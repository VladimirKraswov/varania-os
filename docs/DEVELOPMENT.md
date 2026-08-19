# Сборка, тестирование и разработка

## FASM

Репозиторий фиксирует официальный FASM 1.73.35 и SHA-256 архива. На Linux x86_64
используется статический бинарник, на Mac ARM — локальный `linux/amd64` Docker
image. Приоритет `tools/fasm/run.sh`:

1. `FASM_BIN`;
2. `fasm` из `PATH`;
3. архивный бинарник на Linux x86_64;
4. контейнер на macOS Apple Silicon.

FASM 1.73.35 оставлен намеренно: это текущая стабильная ветка с простым
самодостаточным бинарником. fasmg/fasm2 интересны как более мощные macro engines,
но их обязательное введение ухудшило бы воспроизводимость учебного проекта.
Использованные здесь `function`, `exception_stub`, `slab_class` и структурные
смещения дают читаемый DSL, сохраняя обычный FASM build.

Официальные источники: [загрузки FASM](https://flatassembler.net/download.php),
[руководство fasmg](https://flatassembler.net/docs.php?article=fasmg_manual).

## Полная проверка

```bash
make clean && make test
```

Проверяются:

1. сборка boot/kernel/raw image;
2. размеры, `55 AA`, точная конкатенация и SHA-256 FASM;
3. реальная загрузка `qemu-system-x86_64` в TCG;
4. инициализация ring-3 keyboard-driver;
5. локализация намеренного `UD2` в user task;
6. блокирующий IPC `PING/PONG` между разными CR3;
7. маркер `VARANIA:MICROKERNEL_OK`.

TCG одинаково работает на Mac ARM и Linux и не требует KVM/HVF. Smoke-test
сам завершает QEMU по таймауту 10 секунд.

## Интерактивный запуск

```bash
make run
```

После загрузки PS/2-клавиатура обслуживается пользовательским драйвером. Для
текстового вывода без окна:

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
- `terminated user task` — корректно локализованный fault CPL3;
- нет `MICROKERNEL_OK` — проверить Context offsets, CR3, IPC и capabilities;
- IRQ storm — проверить one-shot mask/unmask и сброс состояния устройства.

## Правила кода

- публичная функция использует System V AMD64 и `function/endf`;
- leaf-функция может использовать `leaf_function/end_leaf`;
- callee сохраняет `RBX`, `RBP`, `R12..R15`;
- физическая память разыменовывается только через `HHDM.base`;
- user pointer нельзя читать до `vmm_translate_user`;
- capability всегда проверяется по handle, type и rights;
- у IRQ и SYSCALL должен оставаться единый `Context`;
- комментарии объясняют причину и инвариант, а не повторяют mnemonic.

## Изменение карты памяти

1. Изменить `src/const.inc`.
2. Проверить выравнивание и отсутствие пересечений.
3. Убедиться, что всё выдаваемое PMM покрыто HHDM.
4. Обновить `docs/ARCHITECTURE.md`.
5. Выполнить `make clean && make test`.

Образ ядра фиксирован на 64 KiB, IDT начинается со смещения `0xF000`. FASM
останавливает сборку при наложении кода на IDT.

## CI

`.github/workflows/ci.yml` выполняет `make test` на Linux x86_64. Локальный
прогон на Mac проверяет отдельный путь сборки FASM через Docker.
