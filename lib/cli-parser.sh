#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later OR Proprietary
# Copyright (c) 2024 Nyia Keeper Contributors

# Nyia Keeper Centralized CLI Parser
# Single source of truth for all CLI argument parsing and help system

set -e

# macOS ships Bash 3.2 — auto-detect and re-exec under Homebrew Bash 5.x if needed
# This shim MUST fire before any Bash 4+ code is sourced (input-validation.sh → shared.sh)
if [ "${BASH_VERSINFO[0]}" -lt 4 ] && [ -z "${_NYIA_BASH_REEXEC:-}" ]; then
    for _brew_bash in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        if [ -x "$_brew_bash" ]; then
            export _NYIA_BASH_REEXEC=1
            exec "$_brew_bash" "$0" "$@"
        fi
    done
    echo "Error: Bash 4.0+ required. Current version: ${BASH_VERSION}" >&2
    echo "Install modern Bash with: brew install bash" >&2
    exit 1
fi
unset _NYIA_BASH_REEXEC

# Standard bash 4.0+ features used throughout

# Load input validation functions for security
cli_parser_dir="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
if [[ -f "$cli_parser_dir/input-validation.sh" ]]; then
    source "$cli_parser_dir/input-validation.sh"
fi

# === GLOBAL VARIABLES ===
# These are set by parse_args() and used by calling scripts

# Mode flags
export SHOW_HELP="false"
export SHOW_STATUS="false"
export SHOW_VERSION="false"
export NO_CACHE="false"
export VERBOSE="false"
export LOGIN_ONLY="false"
export CHECK_REQUIREMENTS="false"  # Moved outside DEV_BUILD - needed in runtime
export SKIP_CHECKS="false"
export SHELL_MODE="false"
export SET_API_KEY="false"
export SETUP_MODE="false"
export LIST_IMAGES="false"
export DOCKER_IMAGE=""
export FLAVOR=""
export LIST_FLAVORS="false"

# Agent persona selection (Plan 149)
export NYIA_AGENT=""
export LIST_AGENTS="false"

# Skill listing (Plan 177)
export LIST_SKILLS="false"

# Workspace init (Plan 199)
export WORKSPACE_INIT="false"

# Command approval mode (Plan 145)
export NYIA_COMMAND_MODE_CLI=""

# Mount exclusions flags (simplified)
export DISABLE_EXCLUSIONS="false"

# === FLAVOR VALIDATION ===
# Validates flavor against lib/flavors.list

validate_flavor() {
    local flavor="$1"
    local script_dir="${SCRIPT_DIR:-$(dirname "${BASH_SOURCE[0]}")}"
    local flavors_file="$script_dir/flavors.list"

    # Empty flavor is invalid
    if [[ -z "$flavor" ]]; then
        echo "Error: Flavor name cannot be empty" >&2
        return 1
    fi

    # If file doesn't exist, allow any flavor (dev mode fallback)
    if [[ ! -f "$flavors_file" ]]; then
        return 0
    fi

    # Check if flavor exists in list (exact match at start of line)
    if grep -q "^${flavor}|" "$flavors_file"; then
        return 0
    fi

    # Flavor not found - show helpful error
    echo "Error: Unknown flavor '$flavor'" >&2
    echo "" >&2
    echo "Available flavors:" >&2
    while IFS='|' read -r name desc; do
        [[ -z "$name" ]] && continue
        printf "  %-12s - %s\n" "$name" "$desc" >&2
    done < "$flavors_file"
    echo "" >&2
    echo "For custom images, use --image instead of --flavor" >&2
    return 1
}

# Configuration
export PROJECT_PATH=""
export BASE_BRANCH=""
export WORK_BRANCH=""
export CREATE_BRANCH="false"
export BUILD_CUSTOM_IMAGE=""

# RAG control flags (Plan 66 - Opt-in, Plan 88 - Config-based model)
export ENABLE_RAG="false"
# NYIA_RAG_MODEL comes from config file, not hardcoded here

# Command and arguments
export COMMAND=""
export ASSISTANT_NAME=""
export USER_PROMPT=""
export REMAINING_ARGS=()

# Context
export SCRIPT_TYPE=""  # "dispatcher" or "assistant"

# === ARGUMENT DEFINITIONS ===
# Using functions for bash 3.2 compatibility (instead of associative arrays)

