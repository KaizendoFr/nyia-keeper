#!/usr/bin/env bash
# lib/plan-commands.sh — Plan 331b: the `nyia plans` command group + launch-time migration offer.
#
# Split of concerns:
#   - detect_plan_layout / should_offer_migration / mark_migration_asked  — PURE, unit-tested.
#   - plans_migrate                                                       — command entry (thin glue
#     over the pure gate + execute_migration from plan-migration.sh).
# The launch path only DETECTS + OFFERS (see should_offer_migration); the actual migration runs ONLY via
# the explicit `nyia plans migrate` command, so a concurrent auto-launch can never trigger a migration.

_pc_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "${NYIA_PLAN_STATUSES:-}" ]]           || source "$_pc_dir/plan-resolution.sh"
[[ "$(type -t execute_migration)" == function ]] || source "$_pc_dir/plan-migration.sh"

NYIA_LAYOUT_MARKER=".layout-v2"      # written by execute_migration when zero legacy remnants remain
NYIA_MIGRATE_ASKED=".migrate-asked"  # durable nag-guard: we offered once, don't re-nag every launch

# detect_plan_layout <plans_dir> — print exactly one of: empty | new | legacy | mixed.
#   The marker wins (migration is "done" once .layout-v2 exists — the plan's launch rule).
#   Otherwise: flat NNN-*.md bodies + new-shape dirs → mixed; only flat → legacy; only dirs → new; neither → empty.
detect_plan_layout() {
    local dir="${1:-$NYIA_PLANS_DIR}" f d flat=0 dirs=0
    [[ -f "$dir/$NYIA_LAYOUT_MARKER" ]] && { printf 'new\n'; return 0; }
    for f in "$dir"/[0-9]*-*.md; do
        [[ -f "$f" ]] || continue
        case "$(basename "$f")" in plan-review-*|pair-review-*|code-review-*) continue ;; esac
        flat=1; break
    done
    for d in "$dir"/[0-9]*-*/; do
        [[ -d "$d" && -f "${d}plan.md" ]] && { dirs=1; break; }
    done
    if   [[ $flat -eq 1 && $dirs -eq 1 ]]; then printf 'mixed\n'
    elif [[ $flat -eq 1 ]];               then printf 'legacy\n'
    elif [[ $dirs -eq 1 ]];               then printf 'new\n'
    else                                       printf 'empty\n'
    fi
    return 0
}

# should_offer_migration <plans_dir> <is_tty:0|1> <force:0|1> — 0 to offer, non-zero to stay silent.
#   force=1 (explicit `nyia plans migrate`): offer whenever there is anything to migrate, ignoring TTY + nag-guard.
#   force=0 (launch path): offer ONLY when legacy/mixed AND interactive AND not already asked (CI/non-TTY never auto-offer).
should_offer_migration() {
    local dir="${1:-$NYIA_PLANS_DIR}" tty="${2:-0}" force="${3:-0}" layout
    layout="$(detect_plan_layout "$dir")"
    case "$layout" in legacy|mixed) ;; *) return 1 ;; esac   # new/empty → nothing to migrate
    [[ "$force" == "1" ]] && return 0
    [[ "$tty" == "1" ]]   || return 1                        # non-TTY / CI: never auto-offer
    [[ -f "$dir/$NYIA_MIGRATE_ASKED" ]] && return 1          # offered once already
    return 0
}

# mark_migration_asked <plans_dir> — set the durable nag-guard (best-effort; a read-only dir must not fail launch).
mark_migration_asked() {
    local dir="${1:-$NYIA_PLANS_DIR}"
    : > "$dir/$NYIA_MIGRATE_ASKED" 2>/dev/null || true
}

