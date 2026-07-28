# agent-convert/Lean Requirements

Status: controlled requirements baseline for an **experimental
developer-preview candidate**, 2026-07-21. It is not release-ready or stable.

Product name: **agent-convert/Lean**. The current Lean package and binary are
named **Loom** and `loom`. This document treats Loom as the implementation name,
not as a different product.

## Method and Claim Standard

The method here is Michael **Jackson** and Pamela Zave's requirements
engineering tradition, specifically the reference model and problem-frames
work. The central distinction is:

```text
W  problem-world vocabulary and context: designations plus relevant assertions
D  indicative domain properties relied on independently of the converter
R  optative effects desired in the problem world
S  machine behavior over shared interface phenomena that the converter controls

D and S must entail R
```

Requirements describe the world we want. They are not a list of functions in
the code. A machine specification may mention only phenomena visible at the
interface, may constrain only converter-controlled outputs, and may depend only
on past or present inputs. Facts about vendor formats and target harnesses stay
in `D`; a Lean build cannot prove those facts about the external world.

This project uses three evidence words precisely:

- **Proof**: a Lean theorem over all values satisfying explicit premises.
- **Verification**: a build-checked decision or test over an enumerated model or
  finite fixture set.
- **Validation**: evidence from real vendor artifacts, target harnesses, or held-
out corpora.

`W` supplies the vocabulary in which the problem is stated; `D` is the subset
of indicative assertions used as environmental bridges; `R` says what should
be true in the problem world; and `S` says what the machine must do at its
shared boundary. Neither W nor the numbered product catalogue is a synonym for
the program. Product constraints in the `R-xxx` catalogue trace to S but are not
themselves Jackson-Zave R.

The executable model is in
[`LoomRequirements`](./LoomRequirements.lean). The implementation evidence is in
[`Proofs.lean`](./LoomRequirements/Proofs.lean). The evidence ledger is
[`REQUIREMENTS_EVIDENCE.md`](./REQUIREMENTS_EVIDENCE.md).

The model represents the reference method directly: `Statement` distinguishes
designations, definitions, indicative assertions, and optative assertions;
`referenceProblem` bundles W, D, R, and S; and build pins require D to contain
only domain knowledge, R to be optative, and every S clause to constrain only a
shared, machine-controlled output using past or present inputs. Its validation
worklist is exactly the falsifiable indicative assertions in D.

`concreteCatalogueConversionAdequacy` instantiates the abstract
`D and S entail R` reduction with typed catalogue designations. It is a
catalogue-adequacy theorem, not a theorem that Loom implements S. The reference
model defines
`ImplementationRefinesConversionSpec`, but the current proof modules do not
instantiate that full abstraction with concrete `run` and independent
`observe` functions. That full implementation-refinement obligation remains
open.

The proof modules do establish a separate, concrete machine refinement for the
real pure pipeline. `runPipelineRefinesConcreteMachineSpec` proves every result
of `runPipeline` equals the decision sequence consisting of the structural
gate, the export blocker, and the selected exporter's exact `Except` result.
The exact structural-error, blocker-error, and exporter-result corollaries are
also proved. This is stronger than a finite smoke test but narrower than full
D/S refinement: it does not establish importer acceptance, independent refusal
applicability, destination-byte behavior, target-harness consumption, or
source/target semantic fidelity.

## Scope

The machine is the Lean semantic core, CLI, and file actuators:

```text
Problem world                                Machine                    Problem world

source transcript bytes  -----------------> [                        ]
CLI source/target/options -----------------> [ agent-convert/Lean     ] ---> output bytes/files
SQLite query result      -----------------> [ canonical Loom IR      ] ---> exit status
                                             [ validation + exporters ] ---> diagnostics
provider-intended meaning  (not observable) [                        ]     target-harness behavior
```

Current declared import surface:

`loom`, `pi`, `claude`, `codex`, `cursor-agent`, `hermes`,
`google-ai-studio`, and `cursor-ide`.

Current declared export surface:

`loom`, `pi`, `claude`, `codex`, and `cursor-agent`.

