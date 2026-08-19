# ABI системных вызовов

## Регистры

Инструкция входа — `SYSCALL`.

| Назначение | Регистр |
|---|---|
| номер syscall | `RAX` |
| аргументы 1–6 | `RDI`, `RSI`, `RDX`, `R10`, `R8`, `R9` |
| результат | `RAX` |
| дополнительный результат IPC sender token | `RDX` |

`RCX` и `R11` уничтожаются самой инструкцией `SYSCALL`. Отрицательные значения
в `RAX` означают ошибку: `-9` — неверная capability, `-11` — занятый mailbox,
`-14` — неверный user pointer, `-38` — неизвестный syscall.

## Таблица

| RAX | Имя | Аргументы | Результат |
|---:|---|---|---|
| 1 | `SYS_LOG` | `RDI=ptr`, `RSI=len<=256` | 0 или `-14` |
| 2 | `SYS_YIELD` | — | 0 после нового планирования |
| 3 | `SYS_SEND` | `RDI=endpoint`, `RSI=value` | 0, `-9`, `-11` |
| 4 | `SYS_RECV` | — | `RAX=value`, `RDX=sender token`; блокирующий |
| 5 | `SYS_EXIT` | — | не возвращается |
| 6 | `SYS_IO_READ8` | `RDI=I/O cap`, `RSI=offset` | byte или `-9` |
| 7 | `SYS_IO_WRITE8` | `RDI=I/O cap`, `RSI=offset`, `RDX=byte` | 0 или `-9` |
| 8 | `SYS_IRQ_WAIT` | `RDI=IRQ cap` | IRQ; блокирующий |

## Пример клиента на FASM

```asm
mov eax, SYS_SEND
mov edi, 1                 ; локальный endpoint handle
mov esi, 0x50494E47        ; PING
syscall

mov eax, SYS_RECV
syscall                    ; ядро блокирует задачу до ответа
cmp rax, 0x504F4E47        ; PONG
```

## Правила безопасности

- `SYS_LOG` переводит каждый user-адрес через page tables и проверяет `P|US`;
- I/O syscalls проверяют тип capability, права и `offset < length`;
- `SYS_SEND` принимает только endpoint с `CAP_SEND`, не индекс задачи;
- kernel stack никогда не берётся из пользовательской памяти;
- возврат идёт через `IRETQ`, поэтому непроверенный адрес не попадает в SYSRET.
