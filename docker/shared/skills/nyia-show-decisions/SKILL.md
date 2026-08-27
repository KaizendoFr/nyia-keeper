---
name: nyia-show-decisions
description: Read the decision trail for a plan — every question and what was decided, and whether the user or the LLM decided it. Use when someone asks "what did we decide for plan N?", "why did we choose X?", or wants a who-decided/what-changed audit across plans. Read-only; never writes.
---

# show-decisions - Plan Decision Viewer

Surfaces the durable *why* behind a plan. Nyia records directional decisions in an
append-only `plans/NNN-slug/decisions.md` (written by make-a-plan, plan-review
respond, and user answers tied to a plan). This skill reads and explains that
trail — it **never writes**. Recording decisions is done by those other skills,
which append entries in the format below.

## What it reads

The files, directly — the host CLI is not available inside the container:

```
.nyiakeeper/plans/<N>-<slug>/decisions.md          # one plan
.nyiakeeper/plans/*/decisions.md                   # aggregate: every plan
.nyiakeeper/shared/plans/<N>-<slug>/decisions.md   # shared plans (private wins if both exist)
```

Entry format (one entry per decision, blank line between entries; see `docs/PLAN_FILE_CONTRACT.md`):

```
## D-<YYYYMMDD>-<HHMMSS>-<n> (<YYYY-MM-DD>) · decided-by: <user|llm|assistant-name>
Topic: <one line>
Question: <one line>
Options: <one line>
Decision: <one line>
Supersedes: <optional earlier id>
```

## How to run

1. **Resolve the target.** A number/plan-ref → that plan's `decisions.md` (per-plan dir
   `plans/<N>-*/decisions.md`; a legacy flat plan has none). No arg → every `decisions.md`
   under `plans/` (and `shared/plans/`).
2. **Parse the entries as written.** Split on `## D-` headers; take the id, the ISO date, and
   `decided-by` from the header, the fields from the following lines. Apply the user's filters
   by reading: `--by user|llm|<name>` matches `decided-by`; `--since YYYY-MM-DD` keeps entries
   whose header date is on/after it. A line that does not fit the format is reported as
   "malformed entry at <file>:<line>" — never silently dropped, never guessed.
3. **Add the LLM value.** Present the entries clearly (id, date, who, topic, decision), then help
   the user reason over them — answer "what did we decide about X", spot reversals
   (`Supersedes:`), summarize who decided what, or trace how a plan's direction evolved. This
   interpretation is the point of the skill over a raw dump.
4. **If there are none**, say so plainly (a plan may simply have no recorded decisions yet) —
   do not invent decisions or infer them from the plan prose.

## Examples

- "What did we decide for 331?" → read `plans/331-*/decisions.md`, then summarize the key calls
  (e.g. per-plan directories, interactive migration, no SQLite) with who-decided.
- "Which calls did I personally make this month?" → all `decisions.md`, keep
  `decided-by: user` with a date ≥ the 1st, then group by plan.
- "Why don't we use whatsup for this?" → find the relevant entry and quote its Decision +
  rationale; if it was later reversed, show the `Supersedes:` link.

## Rules

- **Read-only.** This skill never edits `decisions.md` or any plan file. To record a decision,
  use make-a-plan / plan-review respond (they append in the format above).
- **No fabrication.** Only report decisions that are actually recorded; never present plan
  prose or your own inference as a logged decision.
- **Respect redaction.** Entries may contain `[REDACTED]` — never reconstruct or guess redacted
  values, and never echo a secret you happen to find in one.
