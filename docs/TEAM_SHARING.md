# Team Sharing - Shared Resources Across Machines

Nyia Keeper supports a **team directory** for sharing skills, agents, prompts, and configuration across multiple machines or team members. The team directory is a regular folder on disk (synced via git, Dropbox, NFS, or any other mechanism you choose).

## Quick Start

1. Create a shared directory with the expected structure:

```bash
mkdir -p /path/to/team-shared/{skills,agents,prompts,config}
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
├── prompts/             # Shared prompt overlays
│   └── team-guidelines.md
└── config/              # Shared configuration
    └── team-defaults.conf
```

### Skills

Each skill is a subdirectory containing a `SKILL.md` file. Skills are automatically discovered and listed by `--list-skills`. They are propagated to each assistant's project directory at launch (no-clobber: existing project skills take precedence).

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

### Config

Configuration files in `config/` provide team-level defaults. These are safe-parsed (no secrets -- values are read as plain key=value pairs).

## Precedence

Resources are resolved in strict precedence order. Higher-precedence sources win:

```
1. Project-local    (.claude/skills/, .claude/agents/, etc.)
2. Project-shared   (.nyiakeeper/shared/skills/, etc.)
3. Team             (team_dir/skills/, team_dir/agents/, etc.)
4. Global user      (~/.config/nyiakeeper/skills/, etc.)
```

This means:
- A project-local skill named `code-review` shadows a team skill with the same name.
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
- Which subdirectories are present (skills, agents, prompts, config)

## Security

- Team configuration is **safe-parsed**: no shell expansion, no command execution.
- The team directory is read-only from Nyia Keeper's perspective -- it never writes to it.
- No secrets or credentials should be placed in the team directory.
- Team config values go through the same sanitization as all other config sources.

## Sync Strategies

Nyia Keeper does not manage synchronization of the team directory. Common approaches:

| Strategy | Pros | Cons |
|----------|------|------|
| Git repository | Version history, PR review | Requires git workflow |
| Dropbox/Google Drive | Automatic sync, no setup | No version control |
| NFS/SMB mount | Real-time access | Requires network infrastructure |
| Symlink to monorepo subdirectory | Zero-copy, always current | Ties to monorepo |

## Announcing Changes with `/whatsup`

Sharing skills, agents, and prompts (above) makes resources *available* to the
team. The `/whatsup` skill makes changes to them *discoverable*: when a teammate
ships a new skill, edits a prompt, or changes a convention, they publish a short
news entry, and everyone else sees it instead of finding out by accident.

> "Nyia" (にゃ) is the cat that watches your code — `/whatsup` is the cat telling
> you what changed.

### Commands

| Command | What it does |
|---------|--------------|
| `/whatsup` | Show news entries you haven't read yet, newest/most severe first |
| `/whatsup add` | Publish a news entry (draft → confirm → commit) |
| `/whatsup list` | List all entries with a read / unread / hidden marker |
| `/whatsup ack <id>` | Acknowledge an entry (dismisses a `breaking` warning) |
| `/whatsup hide <id>` | Permanently hide an entry ("not for me") |

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

Outside a Nyia project (no `.nyiakeeper/`), `/whatsup` still works in *standalone
mode*, storing entries under `.whatsup/` with manual invocation only.

### Severity levels

- **info** — inline note, low priority.
- **important** — pulled to the top of the list.
- **breaking** — shown in a loud visual box and **stays flagged on every read**
  until you run `/whatsup ack <id>`. V1 is a visual warning only; it does not block.

### Automatic news at session start (opt-in)

`/whatsup` integrates with the `/kickoff` and `/checkpoint` skills, but only when
enabled in config (default: off):

```bash
# Enable whatsup and surface unread news automatically at session start
nyia config global whatsup_enabled=true
nyia config global whatsup_auto_read=kickoff
```

| Config key | Values | Default | Effect |
|------------|--------|---------|--------|
| `whatsup_enabled` (`NYIA_WHATSUP_ENABLED`) | `true` \| `false` | `false` | Master switch for lifecycle hooks |
| `whatsup_auto_read` (`NYIA_WHATSUP_AUTO_READ`) | `kickoff` \| `never` | `never` | Show unread news during `/kickoff` |

When enabled, `/checkpoint` also detects when a session changed meta-files
(skills, prompts, shared config) and offers to publish a `/whatsup` entry.

### Security

- **No secrets in entries.** Entries are committed and shared, so `/whatsup add`
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

The directory exists but contains none of the expected subdirectories (`skills/`, `agents/`, `prompts/`, `config/`). Create at least one:
```bash
mkdir -p /path/to/team-shared/skills
```

### Team skills/agents not appearing

1. Verify the team directory is configured: `nyia config global --list`
2. Check that skills have a `SKILL.md` file in their subdirectory
3. Check that agent files use the correct format for your assistant
4. Check precedence: a project-local resource with the same name takes priority
