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
