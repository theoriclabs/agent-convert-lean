// The browser half of CONTRACT.md: fetch the JSON the server writes (Viewer/Wire.lean) and build
// the Lean values `Viewer.UI` consumes. LeanJS ABI: a constructor is `{tag, fields}` in declaration
// order, `Nat` is a bigint, `Option` is `Option.some [v]` / `Option.none`, `Bool` is `Bool.true` /
// `Bool.false`, arrays are JS arrays. Harness values come from the compiled `Viewer.Harness.parse`,
// never from tags spelled here.
import { ctor } from '../../../leanreact/engine/adapters/leanjs-react.mjs';
import { action } from '../../../leanreact/engine/runtime/actions.mjs';

const some = value => ctor('Option.some', [value]);
const none = ctor('Option.none');
const bool = value => ctor(value ? 'Bool.true' : 'Bool.false');
const ok = value => ctor('Except.ok', [value]);
const error = message => ctor('Except.error', [message]);

// Decoders throw an Error naming the offending field; the service turns that into `Except.error`.
const describe = value => value === null ? 'null' : Array.isArray(value) ? 'an array' : typeof value === 'string' ? JSON.stringify(value) : typeof value;
const bad = (path, expected, value) => new Error(`${path}: expected ${expected}, got ${describe(value)}`);
const at = (path, name) => `${path}.${name}`;
const index = (path, i) => `${path}[${i}]`;

function object(value, path) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) throw bad(path, 'an object', value);
  return value;
}
function string(value, path) {
  if (typeof value !== 'string') throw bad(path, 'a string', value);
  return value;
}
function nat(value, path) {
  if (typeof value !== 'number' || !Number.isInteger(value) || value < 0) throw bad(path, 'a non-negative integer', value);
  return BigInt(value);
}
function boolean(value, path) {
  if (typeof value !== 'boolean') throw bad(path, 'a boolean', value);
  return bool(value);
}
function array(value, path) {
  if (!Array.isArray(value)) throw bad(path, 'an array', value);
  return value;
}
const optional = decode => (value, path) => value == null ? none : some(decode(value, path));
const optionalString = optional(string);
const optionalNat = optional(nat);

function harness(value, path, program) {
  const slug = string(value, path);
  const parsed = program['Viewer.Harness.parse'](slug);
  if (parsed.tag !== 'Option.some') throw new Error(`${path}: unknown harness ${JSON.stringify(slug)}`);
  return parsed.fields[0];
}

/** Session JSON → `Viewer.Session.mk [SessionFile.mk [harness, id, path, modifiedMs, bytes], Preview.mk [title?, cwd?, model?, startedMs?, turns]]`. */
export function decodeSession(json, program, path = 'session') {
  const s = object(json, path);
  const file = ctor('Viewer.SessionFile.mk', [
    harness(s.harness, at(path, 'harness'), program),
    string(s.id, at(path, 'id')),
    string(s.path, at(path, 'path')),
    nat(s.modifiedMs, at(path, 'modifiedMs')),
    nat(s.bytes, at(path, 'bytes')),
  ]);
  const preview = ctor('Viewer.Preview.mk', [
    optionalString(s.title, at(path, 'title')),
    optionalString(s.cwd, at(path, 'cwd')),
    optionalString(s.model, at(path, 'model')),
    optionalNat(s.startedMs, at(path, 'startedMs')),
    nat(s.turns, at(path, 'turns')),
    ctor(s.internal === true ? 'Bool.true' : 'Bool.false'),
  ]);
  return ctor('Viewer.Session.mk', [file, preview]);
}

/** `{"sessions":[…],"total":N}` → `Viewer.UI.SessionPage.mk [sessions, total]`. */
export function decodeSessionPage(json, program, path = 'page') {
  const page = object(json, path);
  const sessions = array(page.sessions, at(path, 'sessions')).map((s, i) => decodeSession(s, program, index(at(path, 'sessions'), i)));
  return ctor('Viewer.UI.SessionPage.mk', [sessions, nat(page.total, at(path, 'total'))]);
}

const roles = { user: 'AssistantUI.Role.user', assistant: 'AssistantUI.Role.assistant', system: 'AssistantUI.Role.system' };
function role(value, path) {
  const name = string(value, path);
  if (!Object.hasOwn(roles, name)) throw new Error(`${path}: unknown role ${JSON.stringify(name)}`);
  return ctor(roles[name]);
}

const plainStatuses = ['complete', 'running', 'cancelled', 'requiresAction'];
function status(value, path) {
  const s = object(value, path);
  const type = string(s.type, at(path, 'type'));
  if (plainStatuses.includes(type)) return ctor(`AssistantUI.MessageStatus.${type}`);
  if (type === 'failed') return ctor('AssistantUI.MessageStatus.failed', [string(s.error, at(path, 'error'))]);
  throw new Error(`${path}.type: unknown status ${JSON.stringify(type)}`);
}

function toolResult(value, path) {
  const r = object(value, path);
  return ctor('AssistantUI.ToolResult.mk', [string(r.value, at(path, 'value')), boolean(r.isError, at(path, 'isError'))]);
}

