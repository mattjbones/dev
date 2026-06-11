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
#   ./dev-session-sync.sh record <session> <branch> <worktree> <model>
#       Upsert <session> as active in this host's manifest. Called by dev.sh
#       on every invocation. Branch may be "" (main lupa checkout).
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
#       session; otherwise pass session names.
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
  ensure_base || return 0
  update_manifest \
    --arg s "$session" --arg b "$branch" --arg w "$worktree" \
    --arg m "$model" --arg h "$HOST" --arg t "$(now_utc)" \
    '[.[] | select(.session != $s)]
     + [{session: $s, branch: $b, worktree: $w, model: $m,
         status: "active", host: $h, updatedAt: $t}]'
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
}

cmd_list() {
  ensure_base || return 0
  {
    echo "SESSION|HOST|STATUS|MODEL|UPDATED|BRANCH"
    cat "$ONEDRIVE_BASE"/*.json 2>/dev/null | jq -r -s \
      'add // [] | sort_by(.status, .session) | .[]
       | [.session, .host, .status, .model, .updatedAt, (.branch // "")] | join("|")'
  } | column -t -s '|'
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
     | sort_by(.session) | .[] | [.session, (.branch // ""), .model] | @tsv')"

  if [ -z "$candidates" ]; then
    echo "No sessions active on other hosts."
    return 0
  fi

  local restored=0
  while IFS=$'\t' read -r session branch model; do
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
    if [ -n "$branch" ]; then
      DEV_TMUX_NO_ATTACH=1 "$DEV_TMUX" --model "$model" "$branch"
    else
      DEV_TMUX_NO_ATTACH=1 "$DEV_TMUX" --model "$model"
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
  list)      shift; cmd_list ;;
  restore)   shift; cmd_restore "$@" ;;
  *)
    sed -n '/^# ====/,/^# ====/p' "$0" | sed 's/^# \{0,1\}//' | sed -n '3,40p'
    exit 1
    ;;
esac
