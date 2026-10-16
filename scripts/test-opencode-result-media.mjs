#!/usr/bin/env node
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const loom = resolve(process.env.LOOM_BIN || '.lake/build/bin/loom');
const opencode = process.env.OPENCODE_BIN && resolve(process.env.OPENCODE_BIN);
const scratch = mkdtempSync(join(tmpdir(), 'loom-opencode-media-'));
const project = join(scratch, 'project');
mkdirSync(project);
const env = { ...process.env, XDG_DATA_HOME: join(scratch, 'data'),
  XDG_CONFIG_HOME: join(scratch, 'config'), XDG_CACHE_HOME: join(scratch, 'cache'),
  XDG_STATE_HOME: join(scratch, 'state'), OPENCODE_DISABLE_AUTOUPDATE: 'true',
  OPENCODE_DISABLE_MODELS_FETCH: 'true', OPENCODE_DISABLE_DEFAULT_PLUGINS: 'true' };
const text = { type: 'text', text: 'RESULT-TEXT' };
const image = { type: 'media', mimeType: 'image/png',
  data: 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lwoAAAAASUVORK5CYII=' };
const file = { type: 'media', mimeType: 'text/plain', data: 'data:text/plain;base64,RklMRS1DT05URU5U' };
function run(binary, args) {
  const result = spawnSync(binary, args, { env, cwd: project, encoding: 'utf8', timeout: 30000 });
  assert.equal(result.status, 0, result.error?.message || result.stderr || result.stdout);
  return result.stdout;
}
let serial = 0;
try {
  if (opencode) assert.equal(run(opencode, ['--version']).trim(), '1.1.34');
  const archiveFile = join(scratch, 'base.loom.json');
  run(loom, ['convert', resolve('parity/fixtures/opencode.json'), 'loom', archiveFile, '--no-subagents']);
  const base = JSON.parse(readFileSync(archiveFile, 'utf8'));
  for (const error of [
    { kind: 'native', isError: 'false' }, { kind: 'native', isError: 'true' },
    { kind: 'structured', isError: 'true', source: 'synthetic-status' },
    { kind: 'heuristic', isError: 'true', method: 'synthetic-guess' },
  ]) for (const content of [[text, image], [text, file], [text, image, file], [image], [file], [text]]) {
    const archive = structuredClone(base);
    const entryIndex = archive.entries.findIndex(e => e.payload.blocks?.some(b => b.type === 'toolResult'));
    const block = archive.entries[entryIndex].payload.blocks.find(b => b.type === 'toolResult');
    Object.assign(block, { content, error });
    const input = join(scratch, `${serial}.loom.json`), output = join(scratch, `${serial++}.json`);
    writeFileSync(input, JSON.stringify(archive));
    const result = spawnSync(loom, ['convert', input, 'opencode', output, '--no-subagents', '--json',
      '--target-session-id', `ses_media_${serial}`], { encoding: 'utf8' });
    const failed = error.kind !== 'heuristic' && error.isError === 'true';
    const media = content.filter(b => b.type === 'media');
    if (failed && media.length) {
      assert.notEqual(result.status, 0);
      assert.match(result.stderr + result.stdout,
        /entry \d+, block \d+: OpenCode error tool state cannot carry image\/file attachments; refusing to discard failed tool-result media/);
      assert.equal(existsSync(output), false, 'lossy failed-result output was published');
      continue;
    }
    assert.equal(result.status, 0, result.stderr || result.stdout);
    const doc = JSON.parse(readFileSync(output, 'utf8'));
    function check(document) {
      const tool = document.messages.flatMap(m => m.parts).find(p => p.type === 'tool');
      assert.equal(tool.state.status, failed ? 'error' : 'completed');
      assert.equal(failed ? tool.state.error : tool.state.output, content.filter(b => b.type === 'text').map(b => b.text).join('\n'));
      assert.deepEqual((tool.state.attachments || []).map(a => ({ mimeType: a.mime, data: a.url })),
        media.map(({ mimeType, data }) => ({ mimeType, data })));
    }
    check(doc);
    if (opencode) {
      run(opencode, ['import', output]);
      check(JSON.parse(run(opencode, ['export', doc.info.id])));
    }
  }
  console.log(`OpenCode result media: successful images/files survive, failed media is specifically refused, text-only failures and heuristic provenance remain valid${opencode ? '; isolated 1.1.34 loading passed' : ' (set OPENCODE_BIN for isolated target checks)'}.`);
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
