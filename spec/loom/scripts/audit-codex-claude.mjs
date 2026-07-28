#!/usr/bin/env node

import { readFileSync } from "node:fs";
import { isDeepStrictEqual } from "node:util";

const CALL_HEADER =
  "[Historical tool call from source transcript; not executed by Claude]";
const RESULT_HEADER =
  "[Historical tool result from source transcript; not executed by Claude]";
const STRUCTURED_RESULT_HEADER =
  "[Historical structured tool result from source transcript]";

const CONTROL_TAGS = [
  "permissions instructions",
  "skills_instructions",
  "apps_instructions",
  "plugins_instructions",
  "recommended_plugins",
  "collaboration_mode",
  "environment_context",
];

function fail(message) {
  console.error(`audit failed: ${message}`);
  process.exit(1);
}

function readJsonl(path) {
  return readFileSync(path, "utf8")
    .split("\n")
    .filter((line) => line.trim())
    .map((line, index) => {
      try {
        return JSON.parse(line);
      } catch (error) {
        fail(`${path}:${index + 1}: ${error.message}`);
      }
    });
}

function activeCompactionSegment(rows) {
  let compactedIndex = -1;
  for (let index = 0; index < rows.length; index++) {
    if (rows[index]?.type === "compacted") compactedIndex = index;
  }
  if (compactedIndex < 0) return rows;

  const compacted = rows[compactedIndex];
  const history = compacted?.payload?.replacement_history;
  if (!Array.isArray(history) || history.some((item) =>
    !item || typeof item !== "object" || Array.isArray(item) ||
    typeof item.type !== "string" || item.type.length === 0)) {
    throw new Error("latest compacted replacement_history is malformed");
  }
  const timestamp = typeof compacted.timestamp === "string"
    ? compacted.timestamp
    : "";
  const replacement = history.map((payload) => ({
    type: "response_item",
    timestamp,
    payload,
  }));
  const controls = rows.slice(0, compactedIndex)
    .filter((row) => row?.type === "turn_context");
  return [...controls, ...replacement, ...rows.slice(compactedIndex + 1)];
}

// The Lean importer applies latest-compaction independently between resume
// headers. Preserve those boundaries here as part of the independent oracle.
function activeCodexRows(rows) {
  if (!rows.length) return rows;
  const rewritten = [rows[0]];
  let segment = [];
  for (const row of rows.slice(1)) {
    if (row?.type === "session_meta") {
      rewritten.push(...activeCompactionSegment(segment), row);
      segment = [];
    } else {
      segment.push(row);
    }
  }
  rewritten.push(...activeCompactionSegment(segment));
  return rewritten;
}

function exactString(object, key) {
  return typeof object?.[key] === "string" ? object[key] : null;
}

function parseFunctionArguments(value) {
  if (typeof value === "string") {
    try {
      return { ok: true, value: JSON.parse(value) };
    } catch {
      return { ok: false, value: null };
    }
  }
  if (value && typeof value === "object") {
    return { ok: true, value };
  }
  return { ok: false, value: null };
}

function sourceCall(payload) {
  if (payload.type === "function_call") {
    const id = exactString(payload, "call_id");
    const name = exactString(payload, "name");
    const parsed = parseFunctionArguments(payload.arguments);
    if (!id || !name || !parsed.ok) {
      throw new Error("malformed recognized Codex function_call");
    }
    return { id, name, arguments: parsed.value };
  }
  if (payload.type === "custom_tool_call") {
    const id = exactString(payload, "call_id");
    const name = exactString(payload, "name");
    const input = exactString(payload, "input");
    if (!id || !name || input === null) {
      throw new Error("malformed recognized Codex custom_tool_call");
    }
    const key = name === "apply_patch" ? "patch" : "input";
    return { id, name, arguments: { [key]: input } };
  }
  if (payload.type === "tool_search_call" || payload.type === "web_search_call") {
    const id = exactString(payload, "call_id") ?? exactString(payload, "id");
    const args = Object.hasOwn(payload, "action")
      ? payload.action
      : Object.hasOwn(payload, "arguments") ? payload.arguments : payload;
    return { id, name: payload.type, arguments: args };
  }
  return null;
}

function imageRef(item) {
  const url = typeof item.image_url === "string" ? item.image_url : "";
  if (!url) throw new Error("malformed recognized Codex input_image");
  return url;
}

