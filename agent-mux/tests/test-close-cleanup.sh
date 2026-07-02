#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/board-test-helpers.sh"
STUB="$(mktemp -d)"; LOG="$STUB/log"
trap 'rm -rf "$STUB"' EXIT

# Stub docker: echoes a project for a known working_dir filter, nothing otherwise.
cat > "$STUB/docker" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$LOG"
# emulate: docker ps --filter label=...working_dir=<wt>/docker --filter status=running --format ...
if printf '%s' "\$*" | grep -q 'working_dir=/wt/eng-7925-3/docker'; then
  echo "matt-eng-7925-2-batches-at-conversion"
fi
EOF
chmod +x "$STUB/docker"
export PATH="$STUB:$PATH"
source "$DIR/../dev-close-cleanup.sh"

assert_eq "$(dc_project_for_worktree /wt/eng-7925-3)" "matt-eng-7925-2-batches-at-conversion" "discovers branch-named project"
assert_eq "$(dc_project_for_worktree /wt/nothing-running)" "" "empty when no containers"

export DEV_STATE_DIR="$STUB/state"
mkdir -p "$DEV_STATE_DIR/workspace-map"
echo "/Users/me/workspace/eng-7903" > "$DEV_STATE_DIR/workspace-map/UUID-ABC"
assert_eq "$(dc_worktree_for_uuid UUID-ABC)" "/Users/me/workspace/eng-7903" "registry hit"
assert_eq "$(dc_worktree_for_uuid UUID-MISSING)" "" "registry miss → empty"
finish
