import LoomConvert.Pi

/-!
# LoomConvert.Wire — versioned Loom IR serialization

This is the non-lossy release artifact for Loom itself. Flat target formats
still refuse sidechain/detached threads; `loom` export preserves them in a
versioned JSON object (`schema: "loom.transcript.v0"`).

Compatibility policy for v0:

* The decoder accepts only `schema: "loom.transcript.v0"`.
* Required fields must be present with the expected type; missing required
  fields are import errors, not fabricated defaults.
* Numeric indexes remain JSON strings on export for backward compatibility.
  Import accepts those strings, and also accepts JSON numbers for readers that
  normalize them.
* `entries[].disposition` is additive. Its omission decodes as `native`, so
  pre-field v0 artifacts retain their meaning and byte shape on re-export.
* Unknown object members are additive and ignored. Unknown format and
  assumption labels use the IR's `.other` escape hatches.
-/

namespace LoomConvert
open Loom
open Lean (Json)

private def optStr (k : String) : Option String → List (String × Json)
  | some s => [(k, Json.str s)]
  | none => []

private def optJson (k : String) : Option Json → List (String × Json)
  | some j => [(k, j)]
  | none => []

private def optNat (k : String) : Option Nat → List (String × Json)
  | some n => [(k, Json.str (toString n))]
  | none => []

private def ensureObj (ctx : String) : Json → Except String Unit
  | Json.obj _ => .ok ()
  | _ => .error s!"{ctx}: expected object"

private def objField (ctx : String) (j : Json) (k : String) : Except String Json := do
  ensureObj ctx j
  match j.getObjVal? k with
  | .ok v => .ok v
  | .error _ => .error s!"{ctx}: missing required field '{k}'"

private def strJson (ctx : String) (j : Json) : Except String String :=
  match Json.getStr? j with
  | .ok s => .ok s
  | .error _ => .error s!"{ctx}: expected string"

private def strField (ctx : String) (j : Json) (k : String) : Except String String := do
  strJson s!"{ctx}.{k}" (← objField ctx j k)

private def optStrField (ctx : String) (j : Json) (k : String) : Except String (Option String) := do
  ensureObj ctx j
  match j.getObjVal? k with
  | .ok v => do pure (some (← strJson s!"{ctx}.{k}" v))
  | .error _ => .ok none

private def arrJson (ctx : String) (j : Json) : Except String (Array Json) :=
  match Json.getArr? j with
  | .ok a => .ok a
  | .error _ => .error s!"{ctx}: expected array"

private def arrField (ctx : String) (j : Json) (k : String) : Except String (Array Json) := do
  arrJson s!"{ctx}.{k}" (← objField ctx j k)

private def natJson (ctx : String) (j : Json) : Except String Nat :=
  match Json.getNat? j with
  | .ok n => .ok n
  | .error _ =>
      match Json.getStr? j with
      | .ok s =>
          match s.toNat? with
          | some n => .ok n
          | none => .error s!"{ctx}: expected natural-number string"
      | .error _ => .error s!"{ctx}: expected natural number or natural-number string"

private def natField (ctx : String) (j : Json) (k : String) : Except String Nat := do
  natJson s!"{ctx}.{k}" (← objField ctx j k)

private def optNatField (ctx : String) (j : Json) (k : String) : Except String (Option Nat) := do
  ensureObj ctx j
  match j.getObjVal? k with
  | .ok v => do pure (some (← natJson s!"{ctx}.{k}" v))
  | .error _ => .ok none

private def boolJson (ctx : String) (j : Json) : Except String Bool :=
  match Json.getBool? j with
  | .ok b => .ok b
  | .error _ =>
      match Json.getStr? j with
      | .ok "true" => .ok true
      | .ok "false" => .ok false
      | .ok _ => .error s!"{ctx}: expected boolean string"
      | .error _ => .error s!"{ctx}: expected boolean or boolean string"

private def boolField (ctx : String) (j : Json) (k : String) : Except String Bool := do
  boolJson s!"{ctx}.{k}" (← objField ctx j k)

private def optBoolField (ctx : String) (j : Json) (k : String) : Except String (Option Bool) := do
  ensureObj ctx j
  match j.getObjVal? k with
  | .ok v => do pure (some (← boolJson s!"{ctx}.{k}" v))
  | .error _ => .ok none

