#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/board-test-helpers.sh"
source "$DIR/../dev-board-state.sh"

# attention_from_pane <pane-text>
assert_eq "$(attention_from_pane 'esc to interrupt · ✳ Thinking (40s)')" "working" "thinking = working"
assert_eq "$(attention_from_pane 'Do you want to proceed? 1. Yes 2. No')"  "blocked" "prompt = blocked"
assert_eq "$(attention_from_pane '$ ')"                                    "idle"    "shell = idle"
finish
