#!/usr/bin/env node
// Opt-in integration probe. Installs one synthetic session and makes one model
// request using normal Codex auth (--compact uses two turns to test automatic
// remote compaction as well). It never loads a user's source conversation.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { spawnSync, spawn } from 'node:child_process';
import { mkdtempSync, writeFileSync, readFileSync, mkdirSync, copyFileSync, constants } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

assert.ok(process.argv.includes('--run'), 'Pass --run to authorize a synthetic session and live Codex requests.');
const scratch = mkdtempSync(join(tmpdir(), 'loom-native-resume-'));
const sessionId = randomUUID();
const sentinel = `retained-${randomUUID()}`;
const now = new Date().toISOString();
const bubbles = [
  { bubbleId: 'user', type: 1, text: 'Find the retained marker, then try the requested edit.' },
  { bubbleId: 'grep', type: 2, toolFormerData: { tool: 41, name: 'ripgrep_raw_search',
    toolCallId: `call-${'s'.repeat(60)}\nrecorded-source-id`, status: 'completed', rawArgs: { pattern: 'marker' },
    result: JSON.stringify({ success: { matches: [{ lineNumber: 7, content: sentinel }] } }),
  } },
  { bubbleId: 'edit', type: 2, toolFormerData: { tool: 38, name: 'edit_file_v2',
    toolCallId: `call-${'e'.repeat(60)}\nrecorded-source-id`, status: 'error', rawArgs: { old_string: 'example', new_string: 'updated' },
    result: JSON.stringify({ error: { modelVisibleError: 'The string to replace was not found.' } }),
  } },
  { bubbleId: 'empty', type: 2, text: '' },
];
const source = { composer: { composerId: sessionId, name: 'Loom synthetic native-history probe',
  workspaceIdentifier: { uri: { fsPath: scratch } },
  fullConversationHeadersOnly: bubbles.map(({ bubbleId, type }) => ({ bubbleId, type })),
}, bubbles: bubbles.map(b => ({ ...b, createdAt: now })) };
const input = join(scratch, 'source.json');
const output = join(scratch, 'converted.jsonl');
writeFileSync(input, JSON.stringify(source));
const conversion = spawnSync(resolve(process.env.LOOM_BIN || '.lake/build/bin/loom'), ['convert', input, 'codex', output], { encoding: 'utf8' });
assert.equal(conversion.status, 0, conversion.stderr);
const wire = readFileSync(output, 'utf8').trim().split('\n').map(JSON.parse);
const calls = wire.filter(r => r.payload?.type === 'function_call');
assert.equal(calls.length, 2);
assert.ok(calls.every(r => r.payload.call_id.length <= 64 && r._agent_convert_call_id?.source.length > 64));
const directory = join(homedir(), '.codex', 'sessions', ...now.slice(0, 10).split('-'));
mkdirSync(directory, { recursive: true });
const installed = join(directory, `rollout-${now.slice(0, 19).replaceAll(':', '-')}-${sessionId}.jsonl`);
copyFileSync(output, installed, constants.COPYFILE_EXCL);
const prompt = 'Use only your earlier tool results already in this conversation. Do not call any tools. '
  + 'Return JSON with marker (the exact retained marker found by the search) and editSucceeded (a boolean).';
const codex = process.env.CODEX_BIN || 'codex';
const forceCompact = process.argv.includes('--compact');
if (forceCompact) {
  // An imported rollout has no measured token usage yet. Seed one no-tool
  // response so the next resume can actually trigger automatic compaction.
  const seed = spawnSync(codex, ['exec', '--sandbox', 'read-only', '--ignore-user-config',
    '-c', 'approval_policy="never"', 'resume', '--skip-git-repo-check', '--json', sessionId, prompt],
    { cwd: scratch, encoding: 'utf8', timeout: 120000 });
  writeFileSync(join(scratch, 'seed.jsonl'), seed.stdout || '');
  writeFileSync(join(scratch, 'seed.stderr.log'), seed.stderr || '');
  assert.equal(seed.status, 0, `Seed turn failed; inspect ${scratch}`);
}
const child = spawn(codex, ['exec', '--sandbox', 'read-only', '--ignore-user-config', '-c', 'approval_policy="never"',
  ...(forceCompact ? ['-c', 'model_auto_compact_token_limit=1'] : []),
  'resume', '--skip-git-repo-check', '--json', sessionId, prompt], { cwd: scratch, stdio: ['ignore', 'pipe', 'pipe'] });
let stdout = '', stderr = '';
child.stdout.on('data', b => { stdout += b; });
child.stderr.on('data', b => { stderr += b; });
const timeout = setTimeout(() => child.kill('SIGTERM'), 120000);
const code = await new Promise((resolve, reject) => { child.on('error', reject); child.on('exit', resolve); });
clearTimeout(timeout);
writeFileSync(join(scratch, 'events.jsonl'), stdout);
writeFileSync(join(scratch, 'stderr.log'), stderr);
assert.equal(code, 0, `Codex failed; inspect ${scratch}`);
const events = stdout.trim().split('\n').map(JSON.parse);
const items = events.filter(e => e.type === 'item.completed').map(e => e.item);
assert.ok(!items.some(i => ['command_execution', 'mcp_tool_call', 'web_search'].includes(i.type)), 'Probe made a new tool call');
const answer = items.filter(i => i.type === 'agent_message').at(-1)?.text;
assert.ok(answer, `No model answer; inspect ${scratch}`);
const parsed = JSON.parse(answer.replace(/^```(?:json)?\s*|\s*```$/g, ''));
assert.equal(parsed.marker, sentinel, 'Actual resumed model did not receive the prior result');
assert.equal(parsed.editSucceeded, false, 'Actual resumed model misread recorded failure');
// Also check the rollout, including tool kinds unknown to the CLI event printer.
const original = readFileSync(output, 'utf8');
const resumed = readFileSync(installed, 'utf8');
assert.ok(resumed.startsWith(original), 'Resume rewrote existing history');
const appended = resumed.slice(original.length).trim().split('\n').filter(Boolean).map(JSON.parse);
assert.ok(!appended.some(r => ['function_call', 'custom_tool_call', 'web_search_call'].includes(r.payload?.type)), 'Resume executed a tool');
const compacted = appended.some(r => r.type === 'compacted');
if (forceCompact) assert.ok(compacted, `Forced remote compaction was not exercised; inspect ${scratch}`);
console.log(JSON.stringify({ check: 'live-model-native-history', passed: true, priorResultRecalled: true,
  recordedFailureUnderstood: true, newToolCalls: 0, compacted, sessionId, artifacts: scratch }));
