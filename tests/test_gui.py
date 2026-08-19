#!/usr/bin/env python3
"""End-to-end: VBE framebuffer, PS/2 mouse, desktop, WM и GUI terminal."""

from __future__ import annotations

from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile
import time

from test_shell import QmpClient, connect_qmp, type_command, wait_debug


ROOT = Path(__file__).resolve().parents[1]
IMAGE = ROOT / "VOS.VHD"
NVME_IMAGE = ROOT / "VARANIA.VAFS"
SHELL_READY = b"VARANIA:SHELL_READY"
PROMPT_READY = b"VARANIA:SHELL_PROMPT_READY"
DESKTOP_READY = b"VARANIA:DESKTOP_READY"
DESKTOP_CLIENT = b"VARANIA:DESKTOP_CLIENT_READY"
GTERM_WINDOW = b"VARANIA:GTERM_WINDOW_READY"
GTERM_READY = b"VARANIA:GTERM_READY"
GTERM_CLOSED = b"VARANIA:GTERM_CLOSED"
GUI_DEMO_READY = b"VARANIA:GUI_DEMO_READY"
UI_STATE_OK = b"VARANIA:UI_STATE_OK"
UI_EVENT_OK = b"VARANIA:UI_EVENT_OK"


def move_mouse(qmp: QmpClient, dx: int, dy: int) -> None:
    """Послать небольшие relative packets, которые точно помещаются в PS/2."""
    while dx or dy:
        step_x = max(-80, min(80, dx))
        step_y = max(-80, min(80, dy))
        events: list[dict[str, object]] = []
        if step_x:
            events.append({"type": "rel", "data": {"axis": "x", "value": step_x}})
        if step_y:
            events.append({"type": "rel", "data": {"axis": "y", "value": step_y}})
        qmp.command("input-send-event", {"events": events})
        dx -= step_x
        dy -= step_y
        time.sleep(0.015)


def click(qmp: QmpClient) -> None:
    qmp.command("input-send-event", {"events": [
        {"type": "btn", "data": {"button": "left", "down": True}}
    ]})
    time.sleep(0.06)
    qmp.command("input-send-event", {"events": [
        {"type": "btn", "data": {"button": "left", "down": False}}
    ]})
    time.sleep(0.08)


def ppm_size(path: Path) -> tuple[int, int, bytes]:
    raw = path.read_bytes()
    if not raw.startswith(b"P6\n"):
        raise AssertionError("screendump не является binary PPM")
    parts = raw.split(b"\n", 3)
    if len(parts) != 4:
        raise AssertionError("обрезан PPM header")
    width, height = map(int, parts[1].split())
    if parts[2] != b"255":
        raise AssertionError("неожиданная глубина PPM")
    return width, height, parts[3]


