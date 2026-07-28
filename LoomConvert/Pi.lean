import Loom

/-!
# LoomConvert.Pi — the pi importer/exporter (role-content-sum IR)

pi JSONL ↔ Loom IR, pure Lean (`Lean.Json` + `IO.FS`, no host bridge). The
template every other importer/exporter copies. Under the role-content-sum,
pi's flat `{role, content:[…]}` message maps to a role-indexed `Payload`:
`user`→`userMsg`, `assistant`→`assistantMsg`, `toolResult`→`envMsg`, and any
other role→`otherMsg`. Pi stores result linkage and error state on the message,
so import reconstructs a structured `EnvBlock.toolResult`; export emits one Pi
message per result block.

`Origin.rawId`/`extras` carry identity, timestamp, and the source JSON object so
open-world fields survive same-format round trips.
-/

namespace LoomConvert
open Loom
open Lean (Json)

def piTargetVersion : String := "0.74.0"

/-! ## Small Json accessors (Except → Option) -/

private def ostr (j : Json) (k : String) : Option String :=
  (j.getObjVal? k >>= Json.getStr?).toOption

private def oobj (j : Json) (k : String) : Option Json :=
  (j.getObjVal? k).toOption

private def onat (j : Json) (k : String) : Option Nat :=
  (j.getObjVal? k >>= Json.getNat?).toOption

private def oarr (j : Json) (k : String) : Option (Array Json) :=
  (j.getObjVal? k >>= Json.getArr?).toOption

private def overlayJsonFields (raw : Json) (modeledKeys : List String)
    (fields : List (String × Json)) : Json :=
  match raw with
  | .obj obj =>
      let obj := modeledKeys.foldl (fun acc key => acc.erase key) obj
      Json.obj (fields.foldl (fun acc field => acc.insert field.1 field.2) obj)
  | _ => Json.mkObj fields

/-! ## Export: Loom IR → pi JSONL -/

private def piCarrierKey : String := "loomPi"

private def piCarrierVersion : Nat := 1

/-- Pi's content unions are closed. Richer Loom blocks therefore travel in a
valid, inert text block whose additive payload reconstructs the original IR
constructor. Pi renders the empty text and otherwise ignores the stamp. -/
private def piBlockCarrier (author constructor label : String) (raw : Json) : Json :=
  Json.mkObj [
    ("type", Json.str "text"),
    ("text", Json.str ""),
    (piCarrierKey, Json.mkObj [
      ("version", Json.num piCarrierVersion),
      ("kind", Json.str "block"),
      ("author", Json.str author),
      ("constructor", Json.str constructor),
      ("label", Json.str label),
      ("raw", raw)])]

def userBlockToJson : UserBlock → Json
  | .text s => Json.mkObj [("type", Json.str "text"), ("text", Json.str s)]
  | .media m loc => Json.mkObj [("type", Json.str "image"),
                                ("mimeType", Json.str m), ("data", Json.str loc)]
  | .unmodeled label raw => piBlockCarrier "user" "unmodeled" label raw

def assistantBlockToJson : AssistantBlock → Json
  | .text s => Json.mkObj [("type", Json.str "text"), ("text", Json.str s)]
  | .thinking s sig =>
      Json.mkObj ([("type", Json.str "thinking"), ("thinking", Json.str s)]
        ++ (match sig with | some g => [("thinkingSignature", Json.str g)] | none => []))
  | .toolCall name args rawId =>
      match args, rawId with
      | .obj _, some id =>
          if id.isEmpty || name.raw.isEmpty then
            piBlockCarrier "assistant" "toolCall" "toolCall" <| Json.mkObj
              [("name", Json.str name.raw), ("arguments", args), ("id", Json.str id)]
          else
            Json.mkObj [("type", Json.str "toolCall"), ("id", Json.str id),
              ("name", Json.str name.raw), ("arguments", args)]
      | _, _ =>
          piBlockCarrier "assistant" "toolCall" "toolCall" <| Json.mkObj
            ([("name", Json.str name.raw), ("arguments", args)] ++
              (match rawId with | some id => [("id", Json.str id)] | none => []))
  | .media m loc =>
      piBlockCarrier "assistant" "media" "media" <| Json.mkObj [
        ("mimeType", Json.str m), ("data", Json.str loc)]
  | .unmodeled label raw => piBlockCarrier "assistant" "unmodeled" label raw

private def overlayPiBlock (raw : Option Json) (kind : String)
    (modeledKeys : List String) (fields : List (String × Json)) : Json :=
  match raw with
  | some source =>
      if ostr source "type" == some kind then
        overlayJsonFields source modeledKeys fields
      else Json.mkObj fields
  | none => Json.mkObj fields

private def userBlockToJsonPreserving (raw : Option Json) : UserBlock → Json
  | .text text =>
      overlayPiBlock raw "text" ["type", "text"]
        [("type", Json.str "text"), ("text", Json.str text)]
  | .media mimeType data =>
      overlayPiBlock raw "image" ["type", "mimeType", "data"] [
        ("type", Json.str "image"), ("mimeType", Json.str mimeType),
        ("data", Json.str data)]
  | .unmodeled label source => piBlockCarrier "user" "unmodeled" label source

private def assistantBlockToJsonPreserving (raw : Option Json) : AssistantBlock → Json
  | .text text =>
      overlayPiBlock raw "text" ["type", "text"]
        [("type", Json.str "text"), ("text", Json.str text)]
  | .thinking thinking signature =>
      overlayPiBlock raw "thinking" ["type", "thinking", "thinkingSignature"]
        ([("type", Json.str "thinking"), ("thinking", Json.str thinking)] ++
          (match signature with
           | some value => [("thinkingSignature", Json.str value)]
           | none => []))
  | .toolCall name arguments rawId =>
      match arguments, rawId with
      | .obj _, some id =>
          if id.isEmpty || name.raw.isEmpty then
            piBlockCarrier "assistant" "toolCall" "toolCall" <| Json.mkObj
              [("name", Json.str name.raw), ("arguments", arguments),
               ("id", Json.str id)]
          else
            overlayPiBlock raw "toolCall" ["type", "name", "arguments", "id"] [
              ("type", Json.str "toolCall"), ("id", Json.str id),
              ("name", Json.str name.raw), ("arguments", arguments)]
      | _, _ =>
          piBlockCarrier "assistant" "toolCall" "toolCall" <| Json.mkObj
            ([("name", Json.str name.raw), ("arguments", arguments)] ++
              (match rawId with | some id => [("id", Json.str id)] | none => []))
  | .media mimeType data =>
      piBlockCarrier "assistant" "media" "media" <| Json.mkObj [
        ("mimeType", Json.str mimeType), ("data", Json.str data)]
  | .unmodeled label source => piBlockCarrier "assistant" "unmodeled" label source

private def piRawMessage (rawEntry : Option Json) : Option Json :=
  rawEntry.bind (fun entry => oobj entry "message")

private def piRawContent (rawEntry : Option Json) : Option (Array Json) :=
  piRawMessage rawEntry |>.bind (fun message => oarr message "content")

private def userBlocksToJsonPreserving (rawEntry : Option Json)
    (blocks : List UserBlock) : List Json :=
  let rawContent := piRawContent rawEntry
  blocks.zipIdx.map (fun (block, blockIdx) =>
    userBlockToJsonPreserving (rawContent.bind (fun content => content[blockIdx]?)) block)

private def assistantBlocksToJsonPreserving (rawEntry : Option Json)
    (blocks : List AssistantBlock) : List Json :=
  let rawContent := piRawContent rawEntry
  blocks.zipIdx.map (fun (block, blockIdx) =>
    assistantBlockToJsonPreserving (rawContent.bind (fun content => content[blockIdx]?)) block)

/-- Env (tool-result) content flattened to pi's text blocks (pi stores role
"toolResult" messages with text content, no structured tool-result block). -/
def envMsgContent (bs : List EnvBlock) : List Json :=
  bs.flatMap (fun b => match b with
    | EnvBlock.toolResult _ content _ => content.map userBlockToJson
    | EnvBlock.unmodeled _ raw => [raw])

private def piSentinel : String := "loom-unrecorded"

private def piPlaceholderTimestamp : String := "1970-01-01T00:00:00.000Z"

private def piHistoryApi : String := "loom-assistant-history"

private def piHistoryProvider : String := "loom-history"

private def piHistoryModel : String := "foreign-assistant"

private def piZeroUsage : Json := Json.mkObj [
  ("input", Json.num 0), ("output", Json.num 0),
  ("cacheRead", Json.num 0), ("cacheWrite", Json.num 0),
  ("totalTokens", Json.num 0),
  ("cost", Json.mkObj [
    ("input", Json.num 0), ("output", Json.num 0),
    ("cacheRead", Json.num 0), ("cacheWrite", Json.num 0),
    ("total", Json.num 0)])]

private def piSourceEnvironmentExtraKey : String := "piSourceEnvironment"

private def piNullableStringJson : Option String → Json
  | some value => Json.str value
  | none => Json.null

private def piSourceEnvironmentJson (env : EnvInfo) : Json := Json.mkObj [
  ("cwd", piNullableStringJson env.cwd),
  ("model", piNullableStringJson env.model),
  ("provider", piNullableStringJson env.provider),
  ("harnessVersion", piNullableStringJson env.harnessVersion),
  ("instructions", piNullableStringJson env.instructions),
  ("sessionId", piNullableStringJson env.sessionId)]

private def piDecodeNullableString
    (value : Json) (key : String) : Option (Option String) :=
  match value.getObjVal? key with
  | .ok (.str text) => some (some text)
  | .ok .null => some none
  | _ => none

private def piDecodeSourceEnvironment (value : Json) : Option EnvInfo := do
  let cwd ← piDecodeNullableString value "cwd"
  let model ← piDecodeNullableString value "model"
  let provider ← piDecodeNullableString value "provider"
  let harnessVersion ← piDecodeNullableString value "harnessVersion"
  let instructions ← piDecodeNullableString value "instructions"
  let sessionId ← piDecodeNullableString value "sessionId"
  pure { cwd, model, provider, harnessVersion, instructions, sessionId }

private def nonemptyString (value : Option String) : Option String :=
  value.bind (fun s => if s.isEmpty then none else some s)

private def transcriptStringExtra (t : Transcript) (key : String) : Option String :=
  nonemptyString (t.origin.extras.bind (fun extras => ostr extras key))

private def targetTimestamp (t : Transcript) : Option String :=
  transcriptStringExtra t "target_timestamp"

private def targetSessionId (t : Transcript) : Option String :=
  transcriptStringExtra t "target_session_id"

private def targetCwd (t : Transcript) : Option String :=
  transcriptStringExtra t "target_cwd"

private def targetProvider (t : Transcript) : Option String :=
  transcriptStringExtra t "target_provider"

private def targetModel (t : Transcript) : Option String :=
  transcriptStringExtra t "target_model"

private def targetHarnessVersion (t : Transcript) : Option String :=
  transcriptStringExtra t "target_harness_version"

private def piStampedAssistantHistoryMode (t : Transcript) : Option String := do
  let extras ← t.origin.extras
  let header ← oobj extras "piRaw"
  let stamp ← oobj header piCarrierKey
  guard (onat stamp "version" == some piCarrierVersion)
  let targetOptions ← oobj stamp "targetOptions"
  let history ← oobj targetOptions "pi_assistant_history"
  nonemptyString (ostr history "value")

private def piAssistantHistoryMode (t : Transcript) : String :=
  (transcriptStringExtra t "pi_assistant_history" <|>
    piStampedAssistantHistoryMode t).getD "context"

private def piUsesTargetOptions (t : Transcript) : Bool :=
  (targetSessionId t).isSome && (targetCwd t).isSome &&
    (targetProvider t).isSome && (targetModel t).isSome &&
    (targetTimestamp t).isSome && (targetHarnessVersion t).isSome

private def piSourceNative (t : Transcript) : Bool :=
  t.origin.format == Format.pi

private def piSessionId (t : Transcript) : Option String :=
  targetSessionId t <|>
    if piSourceNative t then
      nonemptyString t.env.sessionId <|> nonemptyString t.origin.rawId
    else none

private def piCwd (t : Transcript) : Option String :=
  targetCwd t <|>
    if piSourceNative t then nonemptyString t.env.cwd else none

private def piHeaderTimestamp (t : Transcript) : Option String :=
  targetTimestamp t <|>
    if piSourceNative t then transcriptStringExtra t "ts" else none

private def piStampedObject (fields : List (String × Json)) : Json :=
  Json.mkObj (("version", Json.num piCarrierVersion) :: fields)

private def piMessageTimestamp (rawEntry : Option Json) (entryTimestamp : String) : Nat :=
  let current :=
    (iso8601ToEpochMs? entryTimestamp).map (fun timestamp => timestamp.ms) |>.getD 0
  if rawEntry.bind (fun entry => ostr entry "timestamp") == some entryTimestamp then
    (piRawMessage rawEntry).bind (fun message => onat message "timestamp") |>.getD current
  else current

private def rawMessageContent (rawEntry : Option Json) : Option Json :=
  piRawMessage rawEntry |>.bind (fun message => oobj message "content")

private def userContentToJson (rawEntry : Option Json)
    (blocks : List UserBlock) : Json :=
  match blocks, rawMessageContent rawEntry with
  | [.text text], some (.str _) => Json.str text
  | _, _ => Json.arr (userBlocksToJsonPreserving rawEntry blocks).toArray

private def messageJson (_t : Transcript) (rawEntry : Option Json)
    (base : List (String × Json)) (role : String) (content : Json)
    (entryTimestamp : String) (extra : List (String × Json) := [])
    (carrier : List (String × Json) := [])
    (carrierKeys : List String := []) : Json :=
  let timestamp := piMessageTimestamp rawEntry entryTimestamp
  let structuralFields := [
    ("role", Json.str role), ("content", content), ("timestamp", Json.num timestamp)]
  let carrierFields := carrier
  let carrierStamp :=
    if carrierKeys.isEmpty then none else
      let extras := match piRawMessage rawEntry |>.bind (fun raw => oobj raw piCarrierKey) with
        | some (.obj fields) =>
            carrierKeys.foldl (fun acc key => acc.erase key)
              (fields.erase "version") |>.toList
        | _ => []
      let stampedFields := extras ++ carrierFields
      if stampedFields.isEmpty then none
      else some (Json.mkObj
        (("version", Json.num piCarrierVersion) :: stampedFields))
  let fields := structuralFields ++ extra ++
    (match carrierStamp with
     | some stamp => [(piCarrierKey, stamp)]
     | none => [])
  let message := match piRawMessage rawEntry with
    | some raw =>
        overlayJsonFields raw
          (["role", "content", "timestamp"] ++ extra.map (fun field => field.1) ++
            (if carrierKeys.isEmpty then [] else [piCarrierKey])) fields
    | none => Json.mkObj fields
  let entryFields := base ++ [("type", Json.str "message"), ("message", message)]
  match rawEntry with
  | some raw =>
      overlayJsonFields raw
        ["id", "parentId", "timestamp", piCarrierKey, "type", "message"]
        entryFields
  | none => Json.mkObj entryFields

private def piHistoricalCanonicalTool : CanonicalTool -> String
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

/-- Pi's native assistant `toolCall` block has slots for exactly an id, a name,
and object-shaped arguments — no slot for Loom's canonical tool identity, and no
room for one, since a reserved Loom stamp ON the block would mark the whole
message historical (`piAssistantContentHasCarrier`).

That is a reason to carry the field elsewhere, not a reason to refuse the
block. `piToolCanonicalCarrier` puts it in the MESSAGE-level reserved stamp
beside `toolCallRef` / `toolError`, which is out of the content array and so
does not touch disposition, and `piToolCanonicalCarrier?` reads it back. The
call renders as a real Pi `toolCall` and the interpretation survives with it —
`LoomOps.Interop.Emission.envelopePreserved`, the same shape
`CodexCli.synthesizedNativeCallEvidence?` uses for the identical wire limit. -/
private def piToolCallIsNativeRepresentable
    (name : ToolName) (arguments : Json) (rawId : Option String) : Bool :=
  match arguments, rawId with
  | .obj _, some id => !name.raw.isEmpty && !id.isEmpty
  | _, _ => false

/-- Emitted-content index → canonical identity, for the calls a message renders
as native Pi `toolCall` blocks. Indices are positions in the array that actually
reaches the artifact, which is what the importer re-indexes against; under
context projection that is the FILTERED block list, not the IR one. -/
private def piToolCanonicalEntries
    (blocks : List AssistantBlock) : List (Nat × CanonicalTool) :=
  blocks.zipIdx.filterMap (fun (block, blockIdx) =>
    match block with
    | .toolCall name arguments rawId =>
        if piToolCallIsNativeRepresentable name arguments rawId then
          name.canonical.map (fun canonical => (blockIdx, canonical))
        else none
    | _ => none)

/-- Empty unless a natively emitted call actually asserts a canonical identity.
Pi's own importer never produces one for a native block, so a pi → pi trip adds
no stamp member and the message is byte-identical. -/
private def piToolCanonicalCarrier
    (blocks : List AssistantBlock) : List (String × Json) :=
  match piToolCanonicalEntries blocks with
  | [] => []
  | entries => [("toolCanonical", Json.arr (entries.map
      (fun (blockIdx, canonical) => Json.mkObj [
        ("block", Json.num (Lean.JsonNumber.fromNat blockIdx)),
        ("canonical", Json.str (piHistoricalCanonicalTool canonical))])).toArray)]

/-- Pi's native assistant content union is closed. Plain text and executable
tool calls replay as target-native context; provider-signed reasoning, media,
and open-world blocks must travel inert.

Tool calls qualify on *target capability* and *structural validity* only. Pi
0.74.0 reads `{"type":"toolCall","id","name","arguments"}` from any assistant
message regardless of who produced the session, so gating this on
`origin.format == .pi` would emit native calls only when conversion is
unnecessary. `EntryDisposition.native` remains the anti-laundering guard and is
checked separately by `piEntryEmitsNativeToolCalls`.

`ambiguousCallIds` carries the ids Pi's native call namespace cannot address —
see `piAmbiguousToolCallIds`. It is threaded as a parameter rather than
recomputed per block so the decomposition stays linear. -/
private def piAssistantBlockIsContextSafe
    (ambiguousCallIds : List String) : AssistantBlock -> Bool
  | .text _ => true
  | .toolCall name arguments rawId =>
      piToolCallIsNativeRepresentable name arguments rawId &&
        !rawId.any ambiguousCallIds.contains
  | _ => false

/-- Every tool-call id carried by more than one assistant call block anywhere in
the transcript. Pi's native call namespace is keyed by id alone and its importer
refuses to guess between duplicate occurrences, so an ambiguous id can never be
emitted as a native `toolCall`. Those calls keep the coordinate-bearing carrier,
which resolves positionally and therefore stays lossless — the transcript is
converted, not refused. -/
private def piAmbiguousToolCallIds (t : Transcript) : List String :=
  let ids := t.entries.toList.flatMap (fun entry =>
    match entry.payload with
    | .assistantMsg blocks => blocks.filterMap (fun
        | .toolCall _ _ (some rawId) => some rawId
        | _ => none)
    | _ => [])
  (ids.filter (fun id => ids.count id > 1)).eraseDups

/-- This message-level stamp records provenance but deliberately does not set
historical disposition on import. Its native content is restricted to the
context-safe blocks above; every unsafe block travels in a separate custom
carrier. -/
private def piSynthesizedAssistantJson (t : Transcript)
    (ambiguousCallIds : List String)
    (base : List (String × Json)) (blocks : List AssistantBlock)
    (entryTimestamp : String) : Json :=
  let emitted := blocks.filter (piAssistantBlockIsContextSafe ambiguousCallIds)
  let content := emitted.map assistantBlockToJson
  let canonicalCarrier := piToolCanonicalCarrier emitted
  messageJson t none base "assistant" (Json.arr content.toArray) entryTimestamp [
    ("api", Json.str piHistoryApi),
    ("provider", Json.str piHistoryProvider),
    ("model", Json.str piHistoryModel),
    ("usage", piZeroUsage),
    ("stopReason", Json.str "stop")]
    ([("assistantHistory", Json.mkObj [
      ("mode", Json.str "context"),
      ("identity", Json.str "reserved"),
      ("metadata", Json.str "synthesized-unrecorded"),
      ("usage", Json.str "synthesized-zero-unrecorded"),
      ("stopReason", Json.str "synthesized-unrecorded"),
      ("timestamp", Json.str "source-or-target")])] ++ canonicalCarrier)
    (["assistantHistory"] ++
      (if canonicalCarrier.isEmpty then [] else ["toolCanonical"]))

private def piCallIdOfRef (t : Transcript) : CallRef -> Option String
  | .resolved entry block =>
      (t.entries[entry]?).bind (fun callEntry =>
        match callEntry.payload with
        | .assistantMsg blocks => (blocks[block]?).bind (fun
            | .toolCall _ _ rawId => rawId
            | _ => none)
        | _ => none)
  | .unresolved rawId _ => rawId

private def piToolNameOfRef (t : Transcript) : CallRef → Option String
  | .resolved entry block =>
      (t.entries[entry]?).bind (fun callEntry =>
        match callEntry.payload with
        | .assistantMsg blocks => (blocks[block]?).bind (fun
            | .toolCall name _ _ => some name.raw
            | _ => none)
        | _ => none)
  | .unresolved _ _ => none

/-- Overlay current structural/typed fields onto a raw Pi entry. Pi objects are
open-world, so unmodeled extension fields must survive a same-format round trip. -/
private def overlayPiEntry (raw : Json) (fields : List (String × Json)) : Json :=
  overlayJsonFields raw ["id", "parentId", "timestamp", piCarrierKey] fields

private def piRawEntry (origin : Origin) : Option Json :=
  match origin.format with
  | .pi => origin.extras.bind (fun extras => oobj extras "piRaw")
  | _ => none

private def piSourceEnvironmentJsonFromHeader? (header : Json) : Option Json := do
  let stamp ← oobj header piCarrierKey
  guard (onat stamp "version" == some piCarrierVersion)
  oobj stamp "sourceEnvironment"

private def piArchivedSourceEnvironmentJson? (t : Transcript) : Option Json :=
  if piSourceNative t then
    t.origin.extras.bind (fun extras =>
      oobj extras piSourceEnvironmentExtraKey) <|>
      (piRawEntry t.origin).bind piSourceEnvironmentJsonFromHeader?
  else none

/-- Source environment provenance recovered from a Pi target's ignored session
header stamp. Target identity remains in `Transcript.env`; this archive is the
pre-conversion source identity and is therefore kept separately. -/
def piArchivedSourceEnvironment (t : Transcript) : Option EnvInfo :=
  (piArchivedSourceEnvironmentJson? t).bind piDecodeSourceEnvironment

private def piSourceEnvironmentForHeader (t : Transcript) : EnvInfo :=
  (piArchivedSourceEnvironment t).getD t.env

private def piEntryJson (origin : Origin) (fields : List (String × Json)) : Json :=
  match piRawEntry origin with
  | some raw => overlayPiEntry raw fields
  | none => Json.mkObj fields

private def piErrorExport (error : ErrorSignal) : Bool × List (String × Json) :=
  match error with
  | .native value => (value, [])
  | .inferred value heuristic =>
      (value, [("toolError", Json.mkObj [
        ("state", Json.str "inferred"), ("value", Json.bool value),
        ("heuristic", Json.str heuristic)])])
  | .unrecorded =>
      (false, [("toolError", Json.mkObj [
        ("state", Json.str "unrecorded")])])

private def piCallRefCarrier : CallRef → List (String × Json)
  | .resolved _ _ => []
  | .unresolved rawId note =>
      [("toolCallRef", Json.mkObj
        (("state", Json.str "unresolved") :: ("note", Json.str note) ::
          (match rawId with
           | some id => [("rawId", Json.str id)]
           | none => [("rawId", Json.null)])))]

private def piCustomCarrierEntry (base : List (String × Json))
    (kind : String) (data : Json) : Json :=
  Json.mkObj (base ++ [
    ("type", Json.str "custom"),
    ("customType", Json.str "loom.pi.carrier"),
    ("data", piStampedObject [("kind", Json.str kind), ("value", data)])])

private def piCustomCarrierEntryOverRaw (raw : Json)
    (base : List (String × Json)) (kind : String) (data : Json) : Json :=
  overlayJsonFields raw
    ["id", "parentId", "timestamp", piCarrierKey, "type", "customType", "data"]
    (base ++ [
      ("type", Json.str "custom"),
      ("customType", Json.str "loom.pi.carrier"),
      ("data", piStampedObject [("kind", Json.str kind), ("value", data)])])

private def piCarrierEntryKind? (entry : Json) : Option String := do
  guard (ostr entry "type" == some "custom")
  guard (ostr entry "customType" == some "loom.pi.carrier")
  let data ← oobj entry "data"
  guard (onat data "version" == some piCarrierVersion)
  ostr data "kind"

private def piCarrierValue? (entry : Json) : Option Json := do
  let data ← oobj entry "data"
  guard (onat data "version" == some piCarrierVersion)
  (data.getObjVal? "value").toOption

private def piCustomCarrierEntryPreserving (rawEntry : Option Json)
    (base : List (String × Json)) (kind : String) (data : Json) : Json :=
  match rawEntry with
  | some raw =>
      if piCarrierEntryKind? raw == some kind then
        let dataFields := [
          ("version", Json.num piCarrierVersion),
          ("kind", Json.str kind), ("value", data)]
        let carrierData := match oobj raw "data" with
          | some rawData =>
              overlayJsonFields rawData ["version", "kind", "value"] dataFields
          | none => Json.mkObj dataFields
        let fields := base ++ [
          ("type", Json.str "custom"),
          ("customType", Json.str "loom.pi.carrier"),
          ("data", carrierData)]
        overlayJsonFields raw
          ["id", "parentId", "timestamp", piCarrierKey,
           "type", "customType", "data"] fields
      else piCustomCarrierEntry base kind data
  | none => piCustomCarrierEntry base kind data

private def piAssistantCarrierValue (blocks : List AssistantBlock) : Json :=
  Json.mkObj [
    ("blocks", Json.arr (blocks.map assistantBlockToJson).toArray),
    ("representation", Json.str "inert-unrecorded-metadata")]

private def piHistoricalOptionalString : Option String -> Json
  | some value => Json.str value
  | none => Json.null

private def piHistoricalUserBlock : UserBlock -> Json
  | .text text => Json.mkObj [("kind", Json.str "text"), ("text", Json.str text)]
  | .media mimeType data => Json.mkObj [
      ("kind", Json.str "media"), ("mimeType", Json.str mimeType),
      ("data", Json.str data)]
  | .unmodeled label raw => Json.mkObj [
      ("kind", Json.str "unmodeled"), ("label", Json.str label), ("raw", raw)]

private def piHistoricalAssistantBlock : AssistantBlock -> Json
  | .text text => Json.mkObj [("kind", Json.str "text"), ("text", Json.str text)]
  | .thinking thinking signature => Json.mkObj [
      ("kind", Json.str "thinking"), ("thinking", Json.str thinking),
      ("signature", piHistoricalOptionalString signature)]
  | .toolCall name arguments rawId => Json.mkObj [
      ("kind", Json.str "toolCall"), ("name", Json.str name.raw),
      ("canonical", name.canonical.map (fun canonical =>
        Json.str (piHistoricalCanonicalTool canonical)) |>.getD Json.null),
      ("arguments", arguments), ("rawId", piHistoricalOptionalString rawId)]
  | .media mimeType data => Json.mkObj [
      ("kind", Json.str "media"), ("mimeType", Json.str mimeType),
      ("data", Json.str data)]
  | .unmodeled label raw => Json.mkObj [
      ("kind", Json.str "unmodeled"), ("label", Json.str label), ("raw", raw)]

private def piUnsafeAssistantBlocks (ambiguousCallIds : List String)
    (blocks : List AssistantBlock) : List AssistantBlock :=
  blocks.filter (fun block =>
    !piAssistantBlockIsContextSafe ambiguousCallIds block)

/-- Maximal runs of consecutive blocks of one context-safety class, each block
paired with its source index.

Context mode splits an IR assistant message into a readable Pi message plus an
inert carrier. Collecting *all* safe blocks and then *all* unsafe blocks would
reorder every source that interleaves them — Claude and Cursor emit `thinking`
before `text` as a matter of course — because the exported record order is the
only order the reader ever sees again. Splitting on run boundaries instead makes
record order reproduce source block order exactly, for any interleaving. -/
private def piAssistantBlockRuns (ambiguousCallIds : List String)
    (blocks : List AssistantBlock) :
    List (Bool × List (Nat × AssistantBlock)) :=
  let step := fun (runs : List (Bool × List (Nat × AssistantBlock)))
      (item : AssistantBlock × Nat) =>
    let safe := piAssistantBlockIsContextSafe ambiguousCallIds item.1
    match runs with
    | (runSafe, located) :: earlier =>
        if runSafe == safe then (runSafe, (item.2, item.1) :: located) :: earlier
        else (safe, [(item.2, item.1)]) :: runs
    | [] => [(safe, [(item.2, item.1)])]
  (blocks.zipIdx.foldl step []).reverse.map (fun (safe, located) =>
    (safe, located.reverse))

private def piRunBlocks (located : List (Nat × AssistantBlock)) : List AssistantBlock :=
  located.map (fun item => item.2)

private def piRunSourceIndices (located : List (Nat × AssistantBlock)) : List Nat :=
  located.map (fun item => item.1)

private def piHistoricalAssistantCarrierValue
    (scope : String) (sourceEntry : Nat) (blocks : List AssistantBlock)
    (indices : List Nat) : Json :=
  Json.mkObj [
    ("blocks", Json.arr (blocks.map piHistoricalAssistantBlock).toArray),
    ("representation", Json.str "historical-assistant-blocks"),
    ("scope", Json.str scope),
    ("sourceEntry", Json.num sourceEntry),
    ("sourceBlockIndices", Json.arr
      (indices.map (fun (index : Nat) => Json.num index)).toArray)]

private def piJsonNatArray? (value : Json) (key : String) : Option (List Nat) := do
  let values ← oarr value key
  values.toList.mapM (fun item => (Json.getNat? item).toOption)

private def piHistoricalAssistantCoordinate? (rawEntry : Option Json)
    (block : Nat) : Option (Nat × Nat) := do
  let raw ← rawEntry
  let carrierKind ← piCarrierEntryKind? raw
  let value ← piCarrierValue? raw
  if carrierKind == "assistantMessage" then
    guard (ostr value "representation" == some "historical-assistant-blocks")
  else if carrierKind == "historicalPayload" then
    guard (ostr value "kind" == some "assistantMsg")
  else failure
  let sourceEntry ← onat value "sourceEntry"
  let sourceBlocks ← piJsonNatArray? value "sourceBlockIndices"
  let sourceBlock ← sourceBlocks[block]?
  pure (sourceEntry, sourceBlock)

private structure PiAssistantCoordinateAssignment where
  irEntry : Nat
  irBlock : Nat
  sourceEntry : Nat
  sourceBlock : Nat
  deriving DecidableEq

private abbrev PiAssistantCoordinatePlan := List PiAssistantCoordinateAssignment

private def piPlannedAssistantCoordinate? (plan : PiAssistantCoordinatePlan)
    (entry block : Nat) : Option (Nat × Nat) :=
  (plan.find? (fun assignment =>
    assignment.irEntry == entry && assignment.irBlock == block)).map
      (fun assignment => (assignment.sourceEntry, assignment.sourceBlock))

private def piAssistantCarrierValuePreserving (rawEntry : Option Json)
    (fallbackSourceEntry : Nat) (coordinates : List (Nat × Nat))
    (blocks : List AssistantBlock) : Json :=
  match rawEntry.bind piCarrierValue? with
  | some value =>
      if ostr value "representation" == some "historical-assistant-blocks" then
        let scope := (ostr value "scope").getD "full"
        let sourceEntry := coordinates.head?.map (fun coordinate => coordinate.1) |>.getD
          fallbackSourceEntry
        let sourceBlocks := coordinates.map (fun coordinate => coordinate.2)
        let current := piHistoricalAssistantCarrierValue
          scope sourceEntry blocks sourceBlocks
        match current with
        | .obj fields =>
            overlayJsonFields value
              ["blocks", "representation", "scope", "sourceEntry",
               "sourceBlockIndices"] fields.toList
        | _ => current
      else piAssistantCarrierValue blocks
  | none => piAssistantCarrierValue blocks

/-- Pi's native user content union is closed the same way the assistant one is:
plain text replays natively, while media and open-world blocks must travel
inert rather than being replayed into a target-native user turn. -/
private def piUserBlockIsContextSafe : UserBlock -> Bool
  | .text _ => true
  | _ => false

/-- Maximal runs of consecutive user blocks of one context-safety class — the
same contract `piAssistantBlockRuns` states, for the same reason: the exported
record order is the only block order a reader recovers, so the split must follow
run boundaries rather than block class. Positional references never address user
blocks, so a run carries its blocks without their source indices. -/
private def piUserBlockRuns : List UserBlock → List (Bool × List UserBlock)
  | [] => []
  | block :: rest =>
      let safe := piUserBlockIsContextSafe block
      match piUserBlockRuns rest with
      | (runSafe, items) :: later =>
          if runSafe == safe then (safe, block :: items) :: later
          else (safe, [block]) :: (runSafe, items) :: later
      | [] => [(safe, [block])]

private def piHistoricalCallRef
    (remap : Nat → Nat → Nat × Nat) : CallRef -> Json
  | .resolved entry block =>
      let physical := remap entry block
      Json.mkObj [
        ("kind", Json.str "resolved"), ("entry", Json.num physical.1),
        ("block", Json.num physical.2)]
  | .unresolved rawId note => Json.mkObj [
      ("kind", Json.str "unresolved"),
      ("rawId", piHistoricalOptionalString rawId), ("note", Json.str note)]

private def piHistoricalErrorSignal : ErrorSignal -> Json
  | .native value => Json.mkObj [
      ("kind", Json.str "native"), ("value", Json.bool value)]
  | .inferred value heuristic => Json.mkObj [
      ("kind", Json.str "inferred"), ("value", Json.bool value),
      ("heuristic", Json.str heuristic)]
  | .unrecorded => Json.mkObj [("kind", Json.str "unrecorded")]

private def piHistoricalEnvBlock
    (remap : Nat → Nat → Nat × Nat) : EnvBlock -> Json
  | .toolResult call content error => Json.mkObj [
      ("kind", Json.str "toolResult"),
      ("call", piHistoricalCallRef remap call),
      ("content", Json.arr (content.map piHistoricalUserBlock).toArray),
      ("error", piHistoricalErrorSignal error)]
  | .unmodeled label raw => Json.mkObj [
      ("kind", Json.str "unmodeled"), ("label", Json.str label), ("raw", raw)]

private def piHistoricalCoverage
    (remapEntry : Nat → Nat) : CompactionCoverage -> Json
  | .knownPrefix firstKept => Json.mkObj [
      ("kind", Json.str "knownPrefix"),
      ("firstKept", Json.num (remapEntry firstKept))]
  | .unknownPrefix => Json.mkObj [("kind", Json.str "unknownPrefix")]

private def piHistoricalMetaEvent : MetaEvent -> Json
  | .modelChange previous next => Json.mkObj [
      ("kind", Json.str "modelChange"),
      ("previous", piHistoricalOptionalString previous),
      ("next", piHistoricalOptionalString next)]
  | .thinkingLevelChange previous next => Json.mkObj [
      ("kind", Json.str "thinkingLevelChange"),
      ("previous", piHistoricalOptionalString previous),
      ("next", piHistoricalOptionalString next)]
  | .permissionMode mode => Json.mkObj [
      ("kind", Json.str "permissionMode"), ("mode", Json.str mode)]
  | .branchSummary summary => Json.mkObj [
      ("kind", Json.str "branchSummary"), ("summary", Json.str summary)]
  | .custom label raw => Json.mkObj [
      ("kind", Json.str "custom"), ("label", Json.str label), ("raw", raw)]

private def piHistoricalPayloadCarrierValue
    (remapCall : Nat → Nat → Nat × Nat)
    (remapEntry : Nat → Nat) (coordinatePlan : PiAssistantCoordinatePlan)
    (sourceEntry : Nat) : Payload -> Json
  | .userMsg blocks => Json.mkObj [
      ("kind", Json.str "userMsg"),
      ("blocks", Json.arr (blocks.map piHistoricalUserBlock).toArray)]
  | .assistantMsg blocks => Json.mkObj [
      ("kind", Json.str "assistantMsg"),
      ("blocks", Json.arr (blocks.map piHistoricalAssistantBlock).toArray),
      ("sourceEntry", Json.num (((piPlannedAssistantCoordinate?
        coordinatePlan sourceEntry 0).map (fun coordinate => coordinate.1)).getD
          (remapEntry sourceEntry))),
      ("sourceBlockIndices", Json.arr
        ((List.range blocks.length).map
          (fun (index : Nat) => Json.num
            (((piPlannedAssistantCoordinate? coordinatePlan sourceEntry index).map
              (fun coordinate => coordinate.2)).getD index))).toArray)]
  | .envMsg blocks => Json.mkObj [
      ("kind", Json.str "envMsg"),
      ("blocks", Json.arr (blocks.map (piHistoricalEnvBlock remapCall)).toArray)]
  | .otherMsg role blocks => Json.mkObj [
      ("kind", Json.str "otherMsg"), ("role", Json.str role),
      ("blocks", Json.arr (blocks.map piHistoricalUserBlock).toArray)]
  | .compaction summary coverage tokensBefore => Json.mkObj [
      ("kind", Json.str "compaction"), ("summary", Json.str summary),
      ("coverage", piHistoricalCoverage remapEntry coverage),
      ("tokensBefore", tokensBefore.map Json.num |>.getD Json.null)]
  | .event event => Json.mkObj [
      ("kind", Json.str "event"), ("event", piHistoricalMetaEvent event)]

private def piCallRefValue (coordinatePlan : PiAssistantCoordinatePlan) : CallRef → Json
  | .resolved entry block =>
      Json.mkObj (("state", Json.str "resolved") ::
        match piPlannedAssistantCoordinate? coordinatePlan entry block with
        | some coordinate => [
            ("sourceEntry", Json.num coordinate.1),
            ("sourceBlock", Json.num coordinate.2)]
        | none => [])
  | .unresolved rawId note => Json.mkObj
      (("state", Json.str "unresolved") :: ("note", Json.str note) ::
        (match rawId with
         | some id => [("rawId", Json.str id)]
         | none => [("rawId", Json.null)]))

