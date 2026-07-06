#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later OR Proprietary
#
# Egress firewall root-init (Plan 280b) — runs as ROOT at the start of the
# egress-hardened image variant ONLY. It compiles the user's allowlist into an
# nftables ruleset, applies it, verifies IPv6 is disabled, then drops NET_ADMIN
# (effective + bounding) and execs the normal entrypoint as the mapped user via
# setpriv. After this point the session cannot alter the firewall.
#
# FAIL-CLOSED everywhere: any error before the cap-drop aborts the container so it
# never runs with unfiltered egress.
#
# Required env (set by the launch path under restrict-local):
#   NYIA_EGRESS_POLICY=restrict-local
#   NYIA_TARGET_UID / NYIA_TARGET_GID   (the unprivileged user to drop to)
#   NYIA_EGRESS_RAG=true                (optional; adds the ollama exception)
set -euo pipefail

EGRESS_LIB="${NYIA_EGRESS_LIB:-/usr/local/share/nyia/lib/egress-firewall.sh}"
REAL_ENTRYPOINT="${NYIA_REAL_ENTRYPOINT:-/usr/local/bin/unified-entrypoint.sh}"

_fatal() { echo "FATAL (egress firewall): $1" >&2; exit 1; }

# This image runs as root (to apply nft). It must ONLY ever run under restrict-local —
# where nyia immediately drops privileges below. If it is launched any other way (a user
# hand-selecting the egress image with the policy off, a mis-tagged image, etc.) it would
# otherwise exec the assistant AS ROOT. Refuse, hard. (Plan 283 G1 — this neutralizes every
# "egress image run outside the policy" route at the source, regardless of host guards.)
if [[ "${NYIA_EGRESS_POLICY:-}" != "restrict-local" ]]; then
    _fatal "egress-hardened image launched without restrict-local — refusing to run (it would run as root). Enable: nyia config project network_egress_policy=restrict-local"
fi

# Must be root to apply nft and to setpriv-drop afterwards.
[[ "$(id -u)" -eq 0 ]] || _fatal "egress init must start as root (got uid $(id -u))"
[[ -n "${NYIA_TARGET_UID:-}" && -n "${NYIA_TARGET_GID:-}" ]] \
    || _fatal "NYIA_TARGET_UID/NYIA_TARGET_GID not set"
command -v nft >/dev/null 2>&1 || _fatal "nft binary missing in image"
command -v setpriv >/dev/null 2>&1 || _fatal "setpriv missing in image"
[[ -f "$EGRESS_LIB" ]] || _fatal "egress lib not found: $EGRESS_LIB"
# shellcheck disable=SC1090
source "$EGRESS_LIB"

# IPv6 must be disabled in this netns (the firewall is v4 only) — fail closed.
if [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 0)" != "1" ]]; then
    _fatal "IPv6 is not disabled in the container netns (expected --sysctl ...disable_ipv6=1)"
fi

# Resolver IPs from the container's configured resolver (do NOT hardcode 127.0.0.11).
RESOLVERS="$(awk '/^nameserver/ { printf "%s,", $2 }' /etc/resolv.conf 2>/dev/null)"
RESOLVERS="${RESOLVERS%,}"

# host-gateway IP (for the ollama exception); empty if not resolvable. The `|| true`
# keeps a non-resolving lookup empty instead of fatal under `set -euo pipefail`.
HOST_GW="$(getent hosts host.docker.internal 2>/dev/null | awk '{print $1; exit}' || true)"

# Load + validate the allowlist, then resolve each host to IPv4 literal(s) at
# compile time (the renderer needs IPs). Resolution failure is fail-closed.
resolve_host_to_ipv4() {  # <host> -> one IPv4 per line
    if [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo "$1"; return 0; fi
    getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u
}

ALLOW_RESOLVED=""
if ! ALLOW_RAW="$(load_egress_allowlist "${NYIA_PROJECT_PATH:-}")"; then
    _fatal "allowlist failed validation (see errors above)"
fi
while IFS=' ' read -r proto host port; do
    [[ -z "${proto:-}" ]] && continue
    ips="$(resolve_host_to_ipv4 "$host" || true)"
    [[ -n "$ips" ]] || _fatal "cannot resolve allowlist host '$host' (fail-closed)"
    while IFS= read -r ip; do
        [[ -n "$ip" ]] && ALLOW_RESOLVED+="$proto $ip $port"$'\n'
    done <<< "$ips"
done <<< "$ALLOW_RAW"

# Surface the LAN holes being opened so the operator can see exactly what local
# destinations the allowlist permits (a project-committed allowlist is untrusted input).
if [[ -n "$ALLOW_RESOLVED" ]]; then
    echo "egress firewall: opening local allowlist holes:" >&2
    printf '  %s\n' $ALLOW_RESOLVED >&2
fi

# Render + apply the ruleset.
RULESET="$(printf '%s' "$ALLOW_RESOLVED" \
    | render_nft_ruleset "$RESOLVERS" "$HOST_GW" "${NYIA_EGRESS_RAG:-false}")"
echo "$RULESET" | nft -f - || _fatal "nft failed to apply the egress ruleset"

# Drop NET_ADMIN and reuid/regid to the mapped user, then exec. After this the process
# (and the whole session) has no NET_ADMIN and cannot edit nft. We also clear the
# inheritable + ambient cap sets and set no-new-privs so the drop is robust even if a
# future image adds file capabilities to a binary on the exec path.
exec setpriv \
    --reuid "$NYIA_TARGET_UID" --regid "$NYIA_TARGET_GID" --clear-groups \
    --bounding-set=-net_admin --inh-caps=-all --ambient-caps=-all --no-new-privs \
    "$REAL_ENTRYPOINT" "$@"
