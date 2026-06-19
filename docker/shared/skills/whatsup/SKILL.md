---
name: whatsup
description: Team news distribution. Read what teammates changed (skills, prompts, conventions) since your last session, or publish a news entry after shipping something worth knowing about. Use /whatsup to read, /whatsup add to publish.
---

# whatsup - Team News

"Nyia" (にゃ) is the cat that watches your code. `/whatsup` is the cat telling you
what changed. Teammates ship skills, prompt edits, and convention changes;
`/whatsup` makes that discoverable instead of accidental.

This skill has an **agnostic core** (read / add / ack / hide / list) that works
anywhere, plus **Nyia integration** (kickoff/checkpoint hooks, config gating)
that activates only inside a Nyia Keeper project.

## Environment Detection (do this FIRST)

Decide the storage root before any other action:

1. If `.nyiakeeper/` exists in the project root → **Nyia mode**.
   - Entries: `.nyiakeeper/whatsup/entries/`
   - Read state: `.nyiakeeper/whatsup/.seen.json` (gitignored)
   - Lifecycle hooks (kickoff/checkpoint) and config gating are available.
2. If `.nyiakeeper/` is absent → **standalone mode**.
   - Entries: `.whatsup/entries/`
   - Read state: `.whatsup/.seen.json`
   - Manual invocation only — no lifecycle hooks, no config lookup.

In both modes, create the entries directory if it does not exist before writing.
Use `<root>` below to mean the chosen storage root (`.nyiakeeper/whatsup` or
`.whatsup`).

## Storage Layout

```
<root>/
├── entries/2026/06/2026-06-04-a3f-001.md   # committed, one file per entry
└── .seen.json                              # per-machine read state, gitignored
```

One file per entry — **never append to a shared changelog**. This guarantees
zero merge conflicts even when two contributors publish at the same time.

## Entry Format

A news entry is YAML frontmatter followed by a markdown body:

```markdown
---
id: 2026-06-04-a3f-001
date: 2026-06-04
author: nicolas
scope: project
tags: [skill, deploy]
severity: important
---

## New deploy-checklist skill

**What:** Pre-deployment verification checklist.
**Why it matters:** Catches common deployment mistakes.
**Action needed:** None — opt-in via `/deploy-checklist`.
```

Frontmatter fields:
- `id` — entry ID (see ID generation below).
- `date` — `YYYY-MM-DD`.
- `author` — the publisher (use `$USER`, git `user.name`, or ask).
- `scope` — `project` in V1. (`global` is reserved for V2 team transport.)
- `tags` — short list of topic tags.
- `severity` — `info` | `important` | `breaking`.

### Entry ID generation

Format: `YYYY-MM-DD-{3-char-random}-{seq}` — e.g. `2026-06-04-a3f-001`.

- The 3-char random suffix avoids collisions between concurrent assistants.
  Generate it with exactly three hex characters:
  ```bash
  head -c 2 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-3
  ```
- `{seq}` is a 3-digit zero-padded counter for that day+random combination,
  starting at `001`. If a file with the generated ID already exists, increment
  `{seq}` until the filename is free.
- The entry file lives at `<root>/entries/<YYYY>/<MM>/<id>.md`.

## Read State: `.seen.json`

Per-machine read state, **gitignored** (never commit it). Schema:

```json
{
  "last_run": "2026-06-05T10:00:00Z",
  "seen": ["2026-06-04-a3f-001"],
  "hidden": ["2026-06-03-b2e-002"],
  "acked": ["2026-06-04-c1d-003"]
}
```

- `last_run` — ISO-8601 UTC timestamp of the last read.
- `seen` — entry IDs the user has viewed.
- `hidden` — entry IDs permanently hidden ("not for me").
- `acked` — entry IDs explicitly acknowledged (dismisses breaking warnings).

If `.seen.json` is missing or malformed, treat every entry as unread and create a
fresh file. Always write valid JSON; never crash on a corrupt state file.

## Commands

### `/whatsup` (read mode)

1. Detect environment and storage root.
2. Read `.seen.json` (or treat all as unread if absent).
3. List entry files under `<root>/entries/`. An entry is **unread** if its `id`
   is not in `seen` AND not in `hidden`.
