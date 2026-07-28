import Loom.Core

/-!
# Continuation-semantic projection

Unlike the historical parity projection, this projection does not erase tool
names, arguments, call/result linkage, result state, media, or open-world
blocks. It flattens storage-specific message grouping into an ordered event
stream so two harnesses can be compared without requiring byte-identical
envelopes.

This is still not a claim of complete continuation state or total losslessness:
parent/thread topology, active leaf, time, environment, token accounting,
origins, and format-scoped extras are outside this content projection.
`continuationStateProjection` and `auditProjection` below expose those stronger
contracts. Provider-private reasoning signatures remain observable content;
silently dropping one must not satisfy a continuation-fidelity claim. When a
target policy intentionally omits a foreign signature (e.g. Codex refuses
non-OpenAI blobs in `encrypted_content`), the expected projection must record
that drop explicitly rather than treating the source signature as preserved.
-/

namespace Loom
open Lean (Json)

private def userBlockJson : UserBlock -> Json
  | .text text => Json.mkObj [("kind", Json.str "text"), ("text", Json.str text)]
  | .media mime locator => Json.mkObj
      [("kind", Json.str "media"), ("mime", Json.str mime), ("locator", Json.str locator)]
  | .unmodeled label raw => Json.mkObj
      [("kind", Json.str "unmodeled"), ("label", Json.str label), ("raw", raw)]

private def canonicalToolJson : CanonicalTool -> Json
  | .bash => Json.str "bash"
  | .read => Json.str "read"
  | .write => Json.str "write"
  | .edit => Json.str "edit"
  | .grep => Json.str "grep"
  | .glob => Json.str "glob"
  | .webFetch => Json.str "webFetch"
  | .webSearch => Json.str "webSearch"
  | .agentSpawn => Json.str "agentSpawn"
  | .applyPatch => Json.str "applyPatch"

private def optionCanonicalToolJson : Option CanonicalTool -> Json
  | some tool => canonicalToolJson tool
  | none => Json.null

private def callPositions (transcript : Transcript) : List (Nat × Nat) := Id.run do
  let mut positions : Array (Nat × Nat) := #[]
  for entryPair in transcript.entries.toList.zipIdx do
    match entryPair.1.payload with
    | .assistantMsg blocks =>
        for blockPair in blocks.zipIdx do
          match blockPair.1 with
          | .toolCall _ _ _ => positions := positions.push (entryPair.2, blockPair.2)
          | _ => pure ()
    | _ => pure ()
  return positions.toList

private def callOrdinal? (transcript : Transcript) (entry block : Nat) : Option Nat :=
  ((callPositions transcript).zipIdx.find? (fun pair => pair.1 == (entry, block))).map (·.2)

private def resultState : ErrorSignal -> Json
  | .native value => Json.mkObj
      [("kind", Json.str "native"), ("value", Json.bool value)]
  | .inferred value heuristic => Json.mkObj
      [("kind", Json.str "inferred"), ("value", Json.bool value),
       ("heuristic", Json.str heuristic)]
  | .unrecorded => Json.mkObj [("kind", Json.str "unrecorded")]

private def callLinkJson (transcript : Transcript) : CallRef -> Json
  | .resolved entry block =>
      Json.mkObj [
        ("kind", Json.str "resolved"),
        ("callOrdinal", (callOrdinal? transcript entry block).map Json.num |>.getD Json.null)]
  | .unresolved rawId note => Json.mkObj [
      ("kind", Json.str "unresolved"),
      ("rawId", rawId.map Json.str |>.getD Json.null),
      ("note", Json.str note)]

private def dispositionJson : EntryDisposition -> Json
  | .native => Json.str "native"
  | .historicalUnverified => Json.str "historicalUnverified"

private def withEntrySemantics
    (payloadKind : String) (disposition : EntryDisposition) : Json -> Json
  | .obj fields => Json.obj
      ((fields.insert "payloadKind" (Json.str payloadKind)).insert
        "disposition" (dispositionJson disposition))
  | value => Json.mkObj
      [("payloadKind", Json.str payloadKind),
       ("disposition", dispositionJson disposition), ("value", value)]

