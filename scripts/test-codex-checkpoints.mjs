#!/usr/bin/env node
// Synthetic checkpoints only; no source actions are executed.
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const root = fileURLToPath(new URL('../', import.meta.url));
const loom = resolve(process.env.LOOM_BIN || join(root, '.lake/build/bin/loom'));
const scratch = mkdtempSync(join(tmpdir(), 'loom-checkpoints-'));
const source = readFileSync(join(root, 'testdata/codex/0.162.1/compacted-rollout.jsonl'), 'utf8');
let sequence = 0;
function archive(rows) {
  const input = join(scratch, `source-${sequence}.jsonl`);
  const output = join(scratch, `archive-${sequence++}.json`);
  writeFileSync(input, rows.map(JSON.stringify).join('\n') + '\n');
  const run = spawnSync(loom, ['convert', input, 'loom', output, '--no-subagents'], { encoding: 'utf8' });
  assert.equal(run.status, 0, run.stderr);
  return JSON.parse(readFileSync(output, 'utf8'));
}
const malformedCount = t => t.importNotes.filter(n => n.kind === 'codex-malformed-compaction-record').length;
try {
  const rows = source.trim().split('\n').map(JSON.parse);
  const checkpoint = rows.find(r => r.type === 'compacted');
  const imported = archive(rows);
  assert.equal(malformedCount(imported), 0, 'unsigned 0.162 checkpoint must be accepted');
  assert.equal(imported.entries.filter(e => e.payload.type === 'compaction').length, 1);
  assert.deepEqual(imported.origin.extras.raw_compaction_records, [checkpoint]);

  for (const invalid of [null, [{}], [{ type: 'compaction', encrypted_content: '' }]]) {
    const changed = structuredClone(rows);
    changed.find(r => r.type === 'compacted').payload.replacement_history = invalid;
    assert.equal(malformedCount(archive(changed)), 1, 'malformed history must still be rejected');
  }
  console.log('Codex checkpoint archive: unsigned history accepted, exact provenance retained, malformed histories rejected.');
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
