# Private / Team Marketplace

The **marketplace** lets a team distribute shared **skills** and **agents** from a
single Git repository to every Nyia Keeper user, in **every project**, automatically.

It is a Git-backed evolution of `NYIA_TEAM_DIR`: instead of requiring a mounted or
synced shared folder, members set one URL once and Nyia clones/pulls the content
into a local cache at launch — so it follows them across machines and projects.

---

## TL;DR

**Maintainer** (one time):

```sh
nyia marketplace init my-marketplace --name "Acme Team"
cd my-marketplace
# add skills under skills/<name>/SKILL.md and agents under agents/<name>.md
git remote add origin git@gitlab.com:acme/nyia-marketplace.git
git push -u origin HEAD
```

**Each member** (one time):

```sh
nyia config global marketplace_url=git@gitlab.com:acme/nyia-marketplace.git
```

Done. On the next launch in any project, every member gets the team skills + agents.

---

## How it works

1. At launch, Nyia resolves `NYIA_MARKETPLACE_URL` (project config first, then global).
2. It clones (first time, shallow `--depth 1`) or pulls (`--ff-only`) the repo into:

   ```
   ~/.cache/nyiakeeper/marketplace/
   ```

3. The cached `skills/` and `agents/` directories are propagated into the
   assistant's config using the **same** propagators as `NYIA_TEAM_DIR`
   (no new copy logic, no overwriting of existing content).
4. A status line is printed:
   - `📦 [MARKETPLACE] Synced N item(s)` — fetched/updated successfully
   - `📦 [MARKETPLACE] Offline — using cached (N item(s))` — remote unreachable, cache used
   - (nothing, unless verbose) — not configured

### Marketplace repo layout

```
marketplace.json            # metadata (name, description, version)
skills/
  <skill-name>/
    SKILL.md
agents/
  <agent-name>.md
```

Only directories containing a `SKILL.md` are treated as skills; only regular files
(non-dotfiles) under `agents/` are treated as agents — identical to `NYIA_TEAM_DIR`.

---

## Configuration

The marketplace URL is settable at **global** or **project** precedence:

```sh
# Applies to every project on this machine
nyia config global marketplace_url=<git-url>

# Pins a marketplace for this project only (overrides global)
nyia config project marketplace_url=<git-url>

# View the effective value and its source
nyia config view
```

Accepted URL forms (must be git-clonable):

- `https://host/org/repo.git`
- `ssh://[user@]host[:port]/path/repo.git`
- `git@host:org/repo.git` (scp-like)
- `git://host/path/repo.git`
- `file:///abs/path/repo.git` (local mirrors / testing)

Malformed values (spaces, command substitution, non-git schemes like `ftp://`)
are rejected by `nyia config`.

To unset:

```sh
nyia config global marketplace_url=
```

---

## Authentication (host git credentials only)

Sync uses **your existing git credentials** — SSH keys, credential helpers, or
`.netrc`. **Nyia stores and manages no tokens.**

Rule of thumb: *if you can `git clone <url>` from your shell, Nyia can sync it.*

Sync runs non-interactively (`GIT_TERMINAL_PROMPT=0`, SSH `BatchMode=yes`) so a
missing credential fails fast with a warning instead of hanging a launch. If you
see repeated `auth failed` warnings, verify your credentials with a manual
`git clone` of the same URL.

---

## Fail-open behavior (a launch is never blocked)

Marketplace sync is **fail-open by design**. Any of the following results in a
warning and a fall back to the cached copy (or skipping the marketplace), and the
launch proceeds normally:

- The remote is unreachable (offline, DNS, firewall)
- Authentication fails
- The clone/pull exceeds its hard timeout (pull ≤ 10s, clone ≤ 30s)
- The URL is missing or malformed

If a cache already exists, its content is used (`Offline — using cached`). If no
cache exists yet, the marketplace is simply skipped for that launch. **Nyia never
exits non-zero or blocks a session because of a marketplace problem.**

Concurrent launches are safe: an atomic lock + clone-to-temp-then-rename prevents
two simultaneous syncs from corrupting the cache.

> Portability note: hard timeouts use `timeout` (GNU coreutils) or `gtimeout`
> (macOS via Homebrew) when available; if neither is present, git's own transport
> timeouts bound network operations instead.

---

## Precedence (no clobber)

```
user  >  team dir (NYIA_TEAM_DIR)  >  marketplace  >  project-shared  >  built-in
```

- Your own skills/agents always win.
- A local `NYIA_TEAM_DIR` wins over the marketplace (if both are configured).
- The marketplace **never overwrites** anything that already exists at the target —
  it only fills in items you don't already have.

This means a team can keep a local override dir for in-progress work while still
receiving everything else from the marketplace.

---

## Cross-project behavior

Because the marketplace is fetched at launch (not per-project setup), it applies
to **every project** automatically:

- Set the URL globally once → every project on the machine gets the content.
- Or pin a different marketplace per project with `nyia config project`.

The cache is shared across projects (`~/.cache/nyiakeeper/marketplace/`), so the
first launch fetches and subsequent launches in any project reuse/update it.

---

## Adding skills and agents (maintainer)

```sh
cd my-marketplace

# A skill: a directory with a SKILL.md
mkdir -p skills/deploy-checklist
$EDITOR skills/deploy-checklist/SKILL.md

# An agent: a single Markdown file
$EDITOR agents/release-manager.md

git add -A
git commit -m "Add deploy checklist skill + release-manager agent"
git push
```

Members pick up the changes on their next launch (a fast `pull --ff-only`).

---

## Relationship to other features

- **`NYIA_TEAM_DIR`** — the local-filesystem equivalent. The marketplace reuses its
  propagation flow and sits just below it in precedence. Use a team dir for
  fast-changing local content; use the marketplace for stable, team-wide distribution.
- **Public marketplace / plugin packaging** — out of scope for this feature; the
  private marketplace is the content engine that curates candidates for any future
  public catalog.
