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
assert_eq "$(cat "$(dc_marker_path "$HOME/workspace/eng-7925-3")")" "matt-eng-7925-2-batches-at-conversion" "marker stores project name"

# nothing running → no down, no marker
: > "$LOG"
dc_handle_closes WS-NORUN
assert_eq "$(grep -c 'down' "$LOG")" "0" "no down when nothing running"
[ -f "$(dc_marker_path "$HOME/workspace/stopped")" ] && st=exists || st=absent
assert_eq "$st" "absent" "no marker when nothing torn down"

# bulk (>=3) → skip entirely
: > "$LOG"
dc_handle_closes WS-CLOSE WS-CLOSE WS-CLOSE
assert_eq "$(grep -c 'down' "$LOG")" "0" "bulk close (>=3) skipped"

# unknown uuid → ignored
: > "$LOG"
dc_handle_closes WS-UNKNOWN
assert_eq "$(grep -c 'down' "$LOG")" "0" "unknown uuid ignored"

# --- Task 4 fix: no marker when teardown fails (docker dir missing) ---
: > "$LOG"
echo "$HOME/workspace/nodir" > "$DEV_STATE_DIR/workspace-map/WS-NODIR"   # note: no docker/ dir created
cat > "$STUB/docker" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$LOG"
if [ "\$1" = "ps" ]; then
  printf '%s' "\$*" | grep -q 'eng-7925-3/docker' && echo "matt-eng-7925-2-batches-at-conversion"
  printf '%s' "\$*" | grep -q 'nodir/docker' && echo "nodir-project"
fi
exit 0
EOF
chmod +x "$STUB/docker"
dc_teardown_one WS-NODIR
[ -f "$(dc_marker_path "$HOME/workspace/nodir")" ] && st=exists || st=absent
assert_eq "$st" "absent" "no marker when teardown cd fails"

# --- Task 5: reattach re-up ---
: > "$LOG"
mkdir -p "$DEV_STATE_DIR/torn-down"
echo "matt-eng-7925-2-batches-at-conversion" > "$(dc_marker_path "$HOME/workspace/eng-7925-3")"
dc_reup "$HOME/workspace/eng-7925-3"
assert_eq "$(grep -c 'compose .*-p matt-eng-7925-2-batches-at-conversion up -d' "$LOG")" "1" "re-ups stored project"
[ -f "$(dc_marker_path "$HOME/workspace/eng-7925-3")" ] && st=exists || st=gone
assert_eq "$st" "gone" "marker cleared after re-up"
# no marker → no-op
: > "$LOG"
dc_reup "$HOME/workspace/no-marker"
assert_eq "$(grep -c 'up -d' "$LOG")" "0" "no marker → no-op"

# --- C1: case-variant / nested worktrees get distinct marker paths ---
m1="$(dc_marker_path "$HOME/workspace/eng-7903")"
m2="$(dc_marker_path "$HOME/workspace/ENG-7903")"
[ "$m1" != "$m2" ] && r=distinct || r=same
assert_eq "$r" "distinct" "C1: case-variant worktrees → distinct markers"
m3="$(dc_marker_path "$HOME/workspace/fix/foo")"
m4="$(dc_marker_path "$HOME/workspace/bar/foo")"
[ "$m3" != "$m4" ] && r=distinct || r=same
assert_eq "$r" "distinct" "C1: nested worktrees with same basename → distinct markers"

# --- M2: infra denylist ---
: > "$LOG"
mkdir -p "$HOME/workspace/test/docker"
echo "$HOME/workspace/test" > "$DEV_STATE_DIR/workspace-map/WS-INFRA"
cat > "$STUB/docker" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$LOG"
if [ "\$1" = "ps" ]; then
  printf '%s' "\$*" | grep -q 'eng-7925-3/docker' && echo "matt-eng-7925-2-batches-at-conversion"
  printf '%s' "\$*" | grep -q '/test/docker' && echo "lupa-proxy"
fi
exit 0
EOF
chmod +x "$STUB/docker"
dc_teardown_one WS-INFRA
assert_eq "$(grep -c 'down' "$LOG")" "0" "M2: infra project (lupa-proxy) never torn down"

# --- Task 6/C3: dc_tick with one-tick debounce ---
export DEV_PENDING_CLOSE="$STUB/state/pending-close"
: > "$LOG"
rm -f "$DEV_EVENTS_CURSOR" "$DEV_PENDING_CLOSE"
export DEV_CMUX_EVENTS_FILE="$STUB/tick-events.jsonl"
cat > "$DEV_CMUX_EVENTS_FILE" <<'JSON'
{"boot_id":"B9","seq":1,"name":"workspace.selected","payload":{}}
JSON
dc_tick                                   # baseline (no cursor → establishes, holds nothing)
echo '{"boot_id":"B9","seq":2,"name":"workspace.closed","payload":{"workspace_id":"WS-CLOSE"}}' >> "$DEV_CMUX_EVENTS_FILE"
dc_tick                                   # sees 1 new close → HOLD (pending), no teardown yet
assert_eq "$(grep -c 'down' "$LOG")" "0" "C3: single close held on first tick (no teardown)"
dc_tick                                   # quiet tick → tear down the held close
assert_eq "$(grep -c 'compose .*-p matt-eng-7925-2-batches-at-conversion down' "$LOG")" "1" "C3: held close torn down on quiet tick"

# bulk split across ticks: 2 closes then 2 more → accumulates to >=3 → skipped
: > "$LOG"
rm -f "$DEV_EVENTS_CURSOR" "$DEV_PENDING_CLOSE"
cat > "$DEV_CMUX_EVENTS_FILE" <<'JSON'
{"boot_id":"B9","seq":10,"name":"workspace.selected","payload":{}}
JSON
dc_tick                                   # baseline
{ echo '{"boot_id":"B9","seq":11,"name":"workspace.closed","payload":{"workspace_id":"WS-CLOSE"}}'
  echo '{"boot_id":"B9","seq":12,"name":"workspace.closed","payload":{"workspace_id":"WS-A"}}'; } >> "$DEV_CMUX_EVENTS_FILE"
dc_tick                                   # 2 new → hold (pending=2)
{ echo '{"boot_id":"B9","seq":13,"name":"workspace.closed","payload":{"workspace_id":"WS-B"}}'
  echo '{"boot_id":"B9","seq":14,"name":"workspace.closed","payload":{"workspace_id":"WS-C"}}'; } >> "$DEV_CMUX_EVENTS_FILE"
dc_tick                                   # 2 more → pending=4 >=3 → bulk, drop, skip
dc_tick                                   # quiet tick → nothing pending
assert_eq "$(grep -c 'down' "$LOG")" "0" "C3: bulk close split across ticks → skipped"

finish
