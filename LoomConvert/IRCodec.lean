import Loom
import LoomConvert.Json

/-! The single IR codec. The canonical encoding is Wire v0, including its
string-valued indexes. No harness adapter is imported here. -/
namespace LoomConvert
open Loom
open Lean (Json)

private def requireIndex (ctx : String) (expected : Nat) (j : Json) : Except String Unit := do
  let actual ← natField ctx j "index"
  if actual == expected then
    pure ()
  else
    .error s!"{ctx}: index {actual} does not match position {expected}"

def formatToWireString : Format → String
  | .pi => "pi"
  | .claudeCode => "claude"
  | .codexCli => "codex"
  | .cursorAgent => "cursor-agent"
  | .cursorIde => "cursor-ide"
  | .hermes => "hermes"
  | .googleAiStudio => "google-ai-studio"
  | .openCode => "opencode"
  | .other name => name

def formatFromWireString : String → Format
  | "pi" => .pi
  | "claude" => .claudeCode
  | "codex" => .codexCli
  | "cursor-agent" => .cursorAgent
  | "cursor-ide" => .cursorIde
  | "hermes" => .hermes
  | "google-ai-studio" => .googleAiStudio
  | "opencode" => .openCode
  | name => .other name

/-- A legacy bare label is ambiguous only when an open `.other` value reuses a
spelling assigned to a built-in constructor. The object codec adds a marker in
that case; ordinary built-ins and unknown labels retain their v0 shape. -/
private def formatNeedsOtherMarker : Format → Bool
  | .other name =>
      match formatFromWireString name with
      | .other _ => false
      | _ => true
  | _ => false

def canonicalToolToWireString : CanonicalTool → String
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

def canonicalToolFromWireString (ctx value : String) : Except String CanonicalTool :=
  match value with
  | "bash" => .ok .bash
  | "read" => .ok .read
  | "write" => .ok .write
  | "edit" => .ok .edit
  | "grep" => .ok .grep
  | "glob" => .ok .glob
  | "webFetch" => .ok .webFetch
  | "webSearch" => .ok .webSearch
  | "agentSpawn" => .ok .agentSpawn
  | "applyPatch" => .ok .applyPatch
  | other => .error s!"{ctx}: unsupported canonical tool '{other}'"

def originToWireJson (o : Origin) : Json :=
  Json.mkObj ([
    ("format", Json.str (formatToWireString o.format)),
    ("sourceRef", Json.str o.sourceRef)
  ] ++ (if formatNeedsOtherMarker o.format then [("formatOther", Json.bool true)] else [])
    ++ optStr "rawId" o.rawId ++ optJson "extras" o.extras)

def originFromWireJson (ctx : String) (j : Json) : Except String Origin := do
  let formatLabel ← strField ctx j "format"
  let format := if (← optBoolField ctx j "formatOther").getD false then
      Format.other formatLabel
    else
      formatFromWireString formatLabel
  let sourceRef ← strField ctx j "sourceRef"
  let rawId ← optStrField ctx j "rawId"
  let extras := (j.getObjVal? "extras").toOption
  pure { format, sourceRef, rawId, extras }

def timeToWireJson : Time → Json
  | .recorded t => Json.mkObj [("kind", Json.str "recorded"), ("ms", Json.str (toString t.ms))]
  | .interpolated t basis =>
      Json.mkObj [("kind", Json.str "interpolated"), ("ms", Json.str (toString t.ms)), ("basis", Json.str basis)]
  | .sequenced ord => Json.mkObj [("kind", Json.str "sequenced"), ("ord", Json.str (toString ord))]
  | .absent => Json.mkObj [("kind", Json.str "absent")]

def timeFromWireJson (ctx : String) (j : Json) : Except String Time := do
  match ← strField ctx j "kind" with
  | "recorded" => pure (.recorded ⟨← natField ctx j "ms"⟩)
  | "interpolated" => pure (.interpolated ⟨← natField ctx j "ms"⟩ (← strField ctx j "basis"))
  | "sequenced" => pure (.sequenced (← natField ctx j "ord"))
  | "absent" => pure .absent
  | other => .error s!"{ctx}: unsupported time kind '{other}'"

def errorSignalToWireJson : ErrorSignal → Json
  | .native isError =>
      Json.mkObj [("kind", Json.str "native"), ("isError", Json.str (toString isError))]
  | .heuristic isError heuristic =>
      Json.mkObj [("kind", Json.str "heuristic"), ("isError", Json.str (toString isError)), ("method", Json.str heuristic)]
  | .structured isError source =>
      Json.mkObj [("kind", Json.str "structured"), ("isError", Json.str (toString isError)), ("source", Json.str source)]
  | .unrecorded => Json.mkObj [("kind", Json.str "unrecorded")]

