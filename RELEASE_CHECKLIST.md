# Loom release checklist

Native conversation continuity is defined in [INTENT.md](./INTENT.md).
Carrier decoding, target-parser acceptance, and absence of tool replay are
separate from preserving native history in the target's resumed model context.

Status: **experimental developer-preview candidate; not release-ready and not
stable**.

Current checked values are:

```text
catalogueIntegrityGate       = true
previewCatalogueChecksPass   = false
stableCatalogueChecksPass    = false
previewReadinessAssessment   = catalogueBlocked
stableReadinessAssessment    = catalogueBlocked
previewProofBoundCatalogueEligible = false
stableProofBoundCatalogueEligible  = false
previewProofBoundReadinessAssessment = catalogueBlocked
stableProofBoundReadinessAssessment  = catalogueBlocked
previewReady                 = false
stableReady                  = false
```

`previewReady` and `stableReady` are pure fail-closed booleans and can never
become true. Do not add `previewReady=true` to this checklist. Pure Lean can
only return `catalogueBlocked` or `externalDecisionRequired`; it cannot approve
a release. `previewCatalogueChecksPass=false` is the upstream declaration
sentinel: `AgentConvert.lean` deliberately cannot accept downstream proof
claims. The release-side Lean gate is
`previewProofBoundCatalogueEligible`, computed in `Proofs.lean` from the
proof-bearing internal bundle. That value is also currently false, and
`previewProofBoundReadinessAssessment=catalogueBlocked`.

The proof bundle includes E-036, which discharges only F-032's synthetic
internal context-isolation fixture. It does not include E-037. E-037 is a
candidate-only finite differential pending an immutable retained run; it is not
a Lean key, universal proof, real-harness result, or build provenance. F-029
real-harness historical-call non-execution remains separate.

The current exact assessment sets are:

```text
blocked (all): F-007 F-011 F-012B F-013 F-015 F-016 F-023 F-024B F-025 F-026
blocked (preview): F-012B F-024B F-025 F-026
candidate-pending: F-002 F-006 F-010 F-012 F-014 F-017 F-018 F-019 F-020 F-021 F-022 F-024 F-028 F-029 F-030 F-031 F-033
external worklist: E-006 E-037 E-008 E-015 E-033 E-030 E-027 E-031 E-019 E-029 E-025 E-023 E-034
```

This runbook separates two decisions:

- **Candidate eligibility:** automated verification may produce an immutable
  experimental developer-preview candidate for external evaluation.
- **Developer-preview approval:** downstream proof-bound preview catalogue
  eligibility must pass, all required current-candidate external evidence must
  be sealed, and authorized release and license owners must approve. This is a
  separate decision outside Lean.

The normative scope is in [`REQUIREMENTS.md`](./REQUIREMENTS.md), evidence and
open obligations are in
[`REQUIREMENTS_EVIDENCE.md`](./REQUIREMENTS_EVIDENCE.md), and the signed human
protocol is in [`HUMAN_VALIDATION.md`](./HUMAN_VALIDATION.md).

## Release rules

- Start every release with every box below unchecked.
- Bind every result to the exact source commit, candidate binary digest,
  package commit, tarball digest, platform, command, input digest, and output.
- Treat prior fixture, corpus, or harness results only as historical
  prerequisites and test-design inputs. They do not satisfy a current box.
- Use only `.lake/release/loom` for candidate-bound external reruns.
  `.lake/build/bin/loom` and `coreRevision: working-tree` are development-only.
- Do not publish, install into a real store, tag, or push a release until the
  relevant phase explicitly permits it.
- Do not claim format completeness, arbitrary losslessness, full confidence,
  stable/default parity, or real-harness behavior outside retained
  candidate-bound evidence.

## Historical evidence reset

The following records remain useful evidence history but satisfy no current
release check:

- V-001 through V-004: earlier corpus and fixture projections.
- V-007 through V-011: earlier negative and corrective tool/control probes.
- V-012: continuation at Claude Code `2.1.206`, Codex `0.144.1`, and Pi
  `0.74.0`.
- V-013: Cursor Agent `2026.05.28` disproved local-file resume installation.

