// `node --test web/client.test.mjs` from the viewer directory. The decoders and the service are
// checked against samples shaped like CONTRACT.md; the compiled `Viewer.UI.App` is mounted in jsdom
// over a fake service. The node_modules link (scripts/build.mjs) is made first so react, react-dom
// and jsdom resolve from here; every import below is dynamic for that reason and because jsdom's
// globals must exist before react-dom and assistant-ui load.
import test from 'node:test';
import assert from 'node:assert/strict';

const { linkNodeModules } = await import('../scripts/build.mjs');
await linkNodeModules();
const { JSDOM, VirtualConsole } = await import('jsdom');

// assistant-ui's viewport measures and scrolls; jsdom has neither, so the browser-only pieces are stubs.
const virtualConsole = new VirtualConsole().forwardTo(console, { jsdomErrors: 'none' });
const { window } = new JSDOM('<!doctype html><html><body></body></html>', { virtualConsole, url: 'http://localhost' });
Object.assign(globalThis, { window, document: window.document, HTMLElement: window.HTMLElement, IS_REACT_ACT_ENVIRONMENT: true });
window.Element.prototype.scrollTo = function () {};
window.Element.prototype.scrollIntoView = function () {};
globalThis.ResizeObserver = class { observe() {} unobserve() {} disconnect() {} };
globalThis.requestAnimationFrame = callback => setTimeout(() => callback(Date.now()), 0);
globalThis.cancelAnimationFrame = id => clearTimeout(id);

const React = await import('react');
const { createRoot } = await import('react-dom/client');
const { mountElement, ctor, runAction } = await import('../../../leanreact/engine/adapters/leanjs-react.mjs');
const { action } = await import('../../../leanreact/engine/runtime/actions.mjs');
await import('../../../leanreact/adapters/assistant-ui/index.mjs');
const program = await import('./generated/viewer.mjs');
const { createService, decodeSession, decodeSessionPage, decodeMessage, decodeConversation, queryToSearch } = await import('./client.mjs');

const some = value => ctor('Option.some', [value]);
const none = ctor('Option.none');
const bool = value => ctor(value ? 'Bool.true' : 'Bool.false');
const ok = value => ctor('Except.ok', [value]);
const claude = program['Viewer.Harness.parse']('claude').fields[0];
const codex = program['Viewer.Harness.parse']('codex').fields[0];
const query = (harness, text, offset, limit) => ctor('Viewer.UI.Query.mk', [harness, text, offset, limit]);

// Samples shaped like CONTRACT.md.
const overviewJson = {
  harness: 'claude', id: '5f1c2a9e-0d8b-4c1e-9a7f-2b3c4d5e6f70',
  path: '/Users/x/.claude/projects/-Users-x-code-leanreact/5f1c2a9e-0d8b-4c1e-9a7f-2b3c4d5e6f70.jsonl',
  modifiedMs: 1791589431313, bytes: 4598658,
  title: 'Build a GREAT overview of the project', cwd: '/Users/x/code/leanreact', model: 'claude-opus-4-1',
  startedMs: 1791589431313, turns: 12,
};
const bareJson = {
  harness: 'codex', id: '01a12244-c621-7971-870e-e2bd8ee07b96',
  path: '/Users/x/.codex/sessions/2026/10/09/rollout-2026-10-09T14-41-45-01a12244-c621-7971-870e-e2bd8ee07b96.jsonl',
  modifiedMs: 1791500000000, bytes: 1024, title: null, cwd: null, model: null, startedMs: null, turns: 0,
};
const pageJson = { sessions: [overviewJson, bareJson], total: 57 };
const conversationJson = {
  messages: [
    { id: '0', role: 'user', atMs: 1791589431313, status: { type: 'complete' }, parts: [{ type: 'text', text: 'List the files.' }] },
    { id: '3.0', role: 'assistant', atMs: null, status: { type: 'complete' }, parts: [
      { type: 'reasoning', text: 'A listing will do.' },
      { type: 'text', text: 'Let me look.' },
      { type: 'toolCall', callId: '3.1', name: 'Bash', arguments: { fields: [['command', 'ls']] }, result: { value: 'README.md\nlakefile.toml', isError: false } },
      { type: 'toolCall', callId: '3.2', name: 'Read', arguments: { fields: [['path', 'x']] }, result: null },
    ] },
    { id: '5', role: 'system', atMs: 1791589431400, status: { type: 'failed', error: 'boom' }, parts: [{ type: 'text', text: '[event] compaction' }] },
  ],
  sidechains: 1, importNotes: 2, hidden: { events: 0, redacted: 0 },
};
const overview = ctor('Viewer.Session.mk', [
  ctor('Viewer.SessionFile.mk', [claude, overviewJson.id, overviewJson.path, 1791589431313n, 4598658n]),
  ctor('Viewer.Preview.mk', [some('Build a GREAT overview of the project'), some('/Users/x/code/leanreact'), some('claude-opus-4-1'), some(1791589431313n), 12n, bool(false)]),
]);
const bare = ctor('Viewer.Session.mk', [
  ctor('Viewer.SessionFile.mk', [codex, bareJson.id, bareJson.path, 1791500000000n, 1024n]),
  ctor('Viewer.Preview.mk', [none, none, none, none, 0n, bool(false)]),
]);
const conversation = ctor('Viewer.Conversation.mk', [[
  ctor('AssistantUI.Message.mk', ['0', ctor('AssistantUI.Role.user'), [ctor('AssistantUI.Part.text', ['List the files.'])], some(1791589431313n), ctor('AssistantUI.MessageStatus.complete')]),
  ctor('AssistantUI.Message.mk', ['3.0', ctor('AssistantUI.Role.assistant'), [
    ctor('AssistantUI.Part.reasoning', ['A listing will do.']),
    ctor('AssistantUI.Part.text', ['Let me look.']),
    ctor('AssistantUI.Part.toolCall', ['3.1', 'Bash', ctor('AssistantUI.ToolArguments.fields', [[ctor('Prod.mk', ['command', 'ls'])]]), some(ctor('AssistantUI.ToolResult.mk', ['README.md\nlakefile.toml', bool(false)]))]),
    ctor('AssistantUI.Part.toolCall', ['3.2', 'Read', ctor('AssistantUI.ToolArguments.fields', [[ctor('Prod.mk', ['path', 'x'])]]), none]),
  ], none, ctor('AssistantUI.MessageStatus.complete')]),
  ctor('AssistantUI.Message.mk', ['5', ctor('AssistantUI.Role.system'), [ctor('AssistantUI.Part.text', ['[event] compaction'])], some(1791589431400n), ctor('AssistantUI.MessageStatus.failed', ['boom'])]),
], 1n, 2n, ctor('Viewer.Hidden.mk', [0n, 0n])]);

