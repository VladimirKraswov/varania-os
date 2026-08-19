#!/usr/bin/env python3
"""Быстрые структурные проверки raw-образа Varania OS."""

from pathlib import Path
import hashlib
import sys


ROOT = Path(__file__).resolve().parents[1]
BOOT = ROOT / "BOOT.BIN"
KERNEL = ROOT / "KERNEL.BIN"
DISK = ROOT / "VOS.VHD"
FASM_ARCHIVE = ROOT / "tools" / "fasm" / "fasm-1.73.35.tgz"
FASM_SHA256 = "a34dec7d0bc2dc79faabb68bd8bc2f62b6cfb31d69c01449367ce4cd8098934e"


def fail(message: str) -> None:
    print(f"ОШИБКА: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    boot = BOOT.read_bytes()
    kernel = KERNEL.read_bytes()
    disk = DISK.read_bytes()

    if len(boot) != 512 + 4096:
        fail(f"BOOT.BIN: ожидалось 4608 байт, получено {len(boot)}")
    if boot[510:512] != b"\x55\xaa":
        fail("в первом секторе отсутствует сигнатура BIOS 55 AA")
    if len(kernel) != 65536:
        fail(f"KERNEL.BIN: ожидалось 65536 байт, получено {len(kernel)}")
    if disk != boot + kernel:
        fail("VOS.VHD не является точной конкатенацией загрузчика и ядра")
    if len(disk) % 512:
        fail("размер диска должен быть кратен сектору 512 байт")
    archive_hash = hashlib.sha256(FASM_ARCHIVE.read_bytes()).hexdigest()
    if archive_hash != FASM_SHA256:
        fail("контрольная сумма встроенного архива FASM не совпадает")

    print("Структура образа корректна:")
    print(f"  загрузчик: {len(boot)} байт (1 + 8 секторов)")
    print(f"  ядро:      {len(kernel)} байт (128 секторов)")
    print(f"  диск:      {len(disk)} байт ({len(disk) // 512} секторов)")
    print("  FASM:      SHA-256 подтверждён")


if __name__ == "__main__":
    main()