private def parseJsonList {α : Type} (ctx : String) (a : Array Json)
    (f : String → Json → Except String α) : Except String (List α) :=
  (a.toList.zipIdx).mapM (fun (j, i) => f s!"{ctx}[{i}]" j)

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
  | .other name => name

def formatFromWireString : String → Format
  | "pi" => .pi
  | "claude" => .claudeCode
  | "codex" => .codexCli
  | "cursor-agent" => .cursorAgent
  | "cursor-ide" => .cursorIde
  | "hermes" => .hermes
  | "google-ai-studio" => .googleAiStudio
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
  | .inferred isError heuristic =>
      Json.mkObj [("kind", Json.str "inferred"), ("isError", Json.str (toString isError)), ("heuristic", Json.str heuristic)]
  | .unrecorded => Json.mkObj [("kind", Json.str "unrecorded")]

def errorSignalFromWireJson (ctx : String) (j : Json) : Except String ErrorSignal := do
  match ← strField ctx j "kind" with
  | "native" => pure (.native (← boolField ctx j "isError"))
  | "inferred" => pure (.inferred (← boolField ctx j "isError") (← strField ctx j "heuristic"))
  | "unrecorded" => pure .unrecorded
  | other => .error s!"{ctx}: unsupported error kind '{other}'"

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

private def wireDispositionBaseEntry : Entry := {
  payload := .assistantMsg [.text "disposition fixture"]
  origin := { format := .other "fixture", sourceRef := "wire-disposition" }
}

private def wireEntryWithDisposition (value : Json) : Json :=
  match entryToWireJson 0 wireDispositionBaseEntry with
  | .obj fields => .obj (fields.insert "disposition" value)
  | other => other

/-- Pre-field v0 entries decode to the source-compatible default and re-export
without gaining a field, preserving their historical wire shape. -/
def loomWireEntryDispositionBackwardCompatible : Bool :=
  let legacy := entryToWireJson 0 wireDispositionBaseEntry
  match legacy.getObjVal? "disposition", entryFromWireJson 0 legacy with
  | .error _, .ok restored =>
      restored.disposition == EntryDisposition.native &&
        entryToWireJson 0 restored == legacy
  | _, _ => false

def loomWireRejectsMalformedEntryDisposition : Bool :=
  match entryFromWireJson 0 (wireEntryWithDisposition (Json.bool true)),
      entryFromWireJson 0 (wireEntryWithDisposition (Json.str "futureDisposition")) with
  | .error _, .error _ => true
  | _, _ => false

def loomWireRoundTripsEntryDisposition : Bool :=
  let source := { wireDispositionBaseEntry with
    disposition := EntryDisposition.historicalUnverified }
  let wire := entryToWireJson 0 source
  match wire.getObjVal? "disposition", entryFromWireJson 0 wire with
  | .ok (.str "historicalUnverified"), .ok restored =>
      restored.disposition == EntryDisposition.historicalUnverified &&
        entryToWireJson 0 restored == wire
  | _, _ => false

private def wireMissingRequiredFieldFixture : String :=
  "{\"schema\":\"loom.transcript.v0\",\"origin\":{\"format\":\"claude\",\"sourceRef\":\"missing-required\"},\"env\":{},\"threads\":[{\"index\":\"0\",\"kind\":{\"kind\":\"main\"}}],\"importNotes\":[]}"

private def wireNumberIndexesFixture : String :=
  "{\"schema\":\"loom.transcript.v0\",\"origin\":{\"format\":\"codex\",\"sourceRef\":\"wire-number-indexes\"},\"env\":{\"cwd\":\"/tmp/loom-wire-numbers\"},\"threads\":[{\"index\":0,\"kind\":{\"kind\":\"main\"}}],\"entries\":[{\"index\":0,\"thread\":0,\"time\":{\"kind\":\"sequenced\",\"ord\":0},\"payload\":{\"type\":\"userMsg\",\"blocks\":[{\"type\":\"text\",\"text\":\"number index root\"}]},\"origin\":{\"format\":\"codex\",\"sourceRef\":\"wire-number-indexes\",\"rawId\":\"n0\"}},{\"index\":1,\"parent\":0,\"thread\":0,\"time\":{\"kind\":\"sequenced\",\"ord\":1},\"payload\":{\"type\":\"assistantMsg\",\"blocks\":[{\"type\":\"text\",\"text\":\"number index reply\"}]},\"origin\":{\"format\":\"codex\",\"sourceRef\":\"wire-number-indexes\",\"rawId\":\"n1\"}}],\"importNotes\":[],\"activeLeaf\":1}"

