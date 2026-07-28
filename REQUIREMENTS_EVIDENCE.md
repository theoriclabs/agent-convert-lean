# agent-convert/Lean Requirements Evidence

Evidence date: 2026-07-21. Baseline commit at start of this work:
`28288eec264911abed787f189d1fc0a383df9146`. This identifies ancestry only,
not the uncommitted candidate under review. External evidence is not qualified
for readiness until it names an exact candidate revision and retained digest.

This ledger answers two different questions:

1. Is the reduction from world requirements to machine behavior logically
   adequate under explicit domain assumptions?
2. Does the current implementation satisfy the machine behavior, and how do we
   know?

It does not use a fixture test to claim a universal theorem, and it does not use
a Lean theorem to claim facts about undocumented vendor behavior.

In Jackson-Zave terms, W supplies the problem-world vocabulary and context, D
contains indicative environmental bridges, R is the optative problem-world
outcome, and S constrains shared machine-controlled interface phenomena. A
proof that D and S entail R is an adequacy argument. It is not evidence that D
is true, and it is not evidence that the implementation realizes S.

## Evidence Classes

| Class | Establishes | Does not establish |
|---|---|---|
| Lean theorem | A proposition for every value satisfying its premises | Truth of external domain premises |
| `native_decide` pin | A decidable proposition for the enumerated model/fixture | All possible vendor inputs |
| Fixture/CLI test | End-to-end behavior on checked-in artifacts | Corpus representativeness |
| Differential test | Agreement under a named projection and oracle | That the oracle is semantically correct |
| Corpus validation | Observed behavior over a named real dataset/date | Future schema stability |
| Harness validation | Real target accepts/interprets output | Every target version/environment |

## Universal Proofs

### E-001: concrete catalogue adequacy

[`concreteCatalogueConversionAdequacy`](./LoomRequirements/AgentConvert.lean)
proves:

```text
concreteConversionDomain w
  -> concreteConversionSpec w
  -> concreteConversionRequirement w
```

Typed designations map D-003/D-010/D-011/D-012, the required-success and
classified-refusal S clauses, R-003/R-004/R-014, and the top-level safe-refusal
outcome onto the abstract facets. Product-constraint R-008 is separately
designated to S-004; it is not smuggled into the abstract Jackson-Zave R. For
any conversion situation, S states only observable interface facts:
the machine emitted target-valid output, source/target common projections agree,
and every source fact has a complete loss disposition. D separately bridges
those facts to target consumption, problem-world meaning, absence of silent
loss, and recognized non-consumption after a refusal. The theorem derives the
designated R facets under those premises.

This is an abstract reduction schema, not evidence that the program satisfies
S and not evidence that D is true. Its explicit conditional is essential: Lean
does not prove that Claude, Codex, Cursor, pi, Hermes, or Google will keep a
particular undocumented format contract. `safeFailureAdequacy` makes the
separate failure reduction explicit: a machine refusal and no new artifact
prevent consumption only under D-010's caller behavior.

The surrounding requirements problem is checked rather than left as prose:
`referenceProblemWellPosed = true` establishes that the concrete D catalogue
is indicative domain knowledge, the top-level R is optative, and every S clause
is implementable at the shared interface.
`validationWorklistMatchesDomainAssumptions = true` establishes that every
falsifiable assumption in D appears on the external validation worklist. These
are typing and well-posedness results, not proof that the assumptions are true.

### E-002: exact concrete pipeline boundary

[`runPipelineOkImpliesWellFormed`](./LoomRequirements/Proofs.lean) proves for all
formats, transcripts, and outputs:

```text
runPipeline from to transcript = ok output
  -> Loom.WellFormed transcript
```

[`runPipelineInvalidRefuses`](./LoomRequirements/Proofs.lean) proves the
contrapositive operational obligation: a transcript with a non-empty violation
list cannot produce an `ok` result through the pure pipeline.

[`runPipelineRefinesSuccessfulRunObservableSpec`](./LoomRequirements/Proofs.lean)
additionally proves for every successful pure run that no declared export
blocker remains and `exportByFormat` produced the exact returned bytes. This is
universal proof evidence for the successful boundary.

