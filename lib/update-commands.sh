#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later OR Proprietary
# Copyright (c) 2024 Nyia Keeper Contributors
# Update subcommand implementations for nyia (Plan 213)
# Provides: status, list, check, install, rollback, help
# Delegates to lib/auto-update.sh for core operations.

# Source guard — prevent double-loading
[[ -n "${_UPDATE_COMMANDS_LOADED:-}" ]] && return 0
_UPDATE_COMMANDS_LOADED=1

# Ensure auto-update library is loaded (provides perform_update, perform_rollback, etc.)
if ! declare -f perform_update >/dev/null 2>&1; then
    _update_cmds_dir="$(dirname "${BASH_SOURCE[0]}")"
    if [[ -f "$_update_cmds_dir/auto-update.sh" ]]; then
        source "$_update_cmds_dir/auto-update.sh"
    else
        echo "Error: auto-update.sh library not found" >&2
        return 1
    fi
fi

# --- Help ---

update_help() {
    cat <<'HELPEOF'
Usage: nyia update <subcommand> [options]

Subcommands:
  status                Show installed version, channel, and last check time
  list                  Show available channels and recent releases
  check                 Check for updates (manual)
  install [target]      Install update by channel name (latest|beta|alpha) or version tag
  rollback              Rollback to previous version
  help                  Show this help

Backward-compatible shortcuts:
  nyia update                     Same as: nyia update install (latest for channel)
  nyia update v0.1.0-alpha.50     Same as: nyia update install v0.1.0-alpha.50
  nyia update --list              Same as: nyia update list
  nyia rollback                   Same as: nyia update rollback

Examples:
  nyia update status              # Show version and channel info
  nyia update list                # Show available versions
  nyia update check               # Check if an update is available
  nyia update install             # Install latest for your channel
  nyia update install beta        # Switch to beta channel and install (when available)
  nyia update install alpha       # Switch to alpha channel and install
  nyia update install latest      # Switch to latest (stable) channel
  nyia update install v0.1.0-alpha.50  # Install specific version
  nyia update rollback            # Rollback to previous version

Note: the "beta" channel is fail-closed — until a beta release is published it is
      reported as unavailable and NEVER falls back to the stable "latest" channel.
HELPEOF
}

# --- Status ---

