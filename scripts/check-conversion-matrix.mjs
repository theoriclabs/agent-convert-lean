#!/usr/bin/env node
// Inventory drift check only; semantic fidelity needs adapter and runtime tests.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const root = new URL('../', import.meta.url);
const main = readFileSync(new URL('LoomConvert/Main.lean', root), 'utf8');
const matrix = readFileSync(new URL('docs/conversion-matrix.md', root), 'utf8');
function dispatchNames(name) {
  const body = main.split(`def ${name} `)[1]?.split('\n/--')[0];
  assert.ok(body, `Cannot find ${name}`);
  const names = body.split('\n').filter(line => /^\s*\|\s*"/.test(line))
    .flatMap(line => [...line.split('=>')[0].matchAll(/"([^"]+)"/g)].map(m => m[1]));
  return [...new Set(names.map(n => n === 'gais' ? 'google-ai-studio' : n))].sort();
}
const section = matrix.split('<!-- routes:start -->')[1]?.split('<!-- routes:end -->')[0];
assert.ok(section, 'Missing routes table');
const rows = section.trim().split('\n').map(line => line.split('|').slice(1, -1).map(c => c.trim()));
const code = cell => { assert.match(cell, /^`[^`]+`$/); return cell.slice(1, -1); };
const targets = rows[0].slice(1).map(code);
const sources = rows.slice(2).map(row => code(row[0]));
assert.equal(new Set(targets).size, targets.length, 'Duplicate target');
assert.equal(new Set(sources).size, sources.length, 'Duplicate source');
assert.deepEqual([...targets].sort(), dispatchNames('exportByFormat'), 'Target inventory drift');
assert.deepEqual([...sources].sort(), dispatchNames('importByFormat'), 'Source inventory drift');
for (const row of rows.slice(2)) {
  assert.equal(row.length, targets.length + 1, 'Incomplete route row');
  for (const cell of row.slice(1)) assert.ok(['C', 'L', 'A'].includes(cell), `Unknown route label: ${cell}`);
}
console.log(`Conversion matrix inventory: ${sources.length} sources × ${targets.length} targets; matches CLI dispatch.`);