private def piErrorSignalValue : ErrorSignal → Json
  | .native value => Json.mkObj [
      ("state", Json.str "native"), ("value", Json.bool value)]
  | .inferred value heuristic => Json.mkObj [
      ("state", Json.str "inferred"), ("value", Json.bool value),
      ("heuristic", Json.str heuristic)]
  | .unrecorded => Json.mkObj [("state", Json.str "unrecorded")]

private def piToolResultCarrierValue (t : Transcript)
    (coordinatePlan : PiAssistantCoordinatePlan)
    (rawEntry : Option Json) (call : CallRef)
    (content : List UserBlock) (error : ErrorSignal) : Json :=
  let priorValue := rawEntry.bind (fun raw =>
    if piCarrierEntryKind? raw == some "toolResult" then piCarrierValue? raw
    else none)
  let sourceEnvelope := match rawEntry with
    | some raw =>
        if piCarrierEntryKind? raw == some "toolResult" then
          priorValue.bind (fun value => oobj value "sourceEnvelope")
        else some raw
    | none => none
  let callId := piCallIdOfRef t call <|>
    (piRawMessage sourceEnvelope).bind (fun message => ostr message "toolCallId")
  let toolName := piToolNameOfRef t call <|>
    (piRawMessage sourceEnvelope).bind (fun message => ostr message "toolName") <|>
    priorValue.bind (fun value => ostr value "toolName")
  Json.mkObj ([
    ("call", piCallRefValue coordinatePlan call),
    ("toolCallId", match callId with
      | some id => Json.str id
      | none => Json.null),
    ("toolName", match toolName with
      | some name => Json.str name
      | none => Json.null),
    ("content", Json.arr
      (userBlocksToJsonPreserving sourceEnvelope content).toArray),
    ("error", piErrorSignalValue error)] ++
    (match sourceEnvelope with
     | some raw => [("sourceEnvelope", raw)]
     | none => []))

/-- A retained native Pi assistant message can replay this block without loss.
Pi models signed reasoning natively, so `thinking` qualifies here even though it
is not context-safe for a synthesized foreign turn; tool calls answer to the
same wire limit as everywhere else. -/
private def piAssistantBlockIsNativeRepresentable : AssistantBlock → Bool
  | .text _ | .thinking _ _ => true
  | .toolCall name arguments rawId =>
      piToolCallIsNativeRepresentable name arguments rawId
  | _ => false

private def piRawAssistantHasBlockCarrier (entry : Entry) : Bool :=
  (piRawContent (piRawEntry entry.origin)).any (fun blocks =>
    blocks.any (fun block => (block.getObjVal? piCarrierKey).toOption.isSome))

/-- A native Pi assistant message remains byte-stable while its IR is still
native-representable. If an edit introduces an unsafe call/block, the whole
message moves to a coordinate-bearing carrier so result refs cannot become
ambiguous after inert projection. Existing block-carrier messages retain their
original representation for exact same-format E-I-E. -/
private def piAssistantNeedsCarrierForCurrentIr (entry : Entry) : Bool :=
  (piRawMessage (piRawEntry entry.origin)).isSome &&
    !piRawAssistantHasBlockCarrier entry &&
    match entry.payload with
    | .assistantMsg blocks =>
        blocks.any (fun block => !piAssistantBlockIsNativeRepresentable block)
    | _ => false

private def piAssistantNeedsTargetProjection (t : Transcript) (e : Entry) : Bool :=
  e.disposition == EntryDisposition.native && piUsesTargetOptions t &&
    (piRawMessage (piRawEntry e.origin)).isNone

/-- Whether this entry's assistant tool calls reach the artifact as native Pi
`toolCall` blocks. Two shapes qualify:

* a retained native Pi message whose current IR is still representable, and
* a target-projected message rendered in context mode, which synthesizes a real
  `assistant` record per context-safe run.

Note what is *not* consulted: `origin.format`. Native emission is a question of
target capability plus structural validity, never of source provenance — gating
it on `origin.format == .pi` produced native output only when no conversion had
happened. `EntryDisposition.native` is the anti-laundering guard and it is
independent of `origin.format`, so it is the conjunct that carries that
property. Carrier mode is deliberately excluded: it asks for an inert
projection, and an inert projection has no executable calls. -/
private def piEntryEmitsNativeToolCalls (t : Transcript) (entry : Entry) : Bool :=
  entry.disposition == EntryDisposition.native &&
    (((piRawMessage (piRawEntry entry.origin)).isSome &&
        !piAssistantNeedsCarrierForCurrentIr entry) ||
      (piAssistantNeedsTargetProjection t entry &&
        piAssistantHistoryMode t == "context"))

/-- Per-block refinement of `piEntryEmitsNativeToolCalls`. Under context-mode
projection an entry can mix native calls with carrier-bound ones, so a result
reference must ask about its own call block, not merely its call entry. -/
private def piCallBlockIsNative (t : Transcript) (entryIdx blockIdx : Nat) : Bool :=
  (t.entries[entryIdx]?).any (fun entry =>
    piEntryEmitsNativeToolCalls t entry &&
      match entry.payload with
      | .assistantMsg blocks =>
          (blocks[blockIdx]?).any (fun block =>
            -- A retained native Pi message replays its blocks verbatim, so its
            -- calls are native whenever the message stayed native at all;
            -- reasoning rides along, which context projection cannot do.
            if (piRawMessage (piRawEntry entry.origin)).isSome then
              piAssistantBlockIsNativeRepresentable block
            else piAssistantBlockIsContextSafe (piAmbiguousToolCallIds t) block)
      | _ => false)

private def piCallDispositionIsNative (t : Transcript) : CallRef -> Bool
  | .resolved entry block => piCallBlockIsNative t entry block
  | .unresolved _ _ => true

/-- Pi has one `toolCallId`/`isError` pair per tool-result message. An IR
`envMsg` may contain several results, so each block is emitted independently. -/
private def envBlockJson (t : Transcript)
    (coordinatePlan : PiAssistantCoordinatePlan)
    (rawEntry : Option Json) (base : List (String × Json))
    (entryTimestamp : String) : EnvBlock → Json
  | .toolResult call content error =>
      let sourceMessage := piRawMessage rawEntry
      let callId := nonemptyString (piCallIdOfRef t call <|>
        sourceMessage.bind (fun message => ostr message "toolCallId"))
      let toolName := nonemptyString (piToolNameOfRef t call <|>
        sourceMessage.bind (fun message => ostr message "toolName"))
      let nativeCall := (match call with
        | .resolved _ _ => true
        | .unresolved _ _ => false) &&
          piCallDispositionIsNative t call && callId.isSome && toolName.isSome
      -- `ErrorSignal` epistemics do not gate native emission. Pi's wire slot is
      -- a plain `isError` bool, and `piErrorExport` already writes the exact
      -- provenance (`native`/`inferred`+heuristic/`unrecorded`) out of band into
      -- the reserved `toolError` stamp, which `piToolErrorSignal` reads back
      -- verbatim. Requiring `.native` here forced every Codex-sourced result to
      -- prose, because the Codex importer never produces `.native`.
      let existingCarrier := rawEntry.bind piCarrierEntryKind? == some "toolResult"
      if existingCarrier || !nativeCall then
        piCustomCarrierEntryPreserving rawEntry base "toolResult"
          (piToolResultCarrierValue t coordinatePlan rawEntry call content error)
      else
      let (isError, errorCarrier) := piErrorExport error
      let messageFields : List (String × Json) := [
        ("toolCallId", Json.str (callId.getD piSentinel)),
        ("toolName", Json.str (toolName.getD piSentinel)),
        ("isError", Json.bool isError)]
      messageJson t rawEntry base "toolResult"
        (Json.arr (userBlocksToJsonPreserving rawEntry content).toArray)
        entryTimestamp messageFields
        (piCallRefCarrier call ++ errorCarrier) ["toolCallRef", "toolError"]
  | .unmodeled label raw =>
      piCustomCarrierEntryPreserving rawEntry base "envBlock" <| Json.mkObj [
        ("label", Json.str label), ("raw", raw)]

private def jsonDisplayString (j : Json) : String :=
  match Json.getStr? j with
  | .ok s => s
  | .error _ => j.compress

private def metaEventJson (t : Transcript) (origin : Origin)
    (base : List (String × Json)) : MetaEvent → Json
  | .modelChange previous modelId =>
      let carrierValue := Json.mkObj
        ((match previous with
          | some value => [("previous", Json.str value)]
          | none => [("previous", Json.null)]) ++
         (match modelId with
          | some value => [("next", Json.str value)]
          | none => [("next", Json.null)]))
      match piRawEntry origin with
      | some raw =>
          if piCarrierEntryKind? raw == some "modelChange" then
            piCustomCarrierEntryPreserving (some raw) base "modelChange"
              carrierValue
          else
            match nonemptyString modelId,
                targetProvider t <|> nonemptyString t.env.provider <|>
                  nonemptyString (ostr raw "provider") with
            | some model, some provider =>
                overlayJsonFields raw
                  ["id", "parentId", "timestamp", piCarrierKey, "type",
                   "provider", "modelId", "previousModelId"]
                  (base ++ [("type", Json.str "model_change"),
                    ("provider", Json.str provider), ("modelId", Json.str model)] ++
                    (match previous with
                     | some value => [("previousModelId", Json.str value)]
                     | none => []))
            | _, _ => piCustomCarrierEntry base "modelChange" carrierValue
      | none =>
          let targetPair := match targetProvider t, targetModel t with
            | some provider, some model => some (provider, model)
            | _, _ => none
          let nativeSourcePair :=
            if piSourceNative t && origin.format == Format.pi then
              match nonemptyString t.env.provider, nonemptyString t.env.model with
              | some provider, some model => some (provider, model)
              | _, _ => none
            else none
          match nonemptyString modelId, targetPair <|> nativeSourcePair with
          | some model, some (provider, pairedModel) =>
              if model != pairedModel then
                piCustomCarrierEntry base "modelChange" carrierValue
              else
              Json.mkObj (base ++ [("type", Json.str "model_change"),
                ("provider", Json.str provider), ("modelId", Json.str model)] ++
                (match previous with
                 | some value => [("previousModelId", Json.str value)]
                 | none => []))
          | _, _ =>
              piCustomCarrierEntry base "modelChange" carrierValue
  | .thinkingLevelChange previous level =>
      let carrierValue := Json.mkObj
        ((match previous with
          | some value => [("previous", Json.str value)]
          | none => [("previous", Json.null)]) ++
         (match level with
          | some value => [("next", Json.str value)]
          | none => [("next", Json.null)]))
      match piRawEntry origin with
      | some raw =>
          if piCarrierEntryKind? raw == some "thinkingLevelChange" then
            piCustomCarrierEntryPreserving (some raw) base
              "thinkingLevelChange" carrierValue
          else
            match nonemptyString level with
            | some value =>
                overlayJsonFields raw
                  ["id", "parentId", "timestamp", piCarrierKey, "type",
                   "thinkingLevel", "previousThinkingLevel"]
                  (base ++ [("type", Json.str "thinking_level_change"),
                    ("thinkingLevel", Json.str value)] ++
                    (match previous with
                     | some prior => [("previousThinkingLevel", Json.str prior)]
                     | none => []))
            | none => piCustomCarrierEntry base "thinkingLevelChange" carrierValue
      | none =>
          match nonemptyString level with
          | some value =>
              Json.mkObj (base ++ [("type", Json.str "thinking_level_change"),
                ("thinkingLevel", Json.str value)] ++
                (match previous with
                 | some prior => [("previousThinkingLevel", Json.str prior)]
                 | none => []))
          | none =>
              piCustomCarrierEntry base "thinkingLevelChange" carrierValue
  | .branchSummary summary =>
      match piRawEntry origin with
      | some raw =>
          if piCarrierEntryKind? raw == some "branchSummary" then
            piCustomCarrierEntryPreserving (some raw) base "branchSummary"
              (Json.str summary)
          else
            overlayJsonFields raw
              ["id", "parentId", "timestamp", piCarrierKey, "type", "summary"]
              (base ++ [("type", Json.str "branch_summary"),
                ("summary", Json.str summary)])
      | none => piCustomCarrierEntry base "branchSummary" (Json.str summary)
  | .custom label raw =>
      match piRawEntry origin with
      | some source =>
          if piCarrierEntryKind? source == some "event" then
            piCustomCarrierEntryPreserving (some source) base "event" <|
              Json.mkObj [("label", Json.str label), ("raw", raw)]
          else if ostr raw "type" == some label then
            overlayJsonFields raw
              ["id", "parentId", "timestamp", piCarrierKey, "type"]
              (base ++ [("type", Json.str label)])
          else
            piCustomCarrierEntry base "event" <| Json.mkObj [
              ("label", Json.str label), ("raw", raw)]
      | none => piCustomCarrierEntry base "event" <| Json.mkObj [
          ("label", Json.str label), ("raw", raw)]
  | .permissionMode mode =>
      match piRawEntry origin with
      | some raw =>
          if piCarrierEntryKind? raw == some "permissionMode" then
            piCustomCarrierEntryPreserving (some raw) base "permissionMode"
              (Json.str mode)
          else piCustomCarrierEntryOverRaw raw base "permissionMode"
            (Json.str mode)
      | none => piCustomCarrierEntry base "permissionMode" (Json.str mode)

private def piExistingHistoricalCarrierMatches
    (rawEntry : Option Json) (payload : Payload) : Bool :=
  match rawEntry.bind piCarrierEntryKind?, payload with
  | some "branchSummary", .event (.branchSummary _)
  | some "permissionMode", .event (.permissionMode _)
  | some "event", .event (.custom _ _)
  | some "modelChange", .event (.modelChange _ _)
  | some "thinkingLevelChange", .event (.thinkingLevelChange _ _)
  | some "compaction", .compaction _ _ _
  | some "assistantMessage", .assistantMsg _
  | some "toolResult", .envMsg [.toolResult _ _ _]
  | some "emptyEnv", .envMsg []
  | some "envBlock", .envMsg [.unmodeled _ _] => true
  | _, .otherMsg _ _ =>
      rawEntry.any (fun raw =>
        ostr raw "type" == some "custom_message" &&
          ostr raw "customType" == some "loom.pi.other-message")
  | _, _ => false

private def piUsesGenericHistoricalPayload (e : Entry) : Bool :=
  e.disposition == EntryDisposition.historicalUnverified &&
    !piExistingHistoricalCarrierMatches (piRawEntry e.origin) e.payload

private def piUserNeedsTargetProjection (t : Transcript) (e : Entry) : Bool :=
  e.disposition == EntryDisposition.native && piUsesTargetOptions t &&
    (piRawMessage (piRawEntry e.origin)).isNone

/-- Context mode emits one physical record per safety run, so a message that
interleaves text with reasoning or calls expands past the historical two. An
empty message still occupies exactly one record: entries never vanish. -/
private def piAssistantPhysicalRecordCount
    (t : Transcript) (e : Entry) (blocks : List AssistantBlock) : Nat :=
  if piAssistantNeedsTargetProjection t e && piAssistantHistoryMode t == "context" then
    max 1 (piAssistantBlockRuns (piAmbiguousToolCallIds t) blocks).length
  else 1

/-- The user-side counterpart. A target-projected user message expands to one
record per safety run; anything else stays a single record. -/
private def piUserPhysicalRecordCount
    (t : Transcript) (e : Entry) (blocks : List UserBlock) : Nat :=
  if piUserNeedsTargetProjection t e then max 1 (piUserBlockRuns blocks).length
  else 1

private def piPreferredEntryIds (t : Transcript) (i : Nat) (e : Entry) : List String :=
  let id := e.origin.rawId.getD s!"e{i}"
  if piUsesGenericHistoricalPayload e then [id]
  else
  match e.payload with
  | .envMsg blocks =>
      if blocks.length <= 1 then [id]
      else blocks.zipIdx.map (fun (_, blockIdx) =>
        if blockIdx == 0 then id else s!"{id}#r{blockIdx}")
  | .userMsg blocks =>
      let records := piUserPhysicalRecordCount t e blocks
      if records <= 1 then [id]
      else (List.range records).map (fun record =>
        if record == 0 then id else s!"{id}#run{record}")
  | .assistantMsg blocks =>
      let records := piAssistantPhysicalRecordCount t e blocks
      if records <= 1 then [id]
      else (List.range records).map (fun record =>
        if record == 0 then id else s!"{id}#run{record}")
  | _ => [id]

private def freshPiEntryId (preferred : String) (used : List String) : String :=
  let candidate := fun suffix =>
    if suffix == 0 then preferred else s!"{preferred}#loom{suffix}"
  ((List.range (used.length + 1)).find? (fun suffix =>
      !used.contains (candidate suffix))).map candidate |>.getD
    s!"{preferred}#loom{used.length + 1}"

/-- Allocate every physical Pi record ID in one pass. This includes records
created by expanding a multi-result entry, so raw IDs, fallback IDs, and
generated result suffixes all share one collision domain. -/
private def piEntryIdPlan (t : Transcript) : List (List String) := Id.run do
  let mut used : List String := []
  let mut plan : Array (List String) := #[]
  for (entry, entryIdx) in t.entries.toList.zipIdx do
    let mut ids : Array String := #[]
    for preferred in piPreferredEntryIds t entryIdx entry do
      let id := freshPiEntryId preferred used
      used := used ++ [id]
      ids := ids.push id
    plan := plan.push ids.toList
  return plan.toList

private def piEntryIds (idPlan : List (List String)) (i : Nat) : List String :=
  (idPlan[i]?).getD [s!"e{i}"]

private def piEntryFirstId (idPlan : List (List String)) (i : Nat) : String :=
  (piEntryIds idPlan i).head?.getD s!"e{i}"

private def piEntryLastId (idPlan : List (List String)) (i : Nat) : String :=
  (piEntryIds idPlan i).getLast?.getD s!"e{i}"

/-- Put the selected active leaf last. Pi 0.74.0 rebuilds its in-memory leaf
pointer by assigning each physical record in order, so file order is the only
persisted active-path signal. -/
private def piExportOrder (t : Transcript) : List Nat :=
  let indices := List.range t.entries.size
  match t.activeLeaf with
  | some active => indices.filter (fun index => index != active) ++ [active]
  | none => indices

private def piPhysicalEntryStart (t : Transcript)
    (idPlan : List (List String)) (sourceEntry : Nat) : Nat :=
  let order := piExportOrder t
  if !order.contains sourceEntry then sourceEntry
  else
    (order.takeWhile (fun entry => entry != sourceEntry)).foldl
      (fun offset entry => offset + (piEntryIds idPlan entry).length) 0

/-- Physical Pi coordinates of one source assistant block. Under context-mode
run splitting a block's record is the run that contains it and its block index
is its offset inside that run, so this stays a total function of the same run
decomposition the exporter emits. -/
private def piPhysicalAssistantOccurrence (t : Transcript)
    (idPlan : List (List String)) (sourceEntry sourceBlock : Nat) : Nat × Nat :=
  let physicalEntry := piPhysicalEntryStart t idPlan sourceEntry
  match t.entries[sourceEntry]? with
  | some entry =>
      match entry.payload with
      | .assistantMsg blocks =>
          if piAssistantNeedsTargetProjection t entry &&
              piAssistantHistoryMode t == "context" then
            ((piAssistantBlockRuns (piAmbiguousToolCallIds t) blocks).zipIdx.findSome?
              (fun (run, runIdx) =>
              (run.2.zipIdx.find? (fun item => item.1.1 == sourceBlock)).map
                (fun item => (physicalEntry + runIdx, item.2)))).getD
              (physicalEntry, sourceBlock)
          else (physicalEntry, sourceBlock)
      | _ => (physicalEntry, sourceBlock)
  | none => (sourceEntry, sourceBlock)

private structure PiAssistantCoordinateGroup where
  irEntry : Nat
  irBlocks : List Nat
  preferred : Option (List (Nat × Nat))
  fallback : List (Nat × Nat)

/-- Only assistant blocks serialized with historical source metadata participate
in this namespace. Native Pi messages have no matching source metadata, so a
result that addresses one must continue to use ordinary ID/ancestry resolution. -/
private def piAssistantCoordinateBlocks
    (t : Transcript) (e : Entry) : List Nat :=
  match e.payload with
  | .assistantMsg blocks =>
      if piUsesGenericHistoricalPayload e then List.range blocks.length
      else if (piRawEntry e.origin).bind piCarrierEntryKind? ==
          some "assistantMessage" then
        if ((piRawEntry e.origin).bind piCarrierValue?).bind
            (fun value => ostr value "representation") ==
            some "historical-assistant-blocks" then
          List.range blocks.length
        else []
      else if (piRawMessage (piRawEntry e.origin)).isSome then
        if piAssistantNeedsCarrierForCurrentIr e then List.range blocks.length
        else []
      else if piAssistantNeedsTargetProjection t e &&
          piAssistantHistoryMode t == "context" then
        blocks.zipIdx.filterMap (fun (block, blockIdx) =>
          if piAssistantBlockIsContextSafe (piAmbiguousToolCallIds t) block then none
          else some blockIdx)
      else List.range blocks.length
  | _ => []

private def piCoordinateListIsUsable (used : List (Nat × Nat))
    (coordinates : List (Nat × Nat)) : Bool :=
  coordinates.eraseDups.length == coordinates.length &&
    !coordinates.any used.contains

private def piAssistantCoordinateGroups (t : Transcript)
    (idPlan : List (List String)) : List PiAssistantCoordinateGroup :=
  t.entries.toList.zipIdx.filterMap (fun (entry, entryIdx) =>
    let irBlocks := piAssistantCoordinateBlocks t entry
    if irBlocks.isEmpty then none
    else
      let preferred := irBlocks.mapM
        (piHistoricalAssistantCoordinate? (piRawEntry entry.origin))
      let preferred := preferred.bind (fun coordinates =>
        match coordinates.head? with
        | some first =>
            if coordinates.all (fun coordinate => coordinate.1 == first.1) &&
                coordinates.eraseDups.length == coordinates.length then
              some coordinates
            else none
        | none => none)
      let sourceEntry := piPhysicalEntryStart t idPlan entryIdx
      let fallback := irBlocks.map (fun block => (sourceEntry, block))
      some { irEntry := entryIdx, irBlocks, preferred, fallback })

/-- Allocate one collision-free source-coordinate namespace for every assistant
carrier and every result reference. Existing coordinates are considered first,
which gives unchanged valid artifacts exact E-I-E; newly generated physical
coordinates are second, and a deterministic fresh source entry is the final
fallback when active-leaf ordering makes either collide. -/
private def piAssistantCoordinatePlan (t : Transcript)
    (idPlan : List (List String)) : PiAssistantCoordinatePlan := Id.run do
  let groups := piAssistantCoordinateGroups t idPlan
  let ordered := groups.filter (fun group => group.preferred.isSome) ++
    groups.filter (fun group => group.preferred.isNone)
  let reservedEntries := groups.flatMap (fun group =>
    group.fallback.map (fun coordinate => coordinate.1) ++
      (group.preferred.map (fun coordinates =>
        coordinates.map (fun coordinate => coordinate.1))).getD [])
  let mut used : List (Nat × Nat) := []
  let mut plan : Array PiAssistantCoordinateAssignment := #[]
  for group in ordered do
    let candidates := group.preferred.toList ++ [group.fallback]
    let coordinates := match candidates.find? (piCoordinateListIsUsable used) with
      | some available => available
      | none =>
          let occupied := reservedEntries ++ used.map (fun coordinate => coordinate.1)
          let fresh := ((List.range (occupied.length + 1)).find?
            (fun candidate => !occupied.contains candidate)).getD
              (occupied.length + 1)
          (List.range group.irBlocks.length).map (fun block => (fresh, block))
    for (irBlock, coordinate) in group.irBlocks.zip coordinates do
      plan := plan.push {
        irEntry := group.irEntry, irBlock,
        sourceEntry := coordinate.1, sourceBlock := coordinate.2 }
    used := used ++ coordinates
  return plan.toList

private def piTimeCarrier (rawEntry : Option Json) (time : Time) : List (String × Json) :=
  let extras := match rawEntry.bind (fun raw => oobj raw piCarrierKey) with
    | some (.obj fields) =>
        ((fields.erase "version").erase "time").toList
    | _ => []
  let timeField := match time with
    | .recorded _ => []
    | .interpolated timestamp basis => [("time", Json.mkObj [
        ("state", Json.str "interpolated"),
        ("ms", Json.num timestamp.ms), ("basis", Json.str basis)])]
    | .sequenced ordinal => [("time", Json.mkObj [
        ("state", Json.str "sequenced"), ("ordinal", Json.num ordinal)])]
    | .absent => [("time", Json.mkObj [("state", Json.str "absent")])]
  if extras.isEmpty && timeField.isEmpty then []
  else [(piCarrierKey, Json.mkObj
    (("version", Json.num piCarrierVersion) :: extras ++ timeField))]

private def piBaseFields (rawEntry : Option Json) (id : String) (parentId : Option String)
    (timestamp : String) (time : Time) : List (String × Json) :=
  [("id", Json.str id),
   ("parentId", match parentId with | some parent => Json.str parent | none => Json.null),
   ("timestamp", Json.str timestamp)] ++ piTimeCarrier rawEntry time

private def piEntryTimestamp? (t : Transcript) (e : Entry) : Option String :=
  let rawTimestamp := e.origin.extras.bind (fun extras => ostr extras "ts")
  match e.time with
  | .recorded timestamp | .interpolated timestamp _ =>
      match rawTimestamp with
      | some raw =>
          if iso8601ToEpochMs? raw == some timestamp then some raw
          else some (epochMsToIso8601 timestamp)
      | none => some (epochMsToIso8601 timestamp)
  | .sequenced _ | .absent => rawTimestamp <|> targetTimestamp t

private def piEntryTimestamp (t : Transcript) (e : Entry) : String :=
  (piEntryTimestamp? t e).getD piPlaceholderTimestamp

private def piStructuredOtherMessageJson (rawEntry : Json)
    (base : List (String × Json)) (role : String) (current : Json)
    (entryTimestamp : String) : Json :=
  let timestamp := piMessageTimestamp (some rawEntry) entryTimestamp
  let message := overlayJsonFields current ["role", "timestamp"] [
    ("role", Json.str role), ("timestamp", Json.num timestamp)]
  overlayJsonFields rawEntry
    ["id", "parentId", "timestamp", piCarrierKey, "type", "message"]
    (base ++ [("type", Json.str "message"), ("message", message)])

private def piOtherMessageCarrierJson (rawEntry : Option Json)
    (base : List (String × Json)) (role : String) (blocks : List UserBlock) : Json :=
  let rawDetails := rawEntry.bind (fun raw => oobj raw "details")
  let rawBlocks := rawDetails.bind (fun details => oarr details "blocks")
  let currentBlocks := blocks.zipIdx.map (fun (block, blockIdx) =>
    userBlockToJsonPreserving (rawBlocks.bind (fun values => values[blockIdx]?)) block)
  let detailsFields := [
    ("version", Json.num piCarrierVersion), ("role", Json.str role),
    ("blocks", Json.arr currentBlocks.toArray)]
  let details := match rawDetails with
    | some raw =>
        overlayJsonFields raw ["version", "role", "blocks"] detailsFields
    | none => Json.mkObj detailsFields
  let fields := base ++ [
    ("type", Json.str "custom_message"),
    ("customType", Json.str "loom.pi.other-message"),
    ("content", Json.str ""), ("display", Json.bool false),
    ("details", details)]
  match rawEntry with
  | some raw =>
      overlayJsonFields raw
        ["id", "parentId", "timestamp", piCarrierKey, "details"]
        (base ++ [("details", details)])
  | none => Json.mkObj fields

private def piNativeCustomMessageJson (rawEntry : Json)
    (base : List (String × Json)) (blocks : List UserBlock) : Json :=
  let rawContent := (rawEntry.getObjVal? "content").toOption
  let rawBlocks := rawContent.bind (fun
    | .arr values => some values
    | _ => none)
  let content := match blocks, rawContent with
    | [.text text], some (.str _) => Json.str text
    | _, _ => Json.arr (blocks.zipIdx.map (fun (block, blockIdx) =>
        userBlockToJsonPreserving
          (rawBlocks.bind (fun values => values[blockIdx]?)) block)).toArray
  overlayJsonFields rawEntry
    ["id", "parentId", "timestamp", piCarrierKey, "content"]
    (base ++ [("content", content)])

/-- One IR entry can expand to several Pi records: a multi-result `envMsg`, a
user message whose unsafe blocks need a carrier, and a context-mode assistant
message split into one record per safety run. Expanded records always chain in
source block order, and children point at the last record, so Pi's active-path
walk both retains every record and replays them in the source's own order. -/
private def entryToJsonLinesWithPlan (t : Transcript) (idPlan : List (List String))
    (coordinatePlan : PiAssistantCoordinatePlan) (i : Nat) (e : Entry) : List Json :=
  let ids := piEntryIds idPlan i
  let parentId := e.parent.map (piEntryLastId idPlan)
  let ts := piEntryTimestamp t e
  let rawEntry := piRawEntry e.origin
  let firstBase := piBaseFields rawEntry (ids.head?.getD s!"e{i}") parentId ts e.time
  let remapEntry := piPhysicalEntryStart t idPlan
  let remapCall := piPhysicalAssistantOccurrence t idPlan
  let ambiguousCallIds := piAmbiguousToolCallIds t
  if piUsesGenericHistoricalPayload e then
    [piCustomCarrierEntryPreserving rawEntry firstBase "historicalPayload"
      (piHistoricalPayloadCarrierValue remapCall remapEntry coordinatePlan i e.payload)]
  else
  match e.payload with
  | .userMsg blocks =>
      if (piRawMessage rawEntry).isSome then
        [messageJson t rawEntry firstBase "user"
          (userContentToJson rawEntry blocks) ts]
      else if piUserNeedsTargetProjection t e then
        match piUserBlockRuns blocks with
        | [] =>
            [piCustomCarrierEntry firstBase "historicalPayload"
              (piHistoricalPayloadCarrierValue remapCall remapEntry coordinatePlan i
                (.userMsg blocks))]
        | runs =>
            runs.zipIdx.map (fun (run, runIdx) =>
              let recordId := (ids[runIdx]?).getD s!"e{i}#run{runIdx}"
              let recordParent := if runIdx == 0 then parentId else ids[runIdx - 1]?
              let recordBase := piBaseFields none recordId recordParent ts e.time
              if run.1 then
                messageJson t none recordBase "user"
                  (userContentToJson none run.2) ts
              else
                piCustomCarrierEntry recordBase "historicalPayload"
                  (piHistoricalPayloadCarrierValue remapCall remapEntry coordinatePlan i
                    (.userMsg run.2)))
      else
        [piCustomCarrierEntryPreserving rawEntry firstBase "historicalPayload"
          (piHistoricalPayloadCarrierValue remapCall remapEntry coordinatePlan i
            (.userMsg blocks))]
  | .assistantMsg blocks =>
      if rawEntry.bind piCarrierEntryKind? == some "assistantMessage" then
        let coordinates := (List.range blocks.length).map (fun block =>
          (piPlannedAssistantCoordinate? coordinatePlan i block).getD
            (remapEntry i, block))
        [piCustomCarrierEntryPreserving rawEntry firstBase "assistantMessage"
          (piAssistantCarrierValuePreserving rawEntry (remapEntry i)
            coordinates blocks)]
      else if (piRawMessage rawEntry).isSome then
        if piAssistantNeedsCarrierForCurrentIr e then
          let coordinates := (List.range blocks.length).map (fun block =>
            (piPlannedAssistantCoordinate? coordinatePlan i block).getD
              (remapEntry i, block))
          let sourceEntry := coordinates.head?.map
            (fun coordinate => coordinate.1) |>.getD (remapEntry i)
          let current := piHistoricalAssistantCarrierValue "full" sourceEntry
            blocks (coordinates.map (fun coordinate => coordinate.2))
          let value := match rawEntry with
            | some source =>
                overlayJsonFields current [] [("sourceEnvelope", source)]
            | none => current
          [piCustomCarrierEntry firstBase "assistantMessage" value]
        else
          -- Blocks map 1:1 onto emitted content here, so IR index == artifact
          -- index and the stamp needs no remapping. `carrierKeys` also names
          -- `toolCanonical` when the retained raw message already stamped one,
          -- so a canonical identity edited out of the IR is erased rather than
          -- replayed stale from the source bytes.
          let canonicalCarrier := piToolCanonicalCarrier blocks
          let rawStampedCanonical := ((piRawMessage rawEntry).bind
            (fun message => oobj message piCarrierKey)).bind
              (fun stamp => oobj stamp "toolCanonical")
          [messageJson t rawEntry firstBase "assistant"
            (Json.arr (assistantBlocksToJsonPreserving rawEntry blocks).toArray)
            ts [] canonicalCarrier
            (if canonicalCarrier.isEmpty && rawStampedCanonical.isNone then []
             else ["toolCanonical"])]
      else if piAssistantNeedsTargetProjection t e then
        if piAssistantHistoryMode t == "context" then
          match piAssistantBlockRuns ambiguousCallIds blocks with
          | [] => [piSynthesizedAssistantJson t ambiguousCallIds firstBase blocks ts]
          | runs =>
              runs.zipIdx.map (fun (run, runIdx) =>
                let recordId := (ids[runIdx]?).getD s!"e{i}#run{runIdx}"
                let recordParent := if runIdx == 0 then parentId else ids[runIdx - 1]?
                let recordBase := piBaseFields none recordId recordParent ts e.time
                if run.1 then
                  piSynthesizedAssistantJson t ambiguousCallIds recordBase
                    (piRunBlocks run.2) ts
                else
                  let coordinates := piRunSourceIndices run.2 |>.map (fun block =>
                    (piPlannedAssistantCoordinate? coordinatePlan i block).getD
                      (remapEntry i, block))
                  let sourceEntry := coordinates.head?.map
                    (fun coordinate => coordinate.1) |>.getD (remapEntry i)
                  piCustomCarrierEntry recordBase "assistantMessage"
                    (piHistoricalAssistantCarrierValue "unsafe" sourceEntry
                      (piRunBlocks run.2)
                      (coordinates.map (fun coordinate => coordinate.2))))
        else
          let coordinates := (List.range blocks.length).map (fun block =>
            (piPlannedAssistantCoordinate? coordinatePlan i block).getD
              (remapEntry i, block))
          let sourceEntry := coordinates.head?.map
            (fun coordinate => coordinate.1) |>.getD (remapEntry i)
          [piCustomCarrierEntry firstBase "assistantMessage"
            (piHistoricalAssistantCarrierValue "full" sourceEntry blocks
              (coordinates.map (fun coordinate => coordinate.2)))]
      else
        let coordinates := (List.range blocks.length).map (fun block =>
          (piPlannedAssistantCoordinate? coordinatePlan i block).getD
            (remapEntry i, block))
        let sourceEntry := coordinates.head?.map
          (fun coordinate => coordinate.1) |>.getD (remapEntry i)
        [piCustomCarrierEntryPreserving rawEntry firstBase "assistantMessage"
          (piHistoricalAssistantCarrierValue "full" sourceEntry blocks
            (coordinates.map (fun coordinate => coordinate.2)))]
  | .envMsg [] =>
      [piCustomCarrierEntryPreserving rawEntry firstBase "emptyEnv" Json.null]
  | .envMsg blocks =>
      blocks.zipIdx.map (fun (block, blockIdx) =>
        let id := (ids[blockIdx]?).getD s!"e{i}#r{blockIdx}"
        let lineParent := if blockIdx == 0 then parentId else ids[blockIdx - 1]?
        let blockRaw := if blockIdx == 0 then rawEntry else none
        envBlockJson t coordinatePlan blockRaw
          (piBaseFields blockRaw id lineParent ts e.time) ts block)
  | .otherMsg role blocks =>
      match rawEntry, piRawMessage rawEntry with
      | some raw, some _message =>
          match blocks with
          | [.unmodeled _ current] =>
              [piStructuredOtherMessageJson raw firstBase role current ts]
          | _ =>
              [messageJson t (some raw) firstBase role
                (userContentToJson (some raw) blocks) ts]
      | some raw, none =>
          if ostr raw "type" == some "custom_message" &&
              ostr raw "customType" == some "loom.pi.other-message" then
            [piOtherMessageCarrierJson (some raw) firstBase role blocks]
          else if ostr raw "type" == some "custom_message" && role == "custom" then
            [piNativeCustomMessageJson raw firstBase blocks]
          else
            [piOtherMessageCarrierJson none firstBase role blocks]
      | none, _ =>
          [piOtherMessageCarrierJson none firstBase role blocks]
  | .compaction summary coverage tokensBefore =>
      let carrierValue := Json.mkObj
        ([("summary", Json.str summary)] ++
         (match coverage with
          | .knownPrefix firstKept => [("firstKeptEntryId",
              Json.str (piEntryFirstId idPlan firstKept))]
          | .unknownPrefix => [("firstKeptEntryId", Json.null)]) ++
         (match tokensBefore with
          | some tokens => [("tokensBefore", Json.num tokens)]
          | none => [("tokensBefore", Json.null)]))
      match rawEntry with
      | some raw =>
          if piCarrierEntryKind? raw == some "compaction" then
            [piCustomCarrierEntryPreserving (some raw) firstBase "compaction"
              carrierValue]
          else
            match coverage, tokensBefore with
            | .knownPrefix firstKept, some tokens =>
                [overlayJsonFields raw
                  ["id", "parentId", "timestamp", piCarrierKey, "type",
                   "summary", "firstKeptEntryId", "tokensBefore"]
                  (firstBase ++ [("type", Json.str "compaction"),
                    ("summary", Json.str summary),
                    ("firstKeptEntryId", Json.str
                      (piEntryFirstId idPlan firstKept)),
                    ("tokensBefore", Json.num tokens)])]
            | _, _ => [piCustomCarrierEntry firstBase "compaction" carrierValue]
      | none =>
          match coverage, tokensBefore with
          | .knownPrefix firstKept, some tokens => [Json.mkObj (firstBase ++ [
              ("type", Json.str "compaction"), ("summary", Json.str summary),
              ("firstKeptEntryId", Json.str (piEntryFirstId idPlan firstKept)),
              ("tokensBefore", Json.num tokens)])]
          | _, _ => [piCustomCarrierEntry firstBase "compaction" carrierValue]
  | .event event =>
      [metaEventJson t e.origin firstBase event]

