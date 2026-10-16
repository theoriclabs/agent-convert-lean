#!/usr/bin/env node
// Recorded synthetic outputs only. Never execute commands from the fixture.
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
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
function convert(rows) {
  const input = join(scratch, `source-${sequence}.jsonl`);
  const output = join(scratch, `claude-${sequence++}.jsonl`);
  writeFileSync(input, rows.map(JSON.stringify).join('\n') + '\n');
  const run = spawnSync(loom, ['convert', input, 'claude', output, '--no-subagents'], { encoding: 'utf8' });
  assert.equal(run.status, 0, run.stderr);
  return readFileSync(output, 'utf8').trim().split('\n').map(JSON.parse)
    .flatMap(r => Array.isArray(r.message?.content) ? r.message.content : [])
    .filter(b => b.type === 'tool_result');
}
try {
  const results = convert(fixture);
  assert.equal(results.find(r => r.tool_use_id === 'call_ok').is_error, false);
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
  console.log('Codex error headers: successful printed content cannot set a native error flag.');
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
