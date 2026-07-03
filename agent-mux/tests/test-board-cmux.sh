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
    # Faithful to real cmux: --name does NOT stick (the shell's terminal-title
    # escape clobbers it), and the ref is printed to stdout as "OK workspace:N".
    count=\$(wc -l < "$WS_FILE" 2>/dev/null || echo 0)
    ref="workspace:\$((count + 10))"
    echo "  \$ref  Terminal \$((count + 10))" >> "$WS_FILE"
    echo "OK \$ref"
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

# --- every created header is renamed so its name persists (--name is clobbered) ---
assert_eq "$(grep -c 'action rename' "$LOG")" "6" "renames each created header (name persistence)"

# --- ordering is one atomic reorder-workspaces --order call; no pin/unpin/move-top ---
assert_eq "$(grep -c 'action pin' "$LOG" || true)" "0" "never pins"
assert_eq "$(grep -c 'action unpin' "$LOG" || true)" "6" "unpins each header (6); atomic reorder adds none"
assert_eq "$(grep -c 'action move-top' "$LOG" || true)" "0" "atomic reorder: no move-top calls"

# --- no per-workspace coloring: clear-color count == 0 ---
assert_eq "$(grep -c 'action clear-color' "$LOG" || true)" "0" "no clear-color calls (no per-workspace coloring)"

# --- set-color calls are exactly 6 (one per header only) ---
assert_eq "$(grep -c 'action set-color' "$LOG")" "6" "exactly 6 set-color calls (headers only)"

# --- a description is set for each header (6 set-description calls) ---
assert_eq "$(grep -c 'set-description' "$LOG")" "6" "a description is set for each header"

# --- ordering is realized by exactly one atomic reorder-workspaces --order call ---
assert_eq "$(grep -c 'reorder-workspaces --order' "$LOG")" "1" "one atomic reorder-workspaces --order call"
ORDER_LINE="$(grep 'reorder-workspaces --order' "$LOG" | head -1)"

# --- the --order list uses real refs, never the literal selected-prefix * ---
if printf '%s' "$ORDER_LINE" | grep -q -- '--order [^ ]*\*'; then
  fail "reorder --order used literal * (selected-prefix bug)"
else
  pass
fi

# --- selected workspace (workspace:1) present in the order by real ref ---
if printf '%s' "$ORDER_LINE" | grep -q 'workspace:1'; then
  pass
else
  fail "selected workspace workspace:1 present in --order list"
fi

# --- Act Now header (workspace:10) leads the order ---
if printf '%s' "$ORDER_LINE" | grep -qE -- '--order workspace:10(,|$| )'; then
  pass
else
  fail "Act Now header (workspace:10) leads the --order list"
fi

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
    count=\$(wc -l < "$WS_FILE2" 2>/dev/null || echo 0)
    ref="workspace:\$((count + 10))"
    echo "  \$ref  Terminal \$((count + 10))" >> "$WS_FILE2"
    echo "OK \$ref"
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

# every header (5 created + 1 pre-existing) is renamed to its current full title,
# so created headers get a persistent name and pre-existing ones heal glyph drift.
assert_eq "$(grep -c 'action rename' "$LOG2")" "6" "renames all 6 headers (5 created + 1 healed)"

# -----------------------------------------------------------------------
# Test C: a short key that is a SUBSTRING of another workspace's title must
# not collide onto that workspace's ref. Two keys resolving to one ref put a
# duplicate in the --order list, which cmux rejects atomically (invalid_params:
# Duplicate workspace in order) -> the whole reflect silently no-ops.
# Regression: "review" was matching into "deploy-preview" (p-review).
# -----------------------------------------------------------------------
LOG3="$STUB/log3"; WS_FILE3="$STUB/workspaces3"
cat > "$STUB/cmux3" <<EOF3
#!/usr/bin/env bash
echo "\$*" >> "$LOG3"
case "\$1" in
  list-workspaces)
    # deploy-preview listed BEFORE review, so a substring matcher grabs it first.
    echo "  workspace:70  ✳︎ deploy-preview 5%"
    echo "  workspace:71  review"
    [ -f "$WS_FILE3" ] && cat "$WS_FILE3" || true
    ;;
  new-workspace)
    count=\$(wc -l < "$WS_FILE3" 2>/dev/null || echo 0)
    ref="workspace:\$((count + 80))"
    echo "  \$ref  Terminal \$((count + 80))" >> "$WS_FILE3"
    echo "OK \$ref"
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
    if [ -n "\$ws" ] && [ -n "\$new_title" ] && [ -f "$WS_FILE3" ]; then
      sed -i.bak "s|  \$ws  .*|  \$ws  \$new_title|" "$WS_FILE3" && rm -f "${WS_FILE3}.bak"
    fi
    ;;
esac
EOF3
chmod +x "$STUB/cmux3"

export CMUX_BIN="$STUB/cmux3"
RANKED_C='[{"key":"deploy-preview","tier":6},{"key":"review","tier":6}]'
printf '%s' "$RANKED_C" | "$DIR/../dev-board-cmux.sh"

ORDER_C="$(grep 'reorder-workspaces --order' "$LOG3" | head -1 | sed 's/.*--order //')"

# review resolves to its OWN ref (workspace:71), not deploy-preview's (workspace:70)
if printf '%s' "$ORDER_C" | tr ',' '\n' | grep -qx 'workspace:71'; then
  pass
else
  fail "review must map to its own ref workspace:71, not collide onto deploy-preview"
fi

# no ref appears twice in the --order list (a duplicate makes cmux reject the batch)
DUPES_C="$(printf '%s' "$ORDER_C" | tr ',' '\n' | sort | uniq -d | grep -c . || true)"
assert_eq "$DUPES_C" "0" "--order list has no duplicate refs"

# -----------------------------------------------------------------------
# --- no-op when CMUX_BIN is non-executable ---
# -----------------------------------------------------------------------
(
  export CMUX_BIN="/nonexistent/cmux"
  result="$(printf '%s' "$RANKED" | bash "$DIR/../dev-board-cmux.sh"; echo "exit:$?")"
  if printf '%s' "$result" | grep -q 'exit:0'; then pass; else fail "no-op exit 0 when CMUX_BIN non-executable"; fi
)

finish
