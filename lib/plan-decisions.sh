#!/usr/bin/env bash
# lib/plan-decisions.sh — Plan 331c: per-plan decisions.md (append-only) helpers.
#
# decisions.md lives in the new-shape plan dir (plans/N-slug/decisions.md). Entries are append-only;
# each carries a timestamp id (NYIA_DECISION_ID) + date (NYIA_DECISION_DATE), both overridable for tests.
# Requires lib/plan-resolution.sh (resolve_plan_dir); sources it from the same dir if not already loaded.

_pd_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _pd_dir="."
[[ -n "${NYIA_PLAN_STATUSES:-}" ]] || source "$_pd_dir/plan-resolution.sh"

# Who may be recorded as the decider.
NYIA_DECISION_ACTORS="user llm claude codex gemini opencode vibe"

# decisions_file <N> — print plan N's decisions.md path (new-shape only); non-zero if no dir home.
decisions_file() {
    local n="$1" d
    d="$(resolve_plan_dir "$n")" || return 1
    printf '%s\n' "$d/decisions.md"
}

# _dec_scrub <value> — make a field value safe to write as a single grammar line:
#   (M1) fold CR/newlines to a space so a value can never forge a "## " header or a "Key:" line;
#   (S1) redact obvious "<NAME>KEY|TOKEN|SECRET|PASSWORD|PASSWD|PWD=<value>" secrets → "…=[REDACTED]".
#   Case-insensitive via explicit classes (portable GNU+BSD sed — no `I` flag); LC_ALL=C = ASCII-only.
_dec_scrub() {
    local s="$1"
    s="${s//$'\r'/ }"; s="${s//$'\n'/ }"; s="${s//$'\t'/ }"
    # (337 security review) strip the remaining C0 controls + DEL byte-wise — terminal escapes (ESC, BEL, OSC)
    # from an untrusted decisions.md never reach the terminal; UTF-8 bytes (>= 0x80) are untouched.
    s="$(LC_ALL=C tr -d '\000-\037\177' <<<"$s")"
    LC_ALL=C sed -E 's/([A-Za-z0-9_]*([Kk][Ee][Yy]|[Tt][Oo][Kk][Ee][Nn]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Pp][Aa][Ss][Ss][Ww][Dd]|[Pp][Ww][Dd])[A-Za-z0-9_]*=)[^ ]+/\1[REDACTED]/g' <<<"$s"
}

