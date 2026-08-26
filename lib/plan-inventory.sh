#!/usr/bin/env bash
# lib/plan-inventory.sh — Plan 331d: the GENERATED todo inventory.
#
# `todo.md` becomes a persisted, GENERATED file: one line per plan, Status DERIVED from each
# plans/NNN-*/plan.md `Status:` field (331a) — never hand-edited. A single generator entry point
# (write_todo_inventory, atomic temp+rename), deterministic ordering by plan number, a GENERATED
# header, and a stale check (a plan Status newer than todo.md). No lock: the same Status inputs
# always produce identical bytes, so last-writer-wins is safe (per the plan's Round-2 contract).

_pi_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _pi_dir="."
[[ -n "${NYIA_PLAN_STATUSES:-}" ]] || source "$_pi_dir/plan-resolution.sh"

NYIA_INVENTORY_HEADER="# Project Inventory — GENERATED, do not edit (regenerate: nyia todo)"

# _inventory_emit <key> <slug> <plan_file> — print "<sortkey>\t<key>\t<slug>\t<status>".
#   sortkey = 8-digit-zero-padded-number + letter suffix, so a plain byte sort orders 33 < 331 < 331a < 332
#   (version sort mis-ranks 331a before 331 because of the tab-vs-letter comparison).
_inventory_emit() {
    local key="$1" slug="$2" pf="$3" num letter status
    num="${key%%[!0-9]*}"; letter="${key:${#num}}"        # leading digits only (SF-1: a non-digit key like
    [[ "$num" =~ ^[0-9]+$ ]] || num=0                     #   12AB errored under 10#$num and dropped the row)
    status="$(read_plan_status "$pf" 2>/dev/null)" || true
    # 10#$num forces base-10: a leading-zero key like 08/09 is NOT a valid octal and would print as 0.
    printf '%08d%s\t%s\t%s\t%s\n' "$((10#$num))" "$letter" "$key" "$slug" "$status"
}

# _inventory_scan <plans_dir> — emit sortable "<sortkey>\t<key>\t<slug>\t<status>" per plan
#   (new-shape + legacy flat). Status derived via read_plan_status; review satellites excluded.
_inventory_scan() {
    local dir="${1:-$NYIA_PLANS_DIR}" d f base key slug
    for d in "$dir"/[0-9]*-*/; do                        # new-shape: plans/<key>-<slug>/plan.md
        [[ -d "$d" && -f "${d}plan.md" ]] || continue
        base="$(basename "${d%/}")"; key="${base%%-*}"; slug="${base#*-}"
        _inventory_emit "$key" "$slug" "${d}plan.md"
    done
    for f in "$dir"/[0-9]*-*.md; do                      # legacy flat: plans/<key>-<slug>.md
        [[ -f "$f" ]] || continue
        base="$(basename "$f")"
        case "$base" in plan-review-*|pair-review-*|code-review-*) continue ;; esac
        base="${base%.md}"; key="${base%%-*}"; slug="${base#*-}"
        _inventory_emit "$key" "$slug" "$f"
    done
}

# generate_todo_inventory <plans_dir> [tasks_file] — print the deterministic inventory to stdout.
generate_todo_inventory() {
    local dir="${1:-$NYIA_PLANS_DIR}" tasks="${2:-}" sorted line key slug status
    printf '%s\n\n' "$NYIA_INVENTORY_HEADER"
    printf '## Plans (by number)\n'
    sorted="$(_inventory_scan "$dir" | LC_ALL=C sort)"   # byte sort on the padded sortkey (33<331<331a<332)
    if [[ -n "$sorted" ]]; then
        local _sk
        while IFS=$'\t' read -r _sk key slug status; do
            [[ -n "$key" ]] || continue
            printf -- '- %-5s %-42s · %s\n' "$key" "$slug" "$status"
        done <<<"$sorted"
    else
        printf -- '- (no plans)\n'
    fi
    if [[ -n "$tasks" && -f "$tasks" ]]; then
        printf '\n## Tasks (tasks.md)\n'
        cat "$tasks"
    fi
}

