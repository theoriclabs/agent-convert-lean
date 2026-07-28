#!/usr/bin/env node

import { createHash } from "node:crypto";
import {
  chmodSync,
  closeSync,
  existsSync,
  fstatSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  readdirSync,
  realpathSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { constants as fsConstants } from "node:fs";
import { basename, dirname, join, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const scriptPath = fileURLToPath(import.meta.url);
const scriptDir = dirname(scriptPath);
const loomRoot = resolve(scriptDir, "..");
const fixtureRoot = join(loomRoot, "testdata", "lifecycle");
const manifestPath = join(fixtureRoot, "manifest.v1.json");
const selfTestPath = join(scriptDir, "audit-lifecycle-matrix.self-test.mjs");
const utilsRoot = resolve(loomRoot, "..", "..");

export const SOURCE_NAMES = Object.freeze([
  "loom",
  "pi",
  "claude",
  "codex",
  "cursor-agent",
  "hermes",
  "gais",
  "cursor-ide",
]);

export const TARGET_NAMES = Object.freeze([
  "loom",
  "pi",
  "claude",
  "codex",
  "cursor-agent",
]);

function ownObject(entries = []) {
  const value = Object.create(null);
  for (const [key, item] of entries) value[key] = item;
  return value;
}

function deepFreeze(value) {
  if (value !== null && typeof value === "object" && !Object.isFrozen(value)) {
    for (const item of Object.values(value)) deepFreeze(item);
    Object.freeze(value);
  }
  return value;
}

export const TARGET_EXTENSIONS = deepFreeze(ownObject([
  ["loom", ".json"],
  ["pi", ".jsonl"],
  ["claude", ".jsonl"],
  ["codex", ".jsonl"],
  ["cursor-agent", ".jsonl"],
]));

const CLOSED_TARGET_LAUNCHES = deepFreeze(ownObject([
  ["loom", { kind: "none" }],
  ["pi", {
    kind: "pi-0.74.0",
    cwdPrefix: "/tmp/agent-convert-lifecycle-matrix",
    provider: "lifecycle-provider",
    model: "lifecycle-model",
    timestamp: "2026-07-21T12:34:56.000Z",
    harnessVersion: "0.74.0",
    assistantHistory: "carrier",
  }],
  ["claude", {
    kind: "claude-2.1.216",
    cwdPrefix: "/tmp/agent-convert-lifecycle-matrix",
    timestamp: "2026-07-21T12:34:56.000Z",
    harnessVersion: "2.1.216",
  }],
  ["codex", {
    kind: "codex-0.144.1",
    cwdPrefix: "/tmp/agent-convert-lifecycle-matrix",
    provider: "openai",
    model: "gpt-5.5",
    timestamp: "2026-07-21T12:34:56.000Z",
    harnessVersion: "0.144.1",
    approvalPolicy: "on-request",
    networkAccess: false,
    excludeTmpdirEnvVar: true,
    excludeSlashTmp: true,
    summary: "concise",
  }],
  ["cursor-agent", { kind: "none" }],
]));

const CLAUDE_PROTOCOL = "agent-convert.claude-carriers.v1";
const CLAUDE_CALL_HEADER =
  "[Historical tool call from source transcript; not executed by Claude]";
const CLAUDE_RESULT_HEADER =
  "[Historical tool result from source transcript; not executed by Claude]";
const CODEX_PROTOCOL = "agent-convert.codex-carriers.v1";
const CODEX_CALL_HEADER =
  "[Historical tool call from source transcript; not executed by Codex]";
const CODEX_RESULT_HEADER =
  "[Historical tool result from source transcript; not executed by Codex]";
const CURSOR_RUNTIME_ARCHIVE_ONLY_POLICY = "cursorRuntimeArchiveOnly";
const CURSOR_RUNTIME_ARCHIVE_ONLY_REASON = "turnEndedControl";
const CURSOR_NATIVE_PAYLOAD_PREFLIGHT =
  "Cursor Agent runtime target requires native user/assistant messages containing only text and exact imported tool_use blocks";
const CANONICAL_TOOL_NAMES = Object.freeze([
  "bash", "read", "write", "edit", "grep", "glob", "webFetch", "webSearch",
  "agentSpawn", "applyPatch",
]);
const MAX_BUFFER = 64 * 1024 * 1024;

class AuditError extends Error {}

function invariant(condition, message) {
  if (!condition) throw new AuditError(message);
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function hasOwn(object, key) {
  return isObject(object) && Object.hasOwn(object, key);
}

function exactKeys(object, keys) {
  if (!isObject(object)) return false;
  const actual = Object.keys(object).sort();
  const expected = [...keys].sort();
  return actual.length === expected.length &&
    actual.every((key, index) => key === expected[index]);
}

function exactOptionalKeys(object, required, optional = []) {
  if (!isObject(object) || !required.every((key) => hasOwn(object, key))) return false;
  const allowed = new Set([...required, ...optional]);
  return Object.keys(object).every((key) => allowed.has(key));
}

function nonemptyString(value) {
  return typeof value === "string" && value.length > 0;
}

function canonicalValue(value) {
  if (Array.isArray(value)) return value.map(canonicalValue);
  if (!isObject(value)) return value;
  const output = ownObject();
  for (const key of Object.keys(value).sort()) output[key] = canonicalValue(value[key]);
  return output;
}

export function canonicalJson(value) {
  return `${JSON.stringify(canonicalValue(value), null, 2)}\n`;
}

function compactCanonical(value) {
  return JSON.stringify(canonicalValue(value));
}

function jsonEqual(left, right) {
  if (Object.is(left, right)) return true;
  if (Array.isArray(left) || Array.isArray(right)) {
    return Array.isArray(left) && Array.isArray(right) &&
      left.length === right.length &&
      left.every((value, index) => jsonEqual(value, right[index]));
  }
  if (!isObject(left) || !isObject(right)) return false;
  const leftKeys = Object.keys(left).sort();
  const rightKeys = Object.keys(right).sort();
  return leftKeys.length === rightKeys.length &&
    leftKeys.every((key, index) => key === rightKeys[index] &&
      hasOwn(right, key) && jsonEqual(left[key], right[key]));
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function rejectDuplicateJsonMembers(text, context) {
  let index = 0;
  const fail = (message) => {
    throw new AuditError(`${context}: invalid JSON at byte ${index}: ${message}`);
  };
  const whitespace = () => {
    while (/\s/.test(text[index] ?? "")) index++;
  };
  const string = () => {
    const start = index;
    if (text[index++] !== '"') fail("expected string");
    while (index < text.length) {
      const code = text.charCodeAt(index);
      if (text[index] === '"') {
        index++;
        try {
          return JSON.parse(text.slice(start, index));
        } catch (error) {
          fail(error.message);
        }
      }
      if (code < 0x20) fail("control character in string");
      if (text[index] === "\\") {
        index++;
        const escape = text[index];
        if (escape === "u") {
          if (!/^[0-9a-fA-F]{4}$/.test(text.slice(index + 1, index + 5))) {
            fail("invalid Unicode escape");
          }
          index += 5;
          continue;
        }
        if (!'"\\/bfnrt'.includes(escape ?? "")) fail("invalid string escape");
      }
      index++;
    }
    fail("unterminated string");
  };
  const value = () => {
    whitespace();
    if (text[index] === '"') {
      string();
      return;
    }
    if (text[index] === "{") {
      index++;
      whitespace();
      const keys = new Set();
      if (text[index] === "}") {
        index++;
        return;
      }
      for (;;) {
        whitespace();
        if (text[index] !== '"') fail("expected object key");
        const key = string();
        if (keys.has(key)) {
          throw new AuditError(`${context}: duplicate JSON object member ${JSON.stringify(key)}`);
        }
        keys.add(key);
        whitespace();
        if (text[index++] !== ":") fail("expected colon");
        value();
        whitespace();
        if (text[index] === "}") {
          index++;
          return;
        }
        if (text[index++] !== ",") fail("expected object comma");
      }
    }
    if (text[index] === "[") {
      index++;
      whitespace();
      if (text[index] === "]") {
        index++;
        return;
      }
      for (;;) {
        value();
        whitespace();
        if (text[index] === "]") {
          index++;
          return;
        }
        if (text[index++] !== ",") fail("expected array comma");
      }
    }
    const rest = text.slice(index);
    const literal = rest.match(/^(?:true|false|null)/)?.[0];
    if (literal) {
      index += literal.length;
      return;
    }
    const number = rest.match(/^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/)?.[0];
    if (number) {
      index += number.length;
      return;
    }
    fail("invalid JSON value");
  };

  whitespace();
  value();
  whitespace();
  if (index !== text.length) fail("trailing JSON data");
}

export function parseJsonText(text, context = "JSON") {
  invariant(typeof text === "string", `${context}: JSON input must be text`);
  try {
    rejectDuplicateJsonMembers(text, context);
    const parsed = JSON.parse(text);
    const validateNumbers = (value, path) => {
      if (typeof value === "number") {
        invariant(Number.isFinite(value), `${context}: non-finite number at ${path}`);
      } else if (Array.isArray(value)) {
        value.forEach((item, index) => validateNumbers(item, `${path}[${index}]`));
      } else if (isObject(value)) {
        for (const key of Object.keys(value)) {
          validateNumbers(value[key], `${path}.${JSON.stringify(key)}`);
        }
      }
    };
    validateNumbers(parsed, "$");
    return parsed;
  } catch (error) {
    if (error instanceof AuditError) throw error;
    throw new AuditError(`${context}: invalid JSON: ${error.message}`);
  }
}

function parseJsonlText(text, context) {
  const rows = [];
  for (const [index, line] of text.split("\n").entries()) {
    if (!line.trim()) continue;
    rows.push(parseJsonText(line, `${context}:${index + 1}`));
  }
  invariant(rows.length > 0, `${context}: expected at least one JSONL record`);
  return rows;
}

function rawId(value) {
  if (value === undefined || value === null) return { kind: "missing" };
  invariant(nonemptyString(value), "tool ID must be a nonempty string when present");
  return { kind: "value", value };
}

function rawIdAt(object, key) {
  return rawId(hasOwn(object, key) ? object[key] : undefined);
}

function rawIdAlias(object, first, second) {
  const firstPresent = hasOwn(object, first) && object[first] !== null;
  const secondPresent = hasOwn(object, second) && object[second] !== null;
  if (firstPresent && secondPresent) {
    invariant(object[first] === object[second], `${first} and ${second} disagree`);
  }
  return rawId(firstPresent ? object[first] : secondPresent ? object[second] : undefined);
}

function idKey(id) {
  return id.kind === "value" ? `value:${id.value}` : "missing";
}

function textBlock(text) {
  invariant(typeof text === "string", "text block must contain a string");
  return { kind: "text", text };
}

function mediaBlock(mimeType, locator) {
  invariant(nonemptyString(mimeType), "media block must contain a MIME type");
  invariant(typeof locator === "string", "media block must contain a locator");
  return { kind: "media", mimeType, locator };
}

function unmodeledBlock(label, raw) {
  invariant(nonemptyString(label), "unmodeled block must contain a label");
  return { kind: "unmodeled", label, raw };
}

function nativeError(value) {
  invariant(typeof value === "boolean", "native error value must be boolean");
  return { provenance: "native", value };
}

function inferredError(value, heuristic) {
  invariant(typeof value === "boolean", "inferred error value must be boolean");
  invariant(nonemptyString(heuristic), "inferred error must name its heuristic");
  return { provenance: "inferred", value, heuristic };
}

function unrecordedError() {
  return { provenance: "unrecorded", value: null };
}

function rawCall(site, name, argumentsValue, id, disposition = "native") {
  invariant(nonemptyString(site), "call site must be nonempty");
  invariant(nonemptyString(name), "tool name must be nonempty");
  invariant(["native", "historicalUnverified"].includes(disposition),
    `unsupported disposition: ${disposition}`);
  return {
    kind: "call",
    site,
    rawId: id,
    rawName: name,
    arguments: argumentsValue,
    disposition,
  };
}

function rawResult(site, id, blocks, error, link, disposition = "native") {
  invariant(nonemptyString(site), "result site must be nonempty");
  invariant(Array.isArray(blocks), "result blocks must be an array");
  invariant(["native", "historicalUnverified"].includes(disposition),
    `unsupported disposition: ${disposition}`);
  return { kind: "result", site, rawId: id, blocks, error, link, disposition };
}

function resolvedSite(site, rawIdValue) {
  return { kind: "resolvedSite", site, rawId: rawIdValue };
}

function unresolvedLink(id, note) {
  invariant(typeof note === "string", "unresolved linkage note must be a string");
  return { kind: "unresolved", rawId: id, note };
}

export function finalizeLifecycle(rawEvents) {
  invariant(Array.isArray(rawEvents), "raw lifecycle must be an array");
  const callSites = new Map();
  const callIdsSeen = new Map();
  const resultIdsSeen = new Map();
  const events = [];
  let callOccurrence = 0;
  let resultOccurrence = 0;

  for (const [eventOrder, event] of rawEvents.entries()) {
    invariant(isObject(event), `raw lifecycle event ${eventOrder} must be an object`);
    if (event.kind === "call") {
      invariant(!callSites.has(event.site), `duplicate call site ${event.site}`);
      const key = idKey(event.rawId);
      const idOccurrence = callIdsSeen.get(key) ?? 0;
      callIdsSeen.set(key, idOccurrence + 1);
      const normalized = {
        kind: "call",
        eventOrder,
        callOccurrence,
        rawId: event.rawId,
        idOccurrence,
        rawName: event.rawName,
        arguments: event.arguments,
        disposition: event.disposition,
        state: "open-or-interrupted",
      };
      callSites.set(event.site, callOccurrence);
      events.push(normalized);
      callOccurrence++;
    } else if (event.kind === "result") {
      const key = idKey(event.rawId);
      const idOccurrence = resultIdsSeen.get(key) ?? 0;
      resultIdsSeen.set(key, idOccurrence + 1);
      let linkage;
      if (event.link.kind === "resolvedSite" && callSites.has(event.link.site)) {
        linkage = {
          kind: "resolved",
          callOccurrence: callSites.get(event.link.site),
          rawId: event.link.rawId,
        };
      } else if (event.link.kind === "resolvedSite") {
        linkage = {
          kind: "unresolved",
          rawId: event.link.rawId,
          note: `no earlier call at target occurrence ${event.link.site}`,
        };
      } else {
        linkage = event.link;
      }
      events.push({
        kind: "result",
        eventOrder,
        resultOccurrence,
        rawId: event.rawId,
        idOccurrence,
        blocks: event.blocks,
        error: event.error,
        linkage,
        disposition: event.disposition,
      });
      resultOccurrence++;
    } else {
      throw new AuditError(`unsupported raw lifecycle event kind: ${event.kind}`);
    }
  }

  const calls = events.filter((event) => event.kind === "call");
  for (const result of events.filter((event) => event.kind === "result")) {
    if (result.linkage.kind === "resolved") {
      const call = calls[result.linkage.callOccurrence];
      if (call) call.state = "closed";
    }
  }
  return { events };
}

function callCandidates(state, id, name, matchName) {
  return state.calls.filter((call) => !state.matched.has(call.site) &&
    jsonEqual(call.rawId, id) && (!matchName || call.rawName === name));
}

function resolvePrior(state, id, name, context, matchName = false) {
  const candidates = callCandidates(state, id, name, matchName);
  if (candidates.length === 1) {
    state.matched.add(candidates[0].site);
    return resolvedSite(candidates[0].site, id);
  }
  return unresolvedLink(id, candidates.length === 0
    ? `${context}: no unmatched earlier call occurrence`
    : `${context}: multiple unmatched earlier call occurrences`);
}

function parseWireBlock(block, context) {
  invariant(isObject(block), `${context}: expected block object`);
  if (block.type === "text") return textBlock(block.text);
  if (block.type === "media") return mediaBlock(block.mimeType, block.data);
  if (block.type === "unmodeled") return unmodeledBlock(block.label, block.raw);
  return unmodeledBlock(nonemptyString(block.type) ? block.type : "unknown", block);
}

function parseWireError(error, context) {
  invariant(isObject(error), `${context}: expected error object`);
  const value = error.isError === "true" ? true : error.isError === "false" ? false : null;
  if (error.kind === "native") {
    invariant(value !== null, `${context}: native isError must be true or false`);
    return nativeError(value);
  }
  if (error.kind === "inferred") {
    invariant(value !== null, `${context}: inferred isError must be true or false`);
    return inferredError(value, error.heuristic);
  }
  if (error.kind === "unrecorded") return unrecordedError();
  throw new AuditError(`${context}: unsupported error kind ${error.kind}`);
}

export function parseWireLifecycle(text, context = "Loom wire") {
  const root = parseJsonText(text, context);
  invariant(isObject(root) && root.schema === "loom.transcript.v0",
    `${context}: expected loom.transcript.v0`);
  invariant(Array.isArray(root.entries), `${context}: entries must be an array`);
  const rawEvents = [];
  const callIds = new Map();
  const idProvenanceEvidence = [];
  let callOccurrence = 0;
  for (const [entryIndex, entry] of root.entries.entries()) {
    invariant(isObject(entry) && Number(entry.index) === entryIndex,
      `${context}: entry ${entryIndex} has an invalid index`);
    const disposition = entry.disposition ?? "native";
    invariant(["native", "historicalUnverified"].includes(disposition),
      `${context}: invalid entry disposition`);
    const payload = entry.payload;
    if (!isObject(payload) || !Array.isArray(payload.blocks)) continue;
    for (const [blockIndex, block] of payload.blocks.entries()) {
      const site = `${entryIndex}:${blockIndex}`;
      if (payload.type === "assistantMsg" && block?.type === "toolCall") {
        invariant(nonemptyString(block.name) && hasOwn(block, "arguments"),
          `${context}: malformed wire toolCall at ${site}`);
        const id = rawIdAt(block, "id");
        rawEvents.push(rawCall(site, block.name, block.arguments, id, disposition));
        callIds.set(site, id);
        const origin = entry.origin;
        const rawBubble = origin?.extras?.rawBubble;
        const cursorTool = rawBubble?.toolFormerData;
        if (origin?.format === "cursor-ide" && isObject(rawBubble) &&
            rawBubble.type === 2 && nonemptyString(rawBubble.bubbleId) &&
            origin.sourceRef === `bubble:${rawBubble.bubbleId}` &&
            isObject(cursorTool) && cursorTool.name === block.name &&
            jsonEqual(hasOwn(cursorTool, "rawArgs") ? cursorTool.rawArgs
              : hasOwn(cursorTool, "params") ? cursorTool.params : {}, block.arguments)) {
          idProvenanceEvidence.push({
            callOccurrence,
            sourceFormat: "cursor-ide",
            carrier: "loom.transcript.v0:origin.extras.rawBubble.toolFormerData.toolCallId",
            sourceRawId: rawIdAt(cursorTool, "toolCallId"),
            targetRawId: id,
            reversible: true,
            semanticUse: "evidence-only",
          });
        }
        const rawRecord = origin?.extras?.rawRecord;
        const sourceBlock = rawRecord?.message?.content?.[blockIndex];
        if (origin?.format === "cursor-agent" && isObject(rawRecord) &&
            sourceBlock?.type === "tool_use" && sourceBlock.name === block.name &&
            jsonEqual(sourceBlock.input, block.arguments)) {
          idProvenanceEvidence.push({
            callOccurrence,
            sourceFormat: "cursor-agent",
            carrier: "loom.transcript.v0:origin.extras.rawRecord.message.content",
            sourceRawId: rawIdAt(sourceBlock, "id"),
            targetRawId: id,
            reversible: true,
            semanticUse: "evidence-only",
          });
        }
        callOccurrence++;
      } else if (payload.type === "envMsg" && block?.type === "toolResult") {
        invariant(Array.isArray(block.content) && isObject(block.call),
          `${context}: malformed wire toolResult at ${site}`);
        let link;
        let id;
        if (block.call.kind === "resolved") {
          const target = `${Number(block.call.entry)}:${Number(block.call.block)}`;
          id = callIds.get(target) ?? { kind: "missing" };
          link = resolvedSite(target, id);
        } else if (block.call.kind === "unresolved") {
          id = rawIdAt(block.call, "rawId");
          link = unresolvedLink(id, block.call.note ?? "");
        } else {
          throw new AuditError(`${context}: invalid wire call reference at ${site}`);
        }
        rawEvents.push(rawResult(site, id,
          block.content.map((value, index) => parseWireBlock(value,
            `${context}: entry ${entryIndex} result block ${index}`)),
          parseWireError(block.error, `${context}: entry ${entryIndex} error`),
          link, disposition));
      }
    }
  }
  return { ...finalizeLifecycle(rawEvents), idProvenanceEvidence };
}

function parsePiUserBlock(block, context) {
  invariant(isObject(block), `${context}: expected block object`);
  if (block.type === "text") {
    const stamp = block.loomPi;
    if (exactKeys(stamp,
      ["author", "constructor", "kind", "label", "raw", "version"]) &&
        stamp.version === 1 && stamp.kind === "block" && stamp.author === "user" &&
        stamp.constructor === "unmodeled" && typeof stamp.label === "string") {
      return unmodeledBlock(stamp.label, stamp.raw);
    }
    return textBlock(block.text);
  }
  if (block.type === "image") return mediaBlock(block.mimeType, block.data);
  throw new AuditError(`${context}: unsupported Pi user block ${block.type}`);
}

function parsePiCarrierError(error) {
  if (!isObject(error)) return null;
  if (exactKeys(error, ["state", "value"]) && error.state === "native") {
    return typeof error.value === "boolean" ? nativeError(error.value) : null;
  }
  if (exactKeys(error, ["heuristic", "state", "value"]) &&
      error.state === "inferred" && typeof error.value === "boolean" &&
      nonemptyString(error.heuristic)) {
    return inferredError(error.value, error.heuristic);
  }
  if (exactKeys(error, ["state"]) && error.state === "unrecorded") {
    return unrecordedError();
  }
  return null;
}

function piCarrierData(row) {
  if (row?.type !== "custom" || row.customType !== "loom.pi.carrier") return null;
  if (!exactKeys(row.data, ["kind", "value", "version"]) || row.data.version !== 1 ||
      !nonemptyString(row.data.kind) || !isObject(row.data.value)) return null;
  return row.data;
}

function exactPiCarrierSession(row) {
  const stamp = row?.loomPi;
  return row?.type === "session" && row.version === 3 && nonemptyString(row.id) &&
    exactKeys(stamp, ["cwd", "sessionId", "sourceEnvironment", "targetHarnessVersion",
      "targetOptions", "timestamp", "version"]) && stamp.version === 1 &&
    nonemptyString(stamp.cwd) && nonemptyString(stamp.sessionId) &&
    isObject(stamp.sourceEnvironment) && nonemptyString(stamp.targetHarnessVersion) &&
    isObject(stamp.targetOptions) && nonemptyString(stamp.timestamp);
}

function parsePiHistoricalAssistant(data, state, semanticIndex) {
  const value = data.value;
  if (!exactKeys(value,
    ["blocks", "representation", "scope", "sourceBlockIndices", "sourceEntry"]) ||
      value.representation !== "historical-assistant-blocks" ||
      value.scope !== "full" || !Array.isArray(value.blocks) ||
      !Array.isArray(value.sourceBlockIndices) ||
      value.blocks.length !== value.sourceBlockIndices.length ||
      !Number.isInteger(value.sourceEntry)) return false;
  const staged = [];
  for (const [index, block] of value.blocks.entries()) {
    if (!isObject(block) || block.kind !== "toolCall") continue;
    if (!exactKeys(block, ["arguments", "canonical", "kind", "name", "rawId"]) ||
        !nonemptyString(block.name) ||
        !(block.rawId === null || nonemptyString(block.rawId)) ||
        !(block.canonical === null || nonemptyString(block.canonical)) ||
        !Number.isInteger(value.sourceBlockIndices[index])) return false;
    const site = `coord:${value.sourceEntry}:${value.sourceBlockIndices[index]}`;
    staged.push(rawCall(site, block.name, block.arguments, rawId(block.rawId),
      "historicalUnverified"));
  }
  for (const event of staged) {
    state.events.push(event);
    state.calls.push(event);
  }
  state.semanticIndex = Math.max(state.semanticIndex, semanticIndex + 1);
  return true;
}

function parsePiHistoricalResult(data, state, semanticIndex) {
  const value = data.value;
  if (!exactKeys(value,
    ["call", "content", "error", "toolCallId", "toolName"]) ||
      !isObject(value.call) || !Array.isArray(value.content) ||
      !nonemptyString(value.toolCallId) || !nonemptyString(value.toolName)) return false;
  const error = parsePiCarrierError(value.error);
  if (!error) return false;
  let link;
  if (exactKeys(value.call, ["sourceBlock", "sourceEntry", "state"]) &&
      value.call.state === "resolved" && Number.isInteger(value.call.sourceEntry) &&
      Number.isInteger(value.call.sourceBlock)) {
    const site = `coord:${value.call.sourceEntry}:${value.call.sourceBlock}`;
    const referencedCall = state.calls.find((call) => call.site === site);
    const resultId = rawId(value.toolCallId);
    if (!referencedCall || referencedCall.rawName !== value.toolName ||
        !jsonEqual(referencedCall.rawId, resultId)) return false;
    link = resolvedSite(site, resultId);
  } else if (exactKeys(value.call, ["note", "rawId", "state"]) &&
      value.call.state === "unresolved" && typeof value.call.note === "string") {
    link = unresolvedLink(rawId(value.call.rawId), value.call.note);
  } else return false;
  let blocks;
  try {
    blocks = value.content.map((block, index) =>
      parsePiUserBlock(block, `Pi carrier result block ${index}`));
  } catch {
    return false;
  }
  state.events.push(rawResult(`pi-carrier-result:${semanticIndex}`,
    rawId(value.toolCallId), blocks, error, link, "historicalUnverified"));
  state.semanticIndex = Math.max(state.semanticIndex, semanticIndex + 1);
  return true;
}

function parsePiRows(rows, allowTargetCarriers, context) {
  const state = { events: [], calls: [], matched: new Set(), semanticIndex: 0 };
  const carrierSession = allowTargetCarriers && exactPiCarrierSession(rows[0]);
  for (const [rowIndex, row] of rows.entries()) {
    invariant(isObject(row), `${context}: row ${rowIndex + 1} must be an object`);
    if (carrierSession) {
      const carrier = piCarrierData(row);
      if (carrier?.kind === "assistantMessage" &&
          parsePiHistoricalAssistant(carrier, state, state.semanticIndex)) continue;
      if (carrier?.kind === "toolResult" &&
          parsePiHistoricalResult(carrier, state, state.semanticIndex)) continue;
    }
    if (row.type !== "message" || !isObject(row.message)) continue;
    const message = row.message;
    if (message.role === "assistant") {
      invariant(Array.isArray(message.content), `${context}: assistant content must be an array`);
      for (const [blockIndex, block] of message.content.entries()) {
        if (block?.type !== "toolCall") continue;
        invariant(nonemptyString(block.id) && nonemptyString(block.name) &&
          hasOwn(block, "arguments") && isObject(block.arguments),
        `${context}: malformed native Pi toolCall`);
        const event = rawCall(`native:${rowIndex}:${blockIndex}`, block.name,
          block.arguments, rawId(block.id));
        state.events.push(event);
        state.calls.push(event);
      }
      state.semanticIndex++;
    } else if (message.role === "toolResult") {
      invariant(nonemptyString(message.toolCallId) && nonemptyString(message.toolName) &&
        Array.isArray(message.content) && typeof message.isError === "boolean",
      `${context}: malformed native Pi toolResult`);
      const id = rawId(message.toolCallId);
      const link = resolvePrior(state, id, message.toolName, "Pi toolResult", true);
      state.events.push(rawResult(`native-result:${rowIndex}`, id,
        message.content.map((block, index) => parsePiUserBlock(block,
          `${context}: result block ${index}`)), nativeError(message.isError), link));
      state.semanticIndex++;
    } else {
      state.semanticIndex++;
    }
  }
  return finalizeLifecycle(state.events);
}

function parseClaudeImage(block) {
  const source = block?.source;
  if (!isObject(source)) return null;
  if (source.type === "base64" && nonemptyString(source.media_type) &&
      nonemptyString(source.data)) {
    return mediaBlock(source.media_type,
      `data:${source.media_type};base64,${source.data}`);
  }
  if (source.type === "url" && nonemptyString(source.url)) {
    return mediaBlock("image", source.url);
  }
  if (source.type === "file" && nonemptyString(source.file_id)) {
    return mediaBlock("image", `claude-file:${source.file_id}`);
  }
  return null;
}

function parseClaudeResultBlock(block) {
  if (block?.type === "text" && typeof block.text === "string") return textBlock(block.text);
  if (block?.type === "image") return parseClaudeImage(block) ?? unmodeledBlock("image", block);
  return unmodeledBlock(nonemptyString(block?.type) ? block.type : "tool_result_item", block);
}

function exactHistoricalBlock(block) {
  if (!isObject(block) || !nonemptyString(block.kind)) return null;
  if (block.kind === "text" && exactKeys(block, ["kind", "text"]) &&
      typeof block.text === "string") return textBlock(block.text);
  if (block.kind === "media" && exactKeys(block,
    ["kind", "locator", "mimeType"]) && typeof block.locator === "string" &&
      nonemptyString(block.mimeType)) return mediaBlock(block.mimeType, block.locator);
  if (block.kind === "unmodeled" && exactKeys(block,
    ["kind", "label", "raw"]) && nonemptyString(block.label)) {
    return unmodeledBlock(block.label, block.raw);
  }
  return null;
}

function exactCarrierError(error) {
  if (!isObject(error)) return null;
  if (error.kind === "native" && exactKeys(error, ["isError", "kind"]) &&
      typeof error.isError === "boolean") return nativeError(error.isError);
  if (error.kind === "inferred" && exactKeys(error,
    ["heuristic", "isError", "kind"]) && typeof error.isError === "boolean" &&
      nonemptyString(error.heuristic)) return inferredError(error.isError, error.heuristic);
  if (error.kind === "unrecorded" && exactKeys(error, ["kind"])) {
    return unrecordedError();
  }
  return null;
}

function parseCarrierJson(text, header) {
  if (typeof text !== "string" || !text.startsWith(`${header}\n`)) return null;
  try {
    const parsed = parseJsonText(text.slice(header.length + 1), `${header} carrier`);
    return isObject(parsed) ? parsed : null;
  } catch {
    return null;
  }
}

function exactClaudeCallCarrier(text) {
  const carrier = parseCarrierJson(text, CLAUDE_CALL_HEADER);
  if (!exactKeys(carrier,
    ["arguments", "canonical", "carrier", "id", "name", "occurrence", "reason"]) ||
      carrier.carrier !== "agent-convert.claude-tool-call.v1" ||
      !nonemptyString(carrier.name) || !nonemptyString(carrier.occurrence) ||
      !nonemptyString(carrier.reason) ||
      !(carrier.id === null || nonemptyString(carrier.id)) ||
      !(carrier.canonical === null || nonemptyString(carrier.canonical))) return null;
  return carrier;
}

function exactCarrierCallRef(call) {
  if (!isObject(call)) return null;
  if (call.kind === "resolved" && exactKeys(call,
    ["kind", "occurrence", "rawId"]) && nonemptyString(call.occurrence) &&
      (call.rawId === null || nonemptyString(call.rawId))) {
    return { kind: "resolved", occurrence: call.occurrence, rawId: rawId(call.rawId) };
  }
  if (call.kind === "unresolved" && exactKeys(call,
    ["kind", "note", "rawId"]) && typeof call.note === "string" &&
      (call.rawId === null || nonemptyString(call.rawId))) {
    return { kind: "unresolved", rawId: rawId(call.rawId), note: call.note };
  }
  return null;
}

function exactClaudeResultCarrier(text) {
  const carrier = parseCarrierJson(text, CLAUDE_RESULT_HEADER);
  if (!exactKeys(carrier,
    ["call", "carrier", "content", "error", "id", "occurrence"]) ||
      carrier.carrier !== "agent-convert.claude-tool-result.v1" ||
      !Array.isArray(carrier.content) || !nonemptyString(carrier.occurrence) ||
      !(carrier.id === null || nonemptyString(carrier.id))) return null;
  const call = exactCarrierCallRef(carrier.call);
  const error = exactCarrierError(carrier.error);
  const blocks = carrier.content.map(exactHistoricalBlock);
  if (!call || !error || blocks.some((block) => block === null)) return null;
  return { carrier, call, error, blocks };
}

function claudeMarker(row) {
  const marker = row?._agent_convert;
  return isObject(marker) && marker.protocol === CLAUDE_PROTOCOL ? marker : null;
}

function parseHistoricalAssistantPayload(payload, sourceEntry, state) {
  if (!isObject(payload) || payload.kind !== "assistantMsg" || !Array.isArray(payload.blocks)) {
    return false;
  }
  const staged = [];
  for (const [blockIndex, block] of payload.blocks.entries()) {
    if (block?.kind !== "toolCall") continue;
    if (!exactKeys(block, ["arguments", "canonical", "kind", "name", "rawId"]) ||
        !nonemptyString(block.name) ||
        !(block.rawId === null || nonemptyString(block.rawId)) ||
        !(block.canonical === null || nonemptyString(block.canonical))) return false;
    staged.push(rawCall(`coord:${sourceEntry}:${blockIndex}`, block.name,
      block.arguments, rawId(block.rawId), "historicalUnverified"));
  }
  for (const event of staged) {
    state.events.push(event);
    state.calls.push(event);
  }
  return true;
}

function parseHistoricalEnvPayload(payload, sourceEntry, state) {
  if (!isObject(payload) || payload.kind !== "envMsg" || !Array.isArray(payload.blocks)) {
    return false;
  }
  const staged = [];
  for (const [blockIndex, block] of payload.blocks.entries()) {
    if (block?.kind !== "toolResult") continue;
    if (!exactKeys(block, ["call", "content", "error", "kind"]) ||
        !Array.isArray(block.content)) return false;
    const call = exactCarrierCallRef(block.call);
    const error = exactCarrierError(block.error);
    const blocks = block.content.map(exactHistoricalBlock);
    if (!call || !error || blocks.some((value) => value === null)) return false;
    const id = call.rawId;
    const link = call.kind === "resolved"
      ? resolvedSite(`coord:${call.occurrence}`, call.rawId)
      : unresolvedLink(call.rawId, call.note);
    staged.push(rawResult(`coord:${sourceEntry}:${blockIndex}`, id,
      blocks, error, link, "historicalUnverified"));
  }
  state.events.push(...staged);
  return true;
}

function parseClaudeRows(rows, allowTargetCarriers, context) {
  const state = { events: [], calls: [], matched: new Set(), semanticIndex: 0 };
  for (const [rowIndex, row] of rows.entries()) {
    invariant(isObject(row), `${context}: row ${rowIndex + 1} must be an object`);
    const marker = allowTargetCarriers ? claudeMarker(row) : null;
    if (marker && exactKeys(marker.inertPayload, ["carrier", "payload"]) &&
        marker.inertPayload.carrier === "agent-convert.claude-inert-payload.v1") {
      const payload = marker.inertPayload.payload;
      const parsed = parseHistoricalAssistantPayload(payload, state.semanticIndex, state) ||
        parseHistoricalEnvPayload(payload, state.semanticIndex, state) ||
        (isObject(payload) && ["userMsg", "event", "otherMsg", "compaction"].includes(payload.kind));
      if (parsed) {
        state.semanticIndex++;
        continue;
      }
    }
    const content = Array.isArray(row.message?.content)
      ? row.message.content
      : typeof row.message?.content === "string"
        ? [{ type: "text", text: row.message.content }]
        : [];
    let semantic = row.type === "assistant" || row.type === "user";
    for (const [blockIndex, block] of content.entries()) {
      const stamped = marker && Array.isArray(marker.contentBlocks) &&
        marker.contentBlocks.every(Number.isInteger) &&
        marker.contentBlocks.includes(blockIndex);
      if (allowTargetCarriers && stamped && block?.type === "text") {
        const callCarrier = exactClaudeCallCarrier(block.text);
        if (callCarrier) {
          const event = rawCall(`coord:${callCarrier.occurrence}`, callCarrier.name,
            callCarrier.arguments, rawId(callCarrier.id), "historicalUnverified");
          state.events.push(event);
          state.calls.push(event);
          continue;
        }
        const resultCarrier = exactClaudeResultCarrier(block.text);
        if (resultCarrier) {
          const id = rawId(resultCarrier.carrier.id);
          const link = resultCarrier.call.kind === "resolved"
            ? resolvedSite(`coord:${resultCarrier.call.occurrence}`, resultCarrier.call.rawId)
            : unresolvedLink(resultCarrier.call.rawId, resultCarrier.call.note);
          state.events.push(rawResult(`claude-carrier-result:${rowIndex}:${blockIndex}`,
            id, resultCarrier.blocks, resultCarrier.error, link,
            "historicalUnverified"));
          continue;
        }
      }
      if (row.type === "assistant" && block?.type === "tool_use") {
        invariant(nonemptyString(block.id) && nonemptyString(block.name) &&
          isObject(block.input), `${context}: malformed native Claude tool_use`);
        const event = rawCall(`native:${rowIndex}:${blockIndex}`, block.name,
          block.input, rawId(block.id));
        state.events.push(event);
        state.calls.push(event);
      } else if (row.type === "user" && block?.type === "tool_result") {
        invariant(nonemptyString(block.tool_use_id) && typeof block.is_error === "boolean",
          `${context}: malformed native Claude tool_result`);
        const id = rawId(block.tool_use_id);
        const resultContent = typeof block.content === "string"
          ? [textBlock(block.content)]
          : Array.isArray(block.content) ? block.content.map(parseClaudeResultBlock)
            : hasOwn(block, "content") ? [unmodeledBlock("tool_result_content", block.content)] : [];
        state.events.push(rawResult(`native-result:${rowIndex}:${blockIndex}`, id,
          resultContent, nativeError(block.is_error),
          resolvePrior(state, id, null, "Claude tool_result")));
      }
    }
    if (semantic) state.semanticIndex++;
  }
  return finalizeLifecycle(state.events);
}

function codexOutputIndicatesError(blocks) {
  const text = blocks.filter((block) => block.kind === "text")
    .map((block) => block.text).join("");
  const lower = text.toLowerCase();
  return /Process exited with code [1-9]/.test(text) ||
    lower.includes("timed out after") || lower.includes("command timed out") ||
    (lower.includes("timeout") && ["exceeded", "expired", "limit"]
      .some((part) => lower.includes(part)));
}

function parseCodexOutput(value, context) {
  if (typeof value === "string") return [textBlock(value)];
  if (!Array.isArray(value)) return [unmodeledBlock("tool_output", value)];
  return value.map((item, index) => {
    if (isObject(item) && ["input_text", "output_text", "text"].includes(item.type) &&
        typeof item.text === "string") return textBlock(item.text);
    if (item?.type === "input_image" && nonemptyString(item.image_url)) {
      return mediaBlock("image", item.image_url);
    }
    return unmodeledBlock(nonemptyString(item?.type) ? item.type : "tool_output_item",
      item, `${context}:${index}`);
  });
}

function parseCodexCallPayload(payload, context) {
  if (!isObject(payload)) return null;
  if (payload.type === "function_call") {
    invariant(nonemptyString(payload.call_id) && nonemptyString(payload.name),
      `${context}: malformed function_call`);
    let argumentsValue;
    if (typeof payload.arguments === "string") {
      argumentsValue = parseJsonText(payload.arguments, `${context}.arguments`);
    } else {
      invariant(isObject(payload.arguments), `${context}: malformed function_call arguments`);
      argumentsValue = payload.arguments;
    }
    return { id: rawId(payload.call_id), name: payload.name, arguments: argumentsValue };
  }
  if (payload.type === "custom_tool_call") {
    invariant(nonemptyString(payload.call_id) && nonemptyString(payload.name) &&
      typeof payload.input === "string", `${context}: malformed custom_tool_call`);
    const key = payload.name === "apply_patch" ? "patch" : "input";
    return { id: rawId(payload.call_id), name: payload.name,
      arguments: { [key]: payload.input } };
  }
  return null;
}

function exactCodexCallCarrier(text) {
  const carrier = parseCarrierJson(text, CODEX_CALL_HEADER);
  if (!exactKeys(carrier,
    ["arguments", "canonical", "carrier", "id", "name", "occurrence", "reason"]) ||
      carrier.carrier !== "agent-convert.codex-tool-call.v2" ||
      !nonemptyString(carrier.name) || !nonemptyString(carrier.occurrence) ||
      !nonemptyString(carrier.reason) ||
      !(carrier.id === null || nonemptyString(carrier.id)) ||
      !(carrier.canonical === null || nonemptyString(carrier.canonical))) return null;
  return carrier;
}

function exactCodexResultCarrier(text) {
  const carrier = parseCarrierJson(text, CODEX_RESULT_HEADER);
  if (!exactKeys(carrier, ["call", "carrier", "content", "error", "errorProvenance",
    "id", "isError", "occurrence", "output"]) ||
      carrier.carrier !== "agent-convert.codex-tool-result.v1" ||
      !Array.isArray(carrier.content) || !nonemptyString(carrier.occurrence) ||
      !(carrier.id === null || nonemptyString(carrier.id)) ||
      typeof carrier.output !== "string") return null;
  const call = exactCarrierCallRef(carrier.call);
  const error = exactCarrierError(carrier.error);
  const blocks = carrier.content.map(exactHistoricalBlock);
  if (!call || !error || blocks.some((block) => block === null)) return null;
  const expectedProvenance = error.provenance === "native" ? "native"
    : error.provenance === "unrecorded" ? "unrecorded"
      : `inferred: ${error.heuristic}`;
  const expectedValue = error.provenance === "unrecorded" ? null : error.value;
  if (carrier.errorProvenance !== expectedProvenance || carrier.isError !== expectedValue) {
    return null;
  }
  return { carrier, call, error, blocks };
}

function exactCodexItemStamp(payload, kind) {
  return isObject(payload?._agent_convert) &&
    exactKeys(payload._agent_convert, ["kind", "protocol"]) &&
    payload._agent_convert.protocol === CODEX_PROTOCOL &&
    payload._agent_convert.kind === kind;
}

function parseCodexRows(rows, allowTargetCarriers, context) {
  const first = rows[0]?.type === "session_meta" ? rows[0] : null;
  const sessionStamp = first?.payload?._agent_convert;
  const carrierSession = allowTargetCarriers &&
    exactKeys(sessionStamp, ["kind", "protocol"]) &&
    sessionStamp.kind === "session" && sessionStamp.protocol === CODEX_PROTOCOL;
  const state = { events: [], calls: [], matched: new Set() };
  for (const [rowIndex, row] of rows.entries()) {
    if (row?.type !== "response_item" || !isObject(row.payload)) continue;
    const payload = row.payload;
    if (carrierSession && payload.type === "message" && payload.role === "assistant" &&
        Array.isArray(payload.content) && payload.content.length === 1 &&
        payload.content[0]?.type === "output_text") {
      const text = payload.content[0].text;
      if (exactCodexItemStamp(payload, "tool_call")) {
        const carrier = exactCodexCallCarrier(text);
        if (carrier) {
          const event = rawCall(`coord:${carrier.occurrence}`, carrier.name,
            carrier.arguments, rawId(carrier.id), "historicalUnverified");
          state.events.push(event);
          state.calls.push(event);
          continue;
        }
      }
      if (exactCodexItemStamp(payload, "tool_result")) {
        const parsed = exactCodexResultCarrier(text);
        if (parsed) {
          const id = rawId(parsed.carrier.id);
          const link = parsed.call.kind === "resolved"
            ? resolvedSite(`coord:${parsed.call.occurrence}`, parsed.call.rawId)
            : unresolvedLink(parsed.call.rawId, parsed.call.note);
          state.events.push(rawResult(`codex-carrier-result:${rowIndex}`, id,
            parsed.blocks, parsed.error, link, "historicalUnverified"));
          continue;
        }
      }
    }
    const call = parseCodexCallPayload(payload, `${context}: row ${rowIndex + 1}`);
    if (call) {
      const event = rawCall(`native:${rowIndex}`, call.name, call.arguments, call.id);
      state.events.push(event);
      state.calls.push(event);
    } else if (["function_call_output", "custom_tool_call_output"].includes(payload.type)) {
      invariant(nonemptyString(payload.call_id) && hasOwn(payload, "output"),
        `${context}: malformed ${payload.type}`);
      const id = rawId(payload.call_id);
      const blocks = parseCodexOutput(payload.output, `${context}: row ${rowIndex + 1}`);
      state.events.push(rawResult(`native-result:${rowIndex}`, id, blocks,
        inferredError(codexOutputIndicatesError(blocks),
          "codexOutputIndicatesError (codexAdapter.ts:75)"),
        resolvePrior(state, id, null, `Codex ${payload.type}`)));
    }
  }
  return finalizeLifecycle(state.events);
}

function parseCursorAgentRows(rows, context) {
  const events = [];
  for (const [rowIndex, row] of rows.entries()) {
    const content = row?.message?.content;
    if (!Array.isArray(content)) continue;
    for (const [blockIndex, block] of content.entries()) {
      if (block?.type !== "tool_use") continue;
      invariant(nonemptyString(block.name) && (isObject(block.input) ||
        (block.name === "ApplyPatch" && typeof block.input === "string")),
        `${context}: malformed tool_use at row ${rowIndex + 1}`);
      events.push(rawCall(`cursor-agent:${rowIndex}:${blockIndex}`,
        block.name, block.input, rawIdAt(block, "id")));
    }
  }
  return finalizeLifecycle(events);
}

function parseHermesLifecycle(text, context) {
  const root = parseJsonText(text, context);
  invariant(isObject(root) && Array.isArray(root.messages),
    `${context}: messages must be an array`);
  const state = { events: [], calls: [], matched: new Set() };
  for (const [messageIndex, message] of root.messages.entries()) {
    invariant(isObject(message) && nonemptyString(message.role),
      `${context}: malformed message ${messageIndex}`);
    if (message.role === "assistant") {
      const calls = message.tool_calls ?? [];
      invariant(Array.isArray(calls), `${context}: tool_calls must be an array`);
      for (const [callIndex, call] of calls.entries()) {
        invariant(isObject(call) && (!hasOwn(call, "type") || call.type === "function") &&
          isObject(call.function) && nonemptyString(call.function.name) &&
          typeof call.function.arguments === "string",
        `${context}: malformed Hermes function call`);
        const argumentsValue = parseJsonText(call.function.arguments,
          `${context}: Hermes function arguments at ${messageIndex}:${callIndex}`);
        invariant(isObject(argumentsValue) || Array.isArray(argumentsValue),
          `${context}: Hermes function arguments must decode to an object or array`);
        const event = rawCall(`hermes:${messageIndex}:${callIndex}`,
          call.function.name, argumentsValue, rawIdAlias(call, "id", "call_id"));
        state.events.push(event);
        state.calls.push(event);
      }
    } else if (message.role === "tool") {
      invariant(typeof message.content === "string", `${context}: Hermes result must be text`);
      const id = rawIdAt(message, "tool_call_id");
      const name = nonemptyString(message.name) ? message.name : null;
      let error;
      if (hasOwn(message, "is_error") || hasOwn(message, "isError")) {
        const value = hasOwn(message, "is_error") ? message.is_error : message.isError;
        invariant(typeof value === "boolean", `${context}: Hermes error must be boolean`);
        error = nativeError(value);
      } else error = unrecordedError();
      state.events.push(rawResult(`hermes-result:${messageIndex}`, id,
        [textBlock(message.content)], error,
        resolvePrior(state, id, name, "Hermes tool result", name !== null)));
    }
  }
  return finalizeLifecycle(state.events);
}

function parseGaisLifecycle(text, context) {
  const root = parseJsonText(text, context);
  const chunks = root?.chunkedPrompt?.chunks;
  invariant(Array.isArray(chunks), `${context}: chunkedPrompt.chunks must be an array`);
  const state = { events: [], calls: [], matched: new Set() };
  for (const [chunkIndex, chunk] of chunks.entries()) {
    invariant(isObject(chunk) && ["user", "model"].includes(chunk.role),
      `${context}: malformed chunk ${chunkIndex}`);
    const parts = Array.isArray(chunk.parts) ? chunk.parts : [];
    for (const [partIndex, part] of parts.entries()) {
      if (isObject(part?.functionCall)) {
        const call = part.functionCall;
        invariant(chunk.role === "model" && nonemptyString(call.name) &&
          isObject(call.args), `${context}: malformed functionCall`);
        const event = rawCall(`gais:${chunkIndex}:${partIndex}`, call.name,
          call.args, rawIdAlias(call, "id", "callId"));
        state.events.push(event);
        state.calls.push(event);
      } else if (isObject(part?.functionResponse)) {
        const response = part.functionResponse;
        invariant(chunk.role === "user" && nonemptyString(response.name) &&
          hasOwn(response, "response"), `${context}: malformed functionResponse`);
        const id = rawIdAlias(response, "id", "callId");
        let error;
        if (hasOwn(response, "isError")) {
          invariant(typeof response.isError === "boolean",
            `${context}: functionResponse.isError must be boolean`);
          error = nativeError(response.isError);
        } else if (isObject(response.response) && hasOwn(response.response, "error")) {
          error = inferredError(true,
            "google-ai-studio:functionResponse.response.error-present");
        } else error = unrecordedError();
        const blocks = typeof response.response === "string"
          ? [textBlock(response.response)]
          : [unmodeledBlock("google-ai-studio-function-response", response.response)];
        state.events.push(rawResult(`gais-result:${chunkIndex}:${partIndex}`,
          id, blocks, error,
          resolvePrior(state, id, response.name, "GAIS functionResponse", true)));
      }
    }
  }
  return finalizeLifecycle(state.events);
}

function parseCursorIdeLifecycle(text, context) {
  const root = parseJsonText(text, context);
  invariant(isObject(root?.composer) && Array.isArray(root.bubbles),
    `${context}: invalid Cursor IDE envelope`);
  const headers = root.composer.fullConversationHeadersOnly;
  invariant(Array.isArray(headers), `${context}: active headers must be an array`);
  const events = [];
  const bubbles = new Map();
  for (const bubble of root.bubbles) {
    invariant(isObject(bubble) && nonemptyString(bubble.bubbleId),
      `${context}: malformed bubble`);
    invariant(!bubbles.has(bubble.bubbleId), `${context}: duplicate bubble body`);
    bubbles.set(bubble.bubbleId, bubble);
  }
  for (const [headerIndex, header] of headers.entries()) {
    invariant(isObject(header) && nonemptyString(header.bubbleId),
      `${context}: malformed active header ${headerIndex}`);
    const bubble = bubbles.get(header.bubbleId);
    invariant(bubble && bubble.type === header.type,
      `${context}: active header does not select a unique matching bubble`);
    const tool = bubble.toolFormerData;
    if (bubble.type !== 2 || !isObject(tool) || !Number.isInteger(tool.tool)) continue;
    invariant(nonemptyString(tool.name), `${context}: fixture requires exact toolFormerData.name`);
    const args = hasOwn(tool, "rawArgs") ? tool.rawArgs
      : hasOwn(tool, "params") ? tool.params : {};
    const id = rawIdAt(tool, "toolCallId");
    const callSite = `cursor-ide:${headerIndex}`;
    events.push(rawCall(callSite, tool.name, args, id));
    if (hasOwn(tool, "result")) {
      const blocks = typeof tool.result === "string"
        ? [textBlock(tool.result)]
        : [unmodeledBlock("cursor_ide.tool_result", tool.result)];
      const isError = tool.status === "error" || tool.status === "cancelled";
      events.push(rawResult(`cursor-ide-result:${headerIndex}`, id,
        blocks, nativeError(isError), resolvedSite(callSite, id)));
    }
  }
  return finalizeLifecycle(events);
}

function canonicalNatString(value) {
  if (typeof value !== "string" || !/^(?:0|[1-9][0-9]*)$/.test(value)) return null;
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) ? parsed : null;
}

function requireCanonicalNat(value, context) {
  const parsed = canonicalNatString(value);
  invariant(parsed !== null, `${context}: expected a canonical decimal string`);
  return parsed;
}

function nullableString(value) {
  return value === null || typeof value === "string";
}

function validateWireOrigin(value, context) {
  invariant(exactOptionalKeys(value, ["format", "sourceRef"],
    ["extras", "formatOther", "rawId"]) && nonemptyString(value.format) &&
    nonemptyString(value.sourceRef) && (!hasOwn(value, "rawId") ||
      typeof value.rawId === "string") && (!hasOwn(value, "formatOther") ||
      value.formatOther === true), `${context}: invalid origin envelope`);
}

function validateWireCallRef(value, context) {
  invariant(isObject(value), `${context}: call reference must be an object`);
  if (value.kind === "resolved") {
    invariant(exactKeys(value, ["block", "entry", "kind"]),
      `${context}: invalid resolved call reference`);
    requireCanonicalNat(value.entry, `${context}.entry`);
    requireCanonicalNat(value.block, `${context}.block`);
  } else if (value.kind === "unresolved") {
    invariant(exactOptionalKeys(value, ["kind", "note"], ["rawId"]) &&
      typeof value.note === "string" && (!hasOwn(value, "rawId") ||
        typeof value.rawId === "string"),
    `${context}: invalid unresolved call reference`);
  } else throw new AuditError(`${context}: unsupported call reference kind`);
}

function validateWireUserBlock(block, context) {
  invariant(isObject(block) && nonemptyString(block.type),
    `${context}: user block must name its type`);
  if (block.type === "text") {
    invariant(exactKeys(block, ["text", "type"]) && typeof block.text === "string",
      `${context}: invalid text block`);
  } else if (block.type === "media") {
    invariant(exactKeys(block, ["data", "mimeType", "type"]) &&
      typeof block.data === "string" && nonemptyString(block.mimeType),
    `${context}: invalid media block`);
  } else if (block.type === "unmodeled") {
    invariant(exactKeys(block, ["label", "raw", "type"]) &&
      nonemptyString(block.label), `${context}: invalid unmodeled block`);
  } else throw new AuditError(`${context}: exporter emitted an open-world user block`);
}

function validateWireAssistantBlock(block, context) {
  invariant(isObject(block) && nonemptyString(block.type),
    `${context}: assistant block must name its type`);
  if (["text", "media", "unmodeled"].includes(block.type)) {
    validateWireUserBlock(block, context);
  } else if (block.type === "thinking") {
    invariant(exactOptionalKeys(block, ["thinking", "type"], ["thinkingSignature"]) &&
      typeof block.thinking === "string" && (!hasOwn(block, "thinkingSignature") ||
        typeof block.thinkingSignature === "string"),
    `${context}: invalid thinking block`);
  } else if (block.type === "toolCall") {
    invariant(exactOptionalKeys(block, ["arguments", "name", "type"],
      ["canonical", "id"]) && nonemptyString(block.name) &&
      (!hasOwn(block, "id") || typeof block.id === "string") &&
      (!hasOwn(block, "canonical") || ["bash", "read", "write", "edit", "grep",
        "glob", "webFetch", "webSearch", "agentSpawn", "applyPatch"]
        .includes(block.canonical)), `${context}: invalid toolCall block`);
  } else throw new AuditError(`${context}: exporter emitted an open-world assistant block`);
}

function validateWireError(value, context) {
  invariant(isObject(value), `${context}: error signal must be an object`);
  if (value.kind === "native") {
    invariant(exactKeys(value, ["isError", "kind"]) &&
      ["true", "false"].includes(value.isError), `${context}: invalid native error`);
  } else if (value.kind === "inferred") {
    invariant(exactKeys(value, ["heuristic", "isError", "kind"]) &&
      ["true", "false"].includes(value.isError) && nonemptyString(value.heuristic),
    `${context}: invalid inferred error`);
  } else if (value.kind === "unrecorded") {
    invariant(exactKeys(value, ["kind"]), `${context}: invalid unrecorded error`);
  } else throw new AuditError(`${context}: unsupported error signal`);
}

function validateWirePayload(payload, context) {
  invariant(isObject(payload) && nonemptyString(payload.type),
    `${context}: payload must name its type`);
  if (["userMsg", "assistantMsg", "envMsg"].includes(payload.type)) {
    invariant(exactKeys(payload, ["blocks", "type"]) && Array.isArray(payload.blocks),
      `${context}: invalid ${payload.type} envelope`);
    for (const [index, block] of payload.blocks.entries()) {
      if (payload.type === "userMsg") {
        validateWireUserBlock(block, `${context}.blocks[${index}]`);
      } else if (payload.type === "assistantMsg") {
        validateWireAssistantBlock(block, `${context}.blocks[${index}]`);
      } else if (block?.type === "toolResult") {
        invariant(exactKeys(block, ["call", "content", "error", "type"]) &&
          Array.isArray(block.content), `${context}.blocks[${index}]: invalid toolResult`);
        validateWireCallRef(block.call, `${context}.blocks[${index}].call`);
        validateWireError(block.error, `${context}.blocks[${index}].error`);
        block.content.forEach((item, itemIndex) =>
          validateWireUserBlock(item, `${context}.blocks[${index}].content[${itemIndex}]`));
      } else {
        invariant(exactKeys(block, ["label", "raw", "type"]) &&
          block.type === "unmodeled" && nonemptyString(block.label),
        `${context}.blocks[${index}]: invalid environment block`);
      }
    }
  } else if (payload.type === "otherMsg") {
    invariant(exactKeys(payload, ["blocks", "role", "type"]) &&
      nonemptyString(payload.role) && Array.isArray(payload.blocks),
    `${context}: invalid otherMsg envelope`);
    payload.blocks.forEach((block, index) =>
      validateWireUserBlock(block, `${context}.blocks[${index}]`));
  } else if (payload.type === "compaction") {
    invariant(exactOptionalKeys(payload, ["coverage", "summary", "type"],
      ["tokensBefore"]) && typeof payload.summary === "string" &&
      isObject(payload.coverage), `${context}: invalid compaction envelope`);
    if (payload.coverage.kind === "knownPrefix") {
      invariant(exactKeys(payload.coverage, ["firstKept", "kind"]),
        `${context}: invalid known-prefix coverage`);
      requireCanonicalNat(payload.coverage.firstKept, `${context}.coverage.firstKept`);
    } else invariant(exactKeys(payload.coverage, ["kind"]) &&
      payload.coverage.kind === "unknownPrefix", `${context}: invalid compaction coverage`);
    if (hasOwn(payload, "tokensBefore")) {
      requireCanonicalNat(payload.tokensBefore, `${context}.tokensBefore`);
    }
  } else if (payload.type === "event") {
    invariant(exactKeys(payload, ["event", "type"]) && isObject(payload.event) &&
      nonemptyString(payload.event.type), `${context}: invalid event envelope`);
    const event = payload.event;
    if (event.type === "modelChange" || event.type === "thinkingLevelChange") {
      invariant(exactOptionalKeys(event, ["type"], ["next", "prev"]) &&
        (!hasOwn(event, "next") || typeof event.next === "string") &&
        (!hasOwn(event, "prev") || typeof event.prev === "string"),
      `${context}: invalid change event`);
    } else if (event.type === "permissionMode") {
      invariant(exactKeys(event, ["mode", "type"]) && nonemptyString(event.mode),
        `${context}: invalid permission event`);
    } else if (event.type === "branchSummary") {
      invariant(exactKeys(event, ["summary", "type"]) &&
        typeof event.summary === "string", `${context}: invalid summary event`);
    } else {
      invariant(event.type === "custom" && exactKeys(event, ["label", "raw", "type"]) &&
        nonemptyString(event.label), `${context}: invalid custom event`);
    }
  } else throw new AuditError(`${context}: unsupported payload type ${payload.type}`);
}

function validateLoomTargetEnvelope(root, context) {
  invariant(exactKeys(root, ["activeLeaf", "entries", "env", "importNotes", "origin",
    "schema", "threads"]) && root.schema === "loom.transcript.v0" &&
    isObject(root.env) && Array.isArray(root.threads) && root.threads.length > 0 &&
    Array.isArray(root.entries) && Array.isArray(root.importNotes),
  `${context}: invalid complete Loom target envelope`);
  validateWireOrigin(root.origin, `${context}.origin`);
  invariant(exactOptionalKeys(root.env, [], ["cwd", "harnessVersion", "instructions",
    "model", "provider", "sessionId"]) &&
    Object.values(root.env).every((value) => typeof value === "string"),
  `${context}.env: invalid environment envelope`);
  for (const [index, thread] of root.threads.entries()) {
    invariant(exactOptionalKeys(thread, ["index", "kind"], ["label"]) &&
      thread.index === String(index) && isObject(thread.kind) &&
      (!hasOwn(thread, "label") || typeof thread.label === "string"),
    `${context}.threads[${index}]: invalid thread envelope or index encoding`);
    if (thread.kind.kind === "main") {
      invariant(exactKeys(thread.kind, ["kind"]), `${context}: invalid main thread`);
    } else if (thread.kind.kind === "sidechain") {
      invariant(exactKeys(thread.kind, ["anchor", "kind"]),
        `${context}: invalid sidechain thread`);
      validateWireCallRef(thread.kind.anchor, `${context}.threads[${index}].kind.anchor`);
    } else invariant(thread.kind.kind === "detached" &&
      exactKeys(thread.kind, ["kind", "note"]) && typeof thread.kind.note === "string",
    `${context}: invalid detached thread`);
  }
  for (const [index, entry] of root.entries.entries()) {
    invariant(exactOptionalKeys(entry, ["index", "origin", "payload", "thread", "time"],
      ["disposition", "parent"]) && entry.index === String(index),
    `${context}.entries[${index}]: invalid entry envelope or index encoding`);
    const thread = requireCanonicalNat(entry.thread, `${context}.entries[${index}].thread`);
    invariant(thread < root.threads.length, `${context}.entries[${index}]: invalid thread ref`);
    if (hasOwn(entry, "parent")) {
      const parent = requireCanonicalNat(entry.parent,
        `${context}.entries[${index}].parent`);
      invariant(parent < index, `${context}.entries[${index}]: parent must be earlier`);
    }
    invariant(!hasOwn(entry, "disposition") ||
      entry.disposition === "historicalUnverified",
    `${context}.entries[${index}]: invalid disposition`);
    validateWireOrigin(entry.origin, `${context}.entries[${index}].origin`);
    const time = entry.time;
    invariant(isObject(time), `${context}.entries[${index}].time: invalid time`);
    if (time.kind === "recorded") {
      invariant(exactKeys(time, ["kind", "ms"]), `${context}: invalid recorded time`);
      requireCanonicalNat(time.ms, `${context}.entries[${index}].time.ms`);
    } else if (time.kind === "interpolated") {
      invariant(exactKeys(time, ["basis", "kind", "ms"]) &&
        nonemptyString(time.basis), `${context}: invalid interpolated time`);
      requireCanonicalNat(time.ms, `${context}.entries[${index}].time.ms`);
    } else if (time.kind === "sequenced") {
      invariant(exactKeys(time, ["kind", "ord"]), `${context}: invalid sequenced time`);
      requireCanonicalNat(time.ord, `${context}.entries[${index}].time.ord`);
    } else invariant(time.kind === "absent" && exactKeys(time, ["kind"]),
      `${context}: invalid absent time`);
    validateWirePayload(entry.payload, `${context}.entries[${index}].payload`);
  }
  for (const [index, note] of root.importNotes.entries()) {
    invariant(exactOptionalKeys(note, ["detail", "kind"], ["kindOther", "loc"]) &&
      nonemptyString(note.kind) && typeof note.detail === "string" &&
      (!hasOwn(note, "kindOther") || note.kindOther === true) &&
      (!hasOwn(note, "loc") || typeof note.loc === "string"),
    `${context}.importNotes[${index}]: invalid import note`);
  }
  const activeLeaf = requireCanonicalNat(root.activeLeaf, `${context}.activeLeaf`);
  invariant(activeLeaf < root.entries.length, `${context}: activeLeaf is out of range`);
  return {
    schema: root.schema,
    entries: root.entries.length,
    threads: root.threads.length,
    indexEncoding: "canonical-decimal-strings",
  };
}

function validateSourceEnvironment(value, context) {
  invariant(exactKeys(value, ["cwd", "harnessVersion", "instructions", "model",
    "provider", "sessionId"]) && Object.values(value).every(nullableString),
  `${context}: invalid complete source environment`);
}

function validatePiEntryStamp(stamp, context) {
  invariant(exactKeys(stamp, ["time", "version"]) && stamp.version === 1 &&
    isObject(stamp.time), `${context}: invalid Pi entry stamp`);
  if (stamp.time.state === "absent") {
    invariant(exactKeys(stamp.time, ["state"]), `${context}: invalid absent Pi time`);
  } else if (stamp.time.state === "sequenced") {
    invariant(exactKeys(stamp.time, ["ordinal", "state"]) &&
      Number.isInteger(stamp.time.ordinal) && stamp.time.ordinal >= 0,
    `${context}: invalid sequenced Pi time`);
  } else throw new AuditError(`${context}: unsupported Pi time state`);
}

function validatePiUsage(usage, context) {
  const numeric = (value) => typeof value === "number" && Number.isFinite(value) && value >= 0;
  invariant(exactKeys(usage,
    ["cacheRead", "cacheWrite", "cost", "input", "output", "totalTokens"]) &&
    ["cacheRead", "cacheWrite", "input", "output", "totalTokens"]
      .every((key) => numeric(usage[key])) &&
    exactKeys(usage.cost, ["cacheRead", "cacheWrite", "input", "output", "total"]) &&
    ["cacheRead", "cacheWrite", "input", "output", "total"]
      .every((key) => numeric(usage.cost[key])),
  `${context}: invalid Pi usage envelope`);
}

function validatePiContentBlock(block, context) {
  invariant(isObject(block), `${context}: Pi content block must be an object`);
  if (block.type === "text") {
    invariant(exactOptionalKeys(block, ["text", "type"], ["loomPi"]) &&
      typeof block.text === "string", `${context}: invalid Pi text block`);
    if (hasOwn(block, "loomPi")) {
      invariant(exactKeys(block.loomPi,
        ["author", "constructor", "kind", "label", "raw", "version"]) &&
        block.loomPi.version === 1 && block.loomPi.kind === "block" &&
        block.loomPi.author === "user" &&
        block.loomPi.constructor === "unmodeled" &&
        typeof block.loomPi.label === "string",
      `${context}: invalid Pi user block carrier`);
    }
  } else if (block.type === "image") {
    invariant(exactKeys(block, ["data", "mimeType", "type"]) &&
      nonemptyString(block.mimeType) && typeof block.data === "string",
    `${context}: invalid Pi image block`);
  } else throw new AuditError(`${context}: unsupported Pi content block`);
}

function validatePiHistoricalAssistantBlock(block, context) {
  invariant(isObject(block) && nonemptyString(block.kind),
    `${context}: invalid historical assistant block`);
  if (block.kind === "text") {
    invariant(exactKeys(block, ["kind", "text"]) && typeof block.text === "string",
      `${context}: invalid historical text block`);
  } else if (block.kind === "thinking") {
    invariant(exactKeys(block, ["kind", "signature", "thinking"]) &&
      typeof block.thinking === "string" && nullableString(block.signature),
    `${context}: invalid historical thinking block`);
  } else if (block.kind === "toolCall") {
    invariant(exactKeys(block,
      ["arguments", "canonical", "kind", "name", "rawId"]) &&
      nonemptyString(block.name) && nullableString(block.rawId) &&
      (block.canonical === null || CANONICAL_TOOL_NAMES.includes(block.canonical)),
    `${context}: invalid historical tool-call block`);
  } else if (block.kind === "media") {
    invariant(exactKeys(block, ["data", "kind", "mimeType"]) &&
      nonemptyString(block.mimeType) && typeof block.data === "string",
    `${context}: invalid historical media block`);
  } else if (block.kind === "unmodeled") {
    invariant(exactKeys(block, ["kind", "label", "raw"]) &&
      nonemptyString(block.label), `${context}: invalid historical unmodeled block`);
  } else throw new AuditError(`${context}: unsupported historical assistant block`);
}

function validatePiCarrierValue(data, context) {
  invariant(exactKeys(data, ["kind", "value", "version"]) && data.version === 1 &&
    isObject(data.value), `${context}: invalid Pi carrier envelope`);
  const value = data.value;
  if (data.kind === "assistantMessage") {
    invariant(exactKeys(value, ["blocks", "representation", "scope",
      "sourceBlockIndices", "sourceEntry"]) &&
      value.representation === "historical-assistant-blocks" &&
      value.scope === "full" && Array.isArray(value.blocks) &&
      Array.isArray(value.sourceBlockIndices) &&
      value.blocks.length === value.sourceBlockIndices.length &&
      Number.isInteger(value.sourceEntry) && value.sourceEntry >= 0 &&
      value.sourceBlockIndices.every((index) => Number.isInteger(index) && index >= 0),
    `${context}: invalid historical assistant carrier`);
    value.blocks.forEach((block, index) =>
      validatePiHistoricalAssistantBlock(block, `${context}.value.blocks[${index}]`));
  } else if (data.kind === "toolResult") {
    invariant(exactKeys(value, ["call", "content", "error", "toolCallId", "toolName"]) &&
      isObject(value.call) && Array.isArray(value.content) &&
      nonemptyString(value.toolCallId) && nonemptyString(value.toolName),
    `${context}: invalid historical result carrier`);
    value.content.forEach((block, index) =>
      validatePiContentBlock(block, `${context}.value.content[${index}]`));
    invariant(parsePiCarrierError(value.error) !== null,
      `${context}: invalid historical result error`);
    if (value.call.state === "resolved") {
      invariant(exactKeys(value.call, ["sourceBlock", "sourceEntry", "state"]) &&
        Number.isInteger(value.call.sourceEntry) && value.call.sourceEntry >= 0 &&
        Number.isInteger(value.call.sourceBlock) && value.call.sourceBlock >= 0,
      `${context}: invalid resolved historical result reference`);
    } else invariant(value.call.state === "unresolved" &&
      exactKeys(value.call, ["note", "rawId", "state"]) &&
      typeof value.call.note === "string" &&
      (value.call.rawId === null || nonemptyString(value.call.rawId)),
    `${context}: invalid unresolved historical result reference`);
  } else if (data.kind === "event") {
    invariant(exactKeys(value, ["label", "raw"]) && nonemptyString(value.label),
      `${context}: invalid Pi event carrier`);
  } else if (data.kind === "modelChange") {
    invariant(exactKeys(value, ["next", "previous"]) && nullableString(value.next) &&
      nullableString(value.previous), `${context}: invalid Pi model-change carrier`);
  } else throw new AuditError(`${context}: unsupported Pi carrier kind ${data.kind}`);
}

function expectedLaunchContext(format, binding, context) {
  invariant(exactKeys(binding, ["cell", "target"]) && isObject(binding.cell),
    `${context}: target validation binding is required`);
  validateLaunch(binding.target);
  invariant(binding.target.name === format && binding.cell.target === format &&
    nonemptyString(binding.cell.name), `${context}: target validation binding disagrees`);
  const launch = binding.target.launch;
  return {
    target: binding.target,
    cell: binding.cell,
    launch,
    cwd: launch.kind === "none" ? null : `${launch.cwdPrefix}/${binding.cell.name}`,
  };
}

function validatePiTargetEnvelope(rows, expected, context) {
  invariant(rows.length >= 2, `${context}: Pi target requires a header and model change`);
  const header = rows[0];
  const launch = expected.launch;
  invariant(exactKeys(header, ["cwd", "id", "loomPi", "timestamp", "type", "version"]) &&
    header.type === "session" && header.version === 3 &&
    header.id === expected.cell.targetSessionId && header.cwd === expected.cwd &&
    header.timestamp === launch.timestamp, `${context}: invalid Pi target session header`);
  const stamp = header.loomPi;
  invariant(exactKeys(stamp, ["cwd", "sessionId", "sourceEnvironment",
    "targetHarnessVersion", "targetOptions", "timestamp", "version"]) &&
    stamp.version === 1 && stamp.cwd === "target-option" &&
    stamp.sessionId === "target-option" && stamp.timestamp === "target-option" &&
    stamp.targetHarnessVersion === launch.harnessVersion && isObject(stamp.targetOptions),
  `${context}: invalid Pi launch stamp`);
  validateSourceEnvironment(stamp.sourceEnvironment,
    `${context}: session.loomPi.sourceEnvironment`);
  invariant(exactKeys(stamp.targetOptions, ["pi_assistant_history", "target_cwd",
    "target_harness_version", "target_model", "target_provider", "target_session_id",
    "target_timestamp"]) && ["target_cwd", "target_harness_version", "target_model",
      "target_provider", "target_session_id", "target_timestamp"]
      .every((key) => stamp.targetOptions[key] === "origin-target-option") &&
    exactKeys(stamp.targetOptions.pi_assistant_history, ["provenance", "value"]) &&
    stamp.targetOptions.pi_assistant_history.provenance === "origin-target-option" &&
    stamp.targetOptions.pi_assistant_history.value === launch.assistantHistory,
  `${context}: Pi target options do not bind the requested launch bundle`);

  const ids = new Set();
  const carrierCalls = new Map();
  const nativeCalls = [];
  const matchedNativeCalls = new Set();
  let previousId = null;
  for (const [rowIndex, row] of rows.slice(1, -1).entries()) {
    const index = rowIndex + 1;
    invariant(exactOptionalKeys(row, ["id", "parentId", "timestamp", "type"],
      ["customType", "data", "loomPi", "message"]) && nonemptyString(row.id) &&
      !ids.has(row.id) && row.parentId === previousId && nonemptyString(row.timestamp),
    `${context}: row ${index} has an invalid Pi entry envelope or parent chain`);
    ids.add(row.id);
    previousId = row.id;
    if (hasOwn(row, "loomPi")) validatePiEntryStamp(row.loomPi, `${context}: row ${index}`);
    if (row.type === "custom") {
      invariant(exactOptionalKeys(row, ["customType", "data", "id", "parentId",
        "timestamp", "type"], ["loomPi"]) &&
        row.customType === "loom.pi.carrier", `${context}: row ${index} invalid custom row`);
      validatePiCarrierValue(row.data, `${context}: row ${index}.data`);
      if (row.data.kind === "assistantMessage") {
        const value = row.data.value;
        for (const [blockIndex, block] of value.blocks.entries()) {
          if (block?.kind === "toolCall") {
            const coordinate = `${value.sourceEntry}:${value.sourceBlockIndices[blockIndex]}`;
            invariant(!carrierCalls.has(coordinate),
              `${context}: row ${index} duplicates historical call coordinate ${coordinate}`);
            carrierCalls.set(coordinate, {
              name: block.name,
              rawId: block.rawId,
            });
          }
        }
      } else if (row.data.kind === "toolResult" &&
          row.data.value.call.state === "resolved") {
        const value = row.data.value;
        const referenced = carrierCalls.get(
          `${value.call.sourceEntry}:${value.call.sourceBlock}`);
        invariant(referenced && referenced.name === value.toolName &&
          referenced.rawId === value.toolCallId,
        `${context}: row ${index} toolName/toolCallId disagree with the referenced carrier call`);
      }
    } else if (row.type === "message") {
      invariant(exactOptionalKeys(row, ["id", "message", "parentId", "timestamp", "type"],
        ["loomPi"]) && isObject(row.message) && Array.isArray(row.message.content),
      `${context}: row ${index} invalid message row`);
      const message = row.message;
      if (message.role === "assistant") {
        invariant(exactKeys(message, ["api", "content", "model", "provider", "role",
          "stopReason", "timestamp", "usage"]) && nonemptyString(message.api) &&
          nonemptyString(message.model) && nonemptyString(message.provider) &&
          nonemptyString(message.stopReason) && Number.isInteger(message.timestamp) &&
          isObject(message.usage), `${context}: row ${index} invalid assistant message`);
        validatePiUsage(message.usage, `${context}: row ${index}.message.usage`);
        for (const block of message.content) {
          invariant(exactKeys(block, ["arguments", "id", "name", "type"]) &&
            block.type === "toolCall" && nonemptyString(block.id) &&
            nonemptyString(block.name) && isObject(block.arguments),
          `${context}: row ${index} invalid native Pi tool call`);
          nativeCalls.push({ id: block.id, name: block.name });
        }
      } else if (message.role === "toolResult") {
        invariant(exactKeys(message, ["content", "isError", "role", "timestamp",
          "toolCallId", "toolName"]) && nonemptyString(message.toolCallId) &&
          nonemptyString(message.toolName) && typeof message.isError === "boolean" &&
          Number.isInteger(message.timestamp),
        `${context}: row ${index} invalid native Pi tool result`);
        message.content.forEach((block, blockIndex) =>
          validatePiContentBlock(block, `${context}: row ${index}.content[${blockIndex}]`));
        const callIndex = nativeCalls.findIndex((call, candidateIndex) =>
          !matchedNativeCalls.has(candidateIndex) && call.id === message.toolCallId &&
          call.name === message.toolName);
        invariant(callIndex >= 0,
          `${context}: row ${index} toolName/toolCallId do not identify an earlier native call`);
        matchedNativeCalls.add(callIndex);
      } else if (message.role === "user") {
        invariant(exactKeys(message, ["content", "role", "timestamp"]) &&
          Number.isInteger(message.timestamp), `${context}: row ${index} invalid user message`);
        message.content.forEach((block, blockIndex) =>
          validatePiContentBlock(block, `${context}: row ${index}.content[${blockIndex}]`));
      } else throw new AuditError(`${context}: row ${index} has an unsupported Pi role`);
    } else throw new AuditError(`${context}: row ${index} has an unsupported Pi entry type`);
  }
  const tail = rows.at(-1);
  invariant(exactKeys(tail, ["id", "loomPi", "modelId", "parentId", "provider",
    "timestamp", "type"]) && tail.type === "model_change" &&
    tail.id === "loom-target-model" && !ids.has(tail.id) && tail.parentId === previousId &&
    tail.timestamp === launch.timestamp && tail.modelId === launch.model &&
    tail.provider === launch.provider && exactKeys(tail.loomPi,
      ["targetModelChange", "version"]) && tail.loomPi.version === 1 &&
    exactKeys(tail.loomPi.targetModelChange,
      ["author", "target_model", "target_provider", "target_timestamp"]) &&
    tail.loomPi.targetModelChange.author === "target" &&
    ["target_model", "target_provider", "target_timestamp"].every((key) =>
      tail.loomPi.targetModelChange[key] === "origin-target-option"),
  `${context}: invalid Pi target model-change terminator`);
  return {
    schema: "pi-session-v3+loomPi-v1",
    records: rows.length,
    targetSessionId: header.id,
    targetCwd: header.cwd,
    targetTimestamp: header.timestamp,
    targetHarnessVersion: stamp.targetHarnessVersion,
    targetProvider: tail.provider,
    targetModel: tail.modelId,
  };
}

function validateClaudeHistoricalUserBlock(block, context) {
  invariant(isObject(block) && nonemptyString(block.kind),
    `${context}: invalid historical user block`);
  if (block.kind === "text") {
    invariant(exactKeys(block, ["kind", "text"]) && typeof block.text === "string",
      `${context}: invalid historical text block`);
  } else if (block.kind === "media") {
    invariant(exactKeys(block, ["kind", "locator", "mimeType"]) &&
      nonemptyString(block.mimeType) && typeof block.locator === "string",
    `${context}: invalid historical media block`);
  } else if (block.kind === "unmodeled") {
    invariant(exactKeys(block, ["kind", "label", "raw"]) &&
      nonemptyString(block.label), `${context}: invalid historical unmodeled block`);
  } else throw new AuditError(`${context}: unsupported historical user block`);
}

function validateClaudeHistoricalAssistantBlock(block, context) {
  invariant(isObject(block) && nonemptyString(block.kind),
    `${context}: invalid historical assistant block`);
  if (["text", "media", "unmodeled"].includes(block.kind)) {
    validateClaudeHistoricalUserBlock(block, context);
  } else if (block.kind === "thinking") {
    invariant(exactKeys(block, ["kind", "signature", "thinking"]) &&
      typeof block.thinking === "string" && nullableString(block.signature),
    `${context}: invalid historical thinking block`);
  } else if (block.kind === "toolCall") {
    invariant(exactKeys(block,
      ["arguments", "canonical", "kind", "name", "rawId"]) &&
      nonemptyString(block.name) && nullableString(block.rawId) &&
      (block.canonical === null || CANONICAL_TOOL_NAMES.includes(block.canonical)),
    `${context}: invalid historical tool-call block`);
  } else throw new AuditError(`${context}: unsupported historical assistant block`);
}

function validateClaudeHistoricalCallRef(call, context) {
  invariant(isObject(call), `${context}: invalid historical call reference`);
  if (call.kind === "resolved") {
    invariant(exactKeys(call, ["block", "entry", "kind"]) &&
      Number.isSafeInteger(call.entry) && call.entry >= 0 &&
      Number.isSafeInteger(call.block) && call.block >= 0,
    `${context}: invalid resolved historical call reference`);
  } else {
    invariant(call.kind === "unresolved" &&
      exactKeys(call, ["kind", "note", "rawId"]) &&
      nullableString(call.rawId) && typeof call.note === "string",
    `${context}: invalid unresolved historical call reference`);
  }
}

function validateClaudeHistoricalError(error, context) {
  invariant(isObject(error), `${context}: invalid historical error signal`);
  if (error.kind === "native") {
    invariant(exactKeys(error, ["isError", "kind"]) &&
      typeof error.isError === "boolean", `${context}: invalid native error signal`);
  } else if (error.kind === "inferred") {
    invariant(exactKeys(error, ["heuristic", "isError", "kind"]) &&
      typeof error.isError === "boolean" && typeof error.heuristic === "string",
    `${context}: invalid inferred error signal`);
  } else invariant(error.kind === "unrecorded" && exactKeys(error, ["kind"]),
    `${context}: invalid unrecorded error signal`);
}

function validateClaudeHistoricalEvent(event, context) {
  invariant(isObject(event) && nonemptyString(event.kind),
    `${context}: invalid historical event`);
  if (["modelChange", "thinkingLevelChange"].includes(event.kind)) {
    invariant(exactKeys(event, ["kind", "next", "prev"]) &&
      nullableString(event.next) && nullableString(event.prev),
    `${context}: invalid historical change event`);
  } else if (event.kind === "permissionMode") {
    invariant(exactKeys(event, ["kind", "mode"]) && typeof event.mode === "string",
      `${context}: invalid historical permission event`);
  } else if (event.kind === "branchSummary") {
    invariant(exactKeys(event, ["kind", "summary"]) && typeof event.summary === "string",
      `${context}: invalid historical branch summary`);
  } else invariant(event.kind === "custom" &&
    exactKeys(event, ["kind", "label", "raw"]) && nonemptyString(event.label),
  `${context}: invalid historical custom event`);
}

function validateClaudeInertPayload(value, context) {
  invariant(isObject(value) && nonemptyString(value.kind),
    `${context}: invalid inert payload`);
  if (["userMsg", "assistantMsg", "envMsg"].includes(value.kind)) {
    invariant(exactKeys(value, ["blocks", "kind"]) && Array.isArray(value.blocks),
      `${context}: invalid inert message payload`);
  } else if (value.kind === "otherMsg") {
    invariant(exactKeys(value, ["blocks", "kind", "role"]) &&
      Array.isArray(value.blocks) && nonemptyString(value.role),
    `${context}: invalid inert other-role payload`);
  } else if (value.kind === "event") {
    invariant(exactKeys(value, ["event", "kind"]), `${context}: invalid inert event payload`);
    validateClaudeHistoricalEvent(value.event, `${context}.event`);
    return;
  } else throw new AuditError(`${context}: unsupported inert payload kind ${value.kind}`);

  for (const [index, block] of value.blocks.entries()) {
    const blockContext = `${context}.blocks[${index}]`;
    if (value.kind === "assistantMsg") {
      validateClaudeHistoricalAssistantBlock(block, blockContext);
    } else if (value.kind === "envMsg") {
      invariant(isObject(block) && nonemptyString(block.kind),
        `${blockContext}: invalid historical environment block`);
      if (block.kind === "toolResult") {
        invariant(exactKeys(block, ["call", "content", "error", "kind"]) &&
          Array.isArray(block.content), `${blockContext}: invalid historical tool result`);
        validateClaudeHistoricalCallRef(block.call, `${blockContext}.call`);
        block.content.forEach((item, itemIndex) =>
          validateClaudeHistoricalUserBlock(item, `${blockContext}.content[${itemIndex}]`));
        validateClaudeHistoricalError(block.error, `${blockContext}.error`);
      } else invariant(block.kind === "unmodeled" &&
        exactKeys(block, ["kind", "label", "raw"]) && nonemptyString(block.label),
      `${blockContext}: invalid historical environment block`);
    } else validateClaudeHistoricalUserBlock(block, blockContext);
  }
}

function validateClaudeIdentityProvenance(value, context) {
  invariant(exactOptionalKeys(value, ["carrier", "trust"],
    ["sourceEntryId", "sourceParentId", "sourceSessionId"]) &&
    value.carrier === "agent-convert.claude-identity-provenance.v1" &&
    value.trust === "historical-unverified" &&
    ["sourceEntryId", "sourceParentId", "sourceSessionId"].every((key) =>
      !hasOwn(value, key) || nullableString(value[key])),
  `${context}: invalid Claude identity provenance carrier`);
}

function validateClaudeTimeProvenance(value, context) {
  invariant(isObject(value) &&
    value.carrier === "agent-convert.time-provenance.v1",
  `${context}: invalid Claude time provenance carrier`);
  if (value.kind === "absent") {
    invariant(exactKeys(value, ["carrier", "kind"]),
      `${context}: invalid absent time provenance`);
  } else if (value.kind === "sequenced") {
    invariant(exactKeys(value, ["carrier", "kind", "ordinal"]) &&
      Number.isSafeInteger(value.ordinal) && value.ordinal >= 0,
    `${context}: invalid sequenced time provenance`);
  } else invariant(value.kind === "interpolated" &&
    exactKeys(value, ["basis", "carrier", "kind", "ms"]) &&
    Number.isSafeInteger(value.ms) && value.ms >= 0 && typeof value.basis === "string",
  `${context}: invalid interpolated time provenance`);
}

function validateClaudeMarker(marker, content, rowType, context) {
  invariant(exactOptionalKeys(marker, ["protocol"], ["contentBlocks", "identityProvenance",
    "inertPayload", "provenance", "timeProvenance"]) &&
    marker.protocol === CLAUDE_PROTOCOL, `${context}: invalid Claude marker`);
  invariant(rowType === "system" ? hasOwn(marker, "inertPayload") &&
    !hasOwn(marker, "contentBlocks") : !hasOwn(marker, "inertPayload"),
  `${context}: Claude marker fields disagree with the row type`);
  if (hasOwn(marker, "contentBlocks")) {
    invariant(Array.isArray(marker.contentBlocks) &&
      marker.contentBlocks.every(Number.isInteger) &&
      new Set(marker.contentBlocks).size === marker.contentBlocks.length,
    `${context}: invalid Claude carrier indices`);
    for (const index of marker.contentBlocks) {
      invariant(index >= 0 && index < content.length && content[index]?.type === "text",
        `${context}: Claude carrier index is out of range`);
      const parsed = rowType === "assistant"
        ? exactClaudeCallCarrier(content[index].text)
        : exactClaudeResultCarrier(content[index].text);
      invariant(parsed !== null, `${context}: marked Claude carrier is not exact`);
    }
  }
  const exactCarrierIndices = content.flatMap((block, index) => {
    if (block?.type !== "text") return [];
    const parsed = rowType === "assistant"
      ? exactClaudeCallCarrier(block.text) : exactClaudeResultCarrier(block.text);
    return parsed === null ? [] : [index];
  });
  invariant(jsonEqual(marker.contentBlocks ?? [], exactCarrierIndices),
    `${context}: Claude carrier index metadata is incomplete or extraneous`);
  if (hasOwn(marker, "identityProvenance")) {
    validateClaudeIdentityProvenance(marker.identityProvenance,
      `${context}.identityProvenance`);
  }
  if (hasOwn(marker, "timeProvenance")) {
    validateClaudeTimeProvenance(marker.timeProvenance, `${context}.timeProvenance`);
  }
  if (hasOwn(marker, "provenance")) {
    invariant(exactKeys(marker.provenance, ["carrier", "rawEnvelope"]) &&
      marker.provenance.carrier === "agent-convert.claude-envelope-provenance.v1" &&
      isObject(marker.provenance.rawEnvelope),
    `${context}: invalid Claude envelope provenance carrier`);
  }
  if (hasOwn(marker, "inertPayload")) {
    invariant(exactKeys(marker.inertPayload, ["carrier", "payload"]) &&
      marker.inertPayload.carrier === "agent-convert.claude-inert-payload.v1",
    `${context}: invalid Claude inert payload carrier`);
    validateClaudeInertPayload(marker.inertPayload.payload,
      `${context}.inertPayload.payload`);
  }
}

function validateClaudeTargetEnvelope(rows, expected, context) {
  invariant(rows.length >= 3, `${context}: Claude target is missing required records`);
  const provenance = rows.at(-2);
  const lastPrompt = rows.at(-1);
  invariant(exactKeys(provenance, ["_agent_convert", "type"]) &&
    provenance.type === "agent-convert-provenance", `${context}: missing provenance header`);
  const transcript = provenance._agent_convert;
  invariant(exactKeys(transcript, ["protocol", "transcriptProvenance"]) &&
    transcript.protocol === CLAUDE_PROTOCOL &&
    exactKeys(transcript.transcriptProvenance, ["carrier", "kind", "payload"]) &&
    transcript.transcriptProvenance.carrier ===
      "agent-convert.claude-transcript-provenance.v1" &&
    transcript.transcriptProvenance.kind === "sourceEnv", `${context}: invalid provenance header`);
  const sourceEnv = transcript.transcriptProvenance.payload;
  invariant(exactKeys(sourceEnv, ["carrier", "cwd", "harnessVersion", "instructions",
    "model", "provider", "sessionId"]) &&
    sourceEnv.carrier === "agent-convert.claude-source-env.v1" &&
    ["cwd", "harnessVersion", "instructions", "model", "provider", "sessionId"]
      .every((key) => nullableString(sourceEnv[key])),
  `${context}: invalid Claude source environment header`);
  invariant(exactKeys(lastPrompt, ["leafUuid", "sessionId", "type"]) &&
    lastPrompt.type === "last-prompt" &&
    lastPrompt.sessionId === expected.cell.targetSessionId && nonemptyString(lastPrompt.leafUuid),
  `${context}: invalid Claude last-prompt header`);

  let previousUuid = null;
  for (const [index, row] of rows.slice(0, -2).entries()) {
    invariant(["assistant", "system", "user"].includes(row?.type),
      `${context}: row ${index + 1} has an unsupported Claude type`);
    if (row.type === "system") {
      invariant(exactKeys(row, ["_agent_convert", "content", "cwd", "isSidechain",
        "parentUuid", "sessionId", "subtype", "timestamp", "type", "uuid"]) &&
        row.subtype === "agent_convert_inert" &&
        // Null since 2026-07-27, and asserted rather than merely allowed: the
        // `content` of a Claude `system` row is rendered in the transcript, so
        // any string here is converter bookkeeping shown to the reader as if it
        // were conversation. The payload rides in `_agent_convert` instead.
        row.content === null &&
        isObject(row._agent_convert),
      `${context}: row ${index + 1} invalid inert system envelope`);
      validateClaudeMarker(row._agent_convert, [], "system", `${context}: row ${index + 1}`);
    } else {
      invariant(exactKeys(row, ["_agent_convert", "cwd", "isSidechain", "message",
        "parentUuid", "sessionId", "timestamp", "type", "uuid"]) &&
        isObject(row.message) && row.message.role === row.type &&
        exactOptionalKeys(row.message, ["content", "role"], ["model"]) &&
        Array.isArray(row.message.content) && (!hasOwn(row.message, "model") ||
          nonemptyString(row.message.model)),
      `${context}: row ${index + 1} invalid role/message envelope`);
      for (const block of row.message.content) {
        invariant(exactKeys(block, ["text", "type"]) && block.type === "text" &&
          typeof block.text === "string",
          `${context}: row ${index + 1} invalid content block`);
      }
      validateClaudeMarker(row._agent_convert, row.message.content, row.type,
        `${context}: row ${index + 1}`);
    }
    invariant(row.cwd === expected.cwd && row.sessionId === expected.cell.targetSessionId &&
      row.isSidechain === false && nonemptyString(row.uuid) &&
      row.parentUuid === previousUuid && nonemptyString(row.timestamp),
    `${context}: row ${index + 1} does not bind the requested Claude launch identity`);
    if (hasOwn(row._agent_convert, "timeProvenance")) {
      invariant(row.timestamp === expected.launch.timestamp,
        `${context}: row ${index + 1} does not use the requested fallback timestamp`);
    }
    previousUuid = row.uuid;
  }
  invariant(previousUuid !== null && lastPrompt.leafUuid === previousUuid,
    `${context}: last-prompt does not select the final emitted record`);
  return {
    schema: "claude-jsonl-2.1.216+agent-convert-carriers-v1",
    records: rows.length,
    targetSessionId: lastPrompt.sessionId,
    targetCwd: expected.cwd,
    serializedLaunchFields: ["cwd", "sessionId"],
    targetTimestampFallbackRows: rows.slice(0, -2).filter((row) =>
      hasOwn(row?._agent_convert, "timeProvenance")).length,
    unobservableFromArtifact: ["targetHarnessVersion"],
  };
}

function validateCodexTimeStamp(value, context) {
  invariant(exactKeys(value, ["kind", "protocol", "state"]) &&
    value.kind === "entry_time_provenance" && value.protocol === CODEX_PROTOCOL &&
    value.state === "absent", `${context}: invalid Codex time carrier`);
}

function validateCodexSourceArchive(value, context) {
  invariant(exactKeys(value, ["generated_target_control_records", "kind", "protocol",
    "source_control_records", "source_env", "source_identity", "source_session_payload"]) &&
    value.kind === "historical_source_provenance" && value.protocol === CODEX_PROTOCOL &&
    Array.isArray(value.generated_target_control_records) &&
    Array.isArray(value.source_control_records) && isObject(value.source_identity) &&
    isObject(value.source_session_payload), `${context}: invalid Codex source archive`);
  validateSourceEnvironment(value.source_env, `${context}.source_env`);
}

function validateCodexTargetEnvelope(rows, expected, context) {
  invariant(rows.length >= 4 && rows.length % 2 === 0,
    `${context}: Codex target requires two headers and response/event pairs`);
  const launch = expected.launch;
  const header = rows[0];
  invariant(exactKeys(header, ["payload", "timestamp", "type"]) &&
    header.type === "session_meta" && header.timestamp === launch.timestamp &&
    exactKeys(header.payload, ["_agent_convert", "_agent_convert_source_archive",
      "cli_version", "cwd", "git", "id", "model_provider", "originator",
      "session_id", "source", "timestamp"]) &&
    header.payload.id === expected.cell.targetSessionId &&
    header.payload.session_id === expected.cell.targetSessionId &&
    header.payload.timestamp === launch.timestamp && header.payload.cwd === expected.cwd &&
    header.payload.cli_version === launch.harnessVersion &&
    header.payload.model_provider === launch.provider &&
    header.payload.originator === "agent-convert" && header.payload.source === "cli" &&
    header.payload.git === null && exactKeys(header.payload._agent_convert,
      ["kind", "protocol"]) && header.payload._agent_convert.kind === "session" &&
    header.payload._agent_convert.protocol === CODEX_PROTOCOL,
  `${context}: invalid Codex target session header`);
  validateCodexSourceArchive(header.payload._agent_convert_source_archive,
    `${context}: session source archive`);
  const turn = rows[1];
  invariant(exactKeys(turn, ["payload", "timestamp", "type"]) &&
    turn.type === "turn_context" && turn.timestamp === launch.timestamp &&
    exactKeys(turn.payload, ["_agent_convert", "approval_policy", "cwd", "model",
      "provenance", "sandbox_policy", "summary"]) &&
    exactKeys(turn.payload._agent_convert, ["kind", "protocol"]) &&
    turn.payload._agent_convert.kind === "explicit_target_controls" &&
    turn.payload._agent_convert.protocol === CODEX_PROTOCOL &&
    turn.payload.cwd === expected.cwd && turn.payload.model === launch.model &&
    turn.payload.approval_policy === launch.approvalPolicy &&
    turn.payload.summary === launch.summary &&
    turn.payload.provenance ===
      "explicit target controls from origin.extras.target_codex_controls" &&
    exactKeys(turn.payload.sandbox_policy, ["exclude_slash_tmp",
      "exclude_tmpdir_env_var", "network_access", "type"]) &&
    turn.payload.sandbox_policy.type === "workspace-write" &&
    turn.payload.sandbox_policy.exclude_slash_tmp === launch.excludeSlashTmp &&
    turn.payload.sandbox_policy.exclude_tmpdir_env_var === launch.excludeTmpdirEnvVar &&
    turn.payload.sandbox_policy.network_access === launch.networkAccess,
  `${context}: Codex turn_context does not bind the requested launch bundle`);

  for (let index = 2; index < rows.length; index += 2) {
    const response = rows[index];
    const event = rows[index + 1];
    invariant(exactOptionalKeys(response, ["payload", "timestamp", "type"],
      ["_agent_convert_time"]) && response.type === "response_item" &&
      isObject(response.payload) && response.payload.type === "message" &&
      ["assistant", "user"].includes(response.payload.role) &&
      exactOptionalKeys(response.payload, ["content", "role", "type"],
        ["_agent_convert"]) && Array.isArray(response.payload.content) &&
      response.payload.content.length === 1 && nonemptyString(response.timestamp),
    `${context}: row ${index + 1} invalid Codex response envelope`);
    const item = response.payload.content[0];
    const expectedItemType = response.payload.role === "assistant" ? "output_text" : "input_text";
    invariant(exactKeys(item, ["text", "type"]) && item.type === expectedItemType &&
      typeof item.text === "string", `${context}: row ${index + 1} invalid Codex text item`);
    if (hasOwn(response.payload, "_agent_convert")) {
      const marker = response.payload._agent_convert;
      invariant(exactKeys(marker, ["kind", "protocol"]) &&
        marker.protocol === CODEX_PROTOCOL && response.payload.role === "assistant" &&
        ["tool_call", "tool_result"].includes(marker.kind),
      `${context}: row ${index + 1} invalid Codex carrier stamp`);
      const carrier = marker.kind === "tool_call"
        ? exactCodexCallCarrier(item.text) : exactCodexResultCarrier(item.text);
      invariant(carrier !== null, `${context}: row ${index + 1} marked carrier is not exact`);
    }
    invariant(exactOptionalKeys(event, ["payload", "timestamp", "type"],
      ["_agent_convert_time"]) && event.type === "event_msg" &&
      event.timestamp === response.timestamp && isObject(event.payload),
    `${context}: row ${index + 2} invalid Codex event envelope`);
    if (response.payload.role === "assistant") {
      invariant(exactKeys(event.payload, ["memory_citation", "message", "phase", "type"]) &&
        event.payload.type === "agent_message" && event.payload.phase === "final_answer" &&
        event.payload.memory_citation === null && event.payload.message === item.text,
      `${context}: row ${index + 2} does not mirror its assistant response`);
    } else {
      invariant(exactKeys(event.payload,
        ["images", "local_images", "message", "text_elements", "type"]) &&
        event.payload.type === "user_message" && event.payload.message === item.text &&
        [event.payload.images, event.payload.local_images, event.payload.text_elements]
          .every(Array.isArray),
      `${context}: row ${index + 2} does not mirror its user response`);
    }
    const responseTime = hasOwn(response, "_agent_convert_time")
      ? response._agent_convert_time : null;
    const eventTime = hasOwn(event, "_agent_convert_time") ? event._agent_convert_time : null;
    invariant(jsonEqual(responseTime, eventTime),
      `${context}: response/event time provenance disagrees`);
    if (responseTime !== null) {
      validateCodexTimeStamp(responseTime,
        `${context}: rows ${index + 1}-${index + 2}`);
      invariant(response.timestamp === launch.timestamp,
        `${context}: rows ${index + 1}-${index + 2} do not use the requested fallback timestamp`);
    }
  }
  return {
    schema: "codex-jsonl-0.144.1+agent-convert-carriers-v1",
    records: rows.length,
    targetSessionId: header.payload.id,
    targetCwd: header.payload.cwd,
    targetTimestamp: header.timestamp,
    targetHarnessVersion: header.payload.cli_version,
    targetProvider: header.payload.model_provider,
    targetModel: turn.payload.model,
  };
}

function validateCursorAgentTargetEnvelope(rows, context) {
  invariant(rows.length > 0, `${context}: empty Cursor Agent target`);
  for (const [index, row] of rows.entries()) {
    invariant(isObject(row) && !hasOwn(row, "_agent_convert") &&
      exactKeys(row, ["message", "role"]) &&
      ["assistant", "user"].includes(row.role) &&
      exactKeys(row.message, ["content"]) && Array.isArray(row.message.content),
      `${context}: row ${index + 1} is not target-native Cursor Agent data`);
    for (const block of row.message.content) {
      if (block?.type === "text") {
        invariant(exactKeys(block, ["text", "type"]) && typeof block.text === "string",
          `${context}: row ${index + 1} invalid Cursor Agent text block`);
      } else if (block?.type === "tool_use") {
        const inputIsNative = isObject(block.input) ||
          (block.name === "ApplyPatch" && typeof block.input === "string");
        invariant(row.role === "assistant" &&
          exactKeys(block, ["input", "name", "type"]) &&
          nonemptyString(block.name) && inputIsNative,
        `${context}: row ${index + 1} invalid native Cursor Agent tool_use`);
      } else throw new AuditError(
        `${context}: row ${index + 1} contains a non-native Cursor Agent block`);
    }
  }
  return {
    schema: "cursor-agent-native-jsonl",
    records: rows.length,
    targetNativeOnly: true,
  };
}

export function cursorAgentRuntimeArchiveOnlyEvidence(bytes,
    context = "Cursor Agent runtime-policy source") {
  const text = Buffer.isBuffer(bytes) ? bytes.toString("utf8") : String(bytes);
  const rows = parseJsonlText(text, context);
  const nativeRows = [];
  const archiveOnlyRecords = [];
  for (const [index, row] of rows.entries()) {
    if (isObject(row) && hasOwn(row, "type")) {
      invariant(exactKeys(row, ["error", "status", "type"]) &&
        row.type === "turn_ended" && row.status === "error" &&
        nonemptyString(row.error),
      `${context}: row ${index + 1} is not the exact supported archive-only turn_ended record`);
      archiveOnlyRecords.push({
        row: index + 1,
        type: row.type,
        status: row.status,
        error: row.error,
      });
    } else {
      nativeRows.push(row);
    }
  }
  const nativeEnvelope = validateCursorAgentTargetEnvelope(nativeRows,
    `${context}: native subset`);
  invariant(archiveOnlyRecords.length > 0,
    `${context}: no archive-only turn_ended record was observed`);
  return {
    schema: "cursor-agent-runtime-archive-only-evidence.v1",
    pass: true,
    reason: CURSOR_RUNTIME_ARCHIVE_ONLY_REASON,
    nativeEnvelope,
    archiveOnlyRecords,
  };
}

export function parseSourceArtifact(format, bytes, context = `source ${format}`) {
  const text = Buffer.isBuffer(bytes) ? bytes.toString("utf8") : String(bytes);
  switch (format) {
    case "loom": return parseWireLifecycle(text, context);
    case "pi": return parsePiRows(parseJsonlText(text, context), false, context);
    case "claude": return parseClaudeRows(parseJsonlText(text, context), false, context);
    case "codex": return parseCodexRows(parseJsonlText(text, context), false, context);
    case "cursor-agent": return parseCursorAgentRows(parseJsonlText(text, context), context);
    case "hermes": return parseHermesLifecycle(text, context);
    case "gais": return parseGaisLifecycle(text, context);
    case "cursor-ide": return parseCursorIdeLifecycle(text, context);
    default: throw new AuditError(`unsupported source parser: ${format}`);
  }
}

function parseTargetArtifactDetailed(format, bytes, context, binding) {
  const text = Buffer.isBuffer(bytes) ? bytes.toString("utf8") : String(bytes);
  const expected = expectedLaunchContext(format, binding, context);
  switch (format) {
    case "loom": {
      const root = parseJsonText(text, context);
      return {
        envelope: validateLoomTargetEnvelope(root, context),
        lifecycle: parseWireLifecycle(text, context),
      };
    }
    case "pi": {
      const rows = parseJsonlText(text, context);
      return {
        envelope: validatePiTargetEnvelope(rows, expected, context),
        lifecycle: parsePiRows(rows, true, context),
      };
    }
    case "claude": {
      const rows = parseJsonlText(text, context);
      return {
        envelope: validateClaudeTargetEnvelope(rows, expected, context),
        lifecycle: parseClaudeRows(rows, true, context),
      };
    }
    case "codex": {
      const rows = parseJsonlText(text, context);
      return {
        envelope: validateCodexTargetEnvelope(rows, expected, context),
        lifecycle: parseCodexRows(rows, true, context),
      };
    }
    case "cursor-agent": {
      const rows = parseJsonlText(text, context);
      return {
        envelope: validateCursorAgentTargetEnvelope(rows, context),
        lifecycle: parseCursorAgentRows(rows, context),
      };
    }
    default: throw new AuditError(`unsupported target parser: ${format}`);
  }
}

export function parseTargetArtifact(format, bytes, context = `target ${format}`,
    binding = null) {
  return parseTargetArtifactDetailed(format, bytes, context, binding).lifecycle;
}

function reportValue(value) {
  return value === undefined ? { missing: true } : value;
}

function field(fields, path, expected, actual, pass = jsonEqual(expected, actual), note = null) {
  fields.push({
    path,
    expected: reportValue(expected),
    actual: reportValue(actual),
    pass,
    ...(note === null ? {} : { note }),
  });
}

function compareRawId(fields, path, expected, actual) {
  field(fields, `${path}.kind`, expected?.kind, actual?.kind);
  field(fields, `${path}.value`, expected?.value, actual?.value);
}

function compareBlocks(fields, path, expected, actual) {
  field(fields, `${path}.count`, expected?.length, actual?.length);
  const count = Math.max(expected?.length ?? 0, actual?.length ?? 0);
  for (let index = 0; index < count; index++) {
    const left = expected?.[index];
    const right = actual?.[index];
    field(fields, `${path}[${index}].present`, left !== undefined, right !== undefined);
    if (!left || !right) continue;
    field(fields, `${path}[${index}].kind`, left.kind, right.kind);
    if (left.kind === "text" || right.kind === "text") {
      field(fields, `${path}[${index}].text`, left.text, right.text);
    }
    if (left.kind === "media" || right.kind === "media") {
      field(fields, `${path}[${index}].mimeType`, left.mimeType, right.mimeType);
      field(fields, `${path}[${index}].locator`, left.locator, right.locator);
    }
    if (left.kind === "unmodeled" || right.kind === "unmodeled") {
      field(fields, `${path}[${index}].label`, left.label, right.label);
      field(fields, `${path}[${index}].raw`, left.raw, right.raw);
    }
  }
}

function compareError(fields, path, expected, actual) {
  field(fields, `${path}.provenance`, expected?.provenance, actual?.provenance);
  field(fields, `${path}.value`, expected?.value, actual?.value);
  field(fields, `${path}.heuristic`, expected?.heuristic, actual?.heuristic);
}

function compareLinkage(fields, path, expected, actual) {
  field(fields, `${path}.kind`, expected?.kind, actual?.kind);
  if (expected?.kind === "resolved" || actual?.kind === "resolved") {
    field(fields, `${path}.callOccurrence`, expected?.callOccurrence,
      actual?.callOccurrence);
  }
  compareRawId(fields, `${path}.rawId`, expected?.rawId, actual?.rawId);
  if (expected?.kind === "unresolved" || actual?.kind === "unresolved") {
    field(fields, `${path}.note`, expected?.note, actual?.note);
  }
}

function dispositionPass(expected, actual, policy) {
  if (expected === actual) return { pass: true, note: "exact" };
  if (expected === "historicalUnverified" && actual === "native") {
    return { pass: false, note: "historical-to-native upgrade is forbidden" };
  }
  if (expected === "native" && actual === "historicalUnverified" &&
      policy === "allow-native-to-historical") {
    return { pass: true, note: "manifest-permitted explicit downgrade" };
  }
  return { pass: false, note: "disposition change is not permitted by this cell" };
}

export function reconcileLifecycle(expected, actual, dispositionPolicy = "exact") {
  invariant(isObject(expected) && Array.isArray(expected.events),
    "expected lifecycle is invalid");
  invariant(isObject(actual) && Array.isArray(actual.events),
    "actual lifecycle is invalid");
  invariant(["exact", "allow-native-to-historical"].includes(dispositionPolicy),
    `invalid disposition policy ${dispositionPolicy}`);
  const fields = [];
  const expectedCalls = expected.events.filter((event) => event.kind === "call");
  const actualCalls = actual.events.filter((event) => event.kind === "call");
  const expectedResults = expected.events.filter((event) => event.kind === "result");
  const actualResults = actual.events.filter((event) => event.kind === "result");
  field(fields, "lifecycle.eventCount", expected.events.length, actual.events.length);
  field(fields, "lifecycle.callCount", expectedCalls.length, actualCalls.length);
  field(fields, "lifecycle.resultCount", expectedResults.length, actualResults.length);
  field(fields, "invariants.noFabricatedResult", true,
    actualResults.length <= expectedResults.length,
    actualResults.length <= expectedResults.length,
    "A successful target may not add a result absent from the source fixture.");

  let historicalUpgrade = false;
  const count = Math.max(expected.events.length, actual.events.length);
  for (let index = 0; index < count; index++) {
    const left = expected.events[index];
    const right = actual.events[index];
    field(fields, `events[${index}].present`, left !== undefined, right !== undefined);
    if (!left || !right) continue;
    field(fields, `events[${index}].kind`, left.kind, right.kind);
    field(fields, `events[${index}].eventOrder`, left.eventOrder, right.eventOrder);
    compareRawId(fields, `events[${index}].rawId`, left.rawId, right.rawId);
    field(fields, `events[${index}].idOccurrence`, left.idOccurrence,
      right.idOccurrence);
    const disposition = dispositionPass(left.disposition, right.disposition,
      dispositionPolicy);
    field(fields, `events[${index}].disposition`, left.disposition,
      right.disposition, disposition.pass, disposition.note);
    if (left.disposition === "historicalUnverified" && right.disposition === "native") {
      historicalUpgrade = true;
    }
    if (left.kind === "call" || right.kind === "call") {
      field(fields, `events[${index}].callOccurrence`, left.callOccurrence,
        right.callOccurrence);
      field(fields, `events[${index}].rawName`, left.rawName, right.rawName);
      field(fields, `events[${index}].arguments`, left.arguments, right.arguments);
      field(fields, `events[${index}].state`, left.state, right.state);
    }
    if (left.kind === "result" || right.kind === "result") {
      field(fields, `events[${index}].resultOccurrence`, left.resultOccurrence,
        right.resultOccurrence);
      compareBlocks(fields, `events[${index}].blocks`, left.blocks, right.blocks);
      compareError(fields, `events[${index}].error`, left.error, right.error);
      compareLinkage(fields, `events[${index}].linkage`, left.linkage, right.linkage);
    }
  }
  field(fields, "invariants.noHistoricalToNativeUpgrade", true,
    !historicalUpgrade, !historicalUpgrade,
    "Historical source data may never be upgraded to native target execution state.");
  return {
    pass: fields.every((item) => item.pass),
    dispositionPolicy,
    sourceDigest: sha256(compactCanonical(expected)),
    targetDigest: sha256(compactCanonical(actual)),
    fields,
  };
}

export function auditTargetIdProvenance(sourceLifecycle, targetLifecycle) {
  const sourceCalls = sourceLifecycle.events.filter((event) => event.kind === "call");
  const targetCalls = targetLifecycle.events.filter((event) => event.kind === "call");
  const evidence = Array.isArray(targetLifecycle.idProvenanceEvidence)
    ? targetLifecycle.idProvenanceEvidence
    : [];
  const calls = sourceCalls.map((sourceCall) => {
    const targetCall = targetCalls[sourceCall.callOccurrence] ?? null;
    const semanticIdEqual = targetCall !== null &&
      jsonEqual(sourceCall.rawId, targetCall.rawId);
    const matchingEvidence = evidence.filter((item) =>
      item?.reversible === true && item.semanticUse === "evidence-only" &&
      item.callOccurrence === sourceCall.callOccurrence &&
      jsonEqual(item.sourceRawId, sourceCall.rawId));
    const status = semanticIdEqual
      ? "semantic-equality"
      : matchingEvidence.length > 0 ? "provenance-only" : "unproven-loss";
    return {
      callOccurrence: sourceCall.callOccurrence,
      sourceRawId: sourceCall.rawId,
      targetRawId: targetCall?.rawId ?? null,
      semanticIdEqual,
      status,
      reversibleEvidence: matchingEvidence,
    };
  });
  return {
    evidenceIsNonSemantic: true,
    semanticIdEqualityPass: calls.every((call) => call.semanticIdEqual),
    provenanceOnlyCalls: calls.filter((call) => call.status === "provenance-only").length,
    unprovenLossCalls: calls.filter((call) => call.status === "unproven-loss").length,
    calls,
  };
}

export function lifecycleCoverage(lifecycle) {
  const calls = lifecycle.events.filter((event) => event.kind === "call");
  const results = lifecycle.events.filter((event) => event.kind === "result");
  const frequencies = new Map();
  for (const call of calls) {
    if (call.rawId.kind === "value") {
      frequencies.set(call.rawId.value, (frequencies.get(call.rawId.value) ?? 0) + 1);
    }
  }
  return {
    calls: calls.length,
    results: results.length,
    duplicateCallIds: calls.filter((call) => call.rawId.kind === "value" &&
      frequencies.get(call.rawId.value) > 1).length,
    missingCallIds: calls.filter((call) => call.rawId.kind === "missing").length,
    openCalls: calls.filter((call) => call.state === "open-or-interrupted").length,
    resultBlockKinds: [...new Set(results.flatMap((result) =>
      result.blocks.map((block) => block.kind)))].sort(),
    errorProvenance: [...new Set(results.map((result) =>
      result.error.provenance))].sort(),
  };
}

export function checkFixtureCoverage(expected, lifecycle) {
  const actual = lifecycleCoverage(lifecycle);
  return {
    pass: jsonEqual(expected, actual),
    expected,
    actual,
  };
}

function validateLaunch(target) {
  invariant(exactKeys(target, ["extension", "launch", "name"]) &&
    TARGET_NAMES.includes(target.name), "manifest target is malformed");
  invariant(target.extension === TARGET_EXTENSIONS[target.name],
    `${target.name} target extension must be exactly ${TARGET_EXTENSIONS[target.name]}`);
  invariant(jsonEqual(target.launch, CLOSED_TARGET_LAUNCHES[target.name]),
    `${target.name} launch bundle must equal the closed audit bundle`);
}

function validateCoverage(coverage, sourceName) {
  invariant(exactKeys(coverage, ["calls", "duplicateCallIds", "errorProvenance",
    "missingCallIds", "openCalls", "resultBlockKinds", "results"]),
  `${sourceName} coverage must expose the complete closed schema`);
  invariant(["calls", "duplicateCallIds", "missingCallIds", "openCalls", "results"]
    .every((key) => Number.isInteger(coverage[key]) && coverage[key] >= 0),
  `${sourceName} coverage counts must be nonnegative integers`);
  invariant(Array.isArray(coverage.resultBlockKinds) &&
    coverage.resultBlockKinds.every(nonemptyString) &&
    jsonEqual(coverage.resultBlockKinds,
      [...new Set(coverage.resultBlockKinds)].sort()),
  `${sourceName} result block kinds must be unique and sorted`);
  invariant(Array.isArray(coverage.errorProvenance) &&
    coverage.errorProvenance.every(nonemptyString) &&
    jsonEqual(coverage.errorProvenance,
      [...new Set(coverage.errorProvenance)].sort()),
  `${sourceName} error provenance values must be unique and sorted`);
}

function expectedPairs() {
  return SOURCE_NAMES.flatMap((source) => TARGET_NAMES.map((target) => ({
    source,
    target,
    name: `${source}__to__${target}`,
  })));
}

export function validateManifest(manifest) {
  invariant(exactKeys(manifest, ["cells", "schema", "sources", "targets"]) &&
    manifest.schema === "agent-convert.lifecycle-matrix-manifest.v1",
  "unsupported lifecycle matrix manifest schema");
  invariant(Array.isArray(manifest.sources) && Array.isArray(manifest.targets) &&
    Array.isArray(manifest.cells), "manifest census arrays are required");
  invariant(jsonEqual(manifest.sources.map((source) => source.name), SOURCE_NAMES),
    "manifest sources must be the closed declared source order");
  invariant(jsonEqual(manifest.targets.map((target) => target.name), TARGET_NAMES),
    "manifest targets must be the closed declared target order");
  for (const source of manifest.sources) {
    invariant(exactKeys(source, ["coverage", "fixture", "limitations", "name"]) &&
      SOURCE_NAMES.includes(source.name) && nonemptyString(source.fixture) &&
      !source.fixture.includes("/") && !source.fixture.includes("\\") &&
      isObject(source.coverage) && Array.isArray(source.limitations) &&
      source.limitations.length > 0 && source.limitations.every(nonemptyString),
    `manifest source ${source?.name ?? "unknown"} is incomplete`);
    validateCoverage(source.coverage, source.name);
  }
  for (const target of manifest.targets) validateLaunch(target);
  invariant(manifest.cells.length === 40,
    `manifest must contain exactly 40 cells, got ${manifest.cells.length}`);

  const names = new Set();
  const pairs = new Set();
  const sessionIds = new Set();
  const expected = new Map(expectedPairs().map((pair) =>
    [`${pair.source}\u0000${pair.target}`, pair]));
  for (const cell of manifest.cells) {
    invariant(exactKeys(cell,
      ["expected", "name", "source", "target", "targetSessionId"]) &&
      nonemptyString(cell.name) &&
      nonemptyString(cell.source) && nonemptyString(cell.target) &&
      isObject(cell.expected), "manifest cell is malformed");
    invariant(!names.has(cell.name), `duplicate matrix cell name: ${cell.name}`);
    names.add(cell.name);
    const pairKey = `${cell.source}\u0000${cell.target}`;
    invariant(!pairs.has(pairKey),
      `duplicate matrix pair: ${cell.source} to ${cell.target}`);
    pairs.add(pairKey);
    const pair = expected.get(pairKey);
    invariant(pair, `unexpected matrix pair: ${cell.source} to ${cell.target}`);
    invariant(cell.name === pair.name,
      `cell ${cell.name} must be named ${pair.name}`);
    const needsSession = ["pi", "claude", "codex"].includes(cell.target);
    if (needsSession) {
      invariant(typeof cell.targetSessionId === "string" &&
        /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-8[0-9a-f]{3}-[0-9a-f]{12}$/.test(
          cell.targetSessionId), `${cell.name} has an invalid target session ID`);
      invariant(!sessionIds.has(cell.targetSessionId),
        `${cell.name} reuses a target session ID`);
      sessionIds.add(cell.targetSessionId);
    } else {
      invariant(cell.targetSessionId === null,
        `${cell.name} must not declare target launch identity`);
    }
    if (cell.expected.kind === "success") {
      invariant(exactKeys(cell.expected, ["disposition", "kind"]) &&
        ["exact", "allow-native-to-historical"].includes(cell.expected.disposition),
      `${cell.name} has an invalid success policy`);
    } else if (cell.expected.kind === "refusal") {
      const destructiveLoss = exactKeys(cell.expected,
        ["kind", "obligationRepr", "policy", "status"]) &&
        cell.expected.status === 3 && cell.expected.policy === "destructiveLoss" &&
        typeof cell.expected.obligationRepr === "string" &&
        cell.expected.obligationRepr.startsWith("[Loom.Ops.Obligation.");
      const cursorRuntimeArchiveOnly = exactKeys(cell.expected,
        ["kind", "policy", "reason", "status"]) &&
        cell.expected.status === 3 &&
        cell.expected.policy === CURSOR_RUNTIME_ARCHIVE_ONLY_POLICY &&
        cell.expected.reason === CURSOR_RUNTIME_ARCHIVE_ONLY_REASON &&
        cell.name === "cursor-agent__to__cursor-agent" &&
        cell.source === "cursor-agent" && cell.target === "cursor-agent";
      invariant(destructiveLoss || cursorRuntimeArchiveOnly,
        `${cell.name} has an invalid refusal policy`);
      expectedRefusalStderr(cell);
    } else {
      throw new AuditError(`${cell.name} has an unknown expected outcome`);
    }
  }
  for (const pair of expectedPairs()) {
    invariant(pairs.has(`${pair.source}\u0000${pair.target}`),
      `missing matrix pair: ${pair.name}`);
  }
  return manifest;
}

export function targetLaunchArgs(target, cell) {
  const launch = target.launch;
  if (launch.kind === "none") return [];
  const cwd = `${launch.cwdPrefix}/${cell.name}`;
  if (target.name === "pi") return [
    "--target-cwd", cwd,
    "--target-provider", launch.provider,
    "--target-model", launch.model,
    "--target-session-id", cell.targetSessionId,
    "--target-timestamp", launch.timestamp,
    "--target-harness-version", launch.harnessVersion,
    "--pi-assistant-history", launch.assistantHistory,
  ];
  if (target.name === "claude") return [
    "--target-cwd", cwd,
    "--target-session-id", cell.targetSessionId,
    "--target-timestamp", launch.timestamp,
    "--target-harness-version", launch.harnessVersion,
  ];
  if (target.name === "codex") return [
    "--target-cwd", cwd,
    "--target-provider", launch.provider,
    "--target-model", launch.model,
    "--target-session-id", cell.targetSessionId,
    "--target-timestamp", launch.timestamp,
    "--target-harness-version", launch.harnessVersion,
    "--target-codex-approval-policy", launch.approvalPolicy,
    "--target-codex-network-access", String(launch.networkAccess),
    "--target-codex-exclude-tmpdir-env-var", String(launch.excludeTmpdirEnvVar),
    "--target-codex-exclude-slash-tmp", String(launch.excludeSlashTmp),
    "--target-codex-summary", launch.summary,
  ];
  throw new AuditError(`no launch argument encoder for ${target.name}`);
}

export function validateCandidateReceipt(receipt, target, cell, identity,
    inputPath, outputPath) {
  const launch = target.launch;
  const cwd = launch.kind === "none" ? null : `${launch.cwdPrefix}/${cell.name}`;
  const expected = target.name === "pi" ? {
    targetCwd: cwd,
    targetProvider: launch.provider,
    targetModel: launch.model,
    targetSessionId: cell.targetSessionId,
    targetTimestamp: launch.timestamp,
    targetHarnessVersion: launch.harnessVersion,
  } : target.name === "claude" ? {
    targetCwd: cwd,
    targetProvider: null,
    targetModel: null,
    targetSessionId: cell.targetSessionId,
    targetTimestamp: launch.timestamp,
    targetHarnessVersion: launch.harnessVersion,
  } : target.name === "codex" ? {
    targetCwd: cwd,
    targetProvider: launch.provider,
    targetModel: launch.model,
    targetSessionId: cell.targetSessionId,
    targetTimestamp: launch.timestamp,
    targetHarnessVersion: launch.harnessVersion,
  } : {
    targetCwd: null,
    targetProvider: null,
    targetModel: null,
    targetSessionId: null,
    targetTimestamp: null,
    targetHarnessVersion: null,
  };
  const checks = [
    check("candidateSelfReport.object", true, isObject(receipt), isObject(receipt)),
    check("candidateSelfReport.from", cell.source, receipt?.from),
    check("candidateSelfReport.to", cell.target, receipt?.to),
    check("candidateSelfReport.input", inputPath, receipt?.input),
    check("candidateSelfReport.output", outputPath, receipt?.output),
    check("candidateSelfReport.engine", identity.engine, receipt?.engine),
    check("candidateSelfReport.engineVersion", identity.engineVersion,
      receipt?.engineVersion),
    check("candidateSelfReport.coreRevision", identity.coreRevision,
      receipt?.coreRevision),
    check("candidateSelfReport.protocolVersion", identity.protocolVersion,
      receipt?.protocolVersion),
    check("candidateSelfReport.targetTriple", identity.targetTriple,
      receipt?.targetTriple),
    ...Object.entries(expected).map(([key, value]) =>
      check(`candidateSelfReport.${key}`, value, receipt?.[key])),
    check("candidateSelfReport.exportObligations", true,
      Array.isArray(receipt?.exportObligations), Array.isArray(receipt?.exportObligations)),
    check("candidateSelfReport.exportObligationCount", receipt?.exportObligations?.length,
      receipt?.exportObligationCount,
      Array.isArray(receipt?.exportObligations) &&
        receipt.exportObligationCount === receipt.exportObligations.length),
  ];
  return {
    pass: checks.every((item) => item.pass),
    evidenceKind: "candidate-self-report",
    establishesSourceProvenance: false,
    checks,
  };
}

const REFUSAL_REPR_LINE_WIDTH = 120;

function refusalObligationItems(repr) {
  invariant(typeof repr === "string" && repr.startsWith("[") && repr.endsWith("]"),
    "refusal obligation representation must be a bracketed list");
  const body = repr.slice(1, -1);
  const items = [];
  const closing = { "[": "]", "(": ")", "{": "}" };
  const stack = [];
  let quoted = false;
  let escaped = false;
  let itemStart = 0;
  for (let index = 0; index < body.length; index += 1) {
    const char = body[index];
    if (quoted) {
      if (escaped) escaped = false;
      else if (char === "\\") escaped = true;
      else if (char === "\"") quoted = false;
      continue;
    }
    if (char === "\"") {
      quoted = true;
      continue;
    }
    if (Object.hasOwn(closing, char)) {
      stack.push(closing[char]);
      continue;
    }
    if (["]", ")", "}"].includes(char)) {
      invariant(stack.pop() === char,
        "refusal obligation representation has mismatched delimiters");
      continue;
    }
    if (char === "," && stack.length === 0) {
      items.push(body.slice(itemStart, index));
      itemStart = index + 1;
    }
  }
  invariant(!quoted && !escaped && stack.length === 0,
    "refusal obligation representation is unterminated");
  items.push(body.slice(itemStart));
  const normalized = items.map((item) => item.trim());
  invariant(normalized.length > 0 && normalized.every((item) =>
    item.startsWith("Loom.Ops.Obligation.") && item.length > 20),
  "refusal obligation representation contains an invalid item");
  invariant(`[${normalized.join(", ")}]` === repr,
    "refusal obligation representation is not canonical");
  return normalized;
}

function renderRefusalObligations(repr) {
  const items = refusalObligationItems(repr);
  return repr.length <= REFUSAL_REPR_LINE_WIDTH
    ? repr
    : `[${items.join(",\n ")}]`;
}

function expectedRefusalStderr(cell) {
  if (cell.expected.policy === CURSOR_RUNTIME_ARCHIVE_ONLY_POLICY) {
    return "export error: target 'cursor-agent' validity preflight failed: " +
      `${CURSOR_NATIVE_PAYLOAD_PREFLIGHT}\n`;
  }
  const renderedObligations = renderRefusalObligations(
    cell.expected.obligationRepr);
  return `export error: target '${cell.target}' has destructive export obligations: ` +
    `${renderedObligations} — refusing silent loss; use the loom wire target ` +
    "to preserve the full transcript\n";
}

function refusalMatch(cell, stderr) {
  if (stderr !== expectedRefusalStderr(cell)) return null;
  return {
    policy: cell.expected.policy,
    reason: cell.expected.policy === "destructiveLoss"
      ? cell.expected.obligationRepr
      : cell.expected.reason,
  };
}

function check(path, expected, actual, pass = jsonEqual(expected, actual)) {
  return { path, expected: reportValue(expected), actual: reportValue(actual), pass };
}

function observationText(value) {
  if (Buffer.isBuffer(value)) return value.toString("utf8");
  if (value instanceof Uint8Array) {
    return Buffer.from(value.buffer, value.byteOffset, value.byteLength).toString("utf8");
  }
  return String(value ?? "");
}

function observationBytes(value) {
  if (Buffer.isBuffer(value)) return value;
  if (value instanceof Uint8Array) {
    return Buffer.from(value.buffer, value.byteOffset, value.byteLength);
  }
  return Buffer.from(String(value ?? ""), "utf8");
}

export function evaluateRefusalCell(cell, observation, runtimePolicyEvidence = null) {
  const stdout = observationText(observation.stdout);
  const stderr = observationText(observation.stderr);
  const match = refusalMatch(cell, stderr);
  const beforeBytes = observationBytes(observation.beforeBytes);
  const afterBytes = observationBytes(observation.afterBytes);
  const checks = [
    check("refusal.exitStatus", 3, observation.status),
    check("refusal.signal", null, observation.signal ?? null),
    check("refusal.exactGoldenStderr", expectedRefusalStderr(cell), stderr,
      stderr === expectedRefusalStderr(cell)),
    check("refusal.policy", cell.expected.policy, match?.policy ?? null),
    ...(cell.expected.policy === "destructiveLoss"
      ? [check("refusal.obligationRepr", cell.expected.obligationRepr,
          match?.reason ?? null)]
      : [
          check("refusal.runtimePolicyCell", true,
            cell.name === "cursor-agent__to__cursor-agent" &&
              cell.source === "cursor-agent" && cell.target === "cursor-agent" &&
              cell.expected.reason === CURSOR_RUNTIME_ARCHIVE_ONLY_REASON),
          check("refusal.runtimeReason", cell.expected.reason,
            match?.reason ?? null),
          check("refusal.runtimePolicyEvidence", true,
            runtimePolicyEvidence?.pass === true,
            runtimePolicyEvidence?.pass === true &&
              runtimePolicyEvidence.schema ===
                "cursor-agent-runtime-archive-only-evidence.v1" &&
              runtimePolicyEvidence.reason === CURSOR_RUNTIME_ARCHIVE_ONLY_REASON &&
              runtimePolicyEvidence.archiveOnlyRecords?.length > 0 &&
              runtimePolicyEvidence.nativeEnvelope?.targetNativeOnly === true),
        ]),
    check("refusal.noArtifactReport", "", stdout, observationBytes(observation.stdout).length === 0),
    check("refusal.priorArtifactExists", true, observation.artifactExistedBefore === true,
      observation.artifactExistedBefore === true),
    check("refusal.artifactStillExists", true, observation.artifactExistsAfter === true,
      observation.artifactExistsAfter === true),
    check("refusal.artifactRemainsRegularFile", true,
      observation.artifactRegularFileAfter === true,
      observation.artifactRegularFileBefore === true &&
        observation.artifactRegularFileAfter === true),
    check("refusal.sentinelBytesPreserved", observation.beforeSha256,
      observation.afterSha256,
      observation.beforeSha256 !== null &&
        observation.beforeSha256 === observation.afterSha256),
    check("refusal.sentinelSizePreserved", beforeBytes.length, afterBytes.length,
      beforeBytes.length === afterBytes.length),
    check("refusal.sentinelExactBytesPreserved", true, beforeBytes.equals(afterBytes),
      beforeBytes.length > 0 && beforeBytes.equals(afterBytes)),
    check("refusal.sentinelPostExitBindingPreserved", observation.beforeBinding,
      observation.afterBinding,
      observation.beforeBinding !== null && observation.afterBinding !== null &&
        jsonEqual(observation.beforeBinding, observation.afterBinding)),
    check("refusal.noStageBefore", false, observation.stageBefore === true,
      observation.stageBefore === false),
    check("refusal.noStageAfter", false, observation.stageAfter === true,
      observation.stageAfter === false),
  ];
  return {
    pass: checks.every((item) => item.pass),
    checks,
    exactReason: match?.reason ?? null,
  };
}

export function evaluateSuccessCell(cell, observation, expectedLifecycle,
    targetLifecycle = null, candidateReceipt = null) {
  const checks = [
    check("success.exitStatus", 0, observation.status),
    check("success.signal", null, observation.signal ?? null),
    check("success.noPriorArtifact", false, observation.artifactExistedBefore === true,
      observation.artifactExistedBefore === false),
    check("success.artifactExists", true, observation.artifactExistsAfter === true,
      observation.artifactExistsAfter === true),
    check("success.artifactIsRegularFile", true,
      observation.artifactRegularFileAfter === true,
      observation.artifactRegularFileAfter === true),
    check("success.noStageBefore", false, observation.stageBefore === true,
      observation.stageBefore === false),
    check("success.noStageAfter", false, observation.stageAfter === true,
      observation.stageAfter === false),
    check("success.targetParsed", true, targetLifecycle !== null,
      targetLifecycle !== null),
    check("success.candidateSelfReportValidated", true, candidateReceipt?.pass === true,
      candidateReceipt?.pass === true),
  ];
  const reconciliation = targetLifecycle === null ? null
    : reconcileLifecycle(expectedLifecycle, targetLifecycle,
      cell.expected.disposition);
  return {
    pass: checks.every((item) => item.pass) && reconciliation?.pass === true &&
      candidateReceipt?.pass === true,
    checks,
    reconciliation,
  };
}

function parseCli(args) {
  const parsed = {};
  const allowed = new Set(["--loom", "--scratch", "--output", "--report"]);
  let requireImmutable = false;
  let immutableSeen = false;
  for (let index = 0; index < args.length;) {
    const flag = args[index];
    if (flag === "--require-immutable") {
      invariant(!immutableSeen, "duplicate option --require-immutable");
      immutableSeen = true;
      requireImmutable = true;
      index++;
      continue;
    }
    const value = args[index + 1];
    invariant(allowed.has(flag) && nonemptyString(value),
      "usage: audit-lifecycle-matrix.mjs --loom <binary> --scratch <new-dir> --output <new-dir> --report <new-json> [--require-immutable]");
    invariant(parsed[flag] === undefined, `duplicate option ${flag}`);
    parsed[flag] = resolve(value);
    index += 2;
  }
  invariant([...allowed].every((flag) => parsed[flag]),
    "usage: audit-lifecycle-matrix.mjs --loom <binary> --scratch <new-dir> --output <new-dir> --report <new-json> [--require-immutable]");
  return {
    loom: parsed["--loom"],
    scratch: parsed["--scratch"],
    output: parsed["--output"],
    report: parsed["--report"],
    requireImmutable,
  };
}

function pathContains(parent, child) {
  return child === parent || child.startsWith(`${parent}${sep}`);
}

function containedFile(root, leaf, context) {
  invariant(nonemptyString(leaf) && basename(leaf) === leaf && leaf !== "." && leaf !== "..",
    `${context}: unsafe file name`);
  const path = resolve(root, leaf);
  invariant(path !== root && pathContains(root, path) && dirname(path) === root,
    `${context}: path escapes its owned root`);
  return path;
}

function validateRuntimePaths(paths) {
  invariant(existsSync(paths.loom) && statSync(paths.loom).isFile(),
    `Loom binary is not a file: ${paths.loom}`);
  invariant(!existsSync(paths.scratch), `scratch path already exists: ${paths.scratch}`);
  invariant(!existsSync(paths.output), `output path already exists: ${paths.output}`);
  invariant(!existsSync(paths.report), `report path already exists: ${paths.report}`);
  invariant(!pathContains(paths.scratch, paths.output) &&
    !pathContains(paths.output, paths.scratch),
  "scratch and output paths must be disjoint");
  invariant(!pathContains(paths.scratch, paths.report) &&
    !pathContains(paths.output, paths.report),
  "report path must be outside scratch and output paths");
}

function runProcess(executable, args) {
  const result = spawnSync(executable, args, {
    cwd: utilsRoot,
    encoding: null,
    maxBuffer: MAX_BUFFER,
  });
  if (result.error) throw new AuditError(`cannot execute ${executable}: ${result.error.message}`);
  return {
    status: result.status,
    signal: result.signal,
    stdout: result.stdout ?? Buffer.alloc(0),
    stderr: result.stderr ?? Buffer.alloc(0),
  };
}

export function readFileBinding(path, context) {
  const requestedPath = resolve(path);
  let descriptor;
  try {
    const pathAtOpen = lstatSync(requestedPath);
    descriptor = openSync(requestedPath, fsConstants.O_RDONLY);
    const opened = fstatSync(descriptor);
    invariant(opened.isFile(), `${context}: not a regular file: ${requestedPath}`);
    const bytes = readFileSync(descriptor);
    const afterRead = fstatSync(descriptor);
    const pathAfterRead = lstatSync(requestedPath);
    const pathStat = statSync(requestedPath);
    const realPath = realpathSync(requestedPath);
    invariant(afterRead.dev === opened.dev && afterRead.ino === opened.ino &&
      afterRead.size === bytes.length && pathStat.dev === opened.dev &&
      pathStat.ino === opened.ino && pathAfterRead.dev === pathAtOpen.dev &&
      pathAfterRead.ino === pathAtOpen.ino &&
      pathAfterRead.mode === pathAtOpen.mode && pathAfterRead.size === pathAtOpen.size,
    `${context}: file identity changed while it was loaded`);
    return {
      path: requestedPath,
      realPath,
      pathDevice: String(pathAtOpen.dev),
      pathInode: String(pathAtOpen.ino),
      pathMode: pathAtOpen.mode & 0o7777,
      pathType: pathAtOpen.isSymbolicLink() ? "symbolic-link" : "regular-file",
      device: String(opened.dev),
      inode: String(opened.ino),
      mode: opened.mode & 0o7777,
      bytes,
      size: bytes.length,
      sha256: sha256(bytes),
    };
  } catch (error) {
    if (error instanceof AuditError) throw error;
    throw new AuditError(`${context}: cannot bind ${requestedPath}: ${error.message}`);
  } finally {
    if (descriptor !== undefined) closeSync(descriptor);
  }
}

function bindingMetadata(binding) {
  if (binding === null) return null;
  return {
    path: binding.path,
    realPath: binding.realPath,
    pathDevice: binding.pathDevice,
    pathInode: binding.pathInode,
    pathMode: binding.pathMode,
    pathType: binding.pathType,
    device: binding.device,
    inode: binding.inode,
    mode: binding.mode,
    bytes: binding.size,
    sha256: binding.sha256,
  };
}

function bindingsEqual(left, right) {
  return left !== null && right !== null &&
    ["path", "realPath", "pathDevice", "pathInode", "pathMode", "pathType",
      "device", "inode", "mode", "size", "sha256"]
      .every((key) => left[key] === right[key]);
}

function observeBinding(path, context) {
  try {
    return readFileBinding(path, context);
  } catch {
    return null;
  }
}

export function fileBindingMatches(binding, context = "bound file") {
  return bindingsEqual(binding, observeBinding(binding.path, context));
}

function stabilityReport(start, context) {
  const end = observeBinding(start.path, context);
  return {
    start: bindingMetadata(start),
    end: bindingMetadata(end),
    unchanged: bindingsEqual(start, end),
  };
}

export function writeBoundSnapshot(sourceBinding, destination, mode, context) {
  invariant(!existsSync(destination), `${context}: snapshot path already exists`);
  writeFileSync(destination, sourceBinding.bytes, { flag: "wx", mode });
  chmodSync(destination, mode);
  const snapshot = readFileBinding(destination, context);
  invariant(snapshot.size === sourceBinding.size &&
    snapshot.sha256 === sourceBinding.sha256 && snapshot.mode === mode,
  `${context}: snapshot bytes or mode disagree with the loaded source`);
  return snapshot;
}

function directoryBinding(path, context) {
  const stat = statSync(path);
  invariant(stat.isDirectory(), `${context}: expected a directory`);
  return {
    path: resolve(path),
    realPath: realpathSync(path),
    device: String(stat.dev),
    inode: String(stat.ino),
  };
}

function assertDirectoryBinding(expected, context) {
  const actual = directoryBinding(expected.path, context);
  invariant(jsonEqual(expected, actual), `${context}: directory identity changed`);
}

function assertFileBinding(expected, context) {
  const actual = readFileBinding(expected.path, context);
  invariant(bindingsEqual(expected, actual), `${context}: bound file changed`);
}

export function validateCandidateIdentity(identity, requireImmutable = false) {
  invariant(exactKeys(identity, ["coreRevision", "engine", "engineVersion",
    "protocolVersion", "sourcePath", "sourceRepository", "targetTriple",
    "wireSchemas"]), "Loom version response must expose the complete core identity contract");
  invariant(identity.engine === "lean" && nonemptyString(identity.engineVersion) &&
    nonemptyString(identity.coreRevision) && identity.protocolVersion === "loom.cli.v1" &&
    identity.sourceRepository === "https://github.com/theoriclabs/agent-convert-lean" &&
    identity.sourcePath === "." && nonemptyString(identity.targetTriple) &&
    Array.isArray(identity.wireSchemas) && identity.wireSchemas.length > 0 &&
    identity.wireSchemas.every(nonemptyString) &&
    new Set(identity.wireSchemas).size === identity.wireSchemas.length &&
    identity.wireSchemas.includes("loom.transcript.v0"),
  "Loom version response has an invalid core identity contract");
  if (requireImmutable) {
    invariant(/^[0-9a-f]{40}$/.test(identity.coreRevision),
      `immutable release audit requires a 40-hex coreRevision, got ${identity.coreRevision}`);
  }
  return identity;
}

function candidateIdentity(runCandidate, requireImmutable) {
  const result = runCandidate(["version", "--json"], "candidate version");
  invariant(result.status === 0 && result.signal === null,
    `Loom version failed with status ${result.status}`);
  const identity = parseJsonText(result.stdout.toString("utf8"), "Loom version");
  return validateCandidateIdentity(identity, requireImmutable);
}

function fileObservation(path) {
  if (!existsSync(path)) {
    return {
      exists: false,
      bytes: 0,
      sha256: null,
      content: null,
      binding: null,
    };
  }
  const loaded = readFileBinding(path, `artifact observation ${path}`);
  return {
    exists: true,
    bytes: loaded.size,
    sha256: loaded.sha256,
    content: loaded.bytes,
    binding: bindingMetadata(loaded),
  };
}

function runMutationSelfTest(harnessBindings, harnessSnapshots) {
  for (const [name, binding] of Object.entries(harnessSnapshots)) {
    assertFileBinding(binding, `mutation self-test ${name} snapshot before execution`);
  }
  const processResult = runProcess(process.execPath, [harnessSnapshots.selfTest.path]);
  for (const [name, binding] of Object.entries(harnessSnapshots)) {
    assertFileBinding(binding, `mutation self-test ${name} snapshot after execution`);
  }
  let result = null;
  let parserError = null;
  try {
    result = parseJsonText(processResult.stdout.toString("utf8"),
      "lifecycle mutation self-test result");
    invariant(exactKeys(result, ["harnessScriptSha256", "manifestSha256", "pass",
      "positiveChecks", "rejectedMutations", "schema", "selfTestScriptSha256",
      "totalChecks"]) &&
      result.schema === "agent-convert.lifecycle-matrix-self-test.v1" &&
      typeof result.pass === "boolean" && Number.isInteger(result.positiveChecks) &&
      result.positiveChecks > 0 && Number.isInteger(result.rejectedMutations) &&
      result.rejectedMutations > 0 &&
      result.totalChecks === result.positiveChecks + result.rejectedMutations,
    "mutation self-test result has an invalid machine-readable schema");
  } catch (error) {
    parserError = error instanceof Error ? error.message : String(error);
  }
  const hashesMatch = result !== null &&
    result.harnessScriptSha256 === harnessBindings.script.sha256 &&
    result.selfTestScriptSha256 === harnessBindings.selfTest.sha256 &&
    result.manifestSha256 === harnessBindings.manifest.sha256;
  const pass = processResult.status === 0 && processResult.signal === null &&
    processResult.stderr.length === 0 && result?.pass === true && hashesMatch;
  return {
    pass,
    sourceScript: bindingMetadata(harnessBindings.selfTest),
    executionScriptSnapshot: bindingMetadata(harnessSnapshots.selfTest),
    importedHarnessSnapshot: bindingMetadata(harnessSnapshots.script),
    loadedManifestSnapshot: bindingMetadata(harnessSnapshots.manifest),
    process: {
      exitStatus: processResult.status,
      signal: processResult.signal,
      stdoutBytes: processResult.stdout.length,
      stdoutSha256: sha256(processResult.stdout),
      stderrBytes: processResult.stderr.length,
      stderrSha256: sha256(processResult.stderr),
    },
    hashesMatchStartLoadedHarness: hashesMatch,
    result,
    ...(parserError === null ? {} : { parserError }),
  };
}

async function runMatrix(paths) {
  validateRuntimePaths(paths);

  const harnessBindings = {
    script: readFileBinding(scriptPath, "audit script at start"),
    selfTest: readFileBinding(selfTestPath, "mutation self-test at start"),
    manifest: readFileBinding(manifestPath, "lifecycle manifest at start"),
  };
  const manifest = validateManifest(parseJsonText(
    harnessBindings.manifest.bytes.toString("utf8"), "lifecycle manifest"));
  const candidateOriginal = readFileBinding(paths.loom, "original candidate at start");
  const fixtureRootReal = realpathSync(fixtureRoot);

  const loadedSources = new Map();
  for (const source of manifest.sources) {
    const path = containedFile(fixtureRootReal, source.fixture,
      `${source.name} fixture source`);
    const originalBinding = readFileBinding(path, `${source.name} fixture at start`);
    const lifecycle = parseSourceArtifact(source.name, originalBinding.bytes,
      source.fixture);
    const coverage = checkFixtureCoverage(source.coverage, lifecycle);
    invariant(coverage.pass,
      `${source.name} fixture coverage disagrees with the closed manifest: ` +
      compactCanonical(coverage));
    const runtimePolicyEvidence = source.name === "cursor-agent"
      ? cursorAgentRuntimeArchiveOnlyEvidence(originalBinding.bytes, source.fixture)
      : null;
    loadedSources.set(source.name, {
      source,
      originalBinding,
      lifecycle,
      coverage,
      runtimePolicyEvidence,
    });
  }

  mkdirSync(dirname(paths.scratch), { recursive: true });
  mkdirSync(paths.scratch, { mode: 0o700 });
  const scratchRoot = realpathSync(paths.scratch);
  const candidateDir = containedFile(scratchRoot, "candidate", "candidate snapshot directory");
  const fixtureSnapshotDir = containedFile(scratchRoot, "fixtures", "fixture snapshot directory");
  const harnessSnapshotRoot = containedFile(scratchRoot, "harness",
    "harness snapshot root");
  const harnessScriptsDir = containedFile(harnessSnapshotRoot, "scripts",
    "harness scripts snapshot directory");
  const harnessTestdataDir = containedFile(harnessSnapshotRoot, "testdata",
    "harness testdata snapshot directory");
  const harnessLifecycleDir = containedFile(harnessTestdataDir, "lifecycle",
    "harness lifecycle snapshot directory");
  mkdirSync(candidateDir, { mode: 0o700 });
  mkdirSync(fixtureSnapshotDir, { mode: 0o700 });
  mkdirSync(harnessSnapshotRoot, { mode: 0o700 });
  mkdirSync(harnessScriptsDir, { mode: 0o700 });
  mkdirSync(harnessTestdataDir, { mode: 0o700 });
  mkdirSync(harnessLifecycleDir, { mode: 0o700 });
  const candidateSnapshot = writeBoundSnapshot(candidateOriginal,
    containedFile(candidateDir, "loom", "candidate execution snapshot"),
    0o500, "candidate execution snapshot");
  invariant(candidateSnapshot.path !== candidateOriginal.path,
    "candidate snapshot must not alias the caller-provided path");

  for (const value of loadedSources.values()) {
    value.snapshotBinding = writeBoundSnapshot(value.originalBinding,
      containedFile(fixtureSnapshotDir, value.source.fixture,
        `${value.source.name} fixture execution snapshot`),
      0o400, `${value.source.name} fixture execution snapshot`);
  }

  const harnessSnapshots = {
    script: writeBoundSnapshot(harnessBindings.script,
      containedFile(harnessScriptsDir, basename(scriptPath), "audit script snapshot"),
      0o400, "audit script execution snapshot"),
    selfTest: writeBoundSnapshot(harnessBindings.selfTest,
      containedFile(harnessScriptsDir, basename(selfTestPath), "self-test snapshot"),
      0o400, "mutation self-test execution snapshot"),
    manifest: writeBoundSnapshot(harnessBindings.manifest,
      containedFile(harnessLifecycleDir, basename(manifestPath), "manifest snapshot"),
      0o400, "lifecycle manifest execution snapshot"),
  };
  chmodSync(candidateDir, 0o500);
  chmodSync(fixtureSnapshotDir, 0o500);
  chmodSync(harnessScriptsDir, 0o500);
  chmodSync(harnessLifecycleDir, 0o500);
  chmodSync(harnessTestdataDir, 0o500);
  chmodSync(harnessSnapshotRoot, 0o500);

  mkdirSync(dirname(paths.output), { recursive: true });
  mkdirSync(paths.output, { mode: 0o700 });
  const outputRoot = realpathSync(paths.output);
  const scratchDirectory = directoryBinding(scratchRoot, "scratch root");
  const outputDirectory = directoryBinding(outputRoot, "output root");

  const mutationSelfTest = runMutationSelfTest(harnessBindings, harnessSnapshots);
  const candidateInvocations = [];
  const runCandidate = (args, label) => {
    assertFileBinding(candidateSnapshot, `${label} pre-execution candidate snapshot`);
    const result = runProcess(candidateSnapshot.path, args);
    assertFileBinding(candidateSnapshot, `${label} post-execution candidate snapshot`);
    candidateInvocations.push({
      ordinal: candidateInvocations.length,
      label,
      executable: candidateSnapshot.path,
      executableBytes: candidateSnapshot.size,
      executableSha256: candidateSnapshot.sha256,
    });
    return result;
  };
  const identity = candidateIdentity(runCandidate, paths.requireImmutable);

  const sourceByName = new Map(manifest.sources.map((source) => [source.name, source]));
  const targetByName = new Map(manifest.targets.map((target) => [target.name, target]));
  const parsedSources = new Map();
  for (const [name, value] of loadedSources) {
    parsedSources.set(name, {
      lifecycle: value.lifecycle,
      path: value.snapshotBinding.path,
      snapshotBinding: value.snapshotBinding,
      runtimePolicyEvidence: value.runtimePolicyEvidence,
    });
  }

  const cellReports = [];
  const assertPriorArtifacts = (context) => {
    const expectedNames = new Set(cellReports
      .filter((report) => report.artifact.existsAfter)
      .map((report) => basename(report.artifact.path)));
    const observedNames = readdirSync(outputRoot);
    invariant(observedNames.length === expectedNames.size &&
      observedNames.every((name) => expectedNames.has(name)),
    `${context}: output root contains cross-cell or unexpected residue`);
    for (const report of cellReports) {
      const observation = fileObservation(report.artifact.path);
      const pathStat = observation.exists ? lstatSync(report.artifact.path) : null;
      invariant(observation.exists === report.artifact.existsAfter &&
        (!observation.exists || (pathStat.isFile() && !pathStat.isSymbolicLink() &&
          observation.bytes === report.artifact.bytesAfter &&
          observation.sha256 === report.artifact.sha256 &&
          jsonEqual(observation.binding, report.artifact.afterBinding))),
      `${context}: a prior cell artifact changed`);
    }
  };

  for (const cell of manifest.cells) {
    const target = targetByName.get(cell.target);
    const sourceArtifact = parsedSources.get(cell.source);
    invariant(sourceByName.has(cell.source) && target && sourceArtifact,
      `${cell.name}: closed manifest lookup failed`);
    assertDirectoryBinding(scratchDirectory, `${cell.name} scratch root`);
    assertDirectoryBinding(outputDirectory, `${cell.name} output root`);
    assertFileBinding(sourceArtifact.snapshotBinding,
      `${cell.name} source fixture snapshot`);
    assertPriorArtifacts(`${cell.name} preflight`);

    const artifactPath = containedFile(outputRoot,
      `${cell.name}${TARGET_EXTENSIONS[cell.target]}`, `${cell.name} artifact`);
    const stagePath = containedFile(outputRoot,
      `${cell.name}${TARGET_EXTENSIONS[cell.target]}.agent-convert-stage`,
      `${cell.name} stage artifact`);
    const stdoutPath = containedFile(scratchRoot, `${cell.name}.stdout`,
      `${cell.name} stdout evidence`);
    const stderrPath = containedFile(scratchRoot, `${cell.name}.stderr`,
      `${cell.name} stderr evidence`);
    const commandPath = containedFile(scratchRoot, `${cell.name}.command.json`,
      `${cell.name} command evidence`);
    invariant(!existsSync(artifactPath) && !existsSync(stagePath),
      `${cell.name}: artifact or stage existed before sentinel preparation`);
    const sentinel = cell.expected.kind === "refusal"
      ? Buffer.from(`agent-convert lifecycle sentinel v1\n${cell.name}\n`, "utf8")
      : null;
    if (sentinel) writeFileSync(artifactPath, sentinel, { flag: "wx", mode: 0o600 });
    const before = fileObservation(artifactPath);
    const beforeStat = before.exists ? lstatSync(artifactPath) : null;
    const stageBefore = existsSync(stagePath);
    const args = [
      "convert",
      cell.source,
      cell.target,
      sourceArtifact.path,
      artifactPath,
      ...targetLaunchArgs(target, cell),
      "--json",
    ];
    writeFileSync(commandPath, canonicalJson({
      originalCandidate: candidateOriginal.path,
      executableSnapshot: candidateSnapshot.path,
      executableBytes: candidateSnapshot.size,
      executableSha256: candidateSnapshot.sha256,
      args,
      cwd: utilsRoot,
    }), { flag: "wx", mode: 0o600 });
    const processResult = runCandidate(args, `matrix cell ${cell.name}`);
    writeFileSync(stdoutPath, processResult.stdout, { flag: "wx", mode: 0o600 });
    writeFileSync(stderrPath, processResult.stderr, { flag: "wx", mode: 0o600 });
    assertFileBinding(sourceArtifact.snapshotBinding,
      `${cell.name} source fixture snapshot after execution`);
    assertDirectoryBinding(outputDirectory, `${cell.name} output root after execution`);
    const after = fileObservation(artifactPath);
    const afterStat = after.exists ? lstatSync(artifactPath) : null;
    const stageAfter = existsSync(stagePath);
    const observation = {
      ...processResult,
      artifactExistedBefore: before.exists,
      artifactExistsAfter: after.exists,
      beforeSha256: before.sha256,
      afterSha256: after.sha256,
      beforeBytes: before.content,
      afterBytes: after.content,
      artifactRegularFileBefore: beforeStat?.isFile() === true &&
        beforeStat?.isSymbolicLink() === false,
      artifactRegularFileAfter: afterStat?.isFile() === true &&
        afterStat?.isSymbolicLink() === false,
      beforeBinding: before.binding,
      afterBinding: after.binding,
      stageBefore,
      stageAfter,
    };
    let evaluation;
    const parserErrors = [];
    let idProvenanceAudit = null;
    let envelopeValidation = null;
    let candidateReceipt = null;
    if (cell.expected.kind === "refusal") {
      evaluation = evaluateRefusalCell(cell, observation,
        sourceArtifact.runtimePolicyEvidence);
    } else {
      let targetLifecycle = null;
      if (processResult.status === 0 && processResult.signal === null) {
        try {
          const receipt = parseJsonText(processResult.stdout.toString("utf8"),
            `${cell.name} candidate self-report`);
          candidateReceipt = validateCandidateReceipt(receipt, target, cell, identity,
            sourceArtifact.path, artifactPath);
        } catch (error) {
          parserErrors.push(error instanceof Error ? error.message : String(error));
        }
      }
      if (processResult.status === 0 && after.exists) {
        try {
          const parsed = parseTargetArtifactDetailed(cell.target, after.content,
            `${cell.name} target`, { target, cell });
          targetLifecycle = parsed.lifecycle;
          envelopeValidation = parsed.envelope;
          idProvenanceAudit = auditTargetIdProvenance(sourceArtifact.lifecycle,
            targetLifecycle);
        } catch (error) {
          parserErrors.push(error instanceof Error ? error.message : String(error));
        }
      }
      evaluation = evaluateSuccessCell(cell, observation,
        sourceArtifact.lifecycle, targetLifecycle, candidateReceipt);
    }
    cellReports.push({
      name: cell.name,
      source: cell.source,
      target: cell.target,
      expected: cell.expected,
      status: evaluation.pass ? "pass" : "fail",
      process: {
        exitStatus: processResult.status,
        signal: processResult.signal,
        stdoutBytes: processResult.stdout.length,
        stdoutSha256: sha256(processResult.stdout),
        stderrBytes: processResult.stderr.length,
        stderrSha256: sha256(processResult.stderr),
      },
      artifact: {
        path: artifactPath,
        existedBefore: before.exists,
        beforeSha256: before.sha256,
        beforeBinding: before.binding,
        existsAfter: after.exists,
        bytesAfter: after.bytes,
        sha256: after.sha256,
        afterBinding: after.binding,
        stagePath,
        stageBefore,
        stageAfter,
      },
      diagnostics: {
        command: commandPath,
        stdout: stdoutPath,
        stderr: stderrPath,
      },
      ...(parserErrors.length === 0 ? {} : { parserErrors }),
      ...(cell.expected.kind === "success"
        ? {
            successChecks: evaluation.checks,
            targetEnvelope: envelopeValidation,
            fieldReconciliation: evaluation.reconciliation,
            targetIdProvenance: idProvenanceAudit,
            candidateSelfReport: candidateReceipt,
          }
        : {
            refusalChecks: evaluation.checks,
            exactRefusalReason: evaluation.exactReason,
            ...(cell.expected.policy === CURSOR_RUNTIME_ARCHIVE_ONLY_POLICY
              ? { runtimePolicyEvidence: sourceArtifact.runtimePolicyEvidence }
              : {}),
            refusalClaim: "Observed the exact manifest-specific golden policy refusal. The pre-execution and post-exit observations matched for the prior artifact's recorded path and opened-file device/inode values, mode, size, digest, and bytes. This finite observation is neither continuous monitoring nor an atomicity proof, does not establish build/source-revision provenance, and does not guarantee inode identity between observations or against inode reuse. It also does not prove semantic necessity against an arbitrary substitute executable.",
          }),
    });
    assertPriorArtifacts(`${cell.name} postflight`);
  }

  assertDirectoryBinding(scratchDirectory, "final scratch root");
  assertDirectoryBinding(outputDirectory, "final output root");
  assertFileBinding(candidateSnapshot, "final candidate execution snapshot");

  const candidateOriginalStability = stabilityReport(candidateOriginal,
    "original candidate at end");
  const candidateSnapshotStability = stabilityReport(candidateSnapshot,
    "candidate snapshot at end");
  const harnessStability = {
    script: stabilityReport(harnessBindings.script, "audit script at end"),
    selfTest: stabilityReport(harnessBindings.selfTest, "mutation self-test at end"),
    manifest: stabilityReport(harnessBindings.manifest, "lifecycle manifest at end"),
  };
  const harnessSnapshotStability = {
    script: stabilityReport(harnessSnapshots.script, "audit script snapshot at end"),
    selfTest: stabilityReport(harnessSnapshots.selfTest,
      "mutation self-test snapshot at end"),
    manifest: stabilityReport(harnessSnapshots.manifest,
      "lifecycle manifest snapshot at end"),
  };
  const fixtureReports = manifest.sources.map((source) => {
    const value = loadedSources.get(source.name);
    return {
      source: source.name,
      fixture: source.fixture,
      original: stabilityReport(value.originalBinding,
        `${source.name} original fixture at end`),
      executionSnapshot: stabilityReport(value.snapshotBinding,
        `${source.name} fixture snapshot at end`),
      exactSnapshotOfStartBytes: value.originalBinding.size === value.snapshotBinding.size &&
        value.originalBinding.sha256 === value.snapshotBinding.sha256,
      lifecycleSha256: sha256(compactCanonical(value.lifecycle)),
      coverage: value.coverage,
      ...(value.runtimePolicyEvidence === null
        ? {} : { runtimePolicyEvidence: value.runtimePolicyEvidence }),
      limitations: source.limitations,
    };
  });
  const bindingsPass = candidateOriginalStability.unchanged &&
    candidateSnapshotStability.unchanged &&
    candidateOriginal.size === candidateSnapshot.size &&
    candidateOriginal.sha256 === candidateSnapshot.sha256 &&
    candidateInvocations.length === 41 &&
    candidateInvocations.every((item) => item.executable === candidateSnapshot.path &&
      item.executableBytes === candidateSnapshot.size &&
      item.executableSha256 === candidateSnapshot.sha256) &&
    Object.values(harnessStability).every((item) => item.unchanged) &&
    Object.values(harnessSnapshotStability).every((item) => item.unchanged) &&
    Object.keys(harnessBindings).every((key) =>
      harnessBindings[key].size === harnessSnapshots[key].size &&
      harnessBindings[key].sha256 === harnessSnapshots[key].sha256) &&
    fixtureReports.every((fixture) => fixture.original.unchanged &&
      fixture.executionSnapshot.unchanged && fixture.exactSnapshotOfStartBytes);

  const report = {
    schema: "agent-convert.lifecycle-matrix-report.v1",
    claimScope: "Finite checked-fixture observation of one byte-snapshotted executable only. This finite observation is neither continuous monitoring nor an atomicity proof, does not establish build/source-revision provenance, and does not guarantee inode identity between observations or against inode reuse. It is not a universal proof and does not prove that a target harness executed an artifact.",
    candidate: {
      originalPath: candidateOriginalStability,
      executionSnapshot: candidateSnapshotStability,
      exactSnapshotOfStartBytes: candidateOriginal.size === candidateSnapshot.size &&
        candidateOriginal.sha256 === candidateSnapshot.sha256,
      invocations: {
        expected: 41,
        observed: candidateInvocations.length,
        version: candidateInvocations.filter((item) => item.label === "candidate version").length,
        matrixCells: candidateInvocations.filter((item) =>
          item.label.startsWith("matrix cell ")).length,
        allUsedSnapshot: candidateInvocations.every((item) =>
          item.executable === candidateSnapshot.path),
        records: candidateInvocations,
      },
      identity: {
        evidenceKind: "candidate-self-report",
        establishesSourceProvenance: false,
        value: identity,
      },
      immutableRevisionPolicy: {
        required: paths.requireImmutable,
        selfReportedFortyHexShapeSatisfied: /^[0-9a-f]{40}$/.test(identity.coreRevision),
        establishesRevisionProvenance: false,
      },
    },
    runtime: {
      nodeVersion: process.version,
      platform: process.platform,
      arch: process.arch,
    },
    reportBinding: {
      absoluteEvidencePaths: true,
      determinism: "Canonical serialization is deterministic for one execution binding; absolute candidate and evidence paths intentionally prevent a byte-identity claim across roots.",
      pathAndSourceStabilityPass: bindingsPass,
      crossCellControls: "Unique contained paths, exclusive sentinel creation, immutable input snapshots, prior-artifact byte checks, and output-root residue checks are operational isolation controls; they are not a claim of semantic necessity against an arbitrary malicious executable.",
    },
    harness: {
      startLoadedAndEndChecked: harnessStability,
      executionSnapshots: harnessSnapshotStability,
      snapshotsMatchStartLoadedBytes: Object.keys(harnessBindings).every((key) =>
        harnessBindings[key].size === harnessSnapshots[key].size &&
        harnessBindings[key].sha256 === harnessSnapshots[key].sha256),
      mutationSelfTest,
    },
    paths: {
      scratch: scratchRoot,
      output: outputRoot,
      report: paths.report,
    },
    census: {
      declaredSources: SOURCE_NAMES,
      declaredTargets: TARGET_NAMES,
      expectedCells: 40,
      observedCells: cellReports.length,
      uniqueCellNames: new Set(cellReports.map((cell) => cell.name)).size,
    },
    fixtures: fixtureReports,
    artifacts: cellReports.map((cell) => ({
      cell: cell.name,
      bytes: cell.artifact.bytesAfter,
      sha256: cell.artifact.sha256,
    })),
    cells: cellReports,
    overallPass: cellReports.length === 40 &&
      cellReports.every((cell) => cell.status === "pass") &&
      mutationSelfTest.pass && bindingsPass,
  };
  mkdirSync(dirname(paths.report), { recursive: true });
  writeFileSync(paths.report, canonicalJson(report));
  return report;
}

async function main() {
  const paths = parseCli(process.argv.slice(2));
  const report = await runMatrix(paths);
  const passed = report.cells.filter((cell) => cell.status === "pass").length;
  const failed = report.cells.length - passed;
  console.log(`${paths.report}: ${passed} passed, ${failed} failed, overallPass=${report.overallPass}`);
  if (!report.overallPass) process.exitCode = 1;
}

if (resolve(process.argv[1] ?? "") === resolve(scriptPath)) {
  main().catch((error) => {
    console.error(`audit error: ${error instanceof Error ? error.message : String(error)}`);
    process.exitCode = 2;
  });
}
