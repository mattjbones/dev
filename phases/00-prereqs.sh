#!/usr/bin/env bash
# Phase 00 — Xcode CLT, Homebrew, shell framework. Sourced by bootstrap.sh.

if xcode-select -p >/dev/null 2>&1; then
  ok "Xcode CLT present"
else
  apply "installing Xcode Command Line Tools (GUI prompt will appear)"
  run xcode-select --install
  if [[ "${DRY_RUN:-0}" != 1 ]]; then
    warn "re-run bootstrap once the CLT install finishes"
    exit 1
  fi
fi

if command -v brew >/dev/null 2>&1; then
  ok "Homebrew present"
else
  apply "installing Homebrew"
  if [[ "${DRY_RUN:-0}" == 1 ]]; then
    log "  (dry-run) run official Homebrew install script"
  else
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
fi

# Make brew visible to the rest of this run (fresh machine: not on PATH yet).
if [[ -x /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

# oh-my-zsh + powerlevel10k + zsh-autosuggestions — the shell framework zshrc
# expects; essential to the local env. Plain git clones, not the omz installer
# (it would rewrite ~/.zshrc, which is repo-managed).
if [[ -d "$HOME/.oh-my-zsh" ]]; then
  ok "oh-my-zsh present"
else
  apply "cloning oh-my-zsh"
  run git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git "$HOME/.oh-my-zsh"
fi
if [[ -d "$HOME/.oh-my-zsh/custom/themes/powerlevel10k" ]]; then
  ok "powerlevel10k present"
else
  apply "cloning powerlevel10k"
  run git clone --depth=1 https://github.com/romkatv/powerlevel10k.git \
    "$HOME/.oh-my-zsh/custom/themes/powerlevel10k"
fi
if [[ -d "$HOME/.oh-my-zsh/custom/plugins/zsh-autosuggestions" ]]; then
  ok "zsh-autosuggestions present"
else
  apply "cloning zsh-autosuggestions"
  run git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions.git \
    "$HOME/.oh-my-zsh/custom/plugins/zsh-autosuggestions"
fi
