#!/usr/bin/env bash
# lib/plan-resolution.sh — Plan 331a: the single routing resolver (dual-shape during migration).
#
# The ONE routing rule all skills/tools use:
#   - A plan N lives at plans/N-slug/ (NEW), body = plan.md; reviews + Plan 259 state in reviews/.
#   - OR legacy flat plans/N-slug.md (during the 331b migration window — dual-shape).
#   - Subplans are SIBLING plan dirs plans/Na-slug/, resolved by their full id (e.g. "331a").
#   - "meta" = a plan.md carrying a `## Subplans` table (a relationship, NOT nesting).
#   - Exact number + separator match: "33" never resolves "330" (the char after the number must be '-').
#
# NYIA_PLANS_DIR selects the plans root (default .nyiakeeper/plans) — overridable for tests.

NYIA_PLANS_DIR="${NYIA_PLANS_DIR:-.nyiakeeper/plans}"

# resolve_plan_file <N> — print the plan BODY path and return 0; return non-zero (no output) if absent.
# Prefers the new dir shape over a legacy flat file; never returns a review satellite.
resolve_plan_file() {
    local n="$1" d f base
    [[ "$n" =~ ^[0-9]+[a-z]?$ ]] || return 2   # shape guard: exact NNN[a] only (no glob/traversal)
    # New shape: plans/N-*/plan.md  (the trailing '-' enforces exact-number match: 33 !≡ 330).
    for d in "$NYIA_PLANS_DIR/$n"-*/; do
        [[ -d "$d" && -f "${d}plan.md" ]] && { printf '%s\n' "${d}plan.md"; return 0; }
    done
    # Legacy flat: plans/N-*.md, excluding review satellites (defensive — real reviews don't start with "N-").
    for f in "$NYIA_PLANS_DIR/$n"-*.md; do
        [[ -f "$f" ]] || continue
        base="$(basename "$f")"
        case "$base" in
            plan-review-*|pair-review-*|code-review-*) continue ;;
        esac
        printf '%s\n' "$f"; return 0
    done
    return 1
}

# resolve_plan_dir <N> — print the plan DIRECTORY (new shape only), return 0; non-zero for legacy/absent.
resolve_plan_dir() {
    local n="$1" d
    [[ "$n" =~ ^[0-9]+[a-z]?$ ]] || return 2   # shape guard: exact NNN[a] only (no glob/traversal)
    for d in "$NYIA_PLANS_DIR/$n"-*/; do
        [[ -d "$d" && -f "${d}plan.md" ]] && { printf '%s\n' "${d%/}"; return 0; }
    done
    return 1
}

# resolve_reviews_dir <N> — where plan N's review/state files live:
#   new shape  -> plans/N-slug/reviews/   ;  legacy flat -> the plans root (loose reviews).
# Non-zero only if the plan itself does not resolve.
resolve_reviews_dir() {
    local n="$1" dir
    [[ "$n" =~ ^[0-9]+[a-z]?$ ]] || return 2   # shape guard: exact NNN[a] only (no glob/traversal)
    if dir="$(resolve_plan_dir "$n")"; then
        printf '%s\n' "$dir/reviews"; return 0
    fi
    if resolve_plan_file "$n" >/dev/null 2>&1; then
        printf '%s\n' "$NYIA_PLANS_DIR"; return 0
    fi
    return 1
}

# --- Plan Status (Plan 331a Step 5; consumed by the 331d generator) ---
# Valid enum; severity order (worst first) drives meta aggregation.
NYIA_PLAN_STATUSES="Draft Ready Active Blocked Review Done Dropped"
NYIA_STATUS_SEVERITY="Blocked Active Review Ready Draft Done Dropped"

# validate_plan_status <value> — 0 if a valid enum member, else 1.
validate_plan_status() {
    local v="$1" s
    [[ -n "$v" ]] || return 1
    for s in $NYIA_PLAN_STATUSES; do [[ "$v" == "$s" ]] && return 0; done
    return 1
}

# === TEMPORARY legacy-Status compatibility (a migration shim — DELETE after the sunset) ===
# Old plans predate the canonical `Status: <enum>` line: they use `## Status: COMPLETED`, `**Status**: …`,
# or free-text values. To keep the generated inventory usable while old projects are still being opened
# (which can happen long after adoption), read_plan_status recognizes these and MAPS them to the enum.
# This is compat only — run `nyia plans status-backfill` to write canonical lines. Drop this block + the
# heading/bold matching in the status scan once old projects are migrated (target below).
NYIA_LEGACY_STATUS_SUNSET="2026-12-31"   # decision point to remove legacy-Status recognition

