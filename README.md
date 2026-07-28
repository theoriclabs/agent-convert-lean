# agent-convert

Convert coding-agent sessions between harnesses.

```sh
loom convert <session-or-file> <target> [output]
```

That is the API. Loom finds the session, detects its format, chooses safe
defaults, validates the conversion, and produces a session you can continue.
The Lean core and one-command interface are release-ready.

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

## Formats

| Format | Import | Export | Output |
|---|:---:|:---:|---|
| Claude Code | yes | yes | Installed session or file |
| Codex CLI | yes | yes | File / stdout |
| Pi | yes | yes | File / stdout |
| Cursor Agent | yes | yes | File / stdout |
| Loom wire | yes | yes | Portable archive |
| Cursor IDE | yes | — | Source only |
| Hermes | yes | — | Source only |
| Google AI Studio | yes | — | Source only |

Targets: `claude`, `codex`, `pi`, `cursor-agent`, and `loom`.

Pi and Codex are flat targets, so they default to the main conversation. If a
caller explicitly requests non-main threads, Loom refuses instead of silently
flattening them.

MIT licensed. See [`LICENSE`](./LICENSE).
