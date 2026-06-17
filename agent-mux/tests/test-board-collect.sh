#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/board-test-helpers.sh"

# Stub linear-dash on PATH so no network is hit.
STUB="$(mktemp -d)"
trap 'rm -rf "$STUB" "${FIX:-}"' EXIT
export STUB_LOG="$STUB/log"
cat > "$STUB/linear-dash" <<'EOF'
#!/usr/bin/env bash
echo "STUBCALL" >> "$STUB_LOG"
echo '[{"branch":"eng-7443","ticket":"ENG-7443","priority":2,"priorityLabel":"High","linearState":"In Review","linearStateType":"started","pr":{"number":1,"state":"OPEN","isDraft":false,"reviewDecision":"CHANGES_REQUESTED","mergeStateStatus":"BLOCKED"}}]'
EOF
chmod +x "$STUB/linear-dash"
export PATH="$STUB:$PATH"
export DEV_BOARD_CACHE="$STUB/cache.json"

# Feed an explicit workspace list (avoids tmux/manifest dependency in the test).
WL='[{"key":"eng-7443","branch":"eng-7443","worktree":"/tmp/eng-7443"}]'
echo "$WL" | "$DIR/../dev-board-collect.sh" --stdin --refresh >/dev/null
assert_eq "$(jq -r '.workspaces[0].needsReview' "$DEV_BOARD_CACHE")" "true" "needsReview from PR"
assert_eq "$(jq -r '.workspaces[0].reviewState' "$DEV_BOARD_CACHE")" "review" "reviewState from open PR (not approved)"
assert_eq "$(jq -r '.workspaces[0].priority' "$DEV_BOARD_CACHE")" "2" "priority merged"
calls1="$(wc -l < "$STUB_LOG" | tr -d ' ')"

# Second call within TTL, no --refresh: must NOT call linear-dash again.
echo "$WL" | "$DIR/../dev-board-collect.sh" --stdin >/dev/null
calls2="$(wc -l < "$STUB_LOG" | tr -d ' ')"
assert_eq "$calls2" "$calls1" "TTL skips network"

# --- Open DRAFT PR -> reviewState "draft" ---
cat > "$STUB/linear-dash" <<'EOF'
#!/usr/bin/env bash
echo "STUBCALL" >> "$STUB_LOG"
echo '[{"branch":"eng-7443","ticket":"ENG-7443","priority":2,"priorityLabel":"High","linearState":"In Progress","linearStateType":"started","pr":{"number":2,"state":"OPEN","isDraft":true,"reviewDecision":"","mergeStateStatus":"UNKNOWN"}}]'
EOF
chmod +x "$STUB/linear-dash"
echo "$WL" | "$DIR/../dev-board-collect.sh" --stdin --refresh >/dev/null
assert_eq "$(jq -r '.workspaces[0].reviewState' "$DEV_BOARD_CACHE")" "draft" "reviewState from open DRAFT PR"
assert_eq "$(jq -r '.workspaces[0].needsReview' "$DEV_BOARD_CACHE")" "false" "draft PR does not need review"
# --- Enumeration via dev-session-sync manifest (the real, non --stdin path) ---
FIX="$(mktemp -d)"
host="$(hostname -s)"
cat > "$FIX/$host.json" <<EOF
[{"session":"eng-7443","branch":"eng-7443","worktree":"/tmp/eng-7443","model":"claude","status":"active","host":"$host","updatedAt":"x"},
 {"session":"gone","branch":"gone","worktree":"/tmp/gone","model":"claude","status":"inactive","host":"$host","updatedAt":"x"}]
EOF
export DEV_BOARD_CACHE="$FIX/cache.json" DEV_SESSION_SYNC_DIR="$FIX"
"$DIR/../dev-board-collect.sh" --refresh >/dev/null
assert_eq "$(jq -r '.workspaces | length' "$DEV_BOARD_CACHE")" "1" "only active session enumerated"
assert_eq "$(jq -r '.workspaces[0].key' "$DEV_BOARD_CACHE")" "eng-7443" "enumerated the active session"
assert_eq "$(jq -r '.workspaces[0].worktree' "$DEV_BOARD_CACHE")" "/tmp/eng-7443" "worktree carried through"
finish