# Get description for global arguments
get_global_arg_desc() {
    case "$1" in
        "--help,-h") echo "Show help information" ;;
        "--verbose,-v") echo "Enable verbose output" ;;
        "--version") echo "Show installed version and exit" ;;
        "--path") echo "Work on different project directory" ;;
        *) echo "" ;;
    esac
}

# Get all global arguments
get_global_args() {
    echo "--help,-h --verbose,-v --version --path"
}

# Get description for assistant arguments
get_assistant_arg_desc() {
    case "$1" in
        "--image") echo "Select specific Docker image (tag or repo:tag)" ;;
        "--flavor") echo "Select assistant flavor/variant (e.g., node, python, rust)" ;;
        "--list-flavors") echo "List available flavors for this assistant" ;;
        "--no-cache") echo "Force Docker rebuild without cache (use with --build or --build-custom-image)" ;;
        "--status") echo "Show assistant status, configs, and available overlays" ;;
        "--list-images") echo "List all available Docker images for this assistant" ;;
        "--base-branch") echo "Specify Git base branch to work from" ;;
        "--work-branch") echo "Reuse existing work branch for your work" ;;
        "--create") echo "Create work branch if it doesn't exist (use with --work-branch)" ;;
        "--build-custom-image") echo "Build custom Docker image with your overlays (power users)" ;;
        "--setup") echo "Interactive model/provider setup (OpenCode)" ;;
        "--login") echo "Authenticate using the assistant container" ;;
        "--force") echo "Force operation (bypass authentication checks with --login)" ;;
        "--check-requirements") echo "Check system requirements (Git, Docker, permissions)" ;;
        "--skip-checks") echo "Skip automatic requirements checking" ;;
        "--shell") echo "Start interactive bash shell in container" ;;
        "--set-api-key") echo "Helper to set OpenAI API key for team plan users" ;;
        "--disable-exclusions") echo "Disable mount exclusions for this session" ;;
        "--prompt,-p") echo "Explicit user prompt (deprecated flag, use interactive mode)" ;;
        "--agent") echo "Select agent persona for this session (e.g., reviewer, planner)" ;;
        "--list-agents") echo "List available agent personas for this assistant" ;;
        "--list-skills") echo "List available skills for this assistant" ;;
        "--workspace-init") echo "Create workspace.conf template for multi-repository mode" ;;
        "--command-mode") echo "Set command approval mode for this session (safe or full)" ;;
        "--rag") echo "Enable RAG codebase search (requires Ollama + NYIA_RAG_MODEL in config)" ;;
        "--rag-verbose") echo "Enable verbose debug logging for RAG indexing" ;;
        *) echo "" ;;
    esac
}

# Get all assistant arguments (for iteration)
get_assistant_args() {
    echo "--image --flavor --list-flavors --no-cache --status --list-images --base-branch --work-branch,-w --create --build-custom-image --setup --login --check-requirements --skip-checks --shell --set-api-key --disable-exclusions --agent --list-agents --list-skills --workspace-init --rag --rag-verbose"
}

# Get description for dispatcher arguments
get_dispatcher_arg_desc() {
    case "$1" in
        "config") echo "Configuration management (list, dump, view, get)" ;;
        "list") echo "List all available assistants" ;;
        "status") echo "Show global Nyia Keeper status" ;;
        "exclusions") echo "Manage mount exclusions for security" ;;
        "update") echo "Update management (status, list, check, install)" ;;
        "rollback") echo "Rollback to previous version" ;;
        "completions") echo "Generate shell auto-completion scripts (bash, zsh)" ;;
        "logo") echo "Display Nyia Keeper ASCII art" ;;
        *) echo "" ;;
    esac
}

# Get all dispatcher arguments (for iteration)
get_dispatcher_args() {
    echo "config list status exclusions update rollback completions logo"
}

