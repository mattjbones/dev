#!/usr/bin/env bash
# Seed the Bitwarden vault with the skeleton items secrets/manifest.tsv
# expects, using REPLACE_ME placeholders to be filled in by hand (GUI or CLI).
# Free-tier friendly: secrets live in secure-note bodies and hidden custom
# fields — no attachments (those are a Premium feature).
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

SEED_MARK="Seeded by dev/scripts/seed-vault.sh"

bw sync >/dev/null

have_item() { bw get item "$1" >/dev/null 2>&1; }

# field <name> <value> — one hidden custom field as JSON
field() { jq -nc --arg n "$1" --arg v "$2" '{name: $n, value: $v, type: 1}'; }

seed() { # seed <name> <fields-json-array> <notes-text>
  local name=$1 fields=$2 notes=$3
  if have_item "$name"; then
    echo "✓ $name (exists, untouched)"
    return 0
  fi
  bw get template item \
    | jq --arg n "$name" --argjson f "$fields" --arg notes "$notes ($SEED_MARK — consumed by bootstrap.sh via secrets/manifest.tsv)" \
        '.type = 2 | .secureNote = {type: 0} | .login = null
         | .name = $n | .notes = $notes | .fields = $f' \
    | bw encode | bw create item >/dev/null
  echo "⟳ $name created"
}

# Remove the legacy attachment-era skeleton if it is ours (never a real item).
legacy_id="$(bw get item ssh-personal 2>/dev/null | jq -r --arg m "$SEED_MARK" 'select(.notes // "" | contains($m)) | .id')" || true
if [[ -n "${legacy_id:-}" ]]; then
  bw delete item "$legacy_id"
  echo "✓ removed legacy ssh-personal skeleton"
fi

seed ssh-id_ed25519 '[]' \
  "REPLACE_ME — replace this whole note with the SSH private key (plain text, including BEGIN/END lines)."
seed ssh-id_ed25519.pub '[]' \
  "REPLACE_ME — replace this whole note with the SSH public key line."
seed gpg-private '[]' \
  "REPLACE_ME — replace this whole note with an ASCII-armored GPG private key export: gpg --export-secret-keys --armor <key-id>"
seed raycast '[]' \
  "REPLACE_ME — replace this whole note with base64 of a Raycast settings export: base64 -i <export>.rayconfig | pbcopy"
seed cmux "[$(field socketPassword REPLACE_ME)]" \
  "Secret lives in the socketPassword hidden field; this note is informational."
seed datadog "[$(field DD_API_KEY REPLACE_ME),$(field DD_SITE datadoghq.eu)]" \
  "DD_API_KEY needs a real value; DD_SITE is prefilled. Fields only; this note is informational."

bw sync >/dev/null
echo "Done. Replace the REPLACE_ME values, then bootstrap.sh --only secrets can pull them."
