#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/devctl-test-helpers.sh"
DEVCTL_LIB=1 source "$DIR/../dev-ctl.sh"
assert_eq "$(norm_project 'ENG-8285')" "eng-8285" "name lowercases"
assert_eq "$(norm_project 'feat/foo bar')" "feat-foo-bar" "name maps non-[a-z0-9_-] to dashes"
assert_eq "$(norm_project 'a__b')" "a__b" "name keeps underscores"
assert_eq "$(norm_branch_project 'matt/eng-7443-automations')" "matt-eng-7443-automations" "branch maps slash"
assert_eq "$(norm_branch_project 'claude-slack-foo')" "foo" "branch strips claude-slack- prefix"
assert_eq "$(norm_branch_project 'a_b')" "a-b" "branch maps underscore to dash"
assert_eq "$(norm_project 'a  b')" "a--b" "name does not collapse repeated delimiters"
finish
