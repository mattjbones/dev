#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/board-test-helpers.sh"
STUB="$(mktemp -d)"; LOG="$STUB/log"
trap 'rm -rf "$STUB"' EXIT

# Stub docker: echoes a project for a known working_dir filter, nothing otherwise.
cat > "$STUB/docker" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$LOG"
# emulate: docker ps --filter label=...working_dir=<wt>/docker --filter status=running --format ...
if printf '%s' "\$*" | grep -q 'working_dir=/wt/eng-7925-3/docker'; then
  echo "matt-eng-7925-2-batches-at-conversion"
fi
EOF
chmod +x "$STUB/docker"
export PATH="$STUB:$PATH"
source "$DIR/../dev-close-cleanup.sh"

assert_eq "$(dc_project_for_worktree /wt/eng-7925-3)" "matt-eng-7925-2-batches-at-conversion" "discovers branch-named project"
assert_eq "$(dc_project_for_worktree /wt/nothing-running)" "" "empty when no containers"

export DEV_STATE_DIR="$STUB/state"
mkdir -p "$DEV_STATE_DIR/workspace-map"
echo "/Users/me/workspace/eng-7903" > "$DEV_STATE_DIR/workspace-map/UUID-ABC"
assert_eq "$(dc_worktree_for_uuid UUID-ABC)" "/Users/me/workspace/eng-7903" "registry hit"
assert_eq "$(dc_worktree_for_uuid UUID-MISSING)" "" "registry miss → empty"

export DEV_CMUX_EVENTS_FILE="$STUB/events.jsonl"
export DEV_EVENTS_CURSOR="$STUB/cursor"
# boot B1: two unrelated events, then close of WS-1
cat > "$DEV_CMUX_EVENTS_FILE" <<'JSON'
{"boot_id":"B1","seq":1,"name":"workspace.selected","payload":{}}
{"boot_id":"B1","seq":2,"name":"workspace.closed","payload":{"workspace_id":"WS-1"}}
JSON
# first run: no cursor -> establish baseline at tail, emit nothing
assert_eq "$(dc_drain_closed)" "" "first run emits nothing (no replay)"
# append a new close; second run emits only the new one
echo '{"boot_id":"B1","seq":3,"name":"workspace.closed","payload":{"workspace_id":"WS-2"}}' >> "$DEV_CMUX_EVENTS_FILE"
assert_eq "$(dc_drain_closed)" "WS-2" "emits new close after baseline"
# nothing new -> empty
assert_eq "$(dc_drain_closed)" "" "no new events → empty"
# boot change resets baseline, emits nothing even though a close is present
echo '{"boot_id":"B2","seq":1,"name":"workspace.closed","payload":{"workspace_id":"WS-3"}}' >> "$DEV_CMUX_EVENTS_FILE"
assert_eq "$(dc_drain_closed)" "" "boot change → baseline reset, no replay"

# --- Task 4: teardown + bulk guard ---
export HOME="$STUB/home"
mkdir -p "$HOME/workspace/eng-7925-3/docker" "$HOME/workspace/stopped/docker"
export DEV_STATE_DIR="$STUB/state"; mkdir -p "$DEV_STATE_DIR/workspace-map" "$DEV_STATE_DIR/torn-down"
echo "$HOME/workspace/eng-7925-3" > "$DEV_STATE_DIR/workspace-map/WS-CLOSE"
echo "$HOME/workspace/stopped"    > "$DEV_STATE_DIR/workspace-map/WS-NORUN"

# Replace docker stub: `ps` reports a project only for eng-7925-3; log compose calls.
cat > "$STUB/docker" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$LOG"
if [ "\$1" = "ps" ]; then
  printf '%s' "\$*" | grep -q 'eng-7925-3/docker' && echo "matt-eng-7925-2-batches-at-conversion"
fi
exit 0
EOF
chmod +x "$STUB/docker"

# single close of a running worktree → down + marker with discovered project
dc_handle_closes WS-CLOSE
assert_eq "$(grep -c 'compose .*-p matt-eng-7925-2-batches-at-conversion down' "$LOG")" "1" "runs compose down for discovered project"
assert_eq "$(cat "$DEV_STATE_DIR/torn-down/eng-7925-3")" "matt-eng-7925-2-batches-at-conversion" "marker stores project name"

# nothing running → no down, no marker
: > "$LOG"
dc_handle_closes WS-NORUN
assert_eq "$(grep -c 'down' "$LOG")" "0" "no down when nothing running"
[ -f "$DEV_STATE_DIR/torn-down/stopped" ] && st=exists || st=absent
assert_eq "$st" "absent" "no marker when nothing torn down"

# bulk (>=3) → skip entirely
: > "$LOG"
dc_handle_closes WS-CLOSE WS-CLOSE WS-CLOSE
assert_eq "$(grep -c 'down' "$LOG")" "0" "bulk close (>=3) skipped"

# unknown uuid → ignored
: > "$LOG"
dc_handle_closes WS-UNKNOWN
assert_eq "$(grep -c 'down' "$LOG")" "0" "unknown uuid ignored"

finish
