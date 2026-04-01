---
name: run-plans
description: Execute multiple plans in parallel where safe. Reads plan metadata to detect conflicts, groups into parallel batches, and coordinates verification. Use when you have 2+ plans ready to implement.
---

# Run-Plans - Parallel Plan Executor

When invoked with plan references, do the following:

## A) Parse Arguments

- Accept plan numbers or file paths: `/run-plans 212 213 206`
- Resolve each to its plan file: search `.nyiakeeper/plans/` first, then `.nyiakeeper/shared/plans/` as fallback. Private wins if found in both.
- Read each plan completely

## B) Build Conflict Matrix

For each plan, extract the "Resources Modified" section.
If a plan has no "Resources Modified" section, read its Implementation Steps
and infer which resources (files, systems, documents) it touches.

Build a matrix:
- Plans that share NO resources → safe to run in parallel
- Plans that share resources → must be sequenced or analyzed for non-overlapping scope

Present the matrix to the user:

    Conflict Analysis:
      Plan 212: pipeline.yml, release.sh, promote-channel.sh
      Plan 213: cli-parser.sh, bin/nyia, preprocess-runtime.sh
      Plan 206: docker/shared/skills/ (new files only)

    Safe parallel groups:
      Group 1: [212, 213, 206] — no shared resources

    Conflicts detected: (none)

## C) Propose Execution Strategy

Based on conflict analysis, propose:

- **Parallel batches**: which plans run simultaneously
- **Sequenced plans**: which must run after others (and why)
- **Verification strategy**: run tests once after all plans, or per-batch
- **Isolation method**: worktree-isolated subagents for parallel plans

Get user approval before proceeding.

## D) Preflight

Before any execution:
1. Verify clean git state (`git status` — no uncommitted changes)
2. Capture current branch name (restore point)
3. Confirm all plans are in Ready state in todo.md
4. If dirty worktree or uncommitted changes, STOP and ask user to commit or stash

## E) Execute

For each parallel batch:
1. Launch one worktree-isolated subagent per plan
2. Each subagent: read the plan, implement all steps, commit in worktree
3. Wait for all subagents in the batch to complete
4. Present results — NEVER auto-merge without explicit user approval
5. On approval: merge each worktree branch, resolve conflicts if any
6. Run verification (tests, checks) once per batch

For sequenced plans:
1. Execute in order, one at a time on current branch
2. Verify after each before starting next

If a subagent fails mid-batch:
1. Stop remaining subagents in the batch
2. Report which plan failed and why
3. Preserve completed worktree branches for inspection (don't merge)
4. User decides: fix and retry, skip failed plan, or abort batch
5. NEVER leave merged partial results — all-or-nothing per batch

## F) Post-Execution

- Run final verification (full test suite or equivalent)
- Update todo.md: move completed plans from Ready → Done
- Update context.md with batch execution summary
- Report results:

      Batch Execution Complete:
        ✅ Plan 212: committed (abc1234)
        ✅ Plan 213: committed (def5678)
        ✅ Plan 206: committed (ghi9012)
        Tests: 1038/1038 pass (baseline: 1032)

## G) Conflict Resolution

If conflicts are detected:
- **Non-overlapping scope** (same file, different sections): allow parallel with worktree isolation
- **Overlapping scope** (same file, same section): sequence — smaller plan first
- **Uncertain inference** (Resources Modified missing, steps ambiguous): **default to sequential**
- **Unclear after inference**: ask the user to decide

## H) Key Rules

- ALWAYS verify clean git state before execution (preflight)
- ALWAYS present conflict analysis before executing
- ALWAYS get user approval for execution strategy
- ALWAYS get user approval before merging to main
- NEVER run conflicting plans in parallel without worktree isolation
- NEVER auto-merge — all merges require explicit user approval
- Run verification ONCE per batch, not per plan (efficiency)
- If a subagent fails, stop the batch and report — don't continue blindly
- On partial failure, preserve worktree branches for inspection — never discard
