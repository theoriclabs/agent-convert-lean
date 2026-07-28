#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
LOOM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
QUESTIONNAIRE_SOURCE="$LOOM_ROOT/testdata/release/readability-questionnaire.md"
HUMAN_VALIDATION_SOURCE="$LOOM_ROOT/HUMAN_VALIDATION.md"
PI_VERIFIER_SOURCE="$SCRIPT_DIR/verify-pi-context.mjs"
EXPECTED_CASE_D_CANONICAL_SHA256="bff6b5a6c981e393972eb97c25c1ccaf7a2a58b3ac8c8e4238e159e4386918b4"
LEAN_TOOLCHAIN_VERSION="4.28.0"
CLAUDE_TARGET_HARNESS_VERSION="2.1.216"
CODEX_TARGET_HARNESS_VERSION="0.144.1"
PI_TARGET_HARNESS_VERSION="0.74.0"
CURSOR_AGENT_TARGET_HARNESS_VERSION="2026.07.09-a3815c0"

clear_dangerous_environment() {
  local name
  while IFS='=' read -r name _; do
    case "$name" in
      NODE_OPTIONS|NODE_PATH|NODE_REPL_EXTERNAL_MODULE|DYLD_*|LD_PRELOAD|LD_LIBRARY_PATH|LD_AUDIT|[Nn][Pp][Mm]_[Cc][Oo][Nn][Ff][Ii][Gg]_*|BASH_ENV|ENV|CDPATH|PI_PACKAGE_ROOT|TAR_OPTIONS|GZIP|BZIP2) unset "$name" ;;
    esac
  done < <(env)
}
clear_dangerous_environment

BOOTSTRAP_NODE="$(command -v node || true)"
if [[ -z "$BOOTSTRAP_NODE" ]]; then
  echo "error: required command not found: node" >&2
  exit 2
fi

resolve_tool() {
  "$BOOTSTRAP_NODE" -e '
    const { accessSync, constants, lstatSync, realpathSync } = require("node:fs");
    const input = process.argv[1];
    const before = lstatSync(input);
    if (!before.isFile() && !before.isSymbolicLink()) throw new Error(`not a file or symlink: ${input}`);
    const path = realpathSync(input);
    const after = lstatSync(path);
    if (!after.isFile() || after.isSymbolicLink()) throw new Error(`tool does not resolve to a regular file: ${input}`);
    accessSync(path, constants.X_OK);
    process.stdout.write(path);
  ' "$1"
}

NODE_BIN="$(resolve_tool "$BOOTSTRAP_NODE")"

usage() {
  cat <<'EOF'
usage: prepare-human-validation.sh --run-id UUID --nonce 64_HEX \
         --pi-expectation TRACKED_EXPECTATION.json [--package PACKAGE.tgz] \
         LOOM_BINARY OUTPUT_DIR
       prepare-human-validation.sh --self-test

The run id and nonce must be issued by the independently controlled release
ledger and must never have been used before. The Pi expectation must be a clean,
Git-tracked file below spec/loom/testdata/release and must pin the complete
ordered Pi 0.74.0 context plus the exact oracle closure digests.

When --package is supplied, preparation rejects it unless it is an MIT
agent-convert package with the same preview version as the core and its public
agent-convert bin produces a byte-identical Loom artifact to the core.
OUTPUT_DIR must not exist and must be outside the source repository.
EOF
}

sha256_file() {
  local digest remainder
  IFS=' ' read -r digest remainder < <("${SHASUM_BIN:-shasum}" -a 256 -- "$1")
  printf '%s\n' "$digest"
}

canonical_file() {
  "$NODE_BIN" -e '
    const fs = require("node:fs");
    const input = process.argv[1];
    const before = fs.lstatSync(input);
    if (!before.isFile() || before.isSymbolicLink() || before.nlink !== 1) {
      throw new Error(`not a singly linked regular non-symlink file: ${input}`);
    }
    const p = fs.realpathSync(input);
    const s = fs.lstatSync(p);
    if (!s.isFile() || s.isSymbolicLink() || s.nlink !== 1) throw new Error(`not a regular non-symlink file: ${p}`);
    process.stdout.write(p);
  ' "$1"
}

canonical_dir() {
  "$NODE_BIN" -e '
    const fs = require("node:fs");
    const input = process.argv[1];
    const before = fs.lstatSync(input);
    if (!before.isDirectory() || before.isSymbolicLink()) throw new Error(`not a non-symlink directory: ${input}`);
    const p = fs.realpathSync(input);
    const s = fs.lstatSync(p);
    if (!s.isDirectory() || s.isSymbolicLink()) throw new Error(`not a real directory: ${p}`);
    process.stdout.write(p);
  ' "$1"
}

resolve_loom_toolchain_tool() {
  local bootstrap_lake selected
  bootstrap_lake="$(resolve_tool "$(command -v lake)")"
  selected="$(cd "$LOOM_ROOT" && "$bootstrap_lake" env which "$1")"
  resolve_tool "$selected"
}

