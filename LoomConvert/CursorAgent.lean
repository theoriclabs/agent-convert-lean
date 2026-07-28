import Loom
import LoomConvert.Parity

/-!
# LoomConvert.CursorAgent — the cursor-agent CLI importer

The simplest spoke (`Loom/Formats/CursorAgent.lean` is the census-grounded
spec). The cursor-agent CLI writes linear, Claude-like JSONL: each line is
`{role, message:{content:[blocks]}}` with `role ∈ {user, assistant}` and blocks
that are `{type:"text", text}` or `{type:"tool_use", name, input}`. There are
**no per-entry ids, no timestamps, no cwd** on any record, and tool RESULTS are
never stored — only tool calls.

Matches `src/pi/cursorAgentAdapter.ts` structurally, with Loom's explicit
raw/canonical tool-name refinement:

* `looksLikeCursorAgentLine` remains the TS-reference shape predicate. The
  hardened importer additionally classifies valid `turn_ended` and open-world
  top-level records as inert raw events so they cannot leak into dialogue or
  disappear silently.
* a `user` message → `Payload.userMsg`, an `assistant` message →
  `Payload.assistantMsg` (role-content-sum); a non-empty `text` block →
  `UserBlock.text` / `AssistantBlock.text` (by role); a `tool_use` block
  (assistant-only) → `AssistantBlock.toolCall` with its exact source spelling
  in `ToolName.raw`, a separate `CanonicalTool` interpretation when known, and
  its exact optional source id in `ToolCall.rawId`.
* Tool inputs retain arbitrary JSON (including current `ApplyPatch` strings).
  Unknown content blocks are retained verbatim in the role-appropriate
  `unmodeled` constructor. Malformed known blocks are rejected, unknown roles
  are inert events, and genuinely empty messages remain role-typed entries.
* Entry identity is synthesized as `caNNNN` and logged as
  `ImportNote.idSynthesized`. Native tool-call identity is not synthesized:
  absent and null ids remain `none`, and duplicate explicit ids remain
  duplicated. Missing and duplicate ids receive honest import notes. Time and
  cwd are absent; the thread is linear so `parent` is the previous entry index.

The same-format exporter overlays modeled fields onto exact raw records, keeping
top/message/block additions and the exact absent/null/duplicate id shape. The CLI
stores no results and cannot round-trip entry identity (claim L4). `env.cwd` is
honestly absent.
-/

namespace LoomConvert
open Loom
open Lean (Json)

/-! ## Small Json accessors (Except → Option), per the Pi.lean scaffold. -/

private def ostr (j : Json) (k : String) : Option String :=
  (j.getObjVal? k >>= Json.getStr?).toOption

private def oobj (j : Json) (k : String) : Option Json :=
  (j.getObjVal? k).toOption

private def oarr (j : Json) (k : String) : Option (Array Json) :=
  (j.getObjVal? k >>= Json.getArr?).toOption

private def onat (j : Json) (k : String) : Option Nat :=
  (j.getObjVal? k >>= Json.getNat?).toOption

private def obool (j : Json) (k : String) : Option Bool :=
  (j.getObjVal? k >>= Json.getBool?).toOption

private def cursorAgentHistoricalRecordType : String :=
  "agent_convert_historical_entry"

private def cursorAgentHistoricalProtocol : String :=
  "agent-convert.cursor-agent-entry.v1"

private def cursorAgentHistoricalSourceRawRecordKey : String :=
  "sourceRawRecord"

/-- Whether the source object carries a given key at all (present ⇒ reject),
mirroring the TS `"<key>" in o` guard. -/
private def hasKey (j : Json) (k : String) : Bool :=
  (j.getObjVal? k).toOption.isSome

private def requireString (ctx : String) (j : Json) (k : String) : Except String String :=
  match j.getObjVal? k with
  | .ok (Json.str value) => pure value
  | .ok _ => throw s!"{ctx}.{k}: expected string"
  | .error _ => throw s!"{ctx}.{k}: missing required string"

private def requireObject (ctx : String) (j : Json) (k : String) : Except String Json :=
  match j.getObjVal? k with
  | .ok value@(Json.obj _) => pure value
  | .ok _ => throw s!"{ctx}.{k}: expected object"
  | .error _ => throw s!"{ctx}.{k}: missing required object"

private def requireField (ctx : String) (j : Json) (k : String) : Except String Json :=
  match j.getObjVal? k with
  | .ok value => pure value
  | .error _ => throw s!"{ctx}.{k}: missing required field"

private def requireArray (ctx : String) (j : Json) (k : String) : Except String (Array Json) :=
  match j.getObjVal? k with
  | .ok (Json.arr values) => pure values
  | .ok _ => throw s!"{ctx}.{k}: expected array"
  | .error _ => throw s!"{ctx}.{k}: missing required array"

private def optionalString (ctx : String) (j : Json) (k : String) : Except String (Option String) :=
  match j.getObjVal? k with
  | .ok Json.null => pure none
  | .ok (Json.str value) => pure (some value)
  | .ok _ => throw s!"{ctx}.{k}: expected string when present"
  | .error _ => pure none

private inductive CursorAgentRecord where
  | message (role : String) (content : Array Json)
  | historical
  | turnEnded
  | unknown (label : String)

/-- Classify without ever turning a foreign or future top-level record into
conversation text. Known cursor-agent shapes are validated here; open-world
records remain inert events in the IR. -/
private def classifyCursorAgentRecord (line : Nat) (j : Json) : Except String CursorAgentRecord := do
  let ctx := s!"line{line}"
  match j with
  | Json.obj _ =>
    if hasKey j "type" then
      match j.getObjVal? "type" with
      | .ok (Json.str "agent_convert_historical_entry") =>
          pure .historical
      | .ok (Json.str "turn_ended") =>
          let status ← requireString ctx j "status"
          if status.isEmpty then
            throw s!"{ctx}.status: turn_ended status must be non-empty"
          let error? ← optionalString ctx j "error"
          if status == "error" && error?.isNone then
            throw s!"{ctx}.error: error turn_ended record requires an error string"
          pure .turnEnded
      | .ok (Json.str kind) => pure (.unknown s!"cursor_agent.{kind}")
      | .ok _ => pure (.unknown "cursor_agent.unknown_type")
      | .error _ => pure (.unknown "cursor_agent.unknown_record")
    else if hasKey j "uuid" || hasKey j "parentUuid" || hasKey j "sessionId" then
      pure (.unknown "cursor_agent.foreign_record")
    else if hasKey j "role" || hasKey j "message" then
      let role ← requireString ctx j "role"
      let message ← requireObject ctx j "message"
      let content ← requireArray s!"{ctx}.message" message "content"
      if role == "user" || role == "assistant" then
        pure (.message role content)
      else
        pure (.unknown s!"cursor_agent.unknown_role.{role}")
    else
      pure (.unknown "cursor_agent.unknown_record")
  | _ => pure (CursorAgentRecord.unknown "cursor_agent.non_object")

/-! ## Tool-name interpretation

`piToolNameForClaude` (`src/pi/claudeCode.ts:478-508`) supplies the semantic
lookup vocabulary, but its transformed string never replaces `ToolName.raw`. -/

def claudeToPiTool : List (String × String) := [
  ("Bash", "bash"), ("BashOutput", "bash_output"), ("KillShell", "kill_shell"),
  ("Shell", "bash"), ("StrReplace", "edit"), ("ReadFile", "read"),
  ("ApplyPatch", "applyPatch"), ("rg", "grep"),
  ("Read", "read"), ("Edit", "edit"), ("Write", "write"), ("Grep", "grep"),
  ("Glob", "glob"), ("LS", "ls"), ("TodoWrite", "todo_write"), ("Task", "task"),
  ("TaskCreate", "task_create"), ("TaskUpdate", "task_update"), ("TaskList", "task_list"),
  ("TaskGet", "task_get"), ("TaskOutput", "task_output"), ("TaskStop", "task_stop"),
  ("WebSearch", "web_search"), ("WebFetch", "web_fetch"), ("NotebookEdit", "notebook_edit"),
  ("ExitPlanMode", "exit_plan_mode"), ("Agent", "dispatch_subagent"),
  ("ToolSearch", "tool_search"), ("Skill", "skill")
]

/-- `piToolNameForClaude`: empty/missing → `"unknown"`; mapped Claude name →
its pi name; otherwise the lowercased source name. -/
def piToolName : Option String → String
  | none => "unknown"
  | some "" => "unknown"
  | some name =>
      match claudeToPiTool.find? (fun p => p.1 == name) with
      | some p => p.2
      | none => name.map Char.toLower

/-- Typed interpretation of the pi vocabulary without changing the source
spelling retained in `ToolName.raw`. The closed canonical enum intentionally
leaves the rest of the broader pi vocabulary unmapped. -/
def cursorCanonicalTool (name : Option String) : Option CanonicalTool :=
  match piToolName name with
  | "bash" => some .bash
  | "read" => some .read
  | "write" => some .write
  | "edit" => some .edit
  | "grep" => some .grep
  | "glob" => some .glob
  | "web_fetch" => some .webFetch
  | "web_search" => some .webSearch
  | "task" | "subagent" | "dispatch_subagent" => some .agentSpawn
  | "apply_patch" | "applyPatch" => some .applyPatch
  | _ => none

private def cursorHistoricalCanonicalTool : CanonicalTool -> String
  | .bash => "bash"
  | .read => "read"
  | .write => "write"
  | .edit => "edit"
  | .grep => "grep"
  | .glob => "glob"
  | .webFetch => "webFetch"
  | .webSearch => "webSearch"
  | .agentSpawn => "agentSpawn"
  | .applyPatch => "applyPatch"

private def cursorParseHistoricalCanonicalTool? : String -> Option CanonicalTool
  | "bash" => some .bash
  | "read" => some .read
  | "write" => some .write
  | "edit" => some .edit
  | "grep" => some .grep
  | "glob" => some .glob
  | "webFetch" => some .webFetch
  | "webSearch" => some .webSearch
  | "agentSpawn" => some .agentSpawn
  | "applyPatch" => some .applyPatch
  | _ => none

private def cursorHistoricalOptionalString : Option String -> Json
  | some value => Json.str value
  | none => Json.null

private def cursorHistoricalOptionalString? (j : Json) (key : String) : Option (Option String) :=
  match oobj j key with
  | some Json.null => some none
  | some (Json.str value) => some (some value)
  | _ => none

/-- The IR intentionally identifies both a missing id and an explicit null as
`none`, but the archival codec must retain their distinct source spellings. -/
private inductive CursorHistoricalRawId where
  | missing
  | explicitNull
  | string (value : String)
  deriving Repr, DecidableEq

private def cursorHistoricalRawId? (j : Json) (key : String) : Option CursorHistoricalRawId :=
  match j.getObjVal? key with
  | .error _ => some .missing
  | .ok Json.null => some .explicitNull
  | .ok (Json.str value) => some (.string value)
  | .ok _ => none

private def CursorHistoricalRawId.value : CursorHistoricalRawId -> Option String
  | .missing | .explicitNull => none
  | .string value => some value

private def cursorHistoricalRawIdFromValue : Option String -> CursorHistoricalRawId
  | none => .missing
  | some value => .string value

private def cursorHistoricalRawIdField (key : String)
    (rawId : CursorHistoricalRawId) : List (String × Json) :=
  match rawId with
  | .missing => []
  | .explicitNull => [(key, Json.null)]
  | .string value => [(key, Json.str value)]

private def cursorHistoricalUserBlockJson : UserBlock -> Json
  | .text text => Json.mkObj [("kind", Json.str "text"), ("text", Json.str text)]
  | .media mimeType data => Json.mkObj [
      ("kind", Json.str "media"), ("mimeType", Json.str mimeType),
      ("data", Json.str data)]
  | .unmodeled label raw => Json.mkObj [
      ("kind", Json.str "unmodeled"), ("label", Json.str label), ("raw", raw)]

private def cursorHistoricalUserBlock? (j : Json) : Option UserBlock := do
  match ← ostr j "kind" with
  | "text" => pure (.text (← ostr j "text"))
  | "media" => pure (.media (← ostr j "mimeType") (← ostr j "data"))
  | "unmodeled" => pure (.unmodeled (← ostr j "label") (← oobj j "raw"))
  | _ => none

private def cursorHistoricalAssistantBlockJsonWithRawId
    (sourceRawId? : Option CursorHistoricalRawId) : AssistantBlock -> Json
  | .text text => Json.mkObj [("kind", Json.str "text"), ("text", Json.str text)]
  | .thinking thinking signature => Json.mkObj [
      ("kind", Json.str "thinking"), ("thinking", Json.str thinking),
      ("signature", cursorHistoricalOptionalString signature)]
  | .toolCall name arguments rawId => Json.mkObj ([
      ("kind", Json.str "toolCall"), ("name", Json.str name.raw),
      ("canonical", name.canonical.map (fun canonical =>
        Json.str (cursorHistoricalCanonicalTool canonical)) |>.getD Json.null),
      ("arguments", arguments)] ++
      cursorHistoricalRawIdField "rawId" (match sourceRawId? with
        | some sourceRawId =>
            if sourceRawId.value == rawId then sourceRawId
            else cursorHistoricalRawIdFromValue rawId
        | none => cursorHistoricalRawIdFromValue rawId))
  | .media mimeType data => Json.mkObj [
      ("kind", Json.str "media"), ("mimeType", Json.str mimeType),
      ("data", Json.str data)]
  | .unmodeled label raw => Json.mkObj [
      ("kind", Json.str "unmodeled"), ("label", Json.str label), ("raw", raw)]

private def cursorHistoricalAssistantBlockJson : AssistantBlock -> Json :=
  cursorHistoricalAssistantBlockJsonWithRawId none

private def cursorHistoricalAssistantBlock? (j : Json) : Option AssistantBlock := do
  match ← ostr j "kind" with
  | "text" => pure (.text (← ostr j "text"))
  | "thinking" => pure (.thinking (← ostr j "thinking")
      (← cursorHistoricalOptionalString? j "signature"))
  | "toolCall" =>
      let canonical ← match oobj j "canonical" with
        | some Json.null => some none
        | some (Json.str value) => (cursorParseHistoricalCanonicalTool? value).map some
        | _ => none
      let rawId ← cursorHistoricalRawId? j "rawId"
      pure (.toolCall { raw := ← ostr j "name", canonical }
        (← oobj j "arguments") rawId.value)
  | "media" => pure (.media (← ostr j "mimeType") (← ostr j "data"))
  | "unmodeled" => pure (.unmodeled (← ostr j "label") (← oobj j "raw"))
  | _ => none

private def cursorHistoricalCallRefJson : CallRef -> Json
  | .resolved entry block => Json.mkObj [
      ("kind", Json.str "resolved"), ("entry", Json.num entry),
      ("block", Json.num block)]
  | .unresolved rawId note => Json.mkObj [
      ("kind", Json.str "unresolved"),
      ("rawId", cursorHistoricalOptionalString rawId), ("note", Json.str note)]

private def cursorHistoricalCallRef? (j : Json) : Option CallRef := do
  match ← ostr j "kind" with
  | "resolved" => pure (.resolved (← onat j "entry") (← onat j "block"))
  | "unresolved" => pure (.unresolved
      (← cursorHistoricalOptionalString? j "rawId") (← ostr j "note"))
  | _ => none

private def cursorHistoricalErrorJson : ErrorSignal -> Json
  | .native value => Json.mkObj [
      ("kind", Json.str "native"), ("value", Json.bool value)]
  | .inferred value heuristic => Json.mkObj [
      ("kind", Json.str "inferred"), ("value", Json.bool value),
      ("heuristic", Json.str heuristic)]
  | .unrecorded => Json.mkObj [("kind", Json.str "unrecorded")]

private def cursorHistoricalError? (j : Json) : Option ErrorSignal := do
  match ← ostr j "kind" with
  | "native" => pure (.native (← obool j "value"))
  | "inferred" => pure (.inferred (← obool j "value") (← ostr j "heuristic"))
  | "unrecorded" => pure .unrecorded
  | _ => none

private def cursorHistoricalEnvBlockJson : EnvBlock -> Json
  | .toolResult call content error => Json.mkObj [
      ("kind", Json.str "toolResult"), ("call", cursorHistoricalCallRefJson call),
      ("content", Json.arr (content.map cursorHistoricalUserBlockJson).toArray),
      ("error", cursorHistoricalErrorJson error)]
  | .unmodeled label raw => Json.mkObj [
      ("kind", Json.str "unmodeled"), ("label", Json.str label), ("raw", raw)]

private def cursorHistoricalEnvBlock? (j : Json) : Option EnvBlock := do
  match ← ostr j "kind" with
  | "toolResult" =>
      let content ← oarr j "content"
      pure (.toolResult (← oobj j "call" >>= cursorHistoricalCallRef?)
        (← content.toList.mapM cursorHistoricalUserBlock?)
        (← oobj j "error" >>= cursorHistoricalError?))
  | "unmodeled" => pure (.unmodeled (← ostr j "label") (← oobj j "raw"))
  | _ => none

private def cursorHistoricalCoverageJson : CompactionCoverage -> Json
  | .knownPrefix firstKept => Json.mkObj [
      ("kind", Json.str "knownPrefix"), ("firstKept", Json.num firstKept)]
  | .unknownPrefix => Json.mkObj [("kind", Json.str "unknownPrefix")]

private def cursorHistoricalCoverage? (j : Json) : Option CompactionCoverage := do
  match ← ostr j "kind" with
  | "knownPrefix" => pure (.knownPrefix (← onat j "firstKept"))
  | "unknownPrefix" => pure .unknownPrefix
  | _ => none

private def cursorHistoricalMetaEventJson : MetaEvent -> Json
  | .modelChange previous next => Json.mkObj [
      ("kind", Json.str "modelChange"),
      ("previous", cursorHistoricalOptionalString previous),
      ("next", cursorHistoricalOptionalString next)]
  | .thinkingLevelChange previous next => Json.mkObj [
      ("kind", Json.str "thinkingLevelChange"),
      ("previous", cursorHistoricalOptionalString previous),
      ("next", cursorHistoricalOptionalString next)]
  | .permissionMode mode => Json.mkObj [
      ("kind", Json.str "permissionMode"), ("mode", Json.str mode)]
  | .branchSummary summary => Json.mkObj [
      ("kind", Json.str "branchSummary"), ("summary", Json.str summary)]
  | .custom label raw => Json.mkObj [
      ("kind", Json.str "custom"), ("label", Json.str label), ("raw", raw)]

private def cursorHistoricalMetaEvent? (j : Json) : Option MetaEvent := do
  match ← ostr j "kind" with
  | "modelChange" => pure (.modelChange
      (← cursorHistoricalOptionalString? j "previous")
      (← cursorHistoricalOptionalString? j "next"))
  | "thinkingLevelChange" => pure (.thinkingLevelChange
      (← cursorHistoricalOptionalString? j "previous")
      (← cursorHistoricalOptionalString? j "next"))
  | "permissionMode" => pure (.permissionMode (← ostr j "mode"))
  | "branchSummary" => pure (.branchSummary (← ostr j "summary"))
  | "custom" => pure (.custom (← ostr j "label") (← oobj j "raw"))
  | _ => none

private def cursorHistoricalPayloadJson : Payload -> Json
  | .userMsg blocks => Json.mkObj [
      ("kind", Json.str "userMsg"),
      ("blocks", Json.arr (blocks.map cursorHistoricalUserBlockJson).toArray)]
  | .assistantMsg blocks => Json.mkObj [
      ("kind", Json.str "assistantMsg"),
      ("blocks", Json.arr (blocks.map cursorHistoricalAssistantBlockJson).toArray)]
  | .envMsg blocks => Json.mkObj [
      ("kind", Json.str "envMsg"),
      ("blocks", Json.arr (blocks.map cursorHistoricalEnvBlockJson).toArray)]
  | .otherMsg role blocks => Json.mkObj [
      ("kind", Json.str "otherMsg"), ("role", Json.str role),
      ("blocks", Json.arr (blocks.map cursorHistoricalUserBlockJson).toArray)]
  | .compaction summary coverage tokensBefore => Json.mkObj [
      ("kind", Json.str "compaction"), ("summary", Json.str summary),
      ("coverage", cursorHistoricalCoverageJson coverage),
      ("tokensBefore", tokensBefore.map Json.num |>.getD Json.null)]
  | .event event => Json.mkObj [
      ("kind", Json.str "event"), ("event", cursorHistoricalMetaEventJson event)]

