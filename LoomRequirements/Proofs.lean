import LoomRequirements.AgentConvert
import LoomRequirements.ContextIsolation
import Loom.Claims
import LoomConvert.Main

/-!
# Implementation evidence for the agent-convert requirements

Theorems here are universal over their stated premises. `native_decide` examples
are deliberately labeled witnesses: they verify enumerated fixtures and are not
presented as universal proofs of third-party format behavior.
-/

namespace AgentConvert.Requirements

open Loom LoomConvert

/-- The CLI's pure pipeline cannot return output from a structurally invalid IR. -/
theorem runPipelineOkImpliesWellFormed {fromFmt toFmt output : String}
    {t : Transcript} (h : runPipeline fromFmt toFmt t = .ok output) : WellFormed t := by
  unfold WellFormed
  cases hViolations : violations t with
  | nil => rfl
  | cons violation rest =>
      simp [runPipeline, hViolations] at h

theorem runPipelineInvalidRefuses {fromFmt toFmt : String} {t : Transcript}
    (hInvalid : violations t ≠ []) (output : String) :
    runPipeline fromFmt toFmt t ≠ .ok output := by
  intro hOk
  exact hInvalid (runPipelineOkImpliesWellFormed hOk)

/-- The observable implementation refinement for every successful pure run.
It connects the actual pipeline to the machine boundary without assuming the
problem-world conclusions: the IR passed validation, no declared destructive
loss blocker remained, and the selected exporter produced the exact bytes. -/
def SuccessfulRunObservableSpec (toFmt : String) (t : Transcript)
    (output : String) : Prop :=
  WellFormed t /\ exportBlocker? toFmt t = none /\
    exportByFormat toFmt t = .ok output

theorem runPipelineRefinesSuccessfulRunObservableSpec
    {fromFmt toFmt output : String} {t : Transcript}
    (h : runPipeline fromFmt toFmt t = .ok output) :
    SuccessfulRunObservableSpec toFmt t output := by
  have hWellFormed : WellFormed t := runPipelineOkImpliesWellFormed h
  have hViolations : violations t = [] := hWellFormed
  refine ⟨hWellFormed, ?_⟩
  cases hBlocker : exportBlocker? toFmt t with
  | some blocker =>
      simp [runPipeline, hViolations, hBlocker] at h
  | none =>
      exact ⟨rfl, by
        simpa [runPipeline, hViolations, hBlocker] using h⟩

theorem successfulRunObservableSpecRefinesRunPipeline
    {fromFmt toFmt output : String} {t : Transcript}
    (h : SuccessfulRunObservableSpec toFmt t output) :
    runPipeline fromFmt toFmt t = .ok output := by
  rcases h with ⟨hWellFormed, hBlocker, hExport⟩
  have hViolations : violations t = [] := hWellFormed
  simpa [runPipeline, hViolations, hBlocker] using hExport

/-- The pure pipeline succeeds exactly when the observable implementation
contract holds. This is an implementation characterization, not a claim that
the target harness consumed the resulting bytes. -/
theorem runPipelineOkIffSuccessfulRunObservableSpec
    {fromFmt toFmt output : String} {t : Transcript} :
    runPipeline fromFmt toFmt t = .ok output ↔
      SuccessfulRunObservableSpec toFmt t output := by
  constructor
  · exact runPipelineRefinesSuccessfulRunObservableSpec
  · exact successfulRunObservableSpecRefinesRunPipeline

/-- Complete input to the real pure `runPipeline` boundary. `fromFmt` is kept
because it is part of the implementation signature even though the post-import
pipeline intentionally does not inspect it. -/
structure RunPipelineInvocation where
  fromFmt : String
  toFmt : String
  transcript : Transcript

def runPipelineImplementation
    (input : RunPipelineInvocation) : Except String String :=
  runPipeline input.fromFmt input.toFmt input.transcript

def runPipelineGateFailure?
    (input : RunPipelineInvocation) : Option String :=
  match violations input.transcript with
  | [] => none
  | violations =>
      some s!"source imported to a malformed IR ({violations.length} violations) — refusing to export"

/-- The exact machine-local decision boundary implemented by `runPipeline`:
structural gate, blocker decision, then the selected exporter result. -/
def runPipelineConcreteMachineSpec :
    MachinePipelineSpec RunPipelineInvocation String String := {
  gateFailure? := runPipelineGateFailure?
  blocker? := fun input => exportBlocker? input.toFmt input.transcript
  exporter := fun input => exportByFormat input.toFmt input.transcript
}

/-- Actual concrete refinement for the real function. This theorem includes
both success and failure results but only at the pure machine boundary. -/
theorem runPipelineRefinesConcreteMachineSpec :
    ImplementationRefinesMachinePipelineSpec runPipelineImplementation
      runPipelineConcreteMachineSpec := by
  intro input
  cases hViolations : violations input.transcript with
  | nil =>
      cases hBlocker : exportBlocker? input.toFmt input.transcript with
      | none =>
          simp [runPipelineImplementation, runPipelineConcreteMachineSpec,
            runPipelineGateFailure?, MachinePipelineSpec.expectedResult,
            runPipeline, hViolations, hBlocker]
      | some blocker =>
          simp [runPipelineImplementation, runPipelineConcreteMachineSpec,
            runPipelineGateFailure?, MachinePipelineSpec.expectedResult,
            runPipeline, hViolations, hBlocker]
  | cons violation rest =>
      simp [runPipelineImplementation, runPipelineConcreteMachineSpec,
        runPipelineGateFailure?, MachinePipelineSpec.expectedResult,
        runPipeline, hViolations]

theorem runPipelineStructuralGateFailureExact
    {fromFmt toFmt : String} {t : Transcript}
    {violation : Violation} {rest : List Violation}
    (hViolations : violations t = violation :: rest) :
    runPipeline fromFmt toFmt t =
      .error s!"source imported to a malformed IR ({(violation :: rest).length} violations) — refusing to export" := by
  let input : RunPipelineInvocation := {
    fromFmt := fromFmt, toFmt := toFmt, transcript := t
  }
  apply machinePipelineGateFailureExact runPipelineImplementation
    runPipelineConcreteMachineSpec runPipelineRefinesConcreteMachineSpec input
  simp [input, runPipelineConcreteMachineSpec, runPipelineGateFailure?, hViolations]

theorem runPipelineBlockerFailureExact
    {fromFmt toFmt blocker : String} {t : Transcript}
    (hWellFormed : WellFormed t)
    (hBlocker : exportBlocker? toFmt t = some blocker) :
    runPipeline fromFmt toFmt t = .error blocker := by
  have hViolations : violations t = [] := hWellFormed
  let input : RunPipelineInvocation := {
    fromFmt := fromFmt, toFmt := toFmt, transcript := t
  }
  apply machinePipelineBlockerFailureExact runPipelineImplementation
    runPipelineConcreteMachineSpec runPipelineRefinesConcreteMachineSpec input
  · simp [input, runPipelineConcreteMachineSpec, runPipelineGateFailure?,
      hViolations]
  · simpa [input, runPipelineConcreteMachineSpec] using hBlocker

theorem runPipelineExporterResultExact
    {fromFmt toFmt : String} {t : Transcript}
    (hWellFormed : WellFormed t)
    (hBlocker : exportBlocker? toFmt t = none) :
    runPipeline fromFmt toFmt t = exportByFormat toFmt t := by
  have hViolations : violations t = [] := hWellFormed
  let input : RunPipelineInvocation := {
    fromFmt := fromFmt, toFmt := toFmt, transcript := t
  }
  apply machinePipelineExporterResultExact runPipelineImplementation
    runPipelineConcreteMachineSpec runPipelineRefinesConcreteMachineSpec input
  · simp [input, runPipelineConcreteMachineSpec, runPipelineGateFailure?,
      hViolations]
  · simpa [input, runPipelineConcreteMachineSpec] using hBlocker

/-- A concrete result-to-abstract-outcome relation. Success is tied to the exact
exported string and failure to the exact diagnostic string, but cause,
applicability, status, destination snapshots, and semantics still come from the
independent abstract model. -/
def RunPipelineAbstractResultAgrees
    (abstractRun : RunPipelineInvocation -> ConversionRunObservation) : Prop :=
  ∀ input,
    match runPipelineImplementation input with
    | .ok output =>
        ∃ emission,
          (abstractRun input).outcome = .success emission /\
          emission.artifact = output
    | .error diagnostic =>
        ∃ refusal,
          (abstractRun input).outcome = .safeRefusal refusal /\
          refusal.diagnosticText = diagnostic

/-- Explicit remaining full-refinement obligation. The proved narrow machine
refinement above does not supply importer acceptance, independent support and
refusal applicability, semantic output checks, destination-byte observations,
or any D bridge. -/
def RunPipelineFullConversionRefinementObligation
    (abstractRun : RunPipelineInvocation -> ConversionRunObservation)
    (independentModel : RunPipelineInvocation -> ConversionSituation) : Prop :=
  RunPipelineAbstractResultAgrees abstractRun /\
  ImplementationRefinesConversionSpec abstractRun independentModel

/-- E-002 is bound to theorem terms, not to its claim or locator strings. -/
def runPipelineMachineRefinementLeanBinding :
    LeanEvidenceBinding "E-002"
      (ImplementationRefinesMachinePipelineSpec runPipelineImplementation
          runPipelineConcreteMachineSpec /\
        ∀ (fromFmt toFmt output : String) (t : Transcript),
          runPipeline fromFmt toFmt t = .ok output ->
            SuccessfulRunObservableSpec toFmt t output) :=
  ⟨runPipelineRefinesConcreteMachineSpec,
    fun _ _ _ _ h => runPipelineRefinesSuccessfulRunObservableSpec h⟩

/-- Bytes are eligible for the CLI's `emit` branch only on `Except.ok`. This
models the existing control-flow boundary faithfully; it deliberately makes no
claim about deleting a file left by an earlier, unrelated invocation. -/
def outputEligibleForEmission : Except String String → Option String
  | .ok output => some output
  | .error _ => none

theorem pipelineErrorHasNoEmission {result : Except String String} {error : String}
    (h : result = .error error) : outputEligibleForEmission result = none := by
  simp [h, outputEligibleForEmission]

theorem invalidPipelineHasNoEmission {fromFmt toFmt : String} {t : Transcript}
    (hInvalid : violations t ≠ []) :
    outputEligibleForEmission (runPipeline fromFmt toFmt t) = none := by
  cases hRun : runPipeline fromFmt toFmt t with
  | error _ => rfl
  | ok output => exact False.elim ((runPipelineInvalidRefuses hInvalid output) hRun)

theorem blockedPipelineHasNoEmission
    {fromFmt toFmt blocker : String} {t : Transcript}
    (hWellFormed : WellFormed t)
    (hBlocker : exportBlocker? toFmt t = some blocker) :
    outputEligibleForEmission (runPipeline fromFmt toFmt t) = none := by
  have hViolations : violations t = [] := hWellFormed
  simp [runPipeline, hViolations, hBlocker, outputEligibleForEmission]

/-- Every non-Loom single-file target is blocked when non-main threads exist.
The sidecar-aware CLI path is separate and requires an explicit output path. -/
theorem nonMainFlatExportIsBlocked {toFmt : String} {t : Transcript}
    (hTarget : (toFmt == "loom") = false) (hThreads : hasNonMainThreads t = true) :
    (exportBlocker? toFmt t).isSome = true := by
  simp [exportBlocker?, hTarget, hThreads]

private def proofOrigin : Origin :=
  { format := .other "requirements-proof", sourceRef := "LoomRequirements.Proofs" }

private def withOriginExtra (origin : Origin) (key : String) (value : Lean.Json) : Origin :=
  let extras := match origin.extras with
    | some (Lean.Json.obj fields) => Lean.Json.obj (fields.insert key value)
    | _ => Lean.Json.mkObj [(key, value)]
  { origin with extras := some extras }

private def withoutOriginExtra (origin : Origin) (key : String) : Origin :=
  match origin.extras with
  | some (Lean.Json.obj fields) =>
      { origin with extras := some (Lean.Json.obj (fields.erase key)) }
  | _ => origin

private def proofTargetTimestamp : String := "2026-07-20T12:00:00.000Z"

/-- Add only target launch prerequisites. These are conversion options, not
source provenance, and `metadataLosses` deliberately excludes their keys. -/
private def targetReady (target : String) (t : Transcript) : Transcript :=
  let withTimestamp :=
    { t with origin := (withOriginExtra t.origin "target_timestamp"
        (Lean.Json.str proofTargetTimestamp)) }
  match target with
  | "pi" =>
      let targetSessionId := t.env.sessionId.bind (fun value =>
        if value.isEmpty then none else some value) |>.getD
          "00000000-0000-4000-8000-000000000001"
      let targetCwd := t.env.cwd.bind (fun value =>
        if value.isEmpty then none else some value) |>.getD
          "/tmp/agent-convert-proof"
      let targetProvider := t.env.provider.bind (fun value =>
        if value.isEmpty then none else some value) |>.getD "proof-provider"
      let targetModel := t.env.model.bind (fun value =>
        if value.isEmpty then none else some value) |>.getD "proof-model"
      let targetOrigin := withOriginExtra
        (withOriginExtra
          (withOriginExtra
            (withOriginExtra withTimestamp.origin "target_session_id"
              (Lean.Json.str targetSessionId))
            "target_cwd" (Lean.Json.str targetCwd))
          "target_provider" (Lean.Json.str targetProvider))
        "target_model" (Lean.Json.str targetModel)
      let targetOrigin := withOriginExtra targetOrigin "target_harness_version"
        (Lean.Json.str Loom.Ops.piTargetHarnessVersion)
      { withTimestamp with origin := targetOrigin }
  | "claude" =>
      let targetCwd := t.env.cwd.bind (fun value =>
        if value.isEmpty then none else some value) |>.getD
          "/tmp/agent-convert-proof"
      let targetOrigin := withOriginExtra
        (withOriginExtra
          (withOriginExtra withTimestamp.origin "target_cwd"
            (Lean.Json.str targetCwd))
          "target_session_id"
          (Lean.Json.str "00000000-0000-4000-8000-000000000001"))
        "target_harness_version"
        (Lean.Json.str claudeTargetValidationBuild)
      { withTimestamp with origin := targetOrigin }
  | "codex" =>
      let targetSessionId := t.env.sessionId.bind (fun value =>
        if value == "00000000-0000-4000-8000-000000000001" then some value
        else none) |>.getD "00000000-0000-4000-8000-000000000001"
      let targetCwd := t.env.cwd.bind (fun value =>
        if value.isEmpty then none else some value) |>.getD
          "/tmp/agent-convert-proof"
      let targetModel := t.env.model.bind (fun value =>
        if value.isEmpty then none else some value) |>.getD "gpt-5.5"
      let targetProvider := t.env.provider.bind (fun value =>
        if value.isEmpty then none else some value) |>.getD "openai"
      let targetOrigin := withOriginExtra
        (withOriginExtra
          (withOriginExtra
            (withOriginExtra
              (withOriginExtra
                (withOriginExtra
                  (withOriginExtra withTimestamp.origin "target_session_id"
                    (Lean.Json.str targetSessionId))
                  "target_cwd" (Lean.Json.str targetCwd))
                "target_provider" (Lean.Json.str targetProvider))
              "target_model" (Lean.Json.str targetModel))
            "target_harness_version" (Lean.Json.str "0.144.1"))
          "target_cli_version" (Lean.Json.str "0.144.1"))
        "target_model_provider" (Lean.Json.str targetProvider)
      let targetOrigin := withOriginExtra targetOrigin "target_originator"
        (Lean.Json.str "agent-convert")
      let targetControls := Lean.Json.mkObj [
        ("protocol", Lean.Json.str codexTargetControlsProtocol),
        ("approval_policy", Lean.Json.str "on-request"),
        ("sandbox_policy", Lean.Json.mkObj [
          ("type", Lean.Json.str "workspace-write"),
          ("network_access", Lean.Json.bool false),
          ("exclude_tmpdir_env_var", Lean.Json.bool false),
          ("exclude_slash_tmp", Lean.Json.bool false)]),
        ("summary", Lean.Json.str "auto")]
      let targetOrigin := withOriginExtra targetOrigin codexTargetControlsKey
        targetControls
      { withTimestamp with origin := targetOrigin }
  | _ => t

/-- Target launch controls are added by `targetReady`; source `EnvInfo` is never
rewritten to make a fixture convenient. In particular, Claude's explicit target
cwd/session remain distinct from the exact inert source-environment carrier. -/
private def supportedSourceForTarget (_target : String) (t : Transcript) : Transcript := t

private def validCallEntry : Entry :=
  { thread := 0, time := .absent, origin := proofOrigin,
    payload := .assistantMsg [
      .toolCall { raw := "read", canonical := some .read }
        (Lean.Json.mkObj [("path", Lean.Json.str "README.md")]) (some "call-1")] }

private def validResultEntry : Entry :=
  { parent := some 0, thread := 0, time := .absent, origin := proofOrigin,
    payload := .envMsg [
      .toolResult (.resolved 0 0) [.text "contents"] (.native false)] }

private def validReferenceTranscript : Transcript := {
  threads := #[{ kind := .main }]
  entries := #[validCallEntry, validResultEntry]
  activeLeaf := some 1
  origin := proofOrigin
}

private def badBlockReference : Transcript :=
  { validReferenceTranscript with
    entries := #[
      validCallEntry,
      { validResultEntry with
        payload := .envMsg [
          .toolResult (.resolved 0 9) [.text "contents"] (.native false)] }
    ] }

private def referenceToText : Transcript :=
  { validReferenceTranscript with
    entries := #[
      { validCallEntry with payload := .assistantMsg [.text "not a call"] },
      validResultEntry
    ] }

private def crossThreadParent : Transcript :=
  { validReferenceTranscript with
    threads := #[{ kind := .main }, { kind := .detached "fixture" }]
    entries := #[
      { validCallEntry with thread := 0 },
      { validResultEntry with
        thread := 1
        parent := some 0
        payload := .assistantMsg [.text "child"] }
    ] }

private def activeEntryWithChild : Transcript :=
  { validReferenceTranscript with activeLeaf := some 0 }

private def anchorToNonCall : Transcript :=
  { validReferenceTranscript with
    threads := #[{ kind := .main }, { kind := .sidechain (.resolved 1 0) }]
    entries := #[
      validCallEntry,
      { validResultEntry with
        payload := .assistantMsg [.text "not a spawn"] }
    ] }

private def noMainThread : Transcript :=
  { validReferenceTranscript with threads := #[{ kind := .detached "no root" }] }

private def twoMainThreads : Transcript :=
  { validReferenceTranscript with threads := #[{ kind := .main }, { kind := .main }] }

private def parentNotEarlier : Transcript :=
  { validReferenceTranscript with
    entries := #[{ validCallEntry with parent := some 0 }]
    activeLeaf := some 0 }

private def threadOutOfRange : Transcript :=
  { validReferenceTranscript with
    entries := #[{ validCallEntry with thread := 4 }]
    activeLeaf := some 0 }

private def callRefNotEarlier : Transcript :=
  { validReferenceTranscript with
    entries := #[validCallEntry, { validResultEntry with payload := .envMsg [
      .toolResult (.resolved 1 0) [.text "future"] (.native false)] }] }

private def unresolvedCallRef : Transcript :=
  { validReferenceTranscript with
    entries := #[validCallEntry, { validResultEntry with payload := .envMsg [
      .toolResult (.unresolved (some "missing") "fixture orphan")
        [.text "orphan"] .unrecorded] }] }

private def unresolvedSidechainAnchor : Transcript :=
  { validReferenceTranscript with threads := #[
      { kind := .main },
      { kind := .sidechain (.unresolved (some "missing") "fixture detached") }] }

private def sidechainAnchorEntryOutOfRange : Transcript :=
  { validReferenceTranscript with threads := #[
      { kind := .main }, { kind := .sidechain (.resolved 99 0) }] }

private def sidechainAnchorBlockOutOfRange : Transcript :=
  { validReferenceTranscript with threads := #[
      { kind := .main }, { kind := .sidechain (.resolved 0 99) }] }

private def sidechainAnchorNotMain : Transcript :=
  { validReferenceTranscript with
    threads := #[{ kind := .main }, { kind := .detached "worker" },
      { kind := .sidechain (.resolved 0 0) }]
    entries := #[{ validCallEntry with thread := 1 }]
    activeLeaf := some 0 }

private def activeLeafOutOfRange : Transcript :=
  { validReferenceTranscript with activeLeaf := some 99 }

private def compactionKeptOutOfRange : Transcript :=
  { validReferenceTranscript with
    entries := #[{ validCallEntry with
      payload := .compaction "bad" (.knownPrefix 99) none }]
    activeLeaf := some 0 }

