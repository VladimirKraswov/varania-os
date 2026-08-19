# Block service, VaraniaFS и shell

## Граница микроядра

В ring 0 нет путей, файлов и NVMe-команд. Ядро предоставляет IPC, shared memory,
MMIO/I/O capabilities и планирование. Остальные уровни — обычные процессы:

```mermaid
flowchart LR
    S["shell"] -->|"FS RPC + private shared window"| F["vafs.elf"]
    F -->|"BLOCK RPC + DMA window"| N["nvme.elf"]
    N -->|"MMIO + contiguous DMA"| D["NVMe namespace"]
    S -->|"TERM RPC"| T["terminal.elf"]
    K["keyboard.elf"] -->|"ASCII events"| T
```

Если `vafs.elf` повреждён, он может испортить свой том, но не page tables ядра
и не MMIO другого устройства. Если shell повреждён, он не имеет capability
NVMe buffer и не может посылать block-команды.

## Discovery и capabilities

| Service ID | Процесс | Назначение |
|---:|---|---|
| 1 | `service.elf` | демонстрационный IPC |
| 2 | `terminal.elf` | текстовый вывод и строки ввода |
| 3 | `vafs.elf` | файловый протокол |
| 4 | `nvme.elf` | 4-KiB block protocol |
| 5 | `procd.elf` | загрузка ELF64 из shared file window |

`procd` выдаёт NVMe-процессу только BAR, DMA allocator и nameserver. VFS
получает nameserver и `CREATE`-право, чтобы создавать отдельные shared windows;
произвольную физическую память он отобразить не может.

## Block IPC

Один запрос переносит один 4096-байтный блок. Bulk bytes лежат в 64-KiB shared
DMA window, IPC остаётся control plane.

| Операция | Request | Response |
|---|---|---|
| `BLOCK_ATTACH=1` | reply cap | status, blocks, block size, window bytes, features + shared cap |
| `BLOCK_READ=2` | block, count=1, window offset | status |
| `BLOCK_WRITE=3` | block, count=1, window offset | status |
| `BLOCK_FLUSH=4` | — | status |

Геометрия и номера блоков — `u64`. Сейчас логический блок сервиса всегда 4 KiB;
драйвер сам переводит его в один или несколько namespace LBA размером 512..4096.
`BLOCK_FEATURE_FLUSH` запрещает VFS публиковать commit до NVMe Flush.

## FS IPC

Каждый RPC передаёт `CAP_SEND` на reply endpoint. Node ID — 64-битный object ID
конкретного mounted volume; `0` является псевдонимом корня. Компонент имени
занимает `words[2..7]`: до 47 печатных байт и NUL.

### Каталоги

```text
FS_LIST=1
request:  directory, opaque cursor
entry:    status=0, next_cursor|type, name
end:      status=1

FS_LOOKUP=2
request:  parent, name
success:  status=0, object, type

FS_MKDIR=3 / FS_CREATE=4
request:  parent, name
success:  status=0, new object
```

`.` и `..` разрешает сам VFS. Shell не знает расположение B+tree и не
интерпретирует object ID.

### Shared file window

```text
FS_ATTACH=5
request:  reply cap
success:  status=0, window bytes + SharedMemory capability

FS_READ=6
request:  object, file offset, byte count, window offset
success:  status=0, bytes read

FS_WRITE=7
request:  object, file offset, byte count, window offset, flags
success:  status=0, bytes written

FS_STAT=8
request:  object
success:  status=0, file size, type, object ID

FS_DETACH=9
request:  reply cap
success:  status=0, per-client window освобождён
```

Обычный `FS_WRITE` сохраняет байты до и после диапазона. Флаг
`FS_WRITE_TRUNCATE=1` начинает новое содержимое; `write` использует его на
первом chunk, а `append` пишет с offset текущего `FS_STAT.size`. Один RPC
переносит до 256 KiB, но размер файла этим не ограничен.

VaraniaFS v1 реализует partial write максимально наглядно: читает старые
страницы, накладывает новый диапазон, считает CRC32C потоком и записывает новую
непрерывную COW-версию. Поэтому каждый вызов атомарен, но серия маленьких append
пока имеет O(n²) write amplification. Следующая on-disk оптимизация — extent
log/segment cleaner; IPC ABI останется тем же.

VFS создаёт до четырёх окон по 64 страницы и привязывает их к неподлежающему
подделке `IpcMessage.sender`. Клиенты не делят DMA buffer NVMe и не могут
подменить данные другого клиента во время RPC.
Короткоживущие клиенты посылают `FS_DETACH`: VFS удаляет своё mapping, закрывает
handle и возвращает slot. При аварийном завершении эту уборку позже заменит
общий process-death notification от supervisor.

## COW commit

`mkdir`, `touch` и `write` выполняют один порядок:

```text
new data extents
  -> new catalog leaves
  -> new internal levels
  -> BLOCK_FLUSH
  -> более старая копия superblock с generation+1
  -> BLOCK_FLUSH
```

До последней публикации новое дерево недостижимо. При ошибке сервер повторно
монтирует самое новое целое поколение, поэтому RAM-копия не расходится с диском.
Подробное размещение и CRC описаны в [VAFS.md](VAFS.md).

## Shell

| Команда | RPC |
|---|---|
| `ls` | последовательность `FS_LIST` |
| `cd` | `FS_LOOKUP`, включая `.`/`..` |
| `mkdir` | `FS_MKDIR` |
| `touch` | `FS_CREATE` |
| `cat` | `FS_LOOKUP` + последовательные `FS_READ` |
| `write FILE TEXT` | `FS_LOOKUP` + `FS_WRITE` |
| `append FILE TEXT` | `FS_STAT` + offset `FS_WRITE` |
| `edit FILE` | `/bin/edit.elf`, путь относительно текущего каталога |
| `run FILE [ARGS]` | `FS_READ` + shared cap → process service |
| `pwd`, `clear`, `help` | локально/terminal IPC |

Shell line discipline принимает до 47 ASCII-байт. Запускаемый процесс получает
command line через shared argument area до 1024 байт, поэтому построенный shell
абсолютный путь редактора не ограничивается payload procd. UTF-8 допустим на
диске и в host CLI, но полноценный Unicode input/rendering появится вместе с
GOP/font service.

## Проверка

`tests/test_shell.py` вводит настоящие key events через QMP, читает VGA memory,
делает `cat` существующего системного файла, запускает disk-only ELF, собирает
новый ELF системным FASM, выполняет его, затем создаёт `/demo/note` двумя
streaming writes (`hel` + `lo`) и останавливает VM. После остановки host CLI обязан:

- пройти `fsck --data`;
- увидеть `/demo/note` в новом поколении;
- извлечь ровно пять байт `hello`.

Так тест покрывает всю цепочку keyboard → shell → VFS → NVMe → image, а не
только debug marker отдельного процесса.

`tests/test_editor.py` отдельно создаёт source через VEdit, сохраняет его,
собирает FASM, запускает output и после остановки проверяет оба файла и CRC32C.
