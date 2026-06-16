#!/usr/bin/env bash
# Reflect a ranked workspace list (JSON on stdin: [{key,tier}]) into cmux:
# ensure 4 pinned header workspaces, then reorder each real workspace under its tier header.
set -euo pipefail

CMUX_BIN="${CMUX_BIN:-$(command -v cmux 2>/dev/null || echo /Applications/cmux.app/Contents/Resources/bin/cmux)}"
[ -x "$CMUX_BIN" ] || exit 0   # no cmux here -> no-op (e.g. another machine/headless)

# tier -> "title|color"
header_def() {
  case "$1" in
    1) echo "🔴 Act Now|Red" ;;
    2) echo "🟠 Needs You|Amber" ;;
    3) echo "🟢 In Progress|Green" ;;
    4) echo "⚪ Parked|Charcoal" ;;
  esac
}

list_ws() { "$CMUX_BIN" list-workspaces 2>/dev/null; }

# ref of a header workspace whose title contains $1, else "". Handles the leading
# "* " that cmux puts on the selected workspace (so $1 isn't mistaken for the ref).
ref_for_title() {
  list_ws | awk -v t="$1" 'index($0, t) { print ($1 == "*") ? $2 : $1; exit }'
}

# Header refs stored as plain variables: HEADER_REF_1 .. HEADER_REF_4
header_ref_set() { eval "HEADER_REF_${1}=${2}"; }
header_ref_get() { eval "printf '%s' \"\${HEADER_REF_${1}:-}\""; }

# Ensure each header exists + is pinned + colored. Populate HEADER_REF_N vars.
ensure_headers() {
  local tier def title color ref
  for tier in 1 2 3 4; do
    def="$(header_def "$tier")"; title="${def%%|*}"; color="${def##*|}"
    ref="$(ref_for_title "$title")"
    if [ -z "$ref" ]; then
      "$CMUX_BIN" new-workspace --name "$title" >/dev/null 2>&1 || true
      ref="$(ref_for_title "$title")"
    fi
    [ -n "$ref" ] || continue
    "$CMUX_BIN" workspace-action --workspace "$ref" --action pin >/dev/null 2>&1 || true
    "$CMUX_BIN" workspace-action --workspace "$ref" --action set-color --color "$color" >/dev/null 2>&1 || true
    header_ref_set "$tier" "$ref"
  done
}

# ref of the real workspace whose TITLE (the columns after the ref) contains key $1.
# Normalizes the selected "* " prefix and never matches the ref token itself.
ref_for_key() {
  list_ws | awk -v k="$1" '
    { ref = ($1 == "*") ? $2 : $1
      start = ($1 == "*") ? 3 : 2
      title = ""
      for (j = start; j <= NF; j++) title = title (title == "" ? "" : " ") $j
      if (index(title, k)) { print ref; exit }
    }'
}

main() {
  local ranked; ranked="$(cat)"
  ensure_headers
  local n; n="$(printf '%s' "$ranked" | jq 'length')"
  [ "$n" -eq 0 ] && return 0
  local i key tier wref href
  for i in $(seq 0 $((n - 1))); do
    key="$(printf '%s' "$ranked" | jq -r ".[$i].key")"
    tier="$(printf '%s' "$ranked" | jq -r ".[$i].tier")"
    wref="$(ref_for_key "$key")"
    href="$(header_ref_get "$tier")"
    [ -n "$wref" ] && [ -n "$href" ] || continue
    "$CMUX_BIN" reorder-workspace --workspace "$wref" --after "$href" >/dev/null 2>&1 || true
    # Tier-1 real workspaces also go Red so the "act now" items pop, matching their header.
    [ "$tier" = "1" ] && "$CMUX_BIN" workspace-action --workspace "$wref" --action set-color --color Red >/dev/null 2>&1 || true
  done
}
main
