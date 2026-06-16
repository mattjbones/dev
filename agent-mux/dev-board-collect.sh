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
  WL="$("$DIR/dev-session-sync.sh" list 2>/dev/null \
        | jq '[.[] | select(.active == true) | {key: .session, branch: .branch, worktree: .worktree}]' 2>/dev/null || echo '[]')"
fi

branches="$(printf '%s' "$WL" | jq -r '[.[].branch] | join(",")')"
if [ -z "$branches" ]; then
  SNAP='[]'
else
  SNAP="$(linear-dash --json --branches "$branches" 2>/dev/null || echo '[]')"
fi

# Merge snapshot into workspace list by branch; compute needsReview.
MERGED="$(printf '%s' "$WL" | jq --argjson snap "$SNAP" '
  ($snap | map({(.branch): .}) | add // {}) as $byBranch
  | map(. as $w | ($byBranch[$w.branch] // {}) as $s
      | $w + {
          ticket: ($s.ticket // null),
          priority: ($s.priority // 0),
          priorityLabel: ($s.priorityLabel // null),
          linearState: ($s.linearState // null),
          linearStateType: ($s.linearStateType // null),
          pr: ($s.pr // null),
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
