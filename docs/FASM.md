# FASM 1.73.35 и self-hosting

## Что уже является self-hosted

Системный `/bin/fasm.elf` запускается как обычный ELF64-процесс из VaraniaFS.
В нём используется официальный assembler core FASM 1.73.35; Varania-специфичен
только тонкий platform layer.

Автоматический тест выполняет внутри VM:

```text
/bin/fasm.elf /system/t.asm /system/build/t.elf
/system/build/t.elf
```

Первый процесс читает source с NVMe-тома, собирает ELF и потоково записывает
его обратно. Второй процесс загружает этот новый файл с того же тома и печатает
`VARANIA:SELFHOST_FASM_OK`. Host не подменяет результат между командами.

Системный редактор использует тот же путь: `F5` сохраняет source и вызывает
`/bin/fasm.elf`, `F6` загружает output через process.vlib. Его command line
лежит после ELF в shared VFS window, поэтому абсолютные пути не зависят от
47-байтного IPC payload.

## Почему upstream core не форкнут

`src/fasm/fasm.asm` определяет macro для инструкции `syscall`, затем включает
официальный `linux/x64/fasm.asm`. Все parser/assembler/formatter includes остаются
исходными. `src/fasm/platform.inc` эмулирует лишь маленькое подмножество ABI,
которое использует официальный front end:

| Linux-подобный вызов FASM | Реализация Varania |
|---|---|
| `open`, `read`, `write`, `lseek`, `close` | VFS RPC + private shared window |
| stdout/stderr `write` | terminal RPC по 16 байт |
| `brk` | demand-paged `SYS_BRK`, максимум 16 MiB |
| `gettimeofday`, `time` | воспроизводимое нулевое время |
| `exit` | `SYS_EXIT` |

FASM сохраняет свою модель 32-битных внутренних pointers, но работает в
64-битном процессе и собирает ELF64. Heap расположен ниже 4 GiB, а address
space, capabilities, размеры файлов и block numbers остаются 64-битными.

## Файловый адаптер

Platform layer не знает VaraniaFS on-disk format. Через nameserver он находит
terminal и filesystem, делает `FS_ATTACH`, затем разрешает путь по компонентам
`FS_LOOKUP`. Поддерживаются абсолютные пути, `/`, `.` и `..`; относительный путь
пока считается от корня. В именах пока нет shell quoting и пробелов.

Чтение и запись разбиваются на chunks до 256 KiB. Первый chunk output получает
`FS_WRITE_TRUNCATE`, следующие — обычные offset writes. Поэтому размер source и
результата не ограничен loader window, хотя сам запускаемый ELF на текущем этапе
должен помещаться в 256 KiB.
Перед нормальным exit compiler посылает `FS_DETACH`, поэтому его VFS session и
shared window можно повторно использовать. End-to-end тест запускает FASM четыре
раза подряд; без detach четвёртый процесс исчерпал бы все четыре slots вместе с shell.

## Воспроизводимый bootstrap

Host-сборка распаковывает закреплённый `tools/fasm/fasm-1.73.35.tgz`, проверяет
SHA-256 и собирает первоначальный `/bin/fasm.elf`. Те же official sources и
Varania wrapper импортируются в `/system/build/fasm-source` и `/system/src/fasm`.
Это позволяет следующему guest builder пересобрать сам compiler без сети.

## Что осталось до полной пересборки ОС внутри ОС

Компилятор уже не является барьером. Остался build/install orchestration:

1. guest-утилиты для детерминированного `mkinitramfs` и layout boot image;
2. build manifest вместо host-specific shell-команд Makefile;
3. сборка `BOOT.BIN`, `KERNEL.BIN` и bootstrap ELF системным FASM;
4. проверка размеров, W^X, checksum и fsck до установки;
5. запись нового boot slot и атомарное переключение поколения с rollback;
6. reboot-тест, который подтверждает запуск именно guest-built kernel.

Пока эти шаги не реализованы, фраза «полностью self-hosted kernel build» была бы
неточной: программы уже собираются внутри Varania OS, но системный образ всё ещё
компонует host Makefile.
