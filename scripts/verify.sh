#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOOM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Optional TypeScript host checkout (utils or agent-convert). Required for host gates.
UTILS_ROOT="${LOOM_UTILS_ROOT:-}"
if [[ -z "$UTILS_ROOT" && -f "$LOOM_ROOT/../../package.json" && -d "$LOOM_ROOT/../../src" ]]; then
  # Nested host layout: <host>/spec/loom → <host>
  UTILS_ROOT="$(cd "$LOOM_ROOT/../.." && pwd)"
fi
TSX="${UTILS_ROOT:+$UTILS_ROOT/node_modules/.bin/tsx}"
LOOM_BIN="$LOOM_ROOT/.lake/build/bin/loom"

if [[ -z "$UTILS_ROOT" || ! -x "${TSX:-}" ]]; then
  echo "error: TypeScript host not found; set LOOM_UTILS_ROOT to a utils/agent-convert checkout with npm install" >&2
  exit 2
fi
if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "error: sqlite3 not found on PATH; Cursor IDE actuator smoke requires it" >&2
  exit 2
fi

cd "$UTILS_ROOT"

echo "== lake build loom + requirements evidence =="
(cd "$LOOM_ROOT" && lake build loom LoomRequirements)

echo "== core identity and protocol contract =="
version_json="$("$LOOM_BIN" version --json)"
node -e '
const version = JSON.parse(process.argv[1]);
const revisionOk = version.coreRevision === "working-tree" ||
  /^[0-9a-f]{40}$/.test(version.coreRevision);
if (version.engine !== "lean" || version.engineVersion !== "0.2.0-preview.0" ||
    version.protocolVersion !== "loom.cli.v1" || !revisionOk ||
    version.sourceRepository !== "https://github.com/theoriclabs/agent-convert-lean" ||
    version.sourcePath !== "." || !version.targetTriple ||
    !Array.isArray(version.wireSchemas) ||
    !version.wireSchemas.includes("loom.transcript.v0")) {
  throw new Error(`unexpected core identity: ${JSON.stringify(version)}`);
}
' "$version_json"

echo "== sidecar publication transaction regressions =="
"$LOOM_BIN" self-test-sidecar-publication

echo "== immutable release-builder regressions =="
"$LOOM_ROOT/scripts/build-release.sh" --self-test

echo "== TypeScript build =="
npm run build

echo "== focused node regressions =="
node "$LOOM_ROOT/scripts/audit-corpora.self-test.mjs"
node "$LOOM_ROOT/scripts/audit-codex-claude.self-test.mjs"
SUBAGENT_SKIP_RUNTIME_FINGERPRINT=1 node --test \
  test/codexAdapter.d13-dedup.test.mjs \
  test/detector-agreement.test.mjs \
  test/loom-thin-launcher.test.mjs

echo "== release evidence protocol self-tests =="
"$LOOM_ROOT/scripts/prepare-human-validation.sh" --self-test
"$LOOM_ROOT/scripts/seal-human-validation.sh" --self-test

echo "== D14/D17 fidelity regressions =="
SUBAGENT_SKIP_RUNTIME_FINGERPRINT=1 node --test \
  --test-name-pattern 'event_msg\.token_count|Google AI Studio errorMessage' \
  test/convert-to-pi.test.mjs \
  test/piedit.import-google-ai-studio.test.mjs

scratch="$(mktemp -d "${TMPDIR:-/tmp}/loom-verify.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

echo "== independent 8x5 lifecycle matrix =="
mkdir -p "$scratch/lifecycle-matrix"
node "$LOOM_ROOT/scripts/audit-lifecycle-matrix.mjs" \
  --loom "$LOOM_BIN" \
  --scratch "$scratch/lifecycle-matrix/scratch" \
  --output "$scratch/lifecycle-matrix/output" \
  --report "$scratch/lifecycle-matrix/report.json"
node -e '
const { readFileSync } = require("node:fs");
const report = JSON.parse(readFileSync(process.argv[1], "utf8"));
if (report.schema !== "agent-convert.lifecycle-matrix-report.v1" ||
    report.overallPass !== true || report.census?.expectedCells !== 40 ||
    report.census?.observedCells !== 40 ||
    report.cells?.length !== 40 ||
    report.cells.some(cell => cell.status !== "pass") ||
    report.harness?.mutationSelfTest?.pass !== true ||
    report.reportBinding?.pathAndSourceStabilityPass !== true ||
    report.candidate?.executionSnapshot?.unchanged !== true ||
    report.candidate?.exactSnapshotOfStartBytes !== true) {
  throw new Error(`lifecycle matrix report did not satisfy the development gate: ${JSON.stringify(report)}`);
}
' "$scratch/lifecycle-matrix/report.json"

control_fixture="$scratch/control-envelopes.metadata.jsonl"
node -e '
const { readFileSync, writeFileSync } = require("node:fs");
const metadataRecords = new Set([
  "63000000-0000-4000-8000-000000000002",
  "63000000-0000-4000-8000-000000000005",
  "63000000-0000-4000-8000-000000000006",
  "63000000-0000-4000-8000-000000000007",
]);
const records = readFileSync(process.argv[1], "utf8").trimEnd().split("\n").map(JSON.parse);
for (const record of records) {
  if (metadataRecords.has(record.uuid)) record.isMeta = true;
}
writeFileSync(process.argv[2], records.map(JSON.stringify).join("\n") + "\n");
' "$LOOM_ROOT/testdata/claude/control-envelopes.jsonl" "$control_fixture"

stage_fixture() {
  local fmt="$1"
  local fixture="$2"
  mkdir -p "$scratch/$fmt"
  cp "$LOOM_ROOT/parity/fixtures/$fixture" "$scratch/$fmt/$fixture"
}

expect_sidechain_flat_refusal() {
  local label="$1"
  local from="$2"
  local to="$3"
  local input="$4"
  local status
  shift 4
  if [[ "$to" == "codex" ]]; then
    if (cd "$LOOM_ROOT" && lake exe loom convert "$from" "$to" "$input" "$scratch/$label.flat.out" \
      --target-codex-approval-policy on-request \
      --target-codex-network-access false \
      --target-codex-exclude-tmpdir-env-var true \
      --target-codex-exclude-slash-tmp true \
      --target-codex-summary concise \
      "$@" >"$scratch/$label.out" 2>"$scratch/$label.err"); then
      status=0
    else
      status=$?
    fi
  else
    if (cd "$LOOM_ROOT" && lake exe loom convert "$from" "$to" "$input" "$scratch/$label.flat.out" \
        "$@" >"$scratch/$label.out" 2>"$scratch/$label.err"); then
      status=0
    else
      status=$?
    fi
  fi
  if [[ "$status" -eq 0 ]]; then
    echo "error: $label unexpectedly flattened sidechains" >&2
    exit 1
  else
    if [[ "$status" -ne 3 ]]; then
      cat "$scratch/$label.err" >&2
      echo "error: $label exited $status, expected 3" >&2
      exit 1
    fi
    if ! grep -q "sidechain/detached" "$scratch/$label.err"; then
      cat "$scratch/$label.err" >&2
      echo "error: $label did not report sidechain/detached refusal" >&2
      exit 1
    fi
    if [[ -e "$scratch/$label.flat.out" ]]; then
      echo "error: $label wrote output despite refusal" >&2
      exit 1
    fi
  fi
}

expect_loom_wire_reject() {
  local label="$1"
  local input="$2"
  local expected="$3"
  if (cd "$LOOM_ROOT" && lake exe loom convert loom loom "$input" "$scratch/$label.out" \
      >"$scratch/$label.stdout" 2>"$scratch/$label.err"); then
    echo "error: $label unexpectedly accepted invalid Loom wire" >&2
    exit 1
  else
    local status=$?
    if [[ "$status" -ne 2 ]]; then
      cat "$scratch/$label.err" >&2
      echo "error: $label exited $status, expected 2" >&2
      exit 1
    fi
    if ! grep -F -q "$expected" "$scratch/$label.err"; then
      cat "$scratch/$label.err" >&2
      echo "error: $label did not report expected wire error: $expected" >&2
      exit 1
    fi
    if [[ -e "$scratch/$label.out" ]]; then
      echo "error: $label wrote output despite import refusal" >&2
      exit 1
    fi
  fi
}

echo "== loom-diff fixture gates =="
stage_fixture pi pi.jsonl
mkdir -p "$scratch/pi/nested"
cp "$LOOM_ROOT/parity/fixtures/pi.jsonl" "$scratch/pi/nested/pi-nested.jsonl"
cat >"$scratch/pi/nested/pi-source-model-change.jsonl" <<'EOF'
{"type":"session","version":3,"id":"parity-source-model","timestamp":"2026-07-20T00:00:00.000Z","cwd":"/tmp/parity-source"}
{"type":"model_change","id":"source-model","parentId":null,"timestamp":"2026-07-20T00:00:01.000Z","provider":"anthropic","modelId":"claude-source-model"}
{"type":"message","id":"source-user","parentId":"source-model","timestamp":"2026-07-20T00:00:02.000Z","message":{"role":"user","content":[{"type":"text","text":"source model change remains visible"}],"timestamp":1784505602000}}
EOF
stage_fixture claude claude.jsonl
stage_fixture codex codex.jsonl
stage_fixture cursor-agent cursor-agent.jsonl

echo "== deterministic CLI output gate =="
(cd "$LOOM_ROOT" && "$LOOM_BIN" convert claude loom parity/fixtures/claude.jsonl) \
  >"$scratch/deterministic-a.out" 2>"$scratch/deterministic-a.err"
(cd "$LOOM_ROOT" && "$LOOM_BIN" convert claude loom parity/fixtures/claude.jsonl) \
  >"$scratch/deterministic-b.out" 2>"$scratch/deterministic-b.err"
cmp "$scratch/deterministic-a.out" "$scratch/deterministic-b.out"
cmp "$scratch/deterministic-a.err" "$scratch/deterministic-b.err"

echo "== same-format Claude environment preservation gate =="
"$LOOM_BIN" convert claude claude "$LOOM_ROOT/parity/fixtures/claude.jsonl" \
  "$scratch/same-format.claude.jsonl" --json \
  >"$scratch/same-format.summary.json"
node -e '
const { readFileSync } = require("node:fs");
const rows = readFileSync(process.argv[1], "utf8").trimEnd().split("\n").map(JSON.parse);
const summary = JSON.parse(readFileSync(process.argv[2], "utf8"));
const conversation = rows.filter(row => row.type === "user" || row.type === "assistant");
if (conversation.length === 0 || conversation.some(row =>
    row.cwd !== "/w" || row.sessionId !== "61000000-0000-4000-8000-000000000000")) {
  throw new Error("same-format Claude export did not preserve physical cwd/session");
}
if (rows.some(row => row._agent_convert?.transcriptProvenance?.kind === "sourceEnv")) {
  throw new Error("native same-format Claude export invented a source-environment carrier");
}
if (summary.cwd !== "/w" || summary.sessionId !== "61000000-0000-4000-8000-000000000000") {
  throw new Error(`same-format summary lost source environment: ${JSON.stringify(summary)}`);
}
' "$scratch/same-format.claude.jsonl" "$scratch/same-format.summary.json"

echo "== stdout JSONL framing gate =="
"$LOOM_BIN" convert claude pi \
  "$LOOM_ROOT/testdata/release/continuation-source.claude.jsonl" \
  --target-cwd /tmp/loom-stdout-pi \
  --target-provider deepseek --target-model deepseek-v4-flash \
  --target-session-id stdout-pi-target \
  --target-timestamp 2026-07-20T01:02:03.004Z \
  --target-harness-version 0.74.0 \
  >"$scratch/stdout.pi.jsonl"
