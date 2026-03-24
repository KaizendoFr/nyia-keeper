#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later OR Proprietary
# Copyright (c) 2024 Nyia Keeper Contributors

# Nyia Keeper Public Installer
# Downloads release tarball and runs the real installer inside it

set -euo pipefail

echo "🚀 Installing Nyia Keeper..."

# Configuration
PUBLIC_REPO="KaizendoFr/nyia-keeper"
CHANNELS_MANIFEST_URL="https://raw.githubusercontent.com/${PUBLIC_REPO}/main/channels.json"

# --- Version / Channel resolution (Plan 192) ---
#
# Precedence order (highest to lowest):
#   1. Positional argument: install.sh v0.1.0-alpha.63    (exact version)
#   2. NYIA_VERSION env var: NYIA_VERSION=v0.1.0-alpha.63 (exact version)
#   3. NYIA_CHANNEL env var: NYIA_CHANNEL=alpha            (channel manifest lookup)
#   4. Pipeline placeholder __RELEASE_TAG__ / "latest"    (newest published release)
#
# Channel resolution uses the public channels.json manifest hosted in the
# public runtime repository so GitHub Releases remain immutable.

# Detect selected channel (used to write CHANNEL state file after install).
# Default is "latest" when no explicit channel is chosen.
SELECTED_CHANNEL="latest"

RELEASE_TYPE=""

if [[ -n "${1:-}" ]]; then
    # Positional argument: treat as explicit version tag
    ARG_VAL="$1"
    # If it looks like a channel name (no dots/digits at start), treat as channel
    if [[ "$ARG_VAL" =~ ^(latest|alpha)$ ]]; then
        SELECTED_CHANNEL="$ARG_VAL"
        RELEASE_TYPE="channel:$ARG_VAL"
        echo "📦 Installing channel: $ARG_VAL"
    else
        RELEASE_TYPE="tags/$ARG_VAL"
        SELECTED_CHANNEL=""   # exact pin — no channel tracking
        echo "📦 Installing specific version: $ARG_VAL"
    fi
elif [[ -n "${NYIA_VERSION:-}" ]]; then
    # Explicit version env var wins
    RELEASE_TYPE="tags/$NYIA_VERSION"
    SELECTED_CHANNEL=""   # exact pin — no channel tracking
    echo "📦 Installing specific version: $NYIA_VERSION"
elif [[ -n "${NYIA_CHANNEL:-}" ]]; then
    # Channel env var
    SELECTED_CHANNEL="$NYIA_CHANNEL"
    RELEASE_TYPE="channel:$NYIA_CHANNEL"
    echo "📦 Installing channel: $NYIA_CHANNEL"
else
    # Pipeline replaces __RELEASE_TAG__ with a specific tag (e.g., tags/v0.1.0-alpha.41)
    # or "latest" for non-tag builds. If unreplaced, fall through to latest resolution.
    RELEASE_TYPE="__RELEASE_TAG__"
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
        echo "❌ Could not resolve channel '$CHANNEL_NAME' from manifest"
        echo "   Manifest URL: $CHANNELS_MANIFEST_URL"
        echo "   Falling back to newest published release..."
        RELEASE_TYPE="tags/v0.1.0-alpha.77"
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
