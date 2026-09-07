#!/usr/bin/env node
// Keep the CLI version, release checks, changelog, and published notes aligned.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const root = new URL('../', import.meta.url);
const read = path => readFileSync(new URL(path, root), 'utf8');
const version = read('LoomConvert/Main.lean').match(/def coreVersion : String := "([^"]+)"/)?.[1];
assert.ok(version, 'Cannot find the CLI version');
const requested = process.argv[2];
assert.ok(!requested || requested === '--check' || requested === version || requested === `v${version}`,
  `Expected v${version} or --check`);
const changelog = read('CHANGELOG.md');
assert.match(changelog, /^## \[Unreleased\]$/m, 'Keep an Unreleased section');
const sections = [...changelog.matchAll(/^## \[([^\]]+)\](?: - (\d{4}-\d{2}-\d{2}))?\s*$/gm)];
const index = sections.findIndex(m => m[1] === version);
assert.ok(index >= 0 && sections[index][2], `Missing dated changelog entry for ${version}`);
assert.equal(sections.filter(m => m[1] === version).length, 1, 'Duplicate release entry');
const start = sections[index].index + sections[index][0].length;
const end = sections[index + 1]?.index ?? changelog.length;
const notes = changelog.slice(start, end).replace(/^\[[^\]]+\]: .*$/gm, '').trim();
assert.ok(notes.length > 0, 'Release notes are empty');
for (const path of ['scripts/build-release.sh', 'scripts/verify.sh']) {
  const pins = [...read(path).matchAll(/engineVersion !== "([^"]+)"/g)].map(m => m[1]);
  assert.deepEqual(pins, [version], `Stale release-version check in ${path}`);
}
console.log(requested === '--check' ? `Release metadata aligned: v${version}` : notes);