function sourceOutputBlocks(value) {
  if (typeof value === "string") return [{ kind: "text", text: value }];
  if (!Array.isArray(value)) {
    return [{ kind: "unmodeled", label: "tool_output", raw: value }];
  }
  return value.map((item) => {
    const type = item && typeof item === "object" ? item.type : undefined;
    if (["input_text", "output_text", "text"].includes(type) &&
        typeof item.text === "string") {
      return { kind: "text", text: item.text };
    }
    if (type === "input_image") {
      return { kind: "media", mimeType: "image", locator: imageRef(item) };
    }
    return { kind: "unmodeled", label: type || "tool_output_item", raw: item };
  });
}

function outputIndicatesError(blocks) {
  const text = blocks.filter((block) => block.kind === "text")
    .map((block) => block.text).join("");
  const lower = text.toLowerCase();
  return /Process exited with code [1-9]/.test(text) ||
    lower.includes("timed out after") || lower.includes("command timed out") ||
    (lower.includes("timeout") && ["exceeded", "expired", "limit"]
      .some((part) => lower.includes(part)));
}

function sourceResult(payload) {
  if (payload.type === "function_call_output" ||
      payload.type === "custom_tool_call_output") {
    const id = exactString(payload, "call_id");
    if (!id || !Object.hasOwn(payload, "output")) {
      throw new Error(`malformed recognized Codex ${payload.type}`);
    }
    const content = sourceOutputBlocks(payload.output);
    return {
      id,
      content,
      error: {
        kind: "inferred",
        isError: outputIndicatesError(content),
        heuristic: "codexOutputIndicatesError (codexAdapter.ts:75)",
      },
    };
  }
  if (payload.type === "tool_search_output") {
    const id = exactString(payload, "call_id");
    if (!id) throw new Error("malformed recognized Codex tool_search_output");
    return {
      id,
      content: [{ kind: "unmodeled", label: "tool_search_output", raw: payload }],
      error: typeof payload.status === "string"
        ? { kind: "native", isError: payload.status !== "completed" }
        : { kind: "unrecorded" },
    };
  }
  return null;
}

function sourceLifecycle(rows) {
  const events = [];
  const calls = [];
  const results = [];
  const pending = new Map();
  const previous = new Map();
  let segment = 0;
  let sawPrimaryHeader = false;

  const keyFor = (id) => `${segment}\u0000${id}`;
  for (const row of rows) {
    if (row?.type === "session_meta") {
      if (sawPrimaryHeader) segment++;
      sawPrimaryHeader = true;
      continue;
    }
    if (row?.type !== "response_item") continue;
    const payload = row.payload || {};
    const call = sourceCall(payload);
    if (call) {
      const sourceCallIndex = calls.length;
      const event = { kind: "call", ...call, sourceCallIndex };
      calls.push(call);
      events.push(event);
      if (call.id !== null) {
        const key = keyFor(call.id);
        const queue = pending.get(key) || [];
        queue.push(sourceCallIndex);
        pending.set(key, queue);
      }
    }

    const result = sourceResult(payload);
    if (result) {
      const key = keyFor(result.id);
      const queue = pending.get(key) || [];
      let link;
      if (queue.length) {
        const sourceCallIndex = queue.shift();
        pending.set(key, queue);
        previous.set(key, sourceCallIndex);
        link = {
          kind: "resolved",
          sourceCallIndex,
          rawId: calls[sourceCallIndex].id,
        };
      } else if (previous.has(key)) {
        const sourceCallIndex = previous.get(key);
        link = {
          kind: "resolved",
          sourceCallIndex,
          rawId: calls[sourceCallIndex].id,
        };
      } else {
        link = {
          kind: "unresolved",
          rawId: result.id,
          note: "tool output has no earlier call with this call_id",
        };
      }
      results.push(result);
      events.push({ kind: "result", ...result, link });
    }
  }
  return { events, calls, results };
}

function parseCarrier(text, header, carrier) {
  if (!text.startsWith(`${header}\n`)) return null;
  let record;
  try {
    record = JSON.parse(text.slice(header.length + 1));
  } catch (error) {
    throw new Error(`malformed ${carrier} JSON: ${error.message}`);
  }
  if (!record || typeof record !== "object" || Array.isArray(record) ||
      record.carrier !== carrier) {
    throw new Error(`invalid carrier discriminator: ${record?.carrier}`);
  }
  return record;
}

