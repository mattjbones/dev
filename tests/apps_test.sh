#!/usr/bin/env bash
# Tests for the apps phase (cmux render + raycast marker) against a temp $HOME.
# Run: bash tests/apps_test.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PASS=0 FAIL=0
assert() {
  local desc=$1; shift
  if "$@"; then PASS=$((PASS + 1)); echo "  ok: $desc"
  else FAIL=$((FAIL + 1)); echo "  FAIL: $desc"; fi
}
# shellcheck disable=SC2329  # invoked indirectly via assert
not_grep() { ! grep -q "$1" <<<"$2"; }
# shellcheck disable=SC2329  # invoked indirectly via assert
does_grep() { grep -q "$1" <<<"$2"; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# cmux: render from template with key in env
out1=$(HOME="$tmp" CMUX_SOCKET_PASSWORD=testpass ./bootstrap.sh --only apps --yes 2>&1)
cfg="$tmp/.config/cmux/settings.json"
assert "cmux settings rendered" test -f "$cfg"
assert "placeholder substituted" grep -q 'testpass' "$cfg"
assert "no placeholder remains" bash -c "! grep -q '{{CMUX_SOCKET_PASSWORD}}' '$cfg'"
assert "rendered mode 600" test "$(stat -f %Lp "$cfg")" = 600
assert "secret not logged" not_grep 'testpass' "$out1"
assert "raycast warns when nothing staged" does_grep 'Raycast: no staged' "$out1"

# idempotent: unchanged render -> no ⟳ for cmux
out2=$(HOME="$tmp" CMUX_SOCKET_PASSWORD=testpass ./bootstrap.sh --only apps --yes 2>&1)
assert "second render is no-op" not_grep 'rendered cmux' "$out2"

# no key in env -> warn, still exit 0
out3=$(HOME="$tmp" ./bootstrap.sh --only apps --yes 2>&1)
assert "missing key warns" does_grep 'no socket password' "$out3"

# raycast: marker short-circuits the prompt
mkdir -p "$tmp/.config/dev" && touch "$tmp/.config/dev/.raycast-imported"
out4=$(HOME="$tmp" CMUX_SOCKET_PASSWORD=testpass ./bootstrap.sh --only apps --yes 2>&1)
assert "marker skips raycast" does_grep 'Raycast already imported' "$out4"

echo "passed $PASS, failed $FAIL"
[[ $FAIL -eq 0 ]]
