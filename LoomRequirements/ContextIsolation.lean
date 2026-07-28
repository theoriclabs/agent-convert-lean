import LoomRequirements.AgentConvert
import LoomConvert.Pi
import LoomConvert.ClaudeCode
import LoomConvert.CodexCli
import LoomConvert.CursorAgent
import LoomConvert.Hermes
import LoomConvert.GoogleAiStudio
import LoomConvert.CursorIde
import LoomConvert.Wire

/-!
# F-032 internal context-isolation census

This module is deliberately fixture-bound. It checks the current public Lean
importers over synthetic, structure-only source artifacts; it does not claim
that an external harness emitted or accepted any fixture. It discharges only
F-032's synthetic internal-fixture obligation; it does not discharge F-030,
F-031, F-033, R-018 external validation, or release status.

Each vendor fixture mixes ordinary user/model dialogue with all control-plane
families accepted by that import boundary. A family passes only through typed
payload inspection plus exact JSON retention of the complete fixture source
record used as its witness; retaining only a nested payload is not full-source
evidence. Labels and text substrings are never sufficient evidence. Loom wire
has its own explicit row with no harness role vocabulary: it serializes the IR
and is not an eighth vendor harness.
-/

namespace AgentConvert.Requirements

open Loom LoomConvert
open Lean (Json)

private def jsonField? (value : Json) (key : String) : Option Json :=
  (value.getObjVal? key).toOption

private def jsonString? (value : Json) (key : String) : Option String :=
  (value.getObjVal? key >>= Json.getStr?).toOption

private def jsonArray? (value : Json) (key : String) : Option (Array Json) :=
  (value.getObjVal? key >>= Json.getArr?).toOption

private def jsonLines (records : List Json) : String :=
  String.intercalate "\n" (records.map Json.compress) ++ "\n"

private def textBlock (kind text : String) : Json :=
  Json.mkObj [("type", Json.str kind), ("text", Json.str text)]

private def transcriptExtra? (transcript : Transcript) (key : String) : Option Json :=
  transcript.origin.extras >>= fun extras => jsonField? extras key

private def transcriptExtraArray?
    (transcript : Transcript) (key : String) : Option (Array Json) :=
  transcript.origin.extras >>= fun extras => jsonArray? extras key

private def entryExtra? (entry : Entry) (key : String) : Option Json :=
  entry.origin.extras >>= fun extras => jsonField? extras key

private def entriesRetainRaw
    (transcript : Transcript) (key : String) (expected : List Json) : Bool :=
  transcript.entries.size == expected.length &&
    (transcript.entries.toList.zip expected).all fun (entry, raw) =>
      entryExtra? entry key == some raw

private def archiveRaws
    (transcript : Transcript) (arrayKey rawKey : String) : Option (List Json) := do
  let values <- transcriptExtraArray? transcript arrayKey
  values.toList.mapM fun value => jsonField? value rawKey

private def entryRetainsExactRaw
    (transcript : Transcript) (key : String) (raw : Json) : Bool :=
  transcript.entries.toList.any fun entry => entryExtra? entry key == some raw

private def archiveRetainsExactRaw
    (transcript : Transcript) (arrayKey rawKey : String) (raw : Json) : Bool :=
  (archiveRaws transcript arrayKey rawKey).any fun raws => raws.contains raw

private def extraArrayRetainsExactRaw
    (transcript : Transcript) (key : String) (raw : Json) : Bool :=
  (transcriptExtraArray? transcript key).any fun raws =>
    raws.toList.contains raw

private def contentSkippedCount (transcript : Transcript) : Nat :=
  transcript.importNotes.countP fun note => note.kind == .contentSkipped

private inductive DialogueAtom where
  | userText (text : String)
  | assistantText (text : String)
  deriving Repr, DecidableEq

private def dialogueAtoms (transcript : Transcript) : List DialogueAtom :=
  transcript.entries.toList.flatMap fun entry =>
    match entry.payload with
    | .userMsg blocks => blocks.filterMap fun
        | .text text => some (.userText text)
        | _ => none
    | .assistantMsg blocks => blocks.filterMap fun
        | .text text => some (.assistantText text)
        | _ => none
    | _ => []

private def dialogueEntryCount (transcript : Transcript) : Nat :=
  transcript.entries.toList.countP fun entry =>
    match entry.payload with
    | .userMsg _ | .assistantMsg _ => true
    | _ => false

private def dialogueContainsOnlyText (transcript : Transcript) : Bool :=
  transcript.entries.toList.all fun entry =>
    match entry.payload with
    | .userMsg blocks => blocks.all fun
        | .text _ => true
        | _ => false
    | .assistantMsg blocks => blocks.all fun
        | .text _ => true
        | _ => false
    | _ => true

private def hasExactOtherMessage
    (transcript : Transcript) (role : String) (raw : Json) : Bool :=
  transcript.entries.toList.any fun entry =>
    match entry.payload with
    | .otherMsg actualRole [.unmodeled label actualRaw] =>
        actualRole == role && label == role && actualRaw == raw
    | _ => false

private def hasExactCustomEvent
    (transcript : Transcript) (label : String) (raw : Json) : Bool :=
  transcript.entries.toList.any fun entry =>
    match entry.payload with
    | .event (.custom actualLabel actualRaw) =>
        actualLabel == label && actualRaw == raw
    | _ => false

private def hasModelChange
    (transcript : Transcript) (previous next : Option String) : Bool :=
  transcript.entries.toList.any fun entry =>
    match entry.payload with
    | .event (.modelChange actualPrevious actualNext) =>
        actualPrevious == previous && actualNext == next
    | _ => false

private def hasThinkingLevelChange
    (transcript : Transcript) (previous next : Option String) : Bool :=
  transcript.entries.toList.any fun entry =>
    match entry.payload with
    | .event (.thinkingLevelChange actualPrevious actualNext) =>
        actualPrevious == previous && actualNext == next
    | _ => false

private def noDuplicates {alpha : Type} [DecidableEq alpha]
    (values : List alpha) : Bool :=
  decide values.Nodup

/-! ## Pi -/

private def piTimestamp : String := "2026-07-21T00:00:00.000Z"

private def piHeader : Json := Json.mkObj [
  ("type", Json.str "session"),
  ("version", Json.num 3),
  ("id", Json.str "f032-pi"),
  ("timestamp", Json.str piTimestamp),
  ("cwd", Json.str "/f032/pi"),
  ("instructions", Json.str "pi header instruction"),
  ("configuration", Json.mkObj [
    ("permissionMode", Json.str "read-only"),
    ("runtime", Json.str "fixture")])]

private def piEntry (kind id : String) (parent : Option String)
    (fields : List (Prod String Json)) : Json :=
  Json.mkObj ([("type", Json.str kind), ("id", Json.str id),
    ("parentId", parent.map Json.str |>.getD Json.null),
    ("timestamp", Json.str piTimestamp)] ++ fields)

private def piOpenRoleMessage (role text : String) : Json := Json.mkObj [
  ("role", Json.str role),
  ("content", Json.arr #[textBlock "text" text]),
  ("timestamp", Json.num 1784592000000)]

private def piUserMessage : Json := piOpenRoleMessage "user"
  "Quoted <system>literal</system> remains a Pi user turn."

private def piDeveloperMessage : Json :=
  piOpenRoleMessage "developer" "developer control: never dialogue"

private def piSystemMessage : Json :=
  piOpenRoleMessage "system" "system instruction: never dialogue"

private def piPermissionMessage : Json :=
  piOpenRoleMessage "permission" "permission policy: never dialogue"

private def piRuntimeMessage : Json := Json.mkObj [
  ("role", Json.str "bashExecution"),
  ("command", Json.str "pwd"),
  ("output", Json.str "/f032/pi"),
  ("exitCode", Json.num 0),
  ("cancelled", Json.bool false),
  ("truncated", Json.bool false),
  ("excludeFromContext", Json.bool true),
  ("timestamp", Json.num 1784592000000)]

private def piFutureMessage : Json :=
  piOpenRoleMessage "future-control-role" "future role: never dialogue"

private def piAssistantMessage : Json := Json.mkObj [
  ("role", Json.str "assistant"),
  ("content", Json.arr #[textBlock "text" "Pi assistant answer."]),
  ("api", Json.str "anthropic-messages"),
  ("provider", Json.str "fixture-provider"),
  ("model", Json.str "fixture-model"),
  ("usage", Json.mkObj [
    ("input", Json.num 1), ("output", Json.num 1),
    ("cacheRead", Json.num 0), ("cacheWrite", Json.num 0),
    ("totalTokens", Json.num 2),
    ("cost", Json.mkObj [
      ("input", Json.num 0), ("output", Json.num 0),
      ("cacheRead", Json.num 0), ("cacheWrite", Json.num 0),
      ("total", Json.num 0)])]),
  ("stopReason", Json.str "stop"),
  ("timestamp", Json.num 1784592000000)]

private def piUserRecord : Json :=
  piEntry "message" "pi-user" none [("message", piUserMessage)]

private def piDeveloperRecord : Json :=
  piEntry "message" "pi-developer" (some "pi-user")
    [("message", piDeveloperMessage)]

private def piSystemRecord : Json :=
  piEntry "message" "pi-system" (some "pi-developer")
    [("message", piSystemMessage)]

private def piPermissionRecord : Json :=
  piEntry "message" "pi-permission" (some "pi-system")
    [("message", piPermissionMessage)]

private def piRuntimeRecord : Json :=
  piEntry "message" "pi-runtime" (some "pi-permission")
    [("message", piRuntimeMessage)]

private def piFutureRecord : Json :=
  piEntry "message" "pi-future" (some "pi-runtime")
    [("message", piFutureMessage)]

private def piModelRecord : Json :=
  piEntry "model_change" "pi-model" (some "pi-future") [
    ("provider", Json.str "fixture-provider"),
    ("modelId", Json.str "fixture-model-next"),
    ("previousModelId", Json.str "fixture-model")]

private def piHarnessEventRecord : Json :=
  piEntry "future_harness_event" "pi-event" (some "pi-model") [
    ("payload", Json.mkObj [("phase", Json.str "checkpoint")])]

private def piAssistantRecord : Json :=
  piEntry "message" "pi-assistant" (some "pi-event")
    [("message", piAssistantMessage)]

def contextIsolationPiFixture : String := jsonLines [
  piHeader, piUserRecord, piDeveloperRecord, piSystemRecord,
  piPermissionRecord, piRuntimeRecord, piFutureRecord, piModelRecord,
  piHarnessEventRecord, piAssistantRecord]

private def piExactSourceRecords : List Json := [
  piUserRecord, piDeveloperRecord, piSystemRecord, piPermissionRecord,
  piRuntimeRecord, piFutureRecord, piModelRecord, piHarnessEventRecord,
  piAssistantRecord]

private def piConversationCheck (transcript : Transcript) : Bool :=
  dialogueEntryCount transcript == 2 && dialogueContainsOnlyText transcript &&
    dialogueAtoms transcript == [
      .userText "Quoted <system>literal</system> remains a Pi user turn.",
      .assistantText "Pi assistant answer."]

private def piExactRetentionCheck (transcript : Transcript) : Bool :=
  transcriptExtra? transcript "piRaw" == some piHeader &&
    entriesRetainRaw transcript "piRaw" piExactSourceRecords

def contextIsolationPiCheck : Bool :=
  match importPi contextIsolationPiFixture with
  | .error _ => false
  | .ok transcript =>
      piConversationCheck transcript &&
      hasExactOtherMessage transcript "developer" piDeveloperMessage &&
      hasExactOtherMessage transcript "system" piSystemMessage &&
      hasExactOtherMessage transcript "permission" piPermissionMessage &&
      hasExactOtherMessage transcript "bashExecution" piRuntimeMessage &&
      hasExactOtherMessage transcript "future-control-role" piFutureMessage &&
      hasModelChange transcript (some "fixture-model")
        (some "fixture-model-next") &&
      hasExactCustomEvent transcript "future_harness_event"
        piHarnessEventRecord &&
      piExactRetentionCheck transcript &&
      (violations transcript).isEmpty

/-! ## Claude Code -/

private def claudeSessionId : String :=
  "00000000-0000-0000-0000-000000000032"

private def claudeUuid (suffix : String) : String :=
  "00000000-0000-0000-0000-" ++ suffix

private def claudeParentJson : Option String -> Json
  | some value => Json.str value
  | none => Json.null

private def claudeConversationRecord (kind role uuid : String)
    (parent : Option String) (second : Nat) (content : Json)
    (isMeta : Bool := false) : Json :=
  Json.mkObj [
    ("type", Json.str kind), ("uuid", Json.str uuid),
    ("parentUuid", claudeParentJson parent),
    ("sessionId", Json.str claudeSessionId),
    ("cwd", Json.str "/f032/claude"),
    ("timestamp", Json.str s!"2026-07-21T00:00:0{second}.000Z"),
    ("isSidechain", Json.bool false), ("isMeta", Json.bool isMeta),
    ("message", Json.mkObj [
      ("role", Json.str role), ("content", content)])]

private def claudeSystemRecord (subtype uuid : String)
    (parent : String) (second : Nat) (content : String) : Json :=
  Json.mkObj [
    ("type", Json.str "system"), ("subtype", Json.str subtype),
    ("uuid", Json.str uuid), ("parentUuid", Json.str parent),
    ("sessionId", Json.str claudeSessionId),
    ("cwd", Json.str "/f032/claude"),
    ("timestamp", Json.str s!"2026-07-21T00:00:0{second}.000Z"),
    ("content", Json.str content)]

private def claudeUserId := claudeUuid "000000000001"
private def claudeSystemId := claudeUuid "000000000002"
private def claudeDeveloperId := claudeUuid "000000000003"
private def claudePolicyId := claudeUuid "000000000004"
private def claudeRuntimeId := claudeUuid "000000000005"
private def claudeAssistantId := claudeUuid "000000000006"

private def claudeUserRecord : Json :=
  claudeConversationRecord "user" "user" claudeUserId none 1
    (Json.arr #[textBlock "text"
      "Quoted <system-reminder>literal</system-reminder> remains dialogue."])

private def claudeInstructionRecord : Json :=
  claudeSystemRecord "instructions" claudeSystemId claudeUserId 2
    "system instructions: never dialogue"

private def claudeDeveloperRecord : Json :=
  claudeConversationRecord "user" "developer" claudeDeveloperId
    (some claudeSystemId) 3
    (Json.arr #[textBlock "text" "developer control: never dialogue"])

private def claudePolicyRecord : Json :=
  claudeSystemRecord "policy" claudePolicyId claudeDeveloperId 4
    "policy control: never dialogue"

private def claudeRuntimeText : String := "<bash-input>pwd</bash-input>"

private def claudeRuntimeRecord : Json :=
  claudeConversationRecord "user" "user" claudeRuntimeId
    (some claudePolicyId) 5 (Json.str claudeRuntimeText) true

private def claudeAssistantRecord : Json :=
  claudeConversationRecord "assistant" "assistant" claudeAssistantId
    (some claudeRuntimeId) 6
    (Json.arr #[textBlock "text" "Claude assistant answer."])

private def claudePermissionRecord : Json := Json.mkObj [
  ("type", Json.str "permission-mode"),
  ("sessionId", Json.str claudeSessionId),
  ("mode", Json.str "plan"),
  ("permissionSource", Json.str "f032")]

private def claudeConfigurationRecord : Json := Json.mkObj [
  ("type", Json.str "mode"),
  ("sessionId", Json.str claudeSessionId),
  ("mode", Json.str "acceptEdits"),
  ("configuration", Json.mkObj [("source", Json.str "f032")])]

private def claudeFutureRecord : Json := Json.mkObj [
  ("type", Json.str "future-control-state"),
  ("sessionId", Json.str claudeSessionId),
  ("payload", Json.mkObj [("opaque", Json.bool true)])]

private def claudeHarnessEventRecord : Json := Json.mkObj [
  ("type", Json.str "queue-operation"),
  ("sessionId", Json.str claudeSessionId),
  ("operation", Json.str "enqueue"),
  ("eventId", Json.str "f032-event")]

def contextIsolationClaudeCodeFixture : String := jsonLines [
  claudeUserRecord, claudeInstructionRecord, claudeDeveloperRecord,
  claudePolicyRecord, claudeRuntimeRecord, claudeAssistantRecord,
  claudePermissionRecord, claudeConfigurationRecord, claudeFutureRecord,
  claudeHarnessEventRecord]

private def claudeExpectedInertRecords : List Json := [
  claudeInstructionRecord, claudeDeveloperRecord, claudePolicyRecord,
  claudePermissionRecord, claudeConfigurationRecord, claudeFutureRecord,
  claudeHarnessEventRecord]

private def claudeConversationCheck (transcript : Transcript) : Bool :=
  dialogueEntryCount transcript == 2 && dialogueContainsOnlyText transcript &&
    dialogueAtoms transcript == [
      .userText
        "Quoted <system-reminder>literal</system-reminder> remains dialogue.",
      .assistantText "Claude assistant answer."]

private def claudeConversationExactRetentionCheck
    (transcript : Transcript) : Bool :=
  (transcript.entries.toList.any fun entry =>
    match entry.payload with
    | .userMsg _ =>
        entryExtra? entry "claudeRawEnvelope" == some claudeUserRecord
    | _ => false) &&
  (transcript.entries.toList.any fun entry =>
    match entry.payload with
    | .assistantMsg _ =>
        entryExtra? entry "claudeRawEnvelope" == some claudeAssistantRecord
    | _ => false)

private def claudeExactRetentionCheck (transcript : Transcript) : Bool :=
  claudeConversationExactRetentionCheck transcript &&
    archiveRaws transcript "raw_control_messages" "record" ==
      some [claudeRuntimeRecord] &&
    archiveRaws transcript "raw_inert_records" "raw" ==
      some claudeExpectedInertRecords &&
    contentSkippedCount transcript == 8

def contextIsolationClaudeCodeCheck : Bool :=
  match importClaudeCode contextIsolationClaudeCodeFixture with
  | .error _ => false
  | .ok transcript =>
      claudeConversationCheck transcript &&
      (archiveRaws transcript "raw_inert_records" "raw").any fun raws =>
        raws.contains claudeDeveloperRecord &&
        raws.contains claudeInstructionRecord &&
        raws.contains claudePolicyRecord &&
        raws.contains claudePermissionRecord &&
        raws.contains claudeConfigurationRecord &&
        raws.contains claudeFutureRecord &&
        raws.contains claudeHarnessEventRecord &&
        claudeExactRetentionCheck transcript &&
        (violations transcript).isEmpty

/-! ## Codex CLI -/

private def codexMessageRecord (role : String) (content : Array Json) : Json :=
  Json.mkObj [
    ("type", Json.str "response_item"),
    ("payload", Json.mkObj [
      ("type", Json.str "message"), ("role", Json.str role),
      ("content", Json.arr content)])]

private def codexHeader : Json := Json.mkObj [
  ("type", Json.str "session_meta"),
  ("timestamp", Json.str "2026-07-21T00:00:00.000Z"),
  ("payload", Json.mkObj [
    ("id", Json.str "f032-codex"),
    ("cwd", Json.str "/f032/codex"),
    ("cli_version", Json.str "0.144.1"),
    ("originator", Json.str "codex-tui"),
    ("model_provider", Json.str "fixture-provider"),
    ("instructions", Json.str "codex system instructions"),
    ("configuration", Json.mkObj [("profile", Json.str "f032")])])]

/- The leading header is mandatory Codex framing and is projected as its exact
payload. A later accepted `session_meta` is the full-source family witness:
the importer archives that complete record both as a non-dialogue record and
inside its positional session-boundary provenance. -/
private def codexSessionMetaBoundaryRecord : Json := Json.mkObj [
  ("type", Json.str "session_meta"),
  ("timestamp", Json.str "2026-07-21T00:00:00.500Z"),
  ("payload", Json.mkObj [
    ("id", Json.str "f032-codex"),
    ("cwd", Json.str "/f032/codex"),
    ("instructions", Json.str "codex system instructions"),
    ("configuration", Json.mkObj [
      ("profile", Json.str "f032-boundary")])])]

private def codexControlEnvelope : String :=
  "<environment_context>\n<cwd>/f032/codex</cwd>\n</environment_context>"

private def codexCollisionText : String :=
  "Quoted <environment_context>literal</environment_context> remains dialogue."

private def codexUserRecord : Json := codexMessageRecord "user" #[
  textBlock "input_text" "Codex user question.",
  textBlock "input_text" codexControlEnvelope,
  textBlock "input_text" codexCollisionText]

private def codexDeveloperRecord : Json := codexMessageRecord "developer" #[
  textBlock "input_text" "developer control: never dialogue"]

private def codexSystemRecord : Json := codexMessageRecord "system" #[
  textBlock "input_text" "system control: never dialogue"]

private def codexPolicyRecord : Json := codexMessageRecord "policy" #[
  textBlock "input_text" "policy control: never dialogue"]

private def codexFutureRoleRecord : Json := codexMessageRecord "future-role" #[
  textBlock "input_text" "future control: never dialogue"]

private def codexTurnContextRecord : Json := Json.mkObj [
  ("type", Json.str "turn_context"),
  ("payload", Json.mkObj [
    ("approval_policy", Json.str "never"),
    ("sandbox_policy", Json.mkObj [("type", Json.str "read-only")]),
    ("model", Json.str "fixture-model"),
    ("cwd", Json.str "/f032/codex"),
    ("summary", Json.str "auto")])]

private def codexUnknownRecord : Json := Json.mkObj [
  ("type", Json.str "future_top_level_control"),
  ("payload", Json.mkObj [("opaque", Json.arr #[Json.num 1, Json.bool true])])]

private def codexHarnessEventPayload : Json := Json.mkObj [
  ("type", Json.str "token_count"),
  ("state", Json.str "checkpoint"),
  ("opaque", Json.bool true)]

private def codexHarnessEventRecord : Json := Json.mkObj [
  ("type", Json.str "event_msg"),
  ("payload", codexHarnessEventPayload)]

private def codexAssistantRecord : Json := codexMessageRecord "assistant" #[
  textBlock "output_text" "Codex assistant answer."]

def contextIsolationCodexCliFixture : String := jsonLines [
  codexHeader, codexSessionMetaBoundaryRecord, codexUserRecord,
  codexDeveloperRecord, codexSystemRecord, codexPolicyRecord,
  codexFutureRoleRecord, codexTurnContextRecord, codexUnknownRecord,
  codexHarnessEventRecord, codexAssistantRecord]

private def codexExpectedControls : List Json := [
  codexUserRecord, codexDeveloperRecord, codexSystemRecord, codexPolicyRecord,
  codexFutureRoleRecord, codexTurnContextRecord]

private def codexConversationCheck (transcript : Transcript) : Bool :=
  dialogueEntryCount transcript == 2 && dialogueContainsOnlyText transcript &&
    dialogueAtoms transcript == [
      .userText "Codex user question.", .userText codexCollisionText,
      .assistantText "Codex assistant answer."]

private def codexSessionMetaBoundaryRetainedExactly
    (transcript : Transcript) : Bool :=
  archiveRaws transcript "raw_session_boundaries" "record" ==
      some [codexSessionMetaBoundaryRecord] &&
    extraArrayRetainsExactRaw transcript "raw_non_dialogue_records"
      codexSessionMetaBoundaryRecord

private def codexHarnessEventRetainedExactly
    (transcript : Transcript) : Bool :=
  (transcriptExtraArray? transcript "raw_non_dialogue_records").any fun raws =>
    raws.toList.any fun raw =>
      raw == codexHarnessEventRecord &&
      jsonString? raw "type" == some "event_msg" &&
      (jsonField? raw "payload").any fun payload =>
        payload == codexHarnessEventPayload &&
        jsonString? payload "type" == some "token_count"

private def codexExactRetentionCheck (transcript : Transcript) : Bool :=
  transcript.env.instructions == some "codex system instructions" &&
    transcriptExtra? transcript "raw_session_meta_payload" ==
      jsonField? codexHeader "payload" &&
    codexSessionMetaBoundaryRetainedExactly transcript &&
    (transcriptExtraArray? transcript "raw_control_messages").map Array.toList ==
      some codexExpectedControls &&
    (transcriptExtraArray? transcript "raw_non_dialogue_records").map Array.toList ==
      some [codexSessionMetaBoundaryRecord, codexUnknownRecord,
        codexHarnessEventRecord] &&
    codexHarnessEventRetainedExactly transcript &&
    contentSkippedCount transcript == 7

def contextIsolationCodexCliCheck : Bool :=
  match importCodexCli contextIsolationCodexCliFixture with
  | .error _ => false
  | .ok transcript =>
      codexConversationCheck transcript &&
      codexHarnessEventRetainedExactly transcript &&
      codexExactRetentionCheck transcript &&
      (violations transcript).isEmpty

/-! ## Cursor Agent -/

private def cursorAgentMessageRecord (role text : String) : Json := Json.mkObj [
  ("role", Json.str role),
  ("message", Json.mkObj [
    ("content", Json.arr #[textBlock "text" text])])]

private def cursorAgentUserRecord : Json := cursorAgentMessageRecord "user"
  "Quoted <system>literal</system> remains Cursor Agent dialogue."

private def cursorAgentDeveloperRecord : Json :=
  cursorAgentMessageRecord "developer" "developer control: never dialogue"

private def cursorAgentSystemRecord : Json :=
  cursorAgentMessageRecord "system" "system instruction: never dialogue"

private def cursorAgentPolicyRecord : Json :=
  cursorAgentMessageRecord "policy" "policy control: never dialogue"

private def cursorAgentPermissionRecord : Json := Json.mkObj [
  ("type", Json.str "permission_configuration"),
  ("permissionMode", Json.str "read-only"),
  ("configuration", Json.mkObj [("profile", Json.str "f032")])]

private def cursorAgentRuntimeRecord : Json := Json.mkObj [
  ("type", Json.str "turn_ended"),
  ("status", Json.str "error"),
  ("error", Json.str "runtime envelope retained")]

private def cursorAgentFutureRecord : Json :=
  cursorAgentMessageRecord "future-control-role" "future control: never dialogue"

private def cursorAgentHarnessEventRecord : Json := Json.mkObj [
  ("type", Json.str "future_harness_event"),
  ("payload", Json.mkObj [("phase", Json.str "checkpoint")])]

private def cursorAgentAssistantRecord : Json :=
  cursorAgentMessageRecord "assistant" "Cursor Agent assistant answer."

private def cursorAgentRecords : List Json := [
  cursorAgentUserRecord, cursorAgentDeveloperRecord, cursorAgentSystemRecord,
  cursorAgentPolicyRecord, cursorAgentPermissionRecord, cursorAgentRuntimeRecord,
  cursorAgentFutureRecord, cursorAgentHarnessEventRecord,
  cursorAgentAssistantRecord]

def contextIsolationCursorAgentFixture : String :=
  jsonLines cursorAgentRecords

private def cursorAgentConversationCheck (transcript : Transcript) : Bool :=
  dialogueEntryCount transcript == 2 && dialogueContainsOnlyText transcript &&
    dialogueAtoms transcript == [
      .userText
        "Quoted <system>literal</system> remains Cursor Agent dialogue.",
      .assistantText "Cursor Agent assistant answer."]

private def cursorAgentExactRetentionCheck (transcript : Transcript) : Bool :=
  entriesRetainRaw transcript "rawRecord" cursorAgentRecords

def contextIsolationCursorAgentCheck : Bool :=
  match importCursorAgent contextIsolationCursorAgentFixture with
  | .error _ => false
  | .ok transcript =>
      cursorAgentConversationCheck transcript &&
      hasExactCustomEvent transcript "cursor_agent.unknown_role.developer"
        cursorAgentDeveloperRecord &&
      hasExactCustomEvent transcript "cursor_agent.unknown_role.system"
        cursorAgentSystemRecord &&
      hasExactCustomEvent transcript "cursor_agent.unknown_role.policy"
        cursorAgentPolicyRecord &&
      hasExactCustomEvent transcript "cursor_agent.permission_configuration"
        cursorAgentPermissionRecord &&
      hasExactCustomEvent transcript "cursor_agent.turn_ended"
        cursorAgentRuntimeRecord &&
      hasExactCustomEvent transcript "cursor_agent.unknown_role.future-control-role"
        cursorAgentFutureRecord &&
      hasExactCustomEvent transcript "cursor_agent.future_harness_event"
        cursorAgentHarnessEventRecord &&
      cursorAgentExactRetentionCheck transcript &&
      (violations transcript).isEmpty

/-! ## Hermes -/

private def hermesUserRecord : Json := Json.mkObj [
  ("role", Json.str "user"),
  ("content", Json.str
    "Quoted <system>literal</system> remains Hermes dialogue.")]

private def hermesDeveloperRecord : Json := Json.mkObj [
  ("role", Json.str "developer"),
  ("content", Json.str "developer control: never dialogue")]

private def hermesSystemRecord : Json := Json.mkObj [
  ("role", Json.str "system"),
  ("content", Json.str "system control: never dialogue")]

private def hermesPolicyRecord : Json := Json.mkObj [
  ("role", Json.str "policy"),
  ("content", Json.str "policy control: never dialogue")]

private def hermesRuntimeRecord : Json := Json.mkObj [
  ("role", Json.str "runtime-envelope"),
  ("content", Json.str "runtime control: never dialogue"),
  ("runtime", Json.mkObj [("mode", Json.str "fixture")])]

private def hermesFutureRecord : Json := Json.mkObj [
  ("role", Json.str "future-control-role"),
  ("payload", Json.mkObj [("opaque", Json.bool true)])]

private def hermesHarnessEventRecord : Json := Json.mkObj [
  ("role", Json.str "harness-event"),
  ("event", Json.mkObj [("phase", Json.str "checkpoint")])]

private def hermesAssistantRecord : Json := Json.mkObj [
  ("role", Json.str "assistant"),
  ("content", Json.str "Hermes assistant answer.")]

private def hermesMessages : List Json := [
  hermesUserRecord, hermesDeveloperRecord, hermesSystemRecord,
  hermesPolicyRecord, hermesRuntimeRecord, hermesFutureRecord,
  hermesHarnessEventRecord, hermesAssistantRecord]

private def hermesRoot : Json := Json.mkObj [
  ("session_id", Json.str "f032-hermes"),
  ("model", Json.str "fixture-model"),
  ("system_prompt", Json.str "Hermes system instructions"),
  ("tools", Json.arr #[Json.mkObj [
    ("name", Json.str "terminal"),
    ("policy", Json.str "read-only")]]),
  ("runtime_configuration", Json.mkObj [
    ("permissionMode", Json.str "read-only")]),
  ("message_count", Json.num hermesMessages.length),
  ("messages", Json.arr hermesMessages.toArray)]

def contextIsolationHermesFixture : String := hermesRoot.compress

private def hermesConversationCheck (transcript : Transcript) : Bool :=
  dialogueEntryCount transcript == 2 && dialogueContainsOnlyText transcript &&
    dialogueAtoms transcript == [
      .userText "Quoted <system>literal</system> remains Hermes dialogue.",
      .assistantText "Hermes assistant answer."]

private def hermesExactRetentionCheck (transcript : Transcript) : Bool :=
  transcript.env.instructions == some "Hermes system instructions" &&
    transcriptExtra? transcript "hermesRaw" == some hermesRoot &&
    entriesRetainRaw transcript "hermesRaw" hermesMessages

def contextIsolationHermesCheck : Bool :=
  match importHermes contextIsolationHermesFixture with
  | .error _ => false
  | .ok transcript =>
      hermesConversationCheck transcript &&
      hasExactCustomEvent transcript "hermes-unmodeled-message"
        hermesDeveloperRecord &&
      hasExactCustomEvent transcript "hermes-unmodeled-message"
        hermesSystemRecord &&
      hasExactCustomEvent transcript "hermes-unmodeled-message"
        hermesPolicyRecord &&
      hasExactCustomEvent transcript "hermes-unmodeled-message"
        hermesRuntimeRecord &&
      hasExactCustomEvent transcript "hermes-unmodeled-message"
        hermesFutureRecord &&
      hasExactCustomEvent transcript "hermes-unmodeled-message"
        hermesHarnessEventRecord &&
      hermesExactRetentionCheck transcript &&
      (violations transcript).isEmpty

/-! ## Google AI Studio -/

private def gaisUserChunk : Json := Json.mkObj [
  ("role", Json.str "user"),
  ("text", Json.str
    "Quoted <systemInstruction>literal</systemInstruction> remains dialogue.")]

private def gaisDeveloperChunk : Json := Json.mkObj [
  ("role", Json.str "developer"),
  ("text", Json.str "developer control: never dialogue")]

private def gaisSystemChunk : Json := Json.mkObj [
  ("role", Json.str "system"),
  ("text", Json.str "system control: never dialogue")]

private def gaisPolicyChunk : Json := Json.mkObj [
  ("role", Json.str "policy"),
  ("text", Json.str "policy control: never dialogue")]

private def gaisPermissionChunk : Json := Json.mkObj [
  ("role", Json.str "permission"),
  ("configuration", Json.mkObj [("mode", Json.str "read-only")])]

private def gaisRuntimeChunk : Json := Json.mkObj [
  ("role", Json.str "runtime-envelope"),
  ("runtime", Json.mkObj [("state", Json.str "fixture")])]

private def gaisFutureChunk : Json := Json.mkObj [
  ("role", Json.str "future-control-role"),
  ("payload", Json.mkObj [("opaque", Json.bool true)])]

private def gaisHarnessEventChunk : Json := Json.mkObj [
  ("role", Json.str "model"),
  ("errorMessage", Json.str "fixture harness event")]

private def gaisAssistantChunk : Json := Json.mkObj [
  ("role", Json.str "model"),
  ("text", Json.str "Google AI Studio assistant answer.")]

private def gaisChunks : List Json := [
  gaisUserChunk, gaisDeveloperChunk, gaisSystemChunk, gaisPolicyChunk,
  gaisPermissionChunk, gaisRuntimeChunk, gaisFutureChunk,
  gaisHarnessEventChunk, gaisAssistantChunk]

private def gaisRunSettings : Json := Json.mkObj [
  ("model", Json.str "fixture-gemini"),
  ("thinkingLevel", Json.str "thinking_low"),
  ("safetySettings", Json.arr #[Json.mkObj [
    ("category", Json.str "fixture"),
    ("threshold", Json.str "BLOCK_NONE")]]),
  ("runtimeConfiguration", Json.mkObj [
    ("permissionMode", Json.str "read-only")])]

private def gaisSystemInstruction : Json := Json.mkObj [
  ("text", Json.str "Google AI Studio system instructions"),
  ("futureInstructionField", Json.bool true)]

private def gaisRoot : Json := Json.mkObj [
  ("runSettings", gaisRunSettings),
  ("systemInstruction", gaisSystemInstruction),
  ("chunkedPrompt", Json.mkObj [("chunks", Json.arr gaisChunks.toArray)]),
  ("futureRootConfiguration", Json.mkObj [("kept", Json.bool true)])]

def contextIsolationGoogleAiStudioFixture : String := gaisRoot.compress

private def gaisConversationCheck (transcript : Transcript) : Bool :=
  dialogueEntryCount transcript == 2 && dialogueContainsOnlyText transcript &&
    dialogueAtoms transcript == [
      .userText
        "Quoted <systemInstruction>literal</systemInstruction> remains dialogue.",
      .assistantText "Google AI Studio assistant answer."]

private def gaisExactRetentionCheck (transcript : Transcript) : Bool :=
  transcript.env.instructions ==
      some "Google AI Studio system instructions" &&
    transcriptExtra? transcript "googleAiStudioRaw" == some gaisRoot &&
    transcript.entries.toList.all fun entry =>
      match entry.origin.sourceRef with
      | "runSettings.model" | "runSettings.thinkingLevel" =>
          entryExtra? entry "googleAiStudioRaw" == some gaisRunSettings
      | _ => true

def contextIsolationGoogleAiStudioCheck : Bool :=
  match importGoogleAiStudio contextIsolationGoogleAiStudioFixture with
  | .error _ => false
  | .ok transcript =>
      gaisConversationCheck transcript &&
      hasExactCustomEvent transcript "google-ai-studio-unmodeled-chunk"
        gaisDeveloperChunk &&
      hasExactCustomEvent transcript "google-ai-studio-unmodeled-chunk"
        gaisSystemChunk &&
      hasExactCustomEvent transcript "google-ai-studio-unmodeled-chunk"
        gaisPolicyChunk &&
      hasExactCustomEvent transcript "google-ai-studio-unmodeled-chunk"
        gaisPermissionChunk &&
      hasExactCustomEvent transcript "google-ai-studio-unmodeled-chunk"
        gaisRuntimeChunk &&
      hasExactCustomEvent transcript "google-ai-studio-unmodeled-chunk"
        gaisFutureChunk &&
      hasExactCustomEvent transcript "error" gaisHarnessEventChunk &&
      hasModelChange transcript none (some "fixture-gemini") &&
      hasThinkingLevelChange transcript none (some "low") &&
      gaisExactRetentionCheck transcript &&
      (violations transcript).isEmpty

/-! ## Cursor IDE -/

private def cursorIdeBubble (bubbleType : Nat) (id text family : String) : Json :=
  Json.mkObj [
    ("type", Json.num bubbleType), ("bubbleId", Json.str id),
    ("text", Json.str text), ("controlFamily", Json.str family)]

private def cursorIdeUserBubble : Json := Json.mkObj [
  ("type", Json.num 1), ("bubbleId", Json.str "ci-user"),
  ("text", Json.str
    "Quoted <system>literal</system> remains Cursor IDE dialogue.")]

private def cursorIdeDeveloperBubble : Json :=
  cursorIdeBubble 31 "ci-developer" "developer control: never dialogue" "developer"

private def cursorIdeSystemBubble : Json :=
  cursorIdeBubble 32 "ci-system" "system instruction: never dialogue" "system"

private def cursorIdePolicyBubble : Json :=
  cursorIdeBubble 33 "ci-policy" "policy control: never dialogue" "policy"

private def cursorIdePermissionBubble : Json :=
  cursorIdeBubble 34 "ci-permission" "permission control: never dialogue" "permission"

private def cursorIdeRuntimeBubble : Json :=
  cursorIdeBubble 35 "ci-runtime" "runtime control: never dialogue" "runtime"

private def cursorIdeFutureBubble : Json :=
  cursorIdeBubble 77 "ci-future" "future control: never dialogue" "future"

private def cursorIdeHarnessEventBubble : Json :=
  cursorIdeBubble 78 "ci-event" "harness event: never dialogue" "event"

private def cursorIdeAssistantBubble : Json := Json.mkObj [
  ("type", Json.num 2), ("bubbleId", Json.str "ci-assistant"),
  ("text", Json.str "Cursor IDE assistant answer."),
  ("modelInfo", Json.mkObj [("modelName", Json.str "fixture-model")])]

private def cursorIdeBubbles : List Json := [
  cursorIdeUserBubble, cursorIdeDeveloperBubble, cursorIdeSystemBubble,
  cursorIdePolicyBubble, cursorIdePermissionBubble, cursorIdeRuntimeBubble,
  cursorIdeFutureBubble, cursorIdeHarnessEventBubble,
  cursorIdeAssistantBubble]

private def cursorIdeHeader (bubble : Json) : Json := Json.mkObj [
  ("bubbleId", (jsonField? bubble "bubbleId").getD Json.null),
  ("type", (jsonField? bubble "type").getD Json.null)]

private def cursorIdeComposer : Json := Json.mkObj [
  ("composerId", Json.str "f032-cursor-ide"),
  ("workspaceIdentifier", Json.mkObj [
    ("uri", Json.mkObj [("fsPath", Json.str "/f032/cursor-ide")])]),
  ("systemInstruction", Json.str "Cursor IDE system instructions"),
  ("developerInstructions", Json.str "Cursor IDE developer controls"),
  ("permissionMode", Json.str "read-only"),
  ("runtimeConfiguration", Json.mkObj [("profile", Json.str "f032")]),
  ("fullConversationHeadersOnly",
    Json.arr (cursorIdeBubbles.map cursorIdeHeader).toArray)]

private def cursorIdeRoot : Json := Json.mkObj [
  ("composer", cursorIdeComposer),
  ("bubbles", Json.arr cursorIdeBubbles.toArray),
  ("envelopeConfiguration", Json.mkObj [("kept", Json.bool true)])]

def contextIsolationCursorIdeFixture : String := cursorIdeRoot.compress

private def cursorIdeConversationCheck (transcript : Transcript) : Bool :=
  dialogueEntryCount transcript == 2 && dialogueContainsOnlyText transcript &&
    dialogueAtoms transcript == [
      .userText
        "Quoted <system>literal</system> remains Cursor IDE dialogue.",
      .assistantText "Cursor IDE assistant answer."]

private def cursorIdeExactRetentionCheck (transcript : Transcript) : Bool :=
  transcriptExtra? transcript "rawEnvelope" == some cursorIdeRoot &&
    transcriptExtra? transcript "rawComposer" == some cursorIdeComposer &&
    entriesRetainRaw transcript "rawBubble" cursorIdeBubbles

def contextIsolationCursorIdeCheck : Bool :=
  match importCursorIde contextIsolationCursorIdeFixture with
  | .error _ => false
  | .ok transcript =>
      cursorIdeConversationCheck transcript &&
      hasExactCustomEvent transcript "cursor_ide.bubble_type_31"
        cursorIdeDeveloperBubble &&
      hasExactCustomEvent transcript "cursor_ide.bubble_type_32"
        cursorIdeSystemBubble &&
      hasExactCustomEvent transcript "cursor_ide.bubble_type_33"
        cursorIdePolicyBubble &&
      hasExactCustomEvent transcript "cursor_ide.bubble_type_34"
        cursorIdePermissionBubble &&
      hasExactCustomEvent transcript "cursor_ide.bubble_type_35"
        cursorIdeRuntimeBubble &&
      hasExactCustomEvent transcript "cursor_ide.bubble_type_77"
        cursorIdeFutureBubble &&
      hasExactCustomEvent transcript "cursor_ide.bubble_type_78"
        cursorIdeHarnessEventBubble &&
      cursorIdeExactRetentionCheck transcript &&
      (violations transcript).isEmpty

/-! ## Closed census -/

inductive ContextIsolationHarness where
  | pi
  | claudeCode
  | codexCli
  | cursorAgent
  | hermes
  | googleAiStudio
  | cursorIde
  | loomWire
  deriving Repr, DecidableEq

def ContextIsolationHarness.all : List ContextIsolationHarness := [
  .pi, .claudeCode, .codexCli, .cursorAgent, .hermes,
  .googleAiStudio, .cursorIde, .loomWire]

def ContextIsolationHarness.sourceCliName : ContextIsolationHarness -> String
  | .pi => "pi"
  | .claudeCode => "claude"
  | .codexCli => "codex"
  | .cursorAgent => "cursor-agent"
  | .hermes => "hermes"
  | .googleAiStudio => "google-ai-studio"
  | .cursorIde => "cursor-ide"
  | .loomWire => "loom"

inductive ContextIsolationRoleFamily where
  | conversation
  | developer
  | systemInstructions
  | policyPermissionConfigurationRuntime
  | unknownFuture
  | harnessMetaEvent
  deriving Repr, DecidableEq

def ContextIsolationRoleFamily.all : List ContextIsolationRoleFamily := [
  .conversation, .developer, .systemInstructions,
  .policyPermissionConfigurationRuntime, .unknownFuture, .harnessMetaEvent]

/-- `applicable` means the internal fixture contains an accepted source form
for this adversary. It is not evidence that a real harness emitted that form. -/
structure ContextIsolationFamilyCell where
  family : ContextIsolationRoleFamily
  applicable : Bool
  isolated : Bool
  retainedOrRefusedExactly : Bool

structure ContextIsolationCensusRow where
  harness : ContextIsolationHarness
  name : String
  hasHarnessRoleVocabulary : Bool
  families : List ContextIsolationFamilyCell
  fixtureClosed : Bool
  allFamilies : Bool
  publicAdapterPins : Bool

private structure ContextIsolationFamilyEvidence where
  isolated : Bool
  retainedOrRefusedExactly : Bool

private def vendorFamilyCells
    (result : Except String Transcript)
    (evidence : Transcript ->
      ContextIsolationRoleFamily -> ContextIsolationFamilyEvidence) :
    List ContextIsolationFamilyCell :=
  ContextIsolationRoleFamily.all.map fun family =>
    match result with
    | .error _ => {
        family,
        applicable := true,
        isolated := false,
        retainedOrRefusedExactly := false }
    | .ok transcript =>
        let witness := evidence transcript family
        { family,
          applicable := true,
          isolated := witness.isolated,
          retainedOrRefusedExactly := witness.retainedOrRefusedExactly }

private def piFamilyEvidence (transcript : Transcript) :
    ContextIsolationRoleFamily -> ContextIsolationFamilyEvidence
  | .conversation => {
      isolated := piConversationCheck transcript,
      retainedOrRefusedExactly :=
        entryRetainsExactRaw transcript "piRaw" piUserRecord &&
        entryRetainsExactRaw transcript "piRaw" piAssistantRecord }
  | .developer => {
      isolated := piConversationCheck transcript &&
        hasExactOtherMessage transcript "developer" piDeveloperMessage,
      retainedOrRefusedExactly :=
        entryRetainsExactRaw transcript "piRaw" piDeveloperRecord }
  | .systemInstructions => {
      isolated := piConversationCheck transcript &&
        hasExactOtherMessage transcript "system" piSystemMessage,
      retainedOrRefusedExactly :=
        entryRetainsExactRaw transcript "piRaw" piSystemRecord &&
        transcriptExtra? transcript "piRaw" == some piHeader }
  | .policyPermissionConfigurationRuntime => {
      isolated := piConversationCheck transcript &&
        hasExactOtherMessage transcript "permission" piPermissionMessage &&
        hasExactOtherMessage transcript "bashExecution" piRuntimeMessage,
      retainedOrRefusedExactly :=
        entryRetainsExactRaw transcript "piRaw" piPermissionRecord &&
        entryRetainsExactRaw transcript "piRaw" piRuntimeRecord &&
        transcriptExtra? transcript "piRaw" == some piHeader }
  | .unknownFuture => {
      isolated := piConversationCheck transcript &&
        hasExactOtherMessage transcript "future-control-role" piFutureMessage,
      retainedOrRefusedExactly :=
        entryRetainsExactRaw transcript "piRaw" piFutureRecord }
  | .harnessMetaEvent => {
      isolated := piConversationCheck transcript &&
        hasModelChange transcript (some "fixture-model")
          (some "fixture-model-next") &&
        hasExactCustomEvent transcript "future_harness_event"
          piHarnessEventRecord,
      retainedOrRefusedExactly :=
        entryRetainsExactRaw transcript "piRaw" piModelRecord &&
        entryRetainsExactRaw transcript "piRaw" piHarnessEventRecord }

private def claudeCodeFamilyEvidence (transcript : Transcript) :
    ContextIsolationRoleFamily -> ContextIsolationFamilyEvidence
  | .conversation => {
      isolated := claudeConversationCheck transcript,
      retainedOrRefusedExactly :=
        claudeConversationExactRetentionCheck transcript }
  | .developer =>
      let retained := archiveRetainsExactRaw transcript
        "raw_inert_records" "raw" claudeDeveloperRecord
      { isolated := claudeConversationCheck transcript && retained,
        retainedOrRefusedExactly := retained }
  | .systemInstructions =>
      let retained := archiveRetainsExactRaw transcript
        "raw_inert_records" "raw" claudeInstructionRecord
      { isolated := claudeConversationCheck transcript && retained,
        retainedOrRefusedExactly := retained }
  | .policyPermissionConfigurationRuntime =>
      let retained :=
        archiveRetainsExactRaw transcript "raw_inert_records" "raw"
          claudePolicyRecord &&
        archiveRetainsExactRaw transcript "raw_control_messages" "record"
          claudeRuntimeRecord &&
        archiveRetainsExactRaw transcript "raw_inert_records" "raw"
          claudePermissionRecord &&
        archiveRetainsExactRaw transcript "raw_inert_records" "raw"
          claudeConfigurationRecord
      { isolated := claudeConversationCheck transcript && retained,
        retainedOrRefusedExactly := retained }
  | .unknownFuture =>
      let retained := archiveRetainsExactRaw transcript
        "raw_inert_records" "raw" claudeFutureRecord
      { isolated := claudeConversationCheck transcript && retained,
        retainedOrRefusedExactly := retained }
  | .harnessMetaEvent =>
      let retained := archiveRetainsExactRaw transcript
        "raw_inert_records" "raw" claudeHarnessEventRecord
      { isolated := claudeConversationCheck transcript && retained,
        retainedOrRefusedExactly := retained }

private def codexCliFamilyEvidence (transcript : Transcript) :
    ContextIsolationRoleFamily -> ContextIsolationFamilyEvidence
  | .conversation =>
      let retained := extraArrayRetainsExactRaw transcript
        "raw_control_messages" codexUserRecord
      { isolated := codexConversationCheck transcript,
        retainedOrRefusedExactly :=
          codexConversationCheck transcript && retained }
  | .developer =>
      let retained := extraArrayRetainsExactRaw transcript
        "raw_control_messages" codexDeveloperRecord
      { isolated := codexConversationCheck transcript && retained,
        retainedOrRefusedExactly := retained }
  | .systemInstructions =>
      let retained :=
        extraArrayRetainsExactRaw transcript "raw_control_messages"
          codexSystemRecord &&
        codexSessionMetaBoundaryRetainedExactly transcript
      { isolated := codexConversationCheck transcript &&
          transcript.env.instructions == some "codex system instructions" &&
          transcriptExtra? transcript "raw_session_meta_payload" ==
            jsonField? codexHeader "payload" &&
          retained,
        retainedOrRefusedExactly := retained }
  | .policyPermissionConfigurationRuntime =>
      let retained :=
        extraArrayRetainsExactRaw transcript "raw_control_messages"
          codexPolicyRecord &&
        extraArrayRetainsExactRaw transcript "raw_control_messages"
          codexTurnContextRecord &&
        codexSessionMetaBoundaryRetainedExactly transcript
      { isolated := codexConversationCheck transcript && retained,
        retainedOrRefusedExactly := retained }
  | .unknownFuture =>
      let retained :=
        extraArrayRetainsExactRaw transcript "raw_control_messages"
          codexFutureRoleRecord &&
        extraArrayRetainsExactRaw transcript "raw_non_dialogue_records"
          codexUnknownRecord
      { isolated := codexConversationCheck transcript && retained,
        retainedOrRefusedExactly := retained }
  | .harnessMetaEvent =>
      let retained := codexHarnessEventRetainedExactly transcript
      { isolated := codexConversationCheck transcript && retained,
        retainedOrRefusedExactly := retained }

private def cursorAgentFamilyEvidence (transcript : Transcript) :
    ContextIsolationRoleFamily -> ContextIsolationFamilyEvidence
  | .conversation => {
      isolated := cursorAgentConversationCheck transcript,
      retainedOrRefusedExactly :=
        entryRetainsExactRaw transcript "rawRecord" cursorAgentUserRecord &&
        entryRetainsExactRaw transcript "rawRecord" cursorAgentAssistantRecord }
  | .developer => {
      isolated := cursorAgentConversationCheck transcript &&
        hasExactCustomEvent transcript "cursor_agent.unknown_role.developer"
          cursorAgentDeveloperRecord,
      retainedOrRefusedExactly :=
        entryRetainsExactRaw transcript "rawRecord" cursorAgentDeveloperRecord }
  | .systemInstructions => {
      isolated := cursorAgentConversationCheck transcript &&
        hasExactCustomEvent transcript "cursor_agent.unknown_role.system"
          cursorAgentSystemRecord,
      retainedOrRefusedExactly :=
        entryRetainsExactRaw transcript "rawRecord" cursorAgentSystemRecord }
  | .policyPermissionConfigurationRuntime => {
      isolated := cursorAgentConversationCheck transcript &&
        hasExactCustomEvent transcript "cursor_agent.unknown_role.policy"
          cursorAgentPolicyRecord &&
        hasExactCustomEvent transcript "cursor_agent.permission_configuration"
          cursorAgentPermissionRecord &&
        hasExactCustomEvent transcript "cursor_agent.turn_ended"
          cursorAgentRuntimeRecord,
      retainedOrRefusedExactly :=
        entryRetainsExactRaw transcript "rawRecord" cursorAgentPolicyRecord &&
        entryRetainsExactRaw transcript "rawRecord" cursorAgentPermissionRecord &&
        entryRetainsExactRaw transcript "rawRecord" cursorAgentRuntimeRecord }
  | .unknownFuture => {
      isolated := cursorAgentConversationCheck transcript &&
        hasExactCustomEvent transcript
          "cursor_agent.unknown_role.future-control-role"
          cursorAgentFutureRecord,
      retainedOrRefusedExactly :=
        entryRetainsExactRaw transcript "rawRecord" cursorAgentFutureRecord }
  | .harnessMetaEvent => {
      isolated := cursorAgentConversationCheck transcript &&
        hasExactCustomEvent transcript "cursor_agent.future_harness_event"
          cursorAgentHarnessEventRecord,
      retainedOrRefusedExactly :=
        entryRetainsExactRaw transcript "rawRecord"
          cursorAgentHarnessEventRecord }

private def hermesFamilyEvidence (transcript : Transcript) :
    ContextIsolationRoleFamily -> ContextIsolationFamilyEvidence
  | .conversation => {
      isolated := hermesConversationCheck transcript,
      retainedOrRefusedExactly :=
        entryRetainsExactRaw transcript "hermesRaw" hermesUserRecord &&
        entryRetainsExactRaw transcript "hermesRaw" hermesAssistantRecord }
  | .developer => {
      isolated := hermesConversationCheck transcript &&
        hasExactCustomEvent transcript "hermes-unmodeled-message"
          hermesDeveloperRecord,
      retainedOrRefusedExactly :=
        entryRetainsExactRaw transcript "hermesRaw" hermesDeveloperRecord }
  | .systemInstructions => {
      isolated := hermesConversationCheck transcript &&
        transcript.env.instructions == some "Hermes system instructions" &&
        hasExactCustomEvent transcript "hermes-unmodeled-message"
          hermesSystemRecord,
      retainedOrRefusedExactly :=
        entryRetainsExactRaw transcript "hermesRaw" hermesSystemRecord &&
        transcriptExtra? transcript "hermesRaw" == some hermesRoot }
  | .policyPermissionConfigurationRuntime => {
      isolated := hermesConversationCheck transcript &&
        hasExactCustomEvent transcript "hermes-unmodeled-message"
          hermesPolicyRecord &&
        hasExactCustomEvent transcript "hermes-unmodeled-message"
          hermesRuntimeRecord,
      retainedOrRefusedExactly :=
        entryRetainsExactRaw transcript "hermesRaw" hermesPolicyRecord &&
        entryRetainsExactRaw transcript "hermesRaw" hermesRuntimeRecord &&
        transcriptExtra? transcript "hermesRaw" == some hermesRoot }
  | .unknownFuture => {
      isolated := hermesConversationCheck transcript &&
        hasExactCustomEvent transcript "hermes-unmodeled-message"
          hermesFutureRecord,
      retainedOrRefusedExactly :=
        entryRetainsExactRaw transcript "hermesRaw" hermesFutureRecord }
  | .harnessMetaEvent => {
      isolated := hermesConversationCheck transcript &&
        hasExactCustomEvent transcript "hermes-unmodeled-message"
          hermesHarnessEventRecord,
      retainedOrRefusedExactly :=
        entryRetainsExactRaw transcript "hermesRaw" hermesHarnessEventRecord }

private def googleAiStudioFamilyEvidence (transcript : Transcript) :
    ContextIsolationRoleFamily -> ContextIsolationFamilyEvidence
  | .conversation => {
      isolated := gaisConversationCheck transcript,
      retainedOrRefusedExactly :=
        gaisConversationCheck transcript &&
        transcriptExtra? transcript "googleAiStudioRaw" == some gaisRoot }
  | .developer => {
      isolated := gaisConversationCheck transcript &&
        hasExactCustomEvent transcript "google-ai-studio-unmodeled-chunk"
          gaisDeveloperChunk,
      retainedOrRefusedExactly :=
        hasExactCustomEvent transcript "google-ai-studio-unmodeled-chunk"
          gaisDeveloperChunk &&
        transcriptExtra? transcript "googleAiStudioRaw" == some gaisRoot }
  | .systemInstructions => {
      isolated := gaisConversationCheck transcript &&
        transcript.env.instructions ==
          some "Google AI Studio system instructions" &&
        hasExactCustomEvent transcript "google-ai-studio-unmodeled-chunk"
          gaisSystemChunk,
      retainedOrRefusedExactly :=
        hasExactCustomEvent transcript "google-ai-studio-unmodeled-chunk"
          gaisSystemChunk &&
        transcriptExtra? transcript "googleAiStudioRaw" == some gaisRoot }
  | .policyPermissionConfigurationRuntime => {
      isolated := gaisConversationCheck transcript &&
        hasExactCustomEvent transcript "google-ai-studio-unmodeled-chunk"
          gaisPolicyChunk &&
        hasExactCustomEvent transcript "google-ai-studio-unmodeled-chunk"
          gaisPermissionChunk &&
        hasExactCustomEvent transcript "google-ai-studio-unmodeled-chunk"
          gaisRuntimeChunk,
      retainedOrRefusedExactly :=
        hasExactCustomEvent transcript "google-ai-studio-unmodeled-chunk"
          gaisPolicyChunk &&
        hasExactCustomEvent transcript "google-ai-studio-unmodeled-chunk"
          gaisPermissionChunk &&
        hasExactCustomEvent transcript "google-ai-studio-unmodeled-chunk"
          gaisRuntimeChunk &&
        transcriptExtra? transcript "googleAiStudioRaw" == some gaisRoot }
  | .unknownFuture => {
      isolated := gaisConversationCheck transcript &&
        hasExactCustomEvent transcript "google-ai-studio-unmodeled-chunk"
          gaisFutureChunk,
      retainedOrRefusedExactly :=
        hasExactCustomEvent transcript "google-ai-studio-unmodeled-chunk"
          gaisFutureChunk &&
        transcriptExtra? transcript "googleAiStudioRaw" == some gaisRoot }
  | .harnessMetaEvent => {
      isolated := gaisConversationCheck transcript &&
        hasExactCustomEvent transcript "error" gaisHarnessEventChunk &&
        hasModelChange transcript none (some "fixture-gemini") &&
        hasThinkingLevelChange transcript none (some "low"),
      retainedOrRefusedExactly :=
        hasExactCustomEvent transcript "error" gaisHarnessEventChunk &&
        hasModelChange transcript none (some "fixture-gemini") &&
        hasThinkingLevelChange transcript none (some "low") &&
        transcriptExtra? transcript "googleAiStudioRaw" == some gaisRoot }

private def cursorIdeFamilyEvidence (transcript : Transcript) :
    ContextIsolationRoleFamily -> ContextIsolationFamilyEvidence
  | .conversation => {
      isolated := cursorIdeConversationCheck transcript,
      retainedOrRefusedExactly :=
        entryRetainsExactRaw transcript "rawBubble" cursorIdeUserBubble &&
        entryRetainsExactRaw transcript "rawBubble" cursorIdeAssistantBubble }
  | .developer => {
      isolated := cursorIdeConversationCheck transcript &&
        hasExactCustomEvent transcript "cursor_ide.bubble_type_31"
          cursorIdeDeveloperBubble,
      retainedOrRefusedExactly :=
        entryRetainsExactRaw transcript "rawBubble" cursorIdeDeveloperBubble &&
        transcriptExtra? transcript "rawComposer" == some cursorIdeComposer }
  | .systemInstructions => {
      isolated := cursorIdeConversationCheck transcript &&
        hasExactCustomEvent transcript "cursor_ide.bubble_type_32"
          cursorIdeSystemBubble,
      retainedOrRefusedExactly :=
        entryRetainsExactRaw transcript "rawBubble" cursorIdeSystemBubble &&
        transcriptExtra? transcript "rawComposer" == some cursorIdeComposer }
  | .policyPermissionConfigurationRuntime => {
      isolated := cursorIdeConversationCheck transcript &&
        hasExactCustomEvent transcript "cursor_ide.bubble_type_33"
          cursorIdePolicyBubble &&
        hasExactCustomEvent transcript "cursor_ide.bubble_type_34"
          cursorIdePermissionBubble &&
        hasExactCustomEvent transcript "cursor_ide.bubble_type_35"
          cursorIdeRuntimeBubble,
      retainedOrRefusedExactly :=
        entryRetainsExactRaw transcript "rawBubble" cursorIdePolicyBubble &&
        entryRetainsExactRaw transcript "rawBubble" cursorIdePermissionBubble &&
        entryRetainsExactRaw transcript "rawBubble" cursorIdeRuntimeBubble &&
        transcriptExtra? transcript "rawComposer" == some cursorIdeComposer &&
        transcriptExtra? transcript "rawEnvelope" == some cursorIdeRoot }
  | .unknownFuture => {
      isolated := cursorIdeConversationCheck transcript &&
        hasExactCustomEvent transcript "cursor_ide.bubble_type_77"
          cursorIdeFutureBubble,
      retainedOrRefusedExactly :=
        entryRetainsExactRaw transcript "rawBubble" cursorIdeFutureBubble }
  | .harnessMetaEvent => {
      isolated := cursorIdeConversationCheck transcript &&
        hasExactCustomEvent transcript "cursor_ide.bubble_type_78"
          cursorIdeHarnessEventBubble,
      retainedOrRefusedExactly :=
        entryRetainsExactRaw transcript "rawBubble"
          cursorIdeHarnessEventBubble }

private def unavailableFamilyCell
    (family : ContextIsolationRoleFamily) : ContextIsolationFamilyCell := {
  family,
  applicable := false,
  isolated := false,
  retainedOrRefusedExactly := false }

private def loomWireFamilyCell :
    ContextIsolationRoleFamily -> ContextIsolationFamilyCell
  | .conversation => unavailableFamilyCell .conversation
  | .developer => unavailableFamilyCell .developer
  | .systemInstructions => unavailableFamilyCell .systemInstructions
  | .policyPermissionConfigurationRuntime =>
      unavailableFamilyCell .policyPermissionConfigurationRuntime
  | .unknownFuture => unavailableFamilyCell .unknownFuture
  | .harnessMetaEvent => unavailableFamilyCell .harnessMetaEvent

private def piFamilyCells : List ContextIsolationFamilyCell :=
  vendorFamilyCells (importPi contextIsolationPiFixture) piFamilyEvidence

private def claudeCodeFamilyCells : List ContextIsolationFamilyCell :=
  vendorFamilyCells (importClaudeCode contextIsolationClaudeCodeFixture)
    claudeCodeFamilyEvidence

private def codexCliFamilyCells : List ContextIsolationFamilyCell :=
  vendorFamilyCells (importCodexCli contextIsolationCodexCliFixture)
    codexCliFamilyEvidence

private def cursorAgentFamilyCells : List ContextIsolationFamilyCell :=
  vendorFamilyCells (importCursorAgent contextIsolationCursorAgentFixture)
    cursorAgentFamilyEvidence

private def hermesFamilyCells : List ContextIsolationFamilyCell :=
  vendorFamilyCells (importHermes contextIsolationHermesFixture)
    hermesFamilyEvidence

private def googleAiStudioFamilyCells : List ContextIsolationFamilyCell :=
  vendorFamilyCells (importGoogleAiStudio contextIsolationGoogleAiStudioFixture)
    googleAiStudioFamilyEvidence

private def cursorIdeFamilyCells : List ContextIsolationFamilyCell :=
  vendorFamilyCells (importCursorIde contextIsolationCursorIdeFixture)
    cursorIdeFamilyEvidence

private def loomWireFamilyCells : List ContextIsolationFamilyCell :=
  ContextIsolationRoleFamily.all.map loomWireFamilyCell

private def applicableFamilyCellsPass
    (cells : List ContextIsolationFamilyCell) : Bool :=
  cells.all fun cell =>
    cell.applicable && cell.isolated && cell.retainedOrRefusedExactly

private def unavailableFamilyCellsPass
    (cells : List ContextIsolationFamilyCell) : Bool :=
  cells.all fun cell =>
    !cell.applicable && !cell.isolated && !cell.retainedOrRefusedExactly

def contextIsolationPiAllFamilies : Bool :=
  applicableFamilyCellsPass piFamilyCells

def contextIsolationClaudeCodeAllFamilies : Bool :=
  applicableFamilyCellsPass claudeCodeFamilyCells

def contextIsolationCodexCliAllFamilies : Bool :=
  applicableFamilyCellsPass codexCliFamilyCells

def contextIsolationCursorAgentAllFamilies : Bool :=
  applicableFamilyCellsPass cursorAgentFamilyCells

def contextIsolationHermesAllFamilies : Bool :=
  applicableFamilyCellsPass hermesFamilyCells

def contextIsolationGoogleAiStudioAllFamilies : Bool :=
  applicableFamilyCellsPass googleAiStudioFamilyCells

def contextIsolationCursorIdeAllFamilies : Bool :=
  applicableFamilyCellsPass cursorIdeFamilyCells

def contextIsolationLoomWireAllFamilies : Bool :=
  unavailableFamilyCellsPass loomWireFamilyCells

private def piAdapterPins : Bool :=
  piNativeStringImageAndBashPinned &&
    piAdditiveAndCarrierCyclePinned &&
    piAdditionalRoleValidationPinned &&
    piStrictAssistantContextPinned &&
    piForeignUserUnsafeBlocksStayOutOfContext

private def claudeAdapterPins : Bool :=
  claudeControlsArchivedOutsideConversation &&
    claudeControlLiteralCollisionPreserved &&
    claudeControlRolesNeverBecomeUserDialogue

private def codexAdapterPins : Bool :=
  codexRuntimeControlsArchived &&
    codexMixedControlsAreIsolated &&
    codexMixedControlBothChannelOrdersSafe &&
    codexAllAssistantUnmodeledPayloadsAreRoleSafe

private def cursorAgentAdapterPins : Bool :=
  cursorAgentControlRecordsAreInert &&
    cursorAgentUnknownContentRetained &&
    cursorAgentRawRecordProvenanceExact

private def hermesAdapterPins : Bool :=
  crossParityOkWith importHermes hermesCase1

private def gaisAdapterPins : Bool :=
  crossParityOkWith importGoogleAiStudio gaisCase1

private def cursorIdeAdapterPins : Bool :=
  cursorIdeUnknownBubbleIsInert &&
    cursorIdeMetadataOnlyToolShellsAreInert &&
    cursorIdeMalformedBubbleIsLocalized &&
    crossParityOkWith importCursorIde cursorIdeCase1

private def loomWirePins : Bool :=
  loomWireRoundTripAllConstructors &&
    loomWireClosedEnumsRoundTrip &&
    loomWireReservedOpenLabelsRoundTripExactly

def contextIsolationExpectedRowNames : List String := [
  "pi",
  "claude-code",
  "codex-cli",
  "cursor-agent",
  "hermes",
  "google-ai-studio",
  "cursor-ide",
  "loom-wire-not-a-harness-role-vocabulary"]

def contextIsolationCensusRow :
    ContextIsolationHarness -> ContextIsolationCensusRow
  | .pi => {
      harness := .pi,
      name := "pi",
      hasHarnessRoleVocabulary := true,
      families := piFamilyCells,
      fixtureClosed := contextIsolationPiCheck,
      allFamilies := contextIsolationPiAllFamilies,
      publicAdapterPins := piAdapterPins }
  | .claudeCode => {
      harness := .claudeCode,
      name := "claude-code",
      hasHarnessRoleVocabulary := true,
      families := claudeCodeFamilyCells,
      fixtureClosed := contextIsolationClaudeCodeCheck,
      allFamilies := contextIsolationClaudeCodeAllFamilies,
      publicAdapterPins := claudeAdapterPins }
  | .codexCli => {
      harness := .codexCli,
      name := "codex-cli",
      hasHarnessRoleVocabulary := true,
      families := codexCliFamilyCells,
      fixtureClosed := contextIsolationCodexCliCheck,
      allFamilies := contextIsolationCodexCliAllFamilies,
      publicAdapterPins := codexAdapterPins }
  | .cursorAgent => {
      harness := .cursorAgent,
      name := "cursor-agent",
      hasHarnessRoleVocabulary := true,
      families := cursorAgentFamilyCells,
      fixtureClosed := contextIsolationCursorAgentCheck,
      allFamilies := contextIsolationCursorAgentAllFamilies,
      publicAdapterPins := cursorAgentAdapterPins }
  | .hermes => {
      harness := .hermes,
      name := "hermes",
      hasHarnessRoleVocabulary := true,
      families := hermesFamilyCells,
      fixtureClosed := contextIsolationHermesCheck,
      allFamilies := contextIsolationHermesAllFamilies,
      publicAdapterPins := hermesAdapterPins }
  | .googleAiStudio => {
      harness := .googleAiStudio,
      name := "google-ai-studio",
      hasHarnessRoleVocabulary := true,
      families := googleAiStudioFamilyCells,
      fixtureClosed := contextIsolationGoogleAiStudioCheck,
      allFamilies := contextIsolationGoogleAiStudioAllFamilies,
      publicAdapterPins := gaisAdapterPins }
  | .cursorIde => {
      harness := .cursorIde,
      name := "cursor-ide",
      hasHarnessRoleVocabulary := true,
      families := cursorIdeFamilyCells,
      fixtureClosed := contextIsolationCursorIdeCheck,
      allFamilies := contextIsolationCursorIdeAllFamilies,
      publicAdapterPins := cursorIdeAdapterPins }
  | .loomWire => {
      harness := .loomWire,
      name := "loom-wire-not-a-harness-role-vocabulary",
      hasHarnessRoleVocabulary := false,
      families := loomWireFamilyCells,
      fixtureClosed := true,
      allFamilies := contextIsolationLoomWireAllFamilies,
      publicAdapterPins := loomWirePins }

def contextIsolationCensus : List ContextIsolationCensusRow :=
  ContextIsolationHarness.all.map contextIsolationCensusRow

private def familyRowComplete (row : ContextIsolationCensusRow) : Bool :=
  row.families.map (fun cell => cell.family) ==
      ContextIsolationRoleFamily.all &&
    noDuplicates (row.families.map fun cell => cell.family)

private def familyRowPasses (row : ContextIsolationCensusRow) : Bool :=
  if row.hasHarnessRoleVocabulary then
    applicableFamilyCellsPass row.families
  else
    row.harness == .loomWire && unavailableFamilyCellsPass row.families

theorem contextIsolationHarnessCensusComplete
    (harness : ContextIsolationHarness) :
    Membership.mem (contextIsolationCensus.map fun row => row.harness)
      harness := by
  cases harness <;> native_decide

theorem contextIsolationRoleFamilyCensusComplete
    (harness : ContextIsolationHarness)
    (family : ContextIsolationRoleFamily) :
    Membership.mem ((contextIsolationCensusRow harness).families.map
      fun cell => cell.family) family := by
  cases harness <;> cases family <;> native_decide

def contextIsolationCensusComplete : Bool :=
  let censusSourceNames := ContextIsolationHarness.all.map
    ContextIsolationHarness.sourceCliName
  contextIsolationCensus.map (fun row => row.harness) ==
      ContextIsolationHarness.all &&
    contextIsolationCensus.map (fun row => row.name) ==
      contextIsolationExpectedRowNames &&
    noDuplicates (contextIsolationCensus.map fun row => row.harness) &&
    noDuplicates (contextIsolationCensus.map fun row => row.name) &&
    noDuplicates ContextIsolationHarness.all &&
    noDuplicates censusSourceNames &&
    censusSourceNames.length == declaredSourceCliNames.length &&
    censusSourceNames.all declaredSourceCliNames.contains &&
    declaredSourceCliNames.all censusSourceNames.contains &&
    noDuplicates ContextIsolationRoleFamily.all &&
    contextIsolationCensus.all familyRowComplete &&
    contextIsolationCensus.all fun row =>
      row.allFamilies == familyRowPasses row

def contextIsolationF032Aggregate : Bool :=
  contextIsolationCensusComplete &&
    contextIsolationCensus.all fun row =>
      familyRowPasses row && row.allFamilies && row.fixtureClosed &&
        row.publicAdapterPins

example : contextIsolationF032Aggregate = true := by native_decide

end AgentConvert.Requirements