private def wireUnknownLabelsFixture : String :=
  "{\"schema\":\"loom.transcript.v0\",\"x-top-level\":{\"ignored\":true},\"origin\":{\"format\":\"future-format\",\"sourceRef\":\"unknown-labels\",\"rawId\":\"u-session\",\"x-origin\":true},\"env\":{\"cwd\":\"/tmp/loom-wire-unknown\",\"x-env\":true},\"threads\":[{\"index\":\"0\",\"kind\":{\"kind\":\"main\",\"x-kind\":true},\"label\":\"main\",\"x-thread\":\"ignored\"}],\"entries\":[{\"index\":\"0\",\"thread\":\"0\",\"time\":{\"kind\":\"absent\",\"x-time\":true},\"payload\":{\"type\":\"userMsg\",\"blocks\":[{\"type\":\"futureUserBlock\",\"future\":\"kept as raw\",\"x\":1}],\"x-payload\":true},\"origin\":{\"format\":\"future-format\",\"sourceRef\":\"unknown-labels\",\"rawId\":\"u0\"}},{\"index\":\"1\",\"parent\":\"0\",\"thread\":\"0\",\"time\":{\"kind\":\"absent\"},\"payload\":{\"type\":\"assistantMsg\",\"blocks\":[{\"type\":\"futureAssistantBlock\",\"text\":\"not interpreted\",\"nested\":{\"ok\":true}}]},\"origin\":{\"format\":\"future-format\",\"sourceRef\":\"unknown-labels\",\"rawId\":\"u1\"}},{\"index\":\"2\",\"parent\":\"1\",\"thread\":\"0\",\"time\":{\"kind\":\"absent\"},\"payload\":{\"type\":\"event\",\"event\":{\"type\":\"futureEvent\",\"payload\":{\"ok\":true}}},\"origin\":{\"format\":\"future-format\",\"sourceRef\":\"unknown-labels\",\"rawId\":\"u2\"}}],\"importNotes\":[{\"kind\":\"futureAssumption\",\"loc\":\"fixture\",\"detail\":\"unknown assumption kind survives\",\"x-note\":true}],\"activeLeaf\":\"2\"}"

def loomWireRejectsWrongSchema : Bool :=
  match importLoomWire "{\"schema\":\"loom.transcript.v1\"}" with
  | .error _ => true
  | .ok _ => false

def loomWireRejectsMissingRequiredField : Bool :=
  match importLoomWire wireMissingRequiredFieldFixture with
  | .error _ => true
  | .ok _ => false

def loomWireAcceptsJsonNumberIndexes : Bool :=
  match importLoomWire wireNumberIndexesFixture with
  | .ok t =>
      t.entries.size == 2
      && t.activeLeaf == some 1
      && (match t.threads[0]?, t.entries[0]?, t.entries[1]? with
          | some _, some e0, some e1 =>
              e0.thread == 0
              && e1.parent == some 0
              && e1.thread == 0
              && e0.time == Time.sequenced 0
              && e1.time == Time.sequenced 1
          | _, _, _ => false)
      && (Loom.violations t).isEmpty
  | .error _ => false

def loomWireAcceptsUnknownAdditiveFieldsAndLabels : Bool :=
  match importLoomWire wireUnknownLabelsFixture with
  | .ok t =>
      t.origin.format == Format.other "future-format"
      && (match t.importNotes with
          | [n] => n.kind == AssumptionKind.other "futureAssumption"
          | _ => false)
      && (match t.entries[0]?, t.entries[1]?, t.entries[2]? with
          | some e0, some e1, some e2 =>
              (match e0.payload with
              | .userMsg [.unmodeled label _] => label == "futureUserBlock"
              | _ => false)
              && (match e1.payload with
              | .assistantMsg [.unmodeled label _] => label == "futureAssistantBlock"
              | _ => false)
              && (match e2.payload with
              | .event (.custom label _) => label == "futureEvent"
              | _ => false)
          | _, _, _ => false)
      && (Loom.violations t).isEmpty
  | .error _ => false

