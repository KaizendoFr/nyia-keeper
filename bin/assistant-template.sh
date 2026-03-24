#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later OR Proprietary
# Copyright (c) 2024 Nyia Keeper Contributors

# Nyia Keeper Assistant Template
# Generic wrapper for all AI assistants - source this with ASSISTANT_CONFIG set

set -e

# Source centralized CLI parser and common functions
script_dir="$(dirname "$(realpath "$0")")"
source "$script_dir/../lib/cli-parser.sh"
source "$script_dir/common-functions.sh"

# Ensure NYIAKEEPER_HOME is set (wrappers export it, but guard for direct invocation)
if [[ -z "${NYIAKEEPER_HOME:-}" ]]; then
    export NYIAKEEPER_HOME=$(get_nyiakeeper_home)
fi

# Load assistant configuration
if [[ -z "$ASSISTANT_CONFIG" ]]; then
    print_error "ASSISTANT_CONFIG not set"
    exit 1
fi

# Resolve relative paths
if [[ "$ASSISTANT_CONFIG" != /* ]]; then
    ASSISTANT_CONFIG="$script_dir/$ASSISTANT_CONFIG"
fi

if [[ ! -f "$ASSISTANT_CONFIG" ]]; then
    # Docker-style fallback: check default location if user-specified path fails
    assistant_name=$(basename "$ASSISTANT_CONFIG" .conf)
    nyia_home=$(get_nyiakeeper_home 2>/dev/null)
    default_config="$nyia_home/config/${assistant_name}.conf"
    
    if [[ -f "$default_config" ]]; then
        print_info "Configuration not found at: $ASSISTANT_CONFIG"
        print_info "Using default configuration: $default_config"
        ASSISTANT_CONFIG="$default_config"
    else
        print_error "Assistant configuration file not found: $ASSISTANT_CONFIG"
        if [[ -n "$nyia_home" && -d "$nyia_home/config" ]]; then
            print_info "Default configuration directory: $nyia_home/config"
            print_info "Available configurations:"
            if ls "$nyia_home/config"/*.conf 2>/dev/null; then
                ls "$nyia_home/config"/*.conf | sed 's/^/  /'
            else
                print_info "  No configuration files found in default location"
                
                # Check for example files that can be used
                if ls "$nyia_home/config"/*.conf.example 2>/dev/null; then
                    print_info ""
                    print_info "  Example configuration files found:"
                    ls "$nyia_home/config"/*.conf.example | sed 's/^/    /'
                    print_info ""
                    print_info "  To fix, copy the example to create your config:"
                    print_info "    cp $nyia_home/config/${assistant_name}.conf.example $nyia_home/config/${assistant_name}.conf"
                    print_info "    Then edit the file to add your settings"
                else
                    print_info "  Configuration templates may not have been installed properly"
                    print_info "  Please reinstall or contact support"
                fi
            fi
        fi
        exit 1
    fi
fi

source "$ASSISTANT_CONFIG"

# Validate required configuration variables
for var in ASSISTANT_NAME ASSISTANT_CLI BASE_IMAGE_NAME DOCKERFILE_PATH CONTEXT_DIR_NAME; do
    if [[ -z "${!var}" ]]; then
        print_error "Required configuration variable not set: $var"
        exit 1
    fi
done

# Assistant-specific directories are created by get_nyiakeeper_home() -> generate_default_assistant_configs()

# === MAIN EXECUTION ===
main() {
    # Store assistant name from config BEFORE parsing (CLI parser resets variables)
    config_assistant_name="$ASSISTANT_NAME"
    config_thematic_alias="$THEMATIC_ALIAS"
    
    # Parse arguments using centralized parser
    parse_args "assistant" "$@"
    validate_args
    debug_args

    # Startup update check (runtime only — never blocks assistant launch)
    type check_for_updates_if_due &>/dev/null && check_for_updates_if_due || true

    # Set project path if not provided
    if [[ -z "$PROJECT_PATH" ]]; then
        PROJECT_PATH=$(pwd)
    fi

    # === INFO-ONLY EXITS (Plan 187: no project-level side effects) ===
    # These must exit before auto-init to avoid creating .nyiakeeper/ in CWD

    # Handle help
    if [[ "$SHOW_HELP" == "true" ]]; then
        show_help "$(basename "$0")" "$config_assistant_name" ""
        exit 0
    fi

    # Handle version
    if [[ "$SHOW_VERSION" == "true" ]]; then
        local version=$(get_installed_version)
        echo "Nyia Keeper version: $version"
        exit 0
    fi

    # Handle requirements check
    if [[ "$CHECK_REQUIREMENTS" == "true" ]]; then
        # Detect workspace mode early for requirements check
        local _ws_mode=false
        if declare -f is_workspace >/dev/null 2>&1 && is_workspace "$PROJECT_PATH"; then
            _ws_mode=true
        fi
        show_requirements_check "$PROJECT_PATH" "$_ws_mode"
        exit $?
    fi

    # Handle status mode (info-only, takes priority over build)
    if [[ "$SHOW_STATUS" == "true" ]]; then
        show_assistant_status
        exit 0
    fi

    # Handle list images mode (info-only, takes priority over build)
    if [[ "$LIST_IMAGES" == "true" ]]; then
        list_assistant_images "$BASE_IMAGE_NAME"
        exit 0
    fi

    # Handle list flavors mode (info-only, takes priority over build)
    if [[ "$LIST_FLAVORS" == "true" ]]; then
        list_assistant_flavors "$config_assistant_name"
        exit 0
    fi

    # Handle list agents mode (info-only, host-side resolution) - Plan 149, updated Plan 201
    if [[ "$LIST_AGENTS" == "true" ]]; then
        local agent_lib="$script_dir/../lib/agent-resolution.sh"
        if [[ -f "$agent_lib" ]]; then
            source "$agent_lib"
            local nyiakeeper_home
            nyiakeeper_home=$(get_nyiakeeper_home)
            local team_dir=""
            if declare -f resolve_team_dir >/dev/null 2>&1; then
                team_dir=$(resolve_team_dir 2>/dev/null) || true
            fi
            list_agents "$ASSISTANT_CLI" "$PROJECT_PATH" "$nyiakeeper_home" "$team_dir"
        else
            echo "Agent resolution library not found" >&2
        fi
        exit 0
    fi

    # Handle list skills mode (info-only, host-side resolution) - Plan 177
    if [[ "$LIST_SKILLS" == "true" ]]; then
        local skill_lib="$script_dir/../lib/skill-resolution.sh"
        if [[ -f "$skill_lib" ]]; then
            source "$skill_lib"
            local nyiakeeper_home
            nyiakeeper_home=$(get_nyiakeeper_home)
            local team_dir=""
            if declare -f resolve_team_dir >/dev/null 2>&1; then
                team_dir=$(resolve_team_dir 2>/dev/null) || true
            fi
            list_skills "$ASSISTANT_CLI" "$PROJECT_PATH" "$nyiakeeper_home" "$team_dir"
        else
            echo "Skill resolution library not found" >&2
        fi
        exit 0
    fi

    # Handle workspace init mode (info-only, scaffolds workspace.conf) - Plan 199
    if [[ "$WORKSPACE_INIT" == "true" ]]; then
        if [[ -f "$PROJECT_PATH/.nyiakeeper/workspace.conf" ]]; then
            print_error "workspace.conf already exists at $PROJECT_PATH/.nyiakeeper/workspace.conf"
            print_info "Edit the existing file directly"
            exit 1
        fi
        mkdir -p "$PROJECT_PATH/.nyiakeeper"
        cat > "$PROJECT_PATH/.nyiakeeper/workspace.conf" << 'WORKSPACE_TEMPLATE'
# Nyia Keeper Workspace Configuration
# =====================================
# A workspace lets you mount multiple repositories into a single container.
# Each line defines one repository: PATH MODE
#
# PATH  = absolute path to the repository on your host
# MODE  = rw (read-write, requires git) or ro (read-only)
#
# YOU MUST EDIT THESE PATHS to match your actual repositories!
# The examples below are placeholders and WILL NOT WORK as-is.
#
# Examples:
# /home/user/projects/my-api rw
# /home/user/projects/shared-libs ro

# --- Edit below: add your repositories ---
# /path/to/your/main-project rw
# /path/to/your/dependency ro
WORKSPACE_TEMPLATE
        print_success "Created workspace configuration at: $PROJECT_PATH/.nyiakeeper/workspace.conf"
        print_info "Edit the file to add your repository paths, then run the assistant normally"
        exit 0
    fi

    # === END INFO-ONLY EXITS ===

    # Workspace mode detection (multi-repository support)
    WORKSPACE_MODE=false
    WORKSPACE_REPOS=()
    WORKSPACE_REPO_MODES=()
    if declare -f is_workspace >/dev/null 2>&1 && is_workspace "$PROJECT_PATH"; then
        WORKSPACE_MODE=true
        mapfile -t WORKSPACE_REPOS < <(parse_workspace_repos "$PROJECT_PATH")
        mapfile -t WORKSPACE_REPO_MODES < <(parse_workspace_modes "$PROJECT_PATH")

        if ! verify_workspace_repos "$PROJECT_PATH" WORKSPACE_REPOS WORKSPACE_REPO_MODES; then
            print_error "Workspace verification failed"
            exit 1
        fi

        # Count RO/RW for status display
        # Note: use $((var + 1)) not ((var++)) — the latter returns exit 1
        # when var=0 (bash arithmetic: 0 is falsy), which kills set -e scripts
        local rw_count=0 ro_count=0
        for m in "${WORKSPACE_REPO_MODES[@]}"; do
            if [[ "$m" == "rw" ]]; then
                rw_count=$((rw_count + 1))
            else
                ro_count=$((ro_count + 1))
            fi
        done
        print_status "Workspace mode: ${#WORKSPACE_REPOS[@]} repositories ($rw_count rw, $ro_count ro)"
        local _ws_i
        for ((_ws_i=0; _ws_i<${#WORKSPACE_REPOS[@]}; _ws_i++)); do
            echo "  $(basename "${WORKSPACE_REPOS[_ws_i]}") (${WORKSPACE_REPOS[_ws_i]}) [${WORKSPACE_REPO_MODES[_ws_i]:-rw}]" >&2
        done
    fi

    # Detect if workspace root is itself a git repository
    WORKSPACE_ROOT_IS_GIT=false
    if [[ "$WORKSPACE_MODE" == "true" ]] && git -C "$PROJECT_PATH" rev-parse --git-dir >/dev/null 2>&1; then
        WORKSPACE_ROOT_IS_GIT=true
        print_verbose "Workspace root is a git repository — branch safety enabled for root"
    fi
    export WORKSPACE_MODE WORKSPACE_REPOS WORKSPACE_REPO_MODES WORKSPACE_ROOT_IS_GIT

    # Auto-initialize project prompts directory (Git-style behavior)
    ensure_project_prompts_directory "$PROJECT_PATH"

    # Auto-initialize exclusions system on first run (Git-style behavior)
    # Only if exclusions are enabled and config doesn't exist
    if [[ "$ENABLE_MOUNT_EXCLUSIONS" == "true" ]] || [[ -z "$ENABLE_MOUNT_EXCLUSIONS" ]]; then
        if [[ ! -f "$PROJECT_PATH/.nyiakeeper/exclusions.conf" ]]; then
            # Load exclusions library to get init function
            local exclusions_lib="$script_dir/../lib/exclusions-commands.sh"
            if [[ -f "$exclusions_lib" ]]; then
                source "$exclusions_lib"

                # Call full exclusions initialization (silent mode)
                local old_verbose="$VERBOSE"
                export VERBOSE="false"
                exclusions_init "$PROJECT_PATH" >/dev/null 2>&1
                export VERBOSE="$old_verbose"

                if [[ "$VERBOSE" == "true" ]]; then
                    print_info "Auto-initialized exclusions system: .nyiakeeper/exclusions.conf"
                fi
            else
                print_error "Failed to load exclusions library: $exclusions_lib"
                exit 1
            fi
        fi
    fi

    # SECURITY CHECKPOINT: Verify exclusions system is loaded when enabled
    if [[ "$ENABLE_MOUNT_EXCLUSIONS" == "true" ]] || [[ -z "$ENABLE_MOUNT_EXCLUSIONS" ]]; then
        # Load mount exclusions library if not already loaded
        local mount_exclusions_lib="$script_dir/../lib/mount-exclusions.sh"
        if ! declare -f create_volume_args >/dev/null 2>&1; then
            if [[ -f "$mount_exclusions_lib" ]]; then
                source "$mount_exclusions_lib"
            fi
        fi

        # Final verification - exclusions must work when enabled
        if ! declare -f create_volume_args >/dev/null 2>&1; then
            print_error "SECURITY ERROR: Mount exclusions enabled but system failed to load"
            print_error "This would expose sensitive files (.env, credentials) to AI assistants"
            print_error ""
            print_error "To fix:"
            print_error "  1. Restart and try again"
            print_error "  2. Use --disable-exclusions flag (NOT RECOMMENDED for security)"
            exit 1
        fi
        print_verbose "✅ Mount exclusions verified and active"
    fi

    # Show warning when exclusions explicitly disabled
    if [[ "$DISABLE_EXCLUSIONS" == "true" ]]; then
        print_warning() { echo -e "\e[33m⚠️  $1\e[0m" >&2; }
        print_warning "SECURITY RISK: Mount exclusions disabled"
        print_warning "Sensitive files (.env, credentials, keys) are exposed to AI"
        print_warning "Only use this in trusted environments"
        echo ""
    fi

    # Use explicit prompt from -p/--prompt flag or interactive mode
    local prompt="$USER_PROMPT"

    
    # Handle custom image build (end-user power feature)
    if [[ "$BUILD_CUSTOM_IMAGE" == "true" ]]; then
        build_custom_image "$config_assistant_name"
        exit $?
    fi

    # Handle API key setup mode
    if [[ "$SET_API_KEY" == "true" ]]; then
        set_api_key_helper "$config_assistant_name" "$ASSISTANT_CLI"
        exit $?
    fi

    # Handle interactive setup mode (OpenCode model selection)
    if [[ "$SETUP_MODE" == "true" ]]; then
        if [[ "$ASSISTANT_CLI" == "opencode" ]]; then
            "$NYIAKEEPER_HOME/bin/opencode-setup.sh"
            exit $?
        else
            print_error "Interactive setup is only available for OpenCode assistant"
            exit 1
        fi
    fi


    # Source credentials if available (private path first, legacy fallback)
    local creds_file="$PROJECT_PATH/.nyiakeeper/private/creds/env"
    local _using_legacy_creds=false
    if [[ ! -f "$creds_file" ]]; then
        creds_file="$PROJECT_PATH/.nyiakeeper/creds/env"
        _using_legacy_creds=true
    fi
    if [[ -f "$creds_file" ]]; then
        if [[ "$_using_legacy_creds" == "true" ]]; then
            print_deprecation ".nyiakeeper/creds/" ".nyiakeeper/private/creds/"
        fi
        source "$creds_file"
        print_verbose "Loaded credentials from $creds_file"
    else
        print_verbose "No credentials file found"
    fi
    
    # Source provider-specific hooks if they exist and call setup hook
    # (Must happen before login and credential checks)
    local provider_hooks_file="$DOCKERFILE_PATH/${ASSISTANT_CLI}-hooks.sh"
    if [[ -f "$provider_hooks_file" ]]; then
        source "$provider_hooks_file"
        
        # Call setup hook if it exists
        if declare -f setup_env_vars >/dev/null; then
            setup_env_vars
        fi
    fi
    
    # Handle login mode
    if [[ "$LOGIN_ONLY" == "true" ]]; then
        # Note: DEV_MODE removed as dead code (--dev requires --build, never reaches login)
        login_assistant "$ASSISTANT_CLI" "$BASE_IMAGE_NAME" "$DOCKERFILE_PATH" "$CONFIG_DIR_NAME" "$AUTH_METHOD" "$SHELL_MODE" "$DOCKER_IMAGE"
        exit $?
    fi
    
    # Run requirements check before execution (unless skipped)
    if [[ "$SKIP_CHECKS" != "true" ]]; then
        if ! check_requirements_fast "$PROJECT_PATH" "$WORKSPACE_MODE"; then
            print_error "Requirements check failed. Fix issues above or use --skip-checks to bypass"
            print_info "Run '$config_assistant_name --check-requirements' for detailed diagnostics"
            exit 1
        fi
    fi
    
    
    # Execute assistant using abstracted functions
    # Note: DEV_MODE removed as dead code (--dev requires --build, never reaches RUN)
    run_assistant "$config_assistant_name" "$ASSISTANT_CLI" "$BASE_IMAGE_NAME" "$DOCKERFILE_PATH" "$CONTEXT_DIR_NAME" "$PROJECT_PATH" "$prompt" "$BASE_BRANCH" "$SHELL_MODE" "$DOCKER_IMAGE" "$WORK_BRANCH"
}

# === STATUS DISPLAY ===
show_assistant_status() {
    local nyiakeeper_home=$(get_nyiakeeper_home)
    
    echo "Nyia Keeper ${config_assistant_name} Status:"
    echo "  Project: $(basename "$PROJECT_PATH")"
    echo "  Path: $PROJECT_PATH"
    echo "  Branch: $(get_current_branch)"
    
    if [[ "$DEV_MODE" == "true" ]]; then
        echo "  Mode: Development"
        local dev_image=$(get_target_image "$BASE_IMAGE_NAME" "true" "true")
        echo "  Target image: $dev_image"
        # Try to find what would actually be used
        local selected_image=$(find_best_image "$BASE_IMAGE_NAME" "true" 2>/dev/null || echo "No suitable image found")
    else
        echo "  Mode: Production (default)"
        local prod_image=$(get_target_image "$BASE_IMAGE_NAME" "false" "true")
        echo "  Target image: $prod_image"
        # Try to find what would actually be used
        local selected_image=$(find_best_image "$BASE_IMAGE_NAME" "false" 2>/dev/null || echo "No suitable image found")
    fi
    
    echo "  Selected image: $selected_image"
    echo "  Context dir: $PROJECT_PATH/$CONTEXT_DIR_NAME"
    
    # Show available images (convert dash-form config name to slash-form)
    local _clean="${BASE_IMAGE_NAME#nyiakeeper-}"
    local _search="nyiakeeper/${_clean}"
    echo "  Available images:"
    if command -v docker >/dev/null && docker images --filter "reference=${_search}*" --format "table {{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.CreatedAt}}" 2>/dev/null | tail -n +2 | grep -q . 2>/dev/null; then
        docker images --filter "reference=${_search}*" --format "    {{.Repository}}:{{.Tag}} ({{.Size}}, {{.CreatedAt}})" 2>/dev/null
    else
        echo "    No images found - run nyia-${config_assistant_name} --build-custom-image to create custom overlay"
    fi
    
    # Show command approval mode (Plan 145)
    echo ""
    echo "=== Command Approval Mode ==="
    local _policy_lib=""
    _policy_lib="$HOME/.local/lib/nyiakeeper/command-policy.sh"
    if [[ -f "$_policy_lib" ]]; then
        source "$_policy_lib"
        local _mode_result
        _mode_result=$(resolve_command_mode "$config_assistant_name" "$PROJECT_PATH")
        local _eff_mode="${_mode_result%%	*}"
        local _eff_source="${_mode_result#*	}"
        echo "  Effective mode: $_eff_mode"
        echo "  Source: $_eff_source"
        echo "  Manage: nyia config view $config_assistant_name"
    else
        echo "  (command-policy module not found)"
    fi

    # Show Docker overlays
    echo ""
    echo "=== Docker Overlays ==="
    # Extract just assistant name (remove nyiakeeper- prefix if present) 
    local assistant_name=$(basename "$BASE_IMAGE_NAME" | cut -d: -f1 | sed 's/^nyiakeeper-//')
    
    # Check user overlay
    local user_overlay="$HOME/.config/nyiakeeper/$assistant_name/overlay/Dockerfile"
    if [[ -f "$user_overlay" ]]; then
        echo "  User overlay: FOUND"
        echo "    Path: $user_overlay"
    else
        echo "  User overlay: Not configured"
        echo "    Create at: ~/.config/nyiakeeper/$assistant_name/overlay/Dockerfile"
    fi
    
    # Check project overlay
    local project_overlay="$PROJECT_PATH/.nyiakeeper/$assistant_name/overlay/Dockerfile"
    if [[ -f "$project_overlay" ]]; then
        echo "  Project overlay: FOUND"
        echo "    Path: $project_overlay"
    else
        echo "  Project overlay: Not configured"
        echo "    Create at: .nyiakeeper/$assistant_name/overlay/Dockerfile"
    fi
    
    # Show prompt customization status
    echo ""
    echo "=== Prompt Customization ==="
    echo "  Directory: ~/.config/nyiakeeper/prompts/"

    # Check for active overrides
    local prompts_dir="$nyiakeeper_home/prompts"
    local active_count=0

    if [[ -f "$prompts_dir/base-overrides.md" ]]; then
        echo "  ✓ Global base overrides active"
        ((active_count++)) || true
    fi

    if [[ -f "$prompts_dir/${config_assistant_name}-overrides.md" ]]; then
        echo "  ✓ ${config_assistant_name}-specific overrides active"
        ((active_count++)) || true
    fi

    if [[ -f "$PROJECT_PATH/.nyiakeeper/shared/prompts/project-overrides.md" ]]; then
        echo "  ✓ Project shared overrides active"
        ((active_count++)) || true
    elif [[ -f "$PROJECT_PATH/.nyiakeeper/prompts/project-overrides.md" ]]; then
        print_deprecation ".nyiakeeper/prompts/" ".nyiakeeper/shared/prompts/"
        echo "  ✓ Project overrides active"
        ((active_count++)) || true
    fi

    if [[ -f "$PROJECT_PATH/.nyiakeeper/shared/prompts/${config_assistant_name}-project.md" ]]; then
        echo "  ✓ Project shared ${config_assistant_name}-specific overrides active"
        ((active_count++)) || true
    elif [[ -f "$PROJECT_PATH/.nyiakeeper/prompts/${config_assistant_name}-project.md" ]]; then
        print_deprecation ".nyiakeeper/prompts/" ".nyiakeeper/shared/prompts/"
        echo "  ✓ Project ${config_assistant_name}-specific overrides active"
        ((active_count++)) || true
    fi

    if [[ $active_count -eq 0 ]]; then
        echo "  No active customizations (using defaults)"
        echo "  See: nyia-${config_assistant_name} --help for activation instructions"
    fi

    # Show example overlays
    echo ""
    echo "=== Overlay Documentation ==="
    echo "Create custom Dockerfile at overlay location:"
    local registry=$(get_docker_registry)
    echo "  FROM ${registry}/nyiakeeper-${assistant_name}:latest"
    echo "  RUN apt-get update && apt-get install -y your-tools"
    echo ""
    echo "Then build: nyia-$assistant_name --build-custom-image"
}

main "$@"
