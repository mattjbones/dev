#!/usr/bin/env bash
# Curated macOS defaults, captured from the live machine 2026-06-11.
# Each line: set_default <domain> <key> <type> <value> <restart-target|->
# Sourced by phases/50-macos.sh (which defines set_default).

set_default com.apple.dock autohide bool 1 Dock        # auto-hide the Dock
set_default com.apple.dock tilesize int 39 Dock        # icon size
set_default com.apple.dock magnification bool 1 Dock   # magnify on hover
set_default com.apple.dock largesize int 64 Dock       # magnified icon size
set_default NSGlobalDomain AppleInterfaceStyle string Dark -      # dark mode (applies at next login)
set_default NSGlobalDomain AppleAccentColor int 6 -               # accent colour (value 6 = pink)
set_default com.apple.AppleMultitouchTrackpad Clicking bool 1 -   # tap to click
