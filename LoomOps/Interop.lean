import Loom

/-!
# Loom — the interop contract

Loom's purpose is **transcript portability across agent harnesses**: a session
begun in Codex continues in Claude, and then in Codex again. Every other
property this project tracks — validity, provenance, refusal policy, release
gating — is subordinate to that purpose and is worth exactly as much as it
contributes to it.

2026-09-07 clarification: `INTENT.md` makes this a conversation-continuity
requirement. The destination model receives source executions as its prior
native tool history; importing that history does not rerun them. Completion
and output availability are independent facts. A completed/pruned Cursor call
must not become assistant disclaimer prose merely because its result body was
not retained. The exact-result gate in `nativeCallRecordAt?` still violates this
intent; see `docs/bugs/native-tool-history.md` and `docs/plans/native-tool-history.md`.
The compliance observations below are dated evidence, not a claim that the
current exporters satisfy the clarified requirement.

This module states the design principles as typed data so they are queryable
and so a violation is a value, not a footnote. It is description, not
enforcement: `compliance` records what the shipped exporters do as of
2026-07-24, measured, not assumed.

## The measurement that motivated this module

A `codex → claude → codex` round trip of `testdata/codex/tool-lifecycle-controls.jsonl`
destroyed the entire tool lifecycle. The source held `function_call`,
`function_call_output`, `custom_tool_call`, and `tool_search_call` records. The
returned artifact held **none** of them: each had become an assistant text
message reading `[Historical tool call from source transcript; not executed by
Codex]` followed by raw JSON.

The import layer is not at fault. `loom inspect codex` on that fixture shows a
correctly linked IR: an assistant `toolCall exec_command; id=call-function`
followed by an environment `tool result for entry 1, block 0`. Names, ids,
arguments, ordering, and call↔result linkage are all present and all valid for
a native Claude `tool_use`/`tool_result` pair. The export layer discards that
work on a provenance test.

## The defect class in one sentence

`LoomConvert/ClaudeCode.lean:3595` gates native emission on
`t.origin.format == Format.claudeCode`, so the Claude exporter can emit a
native tool call **only for transcripts that were already Claude** — the one
case where conversion is unnecessary. The same shape recurs in every exporter
(`CodexCli.lean:3014`, `CursorAgent.lean:1084`, `Pi.lean:819`), which is why
the loss compounds on each hop instead of saturating: a transcript that leaves
its home format can never return to native form.
-/

namespace Loom.Ops.Interop

/-! ## What may decide how a datum is rendered -/

/-- The inputs an exporter is allowed to consult when choosing a representation.

The distinction is the whole point. Whether Claude can express a tool call is a
fact about *Claude*; it cannot depend on whether the transcript arrived from
Codex or from Claude. An exporter that consults `sourceProvenance` has
confused "where this came from" with "what this is", and thereby makes
conversion — its only job — the thing it refuses to do well. -/
inductive EmissionDeterminant where
  /-- Does the target format have a native slot for this concept? Legitimate:
  this is a property of the target alone. -/
  | targetCapability
  /-- Does this datum satisfy the target's structural requirements (id charset,
  argument shape, call↔result pairing)? Legitimate: a property of the datum
  and the target, checkable without knowing the source. -/
  | structuralValidity
  /-- Which format was this imported from? **Never legitimate.** Provenance is
  worth recording and worth carrying out-of-band; it is never a reason to
  render a representable fact as prose. -/
  | sourceProvenance
  deriving Repr, DecidableEq

def EmissionDeterminant.legitimate : EmissionDeterminant → Bool
  | .targetCapability | .structuralValidity => true
  | .sourceProvenance => false

/-! ## How a datum may be rendered -/

/-- Representation strategies, in strict preference order. An exporter must
choose the first one that is available for the datum at hand. -/
inductive Emission where
  /-- The target's own construct: a Claude `tool_use`, a Codex `function_call`.
  Required whenever the target can express the concept. -/
  | native
  /-- Omitted from visible content, preserved verbatim in an envelope field the
  target harness ignores but a re-import can recover. This is how a concept the
  target lacks survives a return trip. -/
  | envelopePreserved
  /-- Rendered as the closest thing the target can display, with a typed loss
  recorded. Permitted only when the concept is neither native nor
  envelope-preservable. -/
  | approximated
  /-- No artifact produced. Legitimate only when emitting would produce a
  corrupt or actively misleading artifact — never merely because output would
  be lossy. -/
  | refused
  deriving Repr, DecidableEq

/-- Emission strategies that place converter bookkeeping inside content the
user and the model will read. Reserved for the empty set: see `provenanceOutOfBand`. -/
def Emission.pollutesContent : Emission → Bool
  | _ => false

/-! ## Round-trip quality -/

/-- How well `A → B → A` holds. The project's correctness criterion should be
stated here rather than in per-format fixture assertions.

