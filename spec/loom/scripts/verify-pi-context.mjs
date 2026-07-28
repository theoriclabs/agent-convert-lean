#!/usr/bin/env node

import { execFileSync, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  accessSync,
  chmodSync,
  closeSync,
  constants,
  fstatSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  openSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { builtinModules } from "node:module";
import { tmpdir } from "node:os";
import { dirname, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { isDeepStrictEqual } from "node:util";

const EXPECTATION_SCHEMA = "agent-convert.pi-context-expectation.v1";
const RECEIPT_SCHEMA = "agent-convert.pi-context-receipt.v1";
const PI_PACKAGE_NAME = "@earendil-works/pi-coding-agent";
const DEFAULT_PI_VERSION = "0.74.0";
const THIS_FILE = fileURLToPath(import.meta.url);
const DANGEROUS_ENVIRONMENT = /^(?:NODE_OPTIONS|NODE_PATH|NODE_REPL_EXTERNAL_MODULE|DYLD_.*|LD_PRELOAD|LD_LIBRARY_PATH|LD_AUDIT|npm_config_.*|BASH_ENV|ENV)$/i;
const NPM_ROOT_ARGUMENTS = [
  "--userconfig=/dev/null",
  "--globalconfig=/nonexistent-agent-convert-global-npmrc",
  "root",
  "--global",
];
const ORACLE_EXECUTION_ISOLATION = "node-permission-model-read-only-child";
const ORACLE_RUNNER_SOURCE = `import { pathToFileURL } from "node:url";
import { join } from "node:path";

const [oracleRoot, sessionPath] = process.argv.slice(2);
if (!oracleRoot || !sessionPath) throw new Error("oracle runner requires root and session paths");
const manager = await import(pathToFileURL(
  join(oracleRoot, "dist", "core", "session-manager.js"),
).href);
const entries = manager.loadEntriesFromFile(sessionPath);
const context = manager.buildSessionContext(entries.slice(1));
process.stdout.write(JSON.stringify({ entries, context }));
`;

// Every module whose bytes can change the loaded context is hashed on its own
// and inside the closure digest. `node_modules/uuid` is a tree, not a module.
const ORACLE_MODULES = [
  "package.json",
  "dist/index.js",
  "dist/core/session-manager.js",
  "dist/core/messages.js",
  "dist/config.js",
  "dist/utils/child-process.js",
];
const ORACLE_TREES = ["node_modules/uuid"];
const EXECUTED_ORACLE_MODULES = ORACLE_MODULES.filter((path) => path !== "dist/index.js");
const BUILTIN_MODULES = new Set(builtinModules.flatMap((name) => [name, `node:${name}`]));

const EXPECTATION_KEYS = new Set([
  "schema",
  "piPackage",
  "sessionSha256",
  "sourceArtifactSha256",
  "contextSha256",
  "recordsLoaded",
  "sourceToolAssertions",
  "forbiddenNativeToolNames",
  "context",
  "notes",
]);
const PI_PACKAGE_KEYS = new Set([
  "name",
  "version",
  "packageJsonSha256",
  "sessionManagerSha256",
  "oracleClosureSha256",
  "moduleSha256",
]);
const ASSERTION_KEYS = new Set(["pointer", "name", "note"]);

// This verifier decides one question: does the generated session load into
// exactly the expected native Pi context under a pinned oracle. It cannot show
// that the candidate binary or package tarball was built from the revision it
// claims, and it cannot judge readability. Both stay external gates and are
// restated in every receipt so a passing run is not read as more than it is.
const EXTERNAL_GATES = [
  "trusted-build-provenance: candidate and package digests are bound here as inputs, not proven to match their claimed build origin",
  "independent-human-review: readability and migration-audit fitness are decided by a blinded human review, not by this verifier",
];

function fail(message) {
  console.error(`pi-context verification failed: ${message}`);
  process.exit(1);
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

// Deterministic JSON: sorted keys, dropped undefined, rejected non-finite
// numbers. A digest over this text is stable across runtimes and key insertion
// order, so pinning it is a real ordering-sensitive commitment rather than an
// accident of how the oracle happened to build its objects.
function canonicalJson(value, path = "$") {
  if (value === null) return "null";
  const type = typeof value;
  if (type === "boolean" || type === "string") return JSON.stringify(value);
  if (type === "number") {
    if (!Number.isFinite(value)) fail(`${path} is not a finite number`);
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) {
    return `[${value.map((item, index) => canonicalJson(item, `${path}[${index}]`)).join(",")}]`;
  }
  if (type === "object") {
    const keys = Object.keys(value).filter((key) => value[key] !== undefined).sort();
    return `{${keys.map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key], `${path}.${key}`)}`).join(",")}}`;
  }
  return fail(`${path} cannot be canonicalized (${type})`);
}

function requireObject(value, label) {
  if (!value || typeof value !== "object" || Array.isArray(value)) fail(`${label} must be an object`);
  return value;
}

function requireExactKeys(value, allowed, label) {
  requireObject(value, label);
  for (const key of Object.keys(value)) {
    if (!allowed.has(key)) fail(`${label} has unknown key ${JSON.stringify(key)}`);
  }
  return value;
}

function requireNonEmptyStringArray(value, label) {
  if (!Array.isArray(value) || value.length === 0) fail(`${label} must be a non-empty array`);
  for (const [index, item] of value.entries()) {
    if (typeof item !== "string" || item.length === 0) {
      fail(`${label}[${index}] must be a non-empty string`);
    }
  }
  return value;
}

function requireDigest(value, label, { allowNone = false } = {}) {
  if (allowNone && value === "none") return;
  if (!/^[0-9a-f]{64}$/.test(value ?? "")) {
    fail(`${label} must be a lowercase SHA-256 digest${allowNone ? " or 'none'" : ""}`);
  }
}

function parseArgs(argv) {
  const options = {
    expectedUsers: [],
    expectedAssistants: [],
    forbiddenTools: [],
    packageVersion: DEFAULT_PI_VERSION,
    packageVersionExplicit: false,
    release: false,
  };
  const positional = [];
  const seenScalar = new Set();
  const repeatable = new Map([
    ["--expect-user", "expectedUsers"],
    ["--expect-assistant", "expectedAssistants"],
    ["--forbid-tool-name", "forbiddenTools"],
  ]);
  const scalar = new Map([
    ["--package-version", "packageVersion"],
    ["--package-root", "packageRoot"],
    ["--target-provider", "targetProvider"],
    ["--target-model", "targetModel"],
    ["--expect-context", "expectationPath"],
    ["--source-artifact", "sourceArtifactPath"],
    ["--candidate-sha256", "candidateSha256"],
    ["--package-tarball-sha256", "packageTarballSha256"],
    ["--npm-bin", "npmBin"],
  ]);

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--release") {
      options.release = true;
      continue;
    }
    const repeatableKey = repeatable.get(argument);
    const scalarKey = scalar.get(argument);
    if (repeatableKey || scalarKey) {
      const value = argv[index + 1];
      if (value === undefined || value.startsWith("--")) {
        fail(`${argument} requires a value`);
      }
      index += 1;
      if (repeatableKey) options[repeatableKey].push(value);
      else {
        if (seenScalar.has(argument)) fail(`${argument} was supplied more than once`);
        seenScalar.add(argument);
        options[scalarKey] = value;
        if (scalarKey === "packageVersion") options.packageVersionExplicit = true;
      }
    } else if (argument.startsWith("--")) {
      fail(`unknown option ${argument}`);
    } else {
      positional.push(argument);
    }
  }

  if (positional.length !== 1) {
    fail("usage: verify-pi-context.mjs <session.jsonl> [expectation options]");
  }
  for (const [label, values] of [
    ["--expect-user", options.expectedUsers],
    ["--expect-assistant", options.expectedAssistants],
    ["--forbid-tool-name", options.forbiddenTools],
  ]) {
    if (values.some((value) => value.length === 0)) fail(`${label} values must not be empty`);
  }

  if (options.release) {
    if (process.env.PI_PACKAGE_ROOT || options.packageRoot) {
      fail("release mode rejects PI_PACKAGE_ROOT and --package-root overrides");
    }
    if (options.packageVersionExplicit) {
      fail("release mode rejects --package-version; the pinned version comes from --expect-context");
    }
    if (options.expectedUsers.length || options.expectedAssistants.length ||
        options.forbiddenTools.length || options.targetProvider || options.targetModel) {
      fail("release mode accepts only the structured --expect-context oracle");
    }
    for (const [key, flag] of [
      ["expectationPath", "--expect-context"],
      ["sourceArtifactPath", "--source-artifact"],
      ["candidateSha256", "--candidate-sha256"],
      ["packageTarballSha256", "--package-tarball-sha256"],
      ["npmBin", "--npm-bin"],
    ]) {
      if (!options[key]) fail(`release mode requires ${flag}`);
    }
    requireDigest(options.candidateSha256, "--candidate-sha256");
    requireDigest(options.packageTarballSha256, "--package-tarball-sha256", { allowNone: true });
  } else {
    if (!options.targetProvider || !options.targetModel) {
      fail("--target-provider and --target-model are required outside release mode");
    }
    if (options.expectedUsers.length === 0 || options.expectedAssistants.length === 0) {
      fail("at least one non-empty --expect-user and --expect-assistant are required");
    }
  }

  return {
    ...options,
    sessionPath: resolve(positional[0]),
    expectationPath: options.expectationPath && resolve(options.expectationPath),
    sourceArtifactPath: options.sourceArtifactPath && resolve(options.sourceArtifactPath),
  };
}

function cleanEnvironment(extra = {}) {
  return {
    HOME: "/nonexistent-agent-convert-home",
    TMPDIR: tmpdir(),
    PATH: dirname(process.execPath),
    LC_ALL: "C",
    LANG: "C",
    TZ: "UTC",
    ...extra,
  };
}

function resolveExecutable(path, label) {
  const initial = lstatSync(path);
  if (!initial.isFile() && !initial.isSymbolicLink()) {
    fail(`${label} is not a file or executable symlink`);
  }
  const resolved = realpathSync(path);
  const stat = lstatSync(resolved);
  if (!stat.isFile() || stat.isSymbolicLink()) fail(`${label} does not resolve to a regular file`);
  accessSync(resolved, constants.X_OK);
  return resolved;
}

function findExecutable(name) {
  for (const directory of (process.env.PATH ?? "").split(":").filter(Boolean)) {
    const candidate = join(directory, name);
    try {
      return resolveExecutable(candidate, name);
    } catch {
      // Keep searching PATH.
    }
  }
  fail(`cannot resolve executable ${name}`);
}

function globalPackageRoot(npmBin) {
  const globalRoot = execFileSync(npmBin, NPM_ROOT_ARGUMENTS, {
    encoding: "utf8",
    env: cleanEnvironment(),
  }).trim();
  if (!globalRoot) fail("npm root -g returned an empty path");
  return join(realpathSync(globalRoot), "@earendil-works", "pi-coding-agent");
}

function assertRegularFile(path, label) {
  let stat;
  try {
    stat = lstatSync(path);
  } catch (error) {
    fail(`${label} cannot be read: ${error.message}`);
  }
  if (!stat.isFile() || stat.isSymbolicLink()) fail(`${label} must be a regular non-symlink file`);
}

function readOnce(path, label) {
  assertRegularFile(path, label);
  let fd;
  try {
    fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
    const stat = fstatSync(fd);
    if (!stat.isFile() || stat.nlink !== 1) {
      fail(`${label} must be a singly linked regular file`);
    }
    return readFileSync(fd);
  } finally {
    if (fd !== undefined) closeSync(fd);
  }
}

function writeSnapshot(path, bytes) {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  writeFileSync(path, bytes, { flag: "wx", mode: 0o400 });
}

function copyTreeStrict(source, target, root = source) {
  const stat = lstatSync(source);
  if (stat.isSymbolicLink()) fail(`Pi oracle closure contains a symlink: ${relative(root, source)}`);
  if (stat.isDirectory()) {
    mkdirSync(target, { mode: 0o700 });
    for (const name of readdirSync(source).sort()) {
      copyTreeStrict(join(source, name), join(target, name), root);
    }
    return;
  }
  if (!stat.isFile() || stat.nlink !== 1) {
    fail(`Pi oracle closure contains a special or hard-linked file: ${relative(root, source)}`);
  }
  writeFileSync(target, readOnce(source, `Pi oracle file ${relative(root, source)}`), {
    flag: "wx",
    mode: 0o400,
  });
}

function treeDigest(root) {
  const records = [];
  function visit(path) {
    const stat = lstatSync(path);
    const name = relative(root, path).split(sep).join("/") || ".";
    if (stat.isDirectory()) {
      records.push(`d\0${name}\0`);
      for (const child of readdirSync(path).sort()) visit(join(path, child));
    } else if (stat.isFile() && !stat.isSymbolicLink()) {
      records.push(`f\0${name}\0${sha256(readFileSync(path))}\0`);
    } else {
      fail(`oracle snapshot has a forbidden entry: ${name}`);
    }
  }
  visit(root);
  return sha256(records.join("\n"));
}

function snapshotPiOracle(packageRoot, destination) {
  const paths = [...ORACLE_MODULES, ...ORACLE_TREES];
  mkdirSync(destination, { mode: 0o700 });
  for (const path of paths) {
    const source = join(packageRoot, path);
    mkdirSync(dirname(join(destination, path)), { recursive: true, mode: 0o700 });
    try {
      copyTreeStrict(source, join(destination, path), source);
    } catch (error) {
      fail(`cannot snapshot Pi oracle dependency ${path}: ${error.message}`);
    }
  }
  const moduleSha256 = {};
  for (const path of ORACLE_MODULES) {
    moduleSha256[path] = sha256(readFileSync(join(destination, path)));
  }
  return {
    closureSha256: treeDigest(destination),
    moduleSha256,
    packageJsonSha256: moduleSha256["package.json"],
    sessionManagerSha256: moduleSha256["dist/core/session-manager.js"],
  };
}

function moduleSpecifiers(source, label) {
  if (/\bimport\s*\(/.test(source)) {
    fail(`${label} contains a dynamic import; the executable oracle closure is not statically closed`);
  }
  const specifiers = [];
  const pattern = /(?:\bimport\s+(?:[^"']*?\s+from\s+)?|\bexport\s+[^"']*?\s+from\s+)["']([^"']+)["']/g;
  for (const match of source.matchAll(pattern)) specifiers.push(match[1]);
  return specifiers;
}

function validateExecutableOracleClosure(root) {
  const allowed = new Set(EXECUTED_ORACLE_MODULES);
  for (const path of EXECUTED_ORACLE_MODULES.filter((name) => name.endsWith(".js"))) {
    const source = readFileSync(join(root, path), "utf8");
    for (const specifier of moduleSpecifiers(source, path)) {
      if (BUILTIN_MODULES.has(specifier)) continue;
      if (specifier === "uuid" || specifier.startsWith("uuid/")) continue;
      if (!specifier.startsWith(".")) {
        fail(`${path} imports unclosed package ${JSON.stringify(specifier)}`);
      }
      const resolved = relative(root, resolve(dirname(join(root, path)), specifier))
        .split(sep).join("/");
      const normalized = resolved.endsWith(".js") ? resolved : `${resolved}.js`;
      if (!allowed.has(normalized)) {
        fail(`${path} imports ${JSON.stringify(specifier)}, which is absent from the oracle closure`);
      }
    }
  }
}

function validatePublicExportBinding(root) {
  const source = readFileSync(join(root, "dist/index.js"), "utf8");
  const exports = [...source.matchAll(
    /export\s*\{([^}]*)\}\s*from\s*["']\.\/core\/session-manager\.js["']/gs,
  )].flatMap((match) => match[1].split(",").map((name) => name.trim().split(/\s+as\s+/)[0]));
  if (!exports.includes("buildSessionContext")) {
    fail("pinned Pi public index does not re-export buildSessionContext from session-manager.js");
  }
}

function closeTree(root) {
  function visit(path) {
    const stat = lstatSync(path);
    if (stat.isDirectory()) {
      for (const child of readdirSync(path)) visit(join(path, child));
      chmodSync(path, 0o500);
    } else {
      chmodSync(path, 0o400);
    }
  }
  visit(root);
}

function reopenTree(root) {
  function visit(path) {
    const stat = lstatSync(path);
    if (!stat.isDirectory()) return;
    chmodSync(path, 0o700);
    for (const child of readdirSync(path)) visit(join(path, child));
  }
  try {
    visit(root);
  } catch {
    // Cleanup remains best-effort after a verification failure.
  }
}

function runOracleIsolated(scratch, oracleRoot, sessionSnapshot) {
  const runnerPath = join(scratch, "oracle-runner.mjs");
  const runnerBytes = Buffer.from(ORACLE_RUNNER_SOURCE, "utf8");
  const runnerSha256 = sha256(runnerBytes);
  writeSnapshot(runnerPath, runnerBytes);
  const child = spawnSync(process.execPath, [
    "--no-warnings",
    "--permission",
    `--allow-fs-read=${runnerPath}`,
    `--allow-fs-read=${oracleRoot}`,
    `--allow-fs-read=${sessionSnapshot}`,
    runnerPath,
    oracleRoot,
    sessionSnapshot,
  ], {
    cwd: scratch,
    encoding: "utf8",
    env: {
      HOME: scratch,
      TMPDIR: scratch,
      PATH: dirname(process.execPath),
      LANG: "C",
      LC_ALL: "C",
      TZ: "UTC",
    },
    maxBuffer: 64 * 1024 * 1024,
  });
  if (child.error || child.status !== 0) {
    const diagnostic = String(child.error?.message ?? child.stderr ?? "unknown child failure")
      .replace(/[^\x20-\x7e]/g, "?")
      .slice(0, 1000);
    fail(`read-only Pi oracle child failed: ${diagnostic}`);
  }
  let result;
  try {
    result = JSON.parse(child.stdout);
  } catch (error) {
    fail(`read-only Pi oracle child returned invalid JSON: ${error.message}`);
  }
  requireExactKeys(result, new Set(["entries", "context"]), "Pi oracle child result");
  if (!Array.isArray(result.entries)) fail("Pi oracle child entries must be an array");
  if (sha256(readFileSync(runnerPath)) !== runnerSha256) {
    fail("read-only Pi oracle runner changed during execution");
  }
  return {
    entries: result.entries,
    context: result.context,
    runnerPath,
    runnerSha256,
  };
}

function collectText(value, output = []) {
  if (typeof value === "string") output.push(value);
  else if (Array.isArray(value)) for (const item of value) collectText(item, output);
  else if (value && typeof value === "object") {
    if (typeof value.text === "string") output.push(value.text);
    else if (typeof value.content === "string") output.push(value.content);
    else if (Array.isArray(value.content)) collectText(value.content, output);
  }
  return output;
}

function toolNames(messages) {
  const names = [];
  for (const message of messages) {
    if (typeof message?.toolName === "string") names.push(message.toolName);
    if (!Array.isArray(message?.content)) continue;
    for (const block of message.content) {
      if (block?.type === "toolCall" && typeof block.name === "string") names.push(block.name);
    }
  }
  return names;
}

function requireFiniteNumber(object, key, context) {
  if (typeof object?.[key] !== "number" || !Number.isFinite(object[key])) {
    fail(`${context}.${key} must be a finite number`);
  }
}

function validateAssistant(message, index) {
  const context = `context.messages[${index}]`;
  for (const key of ["api", "provider", "model", "stopReason"]) {
    if (typeof message[key] !== "string" || message[key].length === 0) {
      fail(`${context}.${key} must be a non-empty string`);
    }
  }
  requireFiniteNumber(message, "timestamp", context);
  if (!message.usage || typeof message.usage !== "object" || Array.isArray(message.usage)) {
    fail(`${context}.usage must be an object`);
  }
  for (const key of ["input", "output", "cacheRead", "cacheWrite", "totalTokens"]) {
    requireFiniteNumber(message.usage, key, `${context}.usage`);
  }
  if (!message.usage.cost || typeof message.usage.cost !== "object" ||
      Array.isArray(message.usage.cost)) {
    fail(`${context}.usage.cost must be an object`);
  }
  for (const key of ["input", "output", "cacheRead", "cacheWrite", "total"]) {
    requireFiniteNumber(message.usage.cost, key, `${context}.usage.cost`);
  }
}

function parseJsonArtifact(bytes, label) {
  const text = bytes.toString("utf8");
  try {
    return JSON.parse(text);
  } catch {
    const values = [];
    for (const [index, line] of text.split("\n").entries()) {
      if (!line.trim()) continue;
      try {
        values.push(JSON.parse(line));
      } catch (error) {
        fail(`${label} line ${index + 1} is not JSON: ${error.message}`);
      }
    }
    if (!values.length) fail(`${label} contains no JSON records`);
    return values;
  }
}

function jsonPointer(value, pointer) {
  if (pointer === "") return value;
  if (typeof pointer !== "string" || !pointer.startsWith("/")) {
    fail(`invalid JSON pointer ${JSON.stringify(pointer)}`);
  }
  let current = value;
  for (const raw of pointer.slice(1).split("/")) {
    const token = raw.replace(/~1/g, "/").replace(/~0/g, "~");
    if (current == null || !Object.prototype.hasOwnProperty.call(current, token)) {
      fail(`source assertion pointer does not exist: ${pointer}`);
    }
    current = current[token];
  }
  return current;
}

// Shape, oracle identity, and input bindings. Runs before the Pi oracle module
// is imported so a malformed or unbound expectation never reaches dynamic
// import, and so an empty expectation can never be satisfied vacuously.
function validateReleaseExpectation(expectation, identity, bindings) {
  requireExactKeys(expectation, EXPECTATION_KEYS, "expectation");
  if (expectation.schema !== EXPECTATION_SCHEMA) {
    fail(`unexpected expectation schema: ${expectation.schema}`);
  }

  const expectedPackage = requireExactKeys(
    expectation.piPackage, PI_PACKAGE_KEYS, "expectation.piPackage",
  );
  if (expectedPackage.name !== PI_PACKAGE_NAME) {
    fail(`expectation pins Pi package ${JSON.stringify(expectedPackage.name)}, expected ${PI_PACKAGE_NAME}`);
  }
  if (typeof expectedPackage.version !== "string" || expectedPackage.version.length === 0) {
    fail("expectation.piPackage.version must be a non-empty string");
  }
  if (expectedPackage.name !== identity.nameVersion.name ||
      expectedPackage.version !== identity.nameVersion.version) {
    fail("expectation Pi package name/version does not match the installed oracle");
  }
  for (const [key, actual] of [
    ["packageJsonSha256", identity.packageJsonSha256],
    ["sessionManagerSha256", identity.sessionManagerSha256],
    ["oracleClosureSha256", identity.closureSha256],
  ]) {
    requireDigest(expectedPackage[key], `expectation.piPackage.${key}`);
    if (expectedPackage[key] !== actual) fail(`Pi oracle ${key} does not match its pinned value`);
  }
  requireObject(expectedPackage.moduleSha256, "expectation.piPackage.moduleSha256");
  const pinnedModules = Object.keys(expectedPackage.moduleSha256).sort();
  if (!isDeepStrictEqual(pinnedModules, [...ORACLE_MODULES].sort())) {
    fail(`expectation.piPackage.moduleSha256 must pin exactly: ${[...ORACLE_MODULES].sort().join(", ")}`);
  }
  for (const path of ORACLE_MODULES) {
    requireDigest(expectedPackage.moduleSha256[path], `expectation.piPackage.moduleSha256[${path}]`);
    if (expectedPackage.moduleSha256[path] !== identity.moduleSha256[path]) {
      fail(`Pi oracle module ${path} does not match its pinned digest`);
    }
  }

  for (const [key, actual] of [
    ["sessionSha256", bindings.sessionSha256],
    ["sourceArtifactSha256", bindings.sourceArtifactSha256],
  ]) {
    requireDigest(expectation[key], `expectation.${key}`);
    if (expectation[key] !== actual) {
      fail(`expectation.${key} does not match the verified input (${expectation[key]} != ${actual})`);
    }
  }
  requireDigest(expectation.contextSha256, "expectation.contextSha256");

  if (!Array.isArray(expectation.sourceToolAssertions) || expectation.sourceToolAssertions.length === 0) {
    fail("release expectation requires at least one sourceToolAssertions entry");
  }
  for (const [index, assertion] of expectation.sourceToolAssertions.entries()) {
    requireExactKeys(assertion, ASSERTION_KEYS, `expectation.sourceToolAssertions[${index}]`);
    if (typeof assertion.pointer !== "string" || !assertion.pointer.startsWith("/")) {
      fail(`expectation.sourceToolAssertions[${index}].pointer must be a JSON pointer`);
    }
    if (typeof assertion.name !== "string" || assertion.name.length === 0) {
      fail(`expectation.sourceToolAssertions[${index}].name must be a non-empty string`);
    }
  }
  requireNonEmptyStringArray(
    expectation.forbiddenNativeToolNames, "expectation.forbiddenNativeToolNames",
  );

  requireObject(expectation.context, "expectation.context");
  if (!Array.isArray(expectation.context.messages) || expectation.context.messages.length === 0) {
    fail("release expectation.context.messages must be a non-empty array");
  }
  if (!Number.isSafeInteger(expectation.recordsLoaded) || expectation.recordsLoaded < 1) {
    fail("release expectation.recordsLoaded must be a positive safe integer");
  }
}

async function selfTest() {
  const child = spawnSync(process.execPath, [
    THIS_FILE,
    "/does/not/matter",
    "--target-provider", "p",
    "--target-model", "m",
    "--expect-user", "",
    "--expect-assistant", "a",
  ], { encoding: "utf8" });
  if (child.status === 0 || !child.stderr.includes("must not be empty")) {
    throw new Error("empty expectation refusal self-test failed");
  }
  const object = { a: [{ "x/y": { "~z": "Bash" } }] };
  if (jsonPointer(object, "/a/0/x~1y/~0z") !== "Bash") {
    throw new Error("JSON pointer self-test failed");
  }
  if (!isDeepStrictEqual({ messages: [{ role: "user" }] }, { messages: [{ role: "user" }] }) ||
      isDeepStrictEqual({ messages: [{ role: "user" }] }, { messages: [{ role: "assistant" }] })) {
    throw new Error("exact context comparison self-test failed");
  }
  const scratch = realpathSync(mkdtempSync(join(tmpdir(), "agent-convert-pi-self-test-")));
  try {
    const deniedRunner = join(scratch, "write-denial-probe.mjs");
    const deniedTarget = join(scratch, "must-not-exist");
    writeFileSync(deniedRunner,
      `import { writeFileSync } from "node:fs";\nwriteFileSync(${JSON.stringify(deniedTarget)}, "forbidden");\n`,
      { flag: "wx", mode: 0o400 });
    const denied = spawnSync(process.execPath, [
      "--no-warnings", "--permission", `--allow-fs-read=${deniedRunner}`, deniedRunner,
    ], { encoding: "utf8", env: cleanEnvironment() });
    let deniedTargetExists = true;
    try { accessSync(deniedTarget); } catch { deniedTargetExists = false; }
    if (denied.status === 0 || !denied.stderr.includes("ERR_ACCESS_DENIED") || deniedTargetExists) {
      throw new Error(`read-only oracle permission self-test failed: ${denied.stderr}`);
    }

    const sessionPath = join(scratch, "session.jsonl");
    const sourcePath = join(scratch, "source.json");
    const expectationPath = join(scratch, "expectation.json");
    const negativeExpectationPath = join(scratch, "expectation-negative.json");
    const assistant = {
      role: "assistant",
      content: [{ type: "text", text: "historical answer" }],
      api: "loom-history",
      provider: "loom-history",
      model: "foreign-assistant",
      usage: {
        input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
      },
      stopReason: "stop",
      timestamp: 1704067200001,
    };
    const records = [
      { type: "session", version: 3, id: "self-test", timestamp: "2024-01-01T00:00:00.000Z", cwd: "/tmp" },
      { type: "message", id: "u", parentId: null, timestamp: "2024-01-01T00:00:00.000Z",
        message: { role: "user", content: [{ type: "text", text: "source request" }], timestamp: 1704067200000 } },
      { type: "message", id: "a", parentId: "u", timestamp: "2024-01-01T00:00:00.001Z", message: assistant },
      { type: "model_change", id: "m", parentId: "a", timestamp: "2024-01-01T00:00:00.002Z",
        provider: "deepseek", modelId: "deepseek-v4-flash" },
    ];
    const sessionBytes = Buffer.from(`${records.map((record) => JSON.stringify(record)).join("\n")}\n`);
    const sourceBytes = Buffer.from(`${JSON.stringify({ tool: { name: "Bash" } })}\n`);
    writeFileSync(sessionPath, sessionBytes, { flag: "wx", mode: 0o400 });
    writeFileSync(sourcePath, sourceBytes, { flag: "wx", mode: 0o400 });
    const npmBin = findExecutable("npm");
    const packageRoot = realpathSync(globalPackageRoot(npmBin));
    const oracleRoot = join(scratch, "oracle");
    const identity = snapshotPiOracle(packageRoot, oracleRoot);
    validateExecutableOracleClosure(oracleRoot);
    validatePublicExportBinding(oracleRoot);
    closeTree(oracleRoot);
    const packageJson = JSON.parse(readFileSync(join(oracleRoot, "package.json"), "utf8"));
    const oracleExecution = runOracleIsolated(scratch, oracleRoot, sessionPath);
    const { entries, context } = oracleExecution;
    const candidateSha256 = "0".repeat(64);
    const expectation = {
      schema: EXPECTATION_SCHEMA,
      piPackage: {
        name: packageJson.name,
        version: packageJson.version,
        packageJsonSha256: identity.packageJsonSha256,
        sessionManagerSha256: identity.sessionManagerSha256,
        oracleClosureSha256: identity.closureSha256,
        moduleSha256: identity.moduleSha256,
      },
      sessionSha256: sha256(sessionBytes),
      sourceArtifactSha256: sha256(sourceBytes),
      contextSha256: sha256(canonicalJson(context, "context")),
      recordsLoaded: records.length,
      sourceToolAssertions: [{ pointer: "/tool/name", name: "Bash" }],
      forbiddenNativeToolNames: ["Bash"],
      context,
    };
    writeFileSync(expectationPath, `${JSON.stringify(expectation)}\n`, { flag: "wx", mode: 0o400 });
    const env = cleanEnvironment();
    delete env.PI_PACKAGE_ROOT;
    const releaseArgs = [
      THIS_FILE, "--release", sessionPath, "--expect-context", expectationPath,
      "--source-artifact", sourcePath, "--candidate-sha256", candidateSha256,
      "--package-tarball-sha256", "none",
      "--npm-bin", npmBin,
    ];
    const positive = spawnSync(process.execPath, releaseArgs, { encoding: "utf8", env });
    if (positive.status !== 0) throw new Error(`release-mode positive self-test failed: ${positive.stderr}`);
    const receipt = JSON.parse(positive.stdout);
    if (receipt.contextSha256 !== expectation.contextSha256 ||
        receipt.candidateSha256 !== candidateSha256 ||
        receipt.packageTarballSha256 !== "none" ||
        receipt.publicBuildSessionContextExportBound !== true ||
        receipt.oracleExecutionIsolation !== ORACLE_EXECUTION_ISOLATION ||
        receipt.oracleRunnerSha256 !== oracleExecution.runnerSha256 ||
        receipt.publicPackageExportVerified !== undefined ||
        receipt.npmExecutable?.path !== npmBin ||
        !isDeepStrictEqual(receipt.npmExecutable?.arguments, NPM_ROOT_ARGUMENTS) ||
        !/^[0-9a-f]{64}$/.test(receipt.npmExecutable?.sha256 ?? "") ||
        receipt.nodeExecutable?.path !== realpathSync(process.execPath) ||
        receipt.nodeExecutable?.sha256 !== sha256(readFileSync(realpathSync(process.execPath))) ||
        !/^[0-9a-f]{64}$/.test(receipt.receiptSha256 ?? "") ||
        receipt.externalGates?.length !== 2) {
      throw new Error("release-mode receipt binding self-test failed");
    }

    const dangerousEnv = { ...env, NODE_PATH: scratch };
    const dangerous = spawnSync(process.execPath, releaseArgs, { encoding: "utf8", env: dangerousEnv });
    if (dangerous.status === 0 || !dangerous.stderr.includes("rejects dangerous environment variable NODE_PATH")) {
      throw new Error(`release-mode dangerous-environment self-test failed: ${dangerous.stderr}`);
    }

    // Each refusal below is written to a distinct file so a stale positive
    // expectation can never be mistaken for the mutated one.
    const refusals = [
      ["context", (copy) => { copy.context.messages[0].role = "assistant"; },
        "complete ordered Pi context differs"],
      ["context-digest", (copy) => { copy.contextSha256 = "1".repeat(64); },
        "canonical context digest"],
      ["module-digest", (copy) => { copy.piPackage.moduleSha256["dist/config.js"] = "3".repeat(64); },
        "does not match its pinned digest"],
      ["module-set", (copy) => { delete copy.piPackage.moduleSha256["dist/config.js"]; },
        "must pin exactly"],
      ["unknown-key", (copy) => { copy.unexpectedField = true; }, "unknown key"],
      ["empty-context", (copy) => { copy.context.messages = []; }, "non-empty array"],
      ["empty-assertions", (copy) => { copy.sourceToolAssertions = []; },
        "at least one sourceToolAssertions"],
    ];
    for (const [label, mutate, needle] of refusals) {
      const mutatedPath = join(scratch, `expectation-${label}.json`);
      const copy = JSON.parse(JSON.stringify(expectation));
      mutate(copy);
      writeFileSync(mutatedPath, `${JSON.stringify(copy)}\n`, { flag: "wx", mode: 0o400 });
      const mutatedArgs = releaseArgs.map((argument) =>
        argument === expectationPath ? mutatedPath : argument);
      const refused = spawnSync(process.execPath, mutatedArgs, { encoding: "utf8", env });
      if (refused.status === 0 || !refused.stderr.includes(needle)) {
        throw new Error(`release-mode ${label} negative self-test failed: ${refused.stderr}`);
      }
    }

    // Release mode must not accept an operator-chosen Pi version.
    const overridden = spawnSync(process.execPath, [
      ...releaseArgs, "--package-version", packageJson.version,
    ], { encoding: "utf8", env });
    if (overridden.status === 0 || !overridden.stderr.includes("release mode rejects --package-version")) {
      throw new Error("release-mode package-version override self-test failed");
    }
    writeFileSync(negativeExpectationPath, `${JSON.stringify(expectation)}\n`, { flag: "wx", mode: 0o400 });
  } finally {
    reopenTree(join(scratch, "oracle"));
    rmSync(scratch, { recursive: true, force: true });
  }

  // Canonical JSON ignores key order, preserves array order, drops undefined,
  // and refuses values that cannot be committed to a digest.
  if (canonicalJson({ b: 1, a: [2, 3] }) !== canonicalJson({ a: [2, 3], b: 1 })) {
    throw new Error("canonical JSON key-order self-test failed");
  }
  if (canonicalJson({ a: [2, 3] }) === canonicalJson({ a: [3, 2] })) {
    throw new Error("canonical JSON array-order self-test failed");
  }
  if (canonicalJson({ a: undefined, b: 1 }) !== '{"b":1}') {
    throw new Error("canonical JSON undefined-key self-test failed");
  }
  if (EXTERNAL_GATES.length !== 2 ||
      !EXTERNAL_GATES.some((gate) => gate.startsWith("trusted-build-provenance:")) ||
      !EXTERNAL_GATES.some((gate) => gate.startsWith("independent-human-review:"))) {
    throw new Error("external gate disclosure self-test failed");
  }

  console.log("pi-context verifier self-test: ok");
}

if (process.argv.length === 3 && process.argv[2] === "--self-test") {
  await selfTest();
  process.exit(0);
}

const options = parseArgs(process.argv.slice(2));
if (options.release) {
  for (const name of Object.keys(process.env)) {
    if (DANGEROUS_ENVIRONMENT.test(name)) {
      fail(`release mode rejects dangerous environment variable ${name}`);
    }
  }
}
const scratch = realpathSync(mkdtempSync(join(tmpdir(), "agent-convert-pi-oracle-")));
try {
  const sessionBytes = readOnce(options.sessionPath, "session artifact");
  const sessionSnapshot = join(scratch, "session.jsonl");
  writeSnapshot(sessionSnapshot, sessionBytes);
  const sessionSha256 = sha256(sessionBytes);

  let expectation;
  let expectationSha256 = null;
  let sourceBytes;
  let sourceSha256 = null;
  if (options.release) {
    const expectationBytes = readOnce(options.expectationPath, "structured expectation");
    sourceBytes = readOnce(options.sourceArtifactPath, "captured source artifact");
    writeSnapshot(join(scratch, "expectation.json"), expectationBytes);
    writeSnapshot(join(scratch, "source-artifact"), sourceBytes);
    expectationSha256 = sha256(expectationBytes);
    sourceSha256 = sha256(sourceBytes);
    try {
      expectation = JSON.parse(expectationBytes.toString("utf8"));
    } catch (error) {
      fail(`structured expectation is not JSON: ${error.message}`);
    }
  }

  const npmBin = resolveExecutable(options.npmBin ?? findExecutable("npm"), "npm executable");
  const requestedPackageRoot = options.release
    ? globalPackageRoot(npmBin)
    : resolve(options.packageRoot ?? process.env.PI_PACKAGE_ROOT ?? globalPackageRoot(npmBin));
  const requestedPackageStat = lstatSync(requestedPackageRoot);
  if (!requestedPackageStat.isDirectory() || requestedPackageStat.isSymbolicLink()) {
    fail("Pi package root must be a non-symlink directory before realpath resolution");
  }
  const packageRoot = realpathSync(requestedPackageRoot);
  const packageStat = lstatSync(packageRoot);
  if (!packageStat.isDirectory() || packageStat.isSymbolicLink()) {
    fail("Pi package root must be a real directory");
  }
  const oracleRoot = join(scratch, "pi-oracle");
  const oracleIdentity = snapshotPiOracle(packageRoot, oracleRoot);
  validateExecutableOracleClosure(oracleRoot);
  validatePublicExportBinding(oracleRoot);
  const packageJson = JSON.parse(readFileSync(join(oracleRoot, "package.json"), "utf8"));
  if (packageJson.name !== PI_PACKAGE_NAME) fail(`expected Pi package ${PI_PACKAGE_NAME}, found ${packageJson.name}`);
  if (typeof packageJson.version !== "string" || packageJson.version.length === 0) {
    fail("installed Pi package.json declares no version");
  }
  if (!options.release && packageJson.version !== options.packageVersion) {
    fail(`expected Pi ${options.packageVersion}, found ${packageJson.version}`);
  }
  oracleIdentity.nameVersion = { name: packageJson.name, version: packageJson.version };
  if (options.release) {
    validateReleaseExpectation(expectation, oracleIdentity, {
      sessionSha256,
      sourceArtifactSha256: sourceSha256,
      candidateSha256: options.candidateSha256,
      packageTarballSha256: options.packageTarballSha256,
    });
  }

  closeTree(oracleRoot);
  const oracleExecution = runOracleIsolated(scratch, oracleRoot, sessionSnapshot);
  const sourceLines = sessionBytes.toString("utf8").split("\n").filter((line) => line.trim());
  const parsedLines = sourceLines.map((line, index) => {
    try {
      return JSON.parse(line);
    } catch (error) {
      fail(`session line ${index + 1} is not JSON: ${error.message}`);
    }
  });
  const { entries } = oracleExecution;
  if (entries.length !== parsedLines.length) fail(`Pi loaded ${entries.length}/${parsedLines.length} records`);
  if (entries[0]?.type !== "session" || entries[0]?.version !== 3) {
    fail("first record is not a Pi v3 session header");
  }
  const sessionEntries = entries.slice(1);
  const ids = sessionEntries.map((entry) => entry.id);
  if (ids.some((id) => typeof id !== "string" || id.length === 0) || new Set(ids).size !== ids.length) {
    fail("session entry ids must be non-empty and unique");
  }

  const { context } = oracleExecution;
  if (!Array.isArray(context?.messages) || context.messages.length === 0) {
    fail("Pi built an empty context from the session");
  }
  context.messages.forEach((message, index) => {
    if (message?.role === "assistant") validateAssistant(message, index);
  });
  const nativeTools = toolNames(context.messages);
  const contextSha256 = sha256(canonicalJson(context, "context"));
  const publicBuildSessionContextExportBound = true;

  if (options.release) {
    const sourceArtifact = parseJsonArtifact(sourceBytes, "captured source artifact");
    const assertedTools = [];
    for (const [index, assertion] of expectation.sourceToolAssertions.entries()) {
      if (!assertion || typeof assertion.pointer !== "string" ||
          typeof assertion.name !== "string" || assertion.name.length === 0) {
        fail(`sourceToolAssertions[${index}] must contain pointer and non-empty name`);
      }
      const actual = jsonPointer(sourceArtifact, assertion.pointer);
      if (actual !== assertion.name) {
        fail(`source tool assertion ${assertion.pointer} expected ${assertion.name}, found ${JSON.stringify(actual)}`);
      }
      assertedTools.push(assertion.name);
    }
    for (const name of new Set(assertedTools)) {
      if (!expectation.forbiddenNativeToolNames.includes(name)) {
        fail(`source foreign tool ${JSON.stringify(name)} is not forbidden from native context`);
      }
    }
    // Structure and canonical digest together: deep equality alone tolerates a
    // stale pin, and a digest alone gives no diagnosable failure.
    if (!isDeepStrictEqual(context, expectation.context)) {
      fail("complete ordered Pi context differs from the structured expectation");
    }
    if (expectation.contextSha256 !== contextSha256) {
      fail(`canonical context digest ${contextSha256} does not match expectation.contextSha256`);
    }
    for (const forbidden of expectation.forbiddenNativeToolNames) {
      if (nativeTools.includes(forbidden)) fail(`foreign tool ${JSON.stringify(forbidden)} entered native Pi context`);
    }
    if (entries.length !== expectation.recordsLoaded) {
      fail(`Pi loaded ${entries.length} records; exact expectation requires ${expectation.recordsLoaded}`);
    }
  } else {
    if (context.model?.provider !== options.targetProvider || context.model?.modelId !== options.targetModel) {
      fail(`active model is ${JSON.stringify(context.model)}, expected ${options.targetProvider}/${options.targetModel}`);
    }
    const roleText = (role) => context.messages
      .filter((message) => message?.role === role)
      .flatMap((message) => collectText(message.content))
      .join("\n");
    for (const expected of options.expectedUsers) {
      if (!roleText("user").includes(expected)) fail(`user context is missing ${JSON.stringify(expected)}`);
    }
    for (const expected of options.expectedAssistants) {
      if (!roleText("assistant").includes(expected)) fail(`assistant context is missing ${JSON.stringify(expected)}`);
    }
    for (const forbidden of options.forbiddenTools) {
      if (nativeTools.includes(forbidden)) fail(`foreign tool ${JSON.stringify(forbidden)} entered native Pi context`);
    }
  }

  const receipt = {
    receiptSchema: RECEIPT_SCHEMA,
    releaseMode: options.release,
    piPackage: {
      name: packageJson.name,
      version: packageJson.version,
      resolution: options.release ? "npm-global-no-override" : "development",
      packageJsonSha256: oracleIdentity.packageJsonSha256,
      sessionManagerSha256: oracleIdentity.sessionManagerSha256,
      oracleClosureSha256: oracleIdentity.closureSha256,
      moduleSha256: oracleIdentity.moduleSha256,
    },
    npmExecutable: {
      path: npmBin,
      sha256: sha256(readFileSync(npmBin)),
      arguments: NPM_ROOT_ARGUMENTS,
    },
    nodeExecutable: {
      path: realpathSync(process.execPath),
      sha256: sha256(readFileSync(realpathSync(process.execPath))),
    },
    sessionSha256,
    sourceArtifactSha256: sourceSha256,
    expectationSha256,
    candidateSha256: options.candidateSha256 ?? null,
    packageTarballSha256: options.packageTarballSha256 ?? null,
    recordsLoaded: entries.length,
    contextMessages: context.messages.length,
    contextRoles: context.messages.map((message) => message.role),
    contextSha256,
    assistantMessages: context.messages.filter((message) => message.role === "assistant").length,
    nativeToolNames: nativeTools,
    activeModel: context.model,
    exactStructuredExpectationVerified: options.release,
    publicBuildSessionContextExportBound,
    oracleExecutionIsolation: ORACLE_EXECUTION_ISOLATION,
    oracleRunnerSha256: oracleExecution.runnerSha256,
    structuredExpectation: options.release ? {
      recordsLoaded: expectation.recordsLoaded,
      sourceToolAssertions: expectation.sourceToolAssertions,
      forbiddenNativeToolNames: expectation.forbiddenNativeToolNames,
    } : null,
    externalGates: EXTERNAL_GATES,
  };
  if (treeDigest(oracleRoot) !== oracleIdentity.closureSha256) {
    fail("snapshotted Pi oracle closure changed during execution");
  }
  if (sha256(readFileSync(sessionSnapshot)) !== sessionSha256) {
    fail("snapshotted Pi session changed during execution");
  }
  if (sha256(readFileSync(oracleExecution.runnerPath)) !== oracleExecution.runnerSha256) {
    fail("snapshotted read-only Pi oracle runner changed during verification");
  }
  if (options.release && (
    sha256(readFileSync(join(scratch, "expectation.json"))) !== expectationSha256 ||
    sha256(readFileSync(join(scratch, "source-artifact"))) !== sourceSha256
  )) {
    fail("snapshotted release expectation or source artifact changed during execution");
  }
  console.log(JSON.stringify({
    ...receipt,
    receiptSha256: sha256(canonicalJson(receipt, "receipt")),
  }));
} finally {
  reopenTree(join(scratch, "pi-oracle"));
  rmSync(scratch, { recursive: true, force: true });
}
