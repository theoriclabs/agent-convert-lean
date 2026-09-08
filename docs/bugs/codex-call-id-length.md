# Codex API rejects long imported tool-call IDs

Reported 2026-09-08. A converted Cursor conversation loaded in the Codex UI,
but both remote compaction and ordinary continuation returned HTTP 400:

```text
input[3].call_id: string too long. Expected maximum length 64; got length 80.
```

The native-history exporter copied source IDs without enforcing the API limit.
Cursor can record compound call identifiers longer than 64 characters. Local
rollout parsing and Loom round trips accepted them; the live synthetic fixture
used short IDs and therefore did not reproduce the real conversion's failure.
This was a converter validation gap, unrelated to MCP authentication warnings.

The fix allocates unique short wire IDs, reserves existing IDs to avoid
collisions, and writes the same alias on each call and its recorded result.
Original IDs remain in `_agent_convert_call_id` metadata, not dialogue. The
importer restores source identities; repeated exports are stable. Checked
export also verifies that no native response item exposes an overlong ID.
Already-converted rollouts can be repaired by exporting them to a new Codex file.

Verification:

- `node scripts/test-codex-call-ids.mjs`: 63/64/65/80-character boundaries,
  compound and Unicode IDs, same-prefix IDs, existing alias collisions,
  unchanged arguments/results, original-ID restoration, and old-rollout repair.
- `node scripts/probe-codex-native-history.mjs --run`: opt-in actual Codex
  continuation using long source IDs, exact prior-result recall, failure
  recognition, and zero new tool calls.
- Add `--compact` to establish token usage with one no-tool turn, then trigger
  automatic remote compaction before the second turn. The test asserts that a
  compaction record was actually written; setting a threshold alone is not evidence.

The build, artifact regressions, normal live continuation, and forced remote
compaction probe passed with Codex CLI 0.153.4 on 2026-09-08. Live tests use
synthetic data, not a user's private conversation.

No original session should be overwritten during repair. Keep the current
rollout, including any turns added since conversion, as the repair source.