`degrading` is the status quo and is the uniquely unacceptable value: it means
loss is a function of hop count, so portability decays with use. A tool that
loses a fixed set of facts once is useful; one that loses more on every
transfer is not a portability tool at all. -/
inductive RoundTripLevel where
  /-- Output bytes equal input bytes. Achievable only same-format with no
  retargeting. -/
  | byteIdentical
  /-- IR equal modulo fields the target legitimately mandates (session id, cwd,
  harness version, timestamps). The realistic target for cross-format work. -/
  | semanticIdentity
  /-- Loss occurs on the first hop but never grows: hop n and hop n+1 lose the
  same set. Acceptable where a concept genuinely has no target representation. -/
  | nonAccumulating
  /-- Each hop loses strictly more than the last. Unacceptable. -/
  | degrading
  deriving Repr, DecidableEq

def RoundTripLevel.acceptable : RoundTripLevel → Bool
  | .byteIdentical | .semanticIdentity | .nonAccumulating => true
  | .degrading => false

/-! ## The principles -/

inductive Compliance where
  /-- The shipped exporters follow this principle. -/
  | honored
  /-- Followed in some paths, violated in others; `evidence` cites both. -/
  | mixed (evidence : String)
  /-- Contradicted by shipped behavior; `evidence` cites the contradiction. -/
  | violated (evidence : String)
  deriving Repr

def Compliance.isViolation : Compliance → Bool
  | .violated _ => true
  | _ => false

structure Principle where
  id : String
  statement : String
  rationale : String
  compliance : Compliance
  deriving Repr