test('the decoders build the exact Lean constructor shapes from wire JSON', () => {
  assert.deepEqual(decodeSession(overviewJson, program), overview);
  assert.deepEqual(decodeSession(bareJson, program), bare);
  assert.deepEqual(decodeSessionPage(pageJson, program), ctor('Viewer.UI.SessionPage.mk', [[overview, bare], 57n]));
  assert.deepEqual(decodeMessage(conversationJson.messages[1]), conversation.fields[0][1]);
  assert.deepEqual(decodeConversation(conversationJson), conversation);
  assert.equal(program['Viewer.Harness.slug'](decodeSession(bareJson, program).fields[0].fields[0]), 'codex');
});

test('a bad shape throws an error naming the field', () => {
  assert.throws(() => decodeSession({ ...overviewJson, harness: 'gemini' }, program), { message: 'session.harness: unknown harness "gemini"' });
  assert.throws(() => decodeSession({ ...overviewJson, modifiedMs: '1' }, program), { message: 'session.modifiedMs: expected a non-negative integer, got "1"' });
  assert.throws(() => decodeSessionPage({ sessions: [overviewJson, { ...bareJson, id: 7 }], total: 2 }, program), { message: 'page.sessions[1].id: expected a string, got number' });
  assert.throws(() => decodeSessionPage({ sessions: [], total: -1 }, program), { message: /^page\.total: / });
  assert.throws(() => decodeConversation({ ...conversationJson, messages: [{ ...conversationJson.messages[0], role: 'tool' }] }), { message: 'conversation.messages[0].role: unknown role "tool"' });
  assert.throws(() => decodeMessage({ ...conversationJson.messages[1], parts: [{ type: 'toolCall', callId: '1', name: 'x', arguments: { raw: '{}' }, result: { value: 'v' } }] }),
    { message: 'message.parts[0].result.isError: expected a boolean, got undefined' });
  assert.throws(() => decodeMessage({ ...conversationJson.messages[0], status: { type: 'failed' } }), { message: 'message.status.error: expected a string, got undefined' });
  assert.throws(() => decodeMessage({ ...conversationJson.messages[0], parts: [{ type: 'image' }] }), { message: 'message.parts[0].url: expected a string, got undefined' });
  assert.throws(() => decodeMessage({ ...conversationJson.messages[0], parts: [{ type: 'video' }] }), { message: 'message.parts[0].type: unknown part "video"' });
  assert.throws(() => decodeConversation(null), { message: 'conversation: expected an object, got null' });
});