def entryToJsonLines (t : Transcript) (i : Nat) (e : Entry) : List Json :=
  let idPlan := piEntryIdPlan t
  entryToJsonLinesWithPlan t idPlan (piAssistantCoordinatePlan t idPlan) i e

/-- Compatibility projection for callers expecting one JSON object. Export uses
`entryToJsonLines`, which is lossless for multi-result environment messages. -/
def entryToJson (t : Transcript) (i : Nat) (e : Entry) : Json :=
  (entryToJsonLines t i e).head?.getD Json.null

def headerToJson (t : Transcript) : Json :=
  let id := (piSessionId t).getD "session"
  let timestamp := (piHeaderTimestamp t).getD piPlaceholderTimestamp
  let cwd := (piCwd t).getD ""
  let targetOptionProvenance := Json.mkObj [
    ("target_session_id", Json.str "origin-target-option"),
    ("target_cwd", Json.str "origin-target-option"),
    ("target_provider", Json.str "origin-target-option"),
    ("target_model", Json.str "origin-target-option"),
    ("target_harness_version", Json.str "origin-target-option"),
    ("target_timestamp", Json.str "origin-target-option"),
    ("pi_assistant_history", Json.mkObj [
      ("value", Json.str (piAssistantHistoryMode t)),
      ("provenance", Json.str <|
        if (transcriptStringExtra t "pi_assistant_history").isSome then
          "origin-target-option"
        else "target-default")])]
  let carrier :=
    (if (targetSessionId t).isSome then
      [("sessionId", Json.str "target-option")] else []) ++
    (if (targetCwd t).isSome then
      [("cwd", Json.str "target-option")] else []) ++
    (if (targetTimestamp t).isSome then
      [("timestamp", Json.str "target-option")] else []) ++
    (if piUsesTargetOptions t then [
      ("targetHarnessVersion", Json.str
        ((targetHarnessVersion t).getD piTargetVersion)),
      ("targetOptions", targetOptionProvenance),
      ("sourceEnvironment", piSourceEnvironmentJson
        (piSourceEnvironmentForHeader t))]
    else [])
  let fields := [("type", Json.str "session"), ("id", Json.str id),
      ("timestamp", Json.str timestamp), ("cwd", Json.str cwd),
      ("version", Json.num 3)] ++
    (if carrier.isEmpty then [] else [(piCarrierKey, piStampedObject carrier)])
  match piRawEntry t.origin with
  | some raw =>
      overlayJsonFields raw ["type", "id", "timestamp", "cwd", "version"] fields
  | none => Json.mkObj fields

/-- True exactly when the strict target-option path emits a complete, decodable
source `EnvInfo` archive in Pi's ignored session-header extension. -/
def piTargetPreservesSourceEnvironment (t : Transcript) : Bool :=
  piUsesTargetOptions t &&
    (piSourceEnvironmentJsonFromHeader? (headerToJson t)).bind
      piDecodeSourceEnvironment == some (piSourceEnvironmentForHeader t)

private def piTargetModelChangeStamp? (raw : Json) : Option Json := do
  let stamp ← oobj raw piCarrierKey
  guard (onat stamp "version" == some piCarrierVersion)
  oobj stamp "targetModelChange"

private def piActiveHasTargetModelChange (t : Transcript) : Bool :=
  (t.activeLeaf.bind (fun active => t.entries[active]?)).any (fun entry =>
    match entry.payload, targetProvider t, targetModel t with
    | .event (.modelChange _ (some model)), some provider, some target =>
        model == target &&
          (piRawEntry entry.origin).any (fun raw =>
            ostr raw "type" == some "model_change" &&
              ostr raw "provider" == some provider &&
              ostr raw "modelId" == some target &&
              (piTargetModelChangeStamp? raw).isSome)
    | _, _, _ => false)

private def piShouldAppendTargetModelChange (t : Transcript) : Bool :=
  piUsesTargetOptions t && !piActiveHasTargetModelChange t

private def piTargetModelChangeId
    (_t : Transcript) (idPlan : List (List String)) : String :=
  freshPiEntryId "loom-target-model" idPlan.flatten

private def piTargetModelChangeJson? (t : Transcript)
    (idPlan : List (List String)) : Option Json := do
  guard (piShouldAppendTargetModelChange t)
  let provider ← targetProvider t
  let model ← targetModel t
  let timestamp ← targetTimestamp t
  let id := piTargetModelChangeId t idPlan
  let parentId := t.activeLeaf.map (piEntryLastId idPlan)
  pure <| Json.mkObj (piBaseFields none id parentId timestamp
      (.recorded ((iso8601ToEpochMs? timestamp).getD ⟨0⟩)) ++ [
    ("type", Json.str "model_change"),
    ("provider", Json.str provider), ("modelId", Json.str model),
    (piCarrierKey, piStampedObject [
      ("targetModelChange", Json.mkObj [
        ("author", Json.str "target"),
        ("target_provider", Json.str "origin-target-option"),
        ("target_model", Json.str "origin-target-option"),
        ("target_timestamp", Json.str "origin-target-option")])])])

private def piCandidateRecords (t : Transcript) : List Json :=
  let idPlan := piEntryIdPlan t
  let coordinatePlan := piAssistantCoordinatePlan t idPlan
  let entryLines := (piExportOrder t).flatMap (fun i =>
    match t.entries[i]? with
    | some entry => entryToJsonLinesWithPlan t idPlan coordinatePlan i entry
    | none => [])
  headerToJson t :: entryLines ++ (piTargetModelChangeJson? t idPlan).toList

private def piCountJsonBlocks (value : Json) (predicate : Json → Bool) : Nat :=
  (oarr value "blocks").map (fun blocks =>
    blocks.toList.countP predicate) |>.getD 0

private def piHistoricalOccurrencesInRecord (entry : Json) : List String :=
  match piCarrierEntryKind? entry, piCarrierValue? entry with
  | some "assistantMessage", some value =>
      let toolCalls := piCountJsonBlocks value (fun block =>
        ostr block "kind" == some "toolCall" ||
          ostr block "type" == some "toolCall" ||
          (oobj block piCarrierKey).any (fun stamp =>
            onat stamp "version" == some piCarrierVersion &&
              ostr stamp "kind" == some "block" &&
              ostr stamp "author" == some "assistant" &&
              ostr stamp "constructor" == some "toolCall"))
      "assistant" :: List.replicate toolCalls "toolCall"
  | some "toolResult", _ => ["toolResult"]
  | some "historicalPayload", some value =>
      match ostr value "kind" with
      | some "assistantMsg" =>
          let toolCalls := piCountJsonBlocks value (fun block =>
            ostr block "kind" == some "toolCall")
          "assistant" :: List.replicate toolCalls "toolCall"
      | some "envMsg" =>
          List.replicate (piCountJsonBlocks value (fun block =>
            ostr block "kind" == some "toolResult")) "toolResult"
      | _ => []
  | _, _ => []

private def piTargetHistoricalOccurrences (t : Transcript) : List String :=
  (piCandidateRecords t).drop 1 |>.flatMap piHistoricalOccurrencesInRecord

/-- Counts describe the planned Pi artifact, including record splitting and
carrier contents. They are intentionally not inferred from source IR counts. -/
structure PiTargetSummary where
  nativeAssistantContextMessages : Nat
  historicalAssistantCarriers : Nat
  historicalToolCallCarriers : Nat
  historicalToolResultCarriers : Nat
  resumable : Bool
  deriving Repr, DecidableEq

def piTargetResumable (t : Transcript) : Bool :=
  piAssistantHistoryMode t == "context"

def piNativeAssistantContextCount (t : Transcript) : Nat :=
  (piCandidateRecords t).drop 1 |>.countP (fun entry =>
    ostr entry "type" == some "message" &&
      (oobj entry "message").bind (fun message => ostr message "role") ==
        some "assistant")

/-- Native Pi tool calls are counted from assistant-message content in the
planned artifact, after all context/carrier projection and record splitting. -/
def piNativeToolCallCount (t : Transcript) : Nat :=
  (piCandidateRecords t).drop 1 |>.foldl (fun count entry =>
    match oobj entry "message" with
    | some message =>
        if ostr message "role" != some "assistant" then count
        else
          let nativeCalls := match oarr message "content" with
            | some blocks => blocks.toList.countP (fun block =>
                ostr block "type" == some "toolCall")
            | none => 0
          count + nativeCalls
    | none => count) 0

/-- Native Pi tool results are message records with Pi's `toolResult` role.
Historical results live only inside stamped custom carriers and are excluded. -/
def piNativeToolResultCount (t : Transcript) : Nat :=
  (piCandidateRecords t).drop 1 |>.countP (fun entry =>
    ostr entry "type" == some "message" &&
      (oobj entry "message").bind (fun message => ostr message "role") ==
        some "toolResult")

private def piPlannedNativeToolCallIds (t : Transcript) : List String :=
  (piCandidateRecords t).drop 1 |>.flatMap (fun entry =>
    match oobj entry "message" with
    | some message =>
        if ostr message "role" != some "assistant" then [] else
          (oarr message "content").map (fun blocks =>
            blocks.toList.filterMap (fun block =>
              if ostr block "type" == some "toolCall" then ostr block "id"
              else none)) |>.getD []
    | none => [])

private def piPlannedNativeToolResultIds (t : Transcript) : List String :=
  (piCandidateRecords t).drop 1 |>.filterMap (fun entry => do
    let message ← oobj entry "message"
    guard (ostr message "role" == some "toolResult")
    ostr message "toolCallId")

/-- Count unmatched target-native call occurrences from the planned artifact.
Carrier calls/results are absent from both multisets and cannot affect it. -/
def piNativeOpenToolCallCount (t : Transcript) : Nat :=
  (piPlannedNativeToolResultIds t).foldl
    (fun pending resultId => pending.erase resultId)
    (piPlannedNativeToolCallIds t) |>.length

def piHistoricalAssistantCarrierCount (t : Transcript) : Nat :=
  (piTargetHistoricalOccurrences t).count "assistant"

def piHistoricalToolCallCarrierCount (t : Transcript) : Nat :=
  (piTargetHistoricalOccurrences t).count "toolCall"

def piHistoricalToolResultCarrierCount (t : Transcript) : Nat :=
  (piTargetHistoricalOccurrences t).count "toolResult"

def piTargetSummary (t : Transcript) : PiTargetSummary := {
  nativeAssistantContextMessages := piNativeAssistantContextCount t
  historicalAssistantCarriers := piHistoricalAssistantCarrierCount t
  historicalToolCallCarriers := piHistoricalToolCallCarrierCount t
  historicalToolResultCarriers := piHistoricalToolResultCarrierCount t
  resumable := piTargetResumable t }

private def renderPiCandidate (t : Transcript) : String :=
  String.intercalate "\n" ((piCandidateRecords t).map Json.compress) ++ "\n"

/-! ## Import: pi JSONL → Loom IR -/

private def piSchemaError (ctx detail : String) : Except String α :=
  .error s!"malformed Pi {ctx}: {detail}"

private def piEnsureObject (ctx : String) : Json → Except String Unit
  | .obj _ => pure ()
  | _ => piSchemaError ctx "expected an object"

private def piRequireField (ctx : String) (j : Json) (key : String) : Except String Json := do
  piEnsureObject ctx j
  match j.getObjVal? key with
  | .ok value => pure value
  | .error _ => piSchemaError ctx s!"missing required field '{key}'"

private def piRequireString (ctx : String) (j : Json) (key : String) : Except String String := do
  match ← piRequireField ctx j key with
  | .str value => pure value
  | _ => piSchemaError ctx s!"field '{key}' must be a string"

private def piRequireNonemptyString
    (ctx : String) (j : Json) (key : String) : Except String String := do
  let value ← piRequireString ctx j key
  if value.isEmpty then piSchemaError ctx s!"field '{key}' must not be empty"
  else pure value

private def piRequireObject (ctx : String) (j : Json) (key : String) : Except String Json := do
  let value ← piRequireField ctx j key
  match value with
  | .obj _ => pure value
  | _ => piSchemaError ctx s!"field '{key}' must be an object"

private def piRequireArray
    (ctx : String) (j : Json) (key : String) : Except String (Array Json) := do
  match ← piRequireField ctx j key with
  | .arr values => pure values
  | _ => piSchemaError ctx s!"field '{key}' must be an array"

private def piRequireBool (ctx : String) (j : Json) (key : String) : Except String Bool := do
  match ← piRequireField ctx j key with
  | .bool value => pure value
  | _ => piSchemaError ctx s!"field '{key}' must be a boolean"

private def piRequireNat (ctx : String) (j : Json) (key : String) : Except String Nat := do
  match Json.getNat? (← piRequireField ctx j key) with
  | .ok value => pure value
  | .error _ => piSchemaError ctx s!"field '{key}' must be a natural number"

private def piRequireNumber (ctx : String) (j : Json) (key : String) : Except String Unit := do
  match ← piRequireField ctx j key with
  | .num _ => pure ()
  | _ => piSchemaError ctx s!"field '{key}' must be a number"

private def piOptionalString
    (ctx : String) (j : Json) (key : String) : Except String (Option String) := do
  piEnsureObject ctx j
  match j.getObjVal? key with
  | .error _ => pure none
  | .ok (.str value) => pure (some value)
  | .ok _ => piSchemaError ctx s!"field '{key}' must be a string when present"

private def piOptionalNullableString
    (ctx : String) (j : Json) (key : String) : Except String (Option String) := do
  piEnsureObject ctx j
  match j.getObjVal? key with
  | .error _ | .ok .null => pure none
  | .ok (.str value) =>
      if value.isEmpty then piSchemaError ctx s!"field '{key}' must not be empty"
      else pure (some value)
  | .ok _ => piSchemaError ctx s!"field '{key}' must be a string or null"

private def piOptionalNullableToolName
    (ctx : String) (j : Json) : Except String (Option String) := do
  piEnsureObject ctx j
  match j.getObjVal? "toolName" with
  | .error _ | .ok .null => pure none
  | .ok (.str value) => pure (some value)
  | .ok _ => piSchemaError ctx "field 'toolName' must be a string or null"

private def piOptionalBool
    (ctx : String) (j : Json) (key : String) : Except String (Option Bool) := do
  piEnsureObject ctx j
  match j.getObjVal? key with
  | .error _ => pure none
  | .ok (.bool value) => pure (some value)
  | .ok _ => piSchemaError ctx s!"field '{key}' must be a boolean when present"

private def piOptionalNat
    (ctx : String) (j : Json) (key : String) : Except String (Option Nat) := do
  piEnsureObject ctx j
  match j.getObjVal? key with
  | .error _ => pure none
  | .ok value =>
      match Json.getNat? value with
      | .ok number => pure (some number)
      | .error _ => piSchemaError ctx s!"field '{key}' must be a natural number when present"

private def piOptionalNumber (ctx : String) (j : Json) (key : String) : Except String Unit := do
  piEnsureObject ctx j
  match j.getObjVal? key with
  | .error _ => pure ()
  | .ok (.num _) => pure ()
  | .ok _ => piSchemaError ctx s!"field '{key}' must be a number when present"

private def piOptionalArray
    (ctx : String) (j : Json) (key : String) : Except String (Option (Array Json)) := do
  piEnsureObject ctx j
  match j.getObjVal? key with
  | .error _ => pure none
  | .ok (.arr values) => pure (some values)
  | .ok _ => piSchemaError ctx s!"field '{key}' must be an array when present"

private def piOptionalObject
    (ctx : String) (j : Json) (key : String) : Except String (Option Json) := do
  piEnsureObject ctx j
  match j.getObjVal? key with
  | .error _ => pure none
  | .ok value@(.obj _) => pure (some value)
  | .ok _ => piSchemaError ctx s!"field '{key}' must be an object when present"

private def piOptionalNullableNat
    (ctx : String) (j : Json) (key : String) : Except String (Option Nat) := do
  piEnsureObject ctx j
  match j.getObjVal? key with
  | .error _ | .ok .null => pure none
  | .ok value =>
      match Json.getNat? value with
      | .ok number => pure (some number)
      | .error _ =>
          piSchemaError ctx s!"field '{key}' must be a natural number or null"

private def piRequireParentId (ctx : String) (j : Json) : Except String (Option String) := do
  match ← piRequireField ctx j "parentId" with
  | .null => pure none
  | .str value =>
      if value.isEmpty then piSchemaError ctx "field 'parentId' must not be empty"
      else pure (some value)
  | _ => piSchemaError ctx "field 'parentId' must be a string or null"

private def piRequireTimestamp (ctx : String) (j : Json) : Except String String := do
  let value ← piRequireString ctx j "timestamp"
  if (iso8601ToEpochMs? value).isSome then pure value
  else piSchemaError ctx "field 'timestamp' must be UTC ISO-8601 with optional seconds or exactly millisecond precision"

private def piValidateUsage (ctx : String) (message : Json) : Except String Unit := do
  let usage ← piRequireObject ctx message "usage"
  let usageCtx := s!"{ctx}.usage"
  for key in ["input", "output", "cacheRead", "cacheWrite", "totalTokens"] do
    piRequireNumber usageCtx usage key
  let cost ← piRequireObject usageCtx usage "cost"
  let costCtx := s!"{usageCtx}.cost"
  for key in ["input", "output", "cacheRead", "cacheWrite", "total"] do
    piRequireNumber costCtx cost key

private def piValidateStopReason (ctx : String) (message : Json) : Except String Unit := do
  let reason ← piRequireNonemptyString ctx message "stopReason"
  if ["stop", "length", "toolUse", "error", "aborted"].contains reason then pure ()
  else piSchemaError ctx s!"field 'stopReason' has unsupported value '{reason}'"
  let _ ← piOptionalString ctx message "errorMessage"
  pure ()

private def piValidateDiagnosticError (ctx : String) (error : Json) : Except String Unit := do
  piEnsureObject ctx error
  let _ ← piOptionalString ctx error "name"
  let _ ← piRequireString ctx error "message"
  let _ ← piOptionalString ctx error "stack"
  match error.getObjVal? "code" with
  | .error _ | .ok (.str _) | .ok (.num _) => pure ()
  | .ok _ => piSchemaError ctx "field 'code' must be a string or number when present"

private def piValidateDiagnostics (ctx : String) (message : Json) : Except String Unit := do
  let some diagnostics ← piOptionalArray ctx message "diagnostics" | pure ()
  for (diagnostic, index) in diagnostics.toList.zipIdx do
    let itemCtx := s!"{ctx}.diagnostics[{index}]"
    piEnsureObject itemCtx diagnostic
    let _ ← piRequireString itemCtx diagnostic "type"
    piRequireNumber itemCtx diagnostic "timestamp"
    match ← piOptionalObject itemCtx diagnostic "error" with
    | some error => piValidateDiagnosticError s!"{itemCtx}.error" error
    | none => pure ()
    let _ ← piOptionalObject itemCtx diagnostic "details"
    pure ()

private structure PiBlockCarrier where
  constructor : String
  label : String
  raw : Json

private def piReservedStamp? (ctx : String) (j : Json) : Except String (Option Json) := do
  match j.getObjVal? piCarrierKey with
  | .error _ => pure none
  | .ok stamp =>
      piEnsureObject s!"{ctx}.{piCarrierKey}" stamp
      let version ← piRequireNat s!"{ctx}.{piCarrierKey}" stamp "version"
      if version != piCarrierVersion then
        piSchemaError s!"{ctx}.{piCarrierKey}"
          s!"unsupported Loom Pi carrier version {version}"
      else pure (some stamp)

private def piReservedObjectMember? (ctx : String) (stamp : Json)
    (key : String) : Except String (Option Json) := do
  match stamp.getObjVal? key with
  | .error _ => pure none
  | .ok value@(.obj _) => pure (some value)
  | .ok _ => piSchemaError s!"{ctx}.{piCarrierKey}.{key}" "recognized reserved member must be an object"

private def piParseCanonicalToolName? : String → Option CanonicalTool
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

private def piValidateMessageReservedStamp
    (ctx : String) (stamp : Json) : Except String Unit := do
  match ← piReservedObjectMember? ctx stamp "toolError" with
  | some value =>
      let memberCtx := s!"{ctx}.{piCarrierKey}.toolError"
      match ← piRequireNonemptyString memberCtx value "state" with
      | "inferred" =>
          let _ ← piRequireBool memberCtx value "value"
          let _ ← piRequireString memberCtx value "heuristic"
          pure ()
      | "unrecorded" => pure ()
      | state => piSchemaError memberCtx s!"unsupported Loom tool-error carrier state '{state}'"
  | none => pure ()
  match ← piReservedObjectMember? ctx stamp "toolCallRef" with
  | some value =>
      let memberCtx := s!"{ctx}.{piCarrierKey}.toolCallRef"
      let state ← piRequireNonemptyString memberCtx value "state"
      if state != "unresolved" then
        piSchemaError memberCtx
          s!"unsupported Loom tool-call carrier state '{state}'"
      else pure ()
      let _ ← piOptionalNullableString memberCtx value "rawId"
      let _ ← piRequireString memberCtx value "note"
      pure ()
  | none => pure ()
  match ← piReservedObjectMember? ctx stamp "assistantHistory" with
  | some value =>
      let memberCtx := s!"{ctx}.{piCarrierKey}.assistantHistory"
      let mode ← piRequireNonemptyString memberCtx value "mode"
      if mode != "context" then
        piSchemaError memberCtx s!"unsupported assistant history mode '{mode}'"
      else pure ()
      for key in ["identity", "metadata", "usage", "stopReason", "timestamp"] do
        let _ ← piRequireNonemptyString memberCtx value key
      pure ()
  | none => pure ()
  -- `toolCanonical` is an ARRAY, so it cannot go through
  -- `piReservedObjectMember?` like the members above; it is validated here so
  -- the reserved key stays fail-closed on every message role, not only on the
  -- assistant records that read it.
  let canonicalCtx := s!"{ctx}.{piCarrierKey}.toolCanonical"
  match stamp.getObjVal? "toolCanonical" with
  | .error _ => pure ()
  | .ok (.arr values) =>
      if values.isEmpty then
        piSchemaError canonicalCtx "must not be empty when present"
      else pure ()
      let indices ← values.toList.mapM (fun value => do
        piEnsureObject canonicalCtx value
        let blockIdx ← piRequireNat canonicalCtx value "block"
        let name ← piRequireNonemptyString canonicalCtx value "canonical"
        match piParseCanonicalToolName? name with
        | some _ => pure blockIdx
        | none => (piSchemaError canonicalCtx
            s!"unsupported Loom canonical tool '{name}'"))
      if indices.eraseDups.length != indices.length then
        piSchemaError canonicalCtx "must not contain duplicate block indices"
      else pure ()
  | .ok _ => (piSchemaError canonicalCtx
      "must be an array of block/canonical members")

private def piValidateEntryReservedStamp
    (ctx : String) (entry : Json) : Except String Unit := do
  let some stamp ← piReservedStamp? ctx entry | pure ()
  match ← piReservedObjectMember? ctx stamp "targetModelChange" with
  | some value =>
      let memberCtx := s!"{ctx}.{piCarrierKey}.targetModelChange"
      for key in ["author", "target_provider", "target_model", "target_timestamp"] do
        let _ ← piRequireNonemptyString memberCtx value key
      pure ()
  | none => pure ()

private def piBlockCarrier? (ctx author : String)
    (j : Json) : Except String (Option PiBlockCarrier) := do
  let some stamp ← piReservedStamp? ctx j | pure none
  let stampCtx := s!"{ctx}.{piCarrierKey}"
  let kind ← piRequireNonemptyString stampCtx stamp "kind"
  if kind != "block" then
    piSchemaError stampCtx s!"reserved block stamp has unsupported kind '{kind}'"
  else pure ()
  let stampedAuthor ← piRequireNonemptyString stampCtx stamp "author"
  if stampedAuthor != author then
    piSchemaError stampCtx
      s!"reserved block stamp author '{stampedAuthor}' is invalid for {author} content"
  else pure ()
  let constructor ← piRequireNonemptyString stampCtx stamp "constructor"
  let label ← piRequireString stampCtx stamp "label"
  let raw ← piRequireField stampCtx stamp "raw"
  pure (some { constructor, label, raw })

private def parseUserBlockAt (ctx : String) (j : Json) : Except String UserBlock := do
  piEnsureObject ctx j
  let kind ← piRequireNonemptyString ctx j "type"
  let carrier ← piBlockCarrier? ctx "user" j
  match kind with
  | "text" =>
      let text ← piRequireString ctx j "text"
      let _ ← piOptionalString ctx j "textSignature"
      match carrier with
      | some { constructor := "unmodeled", label, raw } => pure (.unmodeled label raw)
      | some _ => piSchemaError ctx "invalid Loom user-block carrier"
      | none => pure (.text text)
  | "image" =>
      match carrier with
      | some _ => piSchemaError ctx "reserved Loom user-block carrier must use type 'text'"
      | none => pure (.media (← piRequireNonemptyString ctx j "mimeType")
          (← piRequireString ctx j "data"))
  | _ => piSchemaError ctx s!"block type '{kind}' is not valid for user/tool-result content"

def parseUserBlock (j : Json) : Except String UserBlock :=
  parseUserBlockAt "user block" j

private def parseOpenRoleBlockAt (ctx : String) (j : Json) : Except String UserBlock := do
  piEnsureObject ctx j
  let kind ← piRequireNonemptyString ctx j "type"
  match kind with
  | "text" | "image" => parseUserBlockAt ctx j
  | _ => piSchemaError ctx s!"block type '{kind}' is not valid for content"

private def parseAssistantBlockAt
    (ctx : String) (canonicalOverride : Option CanonicalTool)
    (j : Json) : Except String AssistantBlock := do
  piEnsureObject ctx j
  let kind ← piRequireNonemptyString ctx j "type"
  let carrier ← piBlockCarrier? ctx "assistant" j
  match kind with
  | "text" =>
      let text ← piRequireString ctx j "text"
      let _ ← piOptionalString ctx j "textSignature"
      match carrier with
      | some { constructor := "toolCall", raw, .. } =>
          let name ← piRequireString ctx raw "name"
          let arguments ← piRequireField ctx raw "arguments"
          let id ← piOptionalString ctx raw "id"
          pure (.toolCall { raw := name, canonical := none } arguments id)
      | some { constructor := "media", raw, .. } =>
          pure (.media (← piRequireNonemptyString ctx raw "mimeType")
            (← piRequireString ctx raw "data"))
      | some { constructor := "unmodeled", label, raw } => pure (.unmodeled label raw)
      | some _ => piSchemaError ctx "invalid Loom assistant-block carrier"
      | none => pure (.text text)
  | "thinking" =>
      match carrier with
      | some _ => piSchemaError ctx "reserved Loom assistant-block carrier must use type 'text'"
      | none =>
          let _ ← piOptionalBool ctx j "redacted"
          pure (.thinking (← piRequireString ctx j "thinking")
            (← piOptionalString ctx j "thinkingSignature"))
  | "toolCall" =>
      match carrier with
      | some _ => piSchemaError ctx "reserved Loom assistant-block carrier must use type 'text'"
      | none =>
          let id ← piRequireNonemptyString ctx j "id"
          let name ← piRequireNonemptyString ctx j "name"
          let arguments ← piRequireObject ctx j "arguments"
          let _ ← piOptionalString ctx j "thoughtSignature"
          -- `canonicalOverride` comes from the message-level reserved stamp, not
          -- from the block: a stamp on the block would make the message
          -- historical. Absent (every pi-origin artifact) it is `none`.
          pure (.toolCall { raw := name, canonical := canonicalOverride }
            arguments (some id))
  | _ => piSchemaError ctx s!"block type '{kind}' is not valid for assistant content"

def parseAssistantBlock (j : Json) : Except String AssistantBlock :=
  parseAssistantBlockAt "assistant block" none j

private def piImportNote (label loc detail : String) : ImportNote :=
  { kind := .other label, loc := some loc, detail }

private def piUserBlockNotes (role ctx : String)
    (blocks : List UserBlock) : List ImportNote :=
  blocks.zipIdx.filterMap (fun (block, blockIdx) =>
    match block with
    | .unmodeled label _ => some (piImportNote "pi-unmodeled-block"
        s!"{ctx}[{blockIdx}]"
        s!"preserved unknown Pi block type '{label}' verbatim for role '{role}'")
    | _ => none)

private def piAssistantBlockNotes (ctx : String)
    (blocks : List AssistantBlock) : List ImportNote :=
  blocks.zipIdx.filterMap (fun (block, blockIdx) =>
    match block with
    | .unmodeled label _ => some (piImportNote "pi-unmodeled-block"
        s!"{ctx}[{blockIdx}]"
        s!"preserved unknown Pi assistant block type '{label}' verbatim")
    | _ => none)

private structure PiUnresolvedCall where
  rawId : Option String
  note : String

private def piHeaderSourceEnvironment?
    (ctx : String) (header : Json) : Except String (Option EnvInfo) := do
  let some stamp ← piReservedStamp? ctx header | pure none
  let some source ← piReservedObjectMember? ctx stamp "sourceEnvironment" | pure none
  match piDecodeSourceEnvironment source with
  | some env => pure (some env)
  | none => piSchemaError (s!"{ctx}.{piCarrierKey}.sourceEnvironment") "expected all six EnvInfo fields as strings or null"

private def piTimeCarrier? (ctx : String) (entry : Json) : Except String (Option Time) := do
  let some stamp ← piReservedStamp? ctx entry | pure none
  let some time ← piReservedObjectMember? ctx stamp "time" | pure none
  let state ← piRequireNonemptyString s!"{ctx}.{piCarrierKey}.time" time "state"
  match state with
  | "absent" => pure (some .absent)
  | "sequenced" => pure (some (.sequenced (← piRequireNat ctx time "ordinal")))
  | "interpolated" =>
      pure (some (.interpolated ⟨← piRequireNat ctx time "ms"⟩
        (← piRequireString ctx time "basis")))
  | other => piSchemaError ctx s!"unsupported Loom time carrier state '{other}'"

private def piToolErrorSignal (ctx : String) (message : Json)
    (nativeValue : Bool) : Except String ErrorSignal := do
  let some stamp ← piReservedStamp? ctx message | pure (.native nativeValue)
  let some toolError ← piReservedObjectMember? ctx stamp "toolError" |
    pure (.native nativeValue)
  let state ← piRequireNonemptyString s!"{ctx}.{piCarrierKey}.toolError"
    toolError "state"
  match state with
  | "inferred" =>
      let value ← piRequireBool ctx toolError "value"
      if value != nativeValue then
        piSchemaError ctx "Loom inferred tool-error carrier disagrees with required isError"
      else pure (.inferred value (← piRequireString ctx toolError "heuristic"))
  | "unrecorded" =>
      if nativeValue then
        piSchemaError ctx "Loom unrecorded tool-error placeholder must use isError=false"
      else pure .unrecorded
  | other => piSchemaError ctx s!"unsupported Loom tool-error carrier state '{other}'"

/-- Recover `ToolName.canonical` for the message's native `toolCall` blocks from
the reserved message-level stamp the exporter wrote (`piToolCanonicalCarrier`).

Indices address the emitted content array. `piValidateMessageReservedStamp`
rejects a malformed member before this runs, so a well-formed artifact either
has no member or has one this can read exactly. -/
private def piToolCanonicalCarrier? (ctx : String)
    (message : Json) : Except String (List (Nat × CanonicalTool)) := do
  let some stamp ← piReservedStamp? ctx message | pure []
  match stamp.getObjVal? "toolCanonical" with
  | .error _ => pure []
  | .ok (.arr values) =>
      values.toList.mapM (fun value => do
        let blockIdx ← piRequireNat s!"{ctx}.{piCarrierKey}.toolCanonical"
          value "block"
        let name ← piRequireNonemptyString
          s!"{ctx}.{piCarrierKey}.toolCanonical" value "canonical"
        match piParseCanonicalToolName? name with
        | some canonical => pure (blockIdx, canonical)
        | none => (piSchemaError s!"{ctx}.{piCarrierKey}.toolCanonical"
            s!"unsupported Loom canonical tool '{name}'"))
  | .ok _ => (piSchemaError s!"{ctx}.{piCarrierKey}.toolCanonical"
      "must be an array of block/canonical members")

private def piCanonicalForBlock
    (overrides : List (Nat × CanonicalTool)) (blockIdx : Nat) : Option CanonicalTool :=
  (overrides.find? (fun entry => entry.1 == blockIdx)).map Prod.snd

private def piUnresolvedCallCarrier? (ctx : String)
    (message : Json) : Except String (Option PiUnresolvedCall) := do
  let some stamp ← piReservedStamp? ctx message | pure none
  let some callRef ← piReservedObjectMember? ctx stamp "toolCallRef" | pure none
  let state ← piRequireNonemptyString s!"{ctx}.{piCarrierKey}.toolCallRef"
    callRef "state"
  if state != "unresolved" then
    piSchemaError ctx s!"unsupported Loom tool-call carrier state '{state}'"
  else
    let rawId ← piOptionalNullableString ctx callRef "rawId"
    let note ← piRequireString ctx callRef "note"
    pure (some { rawId, note })

private def piCarrierErrorSignal (ctx : String) (value : Json) : Except String ErrorSignal := do
  piEnsureObject ctx value
  let state ← piRequireNonemptyString ctx value "state"
  match state with
  | "native" => pure (.native (← piRequireBool ctx value "value"))
  | "inferred" => pure (.inferred (← piRequireBool ctx value "value")
      (← piRequireString ctx value "heuristic"))
  | "unrecorded" => pure .unrecorded
  | other => piSchemaError ctx s!"unsupported Loom error carrier state '{other}'"

private def piParseUserContent (ctx : String) (value : Json) : Except String (List UserBlock) :=
  match value with
  | .str text => pure [.text text]
  | .arr blocks => blocks.toList.zipIdx.mapM (fun (block, blockIdx) =>
      parseUserBlockAt s!"{ctx}[{blockIdx}]" block)
  | _ => piSchemaError ctx "content must be a string or an array"

private def piParseHistoricalCanonicalTool
    (ctx value : String) : Except String CanonicalTool :=
  match value with
  | "bash" => pure .bash
  | "read" => pure .read
  | "write" => pure .write
  | "edit" => pure .edit
  | "grep" => pure .grep
  | "glob" => pure .glob
  | "webFetch" => pure .webFetch
  | "webSearch" => pure .webSearch
  | "agentSpawn" => pure .agentSpawn
  | "applyPatch" => pure .applyPatch
  | other => piSchemaError ctx s!"unsupported canonical tool '{other}'"

private def piParseHistoricalUserBlock
    (ctx : String) (value : Json) : Except String UserBlock := do
  match ← piRequireNonemptyString ctx value "kind" with
  | "text" => pure (.text (← piRequireString ctx value "text"))
  | "media" => pure (.media (← piRequireString ctx value "mimeType")
      (← piRequireString ctx value "data"))
  | "unmodeled" => pure (.unmodeled (← piRequireString ctx value "label")
      (← piRequireField ctx value "raw"))
  | other => piSchemaError ctx s!"unsupported historical user block '{other}'"

private def piParseHistoricalAssistantBlock
    (ctx : String) (value : Json) : Except String AssistantBlock := do
  match ← piRequireNonemptyString ctx value "kind" with
  | "text" => pure (.text (← piRequireString ctx value "text"))
  | "thinking" => pure (.thinking (← piRequireString ctx value "thinking")
      (← piOptionalNullableString ctx value "signature"))
  | "toolCall" =>
      let canonical ← match ← piOptionalNullableString ctx value "canonical" with
        | some name => pure (some (← piParseHistoricalCanonicalTool
            s!"{ctx}.canonical" name))
        | none => pure none
      pure (.toolCall {
          raw := ← piRequireString ctx value "name", canonical }
        (← piRequireField ctx value "arguments")
        (← piOptionalNullableString ctx value "rawId"))
  | "media" => pure (.media (← piRequireString ctx value "mimeType")
      (← piRequireString ctx value "data"))
  | "unmodeled" => pure (.unmodeled (← piRequireString ctx value "label")
      (← piRequireField ctx value "raw"))
  | other => piSchemaError ctx s!"unsupported historical assistant block '{other}'"

private def piParseHistoricalCallRef
    (ctx : String) (value : Json) : Except String CallRef := do
  match ← piRequireNonemptyString ctx value "kind" with
  | "resolved" => pure (.resolved (← piRequireNat ctx value "entry")
      (← piRequireNat ctx value "block"))
  | "unresolved" => pure (.unresolved
      (← piOptionalNullableString ctx value "rawId")
      (← piRequireString ctx value "note"))
  | other => piSchemaError ctx s!"unsupported historical call reference '{other}'"

private def piParseHistoricalErrorSignal
    (ctx : String) (value : Json) : Except String ErrorSignal := do
  match ← piRequireNonemptyString ctx value "kind" with
  | "native" => pure (.native (← piRequireBool ctx value "value"))
  | "inferred" => pure (.inferred (← piRequireBool ctx value "value")
      (← piRequireString ctx value "heuristic"))
  | "unrecorded" => pure .unrecorded
  | other => piSchemaError ctx s!"unsupported historical error signal '{other}'"

private def piParseHistoricalEnvBlock
    (ctx : String) (value : Json) : Except String EnvBlock := do
  match ← piRequireNonemptyString ctx value "kind" with
  | "toolResult" => pure (.toolResult
      (← piParseHistoricalCallRef s!"{ctx}.call" (← piRequireObject ctx value "call"))
      (← (← piRequireArray ctx value "content").toList.zipIdx.mapM
        (fun (block, blockIdx) => piParseHistoricalUserBlock
          s!"{ctx}.content[{blockIdx}]" block))
      (← piParseHistoricalErrorSignal s!"{ctx}.error"
        (← piRequireObject ctx value "error")))
  | "unmodeled" => pure (.unmodeled (← piRequireString ctx value "label")
      (← piRequireField ctx value "raw"))
  | other => piSchemaError ctx s!"unsupported historical environment block '{other}'"

private def piParseHistoricalCoverage
    (ctx : String) (value : Json) : Except String CompactionCoverage := do
  match ← piRequireNonemptyString ctx value "kind" with
  | "knownPrefix" => pure (.knownPrefix (← piRequireNat ctx value "firstKept"))
  | "unknownPrefix" => pure .unknownPrefix
  | other => piSchemaError ctx s!"unsupported historical compaction coverage '{other}'"

