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

## B) Update `.nyiakeeper/todo.md`

Use the exact format with emoji sections:

```markdown
## 🔥 Doing
- [ ] Current task - Priority: X - Plan: plans/xx.md

## 📋 Ready
- [ ] Next task - Priority: X

## 🧊 Backlog
- [ ] Future task - Priority: Low

## ✅ Done
- [x] Completed task - Completed: YYYY-MM-DD - Plan: plans/xx.md

## 🚧 Blocked
- [ ] Blocked task - Blocked by: Reason
```

- Move completed tasks to ✅ Done with completion date
- Update 🔥 Doing with current status
- Add discovered tasks to 📋 Ready or 🧊 Backlog

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

- Find plan referenced by current 🔥 Doing todo — follow the path in todo.md, which
  may point to `.nyiakeeper/plans/` or `.nyiakeeper/shared/plans/`
- Write updates to the plan in its current directory (do NOT move shared plans back to private)
- Check off completed `[ ]` → `[x]` implementation steps
- Add notes for partially completed steps

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

## F) Final Checks

- Verify all .nyiakeeper files are saved
- Warn if uncommitted code changes exist: "WARNING: Uncommitted changes in [files]"
- Confirm: "Session state saved. Safe to compact/shutdown."