`runPipelineRefinesConcreteMachineSpec` is the stronger result attached to
E-002. For every invocation and for both success and failure, the real
`runPipeline` result equals the modeled sequence: exact structural-gate error,
exact blocker error, or the selected exporter's exact `Except` result. The
corollaries `runPipelineStructuralGateFailureExact`,
`runPipelineBlockerFailureExact`, and `runPipelineExporterResultExact` expose
those branches directly.

This is still not an instantiation of `ImplementationRefinesConversionSpec`:
no concrete `run` and independent `observe` pair is proved to agree on importer
outcome, support and refusal applicability, semantic criteria, destination-byte
observations, typed success/refusal outcome, and complete `ConversionSpec` for
every input. `RunPipelineFullConversionRefinementObligation` names that open
relation. Target-harness consumption and semantic fidelity still require
adapter-specific and candidate-bound validation; E-001 cannot manufacture
those premises.

The accepted-source refusal branch is typed and closed over
`unsupportedTarget`, `destructiveLoss`, `missingTargetPrerequisites`, and
`invalidTargetPrerequisites`. Import rejection, invocation error, host failure,
and core unavailability precede this post-import support decision and are not
misclassified as one of those causes.

### Proof-bearing internal evidence bundle

`verifiedLeanEvidenceBundle` contains theorem terms for every current
Lean-qualified readiness key. Claim text and locator strings cannot construct
the bundle.

| Evidence | Bound proposition |
|---|---|
| E-002 | Exact concrete `runPipeline` machine refinement plus successful-run observable characterization |
| E-003 | `allImportWitnessesPass = true` |
| E-004 | `allRoundTripWitnessesPass = true` |
| E-005 | `structuralCounterexamplesRejected = true` |
| E-009 | `wireCompatibilityLeanEvidence = true` |
| E-014 | Tool-distinguishing continuation projection and Claude-to-Codex, native Codex, and Pi continuation witnesses |
| E-022 | Exact Codex runtime controls are archived outside conversation |
| E-028 | Codex target-policy summary counts reconcile with exporter eligibility |
| E-032 | Inspect hides encrypted thinking-signature bytes while canonical JSON retains them |
| E-035 | Claude, Codex, and Pi historical tool carriers remain non-native typed historical artifacts |
| E-036 | `contextIsolationF032Aggregate = true` for the synthetic internal role-family census |

E-001 has a real proof-bearing adequacy binding, but its role is
`adequacyArgument`, not implementation refinement or release readiness, so it
is intentionally absent from this readiness bundle.

E-036 discharges only F-032's synthetic internal-fixture obligation. E-037 is
intentionally absent from the closed Lean evidence-key type: it is a
candidate-only differential claim pending an immutable retained run, not a Lean
key, universal proof, real-harness observation, or trusted build-provenance
record.

### Additional theorem: non-main flat export is blocked

[`nonMainFlatExportIsBlocked`](./LoomRequirements/Proofs.lean) proves that a
non-Loom single-file target receives a blocker whenever non-main threads exist.
The separate sidecar path is explicit and requires an output path.

## Structural Proof Surface

The former validator checked that a result referenced an earlier entry, but not
that its block existed or was a tool call. `Loom.WellFormed` now also checks:

- exactly one main thread;
- every parent remains within its child's thread;
- every result reference names an existing assistant tool-call block;
- every sidechain anchor is resolved, names a tool call, and points into the
  main thread;
- the declared active leaf has no child;
- the prior bounds, ordering, thread-index, unresolved-result, and compaction
  checks.

`structuralCounterexamplesRejected` pins one valid reference transcript and
specific counterexamples for bad block indexes, references to text, cross-thread
parents, non-leaf active pointers, invalid sidechain anchors, and missing main
threads.

## Finite Verification Witnesses

`allImportWitnessesPass = true` checks one accepted pure-import fixture for:

- Loom wire
- pi
- Claude Code
- Codex CLI
- Cursor Agent
- Hermes
- Google AI Studio
- Cursor IDE's pure `{composer,bubbles}` importer

The SQLite actuator remains an IO validation in `scripts/verify.sh`.

`allRoundTripWitnessesPass = true` checks:

- pi import/export stability;
- Claude import/export stability;
- Codex import/export stability;
- Cursor Agent import/export stability under its declared projection;
- Loom wire thread-metadata preservation;
- Loom wire exact source/import equality over every serialized IR field, plus
  independent closed-enum codec pins and export/import/export idempotence.

Wire pins additionally reject the wrong schema and missing required fields,
accept numeric/string index compatibility, and preserve additive unknown fields
and labels through explicit escape hatches.

`allSchemaClaimsCurrentlyConfirmed = true` checks that all 20 entries in the
current Loom claims register carry `confirmed` status. That means the register
has no self-declared open claim; it does not waive the separate product
requirements in this document.

## Historical External Validation Ledger

`V-001` through `V-013` are an immutable historical ledger. Their dates,
versions, identifiers, results, and scopes are preserved verbatim. They describe
what was observed at the time; none is bound to the current candidate revision,
package digest, core binary digest, or sealed release evidence archive. They
therefore cannot satisfy a current external-validation obligation without a
candidate-bound rerun or an independently retained and verified candidate
binding.

