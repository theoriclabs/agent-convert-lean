# Blinded Inspect Human Validation

The current product goal is [native conversation continuity](./INTENT.md).
This historical inspect protocol measures readability and auditing; it cannot
establish that the target model receives native tool history. Preserve existing
scoring evidence as recorded. Add separate native-context, completed/pruned
state, and no-replay checks before claiming the current fidelity goal is met;
do not treat carrier visibility as desired target conversation behavior.

Status: protocol for an **experimental developer-preview candidate**. No current
production run, external signature set, or release approval is claimed complete.

This protocol defines how to obtain the external human evidence required by
D-007 and R-013. It tests whether an independent developer can audit
deterministic `loom inspect` output without reading raw transcripts. It is not
a Lean proof, a substitute for adapter tests, or proof that a Git revision
built a binary.

The human-validation decision does not adjudicate E-037's finite lifecycle
matrix, F-029's real-harness historical-call non-execution, or the E-034/F-033
held-out context-isolation corpus. Those require separate retained evidence and
remain outside this protocol even when the blinded readability decision passes.

## Claims And Limits

A successful sealed run establishes that:

- Four exact renderings were produced from manifest-bound candidate and fixture
  snapshots and handed to the registered reviewer.
- Candidate, package, fixture, verifier, Pi expectation, generated artifacts,
  target identities, review answers, signatures, ledger receipt, and
  administrator evaluation are digest-bound in one closed evidence archive.
- Production preparation accepted only exact Lean `4.28.0`, Claude Code
  `2.1.216`, Codex CLI `0.144.1`, Pi `0.74.0`, and Cursor Agent
  `2026.07.09-a3815c0` parsed versions.
- Case D exported to Claude with explicit target cwd, session id, timestamp, and
  Claude Code validation build `2.1.216`.
- The Pi export used explicit target identity and exact Pi `0.74.0`; its complete
  ordered context matched a precommitted structured expectation under a pinned
  immutable oracle closure.
- For package runs, npm installed a path-validated tarball without lifecycle
  scripts, installed package/bin bytes matched exact tar members, and npm's
  generated `node_modules/.bin/agent-convert` shim produced the same Loom bytes
  as the candidate on the exercised route.
- A separately signed trust policy committed to the prepared root, registered
  reviewer key, registered ledger key, and ledger origin before review.
- The reviewer signed complete answers and that commitment; the registered
  ledger accepted the payload before administrator scoring; the objective
  decision rule was applied consistently.

The protocol does not establish that checkout `HEAD` produced the candidate or
package. Candidate revision and source identity remain self-reports bound to
exact bytes and a clean source-tree capture. For package runs, the archive binds
the exact tarball digest, package version, installed members, exercised shim,
and candidate-core bytes on the tested route; it does not prove a package source
revision. A compiled-from or package-revision claim requires separately trusted
hermetic or reproducible-build provenance.

Filesystem modes alone do not protect against their owner. Preparation therefore
runs candidate, npm, package, and Pi code under a deny-by-default macOS
`sandbox-exec` profile that permits filesystem writes only inside one private
step output root. If that sandbox cannot be applied, preparation fails before
running untrusted code. Exact protected inputs are rehashed after all untrusted
execution and again immediately before manifests and publication.

## Independent Trust Inputs

The scripts cannot manufacture an independent trust anchor. Production requires
an externally authenticated policy-authority SSH public key. Obtain it from a
release-policy channel independent of the administrator and evidence bundle.
Passing a key found only beside the evidence does not establish independence.

After preparation, the policy authority signs the exact policy file bytes in SSH
namespace `agent-convert-human-validation-policy`. The JSON schema is
`loom.human-validation-trust-policy.v1` and has exactly these fields:

```json
{
  "schema": "loom.human-validation-trust-policy.v1",
  "policyId": "stable policy identifier",
  "runId": "<ledger-issued-unused-lowercase-uuidv4>",
  "nonce": "<ledger-issued-unused-64-lowercase-hex>",
  "issuedAtUtc": "<policy-issued-current-utc-timestamp>",
  "expiresAtUtc": "<policy-expiry-current-utc-timestamp>",
  "preparedRootManifestSha256": "64 lowercase hexadecimal characters",
  "preparationManifestSha256": "64 lowercase hexadecimal characters",
  "policyAuthority": "independent authority identity",
  "policyAuthorityPublicKeySha256": "64 lowercase hexadecimal characters",
  "reviewer": {
    "identity": "pre-registered reviewer identity",
    "role": "reviewer role and team",
    "publicKeySha256": "64 lowercase hexadecimal characters"
  },
  "ledger": {
    "authority": "independent ledger identity",
    "publicKeySha256": "64 lowercase hexadecimal characters",
    "origin": "https://independent.example/releases"
  }
}
```

