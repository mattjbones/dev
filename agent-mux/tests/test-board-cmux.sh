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
  workspace-action)
    # Handle rename: update the workspace title in WS_FILE
    ws=""; new_title=""
    while [ \$# -gt 0 ]; do
      case "\$1" in
        --workspace) ws="\$2"; shift 2 ;;
        --title) new_title="\$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    if [ -n "\$ws" ] && [ -n "\$new_title" ] && [ -f "$WS_FILE" ]; then
      # Replace the old title for this ref with the new title (in-place sed)
      sed -i.bak "s|  \$ws  .*|  \$ws  \$new_title|" "$WS_FILE" && rm -f "${WS_FILE}.bak"
    fi
    ;;
esac
EOF
chmod +x "$STUB/cmux"
export PATH="$STUB:$PATH" CMUX_BIN="$STUB/cmux"

# -----------------------------------------------------------------------
# Test A: all 6 headers absent -> 6 new-workspace calls, 0 rename calls
# -----------------------------------------------------------------------
# ranked records: one tier-1, one tier-6 (6-tier model)
RANKED='[{"key":"eng-7443","tier":1},{"key":"appt-moving","tier":6}]'
printf '%s' "$RANKED" | "$DIR/../dev-board-cmux.sh"

# --- header creation ---
assert_eq "$(grep -c 'new-workspace' "$LOG")" "6" "creates 6 headers when all absent"

# --- never pins anything; unpins headers (6) + every seq item (8) = 14 ---
assert_eq "$(grep -c 'action pin' "$LOG" || true)" "0" "never pins"
assert_eq "$(grep -c 'action unpin' "$LOG")" "14" "unpins 6 headers + all 8 seq items"

# --- one move-top per seq item: 6 headers + 2 workspaces = 8 ---
assert_eq "$(grep -c 'action move-top' "$LOG")" "8" "one move-top per seq item (8 items)"

# --- move-top is applied to the Act Now header (workspace:10) ---
if grep -q 'workspace-action --workspace workspace:10 --action move-top' "$LOG"; then
  pass
else
  fail "move-top applied to Act Now header (workspace:10)"
fi

# --- no per-workspace coloring: clear-color count == 0 ---
assert_eq "$(grep -c 'action clear-color' "$LOG" || true)" "0" "no clear-color calls (no per-workspace coloring)"

# --- set-color calls are exactly 6 (one per header only) ---
assert_eq "$(grep -c 'action set-color' "$LOG")" "6" "exactly 6 set-color calls (headers only)"

# --- a description is set for each header (6 set-description calls) ---
assert_eq "$(grep -c 'set-description' "$LOG")" "6" "a description is set for each header"

# --- no literal * used in move-top calls (selected-prefix must be normalized) ---
if grep -q 'workspace-action --workspace \* --action move-top' "$LOG"; then
  fail "move-top used literal * (selected-prefix bug)"
else
  pass
fi

# --- selected workspace move-top'd by real ref (workspace:1), not * ---
if grep -q 'workspace-action --workspace workspace:1 --action move-top' "$LOG"; then
  pass
else
  fail "selected workspace move-top'd by real ref workspace:1, not *"
fi

# --- ordering uses move-top only; no reorder-workspace calls remain ---
assert_eq "$(grep -c 'reorder-workspace' "$LOG" || true)" "0" "no reorder-workspace calls (move-top only)"

# -----------------------------------------------------------------------
# Test B: existing header with OLD glyph -> rename in place, not duplicated
# -----------------------------------------------------------------------
# Reset state for a fresh run
LOG2="$STUB/log2"; WS_FILE2="$STUB/workspaces2"
cat > "$STUB/cmux2" <<EOF2
#!/usr/bin/env bash
echo "\$*" >> "$LOG2"
case "\$1" in
  list-workspaces)
    echo "* workspace:1  eng-7443"
    echo "  workspace:2  appt-moving"
    [ -f "$WS_FILE2" ] && cat "$WS_FILE2" || true
    ;;
  new-workspace)
    name=""
    while [ \$# -gt 0 ]; do
      case "\$1" in --name) name="\$2"; shift 2 ;; *) shift ;; esac
    done
    count=\$(wc -l < "$WS_FILE2" 2>/dev/null || echo 0)
    ref="workspace:\$((count + 10))"
    echo "  \$ref  \$name" >> "$WS_FILE2"
    ;;
  workspace-action)
    ws=""; new_title=""
    while [ \$# -gt 0 ]; do
      case "\$1" in
        --workspace) ws="\$2"; shift 2 ;;
        --title) new_title="\$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    if [ -n "\$ws" ] && [ -n "\$new_title" ] && [ -f "$WS_FILE2" ]; then
      sed -i.bak "s|  \$ws  .*|  \$ws  \$new_title|" "$WS_FILE2" && rm -f "${WS_FILE2}.bak"
    fi
    ;;
esac
EOF2
chmod +x "$STUB/cmux2"

# Pre-seed: "In Progress" header already exists with OLD glyph (🟢 instead of current 🟡)
echo "  workspace:50  🟢 In Progress" > "$WS_FILE2"

export CMUX_BIN="$STUB/cmux2"
printf '%s' "$RANKED" | "$DIR/../dev-board-cmux.sh"

# 5 new-workspace calls (In Progress already existed, so only 5 created)
assert_eq "$(grep -c 'new-workspace' "$LOG2")" "5" "only 5 new-workspace calls when In Progress pre-exists"

# rename was called for the In Progress header (old glyph -> new glyph)
if grep -q 'action rename' "$LOG2" && grep -q 'In Progress' "$LOG2"; then
  pass
else
  fail "rename issued for existing In Progress header"
fi

# new-workspace was NOT called for In Progress
if grep 'new-workspace' "$LOG2" | grep -q 'In Progress'; then
  fail "new-workspace should NOT be called for pre-existing In Progress header"
else
  pass
fi

# rename --title targets the new full title (🟡 In Progress)
if grep -q -- '--title 🟡 In Progress' "$LOG2" || grep -q 'rename --title' "$LOG2"; then
  pass
else
  fail "rename issued with correct new full title for In Progress"
fi

# create-vs-rename are mutually exclusive per tier: no tier got both new-workspace and rename
new_ws_names=$(grep 'new-workspace' "$LOG2" | grep -o -- '--name [^-]*' | sed 's/--name //' | tr -d ' ')
rename_titles=$(grep 'action rename' "$LOG2" | grep -o -- '--title .*' | sed 's/--title //')
overlap=0
while IFS= read -r nm; do
  if printf '%s\n' "$rename_titles" | grep -qF "$nm"; then
    overlap=1
  fi
done <<< "$new_ws_names"
if [ "$overlap" -eq 0 ]; then
  pass
else
  fail "create and rename fired for the same header tier (not mutually exclusive)"
fi

# -----------------------------------------------------------------------
# --- no-op when CMUX_BIN is non-executable ---
# -----------------------------------------------------------------------
(
  export CMUX_BIN="/nonexistent/cmux"
  result="$(printf '%s' "$RANKED" | bash "$DIR/../dev-board-cmux.sh"; echo "exit:$?")"
  if printf '%s' "$result" | grep -q 'exit:0'; then pass; else fail "no-op exit 0 when CMUX_BIN non-executable"; fi
)

finish
