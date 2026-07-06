#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later OR Proprietary
#
# Git history cutoff — Phase B (Plan 278b): lifecycle for the assistant's commits
# that land in the protected shallow `.git` (built by lib/git-history-cutoff.sh).
#
# The shallow preserves real SHAs, so new commits attach cleanly to real history —
# but bringing them back is ALWAYS an explicit, reviewed user action, NEVER
# automatic. This library powers `nyia git-history status|reconcile|rebuild`.
#
# Security/contract invariants:
#   - reconcile defaults to REVIEW (read-only). --apply imports into a NAMESPACED
#     ref (refs/nyia-shallow/<branch>), never force-updates real branches, never
#     auto-merges. --discard drops pending state only, never touches real history.
#   - rebuild refuses to run while commits are pending (would destroy AI work).
#   - reconcile/rebuild are serialized by a lock under .nyiakeeper/git-shallow/.

# Load guard.
if [[ -n "${_NYIA_GIT_HISTORY_RECONCILE_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
_NYIA_GIT_HISTORY_RECONCILE_LOADED=1

# Fixed on-disk location of the protected shallow, relative to the project root.
# Persisted (not /tmp) so a crash mid-session loses nothing.
_git_history_shallow_dir() { echo "$1/.nyiakeeper/git-shallow"; }

# detect_pending_shallow_commits <real_repo> <shallow_dir>
# Prints (newest-first) the SHAs present in the shallow's current branch but NOT
# in the real repo — i.e. the assistant's un-reconciled commits. Prints nothing
# when there is no shallow or nothing pending. Robust to the real tip having
# advanced on the host (it checks object presence, not ancestry).
detect_pending_shallow_commits() {
    local real="$1"
    local shallow="$2"
    [[ -d "$shallow/.git" ]] || return 0

    local branch
    branch=$(git -C "$shallow" rev-parse --abbrev-ref HEAD 2>/dev/null) || return 0

    local sha
    while IFS= read -r sha; do
        [[ -z "$sha" ]] && continue
        # Not present as a commit object in the real repo => pending (new) work.
        if ! git -C "$real" cat-file -e "${sha}^{commit}" 2>/dev/null; then
            echo "$sha"
        fi
    done < <(git -C "$shallow" rev-list "$branch" 2>/dev/null)
}

# _git_history_lock <shallow_dir>  -> prints lock path on success, non-zero if held.
# Records the holder PID so a lock left by a killed process (which the RETURN trap
# can't release) is reclaimed on the next run instead of wedging the feature.
_git_history_lock() {
    local shallow="$1"
    mkdir -p "$shallow" 2>/dev/null || true
    local lockdir="$shallow/.reconcile.lock"
    if ! mkdir "$lockdir" 2>/dev/null; then
        local oldpid=""
        [[ -f "$lockdir/pid" ]] && oldpid="$(cat "$lockdir/pid" 2>/dev/null)"
        if [[ -n "$oldpid" ]] && ! kill -0 "$oldpid" 2>/dev/null; then
            # Holder is dead — reclaim the stale lock.
            rm -rf "$lockdir"
            mkdir "$lockdir" 2>/dev/null || {
                echo "git-history: could not reclaim stale lock ($lockdir)" >&2; return 1; }
        else
            echo "git-history: another reconcile/rebuild is in progress ($lockdir)" >&2
            echo "  (if no other run is active, remove it: rmdir '$lockdir')" >&2
            return 1
        fi
    fi
    echo "$$" > "$lockdir/pid" 2>/dev/null || true
    echo "$lockdir"
}
# Remove the lock dir (and its pid file). rm -rf because it may contain pid.
_git_history_unlock() { [[ -n "$1" ]] && rm -rf "$1" 2>/dev/null || true; }

# git_history_status <project_path>
# Reports the configured cutoff, shallow presence, and pending commits. Read-only.
git_history_status() {
    local project="$1"
    local shallow
    shallow="$(_git_history_shallow_dir "$project")"

    local cutoff=""
    if declare -f resolve_config_value_raw >/dev/null 2>&1; then
        cutoff=$(resolve_config_value_raw "NYIA_GIT_HISTORY_CUTOFF" "" "$project")
    fi

    echo "Git history cutoff status:"
    if [[ -z "$cutoff" ]]; then
        echo "  Cutoff:  (not configured)"
        echo "  Set one: nyia config project git_history_cutoff=YYYY-MM-DD"
    else
        echo "  Cutoff:  $cutoff"
    fi

    if [[ ! -d "$shallow/.git" ]]; then
        echo "  Shallow: (none built yet — created on next launch)"
        return 0
    fi
    echo "  Shallow: $shallow"

    local pending
    pending="$(detect_pending_shallow_commits "$project" "$shallow")"
    if [[ -z "$pending" ]]; then
        echo "  Pending: none (no un-reconciled assistant commits)"
    else
        local count
        count=$(echo "$pending" | grep -c .)
        echo "  Pending: $count un-reconciled commit(s) in the protected session"
        echo "  Review:  nyia git-history reconcile"
    fi
}

# git_history_reconcile <project_path> <mode>   mode: review|apply|discard
# Default (review) is READ-ONLY. apply imports under refs/nyia-shallow/<branch>;
# discard drops the pending shallow. Serialized by a lock for apply/discard.
git_history_reconcile() {
    local project="$1"
    local mode="${2:-review}"
    local shallow
    shallow="$(_git_history_shallow_dir "$project")"

    if [[ ! -d "$shallow/.git" ]]; then
        echo "git-history: nothing to reconcile (no protected shallow at $shallow)" >&2
        return 0
    fi

    local branch
    branch=$(git -C "$shallow" rev-parse --abbrev-ref HEAD 2>/dev/null) || {
        echo "git-history: cannot resolve shallow branch" >&2; return 1; }

    local pending
    pending="$(detect_pending_shallow_commits "$project" "$shallow")"

    case "$mode" in
        review) _git_history_review "$project" "$shallow" "$branch" "$pending" ;;
        apply)  _git_history_apply  "$project" "$shallow" "$branch" "$pending" ;;
        discard) _git_history_discard "$shallow" "$pending" ;;
        *) echo "git-history: unknown reconcile mode: $mode" >&2; return 1 ;;
    esac
}

