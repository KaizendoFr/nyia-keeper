#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later OR Proprietary
# Copyright (c) 2024 Nyia Keeper Contributors

# Nyia Keeper macOS Installer
# Usage: curl -fsSL https://raw.githubusercontent.com/KaizendoFr/nyia-keeper/main/scripts/install-macos.sh | bash
# Future: curl -fsSL https://get.nyiakeeper.io/mac | bash

set -euo pipefail

# Colors (ASCII-safe, works in all terminals)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# Config - aligned with existing release artifacts
INSTALL_DIR="$HOME/.local/lib/nyiakeeper"
BIN_DIR="$HOME/.local/bin"
PUBLIC_REPO="KaizendoFr/nyia-keeper"
TARBALL_NAME="nyiakeeper-runtime.tar.gz"
MIN_MACOS_VERSION="13"
# Replaced at build time by preprocess-runtime.sh (same pattern as install.sh)
RELEASE_TAG="v0.1.0-alpha.89"

# Version resolution: $1 > $NYIA_VERSION > build-time RELEASE_TAG > "latest"
if [[ -n "${1:-}" ]]; then
    RELEASE_TAG="$1"
    shift
elif [[ -n "${NYIA_VERSION:-}" ]]; then
    RELEASE_TAG="$NYIA_VERSION"
fi

#─────────────────────────────────────────────────────────────
# Utility functions
#─────────────────────────────────────────────────────────────

print_header() {
    echo ""
    echo -e "${CYAN}╭──────────────────────────────────────────────────────────╮${NC}"
    echo -e "${CYAN}│                                                          │${NC}"
    echo -e "${CYAN}│${NC}   ${BOLD}Nyia Keeper Installer for macOS${NC}                       ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}   AI-powered coding assistants                           ${CYAN}│${NC}"
    echo -e "${CYAN}│                                                          │${NC}"
    echo -e "${CYAN}╰──────────────────────────────────────────────────────────╯${NC}"
    echo ""
}

print_box() {
    local message="$1"
    echo ""
    echo -e "${CYAN}╭──────────────────────────────────────────────────────────╮${NC}"
    echo -e "$message"
    echo -e "${CYAN}╰──────────────────────────────────────────────────────────╯${NC}"
    echo ""
}

print_success() { echo -e "  ${GREEN}✓${NC} $1"; }
print_error() { echo -e "  ${RED}✗${NC} $1"; }
print_warning() { echo -e "  ${YELLOW}!${NC} $1"; }
print_info() { echo -e "  ${BLUE}→${NC} $1"; }

fail() {
    echo ""
    echo -e "${RED}Error: $1${NC}"
    echo ""
    exit 1
}

#─────────────────────────────────────────────────────────────
# System checks
#─────────────────────────────────────────────────────────────

check_macos() {
    [[ "$(uname)" == "Darwin" ]] || fail "This installer is for macOS only"
}

check_macos_version() {
    local version
    version=$(sw_vers -productVersion)
    local major
    major=$(echo "$version" | cut -d. -f1)

    if [[ "$major" -lt "$MIN_MACOS_VERSION" ]]; then
        fail "macOS $MIN_MACOS_VERSION or newer required (you have $version)"
    fi

    # Get marketing name
    case "$major" in
        15) echo "macOS Sequoia $version" ;;
        14) echo "macOS Sonoma $version" ;;
        13) echo "macOS Ventura $version" ;;
        12) echo "macOS Monterey $version" ;;
        *) echo "macOS $version" ;;
    esac
}

check_architecture() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        arm64) echo "Apple Silicon (native support)" ;;
        x86_64) echo "Intel Mac (supported)" ;;
        *) fail "Unknown architecture: $arch" ;;
    esac
}

check_ram() {
    local ram_bytes
    ram_bytes=$(sysctl -n hw.memsize)
    local ram_gb=$((ram_bytes / 1024 / 1024 / 1024))
    echo "${ram_gb}GB RAM available"
}

