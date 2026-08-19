#!/usr/bin/env python3
"""Загрузить ОС без окна и дождаться контрольного сообщения ядра."""

from pathlib import Path
import os
import shutil
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
IMAGE = ROOT / "VOS.VHD"
MARKER = b"VARANIA:BOOT_OK"


def main() -> None:
    qemu_name = os.environ.get("QEMU_BIN", "qemu-system-x86_64")
    qemu = shutil.which(qemu_name)
    if qemu is None:
        print(f"ОШИБКА: не найден {qemu_name}", file=sys.stderr)
        raise SystemExit(1)

    command = [
        qemu,
        "-machine", "pc,accel=tcg",
        "-cpu", "max",
        "-m", "128M",
        "-drive", f"format=raw,file={IMAGE}",
        "-display", "none",
        "-serial", "none",
        "-monitor", "none",
        "-no-reboot",
        "-no-shutdown",
        "-debugcon", "stdio",
        "-global", "isa-debugcon.iobase=0xe9",
    ]

    process = subprocess.Popen(
        command,
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    try:
        output, _ = process.communicate(timeout=10)
    except subprocess.TimeoutExpired:
        process.kill()
        output, _ = process.communicate()

    text = output.decode("utf-8", errors="replace")
    print(text, end="")
    if MARKER not in output:
        print("ОШИБКА: ядро не дошло до контрольной точки", file=sys.stderr)
        raise SystemExit(1)
    print("Smoke-тест QEMU пройден: amd64-ядро завершило инициализацию.")


if __name__ == "__main__":
    main()