# Review = list pending commits + show the diff vs the real tip. No writes.
_git_history_review() {
    local project="$1" shallow="$2" branch="$3" pending="$4"
    if [[ -z "$pending" ]]; then
        echo "No pending commits — the protected session matches the real repo."
        return 0
    fi
    echo "Pending commits in the protected session (branch: $branch):"
    # --no-walk: list ONLY the pending SHAs, not their ancestors (which include the
    # real tip). $pending stays unquoted so each SHA is a separate rev.
    git -C "$shallow" log --oneline --no-decorate --no-walk $pending 2>/dev/null | sed 's/^/  /'
    echo ""
    local real_tip
    real_tip=$(git -C "$project" rev-parse "$branch" 2>/dev/null)
    if [[ -n "$real_tip" ]]; then
        echo "Diff vs real $branch ($real_tip):"
        git -C "$shallow" --no-pager diff "${real_tip}..${branch}" 2>/dev/null \
            || echo "  (real tip not in shallow — history diverged on the host)"
    fi
    echo ""
    echo "To import (non-destructive):  nyia git-history reconcile --apply"
    echo "To drop them:                 nyia git-history reconcile --discard"
}

# Apply = fetch the shallow branch into a namespaced ref in the real repo.
# Non-forced, never touches real branches, never merges.
_git_history_apply() {
    local project="$1" shallow="$2" branch="$3" pending="$4"
    if [[ -z "$pending" ]]; then
        echo "No pending commits to apply."
        return 0
    fi
    local lock
    lock="$(_git_history_lock "$shallow")" || return 1
    # Release the lock even if interrupted, so a crash never wedges the feature.
    trap '_git_history_unlock "$lock"' RETURN

    local target="refs/nyia-shallow/$branch"
    if git -C "$project" fetch --no-tags "$shallow/.git" \
            "refs/heads/$branch:$target" 2>/dev/null; then
        _git_history_unlock "$lock"
        echo "Imported the protected session into $target (real branches untouched)."
        echo ""
        echo "Integrate it however you prefer, e.g.:"
        echo "  git merge $target"
        echo "  git rebase $target"
        echo "  git cherry-pick <sha>   # individual commits"
        return 0
    fi
    _git_history_unlock "$lock"
    echo "git-history: import failed (fetch from shallow into $target)" >&2
    return 1
}

