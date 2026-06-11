# Global preferences

## Superpowers doc locations

The `superpowers:brainstorming` and `superpowers:writing-plans` skills note that user
preferences override their default doc locations. They do. Use these instead:

- **Specs / design docs** → `~/Library/CloudStorage/OneDrive-LupaPetsLtd/docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md`
- **Plans** → `~/Library/CloudStorage/OneDrive-LupaPetsLtd/docs/superpowers/plans/YYYY-MM-DD-<feature-name>.md`

This keeps them in OneDrive so they sync to my other machines and I can edit them in Obsidian.

**Do NOT commit specs/plans into the project repo.** They live only in OneDrive. Skip the
brainstorming skill's "commit the spec" step — write the file, report the path, and stop.

**Archiving:** move a spec/plan into the `archive/` subfolder of its directory
(`specs/archive/`, `plans/archive/`) only once the work it describes has shipped —
implementation complete and merged. A finished document is not finished work: a spec
whose implementation hasn't happened yet stays in the active folder. If unsure whether
something shipped, check the repo (or ask) before archiving. When looking for past
specs/plans, check `archive/` too.
