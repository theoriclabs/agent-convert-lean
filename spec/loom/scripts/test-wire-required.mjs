#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const [loomArg, scratchArg] = process.argv.slice(2);
if (!loomArg || !scratchArg) {
  console.error("usage: test-wire-required.mjs <loom-bin> <scratch-dir>");
  process.exit(2);
}

const loom = resolve(loomArg);
const scratch = resolve(scratchArg);
rmSync(scratch, { recursive: true, force: true });
mkdirSync(scratch, { recursive: true });

const origin = {
  format: "codex",
  sourceRef: "wire-required-matrix",
  rawId: "session-wire-required",
};

const fixture = {
  schema: "loom.transcript.v0",
  origin,
  env: { cwd: "/tmp/wire-required", model: "fixture-model" },
  threads: [
    { index: "0", kind: { kind: "main" }, label: "main" },
    {
      index: "1",
      kind: {
        kind: "sidechain",
        anchor: { kind: "resolved", entry: "1", block: "2" },
      },
      label: "child",
    },
    { index: "2", kind: { kind: "detached", note: "unknown anchor" } },
  ],
  entries: [
    {
      index: "0",
      thread: "0",
      time: { kind: "recorded", ms: "1700000000000" },
      payload: {
        type: "userMsg",
        blocks: [
          { type: "text", text: "root" },
          { type: "media", mimeType: "image/png", data: "asset-u" },
          { type: "unmodeled", label: "future-user", raw: { exact: true } },
        ],
      },
      origin,
    },
    {
      index: "1",
      parent: "0",
      thread: "0",
      time: { kind: "interpolated", ms: "1700000000001", basis: "fixture" },
      payload: {
        type: "assistantMsg",
        blocks: [
          { type: "text", text: "dispatch" },
          { type: "thinking", thinking: "reason", thinkingSignature: "opaque" },
          {
            type: "toolCall",
            name: "Task",
            arguments: { prompt: "work" },
            id: "call-child",
          },
          { type: "media", mimeType: "image/png", data: "asset-a" },
          { type: "unmodeled", label: "future-assistant", raw: [1, 2, 3] },
        ],
      },
      origin,
    },
    {
      index: "2",
      parent: "1",
      thread: "0",
      time: { kind: "sequenced", ord: "2" },
      payload: {
        type: "envMsg",
        blocks: [
          {
            type: "toolResult",
            call: { kind: "resolved", entry: "1", block: "2" },
            content: [{ type: "text", text: "native result" }],
            error: { kind: "native", isError: false },
          },
          {
            type: "toolResult",
            call: { kind: "resolved", entry: "1", block: "2" },
            content: [{ type: "media", mimeType: "text/plain", data: "asset-r" }],
            error: { kind: "inferred", isError: true, heuristic: "fixture" },
          },
          {
            type: "toolResult",
            call: { kind: "resolved", entry: "1", block: "2" },
            content: [{ type: "unmodeled", label: "future-result", raw: null }],
            error: { kind: "unrecorded" },
          },
          { type: "unmodeled", label: "future-env", raw: "opaque" },
        ],
      },
      origin,
    },
    {
      index: "3",
      parent: "2",
      thread: "0",
      time: { kind: "absent" },
      payload: { type: "otherMsg", role: "system", blocks: [{ type: "text", text: "policy" }] },
      origin,
    },
    {
      index: "4",
      parent: "3",
      thread: "0",
      time: { kind: "absent" },
      payload: {
        type: "compaction",
        summary: "known summary",
        coverage: { kind: "knownPrefix", firstKept: "2" },
        tokensBefore: "100",
      },
      origin,
    },
    {
      index: "5",
      parent: "4",
      thread: "0",
      time: { kind: "absent" },
      payload: {
        type: "compaction",
        summary: "unknown summary",
        coverage: { kind: "unknownPrefix" },
      },
      origin,
    },
    {
      index: "6",
      parent: "5",
      thread: "0",
      time: { kind: "absent" },
      payload: { type: "event", event: { type: "custom", label: "custom-event", raw: { x: 1 } } },
      origin,
    },
    {
      index: "7",
      parent: "6",
      thread: "0",
      time: { kind: "absent" },
      payload: { type: "event", event: { type: "modelChange", prev: "a", next: "b" } },
      origin,
    },
    {
      index: "8",
      parent: "7",
      thread: "0",
      time: { kind: "absent" },
      payload: { type: "event", event: { type: "thinkingLevelChange", prev: "low", next: "high" } },
      origin,
    },
    {
      index: "9",
      parent: "8",
      thread: "0",
      time: { kind: "absent" },
      payload: { type: "event", event: { type: "permissionMode", mode: "acceptEdits" } },
      origin,
    },
    {
      index: "10",
      parent: "9",
      thread: "0",
      time: { kind: "absent" },
      payload: { type: "event", event: { type: "branchSummary", summary: "active branch" } },
      origin,
    },
    {
      index: "11",
      thread: "1",
      time: { kind: "absent" },
      payload: { type: "userMsg", blocks: [{ type: "text", text: "child" }] },
      origin,
    },
    {
      index: "12",
      thread: "2",
      time: { kind: "absent" },
      payload: { type: "userMsg", blocks: [{ type: "text", text: "detached" }] },
      origin,
    },
  ],
  importNotes: [{ kind: "idSynthesized", loc: "fixture", detail: "required matrix" }],
  activeLeaf: "10",
};

