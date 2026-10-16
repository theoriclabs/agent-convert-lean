#!/usr/bin/env node
// Synthetic checkpoints only; no source actions are executed.
import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const root = fileURLToPath(new URL('../', import.meta.url));
const loom = resolve(process.env.LOOM_BIN || join(root, '.lake/build/bin/loom'));
const scratch = mkdtempSync(join(tmpdir(), 'loom-checkpoints-'));
const source = readFileSync(join(root, 'testdata/codex/0.162.1/compacted-rollout.jsonl'), 'utf8');
let sequence = 0;
function convert(rows, target = 'loom', expectedStatus = 0) {
  const input = join(scratch, `source-${sequence}.jsonl`);
  const output = join(scratch, `archive-${sequence++}.json`);
  writeFileSync(input, rows.map(JSON.stringify).join('\n') + '\n');
  const run = spawnSync(loom, ['convert', input, target, output, '--no-subagents', '--json'], { encoding: 'utf8' });
  assert.equal(run.status, expectedStatus, run.stderr);
  if (expectedStatus !== 0) {
    assert.equal(existsSync(output), false, 'invalid checkpoint wrote an artifact');
    return;
  }
  return { artifact: target === 'loom' ? JSON.parse(readFileSync(output, 'utf8')) :
    readFileSync(output, 'utf8').trim().split('\n').map(JSON.parse),
    summary: JSON.parse(run.stdout.trim().split('\n').at(-1)) };
}
const archive = rows => convert(rows).artifact;
const malformedCount = t => t.importNotes.filter(n => n.kind === 'codex-malformed-compaction-record').length;
try {
  const rows = source.trim().split('\n').map(JSON.parse);
  const checkpoint = rows.find(r => r.type === 'compacted');
  const imported = archive(rows);
  assert.equal(malformedCount(imported), 0, 'unsigned 0.162 checkpoint must be accepted');
  assert.equal(imported.entries.filter(e => e.payload.type === 'compaction').length, 1);
  assert.deepEqual(imported.origin.extras.raw_compaction_records, [checkpoint]);
  assert.deepEqual(imported.origin.extras.retained_contexts, [checkpoint.payload.retained_context]);
  const retained = convert(rows, 'claude');
  const dialogue = retained.artifact.filter(r => ['user', 'assistant'].includes(r.type))
    .flatMap(r => (Array.isArray(r.message.content) ? r.message.content : [])
      .filter(b => b.type === 'text').map(b => b.text));
  assert.deepEqual(dialogue.slice(0, 3), [
    'RETAINED-USER Build the task viewer.',
    'RETAINED-ASSISTANT The task viewer renders correctly.',
    'RETAINED-USER Deploy only to the synthetic preview.',
  ]);
  assert.equal(dialogue.some(t => t.includes('OLD-PRECOMPACTION')), false);
  assert.deepEqual(retained.summary.retainedContexts, [checkpoint.payload.retained_context]);
  assert.equal(retained.summary.activeContextCompactionBoundaries[0].retainedMessageCount, 3);
  for (const mutate of [
    p => { p.retained_context.user_messages[0].order = 'first'; },
    p => { p.retained_context.user_messages[0].order = 2; },
    p => { p.retained_context.user_messages[0].message_id = 'msg_03'; },
    p => { delete p.retained_context.user_messages[0].text; },
    p => { p.retained_context.assistant_messages = null; },
  ]) {
    const changed = structuredClone(rows);
    mutate(changed.find(r => r.type === 'compacted').payload);
    assert.equal(malformedCount(archive(changed)), 1);
    convert(changed, 'claude', 2);
  }

  for (const invalid of [null, [{}], [{ type: 'compaction', encrypted_content: '' }]]) {
    const changed = structuredClone(rows);
    changed.find(r => r.type === 'compacted').payload.replacement_history = invalid;
    assert.equal(malformedCount(archive(changed)), 1, 'malformed history must still be rejected');
    convert(changed, 'claude', 2);
  }
  // The active path must reject shapes the archive labels malformed, including
  // objects which have a type but lack the semantic fields of that type.
  for (const invalid of [{ type: 'message', role: 'user' }, { type: 'compaction' }]) {
    const changed = structuredClone(rows);
    changed.find(r => r.type === 'compacted').payload.replacement_history = [invalid];
    assert.equal(malformedCount(archive(changed)), 1);
    convert(changed, 'claude', 2);
  }
  for (const version of ['0.144.1', '0.153.0', '0.162.1']) {
    const fixture = readFileSync(join(root, `testdata/codex/${version}/compacted-rollout.jsonl`), 'utf8')
      .trim().split('\n').map(JSON.parse);
    const full = convert(fixture);
    const active = convert(fixture, 'claude');
    assert.equal(malformedCount(full.artifact), 0, version);
    assert.equal(active.summary.importJudgments.filter(n => n.kind === 'codex-malformed-compaction-record').length, 0);
    assert.equal(full.summary.activeContext, false);
    assert.equal(full.summary.excludedSourceRecords, 0);
    assert.equal(active.summary.activeContext, true);
    assert.deepEqual(full.summary.activeContextCompactionBoundaries, active.summary.activeContextCompactionBoundaries);
    assert.equal(full.summary.activeContextCompactionBoundaries.length, 1);
  }
  console.log('Codex checkpoints: full/active agreement across 3 versions, exact provenance, malformed histories refused.');
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
