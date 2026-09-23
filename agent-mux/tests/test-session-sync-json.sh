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

# --- record: tickets + transcriptPath ---
RFIX="$(mktemp -d)"; trap 'rm -rf "$FIX" "$AFIX" "$RFIX"' EXIT
rec() { DEV_SESSION_SYNC_DIR="$RFIX" "$DIR/../dev-session-sync.sh" record "$@" >/dev/null 2>&1; }
rjson() { DEV_SESSION_SYNC_DIR="$RFIX" "$DIR/../dev-session-sync.sh" list --json; }
rget() { rjson | jq -r --arg s "$1" ".[] | select(.session==\$s) | $2"; }

# tickets parsed from session name and branch; explicit ones normalised + unioned
rec feat-x "matt/eng-7717-foo" /tmp/wt/feat-x claude 11111111-aaaa-bbbb-cccc-000000000001 "eng-100,QA-12"
assert_eq "$(rget feat-x '.tickets | join(",")')" "ENG-100,ENG-7717,QA-12" "tickets parsed+explicit, sorted unique"
assert_eq "$(rget feat-x '.transcriptPath')" \
  "$HOME/.claude/projects/-tmp-wt-feat-x/11111111-aaaa-bbbb-cccc-000000000001.jsonl" "transcriptPath from id + munged worktree"

# reattach: no id, no tickets passed -> both preserved
rec feat-x "matt/eng-7717-foo" /tmp/wt/feat-x claude "" ""
assert_eq "$(rget feat-x '.tickets | join(",")')" "ENG-100,ENG-7717,QA-12" "tickets preserved on reattach"
assert_eq "$(rget feat-x '.agentSessionId')" "11111111-aaaa-bbbb-cccc-000000000001" "id preserved on reattach"
assert_eq "$(rget feat-x '.transcriptPath')" \
  "$HOME/.claude/projects/-tmp-wt-feat-x/11111111-aaaa-bbbb-cccc-000000000001.jsonl" "transcriptPath preserved on reattach"

# later record adds a ticket -> union
rec feat-x "matt/eng-7717-foo" /tmp/wt/feat-x claude "" "ENG-200"
assert_eq "$(rget feat-x '.tickets | join(",")')" "ENG-100,ENG-200,ENG-7717,QA-12" "tickets union on re-record"

# no ticket anywhere -> empty array, null transcriptPath (codex)
rec plain-thing "plain-thing" /tmp/wt/plain codex "" ""
assert_eq "$(rget plain-thing '.tickets | length')" "0" "no tickets -> empty array"
assert_eq "$(rget plain-thing '.transcriptPath')" "null" "no id -> null transcriptPath"

# session name alone carries the ticket (branch empty = main checkout)
rec ENG-300 "" /tmp/lupa claude "" ""
assert_eq "$(rget ENG-300 '.tickets | join(",")')" "ENG-300" "ticket from session name"

# --- list table: active-only by default, --all, tickets/chat columns, legacy rows ---
LFIX="$(mktemp -d)"; trap 'rm -rf "$FIX" "$AFIX" "$RFIX" "$LFIX"' EXIT
cat > "$LFIX/h.json" <<EOF
[{"session":"eng-1","branch":"eng-1","worktree":"/tmp/eng-1","model":"claude","status":"active","host":"h","updatedAt":"x",
  "agentSessionId":"aaaa-1","tickets":["ENG-1","ENG-9"]},
 {"session":"legacy","branch":"legacy","worktree":"/tmp/legacy","model":"claude","status":"inactive","host":"h","updatedAt":"x"}]
EOF
lst() { DEV_SESSION_SYNC_DIR="$LFIX" "$DIR/../dev-session-sync.sh" list "$@"; }
assert_eq "$(lst | grep -c '^eng-1 ')" "1" "active row shown"
assert_eq "$(lst | grep -c '^legacy ')" "0" "inactive hidden by default"
assert_eq "$(lst --all | grep -c '^legacy ')" "1" "inactive shown with --all"
assert_eq "$(lst | head -1 | tr -s ' ' | tr ' ' '|')" "SESSION|HOST|STATUS|MODEL|TICKETS|CHAT|UPDATED|BRANCH" "header columns"
assert_eq "$(lst | awk '/^eng-1 /{print $5, $6}')" "ENG-1,ENG-9 aaaa-1" "tickets + chat columns"
assert_eq "$(lst --all | awk '/^legacy /{print $5, $6}')" "- -" "legacy row placeholders"
assert_eq "$(lst --json | jq length)" "2" "--json still returns inactive"
cat > "$LFIX/other.json" <<EOF
[{"session":"eng-555-x","branch":"eng-555-x","worktree":"/tmp/o","model":"claude","status":"active","host":"other","updatedAt":"x"}]
EOF
assert_eq "$(lst | awk '/^eng-555-x /{print $5}')" "ENG-555" "list derives tickets for un-reconciled foreign rows"
assert_eq "$(lst --json | jq -r '.[] | select(.session=="eng-555-x") | .tickets | join(",")')" "ENG-555" "--json derives too"
rm "$LFIX/other.json"

# reconcile backfills tickets on legacy rows (no tickets field), leaves existing alone
DEV_SESSION_SYNC_DIR="$LFIX" DEV_SESSION_SYNC_HOST=h "$DIR/../dev-session-sync.sh" reconcile >/dev/null 2>&1 || true
assert_eq "$(jq -r '.[] | select(.session=="eng-1") | .tickets | join(",")' "$LFIX/h.json")" "ENG-1,ENG-9" "backfill leaves explicit tickets alone"
assert_eq "$(jq -r '.[] | select(.session=="legacy") | .tickets | length' "$LFIX/h.json")" "0" "legacy no-ticket row -> []"
cat > "$LFIX/h2.json" <<EOF
[{"session":"matt/eng-4321-thing","branch":"eng-4321-thing","worktree":"/tmp/x","model":"claude","status":"inactive","host":"h2","updatedAt":"x"},
 {"session":"ca95cc","branch":"fix-bug-2024","worktree":"/tmp/y","model":"claude","status":"inactive","host":"h2","updatedAt":"x"}]
EOF
DEV_SESSION_SYNC_DIR="$LFIX" DEV_SESSION_SYNC_HOST=h2 "$DIR/../dev-session-sync.sh" reconcile >/dev/null 2>&1 || true
assert_eq "$(jq -r '.[] | select(.session=="matt/eng-4321-thing") | .tickets | join(",")' "$LFIX/h2.json")" "ENG-4321" "backfill parses ticket"
assert_eq "$(jq -r '.[] | select(.session=="ca95cc") | .tickets | length' "$LFIX/h2.json")" "0" "backfill ignores hash/year tokens"

lst --md >/dev/null
assert_eq "$([ -f "$LFIX/WORKTREES.md" ] && echo present || echo gone)" "present" "--md writes WORKTREES.md"
assert_eq "$(grep -c '^| eng-1 |' "$LFIX/WORKTREES.md")" "1" "md has active row"
assert_eq "$(grep -c '^| legacy |' "$LFIX/WORKTREES.md")" "1" "md includes inactive rows"
assert_eq "$(grep -c 'ENG-1, ENG-9' "$LFIX/WORKTREES.md")" "1" "md lists tickets"

finish
