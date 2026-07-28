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

Loom finds the session, installs the conversion under `~/.claude/projects`,
and prints the exact resume command:

```text
cd /path/to/project && claude --resume <session-id>
```

Paths work too:

```sh
loom convert ~/.codex/sessions/2026/07/27/rollout-….jsonl claude
```

Add an output path to write a file instead of installing:

```sh
loom convert session.jsonl loom session.loom.json
loom convert session.jsonl codex session.codex.jsonl
loom convert session.jsonl pi session.pi.jsonl
```

Without an output path, Claude is installed and other targets go to stdout:

```sh
loom convert session.jsonl loom > session.loom.json
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

## Checked, not guessed

Agent sessions contain more than chat: tool calls, results, reasoning,
compaction, branches, subagents, environment records, and harness controls.
Loom converts through a typed, format-neutral transcript:

```text
source -> parse -> validate -> Loom IR -> target policy -> validate -> publish
```

Exports are rendered completely before an atomic rename. Failures are explicit:
invocation `1`, import `2`, and export/validation/publication `3`.

Build the executable and proof-bearing requirements together:

```sh
lake build loom LoomRequirements
```

Deep dives: [requirements](./REQUIREMENTS.md),
[evidence](./REQUIREMENTS_EVIDENCE.md),
[human validation](./HUMAN_VALIDATION.md),
[release procedure](./RELEASE_CHECKLIST.md), and [audit history](./AUDIT.md).

MIT licensed. See [`LICENSE`](./LICENSE).
