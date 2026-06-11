#!/usr/bin/env bash
# Tests for the prereqs phase's shell-framework clones, with git stubbed on
# PATH against a temp $HOME. Run: bash tests/prereqs_test.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PASS=0 FAIL=0
assert() {
  local desc=$1; shift
  if "$@"; then PASS=$((PASS + 1)); echo "  ok: $desc"
  else FAIL=$((FAIL + 1)); echo "  FAIL: $desc"; fi
}

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
stub="$tmp/stub"; mkdir -p "$stub"
export GIT_LOG="$tmp/git-log"

cat > "$stub/git" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "$GIT_LOG"
[[ $1 == clone ]] && mkdir -p "${@: -1}"
EOF
chmod +x "$stub/git"
export PATH="$stub:$PATH"

HOME="$tmp/home" ./bootstrap.sh --only prereqs --yes >/dev/null
assert "clones oh-my-zsh" grep -q 'ohmyzsh/ohmyzsh' "$GIT_LOG"
assert "clones powerlevel10k" grep -q 'romkatv/powerlevel10k' "$GIT_LOG"
assert "clones zsh-autosuggestions" grep -q 'zsh-users/zsh-autosuggestions' "$GIT_LOG"

HOME="$tmp/home" ./bootstrap.sh --only prereqs --yes >/dev/null
assert "second run skips clones (idempotent)" test "$(grep -c '^clone' "$GIT_LOG")" = 3

echo "passed $PASS, failed $FAIL"
[[ $FAIL -eq 0 ]]
