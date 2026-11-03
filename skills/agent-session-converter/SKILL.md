---
name: agent-session-converter
description: Find, convert, validate, and install coding-agent sessions between Claude Code, Codex CLI, Pi, Cursor Agent, OpenCode, and Loom. Use for session migration or repair of imported conversation and tool history.
---

# Convert a coding-agent session

Use the installed `agent-convert` CLI. It owns the mechanical workflow: session
resolution, target settings, recorded PDF/image adaptation, labeled peer
context with original authorship metadata, native-history audits, recovery of
retained results omitted by Claude’s parent walk, Codex loading and local request serialization, installation, naming, receipts,
and the resume command. Do not reproduce those operations with ad hoc scripts.

```sh
agent-convert doctor
agent-convert find "distinctive words" --limit 20
agent-convert convert <session-id-or-path> codex --name "Conversation title"
agent-convert convert <session-id-or-path> claude
```

A screenshot may supply the session ID and project. Read them and pass the ID
to the CLI. If it supplies only a title or quotation, find candidates and match
their dialogue/project. A unique search query can also be passed as the source.
Ask the user only when the available evidence cannot identify one session.

No output path installs Codex or Claude. An output path requests a file export;
Codex additionally accepts `--install`. Other targets require an output path:

```sh
agent-convert convert <source> codex converted.jsonl --json
agent-convert convert <source> opencode converted.json
# Register the exported OpenCode session:
opencode import converted.json
```

For Cursor IDE acquisition, export the selected composer through Loom's
`cursor-ide <state.vscdb> <composer-id> loom <archive>` command first. OpenCode
sources require `opencode export <id>` to acquire an interchange file. A Cursor
Agent file export is not an established native resume installation.

The CLI uses the user's configured Codex model/provider unless overridden with
`--model` / `--provider`. Use `--cwd` only for a requested destination directory.
It creates a new target ID; an explicit `--session-id` is never silently repaired.

For Codex, default validation calls the installed runtime with an isolated copy
and a localhost test provider. It checks native calls, exact outputs, and PDF
page images in the actual serialized request. It makes no external model
request and does not rerun historical tools. This is not a live model recall
test. `--validation artifact` is an explicit reduced check, useful when Codex
is unavailable for file-only conversion; disclose that limitation.

The source stays intact. Follow the original source's active compaction window.
Never route a compacted Codex source through a full Loom archive as a workaround.
If the CLI refuses conversion, retain its diagnostic directory and fix the
reported acquisition or representation problem within the user's scope. Keep
bookkeeping outside dialogue; don't turn prior executions into assistant
claims, strip their known completion status, or invent missing results.

Report the matched conversation, target, installed/output path, material
adaptations, validation performed, and the exact command printed by the CLI.
Keep the handoff concise. Do not run the user's next task merely to test migration.

If `agent-convert` is missing, install from the existing checkout:

```sh
python3 scripts/install-agent-convert.py --build
# Or use an already built/released Loom executable:
python3 scripts/install-agent-convert.py --core /path/to/loom
```

The installer builds committed source in an isolated directory and installs a
stable core, so an unrelated unfinished checkout cannot break normal use.
`AGENT_CONVERT_CORE` or `agent-convert --core /path/to/loom …` selects another core.

For an already-resumed session containing generated Claude notification clutter,
read [notification-repair.md](references/notification-repair.md). Preserve the
latest target work when repairing; the source alone may be stale.