4. Display unread entries grouped by severity (see Severity Display below).
   Breaking first, then important, then info.
5. After display, add the shown entry IDs to `seen` and update `last_run`, then
   write `.seen.json`. (`breaking` entries are NOT auto-acked — they stay flagged
   until the user runs `/whatsup ack <id>`.)
6. If there are no unread entries, say so briefly: "No new team news."

### `/whatsup add` (publish mode)

Follow draft → confirm → commit:

1. Detect environment and storage root; ensure `entries/<YYYY>/<MM>/` exists.
2. Gather entry content. Ask for (or infer from the session):
   - title (becomes the `##` heading)
   - `severity` (info | important | breaking)
   - `tags`
   - body: What / Why it matters / Action needed
   - **NO-SECRETS RULE**: summarize changed meta-files by path and the user's own
     words only. NEVER dump config, prompt, credential, or `.env` contents into a
     news entry — entries are committed and shared.
3. Generate the entry ID and write the file.
4. Show the rendered draft to the user and ask for explicit confirmation.
5. On confirmation, commit **safely** (Nyia mode / git repos only):
   - Stage ONLY the new entry file: `git add -- <root>/entries/<YYYY>/<MM>/<id>.md`
   - Never use `git add .` or `git add -A` — never stage unrelated work.
   - Show `git diff --staged -- <entry>` so the user sees exactly what commits.
   - Commit with message: `news(whatsup): <title>`
   - In standalone mode (or no git), just write the file and tell the user it is
     not committed.

### `/whatsup ack <id>`

Add `<id>` to `acked` (and `seen`) in `.seen.json`, write it back. This dismisses
a `breaking` entry's warning. For `info`/`important`, ack is optional.

### `/whatsup hide <id>`

Add `<id>` to `hidden` in `.seen.json`. Hidden entries are permanently excluded
from read/list output ("not for me"). This does not delete the entry file.

### `/whatsup list`

Show ALL entries (newest first) with a read/unread/hidden marker each, regardless
of seen state. Format: `<marker> [<severity>] <title> — <author>, <date> (<id>)`.

## Severity Display

```
info:      📰 • [info] Title — author, date
important: 📰 • [important] Title — author, date   (shown at top of list)
breaking:  ╔══════════════════════════════════╗
           ║ ⚠️  BREAKING — Title              ║
           ║ Author: x | /whatsup ack <id>    ║
           ╚══════════════════════════════════╝
```

- `info` — inline list entry.
- `important` — bullet pulled to the top of the list.
- `breaking` — full visual box; remains flagged on every read until the user runs
  `/whatsup ack <id>`. V1 is a loud visual warning only — it does NOT block.

## Nyia Lifecycle Integration (Nyia mode only)

These hooks only fire when `NYIA_WHATSUP_ENABLED=true` in config. They are wired
from the `/kickoff` and `/checkpoint` skills:

- **kickoff**: if `NYIA_WHATSUP_AUTO_READ=kickoff`, run read mode after state
  reconstruction and surface unread entries (breaking ones prominently).
- **checkpoint**: if the session modified meta-files (skills, prompts, shared
  config, `*.conf` under `.nyiakeeper/`), prompt the user to publish a `/whatsup`
  entry so the team sees the change.

### Reading config values

Config is gated by two keys resolved via Nyia's config system:
- `NYIA_WHATSUP_ENABLED` (`true` | `false`, default `false`)
- `NYIA_WHATSUP_AUTO_READ` (`kickoff` | `never`, default `never`)

To read the effective value, prefer `nyia config view whatsup_enabled` /
`nyia config view whatsup_auto_read` if the `nyia` CLI is on PATH. Otherwise read
the config files directly in precedence order (project `.nyiakeeper/nyia.conf`
then global `~/.config/nyiakeeper/config/nyia.conf`) and look for the
`NYIA_WHATSUP_ENABLED` / `NYIA_WHATSUP_AUTO_READ` lines. If neither is set, use
the defaults (`false` / `never`) — which means the hooks do nothing.
