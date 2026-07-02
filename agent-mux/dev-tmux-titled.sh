#!/usr/bin/env bash
# Single long-lived daemon that refreshes every dev session's tmux/cmux titles.
#
# Replaces the old model where each session wired dev-tmux-title.sh into tmux's
# status-right as a "#(...)" command. tmux re-runs status #() commands on every
# status redraw - not just on status-interval - and an actively-streaming agent
# pane redraws constantly. So N sessions x frequent redraws x ~27 forks per
# worker run became a process-spawn storm that pegged sysmond, Microsoft
# Defender (a scan per exec) and XProtect.
#
# Here ONE process loops on a fixed interval, walks every dev session once per
# tick, and runs the per-session worker sequentially (no fork burst). The
# status line is now a plain clock, so redraws cost nothing. The daemon also
# covers backgrounded (0-client) sessions directly, which makes the worker's
# old "title sweep" unnecessary, and owns the periodic board reflect.
#
# Singleton-guarded: every `dev` invocation launches it, but only the first
# instance survives - the rest exit immediately.

set -u

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=dev-close-cleanup.sh
. "$SCRIPT_DIR/dev-close-cleanup.sh"
INTERVAL="${DEV_TITLE_INTERVAL:-15}"

LOCK_DIR="/tmp/dev-tmux-title"
LOCK="$LOCK_DIR/daemon.lock"   # an empty dir used as the mutex (atomic mkdir)
PIDFILE="$LOCK_DIR/daemon.pid" # sibling file so the lock dir stays rmdir-able
mkdir -p "$LOCK_DIR" 2>/dev/null || true

# --- Singleton: only one daemon at a time -----------------------------------
acquire_lock() {
  if mkdir "$LOCK" 2>/dev/null; then
    return 0
  fi
  # Lock exists. Reclaim it only if the recorded owner is gone.
  local other lock_age
  other="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [ -n "$other" ] && kill -0 "$other" 2>/dev/null; then
    return 1   # a healthy daemon is already running
  fi
  # Owner dead, or no pid recorded yet. A launcher that just won the mkdir is
  # about to write its pid, so don't steal a freshly-created lock out from under
  # it - only reclaim one that's clearly stale.
  lock_age=$(( $(date +%s) - $(stat -f %m "$LOCK" 2>/dev/null || echo 0) ))
  if [ -z "$other" ] && [ "$lock_age" -lt 30 ]; then
    return 1
  fi
  rmdir "$LOCK" 2>/dev/null || true
  mkdir "$LOCK" 2>/dev/null || return 1
  return 0
}

acquire_lock || exit 0
echo "$$" > "$PIDFILE" 2>/dev/null || true
# Release the lock on exit, but only if we still own it - a newer daemon may
# have taken over (see the ownership re-check in the loop), and we mustn't pull
# the lock out from under it.
owns_lock() { [ "$(cat "$PIDFILE" 2>/dev/null)" = "$$" ]; }
# EXIT does the cleanup; INT/TERM just exit (a bare `trap '…' TERM` handler would
# run and then RESUME the loop, leaving the daemon effectively unkillable by a
# normal `kill`). Routing INT/TERM through `exit` fires the EXIT trap once.
trap 'owns_lock && rmdir "$LOCK" 2>/dev/null' EXIT
trap 'exit 0' INT TERM

# --- Periodic data refresh + sidebar re-sort (cmux only, global, self-gated) --
# Ported from the worker (was per-focused-session, #25): refresh PR/Linear data
# (TTL-gated, network) THEN re-rank + reorder cmux, so the board doesn't go stale
# on PR/review movement. The daemon is singleton, so no cross-process reflect
# lock is needed - the timestamp gate alone keeps it to once per interval.
CMUX_BIN="$(command -v cmux 2>/dev/null || echo /Applications/cmux.app/Contents/Resources/bin/cmux)"
reflect_if_due() {
  [ -x "$CMUX_BIN" ] || return 0
  local interval stamp now m
  interval="${DEV_BOARD_REFLECT_INTERVAL:-300}"
  stamp="/tmp/dev-board/last-reflect"
  mkdir -p /tmp/dev-board 2>/dev/null || true
  now="$(date +%s)"
  m="$(stat -f %m "$stamp" 2>/dev/null || echo 0)"
  if [ "$(( now - m ))" -ge "$interval" ]; then
    touch "$stamp" 2>/dev/null || true
    ( "$SCRIPT_DIR/dev-board-collect.sh" >/dev/null 2>&1
      "$SCRIPT_DIR/dev-board.sh" --reflect >/dev/null 2>&1 ) &
  fi
}

