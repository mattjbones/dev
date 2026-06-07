#!/usr/bin/env bash
set -euo pipefail

MODEL="${1:-}"

case "$MODEL" in
  claude)
    exec claude --dangerously-skip-permissions
    ;;
  codex)
    exec codex --full-auto
    ;;
  *)
    echo "Unknown model: $MODEL" >&2
    exit 1
    ;;
esac
