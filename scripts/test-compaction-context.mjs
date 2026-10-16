#!/usr/bin/env node
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const scratch = mkdtempSync(join(tmpdir(), 'loom-compaction-'));
const loom = resolve(process.env.LOOM_BIN || '.lake/build/bin/loom');
const fixture = resolve('testdata/claude/2.1.274/compaction-summary.jsonl');
const essential = 'ESSENTIAL-SUMMARY: The chosen database is PostgreSQL. The migration codename is violet-river.';
const parse = text => text.trim().split('\n').map(JSON.parse);
let sequence = 0;
function convert(source, target, success = true) {
  const output = join(scratch, `${sequence++}.${target}`);
  const run = spawnSync(loom, ['convert', source, target, output, '--no-subagents', '--json'], { encoding: 'utf8' });
  if (!success) { assert.notEqual(run.status, 0); return; }
  assert.equal(run.status, 0, run.stderr || run.stdout);
  const text = readFileSync(output, 'utf8');
  return { output, data: target === 'loom' ? JSON.parse(text) : parse(text), report: JSON.parse(run.stdout.trim().split('\n').at(-1)) };
}
function save(rows) {
  const file = join(scratch, `${sequence++}.jsonl`);
  writeFileSync(file, rows.map(JSON.stringify).join('\n') + '\n');
  return file;
}
const compactions = t => t.entries.filter(e => e.payload.type === 'compaction');
try {
  const source = convert(fixture, 'loom').data;
  assert.equal(compactions(source).length, 1);
  assert.doesNotMatch(JSON.stringify(source.entries.map(e => e.payload)), /OLD-CONTEXT/);
  let claude = convert(fixture, 'claude');
  for (let hop = 0; hop < 3; hop++) {
    const boundary = claude.data.find(r => r.subtype === 'compact_boundary');
    const summary = claude.data.find(r => r.isCompactSummary);
    assert.ok(boundary && summary);
    assert.equal(summary.parentUuid, boundary.uuid);
    assert.equal(summary.message.content, essential);
    assert.equal(claude.data.filter(r => r.subtype === 'agent_convert_compaction').length, 0);
    const restored = convert(claude.output, 'loom').data;
    assert.deepEqual(compactions(restored).map(e => e.payload), compactions(source).map(e => e.payload));
    assert.equal(compactions(restored)[0].disposition || 'native', 'native');
    claude = convert(claude.output, 'claude');
  }
  let pi = convert(fixture, 'pi');
  for (let hop = 0; hop < 3; hop++) {
    const summary = pi.data.find(r => r.customType === 'loom.pi.compaction-summary');
    assert.equal(summary.type, 'custom_message');
    assert.equal(summary.content, `[Conversation summary]\n${essential}`);
    const restored = convert(pi.output, 'loom').data;
    assert.deepEqual(compactions(restored).map(e => e.payload), compactions(source).map(e => e.payload));
    assert.equal(compactions(restored)[0].disposition || 'native', 'native');
    pi = convert(pi.output, 'pi');
  }
  const cross = convert(pi.output, 'claude');
  assert.ok(cross.data.some(r => r.message?.content === `[Conversation summary]\n${essential}`));
  assert.equal(cross.data.filter(r => r.isCompactSummary).length, 0);
  assert.match(JSON.stringify(cross.report), /projectCompactionSummary/);
  assert.deepEqual(compactions(convert(cross.output, 'loom').data).map(e => e.payload),
    compactions(source).map(e => e.payload));
  const forged = structuredClone(cross.data);
  const context = forged.find(r => r._agent_convert?.contextSummary);
  context._agent_convert.contextSummary.sourceBoundary = claude.data.find(r => r.subtype === 'compact_boundary');
  context._agent_convert.contextSummary.sourceEnvelope = claude.data.find(r => r.isCompactSummary);
  const stillContext = convert(save(forged), 'claude');
  assert.equal(stillContext.data.filter(r => r.subtype === 'compact_boundary' || r.isCompactSummary).length, 0);
  assert.ok(stillContext.data.some(r => r.message?.content === `[Conversation summary]\n${essential}`));
  // An already-native Pi checkpoint retains its real coverage and token count.
  const nativePi = [pi.data[0],
    { type: 'message', id: 'kept', parentId: null, timestamp: '2026-10-16T00:00:00.000Z',
      message: { role: 'user', content: 'Retained context.', timestamp: 1792108800000 } },
    { type: 'compaction', id: 'summary', parentId: 'kept', timestamp: '2026-10-16T00:00:01.000Z',
      summary: essential, firstKeptEntryId: 'kept', tokensBefore: 1000 }];
  const native = convert(save(nativePi), 'pi');
  assert.ok(native.data.some(r => r.type === 'compaction' && r.summary === essential && r.firstKeptEntryId === 'kept'));
  const crossNative = convert(native.output, 'claude');
  assert.ok(crossNative.data.some(r => r.message?.content === `[Conversation summary]\n${essential}`));
  assert.deepEqual(compactions(convert(crossNative.output, 'loom').data).map(e => e.payload),
    compactions(convert(native.output, 'loom').data).map(e => e.payload));
  for (const [data, target, mutate] of [
    [pi.data, 'pi', rows => { rows.find(r => r.customType === 'loom.pi.compaction-summary').content = 'mismatch'; }],
    [cross.data, 'claude', rows => { rows.find(r => r._agent_convert?.contextSummary).message.content = 'mismatch'; }],
    [claude.data, 'claude', rows => { rows.find(r => r._agent_convert?.contextSummary)._agent_convert.contextSummary.summary = 'mismatch'; }],
  ]) {
    const broken = structuredClone(data); mutate(broken); convert(save(broken), target, false);
  }
  // Opt-in independent consumer verification; no network/model call here.
  const piRoot = process.env.PI_PACKAGE_ROOT;
  if (piRoot) {
    assert.ok(existsSync(join(piRoot, 'dist/core/session-manager.js')));
    const { buildSessionContext } = await import(pathToFileURL(join(piRoot, 'dist/core/session-manager.js')));
    const { convertToLlm } = await import(pathToFileURL(join(piRoot, 'dist/core/messages.js')));
    for (const converted of [pi, native]) {
      const context = convertToLlm(buildSessionContext(converted.data.slice(1)).messages);
      const text = JSON.stringify(context);
      assert.ok(text.includes(essential));
      assert.doesNotMatch(text, /OLD-CONTEXT/);
    }
    console.log('Installed Pi reader: both native and projected summaries are in active LLM input.');
  }
  console.log('Compaction context: Claude native restoration, Pi fallback, same/cross-format repeated hops, exact coverage, and malformed-summary rejection passed.');
} finally { rmSync(scratch, { recursive: true, force: true }); }
