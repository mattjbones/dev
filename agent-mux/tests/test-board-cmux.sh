#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/board-test-helpers.sh"

STUB="$(mktemp -d)"; LOG="$STUB/log"; WS_FILE="$STUB/workspaces"
trap 'rm -rf "$STUB"' EXIT

# Stub cmux: tracks created workspaces so list-workspaces reflects them.
# Variables are expanded at write-time so the stub knows its own paths.
cat > "$STUB/cmux" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$LOG"
case "\$1" in
  list-workspaces)
    echo "  workspace:1  eng-7443"
    echo "  workspace:2  appt-moving"
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
export PATH="$STUB:$PATH" CMUX_BIN="$STUB/cmux"

# ranked records: one tier-1, one tier-4
RANKED='[{"key":"eng-7443","tier":1},{"key":"appt-moving","tier":4}]'
printf '%s' "$RANKED" | "$DIR/../dev-board-cmux.sh"

# Headers must have been created (4 new-workspace calls for the titles).
assert_eq "$(grep -c 'new-workspace' "$LOG")" "4" "creates 4 headers"
# Reorder calls issued for the two real workspaces.
assert_eq "$(grep -c 'reorder-workspace' "$LOG")" "2" "reorders real workspaces"
finish
