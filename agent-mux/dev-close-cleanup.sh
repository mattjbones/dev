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
