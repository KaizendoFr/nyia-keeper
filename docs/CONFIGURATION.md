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
| `team_dir` | `NYIA_TEAM_DIR` | path | local folder of shared skills/personas/prompts (you sync it) |
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

(The former team tier — `$NYIA_TEAM_DIR/config/` — was removed in Plan 328a: a team directory carries skills,
personas and prompt overlays, never config values.)

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
- **Subcommands do operations, not settings.** A config key holds a setting; a subcommand runs an
  operation. New domain features follow this shape (e.g. `git_history_cutoff` key + `nyia git-history`
  ops; `network_egress_policy` key + the egress firewall).

## "Already-both" settings (two sources, by design)
Some settings exist as a config key AND elsewhere, with a defined precedence:
- `workspace_sync` (key) ← overridden by the `workspace.conf` `sync_branches` directive.
- `rag_model` (key) ← a project `<assistant>.conf` `NYIA_RAG_MODEL` (precedence level 5) outranks
  `nyia config global rag_model` (level 6). This is the canonical two-source example.

## What crosses into the container

The launcher never forwards your shell environment wholesale. Exactly three channels carry values into the box
(all resolved on the host by `create_docker_env_file` / `run_docker_container`):

| Channel | Source | What passes | Rule |
|---|---|---|---|
| **Assistant settings allowlist** | the **global** `~/.config/nyiakeeper/config/<assistant>.conf` (profile-aware) | a short, per-assistant list of documented **non-secret** keys — today only OpenCode: `OLLAMA_AUTO_SETUP`, `ENABLE_OLLAMA`, `OLLAMA_FILTER_TOOLS` (`true`\|`false`), `OLLAMA_HOST` (`host[:port]`, no scheme), `OLLAMA_DEFAULT_MODEL` (model name) | conf only (a host-shell `export` of the same name never crosses); an invalid value is **dropped with a warning**, the launch continues with the in-box default; never read from a project tier — `OLLAMA_HOST` redirects model and RAG traffic, so a committed file must not set it (same rule as `auth_profile`) |
| **Credentials** | `.nyiakeeper/private/creds/env` (literal-parsed, never sourced) + the five fixed names read from the global conf **or the host shell environment** (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`, `MISTRAL_API_KEY`, `GOOGLE_CLOUD_PROJECT` — pre-existing behaviour) | names matching `*_API_KEY`, `*_TOKEN`, `*_KEY`, `GOOGLE_CLOUD_PROJECT`, `GOOGLE_APPLICATION_CREDENTIALS` | default-deny allowlist; `NYIA_*` / `OLLAMA_*` in `creds/env` are rejected with a warning |
| **Launcher exports** | flags and resolved config | `NYIA_COMMAND_MODE`, `NYIA_RAG_MODEL`, `ENABLE_RAG`, `NYIA_RAG_VERBOSE` (`--rag-verbose`), `NYIA_DEBUG=true` (only when the host has it on), `NYIA_OPERATION_TYPE=auth` on `--login`, the workspace / egress / git-history markers | not user-settable except through their own flag or key |

Notes:
- `ENABLE_RAG="true"` in a global `<assistant>.conf` is honoured (the conf is sourced after the CLI defaults and
  `parse_args` never resets it) — a supported way to make RAG the default for one assistant.
- A `opencode.conf` generated before Plan 340 carried the example defaults `OLLAMA_HOST="localhost:11434"` and
  `OLLAMA_DEFAULT_MODEL="llama3.2"` as active lines; the launcher comments those two exact lines out once (with a note) so
  they do not turn into per-launch probes/warnings — uncomment them to enforce the values.
- Anything else you put in `<assistant>.conf` stays on the host. If a documented key seems to do nothing in the
  box, check this table first.

## OpenCode configuration — the layers

OpenCode merges its configuration natively; Nyia only adds files in slots OpenCode already reads. In the box,
lowest to highest precedence:

| # | File (in the box) | Owner | Notes |
|---|---|---|---|
| 1 | `~/.config/opencode/config.json` | **Nyia** — regenerated every launch (Ollama auto-setup) | never edit; `OLLAMA_AUTO_SETUP="false"` keeps it as it is |
| 2 | `~/.config/opencode/opencode.json` (or `.jsonc`) | **you** — host path `~/.config/nyiakeeper/opencode/opencode.json` (`profiles/<p>/opencode/` when a profile is active) | your providers, models, `model` pin; Nyia never writes or prints it (OpenCode itself adds a `"$schema"` line on first load — that is the CLI, not Nyia) |
| 3 | `$project/opencode.json` (or `.jsonc`) | **the repository** | Nyia only reads it (see the threat note below) |
| 4 | `$project/.opencode/opencode.json` | **Nyia** — the `codebase-search` MCP entry when `--rag` is on, removed when off | gitignored with `.opencode/` |
| 5 | `~/.opencode/opencode.json` — the *same* host file as layer 2, seen again through Nyia's second mount | you | so on a conflicting key **your file wins over the project file**; a repository can only *add* what you did not set (observed behaviour, not a contract Nyia's code relies on) |

Practical notes:
- Add a cloud / OpenAI-compatible provider in layer 2 (`"provider": {"acme": {"npm": "@ai-sdk/openai-compatible", "options": {"baseURL": "…", "apiKey": "{env:ACME_API_KEY}"}, "models": {…}}}`) and pin `"model": "acme/…"` there — otherwise the default flips to whatever Ollama model is detected first, and to nothing when Ollama is down.
- **Key delivery**: only two paths persist across launches — a name matching `*_API_KEY` / `*_TOKEN` / `*_KEY` in `.nyiakeeper/private/creds/env` (then `{env:NAME}`), or a file dropped in the persisted dir (`{file:acme.key}`, relative to the config file). `/connect` writes `~/.local/share/opencode/auth.json`, which is **not** persisted by Nyia.
- A LAN endpoint (`192.168.x.x`) is blocked under `network_egress_policy=restrict-local` unless listed in `network-allow.conf`; public endpoints are reachable.
- A malformed layer-2/3 file stops OpenCode at startup with its own error — Nyia does not validate it.
- **Threat note**: a repository's `opencode.json` runs with your keys inside the box: it can add `mcp` servers (local commands started with the CLI), `plugin`s, `permission` rules and providers with their own `baseURL`. Nyia runs a best-effort key-name scan and prints one warning when a project file appears to declare any of those (a determined repository can hide a key); the review is yours before launching a repository that is not yours (see [THREAT_MODEL.md](THREAT_MODEL.md)).

## Version, channel and image selection

| Knob | What it does |
|---|---|
| `~/.config/nyiakeeper/VERSION` | the installed dist version (written by the installer / `nyia update`) |
| `~/.config/nyiakeeper/CHANNEL` | the update channel: `latest` (stable), `beta`, `alpha` (frozen). Switch with `nyia update install <channel>` |
| `NYIA_CHANNEL` | overrides the channel for one command |
| `NYIA_IMAGE_TAG` | **pins the container image tag** for one command, bypassing the channel — e.g. `NYIA_IMAGE_TAG=v0.1.0-beta.7 nyia-claude`. Works while that pinned tag is retained (newest 4 per channel + every stable) |

By default the launcher pulls the channel's floating tag on every launch, so a channel that moves —
forward on release, backward on a rollback — reaches you at the next start.
