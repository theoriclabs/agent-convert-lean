# Cursor to Codex conversion

## API call-ID repair — 2026-09-08

The previous installed session failed both continuation and remote compaction:
its compound Cursor call IDs exceeded the API's 64-character maximum. Local
reader and round-trip checks had not detected this, and the earlier synthetic
live test had used short IDs.

Repaired from the failed Codex rollout, preserving its latest `hi` user turn:

```sh
cd /Users/harshwork/code/compute/docs
codex resume c9f594f3-db12-4202-ae8f-892f68fb6390
```

- Installed: `/Users/harshwork/.codex/sessions/2026/09/08/rollout-2026-09-08T20-30-42-c9f594f3-db12-4202-ae8f-892f68fb6390.jsonl`.
- Portable copy: `/private/tmp/google-docs-access-request-2.call-id-repaired.codex.jsonl`.
- All 193 native call/result pairs remain; the longest emitted call ID is 13
  characters. Arguments, output blocks, and result error metadata are unchanged.
- Original IDs are retained out of band and restored by Loom on re-import.
  Both earlier installed sessions and source archives remain untouched.
- Boundary/collision/round-trip tests pass. Actual Codex 0.153.4 synthetic
  continuation and remote-compaction tests pass with long source IDs, exact
  result recall, failure recognition, and zero new tool calls.
- After explicit user approval, a live test of the full private conversation
  passed using the released `v0.2.0-preview.3` binary and a separate session
  (`1c40992c-d13b-4b16-a5a7-bd81e84ba9f2`). Codex replied `RESUME-OK` with
  zero new tool calls. This turn did not trigger compaction; remote compaction
  is covered by the synthetic test above.
- Hash checks confirmed the original session, installed repair, and portable
  repair were unchanged. The installed repair contains no validation prompt
  or response. Private test receipts are in
  `/private/tmp/loom-real-call-id-probe-V6FbnC`.

## Repaired conversion — 2026-09-07

The reported #8/#9 defects are fixed locally, and a fresh extraction is
installed as a new Codex session. The earlier artifacts and installed session
below remain untouched.

```sh
codex resume 51e0f7d3-9105-4e7a-ae22-45c1119f7b32
```

- Source archive: `google-docs-access-request-2.recovered.cursor.loom.json`.
- Codex artifact: `google-docs-access-request-2.recovered.codex.jsonl`.
- Installed: `/Users/harshwork/.codex/sessions/2026/08/09/rollout-2026-08-09T23-39-21-51e0f7d3-9105-4e7a-ae22-45c1119f7b32.jsonl`.

All 17 previously unextracted results were retained in Cursor's
`toolFormerData.toolCallBinary`. Loom's recovered JSON matched Cursor's own
protobuf decoder for all 17, including the full grep output raised in the
report. The repaired conversion contains 193 native calls and 193 native
results, with zero historical-carrier messages in dialogue. Error provenance
now remains Cursor-native rather than being re-inferred from output text.

All 673 entry payloads and timestamps match on re-import after accounting for
the previously documented omission of 154 empty thinking signatures. Codex's
own `thread/read` accepts the new session as 44 turns and retains the screenshot
messages. A separate live synthetic continuation recalled the exact prior
tool result and understood a failed edit, with zero new tool calls. No model
turn was started on this private conversation.

`lake build loom LoomOps.Interop`, the synthetic native-history suite, and the
Codex/Claude audit self-test pass. The full requirements suite retains only
the same three pre-existing failures listed below. Full Cursor raw provenance
remains in the Loom archive; the target still reports source identity and
origin-provenance differences. Active-path scope is unchanged.

The older conversion notes below are historical and superseded by this section.

## Earlier conversion and diagnosis

Status correction, 2026-09-07: this artifact loads in Codex but does not meet
the clarified native-history fidelity requirement. Its 17 carrier calls include
14 completed/pruned calls, one other completed call, and two errors with no
retained result. The earlier open-call count describes the imported IR, not
their full source-recorded execution state. The prior round-trip check also
did not test native representation in resumed model context. See
`docs/bugs/native-tool-history.md` and `docs/plans/native-tool-history.md`.
No replacement artifact has been generated for this planned fix.

Result-recovery correction: "no retained result" above means no result in the
field Loom extracted, not that Cursor no longer retains it. The user reports
that the outputs exist elsewhere in Cursor history; their locations have not
yet been resolved. The acquisition bug is tracked separately in
`docs/bugs/cursor-result-recovery.md`. The existing Loom archive is an extraction
snapshot and is not established to contain the complete Cursor result history.

Converted `(2) Google Docs access request`, Cursor composer ID
`0407b91b-c02d-454e-a6fa-fd71c61b07b0`.

Source: `/Users/harshwork/Library/Application Support/Cursor/User/globalStorage/state.vscdb`.
The title and the messages about Jackson's book and the Wafer blog match the screenshot.
Working directory: `/Users/harshwork/code/compute/docs`.

Files:

- Original active conversation and raw Cursor provenance: `google-docs-access-request-2.cursor.loom.json`.
- Converted session: `google-docs-access-request-2.codex.jsonl`.
- Installed session: `/Users/harshwork/.codex/sessions/2026/08/09/rollout-2026-08-09T23-39-21-0407b91b-c02d-454e-a6fa-fd71c61b07b0.jsonl`.

Resume:

```sh
codex resume 0407b91b-c02d-454e-a6fa-fd71c61b07b0
```

No existing destination or Cursor source was overwritten. Project files referenced by the conversation were not copied or changed.

## Conversion and validation

The exporter now preserves empty user, assistant, and environment messages using its existing typed historical-entry representation. Regression checks cover standalone empty messages, consecutive empties, a final empty message, and empty messages around a tool exchange, including a second export/import cycle.

All 656 entries round-trip, including the previously blocked empty assistant message. Message content, entry order, timestamps, parent links, tool arguments, tool outputs, and tool references were checked against the source archive. Codex's own `thread/read` loaded the installed session as 44 turns and returned the screenshot's matching messages. No model turn was started.

The conversion follows the recorded active conversation. Off-path branches and separate subagent transcripts are not included. The archive retains the extracted Cursor branch metadata. Seventeen calls have no recorded results; they remain historical calls without synthetic outputs. The other 176 calls and results use Codex's native tool-history records.

The converter reports `dropSourceIdentity` and `dropOriginProvenance` as report-only differences. The Codex artifact does not retain every Cursor-specific identity/provenance field; the Loom archive retains those details. It omits 154 empty foreign thinking signatures while retaining the thinking text. For 176 results, the error boolean is unchanged, but its provenance becomes Codex-inferred instead of Cursor-native. The converter selected its default target model, `gpt-5.5`.

`lake build loom`, the new regression checks, the Codex/Claude audit self-test, and skill validation passed. The broader `lake build LoomRequirements` still fails three existing assertions: `environmentLossPolicyPinned`, `previewRequiredSuccessesPass`, and `previewRequiredRefusalsPass`. An untouched `HEAD` checkout reproduced exactly those three failures.

The installed `agent-session-converter` skill was simplified, and the requested refusal instruction was removed.