private def openCallTranscript : Transcript :=
  { validReferenceTranscript with entries := #[validCallEntry], activeLeaf := some 0 }

private def mediaOnlyTranscript : Transcript :=
  { validReferenceTranscript with
    entries := #[{ validCallEntry with payload := .userMsg [.media "image/png" "asset-1"] }],
    activeLeaf := some 0 }

private def eventOnlyTranscript : Transcript :=
  { validReferenceTranscript with
    entries := #[{ validCallEntry with payload := .event (.permissionMode "plan") }],
    activeLeaf := some 0 }

private def piCompactionTranscript : Transcript :=
  { validReferenceTranscript with
    entries := #[{ validCallEntry with
      payload := .compaction "retained summary" .unknownPrefix (some 42) }],
    activeLeaf := some 0 }

private def codexNativeCompactionSummary : String :=
  "requirements checkpoint"

private def codexNativeCompactionPayload : Lean.Json :=
  Lean.Json.mkObj [
    ("message", Lean.Json.str codexNativeCompactionSummary),
    ("replacement_history", Lean.Json.arr #[
      Lean.Json.mkObj [
        ("type", Lean.Json.str "message"),
        ("role", Lean.Json.str "user"),
        ("content", Lean.Json.arr #[Lean.Json.mkObj [
          ("type", Lean.Json.str "input_text"),
          ("text", Lean.Json.str "retained input")]])],
      Lean.Json.mkObj [
        ("type", Lean.Json.str "compaction"),
        ("id", Lean.Json.str "cmp_requirements_checkpoint"),
        ("encrypted_content", Lean.Json.str "encrypted-checkpoint-signature")]]),
    ("window_number", Lean.Json.num 1),
    ("first_window_id", Lean.Json.str "window-first"),
    ("previous_window_id", Lean.Json.str "window-previous"),
    ("window_id", Lean.Json.str "window-current")]

private def codexMalformedCompactionPayload : Lean.Json :=
  Lean.Json.mkObj [
    ("message", Lean.Json.str codexNativeCompactionSummary),
    ("replacement_history", Lean.Json.arr #[Lean.Json.mkObj [
      ("type", Lean.Json.str "compaction"),
      ("id", Lean.Json.str "cmp_missing_encrypted_signature")]]),
    ("window_number", Lean.Json.num 1),
    ("first_window_id", Lean.Json.str "window-first"),
    ("previous_window_id", Lean.Json.str "window-previous"),
    ("window_id", Lean.Json.str "window-current")]

private def codexCompactionRecord (payload : Lean.Json) : Lean.Json :=
  Lean.Json.mkObj [
    ("timestamp", Lean.Json.str "2023-11-14T22:13:20.123Z"),
    ("type", Lean.Json.str "compacted"),
    ("payload", payload)]

private def codexCompactionTranscriptWithRecord (record : Lean.Json) : Transcript :=
  { validReferenceTranscript with
    entries := #[{ validCallEntry with
      time := .recorded ⟨1700000000123⟩
      payload := .compaction codexNativeCompactionSummary .unknownPrefix none
      origin := {
        format := .codexCli
        sourceRef := "entry0"
        extras := some (Lean.Json.mkObj [
          ("ts", Lean.Json.str "2023-11-14T22:13:20.123Z"),
          ("raw_compaction_record", record)]) } }]
    activeLeaf := some 0 }

private def codexNativeCompactionTranscript : Transcript :=
  codexCompactionTranscriptWithRecord
    (codexCompactionRecord codexNativeCompactionPayload)

private def codexMalformedCompactionTranscript : Transcript :=
  codexCompactionTranscriptWithRecord
    (codexCompactionRecord codexMalformedCompactionPayload)

private def codexHistoricalCompactionTranscript : Transcript :=
  { validReferenceTranscript with
    entries := #[{ validCallEntry with
      time := .recorded ⟨1700000000123⟩
      payload := .compaction "historical checkpoint" (.knownPrefix 0) (some 9)
      origin := { format := .pi, sourceRef := "historical-checkpoint" }
      disposition := .historicalUnverified }]
    activeLeaf := some 0 }

private def previewSessionId : String :=
  "00000000-0000-4000-8000-000000000001"

private def previewClaudeContinuationFixture : String :=
  String.intercalate "\n" [
    "{\"type\":\"user\",\"uuid\":\"00000000-0000-4000-8000-000000000010\",\"parentUuid\":null,\"sessionId\":\"" ++ previewSessionId ++ "\",\"cwd\":\"/tmp/agent-convert-proof\",\"timestamp\":\"2026-07-20T00:00:01.000Z\",\"isSidechain\":false,\"message\":{\"role\":\"user\",\"content\":\"run pwd\"}}",
    "{\"type\":\"assistant\",\"uuid\":\"00000000-0000-4000-8000-000000000011\",\"parentUuid\":\"00000000-0000-4000-8000-000000000010\",\"sessionId\":\"" ++ previewSessionId ++ "\",\"cwd\":\"/tmp/agent-convert-proof\",\"timestamp\":\"2026-07-20T00:00:02.000Z\",\"isSidechain\":false,\"message\":{\"role\":\"assistant\",\"model\":\"preview-model\",\"content\":[{\"type\":\"tool_use\",\"id\":\"tool-preview-1\",\"name\":\"bash\",\"input\":{\"cmd\":\"pwd\"}}]}}",
    "{\"type\":\"user\",\"uuid\":\"00000000-0000-4000-8000-000000000012\",\"parentUuid\":\"00000000-0000-4000-8000-000000000011\",\"sessionId\":\"" ++ previewSessionId ++ "\",\"cwd\":\"/tmp/agent-convert-proof\",\"timestamp\":\"2026-07-20T00:00:03.000Z\",\"isSidechain\":false,\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"tool-preview-1\",\"is_error\":false,\"content\":\"/tmp/agent-convert-proof\"}]}}"
  ]

private def previewCodexContinuationFixture : String :=
  String.intercalate "\n" [
    "{\"type\":\"session_meta\",\"timestamp\":\"2026-07-20T00:00:00.000Z\",\"payload\":{\"id\":\"" ++ previewSessionId ++ "\",\"timestamp\":\"2026-07-20T00:00:00.000Z\",\"cwd\":\"/tmp/agent-convert-proof\",\"cli_version\":\"0.144.1\"}}",
    "{\"type\":\"response_item\",\"timestamp\":\"2026-07-20T00:00:01.000Z\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"run pwd\"}]}}",
    "{\"type\":\"response_item\",\"timestamp\":\"2026-07-20T00:00:02.000Z\",\"payload\":{\"type\":\"function_call\",\"name\":\"exec_command\",\"call_id\":\"call-preview-1\",\"arguments\":\"{\\\"cmd\\\":\\\"pwd\\\"}\"}}",
    "{\"type\":\"response_item\",\"timestamp\":\"2026-07-20T00:00:03.000Z\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"call-preview-1\",\"output\":\"/tmp/agent-convert-proof\"}}"
  ]

/-- Codex rollout records do not encode Loom's active continuation leaf. Test
witnesses provide a reviewed entry count and terminal index explicitly instead
of asking an exporter to guess either value. -/
private def selectKnownActiveLeaf (expectedEntries leaf : Nat) :
    Except String Transcript → Except String Transcript
  | .error error => .error error
  | .ok transcript =>
      if transcript.entries.size == expectedEntries && leaf < expectedEntries then
        .ok { transcript with activeLeaf := some leaf }
      else
        .error s!"active-leaf fixture expected {expectedEntries} entries and leaf {leaf}, got {transcript.entries.size} entries"

private def selectPreviewCodexActiveLeaf : Except String Transcript →
    Except String Transcript :=
  selectKnownActiveLeaf 3 2

private def previewHermesContinuationFixture : String :=
  "{\"session_id\":\"hermes-preview\",\"model\":\"hermes-preview-model\"," ++
    "\"messages\":[{\"role\":\"user\",\"content\":\"run pwd\"}," ++
    "{\"role\":\"assistant\",\"tool_calls\":[{\"id\":\"hermes-call-1\"," ++
    "\"type\":\"function\",\"function\":{\"name\":\"terminal\"," ++
    "\"arguments\":\"{\\\"command\\\":\\\"pwd\\\"}\"}}]}," ++
    "{\"role\":\"tool\",\"tool_call_id\":\"hermes-call-1\"," ++
    "\"name\":\"terminal\",\"content\":\"/tmp/agent-convert-proof\"}]}"

private def previewGaisContinuationFixture : String :=
  "{\"runSettings\":{\"model\":\"gemini-preview\"}," ++
    "\"chunkedPrompt\":{\"chunks\":[" ++
    "{\"role\":\"user\",\"text\":\"continue\"}," ++
    "{\"role\":\"model\",\"parts\":[{\"text\":\"ready\"}]}]}}"

private def codexSignedThinkingTranscript : Transcript :=
  { validReferenceTranscript with
    entries := #[{ validCallEntry with
      time := .recorded ⟨1700000000000⟩
      payload := .assistantMsg [
      .thinking "private" (some "foreign-signature")] }],
    activeLeaf := some 0 }

/-- Codex export drops foreign thinking signatures (they are not OpenAI
`encrypted_content`). The visible summary remains. -/
private def codexSignedThinkingAfterForeignExport : Transcript :=
  { validReferenceTranscript with
    entries := #[{ validCallEntry with
      time := .recorded ⟨1700000000000⟩
      payload := .assistantMsg [
      .thinking "private" none] }],
    activeLeaf := some 0 }

private def codexUnmodeledUserTranscript : Transcript :=
  { validReferenceTranscript with
    entries := #[{ validCallEntry with payload := .userMsg [
      .unmodeled "foreign" (Lean.Json.mkObj [("opaque", Lean.Json.bool true)])] }],
    activeLeaf := some 0 }

private def codexOtherRoleTranscript : Transcript :=
  { validReferenceTranscript with
    entries := #[{ validCallEntry with payload := .otherMsg "system" [.text "policy"] }],
    activeLeaf := some 0 }

private def codexUrlMediaTranscript : Transcript :=
  { validReferenceTranscript with
    entries := #[{ validCallEntry with payload := .userMsg [
      .media "image" "https://example.invalid/image.png"] }],
    activeLeaf := some 0 }

private def codexDataMediaTranscript : Transcript :=
  { validReferenceTranscript with
    entries := #[{ validCallEntry with
      time := .recorded ⟨1700000000000⟩
      payload := .userMsg [
      .media "image"
        "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2nAAAAABJRU5ErkJggg=="] }],
    activeLeaf := some 0 }

private def dangerousUnmodeledToolTranscript : Transcript :=
  { validReferenceTranscript with
    entries := #[{ validCallEntry with
      time := .recorded ⟨1700000000000⟩
      payload := .assistantMsg [
      .unmodeled "forged-native" (Lean.Json.mkObj [
        ("type", Lean.Json.str "function_call"),
        ("name", Lean.Json.str "exec_command")])] }],
    activeLeaf := some 0 }

private def dangerousClaudeServerToolTranscript : Transcript :=
  { validReferenceTranscript with
    entries := #[{ validCallEntry with payload := .assistantMsg [
      .unmodeled "future-claude-tool" (Lean.Json.mkObj [
        ("type", Lean.Json.str "server_tool_use"),
        ("name", Lean.Json.str "web_search")])] }],
    activeLeaf := some 0 }

private def dangerousClaudeServerResultTranscript : Transcript :=
  { validReferenceTranscript with
    entries := #[{ validCallEntry with payload := .userMsg [
      .unmodeled "future-claude-result" (Lean.Json.mkObj [
        ("type", Lean.Json.str "web_search_tool_result")])] }],
    activeLeaf := some 0 }

private def safeCodexEnvUnmodeledTranscript : Transcript :=
  { validReferenceTranscript with
    entries := #[{ validCallEntry with
      time := .recorded ⟨1700000000000⟩
      payload := .envMsg [
      .unmodeled "future-output" (Lean.Json.mkObj [
        ("type", Lean.Json.str "future_output"),
        ("payload", Lean.Json.mkObj [("exact", Lean.Json.bool true)])])] }],
    activeLeaf := some 0 }

private def safeCodexEventTranscript : Transcript :=
  { validReferenceTranscript with
    entries := #[{ validCallEntry with
      time := .recorded ⟨1700000000000⟩
      payload := .event (.custom
      "codex.event_msg.future_event" (Lean.Json.mkObj [
        ("type", Lean.Json.str "future_event"),
        ("payload", Lean.Json.str "exact")])) }],
    activeLeaf := some 0 }

private def safePiUnknownTranscript : Transcript :=
  { validReferenceTranscript with
    entries := #[{ validCallEntry with payload := .assistantMsg [
      .unmodeled "futureBlock" (Lean.Json.mkObj [
        ("type", Lean.Json.str "futureBlock"),
        ("payload", Lean.Json.str "exact")])] }],
    activeLeaf := some 0 }

private def unsafePiRecognizedUnknownTranscript : Transcript :=
  { validReferenceTranscript with
    entries := #[{ validCallEntry with payload := .assistantMsg [
      .unmodeled "text" (Lean.Json.mkObj [
        ("type", Lean.Json.str "text"), ("text", Lean.Json.str "reclassified")])] }],
    activeLeaf := some 0 }

private def inferredPiResultTranscript : Transcript :=
  { validReferenceTranscript with
    entries := #[validCallEntry, { validResultEntry with payload := .envMsg [
      .toolResult (.resolved 0 0) [.text "contents"]
        (.inferred false "source-specific inference")] }] }

private def missingPiToolIdTranscript : Transcript :=
  { validReferenceTranscript with
    entries := #[{ validCallEntry with payload := .assistantMsg [
      .toolCall { raw := "read", canonical := some .read }
        (Lean.Json.mkObj [("path", Lean.Json.str "README.md")]) none] }],
    activeLeaf := some 0 }

private def emptyEnvTranscript : Transcript :=
  { validReferenceTranscript with
    entries := #[{ validCallEntry with payload := .envMsg [] }],
    activeLeaf := some 0 }

private def codexEmptyUserTranscript : Transcript :=
  { validReferenceTranscript with
    entries := #[{ validCallEntry with payload := .userMsg [] }],
    activeLeaf := some 0 }

private def unsafeCursorToolCallTranscript : Transcript :=
  { validReferenceTranscript with
    entries := #[{ validCallEntry with payload := .assistantMsg [
      .toolCall { raw := "read", canonical := some .read }
        (Lean.Json.str "not-an-object") (some "call-1")] }],
    activeLeaf := some 0 }

private def unsafeCursorUnmodeledTranscript : Transcript :=
  { validReferenceTranscript with
    entries := #[{ validCallEntry with payload := .assistantMsg [
      .unmodeled "tool_use" (Lean.Json.mkObj [
        ("type", Lean.Json.str "tool_use"), ("name", Lean.Json.str "read"),
        ("input", Lean.Json.mkObj [])])] }],
    activeLeaf := some 0 }

private def safeCursorUnknownTranscript : Transcript :=
  { validReferenceTranscript with
    entries := #[
      { validCallEntry with payload := .userMsg [
        .unmodeled "future_block" (Lean.Json.mkObj [
          ("type", Lean.Json.str "future_block"),
          ("payload", Lean.Json.str "exact")])] },
      { validResultEntry with payload := .event (.custom
          "cursor_agent.future_control" (Lean.Json.mkObj [
            ("type", Lean.Json.str "future_control"),
            ("payload", Lean.Json.str "exact")])) }
    ], activeLeaf := some 1 }

private def interpolatedTimeTranscript : Transcript :=
  { validReferenceTranscript with
    entries := #[{ validCallEntry with
      time := .interpolated ⟨1700000000000⟩ "session endpoints"
      payload := .userMsg [.text "inferred time"] }],
    activeLeaf := some 0 }

private def absentTimeTranscript : Transcript :=
  { validReferenceTranscript with
    entries := #[{ validCallEntry with
      time := .absent
      payload := .userMsg [.text "absent time"] }]
    activeLeaf := some 0 }

private def sequencedTimeTranscript : Transcript :=
  { validReferenceTranscript with
    entries := #[{ validCallEntry with
      time := .sequenced 7
      payload := .userMsg [.text "sequenced time"] }],
    activeLeaf := some 0 }

private def recordedTimeTranscript : Transcript :=
  { validReferenceTranscript with
    entries := #[
      { validCallEntry with
        time := .recorded ⟨1700000000000⟩
        payload := .userMsg [.text "recorded time"] }
    ],
    activeLeaf := some 0 }

private def foreignIdentityTranscript : Transcript :=
  { validReferenceTranscript with
    entries := #[{ validCallEntry with
      origin := { proofOrigin with rawId := some "foreign-entry-id" }
      payload := .userMsg [.text "identity"] }]
    env := { sessionId := some "foreign-session-id" }
    activeLeaf := some 0
    origin := { proofOrigin with rawId := some "foreign-session-id" } }

private def claudeSourceIdentityTranscript : Transcript :=
  let transcriptOrigin : Origin := {
    format := .claudeCode
    sourceRef := "claude-session"
    rawId := some "source-claude-session" }
  let entryOrigin : Origin := {
    format := .claudeCode
    sourceRef := "claude-line"
    rawId := some "source-claude-entry" }
  { validReferenceTranscript with
    entries := #[{ validCallEntry with
      time := .recorded ⟨1700000000000⟩
      origin := entryOrigin
      payload := .userMsg [.text "continue in Codex"] }]
    env := { sessionId := some previewSessionId }
    activeLeaf := some 0
    origin := transcriptOrigin }

private def duplicateEntryIdentityTranscript : Transcript :=
  { validReferenceTranscript with
    entries := #[
      { validCallEntry with
        origin := { proofOrigin with rawId := some "duplicate-entry-id" }
        payload := .userMsg [.text "first"] },
      { validResultEntry with
        origin := { proofOrigin with rawId := some "duplicate-entry-id" }
        payload := .assistantMsg [.text "second"] }]
    activeLeaf := some 1 }

private def expandedEntryIdentityCollisionTranscript : Transcript :=
  { validReferenceTranscript with
    entries := #[
      { validCallEntry with
        origin := { proofOrigin with rawId := some "result-entry" }
        payload := .envMsg [
          .unmodeled "first" (Lean.Json.str "first"),
          .unmodeled "second" (Lean.Json.str "second")] },
      { validResultEntry with
        origin := { proofOrigin with rawId := some "result-entry#r1" }
        payload := .userMsg [.text "later source identity"] }]
    activeLeaf := some 1 }

private def foreignEnvironmentTranscript : Transcript :=
  { validReferenceTranscript with
    entries := #[{ validCallEntry with payload := .userMsg [.text "environment"] }]
    env := { cwd := some "/source/worktree", instructions := some "source policy" }
    activeLeaf := some 0 }

private def harnessVersionOnlyTranscript : Transcript :=
  { validReferenceTranscript with
    entries := #[{ validCallEntry with payload := .userMsg [.text "version"] }]
    env := { harnessVersion := some "source-harness-1.2.3" }
    activeLeaf := some 0 }

private def codexSupportedSourceEnvironmentTranscript : Transcript :=
  { validReferenceTranscript with
    entries := #[{ validCallEntry with
      time := .recorded ⟨1700000000000⟩
      payload := .userMsg [.text "controls"] }]
    env := {
      cwd := some "/tmp/agent-convert-proof"
      model := some "source-model"
      provider := some "source-provider"
      harnessVersion := some "source-harness"
      instructions := some "source instructions"
      sessionId := some previewSessionId }
    activeLeaf := some 0 }

private def foreignOriginProvenanceTranscript : Transcript :=
  { validReferenceTranscript with
    entries := #[{ validCallEntry with
      origin := { proofOrigin with extras := some (Lean.Json.mkObj [
        ("rawEnvelope", Lean.Json.mkObj [("future", Lean.Json.bool true)])]) }
      payload := .userMsg [.text "provenance"] }]
    activeLeaf := some 0 }

private def archivedSourceTargetConfigurationTranscript : Transcript :=
  let archive := Lean.Json.mkObj [
    ("protocol", Lean.Json.str
      Loom.Ops.sourceTargetConfigurationArchiveProtocol),
    ("prior", Lean.Json.null),
    ("cleared", Lean.Json.mkObj [
      ("target_session_id", Lean.Json.str "stale-session"),
      ("target_model", Lean.Json.str "stale-model"),
      (codexTargetControlsKey, Lean.Json.mkObj [])])]
  { validReferenceTranscript with
    env := { sessionId := some previewSessionId }
    origin := {
      proofOrigin with
      rawId := some "source-session-lineage"
      extras := some (Lean.Json.mkObj [
        (Loom.Ops.sourceTargetConfigurationArchiveKey, archive)]) } }

private def archivedNonObjectOriginExtrasTranscript : Transcript :=
  let archive := Lean.Json.mkObj [
    ("protocol", Lean.Json.str Loom.Ops.sourceOriginExtrasArchiveProtocol),
    ("raw", Lean.Json.arr #[Lean.Json.mkObj [
      ("target_timestamp", Lean.Json.str "stale-nested-timestamp"),
      ("target_session_id", Lean.Json.str "stale-nested-session"),
      (codexTargetControlsKey, Lean.Json.mkObj [])]])]
  { validReferenceTranscript with
    origin := {
      proofOrigin with extras := some (Lean.Json.mkObj [
        (Loom.Ops.sourceOriginExtrasArchiveKey, archive)]) } }

