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
# preview_pane's tmux branch never touches git/docker/gh, so give it a fake
# inactive worktree (no live tmux session named "demo") to exercise the git
# calls the cache is meant to memoize.
export HOME="$STUB/home"
mkdir -p "$HOME/workspace/demo"
DEVCTL_LIB=1 source "$DIR/../dev-ctl.sh"
preview_pane "demo" >/dev/null 2>&1 || true
n1="$(wc -l < "$WORK_LOG" | tr -d ' ')"
preview_pane "demo" >/dev/null 2>&1 || true
n2="$(wc -l < "$WORK_LOG" | tr -d ' ')"
[ "$n2" -eq "$n1" ] && pass || fail "second preview of same session hits cache (no new forks)"
finish