private def entryEvents (transcript : Transcript) (entry : Entry) : List Json :=
  let (payloadKind, events) : String × List Json := match entry.payload with
  | .userMsg blocks => ("userMsg", blocks.map (fun block => Json.mkObj
      [("role", Json.str "user"), ("content", userBlockJson block)]))
  | .assistantMsg blocks => ("assistantMsg", blocks.map (fun block =>
      match block with
      | .text text => Json.mkObj
          [("role", Json.str "assistant"), ("kind", Json.str "text"), ("text", Json.str text)]
      | .thinking text signature => Json.mkObj
          [("role", Json.str "assistant"), ("kind", Json.str "thinking"),
           ("text", Json.str text),
           ("signature", signature.map Json.str |>.getD Json.null)]
      | .toolCall name args rawId => Json.mkObj
          [("role", Json.str "assistant"), ("kind", Json.str "toolCall"),
           ("name", Json.str name.raw),
           ("canonicalName", optionCanonicalToolJson name.canonical),
           ("arguments", args),
           ("id", rawId.map Json.str |>.getD Json.null)]
      | .media mime locator => Json.mkObj
          [("role", Json.str "assistant"), ("kind", Json.str "media"),
           ("mime", Json.str mime), ("locator", Json.str locator)]
      | .unmodeled label raw => Json.mkObj
          [("role", Json.str "assistant"), ("kind", Json.str "unmodeled"),
           ("label", Json.str label), ("raw", raw)]))
  | .envMsg blocks => ("envMsg", blocks.map (fun block =>
      match block with
      | .toolResult call content error => Json.mkObj
          [("role", Json.str "environment"), ("kind", Json.str "toolResult"),
           ("call", callLinkJson transcript call),
           ("content", Json.arr (content.map userBlockJson).toArray),
           ("isError", resultState error)]
      | .unmodeled label raw => Json.mkObj
          [("role", Json.str "environment"), ("kind", Json.str "unmodeled"),
           ("label", Json.str label), ("raw", raw)]))
  | .otherMsg role blocks => ("otherMsg", blocks.map (fun block => Json.mkObj
      [("role", Json.str role), ("content", userBlockJson block)]))
  | .compaction summary coverage tokensBefore =>
      let coverageJson := match coverage with
        | .knownPrefix firstKept => Json.num firstKept
        | .unknownPrefix => Json.null
      ("compaction", [Json.mkObj
        [("kind", Json.str "compaction"), ("summary", Json.str summary),
         ("firstKept", coverageJson),
         ("tokensBefore", tokensBefore.map Json.num |>.getD Json.null)]])
  | .event event =>
      let value := match event with
        | .modelChange prev next => Json.mkObj
            [("kind", Json.str "modelChange"),
             ("prev", prev.map Json.str |>.getD Json.null),
             ("next", next.map Json.str |>.getD Json.null)]
        | .thinkingLevelChange prev next => Json.mkObj
            [("kind", Json.str "thinkingLevelChange"),
             ("prev", prev.map Json.str |>.getD Json.null),
             ("next", next.map Json.str |>.getD Json.null)]
        | .permissionMode mode => Json.mkObj
            [("kind", Json.str "permissionMode"), ("mode", Json.str mode)]
        | .branchSummary summary => Json.mkObj
            [("kind", Json.str "branchSummary"), ("summary", Json.str summary)]
        | .custom label raw => Json.mkObj
            [("kind", Json.str "custom"), ("label", Json.str label), ("raw", raw)]
      ("event", [value])
  let observedEvents := if events.isEmpty then [Json.mkObj [
      ("kind", Json.str "emptyPayload")]] else events
  observedEvents.map (withEntrySemantics payloadKind entry.disposition)

/-- Per-entry continuation events. Unlike `continuationProjection`, this keeps
the source grouping boundary while still normalizing resolved call links to
logical call ordinals. It is the executable basis of split-only target-state
relations. Every entry contributes at least one event, including empty message
payloads. -/
def continuationEntryEvents (transcript : Transcript) : Array (Array Json) :=
  transcript.entries.map (fun entry => (entryEvents transcript entry).toArray)

