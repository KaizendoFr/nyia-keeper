---
name: implement-plan
description: Execute a single plan with runtime intelligence — pre-flight validation, per-step verification, regression detection, and checkpointing. Catches stale assumptions before coding and regressions at the step that introduced them. Use when implementing any plan.
---

# Implement-Plan - Runtime Plan Executor

Execute a plan with structured guardrails that a static plan file cannot provide:
pre-flight assumption checks, per-step verification with checkpointing, mid-run
regression detection, and a post-flight summary. Complements `/make-a-plan` (which
creates plans) and `/run-plans` (which orchestrates multiple plans in parallel).

## A) Parse & Load

Parse the arguments and load the plan:

```
/implement-plan <plan-ref>

plan-ref:
  Number (e.g., "228")     -> find .nyiakeeper/plans/228-*.md, then .nyiakeeper/shared/plans/228-*.md (exclude pair-review-* files). Private wins if found in both.
  File path                -> use directly
  Omitted                  -> check todo.md for the current Doing task, use its plan (path may point to shared/plans/)
```

1. **Resolve** plan-ref to an actual plan file. Read it completely.
2. **Extract steps** from the `## Implementation Steps` section.
3. **Detect resume point**: identify which steps are already checked `[x]`. The first
   unchecked `[ ]` step is the resume point. If all steps are checked, inform the user
   the plan is already complete.
4. **Meta-plan detection**: if the plan contains a `## Subplans` table, inform the user
   this is a meta-plan and suggest executing each subplan individually
   (`/implement-plan {N}a`, `/implement-plan {N}b`, etc.). Do not attempt to execute
   a meta-plan directly.

## B) Pre-flight Validation

Before touching any code, validate readiness. Scale effort to plan size:
- **Small plans (< 5 steps)**: git state check + baseline tests only.
- **Larger plans (>= 5 steps)**: full pre-flight including assumption scanning.

### B1) Git State

- Run `git status`. Require a clean worktree (no uncommitted changes).
- If dirty: show the status and ask the user to commit, stash, or explicitly confirm
  they want to proceed with a dirty worktree.

### B2) Assumption Check (best-effort, >= 5 steps only)

Scan the plan's Implementation Steps for **explicit file paths** and **function/variable
names**. For each reference found:
- Verify the file exists in the current codebase.
- Verify the function or variable exists in that file (grep for definition).
- Skip ambiguous or subjective references (e.g., "refactor the module").

If stale references are found, report them BEFORE any code changes:

```
Pre-flight: stale references detected
  - Step 3 references `handleAuth()` in `src/auth.js` — function not found
  - Step 5 references `config/routes.yaml` — file does not exist

Options:
  1. Update the plan to match current code, then re-run
  2. Proceed anyway (references may be created by earlier steps)
  3. Abort
```

Wait for user decision before proceeding.

### B3) Baseline Tests

- Identify the relevant test suite (from the plan's Testing Strategy section, or
  project conventions).
- Run the test suite and capture: total tests, pass count, failure list.
- Store this as the baseline for regression detection in Section D.
- If tests fail at baseline, warn the user — pre-existing failures will not be
  treated as regressions during execution.

### B4) Branch Suggestion

- Check the current branch. If on `dev`, `main`, or `master`, suggest creating a
  feature branch from the plan slug:
  ```
  You're on dev. Create branch feature/implement-{plan-slug}? [yes/no]
  ```
- If user accepts, create and switch to the branch.
- If user declines, proceed on the current branch.

### B5) Todo Update

- Find the plan's entry in `.nyiakeeper/todo.md`.
- Move it from Ready to Doing (if not already there).

## C) Step Execution Loop

Execute each unchecked step in order. This is NOT "do all steps at once" — it is a
controlled loop with verification and checkpointing.

For each unchecked step:

### C1) Announce

```
--- Step {N}/{total}: {step description} ---
```

### C2) Execute

Implement the step. Follow the plan's instructions for this specific step.

### C3) Verify

Check the expected outcome. Use what is concrete and verifiable:
- File exists or was created
- Function or class was added/modified (grep for it)
- Test passes
- Build succeeds
- Expected output matches

For subjective steps (e.g., "refactor for clarity"), skip automated verification —
proceed to checkpoint.

### C4) Checkpoint

**Write order: plan file first, then context.md.**

1. Mark the step `[x]` in the plan file (`## Implementation Steps`).
2. Update `.nyiakeeper/{assistant}/context.md` with progress:
   ```
   ## Current Session Focus
   - Working on: Plan {N} — {title}
   - Progress: Step {completed}/{total} complete
   - Last completed: Step {N} — {description}
   - Next: Step {N+1} — {description}
   ```

### C5) Stop on Failure

If verification fails:
1. **Do NOT proceed** to the next step.
2. Diagnose: what went wrong, which files are affected, what the expected vs actual
   outcome was.
3. Report to the user:
   ```
   Step {N} verification failed.
   Expected: {expected outcome}
   Actual: {what happened}

   Options:
     1. Fix the issue and retry this step
     2. Skip this step and continue (mark as skipped in plan)
     3. Abort execution (progress preserved — resume later)
   ```
4. Wait for user decision.

### C6) Phase Boundary Tests

If the plan has logical phases or groups of steps, run the test suite after
completing each phase. Compare results to the baseline captured in B3.

## D) Regression Detection

Run tests after each phase boundary (C6) and at the end of execution. Compare
against the baseline from B3.

If a previously-passing test now fails:

1. **STOP immediately** — do not execute further steps.
2. **Report** with specifics:
   ```
   Regression detected after Step {N}.

   Failing test: {test name}
   Status at baseline: PASS
   Status now: FAIL

   Most likely cause: changes in Step {N} to {files changed in that step}

   Options:
     1. Fix the regression now (stay on this step)
     2. Revert Step {N} changes and retry differently
     3. Continue with known regression (not recommended)
   ```
3. Wait for user decision before proceeding.

Pre-existing failures (tests that failed at baseline) are excluded from regression
detection — only newly-failing tests trigger a stop.

## E) Post-flight Report

After all steps are complete (or execution is stopped), output a structured summary:

```
## Implementation Report: Plan {N} — {title}

**Steps**: {completed}/{total} ({skipped} skipped)
**Tests**: baseline {X} pass -> now {Y} pass (+{new} new, {regressed} regressions)
**Files changed**: {list from git diff --name-only}
**Branch**: {current branch}

**Next actions**:
- [ ] Review changes: `/code-review {N}`
- [ ] Commit: `git add -p && git commit` (suggested message: {type}({scope}): {plan title})
- [ ] Update todo.md: move to Done
- [ ] Next plan: {N+1} (if applicable)
```

Update `.nyiakeeper/{assistant}/context.md` with the final status.

## F) run-plans Compatibility Note

This section is documentation only — no changes to `/run-plans` are required.

`/run-plans` currently executes plans by reading steps and implementing them directly.
In a future iteration, `/run-plans` MAY delegate per-plan execution to
`/implement-plan` to gain pre-flight validation and regression detection for each
plan in a batch. The contract for that delegation:

- `/run-plans` resolves plan references and builds the conflict matrix (its job).
- `/implement-plan` handles single-plan execution with guardrails (its job).
- Integration point: `/run-plans` invokes `/implement-plan {N}` per plan instead of
  executing steps inline.

This is a natural extension, not a current requirement. No changes to `/run-plans`
are needed for `/implement-plan` to be useful standalone.
