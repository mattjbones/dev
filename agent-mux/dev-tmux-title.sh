#!/usr/bin/env bash
# Called by tmux periodically to update the Ghostty tab title.
# Checks server status and normalized agent context usage.

SESSION="${1:-}"
WORKSPACE_NAME="${2:-}"
WORKTREE="${3:-}"
MODEL="${4:-claude}"
AGENT_ICON="${5:-✳︎}"
AGENT_LABEL="${6:-claude}"
CMUX_WORKSPACE_ID="${CMUX_WORKSPACE_ID:-}"

if [ -z "$SESSION" ] || [ -z "$WORKSPACE_NAME" ] || [ -z "$WORKTREE" ]; then
  exit 0
fi

# Resolve the cmux CLI - the tmux server's PATH usually lacks the app's bin dir,
# so a bare `command -v cmux` fails when invoked from status-right.
CMUX_BIN="$(command -v cmux 2>/dev/null || true)"
if [ -z "$CMUX_BIN" ] && [ -x "/Applications/cmux.app/Contents/Resources/bin/cmux" ]; then
  CMUX_BIN="/Applications/cmux.app/Contents/Resources/bin/cmux"
fi

# Prefer the session's own workspace id - the server-global env var is a stale
# value leaked from whichever shell started the tmux server.
SESSION_CMUX_ID="$(tmux show-environment -t "$SESSION" CMUX_WORKSPACE_ID 2>/dev/null | sed -n 's/^CMUX_WORKSPACE_ID=//p')"
if [ -n "$SESSION_CMUX_ID" ]; then
  CMUX_WORKSPACE_ID="$SESSION_CMUX_ID"
fi

cmux_available() {
  [ -n "$CMUX_WORKSPACE_ID" ] && [ -n "$CMUX_BIN" ]
}

cmux_run() {
  if ! cmux_available; then
    return 1
  fi

  "$CMUX_BIN" "$@" --workspace "$CMUX_WORKSPACE_ID" >/dev/null 2>&1
}

# --- Server check: docker containers by project name or working_dir, then bun/node ---
SERVER_ICON=""
# Mirror docker-start.sh's compose project normalisation: lowercase, then any char
# outside [a-z0-9_-] becomes '-' (collapse runs so multibyte chars like the unicode
# hyphen in Linear-named worktrees normalise to a single '-').
COMPOSE_PROJECT="$(printf '%s' "$WORKSPACE_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g; s/--*/-/g')"
if docker ps --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" --filter "status=running" -q 2>/dev/null | grep -q .; then
  SERVER_ICON=" 🐳"
# Compose files moved into docker/ (#11882), so the working_dir label is <worktree>/docker
elif docker ps --filter "label=com.docker.compose.project.working_dir=$WORKTREE/docker" --filter "status=running" -q 2>/dev/null | grep -q .; then
  SERVER_ICON=" 🐳"
elif docker ps --filter "label=com.docker.compose.project.working_dir=$WORKTREE" --filter "status=running" -q 2>/dev/null | grep -q .; then
  SERVER_ICON=" 🐳"
fi
# Fallback: check for bun/node processes in session panes
if [ -z "$SERVER_ICON" ]; then
  for pane_pid in $(tmux list-panes -t "$SESSION" -F '#{pane_pid}' 2>/dev/null); do
    if pgrep -P "$pane_pid" -f 'bun|node' &>/dev/null; then
      SERVER_ICON=" 🏃"
      break
    fi
  done
fi

# --- Normalized agent context info ---
COLLECTOR="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/dev-tmux-collect.sh"
TOKEN_INFO=""
AGENT_DETAIL=""
if [ -x "$COLLECTOR" ]; then
  COLLECTED="$("$COLLECTOR" "$MODEL" "$WORKSPACE_NAME" "$WORKTREE" 2>/dev/null || true)"
  if [ -n "$COLLECTED" ]; then
    PERCENT="$(printf '%s' "$COLLECTED" | jq -r '.percent // empty' 2>/dev/null || true)"
    LABEL="$(printf '%s' "$COLLECTED" | jq -r '.label // empty' 2>/dev/null || true)"
    DETAIL="$(printf '%s' "$COLLECTED" | jq -r '.detail // empty' 2>/dev/null || true)"
    if [ -n "$LABEL" ]; then
      TOKEN_INFO=" ${LABEL}"
    fi
    if [ -n "$DETAIL" ] && [ "$DETAIL" != "null" ]; then
      AGENT_DETAIL=" · ${DETAIL}"
    elif [ -n "$PERCENT" ]; then
      AGENT_DETAIL=" · ${PERCENT}%"
    fi
  fi
fi

# --- Check for Storybook process ---
STORYBOOK_RUNNING=false
for pane_pid in $(tmux list-panes -t "$SESSION" -F '#{pane_pid}' 2>/dev/null); do
  if pgrep -P "$pane_pid" -f 'storybook' &>/dev/null; then
    STORYBOOK_RUNNING=true
    break
  fi
done

# --- Update build pane title based on server/storybook status ---
BUILD_PANE_TITLE="📦 build"
BUILD_STATUS_VALUE="idle"
if [ "$STORYBOOK_RUNNING" = true ]; then
  BUILD_PANE_TITLE="📖 storybook"
  BUILD_STATUS_VALUE="storybook"
elif [ -n "$SERVER_ICON" ]; then
  BUILD_PANE_TITLE="${SERVER_ICON} build"
  if [ "$SERVER_ICON" = " 🐳" ]; then
    BUILD_STATUS_VALUE="docker"
  else
    BUILD_STATUS_VALUE="server"
  fi
