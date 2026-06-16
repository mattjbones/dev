#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/board-test-helpers.sh"
source "$DIR/../dev-board-lib.sh"

# parse_linear_id
assert_eq "$(parse_linear_id eng-7443)"                    "ENG-7443" "plain eng"
assert_eq "$(parse_linear_id eng-7449-matt-print-all-ca95cc)" "ENG-7449" "eng with suffix"
assert_eq "$(parse_linear_id appointment-moving)"          ""         "no ticket"
assert_eq "$(parse_linear_id QA-12)"                       "QA-12"    "other team"

# priority_rank: Urgent=4 High=3 Medium=2 Low=1 None=0
assert_eq "$(priority_rank 1)" "4" "urgent"
assert_eq "$(priority_rank 2)" "3" "high"
assert_eq "$(priority_rank 0)" "0" "none"

# tier_for <priority> <needsReview:0|1> <attention>
assert_eq "$(tier_for 2 1 working)"  "1" "high+review = act now"
assert_eq "$(tier_for 2 0 blocked)"  "1" "high+blocked = act now"
assert_eq "$(tier_for 3 1 working)"  "2" "med+review = needs you"
assert_eq "$(tier_for 0 0 blocked)"  "2" "none+blocked = needs you"
assert_eq "$(tier_for 3 0 working)"  "3" "working"
assert_eq "$(tier_for 4 0 idle)"     "4" "parked"

finish