/-- Ordered, deterministic semantics needed to understand and continue a
conversation after crossing harnesses. -/
def continuationProjection (transcript : Transcript) : String :=
  let events := (continuationEntryEvents transcript).toList.flatMap (·.toList)
  (Json.mkObj [("events", Json.arr events.toArray)]).compress

private def optionStringJson : Option String -> Json
  | some value => Json.str value
  | none => Json.null

private def optionNatJson : Option Nat -> Json
  | some value => Json.num value
  | none => Json.null

private def formatJson : Format -> Json
  | .pi => Json.str "pi"
  | .claudeCode => Json.str "claude"
  | .codexCli => Json.str "codex"
  | .cursorAgent => Json.str "cursor-agent"
  | .cursorIde => Json.str "cursor-ide"
  | .hermes => Json.str "hermes"
  | .googleAiStudio => Json.str "google-ai-studio"
  | .other name => Json.mkObj [("other", Json.str name)]

private def timeJson : Time -> Json
  | .recorded timestamp => Json.mkObj [
      ("kind", Json.str "recorded"), ("ms", Json.num timestamp.ms)]
  | .interpolated timestamp basis => Json.mkObj [
      ("kind", Json.str "interpolated"), ("ms", Json.num timestamp.ms),
      ("basis", Json.str basis)]
  | .sequenced ordinal => Json.mkObj [
      ("kind", Json.str "sequenced"), ("ordinal", Json.num ordinal)]
  | .absent => Json.mkObj [("kind", Json.str "absent")]

private def rawCallRefJson : CallRef -> Json
  | .resolved entry block => Json.mkObj [
      ("kind", Json.str "resolved"), ("entry", Json.num entry),
      ("block", Json.num block)]
  | .unresolved rawId note => Json.mkObj [
      ("kind", Json.str "unresolved"), ("rawId", optionStringJson rawId),
      ("note", Json.str note)]

private def assistantBlockStateJson : AssistantBlock -> Json
  | .text text => Json.mkObj [
      ("kind", Json.str "text"), ("text", Json.str text)]
  | .thinking text signature => Json.mkObj [
      ("kind", Json.str "thinking"), ("text", Json.str text),
      ("signature", optionStringJson signature)]
  | .toolCall name arguments rawId => Json.mkObj [
      ("kind", Json.str "toolCall"), ("name", Json.str name.raw),
      ("canonicalName", optionCanonicalToolJson name.canonical),
      ("arguments", arguments), ("rawId", optionStringJson rawId)]
  | .media mime locator => Json.mkObj [
      ("kind", Json.str "media"), ("mime", Json.str mime),
      ("locator", Json.str locator)]
  | .unmodeled label raw => Json.mkObj [
      ("kind", Json.str "unmodeled"), ("label", Json.str label), ("raw", raw)]

private def envBlockStateJson : EnvBlock -> Json
  | .toolResult call content error => Json.mkObj [
      ("kind", Json.str "toolResult"), ("call", rawCallRefJson call),
      ("content", Json.arr (content.map userBlockJson).toArray),
      ("isError", resultState error)]
  | .unmodeled label raw => Json.mkObj [
      ("kind", Json.str "unmodeled"), ("label", Json.str label), ("raw", raw)]

