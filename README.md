# agent-convert

Convert coding-agent sessions between harnesses with Loom:

```sh
loom convert <session-id-or-file> <target> [output]
```

Experimental prerelease. Get binaries from
[GitHub releases](https://github.com/theoriclabs/agent-convert-lean/releases);
see the [conversion matrix](./docs/conversion-matrix.md) for fidelity limits
and tested continuation routes.

## Installed CLI and agent skill

```sh
python3 scripts/install-agent-convert.py --build
# Or supply a built/released core: --core /path/to/loom

agent-convert find "distinctive words"
agent-convert convert <session-id-or-path> codex --name "My conversation"
agent-convert convert <session-id-or-path> claude
# For a Claude or Codex session that is still running:
agent-convert convert <session-id> codex --snapshot
```

This installs `~/.local/bin/agent-convert` and the discoverable
`agent-session-converter` skill. No output path installs a new Codex or Claude
session and prints its resume command. Other targets require an output path;
Codex also supports file exports with an optional `--install`.

For Codex, the CLI uses configured model/provider settings, adapts recorded PDF
results into extracted text and page images, preserves original PDFs and image
results, and retains labeled peer context with original authorship metadata.
It restores unambiguous retained results omitted by Claude’s parent walk, audits
source arguments/results, and validates the actual native request through a
localhost test provider before publication. It never reruns historical tools or
calls an external model for validation. Codex conversions and file exports include a checksum-bound
conversion receipt. Use `--json` for one machine-readable receipt.

Codex may omit recorded tool-image `detail` preferences when serializing a
request. Validation records that specific omission in the receipt while keeping
image bytes, tool text, and ordering exact; installed history retains the preferences.

Claude exports keep unavailable reasoning in metadata rather than inserting
placeholder assistant messages. Native tool transport envelopes are rendered
as readable output, with exact originals retained in a metadata sidecar.

`agent-convert doctor` checks the installation. PDF results require Poppler;
native Codex validation requires the Codex CLI. `--validation artifact` explicitly
selects reduced verification. The installer builds committed source in isolation
and keeps an installed core independent of unfinished checkout edits.

## Quick start

With Lean/Lake installed, build using the pinned [`lean-toolchain`](./lean-toolchain):

```sh
lake build loom
export PATH="$PWD/.lake/build/bin:$PATH"

# Convert and install a session for Claude; prints the resume command.
loom convert <session-id> claude

# Convert a transcript into a new Codex file.
loom convert session.jsonl codex converted.codex.jsonl
```

Bare IDs resolve across Codex, Claude Code, and Pi stores. Paths work for all
supported sources; Loom detects the format and derives target defaults.
An explicit output writes a file. Omitting it installs Claude sessions or
writes other targets to stdout. File generation and harness installation are
separate steps for other targets. Run `loom` for options.

Targets: `claude`, `codex`, `pi`, `cursor-agent`, `opencode`, `loom`.
Also imports Cursor IDE, Hermes, and Google AI Studio. Source acquisition and
target handoff details are in the [conversion matrix](./docs/conversion-matrix.md).

For Cursor IDE's native `agent-transcripts/.../*.jsonl` exports, Loom recovers
omitted tool results from the matching local IDE conversation after verifying
the messages and calls. See [Cursor export recovery](./docs/cursor-tool-binary.md#ide-transcript-exports)
for copied exports, database snapshots, and matching limits.

## Use with an agent

Give your agent [SKILL.md](./SKILL.md), or paste:

```text
Read https://raw.githubusercontent.com/theoriclabs/agent-convert-lean/main/SKILL.md
and convert my Codex session <session-id> to Claude Code.
```

The skill covers source discovery, conversion, verification, and the handoff.

## Find sessions

```sh
loom search "distinctive words" --limit 20
loom text <session-id-or-file>   # JSON rows for indexing
```

### Google Antigravity

The installed `agent-convert` CLI can inspect local Antigravity CLI and desktop
threads. Use `--surface` on thread commands or `--store` on `find` to narrow results.

```sh
agent-convert antigravity list --json
agent-convert find "distinctive words" --store antigravity
agent-convert antigravity show <conversation-id> --surface desktop --tail 5
agent-convert antigravity transcript <conversation-id> --surface desktop > thread.jsonl
agent-convert antigravity resume <conversation-id> --surface cli --launch
agent-convert antigravity send <conversation-id> --surface cli --prompt "Summarize the remaining work."
agent-convert antigravity resume <conversation-id> --surface desktop --launch
```

Search covers titles, previews, IDs, and dialogue in available logs. The
`transcript` command exports Antigravity JSONL, preferring the full log when
present. Threads without logs can still appear in the list.
[Antigravity transcript locations](https://antigravity.google/docs/hooks)

For CLI threads, `resume` prints the native `agy` command. Add `--launch` to
run it. For desktop threads, `resume` gives you the conversation picker
shortcut and search term. On macOS, `--launch` also opens the app. To import a
desktop thread into the CLI, select it from the **Other** tab in `agy`'s `/resume`.
[Desktop search](https://antigravity.google/docs/search/)
[CLI resume and desktop import](https://antigravity.google/docs/cli/commands/resume/)

Subagents appear in `list`, `find`, and `show` with their recorded labels and
parent IDs where available. For a subagent UUID, `resume --json` gives the main
conversation's `rootId` and the `subagents` path. Open the main conversation
and select the subagent from **Overview → Subagents** on desktop or `/agents`
in the interactive CLI.
[Desktop Overview panel](https://antigravity.google/docs/side-panel)
[CLI Agent Manager](https://antigravity.google/docs/cli/commands/agents)

For agent tool access, see the [MCP server](./mcp/README.md).
To browse every local session as a chat thread, run the [viewer](./viewer/README.md).
For changes and design goals, see the [changelog](./CHANGELOG.md) and
[product intent](./INTENT.md).

## Development

Run `scripts/verify-local.sh` for the product build and local regressions.
See [the development guide](./docs/development.md) for module boundaries,
external integration checks, and known validation gaps.

MIT licensed. See [`LICENSE`](./LICENSE).
