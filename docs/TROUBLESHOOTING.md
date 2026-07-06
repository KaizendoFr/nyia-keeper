# Troubleshooting

Common first-run issues and fixes. If something here doesn't help, run
`nyia-<assistant> --check-requirements` for a diagnostic.

## "Docker is not running" / cannot connect to the daemon

Start Docker (Docker Desktop, or `sudo systemctl start docker` on Linux) and confirm:

```bash
docker info
```

On Linux, add your user to the `docker` group (then log out/in):

```bash
sudo usermod -aG docker "$USER"
```

## "Not in a Git repository"

The assistant works on a git branch, so your project must be a repo:

```bash
git init && git add . && git commit -m "initial commit"
```

Or bypass the check for a throwaway run with `--skip-checks`.

## `nyia` / `nyia-claude` not found

The installer adds Nyia Keeper to your `PATH` via an env file — activate it (and add the
line to your shell profile):

```bash
# Linux
source ~/.config/nyiakeeper/env

# macOS (the launchers install to ~/.local/bin)
export PATH="$HOME/.local/bin:$PATH"
```

## Assistant says it's not authenticated

Authenticate once per assistant — `nyia-<assistant> --login` (OAuth/device) or
`--set-api-key` (key-based). See [Quick Start → Authentication](QUICKSTART.md#setup-authentication).

## restrict-local won't launch on macOS / Windows

[Network egress](NETWORK_EGRESS.md) enforcement is native-Linux only for now; on Docker
Desktop / WSL2 it refuses with a clear message. Set `network_egress_policy=off` there.

## Still stuck?

Open an issue on the [GitHub repository](https://github.com/KaizendoFr/nyia-keeper).
