#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later OR Proprietary
# Auto-update checking and version management for Nyia Keeper runtime distribution.
# Provides startup update check (throttled), explicit update/rollback commands,
# release notes display, and tarball-based update with SHA256 verification.

# Source guard — prevent double-loading
[[ -n "${_AUTO_UPDATE_LOADED:-}" ]] && return 0
_AUTO_UPDATE_LOADED=1

# --- Constants ---

readonly UPDATE_CHECK_INTERVAL=3600  # 1 hour in seconds
readonly UPDATE_CURL_TIMEOUT=5       # seconds — fast metadata calls (API/manifest)
# Release-asset downloads need a larger bound than metadata calls:
# UPDATE_CURL_TIMEOUT (5s) targets small JSON responses, whereas the runtime
# tarball is a multi-MB asset served via a signed redirect and can take longer
# on slow connections. The checksum file is tiny, so it keeps a tighter bound.
readonly UPDATE_TARBALL_TIMEOUT=60   # seconds — multi-MB runtime tarball
readonly UPDATE_CHECKSUM_TIMEOUT=10  # seconds — tiny .sha256 file
readonly GITHUB_REPO="KaizendoFr/nyia-keeper"
readonly GITHUB_API="https://api.github.com/repos/${GITHUB_REPO}"
readonly GITHUB_RELEASES_URL="https://github.com/${GITHUB_REPO}/releases"
# Public installer URL — this IS the scripts/public-install.sh contract, served via
# raw GitHub content. Same URL users use for first install.
readonly FRESH_INSTALL_URL="https://raw.githubusercontent.com/${GITHUB_REPO}/main/install.sh"
readonly MAX_RELEASE_NOTES_LINES=20
readonly LOCK_STALE_TIMEOUT=300      # 5 minutes — real updates can exceed 60s on slow connections

# Channel manifest URL — hosted on the public runtime repo (raw content).
# Maps channel names ("latest", "alpha", "beta") to immutable release tags.
# Updated automatically for "latest" on every release.sh --push.
# Updated manually for the "alpha"/"beta" prerelease channels via scripts/promote-channel.sh.
# Fail-closed-by-absence (Plan 312a): a channel with NO key here is "not available yet";
# consumers must NOT fall back to another channel (e.g. beta must never resolve to :latest).
readonly CHANNELS_MANIFEST_URL="https://raw.githubusercontent.com/KaizendoFr/nyia-keeper/main/channels.json"

# Approved channel names for channel-aware resolution.
readonly CHANNEL_LATEST="latest"
readonly CHANNEL_ALPHA="alpha"
readonly CHANNEL_BETA="beta"

# --- Locking ---

acquire_update_lock() {
    # Single-owner boundary: if already held by this process, skip
    [[ "${_UPDATE_LOCK_HELD:-}" == "1" ]] && return 0

    local lock_dir="${NYIAKEEPER_HOME:?}/.update-lock"
    local pid_file="$lock_dir/pid"

    if mkdir "$lock_dir" 2>/dev/null; then
        echo $$ > "$pid_file"
        export _UPDATE_LOCK_HELD=1
        return 0
    fi

    # Lock exists — check if stale
    if [[ -f "$pid_file" ]]; then
        local lock_pid
        lock_pid=$(cat "$pid_file" 2>/dev/null) || lock_pid=""

        # Check if PID is still running
        if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
            # Process is dead — remove stale lock
            rm -rf "$lock_dir"
            if mkdir "$lock_dir" 2>/dev/null; then
                echo $$ > "$pid_file"
                export _UPDATE_LOCK_HELD=1
                return 0
            fi
        fi

        # Check if lock is old (stale timeout)
        local lock_age
        if [[ "$(uname -s)" == "Darwin" ]]; then
            lock_age=$(( $(date +%s) - $(stat -f %m "$pid_file" 2>/dev/null || echo 0) ))
        else
            lock_age=$(( $(date +%s) - $(stat -c %Y "$pid_file" 2>/dev/null || echo 0) ))
        fi

        if [[ "$lock_age" -gt "$LOCK_STALE_TIMEOUT" ]]; then
            rm -rf "$lock_dir"
            if mkdir "$lock_dir" 2>/dev/null; then
                echo $$ > "$pid_file"
                export _UPDATE_LOCK_HELD=1
                return 0
            fi
        fi
    fi

    # Could not acquire lock
    return 1
}

release_update_lock() {
    [[ "${_UPDATE_LOCK_HELD:-}" != "1" ]] && return 0
    local lock_dir="${NYIAKEEPER_HOME:?}/.update-lock"
    rm -rf "$lock_dir"
    export _UPDATE_LOCK_HELD=0
}

# --- Cache & Throttle ---

is_update_check_due() {
    local cache_file="${NYIAKEEPER_HOME:?}/.update-cache"

    # No cache = check is due
    if [[ ! -f "$cache_file" ]]; then
        return 0
    fi

    local last_check=0
    while IFS='=' read -r key value; do
        [[ "$key" == "LAST_CHECK" ]] && last_check="$value"
    done < "$cache_file"

    local now
    now=$(date +%s)
    local elapsed=$(( now - last_check ))

    if [[ "$elapsed" -ge "$UPDATE_CHECK_INTERVAL" ]]; then
        return 0
    fi

    return 1
}

_write_update_cache() {
    local latest_tag="$1"
    local current_tag="$2"
    local cache_file="${NYIAKEEPER_HOME:?}/.update-cache"

    cat > "$cache_file" <<EOF
LAST_CHECK=$(date +%s)
LATEST_TAG=${latest_tag}
CURRENT_TAG=${current_tag}
EOF
}

# Write only LAST_CHECK timestamp — used on auto-update decline so the throttle
# still applies (prevents per-command spam) without caching version info.
_write_check_timestamp() {
    local cache_file="${NYIAKEEPER_HOME:?}/.update-cache"
    echo "LAST_CHECK=$(date +%s)" > "$cache_file"
}

# --- Channel State ---
# Persists the user's selected update channel separately from the installed version.
# File: $NYIAKEEPER_HOME/CHANNEL   (single line: "latest", "alpha", "beta", or empty = latest)
# An empty or missing CHANNEL file is treated as the "latest" channel.

# Normalize a channel string: trim, lowercase, validate against the known channels. Empty or
# unrecognized values collapse to the DEFAULT channel (beta — Plan 320; was latest) — prevents
# mixed-case or stray values from leaking into channel resolution. (Invalid-vs-empty distinction —
# fail-closed-with-repair on corrupt state — is a documented fail-safe deviation; see plan 320.)
_normalize_channel() {
    local ch
    ch=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    case "$ch" in
        "$CHANNEL_LATEST"|"$CHANNEL_ALPHA"|"$CHANNEL_BETA") printf '%s\n' "$ch" ;;
        "") printf '%s\n' "$CHANNEL_BETA" ;;   # empty/missing → default beta, silently (migrate)
        *)
            # Plan 321 R5: a NON-empty but unrecognized value (corrupt/typo'd CHANNEL) — don't silently
            # mask it. Warn on STDERR (stdout is captured as the channel value, so this can't corrupt
            # it), then fall back to the default (beta) so launch still works.
            echo "⚠️  Unrecognized channel '$1' — using 'beta'. Set a valid one: nyia update install beta" >&2
            printf '%s\n' "$CHANNEL_BETA"
            ;;
    esac
}