def errorSignalFromWireJson (ctx : String) (j : Json) : Except String ErrorSignal := do
  match ← strField ctx j "kind" with
  | "native" => pure (.native (← boolField ctx j "isError"))
  | "inferred" => pure (.heuristic (← boolField ctx j "isError") (← strField ctx j "heuristic"))
  | "heuristic" => pure (.heuristic (← boolField ctx j "isError") (← strField ctx j "method"))
  | "structured" => pure (.structured (← boolField ctx j "isError") (← strField ctx j "source"))
  | "unrecorded" => pure .unrecorded
  | other => .error s!"{ctx}: unsupported error kind '{other}'"

example : (do
    let value ← Json.parse "{\"kind\":\"inferred\",\"isError\":true,\"heuristic\":\"x\"}"
    errorSignalFromWireJson "error" value).toOption = some (.heuristic true "x") := by native_decide

example : ([.native false, .native true, .heuristic true "x",
    .structured false "exit_code", .structured true "runner.status", .unrecorded] : List ErrorSignal).all
    (fun error => decide ((errorSignalFromWireJson "error" (errorSignalToWireJson error)).toOption = some error)) = true := by native_decide

def callRefToWireJson : CallRef → Json
  | .resolved entry block =>
      Json.mkObj [("kind", Json.str "resolved"), ("entry", Json.str (toString entry)), ("block", Json.str (toString block))]
  | .unresolved rawId note =>
      Json.mkObj ([("kind", Json.str "unresolved"), ("note", Json.str note)] ++ optStr "rawId" rawId)

def callRefFromWireJson (ctx : String) (j : Json) : Except String CallRef := do
  match ← strField ctx j "kind" with
  | "resolved" => pure (.resolved (← natField ctx j "entry") (← natField ctx j "block"))
  | "unresolved" => pure (.unresolved (← optStrField ctx j "rawId") (← strField ctx j "note"))
  | other => .error s!"{ctx}: unsupported callRef kind '{other}'"

def threadKindToWireJson : ThreadKind → Json
  | .main => Json.mkObj [("kind", Json.str "main")]
  | .sidechain anchor =>
      Json.mkObj [("kind", Json.str "sidechain"), ("anchor", callRefToWireJson anchor)]
  | .detached note =>
      Json.mkObj [("kind", Json.str "detached"), ("note", Json.str note)]

def threadKindFromWireJson (ctx : String) (j : Json) : Except String ThreadKind := do
  match ← strField ctx j "kind" with
  | "main" => pure .main
  | "sidechain" => pure (.sidechain (← callRefFromWireJson s!"{ctx}.anchor" (← objField ctx j "anchor")))
  | "detached" => pure (.detached (← strField ctx j "note"))
  | other => .error s!"{ctx}: unsupported thread kind '{other}'"

def threadToWireJson (i : Nat) (th : Thread) : Json :=
  Json.mkObj ([
    ("index", Json.str (toString i)),
    ("kind", threadKindToWireJson th.kind)
  ] ++ optStr "label" th.label)

def threadFromWireJson (i : Nat) (j : Json) : Except String Thread := do
  let ctx := s!"threads[{i}]"
  requireIndex ctx i j
  let kind ← threadKindFromWireJson s!"{ctx}.kind" (← objField ctx j "kind")
  let label ← optStrField ctx j "label"
  pure { kind, label }

def userBlockToWireJson (b : UserBlock) : Json :=
  match b with
  | .text text =>
      Json.mkObj [("type", Json.str "text"), ("text", Json.str text)]
  | .media mimeType data =>
      Json.mkObj [("type", Json.str "media"), ("mimeType", Json.str mimeType),
        ("data", Json.str data)]
  | .unmodeled label raw =>
      Json.mkObj [("type", Json.str "unmodeled"), ("label", Json.str label), ("raw", raw)]

def userBlockFromWireJson (ctx : String) (j : Json) : Except String UserBlock := do
  match ← strField ctx j "type" with
  | "text" => pure (.text (← strField ctx j "text"))
  | "media" => pure (.media (← strField ctx j "mimeType") (← strField ctx j "data"))
  | "unmodeled" => pure (.unmodeled (← strField ctx j "label") (← objField ctx j "raw"))
  | label => pure (.unmodeled label j)

