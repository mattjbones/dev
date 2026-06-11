#!/usr/bin/env bash
# Phase 20 — symlink every file under home/ into $HOME (per-file, never the
# directory: $HOME dirs like ~/.claude also hold machine-local state).

while IFS= read -r -d '' src; do
  rel="${src#"$REPO_ROOT"/home/}"
  backup_then_link "$src" "$HOME/$rel"
done < <(find "$REPO_ROOT/home" -type f -print0)