get_installed_channel() {
    local nyia_home="${NYIAKEEPER_HOME:-}"
    # Fall back to XDG config dir if NYIAKEEPER_HOME not set
    if [[ -z "$nyia_home" ]]; then
        nyia_home="${XDG_CONFIG_HOME:-$HOME/.config}/nyiakeeper"
    fi
    local channel_file="$nyia_home/CHANNEL"

    # Environment variable wins (allows scripted overrides without modifying state).
    if [[ -n "${NYIA_CHANNEL:-}" ]]; then
        _normalize_channel "$NYIA_CHANNEL"
        return 0
    fi

    if [[ -f "$channel_file" ]]; then
        local ch
        ch=$(tr -d '[:space:]' < "$channel_file" | head -1)
        if [[ -n "$ch" ]]; then
            _normalize_channel "$ch"
            return 0
        fi
    fi

    # No explicit channel state: infer from the installed version so an alpha/beta install stays on
    # its own channel (alpha = frozen bridge — no compat mismatch), else default to BETA (Plan 320:
    # beta is the default; auto-migrate legacy no-CHANNEL installs — was latest). Kept consistent with
    # _resolve_host_channel (bin/common/shared.sh) so update channel and runtime image tag agree.
    local _ver _ch
    _ver=$(get_installed_version 2>/dev/null) || _ver=""
    _ch=$(_infer_channel_from_version "$_ver")   # alpha | beta | latest
    if [[ "$_ch" == "alpha" || "$_ch" == "beta" ]]; then
        echo "$_ch"
    else
        echo "$CHANNEL_BETA"
    fi
}

set_installed_channel() {
    local channel="$1"
    local nyia_home="${NYIAKEEPER_HOME:-}"
    if [[ -z "$nyia_home" ]]; then
        nyia_home="${XDG_CONFIG_HOME:-$HOME/.config}/nyiakeeper"
    fi
    local channel_file="$nyia_home/CHANNEL"

    if [[ -z "$channel" ]]; then
        # Empty channel = use default (latest); remove the file
        rm -f "$channel_file"
        return 0
    fi

    mkdir -p "$nyia_home"
    echo "$channel" > "$channel_file"
}

# Infer the update channel from a version tag string.
# Matches the CI pipeline tagging logic (.github/workflows/pipeline.yml — the
# per-job image-tag blocks around L310+):
#   version contains "-alpha." → "alpha"
#   version contains "-beta."  → "beta"
#   everything else            → "latest"
_infer_channel_from_version() {
    local version="${1:-}"
    if [[ "$version" == *-alpha.* ]]; then
        echo "alpha"
    elif [[ "$version" == *-beta.* ]]; then
        echo "beta"
    else
        echo "latest"
    fi
}

# --- Channel Manifest ---
# Resolves a channel name to an immutable release tag via the public channels.json manifest.
# Returns the tag on stdout.  Returns 1 (empty output) on failure.

fetch_channel_version() {
    local channel="$1"

    local response
    # -f: fail-closed on any HTTP error so a 404/error page body can never be parsed as a manifest.
    response=$(curl -fs --max-time "$UPDATE_CURL_TIMEOUT" \
        "$CHANNELS_MANIFEST_URL" 2>/dev/null) || response=""

    if [[ -z "$response" ]]; then
        return 1
    fi

    # Parse the JSON value for the requested channel key (no jq dependency).
    # Pattern: "channel": "vX.Y.Z-alpha.N"
    local tag
    tag=$(echo "$response" \
        | grep -o "\"${channel}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
        | head -1 \
        | sed "s/.*\"${channel}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/") \
        || tag=""

    if [[ -n "$tag" ]]; then
        echo "$tag"
        return 0
    fi

    return 1
}

# --- Version Discovery ---

