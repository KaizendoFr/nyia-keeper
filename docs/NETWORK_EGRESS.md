# Assistant Network Egress Policy

Control what the assistant container can reach on the network. By default the
container has unrestricted network access. Opt in to **restrict-local** to keep
**full web egress** while **restricting local-network access** to a user-editable
allowlist — so the assistant can reach a specific dev/test container (e.g. an SSH
test sidecar) but not the rest of your LAN.

> **Opt-in, default off.** Nothing changes unless you enable it.

```bash
# Enable for a project (or globally / per assistant, like any nyia config key):
nyia config project network_egress_policy=restrict-local

# Back to default (unrestricted):
nyia config project network_egress_policy=off
```

`network_egress_policy` is a standard `nyia config` key: `off` | `restrict-local`,
default `off`, validated, and visible in `nyia config view`. It follows normal scope
precedence (CLI → project → global → team → default).

## What the default (`off`) does — and doesn't — cover

The container keeps the assistant off your **filesystem** (that's the box — see
[Why Nyia Keeper](WHY.md)); the network is a **separate axis**. With `network_egress_policy=off`
(the default) the container has ordinary outbound access, so know the two things it does **not** stop:

- **Exfiltration.** Anything inside the container (your project, minus [excluded
  files](MOUNT_EXCLUSIONS.md)) can in principle be sent out — `curl`, a package post-install hook, a
  `git push`. Excluding secrets shrinks *what* can leak; egress control shrinks *where* it can go.
- **Local-network reach.** The container can reach your LAN, services on your host, and cloud metadata
  (`169.254.169.254`). On **native Linux the default is `--network host`** (see below), so loopback and
  the whole LAN are reachable — a prompt-injected "test the API" can become lateral movement.

Turn on `restrict-local` when that matters (corporate network, sensitive repo, cloud VM). Note the
**enforcement is Linux / nftables-based**; on macOS/WSL2 the network mode already uses a bridge, but the
firewall variant differs — see the Phase A/B notes below.

## What restrict-local does (Phase A: network substrate)

Today, native-Linux launches use `--network host` — the container shares the host's
network stack and can reach all of loopback **and the entire LAN**. That is the
opposite of the goal, and it means any in-container firewall would edit the *host*
firewall. So restrict-local first moves the container off host networking into its
**own network namespace**:

- **Native Linux**: the assistant launches on a dedicated bridge network
  (`nyia-egress`) instead of `--network host`, with
  `--add-host=host.docker.internal:host-gateway` so host services stay reachable.
  The bridge is created on demand; if it cannot be created, the launch is **refused
  (fail-closed)**.
- **Docker Desktop / WSL2**: already uses a bridge, so the network *mode* is
  unchanged here — only `host.docker.internal` is added. (The firewall in Phase B is
  what differs.)
- **off**: byte-for-byte today's behavior (`--network host` on native Linux).

### RAG / ollama still works

`detect_ollama_host()` resolves `host.docker.internal` first (provided via
host-gateway), then `172.17.0.1`, so ollama-backed RAG continues to work on the
bridge. A preset `OLLAMA_HOST` (`host[:port]` in the global `opencode.conf`, Plan 340) is
probed *before* auto-detection: under `restrict-local` the ollama exception covers
**`host-gateway:11434` only, and only when RAG is on** — a LAN address (`192.168.x.x`) is
dropped unless you add it to `network-allow.conf`, while a **public** Ollama URL is
reachable by design (public egress is allowed). When the preset is unreachable the
launcher says so and falls back to auto-detection; when it is reachable but lacks the
embedding model, RAG fails fast as usual (never a silent switch to another host). Web egress (e.g. `curl https://example.com`) also still works — only the
local network is the target of restriction.

## ⚠️ Limitation (Phase A alone)

A plain bridge **still routes to the LAN**. Phase A only relocates the container into
its own netns — it does **not** yet block local destinations. The actual egress
firewall (allow web + DNS, deny private ranges, allow a user-editable host:port
allowlist) is **Phase B** and runs as in-container nftables applied at root then
locked (NET_ADMIN dropped before the session). Until Phase B is enabled, treat
restrict-local as "isolated netns + host-gateway", not "LAN blocked".

## The firewall (Phase B): allowlist + enforcement

