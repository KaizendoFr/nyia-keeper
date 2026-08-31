#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later OR Proprietary
# Copyright (c) 2024 Nyia Keeper Contributors

# Nyia Keeper Public Installer
# Downloads release tarball and runs the real installer inside it

set -euo pipefail

# --- WSL1 guard (Plan 291) ---
# WSL1 lacks Docker socket integration, so Nyia Keeper cannot run there. Reject early,
# BEFORE downloading anything, with an actionable steer to WSL2. Defined positively (a real
# WSL signal + a "microsoft" kernel that is NOT a WSL2 kernel) so a custom-kernel WSL2 or a
# Hyper-V/Azure native-Linux guest is never false-rejected. Mirrors is_wsl1() in
# bin/common/shared.sh (kept inline: this runs before the tarball exists).
_nyia_is_wsl1() {
    [[ -n "${WSL_DISTRO_NAME:-}" || -e /run/WSL || -e /proc/sys/fs/binfmt_misc/WSLInterop ]] || return 1
    local pv; pv="$(cat /proc/version 2>/dev/null)"
    [[ "$pv" == *[Mm]icrosoft* ]] || return 1
    [[ "$pv" == *microsoft-standard* || "$pv" == *WSL2* ]] && return 1
    return 0
}
if _nyia_is_wsl1; then
    echo "❌ WSL1 is not supported (it lacks Docker socket integration)." >&2
    echo "" >&2
    echo "Install WSL2, then re-run this inside your WSL2 terminal:" >&2
    echo "  1. PowerShell (Admin):  wsl --install         (or: wsl --set-version <distro> 2)" >&2
    echo "  2. Docker Desktop -> Settings -> Resources -> WSL Integration -> enable your distro" >&2
    echo "  3. Reopen your WSL2 (Ubuntu) terminal and re-run this installer" >&2
    echo "" >&2
    echo "See: https://github.com/KaizendoFr/nyia-keeper/blob/main/docs/WSL2_SETUP.md" >&2
    exit 1
fi

echo "🚀 Installing Nyia Keeper..."

# Configuration
PUBLIC_REPO="KaizendoFr/nyia-keeper"
CHANNELS_MANIFEST_URL="https://raw.githubusercontent.com/${PUBLIC_REPO}/main/channels.json"

# --- Version / Channel resolution (Plan 192) ---
#
# Precedence order (highest to lowest):
#   1. Positional argument: install.sh v0.1.0-alpha.63    (exact version)
#   2. NYIA_VERSION env var: NYIA_VERSION=v0.1.0-alpha.63 (exact version)
#   3. NYIA_CHANNEL env var: NYIA_CHANNEL=beta            (channel manifest lookup)
#   4. Pipeline placeholder __RELEASE_TAG__ / "latest"    (newest published release)
#
# Valid channel names: latest | alpha | beta. Channel resolution uses the public
# channels.json manifest hosted in the public runtime repository so GitHub
# Releases remain immutable.
#
# FAIL-CLOSED BY ABSENCE (Plan 312a/312c): channels.json has no "beta" key until
# the first beta release is cut. A `beta` channel request with no resolvable beta
# tag is refused (non-zero) with a clear message — it NEVER falls back to the
# stable (latest) channel. alpha/latest keep their existing fallback behavior.

# Detect selected channel (used to write CHANNEL state file after install).
# Default is "beta" when no explicit channel is chosen (Plan 320/321: beta is the default channel).
SELECTED_CHANNEL="beta"
# Track whether the user explicitly chose a channel (Plan 227).
# When false, channel is inferred from the resolved version tag after download.
EXPLICIT_CHANNEL=false

RELEASE_TYPE=""

if [[ -n "${1:-}" ]]; then
    # Positional argument: treat as explicit version tag
    ARG_VAL="$1"
    # If it looks like a channel name (no dots/digits at start), treat as channel
    if [[ "$ARG_VAL" =~ ^(latest|alpha|beta)$ ]]; then
        SELECTED_CHANNEL="$ARG_VAL"
        EXPLICIT_CHANNEL=true
        RELEASE_TYPE="channel:$ARG_VAL"
        echo "📦 Installing channel: $ARG_VAL"
    else
        RELEASE_TYPE="tags/$ARG_VAL"
        SELECTED_CHANNEL=""   # exact pin — inferred later from version
        echo "📦 Installing specific version: $ARG_VAL"
    fi
elif [[ -n "${NYIA_VERSION:-}" ]]; then
    # Explicit version env var wins
    RELEASE_TYPE="tags/$NYIA_VERSION"
    SELECTED_CHANNEL=""   # exact pin — inferred later from version
    echo "📦 Installing specific version: $NYIA_VERSION"