"$LOOM_BIN" convert codex claude "$LOOM_ROOT/parity/fixtures/codex.jsonl" \
  --target-cwd /tmp/loom-stdout-claude \
  --target-harness-version 2.1.216 \
  --target-session-id 69000000-0000-4000-8000-000000000000 \
  --target-timestamp 2026-07-20T01:02:03.004Z \
  >"$scratch/stdout.claude.jsonl"
"$LOOM_BIN" convert claude codex \
  "$LOOM_ROOT/testdata/release/continuation-source.claude.jsonl" \
  --target-cwd /tmp/loom-stdout-codex \
  --target-provider openai --target-model gpt-5.5 \
  --target-harness-version 0.144.1 \
  --target-session-id 31111111-2222-4333-8444-555555555555 \
  --target-timestamp 2026-07-10T01:02:03.004Z \
  --target-codex-approval-policy on-request \
  --target-codex-network-access false \
  --target-codex-exclude-tmpdir-env-var true \
  --target-codex-exclude-slash-tmp true \
  --target-codex-summary concise \
  >"$scratch/stdout.codex.jsonl"
"$LOOM_BIN" convert cursor-agent cursor-agent \
  "$LOOM_ROOT/parity/fixtures/cursor-agent.jsonl" \
  >"$scratch/stdout.cursor-agent.jsonl"
node -e '
const { readFileSync } = require("node:fs");
for (const path of process.argv.slice(1)) {
  const bytes = readFileSync(path);
  if (bytes.length < 2 || bytes.at(-1) !== 10 || bytes.at(-2) === 10) {
    throw new Error(`${path} must end in exactly one newline`);
  }
  for (const [index, line] of bytes.toString("utf8").slice(0, -1).split("\n").entries()) {
    if (!line) throw new Error(`${path}:${index + 1} is a blank JSONL record`);
    JSON.parse(line);
  }
}
' "$scratch/stdout.pi.jsonl" "$scratch/stdout.claude.jsonl" \
  "$scratch/stdout.codex.jsonl" "$scratch/stdout.cursor-agent.jsonl"
"$LOOM_BIN" inspect claude "$scratch/stdout.claude.jsonl" \
  >"$scratch/stdout.claude.inspect"

echo "== readable transcript and Claude control-envelope gate =="
(cd "$LOOM_ROOT" && "$LOOM_BIN" inspect claude "$control_fixture") \
  >"$scratch/inspect.out" 2>"$scratch/inspect.err"
grep -F -q "## 0 USER" "$scratch/inspect.out"
grep -F -q "Name: /goal" "$scratch/inspect.out"
grep -F -q "Arguments: preserve the conversation" "$scratch/inspect.out"
grep -F -q "[tool call Read; id=toolu_read_1]" "$scratch/inspect.out"
grep -F -q "## 2 ENVIRONMENT" "$scratch/inspect.out"
grep -F -q "Task notification" "$scratch/inspect.out"
grep -F -q "Event: status=completed" "$scratch/inspect.out"
grep -F -q "Instruction: If this event is something the user would act on now" "$scratch/inspect.out"
if grep -E -q '<(/)?(command-name|command-message|command-args|system-reminder|ide_opened_file|task-notification|task-id|summary|event)>' \
    "$scratch/inspect.out"; then
  echo "error: Claude control markup leaked into readable transcript" >&2
  exit 1
fi
test ! -s "$scratch/inspect.err"

(cd "$LOOM_ROOT" && "$LOOM_BIN" inspect claude "$control_fixture" --json) \
  >"$scratch/inspect.json" 2>"$scratch/inspect-json.err"
node -e '
const { readFileSync } = require("node:fs");
const result = JSON.parse(readFileSync(process.argv[1], "utf8"));
if (result.engine !== "lean" || !result.engineVersion || !result.coreRevision ||
    result.source !== "claude" || result.transcript?.schema !== "loom.transcript.v0") {
  throw new Error(`unexpected inspect JSON: ${JSON.stringify(result)}`);
}
const archivedControls = result.transcript.origin?.extras?.raw_control_messages;
if (!Array.isArray(archivedControls) || archivedControls.length !== 4 ||
    archivedControls.some(control => control.record?.isMeta !== true)) {
  throw new Error(`genuine Claude controls lost isMeta provenance: ${JSON.stringify(archivedControls)}`);
}
' "$scratch/inspect.json"
test ! -s "$scratch/inspect-json.err"

node -e '
const { writeFileSync } = require("node:fs");
writeFileSync(process.argv[1], JSON.stringify({
  type: "user",
  uuid: "63100000-0000-4000-8000-000000000001",
  parentUuid: null,
  sessionId: "63100000-0000-4000-8000-000000000000",
  cwd: "/tmp/control-literal",
  timestamp: "2026-07-09T00:01:00.000Z",
  isSidechain: false,
  isMeta: false,
  message: { role: "user", content: "<system-reminder>literal example</system-reminder>" },
}) + "\n");
' "$scratch/control-literal.claude.jsonl"
"$LOOM_BIN" inspect claude "$scratch/control-literal.claude.jsonl" \
  >"$scratch/control-literal.inspect"
grep -F -q '<system-reminder>literal example</system-reminder>' \
  "$scratch/control-literal.inspect"

echo "== stale Claude isMeta mutation E-I-E gate =="
node -e '
const { writeFileSync } = require("node:fs");
writeFileSync(process.argv[1], JSON.stringify({
  type: "user",
  uuid: "63200000-0000-4000-8000-000000000001",
  parentUuid: null,
  sessionId: "63200000-0000-4000-8000-000000000000",
  cwd: "/tmp/stale-is-meta",
  timestamp: "2026-07-09T00:02:00.000Z",
  isSidechain: false,
  isMeta: true,
  message: { role: "user", content: "ordinary source user text" },
}) + "\n");
' "$scratch/stale-is-meta.source.jsonl"
"$LOOM_BIN" convert claude loom "$scratch/stale-is-meta.source.jsonl" \
  "$scratch/stale-is-meta.wire.json" >/dev/null
node -e '
const { readFileSync, writeFileSync } = require("node:fs");
const wire = JSON.parse(readFileSync(process.argv[1], "utf8"));
const entry = wire.entries?.[0];
if (entry?.payload?.type !== "userMsg" || entry.payload.blocks?.[0]?.type !== "text") {
  throw new Error(`stale isMeta source did not import as typed user content: ${JSON.stringify(entry)}`);
}
entry.payload.blocks[0].text = "<system-reminder>literal current user text</system-reminder>";
writeFileSync(process.argv[2], JSON.stringify(wire) + "\n");
' "$scratch/stale-is-meta.wire.json" "$scratch/stale-is-meta.mutated.json"
"$LOOM_BIN" convert loom claude "$scratch/stale-is-meta.mutated.json" \
  "$scratch/stale-is-meta.first.jsonl" >/dev/null
node -e '
const { readFileSync } = require("node:fs");
const rows = readFileSync(process.argv[1], "utf8").trimEnd().split("\n").map(JSON.parse);
const user = rows.find(row => row.type === "user");
if (!user || user.isMeta === true ||
    user.message?.content?.[0]?.text !== "<system-reminder>literal current user text</system-reminder>") {
  throw new Error(`current typed user state did not override stale isMeta: ${JSON.stringify(user)}`);
}
' "$scratch/stale-is-meta.first.jsonl"
"$LOOM_BIN" convert claude loom "$scratch/stale-is-meta.first.jsonl" \
  "$scratch/stale-is-meta.reimport.json" >/dev/null
node -e '
const { readFileSync } = require("node:fs");
const wire = JSON.parse(readFileSync(process.argv[1], "utf8"));
const entry = wire.entries?.[0];
if (wire.entries?.length !== 1 || entry?.payload?.type !== "userMsg" ||
    entry.payload.blocks?.[0]?.text !== "<system-reminder>literal current user text</system-reminder>" ||
    wire.origin?.extras?.raw_control_messages !== undefined) {
  throw new Error(`stale isMeta mutation reimported as control state: ${JSON.stringify(wire)}`);
}
' "$scratch/stale-is-meta.reimport.json"
"$LOOM_BIN" convert loom claude "$scratch/stale-is-meta.reimport.json" \
  "$scratch/stale-is-meta.second.jsonl" >/dev/null
cmp "$scratch/stale-is-meta.first.jsonl" "$scratch/stale-is-meta.second.jsonl"

echo "== Codex target readability and append-safety artifact gate =="
"$LOOM_BIN" convert claude codex \
  "$control_fixture" \
  "$scratch/readable.codex.jsonl" \
  --target-cwd /tmp/loom-readable-codex \
  --target-provider openai --target-model gpt-5.5 \
  --target-harness-version 0.144.1 \
  --target-session-id 11111111-2222-4333-8444-555555555555 \
  --target-timestamp 2026-07-10T01:02:03.004Z \
  --target-codex-approval-policy on-request \
  --target-codex-network-access false \
  --target-codex-exclude-tmpdir-env-var true \
  --target-codex-exclude-slash-tmp true \
  --target-codex-summary concise --json \
  >"$scratch/readable.codex.summary.json"
node -e '
const { readFileSync } = require("node:fs");
const bytes = readFileSync(process.argv[1]);
const summary = JSON.parse(readFileSync(process.argv[2], "utf8"));
if (!Array.isArray(summary.exportObligations) ||
    summary.exportObligationCount !== summary.exportObligations.length ||
    summary.exportObligations.some(item => typeof item?.kind !== "string" ||
      !["fulfillment", "reportOnly", "destructive"].includes(item?.impact))) {
  throw new Error(`invalid export obligation report: ${JSON.stringify(summary)}`);
}
if (bytes.at(-1) !== 10) throw new Error("Codex JSONL lacks terminal record delimiter");
const text = bytes.toString("utf8");
const rows = text.trimEnd().split("\n").map(JSON.parse);
const meta = rows[0]?.payload;
if (meta?.id !== "11111111-2222-4333-8444-555555555555" ||
    meta?.cli_version !== "0.144.1" || meta?.originator !== "agent-convert") {
  throw new Error(`unexpected session metadata: ${JSON.stringify(meta)}`);
}
const turnContext = rows.find(row => row.type === "turn_context")?.payload;
if (turnContext?.model !== "gpt-5.5" || turnContext?.cwd !== meta.cwd) {
  throw new Error(`unexpected target turn context: ${JSON.stringify(turnContext)}`);
}
if (!rows.some((row) => row.payload?.type === "user_message") ||
    !rows.some((row) => row.payload?.type === "agent_message")) {
  throw new Error("Codex target lacks TUI display twins");
}
if (/<\/?(?:command-name|command-message|command-args|system-reminder|ide_opened_file|task-notification|task-id|summary|event)>/.test(text)) {
  throw new Error("raw Claude control wrapper leaked into Codex target");
}
const expected = {
  toolCallsImported: 1,
  toolResultsImported: 1,
  openToolCallsImported: 0,
  syntheticToolResults: 0,
};
for (const [key, value] of Object.entries(expected)) {
  if (summary[key] !== value) throw new Error(`${key}: ${summary[key]} !== ${value}`);
}
// Native lifecycle policy (af0b289e/3882d70a): a Claude lifecycle that Codex can
// express arrives as Codex function_call/function_call_output, not as prose. The
// counters are asserted as RELATIONS against the census this same run reports —
// a literal here pins one measurement and rots the next time the fixture moves.
const relations = {
  "every imported call is emitted natively or carried":
    summary.toolCallsEmittedNative + summary.toolCallsCarriedAsHistory ===
      summary.toolCallsImported,
  "every imported result is emitted natively or carried":
    summary.toolResultsEmitted + summary.toolResultsCarriedAsHistory ===
      summary.toolResultsImported,
  "every closed call is emitted natively":
    summary.toolCallsEmittedNative ===
      summary.toolCallsImported - summary.openToolCallsImported,
  "a natively emitted call carries its result natively":
    summary.toolResultsEmitted === summary.toolResultsImported,
  "no call is left as prose when Codex can express it":
    summary.toolCallsCarriedAsHistory === 0,
};
for (const [claim, held] of Object.entries(relations)) {
  if (!held) throw new Error(`Codex target broke the relation '${claim}': ${JSON.stringify(summary)}`);
}
' "$scratch/readable.codex.jsonl" "$scratch/readable.codex.summary.json"

