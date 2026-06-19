#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later OR Proprietary
# Copyright (c) 2024 Nyia Keeper Contributors
# MIGRATION-COMPAT: remove after v0.2.x
# Contains all "nyarlathotia" references for backward-compat migration.
# This file is excluded from the zero-reference verification gate.

# INTENTIONAL POLICY: Content rewrite updates all old-name references in
# migrated text files. This includes historical references (changelogs, plans).
# Acceptable because these are LLM-consumed files where the current name
# matters more than historical accuracy. Binary files are excluded via
# extension allowlist. Uses portable sed/grep (BSD + GNU compatible).
_migrate_file_contents() {
    local dir="$1"
    local count=0
    # Process substitution (not pipe) so count stays in current shell.
    # Bash + GNU/BSD compatible (not POSIX — uses process substitution + grep --include).
    # --include flags BEFORE path for portability/readability.
    # "|| true" on grep: exit code 1 on no matches is safe under pipefail.
    while IFS= read -r f; do
        # BSD+GNU portable: sed -i.bak + rm .bak
        sed -i.bak 's/NyarlathotIA/Nyia Keeper/g; s/NYARLATHOTIA/NYIAKEEPER/g; s/Nyarlathotia/Nyiakeeper/g; s/nyarlathotia/nyiakeeper/g' "$f"
        rm -f "$f.bak"
        count=$((count + 1))
    done < <(grep -rl --include='*.md' --include='*.conf' --include='*.json' \
        --include='*.yaml' --include='*.yml' --include='*.sh' --include='*.txt' \
        --exclude-dir='plans' \
        'nyarlathotia\|Nyarlathotia\|NyarlathotIA\|NYARLATHOTIA' \
        "$dir" 2>/dev/null || true)
    if [[ $count -gt 0 ]]; then
        echo "[MIGRATION] Updated content in $count file(s)" >&2
    fi
}

# Remove existing marker dir before mv, with safety guards.
# Marker is expendable — just a signal that migration happened.
_remove_marker_if_exists() {
    local marker="$1"
    # Safety: only delete if non-empty var, ends with expected suffix, and is a directory
    if [[ -n "$marker" && "$marker" == *".migrated-to-nyiakeeper" && -d "$marker" ]]; then
        rm -rf "$marker"
    fi
}

# Migrate config dir from old name to new name if needed.
# Called from get_nyiakeeper_home() in common-functions.sh.
# After migration, old dir is renamed to *.migrated-to-nyiakeeper as marker.
migrate_config_dir_if_needed() {
    local new_dir="$1"
    local old_dir="${new_dir/nyiakeeper/nyarlathotia}"
    local marker="${old_dir}.migrated-to-nyiakeeper"

    # No old dir (fresh install or already migrated) → nothing to do
    [[ -d "$old_dir" ]] || return 0

    echo "[MIGRATION] Migrating config: $old_dir -> $new_dir" >&2

    if [[ ! -d "$new_dir" ]]; then
        # New dir absent → rename old to new, then leave marker
        _remove_marker_if_exists "$marker"
        if mv "$old_dir" "$new_dir"; then
            mkdir "$marker"
            _migrate_file_contents "$new_dir"
            echo "[MIGRATION] Complete. Old config dir is now deprecated." >&2
        else
            echo "[MIGRATION] ERROR: Failed to move $old_dir -> $new_dir" >&2
        fi
    else
        # New dir exists (possibly empty skeleton) → merge old into new
        cp -a "$old_dir"/. "$new_dir"/
        _remove_marker_if_exists "$marker"
        if mv "$old_dir" "$marker"; then
            _migrate_file_contents "$new_dir"
            echo "[MIGRATION] Complete. Old config dir is now deprecated." >&2
        else
            echo "[MIGRATION] ERROR: Failed to rename $old_dir to marker" >&2
        fi
    fi
}

# Migrate project tracking dir from .nyarlathotia to .nyiakeeper if needed.
# Called from init_nyiakeeper_dir() in shared.sh.
# After migration, old dir is renamed to *.migrated-to-nyiakeeper as marker.
migrate_project_dir_if_needed() {
    local project_path="$1"
    local new_dir="$project_path/.nyiakeeper"
    local old_dir="$project_path/.nyarlathotia"
    local marker="${old_dir}.migrated-to-nyiakeeper"

    # No old dir (fresh install or already migrated) → nothing to do
    [[ -d "$old_dir" ]] || return 0

    echo "[MIGRATION] Migrating project dir: .nyarlathotia/ -> .nyiakeeper/" >&2

    if [[ ! -d "$new_dir" ]]; then
        # New dir absent → rename old to new, then leave marker
        _remove_marker_if_exists "$marker"
        if mv "$old_dir" "$new_dir"; then
            mkdir "$marker"
            _migrate_file_contents "$new_dir"
            echo "[MIGRATION] Complete. Old project dir is now deprecated." >&2
        else
            echo "[MIGRATION] ERROR: Failed to move $old_dir -> $new_dir" >&2
        fi
    else
        # New dir exists (possibly empty skeleton) → merge old into new
        cp -a "$old_dir"/. "$new_dir"/
        _remove_marker_if_exists "$marker"
        if mv "$old_dir" "$marker"; then
            _migrate_file_contents "$new_dir"
            echo "[MIGRATION] Complete. Old project dir is now deprecated." >&2
        else
            echo "[MIGRATION] ERROR: Failed to rename $old_dir to marker" >&2
        fi
    fi
}

