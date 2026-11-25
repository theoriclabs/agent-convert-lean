import LoomConvert.Pi
import LoomConvert.IRCodec

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
            (.heuristic true "fixture heuristic"),
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
  .googleAiStudio, .openCode]

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