#─────────────────────────────────────────────────────────────
# Bash version check
#─────────────────────────────────────────────────────────────

check_bash() {
    # macOS ships bash 3.2 (GPLv2). Nyia Keeper requires bash 4+.
    # Check if a modern bash is available via Homebrew.
    local brew_bash=""
    if [[ -x /opt/homebrew/bin/bash ]]; then
        brew_bash="/opt/homebrew/bin/bash"
    elif [[ -x /usr/local/bin/bash ]]; then
        brew_bash="/usr/local/bin/bash"
    fi

    if [[ -n "$brew_bash" ]]; then
        local version
        version=$("$brew_bash" --version | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
        local major=${version%%.*}
        if [[ "$major" -ge 4 ]]; then
            print_success "Bash $version available at $brew_bash"
            return 0
        fi
    fi

    # Stock /bin/bash is 3.2
    return 1
}

install_modern_bash() {
    if check_homebrew; then
        print_info "Installing modern Bash via Homebrew..."
        local brew_cmd
        brew_cmd=$(get_brew_path)
        if "$brew_cmd" install bash; then
            print_success "Bash 5.x installed"
            return 0
        fi
    fi
    print_error "Could not install modern Bash"
    print_info "Please run: brew install bash"
    return 1
}

#─────────────────────────────────────────────────────────────
# Docker handling
#─────────────────────────────────────────────────────────────

check_docker() {
    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        return 0  # Running
    elif command -v docker &>/dev/null; then
        return 1  # Installed but not running
    else
        return 2  # Not installed
    fi
}

check_homebrew() {
    # Check PATH first
    if command -v brew &>/dev/null; then
        return 0
    fi
    # Apple Silicon location (not always on PATH in non-login shells)
    if [[ -x /opt/homebrew/bin/brew ]]; then
        return 0
    fi
    # Intel Mac location
    if [[ -x /usr/local/bin/brew ]]; then
        return 0
    fi
    return 1
}

get_brew_path() {
    # Return the actual brew path for use in commands
    if command -v brew &>/dev/null; then
        command -v brew
    elif [[ -x /opt/homebrew/bin/brew ]]; then
        echo "/opt/homebrew/bin/brew"
    elif [[ -x /usr/local/bin/brew ]]; then
        echo "/usr/local/bin/brew"
    fi
}

install_docker_homebrew() {
    echo ""
    print_info "Installing Docker Desktop via Homebrew..."
    print_info "This may ask for your password."
    echo ""

    local brew_cmd
    brew_cmd=$(get_brew_path)
    if "$brew_cmd" install --cask docker; then
        print_success "Docker Desktop installed"
        return 0
    else
        print_error "Homebrew installation failed"
        return 1
    fi
}

open_docker_download() {
    local url="https://www.docker.com/products/docker-desktop/"
    print_info "Opening Docker Desktop download page..."
    # Check if we have a display (not SSH without X forwarding)
    if [[ -z "${SSH_CONNECTION:-}" ]] || [[ -n "${DISPLAY:-}" ]]; then
        open "$url" 2>/dev/null || print_info "Please open: $url"
    else
        print_info "Please open in your browser: $url"
    fi
}

prompt_docker_install() {
    print_box "${CYAN}│${NC}                                                          ${CYAN}│${NC}
${CYAN}│${NC}   ${BOLD}Docker Desktop Required${NC}                                ${CYAN}│${NC}
${CYAN}│${NC}                                                          ${CYAN}│${NC}
${CYAN}│${NC}   Nyia Keeper runs AI assistants in Docker containers.  ${CYAN}│${NC}
${CYAN}│${NC}   Docker Desktop is free for personal use.               ${CYAN}│${NC}
${CYAN}│${NC}                                                          ${CYAN}│${NC}
${CYAN}│${NC}   How would you like to install Docker?                  ${CYAN}│${NC}
${CYAN}│${NC}                                                          ${CYAN}│${NC}
${CYAN}│${NC}   [1] Homebrew (recommended if you have it)              ${CYAN}│${NC}
${CYAN}│${NC}   [2] Download from docker.com (opens browser)           ${CYAN}│${NC}
${CYAN}│${NC}   [3] Skip (I'll install Docker myself)                  ${CYAN}│${NC}"

    echo -n "Your choice [1/2/3]: "
    read -r choice < /dev/tty

    case "$choice" in
        1)
            if check_homebrew; then
                install_docker_homebrew
            else
                print_warning "Homebrew not found"
                print_info "Install Homebrew first: https://brew.sh"
                print_info "Or choose option 2 to download Docker directly"
                echo ""
                echo -n "Press ENTER to choose again or Ctrl+C to exit: "
                read -r < /dev/tty
                prompt_docker_install
            fi
            ;;
        2)
            open_docker_download
            ;;
        3)
            print_warning "Please install Docker Desktop and run this installer again"
            exit 0
            ;;
        *)
            print_error "Invalid choice"
            prompt_docker_install
            ;;
    esac
}

