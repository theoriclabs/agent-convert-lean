import LoomRequirements.ReferenceModel

/-!
# Concrete requirements model for agent-convert/Lean (Loom)

This is the checked catalogue behind `REQUIREMENTS.md`. It records the problem
world, the machine boundary, D/R/S artifacts, evidence links, and the honest
split between developer-preview and stable-release obligations.
-/

namespace AgentConvert.Requirements

def sourceArtifact : Phenomenon :=
  { name := "source transcript bytes", control := .environment, sharing := .shared }

def invocation : Phenomenon :=
  { name := "CLI source/target/options", control := .environment, sharing := .shared }

def sourceMeaning : Phenomenon :=
  { name := "provider-intended transcript meaning", control := .environment, sharing := .unshared }

def targetRuntime : Phenomenon :=
  { name := "target harness behavior", control := .environment, sharing := .unshared }

def outputArtifact : Phenomenon :=
  { name := "output transcript bytes/files", control := .machine, sharing := .shared }

def exitStatus : Phenomenon :=
  { name := "process exit status", control := .machine, sharing := .shared }

def diagnostic : Phenomenon :=
  { name := "stderr diagnostic", control := .machine, sharing := .shared }

def cursorIdeSqliteQueryResult : Phenomenon :=
  { name := "Cursor IDE read-only sqlite query rows/status",
    control := .environment, sharing := .shared }

def internalIr : Phenomenon :=
  { name := "Loom in-memory IR", control := .machine, sharing := .unshared }

def stakeholders : List Stakeholder := [
  { id := "ST-DEV", name := "converter user",
    interest := "obtain a usable target transcript without hidden semantic damage" },
  { id := "ST-HARNESS", name := "target harness operator",
    interest := "receive syntactically valid, resumable artifacts" },
  { id := "ST-MAINT", name := "format maintainer",
    interest := "detect schema drift and understand every mapping decision" },
  { id := "ST-AUDIT", name := "forensics and migration reviewer",
    interest := "trace provenance, assumptions, losses, and evidence" },
  { id := "ST-REL", name := "release engineer",
    interest := "run one reproducible gate with an explicit rollback boundary" }
]

def stakeholderGoals : List StakeholderGoal := [
  { id := "G-READ", stakeholder := "ST-DEV",
    statement := "Read converted transcripts without raw harness protocol markup and recover roles, ordered content, tool interactions, threads, and loss judgments.",
    requirements := [.transcriptReadability, .provenanceHonesty,
      .toolLifecycleFidelity, .contextIsolation] },
  { id := "G-CONT", stakeholder := "ST-DEV",
    statement := "Start in one supported harness and continue the same conversation in another at the intended active leaf.",
    requirements := [.crossHarnessContinuation, .structuralIntegrity,
      .toolLifecycleFidelity, .contextIsolation, .failureContract] },
  { id := "G-FID", stakeholder := "ST-AUDIT",
    statement := "Translate every representable fact and make every unavoidable degradation explicit, reversible, or refused.",
    requirements := [.semanticFidelity, .noSilentLoss, .maximalPreservation,
      .semanticAuthority, .toolLifecycleFidelity, .contextIsolation] }
]

def designations : List Designation := [
  { term := "agent-convert/Lean", grounding := "the `loom` Lean binary and its Loom/LoomConvert libraries" },
  { term := "source format", grounding := "the format selected by the CLI, not a guessed provider intention" },
  { term := "accepted source", grounding := "input for which the selected importer returns a transcript and the CLI structural gate passes" },
  { term := "common meaning", grounding := "the projection onto concepts representable by both source and target, with declared approximation rules" },
  { term := "loss", grounding := "source information represented in Loom but absent or degraded in the selected target" },
  { term := "silent loss", grounding := "a loss neither preserved, reported, nor converted into a refusal" },
  { term := "well-formed", grounding := "`Loom.violations transcript = []`" },
  { term := "proof", grounding := "a Lean theorem valid for all values satisfying its premises" },
  { term := "verification", grounding := "a build-checked decision or test over enumerated values/fixtures" },
  { term := "validation", grounding := "evidence gathered from external harnesses or real transcript corpora" }
  , { term := "conversation-authored turn", grounding := "a source record attributed by the supported harness schema to the human user or model assistant, excluding injected developer/system/runtime context" }
  , { term := "tool lifecycle", grounding := "an ordered invocation and its recorded result, including identity, name, complete arguments/content, linkage, and error provenance" }
  , { term := "semantic engine", grounding := "the implementation that parses, normalizes, decides losses, and serializes the transcript; currently `lean` or explicit `ts-legacy`" }
  , { term := "carrier marker", grounding := "an in-band version/disposition marker for decoding agent-convert historical records; collision protection, not cryptographic source authentication" }
]

def domainAssumptions : List DomainAssumption := [
  { id := "D-001",
    statement := "The observed source corpora cover the record kinds used by the supported harness versions.",
    falsifier := "A supported harness emits a semantically relevant kind absent from its disposition table.",
    validation := "Repeat the per-format census on held-out and newly produced sessions.",
    status := .conditional },
  { id := "D-003",
    statement := "An emitted artifact satisfying the declared syntax and operational contract of a version-pinned target is consumable by that target harness.",
    falsifier := "The target parser rejects an artifact that passes the declared syntax, registration, and continuation-contract checks.",
    validation := "Open or resume contract-valid generated artifacts in the real version-pinned target for each release candidate.",
    status := .conditional },
  { id := "D-004",
    statement := "The input snapshot is complete enough to convert; a file being appended concurrently may end in a partial record.",
    falsifier := "A conversion reads a torn record or a changing SQLite snapshot.",
    validation := "Use immutable fixtures in gates and document live-file conversion as a caller responsibility.",
    status := .unvalidated },
  { id := "D-005",
    statement := "System sqlite3 is available when the explicit Cursor IDE Lean actuator is selected.",
    falsifier := "sqlite3 is absent or incompatible on PATH.",
    validation := "Actuator smoke test; Cursor IDE remains outside the default Lean launcher surface until the dependency is removed.",
    status := .conditional },
  { id := "D-006",
    statement := "Vendor formats can drift without notice.",
    falsifier := "Not applicable: this is a standing environmental fact, not a stability assumption.",
    validation := "Keep unknown variants representable and rerun censuses after harness upgrades.",
    status := .validated },
  { id := "D-007",
    statement := "The review vocabulary and role/tool labels are understandable to representative transcript readers.",
    falsifier := "A reader cannot recover a seeded role, tool interaction, thread relationship, or loss judgment from the review surface.",
    validation := "Run a blinded seeded-transcript comprehension check with representative developers.",
    status := .unvalidated },
  { id := "D-008",
    statement := "A target harness accepts only its active tool registry as native calls; foreign historical tools require a readable non-native carrier.",
    falsifier := "A version-pinned target safely accepts and renders arbitrary foreign function names with their source argument schemas.",
    validation := "Probe generated tool-rich artifacts in each target release and recensus the native tool registry.",
    status := .conditional },
  { id := "D-009",
    statement := "Supported source role and envelope labels distinguish conversation-authored turns from harness-injected developer, system, policy, permission, and runtime context.",
    falsifier := "A supported harness labels genuine end-user conversation as developer/system context or injected context as a user turn.",
    validation := "Version-pin role semantics, census real transcripts, and inspect converted sessions in the real source and target harnesses.",
    status := .conditional },
  { id := "D-010",
    statement := "Callers treat a non-zero conversion status as failure and do not consume a stale artifact as output from that failed invocation.",
    falsifier := "A supported launcher or documented workflow presents a prior output file as the result of a failed conversion.",
    validation := "Exercise every failure class through each public launcher with a pre-existing sentinel output and verify it is neither replaced nor reported as new output.",
    status := .conditional },
  { id := "D-011",
    statement := "For each version-pinned supported adapter, equality of the declared common projection denotes equality of the corresponding source and target conversation meaning.",
    falsifier := "A real harness or representative reader interprets projection-equal source and target artifacts differently for a declared common concept.",
    validation := "Maintain a versioned concept census and validate projection-equal fixtures through source/target rendering, continuation, and held-out review.",
    status := .conditional },
  { id := "D-012",
    statement := "A complete preserve, reversible-carrier, report, or refusal disposition makes every conversion loss observable to the caller or downstream reviewer.",
    falsifier := "A declared disposition hides a source fact, cannot be decoded, or is omitted from both output and diagnostics.",
    validation := "Mutation-test each disposition path and independently reconcile source facts against target artifacts and structured diagnostics.",
    status := .conditional }
]

/-- Evidence rules are project choices, not claims about the environment. They
are deliberately excluded from `referenceDomain`. -/
def validationPolicies : List ValidationPolicy := [
  { id := "VP-001",
    statement := "Use the frozen TypeScript converter only as a developer-preview compatibility baseline, never as a truth oracle.",
    rationale := "Differentials reveal migration drift, but target contracts and source meaning decide whether a divergence is a defect." },
  { id := "VP-002",
    statement := "External evidence contributes to readiness only when a release-side verifier checks candidate binding, retained artifact bytes against the named digest, and the recorded claim.",
    rationale := "A manually edited status and a digest-shaped string establish neither artifact retention nor the truth of the evidence claim." }
]

/-- Normative CLI support surface used by requirements and downstream coverage
censuses. Prose descriptions are explanatory; these closed lists are the
machine-readable meaning of "declared source" and "declared target". -/
def declaredSourceCliNames : List String := [
  "loom", "pi", "claude", "codex", "cursor-agent", "hermes",
  "google-ai-studio", "cursor-ide"]

def declaredTargetCliNames : List String := [
  "loom", "pi", "claude", "codex", "cursor-agent"]

def declaredConversionSurfaceWellFormed : Bool :=
  !declaredSourceCliNames.isEmpty && !declaredTargetCliNames.isEmpty &&
    uniqueStrings declaredSourceCliNames && uniqueStrings declaredTargetCliNames &&
    declaredSourceCliNames.all (fun name => !name.isEmpty) &&
    declaredTargetCliNames.all (fun name => !name.isEmpty)

