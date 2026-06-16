#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/board-test-helpers.sh"

out="$("$DIR/../dev-board-rank.sh" < "$DIR/fixtures/records.json")"
order="$(printf '%s' "$out" | jq -r '.[].key' | tr '\n' ',')"
# Expected: tier1 (urgent-blocked, high-review), tier2 (med-blocked), tier3 (working), tier4 (low-idle)
assert_eq "$order" "urgent-blocked,high-review,med-blocked,working,low-idle," "ranked order"
tiers="$(printf '%s' "$out" | jq -r '.[].tier' | tr '\n' ',')"
assert_eq "$tiers" "1,1,2,3,4," "tiers"
# Empty input must yield an empty array, no error.
empty="$(echo '[]' | "$DIR/../dev-board-rank.sh")"
assert_eq "$(printf '%s' "$empty" | jq -c '.')" "[]" "empty input"

# lastFocus breaks ties within the same tier+priority (higher = first).
tie='[{"key":"older","priority":3,"needsReview":false,"attention":"working","lastFocus":50},
      {"key":"newer","priority":3,"needsReview":false,"attention":"working","lastFocus":99}]'
tieorder="$(printf '%s' "$tie" | "$DIR/../dev-board-rank.sh" | jq -r '.[].key' | tr '\n' ',')"
assert_eq "$tieorder" "newer,older," "lastFocus tiebreak desc"

finish
