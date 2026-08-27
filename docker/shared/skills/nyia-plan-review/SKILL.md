---
name: nyia-plan-review
description: Review a plan or respond to a review as an architect. Supports round-trip review workflows between assistants with human-in-the-loop discussion. Use /nyia-plan-review plan {N} to review, /nyia-plan-review respond {N} to respond to a review.
---

# Plan-Review - Architect Plan Review Skill

Supports two modes for round-trip plan review workflows between assistants.

## A) Argument Parsing

Parse the arguments to determine mode and plan reference:

```
/nyia-plan-review [subcommand] <plan-ref> [as <lens>]

subcommand:
  "plan" or omitted  → PLAN MODE (reviewer writes/updates review)
  "respond"          → RESPOND MODE (plan author reads review, discusses, updates plan)

plan-ref:
  Number (e.g., "121")     → find the plan's directory .nyiakeeper/plans/121-*/plan.md (per-plan layout; its reviews/ and decisions.md sit beside it), then legacy flat .nyiakeeper/plans/121-*.md, then the same two shapes under .nyiakeeper/shared/plans/ (exclude plan-review-*, pair-review-* and code-review-* files). Private wins if found in both.
  File path                → use directly

lens (optional — plan mode only, shapes review perspective):
  "architect" / omitted → Design, simplicity, consistency (default)
  "risk"    → Edge cases, error paths, undo, safety
  "user"    → Docs, help text, onboarding, UX
  "ops"     → Deploy, dist, verify, monitor
  Multiple: "as risk,user". Parse order: subcommand → ref → "as" lens
```

## B) Load Context (both modes)

1. Resolve plan-ref to an actual plan file (`{N}-{slug}/plan.md` first, legacy flat `{N}-{slug}.md` as fallback). Search `.nyiakeeper/plans/` first, then `.nyiakeeper/shared/plans/` as fallback. Read it completely.
2. Find review files matching: `plan-review-*-plan-{N}-*.md` OR `pair-review-*-plan-{N}-*.md` in the plan's `reviews/` directory (`.nyiakeeper/plans/{N}-{slug}/reviews/`); for a legacy flat plan, in the same directory as the plan file. The host-side plan migration moved the old flat reviews into `reviews/`.
3. Determine round number: count `## Round` headers in existing review file. Next = count + 1. No file = Round 1.
4. Identify yourself (your assistant name) from context or environment.

### Meta-Plan Detection

If the plan file is a meta-plan (contains a `## Subplans` table):
1. Read the meta-plan AND all referenced subplan files (`{N}a-*.md`, `{N}b-*.md`, etc.)
2. Review proceeds in two layers:
   - **Per-subplan**: each subplan gets normal review (required sections, atomicity, risks)
   - **Cross-cutting**: review concerns that span subplans (see Section C)

## C) PLAN MODE — Write or Update Review

You are the **reviewer**. You are reviewing someone else's plan.

### Round 1 (no existing review by you)

Perform a full review with these focus areas:

**System prompt compliance:**
- Required sections present? (Context, Requirements, Approach, Steps, Testing, Risks)
- Steps truly atomic? (single action, verifiable outcome, minimal scope)

**Review focus:**
- KISS / avoid overengineering
- Security by design
- Testability and test-aware workflow
- Risk management and rollback

**Completeness focus:**
- Scope: plan covers all affected surfaces? (docs, configs, outputs, help text)
- Edge cases: error/fallback behaviors explicitly defined?
- Verification: checks targeted and concrete?
- Criteria: Definition of Done uses relative measures, not absolute numbers?
- Consistency: requirements, approach, steps, and done criteria agree?

**Identify:** What's solid, issues/risks (High/Med/Low), missing tests, non-atomic steps.

### Meta-Plan Cross-Cutting Review (in addition to normal review)

When reviewing a meta-plan, also check:
- **Completeness**: no work falls between phases (gap analysis)
- **Dependencies**: phase ordering is correct (B really needs A first?)
- **Consistency**: assumptions in subplan A don't contradict subplan C
- **No duplication**: same work isn't done in multiple subplans
- **Parallelizability**: phases marked parallel truly share no resources
- **Integration points**: how phases reconnect (shared files, test suites)

Output one review file with per-subplan sections plus a cross-cutting section.

Discuss findings with the human before writing.
Write to: `.nyiakeeper/plans/{N}-{slug}/reviews/plan-review-{me}-for-{target}-plan-{N}-{slug}.md` (create `reviews/` if missing; for a legacy flat plan, write next to the plan file). Keep exactly this basename convention — the migrator and the `nyia` resolvers key on it.

