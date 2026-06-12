#!/usr/bin/env bash
set -euo pipefail

MODEL="${1:-}"
SESSION_ID="${2:-}"

case "$MODEL" in
  claude)
    if [ -n "$SESSION_ID" ]; then
      # Resume the chat if a transcript for this id already exists on this
      # machine (pane relaunch, restore after reboot); otherwise start a fresh
      # session pinned to the id so it can be resumed later.
      if ls "$HOME/.claude/projects"/*/"$SESSION_ID".jsonl >/dev/null 2>&1; then
        exec claude --dangerously-skip-permissions --resume "$SESSION_ID"
      else
        exec claude --dangerously-skip-permissions --session-id "$SESSION_ID"
      fi
    fi
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