private def piParseHistoricalMetaEvent
    (ctx : String) (value : Json) : Except String MetaEvent := do
  match ← piRequireNonemptyString ctx value "kind" with
  | "modelChange" => pure (.modelChange
      (← piOptionalNullableString ctx value "previous")
      (← piOptionalNullableString ctx value "next"))
  | "thinkingLevelChange" => pure (.thinkingLevelChange
      (← piOptionalNullableString ctx value "previous")
      (← piOptionalNullableString ctx value "next"))
  | "permissionMode" => pure (.permissionMode (← piRequireString ctx value "mode"))
  | "branchSummary" => pure (.branchSummary (← piRequireString ctx value "summary"))
  | "custom" => pure (.custom (← piRequireString ctx value "label")
      (← piRequireField ctx value "raw"))
  | other => piSchemaError ctx s!"unsupported historical event '{other}'"

private def piParseHistoricalPayload
    (ctx : String) (value : Json) : Except String Payload := do
  match ← piRequireNonemptyString ctx value "kind" with
  | "userMsg" => pure (.userMsg
      (← (← piRequireArray ctx value "blocks").toList.zipIdx.mapM
        (fun (block, blockIdx) => piParseHistoricalUserBlock
          s!"{ctx}.blocks[{blockIdx}]" block)))
  | "assistantMsg" => pure (.assistantMsg
      (← (← piRequireArray ctx value "blocks").toList.zipIdx.mapM
        (fun (block, blockIdx) => piParseHistoricalAssistantBlock
          s!"{ctx}.blocks[{blockIdx}]" block)))
  | "envMsg" => pure (.envMsg
      (← (← piRequireArray ctx value "blocks").toList.zipIdx.mapM
        (fun (block, blockIdx) => piParseHistoricalEnvBlock
          s!"{ctx}.blocks[{blockIdx}]" block)))
  | "otherMsg" => pure (.otherMsg (← piRequireString ctx value "role")
      (← (← piRequireArray ctx value "blocks").toList.zipIdx.mapM
        (fun (block, blockIdx) => piParseHistoricalUserBlock
          s!"{ctx}.blocks[{blockIdx}]" block)))
  | "compaction" => pure (.compaction (← piRequireString ctx value "summary")
      (← piParseHistoricalCoverage s!"{ctx}.coverage"
        (← piRequireObject ctx value "coverage"))
      (← piOptionalNullableNat ctx value "tokensBefore"))
  | "event" => pure (.event (← piParseHistoricalMetaEvent s!"{ctx}.event"
      (← piRequireObject ctx value "event")))
  | other => piSchemaError ctx s!"unsupported historical payload '{other}'"

private def piParseHistoricalAssistantSource (ctx : String) (value : Json)
    (payload : Payload) : Except String (Option Nat × List Nat) := do
  match payload with
  | .assistantMsg blocks =>
      let sourceEntry ← piOptionalNat ctx value "sourceEntry"
      let sourceIndices ← piOptionalArray ctx value "sourceBlockIndices"
      if sourceEntry.isSome != sourceIndices.isSome then
        piSchemaError ctx
          "historical assistant sourceEntry/sourceBlockIndices must appear together"
      else
        match sourceEntry, sourceIndices with
        | some entry, some indices =>
            let sourceBlocks ← indices.toList.zipIdx.mapM (fun (index, indexIdx) =>
              match Json.getNat? index with
              | .ok block => pure block
              | .error _ => piSchemaError
                  s!"{ctx}.sourceBlockIndices[{indexIdx}]"
                  "source block index must be a natural number")
            if sourceBlocks.length != blocks.length then
              piSchemaError ctx
                "historical assistant blocks and sourceBlockIndices must have equal length"
            else pure (some entry, sourceBlocks)
        | none, none => pure (none, [])
        | _, _ => piSchemaError ctx "historical assistant source coordinates are incomplete"
  | _ => pure (none, [])

private def piValidateOptionalString (ctx : String) (j : Json) (key : String) : Except String Unit := do
  let _ ← piOptionalString ctx j key
  pure ()

private def piValidateBashMessage (ctx : String) (message : Json) : Except String Unit := do
  let _ ← piRequireString ctx message "command"
  let _ ← piRequireString ctx message "output"
  piOptionalNumber ctx message "exitCode"
  let _ ← piRequireBool ctx message "cancelled"
  let _ ← piRequireBool ctx message "truncated"
  piValidateOptionalString ctx message "fullOutputPath"
  let _ ← piOptionalBool ctx message "excludeFromContext"
  pure ()

private structure RawEntry where
  line     : Nat
  id       : String
  parentId : Option String
  ts       : String
  payload  : Payload
  toolResultId : Option String := none
  toolResultError : ErrorSignal := .unrecorded
  toolResultForcedUnresolved : Option PiUnresolvedCall := none
  toolResultHistoricalSource : Option (Nat × Nat) := none
  toolResultContent : List UserBlock := []
  historicalAssistantSourceEntry : Option Nat := none
  historicalAssistantSourceBlocks : List Nat := []
  historicalPayloadDirect : Bool := false
  firstKeptEntryId : Option String := none
  tokensBefore : Option Nat := none
  timeOverride : Option Time := none
  piRaw : Option Json := none
  disposition : EntryDisposition := .native
  notes : List ImportNote := []

private def piHistoricalCarrierNote (loc : String) : ImportNote :=
  piImportNote "unverifiedAgentConvertCarrier" loc
    "exact in-band agent-convert carrier decoded as historical, unverified data"

private def piUserContentHasCarrier (content : Json) : Bool :=
  match content with
  | .arr blocks => blocks.any (fun block =>
      (block.getObjVal? piCarrierKey).toOption.isSome)
  | _ => false

private def piAssistantContentHasCarrier (content : Array Json) : Bool :=
  content.any (fun block => (block.getObjVal? piCarrierKey).toOption.isSome)

/-- A `toolCallRef` stamp says the call *linkage* was reconstructed rather than
read off the wire, so the record is unverified and decodes as historical.

A `toolError` stamp does not, and deliberately so. Every native field of the
record — `toolCallId`, `toolName`, `isError`, and the content blocks — is
genuinely present and target-shaped; the stamp only records how much is known
about `isError`, and `piToolErrorSignal` cross-checks it against that native
bool so it cannot contradict it. `EntryDisposition` answers "is this record
trustworthy target data"; `ErrorSignal` answers "how well is this one field
attested". Downgrading the whole entry because a field admits weaker knowledge
conflates the two, and it also made native export of a non-`.native` error
signal non-idempotent, which is why the exporter used to refuse it outright and
send every Codex-sourced result to prose. -/
private def piToolResultLinkageIsReconstructed (message : Json) : Bool :=
  match oobj message piCarrierKey with
  | some stamp => (oobj stamp "toolCallRef").isSome
  | none => false

private def parseEntry (line : Nat) (j : Json) : Except String RawEntry := do
  let ctx := s!"record at line {line}"
  piEnsureObject ctx j
  let kind ← piRequireNonemptyString ctx j "type"
  if kind == "session" then
    piSchemaError ctx "a session header is only valid as the first record"
  else pure ()
  let id ← piRequireNonemptyString ctx j "id"
  let parentId ← piRequireParentId ctx j
  let ts ← piRequireTimestamp ctx j
  let timeOverride ← piTimeCarrier? ctx j
  piValidateEntryReservedStamp ctx j
  let base := fun (payload : Payload) => ({
    line, id, parentId, ts, payload, timeOverride, piRaw := some j } : RawEntry)
  match kind with
  | "message" =>
      let message ← piRequireObject ctx j "message"
      let messageCtx := s!"{ctx}.message"
      let messageStamp ← piReservedStamp? messageCtx message
      match messageStamp with
      | some stamp => piValidateMessageReservedStamp messageCtx stamp
      | none => pure ()
      let role ← piRequireNonemptyString messageCtx message "role"
      let _ ← piRequireNat messageCtx message "timestamp"
      let contentCtx := s!"{messageCtx}.content"
      if role == "user" then
        let contentValue ← piRequireField messageCtx message "content"
        let blocks ← piParseUserContent contentCtx contentValue
        let historical := piUserContentHasCarrier contentValue
        pure { (base (.userMsg blocks)) with
          disposition := if historical then .historicalUnverified else .native
          notes := piUserBlockNotes role contentCtx blocks ++
            (if historical then [piHistoricalCarrierNote contentCtx] else []) }
      else if role == "assistant" then
        let content ← piRequireArray messageCtx message "content"
        let _ ← piRequireNonemptyString messageCtx message "api"
        let _ ← piRequireNonemptyString messageCtx message "provider"
        let _ ← piRequireNonemptyString messageCtx message "model"
        let _ ← piOptionalString messageCtx message "responseModel"
        let _ ← piOptionalString messageCtx message "responseId"
        piValidateUsage messageCtx message
        piValidateStopReason messageCtx message
        piValidateDiagnostics messageCtx message
        let toolCanonical ← piToolCanonicalCarrier? messageCtx message
        let blocks ← content.toList.zipIdx.mapM (fun (block, blockIdx) =>
          parseAssistantBlockAt s!"{contentCtx}[{blockIdx}]"
            (piCanonicalForBlock toolCanonical blockIdx) block)
        let historical := piAssistantContentHasCarrier content
        pure { (base (.assistantMsg blocks)) with
          disposition := if historical then .historicalUnverified else .native
          notes := piAssistantBlockNotes contentCtx blocks ++
            (if historical then [piHistoricalCarrierNote contentCtx] else []) }
      else if role == "toolResult" then
        let content ← piRequireArray messageCtx message "content"
        let toolCallId ← piRequireNonemptyString messageCtx message "toolCallId"
        let _ ← piRequireNonemptyString messageCtx message "toolName"
        let isError ← piRequireBool messageCtx message "isError"
        let error ← piToolErrorSignal messageCtx message isError
        let forcedUnresolved ← piUnresolvedCallCarrier? messageCtx message
        let blocks ← content.toList.zipIdx.mapM (fun (block, blockIdx) =>
          parseUserBlockAt s!"{contentCtx}[{blockIdx}]" block)
        let historical := piToolResultLinkageIsReconstructed message ||
          content.any (fun block =>
            (block.getObjVal? piCarrierKey).toOption.isSome)
        pure { (base (.envMsg [])) with
          toolResultId := some toolCallId,
          toolResultError := error,
          toolResultForcedUnresolved := forcedUnresolved,
          toolResultContent := blocks,
          disposition := if historical then .historicalUnverified else .native
          notes := piUserBlockNotes role contentCtx blocks ++
            (if historical then [piHistoricalCarrierNote contentCtx] else []) }
      else if role == "bashExecution" then
        piValidateBashMessage messageCtx message
        pure { (base (.otherMsg role [.unmodeled role message])) with
          notes := [piImportNote "pi-structured-other-role" s!"{messageCtx}.role"
            "preserved native Pi bashExecution fields in an inert block"] }
      else if role == "branchSummary" then
        let _ ← piRequireString messageCtx message "summary"
        let _ ← piRequireNonemptyString messageCtx message "fromId"
        pure { (base (.otherMsg role [.unmodeled role message])) with
          notes := [piImportNote "pi-structured-other-role" s!"{messageCtx}.role"
            "preserved native Pi branchSummary fields in an inert block"] }
      else if role == "compactionSummary" then
        let _ ← piRequireString messageCtx message "summary"
        let _ ← piRequireNat messageCtx message "tokensBefore"
        pure { (base (.otherMsg role [.unmodeled role message])) with
          notes := [piImportNote "pi-structured-other-role" s!"{messageCtx}.role"
            "preserved native Pi compactionSummary fields in an inert block"] }
      else if role == "custom" then
        let _ ← piRequireNonemptyString messageCtx message "customType"
        let contentValue ← piRequireField messageCtx message "content"
        let blocks ← piParseUserContent contentCtx contentValue
        let _ ← piRequireBool messageCtx message "display"
        let historical := piUserContentHasCarrier contentValue
        pure { (base (.otherMsg role blocks)) with
          disposition := if historical then .historicalUnverified else .native
          notes := piUserBlockNotes role contentCtx blocks ++
            (if historical then [piHistoricalCarrierNote contentCtx] else []) }
      else
        let roleNote := piImportNote "pi-unmodeled-role" s!"{messageCtx}.role"
          s!"preserved unknown Pi message role '{role}' inertly"
        pure { (base (.otherMsg role [.unmodeled role message])) with
          notes := [roleNote] }
  | "compaction" =>
      let summary ← piRequireString ctx j "summary"
      let firstKeptEntryId ← piRequireNonemptyString ctx j "firstKeptEntryId"
      let tokensBefore ← piRequireNat ctx j "tokensBefore"
      let _ ← piOptionalBool ctx j "fromHook"
      pure { (base (.compaction summary .unknownPrefix (some tokensBefore))) with
        firstKeptEntryId := some firstKeptEntryId, tokensBefore := some tokensBefore }
  | "model_change" =>
      let _ ← piRequireNonemptyString ctx j "provider"
      let modelId ← piRequireNonemptyString ctx j "modelId"
      let previous ← piOptionalString ctx j "previousModelId"
      pure (base (.event (.modelChange previous (some modelId))))
  | "thinking_level_change" =>
      let level ← piRequireNonemptyString ctx j "thinkingLevel"
      let previous ← piOptionalString ctx j "previousThinkingLevel"
      pure (base (.event (.thinkingLevelChange previous (some level))))
  | "branch_summary" =>
      let _ ← piRequireNonemptyString ctx j "fromId"
      let _ ← piOptionalBool ctx j "fromHook"
      pure (base (.event (.branchSummary (← piRequireString ctx j "summary"))))
  | "custom" =>
      let customType ← piRequireNonemptyString ctx j "customType"
      if customType == "loom.pi.carrier" then
        let data ← piRequireObject ctx j "data"
        let version ← piRequireNat s!"{ctx}.data" data "version"
        if version != piCarrierVersion then
          piSchemaError ctx s!"unsupported Loom Pi carrier version {version}"
        else pure ()
        let carrierKind ← piRequireNonemptyString s!"{ctx}.data" data "kind"
        let value ← piRequireField s!"{ctx}.data" data "value"
        let restored ← match carrierKind with
        | "branchSummary" => pure (base (.event (.branchSummary
            (← Json.getStr? value))))
        | "permissionMode" => pure (base (.event (.permissionMode
            (← Json.getStr? value))))
        | "event" =>
            let label ← piRequireNonemptyString ctx value "label"
            pure (base (.event (.custom label (← piRequireField ctx value "raw"))))
        | "modelChange" =>
            let previous ← piOptionalNullableString ctx value "previous"
            let next ← piOptionalNullableString ctx value "next"
            pure (base (.event (.modelChange previous next)))
        | "thinkingLevelChange" =>
            let previous ← piOptionalNullableString ctx value "previous"
            let next ← piOptionalNullableString ctx value "next"
            pure (base (.event (.thinkingLevelChange previous next)))
        | "compaction" =>
            let summary ← piRequireString ctx value "summary"
            let firstKeptEntryId ← piOptionalNullableString ctx value "firstKeptEntryId"
            let tokensBefore ← piOptionalNullableNat ctx value "tokensBefore"
            pure { (base (.compaction summary .unknownPrefix tokensBefore)) with
              firstKeptEntryId, tokensBefore }
        | "assistantMessage" =>
            let representation ← piRequireNonemptyString ctx value "representation"
            let carried ← piRequireArray ctx value "blocks"
            let (blocks, sourceEntry, sourceBlocks) ← match representation with
              | "inert-unrecorded-metadata" => do
                  let blocks ← carried.toList.zipIdx.mapM (fun (block, blockIdx) =>
                    parseAssistantBlockAt
                      s!"{ctx}.data.value.blocks[{blockIdx}]" none block)
                  pure (blocks, none, [])
              | "historical-assistant-blocks" => do
                  let scope ← piRequireNonemptyString ctx value "scope"
                  if scope != "unsafe" && scope != "full" then
                    piSchemaError ctx s!"unsupported assistant carrier scope '{scope}'"
                  else pure ()
                  let sourceEntry ← piRequireNat ctx value "sourceEntry"
                  let indices ← piRequireArray ctx value "sourceBlockIndices"
                  let sourceBlocks ← indices.toList.zipIdx.mapM (fun (index, indexIdx) =>
                    match Json.getNat? index with
                    | .ok value => pure value
                    | .error _ => piSchemaError
                        s!"{ctx}.data.value.sourceBlockIndices[{indexIdx}]"
                        "source block index must be a natural number")
                  if indices.size != carried.size then
                    piSchemaError ctx
                      "assistant carrier blocks and sourceBlockIndices must have equal length"
                  else pure ()
                  let blocks ← carried.toList.zipIdx.mapM (fun (block, blockIdx) =>
                    piParseHistoricalAssistantBlock
                      s!"{ctx}.data.value.blocks[{blockIdx}]" block)
                  pure (blocks, some sourceEntry, sourceBlocks)
              | other =>
                  piSchemaError ctx
                    s!"unsupported assistant carrier representation '{other}'"
            pure { (base (.assistantMsg blocks)) with
              historicalAssistantSourceEntry := sourceEntry,
              historicalAssistantSourceBlocks := sourceBlocks }
        | "toolResult" =>
            let call ← piRequireObject ctx value "call"
            let callState ← piRequireNonemptyString s!"{ctx}.data.value.call"
              call "state"
            let toolCallId ← piOptionalNullableString ctx value "toolCallId"
            let _ ← piOptionalNullableToolName ctx value
            let content ← piRequireArray ctx value "content"
            let blocks ← content.toList.zipIdx.mapM (fun (block, blockIdx) =>
              parseUserBlockAt s!"{ctx}.data.value.content[{blockIdx}]" block)
            let error ← piCarrierErrorSignal s!"{ctx}.data.value.error"
              (← piRequireObject ctx value "error")
            match callState with
            | "resolved" =>
                let some rawId := toolCallId |
                  piSchemaError ctx "resolved toolResult carrier requires toolCallId"
                let sourceEntry ← piOptionalNat ctx call "sourceEntry"
                let sourceBlock ← piOptionalNat ctx call "sourceBlock"
                if sourceEntry.isSome != sourceBlock.isSome then
                  piSchemaError ctx
                    "resolved toolResult carrier sourceEntry/sourceBlock must appear together"
                else pure ()
                let source := sourceEntry.bind (fun entry =>
                  sourceBlock.map (fun block => (entry, block)))
                pure { (base (.envMsg [])) with
                  toolResultId := some rawId, toolResultError := error,
                  toolResultHistoricalSource := source,
                  toolResultContent := blocks }
            | "unresolved" =>
                let rawId ← piOptionalNullableString ctx call "rawId"
                let note ← piRequireString ctx call "note"
                pure { (base (.envMsg [])) with
                  toolResultId := some (toolCallId.getD piSentinel),
                  toolResultError := error,
                  toolResultForcedUnresolved := some { rawId, note },
                  toolResultContent := blocks }
            | other => piSchemaError ctx s!"unsupported Loom tool-result call state '{other}'"
        | "emptyEnv" =>
            if value == Json.null then pure (base (.envMsg []))
            else piSchemaError ctx "Loom emptyEnv carrier value must be null"
        | "envBlock" =>
            let label ← piRequireString ctx value "label"
            let raw ← piRequireField ctx value "raw"
            pure (base (.envMsg [.unmodeled label raw]))
        | "historicalPayload" =>
            let valueCtx := s!"{ctx}.data.value"
            let payload ← piParseHistoricalPayload valueCtx value
            let (sourceEntry, sourceBlocks) ←
              piParseHistoricalAssistantSource valueCtx value payload
            pure { (base payload) with
              historicalAssistantSourceEntry := sourceEntry,
              historicalAssistantSourceBlocks := sourceBlocks,
              historicalPayloadDirect := true }
        | other => piSchemaError ctx s!"unsupported Loom Pi carrier kind '{other}'"
        pure { restored with
          disposition := .historicalUnverified
          notes := restored.notes ++ [piHistoricalCarrierNote s!"{ctx}.data"] }
      else
        pure { (base (.event (.custom "custom" j))) with
          notes := [piImportNote "pi-unmodeled-entry" s!"line{line}"
            s!"preserved Pi custom entry '{customType}' inertly"] }
  | "custom_message" =>
      let customType ← piRequireNonemptyString ctx j "customType"
      let content ← piRequireField ctx j "content"
      let blocks ← piParseUserContent s!"{ctx}.content" content
      let _ ← piRequireBool ctx j "display"
      if customType == "loom.pi.other-message" then
        let details ← piRequireObject ctx j "details"
        let version ← piRequireNat s!"{ctx}.details" details "version"
        if version != piCarrierVersion then
          piSchemaError ctx s!"unsupported Loom Pi carrier version {version}"
        else pure ()
        let role ← piRequireNonemptyString s!"{ctx}.details" details "role"
        let carried ← piRequireArray s!"{ctx}.details" details "blocks"
        let carriedBlocks ← carried.toList.zipIdx.mapM (fun (block, blockIdx) =>
          parseUserBlockAt s!"{ctx}.details.blocks[{blockIdx}]" block)
        pure { (base (.otherMsg role carriedBlocks)) with
          disposition := .historicalUnverified
          notes := [piHistoricalCarrierNote s!"{ctx}.details"] }
      else
        let historical := piUserContentHasCarrier content
        pure { (base (.otherMsg "custom" blocks)) with
          disposition := if historical then .historicalUnverified else .native
          notes := if historical then
            [piHistoricalCarrierNote s!"{ctx}.content"] else [] }
  | "label" =>
      let _ ← piRequireNonemptyString ctx j "targetId"
      let _ ← piOptionalString ctx j "label"
      pure { (base (.event (.custom "label" j))) with
        notes := [piImportNote "pi-unmodeled-entry" s!"line{line}"
          "preserved Pi label entry inertly"] }
  | "session_info" =>
      let _ ← piOptionalString ctx j "name"
      pure { (base (.event (.custom "session_info" j))) with
        notes := [piImportNote "pi-unmodeled-entry" s!"line{line}"
          "preserved Pi session_info entry inertly"] }
  | other =>
      pure { (base (.event (.custom other j))) with
        notes := [piImportNote "pi-unmodeled-entry" s!"line{line}"
          s!"preserved unknown Pi entry kind '{other}' verbatim"] }

private def rawEntryExtras (r : RawEntry) : Option Json :=
  let fields : List (String × Json) := [("ts", Json.str r.ts)] ++
    (match r.piRaw with | some raw => [("piRaw", raw)] | none => [])
  if fields.isEmpty then none else some (Json.mkObj fields)

private def validateUniquePiEntryIds
    (raws : List RawEntry) (seen : List (String × Nat) := []) : Except String Unit :=
  match raws with
  | [] => pure ()
  | raw :: rest =>
      match seen.find? (fun prior => prior.1 == raw.id) with
      | some (_, priorLine) =>
          piSchemaError s!"record at line {raw.line}"
            s!"field 'id' duplicates '{raw.id}' first seen at line {priorLine}"
      | none => validateUniquePiEntryIds rest ((raw.id, raw.line) :: seen)

private def validatePiRoot : List RawEntry → Except String Unit
  | [] => pure ()
  | root :: rest =>
      if root.parentId.isSome then
        piSchemaError s!"record at line {root.line}"
          "the first session entry must be the root with parentId=null"
      else
        match rest.find? (fun entry => entry.parentId.isNone) with
        | some extraRoot => piSchemaError s!"record at line {extraRoot.line}"
            "only the first session entry may have parentId=null"
        | none => pure ()

private def piParentIndices (raws : List RawEntry) : Except String (List (Option Nat)) := do
  let mut seen : List (String × Nat) := []
  let mut parents : Array (Option Nat) := #[]
  for (raw, entryIdx) in raws.zipIdx do
    let parent ← match raw.parentId with
      | none => pure none
      | some parentId =>
          match seen.find? (fun pair => pair.1 == parentId) with
          | some pair => pure (some pair.2)
          | none =>
              if raws.any (fun candidate => candidate.id == parentId) then
                piSchemaError s!"record at line {raw.line}"
                  s!"parentId '{parentId}' must reference an earlier record"
              else
                piSchemaError s!"record at line {raw.line}"
                  s!"parentId references unknown entry id '{parentId}'"
    parents := parents.push parent
    seen := (raw.id, entryIdx) :: seen
  pure parents.toList

private def piIsAncestorAux (parents : List (Option Nat)) (ancestor : Nat) :
    Nat → Nat → Bool
  | _, 0 => false
  | current, .succ fuel =>
      match parents[current]? with
      | some (some parent) =>
          parent == ancestor || piIsAncestorAux parents ancestor parent fuel
      | _ => false

private def piIsAncestor (parents : List (Option Nat))
    (ancestor descendant : Nat) : Bool :=
  ancestor < descendant &&
    piIsAncestorAux parents ancestor descendant (parents.length + 1)

private structure PiCallOccurrence where
  rawId : String
  entry : Nat
  block : Nat

private def piCallOccurrences (raws : List RawEntry) : List PiCallOccurrence := Id.run do
  let mut calls : Array PiCallOccurrence := #[]
  for (raw, entryIdx) in raws.zipIdx do
    match raw.payload with
    | .assistantMsg blocks =>
        for (block, blockIdx) in blocks.zipIdx do
          match block with
          | .toolCall _ _ (some rawId) =>
              calls := calls.push { rawId, entry := entryIdx, block := blockIdx }
          | _ => pure ()
    | _ => pure ()
  return calls.toList

/-- Resolve only when exactly one matching, earlier, ancestor-path call remains
unmatched. Duplicate occurrences are not ordered guesses, and a second result
cannot reuse an occurrence already consumed by the first. -/
private def piResultRefs (raws : List RawEntry) (parents : List (Option Nat)) :
    List (Nat × CallRef) × List ImportNote := Id.run do
  let calls := piCallOccurrences raws
  let mut refs : List (Nat × CallRef) := []
  let mut used : List (Nat × Nat) := []
  let mut notes : List ImportNote := []
  for (raw, entryIdx) in raws.zipIdx do
    match raw.payload with
    | .envMsg [] =>
        if raw.toolResultId.isNone && raw.toolResultForcedUnresolved.isNone &&
            raw.toolResultHistoricalSource.isNone then
          pure ()
        else match raw.toolResultForcedUnresolved with
        | some forced =>
            refs := refs ++ [(entryIdx, .unresolved forced.rawId forced.note)]
            notes := notes ++ [piImportNote "pi-unresolved-tool-result"
              s!"line{raw.line}.message.{piCarrierKey}.toolCallRef"
              "preserved an explicitly unresolved Loom call reference"]
        | none => match raw.toolResultHistoricalSource with
        | some (sourceEntry, sourceBlock) =>
            let candidates := raws.zipIdx.filterMap (fun (candidate, candidateIdx) =>
              if candidate.historicalAssistantSourceEntry != some sourceEntry then none
              else
                let mapped := candidate.historicalAssistantSourceBlocks.zipIdx.find?
                  (fun pair => pair.1 == sourceBlock)
                match mapped with
                | some (_, mappedBlock) =>
                    calls.find? (fun call =>
                      call.entry == candidateIdx && call.block == mappedBlock &&
                        raw.toolResultId == some call.rawId &&
                        call.entry < entryIdx &&
                        piIsAncestor parents call.entry entryIdx &&
                        !used.contains (call.entry, call.block))
                | none => none)
            match candidates with
            | [call] =>
                refs := refs ++ [(entryIdx, .resolved call.entry call.block)]
                used := (call.entry, call.block) :: used
            | _ =>
                refs := refs ++ [(entryIdx, .unresolved raw.toolResultId
                  "historical toolResult source coordinates do not select exactly one earlier ancestor toolCall")]
                notes := notes ++ [piImportNote "pi-unresolved-tool-result"
                  s!"line{raw.line}.data.value.call"
                  "historical source coordinates did not select exactly one unmatched ancestor toolCall"]
        | none => match raw.toolResultId with
        | none =>
            refs := refs ++ [(entryIdx,
              .unresolved none "validated Pi toolResult unexpectedly has no toolCallId")]
            notes := notes ++ [piImportNote "pi-unresolved-tool-result"
              s!"line{raw.line}.message.toolCallId"
              "validated Pi toolResult unexpectedly has no toolCallId"]
        | some rawId =>
            let candidates := calls.filter (fun call =>
              call.rawId == rawId && call.entry < entryIdx &&
                piIsAncestor parents call.entry entryIdx &&
                !used.contains (call.entry, call.block))
            match candidates with
            | [call] =>
                refs := refs ++ [(entryIdx, .resolved call.entry call.block)]
                used := (call.entry, call.block) :: used
            | [] =>
                refs := refs ++ [(entryIdx, .unresolved (some rawId)
                  "pi toolResult has no unmatched earlier ancestor toolCall occurrence with this id")]
                notes := notes ++ [piImportNote "pi-unresolved-tool-result"
                  s!"line{raw.line}.message.toolCallId"
                  s!"no unmatched earlier ancestor toolCall occurrence has id '{rawId}'"]
            | _ =>
                refs := refs ++ [(entryIdx, .unresolved (some rawId)
                  "pi toolResult matches multiple unmatched ancestor toolCall occurrences")]
                notes := notes ++ [piImportNote "pi-ambiguous-tool-result"
                  s!"line{raw.line}.message.toolCallId"
                  s!"multiple unmatched ancestor toolCall occurrences have id '{rawId}'"]
    | _ => pure ()
  return (refs, notes)

private structure PiHeader where
  id : String
  cwd : String
  ts : String
  raw : Json
  sourceEnvironment : Option EnvInfo := none
  notes : List ImportNote := []

private def parsePiHeader (j : Json) : Except String PiHeader := do
  let ctx := "session header at line 1"
  piEnsureObject ctx j
  let kind ← piRequireNonemptyString ctx j "type"
  if kind != "session" then
    piSchemaError ctx s!"field 'type' must be 'session', got '{kind}'"
  else pure ()
  let id ← piRequireNonemptyString ctx j "id"
  let cwd ← piRequireString ctx j "cwd"
  let version ← piRequireNat ctx j "version"
  if version != 3 then piSchemaError ctx s!"unsupported schema version {version}"
  else pure ()
  let _ ← piOptionalString ctx j "parentSession"
  let ts ← piRequireTimestamp ctx j
  let sourceEnvironment ← piHeaderSourceEnvironment? ctx j
  pure { id, cwd, ts, raw := j, sourceEnvironment }

private def parsePiJsonLine (line : Nat) (text : String) : Except String Json :=
  match Json.parse text with
  | .ok value => pure value
  | .error error => .error s!"malformed Pi JSONL at line {line}: {error}"

/-- pi JSONL → Loom IR. Recognized records are schema-checked before conversion;
unknown kinds remain raw custom events with notes. Unique `parentId` strings are
resolved only against earlier records, and source JSON rides in `Origin` for
faithful re-export. -/
def importPi (text : String) : Except String Transcript := do
  let lines := (text.splitOn "\n").filter (fun l => !l.isEmpty)
  match lines with
  | [] => .error "empty session"
  | header :: rest =>
    let hj ← parsePiJsonLine 1 header
    let parsedHeader ← parsePiHeader hj
    let raws ← rest.zipIdx.mapM (fun (lineText, index) => do
      let line := index + 2
      parseEntry line (← parsePiJsonLine line lineText))
    validateUniquePiEntryIds raws
    validatePiRoot raws
    let parentIndices ← piParentIndices raws
    let idIndex : List (String × Nat) := raws.zipIdx.map (fun (r, i) => (r.id, i))
    let lookup := fun (s : String) => (idIndex.find? (fun p => p.1 == s)).map (·.2)
    let (resultRefs, resultNotes) := piResultRefs raws parentIndices
    let entries ← (raws.zip parentIndices).zipIdx.mapM (fun (item, i) => do
      let r := item.1
      let parent := item.2
      let payloadResult : Except String Payload := match r.payload with
        | .envMsg [] => do
            match r.toolResultId with
            | none => pure (.envMsg [])
            | some _ =>
                let callResult : Except String CallRef :=
                  match (resultRefs.find? (fun pair => pair.1 == i)).map (·.2) with
                  | some ref => pure ref
                  | none => piSchemaError s!"record at line {r.line}"
                      "toolResult linkage was not indexed"
                let call ← callResult
                pure (.envMsg [.toolResult call r.toolResultContent
                  r.toolResultError])
        | payload@(.compaction summary _ tokensBefore) => do
            if r.historicalPayloadDirect then pure payload else
            let coverageResult : Except String CompactionCoverage := match r.firstKeptEntryId with
              | none => pure CompactionCoverage.unknownPrefix
              | some firstKeptId =>
                  match lookup firstKeptId with
                  | some firstKept => pure (.knownPrefix firstKept)
                  | none => piSchemaError s!"record at line {r.line}"
                      s!"firstKeptEntryId references unknown entry id '{firstKeptId}'"
            let coverage ← coverageResult
            pure (.compaction summary coverage tokensBefore)
        | other => pure other
      let payload ← payloadResult
      let entry : Entry := {
        parent := parent,
        thread := 0,
        time := r.timeOverride.getD (.recorded ((iso8601ToEpochMs? r.ts).getD ⟨0⟩)),
        payload := payload,
        origin := { format := .pi, sourceRef := s!"line{r.line}", rawId := some r.id,
                    extras := rawEntryExtras r },
        disposition := r.disposition }
      pure entry)
    let headerExtras := Json.mkObj ([
      ("ts", Json.str parsedHeader.ts), ("piRaw", parsedHeader.raw)] ++
      (match parsedHeader.sourceEnvironment with
       | some source => [
           (piSourceEnvironmentExtraKey, piSourceEnvironmentJson source)]
       | none => []))
    let activeLeaf := if entries.isEmpty then none else some (entries.length - 1)
    pure {
      threads := #[{ kind := .main }],
      entries := entries.toArray,
      env := { cwd := some parsedHeader.cwd, sessionId := some parsedHeader.id },
      activeLeaf := activeLeaf,
      importNotes := parsedHeader.notes ++ raws.flatMap (fun raw => raw.notes) ++
        resultNotes,
      origin := { format := .pi, sourceRef := "importPi", rawId := some parsedHeader.id,
                  extras := some headerExtras }
    }

private def piValidateTimestampValue (ctx value : String) : Except String Unit :=
  if (iso8601ToEpochMs? value).isSome then pure ()
  else .error s!"{ctx} must be UTC ISO-8601 with optional seconds or exactly millisecond precision"

private def piValidateOriginTimestamp (ctx : String) (origin : Origin) : Except String Unit := do
  match origin.extras with
  | some extras =>
      match extras.getObjVal? "ts" with
      | .ok (.str value) => piValidateTimestampValue s!"{ctx}.ts" value
      | .ok _ => .error s!"{ctx}.ts must be a string"
      | .error _ => pure ()
  | none => pure ()
  match piRawEntry origin with
  | some raw =>
      match raw.getObjVal? "timestamp" with
      | .ok (.str value) => piValidateTimestampValue s!"{ctx}.piRaw.timestamp" value
      | .ok _ => .error s!"{ctx}.piRaw.timestamp must be a string"
      | .error _ => pure ()
  | none => pure ()

private def piTranscriptIsAncestorAux (t : Transcript) (ancestor : Nat) :
    Nat → Nat → Bool
  | _, 0 => false
  | current, .succ fuel =>
      match t.entries[current]? with
      | some entry =>
          match entry.parent with
          | some parent =>
              parent == ancestor || piTranscriptIsAncestorAux t ancestor parent fuel
          | none => false
      | none => false

private def piTranscriptIsAncestor (t : Transcript)
    (ancestor descendant : Nat) : Bool :=
  ancestor != descendant &&
    piTranscriptIsAncestorAux t ancestor descendant (t.entries.size + 1)

private def piNativeToolCallIds (t : Transcript) : List String :=
  t.entries.toList.zipIdx.flatMap (fun (entry, entryIdx) =>
    match entry.payload with
    | .assistantMsg blocks => blocks.zipIdx.filterMap (fun (block, blockIdx) =>
        if !piCallBlockIsNative t entryIdx blockIdx then none else
        match block with
        | .toolCall _ _ (some rawId) => some rawId
        | _ => none)
    | _ => [])

private def piValidateResolvedToolResults (t : Transcript) : Except String Unit := do
  let nativeIds := piNativeToolCallIds t
  for (entry, entryIdx) in t.entries.toList.zipIdx do
    if entry.disposition != EntryDisposition.native then pure () else
    match entry.payload with
    | .envMsg blocks =>
        for (block, blockIdx) in blocks.zipIdx do
          match block with
          | .toolResult (.resolved callEntry callBlock) _ _ =>
              let call ← match t.entries[callEntry]? with
                | some { payload := .assistantMsg calls, .. } =>
                    match calls[callBlock]? with
                    | some (.toolCall name arguments rawId) =>
                        pure (name, arguments, rawId)
                    | _ => .error s!"entries[{entryIdx}].env[{blockIdx}] resolves to a non-tool-call block"
                | _ => .error s!"entries[{entryIdx}].env[{blockIdx}] resolves to a non-assistant entry"
              let (name, arguments, rawId) := call
              if !piCallBlockIsNative t callEntry callBlock then pure ()
              else
                let id ← match arguments, nonemptyString rawId,
                    nonemptyString (some name.raw) with
                  | .obj _, some id, some _ => pure id
                  | _, _, _ => .error s!"entries[{entryIdx}].env[{blockIdx}] resolves to a tool call that Pi cannot identify natively"
                if nativeIds.count id != 1 then
                  .error s!"entries[{entryIdx}].env[{blockIdx}] resolves through non-unique Pi toolCall id '{id}'"
                else if !piTranscriptIsAncestor t callEntry entryIdx then
                  .error s!"entries[{entryIdx}].env[{blockIdx}] resolves to a tool call outside its ancestor path"
                else pure ()
          | _ => pure ()
    | _ => pure ()

private def piRequiredTargetOptionKeys : List String :=
  ["target_session_id", "target_cwd", "target_provider", "target_model",
   "target_timestamp", "target_harness_version"]

private def piTargetOptionPresent (t : Transcript) (key : String) : Bool :=
  t.origin.extras.any (fun extras => (extras.getObjVal? key).toOption.isSome)

private def piRequireTargetString
    (t : Transcript) (key : String) : Except String String := do
  let extras ← match t.origin.extras with
    | some extras => pure extras
    | none => .error s!"Pi target requires explicit origin.extras.{key}"
  match extras.getObjVal? key with
  | .error _ => .error s!"Pi target requires explicit origin.extras.{key}"
  | .ok (.str value) =>
      if value.isEmpty then .error s!"origin.extras.{key} must not be empty"
      else pure value
  | .ok _ => .error s!"origin.extras.{key} must be a string"

