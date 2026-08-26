#!/usr/bin/env bash
# lib/plan-migration.sh — Plan 331b: legacy flat → new per-plan-directory migration.
#
# This file holds the pure classification helpers (below); the migrator orchestration
# (backup → copy-verify-remove → fail-closed → marker) is layered on in the migrate command.

# Own module dir (for lazy-sourcing siblings from execute_migration — do NOT borrow another file's var).
_pm_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# plan_number_of <slug-or-name> — print the leading NNN[a] key (e.g. 331a, 42); non-zero if none.
plan_number_of() {
    local s="$1" num
    num="$(printf '%s' "$s" | sed -nE 's/^([0-9]+[a-z]?)([-.].*)?$/\1/p')"
    [[ -n "$num" ]] && { printf '%s\n' "$num"; return 0; }
    return 1
}

# classify_legacy_file <basename> — route a flat file to its migration category:
#   "body <slug>"  (a plan body / subplan body → plans/<slug>/plan.md)
#   "review <NNN>" (plan-review-/code-review-/pair-review- satellite → plan NNN's reviews/)
#   "state <NNN>"  (Plan 259 <NNN>.state.json → plan NNN's reviews/)
#   "skip"         (unrelated / unclassifiable → stays flat)
# Collision handling (two bodies for one NNN, etc.) is the migrator's fail-closed job, not this classifier's.
classify_legacy_file() {
    local b="$1" num
    local LC_ALL=C   # ASCII classes only: under a UTF-8 collating locale [a-z] over-matches (café) — force C
    case "$b" in
        plan-review-*|code-review-*|pair-review-*)
            # The number may be followed by a slug (plan-42-x.md) OR go straight to .md (plan-287.md) —
            # accept a '-' OR '.' after it, else 53 real reviews (…-plan-NNN.md) get mis-classified as skip.
            num="$(printf '%s' "$b" | LC_ALL=C sed -nE 's/.*plan-([0-9]+[a-z]?)[-.].*/\1/p')"
            [[ -n "$num" ]] && { printf 'review %s\n' "$num"; return 0; }
            # Plan 336: two more REAL review shapes, ANCHORED so a batch/date name can't be mis-routed:
            #   plan-review-{N}-{lens}.md            (the 2-agent lens output, e.g. plan-review-289-design.md)
            #   pair-review-{a}-for-{b}-{N}[-vK].md  (e.g. pair-review-claude-for-codex-106-v2.md)
            # A name like …-batch-open-plans-2026-03-08.md matches neither (no "for-<b>-N" tail, no plan-review-N-).
            if [[ "$b" =~ ^plan-review-([0-9]+[a-z]?)-[^[:space:]/]+\.md$ ]] \
               || [[ "$b" =~ ^pair-review-[a-z]+-for-[a-z]+-([0-9]+[a-z]?)(-v[0-9]+)?\.md$ ]]; then
                printf 'review %s\n' "${BASH_REMATCH[1]}"; return 0
            fi
            printf 'skip\n'; return 0 ;;
    esac
    case "$b" in
        *.state.json)
            num="$(printf '%s' "$b" | sed -nE 's/^([0-9]+[a-z]?)[-.].*/\1/p')"
            [[ -n "$num" ]] && { printf 'state %s\n' "$num"; return 0; }
            printf 'skip\n'; return 0 ;;
    esac
    if [[ "$b" =~ ^[0-9]+[a-z]?-.*\.md$ ]]; then
        printf 'body %s\n' "${b%.md}"; return 0
    fi
    printf 'skip\n'; return 0
}

# _fallback_body_for <number> — Plan 336 (R2): the EXACT-key fallback home for a review/state whose own
#   number has no body. Reads the caller's body_slug/body_count (dynamic scope). Prints the body key or
#   nothing. Lettered NNNx → base NNN only (one trailing letter stripped; never a sibling letter).
#   Bare NNN → the FIRST body (sorted) whose key matches ^NNN[a-z]$ — the same "first plan" rule a
#   duplicate number's reviews already follow. `10` can never see `100` (exact keys, anchored regex).
_fallback_body_for() {
    local num="$1" base k
    local LC_ALL=C
    if [[ "$num" =~ ^([0-9]+)[a-z]$ ]]; then
        base="${BASH_REMATCH[1]}"
        [[ "${body_count[$base]:-0}" -ge 1 ]] && { printf '%s\n' "$base"; return 0; }
        return 1
    fi
    for k in $(printf '%s\n' "${!body_slug[@]}" | LC_ALL=C sort); do   # keys are ^[0-9]+[a-z]?$ tokens (no IFS risk)
        [[ "$k" =~ ^${num}[a-z]$ ]] && { printf '%s\n' "$k"; return 0; }
    done
    return 1
}