private def cursorHistoricalPayload? (j : Json) : Option Payload := do
  match ← ostr j "kind" with
  | "userMsg" =>
      let blocks ← oarr j "blocks"
      pure (.userMsg (← blocks.toList.mapM cursorHistoricalUserBlock?))
  | "assistantMsg" =>
      let blocks ← oarr j "blocks"
      pure (.assistantMsg (← blocks.toList.mapM cursorHistoricalAssistantBlock?))
  | "envMsg" =>
      let blocks ← oarr j "blocks"
      pure (.envMsg (← blocks.toList.mapM cursorHistoricalEnvBlock?))
  | "otherMsg" =>
      let blocks ← oarr j "blocks"
      pure (.otherMsg (← ostr j "role")
        (← blocks.toList.mapM cursorHistoricalUserBlock?))
  | "compaction" =>
      let tokensBefore ← match oobj j "tokensBefore" with
        | some Json.null => some none
        | some value => (value.getNat?).toOption.map some
        | none => none
      pure (.compaction (← ostr j "summary")
        (← oobj j "coverage" >>= cursorHistoricalCoverage?) tokensBefore)
  | "event" => pure (.event (← oobj j "event" >>= cursorHistoricalMetaEvent?))
  | _ => none

/-- Exporter-owned historical payloads are closed canonical objects. Parsing a
typed value is not enough: exact re-rendering rejects missing or unexpected
semantic fields at every nested constructor. Tool-call raw-id spelling remains
the one intentional optional shape and is copied from the raw canonical block. -/
private def cursorHistoricalStrictPayload? (j : Json) : Option Payload := do
  let payload ← cursorHistoricalPayload? j
  let canonical ← match payload with
    | .assistantMsg blocks =>
        let rawBlocks ← oarr j "blocks"
        guard (rawBlocks.size == blocks.length)
        let rendered ← blocks.zipIdx.mapM (fun (block, blockIdx) => do
          let rawBlock ← rawBlocks[blockIdx]?
          let sourceRawId? ← match block with
            | .toolCall _ _ rawId =>
                let sourceRawId ← cursorHistoricalRawId? rawBlock "rawId"
                guard (sourceRawId.value == rawId)
                pure (some sourceRawId)
            | _ => pure none
          pure (cursorHistoricalAssistantBlockJsonWithRawId sourceRawId? block))
        pure (Json.mkObj [
          ("kind", Json.str "assistantMsg"),
          ("blocks", Json.arr rendered.toArray)])
    | payload => pure (cursorHistoricalPayloadJson payload)
  guard (j == canonical)
  pure payload

private def cursorHistoricalSourceRawRecord? (j : Json) : Option (Option Json) :=
  match j.getObjVal? cursorAgentHistoricalSourceRawRecordKey with
  | .error _ => some none
  | .ok source@(Json.obj _) => some (some source)
  | .ok _ => none

private def cursorAgentHistoricalEntryPayload? (j : Json) : Option Payload := do
  guard (ostr j "type" == some cursorAgentHistoricalRecordType)
  guard (ostr j "protocol" == some cursorAgentHistoricalProtocol)
  let rawPayload ← oobj j "payload"
  let payload ← cursorHistoricalStrictPayload? rawPayload
  let sourceRawRecord? ← cursorHistoricalSourceRawRecord? j
  let canonical := Json.mkObj ([
    ("type", Json.str cursorAgentHistoricalRecordType),
    ("protocol", Json.str cursorAgentHistoricalProtocol),
    ("payload", rawPayload)] ++ sourceRawRecord?.toList.map (fun source =>
      (cursorAgentHistoricalSourceRawRecordKey, source)))
  guard (j == canonical)
  pure payload

/-- Zero-padded to width 4, matching the adapter's `padStart(4, "0")`. -/
def pad4 (n : Nat) : String :=
  let s := toString n
  String.ofList (List.replicate (4 - s.length) '0') ++ s

/-- Does `message.content` exist and is it an array? -/
private def hasContentArray (j : Json) : Bool :=
  match oobj j "message" with
  | some m => ((m.getObjVal? "content" >>= Json.getArr?).toOption).isSome
  | none => false

/-- Port of `looksLikeCursorAgentLine` (`cursorAgentAdapter.ts:36-45`): reject
any object with a top-level discriminator field, then require a user/assistant
role and a `message.content` array. This is the guard that DROPS `turn_ended`
records (they carry a top-level `type`). -/
def looksLikeCursorAgentLine (j : Json) : Bool :=
  if hasKey j "type" || hasKey j "uuid" || hasKey j "parentUuid" || hasKey j "sessionId" then
    false
  else
    match ostr j "role" with
    | some "user" => hasContentArray j
    | some "assistant" => hasContentArray j
    | _ => false

/-! `Lean.Json` stores object members in a map, so duplicate keys must be
rejected from raw text before parsing can collapse them. This scanner follows
JSON structure, decodes escaped keys, and reports duplicate member paths across
nested objects and arrays. -/

private structure CursorAgentRawJsonScan where
  rest : List Char
  duplicatePaths : List String

private def cursorAgentRawJsonWhitespace (char : Char) : Bool :=
  char == ' ' || char == '\n' || char == '\r' || char == '\t'

private def cursorAgentDropRawJsonWhitespace (chars : List Char) : List Char :=
  chars.dropWhile cursorAgentRawJsonWhitespace

private partial def cursorAgentTakeRawJsonString
    (chars reversed : List Char) : Except String (String × List Char) :=
  match chars with
  | [] => .error "unterminated JSON string"
  | '"' :: rest => .ok (String.ofList reversed.reverse, rest)
  | '\\' :: escaped :: rest =>
      cursorAgentTakeRawJsonString rest (escaped :: '\\' :: reversed)
  | '\\' :: [] => .error "unterminated JSON string escape"
  | char :: rest => cursorAgentTakeRawJsonString rest (char :: reversed)

private def cursorAgentDecodeRawJsonKey (encoded : String) : Except String String :=
  match Json.parse ("\"" ++ encoded ++ "\"") with
  | .ok (Json.str key) => .ok key
  | .ok _ => .error "JSON object key did not decode as a string"
  | .error error => .error error

private def cursorAgentRawJsonMemberPath (parent key : String) : String :=
  if parent.isEmpty then key else parent ++ "." ++ key

private def cursorAgentDropRawJsonPrimitive : List Char -> List Char
  | [] => []
  | input@(char :: rest) =>
      if char == ',' || char == ']' || char == '}' then input
      else cursorAgentDropRawJsonPrimitive rest

mutual
  private partial def cursorAgentScanRawJsonValue
      (chars : List Char) (path : String) : Except String CursorAgentRawJsonScan := do
    match cursorAgentDropRawJsonWhitespace chars with
    | [] => .error "missing JSON value"
    | '{' :: rest => cursorAgentScanRawJsonObject rest path [] []
    | '[' :: rest => cursorAgentScanRawJsonArray rest path 0 []
    | '"' :: rest =>
        let (_, tail) ← cursorAgentTakeRawJsonString rest []
        pure { rest := tail, duplicatePaths := [] }
    | primitive => pure {
        rest := cursorAgentDropRawJsonPrimitive primitive
        duplicatePaths := [] }

  private partial def cursorAgentScanRawJsonObject
      (chars : List Char) (path : String) (seen : List String)
      (duplicates : List String) : Except String CursorAgentRawJsonScan := do
    match cursorAgentDropRawJsonWhitespace chars with
    | [] => .error "unterminated JSON object"
    | '}' :: rest => pure { rest, duplicatePaths := duplicates }
    | '"' :: rest =>
        let (encodedKey, afterKey) ← cursorAgentTakeRawJsonString rest []
        let key ← cursorAgentDecodeRawJsonKey encodedKey
        let afterKey := cursorAgentDropRawJsonWhitespace afterKey
        let afterColon ← match afterKey with
          | ':' :: tail => pure tail
          | _ => .error "JSON object key is missing ':'"
        let memberPath := cursorAgentRawJsonMemberPath path key
        let value ← cursorAgentScanRawJsonValue afterColon memberPath
        let duplicates := duplicates ++ value.duplicatePaths ++
          (if seen.contains key then [memberPath] else [])
        match cursorAgentDropRawJsonWhitespace value.rest with
        | ',' :: tail => cursorAgentScanRawJsonObject tail path (key :: seen) duplicates
        | '}' :: tail => pure { rest := tail, duplicatePaths := duplicates }
        | _ => .error "JSON object member is missing ',' or '}'"
    | _ => .error "JSON object key must be a string"

  private partial def cursorAgentScanRawJsonArray
      (chars : List Char) (path : String) (index : Nat)
      (duplicates : List String) : Except String CursorAgentRawJsonScan := do
    match cursorAgentDropRawJsonWhitespace chars with
    | [] => .error "unterminated JSON array"
    | ']' :: rest => pure { rest, duplicatePaths := duplicates }
    | valueChars =>
        let value ← cursorAgentScanRawJsonValue valueChars s!"{path}[{index}]"
        let duplicates := duplicates ++ value.duplicatePaths
        match cursorAgentDropRawJsonWhitespace value.rest with
        | ',' :: tail => cursorAgentScanRawJsonArray tail path (index + 1) duplicates
        | ']' :: tail => pure { rest := tail, duplicatePaths := duplicates }
        | _ => .error "JSON array member is missing ',' or ']'"
end

private def cursorAgentRawJsonDuplicatePaths
    (text : String) : Except String (List String) := do
  let scanned ← cursorAgentScanRawJsonValue text.toList ""
  if (cursorAgentDropRawJsonWhitespace scanned.rest).isEmpty then
    pure scanned.duplicatePaths
  else
    .error "trailing content after JSON value"

private def cursorAgentParseJsonLine (line : Nat) (text : String) : Except String Json := do
  let duplicatePaths ← match cursorAgentRawJsonDuplicatePaths text with
    | .ok paths => pure paths
    | .error error =>
        throw s!"line{line}: raw JSON duplicate scan failed: {error}"
  match duplicatePaths with
  | path :: _ => throw s!"line{line}: duplicate JSON object key '{path}'"
  | [] =>
      match Json.parse text with
      | .ok parsed => pure parsed
      | .error error => throw s!"line{line}: malformed JSON: {error}"

/-! ## Import: cursor-agent CLI JSONL → Loom IR -/

/-- cursor-agent JSONL → Loom IR. Linear single thread; entry identity is
synthesized (logged), while native tool-call ids are retained exactly as optional
source data. Time is absent. Recognized malformed records fail the import. Valid
`turn_ended` and unknown/foreign records are retained as inert raw events, never
conversation text. Unknown content kinds are retained verbatim; malformed known
content kinds and lexical duplicate object members are rejected. -/
def importCursorAgent (text : String) : Except String Transcript := do
  let rawLines := (text.splitOn "\n").zipIdx.filter (fun (line, _) => !line.isEmpty)
  let jsons ← rawLines.mapM (fun (raw, lineIdx) => do
    let line := lineIdx + 1
    pure (← cursorAgentParseJsonLine line raw, line))
  let mut entries : Array Entry := #[]
  let mut notes : Array ImportNote := #[]
  let mut entryCounter : Nat := 0
  let mut usedToolIds : List String := []
  for (j, line) in jsons do
    let sourceRef := s!"line{line}"
    let record ← classifyCursorAgentRecord line j
    let mut disposition := EntryDisposition.native
    let payload ← match record with
      | .historical =>
          match cursorAgentHistoricalEntryPayload? j with
          | some payload =>
              disposition := .historicalUnverified
              pure payload
          | none => throw s!"{sourceRef}: malformed agent-convert historical entry carrier"
      | .turnEnded =>
          pure (Payload.event (.custom "cursor_agent.turn_ended" j))
      | .unknown label =>
          notes := notes.push {
            kind := .other "cursorAgentUnmodeledRecord", loc := some sourceRef,
            detail := s!"retained inert open-world record '{label}'" }
          pure (Payload.event (.custom label j))
      | .message "user" content =>
          let mut blocks : Array UserBlock := #[]
          for (b, blockIdx) in content.zipIdx do
            let ctx := s!"{sourceRef}.message.content[{blockIdx}]"
            match b.getObjVal? "type" with
            | .error _ => blocks := blocks.push (.unmodeled "cursor_agent.content" b)
            | .ok (Json.str "text") =>
                blocks := blocks.push (.text (← requireString ctx b "text"))
            | .ok (Json.str "tool_use") =>
                throw s!"{ctx}: tool_use is not valid in a user-authored message"
            | .ok (Json.str kind) => blocks := blocks.push (.unmodeled kind b)
            | .ok _ => throw s!"{ctx}.type: expected string discriminator"
          pure (Payload.userMsg blocks.toList)
      | .message "assistant" content =>
          let mut blocks : Array AssistantBlock := #[]
          for (b, blockIdx) in content.zipIdx do
            let ctx := s!"{sourceRef}.message.content[{blockIdx}]"
            match b.getObjVal? "type" with
            | .error _ => blocks := blocks.push (.unmodeled "cursor_agent.content" b)
            | .ok (Json.str "text") =>
                blocks := blocks.push (.text (← requireString ctx b "text"))
            | .ok (Json.str "tool_use") =>
                let srcRaw ← requireString ctx b "name"
                if srcRaw.isEmpty then
                  throw s!"{ctx}.name: tool name must be non-empty"
                let args ← requireField ctx b "input"
                let sourceId? ← optionalString ctx b "id"
                match sourceId? with
                | some "" => throw s!"{ctx}.id: must be non-empty when present"
                | _ => pure ()
                match sourceId? with
                | some sourceId =>
                    if usedToolIds.contains sourceId then
                      notes := notes.push {
                        kind := .other "cursorAgentDuplicateToolCallId", loc := some ctx,
                        detail := s!"duplicate explicit tool-call id '{sourceId}' retained unchanged in ToolCall.rawId" }
                    usedToolIds := sourceId :: usedToolIds
                | none =>
                    notes := notes.push {
                      kind := .other "cursorAgentMissingToolCallId", loc := some ctx,
                      detail := "native tool-call id is absent or null; retained as ToolCall.rawId = none" }
                let canonical := cursorCanonicalTool (some srcRaw)
                blocks := blocks.push (.toolCall { raw := srcRaw, canonical } args sourceId?)
                if canonical.isSome then
                  notes := notes.push {
                    kind := .toolNameMapped, loc := some sourceRef,
                    detail := s!"tool name '{srcRaw}' interpreted as '{piToolName (some srcRaw)}' (raw preserved)" }
            | .ok (Json.str "agent_convert_tool_call") =>
                let srcRaw ← requireString ctx b "rawName"
                if srcRaw.isEmpty then
                  throw s!"{ctx}.rawName: historical tool name must be non-empty"
                let args ← requireField ctx b "args"
                let sourceId? ← optionalString ctx b "rawId"
                match sourceId? with
                | some sourceId =>
                    if usedToolIds.contains sourceId then
                      notes := notes.push {
                        kind := .other "cursorAgentHistoricalDuplicateToolCallId",
                        loc := some ctx,
                        detail := s!"duplicate historical tool-call id '{sourceId}' retained unchanged in ToolCall.rawId" }
                    usedToolIds := sourceId :: usedToolIds
                | none =>
                    notes := notes.push {
                      kind := .other "cursorAgentHistoricalMissingToolCallId",
                      loc := some ctx,
                      detail := "historical tool-call id is absent or null; retained as ToolCall.rawId = none" }
                disposition := .historicalUnverified
                blocks := blocks.push (.toolCall {
                  raw := srcRaw, canonical := cursorCanonicalTool (some srcRaw) }
                  args sourceId?)
            | .ok (Json.str kind) => blocks := blocks.push (.unmodeled kind b)
            | .ok _ => throw s!"{ctx}.type: expected string discriminator"
          pure (Payload.assistantMsg blocks.toList)
      | .message role _ => throw s!"{sourceRef}.role: unsupported role '{role}'"
    entryCounter := entryCounter + 1
    let caId := s!"ca{pad4 entryCounter}"
    let idx := entries.size
    entries := entries.push {
      parent := if idx == 0 then none else some (idx - 1),
      thread := 0, time := Time.absent, payload,
      origin := { format := .cursorAgent, sourceRef, rawId := none,
                  extras := some (Json.mkObj [("rawRecord", j)]) },
      disposition }
    if disposition == EntryDisposition.historicalUnverified then
      notes := notes.push {
        kind := .other "unverifiedAgentConvertCarrier", loc := some sourceRef,
        detail := "exact in-band agent-convert carrier decoded as historical, unverified data" }
    notes := notes.push {
      kind := .idSynthesized, loc := some sourceRef,
      detail := s!"synthesized entry id {caId} (cursor-agent has no per-entry identity)" }
  let activeLeaf := if entries.isEmpty then none else some (entries.size - 1)
  if let some leaf := activeLeaf then
    notes := notes.push {
      kind := .activeLeafGuessed, loc := some s!"entry{leaf}",
      detail := "cursor-agent records no active selection; selected the final linear entry by file order" }
  pure {
    threads     := #[{ kind := .main }],
    entries     := entries,
    env         := { cwd := none },
    activeLeaf  := activeLeaf,
    importNotes := notes.toList,
    origin      := { format := .cursorAgent, sourceRef := "importCursorAgent", rawId := none }
  }

/-! ## Actuator: the only IO. -/

/-- Recover identity only from the two observed native Cursor layouts:

* `.cursor/projects/<project>/agent-transcripts/<session>/<session>.jsonl`
* `.cursor/projects/<project>/agent-transcripts/<session>/subagents/<child>.jsonl`

The immediate ancestry and, for a root, stem-directory equality are required.
An arbitrary `.jsonl` filename or a similarly named converter output therefore
does not become evidence of session identity. No cwd is inferred: the
project-directory slug is not injectively decodable. -/
def cursorAgentSessionIdFromPath (path : System.FilePath) : Option String :=
  if path.extension != some "jsonl" then none
  else
    match path.fileStem, path.components.reverse with
    | some stem,
      _file :: session :: "agent-transcripts" :: project :: "projects" :: ".cursor" :: _ =>
        if !stem.isEmpty && !project.isEmpty && stem == session then some stem else none
    | some stem,
      _file :: "subagents" :: session :: "agent-transcripts" :: project ::
        "projects" :: ".cursor" :: _ =>
        if !stem.isEmpty && !session.isEmpty && !project.isEmpty then some stem else none
    | _, _ => none

/-- Path-aware pure import. In addition to record content, it records the exact
source path and restores the session id when `cursorAgentSessionIdFromPath`
recognizes the native filename convention. Callers that know the input path
should use this primitive instead of `importCursorAgent`. -/
def importCursorAgentAtPath (path : System.FilePath) (text : String) : Except String Transcript := do
  let transcript ← importCursorAgent text
  let sessionId := cursorAgentSessionIdFromPath path
  pure { transcript with
    env := { transcript.env with sessionId }
    origin := {
      transcript.origin with
      sourceRef := path.toString
      rawId := sessionId
      extras := some (Json.mkObj [("sourcePath", Json.str path.toString)]) } }

/-- Read a cursor-agent CLI session file using the path-aware import contract. -/
def importCursorAgentFile (path : System.FilePath) : IO (Except String Transcript) := do
  let text ← IO.FS.readFile path
  pure (importCursorAgentAtPath path text)

/-! ## Fixture + self-verification -/

/-- Synthesized linear fixture (structure only — no real content): a user text
message, an assistant message (text + a `tool_use` block whose raw `Bash` name
has canonical interpretation `.bash`), and a `turn_ended` record retained as an
inert event. Mirrors `parity/fixtures/cursor-agent.jsonl` byte-for-byte. -/
def cursorAgentFixture : String := String.intercalate "\n" [
  "{\"role\":\"user\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}}",
  "{\"role\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"yo\"},{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{}}]}}",
  "{\"type\":\"turn_ended\",\"status\":\"completed\"}"
]

-- Import works: two messages plus the retained turn event, all well-formed.
example :
    (match importCursorAgent cursorAgentFixture with
     | .ok t => t.entries.size == 3 && (Loom.violations t).isEmpty &&
         t.activeLeaf == some 2 && t.env.cwd.isNone &&
         t.importNotes.any (fun note => note.kind == .activeLeafGuessed) &&
         t.entries.toList.all (fun entry => entry.origin.rawId.isNone)
     | .error _ => false) = true := by native_decide

/-- Open-world fixture: both source roles carry content kinds unknown to this
version of the importer. Missing discriminators are unknown rather than
malformed instances of a known variant, so they are retained too. -/
def cursorAgentUnknownContentFixture : String := String.intercalate "\n" [
  "{\"role\":\"user\",\"message\":{\"content\":[{\"type\":\"future_user\",\"value\":\"kept-user\"},{\"value\":\"missing-user\"}]}}",
  "{\"role\":\"assistant\",\"message\":{\"content\":[{\"type\":\"future_assistant\",\"value\":\"kept-assistant\"},{\"value\":\"missing-assistant\"}]}}"
]

private def cursorAgentUnknownContentShape (t : Transcript) : Bool :=
  match t.entries[0]?, t.entries[1]? with
  | some userEntry, some assistantEntry =>
      match userEntry.payload, assistantEntry.payload with
      | .userMsg [UserBlock.unmodeled userLabel userRaw,
          UserBlock.unmodeled userMissingLabel userMissingRaw],
        .assistantMsg [AssistantBlock.unmodeled assistantLabel assistantRaw,
          AssistantBlock.unmodeled assistantMissingLabel assistantMissingRaw] =>
          t.entries.size == 2 &&
          userLabel == "future_user" && ostr userRaw "value" == some "kept-user" &&
          userMissingLabel == "cursor_agent.content" &&
            ostr userMissingRaw "value" == some "missing-user" &&
          assistantLabel == "future_assistant" &&
            ostr assistantRaw "value" == some "kept-assistant" &&
          assistantMissingLabel == "cursor_agent.content" &&
            ostr assistantMissingRaw "value" == some "missing-assistant"
      | _, _ => false
  | _, _ => false

