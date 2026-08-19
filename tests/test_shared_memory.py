#!/usr/bin/env python3
"""Проверить передачу и двустороннее изменение shared-memory object."""

import sys

from qemu_testlib import boot_until


def main() -> None:
    try:
        output = boot_until((b"VARANIA:SHM_OK", b"VARANIA:MICROKERNEL_OK"))
    except (RuntimeError, TimeoutError) as error:
        print(f"ОШИБКА: {error}", file=sys.stderr)
        raise SystemExit(1)
    print(output.decode("utf-8", errors="replace"), end="")
    print("Shared-memory тест пройден: две страницы разделяются процессами и освобождаются по refcount.")


if __name__ == "__main__":
    main()
