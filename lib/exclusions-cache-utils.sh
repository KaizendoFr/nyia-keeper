#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later OR Proprietary
# Copyright (c) 2024 Nyia Keeper Contributors
# Cache utilities for exclusions system
# Provides caching functionality to speed up repeated exclusion scans

# Cache TTL — bounded compromise between performance and freshness.
# Current invalidation only tracks exclusions.conf mtime, NOT new files on disk,
# so large values risk missing newly created sensitive files. Override with NYIA_CACHE_TTL.
CACHE_TTL="${NYIA_CACHE_TTL:-60}"

# Get exclusions config modification time
get_exclusions_config_mtime() {
    local project_path="$1"
    local conf_file="$project_path/.nyiakeeper/exclusions.conf"
    
    if [[ -f "$conf_file" ]]; then
        stat -c %Y "$conf_file" 2>/dev/null || stat -f %m "$conf_file" 2>/dev/null || echo 0
    else
        echo 0
    fi
}

# Check if exclusions cache is valid for a project
is_exclusions_cache_valid() {
    local project_path="$1"
    local cache_file="$project_path/.nyiakeeper/.excluded-files.cache"
    local cache_meta="$project_path/.nyiakeeper/.cache-meta"
    
    # Cache file must exist
    [[ -f "$cache_file" ]] || return 1

    # Plan 224: Validate cache key header (version + config content hash)
    if declare -f compute_cache_key >/dev/null 2>&1; then
        local expected_key
        expected_key=$(compute_cache_key "$project_path")
        local first_line
        first_line=$(head -n1 "$cache_file" 2>/dev/null)
        if [[ "$first_line" != "# EXCL_CACHE_V=$expected_key" ]]; then
            if declare -f print_verbose >/dev/null 2>&1; then
                print_verbose "Exclusions cache stale (version/config changed), rescanning"
            fi
            return 1
        fi
    fi

    # Check if config has changed (stored in meta file)
    if [[ -f "$cache_meta" ]]; then
        local stored_mtime
        stored_mtime=$(cat "$cache_meta" 2>/dev/null || echo 0)
        local current_mtime
        current_mtime=$(get_exclusions_config_mtime "$project_path")
        
        # If config modification time changed, cache is invalid
        if [[ "$stored_mtime" != "$current_mtime" ]]; then
            return 1
        fi
    fi
    
    # Age check (simple, works on both platforms)
    local cache_age=$(( $(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || echo 0) ))
    
    # Cache is valid if younger than TTL and config hasn't changed
    [[ $cache_age -lt $CACHE_TTL ]]
}

# Write exclusions to cache
write_exclusions_cache() {
    local project_path="$1"
    local cache_file="$project_path/.nyiakeeper/.excluded-files.cache"
    local cache_meta="$project_path/.nyiakeeper/.cache-meta"
    
    # Ensure .nyiakeeper directory exists
    local nyia_dir="$project_path/.nyiakeeper"
    [[ -d "$nyia_dir" ]] || mkdir -p "$nyia_dir"
    
    # Build comma-separated lists from associative arrays
    local excluded_files_list=""
    local excluded_dirs_list=""  
    local system_files_list=""
    local system_dirs_list=""
    
    # Convert excluded_files associative array to comma-separated list
    if [[ ${#excluded_files[@]} -gt 0 ]]; then
        excluded_files_list=$(printf "%s," "${!excluded_files[@]}")
        excluded_files_list="${excluded_files_list%,}"  # Remove trailing comma
    fi
    
    # Convert excluded_dirs associative array to comma-separated list
    if [[ ${#excluded_dirs[@]} -gt 0 ]]; then
        excluded_dirs_list=$(printf "%s," "${!excluded_dirs[@]}")
        excluded_dirs_list="${excluded_dirs_list%,}"
    fi
    
    # Convert system_files associative array to comma-separated list
    if [[ ${#system_files[@]} -gt 0 ]]; then
        system_files_list=$(printf "%s," "${!system_files[@]}")
        system_files_list="${system_files_list%,}"
    fi
    
    # Convert system_dirs associative array to comma-separated list
    if [[ ${#system_dirs[@]} -gt 0 ]]; then
        system_dirs_list=$(printf "%s," "${!system_dirs[@]}")
        system_dirs_list="${system_dirs_list%,}"
    fi
    
    # Compute cache key header for auto-invalidation (Plan 224)
    local cache_key=""
    if declare -f compute_cache_key >/dev/null 2>&1; then
        cache_key=$(compute_cache_key "$project_path")
    fi

    # Write cache file in the format expected by read_cached_exclusions
    {
        # Cache version header for automatic invalidation (Plan 224)
        if [[ -n "$cache_key" ]]; then
            echo "# EXCL_CACHE_V=$cache_key"
        fi
        echo "excluded_files=$excluded_files_list"
        echo "excluded_dirs=$excluded_dirs_list"
        echo "system_files=$system_files_list"
        echo "system_dirs=$system_dirs_list"
    } > "$cache_file"
    
    # Store config modification time for change detection
    get_exclusions_config_mtime "$project_path" > "$cache_meta"
}

# Export functions so they can be used after sourcing
export -f get_exclusions_config_mtime
export -f is_exclusions_cache_valid
export -f write_exclusions_cache