def cursorAgentUnknownContentRetained : Bool :=
  match importCursorAgent cursorAgentUnknownContentFixture with
  | .ok t => cursorAgentUnknownContentShape t
  | .error _ => false

example : cursorAgentUnknownContentRetained = true := by native_decide

private def cursorAgentRejects (text : String) : Bool :=
  match importCursorAgent text with
  | .error _ => true
  | .ok _ => false

/-- Known record and block variants are fail-closed when their required fields
are absent, mistyped, empty, or attributed to the wrong author. -/
def cursorAgentMalformedKnownShapesRejected : Bool :=
  [
    "{\"role\":\"user\",\"message\":null}",
    "{\"role\":\"user\",\"message\":{\"content\":{}}}",
    "{\"role\":\"user\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":7}]}}",
    "{\"role\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{}}]}}",
    "{\"role\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"input\":{}}]}}",
    "{\"role\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"\",\"input\":{}}]}}",
    "{\"role\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\"}]}}",
    "{\"role\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{},\"id\":7}]}}",
    "{\"role\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{},\"id\":\"\"}]}}",
    "{\"type\":\"turn_ended\",\"status\":7}",
    "{\"type\":\"turn_ended\",\"status\":\"error\"}"
  ].all cursorAgentRejects

example : cursorAgentMalformedKnownShapesRejected = true := by native_decide

private def cursorAgentDuplicateKeyRejectedAt
    (text : String) (line : Nat) (path : String) : Bool :=
  match importCursorAgent text with
  | .error error => error == s!"line{line}: duplicate JSON object key '{path}'"
  | .ok _ => false

/-- Duplicate object members are rejected from raw JSON before map-backed
parsing. Escaped keys collide after JSON decoding, paths traverse nested arrays,
and equal keys in separate sibling objects or string contents remain valid. -/
def cursorAgentLexicalDuplicateKeysAreRejectedStructurally : Bool :=
  let native :=
    "{\"role\":\"assistant\",\"message\":{\"content\":[{" ++
    "\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{}," ++
    "\"id\":\"first\",\"\\u0069d\":\"second\"}]}}"
  let additive :=
    "{\"role\":\"assistant\",\"message\":{\"content\":[{" ++
    "\"type\":\"agent_convert_tool_call\",\"rawName\":\"Bash\"," ++
    "\"args\":{},\"rawId\":null,\"raw\\u0049d\":\"second\"}]}}"
  let wholeCarrier :=
    "{\"type\":\"" ++ cursorAgentHistoricalRecordType ++
    "\",\"protocol\":\"" ++ cursorAgentHistoricalProtocol ++
    "\",\"payload\":{\"kind\":\"assistantMsg\",\"blocks\":[{" ++
    "\"kind\":\"toolCall\",\"name\":\"Bash\",\"canonical\":\"bash\"," ++
    "\"arguments\":{},\"rawId\":null,\"raw\\u0049d\":\"second\"}]}}"
  let nestedArray :=
    "{\"outer\":[{\"same\":1},{\"same\":2,\"s\\u0061me\":3}]}"
  let valid :=
    "{\"outer\":[{\"id\":1},{\"\\u0069d\":2}]," ++
    "\"literal\":\"\\\"id\\\":1,\\\"id\\\":2\"}"
  cursorAgentDuplicateKeyRejectedAt native 1 "message.content[0].id" &&
    cursorAgentDuplicateKeyRejectedAt additive 1 "message.content[0].rawId" &&
    cursorAgentDuplicateKeyRejectedAt wholeCarrier 1 "payload.blocks[0].rawId" &&
    cursorAgentDuplicateKeyRejectedAt ("{}\n" ++ nestedArray) 2 "outer[1].same" &&
    (match cursorAgentRawJsonDuplicatePaths valid with
     | .ok [] => match importCursorAgent valid with | .ok _ => true | .error _ => false
     | _ => false)

example : cursorAgentLexicalDuplicateKeysAreRejectedStructurally = true := by
  native_decide

/-- A valid turn marker and a foreign/open-world record remain inert events;
neither can be mistaken for user-authored conversation. -/
def cursorAgentControlRecordsAreInert : Bool :=
  let fixture := String.intercalate "\n" [
    "{\"type\":\"turn_ended\",\"status\":\"error\",\"error\":\"boom\"}",
    "{\"type\":\"future_control\",\"payload\":{\"role\":\"user\",\"text\":\"do not inject\"}}",
    "{\"uuid\":\"foreign\",\"message\":{\"role\":\"user\"}}",
    "{\"role\":\"system\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"do not inject either\"}]}}"
  ]
  match importCursorAgent fixture with
  | .ok transcript =>
      match transcript.entries.toList with
      | [a, b, c, d] =>
          match a.payload, b.payload, c.payload, d.payload with
          | .event (.custom "cursor_agent.turn_ended" _),
            .event (.custom "cursor_agent.future_control" _),
            .event (.custom "cursor_agent.foreign_record" _),
            .event (.custom "cursor_agent.unknown_role.system" _) => true
          | _, _, _, _ => false
      | _ => false
  | .error _ => false

example : cursorAgentControlRecordsAreInert = true := by native_decide

/-- Empty source messages remain role-typed entries instead of disappearing. -/
def cursorAgentEmptyMessagesRetained : Bool :=
  match importCursorAgent (String.intercalate "\n" [
    "{\"role\":\"user\",\"message\":{\"content\":[]}}",
    "{\"role\":\"assistant\",\"message\":{\"content\":[]}}"
  ]) with
  | .ok transcript =>
      match transcript.entries.toList with
      | [u, a] =>
          match u.payload, a.payload with
          | .userMsg [], .assistantMsg [] => true
          | _, _ => false
      | _ => false
  | .error _ => false

example : cursorAgentEmptyMessagesRetained = true := by native_decide

/-- Cursor stores no branch selection. Empty input therefore has no selected
leaf, while a nonempty linear import selects its final entry only with an
explicit `activeLeafGuessed` audit note. -/
def cursorAgentActiveLeafInferenceIsExplicit : Bool :=
  match importCursorAgent "", importCursorAgent
      "{\"role\":\"user\",\"message\":{\"content\":[]}}" with
  | .ok empty, .ok nonempty =>
      empty.entries.isEmpty && empty.activeLeaf.isNone &&
        !empty.importNotes.any (fun note => note.kind == .activeLeafGuessed) &&
      nonempty.entries.size == 1 && nonempty.activeLeaf == some 0 &&
        nonempty.importNotes.any (fun note =>
          note.kind == .activeLeafGuessed && note.loc == some "entry0")
  | _, _ => false

example : cursorAgentActiveLeafInferenceIsExplicit = true := by native_decide

/-- Full source records remain available as exact raw provenance, including
additive fields outside the currently modeled schema. -/
def cursorAgentRawRecordProvenanceExact : Bool :=
  let source := "{\"role\":\"user\",\"futureTop\":{\"n\":1},\"message\":{\"futureNested\":true,\"content\":[{\"type\":\"text\",\"text\":\"hello\",\"futureBlock\":\"kept\"}]}}"
  match Json.parse source, importCursorAgent source with
  | .ok raw, .ok transcript =>
      let rawRecord? := transcript.entries[0]?.bind (fun entry => entry.origin.extras)
        |>.bind (fun extras => oobj extras "rawRecord")
      rawRecord?.map Json.compress == some raw.compress
  | _, _ => false

example : cursorAgentRawRecordProvenanceExact = true := by native_decide

/-- Cross-parity golden captured from the TS toolchain (`parseSession` →
`adaptCursorAgent`) via `parity/capture-parity.ts`, positional projection. -/
private def cursorAgentParityFixture : String := String.intercalate "\n" [
  "{\"role\":\"user\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}}",
  "{\"role\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"yo\"},{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{}}]}}"
]

def cursorAgentCase1 : CrossParityCase := {
  name     := "cursor-agent",
  input    := cursorAgentParityFixture,
  tsGolden := "session\n0|-|user|text:hi\n1|0|assistant|text:yo;call"
}

/-- THE DECIDE-PIN (cross-parity, RC1): the Lean cursor-agent importer agrees
with the TS reference oracle. If either side drifts, this stops compiling. -/
example : crossParityOkWith importCursorAgent cursorAgentCase1 = true := by native_decide

/-! ## Export: Loom IR → cursor-agent JSONL

Cursor's runtime schema has no session header, per-entry ids, timestamps, cwd,
tool results, thinking, media, compactions, or meta events. The checked runtime
exporter therefore accepts only native user/assistant text and exact imported
`tool_use` blocks. The broader same-format archival codec wraps every unsupported
payload in a versioned inert carrier instead of dropping it or rendering it as
native syntax. Native tool-call ids retain their exact absent/null/string shape
through raw provenance; synthesized entry ids remain outside the file format. -/

/-! Environment values and foreign entry provenance are not target-native
Cursor semantics. An ignored additive field could archive bytes, but the Cursor
harness would not restore cwd/model/session behavior from it. Generic conversion
policy must therefore continue to report or refuse operational environment and
raw-provenance loss. In particular, a native-looking tool name/input is not
provenance: only an unchanged `tool_use` block retained by this importer may be
re-emitted as executable Cursor syntax. -/

/-- Render one user-authored block to a cursor-agent content block. Under the
role-content-sum a `UserBlock` can only be `text` / `media` / `unmodeled`;
`UserBlock.text` → `{type:"text", text}`, source-native `unmodeled` → its exact
raw block, and media has no cursor-agent form. -/
def exportUserBlock : UserBlock → Option Json
  | UserBlock.text s =>
      some (Json.mkObj [("type", Json.str "text"), ("text", Json.str s)])
  | UserBlock.unmodeled _ raw => some raw
  | _ => none  -- media: unrepresentable

private def cursorAgentNativeToolInput (name : ToolName) (args : Json) : Bool :=
  match args with
  | Json.obj _ => true
  | Json.str _ => name.raw == "ApplyPatch"
  | _ => false

/-- Can Cursor's own `tool_use` block hold everything this call asserts?

The block has exactly three slots — `name`, `input`, and an optional `id`
(census 2026-07-06, `Loom.Formats.CursorAgent`) — and no slot for a canonical
tool identity: `importCursorAgent` always *re-derives* `ToolName.canonical`
from the raw name via `cursorCanonicalTool`. A call whose canonical identity
disagrees with that derivation therefore cannot travel natively without
silently replacing an interpretation the source asserted, so it keeps the
carrier. `canonical := none` is not such an assertion — Claude and Codex both
import that way — and re-deriving it on the way back in is Loom's own reading
of the same name, not a claim about the source.

This is a question about the TARGET and about the DATUM only. It deliberately
takes no source format: `LoomOps.Interop.EmissionDeterminant.sourceProvenance`
is never a legitimate input, and gating on it here is what made every foreign
tool call arrive at Cursor as an inert carrier. -/
def cursorAgentToolCallIsNativeRepresentable
    (name : ToolName) (args : Json) (rawId : Option String) : Bool :=
  !name.raw.isEmpty &&
    (name.canonical.isNone || name.canonical == cursorCanonicalTool (some name.raw)) &&
    cursorAgentNativeToolInput name args &&
    (match rawId with | some id => !id.isEmpty | none => true)

/-- Render a representable call as Cursor's native `tool_use` block. An absent
source id stays absent rather than being minted: `Interop.knownLosses` rates
`fabricateCallId` corrupting, and Cursor's own corpus carries id-less calls. -/
def cursorAgentNativeToolBlock (name : ToolName) (args : Json)
    (rawId : Option String) : Json :=
  Json.mkObj ([("type", Json.str "tool_use"), ("name", Json.str name.raw),
    ("input", args)] ++
    match rawId with | some id => [("id", Json.str id)] | none => [])

private def cursorAgentForeignToolCarrier (name : ToolName) (args : Json)
    (rawId : Option String) : Json :=
  Json.mkObj ([("type", Json.str "agent_convert_tool_call"),
    ("rawName", Json.str name.raw), ("args", args)] ++
    match rawId with | some id => [("rawId", Json.str id)] | none => [])

/-- Context-free rendering has no imported-record evidence, so a tool call is
always an inert carrier. Entry-aware same-format export below is the only path
that can recover an exact native `tool_use`. Every source-native `unmodeled`
block returns its exact raw JSON; thinking and media have no cursor-agent form
in this standalone helper (`none`); entry-level archival export carries the
whole containing payload instead. -/
def exportAssistantBlock : AssistantBlock → Option Json
  | AssistantBlock.text s =>
      some (Json.mkObj [("type", Json.str "text"), ("text", Json.str s)])
  | AssistantBlock.toolCall name args rawId =>
      some (cursorAgentForeignToolCarrier name args rawId)
  | AssistantBlock.unmodeled _ raw => some raw
  | _ => none  -- thinking / media: unrepresentable

private def overlayJsonFields (raw : Json) (modeledKeys : List String)
    (fields : List (String × Json)) : Json :=
  match raw with
  | .obj obj =>
      let obj := modeledKeys.foldl (fun acc key => acc.erase key) obj
      Json.obj (fields.foldl (fun acc field => acc.insert field.1 field.2) obj)
  | _ => Json.mkObj fields

private def cursorAgentRawRecord (e : Loom.Entry) : Option Json :=
  if e.origin.format == Loom.Format.cursorAgent then
    e.origin.extras.bind (fun extras => oobj extras "rawRecord")
  else none

private def cursorAgentRawContent (rawRecord : Option Json) : Option (Array Json) :=
  rawRecord.bind (fun record => oobj record "message") |>.bind fun message =>
    (message.getObjVal? "content" >>= Json.getArr?).toOption

private def cursorAgentRawBlock (rawRecord : Option Json) (idx : Nat) : Option Json :=
  (cursorAgentRawContent rawRecord).bind fun content => content[idx]?

private def cursorAgentHistoricalRawBlock (rawRecord : Json) (idx : Nat) : Option Json := do
  guard (ostr rawRecord "type" == some cursorAgentHistoricalRecordType)
  guard (ostr rawRecord "protocol" == some cursorAgentHistoricalProtocol)
  let payload ← oobj rawRecord "payload"
  guard (ostr payload "kind" == some "assistantMsg")
  let blocks ← oarr payload "blocks"
  blocks[idx]?

private def cursorAgentMatchingRawToolId? (raw : Json)
    (discriminator expected keyName keyArgs keyId : String)
    (name : ToolName) (args : Json) (rawId : Option String) : Option CursorHistoricalRawId := do
  guard (ostr raw discriminator == some expected)
  guard (ostr raw keyName == some name.raw)
  guard (oobj raw keyArgs == some args)
  let sourceRawId ← cursorHistoricalRawId? raw keyId
  guard (sourceRawId.value == rawId)
  pure sourceRawId

/-- Recover the exact source spelling of a historical tool id. A first archive
reads it from the imported Cursor block; later archives read it from the prior
historical carrier. Any mismatch falls back to the semantic value instead of
replaying stale provenance. -/
private def cursorAgentSourceRawToolId? (entry : Entry) (blockIdx : Nat)
    (name : ToolName) (args : Json) (rawId : Option String) : Option CursorHistoricalRawId := do
  let rawRecord ← cursorAgentRawRecord entry
  match cursorAgentHistoricalRawBlock rawRecord blockIdx with
  | some raw =>
      cursorAgentMatchingRawToolId? raw "kind" "toolCall" "name" "arguments" "rawId"
        name args rawId
  | none =>
      let raw ← cursorAgentRawBlock (some rawRecord) blockIdx
      match ostr raw "type" with
      | some "tool_use" =>
          cursorAgentMatchingRawToolId? raw "type" "tool_use" "name" "input" "id"
            name args rawId
      | some "agent_convert_tool_call" =>
          cursorAgentMatchingRawToolId? raw "type" "agent_convert_tool_call"
            "rawName" "args" "rawId"
            name args rawId
      | _ => none

private def cursorHistoricalEntryPayloadJson (entry : Entry) : Json :=
  match entry.payload with
  | .assistantMsg blocks => Json.mkObj [
      ("kind", Json.str "assistantMsg"),
      ("blocks", Json.arr (blocks.zipIdx.map (fun (block, blockIdx) =>
        let sourceRawId? := match block with
          | .toolCall name args rawId =>
              cursorAgentSourceRawToolId? entry blockIdx name args rawId
          | _ => none
        cursorHistoricalAssistantBlockJsonWithRawId sourceRawId? block)).toArray)]
  | payload => cursorHistoricalPayloadJson payload

/-- Preserve the original Cursor object as inert provenance. After an archive
hop, unwrap only the prior carrier's validated provenance field so carriers do
not recursively nest. This value is never a source of runtime authorization. -/
private def cursorAgentHistoricalSourceRawRecord? (entry : Entry) : Option Json := do
  let rawRecord ← cursorAgentRawRecord entry
  if ostr rawRecord "type" == some cursorAgentHistoricalRecordType &&
      ostr rawRecord "protocol" == some cursorAgentHistoricalProtocol then
    match rawRecord.getObjVal? cursorAgentHistoricalSourceRawRecordKey with
    | .ok source@(Json.obj _) => some source
    | _ => none
  else
    match rawRecord with
    | source@(Json.obj _) => some source
    | _ => none

private def cursorAgentHistoricalEntryCarrier (entry : Entry) : Json :=
  Json.mkObj ([
    ("type", Json.str cursorAgentHistoricalRecordType),
    ("protocol", Json.str cursorAgentHistoricalProtocol),
    ("payload", cursorHistoricalEntryPayloadJson entry)] ++
    (cursorAgentHistoricalSourceRawRecord? entry).toList.map (fun source =>
      (cursorAgentHistoricalSourceRawRecordKey, source)))

/-- Exact imported Cursor evidence for one executable block. Shape alone is not
authority: the retained outer record must classify as a native assistant message,
and the same block occurrence must agree on raw name, its canonical interpretation,
input, and optional source id. This admits honest absent/null ids and retains
duplicates without authorizing mutated semantics or inert/event provenance. -/
private def cursorAgentExactImportedToolBlock? (e : Entry) (blockIdx : Nat)
    (name : ToolName) (args : Json) (rawId : Option String) : Option Json := do
  guard (e.disposition == EntryDisposition.native)
  guard (e.origin.format == Format.cursorAgent)
  let rawRecord ← cursorAgentRawRecord e
  let content ← match classifyCursorAgentRecord 0 rawRecord with
    | .ok (.message "assistant" content) => some content
    | _ => none
  let raw ← content[blockIdx]?
  guard (ostr raw "type" == some "tool_use")
  let rawName ← ostr raw "name"
  guard (rawName == name.raw)
  guard (name.canonical == cursorCanonicalTool (some rawName))
  guard (oobj raw "input" == some args)
  let sourceId ← (optionalString "cursor-agent raw tool block" raw "id").toOption
  guard (sourceId == rawId)
  guard (cursorAgentNativeToolInput name args)
  pure raw

/-- The exact bytes this call would occupy in a native Cursor artifact, when it
can occupy any.

Two disjoint routes, and neither asks which harness produced the transcript:

* a Cursor-origin entry must agree with its own retained raw record, which is
  the anti-laundering guard — a modeled payload mutated away from the record it
  claims to come from cannot re-authorize itself as executable target data;
* every other entry is judged purely on target capability and structural
  validity, and renders the block the exporter will write.

