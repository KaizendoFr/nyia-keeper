#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later OR Proprietary
# Copyright (c) 2024 Nyia Keeper Contributors
#
# Marketplace Sync Module (Plan 246a)
# Fetches a Git-backed private/team marketplace (skills + agents) to a local
# cache and returns the cached content path. The cached `skills/` and `agents/`
# subdirs are then fed to the EXISTING propagators (propagate_team_skills /
# propagate_team_agents), so there is no new copy logic here.
#
# FAIL-OPEN is sacred: any failure (no URL, network, auth, timeout, corruption)
# results in a warning and a fall back to the existing cache (or empty) — this
# function ALWAYS returns 0 and NEVER blocks a launch.

# Guard against double-sourcing
if [[ -n "${_NYIA_MARKETPLACE_SYNC_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
_NYIA_MARKETPLACE_SYNC_LOADED=1

# === DEFAULTS / TUNABLES ===
# Cache root for the marketplace working copy.
: "${NYIA_MARKETPLACE_CACHE_DIR:=${HOME}/.cache/nyiakeeper/marketplace}"
# Hard timeouts (seconds). Pull is cheap (≤10s); shallow clone is heavier (≤30s).
: "${NYIA_MARKETPLACE_PULL_TIMEOUT:=10}"
: "${NYIA_MARKETPLACE_CLONE_TIMEOUT:=30}"

# Last sync status, set by sync_marketplace() for the launch status line (R8).
# Values: "synced" | "offline-cached" | "not-configured"
NYIA_MARKETPLACE_STATUS="not-configured"
# Count of skill+agent items present in the cache after a successful sync.
NYIA_MARKETPLACE_ITEM_COUNT=0
# Cached content path (with skills/ and agents/), or empty. Set as a side-effect
# variable so callers get the path AND the status without a subshell ($(...)),
# which would discard the status/count variable updates.
NYIA_MARKETPLACE_PATH=""

# --- internal: warning helper -------------------------------------------------
# Use the host's print_warning if available, else a plain stderr line.
_mp_warn() {
    if declare -f print_warning >/dev/null 2>&1; then
        print_warning "$*"
    else
        echo "Warning: $*" >&2
    fi
}

_mp_verbose() {
    if declare -f print_verbose >/dev/null 2>&1; then
        print_verbose "$*"
    fi
}

# --- internal: normalize a marketplace URL for cache-keying/comparison --------
# Strips one trailing slash and a trailing .git so equivalent URLs map to the
# same cache, while genuinely different URLs map to different caches.
_mp_normalize_url() {
    local u="$1"
    u="${u%/}"
    u="${u%.git}"
    printf '%s' "$u"
}

# --- internal: stable short cache key derived from the normalized URL ---------
# Keying the cache by URL prevents a different configured URL (e.g. a project
# override) from being served the previously-cached marketplace (Plan 246a fix).
_mp_url_key() {
    local u="$1" h
    if command -v sha256sum >/dev/null 2>&1; then
        h="$(printf '%s' "$u" | sha256sum | awk '{print $1}')"
    elif command -v shasum >/dev/null 2>&1; then
        h="$(printf '%s' "$u" | shasum -a 256 | awk '{print $1}')"
    else
        h="$(printf '%s' "$u" | cksum | tr -d ' ')"
    fi
    printf '%s' "${h:0:16}"
}

# --- internal: bounded git runner (portable) ----------------------------------
# Runs `git` with hard timeouts and a non-interactive environment, so a dead
# host, an auth prompt, or a stalled transfer can NEVER hang a launch.
#
# Bounding strategy (defense in depth, so a dead host can NEVER hang a launch):
#   1. SSH:  -oConnectTimeout bounds connect; ServerAlive* bounds a stalled
#            transfer (GIT_HTTP_LOW_SPEED_* does NOT cover SSH).
#   2. HTTP: GIT_HTTP_LOW_SPEED_* bounds a stalled transfer.
#   3. Wall: `timeout`/`gtimeout` if present; otherwise a portable bash watchdog
#            that kills git after the bound — so the guarantee holds on macOS
#            even with neither coreutils binary installed.
# (NYIA_MP_FORCE_NO_TIMEOUT=1 forces the watchdog path — test seam only.)
#
# Usage: _mp_run_git <seconds> <git-args...>
_mp_run_git() {
    local secs="$1"; shift
    local ssh_cmd="ssh -oBatchMode=yes -oStrictHostKeyChecking=accept-new"
    ssh_cmd+=" -oConnectTimeout=${secs} -oServerAliveInterval=5 -oServerAliveCountMax=2"
    local -a envv=(
        GIT_TERMINAL_PROMPT=0
        "GIT_SSH_COMMAND=${ssh_cmd}"
        GIT_HTTP_LOW_SPEED_LIMIT=1000
        "GIT_HTTP_LOW_SPEED_TIME=${secs}"
    )

    if [[ -z "${NYIA_MP_FORCE_NO_TIMEOUT:-}" ]] && command -v timeout >/dev/null 2>&1; then
        env "${envv[@]}" timeout "${secs}s" git "$@"
        return $?
    elif [[ -z "${NYIA_MP_FORCE_NO_TIMEOUT:-}" ]] && command -v gtimeout >/dev/null 2>&1; then
        env "${envv[@]}" gtimeout "${secs}s" git "$@"
        return $?
    fi

    # No timeout binary → portable watchdog: bound git ourselves.
    env "${envv[@]}" git "$@" &
    local gitpid=$!
    (
        sleep "$secs"
        kill -TERM "$gitpid" 2>/dev/null
        sleep 2
        kill -KILL "$gitpid" 2>/dev/null
    ) >/dev/null 2>&1 &
    local wdpid=$!
    local rc=0
    wait "$gitpid" 2>/dev/null || rc=$?
    kill -TERM "$wdpid" 2>/dev/null || true
    wait "$wdpid" 2>/dev/null || true
    return "$rc"
}

# --- internal: count skill dirs + agent files in a cache path -----------------
_mp_count_items() {
    local base="$1"
    local count=0
    local d f
    if [[ -d "$base/skills" ]]; then
        for d in "$base/skills"/*/; do
            [[ -d "$d" && -f "$d/SKILL.md" ]] && count=$((count + 1))
        done
    fi
    if [[ -d "$base/agents" ]]; then
        for f in "$base/agents"/*; do
            [[ -f "$f" ]] || continue
            [[ "$(basename "$f")" == .* ]] && continue
            count=$((count + 1))
        done
    fi
    echo "$count"
}

# === PUBLIC: sync_marketplace ================================================
# Resolves NYIA_MARKETPLACE_URL (project > global), then clones (first time) or
# pulls (subsequent) into a local cache using an atomic, lock-guarded update.
#
# Arguments:
#   $1 - project path (optional — enables project-level marketplace_url)
#
# Output:
#   Prints the cached content path (containing skills/ and agents/) to stdout on
#   success or when falling back to an existing cache. Prints nothing if there is
#   no configured URL and no usable cache.
#
# Side effects:
#   Sets NYIA_MARKETPLACE_STATUS and NYIA_MARKETPLACE_ITEM_COUNT.
#
# Return: ALWAYS 0 (fail-open — never blocks launch).
sync_marketplace() {
    local project_path="${1:-}"

    NYIA_MARKETPLACE_STATUS="not-configured"
    NYIA_MARKETPLACE_ITEM_COUNT=0
    NYIA_MARKETPLACE_PATH=""

    # --- Resolve the configured URL (project > global > none) ---
    local url=""
    if declare -f _resolve_marketplace_url_config >/dev/null 2>&1; then
        local resolved
        resolved=$(_resolve_marketplace_url_config "$project_path")
        url="${resolved%%	*}"
    fi

    local cache_root="$NYIA_MARKETPLACE_CACHE_DIR"

    # --- Not configured: silent no-op.
    if [[ -z "$url" ]]; then
        NYIA_MARKETPLACE_STATUS="not-configured"
        return 0
    fi

    # --- Validate URL syntactically (defense in depth; config also validates).
    if declare -f validate_marketplace_url >/dev/null 2>&1; then
        if ! validate_marketplace_url "$url"; then
            _mp_warn "Marketplace URL is malformed — skipping marketplace sync: $url"
            # No per-URL cache exists for a malformed URL → nothing to serve.
            return 0
        fi
    fi

    # --- Key the cache by the (normalized) URL so a DIFFERENT configured URL
    #     (e.g. a project override) is never served the previously-cached
    #     marketplace. Each distinct URL gets its own cache subdir.
    local norm_url cache_dir
    norm_url="$(_mp_normalize_url "$url")"
    cache_dir="${cache_root}/$(_mp_url_key "$norm_url")"

    # --- Ensure the cache root exists.
    if ! mkdir -p "$cache_root" 2>/dev/null; then
        _mp_warn "Cannot create marketplace cache dir: $cache_root — skipping marketplace sync"
        return 0
    fi

    # --- Concurrency lock (atomic mkdir). If another launch holds it, just use
    #     whatever cache currently exists — never wait, never block.
    local lock_dir="${cache_dir}.lock"
    if ! mkdir "$lock_dir" 2>/dev/null; then
        _mp_verbose "Marketplace sync already in progress (lock held) — using existing cache"
        _mp_use_cache_or_empty "$cache_dir"
        return 0
    fi
    # Release lock on any exit path of this function via RETURN trap scope.
    # (We remove it explicitly at each return below to keep behavior obvious.)

    # --- Insurance: if a repo is cached under this URL key, verify its origin
    #     still matches before pulling; otherwise discard and reclone.
    if [[ -d "$cache_dir/.git" ]]; then
        local cached_origin
        cached_origin="$(git -C "$cache_dir" remote get-url origin 2>/dev/null)"
        if [[ "$(_mp_normalize_url "$cached_origin")" != "$norm_url" ]]; then
            _mp_verbose "Cached marketplace origin mismatch — recloning for: $url"
            rm -rf "$cache_dir" 2>/dev/null || true
        fi
    fi

    # --- Cache exists with a matching git repo → pull --ff-only (fast, bounded).
    if [[ -d "$cache_dir/.git" ]]; then
        if _mp_run_git "$NYIA_MARKETPLACE_PULL_TIMEOUT" \
                -C "$cache_dir" pull --ff-only --quiet 2>/dev/null; then
            rmdir "$lock_dir" 2>/dev/null || true
            NYIA_MARKETPLACE_STATUS="synced"
            NYIA_MARKETPLACE_ITEM_COUNT="$(_mp_count_items "$cache_dir")"
            NYIA_MARKETPLACE_PATH="$cache_dir"
            _mp_verbose "Marketplace synced (pull): $url"
            echo "$cache_dir"
            return 0
        fi
        # Pull failed (offline/auth/timeout/non-ff) → fall back to cache.
        rmdir "$lock_dir" 2>/dev/null || true
        _mp_warn "Marketplace update failed (offline or auth?) — using cached content. Check your git credentials if this persists."
        NYIA_MARKETPLACE_STATUS="offline-cached"
        NYIA_MARKETPLACE_ITEM_COUNT="$(_mp_count_items "$cache_dir")"
        NYIA_MARKETPLACE_PATH="$cache_dir"
        echo "$cache_dir"
        return 0
    fi

    # --- No cache yet → shallow clone into a temp dir, then atomic rename.
    local tmp_dir="${cache_dir}.tmp.$$"
    rm -rf "$tmp_dir" 2>/dev/null || true
    if _mp_run_git "$NYIA_MARKETPLACE_CLONE_TIMEOUT" \
            clone --depth 1 --quiet "$url" "$tmp_dir" 2>/dev/null; then
        # Atomic-ish swap: remove any stale (non-git) cache, then rename temp in.
        rm -rf "$cache_dir" 2>/dev/null || true
        if mv "$tmp_dir" "$cache_dir" 2>/dev/null; then
            rmdir "$lock_dir" 2>/dev/null || true
            NYIA_MARKETPLACE_STATUS="synced"
            NYIA_MARKETPLACE_ITEM_COUNT="$(_mp_count_items "$cache_dir")"
            NYIA_MARKETPLACE_PATH="$cache_dir"
            _mp_verbose "Marketplace cloned: $url"
            echo "$cache_dir"
            return 0
        fi
        # Rename failed — clean up temp, fall through to cache/empty.
        rm -rf "$tmp_dir" 2>/dev/null || true
    else
        # Clone failed → clean up partial temp.
        rm -rf "$tmp_dir" 2>/dev/null || true
    fi

    rmdir "$lock_dir" 2>/dev/null || true
    _mp_warn "Marketplace clone failed (offline or auth?) — launching without marketplace content. Check your git credentials if this persists."
    _mp_use_cache_or_empty "$cache_dir"
    return 0
}

# --- internal: emit an existing cache path or nothing -------------------------
# Sets status to offline-cached when a usable cache exists, else not-configured.
_mp_use_cache_or_empty() {
    local cache_dir="$1"
    if [[ -d "$cache_dir/skills" || -d "$cache_dir/agents" ]]; then
        NYIA_MARKETPLACE_STATUS="offline-cached"
        NYIA_MARKETPLACE_ITEM_COUNT="$(_mp_count_items "$cache_dir")"
        NYIA_MARKETPLACE_PATH="$cache_dir"
        echo "$cache_dir"
    else
        # No usable cache; leave status as set by caller (not-configured/offline).
        :
    fi
}