# === HELP SYSTEM ===
show_dispatcher_help() {
    local script_name="$1"
    
    cat << EOF
Nyia Keeper Multi-Assistant Infrastructure =^•ᆺ•^= ~nya!

Usage:
  $script_name <command>                    # System management commands

System Commands:
EOF
    
    for arg in $(get_dispatcher_args); do
        desc=$(get_dispatcher_arg_desc "$arg")
        printf "  %-20s # %s\n" "$arg" "$desc"
    done
    
    cat << EOF

Assistant Access (use direct commands):
  nyia-claude                                    # Start Claude session
  nyia-gemini                                   # Start Gemini session
  nyia-opencode                                 # Start OpenCode session

Global Options:
EOF
    
    for arg in $(get_global_args); do
        desc=$(get_global_arg_desc "$arg")
        printf "  %-20s # %s\n" "$arg" "$desc"
    done
    
    cat << EOF

Examples:
  $script_name list                             # List available assistants
  $script_name status                           # Show system status
  $script_name clean                            # Clean old images
  
  nyia-claude                                    # Start Claude session
  nyia-gemini --build --dev                    # Build Gemini dev image

For assistant-specific help: nyia-<assistant> --help
EOF
}

# Helper function for prompt customization help section
show_prompt_customization_help() {
    local assistant_name="$1"

    cat << EOF

Prompt Customization:
  Customize assistant behavior and communication style

  Setup:
    # Directory auto-created on first run
    # Examples: ~/.config/nyiakeeper/prompts/*.example

  Quick activation:
    # Global customizations (all assistants)
    cp ~/.config/nyiakeeper/prompts/base-overrides.md.example \\
       ~/.config/nyiakeeper/prompts/base-overrides.md

    # ${assistant_name}-specific customizations
    cp ~/.config/nyiakeeper/prompts/${assistant_name}-overrides.md.example \\
       ~/.config/nyiakeeper/prompts/${assistant_name}-overrides.md

    # Edit and test
    nano ~/.config/nyiakeeper/prompts/${assistant_name}-overrides.md
    nyia-${assistant_name} --verbose

  Customization levels:
    Global: ~/.config/nyiakeeper/prompts/base-overrides.md
    ${assistant_name}: ~/.config/nyiakeeper/prompts/${assistant_name}-overrides.md
    Project: .nyiakeeper/prompts/{project,${assistant_name}}-overrides.md

  Documentation: ~/.config/nyiakeeper/prompts/README.md
EOF
}

show_assistant_help() {
    local assistant_name="$1"
    local thematic_alias="${2:-assistant}"
    
    # Source shared functions for development mode detection
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "$script_dir/../bin/common/shared.sh" ]]; then
        source "$script_dir/../bin/common/shared.sh"
    fi
    
    # Get available overlay templates
    local overlay_templates=""
    if [[ -d "docker/overlay-templates" ]]; then
        overlay_templates=$(ls -1 docker/overlay-templates/ 2>/dev/null | grep -v "README.md" | head -6)
    fi
    
    cat << EOF
Nyia Keeper ${assistant_name} Assistant - "I whisper in code. You commit in fear."

Usage:
  nyia-${assistant_name}                      # Interactive session
  nyia-${assistant_name} [options]            # Various operations

Quick Start:
  nyia-${assistant_name} --status             # Show configuration & overlays
  nyia-${assistant_name}                      # Start interactive session
  nyia-${assistant_name} --build-custom-image  # Build with your overlays
EOF

    if ! declare -f is_development_mode >/dev/null 2>&1; then
    cat << EOF

Power User Overlays:
  Create overlay at: ~/.config/nyiakeeper/${assistant_name}/overlay/Dockerfile
  Then run: nyia-${assistant_name} --build-custom-image

  Example overlay content:
EOF
    fi
    
    # Show available overlay templates with descriptions
    if [[ -n "$overlay_templates" ]]; then
        echo "$overlay_templates" | while read -r template; do
            case "$template" in
                "python-latest") echo "    python-latest/    # Python with pytest, black, ruff, mypy" ;;
                "php-82") echo "    php-82/          # PHP 8.2 with PHPUnit, PHPStan" ;;
                "php-81") echo "    php-81/          # PHP 8.1 environment" ;;
                "php-74") echo "    php-74/          # PHP 7.4 for legacy projects" ;;
                "php-73") echo "    php-73/          # PHP 7.3 for legacy projects" ;;
                "data-science") echo "    data-science/    # Jupyter, pandas, sklearn" ;;
                "web-dev") echo "    web-dev/         # FastAPI, Django, Flask" ;;
                *) echo "    $template/" ;;
            esac
        done
    else
        echo "    (No templates found in docker/overlay-templates/)"
    fi
    
    cat << EOF

  Setup overlay from template:
    cp docker/overlay-templates/python-latest/Dockerfile ~/.config/nyiakeeper/${assistant_name}/overlay/
    nyia-${assistant_name} --build
  
  Overlay locations (applied in order):
    1. User config: ~/.config/nyiakeeper/${assistant_name}/overlay/Dockerfile
    2. Project: ./.nyiakeeper/${assistant_name}/overlay/Dockerfile