def assistantBlockToWireJson (b : AssistantBlock) : Json :=
  match b with
  | .text text =>
      Json.mkObj [("type", Json.str "text"), ("text", Json.str text)]
  | .thinking thinking signature =>
      Json.mkObj ([("type", Json.str "thinking"),
        ("thinking", Json.str thinking)] ++ optStr "thinkingSignature" signature)
  | .toolCall name arguments rawId =>
      Json.mkObj ([
        ("type", Json.str "toolCall"),
        ("name", Json.str name.raw),
        ("arguments", arguments)]
        ++ optStr "canonical" (name.canonical.map canonicalToolToWireString)
        ++ optStr "id" rawId)
  | .media mimeType data =>
      Json.mkObj [("type", Json.str "media"), ("mimeType", Json.str mimeType),
        ("data", Json.str data)]
  | .unmodeled label raw =>
      Json.mkObj [("type", Json.str "unmodeled"), ("label", Json.str label), ("raw", raw)]

def assistantBlockFromWireJson (ctx : String) (j : Json) : Except String AssistantBlock := do
  match ← strField ctx j "type" with
  | "text" => pure (.text (← strField ctx j "text"))
  | "thinking" => pure (.thinking (← strField ctx j "thinking") (← optStrField ctx j "thinkingSignature"))
  | "toolCall" =>
      let canonical ← match ← optStrField ctx j "canonical" with
        | some value => pure (some (← canonicalToolFromWireString s!"{ctx}.canonical" value))
        | none => pure none
      pure (.toolCall { raw := (← strField ctx j "name"), canonical }
        (← objField ctx j "arguments") (← optStrField ctx j "id"))
  | "media" => pure (.media (← strField ctx j "mimeType") (← strField ctx j "data"))
  | "unmodeled" => pure (.unmodeled (← strField ctx j "label") (← objField ctx j "raw"))
  | label => pure (.unmodeled label j)

def envBlockToWireJson : EnvBlock → Json
  | .toolResult call content error =>
      Json.mkObj [
        ("type", Json.str "toolResult"),
        ("call", callRefToWireJson call),
        ("content", Json.arr ((content.map userBlockToWireJson).toArray)),
        ("error", errorSignalToWireJson error)
      ]
  | .unmodeled label raw =>
      Json.mkObj [("type", Json.str "unmodeled"), ("label", Json.str label), ("raw", raw)]

def envBlockFromWireJson (ctx : String) (j : Json) : Except String EnvBlock := do
  match ← strField ctx j "type" with
  | "toolResult" =>
      let content ← parseJsonList s!"{ctx}.content" (← arrField ctx j "content") userBlockFromWireJson
      pure (.toolResult (← callRefFromWireJson s!"{ctx}.call" (← objField ctx j "call"))
        content (← errorSignalFromWireJson s!"{ctx}.error" (← objField ctx j "error")))
  | "unmodeled" => pure (.unmodeled (← strField ctx j "label") (← objField ctx j "raw"))
  | label => pure (.unmodeled label j)

def compactionCoverageToWireJson : CompactionCoverage → Json
  | .knownPrefix firstKept =>
      Json.mkObj [("kind", Json.str "knownPrefix"), ("firstKept", Json.str (toString firstKept))]
  | .unknownPrefix => Json.mkObj [("kind", Json.str "unknownPrefix")]

def compactionCoverageFromWireJson (ctx : String) (j : Json) : Except String CompactionCoverage := do
  match ← strField ctx j "kind" with
  | "knownPrefix" => pure (.knownPrefix (← natField ctx j "firstKept"))
  | "unknownPrefix" => pure .unknownPrefix
  | other => .error s!"{ctx}: unsupported compaction coverage kind '{other}'"

def metaEventToWireJson : MetaEvent → Json
  | .modelChange prev next =>
      Json.mkObj ([("type", Json.str "modelChange")] ++ optStr "prev" prev ++ optStr "next" next)
  | .thinkingLevelChange prev next =>
      Json.mkObj ([("type", Json.str "thinkingLevelChange")] ++ optStr "prev" prev ++ optStr "next" next)
  | .permissionMode mode =>
      Json.mkObj [("type", Json.str "permissionMode"), ("mode", Json.str mode)]
  | .branchSummary summary =>
      Json.mkObj [("type", Json.str "branchSummary"), ("summary", Json.str summary)]
  | .custom label raw =>
      Json.mkObj [("type", Json.str "custom"), ("label", Json.str label), ("raw", raw)]

