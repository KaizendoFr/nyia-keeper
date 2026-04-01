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
readonly UPDATE_CURL_TIMEOUT=5       # seconds
readonly GITHUB_REPO="KaizendoFr/nyia-keeper"
readonly GITHUB_API="https://api.github.com/repos/${GITHUB_REPO}"
readonly GITHUB_RELEASES_URL="https://github.com/${GITHUB_REPO}/releases"
# Public installer URL — this IS the scripts/public-install.sh contract, served via
# raw GitHub content. Same URL users use for first install.
readonly FRESH_INSTALL_URL="https://raw.githubusercontent.com/${GITHUB_REPO}/main/install.sh"
readonly MAX_RELEASE_NOTES_LINES=20
readonly LOCK_STALE_TIMEOUT=300      # 5 minutes — real updates can exceed 60s on slow connections

# Channel manifest URL — hosted on the public runtime repo (raw content).
# Maps channel names ("latest", "alpha") to immutable release tags.
# Updated automatically for "latest" on every release.sh --push.
# Updated manually for "alpha" via scripts/promote-channel.sh.
readonly CHANNELS_MANIFEST_URL="https://raw.githubusercontent.com/KaizendoFr/nyia-keeper/main/channels.json"

# Approved channel names for channel-aware resolution.
readonly CHANNEL_LATEST="latest"
readonly CHANNEL_ALPHA="alpha"

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
# File: $NYIAKEEPER_HOME/CHANNEL   (single line: "latest", "alpha", or empty = latest)
# An empty or missing CHANNEL file is treated as the "latest" channel.