Operations:
  --shell                  # Interactive bash in container
  --login                  # Authenticate assistant
  --status                 # Show current config & overlays
Branch Strategy (default: work on current branch):
  -w, --work-branch <name> # Switch to specific work branch
  --create                 # Create work branch if it doesn't exist
  --base-branch <name>     # Specify Git base branch
  Protected branches (main, master + config) trigger an interactive prompt.
  Set NYIA_AUTO_BRANCH=true in config for old timestamped branch behavior.

Agent Personas:
  --agent <name>           # Select agent persona for this session
  --list-agents            # List available agent personas

Skills:
  --list-skills            # List available skills (project, shared, team, global)

Command Approval Mode:
  --command-mode <mode>    # Set mode: safe (default) or full

Workspace Mode (Multi-Repository):
  --workspace-init         # Create workspace.conf template (recommended first step)
  Create .nyiakeeper/workspace.conf with: <path> <ro|rw> (one per line)
  RW repos: full git guards, branch sync; RO repos: read-only, no git needed
  Workspace is auto-detected; repos mounted at /project/{hash}/repos/
  RAG disabled in workspace mode (multi-repo indexing not yet supported)

Flavors:
  --flavor <name>          # Select language flavor (e.g., python, node, rust-tauri)
  --list-flavors           # List available flavors for this assistant

Power User:
  --build-custom-image     # Build custom image with overlays
  --no-cache               # Force rebuild without cache
EOF

    # Add prompt customization help
    show_prompt_customization_help "$assistant_name"

    cat << EOF

Configuration:
  --disable-exclusions     # Disable mount exclusions
  --image <tag>           # Use specific image
  --check-requirements    # Check system requirements
  --setup                 # Interactive setup (OpenCode)
  --set-api-key           # Helper to set API key

RAG (Codebase Search):
  --rag                    # Enable RAG codebase search (requires Ollama + NYIA_RAG_MODEL config)
  --rag-verbose            # Enable verbose debug logging for RAG indexing
EOF


    cat << EOF

Global Options:
  --help, -h              # Show this help
  --verbose, -v           # Verbose output
  --path <dir>           # Work on different project

Examples:
  # Basic usage:
  nyia-${assistant_name}                        # Start interactive session
  nyia-${assistant_name} --status              # Check configuration
EOF

    if ! declare -f is_development_mode >/dev/null 2>&1; then
    echo ""
    echo "  # End-user examples:"
    local registry=$(get_docker_registry)
    cat << EOF
  cat > ~/.config/nyiakeeper/${assistant_name}/overlay/Dockerfile << 'OVERLAY'
FROM ${registry}/nyiakeeper-${assistant_name}:latest
RUN apt-get update && apt-get install -y your-tools
OVERLAY
  nyia-${assistant_name} --build-custom-image  # Build custom image
EOF
    fi

    cat << EOF

Environment:
  Project directory mounted to /workspace in container
  Authentication and settings saved globally
  Git integration automatic in write mode
  Overlay system provides runtime customization
EOF
}

# === ARGUMENT PARSING ===
parse_dispatcher_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help|-h)
                SHOW_HELP="true"
                shift
                ;;
            --version)
                SHOW_VERSION="true"
                return 0
                ;;
            --verbose|-v)
                export VERBOSE="true"
                shift
                ;;
            --path)
                if [[ -n "$2" ]] && validate_file_path "$2"; then
                    PROJECT_PATH="$2"
                    shift 2
                else
                    print_error "Invalid or unsafe path: $2"
                    exit 1
                fi
                ;;
            config|list|status|clean|exclusions|update|rollback|completions|logo|help)
                COMMAND="$1"
                shift
                REMAINING_ARGS=("$@")
                return 0
                ;;
            *)
                # First non-option argument should be the assistant name.
                if [[ -z "$ASSISTANT_NAME" ]]; then
                    if [[ "$1" == -* ]]; then
                        echo "Error: Option '$1' provided before assistant name" >&2
                        echo "Usage: $0 <assistant> [options]" >&2
                        exit 1
                    fi
                    ASSISTANT_NAME="$1"
                    shift
                    REMAINING_ARGS=("$@")
                    return 0
                else
                    echo "Error: Unknown dispatcher command: $1" >&2
                    exit 1
                fi
                ;;
        esac
    done
}

