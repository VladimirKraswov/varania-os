# Сборка, тестирование и разработка

## FASM

Репозиторий фиксирует официальный FASM 1.73.35 и SHA-256 архива. На Linux x86_64
используется статический бинарник, на Mac ARM — локальный `linux/amd64` Docker
image. Приоритет `tools/fasm/run.sh`:

1. `FASM_BIN`;
2. `fasm` из `PATH`;
3. архивный бинарник на Linux x86_64;
4. контейнер на macOS Apple Silicon.

FASM 1.73.35 выпущен 24 февраля 2026 года. В нём добавлен 64-битный ELF
executable самого assembler и актуальные исправления x86 parser. Версия
зафиксирована намеренно: это современный самодостаточный FASM с воспроизводимым
SHA-256. fasmg интересен как более общий macro engine, но его обязательное
введение не даёт этому небольшому x86-64 ядру преимуществ, соразмерных новой
bootstrap-зависимости.
Использованные здесь `function`, `exception_stub`, `slab_class` и структурные
смещения дают читаемый DSL, сохраняя обычный FASM build.

Официальные источники: [загрузки FASM](https://flatassembler.net/download.php),
[руководство fasmg](https://flatassembler.net/docs.php?article=fasmg_manual).

## Полная проверка

```bash
make clean && make test
```

Проверяются:

1. сборка boot/kernel, 18 user ELF, initramfs и raw image;
2. `55 AA`, размеры, точная конкатенация и SHA-256 FASM;
3. каждый ELF header/program header, file bounds, W^X и page overlap;
4. многостраничные RX/RW segments `memory_test.elf`;
5. реальная загрузка `qemu-system-x86_64` в TCG;
6. user procd, nameserver, capability transfer и четыре endpoint-сообщения;
7. BSS, heap shrink/regrow, demand-growth stack и HHDM isolation;
8. create/exit/wait, deferred teardown, возврат frames и slot reuse;
9. lineage tree, revoke двух поколений и сохранение root capability;
10. внешний kill blocked task и два перезапуска user-space supervisor;
11. shared mapping двух страниц, IPC transfer и возврат frames после teardown;
12. PS/2 → terminal → shell → RAMFS и фактический текст VGA после команд.

Тесты можно запускать отдельно:

```bash
make smoke
make test-capabilities
make test-isolation
make test-lifecycle
make test-revoke
make test-supervisor
make test-shared
make test-shell
```

TCG одинаково работает на Mac ARM и Linux и не требует KVM/HVF. Каждый
headless-тест ограничен таймаутом и сам завершает QEMU.

## Интерактивный запуск

```bash
make run
```

После self-tests пользовательский terminal очищает VGA, печатает приветствие и
shell показывает `varania:/$`. Команда `ls` выводит `bin/`, `etc/`, `home/` и
`README`; доступны также `cd`, `mkdir`, `touch`, `pwd`, `clear`, `help`.

Для диагностического вывода без окна:

```bash
./c.sh run -display none -serial none -monitor none \
  -debugcon stdio -global isa-debugcon.iobase=0xe9
```

## Отладка

```bash
make debug
```

Полезные признаки:

- `Triple fault` до вывода banner — ошибка GDT/paging/trampoline;
- #PF с RSVD — неверный флаг или выравнивание page-table entry;
- kernel `CPU EXCEPTION` — fault с CPL0;
- `terminated user task ... 0E` — ожидаемый #PF isolation test;
- нет `MICROKERNEL_OK` — проверить Context offsets, CR3, IPC и capabilities;
- нет `LIFECYCLE_OK` — проверить deferred teardown и `pmm_free_count`;
- нет `REVOKE_OK` — проверить CapNode parent/ghost/pinned и rollback IPC;
- нет `SUPERVISOR_OK` — проверить CONTROL grant, cancel block и WAIT status;
- нет `SHM_OK` — проверить borrowed PTE, mapping ref и права shared cap;
- нет `SHELL_READY` — проверить terminal/RAMFS registration и nameserver IDs;
- `SHELL_LS_OK` есть, но VGA пуст — проверить MMIO cap и `PAGE.BORROWED`;
- IRQ storm — проверить one-shot mask/unmask и сброс состояния устройства.

## Правила кода

- публичная функция использует System V AMD64 и `function/endf`;
- leaf-функция может использовать `leaf_function/end_leaf`;
- callee сохраняет `RBX`, `RBP`, `R12..R15`;
- физическая память разыменовывается только через `HHDM.base`;
- user pointer нельзя читать до `vmm_translate_user`;
- новый user frame должен быть обнулён до установки mapping;
- capability всегда проверяется по handle, type и rights;
- heap capability создаёт сильную ссылку, queue transfer — отдельную ссылку;
- производная capability всегда получает CapNode parent; queue node pinned;
- успешный `SPACE_MAP` потребляет frame и передаёт ownership leaf mapping;
- shared PTE не владеет frame и обязан удерживаться mapping-ссылкой на object;
- MMIO PTE не владеет device page и всегда должен оставаться NX;
- process object хранит token с generation, не голый slot;
- у IRQ и SYSCALL должен оставаться единый `Context`;
- текущий CR3/kernel stack нельзя освобождать на exit path;
- комментарии объясняют причину и инвариант, а не повторяют mnemonic.

## Изменение карты памяти

1. Изменить `src/const.inc`.
2. Проверить выравнивание и отсутствие пересечений.
3. Убедиться, что всё выдаваемое PMM покрыто HHDM.
4. Обновить `docs/ARCHITECTURE.md`.
5. Выполнить `make clean && make test`.

Образ ядра и initramfs фиксированы на 64 KiB каждый. IDT начинается в kernel со
смещения `0xF000`; FASM останавливает сборку при наложении кода на IDT.

## Изменение user ABI

1. Добавить одинаковый номер в `src/user/abi.inc` и `amd64/syscall.inc`.
2. Считать аргументы только из сохранённого `Context`.
3. Перевести каждый user pointer через `vmm_translate_user` или helper copy.
4. Документировать blocking semantics, consumption capabilities и errno.
5. Явно записать, потребляет ли вызов capability/ownership.
6. Добавить user ELF, который проверяет normal и error path в QEMU.

## CI

`.github/workflows/ci.yml` выполняет `make test` на Linux x86_64. Локальный
прогон на Mac проверяет отдельный путь сборки FASM через Docker.
