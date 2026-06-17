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

# tier_for <priority> <reviewState> <attention>  — Act Now = Urgent (1) only
assert_eq "$(tier_for 1 none idle)"      "1" "urgent idle = act now"
assert_eq "$(tier_for 1 none working)"   "1" "urgent always act now (even working)"
assert_eq "$(tier_for 1 review blocked)" "1" "urgent always act now (even blocked)"
assert_eq "$(tier_for 2 none blocked)"   "4" "high+blocked = needs you (not act now)"
assert_eq "$(tier_for 0 none blocked)"   "4" "blocked = needs you"
assert_eq "$(tier_for 2 merge working)"  "2" "approved = Approved even while working"
assert_eq "$(tier_for 0 merge blocked)"  "2" "approved = Approved even when agent blocked"
assert_eq "$(tier_for 3 none working)"   "5" "working (no PR) = in progress"
assert_eq "$(tier_for 2 merge idle)"     "2" "approved idle = Approved (not act now)"
assert_eq "$(tier_for 3 merge idle)"     "2" "approved idle = Approved"
assert_eq "$(tier_for 2 review idle)"    "3" "high in-review = waiting for review (not act now)"
assert_eq "$(tier_for 3 review idle)"    "3" "medium in-review = waiting for review"
assert_eq "$(tier_for 3 none idle)"      "5" "medium idle = in progress"
assert_eq "$(tier_for 2 none idle)"      "5" "high idle no action = in progress"
assert_eq "$(tier_for 4 none idle)"      "6" "low idle = parked"
assert_eq "$(tier_for 0 none idle)"      "6" "none idle = parked"
assert_eq "$(tier_for 0 draft idle)" "5" "draft PR (none priority) = in progress"
assert_eq "$(tier_for 4 draft idle)" "5" "draft PR (low priority) = in progress"
assert_eq "$(tier_for 3 draft idle)" "5" "draft PR (medium) = in progress"

finish
