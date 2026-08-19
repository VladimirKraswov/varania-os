#!/usr/bin/env python3
"""End-to-end: shell -> VEdit -> libvarania -> FASM -> новый ELF."""

from __future__ import annotations

from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile
import time

from test_shell import (
    QmpClient, changed_pixels, connect_qmp, read_framebuffer, type_command,
    wait_debug,
)


ROOT = Path(__file__).resolve().parents[1]
IMAGE = ROOT / "VOS.VHD"
NVME_IMAGE = ROOT / "VARANIA.VAFS"
SHELL_READY = b"VARANIA:SHELL_READY"
PROMPT_READY = b"VARANIA:SHELL_PROMPT_READY"
EDITOR_READY = b"VARANIA:EDITOR_READY"
EDITOR_TEMPLATE = b"VARANIA:EDITOR_TEMPLATE_INSERTED"
EDITOR_SAVED = b"VARANIA:EDITOR_SAVED"
EDITOR_BUILD = b"VARANIA:EDITOR_BUILD_OK"
EDITOR_RUN = b"VARANIA:EDITOR_RUN_OK"
EDITOR_EXIT = b"VARANIA:EDITOR_EXIT"
TEMPLATE_OK = b"VARANIA:EDITOR_TEMPLATE_OK"
CD_OK = b"VARANIA:SHELL_CD_OK"
RUN_OK = b"VARANIA:SHELL_RUN_OK"
SYSINFO_OK = b"VARANIA:SYSINFO_OK"
HANG_READY = b"VARANIA:HANG_READY"
FOREGROUND_INTERRUPTED = b"VARANIA:FOREGROUND_INTERRUPTED"
SHELL_INTERRUPT_OK = b"VARANIA:SHELL_INTERRUPT_OK"
LS_OK = b"VARANIA:SHELL_LS_OK"


def press(qmp: QmpClient, key: str) -> None:
    qmp.hmp(f"sendkey {key} 40")
    time.sleep(0.08)


def press_burst(qmp: QmpClient, key: str, count: int) -> None:
    """Быстрый autorepeat: нагрузить terminal одновременно с DRAW."""
    for _ in range(count):
        qmp.hmp(f"sendkey {key} 5")
        time.sleep(0.012)


def framebuffer_colours(pixels: bytes) -> set[bytes]:
    return {pixels[index:index + 3] for index in range(0, len(pixels), 3)}


def has_repeated_terminal_cells(
    pixels: bytes, width: int, height: int, expected_run: int,
) -> bool:
    """Найти строку одинаковых непустых glyph cells в VBE terminal view."""
    # Эти размеры являются частью текущего GUI ABI 1 layout и совпадают с
    # TERM_COLS/ROWS/CELL_W/CELL_H в gui.asm.
    cell_width, cell_height = 12, 18
    columns, rows = 80, 25
    origin_x = (width - columns * cell_width) // 2
    origin_y = (height - rows * cell_height) // 2
    if origin_x < 0 or origin_y < 0:
        return False

    for row in range(rows):
        previous: bytes | None = None
        run = 0
        for column in range(columns):
            chunks = []
            x = origin_x + column * cell_width
            y = origin_y + row * cell_height
            for pixel_y in range(y, y + cell_height):
                begin = (pixel_y * width + x) * 3
                chunks.append(pixels[begin:begin + cell_width * 3])
            pattern = b"".join(chunks)
            colours = {
                pattern[index:index + 3]
                for index in range(0, len(pattern), 3)
            }
            visible = len(colours) > 1
            if visible and pattern == previous:
                run += 1
            elif visible:
                run = 1
            else:
                run = 0
            previous = pattern if visible else None
            if run >= expected_run:
                return True
    return False


def remove_guest_file(path: str) -> None:
    subprocess.run(
        [sys.executable, str(ROOT / "tools/vafs/vafs.py"), "rm",
         str(NVME_IMAGE), path],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
    )


def extract_guest_file(path: str, destination: Path) -> bytes:
    result = subprocess.run(
        [sys.executable, str(ROOT / "tools/vafs/vafs.py"), "get",
         str(NVME_IMAGE), path, str(destination)],
        capture_output=True, text=True, check=False,
    )
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return destination.read_bytes()


