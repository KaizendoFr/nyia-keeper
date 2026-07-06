# Team Marketplace

This is a **private Nyia Keeper marketplace** — a Git repository that distributes
shared **skills** and **agents** to every team member, in every project, automatically.

## Layout

```
marketplace.json     # Marketplace metadata
skills/              # Shared skills — one subdirectory per skill, each with a SKILL.md
  my-skill/
    SKILL.md
agents/              # Shared agents — one Markdown file per agent
  my-agent.md
```

## For the maintainer (you)

1. Add skills under `skills/<skill-name>/SKILL.md` and agents under `agents/<agent>.md`.
2. Commit and push to your team's Git host (GitLab, GitHub, Bitbucket, self-hosted).

   ```sh
   git add -A && git commit -m "Add team skills/agents"
   git push
   ```

## For team members

Set the marketplace URL once (globally, or per project):

```sh
nyia config global marketplace_url=<this-repo-git-url>
# or, to pin a marketplace for a single project:
nyia config project marketplace_url=<this-repo-git-url>
```

On the next launch in **any** project, Nyia clones/pulls this repo into a local
cache (`~/.cache/nyiakeeper/marketplace/`) and propagates the skills + agents into
the assistant's config. Authentication uses your **existing host git credentials**
(SSH keys, credential helpers, `.netrc`) — Nyia stores no tokens.

## Precedence (no clobber)

`user > team dir (NYIA_TEAM_DIR) > marketplace > project-shared > built-in`

Your own and your team's local content always wins over the marketplace; the
marketplace never overwrites anything that already exists.

## Offline behavior (fail-open)

If the Git remote is unreachable at launch, Nyia uses the last cached copy (or
skips the marketplace entirely) and prints a warning — **a launch is never blocked**
by a marketplace problem.
