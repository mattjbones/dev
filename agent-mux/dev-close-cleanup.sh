#!/usr/bin/env bash
# Library of docker-cleanup-on-workspace-close functions. Sourced by
# dev-tmux-titled.sh (per-tick) and dev.sh (reattach re-up). Pure functions +
# env-configurable paths so tests can drive it with stubs and fixtures.

DEV_CMUX_EVENTS_FILE="${DEV_CMUX_EVENTS_FILE:-$HOME/.cmuxterm/events.jsonl}"
DEV_STATE_DIR="${DEV_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dev}"
DEV_EVENTS_CURSOR="${DEV_EVENTS_CURSOR:-/tmp/dev-tmux-title/events.seq}"

# Print the RUNNING compose project for <worktree>/docker, or empty. Discovered
# from the container's working_dir label so branch-named projects resolve
# correctly (never derived from the basename).
dc_project_for_worktree() {
  local wt="$1"
  docker ps --filter "label=com.docker.compose.project.working_dir=${wt}/docker" \
            --filter status=running \
            --format '{{.Label "com.docker.compose.project"}}' 2>/dev/null | head -1
}

# Map a cmux workspace uuid -> worktree path via the registry dev.sh writes.
dc_worktree_for_uuid() {
  local uuid="$1" reg="$DEV_STATE_DIR/workspace-map/$1"
  [ -f "$reg" ] && cat "$reg" || true
}

# Emit workspace_ids of new workspace.closed events since the cursor.
# Cursor file stores "<boot_id>:<seq>". First run / boot change → baseline only.
dc_drain_closed() {
  local f="$DEV_CMUX_EVENTS_FILE" cf="$DEV_EVENTS_CURSOR"
  [ -f "$f" ] || return 0
  local last latest_boot latest_seq cur_boot cur_seq
  last="$(tail -1 "$f" 2>/dev/null)"
  latest_boot="$(printf '%s' "$last" | jq -r '.boot_id // empty' 2>/dev/null)"
  latest_seq="$(printf '%s' "$last" | jq -r '.seq // 0' 2>/dev/null)"
  [ -n "$latest_boot" ] || return 0
  if [ -f "$cf" ]; then IFS=: read -r cur_boot cur_seq < "$cf"; else cur_boot=""; cur_seq=0; fi
  mkdir -p "$(dirname "$cf")" 2>/dev/null || true
  if [ "$cur_boot" != "$latest_boot" ]; then
    printf '%s:%s\n' "$latest_boot" "$latest_seq" > "$cf"   # baseline, no replay
    return 0
  fi
  jq -rc --arg boot "$latest_boot" --argjson cur "${cur_seq:-0}" \
    'select(.name=="workspace.closed" and .boot_id==$boot and .seq > $cur) | .payload.workspace_id' \
    "$f" 2>/dev/null
  printf '%s:%s\n' "$latest_boot" "$latest_seq" > "$cf"
}
