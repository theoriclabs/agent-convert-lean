import LoomConvert.CursorAgent
import LoomConvert.CursorIdeActuator

/-!
# Recover results omitted by Cursor IDE's transcript export

The IDE also writes the text/tool-use JSONL shape called `cursor-agent` here.
Its native path identifies the composer, but the JSONL deliberately omits tool
results and call IDs. A read-only lookup of that exact composer can recover
results. Before joining, require the entire visible conversation and ordered
call signatures to agree; never join globally by a duplicated or absent ID.
Standalone exports remain pure file imports. Unsupported or stale matches
refuse recovery instead of borrowing another operation's output.
-/

namespace LoomConvert
open Loom Lean

private def field? (j : Json) (key : String) : Option Json :=
  (j.getObjVal? key).toOption

private def str? (j : Json) (key : String) : Option String :=
  (j.getObjVal? key >>= Json.getStr?).toOption

private def jsonObject (j : Json) : Json :=
  match j with
  | .str text => (Json.parse text).toOption.getD j
  | _ => j

private def objectFields (j : Json) : List (String × Json) :=
  match j.getObj? with
  | .ok fields => fields.toList
  | .error _ => []

/-- Only the enclosing export syntax is stripped. The text inside user_query
is compared verbatim, including whitespace and any literal XML. -/
private def exportedUserText (text : String) : String := Id.run do
  let mut body := text
  if body.startsWith "<timestamp>" then
    match body.splitOn "</timestamp>\n" with
    | [_, rest] => body := rest
    | _ => pure ()
  let opening := "<user_query>\n"
  let suffix := "\n</user_query>"
  if body.startsWith opening && body.endsWith suffix then
    return ((body.drop opening.length).toString.dropEnd suffix.length).toString
  return text

private def visibleText (t : Transcript) : List (Bool × String × Nat) := Id.run do
  let mut texts := []
  let mut calls := 0
  for entry in t.entries do
    match entry.payload with
    | .userMsg bs =>
        for b in bs do
          if let .text text := b then
            if !text.isEmpty then texts := (true, text, calls) :: texts
    | .assistantMsg bs =>
        for b in bs do
          match b with
          | .text text =>
              if !text.isEmpty then texts := (false, text, calls) :: texts
          | .toolCall .. => calls := calls + 1
          | _ => pure ()
    | _ => pure ()
  return texts.reverse

private def visibleTextMatches (exported stored : Transcript) : Bool :=
  let left := visibleText exported
  let right := visibleText stored
  left.length == right.length && (left.zip right).all (fun ((user, text, calls), (savedUser, savedText, savedCalls)) =>
    user == savedUser && calls == savedCalls &&
      (text == savedText || (user && exportedUserText text == savedText)))

private structure ExportCall where
  entry : Nat
  block : Nat
  name : String
  args : Json
  id : Option String
  origin : Origin

private def exportCalls (t : Transcript) : List ExportCall :=
  t.entries.toList.zipIdx.flatMap (fun (entry, ei) => match entry.payload with
    | .assistantMsg bs => bs.zipIdx.filterMap (fun (b, bi) => match b with
      | .toolCall name args id => some ⟨ei, bi, name.raw, args, id, entry.origin⟩
      | _ => none)
    | _ => [])

private def withoutCallId (args : Json) : Json :=
  match args with
  | .obj _ => Json.mkObj ((objectFields args).filter (fun (k, _) => k != "toolCallId"))
  | _ => args

private def renamedArgs (args : Json) (names : List (String × String)) : Json :=
  Json.mkObj ((objectFields (withoutCallId args)).map (fun (key, value) =>
    ((names.find? (fun pair => pair.1 == key)).map (·.2) |>.getD key, value)))

private def grepArgs (args : Json) : Json :=
  let renamed := renamedArgs args [
    ("caseInsensitive", "case_insensitive"), ("headLimit", "head_limit"),
    ("outputMode", "output_mode"), ("beforeContext", "-B"),
    ("afterContext", "-A"), ("context", "-C")]
  Json.mkObj ((objectFields renamed).filter (fun (key, value) =>
    !(["case_insensitive", "multiline"].contains key && value == .bool false) &&
    !(key == "offset" && value == toJson (0 : Nat))))

private def rawToolData (call : ExportCall) : Json :=
  ((call.origin.extras.bind (fun x => field? x "rawBubble")).bind
    (fun bubble => field? bubble "toolFormerData")).getD Json.null

