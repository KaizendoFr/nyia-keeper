# Non-Tech Profile Template

A first-pass, general-purpose starting point for a NON-technical persona. Copy it into a
new persona with:

    nyia profile create <name> --persona --from non-tech

It is intentionally small and meant to be edited — treat it as a starting point, not a
finished set.

## What's in it

- `prompts/base-overrides.md` — a plain-language tone override (no jargon, define terms,
  confirm before anything irreversible).
- `skills/plan-anything/` — turn any goal into a simple ordered plan.
- `skills/summarize-notes/` — turn messy notes into a summary + action items.
- `skills/draft-document/` — draft or improve an email, memo, or proposal.
- `agents/everyday-assistant.md` — a friendly general-purpose persona.

## Good to know

- **Base skills still appear.** Nyia Keeper's base prompt and the assistant's built-in
  developer-workflow skills (code review, planning, etc.) are installed in the container
  and are always present — a profile cannot remove them. This template only ADDS a
  friendly layer on top.
- **It's yours to change.** Once seeded, this content lives in your profile
  (`profiles/<name>/`) and never syncs back to the template or to your default. Add,
  edit, or delete freely.
