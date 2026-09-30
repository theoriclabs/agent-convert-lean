---
name: agent-convert-lean
description: Convert coding-agent sessions between Claude Code, Codex CLI, Pi, Cursor Agent, OpenCode, and Loom. Use when asked to migrate or continue a session in another harness, or find a local transcript for conversion.
---

# Convert a session with Loom

Carry the requested conversation into the destination, including its prior
tool activity, and give the user a usable handoff. Use Loom's importer and
exporter rather than rewriting transcripts by hand.

## Locate the source

Use the supplied session ID or transcript path. Bare IDs resolve across the
standard Codex, Claude Code, and Pi stores; other sources need explicit paths.
Loom detects the format from the content, not the filename.

If the user gives a title, quoted message, or project instead of an ID, search
and inspect candidates:

```sh
loom search "distinctive words" --limit 20
loom text <session-id-or-file>
loom detect <file>
loom inspect <source-format> <file>
```

Confirm the conversation from its messages and project. Ask for an ID or path
only if the available evidence cannot distinguish the intended session.

For **OpenCode**, acquire an interchange file with
`opencode export <session-id> > source.opencode.json`.
For **Cursor IDE**, use the rich store and composer ID:

```sh
loom cursor-ide <state.vscdb> <composer-id> loom source.loom.json
loom convert source.loom.json <target> <new-output-path>
```

Cursor IDE and Cursor Agent are separate formats. A Cursor Agent transcript
may omit tool results that remain recoverable from the IDE store.

## Convert

Use an available `loom` binary. From a repository checkout, build with the
toolchain pinned in `lean-toolchain`:

```sh
lake build loom
export PATH="$PWD/.lake/build/bin:$PATH"
loom convert <session-id-or-file> <target> [output]
```

If only this skill file is available, find an existing checkout or clone
[`theoriclabs/agent-convert-lean`](https://github.com/theoriclabs/agent-convert-lean)
into a new directory and build there. Lean/Lake must be installed to build.

Keep the source intact and choose a new destination. Let Loom infer target
settings; use `--target-cwd`, `--target-provider`, `--target-model`,
`--target-session-id`, or `--target-timestamp` when the user requests a change
or required metadata is absent. Obtain missing facts from the source or user.
If installation would replace another session, use a fresh target session ID
unless replacement is already authorized.

| Target | Output and handoff |
| --- | --- |
| `claude` | Omit output to install into Claude's project store and print the exact resume command. Supply output for a file conversion. |
| `codex` | Write a JSONL file. Native store registration is a separate step; Loom does not install it automatically. |
| `pi` | Write a JSONL file and load it through Pi's session workflow. |
| `opencode` | Write JSON, then register it with `opencode import <output.json>`. |
| `cursor-agent` | Write a transcript file. A supported transcript-to-resume installation is not established. |
| `loom` | Write a portable archive; it is not a runnable harness session. |

For targets other than Claude, omitting output writes to stdout. Consult the
[conversion matrix](./docs/conversion-matrix.md) for route-specific limits and
installation guidance. Codex, Pi, and OpenCode default to the main conversation;
explicit inclusion of non-main threads is refused. Supported sidecars do not
make every target capable of preserving threads.

## Verify and hand off

Review the conversion's warnings and summary. With an explicit output path,
add `--json` to see imported/native/carried tool counts, compaction boundaries,
and export obligations. The shorthand command prints a resolution line before
the JSON summary; do not assume all stdout is one JSON document.

Follow [product intent](./INTENT.md): past executions should be native tool
history, with their recorded arguments, results, links, and execution state.
Importing history must not rerun tools. A completed call with pruned output
remains completed; recover retained results from source data where possible,
without inventing outputs or rerunning the old operation. Keep conversion
bookkeeping in metadata or sidecars, outside dialogue.

For compacted Codex sources, continuation targets use the latest active context
plus subsequent history. Only `loom` archives the full stream. Converting that
full archive into a continuation is not a substitute for the active-context
import from the original rollout.

Inspect the generated file with `loom detect` and `loom inspect`, including
native tool pairs when present. Distinguish file validation from a tested
destination resume; readable carriers and Loom round trips do not establish
native-history fidelity. Report any carriers, omitted threads, or other
material limits. On failure, investigate the reported cause and retain the
original; improve the converter when appropriate within the requested scope.
Exit codes: `1` invocation/configuration, `2` import, `3` export/validation/publication.

Report the matched source, target, exact output or install path, verification
performed, material limitations, and next command. For Claude, use the resume
command Loom prints. Do not claim a continuation was tested unless it was.
