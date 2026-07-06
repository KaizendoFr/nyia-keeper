#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later OR Proprietary
# Copyright (c) 2024 Nyia Keeper Contributors
#
# Command Policy Module
# Resolves effective command mode (safe|full) across 6 precedence levels.
# Provides safe config parsing for project-level (untrusted) files.

# Guard against double-sourcing
if [[ -n "${_NYIA_COMMAND_POLICY_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
_NYIA_COMMAND_POLICY_LOADED=1

# === USER-MANAGEABLE KEY ALLOWLIST ===
# Only these keys are exposed via `nyia config` and accepted by the safe parser.
# Internal keys (ASSISTANT_NAME, BASE_IMAGE_NAME, etc.) are NOT user-manageable.
readonly NYIA_USER_CONFIG_KEYS=(
    "NYIA_COMMAND_MODE"
    "NYIA_RAG_MODEL"
    "NYIA_TEAM_DIR"
    "NYIA_MARKETPLACE_URL"
    "NYIA_WORKSPACE_SYNC"
    "NYIA_WHATSUP_ENABLED"
    "NYIA_WHATSUP_AUTO_READ"
    "NYIA_AUTO_BRANCH"
    "NYIA_GIT_HISTORY_CUTOFF"
    "NYIA_NETWORK_EGRESS_POLICY"
    "NYIA_AUTH_PROFILE"
)

# === VALID VALUES ===
readonly NYIA_VALID_COMMAND_MODES=("safe" "full")
readonly NYIA_DEFAULT_COMMAND_MODE="safe"
readonly NYIA_DEFAULT_RAG_MODEL="nomic-embed-text"
readonly NYIA_DEFAULT_TEAM_DIR=""
readonly NYIA_DEFAULT_MARKETPLACE_URL=""
readonly NYIA_DEFAULT_WORKSPACE_SYNC="false"
readonly NYIA_DEFAULT_WHATSUP_ENABLED="false"
readonly NYIA_DEFAULT_WHATSUP_AUTO_READ="never"
readonly NYIA_DEFAULT_AUTO_BRANCH="false"
readonly NYIA_DEFAULT_GIT_HISTORY_CUTOFF=""
readonly NYIA_VALID_NETWORK_EGRESS_POLICIES=("off" "restrict-local")
readonly NYIA_DEFAULT_NETWORK_EGRESS_POLICY="off"
readonly NYIA_DEFAULT_AUTH_PROFILE="default"

# === KEY NAME MAPPING ===
# Maps user-friendly short names to internal variable names
# Used by `nyia config` for user convenience
_map_config_key_name() {
    local key="$1"
    case "$key" in
        command_mode)  echo "NYIA_COMMAND_MODE" ;;
        rag_model)     echo "NYIA_RAG_MODEL" ;;
        team_dir)      echo "NYIA_TEAM_DIR" ;;
        marketplace_url) echo "NYIA_MARKETPLACE_URL" ;;
        workspace_sync) echo "NYIA_WORKSPACE_SYNC" ;;
        whatsup_enabled) echo "NYIA_WHATSUP_ENABLED" ;;
        whatsup_auto_read) echo "NYIA_WHATSUP_AUTO_READ" ;;
        auto_branch)       echo "NYIA_AUTO_BRANCH" ;;
        git_history_cutoff) echo "NYIA_GIT_HISTORY_CUTOFF" ;;
        network_egress_policy) echo "NYIA_NETWORK_EGRESS_POLICY" ;;
        auth_profile) echo "NYIA_AUTH_PROFILE" ;;
        NYIA_COMMAND_MODE)  echo "NYIA_COMMAND_MODE" ;;
        NYIA_RAG_MODEL)     echo "NYIA_RAG_MODEL" ;;
        NYIA_TEAM_DIR)      echo "NYIA_TEAM_DIR" ;;
        NYIA_MARKETPLACE_URL) echo "NYIA_MARKETPLACE_URL" ;;
        NYIA_WORKSPACE_SYNC) echo "NYIA_WORKSPACE_SYNC" ;;
        NYIA_WHATSUP_ENABLED) echo "NYIA_WHATSUP_ENABLED" ;;
        NYIA_WHATSUP_AUTO_READ) echo "NYIA_WHATSUP_AUTO_READ" ;;
        NYIA_AUTO_BRANCH) echo "NYIA_AUTO_BRANCH" ;;
        NYIA_GIT_HISTORY_CUTOFF) echo "NYIA_GIT_HISTORY_CUTOFF" ;;
        NYIA_NETWORK_EGRESS_POLICY) echo "NYIA_NETWORK_EGRESS_POLICY" ;;
        NYIA_AUTH_PROFILE) echo "NYIA_AUTH_PROFILE" ;;
        *)             echo "" ;;
    esac
}

# === KEY VALIDATION ===

# Check if a key is in the user-manageable allowlist
# Returns 0 if valid, 1 if not
is_valid_config_key() {
    local key="$1"
    local mapped
    mapped=$(_map_config_key_name "$key")
    [[ -n "$mapped" ]]
}

# Validate a command mode value
# Returns 0 if valid, 1 if not
validate_command_mode() {
    local mode="$1"
    case "$mode" in
        safe|full) return 0 ;;
        *) return 1 ;;
    esac
}

