#!/usr/bin/env bash
# Запуск Varania OS в QEMU. Все аргументы передаются QEMU без изменений.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
QEMU_DISPLAY_ARGS=()

if ! command -v "$QEMU_BIN" >/dev/null 2>&1; then
  echo "Не найден qemu-system-x86_64." >&2
  echo "macOS: brew install qemu" >&2
  echo "Debian/Ubuntu: sudo apt install qemu-system-x86" >&2
  exit 1
fi

# На Retina-экране исходный VGA mode выглядит физически очень маленьким.
# Cocoa умеет масштабировать framebuffer без изменения гостевой ОС. По
# умолчанию интерактивный запуск разворачивается на весь экран; значение 0
# оставляет обычное resizable window с zoom-to-fit.
if [[ "$(uname -s)" == "Darwin" ]]; then
  HAS_EXPLICIT_DISPLAY=0
  for ARGUMENT in "$@"; do
    case "$ARGUMENT" in
      -display|-nographic)
        HAS_EXPLICIT_DISPLAY=1
        ;;
    esac
  done
  if [[ "$HAS_EXPLICIT_DISPLAY" == 0 ]]; then
    COCOA_OPTIONS="cocoa,zoom-to-fit=on,show-cursor=on"
    if [[ "${VARANIA_QEMU_FULLSCREEN:-1}" != "0" ]]; then
      COCOA_OPTIONS+=",full-screen=on"
    fi
    QEMU_DISPLAY_ARGS=(-display "$COCOA_OPTIONS")
  fi
fi

exec "$QEMU_BIN" \
  -machine pc,accel=tcg \
  -cpu max \
  -m 128M \
  -drive "format=raw,file=$PROJECT_ROOT/VOS.VHD" \
  -drive "if=none,id=varania-nvme,format=raw,file=$PROJECT_ROOT/VARANIA.VAFS" \
  -device "nvme,drive=varania-nvme,serial=VARANIA0001" \
  "${QEMU_DISPLAY_ARGS[@]}" \
  "$@"