Build/export contract pins are Lean `4.28.0`, core `0.2.0-preview.0`, Claude
Code `2.1.216`, Codex `0.144.1`, and Pi `0.74.0`. The current external probe
also selects Cursor Agent `2026.07.09-a3815c0`. Probe configuration, not core
restriction, selects Pi provider/model `deepseek`/`deepseek-v4-flash` and Codex
provider/model `openai`/`gpt-5.5`; Codex's five explicit controls remain a core
contract for every Codex target.

## 1. Scope and authorization

- [ ] Name the release owner, evidence administrator, independent reviewer,
  policy authority, ledger authority, and final approval authority. Incompatible
  human-validation roles are held by different people.
- [ ] Freeze the advertised import/export matrix and explicitly keep Cursor
  Agent file-only and Cursor IDE outside public package install/discovery.
- [ ] Release notes say **experimental developer-preview candidate** until the
  approval phase completes. They state that the public npm package requires an
  external immutable Loom core and is not currently ready.
- [ ] An authorized representative of WOW21, Inc. supplies retained written
  permission before any private Loom file is copied into a public repository.
  The grant must name the Loom source scope in this repository, related
  agent-convert release files, the MIT license, and
  `theoriclabs/agent-convert-lean`. Retain the exact grant and the authority of its
  signer outside the public source tree.
- [ ] Third-party licenses and notices for the package, generated distribution,
  fixtures, and bundled documentation are reviewed and retained. No
  proprietary corpus or secret is present.
- [ ] The release issue links the exact requirements baseline, evidence ledger,
  human protocol, source commits, intended tags, and registry coordinates.

License authorization is a hard external blocker. A passing test suite does not
grant publication rights.

## 2. Source candidate

Run from `utils/` after coordinating the complete intended source change with
the other owners of this working tree:

```sh
git status --short
git diff --check
git diff --name-only
```

- [ ] Review every changed and untracked path. Do not discard or absorb another
  owner's work; stage only the release-approved source set.
- [ ] Commit the candidate before building it. Record the full 40-character
  commit and verify the candidate scope is clean.
- [ ] `lean-toolchain` is exactly `leanprover/lean4:v4.28.0`.
- [ ] Core version is exactly `0.2.0-preview.0`; target constants are Claude
  `2.1.216`, Codex `0.144.1`, and Pi `0.74.0`.
- [ ] Current external probe tools report the selected versions; Claude,
  Codex, and Pi also match their exporter contract pins:

```sh
claude --version
codex --version
pi --version
cursor-agent --version
(lake env lean --version)
```

Expected version lines:

```text
2.1.216 (Claude Code)
codex-cli 0.144.1
0.74.0
2026.07.09-a3815c0
Lean (version 4.28.0, ...)
```

- [ ] Any tool-version warning, wrapper, executable path, and executable digest
  is captured with the release record; parsing a version string alone is not
  provenance.

## 3. Full automated gates

Install exactly from the lockfile and run the complete utils
`prepublishOnly` gate on the clean candidate commit:

```sh
npm ci
npm run prepublishOnly
git diff --check
```

`prepublishOnly` must run all three components without skips introduced for the
release:

```text
npm run build
npm run test:loom
npm test
```

- [ ] `npm ci` succeeds without changing tracked files.
- [ ] TypeScript build and the complete Node test suite pass.
- [ ] `npm run test:loom` builds `loom` and `LoomRequirements` and passes all
  proof/witness, wire, refusal, deterministic output, sidecar transaction,
  SQLite actuator, compatibility projection, audit self-test, evidence-protocol
  self-test, thin-host, byte-equality, and no-fallback gates.
- [ ] No failing test, unexpected skip, warning classified as release-fatal, or
  unreviewed differential divergence remains.
- [ ] The exact command log, environment summary, source commit, and test
  artifact digests are retained. A CI URL without immutable logs is
  insufficient.
- [ ] The candidate rerun confirms
  `catalogueIntegrityGate=true`, the deliberately-false upstream declaration
  sentinels, the reviewed downstream proof-bound values, both pure booleans
  false, and the corresponding assessment states. Any change is reconciled
  against the requirements ledger.

Passing this phase establishes automated candidate eligibility only. It is not
developer-preview approval.

## 4. Immutable release core

The release builder refuses a dirty Loom source scope, stamps the clean `HEAD`,
verifies identity, and copies the frozen executable to the only candidate path:

```sh
scripts/build-release.sh
.lake/release/loom version
shasum -a 256 .lake/release/loom
```

