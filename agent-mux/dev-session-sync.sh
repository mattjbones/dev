#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# dev-session-sync.sh — Sync dev-tmux workspace state to OneDrive
# =============================================================================
#
# Keeps a per-machine manifest of dev workspaces in OneDrive so another
# machine can see what was active and recreate it with dev.sh. The tmux
# layout itself is never synced — `dev <branch>` rebuilds it deterministically,
# so the manifest only needs (session, branch, model, status).
#
# Each host writes ONLY its own manifest file (<hostname>.json), so OneDrive
# never sees concurrent writers and can't produce sync conflicts.
#
# Usage:
#   ./dev-session-sync.sh record <session> <branch> <worktree> <model> [agent-session-id]
#       Upsert <session> as active in this host's manifest. Called by dev.sh
#       on every invocation. Branch may be "" (main lupa checkout).
#       agent-session-id is the Claude Code session uuid for the agent pane;
#       when omitted (reattach) any previously recorded id is preserved.
#
#   ./dev-session-sync.sh reconcile
#       Mark this host's manifest entries inactive when their tmux session no
#       longer exists. Called by dev.sh on startup and by the tmux
#       session-closed hook.
#
#   ./dev-session-sync.sh list
#       Merged view of all hosts' manifests.
#
#   ./dev-session-sync.sh restore [--all | <session>...]
#       Recreate sessions recorded as active on ANOTHER host (and not already
#       running here) via dev.sh in no-attach mode. --all restores every such
#       session; otherwise pass session names. Pulls the recorded Claude chat
#       transcript from OneDrive first so the agent pane resumes the chat.
#
#   ./dev-session-sync.sh push
#       Copy local Claude transcripts for recorded sessions to OneDrive
#       (newest-wins). Also runs automatically on record/reconcile, so an
#       ongoing chat syncs whenever dev.sh runs or a session closes; run
#       manually to snapshot mid-chat.
#
#   ./dev-session-sync.sh sync          (also: dev sync)
#       Interactive fzf picker over sessions active on other hosts:
#       TAB to select some, ctrl-a for all, enter to restore the selection
#       (worktree + tmux layout + resumed Claude chat). Pushes/reconciles
#       this host's state first.
#
# All subcommands are no-ops (exit 0, message on stderr) when the OneDrive
# folder isn't present, so dev.sh never breaks on a machine without OneDrive.
# =============================================================================

_dss_source="${BASH_SOURCE[0]:-$0}"
while [ -h "$_dss_source" ]; do
  _dss_dir="$(cd -P "$(dirname "$_dss_source")" && pwd)"
  _dss_link="$(readlink "$_dss_source")"
  [[ "$_dss_link" == /* ]] && _dss_source="$_dss_link" || _dss_source="$_dss_dir/$_dss_link"
done
SCRIPT_DIR="$(cd -P "$(dirname "$_dss_source")" && pwd)"
unset _dss_source _dss_dir _dss_link

ONEDRIVE_BASE="${DEV_SESSION_SYNC_DIR:-$HOME/Library/CloudStorage/OneDrive-LupaPetsLtd/docs/scripts/dev-sessions}"
HOST="$(hostname -s)"
MANIFEST="$ONEDRIVE_BASE/$HOST.json"
TRANSCRIPTS_DIR="$ONEDRIVE_BASE/transcripts"
DEV_TMUX="$SCRIPT_DIR/dev.sh"

now_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

ensure_base() {
  # Only require the OneDrive root to exist; create our subfolder ourselves.
  local od_root
  od_root="$(dirname "$(dirname "$(dirname "$ONEDRIVE_BASE")")")"
  if [ ! -d "$od_root" ] && [ -z "${DEV_SESSION_SYNC_DIR:-}" ]; then
    echo "dev-session-sync: OneDrive not found at $od_root; skipping" >&2
    return 1
  fi
  mkdir -p "$ONEDRIVE_BASE"
  [ -f "$MANIFEST" ] || echo '[]' > "$MANIFEST"
}

# Claude Code names its per-project transcript dir by replacing every
# non-alphanumeric char of the cwd with '-'.
munge_path() {
  printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'
}

# Copy local Claude transcripts for this host's recorded sessions to OneDrive
# (newest-wins by mtime; cp -p preserves mtimes so the comparison holds across
# machines). Best-effort: a failed copy never breaks the caller.
push_transcripts() {
  [ -f "$MANIFEST" ] || return 0
  local ids id local_file od_file
  ids="$(jq -r '.[] | select((.agentSessionId // "") != "") | .agentSessionId' "$MANIFEST" 2>/dev/null || true)"
  [ -n "$ids" ] || return 0
  mkdir -p "$TRANSCRIPTS_DIR"
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    local_file="$(ls "$HOME/.claude/projects"/*/"$id.jsonl" 2>/dev/null | head -1 || true)"
    [ -n "$local_file" ] || continue
    od_file="$TRANSCRIPTS_DIR/$id.jsonl"
    if [ ! -f "$od_file" ] || [ "$local_file" -nt "$od_file" ]; then
      cp -p "$local_file" "$od_file" 2>/dev/null || true
    fi
  done <<< "$ids"
}

