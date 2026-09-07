# agent-convert-lean — working directives

## Continue the conversation with native tool history

Follow [INTENT.md](./INTENT.md). Prior source tool executions belong in the
destination's native conversation history. They must not become assistant
disclaimers or carrier JSON, and importing them must not rerun them. Preserve
execution status independently of result availability: completed/pruned is
not an unknown or pending call. Test what the resumed model receives, not only
what Loom can decode or the target UI can open.

The 2026-09-07 Cursor-to-Codex recurrence is documented in
[the bug report](./docs/bugs/native-tool-history.md) and
[implementation notes](./docs/cursor-tool-binary.md). The reported path is fixed;
existing carrier tests are historical behavior checks, not the desired product outcome.

Maintain [the conversion matrix](./docs/conversion-matrix.md) when source/target
support or fidelity changes. Run `node scripts/check-conversion-matrix.mjs`
for routing drift; distinguish artifact checks from actual harness continuation.

## Codex → continuation targets resume the active context. This must never regress.

On 2026-09-04 a Codex 0.153 session (ten compactions, 56 MB rollout) converted
to Claude Code produced a 52 MB session that Claude Code could not open: it
compacted for minutes, then answered `Prompt is too long`. The transcript
showed thousands of `[Historical tool call …]` carriers because the *entire
pre-compaction history* had been exported.

Cause: `runConvert` chose the active-context import (`importCodexCliActive`)
only on its no-subagents branch. Claude targets default subagent stitching on,
so every Codex → Claude conversion fell through to the full-history import.
A second, silent drift made it worse: the compacted-record validator was a key
whitelist pinned to Codex 0.144.1, so all ten real checkpoints were demoted to
`codex-malformed-compaction-record` and nothing typed marked where the
resumable context began.

Invariants, pinned by compile-time `example`s (`decide` / `native_decide`) in
`LoomConvert/Main.lean` and `LoomConvert/CodexCli.lean`. Keep them, extend
them, never weaken them:

1. `codexImportMode`: every continuation target (`claude`, `pi`, `codex`,
   `cursor-agent`, `opencode`) imports the context Codex itself would resume —
   the latest compaction's `replacement_history` plus everything after it.
   Only the `loom` archive target imports the full stream. This is a property
   of the target alone. It must never depend on subagent policy or any other
   CLI flag.
2. `importSourceText` is the single import entry point for `runConvert`. Both
   the subagent and the no-subagent branch call it. Do not add a third path.
3. `preCompactionHistoryBlocker?` runs in `runConvert` before export and
   refuses (exit 3) any transcript whose source recorded compactions but whose
   import was not active-context, for every target except `loom`. This is the
   last line of defence and fires even if 1 or 2 are broken again.
4. The Codex compacted-record domain is OPEN-WORLD for unknown keys. Codex adds
   bookkeeping fields every few releases (`ordinal`, `compaction_response_id`,
   `guardian_history`, `latest_token_usage_record`, metadata
   `content_item_kinds` / `create_time`). Only the semantic shape is strict.
   Never reintroduce a key whitelist there.
5. `codexCompactedRolloutConvertsActive` (Main.lean) and
   `codexCurrentCompactionCheckpointAccepted` (CodexCli.lean) are the
   regression pins for this exact bug. If either must change, the bug is back.

When touching the Codex importer, `runConvert`, or the Claude exporter, verify
against a real compacted rollout before finishing:

```sh
loom convert <rollout.jsonl> loom /tmp/a.loom.json   # zero codex-malformed-compaction-record notes
loom convert <rollout.jsonl> claude /tmp/a.jsonl     # entry count ≈ active window, NOT ≈ rollout records
loom convert <rollout.jsonl> claude ~/.claude/projects/<proj>/<uuid>.jsonl --target-session-id <uuid>
cd <project> && claude -p --resume <uuid> "Reply RESUME-OK"   # then delete the throwaway file
```

A converted Claude session whose size is a large fraction of the rollout, or
whose entry count tracks the rollout's record count, is this bug returning.

## Known pre-existing failures (not caused by the above)

As of 2026-09-04 `lake build LoomRequirements` fails on the baseline in three
`native_decide` proofs: `environmentLossPolicyPinned`,
`previewRequiredSuccessesPass`, and `previewRequiredRefusalsPass` (the
`claude-refuses-wrong-target-reader-version` row expects
`target_harness_version must be '2.1.216'`). `lake build loom` is green.
