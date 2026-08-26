# Nyia Keeper CLI Reference

Complete reference for all CLI flags and their interactions.

## Quick Reference Matrix

| Flag | Category | Requires | Conflicts | Description |
|------|----------|----------|-----------|-------------|
| `-w`, `--work-branch <name>` | Branch | - | - | Switch to specific work branch |
| `--create` | Branch | `--work-branch` | - | Create branch if missing |
| `--base-branch <name>` | Branch | - | - | Source branch for new branch |
| `--build-custom-image` | Build | - | - | Build with user overlays |
| `--base-image <image>` | Build | `--build-custom-image` | `--flavor` | Override base image for overlay build (dev only) |
| `--no-cache` | Build | `--build`* or `--build-custom-image` | - | Force rebuild without Docker cache |
| `--flavor <name>` | Image | - | `--image`* | Use flavor image |
| `--image <tag>` | Image | - | `--flavor`* | Use specific image |
| `--list-images` | Image | - | - | List available images |
| `--list-flavors` | Image | - | - | List available flavors |
| `--agent <name>` | Agent | - | - | Select agent persona for session |
| `--list-agents` | Agent | - | - | List available agent personas |
| `--rag` | RAG | Ollama | - | Enable codebase search |
| `--rag-verbose` | RAG | `--rag` | - | Debug RAG indexing |
| `--rag-model <name>` | RAG | `--rag` | - | Override embedding model |
| `--login` | Auth | - | - | Authenticate assistant |
| `--force` | Auth | `--login` | - | Bypass auth checks |
| `--set-api-key` | Auth | - | - | Set API key (OpenCode) |
| `--profile <name>` | Auth | - | - | Use a named profile (separate account; auth-only keeps your content) |
| `--status` | Config | - | - | Show current configuration |
| `--setup` | Config | - | - | Interactive setup |
| `--path <dir>` | Config | - | - | Work on different project |
| `--shell` | System | - | - | Interactive bash shell |
| `--check-requirements` | System | - | - | Verify system requirements |
| `--disable-exclusions` | System | - | - | Disable mount exclusions |
| `--skip-checks` | System | - | - | Skip startup checks |
| `--verbose, -v` | Output | - | - | Verbose output |
| `--help, -h` | Output | - | - | Show help |

*`--image` takes precedence over `--flavor` when both specified.

---

## Aliases & short flags

Every plural command/flag also accepts a singular form, and the common flags have short forms
(kubectl-style, **additive** — the plural/long name stays canonical in help and docs).

**Command aliases** (singular = same command): `nyia plan` = `nyia plans` · `nyia exclusion` =
`nyia exclusions` · `nyia completion` = `nyia completions`.

**Flag aliases & short forms** (on the assistant launchers, e.g. `nyia-claude`):

| Canonical | Singular alias | Short |
|-----------|----------------|-------|
| `--image` | — | `-i` |
| `--flavor` | — | `-f` |
| `--agent` | — | `-a` |
| `--status` | — | `-s` |
| `--login` | — | `-L` |
| `--version` | — | `-V` |
| `--list-images` | `--list-image` | `-li` |
| `--list-flavors` | `--list-flavor` | `-lf` |
| `--list-agents` | `--list-agent` | `-la` |
| `--list-skills` | `--list-skill` | `-ls` |
| `--disable-exclusions` | `--disable-exclusion` | — |

`-l` alone is reserved as the list-prefix; parsing is literal token-matching (no `getopts` bundling), so
`-li` is a single token, never `-l -i`.

## Flag Categories

### Branch Management

Control how Nyia Keeper creates and manages Git branches for your work.

| Flag | Short | Description |
|------|-------|-------------|
| `--work-branch <name>` | `-w` | Switch to a specific work branch |
| `--create` | | Create the work branch if it doesn't exist (requires `--work-branch`) |
| `--base-branch <name>` | | Specify which branch to create new branches from |

**Default behavior**: Works on current branch. Protected branches (main, master, + configured) trigger an interactive prompt.

**Config**: Set `NYIA_AUTO_BRANCH=true` for old timestamped branch behavior. Set `NYIA_PROTECTED_BRANCHES` to add protected branches.

**See also**: [BRANCH_MANAGEMENT.md](BRANCH_MANAGEMENT.md) for detailed workflows.

### Custom Image Building

