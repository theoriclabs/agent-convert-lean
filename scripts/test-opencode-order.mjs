#!/usr/bin/env node
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const loom = resolve(process.env.LOOM_BIN || '.lake/build/bin/loom');
const opencode = process.env.OPENCODE_BIN && resolve(process.env.OPENCODE_BIN);
const scratch = mkdtempSync(join(tmpdir(), 'loom-opencode-order-'));
const project = join(scratch, 'project');
mkdirSync(project);
const env = { ...process.env, XDG_DATA_HOME: join(scratch, 'data'),
  XDG_CONFIG_HOME: join(scratch, 'config'), XDG_CACHE_HOME: join(scratch, 'cache'),
  XDG_STATE_HOME: join(scratch, 'state'), OPENCODE_DISABLE_AUTOUPDATE: 'true',
  OPENCODE_DISABLE_MODELS_FETCH: 'true', OPENCODE_DISABLE_DEFAULT_PLUGINS: 'true',
  OPENCODE_DISABLE_CLAUDE_CODE: 'true', OPENCODE_DISABLE_PROJECT_CONFIG: 'true',
  OPENCODE_EXPERIMENTAL_DISABLE_FILEWATCHER: 'true', OPENCODE_DISABLE_AUTOCOMPACT: 'true' };
const requests = [];
const server = createServer(async (req, res) => {
  let body = '';
  for await (const chunk of req) body += chunk;
  if (!req.url.endsWith('/chat/completions')) { res.writeHead(404); res.end(); return; }
  requests.push(JSON.parse(body));
  res.writeHead(200, { 'Content-Type': 'text/event-stream' });
  const chunk = { id: 'synthetic-response', object: 'chat.completion.chunk', created: 1, model: 'synthetic' };
  res.write(`data: ${JSON.stringify({ ...chunk, choices: [{ index: 0,
    delta: { role: 'assistant', content: 'NATIVE-ASSISTANT-MARKER' }, finish_reason: null }] })}\n\n`);
  res.write(`data: ${JSON.stringify({ ...chunk, choices: [{ index: 0, delta: {}, finish_reason: 'stop' }],
    usage: { prompt_tokens: 10, completion_tokens: 2, total_tokens: 12 } })}\n\n`);
  res.end('data: [DONE]\n\n');
});
function run(binary, args) {
  const result = spawnSync(binary, args, { encoding: 'utf8', env, cwd: project, timeout: 30000,
    maxBuffer: 8 * 1024 * 1024 });
  assert.equal(result.status, 0, result.error?.message || result.stderr || result.stdout);
  return result.stdout;
}
function runAsync(binary, args) {
  return new Promise((accept, reject) => {
    const child = spawn(binary, args, { env, cwd: project, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '', stderr = '';
    child.stdout.on('data', chunk => { stdout += chunk; });
    child.stderr.on('data', chunk => { stderr += chunk; });
    const timer = setTimeout(() => child.kill('SIGKILL'), 45000);
    child.on('error', reject);
    child.on('close', code => {
      clearTimeout(timer);
      if (code !== 0) reject(new Error(`OpenCode exited ${code}: ${stderr}\n${stdout}`));
      else accept(stdout);
    });
  });
}
function fixture(compacted) {
  const rows = [], sessionId = `95000000-0000-4000-8000-00000000000${Number(compacted)}`;
  const uuid = index => `95000000-0000-4000-8001-${String(index).padStart(12, '0')}`;
  function add(role, content, extra = {}) {
    const index = rows.length;
    rows.push({ type: role, uuid: uuid(index), parentUuid: index ? uuid(index - 1) : null,
      sessionId, cwd: project, version: '2.1.274', isSidechain: false,
      timestamp: new Date(Date.UTC(2026, 8, 1, 0, 0, index)).toISOString(),
      ...(role === 'system' ? { content } : { message: { role, content } }), ...extra });
  }
  for (let i = 0; i < 14; i++) {
    if (compacted && i === 6) {
      add('system', 'Conversation compacted', { parentUuid: null,
        logicalParentUuid: uuid(rows.length - 1), subtype: 'compact_boundary',
        compactMetadata: { trigger: 'auto', preTokens: 1000 } });
      add('user', 'ESSENTIAL-SUMMARY-MARKER', { isCompactSummary: true });
    }
    add(i % 2 ? 'assistant' : 'user', [
      { type: 'text', text: `ORDER-${i}-END` },
      ...([0, 6, 13].includes(i) ? Array.from({ length: 12 }, (_, j) =>
        ({ type: 'text', text: `PART-${i}-${j}-END` })) : [])]);
  }
  const input = join(scratch, `${compacted}.jsonl`), output = join(scratch, `${compacted}.json`);
  writeFileSync(input, rows.map(JSON.stringify).join('\n') + '\n');
  run(loom, ['convert', input, 'opencode', output, '--no-subagents', '--target-session-id', `ses_order_${compacted}`]);
  return { output, data: JSON.parse(readFileSync(output, 'utf8')) };
}
const ids = rows => rows.map(row => row.info.id);
function assertOrder(doc) {
  assert.deepEqual(ids(doc.messages), ids(doc.messages).toSorted(), 'message storage order differs from export order');
  for (const message of doc.messages) {
    const partIds = message.parts.map(part => part.id);
    assert.deepEqual(partIds, partIds.toSorted(), 'part storage order differs from export order');
  }
  const summary = doc.messages.find(m => m.info.role === 'assistant' && m.info.summary === true);
  if (summary) {
    const requestIndex = doc.messages.findIndex(m => m.info.id === summary.info.parentID);
    assert.equal(doc.messages[requestIndex + 1], summary, 'compaction request must precede its summary');
  }
}
function assertMarkersInOrder(text, compacted) {
  let previous = -1;
  const markers = [
    ...(compacted ? ['ESSENTIAL-SUMMARY-MARKER'] : []),
    ...Array.from({ length: compacted ? 8 : 14 }, (_, n) => n + (compacted ? 6 : 0)).flatMap(i => [
      `ORDER-${i}-END`, ...([0, 6, 13].includes(i) ? Array.from({ length: 12 }, (_, j) => `PART-${i}-${j}-END`) : [])]),
    'NATIVE-USER-MARKER'];
  for (const marker of markers) {
    const position = text.indexOf(marker);
    assert.ok(position > previous, `${marker} missing or out of order in target model input`);
    previous = position;
  }
  if (compacted) for (let i = 0; i < 6; i++) assert.ok(!text.includes(`ORDER-${i}-END`), 'pre-compaction history leaked');
}
try {
  if (opencode) {
    assert.equal(run(opencode, ['--version']).trim(), '1.1.34');
    await new Promise((accept, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', accept); });
    env.OPENCODE_CONFIG_CONTENT = JSON.stringify({ model: 'loom-local/synthetic', small_model: 'loom-local/synthetic',
      enabled_providers: ['loom-local'], autoupdate: false, share: 'disabled', snapshot: false,
      permission: { '*': 'deny' }, provider: { 'loom-local': { npm: '@ai-sdk/openai-compatible', name: 'Local fixture',
        options: { baseURL: `http://127.0.0.1:${server.address().port}/v1`, apiKey: 'synthetic-local-only' },
        models: { synthetic: { name: 'Synthetic', limit: { context: 100000, output: 1000 } } } } } });
  }
  for (const compacted of [false, true]) {
    const item = fixture(compacted);
    assert.ok(item.data.messages.length >= 14);
    assert.ok(item.data.messages.some(m => m.parts.length >= 12));
    assertOrder(item.data);
    if (!opencode) continue;
    run(opencode, ['import', item.output]);
    const loaded = JSON.parse(run(opencode, ['export', item.data.info.id]));
    assert.deepEqual(loaded.messages, item.data.messages, 'target reordered messages or parts');
    requests.length = 0;
    await runAsync(opencode, ['run', '--session', item.data.info.id, '--model', 'loom-local/synthetic',
      '--format', 'json', 'NATIVE-USER-MARKER']);
    const request = requests.find(r => JSON.stringify(r.messages).includes('NATIVE-USER-MARKER'));
    assert.ok(request, 'native target did not reach the local model endpoint');
    assertMarkersInOrder(JSON.stringify(request.messages), compacted);
    const appended = JSON.parse(run(opencode, ['export', item.data.info.id]));
    assert.deepEqual(appended.messages.slice(0, loaded.messages.length), loaded.messages);
    const tail = appended.messages.slice(loaded.messages.length);
    assert.deepEqual(tail.map(m => m.info.role), ['user', 'assistant']);
    assert.ok(tail[0].parts.some(p => p.text === 'NATIVE-USER-MARKER\n'));
    assert.ok(tail[1].parts.some(p => p.text === 'NATIVE-ASSISTANT-MARKER'));
    assert.equal(tail[1].info.parentID, tail[0].info.id);
    assertOrder(appended);
    assert.ok(tail.every(m => /^msg_[0-9a-f]{12}/.test(m.info.id)));
  }
  console.log(`OpenCode order: 14 messages, 13 parts, and compaction pairs passed${opencode ? '; actual 1.1.34 model input and native user/assistant append passed with a local synthetic responder' : ' (set OPENCODE_BIN for isolated target checks)'}.`);
} finally {
  server.close();
  rmSync(scratch, { recursive: true, force: true });
}