# plans_migrate <plans_dir> [--dry-run|--yes] — the `nyia plans migrate` command entry.
#   (no flag) interactive confirm; --dry-run prints the plan and changes nothing; --yes runs unattended.
plans_migrate() {
    local dir="${1:-$NYIA_PLANS_DIR}"; shift 2>/dev/null || true
    local mode="confirm"
    case "${1:-}" in
        --dry-run) mode="dry" ;;
        --yes|-y)  mode="yes" ;;
        "")        ;;
        *) printf 'unknown option: %s (use --dry-run or --yes)\n' "$1" >&2; return 2 ;;
    esac
    local layout; layout="$(detect_plan_layout "$dir")"
    case "$layout" in
        new)   printf 'Plans already use the per-plan layout (.layout-v2 present). Nothing to do.\n'; return 0 ;;
        empty) printf 'No plans to migrate.\n'; return 0 ;;
    esac
    if [[ "$mode" == "dry" ]]; then
        printf 'Dry run — the following would be migrated (no changes made):\n'
        plan_migration "$dir"
        return 0
    fi
    if [[ "$mode" == "confirm" ]]; then
        printf 'Legacy plan layout detected — migrate to the new per-plan directory layout?\n'
        printf 'A full backup will be made first. [y/N] '
        local reply=""; IFS= read -r reply || reply=""
        mark_migration_asked "$dir"                          # asked once, whatever the answer
        case "$reply" in
            y|Y|yes|YES|Yes) ;;
            *) printf 'Skipped. Plans stay flat; re-offer any time with: nyia plans migrate\n'; return 0 ;;
        esac
    fi
    execute_migration "$dir"
}

# maybe_offer_plan_migration <project_path> [is_tty] — launch GATE for a legacy plan store. Interactive only;
# never crashes the launch (call it in a condition context so set -e is suppressed). It PROMPTS every launch
# while the store is legacy (no nag-guard — migration is required), and STOPS the launch unless the store is
# migrated or the user explicitly insists on starting on the old layout.
#   RETURN: 0 = proceed with the launch ; NYIA_MIGRATION_RELAUNCH (20) = STOP the launch (either the store was
#   migrated → re-run for the new layout, OR the user declined and did NOT confirm "start anyway"). Prints its
#   own messages. Non-TTY / CI → warn + proceed (never block automation); new/empty layout → proceed silently.
NYIA_MIGRATION_RELAUNCH=20
maybe_offer_plan_migration() {
    local project="${1:-$PWD}" tty="${2:-}" launcher="${3:-}" dir layout reply="" confirm=""
    local launch_hint="${launcher:-nyia-<assistant>}"           # concrete when the caller passes it
    dir="$project/.nyiakeeper/plans"
    [[ -d "$dir" ]] || return 0
    if [[ -z "$tty" ]]; then { [[ -t 0 ]] && tty=1; } || tty=0; fi
    layout="$(detect_plan_layout "$dir")"
    case "$layout" in legacy|mixed) ;; *) return 0 ;; esac      # already migrated / empty → proceed
    if [[ "$tty" != "1" ]]; then
        printf 'note: plans are on the OLD flat layout — run `nyia plans migrate` (non-interactive launch, not migrating now).\n' >&2
        return 0                                                # CI / non-TTY → never block automation
    fi
    printf '\n════════════════════════════════════════════════════════════════════\n' >&2
    printf '  Nyia Keeper changed its plan layout (one folder per plan).\n' >&2
    printf '  Your plans are still on the OLD flat layout — the assistant skills\n' >&2
    printf '  expect the new one and will not work correctly until you migrate.\n' >&2
    printf '════════════════════════════════════════════════════════════════════\n' >&2
    printf 'Migrate now? A full backup is made first. [Y/n] ' >&2
    IFS= read -r reply || reply=""
    case "$reply" in
        n|N|no|NO|No)
            printf '\nStarting on the OLD layout is NOT recommended — the skills may misbehave.\n' >&2
            printf 'Start anyway, without migrating? [y/N] ' >&2
            IFS= read -r confirm || confirm=""
            case "$confirm" in
                y|Y|yes|YES|Yes) printf 'Proceeding on the old layout (you were warned).\n' >&2; return 0 ;;
                *)  printf '\nStopped — your plans are untouched. When you are ready:\n' >&2
                    printf '  • Migrate manually:  nyia plans migrate\n' >&2
                    printf '  • Or run %s again and choose Migrate.\n' "$launch_hint" >&2
                    return "$NYIA_MIGRATION_RELAUNCH" ;;
            esac ;;
        *)  # default (Enter) or an explicit yes → migrate, then CONTINUE the launch on the new layout. The
            # assistant prompt is composed in run_assistant AFTER this gate, so it reflects the migrated layout
            # — no restart needed. Only a PARTIAL/failed migration stops (so the user resolves before starting).
            local _erc=0
            execute_migration "$dir" >&2 || _erc=$?
            if [[ "$_erc" -eq 0 ]]; then
                printf '\nMigration complete — starting %s on the new layout.\n' "$launch_hint" >&2
                return 0
            fi
            printf '\nMigration did not fully complete (some files were left flat; a full backup was made).\n' >&2
            printf 'Resolve, then re-run: nyia plans migrate\n' >&2
            return "$NYIA_MIGRATION_RELAUNCH" ;;
    esac
}

