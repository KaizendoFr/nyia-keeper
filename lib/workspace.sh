#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later OR Proprietary
# Copyright (c) 2024 Nyia Keeper Contributors

# Workspace mode functions for multi-repository support
# This module provides functions to detect, parse, and manage workspace configurations
# that allow a single Nyia Keeper session to work across multiple related repositories.

# Load guard — this module has `readonly` declarations, so re-sourcing (e.g. when a
# subcommand re-sources it alongside bin/nyia) would print "readonly variable" noise.
if [[ -n "${_NYIA_WORKSPACE_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
_NYIA_WORKSPACE_LOADED=1

# === WORKSPACE DETECTION ===

# Returns 0 if workspace.conf exists, 1 otherwise
# Usage: is_workspace [project_path]
is_workspace() {
    local project_path="${1:-$(pwd)}"
    [[ -f "$project_path/.nyiakeeper/workspace.conf" ]]
}

# === WORKSPACE DIRECTIVES ===

# Known workspace.conf directive prefixes (key=value lines)
# Only these prefixes are intercepted as directives; all other lines
# are passed to the repo parser (including paths containing '=').
# Defensive: only declare if unset. The load guard above stops a re-source of THIS
# copy, but a STALE installed copy (no guard) sourced first in the same shell would set
# this readonly, then this copy's naked re-declaration would abort under `set -e`
# (seen in dual-install: ~/.local/lib + dev both sourced). Guarding the declaration
# makes the lib idempotent regardless of which/how many copies are sourced. (Plan 283)
if [[ -z "${_WORKSPACE_DIRECTIVE_PREFIXES+x}" ]]; then
    readonly _WORKSPACE_DIRECTIVE_PREFIXES=("sync_branches")
fi

# Internal: Check if a trimmed line is a known workspace.conf directive
# Returns 0 if directive, 1 if not
_is_workspace_directive() {
    local line="$1"
    local prefix
    for prefix in "${_WORKSPACE_DIRECTIVE_PREFIXES[@]}"; do
        if [[ "$line" =~ ^${prefix}= ]]; then
            return 0
        fi
    done
    return 1
}

# Parse the sync_branches directive from workspace.conf
# Returns: "true" or "false" on stdout (empty if not set)
# Warns on empty or invalid values
parse_workspace_sync_directive() {
    local project_path="$1"
    local conf_file="$project_path/.nyiakeeper/workspace.conf"

    [[ ! -f "$conf_file" ]] && return 0

    local found_value=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        # Trim whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue

        if [[ "$line" =~ ^sync_branches= ]]; then
            found_value="${line#sync_branches=}"
            # Strip quotes
            if [[ "$found_value" =~ ^\"(.*)\"$ ]]; then
                found_value="${BASH_REMATCH[1]}"
            elif [[ "$found_value" =~ ^\'(.*)\'$ ]]; then
                found_value="${BASH_REMATCH[1]}"
            fi
        fi
    done < "$conf_file"

    if [[ -z "$found_value" ]]; then
        return 0
    fi

    case "$found_value" in
        true|false)
            echo "$found_value"
            ;;
        "")
            echo "Warning: Empty value for sync_branches in workspace.conf, ignoring" >&2
            ;;
        *)
            echo "Warning: Invalid value '$found_value' for sync_branches in workspace.conf, ignoring" >&2
            ;;
    esac
}

# === WORKSPACE PARSING ===

# Internal: Extract path and mode from a workspace.conf line
# Handles quoted paths ("path with spaces" rw) and unquoted (path rw)
# Sets variables: _ws_path, _ws_mode
# Returns 1 with error message on stderr if line is malformed
_parse_workspace_line() {
    local line="$1"
    local raw_line="$2"  # Original line for error messages
    _ws_path=""
    _ws_mode=""

    if [[ "$line" == \"* ]]; then
        # Quoted path: extract between first and last quote
        local after_quote="${line#\"}"
        if [[ "$after_quote" != *\"* ]]; then
            echo "ERROR: Unclosed quote in workspace.conf: $raw_line" >&2
            return 1
        fi
        _ws_path="${after_quote%%\"*}"
        local remainder="${after_quote#*\"}"
        # Trim whitespace from remainder to get mode
        remainder="${remainder#"${remainder%%[![:space:]]*}"}"
        remainder="${remainder%"${remainder##*[![:space:]]}"}"
        _ws_mode="$remainder"
    else
        # Unquoted path: last whitespace-delimited token is mode
        _ws_mode="${line##* }"
        _ws_path="${line% *}"
        # If no space found, path == mode (single token = missing mode)
        if [[ "$_ws_path" == "$_ws_mode" ]]; then
            _ws_path="$line"
            _ws_mode=""
        fi
    fi

    # Validate mode
    if [[ -z "$_ws_mode" ]]; then
        echo "ERROR: Missing access mode (ro/rw) for: $raw_line. Add 'ro' or 'rw' at end of line." >&2
        return 1
    fi
    _ws_mode=$(echo "$_ws_mode" | tr '[:upper:]' '[:lower:]')
    if [[ "$_ws_mode" != "ro" && "$_ws_mode" != "rw" ]]; then
        echo "ERROR: Invalid access mode '$_ws_mode' for: $raw_line. Use 'ro' or 'rw'." >&2
        return 1
    fi

    return 0
}

# Reads workspace.conf, expands paths, returns array (one path per line)
# Format: <path> <ro|rw>  or  "<path with spaces>" <ro|rw>
# Usage: mapfile -t repos < <(parse_workspace_repos "$PROJECT_PATH")
parse_workspace_repos() {
    local project_path="$1"
    local conf_file="$project_path/.nyiakeeper/workspace.conf"

    [[ ! -f "$conf_file" ]] && return 0

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip empty lines
        [[ -z "$line" ]] && continue
        # Skip comment lines (# at start, with optional leading whitespace)
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        # Trim leading/trailing whitespace
        local raw_line="$line"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue

        # Skip known directive lines (key=value)
        if _is_workspace_directive "$line"; then
            continue
        fi

        # Extract path and mode
        if ! _parse_workspace_line "$line" "$raw_line"; then
            return 1
        fi
        local path="$_ws_path"

        # Expand ~ to $HOME
        path="${path/#\~/$HOME}"

        # Resolve symlinks to canonical path (Issue #9)
        if [[ -d "$path" ]]; then
            path=$(realpath "$path" 2>/dev/null || echo "$path")
        fi

        echo "$path"
    done < "$conf_file"
}

# Reads workspace.conf, returns mode per line (ro or rw) in same order as parse_workspace_repos
# Usage: mapfile -t modes < <(parse_workspace_modes "$PROJECT_PATH")
parse_workspace_modes() {
    local project_path="$1"
    local conf_file="$project_path/.nyiakeeper/workspace.conf"

    [[ ! -f "$conf_file" ]] && return 0

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        local raw_line="$line"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue

        # Skip known directive lines (key=value)
        if _is_workspace_directive "$line"; then
            continue
        fi

        if ! _parse_workspace_line "$line" "$raw_line"; then
            return 1
        fi

        echo "$_ws_mode"
    done < "$conf_file"
}

# === WORKSPACE VERIFICATION ===

# Verify all repos exist; RW repos must be git repos, RO repos just need to exist
# Usage: verify_workspace_repos "$workspace_path" repos_array modes_array
#   repos_array and modes_array are passed by name (declare -n)
verify_workspace_repos() {
    local workspace_path="$1"
    local -n _verify_repos="${2:-_empty_arr}"
    local -n _verify_modes="${3:-_empty_arr}"

    # Get canonical workspace path for self-reference check (Issue #8)
    local canonical_workspace
    canonical_workspace=$(realpath "$workspace_path" 2>/dev/null || echo "$workspace_path")

    local i
    for ((i=0; i<${#_verify_repos[@]}; i++)); do
        local repo="${_verify_repos[i]}"
        local mode="${_verify_modes[i]:-rw}"  # Default rw for backward compat
        [[ -z "$repo" ]] && continue

        # Resolve to canonical path for comparison
        local canonical_repo
        canonical_repo=$(realpath "$repo" 2>/dev/null || echo "$repo")

        # Self-reference check (Issue #8)
        if [[ "$canonical_repo" == "$canonical_workspace" ]]; then
            if declare -f print_error >/dev/null 2>&1; then
                print_error "Workspace cannot include itself: $repo"
            else
                echo "ERROR: Workspace cannot include itself: $repo" >&2
            fi
            return 1
        fi

        # Check directory exists (both RO and RW)
        if [[ ! -d "$repo" ]]; then
            if declare -f print_error >/dev/null 2>&1; then
                print_error "Workspace repo not found: $repo"
            else
                echo "ERROR: Workspace repo not found: $repo" >&2
            fi
            return 1
        fi

        # Check is git repository (RW only — RO repos don't need git)
        if [[ "$mode" == "rw" ]] && [[ ! -d "$repo/.git" ]]; then
            if declare -f print_error >/dev/null 2>&1; then
                print_error "Workspace repo is not a git repository: $repo"
            else
                echo "ERROR: Workspace repo is not a git repository: $repo" >&2
            fi

            # Detect if this is a subdirectory of a git repo — give targeted guidance
            local parent_git_root
            parent_git_root=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null || true)
            if [[ -n "$parent_git_root" ]]; then
                echo "" >&2
                echo "This directory is inside a git repository at: $parent_git_root" >&2
                echo "" >&2
                echo "Subdirectories of git repos are not supported as workspace entries because" >&2
                echo "the AI assistant needs .git/ access for status, diff, blame, and branch" >&2
                echo "operations. Without it, git is completely non-functional inside the container." >&2
                echo "" >&2
                echo "Workarounds:" >&2
                echo "  1. Add the full repository and use exclusions to scope AI access:" >&2
                echo "       $parent_git_root    rw" >&2
                echo "     Then edit $parent_git_root/.nyiakeeper/exclusions.conf to exclude dirs." >&2
                echo "     Run 'nyia exclusions list $parent_git_root' to see what gets excluded." >&2
                echo "  2. Add the subdirectory as read-only (no git needed for RO):" >&2
                echo "       $repo    ro" >&2
            else
                echo "Initialize git first: cd '$repo' && git init && git add . && git commit -m 'init'" >&2
            fi
            return 1
        fi
    done

    return 0
}

# === VOLUME ARGS BUILDING ===

# Builds complete VOLUME_ARGS for workspace mode
# Calls create_volume_args for workspace, then appends repos with their access modes
# Usage: build_workspace_volume_args "$workspace_path" "$container_path" repos_array modes_array
build_workspace_volume_args() {
    local workspace_path="$1"
    local container_path="$2"
    local -n _build_repos="${3:-_empty_arr}"
    local -n _build_modes="${4:-_empty_arr}"

    # Step 1: Mount workspace with its exclusions (clears VOLUME_ARGS)
    if declare -f create_volume_args >/dev/null 2>&1; then
        create_volume_args "$workspace_path" "$container_path"
    else
        VOLUME_ARGS=("-v" "$workspace_path:$container_path:rw")
    fi

    # Step 2: Append each repo with its mode (does NOT clear VOLUME_ARGS)
    if declare -f append_repo_volume_args >/dev/null 2>&1; then
        local i
        for ((i=0; i<${#_build_repos[@]}; i++)); do
            local repo="${_build_repos[i]}"
            local mode="${_build_modes[i]:-rw}"
            [[ -z "$repo" ]] && continue
            append_repo_volume_args "$repo" "$container_path/repos" "$mode"
        done
    fi
}

# Shared helper called by run_docker_container() and run_debug_shell()
# Abstracts the workspace vs normal mode volume mounting decision
# Usage: get_workspace_volume_args "$project_path" "$container_path"
get_workspace_volume_args() {
    local project_path="$1"
    local container_path="$2"

    if [[ "$WORKSPACE_MODE" == "true" ]] && declare -f build_workspace_volume_args >/dev/null 2>&1; then
        build_workspace_volume_args "$project_path" "$container_path" WORKSPACE_REPOS WORKSPACE_REPO_MODES
    elif declare -f create_volume_args >/dev/null 2>&1; then
        create_volume_args "$project_path" "$container_path"
    else
        VOLUME_ARGS=("-v" "$project_path:$container_path:rw")
    fi
}
