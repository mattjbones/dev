#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/board-test-helpers.sh"

FIX="$(mktemp -d)"; trap 'rm -rf "$FIX"' EXIT
# Fake cmux that logs its argv, one call per line.
cat > "$FIX/cmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CMUX_LOG"
SH
chmod +x "$FIX/cmux"
export CMUX_LOG="$FIX/log"
run() { PATH="$FIX:$PATH" "$DIR/../dev-cmux-resume.sh" "$@"; }

# no surface id -> no-op, exit 0
: > "$CMUX_LOG"
CMUX_SURFACE_ID= run fixer; assert_eq "$?" "0" "no surface: exit 0"
assert_eq "$(wc -l < "$CMUX_LOG" | tr -d ' ')" "0" "no surface: cmux not called"

# with surface id -> binding set with argv `dev <session>`
: > "$CMUX_LOG"
CMUX_SURFACE_ID=S1 CMUX_WORKSPACE_ID=W1 run fixer
assert_eq "$(cat "$CMUX_LOG")" \
  "surface resume set --workspace W1 --surface S1 --kind tmux --name dev fixer --cwd $HOME/workspace -- dev fixer" \
  "binding argv (default model omitted)"

# explicit model is carried so the rebuilt session matches
: > "$CMUX_LOG"
CMUX_SURFACE_ID=S1 CMUX_WORKSPACE_ID=W1 run fixer --model claude
assert_eq "$(cat "$CMUX_LOG")" \
  "surface resume set --workspace W1 --surface S1 --kind tmux --name dev fixer --cwd $HOME/workspace -- dev fixer --model claude" \
  "binding argv with model"

# cmux missing entirely -> exit 0, nothing happens
CMUX_SURFACE_ID=S1 PATH="/usr/bin:/bin" "$DIR/../dev-cmux-resume.sh" fixer; assert_eq "$?" "0" "no cmux: exit 0"

finish