# handle_plans_command <subcommand> [args…] — the `nyia plans` dispatcher. Defined HERE (a shipped lib) so
# BOTH the source bin/nyia and the generated runtime dispatcher source this lib and call it (mirrors
# handle_profile_command in profile-commands.sh) — avoiding the source/runtime parity gap. Operates on the
# current project's plan store; decisions/decision lazy-source the sibling plan-decisions.sh.
handle_plans_command() {
    local project="${PROJECT_PATH:-$(pwd)}"
    local plans_dir="$project/.nyiakeeper/plans"
    local subcommand="${1:-help}"; shift 2>/dev/null || true
    case "$subcommand" in
        migrate) plans_migrate "$plans_dir" "$@" ;;
        status)
            local _lay; _lay="$(detect_plan_layout "$plans_dir")"
            printf 'Plan layout: %s\n  (%s)\n' "$_lay" "$plans_dir"
            # Detector (331b fold): on an already-migrated store, flag plans missing an explicit Status field
            # so the user knows to run status-backfill (migrating projects get it auto during `migrate`).
            if [[ "$_lay" == "new" ]]; then
                [[ "$(type -t _plan_has_explicit_status)" == function ]] || source "$_pc_dir/plan-inventory.sh" 2>/dev/null || true
                if [[ "$(type -t _plan_has_explicit_status)" == function ]]; then
                    local _un=0 _p
                    for _p in "$plans_dir"/[0-9]*-*/plan.md; do   # new-shape bodies only (satellites live in reviews/)
                        [[ -f "$_p" ]] || continue
                        _plan_has_explicit_status "$_p" 2>/dev/null || _un=$(( _un + 1 ))
                    done
                    [[ "$_un" -gt 0 ]] && printf '\n%s plan(s) lack an explicit Status: field — run `nyia plans status-backfill` to add one.\n' "$_un"
                fi
            fi ;;
        decisions)
            [[ "$(type -t show_decisions)" == function ]] || source "$_pc_dir/plan-decisions.sh" \
                || { printf 'decisions library not found\n' >&2; return 1; }
            NYIA_PLANS_DIR="$plans_dir" show_decisions "$@" ;;
        decision)
            [[ "$(type -t add_decision_cli)" == function ]] || source "$_pc_dir/plan-decisions.sh" \
                || { printf 'decisions library not found\n' >&2; return 1; }
            local dec_action="${1:-}"; shift 2>/dev/null || true
            case "$dec_action" in
                add) NYIA_PLANS_DIR="$plans_dir" add_decision_cli "$@" ;;
                *)   printf 'Usage: nyia plans decision add <N> --by X --topic .. --question .. --decision .. [--options ..] [--supersedes ..]\n' >&2; return 1 ;;
            esac ;;
        status-backfill)
            [[ "$(type -t plans_status_backfill)" == function ]] || source "$_pc_dir/plan-inventory.sh" \
                || { printf 'inventory library not found\n' >&2; return 1; }
            NYIA_PLANS_DIR="$plans_dir" plans_status_backfill "$plans_dir" "$@" ;;
        todo)   # alias for the top-level `nyia todo` (the generated inventory) — discoverable under `plans`
            [[ "$(type -t handle_todo_command)" == function ]] || source "$_pc_dir/plan-inventory.sh" \
                || { printf 'inventory library not found\n' >&2; return 1; }
            handle_todo_command "$@" ;;
        help|--help|-h)
            printf 'Usage: nyia plans <command>\n\n'
            printf '  migrate [--dry-run|--yes]         Migrate flat plans/NNN-*.md to per-plan dirs (full backup first)\n'
            printf '  status                            Show the detected plan layout (empty|new|legacy|mixed)\n'
            printf '  todo [--write]                    The generated plan inventory (alias of `nyia todo`)\n'
            printf '  status-backfill [--yes]           Write a canonical Status: into plans that lack one (dry-run default)\n'
            printf '  decisions [N] [--by X] [--since]  Show recorded decisions for plan N (or all plans)\n'
            printf '  decision add <N> --by --topic --question --decision [--options --supersedes]  Record a decision\n' ;;
        *) printf 'Unknown plans command: %s (try: nyia plans help)\n' "$subcommand" >&2; return 1 ;;
    esac
}
