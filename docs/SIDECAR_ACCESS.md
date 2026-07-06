# Connecting the Assistant to a Test Sidecar

The assistant can run your project's tests / console commands against a
docker-compose stack by reaching a locked-down **SSH sidecar** (an unprivileged
`runner` user with a forced-command allowlist). Nyia Keeper owns only *how the
assistant reaches the sidecar over the network* and that the key + ssh client survive
the mount/image. The sidecar itself is owned by the akopso side (Plan 58).

> No Docker socket is ever mounted. The basic path adds **no** extra capabilities.

## Key placement

Put the private key at `.nyiakeeper/cli-runner-access/id-runner` (mode `600`). The
mount/exclusion logic does **not** strip it — `id-runner` deliberately does not match
the secret patterns (`id_rsa`, `*.key`, `*.pem`, …), and there is a regression test
guarding this. The `ssh` client stays in the assistant image (also regression-tested).

## Transport per mode

| Egress policy | Sidecar target | Notes |
| --- | --- | --- |
| `off` (default) | `127.0.0.1:2222` | Native Linux is host-networked, so the host loopback reaches the sidecar. |
| `restrict-local` | `host.docker.internal:2222` (host-gateway) | The container is on a bridge; reach the sidecar via host-gateway, and **add it to the allowlist** (see below). |

On Docker Desktop / WSL2 the container is already on a bridge in both modes, so use
`host.docker.internal:2222` (loopback `127.0.0.1` is the *container's* loopback there,
not the host's).

## Allowlist (restrict-local only)

Under `network_egress_policy=restrict-local` the LAN is denied by default — you must
allow the sidecar explicitly in `network-allow.conf` (see `docs/NETWORK_EGRESS.md`):

```
tcp sidecar 2222          # or:  tcp host.docker.internal 2222
```

A LAN database (e.g. mysql `3306`) left unlisted stays **blocked** — that is the whole
point: the assistant reaches the sidecar but not the rest of your network.

## Verify it works

Run the maintainer checklist from inside the container (or anywhere with the key +
reachability):

```bash
scripts/verify-sidecar-access.sh 127.0.0.1 2222 .nyiakeeper/cli-runner-access/id-runner
```

It checks: ssh client present, key present + `600`, port reachable, an allow-listed
command runs (`vendor/bin/phpunit --version`), and a **non-allow-listed** command
(`bash`) is **denied** by the sidecar.

## ⚠️ Limitation

With `network_egress_policy=off` (the default) on native Linux, the container is
host-networked and can reach your **entire LAN**, not just the sidecar. To bound it to
the internet + the allow-listed sidecar only, enable `restrict-local` (see
`docs/NETWORK_EGRESS.md`). That is the recommended setup when the assistant runs
against local infrastructure.

## See also

- `docs/NETWORK_EGRESS.md` — the egress policy + firewall + allowlist.
- akopso Plan 58 — the SSH sidecar (forced-command allowlist, `runner` user).
