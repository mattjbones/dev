#!/usr/bin/env bash
# Phase 20 — symlink every file under home/ into $HOME (per-file, never the
# directory: $HOME dirs like ~/.claude also hold machine-local state).
# *.tmpl files are render sources for the apps phase, not dotfiles.

while IFS= read -r -d '' src; do
  rel="${src#"$REPO_ROOT"/home/}"
  backup_then_link "$src" "$HOME/$rel"
done < <(find "$REPO_ROOT/home" -type f ! -name '*.tmpl' -print0)

# Standalone CLI tools — symlinked into ~/bin (expected to already be on PATH
# via home/.zshrc) rather than mirrored under home/, since they live at the
# repo root/subdirs, not as dotfiles. "name:relpath" pairs — plain array, not
# an associative one: macOS ships bash 3.2 (no declare -A) on a factory-reset
# machine, before this same bootstrap gets a chance to install a newer bash.
BIN_TOOLS=(
  "dev:agent-mux/dev.sh"
  "dev-aws:scripts/dev-aws.sh"
  "dev-ctl:agent-mux/dev-ctl.sh"
  "linear-dash:linear-dash"
  "github-dash:github-dash"
)
for entry in "${BIN_TOOLS[@]}"; do
  backup_then_link "$REPO_ROOT/${entry#*:}" "$HOME/bin/${entry%%:*}"
done