private def payloadStateJson : Payload -> Json
  | .userMsg blocks => Json.mkObj [
      ("kind", Json.str "userMsg"),
      ("blocks", Json.arr (blocks.map userBlockJson).toArray)]
  | .assistantMsg blocks => Json.mkObj [
      ("kind", Json.str "assistantMsg"),
      ("blocks", Json.arr (blocks.map assistantBlockStateJson).toArray)]
  | .envMsg blocks => Json.mkObj [
      ("kind", Json.str "envMsg"),
      ("blocks", Json.arr (blocks.map envBlockStateJson).toArray)]
  | .otherMsg role blocks => Json.mkObj [
      ("kind", Json.str "otherMsg"), ("role", Json.str role),
      ("blocks", Json.arr (blocks.map userBlockJson).toArray)]
  | .compaction summary coverage tokensBefore =>
      let coverageJson := match coverage with
        | .knownPrefix firstKept => Json.mkObj [
            ("kind", Json.str "knownPrefix"), ("firstKept", Json.num firstKept)]
        | .unknownPrefix => Json.mkObj [("kind", Json.str "unknownPrefix")]
      Json.mkObj [
        ("kind", Json.str "compaction"), ("summary", Json.str summary),
        ("coverage", coverageJson), ("tokensBefore", optionNatJson tokensBefore)]
  | .event event =>
      let eventJson := match event with
        | .modelChange prev next => Json.mkObj [
            ("kind", Json.str "modelChange"), ("prev", optionStringJson prev),
            ("next", optionStringJson next)]
        | .thinkingLevelChange prev next => Json.mkObj [
            ("kind", Json.str "thinkingLevelChange"),
            ("prev", optionStringJson prev), ("next", optionStringJson next)]
        | .permissionMode mode => Json.mkObj [
            ("kind", Json.str "permissionMode"), ("mode", Json.str mode)]
        | .branchSummary summary => Json.mkObj [
            ("kind", Json.str "branchSummary"), ("summary", Json.str summary)]
        | .custom label raw => Json.mkObj [
            ("kind", Json.str "custom"), ("label", Json.str label), ("raw", raw)]
      Json.mkObj [("kind", Json.str "event"), ("event", eventJson)]

private def threadJson (thread : Thread) : Json :=
  let kind := match thread.kind with
    | .main => Json.mkObj [("kind", Json.str "main")]
    | .sidechain anchor => Json.mkObj [
        ("kind", Json.str "sidechain"), ("anchor", rawCallRefJson anchor)]
    | .detached note => Json.mkObj [
        ("kind", Json.str "detached"), ("note", Json.str note)]
  Json.mkObj [("kind", kind), ("label", optionStringJson thread.label)]

private def environmentJson (environment : EnvInfo) : Json := Json.mkObj [
  ("cwd", optionStringJson environment.cwd),
  ("model", optionStringJson environment.model),
  ("provider", optionStringJson environment.provider),
  ("harnessVersion", optionStringJson environment.harnessVersion),
  ("instructions", optionStringJson environment.instructions),
  ("sessionId", optionStringJson environment.sessionId)]

private def originJson (origin : Origin) : Json := Json.mkObj [
  ("format", formatJson origin.format), ("sourceRef", Json.str origin.sourceRef),
  ("rawId", optionStringJson origin.rawId),
  ("extras", origin.extras.getD Json.null)]

private def assumptionKindJson : AssumptionKind -> Json
  | .dedupDropped => Json.str "dedupDropped"
  | .timeInterpolated => Json.str "timeInterpolated"
  | .timeSequenced => Json.str "timeSequenced"
  | .errorInferred => Json.str "errorInferred"
  | .roleCoerced => Json.str "roleCoerced"
  | .toolNameMapped => Json.str "toolNameMapped"
  | .idSynthesized => Json.str "idSynthesized"
  | .contentSkipped => Json.str "contentSkipped"
  | .activeLeafGuessed => Json.str "activeLeafGuessed"
  | .other label => Json.mkObj [("other", Json.str label)]

private def importNoteJson (note : ImportNote) : Json := Json.mkObj [
  ("kind", assumptionKindJson note.kind), ("loc", optionStringJson note.loc),
  ("detail", Json.str note.detail)]

private def stateEntryJson (transcript : Transcript) (entry : Entry) : Json :=
  Json.mkObj [
    ("parent", optionNatJson entry.parent), ("thread", Json.num entry.thread),
    ("time", timeJson entry.time),
    ("disposition", dispositionJson entry.disposition),
    ("payload", payloadStateJson entry.payload),
    ("events", Json.arr (entryEvents transcript entry).toArray)]

