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

# --- Update agent pane title with context percentage ---
AGENT_PANE_TITLE="${AGENT_ICON} ${AGENT_LABEL:-agent}"
if [ -n "$TOKEN_INFO" ]; then
  AGENT_PANE_TITLE="${AGENT_PANE_TITLE} ·${TOKEN_INFO}"
fi

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

# --- Push state to the terminal titles and cmux, change-detected + rate-limited ---
# Updating the window title (set-titles-string) every poll is the single biggest cost here:
# each OSC title escape makes the host terminal - cmux especially - do heavy work, so one
# session per worktree refreshing every cycle pegged the cmux daemon. The cmux_run pushes
# spawn a CLI process each and spike the daemon too. Both sinks share the same volatile
# inputs, so gate them together:
#   1. Skip entirely when nothing changed since the last push (idle sessions go quiet).
#   2. Rate-limit: even when state changes, push at most once per STATE_MIN_INTERVAL. An
#      active agent's captured status line ("Thinking", ticking tokens) changes every poll,
#      so without this the signature differs every cycle and guard 1 never fires.
# Unchanged state re-pushes after STATE_TTL so titles/cmux self-heal after a terminal restart.
# Spread each workspace's push window (30-44s) so the ~dozen sessions don't all push on the
# same wall-clock tick, which otherwise produced a synchronized cmux spike. The offset is
# derived from the workspace name, so it's stable across polls but differs per workspace.
STATE_JITTER=$(( $(printf '%s' "$WORKSPACE_NAME" | cksum | cut -d' ' -f1) % 15 ))
STATE_MIN_INTERVAL=$(( 30 + STATE_JITTER ))
STATE_TTL=60
# IMPORTANT = structural state that should reflect immediately (docker/server/build icon,
# build status, agent pane title). Full sig adds the noisy bits (token %, claude status)
# that we rate-limit to avoid flooding cmux.
IMPORTANT_SIG="${SERVER_ICON}|${BUILD_STATUS_VALUE}|${BUILD_PANE_TITLE}|${AGENT_PANE_TITLE}"
STATE_SIG="${WORKSPACE_TITLE}|${AGENT_PANE_TITLE}|${BUILD_PANE_TITLE}|${BUILD_STATUS_VALUE}|${CONTEXT_STATUS_VALUE}|${PERCENT}"
SIG_FILE="/tmp/dev-tmux-title/${WORKSPACE_NAME}-state-sig"
mkdir -p /tmp/dev-tmux-title 2>/dev/null

STATE_CACHED_IMP=""; STATE_CACHED_FULL=""
if [ -f "$SIG_FILE" ]; then
  STATE_CACHED_IMP="$(sed -n '1p' "$SIG_FILE" 2>/dev/null)"
  STATE_CACHED_FULL="$(sed -n '2p' "$SIG_FILE" 2>/dev/null)"
fi
STATE_MTIME="$(stat -f %m "$SIG_FILE" 2>/dev/null || echo 0)"
STATE_ELAPSED=$(( $(date +%s) - STATE_MTIME ))

STATE_PUSH=false
if [ "$STATE_CACHED_IMP" != "$IMPORTANT_SIG" ]; then
  # Structural change (e.g. docker started/stopped) -> reflect immediately, no rate-limit.
  STATE_PUSH=true
elif [ "$STATE_CACHED_FULL" != "$STATE_SIG" ]; then
  # Only the noisy bits changed (token %, status) -> rate-limit.
  [ "$STATE_ELAPSED" -ge "$STATE_MIN_INTERVAL" ] && STATE_PUSH=true
else
  # Nothing changed -> re-push after the TTL so cmux self-heals after a restart.
  [ "$STATE_ELAPSED" -ge "$STATE_TTL" ] && STATE_PUSH=true
fi

if [ "$STATE_PUSH" = true ]; then
  # Pane + window titles (the window title also drives the Ghostty tab title off cmux).
  tmux select-pane -t "$SESSION:.1" -T "$BUILD_PANE_TITLE" 2>/dev/null
  tmux select-pane -t "$SESSION:.0" -T "$AGENT_PANE_TITLE" 2>/dev/null
  tmux set-option -t "$SESSION" -q set-titles-string "$WORKSPACE_TITLE" 2>/dev/null

  # Mirror the same state into cmux when available.
  if cmux_available; then
    # NOTE: we intentionally do NOT rename the workspace. cmux owns the name (its ticket
    # title + live agent status); our rename fought cmux's and the docker glyph flickered.
    # Server/docker state is shown via the build status pill below, which cmux never overwrites.
    # No "agent" pill: the model is ~always claude and its % duplicated the progress bar.
    # The agent's live activity goes in the context pill (below), the % in the progress bar.
    cmux_run clear-status agent || true
    # Emoji in the label already conveys the kind, so no --icon (avoids a redundant glyph).
    case "$BUILD_STATUS_VALUE" in
      docker)    cmux_run set-status build "🐳 docker" --color "#0a84ff" || true ;;
      server)    cmux_run set-status build "🏃 server" --color "#0a84ff" || true ;;
      storybook) cmux_run set-status build "📖 storybook" --color "#0a84ff" || true ;;
      *)         cmux_run clear-status build || true ;;
    esac

    # Keep the sidebar quiet: context usage is just the progress-bar gauge normally. Only when
    # usage is high (>= DEV_BOARD_CONTEXT_WARN) do we add a textual warning pill, so a session
    # only "speaks up" when it actually needs attention.
    CONTEXT_WARN="${DEV_BOARD_CONTEXT_WARN:-70}"
    if [ -n "$PERCENT" ] && [[ "$PERCENT" =~ ^[0-9]+$ ]] && [ "$PERCENT" -ge "$CONTEXT_WARN" ]; then
      cmux_run set-status context "⚠ ${PERCENT}% context" --icon gauge --color "#ff9f0a" || true
    else
      cmux_run clear-status context || true
    fi

    # The gauge itself carries the level; no label, so it reads as a clean bar until it's high.
    if [ -n "$PERCENT" ] && [[ "$PERCENT" =~ ^[0-9]+$ ]]; then
      cmux_run set-progress "$(awk "BEGIN { printf \"%.2f\", $PERCENT / 100 }")" || true
    else
      cmux_run clear-progress || true
    fi
  fi

  printf '%s\n%s' "$IMPORTANT_SIG" "$STATE_SIG" > "$SIG_FILE" 2>/dev/null || true
