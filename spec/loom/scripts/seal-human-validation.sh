#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SIGN_NAMESPACE="agent-convert-human-validation"
LEDGER_NAMESPACE="agent-convert-human-validation-ledger"
POLICY_NAMESPACE="agent-convert-human-validation-policy"

usage() {
  cat <<'EOF'
usage:
  seal-human-validation.sh pre-review PREPARED_DIR TRUST_POLICY POLICY_SIGNATURE \
    TRUSTED_POLICY_AUTHORITY_PUBLIC_KEY REVIEWER_PUBLIC_KEY OUTPUT_HANDOFF_DIR

  seal-human-validation.sh review-payload PREPARED_DIR REVIEW_HANDOFF_DIR \
    COMPLETED_QUESTIONNAIRE TRUSTED_POLICY_AUTHORITY_PUBLIC_KEY OUTPUT_PAYLOAD

  seal-human-validation.sh seal PREPARED_DIR REVIEW_HANDOFF_DIR \
    COMPLETED_QUESTIONNAIRE REVIEW_PAYLOAD REVIEW_SIGNATURE LEDGER_RECEIPT \
    LEDGER_SIGNATURE LEDGER_AUTHORITY_PUBLIC_KEY \
    TRUSTED_POLICY_AUTHORITY_PUBLIC_KEY ADMIN_EVALUATION OUTPUT_DIR

  seal-human-validation.sh --self-test

The policy-authority key is a mandatory external trust anchor. Obtain it from a
separately authenticated release-policy channel; a key carried only beside the
evidence is not an independent anchor.
EOF
}

clear_dangerous_environment() {
  local name
  while IFS='=' read -r name _; do
    case "$name" in
      NODE_OPTIONS|NODE_PATH|NODE_REPL_EXTERNAL_MODULE|DYLD_*|LD_PRELOAD|LD_LIBRARY_PATH|LD_AUDIT|[Nn][Pp][Mm]_[Cc][Oo][Nn][Ff][Ii][Gg]_*|BASH_ENV|ENV|CDPATH|TAR_OPTIONS|GZIP|BZIP2) unset "$name" ;;
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
    const first = lstatSync(input);
    if (!first.isFile() && !first.isSymbolicLink()) throw new Error(`not a file or symlink: ${input}`);
    const path = realpathSync(input);
    const stat = lstatSync(path);
    if (!stat.isFile() || stat.isSymbolicLink()) throw new Error(`tool does not resolve to a regular file: ${input}`);
    accessSync(path, constants.X_OK);
    process.stdout.write(path);
  ' "$1"
}

for required_command in shasum ssh-keygen mktemp tar cmp find sort ln; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    echo "error: required command not found: $required_command" >&2
    exit 2
  fi
done
NODE_BIN="$(resolve_tool "$BOOTSTRAP_NODE")"
SHASUM_BIN="$(resolve_tool "$(command -v shasum)")"
SSH_KEYGEN_BIN="$(resolve_tool "$(command -v ssh-keygen)")"
TAR_BIN="$(resolve_tool "$(command -v tar)")"
CMP_BIN="$(resolve_tool "$(command -v cmp)")"

sha256_file() {
  local digest remainder
  IFS=' ' read -r digest remainder < <("$SHASUM_BIN" -a 256 -- "$1")
  printf '%s\n' "$digest"
}

canonical_dir() {
  "$NODE_BIN" -e '
    const { lstatSync, realpathSync } = require("node:fs");
    const input = process.argv[1];
    const before = lstatSync(input);
    if (!before.isDirectory() || before.isSymbolicLink()) throw new Error(`not a non-symlink directory: ${input}`);
    const path = realpathSync(input);
    const after = lstatSync(path);
    if (!after.isDirectory() || after.isSymbolicLink()) throw new Error(`not a real directory: ${path}`);
    process.stdout.write(path);
  ' "$1"
}

snapshot_file() {
  "$NODE_BIN" - "$1" "$2" "$3" <<'NODE'
const { closeSync, constants, fstatSync, lstatSync, openSync, readFileSync, writeFileSync } = require("node:fs");
const [source, target, modeRaw] = process.argv.slice(2);
const before = lstatSync(source);
if (!before.isFile() || before.isSymbolicLink() || before.nlink !== 1) {
  throw new Error(`snapshot source must be a singly linked regular non-symlink file: ${source}`);
}
const fd = openSync(source, constants.O_RDONLY | constants.O_NOFOLLOW);
try {
  const stat = fstatSync(fd);
  if (!stat.isFile() || stat.nlink !== 1) throw new Error(`snapshot source changed type: ${source}`);
  writeFileSync(target, readFileSync(fd), { flag: "wx", mode: Number(modeRaw) });
} finally {
  closeSync(fd);
}
NODE
}

snapshot_tree() {
  "$NODE_BIN" - "$1" "$2" <<'NODE'
const {
  closeSync, constants, fstatSync, lstatSync, mkdirSync, openSync, readFileSync,
  readdirSync, writeFileSync,
} = require("node:fs");
const { join, relative } = require("node:path");
const [sourceRoot, targetRoot] = process.argv.slice(2);
const rootStat = lstatSync(sourceRoot);
if (!rootStat.isDirectory() || rootStat.isSymbolicLink()) {
  throw new Error(`snapshot root must be a non-symlink directory: ${sourceRoot}`);
}
function copy(source, target) {
  const stat = lstatSync(source);
  const name = relative(sourceRoot, source) || ".";
  if (stat.isSymbolicLink()) throw new Error(`symlink forbidden in snapshot source: ${name}`);
  if (stat.isDirectory()) {
    mkdirSync(target, { mode: 0o700 });
    for (const child of readdirSync(source).sort()) copy(join(source, child), join(target, child));
    return;
  }
  if (!stat.isFile() || stat.nlink !== 1) throw new Error(`special or hard-linked source entry: ${name}`);
  const fd = openSync(source, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const opened = fstatSync(fd);
    if (!opened.isFile() || opened.nlink !== 1) throw new Error(`source entry changed type: ${name}`);
    writeFileSync(target, readFileSync(fd), { flag: "wx", mode: 0o400 });
  } finally {
    closeSync(fd);
  }
}
copy(sourceRoot, targetRoot);
NODE
  find "$2" -type d -exec chmod 500 {} +
}

sanitize_text_files() {
  "$NODE_BIN" - "$@" <<'NODE'
const { readFileSync } = require("node:fs");
for (const path of process.argv.slice(2)) {
  const raw = readFileSync(path);
  const text = raw.toString("utf8");
  if (Buffer.compare(Buffer.from(text, "utf8"), raw) !== 0) throw new Error(`${path} is not valid UTF-8`);
  const control = text.match(/[\u0000-\u0008\u000B-\u001F\u007F-\u009F\u202A-\u202E\u2066-\u2069\uFEFF]/);
  if (control) throw new Error(`${path} contains forbidden display control U+${control[0].codePointAt(0).toString(16).toUpperCase()}`);
}
NODE
}

verify_signature() {
  local identity="$1" namespace="$2" key="$3" signature="$4" payload="$5" scratch="$6"
  local allowed="$scratch/allowed-signers.$RANDOM"
  "$NODE_BIN" - "$identity" "$key" "$allowed" <<'NODE'
const { readFileSync, writeFileSync } = require("node:fs");
const [identity, keyPath, output] = process.argv.slice(2);
const text = readFileSync(keyPath, "utf8");
if (text.includes("\r")) throw new Error("SSH public key contains CR characters");
const lines = text.split("\n").filter((line) => line.length > 0);
if (lines.length !== 1) throw new Error("SSH public key must contain exactly one non-empty line");
const match = lines[0].match(/^(ssh-(?:ed25519|rsa)|ecdsa-sha2-nistp(?:256|384|521)) ([A-Za-z0-9+/]+={0,2})(?: .*)?$/);
if (!match) throw new Error("unsupported or malformed SSH public key");
writeFileSync(output, `${identity} ${match[1]} ${match[2]}\n`, { flag: "wx", mode: 0o600 });
NODE
  if ! "$SSH_KEYGEN_BIN" -Y verify -f "$allowed" -I "$identity" -n "$namespace" \
      -s "$signature" <"$payload" >/dev/null; then
    echo "error: invalid $namespace signature" >&2
    exit 2
  fi
  rm -f -- "$allowed"
}

