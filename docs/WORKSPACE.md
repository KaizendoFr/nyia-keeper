# Workspace Mode - Multi-Repository Support

Workspace mode allows a single Nyia Keeper session to work across multiple related repositories simultaneously.

## Quick Start

1. Create a workspace configuration file using `--workspace-init` (recommended):
```bash
nyia-claude --workspace-init
# Edit the generated template at .nyiakeeper/workspace.conf
```

Or manually:
```bash
mkdir -p .nyiakeeper
cat > .nyiakeeper/workspace.conf << 'EOF'
# Paths to additional repositories: <path> <ro|rw>
~/projects/shared-library        rw
~/projects/api-client            rw
/data/reference-docs             ro
EOF
```

2. Run any assistant - workspace mode is auto-detected:
```bash
nyia-claude
```

## Configuration File Format

The `.nyiakeeper/workspace.conf` file uses a simple line-based format. Each line has a **path** followed by a mandatory **access mode** (`ro` or `rw`):

```
# Comments start with #

# Directives (optional, key=value format)
sync_branches=true

# Repository entries: <path> <ro|rw>
~/projects/repo1                  rw    # Read-write — full git guards
~/projects/api-specs              ro    # Read-only — no git needed
/absolute/path/to/docs            ro    # Non-git dir OK for ro
"~/projects/path with spaces"     rw    # Quoted paths supported

# Empty lines are ignored
```

### Access Modes

| Mode | Mount | Git Required? | Branch Sync? | Use For |
|------|-------|---------------|--------------|---------|
| `rw` | Read-write | Yes (must be git repo) | When enabled | Repos you edit |
| `ro` | Read-only | No | No | Reference material, docs, specs |

### Directives
Directives use `key=value` format and control workspace behavior:

| Directive | Values | Default | Effect |
|-----------|--------|---------|--------|
| `sync_branches` | `true` / `false` | `false` | Auto-sync RW repo branches to work branch |

Directives can appear anywhere in the file (before, after, or between repo entries).

### Parsing Rules
- **Unquoted paths**: last whitespace-delimited token is the mode; everything before it is the path
- **Quoted paths**: wrap the path in `"double quotes"`, mode follows after the closing quote
- **Directives**: `key=value` lines (only known directives like `sync_branches=` are intercepted)
- Mode is case-insensitive (`RO`, `ro`, `Ro` all work)
- Inline comments are NOT supported — use comment-only lines instead
- Old-format lines (path only, no `ro`/`rw`) produce a clear error

### Requirements
- Each path must be a valid directory
- **RW repos** must be git repositories (contains `.git/`)
- **RO repos** just need to exist (git not required)
- The workspace cannot list itself (self-reference check)
- Symlinks are automatically resolved to canonical paths

## How It Works

### Container Mount Structure

When workspace mode is active:
```
/project/{workspace-hash}/           # Main workspace (your current directory)
/project/{workspace-hash}/repos/     # Additional repositories
    ├── shared-library-a1b2c3d4/     # RW repo (with hash suffix, :rw mount)
    ├── api-client-e5f6g7h8/         # RW repo (with hash suffix, :rw mount)
    └── reference-docs-i9j0k1l2/     # RO repo (with hash suffix, :ro mount)
```

The hash suffix prevents collisions when multiple repos have the same basename.

### Branch Naming

Branch names follow the standard format: `{assistant}-{timestamp}`
- Example: `claude-2025-01-15-143025`

The same branch name is used across all **RW** repositories in the workspace. RO repos are not touched.

### Exclusions

Each repository can have its own exclusions:
```
repo1/.nyiakeeper/exclusions.conf   # Applied to repo1 mount
repo2/.nyiakeeper/exclusions.conf   # Applied to repo2 mount
workspace/.nyiakeeper/exclusions.conf  # Applied to main workspace
```

Built-in security exclusions (`.env`, `.key`, `.pem`, etc.) are applied to all mounts (both RO and RW). For full details, see [MOUNT_EXCLUSIONS.md](MOUNT_EXCLUSIONS.md).

## RO vs RW Behavior Summary

| Operation | RW repo | RO repo |
|-----------|---------|---------|
| Must be git repo | Yes | No |
| Docker mount mode | `:rw` | `:ro` |
| Branch sync | Yes | Skipped |
| Branch rollback | Yes | Skipped |
| Uncommitted changes check | Yes | Skipped |
| Exclusions applied | Yes | Yes |

## Limitations

### RAG (Codebase Search)
RAG is automatically disabled in workspace mode. Multi-repository indexing is not yet supported. You'll see a warning:
```
Warning: RAG disabled in workspace mode (multi-repo indexing not yet supported)
         Workspace contains 3 additional repositories
```

### Git Operations
- Git operations in the container target the main workspace only
- Each additional RW repo maintains its own git state
- Commits made by the assistant go to the workspace repo

### Branch Synchronization

By default, Nyia Keeper **warns** when RW workspace repos are on different branches but does **not** automatically sync them. This lets you intentionally work with repos on different branches.

#### Default Behavior (Warn Only)
When you start a workspace session, Nyia Keeper checks all RW repos. If any are on a different branch than the work branch, you'll see:
```
Warning: Workspace repos on different branches than 'feature/my-feature':
  shared-library (/home/user/projects/shared-library): main
  api-client (/home/user/projects/api-client): develop
To auto-sync branches, set workspace_sync=true in config or workspace.conf
```
No branches are changed. RO repos are always skipped.

#### Enabling Auto-Sync

To have Nyia Keeper automatically create/switch branches on all RW repos:

**Per-workspace** — add a directive to `workspace.conf`:
```
sync_branches=true

~/projects/shared-library     rw
~/projects/api-client         rw
```

**Globally** — set the config key:
```bash
nyia config global workspace_sync=true
```

Precedence: `workspace.conf` directive > global config > default (`false`).

To disable sync for a specific workspace even when global is true:
```
sync_branches=false
~/projects/repo rw
```

#### Atomic Rollback (Sync Mode Only)
When sync is enabled, if branch creation fails on any RW repository:
- All RW repositories are rolled back to their original branches
- The work branch is deleted from any repos where it was created
- You'll see an error message indicating which repo failed and why

Common failure reasons:
- Uncommitted changes in an RW workspace repo (commit or stash first)
- Inaccessible repository path
- Branch already exists with conflicts

#### Explicit Branch Names
Use `--work-branch` to specify the branch name:
```bash
nyia-claude --work-branch feature/my-feature
```
When sync is enabled, this branch will be created on all RW repos. When sync is disabled (default), you'll get a warning if repos differ. RO repos are always unaffected.

## Status Display

When workspace mode is active, the status display shows:
```
Git Status
  Branch: claude-2025-01-15-143025
  Commits: 42
  Changes: Clean working directory
  Mode: Workspace (3 repos: 2 rw, 1 ro)
```

## Use Cases

### Monorepo Alternative
Work on related packages without a monorepo structure:
```
# workspace.conf
~/packages/ui-components     rw
~/packages/api-client        rw
~/packages/shared-types      rw
```

### Cross-Project Refactoring
Make coordinated changes across multiple projects:
```
# workspace.conf
~/services/auth-service      rw
~/services/user-service      rw
~/libs/common-utils          rw
```

### Code + Reference Documentation
Edit code while referencing read-only docs/specs:
```
# workspace.conf
~/api-specs                  ro
~/company-wiki               ro
~/shared-types               ro
```

### Mixed: Editable + Reference
```
# workspace.conf
~/services/my-service        rw    # This is what I'm working on
~/services/upstream-api      ro    # Just for reference
~/docs/architecture          ro    # Read-only architecture docs
```

## Troubleshooting

### "Missing access mode (ro/rw) for: ..."
Your `workspace.conf` uses the old format (path only). Add `ro` or `rw` at the end of each line.

### "Workspace repo not found"
The specified path doesn't exist. Check the path in `workspace.conf`.

### "Workspace repo is not a git repository"
An RW directory exists but isn't a git repo. Either run `git init` or change it to `ro`.

### "Workspace cannot include itself"
Remove the current directory from `workspace.conf` - it's already the main workspace.

### Repos with Same Name
If you have multiple repos named `app/`:
```
~/project-a/app    →  /project/.../repos/app-a1b2c3d4/
~/project-b/app    →  /project/.../repos/app-e5f6g7h8/
```
The hash suffix ensures unique container paths.

### "Failed to sync branches across workspace repositories"
Branch synchronization failed on an RW repo. Common causes:
- **Uncommitted changes**: Commit or stash changes in the failing repo
- **Inaccessible repo**: Check the path exists and is readable
- **Permission issues**: Ensure you have write access to create branches

All RW repos will be rolled back to their original branches when this happens. RO repos are never affected.

## Workspace Root as a Project

The directory you launch Nyia from is the **workspace root** — the main workspace itself. You do not need a separate, empty directory to host a workspace.

**Starting from an existing repo is fully supported.** If the workspace root contains a `.git/` directory, Nyia automatically treats it as a full project — with branch safety (assistant branch creation, cleanup, and sync) — *alongside* the additional repos you list. Those additional repos are mounted under `repos/`; the root project is the workspace root itself and is **not** placed in `repos/`.

Because the root is already the main workspace, **do not list the root (current) directory in `workspace.conf`** — Nyia rejects it with an error. Listing only the *additional* repos is correct; "the root project is not under `repos/`" is by design.

**A fresh, non-git root also works.** If the root has no `.git/`, it's treated as an orchestration directory only — branch operations are skipped for the root and applied solely to the workspace repos.

This is automatic — no extra flags needed. In short: launch from a repo *or* from a plain directory; either is valid.

## Unsupported: Subdirectories of Git Repositories

Adding a subdirectory of a git repository as a workspace entry (e.g., `~/monorepo/packages/my-service rw`) is not supported.

**Why**: Inside the Docker container, only the specified directory is mounted. The parent repository's `.git/` directory is not included, which means:
- `git status`, `git diff`, `git blame`, `git log` — all fail
- No assistant branch creation or cleanup (no safety net)
- The AI assistant loses all git context for that directory

**Workaround**: Mount the full repository and use nyia's exclusion system to control what the AI can access:
1. Add the full repo: `~/monorepo    rw`
2. Create exclusions: `nyia exclusions init ~/monorepo`
3. Edit `~/monorepo/.nyiakeeper/exclusions.conf` to exclude directories you don't want exposed (e.g., `other-packages/`, `infrastructure/`)
4. Verify: `nyia exclusions list ~/monorepo`

This gives you scoped access WITH full git functionality.

Alternatively, add the subdirectory as read-only if you don't need git operations:
```
~/monorepo/packages/my-service    ro
```

## Best Practices

1. **Keep workspace.conf in version control** - Share the workspace setup with your team
2. **Use absolute or home-relative paths** - More reliable than relative paths
3. **Mark reference repos as `ro`** - Prevents accidental writes, skips git overhead
4. **Group related repos only** - Don't include unrelated projects
5. **Consider security** - Excluded files in one repo don't affect another
6. **Document the workspace** - Add comments explaining why each repo is included
