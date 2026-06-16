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
assert_eq "$(parse_linear_id ca95cc)"        "" "git hash suffix not a ticket"
assert_eq "$(parse_linear_id fix-bug-2024)"  "" "no-ticket branch with trailing number"
assert_eq "$(parse_linear_id matt/eng-7449-print-all)" "ENG-7449" "linear-style branch with slash"

# priority_rank: Urgent=4 High=3 Medium=2 Low=1 None=0
assert_eq "$(priority_rank 1)" "4" "urgent"
assert_eq "$(priority_rank 2)" "3" "high"
assert_eq "$(priority_rank 0)" "0" "none"

# tier_for <priority> <needsReview> <attention>
assert_eq "$(tier_for 2 1 working)" "1" "high+review = act now"
assert_eq "$(tier_for 1 0 blocked)" "1" "urgent+blocked = act now"
assert_eq "$(tier_for 2 0 blocked)" "1" "high+blocked = act now"
assert_eq "$(tier_for 3 1 idle)"    "2" "medium in-review = waiting for review"
assert_eq "$(tier_for 4 1 idle)"    "2" "low in-review = waiting for review"
assert_eq "$(tier_for 3 1 blocked)" "2" "review beats blocked when not high"
assert_eq "$(tier_for 0 0 blocked)" "3" "blocked (not high/review) = needs you"
assert_eq "$(tier_for 3 0 working)" "4" "working = in progress"
assert_eq "$(tier_for 3 0 idle)"    "4" "medium idle = in progress (still actioning)"
assert_eq "$(tier_for 2 0 idle)"    "4" "high idle = in progress"
assert_eq "$(tier_for 4 0 working)" "4" "low but working = in progress"
assert_eq "$(tier_for 4 0 idle)"    "5" "low idle = parked"
assert_eq "$(tier_for 0 0 idle)"    "5" "none idle = parked"

finish