function part(value, path) {
  const p = object(value, path);
  const type = string(p.type, at(path, 'type'));
  switch (type) {
    case 'text': return ctor('AssistantUI.Part.text', [string(p.text, at(path, 'text'))]);
    case 'reasoning': return ctor('AssistantUI.Part.reasoning', [string(p.text, at(path, 'text'))]);
    case 'image': return ctor('AssistantUI.Part.image', [string(p.url, at(path, 'url'))]);
    case 'toolCall': return ctor('AssistantUI.Part.toolCall', [
      string(p.callId, at(path, 'callId')),
      string(p.name, at(path, 'name')),
      decodeArguments(p.arguments, at(path, 'arguments')),
      optional(toolResult)(p.result, at(path, 'result')),
    ]);
    default: throw new Error(`${path}.type: unknown part ${JSON.stringify(type)}`);
  }
}

/** Message JSON → `AssistantUI.Message.mk [id, role, parts, createdAtMs?, status]`. */
export function decodeMessage(json, path = 'message') {
  const m = object(json, path);
  return ctor('AssistantUI.Message.mk', [
    string(m.id, at(path, 'id')),
    role(m.role, at(path, 'role')),
    array(m.parts, at(path, 'parts')).map((p, i) => part(p, index(at(path, 'parts'), i))),
    optionalNat(m.atMs, at(path, 'atMs')),
    status(m.status, at(path, 'status')),
  ]);
}

/** `{raw}` or `{fields: [[key, value], …]}` → `AssistantUI.ToolArguments`. */
export function decodeArguments(json, path) {
  const a = object(json, path);
  if (typeof a.raw === 'string') return ctor('AssistantUI.ToolArguments.raw', [a.raw]);
  const fields = array(a.fields, at(path, 'fields')).map((pair, i) => {
    const entry = array(pair, index(at(path, 'fields'), i));
    return ctor('Prod.mk', [string(entry[0], index(at(path, 'fields'), i)), string(entry[1], index(at(path, 'fields'), i))]);
  });
  return ctor('AssistantUI.ToolArguments.fields', [fields]);
}

/** Conversation JSON → `Viewer.Conversation.mk [messages, sidechains, importNotes, Hidden.mk [events, redacted]]`. */
export function decodeConversation(json, path = 'conversation') {
  const c = object(json, path);
  return ctor('Viewer.Conversation.mk', [
    array(c.messages, at(path, 'messages')).map((m, i) => decodeMessage(m, index(at(path, 'messages'), i))),
    nat(c.sidechains, at(path, 'sidechains')),
    nat(c.importNotes, at(path, 'importNotes')),
    ctor('Viewer.Hidden.mk', [nat(object(c.hidden, at(path, 'hidden')).events, at(at(path, 'hidden'), 'events')),
      nat(object(c.hidden, at(path, 'hidden')).redacted, at(at(path, 'hidden'), 'redacted'))]),
  ]);
}

/** `Viewer.UI.Query.mk [harness?, text, offset, limit]` → `?harness=<slug>&q=<text>&offset=<n>&limit=<n>` (no `harness` when none). */
export function queryToSearch(query, program) {
  const [harnessOption, text, offset, limit] = query.fields;
  const pairs = [];
  if (harnessOption.tag === 'Option.some') pairs.push(['harness', program['Viewer.Harness.slug'](harnessOption.fields[0])]);
  pairs.push(['q', text], ['offset', String(offset)], ['limit', String(limit)]);
  return '?' + pairs.map(([name, value]) => `${name}=${encodeURIComponent(value)}`).join('&');
}

async function problemText(response) {
  const status = `HTTP ${response.status}${response.statusText ? ` ${response.statusText}` : ''}`;
  let body;
  try { body = await response.text(); } catch { return status; }
  try {
    const json = JSON.parse(body);
    const detail = json && typeof json === 'object' ? json.detail ?? json.title : null;
    return typeof detail === 'string' && detail ? `${status}: ${detail}` : status;
  } catch { return body ? `${status}: ${body.slice(0, 200)}` : status; }
}

/** `Viewer.UI.Service.mk [sessions, conversation]` over fetch. Each call resolves to `Except.ok value`
 * or `Except.error message` (an HTTP status with the problem detail, a decode failure naming its
 * field, or the transport error); nothing is thrown into the resource. */
export function createService(program, { fetchImpl = globalThis.fetch, baseURL = '' } = {}) {
  async function getJson(path) {
    const response = await fetchImpl(`${baseURL}${path}`, { headers: { accept: 'application/json' } });
    if (!response.ok) throw new Error(await problemText(response));
    const body = await response.text();
    try { return JSON.parse(body); } catch { throw new Error(`${path}: the response is not JSON`); }
  }
  const attempt = work => action(async () => {
    try { return ok(await work()); }
    catch (failure) { return error(failure instanceof Error ? failure.message : String(failure)); }
  });
  const sessions = query => attempt(async () => decodeSessionPage(await getJson(`/api/sessions${queryToSearch(query, program)}`), program));
  const conversation = (h, id) => attempt(async () =>
    decodeConversation(await getJson(`/api/sessions/${encodeURIComponent(program['Viewer.Harness.slug'](h))}/${encodeURIComponent(id)}`)));
  return ctor('Viewer.UI.Service.mk', [sessions, conversation]);
}