echo "== Codex-to-Claude tool lifecycle and context-isolation gate =="
node "$LOOM_ROOT/scripts/audit-codex-claude.self-test.mjs"
"$LOOM_BIN" convert codex claude \
  "$LOOM_ROOT/testdata/codex/tool-lifecycle-controls.jsonl" \
  "$scratch/codex-tool-control.claude.jsonl" \
  --target-cwd /tmp/loom-codex-to-claude \
  --target-harness-version 2.1.216 \
  --target-session-id 00000000-0000-7000-8000-000000000001 \
  --target-timestamp 2026-07-20T01:02:03.004Z --json \
  >"$scratch/codex-tool-control.summary.json"
node "$LOOM_ROOT/scripts/audit-codex-claude.mjs" \
  "$LOOM_ROOT/testdata/codex/tool-lifecycle-controls.jsonl" \
  "$scratch/codex-tool-control.claude.jsonl" \
  >"$scratch/codex-tool-control.audit.json"
node -e '
const { readFileSync } = require("node:fs");
const summary = JSON.parse(readFileSync(process.argv[1], "utf8"));
const audit = JSON.parse(readFileSync(process.argv[2], "utf8"));
const expectedSummary = {
  engine: "lean",
  toolCallsImported: 3,
  toolResultsImported: 2,
  toolCallsCarriedAsHistory: 3,
  toolCallsEmittedNative: 0,
  toolResultsCarriedAsHistory: 2,
  toolResultsEmitted: 0,
  openToolCallsImported: 1,
  openToolCallsEmittedNative: 0,
  syntheticToolResults: 0,
  controlsArchived: 3,
};
for (const [key, value] of Object.entries(expectedSummary)) {
  if (summary[key] !== value) throw new Error(`summary ${key}: ${summary[key]} !== ${value}`);
}
if (!audit.ok || audit.sourceCalls !== 3 || audit.targetNativeCalls !== 0 ||
    audit.targetCarriedCalls !== 3 || audit.sourceResults !== 2 ||
    audit.targetNativeResults !== 0 || audit.targetCarriedResults !== 2 ||
    audit.targetResults !== 2 || audit.syntheticResults !== 0 ||
    audit.linkageMismatches !== 0 ||
    audit.leakedControlTexts !== 0) {
  throw new Error(`unexpected independent audit: ${JSON.stringify(audit)}`);
}
' "$scratch/codex-tool-control.summary.json" "$scratch/codex-tool-control.audit.json"

echo "== Codex active-context disclosure gate =="
"$LOOM_BIN" convert codex pi \
  "$LOOM_ROOT/testdata/codex/active-compaction.jsonl" \
  "$scratch/active-compaction.pi.jsonl" \
  --target-cwd /tmp/loom-active-compaction \
  --target-provider deepseek --target-model deepseek-v4-flash \
  --target-session-id active-compaction-target \
  --target-timestamp 2026-07-20T01:02:03.004Z \
  --target-harness-version 0.74.0 --json \
  >"$scratch/active-compaction.summary.json"
node -e '
const { readFileSync } = require("node:fs");
const summary = JSON.parse(readFileSync(process.argv[1], "utf8"));
const rows = readFileSync(process.argv[2], "utf8").trimEnd().split("\n").map(JSON.parse);
if (summary.activeContext !== true || summary.excludedSourceRecords !== 2 ||
    !Array.isArray(summary.activeContextCompactionBoundaries) ||
    summary.activeContextCompactionBoundaries.length !== 1) {
  throw new Error(`active-context disclosure is incomplete: ${JSON.stringify(summary)}`);
}
const boundary = summary.activeContextCompactionBoundaries[0];
if (boundary.recordIndex !== 1 || boundary.segmentRecordIndex !== 1 ||
    boundary.excludedRecordCount !== 2 || boundary.replacementHistoryCount !== 1 ||
    "excluded_records" in boundary || "boundary_record" in boundary) {
  throw new Error(`unexpected active-context boundary: ${JSON.stringify(boundary)}`);
}
const dialogue = rows.filter(row => row.type === "message")
  .map(row => JSON.stringify(row.message?.content)).join("\n");
if (!dialogue.includes("ACTIVE summarized context") || dialogue.includes("OLD context")) {
  throw new Error("pi artifact does not represent exactly the resumable active context");
}
' "$scratch/active-compaction.summary.json" "$scratch/active-compaction.pi.jsonl"

echo "== all JSONL targets end at a record boundary =="
"$LOOM_BIN" convert claude pi \
  "$control_fixture" \
  "$scratch/append-safe.pi.jsonl" \
  --target-cwd /tmp/loom-append-safe \
  --target-provider deepseek --target-model deepseek-v4-flash \
  --target-session-id append-safe-target \
  --target-timestamp 2026-07-20T01:02:03.004Z \
  --target-harness-version 0.74.0
"$LOOM_BIN" convert cursor-agent cursor-agent \
  "$LOOM_ROOT/parity/fixtures/cursor-agent.jsonl" \
  "$scratch/append-safe.cursor-agent.jsonl"
node -e '
const { readFileSync } = require("node:fs");
for (const path of process.argv.slice(1)) {
  const bytes = readFileSync(path);
  if (bytes.length === 0 || bytes.at(-1) !== 10) {
    throw new Error(`${path} does not end at a JSONL record boundary`);
  }
}
' \
  "$scratch/codex-tool-control.claude.jsonl" \
  "$scratch/readable.codex.jsonl" \
  "$scratch/append-safe.pi.jsonl" \
  "$scratch/append-safe.cursor-agent.jsonl"

echo "== CLI failure-class gate =="
printf '\001agent-convert-existing-output\377without-final-newline' \
  >"$scratch/failure-contract.sentinel"

assert_failure_did_not_publish() {
  local label="$1"
  local output="$2"
  local stdout="$scratch/$label.stdout"
  local stderr="$scratch/$label.err"

  if ! cmp -s "$scratch/failure-contract.sentinel" "$output"; then
    echo "error: $label changed the pre-existing output bytes" >&2
    exit 1
  fi
  for reserved in \
      "$output.agent-convert-stage" \
      "$output.agent-convert-backup"; do
    if [[ -e "$reserved" || -L "$reserved" ]]; then
      echo "error: $label left converter transaction state at $reserved" >&2
      exit 1
    fi
  done
  if [[ -s "$stdout" ]]; then
    cat "$stdout" >&2
    echo "error: $label emitted stdout despite refusing the conversion" >&2
    exit 1
  fi
  if grep -F -q "wrote $output" "$stdout" "$stderr" ||
      grep -F -q "\"output\":\"$output\"" "$stdout" "$stderr"; then
    cat "$stdout" >&2
    cat "$stderr" >&2
    echo "error: $label reported the stale destination as newly published" >&2
    exit 1
  fi
}

invocation_output="$scratch/invocation-sentinel.out"
cp "$scratch/failure-contract.sentinel" "$invocation_output"
if "$LOOM_BIN" convert claude pi "$LOOM_ROOT/parity/fixtures/claude.jsonl" \
    "$invocation_output" \
    --target-cwd /tmp/loom-failure-invocation \
    --target-provider deepseek --target-model deepseek-v4-flash \
    --target-session-id failure-invocation-target \
    --target-harness-version 0.74.0 --target-timestamp \
    >"$scratch/invocation.stdout" 2>"$scratch/invocation.err"; then
  echo "error: incomplete target option unexpectedly succeeded" >&2
  exit 1
else
  status=$?
  expected_invocation="invocation error: unknown or incomplete option: --target-timestamp"
  if [[ "$status" -ne 1 ]] ||
      [[ "$(sed -n '1p' "$scratch/invocation.err")" != "$expected_invocation" ]] ||
      ! grep -F -q "loom convert <from> <to>" "$scratch/invocation.err"; then
    cat "$scratch/invocation.err" >&2
    echo "error: malformed invocation did not preserve the exact class-1 diagnostic" >&2
    exit 1
  fi
  assert_failure_did_not_publish invocation "$invocation_output"
fi

missing_output="$scratch/missing-input.out"
if "$LOOM_BIN" convert claude loom "$scratch/does-not-exist.jsonl" "$missing_output" \
    >"$scratch/missing-input.stdout" 2>"$scratch/missing-input.err"; then
  echo "error: missing input unexpectedly succeeded" >&2
  exit 1
else
  status=$?
  if [[ "$status" -ne 2 ]] || ! grep -F -q "cannot read" "$scratch/missing-input.err"; then
    cat "$scratch/missing-input.err" >&2
    echo "error: missing input did not return class 2" >&2
    exit 1
  fi
  test ! -e "$missing_output"
fi

printf '{not-json\n' >"$scratch/malformed.jsonl"
malformed_output="$scratch/import-sentinel.out"
cp "$scratch/failure-contract.sentinel" "$malformed_output"
if "$LOOM_BIN" convert claude pi "$scratch/malformed.jsonl" "$malformed_output" \
    --target-cwd /tmp/loom-failure-import \
    --target-provider deepseek --target-model deepseek-v4-flash \
    --target-session-id failure-import-target \
    --target-timestamp 2026-07-21T00:00:00.000Z \
    --target-harness-version 0.74.0 \
    >"$scratch/malformed.stdout" 2>"$scratch/malformed.err"; then
  echo "error: malformed input unexpectedly succeeded" >&2
  exit 1
else
  status=$?
  expected_import='import error: malformed Claude JSONL at line 1: offset 1: expected "'
  if [[ "$status" -ne 2 ]] ||
      [[ "$(cat "$scratch/malformed.err")" != "$expected_import" ]]; then
    cat "$scratch/malformed.err" >&2
    echo "error: malformed input did not preserve the exact class-2 diagnostic" >&2
    exit 1
  fi
  assert_failure_did_not_publish malformed "$malformed_output"
fi

cp "$scratch/failure-contract.sentinel" "$scratch/preflight-sentinel.out"
if "$LOOM_BIN" convert pi pi "$LOOM_ROOT/parity/fixtures/pi.jsonl" \
    "$scratch/preflight-sentinel.out" \
    --target-cwd /tmp/loom-failure-export \
    --target-provider deepseek --target-model deepseek-v4-flash \
    --target-session-id failure-export-target \
    --target-timestamp not-a-timestamp --target-harness-version 0.74.0 \
    >"$scratch/preflight.stdout" 2>"$scratch/preflight.err"; then
  echo "error: invalid target preflight unexpectedly succeeded" >&2
  exit 1
else
  status=$?
  expected_export="export error: target 'pi' validity preflight failed: origin.extras.target_timestamp must be UTC ISO-8601 with optional seconds or exactly millisecond precision"
  if [[ "$status" -ne 3 ]] ||
      [[ "$(cat "$scratch/preflight.err")" != "$expected_export" ]]; then
    cat "$scratch/preflight.err" >&2
    echo "error: target preflight did not preserve the exact class-3 diagnostic" >&2
    exit 1
  fi
  assert_failure_did_not_publish preflight "$scratch/preflight-sentinel.out"
fi

printf 'existing-output-must-survive\n' >"$scratch/stage-guard.out"
printf 'reserved-stage-must-survive\n' >"$scratch/stage-guard.out.agent-convert-stage"
if "$LOOM_BIN" convert claude loom "$LOOM_ROOT/parity/fixtures/claude.jsonl" \
    "$scratch/stage-guard.out" \
    >"$scratch/stage-guard.stdout" 2>"$scratch/stage-guard.err"; then
  echo "error: occupied staging path unexpectedly succeeded" >&2
  exit 1