def main() -> None:
    qemu = shutil.which(os.environ.get("QEMU_BIN", "qemu-system-x86_64"))
    if qemu is None:
        print("ОШИБКА: не найден qemu-system-x86_64", file=sys.stderr)
        raise SystemExit(1)

    temporary = Path(tempfile.mkdtemp(prefix="varania-gui-", dir="/tmp"))
    qmp_path = temporary / "qmp.sock"
    screenshot = temporary / "desktop.ppm"
    process = subprocess.Popen(
        [qemu, "-machine", "pc,accel=tcg", "-cpu", "max", "-m", "128M",
         "-drive", f"format=raw,file={IMAGE}",
         "-drive", f"if=none,id=varania-nvme,format=raw,file={NVME_IMAGE}",
         "-device", "nvme,drive=varania-nvme,serial=VARANIA0001",
         "-display", "none", "-serial", "none", "-monitor", "none",
         "-qmp", f"unix:{qmp_path},server=on,wait=off",
         "-no-reboot", "-no-shutdown", "-debugcon", "stdio",
         "-global", "isa-debugcon.iobase=0xe9"],
        cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    captured = bytearray()
    client: QmpClient | None = None
    try:
        client = connect_qmp(qmp_path, time.monotonic() + 3)
        mice = client.command("query-mice")
        print(f"QEMU pointing devices: {mice}")
        wait_debug(process, captured, SHELL_READY, 1, timeout=25)
        wait_debug(process, captured, PROMPT_READY, 1, timeout=5)
        type_command(client, "desktop")
        wait_debug(process, captured, DESKTOP_READY, 1, timeout=35)
        wait_debug(process, captured, DESKTOP_CLIENT, 1, timeout=5)

        client.hmp(f'screendump "{screenshot}"')
        width, height, pixels = ppm_size(screenshot)
        if (width, height) != (1280, 800):
            raise AssertionError(f"ожидался VBE 1280x800, получен {width}x{height}")
        # Wallpaper обязан содержать множество цветов, а не быть blank mode.
        sample = pixels[:: max(3, len(pixels) // 5000)]
        if len(set(sample)) < 24:
            raise AssertionError("framebuffer выглядит одноцветным или пустым")
        keep_screenshot = os.environ.get("VARANIA_GUI_SCREENSHOT")
        if keep_screenshot:
            shutil.copyfile(screenshot, keep_screenshot)

        # Pointer начинается в центре (640,400). Открываем Start и Terminal.
        move_mouse(client, -580, 370)  # Start: ~60,770
        click(client)
        move_mouse(client, 40, -135)   # menu Terminal: ~100,635
        click(client)
        wait_debug(process, captured, GTERM_WINDOW, 1, timeout=15)
        wait_debug(process, captured, GTERM_READY, 1, timeout=15)
        wait_debug(process, captured, SHELL_READY, 2, timeout=15)
        wait_debug(process, captured, PROMPT_READY, 2, timeout=10)

        # Запускаем UI client, сворачиваем terminal и кликаем server-side
        # checkbox/button. Это проверяет ownership, state и reply capability.
        type_command(client, "cd bin")
        wait_debug(process, captured, PROMPT_READY, 3, timeout=10)
        type_command(client, "run guidemo.elf")
        wait_debug(process, captured, GUI_DEMO_READY, 1, timeout=15)
        move_mouse(client, 976, -538)   # normal minimize button: ~1076,97
        click(client)
        move_mouse(client, -616, 232)   # checkbox: ~460,329
        click(client)
        wait_debug(process, captured, UI_STATE_OK, 1, timeout=10)
        move_mouse(client, 55, 60)      # close demo button: ~515,389
        click(client)
        wait_debug(process, captured, UI_EVENT_OK, 1, timeout=10)
        wait_debug(process, captured, PROMPT_READY, 4, timeout=10)

        # Restore -> maximize -> restore -> close.
        move_mouse(client, -315, 381)   # terminal task button: ~200,770
        click(client)
        move_mouse(client, 910, -673)   # normal maximize button: ~1110,97
        click(client)
        move_mouse(client, 120, -85)    # maximized restore button: ~1230,12
        click(client)
        move_mouse(client, -85, 85)     # normal close button: ~1145,97
        click(client)
        wait_debug(process, captured, GTERM_CLOSED, 1, timeout=15)

        # Второй terminal запускаем именно double click системного ярлыка.
        move_mouse(client, -1077, -22)  # Terminal shortcut: ~68,75
        click(client)
        click(client)
        wait_debug(process, captured, GTERM_WINDOW, 2, timeout=15)
        wait_debug(process, captured, GTERM_READY, 2, timeout=15)
        wait_debug(process, captured, SHELL_READY, 3, timeout=15)
        move_mouse(client, 1077, 22)    # close button: ~1145,97
        click(client)
        wait_debug(process, captured, GTERM_CLOSED, 2, timeout=15)
    except (AssertionError, OSError, RuntimeError, TimeoutError) as error:
        print(bytes(captured).decode("utf-8", errors="replace"), end="")
        print(f"ОШИБКА: GUI-тест не пройден: {error}", file=sys.stderr)
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
    print("GUI-тест пройден: VBE, desktop, double click, widgets и WM controls работают.")


if __name__ == "__main__":
    main()
