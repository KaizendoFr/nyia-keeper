# Profiles

Profiles let you run the same assistant under **more than one account** — and, when you
want it, under a separate **persona** with its own skills, agents, and rules.

A named profile has two independent parts:

- **Authentication** — its own login/token and credential file (e.g. a personal Claude
  account and a work Claude account).
- **Content mode** — either **auth-only** (the default: it inherits all of your usual
  skills/agents/rules) or **persona** (opt-in: it has its own, isolated content).

By default you don't have to think about profiles at all: every assistant uses the
`default` profile, which is exactly the behavior Nyia Keeper has always had.

## TL;DR

```bash
# Just switch accounts — keep your whole setup (auth-only, the common case).
nyia-claude --profile work --login     # attach the second account (once)
nyia-claude --profile work             # same skills/agents/rules, different account

# A separate persona with its OWN content, seeded from a starting point.
nyia profile create accounting --persona --from non-tech
nyia-claude --profile accounting --login
nyia-claude --profile accounting

# Make a profile the default for every command (global setting).
nyia config global auth_profile=work

# See profiles, which is active, and each one's mode.
nyia profile list
```

## The two modes

### Auth-only (default)

A named profile you just log into — `nyia-claude --profile work --login` — is
**auth-only**. It uses its own account but **inherits your global content live**: the
same skills, agents, and prompt-override rules as your `default` profile. Switch accounts
without losing (or re-creating) your setup. This is the common case, and it needs no
`profile create` at all.

### Persona (opt-in)

When you want a context with its *own* skills/agents/rules — an `accounting` persona, a
client persona, a non-technical persona — create it explicitly:

```bash
nyia profile create accounting --persona --from tech|non-tech|empty
```

A persona is **isolated**: it uses only its own content (plus the always-on items
below). It is **seeded once** at create time and then independent — editing it never
touches your default, and later changes to your default never flow into it.

`--from` chooses the starting point:

| `--from` | Seeds the persona with |
|----------|------------------------|
| `tech`   | a copy of your current global skills/agents/rules |
| `non-tech` | the shipped plain-language starter (planning / summarizing / drafting + a no-jargon tone) |
| `empty`  | nothing — just the Nyia baseline (this is the default if you omit `--from`) |

## What each mode isolates

**Profiled (differs by profile):**

| What | Where (named profile) |
|------|-----------------------|
| Auth directory (OAuth tokens, session files) | `<nyia_home>/profiles/<name>/<assistant>` |
| Credential file (file-based API key, `AUTH_METHOD`) | `<nyia_home>/profiles/<name>/config/<assistant>.conf` |
| User skills / agents / prompt rules — **persona mode only** | `<nyia_home>/profiles/<name>/{skills,agents,prompts}` |

In **auth-only** mode the user content is *not* the profile's own dir — it is your global
`<nyia_home>/{skills,agents,prompts}`, inherited live.

**Always on, in every profile and every mode** — profiles can never switch these off:

- Nyia Keeper's protected system prompt and base prompt sections.
- The assistant's built-in (base) skills — including the developer-workflow ones. A
  persona *adds* content; it cannot remove the base skills.
- Team-shared content (skills, agents, prompts from your team directory).
- Project content (`.nyiakeeper/shared/`, project prompt overrides).

**Global and shared across profiles:**

- All `nyia config` settings (command mode, RAG model, team dir, workspace sync, …).
- Project credentials injected from `.nyiakeeper/private/creds/env`.
- Shell-exported API keys (see the warning below).

!!! warning "Shell-exported API keys are global"
    If you export a key in your own shell — e.g. `export OPENAI_API_KEY=...` or
    `export ANTHROPIC_API_KEY=...` — that value is global by nature and is **not**
    profiled. It applies to every profile and can shadow a profile's own file-based key.
    To isolate keys per profile, store them in the profile's config file (written when
    you log in or set the key under that profile) and avoid a global shell export.

## Selecting the active profile

The active profile is resolved with this precedence (highest first):

1. **`--profile <name>` flag** on a per-assistant command (e.g. `nyia-claude --profile work`).
2. **Global config**: `nyia config global auth_profile=<name>`.
3. **`default`** — the legacy behavior.

The `auth_profile` setting — and a profile's mode — are **global-scope only**. A profile
cannot be selected, nor turned into a persona, from a project-level or team-shared
`nyia.conf`, so a committed repository file can never redirect a teammate's credentials
or swap in a repository-chosen rules file behind your back.

## Creating profiles: `nyia profile create`

