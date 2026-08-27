---
name: nyia-overlay
description: Create Docker overlay Dockerfiles for Nyia Keeper projects. Knows overlay file paths, Dockerfile conventions, and nyia build/run commands. Use when a user wants to customize their assistant Docker image with additional packages or tools.
---

# Overlay - Nyia Keeper Overlay Creator

When invoked, help the user create a Docker overlay Dockerfile for their Nyia Keeper project.

## A) Gather Requirements

Ask the user (skip if already provided via arguments):
1. **What to install**: packages, tools, languages, libraries
2. **Scope**: user-global (all projects) or project-specific (this project only)
3. **Assistant**: which assistant (claude, codex, gemini, opencode, vibe) — or all

## B) Overlay File Locations

There are exactly two overlay locations. Both are optional and stack (user first, then project):

| Scope | Path | Effect |
|-------|------|--------|
| **User (global)** | `~/.config/nyiakeeper/{assistant}/overlay/Dockerfile` | Applies to ALL projects for this assistant |
| **Project** | `.nyiakeeper/{assistant}/overlay/Dockerfile` | Applies to THIS project only |

If both exist, user overlay is applied first, then project overlay builds on top.

## C) Generate the Dockerfile

**MANDATORY patterns** — every overlay Dockerfile MUST follow these:

```dockerfile
# Overlay: {description}
# Scope: {user-global | project-specific}
# Works with: claude, gemini, codex, opencode, vibe

ARG BASE_IMAGE
FROM ${BASE_IMAGE}

USER root

# Install system packages (apt)
RUN apt-get update && apt-get install -y \
    {packages} \
    && rm -rf /var/lib/apt/lists/*

USER node

# {User-space installations below — pip, npm, cargo, etc.}
```

### Rules:
1. **`ARG BASE_IMAGE` + `FROM ${BASE_IMAGE}`** — ALWAYS first, no default value (fail fast). Build system injects this automatically.
2. **`USER root`** for system packages (`apt-get`), **`USER node`** for everything else (pip, npm, cargo)
3. **Always end as `USER node`** — never leave as root
4. **`rm -rf /var/lib/apt/lists/*`** after every `apt-get install`
5. **`--no-cache-dir`** for all `pip install` commands
6. **Never override ENTRYPOINT or CMD** — inherited from base
7. **Python venv**: if installing Python packages, create/reuse venv and symlink RAG:
   ```dockerfile
   USER node
   RUN [ -d /home/node/.venv ] || python3 -m venv /home/node/.venv
   ENV PATH="/home/node/.venv/bin:$PATH"
   RUN ln -sf /usr/local/lib/python3.11/dist-packages/vector_rag \
       /home/node/.venv/lib/python3.11/site-packages/vector_rag 2>/dev/null || true
   RUN pip install --no-cache-dir --upgrade pip setuptools wheel
   RUN pip install --no-cache-dir {packages}
   ```

## D) Write the File

1. Create the directory if needed: `mkdir -p {path}`
2. Write the Dockerfile using the Write tool
3. Show the user the complete file path

## E) Output Build & Run Commands

After writing the Dockerfile, output the exact commands the user needs:

```bash
# Build the custom image with your overlay
nyia-{assistant} --build-custom-image

# Build on top of a language flavor instead of the plain base
nyia-{assistant} --build-custom-image --flavor {python|node|php|rust-tauri|php-react}

# Run the assistant using the custom pseudo-flavor shortcut (Plan 266)
nyia-{assistant} --flavor custom
# (or, when built from a base flavor: nyia-{assistant} --flavor {base}-custom)

# Or run the default image
nyia-{assistant}
```

After `--build-custom-image`, prefer the `--flavor custom` / `--flavor {base}-custom`
shortcut over a long `--image nyiakeeper/{assistant}-custom-{slug}:latest` tag. These
custom pseudo-flavors are local-only selectors; `--image` remains the explicit fallback.

## F) Common Overlay Patterns (reference)

If relevant, offer to generate one of these common overlays (you know the recipes — just write the
Dockerfile per Section C, no external files needed):
- **Python dev** — Python toolchain + venv
- **Data science** — pandas, numpy, scikit-learn, jupyter
- **Web dev** — Django, FastAPI, Flask + Node.js
- **PHP** — a PHP 7.3/7.4/8.1/8.2 environment

(Full write-up: the Flavors & Overlays guide at https://nyia-keeper.com/USER_GUIDE_FLAVORS_OVERLAYS/)

## G) Key Reminders

- The same overlay Dockerfile works with ANY assistant (assistant-agnostic via `ARG BASE_IMAGE`)
- Build system automatically chains: base -> assistant -> flavor -> user overlay -> project overlay
- Image naming: project overlays produce `nyiakeeper/{assistant}-custom-{project-slug}` tags
- If user only wants Python/Node/PHP, suggest using `--flavor` instead of an overlay (simpler)
