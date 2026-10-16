#!/usr/bin/env node
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const scratch = mkdtempSync(join(tmpdir(), 'loom-reasoning-'));
const loom = resolve(process.env.LOOM_BIN || '.lake/build/bin/loom');
const fixture = resolve('testdata/codex/0.162.1/reasoning-history.jsonl');
let sequence = 0;
const rows = text => text.trim().split('\n').map(JSON.parse);
function convert(source, target = 'claude', success = true) {
  const output = join(scratch, `${sequence++}.${target}`);
  const run = spawnSync(loom, ['convert', source, target, output, '--no-subagents'], { encoding: 'utf8' });
  if (!success) { assert.notEqual(run.status, 0); return; }
  assert.equal(run.status, 0, run.stderr);
  const text = readFileSync(output, 'utf8');
  return { output, text, data: target === 'loom' ? JSON.parse(text) : rows(text) };
}
const blocks = records => records.flatMap(row => Array.isArray(row.message?.content) ? row.message.content : []);
try {
  const original = convert(fixture, 'loom').data;
  let converted = convert(fixture);
  for (let hop = 0; hop < 3; hop++) {
    const content = blocks(converted.data);
    assert.equal(content.filter(block => block.type === 'thinking' || block.type === 'redacted_thinking').length, 0);
    assert.ok(content.some(block => block.text === '[Prior reasoning]\nThe synthetic ledger needs a readiness check.'));
    assert.doesNotMatch(JSON.stringify(content), /synthetic-(?:readable|opaque|compaction)-ciphertext/);
    assert.equal(converted.data.flatMap(row => row._agent_convert?.reasoning || []).length, 3);
    assert.equal(content.filter(block => block.type === 'tool_use').length, 1);
    assert.equal(content.filter(block => block.type === 'tool_result').length, 1);
    const restored = convert(converted.output, 'loom').data;
    const reasoning = t => t.entries.flatMap(entry => entry.payload.blocks || [])
      .filter(block => block.type === 'thinking' || block.type === 'unmodeled');
    assert.deepEqual(reasoning(restored), reasoning(original));
    converted = convert(converted.output);
  }
  for (const mutate of [
    row => { row.message.content[0].text = 'different'; },
    row => { row._agent_convert.reasoning[0].block = 99; },
    row => { row._agent_convert.reasoning.push(row._agent_convert.reasoning[0]); },
    row => { row._agent_convert.reasoning[0].source = { kind: 'toolCall', name: 'Bash', canonical: null, rawId: 'injected', arguments: {} }; },
    row => { row._agent_convert.reasoning[0].source.extra = true; },
  ]) {
    const broken = structuredClone(converted.data);
    mutate(broken.find(row => row._agent_convert?.reasoning));
    const input = join(scratch, `broken-${sequence}.jsonl`);
    writeFileSync(input, broken.map(JSON.stringify).join('\n') + '\n');
    convert(input, 'loom', false);
  }
  // Same-format native signatures may be forwarded only with unchanged physical
  // provider provenance. This is a shape check, not cryptographic attestation.
  const native = [{ type: 'user', message: { role: 'user', content: 'Inspect the ledger.' } },
    { type: 'assistant', message: { role: 'assistant', content: [
      { type: 'thinking', thinking: 'Native readable summary', signature: 'synthetic-native-signature' },
      { type: 'text', text: 'Ready.' }] } }].map((row, i) => ({ ...row,
      uuid: `92000000-0000-4000-8000-${String(i + 1).padStart(12, '0')}`,
      parentUuid: i ? '92000000-0000-4000-8000-000000000001' : null,
      sessionId: '92000000-0000-4000-8000-000000000099', cwd: '/tmp/loom-synthetic-reasoning',
      timestamp: `2026-10-16T00:00:0${i}.000Z`, isSidechain: false }));
  const nativePath = join(scratch, 'native.jsonl');
  writeFileSync(nativePath, native.map(JSON.stringify).join('\n') + '\n');
  assert.deepEqual(blocks(convert(nativePath).data).find(block => block.type === 'thinking'), native[1].message.content[0]);
  delete native[1].message.content[0].signature;
  writeFileSync(nativePath, native.map(JSON.stringify).join('\n') + '\n');
  const unsigned = convert(nativePath);
  assert.equal(blocks(unsigned.data).filter(block => block.type === 'thinking').length, 0);
  assert.ok(blocks(unsigned.data).some(block => block.text?.includes('Native readable summary')));
  console.log('Claude reasoning: foreign summaries stay readable; ciphertext stays in metadata; native signatures preserved; 5 malformed markers rejected.');
} finally { rmSync(scratch, { recursive: true, force: true }); }