# plan_migration <plans_dir> — DRY-RUN: print a migration plan. Moves NOTHING.
#   Fields are TAB-delimited (a basename may legally contain spaces, so space cannot delimit):
#     MOVE   <src-basename>  <dest-relpath>            — an unambiguous relocation
#     NOTE   <number>        <n> plans                 — informational: a number with >1 body (collisions log)
#     ROUTED <src-basename>  <dest-dir>  <reason>      — Plan 336: a review/state routed by EXACT-key fallback
#     ORPHAN <src-basename>  <number>                  — Plan 336: a review/state with no body, now or ever
#                                                        (stays flat, NAMED, does NOT block the markers)
#     SKIP   <basename>                                — a foreign file (not a plan artifact)
#     UNSAFE <count>                                   — basenames with a tab/newline / symlinks: never moved,
#                                                        marker withheld
#   The executor consumes this plan; the union invariant (ENFORCED there, R8) is: every top-level regular
#   source file is exactly one of MOVE src / SKIP / ORPHAN, plus the UNSAFE count.
plan_migration() {
    local dir="${1:-$NYIA_PLANS_DIR}" f b d cat key num unsafe=0 home
    declare -A body_slug body_count noted
    local -a files=()
    # Pass 0 (Plan 336, R3): bodies that ALREADY live in NNN-slug/plan.md dirs are bodies too — on a
    # re-run / finalize every body is in a dir, so without this every remaining review looked orphaned.
    # Skip symlinked dirs (never route INTO a link) and any dir name plan_number_of rejects: an empty
    # associative key would abort bash under set -e mid-stream and truncate the plan (risk H1).
    for d in "$dir"/[0-9]*-*/; do
        d="${d%/}"
        # 336 security review: a TAB/newline in a DIR name would forge the fields of a MOVE line (the flat-file
        # loop already refuses such names). Skip it — its reviews become named ORPHAN/ROUTED lines instead.
        case "$d" in *$'\t'*|*$'\n'*) printf 'skip: a plan dir with a tab/newline in its name is ignored: %q\n' "$(basename "$d")" >&2; continue ;; esac
        [[ -d "$d" && ! -L "$d" && -f "$d/plan.md" ]] || continue
        b="$(basename "$d")"
        num="$(plan_number_of "$b")" || continue
        body_count[$num]=$(( ${body_count[$num]:-0} + 1 ))
        [[ -z "${body_slug[$num]:-}" ]] && body_slug[$num]="$b"
    done
    # Pass 1: enumerate top-level flat files; count bodies per number.
    for f in "$dir"/*; do
        [[ -f "$f" ]] || continue
        b="$(basename "$f")"
        # Held back (never moved, marker withheld — fail-closed):
        #   - a symlink (cp would dereference it, pulling outside bytes into the tree — SF-2)
        #   - a tab/newline name (would forge a field / split a plan line — MF-1)
        if [[ -L "$f" || "$b" == *$'\t'* || "$b" == *$'\n'* ]]; then
            unsafe=$(( unsafe + 1 )); continue
        fi
        files+=("$b")
        read -r cat key <<<"$(classify_legacy_file "$b")"
        if [[ "$cat" == "body" ]]; then
            num="$(plan_number_of "$key")"
            body_count[$num]=$(( ${body_count[$num]:-0} + 1 ))
            [[ -z "${body_slug[$num]:-}" ]] && body_slug[$num]="$key"   # FIRST body (sorted) — reviews route here
        fi
    done
    # Pass 2: emit the plan (TAB-delimited fields).
    for b in "${files[@]}"; do
        read -r cat key <<<"$(classify_legacy_file "$b")"
        case "$cat" in
            body)
                # Bodies NEVER collide: each has a unique full basename → a unique NNN-slug/ dir. Always MOVE.
                # A number with >1 body just means resolve-by-number returns the first — emit a NOTE (once),
                # informational, NOT a block (renumbering is unnecessary and would break cross-plan references).
                num="$(plan_number_of "$key")"
                if [[ "${body_count[$num]}" -gt 1 && -z "${noted[$num]:-}" ]]; then
                    printf 'NOTE\t%s\t%s plans\n' "$num" "${body_count[$num]}"; noted[$num]=1
                fi
                printf 'MOVE\t%s\t%s/plan.md\n' "$b" "$key" ;;
            review|state)
                num="$key"
                if [[ "${body_count[$num]:-0}" -ge 1 ]]; then
                    # route to the FIRST plan of this number (deterministic; a duplicate number's reviews
                    # are grouped under its first plan — preserved, not lost).
                    printf 'MOVE\t%s\t%s/reviews/%s\n' "$b" "${body_slug[$num]}" "$b"
                elif home="$(_fallback_body_for "$num")"; then
                    # Plan 336 (R2): no body for this exact number → its base number (170b→170) or its
                    # first lettered sibling (328→328a). Reported as ROUTED so the guess is auditable.
                    printf 'ROUTED\t%s\t%s\tno %s body\n' "$b" "${body_slug[$home]}" "$num"
                    printf 'MOVE\t%s\t%s/reviews/%s\n' "$b" "${body_slug[$home]}" "$b"
                else
                    # Plan 336 (R1): a genuine orphan — no body now, and none the user can create for it.
                    # Named, never blocking (a count-only "unrouted" report locked the launch forever).
                    printf 'ORPHAN\t%s\t%s\n' "$b" "$num"
                fi ;;
            *) printf 'SKIP\t%s\n' "$b" ;;
        esac
    done
    (( unsafe > 0 )) && printf 'UNSAFE\t%s\n' "$unsafe"
    return 0
}

# _migration_hashset <dir> — print the sorted content hashes of every file under <dir>.
#   NUL-delimited find (handles spaces/tabs/newlines in names); no pipeline feeds a command
#   substitution, so it is safe under `set -eo pipefail`. Used to prove backup == source.
_migration_hashset() {
    local d="$1" f h
    local -a hs=()
    while IFS= read -r -d '' f; do
        h="$(sha256sum "$d/$f")"; hs+=("${h%% *}")
    done < <(cd "$d" && find . -type f -print0)
    [[ ${#hs[@]} -gt 0 ]] && printf '%s\n' "${hs[@]}" | sort
}

# _dest_is_331 <dest-relpath> — 0 if the MOVE targets a 331 / 331<letter> plan dir (G3 dogfood-last).
_dest_is_331() {
    local first num
    first="${1%%/*}"; num="${first%%-*}"   # separate statements: a single `local a=.. b=$a` can't see a
    case "$num" in 331|331[a-z]*) return 0 ;; esac
    return 1
}

# _do_move <dir> <src> <dest> — copy → hash-verify → remove ONE plan file. 0 ok; 1 hard fail (abort the
# batch, before this rm); 2 skip (slug path occupied by a flat file → leave flat, caller sets remnant).
_do_move() {
    local dir="$1" src="$2" dest="$3" srchash dsthash
    # Plan 336 (risk M3): never write THROUGH a symlinked path component — a symlinked NNN-slug/ or
    # reviews/ would carry the copy outside the store (SF-2 only refused symlinked source FILES).
    local _walk="$dir" _c _rel
    _rel="$(dirname "$dest")"
    local -a _parts=()
    IFS='/' read -r -a _parts <<<"$_rel"
    for _c in "${_parts[@]}"; do
        [[ -n "$_c" && "$_c" != "." ]] || continue
        _walk="$_walk/$_c"
        if [[ -L "$_walk" ]]; then
            printf 'skip: %s is a symlink — %s stays flat\n' "${_walk#"$dir"/}" "$src" >&2
            return 2
        fi
    done
    if ! mkdir -p "$dir/$(dirname "$dest")" 2>/dev/null; then   # SF-4: occupied slug path → skip+warn
        printf 'skip: cannot create %s (path occupied?) — %s stays flat\n' "$(dirname "$dest")" "$src" >&2
        return 2
    fi
    srchash="$(sha256sum "$dir/$src")"; srchash="${srchash%% *}"   # SF-5: no pipeline (pipefail-safe)
    # Plan 336 (risk H3): re-runs are real now, so a dest may already exist. Identical bytes → the copy
    # already lives there: just drop the flat duplicate. Different bytes → NEVER overwrite; stays flat, named.
    if [[ -e "$dir/$dest" || -L "$dir/$dest" ]]; then
        if [[ -L "$dir/$dest" || ! -f "$dir/$dest" ]]; then
            printf 'skip: %s exists and is not a regular file — %s stays flat\n' "$dest" "$src" >&2; return 2
        fi
        dsthash="$(sha256sum "$dir/$dest")"; dsthash="${dsthash%% *}"
        if [[ "$srchash" == "$dsthash" ]]; then
            [[ -n "${NYIA_MIGRATION_TRACE:-}" ]] && { printf '%s\n' "$src" >> "$NYIA_MIGRATION_TRACE" || true; }
            rm -f "$dir/$src"; return 0
        fi
        printf 'skip: %s already exists with different content — %s stays flat (compare and merge by hand)\n' "$dest" "$src" >&2
        return 2
    fi
    cp -p "$dir/$src" "$dir/$dest" || return 1
    dsthash="$(sha256sum "$dir/$dest")"; dsthash="${dsthash%% *}"
    [[ "$srchash" == "$dsthash" ]] || { printf 'verify failed: %s\n' "$src" >&2; return 1; }
    # Observability only (SF-G2G3-2): a trace-write failure must never errexit _do_move between verify and rm.
    [[ -n "${NYIA_MIGRATION_TRACE:-}" ]] && { printf '%s\n' "$src" >> "$NYIA_MIGRATION_TRACE" || true; }
    rm -f "$dir/$src"
    return 0
}

# backfill_migrated_statuses <plans_dir> — Plan 331b status-backfill fold. Loop the just-migrated new-shape
# plans and ensure each has an explicit canonical `Status:` FIELD (via backfill_plan_status, apply=1). It is
# idempotent (skips plans that already have one) and FIELD-ONLY (real legacy value or Draft — never guessed).
# Echoes one "  <rel> → <status>" line per plan stamped (empty when none). Lazy-sources plan-inventory.sh;
# best-effort (returns 0 even if the lib is unavailable) so the caller's migration is never blocked.
backfill_migrated_statuses() {
    local dir="${1:-$NYIA_PLANS_DIR}" p rel res st
    [[ "$(type -t backfill_plan_status)" == function ]] \
        || source "$_pm_dir/plan-inventory.sh" 2>/dev/null || return 0
    [[ "$(type -t backfill_plan_status)" == function ]] || return 0
    for p in "$dir"/[0-9]*-*/plan.md; do
        [[ -f "$p" && ! -L "$p" ]] || continue
        res="$(backfill_plan_status "$p" 1 2>/dev/null)" || continue
        case "$res" in
            wrote*|fixed*) IFS=$'\t' read -r _ st rel <<<"$res"; printf '  %s → %s\n' "${p#"$dir"/}" "$st" ;;   # fixed = 336 in-place repair
        esac
    done
    return 0
}

