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

# tier_for <priority> <reviewState> <attention>
assert_eq "$(tier_for 1 none blocked)"   "1" "urgent+blocked = act now"
assert_eq "$(tier_for 2 none blocked)"   "1" "high+blocked = act now"
assert_eq "$(tier_for 0 none blocked)"   "4" "blocked (not high) = needs you"
assert_eq "$(tier_for 0 merge working)"  "5" "working with mergeable PR = in progress"
assert_eq "$(tier_for 2 review working)" "5" "high + review but working = in progress"
assert_eq "$(tier_for 3 none working)"   "5" "working = in progress"
assert_eq "$(tier_for 3 merge idle)"     "2" "medium ready-to-merge = ready to merge"
assert_eq "$(tier_for 2 merge idle)"     "1" "high ready-to-merge = act now"
assert_eq "$(tier_for 3 review idle)"    "3" "medium in-review = waiting for review"
assert_eq "$(tier_for 2 review idle)"    "1" "high in-review = act now"
assert_eq "$(tier_for 4 merge idle)"     "2" "low ready-to-merge = ready to merge"
assert_eq "$(tier_for 3 none idle)"      "5" "medium idle = in progress"
assert_eq "$(tier_for 2 none idle)"      "5" "high idle no action = in progress"
assert_eq "$(tier_for 4 none idle)"      "6" "low idle = parked"
assert_eq "$(tier_for 0 none idle)"      "6" "none idle = parked"

finish