const specs = [];
const required = (label, parent, field, context, wrong = 0, wrongSuffix = field) => {
  specs.push({ label, parent, field, context, wrong, wrongSuffix });
};
const arbitraryJson = (label, parent, field, context) => {
  specs.push({ label, parent, field, context, arbitrary: true });
};

required("top-schema", [], "schema", "loom wire");
required("top-origin", [], "origin", "loom wire");
required("top-env", [], "env", "loom wire");
required("top-threads", [], "threads", "loom wire", {});
required("top-entries", [], "entries", "loom wire", {});
required("top-import-notes", [], "importNotes", "loom wire", {});
required("origin-format", ["origin"], "format", "loom wire.origin");
required("origin-source-ref", ["origin"], "sourceRef", "loom wire.origin");
required("thread-index", ["threads", 0], "index", "threads[0]", {});
required("thread-kind-object", ["threads", 0], "kind", "threads[0]");
required("thread-kind", ["threads", 0, "kind"], "kind", "threads[0].kind");
required("sidechain-anchor", ["threads", 1, "kind"], "anchor", "threads[1].kind");
required("sidechain-call-kind", ["threads", 1, "kind", "anchor"], "kind", "threads[1].kind.anchor");
required("sidechain-call-entry", ["threads", 1, "kind", "anchor"], "entry", "threads[1].kind.anchor", {});
required("sidechain-call-block", ["threads", 1, "kind", "anchor"], "block", "threads[1].kind.anchor", {});
required("detached-note", ["threads", 2, "kind"], "note", "threads[2].kind");
required("entry-index", ["entries", 0], "index", "entries[0]", {});
required("entry-thread", ["entries", 0], "thread", "entries[0]", {});
required("entry-time", ["entries", 0], "time", "entries[0]");
required("entry-payload", ["entries", 0], "payload", "entries[0]");
required("entry-origin", ["entries", 0], "origin", "entries[0]");
required("entry-origin-format", ["entries", 0, "origin"], "format", "entries[0].origin");
required("entry-origin-source-ref", ["entries", 0, "origin"], "sourceRef", "entries[0].origin");
required("recorded-time-kind", ["entries", 0, "time"], "kind", "entries[0].time");
required("recorded-time-ms", ["entries", 0, "time"], "ms", "entries[0].time", {});
required("interpolated-time-ms", ["entries", 1, "time"], "ms", "entries[1].time", {});
required("interpolated-time-basis", ["entries", 1, "time"], "basis", "entries[1].time");
required("sequenced-time-ord", ["entries", 2, "time"], "ord", "entries[2].time", {});
required("user-payload-type", ["entries", 0, "payload"], "type", "entries[0].payload");
required("user-blocks", ["entries", 0, "payload"], "blocks", "entries[0].payload", {});
required("user-text-type", ["entries", 0, "payload", "blocks", 0], "type", "entries[0].payload.blocks[0]");
required("user-text", ["entries", 0, "payload", "blocks", 0], "text", "entries[0].payload.blocks[0]");
required("user-media-mime", ["entries", 0, "payload", "blocks", 1], "mimeType", "entries[0].payload.blocks[1]");
required("user-media-data", ["entries", 0, "payload", "blocks", 1], "data", "entries[0].payload.blocks[1]");
required("user-unmodeled-label", ["entries", 0, "payload", "blocks", 2], "label", "entries[0].payload.blocks[2]");
arbitraryJson("user-unmodeled-raw", ["entries", 0, "payload", "blocks", 2], "raw", "entries[0].payload.blocks[2]");
required("assistant-blocks", ["entries", 1, "payload"], "blocks", "entries[1].payload", {});
required("assistant-text", ["entries", 1, "payload", "blocks", 0], "text", "entries[1].payload.blocks[0]");
required("assistant-thinking", ["entries", 1, "payload", "blocks", 1], "thinking", "entries[1].payload.blocks[1]");
required("assistant-call-name", ["entries", 1, "payload", "blocks", 2], "name", "entries[1].payload.blocks[2]");
arbitraryJson("assistant-call-arguments", ["entries", 1, "payload", "blocks", 2], "arguments", "entries[1].payload.blocks[2]");
required("assistant-media-mime", ["entries", 1, "payload", "blocks", 3], "mimeType", "entries[1].payload.blocks[3]");
required("assistant-media-data", ["entries", 1, "payload", "blocks", 3], "data", "entries[1].payload.blocks[3]");
required("assistant-unmodeled-label", ["entries", 1, "payload", "blocks", 4], "label", "entries[1].payload.blocks[4]");
arbitraryJson("assistant-unmodeled-raw", ["entries", 1, "payload", "blocks", 4], "raw", "entries[1].payload.blocks[4]");
required("env-blocks", ["entries", 2, "payload"], "blocks", "entries[2].payload", {});
required("result-call", ["entries", 2, "payload", "blocks", 0], "call", "entries[2].payload.blocks[0]");
required("result-content", ["entries", 2, "payload", "blocks", 0], "content", "entries[2].payload.blocks[0]", {});
required("result-error", ["entries", 2, "payload", "blocks", 0], "error", "entries[2].payload.blocks[0]");
required("result-call-kind", ["entries", 2, "payload", "blocks", 0, "call"], "kind", "entries[2].payload.blocks[0].call");
required("result-call-entry", ["entries", 2, "payload", "blocks", 0, "call"], "entry", "entries[2].payload.blocks[0].call", {});
required("result-call-block", ["entries", 2, "payload", "blocks", 0, "call"], "block", "entries[2].payload.blocks[0].call", {});
required("native-error-kind", ["entries", 2, "payload", "blocks", 0, "error"], "kind", "entries[2].payload.blocks[0].error");
required("native-error-value", ["entries", 2, "payload", "blocks", 0, "error"], "isError", "entries[2].payload.blocks[0].error", {});
required("inferred-error-value", ["entries", 2, "payload", "blocks", 1, "error"], "isError", "entries[2].payload.blocks[1].error", {});
required("inferred-error-heuristic", ["entries", 2, "payload", "blocks", 1, "error"], "heuristic", "entries[2].payload.blocks[1].error");
required("env-unmodeled-label", ["entries", 2, "payload", "blocks", 3], "label", "entries[2].payload.blocks[3]");
arbitraryJson("env-unmodeled-raw", ["entries", 2, "payload", "blocks", 3], "raw", "entries[2].payload.blocks[3]");
required("other-role", ["entries", 3, "payload"], "role", "entries[3].payload");
required("other-blocks", ["entries", 3, "payload"], "blocks", "entries[3].payload", {});
required("compaction-summary", ["entries", 4, "payload"], "summary", "entries[4].payload");
required("compaction-coverage", ["entries", 4, "payload"], "coverage", "entries[4].payload");
required("coverage-kind", ["entries", 4, "payload", "coverage"], "kind", "entries[4].payload.coverage");
required("coverage-first-kept", ["entries", 4, "payload", "coverage"], "firstKept", "entries[4].payload.coverage", {});
required("event-object", ["entries", 6, "payload"], "event", "entries[6].payload");
required("event-type", ["entries", 6, "payload", "event"], "type", "entries[6].payload.event");
required("custom-event-label", ["entries", 6, "payload", "event"], "label", "entries[6].payload.event");
arbitraryJson("custom-event-raw", ["entries", 6, "payload", "event"], "raw", "entries[6].payload.event");
required("permission-mode", ["entries", 9, "payload", "event"], "mode", "entries[9].payload.event");
required("branch-summary", ["entries", 10, "payload", "event"], "summary", "entries[10].payload.event");
required("note-kind", ["importNotes", 0], "kind", "importNotes[0]");
required("note-detail", ["importNotes", 0], "detail", "importNotes[0]");