The version line must have this shape:

```text
agent-convert core 0.2.0-preview.0 (40-lowercase-hex-commit)
```

- [ ] `.lake/release/loom` is a regular executable file built from the exact
  clean candidate commit.
- [ ] Its engine, engine version, protocol `loom.cli.v1`, source repository,
  source path, target triple, wire schema, and full `coreRevision` match the
  builder's verified identity record.
- [ ] `coreRevision` equals the candidate source commit and is not
  `working-tree`; the recorded SHA-256 and size match the frozen bytes.
- [ ] Trusted build provenance establishes that the recorded source commit
  produced those binary bytes. The binary's self-report is not sufficient.
- [ ] Copy the binary into evidence storage once. All later validation uses and
  rehashes that snapshot; do not rebuild or replace it in place.

## 5. Release-binary reruns

The development gate above binds the source candidate. Repeat the release-
critical executable checks against the frozen binary itself.

- [ ] Run `.lake/release/loom self-test-sidecar-publication` and retain
  stdout/stderr/status.
- [ ] Rerun every conversion in the README with
  `LOOM=.lake/release/loom` or
  `LOOM_BIN=.lake/release/loom`; verify complete target metadata and
  output digests.
- [ ] The selected Pi validation reruns use
  `deepseek` / `deepseek-v4-flash`, a fresh valid UUID, absolute cwd, UTC
  timestamp, and the `0.74.0` contract pin. Other nonempty provider/model pairs
  remain valid outside this probe unless they use the reserved history identity.
- [ ] The selected Codex validation reruns use `openai` / `gpt-5.5`, a fresh
  valid UUID, absolute cwd, UTC timestamp, the `0.144.1` contract pin, and the
  contract-required approval policy, network access, TMPDIR exclusion, `/tmp`
  exclusion, and summary mode. Other nonempty provider/model pairs remain valid
  outside this probe.
- [ ] The selected Claude validation reruns use a fresh valid UUID, absolute
  cwd, UTC timestamp, and the `2.1.216` exporter contract pin.
- [ ] `detect` rejects malformed/ambiguous data and identifies every advertised
  fixture inside Lean; `inspect` is read-only and reports zero structural
  violations on accepted release fixtures.
- [ ] Single-file staging, occupied-stage refusal, destination-directory
  refusal, malformed-input refusal, destructive-obligation refusal, and
  sidechain-flat refusal leave no candidate artifact and preserve prior data.
- [ ] Claude and Cursor Agent sidecar reruns verify exact directories,
  generated filenames, ownership refusal, all four stale stage/backup paths,
  rollback behavior, and successful-publication backup-cleanup warnings.
- [ ] Run the direct Cursor IDE actuator with system `sqlite3` and repeat with
  `sqlite3` unavailable. Success and failure remain Lean paths; neither selects
  TS.
- [ ] The utils `convert-to-pi` launcher is byte-identical to direct release
  core output for Claude, Codex, Google AI Studio, and Hermes. Missing core and
  legacy-only flags refuse without output or semantic fallback.
- [ ] `PI_CONVERT_ENGINE=ts` is tested only as explicit rollback and its results
  are labeled separately from candidate evidence.

### E-037 lifecycle differential

Run E-037 once against the frozen release binary. Set
`RELEASE_CORE_REVISION` and `RELEASE_CORE_SHA256` only from section 4's
separately trusted build-provenance record, never from the candidate's version
self-report. `EVIDENCE_ROOT` must be an existing retained absolute directory;
do not clean the generated E-037 root.