snapshot_file() {
  "$NODE_BIN" -e '
    const fs = require("node:fs");
    const [source, target, modeRaw] = process.argv.slice(1);
    const stat = fs.lstatSync(source);
    if (!stat.isFile() || stat.isSymbolicLink() || stat.nlink !== 1) throw new Error(`snapshot source is not a singly linked regular file: ${source}`);
    const fd = fs.openSync(source, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
    try {
      const opened = fs.fstatSync(fd);
      if (!opened.isFile() || opened.nlink !== 1) throw new Error(`snapshot source changed type: ${source}`);
      fs.writeFileSync(target, fs.readFileSync(fd), { flag: "wx", mode: Number(modeRaw) });
    } finally {
      fs.closeSync(fd);
    }
  ' "$1" "$2" "$3"
}

make_sandbox_profile() {
  "$NODE_BIN" - "$1" "$2" <<'NODE'
const { writeFileSync } = require("node:fs");
const [output, writableRoot] = process.argv.slice(2);
const quote = (value) => JSON.stringify(value);
writeFileSync(output, `(version 1)\n(deny default)\n(allow process*)\n(allow file-read*)\n` +
  `(allow file-write* (subpath ${quote(writableRoot)}) (literal "/dev/null"))\n` +
  `(allow sysctl-read)\n(allow mach-lookup)\n`, { flag: "wx", mode: 0o400 });
NODE
}

run_untrusted() {
  local writable_root="$1"; shift
  local profile="$writable_root/sandbox.sb"
  mkdir -p "$writable_root/home" "$writable_root/tmp"
  chmod 700 "$writable_root" "$writable_root/home" "$writable_root/tmp"
  make_sandbox_profile "$profile" "$writable_root"
  (
    cd "$writable_root"
    "$ENV_BIN" -i HOME="$writable_root/home" TMPDIR="$writable_root/tmp" \
      PATH="$PRIVATE_PATH" LC_ALL=C LANG=C TZ=UTC \
      "$SANDBOX_EXEC_BIN" -f "$profile" "$@"
  )
}

verify_prepared_layout() {
  "$NODE_BIN" - "$1" "$2" <<'NODE'
const { lstatSync, readdirSync, readFileSync } = require("node:fs");
const { join, relative, sep } = require("node:path");
const [root, requireClosed] = process.argv.slice(2);
const provenance = JSON.parse(readFileSync(join(root, "admin", "ADMIN-PROVENANCE.json"), "utf8"));
const expectedFiles = new Set([
  "PREPARED", "ROOT-MANIFEST.sha256",
  "review/REVIEW-BINDING.json", "review/CASE-A.inspect.txt", "review/CASE-B.inspect.txt",
  "review/CASE-C.inspect.txt", "review/CASE-D.inspect.txt", "review/QUESTIONNAIRE.md",
  "review/PREPARATION-MANIFEST.sha256",
  "admin/ADMIN-PROVENANCE.json", "admin/PROTOCOL.md", "admin/PREPARATION-SCRIPT.sh",
  "admin/PI-VERIFIER.mjs", "admin/PI-CONTEXT-EXPECTATION.json",
  "admin/PI-CONTEXT-VERIFICATION.json", "admin/PI-CONVERSION-SUMMARY.json",
  "admin/HARNESS-VERSIONS.json",
  "admin/SOURCE-TREE.txt", "admin/DIRECT-OUTPUT.loom.json", "admin/DIRECT-CLI-SUMMARY.json",
  "admin/CASE-D-CODEX-TO-LOOM-SUMMARY.json", "admin/CASE-D-LOOM-TO-CLAUDE-SUMMARY.json",
  "snapshots/loom", "snapshots/fixture-a.claude.jsonl", "snapshots/fixture-b.claude.jsonl",
  "snapshots/fixture-c.loom.json", "snapshots/fixture-d.codex.jsonl", "snapshots/pi-session.jsonl",
]);
if (provenance.packageTarball !== null) for (const name of [
  "admin/PACKAGE-METADATA.json", "admin/PACKAGE-CLI-OUTPUT.loom.json",
  "admin/PACKAGE-CLI-STDOUT.json", "admin/PACKAGE-CLI-STDERR.txt",
  "admin/PACKAGE-LOCK.json", "admin/NPM-INSTALL.log", "snapshots/package.tgz",
]) expectedFiles.add(name);
const expectedDirs = new Set([".", "review", "admin", "snapshots"]);
const actualFiles = new Set();
const actualDirs = new Set();
function walk(path) {
  const stat = lstatSync(path);
  const name = relative(root, path).split(sep).join("/") || ".";
  if (stat.isSymbolicLink()) throw new Error(`symlink forbidden: ${name}`);
  if (requireClosed === "closed" && (stat.mode & 0o222) !== 0) throw new Error(`writable prepared entry: ${name}`);
  if (stat.isDirectory()) {
    actualDirs.add(name);
    for (const child of readdirSync(path).sort()) walk(join(path, child));
  } else if (stat.isFile() && stat.nlink === 1) actualFiles.add(name);
  else throw new Error(`special file forbidden: ${name}`);
}
walk(root);
const compare = (actual, expected, label) => {
  const a = [...actual].sort(), e = [...expected].sort();
  if (JSON.stringify(a) !== JSON.stringify(e)) throw new Error(`${label} allowlist mismatch\nactual=${a}\nexpected=${e}`);
};
compare(actualFiles, expectedFiles, "file");
compare(actualDirs, expectedDirs, "directory");
const parse = (path) => readFileSync(path, "utf8").trimEnd().split("\n").map((line) => {
  const match = line.match(/^[0-9a-f]{64}  ([A-Za-z0-9._/-]+)$/);
  if (!match) throw new Error(`malformed manifest line: ${line}`);
  return match[1];
});
compare(new Set(parse(join(root, "ROOT-MANIFEST.sha256"))),
  new Set([...expectedFiles].filter((name) => name !== "ROOT-MANIFEST.sha256")), "root manifest");
compare(new Set(parse(join(root, "review", "PREPARATION-MANIFEST.sha256"))),
  new Set([...expectedFiles].filter((name) => name.startsWith("review/") &&
    !name.endsWith("PREPARATION-MANIFEST.sha256")).map((name) => name.slice(7))), "review manifest");
NODE
}

enforce_required_tool_versions() {
  local capture_path="$1"
  "$NODE_BIN" - "$capture_path" \
    lean "Lean" "$LEAN_TOOLCHAIN_VERSION" "lake env lean --version" \
    claude "Claude Code" "$CLAUDE_TARGET_HARNESS_VERSION" "claude --version" \
    codex "Codex CLI" "$CODEX_TARGET_HARNESS_VERSION" "codex --version" \
    pi "Pi" "$PI_TARGET_HARNESS_VERSION" "pi --version" \
    cursorAgent "Cursor Agent" "$CURSOR_AGENT_TARGET_HARNESS_VERSION" "cursor-agent --version" <<'NODE'
const { readFileSync } = require("node:fs");
const [capturePath, ...requirementArgs] = process.argv.slice(2);
if (requirementArgs.length % 4 !== 0) throw new Error("invalid required-tool version configuration");
const capture = JSON.parse(readFileSync(capturePath, "utf8"));
const mismatches = [];
for (let index = 0; index < requirementArgs.length; index += 4) {
  const [key, label, expected, probe] = requirementArgs.slice(index, index + 4);
  const record = capture.tools?.[key];
  const actual = typeof record?.parsedVersion === "string" ? record.parsedVersion : "<missing>";
  const executable = typeof record?.executable === "string" ? record.executable : "<missing>";
  if (actual !== expected) {
    mismatches.push(`${label}: expected exactly ${expected}; parsed ${actual}; executable ${executable}; ` +
      `install or select ${label} ${expected}, then confirm \`${probe}\` reports ${expected}`);
  }
}
if (mismatches.length > 0) {
  console.error("error: required human-validation tool versions do not match the release pins:");
  for (const mismatch of mismatches) console.error(`  - ${mismatch}`);
  console.error("action: correct every mismatch above and rerun prepare-human-validation.sh");
  process.exit(2);
}
NODE
}

self_test() {
  local temp source symlink hardlink profile
  local CLAUDE_BIN CODEX_BIN PI_BIN CURSOR_AGENT_BIN NPM_BIN TAR_BIN LEAN_BIN LAKE_BIN
  CLAUDE_BIN="$(resolve_tool "$(command -v claude)")"
  CODEX_BIN="$(resolve_tool "$(command -v codex)")"
  PI_BIN="$(resolve_tool "$(command -v pi)")"
  CURSOR_AGENT_BIN="$(resolve_tool "$(command -v cursor-agent)")"
  NPM_BIN="$(resolve_tool "$(command -v npm)")"
  TAR_BIN="$(resolve_tool "$(command -v tar)")"
  LEAN_BIN="$(resolve_loom_toolchain_tool lean)"
  LAKE_BIN="$(resolve_loom_toolchain_tool lake)"
  "$NODE_BIN" - "$HUMAN_VALIDATION_SOURCE" "$QUESTIONNAIRE_SOURCE" "${BASH_SOURCE[0]}" "$PI_VERIFIER_SOURCE" <<'NODE'
const { readFileSync } = require("node:fs");
const [protocolPath, questionnairePath, scriptPath, verifierPath] = process.argv.slice(2);
const protocol = readFileSync(protocolPath, "utf8");
const questionnaire = readFileSync(questionnairePath, "utf8");
const script = readFileSync(scriptPath, "utf8");
const verifier = readFileSync(verifierPath, "utf8");
const requireText = (text, needle, label) => {
  if (!text.includes(needle)) throw new Error(`${label} is missing ${needle}`);
};
const questions = [...questionnaire.matchAll(/^(\d+)\. /gm)].map((match) => Number(match[1]));
const expected = Array.from({ length: 14 }, (_, index) => index + 1);
if (JSON.stringify(questions) !== JSON.stringify(expected)) throw new Error("questionnaire numbering mismatch");
const answerSections = [...questionnaire.matchAll(/^### Answer (\d+)$/gm)].map((match) => Number(match[1]));
if (JSON.stringify(answerSections) !== JSON.stringify(expected)) throw new Error("questionnaire answer-section mismatch");
const answerKey = protocol.split("## Factual Answer Key\n")[1]?.split("\n## ")[0] ?? "";
const answers = [...answerKey.matchAll(/^(\d+)\. /gm)].map((match) => Number(match[1]));
if (JSON.stringify(answers) !== JSON.stringify(expected)) throw new Error("answer-key numbering mismatch");
for (const [text, needles, label] of [
  [questionnaire, ["Pre-review receipt SHA-256", "Preparation root manifest SHA-256", "Clarification count", "Reviewer signature:"], "questionnaire"],
  [protocol, ["Independent Ledger", "Independent Trust Inputs", "pre-review", "seal-human-validation.sh"], "protocol"],
  [script, ["run_untrusted", "enforce_required_tool_versions",
    "archive links are forbidden", "maxOutputLength", "global PAX path or size overrides are forbidden",
    "tar archive has trailing non-zero data", "npm bin shim", "verify_protected_inputs", "readdirSync"], "script"],
  [verifier, ["--release", "sourceToolAssertions", "oracleClosureSha256", "validatePublicExportBinding",
    "publicBuildSessionContextExportBound", "node-permission-model-read-only-child"], "Pi verifier"],
]) for (const needle of needles) requireText(text, needle, label);

const pinDeclarationsEnd = script.indexOf("\nself_test() {");
if (pinDeclarationsEnd < 0) throw new Error("could not locate self-test declaration");
const declarations = script.slice(0, pinDeclarationsEnd);
const requiredPins = [
  ["LEAN_TOOLCHAIN_VERSION", "4.28.0", "lean", "lean", "Lean", "expectedLean", "lake env lean --version"],
  ["CLAUDE_TARGET_HARNESS_VERSION", "2.1.216", "claude", "claude", "Claude Code", "expectedClaude", "claude --version"],
  ["CODEX_TARGET_HARNESS_VERSION", "0.144.1", "codex", "codex", "Codex CLI", "expectedCodex", "codex --version"],
  ["PI_TARGET_HARNESS_VERSION", "0.74.0", "pi", "pi", "Pi", "expectedPi", "pi --version"],
  ["CURSOR_AGENT_TARGET_HARNESS_VERSION", "2026.07.09-a3815c0", "cursorAgent", "cursor-agent", "Cursor Agent", "expectedCursorAgent", "cursor-agent --version"],
];
const enforcementStart = declarations.indexOf("\nenforce_required_tool_versions() {");
if (enforcementStart < 0) throw new Error("could not locate required-tool version enforcement");
const enforcementSource = declarations.slice(enforcementStart);
for (const [constant, version, productionKey, , label, , probe] of requiredPins) {
  requireText(declarations, `${constant}="${version}"`, "script pin declarations");
  requireText(enforcementSource, `${productionKey} "${label}" "$${constant}" "${probe}"`,
    "production required-tool version enforcement");
}
requireText(enforcementSource, ["if (actual ", "!== expected)"].join(""),
  "production required-tool version comparison");
requireText(enforcementSource, ["process.", "exit(2)"].join(""),
  "production required-tool version failure");

const selfTestEnd = script.indexOf('\n}\n\nif [[ "${1:-}" == "--self-test" ]]', pinDeclarationsEnd);
if (selfTestEnd < 0) throw new Error("could not locate self-test boundary");
const selfTestSource = script.slice(pinDeclarationsEnd, selfTestEnd);
for (const [constant, , , selfTestKey, label, expectedVariable, probe] of requiredPins) {
  requireText(selfTestSource, `"$${constant}"`, "queried tool-version self-test");
  requireText(selfTestSource,
    `["${selfTestKey}", { label: "${label}", expected: ${expectedVariable}, probe: "${probe}" }]`,
    "queried tool-version self-test comparison map");
}
requireText(selfTestSource,
  ["for (const [name, ", "{ label, expected, probe }] of requiredVersions)"].join(""),
  "queried tool-version self-test comparison");
requireText(selfTestSource, ["if (actual ", "!== expected)"].join(""),
  "queried tool-version self-test mismatch failure");

const productionStart = script.indexOf('\nRUN_ID=""', selfTestEnd);
if (productionStart < 0) throw new Error("could not locate production preparation");
const productionSource = script.slice(productionStart);
const captureSchemaIndex = productionSource.indexOf('schema: "loom.queried-tool-versions.v1"');
const captureEndIndex = productionSource.indexOf("\nNODE\n", captureSchemaIndex);
const gateNeedle = ["enforce_required_tool", '_versions "$stageDir/admin/HARNESS-VERSIONS.json"'].join("");
const gateIndex = productionSource.indexOf(gateNeedle);
const candidateExecutionIndex = productionSource.indexOf('run_untrusted "$workDir/candidate-version" "$CANDIDATE"');
const packageExecutionIndex = productionSource.indexOf('run_untrusted "$packageWork" "$NPM_BIN" install');
if (captureSchemaIndex < 0 || captureEndIndex < 0 || gateIndex <= captureEndIndex ||
    candidateExecutionIndex < 0 || gateIndex >= candidateExecutionIndex ||
    packageExecutionIndex < 0 || gateIndex >= packageExecutionIndex ||
    productionSource.indexOf(gateNeedle, gateIndex + gateNeedle.length) !== -1) {
  throw new Error("production required-tool gate is missing, duplicated, or outside the pre-execution boundary");
}
if (/candidate\.json/.test(questionnaire) || /seven entries/i.test(questionnaire) || /answer key/i.test(questionnaire)) {
  throw new Error("blinded questionnaire leaks administrator-only information");
}
const markup = /<\/?[A-Za-z][A-Za-z0-9:_-]*(?:\s+[^<>]*?)?\s*\/?>/g;
for (const sample of ["<TAG>", "</tag>", "<Tag attr=\"x\">", "<tag/>"]) {
  if (!markup.test(sample)) throw new Error(`generic markup detector missed ${sample}`);
  markup.lastIndex = 0;
}

// The handoff sanitizer must reject anything that can drive a terminal while
// leaving ordinary rendered text, tabs, and newlines alone. This mirrors the
// character class applied to the prepared review directory.
const forbiddenControl = /[\u0000-\u0008\u000B-\u001F\u007F-\u009F\u202A-\u202E\u2066-\u2069\uFEFF]/;
for (const sample of [
  "\u001b[31mred\u001b[0m", "\u001b]0;retitled\u0007", "nul\u0000byte",
  "back\u0008space", "delete\u007f", "c1\u009b", "\ufeffbom",
  "bidi\u202ereversed", "isolate\u2066text",
]) {
  if (!forbiddenControl.test(sample)) {
    throw new Error(`control-character sanitizer missed ${JSON.stringify(sample)}`);
  }
}
for (const sample of ["plain text", "tab\tseparated", "line\nbreak", "unicode: café ✓"]) {
  if (forbiddenControl.test(sample)) {
    throw new Error(`control-character sanitizer rejected legitimate text ${JSON.stringify(sample)}`);
  }
}
requireText(script, "forbiddenControl", "script");
if (/await import\(pathToFileURL\(join\(packageRoot,\s*"dist",\s*"index\.js"/.test(verifier)) {
  throw new Error("Pi verifier still imports the broad live package root");
}
if (!script.includes("--target-harness-version \"$CLAUDE_TARGET_HARNESS_VERSION\"")) {
  throw new Error("Case D does not explicitly pass the Claude target harness version");
}
if (!script.includes('"$TAR_BIN" -xOz -f "$workDir/inputs/package.tgz" -- package/package.json')) {
  throw new Error("tar extraction does not place -- before the validated member path");
}
const safePathSource = script.match(/(const safePath = \(value, label\) => \{[\s\S]*?\n\};)\nconst files/);
if (!safePathSource) throw new Error("could not locate production archive path validator");
const archiveSafePath = Function(`${safePathSource[1]}; return safePath;`)();
const gzipImport = script.lastIndexOf('const { gunzipSync } = require("node:zlib");');
const archiveProgramStart = script.lastIndexOf('const { createHash } = require("node:crypto");', gzipImport);
const archiveProgramEnd = script.indexOf('\nNODE\n  archiveBinMember=', gzipImport);
if (gzipImport < 0 || archiveProgramStart < 0 || archiveProgramEnd < 0) {
  throw new Error("could not locate production archive validator program");
}
Function(script.slice(archiveProgramStart, archiveProgramEnd));
for (const valid of ["package", "package/package.json", "package/bin/agent-convert.js"]) {
  if (archiveSafePath(valid, "self-test") !== valid) throw new Error(`archive path self-test rejected ${valid}`);
}
for (const invalid of ["/absolute", "../escape", "package/../escape", "package//escape",
  "package/./escape", "package\\escape", "other/escape", "package/\u0000escape"]) {
  let rejected = false;
  try { archiveSafePath(invalid, "self-test"); } catch { rejected = true; }
  if (!rejected) throw new Error(`archive path self-test accepted ${JSON.stringify(invalid)}`);
}

// Invalid UTF-8 must not survive the round trip the sanitizer relies on.
const invalidUtf8 = Buffer.from([0x41, 0xc3, 0x28]);
if (Buffer.compare(Buffer.from(invalidUtf8.toString("utf8"), "utf8"), invalidUtf8) === 0) {
  throw new Error("UTF-8 round-trip detector failed to flag invalid bytes");
}

console.log("human-validation preparation self-test: ok");
NODE
  "$NODE_BIN" - \
    "$LEAN_TOOLCHAIN_VERSION" "$CLAUDE_TARGET_HARNESS_VERSION" \
    "$CODEX_TARGET_HARNESS_VERSION" "$PI_TARGET_HARNESS_VERSION" \
    "$CURSOR_AGENT_TARGET_HARNESS_VERSION" \
    claude "$CLAUDE_BIN" codex "$CODEX_BIN" pi "$PI_BIN" cursor-agent "$CURSOR_AGENT_BIN" \
    node "$NODE_BIN" npm "$NPM_BIN" tar "$TAR_BIN" lean "$LEAN_BIN" lake "$LAKE_BIN" <<'NODE'
const { spawnSync } = require("node:child_process");
const [expectedLean, expectedClaude, expectedCodex, expectedPi, expectedCursorAgent, ...pairs] = process.argv.slice(2);
const requiredVersions = new Map([
  ["lean", { label: "Lean", expected: expectedLean, probe: "lake env lean --version" }],
  ["claude", { label: "Claude Code", expected: expectedClaude, probe: "claude --version" }],
  ["codex", { label: "Codex CLI", expected: expectedCodex, probe: "codex --version" }],
  ["pi", { label: "Pi", expected: expectedPi, probe: "pi --version" }],
  ["cursor-agent", { label: "Cursor Agent", expected: expectedCursorAgent, probe: "cursor-agent --version" }],
]);
const observed = {};
const executables = {};
for (let index = 0; index < pairs.length; index += 2) {
  const name = pairs[index], command = pairs[index + 1];
  const run = spawnSync(command, ["--version"], { encoding: "utf8", env: {
    PATH: process.env.PATH, HOME: process.env.HOME, TMPDIR: process.env.TMPDIR ?? "/tmp", LC_ALL: "C",
  } });
  const combined = `${run.stdout ?? ""}\n${run.stderr ?? ""}`.trim();
  const parsedVersion = combined.match(/(?:^|[^0-9A-Za-z])v?(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)/m)?.[1];
  if (run.status !== 0 || !parsedVersion) {
    throw new Error(`${name} --version self-test failed (${run.status}): ${combined}`);
  }
  observed[name] = parsedVersion;
  executables[name] = command;
}
const mismatches = [];
for (const [name, { label, expected, probe }] of requiredVersions) {
  const actual = observed[name] ?? "<missing>";
  if (actual !== expected) {
    mismatches.push(`${label}: expected exactly ${expected}; parsed ${actual}; executable ${executables[name] ?? "<missing>"}; ` +
      `install or select ${label} ${expected}, then confirm \`${probe}\` reports ${expected}`);
  }
}
if (mismatches.length > 0) {
  throw new Error(`required tool version self-test mismatch:\n  - ${mismatches.join("\n  - ")}\n` +
    "action: correct every mismatch above and rerun prepare-human-validation.sh --self-test");
}
console.log(`queried tool-version self-test: ok (${JSON.stringify(observed)})`);
NODE

  temp="$(mktemp -d "${TMPDIR:-/tmp}/loom-prepare-self-test.XXXXXX")"
  source="$temp/source"
  symlink="$temp/symlink"
  hardlink="$temp/hardlink"
  profile="$temp/sandbox.sb"
  printf 'snapshot bytes\n' >"$source"
  ln -s "$source" "$symlink"
  if canonical_file "$symlink" >/dev/null 2>&1; then
    echo "error: symlink-before-realpath self-test failed" >&2
    exit 1
  fi
  ln "$source" "$hardlink"
  if snapshot_file "$source" "$temp/copied" 256 >/dev/null 2>&1; then
    echo "error: hardlink snapshot refusal self-test failed" >&2
    exit 1
  fi
  mkdir -m 700 "$temp/writable"
  make_sandbox_profile "$profile" "$temp/writable"
  if ! grep -F -q '(deny default)' "$profile" || grep -F -q '(allow file-write*)' "$profile"; then
    echo "error: sandbox profile self-test failed" >&2
    exit 1
  fi
  rm -rf -- "$temp"
  "$NODE_BIN" "$PI_VERIFIER_SOURCE" --self-test
}

if [[ "${1:-}" == "--self-test" ]]; then
  if [[ "$#" -ne 1 ]]; then usage >&2; exit 2; fi
  self_test
  exit 0
fi

RUN_ID=""
RUN_NONCE=""
PI_EXPECTATION=""
PACKAGE_TARBALL=""
positionals=()
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --run-id|--nonce|--pi-expectation|--package)
      if [[ "$#" -lt 2 || -z "$2" ]]; then echo "error: $1 requires a value" >&2; exit 2; fi
      case "$1" in
        --run-id) RUN_ID="$2" ;;
        --nonce) RUN_NONCE="$2" ;;
        --pi-expectation) PI_EXPECTATION="$2" ;;
        --package) PACKAGE_TARBALL="$2" ;;
      esac
      shift 2
      ;;
    --*) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) positionals+=("$1"); shift ;;
  esac