else
  status=$?
  if [[ "$status" -ne 3 ]] || ! grep -F -q "staging path already exists" \
      "$scratch/stage-guard.err"; then
    cat "$scratch/stage-guard.err" >&2
    echo "error: occupied staging path did not return export class 3" >&2
    exit 1
  fi
  test "$(cat "$scratch/stage-guard.out")" = "existing-output-must-survive"
  test "$(cat "$scratch/stage-guard.out.agent-convert-stage")" = \
    "reserved-stage-must-survive"
fi

if "$LOOM_BIN" convert claude loom "$LOOM_ROOT/parity/fixtures/claude.jsonl" \
    "$scratch/missing-parent/output.json" \
    >"$scratch/write-failure.stdout" 2>"$scratch/write-failure.err"; then
  echo "error: unwritable output unexpectedly succeeded" >&2
  exit 1
else
  status=$?
  if [[ "$status" -ne 3 ]] || ! grep -F -q "cannot write" "$scratch/write-failure.err"; then
    cat "$scratch/write-failure.err" >&2
    echo "error: write failure did not return class 3" >&2
    exit 1
  fi
  test ! -e "$scratch/missing-parent/output.json"
fi

"$TSX" "$LOOM_ROOT/parity/loom-diff.ts" pi "$scratch/pi" --ts-parity
"$TSX" "$LOOM_ROOT/parity/loom-diff.ts" claude "$scratch/claude" --ts-parity
"$TSX" "$LOOM_ROOT/parity/loom-diff.ts" codex "$scratch/codex" --ts-parity
"$TSX" "$LOOM_ROOT/parity/loom-diff.ts" cursor-agent "$scratch/cursor-agent" --ts-parity