# Pull one transcript from OneDrive into the local Claude projects dir for
# <worktree>, but only if the OneDrive copy is newer than any local one
# (never clobbers a chat that progressed further on this machine).
pull_transcript() {
  local id="$1" worktree="$2"
  [ -n "$id" ] && [ -n "$worktree" ] || return 0
  local od_file="$TRANSCRIPTS_DIR/$id.jsonl"
  [ -f "$od_file" ] || return 0
  local existing dest
  existing="$(ls "$HOME/.claude/projects"/*/"$id.jsonl" 2>/dev/null | head -1 || true)"
  if [ -n "$existing" ]; then
    if [ "$od_file" -nt "$existing" ]; then
      cp -p "$od_file" "$existing" 2>/dev/null || true
    fi
    return 0
  fi
  dest="$HOME/.claude/projects/$(munge_path "$worktree")"
  mkdir -p "$dest"
  cp -p "$od_file" "$dest/$id.jsonl" 2>/dev/null || true
}

# Atomic in-place jq edit of this host's manifest.
update_manifest() {
  local tmp
  tmp="$(mktemp)"
  if jq "$@" "$MANIFEST" > "$tmp"; then
    mv "$tmp" "$MANIFEST"
  else
    rm -f "$tmp"
    echo "dev-session-sync: jq update failed; manifest left unchanged" >&2
    return 1
  fi
}

cmd_record() {
  local session="${1:?session required}"
  local branch="${2:-}"
  local worktree="${3:-}"
  local model="${4:-claude}"
  local agent_session="${5:-}"
  ensure_base || return 0
  # agentSessionId: keep the previously recorded id when none is passed
  # (reattach upserts don't know it) so a resumable chat id is never lost.
  update_manifest \
    --arg s "$session" --arg b "$branch" --arg w "$worktree" \
    --arg m "$model" --arg h "$HOST" --arg t "$(now_utc)" \
    --arg a "$agent_session" \
    '(map(select(.session == $s)) | (.[0].agentSessionId // "")) as $prev
     | [.[] | select(.session != $s)]
     + [{session: $s, branch: $b, worktree: $w, model: $m,
         agentSessionId: (if $a != "" then $a else $prev end),
         status: "active", host: $h, updatedAt: $t}]'
  push_transcripts
}

cmd_reconcile() {
  ensure_base || return 0
  local live
  live="$(tmux ls -F '#{session_name}' 2>/dev/null || true)"
  update_manifest --arg live "$live" --arg t "$(now_utc)" \
    '($live | split("\n") | map(select(. != ""))) as $l
     | map(if .status == "active" and ((.session as $s | $l | index($s)) == null)
           then . + {status: "inactive", updatedAt: $t}
           elif .status == "inactive" and ((.session as $s | $l | index($s)) != null)
           then . + {status: "active", updatedAt: $t}
           else . end)'
  push_transcripts
}

