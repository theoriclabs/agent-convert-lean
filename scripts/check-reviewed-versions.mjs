#!/usr/bin/env node
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const directory = { codexCli: 'codex', claudeCode: 'claude', pi: 'pi', openCode: 'opencode' };
const versionPattern = /^(?:\d+|\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?)$/;
function compareVersion(a, b) {
  const parse = value => {
    const [core, ...pre] = value.split('+')[0].split('-');
    return [core.split('.').map(Number), pre.length ? pre.join('-').split('.') : []];
  };
  const [an, ap] = parse(a), [bn, bp] = parse(b);
  for (let i = 0; i < Math.max(an.length, bn.length); i++) {
    if (an[i] !== bn[i]) return (an[i] ?? -1) < (bn[i] ?? -1) ? -1 : 1;
  }
  if (!ap.length || !bp.length) return ap.length === bp.length ? 0 : ap.length ? -1 : 1;
  for (let i = 0; i < Math.max(ap.length, bp.length); i++) {
    if (ap[i] === bp[i]) continue;
    if (ap[i] === undefined || bp[i] === undefined) return ap[i] === undefined ? -1 : 1;
    const numericA = /^\d+$/.test(ap[i]), numericB = /^\d+$/.test(bp[i]);
    if (numericA !== numericB) return numericA ? -1 : 1;
    return (numericA ? Number(ap[i]) < Number(bp[i]) : ap[i] < bp[i]) ? -1 : 1;
  }
  return 0;
}
function checkBaseline(reviewed, versions, label) {
  assert.ok(versions.length, `${label}: no versioned fixtures`);
  const newest = [...versions].sort(compareVersion).at(-1);
  assert.equal(reviewed, newest, `${label}: reviewedSourceVersion must equal newest fixture directory`);
}
assert.equal(compareVersion('0.100.0', '0.99.0'), 1);
assert.equal(compareVersion('1.0.0-rc.10', '1.0.0-rc.2'), 1);
assert.equal(compareVersion('1.0.0+build', '1.0.0'), 0);
assert.throws(() => checkBaseline('0.162.1', ['0.162.1', '0.163.0'], 'new fixture'));
assert.throws(() => checkBaseline('0.163.0', ['0.162.1'], 'unsupported baseline bump'));

const source = readFileSync(join(root, 'LoomConvert/SourceVersion.lean'), 'utf8');
const baselines = [...source.matchAll(/^\s*\| \.(\w+) => some "([^"]+)"/gm)];
assert.equal(baselines.length, Object.keys(directory).length, 'reviewed format inventory changed');
let fixtures = 0;
for (const [, format, reviewed] of baselines) {
  const formatRoot = join(root, 'testdata', directory[format]);
  const versions = readdirSync(formatRoot, { withFileTypes: true })
    .filter(entry => entry.isDirectory() && versionPattern.test(entry.name)).map(entry => entry.name);
  checkBaseline(reviewed, versions, format);
  for (const version of versions) {
    const path = join(formatRoot, version);
    const files = readdirSync(path).filter(name => /\.jsonl?$/.test(name));
    assert.ok(files.length, `${path}: version directory has no JSON fixtures`);
    for (const file of files) {
      const text = readFileSync(join(path, file), 'utf8');
      const rows = file.endsWith('.jsonl') ? text.trim().split('\n').map(JSON.parse) : [JSON.parse(text)];
      const observed = format === 'codexCli' ? rows[0].payload?.cli_version :
        format === 'openCode' ? rows[0].info?.version : String(rows[0].version);
      assert.equal(observed, version, `${path}/${file}: recorded version disagrees with directory`);
      fixtures++;
    }
  }
}
console.log(`Reviewed source versions: ${baselines.length} baselines match ${fixtures} versioned fixtures; drift mutations rejected.`);
