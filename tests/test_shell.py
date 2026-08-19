#!/usr/bin/env python3
"""End-to-end проверка keyboard, terminal, shell и persistent VaraniaFS."""

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
NVME_IMAGE = ROOT / "VARANIA.VAFS"
SHELL_READY = b"VARANIA:SHELL_READY"
PROMPT_READY = b"VARANIA:SHELL_PROMPT_READY"
LS_OK = b"VARANIA:SHELL_LS_OK"
MKDIR_OK = b"VARANIA:SHELL_MKDIR_OK"
CD_OK = b"VARANIA:SHELL_CD_OK"
TOUCH_OK = b"VARANIA:SHELL_TOUCH_OK"
CAT_OK = b"VARANIA:SHELL_CAT_OK"
WRITE_OK = b"VARANIA:SHELL_WRITE_OK"
RUN_OK = b"VARANIA:SHELL_RUN_OK"
DISK_ELF_OK = b"VARANIA:DISK_ELF_OK"
SELFHOST_FASM_OK = b"VARANIA:SELFHOST_FASM_OK"


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
    key_names = {" ": "spc", ".": "dot", "/": "slash"}
    for character in command:
        key = key_names.get(character, character)
        qmp.hmp(f"sendkey {key} 20")
        time.sleep(0.03)
    qmp.hmp("sendkey ret 20")


def read_framebuffer(
    qmp: QmpClient, directory: Path, name: str,
) -> tuple[int, int, bytes]:
    """Снять реальный VBE framebuffer, а не отключённую BIOS text aperture."""
    dump = directory / f"{name}.ppm"
    monitor_output = qmp.hmp(f'screendump "{dump}"')
    if not dump.exists():
        raise RuntimeError(f"screendump не создал PPM: {monitor_output!r}")
    raw = dump.read_bytes()
    parts = raw.split(b"\n", 3)
    if len(parts) != 4 or parts[0] != b"P6" or parts[2] != b"255":
        raise RuntimeError("некорректный binary PPM от QEMU")
    width, height = map(int, parts[1].split())
    pixels = parts[3]
    if len(pixels) != width * height * 3:
        raise RuntimeError("обрезан framebuffer screendump")
    return width, height, pixels


def changed_pixels(first: bytes, second: bytes) -> int:
    """Посчитать pixels, изменившиеся между двумя RGB-кадрами."""
    if len(first) != len(second):
        raise RuntimeError("нельзя сравнить framebuffer разного размера")
    return sum(
        first[index:index + 3] != second[index:index + 3]
        for index in range(0, len(first), 3)
    )


