#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# dev-ctl.sh — Command centre for managing dev-tmux workspaces
# =============================================================================
#
# Usage:
#   ./dev-ctl.sh              Open interactive command centre
#   ./dev-ctl.sh list         List sessions (non-interactive)
#   ./dev-ctl.sh new <branch> Create a new workspace
#   ./dev-ctl.sh verify-main  Unshallow main lupa repo if needed (for worktrees)
#
# Keybindings (in fzf):
#   enter    Attach to session
#   ctrl-n   New workspace
#   ctrl-s   Send free-text prompt to Claude pane
#   ctrl-p   Quick-actions (to Claude, or !devctl:* local — e.g. verify-main)
#   ctrl-x   Stop docker (keep session)
#   ctrl-d   Full cleanup (docker down, kill session, remove worktree)
#   ctrl-r   Refresh list
#
# =============================================================================

_dctl_source="${BASH_SOURCE[0]:-$0}"
while [ -h "$_dctl_source" ]; do
  _dctl_dir="$(cd -P "$(dirname "$_dctl_source")" && pwd)"
  _dctl_link="$(readlink "$_dctl_source")"
  [[ "$_dctl_link" == /* ]] && _dctl_source="$_dctl_link" || _dctl_source="$_dctl_dir/$_dctl_link"
done
SCRIPT_DIR="$(cd -P "$(dirname "$_dctl_source")" && pwd)"
unset _dctl_source _dctl_dir _dctl_link
CONFIG_DIR="$HOME/.config/dev-ctl"
QUICK_ACTIONS="$CONFIG_DIR/quick-actions.txt"
DEV_TMUX="$SCRIPT_DIR/dev.sh"
LUPA_REPO="/Users/mbarnettjones/workspace/lupa"
GITHUB_REPO="${DEV_CTL_GITHUB_REPO:-LupaPets/lupa}"
CLEANUP_STATE_DIR="/tmp/dev-ctl-cleanup"

# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

read_cleanup_status() {
  local session="$1"
  local cleanup_file="$CLEANUP_STATE_DIR/${session}"

  if [ ! -f "$cleanup_file" ]; then
    return 1
  fi

  # Remove stale cleanup state (older than 5 minutes)
  local raw started_at now elapsed
  raw="$(cat "$cleanup_file" 2>/dev/null || true)"
  started_at="${raw%%|*}"
  if [[ "$started_at" =~ ^[0-9]+$ ]]; then
    now="$(date +%s)"
    elapsed=$(( now - started_at ))
    if [ "$elapsed" -gt 300 ]; then
      rm -f "$cleanup_file"
      return 1
    fi
  fi

  echo "$raw"
}

write_cleanup_status() {
  local session="$1"
  local status="${2:-Deleting}"
  local started_at="${3:-}"
  mkdir -p "$CLEANUP_STATE_DIR"

  if [ -z "$started_at" ] && [ -f "$CLEANUP_STATE_DIR/${session}" ]; then
    started_at="$(cut -d'|' -f1 "$CLEANUP_STATE_DIR/${session}" 2>/dev/null || true)"
  fi

  if [ -z "$started_at" ]; then
    started_at="$(date +%s)"
  fi

  printf "%s|%s\n" "$started_at" "$status" > "$CLEANUP_STATE_DIR/${session}"
}

format_cleanup_status() {
  local session="$1"
  local raw started_at status now elapsed

  raw="$(read_cleanup_status "$session" || true)"
  if [ -z "$raw" ]; then
    return 1
  fi

  started_at="${raw%%|*}"
  status="${raw#*|}"

  if ! [[ "$started_at" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "${status:-Deleting}"
    return 0
  fi

  now="$(date +%s)"
  elapsed=$(( now - started_at ))
  if [ "$elapsed" -lt 0 ]; then
    elapsed=0
  fi

  printf '%s (%ss)\n' "${status:-Deleting}" "$elapsed"
}

# Gather info for a single tmux session and print one status line.
# Format: session_name | status_icon | docker_icon | context_pct | pr_merge | claude_status
# Uses DEV_CTL_PR_CACHE (JSON array) from a batched gh pr list — set in format_sessions.
session_info() {
  local session="$1"
  local cleanup_status=""

  cleanup_status="$(format_cleanup_status "$session" || true)"
  if [ -n "$cleanup_status" ]; then
    printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$session" "⌛" " " " " "—" "$cleanup_status"
    return
  fi

  # Docker status
  local docker_icon=""
  local compose_project
  # Mirror docker-start.sh's compose project normalisation (lowercase, non [a-z0-9_-] -> '-')
  compose_project="$(printf '%s' "$session" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g; s/--*/-/g')"
  local worktree="/Users/mbarnettjones/workspace/$session"
  if docker ps --filter "label=com.docker.compose.project=$compose_project" --filter "status=running" -q 2>/dev/null | grep -q .; then
    docker_icon="🐳"
  # Compose files live in docker/ since #11882, so the working_dir label is <worktree>/docker
  elif docker ps --filter "label=com.docker.compose.project.working_dir=$worktree/docker" --filter "status=running" -q 2>/dev/null | grep -q .; then
    docker_icon="🐳"
  elif docker ps --filter "label=com.docker.compose.project.working_dir=$worktree" --filter "status=running" -q 2>/dev/null | grep -q .; then
    docker_icon="🐳"
  fi
  # Fallback: check for bun/node in session panes
  if [ -z "$docker_icon" ]; then
    for pane_pid in $(tmux list-panes -t "$session" -F '#{pane_pid}' 2>/dev/null); do
      if pgrep -P "$pane_pid" -f 'bun|node' &>/dev/null; then
        docker_icon="🏃"
        break
      fi
    done
  fi

  # Token/context percentage from cache
  local context_pct=""
  local cache_file="/tmp/dev-tmux-title/${session}-tokens"
  if [ -f "$cache_file" ]; then
    context_pct="$(cat "$cache_file" 2>/dev/null)"
  fi

  # Claude status from pane capture (last status line)
  local claude_status=""
  local pane_content
  pane_content="$(tmux capture-pane -t "$session:.0" -p 2>/dev/null || true)"
  local status_line
  status_line="$(echo "$pane_content" | grep -oE '✳ [^(]+' | tail -1 | sed 's/✳ //;s/[[:space:]]*$//' || true)"
  if [ -n "$status_line" ]; then
    claude_status="$status_line"
  fi

  # Format the line
  local status_icon="●"
  if [ -z "$docker_icon" ]; then
    status_icon="○"
  fi

  local wt branch pr_merge=""
  wt="$(worktree_path_for_session "$session" 2>/dev/null || true)"
  if [ -n "$wt" ]; then
    branch="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    pr_merge="$(pr_merge_summary_for_branch "$branch")"
  else
    pr_merge="—"
  fi

  printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$session" "$status_icon" "${docker_icon:- }" "${context_pct:-  }" "$pr_merge" "${claude_status:-Idle}"
}

# List all tmux sessions and their status.
list_sessions() {
  local sessions
  sessions="$(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)"
  if [ -z "$sessions" ]; then
    return
  fi

  while IFS= read -r session; do
    session_info "$session"
  done <<< "$sessions"
}

# List worktrees that don't have an active tmux session.
list_inactive_worktrees() {
  local active_sessions
  active_sessions="$(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)"

  local wt_path="" wt_branch=""

  # Parse porcelain output: fields per entry separated by blank lines
  while IFS= read -r line; do
    case "$line" in
      worktree\ *)
        wt_path="${line#worktree }"
        wt_branch=""
        ;;
      branch\ *)
        wt_branch="${line#branch refs/heads/}"
        ;;
      "")
        # End of entry — emit if inactive
        if [ -n "$wt_path" ] && [ "$wt_path" != "$LUPA_REPO" ]; then
          local wt_name
          wt_name="$(basename "$wt_path")"
          if ! echo "$active_sessions" | grep -qx "$wt_name"; then
            printf "%s\t%s\t%s\n" "$wt_name" "$wt_path" "$wt_branch"
          fi
        fi
        wt_path=""
        wt_branch=""
        ;;
    esac
  done < <(git -C "$LUPA_REPO" worktree list --porcelain 2>/dev/null; echo "")
  # trailing echo "" ensures the last entry is flushed
}

