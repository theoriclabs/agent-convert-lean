#!/usr/bin/env node
// Synthetic Codex fixtures only. --live additionally makes one authenticated,
// no-tool Claude request from a nonpersistent fork of the converted history.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, readFileSync, mkdirSync, copyFileSync,
  unlinkSync, constants } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const scratch = mkdtempSync(join(tmpdir(), 'loom-claude-exec-'));
const sessionId = randomUUID();
const marker = `retained-${randomUUID()}`;
const timestamp = new Date().toISOString();
const scripts = [
  'text(await tools.exec_command({cmd: "printf first"})); text(await tools.exec_command({cmd: "printf second"}));',
  'const command = "false"; text(await tools.exec_command({cmd: command}));',
  'text(await tools.exec_command({cmd: "pwd", sandbox_permissions: "require_escalated"}));',
];
const outputs = [marker, 'Process exited with code 1\nfailed intentionally', ''];
const item = payload => ({ type: 'response_item', timestamp, payload });
const active = [
  { type: 'message', role: 'user', content: [{ type: 'input_text',
    text: 'Read the marker, try the failing operation, and inspect the working directory.' }] },
  ...scripts.flatMap((input, i) => [
    { type: 'custom_tool_call', name: 'exec', call_id: `call_exec_${i}`, input },
    { type: 'custom_tool_call_output', call_id: `call_exec_${i}`, output: outputs[i] },
  ]),
];
const source = [
  { type: 'session_meta', timestamp, payload: {
    id: sessionId, timestamp, cwd: scratch, cli_version: '0.153.4',
    originator: 'codex_cli_rs', source: 'cli', model_provider: 'openai',
  } },
  item({ type: 'message', role: 'user', content: [
    { type: 'input_text', text: 'PRECOMPACTION_SENTINEL_MUST_NOT_REAPPEAR' },
  ] }),
  { type: 'compacted', timestamp, payload: { message: 'Compacted', replacement_history: active } },
];
const input = join(scratch, 'source.jsonl');
const output = join(scratch, 'claude.jsonl');
writeFileSync(input, source.map(JSON.stringify).join('\n') + '\n');
const loom = resolve(process.env.LOOM_BIN || '.lake/build/bin/loom');
const run = spawnSync(loom, ['convert', input, 'claude', output], { encoding: 'utf8' });
assert.equal(run.status, 0, run.stderr || run.stdout);
const converted = readFileSync(output, 'utf8');
const rows = converted.trim().split('\n').map(JSON.parse);
const blocks = rows.flatMap(r => Array.isArray(r.message?.content) ? r.message.content : []);
const calls = blocks.filter(b => b.type === 'tool_use');
const results = blocks.filter(b => b.type === 'tool_result');
assert.equal(calls.length, scripts.length);
assert.equal(results.length, scripts.length);
for (let i = 0; i < scripts.length; i++) {
  assert.equal(calls[i].name, 'exec');
  assert.equal(calls[i].id, `call_exec_${i}`);
  assert.deepEqual(calls[i].input, { input: scripts[i] });
  assert.equal(results[i].tool_use_id, calls[i].id);
  const body = typeof results[i].content === 'string' ? results[i].content
    : results[i].content.map(b => b.text).join('');
  assert.equal(body, outputs[i]);
}
assert.equal(results[1].is_error, true);
assert.ok(!converted.includes('PRECOMPACTION_SENTINEL_MUST_NOT_REAPPEAR'));
assert.ok(!blocks.some(b => /Historical tool (?:call|result)/.test(b.text || '')));
const roundtrip = join(scratch, 'roundtrip.jsonl');
const again = spawnSync(loom, ['convert', output, 'claude', roundtrip], { encoding: 'utf8' });
assert.equal(again.status, 0, again.stderr || again.stdout);
assert.equal(readFileSync(roundtrip, 'utf8'), converted);
console.log(JSON.stringify({ check: 'claude-exec-native-artifact', passed: true,
  nativePairs: calls.length, activeCompactionOnly: true, artifacts: scratch }));

if (process.argv.includes('--live')) {
  const project = join(homedir(), '.claude', 'projects', scratch.replace(/[^a-zA-Z0-9]/g, '-'));
  mkdirSync(project, { recursive: true });
  const installed = join(project, `${sessionId}.jsonl`);
  copyFileSync(output, installed, constants.COPYFILE_EXCL);
  try {
    const prompt = 'Use only the prior tool results in this conversation. Do not use tools. '
      + 'Return only JSON with marker (the exact retained marker from the first operation), '
      + 'secondOperationSucceeded (boolean), and thirdOutput (the exact third result text).';
    const probe = spawnSync(process.env.CLAUDE_BIN || 'claude', [
      '-p', '--resume', sessionId, '--fork-session', '--no-session-persistence',
      '--safe-mode', '--tools', '', '--strict-mcp-config', '--mcp-config', '{"mcpServers":{}}',
      '--output-format', 'json', prompt,
    ], { cwd: scratch, encoding: 'utf8', timeout: 120000, maxBuffer: 8 * 1024 * 1024 });
    writeFileSync(join(scratch, 'probe.json'), probe.stdout || '');
    writeFileSync(join(scratch, 'probe.stderr'), probe.stderr || '');
    assert.equal(probe.status, 0, `Claude failed; inspect ${scratch}: ${probe.error || probe.stderr}`);
    const response = JSON.parse(probe.stdout);
    assert.equal(response.is_error, false);
    const answer = JSON.parse(response.result.replace(/^```(?:json)?\s*|\s*```$/g, ''));
    assert.equal(answer.marker, marker);
    assert.equal(answer.secondOperationSucceeded, false);
    assert.equal(answer.thirdOutput, '');
    assert.equal(readFileSync(installed, 'utf8'), converted, 'Probe modified installed history');
    console.log(JSON.stringify({ check: 'claude-exec-live-continuation', passed: true,
      priorResultRecalled: true, recordedFailureUnderstood: true, toolsDisabled: true }));
  } finally {
    // Remove only the synthetic transcript created exclusively by this run.
    unlinkSync(installed);
  }
}
