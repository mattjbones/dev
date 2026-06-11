#!/usr/bin/env bash
# Mac bootstrap orchestrator — see README. Idempotent; re-running converges.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$REPO_ROOT/lib/common.sh"

usage() {
  cat <<'EOF'
usage: bootstrap.sh [flags]
  --tier 1|2|3   stop after a tier (default: 3)
  --only PHASE   run a single phase (substring match, e.g. "dotfiles")
  --dry-run      print the plan, touch nothing
  --yes          skip confirm gates (unattended runs)
  --force        re-pull/re-render even when dest exists
  --no-backup    don't back up conflicting real files before linking
EOF
}

TIER=3 ONLY='' DRY_RUN=0 YES=0 FORCE=0 NO_BACKUP=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --tier)      TIER=$2; shift 2 ;;
    --only)      ONLY=$2; shift 2 ;;
    --dry-run)   DRY_RUN=1; shift ;;
    --yes)       YES=1; shift ;;
    --force)     FORCE=1; shift ;;
    --no-backup) NO_BACKUP=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           echo "unknown flag: $1" >&2; usage >&2; exit 1 ;;
  esac
done
export REPO_ROOT TIER ONLY DRY_RUN YES FORCE NO_BACKUP

# Run-level temp shared by all phases (spec: secrets stage artifacts for apps).
BOOTSTRAP_TMP="$(mktemp -d -t dev-bootstrap)"
export BOOTSTRAP_TMP
trap 'rm -rf "$BOOTSTRAP_TMP"' EXIT

# Phase prefix -> tier: 00-29 tier 1, 30-49 tier 2, 50+ tier 3.
phase_tier() {
  local n=${1%%-*}
  if   (( 10#$n < 30 )); then echo 1
  elif (( 10#$n < 50 )); then echo 2
  else                        echo 3
  fi
}

phases=()
for f in "$REPO_ROOT"/phases/*.sh; do
  [[ -e "$f" ]] || continue
  name="$(basename "$f" .sh)"
  if [[ -n "$ONLY" ]]; then
    [[ "$name" == *"$ONLY"* ]] && phases+=("$f")
  elif (( $(phase_tier "$name") <= TIER )); then
    phases+=("$f")
  fi
done
if [[ ${#phases[@]} -eq 0 ]]; then
  warn "no phases matched (tier=$TIER only='$ONLY')"
  exit 1
fi

suffix=''
[[ $DRY_RUN == 1 ]] && suffix=' · DRY RUN'
log "dev bootstrap · macOS $(sw_vers -productVersion) · tier $TIER$suffix"
log ""
plan="$(basename -a "${phases[@]}" | sed 's/\.sh$//' | tr '\n' ' ')"
gate "This will run ${#phases[@]} phase(s): ${plan}. Proceed?" || { log "aborted"; exit 1; }

i=0
for f in "${phases[@]}"; do
  i=$((i + 1))
  log ""
  log "[$i/${#phases[@]}] $(basename "$f" .sh)"
  # shellcheck source=/dev/null
  source "$f"
done

log ""
ok "Bootstrap complete. See README for remaining manual steps."
