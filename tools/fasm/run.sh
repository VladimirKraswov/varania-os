#!/usr/bin/env bash
# Единая точка запуска FASM на Linux и macOS Apple Silicon.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Использование: $0 <исходник.asm> <результат.bin>" >&2
  exit 2
fi

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE_FILE="$1"
OUTPUT_FILE="$2"
FASM_ARCHIVE="$PROJECT_ROOT/tools/fasm/fasm-1.73.35.tgz"
DOCKER_IMAGE="varania-fasm:1.73.35"

# Явно заданный бинарник имеет наивысший приоритет.
if [[ -n "${FASM_BIN:-}" ]]; then
  exec "$FASM_BIN" "$SOURCE_FILE" "$OUTPUT_FILE"
fi

# На Linux и некоторых Intel Mac FASM может быть установлен системно.
if command -v fasm >/dev/null 2>&1; then
  exec fasm "$SOURCE_FILE" "$OUTPUT_FILE"
fi

# Официальный Linux-бинарник из архива запускается напрямую на x86_64.
# Временный каталог уникален и удаляется автоматически.
if [[ "$(uname -s)" == "Linux" && "$(uname -m)" == "x86_64" ]]; then
  TEMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TEMP_DIR"' EXIT
  tar -xzf "$FASM_ARCHIVE" -C "$TEMP_DIR"
  "$TEMP_DIR/fasm/fasm" "$SOURCE_FILE" "$OUTPUT_FILE"
  exit 0
fi

# На Apple Silicon официальный FASM выполняется в маленьком amd64-контейнере.
if ! command -v docker >/dev/null 2>&1; then
  echo "FASM не найден. На macOS установите и запустите Docker Desktop." >&2
  echo "На Linux установите fasm либо Docker." >&2
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "Docker установлен, но его демон не запущен." >&2
  exit 1
fi
if ! docker image inspect "$DOCKER_IMAGE" >/dev/null 2>&1; then
  echo "Собираю локальный контейнер FASM 1.73.35..."
  docker build --platform linux/amd64 -t "$DOCKER_IMAGE" \
    "$PROJECT_ROOT/tools/fasm"
fi

exec docker run --rm --platform linux/amd64 \
  -v "$PROJECT_ROOT:/work" \
  -w /work \
  "$DOCKER_IMAGE" \
  fasm "$SOURCE_FILE" "$OUTPUT_FILE"
