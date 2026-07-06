#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later OR Proprietary
# Copyright (c) 2024 Nyia Keeper Contributors
# Marketplace subcommand implementations for nyia (Plan 246a)
# Provides `nyia marketplace init` — scaffolds a pushable team marketplace repo.

# Color functions if not already defined
if ! declare -f print_header >/dev/null 2>&1; then
    print_header() { echo -e "\e[1m$1\e[0m"; }
    print_success() { echo -e "\e[32m✅ $1\e[0m"; }
    print_error() { echo -e "\e[31m❌ $1\e[0m"; }
    print_info() { echo -e "\e[37m📍 $1\e[0m"; }
fi
if ! declare -f print_warning >/dev/null 2>&1; then
    print_warning() { echo -e "\e[33m⚠️  $1\e[0m"; }
fi

# Locate the on-disk template directory, if it ships with this install.
# Returns the path on stdout, or empty if not found (callers fall back to
# embedded heredocs so `init` works even when the template is not packaged).
_marketplace_template_dir() {
    local here
    here="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
    local candidates=(
        "$here/../scripts/marketplace-template"          # dev layout (lib/ -> scripts/)
        "$here/../share/nyiakeeper/marketplace-template" # possible installed layout
    )
    local c
    for c in "${candidates[@]}"; do
        if [[ -d "$c" ]]; then
            echo "$c"
            return 0
        fi
    done
    echo ""
}

# Write the template into $target using the on-disk template if available,
# otherwise from embedded content. Idempotent for empty/new directories.
_marketplace_scaffold() {
    local target="$1"
    local name="$2"

    mkdir -p "$target/skills" "$target/agents"

    local tpl
    tpl="$(_marketplace_template_dir)"

    if [[ -n "$tpl" && -d "$tpl" ]]; then
        # Copy from the shipped template (canonical source of truth).
        cp -f "$tpl/marketplace.json" "$target/marketplace.json" 2>/dev/null || true
        cp -f "$tpl/README.md" "$target/README.md" 2>/dev/null || true
        cp -f "$tpl/.gitignore" "$target/.gitignore" 2>/dev/null || true
        [[ -f "$tpl/skills/.gitkeep" ]] && cp -f "$tpl/skills/.gitkeep" "$target/skills/.gitkeep"
        [[ -f "$tpl/agents/.gitkeep" ]] && cp -f "$tpl/agents/.gitkeep" "$target/agents/.gitkeep"
    else
        # Embedded fallback — keeps `init` working if the template is not packaged.
        : > "$target/skills/.gitkeep"
        : > "$target/agents/.gitkeep"
        cat > "$target/.gitignore" <<'GITIGNORE'
# OS / editor cruft
.DS_Store
Thumbs.db
*.swp
*~

# Local-only notes (do not distribute)
.local/
NOTES.local.md
GITIGNORE
        cat > "$target/README.md" <<'README'
# Team Marketplace

Private Nyia Keeper marketplace — distributes shared skills and agents to every
team member, in every project, automatically.

## Layout
- `marketplace.json` — metadata
- `skills/<name>/SKILL.md` — shared skills
- `agents/<name>.md` — shared agents

## Members configure once
    nyia config global marketplace_url=<this-repo-git-url>

Precedence (no clobber): user > team dir > marketplace > project-shared > built-in.
Auth uses your existing host git credentials. Offline launches use the cache.
README
    fi

    # Always (re)write marketplace.json with the chosen name so --name takes effect.
    # JSON-escape the name so quotes/backslashes/newlines can't produce invalid JSON.
    local name_json
    name_json="$(_mp_json_escape "$name")"
    cat > "$target/marketplace.json" <<JSON
{
  "name": "${name_json}",
  "description": "Private Nyia Keeper marketplace — shared skills and agents for the team.",
  "version": "1.0.0",
  "schema": "nyia-marketplace/v1"
}
JSON
}

# Minimal JSON string escaper (backslash, double-quote, and control chars).
_mp_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"      # backslash first
    s="${s//\"/\\\"}"      # double quote
    s="${s//$'\n'/\\n}"    # newline
    s="${s//$'\r'/\\r}"    # carriage return
    s="${s//$'\t'/\\t}"    # tab
    printf '%s' "$s"
}