/-- The interop contract. Ordered by how much damage the current violation does. -/
def principles : List Principle := [
  { id := "P1-native-by-default"
    statement :=
      "If the target format can natively express a concept, emit the native \
       construct. Degrade only when the target genuinely cannot express it."
    rationale :=
      "This is what conversion means. A transcript whose tool calls arrive as \
       prose cannot be resumed as a working session, which is the only reason \
       to convert it."
    compliance := .mixed
      "Honoured for claude↔codex and hermes→claude as of 2026-07-24: the \
       provenance gates in cClaudeNativeEntryProvenance and the Codex native \
       evidence path now consult target capability and structural validity \
       only. Measured on a real session: codex→claude→codex preserves 42/42 \
       tool calls and 42/42 results natively, where it previously preserved 0. \
       Still violated for the pi target (piEntryHasNativePiMessage requires a \
       retained raw pi message) and for cursor-agent, which refuses before \
       examining content." }

, { id := "P2-provenance-out-of-band"
    statement :=
      "Conversion metadata never appears in visible message content. It lives \
       in envelope fields the target harness ignores and a re-import can read."
    rationale :=
      "Content is what a participant said or did. Three separate costs to \
       violating this: the user reads plumbing instead of their conversation; \
       the model reads raw JSON as context, which both degrades behaviour and \
       ENLARGES the prompt-injection surface the carrier design claims to \
       reduce; and the next importer must recover structure by parsing prose."
    compliance := .violated
      "claudeHistoricalToolCallCarrierText et al. (ClaudeCode.lean:401-417) \
       write '[Historical tool call from source transcript; not executed by \
       Claude]' plus raw JSON into message.content. The top-level _agent_convert \
       envelope already exists and is used only to index INTO these content \
       carriers rather than to hold the data itself." }

, { id := "P3-round-trip-is-correctness"
    statement :=
      "A → B → A stability is the primary correctness criterion, mechanically \
       checked across every declared format pair, at minimum at \
       RoundTripLevel.nonAccumulating."
    rationale :=
      "It is the property the user actually needs, it is cheap to test, and it \
       is the one property that cannot be satisfied by a self-consistent but \
       wrong exporter."
    compliance := .violated
      "codex→claude→codex now measures RoundTripLevel.semanticIdentity for the \
       tool lifecycle (42/42 both directions), but that was established by hand, \
       not by a test. No automated A→B→A check exists for any pair, so nothing \
       stops the property regressing — which is exactly how the original defect \
       survived. This stays violated until the census in §P4 of AUDIT.md lands." }

, { id := "P4-report-loss-do-not-enact-it"
    statement :=
      "When the target cannot represent a fact, preserve it out-of-band, or \
       approximate it and record a typed loss. Refuse only when the artifact \
       would be corrupt or misleading — never merely because output is lossy."
    rationale :=
      "A user moving a session between harnesses is better served by a \
       faithful-where-possible artifact plus an honest loss report than by a \
       refusal or by content silently replaced with commentary about content."
    compliance := .mixed
      "Loss is reported (exportObligations, importJudgments are good and \
       machine-readable). But refusal is a first-class default across \
       Main.lean's exportBlocker?/targetValidityBlocker?, and substitution — \
       replacing content with prose about the content — is the standard \
       degradation path rather than envelope preservation." }

, { id := "P5-validate-against-the-real-target"
    statement :=
      "Success means the target harness accepts and resumes the artifact. \
       Self-validation (export, re-import with our own importer, compare) is \
       necessary but never sufficient."
    rationale :=
      "Export→reimport is a closed loop over our own assumptions. It is exactly \
       the check that a converter emitting carrier prose passes perfectly while \
       producing something no harness can use."
    compliance := .mixed
      "exportCursorAgentTargetChecked and the Claude/Codex checked exporters do \
       rigorous self-validation, and HUMAN_VALIDATION.md defines an external \
       protocol. But the automated gate proves self-consistency only, which is \
       why a total interop failure shipped through it." }

, { id := "P6-fidelity-belongs-in-the-types"
    statement :=
      "Degradation must be visible in the type system. Emitting an \
       approximation should be impossible without producing a Loss value."
    rationale :=
      "Lean was chosen for its type system; this is where the leverage is. \
       Today the choice between a native tool_use and a prose carrier is a Bool \
       branch selecting a different Json (ClaudeCode.lean:3643-3651) — the \
       lossy path is as easy to write as the faithful one and is invisible in \
       every signature. LoomOps/Design.lean already argues the refinement-lattice \
       version of this point; the exporters do not follow it."
    compliance := .violated
      "Exporters still return Except String String. A silent downgrade from \
       native to carrier is invisible in every signature — which is why three \
       separate over-strict checks (ErrorSignal.native in Claude, Codex and Pi) \
       each independently forced prose without any type recording the loss." }

, { id := "P7-unknown-data-survives"
    statement :=
      "Records a pinned version does not model must round-trip verbatim via \
       envelope preservation, never by flattening into prose."
    rationale :=
      "Harnesses ship weekly; unmodelled records are the normal case, not an \
       error. Observed live: Codex CLI 0.145.0 emits a `compaction` response_item \
       that this 0.144.1-pinned importer does not model."
    compliance := .mixed
      "Import preserves unknown records verbatim (correct — .unmodeled keeps \
       exact payloads, and origin.extras retains raw records). Export then \
       renders them as prose carriers, so the preservation is one-way." }

, { id := "P8-hub-is-the-union"
    statement :=
      "The IR models the union of the formats' concept spaces. A concept native \
       to one harness is first-class in the IR so a return trip can restore it."
    rationale :=
      "A hub that models only the intersection makes every conversion lossy by \
       construction. Loom.lean already states this ('pi is a spoke, not the \
       hub'); it must hold for concepts, not only for formats."
    compliance := .mixed
      "Threads, compaction coverage, error provenance and time provenance are \
       genuinely first-class and well modelled. Token usage is not modelled at \
       all (Loom/Formats/CodexCli.lean:108-109 records this as a known gap), and \
       several concepts survive only as opaque origin.extras that exporters \
       cannot consume." }

, { id := "P9-version-skew-is-normal"
    statement :=
      "Accept a version range and preserve unknown fields. Do not make an exact \
       harness version a precondition for producing output."
    rationale :=
      "An interop tool exists precisely because the ecosystem is heterogeneous \
       and moving. A hard pin converts every upstream release into an outage."
    compliance := .violated
      "Claude export requires harness version exactly 2.1.216, Codex exactly \
       0.144.1, Pi exactly 0.74.0 (README.md 'Versions and probes'), enforced as \
       export prerequisites. The live Codex CLI is already 0.145.0." }
]

def violations : List Principle :=
  principles.filter (fun p => p.compliance.isViolation)

/-! ## Where conversion metadata lives

Decision (2026-07-24, owner): conversion metadata is stored **separately from
the transcript**. Transcripts stay as native as possible.

Three places metadata could go, in decreasing nativeness:

| Location | Native? | Recoverable? | Verdict |
|---|---|---|---|
| A sibling sidecar file | fully — transcript is byte-native | yes, by path convention | **chosen** |
| Top-level envelope key on each record (`_agent_convert`) | mostly — harness ignores unknown keys, but the file is not what the harness would have written | yes | fallback only where a carrier genuinely exists |
| Inside `message.content` | no — user and model both read it | only by parsing prose | **never** (P2) |

The sidecar is the only option that leaves the artifact indistinguishable from
a native session file. It should carry: engine and core revision; source and
target format; source path and session identity; the import-judgment trace;
export obligations; and every normalization the target could not express —
notably error-signal inference (a flat target's `is_error` is a bare boolean,
so "this was inferred by heuristic, not recorded by the harness" has no slot in
the transcript and would otherwise be silently lost).

Naming follows the existing publication contract, which already reserves
`<output>.agent-convert-stage` and `<output>.agent-convert-backup`:

```text
<output>.loom-provenance.json
```