```text
# Auth-only: register a profile that inherits your global content.
$ nyia profile create work
Created auth-only profile 'work'.
...
Attach an account:  nyia-<assistant> --profile work --login

# Persona: its own content, seeded from a starting point.
$ nyia profile create accounting --persona --from non-tech
Created persona 'accounting' (seeded --from non-tech):
  ~/.config/nyiakeeper/profiles/accounting/   content: [skills agents prompts]
  ├── skills/    <- skill directories (each with SKILL.md)
  ├── agents/    <- agent .md files
  └── prompts/   <- base-overrides.md + <assistant>-overrides.md (see README)
```

- Plain `create` makes an **auth-only** profile — no content dirs, nothing to manage.
- `--persona` scaffolds the content dirs (with a prompts `README.md` and
  `*-overrides.md.example` files), marks the profile a persona, and seeds it once.
- The command is idempotent and never clobbers content you've edited.
- A profile is also created implicitly the first time you `--profile <name> --login`
  (auth-only), so for the two-accounts case you can skip `create` entirely.

## `nyia profile list`

Lists the profiles, marks the active one with `*`, and shows each named profile's
**mode** (and, for personas, which kinds of content it carries):

```text
Authentication profiles:

  * default
    work               (auth-only)
    accounting         (persona) [skills prompts]

Active: default   (override per-command with --profile <name>)
```

- `default` always appears and carries no mode tag (it *is* your global content).
- `(auth-only)` inherits your global content; `(persona)` uses its own.
- Persona content markers are truthful: `skills` needs a `<skill>/SKILL.md`, `agents` a
  `.md` file, `prompts` an activated (non-`.example`) `*-overrides.md`.
- The command is **read-only**.

## Profile names

A profile name must start and end with a letter or digit, contain only letters, digits,
and `.` `_` `-` in between, be at most 64 characters, and never contain `..`, `/`, `:`,
or spaces. Invalid names are rejected at the flag, in `nyia config`, and in
`nyia profile create`, so a name can never escape its directory or alter a container
mount.

## How it is stored on disk

| Profile | Auth dir | Credential file | Content source at launch |
|---------|----------|-----------------|--------------------------|
| `default` | `<nyia_home>/<assistant>` | `<nyia_home>/config/<assistant>.conf` | `<nyia_home>/{skills,agents,prompts}` (global) |
| `work` (auth-only) | `<nyia_home>/profiles/work/<assistant>` | `<nyia_home>/profiles/work/config/<assistant>.conf` | `<nyia_home>/{skills,agents,prompts}` (global, inherited) |
| `accounting` (persona) | `<nyia_home>/profiles/accounting/<assistant>` | `<nyia_home>/profiles/accounting/config/<assistant>.conf` | `<nyia_home>/profiles/accounting/{skills,agents,prompts}` (own) |

A persona is marked by `<nyia_home>/profiles/<name>/profile.conf`
(`NYIA_PROFILE_MODE=persona`); its absence means auth-only. The `default` profile uses
the original paths unchanged, so upgrading changes nothing for existing users.

## Good to know (behavior details)

- **You'll see which profile you're on.** Launching or logging in with a named profile
  prints a one-line banner (e.g. `▶ Profile: work (auth-only)`), so you never work
  against the wrong account by mistake. The `default` profile prints nothing.
- **Auth-only inheritance is slightly asymmetric.** Prompt-override *rules* are read
  fresh at every launch, so editing a global rule takes effect immediately in an
  auth-only profile. *Skills and agents* are copied into the profile's session directory
  at launch. Nyia's **built-in** skills are refreshed on every launch (they are Nyia-owned and
  carry a `.nyia-builtin` marker — Plan 337); a skill you **wrote yourself** is never overwritten,
  so a global skill you **add** shows up, but one you **edit** after the profile's first launch
  is not re-copied. (This is the same copy-on-launch behavior the default profile has.)
- **A persona doesn't track your default.** Because it's seeded once, later changes to
  your global content don't flow into it. Re-seed by copying, or start over with a fresh
  `--from`.
- **Base skills always appear.** The assistant's built-in developer-workflow skills are
  installed in the container and can't be removed by a profile — a persona only adds a
  layer on top. The `non-tech` template is a friendlier layer, not a replacement.
- **Flipping auth-only → persona.** If you `create <name> --persona` for a profile you've
  already launched as auth-only, its session dir still holds the global/team copies from
  before. `create` warns you and tells you which dir to clear for a clean persona.
- **Removing a profile is manual:** delete its `profiles/<name>/` directory. Nyia Keeper
  never auto-deletes profile data.