/-- Match known IDE export renamings; unrecognized tools require exact raw name
and arguments. No fuzzy names, substrings, or positional-only match is accepted.
Shell's description is display metadata; all executable export arguments still
have to match, and the original exported arguments remain in the transcript. -/
private def callSignature (call : ExportCall) : String × Json :=
  match call.name with
  | "Shell" => ("shell", Json.mkObj ((objectFields call.args).filter
      (fun (key, _) => key != "description")))
  | "run_terminal_command_v2" =>
      let params := jsonObject ((field? (rawToolData call) "params").getD Json.null)
      ("shell", Json.mkObj ((field? params "command").toList.map (fun cmd => ("command", cmd))))
  | "Read" | "read_file_v2" => ("read", withoutCallId call.args)
  | "Glob" | "glob_file_search" =>
      ("glob", renamedArgs call.args [("globPattern", "glob_pattern"),
        ("targetDirectory", "target_directory")])
  | "Grep" | "ripgrep_raw_search" => ("grep", grepArgs call.args)
  | "GetDynamicTools" | "get_mcp_tools" =>
      ("get_mcp_tools", renamedArgs call.args [("server", "namespace")])
  | "CallDynamicTool" =>
      if str? call.args "namespace" == some "cursor" &&
          str? call.args "toolName" == some "SearchConversations" then
        ("search_conversations", (field? call.args "arguments").getD Json.null)
      else (call.name, call.args)
  | _ => (call.name, withoutCallId call.args)

private def resultsFor (t : Transcript) (call : ExportCall) : List (Entry × List UserBlock × ErrorSignal) :=
  t.entries.toList.flatMap (fun entry => match entry.payload with
    | .envMsg bs => bs.filterMap (fun b => match b with
      | .toolResult (.resolved ei bi) content error =>
          if ei == call.entry && bi == call.block then some (entry, content, error) else none
      | _ => none)
    | _ => [])

private def turnEndedRecord? (entry : Entry) : Option Json :=
  match entry.payload with
  | .event (.custom "cursor_agent.turn_ended" raw) =>
      some (Json.mkObj [
        ("kind", .str "cursor_agent.turn_ended"),
        ("reason", .str "Cursor turn bookkeeping retained outside conversation content"),
        ("raw", raw)])
  | _ => none

/-- Recover into the supplied export, keeping its messages, arguments, ordering,
and present source IDs; absent IDs are restored from the matched saved call.
Store results are joined by the checked complete call sequence
and then linked positionally; repeated source IDs cannot cross-wire outputs. -/
def recoverCursorIdeTranscript (exported stored : Transcript) (storePath : String) :
    Except String Transcript := do
  if exported.env.sessionId.isNone || exported.env.sessionId != stored.env.sessionId then
    throw "Cursor result recovery: export and store session identities differ"
  if exported.entries.any (fun entry =>
      entry.disposition != .native || match entry.payload with
      | .envMsg _ => true
      | _ => false) then
    throw "Cursor result recovery: export already contains historical carriers or results"
  if !visibleTextMatches exported stored then
    throw "Cursor result recovery: exported messages differ from the saved IDE conversation; refusing a stale or different branch"
  let sourceCalls := exportCalls exported
  let storedCalls := exportCalls stored
  if sourceCalls.length != storedCalls.length then
    throw "Cursor result recovery: exported tool-call count differs from the saved IDE conversation"
  for (source, saved) in sourceCalls.zip storedCalls do
    if source.args.getObj?.toOption.isNone || saved.args.getObj?.toOption.isNone then
      throw "Cursor result recovery: tool arguments must be objects for a verified match"
    if source.id.isSome && source.id != saved.id then
      throw "Cursor result recovery: exported call ID differs from the saved call"
    if callSignature source != callSignature saved then
      throw s!"Cursor result recovery: cannot verify tool arguments at export entry {source.entry}, block {source.block} ({source.name}); use the explicit cursor-ide command for the saved conversation"
    if (resultsFor stored saved).length > 1 then
      throw "Cursor result recovery: multiple results for one saved tool call"
  let mut entries : Array Entry := #[]
  let mut recovered := 0
  for (entry, oldIndex) in exported.entries.toList.zipIdx do
    if (turnEndedRecord? entry).isSome then continue
    let newIndex := entries.size
    let payload := match entry.payload with
      | .assistantMsg blocks => .assistantMsg (blocks.zipIdx.map (fun (block, bi) =>
          match block with
          | .toolCall name args id =>
              let saved := (sourceCalls.zip storedCalls).find? (fun (source, _) =>
                source.entry == oldIndex && source.block == bi)
              .toolCall name args (id.orElse (fun _ => saved.bind (fun pair => pair.2.id)))
          | other => other))
      | other => other
    entries := entries.push { entry with payload }
    for (source, saved) in sourceCalls.zip storedCalls do
      if source.entry == oldIndex then
        for (resultEntry, content, error) in resultsFor stored saved do
          entries := entries.push { resultEntry with
            parent := some (entries.size - 1)
            thread := entry.thread
            payload := .envMsg [.toolResult (.resolved newIndex source.block) content error] }
          recovered := recovered + 1
  -- The export is linear: each following message must follow the inserted
  -- results as well, so no recovered result is stranded off the active path.
  entries := entries.mapIdx (fun i entry => { entry with
    parent := if i == 0 then none else some (i - 1) })
  let originalExtras := exported.origin.extras.getD Json.null
  let controls := exported.entries.toList.filterMap turnEndedRecord? |>.toArray
  let priorRecords := fun key => ((field? originalExtras key).bind
    (fun value => value.getArr?.toOption)).getD #[]
  let extras := Json.mkObj (((objectFields originalExtras).filter (fun (key, _) =>
      key != "raw_control_messages" && key != "raw_inert_records")) ++ [
    -- Existing exporter contracts: Codex carries source controls; Claude
    -- carries inert records. Both preserve the same exact raw bookkeeping.
    ("raw_control_messages", .arr (priorRecords "raw_control_messages" ++ controls)),
    ("raw_inert_records", .arr (priorRecords "raw_inert_records" ++ controls)),
    ("cursorIdeResultSource", Json.mkObj [
      ("storePath", .str storePath),
      ("composerId", .str (stored.env.sessionId.getD "")),
      ("origin", stored.origin.extras.getD Json.null)])])
  let recoveredTranscript := { exported with
    entries
    activeLeaf := if entries.isEmpty then none else some (entries.size - 1)
    env := { exported.env with cwd := exported.env.cwd.orElse (fun _ => stored.env.cwd) }
    origin := { exported.origin with extras := some extras }
    importNotes := exported.importNotes ++ stored.importNotes ++
      (if controls.isEmpty then [] else [{
        kind := .other "cursorIdeTranscriptControlsArchived", loc := some exported.origin.sourceRef,
        detail := s!"archived {controls.size} Cursor turn_ended control records outside dialogue; exact records retained in provenance" }]) ++ [{
      kind := .other "cursorIdeTranscriptResultsRecovered", loc := some storePath,
      detail := s!"recovered {recovered} recorded tool results and available call IDs from the same Cursor IDE composer after matching all {sourceCalls.length} calls and visible messages; no tools were rerun" }] }
  if !(violations recoveredTranscript).isEmpty then
    throw "Cursor result recovery produced an invalid transcript"
  pure recoveredTranscript

