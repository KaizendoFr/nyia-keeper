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
export PATH="$HOME/.local/bin:$PATH"

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

## "The channel was rolled back to …"

A release was withdrawn and the channel now points at the previous version. Your container images
follow automatically on the next launch (the launcher re-pulls the channel tag). Accept the prompt,
or run `nyia update install <version>`, to bring your host side in line. Nothing is broken — you are
being moved back to the last good release.

## "That version's images are no longer published"

`nyia update install <old-version>` refuses versions whose images were pruned: only your channel's
current version plus the newest 4 of that channel are kept (plus every stable one). Run
`nyia update list` to see what is installable. The refusal needs per-version image tags, which
releases from v0.1.0-beta.10 onwards carry; for anything older the check cannot tell and the
install proceeds with a warning. If you need an exact old version, pin the image tag instead:
`NYIA_IMAGE_TAG=v0.1.0-beta.7 nyia-claude` — that only works while that pinned tag still exists.

## "Falling back to the channel image"

Your installed version's image is no longer published — usually because retention pruned it (only
the channel's current version plus the newest 4 are kept). The launcher warns once and starts with
the channel image instead of refusing, so you are never stranded; the container may differ from your
installed host scripts. Run `nyia update list` and move to a listed version to get back to a matched
pair.

You will NOT see this for an image you selected yourself: an explicit `--image` or
`NYIA_IMAGE_TAG` that cannot be pulled is reported as that image failing, never silently swapped.
A timeout or an authentication error does not trigger the fallback either — only a definitive
"this tag does not exist" does, so a flaky network cannot quietly move you to a different version.

## `--list-images` says "No images found" but the assistant runs

Fixed in Plan 344: the listing only matched locally built images (`nyiakeeper/<name>`), never the
published ones (`ghcr.io/kaizendofr/nyiakeeper-<name>`). Update to a build that includes the fix.