# _map_legacy_status <free-text value> — best-effort map of a legacy/free-text status to the enum ('' if none).
_map_legacy_status() {
    local v; v="$(tr '[:upper:]' '[:lower:]' <<<"$1")"   # here-string (no pipe) → set -e safe; portable lowercasing
    case "$v" in
        *complete*|*done*|*finished*|*shipped*|*merged*)                 printf 'Done' ;;
        *"in progress"*|*inprogress*|*partial*|*wip*|*active*|*doing*|*ongoing*) printf 'Active' ;;
        *blocked*|*waiting*|*stuck*)                                     printf 'Blocked' ;;
        *review*)                                                        printf 'Review' ;;
        ready*|*"ready for"*|*approved*)                                 printf 'Ready' ;;
        *dropped*|*abandoned*|*obsolete*|*deferred*|*superseded*|*cancel*|*"won't"*|*wontfix*) printf 'Dropped' ;;
        draft*|*planned*|*"not started"*|*todo*)                          printf 'Draft' ;;
        *) printf '' ;;
    esac
}

# read_plan_status <plan_file> — print the plan's Status to stdout (warnings to stderr):
#   missing file  -> "Draft" + return 2 ;  missing field -> "Draft" + return 0 ;
#   invalid value -> print the raw value + return 1.
# Recognizes the canonical `Status: <enum>` AND (temporary) legacy `## Status:` / `**Status**:` / free-text.
read_plan_status() {
    local f="$1" val="" first mapped in_fence=0 line
    if [[ ! -f "$f" ]]; then
        printf 'Draft\n'; printf 'warning: plan file not found: %s\n' "$f" >&2; return 2
    fi
    # Line-by-line (no pipe → set -e safe), skipping code-fenced lines so a fenced "Status:" can't win.
    # Match canonical `Status:` OR a legacy heading `## Status:` / bold `**Status**:` — first non-fenced wins.
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in '```'*) in_fence=$((1 - in_fence)); continue ;; esac
        [[ $in_fence -eq 1 ]] && continue
        if [[ "$line" =~ ^[[:space:]]*(#+[[:space:]]*)?(\*\*)?Status(\*\*)?:[[:space:]]*(.+)$ ]]; then
            val="${BASH_REMATCH[4]}"; break
        fi
    done < "$f"
    if [[ -z "$val" ]]; then
        printf 'Draft\n'; printf 'warning: no Status: field in %s — defaulting to Draft\n' "$f" >&2; return 0
    fi
    first="${val%%[[:space:]]*}"                 # canonical value is a single enum word
    if validate_plan_status "$first"; then printf '%s\n' "$first"; return 0; fi
    mapped="$(_map_legacy_status "$val")"        # TEMPORARY: legacy/free-text → enum
    if [[ -n "$mapped" ]]; then
        printf '%s\n' "$mapped"
        printf 'note: mapped legacy Status "%s" -> %s in %s (run `nyia plans status-backfill`)\n' "$val" "$mapped" "$f" >&2
        return 0
    fi
    printf '%s\n' "$first"
    printf 'warning: invalid Status "%s" in %s\n' "$first" "$f" >&2; return 1
}

# read_plan_roadmap <plan_file> — print the plan's OPTIONAL free-text `Roadmap:` label (e.g. poc / mvp /
# RC1), or nothing when absent. Mirrors read_plan_status (fence-aware, first non-fenced match wins) but the
# label is FREE TEXT (no enum, no legacy mapping), and an absent field is NORMAL — empty output, return 0,
# no warning. Used by the /plan-status skill to group plans by roadmap axis. Plan 335.
read_plan_roadmap() {
    local f="$1" val="" in_fence=0 line
    [[ -f "$f" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in '```'*) in_fence=$((1 - in_fence)); continue ;; esac
        [[ $in_fence -eq 1 ]] && continue
        if [[ "$line" =~ ^[[:space:]]*(#+[[:space:]]*)?(\*\*)?Roadmap(\*\*)?:[[:space:]]*(.+)$ ]]; then
            val="${BASH_REMATCH[4]}"; break
        fi
    done < "$f"
    val="${val%%[[:space:]]#*}"                  # strip a trailing " # comment" (needs a space before #, so "C#" is safe)
    val="${val%"${val##*[![:space:]]}"}"         # trim trailing whitespace
    [[ -n "$val" ]] && printf '%s\n' "$val"
    return 0
}

# meta_status_aggregate <s1> <s2> ... — print the worst-of status by severity order.
meta_status_aggregate() {
    local want s
    for want in $NYIA_STATUS_SEVERITY; do
        for s in "$@"; do
            [[ "$s" == "$want" ]] && { printf '%s\n' "$want"; return 0; }
        done
    done
    printf 'Draft\n'; return 1
}
