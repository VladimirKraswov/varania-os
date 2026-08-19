#!/usr/bin/env python3
"""Структурные проверки boot image, initramfs и всех ELF64-программ."""

from pathlib import Path
import hashlib
import struct
import sys


ROOT = Path(__file__).resolve().parents[1]
BOOT = ROOT / "BOOT.BIN"
KERNEL = ROOT / "KERNEL.BIN"
INITRAMFS = ROOT / "INITRAMFS.BIN"
DISK = ROOT / "VOS.VHD"
FASM_ARCHIVE = ROOT / "tools" / "fasm" / "fasm-1.73.35.tgz"
FASM_SHA256 = "a34dec7d0bc2dc79faabb68bd8bc2f62b6cfb31d69c01449367ce4cd8098934e"

IR_HEADER = struct.Struct("<8sIIII")
IR_ENTRY = struct.Struct("<32sIIII")
ELF_HEADER = struct.Struct("<16sHHIQQQIHHHHHH")
ELF_PROGRAM = struct.Struct("<IIQQQQQQ")
EXPECTED_PROGRAMS = {
    "procd.elf",
    "init.elf",
    "nameserver.elf",
    "service.elf",
    "client.elf",
    "keyboard.elf",
    "memory_test.elf",
    "isolation_test.elf",
    "lifecycle_child.elf",
    "cap_revoke_test.elf",
    "supervisor.elf",
    "kill_target.elf",
    "restart_worker.elf",
    "shm_receiver.elf",
    "shm_sender.elf",
}


def fail(message: str) -> None:
    print(f"ОШИБКА: {message}", file=sys.stderr)
    raise SystemExit(1)


def check_elf(name: str, image: bytes) -> list[tuple[int, int, int, int]]:
    if len(image) < ELF_HEADER.size:
        fail(f"{name}: заголовок ELF обрезан")
    header = ELF_HEADER.unpack_from(image)
    ident, elf_type, machine, version = header[:4]
    entry, phoff, _, _, ehsize, phentsize, phnum = header[4:11]
    if ident[:7] != b"\x7fELF\x02\x01\x01":
        fail(f"{name}: ожидался little-endian ELF64")
    if (elf_type, machine, version) != (2, 62, 1):
        fail(f"{name}: ожидался ET_EXEC для x86-64")
    if ehsize != 64 or phentsize != 56 or not 1 <= phnum <= 16:
        fail(f"{name}: некорректная таблица program headers")
    if phoff + phnum * phentsize > len(image):
        fail(f"{name}: program headers выходят за файл")

    loads: list[tuple[int, int, int, int]] = []
    entry_is_executable = False
    occupied_pages: set[int] = set()
    for index in range(phnum):
        program = ELF_PROGRAM.unpack_from(image, phoff + index * phentsize)
        kind, flags, offset, virtual, _, file_size, memory_size, alignment = program
        if kind != 1 or memory_size == 0:
            continue
        if file_size > memory_size or offset + file_size > len(image):
            fail(f"{name}: PT_LOAD #{index} имеет неверные размеры")
        if (offset ^ virtual) & 0xFFF:
            fail(f"{name}: PT_LOAD #{index} нарушает page congruence")
        if flags & 3 == 3:
            fail(f"{name}: PT_LOAD #{index} одновременно writable и executable")
        if not flags & 4 or alignment not in (0, 1, 4096):
            fail(f"{name}: PT_LOAD #{index} имеет неподдерживаемые flags/alignment")
        first_page = virtual // 4096
        last_page = (virtual + memory_size - 1) // 4096
        pages = set(range(first_page, last_page + 1))
        if occupied_pages & pages:
            fail(f"{name}: PT_LOAD-сегменты перекрывают одну user-страницу")
        occupied_pages |= pages
        if flags & 1 and virtual <= entry < virtual + memory_size:
            entry_is_executable = True
        loads.append((flags, virtual, file_size, memory_size))

    if not loads or not entry_is_executable:
        fail(f"{name}: entry не принадлежит executable PT_LOAD")
    return loads


