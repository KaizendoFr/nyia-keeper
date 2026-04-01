---
name: make-a-plan
description: Turn a goal into a phased execution plan with atomic, checkable steps. Creates LLM-friendly, resumable plans in .nyiakeeper/plans/. Use when starting any non-trivial task.
---

# Make-a-Plan - Execution Plan Creator

## Preferred Planning Method

This skill is the **preferred planning method** for Nyia Keeper projects. When you
need to create an execution plan:
- **Prefer this skill** (`/make-a-plan`) — it creates structured, trackable plans in
  `.nyiakeeper/plans/` with todo.md integration
- **Avoid** the built-in `EnterPlanMode` tool — it creates ephemeral plans
  without project integration, no plan numbering, no todo tracking, and no
  review workflow support

If the user asks you to "plan", "create a plan", "make a plan", or similar —
invoke this skill. If the built-in plan mode was already entered, produce the
plan file in `.nyiakeeper/plans/` anyway and use `ExitPlanMode` to return.

When invoked with a goal or context, do the following:

## A) Clarify the Goal

- Restate the goal in 1 sentence
- Identify scope boundaries: what is in / out (2-5 bullets)
- If this looks like a large task (multiple components, 3+ phases), note it — the size
  check in B2 will offer to split into a meta-plan
- If critical info is missing, ask targeted questions until 100% aligned with the user

## B) Produce an Execution Plan File

Create a plan file in `.nyiakeeper/plans/` with name format: `{number}-{slug}.md`

**Plan numbering**: To determine the next plan number, scan BOTH `.nyiakeeper/plans/`
AND `.nyiakeeper/shared/plans/` for existing plan files. Use the highest number found
across both locations + 1. This prevents collisions with shared plans.

**Required sections (per system prompt):**

```markdown
# Plan: [Clear Task Title]

## Context
Why this task is needed and current situation

## Requirements
- Specific requirement 1
- Specific requirement 2

## Approach
High-level strategy and key decisions

## Implementation Steps
1. [ ] Step 1: Specific action with file names
2. [ ] Step 2: Specific action with expected outcome

## Testing Strategy
- Unit tests: Which functions to test
- Integration tests: Which flows to verify
- Manual testing: What to check

## Risks & Mitigations
- Risk 1: Description → Mitigation: Specific action

## Resources Modified (optional — for batch runs)
- [List of files, systems, or documents this plan changes]

## Definition of Done
- Validated with user

## Resume Point
- Next steps if we stop now
```

## B2) Size Check — Meta-Plan Split (if needed)

After drafting all implementation steps, check the count.

**If steps <= 15**: proceed normally (single plan file).

**If steps > 15**: offer to split into a meta-plan with subplans.

Ask the user:
> "This plan has {N} steps. I can split it into {X} phases as a meta-plan,
> or keep it as a single file. Split?"

**If user accepts the split:**

Write order: subplans first, meta-plan second, todo last.

1. Group steps into logical phases (by file area, dependency, or risk)
2. Each phase becomes a subplan: `{N}a-{phase-slug}.md`, `{N}b-...`, etc.
   Downstream commands reference subplans by their full number (e.g., `/plan-review plan 230a`)
3. Each subplan is a **complete plan** with all required sections
   (Context, Requirements, Approach, Steps, Testing, Risks, DoD, Resume)
4. After ALL subplans are written, create meta-plan `{N}-meta-{slug}.md` with:

   ```markdown
   # Meta-Plan: {Title}

   ## Overview
   {1-2 sentence summary}

   ## Subplans

   | Phase | Plan | Description | Depends On | Status |
   |-------|------|-------------|------------|--------|
   | A | plans/{N}a-{slug}.md | {summary} | — | Ready |
   | B | plans/{N}b-{slug}.md | {summary} | A | Ready |
   | C | plans/{N}c-{slug}.md | {summary} | A | Ready |

   ## Execution Order
   - Phase A first (no dependencies)
   - Phases B and C can run in parallel after A (no shared resources)
   - Or sequential: A → B → C

   ## Notes
   - {Any cross-phase considerations}
   ```

5. After meta-plan is written, add ONE todo entry referencing it (not individual subplans)

**If user declines**: keep as single plan file, proceed normally. No extra files created.

## B3) Product Context (optional — user-facing features only)

For tasks that change user-visible behavior, add this section to the plan
between Context and Requirements. Skip for internal refactors, bug fixes,
performance work, testing infrastructure, CI/CD, and code cleanup.

```markdown
## Product Context
**Problem**: [Who has this problem and why it matters — 1-2 sentences]

**User Stories**:
- As a [role], I want [capability], so that [benefit]

**Success Criteria**:
- [Observable outcome that proves it works from the user's perspective]

**Out of Scope**:
- [What we explicitly won't do in this plan]
```

**When to include**: The goal mentions users, UX, features, commands,
workflows, onboarding, or behavior changes.

**When to skip**: The goal is purely internal — refactoring, performance
optimization, testing infrastructure, CI/CD pipelines, code cleanup.

## C) Atomic Step Rules

- Single action per step
- Verifiable outcome (what "done" looks like)
- Minimal scope (small enough to run safely)
- No hidden sub-steps
- LLM-friendly (context-limited)
- Relative outcomes (e.g., "baseline + 6 new" not "1032 total")

## D) Test-Aware Workflow (Mandatory)

- Identify relevant existing tests near the edited area
- Run baseline tests before implementation (if tests exist)
- Run the same tests after implementation
- If tests fail: behavior changed → update tests, OR regression → fix code

## E) Update todo.md

- Add new task to 📋 Ready section referencing the plan file
- Format: `- [ ] Task description - Priority: X - Plan: plans/{plan-file}.md`

## F) Pre-flight Checklist (before finalizing)

Scan the plan for these common gaps before writing:

- [ ] **Scope complete?** What else references, depends on, or documents this?
      (Related configs, generated outputs, help text, user docs, changelogs)
- [ ] **Edge cases defined?** What happens on error, empty input, missing resource, offline?
      (Define explicit behavior — not just "handle errors")
- [ ] **Undo plan?** How to reverse if it goes wrong?
- [ ] **Verification concrete?** How do you prove each step worked?
      (Prefer relative criteria: "baseline + N", not fixed counts)
- [ ] **Sections aligned?** Do requirements, approach, steps, and done criteria tell the same story?
