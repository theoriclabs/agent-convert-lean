#!/usr/bin/env node
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const loom = resolve(process.env.LOOM_BIN || '.lake/build/bin/loom');
const opencode = process.env.OPENCODE_BIN && resolve(process.env.OPENCODE_BIN);
const scratch = mkdtempSync(join(tmpdir(), 'loom-opencode-store-'));
const project = join(scratch, 'project');
mkdirSync(project);
const env = { ...process.env, XDG_DATA_HOME: join(scratch, 'data'),
  XDG_CONFIG_HOME: join(scratch, 'config'), XDG_CACHE_HOME: join(scratch, 'cache'),
  XDG_STATE_HOME: join(scratch, 'state'), OPENCODE_DISABLE_AUTOUPDATE: 'true',
  OPENCODE_DISABLE_MODELS_FETCH: 'true', OPENCODE_DISABLE_DEFAULT_PLUGINS: 'true' };
let serial = 0;
function run(binary, args, options = {}) {
  const result = spawnSync(binary, args, { encoding: 'utf8', timeout: 30000,
    maxBuffer: 8 * 1024 * 1024, ...options });
  assert.equal(result.status, 0, result.error?.message || result.stderr || result.stdout);
  return result.stdout;
}
function source(label, session) {
  const row = (index, role, content) => ({ type: role,
    uuid: `90000000-0000-4000-8001-${String(index).padStart(12, '0')}`,
    parentUuid: index ? `90000000-0000-4000-8001-${String(index - 1).padStart(12, '0')}` : null,
    sessionId: session, cwd: project, version: '2.1.274', isSidechain: false,
    timestamp: `2026-09-01T00:00:0${index}.000Z`, message: { role, content } });
  const image = { type: 'image', source: { type: 'base64', media_type: 'image/png',
    data: Buffer.from(`${label}-IMAGE`).toString('base64') } };
  return [row(0, 'user', [image, { type: 'text', text: label }]),
    row(1, 'assistant', [{ type: 'tool_use', id: 'call_shared', name: 'read', input: { path: '/synthetic' } }]),
    row(2, 'user', [{ type: 'tool_result', tool_use_id: 'call_shared', is_error: false,
      content: [{ type: 'text', text: `${label}-RESULT` }, image] }]),
    row(3, 'assistant', [{ type: 'text', text: `${label}-DONE` }])];
}
function convert(rows, targetId) {
  const input = join(scratch, `${serial}.jsonl`), output = join(scratch, `${serial++}.json`);
  writeFileSync(input, rows.map(JSON.stringify).join('\n') + '\n');
  const args = ['convert', input, 'opencode', output, '--no-subagents', '--json'];
  if (targetId !== undefined) args.push('--target-session-id', targetId);
  const result = spawnSync(loom, args, { encoding: 'utf8' });
  return { result, input, output, data: existsSync(output) ? JSON.parse(readFileSync(output, 'utf8')) : null };
}
const storageKeys = doc => doc.messages.flatMap(m => m.parts.flatMap(p => [
  `part/${m.info.id}/${p.id}`, ...(p.state?.attachments || []).map(a => `attachment/${a.id}`)]));
function contents(doc) {
  return doc.messages.flatMap(m => m.parts.flatMap(p => p.type === 'file' ? [`${p.mime}:${p.url}`]
    : p.type === 'text' && !p.ignored ? [p.text] : p.type === 'tool'
      ? [p.state.output, ...(p.state.attachments || []).map(a => `${a.mime}:${a.url}`)] : [])).sort();
}
try {
  const exports = [];
  for (const explicit of [false, true]) {
    const pair = ['SESSION-A', 'SESSION-B'].map((label, i) => {
      const converted = convert(source(label, `90000000-0000-4000-8000-00000000000${i + 2}`),
        explicit ? `ses_repro_${i}` : undefined);
      assert.equal(converted.result.status, 0, converted.result.stderr);
      assert.match(converted.data.info.id, /^ses_[A-Za-z0-9_-]+$/);
      return converted;
    });
    assert.notEqual(pair[0].data.info.id, pair[1].data.info.id);
    const firstKeys = new Set(storageKeys(pair[0].data));
    assert.ok(storageKeys(pair[1].data).every(key => !firstKeys.has(key)), 'sessions share part storage keys');
    assert.equal(new Set(pair[0].data.messages.map(m => m.info.id)).size, pair[0].data.messages.length);
    exports.push(...pair);
  }
  const anonymous = exports.slice(0, 2).map(item => {
    const archivePath = join(scratch, `anonymous-${serial++}.loom.json`);
    run(loom, ['convert', item.input, 'loom', archivePath, '--no-subagents']);
    const archive = JSON.parse(readFileSync(archivePath, 'utf8'));
    delete archive.env.sessionId;
    delete archive.origin.rawId;
    archive.origin.sourceRef = 'anonymous';
    writeFileSync(archivePath, JSON.stringify(archive));
    const output = join(scratch, `anonymous-${serial++}.json`);
    run(loom, ['convert', archivePath, 'opencode', output, '--no-subagents']);
    return JSON.parse(readFileSync(output, 'utf8')).info.id;
  });
  assert.notEqual(anonymous[0], anonymous[1], 'anonymous sources share a default ID');
  for (const invalid of ['', '90000000-0000-4000-8000-000000000000', 'ses', 'ses_', 'ses_../escape']) {
    const failure = convert(source('INVALID', '90000000-0000-4000-8000-000000000004'), invalid);
    assert.notEqual(failure.result.status, 0);
    assert.match(failure.result.stderr + failure.result.stdout, /invalid --target-session-id.*OpenCode/);
    assert.equal(failure.data, null, 'invalid explicit target was published');
  }
  if (opencode) {
    assert.equal(run(opencode, ['--version'], { env, cwd: project }).trim(), '1.1.34');
    // Import all artifacts before reading any: a second import must not replace
    // the first session's globally keyed parts or tool-result attachments.
    for (const item of exports) assert.match(run(opencode, ['import', item.output], { env, cwd: project }), /Imported session:/);
    for (const item of exports) {
      const loaded = JSON.parse(run(opencode, ['export', item.data.info.id], { env, cwd: project }));
      assert.deepEqual(contents(loaded), contents(item.data));
      assert.deepEqual(storageKeys(loaded).sort(), storageKeys(item.data).sort());
    }
  }
  console.log(`OpenCode IDs: source defaults, explicit targets, attachments, invalid IDs passed${opencode ? '; isolated 1.1.34 import/export passed' : ' (set OPENCODE_BIN for isolated target checks)'}.`);
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