echo "== loom-diff Claude Loom-richer empty-entry gate =="
mkdir -p "$scratch/claude-rich"
cat > "$scratch/claude-rich/image-only.jsonl" <<'EOF'
{"type":"user","uuid":"64000000-0000-4000-8000-000000000001","parentUuid":null,"sessionId":"64000000-0000-4000-8000-000000000000","cwd":"/tmp/loom-rich","timestamp":"2026-07-08T00:00:00.000Z","isSidechain":false,"message":{"role":"user","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"abc"}}]}}
{"type":"assistant","uuid":"64000000-0000-4000-8000-000000000002","parentUuid":"64000000-0000-4000-8000-000000000001","sessionId":"64000000-0000-4000-8000-000000000000","cwd":"/tmp/loom-rich","timestamp":"2026-07-08T00:00:01.000Z","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"after image"}]}}
{"type":"user","uuid":"64000000-0000-4000-8000-000000000003","parentUuid":"64000000-0000-4000-8000-000000000002","sessionId":"64000000-0000-4000-8000-000000000000","cwd":"/tmp/loom-rich","timestamp":"2026-07-08T00:00:02.000Z","isSidechain":false,"message":{"role":"user","content":[{"type":"document","source":{"type":"base64","media_type":"application/pdf","data":"abc"}}]}}
{"type":"assistant","uuid":"64000000-0000-4000-8000-000000000004","parentUuid":"64000000-0000-4000-8000-000000000003","sessionId":"64000000-0000-4000-8000-000000000000","cwd":"/tmp/loom-rich","timestamp":"2026-07-08T00:00:03.000Z","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"after document"}]}}
EOF
"$TSX" "$LOOM_ROOT/parity/loom-diff.ts" claude "$scratch/claude-rich" --ts-parity

echo "== loom-diff TS-only error gate =="
mkdir -p "$scratch/codex-ts-error"
cat > "$scratch/codex-ts-error/empty.jsonl" <<'EOF'
{"type":"session_meta","timestamp":"2026-07-06T00:00:00.000Z","payload":{"id":"empty-rollout","timestamp":"2026-07-06T00:00:00.000Z","cwd":"/tmp/empty"}}
EOF
"$TSX" "$LOOM_ROOT/parity/loom-diff.ts" codex "$scratch/codex-ts-error" --ts-parity --allow-ts-errors
if "$TSX" "$LOOM_ROOT/parity/loom-diff.ts" codex "$scratch/codex-ts-error" --ts-parity \
    >"$scratch/codex-ts-error-noallow.out" 2>"$scratch/codex-ts-error-noallow.err"; then
  echo "error: loom-diff accepted TS-only errors without --allow-ts-errors" >&2
  exit 1
fi

echo "== cursor-agent subagent flat-export scope =="
mkdir -p "$scratch/cursor-agent-subagents/subagents"
cat > "$scratch/cursor-agent-subagents/root.jsonl" <<'EOF'
{"role":"user","message":{"content":[{"type":"text","text":"go"}]}}
{"role":"assistant","message":{"content":[{"type":"tool_use","name":"Task","input":{}}]}}
EOF
cat > "$scratch/cursor-agent-subagents/subagents/child-a.jsonl" <<'EOF'
{"role":"user","message":{"content":[{"type":"text","text":"child"}]}}
{"role":"assistant","message":{"content":[{"type":"text","text":"done"}]}}
EOF
for to in pi codex; do
  expect_sidechain_flat_refusal \
    "cursor-agent-subagents-to-$to" cursor-agent "$to" \
    "$scratch/cursor-agent-subagents/root.jsonl" --with-subagents
done
(cd "$LOOM_ROOT" && lake exe loom convert cursor-agent loom \
  "$scratch/cursor-agent-subagents/root.jsonl" "$scratch/cursor-agent-subagents.loom.json" --with-subagents)
node -e '
const { readFileSync } = require("node:fs");
const j = JSON.parse(readFileSync(process.argv[1], "utf8"));
if (j.schema !== "loom.transcript.v0") throw new Error(`bad schema: ${j.schema}`);
if (!Array.isArray(j.threads) || j.threads.length !== 2) {
  throw new Error(`expected 2 threads, got ${j.threads && j.threads.length}`);
}
if (!j.threads.some(t => t.kind && t.kind.kind === "sidechain")) {
  throw new Error("sidechain thread not preserved in loom wire export");
}
' "$scratch/cursor-agent-subagents.loom.json"

echo "== loom wire round-trip gate =="
(cd "$LOOM_ROOT" && lake exe loom convert loom loom \
  testdata/wire/sidechain-detached.v0.json "$scratch/wire.roundtrip.json")
node -e '
const { readFileSync } = require("node:fs");
const j = JSON.parse(readFileSync(process.argv[1], "utf8"));
if (j.schema !== "loom.transcript.v0") throw new Error(`bad schema: ${j.schema}`);
if (!Array.isArray(j.threads) || j.threads.length !== 3) {
  throw new Error(`expected 3 threads, got ${j.threads && j.threads.length}`);
}
const side = j.threads.find(t => t.kind && t.kind.kind === "sidechain");
const detached = j.threads.find(t => t.kind && t.kind.kind === "detached");
if (!side) throw new Error("sidechain thread lost in loom wire round-trip");
if (!detached) throw new Error("detached thread lost in loom wire round-trip");
if (!side.kind.anchor || side.kind.anchor.kind !== "resolved" ||
    side.kind.anchor.entry !== "1" || side.kind.anchor.block !== "1") {
  throw new Error(`sidechain anchor changed: ${JSON.stringify(side.kind.anchor)}`);
}
if (detached.kind.note !== "toolUseId=missing unmatched") {
  throw new Error(`detached note changed: ${detached.kind.note}`);
}
const threadIds = new Set(j.entries.map(e => e.thread));
if (!threadIds.has("1") || !threadIds.has("2")) {
  throw new Error(`child entry thread indexes lost: ${JSON.stringify([...threadIds])}`);
}
if (j.activeLeaf !== "3") throw new Error(`activeLeaf changed: ${j.activeLeaf}`);
' "$scratch/wire.roundtrip.json"

echo "== loom wire to native sidecar export gates =="
printf 'prior-main-must-survive\n' >"$scratch/sidecar-unowned-guard.jsonl"
mkdir -p "$scratch/sidecar-unowned-guard/subagents"
printf 'prior-sidecar-must-survive\n' \
  >"$scratch/sidecar-unowned-guard/subagents/prior.txt"
if (cd "$LOOM_ROOT" && lake exe loom convert loom claude \
  testdata/wire/sidechain-detached.v0.json \
  "$scratch/sidecar-unowned-guard.jsonl" --with-subagents \
  --target-cwd /tmp/loom-sidecar-unowned \
  --target-harness-version 2.1.216 \
  --target-session-id 67000000-0000-4000-8000-000000000000 \
  --target-timestamp 2026-07-20T02:00:00.000Z \
  >"$scratch/sidecar-unowned-guard.stdout" \
  2>"$scratch/sidecar-unowned-guard.err"); then
  echo "error: unowned sidecar entry unexpectedly succeeded" >&2
  exit 1
else
  status=$?
  if [[ "$status" -ne 3 ]] || ! grep -F -q "contains unowned entries" \
      "$scratch/sidecar-unowned-guard.err"; then
    cat "$scratch/sidecar-unowned-guard.err" >&2
    echo "error: unowned sidecar entry did not return export class 3" >&2
    exit 1
  fi
  test "$(cat "$scratch/sidecar-unowned-guard.jsonl")" = \
    "prior-main-must-survive"
  test "$(cat "$scratch/sidecar-unowned-guard/subagents/prior.txt")" = \
    "prior-sidecar-must-survive"
  test ! -e "$scratch/sidecar-unowned-guard.jsonl.agent-convert-stage"
fi

printf 'prior-main-must-survive\n' >"$scratch/sidecar-stage-guard.jsonl"
printf 'reserved-main-stage-must-survive\n' \
  >"$scratch/sidecar-stage-guard.jsonl.agent-convert-stage"
if (cd "$LOOM_ROOT" && lake exe loom convert loom claude \
  testdata/wire/sidechain-detached.v0.json \
  "$scratch/sidecar-stage-guard.jsonl" --with-subagents \
  --target-cwd /tmp/loom-sidecar-stage \
  --target-harness-version 2.1.216 \
  --target-session-id 67000000-0000-4000-8000-000000000000 \
    --target-timestamp 2026-07-20T02:00:00.000Z \
    >"$scratch/sidecar-stage-guard.stdout" \
    2>"$scratch/sidecar-stage-guard.err"); then
  echo "error: occupied sidecar staging path unexpectedly succeeded" >&2
  exit 1
else
  status=$?
  if [[ "$status" -ne 3 ]] || ! grep -F -q \
      "stale converter stage/backup state exists" \
      "$scratch/sidecar-stage-guard.err"; then
    cat "$scratch/sidecar-stage-guard.err" >&2
    echo "error: occupied sidecar staging path did not return export class 3" >&2
    exit 1
  fi
  test "$(cat "$scratch/sidecar-stage-guard.jsonl")" = \
    "prior-main-must-survive"
  test "$(cat "$scratch/sidecar-stage-guard.jsonl.agent-convert-stage")" = \
    "reserved-main-stage-must-survive"
fi

(cd "$LOOM_ROOT" && lake exe loom convert loom claude \
  testdata/wire/sidechain-detached.v0.json "$scratch/wire-to-claude.jsonl" \
  --with-subagents --target-cwd /tmp/loom-wire-to-claude \
  --target-harness-version 2.1.216 \
  --target-session-id 67000000-0000-4000-8000-000000000000 \
  --target-timestamp 2026-07-20T02:00:00.000Z --json) \
  >"$scratch/wire-to-claude.summary.json"
test -s "$scratch/wire-to-claude.jsonl"
test -s "$scratch/wire-to-claude/subagents/agent-0001.jsonl"
test -s "$scratch/wire-to-claude/subagents/agent-0001.meta.json"
test -s "$scratch/wire-to-claude/subagents/agent-0002.jsonl"
test -s "$scratch/wire-to-claude/subagents/agent-0002.meta.json"
node -e '
const { readFileSync } = require("node:fs");
const meta1 = JSON.parse(readFileSync(process.argv[1], "utf8"));
const meta2 = JSON.parse(readFileSync(process.argv[2], "utf8"));
const rows = readFileSync(process.argv[3], "utf8").trimEnd().split("\n").map(JSON.parse);
const summary = JSON.parse(readFileSync(process.argv[4], "utf8"));
const anchor = meta1._agentConvert;
if (anchor?.anchorEntry !== "1" || anchor.anchorBlock !== "1" ||
    anchor.anchorEncoding !== "historical-carrier" || "toolUseId" in meta1) {
  throw new Error(`Claude metadata claimed a native or misplaced anchor: ${JSON.stringify(meta1)}`);
}
if ("toolUseId" in meta2 || meta2.detached !== true) throw new Error(`detached Claude meta changed: ${JSON.stringify(meta2)}`);
const anchorRow = rows.find(row =>
  row._agent_convert?.identityProvenance?.sourceEntryId === "a1");
const carrier = anchorRow?._agent_convert?.inertPayload;
const blocks = carrier?.payload?.blocks;
const toolCall = blocks?.[1];
if (anchorRow?.type !== "system" || anchorRow?.subtype !== "agent_convert_inert" ||
    carrier?.carrier !== "agent-convert.claude-inert-payload.v1" ||
    carrier?.payload?.kind !== "assistantMsg" ||
    blocks?.[0]?.kind !== "text" || blocks[0].text !== "dispatch" ||
    toolCall?.kind !== "toolCall" || toolCall.rawId !== "toolu_child" ||
    rows.some(row => row.message?.content?.some?.(item => item.type === "tool_use"))) {
  throw new Error(`Claude root anchor is not an inert carrier at 1:1: ${JSON.stringify(anchorRow)}`);
}
for (const [key, value] of Object.entries({
  toolCallsImported: 1,
  openToolCallsImported: 1,
  toolCallsCarriedAsHistory: 1,
  toolCallsEmittedNative: 0,
  openToolCallsEmittedNative: 0,
})) {
  if (summary[key] !== value) throw new Error(`${key}: ${summary[key]} !== ${value}`);
}
' "$scratch/wire-to-claude/subagents/agent-0001.meta.json" \
  "$scratch/wire-to-claude/subagents/agent-0002.meta.json" \
  "$scratch/wire-to-claude.jsonl" "$scratch/wire-to-claude.summary.json"
(cd "$LOOM_ROOT" && lake exe loom convert claude loom \
  "$scratch/wire-to-claude.jsonl" "$scratch/wire-to-claude.reimport.json" --with-subagents)
node -e '
const { readFileSync } = require("node:fs");
const j = JSON.parse(readFileSync(process.argv[1], "utf8"));
if (!Array.isArray(j.threads) || j.threads.length !== 3) {
  throw new Error(`expected 3 Claude reimport threads, got ${j.threads && j.threads.length}`);
}
const side = j.threads.find(t => t.kind && t.kind.kind === "sidechain");
const detached = j.threads.find(t => t.kind && t.kind.kind === "detached");
if (!side) throw new Error("Claude sidecar reimport lost sidechain thread");
if (!detached) throw new Error("Claude sidecar reimport lost detached thread");
if (!side.kind.anchor || side.kind.anchor.kind !== "resolved" ||
    side.kind.anchor.entry !== "1" || side.kind.anchor.block !== "1") {
  throw new Error(`Claude sidecar anchor changed: ${JSON.stringify(side.kind.anchor)}`);
}
' "$scratch/wire-to-claude.reimport.json"

# Since a0072e79 this export is REACHABLE rather than refused: cursor-agent has
# no slot for source identity, environment, or time provenance, so those losses
# are forced by the target rather than chosen by the exporter and are rated
# `reportOnly`. The gate therefore moved from "must refuse" to "must disclose" —
# the defect this guards against is now a SILENT loss, not a permitted one.
# Its own output directory: a shared one would let these sidecars satisfy the
# `$scratch/subagents/...` assertions made for the next conversion.
mkdir -p "$scratch/wire-to-cursor-disclosure"
(cd "$LOOM_ROOT" && lake exe loom convert loom cursor-agent \
  testdata/wire/sidechain-detached.v0.json \
  "$scratch/wire-to-cursor-disclosure/root.jsonl" --with-subagents --json) \
  >"$scratch/wire-to-cursor-disclosure.summary.json"
test -s "$scratch/wire-to-cursor-disclosure/root.jsonl"
test -s "$scratch/wire-to-cursor-disclosure/subagents/child-0001.jsonl"
test -s "$scratch/wire-to-cursor-disclosure/subagents/child-0002.jsonl"
test ! -e "$scratch/wire-to-cursor-disclosure/root.jsonl.agent-convert-stage"
node -e '
const { readFileSync } = require("node:fs");
const summary = JSON.parse(readFileSync(process.argv[1], "utf8"));
const obligations = summary.exportObligations;
if (!Array.isArray(obligations) ||
    summary.exportObligationCount !== obligations.length ||
    obligations.some(item => typeof item?.kind !== "string" ||
      !["fulfillment", "reportOnly", "destructive"].includes(item?.impact))) {
  throw new Error(`invalid export obligation report: ${JSON.stringify(summary)}`);
}
const impact = (kind) => obligations.filter(item => item.kind === kind);
// Every fact cursor-agent structurally cannot hold must appear in the report,
// and must appear as a target limitation rather than an exporter choice.
const forced = ["dropSourceIdentity", "dropTimeProvenance"];
for (const kind of forced) {
  const rows = impact(kind);
  if (rows.length !== 1 || rows[0].impact !== "reportOnly") {
    throw new Error(`${kind} was not disclosed as a forced target limitation: ${JSON.stringify(obligations)}`);
  }
}
const environment = impact("dropEnvironment");
if (environment.length !== 1 || environment[0].impact !== "reportOnly" ||
    JSON.stringify(environment[0].fields) !== JSON.stringify(["cwd", "model"])) {
  throw new Error(`environment loss was not disclosed field-by-field: ${JSON.stringify(obligations)}`);
}
' "$scratch/wire-to-cursor-disclosure.summary.json"

# Cursor Agent has no source-identity, environment, or time-provenance carrier.
# Derive a fixture that removes only those unrepresentable facts while retaining
# the full thread/content/linkage projection exercised below.
cursor_representable_wire() {
  node -e '
const { readFileSync, writeFileSync } = require("node:fs");
const wire = JSON.parse(readFileSync(process.argv[1], "utf8"));
wire.env = {};
delete wire.origin.rawId;
for (const entry of wire.entries) {
  delete entry.origin.rawId;
  entry.time = { kind: "absent" };
}
writeFileSync(process.argv[2], JSON.stringify(wire));
' "$1" "$2"
}
cursor_representable_wire \
  "$LOOM_ROOT/testdata/wire/sidechain-detached.v0.json" \
  "$scratch/wire-to-cursor-compatible.json"
(cd "$LOOM_ROOT" && lake exe loom convert loom cursor-agent \
  "$scratch/wire-to-cursor-compatible.json" \
  "$scratch/wire-to-cursor.jsonl" --with-subagents)
test -s "$scratch/wire-to-cursor.jsonl"
test -s "$scratch/subagents/child-0001.jsonl"
test -s "$scratch/subagents/child-0002.jsonl"
(cd "$LOOM_ROOT" && lake exe loom convert cursor-agent loom \
  "$scratch/wire-to-cursor.jsonl" "$scratch/wire-to-cursor.reimport.json" --with-subagents)
node -e '
const { readFileSync } = require("node:fs");
const j = JSON.parse(readFileSync(process.argv[1], "utf8"));
if (!Array.isArray(j.threads) || j.threads.length !== 3) {
  throw new Error(`expected 3 cursor-agent reimport threads, got ${j.threads && j.threads.length}`);
}
if (!j.threads.some(t => t.kind && t.kind.kind === "sidechain")) {
  throw new Error("cursor-agent sidecar reimport lost sidechain thread");
}
if (!j.threads.some(t => t.kind && t.kind.kind === "detached")) {
  throw new Error("cursor-agent sidecar reimport lost detached thread");
}
' "$scratch/wire-to-cursor.reimport.json"

node -e '
const { readFileSync } = require("node:fs");
const { isDeepStrictEqual } = require("node:util");
const [source, ...targets] = process.argv.slice(1).map(path =>
  JSON.parse(readFileSync(path, "utf8")));

function payloadProjection(payload) {
  const value = structuredClone(payload);
  if (value.type === "assistantMsg" && Array.isArray(value.blocks)) {
    for (const block of value.blocks) {
      if (block.type === "toolCall") delete block.canonical;
    }
  }
  return value;
}

function activeProjection(transcript) {
  if (transcript.activeLeaf === undefined) return null;
  const global = Number(transcript.activeLeaf);
  const entry = transcript.entries[global];
  if (!entry) throw new Error(`activeLeaf ${transcript.activeLeaf} is absent`);
  const locals = transcript.entries.filter(candidate => candidate.thread === entry.thread);
  const local = locals.findIndex(candidate => candidate.index === entry.index);
  return { thread: entry.thread, local };
}

function projection(transcript) {
  return {
    threads: transcript.threads.map((thread, threadIndex) => {
      const entries = transcript.entries.filter(entry => Number(entry.thread) === threadIndex);
      const localByGlobal = new Map(entries.map((entry, index) => [entry.index, index]));
      return {
        kind: thread.kind,
        label: threadIndex === 0 ? null : (thread.label ?? null),
        entries: entries.map(entry => ({
          parent: entry.parent === undefined ? null : localByGlobal.get(entry.parent),
          payload: payloadProjection(entry.payload),
        })),
      };
    }),
    active: activeProjection(transcript),
  };
}

const expected = projection(source);
for (const [index, target] of targets.entries()) {
  const actual = projection(target);
  if (!isDeepStrictEqual(actual, expected)) {
    throw new Error(`sidecar target ${index} changed thread disposition, content, linkage, or active path\n` +
      `expected=${JSON.stringify(expected)}\nactual=${JSON.stringify(actual)}`);
  }
}
' "$LOOM_ROOT/testdata/wire/sidechain-detached.v0.json" \
  "$scratch/wire-to-claude.reimport.json" \
  "$scratch/wire-to-cursor.reimport.json"

echo "== interleaved sidecar anchor projection gate =="
(cd "$LOOM_ROOT" && lake exe loom convert loom claude \
  testdata/wire/sidechain-interleaved.v0.json \
  "$scratch/interleaved-claude/root.jsonl" --with-subagents \
  --target-cwd /tmp/loom-interleaved-claude \
  --target-harness-version 2.1.216 \
  --target-session-id 68000000-0000-4000-8000-000000000000 \
  --target-timestamp 2026-07-20T03:00:00.000Z --json) \
  >"$scratch/interleaved-claude.summary.json"
(cd "$LOOM_ROOT" && lake exe loom convert claude loom \
  "$scratch/interleaved-claude/root.jsonl" \
  "$scratch/interleaved-claude.reimport.json" --with-subagents)
cursor_representable_wire \
  "$LOOM_ROOT/testdata/wire/sidechain-interleaved.v0.json" \
  "$scratch/interleaved-cursor-compatible.json"
(cd "$LOOM_ROOT" && lake exe loom convert loom cursor-agent \
  "$scratch/interleaved-cursor-compatible.json" \
  "$scratch/interleaved-cursor/root.jsonl" --with-subagents)
(cd "$LOOM_ROOT" && lake exe loom convert cursor-agent loom \
  "$scratch/interleaved-cursor/root.jsonl" \
  "$scratch/interleaved-cursor.reimport.json" --with-subagents)
node -e '
const { readFileSync } = require("node:fs");
const claudeMeta = JSON.parse(readFileSync(process.argv[1], "utf8"));
const cursorMeta = JSON.parse(readFileSync(process.argv[2], "utf8"));
const rootRows = readFileSync(process.argv[3], "utf8").trimEnd().split("\n").map(JSON.parse);
const summary = JSON.parse(readFileSync(process.argv[4], "utf8"));
const targets = process.argv.slice(5).map(path => JSON.parse(readFileSync(path, "utf8")));
for (const [name, meta] of [["Claude", claudeMeta], ["Cursor", cursorMeta]]) {
  if (meta._agentConvert?.anchorEntry !== "1" ||
      meta._agentConvert?.anchorBlock !== "0") {
    throw new Error(`${name} metadata used a global rather than projected anchor: ${JSON.stringify(meta)}`);
  }
}
if (claudeMeta._agentConvert.anchorEncoding !== "historical-carrier" ||
    "toolUseId" in claudeMeta) {
  throw new Error(`Claude interleaved metadata claimed a native anchor: ${JSON.stringify(claudeMeta)}`);
}
const rootCall = rootRows.filter(row => row.type === "user" || row.type === "assistant")[1];
const callText = rootCall?.message?.content?.[0]?.text;
const header = "[Historical tool call from source transcript; not executed by Claude]\n";
if (rootCall?.message?.content?.[0]?.type !== "text" || !callText?.startsWith(header) ||
    rootRows.some(row => row.message?.content?.some?.(item => item.type === "tool_use"))) {
  throw new Error(`Claude projected root call is not physically inert: ${JSON.stringify(rootCall)}`);
}
const carrier = JSON.parse(callText.slice(header.length));
if (carrier.occurrence !== "1:0" || carrier.id !== "toolu_interleaved") {
  throw new Error(`Claude root carrier disagrees with projected metadata: ${JSON.stringify(carrier)}`);
}
for (const [key, value] of Object.entries({
  toolCallsImported: 1,
  openToolCallsImported: 1,
  toolCallsCarriedAsHistory: 1,
  toolCallsEmittedNative: 0,
  openToolCallsEmittedNative: 0,
})) {
  if (summary[key] !== value) throw new Error(`${key}: ${summary[key]} !== ${value}`);
}
for (const target of targets) {
  const side = target.threads.find(thread => thread.kind?.kind === "sidechain");
  if (side?.kind?.anchor?.entry !== "1" || side.kind.anchor.block !== "0") {
    throw new Error(`reimport did not resolve projected main anchor: ${JSON.stringify(side)}`);
  }
  const call = target.entries.find(entry => entry.index === "1" && entry.thread === "0");
  if (call?.payload?.blocks?.[0]?.type !== "toolCall" ||
      call.payload.blocks[0].id !== "toolu_interleaved") {
    throw new Error(`projected anchor does not name the source tool call: ${JSON.stringify(call)}`);
  }
  const active = target.entries.find(entry => entry.index === target.activeLeaf);
  if (active?.thread !== "1") {
    throw new Error(`child active path was not restored: ${JSON.stringify(target.activeLeaf)}`);
  }
}
' \
  "$scratch/interleaved-claude/root/subagents/agent-0001.meta.json" \
  "$scratch/interleaved-cursor/subagents/child-0001.meta.json" \
  "$scratch/interleaved-claude/root.jsonl" \
  "$scratch/interleaved-claude.summary.json" \
  "$scratch/interleaved-claude.reimport.json" \
  "$scratch/interleaved-cursor.reimport.json"

echo "== interleaved historical child lifecycle projection gate =="
node -e '
const { readFileSync, writeFileSync } = require("node:fs");
const source = JSON.parse(readFileSync(process.argv[1], "utf8"));
const callHeader = "[Historical tool call from source transcript; not executed by Claude]\n";
const resultHeader = "[Historical tool result from source transcript; not executed by Claude]\n";
const callText = callHeader + JSON.stringify({
  carrier: "agent-convert.claude-tool-call.v1",
  id: "child-call",
  name: "child_tool",
  canonical: null,
  arguments: { path: "/tmp/child" },
  reason: "historical source lifecycle",
  occurrence: "3:0",
});
const resultText = resultHeader + JSON.stringify({
  carrier: "agent-convert.claude-tool-result.v1",
  occurrence: "5:0",
  id: "child-call",
  call: { kind: "resolved", occurrence: "3:0", rawId: "child-call" },
  content: [{ kind: "text", text: "child result" }],
  error: { kind: "native", isError: false },
});
const carrierOrigin = rawId => ({
  format: "claude",
  sourceRef: "interleaved-child-carrier",
  rawId,
  extras: {
    claudeCarrierBlocks: [0],
    claudeCarrierDisposition: "agent-convert-historical-unverified",
  },
});
source.entries[3] = {
  index: "3",
  thread: "1",
  time: { kind: "absent" },
  payload: { type: "assistantMsg", blocks: [{ type: "text", text: callText }] },
  origin: carrierOrigin("child-call-entry"),
  disposition: "historicalUnverified",
  parent: "1",
};
source.entries.push({
  index: "4",
  thread: "0",
  time: { kind: "absent" },
  payload: { type: "userMsg", blocks: [{ type: "text", text: "root waits" }] },
  origin: { format: "claude", sourceRef: "interleaved-child-carrier", rawId: "root-waits" },
  parent: "2",
});
source.entries.push({
  index: "5",
  thread: "1",
  time: { kind: "absent" },
  payload: { type: "userMsg", blocks: [{ type: "text", text: resultText }] },
  origin: carrierOrigin("child-result-entry"),
  disposition: "historicalUnverified",
  parent: "3",
});
source.activeLeaf = "5";
writeFileSync(process.argv[2], JSON.stringify(source) + "\n");
' "$LOOM_ROOT/testdata/wire/sidechain-interleaved.v0.json" \
  "$scratch/interleaved-child-carriers.v0.json"
(cd "$LOOM_ROOT" && lake exe loom convert loom claude \
  "$scratch/interleaved-child-carriers.v0.json" \
  "$scratch/interleaved-child/root.jsonl" --with-subagents \
  --target-cwd /tmp/loom-interleaved-child \
  --target-harness-version 2.1.216 \
  --target-session-id 68100000-0000-4000-8000-000000000000 \
  --target-timestamp 2026-07-20T03:01:00.000Z --json) \
  >"$scratch/interleaved-child.summary.json"
(cd "$LOOM_ROOT" && lake exe loom convert claude loom \
  "$scratch/interleaved-child/root.jsonl" \
  "$scratch/interleaved-child.reimport.json" --with-subagents)
node -e '
const { readFileSync } = require("node:fs");
const rows = readFileSync(process.argv[1], "utf8").trimEnd().split("\n").map(JSON.parse);
const meta = JSON.parse(readFileSync(process.argv[2], "utf8"));
const restored = JSON.parse(readFileSync(process.argv[3], "utf8"));
const conversation = rows.filter(row => row.type === "user" || row.type === "assistant");
const callBlock = conversation[1]?.message?.content?.[0];
const resultBlock = conversation[2]?.message?.content?.[0];
const callHeader = "[Historical tool call from source transcript; not executed by Claude]\n";
const resultHeader = "[Historical tool result from source transcript; not executed by Claude]\n";
if (callBlock?.type !== "text" || !callBlock.text.startsWith(callHeader) ||
    resultBlock?.type !== "text" || !resultBlock.text.startsWith(resultHeader)) {
  throw new Error("projected child artifact lost its inert historical carriers");
}
const callCarrier = JSON.parse(callBlock.text.slice(callHeader.length));
const resultCarrier = JSON.parse(resultBlock.text.slice(resultHeader.length));
if (callCarrier.occurrence !== "1:0" || resultCarrier.occurrence !== "2:0" ||
    resultCarrier.call?.kind !== "resolved" || resultCarrier.call.occurrence !== "1:0") {
  throw new Error(`child carrier coordinates were not projected: ${JSON.stringify({ callCarrier, resultCarrier })}`);
}
if (meta._agentConvert?.anchorEntry !== "1" || meta._agentConvert?.anchorBlock !== "0" ||
    meta._agentConvert?.anchorEncoding !== "historical-carrier" || "toolUseId" in meta) {
  throw new Error(`child metadata disagrees with the inert root anchor: ${JSON.stringify(meta)}`);
}
const childThread = restored.threads.findIndex(thread => thread.kind?.kind === "sidechain");
const childEntries = restored.entries.filter(entry => entry.thread === String(childThread));
const callEntry = childEntries[1];
const resultEntry = childEntries[2];
const typedCall = callEntry?.payload?.blocks?.[0];
const typedResult = resultEntry?.payload?.blocks?.[0];
if (childEntries.length !== 3 || callEntry.disposition !== "historicalUnverified" ||
    resultEntry.disposition !== "historicalUnverified" ||
    typedCall?.type !== "toolCall" || typedCall.id !== "child-call" ||
    typedResult?.type !== "toolResult" || typedResult.call?.kind !== "resolved" ||
    typedResult.call.entry !== callEntry.index || typedResult.call.block !== "0" ||
    typedResult.content?.[0]?.text !== "child result" ||
    resultEntry.parent !== callEntry.index || restored.activeLeaf !== resultEntry.index) {
  throw new Error(`child reimport lost typed lifecycle/linkage/disposition: ${JSON.stringify(childEntries)}`);
}
' "$scratch/interleaved-child/root/subagents/agent-0001.jsonl" \
  "$scratch/interleaved-child/root/subagents/agent-0001.meta.json" \
  "$scratch/interleaved-child.reimport.json"

echo "== unmarked interleaved carrier-looking text projection gate =="
node -e '
const { readFileSync, writeFileSync } = require("node:fs");
const source = JSON.parse(readFileSync(process.argv[1], "utf8"));
const ordinaryText = "[Historical tool call from source transcript; not executed by Claude]\n" +
  "{ \"occurrence\": \"3:0\", \"reason\": \"ordinary literal\", " +
  "\"arguments\": {\"z\":1}, \"canonical\": null, \"name\": \"literal_tool\", " +
  "\"id\": \"literal-call\", \"carrier\": \"agent-convert.claude-tool-call.v1\" }";
source.entries[3] = {
  index: "3",
  thread: "1",
  time: { kind: "absent" },
  payload: { type: "assistantMsg", blocks: [{ type: "text", text: ordinaryText }] },
  origin: { format: "claude", sourceRef: "ordinary-carrier-collision", rawId: "ordinary-carrier" },
  parent: "1",
};
source.activeLeaf = "3";
writeFileSync(process.argv[2], JSON.stringify(source) + "\n");
' "$LOOM_ROOT/testdata/wire/sidechain-interleaved.v0.json" \
  "$scratch/interleaved-ordinary-carrier.v0.json"
(cd "$LOOM_ROOT" && lake exe loom convert loom claude \
  "$scratch/interleaved-ordinary-carrier.v0.json" \
  "$scratch/interleaved-ordinary/root.jsonl" --with-subagents \
  --target-cwd /tmp/loom-interleaved-ordinary \
  --target-harness-version 2.1.216 \
  --target-session-id 68200000-0000-4000-8000-000000000000 \
  --target-timestamp 2026-07-20T03:02:00.000Z >/dev/null)
(cd "$LOOM_ROOT" && lake exe loom convert claude loom \
  "$scratch/interleaved-ordinary/root.jsonl" \
  "$scratch/interleaved-ordinary.reimport.json" --with-subagents >/dev/null)
node -e '
const { readFileSync } = require("node:fs");
const source = JSON.parse(readFileSync(process.argv[1], "utf8"));
const rows = readFileSync(process.argv[2], "utf8").trimEnd().split("\n").map(JSON.parse);
const restored = JSON.parse(readFileSync(process.argv[3], "utf8"));
const expected = source.entries[3].payload.blocks[0].text;
const assistant = rows.filter(row => row.type === "user" || row.type === "assistant")[1];
const actual = assistant?.message?.content?.[0]?.text;
if (actual !== expected || assistant?._agent_convert?.contentBlocks !== undefined ||
    !actual.includes("\"occurrence\": \"3:0\"")) {
  throw new Error(`unmarked carrier-looking text was rewritten or claimed: ${JSON.stringify(assistant)}`);
}
const childThread = restored.threads.findIndex(thread => thread.kind?.kind === "sidechain");
const childEntries = restored.entries.filter(entry => entry.thread === String(childThread));
const restoredBlock = childEntries[1]?.payload?.blocks?.[0];
if (restoredBlock?.type !== "text" || restoredBlock.text !== expected) {
  throw new Error(`unmarked carrier-looking text reimported as controlled history: ${JSON.stringify(childEntries)}`);
}
' "$scratch/interleaved-ordinary-carrier.v0.json" \
  "$scratch/interleaved-ordinary/root/subagents/agent-0001.jsonl" \
  "$scratch/interleaved-ordinary.reimport.json"

echo "== loom wire compatibility and negative gates =="
expect_loom_wire_reject \
  "wire-wrong-schema" \
  testdata/wire/reject/wrong-schema.v0.json \
  "unsupported schema"
expect_loom_wire_reject \
  "wire-missing-required" \
  testdata/wire/reject/missing-required-field.v0.json \
  "missing required field 'entries'"
node "$LOOM_ROOT/scripts/test-wire-required.mjs" \
  "$LOOM_BIN" "$scratch/wire-required-mutations"

(cd "$LOOM_ROOT" && lake exe loom convert loom loom \
  testdata/wire/accept/json-number-indexes.v0.json "$scratch/wire.number-indexes.json")
node -e '
const { readFileSync } = require("node:fs");
const j = JSON.parse(readFileSync(process.argv[1], "utf8"));
if (j.schema !== "loom.transcript.v0") throw new Error(`bad schema: ${j.schema}`);
if (j.threads[0].index !== "0") throw new Error(`thread index was not normalized to string: ${j.threads[0].index}`);
if (j.entries[0].index !== "0" || j.entries[0].thread !== "0" || j.entries[0].time.ord !== "0") {
  throw new Error(`entry 0 numeric fields changed unexpectedly: ${JSON.stringify(j.entries[0])}`);
}
if (j.entries[1].index !== "1" || j.entries[1].parent !== "0" ||
    j.entries[1].thread !== "0" || j.entries[1].time.ord !== "1") {
  throw new Error(`entry 1 numeric fields changed unexpectedly: ${JSON.stringify(j.entries[1])}`);
}
if (j.activeLeaf !== "1") throw new Error(`activeLeaf was not normalized to string: ${j.activeLeaf}`);
' "$scratch/wire.number-indexes.json"

(cd "$LOOM_ROOT" && lake exe loom convert loom loom \
  testdata/wire/accept/unknown-additive-labels.v0.json "$scratch/wire.unknown-labels.json")
node -e '
const { readFileSync } = require("node:fs");
const j = JSON.parse(readFileSync(process.argv[1], "utf8"));
if (Object.prototype.hasOwnProperty.call(j, "x-top-level")) {
  throw new Error("top-level additive field was not ignored");
}
if (Object.prototype.hasOwnProperty.call(j.env, "x-env")) {
  throw new Error("env additive field was not ignored");
}
if (j.origin.format !== "future-format") {
  throw new Error(`unknown origin format did not survive: ${j.origin.format}`);
}
if (!Array.isArray(j.importNotes) || j.importNotes[0].kind !== "futureAssumption") {
  throw new Error(`unknown import note kind did not survive: ${JSON.stringify(j.importNotes)}`);
}
const userBlock = j.entries[0].payload.blocks[0];
if (userBlock.type !== "unmodeled" || userBlock.label !== "futureUserBlock" ||
    userBlock.raw.type !== "futureUserBlock" || userBlock.raw.future !== "kept as raw") {
  throw new Error(`unknown user block was not preserved as unmodeled raw: ${JSON.stringify(userBlock)}`);
}
const assistantBlock = j.entries[1].payload.blocks[0];
if (assistantBlock.type !== "unmodeled" || assistantBlock.label !== "futureAssistantBlock" ||
    assistantBlock.raw.type !== "futureAssistantBlock" || !assistantBlock.raw.nested.ok) {
  throw new Error(`unknown assistant block was not preserved as unmodeled raw: ${JSON.stringify(assistantBlock)}`);
}
const event = j.entries[2].payload.event;
if (event.type !== "custom" || event.label !== "futureEvent" || !event.raw.payload.ok) {
  throw new Error(`unknown event label was not preserved as custom raw: ${JSON.stringify(event)}`);
}
' "$scratch/wire.unknown-labels.json"

echo "== claude subagent flat-export scope =="
mkdir -p "$scratch/claude-subagents/root/subagents"
cat > "$scratch/claude-subagents/root.jsonl" <<'EOF'
{"type":"user","uuid":"65000000-0000-4000-8000-000000000001","parentUuid":null,"sessionId":"65000000-0000-4000-8000-000000000000","cwd":"/tmp/loom-claude-sub","timestamp":"2026-07-08T00:00:00.000Z","isSidechain":false,"message":{"role":"user","content":"go"}}
{"type":"assistant","uuid":"65000000-0000-4000-8000-000000000002","parentUuid":"65000000-0000-4000-8000-000000000001","sessionId":"65000000-0000-4000-8000-000000000000","cwd":"/tmp/loom-claude-sub","timestamp":"2026-07-08T00:00:01.000Z","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"dispatching"},{"type":"tool_use","id":"toolu_sub_1","name":"Agent","input":{"prompt":"child"}}]}}
EOF
cat > "$scratch/claude-subagents/root/subagents/agent-a.jsonl" <<'EOF'
{"type":"user","uuid":"65000000-0000-4000-8000-000000000003","parentUuid":null,"sessionId":"65000000-0000-4000-8000-000000000000","cwd":"/tmp/loom-claude-sub","timestamp":"2026-07-08T00:00:02.000Z","isSidechain":true,"message":{"role":"user","content":"child task"}}
{"type":"assistant","uuid":"65000000-0000-4000-8000-000000000004","parentUuid":"65000000-0000-4000-8000-000000000003","sessionId":"65000000-0000-4000-8000-000000000000","cwd":"/tmp/loom-claude-sub","timestamp":"2026-07-08T00:00:03.000Z","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"child done"}]}}
EOF
cat > "$scratch/claude-subagents/root/subagents/agent-a.meta.json" <<'EOF'
{"agentType":"general","description":"synthetic","toolUseId":"toolu_sub_1","spawnDepth":1}
EOF
for to in pi codex; do
  expect_sidechain_flat_refusal \
    "claude-subagents-to-$to" claude "$to" \
    "$scratch/claude-subagents/root.jsonl" --with-subagents
done
(cd "$LOOM_ROOT" && lake exe loom convert claude loom \
  "$scratch/claude-subagents/root.jsonl" "$scratch/claude-subagents.loom.json" --with-subagents)
node -e '
const { readFileSync } = require("node:fs");
const j = JSON.parse(readFileSync(process.argv[1], "utf8"));
if (j.schema !== "loom.transcript.v0") throw new Error(`bad schema: ${j.schema}`);
if (!Array.isArray(j.threads) || j.threads.length !== 2) {
  throw new Error(`expected 2 threads, got ${j.threads && j.threads.length}`);
}
if (!j.threads.some(t => t.kind && t.kind.kind === "sidechain")) {
  throw new Error("sidechain thread not preserved in claude loom wire export");
}
' "$scratch/claude-subagents.loom.json"

echo "== cursor-ide actuator smoke =="
if env PATH=/nonexistent "$LOOM_BIN" cursor-ide \
    "$LOOM_ROOT/test.vscdb" cmp-fix loom "$scratch/cursor-ide.no-sqlite.json" \
    >"$scratch/cursor-ide.no-sqlite.out" 2>"$scratch/cursor-ide.no-sqlite.err"; then
  echo "error: cursor-ide unexpectedly ran without sqlite3" >&2
  exit 1
else
  status=$?
  if [[ "$status" -ne 2 ]] || ! grep -F -q "cannot start sqlite3" \
      "$scratch/cursor-ide.no-sqlite.err"; then
    cat "$scratch/cursor-ide.no-sqlite.err" >&2
    echo "error: missing sqlite3 did not return import class 2" >&2
    exit 1
  fi
  test ! -e "$scratch/cursor-ide.no-sqlite.json"
fi
cursor_ide_json="$(cd "$LOOM_ROOT" && lake exe loom cursor-ide \
  test.vscdb cmp-fix pi "$scratch/cursor-ide.pi.jsonl" \
  --cwd /tmp/loom-cursor-ide --provider cursor-provider --model cursor-model \
  --session-id cursor-ide-smoke \
  --target-timestamp 2026-07-20T01:02:03.004Z \
  --target-harness-version 0.74.0 --json)"
test -s "$scratch/cursor-ide.pi.jsonl"
node -e '
const { readFileSync } = require("node:fs");
const summary = JSON.parse(process.argv[1]);
const rows = readFileSync(process.argv[2], "utf8").trim().split(/\n/).map(JSON.parse);
if (summary.engine !== "lean" || summary.from !== "cursor-ide" ||
    summary.sessionId !== "cmp-fix" ||
    summary.targetSessionId !== "cursor-ide-smoke" ||
    summary.targetCwd !== "/tmp/loom-cursor-ide" ||
    summary.targetProvider !== "cursor-provider" ||
    summary.targetModel !== "cursor-model") {
  throw new Error(`unexpected Cursor IDE summary: ${JSON.stringify(summary)}`);
}
if (rows[0]?.id !== "cursor-ide-smoke" || rows[0]?.cwd !== "/tmp/loom-cursor-ide") {
  throw new Error(`Cursor IDE target overrides were ignored: ${JSON.stringify(rows[0])}`);
}
const assistant = rows.find(row => row.type === "message" && row.message?.role === "assistant");
if (!assistant || assistant.message.provider !== "loom-history" ||
    assistant.message.model !== "foreign-assistant") {
  throw new Error(`Cursor IDE assistant target metadata changed: ${JSON.stringify(assistant)}`);
}
' "$cursor_ide_json" "$scratch/cursor-ide.pi.jsonl"

echo "== convert-to-pi non-codex default loom engine smokes =="
claude_json="$(env -u PI_CONVERT_ENGINE LOOM_BIN="$LOOM_BIN" "$TSX" src/convertToPi.ts \
  --json claude "$LOOM_ROOT/parity/fixtures/claude.jsonl" "$scratch/claude.loom.pi.jsonl" \
  --target-cwd /tmp/loom-claude --target-provider deepseek \
  --target-model deepseek-v4-flash --target-session-id claude-loom-target \
  --target-timestamp 2026-07-20T01:02:03.004Z \
  --target-harness-version 0.74.0)"
test -s "$scratch/claude.loom.pi.jsonl"
node -e '
const { readFileSync } = require("node:fs");
const j = JSON.parse(process.argv[1]);
if (j.engine !== "lean" || j.messagesWritten !== 4 || j.toolCallsImported !== 1 || j.toolResultsImported !== 1 || j.thinkingBlocksImported !== 1) {
  throw new Error(`unexpected claude loom json summary: ${process.argv[1]}`);
}
const entries = readFileSync(process.argv[2], "utf8").trim().split(/\n/).map(JSON.parse);
if (entries[0].cwd !== "/tmp/loom-claude" || entries[0].version !== 3) throw new Error("claude header patch failed");
if (entries[0].loomPi?.targetHarnessVersion !== "0.74.0") {
  throw new Error("Pi target harness version was not retained in the header carrier");
}
const assistant = entries.find(e => e.type === "message" && e.message && e.message.role === "assistant");
if (!assistant || assistant.message.provider !== "loom-history" ||
    assistant.message.model !== "foreign-assistant") {
  throw new Error("claude historical assistant identity changed");
}
' "$claude_json" "$scratch/claude.loom.pi.jsonl"
# `--forbid-tool-name bash` was removed deliberately. Since 3882d70a a foreign
# tool lifecycle is exactly what Pi is supposed to load natively; forbidding the
# source's own tool name now asserts the defect this project exists to fix.
node "$LOOM_ROOT/scripts/verify-pi-context.mjs" \
  "$scratch/claude.loom.pi.jsonl" \
  --target-provider deepseek --target-model deepseek-v4-flash \
  --expect-user hi --expect-assistant tx --expect-assistant tx2 \
  >"$scratch/claude.pi-context.json"
node -e '
const { readFileSync } = require("node:fs");
const result = JSON.parse(readFileSync(process.argv[1], "utf8"));
const summary = JSON.parse(process.argv[2]);
const roles = result.contextRoles;
// The official Pi package loads the converted session and sees the Claude tool
// lifecycle as Pi state: a native toolCall block plus a toolResult role message.
// `verify-pi-context.mjs` counts one name per native toolCall and one per
// toolResult message, so the count is bound to the conversion census rather than
// pinned to a literal.
if (result.piPackage?.version !== "0.74.0" ||
    !Array.isArray(roles) || result.contextMessages !== roles.length ||
    roles[0] !== "user" || roles[roles.length - 1] !== "assistant" ||
    !roles.includes("toolResult") ||
    result.nativeToolNames.length !==
      summary.toolCallsEmittedNative + summary.toolResultsEmitted ||
    result.nativeToolNames.length === 0 ||
    result.nativeToolNames.some((name) => name !== "bash") ||
    summary.toolCallsEmittedNative !== summary.toolCallsImported ||
    summary.toolResultsEmitted !== summary.toolResultsImported ||
    result.activeModel?.provider !== "deepseek" ||
    result.activeModel?.modelId !== "deepseek-v4-flash") {
  throw new Error(`unexpected official Pi context: ${JSON.stringify(result)}`);
}
' "$scratch/claude.pi-context.json" "$claude_json"

cp "$LOOM_ROOT/testdata/sources/google-ai-studio.json" "$scratch/gais.json"
gais_json="$(env -u PI_CONVERT_ENGINE LOOM_BIN="$LOOM_BIN" "$TSX" src/convertToPi.ts \
  --json google-ai-studio "$scratch/gais.json" "$scratch/gais.loom.pi.jsonl" \
  --target-cwd /tmp/loom-gais --target-provider deepseek \
  --target-model deepseek-v4-flash --target-session-id gais-loom-target \
  --target-timestamp 2026-07-20T01:02:03.004Z \
  --target-harness-version 0.74.0)"
test -s "$scratch/gais.loom.pi.jsonl"
node -e '
const { readFileSync } = require("node:fs");
const j = JSON.parse(process.argv[1]);
if (j.engine !== "lean" || j.messagesImported !== 3) {
  throw new Error(`unexpected gais loom json summary: ${process.argv[1]}`);
}
const entries = readFileSync(process.argv[2], "utf8").trim().split(/\n/).map(JSON.parse);
if (entries[0].cwd !== "/tmp/loom-gais" || entries[0].version !== 3) throw new Error("gais header patch failed");
const modelChange = entries.find(e => e.type === "model_change");
if (!modelChange || modelChange.provider !== "deepseek" ||
    modelChange.modelId !== "deepseek-v4-flash") {
  throw new Error(`gais model_change patch failed: ${JSON.stringify(modelChange)}`);
}
const errorCarrier = entries.find(e =>
  e.type === "custom" && e.customType === "loom.pi.carrier" &&
  e.data?.kind === "event" && e.data?.value?.label === "error");
if (!errorCarrier ||
    errorCarrier.data.value.raw?.errorMessage !== "RESOURCE_EXHAUSTED: quota exceeded" ||
    entries.some(e => e.type === "event" && e.eventType === "google-ai-studio:error")) {
  throw new Error(`gais error was not preserved as inert history: ${JSON.stringify(errorCarrier)}`);
}
const assistant = entries.find(e => e.type === "message" && e.message && e.message.role === "assistant");
if (!assistant || assistant.message.provider !== "loom-history" ||
    assistant.message.model !== "foreign-assistant") {
  throw new Error("gais historical assistant identity changed");
}
' "$gais_json" "$scratch/gais.loom.pi.jsonl"

cp "$LOOM_ROOT/testdata/sources/hermes.json" "$scratch/hermes.json"
hermes_json="$(env -u PI_CONVERT_ENGINE LOOM_BIN="$LOOM_BIN" "$TSX" src/convertToPi.ts \
  --json hermes "$scratch/hermes.json" "$scratch/hermes.loom.pi.jsonl" \
  --target-cwd /tmp/loom-hermes --target-provider deepseek \
  --target-model deepseek-v4-flash --target-session-id hermes-loom-target \
  --target-timestamp 2026-07-20T01:02:03.004Z \
  --target-harness-version 0.74.0)"
test -s "$scratch/hermes.loom.pi.jsonl"
node -e '
const { readFileSync } = require("node:fs");
const j = JSON.parse(process.argv[1]);
if (j.engine !== "lean" || j.hermesSessionId !== "hermes-loom-smoke" || j.messagesWritten !== 3 || j.toolCallsImported !== 1 || j.toolResultsImported !== 1 || j.thinkingBlocksImported !== 1) {
  throw new Error(`unexpected hermes loom json summary: ${process.argv[1]}`);
}
const entries = readFileSync(process.argv[2], "utf8").trim().split(/\n/).map(JSON.parse);
if (entries[0].cwd !== "/tmp/loom-hermes" || entries[0].version !== 3) throw new Error("hermes header patch failed");
const assistant = entries.find(e => e.type === "message" && e.message && e.message.role === "assistant");
if (!assistant || assistant.message.provider !== "loom-history" ||
    assistant.message.model !== "foreign-assistant") {
  throw new Error("hermes historical assistant identity changed");
}
' "$hermes_json" "$scratch/hermes.loom.pi.jsonl"

echo "== thin launcher refuses implicit semantic-engine changes =="
if env -u PI_CONVERT_ENGINE LOOM_BIN="$LOOM_BIN" "$TSX" src/convertToPi.ts \
    --json cursor "$scratch/cursor.implicit.pi.jsonl" --chat-id cmp-fix \
    >"$scratch/cursor.implicit.out" 2>"$scratch/cursor.implicit.err"; then
  echo "error: thin launcher silently selected the Cursor TS engine" >&2
  exit 1
fi
grep -F -q "PI_CONVERT_ENGINE=ts" "$scratch/cursor.implicit.err"
test ! -e "$scratch/cursor.implicit.pi.jsonl"

if env -u PI_CONVERT_ENGINE LOOM_BIN="$LOOM_BIN" "$TSX" src/convertToPi.ts \
    --json claude "$LOOM_ROOT/parity/fixtures/claude.jsonl" "$scratch/claude.drop.pi.jsonl" \
    --drop-thinking >"$scratch/semantic.implicit.out" 2>"$scratch/semantic.implicit.err"; then
  echo "error: thin launcher silently selected TS for a semantic flag" >&2
  exit 1
fi
grep -F -q "PI_CONVERT_ENGINE=ts" "$scratch/semantic.implicit.err"
test ! -e "$scratch/claude.drop.pi.jsonl"

PI_CONVERT_ENGINE=ts "$TSX" src/convertToPi.ts --json claude \
  "$LOOM_ROOT/parity/fixtures/claude.jsonl" "$scratch/claude.explicit-ts.pi.jsonl" \
  --drop-thinking >"$scratch/semantic.explicit-ts.json"
test -s "$scratch/claude.explicit-ts.pi.jsonl"

echo "== convert-to-pi codex default loom engine smoke (LOOM_BIN override) =="
loom_json="$(env -u PI_CONVERT_ENGINE LOOM_BIN="$LOOM_BIN" "$TSX" src/convertToPi.ts \
  --json codex "$LOOM_ROOT/parity/fixtures/codex.jsonl" "$scratch/codex.loom.pi.jsonl" \
  --target-cwd /tmp/loom-codex --target-provider deepseek \
  --target-model deepseek-v4-flash --target-session-id codex-loom-target \
  --target-timestamp 2026-07-20T01:02:03.004Z \
  --target-harness-version 0.74.0)"
test -s "$scratch/codex.loom.pi.jsonl"
node -e '
const { readFileSync } = require("node:fs");
const j = JSON.parse(process.argv[1]);
for (const k of ["sessionId", "cwd", "messagesWritten", "toolCallsImported", "toolResultsImported", "reasoningBlocksImported", "compactionEvents", "skippedLines"]) {
  if (!(k in j)) throw new Error(`missing ${k}`);
}
const sourceRows = readFileSync(process.argv[2], "utf8")
  .split(/\n/).filter(line => line.trim().length > 0).map(JSON.parse);
const sourceMetadataRecords = sourceRows.filter(row =>
  row.type === "session_meta").length;
const skippedJudgments = j.importJudgments.filter(note =>
  note.kind === "contentSkipped" || note.kind === "dedupDropped").length;
if (j.engine !== "lean" || j.messagesWritten !== 5 || j.toolCallsImported !== 1 ||
    j.toolResultsImported !== 1 || j.controlsArchived !== 2 ||
    j.excludedSourceRecords !== 0 || j.compactionEvents !== 0 ||
    sourceMetadataRecords !== 1 ||
    sourceMetadataRecords + j.messagesImported + j.skippedLines !== sourceRows.length ||
    skippedJudgments !== j.skippedLines) {
  throw new Error(`unexpected loom json summary: ${process.argv[1]}`);
}
' "$loom_json" "$LOOM_ROOT/parity/fixtures/codex.jsonl"

echo "== convert-to-pi codex default loom engine smoke (repo binary path) =="
env -u PI_CONVERT_ENGINE -u LOOM_BIN "$TSX" src/convertToPi.ts \
  --json codex "$LOOM_ROOT/parity/fixtures/codex.jsonl" "$scratch/codex.loom.default.pi.jsonl" \
  --target-cwd /tmp/loom-codex-default --target-provider deepseek \
  --target-model deepseek-v4-flash --target-session-id codex-default-target \
  --target-timestamp 2026-07-20T01:02:03.004Z \
  --target-harness-version 0.74.0 >/dev/null
test -s "$scratch/codex.loom.default.pi.jsonl"

echo "== convert-to-pi codex loom cwd/provider smoke =="
env -u PI_CONVERT_ENGINE LOOM_BIN="$LOOM_BIN" "$TSX" src/convertToPi.ts \
  --json codex "$LOOM_ROOT/parity/fixtures/codex.jsonl" "$scratch/codex.options.pi.jsonl" \
  --target-cwd /tmp/loom-override --target-provider deepseek \
  --target-model deepseek-v4-flash --target-session-id codex-options-target \
  --target-timestamp 2026-07-20T01:02:03.004Z \
  --target-harness-version 0.74.0 >/dev/null
node -e '
const { readFileSync } = require("node:fs");
const entries = readFileSync(process.argv[1], "utf8").trim().split(/\n/).map(JSON.parse);
const header = entries[0];
if (header.cwd !== "/tmp/loom-override") throw new Error(`cwd override failed: ${header.cwd}`);
const assistant = entries.find(e => e.type === "message" && e.message && e.message.role === "assistant");
if (!assistant || assistant.message.provider !== "loom-history" ||
    assistant.message.model !== "foreign-assistant") {
  throw new Error("codex historical assistant identity changed");
}
' "$scratch/codex.options.pi.jsonl"

echo "== convert-to-pi install remains explicit legacy-only during thin-host cutover =="
if env -u PI_CONVERT_ENGINE LOOM_BIN="$LOOM_BIN" "$TSX" src/convertToPi.ts \
    --json codex "$LOOM_ROOT/parity/fixtures/codex.jsonl" --install \
    >"$scratch/install.implicit.out" 2>"$scratch/install.implicit.err"; then
  echo "error: thin launcher accepted a host-side install mutation" >&2
  exit 1
fi
grep -F -q "PI_CONVERT_ENGINE=ts" "$scratch/install.implicit.err"

echo "loom verification passed"
