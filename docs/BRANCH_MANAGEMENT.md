# Branch Management Guide

How Nyia Keeper manages Git branches for AI-assisted development.

## Overview

By default, Nyia Keeper works on your **current branch** — no new branch is created. If you're on a protected branch (main/master), it prompts you for a branch name.

**Key principle**: AI work is never done directly on protected branches (main, master, plus any you configure).

**Why it's a hard requirement.** This isn't only about undoing the AI — it's a forcing function for
*you*: git every time, on a work branch, protected branches guarded from the start, so an inattentive
mistake (yours or the agent's) is always recoverable and reviewable before it lands. See
[Why Nyia Keeper](WHY.md).

---

## Default Behavior

```bash
# On feature/auth → works on feature/auth (no new branch)
git checkout feature/auth
nyia-claude

# On main → interactive prompt for branch name
nyia-claude
# "You're on protected branch 'main'. Branch name [claude-2026-03-08-143000]: "
```

**Non-interactive mode** (piped stdin): errors with a suggestion:
```
Use: nyia-claude --work-branch <name> --create
```

---

## Branch Modes

### Mode 1: Current Branch (Default)

Works on whatever branch you're already on. No switching, no creation.

```bash
git checkout feature/auth
nyia-claude
# Works on feature/auth
```

**Protected branch guard**: If on main/master (or a configured protected branch), you'll be prompted to switch.

### Mode 2: Named Work Branches

Switch to or create a named branch:

```bash
# Switch to existing branch
nyia-claude --work-branch feature/auth

# Create if missing
nyia-claude --work-branch feature/auth --create
```

**Use when**:
- Multi-session feature development
- You want meaningful branch names
- You plan to resume work later

### Mode 3: Auto-Branch (Legacy)

Create a unique timestamped branch automatically. This was the original default.

Enable via config: `NYIA_AUTO_BRANCH=true` in `~/.config/nyiakeeper/config/nyia.conf`

```bash
nyia-claude
# Creates: claude-2026-03-08-143052
```

**Format**: `{assistant}-{YYYY}-{MM}-{DD}-{HHMMSS}`

---

## Flags Reference

### `--work-branch <name>` / `-w`

Switch to a specific branch.

```bash
# Switch to existing branch
nyia-claude --work-branch feature/auth

# With --create: create if missing
nyia-claude --work-branch feature/auth --create
```

**Behavior without `--create`**:
- Existing branch: switches to it
- Missing branch: **error** with helpful message

**Why this design**: Prevents accidental branch creation from typos.

### `--create`

Explicitly create the work branch if it doesn't exist.

```bash
nyia-claude --work-branch feature/new-feature --create
```

**Requirements**: Must be used with `--work-branch`.

**Behavior**:
- Branch missing: creates it
- Branch exists: shows info message and switches to it

### `--base-branch <name>`

Specify which branch to create new branches from.

```bash
# Create feature/auth from develop (not current branch)
nyia-claude --work-branch feature/auth --create --base-branch develop
```

**Default**: Current branch (HEAD)

---

## Common Workflows

### Starting a New Feature

```bash
# Option 1: Named branch from main
nyia-claude --work-branch feature/user-auth --create --base-branch main

# Option 2: Named branch from current
nyia-claude --work-branch feature/user-auth --create

# Option 3: Just work on current branch
nyia-claude
```

### Resuming Previous Work

```bash
# Switch to your existing branch
nyia-claude --work-branch feature/user-auth

# Check what branches exist
git branch -a | grep feature/
```

### Working from a Release Branch

```bash
# Create hotfix from release
nyia-claude --work-branch hotfix/security-fix --create --base-branch release/v2.0
```

### Multiple Features in Parallel

```bash
# Session 1: Auth feature
nyia-claude --work-branch feature/auth --create

# Session 2: Different terminal, API feature
nyia-claude --work-branch feature/api --create
```

---

## Protected Branches

Nyia Keeper prevents direct work on protected branches.

### Hardcoded (always protected)

- `main`
- `master`

### Configurable (additive)

Add more protected branches via config:

```bash
# In ~/.config/nyiakeeper/config/nyia.conf (global)
NYIA_PROTECTED_BRANCHES="develop,staging,production"

# In .nyiakeeper/nyia.conf (per-project)
NYIA_PROTECTED_BRANCHES="release"
```

Both files are **merged** (union) — project config adds to global, it doesn't replace it.

### Dynamic detection

- Git default branch (from `refs/remotes/origin/HEAD`)
- GitHub API protected branches (if `gh` CLI available)

### What happens on a protected branch

**Interactive** (terminal): prompts for a branch name with an auto-generated default:
```
You're on protected branch 'main'.
Branch name [claude-2026-03-08-143000]: _
```
- Press Enter → uses the auto-generated name
- Type a name → uses your name
- Type a protected branch name → error

**Non-interactive** (piped/scripted): error with suggestion:
```
Use: nyia-claude --work-branch <name> --create
```

---

## Configuration

### `NYIA_AUTO_BRANCH`

Controls default branch strategy.

| Value | Behavior |
|-------|----------|
| `false` (default) | Work on current branch |
| `true` | Auto-create timestamped branch |

Set in `~/.config/nyiakeeper/config/nyia.conf` or `.nyiakeeper/nyia.conf`.

### `NYIA_PROTECTED_BRANCHES`

Comma-separated list of additional protected branches. Extends (never replaces) the hardcoded minimum.

```bash
NYIA_PROTECTED_BRANCHES="develop,staging,production"
```

---

## Branch Naming Conventions

### Recommended Patterns

| Pattern | Example | Use For |
|---------|---------|---------|
| `feature/<name>` | `feature/user-auth` | New features |
| `bugfix/<name>` | `bugfix/login-error` | Bug fixes |
| `hotfix/<name>` | `hotfix/security-patch` | Urgent fixes |
| `refactor/<name>` | `refactor/api-cleanup` | Code refactoring |
| `experiment/<name>` | `experiment/new-approach` | Experiments |

### Invalid Names

- Spaces: `feature/my feature` (use dashes)
- Special chars: `feature/my;branch` (security risk)
- Protected names: `main`, `master`

---

## Error Messages and Solutions

### Branch Does Not Exist

```
Branch 'feature/typo' does not exist locally or on remote

Available local branches:
  feature/auth
  feature/api
  main

To CREATE this branch, use --create flag:
  nyia-claude --work-branch feature/typo --create
```

**Solutions**:
1. Fix the typo: `--work-branch feature/auth`
2. Create the branch: add `--create` flag

### Cannot Use Protected Branch

```
Cannot use protected branch as work branch: 'main'
Protected branches detected:
  - main
  - master
Use a feature branch name like: feature/main
```

**Solution**: Use a feature branch name instead.

### --create Requires --work-branch

```
Error: --create requires --work-branch

The --create flag explicitly creates a branch if it doesn't exist.
Usage: nyia-assistant --work-branch feature/my-branch --create
```

**Solution**: Add `--work-branch <name>` before `--create`.

---

## How It Works

### Branch Detection Flow

```
1. Check if --work-branch specified
   ├─ Yes: Check if branch exists
   │   ├─ Exists locally: switch to it
   │   ├─ Exists on remote: checkout and track
   │   └─ Missing:
   │       ├─ --create: create from --base-branch (or current)
   │       └─ No --create: ERROR with suggestions
   └─ No: Check NYIA_AUTO_BRANCH
       ├─ true: Create timestamped branch
       └─ false (default): Work on current branch
           ├─ Protected: prompt for branch name (or error in non-interactive)
           └─ Not protected: proceed on current branch
```

### What Gets Created

When creating a new branch:
1. Branch created from base (default: current branch)
2. Switched to new branch
3. AI work proceeds on this branch
4. Changes stay on this branch until you merge

---

## Best Practices

### Do

- Use meaningful branch names for ongoing work
- Use `--create` explicitly when making new branches
- Check `git branch` before resuming work
- Review AI commits before merging to main
- Configure `NYIA_PROTECTED_BRANCHES` for team branches

### Don't

- Work directly on main/master
- Use spaces or special characters in branch names
- Forget which branch you were working on (use named branches)

---

## Related Documentation

- [CLI_REFERENCE.md](CLI_REFERENCE.md) - Complete flag reference
- [USER_GUIDE_FLAVORS_OVERLAYS.md](USER_GUIDE_FLAVORS_OVERLAYS.md) - Flavors and custom images
