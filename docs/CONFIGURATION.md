# Nyia Keeper Configuration Reference

This document is the single reference for Nyia Keeper's user configuration: how settings are stored,
the scope precedence, how to set them (CLI or by hand), and the convention that decides what is a
`nyia config` key versus a structural file.

## The `nyia config` system

User settings are **registered keys** managed by `nyia config`:

```
nyia config view [assistant]            # effective values + their source
nyia config get <key>
nyia config project [assistant] key=value   # write project scope
nyia config global  [assistant] key=value   # write global scope
```

### Registered keys (as of this audit)
| Short name | Internal name | Validation | Notes |
|---|---|---|---|
| `command_mode` | `NYIA_COMMAND_MODE` | `safe`\|`full` | dangerous-value confirm gate for `full` global |
| `rag_model` | `NYIA_RAG_MODEL` | model string | also settable in `<assistant>.conf` (see "already-both") |
| `team_dir` | `NYIA_TEAM_DIR` | path | |
| `marketplace_url` | `NYIA_MARKETPLACE_URL` | git URL | paired with `nyia marketplace` ops |
| `workspace_sync` | `NYIA_WORKSPACE_SYNC` | bool | also a `workspace.conf` directive (`sync_branches`, higher precedence) |
| `whatsup_enabled` | `NYIA_WHATSUP_ENABLED` | bool | |
| `whatsup_auto_read` | `NYIA_WHATSUP_AUTO_READ` | `kickoff` \| `never` | |
| `auto_branch` | `NYIA_AUTO_BRANCH` | bool | auto-create a timestamped work branch |
| `auth_profile` | `NYIA_AUTH_PROFILE` | profile-name slug | **global scope only**; selects the active profile — a separate account; content is inherited from your default unless the profile is a persona — see [Profiles](PROFILES.md). Also settable per-command with `--profile <name>` |

### Scope precedence (highest → lowest)
1. CLI flag / env
2. Project **private** — `.nyiakeeper/private/config/nyia.conf` *(hand-edit only)*
3. Project **global** — `.nyiakeeper/nyia.conf` *(written by `nyia config project`)*
4. Project **shared** — `.nyiakeeper/shared/config/nyia.conf` *(hand-edit only; committed downstream)*
5. Global + assistant — `~/.config/nyiakeeper/config/<assistant>.conf`
6. Global — `~/.config/nyiakeeper/config/nyia.conf` *(written by `nyia config global`)*
7. Team — `$NYIA_TEAM_DIR/config/nyia.conf` *(hand-edit only, untrusted)*

## Editing config by hand

`nyia config` writes plain shell-style lines using the **internal** key name:

```
# .nyiakeeper/nyia.conf  (project)  or  ~/.config/nyiakeeper/config/nyia.conf  (global)
NYIA_COMMAND_MODE="full"
```

> Both the dev (`bin/nyia`) and runtime (`dist/runtime/bin/nyia`) editions share one
> implementation of these config commands (`lib/config-commands.sh`, Plan 282), so
> `view` / `project` / `global` behave identically in both. `nyia config get` returns only
> infrastructure paths (`home`, `config`, `data`) — use `nyia config view` for key values.

These files are fully hand-editable and honored on read. **Caveats:**
- **Use the internal `NYIA_*` name**, not the short name. A line like `command_mode=full` is **silently
  ignored** (the safe parser only accepts allow-listed `NYIA_*` keys).
- The CLI writes only **project** and **global** scopes. **private / shared / team are hand-edit-only.**
- **Hand-edits skip validation.** `nyia config set` validates; editing the file by hand does not — an
  invalid value may be silently corrected (e.g. `command_mode` falls back to `safe`) or, for keys without
  resolver-side validation, used as-is. You own value-correctness when hand-editing.

## Secrets — never in trackable scopes
API keys are mostly stored as env-var **references**, not values: `API_KEY_ENV="GEMINI_API_KEY"` names the
variable, it does not hold the secret. The exception is `MISTRAL_API_KEY`, which `vibe.conf` invites as a
literal value. **Rule:** secret *values* must never be written to the **project / shared / team** scopes
(those are designed to be committed in downstream user projects). Keep secrets in the environment, the
global scope, or a private creds file.

## Convention: config key vs structural file vs subcommand
- **Single scalars / small enumerated values → `nyia config` keys** (discoverable via `nyia config view`,
  scoped, validated).
- **Large or append-managed collections that have their own CLI → structural files** (e.g.
  `exclusions.conf` via `nyia exclusions`). *Heuristic, not absolute:* `NYIA_PROTECTED_BRANCHES` is a
  comma-list living as a config scalar (union-merged across scopes) — a list is not automatically structural.
- **Subcommands do operations, not settings.** `marketplace_url` is a config key; `nyia marketplace` does
  `init`/`sync`. New domain features follow this shape (e.g. `git_history_cutoff` key + `nyia git-history`
  ops; `network_egress_policy` key + the egress firewall).

## "Already-both" settings (two sources, by design)
Some settings exist as a config key AND elsewhere, with a defined precedence:
- `workspace_sync` (key) ← overridden by the `workspace.conf` `sync_branches` directive.
- `rag_model` (key) ← a project `<assistant>.conf` `NYIA_RAG_MODEL` (precedence level 5) outranks
  `nyia config global rag_model` (level 6). This is the canonical two-source example.
