#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/devctl-test-helpers.sh"
STUB="$(mktemp -d)"; trap 'rm -rf "$STUB"' EXIT
export GH_LOG="$STUB/gh.log"; : > "$GH_LOG"
cat > "$STUB/gh" <<'EOD'
#!/usr/bin/env bash
echo call >> "$GH_LOG"; echo '[{"headRefName":"x","state":"OPEN","number":1}]'
EOD
chmod +x "$STUB/gh"
export PATH="$STUB:$PATH"
export DEVCTL_PR_CACHE_FILE="$STUB/pr.json" DEVCTL_PR_CACHE_TTL=30 GITHUB_REPO="o/r"
DEVCTL_LIB=1 source "$DIR/../dev-ctl.sh"

load_pr_cache >/dev/null
load_pr_cache >/dev/null
assert_eq "$(wc -l < "$GH_LOG" | tr -d ' ')" "1" "second call within TTL is cached"
load_pr_cache force >/dev/null
assert_eq "$(wc -l < "$GH_LOG" | tr -d ' ')" "2" "force refresh re-invokes gh"
finish