The experimental developer-preview candidate specifically exercises
`convert-to-pi` through Loom for Codex, Claude, Google AI Studio, and Hermes
through the required Loom binary.
Cursor IDE discovery/install remains an explicit legacy operation; the direct
Lean actuator is separately gated. Stable, arbitrary cross-format conversion
is a larger requirement and is not yet claimed. The candidate is not an
approved developer preview: its downstream proof-bound catalogue assessment is
currently `catalogueBlocked`, and required candidate-bound external evidence
and approval do not exist. `previewReady` is not used for that decision because
it is always false by design.

### Current candidate pins

These are current candidate and validation targets, not retroactive labels for
older observations:

| Component | Current pin |
|---|---|
| Lean toolchain | 4.28.0 |
| Loom semantic core | 0.2.0-preview.0 |
| Claude Code target | 2.1.216 |
| Codex CLI target | 0.144.1 |
| Pi target | 0.74.0 |
| Cursor Agent census/file target | 2026.07.09-a3815c0 |

Versions embedded in `V-001` through `V-013` are historical observations and
remain unchanged. Those rows are not candidate-bound evidence for the pins
above. Cursor Agent remains file-only for this release protocol; its current pin
does not revive the failed local-history installation claim recorded in V-013.

### Semantic engines and current distribution gap

There are currently two implementations, and they are not interchangeable:

| Surface | Semantic engine | Current role |
|---|---|---|
| `spec/loom/.lake/build/bin/loom` | Lean | Intended canonical parser, IR, loss policy, and serializer |
| `utils/src/convertToPi.ts` | Lean by subprocess | Thin import-to-pi launcher; `PI_CONVERT_ENGINE=ts` is explicit legacy rollback |
| sibling `agent-convert/dist/agentConvert.js` | Lean by subprocess | Thin cross-format launcher and target-store installer; `--engine ts-legacy` is explicit rollback |
| sibling `agent-convert/dist/agentConvertLegacy.js` | TypeScript | Frozen compatibility engine, reachable only by explicit legacy selection |

The failed 2026-07-09 live Codex-to-Claude conversion used a stale build of the
old TypeScript third row. The current source is intended to route the default
command through Loom and report `engine`, `engineVersion`, and `coreRevision`;
the host performs only process/path and target-store work. F-024 requires
candidate-bound verification of that behavior for the utils launcher fixture.
The held-out rollout audit is historical and non-candidate-bound; broader
packaged/default-path verification remains F-024B.

R-016 remains partial. F-024 is candidate-validation pending for the utils
default-launcher fixture;
F-024B, covering every packaged/default path, remains partial. F-025 and F-026
are unsatisfied: the package does not enforce an immutable core manifest, and
the exact tarball has not passed matching-core and missing-core clean-install
CI. `npm pack` currently contains no Loom binary and has no platform package or
installer that acquires one. A clean npm install therefore requires
`AGENT_CONVERT_LEAN_BIN`/`LOOM_BIN` or a `loom` executable on `PATH` and fails
closed when none exists. Engine/version/core identity is required on
machine-readable version and conversion results; raw artifact bytes are not
claimed to carry that metadata themselves.

Out of scope for this baseline:

- Recovering meaning absent from a source format.
- Proving undocumented vendor semantics from source bytes alone.
- Treating the TypeScript converter as a truth oracle. It is only a compatibility
  oracle, and divergences must be adjudicated.
- A performance claim before a stakeholder approves a workload and threshold.
- Silent best-effort repair of malformed or inherently lossy conversions.

## Stakeholders

| ID | Stakeholder | Required outcome |
|---|---|---|
| ST-DEV | Converter user | A usable target transcript without hidden damage |
| ST-HARNESS | Target-harness operator | Valid, resumable artifacts |
| ST-MAINT | Format maintainer | Detectable schema drift and explicit mappings |
| ST-AUDIT | Migration/forensics reviewer | Traceable provenance, assumptions, loss, and evidence |
| ST-REL | Release engineer | A reproducible gate and explicit rollback boundary |