Use this format:
```markdown
# Plan Review: Plan {N} - {title}
**Reviewer**: {me} | **For**: {target} | **Plan**: {filename}

## Round 1 — {date}

### Review Summary
[Max 8 lines]

### What's Solid
- [point 1]

### Issues / Risks (Ranked)
#### High
- [critical issue]
#### Medium
- [important issue]
#### Low
- [minor issue]

### Recommendations
1. [Fix] - because [reason]

### Test Strategy
- [What to test]

### Refined Atomic Next Steps
- [ ] Step 1 (Done when: [condition])
```

### Round N+1 (review exists, plan was updated since last round)

1. Read your previous review
2. Read the current plan — compare with your last review to identify what changed
3. Focus only on changes and unresolved items from previous round
4. Discuss with human before writing

Append to the existing review file:
```markdown
## Round {N+1} — {date}

### Changes Since Round {N}
- [what changed in the plan]
### Updated Assessment
- [focused on changes, referencing previous recommendations]

### New/Remaining Issues
- [any new or unresolved items]
```

## D) RESPOND MODE — Read Review, Discuss, Update Plan

You are the **plan author**. Someone else reviewed your plan.

### Steps

1. **Find the review**: Look for `plan-review-*-for-{me}-plan-{N}-*.md` or `pair-review-*-for-{me}-plan-{N}-*.md` in the plan's `reviews/` directory first (`.nyiakeeper/plans/{N}-{slug}/reviews/`), then flat in `.nyiakeeper/plans/` and `.nyiakeeper/shared/plans/` (search both prefixes for backward compatibility with existing review files)
   - If multiple files match, use most recently modified. If ambiguous, ask the human.
   - If no review found, inform the human and stop.

2. **Read and present**: Read the review file. Summarize to the human:
   "{reviewer} raised these points in Round {N}: [list of recommendations]"

3. **Discuss each point**: Walk through recommendations with the human.
   Let them accept, reject, or modify each one. Free discussion is fine too.

4. **CONFIRMATION GATE** (mandatory — NEVER skip):
   After discussion, present the agreed changes:
   "Here are the changes I'll make to the plan:
   - [change 1]
   - [change 2]
   Apply these changes? [yes/no]"

   Wait for explicit "yes" before editing ANY file. If "no", ask what to adjust.

5. **Update the plan**: Only after confirmation, edit the plan file with agreed changes.
   Add at the bottom of the plan: `## Updates after Round {N} review\n- [summary of changes]`
   - **Status**: a plan under review carries `Status: Review`. Once the agreed changes are
     applied and the plan is approved / ready to implement, set its `Status: Ready`.
   - **Record decisions (331c)**: each recommendation you accepted, rejected, or deferred is
     a decision — append it to the plan's append-only `decisions.md`:
     ```
     ## D-<YYYYMMDD>-<HHMMSS>-<random> (<YYYY-MM-DD>) · decided-by: <user|llm|assistant-name>
     Topic: <one line>
     Question: <one line>
     Options: <one line, "|"-separated>
     Decision: accepted|rejected|deferred: <one line>
     Supersedes: <optional earlier id>
     (append to `{N}-{slug}/decisions.md`, blank line before the entry, one line per field, no secrets — see docs/PLAN_FILE_CONTRACT.md)
     ```
     Use `--supersedes <N>` when the call reverses an earlier decision.

6. **Guide next step**: Tell the human:
   "Plan updated. To continue the review cycle, run `/nyia-plan-review plan {N}` on {reviewer}'s side."

## F) Review Lenses (optional)

When a lens is specified, focus primarily through that lens while covering base criteria.

| Lens | Primary focus | Key questions |
|------|--------------|---------------|
| **architect** | Design, simplicity, patterns | Simplest approach? Consistent? |
| **risk** | Edge cases, safety, undo | What goes wrong? How to reverse? |
| **user** | Docs, help, UX, onboarding | User understands? Help updated? |
| **ops** | Deploy, dist, verify, monitor | How shipped? How verified? |
Default: **architect**. Multiple: `/nyia-plan-review plan 213 as risk,user`

## G) Key Rules

- **Human-in-the-loop**: ALWAYS discuss before writing in both modes. Never auto-write.
- **Confirmation gate**: In respond mode, NEVER edit the plan without explicit "yes" from the human.
- **Backward compatible**: `/nyia-plan-review 121` (no subcommand) = plan mode.
- **Delta = LLM comparison**: Compare plan content vs last review content. No git diff needed.
- **One review file per pair**: `plan-review-{from}-for-{target}-plan-{N}-{slug}.md`, living in `plans/{N}-{slug}/reviews/`. Rounds append to the same file.
- **Legacy file discovery**: Always search for both `plan-review-*` and `pair-review-*` prefixes when looking for existing review files, so that the 120+ existing `pair-review-*` files remain discoverable.
