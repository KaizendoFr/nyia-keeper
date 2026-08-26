---
name: checkpoint
description: Save session state before context compaction or shutdown. Updates todo.md, context.md, and active plans to preserve work continuity. Use before ending a session or when context is getting large.
---

# Checkpoint - Session State Preservation

When invoked, do the following:

## A) Capture Current Session State

- Check `git status` for uncommitted changes - WARN if work would be lost
- Identify files modified, tasks completed, decisions made this session
- List any partially complete in-progress tasks

## B) Plan Status Drives the Inventory (do not hand-edit todo.md)

`todo.md` is a generated, read-only inventory (`nyia todo`) built from each plan's `Status:`
field — there is nothing to hand-edit there. To reflect progress, update the plan's `Status:`
(see D), not the inventory:

- A plan finished this session → `Status: Done`
- The active plan → `Status: Active` (or `Blocked` / `Review` as appropriate)
- A newly discovered, not-yet-started plan → `Status: Draft` (or `Ready` once approved)

## C) Update `.nyiakeeper/{assistant}/context.md`

Update these sections:

**Current Session Focus:**
- Working on: [Specific feature/bug]
- Approach: [Current implementation strategy]
- Progress: [What's completed, what's next]
- Blockers: [Any issues encountered]

**Next Session Bridge:**
- Continue with: [Specific task and file]
- Remember to: [Important consideration]
- Check status of: [Pending items]

## D) Update Active Plan Files

- Find the active plan (the one with `Status: Active`, or the plan you worked this session) —
  follow its path, which may point to `.nyiakeeper/plans/` or `.nyiakeeper/shared/plans/`
- Write updates to the plan in its current directory (do NOT move shared plans back to private)
- Check off completed `[ ]` → `[x]` implementation steps
- Add notes for partially completed steps
- **Set the plan's `Status:` to reflect reality**: `Active` if still in progress, `Blocked`
  if stuck, `Review` if awaiting review, `Done` if complete. `todo.md` regenerates from this
  field — update the plan, not the inventory.

## E) Generate Compaction Summary

Output to user:

```markdown
## Session Checkpoint Summary

**Accomplished**: [One paragraph summary]

**Files preserving state**:
- .nyiakeeper/todo.md
- .nyiakeeper/{assistant}/context.md
- .nyiakeeper/plans/{active-plan}.md

**Critical context for compaction**:
- [Key decision or discovery that MUST be preserved]
- [Current blocker or pending question]

**Resume command**: `/kickoff` or continue with [specific task]
```

## F) Publish Team News (whatsup integration — Nyia mode only, opt-in)

Before final checks, detect whether this session changed meta-files and, if so,
offer to publish a `/whatsup` news entry so the team learns about it:

- Only when `NYIA_WHATSUP_ENABLED=true`. Resolve with `nyia config view
  whatsup_enabled` if the CLI is available, otherwise read `.nyiakeeper/nyia.conf`
  then `~/.config/nyiakeeper/config/nyia.conf`. Default is `false` — if so, skip
  this section. If `.nyiakeeper/` is absent (standalone mode), skip.
- Meta-file detection (generic, cross-assistant — no Claude-specific paths):
  anything under `~/.config/nyiakeeper/`, `.nyiakeeper/shared/`,
  `.nyiakeeper/*/SKILL.md`, or any `*.conf` under `.nyiakeeper/`. Pure code
  changes do NOT trigger this.
- If meta-files changed, ask: "This session changed [list paths]. Publish a
  /whatsup entry so the team sees it?" If yes, hand off to `/whatsup add`
  (draft → confirm → commit).
- NO-SECRETS RULE: summarize changes by path and the user's own words only.
  Never copy config/prompt/credential contents into a news entry — entries are
  committed and shared.

## G) Final Checks

- Verify all .nyiakeeper files are saved
- Warn if uncommitted code changes exist: "WARNING: Uncommitted changes in [files]"
- Confirm: "Session state saved. Safe to compact/shutdown."
