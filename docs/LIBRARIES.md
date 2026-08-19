# Системная библиотека и аналог DLL

## Почему здесь нет копии Win32 DLL

Обычная DLL смешивает две разные задачи: повторное использование локального
кода и подключение stateful-компонента во время исполнения. Для микроядра это
плохая граница: файловая система или терминал не должны исполняться в address
space приложения. Поэтому Varania OS разделяет библиотечный слой на две части:

1. **FASM-модули** из `/system/lib/*.inc` — короткие функции памяти, IPC и
   типобезопасные клиентские обёртки. Они включаются в ELF при сборке.
2. **`.vlib` capability service** — версионированный контракт с изолированным
   процессом. Nameserver возвращает только `SEND` capability совместимой версии.

Это и есть микроядерный аналог динамической библиотеки: реализацию можно
перезапустить или заменить независимо от клиента, состояние не разделяет его
память, а доступ является явным полномочием.

Текущий loader по-прежнему принимает только статические `ET_EXEC`: `.vlib` не
является `ET_DYN` и не требует relocations. Когда появится безопасный dynamic
linker, чистые RX-модули можно будет дополнительно кэшировать общими frames, не
меняя сервисные контракты.

## Размещение

```text
/bin/edit.elf                    редактор и эталонный клиент libvarania
/bin/fasm.elf                    системный FASM 1.73.35
/bin/hello.elf                   минимальный disk-only ELF
/bin/sysinfo.elf                 пример libvarania и сведения о памяти
/system/lib/base.inc             память и строки
/system/lib/ipc.inc              IPC, backpressure, vlib_open
/system/lib/terminal.inc         terminal.vlib ABI 1
/system/lib/vfs.inc              filesystem.vlib ABI 1
/system/lib/session.inc          foreground/session.vlib ABI 1
/system/lib/process.inc          process.vlib ABI 1
/system/lib/runtime.inc          umbrella include
/system/lib/services/*.vlib      читаемые manifests контрактов
/system/templates/minimal.asm    шаблон минимальной программы
```

Те же файлы находятся в `src/lib` репозитория и импортируются в системный том.
Исходник VEdit использует `runtime.inc`, поэтому библиотека проверяется реальным
приложением и end-to-end тестом.

## Version negotiation

Регистрация nameserver:

```text
words[0] = NAMESERVER_REGISTER
words[1] = service ID
words[2] = ABI version, 0 означает legacy ABI 1
cap[0]   = endpoint с SEND
```

Открытие `.vlib`:

```text
words[0] = NAMESERVER_LOOKUP
words[1] = service ID
words[2] = минимальная ABI version
cap[0]   = reply endpoint

reply.words[0] = 0 / errno
reply.words[1] = фактическая ABI version
reply.cap[0]    = ослабленный SEND endpoint
```

Если версия сервиса меньше требуемой, nameserver возвращает `-93`. Клиент не
получает несовместимую capability и не может случайно отправить новый протокол
старой реализации.

## Публичный API ABI 1

Все процедуры имеют префикс `vlib_`, используют System V AMD64 registers и
возвращают отрицательный errno в `RAX`.

| Модуль | Основные процедуры |
|---|---|
| `base.inc` | `vlib_zero`, `vlib_copy`, `vlib_string_length/copy` |
| `ipc.inc` | `vlib_send_retry`, `vlib_open`, `vlib_close` |
| `terminal.inc` | connect, clear, write, raw key, цветные VGA cells |
| `vfs.inc` | connect/detach, resolve/create/stat, streaming read/write |
| `session.inc` | connect, push/pop foreground CONTROL capability |
| `process.inc` | синхронный запуск ELF64 из VaraniaFS |
| `runtime.inc` | `vlib_initialize`, `vlib_shutdown` и все модули выше |

Пример приложения:

```asm
format ELF64 executable 3
entry start
include '/system/src/user/abi.inc'
include '/system/lib/runtime.inc'

segment readable executable
start:
  call vlib_initialize
  test rax, rax
  jnz .failed
  ; Здесь доступны terminal, VFS и process API.
  call vlib_shutdown
  exit_process 0
.failed:
  exit_process 1
```

`vlib_fs_write` принимает object, 64-битный offset, byte count, source и flags;
сама режет поток на 256-KiB chunks. `vlib_process_run` читает ELF в то же shared
window и размещает длинную command line после образа. Ни одна обёртка не знает
on-disk формат VaraniaFS и не получает hardware capability.

## Правила совместимости

- существующая операция и смысл поля не меняются внутри одной ABI version;
- новые необязательные поля должны быть нулём у старого клиента;
- несовместимое изменение увеличивает version и получает новый `.vlib` manifest;
- endpoint всегда выдаётся с минимальными правами, process capability не
  является частью библиотечного контракта;
- клиент обязан закрывать capabilities и вызывать `vlib_shutdown` перед exit;
- интерфейсный `.inc` содержит только публичный ABI, а реализация сервиса
  остаётся в отдельном ELF-процессе.