```bash
(
  set -euo pipefail

: "${EVIDENCE_ROOT:?set to an existing retained absolute evidence directory}"
: "${RELEASE_CORE_REVISION:?set from the trusted build-provenance record}"
: "${RELEASE_CORE_SHA256:?set from the trusted build-provenance record}"
case "$EVIDENCE_ROOT" in
  /*) ;;
  *) printf '%s\n' 'EVIDENCE_ROOT must be absolute' >&2; exit 1 ;;
esac
test -d "$EVIDENCE_ROOT"
test -x .lake/release/loom
ACTUAL_CORE_SHA256="$(shasum -a 256 .lake/release/loom | awk '{print $1}')"
test "$ACTUAL_CORE_SHA256" = "$RELEASE_CORE_SHA256"

E037_ROOT="$(mktemp -d "$EVIDENCE_ROOT/e037.XXXXXX")"
E037_SCRATCH="$E037_ROOT/scratch"
E037_OUTPUT="$E037_ROOT/output"
E037_REPORT="$E037_ROOT/report.json"
test ! -e "$E037_SCRATCH"
test ! -e "$E037_OUTPUT"
test ! -e "$E037_REPORT"

node scripts/audit-lifecycle-matrix.mjs \
  --loom .lake/release/loom \
  --scratch "$E037_SCRATCH" \
  --output "$E037_OUTPUT" \
  --report "$E037_REPORT" \
  --require-immutable

node -e '
const { readFileSync } = require("node:fs");
const [path, expectedDigest, expectedRevision] = process.argv.slice(1);
if (!/^[0-9a-f]{64}$/.test(expectedDigest) ||
    !/^[0-9a-f]{40}$/.test(expectedRevision)) {
  throw new Error("invalid trusted candidate digest or revision");
}
const report = JSON.parse(readFileSync(path, "utf8"));
const candidate = report.candidate;
const identity = candidate?.identity?.value;
const requiredRefusalChecks = [
  "refusal.sentinelBytesPreserved",
  "refusal.sentinelSizePreserved",
  "refusal.sentinelExactBytesPreserved",
  "refusal.sentinelPostExitBindingPreserved",
];
const refusalCells = report.cells?.filter(cell => cell.expected?.kind === "refusal");
const refusalsPass = refusalCells?.length > 0 &&
  refusalCells.every(cell => requiredRefusalChecks.every(required =>
    cell.refusalChecks?.some(check => check.path === required && check.pass === true)));
if (report.schema !== "agent-convert.lifecycle-matrix-report.v1" ||
    report.overallPass !== true || report.census?.expectedCells !== 40 ||
    report.census?.observedCells !== 40 ||
    report.census?.uniqueCellNames !== 40 || report.cells?.length !== 40 ||
    report.cells.some(cell => cell.status !== "pass") || refusalsPass !== true ||
    report.harness?.mutationSelfTest?.pass !== true ||
    report.harness?.mutationSelfTest?.hashesMatchStartLoadedHarness !== true ||
    report.harness?.snapshotsMatchStartLoadedBytes !== true ||
    report.reportBinding?.pathAndSourceStabilityPass !== true ||
    candidate?.originalPath?.start?.sha256 !== expectedDigest ||
    candidate?.originalPath?.unchanged !== true ||
    candidate?.executionSnapshot?.start?.sha256 !== expectedDigest ||
    candidate?.executionSnapshot?.unchanged !== true ||
    candidate?.exactSnapshotOfStartBytes !== true ||
    candidate?.invocations?.observed !== 41 ||
    candidate?.invocations?.matrixCells !== 40 ||
    candidate?.invocations?.allUsedSnapshot !== true ||
    candidate?.invocations?.records?.length !== 41 ||
    candidate?.invocations?.records?.some(item =>
      item.executableSha256 !== expectedDigest) ||
    candidate?.immutableRevisionPolicy?.required !== true ||
    candidate?.immutableRevisionPolicy?.selfReportedFortyHexShapeSatisfied !== true ||
    candidate?.immutableRevisionPolicy?.establishesRevisionProvenance !== false ||
    candidate?.identity?.establishesSourceProvenance !== false ||
    identity?.coreRevision !== expectedRevision ||
    report.fixtures?.length !== 8 || report.fixtures.some(fixture =>
      fixture.original?.unchanged !== true ||
      fixture.executionSnapshot?.unchanged !== true ||
      fixture.exactSnapshotOfStartBytes !== true)) {
  throw new Error("E-037 report failed 40/40 or candidate cross-binding checks");
}
' "$E037_REPORT" "$RELEASE_CORE_SHA256" "$RELEASE_CORE_REVISION"
shasum -a 256 "$E037_REPORT" > "$E037_ROOT/report.sha256"
)
```

- [ ] The retained report is 40/40 with `overallPass=true`, and all cells use the
  same byte-snapshotted executable whose digest and self-reported revision match
  the separately trusted build-provenance record.
- [ ] Every refusal cell records unchanged post-exit prior-artifact path
  identity, opened-file identity, mode, size, digest, and exact bytes. This is a
  finite before/after observation, not continuous monitoring or an atomicity
  proof.
