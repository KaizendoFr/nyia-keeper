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

## Channels

The installer follows the **`beta` channel by default** (beta is the default
channel; the `alpha` channel is deprecated and frozen). To install a specific
version or a different channel, pass a channel name or set `NYIA_CHANNEL`:

```bash
# Explicit channel name
curl -fsSL https://raw.githubusercontent.com/KaizendoFr/nyia-keeper/main/install.sh | bash -s -- beta
curl -fsSL https://raw.githubusercontent.com/KaizendoFr/nyia-keeper/main/install.sh | bash -s -- latest

# Or via env var
NYIA_CHANNEL=beta bash -c "$(curl -fsSL https://raw.githubusercontent.com/KaizendoFr/nyia-keeper/main/install.sh)"
```

Selection precedence (highest first): **positional version tag** →
`NYIA_VERSION` → `NYIA_CHANNEL` → the installer's default (**`beta`**). The chosen
channel is written to the installed `CHANNEL` state so `nyia update` keeps
following it.

Channels: **`beta` (default)**, `latest` (stable — resolves only once a stable
release exists), and `alpha` (**deprecated & frozen** — pinned at
`v0.1.0-alpha.103` as a bridge for existing installs; it no longer receives
updates and is refused by name on macOS). Missing/legacy `CHANNEL` state resolves
to **beta** everywhere (update channel and container image tag alike).

> **macOS.** The macOS installer resolves the **beta** channel (and the default)
> directly from GitHub `/releases` — filtered to real `-beta.N` tags, both runtime
> assets verified, and **fail-closed** (never a silent alpha/stable/draft
> fallback). `latest` maps to `/releases/latest`; `alpha` is refused (deprecated);
> an exact version tag pins that tag.

## Verify

```bash
nyia list            # show available assistants
nyia-claude --check-requirements   # verify Docker, git, permissions
```

Next: [Quick Start →](QUICKSTART.md)
