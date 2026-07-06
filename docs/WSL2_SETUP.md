# Nyia Keeper on Windows (WSL2)

Quick setup guide for Windows users running WSL2.

## Quick Install (Recommended)

From inside a **WSL2 terminal** (Ubuntu, Debian, etc.), run the standard Linux installer:

```bash
curl -fsSL https://raw.githubusercontent.com/KaizendoFr/nyia-keeper/main/install.sh | bash
export PATH="$HOME/.local/bin:$PATH"
```

The same installer used for Linux works unmodified in WSL2.

## Prerequisites

### 1. Windows 10/11 with WSL2

WSL2 is required (WSL1 is not supported — it lacks Docker socket integration).

```powershell
# From PowerShell (Admin) — install WSL2 with Ubuntu
wsl --install
```

After installation, open "Ubuntu" from the Start menu to launch your WSL2 terminal.

### 2. Docker Desktop for Windows

Download and install from: https://docs.docker.com/desktop/install/windows-install/

**Critical setting**: In Docker Desktop > Settings > General, ensure **"Use the WSL 2 based engine"** is enabled.

Also enable WSL integration for your distribution:
- Docker Desktop > Settings > Resources > WSL Integration
- Toggle ON for your distribution (e.g., Ubuntu)

### 3. Verify Docker in WSL2

Open your WSL2 terminal and run:

```bash
docker info
```

If this works, you're ready to install Nyia Keeper.

---

## Project Location: `/home/` vs `/mnt/c/`

WSL2 mounts your Windows drives under `/mnt/`:

| Path | Filesystem | Case-sensitive | Speed | Recommendation |
|------|-----------|----------------|-------|----------------|
| `/home/user/projects/` | ext4 | Yes | Fast | Recommended for development |
| `/mnt/c/Users/.../` | NTFS | No | Slower | Works, but slower I/O |

**Recommendation**: Clone your projects to `/home/` inside WSL2 for best performance:

```bash
cd ~
git clone https://github.com/your/project.git
cd project
nyia-claude
```

Nyia Keeper automatically detects NTFS paths (`/mnt/<drive>/`) and uses case-insensitive file matching when needed.

---

## Docker Desktop Differences

Nyia Keeper automatically detects WSL2 and adjusts Docker behavior — the same adjustments applied for macOS:

| Feature | Native Linux | WSL2 / macOS |
|---------|-------------|--------------|
| Network mode | `--network host` | Bridge (default) |
| User mapping | `--user $(id -u):$(id -g)` | Docker Desktop handles |
| Ollama access | `localhost:11434` | `host.docker.internal:11434` |
| File matching | Case-sensitive (`-name`) | Case-insensitive on NTFS (`-iname`) |

---

## Ollama for RAG (Optional)

If you want codebase search (RAG), install Ollama on the **Windows side**:

1. Download from [ollama.ai](https://ollama.ai) and run the Windows installer
2. Pull the embedding model (from PowerShell or WSL2):
   ```bash
   ollama pull nomic-embed-text
   ```
3. Configure in your assistant config:
   ```bash
   echo "NYIA_RAG_MODEL=nomic-embed-text" >> ~/.config/nyiakeeper/claude.conf
   ```

Ollama running on Windows is accessible from WSL2 containers via `host.docker.internal:11434`.

---

## First Run

```bash
# Check installation
nyia list

# Check Claude status
nyia-claude --status

# Authenticate (one-time)
nyia-claude --login
```

## Common Commands

```bash
# Use specific assistant
nyia-claude
nyia-gemini

# Use language flavor
nyia-claude --flavor python
nyia-claude --flavor node

# Interactive shell
nyia-claude --shell

# Debug mode
nyia-claude --verbose
```

---

## Troubleshooting

### "Docker is not running"

Nyia Keeper will show: *"Ensure 'Use the WSL 2 based engine' is enabled in Docker Desktop settings"*

1. Open Docker Desktop on Windows
2. Wait for it to fully start (icon in system tray stops animating)
3. Verify: Settings > General > "Use the WSL 2 based engine" is checked
4. Verify: Settings > Resources > WSL Integration > your distro is toggled ON

### "Cannot connect to Docker daemon"

```bash
# Check if Docker socket exists in WSL2
ls -la /var/run/docker.sock

# If missing, restart Docker Desktop on Windows
# Then reopen your WSL2 terminal
```

### Slow performance on `/mnt/c/`

Files on Windows drives (`/mnt/c/`, `/mnt/d/`) go through a 9P filesystem bridge which is significantly slower than native ext4.

**Fix**: Move your projects to `/home/` inside WSL2:

```bash
cp -r /mnt/c/Users/you/project ~/project
cd ~/project
nyia-claude
```

### Permission issues

Docker Desktop for Windows handles file permissions automatically in WSL2 — no `sudo` required for most operations.

---

## Uninstall

To remove Nyia Keeper from WSL2:

```bash
# Remove installed files
rm -rf ~/.local/lib/nyiakeeper
rm -f ~/.local/bin/nyia*

# Optional: Remove config
rm -rf ~/.config/nyiakeeper

# Optional: Remove PATH from shell config
# Edit ~/.bashrc and remove the line:
#   export PATH="$HOME/.local/bin:$PATH"
```

## Support

- Issues: https://github.com/KaizendoFr/nyia-keeper/issues
- Docs: https://github.com/KaizendoFr/nyia-keeper/tree/main/docs
- See also: [macOS Setup Guide](MACOS_SETUP.md) (Docker Desktop behavior is identical)
