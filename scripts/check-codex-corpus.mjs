#!/usr/bin/env node
// Synthetic fixtures only. No harness credentials or recorded command execution.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const root = fileURLToPath(new URL('../', import.meta.url));
const loom = resolve(process.env.LOOM_BIN || join(root, '.lake/build/bin/loom'));
const scratch = mkdtempSync(join(tmpdir(), 'loom-codex-corpus-'));
const versions = readdirSync(join(root, 'testdata/codex'), { withFileTypes: true })
  .filter(entry => entry.isDirectory() && /^\d+\.\d+\.\d+/.test(entry.name)).map(entry => entry.name).sort();
const hash = text => createHash('sha256').update(text).digest('hex');
const rows = text => text.trim().split('\n').map(JSON.parse);
const conversation = records => records.filter(record => ['user', 'assistant'].includes(record.type));
const blocks = records => conversation(records).flatMap(record => record.message?.content || []);
const visible = records => blocks(records).filter(block => block.type === 'text').map(block => block.text);
function assertContinuation(source, summary, artifact, text) {
  const checkpointIndex = source.findLastIndex(record => record.type === 'compacted');
  assert.ok(checkpointIndex > 0, 'fixture must include a checkpoint');
  const checkpoint = source[checkpointIndex].payload;
  assert.equal(summary.activeContext, true, 'continuation did not use active context');
  assert.equal(summary.importJudgments.filter(note => note.kind === 'codex-malformed-compaction-record').length, 0);
  assert.equal(summary.activeContextCompactionBoundaries.length, 1);
  // recordIndex is zero-based after session_meta; source ordinal is separate.
  assert.equal(summary.activeContextCompactionBoundaries[0].recordIndex, checkpointIndex - 1);
  const retained = (checkpoint.retained_context?.user_messages?.length || 0) +
    (checkpoint.retained_context?.assistant_messages?.length || 0);
  const upperBound = checkpoint.replacement_history.length + retained + source.length - checkpointIndex - 1;
  assert.ok(summary.messagesWritten <= upperBound, `active output ${summary.messagesWritten} exceeds ${upperBound}`);
  assert.ok(conversation(artifact).some(record => record.type === 'user' &&
    record.message.content.some(block => block.type === 'text' && block.text.trim() && !block.text.startsWith('[Historical'))),
  'no dialogue user turn in target conversation');
  assert.ok(visible(artifact).every(text => !text.includes('OLD-PRECOMPACTION')), 'pre-compaction dialogue leaked');
  assert.doesNotMatch(text, /\[Historical tool (?:call|result)/, 'native history became carrier prose');
  for (const block of blocks(artifact).filter(block => block.type === 'tool_result')) {
    const readable = typeof block.content === 'string' ? block.content :
      block.content.filter(item => item.type === 'text').map(item => item.text).join('\n');
    // These fixtures seed successful outer and inner commands. The separate
    // error corpus covers successful runners with legitimately failed commands.
    if (readable.startsWith('Script completed')) assert.equal(block.is_error, false, 'successful exec became an error');
  }
  assert.equal(artifact.filter(record => record.subtype === 'agent_convert_inert').length, 0);
  let previous = null;
  for (const record of conversation(artifact)) {
    assert.equal(record.parentUuid, previous, 'physical conversation parent bypass failed');
    previous = record.uuid;
  }
  assert.equal(artifact.at(-1).leafUuid, previous);
}
const report = { schema: 'agent-convert.codex-corpus.v1', versions: [], mutationChecks: 0 };
try {
  assert.deepEqual(versions.filter(version => ['0.144.1', '0.153.0', '0.162.1'].includes(version)),
    ['0.144.1', '0.153.0', '0.162.1']);
  for (const [index, version] of versions.entries()) {
    const relative = `testdata/codex/${version}/compacted-rollout.jsonl`;
    const input = join(root, relative), sourceText = readFileSync(input, 'utf8'), source = rows(sourceText);
    assert.ok(source.length <= 20, `${relative}: keep the regression fixture small`);
    assert.equal(source[0].payload.cli_version, version);
    const convert = (target, withSubagents = false) => {
      const output = join(scratch, `${version}-${target}-${withSubagents}.json`);
      const argv = ['convert', input, target, output, '--json', '--target-session-id',
        `90000000-0000-4000-8000-${String(index + 27).padStart(12, '0')}`];
      if (!withSubagents) argv.push('--no-subagents');
      const run = spawnSync(loom, argv, { encoding: 'utf8' });
      assert.equal(run.status, 0, `${relative} → ${target}: ${run.stderr}`);
      const text = readFileSync(output, 'utf8');
      return { text, artifact: target === 'loom' ? JSON.parse(text) : rows(text),
        summary: JSON.parse(run.stdout.trim().split('\n').at(-1)) };
    };
    const full = convert('loom');
    assert.equal(full.summary.activeContext, false);
    assert.equal(full.summary.importJudgments.filter(note => note.kind === 'codex-malformed-compaction-record').length, 0);
    assert.ok(full.artifact.entries.some(entry => JSON.stringify(entry.payload).includes('OLD-PRECOMPACTION')));
    const checkpoint = source.findLast(record => record.type === 'compacted');
    assert.deepEqual(full.artifact.origin.extras.raw_compaction_records, [checkpoint]);
    assert.deepEqual(full.artifact.origin.extras.active_context_compaction_boundaries[0].boundary_record, checkpoint);
    const active = convert('claude');
    assertContinuation(source, active.summary, active.artifact, active.text);
    const defaultSubagents = convert('claude', true);
    assertContinuation(source, defaultSubagents.summary, defaultSubagents.artifact, defaultSubagents.text);
    assert.deepEqual(conversation(defaultSubagents.artifact), conversation(active.artifact));
    assert.deepEqual(full.summary.activeContextCompactionBoundaries, active.summary.activeContextCompactionBoundaries);
    if (version === '0.162.1') {
      assert.equal(blocks(active.artifact).filter(block => block.type === 'tool_use').length, 2);
      assert.equal(blocks(active.artifact).filter(block => block.type === 'tool_result').length, 2);
      assert.ok(active.artifact.some(record => record._agent_convert?.toolTranslation?.some(call => call.sourceNamespace === 'notes')));
      assert.ok(active.artifact.some(record => record._agent_convert?.unavailableOutput?.length === 1));
      const header = active.artifact.find(record => record.type === 'agent-convert-provenance');
      assert.equal(header._agent_convert.eventBatch.events.length, 2);
      assert.ok(header._agent_convert.eventBatch.events.some(event => event.record.payload.item.type === 'CommandExecution'));
    }
    for (const mutate of [
      sample => { sample.summary.activeContext = false; },
      sample => { sample.summary.activeContextCompactionBoundaries[0].recordIndex++; },
      sample => { sample.summary.messagesWritten = 999; },
      sample => { sample.artifact = sample.artifact.filter(record => record.type !== 'user' ||
        !record.message.content.some(block => block.type === 'text')); },
      sample => { sample.text += '[Historical tool call'; },
      sample => { conversation(sample.artifact)[0].message.content.push({ type: 'text', text: 'OLD-PRECOMPACTION leaked' }); },
      sample => {
        const result = blocks(sample.artifact).find(block => block.type === 'tool_result');
        result.content = [{ type: 'text', text: 'Script completed\nOutput:\nSuccessful output.' }]; result.is_error = true;
      },
    ]) {
      const broken = structuredClone(active); mutate(broken);
      assert.throws(() => assertContinuation(source, broken.summary, broken.artifact, broken.text));
      report.mutationChecks++;
    }
    assert.equal(hash(readFileSync(input, 'utf8')), hash(sourceText), 'conversion modified the fixture');
    report.versions.push({ version, fixture: relative, sha256: hash(sourceText), sourceRecords: source.length,
      checkpointRecordIndex: active.summary.activeContextCompactionBoundaries[0].recordIndex,
      checkpointOrdinal: checkpoint.ordinal ?? null, activeMessages: active.summary.messagesWritten,
      nativeToolPairs: blocks(active.artifact).filter(block => block.type === 'tool_use').length,
      defaultSubagentsPass: true });
  }
  const outputIndex = process.argv.indexOf('--report');
  if (outputIndex !== -1) {
    assert.ok(process.argv[outputIndex + 1], '--report requires a path');
    const path = resolve(process.argv[outputIndex + 1]);
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, JSON.stringify(report, null, 2) + '\n');
  }
  console.log(`Codex corpus: ${report.versions.length} versions, both subagent policies, native continuation shape; ${report.mutationChecks} mutations rejected.`);
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