# Discard = remove the protected shallow entirely. Real repo is never touched.
_git_history_discard() {
    local shallow="$1" pending="$2"
    local lock
    lock="$(_git_history_lock "$shallow")" || return 1
    # Release the lock even if interrupted, so a crash never wedges the feature.
    trap '_git_history_unlock "$lock"' RETURN
    rm -rf "$shallow"
    _git_history_unlock "$lock"
    echo "Discarded the protected session. The real repository was not modified."
}

# git_history_rebuild <project_path>
# Refresh the shallow ONLY when nothing is pending (a rebuild over pending commits
# would destroy the assistant's un-reconciled work). Blocking is destructive-only.
git_history_rebuild() {
    local project="$1"
    local shallow
    shallow="$(_git_history_shallow_dir "$project")"

    local pending
    pending="$(detect_pending_shallow_commits "$project" "$shallow")"
    if [[ -n "$pending" ]]; then
        echo "git-history: refusing to rebuild — un-reconciled commits are pending." >&2
        echo "Run 'nyia git-history reconcile' (review/apply/discard) first." >&2
        return 1
    fi

    local cutoff=""
    if declare -f resolve_config_value_raw >/dev/null 2>&1; then
        cutoff=$(resolve_config_value_raw "NYIA_GIT_HISTORY_CUTOFF" "" "$project")
    fi
    if [[ -z "$cutoff" ]]; then
        echo "git-history: no cutoff configured; nothing to rebuild." >&2
        echo "Set one: nyia config project git_history_cutoff=YYYY-MM-DD" >&2
        return 1
    fi

    local lock
    lock="$(_git_history_lock "$shallow")" || return 1
    # Release the lock even if interrupted, so a crash never wedges the feature.
    trap '_git_history_unlock "$lock"' RETURN
    rm -rf "$shallow"
    if declare -f build_protected_shallow_git >/dev/null 2>&1 \
            && build_protected_shallow_git "$project" "$cutoff" "$shallow"; then
        _git_history_unlock "$lock"
        echo "Rebuilt the protected shallow (cutoff: $cutoff)."
        return 0
    fi
    _git_history_unlock "$lock"
    echo "git-history: rebuild failed." >&2
    return 1
}

# === WORKSPACE (multi-repo) SUPPORT (Plan 278c) ===
# The cutoff feature is per-repo: each member repo has its own history, its own
# cutoff config, and its own protected shallow. These helpers iterate the workspace
# members and aggregate/route the single-repo operations above.

# workspace_git_repos <workspace_root>
# Prints one TAB-separated line per cutoff-candidate repo: "<repo_path>\t<rw|ro>".
# The ROOT is included (mode rw) IFF it is itself a git repo (it is NOT listed in
# workspace.conf). Member repos come from parse_workspace_repos(); only those that
# are git repos are emitted (RO non-git dirs have no .git and no history to protect).
workspace_git_repos() {
    local root="$1"
    if [[ -d "$root/.git" ]]; then
        printf '%s\trw\n' "$root"
    fi
    declare -f parse_workspace_repos >/dev/null 2>&1 || return 0

    local -a _repos=() _modes=()
    mapfile -t _repos < <(parse_workspace_repos "$root")
    if declare -f parse_workspace_modes >/dev/null 2>&1; then
        mapfile -t _modes < <(parse_workspace_modes "$root")
    fi
    local i
    for i in "${!_repos[@]}"; do
        local rp="${_repos[$i]}"
        [[ -z "$rp" || ! -d "$rp/.git" ]] && continue
        printf '%s\t%s\n' "$rp" "${_modes[$i]:-ro}"
    done
}

# git_history_workspace_status <workspace_root> — per-repo aggregated table.
git_history_workspace_status() {
    local root="$1"
    echo "Git history cutoff — workspace status:"
    local repo mode
    while IFS=$'\t' read -r repo mode; do
        [[ -z "$repo" ]] && continue
        local cutoff="none" protected="no" pending_count=0
        if declare -f resolve_config_value_raw >/dev/null 2>&1; then
            local c
            c=$(resolve_config_value_raw "NYIA_GIT_HISTORY_CUTOFF" "" "$repo")
            [[ -n "$c" ]] && cutoff="$c"
        fi
        local shallow="$repo/.nyiakeeper/git-shallow"
        [[ -d "$shallow/.git" ]] && protected="yes"
        local pending
        pending="$(detect_pending_shallow_commits "$repo" "$shallow")"
        [[ -n "$pending" ]] && pending_count=$(echo "$pending" | grep -c .)
        printf '  %-24s mode=%-2s cutoff=%-12s protected=%-3s pending=%s\n' \
            "$(basename "$repo")" "$mode" "$cutoff" "$protected" "$pending_count"
    done < <(workspace_git_repos "$root")
}

