#!/usr/bin/env bash
set -euo pipefail

# Usage: ./dev.sh [--model claude|codex] [--no-docker] [branch-name]
#        ./dev.sh ctl|control [args...]   → dev-ctl.sh (workspace picker / subcommands)
# Resolves <branch-name> via git worktree list, ~/workspace/<name>, or
# lupa/.claude/worktrees/<name>; otherwise adds ~/workspace/<name> off main.
# If no branch given, defaults to the main lupa repo.
#
# Flags:
#   --model claude|codex   Agent to run in the left pane (default: claude)
#   --no-docker            Skip docker-start.sh (bare terminal instead)

# Real directory of this script (works when invoked via symlink, e.g. ~/bin/dev).
_dev_source="${BASH_SOURCE[0]:-$0}"
while [ -h "$_dev_source" ]; do
  _dev_dir="$(cd -P "$(dirname "$_dev_source")" && pwd)"
  _dev_link="$(readlink "$_dev_source")"
  [[ "$_dev_link" == /* ]] && _dev_source="$_dev_link" || _dev_source="$_dev_dir/$_dev_link"
done
SCRIPT_DIR="$(cd -P "$(dirname "$_dev_source")" && pwd)"
unset _dev_source _dev_dir _dev_link
LUPA_REPO="$HOME/workspace/lupa"

# Set by ensure_monorepo_deps when it starts a background pnpm install, so the
# build pane can wait for it before launching the dev server. Empty = no wait.
PNPM_INSTALL_DONE_FILE=""
PNPM_INSTALL_LOG_FILE=""

# Worktrees get their own monorepo/node_modules. pnpm's content-addressable
# store keeps packages shared across worktrees without sharing the node_modules
# directory itself, which is brittle across different lockfiles and branches.
run_pnpm_install() {
  if command -v corepack >/dev/null 2>&1; then
    corepack pnpm install
  else
    pnpm install
  fi
}

ensure_monorepo_deps() {
  local wt="$1"
  local monorepo="$wt/monorepo"
  local wt_nm="$wt/monorepo/node_modules"
  local main_nm="$LUPA_REPO/monorepo/node_modules"
  local nm_target
  local log_slug log_file

  if [ ! -d "$monorepo" ]; then
    return
  fi

  if [ "${DEV_SKIP_PNPM_INSTALL:-0}" = "1" ]; then
    echo "Skipping pnpm install (DEV_SKIP_PNPM_INSTALL=1)."
    return
  fi

  if [ -L "$wt_nm" ]; then
    nm_target="$(readlink "$wt_nm")"
    if [ "$nm_target" = "$main_nm" ]; then
      echo "Removing shared monorepo/node_modules symlink; pnpm will install for this worktree."
      rm "$wt_nm"
    else
      echo "monorepo/node_modules is a symlink to '$nm_target'; leaving it unchanged."
      return
    fi
  fi

  if [ -d "$wt_nm" ]; then
    return
  fi

  if [ -e "$wt_nm" ]; then
    echo "monorepo/node_modules exists but is not a directory; leaving it unchanged."
    return
  fi

  log_slug="$(printf '%s' "$(basename "$wt")" | tr -c '[:alnum:]_.-' '-')"
  log_file="/tmp/dev-pnpm-install-${log_slug}.log"
  local done_file="/tmp/dev-pnpm-install-${log_slug}.done"
  rm -f "$done_file"

  echo "Installing monorepo deps for this worktree with pnpm (log: $log_file)..."
  # Record the install's exit code on completion so the build pane can wait for
  # node_modules before starting nx/vite (see dev-wait-pnpm.sh).
  (cd "$monorepo" && run_pnpm_install >"$log_file" 2>&1; echo "$?" >"$done_file") &

  PNPM_INSTALL_DONE_FILE="$done_file"
  PNPM_INSTALL_LOG_FILE="$log_file"
}

usage() {
  local me
  me="$(basename "$0")"
  cat <<EOF
Usage: $me [options] [branch-name]

Create or reuse a git worktree for <branch> (from $LUPA_REPO): prefers git's
registered path, then ~/workspace/<branch>, then $LUPA_REPO/.claude/worktrees/<branch>.
Otherwise adds a new worktree under ~/workspace/<branch>. Opens tmux: agent,
build (optional Docker), and shell. With no branch name, uses the main lupa checkout.

Options:
  --model claude|codex   Agent in the first pane (default: claude)
  --no-docker            Do not run ./docker/docker-start.sh in the build pane
  --services LIST        Accepted; not passed to docker-start (worktree name only)
  -h, --help             Show this help

Environment:
  DEV_TMUX_NO_ATTACH=1       Create the tmux session but do not attach (dev-ctl.sh)
  DEV_SKIP_PNPM_INSTALL=1    Do not start a per-worktree pnpm install when
                             monorepo/node_modules is missing

Commands:
  ctl, control [args...]  Run dev-ctl (same as $SCRIPT_DIR/dev-ctl.sh). Extra args
                          are forwarded (e.g. ctl list, ctl new my-branch).

In tmux: Ctrl-a W opens the dev-ctl command centre ($SCRIPT_DIR/dev-ctl.sh).

Use -- before a branch name that looks like a command (e.g. $me -- ctl).
EOF
}

# Type a command into a pane, but only after its shell has rendered a prompt.
# send-keys straight after pane creation can race zsh/ZLE init and lose the
# first character(s) of the command (e.g. the leading "/" of an absolute path).
send_keys_when_ready() {
  local target="$1" cmd="$2"
  local i
  for i in $(seq 1 50); do
    if [ -n "$(tmux capture-pane -p -t "$target" 2>/dev/null | tr -d '[:space:]')" ]; then
      break
    fi
    sleep 0.1
  done
  sleep 0.2  # let ZLE finish initialising after the prompt paints
  tmux send-keys -t "$target" "$cmd" Enter
}

propagate_cmux_env() {
  local session="$1"
  local var value

  for var in \
    CMUX_WORKSPACE_ID \
    CMUX_SURFACE_ID \
    CMUX_TAB_ID \
    CMUX_SOCKET_PATH \
    CMUX_SOCKET \
    CMUX_SOCKET_PASSWORD
  do
    if [ -n "${!var:-}" ]; then
      value="${!var}"
      tmux set-environment -t "$session" "$var" "$value"
    else
      tmux set-environment -r -t "$session" "$var" 2>/dev/null || true
    fi
  done
}

MODEL="claude"
USE_DOCKER=true
SERVICES="server"

# Parse flags
while [[ "${1:-}" == -* ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --model)
      MODEL="${2:-claude}"
      shift 2
      ;;
    --no-docker)
      USE_DOCKER=false
      shift
      ;;
    --services)
      SERVICES="${2:-server,work}"
      shift 2
      ;;
    *)
      echo "Unknown option: $1 (try --help)"
      exit 1
      ;;
  esac
done

case "${1:-}" in
  ctl|control)
    shift
    exec "$SCRIPT_DIR/dev-ctl.sh" "$@"
    ;;
esac

if [ "${1:-}" = "--" ]; then
  shift
fi

# Ensure the main repo is never shallow — shallow history breaks worktrees
if [ -f "$LUPA_REPO/.git/shallow" ]; then
  echo "Unshallowing lupa repo (shallow history breaks worktrees)..."
  git -C "$LUPA_REPO" fetch --unshallow
fi

BRANCH="${1:-}"

if [ -n "$BRANCH" ]; then
  WORKTREE="$HOME/workspace/$BRANCH"
  CLAUDE_WORKTREE="$LUPA_REPO/.claude/worktrees/$BRANCH"
  EXISTING_WORKTREE="$(
    git -C "$LUPA_REPO" worktree list --porcelain 2>/dev/null | awk -v branch="refs/heads/$BRANCH" '
      $1 == "worktree" { wt = $2 }
      $1 == "branch" && $2 == branch { print wt; exit }
    '
  )"

  if [ -n "$EXISTING_WORKTREE" ] && [ -d "$EXISTING_WORKTREE" ]; then
    echo "Branch '$BRANCH' already has a worktree at '$EXISTING_WORKTREE', reusing it."
    WORKTREE="$EXISTING_WORKTREE"
  elif [ -d "$WORKTREE" ]; then
    echo "Worktree '$WORKTREE' already exists, reusing it."
  elif [ -d "$CLAUDE_WORKTREE" ]; then
    echo "Branch '$BRANCH' has a Claude worktree at '$CLAUDE_WORKTREE', reusing it."
    WORKTREE="$CLAUDE_WORKTREE"
  else
    echo "Creating worktree '$BRANCH' at $WORKTREE..."
    git -C "$LUPA_REPO" fetch --quiet origin

    if git -C "$LUPA_REPO" show-ref --verify --quiet "refs/heads/$BRANCH"; then
      # Local branch exists — rebase onto latest main before checking out
      git -C "$LUPA_REPO" branch -f "$BRANCH" origin/main 2>/dev/null || true
      git -C "$LUPA_REPO" worktree add "$WORKTREE" "$BRANCH"
    elif git -C "$LUPA_REPO" show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
      git -C "$LUPA_REPO" worktree add "$WORKTREE" -b "$BRANCH" "origin/$BRANCH"
    else
      git -C "$LUPA_REPO" worktree add "$WORKTREE" -b "$BRANCH" origin/main
    fi

    # Ensure the branch tracks origin/main
    git -C "$WORKTREE" branch --set-upstream-to=origin/main 2>/dev/null || true
  fi
else
  WORKTREE="$LUPA_REPO"
fi

WORKSPACE_NAME="$(basename "$WORKTREE")"
MONOREPO="$WORKTREE/monorepo"
SESSION="$WORKSPACE_NAME"

# Sync workspace state to OneDrive (best-effort, never blocks dev startup):
# reconcile tags sessions closed since last invocation as inactive, record
# upserts this one as active so another machine can `dev-session-sync restore`.
SESSION_SYNC_SCRIPT="$SCRIPT_DIR/dev-session-sync.sh"
sync_session_state() {
  if [ -x "$SESSION_SYNC_SCRIPT" ]; then
    "$SESSION_SYNC_SCRIPT" reconcile 2>/dev/null || true
    "$SESSION_SYNC_SCRIPT" record "$SESSION" "$BRANCH" "$WORKTREE" "$MODEL" 2>/dev/null || true
  fi
}

if [ ! -d "$MONOREPO" ]; then
  echo "Error: monorepo dir not found at '$MONOREPO'"
  exit 1
fi

# Reattach if session already exists
if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "Session '$SESSION' already exists, reattaching..."
  sync_session_state
  exec tmux attach-session -t "$SESSION"
fi

ensure_monorepo_deps "$WORKTREE"

# Create session with first pane: agent
tmux new-session -d -s "$SESSION" -c "$WORKTREE" -n "dev"
propagate_cmux_env "$SESSION"
sync_session_state

# Tag sessions inactive in the OneDrive manifest as soon as they close
# (reconcile on the next dev invocation catches anything this hook misses,
# e.g. a crashed tmux server).
if [ -x "$SESSION_SYNC_SCRIPT" ]; then
  tmux set-hook -g session-closed "run-shell '$SESSION_SYNC_SCRIPT reconcile'"
fi

# Enable pane titles in status bar (must be after session exists)
tmux set-option -g pane-border-status top
tmux set-option -g pane-border-format "  #{pane_title}  "
tmux set-option -g pane-border-lines heavy
tmux set-option -g pane-border-style "fg=#444444"
tmux set-option -g pane-active-border-style "fg=green"
AGENT_LAUNCH_SCRIPT="$SCRIPT_DIR/dev-tmux-agent-launch.sh"
WAIT_PNPM_SCRIPT="$SCRIPT_DIR/dev-wait-pnpm.sh"

# Build agent launch command based on model
case "$MODEL" in
  claude)
    AGENT_ICON="✳︎"
    AGENT_LABEL="claude"
    ;;
  codex)
    AGENT_ICON="⚡"
    AGENT_LABEL="codex"
    ;;
  *)
    echo "Unknown model: $MODEL (supported: claude, codex)"
    exit 1
    ;;
esac

AGENT_CMD="$AGENT_LAUNCH_SCRIPT $MODEL"

tmux select-pane -t "$SESSION:.0" -T "$AGENT_ICON $AGENT_LABEL"
send_keys_when_ready "$SESSION:.0" "$AGENT_CMD"

# Split right (33% = 4/12 columns): build pane
tmux split-window -h -p 33 -t "$SESSION" -c "$WORKTREE"
tmux select-pane -T "📦 build"
if [ "$USE_DOCKER" = true ]; then
  BUILD_CMD="./docker/docker-start.sh $WORKSPACE_NAME"
  # If a background pnpm install is in flight, wait for it to finish before the
  # dev server starts — otherwise nx/vite races node_modules and dies with
  # "Could not find Nx modules".
  if [ -n "$PNPM_INSTALL_DONE_FILE" ]; then
    BUILD_CMD="\"$WAIT_PNPM_SCRIPT\" \"$PNPM_INSTALL_DONE_FILE\" \"$PNPM_INSTALL_LOG_FILE\" && $BUILD_CMD"
  fi
  send_keys_when_ready "$SESSION:.1" "$BUILD_CMD"
fi

# Split the right pane vertically: naked terminal
tmux split-window -v -t "$SESSION" -c "$WORKTREE"
tmux select-pane -T "⬛ shell"

# No select-layout needed — explicit split percentages handle the 8/4 ratio

# Enable mouse support (click to switch panes, resize by dragging)
tmux set-option -t "$SESSION" mouse on

# Change prefix to Ctrl-a (Ctrl-b is captured by Claude Code)
tmux set-option -t "$SESSION" prefix C-a
tmux bind-key -T prefix C-a send-prefix

# Toggle mouse mode with Ctrl-a m (for Cmd+click links)
tmux bind-key m set-option mouse \; display-message "mouse #{?mouse,on,off}"

# Command centre popup with Ctrl-a W
tmux bind-key W display-popup -E -w 85% -h 75% "$SCRIPT_DIR/dev-ctl.sh"

# Allow escape sequence passthrough to Ghostty
tmux set-option -g allow-passthrough on

# Dynamic Ghostty tab title: agent + workspace + collector state
TITLE_SCRIPT="$SCRIPT_DIR/dev-tmux-title.sh"
tmux set-option -t "$SESSION" set-titles on
tmux set-option -t "$SESSION" set-titles-string "$AGENT_ICON $WORKSPACE_NAME"

# Poll every 5 seconds to update title based on running processes and collector output
tmux set-option -t "$SESSION" status-interval 5
tmux set-option -t "$SESSION" status-right "#(${TITLE_SCRIPT} \"$SESSION\" \"$WORKSPACE_NAME\" \"$WORKTREE\" \"$MODEL\" \"$AGENT_ICON\" \"$AGENT_LABEL\")  %H:%M"

# Focus the agent pane
tmux select-pane -t "$SESSION:.0"

# Attach (skip if DEV_TMUX_NO_ATTACH is set — used by dev-ctl.sh)
if [ "${DEV_TMUX_NO_ATTACH:-}" = "1" ]; then
  echo "Session '$SESSION' created (no-attach mode)"
else
  tmux attach-session -t "$SESSION"
fi