- [ ] Retain the fresh disjoint scratch, output, report, report digest, commands,
  audit/manifest/fixture bindings, stdout/stderr/status, and trusted provenance
  cross-reference under `E037_ROOT` in immutable evidence storage.
- [ ] Treat E-037 only as F-006/F-028 candidate differential evidence. It does
  not satisfy F-029, prove that a real harness consumed output, provide a
  universal theorem, or establish that the claimed revision built the binary.

### Optional corpus claims

For any corpus result used in release notes, create a fresh immutable bundle;
do not quote the historical totals:

```sh
: "${EVIDENCE_ROOT:?set EVIDENCE_ROOT to a new absolute evidence directory}"
: "${CLAUDE_CORPUS:?set CLAUDE_CORPUS to the absolute Claude corpus directory}"
: "${CODEX_CORPUS:?set CODEX_CORPUS to the absolute Codex corpus directory}"
: "${CURSOR_CORPUS:?set CURSOR_CORPUS to the absolute Cursor Agent corpus directory}"
node scripts/audit-corpora.mjs \
  --loom .lake/release/loom \
  --out "$EVIDENCE_ROOT/corpus-audit" \
  "claude=$CLAUDE_CORPUS" \
  "codex=$CODEX_CORPUS" \
  "cursor-agent=$CURSOR_CORPUS"
```

- [ ] Each claimed corpus has a complete input inventory, input digest, fresh
  output directory, candidate identity, command log, projection description,
  result manifest, and zero unadjudicated divergence.
- [ ] Compatibility projection results are described only as compatibility
  evidence. They are not semantic, continuation, or format-completeness proof.

## 6. Public npm package

The private core, utils compatibility host, and public package are separate
artifacts. The public package remains blocked until every item in this section
passes against the exact release-candidate tarball.

### Public commit ordering

- [ ] The exact MIT authorization in section 1 is retained **before** the first
  private-to-public copy.
- [ ] Create public core commit **C** containing the authorized Loom sources
  source and release documentation. Record its full 40-character commit.
- [ ] Build and verify the release core at C before package-only work proceeds.
- [ ] Create later public package commit **P** containing the manifest, thin
  launcher, generated distribution, tests, and package documentation. The
  manifest pins `coreRevision=C`; P is recorded separately and never presented
  as the core revision.
- [ ] Prove there is no core specification drift between those commits:

```sh
git diff --exit-code C..P -- .
```

- [ ] Build the package candidate at P against the release core stamped with C;
  bind both commits and both artifact digests in every retained record.

### Immutable external-core manifest

- [ ] The tarball contains `package/core-manifest.json` with no mutable or
  floating reference. Its exact schema is `agent-convert.core-manifest.v1`.
- [ ] The manifest fixes `engine="lean"`,
  `engineVersion="0.2.0-preview.0"`, `protocolVersion="loom.cli.v1"`, the full
  lowercase 40-hex `coreRevision`,
  `sourceRepository="https://github.com/theoriclabs/agent-convert-lean"`,
  `sourcePath="."`, and the exact wire-schema list.
- [ ] `artifacts` is keyed by every supported `targetTriple`; each entry fixes
  one lowercase SHA-256 and exact byte size for the accepted external
  `.lake/release/loom` file. Unsupported triples fail closed.
- [ ] Public package version is exactly `0.2.0-preview.0`, and the packed
  manifest's revision/digest values match the frozen core and retained release
  record.
- [ ] Before reading transcript bytes or creating output, the launcher hashes
  the selected core, queries its identity, and rejects every field, triple,
  size, or digest mismatch. PATH discovery cannot bypass the manifest.
- [ ] The legacy TS selector cannot satisfy or bypass the default Lean manifest
  check and remains explicit `ts-legacy` only.

### Exact tarball and clean install

From a clean public `agent-convert` checkout, with `LOOM` set to the absolute
frozen core path:

```sh
npm ci
npm test
npm run leakscan
TGZ_NAME="$(npm pack --silent)"
TGZ="$(pwd -P)/$TGZ_NAME"
shasum -a 256 "$TGZ"
PREFIX="$(mktemp -d)"
npm install -g --prefix "$PREFIX" --ignore-scripts "$TGZ"
test -x "$PREFIX/bin/agent-convert"
```