Status: specified here; not yet emitted by the CLI. Until it exists, the
metadata it would carry still rides in the top-level `_agent_convert` envelope
— out of `message.content`, so P2's hard rule holds, but not yet out of the
transcript. -/
inductive MetadataLocation where
  /-- A sibling file. The transcript is byte-native. -/
  | sidecarFile
  /-- A top-level key on each record; ignored by the harness but present in the
  transcript the harness did not write. -/
  | recordEnvelope
  /-- Inside visible message content. Forbidden. -/
  | messageContent
  deriving Repr, DecidableEq

def MetadataLocation.permitted : MetadataLocation → Bool
  | .sidecarFile | .recordEnvelope => true
  | .messageContent => false

def MetadataLocation.preferred : MetadataLocation := .sidecarFile

def provenanceSidecarSuffix : String := ".loom-provenance.json"

/-! ## The corrected emission rule

The replacement for the provenance gate, stated as the rule the exporters
should implement. Note the absence of any source-format argument: that absence
IS the fix. Every structural check currently in `cNativeClaudeCallAt` — tool
name charset, object-shaped arguments, id validity, id uniqueness, a single
resolved result site, correct ordering — is legitimate and should stay. Only
the `cClaudeNativeEntryProvenance` conjunct, and the demand that the result's
error signal be `ErrorSignal.native` rather than any decided boolean, should
go. -/
structure EmissionRule where
  /-- Can the target express this concept at all? -/
  targetSupports : Bool
  /-- Does this datum meet the target's structural requirements? -/
  structurallyValid : Bool
  /-- Can the target carry it in an ignored envelope field? -/
  envelopeAvailable : Bool
  deriving Repr, DecidableEq

def EmissionRule.choose (r : EmissionRule) : Emission :=
  if r.targetSupports && r.structurallyValid then .native
  else if r.envelopeAvailable then .envelopePreserved
  else .approximated

/-- The rule never refuses, and never consults provenance. Refusal is reserved
for artifact-level corruption, which is not a per-datum decision. -/
example (r : EmissionRule) : r.choose ≠ .refused := by
  obtain ⟨supports, valid, envelope⟩ := r
  cases supports <;> cases valid <;> cases envelope <;> decide

/-! ## What each target's wire format can actually hold

Derived ad hoc four separate times during the 2026-07-24 work — Codex's missing
canonical slot, Codex's array `output` form, Pi's missing canonical slot, Pi's
id-keyed call namespace — each time by reading an exporter and guessing. Stated
once here so the next target is a lookup, not a rediscovery.

`none` means UNMEASURED, not false. Only fields verified against a shipped
exporter are recorded; guessing here would defeat the point.

`toolLifecycle` was ONE field until 2026-07-26, when measuring cursor-agent
found a target that has native tool CALLS and no tool RESULT record at all. A
single Bool could not state that without lying in one direction or the other,
so the field is split. Every other target answers `some true` to both halves. -/
structure TargetCapability where
  target : String
  /-- A native tool-call construct: a Claude `tool_use`, a Codex
  `function_call`, a Cursor `tool_use` block. -/
  toolCalls : Option Bool
  /-- A native tool-RESULT construct linked back to its call. Separate from
  `toolCalls` because cursor-agent has the first and not the second: results
  simply do not exist in its wire format, so a converted session arrives with
  every call open. That is the format's normal state, not a corruption of it. -/
  toolResults : Option Bool
  /-- Whether a canonicalized call survives this target with its
  `ToolName.canonical` intact — NOT whether the harness's own tool-call
  construct has a field for it. No shipped harness has such a field; Claude's
  `tool_use` is `{id,name,input}`, Codex's `function_call` is
  `{name,call_id,arguments}`, Pi's `toolCall` is `{id,name,arguments}`.

  The distinction is the whole point of `Emission.envelopePreserved`. Reading
  this row as "does the block have a slot" made the answer `false` and the
  policy "keep the carrier", which spent the target's entire native lifecycle —
  the thing conversion exists to produce — to protect one scalar. Reading it as
  "does the field survive" lets the exporter emit the native construct AND stash
  the field in an envelope the harness ignores. Where a row says `some true`,
  read `notes` for where the field actually rides. -/
  canonicalToolName : Option Bool
  /-- A slot distinguishing recorded / inferred / unrecorded error provenance.
  Where absent, only the error VALUE survives; the provenance normalizes and
  that normalization is reported, not refused. -/
  errorProvenance : Option Bool
  /-- Ordered multi-block result content, rather than one flat string. Where
  absent, joining blocks collapses distinct transcripts — `["ab","c"]` and
  `["a","bc"]` both becoming "abc" — so the carrier is correct. -/
  multiBlockResults : Option Bool
  /-- Per-entry timestamps. -/
  entryTimestamps : Option Bool
  /-- Session environment: cwd, model, provider, harness version. -/
  environment : Option Bool
  /-- Why a row says what it says, where the value alone would mislead. -/
  notes : String := ""
  deriving Repr