# write_todo_inventory <plans_dir> <out_file> [tasks_file] — atomic generation (temp+rename).
#   On generation failure the previous out_file is left intact (Round-3 contract).
write_todo_inventory() {
    local dir="${1:-$NYIA_PLANS_DIR}" out="$2" tasks="${3:-}" tmp first=""
    [[ -n "$out" ]] || return 2
    # MF-1: NEVER clobber a hand-maintained file. Only (re)write a file that is absent or already generated
    # (first line == the GENERATED header). NYIA_TODO_FORCE=1 overrides. The live todo.md is gitignored, so
    # a blind overwrite of the pre-migration monolith would be unrecoverable.
    if [[ -f "$out" && "${NYIA_TODO_FORCE:-0}" != "1" ]]; then
        IFS= read -r first < "$out" || first=""
        [[ "$first" == "$NYIA_INVENTORY_HEADER" ]] || {
            printf 'refusing to overwrite non-generated %s (archive it, or set NYIA_TODO_FORCE=1)\n' "$out" >&2
            return 4
        }
    fi
    tmp="$(mktemp "${out}.XXXXXX")" || return 1
    if generate_todo_inventory "$dir" "$tasks" > "$tmp"; then
        mv -f "$tmp" "$out" || { rm -f "$tmp"; return 1; }   # SF-3: clean up the temp on mv failure
    else
        rm -f "$tmp"; return 1
    fi
}

# _plan_has_explicit_status <plan_file> — 0 iff the file carries an explicit valid `Status:` line OUTSIDE a
#   code fence. (read_plan_status defaults a MISSING field to Draft, which the G1 gate must NOT accept; and a
#   MF-2 fence-only `Status:` must not count — read_plan_status skips fenced lines, so the gate must too, else
#   the board could silently rot once the mandate is swapped.)
_plan_has_explicit_status() {
    local line in_fence=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in '```'*) in_fence=$((1 - in_fence)); continue ;; esac
        [[ $in_fence -eq 1 ]] && continue
        [[ "$line" =~ ^Status:[[:space:]]+(Draft|Ready|Active|Blocked|Review|Done|Dropped)([[:space:]]|$) ]] && return 0
    done < "$1"
    return 1
}

# mandate_swap_preconditions <plans_dir> — G1 interlock. Return 0 only when it is safe to swap the
# CLAUDE.md/prompt mandate to the write-routing rule: 331b's migration is VERIFIED (.migration-verified)
# AND every live plan carries an explicit valid Status: (so the generated inventory isn't half-empty).
# On failure: name the missing precondition on stderr, return non-zero, and touch NOTHING.
mandate_swap_preconditions() {
    local dir="${1:-$NYIA_PLANS_DIR}" d f base missing=0 seen=0
    if [[ ! -f "$dir/.migration-verified" ]]; then
        printf 'blocked: migration not verified (%s/.migration-verified absent) — run `nyia plans migrate` first\n' "$dir" >&2
        return 1
    fi
    for d in "$dir"/[0-9]*-*/; do
        [[ -d "$d" && -f "${d}plan.md" ]] || continue
        seen=1
        _plan_has_explicit_status "${d}plan.md" || { printf 'blocked: plan %s has no explicit Status:\n' "$(basename "${d%/}")" >&2; missing=1; }
    done
    for f in "$dir"/[0-9]*-*.md; do
        [[ -f "$f" ]] || continue
        base="$(basename "$f")"
        case "$base" in plan-review-*|pair-review-*|code-review-*) continue ;; esac
        seen=1
        _plan_has_explicit_status "$f" || { printf 'blocked: plan %s has no explicit Status:\n' "$base" >&2; missing=1; }
    done
    # SF-2: an empty plan store is not "ready" — a vacuous pass would swap the mandate over an empty board.
    [[ "$seen" -eq 1 ]] || { printf 'blocked: no plans found in %s\n' "$dir" >&2; return 1; }
    [[ "$missing" -eq 0 ]]
}