def metaEventFromWireJson (ctx : String) (j : Json) : Except String MetaEvent := do
  match ← strField ctx j "type" with
  | "modelChange" => pure (.modelChange (← optStrField ctx j "prev") (← optStrField ctx j "next"))
  | "thinkingLevelChange" => pure (.thinkingLevelChange (← optStrField ctx j "prev") (← optStrField ctx j "next"))
  | "permissionMode" => pure (.permissionMode (← strField ctx j "mode"))
  | "branchSummary" => pure (.branchSummary (← strField ctx j "summary"))
  | "custom" => pure (.custom (← strField ctx j "label") (← objField ctx j "raw"))
  | label => pure (.custom label j)

def payloadToWireJson : Payload → Json
  | .userMsg blocks =>
      Json.mkObj [("type", Json.str "userMsg"),
        ("blocks", Json.arr ((blocks.map userBlockToWireJson).toArray))]
  | .assistantMsg blocks =>
      Json.mkObj [("type", Json.str "assistantMsg"),
        ("blocks", Json.arr ((blocks.map assistantBlockToWireJson).toArray))]
  | .envMsg blocks =>
      Json.mkObj [("type", Json.str "envMsg"),
        ("blocks", Json.arr ((blocks.map envBlockToWireJson).toArray))]
  | .otherMsg role blocks =>
      Json.mkObj [("type", Json.str "otherMsg"), ("role", Json.str role),
        ("blocks", Json.arr ((blocks.map userBlockToWireJson).toArray))]
  | .compaction summary coverage tokensBefore =>
      Json.mkObj ([("type", Json.str "compaction"),
        ("summary", Json.str summary),
        ("coverage", compactionCoverageToWireJson coverage)]
        ++ optNat "tokensBefore" tokensBefore)
  | .event e =>
      Json.mkObj [("type", Json.str "event"), ("event", metaEventToWireJson e)]

def payloadFromWireJson (ctx : String) (j : Json) : Except String Payload := do
  match ← strField ctx j "type" with
  | "userMsg" =>
      let blocks ← parseJsonList s!"{ctx}.blocks" (← arrField ctx j "blocks") userBlockFromWireJson
      pure (.userMsg blocks)
  | "assistantMsg" =>
      let blocks ← parseJsonList s!"{ctx}.blocks" (← arrField ctx j "blocks") assistantBlockFromWireJson
      pure (.assistantMsg blocks)
  | "envMsg" =>
      let blocks ← parseJsonList s!"{ctx}.blocks" (← arrField ctx j "blocks") envBlockFromWireJson
      pure (.envMsg blocks)
  | "otherMsg" =>
      let blocks ← parseJsonList s!"{ctx}.blocks" (← arrField ctx j "blocks") userBlockFromWireJson
      pure (.otherMsg (← strField ctx j "role") blocks)
  | "compaction" =>
      pure (.compaction (← strField ctx j "summary")
        (← compactionCoverageFromWireJson s!"{ctx}.coverage" (← objField ctx j "coverage"))
        (← optNatField ctx j "tokensBefore"))
  | "event" =>
      pure (.event (← metaEventFromWireJson s!"{ctx}.event" (← objField ctx j "event")))
  | other => .error s!"{ctx}: unsupported payload type '{other}'"

def entryDispositionToWireString : EntryDisposition -> String
  | .native => "native"
  | .historicalUnverified => "historicalUnverified"

def entryDispositionFromWireString
    (ctx value : String) : Except String EntryDisposition :=
  match value with
  | "native" => .ok .native
  | "historicalUnverified" => .ok .historicalUnverified
  | other => .error s!"{ctx}: unsupported entry disposition '{other}'"

private def entryDispositionWireField : EntryDisposition -> List (String × Json)
  | .native => []
  | disposition =>
      [("disposition", Json.str (entryDispositionToWireString disposition))]

def entryToWireJson (i : Nat) (e : Entry) : Json :=
  Json.mkObj ([
    ("index", Json.str (toString i)),
    ("thread", Json.str (toString e.thread)),
    ("time", timeToWireJson e.time),
    ("payload", payloadToWireJson e.payload),
    ("origin", originToWireJson e.origin)
  ] ++ entryDispositionWireField e.disposition ++ optNat "parent" e.parent)

def entryFromWireJson (i : Nat) (j : Json) : Except String Entry := do
  let ctx := s!"entries[{i}]"
  requireIndex ctx i j
  let disposition ← match ← optStrField ctx j "disposition" with
    | some value => entryDispositionFromWireString s!"{ctx}.disposition" value
    | none => pure .native
  pure {
    parent := (← optNatField ctx j "parent")
    thread := (← natField ctx j "thread")
    time := (← timeFromWireJson s!"{ctx}.time" (← objField ctx j "time"))
    payload := (← payloadFromWireJson s!"{ctx}.payload" (← objField ctx j "payload"))
    origin := (← originFromWireJson s!"{ctx}.origin" (← objField ctx j "origin"))
    disposition
  }