# convert_pristine_override_strays <plans_dir> — Plan 331b extension. compose_project_prompt aggregates a REAL
# project-override `.md` (never `.example`), so an UNTOUCHED default copy composes as `[e.g., …]` placeholder
# noise. Rename each such stray to `.example` (NEVER delete — the content is preserved and the composer stops
# reading it; a same-dir rename is atomic and self-preserving, so no backup is needed). Eligibility: the file's
# sha256 equals its `.example` template (looked up in shared OR legacy prompts). Customized files (no hash
# match) and symlinks are left untouched. Best-effort / fail-open (the plan store is the priority). Opt out with
# NYIA_SKIP_OVERRIDE_CLEANUP=1. Echoes each conversion `X.md -> X.md.example` for the caller's report.
convert_pristine_override_strays() {
    [[ -n "${NYIA_SKIP_OVERRIDE_CLEANUP:-}" ]] && return 0
    local plans_dir="${1:-$NYIA_PLANS_DIR}" root shared legacy d base md ex h1 h2
    root="$(cd "$plans_dir/.." 2>/dev/null && pwd)" || return 0
    shared="$root/shared/prompts"; legacy="$root/prompts"
    # Structural allowlist = the ONLY override tiers compose_project_prompt reads (global + per-assistant).
    local -a bases=(project-overrides.md claude-project.md gemini-project.md codex-project.md \
                    opencode-project.md vibe-project.md)
    for d in "$shared" "$legacy"; do
        [[ -d "$d" ]] || continue
        for base in "${bases[@]}"; do
            md="$d/$base"
            if [[ -L "$md" ]]; then printf 'override cleanup: skipped symlink %s\n' "$md" >&2; continue; fi
            [[ -f "$md" ]] || continue
            # Find the pristine `.example` for this basename: same dir first, else the other prompt dir.
            ex=""
            if   [[ -f "$d/$base.example"      && ! -L "$d/$base.example" ]];      then ex="$d/$base.example"
            elif [[ -f "$shared/$base.example" && ! -L "$shared/$base.example" ]]; then ex="$shared/$base.example"
            elif [[ -f "$legacy/$base.example" && ! -L "$legacy/$base.example" ]]; then ex="$legacy/$base.example"
            fi
            [[ -n "$ex" ]] || continue                        # no template to compare → can't prove pristine → leave
            h1="$(sha256sum "$md")" || continue; h1="${h1%% *}"   # no pipeline (pipefail-safe)
            h2="$(sha256sum "$ex")" || continue; h2="${h2%% *}"
            [[ "$h1" == "$h2" ]] || continue                  # customized (incl. whitespace/EOL diffs) → NEVER touch
            if mv -f "$md" "$md.example" 2>/dev/null; then printf '%s -> %s.example\n' "$base" "$base"; fi
        done
    done
    return 0
}

