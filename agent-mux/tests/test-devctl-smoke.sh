#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/devctl-test-helpers.sh"
# Sourcing as a library must NOT launch fzf / run the dispatch, and must exit 0.
out="$(DEVCTL_LIB=1 bash -c 'source "'"$DIR"'/../dev-ctl.sh"; echo SOURCED_OK' 2>&1)"
assert_eq "$(printf '%s' "$out" | tail -1)" "SOURCED_OK" "sourcing as lib does not dispatch"
finish