example : loomWireRejectsWrongSchema = true := by native_decide
example : loomWireRejectsMissingRequiredField = true := by native_decide
example : loomWireAcceptsJsonNumberIndexes = true := by native_decide
example : loomWireAcceptsUnknownAdditiveFieldsAndLabels = true := by native_decide
example : loomWireEntryDispositionBackwardCompatible = true := by native_decide
example : loomWireRejectsMalformedEntryDisposition = true := by native_decide
example : loomWireRoundTripsEntryDisposition = true := by native_decide

private def wireRoundTripFixture : Transcript :=
  let org : Origin := { format := .claudeCode, sourceRef := "wire-roundtrip", rawId := some "S-wire" }
  {
    threads := #[
      { kind := .main, label := some "main" },
      { kind := .sidechain (.resolved 1 1), label := some "anchored child" },
      { kind := .detached "toolUseId=missing unmatched", label := some "detached child" }
    ]
    entries := #[
      { thread := 0, time := .absent, origin := org,
        payload := .userMsg [.text "root"] },
      { parent := some 0, thread := 0, time := .sequenced 1, origin := org,
        payload := .assistantMsg [
          .text "dispatch",
          .toolCall { raw := "Task", canonical := some .agentSpawn } (Json.mkObj [("prompt", Json.str "child")]) (some "toolu_child")
        ] },
      { thread := 1, time := .absent, origin := org,
        payload := .userMsg [.text "child work"] },
      { parent := some 2, thread := 1, time := .absent, origin := org,
        payload := .assistantMsg [.text "child done"] },
      { thread := 2, time := .absent, origin := org,
        payload := .userMsg [.text "orphan work"] }
    ]
    env := { cwd := some "/tmp/loom-wire", model := some "fixture-model" }
    activeLeaf := some 3
    importNotes := [{ kind := .idSynthesized, loc := some "fixture", detail := "wire round-trip fixture" }]
    origin := org
  }

def loomWireRoundTripPreservesThreadMetadata : Bool :=
  match importLoomWire (exportLoomWire wireRoundTripFixture) with
  | .ok t =>
      t.threads.size == 3
      && t.entries.size == 5
      && t.activeLeaf == some 3
      && (match t.threads[1]?, t.threads[2]? with
          | some th1, some th2 =>
              th1.kind == ThreadKind.sidechain (CallRef.resolved 1 1)
              && th1.label == some "anchored child"
              && th2.kind == ThreadKind.detached "toolUseId=missing unmatched"
              && th2.label == some "detached child"
          | _, _ => false)
      && (match t.entries[2]?, t.entries[4]? with
          | some e2, some e4 => e2.thread == 1 && e4.thread == 2
          | _, _ => false)
      && (Loom.violations t).isEmpty
  | .error _ => false

example : loomWireRoundTripPreservesThreadMetadata = true := by native_decide

