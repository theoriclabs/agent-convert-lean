# Conversion matrix

Last reviewed: 2026-09-07. This describes the current checkout, not every vendor
version or a guarantee that every transcript converts without limitations.

## Routes

All conversions pass through the Loom IR. **C** = conditional harness export:
the route exists, but content, lifecycle, branch, and target prerequisites still
apply. **L** = limited Cursor Agent transcript export (no native result records).
**A** = Loom archive of the imported IR, not a runnable harness session.
These are routing capabilities, **not per-cell test-pass or fidelity ratings**.

<!-- routes:start -->
| Source ↓ / target → | `claude` | `codex` | `pi` | `cursor-agent` | `opencode` | `loom` |
| --- | --- | --- | --- | --- | --- | --- |
| `claude` | C | C | C | L | C | A |
| `codex` | C | C | C | L | C | A |
| `pi` | C | C | C | L | C | A |
| `cursor-agent` | C | C | C | L | C | A |
| `opencode` | C | C | C | L | C | A |
| `cursor-ide` | C | C | C | L | C | A |
| `hermes` | C | C | C | L | C | A |
| `google-ai-studio` | C | C | C | L | C | A |
| `loom` | C | C | C | L | C | A |
<!-- routes:end -->

There are no exporters for Cursor IDE, Hermes, or Google AI Studio. Cursor IDE
and Cursor Agent are different formats; exporting a Cursor Agent transcript
does not install a conversation in Cursor IDE. Same-format conversion is also
subject to validation and is not necessarily a byte-for-byte file copy.

## What to supply

| Source | Input | Source-specific limit |
| --- | --- | --- |
| Claude Code | Session JSONL or resolvable session ID | Supported subagent sidecars are separate files. |
| Codex CLI | Rollout JSONL or resolvable session ID | Harness targets receive the latest active compaction context plus subsequent history; `loom` archives the full stream. |
| Pi | Session JSONL or resolvable session ID | Branches must be selected or preserved in an appropriate output. |
| Cursor Agent | Agent transcript JSONL | Observed source format has tool calls but no tool-result records; conversion cannot recover results from this file alone. |
| OpenCode | JSON from `opencode export <id>` | Not the live database; use the supported interchange document. |
| Cursor IDE | `state.vscdb` plus composer ID, or extracted `{composer,bubbles}` JSON | Use the rich store, not an incomplete text/Agent export. Binary recovery currently covers grep, edit, and conversation search; unsupported recovery remains explicit. |
| Hermes | Session JSON with `messages[]` | Source has no per-message timestamps or recorded tool-error flag; do not invent them. |
| Google AI Studio | Export JSON with `chunkedPrompt.chunks[]` | External media references are not automatically downloaded; missing source project/time metadata remains distinguishable. |
| Loom | `loom.transcript.v0` JSON archive | Contains what its importer captured. An older incomplete archive cannot recover missing source data by itself. |

`gais` is also accepted as an explicit source alias for `google-ai-studio`.
Bare-ID discovery covers Claude Code, Codex, and Pi; use paths for other sources.

## How each target represents history

| Target | Tool-history representation | Output / next step | Important limits |
| --- | --- | --- | --- |
| Claude Code | Native `tool_use` / `tool_result` for eligible pairs | Omit output to install and print a resume command, or write a file | Canonical identity travels in metadata. Native error boolean does not preserve every source error-provenance distinction. Some unresolved/unsupported cases still use legacy carriers or refuse. |
| Codex CLI | Native `function_call` / `function_call_output`; compatible imported custom-tool records | JSONL file; register/install as a new Codex session to resume | Full error provenance is preserved in metadata. Text-result pairs are supported; ambiguous IDs, incomplete lifecycles, and unsupported content can still fall back or refuse. File generation alone is not a tested resume. |
| Pi | Native `toolCall` / tool-result messages for eligible history | JSONL file; load with Pi's session workflow | Canonical identity and error provenance travel in metadata. Flat selected conversation; target history mode and content constraints still apply. |
| Cursor Agent | Native `tool_use` where eligible; no native tool-result channel in the supported transcript schema | Transcript file only | Results and unsupported content may survive only as carriers, not native history. Local transcript-to-resume installation is not established by this exporter; historical validation recorded a negative result. |
| OpenCode | Assistant `tool` part combines a call with `pending`, `completed`, or `error` state | JSON file, then `opencode import <file>` | Flat output. Result text blocks are joined; the exporter does not preserve all source error provenance or block boundaries. No fresh live-continuation claim is made here. |
| Loom | Typed calls, results, positional links, error provenance, and threads | Portable JSON archive | Preserves the serialized IR; not a target model context and not proof that acquisition captured every source fact. |

Codex, Pi, and OpenCode default to the main conversation. Explicitly including
non-main threads in a flat target is refused. Supported Claude/Cursor Agent
sidecars and Loom archives can preserve thread structure; they do not make
unsupported source branches or missing sidecars appear.

## Workflows

```sh
loom convert <session-id-or-file> <target> <new-output-path>

# Rich Cursor IDE acquisition, followed by a harness conversion:
loom cursor-ide <state.vscdb> <composer-id> loom source.loom.json
loom convert source.loom.json codex converted.codex.jsonl
```

Keep originals and use new destinations. A native record represents a past
execution; importing it must not execute the tool again. A carrier that merely
round-trips is not native-history fidelity. See [product intent](../INTENT.md).

## Verification and maintenance

- **Routing inventory:** `importByFormat` and `exportByFormat` in
  [Main.lean](../LoomConvert/Main.lean) define the nine sources and six targets.
  `node scripts/check-conversion-matrix.mjs` checks this table against those
  dispatchers, including aliases. It does not claim semantic correctness.
- **Adapter behavior:** [target capabilities](../LoomOps/Interop.lean) and
  [OpenCode's adapter](../LoomConvert/OpenCode.lean) explain native shapes and
  metadata. Update this document when an importer, exporter, or limitation changes.
- **Legacy cross-route audit:** [audit-lifecycle-matrix.mjs](../scripts/audit-lifecycle-matrix.mjs)
  has an explicit 8-source × 5-target inventory, without OpenCode. Its historical
  expectations include carriers; it is not a 9 × 6 native-continuation certificate.
- **Verified Cursor IDE → Codex case:** synthetic recovery/native-history
  regressions and an actual synthetic Codex continuation passed, with exact
  prior-result recall, failure recognition, and zero new calls. See
  [scope and reproduction](./cursor-tool-binary.md). Do not extrapolate this
  result to every matrix cell or every Cursor binary schema.
- **Remaining suite failures:** the full requirements build retains the three
  pre-existing failures recorded in [CLAUDE.md](../CLAUDE.md). Keep known failures
  and vendor versions visible when adding new test results.

For a newly verified route, record the source variant, target version, content
classes, native/carrier/refusal behavior, and whether an actual continuation
was exercised. Use synthetic fixtures in the repository, never private sessions.