def envInfoToWireJson (e : EnvInfo) : Json :=
  Json.mkObj (optStr "cwd" e.cwd
    ++ optStr "model" e.model
    ++ optStr "provider" e.provider
    ++ optStr "harnessVersion" e.harnessVersion
    ++ optStr "instructions" e.instructions
    ++ optStr "sessionId" e.sessionId)

def envInfoFromWireJson (ctx : String) (j : Json) : Except String EnvInfo := do
  pure {
    cwd := (← optStrField ctx j "cwd")
    model := (← optStrField ctx j "model")
    provider := (← optStrField ctx j "provider")
    harnessVersion := (← optStrField ctx j "harnessVersion")
    instructions := (← optStrField ctx j "instructions")
    sessionId := (← optStrField ctx j "sessionId")
  }

def assumptionKindToWireString : AssumptionKind → String
  | .dedupDropped => "dedupDropped"
  | .timeInterpolated => "timeInterpolated"
  | .timeSequenced => "timeSequenced"
  | .errorInferred => "errorInferred"
  | .roleCoerced => "roleCoerced"
  | .toolNameMapped => "toolNameMapped"
  | .idSynthesized => "idSynthesized"
  | .contentSkipped => "contentSkipped"
  | .activeLeafGuessed => "activeLeafGuessed"
  | .other label => label

def assumptionKindFromWireString : String → AssumptionKind
  | "dedupDropped" => .dedupDropped
  | "timeInterpolated" => .timeInterpolated
  | "timeSequenced" => .timeSequenced
  | "errorInferred" => .errorInferred
  | "roleCoerced" => .roleCoerced
  | "toolNameMapped" => .toolNameMapped
  | "idSynthesized" => .idSynthesized
  | "contentSkipped" => .contentSkipped
  | "activeLeafGuessed" => .activeLeafGuessed
  | label => .other label

private def assumptionKindNeedsOtherMarker : AssumptionKind → Bool
  | .other label =>
      match assumptionKindFromWireString label with
      | .other _ => false
      | _ => true
  | _ => false

def importNoteToWireJson (n : ImportNote) : Json :=
  Json.mkObj ([
    ("kind", Json.str (assumptionKindToWireString n.kind)),
    ("detail", Json.str n.detail)
  ] ++ (if assumptionKindNeedsOtherMarker n.kind then [("kindOther", Json.bool true)] else [])
    ++ optStr "loc" n.loc)

def importNoteFromWireJson (ctx : String) (j : Json) : Except String ImportNote := do
  let kindLabel ← strField ctx j "kind"
  pure {
    kind := if (← optBoolField ctx j "kindOther").getD false then
        AssumptionKind.other kindLabel
      else
        assumptionKindFromWireString kindLabel
    loc := (← optStrField ctx j "loc")
    detail := (← strField ctx j "detail")
  }

def exportLoomWireJson (t : Transcript) : Json :=
  Json.mkObj ([
    ("schema", Json.str "loom.transcript.v0"),
    ("origin", originToWireJson t.origin),
    ("env", envInfoToWireJson t.env),
    ("threads", Json.arr (((t.threads.toList.zipIdx).map (fun (th, i) => threadToWireJson i th)).toArray)),
    ("entries", Json.arr (((t.entries.toList.zipIdx).map (fun (e, i) => entryToWireJson i e)).toArray)),
    ("importNotes", Json.arr ((t.importNotes.map importNoteToWireJson).toArray))
  ] ++ optNat "activeLeaf" t.activeLeaf)

/-- Loom IR → versioned JSON wire object. -/
def exportLoomWire (t : Transcript) : String :=
  (exportLoomWireJson t).compress

def importLoomWireJson (j : Json) : Except String Transcript := do
  let schema ← strField "loom wire" j "schema"
  if schema != "loom.transcript.v0" then
    .error s!"loom wire: unsupported schema '{schema}'"
  else
    let threads ← ((← arrField "loom wire" j "threads").toList.zipIdx).mapM
      (fun (tj, i) => threadFromWireJson i tj)
    let entries ← ((← arrField "loom wire" j "entries").toList.zipIdx).mapM
      (fun (ej, i) => entryFromWireJson i ej)
    let notes ← parseJsonList "importNotes" (← arrField "loom wire" j "importNotes") importNoteFromWireJson
    pure {
      threads := threads.toArray
      entries := entries.toArray
      env := (← envInfoFromWireJson "loom wire.env" (← objField "loom wire" j "env"))
      activeLeaf := (← optNatField "loom wire" j "activeLeaf")
      importNotes := notes
      origin := (← originFromWireJson "loom wire.origin" (← objField "loom wire" j "origin"))
    }

