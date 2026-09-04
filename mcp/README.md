# loom-mcp — Loom as an MCP control plane

`loom-mcp.mjs` is a [Model Context Protocol](https://modelcontextprotocol.io)
server that exposes the `loom` binary to any MCP client, so an agent can search,
project, convert, and inspect transcripts across every local harness through one
interface. It is zero-dependency Node (newline-delimited JSON-RPC 2.0 over
stdio) and shells out to `loom`; it never parses transcripts itself, so the Lean
core stays the single source of truth.

## Tools

| Tool | What it does |
|---|---|
| `loom_search` | Search all stores (codex, claude, pi, cursor-agent, hermes) for tokens. Returns `{store, file, role, index, snippet}` rows. Scope with `store` / `limit`. |
| `loom_text` | Project sessions to JSON search rows (session header + one row per entry). |
| `loom_convert` | Convert a session to another harness (`loom`, `pi`, `claude`, `codex`, `cursor-agent`, `opencode`). |
| `loom_inspect` | Human/JSON review of one session: roles, threads, tool calls, losses. |
| `loom_detect` | Detect a transcript's harness format from its bytes. |
| `loom_version` | Report the loom core identity. |

## Binary resolution

`$LOOM_BIN`, else `../.lake/build/bin/loom` next to the server, else `loom` on
`PATH`. Build the binary first with `lake build loom`.

## Register with a client

Claude Code:

```sh
claude mcp add loom -- node /abs/path/to/agent-convert-lean/mcp/loom-mcp.mjs
```

Any client that speaks MCP stdio: run `node mcp/loom-mcp.mjs`, set
`LOOM_BIN` if the binary is not at the default path.

## Smoke test

```sh
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"x","version":"0"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"loom_version","arguments":{}}}' \
  | node mcp/loom-mcp.mjs
```