- [ ] `npm pack --dry-run` and tar inspection contain only authorized files,
  including the exact manifest and one public `agent-convert` bin; no private
  core, removed bin, source secret, or unsafe archive member is present.
- [ ] The tarball SHA-256 and size are recorded before installation. All tests
  install those exact bytes, not a later repack or source checkout.
- [ ] A fresh install with no core and a fresh install with an explicitly
  missing core refuse before output and name the external-core prerequisite.
- [ ] A development core reporting `working-tree`, a valid core from another
  commit, a modified binary, wrong engine/version/protocol/triple, and wrong
  manifest digest all refuse before output.
- [ ] A fresh install with the exact frozen core passes detection, inspection,
  every advertised conversion direction, and supported install flows. JSON and
  human output report the manifest-matched engine version and revision.
- [ ] Packed output is byte-identical to direct invocation of the same core for
  every default route; Node performs only process, path, and explicit target-
  store work.
- [ ] The packed CLI exposes and forwards every mandatory target field in the
  README. In particular, no Codex conversion can run without model plus all
  five controls, and no Pi conversion can omit model/provider metadata.
- [ ] Missing/invalid core, conversion refusal, and install refusal preserve any
  existing file/store entry. Cursor Agent install remains an explicit refusal.
- [ ] Clean-install tests run on every supported macOS/Linux target triple in
  the manifest and retain logs and installed-package byte inventories.

The current package has no qualifying immutable core manifest or clean-install
evidence, so this section is presently blocking.

## 7. Candidate-bound external validation

- [ ] Rerun authenticated open/append/re-read continuation at the selected
  external probe versions: Claude Code `2.1.216`, Codex `0.144.1`, and Pi
  `0.74.0`. These also match their exporter contract pins. Use the frozen core
  and exact packed package; each target recovers a unique precommitted
  prior-context sentinel at the active leaf and re-imports with zero violations.
- [ ] The selected Cursor Agent external probe, `2026.07.09-a3815c0`, is tested
  only for advertised file-source/file-target behavior. The core does not pin a
  Cursor Agent version. Its public install/resume path refuses before mutation;
  V-013 remains historical negative context only.
- [ ] Every target artifact and append is newline/record safe, digest-addressed,
  and bound to source fixture, target metadata, harness executable/version,
  model response, package/core commits, tarball/binary digests, commands,
  stdout/stderr/status, and re-import report.
- [ ] Ordered source/target tool censuses reconcile occurrence, id, name,
  complete arguments, complete result blocks, linkage, error value/provenance,
  disposition, and every synthesis/refusal.
- [ ] Representable source calls/results are native target history, including
  known completed calls with pruned output. Execution status and unavailable
  output remain distinct; no converter disclaimer or carrier JSON enters
  assistant dialogue. Actual target limitations are reported separately.
- [ ] Inspect the target's resumed model context and run a controlled prior-tool
  recall probe. Parser acceptance and carrier self-round-trips are insufficient.
- [ ] Satisfy F-029 by observing that load/resume does not rerun recorded past
  actions, including native tool history. Check execution events rather than
  treating the absence of native tool records as proof of success.
- [ ] Developer/system/policy/permission/configuration/environment records stay
  outside target user/assistant dialogue and remain typed provenance or a named
  loss/refusal for every advertised role family.
- [ ] Held-out malformed, unknown-kind, control-envelope, compaction, media,
  branch, interrupted-tool, duplicate-id, missing-id, reordered-result, and
  sidechain cases pass the declared preserve/report/refuse policy.
- [ ] No external result is accepted unless it names the exact current
  candidate revision and retained binary/package/input/output digests.

## 8. Human validation and signatures

Run the complete protocol in [`HUMAN_VALIDATION.md`](./HUMAN_VALIDATION.md)
without abbreviating or replacing its commands.

- [ ] The Pi expectation is clean, tracked, current for the selected Pi
  `0.74.0` oracle probe (also the exporter contract pin), and fixes the complete
  oracle closure and ordered expected context.
- [ ] Preparation uses `.lake/release/loom`, the exact packed npm
  tarball, a fresh ledger-issued UUIDv4 run id and 32-byte nonce, and a new
  evidence directory outside the repository.
