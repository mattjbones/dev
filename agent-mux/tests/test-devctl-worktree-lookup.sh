#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/devctl-test-helpers.sh"
STUB="$(mktemp -d)"; trap 'rm -rf "$STUB"' EXIT

# Source first (with real PATH) so we learn the real LUPA_REPO the script
# assigns, before we start stubbing git/basename.
DEVCTL_LIB=1 source "$DIR/../dev-ctl.sh"
REPO="$LUPA_REPO"

export GIT_LOG="$STUB/git.log"; : > "$GIT_LOG"
export BASENAME_LOG="$STUB/basename.log"; : > "$BASENAME_LOG"

cat > "$STUB/porcelain.txt" <<EOF
worktree $REPO
HEAD abc123
branch refs/heads/main

worktree $REPO/.claude/worktrees/feature-a
HEAD def456
branch refs/heads/feature-a

worktree $REPO/.claude/worktrees/feature-b
HEAD ghi789
branch refs/heads/feature-b

worktree $REPO/.claude/worktrees/feature-c
HEAD jkl012
branch refs/heads/feature-c
EOF

cat > "$STUB/git" <<EOD
#!/usr/bin/env bash
echo "\$*" >> "$GIT_LOG"
case "\$*" in
  *"worktree list --porcelain"*) cat "$STUB/porcelain.txt" ;;
esac
exit 0
EOD
chmod +x "$STUB/git"

cat > "$STUB/basename" <<EOD
#!/usr/bin/env bash
echo call >> "$BASENAME_LOG"
p="\${1%/}"
printf '%s\n' "\${p##*/}"
EOD
chmod +x "$STUB/basename"

export PATH="$STUB:$PATH"

# Build the lookup ONCE.
devctl_build_worktree_lookup

git_calls_after_build="$(wc -l < "$GIT_LOG" | tr -d ' ')"
basename_calls_after_build="$(wc -l < "$BASENAME_LOG" | tr -d ' ')"

[ "$git_calls_after_build" -eq 1 ] && pass || fail "git worktree list forked exactly once during build (got $git_calls_after_build)"
[ "$basename_calls_after_build" -eq 3 ] && pass || fail "basename forked once per non-main worktree during build (expected 3, got $basename_calls_after_build)"

# Now look up several (repeated) names — this must NOT re-parse
# `git worktree list` or re-fork `basename` at all.
for n in feature-a feature-b feature-c missing-one feature-a feature-b; do
  find_worktree_path_by_name "$n" >/dev/null 2>&1 || true
done

git_calls_final="$(wc -l < "$GIT_LOG" | tr -d ' ')"
basename_calls_final="$(wc -l < "$BASENAME_LOG" | tr -d ' ')"

assert_eq "$git_calls_final" "$git_calls_after_build" "no additional git invocations during per-name lookups"
assert_eq "$basename_calls_final" "$basename_calls_after_build" "no additional basename invocations during per-name lookups"

assert_eq "$(find_worktree_path_by_name feature-a)" "$REPO/.claude/worktrees/feature-a" "lookup resolves feature-a via the map"
assert_eq "$(find_worktree_path_by_name feature-c)" "$REPO/.claude/worktrees/feature-c" "lookup resolves feature-c via the map"

if find_worktree_path_by_name missing-one >/dev/null 2>&1; then
  fail "missing worktree name should not resolve"
else
  pass
fi

finish
