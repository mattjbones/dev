#!/usr/bin/env bash
# Reflect a ranked workspace list (JSON on stdin: [{key,tier}]) into cmux:
# ensure 6 header workspaces (unpinned), then order the full sequence
# (headers + real workspaces interleaved) via move-top + reorder-workspace.
set -euo pipefail

CMUX_BIN="${CMUX_BIN:-$(command -v cmux 2>/dev/null || echo /Applications/cmux.app/Contents/Resources/bin/cmux)}"
[ -x "$CMUX_BIN" ] || exit 0   # no cmux here -> no-op (e.g. another machine/headless)

# tier -> "title|color"
header_def() {
  case "$1" in
    1) echo "🔴 Act Now|Red" ;;
    2) echo "🟢 Ready to Merge|Green" ;;
    3) echo "🔵 Waiting for Review|Blue" ;;
    4) echo "🟠 Needs You|Orange" ;;
    5) echo "🟡 In Progress|Amber" ;;
    6) echo "⚪ Parked|Charcoal" ;;
  esac
}

# header_desc <tier> -> one-line explanation shown as the header's cmux description
header_desc() {
  case "$1" in
    1) echo "Urgent (P1) in Linear — drop everything" ;;
    2) echo "Approved — good to merge" ;;
    3) echo "Open PR awaiting review" ;;
    4) echo "Agent blocked — needs your input" ;;
    5) echo "Agent working, or mid-priority WIP" ;;
    6) echo "Low / no priority, idle" ;;
  esac
}

list_ws() { "$CMUX_BIN" list-workspaces 2>/dev/null; }

# ref of a header workspace whose title contains $1, else "". Handles the leading
# "* " that cmux puts on the selected workspace (so $1 isn't mistaken for the ref).
ref_for_title() {
  list_ws | awk -v t="$1" 'index($0, t) { print ($1 == "*") ? $2 : $1; exit }'
}

# header_label <tier> -> the text label without the leading glyph (e.g. "In Progress")
header_label() {
  local def title; def="$(header_def "$1")"; title="${def%%|*}"
  printf '%s' "${title#* }"
}

# ref_for_label <label> -> ref of an existing header workspace for this label (any glyph), else ""
ref_for_label() {
  list_ws | awk -v lbl="$1" '
    { ref = ($1 == "*") ? $2 : $1
      start = ($1 == "*") ? 3 : 2
      title = ""
      for (j = start; j <= NF; j++) title = title (title == "" ? "" : " ") $j
      # header rows are "<glyph> <Label>"; match the label as the trailing text
      if (title ~ ("(^| )" lbl "$")) { print ref; exit }
    }'
}

# Header refs stored as plain variables: HEADER_REF_1 .. HEADER_REF_6
header_ref_set() { eval "HEADER_REF_${1}=${2}"; }
header_ref_get() { eval "printf '%s' \"\${HEADER_REF_${1}:-}\""; }

# Ensure each header exists + is unpinned + colored. Populate HEADER_REF_N vars.
# Matches by stable text label so glyph/color changes rename in place (no orphans).
ensure_headers() {
  local tier def title color label ref
  for tier in 1 2 3 4 5 6; do
    def="$(header_def "$tier")"; title="${def%%|*}"; color="${def##*|}"
    label="$(header_label "$tier")"
    ref="$(ref_for_label "$label")"
    if [ -z "$ref" ]; then
      "$CMUX_BIN" new-workspace --name "$title" >/dev/null 2>&1 || true
      ref="$(ref_for_label "$label")"
    else
      # heal glyph/color drift in place (no orphaned duplicate)
      "$CMUX_BIN" workspace-action --workspace "$ref" --action rename --title "$title" >/dev/null 2>&1 || true
    fi
    [ -n "$ref" ] || continue
    "$CMUX_BIN" workspace-action --workspace "$ref" --action unpin >/dev/null 2>&1 || true
    "$CMUX_BIN" workspace-action --workspace "$ref" --action set-color --color "$color" >/dev/null 2>&1 || true
    "$CMUX_BIN" workspace-action --workspace "$ref" --action set-description --description "$(header_desc "$tier")" >/dev/null 2>&1 || true
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

  # Build the desired ordered ref sequence: header(tier) then that tier's workspaces.
  local seq="" t href i key wref
  for t in 1 2 3 4 5 6; do
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

  # Realize the order with move-top applied in REVERSE, so the first item ends on top.
  # We use ONLY move-top (reliable: moves to the top of the unpinned zone). The previous
  # `reorder --after` chain produced rotated orders. Unpin each item first so a leftover
  # pin can't float a workspace above its section (and break the ordering).
  local ref revseq=""
  for ref in $seq; do
    "$CMUX_BIN" workspace-action --workspace "$ref" --action unpin >/dev/null 2>&1 || true
    revseq="$ref${revseq:+ }$revseq"
  done
  for ref in $revseq; do
    "$CMUX_BIN" workspace-action --workspace "$ref" --action move-top >/dev/null 2>&1 || true
  done
}
main
