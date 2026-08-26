#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later OR Proprietary
# Copyright (c) 2024 Nyia Keeper Contributors
# Exclusions subcommand implementations for nyia
# Provides commands for managing mount exclusions

# Source shared cache utilities first
if ! declare -f is_exclusions_cache_valid >/dev/null 2>&1; then
    source "$(dirname "${BASH_SOURCE[0]}")/exclusions-cache-utils.sh" 2>/dev/null || true
fi

# Standard bash 4.0+ associative arrays (no compatibility layer needed)

# Ensure mount-exclusions library is loaded
if ! declare -f get_exclusion_patterns >/dev/null 2>&1; then
    source "$(dirname "${BASH_SOURCE[0]}")/mount-exclusions.sh" 2>/dev/null || {
        echo "❌ Error: Could not load mount-exclusions library" >&2
        exit 1
    }
fi

# Platform-aware case sensitivity for file matching  
get_find_case_args() {
    # On macOS with case-insensitive filesystem, use case-insensitive matching
    if [[ "$(uname -s)" == "Darwin" ]]; then
        echo "-iname"
    else
        # Linux filesystems are typically case-sensitive
        echo "-name" 
    fi
}

# Color functions if not already defined
if ! declare -f print_header >/dev/null 2>&1; then
    print_header() { echo -e "\e[1m$1\e[0m"; }
    print_success() { echo -e "\e[32m✅ $1\e[0m"; }
    print_error() { echo -e "\e[31m❌ $1\e[0m"; }
    print_info() { echo -e "\e[37m📍 $1\e[0m"; }
fi

# Get project path with validation
get_project_path() {
    local path="${1:-$(pwd)}"
    [[ -d "$path" ]] || { echo "❌ Directory not found: $path" >&2; exit 1; }
    realpath "$path"
}

# === WORKSPACE DETECTION FOR EXCLUSION COMMANDS ===

# Source workspace library if available and not already loaded
if ! declare -f is_workspace >/dev/null 2>&1; then
    source "$(dirname "${BASH_SOURCE[0]}")/workspace.sh" 2>/dev/null || true
fi

# Returns workspace repos and modes for a project path, or empty if not workspace.
# Usage: get_workspace_repos_for_exclusions "$project_path"
# Sets: _WS_REPOS array, _WS_MODES array (empty if not workspace)
get_workspace_repos_for_exclusions() {
    local project_path="$1"
    _WS_REPOS=()
    _WS_MODES=()

    if ! declare -f is_workspace >/dev/null 2>&1; then
        return 0
    fi

    if ! is_workspace "$project_path"; then
        return 0
    fi

    if declare -f parse_workspace_repos >/dev/null 2>&1; then
        mapfile -t _WS_REPOS < <(parse_workspace_repos "$project_path")
        mapfile -t _WS_MODES < <(parse_workspace_modes "$project_path")
    fi
}

# === CACHE MANAGEMENT FUNCTIONS ===


# Read cached exclusion lists
read_cached_exclusions() {
    local project_path="$1"
    local cache_file="$project_path/.nyiakeeper/.excluded-files.cache"
    
    # Initialize arrays
    CACHED_EXCLUDED_FILES=()
    CACHED_EXCLUDED_DIRS=()
    CACHED_SYSTEM_FILES=()
    CACHED_SYSTEM_DIRS=()
    
    # Read cache file
    if [[ -f "$cache_file" ]]; then
        while IFS='=' read -r key value; do
            case "$key" in
                excluded_files)
                    IFS=',' read -ra CACHED_EXCLUDED_FILES <<< "$value"
                    ;;
                excluded_dirs)
                    IFS=',' read -ra CACHED_EXCLUDED_DIRS <<< "$value"
                    ;;
                system_files)
                    IFS=',' read -ra CACHED_SYSTEM_FILES <<< "$value"
                    ;;
                system_dirs)
                    IFS=',' read -ra CACHED_SYSTEM_DIRS <<< "$value"
                    ;;
            esac
        done < "$cache_file"
        return 0
    fi
    return 1
}


