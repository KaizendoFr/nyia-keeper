# Why Nyia Keeper

Nyia Keeper runs AI coding assistants (Claude, Gemini, Codex, OpenCode, Vibe) inside a Docker
container that sees your project — and nothing else on your machine. It exists for three reasons,
in the order I built them.

## 1. A box for powerful AI CLIs

I didn't want to run an AI coding CLI directly on my computer. These tools are powerful by design:
they read files, run commands, install packages, reach the network. Run one straight on your
machine and its reach *is* your machine.

So the first thing Nyia does is put the assistant in a box. It works against your project inside a
container and **cannot reach the rest of your machine** — not your home directory, not `~/.ssh`,
not your root filesystem. If it makes a mess, the mess is inside the box, on a copy of your project
you can review.

**This is what "safe by default" means here: a bounded blast radius.** It is not a claim about the
network (see below), and it is not VM-grade escape isolation — a container shares the host kernel,
so if you need a hardware boundary, run something like Docker's microVM Sandboxes underneath. It's
the difference between "the agent can touch my project" and "the agent can touch everything I own."

## 2. Curate what the box sees

The box still contains your project — and projects contain secrets. So Nyia keeps sensitive files
out of the container by default: `.env`, `*.key`, `id_rsa`, `.ssh/`, `.aws/`, `credentials.*` and
more are replaced with a read-only placeholder the agent can't read.

The auto-detection is a **starting point, not the finish line.** It catches the common cases; it
can't know that `prod-dump.sql` or `client-list.csv` is sensitive to *you*. The feature that matters
is the one you drive: **review what Nyia will hide, and add your own private files before your first
launch.**

→ [Mount Exclusions](MOUNT_EXCLUSIONS.md): see the list, add yours, and confirm a path is hidden.

## 3. Forced git discipline

The last reason is about me, not the AI. I wanted a tool that makes me work the way I already know
I should: in git, every time, on a branch — not editing straight on `main` because I was in a
hurry.

So Nyia requires a git repo and protects important branches from the start. You *and* the assistant
work on a work branch; a mistake — yours or the agent's — is always recoverable and always
reviewable before it lands. It's a forcing function against inattention, not just a way to undo the
AI.

→ [Branch Management](BRANCH_MANAGEMENT.md), plus the built-in `nyia-code-review` and `nyia-checkpoint` steps.

## Where the network fits

By default the container has ordinary network access — the assistants need the internet to work
(API calls, package installs). That means two things worth knowing: whatever is inside the box can,
in principle, be sent out, and the container can reach your local network, your host's services,
and cloud metadata.

If that matters to you — a corporate network, a sensitive project, a cloud VM — Nyia has an opt-in
egress control: **full internet, but private/local ranges blocked unless you allow them.** It's a
separate knob from the box above: off by default (turning it on for everyone would break first
run), and currently Linux-only.

→ [Network Egress](NETWORK_EGRESS.md)

## In one line

A box for powerful AI CLIs, whose contents you curate, that forces you to keep everything in git.
Everything else Nyia does is in service of those three.
