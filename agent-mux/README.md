# agent-mux

tmux-based multi-worktree dev environment for the lupa monorepo. One tmux
session per branch, each with three panes:

```
┌──────────────────────────┬─────────────┐
│                          │  📦 build   │
│  ✳︎ claude (agent)        ├─────────────┤
│                          │  ⬛ shell    │
└──────────────────────────┴─────────────┘
```

`dev` and `dev-ctl` are symlinked into `~/bin` (see the repo root README /
dotfiles phase), so everything below assumes they're on PATH.

## One-time machine setup

```sh
./dev-setup.sh
```

Installs Homebrew deps (tmux, dnsmasq), wildcard DNS
(`*.local.lupapets.com` → `127.0.0.1`), the Docker proxy network, and the
Traefik reverse proxy.

## Daily workflow — one session per branch

```sh
dev my-branch          # create or reattach
dev                    # no branch → main lupa checkout
dev -- ctl-like-name   # `--` guards branch names that look like commands
```

What `dev <branch>` does:

1. Finds or creates a git worktree for the branch — prefers git's registered
   path, then `~/workspace/<branch>`, then `lupa/.claude/worktrees/<branch>`;
   otherwise creates `~/workspace/<branch>` (new branches start from
   `origin/main` and track it).
2. Starts a background `pnpm install` if `monorepo/node_modules` is missing
   (the build pane waits on it via `dev-wait-pnpm.sh` before starting).
3. Builds the tmux session: agent pane running Claude (or codex), build pane
   (runs `docker/docker-start.sh` with `--docker`), and a plain shell.
4. Records the session in the OneDrive manifest (see *Multi-machine* below).

If the session already exists it just reattaches — `dev <branch>` is the
universal "take me to that workspace" command.

Flags: `--model claude|codex`, `--docker` / `--no-docker` (default off).
Env: `DEV_TMUX_NO_ATTACH=1` (create, don't attach), `DEV_SKIP_PNPM_INSTALL=1`,
`DEV_CLAUDE_SESSION_ID=<uuid>` (pin/resume a specific Claude chat — normally
set by `dev sync`, not by hand).

Inside the session — prefix is **Ctrl-a** (Ctrl-b is captured by Claude Code):

| Keys | Action |
| --- | --- |
| `Ctrl-a W` | dev-ctl command centre in a popup |
| `Ctrl-a m` | toggle mouse mode |
| mouse | click panes, drag borders (on by default) |

The Ghostty tab title and status line update every 15s with server status and
agent context usage (`dev-tmux-title.sh` + `dev-tmux-collect.sh`).

## `dev board` — urgency view

Ranks all workspaces by Linear priority × needs-my-action into four tiers
(🔴 Act Now / 🟠 Needs You / 🟢 In Progress / ⚪ Parked) and opens an fzf picker;
`enter` attaches to the selected workspace. Priority comes from Linear (via
`linear-dash --json`), review state from open PRs / Linear "In Review", and the
agent's attention (blocked / working / idle) from its pane. The cmux sidebar is
reordered under four pinned header workspaces, and the tmux title line shows a
tier badge. Data is cached in `/tmp/dev-board/cache.json` (TTL 180s), refreshed
on attach and on `dev board`; there is no background daemon. `dev board --refresh`
forces a refetch.

## Workspace management — `dev ctl`

Interactive fzf command centre over all workspaces (also `dev-ctl list`,
`dev-ctl new <branch>`, `dev-ctl verify-main` non-interactively):

| Keys | Action |
| --- | --- |
| `enter` | attach to session |
| `ctrl-n` | new workspace |
| `ctrl-s` | send free-text prompt to the Claude pane |
| `ctrl-p` | quick actions (sent to Claude, or `!devctl:*` run locally) |
| `ctrl-x` | stop docker, keep session |
| `ctrl-d` | full cleanup: docker down, kill session, remove worktree |
| `ctrl-r` | refresh list |

Quick actions live in `~/.config/dev-ctl/quick-actions.txt`.

## Multi-machine — `dev sync`

Session state syncs through OneDrive
(`docs/scripts/dev-sessions/`): each host writes its own manifest
(`<hostname>.json` — session, branch, model, Claude session id, active/inactive),
and Claude chat transcripts are copied to `transcripts/<uuid>.jsonl`. The tmux
layout itself is never synced — `dev <branch>` rebuilds it deterministically.

Typical flow, Air → MBP:

1. **Air:** work as normal. Transcripts push to OneDrive on every `dev`
   invocation and when a session closes. Before switching machines, close the
   session or run `dev-session-sync.sh push` to snapshot mid-chat.
2. **MBP:** `dev sync` — fzf picker of sessions active on other hosts
   (TAB to select some, ctrl-a for all, enter to restore). Each selected
   session gets its worktree, the standard tmux layout, and the Claude chat
   **resumed from the synced transcript**.
3. `dev <branch>` to attach.

Treat the chat as single-driver: if both machines advance the same chat, the
transcripts diverge and newest-wins on the next push/pull.

How chat resume works: `dev.sh` pins each agent pane to a generated session
uuid (`claude --session-id`). On relaunch/restore, `dev-tmux-agent-launch.sh`
resumes (`claude --resume`) if a transcript for that uuid exists locally —
`dev sync` pulls it into `~/.claude/projects/<munged-worktree>/` first. All
copies are newest-wins by mtime, so a chat that progressed further locally is
never clobbered.

`dev-session-sync.sh` subcommands (all no-ops without OneDrive):

| Command | What it does |
| --- | --- |
| `sync` | interactive restore picker (`dev sync`) |
| `list` | merged view of all hosts' sessions |
| `restore [--all\|<session>...]` | non-interactive restore |
| `push` | snapshot local transcripts to OneDrive now |
| `record` / `reconcile` | manifest upkeep — called by dev.sh, not by hand |

## Files

| File | Role |
| --- | --- |
| `dev.sh` | entry point: worktree + tmux session builder, `ctl`/`sync` dispatch |
| `dev-ctl.sh` | fzf command centre for managing workspaces |
| `dev-session-sync.sh` | OneDrive manifest + Claude transcript sync, restore picker |
| `dev-setup.sh` | one-time machine setup (DNS, docker network, traefik) |
| `dev-tmux-agent-launch.sh` | launches the agent pane; resumes Claude by session uuid |
| `dev-tmux-title.sh` | Ghostty tab title / status line updater (15s poll) |
| `dev-tmux-collect.sh` | gathers agent/server state as JSON for the title script |
| `dev-wait-pnpm.sh` | build pane gate: wait for background pnpm install |