/-- Versioned JSON Loom wire object → Loom IR. -/
def importLoomWire (text : String) : Except String Transcript := do
  importLoomWireJson (← Json.parse text)


/-- The shape guides compatibility rewriting only. Opaque JSON in arguments and
`raw` is never traversed, so alias-like keys in user data remain untouched. -/
inductive FragmentShape where
  | user | assistant | env | call | error | event | coverage | payload
  deriving DecidableEq

private inductive FragmentField where
  | string | optionalString | number | optionalNumber | boolean
  | nested (shape : FragmentShape) | array (shape : FragmentShape)

private def fragmentDiscriminator : FragmentShape → String
  | .call | .error | .coverage => "kind"
  | _ => "type"

private def fragmentFields (shape : FragmentShape) (tag : String) :
    List (String × List String × FragmentField) :=
  match shape, tag with
  | .user, "media" | .assistant, "media" => [("data", ["locator"], .string)]
  | .assistant, "thinking" => [("thinkingSignature", ["signature"], .optionalString)]
  | .assistant, "toolCall" => [("canonical", [], .optionalString), ("id", ["rawId"], .optionalString)]
  | .call, "resolved" => [("entry", [], .number), ("block", [], .number)]
  | .call, "unresolved" => [("rawId", [], .optionalString)]
  | .error, "native" => [("isError", ["value"], .boolean)]
  | .error, "heuristic" => [("isError", ["value"], .boolean), ("method", ["heuristic"], .string)]
  | .error, "structured" => [("isError", ["value"], .boolean)]
  | .env, "toolResult" => [("call", [], .nested .call), ("content", [], .array .user),
      ("error", [], .nested .error)]
  | .event, "modelChange" | .event, "thinkingLevelChange" =>
      [("prev", ["previous"], .optionalString), ("next", [], .optionalString)]
  | .coverage, "knownPrefix" => [("firstKept", [], .number)]
  | .payload, "userMsg" | .payload, "otherMsg" => [("blocks", [], .array .user)]
  | .payload, "assistantMsg" => [("blocks", [], .array .assistant)]
  | .payload, "envMsg" => [("blocks", [], .array .env)]
  | .payload, "compaction" => [("coverage", [], .nested .coverage), ("tokensBefore", [], .optionalNumber)]
  | .payload, "event" => [("event", [], .nested .event)]
  | _, _ => []

private def eraseJsonField (j : Json) (key : String) : Json :=
  match j with
  | .obj fields => .obj (fields.erase key)
  | _ => j

/-- Duplicate aliases are ambiguous even if their values happen to agree. -/
private def normalizeAlias (j : Json) (key : String) (aliases : List String) :
    Except String Json := do
  let present := (key :: aliases).filterMap (fun name => (oobj j name).map (name, ·))
  match present with
  | [] => pure j
  | [(name, value)] => pure ((eraseJsonField j name).setObjVal! key value)
  | _ => .error s!"ambiguous IR field '{key}'"

private def normalizeFragment : Nat → FragmentShape → Json → Except String Json
  | 0, _, _ => .error "IR fragment nesting limit"
  | fuel + 1, shape, source => do
      ensureObj "IR fragment" source
      let discriminator := fragmentDiscriminator shape
      let mut value ← normalizeAlias source discriminator
        (if discriminator == "type" then ["kind"] else [])
      let mut tag ← strField "IR fragment" value discriminator
      if shape == .error && tag == "inferred" then
        tag := "heuristic"
        value := value.setObjVal! discriminator (Json.str tag)
      for (key, aliases, field) in fragmentFields shape tag do
        value ← normalizeAlias value key aliases
        match oobj value key with
        | none => pure () -- Required fields are checked by the codec below.
        | some raw =>
          let normalized ← match field with
            | .string => pure (some raw)
            | .optionalString => pure (if raw == .null then none else some raw)
            | .number => pure (some (.str (toString (← natJson key raw))))
            | .optionalNumber =>
                if raw == .null then pure none
                else pure (some (.str (toString (← natJson key raw))))
            | .boolean => pure (some (.str (toString (← boolJson key raw))))
            | .nested child => pure (some (← normalizeFragment fuel child raw))
            | .array child => do
                let values ← arrJson key raw
                pure (some (.arr (← values.mapM (normalizeFragment fuel child))))
          value := eraseJsonField value key
          if let some normalized := normalized then
            value := value.setObjVal! key normalized
      pure value

/-- Canonical historical carriers retain `kind`, nullable option fields, and
JSON numbers/booleans. Their semantic fields come exclusively from ToJson. -/
private def fragmentToCarrier : Nat → FragmentShape → Json → Json
  | 0, _, value => value
  | fuel + 1, shape, source => Id.run do
      let discriminator := fragmentDiscriminator shape
      let tag := (ostr source discriminator).getD ""
      let mut value := source
      for (key, _, field) in fragmentFields shape tag do
        let raw := (oobj value key).getD .null
        let outputKey := if key == "thinkingSignature" then "signature"
          else if shape == .assistant && key == "id" then "rawId" else key
        let converted := match field with
          | .number | .optionalNumber => (natJson key raw).toOption.map Json.num |>.getD raw
          | .boolean => (boolJson key raw).toOption.map Json.bool |>.getD raw
          | .nested child => fragmentToCarrier fuel child raw
          | .array child => match raw with
              | .arr values => .arr (values.map (fragmentToCarrier fuel child))
              | _ => raw
          | _ => raw
        value := (eraseJsonField value key).setObjVal! outputKey converted
      if discriminator == "type" then
        value := (eraseJsonField value "type").setObjVal! "kind" (Json.str tag)
      return value

class Fragment (α : Type) where
  shape : FragmentShape

/-- Historical carriers and Wire share their semantic encoder. Only their
outer field convention differs; Wire v0's emitted bytes remain unchanged. -/
def toCarrierJson {α : Type} [Lean.ToJson α] [Fragment α] (value : α) : Json :=
  fragmentToCarrier 8 (Fragment.shape (α := α)) (Lean.toJson value)

/-- Strict equality after known aliases are normalized. Unknown fields remain
in the comparison, including all opaque JSON, so carrier validation stays closed. -/
def carrierJsonMatches {α : Type} [Lean.ToJson α] [Fragment α]
    (raw : Json) (value : α) : Bool :=
  match normalizeFragment 8 (Fragment.shape (α := α)) raw with
  | .ok normalized => normalized == Lean.toJson value
  | .error _ => false

def fromJsonAt {α : Type} [Lean.FromJson α] (ctx : String) (value : Json) : Except String α :=
  (Lean.fromJson? value).mapError (fun error => s!"{ctx}: {error}")

instance : Lean.ToJson CanonicalTool := ⟨Json.str ∘ canonicalToolToWireString⟩
instance : Lean.FromJson CanonicalTool := ⟨fun j => do
  canonicalToolFromWireString "canonical tool" (← strJson "canonical tool" j)⟩

instance : Fragment UserBlock := ⟨.user⟩
instance : Lean.ToJson UserBlock := ⟨userBlockToWireJson⟩
instance : Lean.FromJson UserBlock := ⟨fun raw => do
  userBlockFromWireJson "UserBlock" (← normalizeFragment 8 .user raw)⟩

instance : Fragment AssistantBlock := ⟨.assistant⟩
instance : Lean.ToJson AssistantBlock := ⟨assistantBlockToWireJson⟩
instance : Lean.FromJson AssistantBlock := ⟨fun raw => do
  assistantBlockFromWireJson "AssistantBlock" (← normalizeFragment 8 .assistant raw)⟩

instance : Fragment EnvBlock := ⟨.env⟩
instance : Lean.ToJson EnvBlock := ⟨envBlockToWireJson⟩
instance : Lean.FromJson EnvBlock := ⟨fun raw => do
  envBlockFromWireJson "EnvBlock" (← normalizeFragment 8 .env raw)⟩

instance : Fragment CallRef := ⟨.call⟩
instance : Lean.ToJson CallRef := ⟨callRefToWireJson⟩
instance : Lean.FromJson CallRef := ⟨fun raw => do
  callRefFromWireJson "CallRef" (← normalizeFragment 8 .call raw)⟩

instance : Fragment ErrorSignal := ⟨.error⟩
instance : Lean.ToJson ErrorSignal := ⟨errorSignalToWireJson⟩
instance : Lean.FromJson ErrorSignal := ⟨fun raw => do
  errorSignalFromWireJson "ErrorSignal" (← normalizeFragment 8 .error raw)⟩

