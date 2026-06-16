#!/usr/bin/env bash
# Pure functions for the dev urgency board. No I/O; safe to source and unit-test.

# parse_linear_id <name> -> "ENG-7443" or "" (first TEAM-NNNN-ish token)
parse_linear_id() {
  local name="$1"
  if [[ "$name" =~ ([A-Za-z]{2,7})-?([0-9]{2,6}) ]]; then
    printf '%s-%s' "$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:lower:]' '[:upper:]')" "${BASH_REMATCH[2]}"
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

# tier_for <priority 0..4> <needsReview 0|1> <attention blocked|working|idle> -> 1..4
tier_for() {
  local priority="$1" needs_review="$2" attention="$3"
  local high=0 needs_action=0
  { [ "$priority" = "1" ] || [ "$priority" = "2" ]; } && high=1
  { [ "$needs_review" = "1" ] || [ "$attention" = "blocked" ]; } && needs_action=1
  if [ "$high" = "1" ] && [ "$needs_action" = "1" ]; then echo 1
  elif [ "$needs_action" = "1" ]; then echo 2
  elif [ "$attention" = "working" ]; then echo 3
  else echo 4; fi
}
