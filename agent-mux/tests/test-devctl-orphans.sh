#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/devctl-test-helpers.sh"
STUB="$(mktemp -d)"; trap 'rm -rf "$STUB"' EXIT
# git worktree list --porcelain: one live worktree "calendar" on branch matt/cal
cat > "$STUB/git" <<'EOD'
#!/usr/bin/env bash
# Match "worktree" "list" anywhere in argv (adjacent), since real callers use
# `git -C <dir> worktree list --porcelain` (worktree/list at $3/$4, not $1/$2).
args=("$@")
for i in "${!args[@]}"; do
  if [ "${args[$i]}" = "worktree" ] && [ "${args[$((i+1))]:-}" = "list" ]; then
    printf 'worktree /Users/x/workspace/calendar\nbranch refs/heads/matt/cal\n\n'
    exit 0
  fi
done
exit 0
EOD
chmod +x "$STUB/git"
# docker: volumes carry compose projects: calendar (live), old-branch (orphan), supabase_db_x (infra).
# image-only-old is an image-only orphan: no volume, no container — simulating
# a worktree torn down by the OLD teardown (`down --volumes`, no `--rmi`),
# where only a tagged compose image is left behind.
cat > "$STUB/docker" <<'EOD'
#!/usr/bin/env bash
case "$1 $2" in
  "volume ls") printf '%s\n' calendar old-branch supabase_db_x ;;
  "images --filter") printf '%s\n' img-image-only-old ;;
  "ps -a"|"ps ") : ;;
esac
# label inspection: map volume->project (name == project here). $3 is the
# volume name; real callers pass it before the --format flag, i.e.
# `docker volume inspect "$v" --format '...'` puts $v at $3, not $4.
if [ "$1" = "volume" ] && [ "$2" = "inspect" ]; then echo "$3"; fi
# image label inspection: map fake image id (img-<project>) -> project name,
# mirroring the volume-inspect trick above.
if [ "$1" = "image" ] && [ "$2" = "inspect" ]; then echo "${3#img-}"; fi
exit 0
EOD
chmod +x "$STUB/docker"
export PATH="$STUB:$PATH"; export LUPA_REPO="/Users/x/workspace/lupa"
DEVCTL_LIB=1 source "$DIR/../dev-ctl.sh"

live="$(devctl_live_projects)"
echo "$live" | grep -qx "calendar" && pass || fail "basename in live-set"
echo "$live" | grep -qx "matt-cal" && pass || fail "branch variant in live-set"

devctl_is_infra "supabase_db_x" && pass || fail "supabase is infra"
devctl_is_infra "calendar" && fail "calendar not infra" || pass

orphans="$(devctl_orphan_projects)"
echo "$orphans" | grep -qx "old-branch" && pass || fail "old-branch is orphan"
echo "$orphans" | grep -qx "image-only-old" && pass || fail "image-only orphan (no volume/container) is discovered via docker images"
echo "$orphans" | grep -qx "calendar" && fail "calendar must not be orphan" || pass
echo "$orphans" | grep -qx "supabase_db_x" && fail "infra must not be orphan" || pass

# Empty live-set (e.g. git worktree list broken) must refuse to compute
# orphans rather than inverting "when in doubt, KEEP" and treating every
# project on the machine as orphaned.
devctl_live_projects() { printf ''; }
if devctl_orphan_projects >"$STUB/empty-live-orphans" 2>/dev/null; then
  fail "empty live-set must not report success"
else
  pass
fi
[ ! -s "$STUB/empty-live-orphans" ] && pass || fail "empty live-set must yield zero orphans, not everything"
finish