wait_for_docker() {
    print_box "${CYAN}│${NC}                                                          ${CYAN}│${NC}
${CYAN}│${NC}   ${BOLD}Please complete these steps:${NC}                             ${CYAN}│${NC}
${CYAN}│${NC}                                                          ${CYAN}│${NC}
${CYAN}│${NC}   1. Download Docker Desktop from the page that opened   ${CYAN}│${NC}
${CYAN}│${NC}   2. Open the downloaded .dmg file                       ${CYAN}│${NC}
${CYAN}│${NC}   3. Drag Docker to Applications                         ${CYAN}│${NC}
${CYAN}│${NC}   4. Open Docker from Applications (first time setup)    ${CYAN}│${NC}
${CYAN}│${NC}   5. Wait for Docker to fully start                      ${CYAN}│${NC}
${CYAN}│${NC}      (whale icon in menu bar stops animating)            ${CYAN}│${NC}
${CYAN}│${NC}                                                          ${CYAN}│${NC}
${CYAN}│${NC}   Press ENTER when Docker is running...                  ${CYAN}│${NC}"

    read -r < /dev/tty

    echo -n "Checking Docker... "
    local attempts=0
    local max_attempts=24  # 2 minutes

    while ! docker info &>/dev/null 2>&1; do
        attempts=$((attempts + 1))
        if [[ $attempts -ge $max_attempts ]]; then
            echo ""
            print_error "Docker not responding"
            print_info "Make sure Docker Desktop is fully started"
            echo -n "Try again? [y/N]: "
            read -r retry < /dev/tty
            if [[ "$retry" =~ ^[Yy] ]]; then
                attempts=0
            else
                fail "Docker is required to continue"
            fi
        fi
        sleep 5
        echo -n "."
    done

    echo ""
    print_success "Docker is running!"
}

prompt_start_docker() {
    print_box "${CYAN}│${NC}                                                          ${CYAN}│${NC}
${CYAN}│${NC}   Docker Desktop is installed but not running.          ${CYAN}│${NC}
${CYAN}│${NC}                                                          ${CYAN}│${NC}
${CYAN}│${NC}   Please open Docker Desktop from your Applications      ${CYAN}│${NC}
${CYAN}│${NC}   folder and wait for it to start.                       ${CYAN}│${NC}
${CYAN}│${NC}                                                          ${CYAN}│${NC}
${CYAN}│${NC}   Press ENTER when Docker is running...                  ${CYAN}│${NC}"

    read -r < /dev/tty
    wait_for_docker
}

#─────────────────────────────────────────────────────────────
# Installation
#─────────────────────────────────────────────────────────────

