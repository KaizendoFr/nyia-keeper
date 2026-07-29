# End-to-End (Real Docker) Testing

The unit suite (`tests/bats/`) runs without Docker and covers argument parsing,
mount-argument construction, config logic, and security helpers in isolation. It
**cannot** prove that a real `nyia` launch actually hides your secrets, or that a second
launch is quiet — those are properties of the assembled system: the host launcher, the
volume mounts, and the container all working together.

`tests/e2e/run.sh` closes that gap. It builds a small **test overlay on top of the
published enduser image** and launches real `nyia` containers against it, asserting real,
observable behavior — with no assistant, API key, or interactive terminal.

## What it checks (Phase 1)

1. **Mount-exclusions actually hide secrets.** The harness builds a throwaway git repo
   with planted *synthetic* secrets (`.env`, `id_rsa`, `.aws/credentials` — each holding a
   marker string, never a real credential) plus a normal `README.md`, launches `nyia`
   against it, and reads those files *from inside the container*. It asserts the secret
   marker never appears, file-excluded secrets show the `FILE EXCLUDED FOR SECURITY`
   placeholder, and the normal file **is** still readable (so a blanket mount failure
   can't pass as "secure").
2. **No "Repairing configuration" noise on a second launch** (regression guard for
   Plan 300).

### What this does and doesn't validate

Both invariants are **host-launcher** properties: the exclusions come from the mount
arguments `nyia` builds on the host, and "Repairing configuration" is host-side config
output. So the harness validates *the host launcher's behavior when driving the real
image*, plus that **the published image pulls and boots**. It does not re-test logic that
lives *inside* the image. That's the right coverage for Phase 1 — the data-safety promise
is enforced host-side — but don't read it as "the image's internals are all tested."

## How it works — overlay, not a shipped hook

The published images carry **no test hook** — they are pristine. To drive a container
headless, the harness builds a **local, throwaway overlay** (`tests/e2e/overlay/`)
`FROM` the published image. `nyia` launches the assistant by bare name, so the overlay
just prepends a directory of *provider shims* to `PATH`; when the harness sets
`NYIA_E2E_EXEC`, the shim runs that probe (after `nyia`'s full real setup) and exits.
When the variable is unset the shim execs the real CLI, so the overlay image still behaves
normally.

Consequences:

- **Nothing goes public.** The seam exists only in the local overlay, never in a shipped
  image. Even the host-side `NYIA_E2E_EXEC` forward is inert on a normal image (no hook
  reads it), and a project can't set it (Plan 310's creds allowlist rejects `NYIA_*`).
- **You test the distributed artifact.** The overlay is `FROM` the published image and the
  harness pulls it first — so a green run also confirms the image is **pullable**
  (doubles as part of the Plan 290 check).

## Requirements

- **Docker** running and reachable (`docker info` succeeds), and **bash**.
- Works on macOS (Docker Desktop), Windows (inside WSL2), and Linux.
- Network access to pull the published base image (or a local base via `--base-image`).
  If the package is private, `docker login ghcr.io` first.

## Follow-along quickstart — pull, run (macOS & Windows 10)

You run this from the **dev repo** (the private development checkout). No whole-image
build is needed — `run.sh` pulls the published image and builds the tiny overlay for you.

### macOS (Docker Desktop)

```bash
# 0. Prereqs: Docker Desktop installed and RUNNING. See docs/MACOS_SETUP.md.
docker info >/dev/null && echo "docker OK"

# 1. Get the latest code
git clone <dev-repo-url> nyia-keeper       # first time
cd nyia-keeper
git checkout dev && git pull               # every time after

# 2. Run the harness (pulls the published image, builds the overlay, tests it)
./tests/e2e/run.sh                         # expect: 3 passed, 0 failed
echo "exit=$?"                             # 0 = real pass
```

### Windows 10 (WSL2 + Docker Desktop)

Everything runs **inside a WSL2 Ubuntu shell**. Do the one-time setup in
`docs/WSL2_SETUP.md` first (install WSL2 + Ubuntu, install Docker Desktop, and enable
**Settings → Resources → WSL Integration** for your Ubuntu distro).

```bash
# Open "Ubuntu" from the Start menu (a WSL2 shell), then:
docker info >/dev/null && echo "docker OK"

# Clone inside the Linux filesystem (~/…), NOT /mnt/c/… (slow + breaks Docker mounts):
cd ~
git clone <dev-repo-url> nyia-keeper && cd nyia-keeper
git checkout dev && git pull

./tests/e2e/run.sh
echo "exit=$?"
```

### Options

| Flag | Default | Meaning |
|------|---------|---------|
| `--assistant <name>` | `codex` | Which `nyia-<assistant>` to drive. `codex`/`gemini` use API-key auth, so a dummy key passes the host gate; the shim runs before the assistant so the key is never used. |
| `--base-image <ref>` | published image for this assistant + channel | Build the overlay `FROM` this ref instead (a local dev image works). |
| `--no-pull` | off | Don't pull; use whatever base is already present locally. |
| `--edition dev\|dist` | `dev` | Launch `bin/nyia-*` (dev) or `dist/runtime/bin/nyia-*` (shipped launchers). |
| `--dry-run` | off | Build the fixture + print the plan; touch no Docker (runs anywhere; self-lint). |
| `--keep` | off | Keep the temporary fixtures on exit. |

## Reading the result

Each check prints `[PASS]` / `[FAIL]` / `[SKIP]` / `[INCONCLUSIVE]`, then a summary line
and a meaningful exit code:

| You see | Exit | Meaning | Do |
|---------|------|---------|----|
| `3 passed, 0 failed` | 0 | Real pass | Nothing — it works. |
| any `[FAIL]` | 1 | A real invariant is broken | Send me the output (it prints markers, never your secrets). |
| `[SKIP] overlay not prepared — pull failed …` | 3 | Base image couldn't be pulled | `docker login ghcr.io` (private pkg), check network, or pass `--base-image <local>` / `--no-pull`. |
| `[SKIP] docker not available` | 3 | Docker not reachable | Start Docker Desktop; on W10 check WSL integration. |
| `[INCONCLUSIVE] shim did not run …` | 3 | Container launched but the probe never fired | Usually a **version/channel skew**: the host channel ≠ the pulled image's channel, so the compat guard stops it. Align `NYIA_CHANNEL`, or pass `--base-image` matching your host channel. |

Exit `3` means **nothing was actually verified** — it must never be read as a pass.

## Prove the harness isn't a rubber stamp ("make it go red")

Confirm each check has teeth by breaking its invariant and expecting a `[FAIL]` + exit 1:

- **Exclusions** — temporarily remove a secret pattern so `.env` is no longer hidden
  (e.g. comment out the `.env` default in `create_volume_args`), then re-run. Check 1 must
  go `[FAIL]`. Revert afterwards.
- **No-Repairing** — temporarily revert the Plan 300 fix so `network-allow.conf` gets
  "repaired" every launch, then re-run. Check 2 must go `[FAIL]`. Revert afterwards.

If a check stays green after you break its invariant, the check is wrong — fix the
harness, not the product.

> **Note on `NYIA_E2E_EXEC`:** the probe runs an arbitrary shell string, visible in `ps` /
> the process environment inside the container. Never put a real secret in a probe — the
> harness only ever uses synthetic marker strings.

## Internals

- `tests/e2e/overlay/Dockerfile.e2e` — builds the throwaway overlay: generates a provider
  shim per CLI with the **real CLI's absolute path baked in at build time** (so the shim
  never resolves to itself), and prepends them to `PATH`.
- `tests/e2e/lib.sh` — environment/Docker detection, the runtime fixture builder, the
  base-image resolver (`get_image_name`), the pull-classify + overlay build, and
  `e2e_run_seam` (drives `nyia --image <overlay>` with a dummy API key and the probe,
  output fenced between `===E2E_BEGIN===` / `===E2E_END===`).
- `tests/e2e/run.sh` — arg parsing, the overlay preflight, the two checks, and the summary.
- Positive control: every probe ends by echoing `E2E_SEAM_REACHED_OK`; its absence is what
  distinguishes "shim didn't fire" (INCONCLUSIVE) from a genuine assertion result.
