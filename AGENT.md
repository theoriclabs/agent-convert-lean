# Convert a coding-agent session with Loom

Read [product intent](./INTENT.md): carry the conversation into the target as
its own prior history, including native tool calls and results. Preserve known
execution even when output was pruned. Importing history must not rerun tools.
Visible historical-tool disclaimers and carrier JSON are conversion defects,
not evidence of high fidelity; keep bookkeeping out of dialogue.

Loom is the release-ready Lean converter in
[`theoriclabs/agent-convert-lean`](https://github.com/theoriclabs/agent-convert-lean).
When a human asks to continue a session in another harness, use the single
public command:

```sh
loom convert <session-id-or-file> <target> [output]
```

Targets are `claude`, `codex`, `pi`, `cursor-agent`, `opencode`, and `loom`.
Check the [conversion matrix](./docs/conversion-matrix.md) for route-specific
inputs, output handling, native-history limits, and verification status.

## Do the conversion

From an existing checkout:

```sh
lake build loom
LOOM="$PWD/.lake/build/bin/loom"
"$LOOM" convert <session-id-or-file> <target> [output]
```

If no checkout exists:

```sh
git clone https://github.com/theoriclabs/agent-convert-lean.git
cd agent-convert-lean
lake build loom
LOOM="$PWD/.lake/build/bin/loom"
"$LOOM" convert <session-id-or-file> <target> [output]
```

A bare session ID is resolved across the standard Codex, Claude Code, and Pi
stores. An explicit path can point to any supported source. Loom detects the
format from the transcript itself.

For OpenCode, use its supported interchange file: `opencode export
<session-id> > session.json`. A Loom OpenCode target can be installed with
`opencode import <output.json>`.

When the target is Claude and `output` is omitted, Loom installs the session in
`~/.claude/projects` and prints the exact `claude --resume` command. For every
other target, provide a new output path; omit it only when stdout is intended.

Examples:

```sh
# Find this Codex/Pi session, convert it, install it for Claude, print resume.
"$LOOM" convert <session-id> claude

# Detect an explicit source and create a portable archive.
"$LOOM" convert /absolute/path/to/session.jsonl loom ./session.loom.json

# Convert an explicit source to a Codex file using safe defaults.
"$LOOM" convert /absolute/path/to/session.jsonl codex ./session.codex.jsonl

# Convert to OpenCode, then register the resulting session.
"$LOOM" convert /absolute/path/to/session.jsonl opencode ./session.opencode.json
opencode import ./session.opencode.json
```

## What you must check

- Identify one source session unambiguously. If “current session” is not enough
  to distinguish it, ask for its ID or path.
- Do not modify or overwrite the source transcript.
- Use a new output path. If a Claude session with the same ID is already
  installed, get confirmation before replacement.
- Let Loom derive source format, target schema version, continuation metadata,
  Pi history mode, Codex controls, and subagent policy. Add overrides only when
  the human wants a genuinely different target configuration or required
  source metadata is absent.
- Investigate conversion failures and improve the converter when appropriate
  within the task. Preserve source facts and explain remaining limitations.

Useful verified overrides are:

```text
--target-cwd <absolute-path>
--target-provider <provider>
--target-model <model>
--target-session-id <uuid>
--target-timestamp <utc-iso8601>
```

Do not invent values merely to satisfy validation.

## Report back

Tell the human:

- the resolved source format and path;
- the target and exact output/install path;
- whether an existing destination was replaced;
- every warning, refusal, carrier, or main-branch-only decision;
- the exact next command—especially the `claude --resume` line Loom prints.

Check native tool structures and resumed model context as well as readability
and Loom round trips. Report each separately; a readable carrier does not meet
the native-history requirement. Exit codes
are `1` for invocation/configuration, `2` for import, and `3` for
export/validation/publication.