The checked stakeholder-goal links are:

| Goal | Problem-world outcome | Requirement links |
|---|---|---|
| G-READ | Read roles, ordered content, tool interactions, threads, and losses without raw harness markup or injected control context | R-013, R-007, R-017, R-018 |
| G-CONT | Continue the intended conversation from one supported harness in another | R-014, R-002, R-017, R-018, R-008 |
| G-FID | Preserve every representable fact and expose, carry, or refuse every degradation | R-003, R-004, R-015, R-016, R-017, R-018 |

`stakeholderGoalCoverage = true` checks that these goals name real stakeholders
and nonempty requirement sets. This closes the earlier loophole where the
self-declared catalogue could be complete while omitting the user's goals.

## Designations

These terms are normative:

| Term | Grounding |
|---|---|
| accepted source | The selected importer succeeds and the CLI structural gate passes |
| common meaning | Concepts representable by both source and target under declared approximation rules |
| loss | Source information represented by Loom but absent or degraded in the target |
| silent loss | A loss neither preserved, reported, nor converted into a refusal |
| well-formed | `Loom.violations transcript = []` |
| Loom wire | The versioned native serialization `loom.transcript.v0` |
| sidechain | A child-agent thread anchored to the assistant tool call that spawned it |
| detached thread | A child transcript whose spawn anchor cannot be established honestly |
| conversation-authored turn | A supported source record attributed to the human user or model assistant, excluding injected developer/system/runtime context |
| tool lifecycle | The ordered call and recorded result, including id, name, complete arguments/content, linkage, and error provenance |
| semantic engine | The implementation that parses, normalizes, decides losses, and serializes: `lean` or explicit `ts-legacy` |
| carrier marker | An in-band version/disposition marker used to decode agent-convert's own historical records; it prevents accidental prose collisions but is not cryptographic source authentication |

## Interface Phenomena

| Phenomenon | Controlled by | Shared? | Legal in S? |
|---|---|---:|---:|
| Source transcript bytes | Environment | Yes | Read only |
| CLI source/target/options | Environment | Yes | Read only |
| Provider-intended meaning | Environment | No | No; belongs in D/validation |
| Target-harness behavior | Environment | No | No; belongs in D/validation |
| Output transcript bytes/files | Converter | Yes | Yes |
| Exit status | Converter | Yes | Yes |
| Diagnostic | Converter | Yes | Yes |
| In-memory Loom IR | Converter | No | No; implementation detail |

Every clause in `machineSpecification` is mechanically checked to obey this
boundary. `specificationInterfaceMetadataWellFormed = true` is the build pin;
it checks interface metadata, not implementation existence or behavioral
correctness.

## Domain Assumptions

| ID | Assumption | Status | How it can fail | Validation action |
|---|---|---|---|---|
| D-001 | Observed corpora cover supported harness record kinds | Conditional | A new relevant kind appears | Repeat censuses on held-out/new sessions |
| D-003 | A conforming target artifact is consumable by its harness | Conditional | Real harness rejects or misreads it | Open/resume generated artifacts in each target |
| D-004 | Input snapshots are complete enough to parse | Open | A live file ends in a torn record | Gate immutable fixtures; document caller duty |
| D-005 | `sqlite3` exists for explicit Cursor IDE Lean use | Conditional | Missing/incompatible binary | Actuator smoke; keep Cursor IDE outside the default Lean launcher surface |
| D-006 | Vendor formats can drift without notice | Validated standing fact | Not applicable | Preserve/log/refuse unknowns and recensus |
| D-007 | Representative developers understand the review vocabulary | Open | A reviewer cannot recover seeded roles/tools/threads/losses | Blinded comprehension validation |
| D-008 | Foreign historical tools cannot be assumed native in a target registry | Conditional | A pinned target safely accepts arbitrary foreign names/schemas | Tool-rich target probe and registry recensus |
| D-009 | Supported role/envelope labels distinguish conversation turns from injected context | Conditional | A harness mislabels either class | Version-pin semantics, census real sessions, inspect both harness views |
| D-010 | Callers honor non-zero status and do not consume stale output as this invocation's artifact | Conditional | A launcher/workflow presents old output after failure | Run every failure class with a sentinel pre-existing output |
| D-011 | Equality of each adapter's declared common projection denotes equality of source/target meaning | Conditional | A pinned harness or representative reader interprets projection-equal artifacts differently | Maintain the concept census; validate rendering, continuation, and held-out cases |
| D-012 | A complete preserve/carrier/report/refuse disposition makes every loss observable | Conditional | A disposition hides, omits, or cannot decode a source fact | Mutation-test dispositions and independently reconcile source facts |

