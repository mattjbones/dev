#!/usr/bin/env bash
# Reflect a ranked workspace list (JSON on stdin: [{key,tier}]) into cmux:
# ensure 4 header workspaces (unpinned), then order the full sequence
# (headers + real workspaces interleaved) via move-top + reorder-workspace.
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

# Ensure each header exists + is unpinned + colored. Populate HEADER_REF_N vars.
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
    "$CMUX_BIN" workspace-action --workspace "$ref" --action unpin >/dev/null 2>&1 || true
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

  # Color real workspaces by urgency: tier-1 Red, others cleared (no sticky red).
  local i key tier wref
  if [ "$n" -gt 0 ]; then
    for i in $(seq 0 $((n - 1))); do
      key="$(printf '%s' "$ranked" | jq -r ".[$i].key")"
      tier="$(printf '%s' "$ranked" | jq -r ".[$i].tier")"
      wref="$(ref_for_key "$key")"; [ -n "$wref" ] || continue
      if [ "$tier" = "1" ]; then
        "$CMUX_BIN" workspace-action --workspace "$wref" --action set-color --color Red >/dev/null 2>&1 || true
      else
        "$CMUX_BIN" workspace-action --workspace "$wref" --action clear-color >/dev/null 2>&1 || true
      fi
    done
  fi

  # Build the desired ordered ref sequence: header(tier) then that tier's workspaces.
  local seq="" t href
  for t in 1 2 3 4; do
    href="$(header_ref_get "$t")"
    [ -n "$href" ] && seq="$seq $href"
    if [ "$n" -gt 0 ]; then
      for i in $(seq 0 $((n - 1))); do
        [ "$(printf '%s' "$ranked" | jq -r ".[$i].tier")" = "$t" ] || continue
        key="$(printf '%s' "$ranked" | jq -r ".[$i].key")"
        wref="$(ref_for_key "$key")"; [ -n "$wref" ] && seq="$seq $wref"
      done
    fi
  done

  # Realize the order: first item to top, then chain each after the previous.
  local prev="" first=1 ref
  for ref in $seq; do
    if [ "$first" = "1" ]; then
      "$CMUX_BIN" workspace-action --workspace "$ref" --action move-top >/dev/null 2>&1 || true
      first=0
    else
      "$CMUX_BIN" reorder-workspace --workspace "$ref" --after "$prev" >/dev/null 2>&1 || true
    fi
    prev="$ref"
  done
}
main
