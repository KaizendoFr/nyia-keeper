# Team Directory — shared skills, personas & prompts (local folder)

Nyia Keeper shares team resources through a **team directory**: a regular folder on disk that you keep in
sync however you like (git, Dropbox, NFS, a symlink — your choice). Nyia only *reads* it. It carries
**skills, personas (agents), and prompt overlays** — the resources the assistant uses. *(It does not carry
`config` values: command-mode and the RAG model must never be silently inherited from a shared source.)*

**How to sync it is up to you, and that's the review gate.** If you keep the folder in git, your own
`git pull` is where you *see the diff* before new team content reaches your assistants — a deliberate
human checkpoint.

**Trust model (honest).** Shared team content is a **trust decision**, the same as trusting any shared
codebase you point an AI tool at: a teammate with write access can add content, and no tool can tell you
in advance whether that content is well-intentioned — this is the git-shared-repo + AI threat model, not
something specific to Nyia. What Nyia *does* protect against, today, is the **propagation mechanism** being
abused: a shared item cannot smuggle a symlink or a traversal path to exfiltrate files from your host (see
the [Security model](THREAT_MODEL.md)). Content-level review of shared skills/prompts is planned next
(an on-device guard model).

## Quick Start

1. Create a shared directory with the expected structure:

```bash
mkdir -p /path/to/team-shared/{skills,agents,prompts}
```

2. Configure Nyia Keeper to use it:

```bash
nyia config global team_dir=/path/to/team-shared
```

3. Verify it works:

```bash
nyia status           # Shows team directory info
nyia-claude --list-skills   # Team skills appear under "Team skills"
nyia-claude --list-agents   # Team agents appear under "Team agents"
```

## Directory Structure

The team directory follows the same layout as `.nyiakeeper/shared/`:

```
/path/to/team-shared/
├── skills/              # Shared skills (each needs SKILL.md)
│   ├── code-review/
│   │   └── SKILL.md
│   └── pair-review/
│       └── SKILL.md
├── agents/              # Shared agent personas
│   ├── reviewer.md      # Claude agent (Markdown)
│   └── architect.md
└── prompts/             # Shared prompt overlays
    └── team-guidelines.md
```

### Skills

Each skill is a subdirectory containing a `SKILL.md` file. Nyia's own built-ins are named `nyia-*` and are
refreshed on every upgrade; to customize one under its own name, put your version in the team directory or in
the project's `.nyiakeeper/shared/skills/` (a copy from there is user-owned and never replaced) — a same-name copy
in your global skills directory would be overwritten by the installer. Skills are automatically discovered and listed by `--list-skills`. They are propagated to each assistant's project directory at launch (no-clobber: existing project skills take precedence).

### Agents

Agent personas are assistant-specific files placed directly in the `agents/` directory. File formats vary by assistant:

| Assistant | Format | Example |
|-----------|--------|---------|
| Claude | `*.md` | `reviewer.md` |
| OpenCode | `*.md`, `*.json` | `architect.md` |
| Vibe | `*.toml` | `debugger.toml` |
| Codex | Config-based | (uses `~/.codex/config.toml` sections) |
| Gemini | Not yet supported | -- |

### Prompts

Prompt overlays placed in `prompts/` are propagated to each assistant at launch. Use these for team-wide coding guidelines, review checklists, or domain-specific instructions.

> **No `config/`.** A team directory does **not** carry config values (command-mode, RAG model). Those are
> deliberately excluded so a shared source can never silently change how much the agent is allowed to do —
> set them locally with `nyia config`.

## Precedence

Resources are resolved in strict precedence order. Higher-precedence sources win:

```
1. Project-local    (.claude/skills/, .claude/agents/, etc.)
2. Project-shared   (.nyiakeeper/shared/skills/, etc.)
3. Team             (team_dir/skills/, team_dir/agents/, etc.)
4. Global user      (~/.config/nyiakeeper/skills/, etc.)
```

This means:
- A project-local skill named `deploy` shadows a team skill with the same name.
- A project-shared agent named `reviewer` shadows a team agent with the same name.
- Team resources shadow global user resources.

## Configuration

### Setting the team directory

```bash
# Set for all projects (global config)
nyia config global team_dir=/path/to/team-shared

# View current configuration
nyia config global --list
```

The key is stored as `NYIA_TEAM_DIR` in `~/.config/nyiakeeper/config/nyia.conf`.

### Checking team status

```bash
nyia status
```

This shows:
- Whether a team directory is configured
- Whether the directory exists on disk
- Which subdirectories are present (skills, agents, prompts)

## Security

- The team directory is read-only from Nyia Keeper's perspective -- it never writes to it.
- No secrets or credentials should be placed in the team directory.
- **Propagation is guarded** (see the [Security model](THREAT_MODEL.md)): a shared skill/agent/prompt that
  is a symlink, contains a nested symlink, or uses a traversal path is refused — it cannot be used to read
  files from your host. This is a structural guard, not content review.
- **Content is a trust decision.** The guard above stops the *mechanism* being abused; it does not judge
  whether a shared prompt's *text* is safe. Treat a shared source like any shared repo you'd point an AI
  tool at. On-device content review is planned next.

## Sync Strategies

Nyia Keeper does not manage synchronization of the team directory. Common approaches:

| Strategy | Pros | Cons |
|----------|------|------|
| Git repository | Version history, PR review | Requires git workflow |
| Dropbox/Google Drive | Automatic sync, no setup | No version control |
| NFS/SMB mount | Real-time access | Requires network infrastructure |
| Symlink to monorepo subdirectory | Zero-copy, always current | Ties to monorepo |

## Team news (`/nyia-whatsup`)

**`/nyia-whatsup` is a different class — news, not resources.** The team directory (above) makes resources
*available*; `/nyia-whatsup` makes changes to them *discoverable*: when a teammate ships a new skill, edits a
prompt, or changes a convention, they publish a short news entry (committed to the project's git), and
everyone else sees it instead of finding out by accident.

> "Nyia" (にゃ) is the cat that watches your code — `/nyia-whatsup` is the cat telling
> you what changed.

### Commands

| Command | What it does |
|---------|--------------|
| `/nyia-whatsup` | Show news entries you haven't read yet, newest/most severe first |
| `/nyia-whatsup add` | Publish a news entry (draft → confirm → commit) |
| `/nyia-whatsup list` | List all entries with a read / unread / hidden marker |
| `/nyia-whatsup ack <id>` | Acknowledge an entry (dismisses a `breaking` warning) |
| `/nyia-whatsup hide <id>` | Permanently hide an entry ("not for me") |

### How entries are stored

Each entry is a single markdown file with YAML frontmatter, committed to the
project so the team shares it via git:

```
.nyiakeeper/whatsup/
├── entries/2026/06/2026-06-04-a3f-001.md   # one file per entry (committed)
└── .seen.json                              # your per-machine read state (gitignored)
```

One file per entry means **two people can publish at the same time without merge
conflicts**. Your read state (`.seen.json`) is per-machine and never committed.

Outside a Nyia project (no `.nyiakeeper/`), `/nyia-whatsup` still works in *standalone
mode*, storing entries under `.whatsup/` with manual invocation only.

### Severity levels

- **info** — inline note, low priority.
- **important** — pulled to the top of the list.
- **breaking** — shown in a loud visual box and **stays flagged on every read**
  until you run `/nyia-whatsup ack <id>`. V1 is a visual warning only; it does not block.

### Automatic news at session start (opt-in)

`/nyia-whatsup` integrates with the `/nyia-kickoff` and `/nyia-checkpoint` skills, but only when
enabled in config (default: off):

```bash
# Enable whatsup and surface unread news automatically at session start
nyia config global whatsup_enabled=true
nyia config global whatsup_auto_read=kickoff
```

| Config key | Values | Default | Effect |
|------------|--------|---------|--------|
| `whatsup_enabled` (`NYIA_WHATSUP_ENABLED`) | `true` \| `false` | `false` | Master switch for lifecycle hooks |
| `whatsup_auto_read` (`NYIA_WHATSUP_AUTO_READ`) | `kickoff` \| `never` | `never` | Show unread news during `/nyia-kickoff` |

When enabled, `/nyia-checkpoint` also detects when a session changed meta-files
(skills, prompts, shared config) and offers to publish a `/nyia-whatsup` entry.

### Security

- **No secrets in entries.** Entries are committed and shared, so `/nyia-whatsup add`
  summarizes changes by file path and your own words only — it never dumps config,
  prompt, credential, or `.env` contents into an entry.
- Publishing stages **only the new entry file** (never `git add .`), and shows you
  the staged diff before committing.

## Troubleshooting

### "Team dir configured but does not exist"

The path in your config does not exist on disk. Check:
```bash
nyia config global --list   # Verify the path
ls -la /path/to/team-shared # Check if directory exists
```

### "Team dir configured but has no content"

The directory exists but contains none of the expected subdirectories (`skills/`, `agents/`, `prompts/`). Create at least one:
```bash
mkdir -p /path/to/team-shared/skills
```

### Team skills/agents not appearing

1. Verify the team directory is configured: `nyia config global --list`
2. Check that skills have a `SKILL.md` file in their subdirectory
3. Check that agent files use the correct format for your assistant
4. Check precedence: a project-local resource with the same name takes priority

## Testing team sharing (helper script)

A self-contained smoke test verifies the whole feature end-to-end **without touching your
real config** (it runs in an isolated temporary `NYIAKEEPER_HOME`).

**File:** `scripts/test-team-sharing.sh`

**Run it** (host or inside the Vagrant VM, from the repo root):

```bash
scripts/test-team-sharing.sh                              # dev edition (./bin)
NYIA_BIN_DIR=dist/runtime/bin scripts/test-team-sharing.sh   # runtime edition
NYIA_ASSISTANT=codex scripts/test-team-sharing.sh            # a different assistant (default: claude)
```

Exit code `0` = all checks passed.

**What it checks:**
1. `nyia config global team_dir=…` sets the team directory, and `nyia config view` shows it.
2. `nyia status` surfaces the team directory.
3. `nyia-<assistant> --list-skills` / `--list-agents` discover the sample team skill/agent.
4. A project-shared skill of the same name resolves (project-over-team precedence path).

**In the Vagrant VM:** the repo is mounted at `/dockerized-assistants-src`; run
`/dockerized-assistants-src/scripts/test-team-sharing.sh` (or `cd` there first). Use
`NYIA_BIN_DIR=/dockerized-assistants-src/dist/runtime/bin` to exercise the shipped (runtime) edition.

> Note: `nyia config get <key>` currently supports only `home`/`config`/`data`, not the
> registered config keys — use `nyia config view` to inspect key values. (Tracked for the
> config-dispatcher convergence work.)