# append_decision <N> <decided-by> <topic> <question> <options> <decision> [supersedes]
#   Header carries ONLY machine/validated tokens (id, ISO date, allowlisted actor); every free-text field
#   goes on its own line, scrubbed to a single injection-proof line. Written as ONE append (S4).
#   id  = ${NYIA_DECISION_ID:-D-<ts>-$RANDOM} + a duplicate-id guard (M2).
#   date= ${NYIA_DECISION_DATE:-today}, strict ISO YYYY-MM-DD (S6).
append_decision() {
    local n="$1" by="$2" topic="$3" q="$4" opts="$5" dec="$6" sup="${7:-${NYIA_DECISION_SUPERSEDES:-}}"
    local f id dt a ok=0 nl=$'\n' entry
    [[ -n "$by" ]] || return 2
    for a in $NYIA_DECISION_ACTORS; do [[ "$by" == "$a" ]] && ok=1; done
    [[ "$ok" -eq 1 ]] || { printf 'error: unknown decided-by "%s"\n' "$by" >&2; return 2; }
    [[ -n "$topic" && -n "$q" && -n "$dec" ]] || { printf 'error: topic, question and decision are required\n' >&2; return 2; }
    dt="${NYIA_DECISION_DATE:-$(date +%Y-%m-%d)}"
    [[ "$dt" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { printf 'error: date must be ISO YYYY-MM-DD (got "%s")\n' "$dt" >&2; return 2; }
    f="$(decisions_file "$n")" || return 1
    id="${NYIA_DECISION_ID:-D-$(date +%Y%m%d-%H%M%S)-$RANDOM}"
    [[ -f "$f" ]] && while grep -q "^## $id " "$f" 2>/dev/null; do id="${id}-$RANDOM"; done
    topic="$(_dec_scrub "$topic")"; q="$(_dec_scrub "$q")"; opts="$(_dec_scrub "$opts")"; dec="$(_dec_scrub "$dec")"
    entry="${nl}## ${id} (${dt}) · decided-by: ${by}${nl}Topic: ${topic}${nl}Question: ${q}${nl}Options: ${opts}${nl}Decision: ${dec}${nl}"
    [[ -n "$sup" ]] && entry="${entry}Supersedes: $(_dec_scrub "$sup")${nl}"
    printf '%s' "$entry" >> "$f"   # single write (S4): small append is atomic on the supported local FS
}

# read_decisions <N> — print plan N's decisions.md; non-zero if none.
read_decisions() {
    local n="$1" f
    f="$(decisions_file "$n")" || return 1
    [[ -f "$f" ]] || return 1
    cat "$f"
}

# add_decision_cli <N> --by X --topic T --question Q [--options O] --decision D [--supersedes S]
#   The safe WRITE path (library only — the user-facing `decision add` command was removed by Plan 337; the
#   file format in docs/PLAN_FILE_CONTRACT.md is the contract): parse named flags and dispatch to the
#   hardened append_decision (required-field + actor + ISO-date validation, secret redaction, injection-proof
#   grammar). Unknown flags are rejected; missing required fields are rejected by append_decision.
add_decision_cli() {
    local n="$1"; shift 2>/dev/null || true
    local by="" topic="" q="" opts="" dec="" sup=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --by)         by="$2";    shift 2 ;;
            --topic)      topic="$2"; shift 2 ;;
            --question)   q="$2";     shift 2 ;;
            --options)    opts="$2";  shift 2 ;;
            --decision)   dec="$2";   shift 2 ;;
            --supersedes) sup="$2";   shift 2 ;;
            *) printf 'add_decision_cli: unknown option %s\n' "$1" >&2; return 2 ;;
        esac
    done
    append_decision "$n" "$by" "$topic" "$q" "$opts" "$dec" "$sup"
}

# _emit_decision — render one parsed entry to stdout, honoring the --by / --since filters.
#   Uses the caller's locals (id/date/by/topic/q/dec/sup, want_by/since). Returns without printing if filtered.
_emit_decision() {
    [[ -z "$id" ]] && return 0
    parsed=$(( parsed + 1 ))
    # Plan 337: entries are appended by skills/humans, not by append_decision — required fields are checked and
    # every field is scrubbed (secret redaction + CR/LF fold) at RENDER time, so the display guard never depends
    # on who wrote the file.
    if [[ -z "$topic" || -z "$dec" ]]; then
        printf 'warning: malformed entry %s in %s: missing %s\n' "$id" "$f" "$([[ -z "$topic" ]] && printf Topic || printf Decision)" >&2; bad=1
    fi
    [[ -n "$want_by" && "$by" != "$want_by" ]] && return 0
    [[ -n "$since" && "$date" < "$since" ]] && return 0     # ISO dates compare lexically
    printf '%s  %s  · %s\n' "$(_dec_scrub "$id")" "$date" "$(_dec_scrub "$by")"   # header tokens scrubbed too (337)
    [[ -n "$topic" ]] && printf '  Topic:    %s\n' "$(_dec_scrub "$topic")"
    [[ -n "$q" ]]     && printf '  Question: %s\n' "$(_dec_scrub "$q")"
    [[ -n "$dec" ]]   && printf '  Decision: %s\n' "$(_dec_scrub "$dec")"
    [[ -n "$sup" ]]   && printf '  (supersedes %s)\n' "$(_dec_scrub "$sup")"
    printf '\n'
}

# _dec_warn_line <file> <n> <line> — name a malformed line without echoing it raw (a hand/LLM-edited file may
# carry escape sequences): non-printables stripped, truncated to 60 chars.
_dec_warn_line() {
    local t; t="$(LC_ALL=C tr -d '\000-\037\177' <<<"$3")"; t="${t:0:60}"
    printf 'warning: malformed entry at %s:%s: %s\n' "$1" "$2" "$t" >&2
}

