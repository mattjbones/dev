#!/usr/bin/env bash
# Tests for lib/common.sh. Run: bash tests/common_test.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=lib/common.sh
source lib/common.sh

PASS=0 FAIL=0
assert() { # assert <desc> <command...>
  local desc=$1; shift
  if "$@"; then PASS=$((PASS + 1)); echo "  ok: $desc"
  else FAIL=$((FAIL + 1)); echo "  FAIL: $desc"; fi
}

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
src="$tmp/repo/file"
mkdir -p "$tmp/repo" "$tmp/home"
echo content > "$src"

# backup_then_link: missing dest -> symlink created (parents made)
dest="$tmp/home/.nested/file"
backup_then_link "$src" "$dest" >/dev/null
assert "creates symlink with parents" test "$(readlink "$dest")" = "$src"

# backup_then_link: correct symlink -> no-op, reports ok
out=$(backup_then_link "$src" "$dest")
assert "idempotent on correct symlink" grep -q '✓' <<<"$out"

# backup_then_link: symlink elsewhere -> repointed
ln -sfn "$tmp/elsewhere" "$dest"
backup_then_link "$src" "$dest" >/dev/null
assert "repoints wrong symlink" test "$(readlink "$dest")" = "$src"

# backup_then_link: real file -> backed up to .bak, then linked
rm "$dest"; echo real > "$dest"
backup_then_link "$src" "$dest" >/dev/null
assert "backs up real file" test -f "$dest.bak"
assert "links after backup" test "$(readlink "$dest")" = "$src"

# backup_then_link: real file + NO_BACKUP=1 -> overwritten, no .bak
dest2="$tmp/home/.plain"
echo real > "$dest2"
NO_BACKUP=1 backup_then_link "$src" "$dest2" >/dev/null
assert "no-backup overwrites" test "$(readlink "$dest2")" = "$src"
assert "no-backup leaves no .bak" test ! -e "$dest2.bak"

# backup_then_link: DRY_RUN=1 -> touches nothing
dest3="$tmp/home/.dry"
DRY_RUN=1 backup_then_link "$src" "$dest3" >/dev/null
assert "dry-run creates nothing" test ! -e "$dest3"

# gate: auto-confirms under YES=1 and DRY_RUN=1
assert "gate passes with YES=1" env YES=1 bash -c 'source lib/common.sh; gate "q?"'
assert "gate passes with DRY_RUN=1" env DRY_RUN=1 bash -c 'source lib/common.sh; gate "q?"'

# env_set: creates file (mode 600) with one export line
envfile="$tmp/home/.config/dev/env"
env_set DD_API_KEY secret1 "$envfile" >/dev/null
assert "env_set creates export line" grep -q "^export DD_API_KEY='secret1'$" "$envfile"
assert "env_set sets mode 600" test "$(stat -f %Lp "$envfile")" = 600

# env_set: replaces existing line, no duplicates, preserves other lines
env_set DD_SITE site1 "$envfile" >/dev/null
env_set DD_API_KEY secret2 "$envfile" >/dev/null
assert "env_set replaces value" grep -q "^export DD_API_KEY='secret2'$" "$envfile"
assert "env_set no duplicates" test "$(grep -c '^export DD_API_KEY=' "$envfile")" = 1
assert "env_set preserves other vars" grep -q "^export DD_SITE='site1'$" "$envfile"

# env_set: dry-run touches nothing
DRY_RUN=1 env_set NEW_VAR x "$tmp/home/.config/dev/env2" >/dev/null
assert "env_set dry-run creates nothing" test ! -e "$tmp/home/.config/dev/env2"

echo "passed $PASS, failed $FAIL"
[[ $FAIL -eq 0 ]]
