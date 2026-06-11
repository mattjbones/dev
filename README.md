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

Currently implemented: **Tier 1** (Xcode CLT, Homebrew + Brewfile, node via
nvm/corepack, dotfile symlinks). Tier 2 (Bitwarden-driven secrets, Zed/cmux/
Raycast configs) and Tier 3 (macOS defaults) are upcoming.

## Layout

- `bootstrap.sh` — orchestrator; sources `phases/*.sh` in order
- `lib/common.sh` — shared helpers (logging, gates, backup-then-link)
- `home/` — mirrors `$HOME`; every file here is symlinked into place by the dotfiles phase
- `tests/` — plain-bash tests; run `bash tests/<name>_test.sh`
- `agent-mux/`, `linear-dash`, `scripts/` — standalone tooling (unchanged)

## After merging a change to `home/`

Run `./bootstrap.sh --only dotfiles` to (re)point the `$HOME` symlinks.
