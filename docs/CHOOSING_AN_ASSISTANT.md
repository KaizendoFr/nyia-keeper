# Choosing an Assistant

Nyia Keeper ships five assistants. They share the same safe, dockerized workflow — they
differ in model, strengths, and how you authenticate.

| Assistant | Strengths | Best for | Authentication |
|-----------|-----------|----------|----------------|
| **Claude** | Advanced reasoning, code analysis | Complex architecture, debugging, reviews | API key |
| **Gemini** | Multimodal, fast responses | Images, documents, rapid prototyping | OAuth |
| **Codex** | Code completion, generation | Boilerplate, refactoring, snippets | OpenAI API |
| **OpenCode** | Privacy, customization | Local inference, sensitive projects | None required |
| **Vibe** | Mistral AI, fast inference | Code generation, chat | Mistral API |

Each assistant is launched with its own command — `nyia-claude`, `nyia-gemini`,
`nyia-codex`, `nyia-opencode`, `nyia-vibe` — and authenticated once with `--login`
(or `--set-api-key` for key-based assistants). See [Quick Start](QUICKSTART.md#setup-authentication)
for the per-assistant auth steps.

You can use several assistants on the same project; each runs in its own container and works
on a git branch, so they never collide.

Next: [Quick Start →](QUICKSTART.md)