count_inactive_worktrees() {
  list_inactive_worktrees | grep -c '.*' 2>/dev/null || true
}

count_deleting_workspaces() {
  if [ ! -d "$CLEANUP_STATE_DIR" ]; then
    echo 0
    return
  fi

  find "$CLEANUP_STATE_DIR" -maxdepth 1 -type f | wc -l | tr -d ' '
}

list_deleting_workspaces() {
  if [ ! -d "$CLEANUP_STATE_DIR" ]; then
    return
  fi

  find "$CLEANUP_STATE_DIR" -maxdepth 1 -type f -exec basename {} \; 2>/dev/null | sort || true
}

info_line() {
  local inactive_count deleting_count non_actionable matched visible_total
  inactive_count="$(count_inactive_worktrees)"
  deleting_count="$(count_deleting_workspaces)"
  non_actionable=$(( inactive_count + deleting_count ))

  matched="${FZF_MATCH_COUNT:-0}"
  visible_total="${FZF_TOTAL_COUNT:-0}"

  if [ "$matched" -ge "$non_actionable" ]; then
    matched=$(( matched - non_actionable ))
  else
    matched=0
  fi

  printf "%s / %s" "$matched" "$visible_total"
}

# Build a lookup of all worktree names (basename -> path).
all_worktree_names() {
  local wt_path=""
  while IFS= read -r line; do
    case "$line" in
      worktree\ *)
        wt_path="${line#worktree }"
        ;;
      "")
        if [ -n "$wt_path" ] && [ "$wt_path" != "$LUPA_REPO" ]; then
          basename "$wt_path"
        fi
        wt_path=""
        ;;
    esac
  done < <(git -C "$LUPA_REPO" worktree list --porcelain 2>/dev/null; echo "")
}

find_worktree_path_by_name() {
  local target_name="$1"
  local wt_path=""

  while IFS= read -r line; do
    case "$line" in
      worktree\ *)
        wt_path="${line#worktree }"
        ;;
      "")
        if [ -n "$wt_path" ] && [ "$wt_path" != "$LUPA_REPO" ]; then
          if [ "$(basename "$wt_path")" = "$target_name" ]; then
            printf '%s\n' "$wt_path"
            return 0
          fi
        fi
        wt_path=""
        ;;
    esac
  done < <(git -C "$LUPA_REPO" worktree list --porcelain 2>/dev/null; echo "")

  return 1
}

# Filesystem path for a workspace session name (tmux session basename).
worktree_path_for_session() {
  local s="$1"
  if [ "$s" = "lupa" ]; then
    printf '%s\n' "$LUPA_REPO"
    return 0
  fi
  local p
  p="$(find_worktree_path_by_name "$s" 2>/dev/null || true)"
  if [ -n "$p" ] && [ -d "$p" ]; then
    printf '%s\n' "$p"
    return 0
  fi
  local w="/Users/mbarnettjones/workspace/$s"
  if [ -d "$w" ]; then
    printf '%s\n' "$w"
    return 0
  fi
  p="$LUPA_REPO/.claude/worktrees/$s"
  if [ -d "$p" ]; then
    printf '%s\n' "$p"
    return 0
  fi
  return 1
}