done
if [[ "${#positionals[@]}" -ne 2 || -z "$RUN_ID" || -z "$RUN_NONCE" || -z "$PI_EXPECTATION" ]]; then
  usage >&2
  exit 2
fi
if [[ ! "$RUN_ID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]]; then
  echo "error: --run-id must be a lowercase UUIDv4" >&2
  exit 2
fi
if [[ ! "$RUN_NONCE" =~ ^[0-9a-f]{64}$ ]]; then
  echo "error: --nonce must be 32 random bytes encoded as lowercase hexadecimal" >&2
  exit 2
fi

for required_command in git node shasum mktemp npm tar cmp lean lake claude codex pi cursor-agent sandbox-exec env; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    echo "error: required command not found: $required_command" >&2
    exit 2
  fi
done
GIT_BIN="$(resolve_tool "$(command -v git)")"
SHASUM_BIN="$(resolve_tool "$(command -v shasum)")"
NPM_BIN="$(resolve_tool "$(command -v npm)")"
TAR_BIN="$(resolve_tool "$(command -v tar)")"
CMP_BIN="$(resolve_tool "$(command -v cmp)")"
LEAN_BIN="$(resolve_loom_toolchain_tool lean)"
LAKE_BIN="$(resolve_loom_toolchain_tool lake)"
CLAUDE_BIN="$(resolve_tool "$(command -v claude)")"
CODEX_BIN="$(resolve_tool "$(command -v codex)")"
PI_BIN="$(resolve_tool "$(command -v pi)")"
CURSOR_AGENT_BIN="$(resolve_tool "$(command -v cursor-agent)")"
SANDBOX_EXEC_BIN="$(resolve_tool "$(command -v sandbox-exec)")"
ENV_BIN="$(resolve_tool "$(command -v env)")"

LOOM_BIN="$(canonical_file "${positionals[0]}")"
PI_EXPECTATION="$(canonical_file "$PI_EXPECTATION")"
PACKAGE_PATH=""
if [[ -n "$PACKAGE_TARBALL" ]]; then PACKAGE_PATH="$(canonical_file "$PACKAGE_TARBALL")"; fi

REPO_ROOT="$("$GIT_BIN" -C "$LOOM_ROOT" rev-parse --show-toplevel)"
REPO_ROOT="$(canonical_dir "$REPO_ROOT")"
case "$LOOM_ROOT/" in
  "$REPO_ROOT/"*) GIT_SOURCE_PATH="${LOOM_ROOT#"$REPO_ROOT/"}" ;;
  *) echo "error: Loom root is outside its Git repository" >&2; exit 2 ;;
esac
if [[ "$GIT_SOURCE_PATH" != "spec/loom" ]]; then
  echo "error: unexpected Loom source path: $GIT_SOURCE_PATH" >&2
  exit 2
fi
case "$PI_EXPECTATION" in
  "$LOOM_ROOT/testdata/release/"*) ;;
  *) echo "error: Pi expectation must be below spec/loom/testdata/release" >&2; exit 2 ;;
esac
PI_EXPECTATION_REL="${PI_EXPECTATION#"$REPO_ROOT/"}"
if ! "$GIT_BIN" -C "$REPO_ROOT" ls-files --error-unmatch "$PI_EXPECTATION_REL" >/dev/null 2>&1; then
  echo "error: Pi expectation must be Git-tracked before release preparation" >&2
  exit 2
fi

HEAD_REVISION="$("$GIT_BIN" -C "$REPO_ROOT" rev-parse HEAD)"
if [[ ! "$HEAD_REVISION" =~ ^[0-9a-f]{40}$ ]]; then
  echo "error: repository HEAD is not an immutable 40-character revision" >&2
  exit 2
fi
if [[ -n "$("$GIT_BIN" -C "$REPO_ROOT" status --porcelain --untracked-files=all -- "$GIT_SOURCE_PATH")" ]]; then
  echo "error: Loom source scope is dirty; commit the exact release sources first" >&2
  exit 2
fi
SOURCE_TREE="$("$GIT_BIN" -C "$REPO_ROOT" rev-parse "$HEAD_REVISION:$GIT_SOURCE_PATH")"
ROOT_TREE="$("$GIT_BIN" -C "$REPO_ROOT" rev-parse "$HEAD_REVISION^{tree}")"

