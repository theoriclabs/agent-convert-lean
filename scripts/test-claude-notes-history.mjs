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
  writeFileSync(input, Array.isArray(rows) ? rows.map(JSON.stringify).join('\n') + '\n' : JSON.stringify(rows));
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
  const resultContent = archive => archive.entries.flatMap(e => e.payload.blocks || [])
    .find(b => b.type === 'toolResult').content;
  for (const mixed of [false, true]) {
    const source = structuredClone(fixture);
    if (mixed) source[3].payload.output = [
      { type: 'input_text', text: 'Before opaque content.' }, ...source[3].payload.output,
      { type: 'input_text', text: 'After opaque content.' },
    ];
    const output = convert(source);
    const blocks = output.flatMap(r => r.message?.content || []);
    assert.equal(blocks.filter(b => b.type === 'tool_use').length, 1);
    const result = blocks.find(b => b.type === 'tool_result');
    assert.equal(result.is_error, false);
    assert.match(result.content[mixed ? 1 : 0].text, /^\[output not retained as readable text: encrypted_content\]/);
    assert.equal(JSON.stringify(blocks).includes('synthetic-encrypted-notes-output'), false);
    assert.equal(JSON.stringify(blocks).includes('[Historical tool'), false);
    const row = output.find(r => r.message?.content?.includes(result));
    assert.deepEqual(row._agent_convert.unavailableOutput, [{ block: 0, contentIndex: mixed ? 1 : 0,
      source: { kind: 'unmodeled', label: 'encrypted_content', raw: fixture[3].payload.output[0] } }]);
    assert.deepEqual(resultContent(convert(output, 'loom')), resultContent(convert(source, 'loom')));
    const repeated = convert(output);
    assert.deepEqual(resultContent(convert(repeated, 'loom')), resultContent(convert(source, 'loom')));
    for (const mutate of [
      row => { row.message.content[0].content[mixed ? 1 : 0].text = 'invented output'; },
      row => { row._agent_convert.unavailableOutput[0].contentIndex = 99; },
      row => { row._agent_convert.unavailableOutput.push(row._agent_convert.unavailableOutput[0]); },
    ]) {
      const changed = structuredClone(output);
      mutate(changed.find(r => r._agent_convert?.unavailableOutput));
      const input = join(scratch, `invalid-${sequence++}.jsonl`);
      writeFileSync(input, changed.map(JSON.stringify).join('\n') + '\n');
      const run = spawnSync(loom, ['convert', input, 'loom', input + '.loom'], { encoding: 'utf8' });
      assert.equal(run.status, 2);
      assert.match(run.stderr, /unavailableOutput/);
    }
  }
  const mediaSource = convert(fixture, 'loom');
  const media = { type: 'media', mimeType: 'application/pdf', data: 'https://example.invalid/old.pdf' };
  resultContent(mediaSource).splice(0, 1, media);
  const mediaOutput = convert(mediaSource);
  assert.deepEqual(resultContent(convert(mediaOutput, 'loom')), [media]);
  console.log('Claude notes history: raw names, namespaces, native call/result pairs, and repeated-hop provenance passed.');
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
