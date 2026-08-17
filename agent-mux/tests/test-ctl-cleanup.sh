#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/board-test-helpers.sh"

# action_cleanup (ctrl-d teardown) kills the tmux session that runs the pill-owning
# poller (dev-tmux-title.sh), so it must itself clear the cmux sidebar pills — else the
# poller's last-set pill (📖 storybook / 🐳 docker / gauge) freezes onto the orphaned row.
# The workspace id lives in the tmux session env and is gone once the session is killed,
# so cleanup MUST capture it BEFORE the kill. The tmux stub below enforces that ordering:
# show-environment returns the id only while the "killed" marker is absent.

STUB="$(mktemp -d)"; CMUX_LOG="$STUB/cmux-log"; KILLED="$STUB/killed"
export DEV_CTL_TEST_WS_ID="workspace:42"
trap 'rm -rf "$STUB"' EXIT

cat > "$STUB/tmux" <<EOF
#!/usr/bin/env bash
case "\$1" in
  has-session)        exit 0 ;;
  kill-session)       : > "$KILLED"; exit 0 ;;
  show-environment)
    # CMUX_WORKSPACE_ID is only resolvable while the session is alive.
    [ -f "$KILLED" ] && exit 0
    echo "CMUX_WORKSPACE_ID=$DEV_CTL_TEST_WS_ID"
    ;;
  *) exit 0 ;;
esac
EOF

# docker / git: no-ops so teardown of the fake workspace touches nothing real.
for tool in docker git; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/$tool"
done

# cmux: record every invocation so we can assert the pill clears fired.
cat > "$STUB/cmux" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CMUX_LOG"
exit 0
EOF

chmod +x "$STUB"/tmux "$STUB"/docker "$STUB"/git "$STUB"/cmux
export PATH="$STUB:$PATH"

# Fake, non-existent workspace name -> resolve_workspace_worktree finds no worktree,
# so teardown runs without touching the real repo/filesystem.
WS="test-cleanup-fixture-xyz-$$"
"$DIR/../dev-ctl.sh" __cleanup "$WS" >/dev/null 2>&1 || true

LOG="$(cat "$CMUX_LOG" 2>/dev/null || true)"

assert_eq "$(grep -c 'clear-status build'   <<<"$LOG" || true)" "1" "clears build pill on teardown"
assert_eq "$(grep -c 'clear-status agent'   <<<"$LOG" || true)" "1" "clears agent pill on teardown"
assert_eq "$(grep -c 'clear-status context' <<<"$LOG" || true)" "1" "clears context pill on teardown"
assert_eq "$(grep -c 'clear-progress'       <<<"$LOG" || true)" "1" "clears progress gauge on teardown"
# Ordering guarantee: the id captured pre-kill must be the one passed to cmux.
assert_eq "$(grep -c "$DEV_CTL_TEST_WS_ID" <<<"$LOG" || true)" "4" "targets the pre-kill workspace id"

finish
