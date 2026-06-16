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
    echo "* workspace:1  eng-7443"
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

# --- header creation ---
assert_eq "$(grep -c 'new-workspace' "$LOG")" "4" "creates 4 headers"

# --- never pins anything; always unpins each header ---
assert_eq "$(grep -c 'action pin' "$LOG" || true)" "0" "never pins"
assert_eq "$(grep -c 'action unpin' "$LOG")" "4" "unpins each header"

# --- exactly one move-top ---
assert_eq "$(grep -c 'action move-top' "$LOG")" "1" "exactly one move-top"

# --- move-top targets the Act Now header (workspace:10, first header created) ---
if grep -q 'workspace-action --workspace workspace:10 --action move-top' "$LOG"; then
  pass
else
  fail "move-top targets Act Now header (workspace:10)"
fi

# --- selected workspace (eng-7443 = workspace:1) gets set-color Red ---
if grep -q 'workspace-action --workspace workspace:1 --action set-color --color Red' "$LOG"; then
  pass
else
  fail "tier-1 workspace (workspace:1) gets set-color Red"
fi

# --- tier-4 workspace (appt-moving = workspace:2) gets clear-color ---
if grep -q 'workspace-action --workspace workspace:2 --action clear-color' "$LOG"; then
  pass
else
  fail "tier-4 workspace (workspace:2) gets clear-color"
fi

# --- no literal * used in reorder calls ---
if grep -q 'reorder-workspace --workspace \* ' "$LOG"; then
  fail "reorder used literal * (selected-prefix bug)"
else
  pass
fi

# --- selected workspace reordered by real ref (workspace:1) ---
if grep -q 'reorder-workspace --workspace workspace:1 --after' "$LOG"; then
  pass
else
  fail "selected workspace reordered by real ref workspace:1, not *"
fi

# --- total reorder-workspace calls = total items - 1 = 6 - 1 = 5 ---
# 4 headers + 2 real workspaces = 6 items; first gets move-top, remaining 5 get reorder.
assert_eq "$(grep -c 'reorder-workspace' "$LOG")" "5" "5 reorder-workspace calls (6 items - 1)"

# --- no-op when CMUX_BIN is non-executable ---
(
  export CMUX_BIN="/nonexistent/cmux"
  result="$(printf '%s' "$RANKED" | bash "$DIR/../dev-board-cmux.sh"; echo "exit:$?")"
  if printf '%s' "$result" | grep -q 'exit:0'; then pass; else fail "no-op exit 0 when CMUX_BIN non-executable"; fi
)

finish