private def cursorIdeStorePath? : IO (Option System.FilePath) := do
  if let some path ← IO.getEnv "LOOM_CURSOR_IDE_DB" then return some path
  let some home ← IO.getEnv "HOME" | return none
  let candidates : List System.FilePath := [
    System.FilePath.mk home / "Library/Application Support/Cursor/User/globalStorage/state.vscdb",
    System.FilePath.mk home / ".config/Cursor/User/globalStorage/state.vscdb"]
  for path in candidates do
    if ← path.pathExists then return some path
  pure none

private def recoveryUnavailable (t : Transcript) (path reason : String) : Transcript :=
  { t with importNotes := t.importNotes ++ [{
    kind := .other "cursorIdeTranscriptRecoveryUnavailable", loc := some path,
    detail := reason ++ "; the supplied Cursor transcript has calls but no recorded results. Use the matching state.vscdb and composer ID to recover them; no outputs were invented." }] }

/-- Path-aware acquisition for native IDE exports. An arbitrary filename is not
identity evidence and never causes a local database lookup. The override permits
read-only snapshots and deterministic tests without changing the user's store. -/
def importCursorTranscriptAtPath (path : System.FilePath) (text : String) :
    IO (Except String Transcript) := do
  let exported ← match importCursorAgentAtPath path text with
    | .error error => return .error error
    | .ok t => pure t
  let some sessionId := cursorAgentSessionIdFromPath path | return .ok exported
  if (exportCalls exported).isEmpty then return .ok exported
  -- Already-enriched/archival transcripts are not the IDE's lossy native export.
  if exported.entries.any (fun entry =>
      entry.disposition != .native || match entry.payload with
      | .envMsg _ => true
      | _ => false) then return .ok exported
  let some db ← cursorIdeStorePath?
    | return .ok (recoveryUnavailable exported path.toString "No local Cursor IDE store was found")
  match ← readCursorIdeStore? db.toString sessionId with
  | .error error => return .error s!"Cursor result recovery: {error}"
  | .ok none => return .ok (recoveryUnavailable exported path.toString
      "The inspected Cursor IDE store has no matching composer")
  | .ok (some source) =>
      match importCursorIde source with
      | .error error => return .error s!"Cursor result recovery: {error}"
      | .ok stored => return recoverCursorIdeTranscript exported stored db.toString

/-- File reader used by conversion and inspection, including sidecar imports. -/
def importCursorTranscriptFile (path : System.FilePath) : IO (Except String Transcript) := do
  importCursorTranscriptAtPath path (← IO.FS.readFile path)

end LoomConvert