/-- A fixture exercising EVERY block / payload / meta-event / compaction-coverage /
error-signal / time / call-ref constructor the thread-metadata fixture omits — so the
idempotence pin below locks per-type round-trip fidelity, which
`loomWireRoundTripPreservesThreadMetadata` (structural counts only) does not. Not
required to be well-formed: it deliberately carries an UNRESOLVED tool result to
round-trip `CallRef.unresolved`, and round-trip fidelity is independent of
well-formedness. -/
private def wireAllConstructorsFixture : Transcript :=
  let org : Origin := {
    format := .codexCli
    sourceRef := "wire-all"
    rawId := some "S-all"
    extras := some (Json.mkObj [("source", Json.str "fixture")]) }
  let env : EnvInfo := {
    cwd := some "/w"
    model := some "gpt"
    provider := some "provider"
    harnessVersion := some "1.2.3"
    instructions := some "instructions"
    sessionId := some "wire-all-session" }
  {
    threads := #[
      { kind := .main, label := some "m" },
      { kind := .sidechain (.resolved 1 2), label := some "sc" },
      { kind := .detached "det-note", label := none }
    ]
    entries := #[
      { thread := 0, time := .recorded ⟨1700000000000⟩, origin := org,
        disposition := .historicalUnverified,
        payload := .userMsg [.text "u", .media "image/png" "ref-u",
          .unmodeled "u-future" (Json.mkObj [("k", Json.str "v")])] },
      { parent := some 0, thread := 0, time := .interpolated ⟨1700000000001⟩ "seq", origin := org,
        payload := .assistantMsg [.text "a", .thinking "reason" (some "sig-xyz"),
          .toolCall { raw := "bash", canonical := some .bash }
            (Json.mkObj [("cmd", Json.str "ls")]) (some "call-1"),
          .media "image/png" "ref-a", .unmodeled "a-future" (Json.mkObj [])] },
      { parent := some 1, thread := 0, time := .sequenced 2, origin := org,
        payload := .envMsg [
          .toolResult (.resolved 1 2) [.text "out"] (.native false),
          .toolResult (.resolved 1 2) [.text "inferred"]
            (.inferred true "fixture heuristic"),
          .toolResult (.unresolved (some "orphan") "no call") [.text "orphan"] .unrecorded,
          .unmodeled "e-future" (Json.mkObj [])] },
      { parent := some 2, thread := 0, time := .absent, origin := org,
        payload := .otherMsg "system" [.text "sys"] },
      { parent := some 3, thread := 0, time := .absent, origin := org,
        payload := .compaction "csum" (.knownPrefix 2) (some 12345) },
      { parent := some 4, thread := 0, time := .absent, origin := org,
        payload := .compaction "csum2" .unknownPrefix none },
      { parent := some 5, thread := 0, time := .absent, origin := org,
        payload := .event (.custom "error" (Json.mkObj [("message", Json.str "boom")])) },
      { parent := some 6, thread := 0, time := .absent, origin := org,
        payload := .event (.modelChange (some "m1") none) },
      { parent := some 7, thread := 0, time := .absent, origin := org,
        payload := .event (.thinkingLevelChange none (some "high")) },
      { parent := some 8, thread := 0, time := .absent, origin := org,
        payload := .event (.permissionMode "acceptEdits") },
      { parent := some 9, thread := 0, time := .absent, origin := org,
        payload := .event (.branchSummary "bsum") }
    ]
    env := env
    activeLeaf := some 5
    importNotes := [
      { kind := .dedupDropped, loc := some "l0", detail := "d0" },
      { kind := .timeInterpolated, loc := some "l1", detail := "d1" },
      { kind := .timeSequenced, loc := some "l2", detail := "d2" },
      { kind := .errorInferred, loc := some "l3", detail := "d3" },
      { kind := .roleCoerced, loc := some "l4", detail := "d4" },
      { kind := .toolNameMapped, loc := some "l5", detail := "d5" },
      { kind := .idSynthesized, loc := some "l6", detail := "d6" },
      { kind := .contentSkipped, loc := some "l7", detail := "d7" },
      { kind := .activeLeafGuessed, loc := some "l8", detail := "d8" },
      { kind := .other "future", loc := none, detail := "d9" }]
    origin := org
  }

private def listEqBy {α β : Type} (eq : α -> β -> Bool)
    (left : List α) (right : List β) : Bool :=
  left.length == right.length && (left.zip right).all (fun pair => eq pair.1 pair.2)

private def optionJsonEq : Option Json -> Option Json -> Bool
  | some left, some right => left == right
  | none, none => true
  | _, _ => false

private def originWireEq (left right : Origin) : Bool :=
  decide (left.format = right.format) && left.sourceRef == right.sourceRef &&
    decide (left.rawId = right.rawId) && optionJsonEq left.extras right.extras

private def userBlockWireEq : UserBlock -> UserBlock -> Bool
  | .text left, .text right => left == right
  | .media leftMime leftLoc, .media rightMime rightLoc =>
      leftMime == rightMime && leftLoc == rightLoc
  | .unmodeled leftLabel leftRaw, .unmodeled rightLabel rightRaw =>
      leftLabel == rightLabel && leftRaw == rightRaw
  | _, _ => false

private def assistantBlockWireEq : AssistantBlock -> AssistantBlock -> Bool
  | .text left, .text right => left == right
  | .thinking leftText leftSig, .thinking rightText rightSig =>
      leftText == rightText && decide (leftSig = rightSig)
  | .toolCall leftName leftArgs leftId, .toolCall rightName rightArgs rightId =>
      decide (leftName = rightName) && leftArgs == rightArgs && decide (leftId = rightId)
  | .media leftMime leftLoc, .media rightMime rightLoc =>
      leftMime == rightMime && leftLoc == rightLoc
  | .unmodeled leftLabel leftRaw, .unmodeled rightLabel rightRaw =>
      leftLabel == rightLabel && leftRaw == rightRaw
  | _, _ => false

