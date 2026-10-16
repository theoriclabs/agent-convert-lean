#!/usr/bin/env node
// Synthetic recorded history only; none of these tools is executed.
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const root = fileURLToPath(new URL('../', import.meta.url));
const loom = resolve(process.env.LOOM_BIN || join(root, '.lake/build/bin/loom'));
const scratch = mkdtempSync(join(tmpdir(), 'loom-notes-history-'));
const fixture = readFileSync(join(root, 'testdata/codex/0.162.1/notes-tool.jsonl'), 'utf8')
  .trim().split('\n').map(JSON.parse);
let sequence = 0;
function convert(rows, target = 'claude') {
  const input = join(scratch, `source-${sequence}.jsonl`);
  const output = join(scratch, `target-${sequence++}.jsonl`);
  writeFileSync(input, rows.map(JSON.stringify).join('\n') + '\n');
  const run = spawnSync(loom, ['convert', input, target, output, '--no-subagents'], { encoding: 'utf8' });
  assert.equal(run.status, 0, run.stderr);
  const text = readFileSync(output, 'utf8');
  return target === 'loom' ? JSON.parse(text) : text.trim().split('\n').map(JSON.parse);
}
try {
  for (const [name, namespace] of [
    ['read_file', 'notes'], ['append_to_file', 'notes'], ['write_file', 'notes'],
    ['list_items', 'history'], ['read_item', 'history'], ['new_context', 'functions'],
    ['search_contents', 'notes'],
  ]) {
    const rows = structuredClone(fixture);
    rows[2].payload.name = name;
    rows[2].payload.namespace = namespace;
    rows[3].payload.output = [{ type: 'input_text', text: 'Previously recorded notes output.' }];
    const output = convert(rows);
    const callRow = output.find(r => r.message?.content?.some(b => b.type === 'tool_use'));
    const call = callRow.message.content.find(b => b.type === 'tool_use');
    assert.deepEqual(call, { type: 'tool_use', id: 'call_notes', name, input: { path: 'priority' } });
    assert.deepEqual(callRow._agent_convert.toolTranslation, [{ block: 0, sourceFormat: 'codex',
      sourceName: name, sourceNamespace: namespace, sourceInput: { path: 'priority' } }]);
    const results = output.flatMap(r => r.message?.content || []).filter(b => b.type === 'tool_result');
    assert.equal(results.length, 1);
    assert.equal(results[0].tool_use_id, call.id);
    assert.equal(JSON.stringify(output).includes('[Historical tool'), false);
    const repeated = convert(output);
    const repeatedCall = repeated.find(r => r.message?.content?.some(b => b.type === 'tool_use'));
    assert.deepEqual(repeatedCall._agent_convert.toolTranslation, callRow._agent_convert.toolTranslation);
  }
  console.log('Claude notes history: raw names, namespaces, native call/result pairs, and repeated-hop provenance passed.');
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