# inventory_is_stale <plans_dir> <out_file> — 0 (stale) if out_file is absent or any plan Status is
# newer than it; non-zero if current. "Stale" only means "re-run nyia todo" — never a lost edit.
inventory_is_stale() {
    local dir="${1:-$NYIA_PLANS_DIR}" out="$2" f
    [[ -f "$out" ]] || return 0
    for f in "$dir"/[0-9]*-*/plan.md "$dir"/[0-9]*-*.md; do
        [[ -f "$f" ]] || continue
        [[ "$f" -nt "$out" ]] && return 0
    done
    return 1
}

# (Removed 2026-08-25: _status_from_checkboxes — bash checkbox-guessing of plan status. FIELD-ONLY policy:
#  backfill ensures the Status field exists from the plan's real value or Draft; the accurate value is set by
#  the plan-touching skills as they work, not guessed here.)

# derive_plan_status <file> — the status to record for backfill: the plan's EXISTING value only —
#   canonical `Status:` > legacy-mapped `## Status:` (both via read_plan_status) > Draft when absent.
#   FIELD-ONLY (user 2026-08-25): bash NEVER guesses a value from checkbox progress — judging where a plan
#   actually stands is an LLM task, done continuously by the plan-touching skills, not a bash heuristic.
derive_plan_status() {
    read_plan_status "$1" 2>/dev/null
}

