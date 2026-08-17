#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/devctl-test-helpers.sh"
STUB="$(mktemp -d)"; WT="$(mktemp -d)"; mkdir -p "$WT/docker"
: > "$WT/docker/docker-compose.dev.yml"
trap 'rm -rf "$STUB" "$WT"' EXIT
export DOWN_LOG="$STUB/down.log"
cat > "$STUB/docker" <<'EOD'
#!/usr/bin/env bash
if [ "$1" = "compose" ]; then echo "$*" >> "$DOWN_LOG"; fi
if [ "$1" = "ps" ]; then exit 0; fi
exit 0
EOD
chmod +x "$STUB/docker"
cat > "$STUB/git" <<'EOD'
#!/usr/bin/env bash
# rev-parse --abbrev-ref HEAD -> branch name for the fake worktree.
# Match "rev-parse" anywhere in argv, since real callers use `git -C <dir>
# rev-parse ...` (rev-parse at $3, not $1/$2).
for _a in "$@"; do
  if [ "$_a" = "rev-parse" ]; then echo "matt/eng-7443-x"; exit 0; fi
done
exit 0
EOD
chmod +x "$STUB/git"
export PATH="$STUB:$PATH"
export LUPA_REPO="$WT"
DEVCTL_LIB=1 source "$DIR/../dev-ctl.sh"

# stop mode: no --rmi
: > "$DOWN_LOG"
docker_down_for_workspace "eng-7443" "$WT" stop
assert_eq "$(grep -c -- '--rmi local' "$DOWN_LOG")" "0" "stop mode omits --rmi"

# purge mode: at least one down carries --rmi local
: > "$DOWN_LOG"
docker_down_for_workspace "eng-7443" "$WT" purge
[ "$(grep -c -- '--rmi local' "$DOWN_LOG")" -ge 1 ] && pass || fail "purge adds --rmi local"

# branch-derived project name is attempted
grep -q "matt-eng-7443-x" "$DOWN_LOG" && pass || fail "branch-derived project attempted"
finish
