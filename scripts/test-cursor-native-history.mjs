#!/usr/bin/env node
// Synthetic wire fixtures only. No Cursor installation, account, or private history needed.
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';

const loom = resolve(process.env.LOOM_BIN || '.lake/build/bin/loom');
const scratch = mkdtempSync(join(tmpdir(), 'loom-cursor-native-'));
let sequence = 0;
function convert(source, from, to) {
  const input = join(scratch, `input-${sequence++}.json`);
  const output = join(scratch, `output-${sequence++}.json`);
  writeFileSync(input, typeof source === 'string' ? source : JSON.stringify(source));
  const run = spawnSync(loom, ['convert', input, to, output], { encoding: 'utf8' });
  assert.equal(run.status, 0, run.stderr || run.stdout);
  return readFileSync(output, 'utf8');
}
// A tiny fixture encoder, independent of the production decoder. Field numbers
// are from agent.v1's GrepResult/EditResult/ConversationSearchResult descriptors.
function uint(n) {
  n = BigInt(n); const bytes = [];
  do { bytes.push(Number(n & 127n) | (n > 127n ? 128 : 0)); n >>= 7n; } while (n);
  return Buffer.from(bytes);
}
const cat = (...parts) => Buffer.concat(parts);
const bytes = (n, value) => { const b = Buffer.from(value); return cat(uint(n * 8 + 2), uint(b.length), b); };
const number = (n, value) => cat(uint(n * 8), uint(value));
const binary = (tag, result, id = 'source-call\nwire-id') => cat(
  bytes(tag, bytes(2, result)), ...(id === null ? [] : [bytes(57, id)])).toString('base64');
const match = cat(number(1, 7), bytes(2, 'example: retained full line'), number(4, 1));
const content = cat(bytes(1, cat(bytes(1, 'example.yaml'), bytes(2, match))), number(2, 1), number(7, 0));
const grep = bytes(1, cat(bytes(1, 'example'), bytes(3, 'content'),
  bytes(4, cat(bytes(1, '/tmp/synthetic'), bytes(2, bytes(3, content))))));
const expectedGrep = { success: { pattern: 'example', outputMode: 'content', workspaceResults: {
  '/tmp/synthetic': { content: { matches: [{ file: 'example.yaml', matches: [
    { lineNumber: 7, content: 'example: retained full line', isContextLine: true },
  ] }], totalLines: 1, offsetApplied: 0 } },
} } };
const edit = bytes(7, cat(bytes(1, 'example.yaml'), bytes(2, 'not found'), bytes(5, 'The string to replace was not found.')));
const expectedEdit = { error: { path: 'example.yaml', error: 'not found', modelVisibleError: 'The string to replace was not found.' } };
const search = bytes(1, cat(bytes(1, cat(bytes(1, 'synthetic-conversation'), bytes(2, 'Synthetic title'),
  number(3, 1), number(4, 9007199254740993n), bytes(5, 'retained snippet'))), number(3, 1)));
const expectedSearch = { success: { hits: [{ conversationId: 'synthetic-conversation', title: 'Synthetic title',
  source: 'CONVERSATION_SEARCH_SOURCE_LOCAL', updatedAtMs: '9007199254740993', snippet: 'retained snippet' }], partial: true } };

function bubble(tf = {}, id = 'tool') {
  return { bubbleId: id, type: 2, createdAt: '2026-09-07T12:00:00Z', toolFormerData: {
    tool: 41, name: 'ripgrep_raw_search', toolCallId: 'source-call\nwire-id', rawArgs: { pattern: 'example' },
    status: 'completed', additionalData: { isPruned: true, totalMatches: 999 },
    toolCallBinary: binary(5, grep), ...tf,
  } };
}
function envelope(bubbles) {
  const all = [{ bubbleId: 'user', type: 1, text: 'Find the example.', createdAt: '2026-09-07T11:59:00Z' }, ...bubbles];
  return { composer: { composerId: '00000000-0000-4000-8000-000000000009', name: 'Synthetic native history',
    workspaceIdentifier: { uri: { fsPath: scratch } },
    fullConversationHeadersOnly: all.map(({ bubbleId, type }) => ({ bubbleId, type })),
  }, bubbles: all };
}
const results = t => t.entries.flatMap(e => e.payload.blocks || []).filter(b => b.type === 'toolResult');
const notes = t => JSON.stringify(t.importNotes);
const nativeRecords = text => text.trim().split('\n').map(JSON.parse).filter(r => r.type === 'response_item').map(r => r.payload);
function recovered(tf, expected, error = false) {
  const source = envelope([bubble(tf)]);
  const archive = JSON.parse(convert(source, 'cursor-ide', 'loom'));
  assert.equal(results(archive).length, 1);
  const result = results(archive)[0];
  assert.deepEqual(JSON.parse(result.content[0].text), expected);
  assert.deepEqual(result.error, { kind: 'native', isError: String(error) });
  assert.match(notes(archive), /cursorIdeBinaryToolResultRecovered/);
  const codex = convert(archive, 'loom', 'codex');
  const records = nativeRecords(codex);
  const calls = records.filter(r => r.type === 'function_call');
  const outputs = records.filter(r => r.type === 'function_call_output');
  assert.equal(calls.length, 1); assert.equal(outputs.length, 1);
  assert.equal(calls[0].call_id, 'source-call\nwire-id');
  assert.equal(calls[0].call_id, outputs[0].call_id);
  assert.deepEqual(JSON.parse(outputs[0].output), expected);
  assert.ok(!records.some(r => JSON.stringify(r.content || '').includes('[Historical')));
  const restored = JSON.parse(convert(codex, 'codex', 'loom'));
  assert.deepEqual(results(restored)[0].error, result.error);
  assert.deepEqual(results(restored)[0].content, result.content);
  const second = convert(restored, 'loom', 'codex');
  assert.equal(second, codex, 'native metadata and wire records must be byte-stable');
}
function unresolved(tf) {
  const archive = JSON.parse(convert(envelope([bubble(tf)]), 'cursor-ide', 'loom'));
  assert.equal(results(archive).length, 0);
  assert.match(notes(archive), /cursorIdeResultRecoveryUnresolved/);
  assert.ok(!notes(archive).includes('has no recorded result'));
}

