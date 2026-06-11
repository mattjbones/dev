#!/usr/bin/env bash
# Phase 15 — node toolchain. Owned by nvm (not brew); pnpm via corepack.

export NVM_DIR="$HOME/.nvm"

if [[ -d "$NVM_DIR" ]]; then
  ok "nvm present"
else
  apply "installing nvm"
  if [[ "${DRY_RUN:-0}" == 1 ]]; then
    log "  (dry-run) run official nvm install script"
  else
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.5/install.sh)"
  fi
fi

if [[ "${DRY_RUN:-0}" == 1 ]]; then
  log "  (dry-run) nvm install --lts && corepack enable"
else
  # shellcheck source=/dev/null
  [[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh"
  apply "nvm install --lts"
  nvm install --lts
  apply "corepack enable (provides pnpm)"
  corepack enable
fi