/-- Modeled continuation state beyond content: exact graph/thread coordinates,
active leaf, time epistemics, environment, grouping, and trust disposition.
Cross-format comparisons must state their expected target transformation rather
than assuming this stronger projection is invariant. -/
def continuationStateProjection (transcript : Transcript) : String :=
  (Json.mkObj [
    ("threads", Json.arr (transcript.threads.map threadJson)),
    ("entries", Json.arr (transcript.entries.map (stateEntryJson transcript))),
    ("environment", environmentJson transcript.env),
    ("activeLeaf", optionNatJson transcript.activeLeaf)]).compress

/-- Forensic projection of all state above plus source origins, open-world
extras, and import judgments. Equality is appropriate for exact/same-format
claims; target-specific conversions normally require an explicit relation. -/
def auditProjection (transcript : Transcript) : String :=
  let entryOrigins := transcript.entries.map (fun entry => originJson entry.origin)
  (Json.mkObj [
    ("continuationState", (Json.parse (continuationStateProjection transcript)).toOption.getD Json.null),
    ("origin", originJson transcript.origin),
    ("entryOrigins", Json.arr entryOrigins),
    ("importNotes", Json.arr (transcript.importNotes.map importNoteJson).toArray)]).compress

private def dispositionProjectionFixture (disposition : EntryDisposition) : Transcript :=
  let origin : Origin := { format := .other "fixture", sourceRef := "disposition" }
  {
    threads := #[{ kind := .main }]
    entries := #[{
      payload := .assistantMsg [.text "historical payload"]
      origin
      disposition }]
    origin
  }

/-- Carrier provenance is continuation-relevant: typed payload equality alone
must not erase whether an entry is safe to export as native executable state. -/
def continuationProjectionDistinguishesDisposition : Bool :=
  continuationProjection (dispositionProjectionFixture .native) !=
    continuationProjection (dispositionProjectionFixture .historicalUnverified)

example : continuationProjectionDistinguishesDisposition = true := by native_decide

private def stateProjectionFixture : Transcript :=
  let origin : Origin := { format := .other "fixture", sourceRef := "state" }
  { threads := #[{ kind := .main }]
    entries := #[
      { time := .recorded ⟨1⟩, payload := .userMsg [.text "same"], origin },
      { parent := some 0, time := .absent,
        payload := .assistantMsg [.text "answer"], origin }]
    env := { cwd := some "/source", model := some "source-model" }
    activeLeaf := some 1
    origin }

/-- The content-only oracle is intentionally equal for mutations that the
state oracle must detect. This pin prevents future evidence from confusing the
two contracts. -/
def continuationStateProjectionDetectsOmittedDimensions : Bool :=
  let changedTime := { stateProjectionFixture with entries :=
    (stateProjectionFixture.entries.toList.zipIdx.map (fun (entry, index) =>
      if index == 0 then { entry with time := .absent } else entry)).toArray }
  let changedLeaf := { stateProjectionFixture with activeLeaf := some 0 }
  let changedEnvironment := { stateProjectionFixture with
    env := { stateProjectionFixture.env with model := some "other-model" } }
  continuationProjection stateProjectionFixture == continuationProjection changedTime &&
  continuationProjection stateProjectionFixture == continuationProjection changedLeaf &&
  continuationProjection stateProjectionFixture == continuationProjection changedEnvironment &&
  continuationStateProjection stateProjectionFixture != continuationStateProjection changedTime &&
  continuationStateProjection stateProjectionFixture != continuationStateProjection changedLeaf &&
  continuationStateProjection stateProjectionFixture != continuationStateProjection changedEnvironment

example : continuationStateProjectionDetectsOmittedDimensions = true := by native_decide

def auditProjectionDetectsOriginProvenance : Bool :=
  let changed := { stateProjectionFixture with origin :=
    { stateProjectionFixture.origin with extras := some (Json.mkObj [
        ("control", Json.str "archived")]) } }
  continuationStateProjection stateProjectionFixture == continuationStateProjection changed &&
    auditProjection stateProjectionFixture != auditProjection changed

