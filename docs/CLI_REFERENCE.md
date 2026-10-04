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
| `--mcp-auth` | Auth | - | - | OAuth an MCP server (OpenCode, Linux only) |
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
| `--mcp-auth [name]` | Authenticate an OAuth-protected **remote MCP server** (OpenCode; **native Linux only** — see below) |
| `--profile <name>` | Use a named profile: a separate account. Auth-only (the default) keeps your global skills/agents/rules; a persona has its own. See [Profiles](PROFILES.md). |

#### OAuth MCP servers (`--mcp-auth`) — native Linux only

A *remote* MCP server (`"type": "remote"`) usually authenticates with OAuth, which needs a browser. The
assistant runs in a container with no browser, so the flow works like this:

```bash
nyia-opencode --mcp-auth               # or: --mcp-auth <server-name>
# OpenCode prints an authorization URL — open it in your own browser.
# Credentials are then stored and reused; you do not re-authenticate every run.
```

Add a server first. The easiest way is to let OpenCode write the file for you:

```bash
nyia-opencode --shell
opencode mcp add my-server --url https://example.com/mcp
opencode mcp auth list                 # per-server status
```

That writes your **global** config (`~/.config/nyiakeeper/opencode/opencode.json` on the host, which
Nyia mounts as OpenCode's config dir), so the server is available in every project. To scope it to one
project instead, put it in that project's own `opencode.json` — and `.gitignore` it if it is personal
rather than something the team should get.

⚠️ **If you write the file by hand, mind OpenCode's own hint.** When nothing is configured, OpenCode
prints an example to add — but it shows a **fragment**:

```jsonc
// NOT a complete file — pasting this alone is invalid JSON
"mcp": {
  "my-server": { "type": "remote", "url": "https://example.com/mcp" }
}
```

Pasted into an empty file that has no enclosing braces, and **OpenCode silently ignores a config it
cannot parse** — so you get the same "No OAuth-capable MCP servers configured" message with no hint
that your file was rejected. A complete file:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "my-server": { "type": "remote", "url": "https://example.com/mcp", "enabled": true }
  }
}
```

Check it parses before launching: `python3 -m json.tool opencode.json`.

**Sharing MCP or model config with a team?** Use the project's own `opencode.json`, committed to the
repository — that is OpenCode's native mechanism and everyone who clones gets it. Nyia's `team_dir`
deliberately carries **skills, agents and prompts only, never config**: a shared source must not be able
to silently add an MCP server, redirect a provider's `baseURL`, or change permissions. See
[THREAT_MODEL.md](THREAT_MODEL.md) for the equivalent note about repository-supplied config — the same
review applies, which is the point of putting it somewhere visible.

**What the MCP server must support.** OpenCode mints its own OAuth client at auth time via **RFC 7591
dynamic client registration**, so an authorization server that does not advertise a
`registration_endpoint` fails with *"Incompatible auth server: does not support dynamic client
registration"*. DCR is **optional** in the MCP spec, so a perfectly compliant server can hit this.
**It is not a dead end** — give OpenCode a pre-registered client instead and the DCR path is never
taken:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "my-server": {
      "type": "remote",
      "url": "https://example.com/mcp",
      "oauth": { "clientId": "{env:MY_MCP_CLIENT_ID}" }
    }
  }
}
```

**Try any value first — you may not need anything from the vendor.** Plenty of MCP servers never
validate the client id, because the server is *itself* the OAuth client to an upstream identity
provider and merely brokers the flow. In that design `"clientId": "opencode"` is enough, and the
server's own registered client is what talks to the real IdP. **This is not theoretical — it is the
path verified end to end against a real third-party OAuth MCP server**, including the token exchange,
with an arbitrary client id and no vendor involvement. Check before asking anyone for
credentials — it is two requests against public discovery metadata:

```bash
curl -s https://example.com/.well-known/oauth-protected-resource        # which AS serves this resource
curl -s https://<as-host>/.well-known/oauth-authorization-server        # does it list registration_endpoint?
# then: does /authorize accept an arbitrary client id?
curl -s -o /dev/null -D - -G https://<as-host>/authorize \
  --data-urlencode response_type=code --data-urlencode client_id=probe \
  --data-urlencode 'redirect_uri=http://127.0.0.1:19876/mcp/oauth/callback' \
  --data-urlencode code_challenge_method=S256 --data-urlencode code_challenge=<43-char-base64url>
```

A **302** means the id was accepted and you can stop there. An error means the server keeps a client
allow-list, and *then* ask the vendor for a `client_id` (plus `clientSecret` only if the client is
confidential — if the metadata says `"token_endpoint_auth_methods_supported": ["none"]`, there is no
secret to issue) with the redirect URI **`http://127.0.0.1:19876/mcp/oauth/callback`** registered,
`authorization_code` + `refresh_token` grants and PKCE `S256`. That is a far smaller ask than
implementing DCR. `callbackPort` and `redirectUri` change those defaults if they insist on others.

⚠️ `"oauth": {}` is **not** the same as omitting it and **not** the same as `false`: an empty object
leaves auto-detection on with no client id, so DCR is still attempted. Use `"oauth": false` to turn
OAuth off outright — which is what you want if the server authenticates with a static token instead:

```json
{ "mcp": { "my-server": { "type": "remote", "url": "https://example.com/mcp",
    "oauth": false, "headers": { "Authorization": "Bearer {env:MY_API_KEY}" } } } }
```

Diagnose either path with `opencode mcp debug <name>` inside the box: it reports the status code, the
`WWW-Authenticate` header, and whether a client id was found.

