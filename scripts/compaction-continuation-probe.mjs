#!/usr/bin/env node
// Opt-in authenticated Pi check using only the checked-in synthetic fixture.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdtempSync, mkdirSync } from 'node:fs';
import { join, resolve, dirname } from 'node:path';
import { homedir, tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const fixture = join(root, 'testdata/claude/2.1.274/compaction-summary.jsonl');
const loom = resolve(process.env.LOOM_BIN || join(root, '.lake/build/bin/loom'));
const pi = process.env.PI_BIN || 'pi';
const source = readFileSync(fixture);
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const scratch = mkdtempSync(join(tmpdir(), 'loom-summary-recall-'));
const reportPath = resolve(process.argv[2] || join(scratch, 'receipt.json'));
const settings = JSON.parse(readFileSync(join(process.env.PI_CODING_AGENT_DIR ||
  join(homedir(), '.pi/agent'), 'settings.json'), 'utf8'));
assert.ok(settings.defaultProvider && settings.defaultModel, 'Configure a Pi provider/model first');
const provider = process.env.PI_PROBE_PROVIDER || settings.defaultProvider;
const model = process.env.PI_PROBE_MODEL || settings.defaultModel;
const run = (exe, args, options = {}) => {
  const out = spawnSync(exe, args, { encoding: 'utf8', timeout: 180000,
    maxBuffer: 16 * 1024 * 1024, ...options });
  assert.equal(out.status, 0, `${exe} failed: ${out.error || out.stderr || out.stdout}`);
  return out.stdout;
};
const converted = join(scratch, 'converted.jsonl');
const conversion = JSON.parse(run(loom, ['convert', fixture, 'pi', converted,
  '--no-subagents', '--target-cwd', scratch, '--target-provider', provider,
  '--target-model', model, '--json']).trim().split('\n').at(-1));
const convertedBytes = readFileSync(converted);
const prompt = 'Which database and migration codename did we choose? Reply in one sentence from the existing conversation.';
const receipt = { schema: 'agent-convert.compaction-recall.v1', timestamp: new Date().toISOString(),
  target: 'pi', harnessVersion: run(pi, ['--version']).trim(),
  provider, model,
  sourceSha256: hash(source), converterSha256: hash(readFileSync(loom)),
  convertedSha256: hash(convertedBytes), conversion, prompt, toolsDisabled: true, passed: false };
try {
  const stdout = run(pi, ['--session', converted, '--print', '--mode', 'json', '--no-tools',
    '--no-extensions', '--no-skills', '--no-prompt-templates', '--no-themes',
    '--no-context-files', '--offline', '--no-approve', '--provider', provider,
    '--model', model, prompt], { cwd: scratch, env: { ...process.env, PI_TELEMETRY: '0' } });
  writeFileSync(join(scratch, 'probe.stdout.jsonl'), stdout, { mode: 0o600 });
  const events = stdout.trim().split('\n').map(JSON.parse);
  assert.equal(events.filter(e => e.type === 'tool_execution_start').length, 0);
  const messages = events.filter(e => e.type === 'message_end' && e.message?.role === 'assistant').map(e => e.message);
  assert.ok(messages.length);
  assert.ok(messages.every(m => m.stopReason !== 'error'),
    messages.find(m => m.stopReason === 'error')?.errorMessage || 'Pi model request failed');
  assert.ok(messages.every(m => !m.content.some(b => b.type === 'toolCall')));
  const reply = messages.at(-1).content.filter(b => b.type === 'text').map(b => b.text).join('\n');
  receipt.reply = reply;
  assert.match(reply, /PostgreSQL/i);
  assert.match(reply, /violet-river/i);
  assert.deepEqual(readFileSync(fixture), source);
  receipt.passed = true;
} catch (error) {
  receipt.failure = error.message;
  throw error;
} finally {
  mkdirSync(dirname(reportPath), { recursive: true });
  writeFileSync(reportPath, JSON.stringify(receipt, null, 2) + '\n', { mode: 0o600 });
  console.log(JSON.stringify({ passed: receipt.passed, target: receipt.target,
    harnessVersion: receipt.harnessVersion, reply: receipt.reply, report: reportPath }));
}
