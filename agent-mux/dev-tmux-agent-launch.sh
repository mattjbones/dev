#!/usr/bin/env bash
set -euo pipefail

MODEL="${1:-}"
SESSION_ID="${2:-}"
# DEV_AGENT_FRESH=1 (dev --fresh): never resume or continue an earlier chat.
FRESH="${DEV_AGENT_FRESH:-}"

# Newest top-level, unarchived codex chat started in this cwd, from codex's
# own thread index. Empty if none, or if the index is missing / unreadable
# (e.g. a codex upgrade changed its schema) — the caller then starts fresh.
latest_codex_thread() {
  local db="${CODEX_HOME:-$HOME/.codex}/state_5.sqlite"
  [ -f "$db" ] && command -v sqlite3 >/dev/null 2>&1 || return 0
  local cwd="${PWD//\'/\'\'}"
  sqlite3 -readonly "$db" "select id from threads where cwd = '$cwd'
    and source = 'cli' and thread_source = 'user' and archived = 0
    order by updated_at desc limit 1;" 2>/dev/null || true
}

case "$MODEL" in
  claude)
    # Claude names its per-project transcript dir by replacing every
    # non-alphanumeric char of the cwd with '-'.
    proj="$HOME/.claude/projects/$(printf '%s' "$PWD" | sed 's/[^A-Za-z0-9]/-/g')"
    if [ -n "$SESSION_ID" ]; then
      # Resume the chat only if a transcript for this id exists in the project
      # dir for THIS pane's cwd — that is the only place `claude --resume` looks.
      # A transcript present under some *other* project dir (e.g. synced from a
      # machine with a different username, so a different ~/workspace path) does
      # not count: --resume would print "No conversation found".
      if [ -z "$FRESH" ] && [ -f "$proj/$SESSION_ID.jsonl" ]; then
        exec claude --dangerously-skip-permissions --resume "$SESSION_ID"
      fi
      # The recorded id is stale (e.g. the chat was /clear'ed into a new id)
      # but this worktree has chats: pick up the latest rather than a blank one.
      if [ -z "$FRESH" ] && compgen -G "$proj/*.jsonl" >/dev/null; then
        exec claude --dangerously-skip-permissions --continue
      fi
      exec claude --dangerously-skip-permissions --session-id "$SESSION_ID"
    fi
    exec claude --dangerously-skip-permissions
    ;;
  codex)
    thread=""
    [ -z "$FRESH" ] && thread="$(latest_codex_thread)"
    if [ -n "$thread" ]; then
      exec codex --dangerously-bypass-approvals-and-sandbox resume "$thread"
    fi
    exec codex --dangerously-bypass-approvals-and-sandbox
    ;;
  *)
    echo "Unknown model: $MODEL" >&2
    exit 1
    ;;
esac