| Evidence | Dataset and projection | Result | Scope |
|---|---|---|---|
| V-001 | Codex full local corpus, `--ts-parity`, 2026-07-08 | 433 files: 429 agree, 0 diverge, 4 TS-only empty/no-importable refusals | Every file the TS converter accepted agreed |
| V-002 | Claude local corpus, declared TS-parity projection, 2026-07-08 | 237/237 agree | Projection drops adjudicated Loom enrichments |
| V-003 | Cursor Agent local corpus, declared TS-parity projection, 2026-07-08 | 427/427 agree | Content-level due source identity/time/result limits |
| V-004 | Checked-in release fixtures | pi, Claude, Codex, Cursor Agent differential gates pass | Fast repeatable gate, not corpus proof |
| V-005 | Cursor IDE fixture database + system `sqlite3` | Explicit Lean actuator produces expected four-entry transcript | Environment-dependent actuator only |
| V-006 | Utils thin-launcher static and differential gate | `utils/src/convertToPi.ts` imports no format adapters or transcript IO; launcher/direct-Lean artifacts are byte-identical; implicit fallback cases refuse | Establishes the boundary only for that import-to-pi launcher, not the separately packaged cross-format CLI |
| V-007 | Real Codex 0.144.1 session `019f4ace-fd03-7830-8a11-2004ef0aa577` converted by the TS package and opened in Claude Code 2.1.204, 2026-07-09 | Target opened, but Codex developer permissions, skills, environment context, and other control-plane records appeared as Claude user prompts. Import reported 107 calls and 105 results; export synthesized two interrupted results, but no field-by-field reconciliation was produced | Negative validation for R-016/R-018 and incomplete evidence for R-017; the generated Claude session is not an acceptable release witness |
| V-008 | Fresh tool/control-rich Claude fixture converted through the public package, installed, opened, continued, and re-read in Codex CLI 0.144.1, 2026-07-09 | Target `9a14d808-1bc4-4460-a97f-cede25e5c82c` opened with detected `cli_version=0.144.1`, no stamped model warning, no raw Claude controls, and foreign tools as non-executable history. `AGENT_CONVERT_FRESH_RESUME_OK_20260709` was appended by the real model and recovered by `inspect`; 10,961 input / 17 output tokens | Positive validation for the Claude-to-Codex slice of R-014/R-017/R-018; does not discharge other target directions |
| V-009 | Immutable snapshot of held-out Codex session `019f4ace-fd03-7830-8a11-2004ef0aa577`, converted by the rebuilt public package through Loom's resumable latest-compaction projection and independently audited by `scripts/audit-codex-claude.mjs`, 2026-07-09 | 77 active-context source calls = 77 occurrence-addressed non-native Claude call carriers; 76 source results = 76 result carriers; 0 native historical tool records; zero synthetic results; complete ordered IDs/names/arguments/result blocks/error provenance matched; 0 linkage mismatches; 7 exact active-context control texts identified and zero appeared as standalone target conversation turns. The full Loom audit surface retains 1,765 calls and 1,763 results, but cross-harness continuation intentionally follows the context Codex itself would resume. | Positive artifact-level evidence for this Codex-to-Claude slice of R-016/R-017/R-018; real Claude open/append/re-read remains required for R-014 |
| V-010 | Fresh tool/control-rich Claude fixture converted by the thin Lean-default package, installed, rendered, continued, and re-read in Codex CLI 0.144.1, 2026-07-09 | Target `a22b23de-1cd2-4e19-b484-ac27f57d50ef` rendered all imported user/assistant turns plus readable non-executable historical tool records in the real TUI. The real model appended `LEAN_APPEND_SAFE_OK_20260709` (11,385 input / 12 output tokens); Lean re-imported 8 conversation entries with 0 violations, archived both the current developer control record and the multi-block `recommended_plugins` + `environment_context` user control record, and retained the sentinel. | Positive Lean-default package evidence for R-013/R-014/R-016/R-018 on the Claude-to-Codex slice; does not discharge other targets or npm core acquisition |
| V-011 | Checked Codex tool/control fixture converted by the thin Lean-default package, installed in an isolated store, and opened in Claude Code 2.1.206, 2026-07-09 | Target `66666666-7777-4888-8999-aaaaaaaaaaaa` was discovered at the physical-cwd project path and rendered the genuine conversation plus all 3 historical calls and 2 historical results as explicitly non-executable history. No raw Codex control envelope appeared in dialogue. The isolated Claude store was not authenticated, so a model sentinel could not be generated. Separately, a failed unauthenticated turn appended to target `55555555-6666-4777-8888-999999999999` without corrupting JSONL; Lean re-imported 9 entries with 0 violations and restored the carriers. | Positive R-013/R-017/R-018 target-render evidence and append-structure evidence; its R-014 gap is superseded by authenticated V-012, but neither row is candidate-bound yet |
| V-012 | Checked conversation `testdata/release/continuation-source.claude.jsonl` converted by the thin package and resumed in authenticated Claude Code 2.1.206, Codex 0.144.1, and pi 0.74.0, 2026-07-10 | Claude target `52000000-0000-4000-8000-000000000206`, Codex target `54000000-0000-4000-8000-000000000144`, and pi target `51000000-0000-4000-8000-000000000074` each answered exactly `VIOLET-LEDGER-731`, proving the prior imported assistant turn reached model context. Loom then re-imported 4, 5, and 5 entries respectively with 0 violations. Codex runtime controls remained outside USER/ASSISTANT turns. | Positive R-014 evidence for every target advertised as resumable in the preview; simple-conversation scope, combined with V-010/V-011 for tool/control-rich rendering |
| V-013 | Same checked conversation written to the observed local Cursor Agent transcript layout and resumed with Cursor Agent 2026.05.28, 2026-07-10 | Target `53000000-0000-4000-8000-000000202605` accepted the id but reported no prior assistant message, removed the two seeded records, and replaced the file with a new 10-record cloud-backed turn. `create-chat` exposes no history-import option. The package now refuses Cursor `--install`. | Disconfirming D-003/R-014 evidence: Cursor remains a file source/target, but is not advertised as a resumable installation target |

The current pins are Lean 4.28.0, Loom core 0.2.0-preview.0, Claude Code
2.1.216, Codex 0.144.1, Pi 0.74.0, and Cursor Agent
2026.07.09-a3815c0. The older Claude and Cursor versions above remain historical
and non-candidate-bound; they have not been silently promoted to current
validation. Candidate external runs remain pending.

These results support D-001 for the versions and corpora observed and apply
validation policy VP-001 by adjudicating, rather than blindly accepting,
TypeScript differentials. Individual rows provide conditional evidence for
D-003 and D-008 through D-012. They must be rerun after material harness schema
changes and against the immutable release candidate.

