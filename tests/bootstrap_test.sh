#!/usr/bin/env bash
# Tests for bootstrap.sh flag/phase handling. Run: bash tests/bootstrap_test.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PASS=0 FAIL=0
assert() {
  local desc=$1; shift
  if "$@"; then PASS=$((PASS + 1)); echo "  ok: $desc"
  else FAIL=$((FAIL + 1)); echo "  FAIL: $desc"; fi
}

assert "--help exits 0" ./bootstrap.sh --help
assert "unknown flag exits 1" test "$(./bootstrap.sh --bogus >/dev/null 2>&1; echo $?)" = 1

out=$(./bootstrap.sh --dry-run --tier 1 --yes)
assert "dry-run announces itself" grep -q 'DRY RUN' <<<"$out"
assert "tier 1 runs prereqs" grep -q '00-prereqs' <<<"$out"
assert "tier 1 runs dotfiles" grep -q '20-dotfiles' <<<"$out"
assert "tier 1 excludes tier-2 phases" bash -c "! grep -q '30-' <<<'$out'"

out=$(./bootstrap.sh --dry-run --only dotfiles --yes)
assert "--only filters to one phase" grep -q '\[1/1\] 20-dotfiles' <<<"$out"

echo "passed $PASS, failed $FAIL"
[[ $FAIL -eq 0 ]]
