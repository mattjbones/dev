#!/usr/bin/env bash
# Tests for the macos phase with defaults/killall stubbed on PATH.
# Run: bash tests/macos_test.sh
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
stub="$tmp/stub"; mkdir -p "$stub" "$tmp/state"
export DEFAULTS_STATE="$tmp/state" KILLALL_LOG="$tmp/killall-log"

cat > "$stub/defaults" <<'EOF'
#!/usr/bin/env bash
case $1 in
  read)  cat "$DEFAULTS_STATE/$2.$3" 2>/dev/null || { echo "does not exist" >&2; exit 1; } ;;
  write) echo "$5" > "$DEFAULTS_STATE/$2.$3" ;;
esac
EOF
cat > "$stub/killall" <<'EOF'
#!/usr/bin/env bash
echo "$1" >> "$KILLALL_LOG"
EOF
chmod +x "$stub/defaults" "$stub/killall"
export PATH="$stub:$PATH"

./bootstrap.sh --only macos --yes >/dev/null 2>&1
assert "writes dock autohide" test "$(cat "$tmp/state/com.apple.dock.autohide" 2>/dev/null)" = 1
assert "writes tilesize" test "$(cat "$tmp/state/com.apple.dock.tilesize" 2>/dev/null)" = 39
assert "writes dark mode" test "$(cat "$tmp/state/NSGlobalDomain.AppleInterfaceStyle" 2>/dev/null)" = Dark
assert "restarts Dock once" test "$(grep -c Dock "$KILLALL_LOG" 2>/dev/null)" = 1
assert "no Finder restart needed" test "$(grep -c Finder "$KILLALL_LOG" 2>/dev/null)" = 0

out2=$(./bootstrap.sh --only macos --yes 2>&1)
assert "second run all converged" not_grep '⟳' "$out2"
assert "second run no restarts" test "$(grep -c Dock "$KILLALL_LOG" 2>/dev/null)" = 1

rm -rf "${DEFAULTS_STATE:?}"/* "$KILLALL_LOG"
out3=$(./bootstrap.sh --only macos --yes --dry-run 2>&1)
assert "dry-run lists writes" does_grep 'dry-run.*autohide' "$out3"
assert "dry-run writes nothing" test -z "$(ls -A "$DEFAULTS_STATE")"

echo "passed $PASS, failed $FAIL"
[[ $FAIL -eq 0 ]]