parse_assistant_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help|-h)
                SHOW_HELP="true"
                return 0
                ;;
            --version)
                SHOW_VERSION="true"
                return 0
                ;;
            --verbose|-v)
                export VERBOSE="true"
                shift
                ;;
            --path)
                if [[ -n "$2" ]] && validate_file_path "$2"; then
                    PROJECT_PATH="$2"
                    shift 2
                else
                    print_error "Invalid or unsafe path: $2"
                    exit 1
                fi
                ;;
            --image)
                if [[ -n "$2" ]]; then
                    export DOCKER_IMAGE="$2"
                    shift 2
                else
                    echo "Error: --image requires an argument" >&2
                    echo "Usage: --image <tag|repo:tag>" >&2
                    exit 1
                fi
                ;;
            --flavor)
                if [[ -z "${2:-}" ]]; then
                    echo "Error: --flavor requires an argument" >&2
                    echo "Usage: --flavor <flavor-name>" >&2
                    echo "Run --list-flavors to see available flavors" >&2
                    exit 1
                fi
                if ! validate_flavor "$2"; then
                    exit 1
                fi
                export FLAVOR="$2"
                shift 2
                ;;
            --list-flavors|--flavors-list)
                export LIST_FLAVORS="true"
                shift
                ;;
            --no-cache)
                export NO_CACHE="true"
                shift
                ;;
            --status)
                SHOW_STATUS="true"
                shift
                ;;
            --list-images)
                LIST_IMAGES="true"
                shift
                ;;
            --login)
                LOGIN_ONLY="true"
                # Check if next argument is --force
                if [[ "$2" == "--force" ]]; then
                    export FORCE_LOGIN="true"
                    shift 2
                else
                    shift
                fi
                ;;
            --force)
                # Can be used standalone or will be caught by --login above
                export FORCE_LOGIN="true"
                shift
                ;;
            --check-requirements)
                CHECK_REQUIREMENTS="true"
                shift
                ;;
            --skip-checks)
                SKIP_CHECKS="true"
                shift
                ;;
            --shell)
                SHELL_MODE="true"
                shift
                ;;
            --set-api-key)
                SET_API_KEY="true"
                shift
                ;;
            --setup)
                SETUP_MODE="true"
                shift
                ;;
            --disable-exclusions)
                export DISABLE_EXCLUSIONS="true"
                export ENABLE_MOUNT_EXCLUSIONS="false"
                shift
                ;;
            --base-branch)
                if [[ -n "$2" ]]; then
                    BASE_BRANCH="$2"
                    shift 2
                else
                    echo "Error: --base-branch requires an argument" >&2
                    echo "Usage: --base-branch <branch-name>" >&2
                    exit 1
                fi
                ;;
            --work-branch|-w)
                if [[ -n "$2" ]]; then
                    WORK_BRANCH="$2"
                    shift 2
                else
                    echo "Error: --work-branch requires an argument" >&2
                    echo "Usage: --work-branch <branch-name>" >&2
                    exit 1
                fi
                ;;
            --create)
                CREATE_BRANCH="true"
                shift
                ;;
            --build-custom-image)
                BUILD_CUSTOM_IMAGE="true"
                shift
                ;;
            --prompt|-p)
                if [[ -n "$2" ]]; then
                    USER_PROMPT="$2"
                    shift 2
                else
                    echo "Error: --prompt requires an argument" >&2
                    echo "Usage: --prompt \"Your prompt text\"" >&2
                    exit 1
                fi
                ;;
            --agent)
                if [[ -z "${2:-}" || "$2" == -* ]]; then
                    echo "Error: --agent requires an agent name" >&2
                    echo "Usage: --agent <name>" >&2
                    echo "Run --list-agents to see available agents" >&2
                    exit 1
                fi
                if ! validate_agent_name "$2"; then
                    exit 1
                fi
                export NYIA_AGENT="$2"
                shift 2
                ;;
            --list-agents)
                export LIST_AGENTS="true"
                shift
                ;;
            --list-skills)
                export LIST_SKILLS="true"
                shift
                ;;
            --workspace-init)
                export WORKSPACE_INIT="true"
                shift
                ;;
            --command-mode)
                if [[ -z "${2:-}" || "$2" == -* ]]; then
                    echo "Error: --command-mode requires a value (safe or full)" >&2
                    exit 1
                fi
                case "$2" in
                    safe|full) ;;
                    *)
                        echo "Error: Invalid command mode '$2'. Valid values: safe, full" >&2
                        exit 1
                        ;;
                esac
                export NYIA_COMMAND_MODE_CLI="$2"
                shift 2
                ;;
            --rag)
                export ENABLE_RAG="true"
                shift
                ;;
            *)
                # Strict validation: reject unknown options
                if [[ "$1" == -* ]]; then
                    # Source shared functions for development mode detection
                    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
                    if [[ -f "$script_dir/../bin/common/shared.sh" ]]; then
                        source "$script_dir/../bin/common/shared.sh"
                    fi
                    
                    echo "Error: Unknown option: $1" >&2
                    echo "" >&2
                    echo "Valid options:" >&2
                    echo "  --status             Show assistant status and available images" >&2
                    echo "  --login              Authenticate using the assistant container" >&2
                    echo "  --shell              Interactive shell in container" >&2
                    echo "  --check-requirements Check system requirements" >&2
                    echo "  --path <dir>         Work on different project directory" >&2
                    echo "  --verbose, -v        Enable verbose output" >&2
                    echo "  --command-mode <m>   Set command mode: safe (default) or full" >&2
                    echo "  --help, -h           Show help" >&2
                    
                    echo "" >&2
                    echo "Additional options:" >&2
                    echo "  --build-custom-image Build custom image with overlays" >&2
                    echo "  --no-cache           Force rebuild without cache (use with --build-custom-image)" >&2
                    echo "  --base-branch <name> Specify Git base branch" >&2
                    echo "  -w, --work-branch <name> Switch to specific work branch" >&2
                    echo "  --create             Create work branch if it doesn't exist" >&2
                    echo "" >&2
                    echo "Example: nyia-claude --build-custom-image --no-cache" >&2
                    
                    exit 1
                fi
                
                # Check if --help is in the remaining arguments
                local check_arg
                for check_arg in "$@"; do
                    if [[ "$check_arg" == "--help" || "$check_arg" == "-h" ]]; then
                        SHOW_HELP="true"
                        return
                    fi
                done
                
                # Check for common dispatcher commands used incorrectly
                if [[ "$1" == "exclusions" || "$1" == "config" || "$1" == "list" || "$1" == "status" || "$1" == "clean" ]]; then
                    echo "Error: '$1' is a system command, not an assistant command" >&2
                    echo "" >&2
                    echo "For system commands, use the dispatcher:" >&2
                    echo "  nyia $1                    # Basic usage" >&2
                    echo "  nyia --path /path $1       # With custom path" >&2
                    echo "" >&2
                    echo "For assistant usage:" >&2
                    echo "  nyia-claude                       # Interactive mode" >&2
                    echo "  nyia-gemini                       # Interactive mode" >&2
                    echo "  nyia-opencode --help              # Show assistant help" >&2
                    exit 1
                fi
                
                # Reject direct text arguments - use interactive mode
                echo "Error: Direct text prompts not supported" >&2
                echo "" >&2
                echo "Bad:  nyia-claude 'help me'" >&2
                echo "Good: nyia-claude              # Interactive mode" >&2
                echo "" >&2
                exit 1
                ;;
        esac
    done
}

