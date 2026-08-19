SHELL := /bin/bash

FASM_RUNNER := ./tools/fasm/run.sh
QEMU_RUNNER := ./scripts/run-qemu.sh
VAFS_TOOL   := ./tools/vafs/vafs.py

BOOT_IMAGE   := BOOT.BIN
KERNEL_IMAGE := KERNEL.BIN
INITRAMFS_IMAGE := INITRAMFS.BIN
DISK_IMAGE   := VOS.VHD
NVME_IMAGE   := VARANIA.VAFS
BOOT_PREFIX  := build/boot-prefix.img
DISK_SIZE    := 1G
VAFS_OFFSET  := 4M
VAFS_BOOT_UUID := 56415241-4e49-4146-5300-000000000000
VAFS_UUID    := 56415241-4e49-4146-5300-000000000001

USER_BUILD := build/user
USER_PROGRAMS := procd init nameserver service client terminal keyboard nvme vafs shell \
		 memory_test isolation_test \
		 lifecycle_child cap_revoke_test supervisor kill_target restart_worker \
		 shm_receiver shm_sender
USER_ELFS := $(addprefix $(USER_BUILD)/,$(addsuffix .elf,$(USER_PROGRAMS)))
DISK_BUILD := build/disk
DISK_PROGRAMS := hello
DISK_ELFS := $(addprefix $(DISK_BUILD)/,$(addsuffix .elf,$(DISK_PROGRAMS)))
FASM_SOURCE_STAMP := build/fasm-source/.stamp
FASM_GUEST_ELF := $(DISK_BUILD)/fasm.elf
DISK_ELFS += $(FASM_GUEST_ELF)

BOOT_SOURCES := src/boot/boot.asm src/boot/disk.inc \
                src/kernel/memory/meminfo.inc src/const.inc
