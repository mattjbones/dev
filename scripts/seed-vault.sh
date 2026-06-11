#!/usr/bin/env bash
# Seed the Bitwarden vault with the skeleton items secrets/manifest.tsv
# expects, using placeholder values to be replaced by hand (GUI or CLI).
# Idempotent: items that already exist are left untouched.
#
# Usage:
#   bw login                                  # once per machine
#   export BW_SESSION="$(bw unlock --raw)"
#   ./scripts/seed-vault.sh
#   bw lock
set -euo pipefail

command -v bw >/dev/null 2>&1 || { echo "bw CLI required (brew install bitwarden-cli)" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 1; }
if [[ -z "${BW_SESSION:-}" ]]; then
  # shellcheck disable=SC2016  # the $() is advice for the user, not for us
  echo 'BW_SESSION not set — run: export BW_SESSION="$(bw unlock --raw)"' >&2
  exit 1
fi

PLACEHOLDER="REPLACE_ME"
NOTE="Seeded by dev/scripts/seed-vault.sh — replace placeholder attachments/fields with real values. Consumed by bootstrap.sh (secrets/manifest.tsv)."

bw sync >/dev/null

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

have_item() { bw get item "$1" >/dev/null 2>&1; }

# create_item <name> <fields-json-array>  — secure note with hidden fields
create_item() {
  bw get template item \
    | jq --arg n "$1" --argjson f "$2" --arg notes "$NOTE" \
        '.type = 2 | .secureNote = {type: 0} | .login = null
         | .name = $n | .notes = $notes | .fields = $f' \
    | bw encode | bw create item | jq -r '.id'
}

# attach_placeholder <item-id> <filename>
attach_placeholder() {
  printf '%s — placeholder for %s\n' "$PLACEHOLDER" "$2" > "$tmp/$2"
  bw create attachment --file "$tmp/$2" --itemid "$1" >/dev/null
}

# field <name> <value> — one hidden custom field as JSON
field() { jq -nc --arg n "$1" --arg v "$2" '{name: $n, value: $v, type: 1}'; }

seed() { # seed <name> <fields-json-array> <attachment...>
  local name=$1 fields=$2 id
  shift 2
  if have_item "$name"; then
    echo "✓ $name (exists, untouched)"
    return 0
  fi
  id="$(create_item "$name" "$fields")"
  local a
  for a in "$@"; do attach_placeholder "$id" "$a"; done
  echo "⟳ $name created ($# attachment(s), fields: $(jq -r 'map(.name) | join(", ") // "none"' <<<"$fields"))"
}

seed ssh-personal '[]' id_ed25519 id_ed25519.pub
seed gpg-personal '[]' private.asc
seed cmux "[$(field socketPassword "$PLACEHOLDER")]"
seed raycast '[]' raycast.rayconfig
seed datadog "[$(field DD_API_KEY "$PLACEHOLDER"),$(field DD_SITE datadoghq.eu)]"

bw sync >/dev/null
echo "Done. Replace the ${PLACEHOLDER} values, then bootstrap can pull them."