verify_prepared() {
  "$NODE_BIN" - "$1" <<'NODE'
const { createHash } = require("node:crypto");
const { lstatSync, readFileSync, readdirSync } = require("node:fs");
const { dirname, join, relative, sep } = require("node:path");
const root = process.argv[2];
const hash = (value) => createHash("sha256").update(value).digest("hex");
const provenance = JSON.parse(readFileSync(join(root, "admin", "ADMIN-PROVENANCE.json"), "utf8"));
if (provenance.schema !== "loom.human-validation-admin-provenance.v3") throw new Error("unexpected prepared provenance schema");
const withPackage = provenance.packageTarball !== null;
const expectedFiles = new Set([
  "PREPARED", "ROOT-MANIFEST.sha256",
  "review/REVIEW-BINDING.json", "review/CASE-A.inspect.txt", "review/CASE-B.inspect.txt",
  "review/CASE-C.inspect.txt", "review/CASE-D.inspect.txt", "review/QUESTIONNAIRE.md",
  "review/PREPARATION-MANIFEST.sha256",
  "admin/ADMIN-PROVENANCE.json", "admin/PROTOCOL.md", "admin/PREPARATION-SCRIPT.sh",
  "admin/PI-VERIFIER.mjs", "admin/PI-CONTEXT-EXPECTATION.json",
  "admin/PI-CONTEXT-VERIFICATION.json", "admin/PI-CONVERSION-SUMMARY.json",
  "admin/HARNESS-VERSIONS.json", "admin/SOURCE-TREE.txt", "admin/DIRECT-OUTPUT.loom.json",
  "admin/DIRECT-CLI-SUMMARY.json", "admin/CASE-D-CODEX-TO-LOOM-SUMMARY.json",
  "admin/CASE-D-LOOM-TO-CLAUDE-SUMMARY.json",
  "snapshots/loom", "snapshots/fixture-a.claude.jsonl", "snapshots/fixture-b.claude.jsonl",
  "snapshots/fixture-c.loom.json", "snapshots/fixture-d.codex.jsonl", "snapshots/pi-session.jsonl",
]);
if (withPackage) for (const name of [
  "admin/PACKAGE-METADATA.json", "admin/PACKAGE-CLI-OUTPUT.loom.json",
  "admin/PACKAGE-CLI-STDOUT.json", "admin/PACKAGE-CLI-STDERR.txt",
  "admin/PACKAGE-LOCK.json", "admin/NPM-INSTALL.log", "snapshots/package.tgz",
]) expectedFiles.add(name);
const expectedDirs = new Set([".", "review", "admin", "snapshots"]);
const actualFiles = new Set(), actualDirs = new Set();
function walk(path) {
  const stat = lstatSync(path);
  const name = relative(root, path).split(sep).join("/") || ".";
  if (stat.isSymbolicLink()) throw new Error(`symlink forbidden in prepared evidence: ${name}`);
  if ((stat.mode & 0o222) !== 0) throw new Error(`prepared evidence entry is writable: ${name}`);
  if (stat.isDirectory()) {
    actualDirs.add(name);
    for (const child of readdirSync(path).sort()) walk(join(path, child));
  } else if (stat.isFile() && stat.nlink === 1) actualFiles.add(name);
  else throw new Error(`special or hard-linked prepared entry: ${name}`);
}
walk(root);
const sameSet = (actual, expected, label) => {
  const a = [...actual].sort(), e = [...expected].sort();
  if (JSON.stringify(a) !== JSON.stringify(e)) throw new Error(`${label} allowlist mismatch\nactual=${a}\nexpected=${e}`);
};
sameSet(actualFiles, expectedFiles, "prepared file");
sameSet(actualDirs, expectedDirs, "prepared directory");
function verifyManifest(path, expected) {
  const lines = readFileSync(path, "utf8").trimEnd().split("\n");
  const listed = new Set();
  for (const line of lines) {
    const match = line.match(/^([0-9a-f]{64})  ([A-Za-z0-9._/-]+)$/);
    if (!match || listed.has(match[2]) || !expected.has(match[2]) ||
        match[2].startsWith("/") || match[2].split("/").some((part) => !part || part === "." || part === "..")) {
      throw new Error(`malformed, unsafe, duplicate, or unlisted manifest line: ${line}`);
    }
    listed.add(match[2]);
    if (hash(readFileSync(join(dirname(path), match[2]))) !== match[1]) {
      throw new Error(`manifest digest mismatch: ${match[2]}`);
    }
  }
  sameSet(listed, expected, `manifest ${path}`);
}
verifyManifest(join(root, "ROOT-MANIFEST.sha256"),
  new Set([...expectedFiles].filter((name) => name !== "ROOT-MANIFEST.sha256")));
const reviewExpected = new Set([...expectedFiles]
  .filter((name) => name.startsWith("review/") && !name.endsWith("PREPARATION-MANIFEST.sha256"))
  .map((name) => name.slice(7)));
const reviewManifest = join(root, "review", "PREPARATION-MANIFEST.sha256");
const reviewLines = readFileSync(reviewManifest, "utf8").trimEnd().split("\n");
const reviewListed = new Set();
for (const line of reviewLines) {
  const match = line.match(/^([0-9a-f]{64})  ([A-Za-z0-9._-]+)$/);
  if (!match || reviewListed.has(match[2]) || !reviewExpected.has(match[2])) throw new Error(`malformed review manifest line: ${line}`);
  reviewListed.add(match[2]);
  if (hash(readFileSync(join(root, "review", match[2]))) !== match[1]) throw new Error(`review digest mismatch: ${match[2]}`);
}
sameSet(reviewListed, reviewExpected, "review manifest");

const prepared = Object.fromEntries(readFileSync(join(root, "PREPARED"), "utf8").trimEnd().split("\n").map((line) => line.split("=")));
const binding = JSON.parse(readFileSync(join(root, "review", "REVIEW-BINDING.json"), "utf8"));
if (binding.schema !== "loom.human-validation-review-binding.v3" ||
    binding.status !== "prepared-not-reviewed" || provenance.status !== "prepared-not-reviewed" ||
    binding.runId !== provenance.runId || binding.nonce !== provenance.nonce ||
    prepared.runId !== binding.runId || prepared.nonce !== binding.nonce) {
  throw new Error("prepared run, provenance, and review binding disagree");
}
if (!/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(binding.runId) ||
    !/^[0-9a-f]{64}$/.test(binding.nonce)) throw new Error("prepared run id or nonce is malformed");
const requiredInputs = {
  candidate: "snapshots/loom",
  fixtureA: "snapshots/fixture-a.claude.jsonl",
  fixtureB: "snapshots/fixture-b.claude.jsonl",
  fixtureC: "snapshots/fixture-c.loom.json",
  fixtureD: "snapshots/fixture-d.codex.jsonl",
  piExpectation: "admin/PI-CONTEXT-EXPECTATION.json",
  piVerifier: "admin/PI-VERIFIER.mjs",
  questionnaire: "review/QUESTIONNAIRE.md",
  protocol: "admin/PROTOCOL.md",
  preparationScript: "admin/PREPARATION-SCRIPT.sh",
};
if (withPackage) requiredInputs.packageTarball = "snapshots/package.tgz";
if (JSON.stringify(Object.keys(provenance.inputSnapshots).sort()) !== JSON.stringify(Object.keys(requiredInputs).sort())) {
  throw new Error("prepared input snapshot key set changed");
}
for (const [key, path] of Object.entries(requiredInputs)) {
  const bytes = readFileSync(join(root, path));
  const record = provenance.inputSnapshots[key];
  if (record.path !== path || record.sha256 !== hash(bytes) || record.sizeBytes !== bytes.length) {
    throw new Error(`prepared input snapshot binding changed: ${key}`);
  }
}
const candidate = readFileSync(join(root, "snapshots", "loom"));
if (binding.candidate.sha256 !== hash(candidate) || binding.candidate.sizeBytes !== candidate.length) {
  throw new Error("review binding candidate digest or size changed");
}
if (!Array.isArray(binding.cases) || binding.cases.length !== 4 ||
    binding.cases.map((item) => item.id).join("") !== "ABCD") {
  throw new Error("review binding must contain Cases A-D exactly once and in order");
}
for (const item of binding.cases) {
  if (!/^[A-D]$/.test(item.id) || item.artifact !== `CASE-${item.id}.inspect.txt` ||
      item.sha256 !== hash(readFileSync(join(root, "review", item.artifact)))) {
    throw new Error(`review case binding changed: ${JSON.stringify(item)}`);
  }
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
  throw new Error("review target harness identities are not pinned");
}
if ((binding.package === null) !== !withPackage) throw new Error("package presence differs between provenance and binding");
if (withPackage) {
  const packageBytes = readFileSync(join(root, "snapshots", "package.tgz"));
  if (binding.package.sha256 !== hash(packageBytes) ||
      provenance.packageTarball.sha256 !== hash(packageBytes)) throw new Error("package tarball binding changed");
}
NODE
}

validate_policy() {
  "$NODE_BIN" - "$1" "$2" "$3" "$4" <<'NODE'
const { createHash } = require("node:crypto");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const [prepared, policyPath, authorityKeyPath, reviewerKeyPath] = process.argv.slice(2);
const hash = (value) => createHash("sha256").update(value).digest("hex");
const exact = (value, keys, label) => {
  if (!value || typeof value !== "object" || Array.isArray(value) ||
      JSON.stringify(Object.keys(value).sort()) !== JSON.stringify([...keys].sort())) {
    throw new Error(`${label} has the wrong fields`);
  }
};
const policy = JSON.parse(readFileSync(policyPath, "utf8"));
exact(policy, ["schema", "policyId", "runId", "nonce", "issuedAtUtc", "expiresAtUtc",
  "preparedRootManifestSha256", "preparationManifestSha256",
  "policyAuthority", "policyAuthorityPublicKeySha256", "reviewer", "ledger"], "trust policy");
exact(policy.reviewer, ["identity", "role", "publicKeySha256"], "trust policy reviewer");
exact(policy.ledger, ["authority", "publicKeySha256", "origin"], "trust policy ledger");
const binding = JSON.parse(readFileSync(join(prepared, "review", "REVIEW-BINDING.json"), "utf8"));
if (policy.schema !== "loom.human-validation-trust-policy.v1" ||
    typeof policy.policyId !== "string" || !policy.policyId ||
    policy.runId !== binding.runId || policy.nonce !== binding.nonce) throw new Error("trust policy run binding is invalid");
for (const [value, label] of [
  [policy.preparedRootManifestSha256, "prepared root"],
  [policy.preparationManifestSha256, "preparation manifest"],
  [policy.policyAuthorityPublicKeySha256, "policy authority key"],
  [policy.reviewer.publicKeySha256, "reviewer key"],
  [policy.ledger.publicKeySha256, "ledger key"],
]) if (!/^[0-9a-f]{64}$/.test(value)) throw new Error(`${label} digest is malformed`);
if (policy.preparedRootManifestSha256 !== hash(readFileSync(join(prepared, "ROOT-MANIFEST.sha256"))) ||
    policy.preparationManifestSha256 !== hash(readFileSync(join(prepared, "review", "PREPARATION-MANIFEST.sha256"))) ||
    policy.policyAuthorityPublicKeySha256 !== hash(readFileSync(authorityKeyPath)) ||
    policy.reviewer.publicKeySha256 !== hash(readFileSync(reviewerKeyPath))) {
  throw new Error("trust policy does not bind the exact prepared root and registered keys");
}
for (const [value, label] of [[policy.policyAuthority, "policy authority"],
  [policy.reviewer.identity, "reviewer identity"], [policy.reviewer.role, "reviewer role"],
  [policy.ledger.authority, "ledger authority"]]) {
  if (typeof value !== "string" || !value.trim()) throw new Error(`${label} must be non-empty`);
}
if (new Set([policy.policyAuthority, policy.reviewer.identity, policy.ledger.authority]).size !== 3) {
  throw new Error("policy authority, reviewer, and ledger identities must be distinct");
}
const parseUtc = (value, label) => {
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(value ?? "") ||
      new Date(value).toISOString() !== value) throw new Error(`${label} must be an exact UTC timestamp`);
  return Date.parse(value);
};
const issued = parseUtc(policy.issuedAtUtc, "trust policy issuedAtUtc");
const expires = parseUtc(policy.expiresAtUtc, "trust policy expiresAtUtc");
if (!Number.isFinite(issued) || !Number.isFinite(expires) || expires <= issued ||
    issued > Date.now() + 5 * 60 * 1000 || Date.now() >= expires) {
  throw new Error("trust policy timestamps are invalid or expired");
}
const origin = new URL(policy.ledger.origin);
if (origin.protocol !== "https:" || origin.username || origin.password || origin.search || origin.hash) {
  throw new Error("ledger origin must be a credential-free HTTPS URL without query or fragment");
}
NODE
}