KERNEL_SOURCES := src/kernel/kernel.asm src/const.inc \
                  $(wildcard src/kernel/amd64/*.inc)
SYSROOT_INPUTS := Makefile README.md $(shell find src docs scripts -type f) \
	tools/fasm/fasm-1.73.35.tgz tools/vafs/vafs.py

.PHONY: all build check smoke test-capabilities test-isolation test-lifecycle \
	test-revoke test-supervisor test-shared test-shell test-vafs test run debug clean help

all: build

build: $(DISK_IMAGE) $(NVME_IMAGE)

$(BOOT_IMAGE): $(BOOT_SOURCES) tools/fasm/run.sh
	$(FASM_RUNNER) src/boot/boot.asm $@

$(KERNEL_IMAGE): $(KERNEL_SOURCES) tools/fasm/run.sh
	$(FASM_RUNNER) src/kernel/kernel.asm $@

$(USER_BUILD)/%.elf: src/user/%.asm src/user/abi.inc tools/fasm/run.sh
	mkdir -p $(USER_BUILD)
	$(FASM_RUNNER) $< $@

$(DISK_BUILD)/%.elf: src/programs/%.asm src/user/abi.inc tools/fasm/run.sh
	mkdir -p $(DISK_BUILD)
	$(FASM_RUNNER) $< $@

$(FASM_SOURCE_STAMP): tools/fasm/fasm-1.73.35.tgz
	rm -rf build/fasm-source
	mkdir -p build/fasm-source
	tar -xzf $< -C build/fasm-source --strip-components=1
	touch $@

$(FASM_GUEST_ELF): src/fasm/fasm.asm src/fasm/platform.inc $(FASM_SOURCE_STAMP) tools/fasm/run.sh
	mkdir -p $(DISK_BUILD)
	$(FASM_RUNNER) src/fasm/fasm.asm $@

$(INITRAMFS_IMAGE): $(USER_ELFS) scripts/mkinitramfs.py
	python3 scripts/mkinitramfs.py --size 196608 $@ \
	  $(foreach program,$(USER_PROGRAMS),$(program).elf=$(USER_BUILD)/$(program).elf)

$(BOOT_PREFIX): $(BOOT_IMAGE) $(KERNEL_IMAGE) $(INITRAMFS_IMAGE) src/link.asm
	mkdir -p $(dir $@)
	$(FASM_RUNNER) src/link.asm $@

# Host готовит воспроизводимый seed-диск. Guest FASM уже собирает программы
# внутри Varania OS; перенос компоновки kernel/initramfs будет следующим слоем.
# Sparse image не занимает 1 GiB на APFS/ext4, пока гость не запишет блоки.
$(DISK_IMAGE): $(BOOT_PREFIX) $(SYSROOT_INPUTS) $(USER_ELFS) $(DISK_ELFS)
	rm -rf build/sysroot
	mkdir -p build/sysroot/root/bin build/sysroot/root/system/build/fasm-source build/sysroot/root/system/tools/fasm
	tar -xzf tools/fasm/fasm-1.73.35.tgz -C build/sysroot
	cp -R src build/sysroot/root/system/src
	cp -R docs build/sysroot/root/system/docs
	cp -R scripts build/sysroot/root/system/scripts
	cp -R build/user build/sysroot/root/system/build/user
	cp $(DISK_ELFS) build/sysroot/root/bin/
	cp src/programs/selfhost_test.asm build/sysroot/root/system/t.asm
	cp -R build/fasm-source/source build/sysroot/root/system/build/fasm-source/source
	cp -R build/sysroot/fasm/source build/sysroot/root/system/tools/fasm/source
	cp Makefile README.md BOOT.BIN KERNEL.BIN INITRAMFS.BIN build/sysroot/root/system/
	cp build/sysroot/fasm/fasm.txt build/sysroot/root/system/tools/fasm/FASM.TXT
	cp build/sysroot/fasm/whatsnew.txt build/sysroot/root/system/tools/fasm/WHATSNEW.TXT
	cp $(BOOT_PREFIX) $@
	python3 $(VAFS_TOOL) format $@ --size $(DISK_SIZE) --offset $(VAFS_OFFSET) \
	  --uuid $(VAFS_BOOT_UUID) --device ssd
	python3 $(VAFS_TOOL) import-tree $@ --offset $(VAFS_OFFSET) \
	  build/sysroot/root / --exclude __pycache__ --exclude '*.pyc'

# Пока UEFI/GPT loader ещё в работе, firmware загружается с compatibility-диска,
# а системная VaraniaFS уже доступна через настоящее QEMU NVMe устройство.
$(NVME_IMAGE): $(DISK_IMAGE)
	python3 $(VAFS_TOOL) format $@ --size $(DISK_SIZE) \
	  --uuid $(VAFS_UUID) --device ssd
	python3 $(VAFS_TOOL) import-tree $@ build/sysroot/root / \
	  --exclude __pycache__ --exclude '*.pyc'

check: build
	python3 tests/check_image.py
	python3 $(VAFS_TOOL) fsck $(DISK_IMAGE) --offset $(VAFS_OFFSET) --data
	python3 $(VAFS_TOOL) fsck $(NVME_IMAGE) --data

smoke: check
	python3 tests/smoke_qemu.py

test-isolation: check
	python3 tests/test_memory_isolation.py

test-lifecycle: check
	python3 tests/test_process_lifecycle.py

test-capabilities: check
	python3 tests/test_capability_ipc.py

test-revoke: check
	python3 tests/test_capability_revoke.py

test-supervisor: check
	python3 tests/test_supervisor.py

test-shared: check
	python3 tests/test_shared_memory.py

test-shell: check
	python3 tests/test_shell.py

test-vafs:
	python3 tests/test_vafs.py

test: test-vafs smoke test-capabilities test-isolation test-lifecycle test-revoke test-supervisor test-shared test-shell

run: check
	$(QEMU_RUNNER)

# Запуск без графики с журналом прерываний и ошибок процессора.
debug: check
	$(QEMU_RUNNER) -display none -d int,guest_errors -D qemu-debug.log

clean:
	rm -f $(BOOT_IMAGE) $(KERNEL_IMAGE) $(INITRAMFS_IMAGE) $(DISK_IMAGE) $(NVME_IMAGE) qemu-debug.log
	rm -rf build

help:
	@printf '%s\n' \
	  'make build  — собрать kernel, ELF, initramfs и два sparse-образа' \
	  'make run    — проверить образ и запустить QEMU' \
	  'make test   — все статические и headless QEMU-тесты' \
	  'make test-capabilities — отдельно проверить endpoint/capability transfer' \
	  'make test-isolation — отдельный QEMU-тест памяти и изоляции' \
	  'make test-lifecycle — отдельный QEMU-тест create/exit/wait/teardown' \
	  'make test-revoke — проверить дерево происхождения и revoke descendants' \
	  'make test-supervisor — проверить внешний kill и restart policy' \
	  'make test-shared — проверить межпроцессную shared memory и IPC' \
	  'make test-shell — проверить persistent VaraniaFS/NVMe через shell и VGA' \
	  'make test-vafs — проверить COW, CRC32C, B+-tree и recovery VaraniaFS' \
	  'make debug  — QEMU с журналом прерываний/ошибок' \
	  'make clean  — удалить только создаваемые сборкой файлы'
