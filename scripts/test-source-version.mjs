#!/usr/bin/env node
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const root = fileURLToPath(new URL('../', import.meta.url));
const loom = resolve(process.env.LOOM_BIN || join(root, '.lake/build/bin/loom'));
const scratch = mkdtempSync(join(tmpdir(), 'loom-source-version-'));
let serial = 0;
const rows = file => readFileSync(join(root, file), 'utf8').trim().split('\n').map(JSON.parse);
function convert(source, target = 'loom') {
  const input = join(scratch, `input-${serial}.jsonl`), output = join(scratch, `output-${serial++}.json`);
  writeFileSync(input, Array.isArray(source) ? source.map(JSON.stringify).join('\n') + '\n' : JSON.stringify(source));
  const run = spawnSync(loom, ['convert', input, target, output, '--no-subagents', '--json'], { encoding: 'utf8' });
  assert.equal(run.status, 0, run.stderr);
  return { summary: JSON.parse(run.stdout.trim().split('\n').at(-1)), stderr: run.stderr,
    archive: target === 'loom' ? JSON.parse(readFileSync(output, 'utf8')) : null };
}
function assertReview(result, observed, reviewed) {
  const expected = observed === null ? null : { observed, reviewed };
  assert.deepEqual(result.summary.sourceVersionBeyondReviewed, expected);
  const notes = result.summary.importJudgments.filter(note => note.kind === 'source-version-beyond-reviewed');
  assert.equal(notes.length, observed === null ? 0 : 1);
  assert.equal(result.stderr.split('\n').filter(line => line.includes('newest reviewed source schema')).length,
    observed === null ? 0 : 1);
  if (observed !== null) {
    assert.ok(result.stderr.includes(observed) && result.stderr.includes(reviewed));
    if (result.archive) assert.deepEqual(result.archive.origin.extras.source_version_beyond_reviewed, expected);
  }
}
try {
  const codex = rows('testdata/codex/0.162.1/compacted-rollout.jsonl');
  for (const [version, newer] of [['0.163.0', true], ['0.162.1', false], ['0.153.0', false],
    ['0.162.1-rc.2', false], ['0.162.1+build.99', false], ['vendor-z', true]]) {
    const source = structuredClone(codex); source[0].payload.cli_version = version;
    for (const target of ['loom', 'claude']) assertReview(convert(source, target), newer ? version : null, '0.162.1');
  }
  const missing = structuredClone(codex); delete missing[0].payload.cli_version;
  assertReview(convert(missing), null);
  const repeated = structuredClone(codex);
  const later = structuredClone(codex[0]); later.payload.cli_version = '0.170.0';
  repeated.push(later);
  assertReview(convert(repeated), '0.170.0', '0.162.1');
  const claude = rows('testdata/claude/2.1.274/versioned-session.jsonl');
  assertReview(convert(claude), null);
  const newerClaude = structuredClone(claude); newerClaude[1].version = '2.2.0';
  const claudeResult = convert(newerClaude);
  assertReview(claudeResult, '2.2.0', '2.1.274');
  assert.equal(claudeResult.archive.env.harnessVersion, '2.2.0');
  const openCode = JSON.parse(readFileSync(join(root, 'testdata/opencode/1.1.34/versioned-session.json'), 'utf8'));
  assertReview(convert(openCode), null);
  openCode.info.version = '1.10.0';
  assertReview(convert(openCode), '1.10.0', '1.1.34');
  assertReview(convert(rows('testdata/pi/3/versioned-session.jsonl')), null);
  // No release version was recorded in the reviewed Cursor corpus. Keep its
  // optional version field inert rather than fabricating a reviewed baseline.
  assertReview(convert([{ role: 'user', version: '2099.1', message: { content: [{ type: 'text', text: 'Recorded request.' }] } }]), null);
  console.log('Source version review: full/active Codex, multiple versions, semver, missing versions, and other-format hooks passed.');
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