Before this second route existed, `cursorAgentExactImportedToolBlock?` was the
only route, so a native `tool_use` was reachable only when source == target —
the one case where no conversion happens (`LoomOps.Interop` §"the defect class
in one sentence"). -/
private def cursorAgentNativeToolBlockFor? (e : Entry) (blockIdx : Nat)
    (name : ToolName) (args : Json) (rawId : Option String) : Option Json :=
  match cursorAgentExactImportedToolBlock? e blockIdx name args rawId with
  | some raw => some raw
  | none =>
      if e.origin.format == Format.cursorAgent then none
      else if e.disposition != EntryDisposition.native then none
      else if cursorAgentToolCallIsNativeRepresentable name args rawId then
        some (cursorAgentNativeToolBlock name args rawId)
      else none

/-- Conservative authority intrinsic to the validated native source call.
Explicit nonempty ids are the primary key. Calls with no semantic id (missing or
null in Cursor JSON) use the canonical JSON data of the exact retained source
block. Neither mutable `sourceRef` nor modeled block placement participates.

This establishes structural consistency only. A retained JSON block is not
cryptographic provenance, and a party able to forge both modeled data and raw
provenance can also forge this key. -/
private inductive CursorAgentToolAuthorityKey where
  | explicitId (rawId : String)
  | anonymousBlock (canonicalSourceBlock : String)
  deriving Repr, DecidableEq, BEq

private def cursorAgentToolAuthorityKey? (entry : Entry) (blockIdx : Nat)
    (name : ToolName) (args : Json) (rawId : Option String) :
    Option CursorAgentToolAuthorityKey := do
  let sourceBlock ← cursorAgentNativeToolBlockFor? entry blockIdx name args rawId
  match rawId with
  | some sourceId =>
      guard (!sourceId.isEmpty)
      pure (.explicitId sourceId)
  | none => pure (.anonymousBlock sourceBlock.compress)

private def cursorAgentEntryToolAuthorityKeys
    (entry : Entry) : List CursorAgentToolAuthorityKey :=
  match entry.payload with
  | .assistantMsg blocks => blocks.zipIdx.filterMap (fun (block, blockIdx) =>
      match block with
      | .toolCall name args rawId =>
          cursorAgentToolAuthorityKey? entry blockIdx name args rawId
      | _ => none)
  | _ => []

private def cursorAgentToolAuthorityKeysFresh
    (used keys : List CursorAgentToolAuthorityKey) : Bool := Id.run do
  let mut seen := used
  for key in keys do
    if seen.contains key then return false
    seen := key :: seen
  return true

/-- Retained raw provenance may constrain a modeled message even when every
typed block is representable. In particular, an inert system, `turn_ended`, or
open-world record cannot be reclassified as native dialogue by mutating only its
typed payload. Cursor-origin entries fail closed when their retained raw record
is absent; foreign-format modeled entries remain ordinary conversion inputs and
are judged by their payload. -/
private def cursorAgentRawRecordAuthorizesRole (entry : Entry) (role : String) : Bool :=
  if entry.origin.format != Format.cursorAgent then true
  else
    match cursorAgentRawRecord entry with
    | none => false
    | some rawRecord =>
        match classifyCursorAgentRecord 0 rawRecord with
        | .ok (.message sourceRole _) => sourceRole == role
        | _ => false

private def cursorAgentEntryNeedsHistoricalCarrier (e : Entry) : Bool :=
  e.disposition == EntryDisposition.historicalUnverified ||
    match e.payload with
    | .userMsg blocks =>
        !cursorAgentRawRecordAuthorizesRole e "user" ||
          blocks.any (fun
            | .text _ => false
            | .media _ _ | .unmodeled _ _ => true)
    | .assistantMsg blocks =>
        !cursorAgentRawRecordAuthorizesRole e "assistant" ||
          blocks.zipIdx.any (fun (block, blockIdx) =>
            match block with
            | .text _ => false
            | .toolCall name args rawId =>
                (cursorAgentNativeToolBlockFor? e blockIdx name args rawId).isNone
            | .thinking _ _ | .media _ _ | .unmodeled _ _ => true) ||
          !cursorAgentToolAuthorityKeysFresh []
            (cursorAgentEntryToolAuthorityKeys e)
    | .envMsg _ | .otherMsg _ _ | .compaction _ _ _ | .event _ => true

private def cursorAgentEntryReusesToolAuthority
    (used : List CursorAgentToolAuthorityKey) (entry : Entry) : Bool :=
  !cursorAgentToolAuthorityKeysFresh used
    (cursorAgentEntryToolAuthorityKeys entry)

private def overlayCursorAgentBlock (raw : Option Json) (kind : String)
    (modeledKeys : List String) (fields : List (String × Json)) : Json :=
  match raw with
  | some source =>
      if ostr source "type" == some kind then
        overlayJsonFields source modeledKeys fields
      else Json.mkObj fields
  | none => Json.mkObj fields

private def exportUserBlockPreserving (raw : Option Json) : UserBlock → Option Json
  | UserBlock.text text =>
      some (overlayCursorAgentBlock raw "text" ["type", "text"]
        [("type", Json.str "text"), ("text", Json.str text)])
  | UserBlock.unmodeled _ source => some source
  | _ => none

private def exportAssistantBlockPreserving (entry : Entry) (raw : Option Json)
    (blockIdx : Nat) : AssistantBlock → Option Json
  | AssistantBlock.text text =>
      some (overlayCursorAgentBlock raw "text" ["type", "text"]
        [("type", Json.str "text"), ("text", Json.str text)])
  | AssistantBlock.toolCall name args rawId =>
      match cursorAgentNativeToolBlockFor? entry blockIdx name args rawId with
      | some source => some source
      | none => exportAssistantBlock (.toolCall name args rawId)
  | AssistantBlock.unmodeled _ source => some source
  | _ => none

private def exportCursorAgentMessage (rawRecord : Option Json) (role : String)
    (content : Array Json) : Json :=
  let messageFields := [("content", Json.arr content)]
  let message := match rawRecord.bind (fun record => oobj record "message") with
    | some rawMessage => overlayJsonFields rawMessage ["content"] messageFields
    | none => Json.mkObj messageFields
  let recordFields := [("role", Json.str role), ("message", message)]
  match rawRecord with
  | some raw => overlayJsonFields raw ["role", "message"] recordFields
  | none => Json.mkObj recordFields

/-- Render one Loom entry to archival cursor-agent JSONL. Only fully
representable user/assistant entries can use native message syntax; every other
entry is encoded whole in an inert historical carrier. Block conversion is
all-or-nothing, so no unsupported block can disappear through filtering. -/
def exportEntry (e : Loom.Entry) : Option Json :=
  if cursorAgentEntryNeedsHistoricalCarrier e then
    some (cursorAgentHistoricalEntryCarrier e)
  else
  let rawRecord := cursorAgentRawRecord e
  match e.payload with
  | Payload.userMsg blocks =>
      match blocks.zipIdx.mapM (fun (block, idx) =>
          exportUserBlockPreserving (cursorAgentRawBlock rawRecord idx) block) with
      | some content =>
          some (exportCursorAgentMessage rawRecord "user" content.toArray)
      | none => some (cursorAgentHistoricalEntryCarrier e)
  | Payload.assistantMsg blocks =>
      match blocks.zipIdx.mapM (fun (block, idx) =>
          exportAssistantBlockPreserving e (cursorAgentRawBlock rawRecord idx) idx block) with
      | some content =>
          some (exportCursorAgentMessage rawRecord "assistant" content.toArray)
      | none => some (cursorAgentHistoricalEntryCarrier e)
  | _ => some (cursorAgentHistoricalEntryCarrier e)

/-- Render in transcript order while consuming native tool authority. An
intrinsic authority key can authorize at most one native block; later copies are
archived whole and cannot produce another executable `tool_use`. -/
private def exportCursorAgentEntries (entries : List Entry) : List Json := Id.run do
  let mut used : List CursorAgentToolAuthorityKey := []
  let mut output : Array Json := #[]
  for entry in entries do
    let keys := cursorAgentEntryToolAuthorityKeys entry
    if cursorAgentEntryNeedsHistoricalCarrier entry ||
        cursorAgentEntryReusesToolAuthority used entry then
      output := output.push (cursorAgentHistoricalEntryCarrier entry)
    else
      match exportEntry entry with
      | some record =>
          output := output.push record
      | none => pure ()
    -- Encountered authority remains consumed even when this entry is inert.
    used := keys ++ used
  return output.toList

/-- Archival Loom IR → cursor-agent-shaped JSONL (one compact JSON object per
line). Unsupported entries use inert agent-convert carriers and are not valid
runtime Cursor input. Each structural tool authority key authorizes native syntax
at most once across the transcript. The terminal delimiter keeps continuation
append-safe. -/
def exportCursorAgent (t : Loom.Transcript) : String :=
  let lines := exportCursorAgentEntries t.entries.toList
  String.intercalate "\n" (lines.map Json.compress) ++ "\n"

def cursorAgentTargetControlsKey : String :=
  "target_cursor_agent_controls"

def cursorAgentTargetControlsProtocol : String :=
  "agent-convert.cursor-agent-target-controls.v1"

private structure CursorAgentTargetControls where
  permissionMode : String

private def cursorAgentTargetControlsJson
    (controls : CursorAgentTargetControls) : Json :=
  Json.mkObj [
    ("protocol", Json.str cursorAgentTargetControlsProtocol),
    ("permission_mode", Json.str controls.permissionMode)]

private def parseCursorAgentTargetControls?
    (raw : Json) : Option CursorAgentTargetControls := do
  guard (ostr raw "protocol" == some cursorAgentTargetControlsProtocol)
  let permissionMode ← ostr raw "permission_mode"
  guard (!permissionMode.isEmpty)
  let controls := { permissionMode }
  guard (raw == cursorAgentTargetControlsJson controls)
  pure controls

private def cursorAgentOriginExtra? (t : Transcript) (key : String) : Option Json :=
  t.origin.extras >>= fun extras => oobj extras key

def cursorAgentTargetLaunchOptionKeys : List String := [
  "target_cwd", "target_provider", "target_model", "target_session_id",
  "target_harness_version", "target_timestamp"]

private def cursorAgentTargetLaunchFailures (t : Transcript) : List String :=
  cursorAgentTargetLaunchOptionKeys.filterMap (fun key =>
    if (cursorAgentOriginExtra? t key).isSome then
      some s!"Cursor Agent JSONL has no native field for origin.extras.{key}"
    else none)

private def cursorAgentTargetControlFailures (t : Transcript) : List String :=
  match cursorAgentOriginExtra? t cursorAgentTargetControlsKey with
  | none => []
  | some raw =>
      if (parseCursorAgentTargetControls? raw).isSome then
        [s!"Cursor Agent JSONL cannot encode operational controls from origin.extras.{cursorAgentTargetControlsKey}"]
      else
        [s!"origin.extras.{cursorAgentTargetControlsKey} must be an exact {cursorAgentTargetControlsProtocol} object"]

/-- Cursor Agent stores one implicit linear branch and no selected-leaf field.
A checked target therefore accepts only absence for an empty transcript or the
final entry for a nonempty transcript. -/
def cursorAgentTargetActiveLeafValid (t : Transcript) : Bool :=
  if t.entries.isEmpty then t.activeLeaf.isNone
  else t.activeLeaf == some (t.entries.size - 1)

def cursorAgentActiveLeafPreflightError : String :=
  "Cursor Agent target requires activeLeaf to select the final linear entry"

private def cursorAgentTargetLinear (t : Transcript) : Bool :=
  t.threads.size == 1 &&
  (match t.threads[0]? with
   | some thread => match thread.kind with | .main => true | _ => false
   | none => false) &&
  t.entries.toList.zipIdx.all (fun (entry, idx) =>
    entry.thread == 0 && entry.parent == (if idx == 0 then none else some (idx - 1)))

/-! ### The representable projection

What Cursor's wire format has no slot for, and what happens to each fact.

| Source fact | Cursor slot | Action |
|---|---|---|
| tool RESULT | none — the census found zero `tool_result` records in ~14,863 | dropped, reported as `Obligation.dropToolResults` |
| thinking block | none — the census found zero | dropped, reported as `Obligation.dropThinking` |
| per-entry time | none — no timestamp key on any of the three record shapes | dropped, reported as `Obligation.dropRecordedTime` |
| `EnvInfo` | none — cwd/model/provider appear on no record | dropped, reported as `Obligation.dropEnvironment` |

`LoomOps.Interop.knownLosses` rates each of these `LossImpact.reportable`, and
`Interop.Emission.refused` reserves refusal for artifacts that would assert
something untrue. A Cursor transcript showing tool calls without results and no
reasoning is not a distorted session; it is what every native Cursor session
looks like. Refusing instead made the target unreachable from every real Claude
or Codex source, which is a worse answer to a loss than reporting it.

Tool CALLS are deliberately absent from that table. Cursor *does* have a native
`tool_use` block, so a call missing from an otherwise native artifact asserts
that the assistant did not act — `LossImpact.corrupting`. A call this exporter
cannot render natively still fails `cursorAgentNativePayloadPreflightError`
rather than silently vanishing. Media, unmodeled blocks, compaction, events and
non-dialogue roles likewise keep their existing named refusals. -/

private def cursorAgentRepresentablePayload? : Payload → Option Payload
  | .assistantMsg blocks =>
      some (.assistantMsg (blocks.filter (fun
        | .thinking _ _ => false
        | _ => true)))
  | .envMsg _ => none
  | payload => some payload

/-- Old entry index → its representative in the projection. A kept entry maps to
its new index; a dropped one stands in for its nearest kept ancestor, so excising
a tool-result entry rejoins the parent chain instead of severing it. -/
private def cursorAgentProjectedIndices (t : Transcript) : Array (Option Nat) := Id.run do
  let mut mapping : Array (Option Nat) := #[]
  let mut next : Nat := 0
  for entry in t.entries do
    match cursorAgentRepresentablePayload? entry.payload with
    | some _ =>
        mapping := mapping.push (some next)
        next := next + 1
    | none =>
        mapping := mapping.push (entry.parent.bind (fun p => (mapping[p]?).getD none))
  return mapping

/-- The transcript exactly as Cursor Agent will hold it. Everything the target
preflight, the renderer and the re-import self-check reason about is this value,
so "what was emitted" and "what was checked" cannot drift apart. -/
def cursorAgentTargetProjection (t : Transcript) : Transcript :=
  let mapping := cursorAgentProjectedIndices t
  let rebase := fun (old : Nat) => (mapping[old]?).getD none
  let entries := (t.entries.toList.zipIdx.filterMap (fun (entry, idx) =>
    (cursorAgentRepresentablePayload? entry.payload).bind (fun payload =>
      match (mapping[idx]?).getD none with
      | none => none
      | some _ => some { entry with
          payload := payload
          parent := entry.parent.bind rebase
          time := Time.absent }))).toArray
  { t with
    entries := entries
    env := {}
    activeLeaf := t.activeLeaf.bind rebase }

/-- The runtime target contract is intentionally narrower than the archival
same-format codec. Cursor consumes user/assistant messages containing text and
native `tool_use` blocks; it does not consume agent-convert historical carriers,
inert control records, or Loom-only block constructors. -/
private def cursorAgentTargetNativeEntryPayload (entry : Entry) : Bool :=
  match entry.payload with
  | .userMsg blocks =>
      cursorAgentRawRecordAuthorizesRole entry "user" &&
        blocks.all (fun
          | .text _ => true
          | _ => false)
  | .assistantMsg blocks =>
      cursorAgentRawRecordAuthorizesRole entry "assistant" &&
        blocks.zipIdx.all (fun (block, blockIdx) =>
          match block with
          | .text _ => true
          | .toolCall name args rawId =>
              (cursorAgentNativeToolBlockFor? entry blockIdx name args rawId).isSome
          | _ => false)
  | _ => false

/-- Checked runtime export fails the whole transcript if an intrinsic tool
authority key would be reused. Source locators and block positions cannot split
authority; distinct explicit ids remain independent even when locators collide. -/
private def cursorAgentTargetToolAuthoritiesUnique (t : Transcript) : Bool := Id.run do
  let mut used : List CursorAgentToolAuthorityKey := []
  for entry in t.entries do
    let keys := cursorAgentEntryToolAuthorityKeys entry
    if !cursorAgentToolAuthorityKeysFresh used keys then return false
    used := keys ++ used
  return true

private def cursorAgentTargetNativeToolIdValid (block : Json) : Bool :=
  match block.getObjVal? "id" with
  | .error _ | .ok Json.null => true
  | .ok (Json.str value) => !value.isEmpty
  | .ok _ => false

private def cursorAgentTargetNativeContentBlock (role : String) (block : Json) : Bool :=
  match ostr block "type" with
  | some "text" => (ostr block "text").isSome
  | some "tool_use" =>
      role == "assistant" &&
        match ostr block "name", (block.getObjVal? "input").toOption with
        | some name, some input =>
            !name.isEmpty &&
              cursorAgentNativeToolInput { raw := name, canonical := none } input &&
              cursorAgentTargetNativeToolIdValid block
        | _, _ => false
  | _ => false

/-- Decidable shape contract for records accepted as runtime Cursor Agent
transcript input. In particular, every top-level `type` record is outside this
contract even though the archival importer deliberately retains such records. -/
private def cursorAgentTargetNativeRecord (record : Json) : Bool :=
  match record with
  | .obj _ =>
      if hasKey record "type" || hasKey record "uuid" ||
          hasKey record "parentUuid" || hasKey record "sessionId" then false
      else
        match ostr record "role", oobj record "message" with
        | some role, some message =>
            (role == "user" || role == "assistant") &&
              (oarr message "content").any (fun content =>
                content.all (cursorAgentTargetNativeContentBlock role))
        | _, _ => false
  | _ => false

private def cursorAgentTargetNativeJsonl (output : String) : Bool :=
  (output.splitOn "\n").filter (fun line => !line.isEmpty) |>.all (fun line =>
    match Json.parse line with
    | .ok record => cursorAgentTargetNativeRecord record
    | .error _ => false)

/-! ### Artifact counts

Counts describe the planned Cursor artifact — after the representable
projection, after carrier selection — and are deliberately not inferred from
source IR counts. Reporting `toolResultsEmitted` from the source would claim
Cursor stored results it structurally cannot store. -/

private def cursorAgentPlannedRecords (t : Transcript) : List Json :=
  exportCursorAgentEntries (cursorAgentTargetProjection t).entries.toList

private def cursorAgentPlannedContentBlocks (record : Json) : List Json :=
  ((oobj record "message").bind (fun message => oarr message "content")).map
    Array.toList |>.getD []

/-- Records the artifact will contain, native or carrier. -/
def cursorAgentTargetRecordCount (t : Transcript) : Nat :=
  (cursorAgentPlannedRecords t).length

/-- `tool_use` blocks in the planned artifact: calls a Cursor session can act on. -/
def cursorAgentNativeToolCallCount (t : Transcript) : Nat :=
  (cursorAgentPlannedRecords t).foldl (fun count record =>
    count + (cursorAgentPlannedContentBlocks record).countP (fun block =>
      ostr block "type" == some "tool_use")) 0

/-- Calls that reached the artifact only as inert data: an
`agent_convert_tool_call` content block, or a `toolCall` inside a whole-entry
historical carrier. Neither is executable Cursor input. -/
def cursorAgentHistoricalToolCallCount (t : Transcript) : Nat :=
  (cursorAgentPlannedRecords t).foldl (fun count record =>
    let inMessage := (cursorAgentPlannedContentBlocks record).countP (fun block =>
      ostr block "type" == some "agent_convert_tool_call")
    let inCarrier :=
      if ostr record "type" == some cursorAgentHistoricalRecordType then
        (((oobj record "payload").bind (fun payload => oarr payload "blocks")).map
          (fun blocks => blocks.toList.countP (fun block =>
            ostr block "kind" == some "toolCall"))).getD 0
      else 0
    count + inMessage + inCarrier) 0

/-- Zero, structurally. The format has no tool-result record: the 2026-07-06
census over 427 files found 16,210 `tool_use` blocks and not one result
(`Loom.Formats.CursorAgent`, claim `L9`). Stated as a definition rather than
left to a generic source-side count so the CLI cannot report otherwise. -/
def cursorAgentNativeToolResultCount (_t : Transcript) : Nat := 0

def cursorAgentHistoricalTargetPreflightError : String :=
  "Cursor Agent runtime target refuses historical-unverified entries because agent-convert carriers are archive-only"

def cursorAgentNativePayloadPreflightError : String :=
  "Cursor Agent runtime target requires native user/assistant messages containing only text and exact imported tool_use blocks"

def cursorAgentReplayedToolSourcePreflightError : String :=
  "Cursor Agent runtime target requires each structural tool authority key to authorize at most one native tool_use block"

/-- The one place a reportable loss becomes a corrupting one.

Dropping tool results and reasoning from a conversation leaves an honest record
of the rest. Dropping *everything* does not: an empty artifact from a nonempty
source asserts that the session had no content, and `LoomOps.Interop.LossImpact`
puts "the artifact would assert something untrue" squarely under `corrupting`,
where `Emission.refused` is the correct answer. A transcript whose entries are
all tool results is the concrete case — it projects to zero records. -/
def cursorAgentEmptyProjectionPreflightError : String :=
  "Cursor Agent target would emit an empty transcript from a nonempty source — every entry is a fact the format cannot hold, and an empty artifact asserts an empty session"

/-- Public refusal census for runtime-facing Cursor Agent export, evaluated on
the representable projection. The format has no runtime contract for the
archival carrier codec, so historical and non-native payloads are rejected
before any bytes are rendered, and it has no transcript slot for explicitly
requested launch options or operational controls — a caller who asks for those
is asking for something the artifact cannot express, which is different from a
fact the source merely happened to carry.

Entry time and source `EnvInfo` used to be refusals here too. They are now
`Obligation.dropRecordedTime` / `dropEnvironment` — reported, not enforced —
because Cursor JSONL has no slot for either, so refusing on them made every
real Claude or Codex session unexportable. See the projection note above. -/
def cursorAgentTargetExportPrerequisiteFailures (t : Transcript) : List String :=
  let projected := cursorAgentTargetProjection t
  let structuralFailures :=
    if (Loom.violations t).isEmpty && (Loom.violations projected).isEmpty &&
        cursorAgentTargetLinear projected then []
    else ["Cursor Agent target requires a well-formed single linear thread"]
  let activeLeafFailures :=
    if cursorAgentTargetActiveLeafValid projected then []
    else [cursorAgentActiveLeafPreflightError]
  let historicalFailures :=
    if projected.entries.any (fun entry =>
        entry.disposition == EntryDisposition.historicalUnverified) then
      [cursorAgentHistoricalTargetPreflightError]
    else []
  let nativePayloadFailures :=
    if projected.entries.all (fun entry =>
        entry.disposition == EntryDisposition.historicalUnverified ||
          cursorAgentTargetNativeEntryPayload entry) then []
    else [cursorAgentNativePayloadPreflightError]
  let replayedToolSourceFailures :=
    if cursorAgentTargetToolAuthoritiesUnique projected then []
    else [cursorAgentReplayedToolSourcePreflightError]
  let emptyProjectionFailures :=
    if projected.entries.isEmpty && !t.entries.isEmpty then
      [cursorAgentEmptyProjectionPreflightError]
    else []
  structuralFailures ++ activeLeafFailures ++ emptyProjectionFailures ++
    historicalFailures ++ nativePayloadFailures ++ replayedToolSourceFailures ++
    cursorAgentTargetLaunchFailures t ++ cursorAgentTargetControlFailures t

def cursorAgentTargetExportReady (t : Transcript) : Bool :=
  (cursorAgentTargetExportPrerequisiteFailures t).isEmpty

/-- Cursor's importer always re-derives `ToolName.canonical` from the raw name,
so a call that asserted nothing comes back asserting Loom's own reading of that
name. Normalising `none` up to that derivation on the source side — and only
`none` — lets the payload comparison see through the one difference the target
is entitled to introduce, while any other change to a canonical identity, in
either direction, still fails the check. -/
private def cursorAgentComparablePayload : Payload → Payload
  | .assistantMsg blocks => .assistantMsg (blocks.map (fun
      | .toolCall name args rawId =>
          .toolCall { name with
            canonical := name.canonical <|> cursorCanonicalTool (some name.raw) }
            args rawId
      | block => block))
  | payload => payload

private def cursorAgentPayloads (t : Transcript) : Array Json :=
  t.entries.map (fun entry =>
    cursorHistoricalPayloadJson (cursorAgentComparablePayload entry.payload))

/-- Runtime-facing exporter. The source is first projected to what Cursor can
hold and checked against the native Cursor record contract, independently of the
broader archival importer. Only then is output rendered, checked again as native
JSONL, and re-imported for structural integrity, selected terminal identity, and
ordered payload recovery — all compared against the projection, so a reported
loss cannot hide an unreported one. -/
def exportCursorAgentTargetChecked (t : Transcript) : Except String String :=
  match cursorAgentTargetExportPrerequisiteFailures t with
  | [] =>
      let projected := cursorAgentTargetProjection t
      let output := exportCursorAgent projected
      if !cursorAgentTargetNativeJsonl output then
        .error "Cursor Agent target renderer produced a record outside the native runtime contract"
      else
        match importCursorAgent output with
        | .error error =>
            .error s!"Cursor Agent target failed self-validation: {error}"
        | .ok restored =>
            if !(Loom.violations restored).isEmpty then
              .error s!"Cursor Agent target re-import has {(Loom.violations restored).length} structural violations"
            else if !cursorAgentTargetActiveLeafValid restored ||
                restored.activeLeaf != projected.activeLeaf then
              .error "Cursor Agent target re-import changed the selected terminal entry"
            else if cursorAgentPayloads restored != cursorAgentPayloads projected then
              .error "Cursor Agent target re-import changed ordered transcript payloads"
            else .ok output
  | failures => .error (String.intercalate "; " failures)

private def cursorAgentCheckedRefuses (t : Transcript) (expected : String) : Bool :=
  (cursorAgentTargetExportPrerequisiteFailures t).contains expected &&
  match exportCursorAgentTargetChecked t with
  | .error error => (error.splitOn "; ").contains expected
  | .ok _ => false

/-- Empty selection remains absent and a native message-only import succeeds.
A non-final selection is a named refusal. Source control records are retained by
archival export but rejected by runtime preflight.

The thinking case INVERTED on 2026-07-26. It used to assert
`cursorAgentNativePayloadPreflightError` for a foreign assistant message whose
only block was a thinking block, which recorded the refuse-on-lossy policy:
Cursor has no reasoning slot at all, so refusing there made an entire class of
real source unexportable for a loss `LoomOps.Interop.knownLosses` rates
`reportable`. The block is now dropped by `cursorAgentTargetProjection`, the
turn survives as an empty assistant message — a shape Cursor's own corpus
contains — and the loss is carried by `Obligation.dropThinking`. Media has no
Cursor slot either but is NOT dropped: it takes the same named refusal as
before, so this pin still proves the runtime contract rejects Loom-only
blocks rather than that it rejects everything lossy. -/
def cursorAgentCheckedSelectionAndTerminalIdentity : Bool :=
  let foreignOrigin : Origin := { format := .pi, sourceRef := "lossy-terminal" }
  let single := fun (blocks : List AssistantBlock) => ({
    threads := #[{ kind := .main }],
    entries := #[{ payload := .assistantMsg blocks, origin := foreignOrigin }],
    activeLeaf := some 0,
    origin := foreignOrigin } : Transcript)
  let thinkingOnly := single [.thinking "not representable" none]
  let mediaOnly := single [.media "image/png" "AAAA"]
  match importCursorAgent "", importCursorAgent cursorAgentParityFixture,
      importCursorAgent cursorAgentFixture with
  | .ok empty, .ok nonempty, .ok archival =>
      cursorAgentTargetActiveLeafValid empty &&
      cursorAgentTargetActiveLeafValid nonempty &&
      (match exportCursorAgentTargetChecked empty with | .ok _ => true | .error _ => false) &&
      (match exportCursorAgentTargetChecked nonempty with
       | .ok output => match importCursorAgent output with
           | .ok restored => restored.activeLeaf == some (restored.entries.size - 1)
           | .error _ => false
       | .error _ => false) &&
      cursorAgentCheckedRefuses { nonempty with activeLeaf := some 0 }
        cursorAgentActiveLeafPreflightError &&
      (match exportCursorAgentTargetChecked thinkingOnly with
       | .ok output =>
           output == "{\"message\":{\"content\":[]},\"role\":\"assistant\"}\n"
       | .error _ => false) &&
      cursorAgentCheckedRefuses mediaOnly cursorAgentNativePayloadPreflightError &&
      cursorAgentCheckedRefuses archival cursorAgentNativePayloadPreflightError &&
      let archivedOutput := exportCursorAgent archival
      !cursorAgentTargetNativeJsonl archivedOutput &&
        match importCursorAgent archivedOutput with
        | .ok restored => restored.entries.size == archival.entries.size
        | .error _ => false
  | _, _, _ => false

example : cursorAgentCheckedSelectionAndTerminalIdentity = true := by native_decide

/-- The projection may shrink a transcript; it may not erase one.

A source whose every entry is a tool result projects to zero records, and an
empty artifact from a nonempty source asserts an empty session — `corrupting`,
not `reportable`, so refusal is the correct answer and `Emission.refused`
applies. An actually empty source still exports to an empty artifact, because
there it asserts nothing false. Mixed content keeps the surviving turns and
reports the dropped results, which is the whole point of the projection. -/
def cursorAgentEmptyProjectionIsRefusedNotEmitted : Bool :=
  let foreignOrigin : Origin := { format := .pi, sourceRef := "empty-projection" }
  let resultOnly : Transcript := {
    threads := #[{ kind := .main }],
    entries := #[{ payload := .envMsg [], origin := foreignOrigin }],
    activeLeaf := some 0,
    origin := foreignOrigin }
  let empty : Transcript := {
    threads := #[{ kind := .main }], entries := #[], activeLeaf := none,
    origin := foreignOrigin }
  let mixed : Transcript := {
    threads := #[{ kind := .main }],
    entries := #[
      { payload := .userMsg [.text "kept"], origin := foreignOrigin },
      { parent := some 0, payload := .envMsg [], origin := foreignOrigin }],
    activeLeaf := some 1,
    origin := foreignOrigin }
  (cursorAgentTargetProjection resultOnly).entries.isEmpty &&
    cursorAgentCheckedRefuses resultOnly cursorAgentEmptyProjectionPreflightError &&
    (match exportCursorAgentTargetChecked empty with
     | .ok output => output == "\n"
     | .error _ => false) &&
    (match exportCursorAgentTargetChecked mixed with
     | .ok output =>
         output == "{\"message\":{\"content\":[{\"text\":\"kept\",\"type\":\"text\"}]},\"role\":\"user\"}\n"
     | .error _ => false)