The policy is created only after the preparation root exists and before the
review starts. This sequencing avoids a recursive digest while giving the
reviewer an independently signed preparation-root commitment.

## Roles

- The release system issues an unused UUIDv4 run id and 32-byte random nonce and
  rejects reuse.
- The policy authority controls its signing key and reviewer/ledger registration
  independently of the administrator.
- The administrator prepares artifacts and does not score until ledger
  publication.
- The reviewer did not implement the renderer or exercised adapters and has not
  seen fixtures, implementation, tests, protocol answer key, or scoring material.
- The ledger atomically rejects reused run ids/nonces, publishes a stable HTTPS
  entry under the policy origin, and signs its receipt independently.

One person must not combine administrator and reviewer roles. The administrator
must not control reviewer, policy-authority, or ledger private keys.

Three external signatures are mandatory for a production pass:

| Signer | Exact signed bytes | SSH namespace |
|---|---|---|
| Policy authority | `TRUST-POLICY.json` | `agent-convert-human-validation-policy` |
| Registered reviewer | `REVIEW-SIGNING-PAYLOAD.txt` | `agent-convert-human-validation` |
| Registered ledger | `LEDGER-RECEIPT.json` | `agent-convert-human-validation-ledger` |

The policy signature must validate under the independently authenticated policy
key; the reviewer and ledger public-key digests must equal the registrations in
that signed policy; and sealing must verify all three signatures over the exact
snapshotted bytes. Locally generated or bundle-only keys are suitable only for
self-tests and cannot support production validation.

## Preparation Eligibility

Preparation requires a clean Git-tracked `spec/loom` scope, immutable
40-character `HEAD`, tracked clean Pi expectation under
`spec/loom/testdata/release`, executable regular candidate, fresh output path
outside the repository, and the exact required tools. It clears `NODE_OPTIONS`,
`NODE_PATH`, dynamic-loader injection variables, shell startup variables,
`PI_PACKAGE_ROOT`, tar option variables, and all npm config environment
variables. Node, npm, tar, harness, Lean, and Lake executables are resolved
once; paths, versions, output, and executable digests are captured.

Every mutable input is snapshotted once. Evidence master snapshots are never
passed to untrusted code. Read-only execution copies and one isolated writable
output root are used per command with private `HOME`, `TMPDIR`, and `PATH`, no
inherited environment, and no network permission. Candidate, package, verifier,
fixtures, expectation, and node/npm/tar executable bytes are rehashed before any
manifest and immediately before publication.

## Execution Context And Pins

Unless a signing step is explicitly performed by an external key-holding role,
run administrator commands from the repository's `utils/` directory:

```sh
cd /absolute/path/to/utils
```

Production preparation requires macOS `sandbox-exec`; Git; Node and npm; tar,
`shasum`, `mktemp`, `cmp`, and `env`; the Lean/Lake tools selected by
`spec/loom/lean-toolchain`; authenticated or otherwise usable `claude`, `codex`,
`pi`, and `cursor-agent` commands; a clean tracked Pi expectation; an unused
ledger-issued run id and nonce; an externally authenticated policy-authority
key; a pre-registered reviewer key; and a policy-registered ledger key and HTTPS
origin. `ssh-keygen` is additionally required for handoff, review, ledger, and
seal operations. Missing sandboxing or a stale/mixed output path is fatal.

The current production pins are:

| Component | Required parsed version or identity |
|---|---|
| Lean | 4.28.0 |
| Loom core | 0.2.0-preview.0, immutable 40-character `coreRevision` equal to clean `HEAD` |
| Claude Code | 2.1.216 |
| Codex CLI | 0.144.1 |
| Pi | 0.74.0 |
| Cursor Agent | 2026.07.09-a3815c0 |