private def unverifiedClaudeCarrierTranscript : Transcript :=
  let carrierOrigin : Origin := {
    format := .claudeCode
    sourceRef := "unverified-claude-carrier"
    extras := some (Lean.Json.mkObj [
      ("claudeCarrierBlocks", Lean.Json.arr #[Lean.Json.num 0]),
      ("claudeCarrierDisposition",
        Lean.Json.str "agent-convert-historical-unverified")]) }
  { validReferenceTranscript with
    entries := #[{ validCallEntry with
      origin := carrierOrigin
      disposition := .historicalUnverified }]
    activeLeaf := some 0 }

private def codexHistoricalCarrierDispositionTranscript : Transcript :=
  let carrierOrigin : Origin := {
    format := .codexCli
    sourceRef := "historical-carrier-entry0"
    extras := some (Lean.Json.mkObj [
      ("codexCarrierOrigin", Lean.Json.str "historical-carrier-entry")]) }
  { validReferenceTranscript with
    entries := #[{ validCallEntry with
      origin := carrierOrigin
      disposition := .historicalUnverified }]
    activeLeaf := some 0 }

private def piCarrierDispositionTranscript : Transcript :=
  let carrierOrigin : Origin := {
    format := .pi
    sourceRef := "pi-carrier-entry"
    extras := some (Lean.Json.mkObj [("piRaw", Lean.Json.mkObj [
      ("type", Lean.Json.str "custom"),
      ("customType", Lean.Json.str "loom.pi.carrier"),
      ("data", Lean.Json.mkObj [
        ("version", Lean.Json.num 1),
        ("kind", Lean.Json.str "assistantMessage")])])]) }
  { validReferenceTranscript with
    entries := #[{ validCallEntry with
      origin := carrierOrigin
      disposition := .historicalUnverified }]
    activeLeaf := some 0 }

private def stripOriginMetadata (t : Transcript) : Transcript :=
  let stripped : Origin := { format := .other "stripped", sourceRef := "" }
  { t with
    origin := stripped
    entries := t.entries.map (fun entry => { entry with origin := stripped }) }

private def strippedHistoricalUserTranscript : Transcript :=
  let stripped := stripOriginMetadata unverifiedClaudeCarrierTranscript
  { stripped with entries := #[{ validCallEntry with
      origin := stripped.origin
      disposition := .historicalUnverified
      payload := .userMsg [.text "historical user payload"] }] }

private def markEntriesNative (t : Transcript) : Transcript :=
  { t with entries := t.entries.map (fun entry => { entry with
      disposition := .native }) }

private def markEntriesHistorical (t : Transcript) : Transcript :=
  { t with entries := t.entries.map (fun entry => { entry with
      disposition := .historicalUnverified }) }

private def foreignToolIdTranscript : Transcript :=
  { validReferenceTranscript with
    entries := #[{ validCallEntry with payload := .assistantMsg [
      .toolCall { raw := "ApplyPatch", canonical := some .applyPatch }
        (Lean.Json.str "*** Begin Patch\n*** End Patch")
        (some "foreign-tool-id")] }]
    activeLeaf := some 0 }

private def emptyToolIdTranscript : Transcript :=
  { foreignToolIdTranscript with
    entries := #[{ validCallEntry with payload := .assistantMsg [
      .toolCall { raw := "ApplyPatch", canonical := some .applyPatch }
        (Lean.Json.str "*** Begin Patch\n*** End Patch") (some "")] }]
    activeLeaf := some 0 }

private def lowercasePatchStringTranscript : Transcript :=
  { foreignToolIdTranscript with
    entries := #[{ validCallEntry with payload := .assistantMsg [
      .toolCall { raw := "applyPatch", canonical := some .applyPatch }
        (Lean.Json.str "*** Begin Patch\n*** End Patch")
        (some "foreign-tool-id")] }]
    activeLeaf := some 0 }

private def duplicateForeignToolIdTranscript : Transcript :=
  { validReferenceTranscript with
    entries := #[{ validCallEntry with payload := .assistantMsg [
      .toolCall { raw := "ReadFile", canonical := some .read }
        (Lean.Json.mkObj [("path", Lean.Json.str "a")]) (some "duplicate-call"),
      .toolCall { raw := "ReadFile", canonical := some .read }
        (Lean.Json.mkObj [("path", Lean.Json.str "b")]) (some "duplicate-call")] }]
    activeLeaf := some 0 }

private def cursorApplyPatchRawRecord (idValue : Lean.Json) : Lean.Json :=
  Lean.Json.mkObj [
    ("role", Lean.Json.str "assistant"),
    ("message", Lean.Json.mkObj [
      ("content", Lean.Json.arr #[Lean.Json.mkObj [
        ("type", Lean.Json.str "tool_use"),
        ("id", idValue),
        ("name", Lean.Json.str "ApplyPatch"),
        ("input", Lean.Json.str "*** Begin Patch\n*** End Patch")]])])]

private def cursorApplyPatchTranscript (idValue : Lean.Json)
    (irId : Option String) : Transcript :=
  { validReferenceTranscript with
    entries := #[{ validCallEntry with
      payload := .assistantMsg [
        .toolCall { raw := "ApplyPatch", canonical := some .applyPatch }
          (Lean.Json.str "*** Begin Patch\n*** End Patch") irId]
      origin := {
        format := .cursorAgent
        sourceRef := "line1"
        rawId := none
        extras := some (Lean.Json.mkObj [
          ("rawRecord", cursorApplyPatchRawRecord idValue)]) } }]
    activeLeaf := some 0
    origin := { format := .cursorAgent, sourceRef := "importCursorAgent" } }

private def disconnectedRootsTranscript : Transcript :=
  { validReferenceTranscript with
    entries := #[
      { validCallEntry with payload := .userMsg [.text "selected root"] },
      { validResultEntry with
        parent := none
        payload := .assistantMsg [.text "later root"] }
    ],
    activeLeaf := some 0 }

private def abandonedAndActiveBranchTranscript : Transcript :=
  { validReferenceTranscript with
    entries := #[
      { validCallEntry with payload := .userMsg [.text "branch root"] },
      { validResultEntry with payload := .assistantMsg [.text "abandoned branch"] },
      { validResultEntry with payload := .assistantMsg [.text "active branch"] }
    ],
    activeLeaf := some 2 }

private def branchUnsafeFormats : List Format :=
  [.claudeCode, .codexCli, .cursorAgent, .cursorIde, .hermes, .googleAiStudio,
   .other "flat-target"]

private def branchUnsafeCliTargets : List String :=
  ["claude", "codex", "cursor-agent", "cursor-ide", "hermes", "gais"]

private def branchSafeCliTargets : List String := ["pi"]

private def continuationEvents? (t : Transcript) : Option (Array Lean.Json) := do
  let projection ← (Lean.Json.parse (continuationProjection t)).toOption
  (projection.getObjVal? "events" >>= Lean.Json.getArr?).toOption

private def withoutDisposition (events : Array Lean.Json) : Array Lean.Json :=
  events.map fun
    | .obj fields => .obj (fields.erase "disposition")
    | value => value

private def jsonObjPairs : Lean.Json → List (String × Lean.Json)
  | .obj fields => fields.toList
  | _ => []

/-- Reduce a tool result's `isError` to its boolean value, discarding whether
that value was recorded or inferred.

Every flat harness target serializes error state as a single boolean: Claude's
`is_error`, and Codex's convention of encoding failure in the output text. None
has a slot for "this state was INFERRED rather than recorded by the harness".
Conversion therefore preserves the error VALUE exactly while normalizing its
provenance.

That normalization is a real loss, and it is reported rather than hidden: it is
recorded in the conversion provenance sidecar, out of band, so the transcript
itself stays native (`LoomOps.Interop`, P2/P4). Refusing the conversion over it,
or demanding `ErrorSignal.native` before emitting a native result, would force
every Codex tool result to prose — Codex has no structured error flag, so its
importer always produces `.inferred`.

The `loom` wire target does carry full provenance and is compared unnormalized. -/
private def withoutErrorProvenance (events : Array Lean.Json) : Array Lean.Json :=
  events.map fun event =>
    match event with
    | .obj _ =>
        Lean.Json.mkObj ((jsonObjPairs event).map (fun (key, value) =>
          if key == "isError" then
            (key, ((value.getObjVal? "value").toOption).getD value)
          else (key, value)))
    | other => other

/-- Pi appends one stamped target-authored model selection after source history.
It is an explicit launch option, not a source conversation event. Remove exactly
that final expected event when comparing source continuation semantics; an
identical source event earlier in the history remains observable. -/
private def withoutPiTargetModelChange
    (prepared : Transcript) (events : Array Lean.Json) : Array Lean.Json :=
  let targetModel := prepared.origin.extras >>= fun extras =>
    (extras.getObjVal? "target_model" >>= Lean.Json.getStr?).toOption
  match events.toList.reverse with
  | [] => events
  | finalEvent :: reversedRest =>
      let generated :=
        (finalEvent.getObjVal? "kind" >>= Lean.Json.getStr?).toOption ==
            some "modelChange" &&
          (finalEvent.getObjVal? "next" >>= Lean.Json.getStr?).toOption ==
            targetModel &&
          (finalEvent.getObjVal? "prev").toOption == some Lean.Json.null &&
          (finalEvent.getObjVal? "disposition" >>= Lean.Json.getStr?).toOption ==
            some "native"
      if generated then reversedRest.reverse.toArray else events

private def restoredContinuationEvents?
    (target : String) (prepared restored : Transcript) : Option (Array Lean.Json) := do
  let events ← continuationEvents? restored
  pure (if target == "pi" then withoutPiTargetModelChange prepared events else events)

private def targetContinuationMatches
    (target : String) (expected prepared restored : Transcript) : Bool :=
  continuationEvents? expected == restoredContinuationEvents? target prepared restored

private def projectionRoundTripsThrough (target : String) (source : Transcript) : Bool :=
  let prepared := targetReady target (supportedSourceForTarget target source)
  match runPipeline "loom" target prepared with
  | .error _ => false
  | .ok exported =>
      match importByFormat target exported with
      | .error _ => false
      | .ok restored => targetContinuationMatches target prepared prepared restored

/-- Like `projectionRoundTripsThrough`, but compares against an explicit expected
continuation (for intentional target policy losses such as dropping foreign
thinking signatures from Codex `encrypted_content`). -/
private def projectionRoundTripsThroughExpected
    (target : String) (source expected : Transcript) : Bool :=
  let prepared := targetReady target (supportedSourceForTarget target source)
  let expectedPrepared := targetReady target (supportedSourceForTarget target expected)
  match runPipeline "loom" target prepared with
  | .error _ => false
  | .ok exported =>
      match importByFormat target exported with
      | .error _ => false
      | .ok restored =>
          targetContinuationMatches target expectedPrepared prepared restored

private def withEntryDispositions?
    (t : Transcript) (dispositions : List EntryDisposition) : Option Transcript :=
  if dispositions.length != t.entries.size then none
  else
    let entries := (t.entries.toList.zip dispositions).map fun (entry, disposition) =>
      { entry with disposition := disposition }
    some { t with entries := entries.toArray }

/-- Some target carriers intentionally turn native source history into inert
historical state. This helper compares the complete content event projection;
callers making state claims pair it with `targetStateRelation` or
`continuationStateProjection`. -/
private def projectionRoundTripsThroughWithDispositions
    (target : String) (source : Transcript)
    (dispositions : List EntryDisposition) : Bool :=
  let prepared := targetReady target (supportedSourceForTarget target source)
  match withEntryDispositions? prepared dispositions with
  | none => false
  | some expected =>
      match runPipeline "loom" target prepared with
      | .error _ => false
      | .ok exported =>
          match importByFormat target exported with
          | .error _ => false
          | .ok restored => targetContinuationMatches target expected prepared restored

private def cursorArchiveRoundTripsThroughWithDispositions
    (source : Transcript) (dispositions : List EntryDisposition) : Bool :=
  let prepared := supportedSourceForTarget "cursor-agent" source
  match withEntryDispositions? prepared dispositions with
  | none => false
  | some expected =>
      match importCursorAgent (exportCursorAgent prepared) with
      | .error _ => false
      | .ok restored =>
          targetContinuationMatches "cursor-agent" expected prepared restored

private def continuationEventsWithoutDisposition?
    (t : Transcript) : Option (Array Lean.Json) := do
  pure (withoutDisposition (← continuationEvents? t))

private def continuationDispositionsFromEvents?
    (events : Array Lean.Json) : Option (Array String) := do
  events.mapM fun event =>
    (event.getObjVal? "disposition" >>= Lean.Json.getStr?).toOption

private def historicalDispositionDoesNotUpgrade
    (source restored : Array Lean.Json) : Bool :=
  match continuationDispositionsFromEvents? source,
      continuationDispositionsFromEvents? restored with
  | some before, some after =>
      before.size == after.size &&
        (before.toList.zip after.toList).all (fun (sourceDisposition, targetDisposition) =>
          (targetDisposition == "native" ||
            targetDisposition == "historicalUnverified") &&
          (sourceDisposition != "historicalUnverified" ||
            targetDisposition == "historicalUnverified"))
  | _, _ => false

private structure StateEntryObservation where
  events : List Lean.Json
  time : Time

private def stateEntryObservations (t : Transcript) : List StateEntryObservation :=
  ((continuationEntryEvents t).toList.zip t.entries.toList).map
    (fun (events, entry) => { events := events.toList, time := entry.time })

private def withoutObservationDisposition
    (observation : StateEntryObservation) : StateEntryObservation :=
  { observation with events :=
      (withoutDisposition observation.events.toArray).toList }

/-- Grouped counterpart of `withoutErrorProvenance`.

The flat comparison in `targetPreservesOrExplicitlyRefuses` already normalizes
error provenance, for the reason its docstring gives: a target whose wire format
has no slot for `recorded`/`inferred`/`unrecorded` re-derives the signal on
import, so demanding provenance equality would forbid native emission outright.
That normalization was never threaded into the GROUPED path, so
`entryPartitionRefines` kept comparing `{"kind":"native","value":false}` against
`{"kind":"inferred","value":false,"heuristic":…}` verbatim and every
claude/codex cell failed on `targetStateRelation` alone.

Only the provenance is normalized; the VALUE still has to match, which is what
makes an error flag that actually flips a `corrupting` loss rather than a
reportable one (`LoomOps.Interop`). Applied for every target except `loom`,
whose wire format does carry provenance and is compared unnormalized. -/
private def withoutObservationErrorProvenance
    (target : String) (observation : StateEntryObservation) :
    StateEntryObservation :=
  if target == "loom" then observation
  else
    { observation with events :=
        (withoutErrorProvenance observation.events.toArray).toList }

/-- Remove exactly Pi's final target-authored model event while retaining the
entry if it also contains source events. This is the grouped counterpart of the
flat content normalization above. -/
private def withoutPiTargetModelObservation
    (prepared : Transcript) (observations : List StateEntryObservation) :
    List StateEntryObservation :=
  match observations.reverse with
  | [] => []
  | final :: reversedRest =>
      let stripped := withoutPiTargetModelChange prepared final.events.toArray
      if stripped.size == final.events.length then observations
      else if stripped.isEmpty then reversedRest.reverse
      else reversedRest.reverse ++ [{ final with events := stripped.toList }]

private def sourceStateObservations
    (target : String) (source : Transcript) : List StateEntryObservation :=
  (stateEntryObservations source).map
    (withoutObservationErrorProvenance target ∘ withoutObservationDisposition)

private def restoredStateObservations
    (target : String) (prepared restored : Transcript) : List StateEntryObservation :=
  let observations := stateEntryObservations restored
  let withoutGenerated := if target == "pi" then
    withoutPiTargetModelObservation prepared observations else observations
  withoutGenerated.map
    (withoutObservationErrorProvenance target ∘ withoutObservationDisposition)

private def listIsPrefix [BEq α] : List α → List α → Bool
  | [], _ => true
  | _ :: _, [] => false
  | expected :: rest, actual :: tail =>
      expected == actual && listIsPrefix rest tail

/-- Consume one or more target entries whose event concatenation is exactly one
source entry. Every fragment must retain the source entry's exact `Time`;
target-specific timestamp synthesis therefore cannot stand in for source time
provenance or create contradictory chronology inside one logical message. -/
private def consumeSourceObservation (sourceTime : Time) :
    List Lean.Json → List StateEntryObservation →
      Option (List StateEntryObservation)
  | [], targets => some targets
  | _ :: _, [] => none
  | remaining, target :: targets =>
      if target.events.isEmpty || target.time != sourceTime ||
          !listIsPrefix target.events remaining then none
      else consumeSourceObservation sourceTime
        (remaining.drop target.events.length) targets
termination_by _remaining targets => targets.length

/-- A target may split one source entry into multiple storage/carrier entries,
but it may not merge adjacent source entries, reorder events, move an event
across a source grouping boundary, or lose the source time for that group. -/
private def entryPartitionRefines :
    List StateEntryObservation → List StateEntryObservation → Bool
  | [], targets => targets.isEmpty
  | source :: sources, targets =>
      match consumeSourceObservation source.time source.events targets with
      | none => false
      | some remaining => entryPartitionRefines sources remaining
termination_by sources _targets => sources.length

private def mainLinearSelected (t : Transcript) : Bool :=
  t.threads.size == 1 &&
    t.threads[0]?.any (fun thread => thread.kind == ThreadKind.main) &&
    t.entries.toList.zipIdx.all (fun (entry, index) =>
      entry.thread == 0 && entry.parent ==
        (if index == 0 then none else some (index - 1))) &&
    t.activeLeaf == (if t.entries.isEmpty then none else some (t.entries.size - 1))

private def sourceEnvironmentRelation
    (format : Format) (target : String) (source restored : Transcript) : Bool :=
  let losses := Loom.Ops.unpreservedEnvironmentFields format source
  let fieldPreserved := fun (name : String)
      (before after : Option String) =>
    before == after || losses.contains name
  let directFields :=
    fieldPreserved "cwd" source.env.cwd restored.env.cwd &&
    fieldPreserved "model" source.env.model restored.env.model &&
    fieldPreserved "provider" source.env.provider restored.env.provider &&
    fieldPreserved "harnessVersion" source.env.harnessVersion
      restored.env.harnessVersion &&
    fieldPreserved "instructions" source.env.instructions
      restored.env.instructions &&
    fieldPreserved "sessionId" source.env.sessionId restored.env.sessionId
  let lossesAreReported := losses.isEmpty ||
    (Loom.Ops.obligations format source).contains (.dropEnvironment losses)
  if target == "pi" then
    piArchivedSourceEnvironment restored == some source.env && losses.isEmpty
  else directFields && lossesAreReported

/-- Cross-format state relation for the finite preview fixtures. Content may be
split into inert carrier/display records, and Pi appends one target-authored
model-selection event. Both sides must remain one selected linear continuation;
target groups must be a split-only refinement of source groups with exact
logical linkage/content and per-group source time; every source environment
field must reappear exactly or have the corresponding computed loss obligation.
Pi's target environment is checked via its reversible `sourceEnvironment`
archive. -/
private def targetStateRelation
    (format : Format) (target : String) (source restored : Transcript) : Bool :=
  mainLinearSelected source && mainLinearSelected restored &&
    source.threads[0]?.map (fun thread => thread.label) ==
      restored.threads[0]?.map (fun thread => thread.label) &&
    entryPartitionRefines (sourceStateObservations target source)
      (restoredStateObservations target source restored) &&
    sourceEnvironmentRelation format target source restored

/-- A required preview direction must produce bytes and re-import with every
tool-aware continuation event intact. Cross-format adapters may conservatively
downgrade native source events to historical state, but may never reactivate a
historical event. Refusal is not success. -/
private def requiredConversionSucceeds
    (fromFmt target : String) (source : Except String Transcript)
    (exactDisposition : Bool := false) : Bool :=
  match source with
  | .error _ => false
  | .ok imported =>
      let prepared := targetReady target imported
      (violations prepared).isEmpty &&
        (exportBlocker? target prepared).isNone &&
        match runPipeline fromFmt target prepared with
        | .error _ => false
        | .ok exported =>
            match importByFormat target exported with
            | .error _ => false
            | .ok restored =>
                let sourceEvents := continuationEvents? prepared
                let restoredEvents := restoredContinuationEvents? target prepared restored
                let targetFormat := (formatByCliName? target).getD
                  (Format.other target)
                (violations restored).isEmpty &&
                  (if target == "loom" then
                    auditProjection prepared == auditProjection restored
                   else targetStateRelation targetFormat target prepared restored) &&
                  (sourceEvents.bind fun source => restoredEvents.map fun targetEvents =>
                    historicalDispositionDoesNotUpgrade source targetEvents &&
                      -- `exactDisposition` cells (same-format, and every
                      -- `*-to-loom`) stay byte-exact: those targets do carry
                      -- error provenance, so normalizing would weaken them.
                      -- Everywhere else this matched its sibling
                      -- `targetPreservesOrExplicitlyRefuses` except for the
                      -- missing `withoutErrorProvenance`, which made this
                      -- strictly the stricter of two checks meant to agree —
                      -- an asymmetry with no stated rationale, and the reason
                      -- claude-to-codex and codex-to-claude failed here while
                      -- passing there.
                      (if exactDisposition then source == targetEvents
                       else if target == "loom" then
                         withoutDisposition source == withoutDisposition targetEvents
                       else
                         withoutErrorProvenance (withoutDisposition source) ==
                           withoutErrorProvenance (withoutDisposition targetEvents))).getD false

