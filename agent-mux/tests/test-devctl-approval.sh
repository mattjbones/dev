#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/devctl-test-helpers.sh"
DEVCTL_LIB=1 source "$DIR/../dev-ctl.sh"
cand="$(printf 'a\nb\nc\n')"; keep="$(printf 'b\n')"
out="$(devctl_removal_after_keepers "$cand" "$keep")"
assert_eq "$(printf '%s' "$out" | tr '\n' ',')" "a,c" "removes all but keepers"
out2="$(devctl_removal_after_keepers "$cand" "")"
assert_eq "$(printf '%s' "$out2" | tr '\n' ',')" "a,b,c" "empty keepers removes all"
finish
