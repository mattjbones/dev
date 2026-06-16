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

# tier_for <priority 0..4> <needsReview 0|1> <attention blocked|working|idle> -> 1..5
# Precedence: blocked (you must respond) > working (moving, not waiting) > in-review (idle
# with an open PR / Linear review) > medium+ idle (still actioning) > low/none idle (parked).
# 1 Act Now            = high priority AND (blocked or in-review while idle)
# 2 Waiting for Review = idle + in review, not high
# 3 Needs You          = agent blocked, not high
# 4 In Progress        = agent working, OR medium+ idle (still actioning)
# 5 Parked             = low/none priority, idle, no action
tier_for() {
  local priority="${1:?}" needs_review="${2:?}" attention="${3:?}"
  local high=0 low=0
  { [ "$priority" = "1" ] || [ "$priority" = "2" ]; } && high=1
  { [ "$priority" = "0" ] || [ "$priority" = "4" ]; } && low=1
  if [ "$attention" = "blocked" ]; then
    if [ "$high" = "1" ]; then echo 1; else echo 3; fi
  elif [ "$attention" = "working" ]; then
    echo 4
  elif [ "$needs_review" = "1" ]; then
    if [ "$high" = "1" ]; then echo 1; else echo 2; fi
  elif [ "$low" = "0" ]; then
    echo 4
  else
    echo 5
  fi
}