**Confirm it persisted — the check that actually matters.** Authenticating proves the flow works; it
does not prove the credential survives. Run `opencode mcp auth list` in a **fresh** session (exit, then
launch again) and look for the tick rather than re-reading the output of the session that just
authenticated. Persistence comes from Nyia pointing OpenCode's XDG data tree at the mounted global
config dir, so a credential obtained on one machine stays on that machine — authenticate once per
machine, not once per session.

**Why native Linux only.** OpenCode binds its OAuth callback to `127.0.0.1:19876` *inside* the
container. On native Linux Nyia uses `--network host`, so that loopback is your machine's and the
browser reaches it. On Docker Desktop (macOS / WSL2) there is no host networking, and Docker's port
forwarding reaches the container's bridge address rather than its loopback — so the browser cannot
deliver the authorization code. MCP OAuth also has no device-code flow, so the workaround used for
`codex --login` does not apply. `--mcp-auth` therefore refuses on those platforms with an explanation.

This is a scope decision, not a technical dead end: a port relay would solve it. **If you need macOS or
Windows support, please open an issue** and it can be built.

**Not available under `restrict-local`.** `--mcp-auth` launches its container through the same path as
`--shell`, which is refused when `network_egress_policy=restrict-local` because that path skips the
entrypoint that installs the egress firewall. The refusal is deliberate — permitting it would run an
*unfirewalled* container in a project that asked for restriction — but the message mentions the debug
shell, so it can read oddly if you only typed `--mcp-auth`. Authenticate with the policy off for that
project, then turn it back on; the stored credential persists.

**What the server can see — read this before authenticating one.** A remote MCP server is a *third
party in your session*. When the assistant calls one of its tools, the call carries whatever the model
puts in the arguments — which in practice can include file contents, paths and excerpts of your
conversation. Nyia cannot scope that: it does not sit between the assistant and the server, and it has
no way to know what a given tool call will contain. The credential `--mcp-auth` stores is a **standing
grant** — it persists across runs by design, and revoking it is done at the server, not here.

So authenticating a remote MCP server is a trust decision about **its operator**, not just a
connection. Prefer servers you or your organisation run. If you want the exposure bounded, add the
server to a single project's config rather than your global one, so it is not present in every session.
This is distinct from the *planted-config* risk in [THREAT_MODEL.md](THREAT_MODEL.md) — that one is
about a repository adding a server you never chose; this one is about a server you chose on purpose.

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
skills (`/nyia-make-a-plan`, `/nyia-implement-plan`, `/nyia-plan-review`, `/nyia-code-review`) read and write them. The
command is `nyia plans` (plural).

`nyia` runs on the **host only** — it is never inside the assistant container. The skills work with the
files directly (a plan's `Status:` line, `decisions.md` entries, the read-only `todo.md`); the host regenerates
`todo.md` automatically at every launch and after every session. The file formats are the contract:
[PLAN_FILE_CONTRACT.md](PLAN_FILE_CONTRACT.md). Decisions are recorded by appending an entry to a plan's
`decisions.md` in that format (the former `nyia plans decision add` command was removed in Plan 337).
Built-in skills are Nyia-owned and refreshed on every upgrade — customize through your own skills, a team
directory or an overlay, never by editing a shipped copy.

| Command | Description |
|---------|-------------|
| `nyia plans migrate [--dry-run\|--yes]` | Migrate flat `plans/NNN-*.md` to per-plan directories, or finalize a migration that stopped early (a full backup is made first). Reviews whose plan number has no body are routed to the nearest exact plan or left flat and named in `plans/migration-notes.md` — they never block |
| `nyia plans status` | Show the detected plan layout (`empty` \| `new` \| `legacy` \| `mixed`), whether the migration is finalized (`.layout-v2`), and any directories under `plans/` that are not plan directories (nested trees, empty numbered dirs) |
| `nyia plans todo [--write]` | The generated plan inventory (alias of `nyia todo`) |
| `nyia plans status-backfill [--yes]` | Write a canonical `Status:` into plans that lack one (dry-run by default) |
| `nyia plans decisions [N] [--by X] [--since]` | Show recorded decisions for plan N (or all plans); a malformed hand-edited entry is named as a warning, the rest still renders |
| `nyia todo [--write]` | Show — or regenerate with `--write` — the generated plan inventory (also regenerated automatically at launch and after each session; a hand-written `todo.md` is never overwritten) |

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

### Which versions can I install?

`nyia update list` shows the versions that are **installable**: your channel's current version plus
the newest 4 releases of that channel, and every stable release, with the current channel pointers.
(The channel's own version is always kept, so it is shown even when it is older than those 4.) Older
releases still exist on GitHub but their container images are pruned, so they are hidden —
`nyia update install <version>` refuses a version whose images are gone rather than installing a
dist that cannot launch. That check applies to releases published with per-version image tags
(v0.1.0-beta.10 onwards); for older releases it cannot tell, so it installs and warns.

**Switching a version switches the image too.** Since v0.1.0-beta.9 each release publishes
per-version image tags, and the launcher runs the image belonging to your *installed* version — so
going back to a retained version gives you that version's container, not just its host scripts.
When two releases share the same image (a dist-only release rebuilds nothing), it is one image
carrying several tags: Docker fetches a manifest and no layers, so the switch is near-instant.
Installs older than v0.1.0-beta.9 predate per-version tags and keep following the channel image.
If a version's image is no longer published, the launcher warns once and falls back to the channel
image rather than refusing to start; an image you chose explicitly (`--image`, `NYIA_IMAGE_TAG`) is
never silently replaced.

If a release turns out to be bad, the maintainer moves the channel back to the previous retained
version. Your images follow on the next launch, and `nyia update` offers you the matching dist
("the channel was rolled back to …"). `nyia update rollback` is different: it restores *your own*
previous install.