V-007 is deliberately recorded as disconfirming evidence. A target merely
opening the file does not establish a faithful conversion.

V-008 also exposed current Codex runtime records (`permissions`, skills/apps,
and `environment_context`) on the appended turn. Exact whole-message records
are now excluded from conversation and retained verbatim in
`codexExtras.rawControlMessages`; the real re-import archived two controls and
kept the sentinel at the active leaf. This fixes the observed current-Codex
shape without treating arbitrary XML-like user text as control data.

V-010 caught two target-contract defects that internal round trips could not
expose. First, a semantic-only rollout did not render imported history in the
Codex TUI; target export now emits the paired `event_msg` display records while
the importer deduplicates them on re-read. Second, the rollout lacked a final
newline, so Codex concatenated its first appended JSON object onto the final
imported object. Codex export now has a compile-time terminal-delimiter pin.
The rerun used a fresh session and passed display, append, and re-import checks.

V-011 establishes a narrower reciprocal fact. Claude's real session browser and
TUI accept the artifact, display the selected conversation, and do not execute
foreign historical tools. It does not establish successful continuation because
the isolated target store had no authenticated account. The failed-turn append
does establish that every JSONL exporter must end at a record boundary; compile-
time pins now enforce a terminal newline for Claude, Codex, pi, and Cursor Agent.

V-012 closes that authentication gap with one shared, checked conversational
witness across Claude, Codex, and pi. The pi re-read also exposed a review-surface
defect: human inspect printed an opaque encrypted thinking signature. Human output
now reports only `signature=present`; canonical JSON retains the exact payload.

V-013 prevents a false positive from becoming product behavior. Matching an
observed Cursor JSONL path and record shape does not establish importability when
the harness resumes cloud chat state. Cursor installation was removed rather than
claiming that a destructive local copy continues a conversation.

## Traceability Result

The Lean catalogue checks all of the following in every build:

```text
catalogueComplete          = true
catalogueHasFitCriteria    = true
contextCatalogueWellFormed = true
validationPoliciesWellFormed = true
stakeholderGoalCoverage    = true
domainCatalogueWellFormed  = true
specificationInterfaceMetadataWellFormed = true
referenceProblemWellPosed   = true
validationWorklistMatchesDomainAssumptions = true
traceabilityComplete       = true
catalogueLevelsWellFormed  = true
previewScopeMatchesReference = true
concreteReductionDesignationsWellFormed = true
fitObligationsWellFormed   = true
leanEvidenceWorklistWellFormed = true
fitObligationEvidenceStatusesSound = true
traceSummariesMatchFitObligations = true
externalValidationWorklistWellFormed = true
catalogueIntegrityGate     = true
previewCatalogueChecksPass = false
stableCatalogueChecksPass  = false
previewReadinessAssessment = .catalogueBlocked
stableReadinessAssessment  = .catalogueBlocked
previewEvidenceDeclarationsComplete = false
stableEvidenceDeclarationsComplete  = false
previewProofBoundCatalogueEligible = false
stableProofBoundCatalogueEligible  = false
previewProofBoundReadinessAssessment = .catalogueBlocked
stableProofBoundReadinessAssessment  = .catalogueBlocked
previewReady               = false
stableReady                = false
```

The upstream `previewCatalogueChecksPass=false` is deliberately a declaration
sentinel because `AgentConvert.lean` cannot import `Proofs.lean`. The downstream
proof-bound value is the substantive Lean-side catalogue check, and it is also
currently false.

The current pending external worklist is exactly, in source order:

```text
E-006 E-037 E-008 E-015 E-033 E-030 E-027 E-031 E-019 E-029 E-025 E-023 E-034
```

