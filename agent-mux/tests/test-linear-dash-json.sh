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

# 3-field form: branch|ticket|pr — gh pr view uses the explicit PR number.
# We assert branch and ticket echo correctly, and that pr is either the requested
# object (when the PR exists) or null (when it doesn't) — never a mis-routed PR.
three_out="$("$DASH" --json --branches "pet-timeline-dates|ENG-1|17120" 2>/dev/null || true)"
assert_eq "$(printf '%s' "$three_out" | jq -r '.[0].branch')" "pet-timeline-dates" "3-field: branch echoed"
assert_eq "$(printf '%s' "$three_out" | jq -r '.[0].ticket')" "ENG-1" "3-field: explicit ticket used"
# When PR #17120 exists, its number is returned; when it doesn't gh returns null — both are valid.
three_pr_num="$(printf '%s' "$three_out" | jq -r '.[0].pr.number // "null"')"
if [ "$three_pr_num" != "null" ]; then
  assert_eq "$three_pr_num" "17120" "3-field: pr.number matches requested PR"
else
  pass  # PR not visible (closed/missing) — branch field still correct, no mis-routing
fi
finish
