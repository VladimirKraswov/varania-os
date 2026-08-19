#!/usr/bin/env python3
"""Загрузить ОС без окна и дождаться контрольного сообщения ядра."""

from pathlib import Path
import json
import os
import select
import shutil
import socket
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
IMAGE = ROOT / "VOS.VHD"
MARKER = b"VARANIA:MICROKERNEL_OK"
FAULT_MARKER = b"terminated user task"
IPC_QUEUE_MARKER = b"VARANIA:IPC_QUEUE_OK"
MEMORY_MARKER = b"VARANIA:MEMORY_OK"
DRIVER_MARKER = b"keyboard-driver: waiting for IRQ1"
DRIVER_IRQ_MARKER = b"keyboard-driver: IRQ1 handled"


def main() -> None:
    qemu_name = os.environ.get("QEMU_BIN", "qemu-system-x86_64")
    qemu = shutil.which(qemu_name)
    if qemu is None:
        print(f"ОШИБКА: не найден {qemu_name}", file=sys.stderr)
        raise SystemExit(1)

    qmp_dir = Path(tempfile.mkdtemp(prefix="varania-qmp-", dir="/tmp"))
    qmp_path = qmp_dir / "qmp.sock"
    command = [
        qemu,
        "-machine", "pc,accel=tcg",
        "-cpu", "max",
        "-m", "128M",
        "-drive", f"format=raw,file={IMAGE}",
        "-display", "none",
        "-serial", "none",
        "-monitor", "none",
        "-qmp", f"unix:{qmp_path},server=on,wait=off",
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
    captured = bytearray()
    try:
        # QMP используется только как автоматическая «клавиатура»: посылаем A
        # и тем самым проверяем полный путь IRQ1 до ring-3 драйвера.
        qmp = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        qmp.settimeout(3)
        deadline = time.monotonic() + 3
        while True:
            try:
                qmp.connect(str(qmp_path))
                break
            except (FileNotFoundError, ConnectionRefusedError):
                if time.monotonic() >= deadline:
                    raise
                time.sleep(0.02)
        with qmp:
            qmp.recv(4096)  # greeting
            qmp.sendall(json.dumps({"execute": "qmp_capabilities"}).encode() + b"\n")
            qmp.recv(4096)
            # Ждём именно user-драйвер, а не фиксированную задержку: CI и
            # Mac M1 могут иметь разную скорость TCG.
            assert process.stdout is not None
            boot_deadline = time.monotonic() + 5
            while DRIVER_MARKER not in captured:
                if time.monotonic() >= boot_deadline:
                    raise TimeoutError("keyboard-driver не запустился за 5 секунд")
                readable, _, _ = select.select([process.stdout], [], [], 0.1)
                if not readable:
                    continue
                chunk = os.read(process.stdout.fileno(), 256)
                if not chunk:
                    raise OSError("QEMU завершился до запуска keyboard-driver")
                captured.extend(chunk)
            command = {
                "execute": "human-monitor-command",
                "arguments": {"command-line": "sendkey a"},
            }
            qmp.sendall(json.dumps(command).encode() + b"\n")
            qmp.recv(4096)
        remaining, _ = process.communicate(timeout=10)
        output = bytes(captured) + remaining
    except subprocess.TimeoutExpired:
        process.kill()
        remaining, _ = process.communicate()
        output = bytes(captured) + remaining
    except OSError as error:
        process.kill()
        remaining, _ = process.communicate()
        output = bytes(captured) + remaining
        print(f"ОШИБКА: не удалось послать клавишу через QMP: {error}", file=sys.stderr)
        raise SystemExit(1)
    finally:
        shutil.rmtree(qmp_dir, ignore_errors=True)

    text = output.decode("utf-8", errors="replace")
    print(text, end="")
    if MARKER not in output:
        print("ОШИБКА: ядро не дошло до контрольной точки", file=sys.stderr)
        raise SystemExit(1)
    if FAULT_MARKER not in output:
        print("ОШИБКА: не проверена локализация user-mode исключения", file=sys.stderr)
        raise SystemExit(1)
    if IPC_QUEUE_MARKER not in output:
        print("ОШИБКА: не проверена кольцевая очередь IPC", file=sys.stderr)
        raise SystemExit(1)
    if MEMORY_MARKER not in output:
        print("ОШИБКА: не пройден multi-page memory test", file=sys.stderr)
        raise SystemExit(1)
    if DRIVER_MARKER not in output:
        print("ОШИБКА: ring-3 драйвер не дошёл до ожидания IRQ", file=sys.stderr)
        raise SystemExit(1)
    if DRIVER_IRQ_MARKER not in output:
        print("ОШИБКА: IRQ1 не дошёл до ring-3 драйвера", file=sys.stderr)
        raise SystemExit(1)
    print("Smoke-тест QEMU пройден: ELF init, queued IPC, memory и ring-3 IRQ работают.")


if __name__ == "__main__":
    main()
