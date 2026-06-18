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

# --- adopt: fold an old hostname-named manifest into this machine's UUID manifest ---
# Compute the expected machine UUID the same way the script does.
uuid="$(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | awk -F'"' '/IOPlatformUUID/{print $4; exit}')"
[ -n "$uuid" ] || uuid="$(hostname -s)"

AFIX="$(mktemp -d)"; trap 'rm -rf "$FIX" "$AFIX"' EXIT
cat > "$AFIX/oldhost.json" <<EOF
[{"session":"eng-1111","branch":"eng-1111","worktree":"/tmp/eng-1111","model":"claude","status":"active","host":"oldhost","updatedAt":"2026-01-01T00:00:00Z"},
 {"session":"eng-2222","branch":"eng-2222","worktree":"/tmp/eng-2222","model":"claude","status":"inactive","host":"oldhost","updatedAt":"2026-01-02T00:00:00Z"}]
EOF

DEV_SESSION_SYNC_DIR="$AFIX" "$DIR/../dev-session-sync.sh" adopt oldhost >/dev/null

assert_eq "$([ -f "$AFIX/oldhost.json" ] && echo present || echo gone)" "gone" "old manifest removed"
uuid_file="$AFIX/$uuid.json"
assert_eq "$([ -f "$uuid_file" ] && echo present || echo gone)" "present" "uuid manifest exists"
assert_eq "$(jq 'length' "$uuid_file")" "2" "both sessions adopted"
assert_eq "$(jq -r '[.[] | select(.host==$u)] | length' --arg u "$uuid" "$uuid_file")" "2" "host rewritten to uuid"
assert_eq "$(jq -r '[.[] | select((.hostLabel // "") != "")] | length' "$uuid_file")" "2" "hostLabel set"
assert_eq "$(jq -r '.[] | select(.session=="eng-1111") | .worktree' "$uuid_file")" "/tmp/eng-1111" "adopted worktree present"

finish
