#!/usr/bin/env node
// Recorded synthetic outputs only. Never execute commands from the fixture.
import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const root = fileURLToPath(new URL('../', import.meta.url));
const loom = resolve(process.env.LOOM_BIN || join(root, '.lake/build/bin/loom'));
const scratch = mkdtempSync(join(tmpdir(), 'loom-exec-status-'));
const fixture = readFileSync(join(root, 'testdata/codex/0.162.1/exec-status.jsonl'), 'utf8')
  .trim().split('\n').map(JSON.parse);
let sequence = 0;
function convert(rows, target = 'claude', raw = false) {
  const input = join(scratch, `source-${sequence}.jsonl`);
  const output = join(scratch, `claude-${sequence++}.jsonl`);
  writeFileSync(input, Array.isArray(rows) ? rows.map(JSON.stringify).join('\n') + '\n' : JSON.stringify(rows));
  const run = spawnSync(loom, ['convert', input, target, output, '--no-subagents'], { encoding: 'utf8' });
  assert.equal(run.status, 0, run.stderr);
  if (target === 'loom' || target === 'opencode') return JSON.parse(readFileSync(output, 'utf8'));
  const records = readFileSync(output, 'utf8').trim().split('\n').map(JSON.parse);
  if (raw) return records;
  return records
    .flatMap(r => Array.isArray(r.message?.content) ? r.message.content : [])
    .filter(b => b.type === 'tool_result');
}
try {
  const results = convert(fixture);
  assert.equal(results.find(r => r.tool_use_id === 'call_ok').is_error, false);
  assert.equal(results.find(r => r.tool_use_id === 'call_fail').is_error, true);
  for (const output of [
    'Script completed\nWall time 0.2 seconds\nOutput:\nCommand timed out after 30 seconds',
    'Process exited with code 0\nFinal output:\nProcess exited with code 9',
    'Process exited with code 0\nFinal output:\nSet timeout to 30; the limit was exceeded.',
    'The manual says: timeout expired; command timed out after 30 seconds.',
  ]) {
    const rows = structuredClone(fixture);
    rows.find(r => r.payload?.call_id === 'call_ok' && r.payload?.type === 'custom_tool_call_output')
      .payload.output = [{ type: 'input_text', text: output }];
    assert.equal(convert(rows).find(r => r.tool_use_id === 'call_ok').is_error, false, output);
  }
  for (const [output, expected] of [
    ['Process exited with code 7\nFinal output:\nfailed command',
      { kind: 'structured', isError: 'true', source: 'codex.runner.process_exit_code' }],
    ['Command timed out after 30 seconds',
      { kind: 'heuristic', isError: 'true', method: 'codexOutputIndicatesError (codexAdapter.ts:75)' }],
  ]) {
    const rows = structuredClone(fixture);
    rows.find(r => r.payload?.call_id === 'call_ok' && r.payload?.type === 'custom_tool_call_output')
      .payload.output = [{ type: 'input_text', text: output }];
    const archive = convert(rows, 'loom');
    const errors = archive.entries.flatMap(e => e.payload.blocks || [])
      .filter(b => b.type === 'toolResult').map(b => b.error);
    assert.deepEqual(errors[0], expected);
  }
  const signal = rows => convert(rows, 'loom').entries.flatMap(e => e.payload.blocks || [])
    .find(b => b.type === 'toolResult').error;
  for (const [chunks, expected] of [
    [['Script completed\nOutput:\n', '{"exit_code":9,"output":"bad"}'],
      { kind: 'structured', isError: 'true', source: 'codex.runner.chunk.exit_code' }],
    [['Script completed\nOutput:\n', '{"output":"quoted {\\"exit_code\\":9}"}'],
      { kind: 'structured', isError: 'false', source: 'codex.runner.status' }],
    [['Script failed\nOutput:\nfailed', '{"exit_code":0}'],
      { kind: 'structured', isError: 'true', source: 'codex.runner.status' }],
  ]) {
    const rows = structuredClone(fixture);
    rows[3].payload.output = chunks.map(text => ({ type: 'input_text', text }));
    assert.deepEqual(signal(rows), expected);
  }
  const commandEvent = turn => ({ type: 'event_msg', payload: {
    type: 'item_completed', turn_id: turn, item: { type: 'CommandExecution',
      id: 'inner-command', status: 'failed', exit_code: 12, command: ['false'],
      aggregated_output: 'recorded failure', duration: { secs: 0, nanos: 1 } },
  } });
  const rows = structuredClone(fixture);
  rows.splice(2, 0, { type: 'turn_context', payload: { turn_id: 'turn-one' } });
  rows.splice(4, 0, commandEvent('turn-one'));
  assert.deepEqual(signal(rows), { kind: 'structured', isError: 'true',
    source: 'codex.item_completed.CommandExecution.exit_code' });
  const resultEntry = convert(rows, 'loom').entries.find(e =>
    e.payload.blocks?.some(b => b.type === 'toolResult'));
  assert.deepEqual(resultEntry.origin.extras.codex_command_completions, [commandEvent('turn-one')]);
  for (const mutation of [
    rs => { rs[4].payload.turn_id = 'different-turn'; },
    rs => { rs[3].payload.name = 'unrelated_custom_tool'; },
    rs => { rs.splice(4, 0, { type: 'response_item', payload: {
      type: 'custom_tool_call', call_id: 'overlapping', name: 'exec', input: 'print(1)' } }); },
    rs => { rs.splice(2, 1); },
  ]) {
    const ambiguous = structuredClone(rows);
    mutation(ambiguous);
    assert.deepEqual(signal(ambiguous), { kind: 'structured', isError: 'false',
      source: 'codex.runner.chunk.exit_code' });
  }
  for (const [text, expectedFlag, expectedKind] of [
    ['Command timed out after 30 seconds', false, 'heuristic'],
    ['Script failed\nOutput:\nerror', true, 'structured'],
    ['Script completed\nOutput:\nok', false, 'structured'],
  ]) {
    const source = structuredClone(fixture);
    source[3].payload.output = [{ type: 'input_text', text }];
    const exported = convert(source, 'claude', true);
    const result = exported.find(r => r.message?.content?.some(b => b.tool_use_id === 'call_ok'));
    assert.equal(result.message.content[0].is_error, expectedFlag);
    assert.equal(result._agent_convert.toolResultErrors[0].errorSignal.kind, expectedKind);
    assert.deepEqual(signal(exported), signal(source), 'original error provenance survives Claude round trip');
    const invalid = structuredClone(exported);
    invalid.find(r => r.message?.content?.some(b => b.tool_use_id === 'call_ok'))
      .message.content[0].is_error = !expectedFlag;
    const input = join(scratch, `invalid-${sequence++}.jsonl`);
    writeFileSync(input, invalid.map(JSON.stringify).join('\n') + '\n');
    const rejected = spawnSync(loom, ['convert', input, 'loom', input + '.loom'], { encoding: 'utf8' });
    assert.equal(rejected.status, 2);
    assert.match(rejected.stderr, /contradicts the emitted native error flag/);
  }
  const contradictory = convert(fixture, 'loom');
  const contradicted = contradictory.entries.flatMap(e => e.payload.blocks || [])
    .find(b => b.type === 'toolResult');
  contradicted.error = { kind: 'native', isError: 'true' };
  const badInput = join(scratch, 'contradictory.loom.json');
  writeFileSync(badInput, JSON.stringify(contradictory));
  for (const target of ['claude', 'pi', 'codex', 'cursor-agent', 'opencode']) {
    const output = join(scratch, `contradictory-${target}`);
    const rejected = spawnSync(loom, ['convert', badInput, target, output, '--no-subagents'], { encoding: 'utf8' });
    assert.equal(rejected.status, 3, `${target}: ${rejected.stderr}`);
    assert.match(rejected.stderr, /contradictory error flag at entry .*call_ok/);
    assert.equal(existsSync(output), false);
  }
  assert.deepEqual(convert(contradictory, 'loom').entries, contradictory.entries, 'archive remains exempt');
  const guessed = structuredClone(fixture);
  guessed[3].payload.output = [{ type: 'input_text', text: 'Command timed out after 30 seconds' }];
  const pi = convert(guessed, 'pi', true);
  assert.equal(pi.find(r => r.message?.role === 'toolResult').message.isError, false);
  assert.deepEqual(signal(pi), signal(guessed));
  const opencode = convert(guessed, 'opencode');
  assert.equal(opencode.messages.flatMap(m => m.parts).find(p => p.callID === 'call_ok').state.status, 'completed');
  assert.deepEqual(signal(opencode), signal(guessed));
  console.log('Codex error headers: successful printed content cannot set a native error flag.');
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