The checked validation worklist is `D-001`, `D-003`, `D-004`, `D-005`,
`D-007`, `D-008`, `D-009`, `D-010`, `D-011`, and `D-012`.
They are not smuggled into a proof as established facts.

The frozen TypeScript differential rule is `VP-001`, a **validation policy**:
use TypeScript as a preview compatibility baseline, never as a truth oracle.
This is a project choice, not an independently true fact about the problem
world, so it is intentionally excluded from D.

## Requirements

The `R-xxx` identifiers form the product-management catalogue; they are not all
the Jackson-Zave `R` artifact. The executable model classifies R-001, R-002,
R-005, R-006, R-008, R-009, R-010, R-011, and R-016 as **product constraints**
that must trace to implementable `S` clauses. The remaining records are
problem-world outcomes. `topLevelRequirement` is the single optative R used by
the checked `D, S ⊨ R` argument. This distinction prevents architecture and
test machinery from being presented as stakeholder needs.

Priorities mean:

- **Preview**: required for the current scoped developer preview.
- **Stable**: required before claiming a stable generic converter.
- **Should**: required before making the corresponding product claim.

| ID | Priority | Status | Requirement and falsifiable fit criterion |
|---|---|---|---|
| R-001 | Preview | **External validation pending** | Import all 8 declared sources; export all 5 declared targets or explicitly refuse. E-003 proves the pure-import fixture set; F-002 still requires candidate-bound focused release evidence for every declared target's exporter witness or refusal. |
| R-002 | Preview | Satisfied | Never emit from structurally invalid IR. A successful `runPipeline` must imply `WellFormed`; adversarial fixtures must trigger each strengthened reference/thread invariant. |
| R-003 | Preview | **External validation pending** | Preserve the declared continuation projection: ordered roles/text/thinking, tool names/arguments/linkage/results/error state, and media/unmodeled content where shared. Native Codex/pi lifecycles and the Claude foreign-tool carrier are pinned internally. F-006 still requires candidate-bound E-037 differential evidence for the complete 8-source by 5-target matrix. |
| R-004 | Stable | **Partial** | Preserve, report, or refuse every actual unrepresentable/degraded concept. Every exporter needs a content-sensitive loss policy and tests for every loss class. Sidechains meet this; all content classes do not yet. |
| R-005 | Preview | Satisfied | Loom wire exactly preserves every serialized IR field, including canonical tool interpretation and all error-provenance constructors; closed-enum codecs, malformed required structure, compatible numeric encodings, and additive unknown labels are independently pinned. |
| R-006 | Preview | **External validation pending** | Preserve valid sidechain anchors in Loom/native sidecars; mark unknowable anchors detached; refuse flat pi/Codex output rather than flattening. F-010 still requires candidate-bound focused release evidence. |
| R-007 | Stable | **Partial** | Keep recorded, inferred, synthesized, absent, unknown, and dropped data distinguishable. Every importer judgment must be logged, preserved, or refused. Some lenient/unknown paths remain unlogged. |
| R-008 | Preview | **Partial** | F-012 requires candidate-bound focused CLI fixtures for invocation `1`, import `2`, and export/validation `3`. F-012B remains partial: every public failure path has not yet been shown to commit no artifact, preserve any prior destination byte-for-byte, and avoid reporting stale output as this invocation's result. |
| R-009 | Stable | **Partial** | Fixed input, explicit options, and versions must produce byte-identical output and status. One CLI fixture is repeated today; the complete release fixture matrix is not. |
| R-010 | Preview | **External validation pending** | Build with Lean 4.28.0; run the produced binary without Lake; name the optional `sqlite3` dependency. Internal gates exist, but F-014 requires retained clean-checkout evidence for the immutable candidate. |
| R-011 | Stable | **Partial** | New closed-world concepts/formats force explicit Lean cases; every open-world source kind must preserve, log, or refuse. Closed matrix is exhaustive; source handlers are uneven. |
| R-012 | Stable | **Unsatisfied** | No performance or stable-release claim until a workload, p95 time, and peak-RSS threshold are approved and gated. |
| R-013 | Preview | **External validation pending** | F-017 requires candidate-bound deterministic inspection of roles, content, tool lifecycle, threads, judgments, and opaque-signature presence. F-018 requires a sealed, candidate-bound blinded developer comprehension result. |
| R-014 | Preview | **External validation pending** | Historical V-012 observed continuation in Claude Code 2.1.206, Codex 0.144.1, and pi 0.74.0; V-013 disproved Cursor Agent 2026.05.28 local-history installation. F-019 through F-022 require immutable candidate-bound reruns or retained negative evidence against the current release candidate; no current external run is claimed complete. |
| R-015 | Stable | **Partial** | Preserve every target-representable datum and show that no policy-valid alternative preserves a strict superset. Loom wire is all-constructor lossless; cross-format maximality remains open. |
| R-016 | Preview | **Partial** | Machine-readable public version/conversion results identify engine, core version, and core revision. F-024 is candidate-validation pending for the utils default fixture; F-024B remains partial for every packaged/default path, while F-025 and F-026 are unsatisfied because immutable core-manifest enforcement and exact packed-install CI do not exist. Development builds may report `coreRevision: working-tree`; a candidate must not. |
| R-017 | Preview | **External validation pending** | Preserve every selected-path tool call/result's order, id, source name, complete arguments, complete result content, linkage, and error state/provenance, or use a reversible carrier/refusal. E-035 and the lifecycle fixtures pin internal carrier behavior. F-028 still requires candidate-bound E-037 reconciliation for all 40 matrix cells. Refusal cells check unchanged post-exit prior-artifact path identity, opened-file identity, mode, size, digest, and exact bytes as a finite before/after observation, not continuous monitoring or an atomicity proof. F-029 separately requires real-target non-execution evidence. |
| R-018 | Preview | **External validation pending** | Never turn injected developer, system, policy, permission, configuration, or runtime context into user/assistant conversation. E-036 proof-binds F-032's synthetic internal role-family census. F-030, F-031, and F-033 still require current candidate controls, real-view, and held-out context-isolation evidence; historical renders are not candidate-bound. |