test('queryToSearch encodes harness, q, offset and limit, and omits harness when none', () => {
  assert.equal(queryToSearch(query(some(codex), 'lean react', 40n, 40n), program), '?harness=codex&q=lean%20react&offset=40&limit=40');
  assert.equal(queryToSearch(query(some(claude), 'a&b=c', 0n, 200n), program), '?harness=claude&q=a%26b%3Dc&offset=0&limit=200');
  assert.equal(queryToSearch(query(none, '', 0n, 40n), program), '?q=&offset=0&limit=40');
});

// A fetch double: a table from URL to [status, body]; problem bodies carry the problem+json type.
function fetchDouble(routes) {
  const calls = [];
  const fetchImpl = async (url, init) => {
    calls.push([url, init]);
    if (!Object.hasOwn(routes, url)) return new Response('not here', { status: 404, statusText: 'Not Found', headers: { 'content-type': 'text/plain' } });
    const [status, body] = routes[url];
    const problem = status >= 400;
    return new Response(typeof body === 'string' ? body : JSON.stringify(body), {
      status, headers: { 'content-type': problem ? 'application/problem+json' : 'application/json' },
    });
  };
  return { fetchImpl, calls };
}

test('the service answers Except.ok values and turns HTTP problems and bad bodies into Except.error', async () => {
  const base = 'http://loom.test';
  const { fetchImpl, calls } = fetchDouble({
    [`${base}/api/sessions?harness=claude&q=overview&offset=0&limit=40`]: [200, pageJson],
    [`${base}/api/sessions/claude/${overviewJson.id}`]: [200, conversationJson],
    [`${base}/api/sessions/codex/broken`]: [500, { type: 'about:blank', title: 'Internal Server Error', status: 500, detail: 'Loom could not import line 7: expected a JSON object' }],
    [`${base}/api/sessions/claude/odd`]: [200, { messages: [{ id: '1', role: 'user', parts: 'none', atMs: null, status: { type: 'complete' } }], sidechains: 0, importNotes: 0, hidden: { events: 0, redacted: 0 } }],
    [`${base}/api/sessions/claude/html`]: [200, '<html>'],
  });
  const service = createService(program, { fetchImpl, baseURL: base });
  assert.equal(service.tag, 'Viewer.UI.Service.mk');
  const [sessions, conversationOf] = service.fields;

  assert.deepEqual(await runAction(sessions(query(some(claude), 'overview', 0n, 40n))), ok(ctor('Viewer.UI.SessionPage.mk', [[overview, bare], 57n])));
  assert.equal(calls[0][0], `${base}/api/sessions?harness=claude&q=overview&offset=0&limit=40`);
  assert.deepEqual(await runAction(conversationOf(claude, overviewJson.id)), ok(conversation));
  assert.equal(calls[1][0], `${base}/api/sessions/claude/${overviewJson.id}`);

  const failed = await runAction(conversationOf(codex, 'broken'));
  assert.equal(failed.tag, 'Except.error');
  assert.equal(failed.fields[0], 'HTTP 500: Loom could not import line 7: expected a JSON object');
  assert.deepEqual(await runAction(conversationOf(claude, 'missing')), ctor('Except.error', ['HTTP 404 Not Found: not here']));
  assert.deepEqual(await runAction(conversationOf(claude, 'odd')), ctor('Except.error', ['conversation.messages[0].parts: expected an array, got "none"']));
  assert.deepEqual(await runAction(conversationOf(claude, 'html')), ctor('Except.error', ['/api/sessions/claude/html: the response is not JSON']));
  const offline = createService(program, { fetchImpl: async () => { throw new TypeError('fetch failed'); } });
  assert.deepEqual(await runAction(offline.fields[0](query(none, '', 0n, 40n))), ctor('Except.error', ['fetch failed']));
});

// A fake service that records every query and conversation request.
function fakeService() {
  const queries = [], asks = [];
  const service = ctor('Viewer.UI.Service.mk', [
    q => action(async () => { queries.push(q); return ok(ctor('Viewer.UI.SessionPage.mk', [[overview, bare], 2n])); }),
    (h, id) => action(async () => { asks.push([h, id]); return ok(conversation); }),
  ]);
  return { service, queries, asks };
}

async function mounted(element) {
  const warnings = [];
  const originalError = console.error;
  console.error = (...args) => warnings.push(args.map(String).join(' '));
  const container = document.createElement('div');
  document.body.append(container);
  const root = createRoot(container);
  await React.act(() => root.render(element));
  const settle = async (rounds = 4) => { for (let i = 0; i < rounds; i++) await React.act(() => new Promise(resolve => setTimeout(resolve, 0))); };
  return {
    container, warnings, settle,
    texts: selector => [...container.querySelectorAll(selector)].map(node => node.textContent),
    click: (selector, text) => React.act(() => [...container.querySelectorAll(selector)].find(node => text === undefined || node.textContent === text).click()),
    type: async text => {
      const input = container.querySelector('.search');
      const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
      await React.act(() => { setter.call(input, text); input.dispatchEvent(new window.Event('input', { bubbles: true })); });
    },
    close: async () => { try { await React.act(() => root.unmount()); container.remove(); } finally { console.error = originalError; } },
  };
}