example : cursorAgentEmptyProjectionIsRefusedNotEmitted = true := by native_decide

private def cursorAgentTargetControlFixture : Json :=
  cursorAgentTargetControlsJson { permissionMode := "plan" }

private def cursorAgentTargetConflictExtras : Json := Json.mkObj [
  ("target_cwd", Json.str "/target/cwd"),
  ("target_provider", Json.str "target-provider"),
  ("target_model", Json.str "target-model"),
  ("target_session_id", Json.str "target-session"),
  ("target_harness_version", Json.str "target-version"),
  ("target_timestamp", Json.str "2026-07-20T00:00:00Z"),
  (cursorAgentTargetControlsKey, cursorAgentTargetControlFixture)]

/-- Cursor has no target-native launch/control record. Every canonical
`target_*` launch option and an exact typed control bundle are surfaced instead
of being conflated or silently ignored. A malformed control bundle has a
distinct validation failure.

Source `EnvInfo` INVERTED on 2026-07-26. It used to be six named refusals here,
which is what made cursor-agent unreachable from every real session: a Claude or
Codex transcript always carries at least a cwd. The distinction the target
actually draws is between a fact the source happened to record — reported as
`Obligation.dropEnvironment`, `LossImpact.reportable`, because Cursor JSONL has
no slot for it and never did — and a launch option the CALLER explicitly asked
this invocation to apply, which the artifact cannot honour and which is
therefore still refused rather than silently ignored. This pin now proves both
halves of that distinction. -/
def cursorAgentEnvironmentAndControlConflictsAreRefused : Bool :=
  match importCursorAgent cursorAgentFixture with
  | .error _ => false
  | .ok imported =>
      let conflicted : Transcript := { imported with
        env := {
          cwd := some "/source/cwd",
          model := some "source-model",
          provider := some "source-provider",
          harnessVersion := some "source-version",
          instructions := some "source instructions",
          sessionId := some "source-session" },
        origin := { imported.origin with
          extras := some cursorAgentTargetConflictExtras } }
      let failures := cursorAgentTargetExportPrerequisiteFailures conflicted
      let malformed : Transcript := { imported with origin := {
        imported.origin with extras := some (Json.mkObj [
          (cursorAgentTargetControlsKey, Json.mkObj [
            ("protocol", Json.str cursorAgentTargetControlsProtocol),
            ("permission_mode", Json.str "plan"),
            ("unexpected", Json.bool true)])]) } }
      let envOnly : Transcript := { conflicted with
        origin := { imported.origin with extras := none } }
      -- Source EnvInfo alone contributes no refusal at any level: not a named
      -- failure, and not a residue in the whole-transcript verdict either.
      ["cwd", "model", "provider", "harnessVersion", "instructions", "sessionId"].all
          (fun field => !failures.contains
            s!"Cursor Agent target cannot preserve source EnvInfo.{field} in transcript JSONL") &&
      ((cursorAgentTargetExportPrerequisiteFailures envOnly).all (fun failure =>
        (failure.splitOn "EnvInfo").length == 1)) &&
      -- The archival fixture's `turn_ended` event is the only reason envOnly is
      -- refused at all; the projection carries no environment complaint.
      cursorAgentCheckedRefuses envOnly cursorAgentNativePayloadPreflightError &&
      cursorAgentTargetLaunchOptionKeys.all (fun key => failures.contains
        s!"Cursor Agent JSONL has no native field for origin.extras.{key}") &&
      failures.contains
        "Cursor Agent JSONL cannot encode operational controls from origin.extras.target_cursor_agent_controls" &&
      (match exportCursorAgentTargetChecked conflicted with
       | .error error =>
           let parts := error.splitOn "; "
           parts.contains
             "Cursor Agent JSONL has no native field for origin.extras.target_cwd" &&
           parts.contains
             "Cursor Agent JSONL cannot encode operational controls from origin.extras.target_cursor_agent_controls"
       | .ok _ => false) &&
      cursorAgentCheckedRefuses malformed
        "origin.extras.target_cursor_agent_controls must be an exact agent-convert.cursor-agent-target-controls.v1 object"

example : cursorAgentEnvironmentAndControlConflictsAreRefused = true := by
  native_decide

private def cursorAgentSourceTargetConfigurationArchiveKey : String :=
  "_agent_convert_source_target_configuration"

private def cursorAgentArchivedTargetConfiguration : Json := Json.mkObj [
  ("protocol", Json.str "agent-convert.source-target-configuration.v1"),
  ("prior", Json.null),
  ("cleared", Json.mkObj [
    ("target_cwd", Json.str "/archive/must-not-activate"),
    ("target_provider", Json.str "archive-provider"),
    ("target_model", Json.str "archive-model"),
    ("target_session_id", Json.str "archive-session"),
    ("target_harness_version", Json.str "archive-version"),
    ("target_timestamp", Json.str "2030-01-01T00:00:00Z"),
    (cursorAgentTargetControlsKey, cursorAgentTargetControlFixture)])]

/-- Nested source target-configuration provenance is not a lookup alias. It
does not trigger launch/control handling, while the same key at the direct
`origin.extras` level is still classified and refused. -/
def cursorAgentArchivedTargetConfigurationNeverActivates : Bool :=
  match importCursorAgent cursorAgentParityFixture with
  | .error _ => false
  | .ok imported =>
      let archived : Transcript := { imported with origin := {
        imported.origin with extras := some (Json.mkObj [
          (cursorAgentSourceTargetConfigurationArchiveKey,
            cursorAgentArchivedTargetConfiguration)]) } }
      let direct : Transcript := { archived with origin := {
        archived.origin with extras := some (Json.mkObj [
          (cursorAgentSourceTargetConfigurationArchiveKey,
            cursorAgentArchivedTargetConfiguration),
          ("target_cwd", Json.str "/direct/refused")]) } }
      cursorAgentTargetExportReady archived &&
      (match exportCursorAgentTargetChecked archived with
       | .ok _ => true
       | .error _ => false) &&
      cursorAgentCheckedRefuses direct
        "Cursor Agent JSONL has no native field for origin.extras.target_cwd"

example : cursorAgentArchivedTargetConfigurationNeverActivates = true := by
  native_decide

/-- Write a runtime Cursor Agent target file. This compatibility API keeps its
`IO Unit` signature, but checked-export refusal is raised as an IO error and no
archive-only bytes are written. -/
def exportCursorAgentFile (path : System.FilePath) (t : Loom.Transcript) : IO Unit :=
  match exportCursorAgentTargetChecked t with
  | .ok output => IO.FS.writeFile path output
  | .error message => throw (IO.userError message)

/-- Write the broader same-format archival codec explicitly. Its historical
carriers preserve unsupported data but are not executable Cursor transcripts. -/
def exportCursorAgentArchiveFile (path : System.FilePath) (t : Loom.Transcript) : IO Unit :=
  IO.FS.writeFile path (exportCursorAgent t)

/-- The open-world blocks are not merely present in the IR: the same-format
exporter writes their exact source JSON and a second import sees the same
unmodeled blocks. -/
def cursorAgentUnknownContentRoundTrips : Bool :=
  match importCursorAgent cursorAgentUnknownContentFixture with
  | .ok t =>
      match importCursorAgent (exportCursorAgent t) with
      | .ok roundTripped => cursorAgentUnknownContentShape roundTripped
      | .error _ => false
  | .error _ => false

example : cursorAgentUnknownContentRoundTrips = true := by native_decide

private def cursorAgentToolNameFixture : String :=
  "{\"role\":\"assistant\",\"message\":{\"content\":[" ++
  "{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{\"cmd\":\"pwd\"}}," ++
  "{\"type\":\"tool_use\",\"name\":\"CustomTOOL\",\"input\":{\"value\":1}}]}}"

/-- Raw spelling and canonical interpretation occupy separate fields. This pin
catches both the mapped `Bash` case and the old lowercase fallback for an
unmapped mixed-case name. -/
def cursorAgentSourceToolNamesAreExact : Bool :=
  match importCursorAgent cursorAgentToolNameFixture with
  | .ok transcript =>
      match transcript.entries[0]? with
      | some entry =>
          match entry.payload with
          | .assistantMsg [
              .toolCall bashName _ _,
              .toolCall customName _ _] =>
                bashName.raw == "Bash" && decide (bashName.canonical = some .bash) &&
                customName.raw == "CustomTOOL" && decide (customName.canonical = none)
          | _ => false
      | none => false
  | .error _ => false

example : cursorAgentSourceToolNamesAreExact = true := by native_decide

/-- Current cursor-agent vocabulary is interpreted without rewriting source
spelling. The live 430-file census contains 311 `ApplyPatch` calls, all with a
raw string input; arbitrary JSON is valid `ToolCall.args` and remains exact. -/
def cursorAgentCurrentToolVocabularyAndStringPatch : Bool :=
  let source :=
    "{\"role\":\"assistant\",\"message\":{\"content\":[" ++
    "{\"type\":\"tool_use\",\"name\":\"Shell\",\"input\":{}}," ++
    "{\"type\":\"tool_use\",\"name\":\"StrReplace\",\"input\":{}}," ++
    "{\"type\":\"tool_use\",\"name\":\"ReadFile\",\"input\":{}}," ++
    "{\"type\":\"tool_use\",\"name\":\"ApplyPatch\",\"input\":\"*** Begin Patch\\n*** End Patch\"}," ++
    "{\"type\":\"tool_use\",\"name\":\"rg\",\"input\":{}}]}}"
  match importCursorAgent source with
  | .ok transcript =>
      match transcript.entries[0]? with
      | some entry => match entry.payload with
        | .assistantMsg [
            .toolCall shell _ _, .toolCall replace _ _, .toolCall readFile _ _,
            .toolCall patch args _, .toolCall rg _ _] =>
              shell.raw == "Shell" && decide (shell.canonical = some .bash) &&
              replace.raw == "StrReplace" && decide (replace.canonical = some .edit) &&
              readFile.raw == "ReadFile" && decide (readFile.canonical = some .read) &&
              patch.raw == "ApplyPatch" && decide (patch.canonical = some .applyPatch) &&
              args == Json.str "*** Begin Patch\n*** End Patch" &&
              rg.raw == "rg" && decide (rg.canonical = some .grep) &&
              piToolName (some "ApplyPatch") == "applyPatch"
        | _ => false
      | _ => false
  | .error _ => false

example : cursorAgentCurrentToolVocabularyAndStringPatch = true := by native_decide

/-- A native-looking tool created outside a Cursor import has no raw target
record to authorize execution. Both the corpus-shaped `ApplyPatch` string and an
unsupported value therefore use the same inert carrier. -/
def cursorAgentForeignToolExportIsInert : Bool :=
  let patch := exportAssistantBlock (.toolCall
    { raw := "ApplyPatch", canonical := some .applyPatch }
    (Json.str "patch body") (some "foreign-ir-id"))
  let unsupported := exportAssistantBlock (.toolCall
    { raw := "Shell", canonical := some .bash }
    (Json.bool true) (some "foreign-bool-id"))
  match patch, unsupported with
  | some patchCarrier, some carrier =>
      ostr patchCarrier "type" == some "agent_convert_tool_call" &&
        ostr patchCarrier "rawName" == some "ApplyPatch" &&
        (patchCarrier.getObjVal? "args").toOption == some (Json.str "patch body") &&
        ostr patchCarrier "rawId" == some "foreign-ir-id" &&
        ostr carrier "type" == some "agent_convert_tool_call" &&
        ostr carrier "rawName" == some "Shell" &&
        (carrier.getObjVal? "args").toOption == some (Json.bool true) &&
        ostr carrier "rawId" == some "foreign-bool-id"
  | _, _ => false

example : cursorAgentForeignToolExportIsInert = true := by native_decide

private def cursorAgentHasToolIdSynthesisNote (transcript : Transcript) : Bool :=
  transcript.importNotes.any fun note =>
    match note.kind with
    | .idSynthesized => note.detail.contains "tool-call"
    | _ => false

private def cursorAgentRawIdentityFixture : String :=
  "{\"role\":\"assistant\",\"message\":{\"content\":[" ++
  "{\"type\":\"tool_use\",\"name\":\"Shell\",\"input\":{\"cmd\":\"pwd\"}}," ++
  "{\"type\":\"tool_use\",\"id\":null,\"name\":\"Task\",\"input\":{\"prompt\":\"x\"}}," ++
  "{\"type\":\"tool_use\",\"id\":\"dup\",\"name\":\"Read\",\"input\":{\"path\":\"a\"}}," ++
  "{\"type\":\"tool_use\",\"id\":\"dup\",\"name\":\"ApplyPatch\",\"input\":\"patch\"}]}}"