check_existing_install() {
    if [[ -d "$INSTALL_DIR" ]]; then
        if [[ -f "$INSTALL_DIR/VERSION" ]]; then
            local current_version
            current_version=$(cat "$INSTALL_DIR/VERSION")
            print_warning "Nyia Keeper $current_version already installed"
            local target_label="latest"
            if [[ "$RELEASE_TAG" != "latest" ]]; then
                target_label="$RELEASE_TAG"
            fi
            echo -n "Install $target_label? [Y/n]: "
            read -r response < /dev/tty
            if [[ "$response" =~ ^[Nn] ]]; then
                print_info "Installation cancelled"
                exit 0
            fi
            print_info "Upgrading..."
        else
            print_warning "Nyia Keeper installation found (unknown version)"
            echo -n "Reinstall? [Y/n]: "
            read -r response < /dev/tty
            if [[ "$response" =~ ^[Nn] ]]; then
                print_info "Installation cancelled"
                exit 0
            fi
        fi
    fi
}

install_nyiakeeper() {
    echo ""
    print_info "Installing Nyia Keeper..."

    # Validate specific version against GitHub API
    if [[ "$RELEASE_TAG" != "latest" ]]; then
        print_info "Validating version $RELEASE_TAG..."
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" \
            "https://api.github.com/repos/$PUBLIC_REPO/releases/tags/$RELEASE_TAG" 2>/dev/null) || http_code="000"
        if [[ "$http_code" != "200" ]]; then
            fail "Version $RELEASE_TAG not found. Check available releases at: https://github.com/$PUBLIC_REPO/releases"
        fi
    fi

    # Build download URL — RELEASE_TAG is patched at build time by preprocess-runtime.sh
    local tarball_url
    if [[ "$RELEASE_TAG" == "latest" ]]; then
        tarball_url="https://github.com/$PUBLIC_REPO/releases/latest/download/$TARBALL_NAME"
    else
        tarball_url="https://github.com/$PUBLIC_REPO/releases/download/$RELEASE_TAG/$TARBALL_NAME"
    fi

    print_info "Downloading from: $tarball_url"

    # Create temp directory for extraction (not local — EXIT trap needs it after function returns)
    temp_dir=$(mktemp -d)

    # Cleanup on exit
    cleanup() {
        rm -rf "$temp_dir"
    }
    trap cleanup EXIT

    # Download and extract
    if ! curl -fsSL "$tarball_url" | tar -xz -C "$temp_dir"; then
        fail "Failed to download Nyia Keeper"
    fi

    print_success "Downloaded runtime package"

    # Run the existing setup.sh from inside the tarball (wraps existing flow)
    if [[ -f "$temp_dir/setup.sh" ]]; then
        print_info "Running installer..."
        cd "$temp_dir"
        bash setup.sh
    else
        fail "Setup script not found in package"
    fi

    # Note: setup.sh handles symlink creation, no need to duplicate
    print_success "Installation complete"
}

get_login_shell() {
    # Use dscl to get the user's actual login shell (not $SHELL which may differ)
    # This is critical when running via curl | bash where SHELL may be /bin/bash
    local login_shell
    login_shell=$(dscl . -read "/Users/$USER" UserShell 2>/dev/null | awk '{print $2}')
    if [[ -z "$login_shell" ]]; then
        # Fallback to $SHELL if dscl fails
        login_shell="$SHELL"
    fi
    echo "$login_shell"
}