def requirements : List RequirementRecord := [
  { id := .sourceCoverage, title := "Supported conversion surface",
    statement := "The converter shall import every declared source and export every declared target or return an explicit unsupported-target refusal.",
    rationale := "A partial dispatch hidden behind stringly CLI names is not a reliable product surface.",
    fitCriterion := "Imports: loom, pi, claude, codex, cursor-agent, hermes, google-ai-studio, cursor-ide. Exports: loom, pi, claude, codex, cursor-agent. One accepted fixture per importer and round-trip witness per implemented same-format exporter.",
    priority := .mustPreview, level := .productConstraint },
  { id := .structuralIntegrity, title := "Structurally valid IR",
    statement := "The converter shall not emit from an IR with invalid parents, threads, call references, sidechain anchors, active leaf, or compaction bounds.",
    rationale := "Downstream readers must not need defensive graph repair.",
    fitCriterion := "`runPipeline = .ok _` implies `Loom.WellFormed`; adversarial fixtures exercise every violation family.",
    priority := .mustPreview, level := .productConstraint },
  { id := .semanticFidelity, title := "Common-semantic fidelity",
    statement := "For accepted conversions, the target projection shall agree with the source on every concept representable by both formats.",
    rationale := "Syntactically valid output can still be semantically wrong.",
    fitCriterion := "Fixture differential has zero unadjudicated divergences; preview corpora retain the recorded Codex, Claude, and Cursor Agent agreement results.",
    priority := .mustPreview },
  { id := .noSilentLoss, title := "No silent loss",
    statement := "Every unrepresentable or degraded source concept shall be preserved in an explicit carrier, reported as an obligation/assumption, or refused before output.",
    rationale := "Silent conversion damage is worse than an explicit refusal.",
    fitCriterion := "Every exporter has an executable content-sensitive loss policy; tests cover each refusal/preservation class, not only sidechains.",
    priority := .mustStable },
  { id := .wireCompatibility, title := "Lossless Loom interchange",
    statement := "The versioned Loom wire format shall preserve every IR constructor and reject incompatible or malformed required structure.",
    rationale := "The native wire is the escape hatch when a flat target cannot represent the transcript.",
    fitCriterion := "Export-import-export is idempotent over an all-constructor witness; wrong schema and missing required fields fail; additive unknown fields and labels survive according to policy.",
    priority := .mustPreview, level := .productConstraint },
  { id := .sidechainSafety, title := "Sidechain integrity",
    statement := "Subagent threads shall retain valid spawn anchors in Loom/native sidecars, become explicitly detached when no anchor is knowable, or cause a flat-target refusal.",
    rationale := "Flattening child agents into the main conversation changes causality.",
    fitCriterion := "Build pins cover anchored and detached stitching; Loom/native sidecar export preserves threads; pi/codex flat export refuses non-main threads.",
    priority := .mustPreview, level := .productConstraint },
  { id := .provenanceHonesty, title := "Provenance and epistemic honesty",
    statement := "Recorded, inferred, synthesized, absent, unknown, and dropped data shall remain distinguishable and every importer judgment shall be auditable.",
    rationale := "Fabricated certainty makes later analysis unsound.",
    fitCriterion := "All inference/fabrication paths emit typed provenance or ImportNotes; malformed or unknown records are rejected, preserved, or logged rather than silently skipped.",
    priority := .mustStable },
  { id := .failureContract, title := "Actionable failure contract",
    statement := "Unsupported, malformed, structurally invalid, or loss-requiring conversions shall fail before output with a stable non-zero class and diagnostic.",
    rationale := "Operators need to distinguish invocation, import, and export failures.",
    fitCriterion := "Exit 1 = invocation, 2 = import, 3 = export/validation; tests assert that each class commits no new artifact, preserves any pre-existing output byte-for-byte, never reports it as this invocation's result, and identifies the reason.",
    priority := .mustPreview, level := .productConstraint },
  { id := .determinism, title := "Deterministic conversion",
    statement := "The same input bytes, explicit options, and dependency versions shall produce byte-identical output and the same diagnostics.",
    rationale := "Differential testing and forensic use require reproducibility.",
    fitCriterion := "Repeat each release fixture conversion twice and compare output bytes and exit status.",
    priority := .mustStable, level := .productConstraint },
  { id := .portableBuild, title := "Reproducible standalone build",
    statement := "The converter shall build with the pinned Lean toolchain and the resulting binary shall run without Lake; optional external dependencies shall be named.",
    rationale := "A converter that only runs in its source checkout is not releasable.",
    fitCriterion := "`lake build loom` succeeds on a clean checkout; `.lake/build/bin/loom` runs directly; Cursor IDE explicitly reports its sqlite3 dependency.",
    priority := .mustPreview, level := .productConstraint },
  { id := .schemaEvolution, title := "Detectable schema evolution",
    statement := "A new concept or declared format shall force an explicit support decision, and unknown wire additions shall follow the compatibility policy.",
    rationale := "Format drift must fail loudly or remain representable.",
    fitCriterion := "Exhaustive Lean matches fail to compile after a new Concept/Format constructor; unknown external record kinds have preserve/log/refuse behavior and a census upgrade path.",
    priority := .mustStable, level := .productConstraint },
  { id := .performance, title := "Measured resource behavior",
    statement := "The project shall not claim performance until stakeholders set corpus size, latency, and memory fit criteria.",
    rationale := "'Fast' without a workload and threshold is not a requirement.",
    fitCriterion := "Before stable release, record a representative workload plus p95 wall-time and peak-RSS thresholds, then add a repeatable benchmark gate.",
    priority := .mustStable },
  { id := .transcriptReadability, title := "Readable transcript review",
    statement := "A developer shall be able to inspect an accepted transcript and recover ordered roles, visible content, tool calls/results, thread relationships, and conversion judgments without reading source JSON or seeing raw harness-control envelopes.",
    rationale := "A syntactically convertible file is not useful for review or forensics if its protocol scaffolding obscures the conversation.",
    fitCriterion := "`loom inspect` renders a seeded all-role/tool/thread transcript deterministically; recognized Claude control envelopes render as labeled text with no known control tags; a blinded reviewer recovers every seeded fact.",
    priority := .mustPreview },
  { id := .crossHarnessContinuation, title := "Cross-harness continuation",
    statement := "For every advertised continuation target, a generated artifact shall open in the version-pinned real harness and append a sentinel next turn at the intended active leaf without manual repair.",
    rationale := "Own-parser round trips prove internal consistency, not that a real harness can continue the conversation.",
    fitCriterion := "Version-pinned smoke tests cover every target labeled resumable in the public matrix, append a unique sentinel, and re-read the resulting history. A target whose observed store is not a supported import interface must be labeled file-only and refuse installation before mutation.",
    priority := .mustPreview },
  { id := .maximalPreservation, title := "Preservation maximality",
    statement := "Among outputs accepted by the selected target and policy, the converter shall preserve every source datum the target can represent; no valid alternative conversion may preserve a strict superset without losing another required fact.",
    rationale := "No-silent-loss prevents hidden damage but does not prove that the converter retained as much as it could have.",
    fitCriterion := "Every IR constructor and provenance escape payload has a per-target preserve/normalize/carrier/refuse decision, an executable loss witness, and a maximality argument or counterexample test.",
    priority := .mustStable },
  { id := .semanticAuthority, title := "Single semantic authority",
    statement := "Every public agent-convert entrypoint shall identify its semantic engine, and the default product path shall perform transcript parsing, normalization, fidelity decisions, loss analysis, and target serialization in the Lean core; a host-language launcher may only resolve paths, invoke the binary, install completed artifacts, and relay diagnostics.",
    rationale := "Two default semantic engines can disagree while each passes its own tests, making the checked Lean requirements irrelevant to shipped behavior.",
    fitCriterion := "Every human and JSON result reports `engine`, engine version, and core version/commit. The utils launcher and packaged `agent-convert` CLI import no format adapters on their defaults, produce artifacts byte-identical to direct pinned-Lean invocation, and expose the legacy TypeScript engine only through explicit `ts-legacy` selection. The package names one immutable external-core revision, rejects unknown/working-tree/mismatched cores, and the exact tarball passes missing-core and matching-core clean-install CI on supported platforms.",
    priority := .mustPreview, level := .productConstraint },
  { id := .toolLifecycleFidelity, title := "Tool lifecycle fidelity",
    statement := "Every tool invocation and recorded result on the selected conversation path shall preserve its order, identity, source name, complete arguments, complete result content, call/result linkage, and error state with provenance, or receive an explicit reversible carrier or pre-output refusal.",
    rationale := "Tool history is part of the conversation state; severed links, rewritten schemas, fabricated results, or dropped outputs can mislead the next model and the developer.",
    fitCriterion := "A seeded matrix covers interleaved text/calls, parallel calls, duplicate and missing ids, unmatched and interrupted calls, structured/non-text results, and true/false/unrecorded errors. Export-import continuation projection agrees for representable pairs; carrier/refusal cases retain every source field; reported call/result/carrier/synthesis counts reconcile exactly with the source census; real target resume performs no historical tool call.",
    priority := .mustPreview },
  { id := .contextIsolation, title := "Harness-context isolation",
    statement := "Harness-injected developer, system, policy, permission, configuration, and runtime records shall never be represented as user-authored or assistant-authored conversation turns in another harness.",
    rationale := "Changing control-plane context into user dialogue corrupts authorship, pollutes the readable transcript, and can cause a target model to obey stale or foreign policy.",
    fitCriterion := "A fixture and held-out real rollout containing user, assistant, developer, system, permission, and environment records converts with every genuine conversation turn in order, zero injected records labeled USER/ASSISTANT, and exact excluded context retained in typed provenance/extras or named in a loss report. Real Claude and Codex views contain no source policy or runtime envelope as a user prompt.",
    priority := .mustPreview }
]