# Migrate macOS ~/Library/Application Support/nyiakeeper → ~/.config/nyiakeeper.
# OS-agnostic function: caller gates on Darwin and passes source/target paths.
# Rule: target wins — existing target files are never overwritten.
# Source files preserved in marker dir for manual reconciliation.
# MIGRATION-COMPAT: remove after v0.2.x
migrate_macos_library_path() {
    local source_dir="$1"
    local target_dir="$2"
    local marker="${source_dir}.migrated-from-library"

    # Already migrated (marker exists) or no source → nothing to do
    [[ -d "$marker" ]] && return 0
    [[ -d "$source_dir" ]] || return 0

    echo "[MIGRATION] Migrating macOS Library path: $source_dir -> $target_dir" >&2

    if [[ ! -d "$target_dir" ]]; then
        # Target absent → move source to target, leave marker
        mkdir -p "$(dirname "$target_dir")"
        if mv "$source_dir" "$target_dir"; then
            mkdir "$marker"
            echo "[MIGRATION] Complete. Old Library path migrated." >&2
        else
            echo "[MIGRATION] ERROR: Failed to move $source_dir -> $target_dir" >&2
        fi
    else
        # Both exist → merge with target-wins rule (file-level no-clobber)
        # Copy only files/dirs that don't exist at target
        if command -v rsync &>/dev/null; then
            rsync -a --ignore-existing "$source_dir/" "$target_dir/"
        else
            # Fallback: manual file-by-file copy
            find "$source_dir" -maxdepth 1 -mindepth 1 | while IFS= read -r item; do
                local name
                name=$(basename "$item")
                if [[ ! -e "$target_dir/$name" ]]; then
                    cp -a "$item" "$target_dir/$name"
                fi
            done
        fi
        if mv "$source_dir" "$marker"; then
            echo "[MIGRATION] Complete. Old Library path merged (target wins)." >&2
        else
            echo "[MIGRATION] ERROR: Failed to rename $source_dir to marker" >&2
        fi
    fi
}

# Repair legacy root prompt symlinks left by the pre-rebrand layout.
#
# A pre-rebrand project root may contain a generated prompt symlink such as:
#   OPENCODE.md -> .nyarlathotia/opencode/OPENCODE.md
# After the .nyarlathotia/ -> .nyiakeeper/ migration, that target no longer
# exists, so the symlink is broken and crashes RAG indexing (Plan 262).
#
# This helper is intentionally CONSERVATIVE. For each known generated prompt
# filename at the project root, it acts ONLY when ALL of these hold:
#   1. the path is a SYMLINK (regular files are never touched)
#   2. its basename is a known generated prompt filename
#   3. readlink target matches exactly .nyarlathotia/<assistant>/<filename>
# When matched:
#   - if .nyiakeeper/<assistant>/<filename> exists -> rewrite the symlink to it
#   - else (broken legacy link) -> remove the symlink
# Unrelated symlinks, symlinks with other targets, and regular files are left
# completely untouched.
#
# MIGRATION-COMPAT: remove after v0.2.x
repair_legacy_prompt_symlinks() {
    local project_path="$1"

    [[ -n "$project_path" && -d "$project_path" ]] || return 0

    # assistant:prompt-filename map (mirrors get_prompt_filename in
    # common-functions.sh: claude->CLAUDE.md, gemini->GEMINI.md,
    # codex->AGENTS.md, opencode->OPENCODE.md, vibe->VIBE.md).
    local map="claude:CLAUDE.md gemini:GEMINI.md codex:AGENTS.md opencode:OPENCODE.md vibe:VIBE.md"

    local entry assistant filename link_path target expected new_target
    for entry in $map; do
        assistant="${entry%%:*}"
        filename="${entry##*:}"
        link_path="$project_path/$filename"

        # Guard 1: must be a symlink. Regular files are never touched.
        [[ -L "$link_path" ]] || continue

        # Guard 3: readlink target must match the legacy layout exactly.
        target="$(readlink "$link_path" 2>/dev/null)" || continue
        expected=".nyarlathotia/$assistant/$filename"
        [[ "$target" == "$expected" ]] || continue

        new_target=".nyiakeeper/$assistant/$filename"
        if [[ -e "$project_path/$new_target" ]]; then
            # Rewrite to the migrated target.
            if rm -f "$link_path" && ln -s "$new_target" "$link_path"; then
                echo "[MIGRATION] Repaired legacy prompt symlink: $filename -> $new_target" >&2
            else
                echo "[MIGRATION] ERROR: Failed to repair prompt symlink: $filename" >&2
            fi
        else
            # Broken legacy link with no migrated target: remove it.
            if rm -f "$link_path"; then
                echo "[MIGRATION] Removed broken legacy prompt symlink: $filename" >&2
            else
                echo "[MIGRATION] ERROR: Failed to remove broken prompt symlink: $filename" >&2
            fi
        fi
    done

    return 0
}

export -f _migrate_file_contents _remove_marker_if_exists \
    migrate_config_dir_if_needed migrate_project_dir_if_needed \
    migrate_macos_library_path repair_legacy_prompt_symlinks
