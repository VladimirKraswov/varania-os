# Varania OS: учебное микроядро amd64

Varania OS — небольшая операционная система на Flat Assembler, показывающая весь
путь от BIOS-сектора до изолированных 64-битных процессов. Проект начинался в
2019 году как монолитное 32-битное ядро; текущая активная версия — однопроцессорное
микроядро amd64 с пользовательскими сервисами и capability-based IPC.

Главная цель проекта — читаемость. Активный код подробно прокомментирован на
русском, функции используют System V AMD64 ABI, а макросы FASM `function/endf`,
`leaf_function/end_leaf` и генераторы таблиц убирают механическое повторение,
не скрывая работу процессора.

## Что работает

- собственный BIOS-загрузчик: `real mode → protected mode → long mode`;
- PAE, четырёхуровневый paging и supervisor-only HHDM для физической памяти;
- GDT с ring 0/ring 3, TSS64, отдельный IST1 для double fault и IDT64;
- PMM по карте BIOS E820 и slab allocator `kmalloc/kfree`;
- отдельный PML4, user stack и kernel stack у каждой задачи;
- вытесняющий round-robin планировщик с квантом 10 ms;
- быстрый вход `SYSCALL`, единый формат контекста для syscall/IRQ;
- блокирующий IPC и типизированные capabilities вместо глобальных PID;
- локализация user-mode исключений: ошибочный сервис завершается, ядро и
  остальные процессы продолжают работу;
- capabilities на IRQ и диапазоны I/O-портов для драйверов в user space;
- ring-3 keyboard-service, ожидающий IRQ1 и читающий только порты `0x60..0x64`;
- воспроизводимая сборка и headless-тест в QEMU на Mac Apple Silicon и Linux.

При успешной загрузке клиент и сервис обмениваются `PING/PONG`, после чего
появляется контрольная строка:

```text
VARANIA:MICROKERNEL_OK
```

Отдельная тестовая задача выполняет `UD2`; сообщение о её завершении доказывает,
что исключение ring 3 не превратилось в kernel panic.

## Быстрый старт

### macOS Apple Silicon (M1/M2/M3/M4)

Нужны QEMU и запущенный Docker Desktop:

```bash
brew install qemu
make test
make run
```

FASM из Homebrew не нужен. Зафиксированный официальный FASM 1.73.35 запускается
в локальном `linux/amd64`-контейнере. Сборка не устанавливает файлы в систему.

### Linux x86_64 (Debian/Ubuntu)

```bash
sudo apt update
sudo apt install make python3 qemu-system-x86
make test
make run
```

На Linux официальный статический FASM запускается прямо из архива репозитория;
Docker не требуется.

## Команды

| Команда | Назначение |
|---|---|
| `make build` | собрать `BOOT.BIN`, `KERNEL.BIN`, `VOS.VHD` |
| `make check` | проверить boot signature, размеры, хеш FASM и raw-образ |
| `make test` | выполнить `check` и загрузить ОС в headless QEMU/TCG |
| `make run` | открыть VGA-окно QEMU; клавиатуру обслуживает ring-3 драйвер |
| `make debug` | записать события CPU в `qemu-debug.log` |
| `make clean` | удалить только результаты сборки и журнал QEMU |

Совместимая оболочка старого проекта также сохранена: `./c.sh build|test|run`.

## Дерево активного кода

```text
src/boot/boot.asm             загрузка, E820, paging, вход в long mode
src/const.inc                 единая физическая/виртуальная карта
src/kernel/kernel.asm         композиция ядра и встроенные user-сервисы
src/kernel/amd64/macros.inc   читаемый FASM DSL и interrupt helpers
src/kernel/amd64/pmm.inc      физические кадры
src/kernel/amd64/memory.inc   адресные пространства и user-pointer validation
src/kernel/amd64/slab.inc     kmalloc/kfree
src/kernel/amd64/task.inc     TCB, ring 3 и планировщик
src/kernel/amd64/ipc.inc      endpoint capabilities и IPC
src/kernel/amd64/device.inc   IRQ/I/O capabilities для драйверов
src/kernel/amd64/syscall.inc  SYSCALL ABI
tests/                        формат образа и настоящий QEMU smoke-test
tools/fasm/                   воспроизводимый FASM 1.73.35
```

Исторический 32-битный код оставлен в `src/kernel/` для сравнения, но не входит
в образ.

## Документация

- [Архитектура и доверенная граница](docs/ARCHITECTURE.md)
- [ABI системных вызовов](docs/SYSCALLS.md)
- [Драйверы в пользовательском пространстве](docs/DRIVERS.md)
- [Сборка, тестирование и отладка](docs/DEVELOPMENT.md)
- [История переноса x86 → amd64 → микроядро](docs/PORTING.md)

## Честные ограничения

Это уже рабочее микроядро, но ещё не ОС общего назначения:

- один CPU, legacy BIOS/PIC/PIT; нет UEFI, APIC, SMP и ACPI;
- максимум четыре встроенные задачи, программа и стек пока по одной странице;
- нет ELF-loader, файловой системы, init-сервера и постоянного хранилища;
- IPC несёт одно 64-битное значение и имеет очередь глубиной один;
- освобождение завершившегося address space и возврат полностью пустых slab-ов
  ещё не реализованы;
- IRQ-маршрутизация показана для PS/2 IRQ1; MMIO, DMA/IOMMU и MSI отсутствуют;
- NX/W^X, ASLR, SMEP/SMAP и полноценная модель отзыва capabilities — следующие
  этапы усиления безопасности.

Ограничения перечислены явно, чтобы учебное ядро не создавало ложного ощущения
готовой production-системы.