| Evidence | Pending candidate-bound claim |
|---|---|
| E-006 | Focused release-script fixtures |
| E-037 | Finite independent raw-source/raw-target lifecycle matrix against one byte-snapshotted immutable candidate |
| E-008 | Clean pinned build and standalone binary execution |
| E-015 | Seeded review-renderer CLI fixture |
| E-033 | Blinded representative-developer readability result |
| E-030 | Shared Claude/Codex/Pi continuation run |
| E-027 | Codex open, append, and re-import run |
| E-031 | Candidate-bound Cursor file-only/install-refusal validation |
| E-019 | Utils thin-launcher and direct-core byte equality |
| E-029 | Claude rendering and historical-call non-execution |
| E-025 | Codex-to-Claude lifecycle/control fixture audit |
| E-023 | Claude-to-Codex real-harness continuation |
| E-034 | Held-out context-isolation corpus result |

E-037 qualifies only after the release procedure retains an immutable 40/40
candidate run and cross-binds its executable digest and self-reported revision
to the separate trusted build-provenance record. For refusal cells it checks
unchanged post-exit prior-artifact path identity, opened-file identity, mode,
size, digest, and exact bytes. That is a finite before/after observation, not
continuous monitoring or an atomicity proof. It does not satisfy F-029 or any
real-harness obligation.

These entries are claims awaiting release-side adjudication against retained
candidate bytes, not successful production validation. Candidate-pending fit
obligations are F-002, F-006, F-010, F-012, F-014, F-017, F-018, F-019,
F-020, F-021, F-022, F-024, F-028, F-029, F-030, F-031, and F-033.

The complete internal blocked list is F-007, F-011, F-012B, F-013, F-015,
F-016, F-023, F-024B, F-025, and F-026. The preview subset is exactly F-012B,
F-024B, F-025, and F-026, blocking R-008 and R-016. R-003, R-017, and R-018
are instead external-validation pending. In particular, F-012 is
candidate-validation pending while F-012B is partial; F-024 is
candidate-validation pending while F-024B is partial; and F-025/F-026 are
unsatisfied.

`externalDecisionRequired` is reachable only after the relevant downstream
proof-bound catalogue check passes, which requires internal partial/unsatisfied
blockers to close while allowing qualified external obligations to remain
pending. It means release tooling must make a separate external decision; it
does not mean ready. The pure model consumes no external result, has no `ready`
constructor, and maps both assessment constructors to `previewReady = false`
and `stableReady = false` by construction.

## Open Verification, Validation, and Release Obligations

### O-001: complete cross-format loss policy (R-004)

The CLI protects sidechains, but arbitrary exporters can still degrade or drop
other content by construction. Examples include Cursor Agent's lack of tool
results, thinking, media, compaction, and events, and target-specific handling
of branches or unmodeled blocks. Before stable generic conversion:

1. Add content-sensitive probes for every IR concept and escape-hatch payload.
2. Define per-exporter preserve/transform/report/refuse behavior.
3. Make the pipeline refuse any destructive obligation without an explicit
   user-selected policy.
4. Add one counterexample per loss class.

The default pipeline now refuses the first audited destructive classes:
sidechain flattening, open Claude tool calls, Cursor media/unmodeled/tool-
result/other-role drops, and currently unfaithful event/compaction exports.
This is progress, not totality; constructors and provenance payloads still need
complete per-target decisions.

### O-002: uniform provenance policy (R-007)

Most modeled inference is typed, but not every lenient path is auditable.
Claude now rejects malformed JSONL lines and duplicate object members rather
than silently skipping them; several other format disposition tables still
retain `unverified` unknown-kind arms. Before stable:

1. Reject, preserve, or emit `ImportNote.contentSkipped` for every malformed or
   unknown record/block.
2. Ensure every defaulted semantic value is absent/unknown or has provenance.
3. Add mutation tests proving silent skip paths are impossible.

### O-003: open-world drift handling (R-011)

The closed Lean `Concept`/`Format` matrix is exhaustive at compile time. Vendor
JSON is open-world, so parser behavior must be equally explicit. Close O-002 and
add a held-out unknown-record suite per format.

### O-004: performance fit criterion (R-012)

No approved workload or threshold exists. Stable release must name:

- representative small/median/large transcript sizes;
- p95 wall-time threshold;
- peak resident-memory threshold;
- hardware and cold/warm-cache conditions.

