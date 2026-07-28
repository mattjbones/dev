#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/devctl-test-helpers.sh"
STUB="$(mktemp -d)"; trap 'rm -rf "$STUB"' EXIT
export RM_LOG="$STUB/rm.log"; : > "$RM_LOG"
cat > "$STUB/docker" <<'EOD'
#!/usr/bin/env bash
sub="$1 $2"
case "$sub" in
  "volume rm"|"image rm"|"rm -f"|"container prune") echo "$*" >> "$RM_LOG" ;;
  "volume ls") : ;;  # no-op; orphan set injected via stub below
  "ps -a")
    # Simulate one fake container id per project label so devctl_purge_project
    # has something to remove for the orphan set injected below.
    for a in "$@"; do
      case "$a" in
        *label=com.docker.compose.project=*)
          echo "cid-${a#*label=com.docker.compose.project=}" ;;
      esac
    done
    ;;
esac
exit 0
EOD
chmod +x "$STUB/docker"
export PATH="$STUB:$PATH"
DEVCTL_LIB=1 source "$DIR/../dev-ctl.sh"
# Override orphan discovery for a deterministic set.
devctl_orphan_projects() { printf '%s\n' old-branch dead-wt; }

# dry-run removes nothing
: > "$RM_LOG"
action_prune_docker true >/dev/null 2>&1 || true
assert_eq "$(wc -l < "$RM_LOG" | tr -d ' ')" "0" "dry-run removes nothing"

# apply removes both orphans
: > "$RM_LOG"
action_prune_docker false >/dev/null 2>&1 || true
grep -q "old-branch" "$RM_LOG" && pass || fail "apply removes old-branch"
grep -q "dead-wt" "$RM_LOG" && pass || fail "apply removes dead-wt"

# keepers excluded
: > "$RM_LOG"
action_prune_docker false "$(printf 'dead-wt\n')" >/dev/null 2>&1 || true
grep -q "dead-wt" "$RM_LOG" && fail "keeper must be spared" || pass
grep -q "old-branch" "$RM_LOG" && pass || fail "non-keeper still removed"
finish