def check_initramfs(image: bytes) -> None:
    if len(image) != 65536:
        fail(f"INITRAMFS.BIN: ожидалось 65536 байт, получено {len(image)}")
    magic, version, count, used, reserved = IR_HEADER.unpack_from(image)
    if (magic, version, reserved) != (b"VARNIR01", 1, 0):
        fail("initramfs: неверные magic/version/reserved")
    if count != len(EXPECTED_PROGRAMS) or not IR_HEADER.size + count * IR_ENTRY.size <= used <= len(image):
        fail("initramfs: некорректные entry_count/total_size")

    names: set[str] = set()
    previous_end = IR_HEADER.size + count * IR_ENTRY.size
    memory_loads: list[tuple[int, int, int, int]] = []
    for index in range(count):
        raw_name, offset, size, flags, entry_reserved = IR_ENTRY.unpack_from(
            image, IR_HEADER.size + index * IR_ENTRY.size
        )
        if b"\0" not in raw_name:
            fail(f"initramfs: имя записи #{index} не завершено NUL")
        name = raw_name.split(b"\0", 1)[0].decode("ascii")
        if name in names or flags or entry_reserved:
            fail(f"initramfs: неверная или повторная запись {name!r}")
        if offset % 16 or offset < previous_end or offset + size > used:
            fail(f"initramfs: диапазон {name!r} повреждён или перекрывается")
        names.add(name)
        previous_end = offset + size
        loads = check_elf(name, image[offset : offset + size])
        if name == "memory_test.elf":
            memory_loads = loads

    if names != EXPECTED_PROGRAMS:
        fail(f"initramfs: ожидались {sorted(EXPECTED_PROGRAMS)}, получены {sorted(names)}")
    executable_pages = max(
        ((virtual & 0xFFF) + memory_size + 4095) // 4096
        for flags, virtual, _, memory_size in memory_loads
        if flags & 1
    )
    writable_pages = max(
        ((virtual & 0xFFF) + memory_size + 4095) // 4096
        for flags, virtual, _, memory_size in memory_loads
        if flags & 2
    )
    if executable_pages < 2 or writable_pages < 3:
        fail("memory_test.elf не проверяет многостраничные code/data segments")


def main() -> None:
    boot = BOOT.read_bytes()
    kernel = KERNEL.read_bytes()
    initramfs = INITRAMFS.read_bytes()
    disk = DISK.read_bytes()

    if len(boot) != 512 + 4096:
        fail(f"BOOT.BIN: ожидалось 4608 байт, получено {len(boot)}")
    if boot[510:512] != b"\x55\xaa":
        fail("в первом секторе отсутствует сигнатура BIOS 55 AA")
    if len(kernel) != 65536:
        fail(f"KERNEL.BIN: ожидалось 65536 байт, получено {len(kernel)}")
    check_initramfs(initramfs)
    if disk != boot + kernel + initramfs:
        fail("VOS.VHD не является boot + kernel + initramfs")
    if len(disk) % 512:
        fail("размер диска должен быть кратен сектору 512 байт")
    archive_hash = hashlib.sha256(FASM_ARCHIVE.read_bytes()).hexdigest()
    if archive_hash != FASM_SHA256:
        fail("контрольная сумма встроенного архива FASM не совпадает")

    print("Структура образа корректна:")
    print(f"  загрузчик: {len(boot)} байт (1 + 8 секторов)")
    print(f"  ядро:      {len(kernel)} байт (128 секторов)")
    print(f"  initramfs: {len(initramfs)} байт, {len(EXPECTED_PROGRAMS)} ELF64")
    print(f"  диск:      {len(disk)} байт ({len(disk) // 512} секторов)")
    print("  ELF:       ET_EXEC/x86-64, PT_LOAD, W^X и границы подтверждены")
    print("  FASM:      SHA-256 подтверждён")


if __name__ == "__main__":
    main()