def targetCapabilities : List TargetCapability := [
  -- canonicalToolName measured 2026-07-26. `claude` read `some true` before
  -- that and was OVER-CLAIMED: true of the prose carrier record, false of the
  -- native `tool_use` block, which wrote `{type,id,name,input}` and nothing
  -- else — so a source asserting `read`/`bash`/`edit` got `canonicalName: null`
  -- back from every native emission. `codex` and `pi` read `some false` and
  -- were accurate, but the policy they justified (force the carrier) cost
  -- native emission outright. All three now carry the field out of band beside
  -- a real native construct, and all three are honestly `some true`.
  { target := "claude", toolCalls := some true, toolResults := some true,
    canonicalToolName := some true,
    errorProvenance := some false, multiBlockResults := some true,
    entryTimestamps := some true, environment := some true
    notes :=
      "canonicalToolName: OUT OF BAND. The `tool_use` block itself holds only \
       {type,id,name,input}; the canonical identity travels as a \
       `toolCanonical` member of the record-level `_agent_convert` marker \
       (`LoomConvert/ClaudeCode.lean`, `cEntryToolCanonical` / \
       `cCarrierToolCanonical?`), which is block-indexed and sits beside the \
       existing `contentBlocks` and provenance members. Claude ignores the \
       key; the block stays an executable tool call. The member is written \
       ONLY when a natively emitted call carries a canonical identity, which \
       the Claude importer never produces on its own, so claude → claude adds \
       nothing and stays byte-exact. errorProvenance: `is_error` is a bare \
       bool with no unknown state, so recorded/inferred/unrecorded collapses \
       to the value alone — except `.unrecorded`, which is OMITTED rather \
       than written `false`." },
  { target := "codex", toolCalls := some true, toolResults := some true,
    canonicalToolName := some true,
    errorProvenance := some true, multiBlockResults := some true,
    entryTimestamps := some true, environment := some true
    notes :=
      "canonicalToolName: OUT OF BAND. `function_call` holds only \
       {type,name,call_id,arguments}; the canonical identity travels as a \
       reserved `_agent_convert` member of the same payload, kind \
       `tool_canonical` (`LoomConvert/CodexCli.lean`, \
       `codexToolCanonicalMarker` / `codexPayloadToolCanonical?`). Only an \
       exporter-stamped session may speak it, and \
       `codexReservedRecordSourceFailure?` additionally holds such a record to \
       canonical whole-line bytes. Absent a canonical identity no member is \
       written, which is what keeps `exactImportedNativeCallEvidence?` \
       byte-exact for codex → codex. errorProvenance: OUT OF BAND. Native \
       results preserve the complete ErrorSignal in the reserved payload \
       marker (`tool_result_error`, or the legacy `tool_result_unrecorded`). \
       This includes errors whose text disagrees with Codex's heuristic. \
       Output text is unchanged and the lifecycle stays native. Unstamped \
       Codex input still uses the original heuristic; metadata never asserts \
       that the tool was rerun by the target." },
  { target := "pi", toolCalls := some true, toolResults := some true,
    canonicalToolName := some true,
    errorProvenance := some true, multiBlockResults := some true,
    entryTimestamps := some true, environment := some true
    notes :=
      "canonicalToolName: OUT OF BAND, and necessarily so — a reserved Loom \
       stamp ON a content block marks the whole message historical \
       (`piAssistantContentHasCarrier`), so the field rides in the \
       MESSAGE-level `loomPi` stamp beside `toolCallRef`/`toolError` \
       (`LoomConvert/Pi.lean`, `piToolCanonicalCarrier` / \
       `piToolCanonicalCarrier?`), indexed by emitted content position. Absent \
       a canonical identity no member is written, so pi → pi is unchanged. \
       errorProvenance: OUT OF BAND, and `some true` since 2026-07-26. \
       Codex now preserves these states too. The \
       wire field is a bare `isError` bool; the PROVENANCE rides beside it in \
       the same message-level `loomPi` stamp, as its reserved `toolError` \
       member. `piErrorExport` writes `{state:inferred,value,heuristic}` for \
       `.inferred` — the heuristic STRING included — and `{state:unrecorded}` \
       for `.unrecorded`, and writes nothing for `.native`, whose bare bool \
       already says everything known. `piToolErrorSignal` reads each back and \
       an absent stamp restores `.native`, so all three states are recovered, \
       not normalized. The stamp cannot drift from the wire bool either: an \
       `inferred` carrier whose `value` disagrees with `isError`, or an \
       `unrecorded` carrier beside `isError: true`, FAILS THE IMPORT rather \
       than being reconciled. Measured end to end by \
       `LoomConvert.piToolErrorEpistemicsPinned`: a foreign source's four \
       results export native and re-import as \
       [.native false, .native true, .inferred true \"nonzero exit\", \
       .unrecorded], and a second export is byte-equal to the first." },
  -- Measured 2026-07-26 by reading LoomConvert/CursorAgent.lean's importer and
  -- exporter against the 2026-07-06 census in Loom/Formats/CursorAgent.lean
  -- (427 files / ~14,863 records). This row was `none` across every content
  -- field because the exporter refused before examining content; it does not
  -- any more, and these are the values that fell out.
  { target := "cursor-agent", toolCalls := some true, toolResults := some false,
    canonicalToolName := some false,
    errorProvenance := some false, multiBlockResults := some false,
    entryTimestamps := some false, environment := some false
    notes :=
      "toolCalls: `BlockKind` is EXACTLY text + toolUse; the census counted \
       16,210 `tool_use` blocks. toolResults: zero `tool_result` anywhere in \
       the corpus, and `importCursorAgent` has no result branch — so every \
       converted call arrives open and `cursorAgentNativeToolResultCount` is 0 \
       by construction. canonicalToolName: the block holds only name/input/ \
       optional id, and the importer RE-DERIVES `ToolName.canonical` via \
       `cursorCanonicalTool`, so an asserted canonical identity that disagrees \
       with the raw name has nowhere to live and keeps its carrier. \
       errorProvenance: `Concept.errorSignaling` is `.absent` — with no result \
       record there is not even a bare `is_error` bool. multiBlockResults: \
       vacuously false; there are no results to have blocks, so \
       `collapseResultBlockBoundaries` cannot arise for this target. \
       entryTimestamps/environment: no timestamp key and no cwd/model/provider \
       on any of the three record shapes; session identity is recoverable only \
       from the FILE NAME, which is a path convention, not transcript content." },
  { target := "loom", toolCalls := some true, toolResults := some true,
    canonicalToolName := some true,
    errorProvenance := some true, multiBlockResults := some true,
    entryTimestamps := some true, environment := some true }]

