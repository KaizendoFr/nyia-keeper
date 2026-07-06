#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later OR Proprietary
# Copyright (c) 2024 Nyia Keeper Contributors

# Nyia Keeper Runtime Installer
# Real installer that copies all files and bootstraps the system
# This file is included inside the runtime tarball

set -e

# Installation paths
INSTALL_DIR="${HOME}/.local"
BIN_DIR="${INSTALL_DIR}/bin"
LIB_DIR="${INSTALL_DIR}/lib/nyiakeeper"
# Platform-aware config path (must match entry points in bin/nyia-*)
case "$(uname -s)" in
    Darwin*)
        CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/nyiakeeper/config"
        ;;
    *)
        CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/nyiakeeper/config"
        ;;
esac

echo "🔧 Installing Nyia Keeper runtime distribution..."

# Create all necessary directories
mkdir -p "$BIN_DIR" "$LIB_DIR" "$CONFIG_DIR"

# Copy binaries
if [[ -d bin ]]; then
    cp -r bin/* "$BIN_DIR/"
    chmod +x "$BIN_DIR"/nyia* 2>/dev/null || true
    echo "✅ Installed commands to $BIN_DIR"
else
    echo "❌ Error: bin directory not found"
    exit 1
fi

# Copy libraries
if [[ -d lib ]]; then
    cp -r lib/* "$LIB_DIR/"
    echo "✅ Installed libraries to $LIB_DIR"
else
    echo "❌ Error: lib directory not found"
    exit 1
fi

# Copy system prompts and docker assets (CRITICAL for runtime)
if [[ -d docker ]]; then
    cp -r docker "$INSTALL_DIR/"
    echo "✅ Installed system prompts to $INSTALL_DIR/docker"
else
    echo "⚠️  Warning: docker directory not found, system prompts may not work"
fi

# Copy and initialize configuration files
if [[ -d config ]]; then
    for conf_example in config/*.conf.example; do
        if [[ -f "$conf_example" ]]; then
            basename_conf=$(basename "$conf_example" .example)
            target_conf="$CONFIG_DIR/$basename_conf"
            
            if [[ ! -f "$target_conf" ]]; then
                cp "$conf_example" "$target_conf"
                echo "✅ Created config: $basename_conf"
            else
                echo "ℹ️  Config exists: $basename_conf (skipped)"
            fi
        fi
    done
else
    echo "⚠️  Warning: config directory not found"
fi

# Copy VERSION file for upgrade detection
if [[ -f "VERSION" ]]; then
    # Primary: config dir (canonical location read by get_installed_version)
    _config_root="${XDG_CONFIG_HOME:-$HOME/.config}/nyiakeeper"
    mkdir -p "$_config_root"
    cp "VERSION" "$_config_root/VERSION"
    # Secondary: lib dir (backward compat for existing installs)
    cp "VERSION" "$LIB_DIR/VERSION"
    echo "✅ Installed version: $(cat VERSION)"
fi

# Persist channel selection (Plan 192).
# The public installer (public-install.sh) writes CHANNEL before calling setup.sh.
# If NYIA_CHANNEL is set directly, honour it here too.
# If neither is set, the CHANNEL file is left absent (defaults to "latest").
if [[ -n "${NYIA_CHANNEL:-}" ]]; then
    _config_root="${XDG_CONFIG_HOME:-$HOME/.config}/nyiakeeper"
    mkdir -p "$_config_root"
    echo "$NYIA_CHANNEL" > "$_config_root/CHANNEL"
    echo "✅ Update channel: $NYIA_CHANNEL"
fi

# Seed built-in skills to global raw source (Plan 193)
# These become visible to --list-skills and get propagated to assistants at launch
_nyia_home="${XDG_CONFIG_HOME:-$HOME/.config}/nyiakeeper"
if [[ -d "docker/shared/skills" ]]; then
    mkdir -p "$_nyia_home/skills"
    _seeded=0
    _kept=0
    for _skill_dir in docker/shared/skills/*/; do
        [[ -d "$_skill_dir" ]] || continue
        _skill_name=$(basename "$_skill_dir")
        # Only seed directories containing SKILL.md (symmetry with discovery)
        [[ -f "$_skill_dir/SKILL.md" ]] || continue
        # No-clobber: do not overwrite user-customized skills on upgrade
        if [[ ! -d "$_nyia_home/skills/$_skill_name" ]]; then
            cp -r "$_skill_dir" "$_nyia_home/skills/$_skill_name"
            _seeded=$((_seeded + 1))
        else
            _kept=$((_kept + 1))
        fi
    done
    echo "✅ Skills: $_seeded seeded, $_kept already present → $_nyia_home/skills/"