private def semanticBlocked (target : String) (source : Transcript) : Bool :=
  (exportBlocker? target
    (targetReady target (supportedSourceForTarget target source))).isSome

/-- Cursor's archival codec is broader than its runtime grammar. Unsupported
native-looking source data must receive the exact named pre-output refusal,
remain typed historical state in the archive, preserve grouped continuation
state, and reach an exact two-hop archival fixed point. -/
private def cursorArchiveOnlyRefusalAndStableRoundTrip
    (source : Transcript) : Bool :=
  let prepared := targetReady "cursor-agent"
    (supportedSourceForTarget "cursor-agent" source)
  let failures := cursorAgentTargetExportPrerequisiteFailures prepared
  failures.contains cursorAgentNativePayloadPreflightError &&
    (match exportCursorAgentTargetChecked prepared with
     | .ok _ => false
     | .error error => error.contains cursorAgentNativePayloadPreflightError) &&
    let first := exportCursorAgent prepared
    first.contains "agent-convert.cursor-agent-entry.v1" &&
      match importCursorAgent first with
      | .error _ => false
      | .ok restored =>
          let expected := markEntriesHistorical prepared
          restored.entries.toList.all (fun entry =>
            entry.disposition == EntryDisposition.historicalUnverified) &&
            targetContinuationMatches "cursor-agent" expected prepared restored &&
            targetStateRelation .cursorAgent "cursor-agent" prepared restored &&
            (cursorAgentTargetExportPrerequisiteFailures restored).contains
              cursorAgentHistoricalTargetPreflightError &&
            (match exportCursorAgentTargetChecked restored with
             | .ok _ => false
             | .error error =>
                 error.contains cursorAgentHistoricalTargetPreflightError) &&
            let second := exportCursorAgent restored
            second == first &&
              match importCursorAgent second with
              | .error _ => false
              | .ok secondRestored =>
                  continuationStateProjection secondRestored ==
                    continuationStateProjection restored

/-- Codex compaction release policy is content-sensitive at the public pipeline
boundary. An exact native 0.144.1 checkpoint succeeds as `compacted`; malformed
native provenance is named and refused before emission; typed historical state
succeeds only through the inert entry carrier. The policy-local predicate is
also cross-pinned against the adapter's authoritative preflight predicate. -/
def codexCompactionPolicyAndDiagnosticsPinned : Bool :=
  let native := targetReady "codex" codexNativeCompactionTranscript
  let malformed := targetReady "codex" codexMalformedCompactionTranscript
  let historical := targetReady "codex" codexHistoricalCompactionTranscript
  let foreignNative := targetReady "codex" {
    validReferenceTranscript with
      entries := #[{ validCallEntry with
        time := .recorded ⟨1700000000123⟩
        payload := .compaction "foreign native summary" .unknownPrefix (some 5)
        origin := { format := .claudeCode, sourceRef := "active0" }
        disposition := .native }]
      activeLeaf := some 0 }
  let predicatesAgree := [native, malformed, historical, foreignNative].all (fun transcript =>
    Loom.Ops.codexTargetCompactionsValid transcript ==
      LoomConvert.codexTargetCompactionsValid transcript)
  let nativeSucceeds :=
    Loom.Ops.codexTargetCompactionsValid native &&
      !(Loom.Ops.obligations .codexCli native).contains .dropCompaction &&
      (exportBlocker? "codex" native).isNone &&
      match runPipeline "loom" "codex" native with
      | .error _ => false
      | .ok exported =>
          exported.contains "\"type\":\"compacted\"" &&
            exported.contains "encrypted-checkpoint-signature" &&
            match importCodexCli exported with
            | .error _ => false
            | .ok restored =>
                restored.entries[0]?.any (fun entry =>
                  entry.disposition == EntryDisposition.native) &&
                  continuationProjection restored == continuationProjection native &&
                  targetStateRelation .codexCli "codex" native restored
  let malformedRefuses :=
    !Loom.Ops.codexTargetCompactionsValid malformed &&
      (Loom.Ops.obligations .codexCli malformed).contains .dropCompaction &&
      Loom.Ops.obligationIsDestructiveFor .codexCli malformed .dropCompaction &&
      (codexTargetExportPrerequisiteFailures malformed).contains
        codexCompactionPreflightError &&
      (match exportBlocker? "codex" malformed with
       | some diagnostic => diagnostic.contains "dropCompaction"
       | none => false) &&
      match runPipeline "loom" "codex" malformed with
      | .error diagnostic => diagnostic.contains "dropCompaction"
      | .ok _ => false
  let historicalSucceeds :=
    Loom.Ops.codexTargetCompactionsValid historical &&
      !(Loom.Ops.obligations .codexCli historical).contains .dropCompaction &&
      (exportBlocker? "codex" historical).isNone &&
      match runPipeline "loom" "codex" historical with
      | .error _ => false
      | .ok exported =>
          !exported.contains "\"type\":\"compacted\"" &&
            exported.contains "agent-convert.codex-entry.v1" &&
            match importCodexCli exported with
            | .error _ => false
            | .ok restored =>
                restored.entries[0]?.any (fun entry =>
                  entry.disposition == EntryDisposition.historicalUnverified) &&
                  continuationProjection restored == continuationProjection historical &&
                  targetStateRelation .codexCli "codex" historical restored
  let foreignNativeSucceeds :=
    Loom.Ops.codexTargetCompactionsValid foreignNative &&
      !(Loom.Ops.obligations .codexCli foreignNative).contains .dropCompaction &&
      (exportBlocker? "codex" foreignNative).isNone &&
      match runPipeline "loom" "codex" foreignNative with
      | .error _ => false
      | .ok exported =>
          !exported.contains "\"type\":\"compacted\"" &&
            exported.contains "agent-convert.codex-entry.v1" &&
            match importCodexCli exported with
            | .error _ => false
            | .ok restored =>
                -- Foreign native compaction is retained as a historical carrier;
                -- disposition upgrades to historicalUnverified on Codex re-import.
                restored.entries[0]?.any (fun entry =>
                  entry.disposition == EntryDisposition.historicalUnverified &&
                    match entry.payload with
                    | .compaction "foreign native summary" .unknownPrefix (some 5) => true
                    | _ => false)
  predicatesAgree && nativeSucceeds && malformedRefuses && historicalSucceeds &&
    foreignNativeSucceeds

def structuralCounterexamplesRejected : Bool :=
  (violations validReferenceTranscript).isEmpty &&
  (violations noMainThread).contains (.mainThreadCount 0) &&
  (violations twoMainThreads).contains (.mainThreadCount 2) &&
  (violations parentNotEarlier).contains (.parentNotEarlier 0 0) &&
  (violations crossThreadParent).contains (.parentThreadMismatch 1 0 1 0) &&
  (violations threadOutOfRange).contains (.threadOutOfRange 0 4) &&
  (violations callRefNotEarlier).contains (.callRefNotEarlier 1 1) &&
  (violations unresolvedCallRef).contains (.unresolvedCallRef 1 "fixture orphan") &&
  (violations badBlockReference).contains (.callRefBlockOutOfRange 1 0 9) &&
  (violations referenceToText).contains (.callRefNotToolCall 1 0 0) &&
  (violations unresolvedSidechainAnchor).contains
    (.unresolvedSidechainAnchor 1 "fixture detached") &&
  (violations sidechainAnchorEntryOutOfRange).contains
    (.sidechainAnchorEntryOutOfRange 1 99) &&
  (violations sidechainAnchorBlockOutOfRange).contains
    (.sidechainAnchorBlockOutOfRange 1 0 99) &&
  (violations anchorToNonCall).contains (.sidechainAnchorNotToolCall 1 1 0) &&
  (violations sidechainAnchorNotMain).contains (.sidechainAnchorNotMain 2 0 1) &&
  (violations activeLeafOutOfRange).contains (.activeLeafOutOfRange 99) &&
  (violations activeEntryWithChild).contains (.activeLeafHasChild 0) &&
  (violations compactionKeptOutOfRange).contains (.compactionKeptOutOfRange 0 99)

def destructiveLossesBlocked : Bool :=
  semanticBlocked "cursor-agent" mediaOnlyTranscript &&
  semanticBlocked "codex" eventOnlyTranscript &&
  semanticBlocked "cursor-agent" eventOnlyTranscript &&
  semanticBlocked "codex" codexUnmodeledUserTranscript &&
  semanticBlocked "codex" codexOtherRoleTranscript &&
  semanticBlocked "codex" codexUrlMediaTranscript &&
  semanticBlocked "cursor-agent" unsafeCursorToolCallTranscript &&
  semanticBlocked "cursor-agent" unsafeCursorUnmodeledTranscript &&
  semanticBlocked "claude" emptyEnvTranscript &&
  semanticBlocked "cursor-agent" emptyEnvTranscript &&
  semanticBlocked "cursor-agent" emptyToolIdTranscript &&
  (match runPipeline "loom" "cursor-agent" mediaOnlyTranscript with
   | .error _ => true
   | .ok _ => false)

/-- The counterpart to `destructiveLossesBlocked`, added 2026-07-27 when four
cursor-agent rows left it.

Those rows — recorded time, source identity, source environment, and a foreign
tool id — asserted a REFUSAL. `Interop.knownLosses` rates the first three
`reportable` and states the rule they were breaking: "every `reportable` row
that today causes a refusal is a bug against `Emission.refused`". a0072e79
removed the refusals, so keeping the old assertions would have pinned the bug.

Deleting them outright would instead have dropped the cells from evidence
entirely, so this pin asserts what they do now, and asserts the part that
matters: each one still EXPORTS, and each loss is still NAMED. The foreign tool
id is the strongest case — it is no longer a loss at all: the call reaches
cursor-agent as a native `tool_use` keeping raw name, canonical identity, and
exact id, so it is required to report nothing. Per-loss disclosure content stays
in `destructiveDiagnosticsAreClassified`. -/
def cursorAgentReportableLossesAreDisclosedNotRefused : Bool :=
  let discloses := fun (source : Transcript) (expected : Loom.Ops.Obligation) =>
    let prepared := targetReady "cursor-agent"
      (supportedSourceForTarget "cursor-agent" source)
    !semanticBlocked "cursor-agent" source &&
      (match runPipeline "loom" "cursor-agent" prepared with
       | .error _ => false
       | .ok _ => true) &&
      (Loom.Ops.obligations .cursorAgent prepared).contains expected
  discloses recordedTimeTranscript .dropRecordedTime &&
  discloses foreignIdentityTranscript .dropSourceIdentity &&
  discloses foreignEnvironmentTranscript (.dropEnvironment ["cwd", "instructions"]) &&
  -- Moved here 2026-07-27 out of `previewRequiredRefusalMatrix`.
  discloses interpolatedTimeTranscript .dropTimeProvenance &&
  (Loom.Ops.metadataLosses .cursorAgent interpolatedTimeTranscript).contains
    .timeProvenance &&
  -- Native, lossless, and therefore silent by right rather than by omission.
  (let prepared := targetReady "cursor-agent"
     (supportedSourceForTarget "cursor-agent" foreignToolIdTranscript)
   !semanticBlocked "cursor-agent" foreignToolIdTranscript &&
     (Loom.Ops.obligations .cursorAgent prepared).isEmpty &&
     (Loom.Ops.metadataLosses .cursorAgent prepared).isEmpty &&
     (match importCursorAgent (exportCursorAgent prepared) with
      | .error _ => false
      | .ok restored =>
          continuationProjection restored == continuationProjection prepared &&
          restored.entries.toList.all (fun entry =>
            entry.disposition == EntryDisposition.native)))

/-- Raw lifecycle discriminators and unsupported native concepts are preserved
when the selected runtime exporter has an inert reversible representation. The
Cursor archive-only row additionally requires a named runtime refusal and an
exact archival round-trip. Named rows keep failures local. -/
def reversibleRepresentationMatrix : List (String × Bool) := [
  ("codex-empty-user", !semanticBlocked "codex" codexEmptyUserTranscript &&
    projectionRoundTripsThroughWithDispositions "codex" codexEmptyUserTranscript
      [.historicalUnverified]),
  ("codex-empty-env", !semanticBlocked "codex" emptyEnvTranscript &&
    projectionRoundTripsThroughWithDispositions "codex" emptyEnvTranscript
      [.historicalUnverified]),
  ("claude-open-call", !semanticBlocked "claude" openCallTranscript &&
    projectionRoundTripsThroughWithDispositions "claude" openCallTranscript
      [.historicalUnverified]),
  ("codex-dangerous-unmodeled-tool",
    !semanticBlocked "codex" dangerousUnmodeledToolTranscript &&
    projectionRoundTripsThroughWithDispositions "codex"
      dangerousUnmodeledToolTranscript [.historicalUnverified]),
  ("codex-safe-env-unmodeled", !semanticBlocked "codex"
    safeCodexEnvUnmodeledTranscript &&
    projectionRoundTripsThroughWithDispositions "codex"
      safeCodexEnvUnmodeledTranscript [.historicalUnverified]),
  ("codex-safe-event", !semanticBlocked "codex" safeCodexEventTranscript &&
    projectionRoundTripsThrough "codex" safeCodexEventTranscript),
  ("claude-server-tool", !semanticBlocked "claude"
    dangerousClaudeServerToolTranscript &&
    projectionRoundTripsThroughWithDispositions "claude"
      dangerousClaudeServerToolTranscript [.historicalUnverified]),
  ("claude-server-result", !semanticBlocked "claude"
    dangerousClaudeServerResultTranscript &&
    projectionRoundTripsThroughWithDispositions "claude"
      dangerousClaudeServerResultTranscript [.historicalUnverified]),
  ("claude-pi-compaction", !semanticBlocked "claude" piCompactionTranscript &&
    projectionRoundTripsThroughWithDispositions "claude" piCompactionTranscript
      [.historicalUnverified]),
  ("pi-safe-unknown", !semanticBlocked "pi" safePiUnknownTranscript &&
    projectionRoundTripsThroughWithDispositions "pi" safePiUnknownTranscript
      [.historicalUnverified]),
  ("cursor-safe-unknown", semanticBlocked "cursor-agent"
    safeCursorUnknownTranscript &&
    cursorArchiveOnlyRefusalAndStableRoundTrip safeCursorUnknownTranscript),
  ("pi-event", !semanticBlocked "pi" eventOnlyTranscript &&
    projectionRoundTripsThroughWithDispositions "pi" eventOnlyTranscript
      [.historicalUnverified]),
  ("claude-event", !semanticBlocked "claude" eventOnlyTranscript &&
    projectionRoundTripsThroughWithDispositions "claude" eventOnlyTranscript
      [.historicalUnverified]),
  ("codex-signed-thinking", !semanticBlocked "codex"
    codexSignedThinkingTranscript &&
    projectionRoundTripsThroughExpected "codex"
      codexSignedThinkingTranscript
      codexSignedThinkingAfterForeignExport),
  ("codex-data-media", !semanticBlocked "codex" codexDataMediaTranscript &&
    projectionRoundTripsThrough "codex" codexDataMediaTranscript),
  ("claude-other-role", !semanticBlocked "claude" codexOtherRoleTranscript &&
    projectionRoundTripsThroughWithDispositions "claude" codexOtherRoleTranscript
      [.historicalUnverified]),
  ("pi-recognized-unknown", !semanticBlocked "pi"
    unsafePiRecognizedUnknownTranscript &&
    projectionRoundTripsThroughWithDispositions "pi"
      unsafePiRecognizedUnknownTranscript [.historicalUnverified]),
  -- `.native` on both, for the reason `piContinuationWitness` gives: the call's
  -- `canonical := some .read` no longer costs it its native block, because Pi
  -- carries that field in the message-level reserved stamp. The row's own
  -- subject is the INFERRED result signal, and that is what makes the pair
  -- reversible here rather than merely representable: Pi writes
  -- `inferred`/`false`/heuristic into the reserved `toolError` stamp and
  -- `piToolErrorSignal` reads it back cross-checked against the native
  -- `isError` bool, so nothing about the error epistemics is approximated.
  ("pi-inferred-result", !semanticBlocked "pi" inferredPiResultTranscript &&
    projectionRoundTripsThroughWithDispositions "pi" inferredPiResultTranscript
      [.native, .native]),
  ("pi-missing-tool-id", !semanticBlocked "pi" missingPiToolIdTranscript &&
    projectionRoundTripsThroughWithDispositions "pi" missingPiToolIdTranscript
      [.historicalUnverified]),
  ("pi-empty-env", !semanticBlocked "pi" emptyEnvTranscript &&
    projectionRoundTripsThroughWithDispositions "pi" emptyEnvTranscript
      [.historicalUnverified])]

def reversibleRepresentationsArePreservedOrRefused : Bool :=
  reversibleRepresentationMatrix.all (fun witness => witness.2)

/-- Each refusal above names the corresponding destructive obligation instead
of relying on a later target-parser failure. -/
def destructiveDiagnosticsAreClassified : Bool :=
  (Loom.Ops.obligations .cursorAgent unsafeCursorToolCallTranscript).contains
      .dropUnmodeled &&
  (Loom.Ops.obligations .codexCli codexUnmodeledUserTranscript).contains
      .dropUnmodeled &&
  (Loom.Ops.obligations .codexCli codexUrlMediaTranscript).contains
      .dropMedia &&
  (Loom.Ops.obligations .cursorAgent recordedTimeTranscript).contains
      .dropRecordedTime &&
  (Loom.Ops.metadataLosses .cursorAgent foreignIdentityTranscript).contains
      .sourceIdentity &&
  (Loom.Ops.obligations .cursorAgent foreignIdentityTranscript).contains
      .dropSourceIdentity &&
  (Loom.Ops.metadataLosses .cursorAgent foreignEnvironmentTranscript).contains
      (.environment ["cwd", "instructions"]) &&
  (Loom.Ops.obligations .cursorAgent foreignEnvironmentTranscript).contains
      (.dropEnvironment ["cwd", "instructions"]) &&
  !(Loom.Ops.metadataLosses .pi unverifiedClaudeCarrierTranscript).contains
      .safetyProvenance &&
  Loom.Ops.obligationIsReportOnlyFor .pi unverifiedClaudeCarrierTranscript
      .dropOriginProvenance &&
  (Loom.Ops.metadataLosses .cursorAgent foreignToolIdTranscript).isEmpty &&
  (Loom.Ops.metadataLosses .cursorAgent emptyToolIdTranscript).contains
      .toolCallIds &&
  (Loom.Ops.obligations .cursorAgent emptyToolIdTranscript).contains
      .dropToolCallIds

/-- Cursor's exact case-sensitive `ApplyPatch` string-input variant is a native
shape. Foreign IDs use the additive `id` carrier, while a native `id:null`
remains null in raw provenance and has no fabricated semantic tool-call ID. -/
def cursorApplyPatchStringPolicyPinned : Bool :=
  let exact := cursorApplyPatchTranscript (Lean.Json.str "patch-id")
    (some "patch-id")
  let nullId := cursorApplyPatchTranscript Lean.Json.null none
  !(Loom.Ops.obligations .cursorAgent exact).contains .dropUnmodeled &&
    (Loom.Ops.metadataLosses .cursorAgent exact).isEmpty &&
    projectionRoundTripsThrough "cursor-agent" exact &&
    (Loom.Ops.metadataLosses .cursorAgent nullId).isEmpty &&
    !(Loom.Ops.obligations .cursorAgent nullId).contains .dropToolCallIds &&
    (Loom.Ops.obligations .cursorAgent nullId).contains .synthesizeEntryIds &&
    projectionRoundTripsThrough "cursor-agent" nullId &&
    (Loom.Ops.obligations .cursorAgent lowercasePatchStringTranscript).contains
      .dropUnmodeled &&
    semanticBlocked "cursor-agent" lowercasePatchStringTranscript &&
    (Loom.Ops.metadataLosses .cursorAgent duplicateForeignToolIdTranscript).isEmpty &&
    (Loom.Ops.obligations .cursorAgent duplicateForeignToolIdTranscript).contains
      .synthesizeEntryIds