These rows do not all mean the same thing. Lean `4.28.0` is the build-toolchain
contract. Claude `2.1.216`, Codex `0.144.1`, and Pi `0.74.0` are both current
exporter contract versions and external probe versions. Cursor Agent
`2026.07.09-a3815c0` is only the current file/census validation probe; the core
does not stamp or restrict Cursor imports/exports to that version.

The target contract versions are not source-parser allowlists. Importers retain
recorded source harness metadata and do not treat these current target pins as
permission to reject an otherwise supported historical transcript solely for
its recorded version.

Provider/model selections are probe configuration, not parser restrictions.
The production preparation script currently exports its Pi case as
`deepseek`/`deepseek-v4-flash`. Loom requires a complete foreign-target launch
bundle, requires nonempty Pi provider/model values, and rejects Pi's reserved
assistant-history identity, but it does not restrict ordinary Pi input or
output to that probe pair. Historical provider/model values and older harness
versions remain evidence metadata, never current validation credit.

Preparation records each resolved executable path, exact `--version` stdout and
stderr, parsed version, and executable SHA-256 in
`admin/HARNESS-VERSIONS.json`; it also records the Lean and Lake selected by the
pinned toolchain. Immediately after those isolated captures, and before any
candidate or package code runs, the script hard-rejects a parsed Lean, Claude,
Codex, Pi, or Cursor Agent version that does not exactly match the table above.
Node, npm, tar, and Lake versions must be parseable and remain captured for
provenance, but this protocol does not pin them exactly. The script separately
hard-rejects a candidate whose engine version differs from 0.2.0-preview.0 or
whose core revision differs from clean `HEAD`. A version capture is identity
evidence, not proof of target behavior.

Passing preparation or sealing does not change Lean's pure readiness booleans.
`previewReady` and `stableReady` remain false by construction. This protocol can
only supply candidate-bound inputs to the separate external decision after the
downstream proof-bound catalogue permits that decision.

Generate the candidate only after committing the exact `spec/loom` source:

```sh
spec/loom/scripts/build-release.sh
test -x spec/loom/.lake/release/loom
spec/loom/.lake/release/loom version --json
```

`build-release.sh` stamps clean `HEAD`, verifies the core identity, and freezes
the candidate at `spec/loom/.lake/release/loom`. Preparation independently
requires that the candidate's self-reported `coreRevision` equal the same clean
HEAD and binds its exact bytes. Use this release path, not the mutable
`.lake/build/bin/loom` path.

For a package run, the tarball must be the exact package candidate recorded by
the release system. The protocol binds its digest and version and checks the
installed shim against the candidate core on the exercised route. Because the
current package has no independently enforced immutable core/source manifest,
this protocol alone does not establish the package source revision; do not use
it to close that separate release obligation.

## Prepare

Run both protocol self-tests before issuing production identifiers:

```sh
spec/loom/scripts/prepare-human-validation.sh --self-test
spec/loom/scripts/seal-human-validation.sh --self-test
```

The independent release ledger, not this document or the administrator, must
issue a fresh unused UUIDv4 and 32-byte nonce. Supply them through the shell
environment; the guards below fail instead of substituting reusable examples:

```sh
: "${LEDGER_RUN_ID:?set to a ledger-issued unused lowercase UUIDv4}"
: "${LEDGER_NONCE:?set to a ledger-issued unused 32-byte lowercase-hex nonce}"
: "${PI_EXPECTATION:?set to the clean tracked Pi expectation path}"
: "${PACKAGE_TARBALL:?set to the absolute exact package-candidate tarball path}"
: "${HUMAN_EVIDENCE_DIR:?set to a fresh absolute path outside the repository}"

spec/loom/scripts/prepare-human-validation.sh \
  --run-id "$LEDGER_RUN_ID" \
  --nonce "$LEDGER_NONCE" \
  --pi-expectation "$PI_EXPECTATION" \
  --package "$PACKAGE_TARBALL" \
  spec/loom/.lake/release/loom \
  "$HUMAN_EVIDENCE_DIR"
```

Omit `--package` only for core-only evidence. Such a run cannot support a public
npm package claim.

Preparation emits:

```text
loom-human-validation/
  PREPARED
  ROOT-MANIFEST.sha256
  review/
  admin/
  snapshots/
```

`ROOT-MANIFEST.sha256` covers every prepared file except itself.
`review/PREPARATION-MANIFEST.sha256` covers every initial reviewer file except
itself. All paths are closed allowlists; symlinks, hardlinks, special files,
writable final entries, malformed manifest paths, and stale output paths fail.

