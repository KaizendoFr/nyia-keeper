#!/usr/bin/env zsh
# SPDX-License-Identifier: AGPL-3.0-or-later OR Proprietary
# Copyright (c) 2024 Nyia Keeper Contributors
#
# Zsh completion for nyia CLI and nyia-* assistant commands.
# Uses compdef + compadd style (works on zsh 5.0+).
#
# Usage:
#   eval "$(nyia completions zsh)"
#   # or: source /path/to/nyia.zsh
#
# When adding new commands/flags, update the lists below.
# Runtime flags only — dev-only flags (--build, --dry-run, --dev,
# --base-image, --test-registry) are excluded.

_nyia() {
    local -a commands global_flags
    commands=(
        'config:Configuration management (list, dump, view, get)'
        'exclusions:Manage mount exclusions for security'
        'update:Update management (status, list, check, install)'
        'list:List all available assistants'
        'status:Show global Nyia Keeper status'
        'clean:Clean up old development images'
        'completions:Generate shell auto-completion scripts (bash, zsh)'
        'rollback:Rollback to previous version'
        'logo:Display Nyia Keeper ASCII art'
        'help:Show help information'
    )
    global_flags=(
        '--help:Show help information'
        '--verbose:Enable verbose output'
        '--version:Show installed version'
        '--path:Work on different project directory'
    )

    # Determine position (word index minus 1 for the command itself)
    if (( CURRENT == 2 )); then
        _describe 'command' commands
        _describe 'option' global_flags
        return
    fi

    # Subcommand dispatch
    local subcmd="${words[2]}"
    case "$subcmd" in
        config)
            if (( CURRENT == 3 )); then
                local -a config_cmds=(
                    'view:Show effective configuration'
                    'list:List configuration values'
                    'dump:Show all configuration'
                    'get:Get specific config value'
                    'project:Set project-level configuration'
                    'global:Set global configuration'
                    'help:Show config help'
                )
                _describe 'config command' config_cmds
            elif (( CURRENT >= 4 )); then
                case "${words[3]}" in
                    list)
                        compadd -- --show-origin
                        ;;
                    project|global)
                        compadd -- --yes
                        ;;
                esac
            fi
            ;;
        exclusions)
            if (( CURRENT == 3 )); then
                local -a excl_cmds=(
                    'list:Show excluded files/patterns'
                    'test:Test if a file would be excluded'
                    'status:Check exclusion system status'
                    'patterns:Show active patterns'
                    'lockdown:Scan project, generate exclude-everything config'
                    'help:Show exclusions help'
                )
                _describe 'exclusions command' excl_cmds
            elif (( CURRENT >= 4 )); then
                case "${words[3]}" in
                    lockdown)
                        compadd -- --force --workspace
                        ;;
                esac
            fi
            ;;
        update)
            if (( CURRENT == 3 )); then
                local -a update_cmds=(
                    'status:Show version, channel, last check'
                    'list:Show channels and recent releases'
                    'check:Check for updates'
                    'install:Install update (channel or version)'
                    'rollback:Rollback to previous version'
                    'help:Show update help'
                )
                _describe 'update command' update_cmds
            fi
            ;;
        completions)
            if (( CURRENT == 3 )); then
                local -a shells=(
                    'bash:Generate Bash completion script'
                    'zsh:Generate Zsh completion script'
                )
                _describe 'shell' shells
            fi
            ;;
    esac
}

_nyia_assistant() {
    local -a flags
    flags=(
        '--help:Show help information'
        '-h:Show help information'
        '--status:Show assistant status and configuration'
        '--login:Authenticate using the assistant container'
        '--force:Force operation (with --login)'
        '--shell:Start interactive bash shell in container'
        '--image:Select specific Docker image'
        '--flavor:Select assistant flavor/variant'
        '--agent:Select agent persona for this session'
        '--command-mode:Set command approval mode (safe or full)'
        '--list-images:List all available Docker images'
        '--list-flavors:List available flavors'
        '--list-agents:List available agent personas'
        '--list-skills:List available skills'
        '--check-requirements:Check system requirements'
        '--verbose:Enable verbose output'
        '-v:Enable verbose output'
        '--path:Work on different project directory'
        '--base-branch:Specify Git base branch'
        '--work-branch:Reuse existing work branch'
        '-w:Reuse existing work branch'
        '--create:Create work branch if it does not exist'
        '--disable-exclusions:Disable mount exclusions for this session'
        '--skip-checks:Skip automatic requirements checking'
        '--rag:Enable RAG codebase search'
        '--rag-verbose:Enable verbose debug logging for RAG'
        '--workspace-init:Create workspace.conf template'
        '--build-custom-image:Build custom Docker image with overlays'
        '--no-cache:Force Docker rebuild without cache'
        '--setup:Interactive model/provider setup'
        '--set-api-key:Helper to set API key'
    )

    # Handle value completion for specific flags
    case "${words[CURRENT-1]}" in
        --command-mode)
            compadd -- safe full
            return
            ;;
        --image|--flavor|--agent|--path|--base-branch|--work-branch|-w)
            # These take a value — no static completions
            return
            ;;
    esac

    _describe 'option' flags
}

# Register completions
compdef _nyia nyia

# Register for all known assistant commands
for _nyia_asst in nyia-claude nyia-gemini nyia-codex nyia-opencode nyia-vibe; do
    compdef _nyia_assistant "$_nyia_asst"
done
unset _nyia_asst