def machineSpecification : List InterfaceClause := [
  { id := "S-001", mentions := [sourceArtifact, invocation, cursorIdeSqliteQueryResult],
    constrains := outputArtifact,
    timeReference := .pastOrPresent,
    behavior := "On typed success, emit only bytes passing the declared target syntax and operational-contract checks." },
  { id := "S-002-STATUS", mentions := [sourceArtifact, invocation,
      cursorIdeSqliteQueryResult], constrains := exitStatus,
    timeReference := .pastOrPresent,
    behavior := "Return the import-failure status when source parsing or source acquisition fails." },
  { id := "S-002-OUTPUT", mentions := [sourceArtifact, invocation,
      cursorIdeSqliteQueryResult], constrains := outputArtifact,
    timeReference := .pastOrPresent,
    behavior := "Commit no output artifact when source parsing or source acquisition fails." },
  { id := "S-003", mentions := [sourceArtifact, invocation], constrains := outputArtifact,
    timeReference := .pastOrPresent,
    behavior := "Emit ordinary output only after the complete structural validator passes." },
  { id := "S-004-STATUS", mentions := [sourceArtifact, invocation],
    constrains := exitStatus,
    timeReference := .pastOrPresent,
    behavior := "Return distinct invocation, import, and export/validation failure statuses." },
  { id := "S-004-DIAGNOSTIC", mentions := [sourceArtifact, invocation],
    constrains := diagnostic,
    timeReference := .pastOrPresent,
    behavior := "Name the typed failure class and cause in the refusal diagnostic." },
  { id := "S-004-OUTPUT", mentions := [sourceArtifact, invocation],
    constrains := outputArtifact,
    timeReference := .pastOrPresent,
    behavior := "On typed refusal, preserve any pre-existing destination and commit no new artifact." },
  { id := "S-005", mentions := [sourceArtifact, invocation], constrains := outputArtifact,
    timeReference := .pastOrPresent,
    behavior := "Use the versioned Loom wire when all IR constructors must be preserved." },
  { id := "S-006", mentions := [sourceArtifact, invocation], constrains := exitStatus,
    timeReference := .pastOrPresent,
    behavior := "Return a destructive-loss refusal status for a flat export of non-main threads." },
  { id := "S-007", mentions := [sourceArtifact, invocation], constrains := outputArtifact,
    timeReference := .pastOrPresent,
    behavior := "Emit deterministic bytes from pure conversion functions for fixed inputs and options." },
  { id := "S-008-OUTPUT", mentions := [sourceArtifact, invocation],
    constrains := outputArtifact,
    timeReference := .pastOrPresent,
    behavior := "Retain assumptions, inferred values, and conversion obligations in auditable output data when the target supports it." },
  { id := "S-008-DIAGNOSTIC", mentions := [sourceArtifact, invocation],
    constrains := diagnostic,
    timeReference := .pastOrPresent,
    behavior := "Report assumptions, inferred values, and conversion obligations not retained in output data." },
  { id := "S-009", mentions := [sourceArtifact, invocation], constrains := outputArtifact,
    timeReference := .pastOrPresent,
    behavior := "Render a deterministic review view with explicit roles, tools, links, threads, and import judgments while normalizing recognized harness-control envelopes." },
  { id := "S-010", mentions := [sourceArtifact, invocation], constrains := outputArtifact,
    timeReference := .pastOrPresent,
    behavior := "Emit the target registration and continuation metadata required by the selected version-pinned harness." },
  { id := "S-011", mentions := [sourceArtifact, invocation], constrains := exitStatus,
    timeReference := .pastOrPresent,
    behavior := "Refuse destructive export obligations unless an explicit reversible carrier or approved loss policy discharges them." },
  { id := "S-012-OUTPUT", mentions := [sourceArtifact, invocation],
    constrains := outputArtifact,
    timeReference := .pastOrPresent,
    behavior := "Route every default public output through the package-pinned Lean semantic core without host-language transcript mutation." },
  { id := "S-012-DIAGNOSTIC", mentions := [sourceArtifact, invocation],
    constrains := diagnostic,
    timeReference := .pastOrPresent,
    behavior := "Report the selected semantic engine identity and immutable core revision." },
  { id := "S-012-STATUS", mentions := [sourceArtifact, invocation],
    constrains := exitStatus,
    timeReference := .pastOrPresent,
    behavior := "Reject an unversioned, working-tree, unavailable, or mismatched core before conversion." },
  { id := "S-013-OUTPUT", mentions := [sourceArtifact, invocation],
    constrains := outputArtifact,
    timeReference := .pastOrPresent,
    behavior := "Preserve or explicitly carry the complete ordered tool lifecycle in successful output." },
  { id := "S-013-STATUS", mentions := [sourceArtifact, invocation],
    constrains := exitStatus,
    timeReference := .pastOrPresent,
    behavior := "Return a destructive-loss refusal when neither target representation nor a declared reversible tool carrier is valid." },
  { id := "S-014-OUTPUT", mentions := [sourceArtifact, invocation],
    constrains := outputArtifact,
    timeReference := .pastOrPresent,
    behavior := "Classify source channels before export and retain excluded harness context in typed output provenance when representable." },
  { id := "S-014-DIAGNOSTIC", mentions := [sourceArtifact, invocation],
    constrains := diagnostic,
    timeReference := .pastOrPresent,
    behavior := "Report excluded harness context that cannot be retained in typed output provenance." },
  { id := "S-015", mentions := [sourceArtifact, invocation],
    constrains := outputArtifact,
    timeReference := .pastOrPresent,
    behavior := "Emit successful output only when its declared common projection agrees with the accepted source." },
  { id := "S-016", mentions := [sourceArtifact, invocation],
    constrains := outputArtifact,
    timeReference := .pastOrPresent,
    behavior := "Emit successful output only when every source fact has a complete preserve, carrier, report, or refusal disposition." },
  { id := "S-CURSOR-QUERY", mentions := [sourceArtifact, invocation,
      cursorIdeSqliteQueryResult], constrains := outputArtifact,
    timeReference := .pastOrPresent,
    behavior := "For Cursor IDE input, derive conversion output only from the selected read-only SQLite query response." }
]

/-- W, D, R, and S as an executable Jackson-Zave problem bundle. Domain
assumption status is evidence metadata; every assumption remains an indicative
assertion in D even after a particular validation run supports it. -/
def referenceWorld : List Statement :=
  designations.map (fun designation =>
    .designation designation.term designation.grounding) ++
  domainAssumptions.map (fun assumption =>
    .assertion .indicative assumption.statement)

def referenceDomain : List Statement :=
  domainAssumptions.map (fun assumption =>
    .assertion .indicative assumption.statement)

def topLevelRequirement : Statement :=
  .assertion .optative
    "Every accepted conversion either yields a target-consumable artifact that preserves common meaning without silent loss, or yields a recognized safe refusal whose invocation artifact is not consumed."

def referenceProblem : RequirementsProblem := {
  world := referenceWorld
  domain := referenceDomain
  requirement := topLevelRequirement
  specification := machineSpecification
}

def referenceProblemWellPosed : Bool := referenceProblem.wellPosed

def validationWorklistMatchesDomainAssumptions : Bool :=
  referenceProblem.validationWorklist == referenceDomain &&
  referenceProblem.validationWorklist.length == domainAssumptions.length

/-- Typed designations from concrete catalogue identifiers to the abstract
conversion facets. These are vocabulary/semantics links, not assertions that D
has been externally validated or that an implementation refines S. -/
inductive ConcreteConversionDomainClause where
  | targetContractD003
  | semanticAdequacyD011
  | lossObservabilityD012
  | safeRefusalD010
  deriving Repr, DecidableEq, BEq

def ConcreteConversionDomainClause.all : List ConcreteConversionDomainClause := [
  .targetContractD003, .semanticAdequacyD011, .lossObservabilityD012,
  .safeRefusalD010
]

theorem ConcreteConversionDomainClause.censusComplete
    (clause : ConcreteConversionDomainClause) :
    ConcreteConversionDomainClause.all.contains clause = true := by
  cases clause <;> native_decide

def ConcreteConversionDomainClause.catalogueId :
    ConcreteConversionDomainClause -> String
  | .targetContractD003 => "D-003"
  | .semanticAdequacyD011 => "D-011"
  | .lossObservabilityD012 => "D-012"
  | .safeRefusalD010 => "D-010"

def ConcreteConversionDomainClause.facet :
    ConcreteConversionDomainClause -> ConversionDomainFacet
  | .targetContractD003 => .targetContract
  | .semanticAdequacyD011 => .semanticAdequacy
  | .lossObservabilityD012 => .lossObservability
  | .safeRefusalD010 => .safeRefusal

def ConcreteConversionDomainClause.interpret
    (clause : ConcreteConversionDomainClause) (w : ConversionSituation) : Prop :=
  clause.facet.interpret w

inductive ConcreteConversionSpecificationClause where
  | requiredSuccessS
  | refusalApplicabilityS
  | classifiedRefusalS004
  deriving Repr, DecidableEq, BEq

def ConcreteConversionSpecificationClause.all :
    List ConcreteConversionSpecificationClause := [
  .requiredSuccessS, .refusalApplicabilityS, .classifiedRefusalS004
]

theorem ConcreteConversionSpecificationClause.censusComplete
    (clause : ConcreteConversionSpecificationClause) :
    ConcreteConversionSpecificationClause.all.contains clause = true := by
  cases clause <;> native_decide

def ConcreteConversionSpecificationClause.catalogueIds :
    ConcreteConversionSpecificationClause -> List String
  | .requiredSuccessS => ["S-001", "S-015", "S-016"]
  | .refusalApplicabilityS => ["S-001", "S-006", "S-011", "S-013-STATUS"]
  | .classifiedRefusalS004 =>
      ["S-004-STATUS", "S-004-DIAGNOSTIC", "S-004-OUTPUT"]

def ConcreteConversionSpecificationClause.facet :
    ConcreteConversionSpecificationClause -> ConversionSpecificationFacet
  | .requiredSuccessS => .requiredSuccess
  | .refusalApplicabilityS => .refusalApplicability
  | .classifiedRefusalS004 => .classifiedRefusal

def ConcreteConversionSpecificationClause.interpret
    (clause : ConcreteConversionSpecificationClause)
    (w : ConversionSituation) : Prop :=
  clause.facet.interpret w

inductive ConcreteConversionRequirementClause where
  | targetConsumabilityR014
  | semanticFidelityR003
  | noSilentLossR004
  deriving Repr, DecidableEq, BEq

def ConcreteConversionRequirementClause.all :
    List ConcreteConversionRequirementClause := [
  .targetConsumabilityR014, .semanticFidelityR003, .noSilentLossR004
]

theorem ConcreteConversionRequirementClause.censusComplete
    (clause : ConcreteConversionRequirementClause) :
    ConcreteConversionRequirementClause.all.contains clause = true := by
  cases clause <;> native_decide

def ConcreteConversionRequirementClause.catalogueId :
    ConcreteConversionRequirementClause -> RequirementId
  | .targetConsumabilityR014 => .crossHarnessContinuation
  | .semanticFidelityR003 => .semanticFidelity
  | .noSilentLossR004 => .noSilentLoss

def ConcreteConversionRequirementClause.facet :
    ConcreteConversionRequirementClause -> ConversionRequirementFacet
  | .targetConsumabilityR014 => .targetConsumability
  | .semanticFidelityR003 => .semanticFidelity
  | .noSilentLossR004 => .noSilentLoss

def ConcreteConversionRequirementClause.interpret
    (clause : ConcreteConversionRequirementClause)
    (w : ConversionSituation) : Prop :=
  clause.facet.interpret w

/-- R-008 is explicitly a product constraint, not an abstract R facet. Its
machine meaning is the exact generic S-004 failure contract. -/
inductive ConcreteConversionProductConstraintClause where
  | failureContractR008
  deriving Repr, DecidableEq, BEq

def ConcreteConversionProductConstraintClause.all :
    List ConcreteConversionProductConstraintClause := [
  .failureContractR008
]

theorem ConcreteConversionProductConstraintClause.censusComplete
    (clause : ConcreteConversionProductConstraintClause) :
    ConcreteConversionProductConstraintClause.all.contains clause = true := by
  cases clause <;> native_decide

def ConcreteConversionProductConstraintClause.catalogueId :
    ConcreteConversionProductConstraintClause -> RequirementId
  | .failureContractR008 => .failureContract

def ConcreteConversionProductConstraintClause.specificationCatalogueIds :
    ConcreteConversionProductConstraintClause -> List String
  | .failureContractR008 =>
      ["S-004-STATUS", "S-004-DIAGNOSTIC", "S-004-OUTPUT"]

def ConcreteConversionProductConstraintClause.interpret
    (_clause : ConcreteConversionProductConstraintClause)
    (failure : ProductFailureSituation) : Prop :=
  ProductFailureContract failure

