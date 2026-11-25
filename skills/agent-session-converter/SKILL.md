---
name: agent-session-converter
description: Find, convert, validate, and install coding-agent sessions between Claude Code, Codex CLI, Pi, Cursor Agent, OpenCode, and Loom. Also use to find, inspect, export, resume, or steer Google Antigravity CLI and desktop conversations.
---

# Convert a coding-agent session

## Antigravity conversations

Use `agent-convert antigravity list --json` or
`agent-convert find "keywords" --store antigravity --json` to identify the thread
UUID and surface.
`antigravity show <id> --surface <cli|desktop> --tail 6 --json` reads recent
dialogue. `antigravity transcript <id> --surface <cli|desktop>` exports the
recorded Antigravity JSONL log when available.

For a CLI thread, `agent-convert antigravity resume <id> --surface cli` prints
the native invocation. Add `--launch` in an interactive terminal. Use
`agent-convert antigravity send <id> --surface cli --prompt-file <path>` when
asked to send a follow-up and wait for the reply. Use `--prompt` for short text.

For a desktop thread, `agent-convert antigravity resume <id> --surface desktop
--json` returns the picker shortcut, search text, UUID, and workspace. Open the
app with computer use if available. Use the conversation picker to search, then
compare title, workspace, and preview before selecting a result. Verify the UUID
in the conversation URL when exposed. The reviewed app exposes a local
`/c/<uuid>` route. For a requested follow-up, paste it into **Message input**
after verifying the thread and submit if the user asked to send it. If computer
use is unavailable, provide the picker handoff printed by `resume`.

If the resume plan has `subagents`, start with its `rootId` conversation and
follow the entries in order. On desktop, open **Overview → Subagents** and
choose the `agentLabel`. The reviewed app exposes the selected side-panel
thread as `tab=subagent_convo__<uuid>` in the conversation URL. Check that UUID
and, for a requested follow-up, use the side-panel composer for that subagent.
The main composer addresses the parent. On CLI, resume `rootId` and use
`/agents` to inspect the subagent. Send to the subagent from the interactive
client using its `@` mention.

To import a desktop thread into Antigravity CLI, use `agy`'s `/resume` picker
and select the thread from **Other**. Use the resulting CLI copy's UUID for
subsequent CLI commands.

## Session conversion

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

For a Claude or Codex session that is still running, add `--snapshot` (any
target). It converts the records completed so far. A tool call still in progress,
and everything after it, is left out rather than given an invented result. The
receipt and output name what was left out. Later source updates are not
synchronized; disclose that the handoff is a snapshot. Without `--snapshot`, a
source that changes during conversion is refused.

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

Do not insert missing-reasoning notices, reasoning labels, or converter
disclaimers into dialogue. Opaque reasoning and original transport envelopes
belong in metadata sidecars. The CLI removes its authenticated generated
placeholders while preserving actual readable text and genuine tool failures.

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
