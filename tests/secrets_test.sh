#!/usr/bin/env bash
# Tests for the secrets phase, with bw/gpg stubbed on PATH. No real vault,
# keyring, or $HOME is touched. Run: bash tests/secrets_test.sh
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
stub="$tmp/stub"; mkdir -p "$stub"
export GPG_STATE="$tmp/gpg-state" GPG_LOG="$tmp/gpg-log"

cat > "$stub/bw" <<'EOF'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "login --check") exit 0 ;;
  "unlock --raw") echo fake-session ;;
  "get item")
    case $3 in
      ssh-personal) echo '{"id":"id-ssh","fields":[]}' ;;
      gpg-personal) echo '{"id":"id-gpg","fields":[]}' ;;
      cmux)         echo '{"id":"id-cmux","fields":[{"name":"socketPassword","value":"sekret-sock"}]}' ;;
      raycast)      echo '{"id":"id-ray","fields":[]}' ;;
      datadog)      echo '{"id":"id-dd","fields":[{"name":"DD_API_KEY","value":"dd-key-123"},{"name":"DD_SITE","value":"datadoghq.eu"}]}' ;;
      *) exit 1 ;;
    esac ;;
  "get attachment")
    src=$3; out=''
    shift 3
    while [[ $# -gt 0 ]]; do [[ $1 == --output ]] && out=$2; shift; done
    mkdir -p "$(dirname "$out")" && echo "fake-$src" > "$out" ;;
  lock*) exit 0 ;;
  *) exit 1 ;;
esac
EOF
cat > "$stub/gpg" <<'EOF'
#!/usr/bin/env bash
case $1 in
  --list-secret-keys) cat "$GPG_STATE" 2>/dev/null; exit 0 ;;
  --import) echo "imported" > "$GPG_STATE"; echo "$@" >> "$GPG_LOG" ;;
esac
EOF
chmod +x "$stub/bw" "$stub/gpg"
export PATH="$stub:$PATH"

out1=$(HOME="$tmp/home" ./bootstrap.sh --only secrets --yes 2>&1)
assert "ssh key written" test "$(cat "$tmp/home/.ssh/id_ed25519" 2>/dev/null)" = "fake-id_ed25519"
assert "ssh key mode 600" test "$(stat -f %Lp "$tmp/home/.ssh/id_ed25519")" = 600
assert "ssh pub mode 644" test "$(stat -f %Lp "$tmp/home/.ssh/id_ed25519.pub")" = 644
assert "env file has DD_API_KEY" grep -q "^export DD_API_KEY='dd-key-123'$" "$tmp/home/.config/dev/env"
assert "env file has DD_SITE" grep -q "^export DD_SITE='datadoghq.eu'$" "$tmp/home/.config/dev/env"
assert "env file mode 600" test "$(stat -f %Lp "$tmp/home/.config/dev/env")" = 600
assert "gpg key imported" grep -q -- '--import' "$GPG_LOG"
assert "no secret values in output" not_grep 'dd-key-123\|sekret-sock' "$out1"

out2=$(HOME="$tmp/home" ./bootstrap.sh --only secrets --yes 2>&1)
assert "second run skips ssh" not_grep 'wrote.*id_ed25519 ' "$out2"
assert "second run skips env" not_grep 'set DD_API_KEY' "$out2"
assert "second run skips gpg" not_grep 'imported GPG' "$out2"

out3=$(HOME="$tmp/home" ./bootstrap.sh --only secrets --yes --force 2>&1)
assert "--force re-pulls ssh" does_grep 'wrote.*id_ed25519' "$out3"

out4=$(HOME="$tmp/home" ./bootstrap.sh --only secrets --yes --dry-run 2>&1)
assert "dry-run lists pulls" does_grep 'dry-run.*id_ed25519' "$out4"

echo "passed $PASS, failed $FAIL"
[[ $FAIL -eq 0 ]]
