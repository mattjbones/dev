#!/usr/bin/env bash
# Gather Linear+PR data for active dev workspaces into a TTL-cached JSON file.
# The ONLY networked component. Usage:
#   dev-board-collect.sh [--refresh] [--stdin]
#   --stdin   read the workspace list as JSON on stdin (else enumerate from manifest/tmux)
set -euo pipefail
DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$DIR/dev-board-lib.sh"

CACHE="${DEV_BOARD_CACHE:-/tmp/dev-board/cache.json}"
TTL="${DEV_BOARD_TTL:-180}"
REFRESH=0; STDIN=0
for a in "$@"; do
  case "$a" in --refresh) REFRESH=1 ;; --stdin) STDIN=1 ;; esac
done
mkdir -p "$(dirname "$CACHE")" 2>/dev/null || true

# TTL gate. If the cache is fresh, print it and stop; if it vanished mid-read,
# fall through to a fresh fetch rather than dying under `set -e`.
if [ "$REFRESH" -eq 0 ] && [ -f "$CACHE" ]; then
  age=$(( $(date +%s) - $(stat -f %m "$CACHE" 2>/dev/null || echo 0) ))
  if [ "$age" -lt "$TTL" ] && cat "$CACHE" 2>/dev/null; then exit 0; fi
fi

# Workspace list: {key,branch,worktree}[]
if [ "$STDIN" -eq 1 ]; then
  WL="$(cat)"
else
  # Enumerate this host's active dev sessions from the manifest (machine-readable).
  # Remote-host sessions are excluded: they have no local tmux pane or cmux workspace.
  host="$(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | awk -F'"' '/IOPlatformUUID/{print $4; exit}')"; [ -n "$host" ] || host="$(hostname -s 2>/dev/null || echo unknown)"
  WL="$("$DIR/dev-session-sync.sh" list --json 2>/dev/null \
        | jq --arg h "$host" '[.[] | select(.status == "active" and .host == $h)
            | {key: .session, branch: .branch, worktree: .worktree}]' 2>/dev/null || echo '[]')"
fi

# Build entries for linear-dash and a normalised workspace list (WL2) where
# each record's .branch is replaced with the live git branch for that worktree.
# This makes the merge key (branch) agree between WL2 and the snapshot.
ENTRIES=""
WL2="[]"
while IFS= read -r row; do
  key="$(printf '%s' "$row" | jq -r '.key')"
  manifest_branch="$(printf '%s' "$row" | jq -r '.branch')"
  worktree="$(printf '%s' "$row" | jq -r '.worktree // ""')"

  # Prefer the live git branch; fall back to the manifest branch.
  live_branch=""
  if [ -n "$worktree" ]; then
    live_branch="$(git -C "$worktree" branch --show-current 2>/dev/null || true)"
  fi
  if [ -z "$live_branch" ]; then
    live_branch="$manifest_branch"
  fi

  # Ticket preference: session name first, then live branch.
  name_tkt="$(parse_linear_id "$key" || true)"
  br_tkt="$(parse_linear_id "$live_branch" || true)"
  ticket="${name_tkt:-$br_tkt}"

  # Read the active PR number from the workspace's agent pane (pane .0).
  # Claude Code shows "PR #NNNNN" in the footer; capture-pane on a non-existent
  # session returns empty → pane_pr stays empty → linear-dash falls back to branch lookup.
  pane_pr="$(tmux capture-pane -t "${key}:.0" -p 2>/dev/null | grep -oiE 'PR #?[0-9]{3,6}' | tail -1 | grep -oE '[0-9]{3,6}' || true)"

  entry="${live_branch}|${ticket}|${pane_pr}"
  if [ -z "$ENTRIES" ]; then
    ENTRIES="$entry"
  else
    ENTRIES="${ENTRIES},${entry}"
  fi

  # Update the workspace record to use live_branch as .branch.
  updated_row="$(printf '%s' "$row" | jq --arg lb "$live_branch" '. + {branch: $lb}')"
  WL2="$(printf '%s' "$WL2" | jq --argjson r "$updated_row" '. + [$r]')"
done < <(printf '%s' "$WL" | jq -c '.[]')

if [ -z "$ENTRIES" ]; then
  SNAP='[]'
else
  SNAP="$(linear-dash --json --branches "$ENTRIES" 2>/dev/null || echo '[]')"
fi

# Merge snapshot into workspace list by branch; compute needsReview.
MERGED="$(printf '%s' "$WL2" | jq --argjson snap "$SNAP" '
  ($snap | map({(.branch): .}) | add // {}) as $byBranch
  | map(. as $w | ($byBranch[$w.branch] // {}) as $s
      | $w + {
          ticket: ($s.ticket // null),
          priority: ($s.priority // 0),
          priorityLabel: ($s.priorityLabel // null),
          linearState: ($s.linearState // null),
          linearStateType: ($s.linearStateType // null),
          pr: ($s.pr // null),
          reviewState: (
            if (($s.pr.state // "") == "OPEN" and ($s.pr.isDraft // false) == false
                and ($s.pr.reviewDecision // "") == "APPROVED"
                and ($s.pr.mergeStateStatus // "") == "CLEAN")
            then "merge"
            elif (($s.pr.state // "") == "OPEN" and ($s.pr.isDraft // false) == false)
            then "review"
            elif (($s.pr.state // "") == "OPEN" and ($s.pr.isDraft // false) == true)
            then "draft"
            elif (($s.linearState // "") | test("review"; "i"))
            then "review"
            else "none" end
          ),
          needsReview: (
            (($s.pr.state // "") == "OPEN" and ($s.pr.isDraft // false) == false)
            or (($s.linearState // "") | test("review"; "i"))
          )
        })
')"

# Atomic write: a concurrent reader (e.g. the attach-refresh hook racing a manual
# `dev board`) must never see a half-written cache. Write to a temp file, then rename.
CACHE_TMP="$(dirname "$CACHE")/.cache.json.tmp.$$"
printf '%s' "{\"generatedAt\": $(date +%s), \"workspaces\": $MERGED}" > "$CACHE_TMP"
mv "$CACHE_TMP" "$CACHE"
cat "$CACHE"
