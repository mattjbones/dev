#!/usr/bin/env bash
set -euo pipefail

MODEL="${1:-}"
WORKSPACE_NAME="${2:-}"
WORKTREE="${3:-}"

if [ -z "$MODEL" ] || [ -z "$WORKSPACE_NAME" ] || [ -z "$WORKTREE" ]; then
  exit 0
fi

json_escape() {
  local value="${1:-}"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/ }"
  value="${value//$'\r'/ }"
  value="${value//$'\t'/ }"
  printf '%s' "$value"
}

emit_json() {
  local source="${1:-unknown}"
  local percent="${2:-}"
  local label="${3:-}"
  local detail="${4:-}"
  local updated_at
  updated_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  printf '{'
  printf '"model":"%s",' "$(json_escape "$MODEL")"
  printf '"workspace":"%s",' "$(json_escape "$WORKSPACE_NAME")"
  printf '"worktree":"%s",' "$(json_escape "$WORKTREE")"
  printf '"source":"%s",' "$(json_escape "$source")"
  printf '"updated_at":"%s",' "$updated_at"

  if [ -n "$percent" ]; then
    printf '"percent":%s,' "$percent"
  else
    printf '"percent":null,'
  fi

  if [ -n "$label" ]; then
    printf '"label":"%s",' "$(json_escape "$label")"
  else
    printf '"label":null,'
  fi

  if [ -n "$detail" ]; then
    printf '"detail":"%s"' "$(json_escape "$detail")"
  else
    printf '"detail":null'
  fi

  printf '}\n'
}

collect_claude() {
  local percent=""
  local context_tokens=""
  local cache_file="/tmp/dev-tmux-title/${WORKSPACE_NAME}-tokens"
  local window="${CLAUDE_CONTEXT_WINDOW_TOKENS:-1000000}"

  local encoded_path project_dir session_file
  # Claude Code encodes project dirs by replacing EVERY non-alphanumeric char with '-',
  # not just '/' (e.g. the unicode hyphen in worktrees like ENG‑7444 becomes ASCII '-').
  # Force a UTF-8 locale so sed treats multibyte chars as one character.
  encoded_path="$(printf '%s' "$WORKTREE" | LC_ALL=en_US.UTF-8 sed -E 's/[^a-zA-Z0-9]/-/g')"
  project_dir="$HOME/.claude/projects/${encoded_path}"

  if [ -d "$project_dir" ]; then
    # Skip agent-*.jsonl subagent transcripts - they would report the subagent's
    # tiny context instead of the main session's.
    session_file="$(ls -t "$project_dir"/*.jsonl 2>/dev/null | grep -v '/agent-' | head -1)"
  fi

  # Source 1: JSONL — newest assistant message with .message.usage (authoritative).
  # The old grep '"usage":{[^}]*}' broke on nested objects inside usage (cache_creation, etc.)
  # and the token cache was read first, so stale "2%" never refreshed from JSONL.
  if [ -n "${session_file:-}" ] && [ -f "$session_file" ] && command -v jq &>/dev/null; then
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      t="$(
        printf '%s' "$line" | jq -r '
          if (type == "object")
             and (.message | type == "object")
             and (.message.usage | type == "object")
          then
            (.message.usage.input_tokens // 0)
            + (.message.usage.cache_read_input_tokens // 0)
            + (.message.usage.cache_creation_input_tokens // 0)
          else
            empty
          end
        ' 2>/dev/null || true
      )"
      if [ -n "$t" ] && [[ "$t" =~ ^[0-9]+$ ]] && [ "$t" -gt 0 ]; then
        context_tokens="$t"
        break
      fi
    done < <(tail -n 8000 "$session_file" 2>/dev/null | tail -r)
  fi

  if [ -n "$context_tokens" ] && [ "$context_tokens" -gt 0 ] 2>/dev/null; then
    percent=$(( context_tokens * 100 / window ))
    [ "$percent" -lt 1 ] && percent=1
    mkdir -p "$(dirname "$cache_file")"
    echo "${percent}%" > "$cache_file"
  fi

  # Source 2: statusline cache (only if JSONL did not yield a value this run)
  if [ -z "$percent" ] && [ -f "$cache_file" ]; then
    local cached
    cached="$(tr -d '\n' < "$cache_file" 2>/dev/null || true)"
    percent="$(printf '%s' "$cached" | sed -n 's/^\([0-9][0-9]*\)%$/\1/p')"
  fi

  if [ -n "$percent" ] && [ "$percent" -gt 0 ] 2>/dev/null; then
    if [ -n "$context_tokens" ]; then
      emit_json "claude-jsonl" "$percent" "${percent}%" ""
    else
      emit_json "claude-cache" "$percent" "${percent}%" ""
    fi
  else
    emit_json "claude" "" "" ""
  fi
}

collect_codex() {
  local db="$HOME/.codex/state_5.sqlite"
  local log_file="$HOME/.codex/log/codex-tui.log"

  if [ ! -f "$db" ]; then
    emit_json "codex-sqlite" "" "" "state-db-missing"
    return
  fi

  local row thread_id model tokens_used updated_at
  row="$(
    sqlite3 -noheader -separator $'\t' "$db" "
      SELECT
        id,
        COALESCE(NULLIF(model, ''), ''),
        tokens_used,
        updated_at
      FROM threads
      WHERE cwd = '$WORKTREE'
         OR cwd LIKE '$WORKTREE/%'
      ORDER BY updated_at DESC
      LIMIT 1;
    " 2>/dev/null || true
  )"

  if [ -z "$row" ]; then
    emit_json "codex-sqlite" "" "" "thread-missing"
    return
  fi

  IFS=$'\t' read -r thread_id model tokens_used updated_at <<< "$row"

  if [ -n "$thread_id" ] && [ -f "$log_file" ]; then
    local log_line estimated_token_count auto_compact_limit percent label
    log_line="$(
      rg "${thread_id}.*codex_core::codex: post sampling token usage.*estimated_token_count=Some\\([0-9]+" "$log_file" 2>/dev/null | tail -n 1 || true
    )"

    if [ -n "$log_line" ]; then
      estimated_token_count="$(printf '%s' "$log_line" | sed -n 's/.*estimated_token_count=Some(\([0-9][0-9]*\)).*/\1/p')"
      auto_compact_limit="$(printf '%s' "$log_line" | sed -n 's/.*auto_compact_limit=\([0-9][0-9]*\).*/\1/p')"

      if [[ "$estimated_token_count" =~ ^[0-9]+$ ]] && [[ "$auto_compact_limit" =~ ^[0-9]+$ ]] && [ "$auto_compact_limit" -gt 0 ]; then
        percent=$(( estimated_token_count * 100 / auto_compact_limit ))
        label="${percent}%"
        emit_json "codex-log" "$percent" "$label" "${estimated_token_count}/${auto_compact_limit} tok"
        return
      fi
    fi
  fi

  if [ -z "$tokens_used" ] || ! [[ "$tokens_used" =~ ^[0-9]+$ ]]; then
    emit_json "codex-sqlite" "" "" "tokens-missing"
    return
  fi

  emit_json "codex-sqlite" "" "${tokens_used} tok" "cumulative-usage-only"
}

case "$MODEL" in
  claude)
    collect_claude
    ;;
  codex)
    collect_codex
    ;;
  *)
    emit_json "unsupported" "" "" "model-unsupported"
    ;;
esac
