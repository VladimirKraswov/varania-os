#!/usr/bin/env bash
# Запуск Varania OS в QEMU. Все аргументы передаются QEMU без изменений.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"

if ! command -v "$QEMU_BIN" >/dev/null 2>&1; then
  echo "Не найден qemu-system-x86_64." >&2
  echo "macOS: brew install qemu" >&2
  echo "Debian/Ubuntu: sudo apt install qemu-system-x86" >&2
  exit 1
fi

exec "$QEMU_BIN" \
  -machine pc,accel=tcg \
  -cpu max \
  -m 128M \
  -drive "format=raw,file=$PROJECT_ROOT/VOS.VHD" \
  "$@"