OUTPUT_RESOLVED="$("$NODE_BIN" -e 'process.stdout.write(require("node:path").resolve(process.argv[1]))' "${positionals[1]}")"
OUTPUT_PARENT_RAW="$(dirname "$OUTPUT_RESOLVED")"
OUTPUT_NAME="$(basename "$OUTPUT_RESOLVED")"
if [[ "$OUTPUT_NAME" == "." || "$OUTPUT_NAME" == ".." || "$OUTPUT_NAME" == "/" ||
      "$OUTPUT_NAME" == -* || ! "$OUTPUT_NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "error: invalid output directory name" >&2
  exit 2
fi
mkdir -p "$OUTPUT_PARENT_RAW"
OUTPUT_PARENT="$(canonical_dir "$OUTPUT_PARENT_RAW")"
OUTPUT_DIR="$OUTPUT_PARENT/$OUTPUT_NAME"
case "$OUTPUT_DIR/" in
  "$REPO_ROOT/"*) echo "error: output directory must be outside the source repository" >&2; exit 2 ;;
esac
if [[ -e "$OUTPUT_DIR" || -L "$OUTPUT_DIR" ]]; then
  echo "error: output path already exists; refusing stale or mixed evidence: $OUTPUT_DIR" >&2
  exit 2
fi

stageDir="$(mktemp -d "$OUTPUT_PARENT/.${OUTPUT_NAME}.prepare.XXXXXX")"
workDir="$(mktemp -d "${TMPDIR:-/tmp}/loom-human-validation-work.XXXXXX")"
reservedOutput=""
cleanup() {
  if [[ -n "${stageDir:-}" && -d "$stageDir" ]]; then chmod -R u+w "$stageDir" 2>/dev/null || true; rm -rf -- "$stageDir"; fi
  if [[ -n "${workDir:-}" && -d "$workDir" ]]; then chmod -R u+w "$workDir" 2>/dev/null || true; rm -rf -- "$workDir"; fi
  if [[ -n "${reservedOutput:-}" && -d "$reservedOutput" ]]; then chmod -R u+w "$reservedOutput" 2>/dev/null || true; rm -rf -- "$reservedOutput"; fi
}
trap cleanup EXIT HUP INT TERM
chmod 700 "$stageDir" "$workDir"
mkdir -m 700 "$stageDir/review" "$stageDir/admin" "$stageDir/snapshots"

# Snapshot every mutable input once. All subsequent commands use these private
# master copies. Untrusted processes receive separate read-only execution copies
# and can write only to their dedicated sandbox output directory.
snapshot_file "$LOOM_BIN" "$stageDir/snapshots/loom" 320
snapshot_file "$LOOM_ROOT/parity/fixtures/claude.jsonl" "$stageDir/snapshots/fixture-a.claude.jsonl" 256
snapshot_file "$LOOM_ROOT/testdata/claude/control-envelopes.jsonl" "$stageDir/snapshots/fixture-b.claude.jsonl" 256
snapshot_file "$LOOM_ROOT/testdata/wire/sidechain-interleaved.v0.json" "$stageDir/snapshots/fixture-c.loom.json" 256
snapshot_file "$LOOM_ROOT/testdata/codex/tool-lifecycle-controls.jsonl" "$stageDir/snapshots/fixture-d.codex.jsonl" 256
snapshot_file "$PI_EXPECTATION" "$stageDir/admin/PI-CONTEXT-EXPECTATION.json" 256
snapshot_file "$HUMAN_VALIDATION_SOURCE" "$stageDir/admin/PROTOCOL.md" 256
snapshot_file "${BASH_SOURCE[0]}" "$stageDir/admin/PREPARATION-SCRIPT.sh" 256
snapshot_file "$PI_VERIFIER_SOURCE" "$stageDir/admin/PI-VERIFIER.mjs" 256
snapshot_file "$QUESTIONNAIRE_SOURCE" "$stageDir/review/QUESTIONNAIRE.md" 256
if [[ -n "$PACKAGE_PATH" ]]; then snapshot_file "$PACKAGE_PATH" "$stageDir/snapshots/package.tgz" 256; fi

mkdir -m 700 "$workDir/inputs" "$workDir/private-bin" "$workDir/tool-versions"
snapshot_file "$stageDir/snapshots/loom" "$workDir/inputs/loom" 320
snapshot_file "$stageDir/snapshots/fixture-a.claude.jsonl" "$workDir/inputs/fixture-a.claude.jsonl" 256
snapshot_file "$stageDir/snapshots/fixture-b.claude.jsonl" "$workDir/inputs/fixture-b.claude.jsonl" 256
snapshot_file "$stageDir/snapshots/fixture-c.loom.json" "$workDir/inputs/fixture-c.loom.json" 256
snapshot_file "$stageDir/snapshots/fixture-d.codex.jsonl" "$workDir/inputs/fixture-d.codex.jsonl" 256
snapshot_file "$stageDir/admin/PI-CONTEXT-EXPECTATION.json" "$workDir/inputs/pi-expectation.json" 256
snapshot_file "$stageDir/admin/PI-VERIFIER.mjs" "$workDir/inputs/pi-verifier.mjs" 256
if [[ -n "$PACKAGE_PATH" ]]; then snapshot_file "$stageDir/snapshots/package.tgz" "$workDir/inputs/package.tgz" 256; fi
ln -s "$NODE_BIN" "$workDir/private-bin/node"
ln -s "$NPM_BIN" "$workDir/private-bin/npm"
ln -s "$TAR_BIN" "$workDir/private-bin/tar"
chmod 500 "$workDir/inputs" "$workDir/private-bin"
PRIVATE_PATH="$workDir/private-bin"
export PRIVATE_PATH

# A release run fails before executing any candidate or package code when the
# host cannot apply the deny-by-default sandbox profile.
mkdir -m 700 "$workDir/sandbox-probe"
if ! run_untrusted "$workDir/sandbox-probe" /usr/bin/true >/dev/null 2>"$workDir/sandbox-probe/error"; then
  cat "$workDir/sandbox-probe/error" >&2
  echo "error: cannot establish the required untrusted-code filesystem sandbox" >&2
  exit 2
fi

query_tool_version() {
  local name="$1" executable="$2" root="$workDir/tool-versions/$1"
  mkdir -m 700 "$root"
  if ! run_untrusted "$root" "$executable" --version >"$root/stdout" 2>"$root/stderr"; then
    echo "error: $name --version failed in the isolated environment" >&2
    cat "$root/stderr" >&2
    exit 2
  fi
}
query_tool_version claude "$CLAUDE_BIN"
query_tool_version codex "$CODEX_BIN"
query_tool_version pi "$PI_BIN"
query_tool_version cursorAgent "$CURSOR_AGENT_BIN"
query_tool_version node "$NODE_BIN"
query_tool_version npm "$NPM_BIN"
query_tool_version tar "$TAR_BIN"
query_tool_version lean "$LEAN_BIN"
query_tool_version lake "$LAKE_BIN"

"$NODE_BIN" - "$stageDir/admin/HARNESS-VERSIONS.json" "$workDir/tool-versions" \
  claude "$CLAUDE_BIN" codex "$CODEX_BIN" pi "$PI_BIN" \
  cursorAgent "$CURSOR_AGENT_BIN" node "$NODE_BIN" npm "$NPM_BIN" tar "$TAR_BIN" \
  lean "$LEAN_BIN" lake "$LAKE_BIN" <<'NODE'
const { createHash } = require("node:crypto");
const { lstatSync, readFileSync, writeFileSync } = require("node:fs");
const { join } = require("node:path");
const [output, captureRoot, ...pairs] = process.argv.slice(2);
const tools = {};
for (let index = 0; index < pairs.length; index += 2) {
  const name = pairs[index], executable = pairs[index + 1];
  const stat = lstatSync(executable);
  if (!stat.isFile() || stat.isSymbolicLink()) throw new Error(`${name} executable is not a regular file`);
  const stdout = readFileSync(join(captureRoot, name, "stdout"), "utf8");
  const stderr = readFileSync(join(captureRoot, name, "stderr"), "utf8");
  const combined = `${stdout}\n${stderr}`.trim();
  const version = combined.match(/(?:^|[^0-9A-Za-z])v?(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)/m)?.[1];
  if (!version) throw new Error(`${name} --version had no parseable version: ${combined}`);
  tools[name] = {
    executable,
    executableSha256: createHash("sha256").update(readFileSync(executable)).digest("hex"),
    arguments: ["--version"],
    exitStatus: 0,
    stdout,
    stderr,
    parsedVersion: version,
  };
}
writeFileSync(output, `${JSON.stringify({
  schema: "loom.queried-tool-versions.v1",
  queriedAtUtc: new Date().toISOString(),
  tools,
}, null, 2)}\n`, { flag: "wx", mode: 0o400 });
NODE
enforce_required_tool_versions "$stageDir/admin/HARNESS-VERSIONS.json"

CANDIDATE="$workDir/inputs/loom"
candidateSha256="$(sha256_file "$stageDir/snapshots/loom")"
fixtureASha256="$(sha256_file "$stageDir/snapshots/fixture-a.claude.jsonl")"
fixtureBSha256="$(sha256_file "$stageDir/snapshots/fixture-b.claude.jsonl")"
fixtureCSha256="$(sha256_file "$stageDir/snapshots/fixture-c.loom.json")"
fixtureDSha256="$(sha256_file "$stageDir/snapshots/fixture-d.codex.jsonl")"
expectationSha256="$(sha256_file "$stageDir/admin/PI-CONTEXT-EXPECTATION.json")"
verifierSha256="$(sha256_file "$stageDir/admin/PI-VERIFIER.mjs")"
questionnaireSha256="$(sha256_file "$stageDir/review/QUESTIONNAIRE.md")"
protocolSha256="$(sha256_file "$stageDir/admin/PROTOCOL.md")"
preparationScriptSha256="$(sha256_file "$stageDir/admin/PREPARATION-SCRIPT.sh")"
packageSha256="none"
if [[ -n "$PACKAGE_PATH" ]]; then packageSha256="$(sha256_file "$stageDir/snapshots/package.tgz")"; fi

verify_protected_inputs() {
  "$NODE_BIN" - \
    candidate "$candidateSha256" "$stageDir/snapshots/loom" "$workDir/inputs/loom" \
    fixtureA "$fixtureASha256" "$stageDir/snapshots/fixture-a.claude.jsonl" "$workDir/inputs/fixture-a.claude.jsonl" \
    fixtureB "$fixtureBSha256" "$stageDir/snapshots/fixture-b.claude.jsonl" "$workDir/inputs/fixture-b.claude.jsonl" \
    fixtureC "$fixtureCSha256" "$stageDir/snapshots/fixture-c.loom.json" "$workDir/inputs/fixture-c.loom.json" \
    fixtureD "$fixtureDSha256" "$stageDir/snapshots/fixture-d.codex.jsonl" "$workDir/inputs/fixture-d.codex.jsonl" \
    piExpectation "$expectationSha256" "$stageDir/admin/PI-CONTEXT-EXPECTATION.json" "$workDir/inputs/pi-expectation.json" \
    piVerifier "$verifierSha256" "$stageDir/admin/PI-VERIFIER.mjs" "$workDir/inputs/pi-verifier.mjs" \
    questionnaire "$questionnaireSha256" "$stageDir/review/QUESTIONNAIRE.md" - \
    protocol "$protocolSha256" "$stageDir/admin/PROTOCOL.md" - \
    preparationScript "$preparationScriptSha256" "$stageDir/admin/PREPARATION-SCRIPT.sh" - \
    packageTarball "$packageSha256" "${PACKAGE_PATH:+$stageDir/snapshots/package.tgz}" "${PACKAGE_PATH:+$workDir/inputs/package.tgz}" \
    "$stageDir/admin/HARNESS-VERSIONS.json" <<'NODE'
const { createHash } = require("node:crypto");
const { lstatSync, readFileSync } = require("node:fs");
const args = process.argv.slice(2), harnessPath = args.pop();
const hash = (value) => createHash("sha256").update(value).digest("hex");
for (let index = 0; index < args.length; index += 4) {
  const [label, expected, ...paths] = args.slice(index, index + 4);
  if (expected === "none") {
    if (paths.some(Boolean)) throw new Error(`${label} unexpectedly has paths`);
    continue;
  }
  for (const path of paths.filter((value) => value && value !== "-")) {
    const stat = lstatSync(path);
    if (!stat.isFile() || stat.isSymbolicLink() || stat.nlink !== 1 || (stat.mode & 0o222) !== 0) {
      throw new Error(`${label} protected snapshot is writable, linked, or non-regular: ${path}`);
    }
    const actual = hash(readFileSync(path));
    if (actual !== expected) throw new Error(`${label} protected snapshot changed: ${actual} != ${expected}`);
  }
}
const harness = JSON.parse(readFileSync(harnessPath, "utf8"));
for (const name of ["node", "npm", "tar"]) {
  const record = harness.tools[name];
  if (!record || hash(readFileSync(record.executable)) !== record.executableSha256) {
    throw new Error(`${name} executable changed after identity capture`);
  }
}
NODE
}

mkdir -m 700 "$workDir/candidate-version"
if ! run_untrusted "$workDir/candidate-version" "$CANDIDATE" version --json \
    >"$workDir/candidate-version/stdout" 2>"$workDir/candidate-version/stderr"; then
  cat "$workDir/candidate-version/stderr" >&2
  echo "error: candidate version query failed" >&2
  exit 2
fi
VERSION_JSON="$(<"$workDir/candidate-version/stdout")"
"$NODE_BIN" - "$VERSION_JSON" "$HEAD_REVISION" <<'NODE'
const [raw, expectedRevision] = process.argv.slice(2);
const candidate = JSON.parse(raw);
if (candidate.engine !== "lean" || candidate.engineVersion !== "0.2.0-preview.0" ||
    candidate.protocolVersion !== "loom.cli.v1" || candidate.coreRevision !== expectedRevision ||
    candidate.sourceRepository !== "https://github.com/theoriclabs/agent-convert-lean" ||
    candidate.sourcePath !== "spec/loom" || typeof candidate.targetTriple !== "string" ||
    !candidate.targetTriple || !Array.isArray(candidate.wireSchemas) ||
    !candidate.wireSchemas.includes("loom.transcript.v0")) {
  throw new Error(`candidate self-reported identity is ineligible: ${JSON.stringify(candidate)}`);
}
NODE

caseA="$workDir/inputs/fixture-a.claude.jsonl"
caseB="$workDir/inputs/fixture-b.claude.jsonl"
caseC="$workDir/inputs/fixture-c.loom.json"
caseD="$workDir/inputs/fixture-d.codex.jsonl"
mkdir -m 700 "$workDir/derived"

for specification in "A:claude:$caseA" "B:claude:$caseB" "C:loom:$caseC"; do
  IFS=: read -r case_id format input <<<"$specification"
  runRoot="$workDir/inspect-$case_id"
  mkdir -m 700 "$runRoot"
  if ! run_untrusted "$runRoot" "$CANDIDATE" inspect "$format" "$input" \
      >"$runRoot/stdout" 2>"$runRoot/stderr"; then
    cat "$runRoot/stderr" >&2
    echo "error: candidate inspect failed for Case $case_id" >&2
    exit 2
  fi
  snapshot_file "$runRoot/stdout" "$stageDir/review/CASE-$case_id.inspect.txt" 256
done

directRun="$workDir/direct-convert"
mkdir -m 700 "$directRun"
if ! run_untrusted "$directRun" "$CANDIDATE" convert claude loom "$caseA" \
    "$directRun/output.loom.json" --json >"$directRun/summary.json" 2>"$directRun/stderr"; then
  cat "$directRun/stderr" >&2
  echo "error: direct candidate conversion failed" >&2
  exit 2
fi
snapshot_file "$directRun/output.loom.json" "$stageDir/admin/DIRECT-OUTPUT.loom.json" 256
snapshot_file "$directRun/summary.json" "$stageDir/admin/DIRECT-CLI-SUMMARY.json" 256
snapshot_file "$directRun/output.loom.json" "$workDir/derived/direct-output.loom.json" 256

caseDImportRun="$workDir/case-d-import"
mkdir -m 700 "$caseDImportRun"
if ! run_untrusted "$caseDImportRun" "$CANDIDATE" convert codex loom "$caseD" \
    "$caseDImportRun/source.loom.json" --json >"$caseDImportRun/summary.json" 2>"$caseDImportRun/stderr"; then
  cat "$caseDImportRun/stderr" >&2
  echo "error: Case D Codex import failed" >&2
  exit 2
fi
snapshot_file "$caseDImportRun/source.loom.json" "$workDir/derived/case-d.source.loom.json" 256
snapshot_file "$caseDImportRun/summary.json" "$stageDir/admin/CASE-D-CODEX-TO-LOOM-SUMMARY.json" 256
"$NODE_BIN" - "$workDir/derived/case-d.source.loom.json" "$workDir/derived/case-d.review.loom.json" \
  "$EXPECTED_CASE_D_CANONICAL_SHA256" <<'NODE'
const { createHash } = require("node:crypto");
const { readFileSync, writeFileSync } = require("node:fs");
const [inputPath, outputPath, expectedDigest] = process.argv.slice(2);
const transcript = JSON.parse(readFileSync(inputPath, "utf8"));
const sort = (value) => Array.isArray(value) ? value.map(sort)
  : value && typeof value === "object"
    ? Object.fromEntries(Object.keys(value).sort().map((key) => [key, sort(value[key])]))
    : value;
const digest = createHash("sha256").update(JSON.stringify(sort(transcript))).digest("hex");
if (digest !== expectedDigest) {
  throw new Error(`complete normalized Case D structure changed: ${digest} != ${expectedDigest}`);
}
if (transcript.activeLeaf != null && transcript.activeLeaf !== "6") {
  throw new Error(`Case D has an unexpected source active leaf: ${transcript.activeLeaf}`);
}
transcript.activeLeaf = "6";
if (!transcript.env || typeof transcript.env !== "object") throw new Error("Case D environment is missing");
transcript.env.sessionId = "42000000-0000-4000-8000-000000000000";
writeFileSync(outputPath, `${JSON.stringify(transcript)}\n`, { flag: "wx", mode: 0o400 });
NODE
caseDExportRun="$workDir/case-d-export"
mkdir -m 700 "$caseDExportRun"
if ! run_untrusted "$caseDExportRun" "$CANDIDATE" convert loom claude \
    "$workDir/derived/case-d.review.loom.json" "$caseDExportRun/case-d.claude.jsonl" --json \
    --target-cwd /tmp/loom-human-validation-case-d \
    --target-session-id 42000000-0000-4000-8000-000000000000 \
    --target-timestamp 2026-07-20T02:00:00.000Z \
    --target-harness-version "$CLAUDE_TARGET_HARNESS_VERSION" \
    >"$caseDExportRun/summary.json" 2>"$caseDExportRun/stderr"; then
  cat "$caseDExportRun/stderr" >&2
  echo "error: Case D Loom-to-Claude export failed" >&2
  exit 2
fi
snapshot_file "$caseDExportRun/case-d.claude.jsonl" "$workDir/derived/case-d.claude.jsonl" 256
snapshot_file "$caseDExportRun/summary.json" "$stageDir/admin/CASE-D-LOOM-TO-CLAUDE-SUMMARY.json" 256
"$NODE_BIN" - "$stageDir/admin/CASE-D-LOOM-TO-CLAUDE-SUMMARY.json" <<'NODE'
const { readFileSync } = require("node:fs");
const summary = JSON.parse(readFileSync(process.argv[2], "utf8"));
const expected = {
  from: "loom", to: "claude", targetCwd: "/tmp/loom-human-validation-case-d",
  targetSessionId: "42000000-0000-4000-8000-000000000000",
  targetTimestamp: "2026-07-20T02:00:00.000Z", targetHarnessVersion: "2.1.216",
};
for (const [key, value] of Object.entries(expected)) {
  if (summary[key] !== value) throw new Error(`Case D target ${key} is ${JSON.stringify(summary[key])}, expected ${JSON.stringify(value)}`);
}
NODE
caseDInspectRun="$workDir/case-d-inspect"
mkdir -m 700 "$caseDInspectRun"
if ! run_untrusted "$caseDInspectRun" "$CANDIDATE" inspect claude "$workDir/derived/case-d.claude.jsonl" \
    >"$caseDInspectRun/stdout" 2>"$caseDInspectRun/stderr"; then
  cat "$caseDInspectRun/stderr" >&2
  echo "error: Case D Claude inspection failed" >&2
  exit 2
fi
snapshot_file "$caseDInspectRun/stdout" "$stageDir/review/CASE-D.inspect.txt" 256

"$NODE_BIN" - "$stageDir/review" "$HEAD_REVISION" <<'NODE'
const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const [directory, revision] = process.argv.slice(2);
const names = ["CASE-A.inspect.txt", "CASE-B.inspect.txt", "CASE-C.inspect.txt", "CASE-D.inspect.txt"];
const rendered = names.map((name) => readFileSync(join(directory, name), "utf8"));
for (const [index, text] of rendered.entries()) {
  if (!text.includes(`core revision: ${revision}`) || !text.includes("violations: 0")) {
    throw new Error(`${names[index]} is not bound to the candidate revision or has violations`);
  }
}
for (const [index, needle] of [
  [0, "[thinking; signature=present]"],
  [0, "active leaf: 3"],
  [1, "Command\nName: /goal"],
  [1, "Task ID: task-1"],
  [2, "sidechain anchored at entry 2, block 0 (interleaved child)"],
  [3, "active leaf: 6"],
  [3, "disposition: historical/unverified carrier-derived"],
  [3, "it cannot authenticate native Claude execution or compaction"],
]) if (!rendered[index].includes(needle)) {
  throw new Error(`${names[index]} is missing expected evidence: ${needle}`);
}
const historical = rendered[3].match(/^disposition: historical\/unverified carrier-derived$/gm)?.length ?? 0;
const native = rendered[3].match(/^disposition: native$/gm)?.length ?? 0;
if (historical !== 5 || native !== 2) throw new Error(`Case D disposition census changed: ${historical}/${native}`);
const markup = /<\/?[A-Za-z][A-Za-z0-9:_-]*(?:\s+[^<>]*?)?\s*\/?>/g;
for (const [index, text] of rendered.entries()) {
  const match = text.match(markup);
  if (match) throw new Error(`${names[index]} leaks XML/HTML-like markup: ${match[0]}`);
}

NODE

# Build a deterministic Pi artifact from the exact direct output and execute the
# snapshotted official Pi oracle against a clean, precommitted exact context.
piConvertRun="$workDir/pi-convert"
mkdir -m 700 "$piConvertRun"
if ! run_untrusted "$piConvertRun" "$CANDIDATE" convert loom pi "$workDir/derived/direct-output.loom.json" \
  "$piConvertRun/pi-session.jsonl" --json \
  --target-cwd /tmp/agent-convert-human-validation \
  --target-provider deepseek --target-model deepseek-v4-flash \
  --target-session-id 43000000-0000-4000-8000-000000000000 \
  --target-timestamp 2026-07-20T02:00:00.000Z --target-harness-version "$PI_TARGET_HARNESS_VERSION" \
  >"$piConvertRun/summary.json" 2>"$piConvertRun/stderr"; then
  cat "$piConvertRun/stderr" >&2
  echo "error: Pi target conversion failed" >&2
  exit 2
fi
snapshot_file "$piConvertRun/pi-session.jsonl" "$stageDir/snapshots/pi-session.jsonl" 256
snapshot_file "$piConvertRun/pi-session.jsonl" "$workDir/derived/pi-session.jsonl" 256
snapshot_file "$piConvertRun/summary.json" "$stageDir/admin/PI-CONVERSION-SUMMARY.json" 256
"$NODE_BIN" - "$stageDir/admin/PI-CONVERSION-SUMMARY.json" <<'NODE'
const { readFileSync } = require("node:fs");
const summary = JSON.parse(readFileSync(process.argv[2], "utf8"));
const expected = { from: "loom", to: "pi", targetCwd: "/tmp/agent-convert-human-validation",
  targetProvider: "deepseek", targetModel: "deepseek-v4-flash",
  targetSessionId: "43000000-0000-4000-8000-000000000000",
  targetTimestamp: "2026-07-20T02:00:00.000Z", targetHarnessVersion: "0.74.0" };
for (const [key, value] of Object.entries(expected)) {
  if (summary[key] !== value) throw new Error(`Pi target ${key} is ${JSON.stringify(summary[key])}, expected ${JSON.stringify(value)}`);
}
NODE
piVerifyRun="$workDir/pi-verify"
mkdir -m 700 "$piVerifyRun"
if ! run_untrusted "$piVerifyRun" "$NODE_BIN" "$workDir/inputs/pi-verifier.mjs" --release \
  "$workDir/derived/pi-session.jsonl" \
  --expect-context "$workDir/inputs/pi-expectation.json" \
  --source-artifact "$caseA" \
  --candidate-sha256 "$candidateSha256" \
  --package-tarball-sha256 "$packageSha256" \
  --npm-bin "$NPM_BIN" \
  >"$piVerifyRun/receipt.json" 2>"$piVerifyRun/stderr"; then
  cat "$piVerifyRun/stderr" >&2
  echo "error: isolated Pi context verification failed" >&2
  exit 2
fi
snapshot_file "$piVerifyRun/receipt.json" "$stageDir/admin/PI-CONTEXT-VERIFICATION.json" 256

packageMetadata="null"
if [[ -n "$PACKAGE_PATH" ]]; then
  archiveValidation="$workDir/package-archive-validation"
  mkdir -m 700 "$archiveValidation"
  "$NODE_BIN" - "$workDir/inputs/package.tgz" "$archiveValidation" "$VERSION_JSON" "$packageSha256" <<'NODE'
const { createHash } = require("node:crypto");
const { mkdirSync, readFileSync, writeFileSync } = require("node:fs");
const { gunzipSync } = require("node:zlib");
const { join } = require("node:path");
const [tarball, outputRoot, versionRaw, tarballSha256] = process.argv.slice(2);
const hash = (value) => createHash("sha256").update(value).digest("hex");
const compressed = readFileSync(tarball);
if (hash(compressed) !== tarballSha256) throw new Error("package tarball digest changed before archive validation");
if (compressed.length > 128 * 1024 * 1024) throw new Error("package tarball exceeds the 128 MiB compressed limit");
const bytes = gunzipSync(compressed, { maxOutputLength: 512 * 1024 * 1024 });
const decode = (field) => {
  const end = field.indexOf(0);
  const raw = field.subarray(0, end < 0 ? field.length : end);
  const text = raw.toString("utf8");
  if (!Buffer.from(text, "utf8").equals(raw)) throw new Error("tar header contains invalid UTF-8");
  return text;
};
const octal = (field, label) => {
  const value = decode(field).trim();
  if (!/^[0-7]+$/.test(value)) throw new Error(`invalid tar ${label}: ${JSON.stringify(value)}`);
  const parsed = Number.parseInt(value, 8);
  if (!Number.isSafeInteger(parsed) || parsed < 0) throw new Error(`unsafe tar ${label}`);
  return parsed;
};
const parsePax = (data) => {
  const result = Object.create(null);
  const allowedKeys = new Set(["path", "size", "mtime", "atime", "ctime", "uid", "gid", "uname", "gname", "comment"]);
  let offset = 0;
  while (offset < data.length) {
    const space = data.indexOf(0x20, offset);
    if (space < 0) throw new Error("malformed PAX record length");
    const lengthText = data.subarray(offset, space).toString("ascii");
    if (!/^[1-9][0-9]*$/.test(lengthText)) throw new Error("malformed PAX record length");
    const length = Number(lengthText), end = offset + length;
    if (!Number.isSafeInteger(length) || end > data.length || data[end - 1] !== 0x0a) throw new Error("truncated PAX record");
    const rawRecord = data.subarray(space + 1, end - 1), record = rawRecord.toString("utf8");
    if (!Buffer.from(record, "utf8").equals(rawRecord)) throw new Error("PAX record contains invalid UTF-8");
    const equals = record.indexOf("=");
    if (equals < 1) throw new Error("malformed PAX key/value");
    const key = record.slice(0, equals);
    if (!allowedKeys.has(key) || Object.hasOwn(result, key)) throw new Error(`unsupported or duplicate PAX key: ${key}`);
    result[key] = record.slice(equals + 1);
    offset = end;
  }
  return result;
};
const safePath = (value, label) => {
  const name = value.endsWith("/") ? value.slice(0, -1) : value;
  const parts = name.split("/");
  if (!name || name.startsWith("/") || name.includes("\\") ||
      /[\u0000-\u001f\u007f]/.test(name) ||
      parts.some((part) => !part || part === "." || part === "..") ||
      (name !== "package" && !name.startsWith("package/"))) {
    throw new Error(`unsafe ${label}: ${JSON.stringify(value)}`);
  }
  return name;
};
const files = new Map(), members = [], memberNames = new Set();
let offset = 0, zeroBlocks = 0, headerCount = 0, nextPax = {}, globalPax = {};
while (offset + 512 <= bytes.length) {
  const header = bytes.subarray(offset, offset + 512);
  if (header.every((byte) => byte === 0)) {
    zeroBlocks += 1;
    offset += 512;
    if (zeroBlocks === 2) break;
    continue;
  }
  if (zeroBlocks) throw new Error("non-zero tar data after an end marker");
  headerCount += 1;
  if (headerCount > 100000) throw new Error("tar archive has too many headers");
  const magic = header.subarray(257, 263).toString("latin1");
  if (magic !== "ustar\0" && magic !== "ustar ") throw new Error("tar member is not in ustar format");
  const storedChecksum = octal(header.subarray(148, 156), "checksum");
  let checksum = 0;
  for (let index = 0; index < header.length; index += 1) checksum += index >= 148 && index < 156 ? 0x20 : header[index];
  if (checksum !== storedChecksum) throw new Error("tar header checksum mismatch");
  const size = octal(header.subarray(124, 136), "size"), mode = octal(header.subarray(100, 108), "mode");
  if ((mode & ~0o777) !== 0) throw new Error("tar member mode has privileged or unsupported bits");
  const type = String.fromCharCode(header[156] || 0), dataStart = offset + 512, dataEnd = dataStart + size;
  if (dataEnd > bytes.length) throw new Error("truncated tar member");
  const data = bytes.subarray(dataStart, dataEnd);
  const prefix = decode(header.subarray(345, 500)), base = decode(header.subarray(0, 100));
  const headerName = prefix ? `${prefix}/${base}` : base;
  if (type === "x" || type === "g") {
    safePath(headerName, "PAX header path");
    const parsed = parsePax(data);
    if (type === "g") {
      if (Object.keys(nextPax).length) throw new Error("global PAX header cannot interrupt a per-file PAX header");
      if (parsed.path !== undefined || parsed.size !== undefined) throw new Error("global PAX path or size overrides are forbidden");
      globalPax = { ...globalPax, ...parsed };
    } else {
      if (Object.keys(nextPax).length) throw new Error("orphaned per-file PAX header");
      nextPax = parsed;
    }
  } else {
    const attributes = { ...globalPax, ...nextPax };
    nextPax = {};
    if (attributes.size !== undefined &&
        (!/^(?:0|[1-9][0-9]*)$/.test(attributes.size) || Number(attributes.size) !== size)) {
      throw new Error("PAX size disagrees with tar header");
    }
    const rawName = attributes.path ?? headerName;
    const name = safePath(rawName, "package member path");
    if (attributes.linkpath !== undefined || decode(header.subarray(157, 257))) {
      throw new Error(`archive links are forbidden: ${name}`);
    }
    if (memberNames.has(name)) throw new Error(`duplicate package member: ${name}`);
    memberNames.add(name);
    if (type === "0" || type === "\0" || type === "") {
      if (rawName.endsWith("/")) throw new Error(`regular file has a directory path: ${name}`);
      const copy = Buffer.from(data);
      files.set(name, { bytes: copy, mode });
      members.push({ path: name, type: "file", mode, size, sha256: hash(copy) });
    } else if (type === "5") {
      if (size !== 0) throw new Error(`directory member has data: ${name}`);
      members.push({ path: name, type: "directory", mode, size: 0 });
    } else {
      throw new Error(`forbidden tar member type ${JSON.stringify(type)} at ${name}`);
    }
  }
  offset = dataStart + Math.ceil(size / 512) * 512;
}
if (zeroBlocks < 2) throw new Error("tar archive lacks two zero end blocks");
if (Object.keys(nextPax).length) throw new Error("tar archive ends with an orphaned PAX header");
if (!bytes.subarray(offset).every((byte) => byte === 0)) throw new Error("tar archive has trailing non-zero data");
const packageEntry = files.get("package/package.json");
if (!packageEntry) throw new Error("package tarball has no regular package/package.json");
const packageJson = JSON.parse(packageEntry.bytes.toString("utf8"));
const coreVersion = JSON.parse(versionRaw);
const repository = typeof packageJson.repository === "string" ? packageJson.repository : packageJson.repository?.url;
const normalizedRepository = String(repository ?? "").replace(/^git\+/, "").replace(/\.git$/, "");
if (packageJson.name !== "agent-convert" || packageJson.version !== coreVersion.engineVersion ||
    packageJson.license !== "MIT" || normalizedRepository !== "https://github.com/theoriclabs/agent-convert") {
  throw new Error("package name/version/license/repository does not match the release identity");
}
for (const name of ["preinstall", "install", "postinstall"]) {
  if (packageJson.scripts?.[name]) throw new Error(`release package must not define ${name}`);
}
const binPath = packageJson.bin?.["agent-convert"];
if (typeof binPath !== "string" || !binPath || binPath.startsWith("/") || binPath.includes("\\") ||
    binPath.split("/").some((part) => !part || part === "." || part === "..")) {
  throw new Error("package bin.agent-convert is missing or unsafe");
}
const binMember = `package/${binPath}`, binEntry = files.get(binMember);
if (!binEntry || (binEntry.mode & 0o111) === 0) throw new Error("archive public bin is missing, non-regular, or non-executable");
mkdirSync(outputRoot, { recursive: true, mode: 0o700 });
writeFileSync(join(outputRoot, "package.json"), packageEntry.bytes, { flag: "wx", mode: 0o400 });
writeFileSync(join(outputRoot, "public-bin"), binEntry.bytes, { flag: "wx", mode: 0o500 });
writeFileSync(join(outputRoot, "metadata.json"), `${JSON.stringify({
  name: packageJson.name, version: packageJson.version, license: packageJson.license,
  repository: normalizedRepository, tarballSha256, publicBin: binPath, publicBinMember: binMember,
  packedPackageJsonSha256: hash(packageEntry.bytes), packedPublicBinSha256: hash(binEntry.bytes),
  packedPublicBinMode: binEntry.mode, archiveMemberCount: members.length,
  archiveMemberManifestSha256: hash(Buffer.from(JSON.stringify(members))),
}, null, 2)}\n`, { flag: "wx", mode: 0o400 });
NODE
  archiveBinMember="$("$NODE_BIN" -e 'process.stdout.write(require(process.argv[1]).publicBinMember)' "$archiveValidation/metadata.json")"
  "$TAR_BIN" -xOz -f "$workDir/inputs/package.tgz" -- package/package.json >"$archiveValidation/tar-package.json"
  "$TAR_BIN" -xOz -f "$workDir/inputs/package.tgz" -- "$archiveBinMember" >"$archiveValidation/tar-public-bin"
  "$CMP_BIN" -s -- "$archiveValidation/package.json" "$archiveValidation/tar-package.json"
  "$CMP_BIN" -s -- "$archiveValidation/public-bin" "$archiveValidation/tar-public-bin"

  packageWork="$workDir/package-install"
  mkdir -m 700 "$packageWork"
  "$NODE_BIN" -e 'require("node:fs").writeFileSync(process.argv[1], "{\"private\":true}\n", {flag:"wx",mode:0o600})' \
    "$packageWork/package.json"
  : >"$packageWork/user.npmrc"
  : >"$packageWork/global.npmrc"
  if ! run_untrusted "$packageWork" "$NPM_BIN" install --prefix "$packageWork" --ignore-scripts \
      --no-audit --no-fund --omit=optional --save-exact --offline --bin-links=true \
      --userconfig "$packageWork/user.npmrc" --globalconfig "$packageWork/global.npmrc" \
      --cache "$packageWork/cache" --registry https://invalid.invalid \
      "$workDir/inputs/package.tgz" \
      >"$packageWork/npm.stdout" 2>"$packageWork/npm.stderr"; then
    cat "$packageWork/npm.stderr" >&2
    echo "error: isolated npm install failed" >&2
    exit 2
  fi
  "$NODE_BIN" - "$packageWork/npm.stdout" "$packageWork/npm.stderr" "$stageDir/admin/NPM-INSTALL.log" <<'NODE'
const { readFileSync, writeFileSync } = require("node:fs");
const [stdout, stderr, output] = process.argv.slice(2);
writeFileSync(output, `stdout:\n${readFileSync(stdout, "utf8")}stderr:\n${readFileSync(stderr, "utf8")}`, { flag: "wx", mode: 0o400 });
NODE
  snapshot_file "$packageWork/package-lock.json" "$stageDir/admin/PACKAGE-LOCK.json" 256
  packageRoot="$packageWork/node_modules/agent-convert"
  packageShim="$packageWork/node_modules/.bin/agent-convert"
  "$NODE_BIN" - "$archiveValidation" "$packageRoot" "$packageShim" \
    "$stageDir/admin/PACKAGE-METADATA.json" <<'NODE'
const { createHash } = require("node:crypto");
const { lstatSync, readFileSync, readdirSync, realpathSync, writeFileSync } = require("node:fs");
const { join, sep } = require("node:path");
const [archiveValidation, packageRoot, packageShim, outputPath] = process.argv.slice(2);
const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");
function rejectUnsafeInstalledTree(path) {
  const stat = lstatSync(path);
  if (stat.isSymbolicLink()) throw new Error(`installed package contains a symlink: ${path}`);
  if (stat.isDirectory()) {
    for (const name of readdirSync(path).sort()) rejectUnsafeInstalledTree(join(path, name));
  } else if (!stat.isFile() || stat.nlink !== 1) throw new Error(`installed package contains a special or hard-linked file: ${path}`);
}
const packageRootStat = lstatSync(packageRoot);
if (!packageRootStat.isDirectory() || packageRootStat.isSymbolicLink()) {
  throw new Error("installed agent-convert package root is not a real directory");
}
rejectUnsafeInstalledTree(packageRoot);
const archive = JSON.parse(readFileSync(join(archiveValidation, "metadata.json"), "utf8"));
const installedPath = join(packageRoot, "package.json");
const installedBytes = readFileSync(installedPath);
if (!installedBytes.equals(readFileSync(join(archiveValidation, "package.json")))) throw new Error("installed package.json bytes differ from the tar member");
const bin = join(packageRoot, archive.publicBin);
const binStat = lstatSync(bin);
if (!binStat.isFile() || binStat.isSymbolicLink() || binStat.nlink !== 1 || (binStat.mode & 0o111) === 0) {
  throw new Error("installed public agent-convert bin is not a singly linked executable regular file");
}
const realRoot = `${realpathSync(packageRoot)}${sep}`;
if (!realpathSync(bin).startsWith(realRoot)) throw new Error("public bin resolves outside the installed package");
const installedBinBytes = readFileSync(bin);
if (!installedBinBytes.equals(readFileSync(join(archiveValidation, "public-bin")))) throw new Error("installed public bin bytes differ from the tar member");
const shimStat = lstatSync(packageShim);
if (!shimStat.isSymbolicLink() || realpathSync(packageShim) !== realpathSync(bin)) {
  throw new Error("npm bin shim is missing or does not resolve to the installed public bin");
}
const record = {
  ...archive,
  installedPackageJsonSha256: hash(installedBytes),
  installedPublicBinSha256: hash(installedBinBytes),
  npmBinShim: "node_modules/.bin/agent-convert",
  npmBinShimTarget: archive.publicBin,
  lifecycleScriptsSuppressed: true,
};
writeFileSync(outputPath, `${JSON.stringify(record, null, 2)}\n`, { flag: "wx", mode: 0o400 });
NODE
  find "$packageWork" -type f -exec chmod a-w {} +
  find "$packageWork" -type d -exec chmod 500 {} +
  packageRun="$workDir/package-cli-run"
  mkdir -m 700 "$packageRun"
  if ! run_untrusted "$packageRun" "$ENV_BIN" AGENT_CONVERT_LEAN_BIN="$CANDIDATE" LOOM_BIN="$CANDIDATE" \
    "$packageShim" "$caseA" "$packageRun/output.loom.json" \
    --from claude --to loom --core-bin "$CANDIDATE" --json \
    >"$packageRun/stdout.json" 2>"$packageRun/stderr.txt"; then
    cat "$packageRun/stderr.txt" >&2
    echo "error: installed npm bin shim execution failed" >&2
    exit 2
  fi
  snapshot_file "$packageRun/output.loom.json" "$stageDir/admin/PACKAGE-CLI-OUTPUT.loom.json" 256
  snapshot_file "$packageRun/stdout.json" "$stageDir/admin/PACKAGE-CLI-STDOUT.json" 256
  snapshot_file "$packageRun/stderr.txt" "$stageDir/admin/PACKAGE-CLI-STDERR.txt" 256
  if ! "$CMP_BIN" -s -- "$stageDir/admin/PACKAGE-CLI-OUTPUT.loom.json" "$stageDir/admin/DIRECT-OUTPUT.loom.json"; then
    echo "error: packaged public CLI output differs from the exact core output" >&2
    exit 2
  fi
  "$NODE_BIN" - "$stageDir/admin/PACKAGE-CLI-STDOUT.json" "$HEAD_REVISION" <<'NODE'
const { readFileSync } = require("node:fs");
const [path, revision] = process.argv.slice(2);
const result = JSON.parse(readFileSync(path, "utf8"));
if (result.engine !== "lean" || result.coreRevision !== revision || result.from !== "claude" || result.to !== "loom") {
  throw new Error("packaged public CLI did not report the exact Lean candidate and route");
}
NODE
  packageMetadata="$(<"$stageDir/admin/PACKAGE-METADATA.json")"
fi

verify_protected_inputs

"$GIT_BIN" -C "$REPO_ROOT" ls-tree -r --full-tree "$HEAD_REVISION" "$GIT_SOURCE_PATH" \
  >"$stageDir/admin/SOURCE-TREE.txt"
LEAN_VERSION="$("$NODE_BIN" -e 'process.stdout.write(require(process.argv[1]).tools.lean.parsedVersion)' "$stageDir/admin/HARNESS-VERSIONS.json")"
LAKE_VERSION="$("$NODE_BIN" -e 'process.stdout.write(require(process.argv[1]).tools.lake.parsedVersion)' "$stageDir/admin/HARNESS-VERSIONS.json")"
QUERIED_TOOLS="$(<"$stageDir/admin/HARNESS-VERSIONS.json")"
PREPARED_AT="$("$NODE_BIN" -e 'process.stdout.write(new Date().toISOString())')"

"$NODE_BIN" - "$stageDir/admin/ADMIN-PROVENANCE.json" "$VERSION_JSON" "$candidateSha256" \
  "$HEAD_REVISION" "$SOURCE_TREE" "$ROOT_TREE" "$GIT_SOURCE_PATH" "$RUN_ID" "$RUN_NONCE" \
  "$PREPARED_AT" "$LEAN_VERSION" "$LAKE_VERSION" "$QUERIED_TOOLS" \
  "$packageMetadata" "$LOOM_BIN" "$PACKAGE_PATH" "$SANDBOX_EXEC_BIN" <<'NODE'
const { createHash } = require("node:crypto");
const { readFileSync, statSync, writeFileSync } = require("node:fs");
const { dirname, join } = require("node:path");
const [output, versionRaw, candidateSha256, headRevision, sourceTree, rootTree,
  cleanScope, runId, nonce, preparedAtUtc, leanVersion, lakeVersion, queriedToolsRaw,
  packageRaw, originalBinaryPath, originalPackagePath, sandboxExecutable] = process.argv.slice(2);
const candidateVersionClaim = JSON.parse(versionRaw);
const packageMetadata = JSON.parse(packageRaw);
const queriedTools = JSON.parse(queriedToolsRaw);
const preparedRoot = dirname(dirname(output));
const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");
const snapshot = (path) => {
  const bytes = readFileSync(join(preparedRoot, path));
  return { path, sha256: hash(bytes), sizeBytes: bytes.length };
};
const targets = {
  claude: {
    harnessVersion: "2.1.216", cwd: "/tmp/loom-human-validation-case-d",
    sessionId: "42000000-0000-4000-8000-000000000000", timestamp: "2026-07-20T02:00:00.000Z",
  },
  pi: {
    harnessVersion: "0.74.0", cwd: "/tmp/agent-convert-human-validation",
    provider: "deepseek", model: "deepseek-v4-flash",
    sessionId: "43000000-0000-4000-8000-000000000000", timestamp: "2026-07-20T02:00:00.000Z",
  },
};
const inputSnapshots = {
  candidate: snapshot("snapshots/loom"), fixtureA: snapshot("snapshots/fixture-a.claude.jsonl"),
  fixtureB: snapshot("snapshots/fixture-b.claude.jsonl"), fixtureC: snapshot("snapshots/fixture-c.loom.json"),
  fixtureD: snapshot("snapshots/fixture-d.codex.jsonl"),
  piExpectation: snapshot("admin/PI-CONTEXT-EXPECTATION.json"), piVerifier: snapshot("admin/PI-VERIFIER.mjs"),
  questionnaire: snapshot("review/QUESTIONNAIRE.md"), protocol: snapshot("admin/PROTOCOL.md"),
  preparationScript: snapshot("admin/PREPARATION-SCRIPT.sh"),
};
if (packageMetadata !== null) inputSnapshots.packageTarball = snapshot("snapshots/package.tgz");
const record = {
  schema: "loom.human-validation-admin-provenance.v3",
  status: "prepared-not-reviewed",
  runId,
  nonce,
  preparedAtUtc,
  inputSnapshots,
  candidateBinary: {
    originalPath: originalBinaryPath,
    snapshotPath: "snapshots/loom",
    sha256: candidateSha256,
    sizeBytes: statSync(join(preparedRoot, "snapshots", "loom")).size,
  },
  candidateVersionClaim,
  claimBoundary: "The binary self-reports this identity. Matching HEAD and binding the source tree do not prove that HEAD produced the binary.",
  sourceCheckoutCapture: {
    headRevision,
    rootTree,
    loomTree: sourceTree,
    cleanScope,
    statusAtCapture: "clean",
  },
  observedToolchain: { leanVersion, lakeVersion, queriedTools },
  executionIsolation: {
    mechanism: "macOS sandbox-exec deny-default with read-only filesystem and one private writable output root",
    executable: sandboxExecutable,
    executableSha256: hash(readFileSync(sandboxExecutable)),
    networkAccess: "denied",
    environment: "env -i with private HOME, TMPDIR, PATH; NODE_OPTIONS/NODE_PATH/npm config cleared",
  },
  targets,
  packageTarball: packageMetadata === null ? null : {
    originalPath: originalPackagePath,
    snapshotPath: "snapshots/package.tgz",
    sha256: packageMetadata.tarballSha256,
    ...packageMetadata,
  },
  cases: [
    { id: "A", sourceSnapshot: "snapshots/fixture-a.claude.jsonl", route: "inspect claude" },
    { id: "B", sourceSnapshot: "snapshots/fixture-b.claude.jsonl", route: "inspect claude" },
    { id: "C", sourceSnapshot: "snapshots/fixture-c.loom.json", route: "inspect loom" },
    { id: "D", sourceSnapshot: "snapshots/fixture-d.codex.jsonl", route: "codex -> loom -> deterministic review leaf -> claude -> inspect" },
  ],
  piContextEvidence: {
    sourceSnapshot: "snapshots/fixture-a.claude.jsonl",
    loomInput: "admin/DIRECT-OUTPUT.loom.json",
    generatedSession: "snapshots/pi-session.jsonl",
    structuredExpectation: "admin/PI-CONTEXT-EXPECTATION.json",
    verifierResult: "admin/PI-CONTEXT-VERIFICATION.json",
  },
};
writeFileSync(output, `${JSON.stringify(record, null, 2)}\n`, { flag: "wx", mode: 0o400 });
NODE

"$NODE_BIN" - "$stageDir/review/REVIEW-BINDING.json" "$VERSION_JSON" "$candidateSha256" \
  "$RUN_ID" "$RUN_NONCE" "$packageMetadata" "$stageDir/review" <<'NODE'
const { createHash } = require("node:crypto");
const { readFileSync, statSync, writeFileSync } = require("node:fs");
const { join } = require("node:path");
const [output, versionRaw, candidateSha256, runId, nonce, packageRaw, reviewDir] = process.argv.slice(2);
const version = JSON.parse(versionRaw);
const packageMetadata = JSON.parse(packageRaw);
const hash = (path) => createHash("sha256").update(readFileSync(path)).digest("hex");
const targets = {
  claude: { harnessVersion: "2.1.216", cwd: "/tmp/loom-human-validation-case-d",
    sessionId: "42000000-0000-4000-8000-000000000000", timestamp: "2026-07-20T02:00:00.000Z" },
  pi: { harnessVersion: "0.74.0", cwd: "/tmp/agent-convert-human-validation",
    provider: "deepseek", model: "deepseek-v4-flash",
    sessionId: "43000000-0000-4000-8000-000000000000", timestamp: "2026-07-20T02:00:00.000Z" },
};
const record = {
  schema: "loom.human-validation-review-binding.v3",
  status: "prepared-not-reviewed",
  runId,
  nonce,
  candidate: {
    sha256: candidateSha256,
    sizeBytes: statSync(join(reviewDir, "..", "snapshots", "loom")).size,
    coreRevision: version.coreRevision,
    version: version.engineVersion,
    targetTriple: version.targetTriple,
    protocolVersion: version.protocolVersion,
  },
  package: packageMetadata === null ? null : {
    sha256: packageMetadata.tarballSha256,
    name: packageMetadata.name,
    version: packageMetadata.version,
  },
  targets,
  cases: ["A", "B", "C", "D"].map((id) => ({
    id,
    artifact: `CASE-${id}.inspect.txt`,
    sha256: hash(join(reviewDir, `CASE-${id}.inspect.txt`)),
  })),
};
writeFileSync(output, `${JSON.stringify(record, null, 2)}\n`, { flag: "wx", mode: 0o400 });
NODE

validate_provenance_and_binding() {
  "$NODE_BIN" - "$stageDir" "$candidateSha256" "$packageSha256" <<'NODE'
const { createHash } = require("node:crypto");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const [root, candidateSha256, packageSha256] = process.argv.slice(2);
const hash = (value) => createHash("sha256").update(value).digest("hex");
const provenance = JSON.parse(readFileSync(join(root, "admin/ADMIN-PROVENANCE.json"), "utf8"));
const binding = JSON.parse(readFileSync(join(root, "review/REVIEW-BINDING.json"), "utf8"));
if (provenance.schema !== "loom.human-validation-admin-provenance.v3" ||
    binding.schema !== "loom.human-validation-review-binding.v3" ||
    provenance.runId !== binding.runId || provenance.nonce !== binding.nonce ||
    JSON.stringify(provenance.targets) !== JSON.stringify(binding.targets)) {
  throw new Error("administrator provenance and reviewer binding disagree");
}
const expectedTargets = {
  claude: { harnessVersion: "2.1.216", cwd: "/tmp/loom-human-validation-case-d",
    sessionId: "42000000-0000-4000-8000-000000000000", timestamp: "2026-07-20T02:00:00.000Z" },
  pi: { harnessVersion: "0.74.0", cwd: "/tmp/agent-convert-human-validation",
    provider: "deepseek", model: "deepseek-v4-flash",
    sessionId: "43000000-0000-4000-8000-000000000000", timestamp: "2026-07-20T02:00:00.000Z" },
};
if (JSON.stringify(binding.targets) !== JSON.stringify(expectedTargets) ||
    JSON.stringify(provenance.targets) !== JSON.stringify(expectedTargets)) {
  throw new Error("target identities changed before manifest creation");
}
for (const [name, record] of Object.entries(provenance.inputSnapshots)) {
  const bytes = readFileSync(join(root, record.path));
  if (record.sha256 !== hash(bytes) || record.sizeBytes !== bytes.length) throw new Error(`provenance input binding changed: ${name}`);
}
const candidate = readFileSync(join(root, "snapshots/loom"));
if (hash(candidate) !== candidateSha256 || binding.candidate.sha256 !== candidateSha256 ||
    binding.candidate.sizeBytes !== candidate.length) throw new Error("candidate provenance or review binding changed");
for (const item of binding.cases) {
  if (item.sha256 !== hash(readFileSync(join(root, "review", item.artifact)))) throw new Error(`case binding changed: ${item.id}`);
}
if (packageSha256 === "none") {
  if (provenance.packageTarball !== null || binding.package !== null) throw new Error("unexpected package provenance");
} else {
  const tarball = readFileSync(join(root, "snapshots/package.tgz"));
  if (hash(tarball) !== packageSha256 || provenance.packageTarball.sha256 !== packageSha256 ||
      binding.package.sha256 !== packageSha256) throw new Error("package provenance or review binding changed");
  const metadata = JSON.parse(readFileSync(join(root, "admin/PACKAGE-METADATA.json"), "utf8"));
  if (metadata.packedPublicBinSha256 !== metadata.installedPublicBinSha256 ||
      metadata.packedPackageJsonSha256 !== metadata.installedPackageJsonSha256 ||
      metadata.npmBinShim !== "node_modules/.bin/agent-convert") throw new Error("package tar/install/bin derivation proof changed");
}
const claude = JSON.parse(readFileSync(join(root, "admin/CASE-D-LOOM-TO-CLAUDE-SUMMARY.json"), "utf8"));
const pi = JSON.parse(readFileSync(join(root, "admin/PI-CONVERSION-SUMMARY.json"), "utf8"));
if (claude.targetHarnessVersion !== "2.1.216" || pi.targetHarnessVersion !== "0.74.0") {
  throw new Error("target harness identity changed before manifest creation");
}
const piReceipt = JSON.parse(readFileSync(join(root, "admin/PI-CONTEXT-VERIFICATION.json"), "utf8"));
const harness = JSON.parse(readFileSync(join(root, "admin/HARNESS-VERSIONS.json"), "utf8"));
if (piReceipt.candidateSha256 !== candidateSha256 || piReceipt.packageTarballSha256 !== packageSha256 ||
    piReceipt.expectationSha256 !== provenance.inputSnapshots.piExpectation.sha256 ||
    piReceipt.publicBuildSessionContextExportBound !== true ||
    piReceipt.oracleExecutionIsolation !== "node-permission-model-read-only-child" ||
    !/^[0-9a-f]{64}$/.test(piReceipt.oracleRunnerSha256 ?? "") ||
    piReceipt.nodeExecutable?.path !== harness.tools.node.executable ||
    piReceipt.nodeExecutable?.sha256 !== harness.tools.node.executableSha256) {
  throw new Error("Pi verification receipt binding changed");
}
NODE
}

# This is deliberately after every untrusted candidate, npm, shim, and Pi
# execution. Nothing else capable of emitting reviewer bytes runs afterward.
verify_protected_inputs
validate_provenance_and_binding
"$NODE_BIN" - "$stageDir/review" <<'NODE'
const { readFileSync } = require("node:fs");
const { join, relative } = require("node:path");
const directory = process.argv[2];
const names = ["REVIEW-BINDING.json", "CASE-A.inspect.txt", "CASE-B.inspect.txt",
  "CASE-C.inspect.txt", "CASE-D.inspect.txt", "QUESTIONNAIRE.md"];
const forbidden = /[\u0000-\u0008\u000B-\u001F\u007F-\u009F\u202A-\u202E\u2066-\u2069\uFEFF]/;
for (const name of names) {
  const raw = readFileSync(join(directory, name)), text = raw.toString("utf8");
  if (!Buffer.from(text, "utf8").equals(raw)) throw new Error(`${name} is not valid UTF-8`);
  const match = text.match(forbidden);
  if (match) throw new Error(`${name} contains forbidden display control U+${match[0].codePointAt(0).toString(16).toUpperCase()}`);
}
NODE

reviewPayloads=(
  REVIEW-BINDING.json
  CASE-A.inspect.txt
  CASE-B.inspect.txt
  CASE-C.inspect.txt
  CASE-D.inspect.txt
  QUESTIONNAIRE.md
)
(
  cd "$stageDir/review"
  "$SHASUM_BIN" -a 256 -- "${reviewPayloads[@]}" >PREPARATION-MANIFEST.sha256
  "$SHASUM_BIN" -a 256 -c -- PREPARATION-MANIFEST.sha256 >/dev/null
)
printf 'runId=%s\nnonce=%s\n' "$RUN_ID" "$RUN_NONCE" >"$stageDir/PREPARED"

rootPayloads=(
  PREPARED
  review/REVIEW-BINDING.json
  review/CASE-A.inspect.txt
  review/CASE-B.inspect.txt
  review/CASE-C.inspect.txt
  review/CASE-D.inspect.txt
  review/QUESTIONNAIRE.md
  review/PREPARATION-MANIFEST.sha256
  admin/ADMIN-PROVENANCE.json
  admin/PROTOCOL.md
  admin/PREPARATION-SCRIPT.sh
  admin/PI-VERIFIER.mjs
  admin/PI-CONTEXT-EXPECTATION.json
  admin/PI-CONTEXT-VERIFICATION.json
  admin/PI-CONVERSION-SUMMARY.json
  admin/HARNESS-VERSIONS.json
  admin/SOURCE-TREE.txt
  admin/DIRECT-OUTPUT.loom.json
  admin/DIRECT-CLI-SUMMARY.json
  admin/CASE-D-CODEX-TO-LOOM-SUMMARY.json
  admin/CASE-D-LOOM-TO-CLAUDE-SUMMARY.json
  snapshots/loom
  snapshots/fixture-a.claude.jsonl
  snapshots/fixture-b.claude.jsonl
  snapshots/fixture-c.loom.json
  snapshots/fixture-d.codex.jsonl
  snapshots/pi-session.jsonl
)
if [[ -n "$PACKAGE_PATH" ]]; then
  rootPayloads+=(
    admin/PACKAGE-METADATA.json
    admin/PACKAGE-CLI-OUTPUT.loom.json
    admin/PACKAGE-CLI-STDOUT.json
    admin/PACKAGE-CLI-STDERR.txt
    admin/PACKAGE-LOCK.json
    admin/NPM-INSTALL.log
    snapshots/package.tgz
  )
fi
(
  cd "$stageDir"
  "$SHASUM_BIN" -a 256 -- "${rootPayloads[@]}" >ROOT-MANIFEST.sha256
  "$SHASUM_BIN" -a 256 -c -- ROOT-MANIFEST.sha256 >/dev/null
)
verify_prepared_layout "$stageDir" open

# Close permissions before publication. The staging root remains writable only
# long enough to move its fixed children into the atomically reserved target.
find "$stageDir" -type f -exec chmod 400 {} +
chmod 500 "$stageDir/snapshots/loom"
find "$stageDir" -type d -exec chmod 500 {} +

# Re-verify both manifests against the bytes that are about to be sealed. The
# earlier check ran before the permission pass; this one is the last read of the
# staged tree, so nothing that happened during staging goes out unverified.
(
  cd "$stageDir"
  "$SHASUM_BIN" -a 256 -c -- ROOT-MANIFEST.sha256 >/dev/null
)
(
  cd "$stageDir/review"
  "$SHASUM_BIN" -a 256 -c -- PREPARATION-MANIFEST.sha256 >/dev/null
)
verify_protected_inputs
validate_provenance_and_binding
verify_prepared_layout "$stageDir" closed

if ! mkdir -m 700 "$OUTPUT_DIR"; then
  echo "error: could not atomically reserve output directory" >&2
  exit 2
fi
reservedOutput="$OUTPUT_DIR"
chmod 700 "$stageDir" "$stageDir/review" "$stageDir/admin" "$stageDir/snapshots"
mv "$stageDir/review" "$OUTPUT_DIR/review"
mv "$stageDir/admin" "$OUTPUT_DIR/admin"
mv "$stageDir/snapshots" "$OUTPUT_DIR/snapshots"
mv "$stageDir/PREPARED" "$OUTPUT_DIR/PREPARED"
mv "$stageDir/ROOT-MANIFEST.sha256" "$OUTPUT_DIR/ROOT-MANIFEST.sha256"
rmdir "$stageDir"
stageDir=""
find "$OUTPUT_DIR" -type d -exec chmod 500 {} +

FINAL_REAL="$(canonical_dir "$OUTPUT_DIR")"
if [[ "$FINAL_REAL" != "$OUTPUT_DIR" ]]; then
  echo "error: published output resolved to an unexpected path" >&2
  exit 2
fi
(
  cd "$OUTPUT_DIR"
  "$SHASUM_BIN" -a 256 -c -- ROOT-MANIFEST.sha256 >/dev/null
)
(
  cd "$OUTPUT_DIR/review"
  "$SHASUM_BIN" -a 256 -c -- PREPARATION-MANIFEST.sha256 >/dev/null
)
verify_prepared_layout "$OUTPUT_DIR" closed
reservedOutput=""
chmod -R u+w "$workDir"
rm -rf -- "$workDir"
workDir=""
trap - EXIT HUP INT TERM

# The two manifest digests are the roots of the evidence chain. Everything the
# reviewer and administrator later sign is reachable from them, so they are
# printed for transcription into the independent ledger. A checksum file cannot
# contain its own digest, which is why these are reported out of band.
preparationRootSha256="$(sha256_file "$OUTPUT_DIR/ROOT-MANIFEST.sha256")"
reviewManifestSha256="$(sha256_file "$OUTPUT_DIR/review/PREPARATION-MANIFEST.sha256")"

printf 'prepared evidence root: %s\n' "$OUTPUT_DIR"
printf 'blinded reviewer directory: %s/review\n' "$OUTPUT_DIR"
printf 'run id: %s\n' "$RUN_ID"
printf 'nonce: %s\n' "$RUN_NONCE"
printf 'candidate binary sha256: %s\n' "$candidateSha256"
if [[ -n "$PACKAGE_PATH" ]]; then printf 'validated package sha256: %s\n' "$packageSha256"; fi
printf 'preparation root sha256 (ROOT-MANIFEST.sha256): %s\n' "$preparationRootSha256"
printf 'review manifest sha256 (PREPARATION-MANIFEST.sha256): %s\n' "$reviewManifestSha256"
printf 'record both digests, the run id, and the nonce in the independent ledger before handing the review directory over\n'
printf 'status: prepared-not-reviewed (signed independent human review is still required)\n'
printf 'unmet external gates: independent human review; trusted build provenance for the candidate binary\n'
