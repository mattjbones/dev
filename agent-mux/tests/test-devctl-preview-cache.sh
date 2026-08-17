#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/devctl-test-helpers.sh"
STUB="$(mktemp -d)"; trap 'rm -rf "$STUB"' EXIT
export WORK_LOG="$STUB/work.log"; : > "$WORK_LOG"
for bin in git docker gh; do
  cat > "$STUB/$bin" <<EOD
#!/usr/bin/env bash
echo "$bin" >> "$WORK_LOG"; exit 0
EOD
  chmod +x "$STUB/$bin"
done
export PATH="$STUB:$PATH"
export DEVCTL_PREVIEW_DIR="$STUB/preview"
# Shrink the TTL so the test doesn't need a real-time sleep; we age the cache
# file's mtime past it below instead.
export DEVCTL_PREVIEW_TTL=1
# preview_pane's tmux branch never touches git/docker/gh, so give it a fake
# inactive worktree (no live tmux session named "demo") to exercise the git
# calls the cache is meant to memoize. This is also the branch that must
# eventually re-fork on its own, since dev-tmux-title.sh's state-sig file for
# this session dies with the (never-live, in this test) tmux session and so
# never changes to invalidate a sig-keyed cache.
export HOME="$STUB/home"
mkdir -p "$HOME/workspace/demo"
DEVCTL_LIB=1 source "$DIR/../dev-ctl.sh"
preview_pane "demo" >/dev/null 2>&1 || true
n1="$(wc -l < "$WORK_LOG" | tr -d ' ')"
preview_pane "demo" >/dev/null 2>&1 || true
n2="$(wc -l < "$WORK_LOG" | tr -d ' ')"
[ "$n2" -eq "$n1" ] && pass || fail "second preview of same session hits cache (no new forks)"

# Age the cache file past DEVCTL_PREVIEW_TTL (mtime rewind, not a real sleep) and
# confirm a third call re-forks instead of serving the cache forever — this is the
# bug the TTL exists to fix: the state-sig this used to key on never changes once
# the worktree is inactive, so without a TTL this call would hit the cache forever.
cache_file="$DEVCTL_PREVIEW_DIR/demo.preview"
[ -f "$cache_file" ] && pass || fail "expected preview cache file at $cache_file"
touch -t "$(date -v-2S +%Y%m%d%H%M.%S)" "$cache_file"
preview_pane "demo" >/dev/null 2>&1 || true
n3="$(wc -l < "$WORK_LOG" | tr -d ' ')"
[ "$n3" -gt "$n2" ] && pass || fail "third preview after TTL expiry re-forks (cache doesn't serve stale content forever)"
finish
