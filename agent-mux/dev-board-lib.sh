#!/usr/bin/env bash
# Pure functions for the dev urgency board. No I/O; safe to source and unit-test.

# parse_linear_id <name> -> "ENG-7443" or "" (first TEAM-NNNN token; hyphen required)
parse_linear_id() {
  local name="$1"
  if [[ "$name" =~ (^|[^A-Za-z0-9-])([A-Za-z]{2,7})-([0-9]{2,6}) ]]; then
    printf '%s-%s' "$(printf '%s' "${BASH_REMATCH[2]}" | tr '[:lower:]' '[:upper:]')" "${BASH_REMATCH[3]}"
  fi
}

# priority_rank <linear-priority 0..4> -> sortable rank (Urgent=4..None=0)
priority_rank() {
  case "$1" in
    1) echo 4 ;;  # Urgent
    2) echo 3 ;;  # High
    3) echo 2 ;;  # Medium
    4) echo 1 ;;  # Low
    *) echo 0 ;;  # None / unknown
  esac
}

# tier_for <priority 0..4> <reviewState merge|review|none> <attention blocked|working|idle> -> 1..6
# Act Now is reserved for Linear Urgent (priority 1) — always top, regardless of state.
# Otherwise: blocked > working > ready-to-merge > in-review > medium+ idle > low/none idle.
# 1 Act Now  2 Ready to Merge  3 Waiting for Review  4 Needs You  5 In Progress  6 Parked
tier_for() {
  local priority="${1:?}" review="${2:?}" attention="${3:?}"
  local low=0
  { [ "$priority" = "0" ] || [ "$priority" = "4" ]; } && low=1
  if [ "$priority" = "1" ]; then echo 1
  elif [ "$attention" = "blocked" ]; then echo 4
  elif [ "$attention" = "working" ]; then echo 5
  elif [ "$review" = "merge" ]; then echo 2
  elif [ "$review" = "review" ]; then echo 3
  elif [ "$low" = "0" ]; then echo 5
  else echo 6
  fi
}