private def piValidateTargetOptions (t : Transcript) : Except String Unit := do
  let targetBundleRequested := !piSourceNative t ||
    piRequiredTargetOptionKeys.any (piTargetOptionPresent t) ||
    piTargetOptionPresent t "pi_assistant_history"
  if targetBundleRequested then
    for key in piRequiredTargetOptionKeys do
      let _ ← piRequireTargetString t key
  else pure ()
  if piTargetOptionPresent t "target_timestamp" then
    piValidateTimestampValue "origin.extras.target_timestamp"
      (← piRequireTargetString t "target_timestamp")
  else pure ()
  if piTargetOptionPresent t "target_harness_version" then
    let version ← piRequireTargetString t "target_harness_version"
    if version == piTargetVersion then pure ()
    else .error s!"origin.extras.target_harness_version must be {piTargetVersion}"
  else pure ()
  if piTargetOptionPresent t "pi_assistant_history" then
    let mode ← piRequireTargetString t "pi_assistant_history"
    if mode == "context" || mode == "carrier" then pure ()
    else .error "origin.extras.pi_assistant_history must be 'context' or 'carrier'"
  else pure ()
  match targetProvider t, targetModel t with
  | some provider, some model =>
      if provider == piHistoryProvider && model == piHistoryModel then
        .error "Pi target provider/model must differ from the reserved assistant-history identity"
      else pure ()
  | _, _ => pure ()

/-- Validate Pi target prerequisites without rendering or reparsing an artifact. -/
def piExportPreflight (t : Transcript) : Except String Unit := do
  let sourceViolations := violations t
  if sourceViolations.isEmpty then pure ()
  else
    .error s!"Pi source transcript has structural violations: {reprStr sourceViolations}"
  piValidateTargetOptions t
  if piUsesTargetOptions t && !piTargetPreservesSourceEnvironment t then
    .error "Pi target cannot preserve source EnvInfo in its session-header carrier"
  else pure ()
  piValidateOriginTimestamp "transcript.origin" t.origin
  if (piSessionId t).isNone then
    .error "Pi export requires origin.extras.target_session_id (source-native Pi may reuse its session id)"
  else pure ()
  if (piCwd t).isNone then
    .error "Pi export requires origin.extras.target_cwd (source-native Pi may reuse its cwd)"
  else pure ()
  if (piHeaderTimestamp t).isNone then
    .error "Pi export requires origin.extras.target_timestamp (source-native Pi may reuse its session timestamp)"
  else pure ()
  for (entry, entryIdx) in t.entries.toList.zipIdx do
    piValidateOriginTimestamp s!"entries[{entryIdx}].origin" entry.origin
    if (piEntryTimestamp? t entry).isNone then
      .error s!"entries[{entryIdx}] requires a source timestamp, recorded/interpolated time, or target_timestamp"
    else pure ()
  piValidateResolvedToolResults t
  match t.activeLeaf with
  | none =>
      if t.entries.isEmpty then pure ()
      else .error "Pi export requires activeLeaf for a nonempty transcript"
  | some active =>
      if active >= t.entries.size then .error s!"activeLeaf {active} is out of range"
      else if t.entries.toList.any (fun entry => entry.parent == some active) then
        .error s!"activeLeaf {active} has a child and cannot be Pi's terminal record"
      else pure ()

/-- Checked Pi exporter. It validates every preferred timestamp, enforces a
real active leaf, then re-imports the candidate so raw overlays cannot bypass
the same schema checks applied to external artifacts. -/
def exportPiChecked (t : Transcript) : Except String String := do
  piExportPreflight t
  let output := renderPiCandidate t
  let restored ← importPi output
  let restoredViolations := violations restored
  if restoredViolations.isEmpty then pure ()
  else
    .error s!"Pi exported artifact restored with structural violations: {reprStr restoredViolations}"
  let idPlan := piEntryIdPlan t
  let expectedId :=
    if piShouldAppendTargetModelChange t then
      some (piTargetModelChangeId t idPlan)
    else t.activeLeaf.map (piEntryLastId idPlan)
  match expectedId with
  | none => pure output
  | some expectedId =>
      let actualId := restored.activeLeaf.bind (fun leaf =>
        (restored.entries[leaf]?).bind (fun entry => entry.origin.rawId))
      if actualId == some expectedId then pure output
      else .error s!"Pi active-leaf round trip selected {actualId}, expected '{expectedId}'"

/-- Compatibility API used by the other Loom modules. A checked-export failure
returns no artifact; callers that need diagnostics use `exportPiChecked`. -/
def exportPi (t : Transcript) : String :=
  match exportPiChecked t with
  | .ok output => output
  | .error _ => ""

/-! ## Actuator: the only IO. Thin by construction. -/

def importPiFile (path : System.FilePath) : IO (Except String Transcript) := do
  let text ← IO.FS.readFile path
  pure (importPi text)

def exportPiFile (path : System.FilePath) (t : Transcript) : IO Unit :=
  match exportPiChecked t with
  | .ok output => IO.FS.writeFile path output
  | .error message => throw (IO.userError message)

/-! ## Pi 0.74.0 schema and fidelity pins -/

private def piTestTimestamp : String := "2024-01-01T00:00:00.000Z"

private def piTestUsage : Json := Json.mkObj [
  ("input", Json.num 11), ("output", Json.num 7),
  ("cacheRead", Json.num 3), ("cacheWrite", Json.num 2),
  ("totalTokens", Json.num 23),
  ("cost", Json.mkObj [
    ("input", Json.num 1), ("output", Json.num 2),
    ("cacheRead", Json.num 3), ("cacheWrite", Json.num 4),
    ("total", Json.num 10)])]

private def piTestHeader (extras : List (String × Json) := []) : Json :=
  Json.mkObj ([
    ("type", Json.str "session"), ("version", Json.num 3),
    ("id", Json.str "pi-test"), ("timestamp", Json.str piTestTimestamp),
    ("cwd", Json.str "/tmp/pi-test")] ++ extras)

private def piTestEntry (kind id : String) (parent : Option String)
    (fields : List (String × Json)) : Json :=
  Json.mkObj ([
    ("type", Json.str kind), ("id", Json.str id),
    ("parentId", match parent with
      | some parentId => Json.str parentId
      | none => Json.null),
    ("timestamp", Json.str piTestTimestamp)] ++ fields)

private def piTestUserMessage (content : Json) : Json :=
  Json.mkObj [
    ("role", Json.str "user"), ("content", content),
    ("timestamp", Json.num 1704067200000)]

private def piTestAssistantMessage (content : Array Json)
    (stopReason : String := "stop") (errorMessage : Option String := none) : Json :=
  Json.mkObj ([
    ("role", Json.str "assistant"), ("content", Json.arr content),
    ("api", Json.str "anthropic-messages"),
    ("provider", Json.str "anthropic"), ("model", Json.str "fixture-model"),
    ("usage", piTestUsage), ("stopReason", Json.str stopReason),
    ("timestamp", Json.num 1704067200000)] ++
    (match errorMessage with
     | some message => [("errorMessage", Json.str message)]
     | none => []))

private def piTestToolResultMessage (callId toolName : String) (isError : Bool)
    (text : String) : Json :=
  Json.mkObj [
    ("role", Json.str "toolResult"), ("toolCallId", Json.str callId),
    ("toolName", Json.str toolName),
    ("content", Json.arr #[Json.mkObj [
      ("type", Json.str "text"), ("text", Json.str text)]]),
    ("isError", Json.bool isError), ("timestamp", Json.num 1704067200000)]

private def piTestMessageEntry (id : String) (parent : Option String)
    (message : Json) : Json :=
  piTestEntry "message" id parent [("message", message)]

private def piTestFixture (records : List Json)
    (header : Json := piTestHeader) : String :=
  String.intercalate "\n" ((header :: records).map Json.compress) ++ "\n"

private def piTestJsonLines (text : String) : List Json :=
  (text.splitOn "\n").filterMap (fun line =>
    if line.isEmpty then none else (Json.parse line).toOption)

private def piTestRejected (text : String) : Bool :=
  match importPi text with
  | .error _ => true
  | .ok _ => false

private def piTestCheckedRejected (transcript : Transcript) : Bool :=
  match exportPiChecked transcript with
  | .error _ => true
  | .ok _ => false

private def piTestExactCycle (source : String) : Bool :=
  match importPi source with
  | .error _ => false
  | .ok imported =>
      match exportPiChecked imported with
      | .error _ => false
      | .ok first =>
          piTestJsonLines first == piTestJsonLines source &&
            match importPi first with
            | .error _ => false
            | .ok restored =>
                match exportPiChecked restored with
                | .error _ => false
                | .ok second => piTestJsonLines second == piTestJsonLines first

private def piTestStableExport (transcript : Transcript) : Bool :=
  match exportPiChecked transcript with
  | .error _ => false
  | .ok first =>
      match importPi first with
      | .error _ => false
      | .ok restored =>
          match exportPiChecked restored with
          | .error _ => false
          | .ok second => piTestJsonLines second == piTestJsonLines first

private def piNativeShapeFixture : String :=
  piTestFixture [
    piTestMessageEntry "string-user" none
      (piTestUserMessage (Json.str "native string content")),
    piTestMessageEntry "image-user" (some "string-user")
      (piTestUserMessage (Json.arr #[Json.mkObj [
        ("type", Json.str "image"), ("mimeType", Json.str "image/png"),
        ("data", Json.str "aGVsbG8="), ("imageExtension", Json.num 7)]])),
    piTestMessageEntry "bash" (some "image-user") (Json.mkObj [
      ("role", Json.str "bashExecution"), ("command", Json.str "pwd"),
      ("output", Json.str "/tmp/pi-test"), ("exitCode", Json.num 0),
      ("cancelled", Json.bool false), ("truncated", Json.bool false),
      ("fullOutputPath", Json.str "/tmp/pi-output"),
      ("excludeFromContext", Json.bool true),
      ("timestamp", Json.num 1704067200000),
      ("bashExtension", Json.str "retained")])]

def piNativeStringImageAndBashPinned : Bool :=
  ostr (userBlockToJson (.media "image/png" "data")) "type" == some "image" &&
    match importPi piNativeShapeFixture with
    | .error _ => false
    | .ok transcript =>
        (match transcript.entries[0]?, transcript.entries[1]?, transcript.entries[2]? with
         | some user, some image, some bash =>
             match user.payload, image.payload, bash.payload with
             | .userMsg [.text "native string content"],
               .userMsg [.media "image/png" "aGVsbG8="],
               .otherMsg "bashExecution" [.unmodeled "bashExecution" _] => true
             | _, _, _ => false
         | _, _, _ => false) && piTestExactCycle piNativeShapeFixture

example : piNativeStringImageAndBashPinned = true := by native_decide

private def piStrictBadFixtures : List String := [
  piTestFixture [] (Json.mkObj [
    ("type", Json.str "session"), ("version", Json.num 3),
    ("id", Json.str "missing-time"), ("cwd", Json.str "/tmp")]),
  piTestFixture [] (piTestHeader [("parentSession", Json.num 7)]),
  piTestFixture [Json.mkObj [
    ("type", Json.str "message"), ("id", Json.str "missing-parent"),
    ("timestamp", Json.str piTestTimestamp),
    ("message", piTestUserMessage (Json.str "x"))]],
  piTestFixture [Json.mkObj [
    ("type", Json.str "message"), ("id", Json.str "missing-time"),
    ("parentId", Json.null),
    ("message", piTestUserMessage (Json.str "x"))]],
  piTestFixture [piTestMessageEntry "bad-root" (some "future")
    (piTestUserMessage (Json.str "x"))],
  piTestFixture [
    piTestMessageEntry "root" none (piTestUserMessage (Json.str "x")),
    piTestMessageEntry "second-root" none (piTestUserMessage (Json.str "y"))],
  piTestFixture [piTestMessageEntry "message-time" none (Json.mkObj [
    ("role", Json.str "user"), ("content", Json.str "x")])],
  piTestFixture [piTestMessageEntry "assistant-api" none
    (overlayJsonFields (piTestAssistantMessage #[]) ["api"] [])],
  piTestFixture [piTestMessageEntry "assistant-args" none
    (piTestAssistantMessage #[Json.mkObj [
      ("type", Json.str "toolCall"), ("id", Json.str "c"),
      ("name", Json.str "read"), ("arguments", Json.arr #[]) ]])],
  piTestFixture [piTestMessageEntry "assistant-signature" none
    (piTestAssistantMessage #[Json.mkObj [
      ("type", Json.str "text"), ("text", Json.str "x"),
      ("textSignature", Json.bool false)]])],
  piTestFixture [piTestMessageEntry "result-name" none
    (overlayJsonFields (piTestToolResultMessage "c" "read" false "x")
      ["toolName"] [])],
  piTestFixture [piTestEntry "compaction" "compact" none [
    ("summary", Json.str "s"), ("firstKeptEntryId", Json.str "compact")]],
  piTestFixture [piTestEntry "branch_summary" "summary" none [
    ("summary", Json.str "s")]],
  piTestFixture [piTestEntry "branch_summary" "summary" none [
    ("fromId", Json.str "root"), ("summary", Json.str "s"),
    ("fromHook", Json.str "yes")]],
  piTestFixture [piTestMessageEntry "bad-stop" none
    (piTestAssistantMessage #[] "finished")],
  piTestFixture [piTestMessageEntry "bad-error" none
    (overlayJsonFields (piTestAssistantMessage #[] "error" (some "boom"))
      ["errorMessage"] [("errorMessage", Json.bool true)])]
]

def piCurrentSchemaRejectsMalformedRecognizedRecords : Bool :=
  piStrictBadFixtures.length == 16 && piStrictBadFixtures.all piTestRejected

example : piCurrentSchemaRejectsMalformedRecognizedRecords = true := by native_decide

private def piMetadataFixtureV3 : String :=
  piTestFixture [
    piTestMessageEntry "root" none (piTestUserMessage (Json.str "root")),
    piTestEntry "branch_summary" "summary" (some "root") [
      ("fromId", Json.str "root"), ("summary", Json.str "branch"),
      ("details", Json.mkObj [("kept", Json.bool true)]),
      ("fromHook", Json.bool false)],
    piTestEntry "compaction" "compact" (some "summary") [
      ("summary", Json.str "history"),
      ("firstKeptEntryId", Json.str "root"),
      ("tokensBefore", Json.num 42),
      ("details", Json.mkObj [("kind", Json.str "native")]),
      ("fromHook", Json.bool true)]]

def piCompactionAndBranchSummaryPinned : Bool :=
  match importPi piMetadataFixtureV3 with
  | .error _ => false
  | .ok transcript =>
      (match transcript.entries[1]?, transcript.entries[2]? with
       | some summary, some compaction =>
           match summary.payload, compaction.payload with
           | .event (.branchSummary "branch"),
             .compaction "history" (.knownPrefix 0) (some 42) => true
           | _, _ => false
       | _, _ => false) && piTestExactCycle piMetadataFixtureV3

example : piCompactionAndBranchSummaryPinned = true := by native_decide

private def piTargetTestOptions (mode : Option String := none) : Json :=
  Json.mkObj ([
    ("target_session_id", Json.str "pi-target-session"),
    ("target_cwd", Json.str "/tmp/pi-target"),
    ("target_provider", Json.str "target-provider"),
    ("target_model", Json.str "target-model"),
    ("target_timestamp", Json.str piTestTimestamp),
    ("target_harness_version", Json.str piTargetVersion)] ++
    (match mode with
     | some value => [("pi_assistant_history", Json.str value)]
     | none => []))

private def piForeignExportOptions : Json := piTargetTestOptions

private def piForeignOrigin (id : String)
    (extras : Option Json := none) : Origin :=
  { format := .claudeCode, sourceRef := "pi-foreign-fixture",
    rawId := some id, extras }

private def piForeignTranscriptOrigin (sourceRef : String)
    (extras : Option Json := none) : Origin :=
  { format := .claudeCode, sourceRef, rawId := none, extras }

private def piSiblingLeafTranscript : Transcript := {
  threads := #[{ kind := .main }],
  entries := #[
    { time := .recorded ⟨1704067200000⟩,
      payload := .userMsg [.text "root"], origin := piForeignOrigin "root" },
    { parent := some 0, time := .recorded ⟨1704067200001⟩,
      payload := .userMsg [.text "left"], origin := piForeignOrigin "left" },
    { parent := some 0, time := .recorded ⟨1704067200002⟩,
      payload := .userMsg [.text "right"], origin := piForeignOrigin "right" }],
  env := { cwd := some "/tmp/pi-test", sessionId := some "sibling-leaf" },
  activeLeaf := some 1,
  importNotes := [],
  origin := piForeignTranscriptOrigin "pi-sibling-leaf"
    (some piForeignExportOptions)
}

def piSiblingActiveLeafPinned : Bool :=
  match exportPiChecked piSiblingLeafTranscript with
  | .error _ => false
  | .ok output =>
      let ids := (piTestJsonLines output).drop 1 |>.filterMap
        (fun record => ostr record "id")
      ids == ["root", "right", "left", "loom-target-model"] &&
        output.endsWith "\n" &&
        match importPi output with
        | .error _ => false
        | .ok restored =>
            restored.activeLeaf == some 3 &&
              restored.entries[2]?.bind (fun entry => entry.origin.rawId) ==
                some "left" &&
              restored.entries.toList.map (fun entry => entry.parent) ==
                [none, some 0, some 0, some 2] &&
              match exportPiChecked restored with
              | .error _ => false
              | .ok second => piTestJsonLines second == piTestJsonLines output

example : piSiblingActiveLeafPinned = true := by native_decide

private def piHistoricalBranchTranscript : Transcript := {
  threads := #[{ kind := .main }],
  entries := #[
    { time := .recorded ⟨1704067200000⟩,
      payload := .userMsg [.text "root"],
      origin := piForeignOrigin "branch-root" },
    { parent := some 0, time := .recorded ⟨1704067200001⟩,
      payload := .assistantMsg [.text "selected branch"],
      origin := piForeignOrigin "branch-active" },
    { parent := some 0, time := .recorded ⟨1704067200002⟩,
      payload := .assistantMsg [
        .thinking "abandoned reasoning" (some "abandoned-signature"),
        .toolCall { raw := "abandoned_exec", canonical := some .bash }
          (Json.mkObj [("cmd", Json.str "pwd")]) (some "abandoned-call")],
      origin := piForeignOrigin "branch-call",
      disposition := .historicalUnverified },
    { parent := some 2, time := .recorded ⟨1704067200003⟩,
      payload := .envMsg [.toolResult (.resolved 2 1)
        [.text "abandoned output"] (.native false)],
      origin := piForeignOrigin "branch-result",
      disposition := .historicalUnverified }],
  env := { cwd := some "/source/branch", model := some "source-model", provider := some "source-provider", sessionId := some "source-branch" },
  activeLeaf := some 1,
  importNotes := [],
  origin := piForeignTranscriptOrigin "pi-historical-branch"
    (some piForeignExportOptions)
}

private def piHistoricalBranchShape (transcript : Transcript) : Bool :=
  (violations transcript).isEmpty && transcript.entries.size == 5 &&
    transcript.entries.toList.map (fun entry => entry.parent) ==
      [none, some 0, some 1, some 0, some 3] &&
    match transcript.entries[1]?, transcript.entries[2]? with
    | some call, some result =>
        call.disposition == EntryDisposition.historicalUnverified &&
          result.disposition == EntryDisposition.historicalUnverified &&
          (match call.payload with
           | .assistantMsg [
               .thinking "abandoned reasoning" (some "abandoned-signature"),
               .toolCall name _ (some "abandoned-call")] =>
                 name.raw == "abandoned_exec" && name.canonical == some .bash
           | _ => false) &&
          (match result.payload with
           | .envMsg [.toolResult (.resolved 1 1)
               [.text "abandoned output"] (.native false)] => true
           | _ => false)
    | _, _ => false

/-- Physical export order, not source-array position, is the namespace for
positional references stored inside historical payload carriers. -/
def piHistoricalBranchCallRefRemapPinned : Bool :=
  piNativeToolCallCount piHistoricalBranchTranscript == 0 &&
    piTargetSummary piHistoricalBranchTranscript == {
      nativeAssistantContextMessages := 1
      historicalAssistantCarriers := 1
      historicalToolCallCarriers := 1
      historicalToolResultCarriers := 1
      resumable := true } &&
    match exportPiChecked piHistoricalBranchTranscript with
    | .error _ => false
    | .ok first =>
        let records := (piTestJsonLines first).drop 1
        let carriedCallEntry := do
          let result ← records[2]?
          let data ← oobj result "data"
          let value ← oobj data "value"
          let blocks ← oarr value "blocks"
          let block ← blocks[0]?
          let call ← oobj block "call"
          onat call "entry"
        carriedCallEntry == some 1 &&
          match importPi first with
          | .error _ => false
          | .ok restored =>
              piHistoricalBranchShape restored &&
                match exportPiChecked restored with
                | .error _ => false
                | .ok second =>
                    piTestJsonLines second == piTestJsonLines first &&
                      match importPi second with
                      | .error _ => false
                      | .ok secondRestored =>
                          piHistoricalBranchShape secondRestored

example : piHistoricalBranchCallRefRemapPinned = true := by native_decide

def piInvalidActiveLeafRefused : Bool :=
  piTestCheckedRejected { piSiblingLeafTranscript with activeLeaf := none } &&
    piTestCheckedRejected { piSiblingLeafTranscript with activeLeaf := some 0 } &&
    piTestCheckedRejected { piSiblingLeafTranscript with activeLeaf := some 9 }

example : piInvalidActiveLeafRefused = true := by native_decide

private def piTimestampTranscript : Transcript := {
  threads := #[{ kind := .main }],
  entries := #[
    { time := .recorded ⟨0⟩, payload := .userMsg [.text "source time"],
      origin := piForeignOrigin "source-time" (some (Json.mkObj [
        ("ts", Json.str "2024-07-03T09:46:40.001Z")])) },
    { parent := some 0, time := .absent,
      payload := .userMsg [.text "target fallback"],
      origin := piForeignOrigin "target-time" }],
  env := { cwd := some "/tmp/pi-test", sessionId := some "timestamps" },
  activeLeaf := some 1,
  importNotes := [],
  origin := piForeignTranscriptOrigin "pi-timestamps"
    (some piForeignExportOptions)
}

private def piInvalidSourceTimestampTranscript : Transcript := {
  threads := #[{ kind := .main }],
  entries := #[{
    payload := .userMsg [.text "bad source"],
    origin := piForeignOrigin "bad-source" (some (Json.mkObj [
      ("ts", Json.str "SOURCE-TIME")])) }],
  env := { cwd := some "/tmp/pi-test", sessionId := some "bad-source" },
  activeLeaf := some 0,
  importNotes := [],
  origin := piForeignTranscriptOrigin "pi-bad-source"
    (some piForeignExportOptions)
}

def piTimestampSelectionAndValidationPinned : Bool :=
  match exportPiChecked piTimestampTranscript with
  | .error _ => false
  | .ok output =>
      let records := (piTestJsonLines output).drop 1 |>.take 2
      let entryTimes := records.map (fun record => ostr record "timestamp")
      let messageTimes := records.map (fun record =>
        (oobj record "message").bind (fun message => onat message "timestamp"))
      entryTimes == [some "1970-01-01T00:00:00.000Z", some piTestTimestamp] &&
        messageTimes == [some 0, some 1704067200000] &&
        match importPi output with
        | .error _ => false
        | .ok restored =>
            match exportPiChecked restored with
            | .error _ => false
            | .ok second => piTestJsonLines second == piTestJsonLines output

example : piTimestampSelectionAndValidationPinned = true := by native_decide

def piInvalidPreferredTimestampsRefused : Bool :=
  piTestCheckedRejected piInvalidSourceTimestampTranscript &&
    piTestCheckedRejected {
      piTimestampTranscript with
      origin := piForeignTranscriptOrigin "pi-missing-target" } &&
    piTestCheckedRejected {
      piTimestampTranscript with
      origin := piForeignTranscriptOrigin "pi-bad-history"
        (some (piTargetTestOptions (some "native"))) } &&
    piTestCheckedRejected {
      piTimestampTranscript with
      origin := piForeignTranscriptOrigin "pi-bad-target" (some
        (overlayJsonFields piForeignExportOptions ["target_timestamp"] [
          ("target_timestamp", Json.str "not-a-time")])) }

example : piInvalidPreferredTimestampsRefused = true := by native_decide

def piPublicExportPreflightPinned : Bool :=
  (match piExportPreflight piTimestampTranscript with
   | .ok _ => true
   | .error _ => false) &&
    (match piExportPreflight {
        piTimestampTranscript with
        origin := piForeignTranscriptOrigin "pi-preflight-bad" (some
          (overlayJsonFields piForeignExportOptions ["target_timestamp"] [
            ("target_timestamp", Json.str "invalid")])) } with
     | .error _ => true
     | .ok _ => false)

example : piPublicExportPreflightPinned = true := by native_decide

private def piCallBlock (id name : String) : Json :=
  Json.mkObj [
    ("type", Json.str "toolCall"), ("id", Json.str id),
    ("name", Json.str name), ("arguments", Json.mkObj [])]

private def piNativeStopFixture : String :=
  piTestFixture [
    piTestMessageEntry "stop" none (piTestAssistantMessage #[Json.mkObj [
      ("type", Json.str "text"), ("text", Json.str "done"),
      ("textSignature", Json.str "sig")]] "stop"),
    piTestMessageEntry "aborted" (some "stop")
      (piTestAssistantMessage #[] "aborted" (some "cancelled by user")),
    piTestMessageEntry "error" (some "aborted")
      (piTestAssistantMessage #[] "error" (some "provider failed"))]

def piAssistantStopAndErrorPinned : Bool :=
  match importPi piNativeStopFixture with
  | .error _ => false
  | .ok transcript =>
      match exportPiChecked transcript with
      | .error _ => false
      | .ok output =>
          let messages := (piTestJsonLines output).drop 1 |>.filterMap
            (fun entry => oobj entry "message")
          messages.map (fun message =>
              (ostr message "stopReason", ostr message "errorMessage")) ==
            [(some "stop", none), (some "aborted", some "cancelled by user"),
             (some "error", some "provider failed")] &&
            piTestExactCycle piNativeStopFixture

example : piAssistantStopAndErrorPinned = true := by native_decide

private def piToolLinkageFixture : String :=
  piTestFixture [
    piTestMessageEntry "calls" none (piTestAssistantMessage #[
      piCallBlock "unique-false" "read", piCallBlock "unique-true" "bash",
      piCallBlock "duplicate" "first", piCallBlock "duplicate" "second"]
      "toolUse"),
    piTestMessageEntry "unique-false-result" (some "calls")
      (piTestToolResultMessage "unique-false" "read" false "ok"),
    piTestMessageEntry "unique-true-result" (some "unique-false-result")
      (piTestToolResultMessage "unique-true" "bash" true "failed"),
    piTestMessageEntry "duplicate-result" (some "unique-true-result")
      (piTestToolResultMessage "duplicate" "first" false "ambiguous"),
    piTestMessageEntry "missing-result" (some "duplicate-result")
      (piTestToolResultMessage "missing" "read" true "orphan"),
    piTestMessageEntry "extra-result" (some "missing-result")
      (piTestToolResultMessage "unique-false" "read" false "second result")]

def piToolLinkageIsEvidenceBounded : Bool :=
  match importPi piToolLinkageFixture with
  | .error _ => false
  | .ok transcript =>
      piNativeToolCallCount transcript == 4 &&
        piHistoricalToolCallCarrierCount transcript == 0 &&
      match transcript.entries[1]?, transcript.entries[2]?,
          transcript.entries[3]?, transcript.entries[4]?, transcript.entries[5]? with
      | some nativeFalse, some nativeTrue, some duplicate,
        some missing, some extra =>
          (match nativeFalse.payload, nativeTrue.payload, duplicate.payload,
              missing.payload, extra.payload with
           | .envMsg [.toolResult (.resolved 0 0) [.text "ok"] (.native false)],
             .envMsg [.toolResult (.resolved 0 1) [.text "failed"] (.native true)],
             .envMsg [.toolResult (.unresolved (some "duplicate") _) _ (.native false)],
             .envMsg [.toolResult (.unresolved (some "missing") _) _ (.native true)],
             .envMsg [.toolResult (.unresolved (some "unique-false") _) _
               (.native false)] => true
           | _, _, _, _, _ => false) && piTestCheckedRejected transcript
      | _, _, _, _, _ => false

example : piToolLinkageIsEvidenceBounded = true := by native_decide

def piCheckedExportRejectsRestoredViolationsPinned : Bool :=
  match importPi piToolLinkageFixture with
  | .error _ => false
  | .ok transcript =>
      !(violations transcript).isEmpty && piTestCheckedRejected transcript

example : piCheckedExportRejectsRestoredViolationsPinned = true := by native_decide

private def piEpistemicTranscript : Transcript := {
  threads := #[{ kind := .main }],
  entries := #[
    { time := .absent, payload := .assistantMsg [
        .toolCall { raw := "native-false" } (Json.mkObj []) (some "c0"),
        .toolCall { raw := "native-true" } (Json.mkObj []) (some "c1"),
        .toolCall { raw := "inferred" } (Json.mkObj []) (some "c2"),
        .toolCall { raw := "unrecorded" } (Json.mkObj []) (some "c3")],
      origin := piForeignOrigin "calls" },
    { parent := some 0, time := .absent,
      payload := .envMsg [.toolResult (.resolved 0 0) [.text "false"]
        (.native false)], origin := piForeignOrigin "r0" },
    { parent := some 1, time := .absent,
      payload := .envMsg [.toolResult (.resolved 0 1) [.text "true"]
        (.native true)], origin := piForeignOrigin "r1" },
    { parent := some 2, time := .absent,
      payload := .envMsg [.toolResult (.resolved 0 2) [.text "inferred"]
        (.inferred true "nonzero exit")], origin := piForeignOrigin "r2" },
    { parent := some 3, time := .absent,
      payload := .envMsg [.toolResult (.resolved 0 3) [.text "unknown"]
        .unrecorded], origin := piForeignOrigin "r3" }],
  env := { cwd := some "/tmp/pi-test", model := some "fixture-model", provider := some "anthropic", sessionId := some "epistemics" },
  activeLeaf := some 4,
  importNotes := [],
  origin := piForeignTranscriptOrigin "pi-epistemics" (some piForeignExportOptions)
}

private def piUnrecordedAssistantTranscript : Transcript := {
  threads := #[{ kind := .main }],
  entries := #[{
    time := .absent, payload := .assistantMsg [.text "metadata unknown"],
    origin := piForeignOrigin "assistant" }],
  env := { cwd := some "/tmp/pi-test", sessionId := some "unrecorded-assistant" },
  activeLeaf := some 0,
  importNotes := [],
  origin := piForeignTranscriptOrigin "pi-unrecorded-assistant"
    (some piForeignExportOptions)
}

/-- A foreign tool lifecycle reaches Pi as native, executable Pi constructs.
Every block of this assistant entry is structurally representable — object
arguments, non-empty name and id, unique id, no canonical identity — so the
entry is one context-safe run producing one real `assistant` message carrying
four `toolCall` blocks, answered by four native `toolResult` records.

The four `ErrorSignal` epistemics survive that natively. Pi's wire slot is a
plain `isError` bool, so the exact provenance rides out of band in the reserved
`toolError` stamp and `piToolErrorSignal` reads it back verbatim; the round trip
below pins that. This inverts the previous assertion of zero native calls, which
recorded a policy — native emission only when `origin.format == .pi` and
`ErrorSignal.native` — that made every real conversion 100% inert prose. -/
def piToolErrorEpistemicsPinned : Bool :=
  piNativeToolCallCount piEpistemicTranscript == 4 &&
    piNativeToolResultCount piEpistemicTranscript == 4 &&
    piNativeOpenToolCallCount piEpistemicTranscript == 0 &&
    piHistoricalToolCallCarrierCount piEpistemicTranscript == 0 &&
    piHistoricalToolResultCarrierCount piEpistemicTranscript == 0 &&
  match exportPiChecked piEpistemicTranscript with
  | .error _ => false
  | .ok output =>
      let records := (piTestJsonLines output).drop 1
      let types := records.map (fun entry => ostr entry "type")
      let assistant := records[0]?
      piNativeAssistantContextCount piEpistemicTranscript == 1 &&
        assistant.bind (fun entry => ostr entry "timestamp") ==
          some piTestTimestamp &&
        types == [some "message", some "message", some "message",
          some "message", some "message", some "model_change"] &&
        match importPi output with
        | .error _ => false
        | .ok restored =>
            let errors := restored.entries.toList.filterMap (fun entry =>
              match entry.payload with
              | .envMsg [.toolResult _ _ error] => some error
              | _ => none)
            (match restored.entries[0]? with
             | some calls =>
                 calls.disposition == EntryDisposition.native &&
                   (match calls.payload with
                    | .assistantMsg carried => carried.length == 4
                    | _ => false)
             | none => false) &&
              (restored.entries.toList.drop 1 |>.take 4 |>.all (fun entry =>
                entry.disposition == EntryDisposition.native)) &&
              errors == [.native false, .native true,
                .inferred true "nonzero exit", .unrecorded] &&
              match exportPiChecked restored with
              | .error _ => false
              | .ok second => piTestJsonLines second == piTestJsonLines output

example : piToolErrorEpistemicsPinned = true := by native_decide

def piUnrecordedAssistantMetadataIsStamped : Bool :=
  match exportPiChecked piUnrecordedAssistantTranscript with
  | .error _ => false
  | .ok output =>
      match (piTestJsonLines output)[1]? with
      | none => false
      | some entry =>
          let message := oobj entry "message"
          let stamp := message.bind (fun value => oobj value piCarrierKey)
          let history := stamp.bind (fun value => oobj value "assistantHistory")
          ostr entry "type" == some "message" &&
            message.bind (fun value => ostr value "provider") ==
              some piHistoryProvider &&
            message.bind (fun value => ostr value "model") == some piHistoryModel &&
            message.bind (fun value => oobj value "usage") == some piZeroUsage &&
            history.bind (fun value => ostr value "metadata") ==
              some "synthesized-unrecorded" &&
            history.bind (fun value => ostr value "usage") ==
              some "synthesized-zero-unrecorded" &&
            history.bind (fun value => ostr value "stopReason") ==
              some "synthesized-unrecorded" &&
            match importPi output with
            | .error _ => false
            | .ok restored =>
                (match restored.entries[0]? with
                 | some restoredEntry =>
                     match restoredEntry.payload, restoredEntry.disposition with
                     | .assistantMsg [.text "metadata unknown"],
                       EntryDisposition.native => true
                     | _, _ => false
                 | none => false) && piTestStableExport restored

example : piUnrecordedAssistantMetadataIsStamped = true := by native_decide

private def piCarrierAndAdditiveFixture : String :=
  piTestFixture [
    piTestEntry "custom" "carrier" none [
      ("customType", Json.str "loom.pi.carrier"),
      ("data", Json.mkObj [
        ("version", Json.num piCarrierVersion), ("kind", Json.str "event"),
        ("value", Json.mkObj [
          ("label", Json.str "checkpoint"),
          ("raw", Json.mkObj [("state", Json.str "retained")])]),
        ("dataExtension", Json.arr #[Json.num 1, Json.num 2])]),
      ("outerExtension", Json.mkObj [("kept", Json.bool true)])],
    piTestEntry "custom" "native-custom" (some "carrier") [
      ("customType", Json.str "plugin.state"),
      ("data", Json.mkObj [("cursor", Json.num 9)]),
      ("outerExtension", Json.str "native")],
    piTestEntry "custom_message" "custom-message" (some "native-custom") [
      ("customType", Json.str "plugin.notice"),
      ("content", Json.str "notice"), ("display", Json.bool false),
      ("details", Json.mkObj [("severity", Json.str "low")]),
      ("outerExtension", Json.bool true)]]
    (piTestHeader [("headerExtension", Json.str "retained")])

def piAdditiveAndCarrierCyclePinned : Bool :=
  match importPi piCarrierAndAdditiveFixture with
  | .error _ => false
  | .ok transcript =>
      (match transcript.entries[0]?, transcript.entries[1]?, transcript.entries[2]? with
       | some carrier, some custom, some customMessage =>
           match carrier.payload, custom.payload, customMessage.payload with
           | .event (.custom "checkpoint" raw),
             .event (.custom "custom" _), .otherMsg "custom" [.text "notice"] =>
               ostr raw "state" == some "retained"
           | _, _, _ => false
       | _, _, _ => false) && piTestExactCycle piCarrierAndAdditiveFixture

example : piAdditiveAndCarrierCyclePinned = true := by native_decide

private def piForeignEventTranscript : Transcript := {
  threads := #[{ kind := .main }],
  entries := #[{
    time := .absent,
    payload := .event (.custom "checkpoint" (Json.mkObj [
      ("state", Json.str "foreign")])),
    origin := piForeignOrigin "event" }],
  env := { cwd := some "/tmp/pi-test", sessionId := some "foreign-event" },
  activeLeaf := some 0,
  importNotes := [],
  origin := piForeignTranscriptOrigin "pi-foreign-event"
    (some piForeignExportOptions)
}

private def piInertEnvironmentTranscript : Transcript := {
  threads := #[{ kind := .main }],
  entries := #[
    { time := .absent, payload := .envMsg [],
      origin := piForeignOrigin "empty-env" },
    { parent := some 0, time := .absent,
      payload := .envMsg [.unmodeled "opaque-env" (Json.mkObj [
        ("status", Json.str "unknown")])],
      origin := piForeignOrigin "opaque-env" }],
  env := { cwd := some "/tmp/pi-test", sessionId := some "inert-env" },
  activeLeaf := some 1,
  importNotes := [],
  origin := piForeignTranscriptOrigin "pi-inert-env"
    (some piForeignExportOptions)
}

def piForeignInertCarriersPinned : Bool :=
  piTestStableExport piForeignEventTranscript &&
    match exportPiChecked piInertEnvironmentTranscript with
    | .error _ => false
    | .ok output =>
        match importPi output with
        | .error _ => false
        | .ok restored =>
            (match restored.entries[0]?, restored.entries[1]? with
             | some empty, some opaqueEntry =>
                 match empty.payload, opaqueEntry.payload with
                 | .envMsg [], .envMsg [.unmodeled "opaque-env" raw] =>
                     ostr raw "status" == some "unknown"
                 | _, _ => false
             | _, _ => false) && piTestStableExport restored