# One-line PR state + whether the branch is merged into main (git), using batched gh JSON in DEV_CTL_PR_CACHE.
pr_merge_summary_for_branch() {
  local branch="$1"
  local cache="${DEV_CTL_PR_CACHE:-[]}"
  local pr_line merged_local=""

  if [ -z "$branch" ] || [ "$branch" = "HEAD" ]; then
    printf '%s\n' "—"
    return
  fi
  if [ "$branch" = "main" ] || [ "$branch" = "master" ]; then
    printf '%s\n' "main"
    return
  fi

  if command -v jq &>/dev/null; then
    pr_line="$(
      printf '%s' "$cache" | jq -r --arg b "$branch" '
        [.[] | select(.headRefName == $b)] | sort_by(.number) | reverse | .[0]
        | if . == null then empty else "\(.state) #\(.number)" end
      ' 2>/dev/null || true
    )"
  fi

  if git -C "$LUPA_REPO" branch --merged main 2>/dev/null | grep -qw "$branch"; then
    merged_local=1
  elif git -C "$LUPA_REPO" branch -r --merged origin/main 2>/dev/null | grep -qw "origin/$branch"; then
    merged_local=1
  fi

  if [ -n "$pr_line" ]; then
    if [ -n "$merged_local" ] && [[ "$pr_line" != MERGED* ]]; then
      printf '%s · merged\n' "$pr_line"
    else
      printf '%s\n' "$pr_line"
    fi
  elif [ -n "$merged_local" ]; then
    printf '%s\n' "merged→main"
  else
    if command -v gh &>/dev/null; then
      printf '%s\n' "no PR"
    else
      printf '%s\n' "no gh"
    fi
  fi
}

# List tmux sessions that have no matching worktree on disk.
list_orphaned_sessions() {
  local sessions
  sessions="$(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)"
  if [ -z "$sessions" ]; then
    return
  fi

  local worktree_names
  worktree_names="$(all_worktree_names)"
  local deleting_workspaces
  deleting_workspaces="$(list_deleting_workspaces)"

  while IFS= read -r session; do
    if echo "$deleting_workspaces" | grep -qx "$session"; then
      continue
    fi
    # Skip if a worktree exists for this session (under ~/workspace or .claude/worktrees)
    if echo "$worktree_names" | grep -qx "$session"; then
      continue
    fi
    # Also check if ~/workspace/<session> exists as a directory (might not be a git worktree)
    if [ -d "/Users/mbarnettjones/workspace/$session" ]; then
      continue
    fi
    # Check if it's the main lupa session
    if [ "$session" = "lupa" ]; then
      continue
    fi
    echo "$session"
  done <<< "$sessions"
}