# List excluded files and directories
exclusions_list() {
    local project_path
    project_path=$(get_project_path "$1")

    print_workspace_info_header "$project_path"
    print_header "📋 Files excluded in: $project_path"
    echo "============================================="
    
    if [[ "$ENABLE_MOUNT_EXCLUSIONS" != "true" ]]; then
        print_info "Exclusions disabled - no files would be excluded"
        return 0
    fi
    
    # Use associative arrays to track unique matches
    declare -A excluded_files
    declare -A excluded_dirs
    declare -A system_files
    declare -A system_dirs
    
    # Track counts
    local excluded_files_count=0
    local excluded_dirs_count=0
    local system_files_count=0
    local system_dirs_count=0
    
    # Check if cache is valid and use it
    if is_exclusions_cache_valid "$project_path"; then
        # Read from cache
        if read_cached_exclusions "$project_path"; then
            # Populate associative arrays from cache
            for file in "${CACHED_EXCLUDED_FILES[@]}"; do
                if [[ -n "$file" ]]; then
                    excluded_files["$file"]=1
                    excluded_files_count=$((excluded_files_count + 1))
                fi
            done
            for dir in "${CACHED_EXCLUDED_DIRS[@]}"; do
                if [[ -n "$dir" ]]; then
                    excluded_dirs["$dir"]=1
                    excluded_dirs_count=$((excluded_dirs_count + 1))
                fi
            done
            for file in "${CACHED_SYSTEM_FILES[@]}"; do
                if [[ -n "$file" ]]; then
                    system_files["$file"]=1
                    system_files_count=$((system_files_count + 1))
                fi
            done
            for dir in "${CACHED_SYSTEM_DIRS[@]}"; do
                if [[ -n "$dir" ]]; then
                    system_dirs["$dir"]=1
                    system_dirs_count=$((system_dirs_count + 1))
                fi
            done
        fi
    else
        # Cache invalid or doesn't exist - scan filesystem
        
        # Source mount-exclusions to get is_nyiakeeper_system_path function
        if declare -f is_nyiakeeper_system_path >/dev/null 2>&1; then
            : # Function already available
        elif [[ -f "$(dirname "${BASH_SOURCE[0]}")/mount-exclusions.sh" ]]; then
            source "$(dirname "${BASH_SOURCE[0]}")/mount-exclusions.sh"
        fi
        
        # Use find for recursive pattern matching
        local max_depth="${EXCLUSION_MAX_DEPTH:-5}"
        
        # Arrays for building cache
        SCAN_EXCLUDED_FILES=()
        SCAN_EXCLUDED_DIRS=()
        SCAN_SYSTEM_FILES=()
        SCAN_SYSTEM_DIRS=()
        
        # Process file patterns using find
        while IFS=' ' read -r pattern; do
            while IFS= read -r -d '' match; do
                local rel_path="${match#$project_path/}"
                
                # Check if this is a Nyia Keeper system file
                if declare -f is_nyiakeeper_system_path >/dev/null 2>&1 && is_nyiakeeper_system_path "$rel_path" "$project_path"; then
                    if [[ -z "${system_files[$rel_path]:-}" ]]; then
                        system_files["$rel_path"]=1
                        system_files_count=$((system_files_count + 1))
                        SCAN_SYSTEM_FILES+=("$rel_path")
                    fi
                else
                    if [[ -z "${excluded_files[$rel_path]:-}" ]]; then
                        excluded_files["$rel_path"]=1
                        excluded_files_count=$((excluded_files_count + 1))
                        SCAN_EXCLUDED_FILES+=("$rel_path")
                    fi
                fi
            done < <(find "$project_path" -maxdepth "$max_depth" -type f $(get_find_case_args) "$pattern" -print0 2>/dev/null)
        done < <(get_exclusion_patterns "$project_path" | tr ' ' '\n')
        
        # Process directory patterns using find
        while IFS=' ' read -r pattern; do
            while IFS= read -r -d '' match; do
                local rel_path="${match#$project_path/}"
                
                # Check if this is a Nyia Keeper system directory
                if declare -f is_nyiakeeper_system_path >/dev/null 2>&1 && is_nyiakeeper_system_path "$rel_path" "$project_path"; then
                    if [[ -z "${system_dirs[$rel_path]:-}" ]]; then
                        system_dirs["$rel_path"]=1
                        system_dirs_count=$((system_dirs_count + 1))
                        SCAN_SYSTEM_DIRS+=("$rel_path")
                    fi
                else
                    if [[ -z "${excluded_dirs[$rel_path]:-}" ]]; then
                        excluded_dirs["$rel_path"]=1
                        excluded_dirs_count=$((excluded_dirs_count + 1))
                        SCAN_EXCLUDED_DIRS+=("$rel_path")
                    fi
                fi
            done < <(find "$project_path" -maxdepth "$max_depth" -type d $(get_find_case_args) "$pattern" -print0 2>/dev/null)
        done < <(get_exclusion_dirs "$project_path" | tr ' ' '\n')

        # Process user-defined file path patterns (containing /) using find -path
        while IFS= read -r pattern; do
            [[ -z "$pattern" ]] && continue
            while IFS= read -r -d '' match; do
                local rel_path="${match#$project_path/}"
                if declare -f is_nyiakeeper_system_path >/dev/null 2>&1 && is_nyiakeeper_system_path "$rel_path" "$project_path"; then
                    if [[ -z "${system_files[$rel_path]:-}" ]]; then
                        system_files["$rel_path"]=1
                        system_files_count=$((system_files_count + 1))
                        SCAN_SYSTEM_FILES+=("$rel_path")
                    fi
                else
                    if [[ -z "${excluded_files[$rel_path]:-}" ]]; then
                        excluded_files["$rel_path"]=1
                        excluded_files_count=$((excluded_files_count + 1))
                        SCAN_EXCLUDED_FILES+=("$rel_path")
                    fi
                fi
            done < <(find "$project_path" -maxdepth "$max_depth" -type f -path "$project_path/$pattern" -print0 2>/dev/null)
        done < <(get_user_exclusion_file_paths "$project_path")

        # Process user-defined directory path patterns (containing /) using find -path
        # Root-anchored per gitignore semantics: match at project root only
        while IFS= read -r pattern; do
            [[ -z "$pattern" ]] && continue
            while IFS= read -r -d '' match; do
                local rel_path="${match#$project_path/}"
                if declare -f is_nyiakeeper_system_path >/dev/null 2>&1 && is_nyiakeeper_system_path "$rel_path" "$project_path"; then
                    if [[ -z "${system_dirs[$rel_path]:-}" ]]; then
                        system_dirs["$rel_path"]=1
                        system_dirs_count=$((system_dirs_count + 1))
                        SCAN_SYSTEM_DIRS+=("$rel_path")
                    fi
                else
                    if [[ -z "${excluded_dirs[$rel_path]:-}" ]]; then
                        excluded_dirs["$rel_path"]=1
                        excluded_dirs_count=$((excluded_dirs_count + 1))
                        SCAN_EXCLUDED_DIRS+=("$rel_path")
                    fi
                fi
            done < <(find "$project_path" -maxdepth "$max_depth" -type d -path "$project_path/$pattern" -print0 2>/dev/null)
        done < <(get_user_exclusion_dir_paths "$project_path")

        # Write results to cache for next time
        write_exclusions_cache "$project_path"
    fi
    
    # Display results
    echo "Files that will be excluded:"
    if [[ $excluded_files_count -eq 0 ]]; then
        echo "  (none found)"
    else
        for file in "${!excluded_files[@]}"; do
            echo "  🔒 $file"
        done | sort
    fi
    
    echo ""
    echo "Directories that will be excluded:"
    if [[ $excluded_dirs_count -eq 0 ]]; then
        echo "  (none found)"
    else
        for dir in "${!excluded_dirs[@]}"; do
            echo "  📁 $dir/"
        done | sort
    fi
    
    # Show Nyia Keeper system files if any (not excluded)
    if [[ $system_files_count -gt 0 || $system_dirs_count -gt 0 ]]; then
        echo ""
        echo "Nyia Keeper system files (NOT excluded - needed for operation):"
        if [[ $system_files_count -gt 0 ]]; then
            for file in "${!system_files[@]}"; do
                echo "  ✅ $file"
            done | sort
        fi
        if [[ $system_dirs_count -gt 0 ]]; then
            for dir in "${!system_dirs[@]}"; do
                echo "  ✅ $dir/"
            done | sort
        fi
    fi
    
    # Summary
    local total_excluded=$((excluded_files_count + excluded_dirs_count))
    local total_system=$((system_files_count + system_dirs_count))
    echo ""
    if [[ $total_excluded -eq 0 && $total_system -eq 0 ]]; then
        print_info "No sensitive files/directories found in this project"
    else
        print_info "Excluded: $excluded_files_count files, $excluded_dirs_count directories"
        if [[ $total_system -gt 0 ]]; then
            print_info "Protected Nyia Keeper system: $system_files_count files, $system_dirs_count directories"
        fi
    fi

    # Workspace mode: iterate repos and show per-repo results
    local _WS_REPOS _WS_MODES
    get_workspace_repos_for_exclusions "$project_path"
    if [[ ${#_WS_REPOS[@]} -gt 0 ]]; then
        local ws_total_files=0
        local ws_total_dirs=0
        local ri
        for ((ri=0; ri<${#_WS_REPOS[@]}; ri++)); do
            local repo="${_WS_REPOS[ri]}"
            local mode="${_WS_MODES[ri]:-rw}"
            local repo_name
            repo_name=$(basename "$repo")
            [[ ! -d "$repo" ]] && continue

            echo ""
            echo "============================================="
            print_header "  Repo: $repo_name ($repo) [$mode]"
            echo "============================================="

            local repo_files=0
            local repo_dirs=0
            local max_depth="${EXCLUSION_MAX_DEPTH:-5}"

            # Scan built-in file patterns
            while IFS=' ' read -r pattern; do
                while IFS= read -r -d '' match; do
                    local rel_path="${match#$repo/}"
                    echo "  🔒 $rel_path"
                    repo_files=$((repo_files + 1))
                done < <(find "$repo" -maxdepth "$max_depth" -type f $(get_find_case_args) "$pattern" -print0 2>/dev/null)
            done < <(get_exclusion_patterns "$repo" | tr ' ' '\n')

            # Scan built-in dir patterns
            while IFS=' ' read -r pattern; do
                while IFS= read -r -d '' match; do
                    local rel_path="${match#$repo/}"
                    echo "  📁 $rel_path/"
                    repo_dirs=$((repo_dirs + 1))
                done < <(find "$repo" -maxdepth "$max_depth" -type d $(get_find_case_args) "$pattern" -print0 2>/dev/null)
            done < <(get_exclusion_dirs "$repo" | tr ' ' '\n')

            # Scan user-defined path patterns for this repo (if it has exclusions.conf)
            if [[ -f "$repo/.nyiakeeper/exclusions.conf" ]]; then
                while IFS= read -r pattern; do
                    [[ -z "$pattern" ]] && continue
                    while IFS= read -r -d '' match; do
                        local rel_path="${match#$repo/}"
                        echo "  🔒 $rel_path"
                        repo_files=$((repo_files + 1))
                    done < <(find "$repo" -maxdepth "$max_depth" -type f -path "$repo/$pattern" -print0 2>/dev/null)
                done < <(get_user_exclusion_file_paths "$repo")

                while IFS= read -r pattern; do
                    [[ -z "$pattern" ]] && continue
                    while IFS= read -r -d '' match; do
                        local rel_path="${match#$repo/}"
                        echo "  📁 $rel_path/"
                        repo_dirs=$((repo_dirs + 1))
                    done < <(find "$repo" -maxdepth "$max_depth" -type d -path "$repo/$pattern" -print0 2>/dev/null)
                done < <(get_user_exclusion_dir_paths "$repo")

                # Scan user basename patterns
                while IFS= read -r pattern; do
                    [[ -z "$pattern" ]] && continue
                    while IFS= read -r -d '' match; do
                        local rel_path="${match#$repo/}"
                        echo "  🔒 $rel_path"
                        repo_files=$((repo_files + 1))
                    done < <(find "$repo" -maxdepth "$max_depth" -type f $(get_find_case_args) "$pattern" -print0 2>/dev/null)
                done < <(get_user_exclusion_patterns "$repo")

                while IFS= read -r pattern; do
                    [[ -z "$pattern" ]] && continue
                    while IFS= read -r -d '' match; do
                        local rel_path="${match#$repo/}"
                        echo "  📁 $rel_path/"
                        repo_dirs=$((repo_dirs + 1))
                    done < <(find "$repo" -maxdepth "$max_depth" -type d $(get_find_case_args) "$pattern" -print0 2>/dev/null)
                done < <(get_user_exclusion_dirs "$repo")
            fi

            if [[ $repo_files -eq 0 && $repo_dirs -eq 0 ]]; then
                echo "  (no excluded files found)"
            else
                print_info "  Repo excluded: $repo_files files, $repo_dirs directories"
            fi
            ws_total_files=$((ws_total_files + repo_files))
            ws_total_dirs=$((ws_total_dirs + repo_dirs))
        done

        echo ""
        echo "============================================="
        print_info "Workspace total: root + ${#_WS_REPOS[@]} repos"
        print_info "  Root: $excluded_files_count files, $excluded_dirs_count directories"
        print_info "  Repos: $ws_total_files files, $ws_total_dirs directories"
    fi

    print_git_history_warning "$project_path"
}

# Test exclusions and show Docker volume arguments
exclusions_test() {
    local project_path
    project_path=$(get_project_path "$1")

    print_workspace_info_header "$project_path"

    print_header "🧪 Testing exclusions for: $project_path"
    echo "=============================================="
    
    if [[ "$ENABLE_MOUNT_EXCLUSIONS" != "true" ]]; then
        print_info "Exclusions disabled - all files would be mounted normally"
        echo ""
        echo "Would use simple mount:"
        echo "  -v $project_path:/workspace:rw"
        return 0
    fi
    
    # Show what would happen
    echo "Docker volume arguments that would be generated:"
    echo ""
    
    # Create volume args to test
    create_volume_args "$project_path" "/workspace"
    
    if [[ ${#VOLUME_ARGS[@]} -gt 0 ]]; then
        local i=0
        while [[ $i -lt ${#VOLUME_ARGS[@]} ]]; do
            if [[ "${VOLUME_ARGS[$i]}" == "-v" ]]; then
                local mount_arg="${VOLUME_ARGS[$((i+1))]}"
                if [[ "$mount_arg" == *"/tmp/nyia-excluded-"* ]]; then
                    echo "  -v $mount_arg  # 🔒 EXCLUDED"
                else
                    echo "  -v $mount_arg"
                fi
                i=$((i + 2))
            else
                echo "  ${VOLUME_ARGS[$i]}"
                i=$((i + 1))
            fi
        done
    else
        echo "  No volume arguments generated"
    fi
    
    echo ""
    print_success "Test complete - sensitive files would be replaced with explanations"

    # Workspace mode: also test workspace volume args
    local _WS_REPOS _WS_MODES
    get_workspace_repos_for_exclusions "$project_path"
    if [[ ${#_WS_REPOS[@]} -gt 0 ]] && declare -f build_workspace_volume_args >/dev/null 2>&1; then
        echo ""
        print_header "🧪 Workspace volume arguments (full workspace simulation)"
        echo "============================================================"
        echo ""

        # Reset VOLUME_ARGS and call the workspace builder (matches launch-time flow)
        VOLUME_ARGS=()
        build_workspace_volume_args "$project_path" "/workspace" _WS_REPOS _WS_MODES

        if [[ ${#VOLUME_ARGS[@]} -gt 0 ]]; then
            local i=0
            while [[ $i -lt ${#VOLUME_ARGS[@]} ]]; do
                if [[ "${VOLUME_ARGS[$i]}" == "-v" ]]; then
                    local mount_arg="${VOLUME_ARGS[$((i+1))]}"
                    if [[ "$mount_arg" == *"/tmp/nyia-excluded-"* ]]; then
                        echo "  -v $mount_arg  # 🔒 EXCLUDED"
                    elif [[ "$mount_arg" == *"tmpfs"* ]] || [[ "${VOLUME_ARGS[$i]}" == "--tmpfs" ]]; then
                        echo "  -v $mount_arg  # tmpfs"
                    else
                        echo "  -v $mount_arg"
                    fi
                    i=$((i + 2))
                elif [[ "${VOLUME_ARGS[$i]}" == "--tmpfs" ]]; then
                    echo "  --tmpfs ${VOLUME_ARGS[$((i+1))]}"
                    i=$((i + 2))
                else
                    echo "  ${VOLUME_ARGS[$i]}"
                    i=$((i + 1))
                fi
            done
        else
            echo "  No workspace volume arguments generated"
        fi
        echo ""
        print_success "Workspace test complete"
    fi

    print_git_history_warning "$project_path"
}

# Show exclusions status
exclusions_status() {
    local project_path
    project_path=$(get_project_path "$1")

    print_workspace_info_header "$project_path"

    print_header "🔍 Mount Exclusions Status"
    echo "=========================="
    echo ""
    echo "Global Settings:"
    echo "  Feature enabled: ${ENABLE_MOUNT_EXCLUSIONS:-true}"
    echo "  Config file: $(get_nyiakeeper_home)/config/mount-exclusions.conf"
    echo ""
    
    echo "Current Status:"
    if [[ "$ENABLE_MOUNT_EXCLUSIONS" != "true" ]]; then
        echo "  🔴 DISABLED - No files will be excluded"
    else
        echo "  🟢 ENABLED - Sensitive files will be excluded"
    fi
    echo ""
    
    echo "Project Path: $project_path"
    local project_exclusions="$project_path/.nyiakeeper/exclusions.conf"
    if [[ -f "$project_exclusions" ]]; then
        echo "  📄 Has project-specific exclusions: $project_exclusions"
    else
        echo "  📍 Using global exclusion patterns only"
    fi
    echo ""
    
    echo "To disable temporarily:"
    echo "  ENABLE_MOUNT_EXCLUSIONS=false nyia-claude \"your prompt\""
    echo "  Or use: nyia-claude --disable-exclusions \"your prompt\""

    # Workspace mode: show per-repo config status
    local _WS_REPOS _WS_MODES
    get_workspace_repos_for_exclusions "$project_path"
    if [[ ${#_WS_REPOS[@]} -gt 0 ]]; then
        echo ""
        echo "Workspace Repositories:"
        local ri
        for ((ri=0; ri<${#_WS_REPOS[@]}; ri++)); do
            local repo="${_WS_REPOS[ri]}"
            local mode="${_WS_MODES[ri]:-rw}"
            local repo_name
            repo_name=$(basename "$repo")
            local repo_conf="$repo/.nyiakeeper/exclusions.conf"
            if [[ -f "$repo_conf" ]]; then
                local pat_count
                pat_count=$(grep -v '^#' "$repo_conf" 2>/dev/null | grep -v '^[[:space:]]*$' | grep -v '^[[:space:]]*!' | wc -l)
                local ovr_count
                ovr_count=$(grep -v '^#' "$repo_conf" 2>/dev/null | grep -v '^[[:space:]]*$' | grep -c '^[[:space:]]*!' || true)
                echo "  📄 $repo_name ($repo) [$mode] — $pat_count patterns, $ovr_count overrides"
            else
                echo "  📍 $repo_name ($repo) [$mode] — no exclusions.conf (built-in only)"
            fi
        done
    fi

    print_git_history_warning "$project_path"
}

# Show all exclusion patterns
exclusions_patterns() {
    local project_path
    project_path=$(get_project_path "${1:-}")

    print_workspace_info_header "$project_path"
    print_header "🔍 Exclusion Patterns"
    echo "==============================="
    echo ""
    echo "Built-in file patterns (basename — match anywhere):"
    echo "$(get_exclusion_patterns "$project_path")" | tr ' ' '\n' | sort | sed 's/^/  • /'
    echo ""
    echo "Built-in directory patterns (basename — match anywhere):"
    echo "$(get_exclusion_dirs "$project_path")" | tr ' ' '\n' | sort | sed 's/^/  • /'

    # Show user-defined patterns with anchoring info using the classifier
    local exclusions_file="$project_path/.nyiakeeper/exclusions.conf"
    if [[ -f "$exclusions_file" ]]; then
        local has_user_patterns="false"
        local has_user_overrides="false"
        local user_lines=""
        local override_lines=""

        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            line=$(echo "$line" | xargs)
            [[ -z "$line" ]] && continue

            local classified
            classified=$(classify_user_pattern "$line")
            local strategy="${classified%%:*}"
            local rest="${classified#*:}"
            local is_dir="${rest%%:*}"
            rest="${rest#*:}"
            local is_negation="${rest%%:*}"
            local cleaned="${rest#*:}"

            # Build display suffix
            local dir_suffix=""
            [[ "$is_dir" == "true" ]] && dir_suffix="/"
            local anchor_label=""
            if [[ "$strategy" == "root-anchored" ]]; then
                # Check if user explicitly anchored with leading /
                local raw_no_neg="$line"
                [[ "$raw_no_neg" == "!"* ]] && raw_no_neg="${raw_no_neg#!}"
                [[ "$raw_no_neg" == */ ]] && raw_no_neg="${raw_no_neg%/}"
                if [[ "$raw_no_neg" == "/"* ]]; then
                    anchor_label="root-anchored"
                else
                    # Implicitly root-anchored because it contains /
                    anchor_label="root-anchored — use **/${cleaned}${dir_suffix} to match anywhere"
                fi
            else
                anchor_label="anywhere"
            fi

            if [[ "$is_negation" == "true" ]]; then
                has_user_overrides="true"
                override_lines="${override_lines}  • !${cleaned}${dir_suffix} (${anchor_label})\n"
            else
                has_user_patterns="true"
                user_lines="${user_lines}  • ${cleaned}${dir_suffix} (${anchor_label})\n"
            fi
        done < "$exclusions_file"

        if [[ "$has_user_patterns" == "true" ]]; then
            echo ""
            echo "User-defined patterns (from exclusions.conf):"
            echo -e "$user_lines" | sort | head -n -1
        fi

        if [[ "$has_user_overrides" == "true" ]]; then
            echo ""
            echo "User-defined overrides (force-include):"
            echo -e "$override_lines" | sort | head -n -1
        fi
    fi

    # Workspace mode: show per-repo user patterns
    local _WS_REPOS _WS_MODES
    get_workspace_repos_for_exclusions "$project_path"
    if [[ ${#_WS_REPOS[@]} -gt 0 ]]; then
        local ri
        for ((ri=0; ri<${#_WS_REPOS[@]}; ri++)); do
            local repo="${_WS_REPOS[ri]}"
            local mode="${_WS_MODES[ri]:-rw}"
            local repo_name
            repo_name=$(basename "$repo")
            local repo_conf="$repo/.nyiakeeper/exclusions.conf"
            if [[ -f "$repo_conf" ]]; then
                echo ""
                echo "Repo: $repo_name ($repo) [$mode] — user patterns:"
                while IFS= read -r line; do
                    [[ -z "$line" ]] && continue
                    [[ "$line" =~ ^[[:space:]]*# ]] && continue
                    line=$(echo "$line" | xargs)
                    [[ -z "$line" ]] && continue
                    local classified
                    classified=$(classify_user_pattern "$line")
                    local strategy="${classified%%:*}"
                    local anchor_label="anywhere"
                    [[ "$strategy" == "root-anchored" ]] && anchor_label="root-anchored"
                    echo "  • $line ($anchor_label)"
                done < "$repo_conf"
            fi
        done
    fi

    echo ""
    print_info "Built-in patterns are hardcoded for security"
    print_info "Pattern rules: no '/' = anywhere, contains '/' = root-anchored"
    print_info "To override: use .nyiakeeper/exclusions.conf with ! prefix"

    print_git_history_warning "$project_path"
}

# Initialize project-specific exclusions config
exclusions_init() {
    local project_path=""
    local force_mode="false"
    local all_mode="false"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force)
                force_mode="true"
                shift
                ;;
            --all)
                all_mode="true"
                shift
                ;;
            *)
                if [[ -z "$project_path" ]]; then
                    project_path="$1"
                fi
                shift
                ;;
        esac
    done

    # Get validated project path
    project_path=$(get_project_path "$project_path")

    # Workspace --all mode: init all repos that lack exclusions.conf
    if [[ "$all_mode" == "true" ]]; then
        local _WS_REPOS _WS_MODES
        get_workspace_repos_for_exclusions "$project_path"
        if [[ ${#_WS_REPOS[@]} -eq 0 ]]; then
            print_info "Not a workspace — use 'nyia exclusions init' without --all"
            return 0
        fi
        # Init root if needed
        exclusions_init "$project_path"
        # Init each repo
        local ri
        for ((ri=0; ri<${#_WS_REPOS[@]}; ri++)); do
            local repo="${_WS_REPOS[ri]}"
            [[ ! -d "$repo" ]] && continue
            echo ""
            exclusions_init "$repo"
        done
        return 0
    fi

    # Workspace summary mode: no explicit path, workspace detected, show status table
    local _WS_REPOS _WS_MODES
    get_workspace_repos_for_exclusions "$project_path"
    if [[ ${#_WS_REPOS[@]} -gt 0 ]] && [[ -f "$project_path/.nyiakeeper/exclusions.conf" ]] && [[ "$force_mode" != "true" ]]; then
        print_info "Workspace exclusions summary:"
        echo ""
        echo "  Root: $project_path"
        local root_conf="$project_path/.nyiakeeper/exclusions.conf"
        local root_pats
        root_pats=$(grep -v '^#' "$root_conf" 2>/dev/null | grep -v '^[[:space:]]*$' | grep -v '^[[:space:]]*!' | wc -l)
        echo "    📄 exclusions.conf — $root_pats patterns"
        echo ""
        local ri
        for ((ri=0; ri<${#_WS_REPOS[@]}; ri++)); do
            local repo="${_WS_REPOS[ri]}"
            local mode="${_WS_MODES[ri]:-rw}"
            local repo_name
            repo_name=$(basename "$repo")
            local repo_conf="$repo/.nyiakeeper/exclusions.conf"
            if [[ -f "$repo_conf" ]]; then
                local pat_count
                pat_count=$(grep -v '^#' "$repo_conf" 2>/dev/null | grep -v '^[[:space:]]*$' | grep -v '^[[:space:]]*!' | wc -l)
                echo "  📄 $repo_name ($repo) [$mode] — $pat_count patterns"
            else
                echo "  📍 $repo_name ($repo) [$mode] — no config (built-in only)"
            fi
        done
        echo ""
        echo "Use 'nyia exclusions init <repo-path>' to init a specific repo"
        echo "Use 'nyia exclusions init --all' to init all repos at once"
        return 0
    fi
    local nyia_dir="$project_path/.nyiakeeper"
    local exclusions_file="$nyia_dir/exclusions.conf"
    
    # If file exists and not forcing, show status (Git/Terraform style)
    if [[ -f "$exclusions_file" ]] && [[ "$force_mode" != "true" ]]; then
        print_info "Exclusions already initialized"
        echo "Current config: .nyiakeeper/exclusions.conf"
        
        # Count user-defined patterns (exclude ! override lines from pattern count)
        local user_pattern_count=$(grep -v '^#' "$exclusions_file" 2>/dev/null | grep -v '^[[:space:]]*$' | grep -v '^[[:space:]]*!' | wc -l)
        local user_override_count=$(grep -v '^#' "$exclusions_file" 2>/dev/null | grep -v '^[[:space:]]*$' | grep -c '^[[:space:]]*!' || true)
        if [[ "$user_override_count" -gt 0 ]]; then
            echo "User-defined patterns: $user_pattern_count (+$user_override_count overrides)"
        else
            echo "User-defined patterns: $user_pattern_count"
        fi
        
        # Show actual exclusion effectiveness with quick scan and change detection
        echo ""
        echo "Current exclusion status:"
        
        local excluded_files=0
        local excluded_dirs=0
        
        # Use cached results from complete scan if available (most accurate)
        local main_cache_file="$nyia_dir/.excluded-files.cache"
        if [[ -f "$main_cache_file" ]]; then
            # Read from main cache written by complete scan
            while IFS='=' read -r key value; do
                case "$key" in
                    excluded_files)
                        # Count comma-separated entries
                        if [[ -n "$value" ]]; then
                            excluded_files=$(echo "$value" | tr ',' '\n' | grep -c '^.')
                        fi
                        ;;
                    excluded_dirs)
                        # Count comma-separated entries
                        if [[ -n "$value" ]]; then
                            excluded_dirs=$(echo "$value" | tr ',' '\n' | grep -c '^.')
                        fi
                        ;;
                esac
            done < "$main_cache_file"
        else
            # Fallback: quick scan for most common patterns only (cache not available)
            local max_depth=3
            local common_patterns=(".env" "*.key" "*.pem" "credentials.*" "*.tfstate" "*.tfvars")
            for pattern in "${common_patterns[@]}"; do
                local count=$(find "$project_path" -maxdepth "$max_depth" -type f $(get_find_case_args) "$pattern" 2>/dev/null | wc -l)
                excluded_files=$((excluded_files + count))
            done
            
            local common_dirs=(".aws" ".ssh" ".terraform" "secrets")
            for pattern in "${common_dirs[@]}"; do
                local count=$(find "$project_path" -maxdepth "$max_depth" -type d $(get_find_case_args) "$pattern" 2>/dev/null | wc -l)
                excluded_dirs=$((excluded_dirs + count))
            done
        fi
        
        # Read cached counts from previous scan
        local cache_file="$nyia_dir/.exclusions-cache"
        local cached_files=0
        local cached_dirs=0
        if [[ -f "$cache_file" ]]; then
            while IFS='=' read -r key value; do
                case "$key" in
                    files) cached_files="$value" ;;
                    dirs) cached_dirs="$value" ;;
                esac
            done < "$cache_file"
        fi
        
        if [[ $excluded_files -gt 0 || $excluded_dirs -gt 0 ]]; then
            print_success "Currently protecting $excluded_files+ sensitive files, $excluded_dirs+ directories"
        else
            print_info "No common sensitive files detected - your project looks secure!"
            echo "System actively scans for 200+ sensitive file patterns"
        fi
        
        # Show changes since last scan
        local files_delta=$((excluded_files - cached_files))
        local dirs_delta=$((excluded_dirs - cached_dirs))
        
        if [[ $files_delta -gt 0 || $dirs_delta -gt 0 ]]; then
            local change_msg=""
            if [[ $files_delta -gt 0 && $dirs_delta -gt 0 ]]; then
                change_msg="Detected $files_delta new files, $dirs_delta new directories since last scan"
            elif [[ $files_delta -gt 0 ]]; then
                if [[ $files_delta -eq 1 ]]; then
                    change_msg="Detected 1 new sensitive file since last scan"
                else
                    change_msg="Detected $files_delta new sensitive files since last scan"
                fi
            elif [[ $dirs_delta -gt 0 ]]; then
                if [[ $dirs_delta -eq 1 ]]; then
                    change_msg="Detected 1 new sensitive directory since last scan"
                else
                    change_msg="Detected $dirs_delta new sensitive directories since last scan"
                fi
            fi
            echo "$change_msg"
        elif [[ $files_delta -lt 0 || $dirs_delta -lt 0 ]]; then
            local removed_files=$((cached_files - excluded_files))
            local removed_dirs=$((cached_dirs - excluded_dirs))
            if [[ $removed_files -gt 0 || $removed_dirs -gt 0 ]]; then
                local removed_msg=""
                if [[ $removed_files -gt 0 && $removed_dirs -gt 0 ]]; then
                    removed_msg="$removed_files files, $removed_dirs directories were removed since last scan"
                elif [[ $removed_files -gt 0 ]]; then
                    if [[ $removed_files -eq 1 ]]; then
                        removed_msg="1 sensitive file was removed since last scan"
                    else
                        removed_msg="$removed_files sensitive files were removed since last scan"
                    fi
                elif [[ $removed_dirs -gt 0 ]]; then
                    if [[ $removed_dirs -eq 1 ]]; then
                        removed_msg="1 sensitive directory was removed since last scan"
                    else
                        removed_msg="$removed_dirs sensitive directories were removed since last scan"
                    fi
                fi
                echo "$removed_msg"
            fi
        elif [[ $cached_files -gt 0 || $cached_dirs -gt 0 ]]; then
            echo "No changes since last scan"
        fi
        
        # Update cache with current counts
        cat > "$cache_file" << EOF
files=$excluded_files
dirs=$excluded_dirs
timestamp=$(date +%s)
EOF
        
        echo ""
        echo "Use 'nyia exclusions init --force' to recreate with fresh template"
        echo "Use 'nyia exclusions list' to see all protected files"
        return 0
    fi
    
    # If forcing and file exists, backup first and capture current state
    local old_excluded_files=0
    local old_excluded_dirs=0
    if [[ -f "$exclusions_file" ]] && [[ "$force_mode" == "true" ]]; then
        # Capture current protection state before backup
        local max_depth=3
        local common_patterns=(".env" "*.key" "*.pem" "credentials.*" "*.tfstate" "*.tfvars")
        for pattern in "${common_patterns[@]}"; do
            local count=$(find "$project_path" -maxdepth "$max_depth" -type f -name "$pattern" 2>/dev/null | wc -l)
            old_excluded_files=$((old_excluded_files + count))
        done
        
        local common_dirs=(".aws" ".ssh" ".terraform" "secrets")
        for pattern in "${common_dirs[@]}"; do
            local count=$(find "$project_path" -maxdepth "$max_depth" -type d -name "$pattern" 2>/dev/null | wc -l)
            old_excluded_dirs=$((old_excluded_dirs + count))
        done
        
        local backup_file="${exclusions_file}.backup"
        cp "$exclusions_file" "$backup_file"
        print_info "⚠️  Backing up existing config to $(basename "$backup_file")"
    fi
    
    print_header "🚀 Initializing project exclusions"
    echo "=================================="
    echo "Project: $project_path"
    echo ""
    
    # Create .nyiakeeper directory if needed
    if [[ ! -d "$nyia_dir" ]]; then
        mkdir -p "$nyia_dir"
        print_success "Created .nyiakeeper directory"
    fi
    
    # Create exclusions.conf (always if forcing or doesn't exist)
    if [[ ! -f "$exclusions_file" ]] || [[ "$force_mode" == "true" ]]; then
        cat > "$exclusions_file" << 'EOF'
# Nyia Keeper Mount Exclusions Configuration
# Project-specific patterns to exclude from Docker mounts
#
# Pattern matching follows gitignore conventions:
#
#   .env                   # Matches .env ANYWHERE in the tree (no path separator)
#   secrets/               # Matches any directory named 'secrets' anywhere
#   *.backup               # Matches by extension anywhere (glob)
#   config/database.yml    # Matches ONLY at project root (has path separator)
#   /src/                  # Matches ONLY root-level src/ (leading /)
#   **/node_modules/       # Matches node_modules/ ANYWHERE (explicit **/  prefix)
#
# Override global exclusions with ! prefix (same anchoring rules apply):
#   !.env.example          # Force include anywhere (basename)
#   !config/database.yml   # Force include at root only (root-anchored)
#   !**/vendor/            # Force include anywhere (explicit)
#
# Key rules:
#   - No '/' in pattern  → matches anywhere (basename matching)
#   - Contains '/'       → anchored to project root
#   - Leading '/'        → explicitly root-anchored
#   - '**/' prefix       → explicitly match anywhere
#   - Trailing '/'       → directory only
#   - '#' at line start  → comment
#
# Note: Built-in security patterns (200+) are always applied first.
# This file adds additional project-specific exclusions.

# Your project-specific exclusions:

EOF
        if [[ "$force_mode" == "true" ]]; then
            print_success "Created fresh exclusions config: .nyiakeeper/exclusions.conf"
        else
            print_success "Created exclusions config: .nyiakeeper/exclusions.conf"
        fi
        
        # Show immediate value - use cached results from complete scan
        echo ""
        echo "Scanning project for sensitive files..."
        
        local excluded_files=0
        local excluded_dirs=0
        
        # Use cached results from the complete scan (most accurate)
        local main_cache_file="$nyia_dir/.excluded-files.cache"
        if [[ -f "$main_cache_file" ]]; then
            # Read from main cache written by complete scan
            while IFS='=' read -r key value; do
                case "$key" in
                    excluded_files)
                        # Count comma-separated entries
                        if [[ -n "$value" ]]; then
                            excluded_files=$(echo "$value" | tr ',' '\n' | grep -c '^.')
                        fi
                        ;;
                    excluded_dirs)
                        # Count comma-separated entries
                        if [[ -n "$value" ]]; then
                            excluded_dirs=$(echo "$value" | tr ',' '\n' | grep -c '^.')
                        fi
                        ;;
                esac
            done < "$main_cache_file"
        else
            # Fallback: quick scan for most common patterns only (cache not available)
            local max_depth=3
            local common_patterns=(".env" "*.key" "*.pem" "credentials.*" "*.tfstate" "*.tfvars")
            for pattern in "${common_patterns[@]}"; do
                local count=$(find "$project_path" -maxdepth "$max_depth" -type f $(get_find_case_args) "$pattern" 2>/dev/null | wc -l)
                excluded_files=$((excluded_files + count))
            done
            
            local common_dirs=(".aws" ".ssh" ".terraform" "secrets")
            for pattern in "${common_dirs[@]}"; do
                local count=$(find "$project_path" -maxdepth "$max_depth" -type d $(get_find_case_args) "$pattern" 2>/dev/null | wc -l)
                excluded_dirs=$((excluded_dirs + count))
            done
        fi
        
        # Calculate and show the delta for what was added
        local added_files=$((excluded_files - old_excluded_files))
        local added_dirs=$((excluded_dirs - old_excluded_dirs))
        
        if [[ $excluded_files -gt 0 || $excluded_dirs -gt 0 ]]; then
            print_success "🛡️  Now protecting $excluded_files+ sensitive files, $excluded_dirs+ directories"
            echo "Run 'nyia exclusions list' to see all protected files"
        else
            print_info "No common sensitive files detected - your project looks secure!"
            echo "The system protects against 200+ sensitive file patterns automatically"
        fi
        
        # Show what was added (delta) - only for first-time init, not --force
        if [[ "$force_mode" != "true" ]]; then
            if [[ $added_files -gt 0 || $added_dirs -gt 0 ]]; then
                local added_msg=""
                if [[ $added_files -gt 0 && $added_dirs -gt 0 ]]; then
                    added_msg="Added $added_files files, $added_dirs directories to protection"
                elif [[ $added_files -gt 0 ]]; then
                    if [[ $added_files -eq 1 ]]; then
                        added_msg="Added 1 file to protection"
                    else
                        added_msg="Added $added_files files to protection"
                    fi
                elif [[ $added_dirs -gt 0 ]]; then
                    if [[ $added_dirs -eq 1 ]]; then
                        added_msg="Added 1 directory to protection"
                    else
                        added_msg="Added $added_dirs directories to protection"
                    fi
                fi
                echo "$added_msg"
            fi
        fi
        
        # Update simple cache with current counts for future change detection
        local simple_cache_file="$nyia_dir/.exclusions-cache"
        cat > "$simple_cache_file" << EOF
files=$excluded_files
dirs=$excluded_dirs
timestamp=$(date +%s)
EOF
        
        echo ""
        echo "Next steps:"
        echo "  1. Run 'nyia exclusions list' to see all protected files"
        echo "  2. Edit .nyiakeeper/exclusions.conf to add project-specific patterns"
        echo "  3. Run 'nyia exclusions test' to verify exclusions work"
    fi
}

# === LOCKDOWN COMMAND ===

# Directories to skip during lockdown scan (infrastructure, not project content)
_LOCKDOWN_SKIP_DIRS=(".git" ".nyiakeeper" "node_modules" "__pycache__" ".venv" ".tox")

# Known-safe directories (auto-whitelisted with !)
_LOCKDOWN_SAFE_DIRS=(
    # Source
    "src" "lib" "app" "cmd" "pkg" "internal"
    # Tests
    "tests" "test" "spec" "__tests__"
    # Docs
    "docs" "doc"
    # Config dirs
    "scripts" "bin" "tools"
)

# Known-safe files (auto-whitelisted with !)
_LOCKDOWN_SAFE_FILES=(
    "README.md" "README.rst" "README.txt" "readme.md"
    "LICENSE" "LICENSE.md" "LICENSE.txt" "license"
    "CHANGELOG.md" "CHANGES.md"
    "Makefile" "Dockerfile"
    "docker-compose.yml" "docker-compose.yaml"
    ".gitignore" ".dockerignore" ".editorconfig"
    "package.json" "package-lock.json"
    "Cargo.toml" "Cargo.lock"
    "go.mod" "go.sum"
    "pyproject.toml" "setup.py" "setup.cfg" "requirements.txt"
    "Gemfile" "Gemfile.lock"
    "tsconfig.json" "webpack.config.js" "vite.config.ts" "vite.config.js"
    "composer.json" "composer.lock"
)

# Check if an entry is in the skip list
_is_lockdown_skip() {
    local name="$1"
    local skip
    for skip in "${_LOCKDOWN_SKIP_DIRS[@]}"; do
        [[ "$name" == "$skip" ]] && return 0
    done
    return 1
}

# Check if a directory name is in the safe whitelist
_is_safe_dir() {
    local name="$1"
    local safe
    for safe in "${_LOCKDOWN_SAFE_DIRS[@]}"; do
        [[ "$name" == "$safe" ]] && return 0
    done
    return 1
}

# Check if a file name is in the safe whitelist (case-insensitive for README/LICENSE)
_is_safe_file() {
    local name="$1"
    local name_lower
    name_lower=$(echo "$name" | tr '[:upper:]' '[:lower:]')
    local safe safe_lower
    for safe in "${_LOCKDOWN_SAFE_FILES[@]}"; do
        safe_lower=$(echo "$safe" | tr '[:upper:]' '[:lower:]')
        [[ "$name_lower" == "$safe_lower" ]] && return 0
    done
    return 1
}

# Scan project root for lockdown (depth 1 only)
# Sets: _LOCKDOWN_DIRS, _LOCKDOWN_FILES arrays
scan_project_for_lockdown() {
    local project_path="$1"
    _LOCKDOWN_DIRS=()
    _LOCKDOWN_FILES=()

    local project_name
    project_name=$(basename "$project_path")
    echo "Scanning $project_name..."

    local entry name
    for entry in "$project_path"/*; do
        [[ -e "$entry" ]] || continue
        name=$(basename "$entry")
        if [[ -d "$entry" ]]; then
            _is_lockdown_skip "$name" && continue
            _LOCKDOWN_DIRS+=("$name")
        elif [[ -f "$entry" ]]; then
            _LOCKDOWN_FILES+=("$name")
        fi
    done

    # Also check dotfiles at root (except skip list)
    for entry in "$project_path"/.[!.]*; do
        [[ -e "$entry" ]] || continue
        name=$(basename "$entry")
        if [[ -d "$entry" ]]; then
            _is_lockdown_skip "$name" && continue
            _LOCKDOWN_DIRS+=("$name")
        elif [[ -f "$entry" ]]; then
            _LOCKDOWN_FILES+=("$name")
        fi
    done

    echo "  Found ${#_LOCKDOWN_DIRS[@]} directories, ${#_LOCKDOWN_FILES[@]} files"
}

# Check workspace gate for write commands
# Returns 0 if allowed to proceed, 1 if blocked
check_workspace_gate() {
    local project_path="$1"
    local workspace_flag="${2:-false}"

    local _WS_REPOS _WS_MODES
    get_workspace_repos_for_exclusions "$project_path"

    # Not a workspace — always allow
    [[ ${#_WS_REPOS[@]} -eq 0 ]] && return 0

    # Workspace with --workspace flag — allow
    [[ "$workspace_flag" == "true" ]] && return 0

    # Workspace without flag — block with helpful message
    local repo_count=${#_WS_REPOS[@]}
    echo ""
    echo "  Workspace detected with $repo_count repos:"
    local ri
    for ((ri=0; ri<${#_WS_REPOS[@]}; ri++)); do
        local repo_name
        repo_name=$(basename "${_WS_REPOS[ri]}")
        local mode="${_WS_MODES[ri]:-rw}"
        echo "    - $repo_name (${_WS_REPOS[ri]}) [$mode]"
    done
    echo ""
    echo "  Add --workspace to lockdown all RW repos, or specify a single repo path:"
    echo "    nyia exclusions lockdown --workspace"
    echo "    nyia exclusions lockdown <repo-path>"
    echo ""
    return 1
}

# Print workspace info header for read commands
print_workspace_info_header() {
    local project_path="$1"

    local _WS_REPOS _WS_MODES
    get_workspace_repos_for_exclusions "$project_path"

    [[ ${#_WS_REPOS[@]} -eq 0 ]] && return 0

    echo "Workspace: ${#_WS_REPOS[@]} repos"
    local ri
    for ((ri=0; ri<${#_WS_REPOS[@]}; ri++)); do
        echo "  $(basename "${_WS_REPOS[ri]}") (${_WS_REPOS[ri]}) [${_WS_MODES[ri]:-rw}]"
    done
}

# Generate lockdown exclusions.conf for a single project
_generate_lockdown_config() {
    local project_path="$1"
    local force_mode="${2:-false}"
    local nyia_dir="$project_path/.nyiakeeper"
    local exclusions_file="$nyia_dir/exclusions.conf"

    # Ensure .nyiakeeper dir exists
    mkdir -p "$nyia_dir"

    # Backup existing file if --force
    if [[ -f "$exclusions_file" ]] && [[ "$force_mode" == "true" ]]; then
        local backup="$exclusions_file.bak.$(date +%Y%m%d%H%M%S)"
        cp "$exclusions_file" "$backup"
        print_info "Backed up existing config to $(basename "$backup")"
    elif [[ -f "$exclusions_file" ]] && [[ "$force_mode" != "true" ]]; then
        print_info "Config already exists: .nyiakeeper/exclusions.conf (use --force to overwrite)"
        return 0
    fi

    # Scan project
    scan_project_for_lockdown "$project_path"

    # Build the config file
    local config=""
    local today
    today=$(date +%Y-%m-%d)

    # Header
    config+="# Nyia Keeper Exclusions — Generated by: nyia exclusions lockdown
# Date: $today
#
# IMPORTANT: Mount exclusions protect the filesystem inside the container,
# but files committed to git history remain accessible via git commands
# (git show, git log -p, git cat-file, etc.).
# See: docs/MOUNT_EXCLUSIONS.md — Git History Protection
#
# .git/ is mounted read-write for git operations.
# Git history of excluded files may still be accessible.
#
# Review the ! overrides below and remove any that should stay excluded.
"

    # Section 1: Excluded directories
    config+="
# Excluded directories
"
    local dir
    for dir in "${_LOCKDOWN_DIRS[@]}"; do
        config+="/$dir/
"
    done

    # Section 2: Excluded files
    config+="
# Excluded files
"
    local file
    for file in "${_LOCKDOWN_FILES[@]}"; do
        config+="/$file
"
    done

    # Section 3: Auto-whitelisted safe entries
    config+="
# Auto-whitelisted (safe for AI access)
# Review these overrides — remove any line to keep that entry excluded.
"
    local whitelist_count=0

    for dir in "${_LOCKDOWN_DIRS[@]}"; do
        if _is_safe_dir "$dir"; then
            config+="!/$dir/
"
            whitelist_count=$((whitelist_count + 1))
        fi
    done

    for file in "${_LOCKDOWN_FILES[@]}"; do
        if _is_safe_file "$file"; then
            config+="!/$file
"
            whitelist_count=$((whitelist_count + 1))
        fi
    done

    # Write the config
    echo -n "$config" > "$exclusions_file"

    # Print summary
    local total_excluded=$(( ${#_LOCKDOWN_DIRS[@]} + ${#_LOCKDOWN_FILES[@]} ))
    local project_name
    project_name=$(basename "$project_path")

    echo ""
    print_success "Lockdown complete for $project_name"
    echo "  ${#_LOCKDOWN_DIRS[@]} directories excluded, ${#_LOCKDOWN_FILES[@]} files excluded"
    echo "  $whitelist_count entries auto-whitelisted (review ! overrides in .nyiakeeper/exclusions.conf)"
    echo "  Run 'nyia exclusions list' to see what's actually excluded"
}

# Main lockdown command
exclusions_lockdown() {
    local project_path=""
    local force_mode="false"
    local workspace_flag="false"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force)
                force_mode="true"
                shift
                ;;
            --workspace)
                workspace_flag="true"
                shift
                ;;
            *)
                if [[ -z "$project_path" ]]; then
                    project_path="$1"
                fi
                shift
                ;;
        esac
    done

    # Get validated project path
    project_path=$(get_project_path "$project_path")

    # Workspace gate check
    if ! check_workspace_gate "$project_path" "$workspace_flag"; then
        return 1
    fi

    # Workspace mode: iterate RW repos
    local _WS_REPOS _WS_MODES
    get_workspace_repos_for_exclusions "$project_path"
    if [[ ${#_WS_REPOS[@]} -gt 0 ]] && [[ "$workspace_flag" == "true" ]]; then
        # Lockdown root project
        _generate_lockdown_config "$project_path" "$force_mode"

        # Lockdown each RW repo
        local ri
        for ((ri=0; ri<${#_WS_REPOS[@]}; ri++)); do
            local repo="${_WS_REPOS[ri]}"
            local mode="${_WS_MODES[ri]:-rw}"
            local repo_name
            repo_name=$(basename "$repo")

            [[ ! -d "$repo" ]] && continue

            if [[ "$mode" == "ro" ]]; then
                echo ""
                print_info "Skipping $repo_name ($repo) [ro]"
                continue
            fi

            echo ""
            _generate_lockdown_config "$repo" "$force_mode"
        done
        return 0
    fi

    # Single project mode
    _generate_lockdown_config "$project_path" "$force_mode"
}

# Print git history warning footer for git-backed projects
print_git_history_warning() {
    local project_path="$1"
    if git -C "$project_path" rev-parse --git-dir >/dev/null 2>&1; then
        echo ""
        echo "Note: Files in git history may still be accessible via git commands."
        echo "See: docs/MOUNT_EXCLUSIONS.md"
    fi
}

# Show help for exclusions commands
exclusions_help() {
    cat << 'EOF'
Nyia Keeper Mount Exclusions Management

Security feature that prevents sensitive files from being exposed to AI assistants
by replacing them with explanation files in Docker containers.

Usage:
  nyia exclusions <command> [path]           # Specify path as command argument
  nyia --path <path> exclusions <command>    # Specify path as global option

Commands:
  list [path]             Show files/dirs that would be excluded (per-repo in workspace)
  test [path]             Test exclusions and show Docker volume mounts
  status [path]           Show exclusion status for project (per-repo in workspace)
  patterns [path]         Show all exclusion patterns with anchoring info
  lockdown [path] [opts]  Generate exclude-everything config from project scan
  help                    Show this help message

Options:
  [path]              Project path (defaults to current directory)
  --path <path>       Project path as global option (before 'exclusions')
  --force             For lockdown: overwrite existing config (backs up first)
  --workspace         For lockdown: apply to all RW workspace repos

Examples:
  # Single project:
  nyia exclusions list              # List excluded files in current dir
  nyia exclusions status            # Check current project status
  nyia exclusions patterns          # Show patterns with anchoring info
  nyia exclusions lockdown          # Scan project, generate exclude-everything config
  nyia exclusions lockdown --force  # Overwrite existing config (backs up first)

  # Specify project path:
  nyia exclusions list ~/project
  nyia exclusions lockdown ~/project
  nyia --path ~/project exclusions status

  # Workspace mode (auto-detected from workspace.conf):
  nyia exclusions list              # Shows root + per-repo sections
  nyia exclusions status            # Shows per-repo config status
  nyia exclusions patterns          # Shows per-repo patterns
  nyia exclusions lockdown --workspace  # Lockdown all RW repos (skips RO)

Note: Built-in patterns auto-protect common sensitive files on every run.
      Use 'lockdown' when you want to exclude everything and whitelist manually.

Custom Exclusions:
  Add patterns to .nyiakeeper/exclusions.conf in your project.
  Pattern matching follows gitignore conventions:

    .env.local              # Basename: matches anywhere in tree
    secrets/                # Basename dir: any 'secrets/' anywhere
    *.backup                # Glob: by extension anywhere
    config/database.yml     # Root-anchored: only at project root (has /)
    /src/                   # Root-anchored: explicit leading /
    **/node_modules/        # Explicit anywhere: **/ prefix

  Override automatic exclusions with ! prefix (force-include):

    !.env.example           # Keep visible despite auto-exclusion
    !vendor/                # Keep directory visible

  Run 'nyia exclusions lockdown' to generate an exclude-everything config.
  Run 'nyia exclusions patterns' to see active patterns with anchoring info.
  See: docs/MOUNT_EXCLUSIONS.md for full documentation.

To disable exclusions temporarily:
  ENABLE_MOUNT_EXCLUSIONS=false nyia-claude "your prompt"
  Or use: nyia-claude --disable-exclusions "your prompt"

To disable globally:
  Edit $(get_nyiakeeper_home)/config/mount-exclusions.conf
  Set: ENABLE_MOUNT_EXCLUSIONS=false

EOF
}

# === DISPATCHER FUNCTION FOR RUNTIME ===
# This function is expected by the runtime dispatcher
handle_exclusions_command() {
    local subcommand="${1:-help}"
    shift || true
    
    case "$subcommand" in
        list)
            exclusions_list "$@"
            ;;
        test)
            exclusions_test "$@"
            ;;
        status)
            exclusions_status "$@"
            ;;
        patterns|pattern)
            exclusions_patterns "$@"
            ;;
        lockdown)
            exclusions_lockdown "$@"
            ;;
        help|--help|-h)
            exclusions_help
            ;;
        *)
            print_error "Unknown exclusions command: $subcommand"
            exclusions_help
            exit 1
            ;;
    esac
}