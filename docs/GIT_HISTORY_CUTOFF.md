# Git History Cutoff

Limit how much git history the assistant container can see. When a cutoff is set,
Nyia Keeper mounts a **protected, object-isolated shallow `.git`** over the real one,
so the assistant has recent history (to work effectively) but **cannot read commits
before the cutoff** — where un-rotated secrets may still live in old blobs.

> Threat model: an assistant that can run `git log -p`/`git cat-file` over full
> history can read secrets that were committed and later removed. The cutoff removes
> those objects from what the container can reach. Network egress is **not** part of
> this threat model (a user cannot exfiltrate by accident); see the egress policy
> feature for that.

## Quick start

```bash
# Set a cutoff date (anything before it is hidden from the assistant).
nyia config project git_history_cutoff=2025-01-01

# Launch as usual — the protected shallow .git is built and mounted automatically.
nyia-claude

# After the session, review what the assistant committed:
nyia git-history status
nyia git-history reconcile            # read-only review (diff vs your real branch)
nyia git-history reconcile --apply    # import into refs/nyia-shallow/<branch>
```

## How it works

1. **Build** — before the container starts, nyia clones the repo with
   `git clone --no-local --shallow-since=<cutoff>` over `file://`. `--no-local` is
   load-bearing: a plain local clone would hardlink or set `objects/info/alternates`
   back to the full object store, re-exposing every object. The origin remote is then
   stripped so `git fetch --unshallow`/`--deepen` cannot recover pre-cutoff objects.
2. **Verify (fail-closed)** — the build is rejected unless it is genuinely isolated:
   no alternates, `.git/shallow` present, no remotes. On any failure the shallow is
   removed and **the launch is refused** — nyia never falls back to the full `.git`.
3. **Mount** — the shallow `.git` is layered over the container's project `.git`
   (`-v <shallow>/.git:<project>/.git:rw`). The working tree stays the real project;
   only history is truncated.
4. **In-container backstop** — the entrypoint asserts the mounted `.git` is shallow
   and alternate-free when a cutoff is active, and refuses to run otherwise.

The shallow lives on disk at `.nyiakeeper/git-shallow/` (gitignored, persisted — a
crash mid-session loses nothing).

### The oldest retained commit must already be secret-free

git stores each commit's **full tree**, so a commit still references the secret blob as
long as the file existed *at that commit*. The precise rule is: **the secret leaks if
any retained commit's tree still contains it** — equivalently, the *oldest retained*
commit must already be secret-free.

So a cutoff *date* is not enough on its own: if the secret was removed in commit `R`,
a cutoff that still retains an **intermediate** commit between the secret's
introduction and `R` will leak (that commit's tree holds the secret). Cut **at or after
`R`** so the oldest retained commit is the cleanup commit (or later) — not merely "some
date after the secret was added." When in doubt, choose a cutoff that excludes every
commit up to and including the last one that still contained the secret.

## The assistant's commits: review, reconcile, recover

Because the container writes to the shallow `.git`, the assistant's **new commits land
in `.nyiakeeper/git-shallow/`, not your real repo**. They attach cleanly (SHAs match),
but importing them is always an **explicit, reviewed action — never automatic**.

| Command | What it does |
| --- | --- |
| `nyia git-history status` | Show the cutoff, the shallow, and any pending commits. |
| `nyia git-history reconcile` | **Review (default, read-only):** list pending commits + `git diff` vs your real tip. No writes. |
| `nyia git-history reconcile --apply` | Import pending commits into `refs/nyia-shallow/<branch>` (namespaced, non-forced). Your real branches are untouched; integrate with `git merge`/`rebase`/`cherry-pick`. |
| `nyia git-history reconcile --discard` | Drop the protected session. The real repository is never modified. |
| `nyia git-history rebuild` | Rebuild the shallow — **only when nothing is pending** (a rebuild over pending commits would destroy un-reconciled work). |

After each session, if pending commits exist, nyia prints a summary + the reconcile
command. It does **not** modify your real repo.

### Crash recovery (non-blocking)

If nyia or the assistant died mid-session, the shallow `.git` is intact on disk. On the
next launch nyia detects pending commits, **warns**, **reuses the existing shallow**
(new commits stack on top — it does *not* rebuild over your work), and continues.
The only thing ever blocked is a destructive `rebuild`, never the launch itself.

### Non-fast-forward (real tip advanced on the host)

If you committed on the host after the shallow was built, `--apply` still imports the
assistant's commits under `refs/nyia-shallow/<branch>` without error. The two lines of
history diverge; you integrate them deliberately (merge/rebase/cherry-pick).

## Scope & precedence

`git_history_cutoff` is a standard `nyia config` key, so it follows normal precedence
(CLI override → project → global → team → default). Set it per project, globally, or
per assistant like any other key. Leave it unset (the default) for today's behavior:
full history, no shallow, no reconcile machinery engaged.

## Workspaces (multiple repos)

In workspace mode the cutoff is **per repo** — each member has its own history, its
own un-rotated-secret risk, and its own `git_history_cutoff` config.

- **Which repos** are considered: the workspace **root** (only if it is itself a git
  repo — it is not listed in `workspace.conf`) plus the **git member repos** from
  `workspace.conf`. Non-git RO members have no `.git` and are skipped.
- **Per-repo opt-in**: set `git_history_cutoff` inside (or targeting) each repo. Repos
  without a cutoff mount their full `.git` as usual. Heterogeneous workspaces (some
  protected, some not) are the normal case.
- **Read-protection vs reconcile**: the shallow mount (read-protection) applies to any
  git repo with a cutoff, including RO git members. **Reconcile** only applies to **RW**
  repos — RO repos take no AI commits, so there is nothing to reconcile.
- **Aggregated commands**:
  - `nyia git-history status` prints a per-repo table (cutoff, protected?, pending count).
  - `nyia git-history reconcile` iterates the RW repos (review by default); restrict with
    `nyia git-history reconcile --repo <path>`. `--apply`/`--discard` act per repo.
  - `nyia git-history rebuild` rebuilds per repo (each still refuses over pending work).
- **Per-repo fail-closed**: if a protected repo's shallow can't be built, the workspace
  launch is refused (that repo cannot be mounted safely) — it is never silently mounted
  with full history.
- **Backstop note**: the in-container entrypoint assertion validates the **root** repo's
  `.git` only. Members rely on the host-side fail-closed build (and the per-repo refusal).

## Safety guarantees

- **Fail-closed**: a cutoff that cannot be built/verified refuses the launch.
- **No auto-merge / no auto-push**: reconcile is always explicit; imports are
  namespaced and non-forced; the real repo is only ever changed by *your* git commands.
- **No data loss**: the shallow is persisted; rebuild refuses to run over pending work.
- **Out of scope**: remote/network handling (covered by the egress policy feature).