get_installed_channel() {
    local nyia_home="${NYIAKEEPER_HOME:-}"
    # Fall back to XDG config dir if NYIAKEEPER_HOME not set
    if [[ -z "$nyia_home" ]]; then
        nyia_home="${XDG_CONFIG_HOME:-$HOME/.config}/nyiakeeper"
    fi
    local channel_file="$nyia_home/CHANNEL"

    # Environment variable wins (allows scripted overrides without modifying state)
    if [[ -n "${NYIA_CHANNEL:-}" ]]; then
        echo "$NYIA_CHANNEL"
        return 0
    fi

    if [[ -f "$channel_file" ]]; then
        local ch
        ch=$(tr -d '[:space:]' < "$channel_file" | head -1)
        if [[ -n "$ch" ]]; then
            echo "$ch"
            return 0
        fi
    fi

    # Default channel: latest
    echo "$CHANNEL_LATEST"
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
# Matches the CI pipeline tagging logic (pipeline.yml:288-293):
#   version contains "-alpha." → "alpha"
#   everything else            → "latest"
_infer_channel_from_version() {
    local version="${1:-}"
    if [[ "$version" == *-alpha.* ]]; then
        echo "alpha"
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
    response=$(curl -s --max-time "$UPDATE_CURL_TIMEOUT" \
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
    # "latest" = promoted stable, "alpha" = bleeding edge.
    # Unknown/invalid channels: manifest returns empty → falls through to GitHub API.
    local manifest_tag
    manifest_tag=$(fetch_channel_version "$installed_channel") || manifest_tag=""
    if [[ -n "$manifest_tag" ]]; then
        echo "$manifest_tag"
        return 0
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

    # Stage 2: fallback to /releases (for prerelease-only repos)
    if [[ -z "$tag" ]]; then
        response=$(curl -s --max-time "$UPDATE_CURL_TIMEOUT" \
            -H "Accept: application/vnd.github.v3+json" \
            "${GITHUB_API}/releases?per_page=10" 2>/dev/null) || response=""

        if [[ -n "$response" ]]; then
            # If current version is alpha, prefer alpha tags
            if [[ "$current_version" == *"-alpha."* ]]; then
                tag=$(echo "$response" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*-alpha\.[^"]*"' | head -1 | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
            fi
            # If no alpha match or not alpha, take first tag
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

list_available_versions() {
    local response
    response=$(curl -s --max-time "$UPDATE_CURL_TIMEOUT" \
        -H "Accept: application/vnd.github.v3+json" \
        "${GITHUB_API}/releases?per_page=10" 2>/dev/null) || response=""

    if [[ -z "$response" ]]; then
        echo "Error: Could not fetch releases from GitHub." >&2
        return 1
    fi

    # Extract all tag_name values
    local -a tags=()
    while IFS= read -r t; do
        tags+=("$t")
    done < <(echo "$response" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')

    if [[ ${#tags[@]} -eq 0 ]]; then
        echo "No releases found." >&2
        return 1
    fi

    # Extract published_at dates
    local -a dates=()
    while IFS= read -r d; do
        dates+=("${d:0:10}")  # keep YYYY-MM-DD only
    done < <(echo "$response" | grep -o '"published_at"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"published_at"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')

    # Get current installed version for marker
    local current
    current=$(get_installed_version 2>/dev/null) || current=""

    echo "Available versions (last ${#tags[@]}):"
    echo ""

    # If date count matches tag count, show dates; otherwise tag-only
    if [[ ${#dates[@]} -eq ${#tags[@]} ]]; then
        printf "  %-28s %-14s %s\n" "TAG" "DATE" "STATUS"
        for i in "${!tags[@]}"; do
            local marker=""
            if [[ "${tags[$i]}" == "$current" ]]; then
                marker="← installed"
            fi
            printf "  %-28s %-14s %s\n" "${tags[$i]}" "${dates[$i]}" "$marker"
        done
    else
        printf "  %-28s %s\n" "TAG" "STATUS"
        for i in "${!tags[@]}"; do
            local marker=""
            if [[ "${tags[$i]}" == "$current" ]]; then
                marker="← installed"
            fi
            printf "  %-28s %s\n" "${tags[$i]}" "$marker"
        done
    fi

    echo ""
    echo "To switch: nyia update install <version>"
}

# --- CLI-targeted Update Wrapper ---

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

    # Both have prerelease — compare alpha.N
    local num1="${pre1##*.}"
    local num2="${pre2##*.}"

    # Handle non-numeric suffixes
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

    echo ""
    echo "================================================================"
    echo "  New version available: ${current_version} -> ${new_version}"
    echo "================================================================"
    echo ""

    echo "Release notes:"
    echo "---"
    fetch_release_notes "$new_version"
    echo "---"
    echo ""
    echo "Full release: ${GITHUB_RELEASES_URL}/tag/${new_version}"
    echo ""
    echo "----------------------------------------------------------------"
    echo ""

    # Read from /dev/tty for pipe safety
    local answer=""
    if ! read -r -p "Update now? [y/N] " answer < /dev/tty 2>/dev/null; then
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

    if [[ ! -f "$checksum_file" ]]; then
        echo "Warning: No checksum file available. Skipping verification." >&2
        return 0
    fi

    local expected_hash
    expected_hash=$(awk '{print $1}' "$checksum_file")
    local actual_hash

    if command -v sha256sum &>/dev/null; then
        actual_hash=$(sha256sum "$tarball" | awk '{print $1}')
    elif command -v shasum &>/dev/null; then
        actual_hash=$(shasum -a 256 "$tarball" | awk '{print $1}')
    else
        echo "Warning: No sha256sum or shasum available. Skipping verification." >&2
        return 0
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
    if read -r -p "Reinstall now? [y/N] " answer < /dev/tty 2>/dev/null; then
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

    # Download tarball
    if ! curl -sL --max-time 60 -o "$tmp_dir/nyiakeeper-runtime.tar.gz" "$tarball_url"; then
        echo "Error: Failed to download tarball from $tarball_url" >&2
        _update_cleanup
        release_update_lock
        return 1
    fi

    # Download checksum (best-effort — warn if unavailable)
    if ! curl -sL --max-time 10 -o "$tmp_dir/nyiakeeper-runtime.tar.gz.sha256" "$checksum_url" 2>/dev/null; then
        echo "Warning: Could not download checksum file. Skipping integrity verification." >&2
    fi

    # Verify checksum
    if ! _verify_checksum "$tmp_dir/nyiakeeper-runtime.tar.gz" "$tmp_dir/nyiakeeper-runtime.tar.gz.sha256"; then
        echo "Error: Checksum verification failed. Aborting update." >&2
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
    read -r -p "Rollback to ${backup_version}? [y/N] " answer < /dev/tty 2>/dev/null || answer="n"

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

    # Guard: must be a TTY
    if [[ ! -t 0 ]] && [[ ! -t 1 ]]; then
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
