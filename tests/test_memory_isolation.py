#!/usr/bin/env python3
"""Отдельно проверить multi-page memory, stack/heap и изоляцию HHDM."""

import sys

from qemu_testlib import boot_until


MARKERS = (
    b"VARANIA:MEMORY_OK",
    b"isolation-test: probing supervisor HHDM",
    b"terminated user task",
    b"VARANIA:ISOLATION_OK",
)


def main() -> None:
    try:
        output = boot_until(MARKERS)
    except (RuntimeError, TimeoutError) as error:
        print(f"ОШИБКА: {error}", file=sys.stderr)
        raise SystemExit(1)
    print(output.decode("utf-8", errors="replace"), end="")
    print("Тест памяти пройден: multi-page ELF/BSS, heap, growing stack и HHDM isolation.")


if __name__ == "__main__":
    main()
