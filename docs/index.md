# Nyia Keeper

**Multi-Assistant AI on a leash.** Run Claude, Gemini, Codex, OpenCode, and Vibe inside
safe, dockerized development environments — with the guardrails to keep an AI assistant
from touching anything it shouldn't.

[Get started in 2 minutes →](QUICKSTART.md){ .md-button .md-button--primary }
[Choose an assistant →](CHOOSING_AN_ASSISTANT.md){ .md-button }

## Why Nyia Keeper

- **Sandboxed by default** — each assistant runs in its own container against your project,
  not your whole machine.
- **You decide what it sees** — [mount exclusions](MOUNT_EXCLUSIONS.md) hide secrets and
  sensitive files; [git history cutoff](GIT_HISTORY_CUTOFF.md) hides old commits.
- **You decide what it can reach** — opt-in [network egress control](NETWORK_EGRESS.md)
  keeps full web access but restricts the local network to an allowlist.
- **Built for real work** — [workspace mode](WORKSPACE.md) across multiple repos,
  [reusable work branches](BRANCH_MANAGEMENT.md), and [flavors & overlays](USER_GUIDE_FLAVORS_OVERLAYS.md)
  for custom toolchains.
- **Shareable** — a [team directory](TEAM_SHARING.md) and a [marketplace](MARKETPLACE.md)
  for sharing skills, agents, and prompts.

## Find your way

| I want to… | Go to |
|---|---|
| Install and run my first assistant | [Quick Start](QUICKSTART.md) · [Installation](INSTALLATION.md) |
| Pick the right assistant | [Choosing an Assistant](CHOOSING_AN_ASSISTANT.md) |
| Keep secrets / old history away from the AI | [Mount Exclusions](MOUNT_EXCLUSIONS.md) · [Git History Cutoff](GIT_HISTORY_CUTOFF.md) |
| Restrict what the container can reach on the network | [Network Egress](NETWORK_EGRESS.md) |
| Work across multiple repositories | [Workspace Mode](WORKSPACE.md) |
| Share skills/agents/prompts with my team | [Team Sharing](TEAM_SHARING.md) · [Marketplace](MARKETPLACE.md) |
| Look up a flag or config key | [CLI Reference](CLI_REFERENCE.md) · [Configuration](CONFIGURATION.md) |
| Fix a problem | [Troubleshooting](TROUBLESHOOTING.md) |
