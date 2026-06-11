#!/usr/bin/env bash
# Phase 10 — converge on the Brewfile. Sourced by bootstrap.sh.

if [[ "${DRY_RUN:-0}" == 1 ]]; then
  log "  (dry-run) brew bundle --file=$REPO_ROOT/Brewfile"
  brew bundle check --file="$REPO_ROOT/Brewfile" || true
else
  apply "brew bundle"
  brew bundle --file="$REPO_ROOT/Brewfile"
fi
