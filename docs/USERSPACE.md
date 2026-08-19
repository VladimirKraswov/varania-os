# User space, initramfs и ELF64

## Зачем здесь отдельный initramfs

На раннем этапе полноценная VFS смешала бы два разных учебных вопроса: загрузку
процесса и устройство файловой системы. Поэтому raw image содержит небольшой
read-only архив. Он даёт именованные ELF-файлы и строгие границы, но не обещает
каталоги, запись, permissions или persistent storage.

`scripts/mkinitramfs.py` всегда создаёт 65536 байт и нулевое заполнение, поэтому
одни и те же входные ELF дают воспроизводимый образ.

## Формат initramfs

Все числа little-endian.

```c
struct Header {                 /* 24 bytes */
    char     magic[8];          /* "VARNIR01" */
    uint32_t version;           /* 1 */
    uint32_t entry_count;       /* <= 32 */
    uint32_t total_size;        /* значимая часть архива */
    uint32_t reserved;
};

struct Entry {                  /* 48 bytes */
    char     name[32];          /* NUL-terminated ASCII */
    uint32_t offset;            /* 16-byte aligned */
    uint32_t size;
    uint32_t flags;
    uint32_t reserved;
};
```

Ядро валидирует magic/version/count/total size до первого поиска. При поиске
повторно проверяются `offset+size` и точное имя.

## Поддерживаемый ELF64

Загрузчик принимает только:

- ELF class 64, little-endian, current version;
- `ET_EXEC`, machine `EM_X86_64`;
- до 16 program headers размером 56 байт;
- `PT_LOAD` в `0x10000..0x3FFFFFFF`;
- совпадающее page offset у `p_offset` и `p_vaddr`;
- `p_filesz <= p_memsz` и диапазоны внутри файла;
- readable segments, но никогда одновременно W и X;
- entry внутри executable `PT_LOAD`;
- неперекрывающиеся 4-KiB pages сегментов.

Каждая страница сначала выделяется и обнуляется. Затем `p_filesz` копируется
через HHDM, поэтому хвост до `p_memsz` автоматически становится BSS. Флаги:

| ELF | Page table |
|---|---|
| `PF_R|PF_X` | user, read-only, executable |
| `PF_R|PF_W` | user, writable, NX |
| `PF_R` | user, read-only, NX |

PIE, `PT_INTERP`, relocations, shared libraries и demand-paging исполняемого
файла пока не поддерживаются.

## Сборка программы

Минимальный пример:

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

Чтобы добавить программу:

1. создать `src/user/name.asm`;
2. добавить `name` в `USER_PROGRAMS` Makefile;
3. при необходимости вызвать её из `src/user/init.asm`;
4. выполнить `make clean && make check` для проверки ELF/initramfs;
5. добавить QEMU-маркер, если программа доказывает новый инвариант.

## Роль user/init

Kernel знает только имя `init.elf`. Bootstrap capabilities init:

| Handle | Объект | Права |
|---:|---|---|
| 1 | system | `SPAWN` |
| 2 | IRQ1 | `WAIT` |
| 3 | ports `0x60..0x64` | `READ` |

Init запускает IPC service, client, memory/isolation/lifecycle tests и keyboard
driver. Client получает только `CAP_SEND` к service. Driver получает IRQ1 и
I/O range; IRQ при этом перемещается из init. Init ждёт конечные процессы и
оставляет service/driver работающими.

Такой bootstrap уже отделяет mechanism от policy: ядро реализует spawn, wait,
memory и capabilities, но состав системы задаёт обычная программа ring 3.

## Встроенные проверки user space

`memory_test.elf` намеренно имеет многостраничные RX и RW segments, проверяет
BSS, касается трёх дополнительных stack pages, растит и уменьшает heap и
убеждается, что повторно выданная page обнулена.

`isolation_test.elf` читает supervisor HHDM. Ожидаемый результат — #PF и status
142 только у этого процесса.

`lifecycle_child.elf` завершается со status 37. Init сначала прогревает slab,
затем сравнивает `SYS_MEM_INFO` до и после второго полного цикла. Равенство
доказывает возврат user frames, page tables и kernel stack; повторное создание
проверяет reuse process slot с новым generation.
