#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/board-test-helpers.sh"

# Stub linear-dash on PATH so no network is hit.
STUB="$(mktemp -d)"
cat > "$STUB/linear-dash" <<'EOF'
#!/usr/bin/env bash
echo "STUBCALL" >> "$STUB_LOG"
echo '[{"branch":"eng-7443","ticket":"ENG-7443","priority":2,"priorityLabel":"High","linearState":"In Review","linearStateType":"started","pr":{"number":1,"state":"OPEN","isDraft":false,"reviewDecision":"CHANGES_REQUESTED","mergeStateStatus":"BLOCKED"}}]'
EOF
chmod +x "$STUB/linear-dash"
export PATH="$STUB:$PATH" STUB_LOG="$STUB/log"
export DEV_BOARD_CACHE="$STUB/cache.json"

# Feed an explicit workspace list (avoids tmux/manifest dependency in the test).
WL='[{"key":"eng-7443","branch":"eng-7443","worktree":"/tmp/eng-7443"}]'
echo "$WL" | "$DIR/../dev-board-collect.sh" --stdin --refresh >/dev/null
assert_eq "$(jq -r '.workspaces[0].needsReview' "$DEV_BOARD_CACHE")" "true" "needsReview from PR"
assert_eq "$(jq -r '.workspaces[0].priority' "$DEV_BOARD_CACHE")" "2" "priority merged"
calls1="$(wc -l < "$STUB_LOG" | tr -d ' ')"

# Second call within TTL, no --refresh: must NOT call linear-dash again.
echo "$WL" | "$DIR/../dev-board-collect.sh" --stdin >/dev/null
calls2="$(wc -l < "$STUB_LOG" | tr -d ' ')"
assert_eq "$calls2" "$calls1" "TTL skips network"
finish
