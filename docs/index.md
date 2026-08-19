# Nyia Keeper

**Run powerful AI coding CLIs in a box.** Claude, Gemini, Codex, OpenCode, and Vibe each run in a
Docker container that sees your project — and nothing else on your machine.

[Get started in 2 minutes →](QUICKSTART.md){ .md-button .md-button--primary }
[Why it exists →](WHY.md){ .md-button }

## Why Nyia Keeper

- **Runs in a box, not on your machine** — each assistant runs in its own Docker container against
  your project. It can't reach the rest of your machine — not your home directory, `~/.ssh`, or your
  root filesystem. *This is what "safe by default" means: a bounded blast radius — not VM-grade
  escape isolation.*
- **You curate what it sees** — [mount exclusions](MOUNT_EXCLUSIONS.md) keep secrets (`.env`, keys,
  `.aws/`, …) out of the container. The auto-detected list is a **starting point**: review it and
  **add your own private files before your first launch**. [Git history cutoff](GIT_HISTORY_CUTOFF.md)
  keeps old commits out of reach too.
- **Forces git discipline** — work runs inside a Git repo on a work branch, **never directly on
  protected branches** ([branch management](BRANCH_MANAGEMENT.md)), so a mistake — yours or the
  agent's — is recoverable and reviewable.
- **Optionally restrict the network** — by default the container has ordinary network access (the
  assistants need the internet). Opt in to [network egress control](NETWORK_EGRESS.md) to keep full
  web access while blocking the local network unless you allow it (off by default, Linux-only).
- **Built for real work** — [workspace mode](WORKSPACE.md) across multiple repos,
  [reusable work branches](BRANCH_MANAGEMENT.md), and [flavors & overlays](USER_GUIDE_FLAVORS_OVERLAYS.md)
  for custom toolchains.
- **Team resources** — share skills, personas (agents), and prompt overlays across your projects with a
  [team directory](TEAM_SHARING.md): a local folder you sync however you like (git, Dropbox, NFS).

## Find your way

| I want to… | Go to |
|---|---|
| Install and run my first assistant | [Quick Start](QUICKSTART.md) · [Installation](INSTALLATION.md) |
| Keep secrets / old history away from the AI | [Mount Exclusions](MOUNT_EXCLUSIONS.md) · [Git History Cutoff](GIT_HISTORY_CUTOFF.md) |
| Understand the security model & its limits | [Security model](THREAT_MODEL.md) |
| Compare it to Docker Sandboxes / devcontainers | [How it compares](COMPARISON.md) |
| Restrict what the container can reach on the network | [Network Egress](NETWORK_EGRESS.md) |
| Work across multiple repositories | [Workspace Mode](WORKSPACE.md) |
| Share skills / personas / prompts with my team | [Team Sharing](TEAM_SHARING.md) |
| Tell my team what changed | [Team news — /whatsup](TEAM_SHARING.md#team-news-whatsup) |
| Look up a flag or config key | [CLI Reference](CLI_REFERENCE.md) · [Configuration](CONFIGURATION.md) |
| Fix a problem | [Troubleshooting](TROUBLESHOOTING.md) |

## Open source, not open contribution

Nyia Keeper is the **public distribution** of a tool I build for myself and use daily. It's **open
source** — `AGPL-3.0-or-later OR Proprietary`. Development happens in a private repo, so this one takes
**no code contributions**, but **[Issues](https://github.com/KaizendoFr/nyia-keeper/issues) and
[Discussions](https://github.com/KaizendoFr/nyia-keeper/discussions) are open** — bug reports,
questions, and ideas are very welcome.
