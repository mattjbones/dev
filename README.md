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
- `agent-mux/` — tmux multi-worktree dev environment (`dev`, `dev ctl`,
  `dev sync` + cross-machine Claude chat resume) — see [its README](agent-mux/README.md)
- `linear-dash`, `scripts/` — standalone tooling (`dev-aws.sh` AWS SSO creds, `seed-vault.sh`)

## Secrets (Tier 2)

Pulled from Bitwarden at apply time by `phases/30-secrets.sh`, driven by
`secrets/manifest.tsv`. No secret value ever enters the repo. Prerequisite:
install the Bitwarden GUI app and sign in (root of trust), then the script
drives the `bw` CLI (unlock prompt during the run).

Vault convention — items the manifest expects. Free-tier friendly: secrets
live in secure-note *bodies* and hidden custom fields (attachments are a
Bitwarden Premium feature). `./scripts/seed-vault.sh` creates these as
REPLACE_ME skeletons:

| Item | Where the secret lives |
| --- | --- |
| `ssh-id_ed25519` | note body: SSH private key (plain text) |
| `ssh-id_ed25519.pub` | note body: SSH public key line |
| `gpg-private` | note body: ASCII-armored GPG export (`gpg --export-secret-keys --armor`) |
| `raycast` | note body: base64 of a settings export (`base64 -i <file>.rayconfig \| pbcopy`) |
| `cmux` | hidden field `socketPassword` |
| `datadog` | hidden fields `DD_API_KEY`, `DD_SITE` |

Missing items and untouched REPLACE_ME placeholders warn and are skipped —
fill them in and re-run (`--force` to re-pull existing dests). Field values
land in `~/.config/dev/env` (mode 600, sourced by zshrc, never committed).
AWS is via SSO (`ar` helper), not Bitwarden.

## One-time on an existing machine

cmux was originally a direct download; let Homebrew adopt it:

```sh
brew install --cask cmux --adopt
```

## After merging a change to `home/`

Run `./bootstrap.sh --only dotfiles` to (re)point the `$HOME` symlinks.