/-- Rows still carrying an unmeasured content capability. Empty is the goal;
a nonempty result names a target nobody has read the exporter for. -/
def unmeasuredCapabilities : List String :=
  (targetCapabilities.filter (fun capability =>
    capability.toolCalls.isNone || capability.toolResults.isNone ||
      capability.canonicalToolName.isNone || capability.errorProvenance.isNone ||
      capability.multiBlockResults.isNone)).map (·.target)

/-! ## When a loss justifies refusing

`Emission.refused` says refusal is for artifacts that would be "corrupt or
actively misleading", never for merely lossy ones — but "corrupt" was an
adjective, so the distinction was never checkable and the cursor-agent exporter
drifted to refusing on lossiness. This makes it decidable. -/
inductive LossImpact where
  /-- The artifact would assert something untrue: a fabricated id, a call whose
  result cannot resolve, an error flag the source never set, content attributed
  to a turn that did not produce it. Refusal is correct — a wrong transcript is
  worse than no transcript. -/
  | corrupting
  /-- A fact the target has no slot for. The artifact is still valid, still
  resumable, and still an honest record of what it does contain. Refusal is
  NOT correct; emit, and record the loss. -/
  | reportable
  deriving Repr, DecidableEq

/-- Refusal is permitted exactly when the loss is corrupting. -/
def LossImpact.justifiesRefusal : LossImpact → Bool
  | .corrupting => true
  | .reportable => false

structure KnownLoss where
  obligation : String
  impact : LossImpact
  reason : String
  deriving Repr

/-- The losses the converter actually produces, classified. Every `reportable`
row that today causes a refusal is a bug against `Emission.refused`.

One row — `synthesizeTimestamps` — classifies a loss shape no shipped target
produces. It is here because its `reportable` sibling `dropTimeProvenance` is,
and the difference between them is the whole content of both: dropping a guess
is honest, minting a fact over it is not. Leaving the corrupting half unstated
left the honest half looking like a general licence to touch timestamps.

