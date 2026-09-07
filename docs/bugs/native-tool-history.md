# [P1] Completed Cursor tool calls with pruned outputs become assistant carrier prose in Codex

## Resolution

Implemented and verified in this change. #9 recovers the
retained output, allowing the affected completed calls to become native Codex
call/result pairs. A second exporter defect was the error-text heuristic:
recorded errors whose output did not match it also became prose. Complete
error provenance now travels in metadata beside native output instead.
Empty-message bookkeeping no longer adds converter dialogue.

The live synthetic Codex continuation recalled a prior result, understood a
recorded failure, and made zero new tool calls. See the
[implementation and validation notes](../cursor-tool-binary.md).

No unavailable-output placeholder was needed or introduced. The original
proposal below also discusses genuinely unavailable output and other targets;
those broader cases are not claimed resolved by this scoped fix.

Status: reported path fixed; broader follow-up scope is listed separately below.

Filed as [GitHub issue #8](https://github.com/theoriclabs/agent-convert-lean/issues/8).

Required companion work: [Cursor result recovery, #9](https://github.com/theoriclabs/agent-convert-lean/issues/9).
A missing inline result is not proof that Cursor no longer retains the output;
placeholder-based export does not resolve that acquisition defect.

## Problem

Cursor-to-Codex conversion emits an assistant text message headed
`[Historical tool call from source transcript; not executed by Codex]`, followed
by `agent-convert.codex-tool-call.v2` JSON. The destination receives commentary
about a tool instead of the native tool history it should continue from.

This violates the native-by-default and provenance-out-of-band principles
already stated in `LoomOps/Interop.lean`. A successful self-round-trip and a
successful Codex `thread/read` do not establish semantic fidelity to the model.

## Reproduction

Use a synthetic Cursor IDE input with a user message, this assistant bubble,
and a following assistant response, all listed in `fullConversationHeadersOnly`:

```json
{
  "_v": 3,
  "type": 2,
  "bubbleId": "search-completed-pruned",
  "toolFormerData": {
    "tool": 41,
    "name": "ripgrep_raw_search",
    "toolCallId": "source-search-1",
    "rawArgs": {"path": "/tmp/example.yaml", "pattern": "example"},
    "status": "completed",
    "additionalData": {"isPruned": true, "totalFiles": 1, "totalMatches": 5}
  }
}
```

Convert that input with `loom convert <input.json> codex <new-output.jsonl>`.
Supply a source workspace path and timestamps in the fixture as needed.

Actual: the call becomes visible assistant prose; the imported IR represents
it as an open call even though the retained raw source says completed.

Expected: first recover the complete recorded output from Cursor's history;
absence from `toolFormerData.result` alone does not establish unavailability.
The target receives native prior tool activity with its recorded state and
output. An unavailable-output condition is appropriate only after the checked
source retrieval paths establish that limitation. No tool is rerun, no old
output is invented, and no converter carrier text appears as assistant dialogue.

## Cause

`LoomConvert/CursorIde.lean` retains terminal status in raw provenance but
classifies a terminal call without a result as open. The typed call/result
projection cannot distinguish pruned completed output from an unfinished call.

`LoomConvert/CodexCli.lean` then requires `nativeCallHasExactResult` inside
`nativeCallRecordAt?`. With no result, it falls through
`assistantStandaloneRecord?` to `historicalToolCallText`. The importer retaining
raw data and the exporter recovering the carrier make internal checks pass
while the target-visible meaning is degraded.

This is not solely an unknown-tool-name problem: the exporter can synthesize
foreign native calls, but separately requires an exact result. Related: issue
#4 addresses Claude's whole-entry carrier fallback around open calls.

## Acceptance criteria and proposed fix

1. Preserve typed execution status separately from output availability, including
   completed/pruned, error without output, interrupted, pending, and unknown.
2. Resolve the separate Cursor result-recovery defect before classifying output
   as unavailable. Preserve retained summaries as summaries, not substitutes
   for the original output. A missing inline field is an extraction gap until
   the source retrieval paths have been investigated.
3. Emit native target history, adapting call IDs and required result records
   according to measured target constraints. Preserve mappings and unavailable
   output provenance outside dialogue. Never relabel an unknown call successful.
4. Remove the exact-result prerequisite as a blanket reason to demote a call
   to prose. Plan a valid complete lifecycle for each target instead.
5. Verify target model context and rendering, absence of converter prose,
   accurate state, correct links, and no replay of old tools. Include repeated
   cross-harness round trips and a controlled continuation probe.
6. Keep archive preservation, native history fidelity, and real continuation
   results separate in diagnostics. A readable carrier is not full fidelity.

The fix should cover the shared policy and all advertised targets, starting
with Cursor IDE to Codex. Parser/own-import tests alone are insufficient.
