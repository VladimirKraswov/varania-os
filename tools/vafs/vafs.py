#!/usr/bin/env python3
"""Host-утилита VaraniaFS для macOS и Linux.

Утилита не знает ничего о формате ELF или сборке ОС. Она читает и
изменяет ровно тот же on-disk формат, который использует ring-3
сервер VaraniaFS. Зависимостей, кроме Python 3, нет.

Порядок commit:
  1. записать новые data extents;
  2. записать новое COW B+-дерево каталога;
  3. fsync;
  4. перезаписать более старую копию superblock;
  5. fsync.

Поэтому обрыв в любой точке оставляет хотя бы одно полное поколение.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass, replace
import fnmatch
import fcntl
import os
from pathlib import Path, PurePosixPath
import struct
import sys
import time
import uuid
from typing import BinaryIO, Iterable, Iterator


BLOCK_SIZE = 4096
BLOCK_SHIFT = 12
VAFS_VERSION = 1
SUPER_MAGIC = b"VAFS\0\0\1\0"
NODE_MAGIC = b"VBTN"

FEATURE_COW = 1 << 0
FEATURE_CRC32C = 1 << 1
FEATURE_CASE_SENSITIVE = 1 << 2
FEATURE_NO_PERMISSIONS = 1 << 3
REQUIRED_FEATURES = (
    FEATURE_COW
    | FEATURE_CRC32C
    | FEATURE_CASE_SENSITIVE
    | FEATURE_NO_PERMISSIONS
)

DEVICE_AUTO = 0
DEVICE_ROTATIONAL = 1
DEVICE_SOLID_STATE = 2
DEVICE_NAMES = {
    DEVICE_AUTO: "auto",
    DEVICE_ROTATIONAL: "hdd",
    DEVICE_SOLID_STATE: "ssd",
}
DEVICE_VALUES = {value: key for key, value in DEVICE_NAMES.items()}

ENTRY_FILE = 1
ENTRY_DIRECTORY = 2
ENTRY_NAMES = {ENTRY_FILE: "file", ENTRY_DIRECTORY: "directory"}

MAX_PATH_BYTES = 1024
MAX_COMPONENT_BYTES = 255

SUPER = struct.Struct("<8sIIQ16sQQQIIQQQIII")
SUPER_CHECKSUM_OFFSET = SUPER.size - 4
NODE = struct.Struct("<4sHHQQIII28s")
NODE_CHECKSUM_OFFSET = 28
ENTRY = struct.Struct("<HHBBHQQQII")
EXTENT = struct.Struct("<QQII")
INTERNAL = struct.Struct("<HHQ")


class VafsError(RuntimeError):
    """Ожидаемая ошибка формата или команды."""


def align_up(value: int, alignment: int) -> int:
    return (value + alignment - 1) & -alignment


def parse_size(text: str) -> int:
    """Разобрать 4096, 0x1000, 128M, 1G и 2T."""
    normalized = text.strip().upper()
    multipliers = {"K": 1 << 10, "M": 1 << 20, "G": 1 << 30, "T": 1 << 40}
    multiplier = 1
    if normalized and normalized[-1] in multipliers:
        multiplier = multipliers[normalized[-1]]
        normalized = normalized[:-1]
    try:
        value = int(normalized, 0) * multiplier
    except ValueError as error:
        raise argparse.ArgumentTypeError(f"неверный размер: {text}") from error
    if value < 0:
        raise argparse.ArgumentTypeError("размер не может быть отрицательным")
    return value


def format_size(value: int) -> str:
    for suffix, unit in (("TiB", 1 << 40), ("GiB", 1 << 30), ("MiB", 1 << 20), ("KiB", 1 << 10)):
        if value >= unit and value % unit == 0:
            return f"{value // unit} {suffix}"
    return f"{value} B"


def normalize_path(raw: str) -> str:
    if not raw:
        raise VafsError("путь пуст")
    if "\0" in raw:
        raise VafsError("в пути нельзя использовать NUL")
    if not raw.startswith("/"):
        raw = "/" + raw
    parts: list[str] = []
    for component in PurePosixPath(raw).parts:
        if component in ("/", "", "."):
            continue
        if component == "..":
            if not parts:
                raise VafsError("путь выходит выше корня")
            parts.pop()
            continue
        encoded = component.encode("utf-8")
        if len(encoded) > MAX_COMPONENT_BYTES:
            raise VafsError(f"компонент длиннее {MAX_COMPONENT_BYTES} UTF-8 байт")
        parts.append(component)
    result = "/" + "/".join(parts)
    if len(result.encode("utf-8")) > MAX_PATH_BYTES:
        raise VafsError(f"путь длиннее {MAX_PATH_BYTES} UTF-8 байт")
    return result


def parent_path(path: str) -> str:
    if path == "/":
        return "/"
    parent = str(PurePosixPath(path).parent)
    return "/" if parent == "." else parent


def path_key(path: str) -> bytes:
    return path.encode("utf-8")


def _crc32c_table() -> tuple[int, ...]:
    polynomial = 0x82F63B78
    result = []
    for byte in range(256):
        value = byte
        for _ in range(8):
            value = (value >> 1) ^ (polynomial if value & 1 else 0)
        result.append(value & 0xFFFFFFFF)
    return tuple(result)


CRC32C_TABLE = _crc32c_table()


def crc32c(data: bytes | bytearray | memoryview, previous: int = 0) -> int:
    """CRC32C Castagnoli; previous позволяет считать поток по частям."""
    value = previous ^ 0xFFFFFFFF
    for byte in data:
        value = CRC32C_TABLE[(value ^ byte) & 0xFF] ^ (value >> 8)
    return value ^ 0xFFFFFFFF


@dataclass(frozen=True)
class Extent:
    logical_block: int
    physical_block: int
    block_count: int


@dataclass(frozen=True)
class CatalogEntry:
    path: str
    kind: int
    object_id: int
    size: int = 0
    mtime_ns: int = 0
    data_crc32c: int = 0
    extents: tuple[Extent, ...] = ()


@dataclass(frozen=True)
class Superblock:
    generation: int
    volume_uuid: uuid.UUID
    total_blocks: int
    features: int
    catalog_root: int
    catalog_height: int
    next_object_id: int
    alloc_cursor: int
    root_object_id: int
    device_class: int
    clean: int = 1

    def encode(self) -> bytes:
        block = bytearray(BLOCK_SIZE)
        SUPER.pack_into(
            block,
            0,
            SUPER_MAGIC,
            VAFS_VERSION,
            BLOCK_SIZE,
            self.generation,
            self.volume_uuid.bytes,
            self.total_blocks,
            self.features,
            self.catalog_root,
            self.catalog_height,
            0,
            self.next_object_id,
            self.alloc_cursor,
            self.root_object_id,
            self.device_class,
            self.clean,
            0,
        )
        struct.pack_into("<I", block, SUPER_CHECKSUM_OFFSET, crc32c(block))
        return bytes(block)

    @classmethod
    def decode(cls, block: bytes, expected_blocks: int) -> "Superblock":
        if len(block) != BLOCK_SIZE:
            raise VafsError("superblock обрезан")
        fields = SUPER.unpack_from(block)
        (
            magic,
            version,
            block_size,
            generation,
            raw_uuid,
            total_blocks,
            features,
            catalog_root,
            catalog_height,
            reserved,
            next_object_id,
            alloc_cursor,
            root_object_id,
            device_class,
            clean,
            checksum,
        ) = fields
        verification = bytearray(block)
        struct.pack_into("<I", verification, SUPER_CHECKSUM_OFFSET, 0)
        if magic != SUPER_MAGIC or version != VAFS_VERSION:
            raise VafsError("неверные magic/version superblock")
        if block_size != BLOCK_SIZE:
            raise VafsError(f"неподдерживаемый block size {block_size}")
        if checksum != crc32c(verification):
            raise VafsError("не совпал CRC32C superblock")
        if reserved or total_blocks != expected_blocks:
            raise VafsError("неверный размер тома или reserved поле")
        if features & REQUIRED_FEATURES != REQUIRED_FEATURES:
            raise VafsError("том не содержит обязательные VaraniaFS features")
        if not 1 <= catalog_root < total_blocks - 1:
            raise VafsError("корень каталога вне тома")
        if not catalog_root < alloc_cursor <= total_blocks - 1:
            raise VafsError("неверный allocation cursor")
        if catalog_height > 15 or root_object_id == 0 or next_object_id <= root_object_id:
            raise VafsError("неверные catalog/object поля")
        if device_class not in DEVICE_NAMES or clean not in (0, 1):
            raise VafsError("неверные device/clean поля")
        return cls(
            generation=generation,
            volume_uuid=uuid.UUID(bytes=raw_uuid),
            total_blocks=total_blocks,
            features=features,
            catalog_root=catalog_root,
            catalog_height=catalog_height,
            next_object_id=next_object_id,
            alloc_cursor=alloc_cursor,
            root_object_id=root_object_id,
            device_class=device_class,
            clean=clean,
        )


def encode_catalog_entry(entry: CatalogEntry) -> bytes:
    raw_path = path_key(entry.path)
    if not raw_path or len(raw_path) > MAX_PATH_BYTES:
        raise VafsError(f"неверная длина пути {entry.path!r}")
    if entry.kind == ENTRY_DIRECTORY and (entry.size or entry.extents or entry.data_crc32c):
        raise VafsError(f"каталог {entry.path!r} имеет файловые поля")
    if entry.kind not in ENTRY_NAMES:
        raise VafsError(f"неизвестный тип entry {entry.kind}")
    extent_bytes = b"".join(
        EXTENT.pack(extent.logical_block, extent.physical_block, extent.block_count, 0)
        for extent in entry.extents
    )
    record_bytes = align_up(ENTRY.size + len(extent_bytes) + len(raw_path), 8)
    if record_bytes > BLOCK_SIZE - NODE.size:
        raise VafsError(f"запись {entry.path!r} не помещается в блок")
    result = bytearray(record_bytes)
    ENTRY.pack_into(
        result,
        0,
        record_bytes,
        len(raw_path),
        entry.kind,
        0,
        len(entry.extents),
        entry.object_id,
        entry.size,
        entry.mtime_ns,
        entry.data_crc32c,
        0,
    )
    result[ENTRY.size : ENTRY.size + len(extent_bytes)] = extent_bytes
    path_at = ENTRY.size + len(extent_bytes)
    result[path_at : path_at + len(raw_path)] = raw_path
    return bytes(result)


def decode_catalog_entry(record: bytes, total_blocks: int) -> CatalogEntry:
    if len(record) < ENTRY.size:
        raise VafsError("короткая catalog entry")
    (
        record_bytes,
        path_bytes,
        kind,
        flags,
        extent_count,
        object_id,
        size,
        mtime_ns,
        data_checksum,
        reserved,
    ) = ENTRY.unpack_from(record)
    minimum = ENTRY.size + extent_count * EXTENT.size + path_bytes
    if record_bytes != len(record) or record_bytes % 8 or minimum > record_bytes:
        raise VafsError("неверная длина catalog entry")
    if flags or reserved or object_id == 0 or kind not in ENTRY_NAMES:
        raise VafsError("неверные catalog entry flags/type/object")
    extents: list[Extent] = []
    cursor = ENTRY.size
    expected_logical = 0
    for _ in range(extent_count):
        logical, physical, blocks, extent_reserved = EXTENT.unpack_from(record, cursor)
        cursor += EXTENT.size
        if extent_reserved or not blocks or logical != expected_logical:
            raise VafsError("повреждённая последовательность extents")
        if physical < 1 or physical + blocks > total_blocks - 1:
            raise VafsError("extent выходит за границы тома")
        extents.append(Extent(logical, physical, blocks))
        expected_logical += blocks
    raw_path = record[cursor : cursor + path_bytes]
    try:
        path = raw_path.decode("utf-8")
    except UnicodeDecodeError as error:
        raise VafsError("путь entry не является UTF-8") from error
    if normalize_path(path) != path:
        raise VafsError(f"неканонический путь {path!r}")
    if kind == ENTRY_DIRECTORY and (size or extent_count or data_checksum):
        raise VafsError(f"каталог {path!r} имеет данные")
    required_blocks = (size + BLOCK_SIZE - 1) // BLOCK_SIZE
    if kind == ENTRY_FILE and expected_logical != required_blocks:
        raise VafsError(f"extents файла {path!r} не покрывают его размер")
    return CatalogEntry(path, kind, object_id, size, mtime_ns, data_checksum, tuple(extents))


def encode_internal_record(max_key: bytes, child_block: int) -> bytes:
    record_bytes = align_up(INTERNAL.size + len(max_key), 8)
    if record_bytes > BLOCK_SIZE - NODE.size:
        raise VafsError("ключ internal node слишком длинный")
    result = bytearray(record_bytes)
    INTERNAL.pack_into(result, 0, record_bytes, len(max_key), child_block)
    result[INTERNAL.size : INTERNAL.size + len(max_key)] = max_key
    return bytes(result)


def decode_internal_record(record: bytes, total_blocks: int) -> tuple[bytes, int]:
    if len(record) < INTERNAL.size:
        raise VafsError("короткая internal entry")
    record_bytes, key_bytes, child = INTERNAL.unpack_from(record)
    if record_bytes != len(record) or record_bytes % 8 or INTERNAL.size + key_bytes > record_bytes:
        raise VafsError("неверная internal entry")
    if not 1 <= child < total_blocks - 1:
        raise VafsError("child B+-дерева вне тома")
    return record[INTERNAL.size : INTERNAL.size + key_bytes], child


def pack_node(level: int, generation: int, next_leaf: int, records: list[bytes]) -> bytes:
    payload = b"".join(records)
    used = NODE.size + len(payload)
    if not records or used > BLOCK_SIZE:
        raise VafsError("неверное наполнение B+-узла")
    block = bytearray(BLOCK_SIZE)
    NODE.pack_into(block, 0, NODE_MAGIC, level, len(records), generation, next_leaf, used, 0, 0, bytes(28))
    block[NODE.size:used] = payload
    struct.pack_into("<I", block, NODE_CHECKSUM_OFFSET, crc32c(block))
    return bytes(block)


def split_records(records: list[tuple[bytes, bytes]]) -> list[list[tuple[bytes, bytes]]]:
    groups: list[list[tuple[bytes, bytes]]] = []
    current: list[tuple[bytes, bytes]] = []
    used = NODE.size
    for key, encoded in records:
        if len(encoded) + NODE.size > BLOCK_SIZE:
            raise VafsError(f"запись ключа {key!r} больше блока")
        if current and used + len(encoded) > BLOCK_SIZE:
            groups.append(current)
            current = []
            used = NODE.size
        current.append((key, encoded))
        used += len(encoded)
    if current:
        groups.append(current)
    return groups


def build_catalog(
    entries: Iterable[CatalogEntry], generation: int, cursor: int, total_blocks: int
) -> tuple[int, int, int, dict[int, bytes]]:
    ordered = sorted(entries, key=lambda entry: path_key(entry.path))
    if not ordered:
        raise VafsError("каталог не может быть пустым")
    leaf_items = [(path_key(entry.path), encode_catalog_entry(entry)) for entry in ordered]
    leaf_groups = split_records(leaf_items)
    if cursor + len(leaf_groups) > total_blocks - 1:
        raise VafsError("нет места для catalog leaves")
    blocks: dict[int, bytes] = {}
    descriptors: list[tuple[bytes, int]] = []
    leaf_ids = list(range(cursor, cursor + len(leaf_groups)))
    cursor += len(leaf_groups)
    for index, group in enumerate(leaf_groups):
        block_id = leaf_ids[index]
        next_leaf = leaf_ids[index + 1] if index + 1 < len(leaf_ids) else 0
        blocks[block_id] = pack_node(0, generation, next_leaf, [encoded for _, encoded in group])
        descriptors.append((group[-1][0], block_id))

    level = 0
    while len(descriptors) > 1:
        level += 1
        internal_items = [(key, encode_internal_record(key, child)) for key, child in descriptors]
        groups = split_records(internal_items)
        if cursor + len(groups) > total_blocks - 1:
            raise VafsError("нет места для internal B+-nodes")
        descriptors = []
        for group in groups:
            block_id = cursor
            cursor += 1
            blocks[block_id] = pack_node(level, generation, 0, [encoded for _, encoded in group])
            descriptors.append((group[-1][0], block_id))
    return descriptors[0][1], level, cursor, blocks


class Volume:
    def __init__(self, image: Path, offset: int, writable: bool = False):
        self.image = image
        self.offset = offset
        self.writable = writable
        mode = "r+b" if writable else "rb"
        self.file: BinaryIO = image.open(mode)
        fcntl.flock(self.file.fileno(), fcntl.LOCK_EX if writable else fcntl.LOCK_SH)
        image_size = os.fstat(self.file.fileno()).st_size
        if offset < 0 or offset % BLOCK_SIZE:
            self.close()
            raise VafsError("смещение VaraniaFS должно быть кратно 4096")
        if image_size - offset < 3 * BLOCK_SIZE or (image_size - offset) % BLOCK_SIZE:
            self.close()
            raise VafsError("область VaraniaFS слишком мала или не кратна 4096")
        self.total_blocks = (image_size - offset) // BLOCK_SIZE
        self.superblocks = self._read_superblocks()
        if not self.superblocks:
            self.close()
            raise VafsError("не найдено ни одной целой копии superblock")
        self.active_slot, self.superblock = max(
            self.superblocks.items(), key=lambda item: (item[1].generation, -item[0])
        )

    def __enter__(self) -> "Volume":
        return self

    def __exit__(self, exc_type: object, exc: object, traceback: object) -> None:
        self.close()

    def close(self) -> None:
        if not self.file.closed:
            fcntl.flock(self.file.fileno(), fcntl.LOCK_UN)
            self.file.close()

    def _absolute(self, block: int) -> int:
        if not 0 <= block < self.total_blocks:
            raise VafsError(f"блок {block} вне тома")
        return self.offset + block * BLOCK_SIZE

    def read_block(self, block: int) -> bytes:
        self.file.seek(self._absolute(block))
        data = self.file.read(BLOCK_SIZE)
        if len(data) != BLOCK_SIZE:
            raise VafsError(f"не удалось прочитать блок {block}")
        return data

    def write_block(self, block: int, data: bytes) -> None:
        if not self.writable:
            raise VafsError("том открыт только для чтения")
        if len(data) != BLOCK_SIZE:
            raise VafsError("запись блока должна иметь ровно 4096 байт")
        self.file.seek(self._absolute(block))
        self.file.write(data)

    def _read_superblocks(self) -> dict[int, Superblock]:
        found: dict[int, Superblock] = {}
        for slot in (0, self.total_blocks - 1):
            try:
                found[slot] = Superblock.decode(self.read_block(slot), self.total_blocks)
            except VafsError:
                pass
        return found

    def _read_node(self, block_id: int, expected_generation: int) -> tuple[int, int, list[bytes]]:
        raw = self.read_block(block_id)
        if len(raw) != BLOCK_SIZE:
            raise VafsError("B+-node обрезан")
        magic, level, count, generation, next_leaf, used, checksum, flags, reserved = NODE.unpack_from(raw)
        verification = bytearray(raw)
        struct.pack_into("<I", verification, NODE_CHECKSUM_OFFSET, 0)
        if magic != NODE_MAGIC or generation != expected_generation:
            raise VafsError(f"неверный B+-node {block_id}: magic/generation")
        if checksum != crc32c(verification):
            raise VafsError(f"не совпал CRC32C B+-node {block_id}")
        if flags or any(reserved) or not count or not NODE.size < used <= BLOCK_SIZE:
            raise VafsError(f"неверные поля B+-node {block_id}")
        if level and next_leaf:
            raise VafsError("internal node имеет next_leaf")
        if next_leaf and not 1 <= next_leaf < self.total_blocks - 1:
            raise VafsError("next_leaf вне тома")
        records: list[bytes] = []
        cursor = NODE.size
        for _ in range(count):
            if cursor + 2 > used:
                raise VafsError(f"обрезана запись B+-node {block_id}")
            record_bytes = struct.unpack_from("<H", raw, cursor)[0]
            if record_bytes < 8 or record_bytes % 8 or cursor + record_bytes > used:
                raise VafsError(f"неверный record size B+-node {block_id}")
            records.append(raw[cursor : cursor + record_bytes])
            cursor += record_bytes
        if cursor != used:
            raise VafsError(f"лишние байты в B+-node {block_id}")
        return level, next_leaf, records

    def load_catalog(self, superblock: Superblock | None = None) -> tuple[dict[str, CatalogEntry], set[int]]:
        sb = superblock or self.superblock
        visited: set[int] = set()

        def walk(block: int, expected_level: int) -> tuple[list[CatalogEntry], bytes]:
            if block in visited:
                raise VafsError("цикл или повторный child в B+-дереве")
            visited.add(block)
            level, _next_leaf, records = self._read_node(block, sb.generation)
            if level != expected_level:
                raise VafsError(f"неверный уровень B+-node {block}")
            if level == 0:
                decoded = [decode_catalog_entry(record, self.total_blocks) for record in records]
                keys = [path_key(entry.path) for entry in decoded]
                if keys != sorted(keys) or len(keys) != len(set(keys)):
                    raise VafsError("несортированные/повторные leaf keys")
                return decoded, keys[-1]
            all_entries: list[CatalogEntry] = []
            previous_key: bytes | None = None
            for record in records:
                maximum, child = decode_internal_record(record, self.total_blocks)
                if previous_key is not None and maximum <= previous_key:
                    raise VafsError("несортированные internal keys")
                child_entries, actual_maximum = walk(child, level - 1)
                if maximum != actual_maximum:
                    raise VafsError("internal separator не равен maximum child")
                all_entries.extend(child_entries)
                previous_key = maximum
            return all_entries, previous_key or b""

        ordered, _ = walk(sb.catalog_root, sb.catalog_height)
        keys = [path_key(entry.path) for entry in ordered]
        if keys != sorted(keys) or len(keys) != len(set(keys)):
            raise VafsError("каталог между leaves не сортирован")
        result = {entry.path: entry for entry in ordered}
        root = result.get("/")
        if root is None or root.kind != ENTRY_DIRECTORY or root.object_id != sb.root_object_id:
            raise VafsError("неверная запись корневого каталога")
        object_ids = [entry.object_id for entry in ordered]
        if len(object_ids) != len(set(object_ids)) or max(object_ids) >= sb.next_object_id:
            raise VafsError("повторные или неверные object id")
        for path, entry in result.items():
            if path == "/":
                continue
            parent = result.get(parent_path(path))
            if parent is None or parent.kind != ENTRY_DIRECTORY:
                raise VafsError(f"у {path!r} нет каталога-родителя")
        return result, visited

    def read_file(self, entry: CatalogEntry, verify: bool = True) -> bytes:
        if entry.kind != ENTRY_FILE:
            raise VafsError(f"{entry.path!r} не файл")
        result = bytearray()
        remaining = entry.size
        for extent in entry.extents:
            bytes_to_read = min(remaining, extent.block_count * BLOCK_SIZE)
            self.file.seek(self._absolute(extent.physical_block))
            data = self.file.read(bytes_to_read)
            if len(data) != bytes_to_read:
                raise VafsError(f"обрезаны данны {entry.path!r}")
            result.extend(data)
            remaining -= bytes_to_read
        if remaining:
            raise VafsError(f"extents не покрыли {entry.path!r}")
        if verify and crc32c(result) != entry.data_crc32c:
            raise VafsError(f"не совпал CRC32C файла {entry.path!r}")
        return bytes(result)

    def allocate_host_file(self, source: Path, cursor: int) -> tuple[tuple[Extent, ...], int, int, int]:
        size = source.stat().st_size
        blocks = (size + BLOCK_SIZE - 1) // BLOCK_SIZE
        if cursor + blocks > self.total_blocks - 1:
            raise VafsError(f"нет места для {source}")
        checksum = 0
        remaining = size
        self.file.seek(self._absolute(cursor))
        with source.open("rb") as input_file:
            while remaining:
                chunk = input_file.read(min(1024 * 1024, remaining))
                if not chunk:
                    raise VafsError(f"неожиданный EOF {source}")
                self.file.write(chunk)
                checksum = crc32c(chunk, checksum)
                remaining -= len(chunk)
        padding = blocks * BLOCK_SIZE - size
        if padding:
            self.file.write(bytes(padding))
        extents = () if blocks == 0 else (Extent(0, cursor, blocks),)
        return extents, size, checksum, cursor + blocks

    def commit(self, entries: dict[str, CatalogEntry], cursor: int, next_object_id: int) -> Superblock:
        generation = self.superblock.generation + 1
        root, height, new_cursor, nodes = build_catalog(entries.values(), generation, cursor, self.total_blocks)
        for block_id in sorted(nodes):
            self.write_block(block_id, nodes[block_id])
        self.file.flush()
        os.fsync(self.file.fileno())
        updated = replace(
            self.superblock,
            generation=generation,
            catalog_root=root,
            catalog_height=height,
            alloc_cursor=new_cursor,
            next_object_id=next_object_id,
            clean=1,
        )
        primary = self.superblocks.get(0)
        mirror = self.superblocks.get(self.total_blocks - 1)
        if primary is None:
            target = 0
        elif mirror is None:
            target = self.total_blocks - 1
        elif primary.generation <= mirror.generation:
            target = 0
        else:
            target = self.total_blocks - 1
        self.write_block(target, updated.encode())
        self.file.flush()
        os.fsync(self.file.fileno())
        self.superblocks[target] = updated
        self.active_slot = target
        self.superblock = updated
        return updated


def ensure_parents(entries: dict[str, CatalogEntry], path: str, next_id: int) -> int:
    missing: list[str] = []
    cursor = parent_path(path)
    while cursor not in entries:
        missing.append(cursor)
        if cursor == "/":
            break
        cursor = parent_path(cursor)
    existing = entries.get(cursor)
    if existing is None or existing.kind != ENTRY_DIRECTORY:
        raise VafsError(f"родитель {cursor!r} не каталог")
    for directory in reversed(missing):
        entries[directory] = CatalogEntry(directory, ENTRY_DIRECTORY, next_id)
        next_id += 1
    return next_id


def format_volume(image: Path, image_size: int, offset: int, volume_uuid: uuid.UUID, device_class: int) -> None:
    if image_size < offset + 16 * BLOCK_SIZE:
        raise VafsError("для VaraniaFS нужно хотя бы 64 KiB после offset")
    if image_size % BLOCK_SIZE or offset % BLOCK_SIZE:
        raise VafsError("image size и offset должны быть кратны 4096")
    image.parent.mkdir(parents=True, exist_ok=True)
    mode = "r+b" if image.exists() else "w+b"
    with image.open(mode) as file:
        fcntl.flock(file.fileno(), fcntl.LOCK_EX)
        current_size = os.fstat(file.fileno()).st_size
        if current_size > image_size:
            raise VafsError("существующий образ больше --size; автоматически обрезать его небезопасно")
        file.truncate(image_size)  # на APFS/ext4 это sparse-операция
        total_blocks = (image_size - offset) // BLOCK_SIZE
        root_entry = CatalogEntry("/", ENTRY_DIRECTORY, 1)
        root, height, cursor, nodes = build_catalog([root_entry], 1, 1, total_blocks)
        for block_id, block in nodes.items():
            file.seek(offset + block_id * BLOCK_SIZE)
            file.write(block)
        superblock = Superblock(
            generation=1,
            volume_uuid=volume_uuid,
            total_blocks=total_blocks,
            features=REQUIRED_FEATURES,
            catalog_root=root,
            catalog_height=height,
            next_object_id=2,
            alloc_cursor=cursor,
            root_object_id=1,
            device_class=device_class,
        ).encode()
        file.seek(offset)
        file.write(superblock)
        file.seek(offset + (total_blocks - 1) * BLOCK_SIZE)
        file.write(superblock)
        file.flush()
        os.fsync(file.fileno())
        fcntl.flock(file.fileno(), fcntl.LOCK_UN)


def direct_children(entries: dict[str, CatalogEntry], directory: str) -> list[CatalogEntry]:
    prefix = "/" if directory == "/" else directory + "/"
    result = []
    for path, entry in entries.items():
        if not path.startswith(prefix) or path == directory:
            continue
        remainder = path[len(prefix) :]
        if "/" not in remainder:
            result.append(entry)
    return sorted(result, key=lambda entry: path_key(entry.path))


def command_format(args: argparse.Namespace) -> None:
    raw_uuid = uuid.UUID(args.uuid) if args.uuid else uuid.uuid4()
    format_volume(args.image, args.size, args.offset, raw_uuid, DEVICE_VALUES[args.device])
    allocated = args.size - args.offset
    print(f"VaraniaFS: создан том {raw_uuid}")
    print(f"  image:  {args.image} ({format_size(args.size)}, sparse)")
    print(f"  volume: offset {args.offset}, {format_size(allocated)}, 4 KiB blocks")
    print(f"  device: {args.device}")


def command_info(args: argparse.Namespace) -> None:
    with Volume(args.image, args.offset) as volume:
        sb = volume.superblock
        entries, nodes = volume.load_catalog()
        file_bytes = sum(entry.size for entry in entries.values() if entry.kind == ENTRY_FILE)
        print(f"VaraniaFS {VAFS_VERSION}: {sb.volume_uuid}")
        print(f"  generation:      {sb.generation} (superblock {volume.active_slot})")
        print(f"  volume:          {format_size(sb.total_blocks * BLOCK_SIZE)}")
        print(f"  device policy:   {DEVICE_NAMES[sb.device_class]}")
        print(f"  catalog:         {len(entries)} objects, {len(nodes)} B+-nodes, height {sb.catalog_height}")
        print(f"  logical data:    {format_size(file_bytes)}")
        print(f"  append cursor:   block {sb.alloc_cursor} ({format_size(sb.alloc_cursor * BLOCK_SIZE)})")


def command_ls(args: argparse.Namespace) -> None:
    target = normalize_path(args.path)
    with Volume(args.image, args.offset) as volume:
        entries, _ = volume.load_catalog()
        entry = entries.get(target)
        if entry is None:
            raise VafsError(f"нет {target!r}")
        selected = direct_children(entries, target) if entry.kind == ENTRY_DIRECTORY else [entry]
        for item in selected:
            name = PurePosixPath(item.path).name or "/"
            suffix = "/" if item.kind == ENTRY_DIRECTORY else ""
            if args.long:
                print(f"{ENTRY_NAMES[item.kind]:9} {item.size:12} {item.object_id:8}  {name}{suffix}")
            else:
                print(f"{name}{suffix}")


def command_tree(args: argparse.Namespace) -> None:
    target = normalize_path(args.path)
    with Volume(args.image, args.offset) as volume:
        entries, _ = volume.load_catalog()
        root = entries.get(target)
        if root is None:
            raise VafsError(f"нет {target!r}")
        prefix = "/" if target == "/" else target + "/"
        print(target)
        for path in sorted(entries, key=path_key):
            if path == target or not path.startswith(prefix):
                continue
            relative = path[len(prefix) :]
            depth = relative.count("/")
            suffix = "/" if entries[path].kind == ENTRY_DIRECTORY else ""
            print(f"{'  ' * (depth + 1)}{PurePosixPath(path).name}{suffix}")


def command_mkdir(args: argparse.Namespace) -> None:
    target = normalize_path(args.path)
    if target == "/":
        return
    with Volume(args.image, args.offset, writable=True) as volume:
        entries, _ = volume.load_catalog()
        if target in entries:
            if args.parents and entries[target].kind == ENTRY_DIRECTORY:
                return
            raise VafsError(f"{target!r} уже существует")
        next_id = volume.superblock.next_object_id
        if args.parents:
            next_id = ensure_parents(entries, target, next_id)
        parent = entries.get(parent_path(target))
        if parent is None or parent.kind != ENTRY_DIRECTORY:
            raise VafsError("родительского каталога нет")
        entries[target] = CatalogEntry(target, ENTRY_DIRECTORY, next_id)
        volume.commit(entries, volume.superblock.alloc_cursor, next_id + 1)


def command_put(args: argparse.Namespace) -> None:
    target = normalize_path(args.remote)
    if not args.local.is_file():
        raise VafsError(f"{args.local} не файл")
    with Volume(args.image, args.offset, writable=True) as volume:
        entries, _ = volume.load_catalog()
        current = entries.get(target)
        if current is not None and current.kind != ENTRY_FILE:
            raise VafsError(f"{target!r} уже является каталогом")
        next_id = volume.superblock.next_object_id
        if args.parents:
            next_id = ensure_parents(entries, target, next_id)
        parent = entries.get(parent_path(target))
        if parent is None or parent.kind != ENTRY_DIRECTORY:
            raise VafsError("родительского каталога нет; добавьте --parents")
        extents, size, checksum, cursor = volume.allocate_host_file(args.local, volume.superblock.alloc_cursor)
        object_id = current.object_id if current else next_id
        if current is None:
            next_id += 1
        mtime = args.local.stat().st_mtime_ns if args.preserve_times else 0
        entries[target] = CatalogEntry(target, ENTRY_FILE, object_id, size, mtime, checksum, extents)
        volume.commit(entries, cursor, next_id)
        print(f"{args.local} -> {target} ({size} байт, CRC32C {checksum:08x})")


def should_exclude(relative: str, patterns: list[str]) -> bool:
    parts = PurePosixPath(relative).parts
    return any(fnmatch.fnmatch(relative, pattern) or any(fnmatch.fnmatch(part, pattern) for part in parts) for pattern in patterns)


def command_import_tree(args: argparse.Namespace) -> None:
    if not args.local.is_dir():
        raise VafsError(f"{args.local} не каталог")
    destination = normalize_path(args.remote)
    patterns = args.exclude or []
    directories: list[tuple[str, Path]] = []
    files: list[tuple[str, Path]] = []
    for host_path in sorted(args.local.rglob("*")):
        relative = host_path.relative_to(args.local).as_posix()
        if should_exclude(relative, patterns):
            continue
        guest_path = normalize_path(destination.rstrip("/") + "/" + relative)
        if host_path.is_dir():
            directories.append((guest_path, host_path))
        elif host_path.is_file():
            files.append((guest_path, host_path))
    with Volume(args.image, args.offset, writable=True) as volume:
        entries, _ = volume.load_catalog()
        next_id = ensure_parents(entries, destination, volume.superblock.next_object_id)
        if destination not in entries:
            entries[destination] = CatalogEntry(destination, ENTRY_DIRECTORY, next_id)
            next_id += 1
        elif entries[destination].kind != ENTRY_DIRECTORY:
            raise VafsError(f"{destination!r} не каталог")
        for guest_path, _ in directories:
            current = entries.get(guest_path)
            if current is None:
                entries[guest_path] = CatalogEntry(guest_path, ENTRY_DIRECTORY, next_id)
                next_id += 1
            elif current.kind != ENTRY_DIRECTORY:
                raise VafsError(f"{guest_path!r} уже файл")
        cursor = volume.superblock.alloc_cursor
        logical_bytes = 0
        for guest_path, host_path in files:
            current = entries.get(guest_path)
            if current is not None and current.kind != ENTRY_FILE:
                raise VafsError(f"{guest_path!r} уже каталог")
            extents, size, checksum, cursor = volume.allocate_host_file(host_path, cursor)
            object_id = current.object_id if current else next_id
            if current is None:
                next_id += 1
            mtime = host_path.stat().st_mtime_ns if args.preserve_times else 0
            entries[guest_path] = CatalogEntry(guest_path, ENTRY_FILE, object_id, size, mtime, checksum, extents)
            logical_bytes += size
        volume.commit(entries, cursor, next_id)
        print(f"Импортировано: {len(directories)} каталогов, {len(files)} файлов, {format_size(logical_bytes)}")


def command_get(args: argparse.Namespace) -> None:
    source = normalize_path(args.remote)
    with Volume(args.image, args.offset) as volume:
        entries, _ = volume.load_catalog()
        entry = entries.get(source)
        if entry is None:
            raise VafsError(f"нет {source!r}")
        data = volume.read_file(entry)
    args.local.parent.mkdir(parents=True, exist_ok=True)
    with args.local.open("wb") as output:
        output.write(data)
    print(f"{source} -> {args.local} ({len(data)} байт)")


def command_rm(args: argparse.Namespace) -> None:
    target = normalize_path(args.path)
    if target == "/":
        raise VafsError("корень удалять нельзя")
    with Volume(args.image, args.offset, writable=True) as volume:
        entries, _ = volume.load_catalog()
        entry = entries.get(target)
        if entry is None:
            raise VafsError(f"нет {target!r}")
        descendants = [path for path in entries if path.startswith(target + "/")]
        if descendants and not args.recursive:
            raise VafsError("каталог не пуст; добавьте --recursive")
        for path in descendants:
            del entries[path]
        del entries[target]
        volume.commit(entries, volume.superblock.alloc_cursor, volume.superblock.next_object_id)


def command_fsck(args: argparse.Namespace) -> None:
    with Volume(args.image, args.offset) as volume:
        entries, metadata = volume.load_catalog()
        referenced = set(metadata)
        data_blocks = 0
        intervals: list[tuple[int, int, str]] = []
        for entry in entries.values():
            if entry.kind != ENTRY_FILE:
                continue
            if args.data:
                volume.read_file(entry, verify=True)
            for extent in entry.extents:
                intervals.append((extent.physical_block, extent.physical_block + extent.block_count, entry.path))
                data_blocks += extent.block_count
        for block in metadata:
            intervals.append((block, block + 1, "<catalog>"))
        intervals.sort()
        for left, right in zip(intervals, intervals[1:]):
            if left[1] > right[0]:
                raise VafsError(f"перекрытие blocks: {left[2]} и {right[2]}")
        if intervals and max(end for _, end, _ in intervals) > volume.superblock.alloc_cursor:
            raise VafsError("активные блоки выше allocation cursor")
        valid_generations = ", ".join(str(sb.generation) for sb in sorted(volume.superblocks.values(), key=lambda item: item.generation))
        print("VaraniaFS fsck: OK")
        print(f"  superblock generations: {valid_generations}")
        print(f"  objects: {len(entries)}, metadata blocks: {len(metadata)}, data blocks: {data_blocks}")
        if args.data:
            print("  CRC32C всех файлов: OK")


def add_volume_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("image", type=Path, help="raw disk или образ раздела")
    parser.add_argument("--offset", type=parse_size, default=0, help="смещение VaraniaFS, например 4M")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    format_parser = subparsers.add_parser("format", help="создать VaraniaFS")
    add_volume_arguments(format_parser)
    format_parser.add_argument("--size", type=parse_size, required=True, help="полный размер image")
    format_parser.add_argument("--uuid", help="фиксированный UUID для reproducible build")
    format_parser.add_argument("--device", choices=sorted(DEVICE_VALUES), default="auto")
    format_parser.set_defaults(function=command_format)

    info_parser = subparsers.add_parser("info", help="показать superblock и размеры")
    add_volume_arguments(info_parser)
    info_parser.set_defaults(function=command_info)

    ls_parser = subparsers.add_parser("ls", help="показать каталог")
    add_volume_arguments(ls_parser)
    ls_parser.add_argument("path", nargs="?", default="/")
    ls_parser.add_argument("-l", "--long", action="store_true")
    ls_parser.set_defaults(function=command_ls)

    tree_parser = subparsers.add_parser("tree", help="показать дерево")
    add_volume_arguments(tree_parser)
    tree_parser.add_argument("path", nargs="?", default="/")
    tree_parser.set_defaults(function=command_tree)

    mkdir_parser = subparsers.add_parser("mkdir", help="создать каталог")
    add_volume_arguments(mkdir_parser)
    mkdir_parser.add_argument("path")
    mkdir_parser.add_argument("-p", "--parents", action="store_true")
    mkdir_parser.set_defaults(function=command_mkdir)

    put_parser = subparsers.add_parser("put", help="записать host-файл в VaraniaFS")
    add_volume_arguments(put_parser)
    put_parser.add_argument("local", type=Path)
    put_parser.add_argument("remote")
    put_parser.add_argument("-p", "--parents", action="store_true")
    put_parser.add_argument("--preserve-times", action="store_true")
    put_parser.set_defaults(function=command_put)

    import_parser = subparsers.add_parser("import-tree", help="импортировать дерево за один commit")
    add_volume_arguments(import_parser)
    import_parser.add_argument("local", type=Path)
    import_parser.add_argument("remote")
    import_parser.add_argument("--exclude", action="append", default=[])
    import_parser.add_argument("--preserve-times", action="store_true")
    import_parser.set_defaults(function=command_import_tree)

    get_parser = subparsers.add_parser("get", help="извлечь файл на host")
    add_volume_arguments(get_parser)
    get_parser.add_argument("remote")
    get_parser.add_argument("local", type=Path)
    get_parser.set_defaults(function=command_get)

    rm_parser = subparsers.add_parser("rm", help="удалить имя из нового поколения")
    add_volume_arguments(rm_parser)
    rm_parser.add_argument("path")
    rm_parser.add_argument("-r", "--recursive", action="store_true")
    rm_parser.set_defaults(function=command_rm)

    fsck_parser = subparsers.add_parser("fsck", help="проверить superblocks, B+-tree, extents и CRC")
    add_volume_arguments(fsck_parser)
    fsck_parser.add_argument("--data", action="store_true", help="пересчитать все файловые CRC32C")
    fsck_parser.set_defaults(function=command_fsck)
    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    try:
        args.function(args)
    except (VafsError, OSError) as error:
        print(f"ОШИБКА: {error}", file=sys.stderr)
        raise SystemExit(1) from error


if __name__ == "__main__":
    main()
