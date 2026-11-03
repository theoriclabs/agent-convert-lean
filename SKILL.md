---
name: agent-convert-lean
description: Convert and install coding-agent sessions with the agent-convert CLI. Use when a user wants to migrate a conversation between Claude Code, Codex CLI, Pi, Cursor Agent, OpenCode, and Loom.
---

# Convert a session

Use `agent-convert` for the mechanical workflow. It resolves the source, selects
configured target settings, adapts recorded PDFs, audits native history, checks
Codex loading and request serialization locally, installs a fresh session, and
prints the resume command. Do not recreate these steps with ad hoc scripts.

```sh
agent-convert find "distinctive words"
agent-convert convert <session-id-or-path> codex --name "Conversation title"
agent-convert convert <session-id-or-path> claude
# File export:
agent-convert convert <source> codex converted.jsonl --json
```

If the command is missing, install the CLI and discoverable skill from this
checkout:

```sh
python3 scripts/install-agent-convert.py --build
# Or: python3 scripts/install-agent-convert.py --core /path/to/loom
```

Read the maintained [session-conversion skill](./skills/agent-session-converter/SKILL.md)
for source acquisition, target handoffs, validation limits, and repair guidance.
It is installed as `$agent-session-converter` by the command above.

Keep source conversations intact and use the source's active compaction context.
Prior tool executions remain recorded native history; importing them must not
rerun them. Follow [INTENT.md](./INTENT.md) and report material adaptations.
A successful localhost serialization check establishes native request content,
not live model recall. Hand off the exact installed path and resume command.
