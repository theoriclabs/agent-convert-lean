import Loom
import LoomConvert.Parity
import LoomConvert.Hermes
import LoomConvert.CursorIde
import LoomOps.Conversion

/-!
# LoomConvert.CodexCli — Codex CLI import/export

Codex JSONL → Loom IR, in pure Lean, matching `utils/src/pi/codexAdapter.ts`
(`adaptCodex`) **including its just-fixed cross-channel dedup** (claim L2 /
defect D13). Scaffold copied from `LoomConvert.Pi`: `ostr`/`oobj` Json
accessors, an intermediate `RawEntry`-style record, a second-pass id→index
resolution (here: `call_id` → the tool-call entry, for `toolResult` linkage),
and `Origin` provenance per entry.

## The format (census-grounded, `Loom.Formats.CodexCli`)

Line 0 is the primary `session_meta` record (fields under `.payload`). A leading
prelude may contain ancestor headers; every header delimits a lifecycle/linkage
segment. The rest is a stream of `response_item` / `event_msg` / `turn_context` / `compacted`
records, each wrapping its real semantic type under `.payload.type`. Codex is
**linear by construction** — no `parentId` graph — so entries chain linearly:
each kept entry's parent is the previous kept entry's index (the first has
none). That is exactly how the pi IR renders a single linear thread.

## Inverse mapping (Codex → Loom), matching `adaptCodex`

* `session_meta`                         → `EnvInfo` (cwd, cli_version→
  harnessVersion, id→sessionId, instructions) + codex extras on the origin.
* `turn_context`                         → archived control provenance.
* `event_msg.task_started/…complete/token_count` → archived lifecycle provenance.
* `response_item.message` (role user)    → `Payload.userMsg` (text blocks).
* `response_item.message` (role assistant) → `Payload.assistantMsg`.
* `response_item.message` (system/developer/other control-plane role) → archived verbatim in
  `origin.extras.raw_control_messages`, never attributed to the user or model.
  Exact control-envelope blocks in a mixed user record are archived the same
  way while ordinary sibling blocks remain user-authored dialogue.
* `response_item.function_call`          → `.assistant` with one `AssistantBlock.toolCall`
  when all required fields parse; malformed calls remain exact assistant
  `unmodeled` blocks rather than being normalized into executable calls.
* `response_item.function_call_output`   → `Payload.envMsg [EnvBlock.toolResult …]`
  authored by the `environment`, `ErrorSignal.inferred` via `codexOutputIndicatesError`
  (`codexAdapter.ts:75`); logs an `ImportNote errorInferred`. The result's
  `CallRef` is resolved positionally to the earlier `function_call` entry.
* `response_item.reasoning`              → `.assistant` with one `AssistantBlock.thinking`
  (summary_text joined by "\n"), retaining encrypted content as the signature;
  encrypted/malformed summary-less records remain exact `unmodeled` blocks and
  content-free reasoning lifecycle records are archived outside dialogue.
* `event_msg.user_message` / `agent_message` → text message, **cross-channel
  deduped** (below); a drop logs `ImportNote dedupDropped`.
* Any unknown `response_item` kind → an assistant `unmodeled` block carrying
  the complete payload; any other `event_msg` kind → `MetaEvent.custom`
  carrying the complete payload. Open-world additions therefore remain
  inspectable and same-format exportable instead of falling through.

## Content deepening (S5+S6): content the text-only extractor dropped

All Loom-only enrichments — the TS toolchain drops these too — so they are
verified on `codexRichFixture`, never cross-parity-pinned (a pin against
the strictly-poorer TS oracle would correctly fail):

* `message` `input_image` blocks       → a `.media "image"` block retaining the
  complete locator, including an inlined `data:` URI, on the source role. Was
  dropped: an image-only message yielded zero blocks → skipped.
* `response_item.web_search_call` / `tool_search_call` → `.assistant` with one
  `AssistantBlock.toolCall` named for the payload type; `tool_search_output` →
  a linked environment-authored result whose content retains the verbatim
  payload. Were unhandled → invisible.
* `event_msg.error`                     → `Payload.event (MetaEvent.custom "error"
  raw)`. Was truly invisible: `error` has no response_item twin.

## The dedup (matches the D13 fix, `codexAdapter.ts:208-217, 280-288`)

Every text utterance is emitted on BOTH channels — a `response_item.message`
and a paired `event_msg.{user,agent}_message`, landing adjacent but role-
asymmetric (user: response_item→event_msg; assistant: event_msg→response_item).
The SECOND arrival is the display duplicate. We drop the current text utterance
iff it matches the previously-*kept* entry (same role + same joined text) AND
that previous entry came from the **other** channel. The channel guard is
load-bearing: it rescues genuine single-channel `event_msg`s and same-channel
repeats (two identical user `response_item.message`s) from collapsing. We track
`lastChannel` = the channel of the last *pushed* entry (skips/drops never touch
it), exactly like `lastEntryChannel` in the adapter.

## Well-formedness

For valid source lifecycles the IR is `WellFormed` (0 `violations`): linear
parents point strictly earlier, and resolved `toolResult` references point to
earlier calls. Source orphans remain explicit unresolved references.

## The tool-result row (former divergence, resolved at the projection layer)

Under the role-content-sum, `LoomConvert.Parity.normalize` projects an
`EnvBlock.toolResult` to its content text (`envBlockTag` → `userBlockTag`), and
the TS `parseSession` model flattens `function_call_output` to a `toolResult`-
role message carrying a `text` block that projects the same way. So the tool-
result row now matches TS **byte-for-byte** (`toolResult|text:<output>`); the
earlier `"result"`-projection divergence is gone. Loom is still strictly richer
than the TS flat model — it keeps the call linkage + inferred error the flat
model discards — and that enrichment is verified separately, exactly the L12
`thinkingSignature` Lean-only property class. Every row matches TS; both facts
are pinned.
-/

namespace LoomConvert
open Loom
open Lean (Json)

/-! ## Small Json accessors (Except → Option), copied from `Pi.lean`. -/

private def ostr (j : Json) (k : String) : Option String :=
  (j.getObjVal? k >>= Json.getStr?).toOption

private def oobj (j : Json) (k : String) : Option Json :=
  (j.getObjVal? k).toOption

private def oarr (j : Json) (k : String) : Option (Array Json) :=
  (j.getObjVal? k >>= Json.getArr?).toOption

private def obool (j : Json) (k : String) : Option Bool :=
  (j.getObjVal? k >>= Json.getBool?).toOption

private def nullableStringField? (j : Json) (k : String) : Option (Option String) :=
  match oobj j k with
  | some Json.null => some none
  | some (Json.str value) => some (some value)
  | _ => none

/-! ## Error inference — a faithful-enough port of `codexOutputIndicatesError`
(`codexAdapter.ts:75`). Codex carries no structured failure flag; error status
is *guessed* from the output text. The value feeds `ErrorSignal.inferred`; it is
invisible to `normalize`/`violations`, so exactness is not load-bearing, but the
heuristic is named so the guess stays auditable. Word boundaries (`\b`) are
approximated by substring; the exit-code check keeps the nonzero constraint. -/

private def lower (s : String) : String := String.ofList (s.toList.map Char.toLower)

private def hasSub (s sub : String) : Bool := decide ((s.splitOn sub).length > 1)

/-- True when text contains `Process exited with code N` with `N` nonzero. -/
private def exitedNonzero (out : String) : Bool :=
  ((out.splitOn "Process exited with code ").drop 1).any (fun part =>
    match part.toList.head? with
    | some c => decide (49 ≤ c.toNat ∧ c.toNat ≤ 57)   -- '1'..'9'
    | none => false)

def codexOutputIndicatesError (out : String) : Bool :=
  let lc := lower out
  exitedNonzero out
    || hasSub lc "timed out after"
    || hasSub lc "command timed out"
    || (hasSub lc "timeout" && (hasSub lc "exceeded" || hasSub lc "expired" || hasSub lc "limit"))

/-- Strict counterpart used by the loss-preserving importer. Missing fields,
wrong field types, and malformed JSON strings remain raw unmodeled records
instead of being normalized to `{}`. -/
private def parseArgsExact? (p : Json) : Option Json :=
  match oobj p "arguments" with
  | some (Json.str encoded) => do
      let parsed <- (Json.parse encoded).toOption
      match parsed with
      | value@(Json.obj _) => some value
      | _ => none
  | some value@(Json.obj _) => some value
  | _ => none

/-! ## Content-block deepening (S5+S6): images + previously-dropped kinds

Codex `input_image` content blocks and the search-family response items were
dropped by the text-only extractor. They are now modeled. TS drops them too, so
these are Loom-only enrichments (verified by `codexRichFixture`). -/

/-- The three Codex text content-block kinds (user `input_text`, model
`output_text`, legacy `text`), treated identically by both adapters. -/
private def isCodexTextType (bt : String) : Bool :=
  bt == "input_text" || bt == "output_text" || bt == "text"

/-- The event vocabulary observed through Codex 0.144. Used only by the
TS-parity input filter: known events may follow the reference converter's
documented drop, while a future event kind must continue into the open-world
fallback rather than disappearing before `adaptRecords` can preserve it. -/
private def isKnownCodexEventType : String -> Bool
  | "token_count" | "agent_message" | "exec_command_end"
  | "task_started" | "task_complete" | "patch_apply_end"
  | "user_message" | "guardian_assessment" | "thread_goal_updated"
  | "agent_reasoning" | "context_compacted" | "web_search_end"
  | "sub_agent_activity" | "turn_aborted" | "thread_settings_applied"
  | "thread_rolled_back" | "mcp_tool_call_end" | "view_image_tool_call"
  | "item_completed" | "error" | "thread_name_updated"
  | "collab_waiting_end" | "collab_agent_spawn_end"
  | "exited_review_mode" | "entered_review_mode" => true
  | _ => false

private def isSkippedCodexEventType (eventType : String) : Bool :=
  eventType == "task_started" || eventType == "task_complete" ||
    eventType == "token_count"

private def exactEnvelope (text opening closing : String) : Bool :=
  text.startsWith opening && text.endsWith closing

private def isCodexControlText (text : String) : Bool :=
  exactEnvelope text "<permissions instructions>" "</permissions instructions>" ||
  exactEnvelope text "<skills_instructions>" "</skills_instructions>" ||
  exactEnvelope text "<apps_instructions>" "</apps_instructions>" ||
  exactEnvelope text "<plugins_instructions>" "</plugins_instructions>" ||
  exactEnvelope text "<recommended_plugins>" "</recommended_plugins>" ||
  exactEnvelope text "<collaboration_mode>" "</collaboration_mode>" ||
  exactEnvelope text "<environment_context>" "</environment_context>"

private def isCodexControlBlock (block : Json) : Bool :=
  match ostr block "type", ostr block "text" with
  | some kind, some text => isCodexTextType kind && isCodexControlText text
  | _, _ => false

private def splitCodexUserContent
    (content : Array Json) : Array Json × Array Json :=
  content.foldl (fun (controls, dialogue) block =>
    if isCodexControlBlock block then (controls.push block, dialogue)
    else (controls, dialogue.push block)) (#[], #[])

/-- Only explicit user/model roles are dialogue. System, developer, and future
control-plane roles are archived rather than guessed into either authorship. -/
private def isCodexDialogueRole (role : String) : Bool :=
  role == "user" || role == "assistant"

private def isCodexControlEvent (eventType text : String) : Bool :=
  eventType == "user_message" &&
    isCodexControlText text

private def containsCodexControlEnvelope (text : String) : Bool :=
  (hasSub text "<permissions instructions>" && hasSub text "</permissions instructions>") ||
  (hasSub text "<skills_instructions>" && hasSub text "</skills_instructions>") ||
  (hasSub text "<apps_instructions>" && hasSub text "</apps_instructions>") ||
  (hasSub text "<plugins_instructions>" && hasSub text "</plugins_instructions>") ||
  (hasSub text "<recommended_plugins>" && hasSub text "</recommended_plugins>") ||
  (hasSub text "<collaboration_mode>" && hasSub text "</collaboration_mode>") ||
  (hasSub text "<environment_context>" && hasSub text "</environment_context>")

private def codexAllText (content : Array Json) : Option String := do
  let texts ← content.toList.mapM (fun block => do
    guard (isCodexTextType (← ostr block "type"))
    ostr block "text")
  pure (String.intercalate "" texts)

/-- A flattened user display event is a safe duplicate of a mixed structured
message only when the structured record proves both the exact full text and the
presence of separately delimited control blocks. -/
private def mixedUserResponseDisplayText? (record : Json) : Option String := do
  guard (ostr record "type" == some "response_item")
  let payload ← oobj record "payload"
  guard (ostr payload "type" == some "message")
  guard (ostr payload "role" == some "user")
  let content ← oarr payload "content"
  let split := splitCodexUserContent content
  guard (!split.1.isEmpty && !split.2.isEmpty)
  codexAllText content

/-- Codex 0.144.1 accepts prompt images from resumed response items through its
inline base64 data-URL path. Remote HTTP(S) URLs are rejected by the app-server,
and malformed data URLs are replaced with an omission placeholder by core image
preparation. Keep this deliberately narrower than an arbitrary nonempty string. -/
private def codexBase64Char (char : Char) : Bool :=
  ('A' <= char && char <= 'Z') || ('a' <= char && char <= 'z') ||
    ('0' <= char && char <= '9') || char == '+' || char == '/'

private def codexBase64PayloadValid (payload : String) : Bool :=
  let chars := payload.toList
  let body := chars.takeWhile (fun char => char != '=')
  let padding := chars.drop body.length
  !body.isEmpty && chars.length % 4 == 0 && body.all codexBase64Char &&
    padding.length <= 2 && padding.all (fun char => char == '=')

private def codexImagePayloadMatchesMime (mime payload : String) : Bool :=
  if mime == "data:image/png" then payload.startsWith "iVBORw0KGgo"
  else if mime == "data:image/jpeg" then payload.startsWith "/9j/"
  else if mime == "data:image/gif" then payload.startsWith "R0lGOD"
  else if mime == "data:image/webp" then payload.startsWith "UklGR"
  else false

def codexImageLocatorValid (locator : String) : Bool :=
  match locator.splitOn "," with
  | [metadata, payload] =>
      let parts := metadata.splitOn ";"
      let mime := lower (parts.headD "")
      let supportedMime := ["data:image/png", "data:image/jpeg",
        "data:image/gif", "data:image/webp"].contains mime
      supportedMime && (parts.drop 1).any (fun part => lower part == "base64") &&
        codexBase64PayloadValid payload && codexImagePayloadMatchesMime mime payload
  | _ => false

private def codexTinyPngDataUri : String :=
  "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2nAAAAABJRU5ErkJggg=="

private def codexDecoratedPngDataUri : String :=
  "DATA:image/png;charset=binary;BASE64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2nAAAAABJRU5ErkJggg=="

private def codexImageDetailValid (b : Json) : Bool :=
  match oobj b "detail" with
  | none | some Json.null => true
  | some (Json.str detail) =>
      detail == "auto" || detail == "high" || detail == "original"
  | _ => false

/-- A typed image requires the exact 0.144.1 content-item field domain. Keep a
valid locator byte-for-byte, including the complete data URI. -/
private def codexImageRef? (b : Json) : Option String := do
  let locator <- ostr b "image_url"
  guard (codexImageLocatorValid locator && codexImageDetailValid b)
  pure locator

private def codexMessageContentLabel : String := "codex.message_content"

/-- Ordered user-authored blocks for a `message` content array: text kinds →
`UserBlock.text`; a well-formed `input_image` → `UserBlock.media "image" <ref>`
(S5). Unknown or malformed items remain byte-for-byte in an `unmodeled` block. -/
private def codexUserBlocks (content : Array Json) : List UserBlock :=
  content.toList.map (fun (b : Json) =>
    match ostr b "type" with
    | some bt =>
        if isCodexTextType bt then
          match ostr b "text" with
          | some text => UserBlock.text text
          | none => UserBlock.unmodeled codexMessageContentLabel b
        else if bt == "input_image" then
          match codexImageRef? b with
          | some locator => UserBlock.media "image" locator
          | none => UserBlock.unmodeled codexMessageContentLabel b
        else UserBlock.unmodeled codexMessageContentLabel b
    | none => UserBlock.unmodeled codexMessageContentLabel b)

/-- Assistant twin of `codexUserBlocks`. -/
private def codexAssistantBlocks (content : Array Json) : List AssistantBlock :=
  content.toList.map (fun (b : Json) =>
    match ostr b "type" with
    | some bt =>
        if isCodexTextType bt then
          match ostr b "text" with
          | some text => AssistantBlock.text text
          | none => AssistantBlock.unmodeled codexMessageContentLabel b
        else if bt == "input_image" then
          match codexImageRef? b with
          | some locator => AssistantBlock.media "image" locator
          | none => AssistantBlock.unmodeled codexMessageContentLabel b
        else AssistantBlock.unmodeled codexMessageContentLabel b
    | none => AssistantBlock.unmodeled codexMessageContentLabel b)

private def codexToolOutputItem? (item : Json) : Option UserBlock := do
  match item with
  | .obj _ => pure ()
  | _ => none
  match ostr item "type" with
  | some kind =>
      if isCodexTextType kind then
        match ostr item "text" with
        | some text => pure (.text text)
        | none => none
      else if kind == "input_image" then
        match codexImageRef? item with
        | some locator => pure (.media "image" locator)
        | none => none
      else pure (.unmodeled kind item)
  | none => pure (.unmodeled "tool_output_item" item)

/-- Codex 0.144+ permits a string or an ordered array of response-content
objects. A wrong outer type, primitive member, or malformed recognized text/image
member makes the whole output record malformed, so the caller retains the
complete payload as inert environment data. Unknown object kinds remain exact
`unmodeled` blocks inside an otherwise valid output. -/
private def codexToolOutputBlocks? : Json -> Option (List UserBlock)
  | .str output => some [UserBlock.text output]
  | .arr items => items.toList.mapM codexToolOutputItem?
  | _ => none

private def toolOutputText (content : List UserBlock) : String :=
  String.intercalate "" (content.filterMap (fun block => match block with
    | .text text => some text
    | _ => none))

/-! ## Reversible historical carriers

Codex has no native record for a tool from another harness. Such calls and
results are assistant-visible history, but readable text alone is not an
inverse: importing it as prose loses the lifecycle. The exporter therefore
stamps both the session and containing message payload and embeds a versioned,
complete record. The stamps self-identify provenance; they are not
cryptographic authentication. Unstamped byte-identical text stays ordinary
prose, while a stamped malformed record is retained verbatim as `unmodeled`
rather than partly decoded. -/

def codexCarrierMarkerKey : String := "_agent_convert"

def codexCarrierProtocol : String := "agent-convert.codex-carriers.v1"

private def codexHistoricalToolCallCarrierV1 : String :=
  "agent-convert.codex-tool-call.v1"

private def codexHistoricalToolCallCarrierV2 : String :=
  "agent-convert.codex-tool-call.v2"

def codexSourceArchiveKey : String := "_agent_convert_source_archive"

private def codexTimeProvenanceKey : String := "_agent_convert_time"

/-- Canonical JSONL bytes emitted by this adapter. Escaping angle brackets is
transport-only: JSON decoding restores the exact source strings. -/
private def codexCanonicalJsonLine (json : Json) : String :=
  json.compress.replace "<" "\\u003c" |>.replace ">" "\\u003e"

private def codexCompactionRawRecordKey : String := "raw_compaction_record"

private def codexNativeToolRawRecordKey : String := "raw_native_tool_record"

private def codexSourceArchiveKind : String := "historical_source_provenance"

private def codexGeneratedTargetDefaultsKind : String :=
  "explicit_target_controls"

private def codexEntryTimeProvenanceKind : String :=
  "entry_time_provenance"

private def codexMarker (kind : String) : Json := Json.mkObj [
  ("protocol", Json.str codexCarrierProtocol), ("kind", Json.str kind)]

def codexTargetControlsKey : String := "target_codex_controls"

def codexTargetControlsProtocol : String :=
  "agent-convert.codex-target-controls.v1"

private structure CodexTargetControls where
  approvalPolicy : String
  sandboxPolicy : Json
  summary : String

private def codexApprovalPolicyValid (policy : String) : Bool :=
  ["untrusted", "on-failure", "on-request", "never"].contains policy

private def codexSummaryPolicyValid (summary : String) : Bool :=
  ["auto", "concise", "detailed", "none"].contains summary

/-- The currently emitted 0.144.1 sandbox shape. Every operational boolean is
explicit; omission would delegate behavior to an undocumented runtime default. -/
private def codexTargetSandboxPolicyValid (sandbox : Json) : Bool :=
  match ostr sandbox "type", obool sandbox "network_access",
      obool sandbox "exclude_tmpdir_env_var", obool sandbox "exclude_slash_tmp" with
  | some "workspace-write", some network, some excludeTmp, some excludeSlash =>
      sandbox == Json.mkObj [
        ("type", Json.str "workspace-write"),
        ("network_access", Json.bool network),
        ("exclude_tmpdir_env_var", Json.bool excludeTmp),
        ("exclude_slash_tmp", Json.bool excludeSlash)]
  | _, _, _, _ => false

private def codexTargetControlsJson (controls : CodexTargetControls) : Json :=
  Json.mkObj [
    ("protocol", Json.str codexTargetControlsProtocol),
    ("approval_policy", Json.str controls.approvalPolicy),
    ("sandbox_policy", controls.sandboxPolicy),
    ("summary", Json.str controls.summary)]

private def parseCodexTargetControls? (raw : Json) : Option CodexTargetControls := do
  guard (ostr raw "protocol" == some codexTargetControlsProtocol)
  let approvalPolicy ← ostr raw "approval_policy"
  let sandboxPolicy ← oobj raw "sandbox_policy"
  let summary ← ostr raw "summary"
  guard (codexApprovalPolicyValid approvalPolicy)
  guard (codexTargetSandboxPolicyValid sandboxPolicy)
  guard (codexSummaryPolicyValid summary)
  let controls := { approvalPolicy, sandboxPolicy, summary }
  guard (raw == codexTargetControlsJson controls)
  pure controls

private def codexTargetControlsRaw? (t : Transcript) : Option Json :=
  t.origin.extras >>= fun extras => oobj extras codexTargetControlsKey

private def codexTargetControls? (t : Transcript) : Option CodexTargetControls :=
  codexTargetControlsRaw? t >>= parseCodexTargetControls?

private structure CodexTimeProvenance where
  time : Time
  sourceTimestamp : Option String

/-- Codex requires a concrete timestamp on target records, but that timestamp
must not silently turn fabricated or missing source time into recorded fact.
This exact, exporter-owned extension lets our importer recover the source
`Time` state while Codex continues to consume the ordinary timestamp field. -/
private def codexTimeProvenanceJson? (time : Time)
    (sourceTimestamp : Option String) : Option Json :=
  let common := [
    ("protocol", Json.str codexCarrierProtocol),
    ("kind", Json.str codexEntryTimeProvenanceKind)]
  let sourceField := match sourceTimestamp with
    | some value => [("source_timestamp", Json.str value)]
    | none => []
  match time with
  | .recorded _ => none
  | .interpolated timestamp basis => some (Json.mkObj (common ++ [
      ("state", Json.str "interpolated"),
      ("ms", Json.num timestamp.ms),
      ("basis", Json.str basis)] ++ sourceField))
  | .sequenced ordinal => some (Json.mkObj (common ++ [
      ("state", Json.str "sequenced"),
      ("ordinal", Json.num ordinal)] ++ sourceField))
  | .absent => some (Json.mkObj (common ++ [
      ("state", Json.str "absent")] ++ sourceField))

private def parseCodexTimeProvenance? (record : Json) : Option CodexTimeProvenance := do
  let raw <- oobj record codexTimeProvenanceKey
  guard (ostr raw "protocol" == some codexCarrierProtocol)
  guard (ostr raw "kind" == some codexEntryTimeProvenanceKind)
  let sourceTimestamp := ostr raw "source_timestamp"
  let time <- match ostr raw "state" with
    | some "interpolated" => do
        let ms <- (raw.getObjVal? "ms" >>= Json.getNat?).toOption
        let basis <- ostr raw "basis"
        pure (Time.interpolated ⟨ms⟩ basis)
    | some "sequenced" => do
        let ordinal <- (raw.getObjVal? "ordinal" >>= Json.getNat?).toOption
        pure (Time.sequenced ordinal)
    | some "absent" => pure Time.absent
    | _ => none
  guard (codexTimeProvenanceJson? time sourceTimestamp == some raw)
  pure { time, sourceTimestamp }

/-- In an exporter-stamped session, presence of the reserved time field is a
claim that the complete record came from this adapter. Check both its exact
typed shape and its original canonical bytes before JSON duplicate keys can be
silently normalized into a different valid object. -/
private def codexTimeProvenanceSourceFailure?
    (sourceLine : String) (record : Json) : Option String :=
  if (oobj record codexTimeProvenanceKey).isNone then none
  else if (parseCodexTimeProvenance? record).isNone then
    some s!"reserved {codexTimeProvenanceKey} must be an exact {codexCarrierProtocol} entry_time_provenance object"
  else if sourceLine != codexCanonicalJsonLine record then
    some s!"reserved {codexTimeProvenanceKey} requires canonical exporter-owned JSON bytes"
  else none

private def codexOuterCarrierProtocolClaimed (record : Json) : Bool :=
  ostr record "type" == some "response_item" &&
    (oobj record "payload").any (fun payload =>
      (oobj payload codexCarrierMarkerKey).any (fun marker =>
        ostr marker "protocol" == some codexCarrierProtocol))

/-- Reserved record extensions are owned only by an exact session stamp.
Unstamped time lookalikes fail on first import so a later export cannot add the
stamp and retroactively authorize them. Stamped carrier envelopes additionally
require canonical whole-line bytes, catching duplicate outer members before
the JSON object representation can erase their lexical ambiguity. -/
private def codexReservedRecordSourceFailure?
    (carrierSessionSelfIdentified : Bool) (sourceLine : String)
    (record : Json) : Option String :=
  if (oobj record codexTimeProvenanceKey).isSome then
    if !carrierSessionSelfIdentified then
      some s!"reserved {codexTimeProvenanceKey} requires an exact exporter-owned session stamp"
    else codexTimeProvenanceSourceFailure? sourceLine record
  else if carrierSessionSelfIdentified &&
      codexOuterCarrierProtocolClaimed record &&
      sourceLine != codexCanonicalJsonLine record then
    some "exporter-owned Codex carrier envelope requires canonical JSONL bytes"
  else none

/-! ### Codex 0.144.1 compacted-record domain

The current rollout schema stores a compacted checkpoint as a six-field payload.
Its `replacement_history` is replayable Responses input and ends in a server-
issued `compaction` item whose `encrypted_content` is the opaque summary
signature. Loom's typed compaction can project only `message`; the complete
checkpoint therefore remains entry-scoped provenance and is reusable only when
the typed projection still agrees with it. -/

private def codexCompactionOnlyObjectKeys (j : Json) (allowed : List String) : Bool :=
  match j with
  | .obj fields => fields.all (fun key _ => allowed.contains key)
  | _ => false

private def codexCompactionOptionalNonemptyString
    (j : Json) (key : String) : Bool :=
  match oobj j key with
  | none | some Json.null => true
  | some (Json.str value) => !value.isEmpty
  | _ => false

private def codexCompactionMetadataValid (item : Json) : Bool :=
  match oobj item "internal_chat_message_metadata_passthrough" with
  | none | some Json.null => true
  | some metadata@(.obj _) =>
      codexCompactionOnlyObjectKeys metadata ["turn_id"] &&
        codexCompactionOptionalNonemptyString metadata "turn_id"
  | _ => false

private def codexCompactionContentItemValid (item : Json) : Bool :=
  match ostr item "type" with
  | some "input_text" | some "output_text" =>
      codexCompactionOnlyObjectKeys item ["type", "text"] &&
        (ostr item "text").isSome
  | some "input_image" =>
      codexCompactionOnlyObjectKeys item ["type", "image_url", "detail"] &&
        (ostr item "image_url").any (fun locator => !locator.isEmpty) &&
        (match oobj item "detail" with
         | none | some Json.null => true
         | some (Json.str detail) =>
             detail == "auto" || detail == "low" || detail == "high" ||
               detail == "original"
         | _ => false)
  | _ => false

private def codexCompactionMessageItemValid (item : Json) : Bool :=
  codexCompactionOnlyObjectKeys item ["type", "id", "role", "content", "phase",
    "internal_chat_message_metadata_passthrough"] &&
    ostr item "type" == some "message" &&
    (ostr item "role").any (fun role => !role.isEmpty) &&
    (oarr item "content").any (fun content =>
      content.all codexCompactionContentItemValid) &&
    codexCompactionOptionalNonemptyString item "id" &&
    (match oobj item "phase" with
     | none | some Json.null => true
     | some (Json.str phase) => phase == "commentary" || phase == "final_answer"
     | _ => false) &&
    codexCompactionMetadataValid item

private def codexCompactionSignatureItemValid (item : Json) : Bool :=
  codexCompactionOnlyObjectKeys item ["type", "id", "encrypted_content",
    "internal_chat_message_metadata_passthrough"] &&
    ostr item "type" == some "compaction" &&
    (ostr item "encrypted_content").any (fun signature => !signature.isEmpty) &&
    codexCompactionOptionalNonemptyString item "id" &&
    codexCompactionMetadataValid item

private def codexReplacementHistoryValid (history : Array Json) : Bool :=
  match history.toList.reverse with
  | [] => false
  | signature :: reversedMessages =>
      codexCompactionSignatureItemValid signature &&
        reversedMessages.all codexCompactionMessageItemValid

private def codexCompactedPayloadValid (payload : Json) : Bool :=
  codexCompactionOnlyObjectKeys payload ["message", "replacement_history",
    "window_number", "first_window_id", "previous_window_id", "window_id"] &&
    (ostr payload "message").isSome &&
    (oarr payload "replacement_history").any codexReplacementHistoryValid &&
    (payload.getObjVal? "window_number" >>= Json.getNat?).toOption.any (· > 0) &&
    ["first_window_id", "previous_window_id", "window_id"].all (fun key =>
      (ostr payload key).any (fun value => !value.isEmpty))

private def codexCompactedRecordValid (record : Json) : Bool :=
  codexCompactionOnlyObjectKeys record
      ["timestamp", "type", "payload", codexTimeProvenanceKey] &&
    ostr record "type" == some "compacted" &&
    (ostr record "timestamp" >>= iso8601ToEpochMs?).isSome &&
    (oobj record "payload").any codexCompactedPayloadValid &&
    (match oobj record codexTimeProvenanceKey with
     | none => true
     | some _ => (parseCodexTimeProvenance? record).isSome)

private def codexGeneratedTargetDefaultsMarkerExact (payload : Json) : Bool :=
  oobj payload codexCarrierMarkerKey ==
    some (codexMarker codexGeneratedTargetDefaultsKind)

private def codexSourceIdentityJson (payload : Json) : Json :=
  let keys := ["id", "session_id", "parent_thread_id", "forked_from_id",
    "thread_source", "source"]
  Json.mkObj (keys.filterMap (fun key => (oobj payload key).map (key, ·)))

private def codexOptionalStringJson : Option String -> Json
  | some value => Json.str value
  | none => Json.null

private def codexSourceEnvJson (env : EnvInfo) : Json := Json.mkObj [
  ("cwd", codexOptionalStringJson env.cwd),
  ("model", codexOptionalStringJson env.model),
  ("provider", codexOptionalStringJson env.provider),
  ("harnessVersion", codexOptionalStringJson env.harnessVersion),
  ("instructions", codexOptionalStringJson env.instructions),
  ("sessionId", codexOptionalStringJson env.sessionId)]

private def codexSourceEnvString? (raw : Json) (key : String) : Option (Option String) :=
  match oobj raw key with
  | some Json.null => some none
  | some (Json.str value) => some (some value)
  | _ => none

private def parseCodexSourceEnv? (raw : Json) : Option EnvInfo := do
  let env : EnvInfo := {
    cwd := ← codexSourceEnvString? raw "cwd"
    model := ← codexSourceEnvString? raw "model"
    provider := ← codexSourceEnvString? raw "provider"
    harnessVersion := ← codexSourceEnvString? raw "harnessVersion"
    instructions := ← codexSourceEnvString? raw "instructions"
    sessionId := ← codexSourceEnvString? raw "sessionId" }
  guard (raw == codexSourceEnvJson env)
  pure env

private structure CodexSourceArchive where
  sourceSessionPayload : Json
  sourceIdentity : Json
  sourceEnv : EnvInfo
  sourceControls : Array Json
  generatedTargetControls : Array Json

private def codexSourceArchiveJson (archive : CodexSourceArchive) : Json :=
  Json.mkObj [
    ("protocol", Json.str codexCarrierProtocol),
    ("kind", Json.str codexSourceArchiveKind),
    ("source_session_payload", archive.sourceSessionPayload),
    ("source_identity", archive.sourceIdentity),
    ("source_env", codexSourceEnvJson archive.sourceEnv),
    ("source_control_records", Json.arr archive.sourceControls),
    ("generated_target_control_records", Json.arr archive.generatedTargetControls)]

/-- Decode only the exact exporter-owned metadata shape. Its contents remain
historical provenance; they are never replayed as active control records. -/
private def parseCodexSourceArchive? (sessionPayload : Json) : Option CodexSourceArchive := do
  let raw <- oobj sessionPayload codexSourceArchiveKey
  guard (ostr raw "protocol" == some codexCarrierProtocol)
  guard (ostr raw "kind" == some codexSourceArchiveKind)
  let sourceSessionPayload <- oobj raw "source_session_payload"
  match sourceSessionPayload with
  | .obj _ => pure ()
  | _ => none
  let sourceIdentity <- oobj raw "source_identity"
  match sourceIdentity with
  | .obj _ => pure ()
  | _ => none
  let sourceEnv <- oobj raw "source_env" >>= parseCodexSourceEnv?
  let sourceControls <- oarr raw "source_control_records"
  let generatedTargetControls <- oarr raw "generated_target_control_records"
  guard (sourceIdentity == codexSourceIdentityJson sourceSessionPayload)
  let archive := {
    sourceSessionPayload, sourceIdentity, sourceEnv, sourceControls,
    generatedTargetControls }
  guard (raw == codexSourceArchiveJson archive)
  pure archive

def codexHistoricalToolCallCarrierHeader : String :=
  "[Historical tool call from source transcript; not executed by Codex]"

def codexHistoricalToolResultCarrierHeader : String :=
  "[Historical tool result from source transcript; not executed by Codex]"

def codexHistoricalUnmodeledCarrierHeader : String :=
  "[Historical unmodeled response item from source transcript; not executed by Codex]"

def codexHistoricalEnvUnmodeledCarrierHeader : String :=
  "[Historical unmodeled environment item from source transcript; not executed by Codex]"

def codexHistoricalSessionBoundaryCarrierHeader : String :=
  "[Historical Codex session boundary; inert metadata, not executed by Codex]"

def codexHistoricalEntryCarrierHeader : String :=
  "[Historical entry from source transcript; not executed by Codex]"

/-- This is a self-identification stamp, not authentication: an input can copy
it. Requiring both the session and item stamps prevents accidental prose or an
isolated extension field from activating the carrier decoder. -/
private def codexCarrierSessionSelfIdentified (sessionPayload : Json) : Bool :=
  oobj sessionPayload codexCarrierMarkerKey == some (Json.mkObj [
    ("protocol", Json.str codexCarrierProtocol), ("kind", Json.str "session")])

private def codexOccurrence (entry block : Nat) : String := s!"{entry}:{block}"

/-- Native ids and exporter-assigned occurrences occupy disjoint namespaces,
so an adversarial raw id cannot alias an occurrence-addressed carrier. -/
private inductive CodexCallKey where
  | rawId (segment : Nat) (id : String)
  | occurrence (segment : Nat) (key : String)
  deriving DecidableEq

/-- How a result asks the second pass to recover its call. Historical orphan
notes are explicit so re-import does not replace source provenance with a
generic linker diagnostic. -/
private inductive CodexToolLink where
  | byId (segment : Nat) (id : String)
  | byOccurrence (segment : Nat) (occurrence : String) (rawId : Option String)
  | unresolved (rawId : Option String) (note : String)

/-! ## The dedup fold -/

/-- Deferred payload: tool results carry a raw `call_id` that is resolved to a
positional `CallRef` only after the whole kept list (hence its indices) is
known. Everything else is already a finished message — role-typed under the
role-content-sum, so user and assistant messages carry their own block lists
(`kuser`/`kassistant`); Codex never authors `otherMsg`. `kevent` carries a harness
meta event (`event_msg.error`), the one non-message entry the fold can emit. -/
private inductive KPayload where
  | kuser (blocks : List UserBlock)
  | kassistant (blocks : List AssistantBlock)
  | kenv (blocks : List EnvBlock)
  | ktool (link : CodexToolLink) (content : List UserBlock) (err : ErrorSignal)
      (nativeRaw : Option (String × Json))
  | kcompaction (summary : String)
  | kevent (e : MetaEvent)
  | khistorical (payload : Payload)

/-- One kept entry, plus the scraps the second pass needs: `role`/`text` for the
dedup comparison against the *next* utterance, and a disjoint `callKey` (set for
tool-call entries) so a later native output or historical result can find it. -/
private structure Kept where
  kpayload : KPayload
  ts       : Option String
  timeProvenance : Option CodexTimeProvenance := none
  role     : Role
  text     : String
  callKey  : Option CodexCallKey
  /-- Did this tool result come from `function_call_output` (envelope-eligible —
  codex.ts's convert path unwraps its exec envelope) rather than
  `custom_tool_call_output` (apply_patch etc., kept RAW by BOTH TS paths)? Both land
  as `EnvBlock.toolResult`, so this flag lets `codexTsParity` unwrap ONLY the former. -/
  envelopeEligible : Bool := false
  /-- Exact protocol carriers decode into useful typed syntax for inspection,
  but that syntax is historical and can never become executable on re-export. -/
  historicalCarrier : Bool := false
  /-- Exact native reasoning payload, reused only while its typed projection is
  unchanged. This preserves encrypted content and adjacent native fields. -/
  nativeReasoningRaw : Option Json := none
  /-- Exact 0.144.1 checkpoint record. The typed payload projects only its
  summary; replacement history, signature, and window provenance stay here. -/
  nativeCompactionRaw : Option Json := none
  /-- Exact native call/output response record. Export may reuse it only while
  target provenance, typed projection, and linked lifecycle all still agree. -/
  nativeToolRaw : Option Json := none

/-- Build an `ImportNote` carrying a record-index locator. -/
private def mkNote (k : AssumptionKind) (i : Nat) (d : String) : ImportNote :=
  { kind := k, loc := some ("record" ++ toString i), detail := d }

/-- Build a `Kept` entry (keeps every push-site in the fold single-line). -/
private def mkKept (kp : KPayload) (ts : Option String) (role : Role)
    (text : String) (callKey : Option CodexCallKey) : Kept :=
  { kpayload := kp, ts := ts, role := role, text := text, callKey := callKey }

private def parseCodexHistoricalUserBlock? (j : Json) : Option UserBlock := do
  match ← ostr j "kind" with
  | "text" => pure (.text (← ostr j "text"))
  | "media" => pure (.media (← ostr j "mimeType") (← ostr j "locator"))
  | "unmodeled" => pure (.unmodeled (← ostr j "label") (← oobj j "raw"))
  | _ => none

private def historicalResultBlockJson : UserBlock -> Json
  | .text text => Json.mkObj [("kind", Json.str "text"), ("text", Json.str text)]
  | .media mime locator => Json.mkObj [
      ("kind", Json.str "media"), ("mimeType", Json.str mime),
      ("locator", Json.str locator)]
  | .unmodeled label raw => Json.mkObj [
      ("kind", Json.str "unmodeled"), ("label", Json.str label), ("raw", raw)]

private def parseCodexErrorSignal? (j : Json) : Option ErrorSignal := do
  match ← ostr j "kind" with
  | "native" => pure (.native (← obool j "isError"))
  | "inferred" => pure (.inferred (← obool j "isError") (← ostr j "heuristic"))
  | "unrecorded" => pure .unrecorded
  | _ => none

private def errorSignalJson : ErrorSignal → Json
  | .native value => Json.mkObj [
      ("kind", Json.str "native"), ("isError", Json.bool value)]
  | .inferred value heuristic => Json.mkObj [
      ("kind", Json.str "inferred"), ("isError", Json.bool value),
      ("heuristic", Json.str heuristic)]
  | .unrecorded => Json.mkObj [("kind", Json.str "unrecorded")]

private def codexHistoricalOptionalString : Option String -> Json
  | some value => Json.str value
  | none => Json.null

private def codexHistoricalNullableNat? (j : Json) (key : String) : Option (Option Nat) :=
  match oobj j key with
  | some Json.null => some none
  | some value => (Json.getNat? value).toOption.map some
  | none => none

private def codexHistoricalCanonicalTool : CanonicalTool -> String
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

private def parseCodexHistoricalCanonicalTool? : String -> Option CanonicalTool
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

private def codexToolCanonicalKind : String := "tool_canonical"

/-- The out-of-band slot for `ToolName.canonical` on a NATIVE Codex call.

Codex's `function_call` holds exactly `{name, call_id, arguments}`; a canonical
tool identity has no place inside it. Forcing such a call to the prose carrier
kept the field but threw away the target's own construct — the loss this whole
adapter exists to avoid. `LoomOps.Interop.Emission.envelopePreserved` keeps
both: the record stays an executable `function_call` and the interpretation
rides in the reserved `_agent_convert` member Codex itself ignores, which
`codexPayloadToolCanonical?` reads back verbatim.

The member is added only when a canonical identity exists. Codex's own importer
never produces one, so a codex → codex trip emits no member and the record is
unchanged — which is what keeps `exactImportedNativeCallEvidence?` byte-exact. -/
private def codexToolCanonicalMarker (canonical : CanonicalTool) : Json :=
  Json.mkObj [
    ("protocol", Json.str codexCarrierProtocol),
    ("kind", Json.str codexToolCanonicalKind),
    ("canonical", Json.str (codexHistoricalCanonicalTool canonical))]

private def codexToolCanonicalFields
    (canonical : Option CanonicalTool) : List (String × Json) :=
  match canonical with
  | some tool => [(codexCarrierMarkerKey, codexToolCanonicalMarker tool)]
  | none => []

private def codexPayloadToolCanonical? (payload : Json) : Option CanonicalTool := do
  let marker ← oobj payload codexCarrierMarkerKey
  guard (ostr marker "protocol" == some codexCarrierProtocol)
  guard (ostr marker "kind" == some codexToolCanonicalKind)
  guard (marker == codexToolCanonicalMarker
    (← parseCodexHistoricalCanonicalTool? (← ostr marker "canonical")))
  parseCodexHistoricalCanonicalTool? (← ostr marker "canonical")

private def codexUnrecordedErrorKind : String := "tool_result_unrecorded"

/-- The out-of-band slot for `ErrorSignal.unrecorded` on a NATIVE Codex result.

`function_call_output` has no error field of any kind, so Codex's importer
re-derives the flag from the output text and every result comes back
`.inferred`. For `.native b` and `.inferred b` that is a pure PROVENANCE
normalization: the value is real and is preserved, which `LoomOps.Interop`
rates reportable. `.unrecorded` is not that. It says the source never recorded
whether the tool failed, and re-deriving `false` from the output text replaces
"nobody knows" with a value nobody asserted — the same class as writing
`is_error: false` into Claude for an unrecorded result, which this project
already classifies `corrupting` and fixed there by omission.

Codex has no omission to exploit — absence IS the wire state — so the fact
travels in the reserved `_agent_convert` member instead and the record stays an
executable `function_call_output`. Written only for `.unrecorded`, so results
that carry a real value emit exactly the bytes they emitted before. -/
private def codexUnrecordedErrorMarker : Json :=
  Json.mkObj [
    ("protocol", Json.str codexCarrierProtocol),
    ("kind", Json.str codexUnrecordedErrorKind)]

private def codexResultErrorFields : ErrorSignal → List (String × Json)
  | .unrecorded => [(codexCarrierMarkerKey, codexUnrecordedErrorMarker)]
  | _ => []

private def codexPayloadErrorIsUnrecorded (payload : Json) : Bool :=
  oobj payload codexCarrierMarkerKey == some codexUnrecordedErrorMarker

private def codexHistoricalAssistantBlockJson : AssistantBlock -> Json
  | .text text => Json.mkObj [
      ("kind", Json.str "text"), ("text", Json.str text)]
  | .thinking thinking signature => Json.mkObj [
      ("kind", Json.str "thinking"), ("thinking", Json.str thinking),
      ("signature", codexHistoricalOptionalString signature)]
  | .toolCall name arguments rawId => Json.mkObj [
      ("kind", Json.str "toolCall"), ("name", Json.str name.raw),
      ("canonical", name.canonical.map (fun canonical =>
        Json.str (codexHistoricalCanonicalTool canonical)) |>.getD Json.null),
      ("arguments", arguments),
      ("rawId", codexHistoricalOptionalString rawId)]
  | .media mime locator => Json.mkObj [
      ("kind", Json.str "media"), ("mimeType", Json.str mime),
      ("locator", Json.str locator)]
  | .unmodeled label raw => Json.mkObj [
      ("kind", Json.str "unmodeled"), ("label", Json.str label),
      ("raw", raw)]

private def parseCodexHistoricalAssistantBlock? (j : Json) : Option AssistantBlock := do
  match ← ostr j "kind" with
  | "text" => pure (.text (← ostr j "text"))
  | "thinking" =>
      pure (.thinking (← ostr j "thinking") (← nullableStringField? j "signature"))
  | "toolCall" =>
      let canonicalText ← nullableStringField? j "canonical"
      let canonical ← canonicalText.mapM parseCodexHistoricalCanonicalTool?
      pure (.toolCall { raw := (← ostr j "name"), canonical }
        (← oobj j "arguments") (← nullableStringField? j "rawId"))
  | "media" => pure (.media (← ostr j "mimeType") (← ostr j "locator"))
  | "unmodeled" => pure (.unmodeled (← ostr j "label") (← oobj j "raw"))
  | _ => none

private def codexHistoricalCallRefJson : CallRef -> Json
  | .resolved entry block => Json.mkObj [
      ("kind", Json.str "resolved"), ("entry", Json.num entry),
      ("block", Json.num block)]
  | .unresolved rawId note => Json.mkObj [
      ("kind", Json.str "unresolved"),
      ("rawId", codexHistoricalOptionalString rawId),
      ("note", Json.str note)]

private def parseCodexHistoricalCallRef? (j : Json) : Option CallRef := do
  match ← ostr j "kind" with
  | "resolved" =>
      let entry ← (j.getObjVal? "entry" >>= Json.getNat?).toOption
      let block ← (j.getObjVal? "block" >>= Json.getNat?).toOption
      pure (.resolved entry block)
  | "unresolved" =>
      pure (.unresolved (← nullableStringField? j "rawId") (← ostr j "note"))
  | _ => none

private def codexHistoricalEnvBlockJson : EnvBlock -> Json
  | .toolResult call content error => Json.mkObj [
      ("kind", Json.str "toolResult"),
      ("call", codexHistoricalCallRefJson call),
      ("content", Json.arr (content.map historicalResultBlockJson).toArray),
      ("error", errorSignalJson error)]
  | .unmodeled label raw => Json.mkObj [
      ("kind", Json.str "unmodeled"), ("label", Json.str label),
      ("raw", raw)]

private def parseCodexHistoricalEnvBlock? (j : Json) : Option EnvBlock := do
  match ← ostr j "kind" with
  | "toolResult" =>
      let content ← oarr j "content"
      pure (.toolResult (← oobj j "call" >>= parseCodexHistoricalCallRef?)
        (← content.toList.mapM parseCodexHistoricalUserBlock?)
        (← oobj j "error" >>= parseCodexErrorSignal?))
  | "unmodeled" => pure (.unmodeled (← ostr j "label") (← oobj j "raw"))
  | _ => none

private def codexHistoricalCoverageJson : CompactionCoverage -> Json
  | .knownPrefix firstKept => Json.mkObj [
      ("kind", Json.str "knownPrefix"), ("firstKept", Json.num firstKept)]
  | .unknownPrefix => Json.mkObj [("kind", Json.str "unknownPrefix")]

private def parseCodexHistoricalCoverage? (j : Json) : Option CompactionCoverage := do
  match ← ostr j "kind" with
  | "knownPrefix" =>
      pure (.knownPrefix (← (j.getObjVal? "firstKept" >>= Json.getNat?).toOption))
  | "unknownPrefix" => pure .unknownPrefix
  | _ => none

private def codexHistoricalMetaEventJson : MetaEvent -> Json
  | .modelChange previous next => Json.mkObj [
      ("kind", Json.str "modelChange"),
      ("previous", codexHistoricalOptionalString previous),
      ("next", codexHistoricalOptionalString next)]
  | .thinkingLevelChange previous next => Json.mkObj [
      ("kind", Json.str "thinkingLevelChange"),
      ("previous", codexHistoricalOptionalString previous),
      ("next", codexHistoricalOptionalString next)]
  | .permissionMode mode => Json.mkObj [
      ("kind", Json.str "permissionMode"), ("mode", Json.str mode)]
  | .branchSummary summary => Json.mkObj [
      ("kind", Json.str "branchSummary"), ("summary", Json.str summary)]
  | .custom label raw => Json.mkObj [
      ("kind", Json.str "custom"), ("label", Json.str label), ("raw", raw)]

private def parseCodexHistoricalMetaEvent? (j : Json) : Option MetaEvent := do
  match ← ostr j "kind" with
  | "modelChange" => pure (.modelChange
      (← nullableStringField? j "previous") (← nullableStringField? j "next"))
  | "thinkingLevelChange" => pure (.thinkingLevelChange
      (← nullableStringField? j "previous") (← nullableStringField? j "next"))
  | "permissionMode" => pure (.permissionMode (← ostr j "mode"))
  | "branchSummary" => pure (.branchSummary (← ostr j "summary"))
  | "custom" => pure (.custom (← ostr j "label") (← oobj j "raw"))
  | _ => none

private def codexHistoricalPayloadJson : Payload -> Json
  | .userMsg blocks => Json.mkObj [
      ("kind", Json.str "userMsg"),
      ("blocks", Json.arr (blocks.map historicalResultBlockJson).toArray)]
  | .assistantMsg blocks => Json.mkObj [
      ("kind", Json.str "assistantMsg"),
      ("blocks", Json.arr (blocks.map codexHistoricalAssistantBlockJson).toArray)]
  | .envMsg blocks => Json.mkObj [
      ("kind", Json.str "envMsg"),
      ("blocks", Json.arr (blocks.map codexHistoricalEnvBlockJson).toArray)]
  | .otherMsg role blocks => Json.mkObj [
      ("kind", Json.str "otherMsg"), ("role", Json.str role),
      ("blocks", Json.arr (blocks.map historicalResultBlockJson).toArray)]
  | .compaction summary coverage tokensBefore => Json.mkObj [
      ("kind", Json.str "compaction"), ("summary", Json.str summary),
      ("coverage", codexHistoricalCoverageJson coverage),
      ("tokensBefore", tokensBefore.map Json.num |>.getD Json.null)]
  | .event event => Json.mkObj [
      ("kind", Json.str "event"),
      ("event", codexHistoricalMetaEventJson event)]

private def parseCodexHistoricalPayload? (j : Json) : Option Payload := do
  match ← ostr j "kind" with
  | "userMsg" =>
      let blocks ← oarr j "blocks"
      pure (.userMsg (← blocks.toList.mapM parseCodexHistoricalUserBlock?))
  | "assistantMsg" =>
      let blocks ← oarr j "blocks"
      pure (.assistantMsg (← blocks.toList.mapM parseCodexHistoricalAssistantBlock?))
  | "envMsg" =>
      let blocks ← oarr j "blocks"
      pure (.envMsg (← blocks.toList.mapM parseCodexHistoricalEnvBlock?))
  | "otherMsg" =>
      let blocks ← oarr j "blocks"
      pure (.otherMsg (← ostr j "role")
        (← blocks.toList.mapM parseCodexHistoricalUserBlock?))
  | "compaction" =>
      pure (.compaction (← ostr j "summary")
        (← oobj j "coverage" >>= parseCodexHistoricalCoverage?)
        (← codexHistoricalNullableNat? j "tokensBefore"))
  | "event" => pure (.event (← oobj j "event" >>= parseCodexHistoricalMetaEvent?))
  | _ => none

private def errorSignalBoolJson : ErrorSignal → Json
  | .native value | .inferred value _ => Json.bool value
  | .unrecorded => Json.null

private def errorSignalProvenance : ErrorSignal → String
  | .native _ => "native"
  | .inferred _ heuristic => "inferred: " ++ heuristic
  | .unrecorded => "unrecorded"

private def codexHistoricalToolCallReason : String :=
  "source lifecycle is not losslessly executable in Codex"

private def codexHistoricalUnmodeledReason : String :=
  "raw discriminator is not authorized as a native Codex call"

private def codexHistoricalEnvUnmodeledReason : String :=
  "environment payload has no native lossless Codex record"

private def codexHistoricalSessionBoundaryReason : String :=
  "source session boundary preserves a disjoint call-id namespace"

private def codexHistoricalEntryReason : String :=
  "typed historical-unverified disposition forbids native Codex replay"

private structure CodexSessionBoundary where
  beforeEntry : Nat
  record : Json

private def codexSessionBoundaryJson (boundary : CodexSessionBoundary) : Json :=
  Json.mkObj [
    ("before_entry", Json.num boundary.beforeEntry),
    ("record", boundary.record)]

private def codexSessionBoundaryRecordValid (record : Json) : Bool :=
  match record, oobj record "payload" with
  | .obj _, some (.obj _) => ostr record "type" == some "session_meta"
  | _, _ => false

private def parseCodexSessionBoundary? (raw : Json) : Option CodexSessionBoundary := do
  let beforeEntry <- (raw.getObjVal? "before_entry" >>= Json.getNat?).toOption
  let record <- oobj raw "record"
  guard (codexSessionBoundaryRecordValid record)
  let boundary := { beforeEntry, record }
  guard (raw == codexSessionBoundaryJson boundary)
  pure boundary

private inductive CodexHistoricalCarrier where
  | call (block : AssistantBlock) (occurrence : String) (displayText : String)
  | result (link : CodexToolLink) (content : List UserBlock)
      (error : ErrorSignal) (displayText : String)
  | unmodeled (label : String) (raw : Json) (displayText : String)
  | envUnmodeled (label : String) (raw : Json) (displayText : String)
  | entry (payload : Payload) (displayText : String)
  | sessionBoundary (record : Json)

private def codexCarrierMarkerPresent (payload : Json) : Bool :=
  (oobj payload codexCarrierMarkerKey).isSome

private def codexCarrierKind? (payload : Json) : Option String := do
  let marker ← oobj payload codexCarrierMarkerKey
  guard (ostr marker "protocol" == some codexCarrierProtocol)
  ostr marker "kind"

private def codexCarrierMarkerExact (payload : Json) (kind : String) : Bool :=
  oobj payload codexCarrierMarkerKey == some (Json.mkObj [
    ("protocol", Json.str codexCarrierProtocol), ("kind", Json.str kind)])

private def codexCarrierMessageText? (payload : Json) : Option String := do
  guard (ostr payload "type" == some "message")
  guard (ostr payload "role" == some "assistant")
  let content ← oarr payload "content"
  guard (content.size == 1)
  let block ← content[0]?
  guard (isCodexTextType (← ostr block "type"))
  ostr block "text"

private def codexCarrierPayloadExact (payload : Json) (kind text : String) : Bool :=
  payload == Json.mkObj [
    ("type", Json.str "message"),
    ("role", Json.str "assistant"),
    (codexCarrierMarkerKey, Json.mkObj [
      ("protocol", Json.str codexCarrierProtocol), ("kind", Json.str kind)]),
    ("content", Json.arr #[Json.mkObj [
      ("type", Json.str "output_text"), ("text", Json.str text)]])]

private def codexHistoricalToolCallV1Json (occurrence : String)
    (rawId : Option String) (rawName : String) (args : Json) : Json :=
  Json.mkObj [
    ("carrier", Json.str codexHistoricalToolCallCarrierV1),
    ("occurrence", Json.str occurrence),
    ("id", rawId.map Json.str |>.getD Json.null),
    ("name", Json.str rawName),
    ("arguments", args),
    ("reason", Json.str codexHistoricalToolCallReason)]

private def codexHistoricalToolCallV2Json (occurrence : String)
    (rawId : Option String) (name : ToolName) (args : Json) : Json :=
  Json.mkObj [
    ("carrier", Json.str codexHistoricalToolCallCarrierV2),
    ("occurrence", Json.str occurrence),
    ("id", rawId.map Json.str |>.getD Json.null),
    ("name", Json.str name.raw),
    ("canonical", name.canonical.map (fun canonical =>
      Json.str (codexHistoricalCanonicalTool canonical)) |>.getD Json.null),
    ("arguments", args),
    ("reason", Json.str codexHistoricalToolCallReason)]

private def parseCodexCarrierCallLink? (call : Json) (segment : Nat) :
    Option (CodexToolLink × Json) := do
  let callRawId ← nullableStringField? call "rawId"
  let kind ← ostr call "kind"
  if kind == "resolved" then
    let occurrence ← ostr call "occurrence"
    guard (!occurrence.isEmpty)
    pure ((CodexToolLink.byOccurrence segment occurrence callRawId), Json.mkObj [
      ("kind", Json.str "resolved"), ("occurrence", Json.str occurrence),
      ("rawId", callRawId.map Json.str |>.getD Json.null)])
  else if kind == "unresolved" then
    let note ← ostr call "note"
    pure ((CodexToolLink.unresolved callRawId note), Json.mkObj [
      ("kind", Json.str "unresolved"),
      ("rawId", callRawId.map Json.str |>.getD Json.null),
      ("note", Json.str note)])
  else none

private def parseCodexHistoricalCarrier? (payload : Json) (segment : Nat) :
    Option CodexHistoricalCarrier := do
  let kind ← codexCarrierKind? payload
  guard (codexCarrierMarkerExact payload kind)
  let text ← codexCarrierMessageText? payload
  guard (codexCarrierPayloadExact payload kind text)
  if kind == "tool_call" then
    let encoded ← text.dropPrefix? (codexHistoricalToolCallCarrierHeader ++ "\n")
    let record ← (Json.parse encoded.toString).toOption
    let carrier ← ostr record "carrier"
    let occurrence ← ostr record "occurrence"
    guard (!occurrence.isEmpty)
    let rawId ← nullableStringField? record "id"
    let rawName ← ostr record "name"
    let args ← oobj record "arguments"
    guard (ostr record "reason" == some codexHistoricalToolCallReason)
    let canonical ←
      if carrier == codexHistoricalToolCallCarrierV1 then
        let expected := codexHistoricalToolCallV1Json occurrence rawId rawName args
        guard (record == expected)
        guard (encoded.toString == expected.compress)
        pure (none : Option CanonicalTool)
      else if carrier == codexHistoricalToolCallCarrierV2 then
        let canonicalText ← nullableStringField? record "canonical"
        let canonical ← canonicalText.mapM parseCodexHistoricalCanonicalTool?
        let name : ToolName := { raw := rawName, canonical }
        let expected := codexHistoricalToolCallV2Json occurrence rawId name args
        guard (record == expected)
        -- `Json.parse` collapses duplicate object keys. The carrier is emitted in
        -- canonical compact form, so exact source bytes are the authority needed
        -- to reject contradictory lexical fields before they can normalize away.
        guard (encoded.toString == expected.compress)
        pure canonical
      else none
    pure (.call (.toolCall { raw := rawName, canonical } args rawId)
      occurrence text)
  else if kind == "tool_result" then
    let encoded ← text.dropPrefix? (codexHistoricalToolResultCarrierHeader ++ "\n")
    let record ← (Json.parse encoded.toString).toOption
    guard (ostr record "carrier" == some "agent-convert.codex-tool-result.v1")
    let resultOccurrence ← ostr record "occurrence"
    guard (!resultOccurrence.isEmpty)
    let recordRawId ← nullableStringField? record "id"
    let call ← oobj record "call"
    let callRawId ← nullableStringField? call "rawId"
    guard (recordRawId == callRawId)
    let (link, expectedCall) ← parseCodexCarrierCallLink? call segment
    let encodedContent ← oarr record "content"
    let content ← encodedContent.toList.mapM parseCodexHistoricalUserBlock?
    let error ← oobj record "error" >>= parseCodexErrorSignal?
    guard (oobj record "output" == some (Json.str (toolOutputText content)))
    guard (oobj record "isError" == some (errorSignalBoolJson error))
    guard (ostr record "errorProvenance" == some (errorSignalProvenance error))
    let expected := Json.mkObj [
      ("carrier", Json.str "agent-convert.codex-tool-result.v1"),
      ("occurrence", Json.str resultOccurrence),
      ("id", recordRawId.map Json.str |>.getD Json.null),
      ("call", expectedCall),
      ("output", Json.str (toolOutputText content)),
      ("content", Json.arr (content.map historicalResultBlockJson).toArray),
      ("isError", errorSignalBoolJson error),
      ("error", errorSignalJson error),
      ("errorProvenance", Json.str (errorSignalProvenance error))]
    guard (record == expected)
    guard (encoded.toString == expected.compress)
    pure (.result link content error text)
  else if kind == "unmodeled" then
    let encoded ← text.dropPrefix? (codexHistoricalUnmodeledCarrierHeader ++ "\n")
    let record ← (Json.parse encoded.toString).toOption
    guard (ostr record "carrier" == some "agent-convert.codex-unmodeled.v1")
    let occurrence ← ostr record "occurrence"
    guard (!occurrence.isEmpty)
    let label ← ostr record "label"
    let raw ← oobj record "raw"
    guard (ostr record "reason" == some codexHistoricalUnmodeledReason)
    let expected := Json.mkObj [
      ("carrier", Json.str "agent-convert.codex-unmodeled.v1"),
      ("occurrence", Json.str occurrence), ("label", Json.str label),
      ("raw", raw), ("reason", Json.str codexHistoricalUnmodeledReason)]
    guard (record == expected)
    guard (encoded.toString == expected.compress)
    pure (.unmodeled label raw text)
  else if kind == "environment_unmodeled" then
    let encoded ← text.dropPrefix? (codexHistoricalEnvUnmodeledCarrierHeader ++ "\n")
    let record ← (Json.parse encoded.toString).toOption
    guard (ostr record "carrier" == some "agent-convert.codex-env-unmodeled.v1")
    let occurrence ← ostr record "occurrence"
    guard (!occurrence.isEmpty)
    let label ← ostr record "label"
    let raw ← oobj record "raw"
    guard (ostr record "reason" == some codexHistoricalEnvUnmodeledReason)
    let expected := Json.mkObj [
      ("carrier", Json.str "agent-convert.codex-env-unmodeled.v1"),
      ("occurrence", Json.str occurrence), ("label", Json.str label),
      ("raw", raw), ("reason", Json.str codexHistoricalEnvUnmodeledReason)]
    guard (record == expected)
    guard (encoded.toString == expected.compress)
    pure (.envUnmodeled label raw text)
  else if kind == "entry" then
    let encoded <- text.dropPrefix? (codexHistoricalEntryCarrierHeader ++ "\n")
    let record <- (Json.parse encoded.toString).toOption
    guard (ostr record "carrier" == some "agent-convert.codex-entry.v1")
    let rawPayload <- oobj record "payload"
    let payload <- parseCodexHistoricalPayload? rawPayload
    guard (ostr record "reason" == some codexHistoricalEntryReason)
    let expected := Json.mkObj [
      ("carrier", Json.str "agent-convert.codex-entry.v1"),
      ("payload", codexHistoricalPayloadJson payload),
      ("reason", Json.str codexHistoricalEntryReason)]
    guard (record == expected)
    guard (encoded.toString == expected.compress)
    pure (.entry payload text)
  else if kind == "session_boundary" then
    let encoded <- text.dropPrefix? (codexHistoricalSessionBoundaryCarrierHeader ++ "\n")
    let record <- (Json.parse encoded.toString).toOption
    guard (ostr record "carrier" == some "agent-convert.codex-session-boundary.v1")
    let boundary <- oobj record "record"
    guard (codexSessionBoundaryRecordValid boundary)
    guard (ostr record "reason" == some codexHistoricalSessionBoundaryReason)
    let expected := Json.mkObj [
      ("carrier", Json.str "agent-convert.codex-session-boundary.v1"),
      ("record", boundary),
      ("reason", Json.str codexHistoricalSessionBoundaryReason)]
    guard (record == expected)
    guard (encoded.toString == expected.compress)
    pure (.sessionBoundary boundary)
  else none

/-- Mirror of `adaptCodex`'s `prevEntryIsSameText`: does the last kept entry
carry this exact role and joined text? (Non-text entries — thinking, toolCall,
toolResult — carry `text := ""`, so a nonempty utterance never matches them.) -/
private def prevSameText (kept : Array Kept) (role : Role) (text : String) : Bool :=
  match kept[kept.size - 1]? with
  | some k => decide (k.role = role) && k.text == text
  | none => false

private def adjacentMixedUserResponseTwin
    (records : Array Json) (index : Nat) (text : String) : Bool :=
  let previous := if index == 0 then none else records[index - 1]?
  previous.bind mixedUserResponseDisplayText? == some text ||
    records[index + 1]?.bind mixedUserResponseDisplayText? == some text

private def codexReasoningSummary? (payload : Json) : Option (List String) := do
  let summary ← oarr payload "summary"
  summary.toList.mapM (fun item => do
    guard (ostr item "type" == some "summary_text")
    ostr item "text")

private def optionalCodexEncryptedContent? (payload : Json) : Option (Option String) :=
  match oobj payload "encrypted_content" with
  | none | some Json.null => some none
  | some (Json.str encrypted) => some (some encrypted)
  | _ => none

/-- Fold the post-`session_meta` records into a kept list + the import-note
trace, applying the cross-channel dedup. Pure: argument-JSON parse failures are
absorbed (matching the TS try/catch), so no `Except` is needed here. -/
private def adaptRecords (records : List Json) (carrierSessionSelfIdentified : Bool) :
    Array Kept × Array ImportNote × Array Json × Array Json × Array Json ×
      Array CodexSessionBoundary := Id.run do
  let mut kept : Array Kept := #[]
  let mut notes : Array ImportNote := #[]
  let mut controls : Array Json := #[]
  let mut generatedControls : Array Json := #[]
  let mut archived : Array Json := #[]
  let mut boundaries : Array CodexSessionBoundary := #[]
  let mut lastChannel : String := ""            -- channel of the last PUSHED entry
  let mut segment : Nat := 0
  let mut idx : Nat := 0                         -- record index (post-header), for note locs
  let recordArray := records.toArray
  for j in records do
    let ty := (ostr j "type").getD ""
    let p := (oobj j "payload").getD Json.null
    let ts := ostr j "timestamp"
    let keptBefore := kept.size
    let timeProvenance := if carrierSessionSelfIdentified then
        parseCodexTimeProvenance? j
      else none
    if ty == "session_meta" then
      archived := archived.push j
      boundaries := boundaries.push { beforeEntry := kept.size, record := j }
      notes := notes.push (mkNote (.other "codex-session-boundary") idx
        "Codex session_meta resume/ancestor header retained as a lifecycle boundary")
      segment := segment + 1
      lastChannel := ""
    else if ty == "compacted" then
      if codexCompactedRecordValid j then
        let summary := (ostr p "message").getD ""
        kept := kept.push { (mkKept (.kcompaction summary) ts .assistant "" none) with
          nativeCompactionRaw := some j }
        lastChannel := "compacted"
      else
        archived := archived.push j
        notes := notes.push (mkNote (.other "codex-malformed-compaction-record") idx
          "Compacted record is outside the strict Codex 0.144.1 checkpoint domain; complete record retained outside dialogue")
    else if ty == "turn_context" then
      if codexGeneratedTargetDefaultsMarkerExact p then
        generatedControls := generatedControls.push j
        notes := notes.push (mkNote
          (.other "codex-generated-target-defaults") idx
          "Generated target defaults retained as historical, non-executable provenance")
      else
        controls := controls.push j
        notes := notes.push (mkNote .contentSkipped idx
          "Source Codex turn_context archived outside conversational entries")
    else if ty == "response_item" &&
        !(match oobj j "payload" with | some (.obj _) => true | _ => false) then
      archived := archived.push j
      notes := notes.push (mkNote (.other "codex-malformed-response-record") idx
        "Codex response_item has no object payload; complete record retained outside dialogue")
    else if ty == "response_item" then
      let pt := (ostr p "type").getD ""
      if pt == "message" && codexCarrierMarkerPresent p then
        match if carrierSessionSelfIdentified then
            parseCodexHistoricalCarrier? p segment else none with
        | some (.call block occurrence displayText) =>
            kept := kept.push { (mkKept (.kassistant [block]) ts .assistant displayText
              (some (.occurrence segment occurrence))) with historicalCarrier := true }
            lastChannel := "response_item"
        | some (.result link content error displayText) =>
            -- Keep the semantic role in `ktool`; the assistant role/text here is
            -- only the display-channel dedup key for Codex's paired event_msg.
            kept := kept.push { (mkKept (.ktool link content error none) ts .assistant
              displayText none) with historicalCarrier := true }
            lastChannel := "response_item"
        | some (.unmodeled label raw displayText) =>
            kept := kept.push { (mkKept (.kassistant [.unmodeled label raw])
              ts .assistant displayText none) with historicalCarrier := true }
            lastChannel := "response_item"
        | some (.envUnmodeled label raw displayText) =>
            -- The semantic payload remains environment-authored. The adjacent
            -- display event is assistant-authored, so use that role only for
            -- cross-channel deduplication.
            kept := kept.push { (mkKept (.kenv [.unmodeled label raw])
              ts .assistant displayText none) with historicalCarrier := true }
            lastChannel := "response_item"
        | some (.entry payload displayText) =>
            kept := kept.push { (mkKept (.khistorical payload)
              ts .assistant displayText none) with historicalCarrier := true }
            lastChannel := "response_item"
        | some (.sessionBoundary boundary) =>
            archived := archived.push boundary
            boundaries := boundaries.push { beforeEntry := kept.size, record := boundary }
            notes := notes.push (mkNote (.other "codex-session-boundary-carrier") idx
              "Inert historical carrier restored a disjoint call-id namespace")
            segment := segment + 1
            lastChannel := ""
        | none =>
            -- A marker is not authority to change authorship. Exact assistant
            -- carriers may decode above; incomplete, spoof-like, and future
            -- marker objects retain the source message role and complete raw
            -- payload. Control-plane roles remain in the control archive.
            let roleStr := (ostr p "role").getD ""
            let displayText := (oarr p "content" >>= codexAllText).getD ""
            if roleStr == "user" then
              match oarr p "content" with
              | some content =>
                  let split := splitCodexUserContent content
                  let controlContent := split.1
                  let dialogueContent := split.2
                  if controlContent.isEmpty then
                    kept := kept.push (mkKept (.kuser [.unmodeled "codex.message" p])
                      ts .user displayText none)
                    lastChannel := "response_item"
                  else
                    -- A spoof-like marker cannot turn runtime controls into user
                    -- dialogue. Archive the exact marked record and retain only
                    -- ordinary sibling blocks in the conversational projection.
                    controls := controls.push j
                    notes := notes.push (mkNote .contentSkipped idx
                      "Runtime-control blocks in an invalid carrier marker were archived outside conversational entries")
                    if !dialogueContent.isEmpty then
                      let joined? := codexAllText dialogueContent
                      let joined := joined?.getD ""
                      if joined?.isSome && lastChannel == "event_msg" &&
                          prevSameText kept .user joined then
                        notes := notes.push (mkNote .dedupDropped idx
                          "Invalid-marker user dialogue dropped as cross-channel duplicate")
                      else
                        kept := kept.push (mkKept (.kuser (codexUserBlocks dialogueContent))
                          ts .user joined none)
                        lastChannel := "response_item"
              | none =>
                  kept := kept.push (mkKept (.kuser [.unmodeled "codex.message" p])
                    ts .user displayText none)
                  lastChannel := "response_item"
            else if roleStr == "assistant" then
              kept := kept.push { (mkKept (.kassistant [
                .unmodeled "agent_convert_codex_carrier" p])
                ts .assistant displayText none) with historicalCarrier := true }
              lastChannel := "response_item"
            else
              controls := controls.push j
              notes := notes.push (mkNote .contentSkipped idx
                s!"Marker-bearing control-plane role '{roleStr}' archived with original authorship")
      else if pt == "message" then
        let roleStr := (ostr p "role").getD ""
        if !isCodexDialogueRole roleStr then
          -- Never guess control-plane or future role names into user/model
          -- authorship. The exact source record remains available in provenance.
          controls := controls.push j
          notes := notes.push (mkNote .contentSkipped idx
            s!"Codex control-plane role '{roleStr}' archived outside conversational entries")
        else match oarr p "content" with
        | none =>
            -- A message with a missing/non-array content field is itself the
            -- malformed content carrier. Keep the complete payload unmodeled.
            let kp : KPayload := if roleStr == "user" then
              .kuser [.unmodeled "codex.message" p]
            else .kassistant [.unmodeled "codex.message" p]
            let role : Role := if roleStr == "user" then .user else .assistant
            kept := kept.push (mkKept kp ts role "" none)
            notes := notes.push (mkNote (.other "codex-malformed-message") idx
              "Codex message content was missing or non-array; payload retained unmodeled")
            lastChannel := "response_item"
        | some content =>
            let split := if roleStr == "user" then splitCodexUserContent content
              else ((#[] : Array Json), content)
            let controlContent := split.1
            let dialogueContent := split.2
            if !controlContent.isEmpty then
              -- Archive the original record so every control block and its source
              -- context remain exact; only ordinary siblings enter dialogue.
              controls := controls.push j
              notes := notes.push (mkNote .contentSkipped idx
                "Codex runtime-control blocks archived outside conversational entries")
            if dialogueContent.isEmpty then
              if controlContent.isEmpty then
                archived := archived.push j
                notes := notes.push (mkNote .contentSkipped idx
                  "Empty Codex message retained as non-dialogue lifecycle data")
              else pure ()
            else
              let joined? := codexAllText dialogueContent
              let textOnly := joined?.isSome
              let joined := joined?.getD ""
              let role : Role := if roleStr == "user" then .user else .assistant
              -- Rich or malformed content has no lossless event_msg twin, so only
              -- an all-text message participates in cross-channel deduplication.
              if textOnly && lastChannel == "event_msg" && prevSameText kept role joined then
                let d := "response_item.message (" ++ roleStr ++ ") dropped as cross-channel dup of prior event_msg"
                notes := notes.push (mkNote .dedupDropped idx d)
              else
                let kp : KPayload := match role with
                  | .user => .kuser (codexUserBlocks dialogueContent)
                  | _ => .kassistant (codexAssistantBlocks dialogueContent)
                kept := kept.push (mkKept kp ts role joined none)
                lastChannel := "response_item"
      else if pt == "function_call" then
        match ostr p "call_id", ostr p "name", parseArgsExact? p with
        | some callId, some name, some args =>
          if callId.isEmpty || name.isEmpty then
            kept := kept.push (mkKept (.kassistant [
              .unmodeled "codex.malformed.function_call" p]) ts .assistant "" none)
            notes := notes.push (mkNote (.other "codex-malformed-tool-record") idx
              "function_call has an empty call_id or name; payload retained unmodeled")
          else
            -- `canonical` is recovered from the reserved envelope member, never
            -- re-derived from `name`. Only an exporter-stamped session may
            -- speak it: `codexReservedRecordSourceFailure?` additionally holds
            -- such a record to canonical whole-line bytes, so the member cannot
            -- be smuggled onto ordinary Codex output.
            let canonical := if carrierSessionSelfIdentified then
              codexPayloadToolCanonical? p else none
            let blk := AssistantBlock.toolCall { raw := name, canonical }
              args (some callId)
            kept := kept.push { (mkKept (.kassistant [blk]) ts .assistant ""
              (some (.rawId segment callId))) with nativeToolRaw := some j }
        | _, _, _ =>
            kept := kept.push (mkKept (.kassistant [
              .unmodeled "codex.malformed.function_call" p]) ts .assistant "" none)
            notes := notes.push (mkNote (.other "codex-malformed-tool-record") idx
              "function_call fields are missing, mistyped, or malformed; payload retained unmodeled")
        lastChannel := "response_item"
      else if pt == "function_call_output" then
        match ostr p "call_id", (oobj p "output" >>= codexToolOutputBlocks?) with
        | some callId, some content =>
          if callId.isEmpty then
            kept := kept.push (mkKept (.kenv [
              .unmodeled "codex.malformed.function_call_output" p])
              ts .environment "" none)
            notes := notes.push (mkNote (.other "codex-malformed-tool-record") idx
              "function_call_output has an empty call_id; payload retained unmodeled")
          else
            let isErr := codexOutputIndicatesError (toolOutputText content)
            -- An exporter-stamped session may say "the source never recorded
            -- this", which is not something the output text can express and not
            -- something the heuristic may overwrite. Everywhere else the
            -- heuristic is the only available answer.
            let unrecorded := carrierSessionSelfIdentified &&
              codexPayloadErrorIsUnrecorded p
            let err := if unrecorded then ErrorSignal.unrecorded
              else ErrorSignal.inferred isErr
                "codexOutputIndicatesError (codexAdapter.ts:75)"
            if unrecorded then
              notes := notes.push (mkNote .errorInferred idx
                "function_call_output error status retained as unrecorded from the exporter-owned reserved envelope; no inference made")
            else
              let d := "function_call_output error status inferred (isError=" ++
                toString isErr ++ ") via codexOutputIndicatesError"
              notes := notes.push (mkNote .errorInferred idx d)
            kept := kept.push { (mkKept (.ktool (.byId segment callId) content err
              (some ("codex.unresolved.function_call_output", p)))
              ts .environment "" none) with
                envelopeEligible := true, nativeToolRaw := some j }
        | _, _ =>
            kept := kept.push (mkKept (.kenv [
              .unmodeled "codex.malformed.function_call_output" p])
              ts .environment "" none)
            notes := notes.push (mkNote (.other "codex-malformed-tool-record") idx
              "function_call_output has a missing/mistyped call_id or malformed output; payload retained unmodeled")
        lastChannel := "response_item"
      else if pt == "reasoning" then
        match codexReasoningSummary? p, optionalCodexEncryptedContent? p with
        | some [], some none =>
            archived := archived.push j
            notes := notes.push (mkNote .contentSkipped idx
              "Empty Codex reasoning lifecycle record retained outside dialogue")
        | some [], some (some _) =>
            kept := kept.push (mkKept (.kassistant [
              .unmodeled "codex.reasoning" p]) ts .assistant "" none)
            notes := notes.push (mkNote (.other "codex-encrypted-reasoning") idx
              "Encrypted reasoning without a visible summary retained verbatim")
            lastChannel := "response_item"
        | some thinkTexts, some encrypted =>
            let blk := AssistantBlock.thinking
              (String.intercalate "\n" thinkTexts) encrypted
            kept := kept.push { (mkKept (.kassistant [blk]) ts .assistant "" none) with
              nativeReasoningRaw := some p }
            if encrypted.isSome then
              notes := notes.push (mkNote (.other "codex-encrypted-reasoning") idx
                "Encrypted reasoning retained in the thinking signature field")
            lastChannel := "response_item"
        | _, _ =>
            kept := kept.push (mkKept (.kassistant [
              .unmodeled "codex.reasoning" p]) ts .assistant "" none)
            notes := notes.push (mkNote (.other "codex-malformed-reasoning") idx
              "Malformed Codex reasoning payload retained verbatim")
            lastChannel := "response_item"
      else if pt == "web_search_call" || pt == "tool_search_call" then
        -- S5/S6 (was DROPPED → invisible): the model's search action, captured as a
        -- tool call named for the payload type. Args = the `action` object when
        -- present, else the whole payload. No function_call_output twin exists, so it
        -- never enters the call↔result index without an id. TS drops it.
        let args := ((oobj p "action").orElse (fun _ => oobj p "arguments")).getD p
        let cid : Option String := match ostr p "call_id" with | some c => some c | none => ostr p "id"
        let blk := AssistantBlock.toolCall { raw := pt, canonical := none } args cid
        -- callKey := cid (was none): lets the TS-parity `pairWebSearch` synthetic
        -- function_call_output resolve to this call. Harmless to the faithful path —
        -- nothing there references a search call's id (no output twin exists).
        kept := kept.push (mkKept (.kassistant [blk]) ts .assistant ""
          (cid.map (CodexCallKey.rawId segment)))
        lastChannel := "response_item"
      else if pt == "tool_search_output" then
        -- Current Codex emits this as the result twin of `tool_search_call`.
        -- Preserve the complete payload in an open-world result block and link by
        -- call_id; status supplies a native error bit while the raw status remains
        -- available for exact/reversible target carriers.
        match ostr p "call_id" with
        | some callId =>
          if callId.isEmpty then
            kept := kept.push (mkKept (.kenv [
              .unmodeled "codex.malformed.tool_search_output" p])
              ts .environment "" none)
            notes := notes.push (mkNote (.other "codex-malformed-tool-record") idx
              "tool_search_output has an empty call_id; payload retained unmodeled")
          else
            let status := ostr p "status"
            let err := match status with
              | some s => ErrorSignal.native (s != "completed")
              | none => ErrorSignal.unrecorded
            let content := [UserBlock.unmodeled "tool_search_output" p]
            kept := kept.push (mkKept (.ktool (.byId segment callId) content err
              (some ("codex.unresolved.tool_search_output", p)))
              ts .environment "" none)
        | none =>
            kept := kept.push (mkKept (.kenv [
              .unmodeled "codex.malformed.tool_search_output" p])
              ts .environment "" none)
            notes := notes.push (mkNote (.other "codex-malformed-tool-record") idx
              "tool_search_output is missing call_id; payload retained unmodeled")
        lastChannel := "response_item"
      else if pt == "custom_tool_call" then
        -- RC2 fix (was DROPPED → 125/424 real files under-reported): Codex emits
        -- `apply_patch` (and other custom tools whose input is non-JSON text) as a
        -- `custom_tool_call`, NOT a `function_call`. BOTH TS paths — `adaptCodex`
        -- (codexAdapter.ts:247-255) and the convert path (codex.ts:1023-1041) — map
        -- it to one assistant `toolCall` whose `arguments` wrap the raw patch DSL as
        -- `{patch: <input>}` (name defaults to "custom_tool"). We mirror `adaptCodex`,
        -- treating it exactly like `function_call`: same `call_id` linkage (so the
        -- paired `custom_tool_call_output` resolves to a real `CallRef` and the IR
        -- stays `WellFormed`), same push-site, same channel bookkeeping. Under
        -- `normalize` a toolCall projects to `call` (name/args dropped), so this row
        -- now matches BOTH TS paths byte-for-byte.
        match ostr p "call_id", ostr p "name", ostr p "input" with
        | some callId, some name, some inputText =>
          if callId.isEmpty || name.isEmpty then
            kept := kept.push (mkKept (.kassistant [
              .unmodeled "codex.malformed.custom_tool_call" p]) ts .assistant "" none)
            notes := notes.push (mkNote (.other "codex-malformed-tool-record") idx
              "custom_tool_call has an empty call_id or name; payload retained unmodeled")
          else
            let input := Json.str inputText
            let args := if name == "apply_patch" then Json.mkObj [("patch", input)]
                        else Json.mkObj [("input", input)]
            let blk := AssistantBlock.toolCall { raw := name, canonical := none }
              args (some callId)
            kept := kept.push { (mkKept (.kassistant [blk]) ts .assistant ""
              (some (.rawId segment callId))) with nativeToolRaw := some j }
        | _, _, _ =>
            kept := kept.push (mkKept (.kassistant [
              .unmodeled "codex.malformed.custom_tool_call" p]) ts .assistant "" none)
            notes := notes.push (mkNote (.other "codex-malformed-tool-record") idx
              "custom_tool_call fields are missing or mistyped; payload retained unmodeled")
        lastChannel := "response_item"
      else if pt == "custom_tool_call_output" then
        -- RC2 fix (twin of `custom_tool_call`): the apply_patch RESULT. Both TS paths
        -- (adaptCodex:256-259, codex.ts:1043-1057) flatten it to a `toolResult` whose
        -- text is the RAW `output` — NEITHER unwraps a Codex exec envelope here (that
        -- unwrap is convert-path-only and applies to `function_call_output`; see the
        -- D-unwrap census note), so keeping the raw output matches both. `isError` is
        -- inferred by the same `codexOutputIndicatesError` heuristic; the `call_id`
        -- resolves positionally to the `custom_tool_call` above.
        match ostr p "call_id", (oobj p "output" >>= codexToolOutputBlocks?) with
        | some callId, some content =>
          if callId.isEmpty then
            kept := kept.push (mkKept (.kenv [
              .unmodeled "codex.malformed.custom_tool_call_output" p])
              ts .environment "" none)
            notes := notes.push (mkNote (.other "codex-malformed-tool-record") idx
              "custom_tool_call_output has an empty call_id; payload retained unmodeled")
          else
            let isErr := codexOutputIndicatesError (toolOutputText content)
            let err := ErrorSignal.inferred isErr
              "codexOutputIndicatesError (codexAdapter.ts:75)"
            let d := "custom_tool_call_output error status inferred (isError=" ++
              toString isErr ++ ") via codexOutputIndicatesError"
            notes := notes.push (mkNote .errorInferred idx d)
            kept := kept.push { (mkKept (.ktool (.byId segment callId) content err
              (some ("codex.unresolved.custom_tool_call_output", p)))
              ts .environment "" none) with nativeToolRaw := some j }
        | _, _ =>
            kept := kept.push (mkKept (.kenv [
              .unmodeled "codex.malformed.custom_tool_call_output" p])
              ts .environment "" none)
            notes := notes.push (mkNote (.other "codex-malformed-tool-record") idx
              "custom_tool_call_output has a missing/mistyped call_id or malformed output; payload retained unmodeled")
        lastChannel := "response_item"
      else
        -- Open-world response items are still model-authored stream items, but
        -- their internal shape is not yet modeled. Keep the payload verbatim so
        -- a newer Codex kind cannot disappear on import or same-format export.
        let label := if pt.isEmpty then "unknown_response_item" else pt
        let blk := AssistantBlock.unmodeled label p
        kept := kept.push (mkKept (.kassistant [blk]) ts .assistant "" none)
        lastChannel := "response_item"
    else if ty == "event_msg" &&
        !(match oobj j "payload" with | some (.obj _) => true | _ => false) then
      archived := archived.push j
      notes := notes.push (mkNote (.other "codex-malformed-event-record") idx
        "Codex event_msg has no object payload; complete record retained outside dialogue")
    else if ty == "event_msg" then
      let pt := (ostr p "type").getD ""
      if pt == "user_message" || pt == "agent_message" then
        let role : Role := if pt == "user_message" then .user else .assistant
        match ostr p "message" with
        | none =>
            archived := archived.push j
            notes := notes.push (mkNote (.other "codex-malformed-event-message") idx
              s!"event_msg.{pt} has no string message; record retained outside dialogue")
        | some txt =>
          if isCodexControlEvent pt txt ||
              (pt == "user_message" &&
                adjacentMixedUserResponseTwin recordArray idx txt) then
            controls := controls.push j
            notes := notes.push (mkNote .contentSkipped idx
              "Codex runtime-control event duplicate archived outside conversational entries")
          else if pt == "user_message" && containsCodexControlEnvelope txt then
            controls := controls.push j
            notes := notes.push (mkNote (.other "codex-ambiguous-control-event") idx
              "Mixed runtime-control event had no provable structured twin; exact event archived")
          else if txt.isEmpty then
            archived := archived.push j
            notes := notes.push (mkNote .contentSkipped idx
              s!"Empty event_msg.{pt} retained as non-dialogue lifecycle data")
          else if lastChannel == "response_item" && prevSameText kept role txt then
            let d := "event_msg." ++ pt ++
              " dropped as cross-channel dup of prior response_item"
            notes := notes.push (mkNote .dedupDropped idx d)
          else
            let kp : KPayload := match role with
              | .user => .kuser [UserBlock.text txt]
              | _ => .kassistant [AssistantBlock.text txt]
            kept := kept.push (mkKept kp ts role txt none)
            lastChannel := "event_msg"
      else if pt == "error" then
        -- S6 (was DROPPED → truly invisible: `error` has NO response_item twin): a
        -- content-bearing meta event, modeled as `Payload.event (MetaEvent.custom
        -- "error" …)` keeping the whole payload. Not part of any dedup pair, so it
        -- does not disturb the cross-channel text dedup. TS drops it → Loom richer.
        kept := kept.push (mkKept (.kevent (MetaEvent.custom "error" p)) ts .assistant "" none)
        lastChannel := "event_msg"
      else if isSkippedCodexEventType pt then
        archived := archived.push j
        notes := notes.push (mkNote .contentSkipped idx
          s!"Codex lifecycle event '{pt}' retained outside conversational entries")
      else
        -- Preserve every non-lifecycle event payload verbatim. The label keeps
        -- its source channel/kind explicit while `p` remains re-exportable.
        let label := if pt.isEmpty then "codex.event_msg.unknown"
                     else "codex.event_msg." ++ pt
        kept := kept.push (mkKept (.kevent (MetaEvent.custom label p)) ts .assistant "" none)
        lastChannel := "event_msg"
    else
      archived := archived.push j
      notes := notes.push (mkNote (.other "codex-unknown-record") idx
        s!"Unknown Codex top-level record type '{ty}' retained outside dialogue")
    if kept.size > keptBefore then
      kept := kept.modify (kept.size - 1) (fun entry =>
        { entry with timeProvenance := timeProvenance })
    idx := idx + 1
  return (kept, notes, controls, generatedControls, archived, boundaries)

/-! ## Second pass: linear parents + positional tool-result linkage -/

private def popPendingCodexCall (key : CodexCallKey) :
    List (CodexCallKey × Nat × Nat) →
      Option ((Nat × Nat) × List (CodexCallKey × Nat × Nat))
  | [] => none
  | (callKey, entryIdx, blockIdx) :: rest =>
      if callKey == key then some ((entryIdx, blockIdx), rest)
      else
        match popPendingCodexCall key rest with
        | some (site, remaining) => some (site, (callKey, entryIdx, blockIdx) :: remaining)
        | none => none

private def pendingCodexCallCount (key : CodexCallKey)
    (pending : List (CodexCallKey × Nat × Nat)) : Nat :=
  pending.countP (fun (candidate, _, _) => candidate == key)

private inductive CodexResultResolution where
  | linked (call : CallRef)
  | inert (label : String) (raw : Json)

private def unresolvedCodexResult (nativeRaw : Option (String × Json))
    (rawId : Option String) (note suffix : String) : CodexResultResolution :=
  match nativeRaw with
  | some (label, raw) => .inert (label ++ "." ++ suffix) raw
  | none => .linked (.unresolved rawId note)

/-- Resolve only a unique unmatched earlier candidate, consuming it exactly
once. A duplicate id with two pending calls is ambiguous, and a later output
cannot reuse an already matched call. Native records without unique unmatched
evidence become exact inert environment payloads; historical carriers retain an
explicit unresolved `CallRef`. -/
private def codexResultRefs (kept : Array Kept) :
    List (Nat × CodexResultResolution) := Id.run do
  let mut pending : List (CodexCallKey × Nat × Nat) := []
  let mut refs : List (Nat × CodexResultResolution) := []
  for (entry, entryIdx) in kept.toList.zipIdx do
    match entry.kpayload, entry.callKey with
    | .kassistant blocks, some callKey =>
        for (block, blockIdx) in blocks.zipIdx do
          match block with
          | .toolCall _ _ _ => pending := pending ++ [(callKey, entryIdx, blockIdx)]
          | _ => pure ()
    | _, _ => pure ()
    match entry.kpayload with
    | .ktool link _ _ nativeRaw =>
        match link with
        | .unresolved rawId note =>
            refs := refs ++ [(entryIdx, unresolvedCodexResult nativeRaw rawId note
              "source_unresolved")]
        | .byId segment callId =>
            let key := CodexCallKey.rawId segment callId
            let candidateCount := pendingCodexCallCount key pending
            if candidateCount == 1 then
              match popPendingCodexCall key pending with
              | some ((callEntry, callBlock), remaining) =>
                  pending := remaining
                  refs := refs ++ [(entryIdx, .linked (.resolved callEntry callBlock))]
              | none =>
                  refs := refs ++ [(entryIdx, unresolvedCodexResult nativeRaw
                    (some callId) "unique pending tool call disappeared during linkage"
                    "linkage_error")]
            else if candidateCount > 1 then
              refs := refs ++ [(entryIdx, unresolvedCodexResult nativeRaw
                (some callId)
                s!"tool output call_id '{callId}' is ambiguous: {candidateCount} unmatched earlier calls"
                "ambiguous")]
            else
              refs := refs ++ [(entryIdx, unresolvedCodexResult nativeRaw
                (if callId.isEmpty then none else some callId)
                "tool output has no unique unmatched earlier call with this call_id"
                "unmatched")]
        | .byOccurrence segment occurrence rawId =>
            let key := CodexCallKey.occurrence segment occurrence
            let candidateCount := pendingCodexCallCount key pending
            if candidateCount == 1 then
              match popPendingCodexCall key pending with
              | some ((callEntry, callBlock), remaining) =>
                  pending := remaining
                  refs := refs ++ [(entryIdx, .linked (.resolved callEntry callBlock))]
              | none =>
                  refs := refs ++ [(entryIdx, unresolvedCodexResult nativeRaw rawId
                    s!"unique historical occurrence '{occurrence}' disappeared during linkage"
                    "linkage_error")]
            else if candidateCount > 1 then
              refs := refs ++ [(entryIdx, unresolvedCodexResult nativeRaw rawId
                s!"historical tool occurrence '{occurrence}' is ambiguous: {candidateCount} unmatched earlier calls"
                "ambiguous")]
            else
              refs := refs ++ [(entryIdx, unresolvedCodexResult nativeRaw rawId
                s!"historical tool call occurrence '{occurrence}' was not found"
                "unmatched")]
    | _ => pure ()
  return refs

private def unindexedCodexResult (link : CodexToolLink)
    (nativeRaw : Option (String × Json)) : CodexResultResolution :=
  match link with
  | .byId _ callId => unresolvedCodexResult nativeRaw
      (if callId.isEmpty then none else some callId)
      "tool output linkage was not indexed" "linkage_error"
  | .byOccurrence _ occurrence rawId => unresolvedCodexResult nativeRaw rawId
      s!"historical tool call occurrence '{occurrence}' was not indexed" "linkage_error"
  | .unresolved rawId note => unresolvedCodexResult nativeRaw rawId note
      "source_unresolved"

private def buildEntries (kept : Array Kept) : Array Entry :=
  let resultRefs := codexResultRefs kept
  (kept.toList.zipIdx.map (fun (k, i) =>
    let payload : Payload := match k.kpayload with
      | .kuser blocks => Payload.userMsg blocks
      | .kassistant blocks => Payload.assistantMsg blocks
      | .kenv blocks => Payload.envMsg blocks
      | .kevent e => Payload.event e
      | .ktool link content err nativeRaw =>
          let resolution := (resultRefs.find? (fun pair => pair.1 == i)).map (·.2) |>.getD
            (unindexedCodexResult link nativeRaw)
          match resolution with
          | .linked cref => Payload.envMsg [EnvBlock.toolResult cref content err]
          | .inert label raw => Payload.envMsg [EnvBlock.unmodeled label raw]
      | .kcompaction summary => Payload.compaction summary .unknownPrefix none
      | .khistorical payload => payload
    let sourceTimestamp := match k.timeProvenance with
      | some provenance => provenance.sourceTimestamp
      | none => k.ts
    let originExtras := (match sourceTimestamp with
        | some s => [("ts", Json.str s)]
        | none => []) ++
      (match k.nativeReasoningRaw with
        | some raw => [("raw_reasoning_payload", raw)]
        | none => []) ++
      (match k.nativeCompactionRaw with
        | some raw => [(codexCompactionRawRecordKey, raw)]
        | none => []) ++
      (match k.nativeToolRaw with
        | some raw => [(codexNativeToolRawRecordKey, raw)]
        | none => [])
    ({ parent := if i == 0 then none else some (i - 1),
       thread := 0,
       time := k.timeProvenance.map (fun provenance => provenance.time) |>.getD
         (k.ts.map recordedTimeFromIso8601 |>.getD Time.absent),
       payload := payload,
       origin := { format := Format.codexCli,
                   sourceRef := (if k.historicalCarrier then "historical-carrier-entry"
                                 else if k.envelopeEligible then "fnout-entry"
                                 else "entry") ++ toString i,
                   rawId := none,
                   extras := if originExtras.isEmpty then none
                     else some (Json.mkObj originExtras) },
       disposition := if k.historicalCarrier then .historicalUnverified
         else .native } : Entry))
  ).toArray

/-! ## Import: Codex JSONL → Loom IR -/

/-- Apply codex.ts's `compactionMode: "latest"` record rewrite (D15 transform 4,
`importCodexToPi` codex.ts:828-862): find the LAST `compacted` record, drop it and
everything before it EXCEPT the `session_meta`/`turn_context` headers, and splice the
last compaction's `replacement_history` items in as synthetic `response_item`s (the
summarised snapshot codex replayed to GPT on resume). No compaction → records
returned unchanged. This is an INPUT-level transform: the `replacement_history` items
are message-shaped, so the existing `adaptRecords` fold handles them with no new
branches — exactly how codex.ts rewrites its `lines` array before its import loop.
A missing, wrong-typed, or malformed latest replacement is an import error;
defaulting it to `#[]` would silently erase all preceding active history. -/
private def latestCompactionReplacement (compacted : Json) : Except String (Array Json) := do
  let payload ← match oobj compacted "payload" with
    | some value => pure value
    | none => throw "latest compacted record is missing an object payload"
  match payload with
  | .obj _ => pure ()
  | _ => throw "latest compacted record payload must be an object"
  let replacementValue ← match oobj payload "replacement_history" with
    | some value => pure value
    | none => throw "latest compacted record is missing replacement_history"
  let replacement ← match replacementValue with
    | .arr items => pure items
    | _ => throw "latest compacted replacement_history must be an array"
  if replacement.all (fun item => match item with
      | .obj _ => (ostr item "type").any (fun kind => !kind.isEmpty)
      | _ => false) then
    pure replacement
  else
    throw "latest compacted replacement_history contains a malformed item"

private def applyLatestCompactionSegment (records : List Json) :
    Except String (List Json) := do
  let lastIdx? := (records.zipIdx.filterMap (fun (r, i) =>
    if ostr r "type" == some "compacted" then some i else none)).getLast?
  match lastIdx? with
  | none => pure records
  | some lastIdx =>
    let compacted ← match records[lastIdx]? with
      | some value => pure value
      | none => throw "latest compacted record index is invalid"
    let replacement ← latestCompactionReplacement compacted
    let ts := (ostr compacted "timestamp").getD ""
    let synthetic := replacement.toList.map (fun item =>
      Json.mkObj [("type", Json.str "response_item"),
                  ("timestamp", Json.str ts), ("payload", item)])
    let preHead := (records.take lastIdx).filter (fun r =>
      ostr r "type" == some "turn_context")
    pure (preHead ++ synthetic ++ records.drop (lastIdx + 1))

/-- Apply compaction independently inside each accepted session segment. A
header is a hard semantic boundary: a replacement history in one segment cannot
select or erase another segment. The release census found 59/567 files with
multiple headers, all with distinct ids (ancestor/fork concatenation), 130 files
with compaction, and 97 with multiple compactions; it found no cross-header tool
link. Nothing in that corpus establishes a contract for crossing the boundary. -/
private def applyLatestCompaction (records : List Json) : Except String (List Json) := do
  let mut rewritten : List Json := []
  let mut segmentRecords : List Json := []
  for record in records do
    if ostr record "type" == some "session_meta" then
      let active ← applyLatestCompactionSegment segmentRecords
      rewritten := rewritten ++ active ++ [record]
      segmentRecords := []
    else
      segmentRecords := segmentRecords ++ [record]
  let active ← applyLatestCompactionSegment segmentRecords
  pure (rewritten ++ active)

private def codexIndexedRawRecord (recordIndex : Nat) (record : Json) : Json :=
  Json.mkObj [("record_index", Json.num recordIndex), ("record", record)]

/-- Describe the latest compaction in one session segment using source-record
indices. `excluded_records` contains exactly the non-control prefix plus the
compaction boundary itself; earlier `turn_context` controls remain active. -/
private def codexActiveCompactionBoundary? (segment segmentStart : Nat)
    (records : List Json) : Option (Json × Nat) := do
  let lastIdx <- (records.zipIdx.filterMap (fun (record, index) =>
    if ostr record "type" == some "compacted" then some index else none)).getLast?
  let compacted <- records[lastIdx]?
  let excludedPrefix := (records.take lastIdx).zipIdx.filterMap (fun (record, index) =>
    if ostr record "type" == some "turn_context" then none
    else some (codexIndexedRawRecord (segmentStart + index) record))
  let excluded := excludedPrefix ++
    [codexIndexedRawRecord (segmentStart + lastIdx) compacted]
  let replacementCount := (oobj compacted "payload" >>= fun payload =>
    oarr payload "replacement_history").map Array.size |>.getD 0
  let boundary := Json.mkObj [
    ("segment", Json.num segment),
    ("record_index", Json.num (segmentStart + lastIdx)),
    ("segment_record_index", Json.num lastIdx),
    ("excluded_record_count", Json.num excluded.length),
    ("retained_prefix_turn_context_count", Json.num
      ((records.take lastIdx).countP (fun record =>
        ostr record "type" == some "turn_context"))),
    ("replacement_history_count", Json.num replacementCount),
    ("boundary_record", compacted),
    ("excluded_records", Json.arr excluded.toArray)]
  pure (boundary, excluded.length)

/-- Machine-readable audit data for a context-rewritten import. The complete
source stream is intentionally retained so the continuation projection never
becomes the only surviving account of pre-compaction history. -/
private def codexActiveContextProvenance (records activeRecords : List Json) : Json := Id.run do
  let mut boundaries : Array Json := #[]
  let mut excludedCount := 0
  let mut segment := 0
  let mut segmentStart := 0
  let mut segmentRecords : List Json := []
  for (record, recordIndex) in records.zipIdx do
    if ostr record "type" == some "session_meta" then
      match codexActiveCompactionBoundary? segment segmentStart segmentRecords with
      | some (boundary, count) =>
          boundaries := boundaries.push boundary
          excludedCount := excludedCount + count
      | none => pure ()
      segment := segment + 1
      segmentStart := recordIndex + 1
      segmentRecords := []
    else
      segmentRecords := segmentRecords ++ [record]
  match codexActiveCompactionBoundary? segment segmentStart segmentRecords with
  | some (boundary, count) =>
      boundaries := boundaries.push boundary
      excludedCount := excludedCount + count
  | none => pure ()
  return Json.mkObj [
    ("protocol", Json.str "agent-convert.codex-active-context.v1"),
    ("active", Json.bool true),
    ("source_record_count", Json.num records.length),
    ("materialized_active_record_count", Json.num activeRecords.length),
    ("excluded_record_count", Json.num excludedCount),
    ("compaction_boundaries", Json.arr boundaries),
    ("raw_source_records", Json.arr records.toArray)]

/-- codex.ts pairs every `web_search_call` with a SYNTHESIZED empty toolResult
(`importCodexToPi` codex.ts:1059-1087): Codex emits only the call (results are baked
into the model's next turn), so codex.ts fabricates the paired result to preserve the
tool_use/tool_result invariant its downstream exporters need. Inject a synthetic
`function_call_output` (same `call_id`, the fixed "embedded" breadcrumb) after each
`web_search_call` so the fold produces that toolResult. The faithful import keeps ONLY
the call — Loom declines to fabricate — so this lives on the TS-parity path only. -/
private def pairWebSearch (records : List Json) : List Json :=
  records.zipIdx.flatMap (fun (r, i) =>
    if ((oobj r "payload").bind (fun p => ostr p "type")) == some "web_search_call" then
      let p := (oobj r "payload").getD Json.null
      let ts := (ostr r "timestamp").getD ""
      -- Share ONE call_id across the call and its fabricated result so they resolve
      -- (codex.ts uses `p.call_id ?? randomUUID()`; we use a deterministic `ws-<i>`
      -- when the record carries none, and stamp it onto the rewritten call record).
      let cid := (ostr p "call_id").getD ((ostr p "id").getD s!"ws-{i}")
      let action := (oobj p "action").getD (Json.mkObj [])
      let call := Json.mkObj [("type", Json.str "response_item"), ("timestamp", Json.str ts),
        ("payload", Json.mkObj [("type", Json.str "web_search_call"),
          ("call_id", Json.str cid), ("action", action)])]
      let synth := Json.mkObj [("type", Json.str "response_item"), ("timestamp", Json.str ts),
        ("payload", Json.mkObj [("type", Json.str "function_call_output"), ("call_id", Json.str cid),
          ("output", Json.str "[web_search results were embedded into model context by Codex; raw result not captured in rollout]")])]
      [call, synth]
    else [r])

/-- Records the codex.ts CONVERT path drops that Loom's faithful import keeps. Two
kinds, both dropped at INPUT (so parents/CallRefs build correctly with NO reindexing —
a post-import drop would need entry-surgery):
* ALL `event_msg` — codex.ts processes ONLY `response_item` (importCodexToPi
  codex.ts:911 skips session_meta/turn_context/event_msg). Loom keeps
  user_message/agent_message/error (matching the READ path adaptCodex) and relies on
  cross-channel dedup to match in normal sessions — but review-mode emits `event_msg`
  user_messages with NO `response_item` twin, so dedup can't collapse them and they
  survive as phantom entries. Dropping is safe for normal sessions: the deduped twin is
  the `response_item`, which stays, carrying identical text.
* `tool_search_call`/`tool_search_output` — S6 enrichment codex.ts drops; keeping them
  also injected the offset that made later call/text entries look mis-ordered. -/
private def dropTsParityNoise (records : List Json) : List Json :=
  records.filter (fun r =>
    let ty := ostr r "type"
    let pt := (oobj r "payload").bind (fun p => ostr p "type")
    -- The TS converter deliberately drops its known event vocabulary. A future
    -- event kind is retained and reaches `adaptRecords`' open-world fallback.
    !(ty == some "event_msg" && pt.any isKnownCodexEventType)
    && !(ty == some "response_item" &&
      (pt == some "tool_search_call" || pt == some "tool_search_output")))

/-- `payload.id` is the rollout/thread identity used in filenames and by Codex
resume. Newer subagent headers also carry a different `session_id` for parent
lineage, so it is a fallback only when `id` is absent or empty. -/
private def codexSessionId? (payload : Json) : Option String :=
  match ostr payload "id" with
  | some id => if id.isEmpty then
      (ostr payload "session_id").bind (fun sid =>
        if sid.isEmpty then none else some sid)
    else some id
  | none => (ostr payload "session_id").bind (fun sid =>
      if sid.isEmpty then none else some sid)

private def codexSessionIdFieldsMatch (payload : Json) (expected : String) : Bool :=
  codexSessionId? payload == some expected

def codexCliTargetVersion : String := "0.144.1"

private def codexHexDigit (char : Char) : Bool :=
  ('0' <= char && char <= '9') || ('a' <= char && char <= 'f') ||
    ('A' <= char && char <= 'F')

def codexUuidValid (value : String) : Bool :=
  match value.splitOn "-" with
  | [a, b, c, d, e] =>
      a.length == 8 && b.length == 4 && c.length == 4 && d.length == 4 &&
        e.length == 12 && [a, b, c, d, e].all (fun part =>
          part.toList.all codexHexDigit)
  | _ => false

private def codexAsciiAlpha (char : Char) : Bool :=
  ('a' <= char && char <= 'z') || ('A' <= char && char <= 'Z')

def codexAbsolutePathValid (value : String) : Bool :=
  value.startsWith "/" || value.startsWith "\\\\" ||
    match value.toList with
    | drive :: ':' :: slash :: _ =>
        codexAsciiAlpha drive && (slash == '/' || slash == '\\')
    | _ => false

private def codexDualIdentityNotes (payload : Json) : List ImportNote :=
  match ostr payload "id", ostr payload "session_id" with
  | some id, some sessionId =>
      if !id.isEmpty && !sessionId.isEmpty && id != sessionId then [{
        kind := .other "codex-dual-session-identity",
        loc := some "session_meta",
        detail := "payload.id selected as the current rollout identity; differing payload.session_id retained verbatim as source lineage provenance" }]
      else []
  | _, _ => []

private def latestCodexTurnModel? (records : List Json) : Option String :=
  (records.reverse.findSome? (fun record => do
    guard (ostr record "type" == some "turn_context")
    let payload <- oobj record "payload"
    let model <- ostr payload "model"
    guard (!model.isEmpty)
    pure model))

private def generatedTargetStateFields (sessionPayload : Json) (records : Array Json) :
    List (String × Json) :=
  match records.toList.getLast? with
  | some record =>
      let timestamp := ostr record "timestamp"
      let contextPayload := oobj record "payload"
      let controls := do
        let turn ← contextPayload
        let approvalPolicy ← ostr turn "approval_policy"
        let sandboxPolicy ← oobj turn "sandbox_policy"
        let summary ← ostr turn "summary"
        parseCodexTargetControls? (Json.mkObj [
          ("protocol", Json.str codexTargetControlsProtocol),
          ("approval_policy", Json.str approvalPolicy),
          ("sandbox_policy", sandboxPolicy),
          ("summary", Json.str summary)])
      [("target_turn_context_record", record)] ++
        (match timestamp with
         | some value => [("target_timestamp", Json.str value)]
         | none => []) ++
        (match codexSessionId? sessionPayload with
         | some value => [("target_session_id", Json.str value)]
         | none => []) ++
        (match ostr sessionPayload "cwd" with
         | some value => [("target_cwd", Json.str value)]
         | none => []) ++
        (match ostr sessionPayload "model_provider" with
         | some value => [("target_provider", Json.str value)]
         | none => []) ++
        (match contextPayload >>= fun turn => ostr turn "model" with
         | some value => [("target_model", Json.str value)]
         | none => []) ++
        (match ostr sessionPayload "cli_version" with
         | some value => [("target_harness_version", Json.str value)]
         | none => []) ++
        (match ostr sessionPayload "originator" with
         | some value => [("target_originator", Json.str value)]
         | none => []) ++
        (match controls with
         | some value => [(codexTargetControlsKey, codexTargetControlsJson value)]
         | none => [])
  | none => []

/-- Shared core: the `session_meta` payload `mp` + a (possibly compaction-rewritten)
record list → the Loom IR. Extracted so the faithful and TS-parity importers differ
only in whether `applyLatestCompaction` ran. -/
private def buildCodexTranscript (mp : Json) (records : List Json)
    (compactionRecords : Array Json := #[]) (activeContext : Bool := false)
    (activeContextProvenance : Option Json := none) : Transcript :=
  let carrierSession := codexCarrierSessionSelfIdentified mp
  let sourceArchive := parseCodexSourceArchive? mp
  let (kept, notes, controls, generatedControls, archived, boundaries) :=
    adaptRecords records carrierSession
  let sourceSessionPayload := sourceArchive.map (·.sourceSessionPayload) |>.getD mp
  let sourceIdentity := codexSourceIdentityJson sourceSessionPayload
  let headerEnv : EnvInfo := {
    cwd := ostr mp "cwd", model := latestCodexTurnModel? records,
    provider := ostr mp "model_provider", harnessVersion := ostr mp "cli_version",
    instructions := ostr mp "instructions", sessionId := codexSessionId? mp }
  let sourceEnv := sourceArchive.map (·.sourceEnv) |>.getD headerEnv
  let allControls := (sourceArchive.map (·.sourceControls) |>.getD #[]) ++ controls
  -- The active generated target context is re-emitted in place. Do not append
  -- it to the historical archive on every import/export cycle.
  let allGeneratedControls := sourceArchive.map (·.generatedTargetControls) |>.getD #[]
  let entries := buildEntries kept
  let activeLeaf := if entries.isEmpty then none else some (entries.size - 1)
  let activeLeafNotes : List ImportNote := match activeLeaf with
    | some leaf => [{
        kind := .activeLeafGuessed, loc := some s!"entry{leaf}",
        detail := "Codex records a linear rollout but no active-leaf field; selected the final materialized entry" }]
    | none => []
  { threads := #[{ kind := .main }],
    entries := entries,
    env := sourceEnv,
    activeLeaf := activeLeaf,
    importNotes := codexDualIdentityNotes mp ++ notes.toList ++ activeLeafNotes,
    origin := {
      format := Format.codexCli, sourceRef := "importCodexCli",
      rawId := codexSessionId? mp,
      extras := some (Json.mkObj ([
        ("originator", Json.str ((ostr mp "originator").getD "")),
        ("model_provider", Json.str ((ostr mp "model_provider").getD "")),
        ("cli_version", Json.str ((ostr mp "cli_version").getD "")),
        ("session_timestamp", Json.str ((ostr mp "timestamp").getD "")),
        ("compaction_events", Json.num compactionRecords.size),
        ("raw_compaction_records", Json.arr compactionRecords),
        ("active_context", Json.bool activeContext),
        ("carrier_session_self_identified", Json.bool carrierSession),
        ("raw_session_meta_payload", sourceSessionPayload),
        ("source_session_identity", sourceIdentity),
        ("raw_control_messages", Json.arr allControls),
        ("raw_generated_target_controls", Json.arr allGeneratedControls),
        ("raw_non_dialogue_records", Json.arr archived),
        ("raw_session_boundaries", Json.arr
          (boundaries.map codexSessionBoundaryJson))] ++
        (match activeContextProvenance with
         | some provenance => [
             ("active_context_provenance", provenance),
             ("active_context_excluded_record_count",
               (oobj provenance "excluded_record_count").getD (Json.num 0)),
             ("active_context_compaction_boundaries",
               (oobj provenance "compaction_boundaries").getD (Json.arr #[])),
             ("raw_active_context_source_records",
               (oobj provenance "raw_source_records").getD (Json.arr #[]))]
         | none => []) ++
        generatedTargetStateFields mp generatedControls)) } }

private def codexCompactionRecords (records : List Json) : Array Json :=
  (records.filter (fun record => ostr record "type" == some "compacted")).toArray

private def laterCodexSessionPayload (record : Json) : Except String Json := do
  match record with
  | .obj _ => pure ()
  | _ => throw "later session_meta record must be an object"
  let payload ← match oobj record "payload" with
    | some value => pure value
    | none => throw "later session_meta record is missing payload"
  match payload with
  | .obj _ => pure payload
  | _ => throw "later session_meta payload must be an object"

private def generatedCodexTargetMetadataFailure? (header payload context : Json) :
    Option String :=
  let topTimestamp := ostr header "timestamp"
  let payloadTimestamp := ostr payload "timestamp"
  let contextTimestamp := ostr context "timestamp"
  let contextPayload := oobj context "payload"
  let contextControls : Option CodexTargetControls := do
    let turn ← contextPayload
    let approvalPolicy ← ostr turn "approval_policy"
    let sandboxPolicy ← oobj turn "sandbox_policy"
    let summary ← ostr turn "summary"
    parseCodexTargetControls? (Json.mkObj [
      ("protocol", Json.str codexTargetControlsProtocol),
      ("approval_policy", Json.str approvalPolicy),
      ("sandbox_policy", sandboxPolicy),
      ("summary", Json.str summary)])
  if !(ostr payload "id").any codexUuidValid then
    some "generated Codex target session_meta.id must be a UUID"
  else if !(ostr payload "session_id").any codexUuidValid then
    some "generated Codex target session_meta.session_id must be a UUID"
  else if ostr payload "id" != ostr payload "session_id" then
    some "generated Codex target session_meta id and session_id must agree"
  else if topTimestamp.isNone || topTimestamp != payloadTimestamp ||
      topTimestamp != contextTimestamp ||
      !(topTimestamp.bind iso8601ToEpochMs?).isSome then
    some "generated Codex target timestamps must agree and be valid UTC ISO-8601"
  else if !(ostr payload "cwd").any codexAbsolutePathValid then
    some "generated Codex target session_meta.cwd must be an absolute path"
  else if !(ostr payload "originator").any (fun value => !value.isEmpty) then
    some "generated Codex target session_meta.originator must be nonempty"
  else if ostr payload "cli_version" != some codexCliTargetVersion then
    some s!"generated Codex target cli_version must be {codexCliTargetVersion}"
  else if ostr payload "source" != some "cli" then
    some "generated Codex target session_meta.source must be cli"
  else if oobj payload "git" != some Json.null then
    some "generated Codex target session_meta.git must be null"
  else if !(parseCodexSourceArchive? payload).isSome then
    some "generated Codex target source provenance archive is invalid"
  else if !(match oobj payload "model_provider" with
      | none | some Json.null => true
      | some (Json.str value) => !value.isEmpty
      | _ => false) then
    some "generated Codex target model_provider must be absent or a nonempty string"
  else match contextPayload with
    | none => some "generated Codex target turn_context payload must be an object"
    | some turn =>
        if ostr turn "cwd" != ostr payload "cwd" then
          some "generated Codex target turn_context.cwd must match session_meta.cwd"
        else if !(ostr turn "model").any (fun value => !value.isEmpty) then
          some "generated Codex target turn_context.model must be nonempty"
        else if contextControls.isNone then
          some "generated Codex target turn_context controls are invalid or incomplete"
        else if ostr turn "provenance" != some
            "explicit target controls from origin.extras.target_codex_controls" then
          some "generated Codex target turn_context.provenance is invalid"
        else none

private def parseCodexSession (text : String) : Except String (Json × List Json) := do
  let lines := (text.splitOn "\n").filter (fun line => !line.isEmpty)
  let (metaLine, rest) ← match lines with
    | [] => throw "empty codex session: missing session_meta header"
    | first :: remaining => pure (first, remaining)
  let header ← Json.parse metaLine
  match header with
  | .obj _ => pure ()
  | _ => throw "first codex record must be a session_meta object"
  if ostr header "type" != some "session_meta" then
    throw "first codex record must have type session_meta"
  let payload ← match oobj header "payload" with
    | some value => pure value
    | none => throw "session_meta header is missing payload"
  match payload with
  | .obj _ => pure ()
  | _ => throw "session_meta payload must be an object"
  -- Since Codex 0.142, subagent rollouts use `id` for the current rollout and
  -- may use a different `session_id` for parent-session lineage. The filename
  -- and `parent_thread_id` corpus evidence makes `id` authoritative here.
  let records ← rest.mapM Json.parse
  let carrierSession := codexCarrierSessionSelfIdentified payload
  for (sourceLine, record) in rest.zip records do
    match codexReservedRecordSourceFailure? carrierSession sourceLine record with
    | some failure => throw failure
    | none => pure ()
  for record in records do
    if ostr record "type" == some "turn_context" &&
        (oobj record "payload").any codexGeneratedTargetDefaultsMarkerExact then
      match generatedCodexTargetMetadataFailure? header payload record with
      | some failure => throw failure
      | none => pure ()
  let primaryId := codexSessionId? payload
  let mut contentStarted := false
  for record in records do
    if ostr record "type" == some "session_meta" then
      let laterPayload ← laterCodexSessionPayload record
      if contentStarted then
        match primaryId, codexSessionId? laterPayload with
        | some expected, some actual =>
            if !codexSessionIdFieldsMatch laterPayload expected then
              throw s!"different session_meta id '{actual}' after content for primary session '{expected}'"
        | _, _ =>
            throw "cannot prove later session_meta belongs to the primary session"
    else
      contentStarted := true
  pure (payload, records)

/-- Parse a Codex CLI session (line 0 `session_meta`, then response_item /
event_msg / turn_context / compacted records) into the Loom IR. Linear parents;
cross-channel dedup; identity is genuinely absent in the source (Codex records
carry no id) so `Origin.rawId := none` rather than a fabricated `cdxNNNN` — the
positional IR does not need synthesized ids. -/
def importCodexCli (text : String) : Except String Transcript := do
  let (mp, records) ← parseCodexSession text
  pure (buildCodexTranscript mp records (codexCompactionRecords records) false)

/-- Import the context Codex would actually resume: apply the latest compaction's
replacement history, but retain Loom's faithful event/tool/control handling.
Use this for cross-harness continuation; `importCodexCli` remains the complete
pre-compaction audit/read surface. -/
def importCodexCliActive (text : String) : Except String Transcript := do
  let (mp, records) ← parseCodexSession text
  let activeRecords ← applyLatestCompaction records
  let provenance := codexActiveContextProvenance records activeRecords
  pure (buildCodexTranscript mp activeRecords (codexCompactionRecords records) true
    (some provenance))

/-- TS-parity import: `importCodexCli` plus codex.ts's compaction `latest` rewrite
(transform 4) applied before the fold — the input-level half of matching the
convert-path oracle. Compose with `codexTsParity` (transforms 1-3) for the full
codex.ts reproduction; `loom convert codex pi --ts-parity` does exactly this. -/
def importCodexCliTsParity (text : String) : Except String Transcript := do
  let (mp, records) ← parseCodexSession text
  let activeRecords ← applyLatestCompaction records
  pure (buildCodexTranscript mp
    (pairWebSearch (dropTsParityNoise activeRecords))
    (codexCompactionRecords records) true
    (some (codexActiveContextProvenance records activeRecords)))

/-- Exact number of source records omitted by the active-context compaction
projection, when this transcript came from an active import. -/
def codexActiveContextExcludedRecordCount? (t : Transcript) : Option Nat := do
  let extras <- t.origin.extras
  (extras.getObjVal? "active_context_excluded_record_count" >>= Json.getNat?).toOption

/-- Exact source-indexed compaction boundaries used by the active projection. -/
def codexActiveContextCompactionBoundaries? (t : Transcript) : Option (Array Json) := do
  let extras <- t.origin.extras
  oarr extras "active_context_compaction_boundaries"

/-- Complete pre-rewrite Codex record stream retained for reversible audit. -/
def codexActiveContextRawSourceRecords? (t : Transcript) : Option (Array Json) := do
  let extras <- t.origin.extras
  oarr extras "raw_active_context_source_records"

/-! ## Actuator: the only IO. -/

/-- Read a Codex session file from disk into the IR. -/
def importCodexCliFile (path : System.FilePath) : IO (Except String Transcript) := do
  let text ← IO.FS.readFile path
  pure (importCodexCli text)

/-! ## TS-parity renderer/import path — reproduce `convert-to-pi codex` (codex.ts) for cutover.

Loom's faithful `importCodexCli` matches the READ-path oracle `adaptCodex`. The
CONVERT-path oracle `codex.ts` (the cutover target) applies four content transforms
`adaptCodex` does not (defect **D15**). The split is intentional: transform 4 is an
input-level rewrite, so `importCodexCliTsParity` applies it before the fold; then
`codexTsParity` maps the resulting IR through the three IR-level transforms. Used
together, they let `loom-diff --ts-parity` gate TRUE cutover parity WITHOUT regressing
the faithful default (which stays the shipped behaviour). Coverage:

1. **developer/control context isolation** — developer records and exact runtime
   envelopes are archived in origin extras, never projected into conversation.
2. **exec-envelope unwrap** — DONE, a port of codex.ts `unwrapCodexExecOutput`; the
   DOMINANT divergence (94% of function_call_outputs, RC2 census).
3. **multi-block text join (`join ""`)** — DONE, `mergeUserTextRuns`/`…Assistant…`.
4. **compaction `"latest"` truncation** — DONE on the TS-parity import path, via
   `importCodexCliTsParity` / `applyLatestCompaction`: drop records before the last
   `compacted` event, splice its `replacement_history`, then fold. This is not a pure
   `codexTsParity` IR→IR transform because faithful `importCodexCli` does not turn
   `compacted` records into conversation entries. Every raw compaction record and its
   replacement history remains in transcript origin provenance in all modes. The
   behavior is pinned below with the compaction fixture. -/

/-- Substring after the FIRST occurrence of `marker` (`none` if `marker` absent). -/
private def afterFirst (s marker : String) : Option String :=
  match s.splitOn marker with
  | _ :: rest@(_ :: _) => some (String.intercalate marker rest)
  | _ => none

/-- Port of codex.ts `unwrapCodexExecOutput`: strip the `exec_command` output
envelope (`Chunk ID:` header … `\nOutput:\n` … body) down to a terse
`[codex: exit=N wall=Xs]` breadcrumb + body, and unwrap the `{"output":"…"}` JSON
form. Pass-through when neither shape is present. -/
private def unwrapCodexExecOutput (raw : String) : String :=
  if raw.isEmpty then raw
  else if raw.startsWith "{\"output\":" then
    match Lean.Json.parse raw with
    | .ok j =>
      match j.getObjVal? "output" with
      | .ok o => match o.getStr? with | .ok s => s | .error _ => raw
      | .error _ => raw
    | .error _ => raw
  else if !raw.startsWith "Chunk ID:" then raw
  else match afterFirst raw "\nOutput:\n" with
    | none => raw
    | some body =>
      let header := (raw.splitOn "\nOutput:\n").headD ""
      let exitPart := (afterFirst header "Process exited with code ").bind (fun s =>
        let d := s.takeWhile Char.isDigit
        if d.isEmpty then none else some ("exit=" ++ d))
      let wallPart := (afterFirst header "Wall time: ").bind (fun s =>
        let d := s.takeWhile (fun c => c.isDigit || c == '.')
        if d.isEmpty then none else some ("wall=" ++ d ++ "s"))
      let parts := [exitPart, wallPart].filterMap id
      let breadcrumb := if parts.isEmpty then "" else "[codex: " ++ String.intercalate " " parts ++ "]\n"
      breadcrumb ++ body

/-- Reduce a user message's blocks to codex.ts's `codexMessageText`: join ALL `text`
items with `""` and DROP everything else (media/other). Non-adjacent runs join too —
a `media` block can sit between two texts (an inline `<image …></image>` split by an
`input_image`). This yields codex.ts's ACTUAL message content, not just its `normalize`
skeleton: `--ts-parity` is a faithful reproduction of the (lossy) TS convert path, so
it drops the message media TS drops. The faithful default import keeps that media
(Loom-richer) — the richness lives in the default, the parity in this mode. -/
private def mergeUserTextRuns (blocks : List UserBlock) : List UserBlock :=
  let texts := blocks.filterMap (fun b => match b with | UserBlock.text s => some s | _ => none)
  if texts.isEmpty then [] else [UserBlock.text (String.intercalate "" texts)]

/-- Assistant twin of `mergeUserTextRuns`. Codex `message` entries carry only
text/media (function_call/reasoning are SEPARATE response_items → their own entries),
so keeping only the joined text is order-safe AND drops the media codex.ts drops. -/
private def mergeAssistantTextRuns (blocks : List AssistantBlock) : List AssistantBlock :=
  let texts := blocks.filterMap (fun b => match b with | AssistantBlock.text s => some s | _ => none)
  let comparable := blocks.filterMap (fun b => match b with
    | AssistantBlock.thinking s sig => some (AssistantBlock.thinking s sig)
    | AssistantBlock.toolCall name args rawId => some (AssistantBlock.toolCall name args rawId)
    | _ => none)
  if texts.isEmpty then comparable else [AssistantBlock.text (String.intercalate "" texts)] ++ comparable

/-- Unwrap the exec envelope inside each of a tool-result's text content blocks. -/
private def unwrapEnvBlock : EnvBlock → EnvBlock
  | EnvBlock.toolResult call content err =>
      EnvBlock.toolResult call (content.map (fun ub => match ub with
        | UserBlock.text s => UserBlock.text (unwrapCodexExecOutput s)
        | other => other)) err
  | other => other

/-- Map the faithful Codex IR toward codex.ts's convert-path output for D15
transforms 1–3. Transform 4 is applied before import by `importCodexCliTsParity`,
because compaction replacement history is not present in the faithful IR.
Well-formedness is preserved because these transforms do not alter call references. -/
def codexTsParity (t : Transcript) : Transcript :=
  { t with entries := t.entries.map (fun e =>
      { e with payload := match e.payload with
          | Payload.assistantMsg blocks =>
              Payload.assistantMsg (mergeAssistantTextRuns blocks)
          | Payload.userMsg blocks => Payload.userMsg (mergeUserTextRuns blocks)
          | Payload.envMsg blocks  =>
              -- codex.ts unwraps the exec envelope ONLY for `function_call_output`;
              -- `custom_tool_call_output` (apply_patch etc.) is kept RAW by both paths.
              if e.origin.sourceRef.startsWith "fnout-entry"
              then Payload.envMsg (blocks.map unwrapEnvBlock)
              else Payload.envMsg blocks
          | other => other }) }

/-! ### Verification of the three IR-level transforms -/

/-- A fixture exercising context isolation, a two-item assistant text message,
and a `function_call_output` carrying a full exec envelope. -/
private def codexTsParityFixture : String := String.intercalate "\n" [
  "{\"type\":\"session_meta\",\"timestamp\":\"T0\",\"payload\":{\"id\":\"s\",\"timestamp\":\"T0\",\"cwd\":\"/w\",\"cli_version\":\"0\",\"originator\":\"codex-tui\",\"model_provider\":\"openai\",\"instructions\":\"x\"}}",
  "{\"type\":\"response_item\",\"timestamp\":\"T1\",\"payload\":{\"type\":\"message\",\"role\":\"developer\",\"content\":[{\"type\":\"input_text\",\"text\":\"be brief\"}]}}",
  "{\"type\":\"response_item\",\"timestamp\":\"T2\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Hello \"},{\"type\":\"output_text\",\"text\":\"world\"}]}}",
  "{\"type\":\"response_item\",\"timestamp\":\"T3\",\"payload\":{\"type\":\"function_call\",\"call_id\":\"c1\",\"name\":\"bash\",\"arguments\":\"{}\"}}",
  "{\"type\":\"response_item\",\"timestamp\":\"T4\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"c1\",\"output\":\"Chunk ID: abc\\nWall time: 1.5 seconds\\nProcess exited with code 0\\nOutput:\\nhi there\"}}"
]

/-- The ts-parity projection of the fixture (or `"ERR"`). -/
private def codexTsParityProjection : String :=
  match importCodexCli codexTsParityFixture with
  | .ok t => normalize (codexTsParity t)
  | .error _ => "ERR"

/-- PIN: context stays isolated, text joins, the exec envelope unwraps, and
well-formedness survives. -/
example :
    (match importCodexCli codexTsParityFixture with
     | .ok t =>
         let p := codexTsParity t
         (Loom.violations p).isEmpty
         -- transform 3 (join) and transform 2 (envelope) via the projection:
         && hasSub codexTsParityProjection "Hello world"
         && hasSub codexTsParityProjection "[codex: exit=0 wall=1.5s]"
         && !hasSub codexTsParityProjection "Chunk ID"
         && !hasSub codexTsParityProjection "be brief"
     | .error _ => false) = true := by native_decide

/-! ### Verification of transform 4 (compaction `latest`) + web_search pairing -/

/-- A compaction fixture: a PRE-compaction message (dropped by `latest`), a
`compacted` record whose `replacement_history` holds one summary message (spliced
in), a POST-compaction message (kept), and a `web_search_call` (paired with a
synthetic result under ts-parity). -/
private def codexCompactionFixture : String := String.intercalate "\n" [
  "{\"type\":\"session_meta\",\"timestamp\":\"T0\",\"payload\":{\"id\":\"s\",\"timestamp\":\"T0\",\"cwd\":\"/w\",\"cli_version\":\"0\",\"originator\":\"codex-tui\",\"model_provider\":\"openai\",\"instructions\":\"x\"}}",
  "{\"type\":\"response_item\",\"timestamp\":\"T1\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"OLD-precompaction\"}]}}",
  "{\"type\":\"compacted\",\"timestamp\":\"T2\",\"payload\":{\"message\":\"summary\",\"replacement_history\":[{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"SNAPSHOT-spliced\"}]}]}}",
  "{\"type\":\"response_item\",\"timestamp\":\"T3\",\"payload\":{\"type\":\"web_search_call\",\"status\":\"completed\"}}",
  "{\"type\":\"response_item\",\"timestamp\":\"T4\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"NEW-postcompaction\"}]}}"
]

/-- PIN: `latest` compaction keeps the replacement_history snapshot + post-compaction
messages and DROPS pre-compaction content, the web_search call gets its fabricated
result (so no orphan → well-formed), and the FAITHFUL import keeps the full linear
stream (incl. OLD, no SNAPSHOT). Locks transforms 4 + web_search against regression. -/
example :
    (match importCodexCliTsParity codexCompactionFixture,
        importCodexCliActive codexCompactionFixture,
        importCodexCli codexCompactionFixture with
     | .ok tsp, .ok active, .ok faith =>
         let p := normalize (codexTsParity tsp)
         hasSub p "SNAPSHOT-spliced" && hasSub p "NEW-postcompaction"
         && !hasSub p "OLD-precompaction"
         && hasSub p "[web_search results were embedded"
         && (Loom.violations (codexTsParity tsp)).isEmpty
         && hasSub (normalize active) "SNAPSHOT-spliced"
         && hasSub (normalize active) "NEW-postcompaction"
         && !hasSub (normalize active) "OLD-precompaction"
         && hasSub (normalize faith) "OLD-precompaction"
         && !hasSub (normalize faith) "SNAPSHOT-spliced"
     | _, _, _ => false) = true := by native_decide

private def codexCompactionProvenanceRetainsMeaning (t : Transcript) : Bool :=
  match t.origin.extras with
  | none => false
  | some extras =>
      let count := (extras.getObjVal? "compaction_events" >>= Json.getNat?).toOption
      let records := (extras.getObjVal? "raw_compaction_records" >>= Json.getArr?).toOption
      match records with
      | some raw =>
          raw.size == 1 && count == some 1 &&
            (match raw[0]? with
             | some record =>
                 hasSub (Json.compress record) "replacement_history" &&
                   hasSub (Json.compress record) "SNAPSHOT-spliced"
             | none => false)
      | none => false

/-- PIN: faithful, active-context, and TS-parity imports all retain the exact
raw compaction record. The active views may replace conversation history, but
the source replacement snapshot is never collapsed to the numeric count. -/
def codexCompactionMeaningRetained : Bool :=
  match importCodexCli codexCompactionFixture,
      importCodexCliActive codexCompactionFixture,
      importCodexCliTsParity codexCompactionFixture with
  | .ok faithful, .ok active, .ok tsParity =>
      codexCompactionProvenanceRetainsMeaning faithful &&
      codexCompactionProvenanceRetainsMeaning active &&
      codexCompactionProvenanceRetainsMeaning tsParity
  | _, _, _ => false

example : codexCompactionMeaningRetained = true := by native_decide

/-- Active-context imports publish both the exact loss count/boundary and the
complete original record stream. The source can therefore be audited or
reconstructed even though the continuation IR contains only the replacement
snapshot and post-compaction records. -/
def codexActiveContextExclusionsAreExplicitAndReversible : Bool :=
  match parseCodexSession codexCompactionFixture,
      importCodexCliActive codexCompactionFixture with
  | .ok (_, sourceRecords), .ok active =>
      let boundaries := codexActiveContextCompactionBoundaries? active
      codexActiveContextExcludedRecordCount? active == some 2 &&
      codexActiveContextRawSourceRecords? active == some sourceRecords.toArray &&
      (active.origin.extras >>= fun extras => obool extras "active_context") ==
        some true &&
      match boundaries with
      | some #[boundary] =>
          (boundary.getObjVal? "segment" >>= Json.getNat?).toOption == some 0 &&
          (boundary.getObjVal? "record_index" >>= Json.getNat?).toOption == some 1 &&
          (boundary.getObjVal? "segment_record_index" >>= Json.getNat?).toOption ==
            some 1 &&
          (boundary.getObjVal? "excluded_record_count" >>= Json.getNat?).toOption ==
            some 2 &&
          (oarr boundary "excluded_records").any (fun excluded =>
            excluded.size == 2 &&
              excluded[0]?.any (fun indexed =>
                (indexed.getObjVal? "record_index" >>= Json.getNat?).toOption ==
                  some 0 && hasSub indexed.compress "OLD-precompaction") &&
              excluded[1]?.any (fun indexed =>
                (indexed.getObjVal? "record_index" >>= Json.getNat?).toOption ==
                  some 1 && hasSub indexed.compress "replacement_history"))
      | _ => false
  | _, _ => false

example : codexActiveContextExclusionsAreExplicitAndReversible = true := by native_decide

private def codexBadHeaderFixtures : List String := [
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[]}}",
  "{\"type\":\"turn_context\",\"payload\":{}}",
  "[]",
  "{\"type\":\"session_meta\"}",
  "{\"type\":\"session_meta\",\"payload\":[]}" ]

private def allCodexImportModesReject (input : String) : Bool :=
  (match importCodexCli input with | .error _ => true | .ok _ => false) &&
  (match importCodexCliActive input with | .error _ => true | .ok _ => false) &&
  (match importCodexCliTsParity input with | .error _ => true | .ok _ => false)

/-- The first nonblank JSON value is a typed header, not merely a convenient
place from which to default missing metadata. Every import mode shares the same
strict gate. -/
def codexSessionMetaHeaderRequired : Bool :=
  codexBadHeaderFixtures.all allCodexImportModesReject

example : codexSessionMetaHeaderRequired = true := by native_decide

private def codexBadCompactionFixtures : List String := [
  String.intercalate "\n" [
    "{\"type\":\"session_meta\",\"payload\":{\"id\":\"bad-compaction-missing\"}}",
    "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"KEEP-before-invalid-compaction\"}]}}",
    "{\"type\":\"compacted\",\"payload\":{\"message\":\"missing history\"}}"],
  String.intercalate "\n" [
    "{\"type\":\"session_meta\",\"payload\":{\"id\":\"bad-compaction-type\"}}",
    "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"KEEP-before-invalid-compaction\"}]}}",
    "{\"type\":\"compacted\",\"payload\":{\"replacement_history\":{}}}"],
  String.intercalate "\n" [
    "{\"type\":\"session_meta\",\"payload\":{\"id\":\"bad-compaction-item\"}}",
    "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"KEEP-before-invalid-compaction\"}]}}",
    "{\"type\":\"compacted\",\"payload\":{\"replacement_history\":[7]}}"],
  String.intercalate "\n" [
    "{\"type\":\"session_meta\",\"payload\":{\"id\":\"bad-compaction-object\"}}",
    "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"KEEP-before-invalid-compaction\"}]}}",
    "{\"type\":\"compacted\",\"payload\":{\"replacement_history\":[{}]}}"],
  String.intercalate "\n" [
    "{\"type\":\"session_meta\",\"payload\":{\"id\":\"bad-compaction-payload\"}}",
    "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"KEEP-before-invalid-compaction\"}]}}",
    "{\"type\":\"compacted\",\"payload\":[]}" ] ]

private def badCompactionFailsActiveWithoutHidingFaithfulHistory
    (input : String) : Bool :=
  (match importCodexCliActive input with | .error _ => true | .ok _ => false) &&
  (match importCodexCliTsParity input with | .error _ => true | .ok _ => false) &&
  (match importCodexCli input with
   | .ok transcript => hasSub (normalize transcript) "KEEP-before-invalid-compaction"
   | .error _ => false)

/-- A bad latest replacement is never interpreted as an empty replacement.
Active-context modes fail, while the faithful audit import still exposes all
pre-compaction history. -/
def codexMalformedLatestCompactionRejected : Bool :=
  codexBadCompactionFixtures.all badCompactionFailsActiveWithoutHidingFaithfulHistory

example : codexMalformedLatestCompactionRejected = true := by native_decide

/-- Open-world fixture: neither payload kind exists in this importer's schema.
Both used to hit a wildcard `pure ()` and disappear. -/
def codexUnknownKindsFixture : String := String.intercalate "\n" [
  "{\"type\":\"session_meta\",\"timestamp\":\"T0\",\"payload\":{\"id\":\"future\",\"cwd\":\"/w\"}}",
  "{\"type\":\"response_item\",\"timestamp\":\"T1\",\"payload\":{\"type\":\"future_response_item\",\"value\":\"kept-response\"}}",
  "{\"type\":\"event_msg\",\"timestamp\":\"T2\",\"payload\":{\"type\":\"task_started\"}}",
  "{\"type\":\"event_msg\",\"timestamp\":\"T3\",\"payload\":{\"type\":\"future_event\",\"value\":\"kept-event\"}}",
  "{\"type\":\"event_msg\",\"timestamp\":\"T4\",\"payload\":{\"type\":\"tool_search_call\",\"value\":\"kept-event-collision\"}}"
]

private def codexUnknownKindsShape (t : Transcript) : Bool :=
  match t.entries[0]?, t.entries[1]?, t.entries[2]? with
  | some responseEntry, some eventEntry, some collisionEntry =>
      match responseEntry.payload, eventEntry.payload, collisionEntry.payload with
      | .assistantMsg [AssistantBlock.unmodeled responseLabel responseRaw],
        .event (MetaEvent.custom eventLabel eventRaw),
        .event (MetaEvent.custom collisionLabel collisionRaw) =>
          t.entries.size == 3 && responseLabel == "future_response_item" &&
          ostr responseRaw "value" == some "kept-response" &&
          eventLabel == "codex.event_msg.future_event" &&
          ostr eventRaw "value" == some "kept-event" &&
          collisionLabel == "codex.event_msg.tool_search_call" &&
          ostr collisionRaw "value" == some "kept-event-collision"
      | _, _, _ => false
  | _, _, _ => false

/-- PIN: the normal, active-context, and TS-parity import surfaces all retain
future response/event kinds. The parity pre-filter must not bypass this guard. -/
def codexUnknownKindsRetained : Bool :=
  match importCodexCli codexUnknownKindsFixture,
      importCodexCliActive codexUnknownKindsFixture,
      importCodexCliTsParity codexUnknownKindsFixture with
  | .ok faithful, .ok active, .ok tsParity =>
      codexUnknownKindsShape faithful && codexUnknownKindsShape active &&
        codexUnknownKindsShape tsParity
  | _, _, _ => false

example : codexUnknownKindsRetained = true := by native_decide

/-- A user message whose text is split by an inline image (`input_text`,
`input_image`, `input_text`) — the real-corpus `<image …></image>` shape. -/
private def codexMediaSplitFixture : String := String.intercalate "\n" [
  "{\"type\":\"session_meta\",\"timestamp\":\"T0\",\"payload\":{\"id\":\"s\",\"timestamp\":\"T0\",\"cwd\":\"/w\",\"cli_version\":\"0\",\"originator\":\"codex-tui\",\"model_provider\":\"openai\",\"instructions\":\"x\"}}",
  ("{\"type\":\"response_item\",\"timestamp\":\"T1\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"<img>\"},{\"type\":\"input_image\",\"image_url\":\"" ++
    codexTinyPngDataUri ++
    "\"},{\"type\":\"input_text\",\"text\":\"</img>done\"}]}}")
]

/-- PIN: text split by a (ts-parity-dropped) `media` block joins into ONE text —
codex.ts's `codexMessageText` joins ALL text items, so a media gap must NOT leave two
text blocks (`<img>;text:</img>` was the full-corpus burn-in's only residual class). -/
example :
    (match importCodexCliTsParity codexMediaSplitFixture with
     | .ok t => hasSub (normalizeTsParity (codexTsParity t)) "user|text:<img></img>done"
     | .error _ => false) = true := by native_decide

private def codexUnmodeledMessageBlocksFixture : String := String.intercalate "\n" [
  "{\"type\":\"session_meta\",\"payload\":{\"id\":\"message-blocks\"}}",
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"before\"},{\"type\":\"future_block\",\"value\":{\"n\":1}},{\"type\":\"input_text\",\"text\":7},{\"value\":\"missing type\"},7,{\"type\":\"input_image\",\"image_url\":false},{\"type\":\"input_text\",\"text\":\"after\"}]}}",
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"future_output\",\"value\":[1,true]},{\"type\":\"output_text\",\"text\":{\"bad\":true}}]}}"
]

/-- Every unknown or malformed content-array item stays in position and keeps
its exact JSON value. In particular, primitive items and known kinds with a
wrong field type are not mistaken for an empty message. -/
def codexUnmodeledMessageBlocksRetained : Bool :=
  match importCodexCli codexUnmodeledMessageBlocksFixture with
  | .error _ => false
  | .ok transcript =>
      match transcript.entries[0]?, transcript.entries[1]? with
      | some user, some assistant =>
          (match user.payload with
           | .userMsg [.text before,
               .unmodeled l1 r1, .unmodeled l2 r2, .unmodeled l3 r3,
               .unmodeled l4 r4, .unmodeled l5 r5, .text after] =>
               before == "before" && after == "after" &&
               [l1, l2, l3, l4, l5].all (· == codexMessageContentLabel) &&
               r1 == Json.mkObj [("type", Json.str "future_block"),
                 ("value", Json.mkObj [("n", (1 : Json))])] &&
               r2 == Json.mkObj [("type", Json.str "input_text"), ("text", (7 : Json))] &&
               r3 == Json.mkObj [("value", Json.str "missing type")] &&
               r4 == (7 : Json) &&
               r5 == Json.mkObj [("type", Json.str "input_image"),
                 ("image_url", Json.bool false)]
           | _ => false) &&
          (match assistant.payload with
           | .assistantMsg [.unmodeled l1 r1, .unmodeled l2 r2] =>
               l1 == codexMessageContentLabel && l2 == codexMessageContentLabel &&
               r1 == Json.mkObj [("type", Json.str "future_output"),
                 ("value", Json.arr #[(1 : Json), Json.bool true])] &&
               r2 == Json.mkObj [("type", Json.str "output_text"),
                 ("text", Json.mkObj [("bad", Json.bool true)])]
           | _ => false)
      | _, _ => false

example : codexUnmodeledMessageBlocksRetained = true := by native_decide

/-! ## Fixture (structure-only; mirrors `parity/fixtures/codex.jsonl`)

Exercises the dedup in BOTH directions and the tool lifecycle:
  * user turn:      response_item.message(user "U") → event_msg.user_message "U"
                    (the event_msg is the cross-channel dup → dropped).
  * assistant turn: reasoning "R" → event_msg.agent_message "A" →
                    response_item.message(assistant "A") (the response_item is the
                    cross-channel dup → dropped; the D13 direction).
  * a `developer` message (archived, not conversational), one function_call + function_call_output,
    and turn_context / task_started / token_count / task_complete skip records. -/
def codexFixture : String := String.intercalate "\n" [
  "{\"type\":\"session_meta\",\"timestamp\":\"2026-07-06T00:00:00.000Z\",\"payload\":{\"id\":\"sess-cdx-1\",\"timestamp\":\"2026-07-06T00:00:00.000Z\",\"cwd\":\"/tmp/cdx\",\"cli_version\":\"0.142.4\",\"originator\":\"codex-tui\",\"model_provider\":\"openai\",\"instructions\":\"be brief\"}}",
  "{\"type\":\"turn_context\",\"timestamp\":\"2026-07-06T00:00:01.000Z\",\"payload\":{\"cwd\":\"/tmp/cdx\",\"approval_policy\":\"never\"}}",
  "{\"type\":\"event_msg\",\"timestamp\":\"2026-07-06T00:00:02.000Z\",\"payload\":{\"type\":\"task_started\"}}",
  "{\"type\":\"response_item\",\"timestamp\":\"2026-07-06T00:00:03.000Z\",\"payload\":{\"type\":\"message\",\"role\":\"developer\",\"content\":[{\"type\":\"input_text\",\"text\":\"D\"}]}}",
  "{\"type\":\"response_item\",\"timestamp\":\"2026-07-06T00:00:04.000Z\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"U\"}]}}",
  "{\"type\":\"event_msg\",\"timestamp\":\"2026-07-06T00:00:05.000Z\",\"payload\":{\"type\":\"user_message\",\"message\":\"U\"}}",
  "{\"type\":\"response_item\",\"timestamp\":\"2026-07-06T00:00:06.000Z\",\"payload\":{\"type\":\"reasoning\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"R\"}],\"encrypted_content\":\"enc\"}}",
  "{\"type\":\"event_msg\",\"timestamp\":\"2026-07-06T00:00:07.000Z\",\"payload\":{\"type\":\"agent_message\",\"message\":\"A\"}}",
  "{\"type\":\"response_item\",\"timestamp\":\"2026-07-06T00:00:08.000Z\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"A\"}]}}",
  "{\"type\":\"event_msg\",\"timestamp\":\"2026-07-06T00:00:09.000Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"total_tokens\":10}}}}",
  "{\"type\":\"response_item\",\"timestamp\":\"2026-07-06T00:00:10.000Z\",\"payload\":{\"type\":\"function_call\",\"name\":\"exec_command\",\"call_id\":\"c1\",\"arguments\":\"{\\\"cmd\\\":\\\"ls\\\"}\"}}",
  "{\"type\":\"response_item\",\"timestamp\":\"2026-07-06T00:00:11.000Z\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"c1\",\"output\":\"done\"}}",
  "{\"type\":\"event_msg\",\"timestamp\":\"2026-07-06T00:00:12.000Z\",\"payload\":{\"type\":\"task_complete\",\"last_agent_message\":\"A\"}}"
]

-- Import works: developer context archived and dedup applied (5 kept entries —
-- dropped) and the IR is well-formed (0 structural violations).
example :
    (match importCodexCli codexFixture with
     | .ok t => t.entries.size == 5 && (Loom.violations t).isEmpty
     | .error _ => false) = true := by native_decide

/-! ## Cross-parity pins (RC1) -/

/-- The raw TS golden, captured from `parseSession` via `parity/capture-parity.ts`
on `parity/fixtures/codex.jsonl` (positional projection). -/
def codexCase1 : CrossParityCase := {
  name := "codex",
  input := codexFixture,
  tsGolden := "session\n0|-|user|text:U\n1|0|assistant|think:R\n2|1|assistant|text:A\n3|2|assistant|call\n4|3|toolResult|text:done"
}

/-- THE DECIDE-PIN (cross-parity, RC1): locks the at-risk logic — the cross-channel
dedup (BOTH directions, the D13 fix), developer-context isolation, roles, thinking, and the
tool call — against the TS oracle byte-for-byte. The earlier tool_result divergence
is resolved at the projection layer (toolResult → content text; Loom's CallRef +
ErrorSignal enrichment verified separately). If the dedup or mapping drifts, this
stops compiling. -/
example : crossParityOkWith importCodexCli codexCase1 = true := by native_decide

/-! ## Export: Loom IR → Codex JSONL (the inverse of `importCodexCli`)

The round-trip direction, enabling self-parity. Codex is **linear**, so we walk
`entries` in order and render each back to a `response_item` stream record —
Codex's real semantic channel. A normal round-trip deliberately does not re-emit
the paired `event_msg` display duplicates: `importCodexCli` deduped them away on
the way in (the D13 fix), and a response-item-only stream re-imports identically.
When the CLI marks the transcript as a target-session export, however, every
user/assistant message also receives its current Codex display twin. Codex's TUI
uses those events to render imported history; omitting them creates a session the
runtime can resume but a developer cannot read. The importer drops the twins on
re-import, so semantic round-trip stability is unchanged. Line 0 is the
`session_meta` record, reconstructed from `EnvInfo` + `Origin`.

Inverse mapping (Loom → Codex `response_item.payload`):
* text blocks of a `userMsg`/`assistantMsg`/`otherMsg` → `{type:message, role,
  content:[{type: input_text|output_text, text}]}` (all text blocks of one entry
  → one record).
* target-native `AssistantBlock.toolCall` (`exec_command`/`update_plan`) →
  `{type:function_call, ...}` when a call id is recorded.
* every foreign/unsupported tool call and result → a labeled, non-executable
  assistant history record retaining id/name/arguments/output/error state.
* results for target-native calls → `{type:function_call_output, ...}` only
  when the result is exactly one text block with reproducible inferred status;
  all other result structures use the lossless history carrier.
* `AssistantBlock.thinking`             → `{type:reasoning, summary:[{type:
  summary_text, text}], encrypted_content?:signature}` only when the entry is
  Codex-origin (so `signature` is OpenAI ciphertext). Foreign signatures
  (Claude `thinking.signature`, Pi `thinkingSignature`, …) are omitted from
  `encrypted_content`; empty foreign thinking is omitted entirely. Placing a
  non-OpenAI blob in that slot breaks Codex resume with
  `invalid_encrypted_content`.

Also re-emitted (S5+S6): message `.media` → an `input_image` content item with
its complete locator; every standalone `AssistantBlock.unmodeled` payload uses an
inert historical carrier, while proven raw message-content items stay nested;
`Payload.event (MetaEvent.custom "error" …)` → its `event_msg.error` record (a
twin-less content event, so it introduces no dedup pair — re-import stays stable).

Special handling in an ordinary format round-trip:
* the user/agent `event_msg` DUPLICATE channel (target-session export restores it
  for TUI readability — see above);
* a native `Payload.compaction` whose entry retains an exact 0.144.1 checkpoint
  record → `compacted`; an unrepresentable native compaction is preserved only
  by the total forensic renderer and rejected by checked target preflight;
* archived lifecycle provenance such as `event_msg.token_count`. Source
  controls are retained in an inert session-metadata archive, never replayed as
  target policy. -/

/-- Content-item type for a message text block. Codex authors user turns as
`input_text`, model turns as `output_text`; `importCodexCli` treats all of
`input_text`/`output_text`/`text` identically, so this convention is faithful
but not load-bearing for parity. -/
private def contentType : Role → String
  | .user => "input_text"
  | _ => "output_text"

/-- Role string as Codex spells it on a `response_item.message`. -/
private def codexRole : Role → String
  | .user => "user"
  | .assistant => "assistant"
  | .system => "system"
  | .environment => "assistant"   -- never a plain message (tool output → function_call_output)

/-- Wrap a semantic payload object as a Codex `response_item` stream record. -/
private def respItem (payload : Json) : Json :=
  Json.mkObj [("type", Json.str "response_item"), ("payload", payload)]

private def codexAssistantText (text : String) : Json :=
  respItem (Json.mkObj [
    ("type", Json.str "message"), ("role", Json.str "assistant"),
    ("content", Json.arr #[Json.mkObj [
      ("type", Json.str "output_text"), ("text", Json.str text)]])])

private def codexAssistantCarrier (kind text : String) : Json :=
  respItem (Json.mkObj [
    ("type", Json.str "message"),
    ("role", Json.str "assistant"),
    (codexCarrierMarkerKey, Json.mkObj [
      ("protocol", Json.str codexCarrierProtocol), ("kind", Json.str kind)]),
    ("content", Json.arr #[Json.mkObj [
      ("type", Json.str "output_text"), ("text", Json.str text)]])])

private def onlyObjectKeys (j : Json) (allowed : List String) : Bool :=
  match j with
  | .obj fields => fields.all (fun key _ => allowed.contains key)
  | _ => false

private def codexEncryptedOnlyReasoningRoundTripsNative (raw : Json) : Bool :=
  onlyObjectKeys raw ["type", "id", "summary", "content", "encrypted_content",
    "internal_chat_message_metadata_passthrough"] &&
    ostr raw "type" == some "reasoning" &&
    codexReasoningSummary? raw == some [] &&
    (optionalCodexEncryptedContent? raw).any (fun encrypted => encrypted.isSome) &&
    (match oobj raw "content" with | none | some Json.null => true | _ => false) &&
    (match oobj raw "id" with | none | some (Json.str _) => true | _ => false) &&
    (match oobj raw "internal_chat_message_metadata_passthrough" with
     | none | some (.obj _) => true
     | _ => false)

private def exactImportedReasoningPayload? (t : Transcript) (entryIdx blockIdx : Nat)
    (text : String) (signature : Option String) : Option Json := do
  let entry <- t.entries[entryIdx]?
  guard (entry.origin.format == Format.codexCli)
  let blocks <- match entry.payload with
    | .assistantMsg values => some values
    | _ => none
  match blocks[blockIdx]? with
  | some (.thinking currentText currentSignature) =>
      guard (currentText == text && currentSignature == signature)
  | _ => none
  let extras <- entry.origin.extras
  let raw <- oobj extras "raw_reasoning_payload"
  let summary <- codexReasoningSummary? raw
  let encrypted <- optionalCodexEncryptedContent? raw
  guard (String.intercalate "\n" summary == text && encrypted == signature)
  pure raw

private def exactImportedEncryptedOnlyReasoning? (t : Transcript)
    (entryIdx blockIdx : Nat) (label : String) (raw : Json) : Bool :=
  (t.entries[entryIdx]?).any (fun entry =>
    entry.origin.format == Format.codexCli &&
    entry.origin.sourceRef.startsWith "entry" &&
    (match entry.payload with
     | .assistantMsg blocks =>
         match blocks[blockIdx]? with
         | some (.unmodeled currentLabel currentRaw) =>
             currentLabel == label && currentRaw == raw
         | _ => false
     | _ => false) &&
    label == "codex.reasoning" && ostr raw "type" == some "reasoning" &&
    codexReasoningSummary? raw == some [] &&
    (optionalCodexEncryptedContent? raw).any (fun encrypted => encrypted.isSome))

private def optionalField (j : Json) (key : String) (accepts : Json -> Bool) : Bool :=
  match oobj j key with
  | none => true
  | some value => accepts value

private def isString : Json -> Bool
  | .str _ => true
  | _ => false

private def isBool : Json -> Bool
  | .bool _ => true
  | _ => false

private def isNat : Json -> Bool
  | value => (value.getNat?).toOption.isSome

private def isStringArray : Json -> Bool
  | .arr values => values.all isString
  | _ => false

private def execCommandArgsValid (args : Json) : Bool :=
  onlyObjectKeys args ["cmd", "workdir", "yield_time_ms", "max_output_tokens",
    "shell", "login", "tty", "sandbox_permissions", "justification", "prefix_rule"] &&
  (match ostr args "cmd" with | some cmd => !cmd.isEmpty | none => false) &&
  optionalField args "workdir" isString &&
  optionalField args "yield_time_ms" isNat &&
  optionalField args "max_output_tokens" isNat &&
  optionalField args "shell" isString &&
  optionalField args "login" isBool &&
  optionalField args "tty" isBool &&
  optionalField args "justification" isString &&
  optionalField args "prefix_rule" isStringArray &&
  optionalField args "sandbox_permissions" (fun value =>
    match value with
    | .str policy => policy == "use_default" || policy == "require_escalated"
    | _ => false)

private def planItemValid (item : Json) : Bool :=
  onlyObjectKeys item ["step", "status"] &&
  (match ostr item "step" with | some step => !step.isEmpty | none => false) &&
  (match ostr item "status" with
   | some status => status == "pending" || status == "in_progress" || status == "completed"
   | none => false)

private def updatePlanArgsValid (args : Json) : Bool :=
  onlyObjectKeys args ["explanation", "plan"] &&
  optionalField args "explanation" isString &&
  match oarr args "plan" with
  | some plan => plan.all planItemValid
  | none => false

private def isNativeCodexCall
    (name : ToolName) (args : Json) (rawId : Option String) : Bool :=
  rawId.any (fun id => !id.isEmpty) &&
    ((name.raw == "exec_command" && execCommandArgsValid args) ||
     (name.raw == "update_plan" && updatePlanArgsValid args))

private inductive CodexNativeToolKind where
  | functionCall
  | customToolCall
  deriving DecidableEq

private structure CodexNativeCallEvidence where
  record : Json
  kind : CodexNativeToolKind
  callId : String

/-- Recover executable call evidence only from an unchanged singleton block and
the exact full Codex record retained by this importer. A foreign entry with the
same name and object-shaped arguments has no such evidence. -/
private def exactImportedNativeCallEvidence? (t : Transcript)
    (entryIdx blockIdx : Nat) (name : ToolName) (args : Json)
    (rawId : Option String) : Option CodexNativeCallEvidence := do
  let entry ← t.entries[entryIdx]?
  guard (entry.disposition == EntryDisposition.native)
  guard (entry.origin.format == Format.codexCli)
  match entry.payload with
  | .assistantMsg [.toolCall currentName currentArgs currentRawId] =>
      guard (blockIdx == 0 && currentName.raw == name.raw &&
        currentName.canonical == name.canonical &&
        currentArgs == args && currentRawId == rawId)
  | _ => none
  let callId ← rawId
  guard (!callId.isEmpty)
  let extras ← entry.origin.extras
  let record ← oobj extras codexNativeToolRawRecordKey
  guard (ostr record "type" == some "response_item")
  let payload ← oobj record "payload"
  guard (ostr payload "call_id" == some callId)
  -- Byte-exact replay is only evidence if the retained record still encodes the
  -- CURRENT canonical identity. An IR edit that added or changed it would make
  -- the replayed bytes silently disagree with the typed call, so the record
  -- must be rebuilt by `synthesizedNativeCallEvidence?` instead.
  guard (codexPayloadToolCanonical? payload == name.canonical)
  match ostr payload "type" with
  | some "function_call" =>
      guard (isNativeCodexCall name args rawId)
      guard (ostr payload "name" == some name.raw)
      guard (parseArgsExact? payload == some args)
      pure { record, kind := .functionCall, callId }
  | some "custom_tool_call" =>
      let input ← ostr payload "input"
      guard (name.raw == "apply_patch" && ostr payload "name" == some "apply_patch")
      guard (args == Json.mkObj [("patch", Json.str input)])
      pure { record, kind := .customToolCall, callId }
  | _ => none

private def codexArgsAreObject : Json → Bool
  | .obj _ => true
  | _ => false

/-- Build a native Codex `function_call` from typed IR alone. Structural
validity only; source format is not consulted, `disposition` stays the guard. -/
private def synthesizedNativeCallEvidence? (t : Transcript)
    (entryIdx blockIdx : Nat) (name : ToolName) (args : Json)
    (rawId : Option String) : Option CodexNativeCallEvidence := do
  let entry ← t.entries[entryIdx]?
  guard (entry.disposition == EntryDisposition.native)
  match entry.payload with
  | .assistantMsg blocks =>
      match blocks[blockIdx]? with
      | some (.toolCall currentName currentArgs currentRawId) =>
          guard (currentName.raw == name.raw && currentArgs == args &&
            currentRawId == rawId)
      | _ => none
  | _ => none
  let callId ← rawId
  guard (!callId.isEmpty)
  guard (!name.raw.isEmpty)
  guard (codexArgsAreObject args)
  -- Codex's `function_call` has no slot for Loom's canonical tool identity, but
  -- that is a reason to carry the field out of band, not a reason to refuse the
  -- target's own construct. `codexToolCanonicalFields` adds the reserved
  -- envelope member iff a canonical identity exists, and the Codex importer
  -- reads it straight back; a source that asserts `read`/`bash`/`edit` now gets
  -- BOTH a real `function_call` and its interpretation returned. Codex- and
  -- Claude-origin calls leave `canonical := none`, so they emit exactly the
  -- bytes they emitted before.
  pure {
    record := Json.mkObj [
      ("type", Json.str "response_item"),
      ("payload", Json.mkObj ([
        ("type", Json.str "function_call"),
        ("name", Json.str name.raw),
        ("call_id", Json.str callId),
        ("arguments", Json.str args.compress)] ++
        codexToolCanonicalFields name.canonical))],
    kind := .functionCall, callId }

private def nativeCallEvidence? (t : Transcript)
    (entryIdx blockIdx : Nat) (name : ToolName) (args : Json)
    (rawId : Option String) : Option CodexNativeCallEvidence :=
  (exactImportedNativeCallEvidence? t entryIdx blockIdx name args rawId).orElse
    (fun _ => synthesizedNativeCallEvidence? t entryIdx blockIdx name args rawId)

private def historicalToolCallText
    (entry block : Nat) (name : ToolName) (args : Json) (rawId : Option String) : String :=
  codexHistoricalToolCallCarrierHeader ++ "\n" ++
    (codexHistoricalToolCallV2Json (codexOccurrence entry block)
      rawId name args).compress

private def historicalToolCallV1Text
    (entry block : Nat) (rawName : String) (args : Json)
    (rawId : Option String) : String :=
  codexHistoricalToolCallCarrierHeader ++ "\n" ++
    (codexHistoricalToolCallV1Json (codexOccurrence entry block)
      rawId rawName args).compress

private def historicalUnmodeledText
    (entry block : Nat) (label : String) (raw : Json) : String :=
  let record := Json.mkObj [
    ("carrier", Json.str "agent-convert.codex-unmodeled.v1"),
    ("occurrence", Json.str (codexOccurrence entry block)),
    ("label", Json.str label),
    ("raw", raw),
    ("reason", Json.str codexHistoricalUnmodeledReason)]
  codexHistoricalUnmodeledCarrierHeader ++ "\n" ++ record.compress

private def historicalEnvUnmodeledText
    (entry block : Nat) (label : String) (raw : Json) : String :=
  let record := Json.mkObj [
    ("carrier", Json.str "agent-convert.codex-env-unmodeled.v1"),
    ("occurrence", Json.str (codexOccurrence entry block)),
    ("label", Json.str label),
    ("raw", raw),
    ("reason", Json.str codexHistoricalEnvUnmodeledReason)]
  codexHistoricalEnvUnmodeledCarrierHeader ++ "\n" ++ record.compress

private def historicalSessionBoundaryText (boundary : Json) : String :=
  let record := Json.mkObj [
    ("carrier", Json.str "agent-convert.codex-session-boundary.v1"),
    ("record", boundary),
    ("reason", Json.str codexHistoricalSessionBoundaryReason)]
  codexHistoricalSessionBoundaryCarrierHeader ++ "\n" ++ record.compress

private def historicalEntryText (payload : Payload) : String :=
  let record := Json.mkObj [
    ("carrier", Json.str "agent-convert.codex-entry.v1"),
    ("payload", codexHistoricalPayloadJson payload),
    ("reason", Json.str codexHistoricalEntryReason)]
  codexHistoricalEntryCarrierHeader ++ "\n" ++ record.compress

/-- Recover the Codex `call_id` for a tool result by following its `CallRef`
back to the originating `function_call` entry's `AssistantBlock.toolCall` `rawId` (or,
for an orphan, the unresolved raw id it kept). This is why `rawId`/`CallRef`
live in the IR: same-stream round-trip of the call↔result link. -/
private def callIdOfRef (t : Transcript) : CallRef → Option String
  | .resolved e b =>
      (t.entries[e]?).bind (fun (ent : Loom.Entry) => match ent.payload with
        | Payload.assistantMsg blocks =>
            (blocks[b]?).bind (fun blk => match blk with
              | AssistantBlock.toolCall _ _ rawId => rawId
              | _ => none)
        | _ => none)
  | .unresolved rawId _ => rawId

private def resultOutput (content : List UserBlock) : String :=
  toolOutputText content

private structure CodexNativeResultEvidence where
  record : Json
  kind : CodexNativeToolKind
  callId : String

private def codexResultContentJson (content : List UserBlock) : Json :=
  Json.arr (content.map historicalResultBlockJson).toArray

/-- Exact imported output evidence, independent of whether its call is trusted.
The caller checks linkage and call evidence separately, preventing a copied raw
output record from activating a foreign call. -/
private def exactImportedNativeResultEvidence? (t : Transcript)
    (entryIdx blockIdx : Nat) (cref : CallRef) (content : List UserBlock)
    (error : ErrorSignal) : Option CodexNativeResultEvidence := do
  let entry ← t.entries[entryIdx]?
  guard (entry.disposition == EntryDisposition.native)
  guard (entry.origin.format == Format.codexCli)
  match entry.payload with
  | .envMsg [.toolResult currentRef currentContent currentError] =>
      guard (blockIdx == 0 && decide (currentRef = cref) &&
        codexResultContentJson currentContent == codexResultContentJson content &&
        errorSignalJson currentError == errorSignalJson error)
  | _ => none
  let extras ← entry.origin.extras
  let record ← oobj extras codexNativeToolRawRecordKey
  guard (ostr record "type" == some "response_item")
  let payload ← oobj record "payload"
  let callId ← ostr payload "call_id"
  guard (!callId.isEmpty)
  let parsedContent ← oobj payload "output" >>= codexToolOutputBlocks?
  guard (codexResultContentJson parsedContent == codexResultContentJson content)
  -- A retained record that carries the reserved unrecorded stamp re-imports as
  -- `.unrecorded`; one that does not re-imports as the re-derived `.inferred`.
  -- Either way the expectation is what THIS record will actually produce, so
  -- replaying its bytes cannot disagree with the typed signal.
  let expectedError := if codexPayloadErrorIsUnrecorded payload then
      ErrorSignal.unrecorded
    else ErrorSignal.inferred
      (codexOutputIndicatesError (toolOutputText parsedContent))
      "codexOutputIndicatesError (codexAdapter.ts:75)"
  guard (errorSignalJson error == errorSignalJson expectedError)
  match ostr payload "type" with
  | some "function_call_output" =>
      pure { record, kind := .functionCall, callId }
  | some "custom_tool_call_output" =>
      pure { record, kind := .customToolCall, callId }
  | _ => none

/-- Error VALUE, discarding provenance.

Codex carries error state only in the output text, from which the importer
re-infers it; `recorded` vs `inferred` vs `unrecorded` has no wire slot.
Demanding provenance equality made native emission impossible for any source
whose provenance was not already Codex-shaped — a Claude result arrives as
`.native b` — which is exactly what forced the return leg of
`codex → claude → codex` to prose. The value is preserved exactly; the
provenance normalization is reported, not hidden (`LoomOps.Interop`, P2/P4). -/
private def codexErrorValue : ErrorSignal → Bool
  | .native value => value
  | .inferred value _ => value
  | .unrecorded => false

private def callIdOfRefRaw (t : Transcript) : CallRef → Option String
  | .resolved e b => do
      let ent ← t.entries[e]?
      match ent.payload with
      | .assistantMsg blocks =>
          match blocks[b]? with
          | some (.toolCall _ _ rawId) => rawId
          | _ => none
      | _ => none
  | .unresolved _ _ => none

/-- Result counterpart of `synthesizedNativeCallEvidence?`. All-text content
only: Codex `output` accepts a plain string that reads back as one text block,
so this is exactly reversible. -/
private def synthesizedNativeResultEvidence? (t : Transcript)
    (entryIdx blockIdx : Nat) (cref : CallRef) (content : List UserBlock)
    (error : ErrorSignal) : Option CodexNativeResultEvidence := do
  let entry ← t.entries[entryIdx]?
  guard (entry.disposition == EntryDisposition.native)
  match entry.payload with
  | .envMsg blocks =>
      match blocks[blockIdx]? with
      | some (.toolResult currentRef currentContent _) =>
          guard (decide (currentRef = cref) &&
            codexResultContentJson currentContent == codexResultContentJson content)
      | _ => none
  | _ => none
  -- Text blocks only, but ANY number of them: each becomes its own
  -- `output_text` item in Codex's array output form, which `codexToolOutputItem?`
  -- reads back one-for-one. Block boundaries are therefore preserved exactly —
  -- `["ab","c"]` and `["a","bc"]` stay distinct rather than both flattening to
  -- "abc", which a joined string would do. Media and `.unmodeled` members keep
  -- the carrier, since neither has a faithful Codex output item here.
  let texts ← content.mapM (fun block =>
    match block with
    | .text text => some text
    | _ => none)
  guard (!texts.isEmpty)
  -- Native emission must never CHANGE an error flag. Codex stores error state
  -- only in the output text, and re-import re-derives it with
  -- `codexOutputIndicatesError`. If the source's error value disagrees with what
  -- that heuristic will produce, emitting natively silently flips the flag — a
  -- result the source marked failed comes back clean. `LoomOps.Interop` rates
  -- that `corrupting` ("an error flag the source never set"), not merely lossy,
  -- so declining native emission and keeping the reversible carrier is correct.
  -- Only the PROVENANCE may normalize here (P2/P4); the value may not.
  -- `exactImportedNativeResultEvidence?` enforces the stricter form — full
  -- signal equality — because a retained Codex record must replay byte for byte;
  -- synthesis only has to preserve the fact.
  --
  -- `.unrecorded` is the one signal with no value to preserve, so it does not
  -- normalize: `codexResultErrorFields` stamps it into the reserved envelope
  -- below rather than letting re-import manufacture `.inferred false` out of
  -- the output text. The value guard still applies to it via `codexErrorValue`,
  -- which keeps an unrecorded result whose text READS as a failure on the
  -- carrier instead of quietly disagreeing with the stamp.
  guard (codexErrorValue error == codexOutputIndicatesError (toolOutputText content))
  let callId ← callIdOfRefRaw t cref
  guard (!callId.isEmpty)
  pure {
    record := Json.mkObj [
      ("type", Json.str "response_item"),
      ("payload", Json.mkObj ([
        ("type", Json.str "function_call_output"),
        ("call_id", Json.str callId),
        ("output", match texts with
          -- One block re-imports identically from the compact string form, and
          -- that is what a genuine single-output Codex record looks like.
          | [single] => Json.str single
          | _ => Json.arr (texts.map (fun text => Json.mkObj [
              ("type", Json.str "output_text"), ("text", Json.str text)])).toArray)] ++
        codexResultErrorFields error))],
    kind := .functionCall, callId }

private def nativeResultEvidence? (t : Transcript)
    (entryIdx blockIdx : Nat) (cref : CallRef) (content : List UserBlock)
    (error : ErrorSignal) : Option CodexNativeResultEvidence :=
  (exactImportedNativeResultEvidence? t entryIdx blockIdx cref content error).orElse
    (fun _ => synthesizedNativeResultEvidence? t entryIdx blockIdx cref content error)

private def codexRawCallIdCount (t : Transcript) (rawId : String) : Nat :=
  t.entries.toList.foldl (fun total entry =>
    total + match entry.payload with
      | .assistantMsg blocks => blocks.countP (fun
          | .toolCall _ _ (some candidate) => candidate == rawId
          | _ => false)
      | _ => 0) 0

private def nativeCallHasExactResult (t : Transcript) (entryIdx blockIdx : Nat)
    (call : CodexNativeCallEvidence) : Bool :=
  let resultMatches := t.entries.toList.zipIdx.flatMap (fun (entry, resultEntryIdx) =>
    match entry.payload with
    | .envMsg blocks => blocks.zipIdx.filterMap (fun (block, resultBlockIdx) =>
        match block with
        | .toolResult (.resolved e b) content error =>
            if e == entryIdx && b == blockIdx then
              nativeResultEvidence? t resultEntryIdx resultBlockIdx
                (.resolved e b) content error
            else none
        | _ => none)
    | _ => [])
  match resultMatches with
  | [result] => result.callId == call.callId && result.kind == call.kind
  | _ => false

private def nativeCallRecordAt? (t : Transcript) (entryIdx blockIdx : Nat)
    (name : ToolName) (args : Json) (rawId : Option String) : Option Json := do
  let evidence ← nativeCallEvidence? t entryIdx blockIdx name args rawId
  guard (codexRawCallIdCount t evidence.callId == 1)
  guard (nativeCallHasExactResult t entryIdx blockIdx evidence)
  pure evidence.record

private def nativeCallAt (t : Transcript) (entryIdx blockIdx : Nat)
    (name : ToolName) (args : Json) (rawId : Option String) : Bool :=
  (nativeCallRecordAt? t entryIdx blockIdx name args rawId).isSome

private def nativeCallIdOfRef (t : Transcript) : CallRef → Option String
  | .resolved e b => do
      let ent ← t.entries[e]?
      match ent.payload with
      | .assistantMsg blocks =>
          match blocks[b]? with
          | some (.toolCall name args rawId) =>
              if nativeCallAt t e b name args rawId then rawId else none
          | _ => none
      | _ => none
  | .unresolved _ _ => none

private def nativeResultRecordAt? (t : Transcript) (entryIdx blockIdx : Nat)
    (cref : CallRef) (content : List UserBlock) (error : ErrorSignal) : Option Json := do
  let result ← nativeResultEvidence? t entryIdx blockIdx cref content error
  let (callEntryIdx, callBlockIdx) ← match cref with
    | .resolved entry block => some (entry, block)
    | .unresolved _ _ => none
  let callEntry ← t.entries[callEntryIdx]?
  let (name, args, rawId) ← match callEntry.payload with
    | .assistantMsg blocks => match blocks[callBlockIdx]? with
      | some (.toolCall name args rawId) => some (name, args, rawId)
      | _ => none
    | _ => none
  let call ← nativeCallEvidence? t callEntryIdx callBlockIdx name args rawId
  guard (call.callId == result.callId && call.kind == result.kind)
  guard (nativeCallAt t callEntryIdx callBlockIdx name args rawId)
  pure result.record

/-- Target-policy census used by the CLI summary. These counts deliberately
reuse the exact predicates that choose native records versus historical text;
counting raw IR constructors would misreport downgraded foreign tools as native. -/
def codexNativeToolCallCount (t : Transcript) : Nat :=
  t.entries.toList.zipIdx.foldl (fun total (entry, entryIdx) =>
    total + match entry.payload with
      | .assistantMsg blocks => blocks.zipIdx.countP (fun (block, blockIdx) =>
          match block with
          | .toolCall name args rawId => nativeCallAt t entryIdx blockIdx name args rawId
          | _ => false)
      | _ => 0) 0

def codexHistoricalToolCallCount (t : Transcript) : Nat :=
  t.entries.toList.foldl (fun total entry =>
    total + match entry.payload with
      | .assistantMsg blocks => blocks.countP (fun
          | .toolCall _ _ _ => true
          | _ => false)
      | _ => 0) 0 - codexNativeToolCallCount t

def codexNativeToolResultCount (t : Transcript) : Nat :=
  t.entries.toList.zipIdx.foldl (fun total (entry, entryIdx) =>
    total + match entry.payload with
      | .envMsg blocks => blocks.zipIdx.countP (fun (block, blockIdx) =>
          match block with
          | .toolResult callRef content error =>
              (nativeResultRecordAt? t entryIdx blockIdx callRef content error).isSome
          | _ => false)
      | _ => 0) 0

def codexHistoricalToolResultCount (t : Transcript) : Nat :=
  t.entries.toList.foldl (fun total entry =>
    total + match entry.payload with
      | .envMsg blocks => blocks.countP (fun
          | .toolResult _ _ _ => true
          | _ => false)
      | _ => 0) 0 - codexNativeToolResultCount t

private def carrierCallRefJson (t : Transcript) : CallRef -> Json
  | .resolved entry block => Json.mkObj [
      ("kind", Json.str "resolved"),
      ("occurrence", Json.str (codexOccurrence entry block)),
      ("rawId", (callIdOfRef t (.resolved entry block)).map Json.str |>.getD Json.null)]
  | .unresolved rawId note => Json.mkObj [
      ("kind", Json.str "unresolved"),
      ("rawId", rawId.map Json.str |>.getD Json.null),
      ("note", Json.str note)]

private def historicalToolResultText (t : Transcript) (entry block : Nat) (cref : CallRef)
    (content : List UserBlock) (error : ErrorSignal) : String :=
  let record := Json.mkObj [
    ("carrier", Json.str "agent-convert.codex-tool-result.v1"),
    ("occurrence", Json.str (codexOccurrence entry block)),
    ("id", (callIdOfRef t cref).map Json.str |>.getD Json.null),
    ("call", carrierCallRefJson t cref),
    ("output", Json.str (resultOutput content)),
    ("content", Json.arr (content.map historicalResultBlockJson).toArray),
    ("isError", errorSignalBoolJson error),
    ("error", errorSignalJson error),
    ("errorProvenance", Json.str (errorSignalProvenance error))]
  codexHistoricalToolResultCarrierHeader ++ "\n" ++
    record.compress

private def codexContentItemRemainsUnmodeled (raw : Json) : Bool :=
  match ostr raw "type" with
  | some kind =>
      if isCodexTextType kind then (ostr raw "text").isNone
      else if kind == "input_image" then (codexImageRef? raw).isNone
      else true
  | none => true

private def assistantMessageContentItem? : AssistantBlock → Option Json
  | .text text => some (Json.mkObj [
      ("type", Json.str (contentType .assistant)), ("text", Json.str text)])
  | .media mime locator =>
      if mime == "image" && codexImageLocatorValid locator then
        some (Json.mkObj [
          ("type", Json.str "input_image"), ("image_url", Json.str locator)])
      else none
  | .unmodeled label raw =>
      if label == codexMessageContentLabel && codexContentItemRemainsUnmodeled raw
      then some raw else none
  | .thinking _ _ | .toolCall _ _ _ => none

private def codexAssistantMessageRecord (content : Array Json) : Json :=
  respItem (Json.mkObj [
    ("type", Json.str "message"),
    ("role", Json.str (codexRole .assistant)),
    ("content", Json.arr content)])

private def assistantStandaloneRecord? (t : Transcript) (entryIdx blockIdx : Nat) :
    AssistantBlock → Option Json
  | .toolCall name args rawId =>
      match nativeCallRecordAt? t entryIdx blockIdx name args rawId with
      | some record => some record
      | none => some (codexAssistantCarrier "tool_call"
          (historicalToolCallText entryIdx blockIdx name args rawId))
  | .thinking text signature =>
      match exactImportedReasoningPayload? t entryIdx blockIdx text signature with
      | some raw => some (respItem raw)
      | none =>
          -- `encrypted_content` is OpenAI provider ciphertext. Only
          -- Codex-origin signatures may occupy that slot. Foreign signatures
          -- (Claude/Pi/…) are not decryptable by the Responses API and break
          -- resume with `invalid_encrypted_content`.
          let encrypted :=
            match t.entries[entryIdx]? with
            | some entry =>
                if entry.origin.format == Format.codexCli then signature else none
            | none => none
          if text.isEmpty && encrypted.isNone then none
          else some (respItem (Json.mkObj ([
              ("type", Json.str "reasoning"),
              ("summary", Json.arr #[Json.mkObj [
                ("type", Json.str "summary_text"), ("text", Json.str text)]])] ++
              (match encrypted with
               | some value => [("encrypted_content", Json.str value)]
               | none => []))))
  | .unmodeled label raw =>
      if label == codexMessageContentLabel && codexContentItemRemainsUnmodeled raw then none
      else if exactImportedEncryptedOnlyReasoning? t entryIdx blockIdx label raw ||
          (label == "codex.reasoning" &&
            codexEncryptedOnlyReasoningRoundTripsNative raw) then some (respItem raw)
      else some (codexAssistantCarrier "unmodeled"
          (historicalUnmodeledText entryIdx blockIdx label raw))
  | .text _ | .media _ _ => none

/-- Preserve assistant block order while grouping each maximal run of native
message-content blocks into one Codex message. This retains the source grouping
for ordinary multi-block assistant messages without moving calls or reasoning. -/
private def assistantBlocksToRecords (t : Transcript) (entryIdx : Nat)
    (blocks : List AssistantBlock) : List Json := Id.run do
  let mut records : Array Json := #[]
  let mut pendingContent : Array Json := #[]
  for (block, blockIdx) in blocks.zipIdx do
    match assistantMessageContentItem? block with
    | some content => pendingContent := pendingContent.push content
    | none =>
        if !pendingContent.isEmpty then
          records := records.push (codexAssistantMessageRecord pendingContent)
          pendingContent := #[]
        match assistantStandaloneRecord? t entryIdx blockIdx block with
        | some record => records := records.push record
        | none => pure ()
  if !pendingContent.isEmpty then
    records := records.push (codexAssistantMessageRecord pendingContent)
  return records.toList

/-- Existing exact call/result/unmodeled carriers retain their specialized
shape for same-format E-I-E. Every other historical payload uses one generic
typed-payload carrier, preventing messages, reasoning, events, and compactions
from entering Codex's native semantic channel or disappearing. -/
private def historicalPayloadUsesSpecializedCarrier : Payload -> Bool
  | .assistantMsg [.toolCall _ _ _] => true
  | .assistantMsg [.unmodeled label _] =>
      label != codexMessageContentLabel && label != "codex.reasoning"
  | .envMsg [.toolResult _ _ _] => true
  | .envMsg [.unmodeled _ _] => true
  | _ => false

private def historicalEntryRecord (payload : Payload) : Json :=
  codexAssistantCarrier "entry" (historicalEntryText payload)

/-- Recover the complete native checkpoint only when it came through the Codex
importer and still agrees with Loom's typed projection. Coverage and token count
have no 0.144.1 compacted fields, so non-default typed values cannot be replayed
without loss. -/
private def exactImportedCompactionPayload? (entry : Entry) : Option Json := do
  guard (entry.disposition == EntryDisposition.native)
  guard (entry.origin.format == Format.codexCli)
  guard (entry.origin.sourceRef.startsWith "entry")
  let summary <- match entry.payload with
    | .compaction summary .unknownPrefix none => some summary
    | _ => none
  let extras <- entry.origin.extras
  let raw <- oobj extras codexCompactionRawRecordKey
  guard (codexCompactedRecordValid raw)
  let payload <- oobj raw "payload"
  guard (ostr payload "message" == some summary)
  pure payload

/-- Public per-entry preflight predicate for Codex compaction export. Historical
entries are representable by the inert typed carrier; Codex-origin native
entries require an exact compatible checkpoint and can never be synthesized
from a summary alone. Foreign native compaction (Claude/Pi/etc.) is retained
via the same historical carrier — the exporter already emits
`historicalEntryRecord` when no exact Codex checkpoint is present. -/
def codexCompactionEntryExportable (entry : Entry) : Bool :=
  match entry.payload with
  | .compaction _ _ _ =>
      entry.disposition == EntryDisposition.historicalUnverified ||
        (exactImportedCompactionPayload? entry).isSome ||
        entry.origin.format != Format.codexCli
  | _ => true

/-- Transcript-level compaction preflight used by the checked exporter and
conversion policy. -/
def codexTargetCompactionsValid (t : Transcript) : Bool :=
  t.entries.all codexCompactionEntryExportable

def codexCompactionPreflightError : String :=
  "Codex target native compaction requires an exact 0.144.1 compacted record with replacement_history and encrypted compaction signature provenance"

/-- Render one IR entry to its Codex `response_item` record(s). Text blocks of a
message collapse into a single `message` record; each tool call / thinking /
tool result becomes its own record (Codex's one-item-per-record stream). -/
private def entryToRecords (t : Transcript) (entryIdx : Nat) (e : Entry) : List Json :=
  if e.disposition == EntryDisposition.historicalUnverified &&
      !historicalPayloadUsesSpecializedCarrier e.payload then
    [historicalEntryRecord e.payload]
  else match e.payload with
  | Payload.userMsg blocks =>
      match blocks with
      | [.unmodeled label raw] =>
          if label == "codex.message" then [respItem raw]
          else
            let contentItems := if label == codexMessageContentLabel then [raw] else []
            if contentItems.isEmpty then []
            else [respItem (Json.mkObj [("type", Json.str "message"),
              ("role", Json.str (codexRole .user)),
              ("content", Json.arr contentItems.toArray)])]
      | _ =>
          let contentItems := blocks.filterMap (fun (b : UserBlock) => match b with
            | UserBlock.text s =>
                some (Json.mkObj [("type", Json.str (contentType .user)), ("text", Json.str s)])
            | UserBlock.media mime loc =>
                if mime == "image" && codexImageLocatorValid loc then
                  some (Json.mkObj [
                    ("type", Json.str "input_image"), ("image_url", Json.str loc)])
                else none
            | UserBlock.unmodeled label raw =>
                if label == codexMessageContentLabel then some raw else none)
          if contentItems.isEmpty then []
          else [respItem (Json.mkObj [("type", Json.str "message"),
                  ("role", Json.str (codexRole .user)),
                  ("content", Json.arr contentItems.toArray)])]
  | Payload.assistantMsg blocks =>
      assistantBlocksToRecords t entryIdx blocks
  | Payload.envMsg blocks =>
      blocks.zipIdx.filterMap (fun (b, blockIdx) => match b with
        | EnvBlock.toolResult cref content error =>
            match nativeResultRecordAt? t entryIdx blockIdx cref content error with
            | some record => some record
            | none => some (codexAssistantCarrier "tool_result"
                (historicalToolResultText t entryIdx blockIdx cref content error))
        | EnvBlock.unmodeled label raw =>
            some (codexAssistantCarrier "environment_unmodeled"
              (historicalEnvUnmodeledText entryIdx blockIdx label raw)))
  | Payload.otherMsg roleLabel blocks =>
      let textItems := blocks.filterMap (fun b => match b with
        | UserBlock.text s =>
            some (Json.mkObj [("type", Json.str (contentType .assistant)), ("text", Json.str s)])
        | _ => none)
      if textItems.isEmpty then []
      else [respItem (Json.mkObj [("type", Json.str "message"),
              ("role", Json.str roleLabel),
              ("content", Json.arr textItems.toArray)])]
  | Payload.compaction _ _ _ =>
      match exactImportedCompactionPayload? e with
      | some payload => [Json.mkObj [
          ("type", Json.str "compacted"), ("payload", payload)]]
      | none => [historicalEntryRecord e.payload]
  | Payload.event e =>
      -- Content-bearing events (`error`) ARE re-emitted: they have no display twin
      -- (unlike the user/agent `event_msg` duplicates we deliberately drop), and
      -- `MetaEvent.custom` kept the original payload, so re-import reconstructs the
      -- same event with no dedup pair introduced. Structured events have no native
      -- Codex record, so retain them in the exact typed historical-entry carrier.
      match e with
      | MetaEvent.custom _ raw => [Json.mkObj [("type", Json.str "event_msg"), ("payload", raw)]]
      | _ => [historicalEntryRecord (Payload.event e)]

/-- Historical source controls and source identity travel only in an inert
session-metadata extension. Re-import restores them to provenance; it never
replays them as `turn_context` or conversational records. -/
private def transcriptSourceArchive? (t : Transcript) : Option CodexSourceArchive := do
  let extras <- t.origin.extras
  let sourceSessionPayload? := oobj extras "raw_session_meta_payload"
  let sourceControls := (oarr extras "raw_control_messages").getD #[]
  let generatedTargetControls :=
    (oarr extras "raw_generated_target_controls").getD #[]
  let sourceSessionPayload := sourceSessionPayload?.getD
    (match t.env.instructions with
     | some instructions => Json.mkObj [("instructions", Json.str instructions)]
     | none => Json.mkObj [])
  match sourceSessionPayload with
  | .obj _ => pure ()
  | _ => none
  let sourceIdentity := codexSourceIdentityJson sourceSessionPayload
  match sourceIdentity with
  | .obj _ => pure ()
  | _ => none
  pure (CodexSourceArchive.mk sourceSessionPayload sourceIdentity t.env sourceControls
    generatedTargetControls)

/-- Only a Codex import can authorize positional boundary metadata. A foreign
transcript that happens to carry a lookalike origin-extra object cannot make the
exporter stamp and activate a session-boundary carrier. -/
private def transcriptSessionBoundaries (t : Transcript) : List CodexSessionBoundary :=
  if t.origin.format != Format.codexCli then []
  else
    (t.origin.extras >>= fun extras => oarr extras "raw_session_boundaries")
      |>.map (fun values => values.toList.filterMap parseCodexSessionBoundary?)
      |>.getD []

private def sourceLineageFields (identity : Json) : List (String × Json) :=
  ["session_id", "parent_thread_id", "forked_from_id", "thread_source", "source"].filterMap
    (fun key => (oobj identity key).map (key, ·))

private def codexNonempty (value : Option String) : Option String :=
  value.bind (fun text => if text.isEmpty then none else some text)

private def codexTranscriptExtra (t : Transcript) (key : String) : Option String :=
  t.origin.extras >>= fun extras => ostr extras key

private def codexTargetTimestamp? (t : Transcript) : Option String :=
  codexNonempty (codexTranscriptExtra t "target_timestamp")

private def codexTargetSessionId? (t : Transcript) : Option String :=
  codexNonempty (codexTranscriptExtra t "target_session_id")

private def codexTargetCwd? (t : Transcript) : Option String :=
  codexNonempty (codexTranscriptExtra t "target_cwd")

private def codexTargetModel? (t : Transcript) : Option String :=
  codexNonempty (codexTranscriptExtra t "target_model")

private def codexTargetCliVersion? (t : Transcript) : Option String :=
  codexNonempty (codexTranscriptExtra t "target_harness_version")

private def codexTargetOriginator? (t : Transcript) : Option String :=
  codexNonempty (codexTranscriptExtra t "target_originator") <|> some "agent-convert"

private def codexTargetProvider? (t : Transcript) : Option String :=
  codexNonempty (codexTranscriptExtra t "target_provider")

private def codexRawContentItemMediaValid (raw : Json) : Bool :=
  if ostr raw "type" == some "input_image" then (codexImageRef? raw).isSome
  else true

private def codexRawMessageMediaValid (raw : Json) : Bool :=
  if ostr raw "type" != some "message" then true
  else (oarr raw "content").any (fun content =>
    content.all codexRawContentItemMediaValid)

private def codexUserBlockMediaValid : UserBlock -> Bool
  | .media mime locator => mime == "image" && codexImageLocatorValid locator
  | .unmodeled label raw =>
      if label == "codex.message" then codexRawMessageMediaValid raw
      else if label == codexMessageContentLabel then
        codexRawContentItemMediaValid raw
      else true
  | .text _ => true

def codexTargetMediaValid (t : Transcript) : Bool :=
  t.entries.toList.all (fun entry =>
    match entry.payload with
    | .userMsg blocks => blocks.all codexUserBlockMediaValid
    | .otherMsg _ blocks => blocks.all (fun
        | .media _ _ => false
        | block => codexUserBlockMediaValid block)
    | .assistantMsg blocks => blocks.all (fun
        | AssistantBlock.media mime locator =>
            mime == "image" && codexImageLocatorValid locator
        | AssistantBlock.unmodeled label raw =>
            if label == codexMessageContentLabel then
              codexRawContentItemMediaValid raw
            else true
        | _ => true)
    | .envMsg blocks => blocks.all (fun
        | .toolResult _ content _ => content.all codexUserBlockMediaValid
        | .unmodeled _ _ => true)
    | .compaction _ _ _ | .event _ => true)

/-- Codex is a single linear rollout and has no branch-selection field. A
resumable target can therefore preserve Loom's selection only when a nonempty
transcript selects its final entry (or when an empty transcript selects none). -/
def codexTargetActiveLeafValid (t : Transcript) : Bool :=
  if t.entries.isEmpty then t.activeLeaf.isNone
  else t.activeLeaf == some (t.entries.size - 1)

def codexActiveLeafPreflightError : String :=
  "Codex target requires activeLeaf to select the final entry of the linear rollout"

/-- Preconditions for a fresh, resumable Codex 0.144.1 artifact. This is the
public refusal surface used by conversion policy: every missing or foreign
field is named, and no identity/model/version is silently synthesized. -/
def codexTargetExportPrerequisiteFailures (t : Transcript) : List String :=
  let timestampFailure := match codexTargetTimestamp? t with
    | none => ["Codex target requires explicit origin.extras.target_timestamp"]
    | some timestamp => if (iso8601ToEpochMs? timestamp).isSome then [] else
        ["Codex target_timestamp must be UTC ISO-8601 with seconds or millisecond precision"]
  let idFailure := match codexTargetSessionId? t with
    | none => ["Codex target requires explicit origin.extras.target_session_id"]
    | some id => if codexUuidValid id then [] else
        ["Codex target_session_id must be a UUID"]
  let cwdFailure := match codexTargetCwd? t with
    | none => ["Codex target requires explicit origin.extras.target_cwd"]
    | some cwd => if codexAbsolutePathValid cwd then [] else
        ["Codex target_cwd must be an absolute path"]
  let modelFailure := match codexTargetModel? t with
    | some _ => []
    | none => ["Codex target requires explicit origin.extras.target_model"]
  let providerFailure := match codexTargetProvider? t with
    | some _ => []
    | none => ["Codex target requires explicit origin.extras.target_provider"]
  let versionFailure := match codexTargetCliVersion? t with
    | some version => if version == codexCliTargetVersion then [] else
        [s!"Codex target_harness_version must be {codexCliTargetVersion}"]
    | none => [s!"Codex target requires explicit origin.extras.target_harness_version {codexCliTargetVersion}"]
  let originatorFailure := match codexTargetOriginator? t with
    | some _ => []
    | none => ["Codex target requires a nonempty originator"]
  let mediaFailure := if codexTargetMediaValid t then [] else
    ["Codex target media must use mime 'image' and a valid inline base64 image data URI"]
  let compactionFailure := if codexTargetCompactionsValid t then [] else
    [codexCompactionPreflightError]
  let activeLeafFailure := if codexTargetActiveLeafValid t then [] else
    [codexActiveLeafPreflightError]
  let controlsFailure := match codexTargetControlsRaw? t with
    | none => [s!"Codex target requires explicit origin.extras.{codexTargetControlsKey}"]
    | some _ => if (codexTargetControls? t).isSome then [] else
        [s!"origin.extras.{codexTargetControlsKey} must be an exact {codexTargetControlsProtocol} object"]
  timestampFailure ++ idFailure ++ cwdFailure ++ modelFailure ++
  providerFailure ++ versionFailure ++ originatorFailure ++ mediaFailure ++
  compactionFailure ++ activeLeafFailure ++ controlsFailure

def codexTargetExportReady (t : Transcript) : Bool :=
  (codexTargetExportPrerequisiteFailures t).isEmpty

private def codexTargetSourceArchive (t : Transcript) : CodexSourceArchive :=
  (transcriptSourceArchive? t).getD {
    sourceSessionPayload := Json.mkObj []
    sourceIdentity := Json.mkObj []
    sourceEnv := t.env
    sourceControls := #[]
    generatedTargetControls := #[] }

/-- Line 0: reconstruct the `session_meta` record from `EnvInfo` + `Origin`.
For an ordinary same-format round-trip, native lineage fields are retained;
fresh target sessions keep source identity only in the inert archive. -/
private def sessionMetaJson (t : Transcript) (carrierProtocolStamp : Bool := false) : Json :=
  let requestedTargetTimestamp := codexTargetTimestamp? t
  let firstRecordedTimestamp := t.entries.toList.findSome? (fun entry =>
    recordedTimeIso8601? entry.time)
  let timestamp := requestedTargetTimestamp <|>
    codexNonempty (codexTranscriptExtra t "session_timestamp") <|> firstRecordedTimestamp
  let targetExport := requestedTargetTimestamp.isSome
  let idStr := if targetExport then (codexTargetSessionId? t).getD ""
    else codexNonempty t.env.sessionId |>.getD
      (codexNonempty t.origin.rawId |>.getD "")
  let sourceArchive := if targetExport then some (codexTargetSourceArchive t)
    else transcriptSourceArchive? t
  let lineageFields := if targetExport then [] else
    sourceArchive.map (sourceLineageFields ·.sourceIdentity) |>.getD []
  let cliVersion := if targetExport then codexTargetCliVersion? t
    else codexNonempty t.env.harnessVersion
  let originator := if targetExport then codexTargetOriginator? t
    else codexNonempty (codexTranscriptExtra t "originator")
  let provider := if targetExport then codexTargetProvider? t
    else codexNonempty (codexTranscriptExtra t "model_provider") <|>
      codexNonempty t.env.provider
  let cwd := if targetExport then codexTargetCwd? t else t.env.cwd
  let fields : List (String × Json) :=
    [("id", Json.str idStr)]
    ++ (if targetExport then [("session_id", Json.str idStr)] else [])
    ++ lineageFields
    ++ (match timestamp with | some ts => [("timestamp", Json.str ts)] | none => [])
    ++ (match cwd with | some c => [("cwd", Json.str c)] | none => [])
    ++ (match cliVersion with | some v => [("cli_version", Json.str v)] | none => [])
    ++ (if targetExport then [] else
        [("instructions", Json.str (t.env.instructions.getD ""))])
    ++ (match originator with | some o => [("originator", Json.str o)] | none => [])
    ++ (match provider with | some m => [("model_provider", Json.str m)] | none => [])
    ++ (if carrierProtocolStamp then [(codexCarrierMarkerKey, Json.mkObj [
          ("protocol", Json.str codexCarrierProtocol), ("kind", Json.str "session")])]
        else [])
    ++ (match sourceArchive with
        | some archive => [(codexSourceArchiveKey, codexSourceArchiveJson archive)]
        | none => [])
    ++ (if targetExport then [("source", Json.str "cli"), ("git", Json.null)] else [])
  Json.mkObj ((match timestamp with | some ts => [("timestamp", Json.str ts)] | none => []) ++
    [("type", Json.str "session_meta"), ("payload", Json.mkObj fields)])

private def targetTurnContextJson? (t : Transcript) : Option Json := do
  let extras ← t.origin.extras
  let timestamp ← ostr extras "target_timestamp"
  let cwd ← codexTargetCwd? t
  let model ← codexTargetModel? t
  let controls ← codexTargetControls? t
  let preserved := if t.origin.format != Format.codexCli then none else
    (oobj extras "target_turn_context_record").bind (fun record => do
      let payload <- oobj record "payload"
      guard (ostr record "type" == some "turn_context")
      guard (ostr record "timestamp" == some timestamp)
      guard (codexGeneratedTargetDefaultsMarkerExact payload)
      guard (ostr payload "cwd" == some cwd && ostr payload "model" == some model)
      guard (ostr payload "approval_policy" == some controls.approvalPolicy)
      guard (oobj payload "sandbox_policy" == some controls.sandboxPolicy)
      guard (ostr payload "summary" == some controls.summary)
      pure record)
  match preserved with
  | some record => some record
  | none =>
      let payload := Json.mkObj [
        ("cwd", Json.str cwd),
        (codexCarrierMarkerKey, codexMarker codexGeneratedTargetDefaultsKind),
        ("provenance", Json.str
          "explicit target controls from origin.extras.target_codex_controls"),
        ("approval_policy", Json.str controls.approvalPolicy),
        ("sandbox_policy", controls.sandboxPolicy),
        ("model", Json.str model),
        ("summary", Json.str controls.summary)]
      some (Json.mkObj [
        ("timestamp", Json.str timestamp),
        ("type", Json.str "turn_context"),
        ("payload", payload)])

private def stampTargetTimestamp (timestamp : String) : Json -> Json
  | .obj fields => .obj (fields.insert "timestamp" (Json.str timestamp))
  | json => json

private def stampCodexTimeProvenance (entry : Entry) : Json -> Json
  | .obj fields =>
      let sourceTimestamp := entry.origin.extras.bind (fun extras => ostr extras "ts")
      match codexTimeProvenanceJson? entry.time sourceTimestamp with
      | some provenance => .obj (fields.insert codexTimeProvenanceKey provenance)
      | none => .obj fields
  | json => json

/-- A recorded epoch is the source fact and always wins over a stale/raw
format extra. Non-recorded states use the explicit launch timestamp for a fresh
target; their source state remains in `codexTimeProvenanceKey`. -/
private def codexEntryTimestamp? (t : Transcript) (entry : Entry) : Option String :=
  match entry.time with
  | .recorded timestamp => some (epochMsToIso8601 timestamp)
  | .absent | .interpolated _ _ | .sequenced _ =>
      codexTargetTimestamp? t <|>
        entry.origin.extras.bind (fun extras => ostr extras "ts")

/-- Current Codex persists text turns twice: `response_item.message` is the
semantic/model channel and `event_msg` is the TUI display channel. Restore the
display twin only for a fresh target-session export. Non-text content remains on
the semantic channel; an empty twin would add no readable information. -/
private def targetDisplayTwin? (record : Json) : Option Json := do
  let timestamp <- ostr record "timestamp"
  guard (ostr record "type" == some "response_item")
  let payload <- oobj record "payload"
  guard (ostr payload "type" == some "message")
  guard (codexCarrierKind? payload != some "session_boundary")
  let role <- ostr payload "role"
  let content <- oarr payload "content"
  let text := String.intercalate "" (content.toList.filterMap (fun block =>
    match ostr block "type", ostr block "text" with
    | some kind, some value => if isCodexTextType kind then some value else none
    | _, _ => none))
  guard (!text.isEmpty)
  let eventPayload <-
    if role == "user" then
      some (Json.mkObj [
        ("type", Json.str "user_message"),
        ("message", Json.str text),
        ("images", Json.arr #[]),
        ("local_images", Json.arr #[]),
        ("text_elements", Json.arr #[])])
    else if role == "assistant" then
      some (Json.mkObj [
        ("type", Json.str "agent_message"),
        ("message", Json.str text),
        ("phase", Json.str "final_answer"),
        ("memory_citation", Json.null)])
    else none
  let timeProvenance := match oobj record codexTimeProvenanceKey with
    | some provenance => [(codexTimeProvenanceKey, provenance)]
    | none => []
  some (Json.mkObj ([
    ("timestamp", Json.str timestamp),
    ("type", Json.str "event_msg"),
    ("payload", eventPayload)] ++ timeProvenance))

private def sessionBoundaryCarrierRecord (boundary : CodexSessionBoundary) : Json :=
  let carrier := codexAssistantCarrier "session_boundary"
    (historicalSessionBoundaryText boundary.record)
  match ostr boundary.record "timestamp" with
  | some timestamp => stampTargetTimestamp timestamp carrier
  | none => carrier

/-- Keep HTML-like source wrappers out of the JSONL byte stream without changing
their string values. Standard JSON decoding restores the exact angle brackets,
so source provenance remains lossless while byte-oriented renderers cannot
mistake archived control markup for target-visible formatting. -/
private def codexJsonLine (json : Json) : String :=
  codexCanonicalJsonLine json

/-- Semantic records for one source entry, including any lifecycle boundary
which precedes it. Keeping this grouping explicit lets checked validation locate
the selected entry's exact materialized start instead of guessing from a tail
length. -/
private def codexSemanticRecordsForEntry (t : Transcript)
    (boundaries : List CodexSessionBoundary) (entryIdx : Nat)
    (entry : Entry) : List Json :=
  let records := (entryToRecords t entryIdx entry).map
    (stampCodexTimeProvenance entry)
  let boundaryRecords := boundaries.filterMap (fun boundary =>
    if boundary.beforeEntry == entryIdx
    then some (sessionBoundaryCarrierRecord boundary) else none)
  match codexEntryTimestamp? t entry with
  | some value => boundaryRecords ++ records.map (stampTargetTimestamp value)
  | none => boundaryRecords ++ records

private def codexSemanticEntryRecordsBefore
    (t : Transcript) (entryLimit : Nat) : List Json :=
  let boundaries := transcriptSessionBoundaries t
  (t.entries.toList.zipIdx.take entryLimit).flatMap (fun (entry, entryIdx) =>
    codexSemanticRecordsForEntry t boundaries entryIdx entry)

/-- Semantic records before generated display twins. The renderer and checked
materialization use this exact grouping and carrier-protocol decision. -/
private def codexSemanticRecords (t : Transcript) : List Json :=
  let entries := t.entries.toList.zipIdx
  let boundaries := transcriptSessionBoundaries t
  entries.flatMap (fun (entry, entryIdx) =>
      codexSemanticRecordsForEntry t boundaries entryIdx entry) ++
    boundaries.filterMap (fun boundary =>
      if boundary.beforeEntry >= entries.length
      then some (sessionBoundaryCarrierRecord boundary) else none)

private def codexRecordsUseCarrierProtocol (records : List Json) : Bool :=
  records.any (fun record =>
    (oobj record "payload").any codexCarrierMarkerPresent ||
      (oobj record codexTimeProvenanceKey).isSome)

private def codexTargetRecordsFromSemantic
    (t : Transcript) (semanticRecords : List Json) : List Json :=
  match codexTargetTimestamp? t with
  | some _ => semanticRecords.flatMap (fun record =>
      record :: (targetDisplayTwin? record).toList)
  | none => semanticRecords

/-- Loom IR → Codex JSONL (one compact JSON object per line): the `session_meta`
header then the linear `response_item` stream. The terminal newline is part of
the target-session contract: Codex appends records in place, so omitting it
would concatenate the first resumed record onto the final imported object.
Inverse of `importCodexCli`. -/
def exportCodexCli (t : Transcript) : String :=
  let semanticRecords := codexSemanticRecords t
  let records := codexTargetRecordsFromSemantic t semanticRecords
  let carrierProtocolStamp := codexRecordsUseCarrierProtocol semanticRecords
  let header := codexJsonLine (sessionMetaJson t carrierProtocolStamp) ::
    (targetTurnContextJson? t).toList.map codexJsonLine
  String.intercalate "\n" (header ++ records.map codexJsonLine) ++ "\n"

/-- Exact typed payload at the selected terminal. This intentionally ignores
entry provenance/disposition: a foreign payload may be downgraded to an inert
carrier while retaining the same selected continuation data. -/
private def codexSelectedTerminalPayload? (t : Transcript) : Option Json := do
  let leaf ← t.activeLeaf
  let entry ← t.entries[leaf]?
  pure (codexHistoricalPayloadJson entry.payload)

private structure CodexSelectedTerminalMaterialization where
  entries : Array Entry
  callKeys : Array (Option CodexCallKey)
  terminalStart : Nat

/-- Materialize the complete target record stream and separately materialize
the exact prefix before the selected source entry. The prefix size is therefore
the selected expansion's fixed target boundary; it cannot slide past an
unexpected entry inserted before an otherwise unchanged tail. -/
private def codexSelectedTerminalMaterialization?
    (t : Transcript) : Option CodexSelectedTerminalMaterialization := do
  let leaf ← t.activeLeaf
  let _ ← t.entries[leaf]?
  let semanticRecords := codexSemanticRecords t
  let carrierProtocolStamp := codexRecordsUseCarrierProtocol semanticRecords
  let targetRecords := codexTargetRecordsFromSemantic t semanticRecords
  let kept := (adaptRecords targetRecords carrierProtocolStamp).1
  let entries := buildEntries kept
  let prefixRecords := codexTargetRecordsFromSemantic t
    (codexSemanticEntryRecordsBefore t leaf)
  let terminalStart := (adaptRecords prefixRecords carrierProtocolStamp).1.size
  guard (terminalStart < entries.size)
  pure { entries, callKeys := kept.map (·.callKey), terminalStart }

private def codexTerminalFragmentStateMatches
    (expected actual : Entry) : Bool :=
  actual.time == expected.time && actual.disposition == expected.disposition

private def codexMaterializedEntryMatches (expected actual : Entry) : Bool :=
  actual.parent == expected.parent && actual.thread == expected.thread &&
    actual.time == expected.time && actual.disposition == expected.disposition &&
    codexHistoricalPayloadJson actual.payload ==
      codexHistoricalPayloadJson expected.payload &&
    actual.origin.format == expected.origin.format &&
    actual.origin.sourceRef == expected.origin.sourceRef &&
    actual.origin.rawId == expected.origin.rawId &&
    actual.origin.extras == expected.origin.extras

private def codexMaterializedBoundaryMatches
    (expected actual : Array Entry) : Bool :=
  expected.size == actual.size && (expected.toList.zip actual.toList).all
    (fun (expectedEntry, actualEntry) =>
      codexMaterializedEntryMatches expectedEntry actualEntry)

/-- Reassemble the exact typed payload represented by a final materialized
suffix. Codex expands mixed assistant and environment entries into multiple
records; concatenating only same-role payload fragments recovers the selected
source entry without relying on an unstable target index. -/
private def codexReassembleTerminalPayload?
    (source : Payload) (suffix : List Entry) : Option Payload :=
  match source with
  | .userMsg _ => do
      let parts ← suffix.mapM (fun entry => match entry.payload with
        | .userMsg blocks => some blocks
        | _ => none)
      pure (.userMsg parts.flatten)
  | .assistantMsg _ => do
      let parts ← suffix.mapM (fun entry => match entry.payload with
        | .assistantMsg blocks => some blocks
        | _ => none)
      pure (.assistantMsg parts.flatten)
  | .envMsg _ => do
      let parts ← suffix.mapM (fun entry => match entry.payload with
        | .envMsg blocks => some blocks
        | _ => none)
      pure (.envMsg parts.flatten)
  | .otherMsg role _ => do
      let parts ← suffix.mapM (fun entry => match entry.payload with
        | .otherMsg currentRole blocks => do
            guard (currentRole == role)
            pure blocks
        | _ => none)
      pure (.otherMsg role parts.flatten)
  | .compaction _ _ _ | .event _ =>
      match suffix with
      | [entry] => some entry.payload
      | _ => none

/-- Exact call syntax at a positional reference. The signature includes raw and
canonical tool names, arguments, and raw id. -/
private def codexToolCallSignatureAt?
    (t : Transcript) (entryIdx blockIdx : Nat) : Option Json := do
  let entry ← t.entries[entryIdx]?
  let blocks ← match entry.payload with
    | .assistantMsg blocks => some blocks
    | _ => none
  let block ← blocks[blockIdx]?
  match block with
  | .toolCall _ _ _ => some (codexHistoricalAssistantBlockJson block)
  | _ => none

/-- Identity inside one materialized target. A resolved result binds the exact
target occurrence as well as call syntax; inserting or removing an identical
call cannot silently retarget it by changing a syntax rank. -/
private def codexMaterializedCallRefIdentity?
    (t : Transcript) : CallRef → Option Json
  | .resolved entryIdx blockIdx => do
      let signature ← codexToolCallSignatureAt? t entryIdx blockIdx
      pure (Json.mkObj [
        ("kind", Json.str "resolved"),
        ("entry", Json.num entryIdx),
        ("block", Json.num blockIdx),
        ("signature", signature)])
  | .unresolved rawId note => some (Json.mkObj [
      ("kind", Json.str "unresolved"),
      ("rawId", rawId.map Json.str |>.getD Json.null),
      ("note", Json.str note)])

private def codexSourceCallKeyMatches (source : Transcript)
    (entryIdx blockIdx : Nat) (key : CodexCallKey) : Bool :=
  match source.entries[entryIdx]? with
  | some entry =>
      match entry.payload with
      | .assistantMsg blocks =>
          match blocks[blockIdx]? with
          | some (.toolCall name args rawId) =>
              if nativeCallAt source entryIdx blockIdx name args rawId then
                match key, rawId with
                | .rawId _ keyId, some sourceId => keyId == sourceId
                | _, _ => false
              else
                match key with
                | .occurrence _ occurrence =>
                    occurrence == codexOccurrence entryIdx blockIdx
                | _ => false
          | _ => false
      | _ => false
  | none => false

/-- Relate a source call coordinate to the exporter-assigned key on its exact
materialized target occurrence. Historical calls use the carrier occurrence;
native calls use their unique native id. Neither case depends on the current
rank among duplicate-looking calls. -/
private def codexSourceCallRefMatchesMaterialized
    (source expected : Transcript)
    (materialized : CodexSelectedTerminalMaterialization) : CallRef → CallRef → Bool
  | .resolved sourceEntry sourceBlock, .resolved targetEntry targetBlock =>
      codexToolCallSignatureAt? source sourceEntry sourceBlock ==
          codexToolCallSignatureAt? expected targetEntry targetBlock &&
        match materialized.callKeys[targetEntry]? with
        | some (some key) =>
            codexSourceCallKeyMatches source sourceEntry sourceBlock key
        | _ => false
  | .unresolved sourceId sourceNote, .unresolved targetId targetNote =>
      sourceId == targetId && sourceNote == targetNote
  | _, _ => false

private def codexSourceTerminalEnvBlockMatchesMaterialized
    (source expected : Transcript)
    (materialized : CodexSelectedTerminalMaterialization) : EnvBlock → EnvBlock → Bool
  | .toolResult sourceCall sourceContent sourceError,
      .toolResult targetCall targetContent targetError =>
      codexSourceCallRefMatchesMaterialized source expected materialized
          sourceCall targetCall &&
        Json.arr (sourceContent.map historicalResultBlockJson).toArray ==
          Json.arr (targetContent.map historicalResultBlockJson).toArray &&
        codexErrorValue sourceError == codexErrorValue targetError
  | .unmodeled sourceLabel sourceRaw, .unmodeled targetLabel targetRaw =>
      sourceLabel == targetLabel && sourceRaw == targetRaw
  | _, _ => false

private def codexSourceTerminalPayloadMatchesMaterialized
    (source expected : Transcript)
    (materialized : CodexSelectedTerminalMaterialization)
    (sourcePayload targetPayload : Payload) : Bool :=
  match sourcePayload, targetPayload with
  | .envMsg sourceBlocks, .envMsg targetBlocks =>
      sourceBlocks.length == targetBlocks.length &&
        (sourceBlocks.zip targetBlocks).all (fun (sourceBlock, targetBlock) =>
          codexSourceTerminalEnvBlockMatchesMaterialized source expected
            materialized sourceBlock targetBlock)
  | .envMsg _, _ | _, .envMsg _ => false
  | _, _ => codexHistoricalPayloadJson sourcePayload ==
      codexHistoricalPayloadJson targetPayload

private def codexEntryOnSelectedPath (t : Transcript) (target : Nat) : Bool :=
  let rec visit (fuel : Nat) (current : Option Nat) : Bool :=
    match fuel, current with
    | 0, _ | _, none => false
    | fuel + 1, some entryIdx =>
        if entryIdx == target then true
        else visit fuel (t.entries[entryIdx]?.bind (fun entry => entry.parent))
  visit (t.entries.size + 1) t.activeLeaf

private structure CodexLinkedCallState where
  entry : Nat
  block : Nat
  time : Time
  disposition : EntryDisposition
  selected : Bool
  deriving DecidableEq

private def codexLinkedCallState? (t : Transcript) : CallRef → Option CodexLinkedCallState
  | .resolved entryIdx blockIdx => do
      let entry ← t.entries[entryIdx]?
      let _ ← codexToolCallSignatureAt? t entryIdx blockIdx
      pure {
        entry := entryIdx
        block := blockIdx
        time := entry.time
        disposition := entry.disposition
        selected := codexEntryOnSelectedPath t entryIdx }
  | .unresolved _ _ => none

private def codexTerminalEnvBlockIdentity?
    (t : Transcript) : EnvBlock → Option Json
  | .toolResult call content error => do
      let callIdentity ← codexMaterializedCallRefIdentity? t call
      pure (Json.mkObj [
        ("kind", Json.str "toolResult"),
        ("call", callIdentity),
        ("content", Json.arr (content.map historicalResultBlockJson).toArray),
        ("error", errorSignalJson error)])
  | .unmodeled label raw => some (Json.mkObj [
      ("kind", Json.str "unmodeled"),
      ("label", Json.str label),
      ("raw", raw)])

/-- Terminal payload identity inside one target materialization. Resolved call
references bind an exact occurrence and its exact call syntax. -/
private def codexTerminalPayloadIdentity?
    (t : Transcript) (payload : Payload) : Option Json :=
  match payload with
  | .envMsg blocks => do
      let encoded ← blocks.mapM (codexTerminalEnvBlockIdentity? t)
      pure (Json.mkObj [
        ("kind", Json.str "envMsg"),
        ("blocks", Json.arr encoded.toArray)])
  | _ => some (codexHistoricalPayloadJson payload)

private def codexTerminalLinkedCallStates?
    (t : Transcript) (payload : Payload) : Option (List CodexLinkedCallState) :=
  match payload with
  | .envMsg blocks => do
      let states ← blocks.mapM (fun block => match block with
        | .toolResult call _ _ => (codexLinkedCallState? t call).map some
        | .unmodeled _ _ => some none)
      pure (states.filterMap (fun state => state))
  | _ => some []

private def codexMaterializedTranscript
    (source : Transcript) (entries : Array Entry) : Transcript :=
  { source with
    entries
    activeLeaf := if entries.isEmpty then none else some (entries.size - 1) }

/-- The target's own thinking-signature policy, applied to a SOURCE payload so
the checked comparison compares like with like.

`assistantStandaloneRecord?` emits `encrypted_content` only for a Codex-origin
entry, because that slot is OpenAI provider ciphertext and a Claude/Pi blob in
it breaks resume with `invalid_encrypted_content`. Empty foreign thinking is
dropped outright rather than emitted as a summary-less stub.

That omission is a DECIDED target policy, not a transport failure. The
materialization already models it, so without this projection the checked
exporter compares a source payload that still carries the signature against its
own correct expectation, calls the difference corruption, and refuses every
foreign transcript containing a thinking signature — which is most real Claude
sessions. Projecting here keeps the refusal for genuine drift while letting the
policy through. `Loom.Fidelity` states the same rule for expected projections. -/
private def codexThinkingSignaturePolicyPayload
    (codexOrigin : Bool) (p : Payload) : Payload :=
  if codexOrigin then p
  else
    match p with
    | .assistantMsg blocks =>
        .assistantMsg (blocks.filterMap (fun block =>
          match block with
          | .thinking text _ =>
              if text.isEmpty then none else some (.thinking text none)
          | other => some other))
    | other => other

private def codexCheckedReimportFailure? (source restored : Transcript) : Option String :=
  let targetViolations := Loom.violations restored
  if !codexTargetActiveLeafValid source then
    some "Codex source did not select its final linear entry"
  else if !targetViolations.isEmpty then
    some s!"Codex target re-import has {targetViolations.length} structural violations"
  else if !codexTargetActiveLeafValid restored then
    some "Codex target re-import did not select its final linear entry"
  else if source.entries.isEmpty then
    if restored.entries.isEmpty then none
    else some "Codex target re-import materialized an entry from an empty source"
  else
    let sourceEntry? : Option Entry := source.activeLeaf >>= fun leaf =>
      source.entries[leaf]?
    match sourceEntry? with
    | none => some "Codex source selected terminal entry is missing"
    | some sourceEntry =>
        match codexSelectedTerminalMaterialization? source with
        | none =>
            some "Codex selected terminal entry emitted no resumable target entries"
        | some materialized =>
            let expectedCount := materialized.entries.size
            if restored.entries.size < expectedCount then
              some "Codex target re-import truncated the selected terminal expansion"
            else if restored.entries.size > expectedCount then
              some "Codex target re-import added an unexpected materialized entry"
            else
              let expectedTranscript := codexMaterializedTranscript source materialized.entries
              let expectedTerminal := materialized.entries.toList.drop
                materialized.terminalStart
              let actualTerminal := restored.entries.toList.drop
                materialized.terminalStart
              let stateMatches := (expectedTerminal.zip actualTerminal).all
                (fun (expected, actual) =>
                  codexTerminalFragmentStateMatches expected actual)
              if !stateMatches then
                some "Codex target re-import changed the selected terminal expansion state"
              else
                match codexReassembleTerminalPayload? sourceEntry.payload expectedTerminal,
                    codexReassembleTerminalPayload? sourceEntry.payload actualTerminal with
                | some expectedPayload, some actualPayload =>
                    let policySourcePayload :=
                      codexThinkingSignaturePolicyPayload
                        (sourceEntry.origin.format == Format.codexCli)
                        sourceEntry.payload
                    if !codexSourceTerminalPayloadMatchesMaterialized source
                        expectedTranscript materialized policySourcePayload expectedPayload then
                      some "Codex target re-import changed the selected terminal expansion"
                    else
                      match codexTerminalPayloadIdentity? expectedTranscript expectedPayload,
                          codexTerminalPayloadIdentity? restored actualPayload with
                      | some expectedIdentity, some actualIdentity =>
                          if actualIdentity != expectedIdentity then
                            some "Codex target re-import changed the selected terminal expansion"
                          else
                            match codexTerminalLinkedCallStates?
                                expectedTranscript expectedPayload,
                                codexTerminalLinkedCallStates? restored actualPayload with
                            | some expectedStates, some actualStates =>
                                if !decide (actualStates = expectedStates) then
                                  some "Codex target re-import changed the selected terminal expansion state"
                                else if !codexMaterializedBoundaryMatches
                                    materialized.entries restored.entries then
                                  some "Codex target re-import changed the complete materialized boundary"
                                else none
                            | _, _ =>
                                some "Codex target re-import produced an invalid terminal call reference"
                      | _, _ =>
                          some "Codex target re-import produced an invalid terminal call reference"
                | _, _ =>
                    some "Codex target re-import changed the selected terminal expansion shape"

/-- Source-side failures owned by the direct checked-export API. These checks
run independently of CLI policy and before any target bytes are rendered. -/
def codexCheckedSourcePreflightFailures (t : Transcript) : List String :=
  let sourceViolations := Loom.violations t
  let structural := if sourceViolations.isEmpty then [] else
    [s!"Codex source IR has {sourceViolations.length} structural violations: {reprStr sourceViolations}"]
  let destructive := (Loom.Ops.obligations .codexCli t).filter
    (Loom.Ops.obligationIsDestructiveFor .codexCli t)
  let loss := if destructive.isEmpty then [] else
    [s!"Codex target has destructive export obligations: {reprStr destructive}"]
  structural ++ loss

/-- Refusing target exporter for runtime-facing conversion paths. The legacy
total renderer remains available for forensic same-format round-trip tests, but
callers that intend Codex to resume the artifact must use this checked surface.
Successful checked output is parsed again and must preserve structural integrity
and the explicitly selected terminal payload. A single Loom entry may materialize
as multiple Codex records, so validation reconstructs its nonempty final suffix
rather than comparing one unstable target index. -/
def exportCodexCliChecked (t : Transcript) : Except String String :=
  let preflightFailures := codexCheckedSourcePreflightFailures t ++
    codexTargetExportPrerequisiteFailures t
  match preflightFailures with
  | failure :: failures => .error (String.intercalate "; " (failure :: failures))
  | [] =>
      let output := exportCodexCli t
      match importCodexCli output with
      | .error error => .error s!"Codex target failed self-validation: {error}"
      | .ok restored =>
          match codexCheckedReimportFailure? t restored with
          | some failure => .error failure
          | none => .ok output

/-- Write the IR back to a Codex session file. -/
def exportCodexCliFile (path : System.FilePath) (t : Transcript) : IO Unit :=
  IO.FS.writeFile path (exportCodexCli t)

/-! ## Round-trip self-parity pin (RC1)

`import → export → import` is stable under `normalize`. Because export re-emits no
cross-channel DUPLICATES (the paired user/agent `event_msg` channel is dropped;
only twin-less content events like `error` round-trip), re-import sees no
duplicates to dedup, so the second import reproduces the first's structure exactly.
If the exporter drops, reorders, or mangles any row, `normalize` diverges and this
stops compiling. -/
def roundTripCodex (text : String) : Bool :=
  match importCodexCli text with
  | .error _ => false
  | .ok t => normalize t == (match importCodexCli (exportCodexCli t) with
                             | .ok t2 => normalize t2
                             | .error _ => "ERR")

/-- THE DECIDE-PIN (self-parity, RC1): Codex round-trips through its own exporter
under `normalize`. -/
example : roundTripCodex codexFixture = true := by native_decide

/-- Unknown response/event payloads also survive the same-format exporter; the
open-world import carrier is not an import-only dead end. -/
def codexUnknownKindsRoundTrip : Bool :=
  match importCodexCli codexUnknownKindsFixture with
  | .ok t =>
      match importCodexCli (exportCodexCli t) with
      | .ok roundTripped => codexUnknownKindsShape roundTripped
      | .error _ => false
  | .error _ => false

example : codexUnknownKindsRoundTrip = true := by native_decide

/-- Codex resumes by appending to the rollout file. Keep this as a separate pin:
semantic round-trip tests alone cannot detect a missing record delimiter. -/
def codexExportEndsWithRecordDelimiter : Bool :=
  match importCodexCli codexFixture with
  | .ok transcript => (exportCodexCli transcript).endsWith "\n"
  | .error _ => false

example : codexExportEndsWithRecordDelimiter = true := by native_decide

/-- Codex records no explicit selected leaf. Empty sessions retain absence;
nonempty linear imports select the final materialized entry and expose that
file-order inference in the import-note trace. -/
def codexLinearActiveLeafInferenceIsExplicit : Bool :=
  let emptySource :=
    "{\"type\":\"session_meta\",\"payload\":{\"id\":\"empty-selection\"}}"
  match importCodexCli emptySource, importCodexCli codexFixture with
  | .ok empty, .ok nonempty =>
      empty.entries.isEmpty && empty.activeLeaf.isNone &&
        !empty.importNotes.any (fun note => note.kind == .activeLeafGuessed) &&
      nonempty.activeLeaf == some (nonempty.entries.size - 1) &&
        nonempty.importNotes.any (fun note =>
          note.kind == .activeLeafGuessed &&
            note.loc == some s!"entry{nonempty.entries.size - 1}")
  | _, _ => false

example : codexLinearActiveLeafInferenceIsExplicit = true := by native_decide

/-! ## S5+S6 deepening — images + search items + error events (leanCore-richer)

`codexRichFixture` exercises every content type the text-only importer used to
drop (census `Loom.Formats.CodexCli`): a `message` with an `input_image`
(alongside text), a `web_search_call` and a `tool_search_call` (→ `toolCall`), a
`tool_search_output` (→ linked result with verbatim content), and a twin-less `event_msg.error` (→
`Payload.event`).

DIVERGENCE (deliberate, NOT pinned): the TS `parseSession`/`adaptCodex` path DROPS
all of these — the image (image-only messages yield zero blocks), the search items
(unhandled), and the error (no response_item twin → invisible). So Loom is strictly
RICHER here; a `crossParityOkWith`/`codexCase1`-style pin would (correctly) FAIL
against the poorer TS oracle. Hence this fixture is verified by local compile-time
checks rather than a cross-parity pin — exactly the adjudicated-leanCore-improvement
class (cf. the L12 `thinkingSignature` exclusion and the sibling Claude/GAIS rich
fixtures). -/

def codexRichFixture : String := String.intercalate "\n" [
  "{\"type\":\"session_meta\",\"timestamp\":\"2026-07-06T00:00:00.000Z\",\"payload\":{\"id\":\"sess-cdx-rich\",\"cwd\":\"/tmp/cdx\",\"cli_version\":\"0.142.4\",\"originator\":\"codex-tui\",\"model_provider\":\"openai\"}}",
  ("{\"type\":\"response_item\",\"timestamp\":\"2026-07-06T00:00:01.000Z\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"look at this\"},{\"type\":\"input_image\",\"image_url\":\"" ++
    codexTinyPngDataUri ++ "\"}]}}"),
  "{\"type\":\"response_item\",\"timestamp\":\"2026-07-06T00:00:02.000Z\",\"payload\":{\"type\":\"web_search_call\",\"call_id\":\"ws1\",\"status\":\"completed\",\"action\":{\"type\":\"search\",\"query\":\"lean 4 json\"}}}",
  "{\"type\":\"response_item\",\"timestamp\":\"2026-07-06T00:00:03.000Z\",\"payload\":{\"type\":\"tool_search_call\",\"call_id\":\"ts1\",\"action\":{\"query\":\"grep\"}}}",
  "{\"type\":\"response_item\",\"timestamp\":\"2026-07-06T00:00:04.000Z\",\"payload\":{\"type\":\"tool_search_output\",\"call_id\":\"ts1\",\"results\":[{\"path\":\"a.lean\"}]}}",
  "{\"type\":\"event_msg\",\"timestamp\":\"2026-07-06T00:00:05.000Z\",\"payload\":{\"type\":\"error\",\"message\":\"boom\"}}"
]

/-- First `.media` block (mimeType, locator) in any message. The locator remains
exact even when Codex inlined a `data:` URI. -/
private def firstMedia (t : Transcript) : Option (String × String) :=
  t.entries.toList.findSome? (fun (e : Entry) => match e.payload with
    | .userMsg blocks => blocks.findSome? (fun (b : UserBlock) => match b with
        | UserBlock.media m loc => some (m, loc) | _ => none)
    | .assistantMsg blocks => blocks.findSome? (fun (b : AssistantBlock) => match b with
        | AssistantBlock.media m loc => some (m, loc) | _ => none)
    | _ => none)

/-- First `error` meta event's `message` — confirms the twin-less error event_msg
(invisible in TS) is captured as `Payload.event (MetaEvent.custom "error" …)`. -/
private def firstError (t : Transcript) : Option String :=
  t.entries.toList.findSome? (fun (e : Entry) => match e.payload with
    | .event (MetaEvent.custom "error" raw) => ostr raw "message"
    | _ => none)

-- S5+S6 recovery (task VERIFY step): well-formed IR, all previously-dropped
-- content present.
example :
    (match importCodexCli codexRichFixture with
     | .ok t =>
         t.entries.size == 5
         && (Loom.violations t).isEmpty
         && (match firstMedia t with
             | some ("image", locator) => locator == codexTinyPngDataUri
             | _ => false)
         && firstError t == some "boom"
         && hasSub (normalize t) "toolResult|unmodeled:tool_search_output"
         && (Loom.Ops.openCalls t).length == 1
     | .error _ => false) = true := by native_decide

-- Foreign search tools are retained as readable history rather than emitted
-- under unregistered `function_call` names. Media and error events still use
-- their target-native carriers.
def codexRichForeignToolsDowngradeSafely : Bool :=
  match importCodexCli codexRichFixture with
  | .error _ => false
  | .ok t =>
      let out := exportCodexCli t
      hasSub out "[Historical tool call from source transcript; not executed by Codex]" &&
      hasSub out "\\\"name\\\":\\\"web_search_call\\\"" &&
      hasSub out "\\\"name\\\":\\\"tool_search_call\\\"" &&
      !hasSub out "\\\"name\\\":\\\"web_search_call\\\",\\\"type\\\":\\\"function_call\\\"" &&
      !hasSub out "\\\"name\\\":\\\"tool_search_call\\\",\\\"type\\\":\\\"function_call\\\""

example : codexRichForeignToolsDowngradeSafely = true := by native_decide

/-- Summary counters use the same target-policy decision as serialization:
both search calls and the structured search result are historical carriers,
not native Codex function records. -/
def codexRichTargetPolicyCensusReconciles : Bool :=
  match importCodexCli codexRichFixture with
  | .error _ => false
  | .ok transcript =>
      codexNativeToolCallCount transcript == 0 &&
      codexHistoricalToolCallCount transcript == 2 &&
      codexNativeToolResultCount transcript == 0 &&
      codexHistoricalToolResultCount transcript == 1

example : codexRichTargetPolicyCensusReconciles = true := by native_decide

/-! ## Current Codex runtime-control envelopes

Codex 0.144+ persists permissions/skills and per-turn environment context as
message-shaped records. They are target runtime state, not user conversation.
The importer archives exact records in origin extras and logs the disposition;
ordinary embedded XML-like text remains conversational. -/

def codexControlFixture : String := String.intercalate "\n" [
  "{\"type\":\"session_meta\",\"timestamp\":\"2026-07-10T00:00:00Z\",\"payload\":{\"id\":\"control\",\"cwd\":\"/tmp/control\",\"cli_version\":\"0.144.1\"}}",
  "{\"type\":\"response_item\",\"timestamp\":\"2026-07-10T00:00:01Z\",\"payload\":{\"type\":\"message\",\"role\":\"developer\",\"content\":[{\"type\":\"input_text\",\"text\":\"<permissions instructions>\\nread-only\\n</permissions instructions>\"},{\"type\":\"input_text\",\"text\":\"plain developer instruction is still not user dialogue\"}]}}",
  "{\"type\":\"response_item\",\"timestamp\":\"2026-07-10T00:00:02Z\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"<recommended_plugins>\\nplugin inventory\\n</recommended_plugins>\"},{\"type\":\"input_text\",\"text\":\"<environment_context>\\n<cwd>/tmp/control</cwd>\\n</environment_context>\"}]}}",
  "{\"type\":\"event_msg\",\"timestamp\":\"2026-07-10T00:00:02Z\",\"payload\":{\"type\":\"user_message\",\"message\":\"<environment_context>\\n<cwd>/tmp/control</cwd>\\n</environment_context>\"}}",
  "{\"type\":\"response_item\",\"timestamp\":\"2026-07-10T00:00:03Z\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"Run the check; explain the literal <environment_context> tag.\"}]}}",
  "{\"type\":\"response_item\",\"timestamp\":\"2026-07-10T00:00:04Z\",\"payload\":{\"type\":\"custom_tool_call\",\"name\":\"exec\",\"call_id\":\"call-current\",\"input\":\"text(await tools.exec_command({cmd: 'pwd'}))\"}}",
  "{\"type\":\"response_item\",\"timestamp\":\"2026-07-10T00:00:05Z\",\"payload\":{\"type\":\"custom_tool_call_output\",\"call_id\":\"call-current\",\"output\":[{\"type\":\"input_text\",\"text\":\"Script completed\\n\"},{\"type\":\"input_text\",\"text\":\"Output:\\n/tmp/control\\n\"}]}}",
  "{\"type\":\"response_item\",\"timestamp\":\"2026-07-10T00:00:06Z\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ordinary text retained\"}]}}"
]

def codexRuntimeControlsArchived : Bool :=
  match importCodexCli codexControlFixture with
  | .error _ => false
  | .ok transcript =>
      let rawControls := transcript.origin.extras.bind (fun extras =>
        oarr extras "raw_control_messages")
      transcript.entries.size == 4 &&
      transcript.importNotes.length == 5 &&
      rawControls.map Array.size == some 3 &&
      (renderTranscript transcript).contains
        "Run the check; explain the literal <environment_context> tag." &&
      (renderTranscript transcript).contains "[tool call exec; id=call-current]" &&
      (renderTranscript transcript).contains "Script completed" &&
      !(renderTranscript transcript).contains "<permissions instructions>" &&
      !(renderTranscript transcript).contains "<recommended_plugins>" &&
      !(renderTranscript transcript).contains "plain developer instruction" &&
      !(renderTranscript transcript).contains "</environment_context>"

example : codexRuntimeControlsArchived = true := by native_decide

private def codexMixedControlFixture : String := String.intercalate "\n" [
  "{\"type\":\"session_meta\",\"payload\":{\"id\":\"mixed-controls\"}}",
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"system\",\"content\":[{\"type\":\"input_text\",\"text\":\"system policy\"}]}}",
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"developer\",\"content\":[{\"type\":\"input_text\",\"text\":\"developer policy\"}]}}",
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"control\",\"content\":[{\"type\":\"input_text\",\"text\":\"future control role\"}]}}",
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"ordinary before\"},{\"type\":\"input_text\",\"text\":\"<environment_context>\\n<cwd>/secret</cwd>\\n</environment_context>\"},{\"type\":\"input_text\",\"text\":\"ordinary after\"},{\"type\":\"input_text\",\"text\":\"<permissions instructions>\\nread-only\\n</permissions instructions>\"}]}}",
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"answer\"}]}}"
]

/-- Control-plane roles never acquire conversational authorship. Exact control
blocks are removed from a mixed user message while ordinary sibling blocks
remain ordered; the original mixed record is retained in the raw archive. -/
def codexMixedControlsAreIsolated : Bool :=
  match importCodexCli codexMixedControlFixture with
  | .error _ => false
  | .ok transcript =>
      let rawControls := transcript.origin.extras.bind (fun extras =>
        oarr extras "raw_control_messages")
      transcript.entries.size == 2 &&
      rawControls.map Array.size == some 4 &&
      (match transcript.entries[0]?, transcript.entries[1]? with
       | some user, some assistant =>
           (match user.payload with
            | .userMsg [.text before, .text after] =>
                before == "ordinary before" && after == "ordinary after"
            | _ => false) &&
           (match assistant.payload with
            | .assistantMsg [.text answer] => answer == "answer"
            | _ => false)
       | _, _ => false) &&
      rawControls.any (fun records => records.any (fun record =>
        hasSub record.compress "<environment_context>" &&
          hasSub record.compress "ordinary before")) &&
      !hasSub (renderTranscript transcript) "system policy" &&
      !hasSub (renderTranscript transcript) "developer policy" &&
      !hasSub (renderTranscript transcript) "future control role" &&
      !hasSub (renderTranscript transcript) "<permissions instructions>"

example : codexMixedControlsAreIsolated = true := by native_decide

def codexDuplicateToolIdFixture : String := String.intercalate "\n" [
  "{\"type\":\"session_meta\",\"timestamp\":\"T0\",\"payload\":{\"id\":\"duplicate-tool-id\",\"cwd\":\"/tmp/duplicate\"}}",
  "{\"type\":\"response_item\",\"timestamp\":\"T1\",\"payload\":{\"type\":\"function_call\",\"call_id\":\"same\",\"name\":\"first\",\"arguments\":\"{}\"}}",
  "{\"type\":\"response_item\",\"timestamp\":\"T2\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"same\",\"output\":\"first result\"}}",
  "{\"type\":\"response_item\",\"timestamp\":\"T3\",\"payload\":{\"type\":\"function_call\",\"call_id\":\"same\",\"name\":\"second\",\"arguments\":\"{}\"}}",
  "{\"type\":\"response_item\",\"timestamp\":\"T4\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"same\",\"output\":\"second result\"}}"
]

/-- Interleaved id reuse is unambiguous: each result arrives with exactly one
unmatched candidate, so the second occurrence never aliases the first. -/
def codexDuplicateToolIdsResolveByOccurrence : Bool :=
  match importCodexCli codexDuplicateToolIdFixture with
  | .error _ => false
  | .ok transcript =>
      Loom.Ops.resolvedRefs transcript == [(0, 0), (2, 0)] &&
      Loom.Ops.openCalls transcript == [] &&
      (Loom.violations transcript).isEmpty

example : codexDuplicateToolIdsResolveByOccurrence = true := by native_decide

private def codexAmbiguousDuplicateToolIdFixture : String := String.intercalate "\n" [
  "{\"type\":\"session_meta\",\"payload\":{\"id\":\"ambiguous-duplicate\"}}",
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\",\"call_id\":\"same\",\"name\":\"first\",\"arguments\":\"{}\"}}",
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\",\"call_id\":\"same\",\"name\":\"second\",\"arguments\":\"{}\"}}",
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"same\",\"output\":\"not positionally attributable\"}}"]

/-- Two unmatched native calls are not ordered evidence for one result. Keep
both calls open and expose the result's ambiguity instead of guessing. -/
def codexDuplicateToolIdAmbiguityIsExplicit : Bool :=
  match importCodexCli codexAmbiguousDuplicateToolIdFixture with
  | .error _ => false
  | .ok transcript =>
      Loom.Ops.resolvedRefs transcript == [] &&
      Loom.Ops.openCalls transcript == [(0, 0), (1, 0)] &&
      (Loom.violations transcript).isEmpty &&
      match transcript.entries[2]? with
      | some result => match result.payload with
        | .envMsg [.unmodeled label raw] =>
            label == "codex.unresolved.function_call_output.ambiguous" &&
              ostr raw "call_id" == some "same" &&
              ostr raw "output" == some "not positionally attributable"
        | _ => false
      | none => false

example : codexDuplicateToolIdAmbiguityIsExplicit = true := by native_decide

private def codexRepeatedToolResultsFixture : String := String.intercalate "\n" [
  "{\"type\":\"session_meta\",\"payload\":{\"id\":\"repeated-results\"}}",
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\",\"call_id\":\"repeat\",\"name\":\"exec_command\",\"arguments\":\"{\\\"cmd\\\":\\\"pwd\\\"}\"}}",
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"repeat\",\"output\":\"first observation\"}}",
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"repeat\",\"output\":\"second observation\"}}"
]

private def codexRepeatedToolResultShape (transcript : Transcript) : Bool :=
  Loom.Ops.resolvedRefs transcript == [(0, 0)] &&
  (Loom.violations transcript).isEmpty &&
  match transcript.entries[1]?, transcript.entries[2]? with
  | some first, some second =>
      (match first.payload with
       | .envMsg [.toolResult (.resolved 0 0) [.text text] _] =>
           text == "first observation"
       | _ => false) &&
      (match second.payload with
       | .envMsg [.unmodeled label raw] =>
           label == "codex.unresolved.function_call_output.unmatched" &&
             ostr raw "call_id" == some "repeat" &&
             ostr raw "output" == some "second observation"
       | _ => false)
  | _, _ => false

def codexRepeatedToolResultDoesNotReuseMatchedCall : Bool :=
  match importCodexCli codexRepeatedToolResultsFixture with
  | .error _ => false
  | .ok transcript =>
      codexRepeatedToolResultShape transcript &&
      match importCodexCli (exportCodexCli transcript) with
      | .ok restored => codexRepeatedToolResultShape restored
      | .error _ => false

example : codexRepeatedToolResultDoesNotReuseMatchedCall = true := by native_decide

def codexOrphanBeforeReusedIdFixture : String := String.intercalate "\n" [
  "{\"type\":\"session_meta\",\"timestamp\":\"T0\",\"payload\":{\"id\":\"orphan-before-reuse\",\"cwd\":\"/tmp/orphan\"}}",
  "{\"type\":\"response_item\",\"timestamp\":\"T1\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"same\",\"output\":\"orphan\"}}",
  "{\"type\":\"response_item\",\"timestamp\":\"T2\",\"payload\":{\"type\":\"function_call\",\"call_id\":\"same\",\"name\":\"later\",\"arguments\":\"{}\"}}",
  "{\"type\":\"response_item\",\"timestamp\":\"T3\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"same\",\"output\":\"matched\"}}"
]

def codexOrphanResultDoesNotConsumeFutureCall : Bool :=
  match importCodexCli codexOrphanBeforeReusedIdFixture with
  | .error _ => false
  | .ok transcript =>
      match transcript.entries[0]?, transcript.entries[1]?, transcript.entries[2]? with
      | some orphan, some call, some matched =>
          match orphan.payload, call.payload, matched.payload with
          | .envMsg [.unmodeled label raw],
            .assistantMsg [.toolCall _ _ (some "same")],
            .envMsg [.toolResult (.resolved 1 0) _ _] =>
              label == "codex.unresolved.function_call_output.unmatched" &&
                ostr raw "output" == some "orphan" &&
                (Loom.violations transcript).isEmpty
          | _, _, _ => false
      | _, _, _ => false

example : codexOrphanResultDoesNotConsumeFutureCall = true := by native_decide

/-! ## Historical-carrier adversaries

This fixture deliberately defeats raw-id linkage: two calls share `dup`, and
the second call's result arrives first. It also exercises an open call, an
orphan result, structured content, and every `ErrorSignal` constructor. -/

private def codexHistoricalCarrierFixture : Transcript :=
  let entryOrigin : Origin := {
    format := .pi, sourceRef := "codex-carrier-adversary" }
  { threads := #[{ kind := .main }],
    entries := #[
      { payload := .assistantMsg [
          .toolCall { raw := "foreign_first" }
            (Json.arr #[Json.str "a", Json.bool true]) (some "dup")],
        origin := entryOrigin },
      { parent := some 0, payload := .assistantMsg [
          .toolCall { raw := "foreign_second" }
            (Json.mkObj [("nested", Json.mkObj [("n", (2 : Json))])]) (some "dup")],
        origin := entryOrigin },
      { parent := some 1, payload := .envMsg [
          .toolResult (.resolved 1 0)
            [.text "second", .media "image/png" "https://example.invalid/image.png",
             .unmodeled "structured" (Json.mkObj [
               ("items", Json.arr #[Json.bool false, Json.null])])]
            (.inferred true "source-specific heuristic")],
        origin := entryOrigin },
      { parent := some 2, payload := .envMsg [
          .toolResult (.resolved 0 0) [.text "first"] (.native false)],
        origin := entryOrigin },
      { parent := some 3, payload := .assistantMsg [
          .toolCall { raw := "foreign_open" } Json.null none],
        origin := entryOrigin },
      { parent := some 4, payload := .envMsg [
          .toolResult (.unresolved (some "ghost") "source orphan note") [] .unrecorded],
        origin := entryOrigin }],
    env := { cwd := some "/tmp/carrier", sessionId := some "carrier-adversary" },
    activeLeaf := some 5,
    origin := {
      format := .pi, sourceRef := "codex-carrier-adversary",
      extras := some (Json.mkObj [
        ("target_timestamp", Json.str "2026-07-10T00:00:00Z")]) } }

private def codexHistoricalCarrierRestored (t : Transcript) : Bool :=
  t.entries.size == 6 &&
  match t.entries[0]?, t.entries[1]?, t.entries[2]?,
        t.entries[3]?, t.entries[4]?, t.entries[5]? with
  | some firstCall, some secondCall, some secondResult,
    some firstResult, some openCall, some orphan =>
      (match firstCall.payload with
       | .assistantMsg [.toolCall name args (some "dup")] =>
           name.raw == "foreign_first" &&
             args == Json.arr #[Json.str "a", Json.bool true]
        | _ => false) &&
      (match secondCall.payload with
       | .assistantMsg [.toolCall name args (some "dup")] =>
           name.raw == "foreign_second" &&
             args == Json.mkObj [("nested", Json.mkObj [("n", (2 : Json))])]
       | _ => false) &&
      (match secondResult.payload with
       | .envMsg [.toolResult (.resolved 1 0)
           [.text "second", .media "image/png" "https://example.invalid/image.png",
            .unmodeled "structured" raw]
           (.inferred true "source-specific heuristic")] =>
             raw == Json.mkObj [("items", Json.arr #[Json.bool false, Json.null])]
       | _ => false) &&
      (match firstResult.payload with
       | .envMsg [.toolResult (.resolved 0 0) [.text "first"] (.native false)] => true
       | _ => false) &&
      (match openCall.payload with
       | .assistantMsg [.toolCall name Json.null none] => name.raw == "foreign_open"
       | _ => false) &&
      (match orphan.payload with
       | .envMsg [.toolResult (.unresolved (some "ghost") note) [] .unrecorded] =>
           note == "source orphan note"
       | _ => false)
  | _, _, _, _, _, _ => false

/-- Export-stamped carriers reconstruct the complete lifecycle. The target
display twins remain readable to Codex but deduplicate on re-import, so they do
not create extra dialogue entries. -/
def codexHistoricalCarrierLifecycleRoundTrip : Bool :=
  let exported := exportCodexCli codexHistoricalCarrierFixture
  (match parseCodexSession exported with
   | .ok (sessionPayload, _) => codexCarrierSessionSelfIdentified sessionPayload
   | .error _ => false) &&
  !hasSub exported "\"type\":\"function_call\"" &&
  !hasSub exported "\"type\":\"function_call_output\"" &&
  hasSub exported ("\"" ++ codexCarrierMarkerKey ++ "\"") &&
  hasSub exported codexHistoricalToolCallCarrierHeader &&
  hasSub exported codexHistoricalToolResultCarrierHeader &&
  match importCodexCli exported with
  | .ok restored =>
      codexHistoricalCarrierRestored restored &&
      Loom.Ops.openCalls restored == [(4, 0)]
  | .error _ => false

example : codexHistoricalCarrierLifecycleRoundTrip = true := by native_decide

private def codexUnsafeUnmodeledRaw : Json := Json.mkObj [
  ("type", Json.str "function_call"),
  ("name", Json.str "exec_command"),
  ("call_id", Json.str "raw-bypass"),
  ("arguments", Json.str "{\"cmd\":\"pwd\"}")]

private def codexUnsafeUnmodeledFixture : Transcript :=
  { threads := #[{ kind := .main }],
    entries := #[{
      payload := .assistantMsg [
        .unmodeled "adversarial_native_discriminator" codexUnsafeUnmodeledRaw],
      origin := { format := .pi, sourceRef := "raw-native-adversary" } }],
    env := { sessionId := some "raw-native-adversary" },
    activeLeaf := some 0,
    origin := { format := .pi, sourceRef := "raw-native-adversary" } }

/-- An unmodeled block cannot smuggle an executable discriminator around
`nativeCallAt`. It becomes an inert carrier, and the exact unmodeled value is
restored only because both session and item self-identify the protocol. -/
def codexUnmodeledNativeDiscriminatorIsInert : Bool :=
  let exported := exportCodexCli codexUnsafeUnmodeledFixture
  match parseCodexSession exported with
  | .error _ => false
  | .ok (sessionPayload, records) =>
      codexCarrierSessionSelfIdentified sessionPayload &&
      !records.any (fun record =>
        ((oobj record "payload").bind (fun payload => ostr payload "type")) ==
          some "function_call") &&
      match importCodexCli exported with
      | .error _ => false
      | .ok restored =>
          Loom.Ops.callSites restored == [] &&
          match restored.entries[0]? with
          | some entry => match entry.payload with
            | .assistantMsg [.unmodeled label raw] =>
                label == "adversarial_native_discriminator" &&
                  raw == codexUnsafeUnmodeledRaw
            | _ => false
          | none => false

example : codexUnmodeledNativeDiscriminatorIsInert = true := by native_decide

private def codexCarrierSpoofText : String :=
  historicalToolCallText 0 0 { raw := "quoted_tool" }
    (Json.mkObj [("quoted", Json.bool true)]) (some "quoted-id")

private def codexCarrierHeaderLine : String :=
  (Json.mkObj [
    ("type", Json.str "session_meta"),
    ("payload", Json.mkObj [("id", Json.str "carrier-spoof")])]).compress

private def codexCarrierSpoofFixture : String := String.intercalate "\n" [
  codexCarrierHeaderLine,
  (codexAssistantText codexCarrierSpoofText).compress]

private def codexMalformedMarkedCarrierFixture : String := String.intercalate "\n" [
  codexCarrierHeaderLine,
  (codexAssistantCarrier "tool_call" (codexHistoricalToolCallCarrierHeader ++
    "\n{\"carrier\":\"agent-convert.codex-tool-call.v1\"}")).compress]

private def codexUnstampedMarkedCarrierFixture : String := String.intercalate "\n" [
  codexCarrierHeaderLine,
  (codexAssistantCarrier "tool_call"
    (historicalToolCallText 0 0 { raw := "unstamped_tool" }
      (Json.mkObj [("x", (1 : Json))]) (some "unstamped-id"))).compress]

/-- Carrier-looking prose is inert without the item stamp. An item-stamped
record is also inert without the session stamp, and a malformed item remains
open-world data. These stamps are self-identification, not cryptographic
authentication; their purpose is provenance gating and accidental-collision
resistance. -/
def codexCarrierProvenanceGateChecked : Bool :=
  match importCodexCli codexCarrierSpoofFixture,
        importCodexCli codexMalformedMarkedCarrierFixture,
        importCodexCli codexUnstampedMarkedCarrierFixture with
  | .ok spoof, .ok malformed, .ok unstamped =>
      Loom.Ops.callSites spoof == [] &&
      (match spoof.entries[0]? with
       | some entry => match entry.payload with
         | .assistantMsg [.text text] => text == codexCarrierSpoofText
         | _ => false
       | none => false) &&
      Loom.Ops.callSites malformed == [] &&
      (match malformed.entries[0]? with
       | some entry => match entry.payload with
         | .assistantMsg [.unmodeled "agent_convert_codex_carrier" _] => true
         | _ => false
       | none => false) &&
      Loom.Ops.callSites unstamped == [] &&
      (match unstamped.entries[0]? with
       | some entry => match entry.payload with
         | .assistantMsg [.unmodeled "agent_convert_codex_carrier" raw] =>
             codexCarrierMarkerPresent raw
         | _ => false
       | none => false)
  | _, _, _ => false

example : codexCarrierProvenanceGateChecked = true := by native_decide

/-! ## Release-blocker adversaries -/

private def codexMixedControlResponseRecord : String :=
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"ordinary before\"},{\"type\":\"input_text\",\"text\":\"<environment_context>\\n<cwd>/private</cwd>\\n</environment_context>\"},{\"type\":\"input_text\",\"text\":\"ordinary after\"}]}}"

private def codexMixedControlEventRecord : String :=
  "{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"ordinary before<environment_context>\\n<cwd>/private</cwd>\\n</environment_context>ordinary after\"}}"

private def codexMixedControlResponseFirst : String := String.intercalate "\n" [
  "{\"type\":\"session_meta\",\"payload\":{\"id\":\"mixed-response-first\"}}",
  codexMixedControlResponseRecord,
  codexMixedControlEventRecord]

private def codexMixedControlEventFirst : String := String.intercalate "\n" [
  "{\"type\":\"session_meta\",\"payload\":{\"id\":\"mixed-event-first\"}}",
  codexMixedControlEventRecord,
  codexMixedControlResponseRecord]

private def codexMixedControlOrderSafe (input : String) : Bool :=
  match importCodexCli input with
  | .error _ => false
  | .ok transcript =>
      let controls := transcript.origin.extras.bind (fun extras =>
        oarr extras "raw_control_messages")
      transcript.entries.size == 1 && controls.map Array.size == some 2 &&
      (match transcript.entries[0]? with
       | some entry => match entry.payload with
         | .userMsg [.text before, .text after] =>
             before == "ordinary before" && after == "ordinary after"
         | _ => false
       | none => false) &&
      !hasSub (renderTranscript transcript) "<environment_context>"

/-- The structured channel is the authority for a mixed control/dialogue turn.
Its ordinary siblings survive in order, while the flattened event twin is
archived rather than attributed to the user, in either channel order. -/
def codexMixedControlBothChannelOrdersSafe : Bool :=
  codexMixedControlOrderSafe codexMixedControlResponseFirst &&
    codexMixedControlOrderSafe codexMixedControlEventFirst

example : codexMixedControlBothChannelOrdersSafe = true := by native_decide

private def codexLeadingHeaderPreludeFixture : String := String.intercalate "\n" [
  "{\"type\":\"session_meta\",\"payload\":{\"id\":\"current\"}}",
  "{\"type\":\"session_meta\",\"payload\":{\"id\":\"ancestor-1\"}}",
  "{\"type\":\"session_meta\",\"payload\":{\"session_id\":\"ancestor-2\"}}",
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"prelude accepted\"}]}}"]

private def codexSyntheticRepeatedSameIdHeadersFixture : String := String.intercalate "\n" [
  "{\"type\":\"session_meta\",\"payload\":{\"id\":\"resume\"}}",
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"one\"}]}}",
  "{\"type\":\"session_meta\",\"payload\":{\"id\":\"resume\"}}",
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"two\"}]}}",
  "{\"type\":\"session_meta\",\"payload\":{\"session_id\":\"resume\"}}",
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"three\"}]}}"]

private def codexDifferentSessionAfterContentFixture : String := String.intercalate "\n" [
  "{\"type\":\"session_meta\",\"payload\":{\"id\":\"primary\"}}",
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"primary content\"}]}}",
  "{\"type\":\"session_meta\",\"payload\":{\"id\":\"concatenated\"}}"]

private def codexAllImportModesHaveEntryCount (input : String) (count : Nat) : Bool :=
  (match importCodexCli input with
   | .ok transcript => transcript.entries.size == count
   | .error _ => false) &&
  (match importCodexCliActive input with
   | .ok transcript => transcript.entries.size == count
   | .error _ => false) &&
  (match importCodexCliTsParity input with
   | .ok transcript => transcript.entries.size == count
   | .error _ => false)

/-- The corpus accepts leading ancestor headers, while a repeated same-ID header
remains only a conservative syntax fixture. The 567-file census found 59 files
with multiple `session_meta` records; all 59 contained multiple distinct IDs and
none was repeated-same-ID-only. Every header therefore stays a hard segment
boundary, and the synthetic same-ID case does not weaken that rule. -/
def codexRealSessionHeaderShapesAccepted : Bool :=
  codexAllImportModesHaveEntryCount codexLeadingHeaderPreludeFixture 1 &&
    codexAllImportModesHaveEntryCount codexSyntheticRepeatedSameIdHeadersFixture 3 &&
    allCodexImportModesReject codexDifferentSessionAfterContentFixture

example : codexRealSessionHeaderShapesAccepted = true := by native_decide

private def codexDualIdentityPayload : Json := Json.mkObj [
  ("id", Json.str "current-rollout"),
  ("session_id", Json.str "parent-session"),
  ("parent_thread_id", Json.str "parent-session"),
  ("cli_version", Json.str "0.142.0"),
  ("thread_source", Json.str "subagent"),
  ("source", Json.mkObj [
    ("subagent", Json.mkObj [("other", Json.str "guardian")])])]

private def codexDualIdentityFixture : String := String.intercalate "\n" [
  (Json.mkObj [("type", Json.str "session_meta"),
    ("payload", codexDualIdentityPayload)]).compress,
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"dual identity accepted\"}]}}"]

/-- In 183/240 dual-field corpus headers the values differ, all on subagent
rollouts from 0.142-0.144. `id` names the current rollout; `session_id` carries
lineage. Both values remain native on same-format export and in inert source
provenance. -/
def codexDualSessionIdentityIsTypedAndReversible : Bool :=
  match importCodexCli codexDualIdentityFixture with
  | .error _ => false
  | .ok imported =>
      let rawPayload := imported.origin.extras.bind (fun extras =>
        oobj extras "raw_session_meta_payload")
      let sourceIdentity := imported.origin.extras.bind (fun extras =>
        oobj extras "source_session_identity")
      let hasIdentityNote := imported.importNotes.any (fun note =>
        match note.kind with
        | .other label => label == "codex-dual-session-identity"
        | _ => false)
      imported.env.sessionId == some "current-rollout" &&
      imported.origin.rawId == some "current-rollout" &&
      rawPayload == some codexDualIdentityPayload &&
      sourceIdentity == some (codexSourceIdentityJson codexDualIdentityPayload) &&
      hasIdentityNote &&
      let exported := exportCodexCli imported
      match parseCodexSession exported, importCodexCli exported with
      | .ok (header, _), .ok restored =>
          ostr header "id" == some "current-rollout" &&
          ostr header "session_id" == some "parent-session" &&
          ostr header "parent_thread_id" == some "parent-session" &&
          (parseCodexSourceArchive? header).any (fun archive =>
            archive.sourceSessionPayload == codexDualIdentityPayload &&
              archive.sourceIdentity == codexSourceIdentityJson codexDualIdentityPayload) &&
          restored.env.sessionId == some "current-rollout"
      | _, _ => false

example : codexDualSessionIdentityIsTypedAndReversible = true := by native_decide

private def codexCrossBoundaryDuplicateIdFixture : String := String.intercalate "\n" [
  "{\"type\":\"session_meta\",\"payload\":{\"id\":\"boundary-tools\"}}",
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\",\"call_id\":\"duplicate\",\"name\":\"first\",\"arguments\":\"{}\"}}",
  "{\"type\":\"session_meta\",\"payload\":{\"id\":\"boundary-tools\"}}",
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"duplicate\",\"output\":\"must stay orphaned\"}}",
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\",\"call_id\":\"duplicate\",\"name\":\"second\",\"arguments\":\"{}\"}}",
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"duplicate\",\"output\":\"same-segment result\"}}"]

def codexToolIdsDoNotCrossResumeBoundaries : Bool :=
  match importCodexCli codexCrossBoundaryDuplicateIdFixture with
  | .error _ => false
  | .ok transcript =>
      Loom.Ops.resolvedRefs transcript == [(2, 0)] &&
      match transcript.entries[1]?, transcript.entries[3]? with
      | some orphan, some resolved =>
          (match orphan.payload with
           | .envMsg [.unmodeled label raw] =>
               label == "codex.unresolved.function_call_output.unmatched" &&
                 ostr raw "call_id" == some "duplicate"
           | _ => false) &&
          (match resolved.payload with
           | .envMsg [.toolResult (.resolved 2 0) _ _] => true
           | _ => false) && (Loom.violations transcript).isEmpty
      | _, _ => false

example : codexToolIdsDoNotCrossResumeBoundaries = true := by native_decide

/-- Later native `session_meta` headers become inert boundary carriers on
export. Re-import restores the exact header and its pre-entry position, so the
disjoint call-id namespace and the complete serialized artifact are stable. -/
def codexSessionBoundariesRoundTripReversibly : Bool :=
  match importCodexCli codexCrossBoundaryDuplicateIdFixture with
  | .error _ => false
  | .ok imported =>
      let firstExport := exportCodexCli imported
      match parseCodexSession firstExport, importCodexCli firstExport with
      | .ok (_, records), .ok restored =>
          let boundaries := restored.origin.extras.bind (fun extras =>
            oarr extras "raw_session_boundaries")
          !records.any (fun record => ostr record "type" == some "session_meta") &&
          records.countP (fun record =>
            (oobj record "payload" >>= codexCarrierKind?) ==
              some "session_boundary") == 1 &&
          (match boundaries with
           | some #[raw] => (parseCodexSessionBoundary? raw).any (fun boundary =>
               boundary.beforeEntry == 1 &&
                 boundary.record == Json.mkObj [
                   ("type", Json.str "session_meta"),
                   ("payload", Json.mkObj [("id", Json.str "boundary-tools")])])
           | _ => false) &&
          Loom.Ops.resolvedRefs restored == [(2, 0)] &&
          exportCodexCli restored == firstExport
      | _, _ => false

example : codexSessionBoundariesRoundTripReversibly = true := by native_decide

private def codexCrossTargetBoundarySpoof : Transcript :=
  let source : Origin := { format := .pi, sourceRef := "boundary-spoof" }
  let fakeBoundary := codexSessionBoundaryJson {
    beforeEntry := 1
    record := Json.mkObj [
      ("type", Json.str "session_meta"),
      ("payload", Json.mkObj [("id", Json.str "spoofed-boundary")])] }
  { threads := #[{ kind := .main }],
    entries := #[
      { payload := .assistantMsg [.toolCall { raw := "foreign_tool" }
          (Json.mkObj []) (some "same")], origin := source },
      { parent := some 0,
        payload := .envMsg [.toolResult (.resolved 0 0) [.text "result"]
          .unrecorded], origin := source }],
    env := { sessionId := some "cross-target-boundary-spoof" },
    activeLeaf := some 1,
    origin := {
      format := .pi
      sourceRef := "boundary-spoof"
      extras := some (Json.mkObj [
        ("raw_session_boundaries", Json.arr #[fakeBoundary])]) } }

/-- Positional boundary extras are trusted only on a Codex-origin transcript.
A foreign lookalike cannot split a lifecycle or activate a boundary carrier. -/
def codexCrossTargetBoundaryCarrierTrustIsGated : Bool :=
  let exported := exportCodexCli codexCrossTargetBoundarySpoof
  !hasSub exported codexHistoricalSessionBoundaryCarrierHeader &&
  match parseCodexSession exported, importCodexCli exported with
  | .ok (_, records), .ok restored =>
      !records.any (fun record =>
        (oobj record "payload" >>= codexCarrierKind?) ==
          some "session_boundary") &&
      Loom.Ops.resolvedRefs restored == [(0, 0)] &&
      restored.origin.extras.bind (fun extras =>
        oarr extras "raw_session_boundaries") == some #[]
  | _, _ => false

example : codexCrossTargetBoundaryCarrierTrustIsGated = true := by native_decide

/-- Compaction is reduced independently inside each hard session segment. In the
same census, 130 files contained compaction and 97 contained more than one,
which supports segment-local reduction rather than cross-header replay. -/
private def codexIndependentCompactionsFixture : String := String.intercalate "\n" [
  "{\"type\":\"session_meta\",\"payload\":{\"id\":\"segmented-compaction\"}}",
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"OLD-ONE\"}]}}",
  "{\"type\":\"compacted\",\"payload\":{\"replacement_history\":[{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"SNAP-ONE\"}]}]}}",
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"NEW-ONE\"}]}}",
  "{\"type\":\"session_meta\",\"payload\":{\"id\":\"segmented-compaction\"}}",
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"OLD-TWO\"}]}}",
  "{\"type\":\"compacted\",\"payload\":{\"replacement_history\":[{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"SNAP-TWO\"}]}]}}",
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"NEW-TWO\"}]}}"]

def codexCompactionsStayInsideResumeSegments : Bool :=
  match importCodexCliActive codexIndependentCompactionsFixture,
      importCodexCliTsParity codexIndependentCompactionsFixture with
  | .ok active, .ok parity =>
      let activeText := normalize active
      let parityText := normalize parity
      let boundariesOk := match codexActiveContextCompactionBoundaries? active with
        | some #[first, second] =>
            (first.getObjVal? "record_index" >>= Json.getNat?).toOption == some 1 &&
            (second.getObjVal? "record_index" >>= Json.getNat?).toOption == some 5
        | _ => false
      active.entries.size == 4 && parity.entries.size == 4 &&
      codexActiveContextExcludedRecordCount? active == some 4 &&
      codexActiveContextExcludedRecordCount? parity == some 4 && boundariesOk &&
      (codexActiveContextRawSourceRecords? active).map Array.size == some 7 &&
      hasSub activeText "SNAP-ONE" && hasSub activeText "NEW-ONE" &&
      hasSub activeText "SNAP-TWO" && hasSub activeText "NEW-TWO" &&
      !hasSub activeText "OLD-ONE" && !hasSub activeText "OLD-TWO" &&
      hasSub parityText "SNAP-ONE" && hasSub parityText "SNAP-TWO"
  | _, _ => false

example : codexCompactionsStayInsideResumeSegments = true := by native_decide

private def codexConcatenationCollisionFixture
    (first second : String) : Transcript :=
  let source : Origin := { format := .pi, sourceRef := "result-collision" }
  { threads := #[{ kind := .main }],
    entries := #[
      { payload := .assistantMsg [.toolCall { raw := "exec_command" }
          (Json.mkObj [("cmd", Json.str "printf abc")]) (some "collision-call")],
        origin := source },
      { parent := some 0,
        payload := .envMsg [.toolResult (.resolved 0 0)
          [.text first, .text second]
          (.inferred false "codexOutputIndicatesError (codexAdapter.ts:75)")],
        origin := source }],
    env := { sessionId := some "result-collision" },
    activeLeaf := some 1,
    origin := { format := .pi, sourceRef := "result-collision" } }

private def codexCollisionBlocksRestored
    (transcript : Transcript) (first second : String) : Bool :=
  match transcript.entries[1]? with
  | some entry => match entry.payload with
    | .envMsg [.toolResult (.resolved 0 0) [.text a, .text b]
        (.inferred false "codexOutputIndicatesError (codexAdapter.ts:75)")] =>
          a == first && b == second
    | _ => false
  | none => false

/-- A native Codex output string cannot distinguish `["ab", "c"]` from
`["a", "bc"]`. Both therefore use structured carriers; their exports differ
and each re-import reconstructs the original two-block result. -/
def codexResultConcatenationCollisionAvoided : Bool :=
  let leftSource := codexConcatenationCollisionFixture "ab" "c"
  let rightSource := codexConcatenationCollisionFixture "a" "bc"
  let left := exportCodexCli leftSource
  let right := exportCodexCli rightSource
  -- The collision is now avoided by faithful encoding rather than by refusing
  -- to emit natively: multi-block results serialize as Codex's array `output`
  -- form, one `output_text` item per block, so `["ab","c"]` and `["a","bc"]`
  -- stay distinct. Previously these could only be kept apart by carrying both
  -- as prose. Same property, strictly more usable artifact.
  left != right &&
  hasSub left "\"type\":\"function_call_output\"" &&
  hasSub right "\"type\":\"function_call_output\"" &&
  codexNativeToolResultCount leftSource == 1 &&
  codexNativeToolResultCount rightSource == 1 &&
  match importCodexCli left, importCodexCli right with
  | .ok restoredLeft, .ok restoredRight =>
      codexCollisionBlocksRestored restoredLeft "ab" "c" &&
        codexCollisionBlocksRestored restoredRight "a" "bc"
  | _, _ => false

example : codexResultConcatenationCollisionAvoided = true := by native_decide

private def codexRoleConfusingMessageRaw : Json := Json.mkObj [
  ("type", Json.str "message"),
  ("role", Json.str "user"),
  ("content", Json.arr #[Json.mkObj [
    ("type", Json.str "input_text"), ("text", Json.str "must remain assistant data")]])]

private def codexReasoningDiscriminatorRaw : Json := Json.mkObj [
  ("type", Json.str "reasoning"),
  ("summary", Json.arr #[Json.mkObj [
    ("type", Json.str "summary_text"), ("text", Json.str "raw reasoning")]])]

private def codexFutureDiscriminatorRaw : Json := Json.mkObj [
  ("type", Json.str "future_response_item"),
  ("nested", Json.mkObj [("exact", Json.bool true)])]

private def codexMislabelledContentRaw : Json := Json.mkObj [
  ("type", Json.str "output_text"),
  ("text", Json.str "must not be reclassified")]

private def codexAssistantUnmodeledRoleFixture : Transcript :=
  { threads := #[{ kind := .main }],
    entries := #[{
      payload := .assistantMsg [
        .unmodeled "raw-message" codexRoleConfusingMessageRaw,
        .unmodeled "raw-reasoning" codexReasoningDiscriminatorRaw,
        .unmodeled "raw-future" codexFutureDiscriminatorRaw,
        .unmodeled codexMessageContentLabel codexMislabelledContentRaw],
      origin := { format := .pi, sourceRef := "assistant-unmodeled" } }],
    env := { sessionId := some "assistant-unmodeled" },
    activeLeaf := some 0,
    origin := { format := .pi, sourceRef := "assistant-unmodeled" } }

private def codexAllRecordsAreInertAssistantCarriers (records : List Json) : Bool :=
  records.length == 4 && records.all (fun record =>
    match oobj record "payload" with
    | some payload =>
        ostr payload "type" == some "message" &&
        ostr payload "role" == some "assistant" &&
        codexCarrierKind? payload == some "unmodeled"
    | none => false)

/-- Every assistant unmodeled payload, including message/user and reasoning
discriminators, is inert on the wire and returns byte-for-byte under assistant
authorship. No discriminator-specific allowlist can accidentally reattribute it. -/
def codexAllAssistantUnmodeledPayloadsAreRoleSafe : Bool :=
  let exported := exportCodexCli codexAssistantUnmodeledRoleFixture
  match parseCodexSession exported, importCodexCli exported with
  | .ok (_, records), .ok restored =>
      codexAllRecordsAreInertAssistantCarriers records &&
      restored.entries.size == 4 &&
      (match restored.entries[0]?, restored.entries[1]?, restored.entries[2]?,
          restored.entries[3]? with
       | some first, some second, some third, some fourth =>
           (match first.payload with
            | .assistantMsg [.unmodeled "raw-message" raw] =>
                raw == codexRoleConfusingMessageRaw
            | _ => false) &&
           (match second.payload with
            | .assistantMsg [.unmodeled "raw-reasoning" raw] =>
                raw == codexReasoningDiscriminatorRaw
            | _ => false) &&
           (match third.payload with
            | .assistantMsg [.unmodeled "raw-future" raw] =>
                raw == codexFutureDiscriminatorRaw
            | _ => false) &&
           (match fourth.payload with
            | .assistantMsg [.unmodeled label raw] =>
                label == codexMessageContentLabel &&
                  raw == codexMislabelledContentRaw
            | _ => false)
       | _, _, _, _ => false)
  | _, _ => false

example : codexAllAssistantUnmodeledPayloadsAreRoleSafe = true := by native_decide

private def codexAssistantMultiBlockRaw : Json := Json.mkObj [
  ("type", Json.str "future_output"),
  ("payload", Json.arr #[Json.str "exact", Json.bool true])]

private def codexAssistantMultiBlockFixture : String := String.intercalate "\n" [
  "{\"type\":\"session_meta\",\"payload\":{\"id\":\"assistant-multiblock\"}}",
  ("{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"first\"},{\"type\":\"input_image\",\"image_url\":\"" ++
    codexDecoratedPngDataUri ++
    "\"},{\"type\":\"future_output\",\"payload\":[\"exact\",true]},{\"type\":\"output_text\",\"text\":\"last\"}]}}")]

private def codexAssistantMultiBlockShape (transcript : Transcript) : Bool :=
  transcript.entries.size == 1 &&
  match transcript.entries[0]? with
  | some entry => match entry.payload with
    | .assistantMsg [.text "first", .media "image" locator,
        .unmodeled label raw, .text "last"] =>
          locator == codexDecoratedPngDataUri &&
          label == codexMessageContentLabel && raw == codexAssistantMultiBlockRaw
    | _ => false
  | none => false

/-- A maximal run of assistant message blocks remains one response-item message,
so import-export-import preserves both entry grouping and block order. -/
def codexAssistantMultiBlockGroupingRoundTrips : Bool :=
  match importCodexCli codexAssistantMultiBlockFixture with
  | .error _ => false
  | .ok imported =>
      let exported := exportCodexCli imported
      codexAssistantMultiBlockShape imported &&
      (match parseCodexSession exported with
       | .ok (_, [record]) =>
           let content := (oobj record "payload").bind (fun payload =>
             oarr payload "content")
           content.map Array.size == some 4
       | _ => false) &&
      (match importCodexCli exported with
       | .ok restored => codexAssistantMultiBlockShape restored
       | .error _ => false)

example : codexAssistantMultiBlockGroupingRoundTrips = true := by native_decide

private def codexMalformedRetentionFixture : String := String.intercalate "\n" [
  "{\"type\":\"session_meta\",\"payload\":{\"id\":\"malformed-retention\"}}",
  "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"unexpected\":{\"retained\":true}}}",
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"reasoning\",\"summary\":[]}}",
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"reasoning\",\"summary\":[],\"encrypted_content\":\"cipher-only\"}}",
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"reasoning\",\"summary\":[{\"type\":\"summary_text\",\"text\":7}]}}",
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"reasoning\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"visible\"}],\"encrypted_content\":\"cipher-visible\"}}",
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\",\"call_id\":\"broken-call\",\"name\":\"exec_command\",\"arguments\":\"{\"}}",
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"broken-call\"}}",
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"custom_tool_call\",\"call_id\":\"broken-custom\",\"name\":\"apply_patch\",\"input\":{}}}",
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"custom_tool_call_output\",\"output\":\"missing id\"}}",
  "{\"type\":\"event_msg\",\"payload\":{\"type\":\"agent_message\",\"message\":7}}",
  "{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"\"}}",
  "{\"type\":\"future_outer_record\",\"payload\":{\"content\":\"retained outside dialogue\"}}"]

private def codexMalformedRetentionShape (transcript : Transcript) : Bool :=
  let archived := transcript.origin.extras.bind (fun extras =>
    oarr extras "raw_non_dialogue_records")
  transcript.entries.size == 7 && archived.map Array.size == some 5 &&
  (match transcript.entries[0]?, transcript.entries[1]?, transcript.entries[2]?,
      transcript.entries[3]?, transcript.entries[4]?, transcript.entries[5]?,
      transcript.entries[6]? with
   | some encrypted, some malformedReasoning, some visibleReasoning,
     some malformedCall, some malformedOutput, some malformedCustom,
     some malformedCustomOutput =>
       (match encrypted.payload with
        | .assistantMsg [.unmodeled "codex.reasoning" raw] =>
            ostr raw "encrypted_content" == some "cipher-only"
        | _ => false) &&
       (match malformedReasoning.payload with
        | .assistantMsg [.unmodeled "codex.reasoning" raw] =>
            (oarr raw "summary").isSome
        | _ => false) &&
       (match visibleReasoning.payload with
        | .assistantMsg [.thinking "visible" (some "cipher-visible")] => true
        | _ => false) &&
       (match malformedCall.payload with
        | .assistantMsg [.unmodeled "codex.malformed.function_call" raw] =>
            ostr raw "call_id" == some "broken-call"
        | _ => false) &&
       (match malformedOutput.payload with
        | .envMsg [.unmodeled "codex.malformed.function_call_output" raw] =>
            ostr raw "call_id" == some "broken-call"
        | _ => false) &&
       (match malformedCustom.payload with
        | .assistantMsg [.unmodeled "codex.malformed.custom_tool_call" raw] =>
            ostr raw "call_id" == some "broken-custom"
        | _ => false) &&
       (match malformedCustomOutput.payload with
        | .envMsg [.unmodeled "codex.malformed.custom_tool_call_output" raw] =>
            ostr raw "output" == some "missing id"
        | _ => false)
   | _, _, _, _, _, _, _ => false)

/-- Content-bearing malformed records remain under their source author and can
be carried exactly; lifecycle-only noise is retained in provenance and creates
no dialogue. Encrypted visible reasoning carries an explicit signature signal. -/
def codexMalformedAndSilentDropsAreExplicit : Bool :=
  match importCodexCli codexMalformedRetentionFixture with
  | .error _ => false
  | .ok imported =>
      codexMalformedRetentionShape imported &&
      match importCodexCli (exportCodexCli imported) with
      | .ok restored =>
          restored.entries.size == 7 &&
          (match restored.entries[3]?, restored.entries[4]?,
              restored.entries[5]?, restored.entries[6]? with
           | some call, some output, some custom, some customOutput =>
               (match call.payload with
                | .assistantMsg [.unmodeled "codex.malformed.function_call" raw] =>
                    ostr raw "call_id" == some "broken-call"
                | _ => false) &&
               (match output.payload with
                | .envMsg [.unmodeled "codex.malformed.function_call_output" raw] =>
                    ostr raw "call_id" == some "broken-call"
                | _ => false) &&
               (match custom.payload with
                | .assistantMsg [.unmodeled "codex.malformed.custom_tool_call" raw] =>
                    ostr raw "call_id" == some "broken-custom"
                | _ => false) &&
               (match customOutput.payload with
                | .envMsg [.unmodeled "codex.malformed.custom_tool_call_output" raw] =>
                    ostr raw "output" == some "missing id"
                | _ => false)
           | _, _, _, _ => false)
      | .error _ => false

example : codexMalformedAndSilentDropsAreExplicit = true := by native_decide

private def codexStampedCarrierHeader (extraMarkerField : Bool := false) : String :=
  let markerFields := [
    ("protocol", Json.str codexCarrierProtocol), ("kind", Json.str "session")] ++
    (if extraMarkerField then [("extra", Json.bool true)] else [])
  (Json.mkObj [
    ("type", Json.str "session_meta"),
    ("payload", Json.mkObj [
      ("id", Json.str "carrier-validation"),
      (codexCarrierMarkerKey, Json.mkObj markerFields)])]).compress

private def codexResultValidationCarrierText
    (recordId callRawId : Json) (output : String) (isError : Option Json)
    (provenance : String) : String :=
  let fields := [
    ("carrier", Json.str "agent-convert.codex-tool-result.v1"),
    ("occurrence", Json.str "1:0"),
    ("id", recordId),
    ("call", Json.mkObj [
      ("kind", Json.str "unresolved"), ("rawId", callRawId),
      ("note", Json.str "source orphan")]),
    ("output", Json.str output),
    ("content", Json.arr #[Json.mkObj [
      ("kind", Json.str "text"), ("text", Json.str "exact output")]]),
    ("error", Json.mkObj [("kind", Json.str "unrecorded")]),
    ("errorProvenance", Json.str provenance)] ++
    (match isError with | some value => [("isError", value)] | none => [])
  codexHistoricalToolResultCarrierHeader ++ "\n" ++ (Json.mkObj fields).compress

private def codexCallValidationCarrierText : String :=
  codexHistoricalToolCallCarrierHeader ++ "\n" ++
    (Json.mkObj [
      ("carrier", Json.str "agent-convert.codex-tool-call.v1"),
      ("occurrence", Json.str "0:0"), ("id", Json.null),
      ("name", Json.str "foreign"), ("arguments", Json.mkObj []),
      ("reason", Json.str "contradictory reason")]).compress

private def codexUnmodeledValidationCarrierText : String :=
  codexHistoricalUnmodeledCarrierHeader ++ "\n" ++
    (Json.mkObj [
      ("carrier", Json.str "agent-convert.codex-unmodeled.v1"),
      ("occurrence", Json.str "0:0"), ("label", Json.str "future"),
      ("raw", Json.mkObj [("type", Json.str "future")]),
      ("reason", Json.str "contradictory reason")]).compress

private def codexCarrierValidationFixture
    (kind text : String) (extraSessionMarkerField : Bool := false) : String :=
  String.intercalate "\n" [
    codexStampedCarrierHeader extraSessionMarkerField,
    (codexAssistantCarrier kind text).compress]

private def codexRejectedCarrierStaysUnmodeled (input : String) : Bool :=
  match importCodexCli input with
  | .error _ => false
  | .ok transcript =>
      Loom.Ops.callSites transcript == [] && transcript.entries.size == 1 &&
      match transcript.entries[0]? with
      | some entry => match entry.payload with
        | .assistantMsg [.unmodeled "agent_convert_codex_carrier" raw] =>
            codexCarrierMarkerPresent raw
        | _ => false
      | none => false

private def codexContradictoryCarrierFixtures : List String := [
  codexCarrierValidationFixture "tool_call" codexCallValidationCarrierText,
  codexCarrierValidationFixture "unmodeled" codexUnmodeledValidationCarrierText,
  codexCarrierValidationFixture "tool_result"
    (codexResultValidationCarrierText Json.null Json.null
      "contradictory output" (some Json.null) "unrecorded"),
  codexCarrierValidationFixture "tool_result"
    (codexResultValidationCarrierText (Json.str "different") Json.null
      "exact output" (some Json.null) "unrecorded"),
  codexCarrierValidationFixture "tool_result"
    (codexResultValidationCarrierText Json.null Json.null
      "exact output" (some (Json.bool false)) "unrecorded"),
  codexCarrierValidationFixture "tool_result"
    (codexResultValidationCarrierText Json.null Json.null
      "exact output" (some Json.null) "contradictory provenance"),
  codexCarrierValidationFixture "tool_result"
    (codexResultValidationCarrierText Json.null Json.null
      "exact output" none "unrecorded"),
  codexCarrierValidationFixture "tool_call"
    (historicalToolCallText 0 0 { raw := "foreign" } (Json.mkObj []) none) true]

/-- A carrier is decoded only when every duplicated projection agrees with the
authoritative structured fields. Contradictory output/id/error/provenance/reason,
missing redundancy, and non-exact session stamps all fall back to raw unmodeled. -/
def codexCarrierRedundantFieldsAreValidated : Bool :=
  codexContradictoryCarrierFixtures.all codexRejectedCarrierStaysUnmodeled

example : codexCarrierRedundantFieldsAreValidated = true := by native_decide

/-! ### Independent release-review adversaries -/

private def codexMalformedNativeSemanticsFixture : String := String.intercalate "\n" [
  "{\"type\":\"session_meta\",\"payload\":{\"id\":\"malformed-native-semantics\"}}",
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\",\"call_id\":\"array-string\",\"name\":\"exec_command\",\"arguments\":\"[]\"}}",
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\",\"call_id\":\"array-value\",\"name\":\"exec_command\",\"arguments\":[]}}",
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\",\"call_id\":\"valid-call\",\"name\":\"exec_command\",\"arguments\":\"{\\\"cmd\\\":\\\"pwd\\\"}\"}}",
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"valid-call\",\"output\":{\"not\":\"a valid output\"}}}",
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"custom_tool_call\",\"call_id\":\"bad-custom\",\"name\":\"apply_patch\",\"input\":{}}}",
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"custom_tool_call_output\",\"call_id\":\"bad-custom\",\"output\":7}}",
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_image\",\"image_url\":\"\"}]}}",
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"input_image\",\"image_url\":false}]}}",
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"valid-call\",\"output\":[{\"type\":\"input_image\"}]}}",
  ("{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_image\",\"image_url\":\"" ++
    codexTinyPngDataUri ++ "\",\"detail\":\"auto\"}]}}")]

private def codexMalformedNativeSemanticsShape (transcript : Transcript) : Bool :=
  transcript.entries.size == 10 &&
  Loom.Ops.callSites transcript == [(2, 0)] &&
  Loom.Ops.resolvedRefs transcript == [] &&
  (match transcript.entries[0]?, transcript.entries[1]?, transcript.entries[3]?,
      transcript.entries[4]?, transcript.entries[5]? with
   | some stringArray, some valueArray, some badOutput, some badCustom,
     some badCustomOutput =>
       (match stringArray.payload with
        | .assistantMsg [.unmodeled "codex.malformed.function_call" raw] =>
            ostr raw "arguments" == some "[]"
        | _ => false) &&
       (match valueArray.payload with
        | .assistantMsg [.unmodeled "codex.malformed.function_call" raw] =>
            (oarr raw "arguments").isSome
        | _ => false) &&
       (match badOutput.payload with
        | .envMsg [.unmodeled "codex.malformed.function_call_output" raw] =>
            oobj raw "output" == some (Json.mkObj [("not", Json.str "a valid output")])
        | _ => false) &&
       (match badCustom.payload with
        | .assistantMsg [.unmodeled "codex.malformed.custom_tool_call" raw] =>
            oobj raw "input" == some (Json.mkObj [])
        | _ => false) &&
       (match badCustomOutput.payload with
        | .envMsg [.unmodeled "codex.malformed.custom_tool_call_output" raw] =>
            oobj raw "output" == some (7 : Json)
        | _ => false)
   | _, _, _, _, _ => false) &&
  (match transcript.entries[6]?, transcript.entries[7]?,
      transcript.entries[8]?, transcript.entries[9]? with
   | some userImage, some assistantImage, some outputImage, some dataImage =>
       (match userImage.payload with
        | .userMsg [.unmodeled label raw] =>
            label == codexMessageContentLabel && ostr raw "image_url" == some ""
        | _ => false) &&
       (match assistantImage.payload with
        | .assistantMsg [.unmodeled label raw] =>
            label == codexMessageContentLabel &&
              oobj raw "image_url" == some (Json.bool false)
        | _ => false) &&
       (match outputImage.payload with
        | .envMsg [.unmodeled "codex.malformed.function_call_output" raw] =>
            (oarr raw "output").any (fun output =>
              output.size == 1 && output[0]?.any (fun item =>
                ostr item "type" == some "input_image" &&
                  oobj item "image_url" == none))
        | _ => false) &&
       (match dataImage.payload with
        | .userMsg [.media "image" locator] =>
            locator == codexTinyPngDataUri
        | _ => false)
   | _, _, _, _ => false)

/-- Malformed recognized records never gain tool/media constructors, while a
valid inlined image retains its full locator through same-format export. -/
def codexMalformedNativeRecordsStayInertAndExact : Bool :=
  match importCodexCli codexMalformedNativeSemanticsFixture with
  | .error _ => false
  | .ok imported =>
      codexMalformedNativeSemanticsShape imported &&
      match importCodexCli (exportCodexCli imported) with
      | .ok restored => codexMalformedNativeSemanticsShape restored
      | .error _ => false

example : codexMalformedNativeRecordsStayInertAndExact = true := by native_decide

/-- The native image subset is pinned to the Codex 0.144.1 inline prompt-image
path. Metadata matching is case-insensitive, but the complete accepted locator
is retained unchanged; remote/file URLs and malformed or mismatched data URLs
never acquire executable media constructors. -/
def codexImageLocatorDomainIsVersionPinned : Bool :=
  codexImageLocatorValid codexTinyPngDataUri &&
  codexImageLocatorValid codexDecoratedPngDataUri &&
  !codexImageLocatorValid "https://example.invalid/image.png" &&
  !codexImageLocatorValid "file:///tmp/image.png" &&
  !codexImageLocatorValid "data:image/svg+xml;base64,PHN2Zz48L3N2Zz4=" &&
  !codexImageLocatorValid "data:image/png;base64,AAECAwQ=" &&
  !codexImageLocatorValid "data:image/png;base64,iVBORw0KGgoAAAA" &&
  !codexImageLocatorValid "data:image/png,iVBORw0KGgoAAAANSUhEUg==" &&
  (codexImageRef? (Json.mkObj [
    ("image_url", Json.str codexTinyPngDataUri),
    ("detail", Json.str "low")])).isNone &&
  codexImageRef? (Json.mkObj [
    ("image_url", Json.str codexDecoratedPngDataUri),
    ("detail", Json.str "original")]) == some codexDecoratedPngDataUri &&
  codexAssistantMultiBlockGroupingRoundTrips

example : codexImageLocatorDomainIsVersionPinned = true := by native_decide

private def codexForeignSignatureFixture : Transcript :=
  { threads := #[{ kind := .main }],
    entries := #[{
      payload := .assistantMsg [.thinking "visible reasoning"
        (some "foreign:claude-or-pi-signature==")],
      origin := { format := .pi, sourceRef := "signature-source" } }],
    env := { sessionId := some "foreign-signature" },
    activeLeaf := some 0,
    origin := { format := .pi, sourceRef := "signature-source" } }

private def codexEmptyForeignSignatureFixture : Transcript :=
  { threads := #[{ kind := .main }],
    entries := #[{
      payload := .assistantMsg [.thinking ""
        (some "CAIS-anthropic-thinking-signature")],
      origin := { format := .claudeCode, sourceRef := "active0" } }],
    env := { sessionId := some "empty-foreign-signature" },
    activeLeaf := some 0,
    origin := { format := .claudeCode, sourceRef := "empty-foreign-signature" } }

private def codexNativeSignatureFixture : Transcript :=
  { threads := #[{ kind := .main }],
    entries := #[{
      payload := .assistantMsg [.thinking "visible reasoning"
        (some "encrypted:exact/signature==")],
      origin := { format := .codexCli, sourceRef := "entry0" } }],
    env := { sessionId := some "signature-round-trip" },
    activeLeaf := some 0,
    origin := { format := .codexCli, sourceRef := "signature-source" } }

/-- Foreign thinking signatures are provider-private ciphertext for another
API. Codex's `encrypted_content` slot only accepts OpenAI ciphertext; placing
a Claude/Pi signature there breaks resume with `invalid_encrypted_content`.
Export keeps the visible summary and omits the foreign signature. -/
def codexForeignThinkingSignatureIsNotEncryptedContent : Bool :=
  let exported := exportCodexCli codexForeignSignatureFixture
  match parseCodexSession exported with
  | .ok (_, records) =>
      records.any (fun record =>
        match oobj record "payload" with
        | some payload =>
            ostr payload "type" == some "reasoning" &&
              (ostr payload "encrypted_content").isNone &&
              (oarr payload "summary").any (fun summary =>
                summary.any (fun item =>
                  ostr item "text" == some "visible reasoning"))
        | none => false) &&
      !exported.contains "foreign:claude-or-pi-signature=="
  | _ => false

example : codexForeignThinkingSignatureIsNotEncryptedContent = true := by native_decide

/-- Empty foreign thinking (Claude signature-only blocks) must not become a
Codex reasoning item with foreign ciphertext or an empty-summary stub. -/
def codexEmptyForeignThinkingIsOmitted : Bool :=
  let exported := exportCodexCli codexEmptyForeignSignatureFixture
  match parseCodexSession exported with
  | .ok (_, records) =>
      records.all (fun record =>
        match oobj record "payload" with
        | some payload => ostr payload "type" != some "reasoning"
        | none => true) &&
      !exported.contains "CAIS-anthropic-thinking-signature"
  | _ => false

example : codexEmptyForeignThinkingIsOmitted = true := by native_decide

/-- Codex-origin thinking signatures remain native `encrypted_content` and
round-trip through the typed `.thinking` path. -/
def codexThinkingSignatureRoundTripsNatively : Bool :=
  let exported := exportCodexCli codexNativeSignatureFixture
  match parseCodexSession exported, importCodexCli exported with
  | .ok (_, records), .ok restored =>
      records.any (fun record =>
        ((oobj record "payload").bind (fun payload =>
          ostr payload "encrypted_content")) ==
            some "encrypted:exact/signature==") &&
      restored.entries.toList.any (fun entry =>
        match entry.payload with
        | .assistantMsg [.thinking "visible reasoning"
            (some "encrypted:exact/signature==")] => true
        | .assistantMsg (.thinking "visible reasoning"
            (some "encrypted:exact/signature==") :: _) => true
        | _ => false)
  | _, _ => false

example : codexThinkingSignatureRoundTripsNatively = true := by native_decide

private def codexVisibleEncryptedReasoningRaw : Json := Json.mkObj [
  ("type", Json.str "reasoning"),
  ("id", Json.str "reasoning-visible"),
  ("summary", Json.arr #[
    Json.mkObj [("type", Json.str "summary_text"),
      ("text", Json.str "first")],
    Json.mkObj [("type", Json.str "summary_text"),
      ("text", Json.str "second")]]),
  ("content", Json.null),
  ("encrypted_content", Json.str "cipher:visible/+/=="),
  ("internal_chat_message_metadata_passthrough", Json.mkObj [
    ("opaque", Json.arr #[Json.str "kept", Json.bool true])])]

private def codexOpaqueEncryptedReasoningRaw : Json := Json.mkObj [
  ("type", Json.str "reasoning"),
  ("id", Json.str "reasoning-opaque"),
  ("summary", Json.arr #[]),
  ("content", Json.null),
  ("encrypted_content", Json.str "cipher:opaque/+/=="),
  ("internal_chat_message_metadata_passthrough", Json.mkObj [
    ("opaque", Json.str "exact")]),
  ("future_reasoning_metadata", Json.mkObj [
    ("retained", Json.bool true)])]

private def codexEncryptedReasoningFixture : String := String.intercalate "\n" [
  "{\"type\":\"session_meta\",\"payload\":{\"id\":\"encrypted-reasoning\"}}",
  (respItem codexVisibleEncryptedReasoningRaw).compress,
  (respItem codexOpaqueEncryptedReasoningRaw).compress]

/-- Both representable reasoning forms preserve the exact native payload.
Visible encrypted reasoning remains typed `.thinking`; summary-less encrypted
reasoning remains exact inert data but still re-emits through Codex's native
`reasoning.encrypted_content` slot. -/
def codexEncryptedReasoningPreservedExactly : Bool :=
  match importCodexCli codexEncryptedReasoningFixture with
  | .error _ => false
  | .ok imported =>
      let exported := exportCodexCli imported
      match parseCodexSession exported, importCodexCli exported with
      | .ok (_, [visible, opaqueRecord]), .ok restored =>
          oobj visible "payload" == some codexVisibleEncryptedReasoningRaw &&
          oobj opaqueRecord "payload" == some codexOpaqueEncryptedReasoningRaw &&
          (match restored.entries[0]?, restored.entries[1]? with
           | some visibleEntry, some opaqueEntry =>
               (match visibleEntry.payload with
                | .assistantMsg [.thinking "first\nsecond"
                    (some "cipher:visible/+/==")] => true
                | _ => false) &&
               (match opaqueEntry.payload with
                | .assistantMsg [.unmodeled "codex.reasoning" raw] =>
                    raw == codexOpaqueEncryptedReasoningRaw
                | _ => false)
           | _, _ => false) &&
          exportCodexCli restored == exported
      | _, _ => false

example : codexEncryptedReasoningPreservedExactly = true := by native_decide

private def codexEmptyNativeIdFixture : Transcript :=
  let source : Origin := { format := .pi, sourceRef := "empty-native-id" }
  { threads := #[{ kind := .main }],
    entries := #[
      { payload := .assistantMsg [.toolCall { raw := "exec_command" }
          (Json.mkObj [("cmd", Json.str "pwd")]) (some "")],
        origin := source },
      { parent := some 0,
        payload := .envMsg [.toolResult (.resolved 0 0) [.text "done"]
          (.inferred false "codexOutputIndicatesError (codexAdapter.ts:75)")],
        origin := source }],
    env := { sessionId := some "empty-native-id" },
    activeLeaf := some 1,
    origin := { format := .pi, sourceRef := "empty-native-id" } }

/-- `some ""` is not a native id. The exact empty raw id survives only inside
historical carriers, and neither half of the lifecycle is executable. -/
def codexEmptyToolIdRejectedFromNativeExport : Bool :=
  let exported := exportCodexCli codexEmptyNativeIdFixture
  codexNativeToolCallCount codexEmptyNativeIdFixture == 0 &&
  codexNativeToolResultCount codexEmptyNativeIdFixture == 0 &&
  match parseCodexSession exported, importCodexCli exported with
  | .ok (_, records), .ok restored =>
      !records.any (fun record =>
        let payloadType := (oobj record "payload").bind (fun payload =>
          ostr payload "type")
        payloadType == some "function_call" ||
          payloadType == some "function_call_output") &&
      match restored.entries[0]? with
      | some entry => match entry.payload with
        | .assistantMsg [.toolCall name args (some "")] =>
            name.raw == "exec_command" &&
              ostr args "cmd" == some "pwd"
        | _ => false
      | none => false
  | _, _ => false

example : codexEmptyToolIdRejectedFromNativeExport = true := by native_decide

/-- Source controls are not replayed into a target's active history. They live
in an exact, inert session archive and reconstruct the same provenance array. -/
def codexSourceControlsRoundTripOutsideConversation : Bool :=
  match importCodexCli codexControlFixture with
  | .error _ => false
  | .ok imported =>
      let sourceControls := imported.origin.extras.bind (fun extras =>
        oarr extras "raw_control_messages")
      let exported := exportCodexCli imported
      match sourceControls, parseCodexSession exported, importCodexCli exported with
      | some expected, .ok (header, records), .ok restored =>
          (parseCodexSourceArchive? header).any (fun archive =>
            archive.sourceControls == expected) &&
          !records.any (fun record => ostr record "type" == some "turn_context") &&
          !records.any (fun record => expected.contains record) &&
          restored.origin.extras.bind (fun extras =>
            oarr extras "raw_control_messages") == some expected &&
          match parseCodexSession (exportCodexCli restored) with
          | .ok (secondHeader, _) =>
              (parseCodexSourceArchive? secondHeader).any (fun archive =>
                archive.sourceControls == expected)
          | .error _ => false
      | _, _, _ => false

example : codexSourceControlsRoundTripOutsideConversation = true := by native_decide

private def codexTargetTestId : String :=
  "019b1f75-4c2a-7b11-8ea2-1234567890ab"

private def codexTargetTestTimestamp : String := "2026-07-20T00:00:00Z"

private def codexTargetTestModel : String := "gpt-5.4"

private def codexTargetTestSandboxPolicy : Json := Json.mkObj [
  ("type", Json.str "workspace-write"),
  ("network_access", Json.bool false),
  ("exclude_tmpdir_env_var", Json.bool false),
  ("exclude_slash_tmp", Json.bool false)]

private def codexTargetTestControls : Json := Json.mkObj [
  ("protocol", Json.str codexTargetControlsProtocol),
  ("approval_policy", Json.str "on-request"),
  ("sandbox_policy", codexTargetTestSandboxPolicy),
  ("summary", Json.str "auto")]

private def codexTargetTestExtras : Json := Json.mkObj [
  ("target_timestamp", Json.str codexTargetTestTimestamp),
  ("target_session_id", Json.str codexTargetTestId),
  ("target_cwd", Json.str "/tmp/generated-target"),
  ("target_provider", Json.str "openai"),
  ("target_model", Json.str codexTargetTestModel),
  ("target_harness_version", Json.str codexCliTargetVersion),
  ("target_originator", Json.str "agent-convert"),
  (codexTargetControlsKey, codexTargetTestControls)]

private def codexEnvironmentCarrierTwinFixture : Transcript :=
  let env : EnvInfo := {
    cwd := some "/source/cwd"
    model := some "source-model"
    provider := some "source-provider"
    harnessVersion := some "source-harness"
    instructions := some "source security policy must remain historical"
    sessionId := some "source-session" }
  { threads := #[{ kind := .main }],
    entries := #[{
      payload := .envMsg [.unmodeled "foreign-environment"
        (Json.mkObj [("exact", Json.bool true)])],
      origin := { format := .pi, sourceRef := "environment-carrier" } }],
    env := env,
    activeLeaf := some 0,
    origin := {
      format := .pi, sourceRef := "environment-carrier",
      extras := some codexTargetTestExtras } }

private def codexClaudeControlMarkup : String :=
  "<system-reminder>Keep source control exact.</system-reminder>"

private def codexClaudeToolWrapperMarkup : String :=
  "<tool_use><name>Bash</name><input>pwd</input></tool_use>" ++
    "<tool_result><stdout>/tmp/generated-target</stdout></tool_result>"

private def codexMarkupControlRecord : Json := Json.mkObj [
  ("kind", Json.str "system-reminder"),
  ("raw", Json.str codexClaudeControlMarkup),
  ("record", Json.mkObj [
    ("type", Json.str "user"),
    ("message", Json.mkObj [
      ("role", Json.str "user"),
      ("content", Json.str codexClaudeControlMarkup)])])]

private def codexMarkupToolWrapperRecord : Json := Json.mkObj [
  ("kind", Json.str "tool-wrapper"),
  ("raw", Json.str codexClaudeToolWrapperMarkup),
  ("record", Json.mkObj [
    ("type", Json.str "tool-wrapper"),
    ("content", Json.str codexClaudeToolWrapperMarkup)])]

private def codexMarkupSourceControls : Array Json :=
  #[codexMarkupControlRecord, codexMarkupToolWrapperRecord]

private def codexMarkupControlArchiveFixture : Transcript :=
  let extras := match codexTargetTestExtras with
    | .obj fields => Json.obj (fields.insert "raw_control_messages"
        (Json.arr codexMarkupSourceControls))
    | other => other
  let source : Origin := {
    format := .claudeCode, sourceRef := "claude-markup-tool-fixture" }
  { codexEnvironmentCarrierTwinFixture with
    entries := #[
      { payload := .userMsg [.text "Run the typed command."]
        origin := source },
      { parent := some 0
        payload := .assistantMsg [.toolCall {
          raw := "Bash", canonical := some .bash }
          (Json.mkObj [("command", Json.str "pwd")])
          (some "toolu_markup_1")]
        origin := source },
      { parent := some 1
        payload := .envMsg [.toolResult (.resolved 1 0)
          [.text "/tmp/generated-target"] (.native false)]
        origin := source },
      { parent := some 2
        payload := .assistantMsg [.text "Typed tool lifecycle complete."]
        origin := source }
    ]
    activeLeaf := some 3
    origin := {
      format := .claudeCode, sourceRef := "claude-markup-tool-fixture",
      extras := some extras } }

/-- `error` is a parameter, not a literal, because Codex has no structured
failure field. The source asserts `.native false`; a real
`function_call_output` returns `.inferred false` via `codexOutputIndicatesError`.
The error VALUE is identical either way — only its provenance normalizes, which
`LoomOps.Interop` rates reportable rather than corrupting. Everything the shape
actually pins about the call, `name.canonical` included, is exact. -/
private def codexMarkupToolLifecycleShape
    (transcript : Transcript) (error : ErrorSignal) : Bool :=
  transcript.entries.size == 4 &&
  Loom.Ops.callSites transcript == [(1, 0)] &&
  Loom.Ops.resolvedRefs transcript == [(1, 0)] &&
  match transcript.entries[1]?, transcript.entries[2]? with
  | some call, some result =>
      (match call.payload with
       | .assistantMsg [.toolCall name args (some "toolu_markup_1")] =>
           name.raw == "Bash" && name.canonical == some .bash &&
             ostr args "command" == some "pwd"
       | _ => false) &&
      (match result.payload with
       | .envMsg [.toolResult (.resolved 1 0)
           [.text "/tmp/generated-target"] restoredError] => restoredError == error
       | _ => false)
  | _, _ => false

private def codexClaudeMarkupNeedles : List String := [
  "<system-reminder>", "</system-reminder>",
  "<tool_use>", "</tool_use>",
  "<tool_result>", "</tool_result>"]

/-- This value is built only after JSON parsing. Scanning every complete
post-header record is stronger than selecting a hand-maintained subset of text
fields: any wrapper in a current or future target-visible string is caught. -/
private def codexDecodedTargetRecordSurface (records : List Json) : String :=
  String.intercalate "\n" (records.map Json.compress)

/-- Archived control wrappers remain exact after JSON parsing, but their raw
angle brackets never occur in the target artifact bytes. -/
def codexArchivedControlMarkupIsTransportEscapedLosslessly : Bool :=
  match exportCodexCliChecked codexMarkupControlArchiveFixture with
  | .error _ => false
  | .ok exported =>
      codexClaudeMarkupNeedles.all (fun needle => !hasSub exported needle) &&
      hasSub exported "\\u003csystem-reminder\\u003e" &&
      hasSub exported "\\u003ctool_use\\u003e" &&
      hasSub exported "\\u003ctool_result\\u003e" &&
      match parseCodexSession exported, importCodexCli exported with
      | .ok (header, _), .ok restored =>
          (parseCodexSourceArchive? header).any (fun archive =>
            archive.sourceControls == codexMarkupSourceControls) &&
          restored.origin.extras.bind (fun restoredExtras =>
            oarr restoredExtras "raw_control_messages") ==
              some codexMarkupSourceControls &&
          match exportCodexCliChecked restored with
          | .ok second => second == exported
          | .error _ => false
      | _, _ => false

example : codexArchivedControlMarkupIsTransportEscapedLosslessly = true := by
  native_decide

/-- At the Codex-visible decoded JSON layer, no Claude control or tool-wrapper
tag survives. The typed call/result lifecycle remains inspectable, while the
two exact originals are recoverable only from inert source provenance.

The restored lifecycle is asked for `.inferred false` where the source asserted
`.native false`. Until canonical tool identity could travel out of band, this
`Bash`/`.bash` call was forced to the prose carrier, and the carrier replayed
the exact `ErrorSignal` with it; the pin recorded that as `.native false` on
both sides. The call is now a real `function_call`, so its result is a real
`function_call_output` — a record with no error field, from which Codex's own
importer re-infers the value. Trading the target's native lifecycle for one
scalar's provenance was the defect, not the fix: the value is unchanged and the
normalization is reported (`LoomOps.Interop`, `errorProvenance := some false`
for codex). What the pin is actually about — that no Claude markup reaches the
decoded target surface — is unchanged and still checked on both sides. -/
def codexClaudeMarkupAbsentFromDecodedTargetText : Bool :=
  codexMarkupToolLifecycleShape codexMarkupControlArchiveFixture (.native false) &&
  match exportCodexCliChecked codexMarkupControlArchiveFixture with
  | .error _ => false
  | .ok exported =>
      match parseCodexSession exported, importCodexCli exported with
      | .ok (header, records), .ok restored =>
          let targetSurface := codexDecodedTargetRecordSurface records
          codexClaudeMarkupNeedles.all (fun needle =>
            !hasSub targetSurface needle) &&
          !hasSub targetSurface codexClaudeControlMarkup &&
          !hasSub targetSurface codexClaudeToolWrapperMarkup &&
          codexMarkupToolLifecycleShape restored
            (.inferred false "codexOutputIndicatesError (codexAdapter.ts:75)") &&
          (parseCodexSourceArchive? header).any (fun archive =>
            archive.sourceControls == codexMarkupSourceControls &&
            archive.sourceControls[0]?.bind (fun raw => ostr raw "raw") ==
              some codexClaudeControlMarkup &&
            archive.sourceControls[1]?.bind (fun raw => ostr raw "raw") ==
              some codexClaudeToolWrapperMarkup) &&
          restored.origin.extras.bind (fun extras =>
            oarr extras "raw_control_messages") == some codexMarkupSourceControls
      | _, _ => false

example : codexClaudeMarkupAbsentFromDecodedTargetText = true := by
  native_decide
private def codexEnvironmentCarrierShape (transcript : Transcript) : Bool :=
  transcript.entries.size == 1 &&
  match transcript.entries[0]? with
  | some entry => match entry.payload with
    | .envMsg [.unmodeled "foreign-environment" raw] =>
        oobj raw "exact" == some (Json.bool true)
    | _ => false
  | none => false

/-- A fresh resumable target reads launch metadata and operational controls only
from explicit target extras. Conflicting source `EnvInfo` remains in the inert
archive and is restored on import. Re-export is byte-stable. -/
def codexGeneratedDefaultsAndEnvironmentTwinAreSafe : Bool :=
  match exportCodexCliChecked codexEnvironmentCarrierTwinFixture with
  | .error _ => false
  | .ok exported =>
    match parseCodexSession exported, importCodexCli exported with
    | .ok (header, records), .ok restored =>
        let generated := restored.origin.extras.bind (fun extras =>
          oarr extras "raw_generated_target_controls")
        let sourceControls := restored.origin.extras.bind (fun extras =>
          oarr extras "raw_control_messages")
        let targetExtrasOk := restored.origin.extras.any (fun extras =>
          ostr extras "target_timestamp" == some codexTargetTestTimestamp &&
          ostr extras "target_session_id" == some codexTargetTestId &&
          ostr extras "target_cwd" == some "/tmp/generated-target" &&
          ostr extras "target_provider" == some "openai" &&
          ostr extras "target_model" == some codexTargetTestModel &&
          ostr extras "target_harness_version" == some codexCliTargetVersion &&
          oobj extras codexTargetControlsKey == some codexTargetTestControls)
        let contextOk := match records.filter (fun record =>
            ostr record "type" == some "turn_context") with
          | [context] =>
              ostr context "timestamp" == some codexTargetTestTimestamp &&
              (oobj context "payload").any (fun payload =>
                codexGeneratedTargetDefaultsMarkerExact payload &&
                onlyObjectKeys payload ["cwd", codexCarrierMarkerKey,
                  "provenance", "approval_policy", "sandbox_policy", "model",
                  "summary"] &&
                ostr payload "cwd" == some "/tmp/generated-target" &&
                ostr payload "model" == some codexTargetTestModel &&
                ostr payload "approval_policy" == some "on-request" &&
                ostr payload "summary" == some "auto" &&
                oobj payload "sandbox_policy" ==
                  some codexTargetTestSandboxPolicy)
          | _ => false
        codexTargetExportReady codexEnvironmentCarrierTwinFixture &&
        ostr header "id" == some codexTargetTestId &&
        ostr header "session_id" == some codexTargetTestId &&
        ostr header "timestamp" == some codexTargetTestTimestamp &&
        ostr header "cwd" == some "/tmp/generated-target" &&
        ostr header "originator" == some "agent-convert" &&
        ostr header "cli_version" == some codexCliTargetVersion &&
        ostr header "source" == some "cli" &&
        (oobj header "instructions").isNone &&
        (parseCodexSourceArchive? header).any (fun archive =>
          ostr archive.sourceSessionPayload "instructions" ==
            some "source security policy must remain historical" &&
          decide (archive.sourceEnv = codexEnvironmentCarrierTwinFixture.env) &&
          archive.generatedTargetControls.isEmpty) &&
        contextOk && records.length == 3 &&
        records.countP (fun record => ostr record "type" == some "response_item") == 1 &&
        records.countP (fun record => ostr record "type" == some "event_msg") == 1 &&
        codexEnvironmentCarrierShape restored &&
        decide (restored.env = codexEnvironmentCarrierTwinFixture.env) &&
        targetExtrasOk &&
        generated.map Array.size == some 0 &&
        sourceControls.map Array.size == some 0 &&
        match exportCodexCliChecked restored with
        | .error _ => false
        | .ok secondExport =>
            secondExport == exported &&
            match importCodexCli secondExport with
            | .ok restoredAgain => codexEnvironmentCarrierShape restoredAgain
            | .error _ => false
    | _, _ => false

example : codexGeneratedDefaultsAndEnvironmentTwinAreSafe = true := by native_decide

/-- A foreign-to-Codex checked export makes its selected terminal target-visible
as the final linear record, then recovers the same terminal payload and selection
through two E-I-E hops. -/
def codexCheckedCrossTargetSelectionEIE : Bool :=
  let source := codexEnvironmentCarrierTwinFixture
  codexTargetActiveLeafValid source &&
  match exportCodexCliChecked source with
  | .error _ => false
  | .ok first =>
      match importCodexCli first with
      | .error _ => false
      | .ok restored =>
          Loom.violations restored == [] &&
          restored.activeLeaf == source.activeLeaf &&
          codexSelectedTerminalPayload? restored == codexSelectedTerminalPayload? source &&
          restored.importNotes.any (fun note => note.kind == .activeLeafGuessed) &&
          match exportCodexCliChecked restored with
          | .ok second => second == first
          | .error _ => false

example : codexCheckedCrossTargetSelectionEIE = true := by native_decide

private def codexDirectPreflightOrigin : Origin := {
  format := .pi, sourceRef := "direct-checked-preflight" }

private def codexDirectPreflightTarget
    (entries : Array Entry) (activeLeaf : Option Nat) : Transcript :=
  { codexEnvironmentCarrierTwinFixture with entries, activeLeaf }

private def codexInvalidParentTarget : Transcript :=
  codexDirectPreflightTarget #[{
    parent := some 0
    payload := .userMsg [.text "invalid parent"]
    origin := codexDirectPreflightOrigin }] (some 0)

private def codexInvalidThreadTarget : Transcript :=
  codexDirectPreflightTarget #[{
    thread := 1
    payload := .userMsg [.text "invalid thread"]
    origin := codexDirectPreflightOrigin }] (some 0)

private def codexInvalidCallRefTarget : Transcript :=
  codexDirectPreflightTarget #[{
    payload := .envMsg [.toolResult (.resolved 9 0) [.text "orphan"] .unrecorded]
    origin := codexDirectPreflightOrigin }] (some 0)

private def codexCheckedStructuralRefusal (transcript : Transcript) : Bool :=
  match exportCodexCliChecked transcript with
  | .error message => hasSub message "Codex source IR has" &&
      hasSub message "structural violations"
  | .ok _ => false

/-- Structural validity belongs to the direct checked API, not only its CLI
caller. A prior successful call cannot turn any later rejection into output. -/
def codexCheckedExportRejectsInvalidSourceBeforeOutput : Bool :=
  (Loom.violations codexInvalidParentTarget).contains (.parentNotEarlier 0 0) &&
  (Loom.violations codexInvalidThreadTarget).contains (.threadOutOfRange 0 1) &&
  (Loom.violations codexInvalidCallRefTarget).contains (.callRefNotEarlier 0 9) &&
  match exportCodexCliChecked codexEnvironmentCarrierTwinFixture with
  | .error _ => false
  | .ok _staleSuccess =>
      [codexInvalidParentTarget, codexInvalidThreadTarget,
        codexInvalidCallRefTarget].all codexCheckedStructuralRefusal

example : codexCheckedExportRejectsInvalidSourceBeforeOutput = true := by
  native_decide

private def codexLossyNonterminalUnknownUserTarget : Transcript :=
  codexDirectPreflightTarget #[
    { payload := .userMsg [.unmodeled "foreign-user-block"
        (Json.mkObj [("opaque", Json.bool true)])]
      origin := codexDirectPreflightOrigin },
    { parent := some 0
      payload := .assistantMsg [.text "selected terminal survives"]
      origin := codexDirectPreflightOrigin }
  ] (some 1)

private def codexEmptyUserTarget : Transcript :=
  codexDirectPreflightTarget #[{
    payload := .userMsg []
    origin := codexDirectPreflightOrigin }] (some 0)

private def codexEmptyAssistantTarget : Transcript :=
  codexDirectPreflightTarget #[{
    payload := .assistantMsg []
    origin := codexDirectPreflightOrigin }] (some 0)

private def codexEmptyEnvironmentTarget : Transcript :=
  codexDirectPreflightTarget #[{
    payload := .envMsg []
    origin := codexDirectPreflightOrigin }] (some 0)

private def codexNativeOtherRoleTarget : Transcript :=
  codexDirectPreflightTarget #[{
    payload := .otherMsg "system" [.text "native unsupported role"]
    origin := codexDirectPreflightOrigin }] (some 0)

private def codexNativeStructuredEventTarget : Transcript :=
  codexDirectPreflightTarget #[{
    payload := .event (.permissionMode "plan")
    origin := codexDirectPreflightOrigin }] (some 0)

private def codexBranchedTarget : Transcript :=
  codexDirectPreflightTarget #[
    { payload := .userMsg [.text "root"]
      origin := codexDirectPreflightOrigin },
    { parent := some 0
      payload := .assistantMsg [.text "abandoned branch"]
      origin := codexDirectPreflightOrigin },
    { parent := some 0
      payload := .assistantMsg [.text "selected branch"]
      origin := codexDirectPreflightOrigin }
  ] (some 2)

private def codexDestructiveDirectCases :
    List (Transcript × Loom.Ops.Obligation) := [
  (codexLossyNonterminalUnknownUserTarget, .dropUnmodeled),
  (codexEmptyUserTarget, .dropUnmodeled),
  (codexEmptyAssistantTarget, .dropUnmodeled),
  (codexEmptyEnvironmentTarget, .dropToolResults),
  (codexNativeOtherRoleTarget, .dropOtherRoles),
  (codexNativeStructuredEventTarget, .dropEvents),
  (codexBranchedTarget, .linearizeBranches)]

private def codexCheckedDestructiveRefusal
    (test : Transcript × Loom.Ops.Obligation) : Bool :=
  let (transcript, expected) := test
  let all := Loom.Ops.obligations .codexCli transcript
  Loom.violations transcript == [] && all.contains expected &&
    Loom.Ops.obligationIsDestructiveFor .codexCli transcript expected &&
    match exportCodexCliChecked transcript with
    | .error message => hasSub message "destructive export obligations"
    | .ok _ => false

/-- The unchecked forensic renderer demonstrates the original hidden loss: a
nonterminal unknown user block disappears while the terminal still validates.
The checked API now rejects it and every other destructive Codex obligation. -/
def codexCheckedExportRejectsDestructiveSourceBeforeOutput : Bool :=
  (match importCodexCli (exportCodexCli codexLossyNonterminalUnknownUserTarget) with
   | .ok restored => restored.entries.size == 1 &&
       (match restored.entries[0]? with
        | some entry => match entry.payload with
          | .assistantMsg [.text "selected terminal survives"] => true
          | _ => false
        | none => false)
   | .error _ => false) &&
  codexDestructiveDirectCases.all codexCheckedDestructiveRefusal

example : codexCheckedExportRejectsDestructiveSourceBeforeOutput = true := by
  native_decide

private def codexTargetRefusalContains (transcript : Transcript)
    (expected : String) : Bool :=
  (codexTargetExportPrerequisiteFailures transcript).contains expected &&
  match exportCodexCliChecked transcript with
  | .error message => hasSub message expected
  | .ok _ => false

private def codexTargetFixtureExtra (transcript : Transcript) (key : String)
    (value : Option Json) : Transcript :=
  let extras := match transcript.origin.extras with
    | some (.obj fields) => Json.obj (match value with
        | some replacement => fields.insert key replacement
        | none => fields.erase key)
    | _ => Json.mkObj (value.toList.map (key, ·))
  { transcript with origin := { transcript.origin with extras := some extras } }

/-- Every launch value and operational control has a named checked-export
prerequisite in `origin.extras`. Conflicting source `EnvInfo` is irrelevant to
these checks; each target-extra mutation proves the corresponding refusal. -/
def codexFreshTargetMetadataPrerequisitesArePrecise : Bool :=
  let base := codexEnvironmentCarrierTwinFixture
  let noTimestamp := codexTargetFixtureExtra base "target_timestamp" none
  let badTimestamp := codexTargetFixtureExtra base "target_timestamp"
    (some (Json.str "not-a-timestamp"))
  let badId := codexTargetFixtureExtra base "target_session_id"
    (some (Json.str "not-a-uuid"))
  let badCwd := codexTargetFixtureExtra base "target_cwd"
    (some (Json.str "relative/path"))
  let noModel := codexTargetFixtureExtra base "target_model" none
  let noProvider := codexTargetFixtureExtra base "target_provider" none
  let badVersion := codexTargetFixtureExtra base "target_harness_version"
    (some (Json.str "0.143.0"))
  let noControls := codexTargetFixtureExtra base codexTargetControlsKey none
  let malformedControls := codexTargetFixtureExtra base codexTargetControlsKey
    (some (Json.mkObj [
      ("protocol", Json.str codexTargetControlsProtocol),
      ("approval_policy", Json.str "on-request")]))
  let noActiveLeaf := { base with activeLeaf := none }
  let wrongActiveLeaf := { base with activeLeaf := some 1 }
  let invalidMediaEntry : Entry := {
    payload := .userMsg [UserBlock.media "image"
      "https://example.invalid/not-inline.png"]
    origin := { format := .pi, sourceRef := "invalid-target-media" } }
  let invalidMedia := { base with
    entries := #[invalidMediaEntry]
    activeLeaf := some 0 }
  let malformedImageEntry : Entry := {
    payload := .userMsg [.unmodeled codexMessageContentLabel (Json.mkObj [
      ("type", Json.str "input_image"),
      ("image_url", Json.str "https://example.invalid/raw.png")])]
    origin := { format := .codexCli, sourceRef := "malformed-target-media" } }
  let malformedImage := { base with
    entries := #[malformedImageEntry]
    activeLeaf := some 0 }
  codexTargetExportReady base &&
  (match exportCodexCliChecked base with | .ok _ => true | .error _ => false) &&
  codexTargetRefusalContains noTimestamp
    "Codex target requires explicit origin.extras.target_timestamp" &&
  codexTargetRefusalContains badTimestamp
    "Codex target_timestamp must be UTC ISO-8601 with seconds or millisecond precision" &&
  codexTargetRefusalContains badId
    "Codex target_session_id must be a UUID" &&
  codexTargetRefusalContains badCwd
    "Codex target_cwd must be an absolute path" &&
  codexTargetRefusalContains noModel
    "Codex target requires explicit origin.extras.target_model" &&
  codexTargetRefusalContains noProvider
    "Codex target requires explicit origin.extras.target_provider" &&
  codexTargetRefusalContains badVersion
    "Codex target_harness_version must be 0.144.1" &&
  codexTargetRefusalContains noControls
    "Codex target requires explicit origin.extras.target_codex_controls" &&
  codexTargetRefusalContains malformedControls
    "origin.extras.target_codex_controls must be an exact agent-convert.codex-target-controls.v1 object" &&
  codexTargetRefusalContains noActiveLeaf codexActiveLeafPreflightError &&
  codexTargetRefusalContains wrongActiveLeaf codexActiveLeafPreflightError &&
  codexTargetRefusalContains invalidMedia
    "Codex target media must use mime 'image' and a valid inline base64 image data URI" &&
  codexTargetRefusalContains malformedImage
    "Codex target media must use mime 'image' and a valid inline base64 image data URI"

example : codexFreshTargetMetadataPrerequisitesArePrecise = true := by native_decide

private def codexAlternateTargetSandboxPolicy : Json := Json.mkObj [
  ("type", Json.str "workspace-write"),
  ("network_access", Json.bool true),
  ("exclude_tmpdir_env_var", Json.bool true),
  ("exclude_slash_tmp", Json.bool true)]

private def codexAlternateTargetControls : Json := Json.mkObj [
  ("protocol", Json.str codexTargetControlsProtocol),
  ("approval_policy", Json.str "never"),
  ("sandbox_policy", codexAlternateTargetSandboxPolicy),
  ("summary", Json.str "detailed")]

private def codexStaleTargetContext : Json := Json.mkObj [
  ("timestamp", Json.str codexTargetTestTimestamp),
  ("type", Json.str "turn_context"),
  ("payload", Json.mkObj [
    ("cwd", Json.str "/tmp/generated-target"),
    (codexCarrierMarkerKey, codexMarker codexGeneratedTargetDefaultsKind),
    ("provenance", Json.str
      "explicit target controls from origin.extras.target_codex_controls"),
    ("approval_policy", Json.str "on-request"),
    ("sandbox_policy", codexTargetTestSandboxPolicy),
    ("model", Json.str codexTargetTestModel),
    ("summary", Json.str "auto")])]

/-- Explicit typed target controls override both source-environment state and a
stale preserved target context. The chosen values survive re-import in target
extras, while source `EnvInfo` remains exactly reversible. -/
def codexExplicitTargetControlsResolveConflicts : Bool :=
  let withControls := codexTargetFixtureExtra codexEnvironmentCarrierTwinFixture
    codexTargetControlsKey (some codexAlternateTargetControls)
  let withStale := codexTargetFixtureExtra withControls
    "target_turn_context_record" (some codexStaleTargetContext)
  let source := { withStale with origin := {
    withStale.origin with format := .codexCli } }
  match exportCodexCliChecked source with
  | .error _ => false
  | .ok first =>
      match parseCodexSession first, importCodexCli first with
      | .ok (header, records), .ok restored =>
          let contextOk := match records.filter (fun record =>
              ostr record "type" == some "turn_context") with
            | [context] => (oobj context "payload").any (fun payload =>
                ostr payload "approval_policy" == some "never" &&
                oobj payload "sandbox_policy" ==
                  some codexAlternateTargetSandboxPolicy &&
                ostr payload "summary" == some "detailed")
            | _ => false
          contextOk &&
          (parseCodexSourceArchive? header).any (fun archive =>
            decide (archive.sourceEnv = source.env)) &&
          decide (restored.env = source.env) &&
          restored.origin.extras.any (fun extras =>
            oobj extras codexTargetControlsKey ==
              some codexAlternateTargetControls) &&
          match exportCodexCliChecked restored with
          | .ok second => second == first
          | .error _ => false
      | _, _ => false

example : codexExplicitTargetControlsResolveConflicts = true := by native_decide

private def codexSourceTargetConfigurationArchiveKey : String :=
  "_agent_convert_source_target_configuration"

private def codexArchivedTargetConfiguration : Json := Json.mkObj [
  ("protocol", Json.str "agent-convert.source-target-configuration.v1"),
  ("prior", Json.null),
  ("cleared", Json.mkObj [
    ("target_timestamp", Json.str "2030-01-01T00:00:00Z"),
    ("target_session_id", Json.str "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
    ("target_cwd", Json.str "/archive/must-not-activate"),
    ("target_provider", Json.str "archive-provider"),
    ("target_model", Json.str "archive-model"),
    ("target_harness_version", Json.str codexCliTargetVersion),
    ("target_originator", Json.str "archive-originator"),
    (codexTargetControlsKey, codexAlternateTargetControls)])]

private def codexDirectTargetAuthorityKeys : List String := [
  "target_timestamp", "target_session_id", "target_cwd", "target_provider",
  "target_model", "target_harness_version", codexTargetControlsKey]

/-- Main's source-target configuration archive is provenance, never authority.
Nested archived values neither satisfy missing direct prerequisites nor override
explicit direct launch options and typed controls. -/
def codexArchivedTargetConfigurationNeverActivates : Bool :=
  let withArchive := codexTargetFixtureExtra codexEnvironmentCarrierTwinFixture
    codexSourceTargetConfigurationArchiveKey
    (some codexArchivedTargetConfiguration)
  let archiveOnly := codexDirectTargetAuthorityKeys.foldl (fun transcript key =>
    codexTargetFixtureExtra transcript key none) withArchive
  let archiveOnlyFailures := codexTargetExportPrerequisiteFailures archiveOnly
  !codexTargetExportReady archiveOnly &&
  archiveOnlyFailures.contains
    "Codex target requires explicit origin.extras.target_timestamp" &&
  archiveOnlyFailures.contains
    "Codex target requires explicit origin.extras.target_session_id" &&
  archiveOnlyFailures.contains
    "Codex target requires explicit origin.extras.target_cwd" &&
  archiveOnlyFailures.contains
    "Codex target requires explicit origin.extras.target_provider" &&
  archiveOnlyFailures.contains
    "Codex target requires explicit origin.extras.target_model" &&
  archiveOnlyFailures.contains
    "Codex target requires explicit origin.extras.target_harness_version 0.144.1" &&
  archiveOnlyFailures.contains
    "Codex target requires explicit origin.extras.target_codex_controls" &&
  match exportCodexCliChecked withArchive with
  | .error _ => false
  | .ok output =>
      match parseCodexSession output with
      | .ok (header, records) =>
          ostr header "id" == some codexTargetTestId &&
          ostr header "cwd" == some "/tmp/generated-target" &&
          ostr header "model_provider" == some "openai" &&
          ostr header "originator" == some "agent-convert" &&
          match records.filter (fun record =>
              ostr record "type" == some "turn_context") with
          | [context] => (oobj context "payload").any (fun payload =>
              ostr payload "model" == some codexTargetTestModel &&
              ostr payload "approval_policy" == some "on-request" &&
              oobj payload "sandbox_policy" ==
                some codexTargetTestSandboxPolicy &&
              ostr payload "summary" == some "auto")
          | _ => false
      | .error _ => false

example : codexArchivedTargetConfigurationNeverActivates = true := by native_decide

private def codexDistinctIdenticalTargetTurns : Transcript :=
  let source : Origin := { format := .pi, sourceRef := "identical-target-turn" }
  { codexEnvironmentCarrierTwinFixture with
    entries := #[
      { payload := .userMsg [.text "same visible text"], origin := source },
      { parent := some 0, payload := .userMsg [.text "same visible text"],
        origin := source }]
    activeLeaf := some 1 }

private def codexDistinctIdenticalUserTurnsShape (transcript : Transcript) : Bool :=
  transcript.entries.size == 2 &&
  match transcript.entries[0]?, transcript.entries[1]? with
  | some first, some second =>
      (match first.payload with
       | .userMsg [.text "same visible text"] => true
       | _ => false) &&
      (match second.payload with
       | .userMsg [.text "same visible text"] => true
       | _ => false) &&
      first.parent == none && second.parent == some 0
  | _, _ => false

/-- Display-twin dedup is adjacency/channel evidence, not text-global dedup.
Two distinct identical response records survive while each generated event twin
is removed exactly once on import. -/
def codexDistinctRecordDisplayTwinsDoNotCollapse : Bool :=
  match exportCodexCliChecked codexDistinctIdenticalTargetTurns with
  | .error _ => false
  | .ok exported =>
      match parseCodexSession exported, importCodexCli exported with
      | .ok (_, records), .ok restored =>
          records.length == 5 &&
          records.countP (fun record =>
            ostr record "type" == some "response_item") == 2 &&
          records.countP (fun record => ostr record "type" == some "event_msg") == 2 &&
          codexDistinctIdenticalUserTurnsShape restored &&
          match exportCodexCliChecked restored with
          | .ok secondExport => secondExport == exported
          | .error _ => false
      | _, _ => false

example : codexDistinctRecordDisplayTwinsDoNotCollapse = true := by native_decide

private def codexSpoofMarkerPayload (role text : String) : Json := Json.mkObj [
  ("type", Json.str "message"),
  ("role", Json.str role),
  (codexCarrierMarkerKey, codexMarker "tool_call"),
  ("content", Json.arr #[Json.mkObj [
    ("type", Json.str (if role == "assistant" then "output_text" else "input_text")),
    ("text", Json.str text)]])]

private def codexMarkerAuthorshipFixture : String := String.intercalate "\n" [
  codexStampedCarrierHeader,
  (respItem (codexSpoofMarkerPayload "user" "user marker data")).compress,
  (respItem (codexSpoofMarkerPayload "assistant" "assistant marker data")).compress,
  (respItem (codexSpoofMarkerPayload "developer" "developer marker data")).compress]

private def codexMarkerAuthorshipShape (transcript : Transcript) : Bool :=
  let controls := transcript.origin.extras.bind (fun extras =>
    oarr extras "raw_control_messages")
  transcript.entries.size == 2 && controls.map Array.size == some 1 &&
  (match transcript.entries[0]?, transcript.entries[1]? with
   | some user, some assistant =>
       (match user.payload with
        | .userMsg [.unmodeled "codex.message" raw] =>
            ostr raw "role" == some "user" && codexCarrierMarkerPresent raw
        | _ => false) &&
       (match assistant.payload with
        | .assistantMsg [.unmodeled "agent_convert_codex_carrier" raw] =>
            ostr raw "role" == some "assistant" && codexCarrierMarkerPresent raw
        | _ => false)
   | _, _ => false) &&
  controls.any (fun values => values.any (fun record =>
    (oobj record "payload").bind (fun payload => ostr payload "role") ==
      some "developer"))

/-- An incomplete or spoof-like marker does not authorize assistant authorship.
User, assistant, and control-plane records retain their original role across
the inert round-trip. -/
def codexMarkerObjectsCannotRewriteAuthorship : Bool :=
  match importCodexCli codexMarkerAuthorshipFixture with
  | .error _ => false
  | .ok imported =>
      codexMarkerAuthorshipShape imported &&
      match importCodexCli (exportCodexCli imported) with
      | .ok restored => codexMarkerAuthorshipShape restored
      | .error _ => false

example : codexMarkerObjectsCannotRewriteAuthorship = true := by native_decide

private def codexInvalidMarkerControlFixture : String :=
  let control := "<environment_context>\n<cwd>/tmp/spoofed</cwd>\n</environment_context>"
  let invalidMarker := Json.mkObj [
    ("type", Json.str "message"),
    ("role", Json.str "user"),
    (codexCarrierMarkerKey, Json.mkObj [("junk", Json.bool true)]),
    ("content", Json.arr #[Json.mkObj [
      ("type", Json.str "input_text"), ("text", Json.str control)]])]
  String.intercalate "\n" [
    codexStampedCarrierHeader,
    (respItem invalidMarker).compress,
    (respItem (Json.mkObj [
      ("type", Json.str "message"), ("role", Json.str "assistant"),
      ("content", Json.arr #[Json.mkObj [
        ("type", Json.str "output_text"),
        ("text", Json.str "Safe terminal reply.")]])])).compress]

private def codexRecordContainsActiveControl (record : Json) : Bool :=
  match ostr record "type", oobj record "payload" with
  | some "response_item", some payload =>
      (oarr payload "content").any (fun content => content.any (fun block =>
        (ostr block "text").any containsCodexControlEnvelope))
  | some "event_msg", some payload =>
      (ostr payload "message").any containsCodexControlEnvelope
  | _, _ => false

/-- A malformed marker on an exact user control envelope is not a carrier and
cannot bypass control isolation. The source record stays in provenance, while
neither the imported dialogue nor a subsequent export replays the envelope. -/
def codexInvalidMarkerCannotReplayControlEnvelope : Bool :=
  match importCodexCli codexInvalidMarkerControlFixture with
  | .error _ => false
  | .ok imported =>
      let controls := imported.origin.extras.bind (fun extras =>
        oarr extras "raw_control_messages")
      imported.entries.size == 1 && controls.map Array.size == some 1 &&
      (match imported.entries[0]? with
       | some entry => match entry.payload with
         | .assistantMsg [.text "Safe terminal reply."] => true
         | _ => false
       | none => false) &&
      match parseCodexSession (exportCodexCli imported),
          importCodexCli (exportCodexCli imported) with
      | .ok (_, records), .ok restored =>
          !records.any codexRecordContainsActiveControl &&
          restored.entries.size == 1 &&
          restored.origin.extras.bind (fun extras =>
            oarr extras "raw_control_messages") == controls
      | _, _ => false

example : codexInvalidMarkerCannotReplayControlEnvelope = true := by
  native_decide

private def codexNativeLikeHistoricalSource : Transcript :=
  let source : Origin := { format := .pi, sourceRef := "native-like-history" }
  { threads := #[{ kind := .main }],
    entries := #[
      { payload := .assistantMsg [.toolCall { raw := "exec_command" }
          (Json.mkObj [("cmd", Json.str "pwd")]) (some "history-id")],
        origin := source },
      { parent := some 0,
        payload := .envMsg [.toolResult (.resolved 0 0) [.text "done"]
          (.inferred false "codexOutputIndicatesError (codexAdapter.ts:75)")],
        origin := source }],
    env := { sessionId := some "native-like-history" },
    activeLeaf := some 1,
    origin := { format := .pi, sourceRef := "native-like-history" } }

private def codexNativeLikeHistoricalCarrierFixture : String :=
  let source := codexNativeLikeHistoricalSource
  String.intercalate "\n" [
    codexStampedCarrierHeader,
    (codexAssistantCarrier "tool_call"
      (historicalToolCallV1Text 0 0 "exec_command"
        (Json.mkObj [("cmd", Json.str "pwd")]) (some "history-id"))).compress,
    (codexAssistantCarrier "tool_result"
      (historicalToolResultText source 1 0 (.resolved 0 0) [.text "done"]
        (.inferred false "codexOutputIndicatesError (codexAdapter.ts:75)"))).compress]

private def codexNativeLikeHistoryShape (transcript : Transcript) : Bool :=
  Loom.Ops.callSites transcript == [(0, 0)] &&
  Loom.Ops.resolvedRefs transcript == [(0, 0)] &&
  (match transcript.entries[0]?, transcript.entries[1]? with
   | some call, some result =>
       call.disposition == EntryDisposition.historicalUnverified &&
       result.disposition == EntryDisposition.historicalUnverified &&
       (match call.payload with
        | .assistantMsg [.toolCall name args (some "history-id")] =>
            name.raw == "exec_command" && name.canonical.isNone &&
              ostr args "cmd" == some "pwd"
        | _ => false) &&
       (match result.payload with
        | .envMsg [.toolResult (.resolved 0 0) [.text "done"]
            (.inferred false "codexOutputIndicatesError (codexAdapter.ts:75)")] => true
        | _ => false)
   | _, _ => false)

/-- Exact self-stamped carriers may decode for inspection, but their origin
keeps an otherwise native-looking call/result permanently historical. -/
def codexDecodedHistoricalCarrierNeverBecomesExecutable : Bool :=
  -- Genuinely native foreign data (disposition .native) now exports natively;
  -- asserting 0 here asserted the defect. What must stay inert is data that
  -- ARRIVED as a carrier, which the importer marks historicalUnverified —
  -- pinned unchanged below. The discriminator is disposition, not format.
  codexNativeToolCallCount codexNativeLikeHistoricalSource == 1 &&
  codexNativeToolResultCount codexNativeLikeHistoricalSource == 1 &&
  match importCodexCli codexNativeLikeHistoricalCarrierFixture with
  | .error _ => false
  | .ok imported =>
      let exported := exportCodexCli imported
      codexNativeLikeHistoryShape imported &&
      codexNativeToolCallCount imported == 0 &&
      codexNativeToolResultCount imported == 0 &&
      match parseCodexSession exported, importCodexCli exported with
      | .ok (_, records), .ok restored =>
          !records.any (fun record =>
            let payloadType := (oobj record "payload").bind (fun payload =>
              ostr payload "type")
            payloadType == some "function_call" ||
              payloadType == some "function_call_output") &&
          codexNativeLikeHistoryShape restored &&
          codexNativeToolCallCount restored == 0
      | _, _ => false

example : codexDecodedHistoricalCarrierNeverBecomesExecutable = true := by native_decide

private def codexTypedHistoricalTargetFixture : Transcript :=
  let source : Origin := {
    format := .pi, sourceRef := "metadata-will-be-stripped",
    extras := some (Json.mkObj [("source_note", Json.str "not authority")]) }
  { codexEnvironmentCarrierTwinFixture with
    entries := #[
      { time := .recorded ⟨1700000000000⟩,
        payload := .assistantMsg [.text "native-looking historical message"],
        origin := source,
        disposition := .historicalUnverified },
      { parent := some 0,
        time := .recorded ⟨1700000000001⟩,
        payload := .assistantMsg [.toolCall { raw := "exec_command" }
          (Json.mkObj [("cmd", Json.str "pwd")]) (some "historical-native-id")],
        origin := source,
        disposition := .historicalUnverified },
      { parent := some 1,
        time := .recorded ⟨1700000000002⟩,
        payload := .envMsg [.toolResult (.resolved 1 0) [.text "done"]
          (.inferred false "codexOutputIndicatesError (codexAdapter.ts:75)")],
        origin := source,
        disposition := .historicalUnverified },
      { parent := some 2,
        time := .recorded ⟨1700000000003⟩,
        payload := .compaction "native-looking historical compaction"
          (.knownPrefix 0) (some 37),
        origin := source,
        disposition := .historicalUnverified }]
    activeLeaf := some 3 }

private def stripCodexEntryOriginMetadata (transcript : Transcript) : Transcript :=
  { transcript with entries := transcript.entries.map (fun entry =>
      { entry with origin := { entry.origin with sourceRef := "", extras := none } }) }

private def codexTypedHistoricalShape (transcript : Transcript) : Bool :=
  transcript.entries.size == 4 &&
  transcript.entries.all (fun entry =>
    entry.disposition == EntryDisposition.historicalUnverified) &&
  match transcript.entries[0]?, transcript.entries[1]?,
      transcript.entries[2]?, transcript.entries[3]? with
  | some message, some call, some result, some compaction =>
      (match message.payload with
       | .assistantMsg [.text "native-looking historical message"] => true
       | _ => false) &&
      (match call.payload with
       | .assistantMsg [.toolCall name args (some "historical-native-id")] =>
           name.raw == "exec_command" && ostr args "cmd" == some "pwd"
       | _ => false) &&
      (match result.payload with
       | .envMsg [.toolResult (.resolved 1 0) [.text "done"]
           (.inferred false "codexOutputIndicatesError (codexAdapter.ts:75)")] => true
       | _ => false) &&
      (match compaction.payload with
       | .compaction "native-looking historical compaction"
           (.knownPrefix 0) (some 37) => true
       | _ => false)
  | _, _, _, _ => false

private def codexResponseCarrierKinds (records : List Json) : List String :=
  records.filterMap (fun record => do
    guard (ostr record "type" == some "response_item")
    codexCarrierKind? (← oobj record "payload"))

private def codexRecordTimestampsOfType
    (records : List Json) (recordType : String) : List (Option String) :=
  records.filterMap (fun record =>
    if ostr record "type" == some recordType
    then some (ostr record "timestamp") else none)

private def codexTypedHistoricalRecordsStayInert (records : List Json) : Bool :=
  codexResponseCarrierKinds records == ["entry", "tool_call", "tool_result", "entry"] &&
  codexRecordTimestampsOfType records "response_item" == [
    some "2023-11-14T22:13:20.000Z",
    some "2023-11-14T22:13:20.001Z",
    some "2023-11-14T22:13:20.002Z",
    some "2023-11-14T22:13:20.003Z"] &&
  codexRecordTimestampsOfType records "event_msg" == [
    some "2023-11-14T22:13:20.000Z",
    some "2023-11-14T22:13:20.001Z",
    some "2023-11-14T22:13:20.002Z",
    some "2023-11-14T22:13:20.003Z"] &&
  !records.any (fun record =>
    ostr record "type" == some "compacted" ||
      (oobj record "payload").any (fun payload =>
        ostr payload "type" == some "function_call" ||
          ostr payload "type" == some "function_call_output"))

/-- Typed historical status, not format-private origin metadata, controls
Codex native eligibility. Strip every entry's `Origin.sourceRef` and
`Origin.extras`, then cross two import/export hops: calls/results never become
native, message/compaction payloads remain reversible carriers, dispositions
remain historical, timestamps remain exact, and E-I-E stays byte-stable. -/
def codexHistoricalDispositionSurvivesMetadataStrippingAndSecondHop : Bool :=
  let source := stripCodexEntryOriginMetadata codexTypedHistoricalTargetFixture
  codexTypedHistoricalShape source &&
  codexNativeToolCallCount source == 0 && codexNativeToolResultCount source == 0 &&
  match exportCodexCliChecked source with
  | .error _ => false
  | .ok firstExport =>
      match parseCodexSession firstExport, importCodexCli firstExport with
      | .ok (_, firstRecords), .ok firstImport =>
          let strippedFirst := stripCodexEntryOriginMetadata firstImport
          codexTypedHistoricalRecordsStayInert firstRecords &&
          codexTypedHistoricalShape strippedFirst &&
          codexNativeToolCallCount strippedFirst == 0 &&
          codexNativeToolResultCount strippedFirst == 0 &&
          match exportCodexCliChecked strippedFirst with
          | .error _ => false
          | .ok secondExport =>
              match parseCodexSession secondExport, importCodexCli secondExport with
              | .ok (_, secondRecords), .ok secondImport =>
                  let strippedSecond := stripCodexEntryOriginMetadata secondImport
                  firstExport == secondExport &&
                  codexTypedHistoricalRecordsStayInert secondRecords &&
                  codexTypedHistoricalShape strippedSecond &&
                  codexNativeToolCallCount strippedSecond == 0 &&
                  codexNativeToolResultCount strippedSecond == 0 &&
                  match exportCodexCliChecked strippedSecond with
                  | .ok thirdExport => thirdExport == secondExport
                  | .error _ => false
              | _, _ => false
      | _, _ => false

example : codexHistoricalDispositionSurvivesMetadataStrippingAndSecondHop = true := by
  native_decide

private def codexStructuredEventsTargetFixture : Transcript :=
  let source : Origin := { format := .pi, sourceRef := "structured-event" }
  { codexEnvironmentCarrierTwinFixture with
    entries := #[
      { payload := .event (.modelChange (some "source-model")
          (some "next-model")), origin := source },
      { parent := some 0,
        payload := .event (.thinkingLevelChange none (some "high")),
        origin := source },
      { parent := some 1,
        payload := .event (.permissionMode "plan"), origin := source },
      { parent := some 2,
        payload := .event (.branchSummary "selected branch summary"),
        origin := source }]
    activeLeaf := some 3 }

private def codexStructuredEventsShape (transcript : Transcript) : Bool :=
  transcript.entries.size == 4 &&
  match transcript.entries[0]?, transcript.entries[1]?,
      transcript.entries[2]?, transcript.entries[3]? with
  | some model, some thinking, some permission, some summary =>
      (match model.payload with
       | .event (.modelChange (some "source-model") (some "next-model")) => true
       | _ => false) &&
      (match thinking.payload with
       | .event (.thinkingLevelChange none (some "high")) => true
       | _ => false) &&
      (match permission.payload with
       | .event (.permissionMode "plan") => true
       | _ => false) &&
      (match summary.payload with
       | .event (.branchSummary "selected branch summary") => true
       | _ => false)
  | _, _, _, _ => false

/-- Codex has no native record for Loom's structured meta events. Native events
are refused as destructive; explicitly historical events use the versioned
inert entry carrier and remain exact across two checked hops. -/
def codexStructuredEventsUseInertCarrierTwoHops : Bool :=
  let native := stripCodexEntryOriginMetadata codexStructuredEventsTargetFixture
  let source := { native with entries := native.entries.map (fun entry =>
    { entry with disposition := .historicalUnverified }) }
  codexStructuredEventsShape native &&
  (Loom.Ops.obligations .codexCli native).contains .dropEvents &&
  (match exportCodexCliChecked native with
   | .error message => hasSub message "destructive export obligations"
   | .ok _ => false) &&
  codexStructuredEventsShape source &&
  match exportCodexCliChecked source with
  | .error _ => false
  | .ok first =>
      match parseCodexSession first, importCodexCli first with
      | .ok (_, firstRecords), .ok firstImport =>
          let strippedFirst := stripCodexEntryOriginMetadata firstImport
          codexResponseCarrierKinds firstRecords == ["entry", "entry", "entry", "entry"] &&
          (firstRecords.filter (fun record =>
            ostr record "type" == some "event_msg")).all (fun record =>
              (oobj record "payload" >>= fun payload => ostr payload "type") ==
                some "agent_message") &&
          codexStructuredEventsShape strippedFirst &&
          strippedFirst.entries.all (fun entry =>
            entry.disposition == EntryDisposition.historicalUnverified) &&
          match exportCodexCliChecked strippedFirst with
          | .error _ => false
          | .ok second =>
              second == first &&
              match importCodexCli second with
              | .ok secondImport =>
                  codexStructuredEventsShape secondImport &&
                  secondImport.activeLeaf == some 3
              | .error _ => false
      | _, _ => false

example : codexStructuredEventsUseInertCarrierTwoHops = true := by native_decide

private def codexNativeToolRecordType? (record : Json) : Option String := do
  guard (ostr record "type" == some "response_item")
  ostr (← oobj record "payload") "type"

private def codexRecordsContainNativeTools (records : List Json) : Bool :=
  records.any (fun record =>
    match codexNativeToolRecordType? record with
    | some kind => ["function_call", "function_call_output",
        "custom_tool_call", "custom_tool_call_output"].contains kind
    | none => false)

private def codexExactNativeExecArgs : Json := Json.mkObj [
  ("cmd", Json.str "pwd"),
  ("workdir", Json.str "/tmp/native")]

private def codexExactNativeToolRecords : List Json := [
  Json.mkObj [
    ("timestamp", Json.str "2026-07-20T01:00:00.000Z"),
    ("type", Json.str "response_item"),
    ("future_transport", Json.mkObj [("exact", Json.bool true)]),
    ("payload", Json.mkObj [
      ("type", Json.str "function_call"),
      ("call_id", Json.str "native-exec"),
      ("name", Json.str "exec_command"),
      ("arguments", Json.str codexExactNativeExecArgs.compress),
      ("status", Json.str "completed")])],
  Json.mkObj [
    ("timestamp", Json.str "2026-07-20T01:00:01.000Z"),
    ("type", Json.str "response_item"),
    ("payload", Json.mkObj [
      ("type", Json.str "function_call_output"),
      ("call_id", Json.str "native-exec"),
      ("output", Json.str "exec result"),
      ("future_output", Json.bool true)])],
  Json.mkObj [
    ("timestamp", Json.str "2026-07-20T01:00:02.000Z"),
    ("type", Json.str "response_item"),
    ("payload", Json.mkObj [
      ("type", Json.str "custom_tool_call"),
      ("call_id", Json.str "native-patch"),
      ("name", Json.str "apply_patch"),
      ("input", Json.str "*** Begin Patch\n*** End Patch"),
      ("future_input", Json.num 7)])],
  Json.mkObj [
    ("timestamp", Json.str "2026-07-20T01:00:03.000Z"),
    ("type", Json.str "response_item"),
    ("payload", Json.mkObj [
      ("type", Json.str "custom_tool_call_output"),
      ("call_id", Json.str "native-patch"),
      ("output", Json.str "patch result"),
      ("future_output", Json.str "retained")])]]

private def codexExactNativeToolsFixture : String :=
  String.intercalate "\n" (
    "{\"type\":\"session_meta\",\"payload\":{\"id\":\"native-tools\"}}" ::
      codexExactNativeToolRecords.map Json.compress)

/-- Exact Codex records with linked results replay byte-identically and retain
their additive raw fields.

Removing the retained evidence no longer downgrades the lifecycle to prose: the
call is still structurally valid, so synthesis re-emits it natively. What is
lost without the original record is byte-exactness, not the lifecycle — the
distinction that lets a transcript return to Codex from another harness. -/
def codexExactImportedNativeToolCyclesStayExact : Bool :=
  match importCodexCli codexExactNativeToolsFixture with
  | .error _ => false
  | .ok imported =>
      let first := exportCodexCli imported
      let stripped := stripCodexEntryOriginMetadata imported
      codexNativeToolCallCount imported == 2 &&
      codexNativeToolResultCount imported == 2 &&
      codexHistoricalToolCallCount imported == 0 &&
      codexHistoricalToolResultCount imported == 0 &&
      Loom.Ops.resolvedRefs imported == [(0, 0), (2, 0)] &&
      codexNativeToolCallCount stripped == 2 &&
      codexNativeToolResultCount stripped == 2 &&
      codexHistoricalToolCallCount stripped == 0 &&
      codexHistoricalToolResultCount stripped == 0 &&
      (match parseCodexSession (exportCodexCli stripped) with
       | .ok (_, records) => codexRecordsContainNativeTools records
       | .error _ => false) &&
      match parseCodexSession first, importCodexCli first with
      | .ok (_, records), .ok restored =>
          records == codexExactNativeToolRecords &&
          codexNativeToolCallCount restored == 2 &&
          codexNativeToolResultCount restored == 2 &&
          exportCodexCli restored == first
      | _, _ => false

example : codexExactImportedNativeToolCyclesStayExact = true := by native_decide

private def codexCanonicalizedImportedNativeCallFixture : Transcript :=
  let rawRecord := codexExactNativeToolRecords.head?.getD Json.null
  let callOrigin : Origin := {
    format := .codexCli
    sourceRef := "entry0"
    extras := some (Json.mkObj [(codexNativeToolRawRecordKey, rawRecord)]) }
  let terminalOrigin : Origin := {
    format := .pi, sourceRef := "canonicalized-native-terminal" }
  { codexEnvironmentCarrierTwinFixture with
    entries := #[
      { time := .recorded ⟨1784518800000⟩
        payload := .assistantMsg [.toolCall {
            raw := "exec_command", canonical := some .bash }
          codexExactNativeExecArgs (some "native-exec")]
        origin := callOrigin },
      { parent := some 0
        payload := .assistantMsg [.text "Canonical name retained."]
        origin := terminalOrigin }]
    activeLeaf := some 1 }

/-- Raw Codex call provenance authorizes native replay only while the complete
tool name remains native. Adding a canonical interpretation forces the v2 inert
carrier, preserving that interpretation even when a later terminal would hide
the loss from terminal-only validation. -/
def codexCanonicalizedNativeEvidenceUsesV2Carrier : Bool :=
  let source := codexCanonicalizedImportedNativeCallFixture
  codexNativeToolCallCount source == 0 &&
  match exportCodexCliChecked source with
  | .error _ => false
  | .ok exported =>
      match parseCodexSession exported, importCodexCli exported with
      | .ok (_, records), .ok restored =>
          !codexRecordsContainNativeTools records &&
          records.any (fun record =>
            (oobj record "payload").any (fun payload =>
              codexCarrierKind? payload == some "tool_call" &&
                (codexCarrierMessageText? payload).any (fun text =>
                  hasSub text codexHistoricalToolCallCarrierV2))) &&
          restored.entries.size == 2 &&
          match restored.entries[0]? with
          | some entry => match entry.payload with
            | .assistantMsg [.toolCall name args (some "native-exec")] =>
                name.raw == "exec_command" && name.canonical == some .bash &&
                  args == codexExactNativeExecArgs
            | _ => false
          | none => false
      | _, _ => false

example : codexCanonicalizedNativeEvidenceUsesV2Carrier = true := by
  native_decide

private def codexForeignNativeLookingToolsFixture : Transcript :=
  let source : Origin := { format := .pi, sourceRef := "foreign-native-looking" }
  let ok := ErrorSignal.inferred false
    "codexOutputIndicatesError (codexAdapter.ts:75)"
  { codexEnvironmentCarrierTwinFixture with
    entries := #[
      { payload := .assistantMsg [.toolCall { raw := "exec_command" }
          (Json.mkObj [("cmd", Json.str "pwd")]) (some "foreign-exec")],
        origin := source },
      { parent := some 0,
        payload := .envMsg [.toolResult (.resolved 0 0) [.text "exec result"] ok],
        origin := source },
      { parent := some 1,
        payload := .assistantMsg [.toolCall { raw := "ApplyPatch" }
          (Json.mkObj [("patch", Json.str "*** Begin Patch\n*** End Patch")])
          (some "foreign-apply-patch")],
        origin := source },
      { parent := some 2,
        payload := .envMsg [.toolResult (.resolved 2 0) [.text "patch result"] ok],
        origin := source },
      { parent := some 3,
        payload := .assistantMsg [.toolCall { raw := "{\"name\":\"exec_command\"}" }
          (Json.mkObj [("cmd", Json.str "whoami")]) (some "foreign-object-name")],
        origin := source },
      { parent := some 4,
        payload := .envMsg [.toolResult (.resolved 4 0) [.text "object result"] ok],
        origin := source }]
    activeLeaf := some 5 }

private def codexForeignNativeLookingToolsShape (transcript : Transcript) : Bool :=
  transcript.entries.size == 6 &&
  Loom.Ops.callSites transcript == [(0, 0), (2, 0), (4, 0)] &&
  Loom.Ops.resolvedRefs transcript == [(0, 0), (2, 0), (4, 0)] &&
  match transcript.entries[0]?, transcript.entries[2]?, transcript.entries[4]? with
  | some execCall, some patchCall, some objectCall =>
      (match execCall.payload with
       | .assistantMsg [.toolCall name args (some "foreign-exec")] =>
           name.raw == "exec_command" && name.canonical.isNone &&
             ostr args "cmd" == some "pwd"
       | _ => false) &&
      (match patchCall.payload with
       | .assistantMsg [.toolCall name args (some "foreign-apply-patch")] =>
           name.raw == "ApplyPatch" && name.canonical.isNone &&
             (ostr args "patch").any (fun patch => patch.startsWith "*** Begin Patch")
       | _ => false) &&
      (match objectCall.payload with
       | .assistantMsg [.toolCall name args (some "foreign-object-name")] =>
           name.raw == "{\"name\":\"exec_command\"}" && name.canonical.isNone &&
             ostr args "cmd" == some "whoami"
       | _ => false)
  | _, _, _ => false

/-- Foreign native-looking names and object-shaped arguments export as real
Codex lifecycle records, and that is a stable fixed point: hops two and three
are byte-identical to hop one.

The deliberate inverse of its former self, which asserted these stayed inert
forever — the policy that prevented a transcript from ever coming home to Codex
(`LoomOps.Interop`, P1). It keyed on origin format, which is not a safety
property; `disposition` is, and is unchanged. Structural validity alone gates
native emission. -/
def codexForeignNativeLookingToolsExportNativelyTwoHops : Bool :=
  let source := stripCodexEntryOriginMetadata codexForeignNativeLookingToolsFixture
  codexForeignNativeLookingToolsShape source &&
  codexNativeToolCallCount source == 3 &&
  codexNativeToolResultCount source == 3 &&
  codexHistoricalToolCallCount source == 0 &&
  codexHistoricalToolResultCount source == 0 &&
  match exportCodexCliChecked source with
  | .error _ => false
  | .ok first =>
      match parseCodexSession first, importCodexCli first with
      | .ok (_, firstRecords), .ok firstImport =>
          let strippedFirst := stripCodexEntryOriginMetadata firstImport
          codexRecordsContainNativeTools firstRecords &&
          codexForeignNativeLookingToolsShape strippedFirst &&
          strippedFirst.entries.all (fun entry =>
            entry.disposition == EntryDisposition.native) &&
          codexNativeToolCallCount strippedFirst == 3 &&
          codexNativeToolResultCount strippedFirst == 3 &&
          codexHistoricalToolCallCount strippedFirst == 0 &&
          codexHistoricalToolResultCount strippedFirst == 0 &&
          match exportCodexCliChecked strippedFirst with
          | .error _ => false
          | .ok second =>
              match parseCodexSession second, importCodexCli second with
              | .ok (_, secondRecords), .ok secondImport =>
                  let strippedSecond := stripCodexEntryOriginMetadata secondImport
                  second == first && codexRecordsContainNativeTools secondRecords &&
                  codexForeignNativeLookingToolsShape strippedSecond &&
                  codexNativeToolCallCount strippedSecond == 3 &&
                  codexNativeToolResultCount strippedSecond == 3 &&
                  match exportCodexCliChecked strippedSecond with
                  | .ok third => third == second
                  | .error _ => false
              | _, _ => false
      | _, _ => false

example : codexForeignNativeLookingToolsExportNativelyTwoHops = true := by native_decide

private def codexMixedAssistantSelectionFixture : Transcript :=
  let source : Origin := {
    format := .claudeCode, sourceRef := "mixed-assistant-selection" }
  { codexEnvironmentCarrierTwinFixture with
    entries := #[
      { payload := .userMsg [.text "Read README.md."], origin := source },
      { parent := some 0,
        payload := .assistantMsg [
          .text "Reading context.",
          .toolCall { raw := "Read", canonical := some .read }
            (Json.mkObj [("file_path", Json.str "README.md")])
            (some "toolu_read_1")],
        origin := source },
      { parent := some 1,
        payload := .envMsg [
          .toolResult (.resolved 1 1) [.text "fixture contents"] (.native false)],
        origin := source },
      { parent := some 2,
        payload := .assistantMsg [.text "Context restored."], origin := source }]
    activeLeaf := some 3 }

private def codexMixedAssistantSelectionShape (transcript : Transcript) : Bool :=
  transcript.entries.size == 5 &&
  Loom.Ops.callSites transcript == [(2, 0)] &&
  Loom.Ops.resolvedRefs transcript == [(2, 0)] &&
  match transcript.entries[1]?, transcript.entries[2]?,
      transcript.entries[3]?, transcript.entries[4]? with
  | some leadText, some call, some result, some terminal =>
      (match leadText.payload with
       | .assistantMsg [.text "Reading context."] => true
       | _ => false) &&
      -- Native, and `canonical` survives with it. The call used to land here as
      -- an inert carrier for exactly one reason: Codex's `function_call` has no
      -- slot for `ToolName.canonical`, so emitting it natively would have
      -- dropped the source's `.read` interpretation. The reserved envelope
      -- member carries that field alongside the native record now, so the
      -- carrier buys nothing and costs the target's own lifecycle.
      call.disposition == EntryDisposition.native &&
      (match call.payload with
       | .assistantMsg [.toolCall name args (some "toolu_read_1")] =>
           name.raw == "Read" && name.canonical == some .read &&
             ostr args "file_path" == some "README.md"
       | _ => false) &&
      result.disposition == EntryDisposition.native &&
      (match result.payload with
       | .envMsg [.toolResult (.resolved 2 0) [.text "fixture contents"]
           (.inferred false "codexOutputIndicatesError (codexAdapter.ts:75)")] =>
           true
       | _ => false) &&
      (match terminal.payload with
       | .assistantMsg [.text "Context restored."] => true
       | _ => false)
  | _, _, _, _ => false

/-- A mixed assistant entry expands into one record per block. That shifts later
entry indices without changing the selected continuation. Checked export accepts
the rematerialization only when both sides select their own final entry and the
exact terminal payload survives. The call/result fields and their remapped link
remain reversible; after the first materialization, subsequent checked E-I-E
output is byte-stable.

This claude-sourced `Read`/`.read` call used to expand into an inert *carrier*,
and the pin asserted that. It was never a statement about mixed-entry expansion:
it was the visible symptom of Codex refusing native emission for any call
carrying `ToolName.canonical`, because its `function_call` has no slot for that
field. The refusal spent the whole native lifecycle — the thing this adapter
exists to produce — to save one scalar that the reserved `_agent_convert`
envelope member now carries losslessly next to the native record. Both facts
survive, so the pin asserts native counts and checks that `.read` still comes
back (see `codexMixedAssistantSelectionShape`). The subject under test, index
remapping across expansion with a stable selection, is untouched. -/
def codexCheckedSelectionSurvivesReversibleEntryExpansion : Bool :=
  let source := codexMixedAssistantSelectionFixture
  codexTargetActiveLeafValid source &&
  Loom.violations source == [] &&
  match exportCodexCliChecked source with
  | .error _ => false
  | .ok first =>
      match parseCodexSession first, importCodexCli first with
      | .ok (_, firstRecords), .ok restored =>
          codexRecordsContainNativeTools firstRecords &&
          Loom.violations restored == [] &&
          codexTargetActiveLeafValid restored &&
          restored.activeLeaf == some 4 &&
          restored.activeLeaf != source.activeLeaf &&
          codexSelectedTerminalPayload? restored ==
            codexSelectedTerminalPayload? source &&
          codexMixedAssistantSelectionShape restored &&
          codexNativeToolCallCount restored == 1 &&
          codexNativeToolResultCount restored == 1 &&
          codexHistoricalToolCallCount restored == 0 &&
          codexHistoricalToolResultCount restored == 0 &&
          match exportCodexCliChecked restored with
          | .error _ => false
          | .ok second =>
              match parseCodexSession second, importCodexCli second with
              | .ok (_, secondRecords), .ok restoredAgain =>
                  codexRecordsContainNativeTools secondRecords &&
                  Loom.violations restoredAgain == [] &&
                  codexTargetActiveLeafValid restoredAgain &&
                  codexSelectedTerminalPayload? restoredAgain ==
                    codexSelectedTerminalPayload? source &&
                  codexMixedAssistantSelectionShape restoredAgain &&
                  match exportCodexCliChecked restoredAgain with
                  | .ok third => third == second
                  | .error _ => false
              | _, _ => false
      | _, _ => false

example : codexCheckedSelectionSurvivesReversibleEntryExpansion = true := by
  native_decide
private def codexSelectedTerminalBlockExpansionFixture : Transcript :=
  let source : Origin := {
    format := .claudeCode, sourceRef := "selected-terminal-block-expansion" }
  { codexEnvironmentCarrierTwinFixture with
    entries := #[{
      payload := .assistantMsg [
        .text "Visible terminal text.",
        .thinking "Terminal reasoning." (some "opaque-terminal-signature")],
      origin := source }]
    activeLeaf := some 0 }

/-- The selected terminal is one Loom entry but two Codex semantic records.
Checked validation reconstructs both final payload fragments in order.

The fixture is `.claudeCode`-origin, so its thinking signature is FOREIGN and
the target policy omits it from `encrypted_content` (see
`codexThinkingSignaturePolicyPayload`). The visible summary survives; the
signature does not, and this pin asserts exactly that split rather than a
round trip. Its Codex-origin counterpart is
`codexThinkingSignatureRoundTripsNatively`. -/
def codexCheckedTerminalTextThinkingExpansionPasses : Bool :=
  let source := codexSelectedTerminalBlockExpansionFixture
  match exportCodexCliChecked source with
  | .error _ => false
  | .ok exported =>
      match importCodexCli exported with
      | .error _ => false
      | .ok restored =>
          restored.entries.size == 2 && restored.activeLeaf == some 1 &&
          match restored.entries[0]?, restored.entries[1]? with
          | some first, some second =>
              (match first.payload with
               | .assistantMsg [.text "Visible terminal text."] => true
               | _ => false) &&
              (match second.payload with
               | .assistantMsg [.thinking "Terminal reasoning." none] => true
               | _ => false)
          | _, _ => false

example : codexCheckedTerminalTextThinkingExpansionPasses = true := by
  native_decide

private def codexZeroRecordSelectedTerminalFixture : Transcript :=
  let raw := Json.mkObj [("opaque", Json.bool true)]
  let payload := Payload.userMsg [.unmodeled "unsupported-terminal" raw]
  let source : Origin := { format := .pi, sourceRef := "zero-record-terminal" }
  { codexEnvironmentCarrierTwinFixture with
    entries := #[
      { payload := payload, origin := source,
        disposition := .historicalUnverified },
      { parent := some 0, payload := payload, origin := source }]
    activeLeaf := some 1 }

/-- The first equal payload survives through a generic historical carrier, but
the selected native terminal is unrepresentable. Source-loss preflight rejects
it before terminal validation or output rendering can mistake the earlier copy
for the selected continuation. -/
def codexCheckedTerminalWithZeroRecordsIsRejected : Bool :=
  (Loom.Ops.obligations .codexCli
      codexZeroRecordSelectedTerminalFixture).contains .dropUnmodeled &&
  match exportCodexCliChecked codexZeroRecordSelectedTerminalFixture with
  | .error message =>
      hasSub message "destructive export obligations" &&
        hasSub message "dropUnmodeled"
  | .ok _ => false

example : codexCheckedTerminalWithZeroRecordsIsRejected = true := by
  native_decide

private def codexHermesTerminalResultExpansionFixture : Transcript :=
  let source : Origin := {
    format := .hermes, sourceRef := "hermes-terminal-result-expansion" }
  { codexEnvironmentCarrierTwinFixture with
    entries := #[
      { payload := .userMsg [.text "List the files here."], origin := source },
      { parent := some 0
        payload := .assistantMsg [
          .text "Sure, running that now.",
          .toolCall { raw := "terminal", canonical := some .bash }
            (Json.mkObj [("command", Json.str "ls -la")]) (some "call_0")]
        origin := source },
      { parent := some 1
        payload := .envMsg [
          .toolResult (.resolved 1 1)
            [.text "total 0 drwxr-xr-x README.md"] .unrecorded]
        origin := source }]
    activeLeaf := some 2 }

/-- Hermes ends in an unrecorded-error result whose call is block 1 of a mixed
`[text, toolCall]` entry. Codex splits that call to `(2,0)` without changing its
duplicate-safe identity or the selected terminal result.

The terminal is now `.native`, not `.historicalUnverified`. Hermes asserts
`canonical := .bash` on `terminal`, and Codex's `function_call` has no field for
it, so the exporter used to send the whole lifecycle to prose to avoid dropping
that one interpretation — a trade that lost the executable call, the linked
result, and the target's ability to continue the session, to keep a scalar. The
reserved envelope member carries the scalar beside the native record instead, so
`codexToolCallSignatureAt?` (which includes `canonical`) still matches and the
records are real. Codex has no error field at all, so the source's
`.unrecorded` would come back as the `.inferred false` its importer re-derives
from the output text — a value nobody asserted. `codexResultErrorFields` stamps
that one state into the reserved envelope beside the record instead, so the
result is a real `function_call_output` AND still says "the source never
recorded whether this failed". -/
def codexCheckedHermesTerminalResultExpansionPasses : Bool :=
  let source := codexHermesTerminalResultExpansionFixture
  match exportCodexCliChecked source with
  | .error _ => false
  | .ok exported =>
      match importCodexCli exported with
      | .error _ => false
      | .ok restored =>
          restored.entries.size == 4 && restored.activeLeaf == some 3 &&
          Loom.Ops.callSites restored == [(2, 0)] &&
          Loom.Ops.resolvedRefs restored == [(2, 0)] &&
          codexToolCallSignatureAt? source 1 1 ==
            codexToolCallSignatureAt? restored 2 0 &&
          codexNativeToolCallCount restored == 1 &&
          (match restored.entries[2]? with
           | some call =>
               match call.payload with
               | .assistantMsg [.toolCall name _ (some "call_0")] =>
                   name.raw == "terminal" && name.canonical == some .bash
               | _ => false
           | none => false) &&
          match restored.entries[3]? with
          | some terminal =>
              terminal.disposition == EntryDisposition.native &&
              match terminal.payload with
              | .envMsg [.toolResult (.resolved 2 0)
                  [.text "total 0 drwxr-xr-x README.md"] .unrecorded] => true
              | _ => false
          | none => false

example : codexCheckedHermesTerminalResultExpansionPasses = true := by
  native_decide

private def codexCursorIdeTerminalResultExpansionFixture : Transcript :=
  let source : Origin := {
    format := .cursorIde, sourceRef := "cursor-ide-terminal-result-expansion" }
  { codexEnvironmentCarrierTwinFixture with
    entries := #[
      { payload := .userMsg [.text "hi cursor"], origin := source },
      { parent := some 0
        time := .recorded ⟨1720000000000⟩
        payload := .assistantMsg [
          .thinking "let me think" (some "SIG123"),
          .text "on it",
          .toolCall { raw := "search_replace", canonical := some .edit }
            (Json.mkObj [
              ("file_path", Json.str "a.txt"),
              ("old_string", Json.str "x"),
              ("new_string", Json.str "y")]) (some "tc-1")]
        origin := source },
      { parent := some 1
        time := .recorded ⟨1720000000000⟩
        payload := .envMsg [
          .toolResult (.resolved 1 2) [.text "edit applied"] (.native false)]
        origin := source }]
    activeLeaf := some 2 }

/-- Cursor IDE ends in a native-false result whose call is block 2 of a mixed
`[thinking, text, toolCall]` entry. Codex splits that call to `(3,0)` while the
result remains the selected final materialization with exact content and error
VALUE.

Same inversion as the Hermes sibling, and for the same single cause: the
`search_replace`/`.edit` call is now a real `function_call` because the reserved
envelope member can carry `ToolName.canonical` beside it, so nothing is dropped
by emitting natively and the prose carrier is pure loss. The result's error
value stays `false`; its provenance moves `.native → .inferred` because a Codex
`function_call_output` has no error field to hold the distinction. -/
def codexCheckedCursorIdeTerminalResultExpansionPasses : Bool :=
  let source := codexCursorIdeTerminalResultExpansionFixture
  match exportCodexCliChecked source with
  | .error _ => false
  | .ok exported =>
      match importCodexCli exported with
      | .error _ => false
      | .ok restored =>
          restored.entries.size == 5 && restored.activeLeaf == some 4 &&
          Loom.Ops.callSites restored == [(3, 0)] &&
          Loom.Ops.resolvedRefs restored == [(3, 0)] &&
          codexToolCallSignatureAt? source 1 2 ==
            codexToolCallSignatureAt? restored 3 0 &&
          codexNativeToolCallCount restored == 1 &&
          (match restored.entries[3]? with
           | some call =>
               match call.payload with
               | .assistantMsg [.toolCall name _ (some "tc-1")] =>
                   name.raw == "search_replace" && name.canonical == some .edit
               | _ => false
           | none => false) &&
          match restored.entries[4]? with
          | some terminal =>
              terminal.disposition == EntryDisposition.native &&
              terminal.time == Time.recorded ⟨1720000000000⟩ &&
              match terminal.payload with
              | .envMsg [.toolResult (.resolved 3 0)
                  [.text "edit applied"]
                  (.inferred false
                    "codexOutputIndicatesError (codexAdapter.ts:75)")] => true
              | _ => false
          | none => false

example : codexCheckedCursorIdeTerminalResultExpansionPasses = true := by
  native_decide
/-! ### Genuine selected-terminal expansion witnesses -/

/-- Add the same explicit fresh-target launch bundle used by the local checked
export tests without replacing any importer-owned source extras. -/
private def codexGenuineFixtureTargetReady (transcript : Transcript) : Transcript :=
  match codexTargetTestExtras with
  | .obj fields =>
      fields.toList.foldl (fun current (key, value) =>
        codexTargetFixtureExtra current key (some value)) transcript
  | _ => transcript

private def codexCheckedGenuineFixturePair?
    (imported : Except String Transcript) : Option (Transcript × Transcript) := do
  let source ← imported.toOption
  let source := codexGenuineFixtureTargetReady source
  let exported ← (exportCodexCliChecked source).toOption
  let restored ← (importCodexCli exported).toOption
  pure (source, restored)

private def codexMutateEntry
    (transcript : Transcript) (entryIdx : Nat) (mutate : Entry → Entry) : Transcript :=
  { transcript with entries := (transcript.entries.toList.zipIdx.map
      (fun (entry, currentIdx) =>
        if currentIdx == entryIdx then mutate entry else entry)).toArray }

private def codexRelinearizeEntries
    (transcript : Transcript) (entries : List Entry) : Transcript :=
  let linear := entries.zipIdx.map (fun (entry, entryIdx) =>
    { entry with parent := if entryIdx == 0 then none else some (entryIdx - 1) })
  { transcript with
    entries := linear.toArray
    activeLeaf := if linear.isEmpty then none else some (linear.length - 1) }

private def codexCheckedTerminalMutationRejected
    (source mutated : Transcript) (expected : String) : Bool :=
  Loom.violations mutated == [] &&
    codexTargetActiveLeafValid mutated &&
    codexCheckedReimportFailure? source mutated == some expected

private def codexTerminalExpansionChangedError : String :=
  "Codex target re-import changed the selected terminal expansion"

private def codexTerminalExpansionStateChangedError : String :=
  "Codex target re-import changed the selected terminal expansion state"

private def codexUnexpectedMaterializedEntryError : String :=
  "Codex target re-import added an unexpected materialized entry"

private def codexCompleteMaterializedBoundaryChangedError : String :=
  "Codex target re-import changed the complete materialized boundary"

private def codexTerminalExpansionTruncatedError : String :=
  "Codex target re-import truncated the selected terminal expansion"

/-- The actual Pi parity fixture ends in one mixed thinking/text/tool-call
entry. Its three Codex entries retain block order, recorded time, and the
foreign call's inert disposition. -/
def codexCheckedGenuinePiTerminalExpansionPasses : Bool :=
  match codexCheckedGenuineFixturePair? (importPi fix1) with
  | none => false
  | some (source, restored) =>
      source.entries.size == 2 && source.activeLeaf == some 1 &&
      restored.entries.size == 4 && restored.activeLeaf == some 3 &&
      Loom.violations source == [] && Loom.violations restored == [] &&
      match source.entries[1]?, restored.entries[1]?,
          restored.entries[2]?, restored.entries[3]? with
      | some sourceTerminal, some thinking, some text, some call =>
          sourceTerminal.time == Time.recorded ⟨1704067200001⟩ &&
          sourceTerminal.disposition == EntryDisposition.native &&
          (match sourceTerminal.payload with
           | .assistantMsg [
               .thinking "hmm" (some "SIG"),
               .text "yo",
               .toolCall name args (some "tc1")] =>
               name.raw == "Bash" && name.canonical.isNone &&
                 args == Json.mkObj []
           | _ => false) &&
          thinking.time == sourceTerminal.time &&
          thinking.disposition == EntryDisposition.native &&
          -- Pi's "SIG" is a foreign signature: it survives on the SOURCE side
          -- above and is omitted here, because `encrypted_content` holds OpenAI
          -- ciphertext alone. Block order, time, and disposition are unaffected.
          (match thinking.payload with
           | .assistantMsg [.thinking "hmm" none] => true
           | _ => false) &&
          text.time == sourceTerminal.time &&
          text.disposition == EntryDisposition.native &&
          (match text.payload with
           | .assistantMsg [.text "yo"] => true
           | _ => false) &&
          call.time == sourceTerminal.time &&
          call.disposition == EntryDisposition.historicalUnverified &&
          (match call.payload with
           | .assistantMsg [.toolCall name args (some "tc1")] =>
               name.raw == "Bash" && name.canonical.isNone &&
                 args == Json.mkObj []
           | _ => false)
      | _, _, _, _ => false

example : codexCheckedGenuinePiTerminalExpansionPasses = true := by
  native_decide

/-- Content, fragment order, source time, and carrier inertness are independent
checked invariants for Pi's genuine three-way terminal split. Every mutation is
well-formed, so rejection cannot be discharged by the structural preflight. -/
def codexCheckedGenuinePiTerminalMutationsRejected : Bool :=
  match codexCheckedGenuineFixturePair? (importPi fix1) with
  | none => false
  | some (source, restored) =>
      let changedContent := codexMutateEntry restored 2 (fun entry =>
        { entry with payload := .assistantMsg [.text "changed"] })
      let reordered := codexMutateEntry
        (codexMutateEntry restored 1 (fun entry =>
          { entry with payload := .assistantMsg [.text "yo"] }))
        2 (fun entry => { entry with
          payload := .assistantMsg [.thinking "hmm" (some "SIG")] })
      let changedTime := codexMutateEntry restored 2 (fun entry =>
        { entry with time := .absent })
      let activatedCarrier := codexMutateEntry restored 3 (fun entry =>
        { entry with disposition := .native })
      codexCheckedTerminalMutationRejected source changedContent
          codexTerminalExpansionChangedError &&
        codexCheckedTerminalMutationRejected source reordered
          codexTerminalExpansionChangedError &&
        codexCheckedTerminalMutationRejected source changedTime
          codexTerminalExpansionStateChangedError &&
        codexCheckedTerminalMutationRejected source activatedCarrier
          codexTerminalExpansionStateChangedError

example : codexCheckedGenuinePiTerminalMutationsRejected = true := by
  native_decide

/-- The actual Hermes fixture's terminal result remains selected after its
preceding mixed assistant entry splits. Exact result data and duplicate-safe
call identity survive, and the call/result now reach Codex as its own native
lifecycle rather than as inert prose.

"Stay inert" was the old assertion. Its cause was never anything about terminal
selection: the real Hermes fixture's call carries `canonical := .bash`, and
Codex's `function_call` has no slot for that field, so the exporter refused
native emission for the entire lifecycle rather than drop one scalar. That is
the loss this adapter exists to prevent, applied to itself. The reserved
`_agent_convert` envelope member now carries the scalar next to a real record,
so `codexToolCallSignatureAt?` — which compares `canonical` — still matches
across the split while the artifact gained an executable call and result. -/
def codexCheckedGenuineHermesTerminalExpansionPasses : Bool :=
  match codexCheckedGenuineFixturePair? (importHermes hermesFixture) with
  | none => false
  | some (source, restored) =>
      source.entries.size == 3 && source.activeLeaf == some 2 &&
      restored.entries.size == 4 && restored.activeLeaf == some 3 &&
      Loom.violations source == [] && Loom.violations restored == [] &&
      Loom.Ops.callSites restored == [(2, 0)] &&
      Loom.Ops.resolvedRefs restored == [(2, 0)] &&
      codexToolCallSignatureAt? source 1 1 ==
        codexToolCallSignatureAt? restored 2 0 &&
      match source.entries[2]?, restored.entries[2]?, restored.entries[3]? with
      | some sourceTerminal, some call, some terminal =>
          sourceTerminal.time == Time.absent &&
          sourceTerminal.disposition == EntryDisposition.native &&
          (match sourceTerminal.payload with
           | .envMsg [.toolResult (.resolved 1 1)
               [.text "total 0 drwxr-xr-x README.md"] .unrecorded] => true
           | _ => false) &&
          call.time == Time.absent &&
          call.disposition == EntryDisposition.native &&
          (match call.payload with
           | .assistantMsg [.toolCall name _ _] => name.canonical == some .bash
           | _ => false) &&
          terminal.time == sourceTerminal.time &&
          terminal.disposition == EntryDisposition.native &&
          (match terminal.payload with
           | .envMsg [.toolResult (.resolved 2 0)
               [.text "total 0 drwxr-xr-x README.md"] .unrecorded] => true
           | _ => false)
      | _, _, _ => false

example : codexCheckedGenuineHermesTerminalExpansionPasses = true := by
  native_decide
/-- Hermes result content/linkage and the terminal fragment's exact state are
all checked independently of structural validity.

The disposition mutation flips direction: the terminal is `.native` now that its
call reaches Codex natively, so the state change worth rejecting is a
DEACTIVATION to `.historicalUnverified`, not an activation. The property under
test — that checked re-import notices a disposition change on the selected
terminal at all — is unchanged, and it is still the only conjunct that
disposition affects. -/
def codexCheckedGenuineHermesTerminalMutationsRejected : Bool :=
  match codexCheckedGenuineFixturePair? (importHermes hermesFixture) with
  | none => false
  | some (source, restored) =>
      let changedContent := codexMutateEntry restored 3 (fun entry =>
        { entry with payload := .envMsg [
            .toolResult (.resolved 2 0) [.text "changed"] .unrecorded] })
      let changedLink := codexMutateEntry restored 2 (fun entry =>
        { entry with payload := .assistantMsg [
            .toolCall { raw := "different-terminal", canonical := some .bash }
              (Json.mkObj [("command", Json.str "pwd")])
              (some "different-call")] })
      let changedTime := codexMutateEntry restored 3 (fun entry =>
        { entry with time := .sequenced 0 })
      let deactivatedTerminal := codexMutateEntry restored 3 (fun entry =>
        { entry with disposition := .historicalUnverified })
      codexCheckedTerminalMutationRejected source changedContent
          codexTerminalExpansionChangedError &&
        codexCheckedTerminalMutationRejected source changedLink
          codexTerminalExpansionChangedError &&
        codexCheckedTerminalMutationRejected source changedTime
          codexTerminalExpansionStateChangedError &&
        codexCheckedTerminalMutationRejected source deactivatedTerminal
          codexTerminalExpansionStateChangedError

example : codexCheckedGenuineHermesTerminalMutationsRejected = true := by
  native_decide

/-- The actual Cursor IDE fixture preserves the selected result's value, its
exact recorded millisecond, and its link to the call after the preceding
thinking/text/tool-call entry expands from index 1 to indices 1-3.

Same inversion as the Hermes sibling and the same single cause: the fixture's
`search_replace` call asserts `canonical := .edit`, which used to force the
whole lifecycle to prose because Codex's `function_call` cannot hold that field.
It travels in the reserved envelope member now, so the call and result are
native and `.edit` still returns. The error value stays `false` while its
provenance normalizes `.native → .inferred` — a Codex `function_call_output`
carries no error field, so that is the format's limit, reported and not
corrupting. -/
def codexCheckedGenuineCursorIdeTerminalExpansionPasses : Bool :=
  match codexCheckedGenuineFixturePair? (importCursorIde cursorIdeFixture) with
  | none => false
  | some (source, restored) =>
      source.entries.size == 3 && source.activeLeaf == some 2 &&
      restored.entries.size == 5 && restored.activeLeaf == some 4 &&
      Loom.violations source == [] && Loom.violations restored == [] &&
      Loom.Ops.callSites restored == [(3, 0)] &&
      Loom.Ops.resolvedRefs restored == [(3, 0)] &&
      codexToolCallSignatureAt? source 1 2 ==
        codexToolCallSignatureAt? restored 3 0 &&
      match source.entries[2]?, restored.entries[3]?, restored.entries[4]? with
      | some sourceTerminal, some call, some terminal =>
          sourceTerminal.time == Time.recorded ⟨1720000000000⟩ &&
          sourceTerminal.disposition == EntryDisposition.native &&
          (match sourceTerminal.payload with
           | .envMsg [.toolResult (.resolved 1 2)
               [.text "edit applied"] (.native false)] => true
           | _ => false) &&
          call.time == sourceTerminal.time &&
          call.disposition == EntryDisposition.native &&
          (match call.payload with
           | .assistantMsg [.toolCall name _ _] => name.canonical == some .edit
           | _ => false) &&
          terminal.time == sourceTerminal.time &&
          terminal.disposition == EntryDisposition.native &&
          (match terminal.payload with
           | .envMsg [.toolResult (.resolved 3 0)
               [.text "edit applied"]
               (.inferred false
                 "codexOutputIndicatesError (codexAdapter.ts:75)")] => true
           | _ => false)
      | _, _, _ => false

example : codexCheckedGenuineCursorIdeTerminalExpansionPasses = true := by
  native_decide
/-- Cursor result content, error VALUE, linkage, recorded time, and entry
disposition each remain rejection-sensitive after index expansion.

Two adjustments, both downstream of the call now being native. The baseline
error signal is the `.inferred false` Codex re-derives rather than the source's
`.native false`, so the mutations are stated against it — `changedError` still
flips the VALUE, which is the thing that must never pass silently. And the
disposition mutation deactivates a native terminal instead of activating a
carrier, because the terminal is native now; the property, that a disposition
change on the selected terminal is rejected, is the same. -/
def codexCheckedGenuineCursorIdeTerminalMutationsRejected : Bool :=
  match codexCheckedGenuineFixturePair? (importCursorIde cursorIdeFixture) with
  | none => false
  | some (source, restored) =>
      let inferredFalse : ErrorSignal :=
        .inferred false "codexOutputIndicatesError (codexAdapter.ts:75)"
      let changedContent := codexMutateEntry restored 4 (fun entry =>
        { entry with payload := .envMsg [
            .toolResult (.resolved 3 0) [.text "changed"] inferredFalse] })
      let changedError := codexMutateEntry restored 4 (fun entry =>
        { entry with payload := .envMsg [
            .toolResult (.resolved 3 0) [.text "edit applied"]
              (.inferred true
                "codexOutputIndicatesError (codexAdapter.ts:75)")] })
      let changedLink := codexMutateEntry restored 3 (fun entry =>
        { entry with payload := .assistantMsg [
            .toolCall { raw := "different-edit", canonical := some .edit }
              (Json.mkObj [("file_path", Json.str "other.txt")])
              (some "different-call")] })
      let changedTime := codexMutateEntry restored 4 (fun entry =>
        { entry with time := .absent })
      let deactivatedTerminal := codexMutateEntry restored 4 (fun entry =>
        { entry with disposition := .historicalUnverified })
      codexCheckedTerminalMutationRejected source changedContent
          codexTerminalExpansionChangedError &&
        codexCheckedTerminalMutationRejected source changedError
          codexTerminalExpansionChangedError &&
        codexCheckedTerminalMutationRejected source changedLink
          codexTerminalExpansionChangedError &&
        codexCheckedTerminalMutationRejected source changedTime
          codexTerminalExpansionStateChangedError &&
        codexCheckedTerminalMutationRejected source deactivatedTerminal
          codexTerminalExpansionStateChangedError

example : codexCheckedGenuineCursorIdeTerminalMutationsRejected = true := by
  native_decide

private def codexDuplicateTerminalResultExpansionFixture : Transcript :=
  let source : Origin := {
    format := .hermes, sourceRef := "duplicate-terminal-result-expansion" }
  let duplicateCall : AssistantBlock :=
    .toolCall { raw := "terminal", canonical := some .bash }
      (Json.mkObj [("command", Json.str "pwd")]) (some "duplicate-call")
  { codexEnvironmentCarrierTwinFixture with
    entries := #[
      { payload := .assistantMsg [duplicateCall], origin := source },
      { parent := some 0
        payload := .assistantMsg [.text "Again.", duplicateCall]
        origin := source },
      { parent := some 1
        payload := .envMsg [
          .toolResult (.resolved 1 1) [.text "/workspace"] .unrecorded]
        origin := source }]
    activeLeaf := some 2 }

/-- Two calls may have byte-identical names, arguments, and raw ids. The
occurrence ordinal keeps a terminal result linked to the second call after the
mixed assistant entry expands and changes its positional coordinates. -/
def codexCheckedDuplicateTerminalCallIdentityPasses : Bool :=
  let source := codexDuplicateTerminalResultExpansionFixture
  match exportCodexCliChecked source with
  | .error _ => false
  | .ok exported =>
      match importCodexCli exported with
      | .error _ => false
      | .ok restored =>
          restored.entries.size == 4 && restored.activeLeaf == some 3 &&
          Loom.Ops.callSites restored == [(0, 0), (2, 0)] &&
          Loom.Ops.resolvedRefs restored == [(2, 0)] &&
          codexMaterializedCallRefIdentity? source (.resolved 0 0) !=
            codexMaterializedCallRefIdentity? source (.resolved 1 1) &&
          codexToolCallSignatureAt? source 1 1 ==
            codexToolCallSignatureAt? restored 2 0 &&
          match restored.entries[3]? with
          | some terminal =>
              terminal.disposition == EntryDisposition.historicalUnverified &&
              match terminal.payload with
              | .envMsg [.toolResult (.resolved 2 0)
                  [.text "/workspace"] .unrecorded] => true
              | _ => false
          | none => false

example : codexCheckedDuplicateTerminalCallIdentityPasses = true := by
  native_decide

private def codexCanonicalToolCarrierFixture : Transcript :=
  let source : Origin := {
    format := .pi, sourceRef := "canonical-tool-carrier" }
  { codexEnvironmentCarrierTwinFixture with
    entries := #[
      { payload := .assistantMsg [
          .toolCall { raw := "custom-shell", canonical := some .bash }
            (Json.mkObj [("command", Json.str "pwd")])
            (some "canonical-call")],
        origin := source },
      { parent := some 0,
        payload := .envMsg [
          .toolResult (.resolved 0 0) [.text "shell result"] .unrecorded],
        origin := source },
      { parent := some 1,
        payload := .assistantMsg [
          .toolCall { raw := "future-tool", canonical := none }
            (Json.mkObj [("future", Json.bool true)])
            (some "raw-only-call")],
        origin := source },
      { parent := some 2,
        payload := .envMsg [
          .toolResult (.resolved 2 0) [.text "future result"] (.native false)],
        origin := source }]
    activeLeaf := some 3 }

private def codexCanonicalToolCarrierShape (transcript : Transcript) : Bool :=
  transcript.entries.size == 4 &&
  Loom.Ops.callSites transcript == [(0, 0), (2, 0)] &&
  Loom.Ops.resolvedRefs transcript == [(0, 0), (2, 0)] &&
  match transcript.entries[0]?, transcript.entries[1]?,
      transcript.entries[2]?, transcript.entries[3]? with
  | some canonicalCall, some canonicalResult, some rawCall, some rawResult =>
      -- Codex has no wire slot for Loom's canonical identity, so this call used
      -- to keep the prose carrier. It does not any more: the reserved
      -- `_agent_convert` envelope member carries `canonical` beside a real
      -- `function_call`, and this shape is the evidence that BOTH survive —
      -- `.native` disposition together with `name.canonical == some .bash`.
      -- Its `.unrecorded` error state survives too: a `function_call_output`
      -- has no error field, so that one state rides in the reserved envelope
      -- rather than being re-derived as a value the source never asserted.
      canonicalCall.disposition == EntryDisposition.native &&
      (match canonicalCall.payload with
       | .assistantMsg [.toolCall name args (some "canonical-call")] =>
           name.raw == "custom-shell" && name.canonical == some .bash &&
             ostr args "command" == some "pwd"
       | _ => false) &&
      canonicalResult.disposition == EntryDisposition.native &&
      (match canonicalResult.payload with
       | .envMsg [.toolResult (.resolved 0 0) [.text "shell result"]
           .unrecorded] => true
       | _ => false) &&
      -- This one asserts no canonical interpretation, so it emits no envelope
      -- member at all and its bytes are exactly what they were before.
      rawCall.disposition == EntryDisposition.native &&
      (match rawCall.payload with
       | .assistantMsg [.toolCall name args (some "raw-only-call")] =>
           name.raw == "future-tool" && name.canonical.isNone &&
             oobj args "future" == some (Json.bool true)
       | _ => false) &&
      rawResult.disposition == EntryDisposition.native &&
      (match rawResult.payload with
       | .envMsg [.toolResult (.resolved 2 0) [.text "future result"]
           (.inferred false "codexOutputIndicatesError (codexAdapter.ts:75)")] => true
       | _ => false)
  | _, _, _, _ => false

/-- The v2 specialized call carrier round-trips both interpretations of
`ToolName.canonical` and keeps each result linked to the correct inert call.
Singleton call/result entries have stable occurrence addresses, so both checked
E-I-E hops are byte-identical. -/
def codexHistoricalToolNameCanonicalFieldIsExactTwoHops : Bool :=
  let source := codexCanonicalToolCarrierFixture
  match exportCodexCliChecked source with
  | .error _ => false
  | .ok first =>
      match parseCodexSession first, importCodexCli first with
      | .ok (_, firstRecords), .ok firstImport =>
          codexRecordsContainNativeTools firstRecords &&
          codexCanonicalToolCarrierShape firstImport &&
          Loom.violations firstImport == [] &&
          match exportCodexCliChecked firstImport with
          | .error _ => false
          | .ok second =>
              first == second &&
              match parseCodexSession second, importCodexCli second with
              | .ok (_, secondRecords), .ok secondImport =>
                  codexRecordsContainNativeTools secondRecords &&
                  codexCanonicalToolCarrierShape secondImport &&
                  Loom.violations secondImport == [] &&
                  match exportCodexCliChecked secondImport with
                  | .ok third => third == second
                  | .error _ => false
              | _, _ => false
      | _, _ => false

example : codexHistoricalToolNameCanonicalFieldIsExactTwoHops = true := by
  native_decide
private def codexCanonicalCarrierValidationText
    (carrier : String) (canonical : Option Json) : String :=
  let fields := [
    ("carrier", Json.str carrier),
    ("occurrence", Json.str "0:0"),
    ("id", Json.null),
    ("name", Json.str "custom-shell")] ++
    canonical.toList.map ("canonical", ·) ++ [
    ("arguments", Json.mkObj []),
    ("reason", Json.str codexHistoricalToolCallReason)]
  codexHistoricalToolCallCarrierHeader ++ "\n" ++ (Json.mkObj fields).compress

private def codexCanonicalCarrierShapeMismatchFixtures : List String := [
  codexCarrierValidationFixture "tool_call"
    (codexCanonicalCarrierValidationText codexHistoricalToolCallCarrierV2 none),
  codexCarrierValidationFixture "tool_call"
    (codexCanonicalCarrierValidationText codexHistoricalToolCallCarrierV2
      (some (Json.str "not-canonical"))),
  codexCarrierValidationFixture "tool_call"
    (codexCanonicalCarrierValidationText codexHistoricalToolCallCarrierV1
      (some Json.null))]

/-- Version/shape mismatches never partially decode: v2 requires one valid
nullable canonical field, while legacy v1 rejects an injected field. -/
def codexHistoricalToolNameCarrierShapeIsCollisionResistant : Bool :=
  codexCanonicalCarrierShapeMismatchFixtures.all codexRejectedCarrierStaysUnmodeled

example : codexHistoricalToolNameCarrierShapeIsCollisionResistant = true := by
  native_decide

private def codexDuplicateCanonicalCarrierText
    (first second : String) : String :=
  codexHistoricalToolCallCarrierHeader ++ "\n" ++
    "{\"carrier\":\"agent-convert.codex-tool-call.v2\"," ++
    "\"occurrence\":\"0:0\",\"id\":null,\"name\":\"custom-shell\"," ++
    "\"canonical\":" ++ first ++ ",\"canonical\":" ++ second ++ "," ++
    "\"arguments\":{},\"reason\":" ++
    (Json.str codexHistoricalToolCallReason).compress ++ "}"

private def codexDuplicateCanonicalCarrierFixtures : List String := [
  codexCarrierValidationFixture "tool_call"
    (codexDuplicateCanonicalCarrierText "null" "\"bash\""),
  codexCarrierValidationFixture "tool_call"
    (codexDuplicateCanonicalCarrierText "\"bash\"" "null")]

/-- These fixtures contain real duplicate lexical keys, not `Json.mkObj` values.
Either parser-collapse order produces a semantically valid canonical field, but
the noncanonical source bytes must still keep the carrier inert. -/
def codexHistoricalToolNameCarrierRejectsDuplicateLexicalKeys : Bool :=
  codexDuplicateCanonicalCarrierFixtures.all codexRejectedCarrierStaysUnmodeled

example : codexHistoricalToolNameCarrierRejectsDuplicateLexicalKeys = true := by
  native_decide

private def codexDuplicateLegacyCallText (first second : String) : String :=
  codexHistoricalToolCallCarrierHeader ++ "\n" ++
    "{\"carrier\":\"agent-convert.codex-tool-call.v1\"," ++
    "\"occurrence\":\"0:0\",\"id\":null,\"name\":" ++
    (Json.str first).compress ++ ",\"name\":" ++ (Json.str second).compress ++
    ",\"arguments\":{},\"reason\":" ++
    (Json.str codexHistoricalToolCallReason).compress ++ "}"

/-- The duplicate lives in the nested call-link object. Both collapsed notes
are otherwise valid unresolved-link semantics. -/
private def codexDuplicateResultCallText (first second : String) : String :=
  codexHistoricalToolResultCarrierHeader ++ "\n" ++
    "{\"carrier\":\"agent-convert.codex-tool-result.v1\"," ++
    "\"occurrence\":\"1:0\",\"id\":null,\"call\":{" ++
    "\"kind\":\"unresolved\",\"rawId\":null,\"note\":" ++
    (Json.str first).compress ++ ",\"note\":" ++ (Json.str second).compress ++
    "},\"output\":\"exact output\",\"content\":[{" ++
    "\"kind\":\"text\",\"text\":\"exact output\"}],\"isError\":null," ++
    "\"error\":{\"kind\":\"unrecorded\"}," ++
    "\"errorProvenance\":\"unrecorded\"}"

private def codexDuplicateUnmodeledText
    (environment : Bool) (first second : String) : String :=
  let header := if environment then codexHistoricalEnvUnmodeledCarrierHeader
    else codexHistoricalUnmodeledCarrierHeader
  let carrier := if environment then "agent-convert.codex-env-unmodeled.v1"
    else "agent-convert.codex-unmodeled.v1"
  let reason := if environment then codexHistoricalEnvUnmodeledReason
    else codexHistoricalUnmodeledReason
  header ++ "\n{\"carrier\":" ++ (Json.str carrier).compress ++
    ",\"occurrence\":\"0:0\",\"label\":" ++ (Json.str first).compress ++
    ",\"label\":" ++ (Json.str second).compress ++
    ",\"raw\":{\"future\":true},\"reason\":" ++
    (Json.str reason).compress ++ "}"

private def codexDuplicateEntryText (first second : String) : String :=
  codexHistoricalEntryCarrierHeader ++ "\n" ++
    "{\"carrier\":\"agent-convert.codex-entry.v1\",\"payload\":{" ++
    "\"kind\":" ++ (Json.str first).compress ++ ",\"kind\":" ++
    (Json.str second).compress ++ ",\"blocks\":[]},\"reason\":" ++
    (Json.str codexHistoricalEntryReason).compress ++ "}"

private def codexDuplicateBoundaryText (first second : String) : String :=
  codexHistoricalSessionBoundaryCarrierHeader ++ "\n" ++
    "{\"carrier\":\"agent-convert.codex-session-boundary.v1\"," ++
    "\"record\":{\"type\":\"session_meta\",\"payload\":{\"id\":" ++
    (Json.str first).compress ++ ",\"id\":" ++ (Json.str second).compress ++
    "}},\"reason\":" ++ (Json.str codexHistoricalSessionBoundaryReason).compress ++ "}"

private def codexAmbiguousLegacyCarrierFixtures : List String := [
  codexCarrierValidationFixture "tool_call"
    (codexDuplicateLegacyCallText "first" "second"),
  codexCarrierValidationFixture "tool_call"
    (codexDuplicateLegacyCallText "second" "first"),
  codexCarrierValidationFixture "tool_result"
    (codexDuplicateResultCallText "first" "second"),
  codexCarrierValidationFixture "tool_result"
    (codexDuplicateResultCallText "second" "first"),
  codexCarrierValidationFixture "unmodeled"
    (codexDuplicateUnmodeledText false "first" "second"),
  codexCarrierValidationFixture "unmodeled"
    (codexDuplicateUnmodeledText false "second" "first"),
  codexCarrierValidationFixture "environment_unmodeled"
    (codexDuplicateUnmodeledText true "first" "second"),
  codexCarrierValidationFixture "environment_unmodeled"
    (codexDuplicateUnmodeledText true "second" "first"),
  codexCarrierValidationFixture "entry"
    (codexDuplicateEntryText "userMsg" "assistantMsg"),
  codexCarrierValidationFixture "entry"
    (codexDuplicateEntryText "assistantMsg" "userMsg"),
  codexCarrierValidationFixture "session_boundary"
    (codexDuplicateBoundaryText "first" "second"),
  codexCarrierValidationFixture "session_boundary"
    (codexDuplicateBoundaryText "second" "first")]

/-- Every exporter-owned legacy carrier requires its exact compact source
bytes. Duplicate semantic keys stay inert in both lexical orders, including a
nested result-call object whose collapsed forms would each otherwise decode. -/
def codexLegacyCarriersRejectDuplicateLexicalKeys : Bool :=
  codexAmbiguousLegacyCarrierFixtures.all codexRejectedCarrierStaysUnmodeled

example : codexLegacyCarriersRejectDuplicateLexicalKeys = true := by
  native_decide

private def codexOuterCarrierDuplicateSource : Transcript :=
  let source : Origin := {
    format := .pi, sourceRef := "outer-carrier-duplicate" }
  { codexEnvironmentCarrierTwinFixture with
    entries := #[{
      time := .recorded ⟨1700000000000⟩
      payload := .assistantMsg [.toolCall {
        raw := "Bash", canonical := some .bash }
        (Json.mkObj [("command", Json.str "pwd")])
        (some "outer-duplicate-call")]
      origin := source }]
    activeLeaf := some 0 }

private def codexOuterCarrierDuplicateVariants (exported : String) : List String := [
  exported.replace "\"role\":\"assistant\""
    "\"role\":\"user\",\"role\":\"assistant\"",
  exported.replace "\"role\":\"assistant\""
    "\"role\":\"assistant\",\"role\":\"user\"",
  exported.replace "\"type\":\"output_text\""
    "\"type\":\"input_text\",\"type\":\"output_text\"",
  exported.replace "\"type\":\"output_text\""
    "\"type\":\"output_text\",\"type\":\"input_text\"",
  exported.replace "\"kind\":\"tool_call\""
    "\"kind\":\"future_kind\",\"kind\":\"tool_call\"",
  exported.replace "\"kind\":\"tool_call\""
    "\"kind\":\"tool_call\",\"kind\":\"future_kind\""
  ]

private def codexOuterCarrierAmbiguityRejected (input : String) : Bool :=
  match importCodexCli input with
  | .error message =>
      message == "exporter-owned Codex carrier envelope requires canonical JSONL bytes"
  | .ok _ => false

private def codexUnstampedOuterDuplicateVariants : List String := [
  codexUnstampedMarkedCarrierFixture.replace "\"role\":\"assistant\""
    "\"role\":\"user\",\"role\":\"assistant\"",
  codexUnstampedMarkedCarrierFixture.replace "\"role\":\"assistant\""
    "\"role\":\"assistant\",\"role\":\"user\""
  ]

/-- Whole-record canonicality is checked before carrier decoding, even when a
record has no time-provenance extension. Duplicate role, nested content type,
and nested marker kind fields reject identically in both lexical orders.
Without the exact session stamp, the same reserved-looking text stays inert
and does not trigger exporter-owned validation. -/
def codexOuterCarrierEnvelopeRejectsDuplicateMembers : Bool :=
  match exportCodexCliChecked codexOuterCarrierDuplicateSource with
  | .error _ => false
  | .ok exported =>
      match parseCodexSession exported with
      | .error _ => false
      | .ok (_, records) =>
          let carrierRecords := records.filter (fun record =>
            codexOuterCarrierProtocolClaimed record)
          carrierRecords.length == 1 &&
          carrierRecords.all (fun record =>
            (oobj record codexTimeProvenanceKey).isNone) &&
          (codexOuterCarrierDuplicateVariants exported).all
            codexOuterCarrierAmbiguityRejected &&
          codexUnstampedOuterDuplicateVariants.all (fun input =>
            match importCodexCli input with
            | .ok transcript => Loom.Ops.callSites transcript == []
            | .error _ => false)

example : codexOuterCarrierEnvelopeRejectsDuplicateMembers = true := by
  native_decide

private def codexTimeValidationPayload : Json := Json.mkObj [
  ("type", Json.str "message"), ("role", Json.str "assistant"),
  ("content", Json.arr #[Json.mkObj [
    ("type", Json.str "output_text"), ("text", Json.str "time validation")]])]

private def codexTimeValidationFixture (rawTime : String) : String :=
  codexStampedCarrierHeader ++ "\n" ++
    "{\"timestamp\":\"2026-07-20T00:00:01.000Z\",\"type\":\"response_item\"," ++
    "\"payload\":" ++ codexTimeValidationPayload.compress ++ "," ++
    (Json.str codexTimeProvenanceKey).compress ++ ":" ++ rawTime ++ "}"

private def codexValidAbsentTimeFixture : String :=
  let provenance := (codexTimeProvenanceJson? .absent none).getD Json.null
  let record := Json.mkObj [
    ("timestamp", Json.str "2026-07-20T00:00:01.000Z"),
    ("type", Json.str "response_item"),
    ("payload", codexTimeValidationPayload),
    (codexTimeProvenanceKey, provenance)]
  codexStampedCarrierHeader ++ "\n" ++ codexCanonicalJsonLine record

private def codexMalformedReservedTimeFixtures : List String :=
  let protocol := (Json.str codexCarrierProtocol).compress
  let kind := (Json.str codexEntryTimeProvenanceKind).compress
  [
    codexTimeValidationFixture "\"not-an-object\"",
    codexTimeValidationFixture
      ("{\"protocol\":7,\"kind\":" ++ kind ++ ",\"state\":\"absent\"}"),
    codexTimeValidationFixture
      ("{\"protocol\":" ++ protocol ++ ",\"kind\":" ++ kind ++ "}"),
    codexTimeValidationFixture
      ("{\"protocol\":" ++ protocol ++ ",\"kind\":" ++ kind ++
        ",\"state\":\"absent\",\"extra\":true}"),
    codexTimeValidationFixture
      ("{\"protocol\":\"wrong.protocol\",\"kind\":" ++ kind ++
        ",\"state\":\"absent\"}"),
    codexTimeValidationFixture
      ("{\"protocol\":" ++ protocol ++
        ",\"kind\":\"wrong_kind\",\"state\":\"absent\"}"),
    codexTimeValidationFixture
      ("{\"protocol\":" ++ protocol ++ ",\"kind\":" ++ kind ++
        ",\"state\":\"absent\",\"source_timestamp\":\"first\"," ++
        "\"source_timestamp\":\"second\"}"),
    codexTimeValidationFixture
      ("{\"protocol\":" ++ protocol ++ ",\"kind\":" ++ kind ++
        ",\"state\":\"absent\",\"source_timestamp\":\"second\"," ++
        "\"source_timestamp\":\"first\"}")
  ]

private def codexReservedTimeFixtureRejected (input : String) : Bool :=
  match importCodexCli input with
  | .error message => hasSub message codexTimeProvenanceKey
  | .ok _ => false

/-- A valid reserved value restores non-recorded time. Wrong outer/field types,
missing or extra fields, protocol/kind drift, and duplicate semantic keys in
both orders fail closed instead of falling back to the visible timestamp. -/
def codexReservedTimePresenceRequiresExactDecoding : Bool :=
  (match importCodexCli codexValidAbsentTimeFixture with
   | .ok transcript =>
       transcript.entries[0]?.map (fun entry => entry.time) == some Time.absent
   | .error _ => false) &&
  codexMalformedReservedTimeFixtures.all codexReservedTimeFixtureRejected

example : codexReservedTimePresenceRequiresExactDecoding = true := by
  native_decide

private def codexUnownedTimeCollisionFixture (rawTime : Option String) : String :=
  let timeField := match rawTime with
    | some raw => ",\"_agent_convert_time\":" ++ raw
    | none => ""
  String.intercalate "\n" [
    "{\"type\":\"session_meta\",\"payload\":{\"id\":\"collision\"}}",
    "{\"timestamp\":\"2026-07-20T00:00:01.000Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\",\"name\":\"exec_command\",\"call_id\":\"collision-call\",\"arguments\":\"{\\\"cmd\\\":\\\"pwd\\\"}\"}" ++
      timeField ++ "}",
    "{\"timestamp\":\"2026-07-20T00:00:02.000Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"collision-call\",\"output\":\"/tmp\"}}"
  ]

private def codexUnownedAbsentTimeObject : String :=
  "{\"protocol\":\"agent-convert.codex-carriers.v1\"," ++
    "\"kind\":\"entry_time_provenance\",\"state\":\"absent\"}"

private def codexUnownedWrongTimeObject : String :=
  "{\"protocol\":\"agent-convert.codex-carriers.v1\"," ++
    "\"kind\":\"wrong-kind\",\"state\":\"absent\"}"

private def codexUnownedTimeCollisionRejectedFixed (rawTime : String) : Bool :=
  let input := codexUnownedTimeCollisionFixture (some rawTime)
  match importCodexCli input, importCodexCli input with
  | .error first, .error second =>
      first == second &&
        first == "reserved _agent_convert_time requires an exact exporter-owned session stamp"
  | _, _ => false

private def codexRecordedToolTimesExact (transcript : Transcript) : Bool :=
    transcript.entries.size == 2 &&
    transcript.entries[0]?.map (fun entry => entry.time) ==
      some (Time.recorded ⟨1784505601000⟩) &&
    transcript.entries[1]?.map (fun entry => entry.time) ==
      some (Time.recorded ⟨1784505602000⟩) &&
    Loom.Ops.callSites transcript == [(0, 0)] &&
    Loom.Ops.resolvedRefs transcript == [(0, 0)]

/-- The exact three-line collision witness and wrong-type/shape variants fail
on their first unstamped appearance with a stable diagnostic. A normal
unstamped native call/result lifecycle remains accepted, keeps both recorded
times, and reaches a byte-stable same-format export fixed point. -/
def codexUnownedReservedTimeNeverBecomesTrusted : Bool :=
  [codexUnownedAbsentTimeObject, "\"absent\"",
    codexUnownedWrongTimeObject].all codexUnownedTimeCollisionRejectedFixed &&
  let ordinary := codexUnownedTimeCollisionFixture none
  match importCodexCli ordinary with
  | .error _ => false
  | .ok firstImport =>
      let firstExport := exportCodexCli firstImport
      codexRecordedToolTimesExact firstImport &&
      match parseCodexSession firstExport, importCodexCli firstExport with
      | .ok (header, _), .ok secondImport =>
          !codexCarrierSessionSelfIdentified header &&
          codexRecordedToolTimesExact secondImport &&
          exportCodexCli secondImport == firstExport
      | _, _ => false

example : codexUnownedReservedTimeNeverBecomesTrusted = true := by
  native_decide

private def codexMixedTimeTargetFixture : Transcript :=
  let recordedWithStaleExtra : Origin := {
    format := .pi, sourceRef := "mixed-recorded",
    extras := some (Json.mkObj [
      ("ts", Json.str "2040-01-01T00:00:00.000Z")]) }
  let interpolatedSource : Origin := {
    format := .pi, sourceRef := "mixed-interpolated",
    extras := some (Json.mkObj [
      ("ts", Json.str "2001-01-01T00:00:00.000Z")]) }
  let sequencedSource : Origin := {
    format := .pi, sourceRef := "mixed-sequenced",
    extras := some (Json.mkObj [
      ("ts", Json.str "1999-12-31T23:59:59.999Z")]) }
  let absentSource : Origin := {
    format := .pi, sourceRef := "mixed-absent",
    extras := some (Json.mkObj [("ts", Json.str "not-a-source-time")]) }
  let toolSource : Origin := { format := .pi, sourceRef := "mixed-tool" }
  { codexEnvironmentCarrierTwinFixture with
    entries := #[
      { time := .recorded ⟨1700000000000⟩,
        payload := .userMsg [.text "recorded millisecond"],
        origin := recordedWithStaleExtra },
      { parent := some 0,
        time := .interpolated ⟨1700000000500⟩ "adversarial endpoints",
        payload := .assistantMsg [.text "interpolated source"],
        origin := interpolatedSource },
      { parent := some 1,
        time := .recorded ⟨1700000000002⟩,
        payload := .assistantMsg [.toolCall { raw := "exec_command" }
          (Json.mkObj [("cmd", Json.str "pwd")]) (some "mixed-time-call")],
        origin := toolSource },
      { parent := some 2,
        time := .recorded ⟨1700000000003⟩,
        payload := .envMsg [.toolResult (.resolved 2 0) [.text "done"]
          (.inferred false "codexOutputIndicatesError (codexAdapter.ts:75)")],
        origin := toolSource },
      { parent := some 3,
        time := .sequenced 41,
        payload := .assistantMsg [.text "sequenced source"],
        origin := sequencedSource },
      { parent := some 4,
        time := .absent,
        payload := .userMsg [.text "absent source"],
        origin := absentSource }]
    activeLeaf := some 5 }

private def codexEntryOriginTimestamp? (transcript : Transcript)
    (entryIdx : Nat) : Option String :=
  transcript.entries[entryIdx]?.bind (fun entry =>
    entry.origin.extras.bind (fun extras => ostr extras "ts"))

/-- Fresh-target timestamps are selected entry by entry, not stamped as a
session-wide rewrite. Recorded milliseconds win even over adversarial raw
extras; generated display twins and native tool records inherit that exact
clock. Non-recorded entries use the launch time while their source `Time` state
and raw timestamp provenance survive E-I-E. -/
def codexMixedTargetTimesAreEntryScopedAndStable : Bool :=
  match exportCodexCliChecked codexMixedTimeTargetFixture with
  | .error _ => false
  | .ok exported =>
      match parseCodexSession exported, importCodexCli exported with
      | .ok (header, records), .ok restored =>
          ostr header "timestamp" == some codexTargetTestTimestamp &&
          -- Two records shorter than the carrier era: a native function_call /
          -- function_call_output pair replaces the carrier `message` plus its
          -- display twin, and native records carry no twin. Per-entry time
          -- scoping is unchanged, which is what this pin exists to protect.
          records.map (fun record => ostr record "timestamp") == [
            some codexTargetTestTimestamp,
            some "2023-11-14T22:13:20.000Z",
            some "2023-11-14T22:13:20.000Z",
            some codexTargetTestTimestamp,
            some codexTargetTestTimestamp,
            some "2023-11-14T22:13:20.002Z",
            some "2023-11-14T22:13:20.003Z",
            some codexTargetTestTimestamp,
            some codexTargetTestTimestamp,
            some codexTargetTestTimestamp,
            some codexTargetTestTimestamp] &&
          records.countP (fun record =>
            (oobj record codexTimeProvenanceKey).isSome) == 6 &&
          restored.entries.toList.map (fun entry => entry.time) == [
            Time.recorded ⟨1700000000000⟩,
            Time.interpolated ⟨1700000000500⟩ "adversarial endpoints",
            Time.recorded ⟨1700000000002⟩,
            Time.recorded ⟨1700000000003⟩,
            Time.sequenced 41,
            Time.absent] &&
          codexEntryOriginTimestamp? restored 1 ==
            some "2001-01-01T00:00:00.000Z" &&
          codexEntryOriginTimestamp? restored 4 ==
            some "1999-12-31T23:59:59.999Z" &&
          codexEntryOriginTimestamp? restored 5 == some "not-a-source-time" &&
          match exportCodexCliChecked restored with
          | .ok reexported => reexported == exported
          | .error _ => false
      | _, _ => false

example : codexMixedTargetTimesAreEntryScopedAndStable = true := by native_decide

private def codexExactMillisecondTargetFixture : Transcript :=
  let source : Origin := {
    format := .pi, sourceRef := "exact-millisecond",
    extras := some (Json.mkObj [
      ("ts", Json.str codexTargetTestTimestamp)]) }
  { codexEnvironmentCarrierTwinFixture with
    entries := #[{
      time := .recorded ⟨1700000000001⟩,
      payload := .userMsg [.text "one exact millisecond"],
      origin := source }]
    activeLeaf := some 0 }

/-- The nonzero millisecond survives both semantic and display channels, then
survives import and byte-identical re-export. This specifically catches a
fallback to the target launch timestamp or whole-second truncation. -/
def codexExactRecordedMillisecondEIE : Bool :=
  match exportCodexCliChecked codexExactMillisecondTargetFixture with
  | .error _ => false
  | .ok exported =>
      match parseCodexSession exported, importCodexCli exported with
      | .ok (_, [context, semantic, display]), .ok restored =>
          ostr context "timestamp" == some codexTargetTestTimestamp &&
          ostr semantic "timestamp" == some "2023-11-14T22:13:20.001Z" &&
          ostr display "timestamp" == some "2023-11-14T22:13:20.001Z" &&
          restored.entries[0]?.map (fun entry => entry.time) ==
            some (Time.recorded ⟨1700000000001⟩) &&
          match exportCodexCliChecked restored with
          | .ok reexported => reexported == exported
          | .error _ => false
      | _, _ => false

example : codexExactRecordedMillisecondEIE = true := by native_decide

/-! ### Native Codex 0.144.1 compaction export pins -/

private def codexStrictCompactionTimestamp : String :=
  "2023-11-14T22:13:20.123Z"

private def codexStrictCompactionSummary : String :=
  "exact checkpoint summary"

private def codexStrictCompactionMetadata : Json :=
  Json.mkObj [("turn_id", Json.str "019b1f75-4c2a-7b11-8ea2-000000000010")]

private def codexStrictCompactionPayload : Json :=
  Json.mkObj [
    ("message", Json.str codexStrictCompactionSummary),
    ("replacement_history", Json.arr #[
      Json.mkObj [
        ("type", Json.str "message"), ("role", Json.str "user"),
        ("content", Json.arr #[Json.mkObj [
          ("type", Json.str "input_text"),
          ("text", Json.str "retained checkpoint input")]]),
        ("internal_chat_message_metadata_passthrough",
          codexStrictCompactionMetadata)],
      Json.mkObj [
        ("type", Json.str "compaction"),
        ("id", Json.str
          "cmp_019b1f754c2a7b118ea21234567890abcdef1234567890abcd"),
        ("encrypted_content", Json.str "gAAAAA-exact-compaction-signature"),
        ("internal_chat_message_metadata_passthrough",
          codexStrictCompactionMetadata)]]),
    ("window_number", Json.num 2),
    ("first_window_id", Json.str "019b1f75-4c2a-7b11-8ea2-000000000001"),
    ("previous_window_id", Json.str "019b1f75-4c2a-7b11-8ea2-000000000002"),
    ("window_id", Json.str "019b1f75-4c2a-7b11-8ea2-000000000003")]

private def codexStrictCompactionRecord : Json :=
  Json.mkObj [
    ("timestamp", Json.str codexStrictCompactionTimestamp),
    ("type", Json.str "compacted"),
    ("payload", codexStrictCompactionPayload)]

private def codexMalformedCompactionPayload : Json :=
  Json.mkObj [
    ("message", Json.str codexStrictCompactionSummary),
    ("replacement_history", Json.arr #[Json.mkObj [
      ("type", Json.str "compaction"),
      ("id", Json.str
        "cmp_019b1f754c2a7b118ea21234567890abcdef1234567890abcd"),
      ("internal_chat_message_metadata_passthrough",
        codexStrictCompactionMetadata)]]),
    ("window_number", Json.num 2),
    ("first_window_id", Json.str "019b1f75-4c2a-7b11-8ea2-000000000001"),
    ("previous_window_id", Json.str "019b1f75-4c2a-7b11-8ea2-000000000002"),
    ("window_id", Json.str "019b1f75-4c2a-7b11-8ea2-000000000003")]

private def codexMalformedCompactionRecord : Json :=
  Json.mkObj [
    ("timestamp", Json.str codexStrictCompactionTimestamp),
    ("type", Json.str "compacted"),
    ("payload", codexMalformedCompactionPayload)]

private def codexStrictCompactionOrigin : Origin := {
  format := .codexCli
  sourceRef := "entry1"
  extras := some (Json.mkObj [
    ("ts", Json.str codexStrictCompactionTimestamp),
    (codexCompactionRawRecordKey, codexStrictCompactionRecord)]) }

private def codexStrictCompactionEntry : Entry := {
  time := .recorded ⟨1700000000123⟩
  payload := .compaction codexStrictCompactionSummary .unknownPrefix none
  origin := codexStrictCompactionOrigin }

private def codexMixedCompactionTargetFixture : Transcript :=
  let source : Origin := { format := .pi, sourceRef := "mixed-compaction" }
  { codexEnvironmentCarrierTwinFixture with
    entries := #[
      { time := .recorded ⟨1700000000122⟩,
        payload := .userMsg [.text "before checkpoint"], origin := source },
      { codexStrictCompactionEntry with parent := some 0 },
      { parent := some 1, time := .recorded ⟨1700000000124⟩,
        payload := .assistantMsg [.text "after checkpoint"], origin := source }]
    activeLeaf := some 2 }

private def codexStrictCompactionEntryShape
    (transcript : Transcript) (entryIdx : Nat) : Bool :=
  match transcript.entries[entryIdx]? with
  | some entry =>
      entry.disposition == EntryDisposition.native &&
      entry.time == Time.recorded ⟨1700000000123⟩ &&
      (match entry.payload with
       | .compaction summary .unknownPrefix none =>
           summary == codexStrictCompactionSummary
       | _ => false) &&
      entry.origin.extras.bind (fun extras =>
        oobj extras codexCompactionRawRecordKey) == some codexStrictCompactionRecord
  | none => false

private def codexStrictCompactionRecordShape (record : Json) : Bool :=
  ostr record "type" == some "compacted" &&
    ostr record "timestamp" == some codexStrictCompactionTimestamp &&
    oobj record "payload" == some codexStrictCompactionPayload &&
    (oobj record "payload").any (fun payload =>
      ostr payload "message" == some codexStrictCompactionSummary &&
      ostr payload "window_id" ==
        some "019b1f75-4c2a-7b11-8ea2-000000000003" &&
      (oarr payload "replacement_history").any (fun history =>
        history.toList.getLast?.any (fun signature =>
          ostr signature "encrypted_content" ==
            some "gAAAAA-exact-compaction-signature" &&
          oobj signature "internal_chat_message_metadata_passthrough" ==
            some codexStrictCompactionMetadata)))

/-- A mixed target stream emits one native checkpoint in place. Its complete
replacement history, opaque signature, summary, window provenance, and exact
recorded millisecond survive two E-I-E hops byte-for-byte; framing remains
append-safe after the final ordinary display record. -/
def codexNativeCompactionDirectEIEAndTwoHop : Bool :=
  let source := codexMixedCompactionTargetFixture
  let direct := exportCodexCli source
  codexTargetCompactionsValid source &&
  codexStrictCompactionEntryShape source 1 &&
  match exportCodexCliChecked source with
  | .error _ => false
  | .ok firstExport =>
      direct == firstExport && firstExport.endsWith "\n" &&
      !firstExport.endsWith "\n\n" &&
      match parseCodexSession firstExport, importCodexCli firstExport with
      | .ok (_, firstRecords), .ok firstImport =>
          firstRecords.map (fun record => ostr record "type") == [
            some "turn_context", some "response_item", some "event_msg",
            some "compacted", some "response_item", some "event_msg"] &&
          (firstRecords.find? (fun record =>
            ostr record "type" == some "compacted")).any
              codexStrictCompactionRecordShape &&
          firstImport.entries.size == 3 &&
          codexStrictCompactionEntryShape firstImport 1 &&
          codexTargetCompactionsValid firstImport &&
          match exportCodexCliChecked firstImport with
          | .error _ => false
          | .ok secondExport =>
              secondExport == firstExport &&
              match importCodexCli secondExport with
              | .error _ => false
              | .ok secondImport =>
                  codexStrictCompactionEntryShape secondImport 1 &&
                  match exportCodexCliChecked secondImport with
                  | .ok thirdExport => thirdExport == secondExport
                  | .error _ => false
      | _, _ => false

example : codexNativeCompactionDirectEIEAndTwoHop = true := by native_decide

private def codexCompactionTargetWithEntry (entry : Entry) : Transcript :=
  { codexEnvironmentCarrierTwinFixture with
    entries := #[{ entry with parent := none }]
    activeLeaf := some 0 }

private def codexMalformedCompactionImportFixture : String :=
  String.intercalate "\n" ([
    Json.mkObj [
      ("timestamp", Json.str "2023-11-14T22:13:20.000Z"),
      ("type", Json.str "session_meta"),
      ("payload", Json.mkObj [
        ("id", Json.str codexTargetTestId),
        ("cli_version", Json.str codexCliTargetVersion)])],
    codexMalformedCompactionRecord,
    Json.mkObj [
      ("timestamp", Json.str "2023-11-14T22:13:20.124Z"),
      ("type", Json.str "response_item"),
      ("payload", Json.mkObj [
        ("type", Json.str "message"), ("role", Json.str "user"),
        ("content", Json.arr #[Json.mkObj [
          ("type", Json.str "input_text"),
          ("text", Json.str "normal record survives")]])])]
    ].map Json.compress) ++ "\n"

private def codexMalformedCompactionArchived (transcript : Transcript) : Bool :=
  transcript.entries.size == 1 &&
    (match transcript.entries[0]?.map (·.payload) with
     | some (Payload.userMsg [UserBlock.text "normal record survives"]) => true
     | _ => false) &&
    transcript.importNotes.any (fun note =>
      match note.kind with
      | .other "codex-malformed-compaction-record" => true
      | _ => false) &&
    transcript.origin.extras.any (fun extras =>
      oarr extras "raw_compaction_records" == some #[codexMalformedCompactionRecord] &&
      (oarr extras "raw_non_dialogue_records").any (fun records =>
        records.contains codexMalformedCompactionRecord))

/-- Malformed/native-unproven checkpoints are never activated or silently
dropped by checked export. Summary drift and Loom-only extent/token facts refuse
too. The same typed payload remains exportable when its disposition is
historical-unverified, in which case it stays an inert entry carrier. -/
def codexCompactionMalformedAndPreflightPinned : Bool :=
  let noProvenance := codexCompactionTargetWithEntry {
    codexStrictCompactionEntry with
      origin := {
        format := .codexCli
        sourceRef := "entry0" } }
  let malformedProvenance := codexCompactionTargetWithEntry {
    codexStrictCompactionEntry with
      origin := {
        format := .codexCli
        sourceRef := "entry0"
        extras := some (Json.mkObj [
          (codexCompactionRawRecordKey, codexMalformedCompactionRecord)]) } }
  let summaryDrift := codexCompactionTargetWithEntry {
    codexStrictCompactionEntry with
      payload := .compaction "changed summary" .unknownPrefix none }
  let unrepresentableExtent := codexCompactionTargetWithEntry {
    codexStrictCompactionEntry with
      payload := .compaction codexStrictCompactionSummary (.knownPrefix 0) (some 9) }
  let historical := codexCompactionTargetWithEntry {
    time := .recorded ⟨1700000000123⟩
    payload := .compaction "historical checkpoint" (.knownPrefix 0) (some 9)
    origin := { format := .pi, sourceRef := "historical-checkpoint" }
    disposition := .historicalUnverified }
  let foreignNative := codexCompactionTargetWithEntry {
    time := .recorded ⟨1700000000123⟩
    payload := .compaction "claude soft-cut summary" .unknownPrefix (some 77)
    origin := { format := .claudeCode, sourceRef := "active0" }
    disposition := .native }
  codexTargetCompactionsValid codexMixedCompactionTargetFixture &&
  !codexTargetCompactionsValid noProvenance &&
  !codexTargetCompactionsValid malformedProvenance &&
  !codexTargetCompactionsValid summaryDrift &&
  !codexTargetCompactionsValid unrepresentableExtent &&
  codexTargetCompactionsValid historical &&
  codexTargetCompactionsValid foreignNative &&
  codexTargetRefusalContains noProvenance codexCompactionPreflightError &&
  codexTargetRefusalContains malformedProvenance codexCompactionPreflightError &&
  codexTargetRefusalContains summaryDrift codexCompactionPreflightError &&
  codexTargetRefusalContains unrepresentableExtent codexCompactionPreflightError &&
  (match exportCodexCliChecked historical with
   | .error _ => false
   | .ok exported =>
       match parseCodexSession exported, importCodexCli exported with
       | .ok (_, records), .ok restored =>
           !records.any (fun record => ostr record "type" == some "compacted") &&
           (match restored.entries[0]? with
            | some entry =>
                entry.disposition == EntryDisposition.historicalUnverified &&
                (match entry.payload with
                 | .compaction "historical checkpoint" (.knownPrefix 0) (some 9) => true
                 | _ => false)
            | none => false)
       | _, _ => false) &&
  (match exportCodexCliChecked foreignNative with
   | .error _ => false
   | .ok exported =>
       match parseCodexSession exported, importCodexCli exported with
       | .ok (_, records), .ok restored =>
           !records.any (fun record => ostr record "type" == some "compacted") &&
           (match restored.entries[0]? with
            | some entry =>
                entry.disposition == EntryDisposition.historicalUnverified &&
                (match entry.payload with
                 | .compaction "claude soft-cut summary" .unknownPrefix (some 77) => true
                 | _ => false)
            | none => false)
       | _, _ => false) &&
  match importCodexCli codexMalformedCompactionImportFixture with
  | .ok transcript => codexMalformedCompactionArchived transcript
  | .error _ => false

example : codexCompactionMalformedAndPreflightPinned = true := by native_decide

end LoomConvert