fi

# --- Periodic data refresh + sidebar re-sort ---
# Any focused session triggers it; an atomic mkdir lock + a timestamp keep it to once per
# DEV_BOARD_REFLECT_INTERVAL across all sessions, in the background so it never delays the
# status line. This only fires while a session is focused (you're present), so it's safe to
# refresh the PR/Linear cache here too (TTL-gated inside the collector) — otherwise the board
# only reflected local agent-state and went stale on PR/review movement until the next manual
# `dev board`/attach. Only matters under cmux.
__CMUX_BIN="$(command -v cmux 2>/dev/null || echo /Applications/cmux.app/Contents/Resources/bin/cmux)"
if [ -x "$__CMUX_BIN" ]; then
  BOARD_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  REFLECT_INTERVAL="${DEV_BOARD_REFLECT_INTERVAL:-300}"
  REFLECT_STAMP="/tmp/dev-board/last-reflect"
  REFLECT_LOCK="/tmp/dev-board/reflect.lock"
  mkdir -p /tmp/dev-board 2>/dev/null || true
  # Drop a stale lock left by a refresh that died before releasing it. Match the sweep's 2-min
  # threshold (was 5): a leaked lock freezes the reorder until it's cleared, so heal it sooner.
  [ -n "$(find "$REFLECT_LOCK" -mmin +2 2>/dev/null)" ] && rmdir "$REFLECT_LOCK" 2>/dev/null
  REFLECT_NOW="$(date +%s)"
  REFLECT_M="$(stat -f %m "$REFLECT_STAMP" 2>/dev/null || echo 0)"
  if [ "$(( REFLECT_NOW - REFLECT_M ))" -ge "$REFLECT_INTERVAL" ]; then
    if mkdir "$REFLECT_LOCK" 2>/dev/null; then
      touch "$REFLECT_STAMP" 2>/dev/null || true
      # Refresh PR/Linear data (TTL-gated, network) THEN re-rank + reorder cmux. An EXIT trap
      # releases the lock even if this backgrounded subshell is killed (e.g. the focused pane
      # closes mid-run, SIGHUP) — otherwise a leak would block reorders until the stale sweep.
      ( trap 'rmdir "$REFLECT_LOCK" 2>/dev/null' EXIT
        "$BOARD_DIR/dev-board-collect.sh" >/dev/null 2>&1
        "$BOARD_DIR/dev-board.sh" --reflect >/dev/null 2>&1 ) &
    fi
  fi
fi

# --- Refresh titles for backgrounded (0-client) workspaces ---
# cmux only attaches a tmux client to a workspace it has opened, so never-opened/backgrounded
# sessions never run their own status-right and their sidebar titles freeze. Any polling
# session sweeps them, throttled to once per DEV_TITLE_SWEEP_INTERVAL across all sessions
# (atomic mkdir lock + timestamp). Only relevant under cmux (many backgrounded surfaces).
if [ -x "$__CMUX_BIN" ]; then
  SWEEP_INTERVAL="${DEV_TITLE_SWEEP_INTERVAL:-30}"
  SWEEP_STAMP="/tmp/dev-tmux-title/.title-sweep"
  SWEEP_LOCK="/tmp/dev-tmux-title/.title-sweep.lock"
  mkdir -p /tmp/dev-tmux-title 2>/dev/null || true
  # Drop a stale lock left by a sweep that died before releasing it.
  [ -n "$(find "$SWEEP_LOCK" -mmin +2 2>/dev/null)" ] && rmdir "$SWEEP_LOCK" 2>/dev/null
  SWEEP_NOW="$(date +%s)"
  SWEEP_M="$(stat -f %m "$SWEEP_STAMP" 2>/dev/null || echo 0)"
  if [ "$(( SWEEP_NOW - SWEEP_M ))" -ge "$SWEEP_INTERVAL" ] && mkdir "$SWEEP_LOCK" 2>/dev/null; then
    touch "$SWEEP_STAMP" 2>/dev/null || true
    (
      for __s in $(tmux list-sessions -F '#{session_name}' 2>/dev/null); do
        # Skip sessions that poll themselves (they have an attached tmux client).
        [ "$(tmux list-clients -t "$__s" 2>/dev/null | wc -l | tr -d ' ')" -eq 0 ] || continue
        __sr="$(tmux show-options -t "$__s" -v status-right 2>/dev/null)"
        case "$__sr" in *dev-tmux-title.sh*) ;; *) continue ;; esac
        # Recover the title invocation from "#(<cmd>)  %H:%M" and re-run it.
        __cmd="${__sr#*#(}"; __cmd="${__cmd%")  %H:%M"}"
        [ -n "$__cmd" ] && eval "$__cmd" >/dev/null 2>&1
      done
      rmdir "$SWEEP_LOCK" 2>/dev/null || true
    ) &
  fi
fi