fi

# Cross-platform sed in-place (BSD sed on macOS requires '' backup arg)
sed_inplace() {
    if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
}

# Fix paths in assistant-template.sh for installed layout
if [[ -f "$BIN_DIR/assistant-template.sh" ]]; then
    # Fix cli-parser.sh path
    sed_inplace 's|source "\$script_dir/\.\./lib/cli-parser\.sh"|source "\$HOME/.local/lib/nyiakeeper/cli-parser.sh"|' "$BIN_DIR/assistant-template.sh"
    # Fix exclusions-commands.sh path
    sed_inplace 's|local exclusions_lib="\$script_dir/\.\./lib/exclusions-commands\.sh"|local exclusions_lib="\$HOME/.local/lib/nyiakeeper/exclusions-commands.sh"|' "$BIN_DIR/assistant-template.sh"
    # Fix mount-exclusions.sh path
    sed_inplace 's|local mount_exclusions_lib="\$script_dir/\.\./lib/mount-exclusions\.sh"|local mount_exclusions_lib="\$HOME/.local/lib/nyiakeeper/mount-exclusions.sh"|' "$BIN_DIR/assistant-template.sh"

    # Also fix paths in main nyia script
    sed_inplace 's|exclusions_lib="\$script_dir_real/\.\./lib/exclusions-commands\.sh"|exclusions_lib="\$HOME/.local/lib/nyiakeeper/exclusions-commands.sh"|' "$BIN_DIR/nyia"
    sed_inplace 's|mount_exclusions_lib="\$script_dir_real/\.\./lib/mount-exclusions\.sh"|mount_exclusions_lib="\$HOME/.local/lib/nyiakeeper/mount-exclusions.sh"|' "$BIN_DIR/nyia"
    # Fix marketplace-commands.sh path (Plan 246a)
    sed_inplace 's|marketplace_lib="\$script_dir_real/\.\./lib/marketplace-commands\.sh"|marketplace_lib="\$HOME/.local/lib/nyiakeeper/marketplace-commands.sh"|' "$BIN_DIR/nyia"
    # Fix config-commands.sh path (Plan 282)
    sed_inplace 's|_cc="\$script_dir/\.\./lib/config-commands\.sh"|_cc="\$HOME/.local/lib/nyiakeeper/config-commands.sh"|' "$BIN_DIR/nyia"
    echo "✅ Updated paths for installed layout"
fi

# Fix shared.sh path in input-validation.sh for installed layout
if [[ -f "$LIB_DIR/input-validation.sh" ]]; then
    sed_inplace 's|source "\$(dirname "\${BASH_SOURCE\[0\]}")/../bin/common/shared\.sh"|source "$HOME/.local/bin/common/shared.sh"|' "$LIB_DIR/input-validation.sh"
    echo "✅ Fixed shared.sh path in input-validation.sh"
fi

# Check and update PATH
if ! echo "$PATH" | grep -q "$BIN_DIR"; then
    echo ""
    echo "📝 Add this to your shell profile (.bashrc, .zshrc, etc.):"
    echo "   export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

echo ""
echo "✅ Installation complete!"
echo ""
echo "Installation summary:"
echo "  Commands: $BIN_DIR"
echo "  Libraries: $LIB_DIR"
echo "  System prompts: $INSTALL_DIR/docker"
echo "  Configuration: $CONFIG_DIR"
echo "  Skills: $_nyia_home/skills"
echo ""
echo "To enable shell auto-completion:"
echo "  Bash: echo 'eval \"\$(nyia completions bash)\"' >> ~/.bashrc"
echo "  Zsh:  echo 'eval \"\$(nyia completions zsh)\"' >> ~/.zshrc"