The catalogue structure and evidence classifications are `native_decide` pins.
The current exact formal state is:

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

The upstream `previewCatalogueChecksPass=false` value is a declaration sentinel,
not the final proof check. `AgentConvert.lean` cannot import downstream proofs,
so `requirementCatalogueReady` deliberately returns false. `Proofs.lean` binds
actual theorem terms to the closed Lean evidence keys E-002, E-003, E-004,
E-005, E-009, E-014, E-022, E-028, E-032, E-035, and E-036, then computes the
downstream `previewProofBoundCatalogueEligible`. That downstream value is also
false for substantive reasons: preview fit obligations F-012B, F-024B, F-025,
and F-026 are blocked.

Across preview and stable scope, the complete blocked fit-obligation list is
F-007, F-011, F-012B, F-013, F-015, F-016, F-023, F-024B, F-025, and
F-026. The preview blocked subset is exactly F-012B, F-024B, F-025, and F-026.
These are internal product/proof/test gaps; an external attestation cannot
discharge them.

The candidate-validation-pending fit obligations are F-002, F-006, F-010,
F-012, F-014, F-017, F-018, F-019, F-020, F-021, F-022, F-024, F-028,
F-029, F-030, F-031, and F-033. Their exact pending external evidence worklist
is, in order: E-006, E-037, E-008, E-015, E-033, E-030, E-027, E-031,
E-019, E-029, E-025, E-023, and E-034. The list records claims for release
tooling to validate against an immutable candidate; it records no successful
current-candidate result.

