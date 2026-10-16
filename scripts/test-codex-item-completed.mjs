#!/usr/bin/env node
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const root = fileURLToPath(new URL('../', import.meta.url));
const loom = resolve(process.env.LOOM_BIN || join(root, '.lake/build/bin/loom'));
const scratch = mkdtempSync(join(tmpdir(), 'loom-item-completed-'));
const fixture = readFileSync(join(root, 'testdata/codex/0.162.1/item-completed.jsonl'), 'utf8')
  .trim().split('\n').map(JSON.parse);
let sequence = 0;
function convert(rows, target = 'loom') {
  const input = join(scratch, `source-${sequence}.jsonl`);
  const output = join(scratch, `target-${sequence++}.jsonl`);
  writeFileSync(input, rows.map(JSON.stringify).join('\n') + '\n');
  const run = spawnSync(loom, ['convert', input, target, output, '--no-subagents'], { encoding: 'utf8' });
  assert.equal(run.status, 0, run.stderr);
  const text = readFileSync(output, 'utf8');
  return target === 'loom' ? JSON.parse(text) : text.trim().split('\n').map(JSON.parse);
}
const standalone = t => t.entries.filter(e => e.payload.event?.label === 'codex.event_msg.item_completed');
const attachments = t => t.entries.flatMap(e => e.origin.extras?.codex_item_completed || []).map(v => v.record);
try {
  const t = convert(fixture);
  assert.equal(t.entries.length, 4);
  assert.equal(standalone(t).length, 0);
  assert.deepEqual(attachments(t), [fixture[2], fixture[7]]);
  const result = t.entries.find(e => e.payload.blocks?.some(b => b.type === 'toolResult'));
  assert.deepEqual(result.origin.extras.codex_command_completions, [fixture[4]]);
  assert.deepEqual(result.origin.extras.codex_command_completion_indices, [3]);
  assert.equal(t.importNotes.filter(n => n.kind === 'dedupDropped').length, 2);
  assert.equal(t.importNotes.filter(n => n.kind === 'codex-command-completion-consumed').length, 1);
  const reversed = structuredClone(fixture);
  [reversed[1], reversed[2]] = [reversed[2], reversed[1]];
  assert.equal(standalone(convert(reversed)).length, 0);
  const mismatched = structuredClone(fixture);
  mismatched[2].payload.item.content[0].text = 'A different recorded user request.';
  assert.equal(standalone(convert(mismatched)).length, 1, 'unequal text is not deduplicated');
  const otherTurn = structuredClone(fixture);
  otherTurn[1].payload.internal_chat_message_metadata_passthrough = { turn_id: 'another-turn' };
  assert.equal(standalone(convert(otherTurn)).length, 1, 'different recorded turns are not deduplicated');
  const reasoning = [
    { type: 'response_item', payload: { type: 'reasoning', summary: [{ type: 'summary_text', text: 'Recorded summary.' }] } },
    { type: 'event_msg', payload: { type: 'item_completed', item: {
      id: 'reasoning-one', type: 'Reasoning', summary_text: ['Recorded summary.'], raw_content: [],
    } } },
  ];
  const withReasoning = convert([...fixture, ...reasoning]);
  assert.equal(standalone(withReasoning).length, 0);
  assert.deepEqual(attachments(withReasoning).at(-1), reasoning[1]);
  for (const rawContent of [['Additional recorded reasoning.'], 'malformed future shape']) {
    const distinct = structuredClone(reasoning);
    distinct[1].payload.item.raw_content = rawContent;
    assert.equal(standalone(convert([...fixture, ...distinct])).length, 1);
  }
  const uncorrelated = structuredClone(fixture);
  uncorrelated[4].payload.turn_id = 'another-turn';
  assert.equal(standalone(convert(uncorrelated)).length, 1, 'uncorrelated command events remain explicit');
  for (const kind of ['ContextCompaction', 'FileChange', 'McpToolCall', 'Extension', 'ImageView']) {
    const event = { type: 'event_msg', payload: { type: 'item_completed', item: { type: kind, id: 'extra', exact: [1, 'raw'] } } };
    const source = structuredClone(fixture);
    source.splice(6, 0, event);
    const archive = convert(source);
    assert.equal(standalone(archive).length, 0);
    assert.deepEqual(attachments(archive).find(raw => raw.payload?.item?.type === kind), event);
  }
  const future = { type: 'event_msg', payload: { type: 'item_completed', item: { type: 'FutureConversation', text: 'Must survive.' } } };
  assert.equal(standalone(convert([...fixture, future])).length, 1);
  const claude = convert(fixture, 'claude');
  assert.equal(claude.filter(r => r.type === 'system' && r.subtype === 'agent_convert_inert').length, 0);
  console.log('Codex item_completed: exact mirrors, command evidence, raw neighbors, and unmatched/future events passed.');
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