cmd_list() {
  ensure_base || return 0
  if [ "${1:-}" = "--json" ]; then
    # Machine-readable merged view (all hosts). Consumers filter as needed.
    cat "$ONEDRIVE_BASE"/*.json 2>/dev/null | jq -s 'add // [] | sort_by(.status, .session)'
    return
  fi
  {
    echo "SESSION|HOST|STATUS|MODEL|UPDATED|BRANCH"
    cat "$ONEDRIVE_BASE"/*.json 2>/dev/null | jq -r -s \
      'add // [] | sort_by(.status, .session) | .[]
       | [.session, .host, .status, .model, .updatedAt, (.branch // "")] | join("|")'
  } | column -t -s '|'
}

cmd_push() {
  ensure_base || return 0
  push_transcripts
}

# Merged manifest entry for one session (fzf preview helper).
cmd_entry() {
  local session="${1:?session required}"
  cat "$ONEDRIVE_BASE"/*.json 2>/dev/null | jq -r -s --arg s "$session" \
    'add // [] | map(select(.session == $s)) | .[0] // "not found"'
}

cmd_sync() {
  ensure_base || return 0
  # Freshen both directions first: push this host's transcripts/state and
  # mark dead local sessions inactive, so the candidate list is accurate.
  cmd_reconcile

  # Sessions active on another host and not already running here.
  local avail=""
  local session host branch model updated
  while IFS=$'\t' read -r session host branch model updated; do
    [ -z "$session" ] && continue
    tmux has-session -t "$session" 2>/dev/null && continue
    avail+="$session"$'\t'"$host"$'\t'"${branch:-<main lupa>}"$'\t'"$model"$'\t'"$updated"$'\n'
  done < <(cat "$ONEDRIVE_BASE"/*.json 2>/dev/null | jq -r -s --arg h "$HOST" \
    'add // [] | map(select(.status == "active" and .host != $h))
     | sort_by(.session) | .[]
     | [.session, .host, (.branch // ""), .model, .updatedAt] | @tsv')

  if [ -z "$avail" ]; then
    echo "Nothing to sync — no sessions active on other hosts."
    return 0
  fi

  local selected=""
  if command -v fzf >/dev/null 2>&1; then
    selected="$(printf '%s' "$avail" \
      | column -t -s $'\t' \
      | fzf --multi --reverse --height=60% \
            --prompt="Restore sessions > " \
            --header="TAB: select  •  ctrl-a: select all  •  enter: restore  (SESSION HOST BRANCH MODEL UPDATED)" \
            --bind 'ctrl-a:select-all' \
            --preview "\"$SCRIPT_DIR/dev-session-sync.sh\" __entry {1}" --preview-window=right,40% \
      | awk '{print $1}' || true)"
  else
    echo "fzf not found; sessions active elsewhere:"
    printf '%s' "$avail" | column -t -s $'\t' | sed 's/^/  /'
    printf 'Restore ALL of the above? [y/N] '
    local reply
    read -r reply
    case "$reply" in
      y|Y) cmd_restore --all; return $? ;;
      *)   echo "Aborted. Run: dev-session-sync.sh restore <session>..."; return 0 ;;
    esac
  fi

  if [ -z "$selected" ]; then
    echo "Nothing selected."
    return 0
  fi

  # shellcheck disable=SC2086
  cmd_restore $selected
}

cmd_restore() {
  ensure_base || return 0
  if [ ! -x "$DEV_TMUX" ]; then
    echo "dev-session-sync: dev.sh not found at $DEV_TMUX" >&2
    return 1
  fi

  local all=false
  if [ "${1:-}" = "--all" ]; then
    all=true
    shift
  fi

  # Candidates: active on another host, not currently running on this one.
  local candidates
  candidates="$(cat "$ONEDRIVE_BASE"/*.json 2>/dev/null | jq -r -s --arg h "$HOST" \
    'add // [] | map(select(.status == "active" and .host != $h))
     | sort_by(.session) | .[]
     | [.session, (.branch // ""), .model, (.agentSessionId // ""), (.worktree // "")] | @tsv')"

  if [ -z "$candidates" ]; then
    echo "No sessions active on other hosts."
    return 0
  fi

  local restored=0
  while IFS=$'\t' read -r session branch model agent_session worktree; do
    [ -z "$session" ] && continue
    if ! $all; then
      case " $* " in
        *" $session "*) ;;
        *) continue ;;
      esac
    fi
    if tmux has-session -t "$session" 2>/dev/null; then
      echo "Skipping '$session' (already running here)"
      continue
    fi
    echo "Restoring '$session' (branch: ${branch:-<main lupa>}, model: $model)..."
    # Drop the other host's transcript into the local Claude projects dir so
    # the agent pane resumes the chat rather than starting fresh. Assumes the
    # worktree path is the same on both machines (it is: ~/workspace/<branch>).
    pull_transcript "$agent_session" "$worktree"
    # Reuse the recorded Claude session id: resumes the chat if its transcript
    # exists on this machine, otherwise starts fresh under the same id.
    if [ -n "$branch" ]; then
      DEV_TMUX_NO_ATTACH=1 DEV_CLAUDE_SESSION_ID="$agent_session" \
        "$DEV_TMUX" --model "$model" "$branch"
    else
      DEV_TMUX_NO_ATTACH=1 DEV_CLAUDE_SESSION_ID="$agent_session" \
        "$DEV_TMUX" --model "$model"
    fi
    restored=$((restored + 1))
  done <<< "$candidates"

  if [ "$restored" -eq 0 ] && ! $all; then
    echo "Nothing restored. Candidates active elsewhere:"
    echo "$candidates" | cut -f1 | sed 's/^/  /'
    echo "Run with --all or pass session names."
  else
    echo "Restored $restored session(s). Attach with: dev <branch>  or  dev ctl"
  fi
}

case "${1:-}" in
  record)    shift; cmd_record "$@" ;;
  reconcile) shift; cmd_reconcile ;;
  list)      shift; cmd_list "$@" ;;
  restore)   shift; cmd_restore "$@" ;;
  push)      shift; cmd_push ;;
  sync)      shift; cmd_sync ;;
  __entry)   shift; cmd_entry "$@" ;;
  *)
    sed -n '/^# ====/,/^# ====/p' "$0" | sed 's/^# \{0,1\}//' | sed -n '3,40p'
    exit 1
    ;;
esac
