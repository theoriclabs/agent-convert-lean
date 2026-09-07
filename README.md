# agent-convert

Convert coding-agent sessions between harnesses.

See the [changelog](./CHANGELOG.md) and
[GitHub releases](https://github.com/theoriclabs/agent-convert-lean/releases)
for versioned changes and downloads. The current release is an experimental
prerelease; its notes list known limitations.

The destination should continue the same conversation, including prior tool
executions as native tool history. Conversion metadata belongs outside dialogue;
tool-carrier prose is not equivalent fidelity. See [product intent](./INTENT.md)
and the [Cursor native-history fix](./docs/cursor-tool-binary.md).

```sh
loom convert <session-or-file> <target> [output]
```

That is the API. Loom finds the session, detects its format, chooses safe
defaults, validates the conversion, and produces a session you can continue.
The Lean core and one-command interface are available in the prerelease.

## Give this to your agent

Point your agent at the
**[raw one-page runbook](https://raw.githubusercontent.com/theoriclabs/agent-convert-lean/main/AGENT.md)**
([view it here](./AGENT.md)):

```text
Read https://raw.githubusercontent.com/theoriclabs/agent-convert-lean/main/AGENT.md
and convert my current Codex session to Claude Code.
```

## Quick start

Build with the toolchain pinned by [`lean-toolchain`](./lean-toolchain):

```sh
lake build loom
export PATH="$PWD/.lake/build/bin:$PATH"
```

Convert a Codex or Pi session to Claude Code:

```sh
loom convert <session-id> claude
```

Convert an exported OpenCode chat, or produce a file OpenCode can import:

```sh
opencode export <session-id> > session.opencode.json
loom convert session.opencode.json codex session.codex.jsonl

loom convert session.codex.jsonl opencode session.opencode.json
opencode import session.opencode.json
```

## Good defaults

`convert` automatically:

- resolves session IDs across Codex, Claude Code, and Pi stores;
- detects the source format from the transcript—not its filename;
- carries forward recorded project, session, and time metadata;
- selects validated target versions, models, and runtime controls;
- preserves supported subagent sidecars;
- validates before publishing and refuses destructive conversions.

Override a default only when the new session needs something different:

```sh
loom convert <session-or-file> <target> [output] \
  --target-cwd /absolute/project/path \
  --target-provider <provider> \
  --target-model <model> \
  --target-session-id <uuid> \
  --target-timestamp <utc-iso8601>
```

Run `loom` with no arguments to see the available overrides.

## Search and analytics

Loom is not only a converter — it reads every local harness store as one
searchable corpus.

```sh
loom search "flash attention"            # all stores, ranked hits
loom search "kanban" --store hermes      # one harness
loom search "deploy" --role user --limit 20 --json
loom text <session-id|file>...           # JSON search rows for indexing
```

`search` matches a case-insensitive AND of whitespace tokens against the
canonical IR, so a Claude `tool_result`, a Codex `function_call_output`, and a
pi tool result all match the same way. `text` emits one JSON row per entry
(`role`, `index`, `ms`, `tools`, `text`) for an external index. Scope large
queries with `--store` / `--limit`.

An MCP server exposes all of this — search, text, convert, inspect, detect,
version — to any agent as a control plane. See [`mcp/`](./mcp/README.md):

```sh
claude mcp add loom -- node "$PWD/mcp/loom-mcp.mjs"
```

## Formats

See the [conversion matrix](./docs/conversion-matrix.md) for source → target
routes, native-history representations, installation steps, known limits, and
which continuations have actually been tested.

| Format | Import | Export | Output |
|---|:---:|:---:|---|
| Claude Code | yes | yes | Installed session or file |
| Codex CLI | yes | yes | File / stdout |
| Pi | yes | yes | File / stdout |
| Cursor Agent | yes | yes | File / stdout |
| OpenCode | yes | yes | Import/export JSON file |
| Loom wire | yes | yes | Portable archive |
| Cursor IDE | yes | — | Source only |
| Hermes | yes | — | Source only |
| Google AI Studio | yes | — | Source only |

Targets: `claude`, `codex`, `pi`, `cursor-agent`, `opencode`, and `loom`.

Pi, Codex, and OpenCode are flat targets, so they default to the main
conversation. If a
caller explicitly requests non-main threads, Loom refuses instead of silently
flattening them.

MIT licensed. See [`LICENSE`](./LICENSE).
