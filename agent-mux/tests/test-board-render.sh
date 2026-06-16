#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/board-test-helpers.sh"
source "$DIR/../dev-board.sh"   # sourcing must NOT run the picker (guarded by ${1})

RANKED='[{"key":"eng-7443","ticket":"ENG-7443","priorityLabel":"High","tier":1,"attention":"blocked","lastFocus":99},
         {"key":"calm","ticket":null,"priorityLabel":null,"tier":4,"attention":"idle","lastFocus":1}]'
lines="$(printf '%s' "$RANKED" | board_render_lines 99)"
assert_eq "$(printf '%s' "$lines" | wc -l | tr -d ' ')" "2" "one line per workspace"
printf '%s' "$lines" | head -1 | grep -q '🔴' || fail "tier-1 row shows act-now glyph"
printf '%s' "$lines" | head -1 | grep -q '← you were here' || fail "lastFocus row marked"
finish
