#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/devctl-test-helpers.sh"

# Sourcing as a library must NOT launch fzf / run the dispatch, and must exit 0.
# Guard with timeout to prevent hangs if source guard regresses.
_out_file=$(mktemp)
trap "rm -f '$_out_file'" RETURN

DEVCTL_LIB=1 bash -c 'source "'"$DIR"'/../dev-ctl.sh"; echo SOURCED_OK' > "$_out_file" 2>&1 &
_pid=$!

# Wait up to 5 seconds (50 iterations of 0.1s each)
_elapsed=0
while kill -0 "$_pid" 2>/dev/null && [ $_elapsed -lt 50 ]; do
  sleep 0.1
  _elapsed=$((_elapsed + 1))
done

# Check if process is still running (timeout occurred)
if kill -0 "$_pid" 2>/dev/null; then
  kill -9 "$_pid" 2>/dev/null || true
  out="ERROR: timeout after 5s"
else
  out="$(cat "$_out_file")"
  wait "$_pid" 2>/dev/null || true
fi

assert_eq "$(printf '%s' "$out" | tail -1)" "SOURCED_OK" "sourcing as lib does not dispatch"
finish
