#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/devctl-test-helpers.sh"
STUB="$(mktemp -d)"; trap 'rm -rf "$STUB"' EXIT
export MERGED_LOG="$STUB/merged.log"; : > "$MERGED_LOG"
cat > "$STUB/git" <<'EOD'
#!/usr/bin/env bash
if [ "$*" = *"branch --merged"* ] || [ "$*" = *"branch -r --merged"* ]; then echo call >> "$MERGED_LOG"; fi
case "$*" in *"branch --merged"*|*"branch -r --merged"*) echo call >> "$MERGED_LOG";; esac
exit 0
EOD
chmod +x "$STUB/git"
export PATH="$STUB:$PATH"; export LUPA_REPO="/tmp/x"
export DEV_CTL_PR_CACHE='[{"headRefName":"a","state":"OPEN","number":1},{"headRefName":"a","state":"MERGED","number":2}]'
DEVCTL_LIB=1 source "$DIR/../dev-ctl.sh"

devctl_build_render_lookups
# summarise 5 branches — must NOT invoke git branch --merged again
for b in a b c d e; do pr_merge_summary_for_branch "$b" >/dev/null; done
# exactly 2 merged calls total (both from build step), 0 during per-row lookups
[ "$(wc -l < "$MERGED_LOG" | tr -d ' ')" -le 2 ] && pass || fail "merged-set computed once, not per row"
# PR map picks the highest-numbered PR for a branch
assert_eq "$(pr_merge_summary_for_branch a)" "MERGED #2" "PR map picks latest PR by number"
finish