/-- Cross-target consumers observe this semantic IR, not private provenance.
The absent and null source ids therefore both remain `none`, while duplicate
explicit ids remain the same duplicate string at their original block positions. -/
private def cursorAgentRawIdentityShape (transcript : Transcript) : Bool :=
  transcript.entries.size == 1 && (Loom.violations transcript).isEmpty &&
    match transcript.entries[0]? with
    | some entry =>
        match entry.payload with
        | .assistantMsg [
            .toolCall shell shellArgs none,
            .toolCall task taskArgs none,
            .toolCall read readArgs (some "dup"),
            .toolCall patch (Json.str "patch") (some "dup")] =>
              shell.raw == "Shell" && decide (shell.canonical = some .bash) &&
              ostr shellArgs "cmd" == some "pwd" &&
              task.raw == "Task" && decide (task.canonical = some .agentSpawn) &&
              ostr taskArgs "prompt" == some "x" &&
              read.raw == "Read" && decide (read.canonical = some .read) &&
              ostr readArgs "path" == some "a" &&
              patch.raw == "ApplyPatch" && decide (patch.canonical = some .applyPatch)
        | _ => false
    | none => false

private def cursorAgentIdentityNoteCount (transcript : Transcript) (label : String) : Nat :=
  (transcript.importNotes.filter fun note =>
    match note.kind with | .other actual => actual == label | _ => false).length

/-- Native identity is copied rather than allocated. Missing/null and duplicate
conditions are still reported honestly, but no tool-call synthesis note or
`ca-tc` value enters the semantic projection consumed by foreign exporters. -/
def cursorAgentNativeToolCallIdentityIsLossless : Bool :=
  match importCursorAgent cursorAgentRawIdentityFixture with
  | .ok transcript =>
      let projection := continuationProjection transcript
      cursorAgentRawIdentityShape transcript &&
        cursorAgentIdentityNoteCount transcript "cursorAgentMissingToolCallId" == 2 &&
        cursorAgentIdentityNoteCount transcript "cursorAgentDuplicateToolCallId" == 1 &&
        !cursorAgentHasToolIdSynthesisNote transcript &&
        !projection.contains "ca-tc" &&
        (projection.splitOn "\"id\":null").length == 3 &&
        (projection.splitOn "\"id\":\"dup\"").length == 3
  | .error _ => false

example : cursorAgentNativeToolCallIdentityIsLossless = true := by native_decide

/-- Exact raw provenance authorizes only the matching semantic identity. In
particular, a retained no-id source block cannot authorize a later synthesized
or otherwise substituted id, and a duplicate-id block cannot authorize a
different occurrence identity. -/
def cursorAgentNativeToolCallIdentityCannotBeLaundered : Bool :=
  match importCursorAgent cursorAgentRawIdentityFixture with
  | .ok transcript =>
      match transcript.entries[0]? with
      | some entry =>
          match entry.payload with
          | .assistantMsg [
              .toolCall shell shellArgs none, _,
              .toolCall read readArgs (some "dup"), _] =>
                (cursorAgentExactImportedToolBlock? entry 0 shell shellArgs none).isSome &&
                (cursorAgentExactImportedToolBlock? entry 0 shell shellArgs
                  (some "ca-tc0001")).isNone &&
                (cursorAgentExactImportedToolBlock? entry 2 read readArgs
                  (some "dup")).isSome &&
                (cursorAgentExactImportedToolBlock? entry 2 read readArgs
                  (some "ca-tc0002")).isNone
          | _ => false
      | none => false
  | .error _ => false

example : cursorAgentNativeToolCallIdentityCannotBeLaundered = true := by native_decide

/-- Same-format archival export preserves distinct absent-vs-null raw shapes and
duplicate ids without granting duplicate runtime authority. Checked export
conservatively refuses the honest duplicate-id source, and the inert carrier is
stable across a second import without synthesizing identity. -/
def cursorAgentNativeToolCallIdentityRoundTripsExactly : Bool :=
  match Json.parse cursorAgentRawIdentityFixture,
      importCursorAgent cursorAgentRawIdentityFixture with
  | .ok raw, .ok transcript =>
      let archived := exportCursorAgent transcript
      cursorAgentCheckedRefuses transcript cursorAgentReplayedToolSourcePreflightError &&
        !cursorAgentTargetNativeJsonl archived &&
        !archived.contains "ca-tc" &&
        (match (archived.splitOn "\n").filter (fun line => !line.isEmpty) with
         | [line] => match Json.parse line with
             | .ok carrier =>
                 (cursorAgentHistoricalEntryPayload? carrier).isSome &&
                   (oobj carrier cursorAgentHistoricalSourceRawRecordKey).map
                     Json.compress == some raw.compress
             | .error _ => false
         | _ => false) &&
        match importCursorAgent archived with
        | .ok restored =>
            cursorAgentRawIdentityShape restored &&
              restored.entries.all (fun entry =>
                entry.disposition == EntryDisposition.historicalUnverified) &&
              cursorAgentPayloads restored == cursorAgentPayloads transcript &&
              !cursorAgentHasToolIdSynthesisNote restored &&
              exportCursorAgent restored == archived
        | .error _ => false
  | _, _ => false

example : cursorAgentNativeToolCallIdentityRoundTripsExactly = true := by native_decide

/-- Exact non-replayed imported native messages remain eligible for runtime
export, including ordinary text and an anonymous tool call. Duplicate explicit
authority is covered by the conservative refusal/archive pin above. -/
def cursorAgentExactNativeRecordsRemainRuntimeEligible : Bool :=
  let eligible := fun (transcript : Transcript) =>
    !transcript.entries.any cursorAgentEntryNeedsHistoricalCarrier &&
      cursorAgentTargetExportReady transcript &&
      match exportCursorAgentTargetChecked transcript with
      | .ok output =>
          cursorAgentTargetNativeJsonl output && output == exportCursorAgent transcript
      | .error _ => false
  match importCursorAgent cursorAgentParityFixture with
  | .ok messages => eligible messages
  | .error _ => false

example : cursorAgentExactNativeRecordsRemainRuntimeEligible = true := by
  native_decide

/-- The corpus-specific string-input `ApplyPatch` spelling remains native when
its source id is null. The name and arguments stay exact, semantic identity is
`none`, and same-format export preserves the raw null rather than minting an id. -/
def cursorAgentApplyPatchNullIdRemainsAnonymous : Bool :=
  let source :=
    "{\"role\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":null,\"name\":\"ApplyPatch\",\"input\":\"*** Begin Patch\\n*** End Patch\"}]}}"
  match Json.parse source, importCursorAgent source with
  | .ok raw, .ok transcript =>
      match transcript.entries[0]? with
      | some entry =>
          match entry.payload with
          | .assistantMsg [.toolCall name (Json.str patch) none] =>
              name.raw == "ApplyPatch" &&
                decide (name.canonical = some .applyPatch) &&
                patch == "*** Begin Patch\n*** End Patch" &&
                !cursorAgentHasToolIdSynthesisNote transcript &&
                match Json.parse (exportCursorAgent transcript) with
                | .ok exported => exported.compress == raw.compress
                | .error _ => false
          | _ => false
      | none => false
  | _, _ => false

example : cursorAgentApplyPatchNullIdRemainsAnonymous = true := by native_decide

/-- Native `id` is nullable string data only. Empty strings and every non-string,
non-null shape fail closed instead of being dropped, coerced, or replaced. -/
def cursorAgentMalformedToolIdsRejected : Bool :=
  [
    "{\"role\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{},\"id\":\"\"}]}}",
    "{\"role\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{},\"id\":7}]}}",
    "{\"role\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{},\"id\":false}]}}",
    "{\"role\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{},\"id\":{}}]}}",
    "{\"role\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{},\"id\":[]}]}}"
  ].all cursorAgentRejects

example : cursorAgentMalformedToolIdsRejected = true := by native_decide

/-- The file-aware API recovers only path-encoded identity and retains the
exact source path; it does not fabricate cwd. -/
def cursorAgentPathIdentityIsRecovered : Bool :=
  let path : System.FilePath :=
    "/Users/dev/.cursor/projects/project/agent-transcripts/session-123/session-123.jsonl"
  match importCursorAgentAtPath path cursorAgentFixture with
  | .ok transcript =>
      transcript.env.sessionId == some "session-123" && transcript.env.cwd.isNone &&
        transcript.origin.rawId == some "session-123" &&
        transcript.origin.sourceRef == path.toString &&
        transcript.origin.extras.bind (fun extras => ostr extras "sourcePath") == some path.toString
  | .error _ => false

example : cursorAgentPathIdentityIsRecovered = true := by native_decide

/-- A child directly beneath the native session's `subagents` directory carries
its own path-encoded identity. -/
def cursorAgentChildPathIdentityIsRecovered : Bool :=
  cursorAgentSessionIdFromPath
    ("/Users/dev/.cursor/projects/project/agent-transcripts/session-123/subagents/child-7.jsonl" :
      System.FilePath) == some "child-7"

example : cursorAgentChildPathIdentityIsRecovered = true := by native_decide

/-- Arbitrary outputs and structural lookalikes do not supply identity. This
pins the full ancestry, root-name equality, and direct-child requirements. -/
def cursorAgentPathIdentityRecognitionIsConservative : Bool :=
  cursorAgentSessionIdFromPath
      ("/tmp/arbitrary.jsonl" : System.FilePath) == none &&
    cursorAgentSessionIdFromPath
      ("/tmp/agent-transcripts/session/session.jsonl" : System.FilePath) == none &&
    cursorAgentSessionIdFromPath
      ("/Users/dev/.cursor/projects/project/agent-transcripts/session/export.jsonl" :
        System.FilePath) == none &&
    cursorAgentSessionIdFromPath
      ("/Users/dev/.cursor/projects/project/output/session/session.jsonl" :
        System.FilePath) == none &&
    cursorAgentSessionIdFromPath
      ("/Users/dev/.cursor/projects/project/agent-transcripts/session/subagents/nested/child.jsonl" :
        System.FilePath) == none &&
    cursorAgentSessionIdFromPath
      ("/Users/dev/.cursor/projects/project/agent-transcripts/session/session.json" :
        System.FilePath) == none

example : cursorAgentPathIdentityRecognitionIsConservative = true := by native_decide

/-- Same-format export overlays modeled fields onto the exact source record.
Top-level, message-level, and block-level additive fields survive, an explicit
additive id survives, and the adjacent source-native no-id call stays no-id. -/
def cursorAgentAdditiveAndIdRoundTripExact : Bool :=
  let source :=
    "{\"topFuture\":{\"n\":1},\"role\":\"assistant\",\"message\":{" ++
    "\"messageFuture\":true,\"content\":[" ++
    "{\"type\":\"text\",\"text\":\"hello\",\"blockFuture\":1}," ++
    "{\"type\":\"tool_use\",\"name\":\"Shell\",\"input\":{\"cmd\":\"pwd\"},\"toolFuture\":2}," ++
    "{\"type\":\"tool_use\",\"id\":\"source-id\",\"name\":\"ApplyPatch\",\"input\":\"patch\",\"toolFuture\":3}]}}"
  match Json.parse source, importCursorAgent source with
  | .ok raw, .ok transcript =>
      let exported := exportCursorAgent transcript
      match Json.parse exported with
      | .ok restored =>
          restored.compress == raw.compress &&
            exported.contains "\"id\":\"source-id\"" &&
            !exported.contains "ca-tc0001"
      | .error _ => false
  | _, _ => false

example : cursorAgentAdditiveAndIdRoundTripExact = true := by native_decide

private def cursorAgentHistoricalRawIdentityFixture : String :=
  let additive := Json.mkObj [
    ("role", Json.str "assistant"),
    ("message", Json.mkObj [
      ("content", Json.arr #[
        Json.mkObj [
          ("type", Json.str "agent_convert_tool_call"),
          ("rawName", Json.str "Task"),
          ("args", Json.mkObj [])],
        Json.mkObj [
          ("type", Json.str "agent_convert_tool_call"),
          ("rawName", Json.str "Bash"),
          ("args", Json.mkObj []),
          ("rawId", Json.null)],
        Json.mkObj [
          ("type", Json.str "agent_convert_tool_call"),
          ("rawName", Json.str "Read"),
          ("args", Json.mkObj []),
          ("rawId", Json.str "")],
        Json.mkObj [
          ("type", Json.str "agent_convert_tool_call"),
          ("rawName", Json.str "ApplyPatch"),
          ("args", Json.str "patch"),
          ("rawId", Json.str "duplicate-history")],
        Json.mkObj [
          ("type", Json.str "agent_convert_tool_call"),
          ("rawName", Json.str "Shell"),
          ("args", Json.mkObj []),
          ("rawId", Json.str "duplicate-history")]])])]
  let historicalBlock := fun (name : String) (rawId : List (String × Json)) =>
    Json.mkObj ([
      ("kind", Json.str "toolCall"),
      ("name", Json.str name),
      ("canonical", Json.null),
      ("arguments", Json.mkObj [])] ++ rawId)
  let wholeEntry := Json.mkObj [
    ("type", Json.str cursorAgentHistoricalRecordType),
    ("protocol", Json.str cursorAgentHistoricalProtocol),
    ("payload", Json.mkObj [
      ("kind", Json.str "assistantMsg"),
      ("blocks", Json.arr #[
        historicalBlock "Task" [],
        historicalBlock "Bash" [("rawId", Json.null)],
        historicalBlock "Read" [("rawId", Json.str "")],
        historicalBlock "ApplyPatch" [("rawId", Json.str "duplicate-history")],
        historicalBlock "Shell" [("rawId", Json.str "duplicate-history")]])])]
  String.intercalate "\n" [additive.compress, wholeEntry.compress]

private def cursorAgentToolCallRawIds (transcript : Transcript) : List (Option String) :=
  transcript.entries.toList.flatMap (fun entry =>
    match entry.payload with
    | .assistantMsg blocks => blocks.filterMap (fun
        | .toolCall _ _ rawId => some rawId
        | _ => none)
    | _ => [])

private def cursorAgentHistoricalCarrierRawIdShapes
    (text : String) : Option (List CursorHistoricalRawId) := do
  let records ← (text.splitOn "\n").filter (fun line => !line.isEmpty) |>.mapM
    (fun line => (Json.parse line).toOption)
  let blockGroups ← records.mapM (fun record => do
    guard (ostr record "type" == some cursorAgentHistoricalRecordType)
    guard (ostr record "protocol" == some cursorAgentHistoricalProtocol)
    let payload ← oobj record "payload"
    guard (ostr payload "kind" == some "assistantMsg")
    oarr payload "blocks")
  blockGroups.flatMap Array.toList |>.mapM (fun block => do
    guard (ostr block "kind" == some "toolCall")
    cursorHistoricalRawId? block "rawId")

/-- Historical carrier identity is data, not a uniqueness key. The semantic IR
maps both missing and null to `none`, while exact carrier provenance keeps those
source spellings distinct. Empty and duplicate strings remain at their original
positions across both historical encodings and two archive hops; checked runtime
export refuses every resulting carrier. -/
def cursorAgentHistoricalToolCallIdentityIsExactAndArchiveOnly : Bool :=
  let expected : List (Option String) := [
    none, none, some "", some "duplicate-history", some "duplicate-history",
    none, none, some "", some "duplicate-history", some "duplicate-history"]
  let expectedShapes : List CursorHistoricalRawId := [
    .missing, .explicitNull, .string "", .string "duplicate-history",
    .string "duplicate-history", .missing, .explicitNull, .string "",
    .string "duplicate-history", .string "duplicate-history"]
  match importCursorAgent cursorAgentHistoricalRawIdentityFixture with
  | .error _ => false
  | .ok imported =>
      imported.entries.toList.all (fun entry =>
        entry.disposition == EntryDisposition.historicalUnverified) &&
      cursorAgentToolCallRawIds imported == expected &&
      cursorAgentIdentityNoteCount imported
        "cursorAgentHistoricalMissingToolCallId" == 2 &&
      cursorAgentIdentityNoteCount imported
        "cursorAgentHistoricalDuplicateToolCallId" == 1 &&
      !cursorAgentHasToolIdSynthesisNote imported &&
      let archived := exportCursorAgent imported
      !archived.contains "ca-tc" &&
      !cursorAgentTargetNativeJsonl archived &&
      decide (cursorAgentHistoricalCarrierRawIdShapes archived == some expectedShapes) &&
      cursorAgentCheckedRefuses imported cursorAgentHistoricalTargetPreflightError &&
      match importCursorAgent archived with
      | .ok restored =>
          cursorAgentToolCallRawIds restored == expected &&
          restored.entries.toList.all (fun entry =>
            entry.disposition == EntryDisposition.historicalUnverified) &&
          cursorAgentCheckedRefuses restored cursorAgentHistoricalTargetPreflightError &&
          let archivedAgain := exportCursorAgent restored
          archivedAgain == archived && !archivedAgain.contains "ca-tc" &&
            decide (cursorAgentHistoricalCarrierRawIdShapes archivedAgain ==
              some expectedShapes)
      | .error _ => false

example : cursorAgentHistoricalToolCallIdentityIsExactAndArchiveOnly = true := by
  native_decide

private def cursorAgentHistoricalAdditiveToolIdFixture (rawId : Json) : String :=
  (Json.mkObj [
    ("role", Json.str "assistant"),
    ("message", Json.mkObj [
      ("content", Json.arr #[Json.mkObj [
        ("type", Json.str "agent_convert_tool_call"),
        ("rawName", Json.str "Shell"),
        ("args", Json.mkObj []),
        ("rawId", rawId)]])])]).compress

private def cursorAgentHistoricalCarrierToolIdFixture (rawId : Json) : String :=
  (Json.mkObj [
    ("type", Json.str cursorAgentHistoricalRecordType),
    ("protocol", Json.str cursorAgentHistoricalProtocol),
    ("payload", Json.mkObj [
      ("kind", Json.str "assistantMsg"),
      ("blocks", Json.arr #[Json.mkObj [
        ("kind", Json.str "toolCall"),
        ("name", Json.str "Shell"),
        ("canonical", Json.null),
        ("arguments", Json.mkObj []),
        ("rawId", rawId)]])])]).compress

/-- Historical ids are nullable strings only. Both the additive legacy carrier
and the whole-entry archival carrier reject every other JSON shape. -/
def cursorAgentMalformedHistoricalToolIdsRejected : Bool :=
  [Json.num 7, Json.bool false, Json.mkObj [], Json.arr #[]].all (fun rawId =>
    cursorAgentRejects (cursorAgentHistoricalAdditiveToolIdFixture rawId) &&
      cursorAgentRejects (cursorAgentHistoricalCarrierToolIdFixture rawId))

example : cursorAgentMalformedHistoricalToolIdsRejected = true := by native_decide

private def cursorAgentHistoricalToolFixture : String :=
  (Json.mkObj [
    ("role", Json.str "assistant"),
    ("message", Json.mkObj [
      ("content", Json.arr #[
        Json.mkObj [
          ("type", Json.str "agent_convert_tool_call"),
          ("rawName", Json.str "Shell"),
          ("args", Json.bool true),
          ("rawId", Json.str "historical-call")],
        Json.mkObj [
          ("type", Json.str "text"),
          ("text", Json.str "native-looking sibling")],
        Json.mkObj [
          ("type", Json.str "tool_use"),
          ("name", Json.str "Bash"),
          ("input", Json.mkObj [])]])])]).compress

private def cursorAgentStripCarrierMetadata (transcript : Transcript) : Transcript :=
  { transcript with
    entries := transcript.entries.map (fun entry => {
      entry with origin := { entry.origin with sourceRef := "", extras := none } })
    origin := { transcript.origin with sourceRef := "", extras := none } }

/-- The additive tool carrier decodes to typed historical data. Removing every
private origin hint cannot make that call, or a native-looking sibling, emit as
an executable Cursor `tool_use`; the universal inert record is E-I-E stable. -/
def cursorAgentHistoricalDispositionSurvivesMetadataStripping : Bool :=
  match importCursorAgent cursorAgentHistoricalToolFixture with
  | .error _ => false
  | .ok imported =>
      (match imported.entries[0]? with
       | some entry =>
           entry.disposition == EntryDisposition.historicalUnverified &&
           match entry.payload with
           | .assistantMsg [
               .toolCall historicalName (Json.bool true) (some "historical-call"),
               .text "native-looking sibling",
               .toolCall nativeName (.obj _) none] =>
                 historicalName.raw == "Shell" && nativeName.raw == "Bash"
           | _ => false
       | none => false) &&
      let stripped := cursorAgentStripCarrierMetadata imported
      let first := exportCursorAgent stripped
      first.contains cursorAgentHistoricalProtocol &&
      !first.contains "\"type\":\"tool_use\"" &&
      !first.contains "\"role\":\"assistant\"" &&
      match importCursorAgent first with
      | .error _ => false
      | .ok restored =>
          restored.entries.toList.all (fun entry =>
            entry.disposition == EntryDisposition.historicalUnverified) &&
          exportCursorAgent restored == first