# nyia marketplace init [path] [--name <name>]
marketplace_init() {
    local target=""
    local name="My Team Marketplace"

    # Parse args: first non-flag is the path; --name <value> sets the name.
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)
                shift
                if [[ -z "${1:-}" ]]; then
                    print_error "marketplace init: --name requires a value"
                    return 1
                fi
                name="$1"
                shift
                ;;
            --name=*)
                name="${1#--name=}"
                shift
                ;;
            -h|--help)
                marketplace_help
                return 0
                ;;
            -*)
                print_error "marketplace init: unknown option '$1'"
                return 1
                ;;
            *)
                if [[ -z "$target" ]]; then
                    target="$1"
                else
                    print_error "marketplace init: unexpected extra argument '$1'"
                    return 1
                fi
                shift
                ;;
        esac
    done

    # Default path: ./team-marketplace
    [[ -z "$target" ]] && target="team-marketplace"

    # Refuse to scaffold over an existing non-empty directory (avoid clobber).
    if [[ -e "$target" ]]; then
        if [[ ! -d "$target" ]]; then
            print_error "marketplace init: '$target' exists and is not a directory"
            return 1
        fi
        if [[ -n "$(ls -A "$target" 2>/dev/null)" ]]; then
            print_error "marketplace init: directory '$target' is not empty — refusing to overwrite"
            return 1
        fi
    fi

    if ! mkdir -p "$target" 2>/dev/null; then
        print_error "marketplace init: cannot create directory '$target'"
        return 1
    fi

    _marketplace_scaffold "$target" "$name"

    # git init + initial commit (best-effort: scaffolding still succeeds without git).
    local git_ok=false
    if command -v git >/dev/null 2>&1; then
        if git -C "$target" init -q 2>/dev/null; then
            git -C "$target" add -A 2>/dev/null || true
            if git -C "$target" -c user.email=marketplace@nyiakeeper.local \
                   -c user.name="Nyia Marketplace" \
                   commit -q -m "Initialize Nyia marketplace: ${name}" 2>/dev/null; then
                git_ok=true
            fi
        fi
    fi

    local abs_target
    abs_target="$(cd "$target" 2>/dev/null && pwd || echo "$target")"

    print_success "Marketplace scaffolded at: $abs_target"
    echo ""
    print_header "Next steps:"
    echo ""
    echo "  1. Add skills under  skills/<name>/SKILL.md"
    echo "     Add agents under  agents/<name>.md"
    echo ""
    if [[ "$git_ok" == "true" ]]; then
        echo "  2. Create an empty repo on your git host, then push:"
        echo ""
        echo "       cd $target"
        echo "       git remote add origin <your-repo-git-url>"
        echo "       git push -u origin HEAD"
    else
        print_warning "  git was unavailable — initialize and commit the repo manually:"
        echo ""
        echo "       cd $target"
        echo "       git init && git add -A && git commit -m 'Initialize marketplace'"
        echo "       git remote add origin <your-repo-git-url>"
        echo "       git push -u origin HEAD"
    fi
    echo ""
    echo "  3. Each team member configures the URL once (global or per project):"
    echo ""
    echo "       nyia config global marketplace_url=<your-repo-git-url>"
    echo ""
    echo "     On their next launch in ANY project, the team skills + agents sync"
    echo "     automatically. Auth uses each member's own host git credentials."
    echo ""

    return 0
}

marketplace_help() {
    cat <<'HELP'
Usage: nyia marketplace <command> [options]

Manage a private/team marketplace — a Git repo that distributes shared skills
and agents to every team member, in every project (Plan 246a).

Commands:
  init [path] [--name <name>]   Scaffold a pushable marketplace repo
                                (default path: ./team-marketplace)
  help                          Show this help

Configure a marketplace as a member (after the maintainer pushes one):
  nyia config global  marketplace_url=<git-url>   # all projects
  nyia config project marketplace_url=<git-url>   # this project only

Behavior:
  - Skills/agents sync at launch from ~/.cache/nyiakeeper/marketplace/
  - Auth uses your existing host git credentials (Nyia stores no tokens)
  - Offline / unreachable remote → uses cache, never blocks a launch
  - Precedence: user > team dir > marketplace > project-shared > built-in
HELP
}