| Flag | Description |
|------|-------------|
| `--build-custom-image` | Build with user overlay Dockerfiles |
| `--base-image <image>` | Override base image for overlay build (dev only). Mutually exclusive with `--flavor` |
| `--no-cache` | Force rebuild without Docker cache (requires `--build`* or `--build-custom-image`) |

*`--build` and `--base-image` are dev-only and not available in runtime distribution.

**`--base-image`**: Override which image the overlay builds on top of. Useful for testing overlays against locally-built flavor images:

```bash
# Build overlay on a local flavor image:
nyia-claude --build-custom-image --base-image nyiakeeper/claude-python:dev-feature
```

Overlay Dockerfiles must follow this pattern:
```dockerfile
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

USER root
RUN apt-get update && apt-get install -y your-packages && rm -rf /var/lib/apt/lists/*
USER node
RUN pip install --no-cache-dir your-python-packages
```

See [USER_GUIDE_FLAVORS_OVERLAYS.md](USER_GUIDE_FLAVORS_OVERLAYS.md) for full overlay documentation.

### Image Selection

Choose which Docker image to run.

| Flag | Description |
|------|-------------|
| `--flavor <name>` | Use a pre-built flavor image (e.g., `python`, `node`) |
| `--image <tag>` | Use a specific image tag |
| `--list-images` | List all available local images |
| `--list-flavors` | List all available flavors |

**Precedence**: `--image` > `--flavor` > default

**Available flavors**:
- `python` - pytest, black, mypy, ruff, isort, ipython
- `php` - PHP 8.3, Composer, PHPUnit, PHPStan
- `node` - Node.js 22, yarn, pnpm, typescript, biome, vitest, vite, storybook, cypress, Expo (via `npx expo`), eas-cli
- `php-react` - PHP 8.2 + React fullstack
- `rust-tauri` - Rust, Cargo, Tauri v2, clippy, rustfmt, Node.js 22

**See also**: [USER_GUIDE_FLAVORS_OVERLAYS.md](USER_GUIDE_FLAVORS_OVERLAYS.md) for flavor details.

### Agent Personas

Select or list agent personas for the session. See [assistant-agents-matrix.md](assistant-agents-matrix.md) for per-assistant capabilities.

| Flag | Description |
|------|-------------|
| `--agent <name>` | Select agent persona (Claude, OpenCode, Vibe: direct mapping; Codex: guidance-only) |
| `--list-agents` | List available agent personas (host-side discovery, no container needed) |

**Scope precedence**: `--agent` (session) > project-local agents > global agents > assistant default.

**Agent name rules**: lowercase letters, numbers, and hyphens only. Max 64 characters.

```bash
# List available agents
nyia-claude --list-agents

# Use a specific agent
nyia-claude --agent reviewer
nyia-vibe --agent plan
nyia-opencode --agent my-custom-agent
```

### RAG (Codebase Search)

Semantic code search using local embeddings. Requires Ollama.

| Flag | Description |
|------|-------------|
| `--rag` | Enable RAG codebase search |
| `--rag-verbose` | Enable verbose debug logging for RAG indexing |
| `--rag-model <name>` | Override embedding model (default: `nomic-embed-text`) |

**Requirements**: Ollama must be installed and running locally.

### Authentication

Manage assistant authentication.

| Flag | Description |
|------|-------------|
| `--login` | Authenticate with the assistant's service |
| `--force` | Bypass authentication checks (use with `--login`) |
| `--set-api-key` | Set API key for team plan users (OpenCode) |
| `--profile <name>` | Use a named profile: a separate account. Auth-only (the default) keeps your global skills/agents/rules; a persona has its own. See [Profiles](PROFILES.md). |

### Profiles (`nyia profile`)

Multiple accounts per assistant, and optional per-profile content. See
[Profiles](PROFILES.md) for the full guide.

| Command | Description |
|---------|-------------|
| `nyia profile list` | List profiles, the active one, and each named profile's mode (auth-only / persona) |
| `nyia profile create <name>` | Register an auth-only profile (inherits your global content) |
| `nyia profile create <name> --persona [--from tech\|non-tech\|empty]` | Create an isolated persona with its own content, seeded once |
| `nyia config global auth_profile=<name>` | Make a profile the default for every command (global scope only) |

### Plan tracking (`nyia plans` / `nyia todo`) {#plan-tracking}