Record the printed root-manifest digest, preparation-manifest digest, run id,
nonce, candidate digest, and optional package digest in the independent release
system. Give those values to the policy authority, not directly to the reviewer
as unsigned assertions.

## Package Validation

Before npm sees a tarball, preparation parses gzip/tar headers and checks header
checksums, PAX lengths, member types, duplicate names, and normalized paths. It
rejects absolute paths, empty/dot/dot-dot components, backslashes, symlinks,
hardlinks, devices, FIFOs, special entries, unsafe PAX paths, and non-`package/`
members. It requires exact regular `package/package.json` and executable public
bin members. Tar extraction uses `--` after the archive operand and is compared
to independently parsed bytes.

Npm runs offline with lifecycle scripts, audit, funding, and optional
dependencies disabled. After installation, preparation rejects links or
hardlinks inside the package, requires package.json and public-bin bytes to equal
the tar members, verifies the npm bin shim resolves to that exact public bin,
then invokes the shim directly. This exercises shebang, executable mode, npm bin
wiring, and the candidate core route.

## Pi Verification

The expectation schema `agent-convert.pi-context-expectation.v1` pins Pi package
name/version, per-module digests, complete oracle-closure digest, session/source
digests, exact ordered context, source tool assertions, forbidden native tool
names, record count, and canonical context digest.

Release mode resolves global Pi with the exact captured npm executable and
rejects package-root/version overrides and dangerous environment variables. It
copies only the complete executable session-manager closure plus the pinned
public index bytes and complete `uuid` dependency tree. Static imports are
checked to be closed, the pinned index is checked to re-export
`buildSessionContext`, and the live broad package root is never imported. The
snapshot is made non-writable before import. Oracle execution occurs in a
separate Node permission-model child that can read only the runner, session,
and immutable closure and has no filesystem-write, child-process, worker,
native-addon, or WASI permission. The runner, entire closure, and
session/source/expectation snapshots are rehashed afterward. The receipt binds
the exact Node and npm executable paths, digests, and constrained npm-root
arguments used for this check.

## Pre-Review Handoff

The policy authority signs the policy:

```sh
ssh-keygen -Y sign -f /policy/private-key \
  -n agent-convert-human-validation-policy \
  /policy/TRUST-POLICY.json
```

Create the handoff with the externally trusted policy key and registered
reviewer key:

```sh
spec/loom/scripts/seal-human-validation.sh pre-review \
  /private/evidence/loom-human-validation \
  /policy/TRUST-POLICY.json \
  /policy/TRUST-POLICY.json.sig \
  /trusted/policy-authority.pub \
  /registered/reviewer.pub \
  /private/evidence/loom-review-handoff
```

`pre-review` snapshots every input once, verifies the prepared root, policy
signature, exact registered digests, expiry, and HTTPS ledger origin, then emits
a closed non-writable handoff. The exact signed policy bytes become
`PRE-REVIEW-RECEIPT.json`; `HANDOFF-MANIFEST.sha256` covers the receipt,
signature, keys, questionnaire, binding, renderings, and preparation manifest.

Give the reviewer only this handoff and the independently authenticated policy
key. The reviewer follows `QUESTIONNAIRE.md`, verifies the handoff and policy
signature before opening any case, transcribes every binding, and completes all
14 answer sections, ambiguity lists, clarification record, protocol-deviation
record, identity fields, timestamps, and five attestations.

## Review Signature

```sh
spec/loom/scripts/seal-human-validation.sh review-payload \
  /private/evidence/loom-human-validation \
  /private/evidence/loom-review-handoff \
  /reviewer/COMPLETED-QUESTIONNAIRE.md \
  /trusted/policy-authority.pub \
  /reviewer/REVIEW-SIGNING-PAYLOAD.txt

ssh-keygen -Y sign -f /reviewer/private-key \
  -n agent-convert-human-validation \
  /reviewer/REVIEW-SIGNING-PAYLOAD.txt
```

Payload generation rejects missing answers, placeholder text, missing score or
ambiguity lists, malformed clarification blocks, unchecked attestations,
unregistered reviewer identity/role, mismatched bindings, invalid timestamps,
display controls, altered policy bytes, or an untrusted policy key. It binds the
root, preparation and handoff manifests, signed pre-review receipt, completed
questionnaire, reviewer/policy/ledger keys, and ledger origin.

