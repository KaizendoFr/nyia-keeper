# Nyia Keeper Quick Start

Get up and running with AI-powered development assistants in under 2 minutes.

## Install

### Linux
```bash
curl -fsSL https://raw.githubusercontent.com/KaizendoFr/nyia-keeper/main/install.sh | bash
export PATH="$HOME/.local/bin:$PATH"
```

### macOS
```bash
curl -fsSL https://raw.githubusercontent.com/KaizendoFr/nyia-keeper/main/scripts/install-macos.sh | bash
```
See [macOS Setup Guide](docs/MACOS_SETUP.md) for Docker Desktop installation and troubleshooting.

### Windows (WSL2)
Run inside a **WSL2 terminal (Ubuntu), not PowerShell** — Nyia Keeper is a bash + Docker
tool. Install [Docker Desktop](https://docs.docker.com/desktop/install/windows-install/)
(enable the WSL2 engine + WSL Integration), then in your WSL2 terminal:
```bash
curl -fsSL https://raw.githubusercontent.com/KaizendoFr/nyia-keeper/main/install.sh | bash
export PATH="$HOME/.local/bin:$PATH"
```
See [Windows (WSL2) Setup Guide](docs/WSL2_SETUP.md). (WSL1 is not supported.)

## Choose Your Assistant

```bash
nyia list                    # Show available assistants
```

Available options: `claude`, `gemini`, `codex`, `opencode`, `vibe`

## Setup Authentication

Each assistant requires one-time authentication:

**Claude:**
```bash
nyia-claude --login          # Follow prompts to authenticate
nyia-claude --status         # Verify setup
```

**Gemini:**
```bash
nyia-gemini --login          # OAuth setup
```

**Codex:**
```bash
nyia-codex --login           # OAuth (ChatGPT) or --set-api-key for an OpenAI key
```

**OpenCode:**
```bash
nyia-opencode --status       # No authentication required
```

**Vibe (Mistral AI):**
```bash
export MISTRAL_API_KEY="your-api-key"  # Get key from console.mistral.ai
nyia-vibe --status                      # Verify setup
```

## Start Coding

Navigate to your project directory and start an interactive session:

```bash
cd /your/project
nyia-claude                  # Or nyia-gemini, nyia-codex, etc.
```

## Branch Management

By default, Nyia Keeper creates timestamped branches for your work:

```bash
nyia-claude                    # Creates: claude-2026-01-11-143052
```

For named branches:

```bash
# Create a named branch
nyia-claude --work-branch feature/my-feature --create

# Resume existing branch
nyia-claude --work-branch feature/my-feature
```

See [docs/BRANCH_MANAGEMENT.md](docs/BRANCH_MANAGEMENT.md) for detailed workflows.

## Built-in Skills

All assistants include 12 built-in skills (following the [Agent Skills](https://agentskills.io) standard), all
prefixed **`nyia-`** — type `/nyia-` to list them. Any other slash command is the assistant CLI's own or yours.

| Skill | Command | Purpose |
|-------|---------|---------|
| **nyia-kickoff** | `/nyia-kickoff` | Start a session — reconstructs state from `.nyiakeeper/` and proposes the next steps |
| **nyia-checkpoint** | `/nyia-checkpoint` | Save session state before ending or when context runs long |
| **nyia-make-a-plan** | `/nyia-make-a-plan` | Turn a goal into a phased, resumable plan under `.nyiakeeper/plans/` |
| **nyia-plan-review** | `/nyia-plan-review` | Architect-level plan review, round-tripping between assistants |
| **nyia-implement-plan** | `/nyia-implement-plan` | Execute one plan with pre-flight checks, per-step verification, regression detection |
| **nyia-run-plans** | `/nyia-run-plans` | Execute several Ready plans in safe parallel batches |
| **nyia-code-review** | `/nyia-code-review` | Pragmatic, security-first review of the code written for a plan |
| **nyia-plan-status** | `/nyia-plan-status` | "Where are we?" — a filterable table of plans by status / roadmap label |
| **nyia-show-decisions** | `/nyia-show-decisions` | The decision trail of a plan — what was decided, by whom, why |
| **nyia-share** | `/nyia-share` | Promote / demote plans between private and team-shared |
| **nyia-whatsup** | `/nyia-whatsup` | Team news — read what changed since your last session, or publish an entry |
| **nyia-overlay** | `/nyia-overlay` | Customize the assistant's Docker image with extra packages or tools |

Skills are invoked as slash commands within your assistant session.

## Power User Features

```bash
# Custom image overlays
mkdir -p ~/.config/nyiakeeper/claude/overlay
cat > ~/.config/nyiakeeper/claude/overlay/Dockerfile << 'EOF'
FROM ghcr.io/kaizendofr/nyiakeeper-claude:latest
RUN apt-get update && apt-get install -y python3-dev build-essential
EOF

nyia-claude --build-custom-image
```

## Troubleshooting

**Docker Issues:**
```bash
# Check Docker is running
docker --version
sudo systemctl start docker    # Linux
open -a Docker                  # macOS
```

**Authentication Problems:**
```bash
# Reset credentials
rm -rf ~/.config/nyiakeeper/creds/
nyia-claude --login
```

**Permission Errors:**
```bash
# Fix Docker permissions (Linux only)
sudo usermod -aG docker $USER
newgrp docker
```

## What's Next?

- **Full Documentation**: [GitHub Repository](https://github.com/KaizendoFr/nyia-keeper)
- **Advanced Usage**: `nyia-claude --help`
- **Custom Overlays**: Check `~/.config/nyiakeeper/claude/overlay/`
- **macOS Setup**: [docs/MACOS_SETUP.md](docs/MACOS_SETUP.md)

---

*Runtime distribution - optimized for production deployment*
