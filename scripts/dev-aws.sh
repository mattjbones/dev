#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# dev-aws.sh — Refresh AWS SSO credentials and emit them as export lines
# =============================================================================
#
# Usage:
#   eval "$(dev-aws)"            Login + export creds for the 'dev' profile
#   eval "$(dev-aws <profile>)"  Same, for another profile
#
# All status output goes to stderr; stdout is exclusively the `export ...`
# lines from `aws configure export-credentials`, so it is safe to eval.
#
# The `ar` function in zshrc is a thin wrapper around this script.
#
# =============================================================================

profile="${1:-dev}"

echo "Refreshing AWS creds / env (profile: $profile)" >&2
aws sso login --profile "$profile" >&2
aws configure export-credentials --profile "$profile" --format env