# Format session list for fzf display.
format_sessions() {
  if command -v gh &>/dev/null && command -v jq &>/dev/null; then
    DEV_CTL_PR_CACHE="$(
      gh pr list --repo "$GITHUB_REPO" --state all --limit 400 --json headRefName,state,number 2>/dev/null || echo '[]'
    )"
  else
    DEV_CTL_PR_CACHE="[]"
  fi
  export DEV_CTL_PR_CACHE

  local orphaned
  orphaned="$(list_orphaned_sessions)"
  local deleting_workspaces
  deleting_workspaces="$(list_deleting_workspaces)"
  local inactive
  inactive="$(list_inactive_worktrees)"
  local sessions_raw
  sessions_raw="$(list_sessions)"

  # Calculate max name width across all entries
  local max_w=0
  local n
  if [ -n "$sessions_raw" ]; then
    while IFS=$'\t' read -r name _i _d _c _p _s; do
      n=${#name}; [ "$n" -gt "$max_w" ] && max_w=$n
    done <<< "$sessions_raw"
  fi
  if [ -n "$orphaned" ]; then
    while IFS= read -r name; do
      n=${#name}; [ "$n" -gt "$max_w" ] && max_w=$n
    done <<< "$orphaned"
  fi
  if [ -n "$inactive" ]; then
    while IFS=$'\t' read -r name _rest; do
      n=${#name}; [ "$n" -gt "$max_w" ] && max_w=$n
    done <<< "$inactive"
  fi
  if [ -n "$deleting_workspaces" ]; then
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      n=${#name}; [ "$n" -gt "$max_w" ] && max_w=$n
    done <<< "$deleting_workspaces"
  fi
  # Minimum width
  [ "$max_w" -lt 12 ] && max_w=12

  # Active sessions (with worktrees)
  if [ -n "$sessions_raw" ]; then
    while IFS=$'\t' read -r name icon docker ctx pr_merge status; do
      if echo "$deleting_workspaces" | grep -qx "$name"; then
        continue
      fi
      if echo "$orphaned" | grep -qx "$name"; then
        continue
      fi
      printf "  %s %-${max_w}s %s  %6s  %-26s · %s\n" "$icon" "$name" "$docker" "$ctx" "$pr_merge" "$status"
    done <<< "$sessions_raw"
  fi

  # Orphaned sessions (tmux session exists, no worktree)
  if [ -n "$orphaned" ]; then
    echo "  ── orphaned sessions (no worktree) ─────────────"
    echo "$orphaned" | while IFS= read -r name; do
      printf "  ⚠ %-${max_w}s  %-26s · no worktree\n" "$name" "—"
    done
  fi

  # Inactive worktrees (worktree exists, no tmux session)
  if [ -n "$inactive" ]; then
    echo "  ── inactive worktrees ──────────────────────────"
    echo "$inactive" | while IFS=$'\t' read -r name path branch; do
      if echo "$deleting_workspaces" | grep -qx "$name"; then
        continue
      fi
      printf "  ◌ %-${max_w}s  %-26s · %s\n" "$name" "$(pr_merge_summary_for_branch "${branch:-}")" "${branch:-no branch}"
    done
  fi

  if [ -n "$deleting_workspaces" ]; then
    echo "  ── deleting workspaces ──────────────────────────"
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      local cleanup_status
      cleanup_status="$(format_cleanup_status "$name" || true)"
      printf "  ⌛ %-${max_w}s  %-26s · %s\n" "$name" "—" "${cleanup_status:-Deleting}"
    done <<< "$deleting_workspaces"
  fi
}

# ---------------------------------------------------------------------------
# Actions (called by fzf --bind execute(...) or directly)
# ---------------------------------------------------------------------------

# Resolve worktree directory for a workspace name (session basename).
resolve_workspace_worktree() {
  local name="$1"
  local wt=""
  wt="$(find_worktree_path_by_name "$name" 2>/dev/null || true)"
  if [ -n "$wt" ] && [ -d "$wt" ] && [ "$wt" != "$LUPA_REPO" ]; then
    printf '%s\n' "$wt"
    return 0
  fi
  local wt_path="/Users/mbarnettjones/workspace/$name"
  if [ -d "$wt_path" ] && [ "$wt_path" != "$LUPA_REPO" ]; then
    printf '%s\n' "$wt_path"
    return 0
  fi
  local claude_wt_path="$LUPA_REPO/.claude/worktrees/$name"
  if [ -d "$claude_wt_path" ]; then
    printf '%s\n' "$claude_wt_path"
    return 0
  fi
  return 1
}

# Tear down per-worktree docker compose (same as docker/docker-start.sh: -f docker-compose.dev.yml -p WORKTREE_NAME).
docker_down_for_workspace() {
  local name="$1"
  local worktree="${2:-}"
  local compose_file="$LUPA_REPO/docker/docker-compose.dev.yml"

  if [ -n "$worktree" ] && [ -f "$worktree/docker/docker-compose.dev.yml" ]; then
    compose_file="$worktree/docker/docker-compose.dev.yml"
  fi

  local name_lc name_norm
  name_lc="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
  # docker-start.sh normalises further: non [a-z0-9_-] chars become '-'
  name_norm="$(printf '%s' "$name_lc" | sed 's/[^a-z0-9_-]/-/g; s/--*/-/g')"

  local proj ids
  for proj in "$name" "$name_lc" "$name_norm"; do
    [ -z "$proj" ] && continue
    docker compose -f "$compose_file" -p "$proj" down --volumes --remove-orphans 2>/dev/null || true
  done

  for proj in "$name" "$name_lc" "$name_norm"; do
    [ -z "$proj" ] && continue
    ids="$(docker ps -aq --filter "label=com.docker.compose.project=$proj" 2>/dev/null | tr '\n' ' ')"
    if [ -n "$ids" ]; then
      # shellcheck disable=SC2086
      docker rm -f $ids 2>/dev/null || true
    fi
  done

  if [ -n "$worktree" ] && [ -d "$worktree" ]; then
    # Compose files live in docker/, so check both worktree root and docker/ working_dirs
    local wd
    for wd in "$worktree" "$worktree/docker"; do
      ids="$(docker ps -aq --filter "label=com.docker.compose.project.working_dir=$wd" 2>/dev/null | tr '\n' ' ')"
      if [ -n "$ids" ]; then
        # shellcheck disable=SC2086
        docker rm -f $ids 2>/dev/null || true
      fi
    done
  fi
}

action_attach() {
  local session="$1"
  # If no active tmux session, create one via dev-tmux (without attaching)
  if ! tmux has-session -t "$session" 2>/dev/null; then
    echo "Starting workspace '$session'..."
    DEV_TMUX_NO_ATTACH=1 "$DEV_TMUX" "$session"
  fi
  if [ -n "${TMUX:-}" ]; then
    tmux switch-client -t "$session"
  else
    tmux attach-session -t "$session"
  fi
}

action_new() {
  local branch="$1"
  if [ -z "$branch" ]; then
    return 1
  fi
  # Run dev-tmux.sh in a new detached process
  "$DEV_TMUX" "$branch" &
  disown
  # Give it a moment to create the session
  sleep 2
}

action_stop() {
  local session="$1"
  local worktree=""
  worktree="$(resolve_workspace_worktree "$session" 2>/dev/null || true)"
  if [ -z "$worktree" ]; then
    worktree="$(tmux display-message -t "$session:.0" -p '#{pane_current_path}' 2>/dev/null || true)"
    # Pane cwd may be a subdir — walk up to a tree that has docker/docker-compose.dev.yml
    local d="${worktree:-/Users/mbarnettjones/workspace/$session}"
    while [ -n "$d" ] && [ "$d" != "/" ]; do
      if [ -f "$d/docker/docker-compose.dev.yml" ]; then
        worktree="$d"
        break
      fi
      d="$(dirname "$d")"
    done
  fi

  echo "  Stopping docker for '$session'..."
  docker_down_for_workspace "$session" "${worktree:-}"

  # Kill any node/bun processes in pane 1 (build pane)
  local build_pid
  build_pid="$(tmux list-panes -t "$session:.1" -F '#{pane_pid}' 2>/dev/null || true)"
  if [ -n "$build_pid" ]; then
    pkill -P "$build_pid" 2>/dev/null || true
  fi

  echo "Stopped services for '$session'"
}

action_cleanup() {
  local name="$1"
  local cleanup_file="$CLEANUP_STATE_DIR/${name}"
  local cleanup_started_at
  cleanup_started_at="$(date +%s)"
  write_cleanup_status "$name" "Stopping docker" "$cleanup_started_at"
  trap 'rm -f "$cleanup_file"' EXIT

  if [ "$name" = "lupa" ]; then
    echo "Skipping main repo cleanup"
    return
  fi

  echo "Cleaning up '$name'..."

  # Resolve worktree before docker/tmux so compose -f path and working_dir labels match
  local worktree=""
  worktree="$(resolve_workspace_worktree "$name" 2>/dev/null || true)"

  # 1. Docker — compose down with correct file + project (-p), then remove stragglers by label
  echo "  Stopping docker containers..."
  write_cleanup_status "$name" "Stopping docker" "$cleanup_started_at"
  docker_down_for_workspace "$name" "${worktree:-}"

  # 2. Kill tmux session (stops all pane processes)
  if tmux has-session -t "$name" 2>/dev/null; then
    echo "  Killing tmux session..."
    write_cleanup_status "$name" "Killing tmux" "$cleanup_started_at"
    tmux kill-session -t "$name" 2>/dev/null || true
  fi

  # 3. Remove git worktree (path may already be empty if only tmux/orphan existed)
  if [ -n "$worktree" ]; then
    echo "  Removing worktree at $worktree..."
    write_cleanup_status "$name" "Removing worktree" "$cleanup_started_at"
    git -C "$LUPA_REPO" worktree remove "$worktree" --force 2>/dev/null || true
    # If worktree remove failed (dirty, locked, etc), force-remove the directory
    if [ -d "$worktree" ]; then
      echo "  Force-removing directory..."
      write_cleanup_status "$name" "Removing directory" "$cleanup_started_at"
      rm -rf "$worktree"
      git -C "$LUPA_REPO" worktree prune 2>/dev/null || true
    fi
  fi

  # 4. Traefik config and port claims
  echo "  Cleaning traefik config..."
  write_cleanup_status "$name" "Cleaning config" "$cleanup_started_at"
  rm -f "$HOME/.lupa/traefik/config/${name}.yml" 2>/dev/null || true
  rm -f "$HOME/.lupa/traefik/config/${name}.port-claim" 2>/dev/null || true

  # 5. Vite log
  write_cleanup_status "$name" "Cleaning logs" "$cleanup_started_at"
  rm -f "$LUPA_REPO/.vite-${name}.log" 2>/dev/null || true

  # 6. Token cache
  write_cleanup_status "$name" "Cleaning cache" "$cleanup_started_at"
  rm -f "/tmp/dev-tmux-title/${name}-tokens" 2>/dev/null || true

  # 7. Prune any dangling worktree references
  write_cleanup_status "$name" "Pruning worktrees" "$cleanup_started_at"
  git -C "$LUPA_REPO" worktree prune 2>/dev/null || true

  # 8. Delete local branch if it's not checked out anywhere and remote is gone
  write_cleanup_status "$name" "Cleaning branches" "$cleanup_started_at"
  # Find branches that were associated with this worktree
  # The worktree branch name might differ from the session name, so check both
  local branches_to_check="$name"
  if [ -n "${wt_branch:-}" ]; then
    branches_to_check="$name"$'\n'"$wt_branch"
  fi
  while IFS= read -r branch; do
    [ -n "$branch" ] || continue
    # Skip main/master
    if [ "$branch" = "main" ] || [ "$branch" = "master" ]; then
      continue
    fi
    # Only delete if the branch exists locally and isn't checked out
    if git -C "$LUPA_REPO" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
      if git -C "$LUPA_REPO" branch -d "$branch" 2>/dev/null; then
        echo "  Deleted branch '$branch'"
      elif git -C "$LUPA_REPO" branch -D "$branch" 2>/dev/null; then
        echo "  Force-deleted branch '$branch'"
      fi
    fi
  done <<< "$branches_to_check"

  echo "Done — '$name' fully cleaned up"
}

# Prune local branches that are no longer needed.
# Checks: remote gone, merged into main, PR merged/closed, or no PR and no worktree.
action_prune_branches() {
  printf "${DIM}Fetching and pruning remote refs...${NC}\n"
  git -C "$LUPA_REPO" fetch --prune --quiet origin 2>/dev/null || true

  # Collect branches checked out in worktrees (cannot delete these)
  local worktree_branches
  worktree_branches="$(git -C "$LUPA_REPO" worktree list --porcelain 2>/dev/null | grep '^branch ' | sed 's|^branch refs/heads/||')"

  # Get ALL local branches (not just gone ones)
  local all_branches
  all_branches="$(git -C "$LUPA_REPO" branch --list | sed 's/^[* ] //')"

  if [ -z "$all_branches" ]; then
    printf "${DIM}No branches found.${NC}\n"
    return
  fi

  local count=0
  local skipped=0
  while IFS= read -r branch; do
    [ -n "$branch" ] || continue
    # Skip main/master
    if [ "$branch" = "main" ] || [ "$branch" = "master" ]; then
      continue
    fi
    # Skip branches checked out in a worktree
    if echo "$worktree_branches" | grep -qx "$branch"; then
      continue
    fi

    # Try safe delete first (catches branches fully merged into main)
    if git -C "$LUPA_REPO" branch -d "$branch" 2>/dev/null; then
      printf "  ${RED}✕${NC} Deleted ${BOLD}$branch${NC} ${DIM}(merged)${NC}\n"
      count=$((count + 1))
      continue
    fi

    # Check if remote tracking branch is gone
    local tracking
    tracking="$(git -C "$LUPA_REPO" for-each-ref --format='%(upstream:track)' "refs/heads/$branch" 2>/dev/null)"

    # Check PR status on GitHub
    local pr_state
    pr_state="$(gh pr list --repo "$GITHUB_REPO" --head "$branch" --state all --json state --jq '.[0].state' 2>/dev/null || echo "")"

    if [ "$pr_state" = "MERGED" ] || [ "$pr_state" = "CLOSED" ]; then
      git -C "$LUPA_REPO" branch -D "$branch" 2>/dev/null || true
      printf "  ${RED}✕${NC} Deleted ${BOLD}$branch${NC} ${DIM}(PR $pr_state)${NC}\n"
      count=$((count + 1))
    elif [ "$tracking" = "[gone]" ]; then
      # Remote gone, no PR — likely abandoned
      git -C "$LUPA_REPO" branch -D "$branch" 2>/dev/null || true
      printf "  ${RED}✕${NC} Deleted ${BOLD}$branch${NC} ${DIM}(remote gone)${NC}\n"
      count=$((count + 1))
    else
      skipped=$((skipped + 1))
    fi
  done <<< "$all_branches"

  # Also untrack from Graphite any branches we just deleted
  if command -v gt &>/dev/null; then
    echo ""
    printf "${DIM}Syncing Graphite...${NC}\n"
    gt repo sync --force 2>/dev/null || true
  fi

  echo ""
  printf "${GREEN}Pruned $count branches${NC} ${DIM}($skipped skipped)${NC}\n"
}

# Rebase all active worktrees onto latest origin/main and push clean branches.
action_rebase_all() {
  printf "${DIM}Fetching latest from origin...${NC}\n"
  git -C "$LUPA_REPO" fetch --quiet origin 2>/dev/null || true
  echo ""

  local rebased=0
  local pushed=0
  local skipped=0
  local failed=0

  while IFS= read -r line; do
    local wt_path branch
    wt_path="$(echo "$line" | awk '{print $1}')"
    branch="$(echo "$line" | sed -n 's/.*\[\(.*\)\]/\1/p')"

    # Skip main repo
    if [ "$wt_path" = "$LUPA_REPO" ]; then
      continue
    fi

    local wt_name
    wt_name="$(basename "$wt_path")"

    # Skip if branch is empty (detached HEAD)
    if [ -z "$branch" ]; then
      printf "  ${YELLOW}⊘${NC} %-40s ${DIM}detached HEAD, skipping${NC}\n" "$wt_name"
      skipped=$((skipped + 1))
      continue
    fi

    # Skip worktrees with uncommitted changes
    if [ -n "$(git -C "$wt_path" status --porcelain 2>/dev/null)" ]; then
      printf "  ${YELLOW}⊘${NC} %-40s ${DIM}uncommitted changes, skipping${NC}\n" "$wt_name"
      skipped=$((skipped + 1))
      continue
    fi

    # Rebase onto origin/main
    printf "  ${DIM}↻${NC} %-40s " "$wt_name"
    if git -C "$wt_path" rebase origin/main --quiet 2>/dev/null; then
      printf "${GREEN}rebased${NC}"
      rebased=$((rebased + 1))

      # Push if branch has a remote
      if git -C "$wt_path" rev-parse --abbrev-ref '@{upstream}' &>/dev/null || \
         git -C "$LUPA_REPO" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
        if git -C "$wt_path" push --force-with-lease --quiet origin "$branch" 2>/dev/null; then
          printf " ${GREEN}→ pushed${NC}"
          pushed=$((pushed + 1))
        else
          printf " ${RED}→ push failed${NC}"
          failed=$((failed + 1))
        fi
      fi
      echo ""
    else
      printf "${RED}conflict${NC}\n"
      git -C "$wt_path" rebase --abort 2>/dev/null || true
      failed=$((failed + 1))
    fi
  done < <(git -C "$LUPA_REPO" worktree list)

  echo ""
  printf "${GREEN}Rebased $rebased${NC}, ${GREEN}pushed $pushed${NC}"
  [ "$skipped" -gt 0 ] && printf ", ${YELLOW}skipped $skipped${NC}"
  [ "$failed" -gt 0 ] && printf ", ${RED}failed $failed${NC}"
  echo ""
}

# Full sweep: check all worktrees against PR/merge status and clean up finished ones.
# Also prunes orphaned local branches.
action_auto_cleanup() {
  local dry_run="${1:-false}"

  printf "${DIM}Fetching latest from origin...${NC}\n"
  git -C "$LUPA_REPO" fetch --prune --quiet origin 2>/dev/null || true
  echo ""

  local removed=0
  local kept=0

  while IFS= read -r line; do
    local wt_path branch
    wt_path="$(echo "$line" | awk '{print $1}')"
    branch="$(echo "$line" | sed -n 's/.*\[\(.*\)\]/\1/p')"

    # Skip main repo
    if [ "$wt_path" = "$LUPA_REPO" ]; then
      continue
    fi

    local wt_name
    wt_name="$(basename "$wt_path")"

    # Skip worktrees with uncommitted changes
    if [ -n "$(git -C "$wt_path" status --porcelain 2>/dev/null)" ]; then
      printf "  ${GREEN}● Keep${NC}   ${BOLD}$wt_name${NC}\n"
      printf "           ${DIM}has uncommitted changes${NC}\n"
      echo ""
      kept=$((kept + 1))
      continue
    fi

    # Check merge status
    local merged=false
    if git -C "$LUPA_REPO" branch --merged main 2>/dev/null | grep -qw "$branch"; then
      merged=true
    elif git -C "$LUPA_REPO" branch -r --merged origin/main 2>/dev/null | grep -qw "origin/$branch"; then
      merged=true
    fi

    # Check PR status on GitHub
    local pr_closed=false
    local pr_info pr_state pr_number pr_title
    pr_info="$(gh pr list --repo "$GITHUB_REPO" --head "$branch" --state all --json state,number,title --jq '.[0]' 2>/dev/null || echo "")"
    if [ -n "$pr_info" ] && [ "$pr_info" != "null" ]; then
      pr_state="$(echo "$pr_info" | jq -r '.state // empty' 2>/dev/null)"
      pr_number="$(echo "$pr_info" | jq -r '.number // empty' 2>/dev/null)"
      pr_title="$(echo "$pr_info" | jq -r '.title // empty' 2>/dev/null)"
      if [ "$pr_state" = "MERGED" ] || [ "$pr_state" = "CLOSED" ]; then
        pr_closed=true
      fi
    fi

    if [ "$merged" = true ] || [ "$pr_closed" = true ]; then
      # Build reason
      local reason=""
      [ "$merged" = true ] && reason="merged"
      if [ "$pr_closed" = true ]; then
        [ -n "$reason" ] && reason="$reason, "
        reason="${reason}PR #${pr_number} ${pr_state}"
      fi

      if [ "$dry_run" = true ]; then
        printf "  ${YELLOW}○ Would remove${NC}  ${BOLD}$wt_name${NC}\n"
      else
        printf "  ${RED}✕ Removing${NC}      ${BOLD}$wt_name${NC}\n"
      fi
      printf "           ${DIM}$reason${NC}\n"
      [ -n "${pr_title:-}" ] && printf "           ${DIM}$pr_title${NC}\n"

      if [ "$dry_run" = false ]; then
        # Use action_cleanup for thorough removal
        action_cleanup "$wt_name" 2>/dev/null
      fi
      removed=$((removed + 1))
      echo ""
    else
      printf "  ${GREEN}● Keep${NC}   ${BOLD}$wt_name${NC}\n"
      if [ -n "${pr_number:-}" ]; then
        printf "           ${DIM}PR #${pr_number}: ${pr_state} — ${pr_title}${NC}\n"
      else
        printf "           ${DIM}no PR found${NC}\n"
      fi
      echo ""
      kept=$((kept + 1))
    fi
  done < <(git -C "$LUPA_REPO" worktree list)

  # Prune orphaned branches
  printf "\n${BOLD}── Pruning orphaned branches ──${NC}\n"
  action_prune_branches

  echo ""
  if [ "$dry_run" = true ]; then
    printf "${YELLOW}Would remove $removed worktrees, keep $kept${NC}\n"
  else
    printf "${GREEN}Removed $removed worktrees, kept $kept${NC}\n"
  fi
}

action_send() {
  local session="$1"
  local text="$2"
  if [ -n "$text" ]; then
    tmux send-keys -t "$session:.0" "$text" Enter
  fi
}

# Ensure the main lupa checkout is not shallow (worktrees break on shallow main).
action_verify_main() {
  if [ ! -d "$LUPA_REPO/.git" ]; then
    printf "${RED}No git repo at ${LUPA_REPO}${NC}\n"
    return 1
  fi
  if [ -f "$LUPA_REPO/.git/shallow" ]; then
    printf "${BOLD}Main lupa repo is shallow — running git fetch --unshallow...${NC}\n"
    if git -C "$LUPA_REPO" fetch --unshallow; then
      printf "${GREEN}Done — lupa is no longer shallow.${NC}\n"
    else
      printf "${RED}git fetch --unshallow failed.${NC}\n"
      return 1
    fi
  else
    printf "${GREEN}Main lupa repo is already a full clone (not shallow).${NC}\n"
  fi
}

# ---------------------------------------------------------------------------
# Preview script (called by fzf --preview)
# ---------------------------------------------------------------------------

preview_pane() {
  local session="$1"
  if tmux has-session -t "$session" 2>/dev/null; then
    tmux capture-pane -t "$session:.0" -p -S -40 2>/dev/null || echo "(no pane content)"
  else
    # Inactive worktree — show git log
    local worktree="/Users/mbarnettjones/workspace/$session"
    if [ ! -d "$worktree" ]; then
      # Check claude agent worktrees
      worktree="$LUPA_REPO/.claude/worktrees/$session"
    fi
    if [ -d "$worktree" ]; then
      echo "── Inactive worktree: $worktree ──"
      echo ""
      git -C "$worktree" log --oneline --no-decorate -10 2>/dev/null || true
      echo ""
      echo "── Status ──"
      git -C "$worktree" status --short 2>/dev/null || true
    else
      echo "(worktree not found)"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Sub-command dispatch
# ---------------------------------------------------------------------------

# Export functions and vars so fzf subshells can access them
export SCRIPT_DIR CONFIG_DIR QUICK_ACTIONS DEV_TMUX LUPA_REPO
export CLEANUP_STATE_DIR

case "${1:-}" in
  # Internal commands used by fzf bindings
  __session_info)
    session_info "$2"
    ;;
  __list)
    format_sessions
    ;;
  __preview)
    preview_pane "$2"
    ;;
  __info)
    info_line
    ;;
  __attach)
    action_attach "$2"
    ;;
  __new)
    action_new "$2"
    ;;
  __stop)
    action_stop "$2"
    ;;
  __cleanup)
    action_cleanup "$2"
    ;;
  __send)
    action_send "$2" "$3"
    ;;
  __quick_pick)
    # Show quick-action picker, send result to session
    session="$2"
    if [ ! -f "$QUICK_ACTIONS" ]; then
      echo "No quick-actions.txt found at $QUICK_ACTIONS"
      read -r -n 1
      exit 1
    fi

    selection="$(grep -v '^#' "$QUICK_ACTIONS" | grep -v '^$' | \
      fzf --height=40% --reverse --prompt="Quick action for $session > " \
          --header="^p: pick  •  !devctl:* = run locally (not sent to Claude)" \
          --delimiter='|' --with-nth=1 || true)"

    if [ -n "$selection" ]; then
      prompt="$(echo "$selection" | cut -d'|' -f2 | sed 's/^ *//;s/ *$//')"
      if [[ "$prompt" == '!devctl:'* ]]; then
        _devctl_action="$(printf '%s' "${prompt#!devctl:}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        case "$_devctl_action" in
          verify-main)
            action_verify_main
            ;;
          *)
            printf "${RED}Unknown !devctl action: %s${NC}\n" "$_devctl_action"
            ;;
        esac
        unset _devctl_action
        echo ""
        echo "Press any key to continue..."
        read -r -n 1
      else
        tmux send-keys -t "$session:.0" "$prompt" Enter
        echo "Sent to $session"
        sleep 1
      fi
    fi
    ;;
  __prompt_send)
    # Free-text prompt input
    session="$2"
    printf "Send to %s Claude > " "$session"
    read -r text
    if [ -n "$text" ]; then
      tmux send-keys -t "$session:.0" "$text" Enter
      echo "Sent."
      sleep 1
    fi
    ;;
  __prompt_new)
    # Prompt for branch name and create workspace
    printf "Branch name > "
    read -r branch
    if [ -n "$branch" ]; then
      echo "Creating workspace '$branch'..."
      "$DEV_TMUX" "$branch" &
      disown
      sleep 3
      echo "Done. Refreshing..."
    fi
    ;;

  __prune_branches)
    action_prune_branches
    echo ""
    echo "Press any key to continue..."
    read -r -n 1
    ;;
  __auto_cleanup)
    action_auto_cleanup "${2:-false}"
    echo ""
    echo "Press any key to continue..."
    read -r -n 1
    ;;
  __rebase_all)
    action_rebase_all
    echo ""
    echo "Press any key to continue..."
    read -r -n 1
    ;;

  # Public commands
  list)
    echo "Active dev sessions:"
    echo ""
    format_sessions
    ;;
  new)
    action_new "${2:-}"
    ;;
  prune-branches)
    action_prune_branches
    ;;
  auto-cleanup)
    action_auto_cleanup false
    ;;
  auto-cleanup-dry)
    action_auto_cleanup true
    ;;
  rebase-all)
    action_rebase_all
    ;;
  verify-main)
    action_verify_main
    ;;

  # Default: interactive mode
  *)
    SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

    # Extract session name: always the 2nd whitespace-delimited word (after icon)
    EXTRACT="echo {} | awk '{print \$2}'"

    SELECTION="$(format_sessions | fzf \
      --ansi \
      --reverse \
      --header-first \
      --header="enter=attach  ^n=new  ^s=send  ^p=quick-action  ^x=stop  ^d=cleanup  ^u=rebase-all  ^g=auto-cleanup  ^b=prune-branches  ^r=refresh · PR/merge" \
      --prompt="workspace > " \
      --info=inline-right \
      --info-command="$SELF __info" \
      --preview="$SELF __preview \$($EXTRACT)" \
      --preview-window=right:55%:wrap \
      --bind="enter:become(echo attach:\$($EXTRACT))" \
      --bind="ctrl-n:become(echo new:)" \
      --bind="ctrl-s:execute($SELF __prompt_send \$($EXTRACT))+reload($SELF __list)" \
      --bind="ctrl-p:execute($SELF __quick_pick \$($EXTRACT))+reload($SELF __list)" \
      --bind="ctrl-x:execute-silent($SELF __stop \$($EXTRACT))+reload($SELF __list)" \
      --bind="ctrl-d:execute-silent(nohup $SELF __cleanup \$($EXTRACT) >/tmp/dev-ctl-cleanup-\$($EXTRACT).log 2>&1 &)+reload($SELF __list)" \
      --bind="ctrl-u:execute($SELF __rebase_all)+reload($SELF __list)" \
      --bind="ctrl-g:execute($SELF __auto_cleanup)+reload($SELF __list)" \
      --bind="ctrl-b:execute($SELF __prune_branches)+reload($SELF __list)" \
      --bind="ctrl-r:reload($SELF __list)" \
    || true)"

    # Act on selection after fzf has exited and tty is free
    ACTION="$(echo "$SELECTION" | cut -d: -f1)"
    TARGET="$(echo "$SELECTION" | cut -d: -f2)"

    case "$ACTION" in
      attach)
        if [ -n "$TARGET" ]; then
          action_attach "$TARGET"
          # Exit so the popup closes after switching
          exit 0
        fi
        ;;
      new)
        printf "Branch name > "
        read -r branch
        if [ -n "$branch" ]; then
          echo "Creating workspace '$branch'..."
          DEV_TMUX_NO_ATTACH=1 "$DEV_TMUX" "$branch"
          if [ -n "${TMUX:-}" ]; then
            # switch-client then exit immediately so the popup closes
            tmux switch-client -t "$branch" 2>/dev/null || true
            exit 0
          else
            exec tmux attach-session -t "$branch"
          fi
        fi
        ;;
    esac
    ;;
esac
