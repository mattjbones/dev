#!/usr/bin/env bash
set -euo pipefail

# dev-wait-pnpm.sh — Block until the background pnpm install started by dev.sh
# has finished, so the dev server (nx/vite) doesn't start before node_modules
# exists ("Could not find Nx modules ... Have you run npm/yarn install?").
#
# Usage:
#   dev-wait-pnpm.sh <done_file> [log_file]
#
# dev.sh runs `run_pnpm_install` in the background and, on completion, writes the
# install's exit code to <done_file>. This script polls for that file (the real
# completion condition — not an arbitrary sleep), then:
#   - exit 0 if install succeeded (caller proceeds to start the dev server)
#   - exit 1 if install failed   (caller's `&& docker-start.sh` is skipped)
#   - exit 0 on timeout, with a warning (never block the build pane forever)
#
# Override the timeout with DEV_PNPM_WAIT_TIMEOUT (seconds, default 900).

done_file="${1:?usage: dev-wait-pnpm.sh <done_file> [log_file]}"
log_file="${2:-}"
timeout_secs="${DEV_PNPM_WAIT_TIMEOUT:-900}"

if [ ! -f "$done_file" ]; then
  printf '⏳ Waiting for pnpm install to finish before starting the dev server'
  [ -n "$log_file" ] && printf ' (log: %s)' "$log_file"
  printf '...\n'
fi

waited=0
while [ ! -f "$done_file" ]; do
  if [ "$waited" -ge "$timeout_secs" ]; then
    echo "⚠️  pnpm install did not signal completion within ${timeout_secs}s; starting the dev server anyway." >&2
    exit 0
  fi
  sleep 1
  waited=$((waited + 1))
done

code="$(cat "$done_file" 2>/dev/null || echo 1)"
if [ "$code" = "0" ]; then
  echo "✅ pnpm install complete — starting the dev server."
  exit 0
fi

echo "❌ pnpm install failed (exit $code); not starting the dev server." >&2
if [ -n "$log_file" ] && [ -f "$log_file" ]; then
  echo "---- last 20 lines of $log_file ----" >&2
  tail -20 "$log_file" >&2
fi
exit 1
