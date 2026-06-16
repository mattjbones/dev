#!/usr/bin/env bash
# Tiny assertion helpers for the board test scripts.
_tests_run=0; _tests_failed=0
pass() { _tests_run=$((_tests_run+1)); }
fail() { _tests_run=$((_tests_run+1)); _tests_failed=$((_tests_failed+1)); echo "FAIL: $1" >&2; }
assert_eq() { # actual expected msg
  if [ "$1" = "$2" ]; then pass; else fail "${3:-}: expected [$2] got [$1]"; fi
}
finish() {
  echo "ran $_tests_run, failed $_tests_failed"
  [ "$_tests_failed" -eq 0 ] || exit 1
}
