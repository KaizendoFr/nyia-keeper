#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later OR Proprietary
# Copyright (c) 2024 Nyia Keeper Contributors
#
# Bash completion for nyia CLI and nyia-* assistant commands.
#
# Usage:
#   eval "$(nyia completions bash)"
#   # or: source /path/to/nyia.bash
#
# When adding new commands/flags, update the lists below.
# Runtime flags only — dev-only flags (--build, --dry-run, --dev,
# --base-image, --test-registry) are excluded.

_nyia() {
    local cur prev words cword
    _init_completion || return

    # Top-level subcommands
    local commands="config exclusions update list status clean completions rollback logo help"

    # Global flags
    local global_flags="--help --verbose --version --path"

    case "$cword" in
        1)
            COMPREPLY=($(compgen -W "$commands $global_flags" -- "$cur"))
            return
            ;;
    esac

    # Subcommand dispatch
    local subcmd="${words[1]}"
    case "$subcmd" in
        config)
            if [[ "$cword" -eq 2 ]]; then
                COMPREPLY=($(compgen -W "view list dump get project global help" -- "$cur"))
            elif [[ "$cword" -ge 3 ]]; then
                case "${words[2]}" in
                    list)
                        COMPREPLY=($(compgen -W "--show-origin" -- "$cur"))
                        ;;
                    project|global)
                        COMPREPLY=($(compgen -W "--yes" -- "$cur"))
                        ;;
                esac
            fi
            ;;
        exclusions)
            if [[ "$cword" -eq 2 ]]; then
                COMPREPLY=($(compgen -W "list test status patterns lockdown help" -- "$cur"))
            elif [[ "$cword" -ge 3 ]]; then
                case "${words[2]}" in
                    lockdown)
                        COMPREPLY=($(compgen -W "--force --workspace" -- "$cur"))
                        ;;
                esac
            fi
            ;;
        update)
            if [[ "$cword" -eq 2 ]]; then
                COMPREPLY=($(compgen -W "status list check install rollback help" -- "$cur"))
            fi
            ;;
        completions)
            if [[ "$cword" -eq 2 ]]; then
                COMPREPLY=($(compgen -W "bash zsh" -- "$cur"))
            fi
            ;;
    esac
}

_nyia_assistant() {
    local cur prev words cword
    _init_completion || return

    # Runtime assistant flags only (no dev-only flags)
    local flags="
        --help -h
        --status
        --login --force
        --shell
        --image
        --flavor
        --agent
        --command-mode
        --list-images --list-flavors --list-agents --list-skills
        --check-requirements
        --verbose -v
        --path
        --base-branch
        --work-branch -w
        --create
        --disable-exclusions
        --skip-checks
        --rag --rag-verbose
        --workspace-init
        --build-custom-image --no-cache
        --setup --set-api-key
    "

    # Suggest values for flags that take arguments
    case "$prev" in
        --command-mode)
            COMPREPLY=($(compgen -W "safe full" -- "$cur"))
            return
            ;;
        --image|--flavor|--agent|--path|--base-branch|--work-branch|-w)
            # These take a value — no static completions, let shell default
            return
            ;;
    esac

    COMPREPLY=($(compgen -W "$flags" -- "$cur"))
}

# Register completions
complete -F _nyia nyia

# Register for all known assistant commands
for _nyia_asst in nyia-claude nyia-gemini nyia-codex nyia-opencode nyia-vibe; do
    complete -F _nyia_assistant "$_nyia_asst"
done
unset _nyia_asst