def main() -> None:
    qemu_name = os.environ.get("QEMU_BIN", "qemu-system-x86_64")
    qemu = shutil.which(qemu_name)
    if qemu is None:
        print(f"ОШИБКА: не найден {qemu_name}", file=sys.stderr)
        raise SystemExit(1)

    source_path = "/system/build/editortest.asm"
    output_path = "/system/build/editortest.elf"
    remove_guest_file(source_path)
    remove_guest_file(output_path)

    temporary = Path(tempfile.mkdtemp(prefix="varania-editor-", dir="/tmp"))
    qmp_path = temporary / "qmp.sock"
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
        wait_debug(process, captured, SHELL_READY, 1)
        wait_debug(process, captured, PROMPT_READY, 1)
        type_command(client, f"edit {source_path}")
        wait_debug(process, captured, EDITOR_READY, 1)

        press(client, "f7")
        wait_debug(process, captured, EDITOR_TEMPLATE, 1)
        time.sleep(0.1)
        width, height, editor_pixels = read_framebuffer(
            client, temporary, "editor-template"
        )
        if (width, height) != (1280, 800):
            raise AssertionError(f"ожидался VBE 1280x800, получен {width}x{height}")
        # Точные RGB берутся из VGA-compatible palette GUI: blue/green/yellow.
        syntax_colours = {b"\x58\xA6\xFF", b"\x75\xD6\x9C", b"\xFF\xC8\x57"}
        visible_colours = framebuffer_colours(editor_pixels)
        if len(syntax_colours & visible_colours) < 2:
            raise AssertionError("на VBE framebuffer нет цветной syntax highlighting")

        # Регрессия: editor_insert_byte получает символ в DIL, а для сдвига
        # хвоста использует RDI. Раньше адрес затирал DIL, и одна клавиша
        # вставляла разные байты при вводе внутри (не в конце) документа.
        press(client, "up")       # последняя строка шаблона: .size = ...
        press(client, "home")
        repeat_count = 12
        press_burst(client, "a", repeat_count)
        time.sleep(0.15)
        _, _, repeated_pixels = read_framebuffer(client, temporary, "repeated-key")
        if not has_repeated_terminal_cells(
            repeated_pixels, width, height, repeat_count
        ):
            raise AssertionError(
                "быстрый повтор клавиши потерян или дал разные glyph cells"
            )
        for _ in range(repeat_count):
            press(client, "backspace")

        _, _, before_debug = read_framebuffer(client, temporary, "before-debug")
        press(client, "f2")
        time.sleep(0.1)
        _, _, debug_pixels = read_framebuffer(client, temporary, "debug-mode")
        if changed_pixels(before_debug, debug_pixels) < 100:
            raise AssertionError("F2 не изменил видимый debug panel")

        press(client, "ctrl-s")
        wait_debug(process, captured, EDITOR_SAVED, 1)
        # Маркер сохранения появляется до возврата VEdit в TERM_READKEY.
        # Не посылаем F5 в короткое окно, где terminal ещё не принял waiter.
        time.sleep(0.25)
        press(client, "f5")
        wait_debug(process, captured, EDITOR_BUILD, 1, timeout=20)
        # Marker печатается перед следующим полным render/read-key cycle.
        # Человеческий ввод всегда медленнее; тест явно ждёт эту границу.
        time.sleep(0.25)
        press(client, "f6")
        wait_debug(process, captured, TEMPLATE_OK, 1)
        wait_debug(process, captured, EDITOR_RUN, 1)
        press(client, "ctrl-q")
        wait_debug(process, captured, EDITOR_EXIT, 1)
        wait_debug(process, captured, PROMPT_READY, 2)

        # Ещё одна программа поверх libvarania подтверждает, что API не
        # завязан только на внутренние состояния редактора.
        type_command(client, "cd bin")
        wait_debug(process, captured, CD_OK, 1)
        wait_debug(process, captured, PROMPT_READY, 3)
        type_command(client, "run sysinfo.elf")
        wait_debug(process, captured, SYSINFO_OK, 1)
        wait_debug(process, captured, RUN_OK, 2)  # edit.elf + sysinfo.elf
        wait_debug(process, captured, PROMPT_READY, 4)

        # Shell уже заблокирован в WAIT и не может сам обработать Ctrl+C.
        # Terminal сообщает sessiond, тот завершает foreground по CONTROL cap,
        # после чего shell снова показывает prompt и продолжает работать.
        type_command(client, "run hang.elf")
        wait_debug(process, captured, HANG_READY, 1)
        press(client, "ctrl-c")
        wait_debug(process, captured, FOREGROUND_INTERRUPTED, 1)
        wait_debug(process, captured, SHELL_INTERRUPT_OK, 1)
        wait_debug(process, captured, PROMPT_READY, 5)
        type_command(client, "ls")
        wait_debug(process, captured, LS_OK, 1)
        wait_debug(process, captured, PROMPT_READY, 6)
    except (AssertionError, OSError, RuntimeError, TimeoutError) as error:
        if client is not None:
            try:
                read_framebuffer(client, temporary, "failure")
                print(f"\nFramebuffer snapshot: {temporary / 'failure.ppm'}")
            except (OSError, RuntimeError):
                pass
        print(bytes(captured).decode("utf-8", errors="replace"), end="")
        print(f"ОШИБКА: VEdit тест не пройден: {error}", file=sys.stderr)
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

    source = extract_guest_file(source_path, temporary / "editor_test.asm")
    output = extract_guest_file(output_path, temporary / "editor_test.elf")
    fsck = subprocess.run(
        [sys.executable, str(ROOT / "tools/vafs/vafs.py"), "fsck",
         str(NVME_IMAGE), "--data"], capture_output=True, text=True,
    )
    shutil.rmtree(temporary, ignore_errors=True)
    if (fsck.returncode or b"format ELF64 executable 3" not in source
            or not output.startswith(b"\x7fELF\x02\x01\x01")):
        print(fsck.stdout + fsck.stderr, end="")
        print("ОШИБКА: исходник/ELF редактора не пережил remount", file=sys.stderr)
        raise SystemExit(1)

    print(bytes(captured).decode("utf-8", errors="replace"), end="")
    print("VEdit-тест пройден: burst keyboard, build/run, Ctrl+C supervisor и VaraniaFS работают.")


if __name__ == "__main__":
    main()
