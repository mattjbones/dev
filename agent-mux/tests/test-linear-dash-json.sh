#!/usr/bin/env bash
# Integration: requires LINEAR_API_KEY + gh auth + network. Asserts JSON shape only.
set -euo pipefail
DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/board-test-helpers.sh"
DASH="$DIR/../../linear-dash"

out="$("$DASH" --json --branches eng-7443,appointment-moving 2>/dev/null || true)"
assert_eq "$(printf '%s' "$out" | jq 'type')" '"array"' "is array"
assert_eq "$(printf '%s' "$out" | jq 'length')" "2" "two entries"
assert_eq "$(printf '%s' "$out" | jq -r '.[0].branch')" "eng-7443" "branch echoed"
assert_eq "$(printf '%s' "$out" | jq -r '.[0].ticket')" "ENG-7443" "ticket derived"
# 'appointment-moving' yields no ticket: 'appointment' (11 chars) exceeds the {2,7} team-key bound.
assert_eq "$(printf '%s' "$out" | jq -r '.[1].ticket')" "null" "ad-hoc has no ticket"
assert_eq "$(printf '%s' "$out" | jq 'all(.[]; has("priority") and has("pr"))' )" "true" "fields present"

# Pipe form: explicit ticket overrides derivation; branch is left-of-pipe only.
pipe_out="$("$DASH" --json --branches "eng-7443|ENG-7443" 2>/dev/null || true)"
assert_eq "$(printf '%s' "$pipe_out" | jq -r '.[0].ticket')" "ENG-7443" "pipe: explicit ticket used"
assert_eq "$(printf '%s' "$pipe_out" | jq -r '.[0].branch')" "eng-7443" "pipe: branch is left side"
finish
