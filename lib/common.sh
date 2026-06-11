#!/usr/bin/env bash
# Shared helpers for bootstrap phases. Sourced, never executed.
# Honours env/flags set by bootstrap.sh: DRY_RUN, YES, NO_BACKUP.

if [[ -t 1 ]]; then
  _C_GREEN=$'\033[32m' _C_YELLOW=$'\033[33m' _C_BLUE=$'\033[34m' _C_RESET=$'\033[0m'
else
  _C_GREEN='' _C_YELLOW='' _C_BLUE='' _C_RESET=''
fi

log()   { printf '%s\n' "$*"; }
ok()    { printf '%s✓%s %s\n' "$_C_GREEN" "$_C_RESET" "$*"; }
apply() { printf '%s⟳%s %s\n' "$_C_BLUE" "$_C_RESET" "$*"; }
warn()  { printf '%s⚠%s %s\n' "$_C_YELLOW" "$_C_RESET" "$*"; }

# gate <question> — y/N confirm; auto-yes under --yes or --dry-run.
gate() {
  if [[ "${YES:-0}" == 1 || "${DRY_RUN:-0}" == 1 ]]; then return 0; fi
  local reply
  read -r -p "$1 [y/N] " reply
  [[ "$reply" == [yY]* ]]
}

# run <cmd...> — execute unless dry-run, in which case log the plan.
run() {
  if [[ "${DRY_RUN:-0}" == 1 ]]; then
    log "  (dry-run) $*"
    return 0
  fi
  "$@"
}

# backup_then_link <src> <dest>
# correct symlink -> skip · other symlink -> repoint · real file -> .bak (or
# overwrite under NO_BACKUP=1) -> link. Creates parent dirs.
backup_then_link() {
  local src=$1 dest=$2
  if [[ -L "$dest" && "$(readlink "$dest")" == "$src" ]]; then
    ok "$dest"
    return 0
  fi
  run mkdir -p "$(dirname "$dest")"
  if [[ -L "$dest" ]]; then
    apply "repointed $dest"
  elif [[ -e "$dest" ]]; then
    if [[ "${NO_BACKUP:-0}" == 1 ]]; then
      warn "overwrote $dest (--no-backup)"
    else
      warn "$dest existed — backed up to $dest.bak"
      run mv "$dest" "$dest.bak"
    fi
  else
    apply "linked $dest"
  fi
  run ln -sfn "$src" "$dest"
}
