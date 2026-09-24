#!/usr/bin/env bash
# dev-tmux-agent-launch.sh: which command each model gets, so a rebuilt dev
# session (e.g. after a reboot) resumes the worktree's chat instead of a blank one.
set -euo pipefail
DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/devctl-test-helpers.sh"
LAUNCH="$DIR/../dev-tmux-agent-launch.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Stub agents: print the argv they were exec'd with.
mkdir -p "$tmp/bin"
for a in claude codex; do
  printf '#!/bin/sh\necho %s "$@"\n' "$a" > "$tmp/bin/$a"
  chmod +x "$tmp/bin/$a"
done

wt="$tmp/workspace/wt"
mkdir -p "$wt"
proj="$tmp/home/.claude/projects/$(printf '%s' "$wt" | sed 's/[^A-Za-z0-9]/-/g')"

# Minimal slice of codex's thread index (~/.codex/state_5.sqlite).
export CODEX_HOME="$tmp/codex"
mkdir -p "$CODEX_HOME"
sqlite3 "$CODEX_HOME/state_5.sqlite" "create table threads (id text, cwd text,
  source text, thread_source text, archived integer, updated_at integer);"
add_thread() { # id cwd source thread_source archived updated_at
  sqlite3 "$CODEX_HOME/state_5.sqlite" \
    "insert into threads values ('$1','$2','$3','$4',$5,$6);"
}

run() { # [VAR=val ...] -- args...
  (cd "$wt" && env HOME="$tmp/home" PATH="$tmp/bin:$PATH" "$@")
}

# --- codex ------------------------------------------------------------------
assert_eq "$(run "$LAUNCH" codex)" \
  "codex --dangerously-bypass-approvals-and-sandbox" \
  "codex: no prior thread for cwd starts fresh"

add_thread old-thread "$wt" cli user 0 100
add_thread newest "$wt" cli user 0 300
add_thread subagent "$wt" '{"subagent":{}}' subagent 0 400
add_thread archived "$wt" cli user 1 500
add_thread elsewhere "$tmp/other" cli user 0 600
assert_eq "$(run "$LAUNCH" codex)" \
  "codex --dangerously-bypass-approvals-and-sandbox resume newest" \
  "codex: resumes newest user thread for cwd (skips subagent/archived/other cwd)"

assert_eq "$(run DEV_AGENT_FRESH=1 "$LAUNCH" codex)" \
  "codex --dangerously-bypass-approvals-and-sandbox" \
  "codex: DEV_AGENT_FRESH=1 skips resume"

rm "$CODEX_HOME/state_5.sqlite"
assert_eq "$(run "$LAUNCH" codex)" \
  "codex --dangerously-bypass-approvals-and-sandbox" \
  "codex: missing index starts fresh"

# --- claude -----------------------------------------------------------------
assert_eq "$(run "$LAUNCH" claude)" \
  "claude --dangerously-skip-permissions" \
  "claude: no id, no transcripts starts fresh"

assert_eq "$(run "$LAUNCH" claude abc)" \
  "claude --dangerously-skip-permissions --session-id abc" \
  "claude: id without any transcript pins a new chat"

mkdir -p "$proj"
touch "$proj/other.jsonl"
assert_eq "$(run "$LAUNCH" claude abc)" \
  "claude --dangerously-skip-permissions --continue" \
  "claude: stale id but worktree has chats continues the latest"

touch "$proj/abc.jsonl"
assert_eq "$(run "$LAUNCH" claude abc)" \
  "claude --dangerously-skip-permissions --resume abc" \
  "claude: id with transcript resumes it"

assert_eq "$(run DEV_AGENT_FRESH=1 "$LAUNCH" claude xyz)" \
  "claude --dangerously-skip-permissions --session-id xyz" \
  "claude: DEV_AGENT_FRESH=1 never continues"

finish
