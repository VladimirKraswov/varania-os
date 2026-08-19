#!/usr/bin/env python3
"""Отдельно проверить create → exit → wait → teardown → reuse."""

import sys

from qemu_testlib import boot_until


MARKERS = (b"VARANIA:LIFECYCLE_OK", b"VARANIA:MICROKERNEL_OK")


def main() -> None:
    try:
        output = boot_until(MARKERS)
    except (RuntimeError, TimeoutError) as error:
        print(f"ОШИБКА: {error}", file=sys.stderr)
        raise SystemExit(1)
    print(output.decode("utf-8", errors="replace"), end="")
    print("Lifecycle-тест пройден: slot reuse и возврат всех process frames подтверждены.")


if __name__ == "__main__":
    main()
