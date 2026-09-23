#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# dev-cmux-resume.sh — tell cmux how to bring this pane back after a restart
# =============================================================================
#
# cmux persists a per-surface "resume binding" and replays it when the app
# reopens. Left to its own detection it records the pane's foreground process,
# which for a dev session is `tmux attach -t <name>`. The tmux server is
# in-memory, so after an OS reboot that replay fails with "no sessions" and the
# pane looks dead. Attaching our own binding — `dev <name>` — makes the replay
# rebuild the worktree session instead. A CLI-set binding is kept even when
# cmux later detects tmux inside the pane (verified 2026-09-21).
#
# cmux records CLI bindings with approvalPolicy=manual; the first replay asks
# you to approve the `dev …` command, after which it can auto-resume.
#
# Usage: dev-cmux-resume.sh <session> [--model <claude|codex>]
# No-op (exit 0) outside cmux (no $CMUX_SURFACE_ID) or when cmux isn't found.
# =============================================================================

session="${1:?session required}"; shift
[ -n "${CMUX_SURFACE_ID:-}" ] || exit 0

CMUX_BIN="$(command -v cmux 2>/dev/null || true)"
if [ -z "$CMUX_BIN" ] && [ -x "/Applications/cmux.app/Contents/Resources/bin/cmux" ]; then
  CMUX_BIN="/Applications/cmux.app/Contents/Resources/bin/cmux"
fi
[ -n "$CMUX_BIN" ] || exit 0

ctx=(--surface "$CMUX_SURFACE_ID")
[ -n "${CMUX_WORKSPACE_ID:-}" ] && ctx=(--workspace "$CMUX_WORKSPACE_ID" "${ctx[@]}")

# `dev` resolves via PATH at replay time (~/bin/dev). Extra args (e.g. --model)
# are passed through verbatim so the rebuilt session matches the original.
"$CMUX_BIN" surface resume set "${ctx[@]}" --kind tmux --name "dev $session" \
  --cwd "$HOME/workspace" -- dev "$session" "$@" >/dev/null 2>&1 || true
