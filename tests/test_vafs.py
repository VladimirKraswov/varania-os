#!/usr/bin/env python3
"""Проверки on-disk формата VaraniaFS без запуска VM."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
import uuid


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "tools" / "vafs" / "vafs.py"
SPEC = importlib.util.spec_from_file_location("varania_vafs", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
vafs = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = vafs
SPEC.loader.exec_module(vafs)


class VaraniaFsTests(unittest.TestCase):
    def create_image(self, directory: Path, size: int = 32 << 20) -> Path:
        image = directory / "test.vafs"
        vafs.format_volume(
            image,
            size,
            0,
            uuid.UUID("11111111-2222-3333-4444-555555555555"),
            vafs.DEVICE_SOLID_STATE,
        )
        return image

    def test_format_and_two_superblocks(self) -> None:
        with tempfile.TemporaryDirectory(prefix="varania-vafs-test-") as raw_directory:
            image = self.create_image(Path(raw_directory))
            with vafs.Volume(image, 0) as volume:
                entries, metadata = volume.load_catalog()
                self.assertEqual(set(entries), {"/"})
                self.assertEqual(volume.superblock.generation, 1)
                self.assertEqual(set(volume.superblocks), {0, volume.total_blocks - 1})
                self.assertEqual(len(metadata), 1)

    def test_multilevel_catalog_and_file_crc(self) -> None:
        with tempfile.TemporaryDirectory(prefix="varania-vafs-test-") as raw_directory:
            directory = Path(raw_directory)
            image = self.create_image(directory)
            source = ROOT / "README.md"
            with vafs.Volume(image, 0, writable=True) as volume:
                entries, _ = volume.load_catalog()
                next_id = volume.superblock.next_object_id
                entries["/many"] = vafs.CatalogEntry("/many", vafs.ENTRY_DIRECTORY, next_id)
                next_id += 1
                # 180 длинных имён гарантируют несколько leaves и internal root.
                for index in range(180):
                    path = f"/many/source-{index:04d}-with-readable-name.asm"
                    entries[path] = vafs.CatalogEntry(path, vafs.ENTRY_FILE, next_id)
                    next_id += 1
                extents, size, checksum, cursor = volume.allocate_host_file(
                    source, volume.superblock.alloc_cursor
                )
                entries["/README.md"] = vafs.CatalogEntry(
                    "/README.md", vafs.ENTRY_FILE, next_id, size, 0, checksum, extents
                )
                next_id += 1
                volume.commit(entries, cursor, next_id)

            with vafs.Volume(image, 0) as volume:
                entries, metadata = volume.load_catalog()
                self.assertGreater(volume.superblock.catalog_height, 0)
                self.assertGreater(len(metadata), 1)
                self.assertEqual(volume.read_file(entries["/README.md"]), source.read_bytes())

    def test_torn_new_generation_falls_back_to_old_superblock(self) -> None:
        with tempfile.TemporaryDirectory(prefix="varania-vafs-test-") as raw_directory:
            image = self.create_image(Path(raw_directory))
            with vafs.Volume(image, 0, writable=True) as volume:
                entries, _ = volume.load_catalog()
                object_id = volume.superblock.next_object_id
                entries["/new"] = vafs.CatalogEntry("/new", vafs.ENTRY_DIRECTORY, object_id)
                volume.commit(entries, volume.superblock.alloc_cursor, object_id + 1)
                self.assertEqual(volume.active_slot, 0)
                self.assertEqual(volume.superblock.generation, 2)

            # Имитируем torn write самой новой копии. Зеркало generation 1
            # остаётся самодостаточным и должно смонтироваться.
            with image.open("r+b") as file:
                file.seek(vafs.SUPER_CHECKSUM_OFFSET)
                file.write(b"\0\0\0\0")
                file.flush()

            with vafs.Volume(image, 0) as recovered:
                entries, _ = recovered.load_catalog()
                self.assertEqual(recovered.superblock.generation, 1)
                self.assertEqual(set(entries), {"/"})

    def test_offset_preserves_boot_prefix(self) -> None:
        with tempfile.TemporaryDirectory(prefix="varania-vafs-test-") as raw_directory:
            directory = Path(raw_directory)
            image = directory / "disk.img"
            prefix = bytes(range(256)) * 16
            image.write_bytes(prefix)
            vafs.format_volume(
                image,
                32 << 20,
                4 << 20,
                uuid.UUID("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
                vafs.DEVICE_AUTO,
            )
            with image.open("rb") as file:
                self.assertEqual(file.read(len(prefix)), prefix)
            with vafs.Volume(image, 4 << 20) as volume:
                entries, _ = volume.load_catalog()
                self.assertIn("/", entries)


if __name__ == "__main__":
    unittest.main(verbosity=2)