# _plan_has_status_line <file> — 0 if ANY (canonical/legacy) status line exists (fence-aware).
_plan_has_status_line() {
    local line in_fence=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in '```'*) in_fence=$((1 - in_fence)); continue ;; esac
        [[ $in_fence -eq 1 ]] && continue
        [[ "$line" =~ ^[[:space:]]*(#+[[:space:]]*)?(\*\*)?Status(\*\*)?:[[:space:]]*(.+)$ ]] && return 0
    done < "$1"
    return 1
}

# backfill_plan_status <file> <apply:0|1> — if the file lacks a CANONICAL `Status: <enum>` line, derive one
#   and (apply=1) insert it right after the first line (atomic). Prints "<action>\t<status>\t<file>".
#   TEMPORARY migration aid — see the legacy-Status sunset in plan-resolution.sh.
backfill_plan_status() {
    local f="$1" apply="${2:-0}" s tmp first second cr="" fix_line=0 i cand stamp_tok=""
    # Plan 336 (R6): a PREVIOUS backfill may have stamped a non-enum token (`Status: the`, from a prose
    # line's first word) at line 1 or 2 — REPLACE that line instead of inserting a second Status. Only the
    # stamped shape qualifies: a single-token `^Status: X$` (CR-tolerant), invalid, on line 1–2, and not
    # inside a fence (line 1 is a fence opener). Prose `Status: …` lines are never touched.
    # Scanned BEFORE the explicit-status short-circuit (336 review): read_plan_status is first-match, so a
    # stamped invalid line wins over a valid `Status:` further down and must be repaired even then.
    { IFS= read -r first || true; IFS= read -r second || true; } < "$f"
    if [[ "${first%$'\r'}" != '```'* ]]; then
        for i in 1 2; do
            cand="$first"; [[ $i -eq 2 ]] && cand="$second"
            cr=""; [[ "$cand" == *$'\r' ]] && { cr=$'\r'; cand="${cand%$'\r'}"; }
            if [[ "$cand" =~ ^Status:[[:space:]]+([^[:space:]]+)$ ]] && ! validate_plan_status "${BASH_REMATCH[1]}"; then
                fix_line=$i; stamp_tok="${BASH_REMATCH[1]}"; break
            fi
        done
    fi
    if [[ "$fix_line" -eq 0 ]] && _plan_has_explicit_status "$f" 2>/dev/null; then printf 'skip\t-\t%s\n' "$f"; return 0; fi
    if [[ "$fix_line" -gt 0 ]]; then
        # Derive from the file WITHOUT the stamped line: the next Status: line (the legacy original, or a
        # valid one someone added later) is the truth; the stamp itself carries no information.
        local view; view="$(mktemp)" || return 1
        sed "${fix_line}d" "$f" > "$view" 2>/dev/null || { rm -f "$view"; return 1; }
        if _plan_has_status_line "$view"; then
            s="$(derive_plan_status "$view")" || true
        else
            s="$(_map_legacy_status "$stamp_tok")"   # the stamp is the ONLY status information left — map it
        fi
        rm -f "$view"
    else
        s="$(derive_plan_status "$f")" || true       # 336: an invalid value yields Draft (rc 1) — never the raw word
    fi
    [[ -n "$s" ]] || s="Draft"
    if [[ "$apply" == "1" ]]; then
        tmp="$(mktemp "${f}.XXXXXX")" || return 1
        if [[ "$fix_line" -gt 0 ]]; then
            # In-place: everything before the stamped line, the repaired line (CR preserved), everything after.
            if { [[ $fix_line -eq 2 ]] && printf '%s\n' "$first"; printf 'Status: %s%s\n' "$s" "$cr"; tail -n +$(( fix_line + 1 )) "$f"; } > "$tmp" && mv -f "$tmp" "$f"; then
                printf 'fixed\t%s\t%s\n' "$s" "$f"; return 0
            fi
            rm -f "$tmp"; return 1
        fi
        # F1: `IFS= read` returns non-zero at EOF on a no-trailing-newline file even though it populated
        # $first — the old `&& printf` then DROPPED that line (data loss on a single-line stub). Emit it
        # whenever non-empty, independent of read's exit status; an empty file still gets no leading blank.
        if { [[ -n "$first" ]] && printf '%s\n' "$first"; printf 'Status: %s\n' "$s"; tail -n +2 "$f"; } > "$tmp" && mv -f "$tmp" "$f"; then
            printf 'wrote\t%s\t%s\n' "$s" "$f"; return 0
        fi
        rm -f "$tmp"; return 1
    else
        if [[ "$fix_line" -gt 0 ]]; then printf 'would-fix\t%s\t%s\n' "$s" "$f"; else printf 'would-write\t%s\t%s\n' "$s" "$f"; fi
    fi
}

# plans_status_backfill <plans_dir> [--yes] — backfill a canonical Status into every plan that lacks one.
#   Default is a DRY RUN (prints the plan); --yes applies. Scans new-shape + legacy-flat plans.
plans_status_backfill() {
    local dir="${1:-$NYIA_PLANS_DIR}" apply=0 d f base n=0
    [[ "${2:-}" == "--yes" ]] && apply=1
    [[ "$apply" -eq 1 ]] && printf 'Backfilling canonical Status: into plans under %s\n' "$dir" \
                         || printf 'DRY RUN (add --yes to apply) — plans under %s\n' "$dir"
    for d in "$dir"/[0-9]*-*/; do
        [[ -d "$d" && -f "${d}plan.md" ]] || continue
        backfill_plan_status "${d}plan.md" "$apply"; n=$(( n + 1 ))
    done
    for f in "$dir"/[0-9]*-*.md; do
        [[ -f "$f" ]] || continue
        base="$(basename "$f")"
        case "$base" in plan-review-*|pair-review-*|code-review-*) continue ;; esac
        backfill_plan_status "$f" "$apply"; n=$(( n + 1 ))
    done
    printf '%s plan(s) scanned.\n' "$n"
}

# handle_todo_command [--write] — the `nyia todo` dispatcher. Defined HERE (a shipped lib) so BOTH the source
# bin/nyia and the generated runtime dispatcher source this lib and call it (source/runtime parity).
handle_todo_command() {
    local project="${PROJECT_PATH:-$(pwd)}"
    local plans_dir="$project/.nyiakeeper/plans"
    local tasks="$project/.nyiakeeper/tasks.md"
    local out="$project/.nyiakeeper/todo.md"
    export NYIA_PLANS_DIR="$plans_dir"
    case "${1:-}" in
        --write)
            if write_todo_inventory "$plans_dir" "$out" "$tasks"; then printf 'Regenerated %s\n' "$out"
            else printf 'Inventory generation failed; %s left unchanged\n' "$out" >&2; return 1; fi ;;
        ""|--print) generate_todo_inventory "$plans_dir" "$tasks" ;;
        *) printf 'Unknown todo option: %s (use --write)\n' "$1" >&2; return 1 ;;
    esac
}