# === MAIN PARSING FUNCTION ===
parse_args() {
    local script_type="$1"
    shift
    
    SCRIPT_TYPE="$script_type"
    
    # Reset all variables to defaults
    export SHOW_HELP="false"
    export SHOW_STATUS="false"
    export NO_CACHE="false"
    export VERBOSE="false"
    export LOGIN_ONLY="false"
    export SKIP_CHECKS="false"
    export SHELL_MODE="false"
    export SET_API_KEY="false"
    export SETUP_MODE="false"
    export LIST_FLAVORS="false"
    export NYIA_AGENT=""
    export LIST_AGENTS="false"
    export LIST_SKILLS="false"
    export WORKSPACE_INIT="false"
    export DISABLE_EXCLUSIONS="false"
    export PROJECT_PATH=""
    export FLAVOR=""
    export BASE_BRANCH=""
        export COMMAND=""
    export ASSISTANT_NAME=""
    export USER_PROMPT=""
    REMAINING_ARGS=()
    
    case "$script_type" in
        "dispatcher")
            parse_dispatcher_args "$@"
            ;;
        "assistant")
            parse_assistant_args "$@"
            ;;
        *)
            echo "Error: Invalid script type: $script_type" >&2
            exit 1
            ;;
    esac
}

# === VALIDATION ===
validate_args() {
    # Validate and normalize paths if provided
    if [[ -n "$PROJECT_PATH" ]]; then
        # Check if path exists first (before normalization)
        if [[ ! -d "$PROJECT_PATH" ]]; then
            echo "Error: Project path does not exist: $PROJECT_PATH" >&2
            exit 1
        fi
        
        # Convert to absolute path (Docker requirement) - transparent for users
        local original_path="$PROJECT_PATH"
        PROJECT_PATH=$(realpath "$PROJECT_PATH" 2>/dev/null)
        
        if [[ -z "$PROJECT_PATH" ]]; then
            echo "Error: Failed to resolve absolute path for: $original_path" >&2
            exit 1
        fi
        
        # Show conversion for transparency (only if verbose)
        if [[ "$VERBOSE" == "true" && "$original_path" != "$PROJECT_PATH" ]]; then
            echo "🔧 Normalized path: $original_path → $PROJECT_PATH" >&2
        fi
        
        # Export the normalized path
        export PROJECT_PATH
    fi


    # Info-only flags bypass build validation (they exit before any build runs)
    if [[ "$LIST_FLAVORS" == "true" || "$SHOW_STATUS" == "true" || "$LIST_IMAGES" == "true" || "$SHOW_HELP" == "true" || "$LIST_AGENTS" == "true" || "$LIST_SKILLS" == "true" || "$WORKSPACE_INIT" == "true" ]]; then
        return 0
    fi

    # Validate build + no-cache combination
    if [[ "$NO_CACHE" == "true" ]]; then
        local has_build_flag=false
        [[ "$BUILD_CUSTOM_IMAGE" == "true" ]] && has_build_flag=true
        if [[ "$has_build_flag" == "false" ]]; then
            local build_options="--build-custom-image"
            echo "Error: --no-cache requires $build_options" >&2
            exit 1
        fi
    fi
    
    # Validate dev mode (only with build)
    if [[ "$DEV_MODE" == "true" && "$BUILD_IMAGE" != "true" ]]; then
        echo "Error: --dev can only be used with --build" >&2
        exit 1
    fi
    
    # Validate image parameter
    if [[ -n "$DOCKER_IMAGE" && "$BUILD_IMAGE" == "true" ]]; then
        echo "Error: --image cannot be used with --build (build creates specific images)" >&2
        exit 1
    fi

    # Validate --create requires --work-branch
    if [[ "$CREATE_BRANCH" == "true" && -z "$WORK_BRANCH" ]]; then
        echo "Error: --create requires --work-branch" >&2
        echo "" >&2
        echo "The --create flag explicitly creates a branch if it doesn't exist." >&2
        echo "Usage: nyia-assistant --work-branch feature/my-branch --create" >&2
        echo "" >&2
        echo "Without --create, --work-branch only switches to existing branches" >&2
        echo "(this prevents accidental branch creation from typos)." >&2
        exit 1
    fi

    # New validation: For assistant mode, require explicit -p flag for prompts
    # No validation needed for dispatcher mode (it handles subcommands)
    if [[ "$SCRIPT_TYPE" == "assistant" && ${#REMAINING_ARGS[@]} -gt 0 && -z "$USER_PROMPT" ]]; then
        # Check if there are any remaining args that look like prompts
        local has_non_option_args=false
        for arg in "${REMAINING_ARGS[@]}"; do
            if [[ "$arg" != --* ]]; then
                has_non_option_args=true
                break
            fi
        done
        
        if [[ "$has_non_option_args" == "true" ]]; then
            echo "Error: Direct text prompts not supported" >&2
            echo "" >&2
            echo "Bad:  nyia-claude 'help me'" >&2
            echo "Good: nyia-claude              # Interactive mode" >&2
            echo "" >&2
            exit 1
        fi
    fi
    
    # Validate flavor parameter
    if [[ -n "$FLAVOR" ]]; then
        # Source the validation function if not already available
        local script_dir="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
        if [[ -f "$script_dir/../bin/common/shared.sh" ]] && ! declare -f validate_flavor_name >/dev/null; then
            source "$script_dir/../bin/common/shared.sh"
        fi
        
        # Validate flavor name format
        if declare -f validate_flavor_name >/dev/null && ! validate_flavor_name "$FLAVOR"; then
            echo "Error: Invalid flavor name '$FLAVOR'" >&2
            echo "" >&2
            echo "Flavor names must:" >&2
            echo "  - Start and end with alphanumeric characters" >&2
            echo "  - Contain only lowercase letters, numbers, and hyphens" >&2
            echo "  - Not have consecutive hyphens" >&2
            echo "" >&2
            echo "Valid examples: node, python, node18, php81, nextjs" >&2
            echo "Invalid examples: Node, python_3, -node, php-, node--js" >&2
            exit 1
        fi
    fi
    
    # Validate conflicting image selection flags
    if [[ -n "$FLAVOR" && -n "$DOCKER_IMAGE" ]]; then
        echo "Error: Cannot use both --flavor and --image flags together" >&2
        echo "" >&2
        echo "Choose one approach:" >&2
        echo "  --flavor node           # Use flavor system" >&2
        echo "  --image custom:tag      # Use specific image" >&2
        exit 1
    fi

}

# === UTILITY FUNCTIONS ===
show_help() {
    local script_name="$1"
    local assistant_name="$2"
    local thematic_alias="$3"
    
    case "$SCRIPT_TYPE" in
        "dispatcher")
            show_dispatcher_help "$script_name"
            ;;
        "assistant")
            show_assistant_help "$assistant_name" "$thematic_alias"
            ;;
        *)
            echo "Error: Cannot show help for unknown script type: $SCRIPT_TYPE" >&2
            exit 1
            ;;
    esac
}

