#!/usr/bin/env bash
# Phase 50 — macOS system defaults. Gated (mutates system prefs and restarts
# Dock/Finder); idempotent: writes only when the current value differs, and
# restarts only the apps whose domains changed.

CHANGED_TARGETS=()

# set_default <domain> <key> <type> <value> <restart-target|->
set_default() {
  local domain=$1 key=$2 type=$3 value=$4 restart=$5 current
  current="$(defaults read "$domain" "$key" 2>/dev/null || echo '<unset>')"
  if [[ "$current" == "$value" ]]; then
    ok "$domain $key = $value"
    return 0
  fi
  if [[ "${DRY_RUN:-0}" == 1 ]]; then
    log "  (dry-run) defaults write $domain $key -$type $value (was: $current)"
    return 0
  fi
  defaults write "$domain" "$key" "-$type" "$value"
  apply "$domain $key: $current -> $value"
  if [[ "$restart" != - ]]; then CHANGED_TARGETS+=("$restart"); fi
}

phase_macos() {
  if ! gate "About to change system defaults (Dock, appearance, trackpad). Apply?"; then
    log "  skipped"
    return 0
  fi
  # shellcheck source=macos/defaults.sh
  source "$REPO_ROOT/macos/defaults.sh"
  if [[ ${#CHANGED_TARGETS[@]} -gt 0 ]]; then   # empty-array guard (bash 3.2 + set -u)
    while IFS= read -r t; do
      killall "$t" >/dev/null 2>&1 || true
      apply "restarted $t"
    done < <(printf '%s\n' "${CHANGED_TARGETS[@]}" | sort -u)
  fi
}
phase_macos