test('the compiled app lists sessions, loads a conversation into the thread, and re-queries on chip and search', async () => {
  const { service, queries, asks } = fakeService();
  const f = await mounted(mountElement(program['Viewer.UI.App'], ctor('Viewer.UI.AppProps.mk', [service])));
  try {
    await f.settle();
    assert.deepEqual(queries.at(-1), query(none, '', 0n, program['Viewer.UI.pageSize']));
    assert.deepEqual(f.texts('.session-title'), ['Build a GREAT overview of the project', bareJson.id]);
    assert.deepEqual(f.texts('.session-meta'), ['Claude Code · leanreact · 2026-10-09 23:43 UTC', 'Codex CLI · no project · 2026-10-08 22:53 UTC']);
    assert.deepEqual(f.texts('.chip'), ['All', 'Claude Code', 'Codex CLI', 'Pi', 'Cursor Agent', 'Hermes']);
    assert.equal(f.texts('.chip.chosen')[0], 'All');
    assert.equal(f.texts('.pager .note')[0], '1–2 of 2');
    assert.equal(f.container.querySelector('.placeholder').textContent, 'Pick a conversation.');

    await f.click('.session');
    await f.settle();
    assert.deepEqual(asks, [[claude, overviewJson.id]]);
    assert.equal(f.container.querySelector('.session.chosen .session-title').textContent, 'Build a GREAT overview of the project');
    assert.equal(f.container.querySelector('.conversation-header h2').textContent, 'Build a GREAT overview of the project');
    assert.deepEqual(f.texts('.conversation-header .meta'), ['Claude Code · /Users/x/code/leanreact · claude-opus-4-1 · 12 turns', overviewJson.path]);
    assert.equal(f.texts('.conversation > .thread-area > .note')[0], '1 subagent thread is not shown yet.');
    const roles = [...f.container.querySelectorAll('.aui-message')].map(node => node.dataset.role);
    assert.deepEqual(roles, ['user', 'assistant', 'system']);
    assert.equal(f.container.querySelector('.aui-message[data-role="user"]').textContent, 'List the files.');
    assert.deepEqual(f.texts('.aui-message[data-role="assistant"] .aui-tool-name'), ['Bash', 'Read']);
    assert.equal(f.container.querySelector('.aui-tool-result').textContent, 'README.md\nlakefile.toml');
    assert.equal(f.container.querySelector('.aui-composer'), null, 'the viewer is read-only');

    const before = queries.length;
    await f.click('.chip', 'Codex CLI');
    await f.settle();
    assert.equal(queries.length, before + 1);
    assert.deepEqual(queries.at(-1), query(some(codex), '', 0n, 40n));
    assert.equal(f.texts('.chip.chosen')[0], 'Codex CLI');

    await f.type('overview');
    await f.settle();
    assert.deepEqual(queries.at(-1), query(some(codex), 'overview', 0n, 40n));
    assert.equal(f.container.querySelector('.search').value, 'overview');
    assert.deepEqual(f.warnings, []);
  } finally { await f.close(); }
});

test('a failing service shows its message as an alert', async () => {
  // One declared parameter per Lean argument: LeanJS applies host functions by their length.
  const service = ctor('Viewer.UI.Service.mk', [
    _query => action(async () => ctor('Except.error', ['HTTP 500: the store is unreadable'])),
    (_harness, _id) => action(async () => ctor('Except.error', ['unused'])),
  ]);
  const f = await mounted(mountElement(program['Viewer.UI.App'], ctor('Viewer.UI.AppProps.mk', [service])));
  try {
    await f.settle();
    assert.equal(f.container.querySelector('[role="alert"]').textContent, 'HTTP 500: the store is unreadable');
    assert.deepEqual(f.warnings, []);
  } finally { await f.close(); }
});

test('the app mounts under StrictMode without warnings', async () => {
  const { service } = fakeService();
  const f = await mounted(React.createElement(React.StrictMode, null,
    mountElement(program['Viewer.UI.App'], ctor('Viewer.UI.AppProps.mk', [service]))));
  try {
    await f.settle();
    assert.equal(f.texts('.session-title').length, 2);
    assert.deepEqual(f.warnings, []);
  } finally { await f.close(); }
});
