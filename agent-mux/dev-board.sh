#!/usr/bin/env bash
# dev board — urgency picker over all dev workspaces.
set -euo pipefail
DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$DIR/dev-board-lib.sh"
source "$DIR/dev-board-state.sh"

TIER_GLYPH() { case "$1" in 1) echo 🔴;; 2) echo 🟢;; 3) echo 🔵;; 4) echo 🟠;; 5) echo 🟡;; *) echo ⚪;; esac; }

# board_render_lines <focus-epoch>  (ranked JSON on stdin) -> tab-separated rows: key<TAB>display
board_render_lines() {
  local focus="${1:-0}"
  jq -r --argjson focus "$focus" '
    .[] | [.key, (.tier|tostring), (.priorityLabel // "-"), (.ticket // "-"), (.attention // "-"),
           (if (.lastFocus // 0) == $focus then "1" else "0" end)] | @tsv
  ' | while IFS=$'\t' read -r key tier prio ticket att here; do
        local mark=""; [ "$here" = "1" ] && mark="  ← you were here"
        printf '%s\t%s  %-22s %-7s %-9s %s%s\n' "$key" "$(TIER_GLYPH "$tier")" "$key" "$prio" "$att" "$ticket" "$mark"
      done
}

# rank_workspaces <workspaces-json-array> -> ranked JSON (attaches fresh local attention + lastFocus).
rank_workspaces() {
  local ws="$1" n i key att lf merged="[]"
  n="$(printf '%s' "$ws" | jq 'length')"
  if [ "$n" -gt 0 ]; then
    for i in $(seq 0 $((n - 1))); do
      key="$(printf '%s' "$ws" | jq -r ".[$i].key")"
      att="$(attention_for_session "$key")"; lf="$(last_focus_for_session "$key")"
      merged="$(printf '%s' "$ws" | jq --argjson m "$merged" --arg k "$key" --arg a "$att" --argjson lf "${lf:-0}" \
                '$m + [(.[] | select(.key==$k)) + {attention:$a, lastFocus:$lf}]')"
    done
  fi
  printf '%s' "$merged" | "$DIR/dev-board-rank.sh"
}

# Build the merged+ranked records (collect cache -> + local state -> rank).
board_ranked() {
  local cache; cache="$("$DIR/dev-board-collect.sh")"
  local ws; ws="$(printf '%s' "$cache" | jq '.workspaces')"
  rank_workspaces "$ws"
}

# Local reflection: rank from the EXISTING cache file (no collector/network) and reorder cmux.
board_reflect() {
  local cache ws ranked
  cache="$(cat "${DEV_BOARD_CACHE:-/tmp/dev-board/cache.json}" 2>/dev/null || echo '{}')"
  ws="$(printf '%s' "$cache" | jq '.workspaces // []' 2>/dev/null || echo '[]')"
  ranked="$(rank_workspaces "$ws")"
  printf '%s' "$ranked" | "$DIR/dev-board-cmux.sh" >/dev/null 2>&1 || true
}

# Interactive picker; enter attaches via dev.
board_pick() {
  local focus ranked; focus="$(tmux display-message -p '#{session_activity}' 2>/dev/null || echo 0)"
  ranked="$(board_ranked)"
  printf '%s' "$ranked" | "$DIR/dev-board-cmux.sh" >/dev/null 2>&1 || true   # reflect into cmux
  local sel
  sel="$(printf '%s' "$ranked" | board_render_lines "$focus" \
        | fzf --ansi --with-nth=2.. --delimiter='\t' --prompt='board> ' \
        | cut -f1)" || true
  [ -n "$sel" ] && exec "$DIR/dev.sh" "$sel"
}

# Only run when executed (not when sourced for tests).
if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
  case "${1:-}" in
    --refresh) "$DIR/dev-board-collect.sh" --refresh >/dev/null; board_pick ;;
    --reflect) board_reflect ;;
    *) board_pick ;;
  esac
fi