instance : Fragment MetaEvent := ⟨.event⟩
instance : Lean.ToJson MetaEvent := ⟨metaEventToWireJson⟩
instance : Lean.FromJson MetaEvent := ⟨fun raw => do
  metaEventFromWireJson "MetaEvent" (← normalizeFragment 8 .event raw)⟩

instance : Fragment CompactionCoverage := ⟨.coverage⟩
instance : Lean.ToJson CompactionCoverage := ⟨compactionCoverageToWireJson⟩
instance : Lean.FromJson CompactionCoverage := ⟨fun raw => do
  compactionCoverageFromWireJson "CompactionCoverage" (← normalizeFragment 8 .coverage raw)⟩

instance : Fragment Payload := ⟨.payload⟩
instance : Lean.ToJson Payload := ⟨payloadToWireJson⟩
instance : Lean.FromJson Payload := ⟨fun raw => do
  payloadFromWireJson "Payload" (← normalizeFragment 8 .payload raw)⟩


private def fragmentDecodesAs {α : Type} [Lean.ToJson α] [Lean.FromJson α]
    (encoded : String) (expected : α) : Bool :=
  match Json.parse encoded >>= Lean.fromJson? with
  | .ok (actual : α) => Lean.toJson actual == Lean.toJson expected
  | .error _ => false

/-- Literal records from all historical field conventions. Index strings are
still canonical for Wire; the compatibility reader also accepts native numbers. -/
def sharedFragmentLegacySpellingsDecode : Bool :=
  ["data", "locator"].all (fun key =>
    let raw := "{\"kind\":\"media\",\"mimeType\":\"image/png\",\"" ++ key ++ "\":\"data:image/png;base64,AA==\"}"
    fragmentDecodesAs raw (UserBlock.media "image/png" "data:image/png;base64,AA==") &&
    fragmentDecodesAs raw (AssistantBlock.media "image/png" "data:image/png;base64,AA==")) &&
  ["isError", "value"].all (fun key =>
    fragmentDecodesAs ("{\"kind\":\"native\",\"" ++ key ++ "\":true}") (.native true : ErrorSignal) &&
    fragmentDecodesAs ("{\"kind\":\"inferred\",\"" ++ key ++ "\":false,\"heuristic\":\"legacy\"}")
      (.heuristic false "legacy" : ErrorSignal)) &&
  ["prev", "previous"].all (fun key =>
    fragmentDecodesAs ("{\"kind\":\"modelChange\",\"" ++ key ++ "\":null,\"next\":\"new\"}")
      (.modelChange none (some "new") : MetaEvent)) &&
  fragmentDecodesAs "{\"kind\":\"resolved\",\"entry\":12,\"block\":3}" (.resolved 12 3 : CallRef) &&
  fragmentDecodesAs "{\"kind\":\"unresolved\",\"rawId\":null,\"note\":\"orphan\"}"
    (.unresolved none "orphan" : CallRef) &&
  fragmentDecodesAs "{\"kind\":\"thinking\",\"thinking\":\"private\",\"signature\":null}"
    (.thinking "private" none : AssistantBlock) &&
  fragmentDecodesAs "{\"type\":\"thinking\",\"thinking\":\"private\",\"thinkingSignature\":\"signed\"}"
    (.thinking "private" (some "signed") : AssistantBlock)

example : sharedFragmentLegacySpellingsDecode = true := by native_decide

/-- Normalization touches modeled schema fields only; user-owned JSON is exact.
Both an extra field and conflicting aliases must continue to fail strict checks. -/
def sharedFragmentCompatibilityIsClosed : Bool := Id.run do
  let raw := Json.mkObj [("kind", .str "media"), ("locator", .str "opaque"),
    ("value", .bool true), ("rawId", .null)]
  let block := AssistantBlock.toolCall ⟨"custom", none⟩ raw none
  let encoded := toCarrierJson block
  return carrierJsonMatches encoded block &&
    oobj encoded "arguments" == some raw &&
    !carrierJsonMatches (encoded.setObjVal! "unexpected" (.bool true)) block &&
    !carrierJsonMatches (Json.mkObj [("kind", .str "media"), ("mimeType", .str "image/png"),
      ("data", .str "a"), ("locator", .str "a")]) (UserBlock.media "image/png" "a") &&
    callRefToWireJson (.resolved 12 3) ==
      Json.mkObj [("kind", .str "resolved"), ("entry", .str "12"), ("block", .str "3")]

example : sharedFragmentCompatibilityIsClosed = true := by native_decide

end LoomConvert
