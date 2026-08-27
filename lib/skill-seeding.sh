#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later OR Proprietary
# lib/skill-seeding.sh — Plan 337: host-side seeding of the SHIPPED built-in skills into the global skills dir.
#
# Shipped built-ins are Nyia-owned: refreshed on every install/upgrade, never edited in place (customize
# through a team source, the project's .nyiakeeper/shared/skills/, or an overlay). Every seeded copy carries a
# `.nyia-builtin <version>` marker; that marker is what every later layer (host propagation, in-container
# install) uses to tell "replaceable shipped copy" from "user-owned — never touched".
#
# Sourced by scripts/runtime-install.sh (the dist setup.sh). Unit-tested in tests/bats/test_setup_skill_seeding.bats.

NYIA_SEED_ASSISTANTS="claude codex gemini opencode vibe"

# _seed_same_tree <a> <b> — 0 iff both dirs have identical content (the marker file is ignored).
_seed_same_tree() {
    diff -rq --exclude='.nyia-builtin' "$1" "$2" >/dev/null 2>&1
}

# _seed_prune_propagated <nyia_home> <skill_name> <old_global_copy_or_empty> [team_dir]
#   (team_dir is accepted for call-site symmetry but is never scanned: only <home>/<assistant>/skills and
#   <home>/profiles/*/<assistant>/skills are visited, and a team dir is never one of those.)
#   One-shot bootstrap for installs seeded BEFORE the marker existed. A propagated per-assistant copy of a
#   built-in is removed ONLY when it is byte-identical to the OLD global copy (= a stale propagated built-in
#   nothing else would ever refresh). A copy that carries the marker is left for the launch-time propagation to
#   refresh; anything else is user-owned → kept and NAMED. Never follows a symlink; never touches the team dir.
_seed_prune_propagated() {
    local home="$1" name="$2" old="$3" team="${4:-}" a d cand
    for a in $NYIA_SEED_ASSISTANTS; do
        for d in "$home/$a/skills" "$home"/profiles/*/"$a"/skills; do
            cand="$d/$name"
            [[ -d "$cand" && ! -L "$cand" && ! -L "$d" ]] || continue
            if [[ -f "$cand/.nyia-builtin" ]]; then
                continue                                            # marked: the launch propagation refreshes it
            elif [[ -n "$old" && -d "$old" ]] && _seed_same_tree "$cand" "$old"; then
                rm -rf "$cand"; printf '   pruned stale propagated copy: %s\n' "$cand"
            else
                printf '   kept (user-owned, not a shipped copy): %s\n' "$cand"
            fi
        done
    done
    return 0
}

# seed_builtin_skills <skills_src> <nyia_home> <version> [team_dir] — refresh every shipped skill into
#   <nyia_home>/skills/<name> (marker written), then prune stale propagated copies. Prints a one-line summary.
seed_builtin_skills() {
    local src="$1" home="$2" version="${3:-unknown}" team="${4:-}" d name seeded=0 refreshed=0 tmp_old=""
    [[ -d "$src" ]] || { printf 'skills source not found: %s (skills not seeded)\n' "$src" >&2; return 0; }
    mkdir -p "$home/skills" || return 1
    for d in "$src"/*/; do
        [[ -d "$d" ]] || continue
        name="$(basename "$d")"
        [[ -f "$d/SKILL.md" ]] || continue                           # only real skills (symmetry with discovery)
        case "$name" in */*|..|.|*$'\n'*|*$'\t'*) continue ;; esac   # never a path
        tmp_old=""
        if [[ -d "$home/skills/$name" && ! -L "$home/skills/$name" ]]; then
            tmp_old="$(mktemp -d "${TMPDIR:-/tmp}/nyia-seed.XXXXXX")" || return 1
            cp -r "$home/skills/$name/." "$tmp_old/" 2>/dev/null || true   # keep the OLD copy to recognise stale clones
            refreshed=$((refreshed + 1))
        else
            seeded=$((seeded + 1))
        fi
        rm -rf "$home/skills/$name"
        cp -r "$d" "$home/skills/$name"
        printf 'nyia-builtin %s\n' "$version" > "$home/skills/$name/.nyia-builtin"
        _seed_prune_propagated "$home" "$name" "$tmp_old" "$team"
        [[ -n "$tmp_old" ]] && rm -rf "$tmp_old"
    done
    remove_stale_shipped_skills "$home" "$team"          # Plan 338: old shipped names go away on upgrade
    printf '✅ Skills: %s seeded, %s refreshed (built-ins are Nyia-owned) → %s/skills/\n' "$seeded" "$refreshed" "$home"
    return 0
}

# ── Renamed shipped skills (Plan 237: pair-review/do-a-plan; Plan 338: the nyia- prefix) ─────────────────────
# old-name:new-name pairs. Consumed by seed_builtin_skills (the installer, every upgrade) and by
# scripts/cleanup-renamed-skills.sh (manual). User decision 2026-08-26: an old shipped name is DELETED from
# Nyia's base dirs on upgrade; user-defined and team skills are never touched.
NYIA_SKILL_RENAMES="pair-review:nyia-plan-review do-a-plan:nyia-make-a-plan kickoff:nyia-kickoff checkpoint:nyia-checkpoint code-review:nyia-code-review implement-plan:nyia-implement-plan make-a-plan:nyia-make-a-plan overlay:nyia-overlay plan-review:nyia-plan-review plan-status:nyia-plan-status run-plans:nyia-run-plans share:nyia-share show-decisions:nyia-show-decisions whatsup:nyia-whatsup"

# remove_stale_shipped_skills <nyia_home> [team_dir] [dry] [quiet]
#   For every old shipped name: delete <home>/skills/<old> (Nyia's base dir, Nyia's name — unconditional), and in
#   every known assistant dir (+ persona profiles) delete <old> ONLY when it is a shipped copy: it carries the
#   .nyia-builtin marker, or it is byte-identical to the global <old> copy (captured before that one is deleted).
#   Anything else is user-owned → kept and NAMED. Symlinks, the team dir and the project's shared skills are never
#   touched (team_dir accepted for symmetry, never scanned). dry=1 prints "would remove" and changes nothing;
#   quiet=1 (the launch path) prints only removals, never the "kept" lines. Always returns 0.
#   First upgrade off a pre-marker install (338 security review): a global old copy WITHOUT the marker may have been
#   edited in place (that was the supported customization before Plan 337) — it is MOVED to <home>/.removed-skills/
#   <stamp>/ (outside skill discovery) with a WARNING naming the path, never rm -rf'd; and an assistant copy deleted
#   because it is identical to that unmarked baseline is stashed there too. Marked copies are plainly deleted.
remove_stale_shipped_skills() {
    local home="$1" team="${2:-}" dry="${3:-0}" quiet="${4:-0}" pair old new g a d cand tmp_old removed=0
    [[ -n "$home" && -d "$home" ]] || return 0                       # never rm -rf with an empty/absent home
    local verb="removed" stash="" stamp; stamp="$(date +%Y%m%d-%H%M%S)"
    [[ "$dry" == "1" ]] && verb="would remove"
    local baseline_unmarked=0
    for pair in $NYIA_SKILL_RENAMES; do
        old="${pair%%:*}"; new="${pair#*:}"
        [[ "$old" == "$new" || -z "$old" ]] && continue
        g="$home/skills/$old"; tmp_old=""; baseline_unmarked=0
        if [[ -d "$g" && ! -L "$g" ]]; then
            tmp_old="$(mktemp -d "${TMPDIR:-/tmp}/nyia-old.XXXXXX")" || tmp_old=""
            [[ -n "$tmp_old" ]] && { cp -r "$g/." "$tmp_old/" 2>/dev/null || true; }
            if [[ -f "$g/.nyia-builtin" ]]; then
                [[ "$dry" == "1" ]] || rm -rf "$g"
                printf '   %s old shipped skill: %s (now %s)\n' "$verb" "$g" "$new"
            else
                baseline_unmarked=1
                if [[ "$dry" == "1" ]]; then
                    printf '   would move old skill (unmarked — possibly edited in place): %s → %s/.removed-skills/%s/%s (now %s)\n' "$g" "$home" "$stamp" "$old" "$new"
                else
                    stash="$home/.removed-skills/$stamp"; mkdir -p "$stash" 2>/dev/null || stash=""
                    if [[ -n "$stash" ]] && mv "$g" "$stash/$old" 2>/dev/null; then
                        printf '   WARNING: old skill %s was never refreshed by Nyia and may carry your edits — moved to %s/%s (now %s)\n' "$g" "$stash" "$old" "$new"
                    else
                        rm -rf "$g"; printf '   %s old shipped skill: %s (now %s; stash unavailable)\n' "$verb" "$g" "$new"
                    fi
                fi
            fi
            removed=$((removed + 1))
        fi
        for a in $NYIA_SEED_ASSISTANTS; do
            for d in "$home/$a/skills" "$home"/profiles/*/"$a"/skills; do
                cand="$d/$old"
                [[ -d "$cand" && ! -L "$cand" && ! -L "$d" ]] || continue
                if [[ -f "$cand/.nyia-builtin" ]]; then
                    [[ "$dry" == "1" ]] || rm -rf "$cand"
                    printf '   %s old shipped copy: %s (now %s)\n' "$verb" "$cand" "$new"; removed=$((removed + 1))
                elif [[ -n "$tmp_old" && -d "$tmp_old" ]] && _seed_same_tree "$cand" "$tmp_old"; then
                    # identical to the global copy: a propagated clone. If that baseline was UNMARKED it may carry
                    # edits → stash the clone next to it instead of deleting.
                    if [[ "$dry" == "1" ]]; then
                        printf '   %s old shipped copy: %s (now %s)\n' "$verb" "$cand" "$new"
                    elif [[ "$baseline_unmarked" -eq 1 && -n "$stash" ]] && mkdir -p "$stash/$a" 2>/dev/null && mv "$cand" "$stash/$a/$old" 2>/dev/null; then
                        printf '   moved old copy (identical to the unmarked global one): %s → %s/%s/%s\n' "$cand" "$stash" "$a" "$old"
                    else
                        rm -rf "$cand"; printf '   %s old shipped copy: %s (now %s)\n' "$verb" "$cand" "$new"
                    fi
                    removed=$((removed + 1))
                elif [[ "$quiet" != "1" ]]; then
                    printf '   kept (user-owned, old name %s): %s\n' "$old" "$cand"
                fi
            done
        done
        [[ -n "$tmp_old" ]] && rm -rf "$tmp_old"
    done
    [[ "$removed" -gt 0 ]] && printf '   %s %s old-named shipped skill dir(s); the same skills are now nyia-*\n' "$verb" "$removed"
    return 0
}