example : cursorAgentHistoricalDispositionSurvivesMetadataStripping = true := by
  native_decide

private def cursorAgentNativeLookingRawEvent : Json := Json.mkObj [
  ("role", Json.str "assistant"),
  ("message", Json.mkObj [
    ("content", Json.arr #[
      Json.mkObj [
        ("type", Json.str "text"),
        ("text", Json.str "must remain an inert event")],
      Json.mkObj [
        ("type", Json.str "tool_use"),
        ("name", Json.str "Shell"),
        ("input", Json.mkObj [("cmd", Json.str "must-not-run")])]])])]

private def cursorAgentUnsupportedArchiveAdversary : Transcript :=
  let source : Origin := { format := .pi, sourceRef := "unsupported-adversary" }
  { threads := #[{ kind := .main }],
    entries := #[
      { payload := .userMsg [
          .media "image/png" "user-media",
          .unmodeled "foreign-user-text" (Json.mkObj [
            ("type", Json.str "text"),
            ("text", Json.str "must remain unmodeled")])],
        origin := source },
      { parent := some 0,
        payload := .assistantMsg [
          .thinking "private reasoning" (some "signature"),
          .media "image/png" "assistant-media",
          .unmodeled "foreign-assistant-tool" (Json.mkObj [
            ("type", Json.str "tool_use"),
            ("name", Json.str "Shell"),
            ("input", Json.mkObj [("cmd", Json.str "must-not-run")])])],
        origin := source },
      { parent := some 1,
        payload := .envMsg [.unmodeled "foreign-env" cursorAgentNativeLookingRawEvent],
        origin := source },
      { parent := some 2,
        payload := .otherMsg "system" [.text "system-only history"],
        origin := source },
      { parent := some 3,
        payload := .compaction "archived summary" (.knownPrefix 1) (some 42),
        origin := source },
      { parent := some 4,
        payload := .event (.custom "cursor_agent.native_shaped" cursorAgentNativeLookingRawEvent),
        origin := source }],
    activeLeaf := some 5,
    origin := source }

private def cursorAgentArchiveOnlyJsonl (output : String) (expected : Nat) : Bool :=
  let lines := (output.splitOn "\n").filter (fun line => !line.isEmpty)
  lines.length == expected && lines.all (fun line =>
    match Json.parse line with
    | .ok record =>
        ostr record "type" == some cursorAgentHistoricalRecordType &&
          ostr record "protocol" == some cursorAgentHistoricalProtocol &&
          (cursorAgentHistoricalEntryPayload? record).isSome
    | .error _ => false)

private def cursorAgentUnsupportedArchiveShape (transcript : Transcript) : Bool :=
  transcript.entries.size == cursorAgentUnsupportedArchiveAdversary.entries.size &&
    transcript.activeLeaf == cursorAgentUnsupportedArchiveAdversary.activeLeaf &&
    cursorAgentPayloads transcript == cursorAgentPayloads cursorAgentUnsupportedArchiveAdversary &&
    transcript.entries.all (fun entry =>
      entry.disposition == EntryDisposition.historicalUnverified)

/-- Thinking, media, unmodeled content, non-message payloads, and a custom
`cursor_agent.*` event containing a complete native-looking assistant record all
remain whole and inert. Checked runtime export refuses after each of two archive
hops, and no top-level archive record ever has native Cursor message syntax. -/
def cursorAgentUnsupportedEntriesStayInertTwoArchiveHops : Bool :=
  cursorAgentCheckedRefuses cursorAgentUnsupportedArchiveAdversary
      cursorAgentNativePayloadPreflightError &&
    let first := exportCursorAgent cursorAgentUnsupportedArchiveAdversary
    cursorAgentArchiveOnlyJsonl first
      cursorAgentUnsupportedArchiveAdversary.entries.size &&
    !cursorAgentTargetNativeJsonl first &&
    match importCursorAgent first with
    | .error _ => false
    | .ok firstImport =>
        cursorAgentUnsupportedArchiveShape firstImport &&
        cursorAgentCheckedRefuses firstImport cursorAgentHistoricalTargetPreflightError &&
        let second := exportCursorAgent firstImport
        second == first &&
        cursorAgentArchiveOnlyJsonl second firstImport.entries.size &&
        !cursorAgentTargetNativeJsonl second &&
        match importCursorAgent second with
        | .error _ => false
        | .ok secondImport =>
            cursorAgentUnsupportedArchiveShape secondImport &&
              cursorAgentCheckedRefuses secondImport
                cursorAgentHistoricalTargetPreflightError &&
              exportCursorAgent secondImport == second

example : cursorAgentUnsupportedEntriesStayInertTwoArchiveHops = true := by
  native_decide

private def cursorAgentSingleArchivedRecord? (output : String) : Option Json :=
  match (output.splitOn "\n").filter (fun line => !line.isEmpty) with
  | [line] => (Json.parse line).toOption
  | _ => none

private def cursorAgentSingleArchivedSourceRawRecord? (output : String) : Option Json := do
  let record ← cursorAgentSingleArchivedRecord? output
  guard ((cursorAgentHistoricalEntryPayload? record).isSome)
  oobj record cursorAgentHistoricalSourceRawRecordKey

