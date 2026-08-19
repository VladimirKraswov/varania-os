#!/usr/bin/env python3
"""Проверить рекурсивный revoke производных capabilities."""

import sys

from qemu_testlib import boot_until


def main() -> None:
    try:
        output = boot_until((b"VARANIA:REVOKE_OK", b"VARANIA:MICROKERNEL_OK"))
    except (RuntimeError, TimeoutError) as error:
        print(f"ОШИБКА: {error}", file=sys.stderr)
        raise SystemExit(1)
    print(output.decode("utf-8", errors="replace"), end="")
    print("Revoke-тест пройден: все descendants закрыты, корневая capability сохранена.")


if __name__ == "__main__":
    main()
