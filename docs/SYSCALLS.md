# ABI системных вызовов

## Регистры

Инструкция `SYSCALL` использует ABI, близкий к Linux/System V:

| Назначение | Регистр |
|---|---|
| номер | `RAX` |
| аргументы 1–6 | `RDI`, `RSI`, `RDX`, `R10`, `R8`, `R9` |
| основной результат | `RAX` |
| дополнительный результат | `RDX` |

`RCX` и `R11` уничтожаются CPU. Отрицательный `RAX` — errno. Ядро возвращается
через единый с IRQ путь `IRETQ`, поэтому непроверенный `RIP/RSP` не попадает в
ускоренный, но более хрупкий `SYSRET`.

## Таблица

| № | Имя | Аргументы | Результат/семантика |
|---:|---|---|---|
| 1 | `LOG` | `ptr`, `len<=256` | debug console |
| 2 | `YIELD` | — | добровольное планирование |
| 3 | reserved | — | удалённый scalar IPC, `-38` |
| 4 | reserved | — | удалённый scalar IPC, `-38` |
| 5 | `EXIT` | `status` | не возвращается |
| 6 | `IO_READ8` | `io_cap`, `offset` | byte |
| 7 | `IO_WRITE8` | `io_cap`, `offset`, `byte` | 0 |
| 8 | `IRQ_WAIT` | `irq_cap` | IRQ, блокирующий |
| 9 | `SPAWN` | legacy | bootstrap capability больше не выдаётся |
| 10 | `WAIT` | `process_cap` | status, блокирующий; потребляет cap |
| 11 | `BRK` | `new_break`, 0=query | новый/current break |
| 12 | `MEM_INFO` | — | свободные frames, test/diagnostic ABI |
| 13 | `ENDPOINT_CREATE` | `system_cap` | endpoint handle |
| 14 | `IPC_SEND` | `endpoint_cap`, `IpcMessage*` | enqueue / `-11` |
| 15 | `IPC_RECV` | `endpoint_cap`, `IpcMessage*` | dequeue, блокирующий |
| 16 | `SPACE_CREATE` | `system_cap` | address-space handle |
| 17 | `FRAME_ALLOC` | `system_cap` | обнулённый frame handle |
| 18 | `FRAME_WRITE` | `frame`, `offset`, `src`, `size` | 0 |
| 19 | `SPACE_MAP` | `space`, `frame`, `virtual`, `flags` | 0; потребляет frame |
| 20 | `THREAD_CREATE` | `system`, `space`, `ThreadConfig*` | process handle, suspended |
| 21 | `THREAD_START` | `process_cap` | `SUSPENDED → RUNNABLE` |
| 22 | `CAP_CLOSE` | `handle` | закрывает локальную ссылку |
| 23 | `BOOTFS_INFO` | `bootfs_cap` | `RAX=base`, `RDX=used size` |
| 24 | `PROCESS_KILL` | `process_cap`, `status` | внешний exit; нужен `CONTROL` |
| 25 | `SHARED_CREATE` | `system_cap`, `pages` | shared handle, `pages=1..64` |
| 26 | `SHARED_MAP` | `shared_cap`, `virtual`, `flags` | map в текущий space |
| 27 | `CAP_REVOKE` | `handle` | число закрытых active descendants |
| 28 | `MMIO_MAP` | `mmio_cap`, `virtual` | весь capability range как RW+NX |
| 29 | `IO_READ32` | `io_cap`, `offset` | dword; PCI config backend |
| 30 | `IO_WRITE32` | `io_cap`, `offset`, `value` | 0 |
| 31 | `MMIO_CREATE` | `system_cap`, `physical`, `pages` | MMIO capability |
| 32 | `DMA_CREATE` | `dma_pool_cap`, `pages` | contiguous shared cap, physical в `RDX` |

Основные errno: `-2` no entry, `-9` bad capability, `-11` queue/full slots,
`-12` no memory, `-14` bad user pointer, `-16` busy, `-22` invalid argument,
`-38` unknown syscall.

## Endpoint IPC

```c
struct IpcCap {
    uint64_t handle;
    uint64_t rights;
};

struct IpcMessage {             /* 112 bytes */
    uint64_t words[8];
    uint64_t capability_count;  /* 0..2 */
    struct IpcCap caps[2];
    uint64_t sender_token;      /* output only, не capability */
};
```

Endpoint имеет очередь на восемь сообщений. `IPC_SEND` проверяет все caps до
изменения состояния, ослабляет права до запрошенного подмножества и только
потом делает enqueue. Бит 63 (`CAP_MOVE`) не является правом: после успешного
enqueue исходный handle закрывается. При ошибке он остаётся у sender.

Очередь удерживает сильную ссылку на каждый переданный heap-object. При
`IPC_RECV` ядро создаёт handles получателя, копирует итоговую структуру и снимает
ссылки очереди. Если свободных slots недостаточно, сообщение остаётся в head и
возвращается backpressure. Пустая очередь блокирует текущий thread; endpoint
при этом удерживается отдельной ссылкой.

Reply не является скрытым kernel-состоянием. Отправитель явно передаёт
ослабленную `CAP_SEND` на свой reply endpoint. Так устроены протоколы `procd` и
`nameserver`.