def concreteConversionDomain (w : ConversionSituation) : Prop :=
  ConcreteConversionDomainClause.targetContractD003.interpret w /\
  ConcreteConversionDomainClause.semanticAdequacyD011.interpret w /\
  ConcreteConversionDomainClause.lossObservabilityD012.interpret w /\
  ConcreteConversionDomainClause.safeRefusalD010.interpret w

def concreteConversionSpec (w : ConversionSituation) : Prop :=
  ConcreteConversionSpecificationClause.requiredSuccessS.interpret w /\
  ConcreteConversionSpecificationClause.refusalApplicabilityS.interpret w /\
  ConcreteConversionSpecificationClause.classifiedRefusalS004.interpret w

/-- The last conjunct comes from the top-level optative safe-refusal outcome.
It is intentionally not designated as product-constraint R-008. -/
def concreteConversionRequirement (w : ConversionSituation) : Prop :=
  ConcreteConversionRequirementClause.targetConsumabilityR014.interpret w /\
  ConcreteConversionRequirementClause.semanticFidelityR003.interpret w /\
  ConcreteConversionRequirementClause.noSilentLossR004.interpret w /\
  ConversionRequirementFacet.safeRefusal.interpret w

theorem concreteConversionDomain_iff (w : ConversionSituation) :
    concreteConversionDomain w ↔ ConversionDomain w := by
  rfl

theorem concreteConversionSpec_iff (w : ConversionSituation) :
    concreteConversionSpec w ↔ ConversionSpec w := by
  rfl

theorem concreteConversionRequirement_iff (w : ConversionSituation) :
    concreteConversionRequirement w ↔ ConversionRequirement w := by
  rfl

/-- Concrete D/S/R identifier designations composed with the abstract reduction
schema. This is a catalogue-level adequacy theorem, not implementation
refinement and not external validation of the designated D clauses. -/
theorem concreteCatalogueConversionAdequacy (w : ConversionSituation) :
    concreteConversionDomain w -> concreteConversionSpec w ->
      concreteConversionRequirement w := by
  simpa [concreteConversionDomain_iff, concreteConversionSpec_iff,
    concreteConversionRequirement_iff] using conversionAdequacy w

/-- This is a real proof-bearing binding. It is not consumed by pure readiness;
its indexed proposition, rather than catalogue prose, carries the evidence. -/
def concreteCatalogueAdequacyLeanBinding :
    LeanEvidenceBinding "E-001"
      (∀ w, concreteConversionDomain w -> concreteConversionSpec w ->
        concreteConversionRequirement w) :=
  ⟨concreteCatalogueConversionAdequacy⟩

def concreteReductionDesignationsWellFormed : Bool :=
  uniqueStrings
      (ConcreteConversionDomainClause.all.map (·.catalogueId)) &&
  ConcreteConversionDomainClause.all.all (fun clause =>
    domainAssumptions.any (fun assumption =>
      assumption.id == clause.catalogueId)) &&
  ConcreteConversionSpecificationClause.all.all (fun clause =>
    uniqueStrings clause.catalogueIds && clause.catalogueIds.all (fun id =>
      machineSpecification.any (fun specification => specification.id == id))) &&
  ConcreteConversionRequirementClause.all.all (fun clause =>
    requirements.any (fun requirement =>
      requirement.id == clause.catalogueId &&
      requirement.level == .problemWorldOutcome)) &&
  ConcreteConversionProductConstraintClause.all.all (fun clause =>
    requirements.any (fun requirement =>
      requirement.id == clause.catalogueId &&
      requirement.level == .productConstraint) &&
    clause.specificationCatalogueIds.all (fun id =>
      machineSpecification.any (fun specification => specification.id == id)))

def evidence : List Evidence := [
  { id := "E-001", kind := .theorem,
    roles := [.adequacyArgument],
    claim := "Typed designations connect D-003/D-010/D-011/D-012, required-success/applicable-refusal/exact-refusal S clauses, R-003/R-004/R-014, and the top-level safe-refusal outcome to the abstract reduction. Product-constraint R-008 is separately designated to S-004 and is not an abstract R facet. This establishes neither implementation refinement nor external validation of D.",
    locator := "LoomRequirements.AgentConvert.concreteCatalogueConversionAdequacy" },
  { id := "E-002", kind := .theorem,
    roles := [.implementationRefinement],
    claim := "The real pure runPipeline exactly implements its structural-gate failure, blocker failure, and selected-exporter result boundary; successful runs imply WellFormedness, no blocker, and exact exporter bytes.",
    locator := "LoomRequirements.Proofs.runPipelineRefinesConcreteMachineSpec" },
  { id := "E-003", kind := .decidePin,
    roles := [.implementationRefinement],
    claim := "All declared pure import fixtures produce structurally valid IR.",
    locator := "LoomRequirements.Proofs.allImportWitnessesPass" },
  { id := "E-004", kind := .decidePin,
    roles := [.implementationRefinement],
    claim := "Same-format exporters and Loom wire satisfy their declared fixture round trips.",
    locator := "LoomRequirements.Proofs.allRoundTripWitnessesPass" },
  { id := "E-005", kind := .decidePin,
    roles := [.implementationRefinement],
    claim := "Adversarial references and thread structures are rejected by WellFormedness.",
    locator := "LoomRequirements.Proofs.structuralCounterexamplesRejected" },
  { id := "E-006", kind := .fixtureTest,
    roles := [.implementationRefinement, .releaseProcess],
    claim := "The focused release script exercises CLI imports, exports, wire compatibility, sidecars, fallback, and refusal behavior.",
    locator := "spec/loom/scripts/verify.sh via npm run test:loom" },
  { id := "E-007", kind := .corpusValidation,
    roles := [.implementationRefinement, .domainValidation],
    claim := "2026-07-08 differential: Codex 429/429 convertible files, Claude 237/237, Cursor Agent 427/427 agree under the declared projections.",
    locator := "REQUIREMENTS_EVIDENCE.md corpus ledger" },
  { id := "E-008", kind := .buildValidation,
    roles := [.releaseProcess],
    claim := "Pinned Lean build and standalone binary execution pass in the release gate.",
    locator := "spec/loom/scripts/verify.sh" },
  { id := "E-009", kind := .decidePin,
    roles := [.implementationRefinement],
    claim := "Loom wire rejects incompatible required structure and preserves additive unknowns.",
    locator := "LoomConvert.Wire compatibility pins" },
  { id := "E-010", kind := .review,
    roles := [.gapRecord],
    claim := "Cross-format exporters still lack a complete content-sensitive loss/refusal policy.",
    locator := "REQUIREMENTS_EVIDENCE.md open proof obligations",
    polarity := .contradicts },
  { id := "E-011", kind := .review,
    roles := [.gapRecord],
    claim := "Some importer leniency and unknown-record paths are not yet represented by ImportNotes.",
    locator := "REQUIREMENTS_EVIDENCE.md open proof obligations",
    polarity := .contradicts },
  { id := "E-012", kind := .review,
    roles := [.gapRecord],
    claim := "No stakeholder-approved performance workload or threshold exists.",
    locator := "REQUIREMENTS.md R-012", polarity := .contradicts },
  { id := "E-013", kind := .fixtureTest,
    roles := [.implementationRefinement],
    claim := "Two identical CLI conversions produce byte-identical stdout, stderr, and status.",
    locator := "spec/loom/scripts/verify.sh deterministic CLI output gate" },
  { id := "E-014", kind := .decidePin,
    roles := [.implementationRefinement],
    claim := "The continuation projection distinguishes tool names/arguments; native Codex and pi witnesses preserve tool lifecycle/result state, while Claude foreign tools use a checked readable non-native carrier.",
    locator := "LoomRequirements.Proofs continuation projection witnesses" },
  { id := "E-015", kind := .fixtureTest,
    roles := [.implementationRefinement],
    claim := "The review renderer exposes roles, tool calls/results, links, and structural status without protocol tags on the seeded fixture.",
    locator := "LoomRequirements.Proofs.readableTranscriptWitness and spec/loom/scripts/verify.sh" },
  { id := "E-016", kind := .review,
    roles := [.releaseProcess],
    claim := "The public continuation claim is restricted to version-pinned targets with successful open/append/re-read evidence; failed targets remain file-only and refuse installation.",
    locator := "REQUIREMENTS_EVIDENCE.md O-005" },
  { id := "E-017", kind := .review,
    roles := [.gapRecord],
    claim := "No total per-target loss policy or preservation-maximality proof exists yet.",
    locator := "REQUIREMENTS_EVIDENCE.md O-001", polarity := .contradicts },
  { id := "E-018", kind := .review,
    roles := [.gapRecord],
    claim := "Blinded human readability validation has not yet been run.",
    locator := "REQUIREMENTS_EVIDENCE.md O-006", polarity := .contradicts },
  { id := "E-019", kind := .fixtureTest,
    roles := [.implementationRefinement],
    claim := "The default TypeScript launcher has no format-adapter or transcript-IO imports, direct Lean and launcher artifacts are byte-identical, and missing/legacy-only cases refuse without changing engines.",
    locator := "test/loom-thin-launcher.test.mjs and spec/loom/scripts/verify.sh" },
  { id := "E-020", kind := .harnessValidation,
    roles := [.domainValidation, .gapRecord],
    claim := "A 2026-07-09 real Codex-to-Claude conversion exposed Codex developer permissions, skills, environment context, and other control-plane records as Claude USER prompts; tool reconciliation was not demonstrated to the operator.",
    locator := "REQUIREMENTS_EVIDENCE.md V-007 negative validation, source 019f4ace-fd03-7830-8a11-2004ef0aa577",
    polarity := .contradicts },
  { id := "E-021", kind := .review,
    roles := [.gapRecord],
    claim := "The rebuilt packaged agent-convert CLI defaults to a thin Lean subprocess and fails closed, but its npm tarball neither contains nor acquires the required Loom binary.",
    locator := "agent-convert src/agentConvert.ts, package.json files, and npm pack --dry-run",
    polarity := .contradicts },
  { id := "E-022", kind := .decidePin,
    roles := [.implementationRefinement],
    claim := "Exact current-Codex permissions/skills/environment envelopes are archived outside conversation with ImportNotes; embedded tag-like user text survives unchanged.",
    locator := "LoomConvert.CodexCli.codexRuntimeControlsArchived" },
  { id := "E-023", kind := .harnessValidation,
    roles := [.implementationRefinement, .domainValidation],
    claim := "A fresh Claude-to-Codex conversion opened in Codex CLI 0.144.1 without raw Claude controls or a model/version warning, appended a unique sentinel, and re-read it at the active leaf.",
    locator := "REQUIREMENTS_EVIDENCE.md V-008, target 9a14d808-1bc4-4460-a97f-cede25e5c82c" },
  { id := "E-024", kind := .fixtureTest,
    roles := [.implementationRefinement],
    claim := "The packaged TS compatibility importer applies the same exact whole-envelope rule, retains raw Codex controls in codexExtras, and refuses lossy native tool mappings.",
    locator := "test/codex-synthetic.test.mjs and test/convert-from-pi.test.mjs" },
  { id := "E-025", kind := .fixtureTest,
    roles := [.implementationRefinement],
    claim := "A checked Codex-to-Claude fixture independently reconciles every active-context call and result through occurrence-addressed, reversible historical carriers, including linked tool-search output, structured results, one interrupted call, zero synthesis, zero linkage mismatch, and zero leaked controls.",
    locator := "testdata/codex/tool-lifecycle-controls.jsonl, scripts/audit-codex-claude.mjs, and scripts/verify.sh" },
  { id := "E-026", kind := .harnessValidation,
    roles := [.implementationRefinement, .domainValidation],
    claim := "The rebuilt public package converted the resumable latest-compaction context of an immutable held-out Codex rollout through Lean; an independent audit matched 77 calls and 76 results field by field as non-native Claude history, preserved occurrence linkage, synthesized nothing, and found no exact control turn in Claude dialogue.",
    locator := "REQUIREMENTS_EVIDENCE.md V-009, source 019f4ace-fd03-7830-8a11-2004ef0aa577" },
  { id := "E-027", kind := .harnessValidation,
    roles := [.implementationRefinement, .domainValidation],
    claim := "The thin Lean-default package generated a Codex 0.144.1 rollout whose imported user/assistant and historical-tool turns rendered in the real TUI; Codex appended a sentinel to the same file, and Lean re-imported the augmented session with zero violations and current runtime controls excluded.",
    locator := "REQUIREMENTS_EVIDENCE.md V-010, target a22b23de-1cd2-4e19-b484-ac27f57d50ef" },
  { id := "E-028", kind := .decidePin,
    roles := [.implementationRefinement],
    claim := "Codex target summary counts are derived from exporter eligibility: foreign calls/results reconcile as historical carriers rather than being misreported as native records.",
    locator := "LoomConvert.CodexCli.codexRichTargetPolicyCensusReconciles" },
  { id := "E-029", kind := .harnessValidation,
    roles := [.implementationRefinement, .domainValidation],
    claim := "Claude Code 2.1.206 discovered and rendered an isolated Lean-generated Codex-origin session with every tool lifecycle visibly non-executable and no raw source controls; append/re-import remained structurally valid, but sentinel generation was blocked by missing authentication in the isolated store.",
    locator := "REQUIREMENTS_EVIDENCE.md V-011, target 66666666-7777-4888-8999-aaaaaaaaaaaa" },
  { id := "E-030", kind := .harnessValidation,
    roles := [.implementationRefinement, .domainValidation],
    claim := "One checked conversation was converted by the thin package and continued in authenticated Claude Code 2.1.206, Codex 0.144.1, and pi 0.74.0; every model recovered the imported prior answer and every appended artifact re-imported with zero structural violations.",
    locator := "REQUIREMENTS_EVIDENCE.md V-012, testdata/release/continuation-source.claude.jsonl" },
  { id := "E-031", kind := .harnessValidation,
    roles := [.implementationRefinement, .domainValidation],
    claim := "Cursor Agent 2026.05.28 accepted a locally seeded resume id but omitted the seeded history and replaced the file; the public launcher now labels Cursor file-only and refuses --install.",
    locator := "REQUIREMENTS_EVIDENCE.md V-013, package install-refusal regression" },
  { id := "E-032", kind := .decidePin,
    roles := [.implementationRefinement],
    claim := "Human inspect reports opaque thinking-signature presence without printing encrypted payload bytes; canonical JSON retains the exact signature.",
    locator := "Loom.Render.assistantBlockLines signature-presence example" },
  { id := "E-033", kind := .humanValidation,
    roles := [.domainValidation],
    claim := "A blinded representative developer recovers every seeded role, visible-content, tool-lifecycle, thread, and conversion-judgment fact from the candidate review surface.",
    locator := "candidate-bound blinded readability validation artifact" },
  { id := "E-034", kind := .corpusValidation,
    roles := [.implementationRefinement, .domainValidation],
    claim := "Held-out candidate conversions for every supported harness role family retain genuine conversation turns, exclude injected context from dialogue, and account for excluded context in provenance or a loss report.",
    locator := "candidate-bound held-out context-isolation validation artifact" },
  { id := "E-035", kind := .decidePin,
    roles := [.implementationRefinement],
    claim := "Claude, Codex, and Pi historical tool carriers remain typed historical data and emit no target-native executable tool-call record.",
    locator := "LoomRequirements.Proofs.historicalToolCarriersAreArtifactInert" },
  { id := "E-036", kind := .decidePin,
    roles := [.implementationRefinement],
    claim := "Every supported harness role family has an exhaustive internal context-isolation fixture whose genuine conversation turns remain dialogue and whose control-plane witnesses are excluded and retained exactly; Loom wire is explicitly not a harness role vocabulary.",
    locator := "LoomRequirements.ContextIsolation.contextIsolationF032Aggregate" },
  { id := "E-037", kind := .differentialTest,
    roles := [.implementationRefinement, .releaseProcess],
    claim := "The candidate-bound independent raw-source/raw-target lifecycle matrix executes one byte-snapshotted Loom executable against the exact closed 8-source by 5-target manifest. Each of its 40 cells must match the manifest outcome: independently parsed successful output is field-reconciled, or refusal has the exact policy-specific status and diagnostic while the pre-execution and post-exit observations match for the prior artifact's recorded path and opened-file device/inode values, mode, size, digest, and bytes. This finite observation is neither continuous monitoring nor an atomicity proof, does not establish build/source-revision provenance, and does not guarantee inode identity between observations or against inode reuse. It is not a universal proof or real-harness execution.",
    locator := "spec/loom/scripts/audit-lifecycle-matrix.mjs, spec/loom/testdata/lifecycle/manifest.v1.json, and the retained candidate lifecycle-matrix report" }
]