E-037 is candidate-only differential evidence. It becomes eligible only through
an immutable retained run of the finite 8-source by 5-target lifecycle matrix.
For refusal cells it checks unchanged post-exit prior-artifact path identity,
opened-file identity, mode, size, digest, and exact bytes. That is a finite
before/after observation, not continuous monitoring or an atomicity proof. It
is absent from the closed Lean evidence-key type and is neither a universal
proof, real-harness execution, nor trusted build provenance. E-036, not E-037,
is in the proof bundle and discharges only F-032's synthetic internal fixture.
F-029 remains the separate real-harness obligation.

`previewProofBoundReadinessAssessment` can become
`externalDecisionRequired` only after every preview internal blocker closes;
qualified external obligations may remain pending at that transition. It means
only that release tooling must evaluate those obligations. It is not a `ready`
state. The pure model has no result-ingestion API or `ready` constructor, and
`pureAssessmentEstablishesReleaseReadiness` returns false for both assessment
constructors. Consequently `previewReady` and `stableReady` are always false by
construction, including in any future `externalDecisionRequired` state.

## Machine Specification

The executable `S` clauses constrain only shared converter outputs:

| ID | Machine behavior |
|---|---|
| S-001 | On typed success, emit only bytes passing declared target syntax and operational-contract checks |
| S-002-STATUS | Return import-failure status when source parsing or acquisition fails |
| S-002-OUTPUT | Commit no output artifact when source parsing or acquisition fails |
| S-003 | Run complete structural validation before ordinary export |
| S-004-STATUS | Return distinct invocation, import, and export/validation statuses |
| S-004-DIAGNOSTIC | Name the typed failure class and cause in the refusal diagnostic |
| S-004-OUTPUT | On typed refusal, preserve any pre-existing destination and commit no new artifact |
| S-005 | Use versioned Loom wire when every IR constructor must survive |
| S-006 | Refuse flat export that would silently flatten non-main threads |
| S-007 | Produce deterministic bytes from pure conversion for fixed inputs/options |
| S-008-OUTPUT | Retain assumptions, inferred values, and obligations in output data where supported |
| S-008-DIAGNOSTIC | Report assumptions, inferred values, and obligations not retained in output data |
| S-009 | Render a deterministic review view with explicit roles, tools, links, threads, and normalized control envelopes |
| S-010 | Emit target registration and continuation metadata required by the selected harness version |
| S-011 | Refuse destructive export obligations unless a reversible carrier or approved explicit policy discharges them |
| S-012-OUTPUT | Route default public output through the package-pinned Lean core without host-language transcript mutation |
| S-012-DIAGNOSTIC | Report semantic-engine identity and immutable core revision |
| S-012-STATUS | Reject unversioned, working-tree, unavailable, or mismatched cores before conversion |
| S-013-OUTPUT | Preserve or explicitly carry the complete ordered tool lifecycle in successful output |
| S-013-STATUS | Refuse destructive loss when neither target representation nor a declared reversible tool carrier is valid |
| S-014-OUTPUT | Classify source channels before export and retain excluded context in typed output provenance where representable |
| S-014-DIAGNOSTIC | Report excluded context that cannot be retained in typed output provenance |
| S-015 | Emit successful output only when the declared common projection agrees with the accepted source |
| S-016 | Emit successful output only when every source fact has a complete preserve/carrier/report/refusal disposition |
| S-CURSOR-QUERY | Derive Cursor IDE output only from the selected read-only SQLite query response |

For accepted, structurally valid sources, the closed post-import refusal causes
are `unsupportedTarget`, `destructiveLoss`, `missingTargetPrerequisites`, and
`invalidTargetPrerequisites`. Invocation errors, importer rejection, host
failure, and core unavailability occur before that accepted-source obligation;
they are deliberately not fabricated as post-import `RefusalCause` values.

