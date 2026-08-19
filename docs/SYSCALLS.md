# ABI системных вызовов

## Регистры

Вход выполняется инструкцией `SYSCALL`.

| Назначение | Регистр |
|---|---|
| номер syscall | `RAX` |
| аргументы 1–6 | `RDI`, `RSI`, `RDX`, `R10`, `R8`, `R9` |
| основной результат | `RAX` |
| sender token после `RECV` | `RDX` |

`RCX` и `R11` уничтожаются CPU. Отрицательный `RAX` — ошибка.

## Таблица вызовов

| № | Имя | Аргументы | Результат |
|---:|---|---|---|
| 1 | `SYS_LOG` | `ptr`, `len<=256` | 0 / `-14` |
| 2 | `SYS_YIELD` | — | 0 после планирования |
| 3 | `SYS_SEND` | `process_cap`, `value` | 0 / `-9` / `-11` |
| 4 | `SYS_RECV` | — | `RAX=value`, `RDX=sender`; блокирующий |
| 5 | `SYS_EXIT` | `exit_code` | не возвращается |
| 6 | `SYS_IO_READ8` | `io_cap`, `offset` | byte / `-9` |
| 7 | `SYS_IO_WRITE8` | `io_cap`, `offset`, `byte` | 0 / `-9` |
| 8 | `SYS_IRQ_WAIT` | `irq_cap` | IRQ; блокирующий |
| 9 | `SYS_SPAWN` | см. ниже | process handle / ошибка |
| 10 | `SYS_WAIT` | `process_cap` | exit status; блокирующий |
| 11 | `SYS_BRK` | `new_break`; 0=query | break / `-12` / `-22` |
| 12 | `SYS_MEM_INFO` | — | число свободных 4-KiB frames |

Основные errno: `-2` no entry, `-9` bad capability, `-11` queue full,
`-12` no memory/slot, `-14` bad user pointer, `-16` already waited,
`-22` invalid argument, `-38` unknown syscall.

## SYS_SPAWN

```text
RDI = system capability с CAP_SPAWN
RSI = указатель на имя в initramfs
RDX = длина имени 1..31 без NUL
R10 = указатель на SpawnGrant[] или 0
R8  = число grants, 0..4
RAX = локальный process handle ребёнка
```

Структура в user memory:

```c
struct SpawnGrant {
    uint64_t handle;  /* capability родителя */
    uint64_t rights;  /* подмножество исходных прав */
};
```

Ядро сначала копирует имя и всю grant table через page-table validation, затем
проверяет ELF и создаёт процесс. Ребёнок получает capabilities в порядке списка,
начиная с handle 1. Родитель получает process capability с `CAP_SEND|CAP_WAIT`.
При любой ошибке частично созданное address space полностью разрушается.

Process/I/O capabilities копируются с attenuation. IRQ уникален: commit успешного
spawn удаляет его у родителя и переводит маршрутизацию на ребёнка.

Пример из `init.asm`:

```asm
mov [grant.handle], r12       ; process capability сервиса
mov qword [grant.rights], CAP_SEND
mov eax, SYS_SPAWN
mov edi, 1                   ; system cap init
lea rsi, [client_name]
mov edx, client_name.size
lea r10, [grant]
mov r8d, 1
syscall                      ; RAX = process cap клиента
```

## SYS_WAIT и generation

`SYS_WAIT` принимает process capability, а не числовой PID. Если ребёнок ещё
работает, caller становится `BLOCKED_WAIT`. Exit status записывается прямо в
сохранённый Context waiter-а. Если процесс уже завершился, статус возвращается
сразу. Успешный wait потребляет capability и разрешает reuse slot-а.

User fault возвращается родителю как `128 + exception vector`; например #PF —
`142`. Generation в object capability предотвращает ABA при reuse таблицы.

## SYS_BRK и растущий стек

`SYS_BRK(0)` возвращает текущий break. Рост отображает обнулённые RW+NX pages,
shrink снимает mappings и возвращает leaf frames PMM. Максимум — 256 страниц
от конца ELF.

Стек растёт без отдельного syscall: #PF на непосредственно соседней странице
ниже `stack_low` выделяет RW+NX frame. Прыжок через guard distance или выход за
16 страниц считается обычным fault процесса.

## Правила безопасности

- user pointers переводятся через собственный CR3 процесса;
- `P|US` проверяется на каждом уровне page tables;
- ELF loader запрещает W+X и добавляет NX writable mappings;
- I/O syscalls проверяют type, rights и `offset < length`;
- IPC не принимает raw process token;
- kernel stack и TCB никогда не берутся из user memory;
- выход выполняется через `IRETQ`, а не через опасный для непроверенных адресов `SYSRET`.