def fitObligations : List FitObligation := [
  { id := "F-001", requirement := .sourceCoverage,
    statement := "Every declared source has an accepted pure-import fixture.",
    evidence := ["E-003"], status := .satisfied },
  { id := "F-002", requirement := .sourceCoverage,
    statement := "Every declared target has an exporter witness or explicit refusal.",
    evidence := ["E-004", "E-006"], status := .externalValidationPending },
  { id := "F-003", requirement := .structuralIntegrity,
    statement := "Successful pipeline output universally implies WellFormed IR.",
    evidence := ["E-002"], status := .satisfied },
  { id := "F-004", requirement := .structuralIntegrity,
    statement := "A counterexample is pinned for every Violation constructor.",
    evidence := ["E-005"], status := .satisfied },
  { id := "F-005", requirement := .semanticFidelity,
    statement := "Finite importer/exporter fixtures preserve the continuation projection.",
    evidence := ["E-003", "E-004", "E-014"], status := .satisfied },
  { id := "F-006", requirement := .semanticFidelity,
    statement := "Every advertised source/target slice has tool-aware differential evidence.",
    evidence := ["E-014", "E-037"], status := .externalValidationPending },
  { id := "F-007", requirement := .noSilentLoss,
    statement := "Every exporter has a total content-sensitive preserve/carrier/refuse policy.",
    evidence := ["E-010"], status := .partiallySatisfied },
  { id := "F-008", requirement := .wireCompatibility,
    statement := "Wire export/import preserves every IR field and closed enum exactly.",
    evidence := ["E-004", "E-009"], status := .satisfied },
  { id := "F-009", requirement := .wireCompatibility,
    statement := "Wrong/missing required structure fails and additive unknowns follow policy.",
    evidence := ["E-009"], status := .satisfied },
  { id := "F-010", requirement := .sidechainSafety,
    statement := "Anchored/detached sidecars survive native targets and flat targets refuse them.",
    evidence := ["E-005", "E-006"], status := .externalValidationPending },
  { id := "F-011", requirement := .provenanceHonesty,
    statement := "Every inference, fabrication, unknown, malformed, and skip path is typed or refused.",
    evidence := ["E-011"], status := .partiallySatisfied },
  { id := "F-012", requirement := .failureContract,
    statement := "Focused CLI fixtures distinguish invocation, import, and export/validation failure classes.",
    evidence := ["E-006"], status := .externalValidationPending },
  { id := "F-012B", requirement := .failureContract,
    statement := "Every public failure path commits no artifact, preserves any prior output, and never reports stale output as this invocation's result.",
    evidence := ["E-006"], status := .partiallySatisfied },
  { id := "F-013", requirement := .determinism,
    statement := "Every release fixture is repeated with byte/status equality.",
    evidence := ["E-013"], status := .partiallySatisfied },
  { id := "F-014", requirement := .portableBuild,
    statement := "A clean pinned checkout builds and its standalone binary runs without Lake.",
    evidence := ["E-008"], status := .externalValidationPending },
  { id := "F-015", requirement := .schemaEvolution,
    statement := "Closed additions force cases and every open-world source kind is preserved/logged/refused.",
    evidence := ["E-009", "E-011"], status := .partiallySatisfied },
  { id := "F-016", requirement := .performance,
    statement := "Stakeholders approve a workload, p95 time, peak RSS, and benchmark gate.",
    evidence := ["E-012"], status := .unsatisfied },
  { id := "F-017", requirement := .transcriptReadability,
    statement := "Inspect deterministically exposes roles, tools, links, threads, judgments, and opaque signature presence.",
    evidence := ["E-015", "E-032"], status := .externalValidationPending },
  { id := "F-018", requirement := .transcriptReadability,
    statement := "A blinded representative developer recovers every seeded fact.",
    evidence := ["E-033"], status := .externalValidationPending },
  { id := "F-019", requirement := .crossHarnessContinuation,
    statement := "Authenticated Claude open/append/re-read evidence is immutable and candidate-bound.",
    evidence := ["E-030"], status := .externalValidationPending },
  { id := "F-020", requirement := .crossHarnessContinuation,
    statement := "Codex open/append/re-read evidence is immutable and candidate-bound.",
    evidence := ["E-027", "E-030"], status := .externalValidationPending },
  { id := "F-021", requirement := .crossHarnessContinuation,
    statement := "pi open/append/re-read evidence is immutable and candidate-bound.",
    evidence := ["E-030"], status := .externalValidationPending },
  { id := "F-022", requirement := .crossHarnessContinuation,
    statement := "Cursor's failed import interface is retained and installation refuses before mutation.",
    evidence := ["E-031"], status := .externalValidationPending },
  { id := "F-023", requirement := .maximalPreservation,
    statement := "Every target has a total preservation table and maximality argument.",
    evidence := ["E-017"], status := .partiallySatisfied },
  { id := "F-024", requirement := .semanticAuthority,
    statement := "The utils default launcher fixture is semantic-free and byte-equal to direct Lean.",
    evidence := ["E-019"], status := .externalValidationPending },
  { id := "F-024B", requirement := .semanticAuthority,
    statement := "Every packaged/default launcher path is semantic-free and byte-equal to direct pinned Lean.",
    evidence := ["E-019", "E-025"], status := .partiallySatisfied },
  { id := "F-025", requirement := .semanticAuthority,
    statement := "The package rejects any core not matching its immutable core manifest.",
    evidence := ["E-021"], status := .unsatisfied },
  { id := "F-026", requirement := .semanticAuthority,
    statement := "The exact packed artifact passes real-core and missing-core clean-install CI.",
    evidence := ["E-021"], status := .unsatisfied },
  { id := "F-027", requirement := .toolLifecycleFidelity,
    statement := "Seeded lifecycle adversaries cover duplicate/missing IDs, reordering, structured results, errors, and interruptions.",
    evidence := ["E-014"], status := .satisfied },
  { id := "F-028", requirement := .toolLifecycleFidelity,
    statement := "Every advertised direction has field-by-field lifecycle reconciliation or refusal.",
    evidence := ["E-014", "E-028", "E-035", "E-037"],
    status := .externalValidationPending },
  { id := "F-029A", requirement := .toolLifecycleFidelity,
    statement := "Historical tool carriers emit no target-native executable tool-call record and remain typed historical after re-import.",
    evidence := ["E-035"], status := .satisfied },
  { id := "F-029", requirement := .toolLifecycleFidelity,
    statement := "Real targets do not execute historical carrier calls.",
    evidence := ["E-029"], status := .externalValidationPending },
  { id := "F-030", requirement := .contextIsolation,
    statement := "Current Codex controls are excluded exactly while quoted ordinary text survives.",
    evidence := ["E-022", "E-025"], status := .externalValidationPending },
  { id := "F-031", requirement := .contextIsolation,
    statement := "Real Claude and Codex views contain no source policy/runtime prompt.",
    evidence := ["E-023", "E-029"], status := .externalValidationPending },
  { id := "F-032", requirement := .contextIsolation,
    statement := "Every supported harness role family has an internal context-isolation fixture.",
    evidence := ["E-036"], status := .satisfied },
  { id := "F-033", requirement := .contextIsolation,
    statement := "Every supported harness role family has held-out candidate isolation evidence.",
    evidence := ["E-034"], status := .externalValidationPending }
]

