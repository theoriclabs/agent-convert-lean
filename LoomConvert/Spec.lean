import LoomConvert.IRCodec
import LoomOps.Conversion

namespace LoomConvert
open Loom

structure CliOptions where
  tsParity     : Bool := false
  /-- `none` = default policy (`resolveWithSubagents`); `some` = explicit flag. -/
  withSubagents : Option Bool := none
  json         : Bool := false
  allowEmptyDialogue : Bool := false
  cwd          : Option String := none
  provider     : Option String := none
  model        : Option String := none
  harnessVersion : Option String := none
  sessionId    : Option String := none
  targetTimestamp : Option String := none
  piAssistantHistory : Option String := none
  codexApprovalPolicy : Option String := none
  codexNetworkAccess : Option Bool := none
  codexExcludeTmpdirEnvVar : Option Bool := none
  codexExcludeSlashTmp : Option Bool := none
  codexSummary : Option String := none
  store        : Option String := none
  limit        : Option Nat := none
  role         : Option String := none

def sourceOriginExtrasArchiveKey : String :=
  "_agent_convert_source_origin_extras"

def setOriginExtra (origin : Origin) (key : String) (value : Lean.Json) : Origin :=
  let extras := match origin.extras with
    | some (.obj fields) => Lean.Json.obj (fields.insert key value)
    | some prior => Lean.Json.mkObj [
        (sourceOriginExtrasArchiveKey, Lean.Json.mkObj [
          ("protocol", Lean.Json.str "agent-convert.source-origin-extras.v1"),
          ("raw", prior)]),
        (key, value)]
    | none => Lean.Json.mkObj [(key, value)]
  { origin with extras := some extras }

def applyTargetExtra (origin : Origin) (key : String) : Option String -> Origin
  | some value => setOriginExtra origin key (Lean.Json.str value)
  | none => origin

def targetConfigurationKeys : List String := [
  "target_cwd", "target_provider", "target_model", "target_session_id",
  "target_timestamp", "target_harness_version", "target_cli_version",
  "target_originator", "target_turn_context_record", "target_codex_controls",
  "target_cursor_agent_controls", "pi_assistant_history"]

def sourceTargetConfigurationArchiveKey : String :=
  "_agent_convert_source_target_configuration"

/-- A source artifact cannot authorize the next target's identity or runtime
controls. Only values supplied by this invocation are eligible for activation. -/
def clearTargetConfiguration (origin : Origin) : Origin :=
  match origin.extras with
  | some (.obj fields) =>
      let raw := Lean.Json.obj fields
      let cleared := targetConfigurationKeys.filterMap (fun key =>
        (raw.getObjVal? key).toOption.map (fun value => (key, value)))
      let retained := targetConfigurationKeys.foldl (fun acc key => acc.erase key) fields
      let retained := if cleared.isEmpty then retained else
        let prior := (raw.getObjVal? sourceTargetConfigurationArchiveKey).toOption
        retained.insert sourceTargetConfigurationArchiveKey (Lean.Json.mkObj [
          ("protocol", Lean.Json.str "agent-convert.source-target-configuration.v1"),
          ("prior", prior.getD Lean.Json.null),
          ("cleared", Lean.Json.mkObj cleared)])
      { origin with extras := some (.obj retained) }
  | _ => origin

def missingCodexControlFlags (opts : CliOptions) : List String :=
  [
    ("--target-codex-approval-policy", opts.codexApprovalPolicy.isNone),
    ("--target-codex-network-access", opts.codexNetworkAccess.isNone),
    ("--target-codex-exclude-tmpdir-env-var", opts.codexExcludeTmpdirEnvVar.isNone),
    ("--target-codex-exclude-slash-tmp", opts.codexExcludeSlashTmp.isNone),
    ("--target-codex-summary", opts.codexSummary.isNone)
  ].filterMap (fun (flag, missing) => if missing then some flag else none)

def hasAnyCodexControlOption (opts : CliOptions) : Bool :=
  (missingCodexControlFlags opts).length < 5

/-- The latest recorded entry time supplies a deterministic target launch stamp. -/
def latestRecordedIso? (t : Transcript) : Option String :=
  (t.entries.toList.foldl (fun acc entry =>
    match entry.time with
    | .recorded value =>
        match acc with
        | some best => some (if value.ms > best then value.ms else best)
        | none => some value.ms
    | _ => acc) none).map (fun ms => Loom.epochMsToIso8601 ⟨ms⟩)

/-- Stable UUIDv8 for foreign sources whose native session ID is not a UUID. -/
def smartGeneratedUuid (material : String) : String :=
  let upper := (String.hash ("agent-convert.smart.uuid.a|" ++ material)).toNat
  let lower := (String.hash ("agent-convert.smart.uuid.b|" ++ material)).toNat
  let packed := upper * (2 ^ 64) + lower
  let raw := (Nat.toDigits 16 packed).reverse.take 30 |>.reverse
  let digits := List.replicate (30 - raw.length) '0' ++ raw
  String.ofList (digits.take 8) ++ "-" ++
    String.ofList ((digits.drop 8).take 4) ++ "-8" ++
    String.ofList ((digits.drop 12).take 3) ++ "-8" ++
    String.ofList ((digits.drop 15).take 3) ++ "-" ++
    String.ofList ((digits.drop 18).take 12)

def transcriptMessageCount (t : Transcript) : Nat :=
  t.entries.toList.countP (fun e => match e.payload with
    | .userMsg _ | .assistantMsg _ | .envMsg _ | .otherMsg _ _ => true
    | _ => false)

def transcriptToolCallCount (t : Transcript) : Nat :=
  t.entries.toList.foldl (fun n e => n + match e.payload with
    | .assistantMsg blocks => blocks.countP (fun
        | AssistantBlock.toolCall _ _ _ => true | _ => false)
    | _ => 0) (0 : Nat)

def transcriptToolResultCount (t : Transcript) : Nat :=
  t.entries.toList.foldl (fun n e => n + match e.payload with
    | .envMsg blocks => blocks.countP (fun
        | EnvBlock.toolResult _ _ _ => true | _ => false)
    | _ => 0) (0 : Nat)


/-- Explicit target metadata never changes the source EnvInfo. -/
def applyCommonCliOverrides (opts : CliOptions) (t : Transcript) : Transcript :=
  let origin := applyTargetExtra (clearTargetConfiguration t.origin) "target_cwd" opts.cwd
  let origin := applyTargetExtra origin "target_provider" opts.provider
  let origin := applyTargetExtra origin "target_model" opts.model
  let origin := applyTargetExtra origin "target_session_id" opts.sessionId
  let origin := applyTargetExtra origin "target_timestamp" opts.targetTimestamp
  let origin := applyTargetExtra origin "target_harness_version" opts.harnessVersion
  let origin := setOriginExtra origin "allow_empty_dialogue" (Lean.Json.bool opts.allowEmptyDialogue)
  { t with origin }

def continuationDefaults (source : Transcript) (opts : CliOptions) : CliOptions :=
  { opts with
    cwd := opts.cwd.orElse (fun _ => source.env.cwd)
    sessionId := opts.sessionId.orElse (fun _ => source.env.sessionId)
    targetTimestamp := opts.targetTimestamp.orElse (fun _ => latestRecordedIso? source) }

inductive ImportMode where
  | full | active | tsParity
  deriving DecidableEq, Repr

structure SidecarPublishSuccess where
  warnings : List String := []

/-- Counts refer to what the destination artifact actually stores. -/
structure ExportCounts where
  messages : Nat
  nativeCalls : Nat
  historicalCalls : Nat := 0
  nativeResults : Nat
  historicalResults : Nat := 0
  openNativeCalls : Nat
  addTransformedCalls : Bool := true
  addTransformedResults : Bool := true
  assistantContext : Option Nat := none
  assistantCarriers : Option Nat := none
  resumable : Option Bool := none

def defaultExportCounts (t : Transcript) : ExportCounts := {
  messages := transcriptMessageCount t
  nativeCalls := transcriptToolCallCount t
  nativeResults := transcriptToolResultCount t
  openNativeCalls := (Loom.Ops.openCalls t).length }

/-- Runtime behaviour is indexed by the existing Format sum. The expressiveness
matrix in Loom.supports remains its own exhaustive match. Adapter modules own
instances; Registry is the only runtime dispatcher. -/
class Spec (format : Format) where
  importText : ImportMode → String → Except String Transcript
  exportChecked? : Option (Transcript → Except String String) := none
  preflight : Transcript → Except String Unit := fun _ => .ok ()
  sidecarExport? : Option (System.FilePath → Transcript → IO (Except String SidecarPublishSuccess)) := none
  preservesThreads : Bool := false
  /-- Native-store reads may recover sidecars or omitted IDE results. Codex has
  no file hook: every conversion must go through the chosen importText mode. -/
  importFile? : Bool → Option (String → IO (Except String Transcript)) := fun _ => none
  validateCli : CliOptions → Option String := fun opts =>
    if hasAnyCodexControlOption opts then
      some "--target-codex-* options are valid only when the target is codex" else none
  applyCli : CliOptions → Transcript → Transcript := fun _ t => t
  defaults : Transcript → CliOptions → CliOptions := fun _ opts => opts
  prepare : Transcript → Transcript × Nat × Nat := fun t => (t, 0, 0)
  rawNativeHistoryEligible : Transcript → Nat → Nat → Bool := fun _ _ _ => false
  nativeHistoryBlocker? : Transcript → Option String := fun _ => none
  counts : Transcript → ExportCounts := defaultExportCounts
  inertBytes? : Option (String → Nat) := none
  displayName : String := formatToWireString format

/-- The archive target is a CLI use of Format.other, not a new IR constructor. -/
def loomArchiveFormat : Format := .other "loom"

def isArchiveFormat (format : Format) : Bool := format == loomArchiveFormat

end LoomConvert
