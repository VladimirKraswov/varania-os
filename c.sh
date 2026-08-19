#!/usr/bin/env bash
# Совместимая короткая команда для старых пользователей проекта.
# Новые сценарии лучше вызывать напрямую: make build/run/test.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_ROOT"

COMMAND="${1:-run}"
if [[ $# -gt 0 ]]; then
  shift
fi

case "$COMMAND" in
  build)
    exec make build
    ;;
  test)
    exec make test
    ;;
  run)
    make check
    exec ./scripts/run-qemu.sh "$@"
    ;;
  *)
    echo "Использование: ./c.sh [build|test|run] [аргументы QEMU]" >&2
    exit 2
    ;;
esac

