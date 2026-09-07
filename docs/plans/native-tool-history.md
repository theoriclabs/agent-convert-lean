# Native tool-history fix plan

Status: the reported Cursor-to-Codex path is implemented and verified.
Product intent: `../../INTENT.md`.

## Implementation outcome

The investigation found retained results in Cursor's `toolCallBinary`; no
missing-output workaround or shared-IR lifecycle extension was needed to repair
the reported history. Supported binary results now enter the ordinary typed
call/result path. Native Codex results preserve full error provenance in
metadata even when the output-text heuristic disagrees, and empty-message
bookkeeping no longer creates dialogue.

Regression and real continuation checks passed. Re-extraction and a new
destination session preserve the original source and prior conversion. See
[implementation notes](../cursor-tool-binary.md) for checks and limitations.

The original investigation plan follows. Its proposals for genuinely missing
output, duplicate target IDs, shared execution-state modeling, and all-target
policy changes remain broader follow-up work, not claims about this fix.

Tracking: [GitHub issue #8](https://github.com/theoriclabs/agent-convert-lean/issues/8).

## 0. Recover Cursor results before designing a missing-output fallback

- Track acquisition separately in `../bugs/cursor-result-recovery.md` and
  [GitHub issue #9](https://github.com/theoriclabs/agent-convert-lean/issues/9).
  The current absence is from Loom's extracted inline result field, not established
  absence from Cursor history. Treat the result location as unresolved.
- Trace Cursor's own history/result retrieval paths and correlate alternate
  records or serialized payloads by call occurrence, request, bubble, composer,
  and branch. Capture a sanitized fixture of the actual discovered layout.
- Verify recovered output against an independent source view. Summaries and
  counts do not substitute for full output; current tool execution cannot
  reconstruct a historical result.
- This is required for repairing the affected conversion. An unavailable-output
  placeholder does not close the acquisition bug. Reserve that fallback for a
  documented limitation of the inspected source after recovery work.

## 1. Capture the failure and target behavior

- Add a small synthetic Cursor fixture with a completed search and pruned
  output, plus adjacent dialogue. Add variants with recorded output, a retained
  summary only, error without output, interrupted/pending/unknown status,
  duplicate/missing IDs, newline-containing IDs, and a final call.
- Reproduce the current native/prose counts and missing-output classification.
  Keep private session contents out of public fixtures and issue attachments.
- Probe the current Codex history reader and resumed model-input builder using
  native foreign-name calls, terminal calls without results, and explicit
  unavailable-output results. Establish actual acceptance and replay behavior;
  distinguish historical parsing from the registry used for new calls.
- Inspect Cursor's available result locations, pruned-output metadata, and
  optional retained stores. Only source-recorded evidence can recover output.

## 2. Represent execution and output independently

- Extend the shared lifecycle model with recorded execution state and output
  availability. Keep absent results distinct from source-recorded empty output,
  pruned output, interruption, errors, and unknown state.
- Have the Cursor importer populate these facts from the raw status and result
  metadata. Decide the exact shared representation after surveying the other
  adapters; do not overload error booleans or historical disposition.
- Update Loom wire serialization compatibly: older archives whose typed state
  is absent remain unknown unless retained source evidence supports recovery.
  Preserve raw source status and source identity out of band.

## 3. Plan native target history

- Replace the blanket `nativeCallHasExactResult` eligibility gate with a
  per-target lifecycle plan. The plan accounts for native call records, source
  results, known completion, and target-required closure independently.
- Preserve arbitrary source names/arguments when the target accepts them as
  historical records. If the target requires a different schema or ID, use a
  deterministic semantic translation with an out-of-band original/mapping.
  Do not infer call/result links from duplicate raw IDs when occurrence data
  resolves them; minting a target ID must not invent a source identity.
- Prefer recovered exact output. Only after acquisition establishes that it is
  unavailable in the inspected source, if the target requires
  a result, emit a minimal unavailable-output record in the native tool-result
  channel. Carry completion/error/unknown state and placeholder provenance
  explicitly. Do not manufacture successful output or current filesystem reads.
- Move converter carrier payloads into ignored envelope fields or sidecars.
  Retain legacy carrier decoding for existing archives, recovering execution
  semantics only from available source facts. Generic metadata and empty
  message handling must also avoid visible converter assistant messages.
- Keep ordinary conversation, tool results, and source-injected controls in
  their correct channels. Native historical records must not trigger execution.

## 4. Align all targets and diagnostics

- Audit Codex, Claude, Pi, Cursor Agent, and OpenCode eligibility/fallback paths
  for the same completion/result/provenance conflation. Use the strongest
  representation each target supports; disclose actual format limitations.
- Update counters to distinguish native calls, recorded results, unavailable
  output placeholders, known completed calls, unresolved calls, and true
  approximations. Preserve source execution/error provenance without presenting
  converter bookkeeping to the model.
- Revise tests and release expectations that currently accept prose carriers
  as full tool-history fidelity. Keep independent no-replay checks: they should
  test the absence of new execution, not the absence of native call records.

## 5. Verify the intended behavior

- Assert target-native record types, roles, links, execution state, available
  output bytes, and zero carrier prose for representable histories.
- Test the target's actual resumed model context, not only `thread/read` or a
  Loom round trip. Use a controlled synthetic conversation whose next question
  depends on a prior tool result; require correct recall without another call.
- For pruned results, require recognition of completed prior work and missing
  output. For unknown/interrupted calls, require that the model not infer
  success. Monitor tool events or a sandbox sentinel to verify no old actions
  are replayed during load/resume.
- Check source → target → source and repeated hops for non-accumulating loss,
  including original IDs, execution/error provenance, and active compaction
  context. Update related Lean regressions and run relevant lifecycle audits.

## 6. Repair the user's conversion

- Re-extract from Cursor with the result-recovery fix; the earlier Loom archive
  may itself be incomplete and must not be the sole source for this repair.
  Reconvert the recovered source into a new artifact, then
  inspect native/model-visible history and reconcile the known 193-call census.
- Before installing, check whether the previously installed Codex thread gained
  new turns. Preserve any appended work. Use a new session ID when appropriate;
  never replace the now-active session without reconciling its additions.
- Report content/state preservation, remaining target limitations, and the
  exact resume command. Do not equate successful loading with full fidelity.

The runtime/importer/exporter changes and repaired conversion described above
supersede the earlier planning-only status.
