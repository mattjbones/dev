# Global preferences

## Superpowers doc locations

The `superpowers:brainstorming` and `superpowers:writing-plans` skills note that user
preferences override their default doc locations. They do. Use these instead:

- **Specs / design docs** → `~/Library/CloudStorage/OneDrive-LupaPetsLtd/docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md`
- **Plans** → `~/Library/CloudStorage/OneDrive-LupaPetsLtd/docs/superpowers/plans/YYYY-MM-DD-<feature-name>.md`

This keeps them in OneDrive so they sync to my other machines and I can edit them in Obsidian.

**Do NOT commit specs/plans into the project repo.** They live only in OneDrive. Skip the
brainstorming skill's "commit the spec" step — write the file, report the path, and stop.

**Archiving:** when a piece of work is complete, move its spec and plan into the `archive/`
subfolder of their respective directories (`specs/archive/`, `plans/archive/`). When looking
for past specs/plans, check `archive/` too.