# _is_generated_file <file> — 0 iff the file carries the `nyia plans migrate` GENERATED header (line 1).
_is_generated_file() {
    local first=""
    [[ -f "$1" ]] || return 1
    IFS= read -r first < "$1" || true
    [[ "$first" == *'GENERATED by `nyia plans migrate`'* ]]
}

# _generated_target <path> <mig_id> — where a generated log may be written: <path> when it is absent or
#   ours (GENERATED header); a mig_id-suffixed sibling when a USER-authored file holds that name (336
#   review: the store is user-controlled — never clobber a user's collisions.md / migration-notes.md).
_generated_target() {
    local path="$1" mig_id="$2"
    if [[ ! -e "$path" ]] || _is_generated_file "$path"; then printf '%s\n' "$path"; return 0; fi
    printf 'note: %s is not a generated file — writing %s instead\n' "$path" "${path%.md}-$mig_id.md" >&2
    printf '%s\n' "${path%.md}-$mig_id.md"
}

# _plan_dirs_for_number <plans_dir> <number> — "  - <dir>" per EXISTING (non-symlink) plan dir of that exact
#   number, from the filesystem = the post-move truth (336 review SF-1: MOVE-fed lists dropped earlier dirs).
_plan_dirs_for_number() {
    local dir="$1" num="$2" d b k
    for d in "$dir/$num"-*/; do
        d="${d%/}"
        [[ -d "$d" && ! -L "$d" && -f "$d/plan.md" ]] || continue
        b="$(basename "$d")"; k="$(plan_number_of "$b")" || continue
        [[ "$k" == "$num" ]] && printf '  - %s\n' "$b"
    done
    return 0
}

