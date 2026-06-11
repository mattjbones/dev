#!/usr/bin/env bash
# Phase 30 — pull secrets from Bitwarden per secrets/manifest.tsv.
# Secret values never hit stdout/logs; files land with the manifest's mode.
# Failures warn and continue so one missing vault item doesn't block the rest.

phase_secrets() {
  local manifest="$REPO_ROOT/secrets/manifest.tsv"
  local item kind source dest mode post value var fails=0

  if [[ "${DRY_RUN:-0}" == 1 ]]; then
    while read -r item kind source dest mode post; do
      [[ -z "$item" || "$item" == \#* ]] && continue
      log "  (dry-run) pull $item/$source ($kind) -> $dest [post: $post]"
    done < "$manifest"
    return 0
  fi

  bw_ensure_unlocked || return 1
  umask 077

  while read -r item kind source dest mode post; do
    [[ -z "$item" || "$item" == \#* ]] && continue
    dest="${dest/#\~/$HOME}"
    dest="${dest//\$BOOTSTRAP_TMP/$BOOTSTRAP_TMP}"

    case $post in
      template)
        # Held in memory for 40-apps (phases are sourced; export survives).
        if value="$(bw_get_field "$item" "$source")" && [[ -n "$value" ]]; then
          export CMUX_SOCKET_PASSWORD="$value"
          apply "staged $item.$source for app templating"
        else
          warn "could not fetch $item.$source"; fails=1
        fi
        ;;
      env:*)
        var="${post#env:}"
        if [[ "${FORCE:-0}" != 1 ]] && grep -q "^export $var=" "$dest" 2>/dev/null; then
          ok "$var already in $dest (--force to refresh)"
        elif value="$(bw_get_field "$item" "$source")" && [[ -n "$value" ]]; then
          env_set "$var" "$value" "$dest"
        else
          warn "could not fetch $item.$source"; fails=1
        fi
        ;;
      gpg-import)
        if [[ "${FORCE:-0}" != 1 ]] && [[ -n "$(gpg --list-secret-keys 2>/dev/null)" ]]; then
          ok "GPG secret key present"
        elif bw_get_attachment "$item" "$source" "$dest" && gpg --import "$dest"; then
          rm -P "$dest"
          apply "imported GPG key"
        else
          warn "could not import $item/$source"; fails=1
        fi
        ;;
      -)
        if [[ -s "$dest" && "${FORCE:-0}" != 1 ]]; then
          ok "$dest (exists; --force to re-pull)"
        elif mkdir -p "$(dirname "$dest")" && bw_get_attachment "$item" "$source" "$dest"; then
          chmod "$mode" "$dest"
          apply "wrote $dest ($mode)"
        else
          warn "could not fetch $item/$source"; fails=1
        fi
        ;;
      *)
        warn "unknown post '$post' for $item/$source"; fails=1
        ;;
    esac
  done < "$manifest"

  [[ $fails == 0 ]] || warn "some secrets failed — fix vault items and re-run (see README)"
}
phase_secrets
