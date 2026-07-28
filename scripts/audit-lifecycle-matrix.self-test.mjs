#!/usr/bin/env node

import { createHash } from "node:crypto";
import {
  chmodSync,
  mkdtempSync,
  readFileSync,
  renameSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import {
  auditTargetIdProvenance,
  canonicalJson,
  checkFixtureCoverage,
  cursorAgentRuntimeArchiveOnlyEvidence,
  evaluateRefusalCell,
  evaluateSuccessCell,
  finalizeLifecycle,
  fileBindingMatches,
  lifecycleCoverage,
  parseJsonText,
  parseSourceArtifact,
  parseTargetArtifact,
  reconcileLifecycle,
  readFileBinding,
  validateCandidateIdentity,
  validateManifest,
  writeBoundSnapshot,
} from "./audit-lifecycle-matrix.mjs";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const mainScript = join(scriptDir, "audit-lifecycle-matrix.mjs");
const selfTestScript = fileURLToPath(import.meta.url);
const manifestPath = resolve(scriptDir, "..", "testdata", "lifecycle", "manifest.v1.json");

let positiveChecks = 0;
let rejectedMutations = 0;
let resultEmitted = false;

function fileSha256(path) {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

function emitResult(pass, error = null) {
  if (resultEmitted) return;
  resultEmitted = true;
  const result = {
    schema: "agent-convert.lifecycle-matrix-self-test.v1",
    pass,
    positiveChecks,
    rejectedMutations,
    totalChecks: positiveChecks + rejectedMutations,
    harnessScriptSha256: fileSha256(mainScript),
    selfTestScriptSha256: fileSha256(selfTestScript),
    manifestSha256: fileSha256(manifestPath),
    ...(error === null ? {} : { error }),
  };
  process.stdout.write(`${JSON.stringify(result)}\n`);
}

process.on("uncaughtException", (error) => {
  emitResult(false, error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
});

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function positive(name, condition) {
  assert(condition, `${name}: positive check failed`);
  positiveChecks++;
}

function mutation(name, condition) {
  assert(condition, `${name}: mutation was not rejected`);
  rejectedMutations++;
}

function clone(value) {
  if (Buffer.isBuffer(value)) return Buffer.from(value);
  if (Array.isArray(value)) return value.map(clone);
  if (value !== null && typeof value === "object") {
    const output = Object.create(null);
    for (const [key, item] of Object.entries(value)) output[key] = clone(item);
    return output;
  }
  return value;
}

function rejects(callback) {
  try {
    callback();
    return false;
  } catch {
    return true;
  }
}

function valueId(value) {
  return { kind: "value", value };
}

function missingId() {
  return { kind: "missing" };
}

function call(site, id, name, args, disposition = "native") {
  return {
    kind: "call",
    site,
    rawId: id,
    rawName: name,
    arguments: args,
    disposition,
  };
}

function result(site, id, blocks, error, link, disposition = "native") {
  return {
    kind: "result",
    site,
    rawId: id,
    blocks,
    error,
    link,
    disposition,
  };
}

function resolved(site, id) {
  return { kind: "resolvedSite", site, rawId: id };
}

const manifest = parseJsonText(readFileSync(manifestPath, "utf8"), "self-test manifest");
const targetByName = new Map(manifest.targets.map((target) => [target.name, target]));
const cellByName = new Map(manifest.cells.map((cell) => [cell.name, cell]));

function targetBinding(format) {
  const name = `${format}__to__${format}`;
  return { target: targetByName.get(format), cell: cellByName.get(name) };
}

function parseTarget(format, artifact, context = `self-test ${format} target`) {
  return parseTargetArtifact(format, Buffer.from(artifact), context,
    targetBinding(format));
}

positive("strict JSON accepts unique object members",
  parseJsonText('{"outer":{"a":1,"b":2}}', "self-test JSON").outer.b === 2);
const dangerousJson = parseJsonText(
  '{"constructor":{"safe":true},"__proto__":{"polluted":false}}',
  "dangerous-key JSON");
const dangerousCanonical = canonicalJson(dangerousJson);
const dangerousRoundTrip = parseJsonText(dangerousCanonical, "dangerous-key canonical JSON");
positive("canonical JSON preserves dangerous own keys",
  Object.hasOwn(dangerousRoundTrip, "__proto__") &&
    Object.hasOwn(dangerousRoundTrip, "constructor") &&
    dangerousRoundTrip.__proto__.polluted === false &&
    dangerousRoundTrip.constructor.safe === true);
mutation("dangerous keys do not mutate Object.prototype",
  !Object.hasOwn(Object.prototype, "polluted") && ({}).polluted === undefined);
mutation("JSON duplicate object member is rejected", rejects(() =>
  parseTargetArtifact("loom", Buffer.from(
    '{"schema":"loom.transcript.v0","entries":[],"entries":[]}'),
  "duplicate Loom target", targetBinding("loom"))));
mutation("escaped duplicate object member is rejected", rejects(() =>
  parseJsonText('{"outer":{"name":1,"n\\u0061me":2}}', "escaped duplicate")));
mutation("non-finite parsed JSON number is rejected", rejects(() =>
  parseJsonText('{"value":1e999}', "non-finite JSON number")));
mutation("JSONL duplicate object member is rejected", rejects(() =>
  parseTargetArtifact("pi", Buffer.from(
    '{"type":"custom","customType":"ordinary","data":{},"data":{}}\n'),
  "duplicate Pi target", targetBinding("pi"))));

const duplicateCodexArguments = [
  {
    type: "response_item",
    payload: {
      type: "function_call",
      call_id: "call-1",
      name: "tool",
      arguments: '{"value":1,"value":2}',
    },
  },
].map(JSON.stringify).join("\n");
mutation("nested Codex argument duplicate is rejected", rejects(() =>
  parseSourceArtifact("codex", Buffer.from(`${duplicateCodexArguments}\n`))));

const duplicateHermesArguments = JSON.stringify({
  messages: [{
    role: "assistant",
    tool_calls: [{
      id: "call-1",
      type: "function",
      function: { name: "tool", arguments: '{"value":1,"value":2}' },
    }],
  }],
});
mutation("nested Hermes argument duplicate is rejected", rejects(() =>
  parseSourceArtifact("hermes", Buffer.from(duplicateHermesArguments))));

const duplicate = valueId("duplicate-id");
const baseline = finalizeLifecycle([
  call("call-0", duplicate, "first_tool", { nested: { count: 1 }, flags: [true, null] }),
  call("call-1", duplicate, "second_tool", ["array", 2, false]),
  result("result-0", duplicate, [
    { kind: "text", text: "second result" },
    { kind: "media", mimeType: "image/png", locator: "data:image/png;base64,eA==" },
    { kind: "unmodeled", label: "future", raw: { exact: [1, null] } },
  ], {
    provenance: "inferred",
    value: true,
    heuristic: "fixture heuristic",
  }, resolved("call-1", duplicate)),
  result("result-1", duplicate, [{ kind: "text", text: "first result" }], {
    provenance: "native",
    value: false,
  }, resolved("call-0", duplicate)),
  call("open", missingId(), "open_tool", null),
  result("orphan", valueId("ghost"), [], {
    provenance: "unrecorded",
    value: null,
  }, {
    kind: "unresolved",
    rawId: valueId("ghost"),
    note: "no earlier source call",
  }),
]);

positive("baseline field reconciliation",
  reconcileLifecycle(baseline, clone(baseline), "exact").pass);
const dangerousLifecycle = finalizeLifecycle([
  call("dangerous-call", valueId("dangerous-id"), "dangerous_tool",
    parseJsonText('{"__proto__":{"value":1},"constructor":{"value":2}}')),
]);
const changedDangerousLifecycle = clone(dangerousLifecycle);
changedDangerousLifecycle.events[0].arguments.__proto__.value = 9;
const dangerousReconciliation = reconcileLifecycle(dangerousLifecycle,
  changedDangerousLifecycle, "exact");
mutation("dangerous-key argument mutation is reported exactly",
  !dangerousReconciliation.pass && dangerousReconciliation.fields.some((item) =>
    item.path === "events[0].arguments" && !item.pass &&
      Object.hasOwn(item.expected, "__proto__") &&
      Object.hasOwn(item.actual, "__proto__")));
positive("dangerous-key reconciliation report serializes both values",
  (() => {
    const report = parseJsonText(canonicalJson(dangerousReconciliation));
    const field = report.fields.find((item) => item.path === "events[0].arguments");
    return Object.hasOwn(field.expected, "__proto__") &&
      Object.hasOwn(field.actual, "__proto__");
  })());
const baselineCoverage = lifecycleCoverage(baseline);
positive("baseline fixture coverage census",
  checkFixtureCoverage(baselineCoverage, baseline).pass);
const changedCoverage = clone(baselineCoverage);
changedCoverage.calls++;
mutation("fixture coverage mismatch",
  !checkFixtureCoverage(changedCoverage, baseline).pass);

function reconciliationMutation(name, mutate, expectedPath) {
  const actual = clone(baseline);
  mutate(actual);
  const reconciliation = reconcileLifecycle(baseline, actual, "exact");
  mutation(name, !reconciliation.pass && reconciliation.fields.some((item) =>
    !item.pass && item.path === expectedPath));
}

reconciliationMutation("event presence", (actual) => actual.events.pop(),
  "events[5].present");
reconciliationMutation("lifecycle event count", (actual) => actual.events.pop(),
  "lifecycle.eventCount");
reconciliationMutation("lifecycle call count", (actual) => {
  actual.events[0].kind = "result";
}, "lifecycle.callCount");
reconciliationMutation("lifecycle result count", (actual) => actual.events.pop(),
  "lifecycle.resultCount");
reconciliationMutation("event kind", (actual) => { actual.events[0].kind = "result"; },
  "events[0].kind");
reconciliationMutation("event order", (actual) => { actual.events[0].eventOrder = 7; },
  "events[0].eventOrder");
reconciliationMutation("call order", (actual) => { actual.events[1].callOccurrence = 9; },
  "events[1].callOccurrence");
reconciliationMutation("raw ID kind", (actual) => {
  actual.events[0].rawId = missingId();
}, "events[0].rawId.kind");
reconciliationMutation("raw ID value", (actual) => {
  actual.events[0].rawId.value = "redirected";
}, "events[0].rawId.value");
reconciliationMutation("duplicate ID occurrence", (actual) => {
  actual.events[1].idOccurrence = 0;
}, "events[1].idOccurrence");
reconciliationMutation("raw source name", (actual) => {
  actual.events[0].rawName = "renamed";
}, "events[0].rawName");
reconciliationMutation("complete argument JSON", (actual) => {
  actual.events[0].arguments.nested.count = 2;
}, "events[0].arguments");
reconciliationMutation("open call state", (actual) => {
  actual.events[4].state = "closed";
}, "events[4].state");
reconciliationMutation("result order", (actual) => {
  actual.events[2].resultOccurrence = 8;
}, "events[2].resultOccurrence");
reconciliationMutation("result block count", (actual) => {
  actual.events[2].blocks.pop();
}, "events[2].blocks.count");
reconciliationMutation("result block presence", (actual) => {
  actual.events[2].blocks.pop();
}, "events[2].blocks[2].present");
reconciliationMutation("result block kind", (actual) => {
  actual.events[2].blocks[0].kind = "media";
}, "events[2].blocks[0].kind");
reconciliationMutation("result text", (actual) => {
  actual.events[2].blocks[0].text = "changed";
}, "events[2].blocks[0].text");
reconciliationMutation("result MIME", (actual) => {
  actual.events[2].blocks[1].mimeType = "image/jpeg";
}, "events[2].blocks[1].mimeType");
reconciliationMutation("result media locator", (actual) => {
  actual.events[2].blocks[1].locator = "data:image/png;base64,eQ==";
}, "events[2].blocks[1].locator");
reconciliationMutation("result raw label", (actual) => {
  actual.events[2].blocks[2].label = "other";
}, "events[2].blocks[2].label");
reconciliationMutation("complete raw result value", (actual) => {
  actual.events[2].blocks[2].raw.exact[0] = 9;
}, "events[2].blocks[2].raw");
reconciliationMutation("error provenance", (actual) => {
  actual.events[2].error.provenance = "native";
}, "events[2].error.provenance");
reconciliationMutation("error value", (actual) => {
  actual.events[2].error.value = false;
}, "events[2].error.value");
reconciliationMutation("error heuristic", (actual) => {
  actual.events[2].error.heuristic = "other heuristic";
}, "events[2].error.heuristic");
reconciliationMutation("linkage kind", (actual) => {
  actual.events[2].linkage.kind = "unresolved";
}, "events[2].linkage.kind");
reconciliationMutation("linkage occurrence", (actual) => {
  actual.events[2].linkage.callOccurrence = 0;
}, "events[2].linkage.callOccurrence");
reconciliationMutation("linkage raw ID", (actual) => {
  actual.events[2].linkage.rawId.value = "other-id";
}, "events[2].linkage.rawId.value");
reconciliationMutation("linkage raw ID kind", (actual) => {
  actual.events[2].linkage.rawId = missingId();
}, "events[2].linkage.rawId.kind");
reconciliationMutation("unresolved linkage note", (actual) => {
  actual.events[5].linkage.note = "invented note";
}, "events[5].linkage.note");
reconciliationMutation("result ID occurrence", (actual) => {
  actual.events[3].idOccurrence = 0;
}, "events[3].idOccurrence");
reconciliationMutation("exact disposition", (actual) => {
  actual.events[0].disposition = "historicalUnverified";
}, "events[0].disposition");

const permittedDowngrade = clone(baseline);
permittedDowngrade.events[0].disposition = "historicalUnverified";
positive("manifest-permitted native-to-historical downgrade",
  reconcileLifecycle(baseline, permittedDowngrade,
    "allow-native-to-historical").pass);

const historicalSource = clone(baseline);
historicalSource.events[0].disposition = "historicalUnverified";
const upgradedTarget = clone(historicalSource);
upgradedTarget.events[0].disposition = "native";
const upgradeReconciliation = reconcileLifecycle(historicalSource, upgradedTarget,
  "allow-native-to-historical");
mutation("historical-to-native upgrade",
  !upgradeReconciliation.pass && upgradeReconciliation.fields.some((item) =>
    item.path === "invariants.noHistoricalToNativeUpgrade" && !item.pass));

const fabricated = clone(baseline);
const extraResult = clone(fabricated.events[5]);
extraResult.eventOrder = fabricated.events.length;
extraResult.resultOccurrence = 3;
fabricated.events.push(extraResult);
const fabricatedReconciliation = reconcileLifecycle(baseline, fabricated, "exact");
mutation("fabricated result",
  !fabricatedReconciliation.pass && fabricatedReconciliation.fields.some((item) =>
    item.path === "invariants.noFabricatedResult" && !item.pass));

const developmentIdentity = {
  coreRevision: "working-tree",
  engine: "lean",
  engineVersion: "0.2.0-preview.0",
  protocolVersion: "loom.cli.v1",
  sourcePath: ".",
  sourceRepository: "https://github.com/theoriclabs/agent-convert-lean",
  targetTriple: "arm64-apple-darwin",
  wireSchemas: ["loom.transcript.v0"],
};
positive("complete development core identity",
  validateCandidateIdentity(clone(developmentIdentity), false) !== null);
const immutableIdentity = clone(developmentIdentity);
immutableIdentity.coreRevision = "a".repeat(40);
positive("immutable release core identity",
  validateCandidateIdentity(immutableIdentity, true) !== null);
mutation("working-tree release identity is rejected", rejects(() =>
  validateCandidateIdentity(clone(developmentIdentity), true)));

function identityMutation(name, mutate) {
  const changed = clone(developmentIdentity);
  mutate(changed);
  mutation(name, rejects(() => validateCandidateIdentity(changed, false)));
}

identityMutation("missing identity source repository", (value) => {
  delete value.sourceRepository;
});
identityMutation("wrong identity source path", (value) => {
  value.sourcePath = "src";
});
identityMutation("empty identity target triple", (value) => {
  value.targetTriple = "";
});
identityMutation("missing identity wire schema", (value) => {
  value.wireSchemas = ["future.schema.v1"];
});
identityMutation("duplicate identity wire schema", (value) => {
  value.wireSchemas.push("loom.transcript.v0");
});

positive("closed manifest baseline", validateManifest(clone(manifest)) !== null);

function manifestMutation(name, mutate) {
  const changed = clone(manifest);
  mutate(changed);
  let rejected = false;
  try {
    validateManifest(changed);
  } catch {
    rejected = true;
  }
  mutation(name, rejected);
}

manifestMutation("missing matrix cell", (value) => value.cells.pop());
manifestMutation("unexpected extra matrix cell", (value) =>
  value.cells.push(clone(value.cells[0])));
manifestMutation("duplicate matrix name", (value) => {
  value.cells[1].name = value.cells[0].name;
});
manifestMutation("duplicate matrix pair", (value) => {
  value.cells[39].source = value.cells[0].source;
  value.cells[39].target = value.cells[0].target;
  value.cells[39].name = "duplicate-pair-name";
});
manifestMutation("unexpected matrix pair", (value) => {
  value.cells[0].source = "future-source";
  value.cells[0].name = "future-source__to__loom";
});
manifestMutation("incorrect cell name", (value) => {
  value.cells[0].name = "loom-to-loom";
});
manifestMutation("missing declared source", (value) => value.sources.pop());
manifestMutation("duplicate declared source", (value) => {
  value.sources[1].name = value.sources[0].name;
});
manifestMutation("unexpected declared target", (value) => {
  value.targets[0].name = "future-target";
});
manifestMutation("missing source limitations", (value) => {
  value.sources[0].limitations = [];
});
manifestMutation("incomplete target launch options", (value) => {
  delete value.targets[1].launch.provider;
});
manifestMutation("target extension is not caller-configurable", (value) => {
  value.targets[0].extension = ".jsonl";
});
manifestMutation("closed target launch value changed", (value) => {
  value.targets[1].launch.provider = "other-provider";
});
manifestMutation("ignored target metadata is rejected", (value) => {
  value.targets[1].ignored = true;
});
manifestMutation("ignored cell metadata is rejected", (value) => {
  value.cells[0].ignored = true;
});
manifestMutation("missing target session identity", (value) => {
  value.cells[1].targetSessionId = null;
});
manifestMutation("stale target identity on metadata-free target", (value) => {
  value.cells[0].targetSessionId = "10000000-0000-4000-8000-000000000001";
});
manifestMutation("duplicate target session identity", (value) => {
  value.cells[2].targetSessionId = value.cells[1].targetSessionId;
});
manifestMutation("refusal status not three", (value) => {
  value.cells[3].expected.status = 1;
});
manifestMutation("refusal policy is prerequisite", (value) => {
  value.cells[3].expected.policy = "missingTargetPrerequisites";
});
manifestMutation("Cursor runtime refusal is not open to another cell", (value) => {
  const cell = value.cells.find((item) =>
    item.name === "cursor-agent__to__cursor-agent");
  value.cells[0].expected = clone(cell.expected);
});
manifestMutation("Cursor runtime refusal reason is closed", (value) => {
  const cell = value.cells.find((item) =>
    item.name === "cursor-agent__to__cursor-agent");
  cell.expected.reason = "arbitraryPrerequisite";
});
manifestMutation("Cursor runtime refusal rejects obligation-shaped extras", (value) => {
  const cell = value.cells.find((item) =>
    item.name === "cursor-agent__to__cursor-agent");
  cell.expected.obligationRepr = "[Loom.Ops.Obligation.dropEvents]";
});
// These two locate their cell by CONTENT rather than by index. Both used to
// hardcode one (`cells[4]`, `cells[9]`), and the delimiter mutation silently
// stopped mutating anything once the manifest's cell order shifted: `cells[9]`
// became `pi__to__cursor-agent`, whose obligationRepr has no bracketed field
// list, so `.replace` was a no-op and the "mutation" was byte-identical to the
// original. A mutation test that mutates nothing cannot fail for the reason it
// claims to test. Selecting on the shape each mutation needs keeps that from
// recurring, and makes the absence of such a cell an explicit error.
function cellMatching(value, predicate, description) {
  const cell = value.cells.find((item) =>
    typeof item?.expected?.obligationRepr === "string" &&
    predicate(item.expected.obligationRepr));
  if (!cell) {
    throw new Error(`self-test manifest has no cell with ${description}`);
  }
  return cell;
}
manifestMutation("refusal obligation spacing is noncanonical", (value) => {
  const cell = cellMatching(value, (repr) => repr.includes(", "),
    "a comma-separated obligation list");
  cell.expected.obligationRepr = cell.expected.obligationRepr.replace(", ", ",  ");
});
manifestMutation("refusal obligation delimiters are malformed", (value) => {
  const cell = cellMatching(value, (repr) =>
    repr.startsWith("[Loom.Ops.Obligation.") && repr.endsWith("]"),
    "a bracketed Loom.Ops.Obligation list");
  cell.expected.obligationRepr = cell.expected.obligationRepr.replace(/]$/, "");
});
manifestMutation("unapproved disposition policy", (value) => {
  value.cells[0].expected.disposition = "upgrade";
});

const refusalCell = {
  name: "fixture__to__codex",
  source: "fixture",
  target: "codex",
  expected: {
    kind: "refusal",
    status: 3,
    policy: "destructiveLoss",
    obligationRepr: "[Loom.Ops.Obligation.dropMedia]",
  },
};
const sentinelSha = "a".repeat(64);
const sentinelBytes = Buffer.from("sentinel bytes\n");
const sentinelBinding = {
  path: "/tmp/refusal-sentinel",
  realPath: "/tmp/refusal-sentinel",
  pathDevice: "1",
  pathInode: "101",
  pathMode: 0o600,
  pathType: "regular-file",
  device: "1",
  inode: "101",
  mode: 0o600,
  bytes: sentinelBytes.length,
  sha256: sentinelSha,
};
const refusalObservation = {
  status: 3,
  signal: null,
  stdout: Buffer.alloc(0),
  stderr: Buffer.from(
    "export error: target 'codex' has destructive export obligations: [Loom.Ops.Obligation.dropMedia] — refusing silent loss; use the loom wire target to preserve the full transcript\n"),
  artifactExistedBefore: true,
  artifactExistsAfter: true,
  beforeSha256: sentinelSha,
  afterSha256: sentinelSha,
  beforeBytes: sentinelBytes,
  afterBytes: sentinelBytes,
  artifactRegularFileBefore: true,
  artifactRegularFileAfter: true,
  beforeBinding: clone(sentinelBinding),
  afterBinding: clone(sentinelBinding),
  stageBefore: false,
  stageAfter: false,
};
positive("refusal baseline", evaluateRefusalCell(refusalCell,
  clone(refusalObservation)).pass);
const byteViewRefusal = clone(refusalObservation);
byteViewRefusal.stdout = new Uint8Array(byteViewRefusal.stdout);
byteViewRefusal.stderr = new Uint8Array(byteViewRefusal.stderr);
positive("refusal accepts Uint8Array process bytes",
  evaluateRefusalCell(refusalCell, byteViewRefusal).pass);

const cursorRuntimeSource = Buffer.from(
  '{"role":"assistant","message":{"content":[{"type":"text","text":"starting calls"},{"type":"tool_use","name":"Shell","input":{"command":"printf one"}}]}}\n' +
  '{"type":"turn_ended","status":"error","error":"session interrupted"}\n');
const cursorRuntimeEvidence = cursorAgentRuntimeArchiveOnlyEvidence(
  cursorRuntimeSource, "Cursor runtime refusal self-test");
positive("Cursor runtime archive-only source evidence", cursorRuntimeEvidence.pass &&
  cursorRuntimeEvidence.nativeEnvelope.records === 1 &&
  cursorRuntimeEvidence.archiveOnlyRecords.length === 1);
mutation("Cursor runtime evidence requires a turn_ended control", rejects(() =>
  cursorAgentRuntimeArchiveOnlyEvidence(
    cursorRuntimeSource.subarray(0, cursorRuntimeSource.indexOf(0x0a) + 1),
    "missing Cursor control")));
mutation("Cursor runtime evidence rejects another control kind", rejects(() =>
  cursorAgentRuntimeArchiveOnlyEvidence(Buffer.from(
    cursorRuntimeSource.toString("utf8").replace('"turn_ended"', '"future_control"')),
  "wrong Cursor control")));

const cursorRuntimeRefusalCell = {
  name: "cursor-agent__to__cursor-agent",
  source: "cursor-agent",
  target: "cursor-agent",
  expected: {
    kind: "refusal",
    status: 3,
    policy: "cursorRuntimeArchiveOnly",
    reason: "turnEndedControl",
  },
};
const cursorRuntimeRefusalObservation = {
  ...clone(refusalObservation),
  stderr: Buffer.from(
    "export error: target 'cursor-agent' validity preflight failed: Cursor Agent runtime target requires native user/assistant messages containing only text and exact imported tool_use blocks\n"),
};
positive("Cursor runtime policy refusal baseline", evaluateRefusalCell(
  cursorRuntimeRefusalCell, cursorRuntimeRefusalObservation,
  cursorRuntimeEvidence).pass);
mutation("Cursor runtime refusal cannot use generic prerequisite text",
  !evaluateRefusalCell(cursorRuntimeRefusalCell, {
    ...clone(cursorRuntimeRefusalObservation),
    stderr: Buffer.from("export error: target 'cursor-agent' validity preflight failed: prerequisite missing\n"),
  }, cursorRuntimeEvidence).pass);
mutation("Cursor runtime refusal requires independent source evidence",
  !evaluateRefusalCell(cursorRuntimeRefusalCell,
    clone(cursorRuntimeRefusalObservation), null).pass);
mutation("Cursor runtime evaluator closes the cell without manifest validation",
  !evaluateRefusalCell({
    ...cursorRuntimeRefusalCell,
    name: "fixture__to__cursor-agent",
    source: "fixture",
  }, clone(cursorRuntimeRefusalObservation), cursorRuntimeEvidence).pass);
mutation("Cursor runtime evaluator closes the evidence schema",
  !evaluateRefusalCell(cursorRuntimeRefusalCell,
    clone(cursorRuntimeRefusalObservation), {
      ...clone(cursorRuntimeEvidence),
      schema: "future-evidence.v2",
    }).pass);

const multilineRefusalCell = {
  ...refusalCell,
  target: "cursor-agent",
  expected: {
    ...refusalCell.expected,
    obligationRepr: "[Loom.Ops.Obligation.dropMedia, Loom.Ops.Obligation.dropToolResults, Loom.Ops.Obligation.dropSourceIdentity, Loom.Ops.Obligation.dropEnvironment [\"cwd\", \"sessionId\"], Loom.Ops.Obligation.dropRecordedTime]",
  },
};
const multilineRefusalObservation = clone(refusalObservation);
multilineRefusalObservation.stderr = Buffer.from(
  "export error: target 'cursor-agent' has destructive export obligations: [Loom.Ops.Obligation.dropMedia,\n Loom.Ops.Obligation.dropToolResults,\n Loom.Ops.Obligation.dropSourceIdentity,\n Loom.Ops.Obligation.dropEnvironment [\"cwd\", \"sessionId\"],\n Loom.Ops.Obligation.dropRecordedTime] — refusing silent loss; use the loom wire target to preserve the full transcript\n");
positive("multiline refusal exact golden", evaluateRefusalCell(
  multilineRefusalCell, multilineRefusalObservation).pass);
const flattenedRefusalObservation = clone(multilineRefusalObservation);
flattenedRefusalObservation.stderr = Buffer.from(
  flattenedRefusalObservation.stderr.toString("utf8").replace(",\n ", ", "));
const flattenedRefusalEvaluation = evaluateRefusalCell(
  multilineRefusalCell, flattenedRefusalObservation);
mutation("multiline refusal cannot be flattened", !flattenedRefusalEvaluation.pass &&
  flattenedRefusalEvaluation.checks.some((item) =>
    item.path === "refusal.exactGoldenStderr" && !item.pass));

function refusalMutation(name, mutate, expectedPath) {
  const observation = clone(refusalObservation);
  mutate(observation);
  const evaluation = evaluateRefusalCell(refusalCell, observation);
  mutation(name, !evaluation.pass && evaluation.checks.some((item) =>
    item.path === expectedPath && !item.pass));
}

refusalMutation("refusal wrong status", (value) => { value.status = 1; },
  "refusal.exitStatus");
refusalMutation("refusal signal", (value) => { value.signal = "SIGTERM"; },
  "refusal.signal");
refusalMutation("refusal wrong obligation", (value) => {
  value.stderr = Buffer.from(
    "export error: target 'codex' has destructive export obligations: [Loom.Ops.Obligation.dropThinking] — refusing silent loss; use the loom wire target to preserve the full transcript\n");
}, "refusal.obligationRepr");
refusalMutation("refusal whitespace is not normalized", (value) => {
  value.stderr = Buffer.from(
    "export error: target 'codex' has destructive export obligations:  [Loom.Ops.Obligation.dropMedia] — refusing silent loss; use the loom wire target to preserve the full transcript\n");
}, "refusal.exactGoldenStderr");
refusalMutation("invocation error cannot discharge", (value) => {
  value.stderr = Buffer.from("invocation error: missing option\n");
}, "refusal.policy");
refusalMutation("import error cannot discharge", (value) => {
  value.stderr = Buffer.from("import error: malformed fixture\n");
}, "refusal.policy");
refusalMutation("prerequisite error cannot discharge", (value) => {
  value.stderr = Buffer.from("export error: target validity preflight failed: prerequisite missing\n");
}, "refusal.policy");
refusalMutation("stale artifact report", (value) => {
  value.stdout = Buffer.from('{"output":"stale.json"}\n');
}, "refusal.noArtifactReport");
refusalMutation("no prior sentinel", (value) => {
  value.artifactExistedBefore = false;
}, "refusal.priorArtifactExists");
refusalMutation("sentinel removed", (value) => {
  value.artifactExistsAfter = false;
  value.afterSha256 = null;
}, "refusal.artifactStillExists");
refusalMutation("sentinel bytes changed", (value) => {
  value.afterSha256 = "b".repeat(64);
  value.afterBytes = Buffer.from("changed bytes\n");
}, "refusal.sentinelBytesPreserved");
refusalMutation("sentinel exact bytes changed despite forged digest", (value) => {
  value.afterBytes = Buffer.from("forged contents\n");
}, "refusal.sentinelExactBytesPreserved");
refusalMutation("sentinel same-byte replacement is detected", (value) => {
  value.afterBinding.pathInode = "202";
  value.afterBinding.inode = "202";
}, "refusal.sentinelPostExitBindingPreserved");
refusalMutation("sentinel mode change is detected", (value) => {
  value.afterBinding.pathMode = 0o644;
  value.afterBinding.mode = 0o644;
}, "refusal.sentinelPostExitBindingPreserved");
refusalMutation("sentinel binding omission is detected", (value) => {
  value.afterBinding = null;
}, "refusal.sentinelPostExitBindingPreserved");
refusalMutation("sentinel replaced by non-regular artifact", (value) => {
  value.artifactRegularFileAfter = false;
}, "refusal.artifactRemainsRegularFile");
refusalMutation("preexisting stage residue", (value) => {
  value.stageBefore = true;
}, "refusal.noStageBefore");
refusalMutation("post-refusal stage residue", (value) => {
  value.stageAfter = true;
}, "refusal.noStageAfter");

const successCell = {
  expected: { kind: "success", disposition: "exact" },
};
const successObservation = {
  status: 0,
  signal: null,
  artifactExistedBefore: false,
  artifactExistsAfter: true,
  artifactRegularFileAfter: true,
  stageBefore: false,
  stageAfter: false,
};
const validCandidateReceipt = { pass: true };
positive("success baseline", evaluateSuccessCell(successCell,
  clone(successObservation), baseline, clone(baseline),
  clone(validCandidateReceipt)).pass);

function successMutation(name, mutateObservation, target, expectedPath,
    receipt = validCandidateReceipt) {
  const observation = clone(successObservation);
  mutateObservation(observation);
  const evaluation = evaluateSuccessCell(successCell, observation,
    baseline, target, clone(receipt));
  mutation(name, !evaluation.pass && evaluation.checks.some((item) =>
    item.path === expectedPath && !item.pass));
}

successMutation("success wrong status", (value) => { value.status = 3; },
  clone(baseline), "success.exitStatus");
successMutation("success signal", (value) => { value.signal = "SIGKILL"; },
  clone(baseline), "success.signal");
successMutation("success stale prior artifact", (value) => {
  value.artifactExistedBefore = true;
}, clone(baseline), "success.noPriorArtifact");
successMutation("success missing artifact", (value) => {
  value.artifactExistsAfter = false;
}, clone(baseline), "success.artifactExists");
successMutation("success non-regular artifact", (value) => {
  value.artifactRegularFileAfter = false;
}, clone(baseline), "success.artifactIsRegularFile");
successMutation("success stage before", (value) => {
  value.stageBefore = true;
}, clone(baseline), "success.noStageBefore");
successMutation("success stage after", (value) => {
  value.stageAfter = true;
}, clone(baseline), "success.noStageAfter");
successMutation("success target parse failure", () => {}, null,
  "success.targetParsed");
successMutation("success candidate receipt failure", () => {}, clone(baseline),
  "success.candidateSelfReportValidated", { pass: false });

const carrierSource = finalizeLifecycle([
  call("source-call", valueId("carrier-id"), "carrier_tool", { exact: true }),
]);

const provenanceWire = JSON.stringify({
  activeLeaf: "0",
  schema: "loom.transcript.v0",
  origin: { format: "self-test", sourceRef: "provenance-wire" },
  env: {},
  threads: [{ index: "0", kind: { kind: "main" } }],
  importNotes: [],
  entries: [{
    index: "0",
    thread: "0",
    time: { kind: "absent" },
    origin: {
      format: "cursor-ide",
      sourceRef: "bubble:bubble-1",
      extras: {
        rawBubble: {
          type: 2,
          bubbleId: "bubble-1",
          toolFormerData: {
            name: "carrier_tool",
            rawArgs: { exact: true },
            toolCallId: "carrier-id",
            tool: 1,
          },
        },
      },
    },
    payload: {
      type: "assistantMsg",
      blocks: [{
        type: "toolCall",
        id: "synthesized-id",
        name: "carrier_tool",
        arguments: { exact: true },
      }],
    },
  }],
});
const provenanceTarget = parseTarget("loom", provenanceWire, "provenance Loom target");
const provenanceReconciliation = reconcileLifecycle(carrierSource,
  provenanceTarget, "exact");
const provenanceAudit = auditTargetIdProvenance(carrierSource, provenanceTarget);
positive("reversible source-ID provenance is reported separately",
  provenanceAudit.provenanceOnlyCalls === 1 &&
    provenanceAudit.calls[0].reversibleEvidence.length === 1);
mutation("provenance does not weaken raw ID equality",
  !provenanceReconciliation.pass && !provenanceAudit.semanticIdEqualityPass);
const provenanceRemoved = clone(provenanceTarget);
provenanceRemoved.idProvenanceEvidence = [];
const lossAudit = auditTargetIdProvenance(carrierSource, provenanceRemoved);
mutation("absent reversible ID provenance is reported as loss",
  lossAudit.unprovenLossCalls === 1 && !lossAudit.semanticIdEqualityPass);

function carrierReconciles(format, artifact) {
  try {
    const parsed = parseTarget(format, artifact, `${format} carrier target`);
    return reconcileLifecycle(carrierSource, parsed,
      "allow-native-to-historical").pass;
  } catch {
    return false;
  }
}

const claudeCarrierObject = {
  arguments: { exact: true },
  canonical: null,
  carrier: "agent-convert.claude-tool-call.v1",
  id: "carrier-id",
  name: "carrier_tool",
  occurrence: "0:0",
  reason: "historical source lifecycle",
};
const claudeCarrierText =
  `[Historical tool call from source transcript; not executed by Claude]\n${JSON.stringify(claudeCarrierObject)}`;
const claudeBinding = targetBinding("claude");
const claudeLaunch = claudeBinding.target.launch;
const claudeCwd = `${claudeLaunch.cwdPrefix}/${claudeBinding.cell.name}`;
function claudeArtifact(marker, text = claudeCarrierText) {
  const uuid = "91000000-0000-4000-8000-000000000001";
  const rows = [{
    ...(marker ? { _agent_convert: marker } : {}),
    cwd: claudeCwd,
    isSidechain: false,
    parentUuid: null,
    sessionId: claudeBinding.cell.targetSessionId,
    timestamp: claudeLaunch.timestamp,
    type: "assistant",
    uuid,
    message: { role: "assistant", content: [{ type: "text", text }] },
  }, {
    _agent_convert: {
      protocol: "agent-convert.claude-carriers.v1",
      transcriptProvenance: {
        carrier: "agent-convert.claude-transcript-provenance.v1",
        kind: "sourceEnv",
        payload: {
          carrier: "agent-convert.claude-source-env.v1",
          cwd: null,
          harnessVersion: null,
          instructions: null,
          model: null,
          provider: null,
          sessionId: null,
        },
      },
    },
    type: "agent-convert-provenance",
  }, {
    leafUuid: uuid,
    sessionId: claudeBinding.cell.targetSessionId,
    type: "last-prompt",
  }];
  return `${rows.map(JSON.stringify).join("\n")}\n`;
}
const claudeMarker = {
  protocol: "agent-convert.claude-carriers.v1",
  contentBlocks: [0],
};
positive("exact Claude carrier", carrierReconciles("claude",
  claudeArtifact(claudeMarker)));
mutation("Claude unstamped carrier spoof remains text",
  !carrierReconciles("claude", claudeArtifact(null)));
const wrongClaudeMarker = clone(claudeMarker);
wrongClaudeMarker.protocol = "agent-convert.claude-carriers.v2";
mutation("Claude wrong item protocol stamp remains text",
  !carrierReconciles("claude", claudeArtifact(wrongClaudeMarker)));
const wrongClaudeIndex = clone(claudeMarker);
wrongClaudeIndex.contentBlocks = [1];
mutation("Claude wrong carrier block index remains text",
  !carrierReconciles("claude", claudeArtifact(wrongClaudeIndex)));
const malformedClaude = clone(claudeCarrierObject);
delete malformedClaude.reason;
mutation("Claude malformed marked carrier remains text",
  !carrierReconciles("claude", claudeArtifact(claudeMarker,
    `[Historical tool call from source transcript; not executed by Claude]\n${JSON.stringify(malformedClaude)}`)));
const unknownClaude = clone(claudeCarrierObject);
unknownClaude.carrier = "agent-convert.claude-tool-call.v99";
mutation("Claude unknown carrier version remains text",
  !carrierReconciles("claude", claudeArtifact(claudeMarker,
    `[Historical tool call from source transcript; not executed by Claude]\n${JSON.stringify(unknownClaude)}`)));
const duplicateClaudeCarrierText = claudeCarrierText.replace(
  '"carrier":"agent-convert.claude-tool-call.v1"',
  '"carrier":"agent-convert.claude-tool-call.v1","carrier":"spoof"');
mutation("Claude duplicate carrier member remains text",
  !carrierReconciles("claude", claudeArtifact(claudeMarker,
    duplicateClaudeCarrierText)));

const piCarrier = {
  type: "custom",
  customType: "loom.pi.carrier",
  data: {
    version: 1,
    kind: "assistantMessage",
    value: {
      blocks: [{
        kind: "toolCall",
        name: "carrier_tool",
        arguments: { exact: true },
        rawId: "carrier-id",
        canonical: null,
      }],
      representation: "historical-assistant-blocks",
      scope: "full",
      sourceEntry: 0,
      sourceBlockIndices: [0],
    },
  },
};
const piBinding = targetBinding("pi");
const piLaunch = piBinding.target.launch;
const piCwd = `${piLaunch.cwdPrefix}/${piBinding.cell.name}`;
const piSession = {
  type: "session",
  version: 3,
  id: piBinding.cell.targetSessionId,
  cwd: piCwd,
  timestamp: piLaunch.timestamp,
  loomPi: {
    cwd: "target-option",
    sessionId: "target-option",
    sourceEnvironment: {
      cwd: null,
      harnessVersion: null,
      instructions: null,
      model: null,
      provider: null,
      sessionId: null,
    },
    targetHarnessVersion: piLaunch.harnessVersion,
    targetOptions: {
      pi_assistant_history: {
        provenance: "origin-target-option",
        value: piLaunch.assistantHistory,
      },
      target_cwd: "origin-target-option",
      target_harness_version: "origin-target-option",
      target_model: "origin-target-option",
      target_provider: "origin-target-option",
      target_session_id: "origin-target-option",
      target_timestamp: "origin-target-option",
    },
    timestamp: "target-option",
    version: 1,
  },
};
function piArtifact(row, session = piSession) {
  const body = {
    ...row,
    id: row.id ?? "pi-self-test-entry",
    parentId: null,
    timestamp: row.timestamp ?? piLaunch.timestamp,
  };
  const tail = {
    id: "loom-target-model",
    loomPi: {
      targetModelChange: {
        author: "target",
        target_model: "origin-target-option",
        target_provider: "origin-target-option",
        target_timestamp: "origin-target-option",
      },
      version: 1,
    },
    modelId: piLaunch.model,
    parentId: body.id,
    provider: piLaunch.provider,
    timestamp: piLaunch.timestamp,
    type: "model_change",
  };
  return `${[session, body, tail].map(JSON.stringify).join("\n")}\n`;
}
positive("exact Pi carrier", carrierReconciles("pi",
  piArtifact(piCarrier)));
const malformedPi = clone(piCarrier);
delete malformedPi.data.value.blocks[0].canonical;
mutation("Pi malformed carrier remains ordinary",
  !carrierReconciles("pi", piArtifact(malformedPi)));
const unknownPi = clone(piCarrier);
unknownPi.data.version = 99;
mutation("Pi unknown carrier version remains ordinary",
  !carrierReconciles("pi", piArtifact(unknownPi)));
const spoofPi = {
  type: "message",
  message: {
    role: "assistant",
    content: [{ type: "text", text: JSON.stringify(piCarrier.data) }],
  },
};
mutation("Pi carrier-looking prose remains ordinary",
  !carrierReconciles("pi", piArtifact(spoofPi)));
mutation("Pi carrier requires session stamp",
  !carrierReconciles("pi", `${JSON.stringify(piCarrier)}\n`));
const wrongPiSession = clone(piSession);
wrongPiSession.loomPi.version = 2;
mutation("Pi carrier rejects wrong session stamp",
  !carrierReconciles("pi", piArtifact(piCarrier, wrongPiSession)));

const codexCarrierObject = {
  arguments: { exact: true },
  canonical: null,
  carrier: "agent-convert.codex-tool-call.v2",
  id: "carrier-id",
  name: "carrier_tool",
  occurrence: "0:0",
  reason: "source lifecycle is not losslessly executable in Codex",
};
const codexCarrierText =
  `[Historical tool call from source transcript; not executed by Codex]\n${JSON.stringify(codexCarrierObject)}`;
const codexBinding = targetBinding("codex");
const codexLaunch = codexBinding.target.launch;
const codexCwd = `${codexLaunch.cwdPrefix}/${codexBinding.cell.name}`;
const codexSession = {
  timestamp: codexLaunch.timestamp,
  type: "session_meta",
  payload: {
    _agent_convert: { kind: "session", protocol: "agent-convert.codex-carriers.v1" },
    _agent_convert_source_archive: {
      generated_target_control_records: [],
      kind: "historical_source_provenance",
      protocol: "agent-convert.codex-carriers.v1",
      source_control_records: [],
      source_env: {
        cwd: null,
        harnessVersion: null,
        instructions: null,
        model: null,
        provider: null,
        sessionId: null,
      },
      source_identity: {},
      source_session_payload: {},
    },
    cli_version: codexLaunch.harnessVersion,
    cwd: codexCwd,
    git: null,
    id: codexBinding.cell.targetSessionId,
    model_provider: codexLaunch.provider,
    originator: "agent-convert",
    session_id: codexBinding.cell.targetSessionId,
    source: "cli",
    timestamp: codexLaunch.timestamp,
  },
};
const codexTurnContext = {
  payload: {
    _agent_convert: {
      kind: "explicit_target_controls",
      protocol: "agent-convert.codex-carriers.v1",
    },
    approval_policy: codexLaunch.approvalPolicy,
    cwd: codexCwd,
    model: codexLaunch.model,
    provenance: "explicit target controls from origin.extras.target_codex_controls",
    sandbox_policy: {
      exclude_slash_tmp: codexLaunch.excludeSlashTmp,
      exclude_tmpdir_env_var: codexLaunch.excludeTmpdirEnvVar,
      network_access: codexLaunch.networkAccess,
      type: "workspace-write",
    },
    summary: codexLaunch.summary,
  },
  timestamp: codexLaunch.timestamp,
  type: "turn_context",
};
function codexCallRow(text = codexCarrierText, stamped = true) {
  return {
    timestamp: codexLaunch.timestamp,
    type: "response_item",
    payload: {
      ...(stamped ? {
        _agent_convert: {
          kind: "tool_call",
          protocol: "agent-convert.codex-carriers.v1",
        },
      } : {}),
      type: "message",
      role: "assistant",
      content: [{ type: "output_text", text }],
    },
  };
}
function codexPair(response) {
  const text = response.payload.content[0].text;
  const event = response.payload.role === "assistant" ? {
    payload: {
      memory_citation: null,
      message: text,
      phase: "final_answer",
      type: "agent_message",
    },
    timestamp: response.timestamp,
    type: "event_msg",
  } : {
    payload: {
      images: [],
      local_images: [],
      message: text,
      text_elements: [],
      type: "user_message",
    },
    timestamp: response.timestamp,
    type: "event_msg",
  };
  return [response, event];
}
function codexArtifact(callRow, session = codexSession) {
  return `${[session, codexTurnContext, ...codexPair(callRow)]
    .map(JSON.stringify).join("\n")}\n`;
}
positive("exact Codex carrier", carrierReconciles("codex",
  codexArtifact(codexCallRow())));
mutation("Codex unstamped carrier twin remains ordinary",
  !carrierReconciles("codex", codexArtifact(codexCallRow(codexCarrierText, false))));
const wrongCodexItemProtocol = codexCallRow();
wrongCodexItemProtocol.payload._agent_convert.protocol =
  "agent-convert.codex-carriers.v2";
mutation("Codex wrong item protocol stamp remains ordinary",
  !carrierReconciles("codex", codexArtifact(wrongCodexItemProtocol)));
const wrongCodexItemKind = codexCallRow();
wrongCodexItemKind.payload._agent_convert.kind = "tool_result";
mutation("Codex wrong item kind stamp remains ordinary",
  !carrierReconciles("codex", codexArtifact(wrongCodexItemKind)));
const malformedCodex = clone(codexCarrierObject);
malformedCodex.id = 7;
mutation("Codex malformed marked carrier remains ordinary",
  !carrierReconciles("codex", codexArtifact(codexCallRow(
    `[Historical tool call from source transcript; not executed by Codex]\n${JSON.stringify(malformedCodex)}`))));
const unknownCodex = clone(codexCarrierObject);
unknownCodex.carrier = "agent-convert.codex-tool-call.v77";
mutation("Codex unknown carrier version remains ordinary",
  !carrierReconciles("codex", codexArtifact(codexCallRow(
    `[Historical tool call from source transcript; not executed by Codex]\n${JSON.stringify(unknownCodex)}`))));
const duplicateCodexCarrierText = codexCarrierText.replace(
  '"carrier":"agent-convert.codex-tool-call.v2"',
  '"carrier":"agent-convert.codex-tool-call.v2","carrier":"spoof"');
mutation("Codex duplicate carrier member remains ordinary",
  !carrierReconciles("codex", codexArtifact(codexCallRow(
    duplicateCodexCarrierText))));
const unstampedSession = clone(codexSession);
delete unstampedSession.payload._agent_convert;
mutation("Codex carrier requires exact session stamp",
  !carrierReconciles("codex", codexArtifact(codexCallRow(), unstampedSession)));
const wrongCodexSession = clone(codexSession);
wrongCodexSession.payload._agent_convert.protocol =
  "agent-convert.codex-carriers.v2";
mutation("Codex carrier rejects wrong session stamp",
  !carrierReconciles("codex", codexArtifact(codexCallRow(), wrongCodexSession)));
const lateCodexSession = `${JSON.stringify(codexCallRow())}\n${JSON.stringify(codexSession)}\n`;
mutation("Codex session stamp must be first",
  !carrierReconciles("codex", lateCodexSession));

const codexResultSource = finalizeLifecycle([
  call("source-call", valueId("carrier-id"), "carrier_tool", { exact: true }),
  result("source-result", valueId("carrier-id"), [{ kind: "text", text: "done" }], {
    provenance: "inferred",
    value: false,
    heuristic: "carrier heuristic",
  }, resolved("source-call", valueId("carrier-id"))),
]);
const codexResultCarrier = {
  call: { kind: "resolved", occurrence: "0:0", rawId: "carrier-id" },
  carrier: "agent-convert.codex-tool-result.v1",
  content: [{ kind: "text", text: "done" }],
  error: { kind: "inferred", isError: false, heuristic: "carrier heuristic" },
  errorProvenance: "inferred: carrier heuristic",
  id: "carrier-id",
  isError: false,
  occurrence: "1:0",
  output: "done",
};
function codexResultArtifact(value) {
  const row = {
    timestamp: codexLaunch.timestamp,
    type: "response_item",
    payload: {
      _agent_convert: {
        kind: "tool_result",
        protocol: "agent-convert.codex-carriers.v1",
      },
      type: "message",
      role: "assistant",
      content: [{
        type: "output_text",
        text: `[Historical tool result from source transcript; not executed by Codex]\n${JSON.stringify(value)}`,
      }],
    },
  };
  return `${[codexSession, codexTurnContext, ...codexPair(codexCallRow()),
    ...codexPair(row)].map(JSON.stringify).join("\n")}\n`;
}
positive("exact Codex result carrier",
  reconcileLifecycle(codexResultSource,
    parseTarget("codex", codexResultArtifact(codexResultCarrier)),
    "allow-native-to-historical").pass);
const inconsistentCodexResult = clone(codexResultCarrier);
inconsistentCodexResult.errorProvenance = "native";
mutation("Codex inconsistent result carrier is rejected", rejects(() =>
  parseTarget("codex", codexResultArtifact(inconsistentCodexResult))));

function jsonlRows(artifact) {
  return artifact.trim().split("\n").map((line) => parseJsonText(line, "mutation JSONL"));
}

function jsonlArtifact(rows) {
  return `${rows.map(JSON.stringify).join("\n")}\n`;
}

function targetJsonlMutation(name, format, artifact, mutate) {
  const rows = clone(jsonlRows(artifact));
  mutate(rows);
  mutation(name, rejects(() => parseTarget(format, jsonlArtifact(rows), name)));
}

const loomEnvelope = parseJsonText(provenanceWire, "Loom envelope mutation baseline");
for (const [name, mutate] of [
  ["Loom removed threads header", (value) => { delete value.threads; }],
  ["Loom numeric coercible entry index", (value) => { value.entries[0].index = 0; }],
  ["Loom numeric coercible active leaf", (value) => { value.activeLeaf = 0; }],
  ["Loom ignored top-level metadata", (value) => { value.ignored = true; }],
]) {
  const changed = clone(loomEnvelope);
  mutate(changed);
  mutation(name, rejects(() => parseTarget("loom", JSON.stringify(changed), name)));
}

const completePiArtifact = piArtifact(piCarrier);
targetJsonlMutation("Pi removed session header", "pi", completePiArtifact,
  (rows) => rows.shift());
targetJsonlMutation("Pi target cwd mutation", "pi", completePiArtifact,
  (rows) => { rows[0].cwd = "/tmp/wrong"; });
targetJsonlMutation("Pi removed target option metadata", "pi", completePiArtifact,
  (rows) => { delete rows[0].loomPi.targetOptions.target_provider; });
targetJsonlMutation("Pi source environment schema mutation", "pi", completePiArtifact,
  (rows) => { delete rows[0].loomPi.sourceEnvironment.provider; });
targetJsonlMutation("Pi removed model-change terminator", "pi", completePiArtifact,
  (rows) => rows.pop());
targetJsonlMutation("Pi coercible carrier source index", "pi", completePiArtifact,
  (rows) => { rows[1].data.value.sourceEntry = "0"; });
targetJsonlMutation("Pi ignored historical block metadata", "pi", completePiArtifact,
  (rows) => { rows[1].data.value.blocks[0].ignored = true; });

function piCarrierResultArtifact(toolName) {
  const rows = jsonlRows(completePiArtifact);
  const resultRow = {
    customType: "loom.pi.carrier",
    data: {
      kind: "toolResult",
      value: {
        call: { sourceBlock: 0, sourceEntry: 0, state: "resolved" },
        content: [{ text: "done", type: "text" }],
        error: { state: "native", value: false },
        toolCallId: "carrier-id",
        toolName,
      },
      version: 1,
    },
    id: "pi-self-test-result",
    parentId: rows[1].id,
    timestamp: piLaunch.timestamp,
    type: "custom",
  };
  rows.splice(2, 0, resultRow);
  rows.at(-1).parentId = resultRow.id;
  return jsonlArtifact(rows);
}
const piCarrierResultSource = finalizeLifecycle([
  call("call", valueId("carrier-id"), "carrier_tool", { exact: true }),
  result("result", valueId("carrier-id"), [{ kind: "text", text: "done" }],
    { provenance: "native", value: false }, resolved("call", valueId("carrier-id"))),
]);
positive("Pi historical result toolName matches referenced call",
  reconcileLifecycle(piCarrierResultSource,
    parseTarget("pi", piCarrierResultArtifact("carrier_tool")),
    "allow-native-to-historical").pass);
mutation("Pi historical result toolName mismatch is rejected", rejects(() =>
  parseTarget("pi", piCarrierResultArtifact("wrong_tool"))));

function piNativeArtifact(toolName) {
  const rows = jsonlRows(completePiArtifact);
  const usage = {
    cacheRead: 0,
    cacheWrite: 0,
    cost: { cacheRead: 0, cacheWrite: 0, input: 0, output: 0, total: 0 },
    input: 0,
    output: 0,
    totalTokens: 0,
  };
  const callRow = {
    id: "pi-native-call-row",
    message: {
      api: "openai-completions",
      content: [{ arguments: { exact: true }, id: "carrier-id",
        name: "carrier_tool", type: "toolCall" }],
      model: "model",
      provider: "provider",
      role: "assistant",
      stopReason: "toolUse",
      timestamp: 1,
      usage,
    },
    parentId: null,
    timestamp: piLaunch.timestamp,
    type: "message",
  };
  const resultRow = {
    id: "pi-native-result-row",
    message: {
      content: [{ text: "done", type: "text" }],
      isError: false,
      role: "toolResult",
      timestamp: 2,
      toolCallId: "carrier-id",
      toolName,
    },
    parentId: callRow.id,
    timestamp: piLaunch.timestamp,
    type: "message",
  };
  rows.splice(1, 1, callRow, resultRow);
  rows.at(-1).parentId = resultRow.id;
  return jsonlArtifact(rows);
}
positive("Pi native result toolName matches referenced call",
  reconcileLifecycle(piCarrierResultSource,
    parseTarget("pi", piNativeArtifact("carrier_tool")), "exact").pass);
mutation("Pi native result toolName mismatch is rejected", rejects(() =>
  parseTarget("pi", piNativeArtifact("wrong_tool"))));
targetJsonlMutation("Pi ignored usage metadata is rejected", "pi",
  piNativeArtifact("carrier_tool"),
  (rows) => { rows[1].message.usage.ignored = true; });

const completeClaudeArtifact = claudeArtifact(claudeMarker);
targetJsonlMutation("Claude removed provenance header", "claude", completeClaudeArtifact,
  (rows) => rows.splice(rows.length - 2, 1));
targetJsonlMutation("Claude removed last-prompt header", "claude", completeClaudeArtifact,
  (rows) => rows.pop());
targetJsonlMutation("Claude role envelope mutation", "claude", completeClaudeArtifact,
  (rows) => { rows[0].message.role = "user"; });
targetJsonlMutation("Claude target session mutation", "claude", completeClaudeArtifact,
  (rows) => { rows[0].sessionId = "92000000-0000-4000-8000-000000000000"; });
targetJsonlMutation("Claude coercible carrier index", "claude", completeClaudeArtifact,
  (rows) => { rows[0]._agent_convert.contentBlocks = ["0"]; });
targetJsonlMutation("Claude historical header removed", "claude", completeClaudeArtifact,
  (rows) => { rows[0].message.content[0].text = JSON.stringify(claudeCarrierObject); });
targetJsonlMutation("Claude ignored marker metadata", "claude", completeClaudeArtifact,
  (rows) => { rows[0]._agent_convert.ignored = true; });
targetJsonlMutation("Claude ignored content-block metadata", "claude", completeClaudeArtifact,
  (rows) => { rows[0].message.content[0].ignored = true; });

const claudeInertRows = jsonlRows(completeClaudeArtifact);
claudeInertRows[0] = {
  _agent_convert: {
    identityProvenance: {
      carrier: "agent-convert.claude-identity-provenance.v1",
      sourceEntryId: null,
      trust: "historical-unverified",
    },
    inertPayload: {
      carrier: "agent-convert.claude-inert-payload.v1",
      payload: {
        event: {
          kind: "custom",
          label: "self-test.event",
          raw: { exact: true },
        },
        kind: "event",
      },
    },
    protocol: "agent-convert.claude-carriers.v1",
    timeProvenance: {
      carrier: "agent-convert.time-provenance.v1",
      kind: "absent",
    },
  },
  content: null,
  cwd: claudeCwd,
  isSidechain: false,
  parentUuid: null,
  sessionId: claudeBinding.cell.targetSessionId,
  subtype: "agent_convert_inert",
  timestamp: claudeLaunch.timestamp,
  type: "system",
  uuid: "91000000-0000-4000-8000-000000000001",
};
const completeClaudeInertArtifact = jsonlArtifact(claudeInertRows);
positive("complete Claude inert carrier envelope",
  parseTarget("claude", completeClaudeInertArtifact).events.length === 0);
targetJsonlMutation("Claude ignored identity metadata", "claude",
  completeClaudeInertArtifact,
  (rows) => { rows[0]._agent_convert.identityProvenance.ignored = true; });
targetJsonlMutation("Claude ignored time metadata", "claude",
  completeClaudeInertArtifact,
  (rows) => { rows[0]._agent_convert.timeProvenance.ignored = true; });
targetJsonlMutation("Claude ignored inert wrapper metadata", "claude",
  completeClaudeInertArtifact,
  (rows) => { rows[0]._agent_convert.inertPayload.ignored = true; });
targetJsonlMutation("Claude ignored inert payload metadata", "claude",
  completeClaudeInertArtifact,
  (rows) => { rows[0]._agent_convert.inertPayload.payload.ignored = true; });
targetJsonlMutation("Claude fallback timestamp mutation", "claude",
  completeClaudeInertArtifact,
  (rows) => { rows[0].timestamp = "2026-07-21T12:34:57.000Z"; });

const completeCodexArtifact = codexArtifact(codexCallRow());
targetJsonlMutation("Codex removed session header", "codex", completeCodexArtifact,
  (rows) => rows.shift());
targetJsonlMutation("Codex removed turn_context header", "codex", completeCodexArtifact,
  (rows) => rows.splice(1, 1));
targetJsonlMutation("Codex target cwd mutation", "codex", completeCodexArtifact,
  (rows) => { rows[0].payload.cwd = "/tmp/wrong"; });
targetJsonlMutation("Codex control bundle mutation", "codex", completeCodexArtifact,
  (rows) => { rows[1].payload.sandbox_policy.network_access = true; });
targetJsonlMutation("Codex response role mutation", "codex", completeCodexArtifact,
  (rows) => { rows[2].payload.role = "user"; });
targetJsonlMutation("Codex event mirror mutation", "codex", completeCodexArtifact,
  (rows) => { rows[3].payload.message = "different"; });
targetJsonlMutation("Codex ignored session metadata", "codex", completeCodexArtifact,
  (rows) => { rows[0].payload.ignored = true; });
targetJsonlMutation("Codex ignored session stamp metadata", "codex", completeCodexArtifact,
  (rows) => { rows[0].payload._agent_convert.ignored = true; });
targetJsonlMutation("Codex ignored source archive metadata", "codex", completeCodexArtifact,
  (rows) => { rows[0].payload._agent_convert_source_archive.ignored = true; });
targetJsonlMutation("Codex ignored response metadata", "codex", completeCodexArtifact,
  (rows) => { rows[2].payload.ignored = true; });
const codexFallbackRows = jsonlRows(completeCodexArtifact);
for (const row of codexFallbackRows.slice(2)) {
  row._agent_convert_time = {
    kind: "entry_time_provenance",
    protocol: "agent-convert.codex-carriers.v1",
    state: "absent",
  };
}
const completeCodexFallbackArtifact = jsonlArtifact(codexFallbackRows);
positive("complete Codex fallback timestamp envelope",
  parseTarget("codex", completeCodexFallbackArtifact).events.length === 1);
targetJsonlMutation("Codex fallback timestamp mutation", "codex",
  completeCodexFallbackArtifact,
  (rows) => { rows[2].timestamp = "2026-07-21T12:34:57.000Z"; });

const cursorAgentArtifact = `${JSON.stringify({
  role: "assistant",
  message: {
    content: [{ type: "text", text: "start" }, {
      type: "tool_use",
      name: "Shell",
      input: { command: "printf ok" },
    }],
  },
})}\n`;
positive("complete target-native Cursor Agent envelope",
  parseTarget("cursor-agent", cursorAgentArtifact).events.length === 1);
const cursorApplyPatchRows = jsonlRows(cursorAgentArtifact);
cursorApplyPatchRows[0].message.content[1].name = "ApplyPatch";
cursorApplyPatchRows[0].message.content[1].input = "*** Begin Patch\n*** End Patch";
positive("Cursor Agent native ApplyPatch string input",
  parseTarget("cursor-agent", jsonlArtifact(cursorApplyPatchRows)).events[0]
    .arguments === "*** Begin Patch\n*** End Patch");
const cursorWithIdRows = jsonlRows(cursorAgentArtifact);
cursorWithIdRows[0].message.content[1].id = "call_1";
positive("Cursor Agent optional tool id is accepted",
  parseTarget("cursor-agent", jsonlArtifact(cursorWithIdRows)).events.length === 1);
targetJsonlMutation("Cursor Agent private carrier is rejected", "cursor-agent",
  cursorAgentArtifact, (rows) => { rows[0]._agent_convert = { carrier: "private" }; });
targetJsonlMutation("Cursor Agent empty tool id is rejected", "cursor-agent",
  cursorAgentArtifact, (rows) => { rows[0].message.content[1].id = ""; });
targetJsonlMutation("Cursor Agent non-string tool id is rejected", "cursor-agent",
  cursorAgentArtifact, (rows) => { rows[0].message.content[1].id = 7; });
targetJsonlMutation("Cursor Agent role mutation is rejected", "cursor-agent",
  cursorAgentArtifact, (rows) => { rows[0].role = "system"; });
targetJsonlMutation("Cursor Agent ignored message metadata is rejected", "cursor-agent",
  cursorAgentArtifact, (rows) => { rows[0].message.ignored = true; });
targetJsonlMutation("Cursor Agent turn_ended control is rejected", "cursor-agent",
  cursorAgentArtifact, (rows) => rows.push({
    type: "turn_ended", status: "ok", error: "",
  }));
targetJsonlMutation("Cursor Agent unknown control record is rejected", "cursor-agent",
  cursorAgentArtifact, (rows) => rows.push({ type: "agent-convert-history" }));

const snapshotTestRoot = mkdtempSync(join(tmpdir(), "loom-audit-self-test-"));
try {
  const originalExecutable = join(snapshotTestRoot, "candidate-original");
  const snapshotExecutable = join(snapshotTestRoot, "candidate-snapshot");
  const originalBytes = Buffer.from("#!/bin/sh\nprintf 'snapshot-v1\\n'\n", "utf8");
  writeFileSync(originalExecutable, originalBytes, { flag: "wx", mode: 0o700 });
  const originalBinding = readFileBinding(originalExecutable,
    "self-test original executable");
  const snapshotBinding = writeBoundSnapshot(originalBinding, snapshotExecutable,
    0o500, "self-test executable snapshot");
  positive("executable snapshot binds exact start-loaded bytes",
    snapshotBinding.sha256 === originalBinding.sha256 &&
      snapshotBinding.size === originalBinding.size &&
      snapshotBinding.mode === 0o500);
  const snapshotRun = spawnSync(snapshotBinding.path, [], { encoding: "utf8" });
  positive("executable snapshot runs preserved bytes",
    snapshotRun.status === 0 && snapshotRun.signal === null &&
      snapshotRun.stdout === "snapshot-v1\n" && snapshotRun.stderr === "");

  const linkedExecutable = join(snapshotTestRoot, "candidate-link");
  const replacementLink = join(snapshotTestRoot, "candidate-link-replacement");
  symlinkSync(originalExecutable, linkedExecutable);
  const linkedBinding = readFileBinding(linkedExecutable,
    "self-test linked executable");
  symlinkSync(originalExecutable, replacementLink);
  renameSync(replacementLink, linkedExecutable);
  mutation("same-target symlink path replacement is detected",
    !fileBindingMatches(linkedBinding, "replaced executable symlink"));

  writeFileSync(originalExecutable,
    "#!/bin/sh\nprintf 'source-mutated\\n'\n", { flag: "w", mode: 0o700 });
  mutation("original executable source mutation is detected",
    !fileBindingMatches(originalBinding, "mutated original executable"));

  const replacementExecutable = join(snapshotTestRoot, "candidate-replacement");
  writeFileSync(replacementExecutable, originalBytes, { flag: "wx", mode: 0o700 });
  renameSync(replacementExecutable, originalExecutable);
  mutation("same-byte original path replacement is detected",
    !fileBindingMatches(originalBinding, "replaced original executable"));

  const specialModeFile = join(snapshotTestRoot, "special-mode-binding");
  writeFileSync(specialModeFile, "mode-binding\n", { flag: "wx", mode: 0o600 });
  chmodSync(specialModeFile, 0o600);
  const specialModeBinding = readFileBinding(specialModeFile,
    "self-test special-mode binding");
  positive("special-mode fixture starts at 0600", specialModeBinding.mode === 0o600);
  chmodSync(specialModeFile, 0o1600);
  mutation("0600 to 01600 special-bit mode mutation is detected",
    !fileBindingMatches(specialModeBinding, "special-bit-mutated binding"));

  chmodSync(snapshotExecutable, 0o700);
  writeFileSync(snapshotExecutable,
    "#!/bin/sh\nprintf 'snapshot-mutated\\n'\n", { flag: "w" });
  mutation("execution snapshot mutation is detected",
    !fileBindingMatches(snapshotBinding, "mutated executable snapshot"));
} finally {
  rmSync(snapshotTestRoot, { recursive: true, force: true });
}

const mainText = readFileSync(mainScript, "utf8");
positive("no source or dist adapter import",
  !/from\s+["'][^"']*(?:\/src\/|\/dist\/)/.test(mainText));
positive("no forbidden semantic-oracle command", !/["']inspect["']/.test(mainText));
positive("canonical report serialization is deterministic",
  canonicalJson({ z: 1, a: { y: 2, x: 3 } }) ===
    canonicalJson({ a: { x: 3, y: 2 }, z: 1 }));
positive("candidate identity and cells execute through one snapshot runner",
  mainText.includes("runProcess(candidateSnapshot.path, args)") &&
    mainText.includes("candidateIdentity(runCandidate") &&
    !mainText.includes("runProcess(paths.loom"));
positive("candidate snapshot precedes identity execution",
  mainText.indexOf("const candidateSnapshot = writeBoundSnapshot") <
    mainText.indexOf("const identity = candidateIdentity"));
positive("artifact containment is proven before sentinel creation",
  mainText.indexOf("const artifactPath = containedFile") <
    mainText.indexOf("if (sentinel) writeFileSync"));
positive("matrix automatically runs and gates the mutation self-test",
  mainText.includes("const mutationSelfTest = runMutationSelfTest") &&
    mainText.includes("mutationSelfTest.pass && bindingsPass"));
positive("matrix executes self-test from bound harness snapshots",
  mainText.includes("[harnessSnapshots.selfTest.path]") &&
    mainText.includes("loadedManifestSnapshot") &&
    !mainText.includes("runProcess(process.execPath, [selfTestPath])"));

emitResult(true);