verify_handoff() {
  local handoff="$1" prepared="$2" trusted_authority="$3" scratch="$4"
  "$NODE_BIN" - "$handoff" "$prepared" <<'NODE'
const { createHash } = require("node:crypto");
const { lstatSync, readFileSync, readdirSync } = require("node:fs");
const { join } = require("node:path");
const [root, prepared] = process.argv.slice(2);
const hash = (value) => createHash("sha256").update(value).digest("hex");
const preparedNames = ["REVIEW-BINDING.json", "CASE-A.inspect.txt", "CASE-B.inspect.txt",
  "CASE-C.inspect.txt", "CASE-D.inspect.txt", "QUESTIONNAIRE.md", "PREPARATION-MANIFEST.sha256"];
const expected = new Set([...preparedNames, "PRE-REVIEW-RECEIPT.json", "PRE-REVIEW-RECEIPT.json.sig",
  "POLICY-AUTHORITY-PUBLIC-KEY.pub", "REVIEWER-PUBLIC-KEY.pub", "HANDOFF-MANIFEST.sha256"]);
const actual = new Set();
for (const name of readdirSync(root).sort()) {
  const path = join(root, name), stat = lstatSync(path);
  if (stat.isSymbolicLink() || !stat.isFile() || stat.nlink !== 1 || (stat.mode & 0o222) !== 0) {
    throw new Error(`forbidden handoff entry: ${name}`);
  }
  actual.add(name);
}
if ((lstatSync(root).mode & 0o222) !== 0) throw new Error("review handoff directory is writable");
if (JSON.stringify([...actual].sort()) !== JSON.stringify([...expected].sort())) throw new Error("handoff allowlist mismatch");
const listed = new Set();
for (const line of readFileSync(join(root, "HANDOFF-MANIFEST.sha256"), "utf8").trimEnd().split("\n")) {
  const match = line.match(/^([0-9a-f]{64})  ([A-Za-z0-9._-]+)$/);
  if (!match || listed.has(match[2]) || match[2] === "HANDOFF-MANIFEST.sha256" || !expected.has(match[2])) {
    throw new Error(`malformed handoff manifest line: ${line}`);
  }
  listed.add(match[2]);
  if (hash(readFileSync(join(root, match[2]))) !== match[1]) throw new Error(`handoff digest mismatch: ${match[2]}`);
}
const expectedListed = new Set([...expected].filter((name) => name !== "HANDOFF-MANIFEST.sha256"));
if (JSON.stringify([...listed].sort()) !== JSON.stringify([...expectedListed].sort())) throw new Error("handoff manifest allowlist mismatch");
for (const name of preparedNames) {
  if (!readFileSync(join(root, name)).equals(readFileSync(join(prepared, "review", name)))) {
    throw new Error(`handoff changed prepared review bytes: ${name}`);
  }
}
NODE
  if ! "$CMP_BIN" -s -- "$trusted_authority" "$handoff/POLICY-AUTHORITY-PUBLIC-KEY.pub"; then
    echo "error: handoff policy key differs from the externally trusted policy key" >&2
    exit 2
  fi
  verify_signature policy-authority "$POLICY_NAMESPACE" \
    "$handoff/POLICY-AUTHORITY-PUBLIC-KEY.pub" "$handoff/PRE-REVIEW-RECEIPT.json.sig" \
    "$handoff/PRE-REVIEW-RECEIPT.json" "$scratch"
  validate_policy "$prepared" "$handoff/PRE-REVIEW-RECEIPT.json" \
    "$handoff/POLICY-AUTHORITY-PUBLIC-KEY.pub" "$handoff/REVIEWER-PUBLIC-KEY.pub"
  sanitize_text_files "$handoff"/*
}

write_review_payload() {
  local handoff="$1" completed="$2" output="$3" analysis="$4"
  "$NODE_BIN" - "$handoff" "$completed" "$output" "$analysis" <<'NODE'
const { createHash } = require("node:crypto");
const { readFileSync, writeFileSync } = require("node:fs");
const { join } = require("node:path");
const [handoff, completedPath, output, analysisOutput] = process.argv.slice(2);
const hash = (value) => createHash("sha256").update(value).digest("hex");
const completed = readFileSync(completedPath);
const text = completed.toString("utf8");
if (!Buffer.from(text, "utf8").equals(completed)) throw new Error("completed questionnaire is not valid UTF-8");
const binding = JSON.parse(readFileSync(join(handoff, "REVIEW-BINDING.json"), "utf8"));
const policyBytes = readFileSync(join(handoff, "PRE-REVIEW-RECEIPT.json"));
const policy = JSON.parse(policyBytes.toString("utf8"));
const template = readFileSync(join(handoff, "QUESTIONNAIRE.md"));
if (hash(completed) === hash(template)) throw new Error("completed questionnaire is unchanged from the template");

const lines = text.split("\n");
function field(label, within = text) {
  const matches = within.split("\n").filter((line) => line.startsWith(`${label}:`));
  if (matches.length !== 1) throw new Error(`${label} must occur exactly once`);
  const value = matches[0].slice(label.length + 1).trim();
  if (!value || /^\[(?:required|enter|write)/i.test(value)) throw new Error(`${label} is incomplete`);
  return value;
}
function parseUtc(value, label) {
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(value ?? "") ||
      new Date(value).toISOString() !== value) throw new Error(`${label} must be an exact UTC timestamp`);
  return Date.parse(value);
}
const expectedFields = [
  ["Run ID", binding.runId], ["Release nonce", binding.nonce],
  ["Candidate binary SHA-256", binding.candidate.sha256],
  ["Candidate binary size in bytes", String(binding.candidate.sizeBytes)],
  ["Core revision", binding.candidate.coreRevision], ["Candidate version", binding.candidate.version],
  ["Target triple", binding.candidate.targetTriple], ["CLI protocol version", binding.candidate.protocolVersion],
  ["Claude target harness version", binding.targets.claude.harnessVersion],
  ["Pi target harness version", binding.targets.pi.harnessVersion],
  ["Preparation manifest SHA-256", hash(readFileSync(join(handoff, "PREPARATION-MANIFEST.sha256")))],
  ["Preparation root manifest SHA-256", policy.preparedRootManifestSha256],
  ["Pre-review receipt SHA-256", hash(policyBytes)],
  ["Handoff manifest SHA-256", hash(readFileSync(join(handoff, "HANDOFF-MANIFEST.sha256")))],
  ["Policy authority public key SHA-256", policy.policyAuthorityPublicKeySha256],
  ["Reviewer public key SHA-256", policy.reviewer.publicKeySha256],
  ["Ledger origin", policy.ledger.origin],
];
for (const [label, expected] of expectedFields) {
  if (field(label) !== expected) throw new Error(`${label} does not match the signed handoff`);
}
if (binding.package === null) {
  for (const label of ["Package name", "Package version", "Package tarball SHA-256"]) {
    if (field(label) !== "N/A (not supplied)") throw new Error(`${label} must say N/A (not supplied)`);
  }
} else if (field("Package name") !== binding.package.name ||
    field("Package version") !== binding.package.version ||
    field("Package tarball SHA-256") !== binding.package.sha256) {
  throw new Error("package fields do not match the signed handoff");
}

const headings = [...text.matchAll(/^### Answer (\d+)\s*$/gm)];
if (headings.length !== 14 || headings.some((match, index) => Number(match[1]) !== index + 1)) {
  throw new Error("completed questionnaire must contain Answer 1 through Answer 14 exactly once and in order");
}
const answers = headings.map((match, index) => {
  const start = match.index + match[0].length;
  const end = index + 1 < headings.length ? headings[index + 1].index : text.indexOf("\n## Clarification Log", start);
  if (end < 0) throw new Error("completed questionnaire is missing the Clarification Log section");
  const body = text.slice(start, end).trim();
  if (!body || /\[(?:required|enter|write)[^\]]*\]/i.test(body)) throw new Error(`Answer ${index + 1} is incomplete`);
  return body;
});
for (let index = 0; index < 13; index += 1) {
  if (answers[index].replace(/\s+/g, " ").length < 3) throw new Error(`Answer ${index + 1} is incomplete`);
}
const scoreMatches = [...answers[13].matchAll(/^Usability score \(1-5\): ([1-5])$/gm)];
if (scoreMatches.length !== 1) throw new Error("Answer 14 requires exactly one integer Usability score (1-5)");
const explanationMatches = [...answers[13].matchAll(/^Auditability explanation:\s*(\S.+)$/gm)];
if (explanationMatches.length !== 1) throw new Error("Answer 14 requires exactly one auditability explanation");
function listAfter(label, source) {
  const sourceLines = source.split("\n");
  const indexes = sourceLines.map((line, index) => line === `${label}:` ? index : -1).filter((index) => index >= 0);
  if (indexes.length !== 1) throw new Error(`${label} must occur exactly once`);
  const values = [];
  for (let index = indexes[0] + 1; index < sourceLines.length && sourceLines[index].startsWith("- "); index += 1) {
    const value = sourceLines[index].slice(2).trim();
    if (!value) throw new Error(`${label} contains an empty item`);
    values.push(value);
  }
  if (!values.length) throw new Error(`${label} requires '- none' or one or more items`);
  if (values.some((value) => value.toLowerCase() === "none")) {
    if (values.length !== 1) throw new Error(`${label} cannot combine none with other items`);
    return [];
  }
  return values;
}
const blockingAmbiguities = listAfter("Blocking ambiguities", answers[13]);
const nonBlockingAmbiguities = listAfter("Non-blocking ambiguities", answers[13]);

const clarificationStart = text.indexOf("\n## Clarification Log");
const protocolStart = text.indexOf("\n## Protocol Record", clarificationStart);
const attestationStart = text.indexOf("\n## Reviewer Attestation", protocolStart);
if (clarificationStart < 0 || protocolStart < 0 || attestationStart < 0) throw new Error("questionnaire sections are missing or out of order");
const clarificationText = text.slice(clarificationStart, protocolStart);
const countRaw = field("Clarification count", clarificationText);
if (!/^(?:0|[1-9][0-9]*)$/.test(countRaw)) throw new Error("Clarification count must be a non-negative integer");
const clarificationCount = Number(countRaw);
const clarificationHeadings = [...clarificationText.matchAll(/^### Clarification (\d+)\s*$/gm)];
if (clarificationHeadings.length !== clarificationCount ||
    clarificationHeadings.some((match, index) => Number(match[1]) !== index + 1)) {
  throw new Error("Clarification count and numbered clarification blocks disagree");
}
const clarifications = clarificationHeadings.map((match, index) => {
  const start = match.index + match[0].length;
  const end = index + 1 < clarificationHeadings.length ? clarificationHeadings[index + 1].index : clarificationText.length;
  const block = clarificationText.slice(start, end);
  const utcTime = field("UTC time", block);
  parseUtc(utcTime, `Clarification ${index + 1} UTC time`);
  const answerChanged = field("Answer changed (yes or no)", block).toLowerCase();
  if (!new Set(["yes", "no"]).has(answerChanged)) throw new Error(`Clarification ${index + 1} has invalid Answer changed`);
  return {
    number: index + 1, utcTime, question: field("Question", block),
    reviewerRequest: field("Reviewer request", block),
    administratorResponse: field("Administrator response", block), answerChanged,
  };
});
const protocolText = text.slice(protocolStart, attestationStart);
const deviations = listAfter("Protocol deviations", protocolText);
const attestationText = text.slice(attestationStart);
const expectedAttestations = [
  "I received only the allowlisted read-only review handoff.",
  "I did not inspect excluded source, provenance, code, tests, scoring material, binary, or package bytes before finalizing my answers.",
  "I verified the handoff manifest, the externally trusted policy key, the policy signature, the signed preparation-root commitment, and all binding fields before opening a case.",
  "Every answer, ambiguity classification, and usability score is my own observation.",
  "The clarification and protocol-deviation records are complete, including unsolicited administrator comments.",
];
function attestationItems(source) {
  const items = [];
  let current = null;
  const finish = () => {
    if (current) items.push({ checked: current.checked, text: current.parts.join(" ").replace(/\s+/g, " ").trim() });
    current = null;
  };
  for (const line of source.split("\n")) {
    const match = line.match(/^- \[([ xX])\] (.*)$/);
    if (match) {
      finish();
      current = { checked: /[xX]/.test(match[1]), parts: [match[2].trim()] };
    } else if (current && /^\s+\S/.test(line)) current.parts.push(line.trim());
    else finish();
  }
  finish();
  return items;
}
const attestationItemsFound = attestationItems(attestationText);
if (attestationItemsFound.length !== 5 || attestationItemsFound.some((item) => !item.checked)) {
  throw new Error("all five reviewer attestations must be checked");
}
if (JSON.stringify(attestationItemsFound.map((item) => item.text)) !== JSON.stringify(expectedAttestations)) {
  throw new Error("reviewer attestation text differs from the required statements");
}
const reviewer = field("Reviewer name", attestationText);
const reviewerRole = field("Reviewer role and team", attestationText);
const administrator = field("Administrator name", attestationText);
if (reviewer !== policy.reviewer.identity || reviewerRole !== policy.reviewer.role) {
  throw new Error("reviewer identity or role does not match the signed trust policy");
}
if (administrator === reviewer) throw new Error("administrator and reviewer identities must be distinct");
const reviewStartedAtUtc = field("Review started at (UTC)", attestationText);
const reviewCompletedAtUtc = field("Review completed at (UTC)", attestationText);
const started = parseUtc(reviewStartedAtUtc, "Review started at (UTC)");
const completedAt = parseUtc(reviewCompletedAtUtc, "Review completed at (UTC)");
const policyIssued = parseUtc(policy.issuedAtUtc, "policy issuedAtUtc");
const policyExpires = parseUtc(policy.expiresAtUtc, "policy expiresAtUtc");
if (completedAt < started || started < policyIssued || completedAt > policyExpires ||
    completedAt > Date.now() + 5 * 60 * 1000) {
  throw new Error("review timestamps are invalid or predate the signed pre-review receipt");
}
for (const clarification of clarifications) {
  const at = parseUtc(clarification.utcTime, `Clarification ${clarification.number} UTC time`);
  if (at < started || at > completedAt) throw new Error(`Clarification ${clarification.number} is outside the review interval`);
}
const independence = field("Independence from implementation (yes or explain)", attestationText);
const blinding = field("Blinding remained intact until answers were final (yes or explain)", attestationText);
field("Reviewer signature", attestationText);
const attestationDate = field("Attestation date (UTC)", attestationText);
if (!/^\d{4}-\d{2}-\d{2}$/.test(attestationDate) ||
    attestationDate !== new Date(completedAt).toISOString().slice(0, 10)) {
  throw new Error("Attestation date (UTC) must be the review completion date in YYYY-MM-DD form");
}

const analysis = {
  reviewer, reviewerRole, administrator, reviewStartedAtUtc, reviewCompletedAtUtc,
  independenceSatisfied: independence.toLowerCase() === "yes",
  blindingSatisfied: blinding.toLowerCase() === "yes",
  usabilityScore: Number(scoreMatches[0][1]), blockingAmbiguities, nonBlockingAmbiguities,
  clarifications, deviations,
};
const payload = [
  "schema=loom.human-validation-review-signature.v2",
  `runId=${binding.runId}`, `nonce=${binding.nonce}`,
  `preparedRootManifestSha256=${policy.preparedRootManifestSha256}`,
  `preparationManifestSha256=${policy.preparationManifestSha256}`,
  `preReviewReceiptSha256=${hash(policyBytes)}`,
  `handoffManifestSha256=${hash(readFileSync(join(handoff, "HANDOFF-MANIFEST.sha256")))}`,
  `completedQuestionnaireSha256=${hash(completed)}`,
  `reviewerPublicKeySha256=${policy.reviewer.publicKeySha256}`,
  `policyAuthorityPublicKeySha256=${policy.policyAuthorityPublicKeySha256}`,
  `ledgerPublicKeySha256=${policy.ledger.publicKeySha256}`,
  `ledgerOrigin=${policy.ledger.origin}`, "",
].join("\n");
writeFileSync(output, payload, { flag: "wx", mode: 0o400 });
writeFileSync(analysisOutput, `${JSON.stringify(analysis, null, 2)}\n`, { flag: "wx", mode: 0o400 });
NODE
}

validate_receipt_and_evaluation() {
  "$NODE_BIN" - "$1" "$2" "$3" "$4" "$5" "$6" <<'NODE'
const { createHash } = require("node:crypto");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const [handoff, payloadPath, ledgerKeyPath, receiptPath, evaluationPath, analysisPath] = process.argv.slice(2);
const hash = (value) => createHash("sha256").update(value).digest("hex");
const policy = JSON.parse(readFileSync(join(handoff, "PRE-REVIEW-RECEIPT.json"), "utf8"));
const binding = JSON.parse(readFileSync(join(handoff, "REVIEW-BINDING.json"), "utf8"));
const analysis = JSON.parse(readFileSync(analysisPath, "utf8"));
const receipt = JSON.parse(readFileSync(receiptPath, "utf8"));
const exactKeys = (value, keys, label) => {
  if (!value || typeof value !== "object" || Array.isArray(value) ||
      JSON.stringify(Object.keys(value).sort()) !== JSON.stringify([...keys].sort())) throw new Error(`${label} has the wrong fields`);
};
const parseUtc = (value, label) => {
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(value ?? "") ||
      new Date(value).toISOString() !== value) throw new Error(`${label} must be an exact UTC timestamp`);
  return Date.parse(value);
};
exactKeys(receipt, ["schema", "runId", "nonce", "reviewSigningPayloadSha256",
  "reviewerPublicKeySha256", "preparedRootManifestSha256", "preReviewReceiptSha256",
  "ledgerAuthority", "publishedAtUtc", "entryId", "ledgerUrl"], "ledger receipt");
if (receipt.schema !== "loom.human-validation-ledger-receipt.v2" ||
    receipt.runId !== binding.runId || receipt.nonce !== binding.nonce ||
    receipt.reviewSigningPayloadSha256 !== hash(readFileSync(payloadPath)) ||
    receipt.reviewerPublicKeySha256 !== policy.reviewer.publicKeySha256 ||
    receipt.preparedRootManifestSha256 !== policy.preparedRootManifestSha256 ||
    receipt.preReviewReceiptSha256 !== hash(readFileSync(join(handoff, "PRE-REVIEW-RECEIPT.json"))) ||
    receipt.ledgerAuthority !== policy.ledger.authority ||
    hash(readFileSync(ledgerKeyPath)) !== policy.ledger.publicKeySha256) {
  throw new Error("ledger receipt does not bind the signed policy, review payload, and registered ledger key");
}

if (typeof receipt.entryId !== "string" || !receipt.entryId.trim()) throw new Error("ledger receipt entryId is missing");
const origin = new URL(policy.ledger.origin), ledgerUrl = new URL(receipt.ledgerUrl);
const originPath = origin.pathname.endsWith("/") ? origin.pathname : `${origin.pathname}/`;
if (ledgerUrl.protocol !== "https:" || ledgerUrl.origin !== origin.origin ||
    !(ledgerUrl.pathname === origin.pathname || ledgerUrl.pathname.startsWith(originPath)) ||
    ledgerUrl.username || ledgerUrl.password || ledgerUrl.search || ledgerUrl.hash) {
  throw new Error("ledger receipt URL is outside the policy ledger origin");
}
const published = parseUtc(receipt.publishedAtUtc, "ledger receipt publishedAtUtc");
const reviewCompleted = parseUtc(analysis.reviewCompletedAtUtc, "signed review completion time");
const policyExpires = parseUtc(policy.expiresAtUtc, "policy expiresAtUtc");
if (published < reviewCompleted || published > policyExpires || published > Date.now() + 5 * 60 * 1000) {
  throw new Error("ledger receipt publication must follow review completion and cannot be future-dated");
}

const evaluation = JSON.parse(readFileSync(evaluationPath, "utf8"));
exactKeys(evaluation, ["schema", "runId", "decision", "evaluationStartedAtUtc", "evaluatedAtUtc",
  "reviewer", "administrator", "factualScore", "usabilityScore", "ambiguities", "clarifications",
  "deviations", "questionEvaluations"], "administrator evaluation");
if (evaluation.schema !== "loom.human-validation-admin-evaluation.v2" || evaluation.runId !== binding.runId ||
    !["pass", "fail", "invalid"].includes(evaluation.decision)) throw new Error("administrator evaluation schema, run, or decision is invalid");
const evaluationStarted = parseUtc(evaluation.evaluationStartedAtUtc, "evaluationStartedAtUtc");
const evaluated = parseUtc(evaluation.evaluatedAtUtc, "evaluatedAtUtc");
if (evaluationStarted < published || evaluated < evaluationStarted ||
    evaluated > Date.now() + 5 * 60 * 1000) throw new Error("administrator evaluation must occur after ledger publication");
if (evaluation.reviewer !== analysis.reviewer || evaluation.administrator !== analysis.administrator) {
  throw new Error("evaluation identities differ from the signed questionnaire");
}
if (!Array.isArray(evaluation.questionEvaluations) || evaluation.questionEvaluations.length !== 14) {
  throw new Error("evaluation requires exactly 14 question evaluations");
}
for (const [index, item] of evaluation.questionEvaluations.entries()) {
  exactKeys(item, ["question", "status", "rationale"], `questionEvaluations[${index}]`);
  if (item.question !== index + 1 || !["pass", "fail"].includes(item.status) ||
      typeof item.rationale !== "string" || !item.rationale.trim()) throw new Error(`question ${index + 1} evaluation is incomplete`);
}
const factualScore = evaluation.questionEvaluations.slice(0, 13).filter((item) => item.status === "pass").length;
if (evaluation.factualScore !== factualScore || !Number.isInteger(evaluation.factualScore)) {
  throw new Error("factualScore must equal the pass count for questions 1-13");
}
if (evaluation.usabilityScore !== analysis.usabilityScore) throw new Error("usabilityScore differs from the signed answer 14 score");
const expectedAmbiguities = [
  ...analysis.blockingAmbiguities.map((text) => ({ kind: "blocking", text })),
  ...analysis.nonBlockingAmbiguities.map((text) => ({ kind: "non-blocking", text })),
];
if (JSON.stringify(evaluation.ambiguities) !== JSON.stringify(expectedAmbiguities) ||
    JSON.stringify(evaluation.deviations) !== JSON.stringify(analysis.deviations)) {
  throw new Error("evaluation ambiguity or deviation record differs from the signed questionnaire");
}
if (!Array.isArray(evaluation.clarifications) || evaluation.clarifications.length !== analysis.clarifications.length) {
  throw new Error("evaluation clarification record differs from the signed questionnaire");
}
for (const [index, item] of evaluation.clarifications.entries()) {
  exactKeys(item, ["number", "utcTime", "question", "reviewerRequest", "administratorResponse",
    "answerChanged", "permitted", "assessment"], `clarifications[${index}]`);
  const source = analysis.clarifications[index];
  for (const key of ["number", "utcTime", "question", "reviewerRequest", "administratorResponse", "answerChanged"]) {
    if (item[key] !== source[key]) throw new Error(`clarification ${index + 1} differs from the signed questionnaire`);
  }
  if (typeof item.permitted !== "boolean" || typeof item.assessment !== "string" || !item.assessment.trim()) {
    throw new Error(`clarification ${index + 1} lacks an administrator policy assessment`);
  }
}
const q14Pass = analysis.usabilityScore >= 4 && analysis.blockingAmbiguities.length === 0;
if ((evaluation.questionEvaluations[13].status === "pass") !== q14Pass) {
  throw new Error("question 14 status is inconsistent with score and blocking ambiguities");
}
const valid = analysis.independenceSatisfied && analysis.blindingSatisfied &&
  analysis.deviations.length === 0 && evaluation.clarifications.every((item) => item.permitted);
const threshold = factualScore === 13 && q14Pass;
const expectedDecision = !valid ? "invalid" : threshold ? "pass" : "fail";
if (evaluation.decision !== expectedDecision) {
  throw new Error(`evaluation decision ${evaluation.decision} is inconsistent; expected ${expectedDecision}`);
}
NODE
}

resolve_new_output() {
  local resolved parent name
  resolved="$("$NODE_BIN" -e 'process.stdout.write(require("node:path").resolve(process.argv[1]))' "$1")"
  parent="$(dirname "$resolved")"
  name="$(basename "$resolved")"
  if [[ "$name" == "." || "$name" == ".." || "$name" == "/" || "$name" == -* || ! "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "error: invalid output name: $name" >&2
    exit 2
  fi
  mkdir -p "$parent"
  parent="$(canonical_dir "$parent")"
  resolved="$parent/$name"
  if [[ -e "$resolved" || -L "$resolved" ]]; then
    echo "error: output already exists: $resolved" >&2
    exit 2
  fi
  printf '%s\n' "$resolved"
}

ACTIVE_TEMP=""
ACTIVE_STAGE=""
ACTIVE_RESERVED=""
ACTIVE_ARCHIVE=""
ACTIVE_CHECKSUM=""
cleanup_active() {
  local path
  for path in "$ACTIVE_STAGE" "$ACTIVE_TEMP" "$ACTIVE_RESERVED"; do
    if [[ -n "$path" && -d "$path" ]]; then
      chmod -R u+w "$path" 2>/dev/null || true
      rm -rf -- "$path"
    fi
  done
  for path in "$ACTIVE_ARCHIVE" "$ACTIVE_CHECKSUM"; do
    if [[ -n "$path" && -f "$path" ]]; then
      chmod u+w "$path" 2>/dev/null || true
      rm -f -- "$path"
    fi
  done
}
trap cleanup_active EXIT HUP INT TERM

make_handoff() {
  local prepared_source="$1" policy_source="$2" policy_signature_source="$3"
  local authority_source="$4" reviewer_source="$5" output_arg="$6"
  local output policy_allowed names name
  output="$(resolve_new_output "$output_arg")"
  ACTIVE_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/loom-pre-review-inputs.XXXXXX")"
  chmod 700 "$ACTIVE_TEMP"
  snapshot_tree "$prepared_source" "$ACTIVE_TEMP/prepared"
  snapshot_file "$policy_source" "$ACTIVE_TEMP/policy.json" 256
  snapshot_file "$policy_signature_source" "$ACTIVE_TEMP/policy.sig" 256
  snapshot_file "$authority_source" "$ACTIVE_TEMP/policy-authority.pub" 256
  snapshot_file "$reviewer_source" "$ACTIVE_TEMP/reviewer.pub" 256
  verify_prepared "$ACTIVE_TEMP/prepared"
  sanitize_text_files "$ACTIVE_TEMP/policy.json" "$ACTIVE_TEMP/policy.sig" \
    "$ACTIVE_TEMP/policy-authority.pub" "$ACTIVE_TEMP/reviewer.pub"
  verify_signature policy-authority "$POLICY_NAMESPACE" "$ACTIVE_TEMP/policy-authority.pub" \
    "$ACTIVE_TEMP/policy.sig" "$ACTIVE_TEMP/policy.json" "$ACTIVE_TEMP"
  validate_policy "$ACTIVE_TEMP/prepared" "$ACTIVE_TEMP/policy.json" \
    "$ACTIVE_TEMP/policy-authority.pub" "$ACTIVE_TEMP/reviewer.pub"

  ACTIVE_STAGE="$(mktemp -d "$(dirname "$output")/.$(basename "$output").stage.XXXXXX")"
  chmod 700 "$ACTIVE_STAGE"
  names=(REVIEW-BINDING.json CASE-A.inspect.txt CASE-B.inspect.txt CASE-C.inspect.txt \
    CASE-D.inspect.txt QUESTIONNAIRE.md PREPARATION-MANIFEST.sha256)
  for name in "${names[@]}"; do
    snapshot_file "$ACTIVE_TEMP/prepared/review/$name" "$ACTIVE_STAGE/$name" 256
  done
  snapshot_file "$ACTIVE_TEMP/policy.json" "$ACTIVE_STAGE/PRE-REVIEW-RECEIPT.json" 256
  snapshot_file "$ACTIVE_TEMP/policy.sig" "$ACTIVE_STAGE/PRE-REVIEW-RECEIPT.json.sig" 256
  snapshot_file "$ACTIVE_TEMP/policy-authority.pub" "$ACTIVE_STAGE/POLICY-AUTHORITY-PUBLIC-KEY.pub" 256
  snapshot_file "$ACTIVE_TEMP/reviewer.pub" "$ACTIVE_STAGE/REVIEWER-PUBLIC-KEY.pub" 256
  (
    cd "$ACTIVE_STAGE"
    "$SHASUM_BIN" -a 256 -- "${names[@]}" PRE-REVIEW-RECEIPT.json \
      PRE-REVIEW-RECEIPT.json.sig POLICY-AUTHORITY-PUBLIC-KEY.pub REVIEWER-PUBLIC-KEY.pub \
      >HANDOFF-MANIFEST.sha256
  )
  chmod 400 "$ACTIVE_STAGE"/*
  chmod 500 "$ACTIVE_STAGE"
  verify_handoff "$ACTIVE_STAGE" "$ACTIVE_TEMP/prepared" "$ACTIVE_TEMP/policy-authority.pub" "$ACTIVE_TEMP"

  if ! mkdir -m 700 "$output"; then
    echo "error: could not atomically reserve review handoff" >&2
    exit 2
  fi
  ACTIVE_RESERVED="$output"
  find "$ACTIVE_STAGE" -type d -exec chmod 700 {} +
  mv "$ACTIVE_STAGE"/* "$output/"
  rmdir "$ACTIVE_STAGE"
  ACTIVE_STAGE=""
  chmod 500 "$output"
  verify_handoff "$output" "$ACTIVE_TEMP/prepared" "$ACTIVE_TEMP/policy-authority.pub" "$ACTIVE_TEMP"
  chmod -R u+w "$ACTIVE_TEMP"
  rm -rf -- "$ACTIVE_TEMP"
  ACTIVE_TEMP=""
  ACTIVE_RESERVED=""
  printf 'review handoff: %s\npre-review receipt sha256: %s\n' \
    "$output" "$(sha256_file "$output/PRE-REVIEW-RECEIPT.json")"
}

make_review_payload() {
  local prepared_source="$1" handoff_source="$2" completed_source="$3" authority_source="$4" output_arg="$5"
  local output
  output="$(resolve_new_output "$output_arg")"
  ACTIVE_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/loom-review-payload-inputs.XXXXXX")"
  chmod 700 "$ACTIVE_TEMP"
  snapshot_tree "$prepared_source" "$ACTIVE_TEMP/prepared"
  snapshot_tree "$handoff_source" "$ACTIVE_TEMP/handoff"
  snapshot_file "$completed_source" "$ACTIVE_TEMP/completed.md" 256
  snapshot_file "$authority_source" "$ACTIVE_TEMP/trusted-policy-authority.pub" 256
  verify_prepared "$ACTIVE_TEMP/prepared"
  verify_handoff "$ACTIVE_TEMP/handoff" "$ACTIVE_TEMP/prepared" \
    "$ACTIVE_TEMP/trusted-policy-authority.pub" "$ACTIVE_TEMP"
  sanitize_text_files "$ACTIVE_TEMP/completed.md"
  write_review_payload "$ACTIVE_TEMP/handoff" "$ACTIVE_TEMP/completed.md" \
    "$ACTIVE_TEMP/payload.txt" "$ACTIVE_TEMP/review-analysis.json"
  ACTIVE_CHECKSUM="$output"
  snapshot_file "$ACTIVE_TEMP/payload.txt" "$output" 292
  chmod 444 "$output"
  "$NODE_BIN" - "$output" <<'NODE'
const { lstatSync } = require("node:fs");
const stat = lstatSync(process.argv[2]);
if (!stat.isFile() || stat.isSymbolicLink() || stat.nlink !== 1 || (stat.mode & 0o222) !== 0) {
  throw new Error("published review payload is writable, linked, or non-regular");
}
NODE
  if ! "$CMP_BIN" -s -- "$ACTIVE_TEMP/payload.txt" "$output"; then
    echo "error: published review payload bytes changed" >&2
    exit 2
  fi
  chmod -R u+w "$ACTIVE_TEMP"
  rm -rf -- "$ACTIVE_TEMP"
  ACTIVE_TEMP=""
  ACTIVE_CHECKSUM=""
  printf '%s\n' "$output"
}

seal_evidence() {
  local prepared_source="$1" handoff_source="$2" completed_source="$3" payload_source="$4"
  local review_signature_source="$5" receipt_source="$6" ledger_signature_source="$7"
  local ledger_key_source="$8" authority_source="$9" evaluation_source="${10}" output_arg="${11}"
  local output archive archive_tmp checksum_tmp file
  output="$(resolve_new_output "$output_arg")"
  archive="$output.evidence.tgz"
  if [[ -e "$archive" || -L "$archive" || -e "$archive.sha256" || -L "$archive.sha256" ]]; then
    echo "error: evidence archive path already exists" >&2
    exit 2
  fi
  ACTIVE_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/loom-seal-inputs.XXXXXX")"
  chmod 700 "$ACTIVE_TEMP"
  snapshot_tree "$prepared_source" "$ACTIVE_TEMP/prepared"
  snapshot_tree "$handoff_source" "$ACTIVE_TEMP/handoff"
  snapshot_file "$completed_source" "$ACTIVE_TEMP/completed.md" 256
  snapshot_file "$payload_source" "$ACTIVE_TEMP/review-payload.txt" 256
  snapshot_file "$review_signature_source" "$ACTIVE_TEMP/review-signature" 256
  snapshot_file "$receipt_source" "$ACTIVE_TEMP/ledger-receipt.json" 256
  snapshot_file "$ledger_signature_source" "$ACTIVE_TEMP/ledger-receipt.sig" 256
  snapshot_file "$ledger_key_source" "$ACTIVE_TEMP/ledger-authority.pub" 256
  snapshot_file "$authority_source" "$ACTIVE_TEMP/trusted-policy-authority.pub" 256
  snapshot_file "$evaluation_source" "$ACTIVE_TEMP/admin-evaluation.json" 256

  verify_prepared "$ACTIVE_TEMP/prepared"
  verify_handoff "$ACTIVE_TEMP/handoff" "$ACTIVE_TEMP/prepared" \
    "$ACTIVE_TEMP/trusted-policy-authority.pub" "$ACTIVE_TEMP"
  sanitize_text_files "$ACTIVE_TEMP/completed.md" "$ACTIVE_TEMP/review-payload.txt" \
    "$ACTIVE_TEMP/review-signature" "$ACTIVE_TEMP/ledger-receipt.json" \
    "$ACTIVE_TEMP/ledger-receipt.sig" "$ACTIVE_TEMP/ledger-authority.pub" \
    "$ACTIVE_TEMP/trusted-policy-authority.pub" "$ACTIVE_TEMP/admin-evaluation.json"
  write_review_payload "$ACTIVE_TEMP/handoff" "$ACTIVE_TEMP/completed.md" \
    "$ACTIVE_TEMP/expected-payload.txt" "$ACTIVE_TEMP/review-analysis.json"
  if ! "$CMP_BIN" -s -- "$ACTIVE_TEMP/expected-payload.txt" "$ACTIVE_TEMP/review-payload.txt"; then
    echo "error: supplied review payload is not deterministic for the snapshotted inputs" >&2
    exit 2
  fi
  verify_signature reviewer "$SIGN_NAMESPACE" "$ACTIVE_TEMP/handoff/REVIEWER-PUBLIC-KEY.pub" \
    "$ACTIVE_TEMP/review-signature" "$ACTIVE_TEMP/review-payload.txt" "$ACTIVE_TEMP"
  verify_signature ledger-authority "$LEDGER_NAMESPACE" "$ACTIVE_TEMP/ledger-authority.pub" \
    "$ACTIVE_TEMP/ledger-receipt.sig" "$ACTIVE_TEMP/ledger-receipt.json" "$ACTIVE_TEMP"
  validate_receipt_and_evaluation "$ACTIVE_TEMP/handoff" "$ACTIVE_TEMP/review-payload.txt" \
    "$ACTIVE_TEMP/ledger-authority.pub" "$ACTIVE_TEMP/ledger-receipt.json" \
    "$ACTIVE_TEMP/admin-evaluation.json" "$ACTIVE_TEMP/review-analysis.json"

  ACTIVE_STAGE="$(mktemp -d "$(dirname "$output")/.$(basename "$output").stage.XXXXXX")"
  chmod 700 "$ACTIVE_STAGE"
  snapshot_tree "$ACTIVE_TEMP/prepared" "$ACTIVE_STAGE/prepared"
  snapshot_tree "$ACTIVE_TEMP/handoff" "$ACTIVE_STAGE/review-handoff"
  mkdir -m 700 "$ACTIVE_STAGE/response"
  snapshot_file "$ACTIVE_TEMP/completed.md" "$ACTIVE_STAGE/response/COMPLETED-QUESTIONNAIRE.md" 256
  snapshot_file "$ACTIVE_TEMP/review-payload.txt" "$ACTIVE_STAGE/response/REVIEW-SIGNING-PAYLOAD.txt" 256
  snapshot_file "$ACTIVE_TEMP/review-signature" "$ACTIVE_STAGE/response/REVIEW-SIGNATURE" 256
  snapshot_file "$ACTIVE_TEMP/ledger-receipt.json" "$ACTIVE_STAGE/response/LEDGER-RECEIPT.json" 256
  snapshot_file "$ACTIVE_TEMP/ledger-receipt.sig" "$ACTIVE_STAGE/response/LEDGER-RECEIPT.json.sig" 256
  snapshot_file "$ACTIVE_TEMP/ledger-authority.pub" "$ACTIVE_STAGE/response/LEDGER-AUTHORITY-PUBLIC-KEY.pub" 256
  snapshot_file "$ACTIVE_TEMP/trusted-policy-authority.pub" "$ACTIVE_STAGE/response/TRUSTED-POLICY-AUTHORITY-PUBLIC-KEY.pub" 256
  snapshot_file "$ACTIVE_TEMP/admin-evaluation.json" "$ACTIVE_STAGE/response/ADMIN-EVALUATION.json" 256
  : >"$ACTIVE_STAGE/SEALED"
  (
    cd "$ACTIVE_STAGE"
    find prepared review-handoff response -type f -print | LC_ALL=C sort | while IFS= read -r file; do
      "$SHASUM_BIN" -a 256 -- "$file"
    done
    "$SHASUM_BIN" -a 256 -- SEALED
  ) >"$ACTIVE_STAGE/EVIDENCE-MANIFEST.sha256"
  find "$ACTIVE_STAGE" -type f -exec chmod 400 {} +
  find "$ACTIVE_STAGE" -type d -exec chmod 500 {} +
  "$NODE_BIN" - "$ACTIVE_STAGE" <<'NODE'
const { createHash } = require("node:crypto");
const { lstatSync, readFileSync, readdirSync } = require("node:fs");
const { dirname, join, relative, sep } = require("node:path");
const root = process.argv[2], hash = (value) => createHash("sha256").update(value).digest("hex");
const files = new Set();
function walk(path) {
  const stat = lstatSync(path), name = relative(root, path).split(sep).join("/") || ".";
  if (stat.isSymbolicLink() || (stat.mode & 0o222) !== 0) throw new Error(`writable or symlinked evidence entry: ${name}`);
  if (stat.isDirectory()) for (const child of readdirSync(path).sort()) walk(join(path, child));
  else if (stat.isFile() && stat.nlink === 1) files.add(name);
  else throw new Error(`special or hard-linked evidence entry: ${name}`);
}
walk(root);
const manifestPath = join(root, "EVIDENCE-MANIFEST.sha256"), listed = new Set();
const expected = new Set([...files].filter((name) => name !== "EVIDENCE-MANIFEST.sha256"));
for (const line of readFileSync(manifestPath, "utf8").trimEnd().split("\n")) {
  const match = line.match(/^([0-9a-f]{64})  ([A-Za-z0-9._/-]+)$/);
  if (!match || listed.has(match[2]) || !expected.has(match[2]) || match[2].startsWith("/") ||
      match[2].split("/").some((part) => !part || part === "." || part === "..")) {
    throw new Error(`malformed, unsafe, duplicate, or unlisted evidence manifest line: ${line}`);
  }
  listed.add(match[2]);
  if (hash(readFileSync(join(dirname(manifestPath), match[2]))) !== match[1]) throw new Error(`evidence digest mismatch: ${match[2]}`);
}
if (JSON.stringify([...listed].sort()) !== JSON.stringify([...expected].sort())) throw new Error("evidence manifest allowlist mismatch");
NODE

  if ! mkdir -m 700 "$output"; then
    echo "error: could not atomically reserve sealed evidence output" >&2
    exit 2
  fi
  ACTIVE_RESERVED="$output"
  find "$ACTIVE_STAGE" -type d -exec chmod 700 {} +
  mv "$ACTIVE_STAGE"/* "$output/"
  rmdir "$ACTIVE_STAGE"
  ACTIVE_STAGE=""
  find "$output" -type d -exec chmod 500 {} +
  (
    cd "$output"
    "$SHASUM_BIN" -a 256 -c -- EVIDENCE-MANIFEST.sha256 >/dev/null
  )
  "$NODE_BIN" - "$output" <<'NODE'
const { lstatSync, readdirSync } = require("node:fs");
const { join } = require("node:path");
function walk(path) {
  const stat = lstatSync(path);
  if (stat.isSymbolicLink() || (stat.mode & 0o222) !== 0 ||
      (!stat.isDirectory() && (!stat.isFile() || stat.nlink !== 1))) {
    throw new Error(`published evidence has a writable, linked, or special entry: ${path}`);
  }
  if (stat.isDirectory()) for (const child of readdirSync(path).sort()) walk(join(path, child));
}
walk(process.argv[2]);
NODE
  archive_tmp="$(mktemp "$(dirname "$output")/.$(basename "$output").archive.XXXXXX")"
  "$TAR_BIN" -cz -f "$archive_tmp" -C "$(dirname "$output")" -- "$(basename "$output")"
  "$TAR_BIN" -tz -f "$archive_tmp" -- | "$NODE_BIN" -e '
const { readFileSync } = require("node:fs");
const root = process.argv[1];
for (const raw of readFileSync(0, "utf8").split("\n").filter(Boolean)) {
  const name = raw.endsWith("/") ? raw.slice(0, -1) : raw;
  const parts = name.split("/");
  if ((parts[0] !== root) || parts.some((part) => !part || part === "." || part === "..") || name.includes("\\")) {
    throw new Error(`unsafe sealed archive member: ${raw}`);
  }
}
' "$(basename "$output")"
  if ! ln "$archive_tmp" "$archive"; then
    rm -f -- "$archive_tmp"
    echo "error: could not publish archive without replacement" >&2
    exit 2
  fi
  ACTIVE_ARCHIVE="$archive"
  rm -f -- "$archive_tmp"
  checksum_tmp="$(mktemp "$(dirname "$output")/.$(basename "$output").checksum.XXXXXX")"
  "$SHASUM_BIN" -a 256 -- "$archive" >"$checksum_tmp"
  if ! ln "$checksum_tmp" "$archive.sha256"; then
    rm -f -- "$checksum_tmp"
    echo "error: could not publish archive checksum without replacement" >&2
    exit 2
  fi
  ACTIVE_CHECKSUM="$archive.sha256"
  rm -f -- "$checksum_tmp"
  chmod 444 "$archive" "$archive.sha256"
  chmod -R u+w "$ACTIVE_TEMP"
  rm -rf -- "$ACTIVE_TEMP"
  ACTIVE_TEMP=""
  ACTIVE_RESERVED=""
  ACTIVE_ARCHIVE=""
  ACTIVE_CHECKSUM=""
  printf 'sealed evidence: %s\narchive: %s\n' "$output" "$archive"
}

self_test() {
  local temp script prepared policy handoff completed payload receipt evaluation output
  local source_script reviewer_private reviewer_public ledger_private ledger_public policy_private policy_public
  temp="$(mktemp -d "${TMPDIR:-/tmp}/loom-seal-self-test.XXXXXX")"
  chmod 700 "$temp"
  source_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
  script="$temp/seal-human-validation.self-test.sh"
  snapshot_file "$source_script" "$script" 320
  prepared="$temp/prepared"
  policy="$temp/TRUST-POLICY.json"
  handoff="$temp/review-handoff"
  completed="$temp/COMPLETED-QUESTIONNAIRE.md"
  payload="$temp/REVIEW-SIGNING-PAYLOAD.txt"
  receipt="$temp/LEDGER-RECEIPT.json"
  evaluation="$temp/ADMIN-EVALUATION.json"
  output="$temp/sealed"
  reviewer_private="$temp/reviewer-key"
  reviewer_public="$reviewer_private.pub"
  ledger_private="$temp/ledger-key"
  ledger_public="$ledger_private.pub"
  policy_private="$temp/policy-key"
  policy_public="$policy_private.pub"
  "$SSH_KEYGEN_BIN" -q -t ed25519 -N '' -f "$reviewer_private"
  "$SSH_KEYGEN_BIN" -q -t ed25519 -N '' -f "$ledger_private"
  "$SSH_KEYGEN_BIN" -q -t ed25519 -N '' -f "$policy_private"
  mkdir -m 700 "$prepared" "$prepared/review" "$prepared/admin" "$prepared/snapshots"
  "$NODE_BIN" - "$prepared" <<'NODE'
const { createHash } = require("node:crypto");
const { mkdirSync, readFileSync, writeFileSync } = require("node:fs");
const { join } = require("node:path");
const root = process.argv[2], hash = (value) => createHash("sha256").update(value).digest("hex");
const runId = "550e8400-e29b-41d4-a716-446655440000", nonce = "1".repeat(64);
const fixed = {
  "review/CASE-A.inspect.txt": "synthetic case A\n",
  "review/CASE-B.inspect.txt": "synthetic case B\n",
  "review/CASE-C.inspect.txt": "synthetic case C\n",
  "review/CASE-D.inspect.txt": "synthetic case D\n",
  "review/QUESTIONNAIRE.md": "synthetic questionnaire template\n",
  "admin/PROTOCOL.md": "synthetic protocol\n",
  "admin/PREPARATION-SCRIPT.sh": "synthetic preparation script\n",
  "admin/PI-VERIFIER.mjs": "synthetic Pi verifier\n",
  "admin/PI-CONTEXT-EXPECTATION.json": "{}\n",
  "admin/PI-CONTEXT-VERIFICATION.json": "{}\n",
  "admin/PI-CONVERSION-SUMMARY.json": "{}\n",
  "admin/HARNESS-VERSIONS.json": "{}\n",
  "admin/SOURCE-TREE.txt": "synthetic tree\n",
  "admin/DIRECT-OUTPUT.loom.json": "{}\n",
  "admin/DIRECT-CLI-SUMMARY.json": "{}\n",
  "admin/CASE-D-CODEX-TO-LOOM-SUMMARY.json": "{}\n",
  "admin/CASE-D-LOOM-TO-CLAUDE-SUMMARY.json": "{}\n",
  "snapshots/loom": "synthetic candidate\n",
  "snapshots/fixture-a.claude.jsonl": "{}\n",
  "snapshots/fixture-b.claude.jsonl": "{}\n",
  "snapshots/fixture-c.loom.json": "{}\n",
  "snapshots/fixture-d.codex.jsonl": "{}\n",
  "snapshots/pi-session.jsonl": "{}\n",
};
for (const [path, value] of Object.entries(fixed)) writeFileSync(join(root, path), value, { flag: "wx", mode: 0o400 });
const inputPaths = {
  candidate: "snapshots/loom", fixtureA: "snapshots/fixture-a.claude.jsonl",
  fixtureB: "snapshots/fixture-b.claude.jsonl", fixtureC: "snapshots/fixture-c.loom.json",
  fixtureD: "snapshots/fixture-d.codex.jsonl", piExpectation: "admin/PI-CONTEXT-EXPECTATION.json",
  piVerifier: "admin/PI-VERIFIER.mjs", questionnaire: "review/QUESTIONNAIRE.md",
  protocol: "admin/PROTOCOL.md", preparationScript: "admin/PREPARATION-SCRIPT.sh",
};
const inputSnapshots = Object.fromEntries(Object.entries(inputPaths).map(([key, path]) => {
  const bytes = readFileSync(join(root, path));
  return [key, { path, sha256: hash(bytes), sizeBytes: bytes.length }];
}));
const candidate = readFileSync(join(root, "snapshots/loom"));
const targets = {
  claude: { harnessVersion: "2.1.216", cwd: "/tmp/loom-human-validation-case-d",
    sessionId: "42000000-0000-4000-8000-000000000000", timestamp: "2026-07-20T02:00:00.000Z" },
  pi: { harnessVersion: "0.74.0", cwd: "/tmp/agent-convert-human-validation",
    provider: "deepseek", model: "deepseek-v4-flash",
    sessionId: "43000000-0000-4000-8000-000000000000", timestamp: "2026-07-20T02:00:00.000Z" },
};
const provenance = {
  schema: "loom.human-validation-admin-provenance.v3", status: "prepared-not-reviewed", runId, nonce,
  inputSnapshots, packageTarball: null, targets,
};
writeFileSync(join(root, "admin/ADMIN-PROVENANCE.json"), `${JSON.stringify(provenance)}\n`, { flag: "wx", mode: 0o400 });
const binding = {
  schema: "loom.human-validation-review-binding.v3", status: "prepared-not-reviewed", runId, nonce,
  candidate: { sha256: hash(candidate), sizeBytes: candidate.length, coreRevision: "3".repeat(40),
    version: "0.2.0-preview.0", targetTriple: "self-test", protocolVersion: "loom.cli.v1" },
  package: null, targets,
  cases: ["A", "B", "C", "D"].map((id) => ({ id, artifact: `CASE-${id}.inspect.txt`,
    sha256: hash(readFileSync(join(root, "review", `CASE-${id}.inspect.txt`))) })),
};
writeFileSync(join(root, "review/REVIEW-BINDING.json"), `${JSON.stringify(binding)}\n`, { flag: "wx", mode: 0o400 });
const reviewNames = ["REVIEW-BINDING.json", "CASE-A.inspect.txt", "CASE-B.inspect.txt",
  "CASE-C.inspect.txt", "CASE-D.inspect.txt", "QUESTIONNAIRE.md"];
writeFileSync(join(root, "review/PREPARATION-MANIFEST.sha256"), reviewNames.map((name) =>
  `${hash(readFileSync(join(root, "review", name)))}  ${name}`).join("\n") + "\n", { flag: "wx", mode: 0o400 });
writeFileSync(join(root, "PREPARED"), `runId=${runId}\nnonce=${nonce}\n`, { flag: "wx", mode: 0o400 });
const rootNames = [];
for (const directory of ["review", "admin", "snapshots"]) {
  const collect = (path, prefix) => {
    const { lstatSync, readdirSync } = require("node:fs");
    for (const name of readdirSync(path).sort()) {
      const full = join(path, name), relative = `${prefix}/${name}`;
      if (lstatSync(full).isDirectory()) collect(full, relative); else rootNames.push(relative);
    }
  };
  collect(join(root, directory), directory);
}
rootNames.push("PREPARED");
rootNames.sort();
writeFileSync(join(root, "ROOT-MANIFEST.sha256"), rootNames.map((name) =>
  `${hash(readFileSync(join(root, name)))}  ${name}`).join("\n") + "\n", { flag: "wx", mode: 0o400 });
NODE
  find "$prepared" -type f -exec chmod 400 {} +
  find "$prepared" -type d -exec chmod 500 {} +

  "$NODE_BIN" - "$prepared" "$policy" "$policy_public" "$reviewer_public" "$ledger_public" <<'NODE'
const { createHash } = require("node:crypto");
const { readFileSync, writeFileSync } = require("node:fs");
const { join } = require("node:path");
const [prepared, output, policyKey, reviewerKey, ledgerKey] = process.argv.slice(2);
const hash = (value) => createHash("sha256").update(value).digest("hex");
writeFileSync(output, `${JSON.stringify({
  schema: "loom.human-validation-trust-policy.v1", policyId: "self-test-policy",
  runId: "550e8400-e29b-41d4-a716-446655440000", nonce: "1".repeat(64),
  issuedAtUtc: "2026-07-20T19:00:00.000Z", expiresAtUtc: "2099-07-20T19:00:00.000Z",
  preparedRootManifestSha256: hash(readFileSync(join(prepared, "ROOT-MANIFEST.sha256"))),
  preparationManifestSha256: hash(readFileSync(join(prepared, "review/PREPARATION-MANIFEST.sha256"))),
  policyAuthority: "Synthetic Policy Authority", policyAuthorityPublicKeySha256: hash(readFileSync(policyKey)),
  reviewer: { identity: "Synthetic Reviewer", role: "Independent Release Engineering",
    publicKeySha256: hash(readFileSync(reviewerKey)) },
  ledger: { authority: "Synthetic Ledger Authority", publicKeySha256: hash(readFileSync(ledgerKey)),
    origin: "https://ledger.example/releases" },
}, null, 2)}\n`, { flag: "wx", mode: 0o400 });
NODE
  "$SSH_KEYGEN_BIN" -Y sign -q -f "$policy_private" -n "$POLICY_NAMESPACE" "$policy"
  "$script" pre-review "$prepared" "$policy" "$policy.sig" "$policy_public" \
    "$reviewer_public" "$handoff" >/dev/null

  "$NODE_BIN" - "$handoff" "$completed" <<'NODE'
const { createHash } = require("node:crypto");
const { readFileSync, writeFileSync } = require("node:fs");
const { join } = require("node:path");
const [handoff, output] = process.argv.slice(2), hash = (value) => createHash("sha256").update(value).digest("hex");
const binding = JSON.parse(readFileSync(join(handoff, "REVIEW-BINDING.json"), "utf8"));
const policyBytes = readFileSync(join(handoff, "PRE-REVIEW-RECEIPT.json"));
const policy = JSON.parse(policyBytes);
const lines = [
  "# Completed Synthetic Review", "",
  `Run ID: ${binding.runId}`, `Release nonce: ${binding.nonce}`,
  `Candidate binary SHA-256: ${binding.candidate.sha256}`,
  `Candidate binary size in bytes: ${binding.candidate.sizeBytes}`,
  `Core revision: ${binding.candidate.coreRevision}`, `Candidate version: ${binding.candidate.version}`,
  `Target triple: ${binding.candidate.targetTriple}`, `CLI protocol version: ${binding.candidate.protocolVersion}`,
  "Package name: N/A (not supplied)", "Package version: N/A (not supplied)",
  "Package tarball SHA-256: N/A (not supplied)",
  `Claude target harness version: ${binding.targets.claude.harnessVersion}`,
  `Pi target harness version: ${binding.targets.pi.harnessVersion}`,
  `Preparation manifest SHA-256: ${hash(readFileSync(join(handoff, "PREPARATION-MANIFEST.sha256")))}`,
  `Preparation root manifest SHA-256: ${policy.preparedRootManifestSha256}`,
  `Pre-review receipt SHA-256: ${hash(policyBytes)}`,
  `Handoff manifest SHA-256: ${hash(readFileSync(join(handoff, "HANDOFF-MANIFEST.sha256")))}`,
  `Policy authority public key SHA-256: ${policy.policyAuthorityPublicKeySha256}`,
  `Reviewer public key SHA-256: ${policy.reviewer.publicKeySha256}`,
  `Ledger origin: ${policy.ledger.origin}`, "", "## Answers", "",
];
for (let question = 1; question <= 13; question += 1) {
  lines.push(`### Answer ${question}`, `Synthetic complete factual answer ${question}.`, "");
}
lines.push("### Answer 14", "Usability score (1-5): 5", "Auditability explanation: The synthetic views are clear.",
  "Blocking ambiguities:", "- none", "Non-blocking ambiguities:", "- none", "",
  "## Clarification Log", "", "Clarification count: 0", "", "## Protocol Record", "",
  "Protocol deviations:", "- none", "", "## Reviewer Attestation", "",
  "Reviewer name: Synthetic Reviewer", "Reviewer role and team: Independent Release Engineering",
  "Administrator name: Synthetic Administrator", "Review started at (UTC): 2026-07-20T20:00:00.000Z",
  "Review completed at (UTC): 2026-07-20T20:10:00.000Z",
  "Independence from implementation (yes or explain): yes",
  "Blinding remained intact until answers were final (yes or explain): yes",
  "- [x] I received only the allowlisted read-only review handoff.",
  "- [x] I did not inspect excluded source, provenance, code, tests, scoring material, binary, or package bytes before finalizing my answers.",
  "- [x] I verified the handoff manifest, the externally trusted policy key, the policy signature, the signed preparation-root commitment, and all binding fields before opening a case.",
  "- [x] Every answer, ambiguity classification, and usability score is my own observation.",
  "- [x] The clarification and protocol-deviation records are complete, including unsolicited administrator comments.",
  "Reviewer signature: Synthetic Reviewer", "Attestation date (UTC): 2026-07-20", "");
writeFileSync(output, lines.join("\n"), { flag: "wx", mode: 0o400 });
NODE
  "$script" review-payload "$prepared" "$handoff" "$completed" "$policy_public" "$payload" >/dev/null
  "$SSH_KEYGEN_BIN" -Y sign -q -f "$reviewer_private" -n "$SIGN_NAMESPACE" "$payload"
  "$NODE_BIN" - "$handoff" "$payload" "$receipt" <<'NODE'
const { createHash } = require("node:crypto");
const { readFileSync, writeFileSync } = require("node:fs");
const { join } = require("node:path");
const [handoff, payload, output] = process.argv.slice(2), hash = (value) => createHash("sha256").update(value).digest("hex");
const policyBytes = readFileSync(join(handoff, "PRE-REVIEW-RECEIPT.json"));
const policy = JSON.parse(policyBytes);
writeFileSync(output, `${JSON.stringify({
  schema: "loom.human-validation-ledger-receipt.v2", runId: policy.runId, nonce: policy.nonce,
  reviewSigningPayloadSha256: hash(readFileSync(payload)), reviewerPublicKeySha256: policy.reviewer.publicKeySha256,
  preparedRootManifestSha256: policy.preparedRootManifestSha256, preReviewReceiptSha256: hash(policyBytes),
  ledgerAuthority: policy.ledger.authority, publishedAtUtc: "2026-07-20T20:11:00.000Z",
  entryId: "self-test-entry", ledgerUrl: "https://ledger.example/releases/self-test-entry",
}, null, 2)}\n`, { flag: "wx", mode: 0o400 });
NODE
  "$SSH_KEYGEN_BIN" -Y sign -q -f "$ledger_private" -n "$LEDGER_NAMESPACE" "$receipt"
  "$NODE_BIN" - "$evaluation" <<'NODE'
const { writeFileSync } = require("node:fs");
writeFileSync(process.argv[2], `${JSON.stringify({
  schema: "loom.human-validation-admin-evaluation.v2", runId: "550e8400-e29b-41d4-a716-446655440000",
  decision: "pass", evaluationStartedAtUtc: "2026-07-20T20:12:00.000Z", evaluatedAtUtc: "2026-07-20T20:20:00.000Z",
  reviewer: "Synthetic Reviewer", administrator: "Synthetic Administrator", factualScore: 13, usabilityScore: 5,
  ambiguities: [], clarifications: [], deviations: [],
  questionEvaluations: Array.from({ length: 14 }, (_, index) => ({ question: index + 1, status: "pass", rationale: "synthetic match" })),
}, null, 2)}\n`, { flag: "wx", mode: 0o400 });
NODE
  "$script" seal "$prepared" "$handoff" "$completed" "$payload" "$payload.sig" \
    "$receipt" "$receipt.sig" "$ledger_public" "$policy_public" "$evaluation" "$output" >/dev/null
  [[ -f "$output/EVIDENCE-MANIFEST.sha256" && -f "$output.evidence.tgz" && -f "$output.evidence.tgz.sha256" ]]
  "$CMP_BIN" -s -- "$output/review-handoff/REVIEWER-PUBLIC-KEY.pub" "$reviewer_public"
  "$CMP_BIN" -s -- "$output/response/LEDGER-AUTHORITY-PUBLIC-KEY.pub" "$ledger_public"

  expect_failure() {
    local needle="$1"; shift
    local log="$temp/failure-$RANDOM.log"
    if "$@" >"$log" 2>&1; then
      echo "error: expected failure for: $needle" >&2
      exit 1
    fi
    if ! grep -F -q "$needle" "$log"; then
      cat "$log" >&2
      echo "error: expected failure did not mention: $needle" >&2
      exit 1
    fi
  }

  ln -s "$reviewer_public" "$temp/reviewer-key-symlink.pub"
  expect_failure "snapshot source must be a singly linked regular non-symlink file" "$script" pre-review \
    "$prepared" "$policy" "$policy.sig" "$policy_public" "$temp/reviewer-key-symlink.pub" "$temp/symlink-key-handoff"
  rm -f -- "$temp/reviewer-key-symlink.pub"
  ln "$reviewer_public" "$temp/reviewer-key-hardlink.pub"
  expect_failure "snapshot source must be a singly linked regular non-symlink file" "$script" pre-review \
    "$prepared" "$policy" "$policy.sig" "$policy_public" "$temp/reviewer-key-hardlink.pub" "$temp/hardlink-key-handoff"
  rm -f -- "$temp/reviewer-key-hardlink.pub"

  "$NODE_BIN" - "$completed" "$temp/incomplete.md" "$temp/wrong-reviewer.md" "$temp/unchecked.md" \
    "$temp/altered-attestation.md" "$temp/bad-attestation-date.md" "$temp/duplicate-score.md" \
    "$temp/same-administrator.md" <<'NODE'
const { readFileSync, writeFileSync } = require("node:fs");
const [source, incomplete, wrongReviewer, unchecked, alteredAttestation, badDate, duplicateScore,
  sameAdministrator] = process.argv.slice(2);
const text = readFileSync(source, "utf8");
writeFileSync(incomplete, text.replace("Synthetic complete factual answer 7.", "[required answer]"));
writeFileSync(wrongReviewer, text.replace("Reviewer name: Synthetic Reviewer", "Reviewer name: Unregistered Reviewer"));
writeFileSync(unchecked, text.replace(
  "- [x] The clarification and protocol-deviation records are complete, including unsolicited administrator comments.",
  "- [ ] The clarification and protocol-deviation records are complete, including unsolicited administrator comments.",
));
writeFileSync(alteredAttestation, text.replace(
  "- [x] Every answer, ambiguity classification, and usability score is my own observation.",
  "- [x] I checked something else.",
));
writeFileSync(badDate, text.replace(
  "Attestation date (UTC): 2026-07-20", "Attestation date (UTC): 2026-07-21",
));
writeFileSync(duplicateScore, text.replace(
  "Usability score (1-5): 5", "Usability score (1-5): 5\nUsability score (1-5): 1",
));
writeFileSync(sameAdministrator, text.replace(
  "Administrator name: Synthetic Administrator", "Administrator name: Synthetic Reviewer",
));
NODE
  expect_failure "Answer 7 is incomplete" "$script" review-payload "$prepared" "$handoff" \
    "$temp/incomplete.md" "$policy_public" "$temp/incomplete-payload"
  expect_failure "reviewer identity or role" "$script" review-payload "$prepared" "$handoff" \
    "$temp/wrong-reviewer.md" "$policy_public" "$temp/wrong-reviewer-payload"
  expect_failure "all five reviewer attestations" "$script" review-payload "$prepared" "$handoff" \
    "$temp/unchecked.md" "$policy_public" "$temp/unchecked-payload"
  expect_failure "reviewer attestation text differs" "$script" review-payload "$prepared" "$handoff" \
    "$temp/altered-attestation.md" "$policy_public" "$temp/altered-attestation-payload"
  expect_failure "must be the review completion date" "$script" review-payload "$prepared" "$handoff" \
    "$temp/bad-attestation-date.md" "$policy_public" "$temp/bad-attestation-date-payload"
  expect_failure "exactly one integer Usability score" "$script" review-payload "$prepared" "$handoff" \
    "$temp/duplicate-score.md" "$policy_public" "$temp/duplicate-score-payload"
  expect_failure "administrator and reviewer identities must be distinct" "$script" review-payload \
    "$prepared" "$handoff" "$temp/same-administrator.md" "$policy_public" "$temp/same-administrator-payload"

  "$SSH_KEYGEN_BIN" -q -t ed25519 -N '' -f "$temp/untrusted-policy-key"
  expect_failure "invalid $POLICY_NAMESPACE signature" "$script" pre-review "$prepared" "$policy" "$policy.sig" \
    "$temp/untrusted-policy-key.pub" "$reviewer_public" "$temp/untrusted-handoff"
  "$NODE_BIN" - "$evaluation" "$temp/bad-score-evaluation.json" "$temp/bad-record-evaluation.json" <<'NODE'
const { readFileSync, writeFileSync } = require("node:fs");
const [source, badScore, badRecord] = process.argv.slice(2), original = JSON.parse(readFileSync(source, "utf8"));
const score = structuredClone(original); score.factualScore = 12;
writeFileSync(badScore, `${JSON.stringify(score)}\n`);
const record = structuredClone(original); record.deviations = ["not in signed questionnaire"];
writeFileSync(badRecord, `${JSON.stringify(record)}\n`);
NODE
  expect_failure "factualScore must equal" "$script" seal "$prepared" "$handoff" "$completed" "$payload" "$payload.sig" \
    "$receipt" "$receipt.sig" "$ledger_public" "$policy_public" "$temp/bad-score-evaluation.json" "$temp/bad-score-output"
  expect_failure "ambiguity or deviation record differs" "$script" seal "$prepared" "$handoff" "$completed" "$payload" "$payload.sig" \
    "$receipt" "$receipt.sig" "$ledger_public" "$policy_public" "$temp/bad-record-evaluation.json" "$temp/bad-record-output"
  "$NODE_BIN" - "$receipt" "$temp/early-ledger-receipt.json" <<'NODE'
const { readFileSync, writeFileSync } = require("node:fs");
const receipt = JSON.parse(readFileSync(process.argv[2], "utf8"));
receipt.publishedAtUtc = "2026-07-20T20:09:00.000Z";
writeFileSync(process.argv[3], `${JSON.stringify(receipt)}\n`, { flag: "wx", mode: 0o400 });
NODE
  "$SSH_KEYGEN_BIN" -Y sign -q -f "$ledger_private" -n "$LEDGER_NAMESPACE" "$temp/early-ledger-receipt.json"
  expect_failure "publication must follow review completion" "$script" seal "$prepared" "$handoff" "$completed" \
    "$payload" "$payload.sig" "$temp/early-ledger-receipt.json" "$temp/early-ledger-receipt.json.sig" \
    "$ledger_public" "$policy_public" "$evaluation" "$temp/early-ledger-output"

  expect_signed_case_failure() {
    local label="$1" needle="$2" case_completed="$3" case_evaluation="$4"
    local case_payload="$temp/$label.payload" case_receipt="$temp/$label-receipt.json"
    "$script" review-payload "$prepared" "$handoff" "$case_completed" "$policy_public" "$case_payload" >/dev/null
    "$SSH_KEYGEN_BIN" -Y sign -q -f "$reviewer_private" -n "$SIGN_NAMESPACE" "$case_payload"
    "$NODE_BIN" - "$handoff" "$case_payload" "$case_receipt" "$label" <<'NODE'
const { createHash } = require("node:crypto");
const { readFileSync, writeFileSync } = require("node:fs");
const { join } = require("node:path");
const [handoff, payload, output, label] = process.argv.slice(2), hash = (value) => createHash("sha256").update(value).digest("hex");
const policyBytes = readFileSync(join(handoff, "PRE-REVIEW-RECEIPT.json")), policy = JSON.parse(policyBytes);
writeFileSync(output, `${JSON.stringify({
  schema: "loom.human-validation-ledger-receipt.v2", runId: policy.runId, nonce: policy.nonce,
  reviewSigningPayloadSha256: hash(readFileSync(payload)), reviewerPublicKeySha256: policy.reviewer.publicKeySha256,
  preparedRootManifestSha256: policy.preparedRootManifestSha256, preReviewReceiptSha256: hash(policyBytes),
  ledgerAuthority: policy.ledger.authority, publishedAtUtc: "2026-07-20T20:11:00.000Z",
  entryId: `self-test-${label}`, ledgerUrl: `https://ledger.example/releases/self-test-${label}`,
}, null, 2)}\n`, { flag: "wx", mode: 0o400 });
NODE
    "$SSH_KEYGEN_BIN" -Y sign -q -f "$ledger_private" -n "$LEDGER_NAMESPACE" "$case_receipt"
    expect_failure "$needle" "$script" seal "$prepared" "$handoff" "$case_completed" "$case_payload" \
      "$case_payload.sig" "$case_receipt" "$case_receipt.sig" "$ledger_public" "$policy_public" \
      "$case_evaluation" "$temp/$label-output"
  }

  "$NODE_BIN" - "$completed" "$evaluation" "$temp" <<'NODE'
const { readFileSync, writeFileSync } = require("node:fs");
const [completedPath, evaluationPath, root] = process.argv.slice(2);
const completed = readFileSync(completedPath, "utf8"), base = JSON.parse(readFileSync(evaluationPath, "utf8"));
const writeCase = (label, questionnaire, mutate) => {
  const evaluation = structuredClone(base);
  mutate(evaluation);
  writeFileSync(`${root}/${label}.md`, questionnaire);
  writeFileSync(`${root}/${label}-evaluation.json`, `${JSON.stringify(evaluation)}\n`);
};
writeCase("low-score", completed.replace("Usability score (1-5): 5", "Usability score (1-5): 3"), (evaluation) => {
  evaluation.usabilityScore = 3;
  evaluation.questionEvaluations[13].status = "fail";
  evaluation.questionEvaluations[13].rationale = "score below threshold";
});
writeCase("blocking", completed.replace("Blocking ambiguities:\n- none", "Blocking ambiguities:\n- cannot distinguish the active branch"), (evaluation) => {
  evaluation.ambiguities = [{ kind: "blocking", text: "cannot distinguish the active branch" }];
  evaluation.questionEvaluations[13].status = "fail";
  evaluation.questionEvaluations[13].rationale = "blocking ambiguity";
});
writeCase("deviation", completed.replace("Protocol deviations:\n- none", "Protocol deviations:\n- administrator supplied a content hint"), (evaluation) => {
  evaluation.deviations = ["administrator supplied a content hint"];
});
const clarificationBlock = [
  "Clarification count: 1", "", "### Clarification 1",
  "UTC time: 2026-07-20T20:05:00.000Z", "Question: 4",
  "Reviewer request: Define the import judgment.",
  "Administrator response: It means the expected answer is environment.",
  "Answer changed (yes or no): yes",
].join("\n");
writeCase("clarification", completed.replace("Clarification count: 0", clarificationBlock), (evaluation) => {
  evaluation.clarifications = [{
    number: 1, utcTime: "2026-07-20T20:05:00.000Z", question: "4",
    reviewerRequest: "Define the import judgment.",
    administratorResponse: "It means the expected answer is environment.",
    answerChanged: "yes", permitted: false, assessment: "prohibited content hint",
  }];
});
NODE
  expect_signed_case_failure low-score "expected fail" "$temp/low-score.md" "$temp/low-score-evaluation.json"
  expect_signed_case_failure blocking "expected fail" "$temp/blocking.md" "$temp/blocking-evaluation.json"
  expect_signed_case_failure deviation "expected invalid" "$temp/deviation.md" "$temp/deviation-evaluation.json"
  expect_signed_case_failure clarification "expected invalid" "$temp/clarification.md" "$temp/clarification-evaluation.json"

  expect_failure "output already exists" "$script" seal "$prepared" "$handoff" "$completed" "$payload" "$payload.sig" \
    "$receipt" "$receipt.sig" "$ledger_public" "$policy_public" "$evaluation" "$output"

  chmod -R u+w "$temp"
  rm -rf -- "$temp"
  echo "human-validation sealing self-test: ok"
}

mode="${1:-}"
case "$mode" in
  --self-test)
    if [[ "$#" -ne 1 ]]; then usage >&2; exit 2; fi
    self_test
    ;;
  pre-review)
    if [[ "$#" -ne 7 ]]; then usage >&2; exit 2; fi
    make_handoff "$2" "$3" "$4" "$5" "$6" "$7"
    ;;
  review-payload)
    if [[ "$#" -ne 6 ]]; then usage >&2; exit 2; fi
    make_review_payload "$2" "$3" "$4" "$5" "$6"
    ;;
  seal)
    if [[ "$#" -ne 12 ]]; then usage >&2; exit 2; fi
    seal_evidence "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" "${12}"
    ;;
  *) usage >&2; exit 2 ;;
esac

trap - EXIT HUP INT TERM
