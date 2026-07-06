#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later OR Proprietary
#
# Assistant egress firewall — Phase B (Plan 280b): allowlist loader + nftables
# renderer. Pure, host-testable logic. The ruleset it emits is applied AS ROOT in
# the egress-hardened image variant's entrypoint, which then drops NET_ADMIN before
# the assistant runs — so the user owns the policy between sessions and the session
# cannot tamper with it.
#
# Policy shape under restrict-local: allow loopback + established + DNS + a
# user-editable host:port allowlist (+ ollama when RAG is on) + ALL public egress;
# DENY the private/special-use ranges (RFC1918, link-local, CGNAT, loopback-as-dest,
# etc.). Allowlist entries are matched BEFORE the private drop, so a sidecar on the
# LAN can be reached while the rest of the LAN cannot.

# Load guard.
if [[ -n "${_NYIA_EGRESS_FIREWALL_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
_NYIA_EGRESS_FIREWALL_LOADED=1

# Private / special-use destinations that are DENIED by default (review: full set,
# not just RFC1918). Allowlist entries are accepted before this drop.
readonly NYIA_EGRESS_DENY_CIDRS=(
    "10.0.0.0/8"
    "172.16.0.0/12"
    "192.168.0.0/16"
    "169.254.0.0/16"   # link-local
    "127.0.0.0/8"      # loopback as a destination
    "100.64.0.0/10"    # CGNAT
    "192.0.0.0/24"     # IETF protocol assignments
    "198.18.0.0/15"    # benchmarking
    "240.0.0.0/4"      # reserved
    "224.0.0.0/4"      # multicast (mDNS/SSDP local-segment discovery)
    "255.255.255.255/32" # limited broadcast
)

# Hard limits to reject oversized/abusive allowlists.
readonly NYIA_EGRESS_MAX_ENTRIES=64
readonly NYIA_EGRESS_MAX_LINE_LEN=200

# _egress_validate_entry <proto> <host> <port>
# Strict validation. Returns 0 if the entry is safe to compile, non-zero otherwise
# (with a reason on stderr). Rejects: non tcp/udp; default routes; CIDR in host;
# port 0/ranges/non-numeric/out-of-range.
_egress_validate_entry() {
    local proto="$1" host="$2" port="$3"

    case "$proto" in
        tcp|udp) ;;
        *) echo "egress: invalid proto '$proto' (must be tcp or udp)" >&2; return 1 ;;
    esac

    if [[ -z "$host" ]]; then
        echo "egress: empty host" >&2; return 1
    fi
    # No default routes / CIDRs / wildcards in the host field.
    case "$host" in
        0.0.0.0|0.0.0.0/0|::/0|::|*/*|*\**)
            echo "egress: unsafe host '$host' (no default routes, CIDRs or wildcards)" >&2
            return 1
            ;;
    esac
    # Host must look like a hostname or an IPv4 literal (names resolved at compile time).
    if [[ ! "$host" =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo "egress: invalid host characters in '$host'" >&2; return 1
    fi
    # If it looks like a dotted-quad, every octet must be 0..255 (reject 999.1.1.1
    # early with a clear error instead of letting nft reject the whole ruleset).
    if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        local _o
        local IFS='.'
        for _o in $host; do
            if (( _o > 255 )); then
                echo "egress: invalid IPv4 literal '$host' (octet > 255)" >&2; return 1
            fi
        done
    fi

    # Port: a single integer 1..65535 (no ranges).
    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        echo "egress: invalid port '$port' (single number required, no ranges)" >&2; return 1
    fi
    if (( port < 1 || port > 65535 )); then
        echo "egress: port out of range '$port'" >&2; return 1
    fi
    return 0
}

# load_egress_allowlist <project_path>
# Merge layered allowlists (global -> project -> project-private), validate each
# entry, and print the accepted "proto host port" lines. Comments (#) and blanks are
# ignored. Returns non-zero (fail-closed) on any malformed/oversized input.
load_egress_allowlist() {
    local project_path="${1:-}"
    local config_home="${NYIA_CONFIG_HOME:-${HOME}/.config/nyiakeeper/config}"

    local -a files=(
        "$config_home/network-allow.conf"
        "$project_path/.nyiakeeper/network-allow.conf"
        "$project_path/.nyiakeeper/private/network-allow.conf"
    )

    local count=0
    local f line proto host port
    for f in "${files[@]}"; do
        [[ -n "$f" && -f "$f" ]] || continue
        while IFS= read -r line || [[ -n "$line" ]]; do
            # Strip comments and surrounding whitespace.
            line="${line%%#*}"
            line="${line#"${line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"
            [[ -z "$line" ]] && continue

            if (( ${#line} > NYIA_EGRESS_MAX_LINE_LEN )); then
                echo "egress: allowlist line too long in $f" >&2; return 1
            fi
            # shellcheck disable=SC2086
            set -- $line
            if [[ $# -ne 3 ]]; then
                echo "egress: malformed allowlist entry in $f: '$line' (expected: proto host port)" >&2
                return 1
            fi
            proto="$1"; host="$2"; port="$3"
            if ! _egress_validate_entry "$proto" "$host" "$port"; then
                echo "egress: rejected entry in $f: '$line'" >&2; return 1
            fi
            count=$((count + 1))
            if (( count > NYIA_EGRESS_MAX_ENTRIES )); then
                echo "egress: too many allowlist entries (max $NYIA_EGRESS_MAX_ENTRIES)" >&2; return 1
            fi
            printf '%s %s %s\n' "$proto" "$host" "$port"
        done < "$f"
    done
    return 0
}

# render_nft_ruleset <resolver_ips_csv> <host_gateway_or_empty> <rag_enabled:true|false>
# Reads validated "proto host port" allowlist lines from STDIN and prints an nft
# ruleset. Order is load-bearing: allowlist + ollama accepts come BEFORE the
# private-range drop, so allow-listed LAN hosts are reachable while the rest are not.
render_nft_ruleset() {
    local resolver_ips_csv="${1:-}"
    local host_gateway="${2:-}"
    local rag_enabled="${3:-false}"

    echo "#!/usr/sbin/nft -f"
    echo "# Generated by Nyia Keeper egress firewall (Plan 280b). Do not edit by hand."
    # Scope to OUR OWN table — never 'flush ruleset'. Flushing wipes Docker's embedded
    # rules, including the NAT that makes the bridge resolver 127.0.0.11 work, which
    # silently kills DNS and therefore ALL web egress under restrict-local (Plan 283 VM
    # finding). `table` then `delete table` is the idempotent way to reset only our table.
    echo "table inet nyia_egress"
    echo "delete table inet nyia_egress"
    echo "table inet nyia_egress {"
    echo "    chain output {"
    echo "        type filter hook output priority 0; policy drop;"
    echo "        oifname \"lo\" accept"
    echo "        ct state established,related accept"

    # DNS to the container's configured resolver(s) only (not the whole LAN).
    local ip
    if [[ -n "$resolver_ips_csv" ]]; then
        local IFS=','
        for ip in $resolver_ips_csv; do
            [[ -z "$ip" ]] && continue
            echo "        ip daddr $ip udp dport 53 accept"
            echo "        ip daddr $ip tcp dport 53 accept"
        done
    fi

    # ollama auto-exception (only when RAG is on, and only the exact host-gateway:11434).
    if [[ "$rag_enabled" == "true" && -n "$host_gateway" ]]; then
        echo "        ip daddr $host_gateway tcp dport 11434 accept"
    fi

    # User allowlist entries (accepted before the private drop below).
    local proto host port
    while IFS=' ' read -r proto host port; do
        [[ -z "$proto" ]] && continue
        echo "        ip daddr $host $proto dport $port accept"
    done

    # Deny the private / special-use ranges (everything else = public = allowed).
    local cidr
    for cidr in "${NYIA_EGRESS_DENY_CIDRS[@]}"; do
        echo "        ip daddr $cidr drop"
    done

    # IPv6 is not covered by the v4 rules above; drop ALL of it so the firewall is
    # fail-closed even if the IPv6-disable sysctl didn't take (defense in depth — the
    # entrypoint also refuses to run when IPv6 isn't disabled).
    echo "        meta nfproto ipv6 drop"

    # Public internet (IPv4): anything not dropped above.
    echo "        accept"
    echo "    }"
    echo "}"
}
