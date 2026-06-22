#!/usr/bin/env bash
set -euo pipefail

MODEL="${1:-}"
SESSION_ID="${2:-}"

case "$MODEL" in
  claude)
    if [ -n "$SESSION_ID" ]; then
      # Resume the chat only if a transcript for this id exists in the project
      # dir for THIS pane's cwd — that is the only place `claude --resume` looks.
      # A transcript present under some *other* project dir (e.g. synced from a
      # machine with a different username, so a different ~/workspace path) does
      # not count: --resume would print "No conversation found". In that case
      # start fresh pinned to the id. Claude names its per-project transcript
      # dir by replacing every non-alphanumeric char of the cwd with '-'.
      proj="$HOME/.claude/projects/$(printf '%s' "$PWD" | sed 's/[^A-Za-z0-9]/-/g')"
      if [ -f "$proj/$SESSION_ID.jsonl" ]; then
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