# execute_migration <plans_dir> — apply the plan: backup → restore-verify → copy → verify(hash) → remove. DESTRUCTIVE.
#   Returns 0 (marker written) only when NO legacy artifact remains flat; 3 if legacy remnants remain
#   (blocked/orphan → detection stays active); 1 on backup/copy/verify failure (before any source removed).
#   NYIA_ARCHIVE_DIR (default <dir>/../.plan-archive) + NYIA_MIGRATION_ID make the backup path deterministic.
execute_migration() {
    local dir="${1:-$NYIA_PLANS_DIR}" l action src dest srchash dsthash remnant=0 c
    local -a plan=()
    local archive_dir="${NYIA_ARCHIVE_DIR:-$dir/../.plan-archive}"
    local mig_id="${NYIA_MIGRATION_ID:-$(date +%Y%m%d-%H%M%S)}"
    # SF-G2G3-1: mig_id builds the archive/extracted paths that later feed `rm -rf` — keep it a safe token.
    [[ "$mig_id" =~ ^[A-Za-z0-9._-]+$ ]] || { printf 'bad migration id: %s\n' "$mig_id" >&2; return 1; }
    # Plan 336 (risk H1): a process substitution hides the planner's exit status — a planner abort would
    # leave a TRUNCATED plan, remnant=0 and BOTH markers written on an incomplete run. Capture rc explicitly.
    local plan_out
    plan_out="$(plan_migration "$dir")" || { printf 'migration planner failed — nothing changed\n' >&2; return 1; }
    [[ -n "$plan_out" ]] && mapfile -t plan <<<"$plan_out"
    # R8: ENFORCE the union invariant BEFORE touching anything — every top-level regular file must be
    # exactly one MOVE src / SKIP / ORPHAN, plus the UNSAFE count. Any drift = an inconsistent plan → abort.
    local _src_n=0 _planned=0 _f _l2 _a _s _rest
    for _f in "$dir"/*; do [[ -f "$_f" ]] && _src_n=$(( _src_n + 1 )); done
    for _l2 in "${plan[@]}"; do
        IFS=$'\t' read -r _a _s _rest <<<"$_l2"
        case "$_a" in MOVE|SKIP|ORPHAN) _planned=$(( _planned + 1 )) ;; UNSAFE) _planned=$(( _planned + _s )) ;; esac
    done
    if [[ "$_src_n" -ne "$_planned" ]]; then
        printf 'migration plan is inconsistent (%s files, %s planned) — nothing changed\n' "$_src_n" "$_planned" >&2
        return 1
    fi
    # Backup FIRST (the only undo for a gitignored store) — before touching any original.
    mkdir -p "$archive_dir" || { printf 'backup dir failed\n' >&2; return 1; }
    local backup="$archive_dir/plans-premigration-$mig_id.tgz"
    tar czf "$backup" -C "$dir" . 2>/dev/null || { printf 'backup failed\n' >&2; return 1; }
    # G2 (risk-review): keep a READABLE extracted backup copy (recovery is a plain `cp`, not an un-tar) and
    # use it AS the restore-verify target — prove content-set(source) == content-set(extracted) BEFORE any
    # rm. Then make the copy read-only (immutable). A tar exit of 0 does not by itself prove a faithful,
    # restorable archive, so a mismatch aborts the migration with everything untouched.
    local extracted="$archive_dir/plans-premigration-$mig_id"
    if [[ -d "$extracted" ]]; then chmod -R u+w "$extracted" 2>/dev/null || true; rm -rf "$extracted"; fi
    mkdir -p "$extracted" || { printf 'restore-verify: cannot create %s\n' "$extracted" >&2; return 1; }
    if ! tar xzf "$backup" -C "$extracted" 2>/dev/null \
       || [[ "$(_migration_hashset "$dir")" != "$(_migration_hashset "$extracted")" ]]; then
        printf 'restore-verify failed: backup is not a faithful copy — aborting before any change\n' >&2
        return 1
    fi
    # Make the recovery FILES immutable (content can't be tampered). Directories stay traversable/removable —
    # the true read-only guarantee is the container's ro MOUNT (a mount-layer concern), this is belt-and-suspenders.
    find "$extracted" -type f -exec chmod a-w {} + 2>/dev/null || true
    # Partition the plan: BLOCK/UNSAFE/SKIP set remnant (order-independent); MOVEs are split so the 331*
    # plans migrate LAST (G3) — they describe their own migrator, so a bug must not corrupt them first.
    local -a moves_other=() moves_331=() note_report=() noted_nums=()  # NOTE = multi-plan numbers (informational)
    local unsafe_total=0 _bdir _bnum reason
    local -a routed_report=() orphan_report=()            # Plan 336: named, auditable, never blocking
    declare -A body_dirs                                   # number → its plan dirs (for the collisions log)
    for l in "${plan[@]}"; do
        IFS=$'\t' read -r action src dest reason <<<"$l"
        case "$action" in
            MOVE)
                if _dest_is_331 "$dest"; then moves_331+=("$src"$'\t'"$dest"); else moves_other+=("$src"$'\t'"$dest"); fi
                case "$dest" in */plan.md) _bdir="${dest%/plan.md}"; _bnum="${_bdir%%-*}"; body_dirs[$_bnum]="${body_dirs[$_bnum]:-}  - ${_bdir}"$'\n' ;; esac ;;
            NOTE)    note_report+=("$src ($dest)"); noted_nums+=("$src") ;;   # e.g. "66 (5 plans)" — does NOT set remnant
            UNSAFE)  unsafe_total="$src"; remnant=1 ;;               # tab/newline names stayed flat → detection stays active
            ROUTED)  routed_report+=("$src → $dest/reviews/ ($reason)") ;;  # a fallback guess: reported, NOT a collision NOTE
            ORPHAN)  orphan_report+=("$src (no plan body for $dest)") ;;    # Plan 336 R1: named, stays flat, never blocks
            SKIP)    ;;                                          # foreign file (the planner owns orphan-vs-foreign now)
        esac
    done
    # Apply: everything else first, the 331* plans last. copy → verify → remove per file (via _do_move).
    local -a ordered=()
    [[ ${#moves_other[@]} -gt 0 ]] && ordered+=("${moves_other[@]}")
    [[ ${#moves_331[@]}   -gt 0 ]] && ordered+=("${moves_331[@]}")
    local i m rc
    for (( i = 0; i < ${#ordered[@]}; i++ )); do
        m="${ordered[i]}"
        IFS=$'\t' read -r src dest <<<"$m"
        rc=0; _do_move "$dir" "$src" "$dest" || rc=$?   # `|| rc=$?` = condition context: set -e won't abort on
        case "$rc" in 0) ;; 2) remnant=1 ;; *) return 1 ;; esac   #   a return 2 (SF-4 skip) before we branch
    done
    # Plan 331b extension: opportunistically convert untouched-default override strays to `.example` (rename,
    # never delete) so they stop composing as placeholder noise. Fail-OPEN — a hygiene error must never abort
    # the plan migration (plans are the priority). Report any conversions.
    local _ovr
    # Capture the conversion list (stdout); let the "skipped symlink" warning through on stderr (skip + WARN).
    _ovr="$(convert_pristine_override_strays "$dir")" || true
    [[ -n "$_ovr" ]] && printf 'Converted untouched override file(s) to .example (kept as reference):\n%s\n' "$_ovr" >&2
    # Plan 331b status-backfill fold: ensure every migrated plan carries an explicit `Status:` FIELD (so the
    # generated inventory + the mandate-swap gate have one). FIELD-ONLY — real legacy value or Draft; the
    # accurate value is set later by the plan-touching skills. Fail-OPEN (a hygiene error never aborts migrate).
    local _bf
    _bf="$(backfill_migrated_statuses "$dir")" || true
    [[ -n "$_bf" ]] && printf 'Stamped a Status: field on plan(s) that lacked one (default Draft; skills refine it):\n%s\n' "$_bf" >&2
    # Informational: numbers that now have >1 plan (each in its own dir). Write a persistent, readable
    # collisions log the user + assistant can analyze (identify duplicates, link related plans) and echo a
    # pointer to stderr. Shown whether or not the migration otherwise completed. No renumbering is done.
    if [[ ${#note_report[@]} -gt 0 ]]; then
        local logf n
        logf="$(_generated_target "$dir/collisions.md" "$mig_id")"
        # Every number known so far: NOTEd this run + the sections of an existing generated log (a re-run must
        # never drop earlier sections); each section is rebuilt from the filesystem (post-move truth).
        local -a all_nums=("${noted_nums[@]}")
        if _is_generated_file "$dir/collisions.md"; then
            while IFS= read -r n; do all_nums+=("${n#\#\# }"); done < <(grep -E '^## [0-9]+[a-z]?$' "$dir/collisions.md" 2>/dev/null || true)
        fi
        {
            printf '# Plan-number collisions — GENERATED by `nyia plans migrate` (%s)\n\n' "$mig_id"
            printf 'These numbers are shared by MULTIPLE plans. Each migrated to its OWN dir (no renumbering —\n'
            printf 'that would break cross-plan references). resolve-by-number returns the FIRST listed, and a\n'
            printf "duplicate number's reviews were grouped under its first plan. Review these — ask your assistant\n"
            printf 'to identify true duplicates vs distinct plans, and link related ones (requirement/ordered/meta).\n\n'
            for n in $(printf '%s\n' "${all_nums[@]}" | LC_ALL=C sort -u); do   # keys are ^[0-9]+[a-z]?$ tokens
                printf '## %s\n' "$n"; _plan_dirs_for_number "$dir" "$n"; printf '\n'
            done
        } > "$logf" 2>/dev/null || true
        printf 'Note: %s plan number(s) have multiple plans — see %s (each in its own dir; no renumbering needed).\n' "${#note_report[@]}" "$logf" >&2
    fi
    # Plan 336 (risk M1): the stderr report scrolls away behind the docker launch — persist routes + orphans
    # in a generated notes file (same pattern as collisions.md) so the 328→328a-style guess stays auditable.
    if [[ ${#routed_report[@]} -gt 0 || ${#orphan_report[@]} -gt 0 ]]; then
        local notesf r
        notesf="$(_generated_target "$dir/migration-notes.md" "$mig_id")"   # never clobber a user-authored file
        {
            printf '# Migration notes — GENERATED by `nyia plans migrate` (%s)\n\n' "$mig_id"
            if [[ ${#routed_report[@]} -gt 0 ]]; then
                printf '## Routed by fallback (no body for the exact number)\n'
                printf 'Move a file if the guess is wrong; nothing was lost (the source is in the backup).\n\n'
                for r in "${routed_report[@]}"; do printf -- '- %s\n' "$r"; done; printf '\n'
            fi
            if [[ ${#orphan_report[@]} -gt 0 ]]; then
                printf '## Left flat — orphan reviews (no plan body, now or ever)\n'
                printf 'They do not block anything. Delete them, or create the plan they refer to and re-run `nyia plans migrate`.\n\n'
                for r in "${orphan_report[@]}"; do printf -- '- %s\n' "$r"; done
            fi
        } > "$notesf" 2>/dev/null || true
        {
            [[ ${#routed_report[@]} -gt 0 ]] && { printf 'Routed %s review(s) by fallback (no exact plan body):\n' "${#routed_report[@]}"; for r in "${routed_report[@]}"; do printf '  - %s\n' "$r"; done; }
            [[ ${#orphan_report[@]} -gt 0 ]] && { printf 'Left flat, %s orphan review(s) (no plan body — not blocking):\n' "${#orphan_report[@]}"; for r in "${orphan_report[@]}"; do printf '  - %s\n' "$r"; done; }
            printf 'See %s\n' "$notesf"
        } >&2
    elif _is_generated_file "$dir/migration-notes.md"; then
        rm -f "$dir/migration-notes.md"   # 336 review: a clean run must not leave STALE routes/orphans advertised
    fi
    if [[ "$remnant" -eq 0 ]]; then
        printf 'layout-v2\n' > "$dir/.layout-v2"
        # G1 (331d): the migration ran AND round-tripped (restore-verify + union invariant). This marker
        # gates the CLAUDE.md/prompt mandate swap — it must never appear on a partial/fail-closed run.
        printf 'verified %s\n' "$mig_id" > "$dir/.migration-verified"
        return 0
    fi
    # Partial: only genuinely FIXABLE remnants stay flat now (unsafe names/symlinks, an occupied or differing
    # dest). Orphans no longer count (Plan 336 R1). No data lost. Name every remnant so the user can act.
    {
        printf 'Migration incomplete — some files were LEFT FLAT (no data lost; full backup in %s). Resolve, then re-run `nyia plans migrate`:\n' "$archive_dir"
        if [[ "$unsafe_total" -gt 0 ]] 2>/dev/null; then
            printf '  - %s file(s) with unsafe names (tab/newline) or symlinks — rename/replace them:\n' "$unsafe_total"
            for _f in "$dir"/*; do
                [[ -f "$_f" || -L "$_f" ]] || continue   # -L too: a link whose target moved this run is dangling now
                _f="$(basename "$_f")"
                if [[ -L "$dir/$_f" || "$_f" == *$'\t'* || "$_f" == *$'\n'* ]]; then printf '      %q\n' "$_f"; fi
            done
        fi
        printf '  - any file named above as "stays flat" (occupied or differing destination).\n'
    } >&2
    return 3
}