/-- Present identity is never mislabeled as synthesis. A target registration
identity can make source spelling loss report-only, but targets without one
still refuse it. -/
def identitySynthesisIsNotReplacement : Bool :=
  let absentIds := targetReady "pi" {
    validReferenceTranscript with
      entries := #[{ validCallEntry with
        origin := { proofOrigin with rawId := none }
        payload := .userMsg [.text "mint an id"] }]
      activeLeaf := some 0 }
  let stablePi := targetReady "pi" foreignIdentityTranscript
  let stableClaude := targetReady "claude"
    (supportedSourceForTarget "claude" foreignIdentityTranscript)
  let duplicatePi := targetReady "pi" duplicateEntryIdentityTranscript
  let duplicateClaude := targetReady "claude" duplicateEntryIdentityTranscript
  let expandedPi := targetReady "pi" expandedEntryIdentityCollisionTranscript
  let claudeCarrierExact :=
    match exportClaudeCodeChecked stableClaude with
    | .error _ => false
    | .ok output =>
        match importClaudeCode output with
        | .error _ => false
        | .ok restored =>
            let identity := restored.entries[0]? >>= fun entry => entry.origin.extras >>=
              fun extras => (extras.getObjVal? "claudeIdentityProvenance").toOption
            let sourceEntryId := identity >>= fun value =>
              (value.getObjVal? "sourceEntryId" >>= Lean.Json.getStr?).toOption
            let sourceSessionId := identity >>= fun value =>
              (value.getObjVal? "sourceSessionId" >>= Lean.Json.getStr?).toOption
            sourceEntryId == some "foreign-entry-id" &&
              sourceSessionId == some "foreign-session-id"
  (Loom.Ops.obligations .pi absentIds).contains .synthesizeEntryIds &&
    !(Loom.Ops.metadataLosses .pi absentIds).contains .sourceIdentity &&
    !(Loom.Ops.obligations .pi stablePi).contains .synthesizeEntryIds &&
    !(Loom.Ops.metadataLosses .pi stablePi).contains .sourceIdentity &&
    !(Loom.Ops.metadataLosses .claudeCode stableClaude).contains .sourceIdentity &&
    (Loom.Ops.obligations .claudeCode stableClaude).contains .synthesizeEntryIds &&
    claudeCarrierExact &&
    (Loom.Ops.metadataLosses .pi duplicatePi).contains .sourceIdentity &&
    (Loom.Ops.obligations .pi duplicatePi).contains .dropSourceIdentity &&
    (Loom.Ops.metadataLosses .pi expandedPi).contains .sourceIdentity &&
    (Loom.Ops.obligations .pi expandedPi).contains .dropSourceIdentity &&
    !(Loom.Ops.metadataLosses .claudeCode duplicateClaude).contains .sourceIdentity &&
    (Loom.Ops.obligations .claudeCode duplicateClaude).contains
      .synthesizeEntryIds &&
    (Loom.Ops.metadataLosses .codexCli
      (targetReady "codex" foreignIdentityTranscript)).contains .sourceIdentity &&
    (Loom.Ops.metadataLosses .cursorAgent foreignIdentityTranscript).contains
      .sourceIdentity

/-- The advertised Claude-to-Codex continuation registers an explicit Codex
session. Source UUID spelling/lineage remains an observable report, while the
separate topology and tool-linkage obligations retain their own hard gates. -/
def claudeToCodexIdentityLossIsReportOnly : Bool :=
  let prepared := targetReady "codex" claudeSourceIdentityTranscript
  let all := Loom.Ops.obligations .codexCli prepared
  (Loom.Ops.metadataLosses .codexCli prepared).contains .sourceIdentity &&
    all.contains .dropSourceIdentity &&
    Loom.Ops.obligationIsReportOnlyFor .codexCli prepared .dropSourceIdentity &&
    !Loom.Ops.obligationIsDestructiveFor .codexCli prepared .dropSourceIdentity &&
    (all.filter (Loom.Ops.obligationIsDestructiveFor .codexCli prepared)).isEmpty &&
    (exportBlocker? "codex" prepared).isNone &&
    match runPipeline "loom" "codex" prepared with
    | .ok _ => true
    | .error _ => false

/-- Environment preservation is field-specific and executable. Pi's complete
target bundle archives all source `EnvInfo` separately from launch controls.
Claude and Codex likewise use exact inert source-environment carriers on
retargeted exports; none of their physical target controls become source facts. -/
def environmentLossPolicyPinned : Bool :=
  let pi := targetReady "pi" foreignEnvironmentTranscript
  let piWrongVersionOrigin := withOriginExtra pi.origin
    "target_harness_version" (Lean.Json.str "0.73.0")
  let piWrongVersion := { pi with origin := piWrongVersionOrigin }
  let piMissingVersionOrigin := withoutOriginExtra pi.origin
    "target_harness_version"
  let piMissingVersion := { pi with origin := piMissingVersionOrigin }
  let claude := targetReady "claude" foreignEnvironmentTranscript
  let codex := targetReady "codex" foreignEnvironmentTranscript
  Loom.Ops.piTargetHarnessVersion == LoomConvert.piTargetVersion &&
    Loom.Ops.claudeTargetHarnessVersion ==
      LoomConvert.claudeTargetValidationBuild &&
    Loom.Ops.unpreservedEnvironmentFields .cursorAgent
      foreignEnvironmentTranscript == ["cwd", "instructions"] &&
    Loom.Ops.unpreservedEnvironmentFields .pi pi == [] &&
    piTargetPreservesSourceEnvironment pi &&
    (match exportPiChecked pi with
     | .ok output => output.contains
         "\"targetHarnessVersion\":\"0.74.0\""
     | .error _ => false) &&
    Loom.Ops.unpreservedEnvironmentFields .pi piWrongVersion ==
      ["cwd", "instructions"] &&
    (match piExportPreflight piWrongVersion with
     | .error error => error.contains
         "origin.extras.target_harness_version must be 0.74.0"
     | .ok _ => false) &&
    Loom.Ops.unpreservedEnvironmentFields .pi piMissingVersion ==
      ["cwd", "instructions"] &&
    (match piExportPreflight piMissingVersion with
     | .error error => error.contains
         "Pi target requires explicit origin.extras.target_harness_version"
     | .ok _ => false) &&
    Loom.Ops.unpreservedEnvironmentFields .claudeCode claude == [] &&
    (Loom.Ops.unpreservedEnvironmentFields .codexCli codex).isEmpty &&
    !(Loom.Ops.obligations .pi pi).any (fun
      | .dropEnvironment _ => true
      | _ => false) &&
    !(Loom.Ops.obligations .claudeCode claude).any (fun
      | .dropEnvironment _ => true
      | _ => false) &&
    !(Loom.Ops.obligations .codexCli codex).any (fun
      | .dropEnvironment _ => true
      | _ => false)

/-- Claude's retargeted path round-trips all six source environment fields while
the physical Claude cwd/session remain separate target facts. -/
def claudeSourceEnvironmentCarrierPreservesAllFields : Bool :=
  let source := codexSupportedSourceEnvironmentTranscript
  let base := targetReady "claude" source
  let targetOrigin := withOriginExtra
    (withOriginExtra base.origin "target_cwd"
      (Lean.Json.str "/tmp/distinct-claude-target"))
    "target_session_id"
      (Lean.Json.str "00000000-0000-4000-8000-000000000002")
  let prepared := { base with origin := targetOrigin }
  (Loom.Ops.unpreservedEnvironmentFields .claudeCode prepared).isEmpty &&
    !(Loom.Ops.obligations .claudeCode prepared).any (fun
      | .dropEnvironment _ => true
      | _ => false) &&
    (exportBlocker? "claude" prepared).isNone &&
    match runPipeline "loom" "claude" prepared with
    | .error _ => false
    | .ok exported => match importClaudeCode exported with
      | .error _ => false
      | .ok restored =>
          restored.env == source.env &&
            restored.origin.extras.any (fun extras =>
              (extras.getObjVal? "target_cwd" >>= Lean.Json.getStr?).toOption ==
                  some "/tmp/distinct-claude-target" &&
                (extras.getObjVal? "target_session_id" >>=
                  Lean.Json.getStr?).toOption ==
                    some "00000000-0000-4000-8000-000000000002")

/-- Launch controls and source state are independent dimensions. Fresh Codex
exports preserve source `EnvInfo` in an inert exact archive, so valid target
cwd/model/provider/session/version values may differ without becoming source
facts. Malformed active controls are still refused by target preflight. Pi uses
its own separate checked source-environment archive. -/
def targetControlsDoNotMasqueradeAsSourceEnvironment : Bool :=
  let source := codexSupportedSourceEnvironmentTranscript
  let supported := targetReady "codex" source
  let differentOrigin := withOriginExtra
    (withOriginExtra
      (withOriginExtra
        (withOriginExtra supported.origin "target_cwd"
          (Lean.Json.str "/tmp/distinct-codex-target"))
        "target_model" (Lean.Json.str "target-model"))
      "target_provider" (Lean.Json.str "openai"))
    "target_session_id"
      (Lean.Json.str "00000000-0000-4000-8000-000000000002")
  let different := { supported with origin := differentOrigin }
  let malformedOrigin := withOriginExtra different.origin
    codexTargetControlsKey (Lean.Json.mkObj [])
  let malformedControls := { different with origin := malformedOrigin }
  let piBase := targetReady "pi" codexSupportedSourceEnvironmentTranscript
  let piDifferent := { piBase with origin := (withOriginExtra piBase.origin
    "target_model" (Lean.Json.str "different-pi-target-model")) }
  (Loom.Ops.unpreservedEnvironmentFields .codexCli supported).isEmpty &&
    (exportBlocker? "codex" supported).isNone &&
    (Loom.Ops.unpreservedEnvironmentFields .codexCli different).isEmpty &&
    !(Loom.Ops.obligations .codexCli different).any (fun
      | .dropEnvironment _ => true
      | _ => false) &&
    (codexTargetExportPrerequisiteFailures different).isEmpty &&
    (exportBlocker? "codex" different).isNone &&
    (codexTargetExportPrerequisiteFailures malformedControls).contains
      "origin.extras.target_codex_controls must be an exact agent-convert.codex-target-controls.v1 object" &&
    (exportBlocker? "codex" malformedControls).isSome &&
    Loom.Ops.unpreservedEnvironmentFields .pi piDifferent == [] &&
    piTargetPreservesSourceEnvironment piDifferent &&
    match runPipeline "loom" "codex" different with
    | .error _ => false
    | .ok exported => match importCodexCli exported with
      | .error _ => false
      | .ok restored => restored.env == source.env

/-- The reviewed Claude control fixture can start a fresh Codex 0.144.1
continuation with a distinct target cwd/session/model. Claude's source `EnvInfo`
and archived controls return from Codex's inert source archive; current target
facts remain separate top-level extras. -/
def codexSourceEnvironmentCarrierPreservesClaudeControlFixture : Bool :=
  match importClaudeCode claudeControlImportFixture with
  | .error _ => false
  | .ok source =>
      let base := targetReady "codex" source
      let preparedOrigin := withOriginExtra
        (withOriginExtra
          (withOriginExtra base.origin "target_cwd"
            (Lean.Json.str "/tmp/claude-control-codex-target"))
          "target_model" (Lean.Json.str "gpt-5.5"))
        "target_session_id"
          (Lean.Json.str "00000000-0000-4000-8000-000000000003")
      let prepared := { base with origin := preparedOrigin }
      let sourceControls := source.origin.extras >>= fun extras =>
        (extras.getObjVal? "raw_control_messages" >>= Lean.Json.getArr?).toOption
      let all := Loom.Ops.obligations .codexCli prepared
      LoomConvert.codexGeneratedDefaultsAndEnvironmentTwinAreSafe &&
        source.env.cwd == some "/w" &&
        source.env.sessionId != some
          "00000000-0000-4000-8000-000000000003" &&
        (Loom.Ops.unpreservedEnvironmentFields .codexCli prepared).isEmpty &&
        !all.any (fun | .dropEnvironment _ => true | _ => false) &&
        (all.filter
          (Loom.Ops.obligationIsDestructiveFor .codexCli prepared)).isEmpty &&
        (codexTargetExportPrerequisiteFailures prepared).isEmpty &&
        (exportBlocker? "codex" prepared).isNone &&
        match runPipeline "claude" "codex" prepared with
        | .error _ => false
        | .ok exported => match importCodexCli exported with
          | .error _ => false
          | .ok restored =>
              restored.env == source.env &&
                targetContinuationMatches "codex" prepared prepared restored &&
                targetStateRelation .codexCli "codex" prepared restored &&
                restored.origin.extras.any (fun extras =>
                  (extras.getObjVal? "target_cwd" >>= Lean.Json.getStr?).toOption ==
                      some "/tmp/claude-control-codex-target" &&
                    (extras.getObjVal? "target_session_id" >>=
                      Lean.Json.getStr?).toOption ==
                        some "00000000-0000-4000-8000-000000000003" &&
                    ((extras.getObjVal? "raw_control_messages" >>=
                      Lean.Json.getArr?).toOption == sourceControls))

/-- Main's scrubbed target configuration is source provenance, never authority
for the next launch. Archive-only Codex input lacks every required active target
fact and keeps source-ID loss destructive. Fresh top-level invocation controls
make the route executable while the archive remains an explicit report-only
provenance degradation. Cursor's own fresh control key is not misclassified as
source provenance. -/
def sourceTargetConfigurationArchivePolicyPinned : Bool :=
  let archived := archivedSourceTargetConfigurationTranscript
  let fresh := targetReady "codex" archived
  let nonObjectArchived := archivedNonObjectOriginExtrasTranscript
  let freshNonObject := targetReady "codex" nonObjectArchived
  let cursorControlsOrigin := withOriginExtra validReferenceTranscript.origin
    "target_cursor_agent_controls" (Lean.Json.mkObj [
      ("protocol", Lean.Json.str
        "agent-convert.cursor-agent-target-controls.v1"),
      ("permission_mode", Lean.Json.str "default")])
  let cursorControlsOnly := {
    validReferenceTranscript with origin := cursorControlsOrigin }
  let archivedObligations := Loom.Ops.obligations .codexCli archived
  let freshObligations := Loom.Ops.obligations .codexCli fresh
  let nonObjectRuns := match runPipeline "loom" "codex" freshNonObject with
    | .ok _ => true
    | .error _ => false
  Loom.Ops.sourceTargetConfigurationArchiveStamped archived.origin &&
    Loom.Ops.sourceTargetConfigurationArchiveStamped fresh.origin &&
    Loom.Ops.sourceOriginExtrasArchiveStamped nonObjectArchived.origin &&
    Loom.Ops.sourceOriginExtrasArchiveStamped freshNonObject.origin &&
    (Loom.Ops.metadataLosses .codexCli archived).contains .originProvenance &&
    archivedObligations.contains .dropOriginProvenance &&
    Loom.Ops.obligationIsReportOnlyFor .codexCli archived
      .dropOriginProvenance &&
    archivedObligations.contains .dropSourceIdentity &&
    Loom.Ops.obligationIsDestructiveFor .codexCli archived
      .dropSourceIdentity &&
    Loom.Ops.unpreservedEnvironmentFields .pi archived == ["sessionId"] &&
    (codexTargetExportPrerequisiteFailures archived).contains
      "Codex target requires explicit origin.extras.target_session_id" &&
    (codexTargetExportPrerequisiteFailures archived).contains
      "Codex target requires explicit origin.extras.target_harness_version 0.144.1" &&
    (codexTargetExportPrerequisiteFailures archived).contains
      "Codex target requires explicit origin.extras.target_codex_controls" &&
    (exportBlocker? "codex" archived).isSome &&
    (codexTargetExportPrerequisiteFailures fresh).isEmpty &&
    (Loom.Ops.metadataLosses .codexCli fresh).contains .originProvenance &&
    freshObligations.contains .dropSourceIdentity &&
    Loom.Ops.obligationIsReportOnlyFor .codexCli fresh .dropSourceIdentity &&
    (freshObligations.filter
      (Loom.Ops.obligationIsDestructiveFor .codexCli fresh)).isEmpty &&
    (exportBlocker? "codex" fresh).isNone &&
    (Loom.Ops.metadataLosses .codexCli nonObjectArchived).contains
      .originProvenance &&
    Loom.Ops.obligationIsReportOnlyFor .codexCli nonObjectArchived
      .dropOriginProvenance &&
    (codexTargetExportPrerequisiteFailures nonObjectArchived).contains
      "Codex target requires explicit origin.extras.target_timestamp" &&
    (codexTargetExportPrerequisiteFailures nonObjectArchived).contains
      "Codex target requires explicit origin.extras.target_session_id" &&
    (codexTargetExportPrerequisiteFailures freshNonObject).isEmpty &&
    (Loom.Ops.metadataLosses .codexCli freshNonObject).contains
      .originProvenance &&
    (exportBlocker? "codex" freshNonObject).isNone &&
    nonObjectRuns &&
    !(Loom.Ops.metadataLosses .cursorAgent cursorControlsOnly).contains
      .originProvenance &&
    match runPipeline "loom" "codex" fresh with
    | .ok _ => true
    | .error _ => false

/-- Target option keys are not mistaken for source provenance. Generic raw
vendor records remain report-only degradations; a source harness version alone
is historical rather than executable target state. -/
def originProvenancePolicyPinned : Bool :=
  [(.pi, "pi"), (.claudeCode, "claude"), (.codexCli, "codex"),
    (.cursorAgent, "cursor-agent")].all (fun (format, target) =>
      let prepared := targetReady target foreignOriginProvenanceTranscript
      (Loom.Ops.metadataLosses format prepared).contains .originProvenance &&
        (Loom.Ops.obligations format prepared).contains .dropOriginProvenance &&
        Loom.Ops.obligationIsReportOnlyFor format prepared
          .dropOriginProvenance) &&
    !(Loom.Ops.metadataLosses .codexCli
      (targetReady "codex" validReferenceTranscript)).contains
        .originProvenance &&
    Loom.Ops.obligationIsReportOnlyFor .cursorAgent harnessVersionOnlyTranscript
      (.dropEnvironment ["harnessVersion"])

/-- A target's exact inert carrier preserves continuation semantics and typed
historical state for two export/import hops even when format-specific origin
metadata has been stripped. -/
private def typedHistoricalTargetRoundTrips
    (format : Format) (target marker : String) : Bool :=
  let source := if target == "codex" then
      { strippedHistoricalUserTranscript with entries :=
          strippedHistoricalUserTranscript.entries.map (fun entry =>
            { entry with time := .recorded ⟨1700000000000⟩ }) }
    else strippedHistoricalUserTranscript
  let prepared := targetReady target (supportedSourceForTarget target source)
  let expectedPayload := prepared.entries[0]?.map (fun entry =>
    payloadToWireJson entry.payload)
  let preservesTypedPayload := fun (restored : Transcript) =>
    restored.entries.size == (if target == "pi" then 2 else 1) &&
      restored.entries[0]?.map (fun entry => entry.disposition) ==
        some EntryDisposition.historicalUnverified &&
      restored.entries[0]?.map (fun entry =>
        payloadToWireJson entry.payload) == expectedPayload
  Loom.Ops.preservesHistoricalDisposition format &&
    !(Loom.Ops.metadataLosses format prepared).contains .safetyProvenance &&
    !(Loom.Ops.metadataLosses format prepared).contains .originProvenance &&
    (Loom.Ops.obligations format prepared).all (fun obligation =>
      !Loom.Ops.obligationIsDestructiveFor format prepared obligation) &&
    match runPipeline "loom" target prepared with
    | .error _ => false
    | .ok exported =>
        exported.contains marker &&
          match importByFormat target exported with
          | .error _ => false
          | .ok restored =>
              preservesTypedPayload restored &&
                targetContinuationMatches target prepared prepared restored &&
                targetStateRelation format target prepared restored &&
                let secondPrepared := targetReady target restored
                (Loom.Ops.obligations format secondPrepared).all (fun obligation =>
                  !Loom.Ops.obligationIsDestructiveFor format secondPrepared obligation) &&
                  match runPipeline target target secondPrepared with
                  | .error _ => false
                  | .ok secondExported =>
                      secondExported.contains marker &&
                        match importByFormat target secondExported with
                        | .error _ => false
                        | .ok secondRestored =>
                            preservesTypedPayload secondRestored &&
                              continuationStateProjection secondRestored ==
                                continuationStateProjection restored

/-- Cursor's additive carrier is an archive format, not a runtime grammar.
Historical state must remain inert and stable for two archival hops while the
checked target exporter refuses it before rendering any runtime artifact. -/
private def typedHistoricalCursorArchiveRoundTrips : Bool :=
  let source := strippedHistoricalUserTranscript
  let expectedPayload := source.entries[0]?.map (fun entry =>
    payloadToWireJson entry.payload)
  let preservesTypedPayload := fun (restored : Transcript) =>
    restored.entries.size == 1 &&
      restored.entries[0]?.map (fun entry => entry.disposition) ==
        some EntryDisposition.historicalUnverified &&
      restored.entries[0]?.map (fun entry => payloadToWireJson entry.payload) ==
        expectedPayload
  let failures := cursorAgentTargetExportPrerequisiteFailures source
  failures.contains cursorAgentHistoricalTargetPreflightError &&
    (match exportCursorAgentTargetChecked source with
     | .ok _ => false
     | .error error => error.contains cursorAgentHistoricalTargetPreflightError) &&
    !(Loom.Ops.metadataLosses .cursorAgent source).contains .safetyProvenance &&
    !(Loom.Ops.metadataLosses .cursorAgent source).contains .originProvenance &&
    let first := exportCursorAgent source
    first.contains "agent-convert.cursor-agent-entry.v1" &&
      match importCursorAgent first with
      | .error _ => false
      | .ok restored =>
          preservesTypedPayload restored &&
            targetContinuationMatches "cursor-agent" source source restored &&
            targetStateRelation .cursorAgent "cursor-agent" source restored &&
            let second := exportCursorAgent restored
            second == first &&
              match importCursorAgent second with
              | .error _ => false
              | .ok secondRestored =>
                  preservesTypedPayload secondRestored &&
                    continuationStateProjection secondRestored ==
                      continuationStateProjection restored