update_status() {
    local version
    version=$(get_installed_version 2>/dev/null) || version="unknown"

    local channel
    channel=$(get_installed_channel 2>/dev/null) || channel="unknown"

    local nyia_home="${NYIAKEEPER_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/nyiakeeper}"

    echo "Nyia Keeper Update Status"
    echo ""
    echo "  Installed version: $version"
    echo "  Channel:           $channel"
    echo "  NYIAKEEPER_HOME:   $nyia_home"

    # Show last check time from .update-cache
    local cache_file="$nyia_home/.update-cache"
    if [[ -f "$cache_file" ]]; then
        local last_check=0 cached_latest="" cached_current=""
        while IFS='=' read -r key value; do
            case "$key" in
                LAST_CHECK) last_check="$value" ;;
                LATEST_TAG) cached_latest="$value" ;;
                CURRENT_TAG) cached_current="$value" ;;
            esac
        done < "$cache_file"

        if [[ "$last_check" -gt 0 ]]; then
            # Format timestamp in a portable way
            local formatted_time
            if date -d "@$last_check" "+%Y-%m-%d %H:%M:%S" 2>/dev/null; then
                formatted_time=$(date -d "@$last_check" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
            elif date -r "$last_check" "+%Y-%m-%d %H:%M:%S" 2>/dev/null; then
                formatted_time=$(date -r "$last_check" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
            else
                formatted_time="$last_check (unix timestamp)"
            fi
            echo "  Last check:        $formatted_time"
        else
            echo "  Last check:        never"
        fi

        if [[ -n "$cached_latest" ]]; then
            echo "  Cached latest:     $cached_latest"
        fi
    else
        echo "  Last check:        never"
    fi
    echo ""
}

# --- List ---

update_list() {
    # Show channels
    echo "Channels:"
    echo ""

    local current_channel
    current_channel=$(get_installed_channel 2>/dev/null) || current_channel="latest"

    local current_version
    current_version=$(get_installed_version 2>/dev/null) || current_version=""

    # Fetch channel versions (best-effort).
    # beta is fail-closed (Plan 312c): when the manifest has no "beta" key yet,
    # fetch_channel_version returns non-zero and the row shows "(unavailable)" — it is
    # NEVER shown resolving to the stable "latest" tag.
    local latest_tag alpha_tag beta_tag
    latest_tag=$(fetch_channel_version "$CHANNEL_LATEST" 2>/dev/null) || latest_tag="(unavailable)"
    alpha_tag=$(fetch_channel_version "$CHANNEL_ALPHA" 2>/dev/null) || alpha_tag="(unavailable)"
    beta_tag=$(fetch_channel_version "$CHANNEL_BETA" 2>/dev/null) || beta_tag="(unavailable)"

    # Show installed version in the row matching the active channel
    local latest_installed="" alpha_installed="" beta_installed=""
    if [[ "$current_channel" == "latest" && -n "$current_version" ]]; then
        latest_installed="$current_version"
    elif [[ "$current_channel" == "alpha" && -n "$current_version" ]]; then
        alpha_installed="$current_version"
    elif [[ "$current_channel" == "beta" && -n "$current_version" ]]; then
        beta_installed="$current_version"
    fi

    # Ordered most-stable → least-stable: latest, beta, alpha.
    printf "  %-10s %-28s %s\n" "CHANNEL" "LATEST" "INSTALLED"
    printf "  %-10s %-28s %s\n" "latest" "$latest_tag" "$latest_installed"
    printf "  %-10s %-28s %s\n" "beta" "$beta_tag" "$beta_installed"
    printf "  %-10s %-28s %s\n" "alpha" "$alpha_tag" "$alpha_installed"
    echo ""

    # Show recent releases
    list_available_versions
}

# --- Check ---

update_check() {
    local current_version
    current_version=$(get_installed_version 2>/dev/null) || current_version=""

    if [[ -z "$current_version" || "$current_version" == "latest" || "$current_version" == "dev" ]]; then
        echo "Cannot check for updates: installed version is '$current_version'"
        echo "Version checking requires a proper version tag (e.g., v0.1.0-alpha.50)"
        return 1
    fi

    local channel
    channel=$(get_installed_channel 2>/dev/null) || channel="latest"

    echo "Checking for updates (channel: $channel)..."
    echo "  Installed: $current_version"
    echo ""

    local latest_version
    latest_version=$(fetch_latest_version "$current_version" "$channel")

    if [[ -z "$latest_version" ]]; then
        # Fail-closed for beta (Plan 312c): resolution returns empty EITHER when the
        # manifest has no "beta" key yet OR when the manifest could not be fetched
        # (a transient network/GitHub outage). Report both possible causes plainly
        # instead of asserting it is simply unpublished, and NEVER fall back to the
        # stable "latest" channel.
        if [[ "$channel" == "$CHANNEL_BETA" ]]; then
            echo "The 'beta' channel is not available (unpublished, or could not be resolved)."
            echo "No beta release has been published yet, or the channel manifest could not be reached"
            echo "(a transient network/GitHub error) — if a beta was recently cut, retry shortly."
            echo "(Not falling back to the stable 'latest' channel.)"
            return 1
        fi
        echo "Could not determine latest version. Check your internet connection."
        return 1
    fi

    # User explicitly asked to check — write cache immediately (throttle is appropriate)
    _write_update_cache "$latest_version" "$current_version"

    echo "  Latest:    $latest_version"
    echo ""

    if compare_versions "$current_version" "$latest_version"; then
        echo "Update available: $current_version -> $latest_version"
        echo ""
        echo "Release notes:"
        echo "---"
        fetch_release_notes "$latest_version"
        echo "---"
        echo ""
        echo "To install: nyia update install"
        echo "       or:  nyia update install $latest_version"
    else
        echo "You are up to date."
    fi
}

# --- Install ---

update_install() {
    local target="${1:-}"

    # Fail-closed pre-check for the beta channel (Plan 312c; fail-closed-by-absence, Plan 312a):
    # Resolve beta BEFORE the interactive-TTY guard so an unavailable beta is rejected in EVERY
    # context (including non-interactive/piped) and can NEVER silently fall back to the stable
    # ":latest" channel. alpha/latest keep their original ordering (TTY guard first) for
    # byte-for-behavior parity — only the beta target is gated here.
    if [[ "$target" == "$CHANNEL_BETA" ]]; then
        local _beta_probe
        _beta_probe=$(fetch_channel_version "$CHANNEL_BETA" 2>/dev/null) || _beta_probe=""
        if [[ -z "$_beta_probe" ]]; then
            echo "Error: The 'beta' channel is not available (unpublished, or could not be resolved)." >&2
            echo "  No beta release has been published yet, or the channel manifest could not be reached" >&2
            echo "  (a transient network/GitHub error). If a beta was recently cut, retry shortly." >&2
            echo "  (Not falling back to the stable 'latest' channel.)" >&2
            return 1
        fi
    fi

    # TTY check: interactive install requires a terminal
    if [[ ! -t 0 ]] && [[ ! -t 1 ]]; then
        echo "Update requires an interactive terminal."
        echo "To update manually, download the latest release from:"
        echo "  https://github.com/KaizendoFr/nyia-keeper/releases"
        return 1
    fi

    # Ensure auto-update library is available
    if ! type perform_update &>/dev/null; then
        echo "Error: Auto-update library not available." >&2
        return 1
    fi

    # Resolve channel names to version tags
    local channel_context=""
    case "$target" in
        latest)
            echo "Switching to 'latest' (stable) channel..."
            channel_context="latest"
            target=$(fetch_channel_version "$CHANNEL_LATEST" 2>/dev/null) || target=""
            if [[ -z "$target" ]]; then
                echo "Error: Could not resolve 'latest' channel version." >&2
                return 1
            fi
            echo "  Resolved: $target"
            ;;
        alpha)
            echo "Switching to 'alpha' channel..."
            channel_context="alpha"
            target=$(fetch_channel_version "$CHANNEL_ALPHA" 2>/dev/null) || target=""
            if [[ -z "$target" ]]; then
                echo "Error: Could not resolve 'alpha' channel version." >&2
                return 1
            fi
            echo "  Resolved: $target"
            ;;
        beta)
            # Mirrors the alpha branch. Fail-closed: if beta is unavailable (no manifest
            # key yet) it aborts here and NEVER falls back to the stable "latest" channel.
            # The pre-TTY gate above already rejects an unavailable beta, so on this path
            # beta is available; the guard below is defense-in-depth.
            echo "Switching to 'beta' channel..."
            channel_context="beta"
            target=$(fetch_channel_version "$CHANNEL_BETA" 2>/dev/null) || target=""
            if [[ -z "$target" ]]; then
                echo "Error: The 'beta' channel is not available (unpublished, or could not be resolved)." >&2
                echo "  No beta release has been published yet, or the channel manifest could not be reached." >&2
                return 1
            fi
            echo "  Resolved: $target"
            ;;
        "")
            # No target: update to latest for current channel
            ;;
    esac

    # Delegate to cli_targeted_update for confirmation + install
    if [[ -n "$channel_context" ]]; then
        # Channel switch: perform_update with channel context
        cli_targeted_update "$target"
        # Persist channel on success
        if [[ $? -eq 0 && -n "$channel_context" ]]; then
            set_installed_channel "$channel_context" 2>/dev/null || true
        fi
    else
        cli_targeted_update "$target"
    fi
}

# --- Rollback ---

update_rollback() {
    # TTY check
    if [[ ! -t 0 ]] && [[ ! -t 1 ]]; then
        echo "Rollback requires an interactive terminal."
        return 1
    fi

    if ! type perform_rollback &>/dev/null; then
        echo "Error: Auto-update library not available." >&2
        return 1
    fi

    perform_rollback
}

# --- Dispatcher ---

handle_update_command() {
    local subcommand="${1:-}"
    shift 2>/dev/null || true

    case "$subcommand" in
        # Direct subcommands
        status)
            update_status
            ;;
        list)
            update_list
            ;;
        check)
            update_check
            ;;
        install)
            update_install "$@"
            ;;
        rollback)
            update_rollback
            ;;
        help|--help|-h)
            update_help
            ;;

        # Backward compatibility: --list flag
        --list)
            update_list
            ;;

        # Backward compatibility: version tag (v0.1.0-alpha.50 etc.)
        v[0-9]*)
            update_install "$subcommand"
            ;;

        # Empty = default install (latest for channel)
        "")
            update_install
            ;;

        # Fallback: treat unknown args as install target
        *)
            update_install "$subcommand"
            ;;
    esac
}