Nyia keeps execution plans and a generated todo inventory under `.nyiakeeper/plans/`; the built-in
skills (`/make-a-plan`, `/implement-plan`, `/plan-review`, `/code-review`) read and write them. The
command is `nyia plans` (plural).

| Command | Description |
|---------|-------------|
| `nyia plans migrate [--dry-run\|--yes]` | Migrate flat `plans/NNN-*.md` to per-plan directories (a full backup is made first) |
| `nyia plans status` | Show the detected plan layout (`empty` \| `new` \| `legacy` \| `mixed`) |
| `nyia plans todo [--write]` | The generated plan inventory (alias of `nyia todo`) |
| `nyia plans status-backfill [--yes]` | Write a canonical `Status:` into plans that lack one (dry-run by default) |
| `nyia plans decisions [N] [--by X] [--since]` | Show recorded decisions for plan N (or all plans) |
| `nyia plans decision add <N> --by X --topic .. --question .. --decision .. [--options ..] [--supersedes ..]` | Record a decision |
| `nyia todo [--write]` | Show — or regenerate with `--write` — the generated plan inventory |

### Configuration

View and manage configuration.

| Flag | Description |
|------|-------------|
| `--status` | Show current configuration and overlay status |
| `--setup` | Run interactive setup wizard |
| `--path <dir>` | Work on a different project directory |

### System Operations

System-level operations.

| Flag | Description |
|------|-------------|
| `--shell` | Open interactive bash shell in container |
| `--check-requirements` | Verify Docker and system requirements |
| `--disable-exclusions` | Disable mount exclusions (mount everything) |
| `--skip-checks` | Skip startup requirement checks |

### Output Control

| Flag | Description |
|------|-------------|
| `--verbose, -v` | Enable verbose output |
| `--help, -h` | Show help message |

---

## Flag Interactions

### Required Combinations

| If you use... | You must also use... | Reason |
|---------------|---------------------|--------|
| `--create` | `--work-branch` | `--create` specifies what to create |
| `--no-cache` | `--build`* or `--build-custom-image` | Cache bypass applies to builds |
| `--base-image` | `--build-custom-image` | Base image override applies to custom builds |
| `--rag-verbose` | `--rag` | Verbose mode for RAG |
| `--rag-model` | `--rag` | Model selection for RAG |
| `--force` | `--login` | Force applies to login |

### Precedence Rules

| Flags | Winner | Behavior |
|-------|--------|----------|
| `--image` + `--flavor` | `--image` | Custom image overrides flavor |
| `--work-branch` + `--base-branch` | Both apply | Creates/switches work branch from base |

### Mutually Exclusive

| Flag A | Flag B | Reason |
|--------|--------|--------|
| `--base-image` | `--flavor` | Base image override replaces flavor selection |

### Compatible Combinations

```bash
# Work on current branch (default — no flags needed)
nyia-claude

# Work branch from specific base
nyia-claude --work-branch feature/x --create --base-branch develop

# RAG with custom model
nyia-claude --rag --rag-model nomic-embed-text --verbose

# Flavor with prompt
nyia-claude --flavor python
```

---

## Examples by Use Case

### Starting a New Feature

```bash
# Create named work branch from main
nyia-claude --work-branch feature/auth --create --base-branch main

# Or just work on current branch (default)
nyia-claude
```

### Resuming Previous Work

```bash
# Switch to existing branch
nyia-claude --work-branch feature/auth
```

### Python Development

```bash
# Use Python flavor
nyia-claude --flavor python

# Interactive mode with flavor
nyia-claude --flavor python
```

### Building Custom Images

```bash
# Build with custom overlays
nyia-claude --build-custom-image

# Force rebuild without Docker cache
nyia-claude --build-custom-image --no-cache

# Then use your custom image
nyia-claude --image nyiakeeper/claude-custom
```

### Codebase Search

```bash
# Enable RAG for semantic search
nyia-claude --rag

# Debug RAG indexing
nyia-claude --rag --rag-verbose
```

### Working on Different Project

```bash
# Work on project in different directory
nyia-claude --path /path/to/other/project
```

---

## Error Messages

### `--create requires --work-branch`

```
Error: --create requires --work-branch

The --create flag explicitly creates a branch if it doesn't exist.
Usage: nyia-assistant --work-branch feature/my-branch --create
```

**Fix**: Add `--work-branch <name>` before `--create`.

### `Branch does not exist`

