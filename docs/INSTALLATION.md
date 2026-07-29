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

The installer follows the **stable (`latest`) channel** by default. To track a
pre-release channel instead, pass a channel name or set `NYIA_CHANNEL`:

```bash
# Positional channel name
curl -fsSL https://raw.githubusercontent.com/KaizendoFr/nyia-keeper/main/install.sh | bash -s -- alpha
curl -fsSL https://raw.githubusercontent.com/KaizendoFr/nyia-keeper/main/install.sh | bash -s -- beta

# Or via env var
NYIA_CHANNEL=beta bash -c "$(curl -fsSL https://raw.githubusercontent.com/KaizendoFr/nyia-keeper/main/install.sh)"
```

Selection precedence (highest first): **positional version tag** →
`NYIA_VERSION` → `NYIA_CHANNEL` → the installer's build-time default (`latest`).
The chosen channel is written to the installed `CHANNEL` state so `nyia update`
keeps following it.

Channels: `latest` (stable, default), `alpha`, and `beta` (a peer of `alpha`).
Channel selection at install time is supported by the **Linux** installer. On
**macOS**, prefer pinning an explicit version tag (see [macOS Setup](MACOS_SETUP.md)),
then use `nyia update install <channel>` afterwards to track a channel.

> **macOS behavior change (Plan 312c).** The macOS installer does not resolve a
> prerelease channel manifest, so requesting `alpha` or `beta` **by name** —
> positionally (`install-macos.sh beta`) or via `NYIA_CHANNEL=beta` — now
> **fails closed** with a clear message and a non-zero exit, instead of silently
> ignoring the request and installing the build's default tag. `latest` is still
> accepted by name and maps to GitHub's `/releases/latest`; to install a
> prerelease on macOS, pin its exact version tag.

> **Beta is fail-closed by absence.** `beta` is a valid channel name, but it has
> no manifest entry until the first beta release is cut. Requesting `beta` before
> then prints a clear "not available yet" message and fails — it never falls back
> to installing `latest`.

## Verify

```bash
nyia list            # show available assistants
nyia-claude --check-requirements   # verify Docker, git, permissions
```

Next: [Quick Start →](QUICKSTART.md)
