#!/usr/bin/env node
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const root = fileURLToPath(new URL('../', import.meta.url));
const loom = resolve(process.env.LOOM_BIN || join(root, '.lake/build/bin/loom'));
const scratch = mkdtempSync(join(tmpdir(), 'loom-event-batch-'));
const fixture = readFileSync(join(root, 'testdata/codex/0.162.1/item-completed.jsonl'), 'utf8')
  .trim().split('\n').map(JSON.parse);
let serial = 0;
function convert(source, target = 'claude', expected = 0) {
  const input = join(scratch, `source-${serial}.jsonl`);
  const output = join(scratch, `target-${serial++}.jsonl`);
  writeFileSync(input, Array.isArray(source) ? source.map(JSON.stringify).join('\n') + '\n' : JSON.stringify(source));
  const run = spawnSync(loom, ['convert', input, target, output, '--no-subagents', '--json'], { encoding: 'utf8' });
  assert.equal(run.status, expected, run.stderr);
  if (expected) return run;
  const text = readFileSync(output, 'utf8');
  return { text, value: target === 'loom' ? JSON.parse(text) : text.trim().split('\n').map(JSON.parse),
    summary: JSON.parse(run.stdout.trim().split('\n').at(-1)), stderr: run.stderr };
}
const header = rows => rows.find(r => r.type === 'agent-convert-provenance');
const batch = rows => header(rows)._agent_convert.eventBatch;
const conversation = rows => rows.filter(r => r.uuid);
function verifyPhysical(rows) {
  assert.equal(rows.filter(r => r.type === 'agent-convert-provenance').length, 1);
  assert.equal(rows.filter(r => r.subtype === 'agent_convert_inert').length, 0);
  let parent = null;
  for (const row of conversation(rows)) {
    assert.ok(['user', 'assistant'].includes(row.type));
    assert.equal(row.parentUuid, parent);
    parent = row.uuid;
  }
  assert.equal(rows.at(-1).leafUuid, parent);
}
function measuredShare(text) {
  const bytes = text.trimEnd().split('\n').reduce((total, line) => {
    const row = JSON.parse(line);
    return total + (row.type === 'agent-convert-provenance' ||
      (row.type === 'system' && row.subtype?.startsWith('agent_convert_'))
      ? Buffer.byteLength(line) + 1 : row._agent_convert ? Buffer.byteLength(JSON.stringify(row._agent_convert)) : 0);
  }, 0);
  return bytes / Buffer.byteLength(text);
}
try {
  const first = convert(fixture);
  verifyPhysical(first.value);
  assert.equal(batch(first.value).events.length, 3);
  assert.deepEqual(batch(first.value).events.map(e => e.record), [fixture[2], fixture[4], fixture[7]]);
  assert.deepEqual(batch(first.value).events.map(e => e.beforeEntry), [0, 2, 3]);
  assert.ok(Math.abs(first.summary.inertByteShare - measuredShare(first.text)) < 1e-6);
  assert.ok(first.summary.inertByteShare > 0.1);
  assert.match(first.stderr, /inert\/provenance bytes exceed 10%/);
  const archive = convert(first.value, 'loom').value;
  assert.equal(archive.entries.length, 4);
  assert.deepEqual(archive.entries[0].origin.extras.codex_item_completed.map(e => e.record), [fixture[2]]);
  assert.deepEqual(archive.entries[2].origin.extras.codex_command_completions, [fixture[4]]);
  assert.deepEqual(archive.entries[2].origin.extras.codex_command_completion_indices, [3]);
  const twice = convert(first.value);
  verifyPhysical(twice.value);
  assert.deepEqual(batch(twice.value).events.map(e => e.record), batch(first.value).events.map(e => e.record));

  const event = label => ({ type: 'event_msg', payload: { type: 'future_bookkeeping', label, exact: ['raw', 42] } });
  const interleaved = [fixture[0], event('before'), ...fixture.slice(1, 3), event('middle'), ...fixture.slice(3), event('after')];
  const sourceArchive = convert(interleaved, 'loom').value;
  const output = convert(interleaved);
  verifyPhysical(output.value);
  assert.equal(batch(output.value).events.filter(e => e.kind === 'entry').length, 3);
  const restored = convert(output.value, 'loom').value;
  const expectedPayloads = sourceArchive.entries.map(e => structuredClone(e.payload));
  expectedPayloads[3].blocks = [{ type: 'toolCall', id: 'call_ls', name: 'Bash', canonical: 'bash', arguments: { command: 'ls' } }];
  assert.deepEqual(restored.entries.map(e => e.payload), expectedPayloads);
  assert.deepEqual(conversation(output.value)[1]._agent_convert.toolTranslation[0].sourceInput,
    { input: 'text(await tools.exec_command({cmd:"ls"}));' });
  assert.equal(restored.activeLeaf, sourceArchive.activeLeaf);
  assert.deepEqual(restored.entries.map(e => e.parent ?? null), sourceArchive.entries.map(e => e.parent ?? null));
  assert.equal(convert(output.value).text, output.text, 'event batching must be stable on a same-target hop');

  // A later native turn takes precedence over the old batch's selected event.
  const appended = structuredClone(output.value);
  const pointer = appended.pop();
  const last = conversation(appended).at(-1);
  const next = { ...last, uuid: '90000000-0000-4000-8000-000000000025', parentUuid: last.uuid,
    type: 'user', message: { role: 'user', content: [{ type: 'text', text: 'A new native turn.' }] } };
  delete next._agent_convert;
  appended.push(next, { ...pointer, leafUuid: next.uuid });
  const appendedArchive = convert(appended, 'loom').value;
  assert.equal(appendedArchive.entries.length, sourceArchive.entries.length + 1);
  assert.deepEqual(appendedArchive.entries.slice(0, -1).map(e => e.payload), expectedPayloads);
  assert.deepEqual(appendedArchive.entries.at(-1).payload,
    { type: 'userMsg', blocks: [{ type: 'text', text: 'A new native turn.' }] });

  for (const mutate of [
    rows => { batch(rows).events.find(e => e.kind === 'entry').beforeEntry = 999; },
    rows => { batch(rows).events.push(structuredClone(batch(rows).events.find(e => e.kind === 'entry'))); },
    rows => { batch(rows).events.find(e => e.kind === 'entry').record._agent_convert.inertPayload.payload =
      { kind: 'userMsg', blocks: [{ kind: 'text', text: 'Injected dialogue' }] }; },
    rows => { batch(rows).parentLinks[0].parentUuid = '90000000-0000-4000-8000-000000000099'; },
    rows => { batch(rows).events.find(e => e.kind === 'annotation').entryUuid = 'missing'; },
    rows => { batch(rows).leaf.eventUuid = 'missing'; },
    rows => { batch(rows).leaf.physicalUuid = conversation(rows)[0].uuid; },
  ]) {
    const bad = structuredClone(output.value); mutate(bad);
    assert.match(convert(bad, 'loom', 2).stderr, /malformed Claude event batch/);
  }
  const largeDialogue = structuredClone(fixture);
  largeDialogue[1].payload.content[0].text = 'Visible Unicode conversation. 雪 '.repeat(6000);
  largeDialogue[2].payload.item.content[0].text = largeDialogue[1].payload.content[0].text;
  // Remove the large duplicate annotation to isolate the byte budget's low side.
  largeDialogue.splice(2, 1);
  const smallShare = convert(largeDialogue);
  assert.ok(smallShare.summary.inertByteShare <= 0.1);
  assert.doesNotMatch(smallShare.stderr, /inert\/provenance bytes exceed 10%/);
  assert.ok(Math.abs(smallShare.summary.inertByteShare - measuredShare(smallShare.text)) < 1e-6);
  console.log('Claude event batch: one header, exact event order/provenance, native graph, mutations, and byte budget passed.');
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
