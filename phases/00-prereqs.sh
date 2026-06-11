#!/usr/bin/env bash
# Phase 00 — Xcode CLT + Homebrew. Sourced by bootstrap.sh.

if xcode-select -p >/dev/null 2>&1; then
  ok "Xcode CLT present"
else
  apply "installing Xcode Command Line Tools (GUI prompt will appear)"
  run xcode-select --install
  if [[ "${DRY_RUN:-0}" != 1 ]]; then
    warn "re-run bootstrap once the CLT install finishes"
    exit 1
  fi
fi

if command -v brew >/dev/null 2>&1; then
  ok "Homebrew present"
else
  apply "installing Homebrew"
  if [[ "${DRY_RUN:-0}" == 1 ]]; then
    log "  (dry-run) run official Homebrew install script"
  else
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
fi

# Make brew visible to the rest of this run (fresh machine: not on PATH yet).
if [[ -x /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi
