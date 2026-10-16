import LoomConvert
import LoomOps.Conversion

/-!
# CLI format dispatch and validation

Pure format detection, import/export routing, and flat-export preflight.
These declarations retain their existing names for callers that import Main.
Target-context selection and CLI overrides belong to Main; this module does
not decide which Codex context a continuation should import.
-/

open Loom LoomConvert

/-- CLI source/target string → format row, for export-readiness checks. -/
def formatByCliName? (fmt : String) : Option Format :=
  match fmt with
  | "pi"                        => some .pi
  | "claude"                    => some .claudeCode
  | "codex"                     => some .codexCli
  | "cursor-agent"              => some .cursorAgent
  | "hermes"                    => some .hermes
  | "gais" | "google-ai-studio" => some .googleAiStudio
  | "cursor-ide"                => some .cursorIde
  | "opencode"                  => some .openCode
  | _                           => none

/-- Single-file flat exporters write only the main thread. Sidechain/detached
threads are preserved by the `loom` wire target, not by these flat targets. -/
def hasNonMainThreads (t : Transcript) : Bool :=
  t.threads.toList.any (fun th =>
    match th.kind with
    | ThreadKind.main => false
    | _ => true)

/-- The header describes the outer runner. A recorded inner failure takes
precedence, so `Script completed` alone never contradicts a nonzero inner exit. -/
def contradictoryErrorFlag (flag : Bool) (content : List UserBlock)
    (signal : ErrorSignal) (commands : Array Lean.Json := #[]) : Bool :=
  flag && ((match signal with | .heuristic _ _ => true | _ => false) ||
    match codexToolOutputErrorSignal content commands with
    | .structured false _ => true
    | _ => false)

private def continuationErrorFlag (target : String) : ErrorSignal → Bool :=
  match target with
  | "claude" => errorBool
  | "pi" => piErrorBool
  | "opencode" => openCodeErrorBool
  | _ => ErrorSignal.failureFlag

def contradictoryErrorBlocker? (target : String) (t : Transcript) : Option String :=
  if target == "loom" then none else Id.run do
    for (entry, index) in t.entries.toList.zipIdx do
      if let .envMsg blocks := entry.payload then
        let commands := (entry.origin.extras >>= fun extras =>
          (extras.getObjVal? "codex_command_completions" >>= Lean.Json.getArr?).toOption).getD #[]
        for block in blocks do
          if let .toolResult call content signal := block then
            if contradictoryErrorFlag (continuationErrorFlag target signal) content signal commands then
              let id := (callRefToolUseId t call).getD "<unresolved>"
              let evidence := match signal with
                | .heuristic _ method => s!"heuristic '{method}' cannot assert a native error"
                | _ => s!"{reprStr (codexToolOutputErrorSignal content commands)} records success"
              return some s!"contradictory error flag at entry {index}, tool-use id '{id}': {evidence}"
    return none

example : contradictoryErrorFlag true [.text "Script completed\nOutput:\nok"]
    (.native true) = true := by native_decide
example : contradictoryErrorFlag true [.text "Script completed\nOutput:\n",
    .text "{\"exit_code\":9}"] (.structured true "exit_code") = false := by native_decide
example : contradictoryErrorFlag true [.text "printed timeout"]
    (.heuristic true "guess") = true := by native_decide
example : contradictoryErrorFlag false [.text "printed timeout"]
    (.heuristic true "guess") = false := by native_decide

def targetValidityBlocker? (toFmt : String) (t : Transcript) : Option String :=
  (contradictoryErrorBlocker? toFmt t).orElse (fun _ =>
  let failure? := match toFmt with
    | "pi" => match piExportPreflight t with
      | .ok _ => none
      | .error error => some error
    | "claude" => match claudeExportPreflight t with
      | .ok _ => none
      | .error error => some error
    | "codex" => (codexTargetExportPrerequisiteFailures t).head?
    | "cursor-agent" => match LoomConvert.exportCursorAgentTargetChecked t with
      | .ok _ => none
      | .error error => some error
    | "opencode" => (openCodeTargetExportPrerequisiteFailures t).head?
    | _ => none
  failure?.map (fun error => s!"target '{toFmt}' validity preflight failed: {error}"))

/-- Losses that the current executable refuses rather than silently flattening.
Stable/default flat-export scope is mainline-only: even targets whose broader
format can store sidechains need a multi-file/sidecar exporter before this CLI
can promise native resumable sidechain output. -/
def exportBlocker? (toFmt : String) (t : Transcript) : Option String :=
  if toFmt == "loom" then
    none
  else if hasNonMainThreads t then
    some "single-file flat exporter does not preserve sidechain/detached thread metadata — refusing silent flattening; use `loom` or an explicit sidecar export"
  else
    match formatByCliName? toFmt with
    | none => none
    | some target =>
      let destructive := (Loom.Ops.obligations target t).filter
        (Loom.Ops.obligationIsDestructiveFor target t)
      let semanticBlocker := if destructive.isEmpty then none
        else some s!"target '{toFmt}' has destructive export obligations: {reprStr destructive} — refusing silent loss; use the loom wire target to preserve the full transcript"
      semanticBlocker.orElse (fun _ => targetValidityBlocker? toFmt t)

/-- Source format → Loom IR. Every importer the fan-out produced. -/
def importByFormat (fmt text : String) : Except String Transcript :=
  match fmt with
  | "loom"                      => importLoomWire text
  | "pi"                        => importPi text
  | "claude"                    => importClaudeCode text
  | "codex"                     => importCodexCli text
  | "cursor-agent"              => importCursorAgent text
  | "hermes"                    => importHermes text
  | "gais" | "google-ai-studio" => importGoogleAiStudio text
  | "cursor-ide"                => importCursorIde text  -- text = {composer,bubbles} JSON
  | "opencode"                  => importOpenCode text
  | _ => .error s!"unknown source format: {fmt}"

/-- Loom IR → target format text. `loom` is the versioned, thread-preserving
wire form; the others are flat harness targets. -/
def exportByFormat (fmt : String) (t : Transcript) : Except String String :=
  match fmt with
  | "pi"           => exportPiChecked t
  | "loom"         => .ok (exportLoomWire t)
  | "claude"       => exportClaudeCodeChecked t
  | "codex"        => exportCodexCliChecked t
  | "cursor-agent" => LoomConvert.exportCursorAgentTargetChecked t
  | "opencode"     => exportOpenCodeChecked t
  | _ => .error s!"no exporter for target '{fmt}' (exporters: loom, pi, claude, codex, cursor-agent, opencode)"

/-- Import → (well-formedness + hard export-obligation checks) → export. Refuses
to emit a structurally invalid IR, or a stitched sidechain transcript through a
flat exporter that would silently drop thread anchors. -/
def runPipeline (_fromFmt toFmt : String) (t : Transcript) : Except String String := do
  let vs := violations t
  if vs.length > 0 then
    .error s!"source imported to a malformed IR ({vs.length} violations) — refusing to export"
  else if let some blocker := exportBlocker? toFmt t then
    .error blocker
  else
    exportByFormat toFmt t

private def jsonString? (json : Lean.Json) (key : String) : Option String :=
  (json.getObjVal? key >>= Lean.Json.getStr?).toOption

private def jsonValue? (json : Lean.Json) (key : String) : Option Lean.Json :=
  (json.getObjVal? key).toOption

private def detectionRecords (text : String) : Except String (List Lean.Json) := do
  match Lean.Json.parse text with
  | .ok document => pure [document]
  | .error _ =>
      let lines := (text.splitOn "\n").filter (fun line => !line.trimAscii.isEmpty)
      if lines.isEmpty then .error "empty input"
      else
        lines.zipIdx.mapM (fun (line, index) =>
          match Lean.Json.parse line with
          | .ok value => pure value
          | .error error =>
              .error s!"malformed JSONL at line {index + 1}: {error}")

private def hasEnvelopeField (record : Lean.Json) (key : String) : Bool :=
  (jsonValue? record key).isSome

private def looksLikeClaudeRecord (record : Lean.Json) : Bool :=
  let hasIdentity := hasEnvelopeField record "uuid" ||
    hasEnvelopeField record "parentUuid" ||
    (jsonString? record "sessionId").isSome
  jsonString? record "type" == some "file-history-snapshot" ||
    ((jsonString? record "type").isSome && hasIdentity)

private def looksLikeCursorAgentRecord (record : Lean.Json) : Bool :=
  let messageLike := (jsonValue? record "message").isSome &&
    ((jsonString? record "role").isSome ||
      ["user", "assistant"].contains ((jsonString? record "type").getD ""))
  messageLike && !hasEnvelopeField record "uuid" &&
    !hasEnvelopeField record "parentUuid"

/-- Detect from structured envelope fields inside Lean. This is intentionally
part of the semantic core: the host launcher never reads transcript bytes. -/
def detectFormat (text : String) : Except String String := do
  let records ← detectionRecords text
  let first ← match records.head? with
    | some record => pure record
    | none => .error "empty input"
  if jsonString? first "schema" == some "loom.transcript.v0" then .ok "loom"
  else if (jsonValue? first "info").isSome &&
      (jsonValue? first "messages").isSome &&
      ((jsonValue? first "info").bind (fun info => jsonString? info "id")).isSome &&
      ((jsonValue? first "info").bind (fun info => jsonString? info "version")).isSome
    then .ok "opencode"
  else if (jsonValue? first "composer").isSome &&
      (jsonValue? first "bubbles").isSome then .ok "cursor-ide"
  else if (jsonValue? first "chunkedPrompt").isSome then .ok "gais"
  else if (jsonString? first "session_id").isSome &&
      (jsonValue? first "messages").isSome then .ok "hermes"
  else if jsonString? first "type" == some "session" then .ok "pi"
  else
    let labels :=
      (if records.any (fun record =>
          jsonString? record "type" == some "session_meta") then ["codex"] else []) ++
      (if records.any looksLikeClaudeRecord then ["claude"] else []) ++
      (if records.any looksLikeCursorAgentRecord then ["cursor-agent"] else [])
    match labels with
    | [format] => .ok format
    | [] => .error "unrecognized transcript envelope"
    | _ => .error s!"ambiguous transcript envelope: {String.intercalate ", " labels}"

private def detectsAs (expected source : String) : Bool :=
  match detectFormat source with
  | .ok actual => actual == expected
  | .error _ => false

private def detectionRejects (source : String) : Bool :=
  match detectFormat source with
  | .error _ => true
  | .ok _ => false

example : detectsAs "claude"
    ("{\"type\":\"permission-mode\",\"sessionId\":\"S\"}\n" ++
     "{\"type\":\"user\",\"uuid\":\"u\",\"parentUuid\":null," ++
       "\"sessionId\":\"S\",\"message\":{\"role\":\"user\",\"content\":\"hi\"}}\n") =
    true := by native_decide

example : detectsAs "cursor-agent"
    "{\"role\":\"user\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}}\n" =
    true := by native_decide

example : detectsAs "cursor-ide"
    "{\"composer\":{\"composerId\":\"c\"},\"bubbles\":[]}" = true := by
  native_decide

example : detectsAs "opencode"
    "{\"info\":{\"id\":\"ses_x\",\"version\":\"1.1.34\"},\"messages\":[]}" = true := by
  native_decide

example : detectionRejects
    ("{\"type\":\"user\",\"uuid\":\"u\",\"sessionId\":\"S\",\"message\":{}}\n" ++
     "{\"role\":\"user\",\"message\":{}}\n") = true := by native_decide

example : detectionRejects
    ("{\"type\":\"session\",\"id\":\"S\"}\n{not-json}\n") = true := by
  native_decide