fi
tmux select-pane -t "$SESSION:.1" -T "$BUILD_PANE_TITLE" 2>/dev/null

# --- Update agent pane title with context percentage ---
AGENT_PANE_TITLE="${AGENT_ICON} ${AGENT_LABEL:-agent}"
if [ -n "$TOKEN_INFO" ]; then
  AGENT_PANE_TITLE="${AGENT_PANE_TITLE} ·${TOKEN_INFO}"
fi
tmux select-pane -t "$SESSION:.0" -T "$AGENT_PANE_TITLE" 2>/dev/null

# --- Claude activity status from pane capture ---
CLAUDE_STATUS=""
PANE_CONTENT="$(tmux capture-pane -t "$SESSION:.0" -p 2>/dev/null || true)"
STATUS_LINE="$(echo "$PANE_CONTENT" | grep -oE '✳ [^(]+' | tail -1 | sed 's/✳ //;s/[[:space:]]*$//' || true)"
if [ -n "$STATUS_LINE" ]; then
  CLAUDE_STATUS=" · ${STATUS_LINE}"
fi

CONTEXT_STATUS_VALUE=""
if [ -n "$STATUS_LINE" ]; then
  CONTEXT_STATUS_VALUE="$STATUS_LINE"
fi
if [ -n "$DETAIL" ] && [ "$DETAIL" != "null" ]; then
  if [ -n "$CONTEXT_STATUS_VALUE" ]; then
    CONTEXT_STATUS_VALUE="${CONTEXT_STATUS_VALUE} · ${DETAIL}"
  else
    CONTEXT_STATUS_VALUE="$DETAIL"
  fi
elif [ -n "$LABEL" ]; then
  if [ -n "$CONTEXT_STATUS_VALUE" ]; then
    CONTEXT_STATUS_VALUE="${CONTEXT_STATUS_VALUE} · ${LABEL}"
  else
    CONTEXT_STATUS_VALUE="$LABEL"
  fi
fi

# --- Set Ghostty tab title ---
WORKSPACE_TITLE="${SERVER_ICON} ${AGENT_ICON} ${WORKSPACE_NAME}${CLAUDE_STATUS}${TOKEN_INFO}"
WORKSPACE_TITLE="$(printf '%s' "$WORKSPACE_TITLE" | sed 's/^ *//;s/  */ /g')"

tmux set-option -t "$SESSION" -q set-titles-string "$WORKSPACE_TITLE" 2>/dev/null

# --- Mirror the same state into CMUX when available ---
# Each cmux_run spawns a CLI process that connects to the cmux.app socket, and the daemon
# spikes hard per push. With one session per worktree this floods cmux. Two guards:
#   1. Skip entirely when nothing changed since the last push (idle sessions go quiet).
#   2. Rate-limit: even when state changes, push at most once per CMUX_MIN_INTERVAL. An
#      active agent's captured status line ("Thinking", ticking tokens) changes every poll,
#      so without this the signature differs every cycle and guard 1 never fires.
# Unchanged state still re-pushes after CMUX_TTL so cmux self-heals if it restarted.
CMUX_MIN_INTERVAL=30
CMUX_TTL=60
if cmux_available; then
  CMUX_SIG="${WORKSPACE_TITLE}|${AGENT_PANE_TITLE}|${BUILD_STATUS_VALUE}|${CONTEXT_STATUS_VALUE}|${PERCENT}"
  SIG_FILE="/tmp/dev-tmux-title/${WORKSPACE_NAME}-cmux-sig"
  mkdir -p /tmp/dev-tmux-title 2>/dev/null

  CMUX_CACHED=""
  [ -f "$SIG_FILE" ] && CMUX_CACHED="$(cat "$SIG_FILE" 2>/dev/null)"
  CMUX_MTIME="$(stat -f %m "$SIG_FILE" 2>/dev/null || echo 0)"
  CMUX_NOW="$(date +%s)"
  CMUX_ELAPSED=$(( CMUX_NOW - CMUX_MTIME ))

  CMUX_PUSH=false
  if [ "$CMUX_CACHED" != "$CMUX_SIG" ]; then
    # Changed - push, but no more often than once per CMUX_MIN_INTERVAL per workspace.
    [ "$CMUX_ELAPSED" -ge "$CMUX_MIN_INTERVAL" ] && CMUX_PUSH=true
  else
    # Unchanged - re-push only after the TTL so cmux state self-heals after a restart.
    [ "$CMUX_ELAPSED" -ge "$CMUX_TTL" ] && CMUX_PUSH=true
  fi

  if [ "$CMUX_PUSH" = true ]; then
    cmux_run rename-workspace "$WORKSPACE_TITLE" || true

    cmux_run set-status agent "${AGENT_PANE_TITLE#${AGENT_ICON} }" --icon sparkle --color "#34c759" || true
    cmux_run set-status build "$BUILD_STATUS_VALUE" --icon shippingbox --color "#0a84ff" || true

    if [ -n "$CONTEXT_STATUS_VALUE" ]; then
      cmux_run set-status context "$CONTEXT_STATUS_VALUE" --icon gauge --color "#ff9f0a" || true
    else
      cmux_run clear-status context || true
    fi

    if [ -n "$PERCENT" ] && [[ "$PERCENT" =~ ^[0-9]+$ ]]; then
      cmux_run set-progress "$(awk "BEGIN { printf \"%.2f\", $PERCENT / 100 }")" --label "${PERCENT}%" || true
    else
      cmux_run clear-progress || true
    fi

    printf '%s' "$CMUX_SIG" > "$SIG_FILE" 2>/dev/null || true
  fi
fi