```
Branch 'feature/x' does not exist locally or on remote
```

**Fix**: Either:
- Use `--create` to create it: `--work-branch feature/x --create`
- Check spelling and use an existing branch

### `Cannot use protected branch`

```
Cannot use protected branch as work branch: 'main'
```

**Fix**: Use a feature branch name like `feature/my-work` instead.

---

## Update Management

Manage Nyia Keeper installation updates and rollbacks.

### Subcommands

| Subcommand | Description |
|-----------|-------------|
| `nyia update status` | Show installed version, channel, NYIAKEEPER_HOME, and last check time |
| `nyia update list` | Show available channels (latest, alpha, beta) and recent releases |
| `nyia update check` | Manual check for updates, shows release notes if available |
| `nyia update install [target]` | Install update by channel name (`alpha`, `beta`, `latest`) or version tag |
| `nyia update rollback` | Rollback to previous version (same as `nyia rollback`) |
| `nyia update help` | Show update subcommand help |

### Channel Management

Nyia Keeper supports three update channels:

- **beta** - Pre-release builds (**default channel**)
- **latest** - Stable releases (resolves only once a stable release exists)
- **alpha** - **Deprecated & frozen** (pinned at `v0.1.0-alpha.103` as a bridge; no new alpha builds)

Switch channels with:
```bash
nyia update install beta      # Switch to beta channel (default)
nyia update install latest    # Switch to latest (stable) channel
```

> **Beta availability (fail-closed by absence):** `beta` is a first-class channel
> name, but the channel manifest carries no `beta` entry until the first beta
> release is cut. Until then, `nyia update install beta` prints a clear
> "beta is not available yet" message and exits non-zero — it **never** silently
> falls back to the stable (`latest`) channel. `nyia update list` shows `beta`
> with an availability marker.

### Backward Compatibility

Previous syntax continues to work:

| Old Syntax | Equivalent New Syntax |
|-----------|----------------------|
| `nyia update` | `nyia update install` |
| `nyia update v0.1.0-alpha.50` | `nyia update install v0.1.0-alpha.50` |
| `nyia update --list` | `nyia update list` |
| `nyia rollback` | `nyia update rollback` |

### Examples

```bash
# Check current status
nyia update status

# Check if an update is available
nyia update check

# List all available versions
nyia update list

# Install latest for current channel
nyia update install

# Install specific version
nyia update install v0.1.0-alpha.55

# Rollback after a bad update
nyia update rollback
```

---

## Shell Auto-Completion

Enable tab-completion for `nyia` and all `nyia-*` assistant commands.

### Setup

```bash
# Bash — add to ~/.bashrc
eval "$(nyia completions bash)"

# Zsh — add to ~/.zshrc
eval "$(nyia completions zsh)"
```

### What Completes

| Context | Completions |
|---------|-------------|
| `nyia <TAB>` | `config`, `exclusions`, `profile`, `git-history`, `plans`, `todo`, `update`, `list`, `status`, `clean`, `completions`, `rollback`, `logo`, `help` |
| `nyia config <TAB>` | `view`, `list`, `dump`, `get`, `project`, `global`, `help` |
| `nyia exclusions <TAB>` | `list`, `test`, `status`, `patterns`, `lockdown`, `help` |
| `nyia update <TAB>` | `status`, `list`, `check`, `install`, `rollback`, `help` |
| `nyia completions <TAB>` | `bash`, `zsh` |
| `nyia-claude <TAB>` | All runtime flags (`--status`, `--login`, `--shell`, `--rag`, etc.) |

All `nyia-*` assistant commands (`nyia-claude`, `nyia-gemini`, `nyia-codex`, `nyia-opencode`, `nyia-vibe`) share the same flag completions.

### Subcommand

| Command | Description |
|---------|-------------|
| `nyia completions bash` | Output Bash completion script to stdout |
| `nyia completions zsh` | Output Zsh completion script to stdout |
| `nyia completions` | Show usage and setup instructions |

Setup instructions are printed to stderr only when the terminal is interactive, so `eval` usage in shell RC files stays silent.

---

## Related Documentation

- [BRANCH_MANAGEMENT.md](BRANCH_MANAGEMENT.md) - Detailed branch workflow guide
- [USER_GUIDE_FLAVORS_OVERLAYS.md](USER_GUIDE_FLAVORS_OVERLAYS.md) - Flavors and overlays guide
