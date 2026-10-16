#!/usr/bin/env node
// Opt-in authenticated harness check. Never run by the offline verification job.
import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { constants, copyFileSync, mkdirSync, mkdtempSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const prompt = 'In one sentence, what did the user most recently ask you to do, and what was the result of the last tool call? If you have no user request in context, reply NO-REQUEST.';
const digest = value => createHash('sha256').update(value).digest('hex');
const lastJsonLine = text => JSON.parse(text.trim().split('\n').at(-1));

export function lastToolOutcome(transcript) {
  const byIndex = new Map(transcript.entries.map(entry => [entry.index, entry]));
  const seen = new Set();
  let entry = byIndex.get(transcript.activeLeaf);
  while (entry && !seen.has(entry.index)) {
    seen.add(entry.index);
    const result = entry.payload.blocks?.findLast(block => block.type === 'toolResult');
    if (result) {
      const signal = result.error;
      return { entry: entry.index, signal,
        authoritativeSuccess: ['native', 'structured'].includes(signal?.kind) &&
          (signal.isError === 'false' || signal.isError === false) };
    }
    entry = byIndex.get(entry.parent);
  }
  return null;
}

export function validateReply(reply, expected, expectedOutcome, sourceOutcome) {
  assert.equal(typeof reply, 'string', 'Harness returned no textual answer');
  assert.ok(reply.trim(), 'Harness returned an empty answer');
  assert.doesNotMatch(reply, /NO[- ]REQUEST/i, 'Resumed model has no current request');
  for (const word of expected) assert.ok(reply.toLowerCase().includes(word.toLowerCase()),
    `Reply did not recall request keyword ${JSON.stringify(word)}`);
  for (const word of expectedOutcome) assert.ok(reply.toLowerCase().includes(word.toLowerCase()),
    `Reply did not recall tool-outcome keyword ${JSON.stringify(word)}`);
  if (sourceOutcome?.authoritativeSuccess) assert.doesNotMatch(reply, /\b(?:error|failed|failure)\b/i,
    'Reply describes an error although the last source tool status was success');
}

export function main(args = process.argv.slice(2)) {
  const [sourceArg, target, ...options] = args;
  assert.ok(sourceArg && target, 'Usage: continuation-probe.mjs <source> claude --expect <word> [--expect-outcome <word>] [--report <path>] [--keep]');
  assert.equal(target, 'claude', `Live continuation probing for ${target} is not implemented; no session was installed`);
  const expected = [], expectedOutcome = [];
  let keep = false, reportPath;
  for (let i = 0; i < options.length; i++) {
    const flag = options[i];
    if (flag === '--keep') { keep = true; continue; }
    assert.ok(['--expect', '--expect-outcome', '--report'].includes(flag), `Unknown option: ${flag}`);
    const value = options[++i];
    assert.ok(value && !value.startsWith('--'), `${flag} needs a value`);
    if (flag === '--expect') expected.push(value);
    else if (flag === '--expect-outcome') expectedOutcome.push(value);
    else reportPath = resolve(value);
  }
  assert.ok(expected.length, 'Provide --expect with a distinctive keyword from the current source request');
  const source = resolve(sourceArg), sourceBytes = readFileSync(source);
  for (const word of expected) assert.ok(sourceBytes.toString('utf8').toLowerCase().includes(word.toLowerCase()),
    `Request keyword ${JSON.stringify(word)} is absent from the source`);
  const root = fileURLToPath(new URL('../', import.meta.url));
  const loom = resolve(process.env.LOOM_BIN || join(root, '.lake/build/bin/loom'));
  const harness = process.env.CLAUDE_BIN || 'claude';
  const scratch = mkdtempSync(join(tmpdir(), 'loom-continuation-'));
  const run = (exe, argv, extra = {}) => {
    const result = spawnSync(exe, argv, { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024, ...extra });
    assert.equal(result.status, 0, `${exe} failed: ${result.error || result.stderr || result.stdout}`);
    return result.stdout;
  };
  const sessionId = randomUUID(), convertedPath = join(scratch, 'converted.jsonl');
  const sourceArchive = join(scratch, 'source.loom.json');
  const sourceSummary = lastJsonLine(run(loom, ['convert', source, 'loom', sourceArchive, '--json', '--no-subagents']));
  const sourceOutcome = lastToolOutcome(JSON.parse(readFileSync(sourceArchive, 'utf8')));
  const conversion = lastJsonLine(run(loom, ['convert', source, target, convertedPath, '--json',
    '--no-subagents', '--target-session-id', sessionId]));
  const converted = readFileSync(convertedPath);
  const harnessVersion = run(harness, ['--version']).trim();
  const converter = JSON.parse(run(loom, ['version', '--json']));
  const project = join(process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude'), 'projects',
    scratch.replace(/[^a-zA-Z0-9]/g, '-'));
  mkdirSync(project, { recursive: true });
  const installed = join(project, `${sessionId}.jsonl`);
  copyFileSync(convertedPath, installed, constants.COPYFILE_EXCL);
  const receipt = { schema: 'agent-convert.continuation-probe.v1', timestamp: new Date().toISOString(),
    target, harnessVersion, sessionId, source, sourceSha256: digest(sourceBytes),
    converterSha256: digest(readFileSync(loom)), converter,
    convertedSha256: digest(converted), sourceOutcome, expected, expectedOutcome,
    sourceSummary, conversion, prompt, toolsDisabled: true, passed: false, kept: keep };
  reportPath ||= join(scratch, 'receipt.json');
  try {
    const probe = spawnSync(harness, ['-p', '--resume', sessionId, '--fork-session',
      '--no-session-persistence', '--safe-mode', '--tools', '', '--disable-slash-commands',
      '--strict-mcp-config', '--mcp-config', '{"mcpServers":{}}', '--output-format', 'json',
      '--max-budget-usd', '2', prompt],
    { cwd: scratch, encoding: 'utf8', timeout: 180000, maxBuffer: 16 * 1024 * 1024 });
    writeFileSync(join(scratch, 'probe.stdout'), probe.stdout || '');
    writeFileSync(join(scratch, 'probe.stderr'), probe.stderr || '');
    assert.equal(probe.status, 0, `Harness failed; inspect ${scratch}: ${probe.error || probe.stderr}`);
    const response = JSON.parse(probe.stdout);
    receipt.reply = response.result;
    receipt.harnessResponse = response;
    assert.equal(response.is_error, false, `Harness reported an error: ${response.result}`);
    assert.equal(response.num_turns, 1, 'Probe unexpectedly ran additional agent turns');
    assert.equal(response.permission_denials?.length || 0, 0, 'Probe attempted a disallowed tool');
    validateReply(response.result, expected, expectedOutcome, sourceOutcome);
    assert.deepEqual(readFileSync(installed), converted, 'Probe modified the installed history');
    assert.deepEqual(readFileSync(source), sourceBytes, 'Probe modified the source');
    receipt.passed = true;
  } catch (error) {
    receipt.failure = error.message;
    throw error;
  } finally {
    if (!keep) unlinkSync(installed);
    receipt.installedSession = keep ? installed : null;
    mkdirSync(dirname(reportPath), { recursive: true });
    writeFileSync(reportPath, JSON.stringify(receipt, null, 2) + '\n', { mode: 0o600 });
    console.log(JSON.stringify({ check: 'live-continuation', passed: receipt.passed, target,
      harnessVersion, reply: receipt.reply, report: reportPath, installedSession: receipt.installedSession }));
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { main(); } catch (error) { console.error(error.message); process.exitCode = 1; }
}