function targetNativeResultBlocks(content) {
  const values = typeof content === "string"
    ? [{ type: "text", text: content }]
    : Array.isArray(content) ? content : [content];
  return values.map((item) => {
    if (item?.type === "text") {
      const carrier = parseCarrier(item.text || "", STRUCTURED_RESULT_HEADER,
        "agent-convert.tool-result-block.v1");
      return carrier
        ? { kind: "unmodeled", label: carrier.label, raw: carrier.raw }
        : { kind: "text", text: item.text || "" };
    }
    if (item?.type === "image") {
      return {
        kind: "media",
        mimeType: item.mimeType || "image",
        locator: item.data || "image",
      };
    }
    return { kind: "unmodeled", label: item?.type || "tool_result_item", raw: item };
  });
}

function targetLifecycle(rows) {
  const events = [];
  for (const row of rows) {
    const content = Array.isArray(row.message?.content) ? row.message.content : [];
    for (const block of content) {
      if (row.type === "assistant" && block?.type === "tool_use") {
        events.push({
          kind: "call",
          id: block.id ?? null,
          name: block.name,
          arguments: block.input,
          carried: false,
          occurrence: null,
        });
      } else if (row.type === "assistant" && block?.type === "text") {
        const carrier = parseCarrier(block.text || "", CALL_HEADER,
          "agent-convert.claude-tool-call.v1");
        if (carrier) {
          events.push({
            kind: "call",
            id: Object.hasOwn(carrier, "id") ? carrier.id : undefined,
            name: carrier.name,
            arguments: carrier.arguments,
            carried: true,
            occurrence: carrier.occurrence,
          });
        }
      } else if (row.type === "user" && block?.type === "tool_result") {
        events.push({
          kind: "result",
          id: block.tool_use_id ?? null,
          content: targetNativeResultBlocks(block.content),
          // `is_error` is a bare bool with no "unknown" state, so its ABSENCE is
          // load-bearing: it is the only honest rendering of a source that never
          // recorded whether the call errored. Record presence separately from
          // value or an omitted flag reads as an asserted success.
          error: { kind: "native", isError: block.is_error === true },
          errorRecorded: Object.hasOwn(block, "is_error"),
          carried: false,
          occurrence: null,
          call: null,
        });
      } else if (row.type === "user" && block?.type === "text") {
        const carrier = parseCarrier(block.text || "", RESULT_HEADER,
          "agent-convert.claude-tool-result.v1");
        if (carrier) {
          events.push({
            kind: "result",
            id: Object.hasOwn(carrier, "id") ? carrier.id : undefined,
            content: carrier.content,
            error: carrier.error,
            carried: true,
            occurrence: carrier.occurrence,
            call: carrier.call,
          });
        }
      }
    }
  }
  return events;
}

function lifecycleValue(event) {
  return event.kind === "call"
    ? { id: event.id, name: event.name, arguments: event.arguments }
    : { id: event.id, content: event.content, error: event.error };
}

// A native `tool_result` cannot carry error PROVENANCE, only the bool. Compare
// what Claude can hold: the recorded value, or `null` when the source recorded
// no value at all and the target must therefore omit the field.
function recordedErrorValue(error) {
  if (!error || error.kind === "unrecorded") return null;
  return error.isError === true;
}

