#!/usr/bin/env node
import assert from 'node:assert/strict';
import { lastToolOutcome, main, validateReply } from './continuation-probe.mjs';
const signal = { kind: 'structured', isError: 'false', evidence: ['exit_code=0'] };
const source = { activeLeaf: '2', entries: [
  { index: '0', payload: { blocks: [{ type: 'toolResult', error: signal }] } },
  { index: '1', parent: '0', payload: {} },
  { index: '2', parent: '1', payload: {} },
  { index: '3', parent: '0', payload: { blocks: [{ type: 'toolResult', error: { kind: 'native', isError: 'true' } }] } },
] };
const outcome = lastToolOutcome(source);
assert.equal(outcome.authoritativeSuccess, true); // Ignore a nonselected sibling.
assert.equal(outcome.entry, '0');
validateReply('Deploy the preview; git status succeeded and showed README.md modified.', ['preview'], ['README.md'], outcome);
for (const reply of ['', 'NO-REQUEST', 'Build the old viewer; README.md was modified.',
  'Deploy the preview; the last tool failed on README.md.', 'Deploy the preview.']) {
  assert.throws(() => validateReply(reply, ['preview'], ['README.md'], outcome));
}
for (const kind of ['heuristic', 'unrecorded']) {
  source.entries[0].payload.blocks[0].error = { kind, isError: 'false' };
  assert.equal(lastToolOutcome(source).authoritativeSuccess, false);
}
assert.throws(() => main(['unused', 'codex', '--expect', 'preview']), /not implemented/);
assert.throws(() => main(['unused', 'claude']), /Provide --expect/);
assert.throws(() => main(['unused', 'claude', '--expect']), /needs a value/);
console.log('Continuation probe: missing context, wrong request/outcome, false failure, selected branch, and unsupported harness checks passed.');