def traces : List Trace := [
  { requirement := .sourceCoverage,
    clauses := ["S-001", "S-002-STATUS", "S-002-OUTPUT", "S-CURSOR-QUERY"],
    evidence := ["E-003", "E-004", "E-006"],
    status := .externalValidationPending },
  { requirement := .structuralIntegrity, clauses := ["S-003"],
    evidence := ["E-002", "E-005"], status := .satisfied },
  { requirement := .semanticFidelity, clauses := ["S-001", "S-007", "S-015"],
    evidence := ["E-003", "E-004", "E-006", "E-014", "E-037"],
    status := .externalValidationPending },
  { requirement := .noSilentLoss,
    clauses := ["S-005", "S-006", "S-008-OUTPUT", "S-008-DIAGNOSTIC",
      "S-016"],
    evidence := ["E-001", "E-006", "E-010"], status := .partiallySatisfied,
    gap := some "Sidechains are protected, but all cross-format content-loss classes are not yet gated." },
  { requirement := .wireCompatibility, clauses := ["S-005"],
    evidence := ["E-004", "E-009"], status := .satisfied },
  { requirement := .sidechainSafety, clauses := ["S-005", "S-006"],
    evidence := ["E-005", "E-006"], status := .externalValidationPending },
  { requirement := .provenanceHonesty,
    clauses := ["S-008-OUTPUT", "S-008-DIAGNOSTIC"],
    evidence := ["E-009", "E-011"], status := .partiallySatisfied,
    gap := some "Malformed/unknown source paths are not uniformly rejected, preserved, or logged." },
  { requirement := .failureContract,
    clauses := ["S-002-STATUS", "S-002-OUTPUT", "S-003", "S-004-STATUS",
      "S-004-DIAGNOSTIC", "S-004-OUTPUT", "S-006", "S-011",
      "S-013-STATUS"],
    evidence := ["E-002", "E-006"], status := .partiallySatisfied,
    gap := some "Selected failure fixtures pass, but every public failure path has not been shown to preserve and avoid reporting a stale destination." },
  { requirement := .determinism, clauses := ["S-007"],
    evidence := ["E-004", "E-013"], status := .partiallySatisfied,
    gap := some "One deterministic CLI fixture is repeated; the complete release fixture matrix is not." },
  { requirement := .portableBuild, clauses := ["S-001"],
    evidence := ["E-006", "E-008"], status := .externalValidationPending },
  { requirement := .schemaEvolution,
    clauses := ["S-008-OUTPUT", "S-008-DIAGNOSTIC"],
    evidence := ["E-009", "E-011"], status := .partiallySatisfied,
    gap := some "The closed Concept/Format matrix is exhaustive, but open-world source record handling is uneven." },
  { requirement := .performance, clauses := [], evidence := ["E-012"], status := .unsatisfied,
    gap := some "A stakeholder must approve a workload and quantitative SLO before this can be verified." },
  { requirement := .transcriptReadability,
    clauses := ["S-009", "S-008-OUTPUT", "S-008-DIAGNOSTIC"],
    evidence := ["E-015", "E-032", "E-033"],
    status := .externalValidationPending },
  { requirement := .crossHarnessContinuation, clauses := ["S-003", "S-010", "S-011"],
    evidence := ["E-004", "E-006", "E-027", "E-030", "E-031"],
    status := .externalValidationPending },
  { requirement := .maximalPreservation,
    clauses := ["S-005", "S-008-OUTPUT", "S-008-DIAGNOSTIC", "S-011",
      "S-016"],
    evidence := ["E-009", "E-010", "E-017"], status := .partiallySatisfied,
    gap := some "Loom wire is all-constructor lossless; cross-format exporters do not yet have a total loss policy or maximality argument." },
  { requirement := .semanticAuthority,
    clauses := ["S-001", "S-012-OUTPUT", "S-012-DIAGNOSTIC",
      "S-012-STATUS"],
    evidence := ["E-006", "E-019", "E-021", "E-025", "E-026", "E-027"], status := .partiallySatisfied,
    gap := some "Both default launchers are thin and Lean-backed, but a clean npm install does not contain or acquire the core, portable packed-install evidence is open, and development binaries report working-tree rather than immutable build revision provenance." },
  { requirement := .toolLifecycleFidelity,
    clauses := ["S-003", "S-008-OUTPUT", "S-008-DIAGNOSTIC", "S-011",
      "S-013-OUTPUT", "S-013-STATUS"],
    evidence := ["E-005", "E-014", "E-024", "E-025", "E-026", "E-027",
      "E-028", "E-029", "E-035", "E-037"],
    status := .externalValidationPending },
  { requirement := .contextIsolation,
    clauses := ["S-008-OUTPUT", "S-008-DIAGNOSTIC", "S-009",
      "S-014-OUTPUT", "S-014-DIAGNOSTIC"],
    evidence := ["E-022", "E-023", "E-025", "E-029", "E-034", "E-036"],
    status := .externalValidationPending }
]

def requirementCodes : List String := requirements.map (RequirementId.code ·.id)
def clauseIds : List String := machineSpecification.map (·.id)
def evidenceIds : List String := evidence.map (·.id)
def fitObligationIds : List String := fitObligations.map (·.id)

def contextCatalogueWellFormed : Bool :=
  uniqueStrings (stakeholders.map (·.id)) &&
  stakeholders.all (fun s => !s.name.isEmpty && !s.interest.isEmpty) &&
  uniqueStrings (designations.map (·.term)) &&
  designations.all (fun d => !d.term.isEmpty && !d.grounding.isEmpty)

def validationPoliciesWellFormed : Bool :=
  uniqueStrings (validationPolicies.map (·.id)) &&
  validationPolicies.all (fun policy =>
    !policy.id.isEmpty && !policy.statement.isEmpty && !policy.rationale.isEmpty)

def stakeholderGoalCoverage : Bool :=
  uniqueStrings (stakeholderGoals.map (·.id)) &&
  stakeholderGoals.all (fun goal =>
    !goal.statement.isEmpty &&
    stakeholders.any (fun stakeholder => stakeholder.id == goal.stakeholder) &&
    !goal.requirements.isEmpty &&
    goal.requirements.all (fun rid => RequirementId.all.contains rid)) &&
  ["G-READ", "G-CONT", "G-FID"].all (fun id =>
    stakeholderGoals.any (fun goal => goal.id == id))

def domainCatalogueWellFormed : Bool :=
  uniqueStrings (domainAssumptions.map (·.id)) &&
  domainAssumptions.all (fun d =>
    !d.statement.isEmpty && !d.falsifier.isEmpty && !d.validation.isEmpty)

def catalogueComplete : Bool :=
  RequirementId.all.all (fun rid => requirements.any (fun r => r.id == rid)) &&
  requirements.length == RequirementId.all.length &&
  uniqueStrings requirementCodes

def catalogueHasFitCriteria : Bool :=
  requirements.all (fun r =>
    !r.title.isEmpty && !r.statement.isEmpty && !r.rationale.isEmpty && !r.fitCriterion.isEmpty)

def specificationInterfaceMetadataWellFormed : Bool :=
  machineSpecification.all (fun clause =>
    clause.metadataWellFormed && !clause.id.isEmpty &&
      !clause.behavior.isEmpty) &&
  uniqueStrings clauseIds &&
  machineSpecification.any (fun clause =>
    clause.mentions.contains cursorIdeSqliteQueryResult)

def concretePreviewScope : List RequirementId :=
  requirements.filterMap (fun requirement =>
    if requirement.priority == .mustPreview then some requirement.id else none)

/-- This detects accidental scope/priority drift between modules. It cannot
protect against a malicious coordinated edit to both source files. -/
def previewScopeMatchesReference : Bool :=
  concretePreviewScope == RequirementId.previewScopeManifest &&
  RequirementId.previewScopeManifest.eraseDups.length ==
    RequirementId.previewScopeManifest.length &&
  requirements.all (fun requirement =>
    requirement.priority == requirement.id.expectedPriority)

def traceabilityComplete : Bool :=
  RequirementId.all.all (fun rid => traces.any (fun t => t.requirement == rid)) &&
  traces.length == RequirementId.all.length &&
  traces.all (fun t =>
    t.clauses.all (fun sid => clauseIds.contains sid) &&
    t.evidence.all (fun eid => evidenceIds.contains eid) &&
    !t.evidence.isEmpty) &&
  uniqueStrings evidenceIds &&
  evidence.all (fun e =>
    !e.id.isEmpty && !e.claim.isEmpty && !e.locator.isEmpty &&
    !e.roles.isEmpty && e.roles.eraseDups.length == e.roles.length)

/-- Product constraints are not smuggled into the Jackson-Zave R artifact: each
must instead have at least one implementing S clause. -/
def catalogueLevelsWellFormed : Bool :=
  requirements.any (fun requirement =>
    requirement.level == .problemWorldOutcome) &&
  requirements.any (fun requirement =>
    requirement.level == .productConstraint) &&
  requirements.all (fun requirement =>
    requirement.level != .productConstraint ||
      traces.any (fun trace =>
        trace.requirement == requirement.id && !trace.clauses.isEmpty))