try {
  recovered({}, expectedGrep);
  recovered({ tool: 38, name: 'edit_file_v2', status: 'error', toolCallBinary: binary(12, edit) }, expectedEdit, true);
  recovered({ tool: 0, name: 'search_conversations', toolCallBinary: binary(69, search) }, expectedSearch);
  recovered({ toolCallBinary: binary(5, grep, null) }, expectedGrep); // older binary without optional call ID
  recovered({ toolCallBinary: binary(5, bytes(2, bytes(1, 'search failed'))), status: 'error' }, { error: { error: 'search failed' } }, true);
  const counts = cat(bytes(1, cat(bytes(1, 'a.txt'), number(2, 2))), number(2, 1), number(3, 2), number(4, 1), number(6, 0));
  recovered({ toolCallBinary: binary(5, bytes(1, bytes(5, bytes(1, counts)))) },
    { success: { activeEditorResult: { count: { counts: [{ file: 'a.txt', count: 2 }], totalFiles: 1,
      totalMatches: 2, clientTruncated: true, headLimitApplied: 0 } } } });
  const files = cat(bytes(1, 'a.txt'), bytes(1, 'b.txt'), number(2, 2));
  recovered({ toolCallBinary: binary(5, bytes(1, bytes(5, bytes(2, files)))) },
    { success: { activeEditorResult: { files: { files: ['a.txt', 'b.txt'], totalFiles: 2 } } } });
  const editSuccess = cat(bytes(1, 'a.txt'), number(3, 0), bytes(5, ''), bytes(7, 'after'));
  recovered({ tool: 38, name: 'edit_file_v2', toolCallBinary: binary(12, bytes(1, editSuccess)) },
    { success: { path: 'a.txt', linesAdded: 0, diffString: '', afterFullFileContent: 'after' } });
  for (const toolCallBinary of ['A===', 'AB==', 'AQ', 'AA==', 'CgT/', binary(5, grep, 'wrong-call'),
    binary(12, edit), binary(5, cat(grep, bytes(2, bytes(1, 'contradiction')))),
    binary(5, bytes(99, 'future schema')), bytes(5, bytes(1, 'args-only')).toString('base64')]) unresolved({ toolCallBinary });
  unresolved({ status: 'error' }); // binary success cannot overwrite error status
  unresolved({ status: 'cancelled' });
  unresolved({ toolCallBinary: binary(5, bytes(2, bytes(1, 'failure'))) }); // nor the reverse
  unresolved({ toolCallBinary: 123 });
  const inline = JSON.parse(convert(envelope([bubble({ result: 'original inline output', toolCallBinary: 'not-base64' })]), 'cursor-ide', 'loom'));
  assert.equal(results(inline)[0].content[0].text, 'original inline output');
  const empty = JSON.parse(convert(envelope([bubble({ result: '' })]), 'cursor-ide', 'loom'));
  assert.equal(results(empty)[0].content[0].text, ''); // empty is present, not missing
  const loading = JSON.parse(convert(envelope([bubble({ status: 'loading' })]), 'cursor-ide', 'loom'));
  assert.equal(results(loading).length, 0); // provisional payload is not completed history
  for (const status of ['completed', undefined]) {
    const archive = JSON.parse(convert(envelope([bubble({ status, result: 'command timed out' })]), 'cursor-ide', 'loom'));
    const codex = convert(archive, 'loom', 'codex');
    assert.equal(nativeRecords(codex).filter(p => p.type === 'function_call_output').length, 1);
    assert.deepEqual(results(JSON.parse(convert(codex, 'codex', 'loom')))[0].error, results(archive)[0].error);
  }
  const repeated = JSON.parse(convert(envelope([bubble({}, 'first'), bubble({}, 'second')]), 'cursor-ide', 'loom'));
  assert.equal(results(repeated).length, 2);
  assert.notDeepEqual(results(repeated)[0].call, results(repeated)[1].call); // occurrence ownership, not global ID join
  const blank = convert(envelope([{ bubbleId: 'empty', type: 2, text: '' }]), 'cursor-ide', 'codex');
  assert.ok(!nativeRecords(blank).some(r => JSON.stringify(r.content || '').includes('[Historical')));
  console.log('Cursor native history: recovery, errors, malformed inputs, ownership, native records, and repeated-hop checks passed.');
} finally { rmSync(scratch, { recursive: true, force: true }); }
