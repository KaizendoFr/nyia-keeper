#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later OR Proprietary
# Copyright (c) 2024 Nyia Keeper Contributors
# MIGRATION-COMPAT: remove after v0.3.x
# Standalone cleanup for renamed built-in skills (Plan 237 → Plan 338). The rename map and the removal rules live
# in lib/skill-seeding.sh (NYIA_SKILL_RENAMES / remove_stale_shipped_skills) and run automatically on every
# install/upgrade; this script is the MANUAL entry point (dry-run, confirmation) for a host that wants to clean
# up without reinstalling. Never run inside a container.
# This file is excluded from the zero-reference verification gate.

set -euo pipefail

DRY_RUN=false
AUTO_YES=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/../lib/skill-seeding.sh"
[[ -f "$LIB" ]] || LIB="$SCRIPT_DIR/../lib/nyiakeeper/skill-seeding.sh"   # installed layout

usage() {
    cat << EOF2
Usage: $(basename "$0") [OPTIONS] [config-dir]

Remove old-named built-in skills left behind by a rename upgrade.

Skills renamed (old → new):
EOF2
    if [[ -f "$LIB" ]]; then
        # shellcheck source=/dev/null
        source "$LIB"
        local pair; for pair in $NYIA_SKILL_RENAMES; do printf '  %-16s → %s\n' "${pair%%:*}" "${pair#*:}"; done
    fi
    cat << EOF2

Rules: every directory under an old shipped name inside Nyia's own skill directories — the global one, each
assistant's, each persona profile's — is deleted, whatever its content or marker (shipped skills are never edited in
place; a CLI's own commands never live there). Skills under other names, symlinks, team and project-shared skills are
never touched. The same cleanup runs automatically on every install/upgrade and at every launch.

Arguments:
  config-dir    Nyia config root (default: \${NYIAKEEPER_HOME:-\$HOME/.config/nyiakeeper})

Options:
  --dry-run     Report actions without making changes
  --yes         Skip confirmation prompt
  --help        Show this help message

This script must be run on the host, not inside a container.
EOF2
}

log() { echo "[CLEANUP] $*"; }

# Detect nyia-keeper assistant containers specifically via NYIA_ASSISTANT_CLI (set by the launch system).
check_not_in_container() {
    if [[ -n "${NYIA_ASSISTANT_CLI:-}" ]]; then
        echo "ERROR: This script must be run on the host, not inside a container."
        echo "Container skills are ephemeral and self-heal on rebuild."
        exit 1
    fi
}

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
if [[ ! -f "$LIB" ]]; then
    echo "ERROR: $LIB not found (this script must live next to the installed lib/)."
    exit 1
fi
# shellcheck source=/dev/null
source "$LIB"

# Project-level scan (warn only — a tracked shared skill is the team's to rename)
if [[ -d ".nyiakeeper/shared/skills" ]]; then
    for pair in $NYIA_SKILL_RENAMES; do
        old="${pair%%:*}"
        [[ -d ".nyiakeeper/shared/skills/$old" ]] && echo "[WARNING] Project-level: .nyiakeeper/shared/skills/$old (rename it to ${pair#*:} by hand)"
    done
fi

log "Scanning $CONFIG_DIR (dry run):"
plan="$(remove_stale_shipped_skills "$CONFIG_DIR" "${NYIA_TEAM_DIR:-}" 1)"
printf '%s\n' "$plan"
if ! grep -qE 'would (remove|move)' <<<"$plan"; then
    log "Nothing to clean up — no old-named shipped skills found."
    exit 0
fi
if $DRY_RUN; then
    log "Dry run complete — no changes made."
    exit 0
fi
if ! $AUTO_YES; then
    if [[ ! -t 0 ]]; then log "Cancelled: no terminal to confirm on (re-run with --yes)."; exit 0; fi
    printf "Remove the old-named shipped skill directories listed above? [y/N] "
    read -r answer || answer=""
    if [[ "$answer" != "y" && "$answer" != "Y" ]]; then log "Cancelled."; exit 0; fi
fi
remove_stale_shipped_skills "$CONFIG_DIR" "${NYIA_TEAM_DIR:-}" 0 1
log "Done."
