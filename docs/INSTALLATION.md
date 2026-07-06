# Installation

Nyia Keeper needs **Docker** and **git**. Pick your platform below, then head to the
[Quick Start](QUICKSTART.md) to launch your first assistant.

## Requirements

- **Docker** — Docker Engine (Linux) or Docker Desktop (macOS / Windows).
- **git** — your projects must be git repositories (the assistant works on a branch).
- **bash** — Linux/macOS ship it; on Windows use WSL2.

## Linux

```bash
curl -fsSL https://raw.githubusercontent.com/KaizendoFr/nyia-keeper/main/install.sh | bash
```

This installs Nyia Keeper to `~/.local/nyiakeeper` and writes a PATH entry to
`~/.config/nyiakeeper/env`. Activate it (and add this line to your shell profile):

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Docker Engine must be installed and running (`docker info` should succeed), and your user
should be in the `docker` group.

## macOS

Install Docker Desktop, then run the same installer as Linux. See the
[macOS Setup guide](MACOS_SETUP.md) for Docker Desktop installation, Apple-Silicon notes,
and troubleshooting.

## Windows (WSL2)

Nyia Keeper runs inside WSL2 with Docker Desktop's WSL2 backend. See the
[Windows (WSL2) Setup guide](WSL2_SETUP.md) for the full walkthrough.

## Verify

```bash
nyia list            # show available assistants
nyia-claude --check-requirements   # verify Docker, git, permissions
```

Next: [Quick Start →](QUICKSTART.md)
