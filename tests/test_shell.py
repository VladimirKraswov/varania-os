#!/usr/bin/env python3
"""End-to-end проверка клавиатуры, terminal, shell и RAMFS через QEMU."""

from __future__ import annotations

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
SHELL_READY = b"VARANIA:SHELL_READY"
PROMPT_READY = b"VARANIA:SHELL_PROMPT_READY"
LS_OK = b"VARANIA:SHELL_LS_OK"
MKDIR_OK = b"VARANIA:SHELL_MKDIR_OK"
CD_OK = b"VARANIA:SHELL_CD_OK"
TOUCH_OK = b"VARANIA:SHELL_TOUCH_OK"


class QmpClient:
    """Минимальный синхронный QMP client, достаточный для теста консоли."""

    def __init__(self, path: Path) -> None:
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.socket.connect(str(path))
        self.stream = self.socket.makefile("rwb", buffering=0)
        self._read_json()  # greeting
        self.command("qmp_capabilities")

    def _read_json(self) -> dict[str, object]:
        line = self.stream.readline()
        if not line:
            raise OSError("QMP закрыл соединение")
        return json.loads(line)

    def command(self, name: str, arguments: dict[str, object] | None = None) -> object:
        request: dict[str, object] = {"execute": name}
        if arguments is not None:
            request["arguments"] = arguments
        self.stream.write(json.dumps(request).encode() + b"\n")
        while True:
            response = self._read_json()
            if "error" in response:
                raise OSError(f"ошибка QMP: {response['error']}")
            if "return" in response:
                return response["return"]

    def hmp(self, line: str) -> str:
        result = self.command(
            "human-monitor-command", {"command-line": line}
        )
        return str(result)

    def close(self) -> None:
        self.stream.close()
        self.socket.close()


def connect_qmp(path: Path, deadline: float) -> QmpClient:
    while True:
        try:
            return QmpClient(path)
        except (FileNotFoundError, ConnectionRefusedError):
            if time.monotonic() >= deadline:
                raise TimeoutError("QMP socket не появился")
            time.sleep(0.02)


def wait_debug(
    process: subprocess.Popen[bytes], captured: bytearray, marker: bytes,
    count: int, timeout: float = 15.0,
) -> None:
    """Дождаться заданного числа вхождений маркера в debugcon."""
    deadline = time.monotonic() + timeout
    assert process.stdout is not None
    while captured.count(marker) < count:
        if time.monotonic() >= deadline:
            raise TimeoutError(f"не появился маркер {marker!r}")
        readable, _, _ = select.select([process.stdout], [], [], 0.1)
        if not readable:
            if process.poll() is not None:
                raise RuntimeError("QEMU завершился во время shell-теста")
            continue
        chunk = os.read(process.stdout.fileno(), 512)
        if not chunk:
            raise RuntimeError("QEMU закрыл debug console")
        captured.extend(chunk)


def type_command(qmp: QmpClient, command: str) -> None:
    """Ввести ASCII-команду настоящими PS/2 key events."""
    key_names = {" ": "spc"}
    for character in command:
        key = key_names.get(character, character)
        qmp.hmp(f"sendkey {key} 20")
        time.sleep(0.03)
    qmp.hmp("sendkey ret 20")


def read_vga(qmp: QmpClient, directory: Path) -> str:
    """Считать 80x25 VGA text buffer и убрать байты атрибутов."""
    dump = directory / "vga.bin"
    monitor_output = qmp.hmp(f'pmemsave 0xb8000 4000 "{dump}"')
    if not dump.exists():
        raise RuntimeError(f"pmemsave не создал VGA dump: {monitor_output!r}")
    raw = dump.read_bytes()
    if len(raw) != 4000:
        raise RuntimeError(f"QEMU сохранил {len(raw)} вместо 4000 байт VGA")
    characters = raw[0::2]
    rows = [characters[index:index + 80].decode("ascii", errors="replace").rstrip()
            for index in range(0, len(characters), 80)]
    return "\n".join(rows)


def main() -> None:
    qemu_name = os.environ.get("QEMU_BIN", "qemu-system-x86_64")
    qemu = shutil.which(qemu_name)
    if qemu is None:
        print(f"ОШИБКА: не найден {qemu_name}", file=sys.stderr)
        raise SystemExit(1)

    temporary = Path(tempfile.mkdtemp(prefix="varania-shell-", dir="/tmp"))
    qmp_path = temporary / "qmp.sock"
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
        command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT
    )
    captured = bytearray()
    client: QmpClient | None = None
    try:
        client = connect_qmp(qmp_path, time.monotonic() + 3)
        wait_debug(process, captured, SHELL_READY, 1)
        wait_debug(process, captured, PROMPT_READY, 1)

        type_command(client, "ls")
        wait_debug(process, captured, LS_OK, 1)
        wait_debug(process, captured, PROMPT_READY, 2)
        root_screen = read_vga(client, temporary)
        for expected in ("Welcome to Varania OS", "bin/", "etc/", "home/", "README"):
            if expected not in root_screen:
                raise AssertionError(f"на VGA после `ls` нет {expected!r}\n{root_screen}")

        type_command(client, "mkdir demo")
        wait_debug(process, captured, MKDIR_OK, 1)
        wait_debug(process, captured, PROMPT_READY, 3)
        type_command(client, "cd demo")
        wait_debug(process, captured, CD_OK, 1)
        wait_debug(process, captured, PROMPT_READY, 4)
        type_command(client, "touch note")
        wait_debug(process, captured, TOUCH_OK, 1)
        wait_debug(process, captured, PROMPT_READY, 5)
        type_command(client, "ls")
        wait_debug(process, captured, LS_OK, 2)

        child_screen = read_vga(client, temporary)
        for expected in ("varania:/demo$", "note"):
            if expected not in child_screen:
                raise AssertionError(f"на VGA после lifecycle RAMFS нет {expected!r}\n{child_screen}")
    except (AssertionError, OSError, RuntimeError, TimeoutError) as error:
        print(bytes(captured).decode("utf-8", errors="replace"), end="")
        print(f"ОШИБКА: shell/RAMFS тест не пройден: {error}", file=sys.stderr)
        raise SystemExit(1)
    finally:
        if client is not None:
            client.close()
        process.terminate()
        try:
            process.communicate(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.communicate()
        shutil.rmtree(temporary, ignore_errors=True)

    print(bytes(captured).decode("utf-8", errors="replace"), end="")
    print("Shell-тест пройден: PS/2 → terminal → shell → RAMFS и VGA работают end-to-end.")


if __name__ == "__main__":
    main()
