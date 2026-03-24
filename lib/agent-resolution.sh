#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later OR Proprietary
# Copyright (c) 2024 Nyia Keeper Contributors

# Agent Resolution Helper (Plan 149, updated Plan 201)
# Resolves agent persona paths and lists available agents per assistant
# 4-scope precedence: project > shared > team > global

# Get assistant-specific agent directories (project-local, project-shared, team, and global)
# Returns four paths (one per line): project, shared, team, global
# Team line is empty if team_dir is not provided
get_agent_dirs() {
    local assistant_cli="$1"
    local project_path="$2"
    local nyiakeeper_home="$3"
    local team_dir="${4:-}"

    local project_dir=""
    local shared_dir=""
    local team_agents_dir=""
    local global_dir=""

    case "$assistant_cli" in
        claude)
            project_dir="$project_path/.claude/agents"
            ;;
        opencode)
            project_dir="$project_path/.opencode/agents"
            ;;
        vibe)
            project_dir="$project_path/.vibe/agents"
            ;;
        codex)
            # Codex uses config-based agents, not file-based
            project_dir=""
            ;;
        *)
            project_dir=""
            ;;
    esac

    # Project-shared agents (universal, all assistants except codex/gemini)
    if [[ -n "$project_dir" ]]; then
        shared_dir="$project_path/.nyiakeeper/shared/agents"
    fi

    # Global is the raw source (assistant-agnostic), not propagation target
    if [[ -n "$project_dir" ]]; then
        global_dir="$nyiakeeper_home/agents"
    fi

    # Team agents are assistant-agnostic (same pattern as skill-resolution.sh)
    if [[ -n "$team_dir" ]]; then
        team_agents_dir="$team_dir/agents"
    fi

    echo "$project_dir"
    echo "$shared_dir"
    echo "$team_agents_dir"
    echo "$global_dir"
}

# Get the file extension pattern for agent definitions
get_agent_file_pattern() {
    local assistant_cli="$1"

    case "$assistant_cli" in
        claude)    echo "*.md" ;;
        opencode)  echo "*.md *.json" ;;
        vibe)      echo "*.toml" ;;
        *)         echo "" ;;
    esac
}