Phase B adds the actual enforcement as an **in-container nftables firewall**, shipped
as an opt-in **egress-hardened image variant** (tag suffix `-egress`).

**End users don't build anything.** Under restrict-local, nyia **pulls the published
`-egress` variant automatically** and launches it instead of the default image. It then
verifies the pulled image is a genuine hardened variant (by a baked-in label + entrypoint,
not the tag name) before granting it any extra privilege. If the variant can't be obtained
or isn't genuine, the launch is **refused** (fail-closed) with a clear message.

Maintainers/CI publish the variants; to build one locally use the dev build command (it
layers egress on top of the assistant image):

```bash
nyia-claude --build --dev --egress             # dev image + its -egress variant
nyia-claude --build --egress                   # release image + its -egress variant
nyia-claude --build-custom-image --egress      # egress-hardened version of YOUR overlay
```

> An egress image must always be the outermost layer — you cannot build *on top of* one,
> and `--image <x>-egress` is rejected (use the config key, which selects it safely).
> See `docs/DEV_GUIDE_EGRESS.md` for the architecture.

What the firewall allows / denies:

- **Allow**: loopback, established/related return traffic, DNS to the container's
  configured resolver, every **public** internet destination, and each entry in your
  **allowlist** (matched *before* the private-range drop).
- **Allow (conditional)**: ollama at `host-gateway:11434`, only when RAG is enabled.
- **Deny**: the private / special-use ranges — `10/8`, `172.16/12`, `192.168/16`,
  `169.254/16` (link-local), `127/8`, `100.64/10` (CGNAT), `192.0.0/24`, `198.18/15`,
  `240/4`.

So: full web egress, your allow-listed local `host:port`s (e.g. the test sidecar), and
nothing else on the LAN.

### The allowlist (user-editable)

A structural file (like `exclusions.conf`), layered and merged:
`~/.config/nyiakeeper/config/network-allow.conf` → `.nyiakeeper/network-allow.conf` →
`.nyiakeeper/private/network-allow.conf`. Each line is `proto host port`:

```
tcp sidecar 2222      # allow SSH to the test sidecar
# a LAN database is NOT listed -> it stays blocked
```

See `config/network-allow.conf.example`. Validation is strict (fail-closed): only
`tcp`/`udp`, a single port `1..65535`, a hostname or IPv4 literal — no CIDRs, no
`0.0.0.0`, no ranges, capped entry count. Names are resolved to IPs when the firewall
is compiled at container start.

### Capability lifecycle (why the session can't tamper)

The hardened variant starts as **root**, applies the nft ruleset, verifies IPv6 is
disabled, then **drops `NET_ADMIN`** (effective + bounding set) and `setpriv`s down to
your mapped uid:gid before running the assistant. The entrypoint then **self-checks**
that `NET_ADMIN` is gone and **refuses to run otherwise**. So you edit the policy
between sessions; the AI-driven session cannot change the rules. The debug shell
(`--shell`) bypasses the entrypoint and is therefore **not available** under
restrict-local.

### Fail-closed

Under restrict-local, the launch is refused (never run unfiltered) if: the bridge can't
be created, the hardened image isn't built, the allowlist is malformed/oversized, nft
or kernel modules are missing, IPv6 can't be disabled, or `NET_ADMIN` isn't dropped.

## Platform support

| Platform | restrict-local behavior (v1) |
| --- | --- |
| Native Linux | **Enforced**: dedicated `nyia-egress` bridge + host-gateway (host-net dropped) + in-container firewall |
| WSL2 / Docker Desktop | **Refused** (v1): the firewall variant is not yet verified there; the launch fails with a clear message. Set the policy to `off` to launch. |
| macOS / Docker Desktop | **Refused** (v1), same as above |

> v1 scopes enforcement to native Linux so the security guarantee is only ever claimed
> where it is validated. Docker Desktop / WSL2 support is a follow-up (the firewall must
> run inside the Docker VM).

## Notes

- The codex OAuth **login** path is separate from the session launch and is not
  affected by this policy; if a login flow needs host networking it is handled on its
  own path.
- This is distinct from **mount exclusions** (which hide files) — egress policy is
  about the network, not the filesystem.
- Never mounts `/var/run/docker.sock`; no extra capabilities on the `off` path.