`LoomOps.Conversion.obligationForcedByTargetLimits` cites this table and claims
to answer "for the exact obligations whose losses `knownLosses` classifies
`reportable`". As of 2026-07-26 that holds in one direction: every obligation
it can answer `true` for has a `reportable` row here. It is not onto —
`dropUnmodeled` is `reportable` here and the predicate does not answer for it,
so the CLI still rates it `.destructive` and refuses. That is a live instance of
the sentence above this one, not a defect in this table. -/
def knownLosses : List KnownLoss := [
  { obligation := "dropRecordedTime", impact := .reportable
    reason := "A transcript without per-entry timestamps is still a complete, \
      resumable record of the conversation. Cursor Agent JSONL has no timestamp \
      field, so refusing on this makes the target unreachable from every real \
      source — which is the observed behaviour." },
  { obligation := "dropEnvironment", impact := .reportable
    reason := "cwd/model/provider are context, not content. Losing them changes \
      what a continuation infers, which is worth reporting loudly and worth \
      carrying in a sidecar — but the transcript itself is intact." },
  { obligation := "dropUnmodeled", impact := .reportable
    reason := "Unmodeled blocks are opaque payloads the target cannot express. \
      They belong in the sidecar; dropping them silently would be the bug, not \
      dropping them at all." },
  -- Added 2026-07-26: both were rated `destructive` by the obligationImpactFor
  -- catch-all and both are now target-scoped `reportOnly`, so the contract has
  -- to say which they are rather than leave the code to decide unattested.
  { obligation := "dropThinking", impact := .reportable
    reason := "Reasoning is not what a participant said or did, and a target \
      with no reasoning slot renders a conversation that is still complete and \
      still resumable. Cursor Agent has no thinking block at all, so refusing \
      here would refuse every Claude source." },
  { obligation := "dropToolResults", impact := .reportable
    reason := "Only where the target has NO tool-result record — cursor-agent \
      is the sole such target. Every native session in that format shows calls \
      without results, so their absence asserts nothing false; it is the \
      format's normal state. Dropping results from a target that HAS the slot \
      stays destructive, because there the exporter is discarding a fact it \
      could have written. Note the asymmetry with tool CALLS: those the format \
      does have, so an absent call would assert the assistant did not act, and \
      that is corrupting — the exporter refuses instead of dropping one." },
  -- Added 2026-07-26. `obligationForcedByTargetLimits` already answered `true`
  -- for both of these and cited this table as its authority, so the code was
  -- extending an attested classification to two obligations nobody had
  -- classified. The verdicts below are the ones the code was assuming; they are
  -- written down here so the citation is true.
  { obligation := "dropTimeProvenance", impact := .reportable
    reason := "The fact at risk is a NON-recorded `Time` — `.absent`, \
      `.interpolated`, or `.sequenced`. The source knew an ordering or an \
      estimate, never a recording. A target with no timestamp slot renders that \
      as 'we do not know when', which is exactly what the source knew: nothing \
      untrue is asserted, no participant's words move, and the conversation \
      resumes unchanged. `obligationForcedByTargetLimits` answers `true` here \
      only where `supports tgt .time == .absent`, which among the five export \
      targets is cursor-agent alone; a target that HAS the slot and drops the \
      value anyway is still destructive. The corrupting sibling is \
      `synthesizeTimestamps` below." },
  { obligation := "dropSourceIdentity", impact := .reportable
    reason := "A session or entry id names WHERE a transcript came from, not \
      what was said or done in it. A target with no identity slot — \
      `supports tgt .identity == .absent`, again cursor-agent alone, whose \
      session identity is recoverable only from the FILE NAME — still yields a \
      complete, resumable record, and the id belongs in the sidecar. \
      `obligationImpactFor` reaches the same verdict by a second route via \
      `hasExplicitTargetSessionIdentity`: once the target registers an identity \
      of its own, what is lost is a spelling, not a participant. Minting an id \
      that CLAIMS to be the source's would be corrupting — that is \
      `fabricateCallId`'s class — which is why `synthesizeEntryIds` mints \
      target-scoped ids that assert nothing about the source." },
  { obligation := "fabricateCallId", impact := .corrupting
    reason := "An invented id asserts a linkage the source never had, and the \
      artifact would claim a call happened that did not." },
  { obligation := "unresolvableToolResult", impact := .corrupting
    reason := "A result whose call cannot be found fails the target's own \
      structural check — the artifact is not merely lossy, it is invalid." },
  { obligation := "collapseResultBlockBoundaries", impact := .corrupting
    reason := "Joining multi-block results makes distinct transcripts identical. \
      Two different histories rendering to the same bytes is misinformation, \
      not omission." },
  -- The guard row. No shipped target reaches it; see the module note above for
  -- why it is stated anyway.
  { obligation := "synthesizeTimestamps", impact := .corrupting
    reason := "Corrupting ONLY where the minted timestamp stands IN PLACE OF \
      the source's typed `Time` rather than beside it. A wire timestamp \
      substituted for `.absent`/`.interpolated`/`.sequenced` asserts a fact the \
      source never had and no reader can tell the guess from a recording — the \
      timestamp analogue of `fabricateCallId`. The shipped obligation is NOT \
      that, and `obligationImpactFor` is right to rate it `.fulfillment`: \
      `synthesizesTargetTimestamps` is true only for pi/claude/codex, all three \
      of which also answer `true` to `preservesNonRecordedTimeProvenance`, so \
      the source `Time` rides out of band and returns exactly — measured by \
      `LoomRequirements` pin `timestampSynthesisAndLossAreDistinct`. The one \
      target that loses the provenance, cursor-agent, mints nothing, and takes \
      `dropTimeProvenance` instead. Synthesis and loss are disjoint today; this \
      row is what makes their overlap a stated defect rather than a silent \
      one." }]