configure_path() {
    local shell_config
    local shell_name
    local login_shell
    login_shell=$(get_login_shell)

    # Detect config file based on ACTUAL login shell (not $SHELL)
    case "$login_shell" in
        */zsh)
            # For zsh, prefer .zshrc (interactive) over .zprofile (login)
            shell_config="$HOME/.zshrc"
            shell_name="zsh"
            ;;
        */bash)
            # For bash on macOS, use .bash_profile (login shell config)
            shell_config="$HOME/.bash_profile"
            shell_name="bash"
            ;;
        *)
            shell_config="$HOME/.profile"
            shell_name="shell"
            ;;
    esac

    # Homebrew PATH not needed here — installed scripts auto-detect Homebrew Bash
    # via re-exec shim in common-functions.sh (Plan 142)
    local path_line='export PATH="$HOME/.local/bin:$PATH"'
    local marker="# Nyia Keeper PATH"

    # Check if already configured (idempotent - don't duplicate)
    if grep -q "\.local/bin" "$shell_config" 2>/dev/null; then
        print_success "PATH already configured in $shell_config"
        return 0
    fi

    # Backup existing file
    [[ -f "$shell_config" ]] && cp "$shell_config" "${shell_config}.bak"

    # Append PATH configuration
    echo "" >> "$shell_config"
    echo "$marker" >> "$shell_config"
    echo "$path_line" >> "$shell_config"

    print_success "Updated PATH in $shell_config (detected $shell_name login shell)"
}

print_success_message() {
    print_box "${CYAN}│${NC}                                                          ${CYAN}│${NC}
${CYAN}│${NC}   ${GREEN}${BOLD}Installation complete!${NC} 🎉                              ${CYAN}│${NC}
${CYAN}│${NC}                                                          ${CYAN}│${NC}
${CYAN}│${NC}   ${BOLD}To start using Nyia Keeper:${NC}                           ${CYAN}│${NC}
${CYAN}│${NC}                                                          ${CYAN}│${NC}
${CYAN}│${NC}   1. Close this Terminal window                          ${CYAN}│${NC}
${CYAN}│${NC}   2. Open a new Terminal window                          ${CYAN}│${NC}
${CYAN}│${NC}   3. Try: ${CYAN}nyia list${NC}                                      ${CYAN}│${NC}
${CYAN}│${NC}                                                          ${CYAN}│${NC}
${CYAN}│${NC}   ${BOLD}First time setup for Claude:${NC}                           ${CYAN}│${NC}
${CYAN}│${NC}      ${CYAN}nyia-claude --login${NC}                                 ${CYAN}│${NC}
${CYAN}│${NC}                                                          ${CYAN}│${NC}"
}

#─────────────────────────────────────────────────────────────
# Main
#─────────────────────────────────────────────────────────────

main() {
    print_header

    echo "Checking your system..."
    echo ""

    check_macos
    print_success "$(check_macos_version) detected"
    print_success "$(check_architecture)"
    print_success "$(check_ram)"

    echo ""
    echo "Checking for Docker..."
    echo ""

    # Capture exit code without triggering set -e
    local docker_status=0
    check_docker || docker_status=$?

    case $docker_status in
        0)
            print_success "Docker is running"
            ;;
        1)
            print_warning "Docker installed but not running"
            prompt_start_docker
            ;;
        2)
            print_error "Docker Desktop not found"
            prompt_docker_install
            wait_for_docker
            ;;
    esac

    echo ""
    echo "Checking for modern Bash..."
    echo ""

    if ! check_bash; then
        print_warning "Nyia Keeper requires Bash 4.0+ (macOS ships 3.2)"
        if check_homebrew; then
            echo -n "Install modern Bash via Homebrew? [Y/n]: "
            read -r response < /dev/tty
            if [[ ! "$response" =~ ^[Nn] ]]; then
                install_modern_bash || fail "Failed to install modern Bash"
            else
                print_warning "Nyia Keeper will not work without Bash 4+"
                print_info "Install later with: brew install bash"
            fi
        else
            print_error "Homebrew not found. Modern Bash is required."
            print_info "Install Homebrew first: https://brew.sh"
            print_info "Then run: brew install bash"
            fail "Bash 4+ is required for Nyia Keeper"
        fi
    fi

    echo ""
    echo "Checking for existing Nyia Keeper installation..."
    echo ""

    check_existing_install
    install_nyiakeeper
    configure_path
    print_success_message
}

main "$@"
