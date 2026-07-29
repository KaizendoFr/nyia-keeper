# Requirements

Nyia Keeper runs your AI coding assistants inside Docker containers. To use it you need
**Docker** and **Git**, and you launch assistants **inside a Git repository**.

## What you need

| Requirement | Why | Check |
|-------------|-----|-------|
| **Docker** (running) | Assistants run in containers | `docker info` |
| **Your user in the `docker` group** (Linux) | So Nyia can talk to the Docker daemon without `sudo` | `docker run --rm hello-world` |
| **Git** | To install the runtime and to give AI agents a safety net (work branches, diffs) | `git --version` |
| **A Git repository** | AI agents modify files — Git lets you review and undo | `git rev-parse --git-dir` |

If Docker can't be reached, Nyia fails fast with a clear message **before** it tries to pull an
image — so a permission problem no longer looks like "image not found".

## Linux

1. **Install Docker:** <https://docs.docker.com/engine/install/> (or `curl -fsSL https://get.docker.com | sh`).
2. **Start it:** `sudo systemctl enable --now docker`.
3. **Add yourself to the `docker` group** (this is the most common first-run problem):
   ```bash
   sudo usermod -aG docker $USER
   # then log out and back in, or in the current shell:
   newgrp docker
   docker run --rm hello-world   # verify
   ```
4. **Install Git:** `sudo apt install git` (Debian/Ubuntu) · `sudo dnf install git` (Fedora/RHEL).

## macOS

- Install **Docker Desktop** (or Colima) and make sure it's running.
- Git ships with the Xcode command-line tools: `xcode-select --install`, or `brew install git`.
- See [macOS setup](MACOS_SETUP.md) for details.

## Windows / WSL2

Nyia Keeper needs **WSL2** (WSL1 lacks Docker socket integration). Install Docker Desktop and enable
WSL integration for your distro. Full walkthrough: [WSL2 setup](WSL2_SETUP.md).

## Running outside a Git repo

The Git-repo check is a safety default (AI agents change files). If you knowingly want to run in a
non-Git directory, pass `--skip-checks` — you lose the work-branch/undo safety net.

## Troubleshooting

- **`Cannot connect to the Docker daemon`** → Docker isn't running, or you're not in the `docker`
  group (see Linux step 3).
- **`Not in a Git repository`** → run inside a repo, or `--skip-checks` to bypass.
- More: [Troubleshooting](TROUBLESHOOTING.md).