- [ ] Preparation verifies the build contract Lean `4.28.0`; the selected
  Claude `2.1.216`, Codex `0.144.1`, and Pi `0.74.0` probes that also match
  exporter contract pins; and the Cursor Agent `2026.07.09-a3815c0` external
  probe. All queried executable paths, bytes, versions, and digests are retained.
- [ ] The package route and direct core route produce byte-identical exercised
  output, and preparation records candidate/package/source identities without
  treating self-reports as trusted build provenance.
- [ ] An independent policy authority signs the exact trust policy in namespace
  `agent-convert-human-validation-policy` before review.
- [ ] `seal-human-validation.sh pre-review` creates a closed handoff bound to
  the registered reviewer key and independently authenticated policy key.
- [ ] The blinded reviewer completes every required answer and attestation and
  signs the exact review payload in namespace
  `agent-convert-human-validation`.
- [ ] The independent ledger atomically rejects reused ids/nonces, publishes
  the payload before administrator scoring, and signs the v2 receipt in
  namespace `agent-convert-human-validation-ledger`.
- [ ] The administrator evaluation follows the objective decision rule and is
  chronologically after ledger publication.
- [ ] `seal-human-validation.sh seal` verifies all manifests, bindings,
  signatures, keys, timestamps, answers, scores, and ledger origin, then emits
  the closed evidence tree, `.evidence.tgz`, and external SHA-256.
- [ ] The sealed decision is `pass`; the archive digest and ledger URL are
  published in the release record. Failed or invalid runs are retained and do
  not get rewritten.
- [ ] The authorized evidence owner adds current candidate-bound results and
  digests to [`REQUIREMENTS_EVIDENCE.md`](./REQUIREMENTS_EVIDENCE.md) without
  altering historical records.

## 9. Developer-preview decision

- [ ] All preview-scope fit obligations are internally satisfied or have the
  required sealed external validation; no preview trace remains blocked.
- [ ] A fresh requirements build reports
  `previewCatalogueChecksPass=false` and
  `previewReadinessAssessment=catalogueBlocked` as the intentional upstream
  sentinel, plus `previewProofBoundCatalogueEligible=true` and
  `previewProofBoundReadinessAssessment=externalDecisionRequired` downstream.
- [ ] `previewReady=false` and `stableReady=false` remain unchanged, as
  designed. No reviewer treats either pure boolean as a release vote.
- [ ] Open stable-only obligations, performance non-claims, format/version
  limits, external-core prerequisite, rollback boundary, and Cursor file-only
  scope are explicit in release notes.
- [ ] The release, security, legal/license, and product authorities review the
  exact sealed evidence and record an explicit developer-preview approval.

If the preview catalogue is still blocked, or external approval is absent, the
artifacts remain experimental developer-preview candidates and must not be
represented as an approved developer preview.

## 10. Commit, tag, and push

- [ ] The private core source commit is the exact commit stamped in and used by
  the validated `.lake/release/loom`; no source change follows validation.
- [ ] The utils compatibility-host commit is recorded separately and its full
  gate passed against that core.
- [ ] The public package commit is the exact source of the validated tarball;
  package version, lockfile, manifest, generated distribution, docs, and
  release notes are committed before packing.
- [ ] Public commit C contains the authorized core, public commit P contains the
  package, `git diff --exit-code C..P -- .` is clean, and P's manifest
  pins C rather than P.
- [ ] Re-run clean-tree checks in each repository. Review signed commit
  identities and remote destinations before network operations.
- [ ] Create signed annotated tags only after external approval. Each tag points
  directly to its validated commit; record the tag object id and signature.
- [ ] Push the exact commits first, then the exact signed tags, and verify the
  remote refs resolve to the recorded commits. Do not force-push or move a
  release tag.
- [ ] Announce only the externally approved scope. Keep rollback instructions
  explicit and preserve all release evidence according to retention policy.

Publishing to npm is outside this checklist and is not performed or claimed by
these steps. A later publication authorization must name the already validated
tarball bytes and registry operation explicitly; it must not rebuild or repack
the candidate.

Stable/default release remains a separate future decision requiring downstream
`stableProofBoundCatalogueEligible=true`, a
`stableProofBoundReadinessAssessment=externalDecisionRequired` result,
stable-scope evidence, and a new external approval. The upstream
`stableCatalogueChecksPass` sentinel remains deliberately false.
