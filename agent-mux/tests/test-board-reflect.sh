#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/board-test-helpers.sh"

STUB="$(mktemp -d)"; LOG="$STUB/log"; WS_FILE="$STUB/workspaces"
trap 'rm -rf "$STUB"' EXIT

# Stateful cmux stub: tracks created workspaces so list-workspaces reflects them.
# Mirrors the proven pattern from test-board-cmux.sh.
cat > "$STUB/cmux" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$LOG"
case "\$1" in
  list-workspaces)
    echo "  workspace:1  eng-7443"
    [ -f "$WS_FILE" ] && cat "$WS_FILE" || true
    ;;
  new-workspace)
    name=""
    while [ \$# -gt 0 ]; do
      case "\$1" in --name) name="\$2"; shift 2 ;; *) shift ;; esac
    done
    count=\$(wc -l < "$WS_FILE" 2>/dev/null || echo 0)
    ref="workspace:\$((count + 10))"
    echo "  \$ref  \$name" >> "$WS_FILE"
    ;;
esac
EOF
chmod +x "$STUB/cmux"

# linear-dash must NOT be called during --reflect (no network).
cat > "$STUB/linear-dash" <<'EOF'
#!/usr/bin/env bash
echo "NETWORK" >> "$STUB_NET_LOG"
echo '[]'
EOF
# We use an env var so the trap/expansion work correctly
export STUB_NET_LOG="$STUB/net.log"
# Rewrite with proper expansion
cat > "$STUB/linear-dash" <<EOF
#!/usr/bin/env bash
echo "NETWORK" >> "$STUB_NET_LOG"
echo '[]'
EOF
chmod +x "$STUB/linear-dash"

export PATH="$STUB:$PATH" CMUX_BIN="$STUB/cmux"

# A pre-populated cache with one workspace (priority/needsReview present, no tier — ranker assigns it).
mkdir -p "$STUB/cachedir"
export DEV_BOARD_CACHE="$STUB/cachedir/cache.json"
cat > "$DEV_BOARD_CACHE" <<'CACHE'
{"generatedAt":1,"workspaces":[{"key":"eng-7443","branch":"eng-7443","worktree":"/tmp/x","ticket":"ENG-7443","priority":2,"needsReview":true,"pr":null}]}
CACHE

# Run --reflect (must be local-only: no collector, no network).
"$DIR/../dev-board.sh" --reflect

# Assertion 1: linear-dash must NOT have been called.
assert_eq "$([ -f "$STUB/net.log" ] && echo called || echo no)" "no" "no network on --reflect"

# Assertion 2: cmux must have been driven (log is non-empty).
assert_eq "$([ -s "$LOG" ] && echo yes || echo no)" "yes" "cmux reflected"

finish