example : piForeignInertCarriersPinned = true := by native_decide

private def piUnrepresentableAssistantTranscript : Transcript := {
  threads := #[{ kind := .main }],
  entries := #[{
    time := .absent,
    payload := .assistantMsg [
      .toolCall { raw := "opaque" } (Json.arr #[Json.num 1]) none,
      .media "image/png" "opaque-image"],
    origin := piForeignOrigin "assistant-carriers" }],
  env := { cwd := some "/tmp/pi-test", model := some "fixture-model", provider := some "anthropic", sessionId := some "assistant-carriers" },
  activeLeaf := some 0,
  importNotes := [],
  origin := piForeignTranscriptOrigin "pi-assistant-carriers"
    (some piForeignExportOptions)
}

def piUnrepresentableAssistantBlocksStayInert : Bool :=
  match exportPiChecked piUnrepresentableAssistantTranscript with
  | .error _ => false
  | .ok output =>
      match importPi output with
      | .error _ => false
      | .ok restored =>
          (match restored.entries[0]? with
           | some entry =>
               entry.disposition == EntryDisposition.historicalUnverified &&
               (match entry.payload with
               | .assistantMsg [
                   .toolCall name (.arr values) none,
                   .media "image/png" "opaque-image"] =>
                     name.raw == "opaque" && values == #[Json.num 1]
               | _ => false)
           | none => false) && piTestStableExport restored

example : piUnrepresentableAssistantBlocksStayInert = true := by native_decide

private def piRawAssistantWithoutRequiredFields : Json :=
  piTestMessageEntry "raw-assistant" none (Json.mkObj [
    ("role", Json.str "assistant"),
    ("content", Json.arr #[Json.mkObj [
      ("type", Json.str "text"), ("text", Json.str "raw")]]),
    ("timestamp", Json.num 1704067200000)])

private def piAdversarialEntryOrigin : Origin :=
  { format := .pi, sourceRef := "adversarial-raw",
    rawId := some "raw-assistant", extras := some (Json.mkObj [
      ("ts", Json.str piTestTimestamp),
      ("piRaw", piRawAssistantWithoutRequiredFields)]) }

private def piAdversarialRawTranscript : Transcript := {
  threads := #[{ kind := .main }],
  entries := #[{
    time := .recorded ⟨1704067200000⟩,
    payload := .assistantMsg [.text "raw"],
    origin := piAdversarialEntryOrigin }],
  env := { cwd := some "/tmp/pi-test", model := some "fixture-model", provider := some "anthropic", sessionId := some "adversarial" },
  activeLeaf := some 0,
  importNotes := [],
  origin := piForeignTranscriptOrigin "pi-adversarial"
    (some piForeignExportOptions)
}

private def piDuplicateResolvedTranscript : Transcript := {
  threads := #[{ kind := .main }],
  entries := #[
    { time := .absent, payload := .assistantMsg [
        .toolCall { raw := "first" } (Json.mkObj []) (some "duplicate"),
        .toolCall { raw := "second" } (Json.mkObj []) (some "duplicate")],
      origin := piForeignOrigin "duplicate-calls" },
    { parent := some 0, time := .absent,
      payload := .envMsg [.toolResult (.resolved 0 0) [.text "result"]
        (.native false)], origin := piForeignOrigin "duplicate-result" }],
  env := { cwd := some "/tmp/pi-test", model := some "fixture-model", provider := some "anthropic", sessionId := some "duplicate-resolved" },
  activeLeaf := some 1,
  importNotes := [],
  origin := piForeignTranscriptOrigin "pi-duplicate-resolved"
    (some piForeignExportOptions)
}

def piRawOverlayAndAmbiguousExportRefused : Bool :=
  piTestCheckedRejected piAdversarialRawTranscript &&
    match exportPiChecked piDuplicateResolvedTranscript with
    | .error _ => false
    | .ok output =>
        match importPi output with
        | .error _ => false
        | .ok restored =>
            (match restored.entries[1]? with
             | some result =>
                 result.disposition == EntryDisposition.historicalUnverified &&
                   match result.payload with
                   | .envMsg [.toolResult (.resolved 0 0) [.text "result"]
                       (.native false)] => true
                   | _ => false
             | none => false) && piTestStableExport restored

example : piRawOverlayAndAmbiguousExportRefused = true := by native_decide

private def piAdditionalMalformedFixtures : List String := [
  piTestFixture [piTestMessageEntry "media" none
    (piTestUserMessage (Json.arr #[Json.mkObj [
      ("type", Json.str "media"), ("mimeType", Json.str "image/png"),
      ("data", Json.str "x")]]))],
  piTestFixture [piTestMessageEntry "bash" none (Json.mkObj [
    ("role", Json.str "bashExecution"), ("command", Json.str "pwd"),
    ("output", Json.str "x"), ("truncated", Json.bool false),
    ("timestamp", Json.num 1704067200000)])],
  piTestFixture [piTestMessageEntry "diagnostics" none
    (overlayJsonFields (piTestAssistantMessage #[]) ["diagnostics"] [
      ("diagnostics", Json.arr #[Json.mkObj [
        ("type", Json.str "provider"), ("timestamp", Json.num 1),
        ("details", Json.str "not-an-object")]])])],
  piTestFixture [piTestEntry "custom_message" "custom-message" none [
    ("customType", Json.str "plugin"), ("content", Json.str "x")]],
  piTestFixture [piTestMessageEntry "result-error" none
    (overlayJsonFields (piTestToolResultMessage "c" "read" false "x")
      ["isError"] [])],
  piTestFixture [] (piTestHeader [
    (piCarrierKey, piStampedObject [
      ("sourceEnvironment", Json.mkObj [
        ("cwd", Json.str "/source-only")])])])
]

def piAdditionalRoleValidationPinned : Bool :=
  piAdditionalMalformedFixtures.length == 6 &&
    piAdditionalMalformedFixtures.all piTestRejected

example : piAdditionalRoleValidationPinned = true := by native_decide

private def piDispositionCarrierFixture : String :=
  piTestFixture [
    piTestMessageEntry "historical-call" none (piTestAssistantMessage #[
      piBlockCarrier "assistant" "toolCall" "toolCall" (Json.mkObj [
        ("name", Json.str "historical_exec"),
        ("arguments", Json.mkObj [("cmd", Json.str "pwd")]),
        ("id", Json.str "historical-call-id")])]),
    piTestEntry "custom" "historical-compaction" (some "historical-call") [
      ("customType", Json.str "loom.pi.carrier"),
      ("data", piStampedObject [
        ("kind", Json.str "compaction"),
        ("value", Json.mkObj [
          ("summary", Json.str "historical summary"),
          ("firstKeptEntryId", Json.str "historical-call"),
          ("tokensBefore", Json.num 41)])])]]

private def piStripEntryCarrierMetadata (transcript : Transcript) : Transcript :=
  { transcript with
    entries := transcript.entries.map (fun entry => {
      entry with origin := { entry.origin with sourceRef := "", extras := none } })
    origin := { transcript.origin with
      sourceRef := "",
      extras := some (Json.mkObj [
        ("ts", Json.str piTestTimestamp)]) } }

/-- Exact Pi content/custom carriers set typed disposition. After private
origin metadata is removed, tool and compaction payloads still export only as
inert custom data, and the resulting artifact is an E-I-E fixed point. -/
def piHistoricalDispositionSurvivesMetadataStripping : Bool :=
  match importPi piDispositionCarrierFixture with
  | .error _ => false
  | .ok imported =>
      (match imported.entries[0]?, imported.entries[1]? with
       | some call, some compaction =>
           call.disposition == EntryDisposition.historicalUnverified &&
           compaction.disposition == EntryDisposition.historicalUnverified &&
           (match call.payload with
            | .assistantMsg [.toolCall name _ (some "historical-call-id")] =>
                name.raw == "historical_exec"
            | _ => false) &&
           (match compaction.payload with
            | .compaction "historical summary" (.knownPrefix 0) (some 41) => true
            | _ => false)
       | _, _ => false) &&
      let stripped := piStripEntryCarrierMetadata imported
      match exportPiChecked stripped with
      | .error _ => false
      | .ok first =>
          !first.contains "\"type\":\"toolCall\"" &&
          !first.contains "\"type\":\"compaction\"" &&
          (first.splitOn "\"customType\":\"loom.pi.carrier\"").length == 3 &&
          match importPi first with
          | .error _ => false
          | .ok restored =>
              restored.entries.toList.all (fun entry =>
                entry.disposition == EntryDisposition.historicalUnverified) &&
              match exportPiChecked restored with
              | .ok second => piTestJsonLines second == piTestJsonLines first
              | .error _ => false

example : piHistoricalDispositionSurvivesMetadataStripping = true := by native_decide

private def piTestAssistantMessages (output : String) : List Json :=
  (piTestJsonLines output).drop 1 |>.filterMap (fun entry => do
    guard (ostr entry "type" == some "message")
    let message ← oobj entry "message"
    guard (ostr message "role" == some "assistant")
    pure message)

private def piTestAssistantTexts (message : Json) : List String :=
  (oarr message "content").map (fun blocks => blocks.toList.filterMap (fun block =>
    if ostr block "type" == some "text" then ostr block "text" else none)) |>.getD []

private def piTestSafeAssistantShape (message : Json) : Bool :=
  (oarr message "content").any (fun blocks => blocks.all (fun block =>
    ostr block "type" == some "text" &&
      (oobj block piCarrierKey).isNone &&
      (ostr block "textSignature").isNone &&
      (ostr block "thinkingSignature").isNone &&
      (ostr block "thoughtSignature").isNone))

/-- Native counterpart of `piTestSafeAssistantShape`. A context-safe run may also
carry executable `toolCall` blocks, which are keyed by id/name/arguments rather
than text. No block may carry a reserved Loom stamp or a provider signature. -/
private def piTestNativeAssistantShape (message : Json) : Bool :=
  (oarr message "content").any (fun blocks => blocks.all (fun block =>
    (oobj block piCarrierKey).isNone &&
      (ostr block "textSignature").isNone &&
      (ostr block "thinkingSignature").isNone &&
      (ostr block "thoughtSignature").isNone &&
      match ostr block "type" with
      | some "text" => true
      | some "toolCall" =>
          (ostr block "id").any (fun id => !id.isEmpty) &&
            (ostr block "name").any (fun name => !name.isEmpty) &&
            (oobj block "arguments").isSome
      | _ => false))

private def piTestSynthesizedAssistantProvenance (message : Json) : Bool :=
  let history := (oobj message piCarrierKey).bind (fun stamp =>
    oobj stamp "assistantHistory")
  ostr message "api" == some piHistoryApi &&
    ostr message "provider" == some piHistoryProvider &&
    ostr message "model" == some piHistoryModel &&
    oobj message "usage" == some piZeroUsage &&
    ostr message "stopReason" == some "stop" &&
    history.bind (fun value => ostr value "identity") == some "reserved" &&
    history.bind (fun value => ostr value "metadata") ==
      some "synthesized-unrecorded" &&
    history.bind (fun value => ostr value "usage") ==
      some "synthesized-zero-unrecorded" &&
    history.bind (fun value => ostr value "stopReason") ==
      some "synthesized-unrecorded"

private def piTestTargetOptionProvenance (header : Json)
    (historyMode historyProvenance : String) : Bool :=
  let stamp := oobj header piCarrierKey
  let targetOptions := stamp.bind (fun value => oobj value "targetOptions")
  let history := targetOptions.bind (fun options =>
    oobj options "pi_assistant_history")
  targetOptions.bind (fun options => ostr options "target_session_id") ==
      some "origin-target-option" &&
    targetOptions.bind (fun options => ostr options "target_cwd") ==
      some "origin-target-option" &&
    targetOptions.bind (fun options => ostr options "target_provider") ==
      some "origin-target-option" &&
    targetOptions.bind (fun options => ostr options "target_model") ==
      some "origin-target-option" &&
    targetOptions.bind (fun options => ostr options "target_harness_version") ==
      some "origin-target-option" &&
    targetOptions.bind (fun options => ostr options "target_timestamp") ==
      some "origin-target-option" &&
    stamp.bind (fun value => ostr value "targetHarnessVersion") ==
      some piTargetVersion &&
    history.bind (fun value => ostr value "value") == some historyMode &&
    history.bind (fun value => ostr value "provenance") ==
      some historyProvenance

private def piTestSourceEnvironmentArchive
    (header : Json) (expected : EnvInfo) : Bool :=
  let source := piSourceEnvironmentJsonFromHeader? header
  source == some (piSourceEnvironmentJson expected) &&
    source.bind piDecodeSourceEnvironment == some expected

private def piStrictContextTranscript : Transcript := {
  threads := #[{ kind := .main }],
  entries := #[
    { time := .recorded ⟨1704067200000⟩,
      payload := .userMsg [.text "question"],
      origin := piForeignOrigin "strict-user" },
    { parent := some 0, time := .recorded ⟨1704067200001⟩,
      payload := .assistantMsg [.text "first answer"],
      origin := piForeignOrigin "strict-first" },
    { parent := some 1, time := .recorded ⟨1704067200002⟩,
      payload := .assistantMsg [
        .text "safe before",
        .thinking "foreign reasoning" (some "foreign-thinking-signature"),
        .toolCall { raw := "foreign_exec", canonical := some .bash }
          (Json.mkObj [("cmd", Json.str "pwd")]) (some "foreign-call"),
        .unmodeled "foreign-extra" (Json.mkObj [("opaque", Json.bool true)]),
        .text "safe after"],
      origin := piForeignOrigin "strict-mixed" },
    { parent := some 2, time := .recorded ⟨1704067200003⟩,
      payload := .envMsg [.toolResult (.resolved 2 2) [.text "tool output"]
        (.native false)], origin := piForeignOrigin "strict-result" },
    { parent := some 3, time := .recorded ⟨1704067200004⟩,
      payload := .assistantMsg [
        .thinking "tail reasoning" (some "tail-signature")],
      origin := piForeignOrigin "strict-tail" }],
  env := { cwd := some "/source/cwd", model := some "source-model", provider := some "source-provider", harnessVersion := some "source-version", instructions := some "source instructions", sessionId := some "source-session" },
  activeLeaf := some 4,
  importNotes := [],
  origin := piForeignTranscriptOrigin "pi-strict-context"
    (some piForeignExportOptions)
}

def piStrictAssistantContextPinned : Bool :=
  match exportPiChecked piStrictContextTranscript with
  | .error _ => false
  | .ok output =>
      let lines := piTestJsonLines output
      let header := lines.head?.getD Json.null
      let records := lines.drop 1
      let assistantRecords := records.filter (fun entry =>
        (oobj entry "message").bind (fun message => ostr message "role") ==
          some "assistant")
      let assistants := piTestAssistantMessages output
      let modelChange := records.getLast?.getD Json.null
      let modelStamp := oobj modelChange piCarrierKey |>.bind (fun stamp =>
        oobj stamp "targetModelChange")
      -- The mixed entry interleaves text with reasoning/call/unmodeled blocks.
      -- The call is context-safe now that its canonical identity can ride in the
      -- message-level reserved stamp, so context mode emits five records in
      -- source block order: `safe before`, the reasoning carrier, an executable
      -- `toolCall` message, the unmodeled carrier, then `safe after`. It used to
      -- emit three, with the call buried in the middle carrier — a Pi session
      -- that could be read but not continued. The tail entry is entirely unsafe
      -- and still contributes no native message at all.
      assistants.length == 4 &&
        assistants.map piTestAssistantTexts ==
          [["first answer"], ["safe before"], [], ["safe after"]] &&
        assistants.all piTestNativeAssistantShape &&
        assistants.all piTestSynthesizedAssistantProvenance &&
        assistantRecords.map (fun entry => ostr entry "timestamp") ==
          [some "2024-01-01T00:00:00.001Z",
           some "2024-01-01T00:00:00.002Z",
           some "2024-01-01T00:00:00.002Z",
           some "2024-01-01T00:00:00.002Z"] &&
        assistants.map (fun message => onat message "timestamp") ==
          [some 1704067200001, some 1704067200002, some 1704067200002,
           some 1704067200002] &&
        ostr header "id" == some "pi-target-session" &&
        ostr header "cwd" == some "/tmp/pi-target" &&
        ostr header "timestamp" == some piTestTimestamp &&
        piTestTargetOptionProvenance header "context" "target-default" &&
        piTestSourceEnvironmentArchive header piStrictContextTranscript.env &&
        piTargetPreservesSourceEnvironment piStrictContextTranscript &&
        ostr modelChange "type" == some "model_change" &&
        ostr modelChange "provider" == some "target-provider" &&
        ostr modelChange "modelId" == some "target-model" &&
        modelStamp.bind (fun value => ostr value "author") == some "target" &&
        piHistoryProvider != "target-provider" &&
        piHistoryModel != "target-model" &&
        -- No `toolCall`/`toolResult` carriers left: the lifecycle is native, and
        -- `foreign_exec`'s `canonical := .bash` travels in the reserved stamp
        -- rather than costing the whole lifecycle its executable form.
        piTargetHistoricalOccurrences piStrictContextTranscript ==
          ["assistant", "assistant", "assistant"] &&
        piNativeToolCallCount piStrictContextTranscript == 1 &&
        piNativeToolResultCount piStrictContextTranscript == 1 &&
        piNativeOpenToolCallCount piStrictContextTranscript == 0 &&
        piTargetSummary piStrictContextTranscript == {
          nativeAssistantContextMessages := 4
          historicalAssistantCarriers := 3
          historicalToolCallCarriers := 0
          historicalToolResultCarriers := 0
          resumable := true } &&
        piTestStableExport piStrictContextTranscript

example : piStrictAssistantContextPinned = true := by native_decide

private def piStripHistoricalMetadata (transcript : Transcript) : Transcript :=
  { transcript with entries := transcript.entries.map (fun entry =>
      if entry.disposition == EntryDisposition.historicalUnverified then
        { entry with origin := { entry.origin with sourceRef := "", extras := none } }
      else entry) }

/-- The restored trust boundary after the mixed entry's five-record split.

The call is a native record of its own now, so the entry that once held
`[thinking, toolCall, unmodeled]` as one inert carrier splits into a reasoning
carrier, a NATIVE call, and an unmodeled carrier — eight entries became ten. The
canonical identity is still checked, on the native call rather than inside the
carrier: it survives in the message's reserved stamp instead of costing the call
its executable form. The tool result follows its call and is native too, which
is exactly the resumability this adapter exists to deliver; Pi has a real
`isError` bool, so `.native false` is preserved without normalization. -/
private def piStrictRestoredTrustShape (transcript : Transcript) : Bool :=
  transcript.entries.size == 10 &&
    (match transcript.entries[1]?, transcript.entries[2]?,
        transcript.entries[3]?, transcript.entries[4]?,
        transcript.entries[5]?, transcript.entries[6]?,
        transcript.entries[7]?, transcript.entries[8]? with
     | some first, some safeBefore, some reasoningHistory, some call,
       some unmodeledHistory, some safeAfter, some result, some tailHistory =>
         first.disposition == EntryDisposition.native &&
           safeBefore.disposition == EntryDisposition.native &&
           safeAfter.disposition == EntryDisposition.native &&
           call.disposition == EntryDisposition.native &&
           result.disposition == EntryDisposition.native &&
           reasoningHistory.disposition == EntryDisposition.historicalUnverified &&
           unmodeledHistory.disposition == EntryDisposition.historicalUnverified &&
           tailHistory.disposition == EntryDisposition.historicalUnverified &&
           -- The carriers sit *between* the context records, so replaying the
           -- restored entries in order replays the source block order.
           (match first.payload, safeBefore.payload, safeAfter.payload with
            | .assistantMsg [.text "first answer"],
              .assistantMsg [.text "safe before"],
              .assistantMsg [.text "safe after"] => true
            | _, _, _ => false) &&
           (match reasoningHistory.payload with
            | .assistantMsg [
                .thinking "foreign reasoning"
                  (some "foreign-thinking-signature")] => true
            | _ => false) &&
           (match call.payload with
            | .assistantMsg [.toolCall name _ (some "foreign-call")] =>
                name.raw == "foreign_exec" && name.canonical == some .bash
            | _ => false) &&
           (match unmodeledHistory.payload with
            | .assistantMsg [.unmodeled "foreign-extra" _] => true
            | _ => false) &&
           (match result.payload with
            | .envMsg [.toolResult (.resolved 4 0) [.text "tool output"]
                (.native false)] => true
            | _ => false) &&
           (match tailHistory.payload with
            | .assistantMsg [
                .thinking "tail reasoning" (some "tail-signature")] => true
            | _ => false)
     | _, _, _, _, _, _, _, _ => false)

/-- `assistantHistory` is provenance on a context-safe native message, while
the adjacent custom records are the unauthenticated historical trust boundary. -/
def piAssistantContextTwoHopTrustPinned : Bool :=
  match exportPiChecked piStrictContextTranscript with
  | .error _ => false
  | .ok first =>
      match importPi first with
      | .error _ => false
      | .ok restored =>
          piStrictRestoredTrustShape restored &&
            piArchivedSourceEnvironment restored ==
              some piStrictContextTranscript.env &&
            (piTestAssistantMessages first).all piTestSynthesizedAssistantProvenance &&
            match exportPiChecked restored with
            | .error _ => false
            | .ok second =>
                piTestJsonLines second == piTestJsonLines first &&
                  match importPi second with
                  | .error _ => false
                  | .ok secondRestored =>
                    piStrictRestoredTrustShape secondRestored &&
                    piArchivedSourceEnvironment secondRestored ==
                      some piStrictContextTranscript.env &&
                  let stripped := piStripHistoricalMetadata restored
                  piTargetSummary stripped == {
                    nativeAssistantContextMessages := 4
                    historicalAssistantCarriers := 3
                    historicalToolCallCarriers := 0
                    historicalToolResultCarriers := 0
                    resumable := true } &&
                    match exportPiChecked stripped with
                    | .error _ => false
                    | .ok strippedOutput =>
                        match importPi strippedOutput with
                        | .error _ => false
                        | .ok strippedRestored =>
                            piStrictRestoredTrustShape strippedRestored &&
                              (piTestAssistantMessages strippedOutput).map
                                piTestAssistantTexts ==
                                  [["first answer"], ["safe before"], [],
                                   ["safe after"]] &&
                              match exportPiChecked strippedRestored with
                              | .error _ => false
                              | .ok third => piTestJsonLines third ==
                                  piTestJsonLines strippedOutput

example : piAssistantContextTwoHopTrustPinned = true := by native_decide


/-! ## Assistant block order under context-mode splitting

Splitting one assistant message into a readable Pi message plus an inert carrier
is only lossless if the records come back in the source's block order. The
fixtures below cover the three shapes that a "all safe blocks, then all unsafe
blocks" split gets wrong: reasoning before text (Claude and Cursor's normal
shape), text before reasoning, and full interleaving. -/

private def piOrderCanonicalCall : AssistantBlock :=
  .toolCall { raw := "search_replace", canonical := some .edit }
    (Json.mkObj [("path", Json.str "a.txt")]) (some "order-call")

private def piThinkingFirstBlocks : List AssistantBlock := [
  .thinking "reason first" (some "order-signature"),
  .text "answer",
  piOrderCanonicalCall]

private def piTextFirstBlocks : List AssistantBlock := [
  .text "answer",
  .thinking "reason after" (some "order-signature"),
  piOrderCanonicalCall]

private def piInterleavedBlocks : List AssistantBlock := [
  .text "a",
  .thinking "t1" none,
  .text "b",
  piOrderCanonicalCall,
  .text "c",
  .media "image/png" "opaque-image",
  .text "d"]

private def piBlockOrderTranscript (blocks : List AssistantBlock) : Transcript := {
  threads := #[{ kind := .main }],
  entries := #[
    { time := .recorded ⟨1704067200000⟩, payload := .userMsg [.text "ask"],
      origin := piForeignOrigin "order-user" },
    { parent := some 0, time := .recorded ⟨1704067200001⟩,
      payload := .assistantMsg blocks,
      origin := piForeignOrigin "order-assistant" }],
  env := { cwd := some "/source", sessionId := some "order-source" },
  activeLeaf := some 1,
  importNotes := [],
  origin := piForeignTranscriptOrigin "pi-block-order" (some piForeignExportOptions)
}

/-- The ordered assistant-block stream across every entry. `AssistantBlock` has
no `DecidableEq` (it carries `Json`), so the historical block encoding — which
observes signature, canonical tool name, raw id, and arguments — is the
comparison key. -/
private def piAssistantBlockStreamJson (t : Transcript) : Json :=
  Json.arr (t.entries.toList.flatMap (fun entry =>
    match entry.payload with
    | .assistantMsg blocks => blocks.map piHistoricalAssistantBlock
    | _ => [])).toArray

/-- No restored entry may hold an unsafe block at native trust, and no entry may
mix trust levels: a split record is entirely context-safe or entirely inert. -/
private def piOrderTrustSeparated (t : Transcript) : Bool :=
  t.entries.toList.all (fun entry =>
    match entry.payload with
    | .assistantMsg blocks =>
        if blocks.all (piAssistantBlockIsContextSafe (piAmbiguousToolCallIds t)) then
          true
        else entry.disposition == EntryDisposition.historicalUnverified
    | _ => true)

/-- `piOrderCanonicalCall` asserts `canonical := .edit` and has no result in
these fixtures, so the counts are one native call, still open. Both used to be
zero: the canonical identity forced the call into the inert carrier, and an
inert call is not open because it is not a call at all. Emitting it natively is
the point — the identity now rides in the message's reserved stamp — and the
resulting open call is a faithful report of a fixture that never answered it,
not a new loss. Order, signature, and canonical identity are still compared
block-for-block through `piAssistantBlockStreamJson`. -/
private def piOrderRoundTripPinned (blocks : List AssistantBlock) : Bool :=
  let source := piBlockOrderTranscript blocks
  piNativeToolCallCount source == 1 && piNativeOpenToolCallCount source == 1 &&
  match exportPiChecked source with
  | .error _ => false
  | .ok first =>
      (piTestAssistantMessages first).all piTestNativeAssistantShape &&
      (piTestAssistantMessages first).all piTestSynthesizedAssistantProvenance &&
      match importPi first with
      | .error _ => false
      | .ok restored =>
          piAssistantBlockStreamJson restored == piAssistantBlockStreamJson source &&
          piOrderTrustSeparated restored &&
          match exportPiChecked restored with
          | .error _ => false
          | .ok second =>
              piTestJsonLines second == piTestJsonLines first &&
              match importPi second with
              | .error _ => false
              | .ok twoHop =>
                  piAssistantBlockStreamJson twoHop ==
                    piAssistantBlockStreamJson source &&
                  piOrderTrustSeparated twoHop

/-- Reasoning-before-text, text-before-reasoning, and full interleaving all
survive Pi's context split with source block order, `ThinkingBlock.signature`,
and `ToolName.canonical` intact, at stable trust, over two hops. -/
def piAssistantBlockOrderPreserved : Bool :=
  [piThinkingFirstBlocks, piTextFirstBlocks, piInterleavedBlocks].all
    piOrderRoundTripPinned

example : piAssistantBlockOrderPreserved = true := by native_decide

/-- The two orders are genuinely distinguished by the artifact. Without this an
order-blind exporter could satisfy every equality above by normalizing both
sources to the same file. -/
def piAssistantBlockOrderIsObservable : Bool :=
  match exportPiChecked (piBlockOrderTranscript piThinkingFirstBlocks),
      exportPiChecked (piBlockOrderTranscript piTextFirstBlocks) with
  | .ok thinkingFirst, .ok textFirst =>
      thinkingFirst != textFirst &&
        match importPi thinkingFirst, importPi textFirst with
        | .ok restoredThinkingFirst, .ok restoredTextFirst =>
            piAssistantBlockStreamJson restoredThinkingFirst !=
              piAssistantBlockStreamJson restoredTextFirst
        | _, _ => false
  | _, _ => false

example : piAssistantBlockOrderIsObservable = true := by native_decide

/-- The planned artifact for the interleaved case: one physical record per
safety run, alternating readable message and inert carrier in source order.
Foreign reasoning and media never reach Pi's native content union.

This fixture's call does. `piOrderCanonicalCall` asserts `canonical := .edit`,
which used to make it a third inert run of its own and split `[b, call, c]` into
three records; Pi has no slot for that field inside a `toolCall` block, so the
exporter dropped the block rather than the field. It carries the field in the
message-level reserved stamp instead, so the call joins the surrounding text in
ONE context-safe run: seven records rather than nine, texts `[b, c]` in one
message, and no `toolCall` carrier anywhere. -/
def piInterleavedRecordShapePinned : Bool :=
  let source := piBlockOrderTranscript piInterleavedBlocks
  match exportPiChecked source with
  | .error _ => false
  | .ok output =>
      let records := (piTestJsonLines output).drop 1
      records.map (fun entry => ostr entry "type") ==
          [some "message", some "message", some "custom", some "message",
           some "custom", some "message", some "model_change"] &&
        (piTestAssistantMessages output).map piTestAssistantTexts ==
          [["a"], ["b", "c"], ["d"]] &&
        piTargetSummary source == {
          nativeAssistantContextMessages := 3
          historicalAssistantCarriers := 2
          historicalToolCallCarriers := 0
          historicalToolResultCarriers := 0
          resumable := true } &&
        match importPi output with
        | .error _ => false
        | .ok restored =>
            restored.entries.size == 7 &&
              restored.entries.toList.map (fun entry =>
                entry.disposition == EntryDisposition.native) ==
                [true, true, false, true, false, true, true]

example : piInterleavedRecordShapePinned = true := by native_decide

/-! The source importers sit above Pi in the module graph, so this file cannot
import their fixture declarations without a cycle. These are the exact mixed
assistant payloads produced by the existing `claudeFixture` and
`cursorIdeFixture`; each source importer separately pins that fixture-to-IR
mapping. The checks below pin the Pi half of those two concrete conversions. -/

private def piClaudeFixtureMixedBlocks : List AssistantBlock := [
  .thinking "th" (some "sig1"),
  .text "tx",
  .toolCall { raw := "bash" }
    (Json.mkObj [("a", Json.num 1)]) (some "tu1")]

private def piCursorIdeFixtureMixedBlocks : List AssistantBlock := [
  .thinking "let me think" (some "SIG123"),
  .text "on it",
  .toolCall { raw := "search_replace", canonical := some .edit }
    (Json.mkObj [
      ("file_path", Json.str "a.txt"),
      ("old_string", Json.str "x"),
      ("new_string", Json.str "y")]) (some "tc-1")]

private def piAssistantRunIndexShape
    (blocks : List AssistantBlock) : List (Bool × List Nat) :=
  (piAssistantBlockRuns [] blocks).map (fun run =>
    (run.1, piRunSourceIndices run.2))

private def piAssistantRunBlockStreamJson (blocks : List AssistantBlock) : Json :=
  Json.arr ((piAssistantBlockRuns [] blocks).flatMap (fun run =>
    (piRunBlocks run.2).map piHistoricalAssistantBlock)).toArray

/-- The regression's minimal sequence is not normalized by block class, and
flattening the physical plan reproduces the original typed block stream — the
order property this pin exists for, unchanged.

The two run shapes agree, and that agreement is the point. `claudeFixture`'s
call carries no canonical identity and `cursorIdeFixture`'s asserts
`canonical := .edit`, but a field Pi's `toolCall` block cannot hold is no longer
a reason to withhold the block: the identity travels in the message-level
reserved stamp, so BOTH calls are native-representable and join the preceding
text in one context-safe run. Cursor's used to be a third inert run — the only
difference between the two sources was a scalar that neither Pi nor its reader
ever saw, paid for with an executable call. -/
def piThinkingTextToolCallRunOrderPinned : Bool :=
  piAssistantRunIndexShape piClaudeFixtureMixedBlocks ==
      [(false, [0]), (true, [1, 2])] &&
    piAssistantRunIndexShape piCursorIdeFixtureMixedBlocks ==
      [(false, [0]), (true, [1, 2])] &&
    [piClaudeFixtureMixedBlocks, piCursorIdeFixtureMixedBlocks].all (fun blocks =>
      piAssistantRunBlockStreamJson blocks ==
        Json.arr (blocks.map piHistoricalAssistantBlock).toArray)

example : piThinkingTextToolCallRunOrderPinned = true := by native_decide

private def piFixtureOrderOrigin
    (format : Format) (sourceRef id : String) : Origin :=
  { format, sourceRef, rawId := some id }

private def piFixtureOrderTranscript (format : Format) (sourceRef userText : String)
    (blocks : List AssistantBlock) (resultText : String) : Transcript :=
  let origin := piFixtureOrderOrigin format sourceRef
  let transcriptOrigin : Origin := {
    format := format, sourceRef := sourceRef,
    extras := some piForeignExportOptions }
  { threads := #[{ kind := .main }],
    entries := #[
      { time := .recorded ⟨1704067200000⟩,
        payload := .userMsg [.text userText],
        origin := origin "fixture-user" },
      { parent := some 0, time := .recorded ⟨1704067200001⟩,
        payload := .assistantMsg blocks,
        origin := origin "fixture-assistant" },
      { parent := some 1, time := .recorded ⟨1704067200002⟩,
        payload := .envMsg [
          .toolResult (.resolved 1 2) [.text resultText] (.native false)],
        origin := origin "fixture-result" }],
    env := { cwd := some "/fixture", sessionId := some "fixture-session" },
    activeLeaf := some 2,
    importNotes := [],
    origin := transcriptOrigin }

private def piFixtureAssistantCarrierValues (output : String) : List Json :=
  (piTestJsonLines output).drop 1 |>.filterMap (fun record => do
    guard (piCarrierEntryKind? record == some "assistantMessage")
    piCarrierValue? record)

private def piFixtureResultCarrierValue (output : String) : Option Json :=
  (piTestJsonLines output).drop 1 |>.findSome? (fun record => do
    guard (piCarrierEntryKind? record == some "toolResult")
    piCarrierValue? record)

private def piFixtureRecordsFormChain (records : List Json) : Bool :=
  records.zipIdx.all (fun (record, recordIdx) =>
    if recordIdx == 0 then
      (record.getObjVal? "parentId").toOption == some Json.null
    else
      ostr record "parentId" ==
        (records[recordIdx - 1]?).bind (fun previous => ostr previous "id"))