example : auditProjectionDetectsOriginProvenance = true := by native_decide

private def semanticFieldFixture (payload : Payload) : Transcript :=
  let origin : Origin := { format := .other "fixture", sourceRef := "semantic-fields" }
  { threads := #[{ kind := .main }]
    entries := #[{ payload, origin }]
    activeLeaf := some 0
    origin }

/-- Every typed field that can change continuation meaning is observable in the
content projection. Empty messages remain events, and a loose `otherMsg "user"`
cannot impersonate a typed user message merely by sharing its display label. -/
def continuationProjectionDetectsTypedSemanticFields : Bool :=
  let thinkingA := semanticFieldFixture (.assistantMsg [
    .thinking "private" (some "signature-a")])
  let thinkingB := semanticFieldFixture (.assistantMsg [
    .thinking "private" (some "signature-b")])
  let canonicalRead := semanticFieldFixture (.assistantMsg [
    .toolCall { raw := "same", canonical := some .read } Json.null none])
  let canonicalWrite := semanticFieldFixture (.assistantMsg [
    .toolCall { raw := "same", canonical := some .write } Json.null none])
  let unresolvedA := semanticFieldFixture (.envMsg [
    .toolResult (.unresolved (some "call") "missing source A") [] .unrecorded])
  let unresolvedB := semanticFieldFixture (.envMsg [
    .toolResult (.unresolved (some "call") "missing source B") [] .unrecorded])
  let emptyUser := semanticFieldFixture (.userMsg [])
  let emptyAssistant := semanticFieldFixture (.assistantMsg [])
  let typedUser := semanticFieldFixture (.userMsg [.text "same"])
  let looseUser := semanticFieldFixture (.otherMsg "user" [.text "same"])
  continuationProjection thinkingA != continuationProjection thinkingB &&
    continuationProjection canonicalRead != continuationProjection canonicalWrite &&
    continuationProjection unresolvedA != continuationProjection unresolvedB &&
    continuationProjection emptyUser != continuationProjection emptyAssistant &&
    continuationProjection typedUser != continuationProjection looseUser

example : continuationProjectionDetectsTypedSemanticFields = true := by native_decide

private def linkageProjectionFixture (targetBlock : Nat) : Transcript :=
  let origin : Origin := { format := .other "fixture", sourceRef := "linkage" }
  { threads := #[{ kind := .main }]
    entries := #[
      { payload := .assistantMsg [
          .toolCall { raw := "read", canonical := some .read }
            (Json.mkObj [("path", Json.str "a")]) (some "call-a"),
          .toolCall { raw := "read", canonical := some .read }
            (Json.mkObj [("path", Json.str "b")]) (some "call-b")]
        origin },
      { parent := some 0
        payload := .envMsg [
          .toolResult (.resolved 0 targetBlock) [.text "result"]
            (.native false)]
        origin }]
    activeLeaf := some 1
    origin }

/-- Logical call linkage remains observable even when both candidate calls and
all result content are otherwise unchanged. -/
def continuationProjectionDetectsCallLinkage : Bool :=
  continuationProjection (linkageProjectionFixture 0) !=
    continuationProjection (linkageProjectionFixture 1)

example : continuationProjectionDetectsCallLinkage = true := by native_decide

/-- Content comparison deliberately permits a target to split a message into
multiple storage entries. The state projection still observes that grouping,
including the resulting parent coordinates. -/
def continuationStateProjectionDetectsGrouping : Bool :=
  let grouped := semanticFieldFixture (.assistantMsg [.text "a", .text "b"])
  let first : Entry := {
    payload := .assistantMsg [.text "a"]
    origin := grouped.origin }
  let second : Entry := {
    parent := some 0
    payload := .assistantMsg [.text "b"]
    origin := grouped.origin }
  let split := { grouped with
    entries := #[first, second]
    activeLeaf := some 1 }
  continuationProjection grouped == continuationProjection split &&
    continuationStateProjection grouped != continuationStateProjection split

example : continuationStateProjectionDetectsGrouping = true := by native_decide

end Loom