# Validate a marketplace URL value.
# Accepts git-clonable URLs only:
#   - scheme URLs:  https://host/path, http://host/path, git://host/path, ssh://[user@]host[:port]/path
#   - scp-like:     [user@]host:path  (e.g. git@github.com:org/repo.git)
# Returns 0 if valid, 1 if not. No network access (syntactic check only).
validate_marketplace_url() {
    local url="$1"
    [[ -z "$url" ]] && return 1

    # Reject command-substitution / injection characters defensively.
    case "$url" in
        *'$('* | *'`'* | *'${'* | *';'* | *'&'* | *'|'* | *' '*) return 1 ;;
    esac

    # Scheme-based URLs (https/http/git/ssh require a host before the path)
    if [[ "$url" =~ ^(https|http|git|ssh)://[^/]+/.+ ]]; then
        return 0
    fi

    # Local filesystem repos: file:///abs/path (git-clonable; used for local
    # mirrors and tests). Requires an absolute path after the scheme.
    if [[ "$url" =~ ^file:///.+ ]]; then
        return 0
    fi

    # scp-like syntax: [user@]host:path (host must not contain a slash before ':').
    # Reject anything containing "://" here — that is a (mis-spelled) scheme URL,
    # not scp syntax, and only the schemes whitelisted above are valid.
    if [[ "$url" != *"://"* ]] && [[ "$url" =~ ^([A-Za-z0-9._~-]+@)?[A-Za-z0-9._-]+:.+ ]]; then
        return 0
    fi

    return 1
}

# Validate a config value for a given key
# Returns 0 if valid, 1 if not. Writes error to stderr.
validate_config_value() {
    local key="$1"
    local value="$2"
    local mapped
    mapped=$(_map_config_key_name "$key")

    # Plan 282 (codex H3): config values are written as KEY="value" and later
    # sourced, so reject shell metacharacters that could inject shell or break
    # round-tripping. No registered key needs these characters.
    case "$value" in
        *'"'*|*'`'*|*'$'*|*'\'*)
            echo "Error: value for '$key' contains unsupported characters (one of: \" \` \$ \\)." >&2
            return 1
            ;;
    esac
    if [[ "$value" == *$'\n'* ]]; then
        echo "Error: value for '$key' must not contain newlines." >&2
        return 1
    fi

    case "$mapped" in
        NYIA_COMMAND_MODE)
            if ! validate_command_mode "$value"; then
                echo "Error: Invalid command mode '$value'. Valid values: safe, full" >&2
                return 1
            fi
            ;;
        NYIA_RAG_MODEL)
            # Any non-empty string is valid for model name
            if [[ -z "$value" ]]; then
                echo "Error: rag_model cannot be empty" >&2
                return 1
            fi
            ;;
        NYIA_TEAM_DIR)
            # Any non-empty string is valid (directory path)
            if [[ -z "$value" ]]; then
                echo "Error: team_dir cannot be empty. Use 'nyia config global team_dir=' to unset." >&2
                return 1
            fi
            ;;
        NYIA_MARKETPLACE_URL)
            # Must look like a git URL: https://, http://, git://, ssh://,
            # or scp-like syntax (user@host:path / host:path). Unsetting handled
            # by the caller before validation (empty value clears the key).
            if [[ -z "$value" ]]; then
                echo "Error: marketplace_url cannot be empty. Use 'nyia config global marketplace_url=' to unset." >&2
                return 1
            fi
            if ! validate_marketplace_url "$value"; then
                echo "Error: Invalid marketplace_url '$value'. Expected a git URL (https://, ssh://, git://, or user@host:path)." >&2
                return 1
            fi
            ;;
        NYIA_WORKSPACE_SYNC)
            case "$value" in
                true|false) ;;
                *)
                    echo "Error: Invalid workspace_sync value '$value'. Valid values: true, false" >&2
                    return 1
                    ;;
            esac
            ;;
        NYIA_WHATSUP_ENABLED)
            case "$value" in
                true|false) ;;
                *)
                    echo "Error: Invalid whatsup_enabled value '$value'. Valid values: true, false" >&2
                    return 1
                    ;;
            esac
            ;;
        NYIA_WHATSUP_AUTO_READ)
            case "$value" in
                kickoff|never) ;;
                *)
                    echo "Error: Invalid whatsup_auto_read value '$value'. Valid values: kickoff, never" >&2
                    return 1
                    ;;
            esac
            ;;
        NYIA_AUTO_BRANCH)
            case "$value" in
                true|false) ;;
                *)
                    echo "Error: Invalid auto_branch value '$value'. Valid values: true, false" >&2
                    return 1
                    ;;
            esac
            ;;
        NYIA_GIT_HISTORY_CUTOFF)
            # Plan 278 v1: a date (YYYY-MM-DD) or a tag/ref — NOT a bare commit SHA
            # (git --shallow-exclude rejects bare SHAs; see plan review M2). Empty = unset.
            if [[ -n "$value" && "$value" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
                echo "Error: git_history_cutoff must be a date (YYYY-MM-DD) or a tag, not a commit SHA (Plan 278 v1)." >&2
                return 1
            fi
            ;;
        NYIA_NETWORK_EGRESS_POLICY)
            case "$value" in
                off|restrict-local) ;;
                *)
                    echo "Error: Invalid network_egress_policy value '$value'. Valid values: off, restrict-local" >&2
                    return 1
                    ;;
            esac
            ;;
        NYIA_AUTH_PROFILE)
            # Profile name becomes a filesystem path + docker -v arg; strict slug only,
            # no traversal. (Plan 286) 'default' = the legacy/global creds.
            if [[ "$value" == "default" ]]; then :
            elif [[ "$value" == *".."* ]] || [[ ! "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9._-]{0,62}[A-Za-z0-9])?$ ]]; then
                echo "Error: Invalid auth_profile '$value'. Use letters, digits, . _ - (no '..', '/', ':' or spaces)." >&2
                return 1
            fi
            ;;
        *)
            echo "Error: Unknown config key '$key'" >&2
            return 1
            ;;
    esac
    return 0
}