## Independent Ledger

Before scoring, the ledger publishes and signs schema
`loom.human-validation-ledger-receipt.v2`:

```json
{
  "schema": "loom.human-validation-ledger-receipt.v2",
  "runId": "<same-ledger-issued-unused-lowercase-uuidv4>",
  "nonce": "<same-ledger-issued-unused-64-lowercase-hex>",
  "reviewSigningPayloadSha256": "64 lowercase hexadecimal characters",
  "reviewerPublicKeySha256": "64 lowercase hexadecimal characters",
  "preparedRootManifestSha256": "64 lowercase hexadecimal characters",
  "preReviewReceiptSha256": "64 lowercase hexadecimal characters",
  "ledgerAuthority": "policy-registered authority",
  "publishedAtUtc": "<ledger-publication-current-utc-timestamp>",
  "entryId": "stable append-only entry id",
  "ledgerUrl": "https://independent.example/releases/entry-id"
}
```

It signs exact receipt bytes in namespace
`agent-convert-human-validation-ledger`. The URL must remain within the signed
policy origin. `publishedAtUtc` must follow the signed review-completion time;
administrator scoring starts only after `publishedAtUtc`. Review,
clarification, ledger, and evaluation timestamps use exact UTC form and are
checked for chronological consistency.

## Decision Rule

Answers 1-13 receive only `pass` or `fail`; no partial factual credit is
recognized by the protocol. `factualScore` must exactly equal their pass count.
Question 14 passes only for reviewer score at least 4/5 and no blocking
ambiguity. Every assessment needs a nonempty rationale.

The derived decision is:

- `invalid` when independence or blinding is not affirmed, any protocol
  deviation exists, or any clarification is classified as prohibited.
- `pass` when valid, all 13 factual answers pass, question 14 passes, and no
  blocking ambiguity exists.
- `fail` for every other valid completed review.

Evaluation schema `loom.human-validation-admin-evaluation.v2` contains matching
run and identities, post-ledger timestamps, decision, factual/usability scores,
exact ambiguity/clarification/deviation records, and exactly 14 objects of shape
`{"question":1,"status":"pass","rationale":"..."}`. Clarification objects
repeat the exact signed exchange and add boolean `permitted` plus a nonempty
policy assessment. Sealing recomputes every score and the decision.

## Factual Answer Key

1. `USER`, `ASSISTANT`, `ENVIRONMENT`, `ASSISTANT`; active leaf 3; 0
   violations.
2. Thinking text `th`; signature is reported as present; opaque signature bytes
   are not displayed. Adjacent assistant text `tx` is ordinary text.
3. Call `bash`, id `tu1`, arguments `{ "a": 1 }`; the result links to entry 1,
   block 2, reports recorded success, and contains `tr`.
4. Claude serialized the tool result in a user-role line, so Loom attributed it
   to the environment. `file-history-snapshot` and `mode` remain inert
   provenance outside dialogue. With no last-prompt pointer, Loom selected the
   newest non-sidechain leaf.
5. Four conversation entries remain in order: user request to read and report,
   assistant text plus `Read` call, environment result `fixture contents`, and
   final assistant response `Context restored.`
6. Command `/goal`, message `goal`, arguments `preserve the conversation`; task
   id `task-1`, summary `Background reader changed state`, event
   `status=completed`.
7. The command envelope, system reminder, IDE-opened-file notice, and task
   notification are outside conversation. Their normalized meanings and source
   locations appear under `Import Judgments`; exact raw wrappers remain in
   origin provenance but are not printed as dialogue.
8. Two threads: thread 0 is main; thread 1 is sidechain `interleaved child`,
   anchored at entry 2, block 0.
9. Thread 0 contains user `root`, then assistant `Task` call. Thread 1 contains
   user `child work`, then assistant `child done`.
10. Call `Task`, id `toolu_interleaved`, arguments
    `{ "prompt": "child work" }`; all four entry times are absent.
11. Entry 0 is native `USER` request `Run the checks and retain every result
    block.` Entry 1 is historical/unverified `ASSISTANT` `exec_command`; entry 2
    its historical/unverified `ENVIRONMENT` result; entry 3
    historical/unverified `ASSISTANT` `tool_search_call`; entry 4 its
    historical/unverified `ENVIRONMENT` result; entry 5 historical/unverified
    interrupted `ASSISTANT` `exec`; entry 6 native `ASSISTANT` text `The
    recorded checks are complete.` Active leaf 6; 0 violations.