private def piFixturePhysicalOrderPinned
    (output visibleText toolName callId : String) : Bool :=
  let records := (piTestJsonLines output).drop 1
  let carriers := piFixtureAssistantCarrierValues output
  let result := piFixtureResultCarrierValue output
  records.map (fun record => ostr record "type") ==
      [some "message", some "custom", some "message", some "custom",
       some "custom", some "model_change"] &&
    piFixtureRecordsFormChain records &&
    (piTestAssistantMessages output).map piTestAssistantTexts == [[visibleText]] &&
    (piTestAssistantMessages output).all piTestSafeAssistantShape &&
    carriers.map (fun value => ostr value "scope") ==
      [some "unsafe", some "unsafe"] &&
    carriers.map (fun value => oarr value "sourceBlockIndices") ==
      [some #[Json.num 0], some #[Json.num 2]] &&
    carriers.map (fun value => (oarr value "blocks").map (fun blocks =>
      blocks.toList.map (fun block => ostr block "kind"))) ==
      [some [some "thinking"], some [some "toolCall"]] &&
    result.bind (fun value => ostr value "toolName") == some toolName &&
    result.bind (fun value => ostr value "toolCallId") == some callId

private def piFixtureRestoredOrderPinned
    (transcript : Transcript) (expected : List AssistantBlock) : Bool :=
  (violations transcript).isEmpty && transcript.entries.size == 6 &&
    transcript.activeLeaf == some 5 &&
    piAssistantBlockStreamJson transcript ==
      Json.arr (expected.map piHistoricalAssistantBlock).toArray &&
    transcript.entries.toList.map (fun entry => entry.disposition) == [
      EntryDisposition.native,
      EntryDisposition.historicalUnverified,
      EntryDisposition.native,
      EntryDisposition.historicalUnverified,
      EntryDisposition.historicalUnverified,
      EntryDisposition.native] &&
    piOrderTrustSeparated transcript &&
    match transcript.entries[4]? with
    | some result =>
        match result.payload with
        | .envMsg [.toolResult (.resolved 3 0) _ (.native false)] => true
        | _ => false
    | none => false

private def piMutateFixtureAssistantBlock : AssistantBlock -> AssistantBlock
  | .text text => .text (text ++ " edited")
  | .thinking thinking signature =>
      .thinking (thinking ++ " edited") (signature.map (fun value =>
        value ++ "-edited"))
  | .toolCall name _ rawId =>
      .toolCall { name with raw := name.raw ++ "_edited" }
        (Json.mkObj [("edited", Json.bool true)]) rawId
  | .media mimeType data => .media mimeType data
  | .unmodeled label raw => .unmodeled label raw

private def piMutateFixtureAssistantEntries (transcript : Transcript) : Transcript :=
  { transcript with entries := transcript.entries.map (fun entry =>
      match entry.payload with
      | .assistantMsg blocks =>
          { entry with payload :=
              (.assistantMsg (blocks.map piMutateFixtureAssistantBlock)) }
      | _ => entry) }

private def piFixtureOrderMutationCyclePinned (source : Transcript)
    (expected mutatedExpected : List AssistantBlock)
    (visibleText mutatedVisibleText toolName mutatedToolName callId : String) : Bool :=
  let expectedJson := Json.arr (expected.map piHistoricalAssistantBlock).toArray
  let swappedJson := match expected with
    | first :: second :: rest =>
        Json.arr ((second :: first :: rest).map piHistoricalAssistantBlock).toArray
    | _ => expectedJson
  piAssistantBlockStreamJson source == expectedJson && expectedJson != swappedJson &&
    piNativeToolCallCount source == 0 && piNativeOpenToolCallCount source == 0 &&
    match exportPiChecked source with
    | .error _ => false
    | .ok first =>
        piFixturePhysicalOrderPinned first visibleText toolName callId &&
          match importPi first with
          | .error _ => false
          | .ok restored =>
              piFixtureRestoredOrderPinned restored expected &&
                let mutated := piMutateFixtureAssistantEntries restored
                piAssistantBlockStreamJson mutated ==
                    Json.arr (mutatedExpected.map piHistoricalAssistantBlock).toArray &&
                  piNativeToolCallCount mutated == 0 &&
                  piNativeOpenToolCallCount mutated == 0 &&
                  match exportPiChecked mutated with
                  | .error _ => false
                  | .ok second =>
                      piFixturePhysicalOrderPinned second mutatedVisibleText
                          mutatedToolName callId &&
                        match importPi second with
                        | .error _ => false
                        | .ok mutatedRestored =>
                            piFixtureRestoredOrderPinned mutatedRestored
                                mutatedExpected &&
                              match exportPiChecked mutatedRestored with
                              | .error _ => false
                              | .ok third =>
                                  piTestJsonLines third == piTestJsonLines second

private def piClaudeFixtureMutatedBlocks : List AssistantBlock := [
  .thinking "th edited" (some "sig1-edited"),
  .text "tx edited",
  .toolCall { raw := "bash_edited" }
    (Json.mkObj [("edited", Json.bool true)]) (some "tu1")]

private def piCursorIdeFixtureMutatedBlocks : List AssistantBlock := [
  .thinking "let me think edited" (some "SIG123-edited"),
  .text "on it edited",
  .toolCall { raw := "search_replace_edited", canonical := some .edit }
    (Json.mkObj [("edited", Json.bool true)]) (some "tc-1")]

/-- Physical shape when the fixture's call is native-representable. The unsafe
`thinking` run still takes a carrier, but the context-safe run now carries both
the text and an executable `toolCall`, and the result is a real Pi `toolResult`
record instead of a fifth carrier — five records rather than six. -/
private def piNativeFixturePhysicalOrderPinned
    (output visibleText toolName callId : String) : Bool :=
  let records := (piTestJsonLines output).drop 1
  let carriers := piFixtureAssistantCarrierValues output
  let assistants := piTestAssistantMessages output
  let callBlocks := assistants.flatMap (fun message =>
    ((oarr message "content").map (fun blocks =>
      blocks.toList.filter (fun block =>
        ostr block "type" == some "toolCall"))).getD [])
  let result := records[3]?.bind (fun record => oobj record "message")
  records.map (fun record => ostr record "type") ==
      [some "message", some "custom", some "message", some "message",
       some "model_change"] &&
    piFixtureRecordsFormChain records &&
    assistants.map piTestAssistantTexts == [[visibleText]] &&
    assistants.all piTestNativeAssistantShape &&
    carriers.map (fun value => ostr value "scope") == [some "unsafe"] &&
    carriers.map (fun value => oarr value "sourceBlockIndices") ==
      [some #[Json.num 0]] &&
    carriers.map (fun value => (oarr value "blocks").map (fun blocks =>
      blocks.toList.map (fun block => ostr block "kind"))) ==
      [some [some "thinking"]] &&
    callBlocks.map (fun block => ostr block "id") == [some callId] &&
    callBlocks.map (fun block => ostr block "name") == [some toolName] &&
    result.bind (fun message => ostr message "role") == some "toolResult" &&
    result.bind (fun message => ostr message "toolName") == some toolName &&
    result.bind (fun message => ostr message "toolCallId") == some callId

private def piNativeFixtureRestoredOrderPinned
    (transcript : Transcript) (expected : List AssistantBlock) : Bool :=
  (violations transcript).isEmpty && transcript.entries.size == 5 &&
    transcript.activeLeaf == some 4 &&
    piAssistantBlockStreamJson transcript ==
      Json.arr (expected.map piHistoricalAssistantBlock).toArray &&
    transcript.entries.toList.map (fun entry => entry.disposition) == [
      EntryDisposition.native,
      EntryDisposition.historicalUnverified,
      EntryDisposition.native,
      EntryDisposition.native,
      EntryDisposition.native] &&
    piOrderTrustSeparated transcript &&
    match transcript.entries[3]? with
    | some result =>
        match result.payload with
        | .envMsg [.toolResult (.resolved 2 1) _ (.native false)] => true
        | _ => false
    | none => false

private def piNativeFixtureOrderMutationCyclePinned (source : Transcript)
    (expected mutatedExpected : List AssistantBlock)
    (visibleText mutatedVisibleText toolName mutatedToolName callId : String) : Bool :=
  let expectedJson := Json.arr (expected.map piHistoricalAssistantBlock).toArray
  let swappedJson := match expected with
    | first :: second :: rest =>
        Json.arr ((second :: first :: rest).map piHistoricalAssistantBlock).toArray
    | _ => expectedJson
  piAssistantBlockStreamJson source == expectedJson && expectedJson != swappedJson &&
    piNativeToolCallCount source == 1 && piNativeToolResultCount source == 1 &&
    piNativeOpenToolCallCount source == 0 &&
    match exportPiChecked source with
    | .error _ => false
    | .ok first =>
        piNativeFixturePhysicalOrderPinned first visibleText toolName callId &&
          match importPi first with
          | .error _ => false
          | .ok restored =>
              piNativeFixtureRestoredOrderPinned restored expected &&
                let mutated := piMutateFixtureAssistantEntries restored
                piAssistantBlockStreamJson mutated ==
                    Json.arr (mutatedExpected.map piHistoricalAssistantBlock).toArray &&
                  piNativeToolCallCount mutated == 1 &&
                  piNativeOpenToolCallCount mutated == 0 &&
                  match exportPiChecked mutated with
                  | .error _ => false
                  | .ok second =>
                      piNativeFixturePhysicalOrderPinned second mutatedVisibleText
                          mutatedToolName callId &&
                        match importPi second with
                        | .error _ => false
                        | .ok mutatedRestored =>
                            piNativeFixtureRestoredOrderPinned mutatedRestored
                                mutatedExpected &&
                              match exportPiChecked mutatedRestored with
                              | .error _ => false
                              | .ok third =>
                                  piTestJsonLines third == piTestJsonLines second

/-- The exact `[thinking,text,toolCall]` payload from `claudeFixture` remains in
that order across checked Pi export/import. Editing every split fragment keeps
the same order and trust, updates the result's tool name, and reaches an
export/import fixed point.

`claudeFixture`'s call has object arguments, a non-empty name and id, and no
canonical identity, so it is emitted as an executable Pi `toolCall` answered by a
native `toolResult` — a Claude session converted this way is resumable in Pi
rather than replayed as prose. The `thinking` block has no context-safe
representation and keeps its inert carrier, which is what still forces the split.
`piCursorIdeFixtureMixedOrderPinned` pins the fully inert shape for a source that
does assert a canonical identity. -/
def piClaudeFixtureMixedOrderPinned : Bool :=
  piNativeFixtureOrderMutationCyclePinned
    (piFixtureOrderTranscript .claudeCode "claudeFixture" "hi"
      piClaudeFixtureMixedBlocks "tr")
    piClaudeFixtureMixedBlocks piClaudeFixtureMutatedBlocks
    "tx" "tx edited" "bash" "bash_edited" "tu1"

example : piClaudeFixtureMixedOrderPinned = true := by native_decide

/-- The exact mixed payload from `cursorIdeFixture`, including its signed
thinking and canonical edit tool, has the same physical-order, mutation,
linkage, and fixed-point guarantees as its Claude sibling.

It uses the NATIVE cycle now. The only thing that ever separated this fixture
from `piClaudeFixtureMixedOrderPinned` was `canonical := .edit`, and Pi's
`toolCall` block having no slot for it made the exporter withhold the block —
so a Cursor session converted to Pi could be read but not continued, purely to
avoid dropping a scalar. The scalar travels in the message-level reserved stamp
now, so the call and its result are native here too and `.edit` still returns
(`piNativeFixtureRestoredOrderPinned` compares the full block stream, canonical
field included). -/
def piCursorIdeFixtureMixedOrderPinned : Bool :=
  piNativeFixtureOrderMutationCyclePinned
    (piFixtureOrderTranscript .cursorIde "cursorIdeFixture" "hi cursor"
      piCursorIdeFixtureMixedBlocks "edit applied")
    piCursorIdeFixtureMixedBlocks piCursorIdeFixtureMutatedBlocks
    "on it" "on it edited" "search_replace" "search_replace_edited" "tc-1"

example : piCursorIdeFixtureMixedOrderPinned = true := by native_decide

/-- A historical payload carrier stores its call reference in *physical* export
coordinates, so run splitting has to move those coordinates with the blocks.

The tool call here is the third block of the source entry and lands as the
SECOND block of that entry's second record — `(1,2) → (2,1)`, a coordinate no
unsplit and no "texts first" layout produces, and one that exercises the remap
in both components at once rather than only the entry index. It used to be
`(3,0)`, its own third record, because `canonical := .bash` made the call
context-unsafe; the identity travels in the message's reserved stamp now, so the
call is native and shares a run with the text ahead of it. -/
private def piSplitCallRefTranscript : Transcript := {
  threads := #[{ kind := .main }],
  entries := #[
    { time := .recorded ⟨1704067200000⟩, payload := .userMsg [.text "ask"],
      origin := piForeignOrigin "split-user" },
    { parent := some 0, time := .recorded ⟨1704067200001⟩,
      payload := .assistantMsg [
        .thinking "reason" (some "split-signature"),
        .text "answer",
        .toolCall { raw := "exec", canonical := some .bash }
          (Json.mkObj [("cmd", Json.str "pwd")]) (some "split-call")],
      origin := piForeignOrigin "split-assistant" },
    { parent := some 1, time := .recorded ⟨1704067200002⟩,
      payload := .envMsg [.toolResult (.resolved 1 2) [.text "out"] (.native false)],
      origin := piForeignOrigin "split-result",
      disposition := .historicalUnverified }],
  env := { cwd := some "/source", sessionId := some "split-source" },
  activeLeaf := some 2,
  importNotes := [],
  origin := piForeignTranscriptOrigin "pi-split-callref" (some piForeignExportOptions)
}

private def piSplitCallRefShape (t : Transcript) : Bool :=
  t.entries.size == 5 &&
    match t.entries[2]?, t.entries[3]? with
    | some call, some result =>
        (match call.payload with
         | .assistantMsg [.text "answer", .toolCall name _ (some "split-call")] =>
             name.raw == "exec" && name.canonical == some .bash
         | _ => false) &&
          (match result.payload with
           | .envMsg [.toolResult (.resolved 2 1) [.text "out"] (.native false)] => true
           | _ => false)
    | _, _ => false

def piSplitEntryCallRefRemapPinned : Bool :=
  match exportPiChecked piSplitCallRefTranscript with
  | .error _ => false
  | .ok first =>
      let records := (piTestJsonLines first).drop 1
      let carriedCall := do
        let result ← records[3]?
        let value ← piCarrierValue? result
        let blocks ← oarr value "blocks"
        let block ← blocks[0]?
        let call ← oobj block "call"
        pure (onat call "entry", onat call "block")
      carriedCall == some (some 2, some 1) &&
        match importPi first with
        | .error _ => false
        | .ok restored =>
            piSplitCallRefShape restored &&
              match exportPiChecked restored with
              | .error _ => false
              | .ok second =>
                  piTestJsonLines second == piTestJsonLines first &&
                    match importPi second with
                    | .error _ => false
                    | .ok secondRestored => piSplitCallRefShape secondRestored

example : piSplitEntryCallRefRemapPinned = true := by native_decide

private def piCarrierModeTranscript : Transcript :=
  { piStrictContextTranscript with
    origin := piForeignTranscriptOrigin "pi-carrier-mode"
      (some (piTargetTestOptions (some "carrier"))) }

def piAssistantCarrierModePinned : Bool :=
  piNativeToolCallCount piCarrierModeTranscript == 0 &&
    piTargetSummary piCarrierModeTranscript == {
    nativeAssistantContextMessages := 0
    historicalAssistantCarriers := 3
    historicalToolCallCarriers := 1
    historicalToolResultCarriers := 1
    resumable := false } &&
    piTargetHistoricalOccurrences piCarrierModeTranscript ==
      ["assistant", "assistant", "toolCall", "toolResult", "assistant"] &&
    match exportPiChecked piCarrierModeTranscript with
    | .error _ => false
    | .ok output =>
        let header := (piTestJsonLines output).head?.getD Json.null
        (piTestAssistantMessages output).isEmpty &&
          piTestTargetOptionProvenance header "carrier"
            "origin-target-option" &&
          piTestSourceEnvironmentArchive header piCarrierModeTranscript.env &&
          match importPi output with
          | .error _ => false
          | .ok restored =>
              piArchivedSourceEnvironment restored ==
                  some piCarrierModeTranscript.env &&
              piTargetSummary restored == {
                nativeAssistantContextMessages := 0
                historicalAssistantCarriers := 3
                historicalToolCallCarriers := 1
                historicalToolResultCarriers := 1
                resumable := false } &&
              (restored.entries.toList.filter (fun entry =>
                match entry.payload with | .assistantMsg _ => true | _ => false)
                |>.all (fun entry =>
                  entry.disposition == EntryDisposition.historicalUnverified)) &&
                piTestStableExport restored

example : piAssistantCarrierModePinned = true := by native_decide

private def piEraseTargetOption (options : Json) (key : String) : Json :=
  overlayJsonFields options [key] []

def piStrictTargetOptionsPinned : Bool :=
  let spoofedArchive := {
    piStrictContextTranscript with
    origin := piForeignTranscriptOrigin "pi-foreign-archive-spoof" (some
      (overlayJsonFields piForeignExportOptions [] [
        (piSourceEnvironmentExtraKey, piSourceEnvironmentJson {})])) }
  piArchivedSourceEnvironment spoofedArchive == none &&
    piTestSourceEnvironmentArchive (headerToJson spoofedArchive)
      piStrictContextTranscript.env &&
    piRequiredTargetOptionKeys.all (fun key =>
    piTestCheckedRejected {
      piStrictContextTranscript with
      origin := piForeignTranscriptOrigin s!"pi-missing-{key}"
        (some (piEraseTargetOption piForeignExportOptions key)) }) &&
    piTestCheckedRejected {
      piStrictContextTranscript with
      origin := piForeignTranscriptOrigin "pi-env-is-not-target" } &&
    piTestCheckedRejected {
      piStrictContextTranscript with
      origin := piForeignTranscriptOrigin "pi-reserved-target" (some
        (overlayJsonFields piForeignExportOptions
          ["target_provider", "target_model"] [
            ("target_provider", Json.str piHistoryProvider),
            ("target_model", Json.str piHistoryModel)])) } &&
    (match piExportPreflight piStrictContextTranscript with
     | .ok _ => true
     | .error _ => false)

example : piStrictTargetOptionsPinned = true := by native_decide

private def piTestContextUserTexts (records : List Json) : List (List String) :=
  records.filterMap (fun entry => do
    let message ← oobj entry "message"
    guard (ostr message "role" == some "user")
    let content ← oarr message "content"
    guard (content.all (fun block => ostr block "type" == some "text" &&
      (oobj block piCarrierKey).isNone))
    pure (content.toList.filterMap (fun block => ostr block "text")))

private def piUserEntryGroupsJson (t : Transcript) : List Json :=
  t.entries.toList.filterMap (fun entry =>
    match entry.payload with
    | .userMsg blocks =>
        some (Json.arr (blocks.map piHistoricalUserBlock).toArray)
    | _ => none)

private def piUserEntryDispositions (t : Transcript) : List EntryDisposition :=
  t.entries.toList.filterMap (fun entry =>
    match entry.payload with
    | .userMsg _ => some entry.disposition
    | _ => none)

private def piUserEntryTimes (t : Transcript) : List Time :=
  t.entries.toList.filterMap (fun entry =>
    match entry.payload with
    | .userMsg _ => some entry.time
    | _ => none)

private def piUserEntryParents (t : Transcript) : List (Option Nat) :=
  t.entries.toList.filterMap (fun entry =>
    match entry.payload with
    | .userMsg _ => some entry.parent
    | _ => none)

private def piUserEntryRawIds (t : Transcript) : List (Option String) :=
  t.entries.toList.filterMap (fun entry =>
    match entry.payload with
    | .userMsg _ => some entry.origin.rawId
    | _ => none)

private def piForeignDuplicateCall : AssistantBlock :=
  .toolCall { raw := "foreign_exec", canonical := some .bash }
    (Json.mkObj [("cmd", Json.str "pwd")]) (some "foreign-duplicate-call")

private def piForeignUserSafetyTranscript : Transcript := {
  threads := #[{ kind := .main }],
  entries := #[
    { time := .recorded ⟨1704067200000⟩,
      payload := .userMsg [
        .text "inspect this",
        .media "image/png" "https://foreign.invalid/not-pi-image-data",
        .unmodeled "foreign-user-extra" (Json.mkObj [("x", Json.num 1)]),
        .text "without replaying media"],
      origin := piForeignOrigin "foreign-user-mixed" },
    { parent := some 0, time := .recorded ⟨1704067200001⟩,
      payload := .assistantMsg [.text "acknowledged"],
      origin := piForeignOrigin "foreign-user-answer" },
    { parent := some 1, time := .recorded ⟨1704067200002⟩,
      payload := .assistantMsg [piForeignDuplicateCall, piForeignDuplicateCall],
      origin := piForeignOrigin "foreign-duplicate-calls",
      disposition := EntryDisposition.historicalUnverified },
    { parent := some 2, time := .recorded ⟨1704067200003⟩,
      payload := .envMsg [.toolResult (.resolved 2 1) [.text "duplicate result"]
        (.native false)],
      origin := piForeignOrigin "foreign-duplicate-result" }],
  env := { cwd := some "/source", sessionId := some "source-user" },
  activeLeaf := some 3,
  importNotes := [],
  origin := piForeignTranscriptOrigin "pi-user-safety"
    (some piForeignExportOptions)
}

private def piForeignUserSafetyRestoredShape (t : Transcript) : Bool :=
  (violations t).isEmpty && t.entries.size == 7 && t.activeLeaf == some 6 &&
    t.entries.toList.map (fun entry => entry.parent) ==
      [none, some 0, some 1, some 2, some 3, some 4, some 5] &&
    t.entries.toList.map (fun entry => entry.thread) == [0, 0, 0, 0, 0, 0, 0] &&
    t.entries.toList.map (fun entry => entry.time) == [
      .recorded ⟨1704067200000⟩, .recorded ⟨1704067200000⟩,
      .recorded ⟨1704067200000⟩, .recorded ⟨1704067200001⟩,
      .recorded ⟨1704067200002⟩, .recorded ⟨1704067200003⟩,
      .recorded ⟨1704067200000⟩] &&
    t.entries.toList.map (fun entry => entry.origin.format) ==
      [.pi, .pi, .pi, .pi, .pi, .pi, .pi] &&
    t.entries.toList.map (fun entry => entry.origin.rawId) == [
      some "foreign-user-mixed", some "foreign-user-mixed#run1",
      some "foreign-user-mixed#run2", some "foreign-user-answer",
      some "foreign-duplicate-calls", some "foreign-duplicate-result",
      some "loom-target-model"] &&
    t.entries.toList.map (fun entry => entry.disposition) == [
      EntryDisposition.native, EntryDisposition.historicalUnverified,
      EntryDisposition.native, EntryDisposition.native,
      EntryDisposition.historicalUnverified,
      EntryDisposition.historicalUnverified, EntryDisposition.native] &&
    match t.entries[0]?, t.entries[1]?, t.entries[2]?, t.entries[3]?,
        t.entries[4]?, t.entries[5]?, t.entries[6]? with
    | some before, some history, some after, some answer,
      some calls, some result, some modelChange =>
        (match before.payload, history.payload, after.payload with
         | .userMsg [.text "inspect this"],
           .userMsg [.media "image/png" locator,
             .unmodeled "foreign-user-extra" raw],
           .userMsg [.text "without replaying media"] =>
             locator == "https://foreign.invalid/not-pi-image-data" &&
               raw == Json.mkObj [("x", Json.num 1)]
         | _, _, _ => false) &&
        (match answer.payload with
         | .assistantMsg [.text "acknowledged"] => true
         | _ => false) &&
        (match calls.payload with
         | .assistantMsg [
             .toolCall first firstArgs (some "foreign-duplicate-call"),
             .toolCall second secondArgs (some "foreign-duplicate-call")] =>
               first.raw == "foreign_exec" && first.canonical == some .bash &&
                 second == first && secondArgs == firstArgs &&
                 firstArgs == Json.mkObj [("cmd", Json.str "pwd")]
         | _ => false) &&
        (match result.payload with
         | .envMsg [.toolResult (.resolved 4 1) [.text "duplicate result"]
             (.native false)] => true
         | _ => false) &&
        (match modelChange.payload with
         | .event (.modelChange none (some "target-model")) => true
         | _ => false)
    | _, _, _, _, _, _, _ => false

def piForeignUserUnsafeBlocksStayOutOfContext : Bool :=
  match exportPiChecked piForeignUserSafetyTranscript with
  | .error _ => false
  | .ok output =>
      let lines := piTestJsonLines output
      let header := lines.head?.getD Json.null
      let records := lines.drop 1
      let historicalCall := records[4]?.bind piCarrierValue?
      let historicalCalls := historicalCall.bind (fun value => oarr value "blocks")
      let resultCall := do
        let result ← records[5]?
        guard (piCarrierEntryKind? result == some "toolResult")
        let value ← piCarrierValue? result
        oobj value "call"
      -- The media/unmodeled pair sits between the two texts, so the carrier
      -- record sits between the two readable user records: unsafe blocks stay
      -- out of Pi's native content union without the surrounding text being
      -- silently re-ordered around them.
      piTestSourceEnvironmentArchive header piForeignUserSafetyTranscript.env &&
        piTargetPreservesSourceEnvironment piForeignUserSafetyTranscript &&
        records.map (fun record => ostr record "type") ==
          [some "message", some "custom", some "message", some "message",
           some "custom", some "custom", some "model_change"] &&
        piTestContextUserTexts records ==
          [["inspect this"], ["without replaying media"]] &&
        records[1]?.bind piCarrierEntryKind? == some "historicalPayload" &&
        ostr (records[3]?.getD Json.null) "parentId" ==
          some "foreign-user-mixed#run2" &&
        records[4]?.bind piCarrierEntryKind? == some "historicalPayload" &&
        historicalCall.bind (fun value => onat value "sourceEntry") == some 4 &&
        historicalCall.bind (fun value => oarr value "sourceBlockIndices") ==
          some #[Json.num 0, Json.num 1] &&
        historicalCalls.map Array.size == some 2 &&
        historicalCalls.bind (fun blocks =>
          (blocks[0]?).bind (fun first =>
            (blocks[1]?).map (fun second => first == second))) == some true &&
        resultCall.bind (fun call => ostr call "state") == some "resolved" &&
        resultCall.bind (fun call => onat call "sourceEntry") == some 4 &&
        resultCall.bind (fun call => onat call "sourceBlock") == some 1 &&
        ostr (records.getLast?.getD Json.null) "id" == some "loom-target-model" &&
        match importPi output with
        | .error _ => false
        | .ok restored =>
            piArchivedSourceEnvironment restored ==
                some piForeignUserSafetyTranscript.env &&
              piForeignUserSafetyRestoredShape restored &&
              match exportPiChecked restored with
              | .error _ => false
              | .ok second =>
                  piTestJsonLines second == lines &&
                    match importPi second with
                    | .error _ => false
                    | .ok secondRestored =>
                        piForeignUserSafetyRestoredShape secondRestored

example : piForeignUserUnsafeBlocksStayOutOfContext = true := by native_decide

private def piUserLeadingTextRun : List UserBlock := [
  .text "leading one", .text "leading two"]

private def piUserUnsafeMiddleRun : List UserBlock := [
  .media "image/png" "first-image-data",
  .unmodeled "middle-extra" (Json.mkObj [("position", Json.str "middle")]),
  .media "image/jpeg" "second-image-data"]

private def piUserTrailingTextRun : List UserBlock := [
  .text "trailing one", .text "trailing two"]

private def piUserRunCoverageBlocks : List UserBlock :=
  piUserLeadingTextRun ++ piUserUnsafeMiddleRun ++ piUserTrailingTextRun

private def piUserGroupJson (blocks : List UserBlock) : Json :=
  Json.arr (blocks.map piHistoricalUserBlock).toArray

private def piUserRunCoverageTime : Time :=
  .interpolated ⟨1704067200123⟩ "mixed-user-source-order"

private def piForeignUserRunCoverageTranscript : Transcript := {
  threads := #[{ kind := .main }],
  entries := #[{
    time := piUserRunCoverageTime,
    payload := .userMsg piUserRunCoverageBlocks,
    origin := piForeignOrigin "foreign-user-runs" }],
  env := { cwd := some "/source", sessionId := some "source-user-runs" },
  activeLeaf := some 0,
  importNotes := [],
  origin := piForeignTranscriptOrigin "pi-user-run-coverage"
    (some piForeignExportOptions)
}

/-- Adjacent blocks of the same safety class stay in one run, but the runs
themselves remain in source order. In particular, the trailing text cannot be
folded into the leading text across either media block. -/
def piUserBlockRunsPreserveSourceOrder : Bool :=
  match piUserBlockRuns piUserRunCoverageBlocks with
  | [(true, leading), (false, middle), (true, trailing)] =>
      piUserGroupJson leading == piUserGroupJson piUserLeadingTextRun &&
        piUserGroupJson middle == piUserGroupJson piUserUnsafeMiddleRun &&
        piUserGroupJson trailing == piUserGroupJson piUserTrailingTextRun
  | _ => false

example : piUserBlockRunsPreserveSourceOrder = true := by native_decide

/-- The checked foreign export emits one record per maximal safety run. Import
keeps each run's block grouping, trust state, parent chain, identity, and exact
interpolated-time provenance, and the artifact is an E-I-E fixed point. -/
def piForeignUserRunCoveragePinned : Bool :=
  let source := piForeignUserRunCoverageTranscript
  let expectedGroups := [
    piUserGroupJson piUserLeadingTextRun,
    piUserGroupJson piUserUnsafeMiddleRun,
    piUserGroupJson piUserTrailingTextRun]
  match exportPiChecked source with
  | .error _ => false
  | .ok first =>
      let lines := piTestJsonLines first
      let records := lines.drop 1
      let runRecords := records.take 3
      let carriedBlocks : Option (Array Json) := do
        let carrier ← runRecords[1]?
        guard (piCarrierEntryKind? carrier == some "historicalPayload")
        let value ← piCarrierValue? carrier
        guard (ostr value "kind" == some "userMsg")
        oarr value "blocks"
      runRecords.map (fun record => ostr record "type") ==
          [some "message", some "custom", some "message"] &&
        piTestContextUserTexts runRecords ==
          [["leading one", "leading two"],
           ["trailing one", "trailing two"]] &&
        carriedBlocks ==
          some (piUserUnsafeMiddleRun.map piHistoricalUserBlock).toArray &&
        match importPi first with
        | .error _ => false
        | .ok restored =>
            (violations restored).isEmpty &&
              piArchivedSourceEnvironment restored == some source.env &&
              restored.entries.size == 4 && restored.activeLeaf == some 3 &&
              piUserEntryGroupsJson restored == expectedGroups &&
              piUserEntryDispositions restored ==
                [EntryDisposition.native,
                 EntryDisposition.historicalUnverified,
                 EntryDisposition.native] &&
              piUserEntryTimes restored ==
                [piUserRunCoverageTime, piUserRunCoverageTime,
                 piUserRunCoverageTime] &&
              piUserEntryParents restored == [none, some 0, some 1] &&
              piUserEntryRawIds restored ==
                [some "foreign-user-runs", some "foreign-user-runs#run1",
                 some "foreign-user-runs#run2"] &&
              match exportPiChecked restored with
              | .error _ => false
              | .ok second =>
                  piTestJsonLines second == lines &&
                    match importPi second with
                    | .error _ => false
                    | .ok twoHop =>
                        piUserEntryGroupsJson twoHop == expectedGroups &&
                          piUserEntryDispositions twoHop ==
                            [EntryDisposition.native,
                             EntryDisposition.historicalUnverified,
                             EntryDisposition.native] &&
                          piUserEntryTimes twoHop ==
                            [piUserRunCoverageTime, piUserRunCoverageTime,
                             piUserRunCoverageTime]

example : piForeignUserRunCoveragePinned = true := by native_decide

private def piHistoricalForeignUserRunTranscript : Transcript :=
  { piForeignUserRunCoverageTranscript with
    entries := piForeignUserRunCoverageTranscript.entries.map (fun entry =>
      { entry with disposition := EntryDisposition.historicalUnverified })
    origin := piForeignTranscriptOrigin "pi-historical-user-run-coverage"
      (some piForeignExportOptions) }

/-- A source entry already marked historical remains one inert entry. Run
splitting is a native-context projection and must not regroup or promote
historical user content. -/
def piHistoricalUserGroupingAndStatePinned : Bool :=
  let source := piHistoricalForeignUserRunTranscript
  match exportPiChecked source with
  | .error _ => false
  | .ok first =>
      let lines := piTestJsonLines first
      let records := lines.drop 1
      records[0]?.bind piCarrierEntryKind? == some "historicalPayload" &&
        piTestContextUserTexts records == [] &&
        match importPi first with
        | .error _ => false
        | .ok restored =>
            (violations restored).isEmpty && restored.entries.size == 2 &&
              restored.activeLeaf == some 1 &&
              piUserEntryGroupsJson restored ==
                [piUserGroupJson piUserRunCoverageBlocks] &&
              piUserEntryDispositions restored ==
                [EntryDisposition.historicalUnverified] &&
              piUserEntryTimes restored == [piUserRunCoverageTime] &&
              piUserEntryParents restored == [none] &&
              piUserEntryRawIds restored == [some "foreign-user-runs"] &&
              match exportPiChecked restored with
              | .error _ => false
              | .ok second => piTestJsonLines second == lines

example : piHistoricalUserGroupingAndStatePinned = true := by native_decide

private def piMutatedUserUnsafeMiddleRun : List UserBlock := [
  .media "image/jpeg" "second-image-data-edited",
  .media "image/png" "first-image-data",
  .unmodeled "middle-extra-edited" (Json.mkObj [
    ("position", Json.str "after-images"), ("revision", Json.num 2)])]

private def piMutatedHistoricalUserRun : List UserBlock :=
  piUserLeadingTextRun ++ piMutatedUserUnsafeMiddleRun ++ piUserTrailingTextRun

private def piHistoricalUserCarrierWithEnvelope (output : String) : Option String := do
  let lines := piTestJsonLines output
  let header ← lines[0]?
  let carrier ← lines[1]?
  guard (piCarrierEntryKind? carrier == some "historicalPayload")
  let data ← oobj carrier "data"
  let extendedData := overlayJsonFields data ["dataExtension"] [
    ("dataExtension", Json.str "stale-controlled-data")]
  let extendedCarrier := overlayJsonFields carrier ["data", "outerExtension"] [
    ("data", extendedData),
    ("outerExtension", Json.mkObj [
      ("owner", Json.str "pi-envelope"), ("retained", Json.bool true)])]
  pure <| String.intercalate "\n"
    ((header :: extendedCarrier :: lines.drop 2).map Json.compress) ++ "\n"

private def piMutatedHistoricalUserRestoredShape (t : Transcript) : Bool :=
  (violations t).isEmpty &&
    piArchivedSourceEnvironment t == some piHistoricalForeignUserRunTranscript.env &&
    t.entries.size == 2 && t.activeLeaf == some 1 &&
    t.entries.toList.map (fun entry => entry.parent) == [none, some 0] &&
    t.entries.toList.map (fun entry => entry.origin.format) == [.pi, .pi] &&
    t.entries.toList.map (fun entry => entry.origin.rawId) ==
      [some "foreign-user-runs", some "loom-target-model"] &&
    piUserEntryGroupsJson t == [piUserGroupJson piMutatedHistoricalUserRun] &&
    piUserEntryDispositions t == [EntryDisposition.historicalUnverified] &&
    piUserEntryTimes t == [piUserRunCoverageTime] &&
    piUserEntryParents t == [none] &&
    piUserEntryRawIds t == [some "foreign-user-runs"] &&
    match t.entries[1]? with
    | some modelChange =>
        modelChange.time == Time.recorded ⟨1704067200000⟩ &&
          modelChange.disposition == EntryDisposition.native &&
          (match modelChange.payload with
           | .event (.modelChange none (some "target-model")) => true
           | _ => false)
    | none => false

/-- Re-export overlays current historical user IR onto the controlled carrier
body. Unknown fields on the outer Pi record and in the carrier data envelope
remain additive, while they cannot override the recomputed stamped payload. -/
def piHistoricalUserMutationReflectsCurrentIr : Bool :=
  let source := piHistoricalForeignUserRunTranscript
  match exportPiChecked source with
  | .error _ => false
  | .ok canonical =>
      match piHistoricalUserCarrierWithEnvelope canonical with
      | none => false
      | some fixture =>
          match importPi fixture with
          | .error _ => false
          | .ok imported =>
              piUserEntryGroupsJson imported ==
                  [piUserGroupJson piUserRunCoverageBlocks] &&
                match imported.entries[0]?, imported.entries[1]? with
                | some user, some modelChange =>
                    let mutated : Transcript := { imported with
                      entries := #[
                        { user with payload := .userMsg piMutatedHistoricalUserRun },
                        modelChange] }
                    match exportPiChecked mutated with
                    | .error _ => false
                    | .ok first =>
                        let lines := piTestJsonLines first
                        let carrier := lines[1]?.getD Json.null
                        let data := oobj carrier "data"
                        let value := piCarrierValue? carrier
                        let carriedBlocks := value.bind (fun payload =>
                          oarr payload "blocks")
                        piCarrierEntryKind? carrier == some "historicalPayload" &&
                          ostr carrier "id" == some "foreign-user-runs" &&
                          oobj carrier "outerExtension" == some (Json.mkObj [
                            ("owner", Json.str "pi-envelope"),
                            ("retained", Json.bool true)]) &&
                          data.bind (fun raw =>
                            (raw.getObjVal? "dataExtension").toOption) ==
                              some (Json.str "stale-controlled-data") &&
                          carriedBlocks == some
                            (piMutatedHistoricalUserRun.map
                              piHistoricalUserBlock).toArray &&
                          carriedBlocks != some
                            (piUserRunCoverageBlocks.map
                              piHistoricalUserBlock).toArray &&
                          match importPi first with
                          | .error _ => false
                          | .ok restored =>
                              piMutatedHistoricalUserRestoredShape restored &&
                                match exportPiChecked restored with
                                | .error _ => false
                                | .ok second =>
                                    piTestJsonLines second == lines &&
                                      match importPi second with
                                      | .error _ => false
                                      | .ok secondRestored =>
                                          piMutatedHistoricalUserRestoredShape
                                            secondRestored
                | _, _ => false

example : piHistoricalUserMutationReflectsCurrentIr = true := by native_decide

private def piCompactionMutationTranscript : Transcript := {
  threads := #[{ kind := .main }],
  entries := #[
    { time := .recorded ⟨1704067200000⟩,
      payload := .userMsg [.text "compaction anchor"],
      origin := piForeignOrigin "compaction-anchor" },
    { parent := some 0, time := .sequenced 7,
      payload := .compaction "stale summary" .unknownPrefix none,
      origin := piForeignOrigin "mutable-compaction" }],
  env := { cwd := some "/source", sessionId := some "source-compaction" },
  activeLeaf := some 1,
  importNotes := [],
  origin := piForeignTranscriptOrigin "pi-compaction-mutation"
    (some piForeignExportOptions)
}

private def piCompactionCarrierWithEnvelope (output : String) : Option String := do
  let lines := piTestJsonLines output
  let carrier ← lines[2]?
  guard (piCarrierEntryKind? carrier == some "compaction")
  let data ← oobj carrier "data"
  let extendedData := overlayJsonFields data ["dataExtension"] [
    ("dataExtension", Json.mkObj [
      ("plugin", Json.str "retained"), ("revision", Json.num 4)])]
  let extendedCarrier := overlayJsonFields carrier ["data", "outerExtension"] [
    ("data", extendedData),
    ("outerExtension", Json.str "retained-compaction-envelope")]
  pure <| String.intercalate "\n"
    ((lines.take 2 ++ [extendedCarrier] ++ lines.drop 3).map Json.compress) ++ "\n"

private def piMutatedCompactionRestoredShape (t : Transcript) : Bool :=
  (violations t).isEmpty &&
    piArchivedSourceEnvironment t == some piCompactionMutationTranscript.env &&
    t.entries.size == 3 && t.activeLeaf == some 2 &&
    t.entries.toList.map (fun entry => entry.parent) == [none, some 0, some 1] &&
    t.entries.toList.map (fun entry => entry.time) == [
      .recorded ⟨1704067200000⟩, .sequenced 7,
      .recorded ⟨1704067200000⟩] &&
    t.entries.toList.map (fun entry => entry.origin.format) == [.pi, .pi, .pi] &&
    t.entries.toList.map (fun entry => entry.origin.rawId) == [
      some "compaction-anchor", some "mutable-compaction",
      some "loom-target-model"] &&
    t.entries.toList.map (fun entry => entry.disposition) == [
      EntryDisposition.native, EntryDisposition.historicalUnverified,
      EntryDisposition.native] &&
    match t.entries[0]?, t.entries[1]?, t.entries[2]? with
    | some anchor, some compaction, some modelChange =>
        (match anchor.payload with
         | .userMsg [.text "compaction anchor"] => true
         | _ => false) &&
        (match compaction.payload with
         | .compaction "edited summary" (.knownPrefix 0) (some 99) => true
         | _ => false) &&
        (match modelChange.payload with
         | .event (.modelChange none (some "target-model")) => true
         | _ => false)
    | _, _, _ => false