def main() -> None:
    qemu_name = os.environ.get("QEMU_BIN", "qemu-system-x86_64")
    qemu = shutil.which(qemu_name)
    if qemu is None:
        print(f"ОШИБКА: не найден {qemu_name}", file=sys.stderr)
        raise SystemExit(1)

    # Тест повторяем: убрать только каталог, который сам тест создаёт. Host CLI
    # пишет новое COW-поколение и не затрагивает остальные данные тома.
    subprocess.run(
        [sys.executable, str(ROOT / "tools/vafs/vafs.py"), "rm",
         str(NVME_IMAGE), "/demo", "--recursive"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
    )

    temporary = Path(tempfile.mkdtemp(prefix="varania-shell-", dir="/tmp"))
    qmp_path = temporary / "qmp.sock"
    command = [
        qemu,
        "-machine", "pc,accel=tcg",
        "-cpu", "max",
        "-m", "128M",
        "-drive", f"format=raw,file={IMAGE}",
        "-drive", f"if=none,id=varania-nvme,format=raw,file={NVME_IMAGE}",
        "-device", "nvme,drive=varania-nvme,serial=VARANIA0001",
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
        width, height, initial_pixels = read_framebuffer(
            client, temporary, "initial-console"
        )
        if (width, height) != (1280, 800):
            raise AssertionError(f"ожидался VBE 1280x800, получен {width}x{height}")

        type_command(client, "ls")
        wait_debug(process, captured, LS_OK, 1)
        wait_debug(process, captured, PROMPT_READY, 2)
        _, _, root_pixels = read_framebuffer(client, temporary, "root-ls")
        if changed_pixels(initial_pixels, root_pixels) < 250:
            raise AssertionError("`ls` не изменил видимый VBE framebuffer")

        type_command(client, "cd system")
        wait_debug(process, captured, CD_OK, 1)
        wait_debug(process, captured, PROMPT_READY, 3)
        type_command(client, "cd src")
        wait_debug(process, captured, CD_OK, 2)
        wait_debug(process, captured, PROMPT_READY, 4)
        type_command(client, "cat const.inc")
        wait_debug(process, captured, CAT_OK, 1)
        wait_debug(process, captured, PROMPT_READY, 5)
        type_command(client, "cd ..")
        wait_debug(process, captured, CD_OK, 3)
        wait_debug(process, captured, PROMPT_READY, 6)
        type_command(client, "cd ..")
        wait_debug(process, captured, CD_OK, 4)
        wait_debug(process, captured, PROMPT_READY, 7)

        # hello.elf отсутствует в initramfs: успешный marker доказывает путь
        # VaraniaFS READ -> shared capability -> procd ELF64 loader -> ring 3.
        type_command(client, "cd bin")
        wait_debug(process, captured, CD_OK, 5)
        wait_debug(process, captured, PROMPT_READY, 8)
        type_command(client, "run hello.elf")
        wait_debug(process, captured, DISK_ELF_OK, 1)
        wait_debug(process, captured, RUN_OK, 1)
        wait_debug(process, captured, PROMPT_READY, 9)

        # Официальный FASM 1.73.35 работает как обычный disk process: читает
        # source через VFS, потоково пишет ELF и завершает работу. Затем shell
        # загружает только что созданный ELF с того же тома.
        # Четыре запуска превышают SESSION_MAX без FS_DETACH (shell уже занял
        # первый slot), поэтому цикл одновременно проверяет возврат VFS window.
        compile_commands = [
            "run fasm.elf /system/t.asm /system/build/t.elf",
            "run fasm.elf /system/t.asm /system/build/t.elf",
            "run fasm.elf /system/t.asm /system/build/t.elf",
            "run fasm.elf /system/ui.asm /system/build/g.elf",
        ]
        for compile_index, compile_command in enumerate(compile_commands):
            type_command(client, compile_command)
            wait_debug(process, captured, RUN_OK, 2 + compile_index)
            wait_debug(process, captured, PROMPT_READY, 10 + compile_index)
        type_command(client, "cd ..")
        wait_debug(process, captured, CD_OK, 6)
        wait_debug(process, captured, PROMPT_READY, 14)
        type_command(client, "cd system")
        wait_debug(process, captured, CD_OK, 7)
        wait_debug(process, captured, PROMPT_READY, 15)
        type_command(client, "cd build")
        wait_debug(process, captured, CD_OK, 8)
        wait_debug(process, captured, PROMPT_READY, 16)
        type_command(client, "run t.elf")
        wait_debug(process, captured, SELFHOST_FASM_OK, 1)
        wait_debug(process, captured, RUN_OK, 6)
        wait_debug(process, captured, PROMPT_READY, 17)
        type_command(client, "cd /")
        wait_debug(process, captured, CD_OK, 9)
        wait_debug(process, captured, PROMPT_READY, 18)

        type_command(client, "mkdir demo")
        wait_debug(process, captured, MKDIR_OK, 1)
        wait_debug(process, captured, PROMPT_READY, 19)
        type_command(client, "cd demo")
        wait_debug(process, captured, CD_OK, 10)
        wait_debug(process, captured, PROMPT_READY, 20)
        type_command(client, "touch note")
        wait_debug(process, captured, TOUCH_OK, 1)
        wait_debug(process, captured, PROMPT_READY, 21)
        type_command(client, "write note hel")
        wait_debug(process, captured, WRITE_OK, 1)
        wait_debug(process, captured, PROMPT_READY, 22)
        type_command(client, "append note lo")
        wait_debug(process, captured, WRITE_OK, 2)
        wait_debug(process, captured, PROMPT_READY, 23)
        type_command(client, "cat note")
        wait_debug(process, captured, CAT_OK, 2)
        wait_debug(process, captured, PROMPT_READY, 24)
        type_command(client, "ls")
        wait_debug(process, captured, LS_OK, 2)

        _, _, child_pixels = read_framebuffer(client, temporary, "demo-ls")
        if changed_pixels(root_pixels, child_pixels) < 250:
            raise AssertionError("VaraniaFS lifecycle не изменил видимый framebuffer")
    except (AssertionError, OSError, RuntimeError, TimeoutError) as error:
        if client is not None:
            try:
                read_framebuffer(client, temporary, "failure")
                print(f"\nFramebuffer snapshot: {temporary / 'failure.ppm'}")
                preserved = os.environ.get("VARANIA_TEST_FAILURE_SCREENSHOT")
                if preserved:
                    shutil.copyfile(temporary / "failure.ppm", preserved)
            except (OSError, RuntimeError):
                pass
        print(bytes(captured).decode("utf-8", errors="replace"), end="")
        print(f"ОШИБКА: shell/VaraniaFS тест не пройден: {error}", file=sys.stderr)
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

    verification = subprocess.run(
        [sys.executable, str(ROOT / "tools/vafs/vafs.py"), "fsck",
         str(NVME_IMAGE), "--data"],
        capture_output=True, text=True, check=False,
    )
    tree = subprocess.run(
        [sys.executable, str(ROOT / "tools/vafs/vafs.py"), "tree",
         str(NVME_IMAGE), "/demo"],
        capture_output=True, text=True, check=False,
    )
    extracted_fd, extracted_name = tempfile.mkstemp(prefix="varania-note-", dir="/tmp")
    os.close(extracted_fd)
    extracted = Path(extracted_name)
    get_file = subprocess.run(
        [sys.executable, str(ROOT / "tools/vafs/vafs.py"), "get",
         str(NVME_IMAGE), "/demo/note", str(extracted)],
        capture_output=True, text=True, check=False,
    )
    persisted = extracted.read_bytes() if get_file.returncode == 0 else b""
    extracted.unlink(missing_ok=True)
    guest_elf_fd, guest_elf_name = tempfile.mkstemp(prefix="varania-selfhost-", dir="/tmp")
    os.close(guest_elf_fd)
    guest_elf = Path(guest_elf_name)
    get_guest_elf = subprocess.run(
        [sys.executable, str(ROOT / "tools/vafs/vafs.py"), "get",
         str(NVME_IMAGE), "/system/build/t.elf", str(guest_elf)],
        capture_output=True, text=True, check=False,
    )
    guest_image = guest_elf.read_bytes() if get_guest_elf.returncode == 0 else b""
    guest_elf.unlink(missing_ok=True)
    gui_elf_fd, gui_elf_name = tempfile.mkstemp(prefix="varania-gui-template-", dir="/tmp")
    os.close(gui_elf_fd)
    gui_elf = Path(gui_elf_name)
    get_gui_elf = subprocess.run(
        [sys.executable, str(ROOT / "tools/vafs/vafs.py"), "get",
         str(NVME_IMAGE), "/system/build/g.elf", str(gui_elf)],
        capture_output=True, text=True, check=False,
    )
    gui_image = gui_elf.read_bytes() if get_gui_elf.returncode == 0 else b""
    gui_elf.unlink(missing_ok=True)
    if (verification.returncode or tree.returncode or get_file.returncode
            or get_guest_elf.returncode or get_gui_elf.returncode
            or "note" not in tree.stdout or persisted != b"hello"
            or not guest_image.startswith(b"\x7fELF\x02\x01\x01")
            or not gui_image.startswith(b"\x7fELF\x02\x01\x01")):
        print(verification.stdout + verification.stderr + tree.stdout + tree.stderr, end="")
        print(get_file.stdout + get_file.stderr, end="")
        print(get_guest_elf.stdout + get_guest_elf.stderr, end="")
        print(get_gui_elf.stdout + get_gui_elf.stderr, end="")
        print("ОШИБКА: COW/FASM-результаты не пережили остановку VM", file=sys.stderr)
        raise SystemExit(1)

    print(bytes(captured).decode("utf-8", errors="replace"), end="")
    print("Shell-тест пройден: PS/2 → shell → VaraniaFS/NVMe, remount fsck и VBE работают end-to-end.")


if __name__ == "__main__":
    main()
