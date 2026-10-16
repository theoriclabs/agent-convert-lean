# Codex fixtures

The versioned directories contain synthetic rollouts, never private sessions.
They cover signed and unsigned checkpoints, optional window metadata, and the
0.162 retained-context shape. Acceptance of a checkpoint is separate from
correctly materializing every field in its active conversation.

`checkpoint-pins.lean` proves that the full and active importers agree on valid
checkpoints and their selected boundaries. `scripts/test-codex-checkpoints.mjs`
also checks native CLI artifacts and rejects malformed replacement histories
before a continuation artifact is written. Both run in local verification.

Window metadata is optional in the upstream checkpoint construction and migration
fixtures: see [session checkpoint construction](https://github.com/openai/codex/blob/main/codex-rs/core/src/session/mod.rs)
and [rollout migration tests](https://github.com/openai/codex/blob/main/codex-rs/thread-store/src/local/rollout_migration_tests.rs).
An explicitly empty history is distinct from a missing or malformed history.
Completed tool calls and results may also be present in replacement history;
the Claude exec-history regression covers that case.

`0.162.1/exec-status.jsonl` reproduces success output containing timeout/limit
text alongside a runner failure. `scripts/test-codex-exec-status.mjs` checks
native Claude result flags without executing any recorded command.

`0.162.1/notes-tool.jsonl` contains a synthetic namespaced notes call and an
encrypted result. `scripts/test-claude-notes-history.mjs` checks raw-name native
history and exact source-namespace metadata without executing source tools.

`0.162.1/reasoning-history.jsonl` includes readable and encrypted-only reasoning,
an opaque compaction response item, and a completed tool pair.
`scripts/test-claude-reasoning.mjs` checks that foreign signatures remain in
validated metadata across repeated conversions, while readable summaries stay
in conversation. Its optional live continuation uses the common probe script.

`0.162.1/item-completed.jsonl` covers exact user/assistant event mirrors and
structured command completions. `scripts/test-codex-item-completed.mjs` checks
deduplication, source-record retention, and conservative handling of unmatched,
cross-turn, and future event shapes. Command evidence attaches only to an
unambiguous enclosing `exec` call in the same recorded turn.
`scripts/test-claude-event-batch.mjs` checks the same fixture's three exact
completion records in one provenance header, event order and graph restoration,
malformed batches, appended native turns, and the provenance byte budget.

`scripts/check-codex-corpus.mjs` runs every version's compacted rollout through
both the archive and Claude continuation paths, with both subagent policies.
The latest fixture combines retained context, notes tools, opaque output,
exec status, and completion mirrors in twelve records. CI runs this corpus and
its negative mutations through `scripts/verify-local.sh`.