function compareLifecycle(source, target) {
  const nativeCalls = target.filter((event) => event.kind === "call" && !event.carried);
  const nativeResults = target.filter((event) => event.kind === "result" && !event.carried);
  const carriedCalls = target.filter((event) => event.kind === "call" && event.carried);
  const carriedResults = target.filter((event) => event.kind === "result" && event.carried);
  // Native emission is NOT rejected here. Since af0b289e a Codex lifecycle that
  // Claude can express is supposed to arrive as `tool_use`/`tool_result`; the
  // carrier is the fallback for what Claude cannot hold (an unpaired call, or a
  // result containing blocks with no native Claude representation). This oracle
  // therefore checks the invariants that must hold under EITHER encoding, and
  // reports the split rather than dictating it.
  if (source.events.length !== target.length) {
    throw new Error(
      `ordered lifecycle length mismatch: source ${source.events.length}, target ${target.length}`,
    );
  }

  const targetCalls = [];
  const occurrenceSites = new Map();
  let provenanceNormalizedResults = 0;
  for (let index = 0; index < target.length; index++) {
    const expected = source.events[index];
    const actual = target[index];
    if (expected.kind !== actual.kind) {
      throw new Error(
        `ordered lifecycle kind mismatch at index ${index}: source ${expected.kind}, target ${actual.kind}`,
      );
    }
    if (actual.kind === "result" && !actual.carried) {
      if (!isDeepStrictEqual(
        { id: expected.id, content: expected.content },
        { id: actual.id, content: actual.content },
      )) {
        throw new Error(`result id/content mismatch at lifecycle index ${index}`);
      }
      const expectedValue = recordedErrorValue(expected.error);
      const actualValue = actual.errorRecorded ? actual.error.isError : null;
      if (expectedValue !== actualValue) {
        throw new Error(
          `native result error state mismatch at lifecycle index ${index}: ` +
          `source ${JSON.stringify(expectedValue)}, target ${JSON.stringify(actualValue)}`,
        );
      }
      if (expected.error?.kind !== "native") provenanceNormalizedResults++;
    } else if (!isDeepStrictEqual(lifecycleValue(expected), lifecycleValue(actual))) {
      const field = expected.kind === "call" ? "id/name/arguments" :
        "id/content/error provenance";
      throw new Error(`${expected.kind} ${field} mismatch at lifecycle index ${index}`);
    }
    if (actual.carried) {
      if (typeof actual.occurrence !== "string" || actual.occurrence.length === 0) {
        throw new Error(`${actual.kind} carrier at lifecycle index ${index} has no occurrence`);
      }
      if (occurrenceSites.has(actual.occurrence)) {
        throw new Error(
          `duplicate carrier occurrence '${actual.occurrence}' at lifecycle index ${index}`,
        );
      }
      occurrenceSites.set(actual.occurrence, index);
    } else if (actual.occurrence !== null) {
      throw new Error(
        `native ${actual.kind} at lifecycle index ${index} claims a carrier occurrence`,
      );
    }
    if (actual.kind === "call") targetCalls.push({ ...actual, lifecycleIndex: index });
  }

  let linkageMismatches = 0;
  for (let index = 0; index < target.length; index++) {
    const expected = source.events[index];
    const actual = target[index];
    if (expected.kind !== "result") continue;

    if (expected.link.kind === "resolved") {
      const call = targetCalls[expected.link.sourceCallIndex];
      if (call === undefined || call.lifecycleIndex >= index) {
        linkageMismatches++;
        continue;
      }
      // A result must travel with the same encoding as the call it belongs to:
      // Claude cannot pair a native tool_result with a call rendered as prose,
      // and a carried result under a native call would strand the linkage.
      if (call.carried !== actual.carried) {
        linkageMismatches++;
        continue;
      }
      if (actual.carried) {
        if (!isDeepStrictEqual(actual.call, {
          kind: "resolved",
          occurrence: call.occurrence,
          rawId: expected.link.rawId,
        })) linkageMismatches++;
      } else if (actual.id !== expected.link.rawId || call.id !== expected.link.rawId) {
        linkageMismatches++;
      }
    } else if (!actual.carried) {
      // Claude's tool_use_id is a pointer; an unresolved source link has nothing
      // to point at, so it is only expressible as a carrier.
      linkageMismatches++;
    } else if (!isDeepStrictEqual(actual.call, {
      kind: "unresolved",
      rawId: expected.link.rawId,
      note: expected.link.note,
    })) {
      linkageMismatches++;
    }
  }
  if (linkageMismatches) {
    throw new Error(
      `${linkageMismatches} result(s) lost independently derived occurrence linkage`,
    );
  }

  return {
    nativeCalls,
    nativeResults,
    carriedCalls,
    carriedResults,
    linkageMismatches,
    provenanceNormalizedResults,
  };
}

function normalizeText(text) {
  return text.normalize("NFKC").toLowerCase().replace(/\s+/gu, " ").trim();
}

function words(text) {
  return normalizeText(text).match(/[\p{L}\p{N}_-]+/gu) || [];
}

function runtimeTags(text) {
  const found = new Set();
  for (const tag of CONTROL_TAGS) {
    if (text.includes(`<${tag}>`) && text.includes(`</${tag}>`)) found.add(tag);
  }
  return found;
}

function isRuntimeControlText(text) {
  return CONTROL_TAGS.some((tag) =>
    text.startsWith(`<${tag}>`) && text.endsWith(`</${tag}>`));
}

function controlFragments(text) {
  const fragments = new Set();
  const withoutTags = text.replace(/<\/?[^>]+>/gu, " ");
  const normalized = normalizeText(withoutTags);
  if (normalized.length >= 20) fragments.add(normalized);

  for (const line of withoutTags.split(/\r?\n/gu)) {
    const value = normalizeText(line);
    if (value.length >= 20) fragments.add(value);
  }

  const tokens = words(withoutTags);
  for (let index = 0; index + 4 <= tokens.length; index++) {
    const fragment = tokens.slice(index, index + 4).join(" ");
    if (fragment.length >= 20) fragments.add(fragment);
  }
  return fragments;
}