print_verbose() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo "🔧 $*" >&2
    fi
}

# === DEBUGGING ===
debug_args() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo "=== CLI Parser Debug ===" >&2
        echo "SCRIPT_TYPE: $SCRIPT_TYPE" >&2
        echo "SHOW_HELP: $SHOW_HELP" >&2
        echo "SHOW_STATUS: $SHOW_STATUS" >&2
        echo "BUILD_IMAGE: $BUILD_IMAGE" >&2
        echo "DEV_MODE: $DEV_MODE" >&2
        echo "NO_CACHE: $NO_CACHE" >&2
        echo "LOGIN_ONLY: $LOGIN_ONLY" >&2
        echo "DOCKER_IMAGE: $DOCKER_IMAGE" >&2
        echo "LIST_IMAGES: $LIST_IMAGES" >&2
        echo "PROJECT_PATH: $PROJECT_PATH" >&2
        echo "COMMAND: $COMMAND" >&2
        echo "ASSISTANT_NAME: $ASSISTANT_NAME" >&2
        echo "USER_PROMPT: $USER_PROMPT" >&2
        echo "NYIA_AGENT: $NYIA_AGENT" >&2
        echo "LIST_AGENTS: $LIST_AGENTS" >&2
        echo "LIST_SKILLS: $LIST_SKILLS" >&2
        echo "NYIA_COMMAND_MODE_CLI: $NYIA_COMMAND_MODE_CLI" >&2
        echo "ENABLE_RAG: $ENABLE_RAG" >&2
        echo "NYIA_RAG_MODEL: ${NYIA_RAG_MODEL:-<from config>}" >&2
        echo "REMAINING_ARGS: ${REMAINING_ARGS[*]}" >&2
        echo "======================" >&2
    fi
}

# === MAIN ENTRY POINT ===
# Usage: source lib/cli-parser.sh && parse_args "dispatcher|assistant" "$@"
# This file is meant to be sourced, not executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Error: cli-parser.sh should be sourced, not executed directly" >&2
    echo "Usage: source lib/cli-parser.sh && parse_args 'dispatcher' \"\$@\"" >&2
    exit 1
fi
