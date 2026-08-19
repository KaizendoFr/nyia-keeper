# How Nyia compares

Nyia Keeper is a **workflow + data-control layer** for running AI coding assistants — not a new
isolation technology. The honest one-liner: **if you need a hardware escape boundary, use a microVM
(Docker Sandboxes) — possibly *underneath* Nyia.** What Nyia adds is keeping the agent off your
secrets, a git-safe reviewable workflow, and one setup across several assistants.

| | **Nyia Keeper** | **Docker Sandboxes** | **Dev Containers** | **Raw CLI** (agent on host) |
|---|---|---|---|---|
| Isolation boundary | Container (shares host kernel) | **microVM (hardware)** | Container | **None** — full host access |
| Hides *your secrets* from the agent | **Yes** — auto-excluded + you curate | No — mounts the project wholesale | No | No |
| Git-safe by default (protected branches) | **Yes** | No | No | No |
| Network egress control | Opt-in allowlist (Linux) | Yes (its own) | No | No |
| Reviewed workflow (plan → review → checkpoint) | **Yes, shipped** | No | No | No |
| Multi-assistant (Claude/Gemini/Codex/OpenCode/Vibe) | **Yes (5)** | Runs agents, not an orchestration layer | No | One at a time |
| Runs | On your machine | On your machine | On your machine / IDE | On your machine |
| Setup cost | Low (Docker) | Higher (microVM) | Medium | None |

## When to use which

- **Raw CLI** — you trust the tool with your whole machine and just want speed. Nyia exists because
  that made the author uncomfortable.
- **Dev Containers** — you want a reproducible toolchain for humans; hiding secrets from an agent and
  git guardrails aren't the goal.
- **Docker Sandboxes** — you need a true escape boundary (untrusted code, hostile input). It mounts
  your project wholesale, so it does **not** hide your secrets from the agent — pair it *under* Nyia
  if you want both.
- **Nyia Keeper** — you want the agent to work on your project **without seeing your secrets**, on a
  **git-safe** branch, with a **reviewable** workflow, across **several assistants** — on your own
  machine, with ordinary Docker.

> Nyia cedes VM-grade escape isolation on purpose (a container shares the host kernel — see the
> [Security model](THREAT_MODEL.md)). It competes on **data control and workflow**, not on the
> isolation boundary.