def safetyProvenancePolicyPinned : Bool :=
  let historical := [unverifiedClaudeCarrierTranscript,
    codexHistoricalCarrierDispositionTranscript, piCarrierDispositionTranscript]
  let targets : List (Format × String × String) := [
    (.pi, "pi", "historicalPayload"),
    (.claudeCode, "claude", "agent_convert_inert"),
    (.codexCli, "codex", "agent-convert.codex-entry.v1")]
  targets.all (fun (format, target, marker) =>
      typedHistoricalTargetRoundTrips format target marker) &&
    typedHistoricalCursorArchiveRoundTrips &&
    historical.all (fun transcript =>
      let formats : List Format :=
        targets.map (fun (format, _, _) => format) ++ [Format.cursorAgent]
      formats.all (fun format =>
        Loom.Ops.preservesHistoricalDisposition format &&
          !(Loom.Ops.metadataLosses format transcript).contains
            .safetyProvenance &&
          Loom.Ops.obligationIsReportOnlyFor format transcript
            .dropOriginProvenance))

/-- Trust is controlled only by `Entry.disposition`. Removing every optional
origin field leaves historical state for each preserving target; conversely,
legacy carrier lookalikes remain native and raw-origin loss stays report-only. -/
def typedDispositionAuthorityPinned : Bool :=
  let stripped := stripOriginMetadata unverifiedClaudeCarrierTranscript
  let lookalikes := [
    markEntriesNative unverifiedClaudeCarrierTranscript,
    markEntriesNative codexHistoricalCarrierDispositionTranscript,
    markEntriesNative piCarrierDispositionTranscript]
  let targets : List Format := [.pi, .claudeCode, .codexCli, .cursorAgent]
  stripped.entries.toList.all (fun entry =>
      entry.disposition == EntryDisposition.historicalUnverified) &&
    targets.all (fun target =>
      !(Loom.Ops.metadataLosses target stripped).contains .safetyProvenance) &&
    !(Loom.Ops.metadataLosses .cursorAgent stripped).contains .originProvenance &&
    lookalikes.all (fun transcript =>
      transcript.entries.toList.all (fun entry =>
          entry.disposition == EntryDisposition.native) &&
        targets.all (fun target =>
          !(Loom.Ops.metadataLosses target transcript).contains
            .safetyProvenance) &&
        (Loom.Ops.metadataLosses .cursorAgent transcript).contains
          .originProvenance &&
        (Loom.Ops.obligations .cursorAgent transcript).contains
          .dropOriginProvenance &&
        Loom.Ops.obligationIsReportOnlyFor .cursorAgent transcript
          .dropOriginProvenance)

private def contentDropObligations : List Loom.Ops.Obligation :=
  [.dropThinking, .dropCompaction, .dropMedia, .dropUnmodeled,
    .dropToolResults, .dropOtherRoles, .dropEvents]

private def historicalConstructorCarrierRoundTrips
    (format : Format) (target : String) (source : Transcript) : Bool :=
  let payloadOnly := { source with entries := source.entries.map (fun entry =>
    { entry with time := Time.absent }) }
  let historical := supportedSourceForTarget target
    (markEntriesHistorical payloadOnly)
  let prepared := targetReady target historical
  !(Loom.Ops.obligations format prepared).any (fun obligation =>
      contentDropObligations.contains obligation) &&
    (Loom.Ops.obligations format prepared).all (fun obligation =>
      !Loom.Ops.obligationIsDestructiveFor format prepared obligation) &&
    match runPipeline "loom" target prepared with
    | .error _ => false
    | .ok exported =>
        match importByFormat target exported with
        | .error _ => false
        | .ok restored =>
            restored.entries.toList.all (fun entry =>
              entry.disposition == EntryDisposition.historicalUnverified) &&
            targetContinuationMatches target prepared prepared restored &&
            targetStateRelation format target prepared restored

private def historicalConstructorCursorArchiveRoundTrips
    (source : Transcript) : Bool :=
  let payloadOnly := { source with entries := source.entries.map (fun entry =>
    { entry with time := Time.absent }) }
  let historical := markEntriesHistorical payloadOnly
  let failures := cursorAgentTargetExportPrerequisiteFailures historical
  failures.contains cursorAgentHistoricalTargetPreflightError &&
    (match exportCursorAgentTargetChecked historical with
     | .ok _ => false
     | .error error => error.contains cursorAgentHistoricalTargetPreflightError) &&
    let exported := exportCursorAgent historical
    match importCursorAgent exported with
    | .error _ => false
    | .ok restored =>
        restored.entries.toList.all (fun entry =>
          entry.disposition == EntryDisposition.historicalUnverified) &&
        targetContinuationMatches "cursor-agent" historical historical restored &&
        targetStateRelation .cursorAgent "cursor-agent" historical restored

/-- Capability probes inspect only the target's native representation surface.
Cursor's exact entry carrier and Claude's whole-entry carrier therefore accept
every typed historical payload constructor below without hiding the fact that
the same native unsupported payload remains destructive. Empty environment
messages are included explicitly because an empty block list previously
triggered refusal before disposition was consulted. -/
def historicalCapabilityPolicyIsDispositionAware : Bool :=
  let constructors := [codexSignedThinkingTranscript, piCompactionTranscript,
    mediaOnlyTranscript, unsafeCursorToolCallTranscript,
    unsafeCursorUnmodeledTranscript, emptyEnvTranscript,
    codexOtherRoleTranscript, eventOnlyTranscript]
  -- `emptyEnvTranscript` omitted: see the archival note below.
  let cursorArchiveConstructors := [codexSignedThinkingTranscript,
    piCompactionTranscript, mediaOnlyTranscript, unsafeCursorToolCallTranscript,
    unsafeCursorUnmodeledTranscript, codexOtherRoleTranscript,
    eventOnlyTranscript]
  -- Split 2026-07-27. These six remain destructive for cursor-agent: each
  -- concept has no target representation AND its absence would assert something
  -- untrue about the conversation.
  let destructiveCursorCases : List (Transcript × Loom.Ops.Obligation) := [
    (piCompactionTranscript, .dropCompaction),
    (mediaOnlyTranscript, .dropMedia),
    (unsafeCursorToolCallTranscript, .dropUnmodeled),
    (unsafeCursorUnmodeledTranscript, .dropUnmodeled),
    (codexOtherRoleTranscript, .dropOtherRoles),
    (eventOnlyTranscript, .dropEvents)]
  -- These two are NAMED but no longer destructive for cursor-agent, and the
  -- distinction is the point of this pin rather than an exception to it.
  -- `.dropThinking`: reasoning is the assistant's private draft, so its absence
  -- claims nothing false about what was said or done.
  -- `.dropToolResults`: cursor-agent has no result slot at all
  -- (`Interop.targetCapabilities` gives `toolResults := none`), so the artifact
  -- renders "outcome unknown" — which is honest — whereas an absent CALL would
  -- assert the assistant never acted, which is why calls still refuse. Claude
  -- HAS the slot, so dropping a result there stays destructive; that asymmetry
  -- is asserted below and is what makes this policy disposition-aware.
  let reportableCursorCases : List (Transcript × Loom.Ops.Obligation) := [
    (codexSignedThinkingTranscript, .dropThinking),
    (emptyEnvTranscript, .dropToolResults)]
  destructiveCursorCases.all (fun (transcript, expected) =>
      let all := Loom.Ops.obligations .cursorAgent transcript
      all.contains expected &&
        Loom.Ops.obligationIsDestructiveFor .cursorAgent transcript expected) &&
    reportableCursorCases.all (fun (transcript, expected) =>
      let all := Loom.Ops.obligations .cursorAgent transcript
      all.contains expected &&
        !Loom.Ops.obligationIsDestructiveFor .cursorAgent transcript expected) &&
    (Loom.Ops.obligations .claudeCode emptyEnvTranscript).contains
      .dropToolResults &&
    Loom.Ops.obligationIsDestructiveFor .claudeCode emptyEnvTranscript
      .dropToolResults &&
    -- `emptyEnvTranscript` leaves the cursor archival round-trip set: with
    -- `.dropToolResults` no longer destructive the runtime target accepts it, so
    -- there is no archive-only refusal left for the archival codec to preserve.
    cursorArchiveConstructors.all historicalConstructorCursorArchiveRoundTrips &&
    constructors.all (historicalConstructorCarrierRoundTrips .claudeCode
      "claude")

/-- A target launch timestamp satisfies a target schema but does not itself
preserve the source's typed time. Pi, Claude, and Codex now have exact typed
carriers; Cursor remains blocked for interpolated/sequenced provenance. -/
def timestampSynthesisAndLossAreDistinct : Bool :=
  let exactRoundTrip := fun (target : String)
      (importer : String → Except String Transcript) (source : Transcript) =>
    let prepared := targetReady target (supportedSourceForTarget target source)
    match runPipeline "loom" target prepared with
    | .error _ => false
    | .ok output =>
        match importer output with
        | .error _ => false
        | .ok restored => restored.entries[0]?.map (fun entry => entry.time) ==
            prepared.entries[0]?.map (fun entry => entry.time)
  let nonRecorded := [absentTimeTranscript, interpolatedTimeTranscript,
    sequencedTimeTranscript]
  [(.pi, "pi", importPi),
    (.claudeCode, "claude", importClaudeCode),
    (.codexCli, "codex", importCodexCli)].all
      (fun (format, target, importer) =>
        Loom.Ops.preservesNonRecordedTimeProvenance format &&
          nonRecorded.all (fun transcript =>
            let source := supportedSourceForTarget target transcript
            let prepared := targetReady target source
            (Loom.Ops.obligations format prepared).contains
                .synthesizeTimestamps &&
              !(Loom.Ops.obligations format prepared).contains
                .dropRecordedTime &&
              !(Loom.Ops.metadataLosses format prepared).contains
                .timeProvenance &&
              exactRoundTrip target importer source)) &&
    LoomConvert.codexMixedTargetTimesAreEntryScopedAndStable &&
    (Loom.Ops.obligations .cursorAgent recordedTimeTranscript).contains
      .dropRecordedTime &&
    (Loom.Ops.metadataLosses .cursorAgent interpolatedTimeTranscript).contains
      .timeProvenance &&
    (Loom.Ops.obligations .cursorAgent interpolatedTimeTranscript).contains
      .dropTimeProvenance &&
    -- Not destructive since 2026-07-27, and the distinction this pin exists to
    -- draw is unaffected: LOSING a non-recorded time is reportable, MINTING one
    -- over it is corrupting. Only the second would break the pin's subject.
    !Loom.Ops.obligationIsDestructiveFor .cursorAgent
      interpolatedTimeTranscript .dropTimeProvenance &&
    !(Loom.Ops.metadataLosses .cursorAgent absentTimeTranscript).contains
      .timeProvenance

/-- An abandoned sibling must not be flattened beside the selected branch.
Every target without exact parent-plus-active-leaf support gets the destructive
obligation and the CLI refuses before an exporter can serialize either path. -/
def divergentBranchExportsAreGuarded : Bool :=
  (violations abandonedAndActiveBranchTranscript).isEmpty &&
  Loom.Ops.hasBranches abandonedAndActiveBranchTranscript &&
  abandonedAndActiveBranchTranscript.activeLeaf == some 2 &&
  branchUnsafeFormats.all (fun target =>
    (Loom.Ops.obligations target abandonedAndActiveBranchTranscript).contains
      .linearizeBranches) &&
  branchUnsafeCliTargets.all (fun target =>
    (exportBlocker? target abandonedAndActiveBranchTranscript).isSome &&
    (match runPipeline "loom" target abandonedAndActiveBranchTranscript with
     | .error _ => true
     | .ok _ => false)) &&
  branchSafeCliTargets.all (fun target =>
    let prepared := targetReady target abandonedAndActiveBranchTranscript
    (exportBlocker? target prepared).isNone &&
      !(Loom.Ops.obligations .pi prepared).contains .linearizeBranches &&
      projectionRoundTripsThroughWithDispositions target
        abandonedAndActiveBranchTranscript
        [.native, .native, .native]) &&
  (match runPipeline "loom" "loom" abandonedAndActiveBranchTranscript with
   | .error _ => false
   | .ok wire =>
       match importLoomWire wire with
       | .error _ => false
       | .ok restored =>
           restored.activeLeaf == some 2 && Loom.Ops.hasBranches restored)

def disconnectedRootExportsAreGuarded : Bool :=
  (violations disconnectedRootsTranscript).isEmpty &&
  Loom.Ops.hasBranches disconnectedRootsTranscript &&
  branchUnsafeFormats.all (fun target =>
    (Loom.Ops.obligations target disconnectedRootsTranscript).contains
      .linearizeBranches) &&
  branchUnsafeCliTargets.all (fun target =>
    (exportBlocker? target disconnectedRootsTranscript).isSome) &&
  branchSafeCliTargets.all (fun target =>
    !(Loom.Ops.obligations .pi
        (targetReady target disconnectedRootsTranscript)).contains
      .linearizeBranches)

/-- A nonempty IR with its imported selection removed is not silently resumed
from the last record. Every resumable target reports the missing selection as a
destructive topology obligation. The Codex importer itself records an explicit
`activeLeafGuessed` judgment when it selects the terminal linear record. -/
def missingActiveLeafSelectionIsExplicit : Bool :=
  match importCodexCli previewCodexContinuationFixture with
  | .error _ => false
  | .ok source =>
      let missing := { source with activeLeaf := none }
      source.entries.size == 3 && source.activeLeaf == some 2 &&
        source.importNotes.any (fun note => note.kind == .activeLeafGuessed) &&
        !Loom.Ops.hasBranches missing &&
        [(.pi, "pi"), (.claudeCode, "claude"), (.codexCli, "codex"),
          (.cursorAgent, "cursor-agent")].all (fun (format, target) =>
            let prepared := targetReady target missing
            (Loom.Ops.obligations format prepared).contains
                .linearizeBranches &&
              Loom.Ops.obligationIsDestructiveFor format prepared
                .linearizeBranches &&
              (match exportBlocker? target prepared with
               | some diagnostic => diagnostic.contains "linearizeBranches"
               | none => false)) &&
        match selectPreviewCodexActiveLeaf (.ok missing) with
        | .error _ => false
        | .ok selected =>
            selected.activeLeaf == some 2 &&
              !(Loom.Ops.obligations .pi
                (targetReady "pi" selected)).contains .linearizeBranches

private def importPasses : Except String Transcript -> Bool
  | .ok t => (violations t).isEmpty
  | .error _ => false

private def declaredSourceImportWitnesses :
    List (String × Except String Transcript) := [
  ("loom", importLoomWire (exportLoomWire validReferenceTranscript)),
  ("pi", importPi fix1),
  ("claude", importClaudeCode claudeFixture),
  ("codex", importCodexCli codexFixture),
  ("cursor-agent", importCursorAgent cursorAgentFixture),
  ("hermes", importHermes hermesFixture),
  ("google-ai-studio", importGoogleAiStudio gaisFixture),
  ("cursor-ide", importCursorIde cursorIdeFixture)]

/-- One checked witness for every declared pure importer. Cursor IDE's SQLite
actuator is separately exercised by the release script; this list checks its
pure `{composer,bubbles}` importer. Exact name equality binds the witnesses to
the normative requirements manifest, so changing the declared surface forces
this evidence to change too. -/
def allImportWitnessesPass : Bool :=
  declaredSourceImportWitnesses.map (fun witness => witness.1) ==
      declaredSourceCliNames &&
    declaredSourceImportWitnesses.all (fun witness => importPasses witness.2)

private def targetHasPolicySpecificRefusal
    (target : String) (source : Transcript) (error : String) : Bool :=
  match exportBlocker? target source with
  | none => false
  | some blocker =>
      error == blocker &&
        if target == "loom" then false
        else if hasNonMainThreads source then
          blocker.contains "single-file flat exporter does not preserve sidechain/detached thread metadata"
        else match formatByCliName? target with
          | none => false
          | some format =>
              let destructive := (Loom.Ops.obligations format source).filter
                (Loom.Ops.obligationIsDestructiveFor format source)
              let semanticRefusal :=
                !destructive.isEmpty &&
                  blocker.contains "destructive export obligations"
              let cursorRuntimeRefusal :=
                let failures := cursorAgentTargetExportPrerequisiteFailures source
                let archiveOnlyFailure :=
                  failures.contains cursorAgentHistoricalTargetPreflightError ||
                    failures.contains cursorAgentNativePayloadPreflightError
                target == "cursor-agent" && archiveOnlyFailure &&
                  failures.all (fun failure => blocker.contains failure)
              semanticRefusal || cursorRuntimeRefusal

private def targetPreservesOrExplicitlyRefuses
    (target : String) (source : Transcript) : Bool :=
  let prepared := targetReady target (supportedSourceForTarget target source)
  if !(violations prepared).isEmpty then false
  else
    match runPipeline "witness" target prepared with
    | .error error => targetHasPolicySpecificRefusal target prepared error
    | .ok exported =>
        match importByFormat target exported with
        | .error _ => false
        | .ok restored =>
            let targetFormat := (formatByCliName? target).getD
              (Format.other target)
            let sourceEvents := continuationEvents? prepared
            let restoredEvents := restoredContinuationEvents? target prepared restored
            (violations restored).isEmpty &&
              (if target == "loom" then
                auditProjection restored == auditProjection prepared
               else
                 targetStateRelation targetFormat target prepared restored &&
                  (sourceEvents.bind fun sourceEvents =>
                    restoredEvents.map fun targetEvents =>
                      historicalDispositionDoesNotUpgrade sourceEvents targetEvents &&
                        withoutErrorProvenance (withoutDisposition sourceEvents) ==
                          withoutErrorProvenance (withoutDisposition targetEvents)).getD false)

/-- The third disposition, added 2026-07-27.

`targetPreservesOrExplicitlyRefuses` offers two outcomes: preservation, or a
named refusal. `Interop.knownLosses` normatively rejects the reading that made
those exhaustive — "every `reportable` row that today causes a refusal is a bug
against `Emission.refused`" — and once a0072e79 stopped cursor-agent refusing
`dropRecordedTime` / `dropSourceIdentity` / `dropEnvironment` /
`dropToolResults`, real cells began exporting successfully while preserving
less than the source. A two-way predicate cannot tell those apart from silent
corruption, so it called them all corruption.

This branch admits such a cell ONLY on positive disclosure: the export
succeeds, the re-import is well formed, the converter NAMES at least one
obligation for this prepared target, and EVERY obligation it names is
non-destructive for that target. A cell that loses something the converter
does not name has no obligation to point at and still fails — which is what
stops this from laundering silent loss into evidence.

It is deliberately weaker than preservation. It is evidence that a loss was
DISCLOSED, never that the loss is acceptable; whether a disclosed cell may
ship is a release decision and not a Lean one. `knownLosses` classifies the
impact, and `REQUIREMENTS_EVIDENCE.md` records which cells rely on this
branch rather than on preservation. -/
private def targetExportsWithDisclosedLoss
    (target : String) (source : Transcript) : Bool :=
  let prepared := targetReady target (supportedSourceForTarget target source)
  if !(violations prepared).isEmpty then false
  else
    match formatByCliName? target with
    | none => false
    | some targetFormat =>
        match runPipeline "witness" target prepared with
        | .error _ => false
        | .ok exported =>
            match importByFormat target exported with
            | .error _ => false
            | .ok restored =>
                let named := Loom.Ops.obligations targetFormat prepared
                (violations restored).isEmpty &&
                  !named.isEmpty &&
                  named.all (fun obligation =>
                    !Loom.Ops.obligationIsDestructiveFor targetFormat prepared
                      obligation)

private def targetPreservesRefusesOrDisclosesLoss
    (target : String) (source : Transcript) : Bool :=
  targetPreservesOrExplicitlyRefuses target source ||
    targetExportsWithDisclosedLoss target source

private def allDeclaredTargetsHaveDisposition (source : Transcript) : Bool :=
  ["loom", "pi", "claude", "codex", "cursor-agent"].all fun target =>
    targetPreservesRefusesOrDisclosesLoss target source