# --- Prefetch running docker compose containers once per tick ---------------
# Each worker would otherwise run `docker ps` up to 3x; across a fleet that's
# the heaviest per-pass cost (a daemon socket round-trip each). Snapshot once
# and export it so workers match in-process. DEV_DOCKER_PREFETCHED signals the
# worker to use the snapshot even when it's empty (no containers != not fetched).
prefetch_docker() {
  command -v docker >/dev/null 2>&1 || return 0
  DEV_DOCKER_RUNNING="$(docker ps --filter status=running \
    --format '{{.Label "com.docker.compose.project"}}|{{.Label "com.docker.compose.project.working_dir"}}' 2>/dev/null)"
  DEV_DOCKER_PREFETCHED=1
  export DEV_DOCKER_RUNNING DEV_DOCKER_PREFETCHED
}

# --- Resolve a session's worker invocation ----------------------------------
# New sessions store it in the @dev_title_cmd user option (tmux never executes
# user options, so it costs nothing on redraw). Legacy sessions still carry it
# inside status-right "#(...)  %H:%M" - adopt and normalise those so the daemon
# takes ownership and their redraws stop spawning the worker.
title_cmd_for() {
  local s="$1" cmd sr
  cmd="$(tmux show-options -t "$s" -qv @dev_title_cmd 2>/dev/null)"
  if [ -n "$cmd" ]; then
    printf '%s' "$cmd"
    return 0
  fi
  sr="$(tmux show-options -t "$s" -v status-right 2>/dev/null)"
  case "$sr" in
    *dev-tmux-title.sh*)
      cmd="${sr#*#(}"
      cmd="${cmd%")  %H:%M"}"
      [ -n "$cmd" ] || return 1
      tmux set-option -t "$s" @dev_title_cmd "$cmd" 2>/dev/null || true
      tmux set-option -t "$s" status-right "%H:%M" 2>/dev/null || true
      tmux set-option -t "$s" status-interval 60 2>/dev/null || true
      printf '%s' "$cmd"
      return 0
      ;;
  esac
  return 1
}

# --- Main loop --------------------------------------------------------------
while :; do
  # Bow out if a newer daemon has taken ownership (e.g. after a redeploy that
  # reclaimed the lock). Keeps us strictly singleton even if the lock dir was
  # removed out from under us.
  owns_lock || exit 0

  sessions="$(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)"
  [ -n "$sessions" ] || exit 0   # tmux server gone -> nothing to drive

  # Pass 1 - adopt/normalise every session first. This is cheap (a couple of
  # set-options) and, crucially, strips the legacy "#()" off status-right
  # immediately, so a slow Pass 2 doesn't run alongside legacy sessions still
  # self-spawning the worker on their old status poll.
  cmds=()
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    cmd="$(title_cmd_for "$s")" || continue
    cmds+=("$cmd")
  done <<EOF
$sessions
EOF

  [ "${#cmds[@]}" -gt 0 ] || exit 0   # no dev sessions left -> stop the daemon

  # Pass 2 - refresh each session's title (the expensive part), sequentially so
  # we never burst a fleet of workers at once. One docker ps for the whole pass.
  prefetch_docker
  for cmd in "${cmds[@]}"; do
    eval "$cmd" >/dev/null 2>&1 || true
  done

  dc_tick || true

  reflect_if_due
  sleep "$INTERVAL"
done