# List available agents for an assistant
# Scans 4 raw source directories with dedup (project > shared > team > global)
list_agents() {
    local assistant_cli="$1"
    local project_path="$2"
    local nyiakeeper_home="$3"
    local team_dir="${4:-}"

    local dirs
    dirs=$(get_agent_dirs "$assistant_cli" "$project_path" "$nyiakeeper_home" "$team_dir")
    local project_dir
    project_dir=$(echo "$dirs" | sed -n '1p')
    local shared_dir
    shared_dir=$(echo "$dirs" | sed -n '2p')
    local team_agents_dir
    team_agents_dir=$(echo "$dirs" | sed -n '3p')
    local global_dir
    global_dir=$(echo "$dirs" | sed -n '4p')

    local found_any=false

    echo "Available agent personas for $assistant_cli:"
    echo ""

    # Codex special case: guidance-only
    if [[ "$assistant_cli" == "codex" ]]; then
        echo "  Codex uses config-based agents (not file-based)."
        echo ""
        echo "  To define agents, add sections to ~/.codex/config.toml:"
        echo "    [agents.my-agent]"
        echo "    agent_type = \"custom\""
        echo "    description = \"My custom agent\""
        echo ""
        echo "  To switch agents in a Codex session, use the /agent command."
        return 0
    fi

    # Gemini: not supported
    if [[ "$assistant_cli" == "gemini" ]]; then
        echo "  Agent persona selection is not yet supported for Gemini."
        return 0
    fi

    local patterns
    patterns=$(get_agent_file_pattern "$assistant_cli")

    # Disable glob expansion so patterns like *.md don't expand in for loops
    local restore_glob=false
    if [[ -o noglob ]]; then
        restore_glob=false
    else
        restore_glob=true
        set -f
    fi

    # Project-local agents
    if [[ -n "$project_dir" && -d "$project_dir" ]]; then
        local project_agents=()
        for pattern in $patterns; do
            while IFS= read -r -d '' f; do
                project_agents+=("$f")
            done < <(find "$project_dir" -maxdepth 1 -name "$pattern" -type f -print0 2>/dev/null)
        done
        if [[ ${#project_agents[@]} -gt 0 ]]; then
            echo "  Project agents ($project_dir/):"
            for agent_file in "${project_agents[@]}"; do
                local name
                name=$(basename "$agent_file" | sed 's/\.[^.]*$//')
                printf "    %-20s %s\n" "$name" "($(basename "$agent_file"))"
            done
            echo ""
            found_any=true
        fi
    fi

    # Project-shared agents (.nyiakeeper/shared/agents/)
    if [[ -n "$shared_dir" && -d "$shared_dir" ]]; then
        local shared_agents=()
        for pattern in $patterns; do
            while IFS= read -r -d '' f; do
                shared_agents+=("$f")
            done < <(find "$shared_dir" -maxdepth 1 -name "$pattern" -type f -print0 2>/dev/null)
        done
        if [[ ${#shared_agents[@]} -gt 0 ]]; then
            echo "  Shared agents ($shared_dir/):"
            for agent_file in "${shared_agents[@]}"; do
                local name
                name=$(basename "$agent_file" | sed 's/\.[^.]*$//')
                printf "    %-20s %s\n" "$name" "($(basename "$agent_file"))"
            done
            echo ""
            found_any=true
        fi
    fi

    # Team agents (team_dir/agents/)
    if [[ -n "$team_agents_dir" && -d "$team_agents_dir" ]]; then
        local team_agents=()
        for pattern in $patterns; do
            while IFS= read -r -d '' f; do
                team_agents+=("$f")
            done < <(find "$team_agents_dir" -maxdepth 1 -name "$pattern" -type f -print0 2>/dev/null)
        done
        if [[ ${#team_agents[@]} -gt 0 ]]; then
            echo "  Team agents ($team_agents_dir/):"
            for agent_file in "${team_agents[@]}"; do
                local name
                name=$(basename "$agent_file" | sed 's/\.[^.]*$//')
                printf "    %-20s %s\n" "$name" "($(basename "$agent_file"))"
            done
            echo ""
            found_any=true
        fi
    fi

    # Global agents
    if [[ -n "$global_dir" && -d "$global_dir" ]]; then
        local global_agents=()
        for pattern in $patterns; do
            while IFS= read -r -d '' f; do
                global_agents+=("$f")
            done < <(find "$global_dir" -maxdepth 1 -name "$pattern" -type f -print0 2>/dev/null)
        done
        if [[ ${#global_agents[@]} -gt 0 ]]; then
            echo "  Global agents ($global_dir/):"
            for agent_file in "${global_agents[@]}"; do
                local name
                name=$(basename "$agent_file" | sed 's/\.[^.]*$//')
                printf "    %-20s %s\n" "$name" "($(basename "$agent_file"))"
            done
            echo ""
            found_any=true
        fi
    fi

    # Restore glob expansion
    if [[ "$restore_glob" == "true" ]]; then
        set +f
    fi

    if [[ "$found_any" == "false" ]]; then
        echo "  No agent personas found."
        echo ""
        echo "  To create an agent, add a definition file to:"
        if [[ -n "$project_dir" ]]; then
            echo "    Project: $project_dir/"
        fi
        if [[ -n "$shared_dir" ]]; then
            echo "    Shared:  $shared_dir/"
        fi
        if [[ -n "$team_agents_dir" ]]; then
            echo "    Team:    $team_agents_dir/"
        fi
        if [[ -n "$global_dir" ]]; then
            echo "    Global:  $global_dir/"
        fi
    fi

    return 0
}

# Check if a specific agent exists (for validation)
agent_exists() {
    local assistant_cli="$1"
    local agent_name="$2"
    local project_path="$3"
    local nyiakeeper_home="$4"
    local team_dir="${5:-}"

    # Codex: always "exists" (guidance-only, no file check)
    if [[ "$assistant_cli" == "codex" ]]; then
        return 0
    fi

    local dirs
    dirs=$(get_agent_dirs "$assistant_cli" "$project_path" "$nyiakeeper_home" "$team_dir")
    local project_dir
    project_dir=$(echo "$dirs" | sed -n '1p')
    local shared_dir
    shared_dir=$(echo "$dirs" | sed -n '2p')
    local team_agents_dir
    team_agents_dir=$(echo "$dirs" | sed -n '3p')
    local global_dir
    global_dir=$(echo "$dirs" | sed -n '4p')

    local patterns
    patterns=$(get_agent_file_pattern "$assistant_cli")

    # Disable glob expansion so patterns like *.md don't expand in for loops
    local restore_glob=false
    if [[ -o noglob ]]; then
        restore_glob=false
    else
        restore_glob=true
        set -f
    fi

    # Check project-local first, then shared, then team, then global (precedence order)
    for dir in "$project_dir" "$shared_dir" "$team_agents_dir" "$global_dir"; do
        if [[ -n "$dir" && -d "$dir" ]]; then
            for pattern in $patterns; do
                local ext="${pattern#\*}"
                if [[ -f "$dir/${agent_name}${ext}" ]]; then
                    [[ "$restore_glob" == "true" ]] && set +f
                    return 0
                fi
            done
        fi
    done

    # Restore glob expansion
    [[ "$restore_glob" == "true" ]] && set +f
    return 1
}

# Export functions
export -f get_agent_dirs
export -f get_agent_file_pattern
export -f list_agents
export -f agent_exists