fetch_latest_version() {
    local current_version="${1:-}"
    # Optional: caller may pass the installed channel to select the right resolution path.
    local installed_channel="${2:-}"

    # Resolve installed channel if not provided
    if [[ -z "$installed_channel" ]]; then
        installed_channel=$(get_installed_channel)
    fi

    # --- Channel manifest path (all channels) ---
    # Try the curated channels.json manifest first for ALL channels.
    # "latest" = promoted stable, "alpha"/"beta" = prerelease channels.
    # Unknown/invalid channels: manifest returns empty → falls through to GitHub API.
    local manifest_tag
    manifest_tag=$(fetch_channel_version "$installed_channel") || manifest_tag=""
    if [[ -n "$manifest_tag" ]]; then
        echo "$manifest_tag"
        return 0
    fi

    # Fail-closed for the beta channel (Plan 312c; fail-closed-by-absence, Plan 312a):
    # beta is served EXCLUSIVELY through the channels.json manifest. Until the first beta is
    # cut, channels.json has NO "beta" key, so fetch_channel_version above returned empty. We
    # MUST NOT fall through to the GitHub API path below — /releases/latest resolves to the
    # STABLE release and would silently downgrade a beta user to :latest. Fail closed: return
    # empty/non-zero so callers report "beta not available yet" and abort (never a stable
    # fallback). alpha/latest keep their existing GitHub API fallback (parity).
    if [[ "$installed_channel" == "$CHANNEL_BETA" ]]; then
        return 1
    fi

    # Manifest unreachable or channel key not found: fall through to GitHub API fallback

    # --- GitHub API path (for "latest" channel and fallback) ---

    # Stage 1: try /releases/latest (works when repo has non-prerelease releases)
    local response
    response=$(curl -s --max-time "$UPDATE_CURL_TIMEOUT" \
        -H "Accept: application/vnd.github.v3+json" \
        "${GITHUB_API}/releases/latest" 2>/dev/null) || response=""

    local tag=""
    if [[ -n "$response" ]]; then
        # Extract tag_name
        tag=$(echo "$response" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
    fi

    # "latest" is the STABLE/default channel: only a genuine (non-prerelease) release qualifies.
    # If /releases/latest found nothing (a prerelease-only repo), FAIL CLOSED — never offer a
    # prerelease as "latest" (Plan 319; client side of the channels.json latest contract). alpha
    # keeps its same-channel /releases fallback below; beta already fail-closed above.
    if [[ "$installed_channel" == "$CHANNEL_LATEST" && -z "$tag" ]]; then
        return 1
    fi

    # Stage 2: fallback to /releases (for prerelease-only repos)
    if [[ -z "$tag" ]]; then
        response=$(curl -s --max-time "$UPDATE_CURL_TIMEOUT" \
            -H "Accept: application/vnd.github.v3+json" \
            "${GITHUB_API}/releases?per_page=10" 2>/dev/null) || response=""

        if [[ -n "$response" ]]; then
            # If current version is a prerelease channel, prefer same-channel tags.
            if [[ "$current_version" == *"-alpha."* ]]; then
                tag=$(echo "$response" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*-alpha\.[^"]*"' | head -1 | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
            elif [[ "$current_version" == *"-beta."* ]]; then
                tag=$(echo "$response" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*-beta\.[^"]*"' | head -1 | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
            fi
            # If no same-channel match (or a stable current), take first tag
            if [[ -z "$tag" ]]; then
                tag=$(echo "$response" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
            fi
        fi
    fi

    if [[ -n "$tag" ]]; then
        echo "$tag"
    fi
    # Empty output on failure (silent fail)
}

# --- Version Listing ---

# Plan 344: what a user can actually install is bounded by IMAGE RETENTION, not by the release
# list: the pipeline keeps the newest NYIA_RETAIN_PER_FAMILY pinned image versions per prerelease
# family (plus every stable), so older releases still have assets but no runnable image. Listing
# them would offer versions that cannot launch. Keep this constant in step with the retain-images
# job's RETAIN_PER_FAMILY and docs/RELEASE_OPS.md.
NYIA_RETAIN_PER_FAMILY="${NYIA_RETAIN_PER_FAMILY:-4}"

# Release-version POLICY (the pinning epoch + its validated ordering) comes from the shared module,
# never from a local copy — a duplicated constant is exactly the kind of cross-file drift that reads
# as agreement until it silently isn't (Plan 346, D-3469). The module is deliberately tiny and
# side-effect free so the updater does NOT have to source the launcher library.
# Layouts: source/dist = <root>/bin/common/…  ·  installed = ~/.local/lib/nyiakeeper -> ../../bin/common/…
_nyia_load_version_policy() {
    local here="${BASH_SOURCE[0]%/*}" c
    for c in "${here}/../bin/common/version-policy.sh" \
             "${here}/../../bin/common/version-policy.sh"; do
        if [[ -f "$c" ]]; then
            # shellcheck source=/dev/null
            source "$c"
            return 0
        fi
    done
    return 1
}
if ! _nyia_load_version_policy; then
    # Fail SAFE: with no policy module we cannot tell "predates pinning" from "pruned", so never
    # claim a version was pruned (the refusal below is skipped entirely).
    nyia_version_at_or_after_epoch() { return 1; }
fi

# _version_family <tag> -> alpha | beta | stable | unknown
_version_family() {
    case "$1" in
        *-alpha.*) echo "alpha" ;;
        *-beta.*)  echo "beta" ;;
        v*.*.*)    [[ "$1" == *-* ]] && echo "unknown" || echo "stable" ;;
        *)         echo "unknown" ;;
    esac
}

list_available_versions() {
    local response
    # per_page 40 (was 10): with 4+ retained betas the stable release must stay reachable behind
    # them — a 10-release window drops it as soon as ten prereleases are cut (Plan 344).
    response=$(curl -s --max-time "$UPDATE_CURL_TIMEOUT" \
        -H "Accept: application/vnd.github.v3+json" \
        "${GITHUB_API}/releases?per_page=40" 2>/dev/null) || response=""

    if [[ -z "$response" ]]; then
        echo "Error: Could not fetch releases from GitHub." >&2
        return 1
    fi

    local -a tags=()
    while IFS= read -r t; do
        tags+=("$t")
    done < <(echo "$response" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')

    if [[ ${#tags[@]} -eq 0 ]]; then
        echo "No releases found." >&2
        return 1
    fi

    local -a dates=()
    while IFS= read -r d; do
        dates+=("${d:0:10}")
    done < <(echo "$response" | grep -o '"published_at"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"published_at"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')

    local current
    current=$(get_installed_version 2>/dev/null) || current=""

    # The channel pointers (what an automatic update would install per channel).
    local pointers="" ch_ptr
    for ch in "$CHANNEL_LATEST" "$CHANNEL_BETA" "$CHANNEL_ALPHA"; do
        ch_ptr=$(fetch_channel_version "$ch" 2>/dev/null) || ch_ptr=""
        [[ -n "$ch_ptr" ]] && pointers="${pointers}${ch}=${ch_ptr} "
    done

    echo "Installable versions (each channel's current version + the newest ${NYIA_RETAIN_PER_FAMILY} of that channel, plus every stable release):"
    echo ""
    [[ -n "$pointers" ]] && { echo "  Channel pointers: ${pointers% }"; echo ""; }

    local have_dates=0
    [[ ${#dates[@]} -eq ${#tags[@]} ]] && have_dates=1
    if [[ "$have_dates" -eq 1 ]]; then
        printf "  %-28s %-14s %s\n" "TAG" "DATE" "STATUS"
    else
        printf "  %-28s %s\n" "TAG" "STATUS"
    fi

    local -A shown=()
    local i tag family marker n hidden=0 p is_pointer
    for i in "${!tags[@]}"; do
        tag="${tags[$i]}"
        family=$(_version_family "$tag")
        # The channel pointer's digest is PROTECTED by retention (it carries the floating alias),
        # so it never consumes one of the N slots — retention keeps "pointer + N", and the list must
        # show the same set or it would hide a version that is still installable. (Code review SF6.)
        is_pointer=0
        for p in $pointers; do [[ "$tag" == "${p#*=}" ]] && is_pointer=1; done
        if [[ "$family" != "stable" && "$is_pointer" -eq 0 ]]; then
            n=${shown[$family]:-0}
            if (( n >= NYIA_RETAIN_PER_FAMILY )); then
                hidden=$((hidden + 1))
                continue                      # its images are pruned — offering it would be a lie
            fi
            shown[$family]=$((n + 1))
        fi
        marker=""
        [[ "$tag" == "$current" ]] && marker="← installed"
        for p in $pointers; do
            [[ "$tag" == "${p#*=}" ]] && marker="${marker:+$marker }(${p%%=*} channel)"
        done
        case "$tag" in *-alpha.*) marker="${marker:+$marker }(deprecated)" ;; esac   # Plan 321 R3
        if [[ "$have_dates" -eq 1 ]]; then
            printf "  %-28s %-14s %s\n" "$tag" "${dates[$i]}" "$marker"
        else
            printf "  %-28s %s\n" "$tag" "$marker"
        fi
    done

    echo ""
    if [[ "$hidden" -gt 0 ]]; then
        echo "  ($hidden older release(s) hidden — their images are no longer published, so they cannot be installed.)"
        echo ""
    fi
    echo "To switch: nyia update install <version>"
}

# --- CLI-targeted Update Wrapper ---

# nyia_pinned_image_exists <version-tag> [package]
#   0 = the pinned image for this version is published · 1 = it is not · 2 = could not tell.
# Anonymous GHCR read on a PUBLIC package: token exchange, then HEAD the manifest. The Accept
# header must list the index media types or a multi-arch manifest answers 404/406 (Plan 344).
nyia_pinned_image_exists() {
    local version="${1:?version}" pkg="${2:-nyiakeeper-base}" token code
    command -v curl >/dev/null 2>&1 || return 2
    token=$(curl -s --max-time "${UPDATE_CURL_TIMEOUT:-10}" \
        "https://ghcr.io/token?scope=repository:kaizendofr/${pkg}:pull&service=ghcr.io" 2>/dev/null \
        | sed 's/.*"token":"\([^"]*\)".*/\1/') || return 2
    [[ -n "$token" && "$token" != *'{'* ]] || return 2
    code=$(curl -sI -o /dev/null -w '%{http_code}' --max-time "${UPDATE_CURL_TIMEOUT:-10}" \
        -H "Authorization: Bearer ${token}" \
        -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json' \
        "https://ghcr.io/v2/kaizendofr/${pkg}/manifests/${version}" 2>/dev/null) || return 2
    case "$code" in
        200) return 0 ;;
        404) return 1 ;;
        *)   return 2 ;;   # 401/5xx/timeout: unverifiable — never claim the image is missing
    esac
}

cli_targeted_update() {
    local target_tag="${1:-}"

    local current
    current=$(get_installed_version 2>/dev/null) || current=""

    if [[ -n "$target_tag" ]]; then
        # Show confirmation for explicit version targeting
        local direction="switch"
        if [[ -n "$current" && "$current" != "latest" && "$current" != "dev" ]]; then
            if compare_versions "$current" "$target_tag" 2>/dev/null; then
                direction="upgrade"
            else
                direction="downgrade"
            fi
            if [[ "$current" == "$target_tag" ]]; then
                direction="reinstall"
            fi
        fi

        echo "Current version: ${current:-unknown}"
        echo "Target version:  $target_tag ($direction)"

        # Plan 344: only RETAINED versions still have container images, so installing a pruned
        # version yields a host that cannot launch. Two guards keep this honest:
        #   * a 404 for the target is only meaningful once pinned tags are actually in use — every
        #     release cut BEFORE Plan 344 has none, and refusing those would block every install
        #     that works today. So first confirm the current channel pointer HAS a pinned image;
        #   * only a DEFINITIVE 404 refuses. Offline, 401 or 5xx (rc 2) never blocks the user.
        local _probe_rc=0
        nyia_pinned_image_exists "$target_tag" || _probe_rc=$?
        if [[ "$_probe_rc" -eq 1 ]]; then
            local _channel_ref _pinning_in_use=2      # 0 = pinning IS in use, anything else = unknown
            _channel_ref=$(fetch_channel_version "$(get_installed_channel 2>/dev/null || echo "$CHANNEL_BETA")" 2>/dev/null) || _channel_ref=""
            if [[ -n "$_channel_ref" ]]; then
                if nyia_pinned_image_exists "$_channel_ref"; then
                    _pinning_in_use=0
                else
                    _pinning_in_use=$?
                fi
            fi
            # A target OLDER than the pinning epoch predates per-version tags entirely: its missing
            # pinned tag says nothing about whether its images are still there. Refusing it would
            # contradict `nyia update list`, which still lists it as installable.
            if ! nyia_version_at_or_after_epoch "$target_tag"; then
                _pinning_in_use=2
            fi
            if [[ "$_pinning_in_use" -eq 0 ]]; then
                echo "" >&2
                echo "❌ ${target_tag} is no longer installable: its container images have been removed." >&2
                echo "   Only the newest few releases per channel are kept (plus every stable release)." >&2
                echo "   Run 'nyia update list' to see what is installable." >&2
                return 1
            fi
            # Pinned tags are not in use yet (pre-Plan-344 releases): say nothing, install as before.
        fi
        echo ""

        local answer
        if [[ -n "${NYIA_UPDATE_CONFIRM:-}" ]]; then
            answer="$NYIA_UPDATE_CONFIRM"
        else
            read -r -p "Proceed? [y/N] " answer < /dev/tty
        fi
        if [[ ! "$answer" =~ ^[Yy] ]]; then
            echo "Update cancelled."
            return 0
        fi
    fi

    # Infer channel from target version so CHANNEL file stays coherent (Plan 227).
    # Only when an explicit target is given — no-target updates preserve existing channel.
    if [[ -n "$target_tag" ]]; then
        local _inferred_ch
        _inferred_ch=$(_infer_channel_from_version "$target_tag")
        perform_update "$target_tag" "$_inferred_ch"
    else
        perform_update "$target_tag"
    fi
}

# --- Version Comparison ---

# Rank a prerelease FAMILY for ordering: rc > beta > alpha > unknown (higher = newer). Plan 319.
_prerelease_family_rank() {
    case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
        rc)    echo 3 ;;
        beta)  echo 2 ;;
        alpha) echo 1 ;;
        *)     echo 0 ;;
    esac
}

compare_versions() {
    local v1="$1"  # installed version
    local v2="$2"  # latest version

    # Safety net: reject unparseable versions (same contract as get_installed_version)
    # Accepted: vX.Y.Z, vX.Y.Z-pre.N. Reject: "latest", "dev", empty, garbage.
    local _ver_re='^v[0-9]+\.[0-9]+\.[0-9]+(-.+)?$'
    if [[ -z "$v1" || -z "$v2" || "$v1" == "latest" || "$v2" == "latest" || "$v1" == "dev" || "$v2" == "dev" ]]; then
        return 1  # no update
    fi
    if [[ ! "$v1" =~ $_ver_re ]] || [[ ! "$v2" =~ $_ver_re ]]; then
        return 1  # no update
    fi

    # Strip leading 'v'
    v1="${v1#v}"
    v2="${v2#v}"

    # Split into base and prerelease
    local base1="${v1%%-*}"
    local base2="${v2%%-*}"
    local pre1="" pre2=""

    if [[ "$v1" == *"-"* ]]; then
        pre1="${v1#*-}"
    fi
    if [[ "$v2" == *"-"* ]]; then
        pre2="${v2#*-}"
    fi

    # Compare base version (major.minor.patch)
    local IFS='.'
    read -r maj1 min1 pat1 <<< "$base1"
    read -r maj2 min2 pat2 <<< "$base2"

    maj1=${maj1:-0}; min1=${min1:-0}; pat1=${pat1:-0}
    maj2=${maj2:-0}; min2=${min2:-0}; pat2=${pat2:-0}

    if [[ "$maj1" -lt "$maj2" ]]; then return 0; fi
    if [[ "$maj1" -gt "$maj2" ]]; then return 1; fi
    if [[ "$min1" -lt "$min2" ]]; then return 0; fi
    if [[ "$min1" -gt "$min2" ]]; then return 1; fi
    if [[ "$pat1" -lt "$pat2" ]]; then return 0; fi
    if [[ "$pat1" -gt "$pat2" ]]; then return 1; fi

    # Base versions are equal — compare prerelease
    # No prerelease > any prerelease (stable > alpha)
    if [[ -n "$pre1" && -z "$pre2" ]]; then return 0; fi  # alpha < stable
    if [[ -z "$pre1" && -n "$pre2" ]]; then return 1; fi  # stable > alpha
    if [[ -z "$pre1" && -z "$pre2" ]]; then return 1; fi  # equal

    # Both have prerelease — order by FAMILY first (rc > beta > alpha > unknown), THEN numeric suffix.
    # Family-blindness was the Plan-319 downgrade bug: "beta.1" vs "alpha.68" compared only 1 vs 68,
    # ranking alpha.68 as "newer" than beta.1. Compare the family before the number.
    local fam1="${pre1%%.*}" fam2="${pre2%%.*}"
    local rank1 rank2
    rank1="$(_prerelease_family_rank "$fam1")"
    rank2="$(_prerelease_family_rank "$fam2")"
    if [[ "$rank1" -lt "$rank2" ]]; then return 0; fi   # v1 older family (alpha < beta) → update
    if [[ "$rank1" -gt "$rank2" ]]; then return 1; fi   # v1 newer family (beta > alpha) → no update

    # Same family — compare the numeric suffix (alpha.68 vs alpha.104, beta.1 vs beta.2, ...)
    local num1="${pre1##*.}"
    local num2="${pre2##*.}"
    if [[ "$num1" =~ ^[0-9]+$ && "$num2" =~ ^[0-9]+$ ]]; then
        if [[ "$num1" -lt "$num2" ]]; then return 0; fi
    fi

    return 1  # equal or v1 >= v2
}

# --- Release Notes ---

fetch_release_notes() {
    local tag="$1"

    local response
    response=$(curl -s --max-time "$UPDATE_CURL_TIMEOUT" \
        -H "Accept: application/vnd.github.v3+json" \
        "${GITHUB_API}/releases/tags/${tag}" 2>/dev/null) || response=""

    if [[ -z "$response" ]]; then
        echo "See ${GITHUB_RELEASES_URL}"
        return
    fi

    local body=""

    # Strategy 1: jq (if available)
    if command -v jq &>/dev/null; then
        body=$(echo "$response" | jq -r '.body // empty' 2>/dev/null) || body=""
    fi

    # Strategy 2: sed extraction
    if [[ -z "$body" ]]; then
        body=$(echo "$response" | sed -n 's/.*"body"[[:space:]]*:[[:space:]]*"\(.*\)"/\1/p' | head -1 | sed 's/\\n/\n/g; s/\\r//g; s/\\"/"/g') || body=""
    fi

    # Strategy 3: URL-only fallback
    if [[ -z "$body" ]]; then
        echo "See ${GITHUB_RELEASES_URL}/tag/${tag}"
        return
    fi

    # Truncate if too long
    local line_count
    line_count=$(echo "$body" | wc -l)
    if [[ "$line_count" -gt "$MAX_RELEASE_NOTES_LINES" ]]; then
        echo "$body" | head -n "$MAX_RELEASE_NOTES_LINES"
        echo "[...truncated — see ${GITHUB_RELEASES_URL}/tag/${tag}]"
    else
        echo "$body"
    fi
}

# --- User Prompt ---

show_update_prompt() {
    local current_version="$1"
    local new_version="$2"

    # All output to stderr — stdout may be captured by eval "$(nyia completions bash)"
    echo "" >&2
    echo "================================================================" >&2
    echo "  New version available: ${current_version} -> ${new_version}" >&2
    echo "================================================================" >&2
    echo "" >&2

    echo "Release notes:" >&2
    echo "---" >&2
    fetch_release_notes "$new_version" >&2
    echo "---" >&2
    echo "" >&2
    echo "Full release: ${GITHUB_RELEASES_URL}/tag/${new_version}" >&2
    echo "" >&2
    echo "----------------------------------------------------------------" >&2
    echo "" >&2

    # Read from /dev/tty for pipe safety.
    # Print the prompt explicitly on stderr: `read -p` writes its prompt to
    # stderr, so the `2>/dev/null` below would otherwise hide it (Plan 260).
    local answer=""
    printf "Update now? [y/N] " >&2
    if ! read -r answer < /dev/tty 2>/dev/null; then
        echo "" >&2
        echo "Update prompt unavailable (no TTY), skipping." >&2
        return 1
    fi

    case "$answer" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

# --- Backup ---

backup_current_install() {
    local bin_dir="${1:?}"
    local lib_dir="${2:?}"
    local backup_dir="${NYIAKEEPER_HOME:?}/.update-backup"

    # Remove previous backup
    rm -rf "$backup_dir"
    mkdir -p "$backup_dir/bin" "$backup_dir/lib"

    # Backup bin files
    if [[ -d "$bin_dir" ]]; then
        cp -a "$bin_dir"/nyia* "$backup_dir/bin/" 2>/dev/null || true
        [[ -f "$bin_dir/assistant-template.sh" ]] && cp -a "$bin_dir/assistant-template.sh" "$backup_dir/bin/"
        [[ -f "$bin_dir/common-functions.sh" ]] && cp -a "$bin_dir/common-functions.sh" "$backup_dir/bin/"
        [[ -d "$bin_dir/common" ]] && cp -a "$bin_dir/common" "$backup_dir/bin/"
    fi

    # Backup lib files
    if [[ -d "$lib_dir" ]]; then
        cp -a "$lib_dir"/* "$backup_dir/lib/" 2>/dev/null || true
    fi

    # Save current version
    local current_version
    current_version=$(get_installed_version 2>/dev/null) || current_version="unknown"
    echo "$current_version" > "$backup_dir/VERSION"
}

# --- Checksum Verification ---

_verify_checksum() {
    local tarball="$1"
    local checksum_file="$2"

    # FAIL-CLOSED (Plan 319): never continue with an UNVERIFIED archive. A missing checksum file,
    # a checksum that is not a real SHA-256 (e.g. a saved "Not Found" 404 body → "Not"), or a missing
    # hashing tool are all hard failures — not "skip verification".
    if [[ ! -s "$checksum_file" ]]; then
        echo "Error: integrity verification failed — checksum asset missing or empty." >&2
        echo "  The release may be missing its .sha256 asset; refusing to install unverified." >&2
        return 1
    fi

    local expected_hash
    expected_hash=$(awk 'NR==1{print $1}' "$checksum_file")
    if [[ ! "$expected_hash" =~ ^[0-9a-fA-F]{64}$ ]]; then
        echo "Error: integrity verification failed — checksum is not a valid SHA-256 (got: '${expected_hash:0:16}')." >&2
        echo "  This usually means the checksum download returned an error page, not the real asset." >&2
        return 1
    fi

    local actual_hash
    if command -v sha256sum &>/dev/null; then
        actual_hash=$(sha256sum "$tarball" | awk '{print $1}')
    elif command -v shasum &>/dev/null; then
        actual_hash=$(shasum -a 256 "$tarball" | awk '{print $1}')
    else
        echo "Error: integrity verification unavailable — no sha256sum or shasum found." >&2
        echo "  Refusing to install an unverified archive; install coreutils (sha256sum) and retry." >&2
        return 1
    fi

    if [[ "$expected_hash" != "$actual_hash" ]]; then
        echo "Error: Checksum verification failed!" >&2
        echo "  Expected: $expected_hash" >&2
        echo "  Got:      $actual_hash" >&2
        return 1
    fi

    return 0
}

# --- Self-repair ---

# Offer fresh reinstall when the local update mechanism is broken (chicken-and-egg).
# Called AFTER backup is restored and lock is released — user is in a safe state.
_offer_fresh_install() {
    local channel="${1:-}"

    # Fall back to installed channel if caller didn't pass one
    if [[ -z "$channel" ]]; then
        channel=$(get_installed_channel 2>/dev/null) || channel=""
    fi

    echo "" >&2
    echo "The update mechanism may be outdated and unable to self-update." >&2
    echo "A fresh reinstall can fix this." >&2
    echo "" >&2

    local answer=""
    # Prompt on stderr so it stays visible despite the read-error suppression (Plan 260)
    printf "Reinstall now? [y/N] " >&2
    if read -r answer < /dev/tty 2>/dev/null; then
        case "$answer" in
            [yY]|[yY][eE][sS])
                echo "" >&2
                echo "Downloading fresh installer..." >&2
                if curl -fsSL "$FRESH_INSTALL_URL" | NYIA_CHANNEL="$channel" bash; then
                    echo "" >&2
                    echo "Reinstall complete. Please restart your terminal." >&2
                    return 0
                else
                    echo "Reinstall failed." >&2
                fi
                ;;
        esac
    fi

    # User declined, TTY unavailable, or reinstall failed — print manual command
    echo "" >&2
    echo "To reinstall manually:" >&2
    if [[ -n "$channel" && "$channel" != "latest" ]]; then
        echo "  NYIA_CHANNEL=$channel curl -fsSL $FRESH_INSTALL_URL | bash" >&2
    else
        echo "  curl -fsSL $FRESH_INSTALL_URL | bash" >&2
    fi
    return 1
}

# --- Release-Asset Download ---

# Maps a curl exit code to a concise, human-readable cause.
# SECURITY: This is the ONLY source of user-facing download diagnostics. We never
# pass curl's own stderr through, because with -L curl follows GitHub's redirect to
# a signed release-asset URL (containing token=/X-Amz-* params) and may echo it in
# error messages. Suppressing curl stderr and mapping the exit code here guarantees
# no signed redirect URL or secret can leak.
#
# Pinned exit-code -> cause table (see Plan 261):
#   6  -> DNS resolution failed
#   7  -> connection or proxy connection failed
#   22 -> HTTP error response (from -f; e.g. 403/404/5xx)
#   23 -> local write failed
#   28 -> download timed out
#   35 -> TLS handshake failed
#   60 -> TLS certificate validation failed
#   *  -> download failed (curl code shown for reference)
_curl_exit_cause() {
    local code="$1"
    case "$code" in
        6)  echo "DNS resolution failed" ;;
        7)  echo "connection or proxy connection failed" ;;
        22) echo "HTTP error response from GitHub or the release asset host" ;;
        23) echo "local write failed" ;;
        28) echo "download timed out" ;;
        35) echo "TLS handshake failed" ;;
        60) echo "TLS certificate validation failed" ;;
        *)  echo "download failed" ;;
    esac
}

# Downloads a release asset with fail-fast HTTP handling and mapped diagnostics.
#   $1 = destination file
#   $2 = public GitHub release URL (only this URL is ever printed)
#   $3 = max-time seconds
#   $4 = mode: "mandatory" (default) prints "Error:" diagnostics on failure;
#        "warn" prints a single "Warning:" line and the caller decides whether to continue.
# Returns curl's exit code (0 on success).
#
# Flags: -f (fail fast on HTTP >=400 so error pages are not saved as a tarball),
#        -s (silent — no progress meter / no stderr leakage),
#        -L (follow redirects to the signed asset host),
#        --retry/--retry-delay for transient release-asset failures.
# curl stderr is suppressed (2>/dev/null) so signed redirect URLs cannot leak;
# all diagnostics come from _curl_exit_cause() against the captured exit code.
_download_release_asset() {
    local dest="$1"
    local public_url="$2"
    local max_time="$3"
    local mode="${4:-mandatory}"

    curl -fsL --max-time "$max_time" --retry 2 --retry-delay 1 \
        -o "$dest" "$public_url" 2>/dev/null
    local code=$?

    if [[ "$code" -ne 0 ]]; then
        local cause
        cause=$(_curl_exit_cause "$code")
        if [[ "$mode" == "warn" ]]; then
            echo "Warning: Download failed (curl exit $code: $cause) from $public_url" >&2
        else
            echo "Error: Failed to download from $public_url" >&2
            echo "  curl exit $code: $cause" >&2
        fi
    fi

    return "$code"
}

# --- Update ---

perform_update() {
    local target_tag="${1:-}"
    # Optional: channel context for this update.  When non-empty the CHANNEL
    # state file is updated to match so future update checks stay on the same channel.
    local channel_context="${2:-}"

    if ! acquire_update_lock; then
        echo "Another update is in progress. Please try again later." >&2
        return 1
    fi

    # Determine target version
    if [[ -z "$target_tag" ]]; then
        local current
        current=$(get_installed_version 2>/dev/null) || current=""
        # Use installed channel to drive resolution
        local ch
        ch=$(get_installed_channel)
        target_tag=$(fetch_latest_version "$current" "$ch")
        if [[ -z "$target_tag" ]]; then
            echo "Error: Could not determine latest version." >&2
            release_update_lock
            return 1
        fi
        # User explicitly ran update — write cache immediately
        _write_update_cache "$target_tag" "$current"
    fi

    # Determine install directories
    local bin_dir lib_dir
    bin_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" 2>/dev/null && pwd)" || bin_dir="$HOME/.local/bin"
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib/nyiakeeper" 2>/dev/null && pwd)" || lib_dir="$HOME/.local/lib/nyiakeeper"

    # Fallback: use parent of common-functions.sh location
    if [[ ! -d "$bin_dir" ]]; then
        bin_dir="$HOME/.local/bin"
    fi
    if [[ ! -d "$lib_dir" ]]; then
        lib_dir="$HOME/.local/lib/nyiakeeper"
    fi

    local tmp_dir="${TMPDIR:-/tmp}/nyia-update-$$"
    local staging_dir="${TMPDIR:-/tmp}/nyia-staging-$$"
    local tarball_url="${GITHUB_RELEASES_URL}/download/${target_tag}/nyiakeeper-runtime.tar.gz"
    local checksum_url="${GITHUB_RELEASES_URL}/download/${target_tag}/nyiakeeper-runtime.tar.gz.sha256"

    # Cleanup function
    _update_cleanup() {
        rm -rf "$tmp_dir" "$staging_dir"
    }

    mkdir -p "$tmp_dir" "$staging_dir"

    echo "Downloading ${target_tag}..."

    # Download tarball (mandatory — abort before extraction on any failure)
    if ! _download_release_asset "$tmp_dir/nyiakeeper-runtime.tar.gz" \
        "$tarball_url" "$UPDATE_TARBALL_TIMEOUT" "mandatory"; then
        _update_cleanup
        release_update_lock
        return 1
    fi

    # Download checksum (MANDATORY — never install an unverified archive; Plan 319 fail-closed).
    if ! _download_release_asset "$tmp_dir/nyiakeeper-runtime.tar.gz.sha256" \
        "$checksum_url" "$UPDATE_CHECKSUM_TIMEOUT" "mandatory"; then
        echo "Error: could not download the checksum asset for ${target_tag}." >&2
        echo "  Refusing to install an unverified archive (the release may be missing its .sha256)." >&2
        _update_cleanup
        release_update_lock
        return 1
    fi

    # Verify checksum (fail-closed: missing/invalid/mismatch all abort before extraction)
    if ! _verify_checksum "$tmp_dir/nyiakeeper-runtime.tar.gz" "$tmp_dir/nyiakeeper-runtime.tar.gz.sha256"; then
        echo "Error: Checksum verification failed. Aborting update." >&2
        _update_cleanup
        release_update_lock
        return 1
    fi

    # Defense-in-depth: the (verified) archive must be a well-formed gzip before extraction (Plan 319).
    if ! gzip -t "$tmp_dir/nyiakeeper-runtime.tar.gz" 2>/dev/null; then
        echo "Error: downloaded archive is not a valid gzip. Aborting update." >&2
        _update_cleanup
        release_update_lock
        return 1
    fi

    echo "Extracting..."

    # Extract to staging
    if ! tar -xzf "$tmp_dir/nyiakeeper-runtime.tar.gz" -C "$staging_dir"; then
        echo "Error: Failed to extract tarball." >&2
        _update_cleanup
        release_update_lock
        return 1
    fi

    # Backup current install
    echo "Backing up current installation..."
    backup_current_install "$bin_dir" "$lib_dir"

    # Run setup.sh from staging to install new version.
    # setup.sh handles: bin/lib copy, docker/ copy, config, VERSION, path patching, skill seeding.
    # It expects CWD to contain bin/, lib/, docker/, config/, VERSION — the full tarball layout.
    # Previous approach (staged swap + setup.sh) was broken: swap moved bin/lib out of staging
    # before setup.sh ran, causing "bin directory not found" or "copy to self" errors.
    # Recovery on failure: _restore_from_backup() uses .update-backup/ created above.
    echo "Installing ${target_tag}..."
    if [[ -f "$staging_dir/setup.sh" ]]; then
        if ! (cd "$staging_dir" && bash ./setup.sh) 2>/dev/null; then
            echo "Error: setup.sh failed. Restoring from backup..." >&2
            _restore_from_backup "$bin_dir" "$lib_dir"
            release_update_lock
            if _offer_fresh_install "$channel_context"; then
                _update_cleanup
                return 0
            fi
            _update_cleanup
            return 1
        fi
    else
        echo "Error: setup.sh not found in update package." >&2
        _update_cleanup
        release_update_lock
        return 1
    fi

    # Persist channel selection so future update checks stay on the same channel.
    if [[ -n "$channel_context" ]]; then
        set_installed_channel "$channel_context" 2>/dev/null || true
    fi

    # Verify version — assert installed version matches the target
    local new_version
    new_version=$(get_installed_version 2>/dev/null) || new_version=""
    if [[ -n "$new_version" && "$new_version" == "$target_tag" ]]; then
        echo "Successfully updated to ${new_version}"
    elif [[ -n "$new_version" && "$new_version" != "$target_tag" ]]; then
        echo "Error: Update failed — installed version is still ${new_version} (expected ${target_tag})" >&2
        echo "Restoring previous version..." >&2
        _restore_from_backup "$bin_dir" "$lib_dir"
        release_update_lock
        if _offer_fresh_install "$channel_context"; then
            _update_cleanup
            return 0
        fi
        _update_cleanup
        return 1
    else
        echo "Update installed. Please restart your terminal."
    fi

    _update_cleanup
    release_update_lock
    return 0
}

_restore_from_backup() {
    local bin_dir="$1"
    local lib_dir="$2"
    local backup_dir="${NYIAKEEPER_HOME:?}/.update-backup"
    local restore_failed=false

    if [[ ! -d "$backup_dir" ]]; then
        echo "Error: No backup found to restore from." >&2
        return 1
    fi

    # Restore bin
    if [[ -d "$backup_dir/bin" ]]; then
        rm -rf "$bin_dir"
        mkdir -p "$bin_dir"
        if ! cp -a "$backup_dir/bin"/* "$bin_dir/" 2>/dev/null; then
            echo "Error: Failed to restore bin/ from backup." >&2
            restore_failed=true
        fi
    fi

    # Restore lib
    if [[ -d "$backup_dir/lib" ]]; then
        rm -rf "$lib_dir"
        mkdir -p "$lib_dir"
        if ! cp -a "$backup_dir/lib"/* "$lib_dir/" 2>/dev/null; then
            echo "Error: Failed to restore lib/ from backup." >&2
            restore_failed=true
        fi
    fi

    # Restore version
    if [[ -f "$backup_dir/VERSION" ]]; then
        local backup_version
        backup_version=$(cat "$backup_dir/VERSION")
        set_installed_version "$backup_version" 2>/dev/null || true
    fi

    if [[ "$restore_failed" == "true" ]]; then
        return 1
    fi
}

# --- Rollback ---

perform_rollback() {
    if ! acquire_update_lock; then
        echo "Another update is in progress. Please try again later." >&2
        return 1
    fi

    local backup_dir="${NYIAKEEPER_HOME:?}/.update-backup"

    if [[ ! -d "$backup_dir" ]]; then
        echo "No backup found. Cannot rollback." >&2
        echo "Rollback is only available after a successful update." >&2
        release_update_lock
        return 1
    fi

    local backup_version="unknown"
    if [[ -f "$backup_dir/VERSION" ]]; then
        backup_version=$(cat "$backup_dir/VERSION")
    fi

    local current_version
    current_version=$(get_installed_version 2>/dev/null) || current_version="unknown"

    echo ""
    echo "Rollback: ${current_version} -> ${backup_version}"
    echo ""

    local answer=""
    # Prompt on stderr so it stays visible despite the read-error suppression (Plan 260)
    printf "Rollback to %s? [y/N] " "${backup_version}" >&2
    read -r answer < /dev/tty 2>/dev/null || answer="n"

    case "$answer" in
        [yY]|[yY][eE][sS]) ;;
        *)
            echo "Rollback cancelled."
            release_update_lock
            return 0
            ;;
    esac

    local bin_dir lib_dir
    bin_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" 2>/dev/null && pwd)" || bin_dir="$HOME/.local/bin"
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib/nyiakeeper" 2>/dev/null && pwd)" || lib_dir="$HOME/.local/lib/nyiakeeper"

    echo "Restoring ${backup_version}..."
    if _restore_from_backup "$bin_dir" "$lib_dir"; then
        echo "Successfully rolled back to ${backup_version}"
        release_update_lock
        return 0
    else
        echo "Error: Rollback encountered errors. Installation may be in an inconsistent state." >&2
        echo "Backup files are preserved at: $backup_dir" >&2
        release_update_lock
        return 1
    fi
}

# --- Main Entry Point ---

# Plan 320: one-time alpha EOL notice. Alpha is frozen (pinned at v0.1.0-alpha.103); show a
# migrate-to-beta notice ONCE, DURABLY (a versioned marker survives restarts), INDEPENDENT of whether
# an update is available (the frozen alpha never has a newer version). Marker written atomically AFTER
# a successful display; a read-only home simply re-shows next launch. No TTY guard here so it is unit-
# testable — the launch call site gates on an interactive terminal.
_ALPHA_EOL_MARKER_VERSION="1"
_maybe_show_alpha_eol_notice() {
    local nyia_home="${NYIAKEEPER_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/nyiakeeper}"
    local marker="$nyia_home/.alpha-eol-notice.v${_ALPHA_EOL_MARKER_VERSION}"

    local channel
    channel=$(get_installed_channel 2>/dev/null) || channel=""
    [[ "$channel" == "alpha" ]] || return 0     # only alpha installs
    [[ -f "$marker" ]] && return 0              # already shown (durable one-time)

    echo "" >&2
    echo "⚠️  The 'alpha' channel is deprecated and frozen — alpha is over; Nyia Keeper is on beta now." >&2
    echo "    Your alpha install keeps working (pinned to v0.1.0-alpha.103) but no longer receives updates." >&2
    echo "    Switch to beta:  nyia update install beta" >&2
    echo "" >&2

    # Record atomically AFTER display; best-effort (read-only home just re-shows next time).
    mkdir -p "$nyia_home" 2>/dev/null || return 0
    local tmp="$marker.tmp.$$"
    if printf 'shown\n' > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$marker" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    fi
    return 0
}

# Plan 331f: a once-ever, durable heads-up that the plan storage layout changed. Migration is per-PROJECT (the
# launch gate), and there is no global project registry, so this only INFORMS — it migrates nothing. Mirrors
# _maybe_show_alpha_eol_notice: versioned durable marker, print-then-record atomically, best-effort on a
# read-only home (re-shows next time). TTY-gating is the caller's job (assistant-template.sh).
_LAYOUT_CHANGE_MARKER_VERSION="1"
_maybe_show_layout_change_notice() {
    local nyia_home="${NYIAKEEPER_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/nyiakeeper}"
    local marker="$nyia_home/.layout-change-notice.v${_LAYOUT_CHANGE_MARKER_VERSION}"
    [[ -f "$marker" ]] && return 0              # already shown (durable one-time)

    echo "" >&2
    echo "ℹ️  This version changes the plan layout." >&2
    echo "    Projects still on the old layout will prompt you to migrate (a backup is made first) until you do." >&2
    echo "" >&2

    # Record atomically AFTER display; best-effort (a read-only home just re-shows next time).
    mkdir -p "$nyia_home" 2>/dev/null || return 0
    local tmp="$marker.tmp.$$"
    if printf 'shown\n' > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$marker" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    fi
    return 0
}

# _maybe_offer_channel_rollback <installed> <pointer> <channel>
#   0 = this WAS a rollback and it has been handled (caller should stop)
#   1 = not a rollback (the pointer is newer or equal) — carry on with the normal update path
#
# Before Plan 344 a backward pointer produced pure SILENCE: compare_versions returns non-zero and
# the update block was simply skipped, so a user on a withdrawn version was never told — while
# their IMAGES rolled back on the next launch (the launcher re-pulls the floating channel tag),
# leaving dist and image skewed. A decline is remembered durably: the check runs hourly, so a
# timestamp alone would re-ask forever.
_maybe_offer_channel_rollback() {
    local current="$1" pointer="$2" channel="$3"
    [[ -n "$current" && -n "$pointer" ]] || return 1
    [[ "$current" != "$pointer" ]] || return 1
    compare_versions "$current" "$pointer" && return 1      # pointer is NEWER: normal update path

    local _home="${NYIAKEEPER_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/nyiakeeper}"
    mkdir -p "$_home" 2>/dev/null || true
    local marker="${_home}/.rollback-declined"
    local declined=""
    [[ -f "$marker" ]] && declined="$(tr -d '[:space:]' < "$marker" 2>/dev/null)"
    if [[ "$declined" == "$pointer" ]]; then
        return 0                                            # already declined THIS rollback: stay quiet
    fi

    echo "" >&2
    echo "⚠️  The '${channel}' channel was rolled back to ${pointer}" >&2
    echo "   (you have ${current} installed — its images are no longer published)." >&2
    if [[ -t 0 ]]; then
        local answer=""
        printf "   Install %s now? [y/N]: " "$pointer" >&2
        read -r answer || answer=""
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            _write_update_cache "$pointer" "$current"
            perform_update "$pointer" "$channel"
            return 0
        fi
        if ! printf '%s\n' "$pointer" > "$marker" 2>/dev/null; then
            # Cannot remember the decline (read-only home): fall back to the check timestamp so the
            # user is not re-prompted on every single launch.
            _write_check_timestamp 2>/dev/null || true
        fi
        _write_check_timestamp 2>/dev/null || true   # also throttle the network check itself
        echo "   Skipped. Install it later with:  nyia update install ${pointer}" >&2
        return 0
    fi
    echo "   Install it with:  nyia update install ${pointer}" >&2
    return 0
}

check_for_updates_if_due() {
    # Guard: VERSION file must exist — resolve config dir without side effects
    local _config_root="${XDG_CONFIG_HOME:-$HOME/.config}/nyiakeeper"
    local version_file="$_config_root/VERSION"
    # Check config dir first, then lib dir fallback
    if [[ ! -f "$version_file" ]]; then
        version_file="$HOME/.local/lib/nyiakeeper/VERSION"
    fi
    if [[ ! -f "$version_file" ]]; then
        return 0
    fi

    # Ensure NYIAKEEPER_HOME is set — downstream functions (is_update_check_due,
    # acquire_update_lock) use ${NYIAKEEPER_HOME:?} for cache/lock paths
    if [[ -z "${NYIAKEEPER_HOME:-}" ]]; then
        NYIAKEEPER_HOME="$_config_root"
    fi

    # Guard: must be a fully interactive TTY (both stdin AND stdout)
    # Inside eval "$(nyia completions bash)", stdout is a pipe — skip update check
    if [[ ! -t 0 ]] || [[ ! -t 1 ]]; then
        return 0
    fi

    # Guard: throttle
    if ! is_update_check_due; then
        return 0
    fi

    if ! acquire_update_lock; then
        return 0
    fi

    local current_version
    current_version=$(get_installed_version 2>/dev/null) || {
        release_update_lock
        return 0
    }

    local installed_channel
    installed_channel=$(get_installed_channel)

    echo "Checking for new version (channel: $installed_channel)..." >&2

    local latest_version
    latest_version=$(fetch_latest_version "$current_version" "$installed_channel")

    if [[ -z "$latest_version" ]]; then
        # 'latest' is the default/stable channel: when no stable exists yet it fails closed — but
        # guide the user rather than going silent (Plan 319 review). Other channels stay quiet (an
        # empty result there is usually a transient network/manifest miss).
        if [[ "$installed_channel" == "$CHANNEL_LATEST" ]]; then
            echo "No stable release available yet on the 'latest' channel." >&2
            echo "  Switch to the beta channel with:  nyia update install beta" >&2
        fi
        release_update_lock
        return 0
    fi

    # Plan 344: the channel pointer can also move BACKWARD (a maintainer rolled a bad release back).
    # Handled by _maybe_offer_channel_rollback so it is testable on its own — the enclosing function
    # is TTY-gated and cannot be exercised headlessly.
    if _maybe_offer_channel_rollback "$current_version" "$latest_version" "$installed_channel"; then
        release_update_lock
        return 0
    fi

    # Compare
    if compare_versions "$current_version" "$latest_version"; then
        if show_update_prompt "$current_version" "$latest_version"; then
            # User accepted — write cache so throttle window starts now
            _write_update_cache "$latest_version" "$current_version"
            # Pass the installed channel so perform_update preserves channel state.
            perform_update "$latest_version" "$installed_channel"
        else
            # User declined — write only the check timestamp so throttle prevents
            # per-command spam, but don't cache version info. Re-prompts after interval.
            _write_check_timestamp
            echo "Update skipped. Run 'nyia update install' to update later."
        fi
    fi

    release_update_lock
    return 0
}
