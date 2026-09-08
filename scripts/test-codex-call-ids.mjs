#!/usr/bin/env node
// Synthetic fixtures; no private transcripts or live requests.
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';

const scratch = mkdtempSync(join(tmpdir(), 'loom-call-ids-'));
const loom = resolve(process.env.LOOM_BIN || '.lake/build/bin/loom');
const ids = ['loom_call_0', 'loom_call_1', 'a'.repeat(63), 'b'.repeat(64),
  'c'.repeat(65), 'd'.repeat(80), 'd'.repeat(79) + 'e',
  'call-' + 'f'.repeat(60) + '\n' + 'g'.repeat(16), 'λ'.repeat(65), 'x'.repeat(1000)];
const timestamp = '2026-09-08T12:00:00Z';
const source = { composer: { composerId: '10000000-0000-4000-8000-000000000064',
  workspaceIdentifier: { uri: { fsPath: scratch } } }, bubbles: [
  { bubbleId: 'user', type: 1, text: 'Inspect the synthetic markers.', createdAt: timestamp },
  ...ids.map((id, i) => ({ bubbleId: `tool-${i}`, type: 2, createdAt: timestamp,
    toolFormerData: { tool: 41, name: 'ripgrep_raw_search', toolCallId: id,
      status: 'completed', rawArgs: { pattern: `marker-${i}` }, result: `result-${i}` } })),
] };
let sequence = 0;
function convert(text, target) {
  const input = join(scratch, `input-${sequence++}`), output = join(scratch, `output-${sequence++}`);
  writeFileSync(input, text);
  const run = spawnSync(loom, ['convert', input, target, output], { encoding: 'utf8' });
  assert.equal(run.status, 0, run.stderr || run.stdout);
  return readFileSync(output, 'utf8');
}
const first = convert(JSON.stringify(source), 'codex');
const rows = first.trim().split('\n').map(JSON.parse);
const calls = rows.filter(r => r.payload?.type === 'function_call');
const results = rows.filter(r => r.payload?.type === 'function_call_output');
assert.equal(calls.length, ids.length); assert.equal(results.length, ids.length);
assert.equal(new Set(calls.map(r => r.payload.call_id)).size, ids.length);
for (let i = 0; i < ids.length; i++) {
  const call = calls[i], result = results[i], wireId = call.payload.call_id;
  assert.ok([...wireId].length <= 64);
  assert.equal(result.payload.call_id, wireId);
  assert.equal(call.payload.arguments, JSON.stringify({ pattern: `marker-${i}` }));
  assert.equal(result.payload.output, `result-${i}`);
  if ([...ids[i]].length <= 64) assert.equal(wireId, ids[i]);
  else {
    assert.equal(call._agent_convert_call_id.source, ids[i]);
    assert.equal(call._agent_convert_call_id.target, wireId);
    assert.deepEqual(result._agent_convert_call_id, call._agent_convert_call_id);
  }
}
assert.ok(!rows.some(r => r.payload?.type === 'message' &&
  JSON.stringify(r.payload.content).includes('[Historical tool')));
const archive = JSON.parse(convert(first, 'loom'));
const restoredIds = archive.entries.flatMap(e => e.payload.blocks || [])
  .filter(b => b.type === 'toolCall').map(b => b.id);
assert.deepEqual(restoredIds, ids, 'Original identities must round-trip through metadata');
assert.equal(convert(first, 'codex'), first, 'Same-format repair/export must be stable');

// Reproduce an already-installed old conversion: retain long wire IDs but remove
// mapping metadata. A fresh same-format export must repair it, not replay it.
const old = rows.map(r => {
  if (!r._agent_convert_call_id) return r;
  const { _agent_convert_call_id: mapping, ...rest } = r;
  return { ...rest, payload: { ...rest.payload, call_id: mapping.source } };
}).map(JSON.stringify).join('\n') + '\n';
const repaired = convert(old, 'codex');
const repairedCalls = repaired.trim().split('\n').map(JSON.parse)
  .filter(r => r.payload?.type === 'function_call');
assert.deepEqual(repairedCalls.map(r => r.payload.call_id), calls.map(r => r.payload.call_id));
assert.equal(convert(repaired, 'codex'), repaired);
const tampered = rows.map(r => r._agent_convert_call_id ? {
  ...r, _agent_convert_call_id: { ...r._agent_convert_call_id, target: 'wrong-binding' },
} : r).map(JSON.stringify).join('\n') + '\n';
const invalidInput = join(scratch, 'invalid-map.jsonl');
writeFileSync(invalidInput, tampered);
const invalid = spawnSync(loom, ['convert', invalidInput, 'loom', join(scratch, 'invalid.json')],
  { encoding: 'utf8' });
assert.notEqual(invalid.status, 0, 'A mismatched mapping must not silently rewrite identities');
assert.match(invalid.stderr, /call ID mapping/);
console.log(JSON.stringify({ check: 'codex-call-id-boundaries', passed: true,
  cases: ids.length, collisionsAvoided: true, originalIdsRestored: true,
  oldRolloutRepair: true, artifacts: scratch }));
