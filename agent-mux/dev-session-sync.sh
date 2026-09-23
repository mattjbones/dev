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
#   ./dev-session-sync.sh record <session> <branch> <worktree> <model> [agent-session-id] [tickets]
#       Upsert <session> as active in this host's manifest. Called by dev.sh
#       on every invocation. Branch may be "" (main lupa checkout).
#       agent-session-id is the Claude Code session uuid for the agent pane;
#       when omitted (reattach) any previously recorded id is preserved.
#       tickets is a comma-separated list of Linear ids (dev --ticket); they
#       are unioned with ids parsed from the session name and branch, and
#       with anything previously recorded, so a ticket is never dropped.
#       Each entry also records transcriptPath: the local Claude chat jsonl
#       for the agent pane (null for non-claude models).
#
#   ./dev-session-sync.sh reconcile
#       Mark this host's manifest entries inactive when their tmux session no
#       longer exists. Called by dev.sh on startup and by the tmux
#       session-closed hook.
#
#   ./dev-session-sync.sh list [--all] [--json] [--md]   (also: dev list)
#       Merged view of all hosts' manifests: session, tickets, chat uuid,
#       branch. Active sessions only unless --all. --json emits every entry
#       (consumers filter). --md writes WORKTREES.md next to the manifests
#       (an Obsidian-readable table, all hosts, all statuses) — manual-only,
#       so the single-writer-per-file rule below is only bent on demand.
#
#   ./dev-session-sync.sh restore [--all | --here | <session>...]
#       Recreate sessions recorded as active (and not already running here) via
#       dev.sh in no-attach mode, resuming each agent's Claude chat.
#         --all   every session active on ANOTHER host (cross-machine restore).
#         --here  every session active on THIS host that isn't running — i.e.
#                 crash recovery after the tmux server dies (the manifest still
#                 marks them active until the next reconcile).
#         <session>...  restore named sessions (defaults to the other-host scope).
#
#   ./dev-session-sync.sh push
#       Copy local Claude transcripts for recorded sessions to OneDrive
#       (newest-wins). Also runs automatically on record/reconcile, so an
#       ongoing chat syncs whenever dev.sh runs or a session closes; run
#       manually to snapshot mid-chat.
#
#   ./dev-session-sync.sh pull <agent-session-id> <local-worktree>
#       Pull one transcript from OneDrive into the Claude project dir for
#       <local-worktree> (this machine's path). Called by dev.sh on restore,
#       once it has resolved the worktree locally — the manifest records the
#       *originating* host's worktree path, which differs across machines when
#       usernames differ, so the destination must be computed from the local
#       worktree, not the recorded one.
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
# Stable per-machine identity. hostname -s flaps with the network, so key on the
# hardware UUID instead; keep a human label for display.
machine_uuid() {
  ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null \
    | awk -F'"' '/IOPlatformUUID/{print $4; exit}'
}
HOST="${DEV_SESSION_SYNC_HOST:-$(machine_uuid)}"; [ -n "$HOST" ] || HOST="$(hostname -s)"
HOST_LABEL="$(scutil --get ComputerName 2>/dev/null || hostname -s)"
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

# parse_linear_id lives in the board lib (side-effect free to source).
# shellcheck source=dev-board-lib.sh
source "$SCRIPT_DIR/dev-board-lib.sh"