# render_decisions <file> [--by <actor>] [--since <ISO-date>] — read-only, TOLERANT (Plan 337). Print each
# entry; a malformed line or a missing required field is named on stderr (file:line / entry id) and never
# silently dropped. Exit is non-zero only when something was malformed AND no entry parsed at all — a
# hand-edited file with one bad line still renders its good entries with rc 0. CRLF tolerated.
# Line-by-line (no pipe → set -e/pipefail safe).
render_decisions() {
    local f="$1"; shift || true
    local want_by="" since="" a
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --by)    want_by="$2"; shift 2 ;;
            --since) since="$2";   shift 2 ;;
            *) printf 'render_decisions: unknown option %s\n' "$1" >&2; return 2 ;;
        esac
    done
    [[ -f "$f" ]] || return 1
    local line n=0 bad=0 parsed=0 id="" date="" by="" topic="" q="" opts="" dec="" sup=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n+1)); line="${line%$'\r'}"
        if [[ "$line" =~ ^##\ (D[^\ ]+)\ \(([0-9]{4}-[0-9]{2}-[0-9]{2})\)\ ·\ decided-by:\ (.+)$ ]]; then
            _emit_decision                                  # flush the previous entry
            id="${BASH_REMATCH[1]}"; date="${BASH_REMATCH[2]}"; by="${BASH_REMATCH[3]}"
            topic=""; q=""; opts=""; dec=""; sup=""
        elif [[ "$line" =~ ^Topic:\ (.*)$ ]];      then topic="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^Question:\ (.*)$ ]];   then q="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^Options:\ (.*)$ ]];    then opts="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^Decision:\ (.*)$ ]];   then dec="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^Supersedes:\ (.*)$ ]]; then sup="${BASH_REMATCH[1]}"
        elif [[ -z "$line" ]]; then :                       # blank separator
        else
            _dec_warn_line "$f" "$n" "$line"; bad=1
        fi
    done < "$f"
    _emit_decision                                          # flush the last entry
    [[ "$bad" -eq 0 || "$parsed" -gt 0 ]]
}

# show_decisions [<N>] [--by <actor>] [--since <ISO>] — the read-only viewer entry.
#   With a plan number: render that plan's decisions.md. No number: aggregate across every new-shape plan dir.
show_decisions() {
    local n="" a rc=0 pass=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --by|--since) pass+=("$1" "$2"); shift 2 ;;
            -*) printf 'show_decisions: unknown option %s\n' "$1" >&2; return 2 ;;
            *) n="$1"; shift ;;
        esac
    done
    if [[ -n "$n" ]]; then
        local f; f="$(decisions_file "$n")" || { printf 'no plan dir for %s\n' "$n" >&2; return 1; }
        [[ -f "$f" ]] || { printf 'No decisions recorded for plan %s.\n' "$n"; return 0; }
        render_decisions "$f" "${pass[@]}"; return $?
    fi
    local d f any=0                                          # aggregate: every plans/<N-slug>/decisions.md
    for d in "$NYIA_PLANS_DIR"/*/; do
        f="${d}decisions.md"; [[ -f "$f" ]] || continue
        any=1
        printf '=== %s ===\n' "${d%/}"
        render_decisions "$f" "${pass[@]}" || true          # aggregate view: warnings on stderr, rc stays 0 (337)
    done
    [[ "$any" -eq 0 ]] && printf 'No decisions recorded in any plan.\n'
    return "$rc"
}

# count_decisions <N> — number of decision entries (0 if the file is absent/empty).
count_decisions() {
    local n="$1" f c
    f="$(decisions_file "$n")" || return 1
    [[ -f "$f" ]] || { echo 0; return 0; }
    c="$(grep -c '^## D' "$f" 2>/dev/null)" || c=0   # grep -c exits 1 on zero matches → don't abort (S2)
    echo "$c"
}
