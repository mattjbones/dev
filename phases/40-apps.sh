#!/usr/bin/env bash
# Phase 40 — app configs. Zed is plain dotfiles (home/.config/zed, phase 20).
# Here: render cmux settings from template (secret held by phase 30) and
# stage the interactive Raycast import.

phase_apps() {
  local tmpl="$REPO_ROOT/home/.config/cmux/settings.json.tmpl"
  local dest="$HOME/.config/cmux/settings.json"
  local staged="$BOOTSTRAP_TMP/raycast.rayconfig"
  local marker="$HOME/.config/dev/.raycast-imported"
  local rendered

  if [[ "${DRY_RUN:-0}" == 1 ]]; then
    log "  (dry-run) render cmux settings.json from template"
    log "  (dry-run) prompt for Raycast import if a .rayconfig is staged"
    return 0
  fi

  if [[ -z "${CMUX_SOCKET_PASSWORD:-}" ]]; then
    warn "cmux: no socket password in env (secrets phase not run?) — skipped"
  else
    rendered="$(<"$tmpl")"
    rendered="${rendered//\{\{CMUX_SOCKET_PASSWORD\}\}/$CMUX_SOCKET_PASSWORD}"
    if [[ -f "$dest" && "$(<"$dest")" == "$rendered" ]]; then
      ok "cmux settings.json up to date"
    else
      if [[ -f "$dest" && "${NO_BACKUP:-0}" != 1 ]]; then
        mv "$dest" "$dest.bak"
        warn "$dest existed — backed up to $dest.bak"
      fi
      mkdir -p "$(dirname "$dest")"
      (umask 077; printf '%s\n' "$rendered" > "$dest")
      apply "rendered cmux settings.json"
    fi
  fi

  if [[ -f "$marker" ]]; then
    ok "Raycast already imported"
  elif [[ -f "$staged" ]]; then
    log "  ▸ Raycast: open Raycast → Settings → Import, file at $staged"
    if gate "  Done?"; then
      mkdir -p "$(dirname "$marker")"
      touch "$marker"
      apply "Raycast import recorded"
    fi
  else
    warn "Raycast: no staged .rayconfig (run secrets phase first) — skipped"
  fi
}
phase_apps
