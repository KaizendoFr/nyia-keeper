---
name: kickoff
description: Session start skill. Reconstructs previous session state from .nyiakeeper files, then outputs a phased execution plan with atomic steps. Use at the beginning of any coding session.
---

# Kickoff - Session Start

When invoked, follow the Context Management Protocol:

## A) Read Project State (MANDATORY - do not assume)

1. Read `.nyiakeeper/todo.md` FIRST - check current task status (🔥 Doing section)
   - If `todo.md` doesn't exist but `.nyiakeeper/shared/todo.md` does, use shared as starting point
   - If both exist, use private (working copy) but note shared exists
2. Read `.nyiakeeper/{assistant}/context.md` - understand where previous session left off
3. Find and read active plans referenced by in-progress todos — plan paths may point to
   either `.nyiakeeper/plans/` or `.nyiakeeper/shared/plans/` (follow the path in todo.md).
   Also scan `.nyiakeeper/shared/plans/` for active plans not referenced in todo.md.
4. Inspect git state: `git status`, `git branch --show-current`, `git log -n 5 --oneline`

## B) Output "State Snapshot"

Provide a concise summary:
- Current branch and uncommitted changes (if any)
- In-progress task from todo.md (🔥 Doing)
- Last session's work from context.md "Next Session Bridge"
- Active plan progress (which steps are done/pending)

## C) Produce or Update Execution Plan

- Structure as: Phase → Task → Atomic steps
- Atomic step rules: single action, verifiable outcome, minimal scope, LLM-friendly
- Output as Markdown checklist with empty [ ] boxes
- Reference plan file if exists, or suggest creating one for complex tasks

## D) Resumability

- End with "Resume point" (1-3 bullets): what to do next if we stop now
- If critical context is missing, ask up to 2 targeted questions, then proceed with explicit assumptions