Until then, the project makes no performance claim.

### O-005: candidate-bound cross-harness continuation (R-014)

Own-importer round trips establish internal consistency, not target behavior.
Historical V-012 supplies authenticated open/append/re-read observations for
Claude Code 2.1.206, Codex 0.144.1, and Pi 0.74.0. Historical V-013 is equally
important negative evidence: Cursor Agent 2026.05.28 did not treat its observed
JSONL as a history-import interface, so the public package refuses Cursor
installation and makes no Cursor continuation claim.

F-019 through F-022 remain externally pending. The candidate-bound rerun must
use Claude Code 2.1.216, Codex 0.144.1, and Pi 0.74.0. Cursor Agent
2026.07.09-a3815c0 remains a file/census target and needs retained negative
installation evidence; it is not a resumable target. Before R-014 can advance,
retain a bundle naming the exact candidate and core revisions, commands, fixture
and target hashes, harness versions and executable digests, model outputs, and
zero-violation re-import reports. No such current candidate bundle is claimed.

### O-006: human readability validation (R-013)

`loom inspect` deterministically renders every role-indexed block, thread,
tool link, error provenance, and import judgment. Build and CLI fixtures recover
the seeded facts and reject known Claude control tags. A blinded representative-
developer comprehension check is still required to validate D-007; a machine
pin cannot prove that a person understands the vocabulary. F-018 therefore
remains externally pending until the protocol in `HUMAN_VALIDATION.md` produces
a candidate-bound sealed result with the required independent signatures.

### O-007: preservation maximality (R-015)

`continuationProjection` is stronger than the historical parity normal form:
it includes ordered content, tool names/arguments/linkage/results/error state,
media, unmodeled blocks, compactions, and events. It already found a real Codex
export reordering (`thinking,text,call` had become `text,thinking,call`). Every
target still needs a total preserve/normalize/carrier/refuse table and a
maximality argument or counterexample suite.

### O-008: complete tool lifecycle (R-017)

The prior live TS conversion reported 107 source calls, 105 recorded results,
and two synthesized interrupted results. The current Lean exporter never closes
an interrupted source call with a fabricated result: it emits a readable,
versioned assistant-text carrier that re-imports to the exact id/name/arguments.
Structured result blocks use a separate reversible text carrier when Claude
cannot natively represent their source block kind. The historical,
non-candidate-bound V-009 audit compares source and target parsers rather than
trusting Loom's own summary.

V-009 also caught and closed a real gap before release: five
`tool_search_output` records were preserved as unrelated assistant metadata, so
completed search calls looked interrupted. They are now linked environment
results with complete raw payloads. A later safety review made the target policy
uniform: Codex and Claude do not share an executable tool registry, so every
Codex-origin call/result is now a reversible historical carrier rather than a
Claude-native lifecycle. The independent audit follows the latest compaction,
checks occurrence-addressed linkage, and compares error provenance as well as
values. Codex's carrier now independently pins duplicate raw IDs, reordered
results, missing IDs, unmatched/open calls, structured content, spoof gating,
and native/inferred/unrecorded error provenance.

The proof-bound `f027LifecycleAdversaryAggregate` separately closes F-027's
finite internal seed: one well-formed Pi carrier round trip contains duplicate
and missing ids, reversed positional result linkage, nested structured result
JSON, native true/false error states, and an open interrupted call. Its typed
six-row census and full continuation projection passed independent mutation
review. This does not establish every direction or real-target non-execution;
F-028 and F-029 remain candidate-validation pending.

E-037 is the candidate-only evidence declaration for F-028. A qualifying run
must execute the complete finite 8-source by 5-target matrix against one
byte-snapshotted immutable release executable. Successful cells require
independent field reconciliation. Refusal cells check unchanged post-exit
prior-artifact path identity, opened-file identity, mode, size, digest, and exact
bytes. This is a finite before/after observation, not continuous monitoring or
an atomicity proof. E-037 is not a Lean key, universal proof, real-harness run,
or build provenance, and no immutable retained release run is currently claimed.

Remaining work before R-017 is satisfied:

