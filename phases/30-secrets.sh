#!/usr/bin/env bash
# Phase 30 — pull secrets from Bitwarden per secrets/manifest.tsv.
# Secret values never hit stdout/logs; files land with the manifest's mode.
# Failures warn and continue so one missing vault item doesn't block the rest.
# REPLACE_ME placeholders (from scripts/seed-vault.sh) are never written.

phase_secrets() {
  local manifest="$REPO_ROOT/secrets/manifest.tsv"
  local item kind source dest mode post value var fails=0

  if [[ "${DRY_RUN:-0}" == 1 ]]; then
    while read -r item kind source dest mode post; do
      [[ -z "$item" || "$item" == \#* ]] && continue
      log "  (dry-run) pull $item ($kind) -> $dest [post: $post]"
    done < "$manifest"
    return 0
  fi

  bw_ensure_unlocked || return 1
  umask 077

  while read -r item kind source dest mode post; do
    [[ -z "$item" || "$item" == \#* ]] && continue
    dest="${dest/#\~/$HOME}"
    dest="${dest//\$BOOTSTRAP_TMP/$BOOTSTRAP_TMP}"

    # Idempotency: skip without touching the vault when already converged.
    case $post in
      template) ;;  # always fetched — held in memory for 40-apps
      env:*)
        var="${post#env:}"
        if [[ "${FORCE:-0}" != 1 ]] && grep -q "^export $var=" "$dest" 2>/dev/null; then
          ok "$var already in $dest (--force to refresh)"
          continue
        fi
        ;;
      gpg-import)
        if [[ "${FORCE:-0}" != 1 ]] && [[ -n "$(gpg --list-secret-keys 2>/dev/null)" ]]; then
          ok "GPG secret key present"
          continue
        fi
        ;;
      -)
        if [[ -s "$dest" && "${FORCE:-0}" != 1 ]]; then
          ok "$dest (exists; --force to re-pull)"
          continue
        fi
        ;;
      *)
        warn "unknown post '$post' for $item"; fails=1
        continue
        ;;
    esac

    case $kind in
      field)       value="$(bw_get_field "$item" "$source")" ;;
      note|note64) value="$(bw_get_notes "$item")" ;;
      *)           warn "unknown kind '$kind' for $item"; fails=1; continue ;;
    esac
    if [[ -z "$value" || "$value" == REPLACE_ME* ]]; then
      warn "no real value for $item yet — fill it in Bitwarden (see README)"; fails=1
      continue
    fi

    case $post in
      template)
        # Held in memory for 40-apps (phases are sourced; export survives).
        export CMUX_SOCKET_PASSWORD="$value"
        apply "staged $item.$source for app templating"
        ;;
      env:*)
        env_set "$var" "$value" "$dest"
        ;;
      gpg-import|-)
        mkdir -p "$(dirname "$dest")"
        if [[ $kind == note64 ]]; then
          if ! printf '%s' "$value" | base64 -d > "$dest"; then
            warn "base64 decode failed for $item"; fails=1
            rm -f "$dest"
            continue
          fi
        else
          printf '%s\n' "$value" > "$dest"
        fi
        chmod "$mode" "$dest"
        if [[ $post == gpg-import ]]; then
          if gpg --import "$dest"; then
            rm -P "$dest"
            apply "imported GPG key"
          else
            warn "gpg import failed for $item"; fails=1
          fi
        else
          apply "wrote $dest ($mode)"
        fi
        ;;
    esac
  done < "$manifest"

  [[ $fails == 0 ]] || warn "some secrets failed — fix vault items and re-run (see README)"
}
phase_secrets
