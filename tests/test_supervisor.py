#!/usr/bin/env python3
"""Проверить внешний kill заблокированного процесса и restart policy."""

import sys

from qemu_testlib import boot_until


def main() -> None:
    markers = (b"VARANIA:KILL_OK", b"VARANIA:SUPERVISOR_OK", b"VARANIA:MICROKERNEL_OK")
    try:
        output = boot_until(markers)
    except (RuntimeError, TimeoutError) as error:
        print(f"ОШИБКА: {error}", file=sys.stderr)
        raise SystemExit(1)
    print(output.decode("utf-8", errors="replace"), end="")
    print("Supervisor-тест пройден: blocked process завершён извне, сервис перезапущен дважды.")


if __name__ == "__main__":
    main()