/-- Finite pairwise evidence over one checked fixture for each of the eight
declared source importers and all five declared targets. A cell passes only if
the target artifact re-imports with equal content plus the explicit state
relation above (full audit equality for Loom wire), or the semantic loss gate
names a destructive obligation for that prepared target. Missing launch
prerequisites and unrelated validity failures cannot discharge a cell. This is
a regression matrix, not a universal proof over third-party schemas. -/
def declaredSourceTargetDispositionMatrix : List (String × Bool) :=
  declaredSourceImportWitnesses.flatMap fun (sourceName, imported) =>
    declaredTargetCliNames.map fun target =>
      (sourceName ++ "-to-" ++ target,
        match imported with
        | .error _ => false
        | .ok source => targetPreservesRefusesOrDisclosesLoss target source)

def allDeclaredSourceTargetWitnessesHaveDisposition : Bool :=
  declaredSourceTargetDispositionMatrix.length ==
      declaredSourceCliNames.length * declaredTargetCliNames.length &&
    declaredSourceTargetDispositionMatrix.all (fun witness => witness.2)

private def missingPiTargetPrerequisiteWitness : Transcript :=
  let origin : Origin := { format := .pi, sourceRef := "missing-target-bundle" }
  { threads := #[{ kind := .main }]
    entries := #[{
      time := .recorded ⟨1700000000000⟩
      payload := .userMsg [.text "source"]
      origin }]
    activeLeaf := some 0
    origin }

/-- A real target-validity error is observable, but it is not evidence that the
source/target cell has a semantic preservation-or-refusal disposition. -/
def missingTargetPrerequisiteCannotDischargeDisposition : Bool :=
  let source := missingPiTargetPrerequisiteWitness
  match runPipeline "pi" "pi" source with
  | .ok _ => false
  | .error error =>
      (exportBlocker? "pi" source == some error) &&
        error.contains "target 'pi' validity preflight failed" &&
        !targetHasPolicySpecificRefusal "pi" source error

/-- Finite required-success matrix for the developer-preview headline paths.
Unlike `allDeclaredSourceTargetWitnessesHaveDisposition`, these cells cannot be
discharged by an explicit refusal: each must emit a target artifact, re-import
well-formed IR, preserve every tool-aware continuation event, and avoid any
historical-to-native trust upgrade. Same-format and Loom-wire cells additionally
require exact content disposition plus the explicit topology/time/leaf/env
relation above. This is fixture evidence for the listed release slice, not a
universal claim over vendor data.
Cross-format cells use importer-derived continuation fixtures whose source
environment is representable by that target; the broader public fixtures remain
covered by the preserve-or-refuse and wire cells rather than silently losing
unsupported environment fields. -/
private def previewCursorAgentContinuationFixture : String :=
  String.intercalate "\n" ((cursorAgentFixture.splitOn "\n").take 2)

def previewRequiredSuccessMatrix : List (String × Bool) :=
  let pi := importPi fix1
  let claude := importClaudeCode claudeFixture
  let codex := selectKnownActiveLeaf 5 4 (importCodexCli codexFixture)
  let cursor := importCursorAgent previewCursorAgentContinuationFixture
  let hermes := importHermes hermesFixture
  let gais := importGoogleAiStudio gaisFixture
  let previewClaude := importClaudeCode previewClaudeContinuationFixture
  let previewCodex := selectPreviewCodexActiveLeaf
    (importCodexCli previewCodexContinuationFixture)
  let previewHermes := importHermes previewHermesContinuationFixture
  let previewGais := importGoogleAiStudio previewGaisContinuationFixture
  [
    ("claude-to-pi", requiredConversionSucceeds "claude" "pi" previewClaude),
    ("codex-to-pi", requiredConversionSucceeds "codex" "pi" previewCodex),
    ("hermes-to-pi", requiredConversionSucceeds "hermes" "pi" previewHermes),
    ("gais-to-pi", requiredConversionSucceeds "gais" "pi" previewGais),
    ("claude-to-codex",
      requiredConversionSucceeds "claude" "codex" previewClaude),
    ("codex-to-claude",
      requiredConversionSucceeds "codex" "claude" previewCodex),
    ("pi-to-pi", requiredConversionSucceeds "pi" "pi" pi true),
    ("claude-to-claude",
      requiredConversionSucceeds "claude" "claude" previewClaude true),
    ("codex-to-codex",
      requiredConversionSucceeds "codex" "codex" previewCodex true),
    ("cursor-agent-to-cursor-agent",
      requiredConversionSucceeds "cursor-agent" "cursor-agent" cursor true),
    ("loom-to-loom", requiredConversionSucceeds "loom" "loom"
      (.ok validReferenceTranscript) true),
    ("pi-to-loom", requiredConversionSucceeds "pi" "loom" pi true),
    ("claude-to-loom", requiredConversionSucceeds "claude" "loom" claude true),
    ("codex-to-loom", requiredConversionSucceeds "codex" "loom" codex true),
    ("cursor-agent-to-loom",
      requiredConversionSucceeds "cursor-agent" "loom" cursor true),
    ("hermes-to-loom", requiredConversionSucceeds "hermes" "loom" hermes true),
    ("gais-to-loom", requiredConversionSucceeds "gais" "loom" gais true)
  ]

def previewRequiredSuccessesPass : Bool :=
  previewRequiredSuccessMatrix.all (fun witness => witness.2)

/-- Neighboring unsupported routes are explicit refusals, not failed success
witnesses: malformed current target controls, missing active selection, a wrong
Claude reader-version assertion, and non-recorded Cursor time each name a hard
obligation. Distinct but valid Codex target settings are covered by the source
environment carrier success pins above. -/
def previewRequiredRefusalMatrix : List (String × Bool) :=
  let supportedCodex := targetReady "codex"
    codexSupportedSourceEnvironmentTranscript
  let malformedCodexOrigin := withOriginExtra supportedCodex.origin
    codexTargetControlsKey (Lean.Json.mkObj [])
  let malformedCodex := { supportedCodex with origin := malformedCodexOrigin }
  let missingCodexLeaf := importCodexCli previewCodexContinuationFixture
  let claude := targetReady "claude" foreignEnvironmentTranscript
  let wrongClaudeOrigin := withOriginExtra claude.origin
    "target_harness_version" (Lean.Json.str "2.1.215")
  let wrongClaudeVersion := { claude with origin := wrongClaudeOrigin }
  [
    ("codex-malformed-current-target-controls-refused",
      (exportBlocker? "codex" malformedCodex).isSome),
    ("codex-to-pi-needs-explicit-active-leaf",
      match missingCodexLeaf with
      | .error _ => false
      | .ok source => (exportBlocker? "pi"
          (targetReady "pi" { source with activeLeaf := none })).isSome),
    ("claude-refuses-wrong-target-reader-version",
      (exportBlocker? "claude" wrongClaudeVersion).any (fun error =>
        error.contains "target_harness_version must be '2.1.216'")),
    -- The "cursor-refuses-unpreserved-nonrecorded-time" row was removed
    -- 2026-07-27. `Interop.knownLosses` now classifies `dropTimeProvenance`
    -- `.reportable`: what is at risk is a NON-recorded time — `.absent`,
    -- `.interpolated`, or `.sequenced` — so a target with no timestamp slot
    -- renders "we do not know when", which is exactly what the source knew.
    -- A refusal matrix is the wrong home for a case that must now succeed;
    -- `cursorAgentReportableLossesAreDisclosedNotRefused` asserts the
    -- disclosure instead. Minting a timestamp over the gap stays corrupting
    -- and is guarded by the `synthesizeTimestamps` row.
  ]

def previewRequiredRefusalsPass : Bool :=
  previewRequiredRefusalMatrix.all (fun witness => witness.2)

/-- Same-format and native-wire witnesses. These are finite regression pins,
not claims about every possible external document. -/
def allRoundTripWitnessesPass : Bool :=
  roundTripStable fix1 &&
  roundTripClaude claudeFixture &&
  roundTripCodex codexFixture &&
  roundTripCursorAgent cursorAgentFixture &&
  loomWireRoundTripPreservesThreadMetadata &&
  loomWireRoundTripAllConstructors &&
  loomWireClosedEnumsRoundTrip

def allSchemaClaimsCurrentlyConfirmed : Bool :=
  openClaims.isEmpty

private def alternateToolTranscript : Transcript :=
  { validReferenceTranscript with
    entries := #[
      { validCallEntry with
        payload := .assistantMsg [
          .toolCall { raw := "write", canonical := some .write }
            (Lean.Json.mkObj [("path", Lean.Json.str "README.md")]) (some "call-1")] },
      validResultEntry
    ] }

private def alternateToolIdTranscript : Transcript :=
  { validReferenceTranscript with
    entries := #[
      { validCallEntry with
        payload := .assistantMsg [
          .toolCall { raw := "read", canonical := some .read }
            (Lean.Json.mkObj [("path", Lean.Json.str "README.md")])
            (some "different-call-id")] },
      validResultEntry
    ] }

private def inferredResultTranscript (heuristic : String) : Transcript :=
  { validReferenceTranscript with
    entries := #[validCallEntry,
      { validResultEntry with payload := .envMsg [
          .toolResult (.resolved 0 0) [.text "contents"]
            (.inferred false heuristic)] }]
    activeLeaf := some 1 }

/-- The content projection is materially stronger than the historical parity
normal form for tools: changing a tool's name or arguments changes the witness.
`continuationStateProjection` separately covers topology, time, leaf, and env. -/
def continuationProjectionDistinguishesTools : Bool :=
  continuationProjection validReferenceTranscript !=
      continuationProjection alternateToolTranscript &&
  continuationProjection validReferenceTranscript !=
      continuationProjection alternateToolIdTranscript &&
  continuationProjection validReferenceTranscript !=
      continuationProjection (inferredResultTranscript "heuristic-a") &&
  continuationProjection (inferredResultTranscript "heuristic-a") !=
      continuationProjection (inferredResultTranscript "heuristic-b")

private def groupedStateFixture : Transcript :=
  { validReferenceTranscript with
    entries := #[{ validCallEntry with
      time := .recorded ⟨7⟩
      payload := .assistantMsg [.text "first", .text "second"] }]
    env := {}
    activeLeaf := some 0 }

private def splitStateFixture (firstTime secondTime : Time)
    (reversed : Bool := false) : Transcript :=
  let first := if reversed then "second" else "first"
  let second := if reversed then "first" else "second"
  let firstEntry := { validCallEntry with
    time := firstTime
    payload := .assistantMsg [.text first] }
  let secondEntry := { validResultEntry with
    parent := some 0
    time := secondTime
    payload := .assistantMsg [.text second] }
  { groupedStateFixture with
    entries := #[firstEntry, secondEntry]
    activeLeaf := some 1 }

/-- The state relation permits only split normalization. It rejects merging two
source groups, event reordering, and a split for which no fragment retains the
source group's exact time provenance. -/
def targetStateRelationIsSplitOnlyAndTimeBound : Bool :=
  let exactSplit := splitStateFixture (.recorded ⟨7⟩) (.recorded ⟨7⟩)
  let partialTime := splitStateFixture (.recorded ⟨7⟩) (.recorded ⟨8⟩)
  let timeLost := splitStateFixture (.recorded ⟨8⟩) (.recorded ⟨8⟩)
  let reordered := splitStateFixture (.recorded ⟨7⟩) (.recorded ⟨7⟩) true
  let splitSource := exactSplit
  targetStateRelation .cursorAgent "cursor-agent" groupedStateFixture exactSplit &&
    !targetStateRelation .cursorAgent "cursor-agent" groupedStateFixture partialTime &&
    !targetStateRelation .cursorAgent "cursor-agent" groupedStateFixture timeLost &&
    !targetStateRelation .cursorAgent "cursor-agent" groupedStateFixture reordered &&
    !targetStateRelation .cursorAgent "cursor-agent" splitSource groupedStateFixture

/-- Claude → Codex emits the tool lifecycle NATIVELY.

Inverted 2026-07-27. This pin previously asserted the carrier projection — no
`function_call`, plus "[Historical tool call from source transcript; not
executed by Codex]" prose — which is precisely the D-008 defect `AUDIT.md` §2
records: a native `tool_use` was emitted only when the source was ALREADY
Codex, the one case where conversion is unnecessary. Native emission landed in
af0b289e; the pin now asserts the goal instead of the defect, and the old
expectation is kept above only as the thing that must NOT reappear.

Provenance is unaffected: `_agent_convert` still travels out of band, and no
entry is upgraded past `.native` because the Claude source is native
throughout. `codexErrorHeuristicDoesNotDemoteNativeHistory` covers recorded
failures whose text does not match Codex's heuristic. -/
def claudeToCodexNativeLifecycleWitness : Bool :=
  match importClaudeCode claudeFixture with
  | .error _ => false
  | .ok source =>
      let exported := exportCodexCli source
      exported.contains "\"type\":\"function_call\"" &&
      exported.contains "\"type\":\"function_call_output\"" &&
      !(exported.contains
        "[Historical tool call from source transcript; not executed by Codex]") &&
      !(exported.contains
        "[Historical tool result from source transcript; not executed by Codex]") &&
      -- Provenance still travels out of band. With the carrier gone the
      -- envelope that remains is the source archive, not the old inline key.
      exported.contains "\"_agent_convert_source_archive\"" &&
      match importCodexCli exported with
      | .error _ => false
      | .ok target =>
          source.entries.toList.all (fun entry =>
              entry.disposition == EntryDisposition.native) &&
            target.entries.toList.all (fun entry =>
              entry.disposition == EntryDisposition.native) &&
            (renderTranscript target).contains "[tool call bash"

private def nativeCodexCallEntry : Entry :=
  { validCallEntry with payload := .assistantMsg [
      .toolCall { raw := "exec_command", canonical := none }
        (Lean.Json.mkObj [("cmd", Lean.Json.str "cat README.md")])
        (some "call-1")] }

private def nativeCodexTranscript : Transcript :=
  { validReferenceTranscript with entries := #[nativeCodexCallEntry,
      { validResultEntry with payload := .envMsg [
          .toolResult (.resolved 0 0) [.text "contents"]
            (.inferred false "codexOutputIndicatesError (codexAdapter.ts:75)")] }] }

/-- Inverted 2026-07-27 for the same reason as
`claudeToCodexNativeLifecycleWitness`: a representable call/result pair reaches
Codex as its own native lifecycle, and both entries stay `.native` through the
round trip rather than degrading to `.historicalUnverified` prose. The name was
already accurate; only the body was asserting the opposite. -/
def codexNativeContinuationWitness : Bool :=
  LoomConvert.codexExactImportedNativeToolCyclesStayExact &&
    let prepared := targetReady "codex" nativeCodexTranscript
    let exported := exportCodexCli prepared
    exported.contains "\"type\":\"function_call\"" &&
      exported.contains "\"type\":\"function_call_output\"" &&
      !(exported.contains "[Historical tool call from source transcript") &&
      !(exported.contains "[Historical tool result from source transcript") &&
      match importCodexCli exported,
          withEntryDispositions? prepared [.native, .native] with
      | .ok target, some expected =>
          targetContinuationMatches "codex" expected prepared target &&
            targetStateRelation .codexCli "codex" prepared target
      | _, _ => false

private def lossyNativeSchemaTranscript : Transcript :=
  { nativeCodexTranscript with
    entries := #[
      { validCallEntry with payload := .assistantMsg [
          .toolCall { raw := "exec_command", canonical := none }
            (Lean.Json.mkObj [
              ("cmd", Lean.Json.str "cat README.md"),
              ("timeout", (30 : Lean.Json))])
            (some "call-1")] },
      validResultEntry] }

private def lossyNativeResultTranscript : Transcript :=
  { nativeCodexTranscript with
    entries := #[nativeCodexCallEntry,
      { validResultEntry with payload := .envMsg [
          .toolResult (.resolved 0 0) [.text "failed"] (.native true)] }] }

/-- Extra arguments and a recorded error not recognized by the text heuristic
are both representable. Native records carry exact error provenance out of band;
the old carrier assertion encoded the defect reported in #8. -/
def codexErrorHeuristicDoesNotDemoteNativeHistory : Bool :=
  let schemaExported := exportCodexCli lossyNativeSchemaTranscript
  let resultExported := exportCodexCli lossyNativeResultTranscript
  -- Representable: native, no carrier prose.
  schemaExported.contains "\"type\":\"function_call\"" &&
  !(schemaExported.contains
    "[Historical tool call from source transcript; not executed by Codex]") &&
  resultExported.contains "\"type\":\"function_call\"" &&
  resultExported.contains "\"type\":\"function_call_output\"" &&
  !(resultExported.contains "[Historical tool call from source transcript") &&
  !(resultExported.contains "[Historical tool result from source transcript") &&
  match importCodexCli resultExported with
  | .ok restored =>
      restored.entries.all (·.disposition == EntryDisposition.native) &&
      match restored.entries[1]? with
      | some entry => match entry.payload with
        | .envMsg [.toolResult (.resolved 0 0) [.text "failed"] (.native true)] => true
        | _ => false
      | none => false
  | .error _ => false

/-- The pi spoke preserves the tool call/result lifecycle, including raw id and
error state, instead of reclassifying tool results as generic messages.

Both entries come back `.native`. `validCallEntry` asserts
`canonical := some .read`, and until that field could travel out of band Pi's
exporter withheld the whole `toolCall` block over it — Pi's block has slots for
only id/name/arguments, and a reserved Loom stamp ON a content block would mark
the message historical. `piToolCanonicalCarrier` puts it in the message-level
stamp instead, so the call is executable, its result follows it, and `.read`
still returns. The pin's subject — that the lifecycle survives rather than
flattening into generic messages — is strengthened, not weakened: a
`historicalUnverified` pair is a lifecycle Pi can display but not continue. -/
def piContinuationWitness : Bool :=
  projectionRoundTripsThroughWithDispositions "pi" validReferenceTranscript
    [.native, .native]

private def piEmptyAssistantContinuationTranscript : Transcript :=
  { validReferenceTranscript with
    entries := #[{ validCallEntry with payload := .assistantMsg [] }]
    activeLeaf := some 0 }

/-- Empty assistant turns are continuation events, not removable target
scaffolding. Pi must re-import the explicit empty payload with its grouping,
time, and trust disposition intact. -/
def piEmptyAssistantContinuationWitness : Bool :=
  requiredConversionSucceeds "loom" "pi"
    (.ok piEmptyAssistantContinuationTranscript)

/-- Closed audit dimensions for F-027. Keeping the census typed means adding a
new lifecycle dimension cannot be hidden behind an unnamed Boolean conjunct. -/
inductive F027LifecycleAdversaryDimension where
  | duplicateIds
  | missingIds
  | reorderedCallResults
  | structuredResultPayloads
  | errorResults
  | interruptedIncompleteCalls
  deriving Repr, DecidableEq, BEq

def F027LifecycleAdversaryDimension.all :
    List F027LifecycleAdversaryDimension := [
  .duplicateIds,
  .missingIds,
  .reorderedCallResults,
  .structuredResultPayloads,
  .errorResults,
  .interruptedIncompleteCalls
]

def F027LifecycleAdversaryDimension.rowName :
    F027LifecycleAdversaryDimension -> String
  | .duplicateIds =>
      "duplicate-ids--pi-checked-conversion-reimport-preserves-positional-linkage"
  | .missingIds =>
      "missing-ids--pi-checked-conversion-reimport-preserves-none"
  | .reorderedCallResults =>
      "reordered-call-results--pi-checked-conversion-reimport-preserves-order"
  | .structuredResultPayloads =>
      "structured-result-payloads--pi-checked-conversion-reimport-preserves-json"
  | .errorResults =>
      "error-results--pi-checked-conversion-reimport-preserves-error-state"
  | .interruptedIncompleteCalls =>
      "interrupted-incomplete-calls--pi-checked-conversion-reimport-preserves-open-call"

theorem F027LifecycleAdversaryDimension.censusComplete
    (dimension : F027LifecycleAdversaryDimension) :
    F027LifecycleAdversaryDimension.all.contains dimension = true := by
  cases dimension <;> native_decide

/-- One deterministic lifecycle adversary. Duplicate raw ids cannot substitute
for positional linkage: the second call's result arrives first. That result is
structured and erroneous, the first result is non-error, and the final call has
neither an id nor a result because the source was interrupted. -/
def f027LifecycleAdversaryTranscript : Transcript :=
  let origin : Origin := {
    format := .other "f027-lifecycle-adversary"
    sourceRef := "F-027/seed-0" }
  { threads := #[{ kind := .main }]
    entries := #[
      { payload := .assistantMsg [
          .toolCall { raw := "f027_first" }
            (Lean.Json.mkObj [("ordinal", (1 : Lean.Json))])
            (some "duplicate-id")]
        origin },
      { parent := some 0
        payload := .assistantMsg [
          .toolCall { raw := "f027_second" }
            (Lean.Json.mkObj [("ordinal", (2 : Lean.Json))])
            (some "duplicate-id")]
        origin },
      { parent := some 1
        payload := .envMsg [
          .toolResult (.resolved 1 0) [
            .text "second-result",
            .unmodeled "f027.structured-result" (Lean.Json.mkObj [
              ("stdout", Lean.Json.str "failed"),
              ("exitCode", (17 : Lean.Json)),
              ("chunks", Lean.Json.arr #[
                Lean.Json.str "alpha",
                Lean.Json.mkObj [("nested", Lean.Json.bool true)]])])]
            (.native true)]
        origin },
      { parent := some 2
        payload := .envMsg [
          .toolResult (.resolved 0 0) [.text "first-result"]
            (.native false)]
        origin },
      { parent := some 3
        payload := .assistantMsg [
          .toolCall { raw := "f027_interrupted" }
            (Lean.Json.mkObj [("phase", Lean.Json.str "started")]) none]
        origin }
    ]
    activeLeaf := some 4
    origin }

