# Conversion matrix

Last reviewed: 2026-10-15. This describes the current checkout, not every vendor
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
| Claude Code | Session JSONL or resolvable session ID | Supported subagent sidecars are separate files. Generated task notifications are archived using `isMeta` or explicit system-origin metadata, including recent records without `isMeta`; literal user XML stays in conversation. |
| Codex CLI | Rollout JSONL or resolvable session ID | Harness targets receive the latest replacement history, ordered retained user/assistant context, and subsequent history; `loom` archives the full stream. |
| Pi | Session JSONL or resolvable session ID | Branches must be selected or preserved in an appropriate output. |
| Cursor Agent / IDE transcript export | Agent transcript JSONL | The file omits tool results. For native `agent-transcripts/<session>/<session>.jsonl` paths, Loom checks the same IDE composer and recovers recorded results when messages and ordered calls agree. Standalone files alone cannot supply missing results. |
| OpenCode | JSON from `opencode export <id>` | Not the live database; use the supported interchange document. |
| Cursor IDE | `state.vscdb` plus composer ID, or extracted `{composer,bubbles}` JSON | Use the rich store, not an incomplete text/Agent export. Binary recovery currently covers grep, edit, and conversation search; unsupported recovery remains explicit. |
| Hermes | Session JSON with `messages[]` | Source has no per-message timestamps or recorded tool-error flag; do not invent them. |
| Google AI Studio | Export JSON with `chunkedPrompt.chunks[]` | External media references are not automatically downloaded; missing source project/time metadata remains distinguishable. |
| Loom | `loom.transcript.v0` JSON archive | Contains what its importer captured. An older incomplete archive cannot recover missing source data by itself. |

`gais` is also accepted as an explicit source alias for `google-ai-studio`.
Bare-ID discovery covers Claude Code, Codex, and Pi; use paths for other sources.

Continuation exports require at least one native user text turn in the active
window. `--allow-empty-dialogue` permits deliberate tool-only archives and is
recorded as `allowEmptyDialogue` in `--json` output. The `loom` archive target is
exempt from this guard.

The IR and archive/carrier codecs distinguish native error flags, structured
status evidence, heuristic guesses, and unrecorded status. Legacy `inferred`
records decode as heuristic evidence; new records use `structured` or `heuristic`.
Continuation export refuses native failure flags contradicted by recorded
success. Nonzero inner command exits take precedence over outer-runner success.

## How each target represents history

| Target | Tool-history representation | Output / next step | Important limits |
| --- | --- | --- | --- |
| Claude Code | Native `tool_use` / `tool_result` for eligible pairs, with translated or exact source tool names | Omit output to install and print a resume command, or write a file | Canonical identity and exact error provenance travel in validated metadata. Only native or structured evidence can set the native error boolean. Encrypted or unsupported results use labeled native placeholders with exact source content in metadata. Some unresolved/unsupported cases still use legacy carriers or refuse. |
| Codex CLI | Native `function_call` / `function_call_output`; compatible imported custom-tool records | JSONL file; register/install as a new Codex session to resume | Full error provenance is preserved in metadata. Text-result pairs are supported; ambiguous IDs, incomplete lifecycles, and unsupported content can still fall back or refuse. File generation alone is not a tested resume. |
| Pi | Native `toolCall` / tool-result messages for eligible history | JSONL file; load with Pi's session workflow | Canonical identity and error provenance travel in metadata. Flat selected conversation; target history mode and content constraints still apply. |
| Cursor Agent | Native `tool_use` where eligible; no native tool-result channel in the supported transcript schema | Transcript file only | Results and unsupported content may survive only as carriers, not native history. Local transcript-to-resume installation is not established by this exporter; historical validation recorded a negative result. |
| OpenCode | Assistant `tool` part combines a call with `pending`, `completed`, or `error` state | JSON file, then `opencode import <file>` | Flat output. Result text blocks are joined; error provenance travels in metadata, while result block boundaries can still normalize. No fresh live-continuation claim is made here. |
| Loom | Typed calls, results, positional links, error provenance, and threads | Portable JSON archive | Preserves the serialized IR; not a target model context and not proof that acquisition captured every source fact. |

Codex, Pi, and OpenCode default to the main conversation. Explicitly including
non-main threads in a flat target is refused. Supported Claude/Cursor Agent
sidecars and Loom archives can preserve thread structure; they do not make
unsupported source branches or missing sidecars appear.

For Codex → Claude, reviewed single-command JavaScript `exec` wrappers translate
to `Bash`. Other string-valued wrappers retain their original `exec` name and
input in native history when the call/result pair is eligible. This preserves
the recorded outer operation, not a reconstruction of its inner tool calls;
it does not install a callable JavaScript tool in Claude.

For Codex targets, source call IDs longer than the API's 64-character limit
receive collision-free short aliases on both native calls and results. Original
IDs remain in metadata and are restored on import. Existing converted rollouts
can be repaired into a new file. See [the API-limit regression](./bugs/codex-call-id-length.md).

## Workflows

```sh
loom convert <session-id-or-file> <target> <new-output-path>

# Rich Cursor IDE acquisition, followed by a harness conversion:
loom cursor-ide <state.vscdb> <composer-id> loom source.loom.json
loom convert source.loom.json codex converted.codex.jsonl

# Native IDE JSONL exports also recover from the matching local store:
loom convert ~/.cursor/projects/<project>/agent-transcripts/<id>/<id>.jsonl codex output.jsonl
```

Keep originals and use new destinations. A native record represents a past
execution; importing it must not execute the tool again. A carrier that merely
round-trips is not native-history fidelity. See [product intent](../INTENT.md).

## Verification and maintenance

- **Routing inventory:** `importByFormat` and `exportByFormat` in
  [Formats.lean](../LoomConvert/Cli/Formats.lean) define the nine sources and six targets.
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
- **IDE transcript acquisition:** `python3 scripts/test-cursor-ide-transcript.py`
  exercises a synthetic SQLite store, exact result/ID recovery, stale-source
  refusal, and native Codex/Claude records. These are artifact checks, not a
  new authenticated model-continuation claim. See
  [matching rules and limits](./cursor-tool-binary.md#ide-transcript-exports).
- **Codex call-ID limits:** `node scripts/test-codex-call-ids.mjs` checks
  boundary lengths, alias collisions, source-ID restoration, and repair of old
  rollouts. The long-ID synthetic continuation and `--run --compact` probe
  passed on Codex CLI 0.153.4 on 2026-09-08, with prior-result recall and no new
  tool calls. See [the regression report](./bugs/codex-call-id-length.md).
- **Codex JavaScript → Claude:** `node scripts/test-claude-exec-history.mjs`
  checks native composite/dynamic/privileged wrapper pairs, exact outputs,
  recorded failure, compaction selection, and stable re-export. Add `--live`
  for an authenticated Claude continuation with tools/customizations disabled
  and session persistence off; it checks prior-result recall and failure
  recognition, then removes only its synthetic installed transcript.
  The synthetic live probe passed on Claude Code 2.1.263 on 2026-09-07,
  including exact empty-output recall. This is not a claim about every tool
  schema or unresolved lifecycle.
- **Requirements checks:** the full requirements build now passes and runs in
  `scripts/verify-local.sh`. Keep known validation gaps
  and vendor versions visible when adding new test results.

For a newly verified route, record the source variant, target version, content
classes, native/carrier/refusal behavior, and whether an actual continuation
was exercised. Use synthetic fixtures in the repository, never private sessions.
