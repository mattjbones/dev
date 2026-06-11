#!/usr/bin/env bash
# Integration test: dotfiles phase links home/** into $HOME, idempotently.
# Run: bash tests/dotfiles_test.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

fail=0
check() { "$@" || { echo "  FAIL: $*"; fail=1; }; }

out1=$(HOME="$tmp" ./bootstrap.sh --only dotfiles --yes)
check test -L "$tmp/.zshrc"
check test -L "$tmp/.claude/CLAUDE.md"
check grep -q '⟳' <<<"$out1"                       # first run applies

out2=$(HOME="$tmp" ./bootstrap.sh --only dotfiles --yes)
check bash -c "! grep -q '⟳' <<<'$out2'"           # second run all ✓ (idempotent)

# real-file conflict -> backed up, then linked
rm "$tmp/.zshrc"; echo real > "$tmp/.zshrc"
HOME="$tmp" ./bootstrap.sh --only dotfiles --yes >/dev/null
check test -f "$tmp/.zshrc.bak"
check test -L "$tmp/.zshrc"

[[ $fail -eq 0 ]] && echo "ok: dotfiles phase links and converges"
exit "$fail"
