#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later OR Proprietary
# Copyright (c) 2024 Nyia Keeper Contributors
# MIGRATION-COMPAT: remove after v0.3.x
# Standalone cleanup script for renamed built-in skills (Plan 237).
# Removes stale old-named skill directories left behind by no-clobber seeding.
# This file is excluded from the zero-reference verification gate.

set -euo pipefail

DRY_RUN=false
AUTO_YES=false

# ── Rename map: old-name → new-name ──────────────────────────────────────────
declare -A RENAME_MAP=(
    [pair-review]=plan-review
    [do-a-plan]=make-a-plan
)

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS] [config-dir]

Remove stale old-named built-in skills left behind after a rename upgrade.

Skills renamed:
  pair-review  → plan-review
  do-a-plan    → make-a-plan

The script cleans both the global skills directory and assistant-specific
propagated skill directories under the Nyia config root.

Arguments:
  config-dir    Nyia config root (default: \${NYIAKEEPER_HOME:-\$HOME/.config/nyiakeeper})

Options:
  --dry-run     Report actions without making changes
  --yes         Skip confirmation prompt
  --help        Show this help message

This script must be run on the host, not inside a container.
EOF
}

log() { echo "[CLEANUP] $*"; }
log_action() { if $DRY_RUN; then echo "[DRY-RUN] Would remove: $*"; else log "Removing: $*"; fi; }
log_warn() { echo "[WARNING] $*"; }
log_skip() { echo "[SKIP] $*"; }

# ── Container detection ──────────────────────────────────────────────────────
# Detect nyia-keeper assistant containers specifically via NYIA_ASSISTANT_CLI
# (set by the launch system). Plain /.dockerenv is not used because it
# triggers in dev/CI Docker environments that are not assistant containers.
check_not_in_container() {
    if [[ -n "${NYIA_ASSISTANT_CLI:-}" ]]; then
        echo "ERROR: This script must be run on the host, not inside a container."
        echo "Container skills are ephemeral and self-heal on rebuild."
        exit 1
    fi
}

# ── Arg parsing ──────────────────────────────────────────────────────────────
CONFIG_DIR=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --yes)     AUTO_YES=true; shift ;;
        --help|-h) usage; exit 0 ;;
        -*)        echo "Unknown option: $1"; usage; exit 1 ;;
        *)         CONFIG_DIR="$1"; shift ;;
    esac
done

check_not_in_container

CONFIG_DIR="${CONFIG_DIR:-${NYIAKEEPER_HOME:-$HOME/.config/nyiakeeper}}"

if [[ ! -d "$CONFIG_DIR" ]]; then
    echo "Config directory not found: $CONFIG_DIR"
    exit 1
fi

# ── Collect stale directories ────────────────────────────────────────────────
QUEUE=()
WARNINGS=()

# Scan a skills directory for stale old-named skills
# Usage: scan_skills_dir <skills_dir> <label>
scan_skills_dir() {
    local skills_dir="$1"
    local label="$2"

    if [[ ! -d "$skills_dir" ]]; then
        return
    fi

    for old_name in "${!RENAME_MAP[@]}"; do
        local new_name="${RENAME_MAP[$old_name]}"
        local old_dir="$skills_dir/$old_name"
        local new_dir="$skills_dir/$new_name"

        if [[ ! -d "$old_dir" ]]; then
            continue
        fi

        if [[ ! -d "$new_dir" ]]; then
            log_warn "$label: '$old_name' exists but replacement '$new_name' not found — skipping (replacement not seeded yet)"
            continue
        fi

        QUEUE+=("$old_dir")
        log_action "$label: $old_dir ($old_name → $new_name)"
    done
}

# 1. Global skills
scan_skills_dir "$CONFIG_DIR/skills" "Global"

# 2. Assistant-specific propagated skills
for assistant_dir in "$CONFIG_DIR"/*/; do
    # Skip non-assistant dirs (skills/, agents/, shared/, etc.)
    local_name="$(basename "$assistant_dir")"
    case "$local_name" in
        skills|agents|prompts|shared|config|creds|dev-tools|plans|private) continue ;;
    esac
    if [[ -d "$assistant_dir/skills" ]]; then
        scan_skills_dir "$assistant_dir/skills" "Assistant ($local_name)"
    fi
done

# 3. Project-level scan (warn only)
if [[ -d ".nyiakeeper/shared/skills" ]]; then
    for old_name in "${!RENAME_MAP[@]}"; do
        if [[ -d ".nyiakeeper/shared/skills/$old_name" ]]; then
            WARNINGS+=("Project-level: .nyiakeeper/shared/skills/$old_name (manual removal recommended)")
        fi
    done
fi

# ── Summary & execution ─────────────────────────────────────────────────────
if [[ ${#QUEUE[@]} -eq 0 ]] && [[ ${#WARNINGS[@]} -eq 0 ]]; then
    log "Nothing to clean up — no stale renamed skills found."
    exit 0
fi

echo ""
if [[ ${#QUEUE[@]} -gt 0 ]]; then
    echo "Stale skill directories to remove: ${#QUEUE[@]}"
    for dir in "${QUEUE[@]}"; do
        echo "  - $dir"
    done
fi

if [[ ${#WARNINGS[@]} -gt 0 ]]; then
    echo ""
    echo "Project-level stale skills (manual removal recommended):"
    for warn in "${WARNINGS[@]}"; do
        echo "  - $warn"
    done
fi

if [[ ${#QUEUE[@]} -eq 0 ]]; then
    echo ""
    log "No auto-removable directories found (project-level skills require manual removal)."
    exit 0
fi

if $DRY_RUN; then
    echo ""
    log "Dry run complete — no changes made."
    exit 0
fi

# Confirmation
if ! $AUTO_YES; then
    echo ""
    printf "Remove %d stale skill directories? [y/N] " "${#QUEUE[@]}"
    read -r answer
    if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
        log "Cancelled."
        exit 0
    fi
fi

# Delete
removed=0
for dir in "${QUEUE[@]}"; do
    rm -rf "$dir"
    removed=$((removed + 1))
done

log "Removed $removed stale skill directories."
