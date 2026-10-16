#!/usr/bin/env node
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const scratch = mkdtempSync(join(tmpdir(), 'loom-mixed-blocks-'));
const loom = resolve(process.env.LOOM_BIN || '.lake/build/bin/loom');
const source = resolve('testdata/claude/2.1.274/mixed-open-tool.jsonl');
const rows = text => text.trim().split('\n').map(JSON.parse);
let next = 0;
function save(data) {
  const path = join(scratch, `source-${next++}.jsonl`);
  writeFileSync(path, data.map(JSON.stringify).join('\n') + '\n');
  return path;
}
function convert(input, target = 'claude') {
  const output = join(scratch, `${next++}.${target}`);
  const result = spawnSync(loom, ['convert', input, target, output, '--no-subagents'], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr || result.stdout);
  const text = readFileSync(output, 'utf8');
  return { output, data: target === 'loom' ? JSON.parse(text) : rows(text) };
}
const blocks = records => records.flatMap(r => Array.isArray(r.message?.content) ? r.message.content : []);
const assistantText = records => records.filter(r => r.type === 'assistant')
  .flatMap(r => r.message.content.filter(b => b.type === 'text').map(b => b.text));
function checkHops(input, text, nativeIds = []) {
  let result = convert(input);
  for (let hop = 0; hop < 3; hop++) {
    assert.deepEqual(assistantText(result.data), text);
    const content = blocks(result.data);
    assert.deepEqual(content.filter(b => b.type === 'tool_use').map(b => b.id), nativeIds);
    assert.deepEqual(content.filter(b => b.type === 'tool_result').map(b => b.tool_use_id), nativeIds);
    assert.doesNotMatch(JSON.stringify(content), /Historical tool|agent-convert|OPAQUE-ONLY/);
    const restored = convert(result.output, 'loom').data;
    for (const entry of restored.entries) {
      for (const block of entry.payload.blocks || []) {
        if (block.type === 'toolCall' && !nativeIds.includes(block.id))
          assert.equal(entry.disposition, 'historicalUnverified');
      }
    }
    result = convert(result.output);
  }
  return result;
}
try {
  checkHops(source, ['The launch label is amber-pine.']);
  const piHeader = rows(readFileSync(resolve('testdata/pi/3/versioned-session.jsonl'), 'utf8'))[0];
  checkHops(save([piHeader,
    { type: 'message', id: 'user', parentId: null, timestamp: piHeader.timestamp,
      message: { role: 'user', timestamp: 1791590400000, content: 'Inspect the file.' } },
    { type: 'message', id: 'assistant', parentId: 'user', timestamp: piHeader.timestamp,
      message: { role: 'assistant', timestamp: 1791590400000,
        api: 'anthropic-messages', provider: 'anthropic', model: 'synthetic', stopReason: 'toolUse',
        usage: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2,
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
        content: [{ type: 'text', text: 'PI-TEXT' },
          { type: 'toolCall', id: 'pi-open', name: 'read', arguments: { path: '/tmp/file' } }] } },
  ]), ['PI-TEXT']);
  const fixture = rows(readFileSync(source, 'utf8'));
  const unknown = structuredClone(fixture);
  unknown[1].message.content = [{ type: 'text', text: 'BEFORE' },
    { type: 'future_widget', data: 'OPAQUE-ONLY' }, { type: 'text', text: 'AFTER' }];
  checkHops(save(unknown), ['BEFORE', 'AFTER']);
  const paired = structuredClone(fixture);
  paired[1].message.content = [{ type: 'text', text: 'BEFORE' },
    { type: 'tool_use', id: 'good-call', name: 'Read', input: { file_path: '/tmp/good' } },
    { type: 'future_widget', data: 'OPAQUE-ONLY' }, { type: 'text', text: 'AFTER' },
    { type: 'tool_use', id: 'toolu_open_read', name: 'Read', input: { file_path: '/tmp/open' } }];
  paired[2].message.content = [{ type: 'tool_result', tool_use_id: 'good-call', content: 'RECORDED-RESULT', is_error: false }];
  checkHops(save(paired), ['BEFORE', 'AFTER'], ['good-call']);
  // The native tool appears after an omitted run: its result must follow the
  // remapped entry/block coordinate, not the old physical position.
  paired[1].message.content.reverse();
  const reversed = checkHops(save(paired), ['AFTER', 'BEFORE'], ['good-call']);
  const restored = convert(reversed.output, 'loom').data;
  const result = restored.entries.flatMap(e => e.payload.blocks || []).find(b => b.type === 'toolResult');
  const callEntry = restored.entries.find(e => e.index === result.call.entry);
  assert.equal(callEntry.payload.blocks[Number(result.call.block)].id, 'good-call');
  // Exercise a multi-result IR entry: one native result must not disappear
  // merely because its neighbor's call has arguments Claude cannot express.
  const twoCalls = structuredClone(fixture);
  twoCalls[1].message.content = [{ type: 'text', text: 'BEFORE' },
    { type: 'tool_use', id: 'good-call', name: 'Read', input: { file_path: '/tmp/good' } },
    { type: 'tool_use', id: 'bad-call', name: 'Read', input: { file_path: '/tmp/bad' } },
    { type: 'text', text: 'AFTER' }];
  twoCalls[2].message.content = ['good-call', 'bad-call'].map(tool_use_id =>
    ({ type: 'tool_result', tool_use_id, content: `${tool_use_id} result`, is_error: false }));
  const archive = convert(save(twoCalls), 'loom').data;
  archive.entries[1].payload.blocks[2].arguments = ['unsupported array arguments'];
  archive.entries[2].payload.blocks.push(...archive.entries[3].payload.blocks);
  archive.entries.pop(); archive.activeLeaf = '2';
  const archivePath = join(scratch, 'multi-result.loom.json');
  writeFileSync(archivePath, JSON.stringify(archive));
  checkHops(archivePath, ['BEFORE', 'AFTER'], ['good-call']);
  console.log('Claude mixed blocks: text, completed calls, order and linkage remain native; open/unknown blocks remain inert across repeated hops.');
} finally { rmSync(scratch, { recursive: true, force: true }); }
