# Loom: checked transcript conversion core

Loom is the Lean 4 semantic core for [`agent-convert`](https://github.com/theoriclabs/agent-convert).
This repository is [`theoriclabs/agent-convert-lean`](https://github.com/theoriclabs/agent-convert-lean). It models agent
transcripts as a format-neutral IR, records conversion judgments, and refuses
known destructive exports. Pi is one target format, not the semantic hub.

## Current status

This checkout is an **experimental developer-preview candidate**, not an
approved developer preview, release-ready artifact, or stable/default release.
The checked state is:

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

`previewCatalogueChecksPass=false` is an upstream declaration sentinel:
`AgentConvert.lean` cannot import downstream implementation proofs, so its
`requirementCatalogueReady` deliberately returns false. The release-relevant
Lean-side check is downstream in `Proofs.lean`, where
`verifiedLeanEvidenceBundle` binds proof terms to the closed internal evidence
keys before computing `previewProofBoundCatalogueEligible`. That proof-bound
value is also currently false, and
`previewProofBoundReadinessAssessment=catalogueBlocked`.

Pure readiness is intentionally fail-closed. A proof-bound assessment can
return only `catalogueBlocked` or `externalDecisionRequired`; neither value
authorizes a release. If proof-bound catalogue eligibility eventually passes,
Lean returns `externalDecisionRequired` so release tooling and authorized
humans can assess candidate-bound external evidence. The booleans
`previewReady` and `stableReady` always remain false by construction and must
never be used as release conditions.

Lean currently proves the real pure `runPipeline` boundary exactly: structural
gate failure, blocker failure, and the selected exporter's complete
`Except` result. Successful runs are well formed, unblocked, and return exactly
the exporter bytes. The proof-bearing internal bundle covers E-002, E-003,
E-004, E-005, E-009, E-014, E-022, E-028, E-032, E-035, and E-036. E-036
discharges only F-032's synthetic internal context-isolation fixture census. It
does **not** prove the full abstract D/S refinement, external target-harness
consumption, or semantic fidelity for every advertised source/target slice.
Those remain open or candidate-bound as recorded in the requirements ledger.

E-037 is not in that Lean proof bundle. It is candidate-only differential
evidence for a finite 8-source by 5-target lifecycle matrix and remains pending
until an immutable run against the retained release binary records all 40 cells.
For refusal cells it checks unchanged post-exit prior-artifact path identity,
opened-file identity, mode, size, digest, and exact bytes. That is a finite
before/after observation, not continuous monitoring or an atomicity proof.
E-037 is not a Lean key, universal proof, real-harness result, or trusted build
provenance. Real-harness historical-call non-execution remains the separate
F-029 obligation.

There are two distinct operational gates:

- **Experimental developer-preview candidate gate:** build and test an
  immutable core and package candidate so external validation can run. Passing
  it permits evaluation only.
- **Developer-preview gate:** require the preview catalogue, candidate-bound
  validation, immutable package/core binding, license authorization, and an
  explicit external approval. This gate is not currently satisfied.

See [`RELEASE_CHECKLIST.md`](./RELEASE_CHECKLIST.md) for the release procedure,
[`REQUIREMENTS.md`](./REQUIREMENTS.md) for the normative requirements,
[`REQUIREMENTS_EVIDENCE.md`](./REQUIREMENTS_EVIDENCE.md) for evidence and open
obligations, and [`HUMAN_VALIDATION.md`](./HUMAN_VALIDATION.md) for the blinded
review protocol.

## Lean libraries

The Lake package declares four `lean_lib` targets with one-way dependencies:

| Library | Responsibility | Dependency rule |
|---|---|---|
| `Loom` | Transcript vocabulary, IR, provenance, validity, rendering, and per-format descriptions | Imports none of the other three libraries |
| `LoomOps` | Export obligations, conversion policy, defects, and evaluation | Imports `Loom` |
| `LoomConvert` | Importers, exporters, target policy application, file publication, sidecars, and the Cursor IDE actuator | Imports `Loom`; policy-aware Claude, Codex, and CLI modules also import `LoomOps.Conversion` |
| `LoomRequirements` | Jackson-Zave requirements, traceability, proofs, finite witnesses, and external worklists | Directly imports `LoomConvert.Main` and `Loom.Claims`, and therefore transitively depends on all three product libraries; none imports it |

The `loom` executable uses `LoomConvert.Main`. The declared source formats are
`loom`, `pi`, `claude`, `codex`,
`cursor-agent`, `hermes`, `gais`/`google-ai-studio`, and `cursor-ide`. The
declared targets are `loom`, `pi`, `claude`, `codex`, and `cursor-agent`.
Declared support is not a claim that every cross-format pair is lossless or
release-approved.

## Artifacts and ownership

Keep these workflows separate:

| Artifact | Repository role | Release workflow |
|---|---|---|
| Loom Lean core (this repo) | Owns parsing, IR, policy, rendering, and file/SQLite actuators | Build the immutable `.lake/release/loom` from a clean commit |
| TypeScript compatibility host | Thin `convert-to-pi` / `agent-convert` launcher; discovers an external Loom binary | Tested against this core via `LOOM_BIN` / `LOOM_UTILS_ROOT` |
| Public `agent-convert` npm package | Separate public package; thin cross-format process/path/install host | Pack and clean-install the exact tarball against an external core that matches an immutable package manifest |

The npm package does not currently contain or acquire the core and is not ready
for publication. A release must keep the external-core prerequisite explicit,
bind the package to the exact accepted core identity and digest, and prove both
matching-core success and missing/wrong-core refusal from a clean packed
install.

## Versions and probes

A **contract pin** is enforced by the build, CLI identity, or checked exporter.
A **validation probe** is the release team's currently chosen external binary
or provider/model configuration. A probe choice is not a parser restriction.

| Component | Value | Classification |
|---|---|---|
| Lean | `4.28.0` | Build contract pin |
| Loom core | `0.2.0-preview.0` | CLI/package identity contract pin |
| Claude Code | `2.1.216` | Claude export contract pin and current external validation probe |
| Codex CLI | `0.144.1` | Codex export contract pin and current external validation probe |
| Pi | `0.74.0` | Pi export contract pin and current external validation probe |
| Cursor Agent | `2026.07.09-a3815c0` | Current external file-source/file-target validation probe only; the core does not stamp or restrict a Cursor Agent version |

The current Pi continuation probe chooses provider/model
`deepseek`/`deepseek-v4-flash`; the current Codex probe chooses
`openai`/`gpt-5.5`. Loom requires nonempty provider/model values for those
foreign targets but does not restrict them to these probe choices. Pi also
rejects its reserved assistant-history provider/model identity.

Claude Code `2.1.206` and Cursor Agent `2026.05.28` appear only in the historical
V-012 and V-013 records in
[`REQUIREMENTS_EVIDENCE.md`](./REQUIREMENTS_EVIDENCE.md). They are evidence
references, not current release criteria, and must not satisfy a checklist item.

## Build and identity

```sh
lake build loom
lake exe loom version
```

The development binary is `.lake/build/bin/loom` and normally reports
`coreRevision: "working-tree"`. That binary is for development only. The
release runbook builds `.lake/release/loom` from a clean commit and verifies a
full 40-character revision. Its automated gate separately builds
`LoomRequirements`; this CLI smoke does not substitute for that gate.

## CLI

```text
loom convert <from> <to> <input> [output]
  [--target-cwd <dir>] [--target-provider <name>]
  [--target-model <name>] [--target-session-id <uuid>]
  [--target-timestamp <utc>] [--target-harness-version <version>]
  [--pi-assistant-history <context|carrier>]
  [--target-codex-approval-policy <untrusted|on-failure|on-request|never>]
  [--target-codex-network-access <true|false>]
  [--target-codex-exclude-tmpdir-env-var <true|false>]
  [--target-codex-exclude-slash-tmp <true|false>]
  [--target-codex-summary <auto|concise|detailed|none>]
  [--json] [--ts-parity] [--with-subagents|--no-subagents]
loom inspect <from> <input> [--json] [--with-subagents|--no-subagents]
loom detect <input> [--json]
loom version [--json]
loom self-test-sidecar-publication
loom cursor-ide <state.vscdb> <composer-id> <to> [output] [target options]
```

Target launch metadata belongs to the new target. It never overwrites source
`EnvInfo`; source identity and environment remain typed provenance or an inert
carrier. Retargeted output fails closed when its launch bundle is incomplete.

| Target | Mandatory metadata for a foreign source | Current contract |
|---|---|---|
| Loom wire | None | `schema: "loom.transcript.v0"`; preserves modeled threads |
| Pi | cwd, provider, model, session id, UTC timestamp, harness version | Harness version must be `0.74.0`; provider/model must not use the reserved history identity |
| Claude Code | absolute cwd, UUID session id, UTC timestamp, harness version | Harness version must be `2.1.216` |
| Codex CLI | absolute cwd, provider, model, UUID session id, UTC timestamp, harness version, and all five Codex controls | Harness version must be `0.144.1` |
| Cursor Agent | No launch bundle is accepted by the JSONL target | File output only; runtime metadata it cannot encode is reported or refused; no resume/install claim |

`--ts-parity` is a Codex compatibility diagnostic against the old TS
convert-path projection. It is not the product default and does not establish
semantic correctness. Subagent sidecars default on for `inspect` and for
targets that can keep threads (`loom`, `claude`, `cursor-agent`). Flat
targets (`pi`, `codex`) stay main-branch unless `--with-subagents` is
explicit (they still refuse non-main threads rather than flatten). Use
`--no-subagents` to force main-branch-only import/export.

## Detect, inspect, and Cursor IDE

`detect` parses JSON/JSONL and classifies structured envelope fields inside the
Lean core. It rejects malformed, ambiguous, empty, or unrecognized input. Thin
hosts may invoke it but do not inspect transcript bytes themselves.

`inspect` imports and validates one source without writing a target artifact or
harness index. Human output shows engine identity, roles, ordering, threads,
tool calls/results and links, error provenance, dispositions, and import
judgments. `--json` returns engine identity plus the canonical
`loom.transcript.v0` object and exact retained provenance. With
By default, inspection also reads the source's sidecar files; pass
`--no-subagents` to inspect the main branch only.

After the build above:

```sh
LOOM=.lake/build/bin/loom
"$LOOM" detect parity/fixtures/claude.jsonl
"$LOOM" inspect claude testdata/claude/control-envelopes.jsonl \
  | sed -n '1,18p'
```

Output begins:

```text
claude
# Engine

engine: lean
engine version: 0.2.0-preview.0
core revision: working-tree
source: claude
```

Cursor IDE has two separate inputs:

- `loom convert cursor-ide ...` consumes a read-only JSON snapshot containing
  `composer`, `workspaceIdentifier`, and ordered `bubbles`.
- `loom cursor-ide <state.vscdb> <composer-id> ...` is the SQLite actuator. It
  runs system `sqlite3 -readonly -batch`, assembles the same snapshot, and then
  calls the pure importer. Missing `sqlite3`, missing rows, query errors, and
  malformed JSON are import failures. It never silently switches to TS.

An actuator smoke using the checked database is:

```sh
LOOM=.lake/build/bin/loom
"$LOOM" cursor-ide test.vscdb cmp-fix loom \
  /tmp/loom-readme-cursor-ide.loom.json
```

## Runnable conversions

Conversion examples provide the complete metadata
required by their target. Reuse the sample identities only for disposable
files, never for a real target session.

The chosen Pi validation probe uses provider/model
`deepseek` / `deepseek-v4-flash`; these values are not a Loom restriction:

```sh
LOOM_BIN=.lake/build/bin/loom \
  node_modules/.bin/tsx src/convertToPi.ts --json claude \
  testdata/release/continuation-source.claude.jsonl \
  /tmp/loom-readme.pi.jsonl \
  --target-cwd /tmp/loom-readme-pi \
  --target-provider deepseek \
  --target-model deepseek-v4-flash \
  --target-session-id 74000000-0000-4000-8000-000000000074 \
  --target-timestamp 2026-07-21T18:15:00.000Z \
  --target-harness-version 0.74.0 \
  --pi-assistant-history context \
  | node -e '
const fs = require("node:fs");
const j = JSON.parse(fs.readFileSync(0, "utf8"));
console.log(JSON.stringify({
  engine: j.engine, engineVersion: j.engineVersion, from: j.from, to: j.to,
  targetCwd: j.targetCwd, targetProvider: j.targetProvider,
  targetModel: j.targetModel, targetSessionId: j.targetSessionId,
  targetTimestamp: j.targetTimestamp,
  targetHarnessVersion: j.targetHarnessVersion,
  targetResumable: j.targetResumable
}, null, 2));'
```

Output:

```json
{
  "engine": "lean",
  "engineVersion": "0.2.0-preview.0",
  "from": "claude",
  "to": "pi",
  "targetCwd": "/tmp/loom-readme-pi",
  "targetProvider": "deepseek",
  "targetModel": "deepseek-v4-flash",
  "targetSessionId": "74000000-0000-4000-8000-000000000074",
  "targetTimestamp": "2026-07-21T18:15:00.000Z",
  "targetHarnessVersion": "0.74.0",
  "targetResumable": true
}
```

The chosen Codex validation probe uses `openai` / `gpt-5.5`. Loom accepts other
nonempty provider/model values, but every Codex export still requires all five
controls:

```sh
LOOM=.lake/build/bin/loom
"$LOOM" convert claude codex \
  testdata/release/continuation-source.claude.jsonl \
  /tmp/loom-readme.codex.jsonl \
  --target-cwd /tmp/loom-readme-codex \
  --target-provider openai \
  --target-model gpt-5.5 \
  --target-session-id 72000000-0000-4000-8000-000000000144 \
  --target-timestamp 2026-07-21T18:05:00.000Z \
  --target-harness-version 0.144.1 \
  --target-codex-approval-policy on-request \
  --target-codex-network-access false \
  --target-codex-exclude-tmpdir-env-var true \
  --target-codex-exclude-slash-tmp true \
  --target-codex-summary auto \
  --json \
  | node -e '
const fs = require("node:fs");
const j = JSON.parse(fs.readFileSync(0, "utf8"));
console.log(JSON.stringify({
  engine: j.engine, engineVersion: j.engineVersion, from: j.from, to: j.to,
  targetCwd: j.targetCwd, targetProvider: j.targetProvider,
  targetModel: j.targetModel, targetSessionId: j.targetSessionId,
  targetTimestamp: j.targetTimestamp,
  targetHarnessVersion: j.targetHarnessVersion
}, null, 2));'
```

Output:

```json
{
  "engine": "lean",
  "engineVersion": "0.2.0-preview.0",
  "from": "claude",
  "to": "codex",
  "targetCwd": "/tmp/loom-readme-codex",
  "targetProvider": "openai",
  "targetModel": "gpt-5.5",
  "targetSessionId": "72000000-0000-4000-8000-000000000144",
  "targetTimestamp": "2026-07-21T18:05:00.000Z",
  "targetHarnessVersion": "0.144.1"
}
```

Claude native sidecar export supplies the full Claude target bundle:

```sh
LOOM=.lake/build/bin/loom
"$LOOM" convert loom claude \
  testdata/wire/sidechain-detached.v0.json \
  /tmp/loom-readme-claude.jsonl \
  --target-cwd /tmp/loom-readme-claude \
  --target-session-id 73000000-0000-4000-8000-000000000216 \
  --target-timestamp 2026-07-21T18:10:00.000Z \
  --target-harness-version 2.1.216
test -f /tmp/loom-readme-claude/subagents/agent-0001.jsonl
test -f /tmp/loom-readme-claude/subagents/agent-0001.meta.json
```

## Output and refusal contract

The CLI renders and validates before publication. Invocation errors exit `1`,
import errors exit `2`, and export/validation/publication errors exit `3`.
`--json` conversion requires an output path.

Single-file output is written exclusively to
`<output>.agent-convert-stage` and renamed into place only after a complete
render. An existing stage path or directory destination is refused. On a
preflight or import/export refusal, no candidate output is published; an
existing destination is not presented as this invocation's result.

Flat exporters refuse sidechain/detached threads, destructive obligations, or
invalid target prerequisites rather than silently flattening or fabricating a
launch bundle. Use Loom wire when the target cannot represent required facts.

## Sidecar publication

Claude and Cursor Agent sidecar exports coordinate a main file with a generated
directory:

| Family | Main output example | Exact sidecar directory | Generated names |
|---|---|---|---|
| Claude | `/tmp/root.jsonl` | `/tmp/root/subagents` (strip `.jsonl`, then append `/subagents`) | `agent-0001.jsonl`, `agent-0001.meta.json`, ... |
| Cursor Agent | `/tmp/session/root.jsonl` | `/tmp/session/subagents` | `child-0001.jsonl`, `child-0001.meta.json`, ... |

The converter owns a pre-existing sidecar directory only when every immediate
entry has an allowed generated name for the current export and is a regular
file. Unexpected files, nested directories, symlinks, special entries, a
non-directory sidecar path, or a non-regular main destination cause refusal;
none is deleted or overwritten.

The four reserved recovery paths are exact:

```text
<main>.agent-convert-stage
<sidecar-dir>.agent-convert-stage
<main>.agent-convert-backup
<sidecar-dir>.agent-convert-backup
```

If any reserved path already exists, the next run refuses and does not recover
or delete it automatically. Publication stages the complete generation,
rechecks ownership, hides the old main, swaps sidecars while no main marker is
visible, and publishes the new main last. A commit failure attempts rollback;
an incomplete rollback keeps recovery paths for inspection and publishes no
candidate main marker.

A successful commit can still print a warning if old backup cleanup fails. The
warning means the new main and sidecars are a matching published generation,
but backup state remains or needs inspection. Exit status remains success; the
next export refuses that stale state. Treat the warning as a release failure,
preserve the paths for diagnosis, and never delete them without verifying which
generation they contain.

## Engine selection and rollback

The utils conversion host defaults to Lean and resolves `LOOM_BIN`, the checkout
build, or `loom` on `PATH`. Missing core, unsupported source, or a legacy-only
option is an actionable error. It never silently changes semantic engines.

TypeScript rollback is opt-in for one invocation through the exact selector
`PI_CONVERT_ENGINE=ts`; without that value, conversion never enters the legacy
module.

The public package uses `--engine ts-legacy` or
`AGENT_CONVERT_ENGINE=ts-legacy` for the same explicit rollback boundary. TS
results are compatibility behavior, not evidence for the Lean candidate, and a
release rerun must keep them separate from default-engine results.

## Claim discipline

Builds, proofs, fixtures, and differential projections establish only their
named scopes. They do not establish undocumented vendor semantics, format
completeness, arbitrary losslessness, full confidence, stable/default parity,
or current real-harness behavior. Such claims require retained evidence bound
to the exact core revision, binary/package digests, applicable contract pins,
recorded validation-probe versions, and external approval.