The split obligations matter. F-012 is candidate-validation pending, but F-012B
is partial, so R-008's fit assessment is blocked. F-024 is
candidate-validation pending for the utils default fixture; F-024B is partial
and F-025/F-026 are unsatisfied, so R-016's fit assessment is blocked. The
catalogue does not convert a narrower witness into completion of a broader fit
criterion.

## Adequacy Arguments

### A-001 Usable conversion

- R: an accepted conversion is usable by the target.
- S: the converter emits an artifact satisfying the modeled target syntax.
- D: the real target consumes artifacts satisfying that syntax and semantics.
- Argument: from S we obtain a valid emitted artifact; D bridges that interface
  fact to target consumption.

### A-002 Faithful conversion

- R: common source meaning is preserved and loss is visible.
- S: observable source/target common projections agree and every source fact
  has a complete preserve, reversible-carrier, report, or refusal disposition.
- D: D-011 maps projection equality to problem-world meaning; D-012 maps a
  complete disposition to visible loss.
- Argument: `conversionAdequacy` is the abstract reduction schema from those
  observable S facts and explicit D bridges to R. It does **not** prove that the
  implementation satisfies S. Adapter-specific theorems, mutation tests,
  independent reconciliation, and harness validation establish finite parts of
  that implementation premise.

### A-003 Safe failure

- R: unsupported or unsafe conversions do not produce plausible silent output.
- S: parse errors, structural violations, and protected loss classes produce a
  non-zero refusal before output.
- D: D-010 says callers treat non-zero exit status as failure and do not consume
  a stale prior output path as this invocation's result.
- Argument: `safeFailureAdequacy` states this separate D/S/R reduction. CLI
  sentinel-output tests validate its machine and caller-facing premises.

`runPipelineRefinesConcreteMachineSpec` proves the complete real pure-pipeline
decision boundary for both success and failure: structural gate, blocker, then
the selected exporter's exact result. `runPipelineOkIffSuccessfulRunObservableSpec`
separately characterizes successful runs as well-formed, unblocked, and exactly
equal to exporter output. Neither theorem instantiates
`ImplementationRefinesConversionSpec`: the missing full relation must still
supply importer outcome, independent support/refusal applicability, semantic
criteria, destination observations, and complete typed success/refusal
agreement for every input. Target-harness consumption and provider meaning
remain D/external-validation questions even after that relation is proved.

A-002 now has strong native Codex/pi continuation witnesses plus a checked
Claude-to-Codex foreign-tool carrier, but it is not complete for every
advertised pair. R-003 therefore remains external-validation pending on the
candidate-bound matrix; R-004 and R-015 keep the broader
stable/maximal-preservation claim explicitly open.

## Change Control

Any behavior change must:

1. Identify the affected `R`, `D`, and `S` IDs.
2. Change the fit criterion before or with the implementation.
3. Add proof/verification evidence and, for external claims, validation evidence.
4. Revalidate every touched conditional domain assumption.
5. Keep the formal external-pending, partial, or unsatisfied status until the
   named evidence exists and qualifies under the model.
6. Run `npm run test:loom`; before release handoff, run
   `npm run prepublishOnly`.

Adding a `Concept` or closed `Format` constructor intentionally breaks exhaustive
Lean matches until every format answers it. Adding an open-world vendor record
must produce preserve/log/refuse behavior and a fixture or corpus witness.

## Primary Sources

- Michael Jackson and Pamela Zave, [Deriving Specifications from Requirements: An Example](https://www.pamelazave.com/turnstile.pdf), ICSE 1995.
- Pamela Zave, [Foundations of Requirements Engineering](https://www.pamelazave.com/fre.html), with links to the Jackson-Zave primary papers.
- Carl Gunter, Elsa Gunter, Michael Jackson, and Pamela Zave, [A Reference Model for Requirements and Specifications](https://doi.org/10.1109/52.896248), IEEE Software 2000.
