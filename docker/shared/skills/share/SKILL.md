# Share - Promote/Demote Plans Between Private and Shared

Move plans (and their review files) between `.nyiakeeper/plans/` (private, gitignored)
and `.nyiakeeper/shared/plans/` (team-visible, committed to git). Also supports
sharing a snapshot of `todo.md`.

## A) Argument Parsing

```
/share <subcommand> [args]

subcommand:
  plan <N>          → move plan N + reviews to shared/plans/, rewrite todo.md path
  todo              → copy todo.md to shared/todo.md (snapshot)
  list              → show what's currently shared
  unshare plan <N>  → move plan N + reviews back to plans/, rewrite todo.md path
  unshare todo      → remove shared/todo.md
```

## B) `/share plan <N>`

1. **Resolve** plan file: find `.nyiakeeper/plans/{N}-*.md` (exclude `pair-review-*`,
   `plan-review-*`, `code-review-*` files).
   - If not found in `plans/`, check if already in `shared/plans/` — if so, print
     "Plan {N} is already shared" and stop.
   - If not found in either location, print "Plan {N} not found" and stop.

2. **Create** `.nyiakeeper/shared/plans/` if it doesn't exist.

3. **Move plan file** from `plans/` to `shared/plans/`.

4. **Move associated review files** matching any of these patterns in `plans/`:
   - `pair-review-*-plan-{N}-*.md`
   - `plan-review-*-plan-{N}-*.md`
   - `code-review-plan-{N}*.md`

5. **Rewrite todo.md reference**: find any line containing `Plan: plans/{N}-` and
   replace with `Plan: shared/plans/{N}-` (preserving the rest of the filename).
   If `todo.md` doesn't exist or has no matching reference, skip silently.

6. **Print summary**:
   ```
   Shared plan {N}:
     Moved: {plan-file}
     Moved: {review-file-1}  (if any)
     Moved: {review-file-2}  (if any)
     Updated: todo.md path reference  (if applicable)
   ```

## C) `/unshare plan <N>`

1. **Resolve** plan file: find `.nyiakeeper/shared/plans/{N}-*.md` (exclude review files).
   - If not found in `shared/plans/`, check if already in `plans/` — if so, print
     "Plan {N} is already private" and stop.
   - If not found in either location, print "Plan {N} not found" and stop.

2. **Move plan file** from `shared/plans/` back to `plans/`.

3. **Move associated review files** (same patterns as share, from `shared/plans/` to `plans/`).

4. **Rewrite todo.md reference**: find any line containing `Plan: shared/plans/{N}-` and
   replace with `Plan: plans/{N}-` (preserving the rest of the filename).

5. **Print summary** (same format as share, with "Unshared" label).

## D) `/share todo`

1. **Copy** (not move) `.nyiakeeper/todo.md` to `.nyiakeeper/shared/todo.md`.
   - If `todo.md` doesn't exist, print error and stop.
2. **Print confirmation**:
   ```
   Copied todo.md → shared/todo.md
   Note: Your private todo.md remains the working copy.
   shared/todo.md is a snapshot for the team — re-run /share todo to update it.
   ```

## E) `/unshare todo`

1. **Remove** `.nyiakeeper/shared/todo.md`.
   - If it doesn't exist, print "shared/todo.md not found — nothing to unshare" and stop.
2. **Print confirmation**: "Removed shared/todo.md"

## F) `/share list`

1. **Scan** `.nyiakeeper/shared/plans/` for plan files (exclude review files:
   `pair-review-*`, `plan-review-*`, `code-review-*`).
2. **Check** whether `.nyiakeeper/shared/todo.md` exists.
3. **Print summary**:
   ```
   Shared artifacts:

   Plans (N shared):
     - 234-feature-auth.md
     - 235-fix-paths.md

   Todo: shared  (or "Todo: not shared")
   ```
   If no plans and no todo: "Nothing shared yet. Use /share plan <N> or /share todo."

## G) Key Rules

- **Plans are private by default** — `/share` is an explicit publish action.
- **Review files travel with their plan** — never split plan from its reviews.
- **Todo is a snapshot copy** — private todo.md remains the working copy.
- **Todo.md paths are rewritten** on share/unshare to keep omitted-argument workflows working.
- **Context.md is never shared** — it contains per-assistant session state.
- **Idempotent**: sharing an already-shared plan prints a message, doesn't error hard.
