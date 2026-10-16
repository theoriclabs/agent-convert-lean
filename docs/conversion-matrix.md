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

Recorded versions newer than `reviewedSourceVersion` produce an import warning
and `sourceVersionBeyondReviewed: {observed, reviewed}` in conversion JSON.
Versioned fixtures define the baseline; this warning does not reject otherwise
valid open-world records. Pi records a schema number, while the reviewed Cursor
Agent corpus has no release-version baseline.

Codex `item_completed` events that exactly mirror adjacent dialogue are retained
in entry provenance without duplicating conversation. Unambiguous same-turn
`exec` command completions supply structured result status. Other reviewed
non-dialogue completions attach to neighboring entries; unmatched conversation
and unknown future event kinds remain explicit events.

The opt-in `scripts/continuation-probe.mjs` gate checks current-request and
last-result recall in a signed-in Claude harness. All three versioned Codex
compaction fixtures passed on Claude Code 2.1.301 on 2026-10-16; exact replies
and limits are in `REQUIREMENTS_EVIDENCE.md`. Other harnesses are not covered by
this live probe. The separate opt-in `scripts/compaction-continuation-probe.mjs`
checks summary-only fact recall in the configured Pi model.

Native compaction summaries remain model context in Claude and Pi. Claude
restores a recorded native boundary and summary when available; otherwise it
uses a labeled user summary. Pi keeps valid native checkpoints and uses a
`custom_message` summary when coverage or token count is unknown. These
fallbacks report `projectCompactionSummary`: the text and typed metadata are
retained, but native compaction coordinates are not fabricated. Old explicitly
historical carriers remain inert. Summary metadata must match the visible text.

Claude splits mixed messages at representable/archive boundaries. Ordinary
text and completed native tool pairs remain in conversation; unsupported
blocks and unfinished calls retain their exact payloads in separate inert
records. Call references, parent links, active selection, and compaction
coverage follow the split. Later conversions keep those archives inert.

Foreign reasoning becomes labeled assistant text in Claude. Opaque reasoning
and encrypted compaction payloads stay in record metadata, with a readable
availability label; they never populate Claude's `thinking.signature`. The
importer validates that the metadata matches the visible projection before
restoring the original block. An unchanged signed block from a physical native
Claude record can be forwarded; the converter does not cryptographically
validate provider signatures. This follows Claude's requirement to return its
own [thinking signatures unchanged](https://platform.claude.com/docs/en/build-with-claude/thinking#thinking-encryption).

Claude exports batch events, archived controls, and archived records into one
`agent-convert-provenance` header. Events retain their position and graph links
for re-import, while physical conversation parents bypass them. Consumed Codex
completion records also travel in this header. The JSON `inertByteShare` measures
UTF-8 provenance bytes (including per-record converter metadata) divided by total
output bytes; values above 0.10 produce a warning. Large provenance stays intact
in the artifact, so a warning does not imply that records were discarded.

Continuation exports require at least one native user text turn in the active
window. `--allow-empty-dialogue` permits deliberate tool-only archives and is
recorded as `allowEmptyDialogue` in `--json` output. The `loom` archive target is
exempt from this guard.

The IR and archive/carrier codecs distinguish native error flags, structured
status evidence, heuristic guesses, and unrecorded status. Legacy `inferred`
records decode as heuristic evidence; new records use `structured` or `heuristic`.
Continuation export refuses native failure flags contradicted by recorded
success. Nonzero inner command exits take precedence over outer-runner success.
A second publication guard rejects newly generated historical-tool prose for
otherwise native-eligible pairs. Cursor Agent has no native result channel; its
runtime preflight continues to refuse unsupported result-bearing imports.

## How each target represents history

| Target | Tool-history representation | Output / next step | Important limits |
| --- | --- | --- | --- |
| Claude Code | Native `tool_use` / `tool_result` for eligible pairs, with translated or exact source tool names | Omit output to install and print a resume command, or write a file | Canonical identity and exact error provenance travel in validated metadata. Only native or structured evidence can set the native error boolean. Encrypted or unsupported results use labeled native placeholders with exact source content in metadata. Duplicate or missing ids, incomplete pairs, invalid call shapes, and explicitly inert history can still use legacy carriers or refuse. |
| Codex CLI | Native `function_call` / `function_call_output`; compatible imported custom-tool records | JSONL file; register/install as a new Codex session to resume | Full error provenance is preserved in metadata. Text-result pairs are supported; ambiguous IDs, incomplete lifecycles, and unsupported content can still fall back or refuse. File generation alone is not a tested resume. |
| Pi | Native `toolCall` / tool-result messages for eligible history | JSONL file; load with Pi's session workflow | Canonical identity and error provenance travel in metadata. Flat selected conversation; target history mode and content constraints still apply. |
| Cursor Agent | Native `tool_use` where eligible; no native tool-result channel in the supported transcript schema | Transcript file only | Results and unsupported content may survive only as carriers, not native history. Local transcript-to-resume installation is not established by this exporter; historical validation recorded a negative result. |
| OpenCode | Assistant `tool` part combines a call with `pending`, `completed`, or `error` state | JSON file, then `opencode import <file>` | Flat output. Session-scoped, ordered IDs protect separately imported sessions and keep subsequent native turns at the tail; invalid explicit session IDs are refused. Result text blocks are joined; error provenance travels in metadata, while result block boundaries can still normalize. No fresh live-continuation claim is made here. |
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