/-- Matching recognized carriers merge open-world envelope fields around a
fresh authoritative stamp. This non-user case exercises all three controlled
members: `version`, `kind`, and an edited compaction `value`. -/
def piCompactionCarrierMutationReflectsCurrentIr : Bool :=
  match exportPiChecked piCompactionMutationTranscript with
  | .error _ => false
  | .ok canonical =>
      match piCompactionCarrierWithEnvelope canonical with
      | none => false
      | some fixture =>
          match importPi fixture with
          | .error _ => false
          | .ok imported =>
              (match imported.entries[1]? with
               | some compaction =>
                   match compaction.payload with
                   | .compaction "stale summary" .unknownPrefix none => true
                   | _ => false
               | none => false) &&
                match imported.entries[0]?, imported.entries[1]?,
                    imported.entries[2]? with
                | some anchor, some compaction, some modelChange =>
                    let mutated : Transcript := { imported with
                      entries := #[anchor, { compaction with
                        payload := .compaction "edited summary"
                          (.knownPrefix 0) (some 99) }, modelChange] }
                    match exportPiChecked mutated with
                    | .error _ => false
                    | .ok first =>
                        let lines := piTestJsonLines first
                        let carrier := lines[2]?.getD Json.null
                        let data := oobj carrier "data"
                        let value := piCarrierValue? carrier
                        piCarrierEntryKind? carrier == some "compaction" &&
                          ostr carrier "id" == some "mutable-compaction" &&
                          ostr carrier "outerExtension" ==
                            some "retained-compaction-envelope" &&
                          data.bind (fun raw =>
                            (raw.getObjVal? "dataExtension").toOption) ==
                              some (Json.mkObj [
                                ("plugin", Json.str "retained"),
                                ("revision", Json.num 4)]) &&
                          data.bind (fun raw => onat raw "version") ==
                            some piCarrierVersion &&
                          data.bind (fun raw => ostr raw "kind") ==
                            some "compaction" &&
                          value.bind (fun payload => ostr payload "summary") ==
                            some "edited summary" &&
                          value.bind (fun payload =>
                            ostr payload "firstKeptEntryId") ==
                              some "compaction-anchor" &&
                          value.bind (fun payload => onat payload "tokensBefore") ==
                            some 99 &&
                          match importPi first with
                          | .error _ => false
                          | .ok restored =>
                              piMutatedCompactionRestoredShape restored &&
                                match exportPiChecked restored with
                                | .error _ => false
                                | .ok second =>
                                    piTestJsonLines second == lines &&
                                      match importPi second with
                                      | .error _ => false
                                      | .ok secondRestored =>
                                          piMutatedCompactionRestoredShape
                                            secondRestored
                | _, _, _ => false

example : piCompactionCarrierMutationReflectsCurrentIr = true := by native_decide

private def piRawFamilyMutationFixture : String :=
  piTestFixture [
    piTestMessageEntry "raw-other" none (Json.mkObj [
      ("role", Json.str "bashExecution"), ("command", Json.str "old-command"),
      ("output", Json.str "old-output"), ("exitCode", Json.num 0),
      ("cancelled", Json.bool false), ("truncated", Json.bool false),
      ("timestamp", Json.num 1704067200000),
      ("messageExtension", Json.str "keep-message")]),
    piTestEntry "custom_message" "raw-other-carrier" (some "raw-other") [
      ("customType", Json.str "loom.pi.other-message"),
      ("content", Json.str ""), ("display", Json.bool false),
      ("details", Json.mkObj [
        ("version", Json.num piCarrierVersion),
        ("role", Json.str "legacy-role"),
        ("blocks", Json.arr #[
          Json.mkObj [("type", Json.str "text"), ("text", Json.str "old-a")],
          Json.mkObj [("type", Json.str "image"),
            ("mimeType", Json.str "image/png"), ("data", Json.str "old-b")]]),
        ("detailsExtension", Json.str "keep-details")]),
      ("carrierExtension", Json.num 17)],
    piTestEntry "compaction" "raw-compaction" (some "raw-other-carrier") [
      ("summary", Json.str "old-summary"),
      ("firstKeptEntryId", Json.str "raw-other"),
      ("tokensBefore", Json.num 7), ("fromHook", Json.bool true),
      ("compactionExtension", Json.str "keep-compaction")],
    piTestEntry "model_change" "raw-model" (some "raw-compaction") [
      ("provider", Json.str "raw-provider"), ("modelId", Json.str "old-model"),
      ("previousModelId", Json.str "older-model"),
      ("modelExtension", Json.str "keep-model")],
    piTestEntry "thinking_level_change" "raw-thinking" (some "raw-model") [
      ("thinkingLevel", Json.str "low"),
      ("previousThinkingLevel", Json.str "off"),
      ("thinkingExtension", Json.str "keep-thinking")],
    piTestEntry "branch_summary" "raw-branch" (some "raw-thinking") [
      ("fromId", Json.str "raw-other"), ("summary", Json.str "old-branch"),
      ("fromHook", Json.bool false),
      ("branchExtension", Json.str "keep-branch")],
    piTestEntry "plugin_event" "raw-event" (some "raw-branch") [
      ("payload", Json.str "old-event"),
      ("eventExtension", Json.str "keep-event")],
    piTestEntry "plugin_event" "raw-permission" (some "raw-event") [
      ("payload", Json.str "old-permission-event"),
      ("permissionExtension", Json.str "keep-permission")]]

private def piRawFamilyRestoredShape (t : Transcript) : Bool :=
  (violations t).isEmpty && t.entries.size == 8 && t.activeLeaf == some 7 &&
    t.entries.toList.map (fun entry => entry.parent) ==
      [none, some 0, some 1, some 2, some 3, some 4, some 5, some 6] &&
    t.entries.toList.map (fun entry => entry.origin.format) ==
      List.replicate 8 Format.pi &&
    t.entries.toList.map (fun entry => entry.origin.rawId) == [
      some "raw-other", some "raw-other-carrier", some "raw-compaction",
      some "raw-model", some "raw-thinking", some "raw-branch",
      some "raw-event", some "raw-permission"] &&
    t.entries.toList.map (fun entry => entry.disposition) == [
      EntryDisposition.native, EntryDisposition.historicalUnverified,
      EntryDisposition.native, EntryDisposition.native, EntryDisposition.native,
      EntryDisposition.native, EntryDisposition.native,
      EntryDisposition.historicalUnverified] &&
    match t.entries[0]?, t.entries[1]?, t.entries[2]?, t.entries[3]?,
        t.entries[4]?, t.entries[5]?, t.entries[6]?, t.entries[7]? with
    | some nativeOther, some carriedOther, some compaction, some model,
        some thinking, some branch, some event, some permission =>
        (match nativeOther.payload with
         | .otherMsg "bashExecution" [.unmodeled "bashExecution" raw] =>
             ostr raw "command" == some "new-command" &&
               ostr raw "output" == some "new-output"
         | _ => false) &&
        (match carriedOther.payload with
         | .otherMsg "edited-role" [
             .media "image/jpeg" "new-media", .text "new-text"] => true
         | _ => false) &&
        (match compaction.payload with
         | .compaction "new-summary" (.knownPrefix 0) (some 88) => true
         | _ => false) &&
        (match model.payload with
         | .event (.modelChange (some "edited-previous") (some "new-model")) => true
         | _ => false) &&
        (match thinking.payload with
         | .event (.thinkingLevelChange (some "low") (some "high")) => true
         | _ => false) &&
        (match branch.payload with
         | .event (.branchSummary "new-branch") => true
         | _ => false) &&
        (match event.payload with
         | .event (.custom "plugin_event" raw) =>
             ostr raw "payload" == some "new-event" &&
               ostr raw "eventExtension" == some "keep-event"
         | _ => false) &&
        (match permission.payload with
         | .event (.permissionMode "edited-mode") => true
         | _ => false) &&
        permission.parent == some 6 &&
        permission.time == Time.recorded ⟨1704067200000⟩
    | _, _, _, _, _, _, _, _ => false

/-- Every recognized raw record family is exact while unchanged, then overlays
the current IR fields without sacrificing additive source extensions. -/
def piRawFamiliesReflectCurrentIr : Bool :=
  piTestExactCycle piRawFamilyMutationFixture &&
    match importPi piRawFamilyMutationFixture with
    | .error _ => false
    | .ok imported =>
        match imported.entries[0]?, imported.entries[1]?, imported.entries[2]?,
            imported.entries[3]?, imported.entries[4]?, imported.entries[5]?,
            imported.entries[6]?, imported.entries[7]? with
        | some nativeOther, some carriedOther, some compaction, some model,
            some thinking, some branch, some event, some permission =>
            let nativePayload := match nativeOther.payload with
              | .otherMsg _ [.unmodeled _ raw] => .otherMsg "bashExecution"
                  [.unmodeled "bashExecution" (overlayJsonFields raw
                    ["command", "output"] [
                      ("command", Json.str "new-command"),
                      ("output", Json.str "new-output")])]
              | payload => payload
            let eventPayload := match event.payload with
              | .event (.custom label raw) => .event (.custom label
                  (overlayJsonFields raw ["payload"] [
                    ("payload", Json.str "new-event")]))
              | payload => payload
            let mutated : Transcript := { imported with entries := #[
              { nativeOther with payload := nativePayload },
              { carriedOther with payload := .otherMsg "edited-role" [
                  .media "image/jpeg" "new-media", .text "new-text"] },
              { compaction with payload := (.compaction "new-summary"
                  (.knownPrefix 0) (some 88)) },
              { model with payload := (.event (.modelChange
                  (some "edited-previous") (some "new-model"))) },
              { thinking with payload := (.event (.thinkingLevelChange
                  (some "low") (some "high"))) },
              { branch with payload := (.event (.branchSummary "new-branch")) },
              { event with payload := eventPayload },
              { permission with payload := (.event (.permissionMode "edited-mode")) }] }
            match exportPiChecked mutated with
            | .error _ => false
            | .ok first =>
                let records := (piTestJsonLines first).drop 1
                let nativeMessage := records[0]?.bind (fun raw => oobj raw "message")
                let carrierDetails := records[1]?.bind (fun raw => oobj raw "details")
                let carrierBlocks := carrierDetails.bind (fun details => oarr details "blocks")
                let compact := records[2]?.getD Json.null
                let modelJson := records[3]?.getD Json.null
                let thinkingJson := records[4]?.getD Json.null
                let branchJson := records[5]?.getD Json.null
                let eventJson := records[6]?.getD Json.null
                let permissionJson := records[7]?.getD Json.null
                let permissionValue := piCarrierValue? permissionJson
                nativeMessage.bind (fun raw => ostr raw "command") ==
                    some "new-command" &&
                  nativeMessage.bind (fun raw => ostr raw "messageExtension") ==
                    some "keep-message" &&
                  carrierDetails.bind (fun raw => ostr raw "role") ==
                    some "edited-role" &&
                  carrierDetails.bind (fun raw => ostr raw "detailsExtension") ==
                    some "keep-details" &&
                  records[1]?.bind (fun raw => onat raw "carrierExtension") == some 17 &&
                  carrierBlocks == some #[
                    Json.mkObj [("type", Json.str "image"),
                      ("mimeType", Json.str "image/jpeg"),
                      ("data", Json.str "new-media")],
                    Json.mkObj [("type", Json.str "text"),
                      ("text", Json.str "new-text")]] &&
                  ostr compact "summary" == some "new-summary" &&
                  ostr compact "firstKeptEntryId" == some "raw-other" &&
                  onat compact "tokensBefore" == some 88 &&
                  ostr compact "compactionExtension" == some "keep-compaction" &&
                  ostr modelJson "modelId" == some "new-model" &&
                  ostr modelJson "previousModelId" == some "edited-previous" &&
                  ostr modelJson "modelExtension" == some "keep-model" &&
                  ostr thinkingJson "thinkingLevel" == some "high" &&
                  ostr thinkingJson "previousThinkingLevel" == some "low" &&
                  ostr thinkingJson "thinkingExtension" == some "keep-thinking" &&
                  ostr branchJson "summary" == some "new-branch" &&
                  ostr branchJson "branchExtension" == some "keep-branch" &&
                  ostr eventJson "payload" == some "new-event" &&
                  ostr eventJson "eventExtension" == some "keep-event" &&
                  piCarrierEntryKind? permissionJson == some "permissionMode" &&
                  permissionValue == some (Json.str "edited-mode") &&
                  ostr permissionJson "payload" == some "old-permission-event" &&
                  ostr permissionJson "permissionExtension" ==
                    some "keep-permission" &&
                  ostr permissionJson "parentId" == some "raw-event" &&
                  ostr permissionJson "timestamp" == some piTestTimestamp &&
                  match importPi first with
                  | .error _ => false
                  | .ok restored =>
                      piRawFamilyRestoredShape restored &&
                        match exportPiChecked restored with
                        | .error _ => false
                        | .ok second =>
                            piTestJsonLines second == piTestJsonLines first
        | _, _, _, _, _, _, _, _ => false

example : piRawFamiliesReflectCurrentIr = true := by native_decide

private def piTimeMutationFixture : String :=
  let message := overlayJsonFields (piTestUserMessage (Json.str "time"))
    [piCarrierKey] [(piCarrierKey, Json.mkObj [
      ("version", Json.num piCarrierVersion),
      ("messageExtension", Json.str "keep-message-time")])]
  let entry := overlayJsonFields (piTestMessageEntry "time-root" none message)
    [piCarrierKey] [(piCarrierKey, Json.mkObj [
      ("version", Json.num piCarrierVersion),
      ("entryExtension", Json.str "keep-entry-time")])]
  piTestFixture [entry]

private def piTimeMutationCase (imported : Transcript) (time : Time)
    (entryTimestamp : String) (messageTimestamp : Nat)
    (state : Option String) : Bool :=
  match imported.entries[0]? with
  | none => false
  | some entry =>
      let mutated : Transcript := { imported with entries := #[{ entry with time }] }
      match exportPiChecked mutated with
      | .error _ => false
      | .ok first =>
          let record := (piTestJsonLines first)[1]?.getD Json.null
          let stamp := oobj record piCarrierKey
          let timeStamp := stamp.bind (fun value => oobj value "time")
          let message := oobj record "message"
          ostr record "timestamp" == some entryTimestamp &&
            message.bind (fun value => onat value "timestamp") == some messageTimestamp &&
            stamp.bind (fun value => ostr value "entryExtension") ==
              some "keep-entry-time" &&
            (message.bind (fun value => oobj value piCarrierKey)).bind
              (fun value => ostr value "messageExtension") ==
                some "keep-message-time" &&
            timeStamp.bind (fun value => ostr value "state") == state &&
            match importPi first with
            | .error _ => false
            | .ok restored =>
                restored.entries[0]?.map (fun current => current.time) == some time &&
                  match exportPiChecked restored with
                  | .error _ => false
                  | .ok second => piTestJsonLines second == piTestJsonLines first

/-- Recorded and interpolated mutations rewrite both timestamps; sequenced and
absent retain the required source timestamp envelope while stamping their exact
IR state. Unknown entry/message stamp fields survive every case. -/
def piAllTimeMutationsAreAuthoritative : Bool :=
  piTestExactCycle piTimeMutationFixture &&
    match importPi piTimeMutationFixture with
    | .error _ => false
    | .ok imported =>
        piTimeMutationCase imported (.recorded ⟨1704067200555⟩)
            "2024-01-01T00:00:00.555Z" 1704067200555 none &&
          piTimeMutationCase imported
            (.interpolated ⟨1704067200666⟩ "edited-basis")
            "2024-01-01T00:00:00.666Z" 1704067200666
            (some "interpolated") &&
          piTimeMutationCase imported (.sequenced 23)
            piTestTimestamp 1704067200000 (some "sequenced") &&
          piTimeMutationCase imported .absent
            piTestTimestamp 1704067200000 (some "absent")

example : piAllTimeMutationsAreAuthoritative = true := by native_decide

private def piCoordinateCollisionOldBlock : AssistantBlock :=
  .toolCall { raw := "old-call" } (Json.mkObj []) (some "duplicate-coordinate-id")

private def piCoordinateCollisionOldRaw : Json :=
  piTestEntry "custom" "old-coordinate" (some "new-coordinate") [
    ("customType", Json.str "loom.pi.carrier"),
    ("data", piStampedObject [
      ("kind", Json.str "assistantMessage"),
      ("value", piHistoricalAssistantCarrierValue "full" 0
        [piCoordinateCollisionOldBlock] [0]),
      ("dataExtension", Json.str "keep-coordinate-data")]),
    ("coordinateExtension", Json.str "keep-coordinate-entry")]

private def piOriginWithRaw (id : String) (raw : Json) : Origin :=
  { format := .pi, sourceRef := "pi-coordinate-source", rawId := some id,
    extras := some (Json.mkObj [
      ("ts", Json.str piTestTimestamp), ("piRaw", raw)]) }

private def piCoordinateCollisionEnv : EnvInfo := {
  cwd := some "/coordinate-source",
  model := some "source-model",
  provider := some "source-provider",
  sessionId := some "coordinate-source"
}

private def piCoordinateCollisionTranscript : Transcript := {
  threads := #[{ kind := .main }],
  entries := #[
    { time := .recorded ⟨1704067200000⟩,
      payload := .assistantMsg [
        .toolCall { raw := "new-call" } (Json.mkObj [])
          (some "duplicate-coordinate-id")],
      origin := piForeignOrigin "new-coordinate",
      disposition := .historicalUnverified },
    { parent := some 0, time := .recorded ⟨1704067200001⟩,
      payload := .assistantMsg [piCoordinateCollisionOldBlock],
      origin := piOriginWithRaw "old-coordinate" piCoordinateCollisionOldRaw,
      disposition := .historicalUnverified },
    { parent := some 0, time := .recorded ⟨1704067200002⟩,
      payload := .userMsg [.text "selected branch"],
      origin := piForeignOrigin "active-coordinate-branch" },
    { parent := some 1, time := .recorded ⟨1704067200003⟩,
      payload := .envMsg [.toolResult (.resolved 1 0)
        [.text "old call result"] (.native false)],
      origin := piForeignOrigin "collision-result" }],
  env := piCoordinateCollisionEnv,
  activeLeaf := some 2,
  importNotes := [],
  origin := piForeignTranscriptOrigin "pi-coordinate-collision"
    (some piForeignExportOptions)
}

private def piCoordinateCollisionRestoredShape (t : Transcript) : Bool :=
  (violations t).isEmpty && t.entries.size == 5 && t.activeLeaf == some 4 &&
    t.entries.toList.map (fun entry => entry.parent) ==
      [none, some 0, some 1, some 0, some 3] &&
    match t.entries[0]?, t.entries[1]?, t.entries[2]? with
    | some introduced, some preserved, some result =>
        (match introduced.payload, preserved.payload with
         | .assistantMsg [.toolCall introducedName _
             (some "duplicate-coordinate-id")],
           .assistantMsg [.toolCall preservedName _
             (some "duplicate-coordinate-id")] =>
             introducedName.raw == "new-call" && preservedName.raw == "old-call"
         | _, _ => false) &&
        (match result.payload with
         | .envMsg [.toolResult (.resolved 1 0)
             [.text "old call result"] (.native false)] => true
         | _ => false) &&
        introduced.disposition == EntryDisposition.historicalUnverified &&
        preserved.disposition == EntryDisposition.historicalUnverified &&
        result.disposition == EntryDisposition.historicalUnverified
    | _, _, _ => false

/-- Preserved historical coordinates are allocated before new physical ones.
The selected leaf moves ahead of a later source-array entry, the duplicate call
IDs remain ambiguous by signature alone, and the result still selects exactly
the intended old call through the shared collision-free plan. -/
def piHistoricalCoordinateCollisionPlanPinned : Bool :=
  let source := piCoordinateCollisionTranscript
  let idPlan := piEntryIdPlan source
  let plan := piAssistantCoordinatePlan source idPlan
  piPhysicalEntryStart source idPlan 0 == 0 &&
    source.entries[1]?.bind (fun entry =>
      piHistoricalAssistantCoordinate? (piRawEntry entry.origin) 0) ==
        some (0, 0) &&
    piPlannedAssistantCoordinate? plan 1 0 == some (0, 0) &&
    piPlannedAssistantCoordinate? plan 0 0 == some (2, 0) &&
    match exportPiChecked source with
    | .error _ => false
    | .ok first =>
        let records := (piTestJsonLines first).drop 1
        let introducedValue := records[0]?.bind piCarrierValue?
        let preservedValue := records[1]?.bind piCarrierValue?
        let resultValue := records[2]?.bind piCarrierValue?
        let resultCall := resultValue.bind (fun value => oobj value "call")
        records.map (fun record => ostr record "id") == [
            some "new-coordinate", some "old-coordinate",
            some "collision-result", some "active-coordinate-branch",
            some "loom-target-model"] &&
          introducedValue.bind (fun value => onat value "sourceEntry") == some 2 &&
          introducedValue.bind (fun value => oarr value "sourceBlockIndices") ==
            some #[Json.num 0] &&
          preservedValue.bind (fun value => onat value "sourceEntry") == some 0 &&
          preservedValue.bind (fun value => oarr value "sourceBlockIndices") ==
            some #[Json.num 0] &&
          resultCall.bind (fun call => onat call "sourceEntry") == some 0 &&
          resultCall.bind (fun call => onat call "sourceBlock") == some 0 &&
          records[1]?.bind (fun raw => ostr raw "coordinateExtension") ==
            some "keep-coordinate-entry" &&
          match importPi first with
          | .error _ => false
          | .ok restored =>
              piCoordinateCollisionRestoredShape restored &&
                match exportPiChecked restored with
                | .error _ => false
                | .ok second => piTestJsonLines second == piTestJsonLines first

example : piHistoricalCoordinateCollisionPlanPinned = true := by native_decide

private def piToolNameMutationFixture : String :=
  piTestFixture [
    piTestMessageEntry "name-native-call" none (piTestAssistantMessage #[
      piCallBlock "name-native" "stale-native"] "toolUse"),
    piTestMessageEntry "name-carrier-call" (some "name-native-call")
      (piTestAssistantMessage #[
        piCallBlock "name-carrier" "stale-carrier"] "toolUse"),
    overlayJsonFields
      (piTestMessageEntry "name-native-result" (some "name-carrier-call")
        (overlayJsonFields
          (piTestToolResultMessage "name-native" "stale-native" false "native")
          ["messageExtension"] [
            ("messageExtension", Json.str "keep-native-message")]))
      ["resultExtension"] [("resultExtension", Json.str "keep-native-entry")],
    overlayJsonFields
      (piTestMessageEntry "name-carrier-result" (some "name-native-result")
        (piTestToolResultMessage "name-carrier" "stale-carrier" false "carrier"))
      ["resultExtension"] [("resultExtension", Json.str "keep-carrier-source")]]

private def piToolNameMutationRestoredShape (t : Transcript) : Bool :=
  (violations t).isEmpty && t.entries.size == 4 && t.activeLeaf == some 3 &&
    match t.entries[0]?, t.entries[1]?, t.entries[2]?, t.entries[3]? with
    | some nativeCall, some carrierCall, some nativeResult, some carrierResult =>
        (match nativeCall.payload with
         | .assistantMsg [.toolCall nativeName _ (some "name-native")] =>
             nativeName.raw == "edited-native" && nativeName.canonical.isNone
         | _ => false) &&
        (match carrierCall.payload with
         | .assistantMsg [.toolCall carrierName _ (some "name-carrier")] =>
             carrierName.raw == "edited-carrier" &&
               carrierName.canonical == some .bash
         | _ => false) &&
        (match nativeResult.payload with
         | .envMsg [.toolResult (.resolved 0 0) [.text "native"]
             (.native false)] => true
         | _ => false) &&
        (match carrierResult.payload with
         | .envMsg [.toolResult (.resolved 1 0) [.text "carrier"]
             (.native false)] => true
         | _ => false) &&
        nativeCall.disposition == EntryDisposition.native &&
        carrierCall.disposition == EntryDisposition.historicalUnverified &&
        nativeResult.disposition == EntryDisposition.native &&
        carrierResult.disposition == EntryDisposition.historicalUnverified
    | _, _, _, _ => false

/-- The resolved IR call owns the current tool name. A stale native result name
is overwritten, while a carrier keeps the old raw result only in sourceEnvelope
and exposes the edited call name in its authoritative value.

The lever that drives the second lifecycle onto the carrier path is the mutation
giving its call NON-OBJECT arguments: Pi's `toolCall` block types `arguments` as
an object, so that message — and therefore its result — has no native form and
must travel inert. The lever has moved twice, and both moves are the same
correction. It was `ErrorSignal.unrecorded`, until `piErrorExport` started
writing error epistemics out of band into the reserved `toolError` stamp. It was
then `canonical := .bash`, until `piToolCanonicalCarrier` started doing the same
for canonical identity — a field with no slot in the block is a reason to carry
it beside the block, not to withhold the block. Argument SHAPE is a different
kind of limit: there is no encoding of a bare string that Pi's object-typed
`arguments` accepts, so the carrier here is genuine. The call still asserts
`canonical := .bash`, and the carrier still returns it. Two assistant entries
are needed because representability is decided per message, not per block. -/
def piResolvedToolNameMutationPinned : Bool :=
  piTestExactCycle piToolNameMutationFixture &&
    match importPi piToolNameMutationFixture with
    | .error _ => false
    | .ok imported =>
        match imported.entries[0]?, imported.entries[1]?,
            imported.entries[2]?, imported.entries[3]? with
        | some nativeCall, some carrierCall, some nativeResult, some carrierResult =>
            let mutated : Transcript := { imported with entries := #[
              { nativeCall with payload := .assistantMsg [
                  .toolCall { raw := "edited-native" } (Json.mkObj [])
                    (some "name-native")] },
              { carrierCall with payload := .assistantMsg [
                  .toolCall { raw := "edited-carrier", canonical := some .bash }
                    (Json.str "opaque-arguments") (some "name-carrier")] },
              nativeResult,
              carrierResult] }
            match exportPiChecked mutated with
            | .error _ => false
            | .ok first =>
                let records := (piTestJsonLines first).drop 1
                let nativeMessage := records[2]?.bind (fun raw => oobj raw "message")
                let carrierValue := records[3]?.bind piCarrierValue?
                let sourceEnvelope := carrierValue.bind
                  (fun value => oobj value "sourceEnvelope")
                let sourceMessage := sourceEnvelope.bind
                  (fun raw => oobj raw "message")
                nativeMessage.bind (fun message => ostr message "toolName") ==
                    some "edited-native" &&
                  nativeMessage.bind (fun message => ostr message "messageExtension") ==
                    some "keep-native-message" &&
                  records[2]?.bind (fun raw => ostr raw "resultExtension") ==
                    some "keep-native-entry" &&
                  carrierValue.bind (fun value => ostr value "toolName") ==
                    some "edited-carrier" &&
                  sourceMessage.bind (fun message => ostr message "toolName") ==
                    some "stale-carrier" &&
                  sourceEnvelope.bind (fun raw => ostr raw "resultExtension") ==
                    some "keep-carrier-source" &&
                  match importPi first with
                  | .error _ => false
                  | .ok restored =>
                      piToolNameMutationRestoredShape restored &&
                        match exportPiChecked restored with
                        | .error _ => false
                        | .ok second => piTestJsonLines second == piTestJsonLines first
        | _, _, _, _ => false

example : piResolvedToolNameMutationPinned = true := by native_decide

private def piEmptyToolNameMutationFixture : String :=
  piTestFixture [
    overlayJsonFields
      (piTestMessageEntry "empty-name-calls" none (piTestAssistantMessage #[
        piCallBlock "empty-duplicate" "stale-first",
        piCallBlock "empty-duplicate" "stale-second"] "toolUse"))
      ["assistantExtension"] [
        ("assistantExtension", Json.str "keep-assistant-source")],
    overlayJsonFields
      (piTestMessageEntry "empty-name-result" (some "empty-name-calls")
        (piTestToolResultMessage "empty-duplicate" "stale-second" false
          "empty-name-result"))
      ["resultExtension"] [
        ("resultExtension", Json.str "keep-empty-result-source")]]

private def piEmptyToolNameRestoredShape (t : Transcript) : Bool :=
  (violations t).isEmpty && t.entries.size == 2 && t.activeLeaf == some 1 &&
    t.entries.toList.map (fun entry => entry.parent) == [none, some 0] &&
    t.entries.toList.map (fun entry => entry.time) == [
      .recorded ⟨1704067200000⟩, .recorded ⟨1704067200000⟩] &&
    t.entries.toList.map (fun entry => entry.origin.rawId) == [
      some "empty-name-calls", some "empty-name-result"] &&
    t.entries.toList.map (fun entry => entry.disposition) == [
      EntryDisposition.historicalUnverified,
      EntryDisposition.historicalUnverified] &&
    match t.entries[0]?, t.entries[1]? with
    | some calls, some result =>
        (match calls.payload with
         | .assistantMsg [
             .toolCall first _ (some "empty-duplicate"),
             .toolCall second _ (some "empty-duplicate")] =>
             first.raw == "current-first" && second.raw == ""
         | _ => false) &&
        (match result.payload with
         | .envMsg [.toolResult (.resolved 0 1)
             [.text "empty-name-result"] (.native false)] => true
         | _ => false) &&
        piToolNameOfRef t (.resolved 0 1) == some ""
    | _, _ => false

/-- Empty is a current, representable Loom tool name, not missing evidence.
The assistant moves inertly into a coordinate-bearing carrier; the result keeps
the exact empty name while its stale Pi name survives only in sourceEnvelope.
Coordinates, rather than the duplicate raw ID, select block 1 on every import. -/
def piEmptyResolvedToolNameIsAuthoritative : Bool :=
  match importPi piEmptyToolNameMutationFixture with
  | .error _ => false
  | .ok imported =>
      match imported.entries[0]?, imported.entries[1]? with
      | some calls, some result =>
          let mutated : Transcript := { imported with entries := #[
            { calls with payload := .assistantMsg [
                .toolCall { raw := "current-first" } (Json.mkObj [])
                  (some "empty-duplicate"),
                .toolCall { raw := "" } (Json.mkObj [])
                  (some "empty-duplicate")] },
            { result with payload := .envMsg [
                .toolResult (.resolved 0 1) [.text "empty-name-result"]
                  (.native false)] }] }
          (violations mutated).isEmpty &&
            match exportPiChecked mutated with
            | .error _ => false
            | .ok first =>
                let records := (piTestJsonLines first).drop 1
                let assistantValue := records[0]?.bind piCarrierValue?
                let assistantBlocks := assistantValue.bind
                  (fun value => oarr value "blocks")
                let assistantSource := assistantValue.bind
                  (fun value => oobj value "sourceEnvelope")
                let resultValue := records[1]?.bind piCarrierValue?
                let resultCall := resultValue.bind (fun value => oobj value "call")
                let resultSource := resultValue.bind
                  (fun value => oobj value "sourceEnvelope")
                let resultSourceMessage := resultSource.bind
                  (fun raw => oobj raw "message")
                records[0]?.bind piCarrierEntryKind? == some "assistantMessage" &&
                  assistantValue.bind (fun value => onat value "sourceEntry") ==
                    some 0 &&
                  assistantValue.bind (fun value => oarr value
                    "sourceBlockIndices") == some #[Json.num 0, Json.num 1] &&
                  (assistantBlocks.bind (fun blocks => blocks[1]?)).bind
                    (fun block => ostr block "name") == some "" &&
                  assistantSource.bind (fun raw => ostr raw
                    "assistantExtension") == some "keep-assistant-source" &&
                  records[1]?.bind piCarrierEntryKind? == some "toolResult" &&
                  resultValue.bind (fun value => ostr value "toolName") == some "" &&
                  resultCall.bind (fun call => ostr call "state") ==
                    some "resolved" &&
                  resultCall.bind (fun call => onat call "sourceEntry") == some 0 &&
                  resultCall.bind (fun call => onat call "sourceBlock") == some 1 &&
                  resultSourceMessage.bind (fun message => ostr message "toolName") ==
                    some "stale-second" &&
                  resultSource.bind (fun raw => ostr raw "resultExtension") ==
                    some "keep-empty-result-source" &&
                  match importPi first with
                  | .error _ => false
                  | .ok restored =>
                      piEmptyToolNameRestoredShape restored &&
                        match exportPiChecked restored with
                        | .error _ => false
                        | .ok second =>
                            piTestJsonLines second == piTestJsonLines first &&
                              match importPi second with
                              | .error _ => false
                              | .ok twoHop => piEmptyToolNameRestoredShape twoHop
      | _, _ => false

example : piEmptyResolvedToolNameIsAuthoritative = true := by native_decide

/-- Pi does not encode Loom thread declarations. This source is structurally
invalid, yet the unchecked renderer normalizes it to a one-main-thread artifact;
checked export must reject the source before that normalization can hide it. -/
def piInvalidSourceCannotNormalizeThroughCheckedExport : Bool :=
  let invalid : Transcript := { piTimestampTranscript with
    threads := #[{ kind := .main }, { kind := .main }] }
  (violations invalid).contains (.mainThreadCount 2) &&
    match importPi (renderPiCandidate invalid) with
    | .error _ => false
    | .ok normalized =>
        (violations normalized).isEmpty && normalized.threads.size == 1 &&
          piTestCheckedRejected invalid && exportPi invalid == "" &&
          match piExportPreflight invalid with
          | .error _ => true
          | .ok _ => false

example : piInvalidSourceCannotNormalizeThroughCheckedExport = true := by native_decide

private def piReservedTextBlock (stamp : Json) : Json :=
  Json.mkObj [
    ("type", Json.str "text"), ("text", Json.str "must-not-downgrade"),
    (piCarrierKey, stamp)]

private def piCompleteBlockStamp (author : String) (version : Nat := piCarrierVersion) : Json :=
  Json.mkObj [
    ("version", Json.num version), ("kind", Json.str "block"),
    ("author", Json.str author), ("constructor", Json.str "unmodeled"),
    ("label", Json.str "reserved"),
    ("raw", Json.mkObj [("opaque", Json.bool true)])]

private def piReservedUserBlockFixture (stamp : Json) : String :=
  piTestFixture [piTestMessageEntry "reserved-user" none
    (piTestUserMessage (Json.arr #[piReservedTextBlock stamp]))]

private def piReservedAssistantBlockFixture (stamp : Json) : String :=
  piTestFixture [piTestMessageEntry "reserved-assistant" none
    (piTestAssistantMessage #[piReservedTextBlock stamp])]

private def piIncompleteTargetModelStamp : Json :=
  Json.mkObj [
    ("version", Json.num piCarrierVersion),
    ("targetModelChange", Json.mkObj [
      ("author", Json.str "missing-provenance")])]

private def piMalformedReservedFixtures : List String := [
  piReservedUserBlockFixture (Json.str "not-an-object"),
  piReservedUserBlockFixture (piCompleteBlockStamp "user" 2),
  piReservedUserBlockFixture (Json.mkObj [
    ("version", Json.num piCarrierVersion), ("kind", Json.str "block"),
    ("author", Json.str "user"), ("constructor", Json.str "unmodeled"),
    ("label", Json.str "missing-raw")]),
  piReservedAssistantBlockFixture (Json.arr #[]),
  piReservedAssistantBlockFixture (piCompleteBlockStamp "assistant" 99),
  piReservedAssistantBlockFixture (Json.mkObj [
    ("version", Json.num piCarrierVersion), ("kind", Json.str "block"),
    ("author", Json.str "assistant"),
    ("label", Json.str "missing-constructor-and-raw")]),
  piTestFixture [overlayJsonFields
    (piTestMessageEntry "bad-entry-stamp" none
      (piTestUserMessage (Json.str "x"))) [piCarrierKey] [
        (piCarrierKey, Json.mkObj [
          ("version", Json.num piCarrierVersion),
          ("time", Json.str "not-an-object")])]],
  piTestFixture [overlayJsonFields
    (piTestEntry "model_change" "bad-target-model" none [
      ("provider", Json.str "p"), ("modelId", Json.str "m")])
    [piCarrierKey] [(piCarrierKey, piIncompleteTargetModelStamp)]],
  piTestFixture [piTestMessageEntry "bad-user-call-ref" none
    (overlayJsonFields (piTestUserMessage (Json.str "x")) [piCarrierKey] [
      (piCarrierKey, Json.mkObj [
        ("version", Json.num piCarrierVersion),
        ("toolCallRef", Json.mkObj [
          ("state", Json.str "unresolved")])])])],
  piTestFixture [piTestMessageEntry "bad-assistant-history" none
    (overlayJsonFields (piTestAssistantMessage #[]) [piCarrierKey] [
      (piCarrierKey, Json.mkObj [
        ("version", Json.num piCarrierVersion),
        ("assistantHistory", Json.mkObj [
          ("mode", Json.str "context")])])])],
  piTestFixture [piTestMessageEntry "bad-tool-error" none
    (overlayJsonFields
      (piTestToolResultMessage "missing" "tool" false "x") [piCarrierKey] [
        (piCarrierKey, Json.mkObj [
          ("version", Json.num piCarrierVersion),
          ("toolError", Json.str "not-an-object")])])],
  piTestFixture [] (overlayJsonFields piTestHeader [piCarrierKey] [
    (piCarrierKey, Json.mkObj [
      ("version", Json.num piCarrierVersion),
      ("sourceEnvironment", Json.str "not-an-object")])])]

private def piOrdinaryUnstampedBlocksFixture : String :=
  piTestFixture [
    piTestMessageEntry "ordinary-user" none
      (piTestUserMessage (Json.arr #[Json.mkObj [
        ("type", Json.str "text"), ("text", Json.str "ordinary")]])),
    piTestMessageEntry "ordinary-assistant" (some "ordinary-user")
      (piTestAssistantMessage #[
        Json.mkObj [("type", Json.str "thinking"),
          ("thinking", Json.str "ordinary thought")],
        piCallBlock "ordinary-call" "read"] "toolUse")]

/-- The reserved key is fail-closed at every recognized schema surface. The
same native block constructors remain accepted when that key is absent. -/
def piReservedMetadataIsFailClosed : Bool :=
  piMalformedReservedFixtures.length == 12 &&
    piMalformedReservedFixtures.all piTestRejected &&
    piTestExactCycle piOrdinaryUnstampedBlocksFixture

example : piReservedMetadataIsFailClosed = true := by native_decide

/-- The fixed-point guarantees above apply only after strict checked export.
Missing target identity or active-leaf state is still refused; the ordering fix
does not turn malformed target requests into best-effort artifacts. -/
def piForeignUserOrderingRefusalBoundaryPinned : Bool :=
  let missingTarget := {
    piForeignUserRunCoverageTranscript with
    origin := piForeignTranscriptOrigin "pi-user-runs-missing-target" }
  let missingLeaf := {
    piForeignUserRunCoverageTranscript with activeLeaf := none }
  piTestCheckedRejected missingTarget && piTestCheckedRejected missingLeaf &&
    exportPi missingTarget == "" && exportPi missingLeaf == ""

example : piForeignUserOrderingRefusalBoundaryPinned = true := by native_decide

def piNativeAssistantMetadataAndCountExact : Bool :=
  match importPi piNativeStopFixture with
  | .error _ => false
  | .ok native =>
      piTargetSummary native == {
        nativeAssistantContextMessages := 3
        historicalAssistantCarriers := 0
        historicalToolCallCarriers := 0
        historicalToolResultCarriers := 0
        resumable := true } &&
        match exportPiChecked native with
        | .error _ => false
        | .ok output => piTestJsonLines output == piTestJsonLines piNativeStopFixture

example : piNativeAssistantMetadataAndCountExact = true := by native_decide

end LoomConvert
