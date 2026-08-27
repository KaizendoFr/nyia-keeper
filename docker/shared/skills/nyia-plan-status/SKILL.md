---
name: nyia-plan-status
description: A normalized, filterable table of the project's plans — id, a concise purpose, and status — plus a single-plan drill-down. Use when someone asks "where are we regarding the plans?", "which plans are running / done / to-do?", "what's blocked?", or "status by roadmap / mvp / RC1". Read-only; it renders, it never changes a plan.
---

# plan-status - the "where are we?" plan view

Answers the recurring "where do the plans stand?" question as a clean table, filtered and grouped
however the user asks. It is a **read-only lens** over the plan store — it never edits a plan or the
inventory. (To change a plan's status you set `Status:` in the plan; the skills that do the work
maintain it.)

## Data source — reuse, never re-derive

Status is owned by the generated inventory. Do NOT re-read or re-infer it plan-by-plan.

1. **Status + id + slug**: read `.nyiakeeper/todo.md` — the generated inventory (one line per plan,
   worst-status first), written by the host at launch and after the session. If it is missing or older than
   the plans, read each `plans/NNN-slug/plan.md` line-2 `Status:` instead (read-only; never write `todo.md`).
   A plan with no `Status:` line counts as `Draft`. This is the single source of truth for each plan's `Status:`.
2. **Roadmap label** (optional axis): each plan may carry an optional free-text `Roadmap:` line near the
   top (e.g. `Roadmap: mvp`). Read it directly from the plan — the first non-fenced `Roadmap:` line, the
   value up to any trailing ` #` comment. (The shipped `read_plan_roadmap` in `plan-resolution.sh` defines
   the exact rule and is the test oracle; you don't need to invoke it — just read the field.) A plan
   without a `Roadmap:` line is simply **Unlabeled**, never hidden.
3. **Concise purpose**: distill a one-line purpose from each plan's title / Context — short, "just enough
   context," not a paragraph. This is the only part you generate; status and label come from the tools.

## Delegate the render to a cheaper model (if your runtime supports it)

Rendering this view — distilling one-line purposes and formatting/filtering a table over already-
deterministic data — is not flagship-tier reasoning. **If your assistant runtime can run a subtask on a
cheaper / smaller / faster model tier, use it for the purpose-distillation + table render** (keeps the
main model free). If it can't, just do it inline. (Capability-based on purpose — this one skill ships to
every assistant, so it names no specific vendor model.)

## Invocation & filters

```
/nyia-plan-status                 # default view (see Rendering)
/nyia-plan-status running         # lifecycle filter → Active/Review/Blocked
/nyia-plan-status done            # → Done
/nyia-plan-status todo            # → Draft/Ready (not yet started)
/nyia-plan-status blocked         # → Blocked
/nyia-plan-status as mvp          # roadmap-label filter (any non-lifecycle token; `as` is optional)
/nyia-plan-status mvp             #   same
/nyia-plan-status running mvp     # combine: Active/Review/Blocked AND Roadmap: mvp
/nyia-plan-status <N>             # single-plan drill-down (e.g. /nyia-plan-status 331)
```

Lifecycle tokens map onto the canonical enum `Draft Ready Active Blocked Review Done Dropped`
(`running` = Active + Review + Blocked; `todo` = Draft + Ready). Any token that isn't a lifecycle word
is treated as a **roadmap label** (case-insensitive).

## Rendering (default view, scale-aware)

Columns: **id · purpose (concise) · status** (and a **roadmap** group when any plan has a label).

- **Small store (≲15 live plans)**: show the full table, grouped by roadmap label; collapse `Done`/
  `Dropped` to a count line (`Done: 12`) so the board shows what's live.
- **Large store (≳15 live plans)**: lead with counts (by status, and by roadmap label), then list only
  the live rows (`Blocked`, `Active`, `Review`, then `Ready`); collapse the rest with a hint to expand
  via a filter (e.g. "run `/nyia-plan-status done` for the 40 completed"). The ~15 threshold is a guideline,
  not a hard rule — favor a view the user can scan.

Order rows worst-status-first (`Blocked Active Review Ready Draft Done Dropped`), same as the generated inventory.

## Single-plan drill-down (`/nyia-plan-status <N>`)

- **Meta-plan** (has a `## Subplans` table): render that table normalized — each subplan's id, one-line
  purpose, and status.
- **Leaf plan**: render its `## Implementation Steps` with a done/■ marker per step and a one-line
  purpose; show the plan's own `Status:` and `Roadmap:` at the top. Keep it concise — enough to answer
  "where is this plan?", not the whole file.

## Rules

- **Read-only.** Never edit a plan, `plan.md`, `todo.md`, or any status/roadmap field. Rendering only.
- **Reuse the files.** Status from the inventory or the `Status:` line verbatim (never re-derive from prose →
  no enum drift); roadmap from the plan's `Roadmap:` line. Only the concise purpose is LLM-generated.
- **Handle both layouts.** New per-plan dirs (`NNN-slug/plan.md`) and legacy flat plans (`NNN-slug.md`) both
  count; review files (`plan-review-*`, `code-review-*`, `pair-review-*`) are not plans.
- **Missing is normal.** No `Roadmap:` → Unlabeled; no explicit `Status:` → the inventory shows Draft.
  Never hide a plan for lacking a field.
