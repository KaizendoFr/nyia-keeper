# User Guide: Flavors and Overlays

This guide explains how to use pre-built flavors and create custom overlays to extend Nyia Keeper assistants with additional tools and packages.

## Quick Decision: Flavor or Overlay?

| I need... | Use | Command |
|-----------|-----|---------|
| Python dev tools (pytest, black, mypy) | **Flavor** | `nyia-claude --flavor python` |
| PHP dev tools (PHPUnit, PHPStan) | **Flavor** | `nyia-claude --flavor php` |
| Node.js / React / Cypress / Expo | **Flavor** | `nyia-claude --flavor node` |
| PHP + React fullstack | **Flavor** | `nyia-claude --flavor php-react` |
| Rust + Tauri v2 desktop apps | **Flavor** | `nyia-claude --flavor rust-tauri` |
| Something else (custom packages) | **Overlay** | Create Dockerfile, then `--build-custom-image` |

**Rule of thumb:**
- Flavor = ready to use, no build required
- Overlay = custom, requires Docker and building

---

## Part 1: Using Pre-built Flavors

Flavors are specialized images pre-built with common development tools. They're pulled automatically from the registry - no local build required.

### List Available Flavors

```bash
nyia-claude --list-flavors
```

### Current Flavors

| Flavor | Tools Included |
|--------|----------------|
| `python` | pytest, pytest-cov, black, mypy, ruff, isort, ipython |
| `php` | PHP 8.3, Composer, PHPUnit, PHPStan, PHP-CS-Fixer |
| `node` | Node.js 22, yarn, pnpm, typescript, biome, vitest, vite, storybook, cypress (headless Chromium), Expo (via `npx expo`), eas-cli |
| `php-react` | PHP 8.2 + React + Storybook + Jest + Cypress + PHPUnit (fullstack) |
| `rust-tauri` | Rust, Cargo, Tauri v2 CLI, clippy, rustfmt, cargo-watch, Node.js 22 |

### Using a Flavor

```bash
# Python development
nyia-claude --flavor python

# PHP development
nyia-claude --flavor php

# Interactive mode with flavor
nyia-claude --flavor python
```

The first time you use a flavor, it will be pulled from the registry automatically.

---

## Part 2: Creating Custom Overlays

If you need packages not included in any flavor, create a custom overlay.

**Requirements:** Docker must be installed.

### Step 1: Create Your Overlay Dockerfile

Choose one of these locations:

| Location | Scope |
|----------|-------|
| `~/.config/nyiakeeper/claude/overlay/Dockerfile` | All your projects |
| `.nyiakeeper/claude/overlay/Dockerfile` | This project only |

**Create your Dockerfile:**

```bash
mkdir -p ~/.config/nyiakeeper/claude/overlay/

cat > ~/.config/nyiakeeper/claude/overlay/Dockerfile << 'EOF'
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

# Install system packages (as root)
USER root
RUN apt-get update && apt-get install -y \
    your-package \
    another-package \
    && rm -rf /var/lib/apt/lists/*

# Install user packages (as node)
USER node
RUN pip install --no-cache-dir your-python-package
EOF
```

### Step 2: Build Your Custom Image

```bash
nyia-claude --build-custom-image

# Force rebuild without Docker cache
nyia-claude --build-custom-image --no-cache
```

This creates a project-scoped image named `nyiakeeper/claude-custom-{project}` (e.g., `nyiakeeper/claude-custom-my-app`).
If only a user overlay exists (no project overlay), the global name `nyiakeeper/claude-custom` is used instead.

### Step 3: Use Your Custom Image

```bash
# The build output shows the exact image name to use
nyia-claude --image nyiakeeper/claude-custom-my-app
```

**Note:** You must use `--image` to select your custom image. Without it, the default image is used.

> **Migration:** Users who built legacy custom images (`nyiakeeper/claude-custom`) before project scoping can still reference them via the `--image` flag.

---

## Overlay Stacking

If you have overlays in both locations, they're applied in order:

1. Base image (from registry)
2. User overlay (`~/.config/nyiakeeper/claude/overlay/`)
3. Project overlay (`.nyiakeeper/claude/overlay/`)

This allows global preferences plus project-specific additions.

---

## Dockerfile Best Practices

### Always Switch Users Properly

```dockerfile
USER root
# Install system packages here
RUN apt-get update && apt-get install -y package

USER node
# Install user packages here
RUN pip install package
```

### Clean Up Package Caches

```dockerfile
RUN apt-get update && apt-get install -y package \
    && rm -rf /var/lib/apt/lists/*
```

### Use --no-cache-dir for pip

```dockerfile
RUN pip install --no-cache-dir package
```

### Don't Override the Entrypoint

The base image has a configured entrypoint. Don't change it unless you know what you're doing.

---

## Troubleshooting

### "Flavor not found"

```
❌ Error: Flavor 'nodejs' not found
```

**Solution:** Check available flavors with `--list-flavors`. Did you mean `node` instead of `nodejs`?

### "Cannot pull image"

```
Error response from daemon: pull access denied
```

**Solutions:**
- Check your network connection
- Try `docker login ghcr.io` if authentication is required
- Verify the image exists: `docker manifest inspect ghcr.io/kaizendofr/nyiakeeper-claude-python:latest`

### Build fails with permission error

```
Permission denied: /some/path
```

**Solution:** Make sure you switch to `USER node` before installing user packages, and `USER root` for system packages.

### Custom image not found

```
Error: No such image: nyiakeeper/claude-custom
```

**Solution:** Did you run `--build-custom-image` or `docker build`? Check with `docker images | grep custom`.

---

## Quick Reference

| Task | Command |
|------|---------|
| List flavors | `nyia-claude --list-flavors` |
| Use Python flavor | `nyia-claude --flavor python` |
| Use PHP flavor | `nyia-claude --flavor php` |
| Build custom overlay | `nyia-claude --build-custom-image` |
| Rebuild without cache | `nyia-claude --build-custom-image --no-cache` |
| Use custom image | `nyia-claude --image nyiakeeper/claude-custom-my-app` |
| Check available images | `nyia-claude --list-images` |