private def candidateValidationEvidenceKind : EvidenceKind -> Bool
  | .fixtureTest
  | .differentialTest
  | .corpusValidation
  | .harnessValidation
  | .humanValidation
  | .buildValidation => true
  | _ => false

private def leanEvidenceKind : EvidenceKind -> Bool
  | .theorem | .decidePin => true
  | _ => false

private def readinessEvidenceRole : EvidenceRole -> Bool
  | .implementationRefinement | .domainValidation | .releaseProcess => true
  | .adequacyArgument | .gapRecord => false

private def evidenceHasReadinessRole (item : Evidence) : Bool :=
  item.roles.any readinessEvidenceRole

private def uniqueEvidenceItem? (id : String) : Option Evidence :=
  match evidence.filter (fun item => item.id == id) with
  | [item] => some item
  | _ => none

/-- Lean-side claims are emitted as proof obligations. A downstream
`LeanEvidenceBinding` must contain an actual proof of its indexed proposition;
this worklist itself never marks a claim satisfied. -/
def leanEvidenceWorklist : List LeanEvidenceObligation :=
  evidence.filterMap (fun item =>
    if item.polarity == .supports && leanEvidenceKind item.kind &&
        evidenceHasReadinessRole item then
      some {
        evidenceId := item.id
        kind := item.kind
        claim := item.claim
        locator := item.locator
      }
    else
      none)

def leanEvidenceWorklistWellFormed : Bool :=
  uniqueStrings (leanEvidenceWorklist.map (·.evidenceId)) &&
  leanEvidenceWorklist.all (fun obligation =>
    leanEvidenceKind obligation.kind && !obligation.evidenceId.isEmpty &&
    !obligation.claim.isEmpty && !obligation.locator.isEmpty &&
    (uniqueEvidenceItem? obligation.evidenceId).any (fun item =>
      item.polarity == .supports && evidenceHasReadinessRole item &&
      item.kind == obligation.kind && item.claim == obligation.claim &&
      item.locator == obligation.locator))

/-- Qualification names the kind of missing evidence; it never asserts that a
claim is true. Fixture, differential, corpus, harness, human, and build results
all remain candidate-bound validation inputs. -/
def evidenceQualification (id : String) : EvidenceQualification :=
  match uniqueEvidenceItem? id with
  | none => .ineligible
  | some item =>
      if item.polarity != .supports || item.kind == .review ||
          !evidenceHasReadinessRole item then
        .ineligible
      else if candidateValidationEvidenceKind item.kind then
        .candidateValidationRequired
      else if leanEvidenceKind item.kind then
        .leanProofRequired
      else
        .ineligible

private def evidencePositiveAndEligible (id : String) : Bool :=
  (uniqueEvidenceItem? id).any (fun item =>
    item.polarity == .supports &&
      (evidenceQualification id == .leanProofRequired ||
        evidenceQualification id == .candidateValidationRequired))

/-- Status/evidence classification used by both fit obligations and traces.
`satisfied` catalogue prose yields a Lean proof obligation, never satisfaction.
Pending requires candidate-bound evidence and permits accompanying Lean proof
obligations. Partial and unsatisfied rows remain blocked. -/
def evidenceSetAssessment
    (status : Satisfaction) (evidenceIds : List String) : FitObligationAssessment :=
  if evidenceIds.isEmpty then
    .blocked
  else
    match status with
    | .satisfied =>
        if evidenceIds.all (fun id =>
            evidenceQualification id == .leanProofRequired) then
          .leanProofRequired
        else
          .blocked
    | .externalValidationPending =>
        if evidenceIds.any (fun id =>
              evidenceQualification id == .candidateValidationRequired) &&
            evidenceIds.all evidencePositiveAndEligible then
          .candidateValidationPending
        else
          .blocked
    | .partiallySatisfied | .unsatisfied => .blocked

def fitObligationAssessment
    (obligation : FitObligation) : FitObligationAssessment :=
  evidenceSetAssessment obligation.status obligation.evidence

def requirementFitAssessment (rid : RequirementId) : FitObligationAssessment :=
  let obligations := fitObligations.filter (fun obligation =>
    obligation.requirement == rid)
  if obligations.isEmpty then
    .blocked
  else if obligations.all (fun obligation =>
      fitObligationAssessment obligation == .leanProofRequired) then
    .leanProofRequired
  else if obligations.all (fun obligation =>
        fitObligationAssessment obligation != .blocked) &&
      obligations.any (fun obligation =>
        fitObligationAssessment obligation == .candidateValidationPending) then
    .candidateValidationPending
  else
    .blocked

private def pendingExternalEvidenceIds : List String :=
  ((fitObligations.filter (fun obligation =>
      fitObligationAssessment obligation == .candidateValidationPending)).flatMap
    (·.evidence)).filter (fun id =>
      evidenceQualification id == .candidateValidationRequired) |>.eraseDups

/-- External observations are emitted only for explicitly pending obligations.
The pure model never consumes an alleged result and therefore cannot turn one
into release readiness. -/
def externalValidationWorklist : List ExternalValidationObligation :=
  pendingExternalEvidenceIds.filterMap (fun id =>
    (uniqueEvidenceItem? id).map (fun item => {
      evidenceId := item.id
      kind := item.kind
      roles := item.roles
      claim := item.claim
      locator := item.locator
    }))

def externalValidationWorklistWellFormed : Bool :=
  uniqueStrings (externalValidationWorklist.map (·.evidenceId)) &&
  externalValidationWorklist.map (·.evidenceId) == pendingExternalEvidenceIds &&
  externalValidationWorklist.all (fun obligation =>
    candidateValidationEvidenceKind obligation.kind &&
    evidenceQualification obligation.evidenceId ==
      .candidateValidationRequired &&
    !obligation.evidenceId.isEmpty && !obligation.roles.isEmpty &&
    !obligation.claim.isEmpty && !obligation.locator.isEmpty)

/-- Explicit implementation-refinement classification. This is false for the
abstract reduction theorem even though that theorem is logically substantive. -/
def evidenceSupportsImplementationRefinement (id : String) : Bool :=
  (evidence.find? (fun item => item.id == id)).any (fun item =>
    item.roles.contains .implementationRefinement)

def fitObligationsWellFormed : Bool :=
  uniqueStrings fitObligationIds &&
  RequirementId.all.all (fun rid =>
    fitObligations.any (fun obligation => obligation.requirement == rid)) &&
  fitObligations.all (fun obligation =>
    !obligation.id.isEmpty && !obligation.statement.isEmpty &&
    !obligation.evidence.isEmpty &&
    obligation.evidence.all (fun eid => evidenceIds.contains eid))

def fitObligationEvidenceStatusesSound : Bool :=
  fitObligations.all (fun obligation =>
    match obligation.status with
    | .satisfied =>
        fitObligationAssessment obligation == .leanProofRequired
    | .externalValidationPending =>
        fitObligationAssessment obligation == .candidateValidationPending
    | .partiallySatisfied | .unsatisfied =>
        fitObligationAssessment obligation == .blocked)

private def uniqueTrace? (rid : RequirementId) : Option Trace :=
  match traces.filter (fun trace => trace.requirement == rid) with
  | [trace] => some trace
  | _ => none

def traceSummariesMatchFitObligations : Bool :=
  traces.all (fun trace =>
    let traceAssessment := evidenceSetAssessment trace.status trace.evidence
    match requirementFitAssessment trace.requirement with
    | .leanProofRequired =>
        trace.status == .satisfied &&
          traceAssessment == .leanProofRequired && trace.gap.isNone
    | .candidateValidationPending =>
        trace.status == .externalValidationPending &&
          traceAssessment == .candidateValidationPending && trace.gap.isNone
    | .blocked =>
        (trace.status == .partiallySatisfied ||
          trace.status == .unsatisfied) && trace.gap.isSome)

/-- Declaration integrity accepts either a Lean proof obligation or a
candidate-validation obligation. It says only that the catalogue has a coherent
evidence path; it does not say the Lean obligations have proof terms. -/
def requirementEvidenceDeclarationWellFormed (rid : RequirementId) : Bool :=
  requirementFitAssessment rid != .blocked &&
    (uniqueTrace? rid).any (fun trace =>
      evidenceSetAssessment trace.status trace.evidence != .blocked)

/-- This module cannot import downstream implementation proofs, so final
catalogue eligibility is deliberately unavailable here. `Proofs` combines a
proof-bearing bundle with candidate-pending declarations. -/
def requirementCatalogueReady (_rid : RequirementId) : Bool :=
  false

/-- Every structural/catalogue integrity predicate is composed here once. This
is an accidental-drift gate, not protection against malicious source edits. -/
def catalogueIntegrityGate : Bool :=
  catalogueComplete &&
  declaredConversionSurfaceWellFormed &&
  catalogueHasFitCriteria &&
  stakeholderGoalCoverage &&
  contextCatalogueWellFormed &&
  domainCatalogueWellFormed &&
  validationPoliciesWellFormed &&
  referenceProblemWellPosed &&
  validationWorklistMatchesDomainAssumptions &&
  specificationInterfaceMetadataWellFormed &&
  traceabilityComplete &&
  catalogueLevelsWellFormed &&
  previewScopeMatchesReference &&
  concreteReductionDesignationsWellFormed &&
  fitObligationsWellFormed &&
  leanEvidenceWorklistWellFormed &&
  fitObligationEvidenceStatusesSound &&
  traceSummariesMatchFitObligations &&
  externalValidationWorklistWellFormed

def previewCatalogueChecksPass : Bool :=
  catalogueIntegrityGate &&
    RequirementId.previewScopeManifest.all requirementCatalogueReady

def stableCatalogueChecksPass : Bool :=
  catalogueIntegrityGate && RequirementId.all.all requirementCatalogueReady

def previewEvidenceDeclarationsComplete : Bool :=
  catalogueIntegrityGate && RequirementId.previewScopeManifest.all
    requirementEvidenceDeclarationWellFormed

def stableEvidenceDeclarationsComplete : Bool :=
  catalogueIntegrityGate && RequirementId.all.all
    requirementEvidenceDeclarationWellFormed

/-- Pure Lean stops at one of these two states. Passing catalogue checks means
that release tooling may evaluate the external worklist; it is not a release
decision. -/
def catalogueReadinessAssessment
    (catalogueReady : Bool) : PureReadinessAssessment :=
  if catalogueReady then
    .externalDecisionRequired
  else
    .catalogueBlocked

def previewReadinessAssessment : PureReadinessAssessment :=
  catalogueReadinessAssessment previewCatalogueChecksPass

def stableReadinessAssessment : PureReadinessAssessment :=
  catalogueReadinessAssessment stableCatalogueChecksPass

private def obligationListDeclarationWellFormed
    (obligations : List FitObligation) : Bool :=
  !obligations.isEmpty && obligations.all (fun obligation =>
    fitObligationAssessment obligation != .blocked)

