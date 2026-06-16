#!/usr/bin/env bash
# Local, network-free attention-state derivation for the board.

# attention_from_pane <captured-pane-text> -> blocked|working|idle
attention_from_pane() {
  local text="$1"
  if printf '%s' "$text" | grep -qiE 'do you want|proceed\?|\(y/n\)|❯ *1\.|waiting for your input'; then
    echo blocked
  elif printf '%s' "$text" | grep -qE 'esc to interrupt|✳|Thinking|Computing|Running|tool use'; then
    echo working
  else
    echo idle
  fi
}

# attention_for_session <session> -> blocked|working|idle  (captures pane .0)
attention_for_session() {
  local s="$1" text
  text="$(tmux capture-pane -t "$s:.0" -p 2>/dev/null || true)"
  attention_from_pane "$text"
}

# last_focus_for_session <session> -> epoch seconds of last activity (0 if unknown)
last_focus_for_session() {
  tmux display-message -p -t "$1" '#{session_activity}' 2>/dev/null || echo 0
}
