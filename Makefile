SHELL := /bin/bash

FASM_RUNNER := ./tools/fasm/run.sh
QEMU_RUNNER := ./scripts/run-qemu.sh

BOOT_IMAGE   := BOOT.BIN
KERNEL_IMAGE := KERNEL.BIN
DISK_IMAGE   := VOS.VHD

BOOT_SOURCES := src/boot/boot.asm src/boot/disk.inc \
                src/kernel/memory/meminfo.inc src/const.inc
KERNEL_SOURCES := src/kernel/kernel.asm src/const.inc \
                  $(wildcard src/kernel/amd64/*.inc)

.PHONY: all build check smoke test run debug clean help

all: build

build: $(DISK_IMAGE)

$(BOOT_IMAGE): $(BOOT_SOURCES) tools/fasm/run.sh
	$(FASM_RUNNER) src/boot/boot.asm $@

$(KERNEL_IMAGE): $(KERNEL_SOURCES) tools/fasm/run.sh
	$(FASM_RUNNER) src/kernel/kernel.asm $@

$(DISK_IMAGE): $(BOOT_IMAGE) $(KERNEL_IMAGE) src/link.asm
	$(FASM_RUNNER) src/link.asm $@

check: build
	python3 tests/check_image.py

smoke: check
	python3 tests/smoke_qemu.py

test: smoke

run: check
	$(QEMU_RUNNER)

# Запуск без графики с журналом прерываний и ошибок процессора.
debug: check
	$(QEMU_RUNNER) -display none -d int,guest_errors -D qemu-debug.log

clean:
	rm -f $(BOOT_IMAGE) $(KERNEL_IMAGE) $(DISK_IMAGE) qemu-debug.log

help:
	@printf '%s\n' \
	  'make build  — собрать загрузчик, ядро и raw-образ' \
	  'make run    — проверить образ и запустить QEMU' \
	  'make test   — статические проверки + headless smoke-тест' \
	  'make debug  — QEMU с журналом прерываний/ошибок' \
	  'make clean  — удалить только создаваемые сборкой файлы'
