# User space, initramfs и ELF64

## Почему loader находится в ring 3

Формат executable, поиск файла и выбор набора сервисов — политика. Микроядру
достаточно уметь создать AddressSpace, выделить/заполнить/map-ить frames и
создать suspended thread. Поэтому обычный путь выглядит так:

```text
init --spawn RPC--> procd --BOOTFS--> initramfs entry
                         |
                         +--> validate ELF64
                         +--> SPACE_CREATE
                         +--> FRAME_ALLOC / FRAME_WRITE / SPACE_MAP
                         +--> ENDPOINT_CREATE
                         +--> THREAD_CREATE(grants) / THREAD_START
                         +--> reply(process cap, endpoint cap)
```

Kernel использует встроенный ELF loader ровно один раз для `procd.elf` — это
неустранимая bootstrap-ступень до появления первого user loader.

## Initramfs

`scripts/mkinitramfs.py` создаёт детерминированный bootstrap-образ ровно
196608 байт. Это не системная файловая система: исходники и обычные программы
живут на VaraniaFS.
Числа little-endian:

```c
struct Header {                 /* 24 bytes */
    char magic[8];              /* "VARNIR01" */
    uint32_t version;           /* 1 */
    uint32_t entry_count;       /* <= 512 */
    uint32_t total_size;
    uint32_t reserved;
};

struct Entry {                  /* 48 bytes */
    char name[32];              /* NUL-terminated ASCII */
    uint32_t offset;            /* 16-byte aligned */
    uint32_t size;
    uint32_t flags;
    uint32_t reserved;
};
```

Kernel проверяет envelope архива до bootstrap и отображает все 192 KiB procd
как R+NX. Procd повторно проверяет точное имя и `offset+size <= total_size`.
Ни один другой процесс не получает bootfs capability/mapping.

## Поддерживаемый ELF64

`procd` принимает намеренно небольшой и проверяемый поднабор:

- class 64, little-endian, `ET_EXEC`, `EM_X86_64`;
- до 16 program headers по 56 байт;
- только `PT_NULL` и `PT_LOAD`;
- `PT_LOAD` в `0x10000..0x3FFFFFFF`;
- `p_filesz <= p_memsz`, file ranges внутри initramfs entry;
- одинаковый page offset `p_offset`/`p_vaddr`;
- readable segment и никогда одновременно writable+executable;
- entry внутри executable segment.

На каждую страницу procd получает zero-filled Frame, копирует пересечение с
файловой частью и передаёт frame в `SPACE_MAP`. Поэтому BSS и хвост page
остаются нулевыми. Kernel независимо запрещает W+X.

| ELF flags | Mapping |
|---|---|
| `PF_R|PF_X` | R+X |
| `PF_R|PF_W` | R+W+NX |
| `PF_R` | R+NX |

PIE, `PT_INTERP`, relocations, shared libraries и demand paging executable пока
не поддерживаются.

## Bootstrap capabilities procd

| Handle | Capability | Права |
|---:|---|---|
| 1 | system object factory | `CREATE` |
| 2 | control endpoint | `SEND|RECV` |
| 3 | bootfs mapping | `READ` |
| 4 | IRQ1 | `WAIT` |
| 5 | ports `0x60..0x64` | `READ` |
| 6 | VGA MMIO page `0xB8000` | `MAP|READ|WRITE` |
| 7 | PCI config ports `0xCF8..0xCFF` | `READ|WRITE` |
| 8 | DMA pool factory | `CREATE` |

Procd передаёт init свой inbox как handle 1 и ослабленный control endpoint как
handle 2. Каждый последующий процесс также получает собственный endpoint как
handle 1. Дополнительные grants идут с handle 2 в порядке `ThreadConfig`.

IRQ1 уникален: при создании keyboard driver он перемещается из procd. VGA
capability выдаётся только `terminal.elf`. Procd сканирует PCI config, создаёт
capability только на найденный BAR NVMe и передаёт её вместе с отдельным DMA
allocator процессу `nvme.elf`. Ни init, ни nameserver, ни shell не владеют
hardware capabilities.

## Протокол procd

Request — `IpcMessage`:

```text
words[0] = PROCD_SPAWN
words[1..3] = NUL-terminated filename, максимум 23 байта
cap[0] = reply endpoint с SEND
cap[1] = необязательный attenuated grant
```

Success reply содержит `words[0]=0`, process capability с `WAIT|CONTROL` и endpoint
нового процесса с `SEND`. Обе передаются с `CAP_MOVE`, поэтому procd не копит
handles. Ошибка возвращается в `words[0]` без capabilities.

Особые grants задаёт bootstrap policy procd, а не запрашивающий процесс:
keyboard получает nameserver/IRQ/I/O, terminal — nameserver/VGA MMIO,
NVMe — BAR/DMA, VFS — nameserver/`CREATE`, а `shm_sender` — `CREATE`.
Получатель shared memory
не получает system capability: sender передаёт ему только ослабленный
`MAP|READ|WRITE` handle обычным endpoint IPC.

## Init, nameserver и сервисы

Init сначала запускает nameserver и изолированные integration-процессы. После
успеха self-tests он создаёт terminal, NVMe, VaraniaFS, keyboard driver и shell. Каждому
из них init передаёт только `CAP_SEND` к endpoint nameserver; hardware grants
добавляет policy procd.

Service регистрирует собственный inbox capability. Client делает lookup,
передавая reply endpoint; nameserver возвращает ослабленный service endpoint.
Process capability сервиса клиент не видит. Этот сценарий одновременно
проверяет:

- endpoint как объект, независимый от процесса;
- передачу capabilities через очередь;
- attenuated rights;
- явный reply channel;
- закрытие временных handles.

## Добавление программы

Минимальный ELF:

```asm
format ELF64 executable 3
entry start
include "abi.inc"

segment readable executable
start:
  log message, message.size
  exit_process 0

segment readable writeable
message db "hello from ring 3", 10
.size = $-message
```

Порядок:

1. создать `src/user/name.asm`;
2. добавить `name` в `USER_PROGRAMS` в Makefile;
3. добавить spawn policy в init или RPC другого supervisor;
4. передать только минимальные capabilities;
5. добавить наблюдаемый тестовый marker;
6. выполнить `make clean && make test`.

## Встроенные проверки

- `memory_test.elf`: multi-page RX/RW, BSS, stack growth, heap grow/shrink и
  zero-on-reuse;
- `isolation_test.elf`: чтение supervisor HHDM, ожидаемый #PF/status 142;
- `lifecycle_child.elf`: status 37 и сравнение PMM frame count после teardown;
- `service/client/nameserver`: endpoint queue и capability transfer;
- `keyboard.elf`: реальный IRQ1, отправляемый тестом через QMP;
- `terminal/vafs/nvme/shell`: key events, persistent FS lifecycle и VGA page;
- `cap_revoke_test.elf`: цепочка из двух descendants и сохранение root;
- `supervisor.elf`: kill blocked target и два restart завершившегося worker;
- `shm_sender/receiver.elf`: две общие страницы, capability transfer,
  двусторонняя запись и повторный teardown с проверкой числа frames.
