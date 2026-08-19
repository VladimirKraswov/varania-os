#!/usr/bin/env python3
"""Собрать минимальный детерминированный initramfs Varania OS.

Формат специально не притворяется полноценной файловой системой. Ядру на
раннем этапе нужны только имена и неизменяемые диапазоны байтов с ELF-файлами.
Все числа little-endian, таблица имеет фиксированные записи по 48 байт.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import struct


MAGIC = b"VARNIR01"
VERSION = 1
HEADER = struct.Struct("<8sIIII")
ENTRY = struct.Struct("<32sIIII")
ALIGNMENT = 16


def align_up(value: int, alignment: int = ALIGNMENT) -> int:
    return (value + alignment - 1) & -alignment


def parse_file(specification: str) -> tuple[str, Path]:
    try:
        name, path = specification.split("=", 1)
    except ValueError as error:
        raise argparse.ArgumentTypeError("ожидалось имя=путь") from error
    encoded = name.encode("ascii", errors="strict")
    if not encoded or len(encoded) >= 32 or b"/" in encoded:
        raise argparse.ArgumentTypeError("имя должно занимать 1..31 ASCII-байт без '/'")
    return name, Path(path)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--size", type=int, required=True, help="фиксированный размер архива")
    parser.add_argument("output", type=Path)
    parser.add_argument("files", nargs="+", type=parse_file, metavar="NAME=PATH")
    args = parser.parse_args()

    if len({name for name, _ in args.files}) != len(args.files):
        parser.error("имена файлов должны быть уникальны")

    payloads = [(name, path.read_bytes()) for name, path in args.files]
    data_offset = align_up(HEADER.size + ENTRY.size * len(payloads))
    entries: list[tuple[str, int, bytes]] = []
    cursor = data_offset
    for name, payload in payloads:
        entries.append((name, cursor, payload))
        cursor = align_up(cursor + len(payload))

    if cursor > args.size:
        parser.error(f"файлы требуют {cursor} байт, архив ограничен {args.size}")

    image = bytearray(args.size)
    image[: HEADER.size] = HEADER.pack(MAGIC, VERSION, len(entries), cursor, 0)
    for index, (name, offset, payload) in enumerate(entries):
        encoded = name.encode("ascii") + b"\0"
        entry_at = HEADER.size + index * ENTRY.size
        image[entry_at : entry_at + ENTRY.size] = ENTRY.pack(
            encoded.ljust(32, b"\0"), offset, len(payload), 0, 0
        )
        image[offset : offset + len(payload)] = payload

    args.output.write_bytes(image)
    print(f"initramfs: {len(entries)} файлов, {cursor} значащих байт, {args.size} байт в образе")


if __name__ == "__main__":
    main()