// JSON cloning intentionally breaks the shared `origin` object references in
// the JavaScript fixture, matching the independent objects present on disk.
const clone = () => JSON.parse(JSON.stringify(fixture));
const parentAt = (root, path) => path.reduce((value, key) => value[key], root);
const safeLabel = (value) => value.replace(/[^a-z0-9-]/gi, "-");

function runFixture(label, value, expectedStatus, expectedDiagnostic = null) {
  const stem = safeLabel(label);
  const input = resolve(scratch, `${stem}.json`);
  const output = resolve(scratch, `${stem}.out.json`);
  writeFileSync(input, `${JSON.stringify(value)}\n`);
  rmSync(output, { force: true });
  const result = spawnSync(loom, ["convert", "loom", "loom", input, output], {
    encoding: "utf8",
  });
  if (result.status !== expectedStatus) {
    throw new Error(`${label}: exit ${result.status}, expected ${expectedStatus}\n${result.stderr}`);
  }
  if (expectedDiagnostic && !result.stderr.includes(expectedDiagnostic)) {
    throw new Error(`${label}: missing diagnostic ${JSON.stringify(expectedDiagnostic)}\n${result.stderr}`);
  }
  if (expectedStatus !== 0) {
    try {
      readFileSync(output);
      throw new Error(`${label}: wrote output despite import refusal`);
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
    }
  }
}

runFixture("valid-required-matrix", fixture, 0);

let mutationCount = 0;
for (const spec of specs) {
  const missing = clone();
  delete parentAt(missing, spec.parent)[spec.field];
  runFixture(
    `${spec.label}-missing`,
    missing,
    2,
    `${spec.context}: missing required field '${spec.field}'`,
  );
  mutationCount += 1;

  if (!spec.arbitrary) {
    const mistyped = clone();
    parentAt(mistyped, spec.parent)[spec.field] = spec.wrong;
    runFixture(
      `${spec.label}-mistyped`,
      mistyped,
      2,
      `${spec.context}.${spec.wrongSuffix}`,
    );
    mutationCount += 1;
  }
}

console.log(`wire required-field mutations: ${mutationCount} rejected`);
