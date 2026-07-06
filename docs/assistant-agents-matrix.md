# Assistant Agent Persona Matrix

Last verified: 2026-02-22

This document describes agent persona capabilities for each assistant supported by Nyia Keeper.

## Nyia Keeper Abstraction

Nyia provides two optional flags for agent persona management:

| Flag | Description |
|------|-------------|
| `--agent <name>` | Select an agent persona for the session |
| `--list-agents` | List available agent personas (host-side discovery) |

### Scope Precedence

1. **Session override** (`--agent <name>`) — highest priority
2. **Project-local** agent definitions (assistant-specific project path)
3. **Global user** agent definitions (assistant-specific global path)
4. **Assistant default** behavior (no explicit persona)

### Unsupported Behavior

- If an assistant does not support `--agent`, Nyia prints guidance and continues with the default launch behavior. No hard error.
- If an assistant does not support `--list-agents`, Nyia prints guidance and returns success.

---

## Per-Assistant Capabilities

### Claude Code (Anthropic)

| Feature | Support | Details |
|---------|---------|---------|
| `--agent <name>` | Direct mapping | Maps to `claude --agent <name>` |
| `--list-agents` | File-based discovery | Scans `.claude/agents/` and `~/.claude/agents/` |
| In-session switching | `/agents` slash command | Native Claude feature |
| Agent format | Markdown | Frontmatter with `name`, `description`, optional `tools` |

**Agent paths:**
- Project: `.claude/agents/*.md`
- Global: `~/.claude/agents/*.md` (mounted from host `~/.config/nyiakeeper/claude/agents/`)

### Codex CLI (OpenAI)

| Feature | Support | Details |
|---------|---------|---------|
| `--agent <name>` | Guidance-only | No CLI flag; prints manual instructions |
| `--list-agents` | Guidance-only | Points to config file location |
| In-session switching | `/agent` slash command | Native Codex feature |
| Agent format | TOML config | `[agents.<name>]` sections in `~/.codex/config.toml` |

**Why guidance-only:** Codex does not expose a top-level `--agent` CLI flag. Agent selection requires interactive `/agent` commands or pre-configured `config.toml` sections.

### OpenCode

| Feature | Support | Details |
|---------|---------|---------|
| `--agent <name>` | Direct mapping | Maps to `opencode --agent <name>` |
| `--list-agents` | File-based discovery | Scans `.opencode/agents/` and `~/.config/opencode/agents/` |
| In-session switching | Tab key, `@` mention | Native OpenCode feature |
| Agent format | Markdown or JSON | `.md` and `.json` definitions |

**Agent paths:**
- Project: `.opencode/agents/*.md`, `.opencode/agents/*.json`
- Global: `~/.config/opencode/agents/` (mounted from host config)

### Vibe (Mistral)

| Feature | Support | Details |
|---------|---------|---------|
| `--agent <name>` | Direct mapping | Maps to `vibe --agent <name>` |
| `--list-agents` | File-based discovery | Scans `~/.vibe/agents/` |
| In-session switching | Shift+Tab | Native Vibe feature |
| Agent format | TOML | `~/.vibe/agents/*.toml` |

**Built-in agents:** `default`, `plan`, `accept-edits`, `auto-approve`

**Agent paths:**
- Global: `~/.vibe/agents/*.toml` (mounted from host config)
- Config: project `.vibe/config.toml` overrides global `~/.vibe/config.toml`

### Gemini

| Feature | Support | Details |
|---------|---------|---------|
| `--agent <name>` | Not supported | Out of scope for first implementation |
| `--list-agents` | Not supported | Out of scope for first implementation |

---

## Container Boundary

Nyia runs on the host; assistants run inside Docker containers. The agent selection mechanism works as follows:

1. **Host-side parser** parses `--agent <name>` and stores it in `NYIA_AGENT`
2. **Host-side launcher** passes `NYIA_AGENT` as a Docker env var into the container
3. **Container entrypoint** reads `NYIA_AGENT` and maps it to the assistant's native flag
4. **`--list-agents`** runs entirely host-side by scanning mounted paths — no container needed

Agent definition files are accessible from the host because:
- Project-local paths (`.claude/agents/`) are in the project directory, which is mounted into the container
- Global paths (`~/.claude/agents/`) are in the Nyia config directory, also mounted into the container

---

## Source Anchors

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code/cli-usage)
- [Claude Code Sub-agents](https://docs.anthropic.com/en/docs/claude-code/sub-agents)
- [Codex Multi-agent](https://developers.openai.com/codex/multi-agent)
- [Codex Config](https://developers.openai.com/codex/config-basic)
- [OpenCode Agents](https://opencode.ai/docs/agents/)
- [OpenCode CLI](https://opencode.ai/docs/cli/)
- [Vibe Agents & Skills](https://docs.mistral.ai/mistral-vibe/agents-skills)
- [Vibe Configuration](https://docs.mistral.ai/mistral-vibe/introduction/configuration)
