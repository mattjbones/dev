#!/usr/bin/env bash
# Integration: requires gh auth + network (Linear key optional — ticket fields
# just come back null without it). Asserts JSON shape only, not exact counts
# (those depend on live PR state).
set -euo pipefail
DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/board-test-helpers.sh"
DASH="$DIR/../../github-dash"

out="$("$DASH" --json 2>/dev/null || true)"
assert_eq "$(printf '%s' "$out" | jq 'type')" '"object"' "top level is object"
assert_eq "$(printf '%s' "$out" | jq -r '.org')" "LupaPets" "default org"
assert_eq "$(printf '%s' "$out" | jq '.sections | type')" '"array"' "sections is array"
assert_eq "$(printf '%s' "$out" | jq '.sections | length')" "7" "seven fixed sections"

expected_titles='["APPROVED","CHANGES REQUESTED / COMMENTED","OPEN — NO REVIEW","CODEOWNER","FROM HKNAKN/DEC1024","MY OPEN PRS","MY DRAFTS"]'
assert_eq "$(printf '%s' "$out" | jq -c '[.sections[].title]')" "$expected_titles" "section order/labels"

assert_eq "$(printf '%s' "$out" | jq 'all(.sections[]; has("count") and has("prs") and (.prs | type == "array"))')" "true" "each section has count + prs array"
assert_eq "$(printf '%s' "$out" | jq 'all(.sections[]; .count == (.prs | length))')" "true" "count matches prs length"

# Every PR row carries the full row shape, regardless of which section it's in.
assert_eq "$(printf '%s' "$out" | jq '[.sections[].prs[]] | all(has("repo") and has("number") and has("url") and has("author") and has("ticketId") and has("ci") and has("ageIso"))')" "true" "row fields present"

# A PR key (repo#number) never appears in more than one section — the whole
# point of the fixed bucket-priority design.
dupe_count="$(printf '%s' "$out" | jq '[.sections[].prs[] | "\(.repo)#\(.number)"] | group_by(.) | map(select(length > 1)) | length')"
assert_eq "$dupe_count" "0" "no PR appears in more than one section"

# --watch-authors overrides the section label and membership.
watch_out="$("$DASH" --json --watch-authors hknakn 2>/dev/null || true)"
assert_eq "$(printf '%s' "$watch_out" | jq -c '.watchLogins')" '["hknakn"]' "watch-authors override reflected"
assert_eq "$(printf '%s' "$watch_out" | jq -r '.sections[4].title')" "FROM HKNAKN" "watch section label updates"

finish
