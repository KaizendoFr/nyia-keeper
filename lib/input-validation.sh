#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later OR Proprietary
# Copyright (c) 2024 Nyia Keeper Contributors
# Input validation functions for security
# Prevents command injection and directory traversal attacks

# Source shared functions for error reporting
if ! declare -f print_error >/dev/null 2>&1; then
    source "$(dirname "${BASH_SOURCE[0]}")/../bin/common/shared.sh" 2>/dev/null || {
        # Fallback if shared.sh not available
        print_error() { echo "ERROR: $*" >&2; }
        print_info() { echo "INFO: $*" >&2; }
    }
fi

# Validate branch names (prevent command injection)
validate_branch_name() {
    local branch="$1"
    
    # Empty branch name
    if [[ -z "$branch" ]]; then
        print_error "Branch name cannot be empty"
        return 1
    fi
    
    # Allow: letters, numbers, slash, dash, underscore, dot
    # Block: semicolons, pipes, backticks, spaces, etc.
    if [[ "$branch" =~ ^[a-zA-Z0-9._/-]+$ ]]; then
        return 0
    else
        print_error "Invalid branch name: '$branch'"
        print_info "Branch names can only contain: a-z A-Z 0-9 . / _ -"
        print_info "Blocked characters: ; | \` & $ ( ) < > space"
        return 1
    fi
}

# Validate file paths (prevent directory traversal)
validate_file_path() {
    local path="$1"
    
    # Empty path
    if [[ -z "$path" ]]; then
        print_error "File path cannot be empty"
        return 1
    fi
    
    # Block directory traversal attempts
    if [[ "$path" == *".."* ]]; then
        print_error "Path contains '..': '$path'"
        print_info "Directory traversal attempts are blocked for security"
        return 1
    fi
    
    # Block absolute paths outside workspace (unless it's a known safe location)
    if [[ "$path" == /* ]]; then
        case "$path" in
            /workspace*|/tmp/*|/home/node/*)
                return 0  # Allow these paths
                ;;
            *)
                print_error "Absolute path outside allowed directories: '$path'"
                print_info "Allowed absolute paths: /workspace /tmp /home/node"
                return 1
                ;;
        esac
    fi
    
    return 0
}

# Validate Docker image names (prevent registry attacks)
validate_image_name() {
    local image="$1"
    
    # Empty image name
    if [[ -z "$image" ]]; then
        print_error "Image name cannot be empty"
        return 1
    fi
    
    # Basic format validation: [registry/]name[:tag]
    # Allow: letters, numbers, dots, slashes, dashes, colons, underscores
    # Block: spaces, semicolons, pipes, backticks, parentheses
    if [[ "$image" =~ ^[a-zA-Z0-9._/-]+:[a-zA-Z0-9._-]+$ ]]; then
        # Has tag - check for dangerous patterns
        if [[ "$image" == *";"* || "$image" == *"|"* || "$image" == *"\`"* || "$image" == *" "* ]]; then
            print_error "Image name contains dangerous characters: '$image'"
            return 1
        fi
        return 0
    elif [[ "$image" =~ ^[a-zA-Z0-9._/-]+$ ]]; then
        # No tag specified - that's okay for local images
        if [[ "$image" == *";"* || "$image" == *"|"* || "$image" == *"\`"* || "$image" == *" "* ]]; then
            print_error "Image name contains dangerous characters: '$image'"
            return 1
        fi
        return 0
    else
        print_error "Invalid image name format: '$image'"
        print_info "Expected format: [registry/]name[:tag]"
        print_info "Example: nyiakeeper/claude:latest"
        return 1
    fi
}

# Validate agent persona names (prevent injection, enforce naming policy)
validate_agent_name() {
    local name="$1"

    # Empty name
    if [[ -z "$name" ]]; then
        print_error "Agent name cannot be empty"
        return 1
    fi

    # Length check (1-64 chars, aligned with Agent Skills spec)
    if [[ ${#name} -gt 64 ]]; then
        print_error "Agent name too long: '${name:0:20}...' (max 64 characters)"
        return 1
    fi

    # Allow: lowercase letters, numbers, hyphens (same as Agent Skills spec)
    # Must start and end with alphanumeric
    if [[ "$name" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
        return 0
    else
        print_error "Invalid agent name: '$name'"
        print_info "Agent names must contain only lowercase letters, numbers, and hyphens"
        print_info "Must start and end with a letter or number"
        print_info "Examples: reviewer, my-planner, code-review-v2"
        return 1
    fi
}

# Sanitize branch name for safe usage
sanitize_branch_name() {
    local branch="$1"
    # Replace any non-safe characters with dashes
    echo "$branch" | sed 's/[^a-zA-Z0-9._/-]/-/g'
}

# Strip control chars (C0 range + DEL) and cap length for safe terminal display
# of values sourced from user .conf files (Plan 35). Multibyte UTF-8 (bytes
# >= 0x80) is left intact so legitimate names survive; only injection vectors
# (ESC 0x1b, CR, LF, BS, BEL, DEL, ...) are removed.
sanitize_terminal_field() {
    local s="$1" max="${2:-64}"
    s=$(printf '%s' "$s" | LC_ALL=C tr -d '\000-\037\177')
    printf '%s' "${s:0:$max}"
}

# ALLOWLIST for variable names accepted from a project's .nyiakeeper/creds/env (Plan 310).
# creds/env is attacker-controllable for nyia's core "open an untrusted repo" use case, so we
# DEFAULT-DENY: only credential-shaped names may reach the host launcher env or the container.
# This structurally excludes every exec/loader/interpreter/control vector (LD_*, NODE_OPTIONS,
# PATH, HOME, BASH_ENV, GCONV_PATH, GIT_SSH_COMMAND, NYIA_*, ...) — none of which are *_KEY/
# *_TOKEN/*_API_KEY shaped — rather than chasing an unwinnable denylist. Returns 0 if allowed.
is_allowed_creds_var() {
    case "$1" in
        *_API_KEY|*_TOKEN|*_KEY) return 0 ;;
        GOOGLE_CLOUD_PROJECT|GOOGLE_APPLICATION_CREDENTIALS) return 0 ;;
        *) return 1 ;;
    esac
}

# Export functions so they can be used after sourcing
export -f validate_branch_name
export -f validate_file_path
export -f validate_image_name
export -f validate_agent_name
export -f sanitize_branch_name
export -f sanitize_terminal_field
export -f is_allowed_creds_var