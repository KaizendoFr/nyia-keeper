#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later OR Proprietary
#
# Git history cutoff (Plan 278a) — build a history-truncated, object-isolated
# shallow `.git` so the assistant container can use recent history but cannot
# read pre-cutoff commits (where un-rotated secrets may live). The mount that
# layers this over the project `.git` is the launch path's job; this library is
# the security-critical build + verification, fully testable with real git.
#
# Load guard.
if [[ -n "${_NYIA_GIT_HISTORY_CUTOFF_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
_NYIA_GIT_HISTORY_CUTOFF_LOADED=1

# build_protected_shallow_git <repo_path> <cutoff> <dest_dir>
# Builds an object-isolated shallow clone of <repo_path>'s current branch since
# <cutoff> (date YYYY-MM-DD or tag) into <dest_dir>. FAIL-CLOSED: returns non-zero
# and removes <dest_dir> on any error or failed isolation check — callers MUST NOT
# fall back to the full `.git`.
build_protected_shallow_git() {
    local repo_path="$1"
    local cutoff="$2"
    local dest="$3"

    if [[ -z "$repo_path" || -z "$cutoff" || -z "$dest" ]]; then
        echo "build_protected_shallow_git: repo_path, cutoff and dest are required" >&2
        return 1
    fi
    # A `.git` directory (not a gitfile/submodule — unsupported in v1).
    if [[ ! -d "$repo_path/.git" ]]; then
        echo "build_protected_shallow_git: not a standard git repo (no .git dir): $repo_path" >&2
        return 1
    fi

    local branch
    branch=$(git -C "$repo_path" rev-parse --abbrev-ref HEAD 2>/dev/null) || {
        echo "build_protected_shallow_git: cannot resolve current branch" >&2
        return 1
    }

    # Date -> --shallow-since; anything else (a tag/ref) -> --shallow-exclude.
    local shallow_arg
    if [[ "$cutoff" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        shallow_arg="--shallow-since=$cutoff"
    else
        shallow_arg="--shallow-exclude=$cutoff"
    fi

    local abs_repo
    abs_repo="$(cd "$repo_path" && pwd)" || return 1

    rm -rf "$dest"
    # file:// + --no-local is LOAD-BEARING: a plain/local clone hardlinks or sets
    # objects/info/alternates back to the real store, re-exposing every object.
    if ! git clone --quiet --no-local "$shallow_arg" --branch "$branch" \
            "file://$abs_repo" "$dest" 2>/dev/null; then
        echo "build_protected_shallow_git: shallow clone failed (cutoff=$cutoff)" >&2
        rm -rf "$dest"
        return 1
    fi

    # Strip the origin remote (and any file:// remotes) so `git fetch --unshallow`
    # / --deepen cannot recover pre-cutoff objects (review H1).
    git -C "$dest" remote remove origin 2>/dev/null || true
    local r
    for r in $(git -C "$dest" remote 2>/dev/null); do
        git -C "$dest" remote remove "$r" 2>/dev/null || true
    done

    # Fail-closed isolation checks.
    if ! verify_protected_shallow_git "$dest"; then
        echo "build_protected_shallow_git: isolation verification failed; refusing." >&2
        rm -rf "$dest"
        return 1
    fi
    return 0
}

# verify_protected_shallow_git <dest_dir>
# Asserts the built shallow is object-isolated: no alternates, no remotes, it IS
# shallow, and unshallow/deepen cannot recover objects. Returns non-zero if any
# check fails (used both at build time and as a live mount assertion).
verify_protected_shallow_git() {
    local dest="$1"
    local gitdir="$dest/.git"
    [[ -d "$gitdir" ]] || { echo "verify: no .git at $dest" >&2; return 1; }

    # 1. No alternates linking back to the real object store.
    if [[ -e "$gitdir/objects/info/alternates" ]]; then
        echo "verify: objects/info/alternates present (NOT isolated)" >&2
        return 1
    fi
    # 2. It must actually be shallow.
    if [[ ! -f "$gitdir/shallow" ]]; then
        echo "verify: not a shallow clone (.git/shallow missing)" >&2
        return 1
    fi
    # 3. No remotes. This is THE guarantee: with no remote configured, git
    #    fetch --unshallow/--deepen has no source and recovers nothing (it
    #    exits 0 as a harmless no-op — verified — but pulls back zero objects).
    if [[ -n "$(git -C "$dest" remote 2>/dev/null)" ]]; then
        echo "verify: a remote remains (unshallow could recover objects)" >&2
        return 1
    fi
    return 0
}

# prepare_git_history_cutoff_mount <project_path> <container_path> <cutoff> <dest>
# When <cutoff> is set, builds the protected shallow at <dest>, copies the real
# index (so uncommitted changes show), and prints the docker volume SPEC to layer
# the shallow `.git` over the container's `<container_path>/.git`. The caller does:
#     spec=$(prepare_git_history_cutoff_mount ...) || refuse-launch  # FAIL CLOSED
#     [[ -n "$spec" ]] && VOLUME_ARGS+=(-v "$spec")
# Empty cutoff => prints nothing, returns 0 (feature off). Build failure => non-zero.
prepare_git_history_cutoff_mount() {
    local project_path="$1"
    local container_path="$2"
    local cutoff="$3"
    local dest="$4"

    [[ -z "$cutoff" ]] && return 0  # feature off — full history, today's behavior

    if ! build_protected_shallow_git "$project_path" "$cutoff" "$dest"; then
        return 1  # fail-closed: caller must refuse to launch with the full .git
    fi

    # Copy the real index so the working tree's uncommitted changes are tracked.
    if [[ -f "$project_path/.git/index" ]]; then
        cp -f "$project_path/.git/index" "$dest/.git/index" 2>/dev/null || true
    fi

    printf '%s\n' "$dest/.git:$container_path/.git:rw"
    return 0
}
