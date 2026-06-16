#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/board-test-helpers.sh"

FIX="$(mktemp -d)"; trap 'rm -rf "$FIX"' EXIT
host="$(hostname -s)"
cat > "$FIX/$host.json" <<EOF
[{"session":"eng-7443","branch":"eng-7443","worktree":"/tmp/eng-7443","model":"claude","status":"active","host":"$host","updatedAt":"x"},
 {"session":"old-thing","branch":"old-thing","worktree":"/tmp/old","model":"claude","status":"inactive","host":"$host","updatedAt":"x"}]
EOF
out="$(DEV_SESSION_SYNC_DIR="$FIX" "$DIR/../dev-session-sync.sh" list --json)"
assert_eq "$(printf '%s' "$out" | jq 'type')" '"array"' "json array"
assert_eq "$(printf '%s' "$out" | jq 'length')" "2" "both records"
assert_eq "$(printf '%s' "$out" | jq -r '[.[] | select(.status=="active")] | length')" "1" "one active"
assert_eq "$(printf '%s' "$out" | jq -r '.[] | select(.session=="eng-7443") | .worktree')" "/tmp/eng-7443" "worktree present"
finish