/-- Release readiness is intentionally fail-closed in the pure model. External
tooling makes a separate decision; no result-ingestion API exists here. -/
private def pureAssessmentEstablishesReleaseReadiness
    (_assessment : PureReadinessAssessment) : Bool :=
  false

private theorem pureAssessmentCannotEstablishReleaseReadiness
    (assessment : PureReadinessAssessment) :
    pureAssessmentEstablishesReleaseReadiness assessment = false := by
  rfl

def previewReady : Bool :=
  pureAssessmentEstablishesReleaseReadiness previewReadinessAssessment

def stableReady : Bool :=
  pureAssessmentEstablishesReleaseReadiness stableReadinessAssessment

theorem pureReadinessFailsClosed :
    previewReady = false /\ stableReady = false := by
  exact ⟨pureAssessmentCannotEstablishReleaseReadiness _,
    pureAssessmentCannotEstablishReleaseReadiness _⟩

/-- Arbitrary source strings and caller truth values are outside the release
decision. They cannot affect either closed readiness value. -/
theorem callerDataCannotEstablishReleaseReadiness
    (_sourceData : List String) (_callerTruthValues : List Bool) :
    previewReady = false /\ stableReady = false :=
  pureReadinessFailsClosed

private def isLowerHexDigit (char : Char) : Bool :=
  ('0' ≤ char && char ≤ '9') || ('a' ≤ char && char ≤ 'f')

private def isFullCommit (value : String) : Bool :=
  value.length == 40 && value.toList.all isLowerHexDigit

private def isArtifactDigest (value : String) : Bool :=
  value.startsWith "sha256:" && value.length == 71 &&
    (value.drop 7).toString.toList.all isLowerHexDigit

/-- A private reconstruction of the removed, unsound caller-attestation shape.
It exists only for adversarial pins and is not accepted by any readiness API. -/
private structure UntrustedExternalRecord where
  evidenceId : String
  candidateRevision : String
  artifactDigest : String
  claim : String
  callerCandidateBound : Bool
  callerDigestVerified : Bool
  callerClaimChecked : Bool
  deriving Repr, DecidableEq

private def expectedEvidenceClaim (id : String) : String :=
  match uniqueEvidenceItem? id with
  | some item => item.claim
  | none => ""

/-- This checks only uniqueness and catalogue shape. In particular, it ignores
the three caller assertions and does not qualify evidence or decide release. -/
private def untrustedRecordHasCatalogueShape
    (candidate : String) (records : List UntrustedExternalRecord)
    (id : String) : Bool :=
  match records.filter (fun record => record.evidenceId == id) with
  | [record] =>
      isFullCommit candidate &&
      record.candidateRevision == candidate &&
      isArtifactDigest record.artifactDigest &&
      (uniqueEvidenceItem? id).any (fun item =>
        evidenceQualification id == .candidateValidationRequired &&
        record.claim == item.claim)
  | _ => false

private def adversarialCandidate : String :=
  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

private def callerTrueRecord : UntrustedExternalRecord := {
  evidenceId := "E-023"
  candidateRevision := adversarialCandidate
  artifactDigest :=
    "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  claim := expectedEvidenceClaim "E-023"
  callerCandidateBound := true
  callerDigestVerified := true
  callerClaimChecked := true
}

private def assessmentFixture
    (status : Satisfaction) (evidenceIds : List String) : FitObligation := {
  id := "F-ADVERSARIAL"
  requirement := .sourceCoverage
  statement := "Adversarial classification fixture"
  evidence := evidenceIds
  status := status
}

def domainValidationWorklist : List DomainAssumption :=
  domainAssumptions.filter (fun d => d.status != .validated)

example : catalogueComplete = true := by native_decide
example : catalogueHasFitCriteria = true := by native_decide
example : contextCatalogueWellFormed = true := by native_decide
example : validationPoliciesWellFormed = true := by native_decide
example : stakeholderGoalCoverage = true := by native_decide
example : domainCatalogueWellFormed = true := by native_decide
example : specificationInterfaceMetadataWellFormed = true := by native_decide
example : referenceProblemWellPosed = true := by native_decide
example : validationWorklistMatchesDomainAssumptions = true := by native_decide
example : traceabilityComplete = true := by native_decide
example : catalogueLevelsWellFormed = true := by native_decide
example : declaredConversionSurfaceWellFormed = true := by native_decide
example : previewScopeMatchesReference = true := by native_decide
example : concretePreviewScope = RequirementId.previewScopeManifest := by
  native_decide
example : concreteReductionDesignationsWellFormed = true := by native_decide
example : ConcreteConversionDomainClause.all.eraseDups.length =
    ConcreteConversionDomainClause.all.length := by native_decide
example : ConcreteConversionSpecificationClause.all.eraseDups.length =
    ConcreteConversionSpecificationClause.all.length := by native_decide
example : ConcreteConversionRequirementClause.all.eraseDups.length =
    ConcreteConversionRequirementClause.all.length := by native_decide
example : ConcreteConversionProductConstraintClause.all.eraseDups.length =
    ConcreteConversionProductConstraintClause.all.length := by native_decide
example : requirements.any (fun requirement =>
    requirement.id == .failureContract &&
    requirement.level == .productConstraint) = true := by native_decide
example : fitObligationsWellFormed = true := by native_decide
example : leanEvidenceWorklistWellFormed = true := by native_decide
example : fitObligationEvidenceStatusesSound = true := by native_decide
example : traceSummariesMatchFitObligations = true := by native_decide
example : externalValidationWorklistWellFormed = true := by native_decide
example : externalValidationWorklist.map (·.evidenceId) =
    ["E-006", "E-037", "E-008", "E-015", "E-033", "E-030", "E-027", "E-031",
      "E-019", "E-029", "E-025", "E-023", "E-034"] := by
  native_decide
example : catalogueIntegrityGate = true := by native_decide
example : requirementFitAssessment .sourceCoverage =
    .candidateValidationPending := by
  native_decide
example : requirementFitAssessment .structuralIntegrity = .leanProofRequired := by
  native_decide
example : requirementFitAssessment .semanticFidelity =
    .candidateValidationPending := by
  native_decide
example : requirementFitAssessment .portableBuild =
    .candidateValidationPending := by
  native_decide
example : requirementFitAssessment .transcriptReadability =
    .candidateValidationPending := by
  native_decide
example : requirementFitAssessment .crossHarnessContinuation =
    .candidateValidationPending := by
  native_decide
example : requirementEvidenceDeclarationWellFormed .portableBuild = true := by
  native_decide
example : requirementEvidenceDeclarationWellFormed .structuralIntegrity = true := by
  native_decide
example : requirementCatalogueReady .portableBuild = false := by native_decide
example : requirementCatalogueReady .structuralIntegrity = false := by native_decide
example :
    catalogueReadinessAssessment
      (catalogueIntegrityGate && requirementCatalogueReady .portableBuild) =
      .catalogueBlocked := by
  native_decide
example : requirementFitAssessment .failureContract = .blocked := by native_decide
example : requirementFitAssessment .semanticAuthority = .blocked := by native_decide
example : requirementFitAssessment .contextIsolation =
    .candidateValidationPending := by
  native_decide
example : requirementFitAssessment .toolLifecycleFidelity =
    .candidateValidationPending := by
  native_decide
example : catalogueReadinessAssessment true = .externalDecisionRequired := by
  native_decide
example :
    obligationListDeclarationWellFormed
      [assessmentFixture .externalValidationPending ["E-002", "E-023"]] =
      true := by
  native_decide
example :
    obligationListDeclarationWellFormed
      [assessmentFixture .partiallySatisfied ["E-023"]] = false := by
  native_decide
example :
    obligationListDeclarationWellFormed
      [assessmentFixture .unsatisfied ["E-023"]] = false := by
  native_decide
example :
    obligationListDeclarationWellFormed
      [assessmentFixture .externalValidationPending ["E-023", "E-FORGED"]] =
      false := by
  native_decide
example :
    obligationListDeclarationWellFormed
      [assessmentFixture .externalValidationPending ["E-023", "E-020"]] =
      false := by
  native_decide
example :
    obligationListDeclarationWellFormed
      [assessmentFixture .externalValidationPending ["E-002"]] = false := by
  native_decide
example :
    obligationListDeclarationWellFormed
      [assessmentFixture .satisfied ["E-023"]] = false := by
  native_decide
example :
    obligationListDeclarationWellFormed
      [assessmentFixture .externalValidationPending ["E-016", "E-023"]] =
      false := by
  native_decide
example : evidenceSupportsImplementationRefinement "E-001" = false := by
  native_decide
example : evidenceSupportsImplementationRefinement "E-002" = true := by
  native_decide
example : evidenceQualification "E-002" = .leanProofRequired := by native_decide
example : evidenceQualification "E-023" = .candidateValidationRequired := by
  native_decide
example : evidenceQualification "E-024" = .candidateValidationRequired := by
  native_decide
example : evidenceQualification "E-037" = .candidateValidationRequired := by
  native_decide
example : (evidence.find? (fun item => item.id == "E-037")).map
    (fun item => item.kind) = some .differentialTest := by
  native_decide
example : evidenceQualification "E-FORGED" = .ineligible := by native_decide
example : evidenceSetAssessment .satisfied ["E-002"] = .leanProofRequired := by
  native_decide
example :
    untrustedRecordHasCatalogueShape adversarialCandidate
      [{ callerTrueRecord with evidenceId := "E-FORGED" }] "E-023" = false := by
  native_decide
example :
    isArtifactDigest callerTrueRecord.artifactDigest = true /\
      untrustedRecordHasCatalogueShape adversarialCandidate [callerTrueRecord]
        "E-023" = true /\
      previewReady = false := by
  native_decide
example :
    untrustedRecordHasCatalogueShape adversarialCandidate
      [callerTrueRecord, callerTrueRecord] "E-023" = false := by
  native_decide
example :
    untrustedRecordHasCatalogueShape adversarialCandidate
      [{ callerTrueRecord with
          candidateRevision := "cccccccccccccccccccccccccccccccccccccccc" }]
      "E-023" = false := by
  native_decide
example :
    untrustedRecordHasCatalogueShape adversarialCandidate
      [{ callerTrueRecord with claim := "a different claim" }] "E-023" = false := by
  native_decide
example :
    callerTrueRecord.callerCandidateBound = true /\
      callerTrueRecord.callerDigestVerified = true /\
      callerTrueRecord.callerClaimChecked = true /\
      previewReady = false /\ stableReady = false := by
  native_decide
example : previewCatalogueChecksPass = false := by native_decide
example : stableCatalogueChecksPass = false := by native_decide
example : previewReadinessAssessment = .catalogueBlocked := by native_decide
example : stableReadinessAssessment = .catalogueBlocked := by native_decide
example : previewReady = false := by native_decide
example : stableReady = false := by native_decide
example : domainValidationWorklist.map (·.id) =
    ["D-001", "D-003", "D-004", "D-005", "D-007", "D-008", "D-009",
      "D-010", "D-011", "D-012"] := by
  native_decide

end AgentConvert.Requirements
