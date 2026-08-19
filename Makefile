SHELL := /bin/bash

FASM_RUNNER := ./tools/fasm/run.sh
QEMU_RUNNER := ./scripts/run-qemu.sh

BOOT_IMAGE   := BOOT.BIN
KERNEL_IMAGE := KERNEL.BIN
INITRAMFS_IMAGE := INITRAMFS.BIN
DISK_IMAGE   := VOS.VHD

USER_BUILD := build/user
USER_PROGRAMS := procd init nameserver service client keyboard memory_test isolation_test lifecycle_child
USER_ELFS := $(addprefix $(USER_BUILD)/,$(addsuffix .elf,$(USER_PROGRAMS)))

BOOT_SOURCES := src/boot/boot.asm src/boot/disk.inc \
                src/kernel/memory/meminfo.inc src/const.inc
KERNEL_SOURCES := src/kernel/kernel.asm src/const.inc \
                  $(wildcard src/kernel/amd64/*.inc)

.PHONY: all build check smoke test-capabilities test-isolation test-lifecycle test run debug clean help

all: build

build: $(DISK_IMAGE)

$(BOOT_IMAGE): $(BOOT_SOURCES) tools/fasm/run.sh
	$(FASM_RUNNER) src/boot/boot.asm $@

$(KERNEL_IMAGE): $(KERNEL_SOURCES) tools/fasm/run.sh
	$(FASM_RUNNER) src/kernel/kernel.asm $@

$(USER_BUILD)/%.elf: src/user/%.asm src/user/abi.inc tools/fasm/run.sh
	mkdir -p $(USER_BUILD)
	$(FASM_RUNNER) $< $@

$(INITRAMFS_IMAGE): $(USER_ELFS) scripts/mkinitramfs.py
	python3 scripts/mkinitramfs.py --size 65536 $@ \
	  $(foreach program,$(USER_PROGRAMS),$(program).elf=$(USER_BUILD)/$(program).elf)

$(DISK_IMAGE): $(BOOT_IMAGE) $(KERNEL_IMAGE) $(INITRAMFS_IMAGE) src/link.asm
	$(FASM_RUNNER) src/link.asm $@

check: build
	python3 tests/check_image.py

smoke: check
	python3 tests/smoke_qemu.py

test-isolation: check
	python3 tests/test_memory_isolation.py

test-lifecycle: check
	python3 tests/test_process_lifecycle.py

test-capabilities: check
	python3 tests/test_capability_ipc.py

test: smoke test-capabilities test-isolation test-lifecycle

run: check
	$(QEMU_RUNNER)

# Запуск без графики с журналом прерываний и ошибок процессора.
debug: check
	$(QEMU_RUNNER) -display none -d int,guest_errors -D qemu-debug.log

clean:
	rm -f $(BOOT_IMAGE) $(KERNEL_IMAGE) $(INITRAMFS_IMAGE) $(DISK_IMAGE) qemu-debug.log
	rm -rf build

help:
	@printf '%s\n' \
	  'make build  — собрать загрузчик, ядро, ELF, initramfs и raw-образ' \
	  'make run    — проверить образ и запустить QEMU' \
	  'make test   — статические проверки + headless smoke-тест' \
	  'make test-capabilities — отдельно проверить endpoint/capability transfer' \
	  'make test-isolation — отдельный QEMU-тест памяти и изоляции' \
	  'make test-lifecycle — отдельный QEMU-тест create/exit/wait/teardown' \
	  'make debug  — QEMU с журналом прерываний/ошибок' \
	  'make clean  — удалить только создаваемые сборкой файлы'