/-- A retained raw name authorizes only its exact canonical interpretation.
Changing `Bash` from `.bash` to `.webSearch` forces a whole-entry carrier; the
mutated typed value survives archive import and checked runtime export refuses. -/
def cursorAgentCanonicalMutationIsArchiveOnly : Bool :=
  let source :=
    "{\"role\":\"assistant\",\"message\":{\"content\":[{" ++
    "\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{\"cmd\":\"pwd\"}}]}}"
  match importCursorAgent source with
  | .error _ => false
  | .ok imported =>
      match imported.entries[0]? with
      | some entry =>
          match entry.payload with
          | .assistantMsg [.toolCall name args rawId] =>
              let mutatedName : ToolName := {
                raw := name.raw, canonical := some .webSearch }
              let mutatedEntry : Entry := { entry with
                payload := .assistantMsg [.toolCall mutatedName args rawId] }
              let mutated : Transcript := { imported with entries := #[mutatedEntry] }
              (cursorAgentExactImportedToolBlock? mutatedEntry 0 mutatedName args rawId).isNone &&
                cursorAgentEntryNeedsHistoricalCarrier mutatedEntry &&
                cursorAgentCheckedRefuses mutated cursorAgentNativePayloadPreflightError &&
                let archived := exportCursorAgent mutated
                cursorAgentArchiveOnlyJsonl archived 1 &&
                match importCursorAgent archived with
                | .error _ => false
                | .ok restored =>
                    cursorAgentCheckedRefuses restored cursorAgentHistoricalTargetPreflightError &&
                      (match restored.entries[0]? with
                       | some restoredEntry => match restoredEntry.payload with
                           | .assistantMsg [.toolCall restoredName _ _] =>
                               restoredName.raw == "Bash" &&
                                 decide (restoredName.canonical = some .webSearch)
                           | _ => false
                       | none => false) &&
                      exportCursorAgent restored == archived
          | _ => false
      | none => false

example : cursorAgentCanonicalMutationIsArchiveOnly = true := by native_decide

/-- Raw block agreement is insufficient when the containing source record was
an inert system event. Even after semantic mutation to an assistant tool call,
the record remains archival and its nested source provenance grants no native
authority. -/
def cursorAgentSystemEventMutationCannotAuthorizeNativeTool : Bool :=
  let source :=
    "{\"role\":\"system\",\"message\":{\"content\":[{" ++
    "\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{}}]}}"
  match importCursorAgent source with
  | .error _ => false
  | .ok imported =>
      match imported.entries[0]? with
      | none => false
      | some eventEntry =>
          let name : ToolName := { raw := "Bash", canonical := some .bash }
          let mutatedEntry : Entry := { eventEntry with
            payload := .assistantMsg [.toolCall name (Json.mkObj []) none] }
          let mutated : Transcript := { imported with entries := #[mutatedEntry] }
          (cursorAgentExactImportedToolBlock? mutatedEntry 0 name (Json.mkObj []) none).isNone &&
            cursorAgentCheckedRefuses mutated cursorAgentNativePayloadPreflightError &&
            let archived := exportCursorAgent mutated
            cursorAgentArchiveOnlyJsonl archived 1 &&
            (cursorAgentSingleArchivedSourceRawRecord? archived).bind
                (fun raw => ostr raw "role") == some "system" &&
            match importCursorAgent archived with
            | .error _ => false
            | .ok restored =>
                cursorAgentCheckedRefuses restored cursorAgentHistoricalTargetPreflightError &&
                  match restored.entries[0]? with
                  | some restoredEntry =>
                      let declassified : Entry := {
                        restoredEntry with disposition := .native }
                      (cursorAgentExactImportedToolBlock? declassified 0 name
                        (Json.mkObj []) none).isNone
                  | none => false

example : cursorAgentSystemEventMutationCannotAuthorizeNativeTool = true := by
  native_decide

/-- Mutating an inert imported record to typed assistant text cannot override its
raw classification. The current typed mutation is archived, the exact inert raw
record remains provenance, and the carrier reaches a fixed point after import. -/
private def cursorAgentInertToTextMutationArchiveStable
    (source mutation : String) : Bool :=
  match Json.parse source, importCursorAgent source with
  | .ok sourceRaw, .ok imported =>
      match imported.entries[0]? with
      | none => false
      | some inertEntry =>
          match inertEntry.payload with
          | .event _ =>
              let mutatedEntry : Entry := { inertEntry with
                payload := .assistantMsg [.text mutation] }
              let mutated : Transcript := { imported with entries := #[mutatedEntry] }
              !cursorAgentRawRecordAuthorizesRole mutatedEntry "assistant" &&
                cursorAgentEntryNeedsHistoricalCarrier mutatedEntry &&
                cursorAgentCheckedRefuses mutated cursorAgentNativePayloadPreflightError &&
                let archived := exportCursorAgent mutated
                cursorAgentArchiveOnlyJsonl archived 1 &&
                !cursorAgentTargetNativeJsonl archived &&
                (cursorAgentSingleArchivedSourceRawRecord? archived).map Json.compress ==
                  some sourceRaw.compress &&
                match importCursorAgent archived with
                | .error _ => false
                | .ok restored =>
                    cursorAgentCheckedRefuses restored
                        cursorAgentHistoricalTargetPreflightError &&
                      (match restored.entries[0]? with
                       | some restoredEntry =>
                           restoredEntry.disposition ==
                               EntryDisposition.historicalUnverified &&
                             match restoredEntry.payload with
                             | .assistantMsg [.text restoredText] =>
                                 restoredText == mutation
                             | _ => false
                       | none => false) &&
                      exportCursorAgent restored == archived
          | _ => false
  | _, _ => false

def cursorAgentSystemToTextMutationArchiveStable : Bool :=
  cursorAgentInertToTextMutationArchiveStable
    "{\"role\":\"system\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"system source\"}]}}"
    "typed system mutation"

example : cursorAgentSystemToTextMutationArchiveStable = true := by native_decide

def cursorAgentUnknownToTextMutationArchiveStable : Bool :=
  cursorAgentInertToTextMutationArchiveStable
    "{\"futureRecord\":{\"v\":1},\"note\":\"unknown source\"}"
    "typed unknown mutation"

example : cursorAgentUnknownToTextMutationArchiveStable = true := by native_decide

def cursorAgentTurnEndedToTextMutationArchiveStable : Bool :=
  cursorAgentInertToTextMutationArchiveStable
    "{\"type\":\"turn_ended\",\"status\":\"completed\",\"future\":true}"
    "typed turn_ended mutation"

example : cursorAgentTurnEndedToTextMutationArchiveStable = true := by
  native_decide

/-- Stripping retained provenance after mutating an imported inert event to text
cannot turn a Cursor-origin entry into native dialogue. The current typed value
is retained in an inert carrier, but the stripped source record is not invented. -/
private def cursorAgentStrippedInertToTextFailsClosed
    (source mutation : String) : Bool :=
  match importCursorAgent source with
  | .error _ => false
  | .ok imported =>
      match imported.entries[0]? with
      | none => false
      | some inertEntry =>
          match inertEntry.payload with
          | .event _ =>
              let strippedEntry : Entry := { inertEntry with
                payload := .assistantMsg [.text mutation]
                origin := { inertEntry.origin with extras := none } }
              let stripped : Transcript := { imported with entries := #[strippedEntry] }
              strippedEntry.origin.format == Format.cursorAgent &&
                (cursorAgentRawRecord strippedEntry).isNone &&
                !cursorAgentRawRecordAuthorizesRole strippedEntry "assistant" &&
                cursorAgentEntryNeedsHistoricalCarrier strippedEntry &&
                cursorAgentCheckedRefuses stripped
                  cursorAgentNativePayloadPreflightError &&
                let archived := exportCursorAgent stripped
                cursorAgentArchiveOnlyJsonl archived 1 &&
                  (cursorAgentSingleArchivedSourceRawRecord? archived).isNone &&
                  match importCursorAgent archived with
                  | .error _ => false
                  | .ok restored =>
                      cursorAgentCheckedRefuses restored
                          cursorAgentHistoricalTargetPreflightError &&
                        (match restored.entries[0]? with
                         | some restoredEntry =>
                             restoredEntry.disposition ==
                                 EntryDisposition.historicalUnverified &&
                               match restoredEntry.payload with
                               | .assistantMsg [.text restoredText] =>
                                   restoredText == mutation
                               | _ => false
                         | none => false) &&
                        exportCursorAgent restored == archived
          | _ => false

def cursorAgentStrippedSystemRawRecordCannotAuthorizeText : Bool :=
  cursorAgentStrippedInertToTextFailsClosed
    "{\"role\":\"system\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"system source\"}]}}"
    "stripped system mutation"

example : cursorAgentStrippedSystemRawRecordCannotAuthorizeText = true := by
  native_decide

def cursorAgentStrippedUnknownRawRecordCannotAuthorizeText : Bool :=
  cursorAgentStrippedInertToTextFailsClosed
    "{\"futureRecord\":{\"v\":1},\"note\":\"unknown source\"}"
    "stripped unknown mutation"

example : cursorAgentStrippedUnknownRawRecordCannotAuthorizeText = true := by
  native_decide

def cursorAgentStrippedTurnEndedRawRecordCannotAuthorizeText : Bool :=
  cursorAgentStrippedInertToTextFailsClosed
    "{\"type\":\"turn_ended\",\"status\":\"completed\",\"future\":true}"
    "stripped turn_ended mutation"

example : cursorAgentStrippedTurnEndedRawRecordCannotAuthorizeText = true := by
  native_decide

/-- Raw Cursor provenance is format-scoped. A foreign modeled text entry with no
Cursor raw record continues to be judged by its payload and remains exportable. -/
def cursorAgentForeignModeledTextWithoutRawRecordRemainsEligible : Bool :=
  let source : Origin := { format := .pi, sourceRef := "foreign-text" }
  let entry : Entry := {
    payload := Payload.assistantMsg [AssistantBlock.text "modeled text"]
    origin := source }
  let transcript : Transcript := {
    threads := #[{ kind := .main }], entries := #[entry], activeLeaf := some 0,
    origin := source }
  cursorAgentRawRecordAuthorizesRole entry "assistant" &&
    !cursorAgentEntryNeedsHistoricalCarrier entry &&
    match exportCursorAgentTargetChecked transcript with
    | .ok output => cursorAgentTargetNativeJsonl output
    | .error _ => false

example : cursorAgentForeignModeledTextWithoutRawRecordRemainsEligible = true := by
  native_decide

private def cursorAgentNativeThenHistoricalReplayShape (output : String) : Bool :=
  match (output.splitOn "\n").filter (fun line => !line.isEmpty) with
  | [nativeLine, replayLine] =>
      match Json.parse nativeLine, Json.parse replayLine with
      | .ok nativeRecord, .ok replayRecord =>
          cursorAgentTargetNativeRecord nativeRecord &&
            (cursorAgentHistoricalEntryPayload? replayRecord).isSome
      | _, _ => false
  | _ => false

/-- Copying a valid imported entry and changing its mutable source locator does
not create authority. The explicit source id remains the key, so checked export
rejects the replay and archival export carries the later copy inertly. -/
def cursorAgentClonedToolSourceCannotReplayNative : Bool :=
  let source :=
    "{\"role\":\"assistant\",\"message\":{\"content\":[{" ++
    "\"type\":\"tool_use\",\"id\":\"source-call\",\"name\":\"Bash\"," ++
    "\"input\":{\"cmd\":\"pwd\"}}]}}"
  match importCursorAgent source with
  | .error _ => false
  | .ok imported =>
      match imported.entries[0]? with
      | none => false
      | some entry =>
          let replayEntry : Entry := { entry with
            parent := some 0
            origin := { entry.origin with sourceRef := "attacker-relocated" } }
          let replay : Transcript := { imported with
            entries := #[entry, replayEntry], activeLeaf := some 1 }
          (Loom.violations replay).isEmpty &&
            entry.origin.sourceRef != replayEntry.origin.sourceRef &&
            cursorAgentEntryToolAuthorityKeys entry ==
              cursorAgentEntryToolAuthorityKeys replayEntry &&
            !cursorAgentTargetToolAuthoritiesUnique replay &&
            cursorAgentCheckedRefuses replay
              cursorAgentReplayedToolSourcePreflightError &&
            let archived := exportCursorAgent replay
            cursorAgentNativeThenHistoricalReplayShape archived &&
            match importCursorAgent archived with
            | .error _ => false
            | .ok restored =>
                cursorAgentPayloads restored == cursorAgentPayloads replay &&
                  (match restored.entries[0]?, restored.entries[1]? with
                   | some first, some second =>
                       first.disposition == EntryDisposition.native &&
                         second.disposition ==
                           EntryDisposition.historicalUnverified
                   | _, _ => false) &&
                  exportCursorAgent restored == archived

example : cursorAgentClonedToolSourceCannotReplayNative = true := by
  native_decide

/-- An anonymous source call keeps the same authority when a clone moves it to a
different block position and edits only surrounding raw provenance. This pins
the exact source block fallback independently of `sourceRef` and `blockIdx`. -/
def cursorAgentMovedAnonymousToolCloneCannotReplayNative : Bool :=
  let sourceTool := Json.mkObj [
    ("type", Json.str "tool_use"),
    ("name", Json.str "Bash"),
    ("input", Json.mkObj [("cmd", Json.str "pwd")])]
  let source := (Json.mkObj [
    ("role", Json.str "assistant"),
    ("message", Json.mkObj [("content", Json.arr #[sourceTool])])]).compress
  match importCursorAgent source with
  | .error _ => false
  | .ok imported =>
      match imported.entries[0]? with
      | none => false
      | some entry =>
          match entry.payload with
          | .assistantMsg [.toolCall name args none] =>
              let movedRaw := Json.mkObj [
                ("editedTop", Json.str "clone provenance"),
                ("role", Json.str "assistant"),
                ("message", Json.mkObj [
                  ("editedMessage", Json.bool true),
                  ("content", Json.arr #[
                    Json.mkObj [
                      ("type", Json.str "text"),
                      ("text", Json.str "surrounding clone text"),
                      ("editedBlock", Json.num 1)],
                    sourceTool])])]
              let movedEntry : Entry := { entry with
                parent := some 0
                payload := .assistantMsg [
                  .text "surrounding clone text", .toolCall name args none]
                origin := { entry.origin with extras := some (Json.mkObj [
                  ("rawRecord", movedRaw)]) } }
              let replay : Transcript := { imported with
                entries := #[entry, movedEntry], activeLeaf := some 1 }
              (cursorAgentExactImportedToolBlock? movedEntry 1 name args none).isSome &&
                !cursorAgentEntryNeedsHistoricalCarrier movedEntry &&
                cursorAgentEntryToolAuthorityKeys entry ==
                  cursorAgentEntryToolAuthorityKeys movedEntry &&
                !cursorAgentTargetToolAuthoritiesUnique replay &&
                cursorAgentCheckedRefuses replay
                  cursorAgentReplayedToolSourcePreflightError &&
                let archived := exportCursorAgent replay
                cursorAgentNativeThenHistoricalReplayShape archived &&
                  match importCursorAgent archived with
                  | .error _ => false
                  | .ok restored =>
                      cursorAgentPayloads restored == cursorAgentPayloads replay &&
                        exportCursorAgent restored == archived
          | _ => false

example : cursorAgentMovedAnonymousToolCloneCannotReplayNative = true := by
  native_decide

/-- Honest duplicate explicit ids remain losslessly imported but conservatively
share one authority key. Runtime export refuses the transcript; archival export
keeps the first entry native and preserves the later duplicate in a carrier. -/
def cursorAgentDuplicateExplicitIdIsRefusedAndArchived : Bool :=
  let line :=
    "{\"role\":\"assistant\",\"message\":{\"content\":[{" ++
    "\"type\":\"tool_use\",\"id\":\"shared-id\",\"name\":\"Bash\"," ++
    "\"input\":{\"cmd\":\"pwd\"}}]}}"
  let source := line ++ "\n" ++ line
  match importCursorAgent source with
  | .error _ => false
  | .ok imported =>
      (match imported.entries[0]?, imported.entries[1]? with
       | some first, some second =>
           first.origin.sourceRef == "line1" &&
             second.origin.sourceRef == "line2"
       | _, _ => false) &&
        cursorAgentIdentityNoteCount imported
            "cursorAgentDuplicateToolCallId" == 1 &&
        !cursorAgentTargetToolAuthoritiesUnique imported &&
        !imported.entries.any cursorAgentEntryNeedsHistoricalCarrier &&
        cursorAgentCheckedRefuses imported
          cursorAgentReplayedToolSourcePreflightError &&
        let archived := exportCursorAgent imported
        cursorAgentNativeThenHistoricalReplayShape archived &&
          match importCursorAgent archived with
          | .error _ => false
          | .ok restored =>
              cursorAgentPayloads restored == cursorAgentPayloads imported &&
                (match restored.entries[0]?, restored.entries[1]? with
                 | some first, some second =>
                     first.disposition == EntryDisposition.native &&
                       second.disposition == EntryDisposition.historicalUnverified
                 | _, _ => false) &&
                exportCursorAgent restored == archived

example : cursorAgentDuplicateExplicitIdIsRefusedAndArchived = true := by
  native_decide

/-- Two records imported independently both carry the mutable locator `line1`.
Their distinct explicit source ids remain distinct authority keys, so the source
locator collision does not cause a false replay refusal. -/
def cursorAgentDistinctExplicitIdsSurviveSourceRefCollision : Bool :=
  let line := fun (rawId : String) =>
    "{\"role\":\"assistant\",\"message\":{\"content\":[{" ++
    "\"type\":\"tool_use\",\"id\":\"" ++ rawId ++ "\",\"name\":\"Bash\"," ++
    "\"input\":{\"cmd\":\"pwd\"}}]}}"
  match importCursorAgent (line "independent-a"),
      importCursorAgent (line "independent-b") with
  | .ok firstImport, .ok secondImport =>
      match firstImport.entries[0]?, secondImport.entries[0]? with
      | some first, some secondSource =>
          let second : Entry := { secondSource with parent := some 0 }
          let combined : Transcript := { firstImport with
            entries := #[first, second], activeLeaf := some 1 }
          first.origin.sourceRef == "line1" &&
            second.origin.sourceRef == "line1" &&
            cursorAgentEntryToolAuthorityKeys first !=
              cursorAgentEntryToolAuthorityKeys second &&
            (Loom.violations combined).isEmpty &&
            cursorAgentTargetToolAuthoritiesUnique combined &&
            !combined.entries.any cursorAgentEntryNeedsHistoricalCarrier &&
            match exportCursorAgentTargetChecked combined with
            | .error _ => false
            | .ok output =>
                output == exportCursorAgent combined &&
                  cursorAgentTargetNativeJsonl output &&
                  ((output.splitOn "\n").filter
                    (fun raw => !raw.isEmpty)).length == 2 &&
                  !output.contains cursorAgentHistoricalProtocol
      | _, _ => false
  | _, _ => false

example : cursorAgentDistinctExplicitIdsSurviveSourceRefCollision = true := by
  native_decide

/-- Whole-entry carriers are exporter-owned closed records. The sole optional
outer field is an object-valued `sourceRawRecord`; missing required fields and
unexpected fields at outer, payload, and block levels all fail closed. -/
def cursorAgentHistoricalCarrierIsStrictCanonical : Bool :=
  let payload := Json.mkObj [
    ("kind", Json.str "userMsg"), ("blocks", Json.arr #[])]
  let carrier := fun (payload : Json) (extras : List (String × Json)) =>
    Json.mkObj ([
      ("type", Json.str cursorAgentHistoricalRecordType),
      ("protocol", Json.str cursorAgentHistoricalProtocol),
      ("payload", payload)] ++ extras)
  let canonical := carrier payload []
  let outerExtra := carrier payload [("unexpected", Json.bool true)]
  let missingProtocol := Json.mkObj [
    ("type", Json.str cursorAgentHistoricalRecordType), ("payload", payload)]
  let missingPayload := Json.mkObj [
    ("type", Json.str cursorAgentHistoricalRecordType),
    ("protocol", Json.str cursorAgentHistoricalProtocol)]
  let payloadExtra := carrier (Json.mkObj [
    ("kind", Json.str "userMsg"), ("blocks", Json.arr #[]),
    ("unexpected", Json.bool true)]) []
  let blockExtra := carrier (Json.mkObj [
    ("kind", Json.str "userMsg"),
    ("blocks", Json.arr #[Json.mkObj [
      ("kind", Json.str "text"), ("text", Json.str "x"),
      ("unexpected", Json.bool true)]])]) []
  let blockMissing := carrier (Json.mkObj [
    ("kind", Json.str "userMsg"),
    ("blocks", Json.arr #[Json.mkObj [("kind", Json.str "text")]])]) []
  let assistantToolExtra := carrier (Json.mkObj [
    ("kind", Json.str "assistantMsg"),
    ("blocks", Json.arr #[Json.mkObj [
      ("kind", Json.str "toolCall"), ("name", Json.str "Bash"),
      ("canonical", Json.str "bash"), ("arguments", Json.mkObj []),
      ("unexpected", Json.bool true)]])]) []
  let assistantToolMissingCanonical := carrier (Json.mkObj [
    ("kind", Json.str "assistantMsg"),
    ("blocks", Json.arr #[Json.mkObj [
      ("kind", Json.str "toolCall"), ("name", Json.str "Bash"),
      ("arguments", Json.mkObj [])]])]) []
  let malformedSource := carrier payload [
    (cursorAgentHistoricalSourceRawRecordKey, Json.str "not an object")]
  (match importCursorAgent canonical.compress with
   | .ok transcript => transcript.entries.toList.all (fun entry =>
       entry.disposition == EntryDisposition.historicalUnverified)
   | .error _ => false) &&
    [outerExtra, missingProtocol, missingPayload, payloadExtra, blockExtra,
      blockMissing, assistantToolExtra, assistantToolMissingCanonical,
      malformedSource].all (fun raw => cursorAgentRejects raw.compress)

example : cursorAgentHistoricalCarrierIsStrictCanonical = true := by native_decide

private def cursorAgentMixedNativeRawFixture : String :=
  "{\"role\":\"assistant\",\"topFuture\":{\"n\":1},\"message\":{" ++
  "\"messageFuture\":true,\"content\":[" ++
  "{\"type\":\"text\",\"text\":\"original\",\"textFuture\":1}," ++
  "{\"type\":\"tool_use\",\"id\":null,\"name\":\"Bash\"," ++
  "\"input\":{\"cmd\":\"pwd\"},\"toolFuture\":2}," ++
  "{\"type\":\"future_block\",\"raw\":{\"v\":3},\"future\":\"kept\"}]}}"

/-- Switching a mixed native message to a whole carrier retains its complete
raw object, including top/message/supported-block additions. Two archive hops
are stable. A later typed text mutation changes the carrier payload while the
original raw object remains inert provenance and cannot authorize a tool call. -/
def cursorAgentMixedNativeRawProvenanceIsExactAndInert : Bool :=
  match Json.parse cursorAgentMixedNativeRawFixture,
      importCursorAgent cursorAgentMixedNativeRawFixture with
  | .ok sourceRaw, .ok imported =>
      cursorAgentCheckedRefuses imported cursorAgentNativePayloadPreflightError &&
      let first := exportCursorAgent imported
      cursorAgentArchiveOnlyJsonl first 1 &&
      (cursorAgentSingleArchivedSourceRawRecord? first).map Json.compress ==
        some sourceRaw.compress &&
      match importCursorAgent first with
      | .error _ => false
      | .ok firstImport =>
          cursorAgentCheckedRefuses firstImport cursorAgentHistoricalTargetPreflightError &&
          let second := exportCursorAgent firstImport
          second == first &&
          (cursorAgentSingleArchivedSourceRawRecord? second).map Json.compress ==
            some sourceRaw.compress &&
          match importCursorAgent second with
          | .error _ => false
          | .ok secondImport =>
              match secondImport.entries[0]? with
              | none => false
              | some entry =>
                  match entry.payload with
                  | .assistantMsg [
                      .text "original", .toolCall name args rawId,
                      .unmodeled label rawBlock] =>
                      let declassified : Entry := { entry with disposition := .native }
                      (cursorAgentExactImportedToolBlock? declassified 1 name args rawId).isNone &&
                        let mutatedEntry : Entry := { entry with payload := .assistantMsg [
                          .text "mutated", .toolCall name args rawId,
                          .unmodeled label rawBlock] }
                        let mutated : Transcript := {
                          secondImport with entries := #[mutatedEntry] }
                        let mutatedArchive := exportCursorAgent mutated
                        mutatedArchive != second &&
                        (cursorAgentSingleArchivedSourceRawRecord? mutatedArchive).map
                            Json.compress == some sourceRaw.compress &&
                        match importCursorAgent mutatedArchive with
                        | .error _ => false
                        | .ok restored =>
                            cursorAgentCheckedRefuses restored
                              cursorAgentHistoricalTargetPreflightError &&
                            (match restored.entries[0]? with
                             | some restoredEntry => match restoredEntry.payload with
                                 | .assistantMsg [.text "mutated", _, _] => true
                                 | _ => false
                             | none => false) &&
                            exportCursorAgent restored == mutatedArchive
                  | _ => false
  | _, _ => false

example : cursorAgentMixedNativeRawProvenanceIsExactAndInert = true := by
  native_decide

private def cursorAgentForeignNativeLookingLifecycle : Transcript :=
  let source : Origin := { format := .pi, sourceRef := "foreign-native-looking" }
  { threads := #[{ kind := .main }],
    entries := #[
      { payload := .assistantMsg [
          .toolCall { raw := "ApplyPatch", canonical := some .applyPatch }
            (Json.str "*** Begin Patch\n*** End Patch") (some "foreign-patch"),
          .toolCall { raw := "exec_command", canonical := some .bash }
            (Json.mkObj [("cmd", Json.str "pwd")]) (some "foreign-exec")],
        origin := source },
      { parent := some 0,
        payload := .envMsg [.toolResult (.resolved 0 1) [.text "/tmp"]
          (.native false)],
        origin := source }],
    activeLeaf := some 1,
    origin := source }

private def cursorAgentForeignNativeLookingShape (transcript : Transcript) : Bool :=
  transcript.entries.size == 2 && transcript.activeLeaf == some 1 &&
    transcript.entries.all (fun entry =>
      entry.disposition == EntryDisposition.historicalUnverified) &&
    match transcript.entries[0]?, transcript.entries[1]? with
    | some calls, some result =>
        (match calls.payload with
         | .assistantMsg [
             .toolCall patch (Json.str "*** Begin Patch\n*** End Patch")
               (some "foreign-patch"),
             .toolCall exec args (some "foreign-exec")] =>
               patch.raw == "ApplyPatch" && exec.raw == "exec_command" &&
                 ostr args "cmd" == some "pwd"
         | _ => false) &&
        (match result.payload with
         | .envMsg [.toolResult (.resolved 0 1) [.text "/tmp"] (.native false)] => true
         | _ => false)
    | _, _ => false

/-- Foreign calls that match both observed native input shapes, plus their
linked result, remain inert after entry metadata is stripped and after two
export/import hops. The universal versioned carrier retains the complete typed
lifecycle without ever producing executable `tool_use` syntax. -/
def cursorAgentForeignNativeLookingLifecycleStaysInertTwoHops : Bool :=
  let first := exportCursorAgent cursorAgentForeignNativeLookingLifecycle
  !first.contains "\"type\":\"tool_use\"" &&
    (first.splitOn cursorAgentHistoricalProtocol).length == 3 &&
    match importCursorAgent first with
    | .error _ => false
    | .ok firstImport =>
        let stripped := cursorAgentStripCarrierMetadata firstImport
        let second := exportCursorAgent stripped
        cursorAgentForeignNativeLookingShape stripped && second == first &&
          !second.contains "\"type\":\"tool_use\"" &&
          match importCursorAgent second with
          | .error _ => false
          | .ok secondImport =>
              cursorAgentForeignNativeLookingShape secondImport &&
                exportCursorAgent secondImport == second

example : cursorAgentForeignNativeLookingLifecycleStaysInertTwoHops = true := by
  native_decide

/-! ## Round-trip self-parity (RC1) -/

/-- Self-parity for cursor-agent: `import → export → import` is stable under
`normalize` (the positional, entry-identity-independent projection). The format
cannot round-trip entry ids, timestamps, or results, but representable message
structure and Loom's additive tool-call ids survive. -/
def roundTripCursorAgent (text : String) : Bool :=
  match importCursorAgent text with
  | .error _ => false
  | .ok t => normalize t == (match importCursorAgent (exportCursorAgent t) with | .ok t2 => normalize t2 | .error _ => "ERR")

/-- THE DECIDE-PIN (self-parity, RC1): cursor-agent round-trips green under
`normalize`. If the exporter or the importer drifts, this stops compiling. -/
example : roundTripCursorAgent cursorAgentFixture = true := by native_decide

/-- The historical `normalize` pin intentionally erases tool names. This
stronger same-format pin uses the continuation projection, which includes raw
tool names and arguments, and also checks the source spellings explicitly so a
lowercase-on-first-import bug cannot become a stable but lossy fixed point. -/
def cursorAgentToolNameLifecycleRoundTrips : Bool :=
  match importCursorAgent cursorAgentToolNameFixture with
  | .error _ => false
  | .ok source =>
      let sourceProjection := continuationProjection source
      let exported := exportCursorAgent source
      match importCursorAgent exported with
      | .error _ => false
      | .ok restored =>
          sourceProjection.contains "\"name\":\"Bash\"" &&
          sourceProjection.contains "\"name\":\"CustomTOOL\"" &&
          exported.contains "\"name\":\"Bash\"" &&
          exported.contains "\"name\":\"CustomTOOL\"" &&
          continuationProjection restored == sourceProjection &&
          exportCursorAgent restored == exported

example : cursorAgentToolNameLifecycleRoundTrips = true := by native_decide

def cursorAgentExportEndsWithRecordDelimiter : Bool :=
  match importCursorAgent cursorAgentFixture with
  | .ok transcript => (exportCursorAgent transcript).endsWith "\n"
  | .error _ => false

example : cursorAgentExportEndsWithRecordDelimiter = true := by native_decide

/-! ## Historical RC2 burn-in — importer vs the TS oracle (2026-07-07)

The cutover harness (`parity/loom-diff.ts`) ran `importCursorAgent` against the
TS reference oracle (`parseSession` → `adaptCursorAgent`), both sides projected
through the shared positional `normalize` skeleton (roles + block kinds + text +
parent tree; tool names/args and ids are deliberately dropped by `normalize`).
Corpus: the entire local cursor-agent store — **283 root + 144 subagent
transcripts, 14,859 message records** (`~/.cursor/projects/*/agent-transcripts`).

RESULT AT THAT CUT: **427 / 427 files AGREE, 0 diverge, 0 error.** The hardened
importer now intentionally differs on the four `turn_ended` records by retaining
them as inert events. Structural counts only (no conversation content was
inspected): -/

structure BurnIn where
  rootFiles     : Nat        -- root transcripts (the `<uuid>/<uuid>.jsonl`)
  subagentFiles : Nat        -- `subagents/<child>.jsonl` children (D16 below)
  filesAgree    : Nat
  filesDiverge  : Nat
  msgRecords    : Nat        -- {role,message} records (assistant 13 280 / user 1 579)
  textBlocks    : Nat        -- content blocks of type "text"
  toolUseBlocks : Nat        -- content blocks of type "tool_use" (no id, no result)
  turnEndedMeta : Nat        -- top-level turn_ended metaevents (2 ok + 2 error)
  otherBlockKinds : Nat      -- content blocks that are NEITHER text NOR tool_use
  deriving Repr, DecidableEq

/-- The 2026-07-07 burn-in tally. Confirms the census in
`Loom/Formats/CursorAgent.lean` exactly (14,859 msg / 12,862 text / 16,210
tool_use). `otherBlockKinds = 0` is the load-bearing fact for divergence
category (d): across the whole corpus there is NO content block beyond
text/tool_use — no thinking, no tool_result, no media — so the importer's
two-arm block match drops nothing it should have modeled. -/
def rc2BurnIn : BurnIn := {
  rootFiles := 283, subagentFiles := 144,
  filesAgree := 427, filesDiverge := 0,
  msgRecords := 14859, textBlocks := 12862, toolUseBlocks := 16210,
  turnEndedMeta := 4, otherBlockKinds := 0 }

/-! ### Residual gaps and resolutions

This historical catalog now distinguishes remaining ceilings from defects
resolved after the burn-in, so the old parity result is not overstated. -/

inductive GapKind where
  | deferredFeature   -- needs new machinery (e.g. a multi-file actuator)
  | matchedDrop       -- both Lean and TS drop it → no divergence, but data lost
  | resolved          -- retained by the hardened importer after the historical run
  | irCeiling         -- unrepresentable in the Loom IR / the format itself
  | foundational      -- Lean-String-vs-JS-string; only on malformed input
  deriving Repr, DecidableEq, BEq

structure ResidualGap where
  id       : String
  kind     : GapKind
  triggers : Bool        -- does it occur anywhere in the real 427-file corpus?
  note     : String
  deriving Repr

def rc2ResidualGaps : List ResidualGap := [
  { id := "D16-subagent-sidechains", kind := .deferredFeature, triggers := false,
    note :=
      "144 subagent child transcripts live at <root>/subagents/<child>.jsonl. \
       The single-file importer (like adaptCursorAgent) never opens them, so \
       BOTH sides agree on the root file and the children are simply absent \
       from the IR — no divergence, but a real completeness gap. Pointing \
       loom-diff AT the children directly gives 144/144 AGREE, so the importer \
       already handles the child shape; what is missing is an ACTUATOR that \
       stitches them in. See the plan below." },
  { id := "turn_ended-metaevents", kind := .resolved, triggers := true,
    note :=
      "4 records (2 status/type + 2 error/status/type). The TS shape predicate \
       rejects them, but the hardened importer validates and retains each as an \
       inert custom event with exact raw provenance." },
  { id := "identity-time-cwd", kind := .matchedDrop, triggers := true,
    note :=
      "No per-entry id / timestamp / cwd exists on native records. Loom logs \
       deterministic entry-id synthesis, leaves time/cwd absent, and retains \
       native tool-call rawId as none rather than manufacturing identity." },
  { id := "lone-surrogate-text", kind := .foundational, triggers := false,
    note :=
      "A Lean String is a sequence of Unicode scalar values and cannot hold a \
       lone UTF-16 surrogate; JS strings can. Synthetic input with an unpaired \
       \\uD83D/\\uDE00 escape is the ONLY probe that diverges (Lean substitutes \
       U+FFFD). Valid Unicode — emoji, non-BMP, escaped surrogate PAIRS, control \
       chars, combining marks — all round-trip and AGREE. Malformed input only; \
       absent from the real corpus." }]

example : rc2ResidualGaps.length = 4 := by native_decide

-- Sanity: no unresolved, non-format-ceiling gap fires on the historical corpus.
example :
    (rc2ResidualGaps.filter (fun g => g.triggers && g.kind != GapKind.matchedDrop &&
      g.kind != GapKind.resolved)).length = 0 := by
  native_decide

/-! ### D16 plan — a multi-file actuator for subagent sidechains

`importCursorAgent : String → …` is string-in by design and structurally cannot
see sibling files. Closing D16 needs an ACTUATOR (IO, alongside
`importCursorAgentFile`) — the importer's block/entry logic is already correct
(144/144 child files AGREE), so no change to `importCursorAgent` itself.

Sketch (`importCursorAgentSession (root : FilePath)`):
  1. Import the root file as today → the main thread (thread 0).
  2. Glob `<root-dir>/subagents/*.jsonl`; import each child with the SAME block
     logic, each as its OWN sidechain thread (`Thread.kind := .sidechain`),
     re-basing entry/thread coordinates while keeping tool-call raw identity.
  3. Attach each sidechain to the transcript; log one ImportNote per child.

LINKAGE IS NOT IN-BAND (measured, not assumed): child UUIDs never appear inside
the root file, and per-root `#children` matches `#dispatch-calls` (Task/Subagent)
in only 9/27 dirs — many roots carry subagent children with ZERO dispatch calls
(auto-spawned helpers). So an actuator can attach children as sidechains by
directory containment, but CANNOT reliably bind a child to the specific parent
tool_call that spawned it from the data alone; any parent-call binding must be
heuristic (positional) and flagged approximate. This also means the eventual
oracle for D16 is NOT `adaptCursorAgent` (single-file) — parity for the stitched
result needs a multi-file reference, which does not yet exist on the TS side. -/

end LoomConvert