private def envBlockWireEq : EnvBlock -> EnvBlock -> Bool
  | .toolResult leftCall leftContent leftError,
      .toolResult rightCall rightContent rightError =>
      decide (leftCall = rightCall) &&
        listEqBy userBlockWireEq leftContent rightContent &&
        decide (leftError = rightError)
  | .unmodeled leftLabel leftRaw, .unmodeled rightLabel rightRaw =>
      leftLabel == rightLabel && leftRaw == rightRaw
  | _, _ => false

private def metaEventWireEq : MetaEvent -> MetaEvent -> Bool
  | .modelChange leftPrev leftNext, .modelChange rightPrev rightNext =>
      decide (leftPrev = rightPrev) && decide (leftNext = rightNext)
  | .thinkingLevelChange leftPrev leftNext, .thinkingLevelChange rightPrev rightNext =>
      decide (leftPrev = rightPrev) && decide (leftNext = rightNext)
  | .permissionMode left, .permissionMode right => left == right
  | .branchSummary left, .branchSummary right => left == right
  | .custom leftLabel leftRaw, .custom rightLabel rightRaw =>
      leftLabel == rightLabel && leftRaw == rightRaw
  | _, _ => false

private def payloadWireEq : Payload -> Payload -> Bool
  | .userMsg left, .userMsg right => listEqBy userBlockWireEq left right
  | .assistantMsg left, .assistantMsg right => listEqBy assistantBlockWireEq left right
  | .envMsg left, .envMsg right => listEqBy envBlockWireEq left right
  | .otherMsg leftRole left, .otherMsg rightRole right =>
      leftRole == rightRole && listEqBy userBlockWireEq left right
  | .compaction leftSummary leftCoverage leftTokens,
      .compaction rightSummary rightCoverage rightTokens =>
      leftSummary == rightSummary && decide (leftCoverage = rightCoverage) &&
        decide (leftTokens = rightTokens)
  | .event left, .event right => metaEventWireEq left right
  | _, _ => false

private def entryWireEq (left right : Entry) : Bool :=
  decide (left.parent = right.parent) && left.thread == right.thread &&
    decide (left.time = right.time) && payloadWireEq left.payload right.payload &&
    originWireEq left.origin right.origin &&
    decide (left.disposition = right.disposition)

private def importNoteWireEq (left right : ImportNote) : Bool :=
  decide (left.kind = right.kind) && decide (left.loc = right.loc) &&
    left.detail == right.detail

private def transcriptWireEq (left right : Transcript) : Bool :=
  listEqBy (fun a b => decide (a = b)) left.threads.toList right.threads.toList &&
    listEqBy entryWireEq left.entries.toList right.entries.toList &&
    decide (left.env = right.env) && decide (left.activeLeaf = right.activeLeaf) &&
    listEqBy importNoteWireEq left.importNotes right.importNotes &&
    originWireEq left.origin right.origin