elif [[ -n "${NYIA_CHANNEL:-}" ]]; then
    # Channel env var
    SELECTED_CHANNEL="$NYIA_CHANNEL"
    EXPLICIT_CHANNEL=true
    RELEASE_TYPE="channel:$NYIA_CHANNEL"
    echo "📦 Installing channel: $NYIA_CHANNEL"
else
    # Pipeline replaces __RELEASE_TAG__ with a concrete tag for a RELEASE installer. If UNREPLACED
    # (raw/source install), default to the BETA channel (Plan 320/321). The placeholder in the
    # comparison is split ("__RELEASE""_TAG__") so the replace step can't rewrite it — only the
    # assignment above is a real placeholder; a pinned release installer keeps its tag.
    RELEASE_TYPE="__RELEASE_TAG__"
    if [[ "$RELEASE_TYPE" == "__RELEASE""_TAG__" ]]; then
        RELEASE_TYPE="channel:beta"
        SELECTED_CHANNEL="beta"
    fi
fi

# Resolve the release tag name for download URL
echo "🔍 Finding Nyia Keeper release..."

# Resolve channel aliases through the manifest
if [[ "$RELEASE_TYPE" == channel:* ]]; then
    CHANNEL_NAME="${RELEASE_TYPE#channel:}"
    echo "📡 Resolving channel '$CHANNEL_NAME' via manifest..."
    MANIFEST_JSON=$(curl -fsS "$CHANNELS_MANIFEST_URL" 2>/dev/null) || MANIFEST_JSON=""
    if [[ -n "$MANIFEST_JSON" ]]; then
        TAG_NAME=$(echo "$MANIFEST_JSON" \
            | grep -o "\"${CHANNEL_NAME}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
            | head -1 \
            | sed "s/.*\"${CHANNEL_NAME}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/" \
            2>/dev/null) || TAG_NAME=""
    else
        TAG_NAME=""
    fi
    if [[ -z "$TAG_NAME" ]]; then
        # FAIL-CLOSED BY ABSENCE (Plan 312a/312c): the beta channel is unavailable
        # until a beta release is cut and added to channels.json. A beta request we
        # cannot resolve must NEVER silently install the stable (latest) channel —
        # refuse with a clear message and a non-zero exit instead.
        if [[ "$CHANNEL_NAME" == "beta" ]]; then
            echo "❌ Beta channel is not available yet." >&2
            echo "   No resolvable 'beta' entry is present in the channel manifest," >&2
            echo "   or the manifest could not be fetched (a transient network/GitHub error)." >&2
            echo "   (A beta release must be published before you can install it.)" >&2
            echo "   Manifest URL: $CHANNELS_MANIFEST_URL" >&2
            echo "   Refusing to fall back to the stable channel." >&2
            exit 1
        fi
        echo "❌ Could not resolve channel '$CHANNEL_NAME' from manifest"
        echo "   Manifest URL: $CHANNELS_MANIFEST_URL"
        echo "   Falling back to newest published release..."
        RELEASE_TYPE="tags/v0.1.0-beta.11"
    else
        echo "📦 Channel '$CHANNEL_NAME' resolved to: $TAG_NAME"
    fi
fi

