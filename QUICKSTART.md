# Nyia Keeper Quick Start

Get up and running with AI-powered development assistants in under 2 minutes.

## Install

### Linux
```bash
curl -fsSL https://raw.githubusercontent.com/KaizendoFr/nyia-keeper/main/install.sh | bash
source ~/.config/nyiakeeper/env
```

### macOS
```bash
curl -fsSL https://raw.githubusercontent.com/KaizendoFr/nyia-keeper/main/scripts/install-macos.sh | bash
```
See [macOS Setup Guide](docs/MACOS_SETUP.md) for Docker Desktop installation and troubleshooting.

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
nyia-codex --setup           # API key setup
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

All assistants include 5 built-in skills (following the [Agent Skills](https://agentskills.io) standard):

| Skill | Command | Purpose |
|-------|---------|---------|
| **kickoff** | `/kickoff` | Start a session - reconstructs state from `.nyiakeeper/` files |
| **make-a-plan** | `/make-a-plan` | Create a phased execution plan with atomic steps |
| **implement-plan** | `/implement-plan` | Execute a plan with pre-flight validation, per-step verification, and regression detection |
| **plan-review** | `/plan-review` | Architect-level plan review between agents (e.g., Claude reviews Codex's plan) |
| **checkpoint** | `/checkpoint` | Save session state before context compaction or shutdown |

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
