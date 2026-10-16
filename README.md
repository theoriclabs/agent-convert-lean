# agent-convert

Convert coding-agent sessions between harnesses with Loom:

```sh
loom convert <session-id-or-file> <target> [output]
```

Experimental prerelease. Get binaries from
[GitHub releases](https://github.com/theoriclabs/agent-convert-lean/releases);
see the [conversion matrix](./docs/conversion-matrix.md) for fidelity limits
and tested continuation routes.

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

For agent tool access, see the [MCP server](./mcp/README.md).
To browse every local session as a chat thread, run the [viewer](./viewer/README.md).
For changes and design goals, see the [changelog](./CHANGELOG.md) and
[product intent](./INTENT.md).

## Development

Run `scripts/verify-local.sh` for the product build and local regressions.
See [the development guide](./docs/development.md) for module boundaries,
external integration checks, and known validation gaps.

MIT licensed. See [`LICENSE`](./LICENSE).