/-- PIN (Finding #1 fix): export → import → re-export is IDEMPOTENT over the wire
format across every constructor. If `importLoomWire` drops or mangles ANY serialized
field (a media locator, a thinking signature, a tool-call's args/id, a tool-result's
CallRef/content/error, a compaction's coverage/tokensBefore, a meta-event's fields, an
unmodeled block's raw, a non-`absent` time), the re-export string diverges and this
stops compiling. Complements the structural-metadata pin above. -/
def loomWireRoundTripAllConstructors : Bool :=
  let wire := exportLoomWire wireAllConstructorsFixture
  match importLoomWire wire with
  | .ok t => transcriptWireEq t wireAllConstructorsFixture && exportLoomWire t == wire
  | .error _ => false

example : loomWireRoundTripAllConstructors = true := by native_decide

/-- The versioned Loom wire vocabulary is independent of adapter-native tags.
Pi 0.74 calls the same semantic block `image`; v0 must remain `media`. -/
def loomWireMediaTagIsStable : Bool :=
  match (userBlockToWireJson (UserBlock.media "image/png" "user")).getObjVal? "type",
      (assistantBlockToWireJson
        (AssistantBlock.media "image/jpeg" "assistant")).getObjVal? "type" with
  | .ok (.str "media"), .ok (.str "media") => true
  | _, _ => false

example : loomWireMediaTagIsStable = true := by native_decide

private def wireCanonicalTools : List CanonicalTool := [
  .bash, .read, .write, .edit, .grep, .glob, .webFetch, .webSearch,
  .agentSpawn, .applyPatch]

private def wireEntryDispositions : List EntryDisposition :=
  [.native, .historicalUnverified]

private def wireBuiltinFormats : List Format := [
  .pi, .claudeCode, .codexCli, .cursorAgent, .cursorIde, .hermes,
  .googleAiStudio]

private def wireFormats : List Format :=
  wireBuiltinFormats ++ [.other "future-format"]

private def wireBuiltinAssumptionKinds : List AssumptionKind := [
  .dedupDropped, .timeInterpolated, .timeSequenced, .errorInferred,
  .roleCoerced, .toolNameMapped, .idSynthesized, .contentSkipped,
  .activeLeafGuessed]

/-- Closed wire enums receive independent exhaustive codec pins. The transcript
witness can contain one value per field, while these lists prevent an untested
constructor from hiding behind that single representative. -/
def loomWireClosedEnumsRoundTrip : Bool :=
  wireCanonicalTools.all (fun tool =>
    match canonicalToolFromWireString "fixture" (canonicalToolToWireString tool) with
    | .ok restored => decide (restored = tool)
    | .error _ => false) &&
  wireEntryDispositions.all (fun disposition =>
    match entryDispositionFromWireString "fixture"
        (entryDispositionToWireString disposition) with
    | .ok restored => decide (restored = disposition)
    | .error _ => false) &&
  wireFormats.all (fun format =>
    decide (formatFromWireString (formatToWireString format) = format))

example : loomWireClosedEnumsRoundTrip = true := by native_decide

private def wireOpenLabelFixture (format : Format) (kind : AssumptionKind) : Transcript :=
  let org : Origin := { format, sourceRef := "wire-open-label" }
  {
    threads := #[{ kind := .main }]
    entries := #[]
    env := {}
    activeLeaf := none
    importNotes := [{ kind, detail := "wire-open-label" }]
    origin := org
  }

private def wireRoundTripsExactly (source : Transcript) : Bool :=
  let wire := exportLoomWire source
  match importLoomWire wire with
  | .ok restored => transcriptWireEq restored source && exportLoomWire restored == wire
  | .error _ => false

private def wireReservedFormatLabels : List String :=
  wireBuiltinFormats.map formatToWireString

private def wireReservedAssumptionLabels : List String :=
  wireBuiltinAssumptionKinds.map assumptionKindToWireString

/-- Every built-in spelling is also a legal open label. The additive marker
must keep those values in `.other` through a complete wire round-trip, not just
through the string helpers where the two constructors necessarily alias. -/
def loomWireReservedOpenLabelsRoundTripExactly : Bool :=
  wireReservedFormatLabels.all (fun label =>
    wireRoundTripsExactly
      (wireOpenLabelFixture (.other label) (.other "future-assumption"))) &&
  wireReservedAssumptionLabels.all (fun label =>
    wireRoundTripsExactly
      (wireOpenLabelFixture (.other "future-format") (.other label)))

/-- Unmarked v0 objects keep their historical interpretation and shape:
recognized labels decode as built-ins, while ordinary unknown labels decode as
`.other` without gaining a marker on re-export. -/
private def legacyFormatCompatible (format : Format) : Bool :=
  let legacy := Json.mkObj [
    ("format", Json.str (formatToWireString format)),
    ("sourceRef", Json.str "legacy")]
  originToWireJson { format, sourceRef := "legacy" } == legacy &&
    (match originFromWireJson "legacy origin" legacy with
    | .ok restored => decide (restored.format = format)
    | .error _ => false)

private def legacyAssumptionCompatible (kind : AssumptionKind) : Bool :=
  let legacy := Json.mkObj [
    ("kind", Json.str (assumptionKindToWireString kind)),
    ("detail", Json.str "legacy")]
  importNoteToWireJson { kind, detail := "legacy" } == legacy &&
    (match importNoteFromWireJson "legacy note" legacy with
    | .ok restored => decide (restored.kind = kind)
    | .error _ => false)

def loomWireLegacyOpenLabelsCompatible : Bool :=
  wireBuiltinFormats.all legacyFormatCompatible &&
  legacyFormatCompatible (.other "future-format") &&
  wireBuiltinAssumptionKinds.all legacyAssumptionCompatible &&
  legacyAssumptionCompatible (.other "future-assumption")

example : loomWireReservedOpenLabelsRoundTripExactly = true := by native_decide
example : loomWireLegacyOpenLabelsCompatible = true := by native_decide

end LoomConvert