function sourceControls(rows) {
  const exactTexts = new Set();
  const fragments = new Set();
  const tags = new Set();
  const add = (text) => {
    exactTexts.add(text);
    for (const fragment of controlFragments(text)) fragments.add(fragment);
    for (const tag of runtimeTags(text)) tags.add(tag);
  };

  for (const row of rows) {
    const payload = row.payload || {};
    if (row.type === "response_item" && payload.type === "message") {
      const blocks = Array.isArray(payload.content) ? payload.content : [];
      const blockTexts = blocks.filter((block) =>
        ["input_text", "output_text", "text"].includes(block?.type) &&
        typeof block.text === "string").map((block) => block.text);
      if (payload.role === "developer") {
        blockTexts.forEach(add);
        if (blockTexts.length > 1) add(blockTexts.join(""));
      } else if (payload.role === "user") {
        blockTexts.filter(isRuntimeControlText).forEach(add);
      }
    }
    if (row.type === "event_msg" && payload.type === "user_message" &&
        typeof payload.message === "string" &&
        isRuntimeControlText(payload.message)) {
      add(payload.message);
    }
  }
  return { exactTexts, fragments, tags };
}

function targetConversationTexts(rows) {
  const texts = [];
  for (const row of rows) {
    if (!["user", "assistant"].includes(row.type)) continue;
    const content = row.message?.content;
    if (typeof content === "string") texts.push(content);
    if (Array.isArray(content)) {
      for (const block of content) {
        if (block?.type !== "text" || typeof block.text !== "string") continue;
        const header = row.type === "assistant" ? CALL_HEADER : RESULT_HEADER;
        const carrier = row.type === "assistant"
          ? "agent-convert.claude-tool-call.v1"
          : "agent-convert.claude-tool-result.v1";
        if (parseCarrier(block.text, header, carrier)) continue;
        texts.push(block.text);
      }
    }
  }
  return texts;
}

function looseTagPattern(tag) {
  const escaped = tag.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&")
    .replace(/\s+/gu, "\\s+");
  return new RegExp(`<\\s*\\/?\\s*${escaped}\\s*>`, "iu");
}

function leaksControl(text, controls) {
  const normalized = normalizeText(text);
  if ([...controls.exactTexts].some((control) =>
    normalized.includes(normalizeText(control)))) return true;
  if ([...controls.fragments].some((fragment) => normalized.includes(fragment))) return true;

  const tokenText = words(text).join(" ");
  for (const tag of controls.tags) {
    if (looseTagPattern(tag).test(text) || tokenText.includes(tag)) return true;
  }
  return false;
}

const [sourcePath, targetPath] = process.argv.slice(2);
if (!sourcePath || !targetPath) {
  fail("usage: audit-codex-claude.mjs <codex.jsonl> <claude.jsonl>");
}

try {
  const sourceRows = activeCodexRows(readJsonl(sourcePath));
  const targetRows = readJsonl(targetPath);
  const source = sourceLifecycle(sourceRows);
  const target = targetLifecycle(targetRows);
  const comparison = compareLifecycle(source, target);

  const controls = sourceControls(sourceRows);
  const leakedControls = targetConversationTexts(targetRows)
    .filter((text) => leaksControl(text, controls));
  if (leakedControls.length) {
    throw new Error(
      `${leakedControls.length} exact, normalized, or partial control-plane block(s) became conversation text`,
    );
  }

  console.log(JSON.stringify({
    ok: true,
    sourceCalls: source.calls.length,
    targetNativeCalls: comparison.nativeCalls.length,
    targetCarriedCalls: comparison.carriedCalls.length,
    sourceResults: source.results.length,
    targetNativeResults: comparison.nativeResults.length,
    targetCarriedResults: comparison.carriedResults.length,
    targetResults: comparison.carriedResults.length + comparison.nativeResults.length,
    syntheticResults: comparison.carriedResults.length + comparison.nativeResults.length -
      source.results.length,
    linkageMismatches: comparison.linkageMismatches,
    provenanceNormalizedResults: comparison.provenanceNormalizedResults,
    archivedControlTexts: controls.exactTexts.size,
    controlSignatures: controls.fragments.size + controls.tags.size,
    leakedControlTexts: leakedControls.length,
  }, null, 2));
} catch (error) {
  fail(error instanceof Error ? error.message : String(error));
}