private def f027LifecycleDimensionPresent
    (dimension : F027LifecycleAdversaryDimension) (t : Transcript) : Bool :=
  match dimension with
  | .duplicateIds =>
      match t.entries[0]?, t.entries[1]? with
      | some first, some second =>
          match first.payload, second.payload with
          | .assistantMsg [.toolCall _ _ firstId],
              .assistantMsg [.toolCall _ _ secondId] =>
              firstId == some "duplicate-id" && secondId == firstId
          | _, _ => false
      | _, _ => false
  | .missingIds =>
      match t.entries[4]? with
      | some entry =>
          match entry.payload with
          | .assistantMsg [.toolCall _ _ none] => true
          | _ => false
      | none => false
  | .reorderedCallResults =>
      match t.entries[2]?, t.entries[3]? with
      | some secondResult, some firstResult =>
          match secondResult.payload, firstResult.payload with
          | .envMsg [.toolResult (.resolved 1 0) _ _],
              .envMsg [.toolResult (.resolved 0 0) _ _] => true
          | _, _ => false
      | _, _ => false
  | .structuredResultPayloads =>
      match t.entries[2]? with
      | some entry =>
          match entry.payload with
          | .envMsg [.toolResult _
              [.text "second-result", .unmodeled "f027.structured-result" raw] _] =>
              raw == Lean.Json.mkObj [
                ("stdout", Lean.Json.str "failed"),
                ("exitCode", (17 : Lean.Json)),
                ("chunks", Lean.Json.arr #[
                  Lean.Json.str "alpha",
                  Lean.Json.mkObj [("nested", Lean.Json.bool true)]])]
          | _ => false
      | none => false
  | .errorResults =>
      match t.entries[2]?, t.entries[3]? with
      | some errorResult, some successResult =>
          match errorResult.payload, successResult.payload with
          | .envMsg [.toolResult _ _ (.native true)],
              .envMsg [.toolResult _ _ (.native false)] => true
          | _, _ => false
      | _, _ => false
  | .interruptedIncompleteCalls =>
      Loom.Ops.openCalls t == [(4, 0)] &&
        match t.entries[4]? with
        | some entry =>
            match entry.payload with
            | .assistantMsg [.toolCall name _ none] =>
                name.raw == "f027_interrupted"
            | _ => false
        | none => false

/-- This is the actual checked conversion boundary, not an importer-only shape
test: it requires a well-formed source, no Pi policy blocker, successful
`runPipeline`, successful Pi re-import, well-formed restored IR, split-only
state preservation, exact lifecycle events modulo a permitted native-to-inert
downgrade, and no historical-to-native trust upgrade. -/
private def f027PiCheckedConversionReimportPreserves : Bool :=
  requiredConversionSucceeds "loom" "pi"
    (.ok f027LifecycleAdversaryTranscript)

structure F027LifecycleAdversaryRow where
  dimension : F027LifecycleAdversaryDimension
  name : String
  checked : Bool

/-- Auditable finite F-027 aggregate. Every row independently requires both a
concrete source witness for its named dimension and the checked Pi conversion /
re-import preservation contract above. -/
def f027LifecycleAdversaryRows : List F027LifecycleAdversaryRow :=
  let source := f027LifecycleAdversaryTranscript
  let preserved := f027PiCheckedConversionReimportPreserves
  [
    { dimension := .duplicateIds
      name := F027LifecycleAdversaryDimension.rowName .duplicateIds
      checked := f027LifecycleDimensionPresent .duplicateIds source && preserved },
    { dimension := .missingIds
      name := F027LifecycleAdversaryDimension.rowName .missingIds
      checked := f027LifecycleDimensionPresent .missingIds source && preserved },
    { dimension := .reorderedCallResults
      name := F027LifecycleAdversaryDimension.rowName .reorderedCallResults
      checked := f027LifecycleDimensionPresent .reorderedCallResults source && preserved },
    { dimension := .structuredResultPayloads
      name := F027LifecycleAdversaryDimension.rowName .structuredResultPayloads
      checked := f027LifecycleDimensionPresent .structuredResultPayloads source && preserved },
    { dimension := .errorResults
      name := F027LifecycleAdversaryDimension.rowName .errorResults
      checked := f027LifecycleDimensionPresent .errorResults source && preserved },
    { dimension := .interruptedIncompleteCalls
      name := F027LifecycleAdversaryDimension.rowName .interruptedIncompleteCalls
      checked := f027LifecycleDimensionPresent .interruptedIncompleteCalls source && preserved }
  ]

/-- The exact typed census, exact row names, and every checked preservation row
must agree. List equality prevents duplicate rows from masking an omission. -/
def f027LifecycleAdversaryAggregate : Bool :=
  f027LifecycleAdversaryRows.map (fun row => row.dimension) ==
      F027LifecycleAdversaryDimension.all &&
    f027LifecycleAdversaryRows.all (fun row =>
      row.name == row.dimension.rowName && row.checked)

private def recordedTimeRoundTripWith
    (target : String) (importer : String → Except String Transcript) : Bool :=
  let source := supportedSourceForTarget target recordedTimeTranscript
  match runPipeline "loom" target (targetReady target source) with
  | .error _ => false
  | .ok exported =>
      exported.contains "2023-11-14T22:13:20.000Z" &&
      match importer exported with
      | .error _ => false
      | .ok restored => restored.entries[0]?.map (·.time) ==
          some (Time.recorded ⟨1700000000000⟩)

/-- Pi, Claude, and Codex preserve the exact recorded millisecond value. Codex
uses its target launch timestamp only for absent/interpolated/sequenced source
time, never in place of `Time.recorded`. -/
def recordedTimeTargetRoundTrips : Bool :=
  recordedTimeRoundTripWith "pi" importPi &&
  recordedTimeRoundTripWith "claude" importClaudeCode &&
  recordedTimeRoundTripWith "codex" importCodexCli

def readableTranscriptWitness : Bool :=
  let rendered := renderTranscript validReferenceTranscript
  rendered.contains "## 0 ASSISTANT" &&
  rendered.contains "[tool call read; id=call-1]" &&
  rendered.contains "## 1 ENVIRONMENT" &&
  rendered.contains "tool result for entry 0, block 0" &&
  !(rendered.contains "<tool")

/-- Typed Lean evidence for E-009's wire-compatibility claim. -/
def wireCompatibilityLeanEvidence : Bool :=
  loomWireRejectsWrongSchema &&
  loomWireRejectsMissingRequiredField &&
  loomWireRejectsMalformedEntryDisposition &&
  loomWireAcceptsUnknownAdditiveFieldsAndLabels

/-- Typed Lean evidence for E-032. The rendered review exposes only signature
presence, while canonical Loom JSON retains the exact opaque value. -/
def thinkingSignatureReviewLeanEvidence : Bool :=
  let rendered := renderTranscript codexSignedThinkingTranscript
  let canonical := exportLoomWire codexSignedThinkingTranscript
  rendered.contains "[thinking; signature=present]" &&
  !(rendered.contains "foreign-signature") &&
  canonical.contains "foreign-signature"

/-- Artifact-level inertness is distinct from observing a real harness. These
checks require historical Claude, Codex, and Pi lifecycle carriers to avoid the
target's native executable call shape, retain typed historical disposition on
re-import, and preserve the carried lifecycle. They make no claim about what a
third-party runtime did with the resulting bytes. -/
def historicalToolCarriersAreArtifactInert : Bool :=
  LoomConvert.claudeCodexHistoricalLifecycleRoundTrip &&
  LoomConvert.claudeHistoricalDispositionSurvivesMetadataStripping &&
  claudeToCodexNativeLifecycleWitness &&
  codexNativeContinuationWitness &&
  codexErrorHeuristicDoesNotDemoteNativeHistory &&
  piContinuationWitness &&
  LoomConvert.piHistoricalDispositionSurvivesMetadataStripping

/-- Closed keys for every currently declared Lean-side readiness claim. A new
constructor must be added to `.all`, given a proposition below, and proved in
the total bundle. -/
inductive VerifiedLeanEvidenceKey where
  | pipelineBoundaryE002
  | importFixturesE003
  | roundTripsE004
  | structuralCounterexamplesE005
  | wireCompatibilityE009
  | continuationProjectionE014
  | runtimeControlsE022
  | targetPolicyCensusE028
  | thinkingSignatureReviewE032
  | historicalCarrierInertnessE035
  | contextIsolationCensusE036
  deriving Repr, DecidableEq, BEq

def VerifiedLeanEvidenceKey.all : List VerifiedLeanEvidenceKey := [
  .pipelineBoundaryE002,
  .importFixturesE003,
  .roundTripsE004,
  .structuralCounterexamplesE005,
  .wireCompatibilityE009,
  .continuationProjectionE014,
  .runtimeControlsE022,
  .targetPolicyCensusE028,
  .thinkingSignatureReviewE032,
  .historicalCarrierInertnessE035,
  .contextIsolationCensusE036
]

theorem VerifiedLeanEvidenceKey.censusComplete
    (key : VerifiedLeanEvidenceKey) :
    VerifiedLeanEvidenceKey.all.contains key = true := by
  cases key <;> native_decide

def VerifiedLeanEvidenceKey.evidenceId : VerifiedLeanEvidenceKey -> String
  | .pipelineBoundaryE002 => "E-002"
  | .importFixturesE003 => "E-003"
  | .roundTripsE004 => "E-004"
  | .structuralCounterexamplesE005 => "E-005"
  | .wireCompatibilityE009 => "E-009"
  | .continuationProjectionE014 => "E-014"
  | .runtimeControlsE022 => "E-022"
  | .targetPolicyCensusE028 => "E-028"
  | .thinkingSignatureReviewE032 => "E-032"
  | .historicalCarrierInertnessE035 => "E-035"
  | .contextIsolationCensusE036 => "E-036"

def VerifiedLeanEvidenceKey.ofEvidenceId? :
    String -> Option VerifiedLeanEvidenceKey
  | "E-002" => some .pipelineBoundaryE002
  | "E-003" => some .importFixturesE003
  | "E-004" => some .roundTripsE004
  | "E-005" => some .structuralCounterexamplesE005
  | "E-009" => some .wireCompatibilityE009
  | "E-014" => some .continuationProjectionE014
  | "E-022" => some .runtimeControlsE022
  | "E-028" => some .targetPolicyCensusE028
  | "E-032" => some .thinkingSignatureReviewE032
  | "E-035" => some .historicalCarrierInertnessE035
  | "E-036" => some .contextIsolationCensusE036
  | _ => none

/-- Unlike catalogue claim text, each key denotes an actual Lean proposition. -/
def VerifiedLeanEvidenceKey.claim : VerifiedLeanEvidenceKey -> Prop
  | .pipelineBoundaryE002 =>
      ImplementationRefinesMachinePipelineSpec runPipelineImplementation
          runPipelineConcreteMachineSpec /\
        ∀ (fromFmt toFmt output : String) (t : Transcript),
          runPipeline fromFmt toFmt t = .ok output ->
            SuccessfulRunObservableSpec toFmt t output
  | .importFixturesE003 => allImportWitnessesPass = true
  | .roundTripsE004 => allRoundTripWitnessesPass = true
  | .structuralCounterexamplesE005 => structuralCounterexamplesRejected = true
  | .wireCompatibilityE009 => wireCompatibilityLeanEvidence = true
  | .continuationProjectionE014 =>
      continuationProjectionDistinguishesTools = true /\
      claudeToCodexNativeLifecycleWitness = true /\
      codexNativeContinuationWitness = true /\
      piContinuationWitness = true /\
      f027LifecycleAdversaryAggregate = true
  | .runtimeControlsE022 => LoomConvert.codexRuntimeControlsArchived = true
  | .targetPolicyCensusE028 =>
      LoomConvert.codexRichTargetPolicyCensusReconciles = true
  | .thinkingSignatureReviewE032 => thinkingSignatureReviewLeanEvidence = true
  | .historicalCarrierInertnessE035 =>
      historicalToolCarriersAreArtifactInert = true
  | .contextIsolationCensusE036 => contextIsolationF032Aggregate = true

/-- Total proof-bearing bundle. No evidence ID enters this value through a
claim string, locator string, caller Boolean, or script result. -/
def verifiedLeanEvidenceBundle :
    VerifiedEvidenceBundle VerifiedLeanEvidenceKey
      VerifiedLeanEvidenceKey.claim := {
  verify := fun key =>
    match key with
    | .pipelineBoundaryE002 => runPipelineMachineRefinementLeanBinding.proof
    | .importFixturesE003 => by
        change allImportWitnessesPass = true
        native_decide
    | .roundTripsE004 => by
        change allRoundTripWitnessesPass = true
        native_decide
    | .structuralCounterexamplesE005 => by
        change structuralCounterexamplesRejected = true
        native_decide
    | .wireCompatibilityE009 => by
        change wireCompatibilityLeanEvidence = true
        native_decide
    | .continuationProjectionE014 => by
        change continuationProjectionDistinguishesTools = true /\
          claudeToCodexNativeLifecycleWitness = true /\
          codexNativeContinuationWitness = true /\ piContinuationWitness = true /\
          f027LifecycleAdversaryAggregate = true
        native_decide
    | .runtimeControlsE022 => by
        change LoomConvert.codexRuntimeControlsArchived = true
        native_decide
    | .targetPolicyCensusE028 => by
        change LoomConvert.codexRichTargetPolicyCensusReconciles = true
        native_decide
    | .thinkingSignatureReviewE032 => by
        change thinkingSignatureReviewLeanEvidence = true
        native_decide
    | .historicalCarrierInertnessE035 => by
        change historicalToolCarriersAreArtifactInert = true
        native_decide
    | .contextIsolationCensusE036 => by
        change contextIsolationF032Aggregate = true
        native_decide
}

/-- Eligibility requires the proof-bearing bundle as an argument. Candidate
evidence remains pending and is accepted only as a declared external input. -/
def evidenceProofBoundOrCandidatePending
    (_bundle : VerifiedEvidenceBundle VerifiedLeanEvidenceKey
      VerifiedLeanEvidenceKey.claim) (id : String) : Bool :=
  match evidenceQualification id with
  | .leanProofRequired => (VerifiedLeanEvidenceKey.ofEvidenceId? id).isSome
  | .candidateValidationRequired => true
  | .ineligible => false

def fitObligationProofBoundCatalogueEligible
    (bundle : VerifiedEvidenceBundle VerifiedLeanEvidenceKey
      VerifiedLeanEvidenceKey.claim) (obligation : FitObligation) : Bool :=
  fitObligationAssessment obligation != .blocked &&
  obligation.evidence.all (evidenceProofBoundOrCandidatePending bundle)

/-- Final catalogue eligibility belongs in this downstream module: Lean-only
obligations need actual proofs from the closed bundle; candidate obligations may
remain explicitly pending. This is still not release readiness. -/
def requirementProofBoundCatalogueEligible
    (bundle : VerifiedEvidenceBundle VerifiedLeanEvidenceKey
      VerifiedLeanEvidenceKey.claim) (rid : RequirementId) : Bool :=
  let obligations := fitObligations.filter (fun obligation =>
    obligation.requirement == rid)
  requirementEvidenceDeclarationWellFormed rid &&
  !obligations.isEmpty &&
  obligations.all (fitObligationProofBoundCatalogueEligible bundle)

def previewProofBoundCatalogueEligible : Bool :=
  catalogueIntegrityGate && RequirementId.previewScopeManifest.all
    (requirementProofBoundCatalogueEligible verifiedLeanEvidenceBundle)

def stableProofBoundCatalogueEligible : Bool :=
  catalogueIntegrityGate && RequirementId.all.all
    (requirementProofBoundCatalogueEligible verifiedLeanEvidenceBundle)

/-- Honest downstream catalogue assessments after Lean proof binding. Even a
true eligibility result advances only to external decision, never pure release
readiness. -/
def previewProofBoundReadinessAssessment : PureReadinessAssessment :=
  catalogueReadinessAssessment previewProofBoundCatalogueEligible

def stableProofBoundReadinessAssessment : PureReadinessAssessment :=
  catalogueReadinessAssessment stableProofBoundCatalogueEligible

example : leanEvidenceWorklist.map (·.evidenceId) =
    VerifiedLeanEvidenceKey.all.map (·.evidenceId) := by
  native_decide

example : VerifiedLeanEvidenceKey.all.eraseDups.length =
    VerifiedLeanEvidenceKey.all.length := by
  native_decide

example : VerifiedLeanEvidenceKey.ofEvidenceId? "E-037" = none := by
  native_decide

example : requirementProofBoundCatalogueEligible verifiedLeanEvidenceBundle
    .structuralIntegrity = true := by
  native_decide

example : requirementProofBoundCatalogueEligible verifiedLeanEvidenceBundle
    .wireCompatibility = true := by
  native_decide

example : requirementProofBoundCatalogueEligible verifiedLeanEvidenceBundle
    .portableBuild = true := by
  native_decide

example : evidenceProofBoundOrCandidatePending verifiedLeanEvidenceBundle
    "E-FORGED" = false := by
  native_decide

example : evidenceProofBoundOrCandidatePending verifiedLeanEvidenceBundle
    "E-037" = true := by
  native_decide

example : previewProofBoundCatalogueEligible = false := by native_decide
example : stableProofBoundCatalogueEligible = false := by native_decide
example : previewProofBoundReadinessAssessment = .catalogueBlocked := by
  native_decide
example : stableProofBoundReadinessAssessment = .catalogueBlocked := by
  native_decide
example : catalogueReadinessAssessment true = .externalDecisionRequired := by
  native_decide

/-- Even a total proof bundle establishes catalogue eligibility only. External
candidate adjudication and release readiness remain outside the pure model. -/
theorem proofBoundCatalogueEvidenceCannotEstablishReleaseReadiness :
    previewReady = false /\ stableReady = false :=
  pureReadinessFailsClosed

example : structuralCounterexamplesRejected = true := by native_decide
example : codexCompactionPolicyAndDiagnosticsPinned = true := by native_decide
example : destructiveLossesBlocked = true := by native_decide
example : reversibleRepresentationsArePreservedOrRefused = true := by native_decide
example : destructiveDiagnosticsAreClassified = true := by native_decide
example : cursorApplyPatchStringPolicyPinned = true := by native_decide
example : identitySynthesisIsNotReplacement = true := by native_decide
example : claudeToCodexIdentityLossIsReportOnly = true := by native_decide
example : environmentLossPolicyPinned = true := by native_decide
example : claudeSourceEnvironmentCarrierPreservesAllFields = true := by native_decide
example : targetControlsDoNotMasqueradeAsSourceEnvironment = true := by native_decide
example : codexSourceEnvironmentCarrierPreservesClaudeControlFixture = true := by
  native_decide
example : sourceTargetConfigurationArchivePolicyPinned = true := by native_decide
example : originProvenancePolicyPinned = true := by native_decide
example : safetyProvenancePolicyPinned = true := by native_decide
example : typedDispositionAuthorityPinned = true := by native_decide
example : historicalCapabilityPolicyIsDispositionAware = true := by native_decide
example : contextIsolationF032Aggregate = true := by native_decide
example : timestampSynthesisAndLossAreDistinct = true := by native_decide
example : divergentBranchExportsAreGuarded = true := by native_decide
example : disconnectedRootExportsAreGuarded = true := by native_decide
example : missingActiveLeafSelectionIsExplicit = true := by native_decide
example : allImportWitnessesPass = true := by native_decide
example : allDeclaredSourceTargetWitnessesHaveDisposition = true := by native_decide
example : missingTargetPrerequisiteCannotDischargeDisposition = true := by native_decide
example : previewRequiredSuccessesPass = true := by native_decide
example : previewRequiredRefusalsPass = true := by native_decide
example : allRoundTripWitnessesPass = true := by native_decide
example : allSchemaClaimsCurrentlyConfirmed = true := by native_decide
example : continuationProjectionDistinguishesTools = true := by native_decide
example : targetStateRelationIsSplitOnlyAndTimeBound = true := by native_decide
example : claudeToCodexNativeLifecycleWitness = true := by native_decide
example : codexNativeContinuationWitness = true := by native_decide
example : codexErrorHeuristicDoesNotDemoteNativeHistory = true := by native_decide
example : piContinuationWitness = true := by native_decide
example : piEmptyAssistantContinuationWitness = true := by native_decide
example : f027LifecycleAdversaryAggregate = true := by native_decide
example : recordedTimeTargetRoundTrips = true := by native_decide
example : readableTranscriptWitness = true := by native_decide

end AgentConvert.Requirements