# jq: tickets for an entry — recorded .tickets, else parsed from session/branch
# with the same TEAM-NNNN rule as parse_linear_id (rows written by other hosts
# or before the field existed are never reconciled here).
JQ_TIX='def tix: if has("tickets") then .tickets
  else [.session, (.branch // "")] | map(select(. != "")
        | capture("(^|[^A-Za-z0-9-])(?<team>[A-Za-z]{2,7})-(?<num>[0-9]{2,6})")?
        | "\(.team | ascii_upcase)-\(.num)") | unique end;'

# tickets_from <session> <branch> <comma-list> -> comma-joined normalised
# unique Linear ids (ENG-123). Explicit ids go through parse_linear_id too so
# `--ticket eng-123` lands as ENG-123.
tickets_from() {
  local session="$1" branch="$2" explicit="$3" tok t out=""
  for tok in "$session" "$branch" ${explicit//,/ }; do
    [ -n "$tok" ] || continue
    t="$(parse_linear_id "$tok" || true)"
    [ -n "$t" ] && out+="$t,"
  done
  printf '%s' "$out" | tr ',' '\n' | sed '/^$/d' | sort -u | paste -sd, -
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

# Pull one transcript from OneDrive into the Claude project dir for <worktree>
# (this machine's path), but only if the OneDrive copy is newer than the local
# one there (never clobbers a chat that progressed further on this machine).
#
# <worktree> must be the LOCAL path: the project dir is the only place
# `claude --resume` looks when run from that worktree. We deliberately target it
# directly rather than reusing any copy found under another project dir — a
# transcript synced from a host with a different username lives under a
# different ~/workspace path (a different project dir), and refreshing *that*
# would leave the dir for this machine's worktree empty, so --resume fails.
pull_transcript() {
  local id="$1" worktree="$2"
  [ -n "$id" ] && [ -n "$worktree" ] || return 0
  local od_file="$TRANSCRIPTS_DIR/$id.jsonl"
  [ -f "$od_file" ] || return 0
  local dest local_file
  dest="$HOME/.claude/projects/$(munge_path "$worktree")"
  local_file="$dest/$id.jsonl"
  mkdir -p "$dest"
  if [ ! -f "$local_file" ] || [ "$od_file" -nt "$local_file" ]; then
    cp -p "$od_file" "$local_file" 2>/dev/null || true
  fi
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
  local tickets
  tickets="$(tickets_from "$session" "$branch" "${6:-}")"
  ensure_base || return 0
  # agentSessionId: keep the previously recorded id when none is passed
  # (reattach upserts don't know it) so a resumable chat id is never lost.
  # transcriptPath is derived from the *resolved* id inside jq for the same
  # reason. tickets union with whatever was recorded before.
  update_manifest \
    --arg s "$session" --arg b "$branch" --arg w "$worktree" \
    --arg m "$model" --arg h "$HOST" --arg hl "$HOST_LABEL" --arg t "$(now_utc)" \
    --arg a "$agent_session" --arg tk "$tickets" \
    --arg pd "$HOME/.claude/projects/$(munge_path "$worktree")" \
    '(map(select(.session == $s)) | .[0]) as $old
     | (($old.agentSessionId // "") | if $a != "" then $a else . end) as $id
     | ((($old.tickets // []) + ($tk | split(",") | map(select(. != "")))) | unique) as $tix
     | [.[] | select(.session != $s)]
     + [{session: $s, branch: $b, worktree: $w, model: $m,
         agentSessionId: $id,
         transcriptPath: (if $id != "" then $pd + "/" + $id + ".jsonl" else null end),
         tickets: $tix,
         status: "active", host: $h, hostLabel: $hl, updatedAt: $t}]'
  push_transcripts
}

cmd_reconcile() {
  ensure_base || return 0
  local live
  live="$(tmux ls -F '#{session_name}' 2>/dev/null || true)"
  # Also backfills .tickets on entries recorded before the field existed,
  # using the same TEAM-NNNN rule as parse_linear_id, so `list` shows tickets
  # for every worktree, not just ones re-opened since.
  update_manifest --arg live "$live" --arg t "$(now_utc)" \
    "$JQ_TIX"'
     ($live | split("\n") | map(select(. != ""))) as $l
     | map(. + {tickets: tix})
     | map(if .status == "active" and ((.session as $s | $l | index($s)) == null)
           then . + {status: "inactive", updatedAt: $t}
           elif .status == "inactive" and ((.session as $s | $l | index($s)) != null)
           then . + {status: "active", updatedAt: $t}
           else . end)'
  push_transcripts
}

cmd_list() {
  ensure_base || return 0
  local all=false json=false md=false
  for a in "$@"; do
    case "$a" in
      --all)  all=true ;;
      --json) json=true ;;
      --md)   md=true ;;
      *) echo "dev-session-sync list: unknown flag $a" >&2; return 1 ;;
    esac
  done
  local merged
  merged="$(cat "$ONEDRIVE_BASE"/*.json 2>/dev/null \
    | jq -s "$JQ_TIX"'add // [] | map(. + {tickets: tix}) | sort_by(.status, .session)')"
  if $json; then
    # Machine-readable merged view (all hosts, all statuses). Consumers filter.
    printf '%s\n' "$merged"
    return
  fi
  if $md; then
    local out="$ONEDRIVE_BASE/WORKTREES.md"
    {
      echo "# Dev worktrees"
      echo
      echo "Generated $(now_utc) by \`dev list --md\` on ${HOST_LABEL}. All hosts, all statuses."
      echo
      echo "| Session | Status | Host | Tickets | Branch | Worktree | Chat | Updated |"
      echo "|---|---|---|---|---|---|---|---|"
      printf '%s' "$merged" | jq -r '.[]
        | "| \(.session) | \(.status) | \(.hostLabel // .host) | \((.tickets // []) | join(", ")) | \(.branch // "") | `\(.worktree // "")` | \(.agentSessionId // "") | \(.updatedAt) |"'
    } > "$out"
    echo "wrote $out"
    return
  fi
  {
    echo "SESSION|HOST|STATUS|MODEL|TICKETS|CHAT|UPDATED|BRANCH"
    printf '%s' "$merged" | jq -r --argjson all "$all" \
      '.[] | select($all or .status == "active")
       | [.session, (.hostLabel // .host), .status, .model,
          (((.tickets // []) | join(",")) | if . == "" then "-" else . end),
          ((.agentSessionId // "") | if . == "" then "-" else . end),
          .updatedAt, (.branch // "")] | join("|")'
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
     | [.session, (.hostLabel // .host), (.branch // ""), .model, .updatedAt] | @tsv')

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

  local all=false here=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --all)  all=true;  shift ;;
      --here) here=true; shift ;;
      --)     shift; break ;;
      -*)     echo "dev-session-sync restore: unknown flag '$1'" >&2; return 1 ;;
      *)      break ;;
    esac
  done
  # --here recovers THIS host's OWN sessions — e.g. after a tmux server crash, when
  # the sessions vanished but reconcile hasn't run yet so the manifest still marks
  # them active. Default (no --here) is the cross-machine case: sessions active on
  # OTHER hosts. Either scope skips anything already running here. --here implies
  # "restore them all" (you don't enumerate ~40 crashed sessions by hand).
  local select_all=false
  { $all || $here; } && select_all=true

  local host_match scope
  if $here; then host_match='.host == $h'; scope="this host"
  else           host_match='.host != $h'; scope="other hosts"; fi

  # Candidates: active in the chosen scope, not currently running on this machine.
  local candidates
  candidates="$(cat "$ONEDRIVE_BASE"/*.json 2>/dev/null | jq -r -s --arg h "$HOST" \
    'add // [] | map(select(.status == "active" and ('"$host_match"')))
     | sort_by(.session) | .[]
     | [.session, (.branch // ""), .model, (.agentSessionId // ""), (.worktree // "")] | @tsv')"

  if [ -z "$candidates" ]; then
    echo "No sessions recorded active on $scope."
    return 0
  fi

  local restored=0
  while IFS=$'\t' read -r session branch model agent_session worktree; do
    [ -z "$session" ] && continue
    if ! $select_all; then
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
    # Reuse the recorded Claude session id: resumes the chat if its transcript
    # exists on this machine, otherwise starts fresh under the same id.
    # dev.sh pulls the transcript itself (via `pull`) once it has resolved the
    # LOCAL worktree path — the manifest's worktree is the *other* host's path,
    # and usernames differ across machines (~/workspace/<branch> is a different
    # absolute path, hence a different Claude project dir), so the remote path
    # can't be used to place the transcript here.
    if [ -n "$branch" ]; then
      DEV_TMUX_NO_ATTACH=1 DEV_CLAUDE_SESSION_ID="$agent_session" \
        "$DEV_TMUX" --model "$model" "$branch"
    else
      DEV_TMUX_NO_ATTACH=1 DEV_CLAUDE_SESSION_ID="$agent_session" \
        "$DEV_TMUX" --model "$model"
    fi
    restored=$((restored + 1))
  done <<< "$candidates"

  if [ "$restored" -eq 0 ] && ! $select_all; then
    echo "Nothing restored. Candidates active on $scope:"
    echo "$candidates" | cut -f1 | sed 's/^/  /'
    echo "Run with --all (other hosts), --here (this host, e.g. after a crash), or pass session names."
  else
    echo "Restored $restored session(s). Attach with: dev <branch>  or  dev ctl"
  fi
}

# adopt <old-host-name>...  — fold old (hostname-named) manifests for THIS machine into the
# current UUID manifest: rewrite each entry's host->UUID + hostLabel, dedupe by session
# (newest updatedAt wins), then remove the old files. Use after the hostname-flap migration.
cmd_adopt() {
  ensure_base || return 0
  local uuid_file="$ONEDRIVE_BASE/$HOST.json"
  [ -f "$uuid_file" ] || echo '[]' > "$uuid_file"
  local old name old_file
  for name in "$@"; do
    old_file="$ONEDRIVE_BASE/$name.json"
    [ -f "$old_file" ] || { echo "adopt: no manifest '$name.json'"; continue; }
    [ "$old_file" = "$uuid_file" ] && continue
    local tmp; tmp="$(mktemp)"
    jq -s --arg h "$HOST" --arg hl "$HOST_LABEL" \
      '(.[0] + .[1])
       | map(.host=$h | .hostLabel=$hl)
       | group_by(.session) | map(max_by(.updatedAt // ""))' \
      "$uuid_file" "$old_file" > "$tmp" && mv "$tmp" "$uuid_file"
    rm -f "$old_file"
    echo "adopted '$name' into this machine ($HOST_LABEL)"
  done
}

case "${1:-}" in
  record)    shift; cmd_record "$@" ;;
  reconcile) shift; cmd_reconcile ;;
  list)      shift; cmd_list "$@" ;;
  restore)   shift; cmd_restore "$@" ;;
  push)      shift; cmd_push ;;
  pull)      shift; ensure_base && pull_transcript "$@" ;;
  sync)      shift; cmd_sync ;;
  adopt)     shift; cmd_adopt "$@" ;;
  __entry)   shift; cmd_entry "$@" ;;
  *)
    sed -n '/^# ====/,/^# ====/p' "$0" | sed 's/^# \{0,1\}//' | sed -n '3,40p'
    exit 1
    ;;
esac
