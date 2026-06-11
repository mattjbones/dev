# dev

Dotfiles, tooling, and the Mac bootstrap for a factory-reset machine.

## Bootstrap

```sh
git clone https://github.com/mattjbones/dev ~/workspace/dev
cd ~/workspace/dev && ./bootstrap.sh
```

Idempotent — re-running converges and never clobbers. Flags:

| Flag | Effect |
| --- | --- |
| `--tier 1\|2\|3` | stop after a tier (1 = install + shell, 2 = apps + secrets, 3 = full) |
| `--only PHASE` | run a single phase, e.g. `--only dotfiles` |
| `--dry-run` | print the plan, touch nothing |
| `--yes` | skip confirm gates |
| `--force` | re-pull/re-render even when dest exists |
| `--no-backup` | overwrite conflicting real files instead of backing up to `.bak` |

**All tiers implemented** (Xcode CLT, Homebrew + Brewfile, shell framework,
node via nvm/corepack, dotfile symlinks, Bitwarden-driven secrets,
Zed/cmux/Raycast configs, macOS defaults). The defaults
list lives in `macos/defaults.sh` (one commented line per setting); the
phase applies only diffs and restarts Dock/Finder only when something
actually changed.

## Layout

- `bootstrap.sh` — orchestrator; sources `phases/*.sh` in order
- `lib/common.sh` — shared helpers (logging, gates, backup-then-link)
- `home/` — mirrors `$HOME`; every file here is symlinked into place by the dotfiles phase
- `tests/` — plain-bash tests; run `bash tests/<name>_test.sh`
- `agent-mux/`, `linear-dash`, `scripts/` — standalone tooling (unchanged)

## Secrets (Tier 2)

Pulled from Bitwarden at apply time by `phases/30-secrets.sh`, driven by
`secrets/manifest.tsv`. No secret value ever enters the repo. Prerequisite:
install the Bitwarden GUI app and sign in (root of trust), then the script
drives the `bw` CLI (unlock prompt during the run).

Vault convention — items the manifest expects:

| Item | Type | Holds |
| --- | --- | --- |
| `ssh-personal` | attachments | `id_ed25519`, `id_ed25519.pub` |
| `gpg-personal` | attachment | `private.asc` (GPG private key export) |
| `cmux` | custom field | `socketPassword` |
| `raycast` | attachment | `raycast.rayconfig` (settings export) |
| `datadog` | custom fields | `DD_API_KEY`, `DD_SITE` |

Missing items warn and are skipped — create them and re-run (`--force` to
re-pull existing dests). Field values land in `~/.config/dev/env` (mode 600,
sourced by zshrc, never committed). AWS is via SSO (`ar` helper), not Bitwarden.

## One-time on an existing machine

cmux was originally a direct download; let Homebrew adopt it:

```sh
brew install --cask cmux --adopt
```

## After merging a change to `home/`

Run `./bootstrap.sh --only dotfiles` to (re)point the `$HOME` symlinks.
