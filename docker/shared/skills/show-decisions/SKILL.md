---
name: show-decisions
description: Read the decision trail for a plan — every question and what was decided, and whether the user or the LLM decided it. Use when someone asks "what did we decide for plan N?", "why did we choose X?", or wants a who-decided/what-changed audit across plans. Read-only; never writes.
---

# show-decisions - Plan Decision Viewer

Surfaces the durable *why* behind a plan. Nyia records directional decisions in an
append-only `plans/NNN-slug/decisions.md` (written by make-a-plan, plan-review
respond, and user answers tied to a plan). This skill reads and explains that
trail — it **never writes**. Recording decisions is done by those other skills and
by `nyia plans decision add`.

## What it wraps

The read path is the shipped CLI (works in dev, runtime, and installed builds):

```
nyia plans decisions            # aggregate: every plan's decisions
nyia plans decisions <N>        # one plan (e.g. nyia plans decisions 331)
nyia plans decisions --by user  # only user-made decisions (or --by llm / --by <assistant>)
nyia plans decisions --since 2026-08-01   # decisions on/after a date
```

Each entry carries a topic, the question, the options considered, the decision +
rationale, the date, and **who decided** (`user` / `llm` / a named assistant).

## How to run

1. **Resolve the target.** A number/plan-ref → that plan (`nyia plans decisions <N>`).
   No arg → the aggregate across all plans. Pass through `--by` / `--since` filters
   the user gives.
2. **Fetch, don't reinvent.** Run the CLI above to get the raw entries — it is the
   single source of truth and handles the dual plan-layout (new `plans/NNN-slug/`
   and legacy flat) plus the private/shared precedence. Do not parse `decisions.md`
   yourself.
3. **Add the LLM value.** Present the entries clearly, then help the user reason
   over them — answer "what did we decide about X", spot reversals/supersessions,
   summarize who decided what, or trace how a plan's direction evolved. This
   interpretation is the point of the skill over the raw CLI dump.
4. **If there are none**, say so plainly (a plan may simply have no recorded
   decisions yet) — do not invent decisions or infer them from the plan prose.

## Examples

- "What did we decide for 331?" → `nyia plans decisions 331`, then summarize the
  key calls (e.g. per-plan directories, interactive migration, no SQLite) with
  who-decided.
- "Which calls did I personally make this month?" →
  `nyia plans decisions --by user --since 2026-08-01`, then group by plan.
- "Why don't we use whatsup for this?" → find the relevant entry and quote its
  Decision + rationale; if it was later reversed, show the `supersedes` link.

## Rules

- **Read-only.** This skill never edits `decisions.md` or any plan file. To record
  a decision, use make-a-plan / plan-review respond, or `nyia plans decision add`.
- **No fabrication.** Only report decisions that are actually recorded; never
  present plan prose or your own inference as a logged decision.
- **Respect redaction.** The stored entries are already secret-redacted by the
  writer — never reconstruct or guess redacted values.