if [[ "$RELEASE_TYPE" == "__RELEASE_TAG__" || "$RELEASE_TYPE" == "latest" ]]; then
    # Resolve latest release (handles pre-releases which /releases/latest ignores)
    echo "📦 Finding latest release..."
    RELEASE_URL="https://api.github.com/repos/$PUBLIC_REPO/releases/latest"
    if RELEASE_JSON=$(curl -fsS "$RELEASE_URL" 2>/dev/null); then
        TAG_NAME=$(echo "$RELEASE_JSON" | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
    else
        # /releases/latest returns 404 when all releases are pre-releases (alpha/beta)
        echo "   No stable release found, checking pre-releases..."
        RELEASES_URL="https://api.github.com/repos/$PUBLIC_REPO/releases"
        if ! RELEASE_JSON=$(curl -fsS "$RELEASES_URL"); then
            echo "❌ Failed to fetch releases from GitHub API"
            echo "   Please check if the repository exists and has releases"
            exit 1
        fi
        TAG_NAME=$(echo "$RELEASE_JSON" | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
        if [[ -z "$TAG_NAME" ]]; then
            echo "❌ No releases found for $PUBLIC_REPO"
            exit 1
        fi
    fi
    echo "📦 Installing version: $TAG_NAME"
elif [[ "$RELEASE_TYPE" == tags/* && -z "${TAG_NAME:-}" ]]; then
    # Specific tag requested (via argument or env var) and not yet set by channel resolution
    TAG_NAME="${RELEASE_TYPE#tags/}"
    RELEASE_URL="https://api.github.com/repos/$PUBLIC_REPO/releases/$RELEASE_TYPE"
    if ! RELEASE_JSON=$(curl -fsS "$RELEASE_URL"); then
        echo "❌ Release $TAG_NAME not found"
        echo "   URL: $RELEASE_URL"
        echo "   Please verify this version exists"
        exit 1
    fi
fi

# --- Channel inference from resolved version (Plan 227) ---
# When no explicit channel was chosen, infer from the version tag pattern.
# Matches CI pipeline logic: *-alpha.* → alpha, *-beta.* → beta, else → latest.
if [[ "$EXPLICIT_CHANNEL" == "false" && -n "${TAG_NAME:-}" ]]; then
    if [[ "$TAG_NAME" == *-alpha.* ]]; then
        SELECTED_CHANNEL="alpha"
        echo "📡 Inferred channel 'alpha' from version: $TAG_NAME"
    elif [[ "$TAG_NAME" == *-beta.* ]]; then
        SELECTED_CHANNEL="beta"
        echo "📡 Inferred channel 'beta' from version: $TAG_NAME"
    elif [[ -z "$SELECTED_CHANNEL" ]]; then
        # Exact-version install of a non-prerelease tag — default to latest
        SELECTED_CHANNEL="latest"
    fi
fi

TARBALL_URL="https://github.com/$PUBLIC_REPO/releases/download/$TAG_NAME/nyiakeeper-runtime.tar.gz"
echo "✅ Using release: $TAG_NAME"

echo "📥 Downloading Nyia Keeper runtime..."
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

TARBALL_FILE="$TEMP_DIR/nyiakeeper-runtime.tar.gz"
if ! curl -fL --retry 3 --retry-delay 1 -o "$TARBALL_FILE" "$TARBALL_URL"; then
    echo "❌ Failed to download release tarball"
    echo "   URL: $TARBALL_URL"
    echo "   Please verify the release exists and contains nyiakeeper-runtime.tar.gz"
    exit 1
fi

tar -xzf "$TARBALL_FILE" -C "$TEMP_DIR"

echo "🔧 Running real installer..."
cd "$TEMP_DIR"

# Execute the real installer inside the package
if [[ -f setup.sh ]]; then
    bash setup.sh
else
    echo "❌ Setup script not found in package"
    exit 1
fi

# Persist the selected channel so auto-update stays on the same channel.
# Skip for exact-version installs (SELECTED_CHANNEL is empty in that case).
if [[ -n "${SELECTED_CHANNEL:-}" ]]; then
    _nyia_config_root="${XDG_CONFIG_HOME:-$HOME/.config}/nyiakeeper"
    mkdir -p "$_nyia_config_root"
    echo "$SELECTED_CHANNEL" > "$_nyia_config_root/CHANNEL"
    echo "📌 Update channel set to: $SELECTED_CHANNEL"
fi

echo "✅ Nyia Keeper installation complete!"
echo ""
echo "Next steps:"
echo "1. Add ~/.local/bin to your PATH if not already done"
echo "2. Run: nyia list"
echo "3. Configure an assistant: nyia-claude --login"

# --- End-of-install Docker check (Plan 323) ---
# The bootstrap installer does NOT source the library, so this is self-contained. It
# mirrors check_docker_available / check_docker_running in bin/common-functions.sh
# (the source of truth) so install-time and command-time wording stay consistent.
# Non-fatal: the user may add Docker afterward. WSL1 is already rejected at the top of
# this script, so only two failure states remain here — CLI missing, or daemon down.
_nyia_check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo ""
        echo "⚠️  Docker is not installed — Nyia Keeper needs it to run."
        echo "   Install Docker:"
        echo "     curl -fsSL https://get.docker.com -o get-docker.sh && sh get-docker.sh"
        echo "     Or visit: https://docs.docker.com/get-docker/"
        echo "   Full setup: https://nyia-keeper.com"
        return 0
    fi
    if ! docker info >/dev/null 2>&1; then
        echo ""
        echo "⚠️  Docker is installed but the daemon is not reachable (not running, or permission denied)."
        echo "   Start Docker:  sudo systemctl start docker    # or: sudo service docker start"
        echo "   If Docker IS running, add your user to the 'docker' group:"
        echo "     sudo usermod -aG docker \$USER    # then log out/in (or: newgrp docker)"
        echo "   Full setup: https://nyia-keeper.com"
        return 0
    fi
    echo ""
    echo "✅ Docker is installed and running."
    return 0
}
_nyia_check_docker

echo ""
echo "Requirements to run:"
echo "  • Git installed; launch inside a Git repo (--skip-checks to bypass)"
echo "  • Full requirements & per-OS setup: https://nyia-keeper.com"
