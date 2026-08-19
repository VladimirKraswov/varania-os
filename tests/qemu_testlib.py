"""Общий headless QEMU runner для интеграционных тестов Varania OS."""

from __future__ import annotations

from pathlib import Path
import os
import select
import shutil
import subprocess
import time


ROOT = Path(__file__).resolve().parents[1]
IMAGE = ROOT / "VOS.VHD"


def boot_until(markers: tuple[bytes, ...], timeout: float = 10.0) -> bytes:
    qemu_name = os.environ.get("QEMU_BIN", "qemu-system-x86_64")
    qemu = shutil.which(qemu_name)
    if qemu is None:
        raise RuntimeError(f"не найден {qemu_name}")
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
    process = subprocess.Popen(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    captured = bytearray()
    deadline = time.monotonic() + timeout
    try:
        assert process.stdout is not None
        while not all(marker in captured for marker in markers):
            if time.monotonic() >= deadline:
                missing = [marker.decode(errors="replace") for marker in markers if marker not in captured]
                raise TimeoutError(f"за {timeout:g} с не появились маркеры: {missing}")
            readable, _, _ = select.select([process.stdout], [], [], 0.1)
            if not readable:
                if process.poll() is not None:
                    raise RuntimeError("QEMU завершился до контрольных маркеров")
                continue
            chunk = os.read(process.stdout.fileno(), 512)
            if not chunk:
                raise RuntimeError("QEMU закрыл debug console")
            captured.extend(chunk)
    finally:
        process.terminate()
        try:
            process.communicate(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.communicate()
    return bytes(captured)