12. Entries 1-5 are non-executable audit history. Calls are `exec_command` id
    `call-function`, `tool_search_call` id `call-search`, and `exec` id
    `call-interrupted`; entries 2 and 4 are results for the first two, while the
    interrupted call has no result. The view reports
    `historical/unverified carrier-derived` and says the in-band carrier cannot
    authenticate native Claude execution or compaction. Entries 0 and 6 report
    `disposition: native`.
13. None. No opening, closing, attributed, self-closing, or case-varied raw
    XML/HTML-like harness wrapper is visible.
14. Subjective. Score at least 4/5; every slowdown or ambiguity is named; none
    is blocking.

## Seal Evidence

```sh
spec/loom/scripts/seal-human-validation.sh seal \
  /private/evidence/loom-human-validation \
  /private/evidence/loom-review-handoff \
  /reviewer/COMPLETED-QUESTIONNAIRE.md \
  /reviewer/REVIEW-SIGNING-PAYLOAD.txt \
  /reviewer/REVIEW-SIGNING-PAYLOAD.txt.sig \
  /ledger/LEDGER-RECEIPT.json \
  /ledger/LEDGER-RECEIPT.json.sig \
  /registered/ledger-authority.pub \
  /trusted/policy-authority.pub \
  /administrator/ADMIN-EVALUATION.json \
  /private/evidence/loom-human-validation-sealed
```

Sealing snapshots the prepared tree, handoff, both registered keys, all signed
payloads, and evaluation exactly once into private storage. All hashes,
signature checks, policy/ledger validation, deterministic payload derivation,
score checks, copies, and final manifests use only those bytes. Live caller
paths are never reread, eliminating seal-time key replacement races.

The output is a closed non-writable tree plus no-replace `.evidence.tgz` and
external SHA-256 file. Archive creation uses explicit `--`; source trees reject
symlinks, hardlinks, traversal, and special files. Publish the archive digest
and ledger entry, and retain failed/invalid runs without rewriting answers.

## Verify Sealed Evidence

An independent verifier must obtain the archive digest and policy-authority key
through authenticated channels separate from the archive. Verify the published
archive and every nested manifest from a fresh directory:

```sh
: "${SEALED_ARCHIVE:?set to the absolute .evidence.tgz path}"
shasum -a 256 -c -- "$SEALED_ARCHIVE.sha256"
tar -tvzf "$SEALED_ARCHIVE"
```

Before extraction, reject any listing with more than one top-level root,
absolute or dot/dot-dot paths, backslashes, symlinks, hardlinks, devices, or
other special entries. After that independent path/type review passes, verify
the nested manifests:

```sh
: "${SEALED_ARCHIVE:?set to the already digest-verified .evidence.tgz path}"

VERIFY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/loom-evidence-verify.XXXXXX")"
SEALED_ROOT_NAME="$(basename "${SEALED_ARCHIVE%.evidence.tgz}")"
tar -xzf "$SEALED_ARCHIVE" -C "$VERIFY_DIR"

(cd "$VERIFY_DIR/$SEALED_ROOT_NAME" && \
  shasum -a 256 -c -- EVIDENCE-MANIFEST.sha256)
(cd "$VERIFY_DIR/$SEALED_ROOT_NAME/prepared" && \
  shasum -a 256 -c -- ROOT-MANIFEST.sha256)
(cd "$VERIFY_DIR/$SEALED_ROOT_NAME/prepared/review" && \
  shasum -a 256 -c -- PREPARATION-MANIFEST.sha256)
(cd "$VERIFY_DIR/$SEALED_ROOT_NAME/review-handoff" && \
  shasum -a 256 -c -- HANDOFF-MANIFEST.sha256)
```

Compare the verified archive digest, run id, nonce, candidate/core revision,
candidate and optional package digests, reviewer identity, and ledger URL to the
independent release and ledger records. Reverify the policy, reviewer, and
ledger signatures under their three namespaces using the externally obtained
registered keys. Digest integrity alone does not turn an `invalid` or `fail`
evaluation into a pass, prove package build provenance, or establish release
readiness.