/-! ## Per-target success criteria

What "done" means, so it is a check rather than a judgement call. -/
structure TargetGoal where
  target : String
  /-- Every tool call the target can structurally represent — nonempty name,
  object arguments, nonempty id, no canonical identity the target cannot hold —
  reaches it as a native construct, with zero carriers for that class. -/
  nativeLifecycleForRepresentableCalls : Bool
  /-- The floor for `source → target → source` on the tool lifecycle. -/
  lifecycleRoundTrip : RoundTripLevel
  /-- The target is reachable at all from a real Claude or Codex session. -/
  reachableFromRealSession : Bool
  /-- The target is reachable **from itself**: a real session in the target's
  own format converts to that format and produces an artifact.

  Separate from `reachableFromRealSession` because the two moved apart on
  2026-07-26. cursor-agent became reachable from claude and codex that day and
  is still unreachable from a real cursor-agent session, so the earlier field
  now reads `true` for a target that cannot consume its own format's output.

  It is the weakest reachability question there is — the source needs no
  translation, every concept is by construction expressible, and the identity
  conversion is the one an exporter cannot get wrong by being lossy. A `false`
  here is therefore never a `RoundTripLevel` question and never an
  expressiveness question; it means the exporter and the target-validity
  contract disagree about what the format IS. -/
  reachableFromOwnFormat : Bool
  status : Compliance
  deriving Repr

def targetGoals : List TargetGoal := [
  { target := "claude", nativeLifecycleForRepresentableCalls := true
    lifecycleRoundTrip := .semanticIdentity, reachableFromRealSession := true
    reachableFromOwnFormat := true
    status := .honored },
  { target := "codex", nativeLifecycleForRepresentableCalls := true
    lifecycleRoundTrip := .semanticIdentity, reachableFromRealSession := true
    reachableFromOwnFormat := true
    status := .honored },
  { target := "pi", nativeLifecycleForRepresentableCalls := true
    lifecycleRoundTrip := .semanticIdentity, reachableFromRealSession := true
    reachableFromOwnFormat := true
    status := .honored },
  -- NOTE (2026-07-26): `lifecycleRoundTrip := .semanticIdentity` is
  -- unreachable for this target BY CONSTRUCTION, not by defect. Cursor Agent
  -- stores no tool results (see `targetCapabilities`), so `X → cursor-agent → X`
  -- cannot restore them at any hop count; the honest ceiling is
  -- `.nonAccumulating`. The row is deliberately NOT downgraded yet: doing so
  -- would drop cursor-agent out of `unmetGoals` while `scripts/verify.sh` is
  -- still red for unrelated reasons. Revisit once that gate passes.
  { target := "cursor-agent", nativeLifecycleForRepresentableCalls := true
    lifecycleRoundTrip := .semanticIdentity, reachableFromRealSession := true
    reachableFromOwnFormat := false
    status := .violated
      "Reachability FIXED 2026-07-26 — claude→cursor-agent and \
       codex→cursor-agent now emit artifacts with every structurally \
       representable tool call native (1/1 on both parity fixtures), where both \
       previously refused before examining content. Two copies of the same \
       defect were removed: the `obligationImpactFor` catch-all rating \
       dropRecordedTime/dropEnvironment destructive, and the exporter's own \
       timeFailures/sourceEnvFailures preflight. Native emission no longer \
       consults `origin.format`. STILL VIOLATED for two reasons. (1) The stated \
       `lifecycleRoundTrip` is unreachable: results have no wire form, so the \
       ceiling is `.nonAccumulating` — see the note above. (2) cursor-agent is \
       not reachable from ITSELF: `cursorAgentTargetNativeRecord` rejects any \
       record carrying a top-level `type` key, which is the format's own \
       `turn_ended` metaevent, so cursor-agent→cursor-agent still refuses. That \
       is pre-existing and independent of the reachability work." },
  { target := "loom", nativeLifecycleForRepresentableCalls := true
    lifecycleRoundTrip := .byteIdentical, reachableFromRealSession := true
    reachableFromOwnFormat := true
    status := .honored }]

def unmetGoals : List TargetGoal :=
  targetGoals.filter (fun goal => goal.status.isViolation)

/-- No known loss both (a) is merely reportable and (b) justifies refusal.
Refusing on a reportable loss is the cursor-agent defect, stated as a check. -/
example : knownLosses.all (fun loss =>
    !(loss.impact == .reportable && loss.impact.justifiesRefusal)) = true := by
  native_decide

end Loom.Ops.Interop
