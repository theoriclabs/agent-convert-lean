// End to end, against the real stores: start the built server, open the viewer in Chromium,
// list sessions, open the newest one, and check that a thread renders. Screenshots land in
// .lake/screenshots. Run from the viewer directory after `lake build loom_viewer` and
// `node scripts/build.mjs`: `node tests/browser.mjs`.
import { spawn } from 'node:child_process';
import { mkdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';
import playwright from '/Users/harshwork/code/leanreact/node_modules/@playwright/test/index.js';

const { chromium } = playwright;
const root = fileURLToPath(new URL('../', import.meta.url));
const port = Number(process.env.LOOM_VIEWER_PORT ?? 4811);
const base = `http://127.0.0.1:${port}`;
const shots = resolve(root, '.lake/screenshots');
await mkdir(shots, { recursive: true });

const server = spawn(resolve(root, '.lake/build/bin/loom_viewer'), [], {
  cwd: root, env: { ...process.env, LOOM_VIEWER_PORT: String(port) }, stdio: ['ignore', 'pipe', 'pipe'],
});
let serverLog = '';
for (const stream of [server.stdout, server.stderr]) stream.on('data', chunk => { serverLog += chunk; });
const deadline = Date.now() + 30_000;
let ready = false;
while (Date.now() < deadline && !ready) {
  try { ready = (await fetch(`${base}/api/health`)).ok; } catch { await new Promise(r => setTimeout(r, 250)); }
}
if (!ready) { server.kill(); console.error(serverLog); throw new Error('the viewer did not come up'); }

const errors = [];
const browser = await chromium.launch();
try {
  const page = await browser.newPage({ viewport: { width: 1360, height: 1000 } });
  page.on('pageerror', error => errors.push(`page: ${error.message}`));
  page.on('console', message => { if (message.type() === 'error') errors.push(`console: ${message.text()}`); });
  await page.goto(`${base}/`);
  await page.locator('.session').first().waitFor({ timeout: 90_000 });
  const rows = await page.locator('.session').count();
  const first = await page.locator('.session .session-title').first().textContent();
  const meta = await page.locator('.session .session-meta').first().textContent();
  console.log(`catalog: ${rows} rows on the first page; first: "${first}" (${meta})`);
  await page.screenshot({ path: resolve(shots, 'viewer-catalog.png') });
  await page.locator('.session').first().click();
  await page.locator('.aui-message').first().waitFor({ timeout: 180_000 });
  await page.waitForTimeout(500);
  const messages = await page.locator('.aui-message').count();
  const roles = await page.locator('.aui-message').evaluateAll(nodes => nodes.slice(0, 6).map(n => n.dataset.role));
  const tools = await page.locator('.aui-tool-name').count();
  console.log(`thread: ${messages} messages, first roles ${JSON.stringify(roles)}, ${tools} tool calls`);
  await page.screenshot({ path: resolve(shots, 'viewer-thread.png') });
  await page.locator('.chip', { hasText: 'Codex CLI' }).click();
  await page.locator('.session').first().waitFor({ timeout: 90_000 });
  console.log(`codex filter: first row "${await page.locator('.session .session-title').first().textContent()}"`);
  await page.screenshot({ path: resolve(shots, 'viewer-codex.png') });
} finally {
  await browser.close();
  server.kill();
}
console.log('errors:', JSON.stringify(errors));
const serverErrors = serverLog.split('\n').filter(line => /error|fail/i.test(line));
if (serverErrors.length) console.log('server log mentions:', serverErrors.slice(0, 5).join('\n'));
if (errors.length) process.exitCode = 1;
