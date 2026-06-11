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

# env_set <var> <value> <dest> — maintain one `export VAR='value'` line per
# var in dest (mode 600). How secret-paired shell env reaches the shell:
# dest is sourced by zshrc and never committed.
env_set() {
  local var=$1 value=$2 dest=$3 tmp
  if [[ "${DRY_RUN:-0}" == 1 ]]; then
    log "  (dry-run) set $var in $dest"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  tmp="$(mktemp)"
  if [[ -f "$dest" ]]; then grep -v "^export $var=" "$dest" > "$tmp" || true; fi
  printf "export %s='%s'\n" "$var" "${value//\'/\'\\\'\'}" >> "$tmp"
  install -m 600 "$tmp" "$dest"
  rm -f "$tmp"
  apply "set $var in $dest"
}

# Bitwarden — GUI sign-in is the manual root of trust; the CLI is what we drive.
bw_ensure_unlocked() {
  command -v bw >/dev/null 2>&1 || { warn "bw CLI missing — run the brew phase first"; return 1; }
  bw login --check >/dev/null 2>&1 || bw login
  BW_SESSION="$(bw unlock --raw)"
  [[ -n "$BW_SESSION" ]] || return 1
  export BW_SESSION
}
bw_get_field() { bw get item "$1" 2>/dev/null | jq -r --arg n "$2" '.fields[]? | select(.name == $n) | .value'; }
bw_get_notes() { bw get item "$1" 2>/dev/null | jq -r '.notes // empty'; }