Каждый transfer создаёт descendant исходной capability. Очередь удерживает
pinned lineage node даже после `CAP_MOVE`; полученный handle становится его
потомком. Благодаря этому `CAP_REVOKE` видит права, прошедшие через несколько
процессов и временно находящиеся в очереди.
Если отозван хотя бы один queued descendant, receive снимает всё сообщение,
освобождает его object refs и возвращает `-9`, сохраняя атомарность payload.

## Объекты памяти

`FRAME_ALLOC` создаёт один zero-filled frame размером 4096 байт. Пока frame не
отображён, `FRAME_WRITE` может копировать в него диапазон
`offset + size <= 4096`.

`SPACE_MAP` принимает page-aligned user address и флаги:

```text
SPACE_MAP_WRITE = 1
SPACE_MAP_EXEC  = 2
```

Одновременные WRITE+EXEC запрещены. Успешный map передаёт ownership физического
кадра leaf PTE и потребляет frame handle; разрушение AddressSpace освобождает
leaf frames и все уровни page tables снизу вверх. Дублированный frame нельзя
map-ить (`-16`), потому что его ownership был бы неоднозначен.

`SHARED_CREATE` создаёт от 1 до 64 zero-filled frames и возвращает capability с
`MAP|READ|WRITE`. `SHARED_MAP` отображает весь объект в текущий managed
AddressSpace по page-aligned адресу. Разрешены флаги `0` и `SPACE_MAP_WRITE`;
исполняемое отображение невозможно. Для RW нужны `MAP|READ|WRITE`, для R —
`MAP|READ`. Один объект можно передать через IPC и отобразить в нескольких
процессах; mapping удерживает object ref до teardown address space.

`MMIO_MAP` принимает page-aligned user address и capability типа MMIO с
`MAP|READ|WRITE`. x86-64 не имеет write-only PTE, поэтому права явно отражают
фактическую возможность чтения. Физический адрес находится внутри capability
и не передаётся user process аргументом. Сейчас bootstrap policy создаёт одну
capability — VGA text page `0xB8000` для `terminal.elf`. Mapping получает
`USER|RW|NX|BORROWED`: teardown удаляет page tables, но не пытается вернуть
device pages в PMM. Повторное отображение занятого диапазона даёт `-16`.

`MMIO_CREATE` доступен только обладателю system capability с `CREATE`. Физический
адрес и длина проверяются и затем становятся частью value capability; обычный
драйвер получает уже готовый диапазон. `DMA_CREATE` требует отдельный
`CAP_DMA_POOL`, выделяет физически непрерывные frames и возвращает и shared
object, и physical base. Именно так `procd` ограничивает NVMe-драйвер BAR-ом и
DMA allocator, не передавая ему root capability.

## Создание thread

```c
struct SpawnGrant {
    uint64_t handle;
    uint64_t rights;
};

struct ThreadConfig {           /* 112 bytes */
    uint64_t entry;
    uint64_t stack_top;
    uint64_t stack_low;
    uint64_t stack_limit;
    uint64_t brk_base;
    uint64_t grant_count;       /* 0..4 */
    struct SpawnGrant grants[4];
};
```

`THREAD_CREATE` не читает ELF и не выделяет user pages. Caller обязан заранее
подготовить AddressSpace. Ядро создаёт TCB/kernel stack, удерживает отдельную
ссылку на space, копирует attenuated capabilities и возвращает process handle
с `WAIT|CONTROL`. Новый thread остаётся `SUSPENDED`, пока caller явно не вызовет
`THREAD_START`. После успеха caller обычно закрывает свой space handle.

## WAIT, BRK и faults

Process capability содержит generation-safe token, а не индекс таблицы.
`WAIT` блокируется до exit, возвращает status, потребляет handle и разрешает
повторное использование slot с новым generation.

`PROCESS_KILL` требует process capability с `CONTROL`, не потребляет её и
возвращает `0` после перевода живой чужой задачи в zombie. Self-kill через этот
API отвергается (`-22`), уже завершившаяся цель даёт `-16`; status затем получает
обычный `WAIT`. Если цель блокировалась в IPC/WAIT/IRQ, kernel сначала отменяет
соответствующее ожидание и освобождает удерживаемые ссылки.

`CAP_REVOKE` не закрывает указанный root. Он обходит lineage tree, закрывает
все активные descendants и возвращает их число. Неверный handle даёт `-9`.

`BRK` работает внутри уже созданного address space: рост добавляет обнулённые
RW+NX pages, shrink возвращает frames. Page fault непосредственно под
`stack_low` добавляет одну stack page до `stack_limit`; остальные user faults
завершают только виновный процесс со status `128 + vector`.

## Проверка границы доверия

- каждый user pointer переводится через CR3 владельца;
- `P|US` проверяется на всех четырёх уровнях page tables;
- при копировании заблокированному receiver используется его CR3, не текущий;
- I/O/IRQ проверяют type, rights и границы диапазона;
- MMIO address приходит только из capability, mapping всегда NX;
- kernel stack, TCB и object metadata не читаются из user memory;
- raw physical address, process token и kernel object pointer никогда не
  выбираются пользователем как полномочия.
