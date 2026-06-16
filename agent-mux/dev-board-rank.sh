#!/usr/bin/env bash
# Reads a JSON array of merged workspace records on stdin; writes the same array
# with `tier` added, sorted by urgency. Pure transform (no network).
set -euo pipefail
DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$DIR/dev-board-lib.sh"

input="$(cat)"
count="$(printf '%s' "$input" | jq 'length')"

# Compute tier per record in bash (uses tier_for), collect tiers as a JSON array.
tiers="[]"
for i in $(seq 0 $((count - 1))); do
  [ "$count" -eq 0 ] && break
  rec="$(printf '%s' "$input" | jq ".[$i]")"
  priority="$(printf '%s' "$rec" | jq -r '.priority // 0')"
  needs_review="$(printf '%s' "$rec" | jq -r 'if .needsReview then 1 else 0 end')"
  attention="$(printf '%s' "$rec" | jq -r '.attention // "idle"')"
  t="$(tier_for "$priority" "$needs_review" "$attention")"
  tiers="$(printf '%s' "$tiers" | jq ". + [$t]")"
done

# Merge tiers back, then sort: tier asc, priorityRank desc, lastFocus desc.
printf '%s' "$input" | jq --argjson tiers "$tiers" '
  def prank: {"1":4,"2":3,"3":2,"4":1} as $m | ($m[(.priority|tostring)] // 0);
  to_entries
  | map(.value + {tier: $tiers[.key]})
  | sort_by([.tier, -(.|prank), -(.lastFocus // 0)])
'