# === SAFE CONFIG PARSER ===
# Parses config files line-by-line for project-level (untrusted) files.
# NEVER uses source/eval. Rejects command substitution and invalid characters.
#
# Usage: parse_config_file <file_path> [key_filter]
# Sets variables in the caller's scope via nameref or prints KEY=VALUE lines.
# If key_filter is provided, only returns value for that specific key.
#
# Returns 0 on success, 1 on file not found/error.

parse_config_file() {
    local file_path="$1"
    local key_filter="${2:-}"

    if [[ ! -f "$file_path" ]]; then
        return 1
    fi

    if [[ ! -r "$file_path" ]]; then
        echo "Warning: Cannot read config file: $file_path" >&2
        return 1
    fi

    local line_num=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line_num=$((line_num + 1))

        # Skip empty lines and comments
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue

        # Strip leading/trailing whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"

        # Must match KEY=VALUE or KEY="VALUE" pattern
        if [[ ! "$line" =~ ^[A-Z_][A-Z0-9_]*= ]]; then
            echo "Warning: Skipping malformed line $line_num in $file_path" >&2
            continue
        fi

        local key="${line%%=*}"
        local value="${line#*=}"

        # Reject if key contains invalid characters
        if [[ ! "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
            echo "Warning: Invalid key name '$key' at line $line_num in $file_path" >&2
            continue
        fi

        # SECURITY: Reject command substitution and backticks in values
        if [[ "$value" =~ \$\( || "$value" =~ \` || "$value" =~ \$\{ ]]; then
            echo "Warning: Rejected unsafe value for '$key' at line $line_num in $file_path (command substitution not allowed)" >&2
            continue
        fi

        # Strip surrounding quotes from value
        if [[ "$value" =~ ^\"(.*)\"$ ]]; then
            value="${BASH_REMATCH[1]}"
        elif [[ "$value" =~ ^\'(.*)\'$ ]]; then
            value="${BASH_REMATCH[1]}"
        fi

        # Check if key is in the user-manageable allowlist
        local is_allowed=false
        local k
        for k in "${NYIA_USER_CONFIG_KEYS[@]}"; do
            if [[ "$k" == "$key" ]]; then
                is_allowed=true
                break
            fi
        done

        if [[ "$is_allowed" != "true" ]]; then
            # Skip non-user-manageable keys silently (they may be internal keys)
            continue
        fi

        # If filtering for a specific key, check match
        if [[ -n "$key_filter" ]]; then
            if [[ "$key" == "$key_filter" ]]; then
                echo "$value"
                return 0
            fi
        else
            echo "${key}=${value}"
        fi
    done < "$file_path"

    # If filtering and we got here, key was not found
    if [[ -n "$key_filter" ]]; then
        return 1
    fi

    return 0
}

# === 9-LEVEL RESOLVER ===
# Walks precedence levels 1-9 and returns the first defined NYIA_COMMAND_MODE.
# "Closest to code wins" — higher levels override lower ones.
#
# Levels (highest priority first):
#   1. CLI override (NYIA_COMMAND_MODE_CLI env var, set by cli-parser.sh)
#   2. Project + assistant (.nyiakeeper/{assistant}.conf) — safe parsed
#   3. Project private (.nyiakeeper/private/config/nyia.conf) — safe parsed
#   4. Project global (.nyiakeeper/nyia.conf) — safe parsed (write target for `nyia config project`)
#   5. Project shared (.nyiakeeper/shared/config/nyia.conf) — safe parsed
#   6. Global + assistant (~/.config/nyiakeeper/config/{assistant}.conf) — source OK
#   7. Global (~/.config/nyiakeeper/config/nyia.conf) — source OK
#   8. Team ($NYIA_TEAM_DIR/config/nyia.conf) — safe parsed (untrusted)
#   9. Default (safe)
#
# Arguments:
#   $1 - assistant name (e.g., "claude", "codex")
#   $2 - project path (optional, for levels 2-5)
#
# Outputs:
#   Prints the effective command mode to stdout.
#   Sets NYIA_COMMAND_MODE_SOURCE in the caller's environment.

resolve_command_mode() {
    local assistant_name="${1:-}"
    local project_path="${2:-}"
    local mode=""
    local source_label=""
    local config_home="${NYIA_CONFIG_HOME:-${HOME}/.config/nyiakeeper/config}"

    # Level 1: CLI override
    if [[ -n "${NYIA_COMMAND_MODE_CLI:-}" ]]; then
        mode="$NYIA_COMMAND_MODE_CLI"
        source_label="cli-override"
    fi

    # Level 2: Project + assistant
    if [[ -z "$mode" && -n "$assistant_name" && -n "$project_path" ]]; then
        local project_assistant_conf="$project_path/.nyiakeeper/${assistant_name}.conf"
        if [[ -f "$project_assistant_conf" ]]; then
            local val
            val=$(parse_config_file "$project_assistant_conf" "NYIA_COMMAND_MODE") && {
                if [[ -n "$val" ]]; then
                    mode="$val"
                    source_label="project+${assistant_name}"
                fi
            }
        fi
    fi

    # Level 3: Project private config
    if [[ -z "$mode" && -n "$project_path" ]]; then
        local f="$project_path/.nyiakeeper/private/config/nyia.conf"
        if [[ -f "$f" ]]; then
            local val
            val=$(parse_config_file "$f" "NYIA_COMMAND_MODE") && {
                [[ -n "$val" ]] && mode="$val" && source_label="project-private"
            }
        fi
    fi

    # Level 4: Project global (existing write target for `nyia config project`)
    if [[ -z "$mode" && -n "$project_path" ]]; then
        local project_global_conf="$project_path/.nyiakeeper/nyia.conf"
        if [[ -f "$project_global_conf" ]]; then
            local val
            val=$(parse_config_file "$project_global_conf" "NYIA_COMMAND_MODE") && {
                if [[ -n "$val" ]]; then
                    mode="$val"
                    source_label="project-global"
                fi
            }
        fi
    fi

    # Level 5: Project shared config
    if [[ -z "$mode" && -n "$project_path" ]]; then
        local f="$project_path/.nyiakeeper/shared/config/nyia.conf"
        if [[ -f "$f" ]]; then
            local val
            val=$(parse_config_file "$f" "NYIA_COMMAND_MODE") && {
                [[ -n "$val" ]] && mode="$val" && source_label="project-shared"
            }
        fi
    fi

    # Level 6: Global + assistant (existing per-assistant .conf files — source OK)
    if [[ -z "$mode" && -n "$assistant_name" ]]; then
        local global_assistant_conf="$config_home/${assistant_name}.conf"
        if [[ -f "$global_assistant_conf" ]]; then
            # Global files are user-controlled; safe to source for the key we need
            local val
            val=$(_source_config_key "$global_assistant_conf" "NYIA_COMMAND_MODE") && {
                if [[ -n "$val" ]]; then
                    mode="$val"
                    source_label="global+${assistant_name}"
                fi
            }
        fi
    fi

    # Level 7: Global cross-assistant
    if [[ -z "$mode" ]]; then
        local global_conf="$config_home/nyia.conf"
        if [[ -f "$global_conf" ]]; then
            local val
            val=$(_source_config_key "$global_conf" "NYIA_COMMAND_MODE") && {
                if [[ -n "$val" ]]; then
                    mode="$val"
                    source_label="global"
                fi
            }
        fi
    fi

    # Level 8: Team config (safe-parsed — untrusted, another team member wrote it)
    if [[ -z "$mode" ]]; then
        local team_dir=""
        if [[ -f "$config_home/nyia.conf" ]]; then
            team_dir=$(_source_config_key "$config_home/nyia.conf" "NYIA_TEAM_DIR") || true
        fi
        if [[ -n "$team_dir" && -f "$team_dir/config/nyia.conf" ]]; then
            local val
            val=$(parse_config_file "$team_dir/config/nyia.conf" "NYIA_COMMAND_MODE") && {
                [[ -n "$val" ]] && mode="$val" && source_label="team"
            }
        fi
    fi

    # Level 9: Default
    if [[ -z "$mode" ]]; then
        mode="$NYIA_DEFAULT_COMMAND_MODE"
        source_label="default"
    fi

    # Validate the resolved mode
    if ! validate_command_mode "$mode"; then
        echo "Warning: Invalid command mode '$mode' from $source_label, falling back to safe" >&2
        mode="safe"
        source_label="default(fallback)"
    fi

    # Output format: "mode<TAB>source" for subshell-safe parsing
    printf '%s\t%s\n' "$mode" "$source_label"
}

# Convenience: resolve and split into NYIA_COMMAND_MODE + NYIA_COMMAND_MODE_SOURCE globals.
# Must be called directly (not in a subshell) for the exports to persist.
resolve_and_export_command_mode() {
    local assistant_name="${1:-}"
    local project_path="${2:-}"
    local result
    result=$(resolve_command_mode "$assistant_name" "$project_path")
    export NYIA_COMMAND_MODE="${result%%	*}"
    export NYIA_COMMAND_MODE_SOURCE="${result#*	}"
}

# Convenience: resolve and export the effective network egress policy (Plan 280a).
# Sets NYIA_EFFECTIVE_EGRESS_POLICY (off|restrict-local) for the launch path to read.
# Must be called directly (not in a subshell) for the export to persist.
resolve_and_export_egress_policy() {
    local assistant_name="${1:-}"
    local project_path="${2:-}"
    local policy
    policy=$(resolve_config_value_raw "NYIA_NETWORK_EGRESS_POLICY" "$assistant_name" "$project_path")
    export NYIA_EFFECTIVE_EGRESS_POLICY="${policy:-off}"
}

# Convenience: resolve and export NYIA_RAG_MODEL from config precedence.
# Must be called directly (not in a subshell) for the exports to persist.
resolve_and_export_rag_model() {
    local assistant_name="${1:-}"
    local project_path="${2:-}"
    local result
    result=$(_resolve_rag_model "$assistant_name" "$project_path")
    local model="${result%%	*}"
    if [[ -n "$model" ]]; then
        export NYIA_RAG_MODEL="$model"
        export NYIA_RAG_MODEL_SOURCE="${result#*	}"
    fi
}

# Get just the effective mode (for use in subshells / $())
get_effective_command_mode() {
    local result
    result=$(resolve_command_mode "$@")
    echo "${result%%	*}"
}

# Get just the source label (for use in subshells / $())
get_effective_command_mode_source() {
    local result
    result=$(resolve_command_mode "$@")
    echo "${result#*	}"
}

# === INTERNAL HELPERS ===

# Source a global config file and extract a specific key value.
# Used for levels 4-5 (user-controlled global files where source is safe).
_source_config_key() {
    local file_path="$1"
    local key_name="$2"

    if [[ ! -f "$file_path" || ! -r "$file_path" ]]; then
        return 1
    fi

    # Source in a subshell to avoid polluting the caller's environment
    (
        # Unset the target key first to detect if it gets set
        unset "$key_name"
        # shellcheck disable=SC1090
        source "$file_path" 2>/dev/null
        local val="${!key_name:-}"
        if [[ -n "$val" ]]; then
            echo "$val"
        else
            exit 1
        fi
    )
}

# === ASSISTANT MODE MAPPING ===
# Returns CLI flags for a given assistant and mode.
#
# Arguments:
#   $1 - assistant name (claude, codex, gemini, opencode, vibe)
#   $2 - effective mode (safe|full)
#
# Outputs:
#   Prints space-separated flags to stdout.
#   For assistants without a permissive flag, prints nothing and logs info to stderr.

build_assistant_mode_args() {
    local assistant="$1"
    local mode="$2"

    if [[ "$mode" == "safe" ]]; then
        # safe = no bypass flags, defer to assistant defaults
        return 0
    fi

    # full mode: per-assistant native flag mapping
    case "$assistant" in
        claude)
            echo "--dangerously-skip-permissions"
            ;;
        codex)
            echo "--yolo"
            ;;
        gemini)
            echo "--approval-mode=yolo"
            ;;
        opencode)
            echo "Info: full mode requested but OpenCode has no permissive override flag; using assistant defaults" >&2
            ;;
        vibe)
            echo "Info: full mode requested but Vibe auto-approve profile not available; using assistant defaults" >&2
            ;;
        *)
            echo "Warning: Unknown assistant '$assistant' for mode mapping" >&2
            ;;
    esac
}

# === CONFIG FILE WRITE HELPERS ===
# Used by `nyia config project|global [assistant] key=value`

# Determine the target config file path for a write operation.
# Arguments:
#   $1 - scope: "project" or "global"
#   $2 - assistant name (optional, empty string for cross-assistant)
#   $3 - project path (required for scope=project)
# Outputs: file path to stdout
get_config_target_file() {
    local scope="$1"
    local assistant="${2:-}"
    local project_path="${3:-}"
    local config_home="${NYIA_CONFIG_HOME:-${HOME}/.config/nyiakeeper/config}"

    case "$scope" in
        project)
            if [[ -z "$project_path" ]]; then
                echo "Error: Project path required for project scope" >&2
                return 1
            fi
            if [[ -n "$assistant" ]]; then
                echo "$project_path/.nyiakeeper/${assistant}.conf"
            else
                echo "$project_path/.nyiakeeper/nyia.conf"
            fi
            ;;
        global)
            if [[ -n "$assistant" ]]; then
                echo "$config_home/${assistant}.conf"
            else
                echo "$config_home/nyia.conf"
            fi
            ;;
        *)
            echo "Error: Invalid scope '$scope'. Use 'project' or 'global'" >&2
            return 1
            ;;
    esac
}

# Write a key=value pair to a config file.
# Creates the file and parent directory if needed.
# Updates existing key if present, appends if not.
# Arguments:
#   $1 - file path
#   $2 - key (internal name, e.g., NYIA_COMMAND_MODE)
#   $3 - value
write_config_value() {
    local file_path="$1"
    local key="$2"
    local value="$3"

    # Create parent directory if needed
    local dir
    dir="$(dirname "$file_path")"
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir"
    fi

    if [[ -f "$file_path" ]]; then
        # Check if key already exists in file
        if grep -q "^${key}=" "$file_path" 2>/dev/null; then
            # Update existing key — use safe line-by-line rewrite (no sed -i portability issues)
            local temp_file
            temp_file="$(mktemp)"
            while IFS= read -r line || [[ -n "$line" ]]; do
                if [[ "$line" =~ ^${key}= ]]; then
                    echo "${key}=\"${value}\""
                else
                    echo "$line"
                fi
            done < "$file_path" > "$temp_file"
            mv "$temp_file" "$file_path"
        else
            # Append new key
            echo "${key}=\"${value}\"" >> "$file_path"
        fi
    else
        # Create new file with header
        {
            echo "# Nyia Keeper Configuration"
            echo "# Generated by: nyia config"
            echo ""
            echo "${key}=\"${value}\""
        } > "$file_path"
    fi
}

# Read the effective value of a user-manageable key across all 6 levels.
# Arguments:
#   $1 - key (internal name, e.g., NYIA_COMMAND_MODE)
#   $2 - assistant name (optional)
#   $3 - project path (optional)
# Outputs: prints "value (source: label)" to stdout
read_effective_config_value() {
    local key="$1"
    local assistant_name="${2:-}"
    local project_path="${3:-}"

    case "$key" in
        NYIA_COMMAND_MODE)
            local result
            result=$(resolve_command_mode "$assistant_name" "$project_path")
            local mode="${result%%	*}"
            local src="${result#*	}"
            echo "$mode (source: $src)"
            ;;
        NYIA_RAG_MODEL)
            local result
            result=$(_resolve_rag_model "$assistant_name" "$project_path")
            local model="${result%%	*}"
            local src="${result#*	}"
            echo "$model (source: $src)"
            ;;
        NYIA_TEAM_DIR)
            local result
            result=$(_resolve_team_dir_config)
            local dir="${result%%	*}"
            local src="${result#*	}"
            if [[ -n "$dir" ]]; then
                echo "$dir (source: $src)"
            else
                echo "(not configured)"
            fi
            ;;
        NYIA_MARKETPLACE_URL)
            local result
            result=$(_resolve_marketplace_url_config "$project_path")
            local url="${result%%	*}"
            local src="${result#*	}"
            if [[ -n "$url" ]]; then
                echo "$url (source: $src)"
            else
                echo "(not configured)"
            fi
            ;;
        NYIA_WORKSPACE_SYNC)
            local result
            result=$(_resolve_workspace_sync_config "$project_path")
            local val="${result%%	*}"
            local src="${result#*	}"
            echo "$val (source: $src)"
            ;;
        NYIA_WHATSUP_ENABLED)
            local result
            result=$(_resolve_whatsup_config "NYIA_WHATSUP_ENABLED" "$NYIA_DEFAULT_WHATSUP_ENABLED" "$project_path")
            local val="${result%%	*}"
            local src="${result#*	}"
            echo "$val (source: $src)"
            ;;
        NYIA_WHATSUP_AUTO_READ)
            local result
            result=$(_resolve_whatsup_config "NYIA_WHATSUP_AUTO_READ" "$NYIA_DEFAULT_WHATSUP_AUTO_READ" "$project_path")
            local val="${result%%	*}"
            local src="${result#*	}"
            echo "$val (source: $src)"
            ;;
        NYIA_AUTO_BRANCH)
            # Reuses the generic project-global -> global -> default scoped resolver.
            local result
            result=$(_resolve_whatsup_config "NYIA_AUTO_BRANCH" "$NYIA_DEFAULT_AUTO_BRANCH" "$project_path")
            local val="${result%%	*}"
            local src="${result#*	}"
            echo "$val (source: $src)"
            ;;
        NYIA_GIT_HISTORY_CUTOFF)
            local result
            result=$(_resolve_whatsup_config "NYIA_GIT_HISTORY_CUTOFF" "$NYIA_DEFAULT_GIT_HISTORY_CUTOFF" "$project_path")
            local val="${result%%	*}"
            local src="${result#*	}"
            if [[ -n "$val" ]]; then
                echo "$val (source: $src)"
            else
                echo "(not configured)"
            fi
            ;;
        NYIA_NETWORK_EGRESS_POLICY)
            local result
            result=$(_resolve_whatsup_config "NYIA_NETWORK_EGRESS_POLICY" "$NYIA_DEFAULT_NETWORK_EGRESS_POLICY" "$project_path")
            local val="${result%%	*}"
            local src="${result#*	}"
            echo "$val (source: $src)"
            ;;
        NYIA_AUTH_PROFILE)
            # GLOBAL-only (no project_path) — a committed project conf must not redirect creds.
            local result
            result=$(_resolve_whatsup_config "NYIA_AUTH_PROFILE" "$NYIA_DEFAULT_AUTH_PROFILE" "")
            local val="${result%%	*}"
            local src="${result#*	}"
            echo "$val (source: $src)"
            ;;
        *)
            echo "Error: Unknown key '$key'" >&2
            return 1
            ;;
    esac
}

# resolve_config_value_raw <key> <assistant> <project_path>
# Returns ONLY the effective value (no "(source: ...)" suffix; empty string when
# unset). Unlike read_effective_config_value (which formats for `nyia config view`),
# this is for code that needs the bare value (launch decisions, etc.). Currently
# supports the scope-resolved keys used by the launch path (Plan 278/280).
resolve_config_value_raw() {
    local key="$1"
    local assistant_name="${2:-}"
    local project_path="${3:-}"
    local mapped
    mapped=$(_map_config_key_name "$key")
    case "$mapped" in
        NYIA_GIT_HISTORY_CUTOFF)
            local r
            r=$(_resolve_whatsup_config "NYIA_GIT_HISTORY_CUTOFF" "$NYIA_DEFAULT_GIT_HISTORY_CUTOFF" "$project_path")
            echo "${r%%	*}"
            ;;
        NYIA_NETWORK_EGRESS_POLICY)
            local r
            r=$(_resolve_whatsup_config "NYIA_NETWORK_EGRESS_POLICY" "$NYIA_DEFAULT_NETWORK_EGRESS_POLICY" "$project_path")
            echo "${r%%	*}"
            ;;
        NYIA_AUTH_PROFILE)
            # GLOBAL-only: ignore any project_path so a committed conf can't redirect creds.
            local r
            r=$(_resolve_whatsup_config "NYIA_AUTH_PROFILE" "$NYIA_DEFAULT_AUTH_PROFILE" "")
            echo "${r%%	*}"
            ;;
        *)
            echo "Error: resolve_config_value_raw: unsupported key '$key'" >&2
            return 1
            ;;
    esac
}

# Simple resolver for NYIA_TEAM_DIR (global-only — team dir is a user preference, not per-project)
_resolve_team_dir_config() {
    local dir=""
    local source_label=""
    local config_home="${NYIA_CONFIG_HOME:-${HOME}/.config/nyiakeeper/config}"

    # Only global config (team dir is a user-level setting, not project-level)
    local f="$config_home/nyia.conf"
    if [[ -f "$f" ]]; then
        local val
        val=$(_source_config_key "$f" "NYIA_TEAM_DIR") && {
            [[ -n "$val" ]] && dir="$val" && source_label="global"
        }
    fi

    if [[ -z "$dir" ]]; then
        dir="$NYIA_DEFAULT_TEAM_DIR"
        source_label="default"
    fi

    printf '%s\t%s\n' "$dir" "$source_label"
}

# Resolver for NYIA_MARKETPLACE_URL.
# UNLIKE NYIA_TEAM_DIR (global-only), the marketplace URL is settable at BOTH
# project and global precedence so a repo can pin its own team marketplace.
# Precedence: project .nyiakeeper/nyia.conf (safe parsed, untrusted) > global > default(empty).
# Arguments:
#   $1 - project path (optional — needed to read project config)
_resolve_marketplace_url_config() {
    local project_path="${1:-}"
    local url=""
    local source_label=""
    local config_home="${NYIA_CONFIG_HOME:-${HOME}/.config/nyiakeeper/config}"

    # Level 1: Project global config (untrusted — safe parsed)
    if [[ -z "$url" && -n "$project_path" ]]; then
        local f="$project_path/.nyiakeeper/nyia.conf"
        if [[ -f "$f" ]]; then
            local val
            val=$(parse_config_file "$f" "NYIA_MARKETPLACE_URL") && {
                [[ -n "$val" ]] && url="$val" && source_label="project-global"
            }
        fi
    fi

    # Level 2: Global config (user-controlled — source OK)
    if [[ -z "$url" ]]; then
        local f="$config_home/nyia.conf"
        if [[ -f "$f" ]]; then
            local val
            val=$(_source_config_key "$f" "NYIA_MARKETPLACE_URL") && {
                [[ -n "$val" ]] && url="$val" && source_label="global"
            }
        fi
    fi

    # Level 3: Default (empty)
    if [[ -z "$url" ]]; then
        url="$NYIA_DEFAULT_MARKETPLACE_URL"
        source_label="default"
    fi

    printf '%s\t%s\n' "$url" "$source_label"
}

# Unified resolver for NYIA_WORKSPACE_SYNC
# Precedence: workspace.conf directive > global config > default (false)
# Used by both runtime behavior AND `nyia config view` to ensure they agree.
# Arguments:
#   $1 - project path (optional — needed to read workspace.conf directive)
_resolve_workspace_sync_config() {
    local project_path="${1:-}"
    local sync=""
    local source_label=""
    local config_home="${NYIA_CONFIG_HOME:-${HOME}/.config/nyiakeeper/config}"

    # Level 1: workspace.conf directive (closest to code wins)
    if [[ -z "$sync" && -n "$project_path" ]]; then
        local conf_file="$project_path/.nyiakeeper/workspace.conf"
        if [[ -f "$conf_file" ]]; then
            local directive_val=""
            while IFS= read -r line || [[ -n "$line" ]]; do
                [[ -z "$line" ]] && continue
                [[ "$line" =~ ^[[:space:]]*# ]] && continue
                # Trim whitespace
                line="${line#"${line%%[![:space:]]*}"}"
                line="${line%"${line##*[![:space:]]}"}"
                [[ -z "$line" ]] && continue
                # Known-prefix matching for directives
                if [[ "$line" =~ ^sync_branches= ]]; then
                    directive_val="${line#sync_branches=}"
                    # Strip quotes
                    if [[ "$directive_val" =~ ^\"(.*)\"$ ]]; then
                        directive_val="${BASH_REMATCH[1]}"
                    elif [[ "$directive_val" =~ ^\'(.*)\'$ ]]; then
                        directive_val="${BASH_REMATCH[1]}"
                    fi
                fi
            done < "$conf_file"
            if [[ -n "$directive_val" ]]; then
                case "$directive_val" in
                    true|false)
                        sync="$directive_val"
                        source_label="workspace.conf"
                        ;;
                    *)
                        echo "Warning: Invalid value '$directive_val' for sync_branches in workspace.conf, ignoring" >&2
                        ;;
                esac
            fi
        fi
    fi

    # Level 2: Global config
    if [[ -z "$sync" ]]; then
        local f="$config_home/nyia.conf"
        if [[ -f "$f" ]]; then
            local val
            val=$(_source_config_key "$f" "NYIA_WORKSPACE_SYNC") && {
                [[ -n "$val" ]] && sync="$val" && source_label="global"
            }
        fi
    fi

    # Level 3: Default
    if [[ -z "$sync" ]]; then
        sync="$NYIA_DEFAULT_WORKSPACE_SYNC"
        source_label="default"
    fi

    # Validate
    case "$sync" in
        true|false) ;;
        *)
            echo "Warning: Invalid workspace_sync '$sync' from $source_label, falling back to false" >&2
            sync="false"
            source_label="default(fallback)"
            ;;
    esac

    printf '%s\t%s\n' "$sync" "$source_label"
}

# Unified resolver for whatsup config keys (Plan 258)
# Precedence: project .nyiakeeper/nyia.conf (safe parsed) > global config > default.
# Used by /kickoff and /checkpoint hooks and by `nyia config view`.
# Arguments:
#   $1 - internal key name (NYIA_WHATSUP_ENABLED | NYIA_WHATSUP_AUTO_READ)
#   $2 - default value to fall back to
#   $3 - project path (optional — needed to read project config)
_resolve_whatsup_config() {
    local key="$1"
    local default_value="$2"
    local project_path="${3:-}"
    local value=""
    local source_label=""
    local config_home="${NYIA_CONFIG_HOME:-${HOME}/.config/nyiakeeper/config}"

    # Level 1: Project global config (untrusted — safe parsed)
    if [[ -z "$value" && -n "$project_path" ]]; then
        local f="$project_path/.nyiakeeper/nyia.conf"
        if [[ -f "$f" ]]; then
            local val
            val=$(parse_config_file "$f" "$key") && {
                [[ -n "$val" ]] && value="$val" && source_label="project-global"
            }
        fi
    fi

    # Level 2: Global config (user-controlled — source OK)
    if [[ -z "$value" ]]; then
        local f="$config_home/nyia.conf"
        if [[ -f "$f" ]]; then
            local val
            val=$(_source_config_key "$f" "$key") && {
                [[ -n "$val" ]] && value="$val" && source_label="global"
            }
        fi
    fi

    # Level 3: Default
    if [[ -z "$value" ]]; then
        value="$default_value"
        source_label="default"
    fi

    printf '%s\t%s\n' "$value" "$source_label"
}

# Resolver for NYIA_RAG_MODEL (same 9-level pattern as command_mode)
_resolve_rag_model() {
    local assistant_name="${1:-}"
    local project_path="${2:-}"
    local model=""
    local source_label=""
    local config_home="${NYIA_CONFIG_HOME:-${HOME}/.config/nyiakeeper/config}"

    # Level 2: Project + assistant
    if [[ -z "$model" && -n "$assistant_name" && -n "$project_path" ]]; then
        local f="$project_path/.nyiakeeper/${assistant_name}.conf"
        if [[ -f "$f" ]]; then
            local val
            val=$(parse_config_file "$f" "NYIA_RAG_MODEL") && {
                [[ -n "$val" ]] && model="$val" && source_label="project+${assistant_name}"
            }
        fi
    fi

    # Level 3: Project private config
    if [[ -z "$model" && -n "$project_path" ]]; then
        local f="$project_path/.nyiakeeper/private/config/nyia.conf"
        if [[ -f "$f" ]]; then
            local val
            val=$(parse_config_file "$f" "NYIA_RAG_MODEL") && {
                [[ -n "$val" ]] && model="$val" && source_label="project-private"
            }
        fi
    fi

    # Level 4: Project global
    if [[ -z "$model" && -n "$project_path" ]]; then
        local f="$project_path/.nyiakeeper/nyia.conf"
        if [[ -f "$f" ]]; then
            local val
            val=$(parse_config_file "$f" "NYIA_RAG_MODEL") && {
                [[ -n "$val" ]] && model="$val" && source_label="project-global"
            }
        fi
    fi

    # Level 5: Project shared config
    if [[ -z "$model" && -n "$project_path" ]]; then
        local f="$project_path/.nyiakeeper/shared/config/nyia.conf"
        if [[ -f "$f" ]]; then
            local val
            val=$(parse_config_file "$f" "NYIA_RAG_MODEL") && {
                [[ -n "$val" ]] && model="$val" && source_label="project-shared"
            }
        fi
    fi

    # Level 6: Global + assistant
    if [[ -z "$model" && -n "$assistant_name" ]]; then
        local f="$config_home/${assistant_name}.conf"
        if [[ -f "$f" ]]; then
            local val
            val=$(_source_config_key "$f" "NYIA_RAG_MODEL") && {
                [[ -n "$val" ]] && model="$val" && source_label="global+${assistant_name}"
            }
        fi
    fi

    # Level 7: Global
    if [[ -z "$model" ]]; then
        local f="$config_home/nyia.conf"
        if [[ -f "$f" ]]; then
            local val
            val=$(_source_config_key "$f" "NYIA_RAG_MODEL") && {
                [[ -n "$val" ]] && model="$val" && source_label="global"
            }
        fi
    fi

    # Level 8: Team config
    if [[ -z "$model" ]]; then
        local team_dir=""
        if [[ -f "$config_home/nyia.conf" ]]; then
            team_dir=$(_source_config_key "$config_home/nyia.conf" "NYIA_TEAM_DIR") || true
        fi
        if [[ -n "$team_dir" && -f "$team_dir/config/nyia.conf" ]]; then
            local val
            val=$(parse_config_file "$team_dir/config/nyia.conf" "NYIA_RAG_MODEL") && {
                [[ -n "$val" ]] && model="$val" && source_label="team"
            }
        fi
    fi

    # Level 9: Default
    if [[ -z "$model" ]]; then
        model="$NYIA_DEFAULT_RAG_MODEL"
        source_label="default"
    fi

    printf '%s\t%s\n' "$model" "$source_label"
}
