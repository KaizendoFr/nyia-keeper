# Security model & its edges

The honest version: what Nyia protects **by default**, where the edges are, and how you can **verify
it yourself**. The canonical policy and how to report a vulnerability live in
[`SECURITY.md`](https://github.com/KaizendoFr/nyia-keeper/blob/main/SECURITY.md).

## The boundary

Nyia runs each assistant in a **Docker container — not a VM**. A container shares the host kernel, so
a container escape means host access. If you need a hardware boundary (untrusted code, hostile
input), run microVM isolation (e.g. Docker Sandboxes) underneath — Nyia is the workflow / data-control
layer on top. See [How Nyia compares](COMPARISON.md).

## What's protected by default

- **The rest of your machine.** The agent sees your project, not your home dir, `~/.ssh`, or root
  filesystem — a bounded blast radius. See [Why Nyia](WHY.md).
- **Your secrets in the project.** Sensitive files are excluded from the mount and replaced with a
  read-only placeholder ([Mount Exclusions](MOUNT_EXCLUSIONS.md)). The default patterns are a
  **starting point** — review them and add your own private files before your first launch.
- **Your branches.** Work runs on a work branch; protected branches are guarded
  ([Branch Management](BRANCH_MANAGEMENT.md)).

## The edges (know these)

- **Exclusion ≠ history redaction.** A secret already committed is recoverable from git history
  unless you enable [Git History Cutoff](GIT_HISTORY_CUTOFF.md).
- **Network is a separate, opt-in axis.** By default the container has ordinary network access; it can
  exfiltrate what's in the box and reach your LAN, host services, and cloud metadata. Turn on
  [restrict-local](NETWORK_EGRESS.md) (Linux) when that matters.
- **Exclusions are patterns, not magic.** They can't know a custom-named secret is sensitive — you
  extend the list.
- **The assistant's own project config is repository content.** OpenCode reads `opencode.json` from
  the project (Claude, Codex, Gemini and Vibe have equivalents): a repository can add MCP servers
  (local commands started with the CLI), plugins, permission rules and providers pointing at its own
  `baseURL` — with your keys, inside the box, and with ordinary egress. Nyia never writes those files,
  refuses to write through a repository-planted link in the project, and runs a best-effort key-name scan
  that warns once (a determined repository can hide a key); the review is yours (see
  [CONFIGURATION.md](CONFIGURATION.md#opencode-configuration--the-layers)).
- **Not independently audited.** It's a solo, beta-quality project — use at your own risk.

## Shared team content: a structural shield, not content review

A [team directory](TEAM_SHARING.md) lets you share skills, personas, and prompt overlays. Shared content
is a **trust decision** — the same as pointing any AI tool at a shared repo; a teammate can commit
whatever they like, and no tool can tell you in advance whether a prompt's *text* is well-intentioned.
That is the git-shared-repo + AI threat model, not something specific to Nyia.

What Nyia *does* enforce, today, is that the **propagation mechanism cannot be abused**: when it brings a
shared skill/agent/prompt into an assistant, it refuses any item that is a **symlink** (top-level or
nested), a **special file**, or uses a **traversal / unsafe name** — so a shared source cannot smuggle a
link like `steal → ~/.ssh/id_rsa` to read files off your host. Copies are per-item atomic and never
overwrite your own content, and execute bits are stripped from copied data files. These are **structural**
protections (extensions are not a security boundary); they do **not** judge whether the content itself is
safe. On-device content review of shared skills/prompts (a guard model) is planned next.

*(Out of scope: hardlinks — a shared **Git** repo cannot carry one, so the sharing mechanism can't
introduce a hardlink to a host file; and a sub-microsecond validate→copy race on a locally-writable team
dir, which already implies local code execution.)*

## Deliberate strengths (not accidents)

- **Fail-closed.** If a protection can't be applied — the egress firewall can't be built, a shallow-git
  history cutoff can't be prepared — the launch is **refused**, not silently downgraded.
- **Safe-parsed config.** Team and project config is read as plain `key=value` — no shell expansion,
  no command execution.
- **Per-assistant branch isolation** and an **object-isolated shallow `.git`** for history cutoff, so
  one assistant's work and old commits stay contained.

## Verify it yourself

Don't take the claims on faith — check them on your own machine:

```bash
nyia exclusions list            # what will be hidden from the agent in this project
nyia exclusions test .env       # confirm a specific path is excluded
```

After launch, excluded files show a `FILE EXCLUDED FOR SECURITY` placeholder inside the container,
while normal files stay readable. Every release is also gated by an automated end-to-end suite
(secret-exclusion + MCP-handshake smokes) before images publish.