# git_history_workspace_reconcile <workspace_root> <mode> [selector_path]
# Iterates RW repos (RO repos take no AI commits, nothing to reconcile). An optional
# selector restricts to one repo path. Per-repo review is the default mode.
git_history_workspace_reconcile() {
    local root="$1" mode="${2:-review}" selector="${3:-}"
    local repo wmode found=0
    while IFS=$'\t' read -r repo wmode; do
        [[ -z "$repo" ]] && continue
        [[ "$wmode" != "rw" ]] && continue
        [[ -n "$selector" && "$repo" != "$selector" ]] && continue
        found=1
        echo "=== $repo ==="
        git_history_reconcile "$repo" "$mode"
        echo ""
    done < <(workspace_git_repos "$root")
    if [[ "$found" -eq 0 ]]; then
        echo "git-history: no matching RW workspace repo to reconcile." >&2
        return 1
    fi
}

# git_history_workspace_rebuild <workspace_root> [selector_path] — per-repo rebuild.
git_history_workspace_rebuild() {
    local root="$1" selector="${2:-}"
    local repo wmode
    while IFS=$'\t' read -r repo wmode; do
        [[ -z "$repo" || "$wmode" != "rw" ]] && continue
        [[ -n "$selector" && "$repo" != "$selector" ]] && continue
        echo "=== $repo ==="
        git_history_rebuild "$repo" || true   # per-repo; one failure does not abort others
    done < <(workspace_git_repos "$root")
}

# _git_history_is_workspace <path> — true if the path is a workspace root.
_git_history_is_workspace() { [[ -f "$1/.nyiakeeper/workspace.conf" ]]; }

# nyia_git_history_command <project_path> <args...>
# Dispatcher entry: status | reconcile [--apply|--discard] [--repo P] | rebuild.
# Auto-detects workspace mode (workspace.conf present) and aggregates per-repo.
nyia_git_history_command() {
    local project="$1"; shift
    local action="${1:-status}"; shift 2>/dev/null || true
    local is_ws="false"
    _git_history_is_workspace "$project" && is_ws="true"

    case "$action" in
        status)
            if [[ "$is_ws" == "true" ]]; then git_history_workspace_status "$project"
            else git_history_status "$project"; fi
            ;;
        reconcile)
            local mode="review" selector=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --apply) mode="apply" ;;
                    --discard) mode="discard" ;;
                    --repo) shift; selector="$1" ;;
                    *) echo "git-history: unknown reconcile flag: $1" >&2; return 1 ;;
                esac
                shift
            done
            if [[ "$is_ws" == "true" ]]; then
                git_history_workspace_reconcile "$project" "$mode" "$selector"
            else
                git_history_reconcile "$project" "$mode"
            fi
            ;;
        rebuild)
            local selector=""
            [[ "${1:-}" == "--repo" ]] && { shift; selector="$1"; }
            if [[ "$is_ws" == "true" ]]; then git_history_workspace_rebuild "$project" "$selector"
            else git_history_rebuild "$project"; fi
            ;;
        help|--help|-h)
            echo "Usage: nyia git-history <status|reconcile|rebuild>"
            echo "  status                    Show cutoff, shallow, and pending commits"
            echo "  reconcile                 Review pending commits (read-only, default)"
            echo "  reconcile --apply         Import pending commits into refs/nyia-shallow/<branch>"
            echo "  reconcile --discard       Drop the protected session (real repo untouched)"
            echo "  rebuild                   Rebuild the shallow (only when nothing pending)"
            echo ""
            echo "In a workspace, status aggregates all member repos and reconcile/rebuild"
            echo "iterate the RW repos; restrict with: reconcile --repo <path>"
            ;;
        *) echo "git-history: unknown action: $action" >&2; return 1 ;;
    esac
}
