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
  "volume ls")
    # Simulate one fake volume id per orphan project (independent of which
    # project is currently being purged, like real `docker volume ls -q`)
    # so devctl_purge_project's volume-removal loop has real elements to
    # inspect and filter, not zero.
    printf '%s\n' vol-old-branch vol-dead-wt
    ;;
  "volume inspect")
    # Map a fake volume id ($3, before --format) back to its project name,
    # mirroring the same trick used in test-devctl-orphans.sh.
    v="$3"
    echo "${v#vol-}"
    ;;
  "images -q")
    # Simulate one fake image id per project label so devctl_purge_project's
    # image-removal loop has a real element to remove for the matching
    # orphan, not zero.
    for a in "$@"; do
      case "$a" in
        *label=com.docker.compose.project=*)
          echo "img-${a#*label=com.docker.compose.project=}" ;;
      esac
    done
    ;;
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

# dry-run removes nothing (container, volume, or image)
: > "$RM_LOG"
action_prune_docker true </dev/null >/dev/null 2>&1 || true
assert_eq "$(wc -l < "$RM_LOG" | tr -d ' ')" "0" "dry-run removes nothing"

# apply removes both orphans, across all three docker resource types
: > "$RM_LOG"
action_prune_docker false >/dev/null 2>&1 || true
grep -q "cid-old-branch" "$RM_LOG" && pass || fail "apply removes old-branch container"
grep -q "cid-dead-wt" "$RM_LOG" && pass || fail "apply removes dead-wt container"
grep -q "vol-old-branch" "$RM_LOG" && pass || fail "apply removes old-branch volume"
grep -q "vol-dead-wt" "$RM_LOG" && pass || fail "apply removes dead-wt volume"
grep -q "img-old-branch" "$RM_LOG" && pass || fail "apply removes old-branch image"
grep -q "img-dead-wt" "$RM_LOG" && pass || fail "apply removes dead-wt image"

# keepers excluded, across all three docker resource types
: > "$RM_LOG"
action_prune_docker false "$(printf 'dead-wt\n')" >/dev/null 2>&1 || true
grep -q "cid-dead-wt" "$RM_LOG" && fail "keeper container must be spared" || pass
grep -q "vol-dead-wt" "$RM_LOG" && fail "keeper volume must be spared" || pass
grep -q "img-dead-wt" "$RM_LOG" && fail "keeper image must be spared" || pass
grep -q "cid-old-branch" "$RM_LOG" && pass || fail "non-keeper container still removed"
grep -q "vol-old-branch" "$RM_LOG" && pass || fail "non-keeper volume still removed"
grep -q "img-old-branch" "$RM_LOG" && pass || fail "non-keeper image still removed"
finish