1. Retain the immutable E-037 40/40 report, commands, executable/fixture/harness
   digests, field reconciliations, policy refusals, and cross-binding to the
   separately trusted candidate build-provenance record.
2. Complete the separate F-029 candidate-bound real-target non-execution
   validation; historical V-011 observed the Codex-to-Claude policy but does not
   qualify for the current candidate.

### O-009: harness-context isolation (R-018)

Lean treats the Codex `developer` role as control-plane regardless of wrapper
drift and recognizes user/event environment context only as exact whole-message
envelopes. Exact records remain in origin extras with ImportNotes; embedded,
partial, and quoted tag-like user text stays conversational. E-036 proof-binds
the synthetic internal role-family census and satisfies F-032 only. Historical
V-009 and V-011 observed zero exact control blocks as target dialogue but are
not candidate-bound. F-030, F-031, and F-033 still require current candidate
controls, real-view, and held-out context-isolation evidence, so R-018 remains
external-validation pending.

### O-010: one reported semantic engine (R-016)

F-024 is candidate-validation pending for the utils default-launcher fixture;
its claim is that the host is semantic-free and byte-equal to direct Lean.
F-024B remains partial for every packaged/default path. The packaged command is
intended to restrict host code to core discovery/invocation and target-store
installation, with explicit `ts-legacy` compatibility selection, but the
broader byte-equality claim is not complete.

F-025 and F-026 are unsatisfied. The npm tarball does not include or acquire a
Loom binary, does not enforce an immutable core manifest, and has not passed
matching-core and missing-core clean-install CI as the exact packed artifact.
Machine-readable version and conversion results must report engine, core
version, and core revision; raw converted artifact bytes need not embed that
metadata. Development binaries may report `coreRevision: working-tree`, but a
candidate binary must stamp and verify the immutable source revision it claims.

### O-011: full abstract implementation refinement

The reference model defines `ImplementationRefinesConversionSpec` over a
concrete `run` and independent world model. No current theorem instantiates that
full relation for Loom. The narrower real machine boundary is proved by
`runPipelineRefinesConcreteMachineSpec`; do not reopen or understate that fact.
To close the remaining abstraction, supply execution observations carrying
importer outcome, structural-gate outcome, support/refusal applicability,
semantic and emission criteria, destination-byte state, and typed
success/refusal outcome, then prove complete `ConversionSpec` agreement for
every input. Domain bridges must still be validated separately; even a full
implementation-refinement proof would not establish D, target-harness
consumption, or release readiness.

## Reproduction

From `utils/`:

```sh
npm run test:loom
npm run prepublishOnly
scripts/prepare-human-validation.sh --self-test
scripts/seal-human-validation.sh --self-test
```

The focused gate builds the executable and `LoomRequirements`, runs Lean proof
and witness pins, checks deterministic duplicate conversion, exercises
differential fixtures, wire compatibility, sidechains, Cursor SQLite, engine
selection, thin-launcher byte equality, and explicit no-fallback refusals.

Optional corpus validation:

```sh
npm run test:loom:corpus -- codex <dir> --ts-parity --allow-ts-errors
npm run test:loom:corpus -- claude <dir> --ts-parity
npm run test:loom:corpus -- cursor-agent <dir> --ts-parity
```

## Verdict

The requirements case describes an experimental developer-preview candidate
and does not claim release readiness. V-012 and V-013 are historical
observations, not candidate-bound release evidence. R-001, R-003, R-006, R-010,
R-013, R-014, R-017, and R-018 are externally pending. R-004, R-007 through
R-009, R-011, R-015, and R-016 remain partial; R-012 is unsatisfied. Blinded
human readability, semantic authority/distribution, candidate lifecycle
validation, real-harness non-execution, held-out context isolation, and full
`ImplementationRefinesConversionSpec` instantiation remain open. It also does
**not** prove stable arbitrary
cross-format conversion. A developer-preview release or
stable/default-replacement announcement would contradict the current
proof-bound catalogue assessment, and the pure readiness booleans are
fail-closed regardless.
