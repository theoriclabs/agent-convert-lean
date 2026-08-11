import Loom.Formats
import Loom.Temporal
import Loom.WellFormed

/-!
# Loom.Ops — conversion obligations

The how-side of export: what a converter must *do* to a specific transcript
for a specific target. Everything here is derived from the what-side
(`Loom.Formats.supports`, transcript contents); nothing here adds new facts
about formats.

Feature probes are computable observations over a transcript; `obligations`
combines them with the matrix. Loss stops being a property of the code path
and becomes a computable property of (transcript, target).
-/

namespace Loom.Ops

private def hasDuplicate (xs : List Nat) : Bool := Id.run do
  let mut seen : List Nat := []
  for x in xs do
    if seen.contains x then
      return true
    seen := x :: seen
  return false

/-- Does the entry graph have a shared parent or more than one root? Multiple
disconnected roots are branch alternatives too: a flat exporter that ignores
`activeLeaf` can otherwise resume the wrong root without seeing a duplicate
parent value. -/
def hasBranches (t : Transcript) : Bool :=
  let roots := t.entries.toList.countP (fun entry => entry.parent.isNone)
  roots > 1 || hasDuplicate (t.entries.toList.filterMap (·.parent))

/-- Can the shipped target adapter preserve both Loom's shared-parent topology
and its explicit active branch selection in the re-imported IR? Pi retains the
graph and makes the selected leaf terminal. Claude archives sibling records but
its importer materializes only authoritative ancestry, so it does not yet meet
this continuation contract. -/
def preservesParentAndActiveLeaf : Format → Bool
  | .pi => true
  | _ => false

/-- Historical trust is typed IR state. Pi, Claude, Codex, and Cursor Agent
serialize this state through reviewed versioned inert entry carriers. The Wire
path bypasses `obligations` and preserves the field directly. -/
def preservesHistoricalDisposition : Format → Bool
  | .pi | .claudeCode | .codexCli | .cursorAgent => true
  | _ => false

/-- Content capabilities apply only to entries the target must represent
natively. Reviewed historical carriers preserve the complete typed entry and
must not inherit destructive obligations from the payload they keep inert. -/
private def nativeRepresentationSurface
    (tgt : Format) (t : Transcript) : Transcript :=
  if preservesHistoricalDisposition tgt then
    { t with entries := t.entries.filter (fun entry =>
        entry.disposition == EntryDisposition.native) }
  else t

def hasThinking (t : Transcript) : Bool :=
  t.entries.toList.any fun e =>
    match e.payload with
    | .assistantMsg blocks =>
        blocks.any fun b =>
          match b with
          | .thinking _ _ => true
          | _ => false
    | _ => false

def hasSidechains (t : Transcript) : Bool :=
  t.threads.toList.any fun th =>
    match th.kind with
    | .sidechain _ => true
    | .detached _ => true
    | _ => false

def hasCompaction (t : Transcript) : Bool :=
  t.entries.toList.any fun e =>
    match e.payload with
    | .compaction _ _ _ => true
    | _ => false

def hasMedia (t : Transcript) : Bool :=
  t.entries.toList.any fun e =>
    match e.payload with
    | .userMsg blocks | .otherMsg _ blocks => blocks.any (fun
        | .media _ _ => true
        | _ => false)
    | .assistantMsg blocks => blocks.any (fun
        | .media _ _ => true
        | _ => false)
    | .envMsg blocks => blocks.any (fun
        | .toolResult _ content _ => content.any (fun
            | .media _ _ => true
            | _ => false)
        | _ => false)
    | _ => false

def hasUnmodeled (t : Transcript) : Bool :=
  t.entries.toList.any fun e =>
    match e.payload with
    | .userMsg blocks | .otherMsg _ blocks => blocks.any (fun
        | .unmodeled _ _ => true
        | _ => false)
    | .assistantMsg blocks => blocks.any (fun
        | .unmodeled _ _ => true
        | _ => false)
    | .envMsg blocks => blocks.any (fun
        | .unmodeled _ _ => true
        | _ => false)
    | _ => false

private def jsonHasKey (raw : Lean.Json) (key : String) : Bool :=
  (raw.getObjVal? key).toOption.isSome

private def jsonString? (raw : Lean.Json) (key : String) : Option String :=
  (raw.getObjVal? key >>= Lean.Json.getStr?).toOption

private def jsonArray? (raw : Lean.Json) (key : String) : Option (Array Lean.Json) :=
  (raw.getObjVal? key >>= Lean.Json.getArr?).toOption

private def jsonObject? (raw : Lean.Json) (key : String) : Option Lean.Json :=
  (raw.getObjVal? key >>= Lean.Json.getObj?).toOption.map Lean.Json.obj

private def isJsonObject : Lean.Json → Bool
  | .obj _ => true
  | _ => false

private def rawType (raw : Lean.Json) : Option String :=
  jsonString? raw "type"

/-! ### Codex compaction export policy

`LoomConvert.CodexCli` depends on this module, so conversion policy cannot call
the adapter's public `codexTargetCompactionsValid` predicate without creating an
import cycle. The definitions below mirror its exact 0.144.1 checkpoint domain.
Executable pins in `LoomRequirements.Proofs` compare both predicates on native,
malformed, and historical cases. -/

private def codexCompactionOnlyObjectKeys
    (raw : Lean.Json) (allowed : List String) : Bool :=
  match raw with
  | .obj fields => fields.all (fun key _ => allowed.contains key)
  | _ => false

private def codexCompactionOptionalNonemptyString
    (raw : Lean.Json) (key : String) : Bool :=
  match raw.getObjVal? key with
  | .error _ | .ok .null => true
  | .ok (.str value) => !value.isEmpty
  | .ok _ => false

private def codexCompactionMetadataValid (item : Lean.Json) : Bool :=
  match item.getObjVal? "internal_chat_message_metadata_passthrough" with
  | .error _ | .ok .null => true
  | .ok metadata@(.obj _) =>
      codexCompactionOnlyObjectKeys metadata ["turn_id"] &&
        codexCompactionOptionalNonemptyString metadata "turn_id"
  | .ok _ => false

private def codexCompactionContentItemValid (item : Lean.Json) : Bool :=
  match jsonString? item "type" with
  | some "input_text" | some "output_text" =>
      codexCompactionOnlyObjectKeys item ["type", "text"] &&
        (jsonString? item "text").isSome
  | some "input_image" =>
      codexCompactionOnlyObjectKeys item ["type", "image_url", "detail"] &&
        (jsonString? item "image_url").any (fun locator => !locator.isEmpty) &&
        (match item.getObjVal? "detail" with
         | .error _ | .ok .null => true
         | .ok (.str detail) =>
             detail == "auto" || detail == "low" || detail == "high" ||
               detail == "original"
         | .ok _ => false)
  | _ => false

private def codexCompactionMessageItemValid (item : Lean.Json) : Bool :=
  codexCompactionOnlyObjectKeys item ["type", "id", "role", "content", "phase",
      "internal_chat_message_metadata_passthrough"] &&
    jsonString? item "type" == some "message" &&
    (jsonString? item "role").any (fun role => !role.isEmpty) &&
    (jsonArray? item "content").any (fun content =>
      content.all codexCompactionContentItemValid) &&
    codexCompactionOptionalNonemptyString item "id" &&
    (match item.getObjVal? "phase" with
     | .error _ | .ok .null => true
     | .ok (.str phase) => phase == "commentary" || phase == "final_answer"
     | .ok _ => false) &&
    codexCompactionMetadataValid item

private def codexCompactionSignatureItemValid (item : Lean.Json) : Bool :=
  codexCompactionOnlyObjectKeys item ["type", "id", "encrypted_content",
      "internal_chat_message_metadata_passthrough"] &&
    jsonString? item "type" == some "compaction" &&
    (jsonString? item "encrypted_content").any (fun signature => !signature.isEmpty) &&
    codexCompactionOptionalNonemptyString item "id" &&
    codexCompactionMetadataValid item

private def codexReplacementHistoryValid (history : Array Lean.Json) : Bool :=
  match history.toList.reverse with
  | [] => false
  | signature :: reversedMessages =>
      codexCompactionSignatureItemValid signature &&
        reversedMessages.all codexCompactionMessageItemValid

private def codexCompactedPayloadValid (payload : Lean.Json) : Bool :=
  codexCompactionOnlyObjectKeys payload ["message", "replacement_history",
      "window_number", "first_window_id", "previous_window_id", "window_id"] &&
    (jsonString? payload "message").isSome &&
    (jsonArray? payload "replacement_history").any codexReplacementHistoryValid &&
    (payload.getObjVal? "window_number" >>= Lean.Json.getNat?).toOption.any (· > 0) &&
    ["first_window_id", "previous_window_id", "window_id"].all (fun key =>
      (jsonString? payload key).any (fun value => !value.isEmpty))

private def codexCompactionTimeProvenanceJson?
    (time : Time) (sourceTimestamp : Option String) : Option Lean.Json :=
  let common := [
    ("protocol", Lean.Json.str "agent-convert.codex-carriers.v1"),
    ("kind", Lean.Json.str "entry_time_provenance")]
  let sourceField := match sourceTimestamp with
    | some value => [("source_timestamp", Lean.Json.str value)]
    | none => []
  match time with
  | .recorded _ => none
  | .interpolated timestamp basis => some (Lean.Json.mkObj (common ++ [
      ("state", Lean.Json.str "interpolated"),
      ("ms", Lean.Json.num timestamp.ms),
      ("basis", Lean.Json.str basis)] ++ sourceField))
  | .sequenced ordinal => some (Lean.Json.mkObj (common ++ [
      ("state", Lean.Json.str "sequenced"),
      ("ordinal", Lean.Json.num ordinal)] ++ sourceField))
  | .absent => some (Lean.Json.mkObj (common ++ [
      ("state", Lean.Json.str "absent")] ++ sourceField))

private def codexCompactionTimeProvenanceValid (record : Lean.Json) : Bool :=
  let parsed : Option (Time × Option String) := do
    let raw <- jsonObject? record "_agent_convert_time"
    guard (jsonString? raw "protocol" == some "agent-convert.codex-carriers.v1")
    guard (jsonString? raw "kind" == some "entry_time_provenance")
    let sourceTimestamp := jsonString? raw "source_timestamp"
    let time <- match jsonString? raw "state" with
      | some "interpolated" => do
          let ms <- (raw.getObjVal? "ms" >>= Lean.Json.getNat?).toOption
          let basis <- jsonString? raw "basis"
          pure (Time.interpolated ⟨ms⟩ basis)
      | some "sequenced" => do
          let ordinal <- (raw.getObjVal? "ordinal" >>= Lean.Json.getNat?).toOption
          pure (Time.sequenced ordinal)
      | some "absent" => pure Time.absent
      | _ => none
    guard (codexCompactionTimeProvenanceJson? time sourceTimestamp == some raw)
    pure (time, sourceTimestamp)
  parsed.isSome

private def codexCompactedRecordValid (record : Lean.Json) : Bool :=
  codexCompactionOnlyObjectKeys record
      ["timestamp", "type", "payload", "_agent_convert_time"] &&
    jsonString? record "type" == some "compacted" &&
    (jsonString? record "timestamp" >>= iso8601ToEpochMs?).isSome &&
    (jsonObject? record "payload").any codexCompactedPayloadValid &&
    (!jsonHasKey record "_agent_convert_time" ||
      codexCompactionTimeProvenanceValid record)

private def codexNativeCompactionExportable (entry : Entry) : Bool :=
  entry.disposition == EntryDisposition.native &&
    entry.origin.format == Format.codexCli &&
    entry.origin.sourceRef.startsWith "entry" &&
    match entry.payload with
    | .compaction summary .unknownPrefix none =>
        (entry.origin.extras >>= fun extras =>
          jsonObject? extras "raw_compaction_record").any (fun record =>
            codexCompactedRecordValid record &&
              (jsonObject? record "payload").any (fun payload =>
                jsonString? payload "message" == some summary))
    | _ => false

/-- Policy-side Codex compaction predicate. Historical compactions use the
typed inert carrier; Codex-origin native compactions require an exact,
internally consistent 0.144.1 checkpoint record and are never synthesized from
summary text alone. Foreign native compaction is retained via the historical
carrier (mirrors LoomConvert.CodexCli.codexCompactionEntryExportable). -/
def codexCompactionEntryExportable (entry : Entry) : Bool :=
  match entry.payload with
  | .compaction _ _ _ =>
      entry.disposition == EntryDisposition.historicalUnverified ||
        codexNativeCompactionExportable entry ||
        entry.origin.format != Format.codexCli
  | _ => true

def codexTargetCompactionsValid (t : Transcript) : Bool :=
  t.entries.all codexCompactionEntryExportable

/-- Codex assistant/environment unknowns use protocol-stamped inert carriers.
User unknowns are only reversible when they are exact malformed-message or
message-content values produced by the Codex importer; every other user
unknown is filtered by the exporter. -/
private def codexTextContentType (kind : String) : Bool :=
  kind == "input_text" || kind == "output_text" || kind == "text"

private def codexContentItemRemainsUnmodeled (raw : Lean.Json) : Bool :=
  match rawType raw with
  | some kind =>
      if codexTextContentType kind then (jsonString? raw "text").isNone
      else if kind == "input_image" then (jsonString? raw "image_url").isNone
      else true
  | none => true

private def codexMalformedUserMessageRoundTrips (raw : Lean.Json) : Bool :=
  isJsonObject raw && rawType raw == some "message" &&
    jsonString? raw "role" == some "user" &&
    (jsonArray? raw "content").isNone &&
    !jsonHasKey raw "_agent_convert"

private def codexUserUnmodeledRoundTrips (label : String) (raw : Lean.Json) : Bool :=
  if label == "codex.message_content" then codexContentItemRemainsUnmodeled raw
  else if label == "codex.message" then codexMalformedUserMessageRoundTrips raw
  else false

def hasCodexUnexportableUnmodeled (t : Transcript) : Bool :=
  t.entries.toList.any fun e =>
    match e.payload with
    | .userMsg blocks => blocks.any (fun
        | .unmodeled label raw => !codexUserUnmodeledRoundTrips label raw
        | _ => false)
    | _ => false

def hasCodexEmptyMessages (t : Transcript) : Bool :=
  t.entries.toList.any fun entry =>
    match entry.payload with
    | .userMsg [] | .assistantMsg [] => true
    | _ => false

private def codexCustomEventRoundTrips (label : String) (raw : Lean.Json) : Bool :=
  if !isJsonObject raw then false
  else
    let kind := (rawType raw).getD ""
    if kind == "error" then label == "error"
    else if kind == "user_message" || kind == "agent_message" ||
        kind == "task_started" || kind == "task_complete" || kind == "token_count"
      then false
    else
      let expected := if kind.isEmpty then "codex.event_msg.unknown"
        else "codex.event_msg." ++ kind
      label == expected

def hasCodexUnexportableEvents (t : Transcript) : Bool :=
  t.entries.toList.any fun entry =>
    match entry.payload with
    | .event (.custom label raw) => !codexCustomEventRoundTrips label raw
    | .event _ => true
    | _ => false

private def lowerAscii (text : String) : String :=
  String.ofList (text.toList.map Char.toLower)

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

/-- Mirror the checked Codex 0.144.1 target's deliberately narrow media
contract. It accepts complete inline base64 image data URIs and refuses remote
URLs or payloads whose magic bytes disagree with the declared MIME. -/
def codexImageLocatorValid (locator : String) : Bool :=
  match locator.splitOn "," with
  | [metadata, payload] =>
      let parts := metadata.splitOn ";"
      let mime := lowerAscii (parts.headD "")
      let supportedMime := ["data:image/png", "data:image/jpeg",
        "data:image/gif", "data:image/webp"].contains mime
      supportedMime &&
        (parts.drop 1).any (fun part => lowerAscii part == "base64") &&
        codexBase64PayloadValid payload && codexImagePayloadMatchesMime mime payload
  | _ => false

private def codexTypedMediaUnexportable : UserBlock → Bool
  | .media mime locator => mime != "image" || !codexImageLocatorValid locator
  | _ => false

def hasCodexUnexportableMedia (t : Transcript) : Bool :=
  t.entries.toList.any fun entry =>
    match entry.payload with
    | .userMsg blocks | .otherMsg _ blocks =>
        blocks.any codexTypedMediaUnexportable
    | .assistantMsg blocks => blocks.any (fun
        | .media mime locator => mime != "image" || !codexImageLocatorValid locator
        | _ => false)
    | .envMsg blocks => blocks.any (fun
        | .toolResult _ content _ => content.any codexTypedMediaUnexportable
        | _ => false)
    | .compaction _ _ _ | .event _ => false

def hasEnvMessages (t : Transcript) : Bool :=
  t.entries.toList.any fun e =>
    match e.payload with
    | .envMsg _ => true
    | _ => false

def hasOtherRoles (t : Transcript) : Bool :=
  t.entries.toList.any fun e =>
    match e.payload with
    | .otherMsg _ _ => true
    | _ => false

def hasEvents (t : Transcript) : Bool :=
  t.entries.toList.any fun e =>
    match e.payload with
    | .event _ => true
    | _ => false

/-- Pi writes raw unknown blocks directly. Exact re-import therefore requires
the stored label to agree with the raw discriminator and the discriminator not
to select a modeled or role-invalid block parser. Assistant `toolCall` and
`toolResult` discriminators are the exception: the exporter wraps those in an
explicit inert carrier. -/
private def piUserUnmodeledRoundTrips (label : String) (raw : Lean.Json) : Bool :=
  match rawType raw with
  | some kind => !kind.isEmpty && label == kind &&
      !["text", "media", "thinking", "toolCall"].contains kind
  | none => false

private def piOpenRoleUnmodeledRoundTrips (label : String) (raw : Lean.Json) : Bool :=
  match rawType raw with
  | some kind => !kind.isEmpty && label == kind && !["text", "media"].contains kind
  | none => false

private def piAssistantUnmodeledRoundTrips (label : String) (raw : Lean.Json) : Bool :=
  match rawType raw with
  | some "toolCall" | some "toolResult" => true
  | some kind => !kind.isEmpty && label == kind &&
      !["text", "thinking", "media", "agentConvertUnmodeledAssistant"].contains kind
  | none => false

def hasPiUnexportableUnmodeled (t : Transcript) : Bool :=
  t.entries.toList.any fun entry =>
    match entry.payload with
    | .userMsg blocks => blocks.any (fun
        | .unmodeled label raw => !piUserUnmodeledRoundTrips label raw
        | _ => false)
    | .assistantMsg blocks => blocks.any (fun
        | .unmodeled label raw => !piAssistantUnmodeledRoundTrips label raw
        | _ => false)
    | .envMsg blocks => blocks.any (fun
        | .unmodeled _ _ => true
        | .toolResult _ content _ => content.any (fun
            | .unmodeled label raw => !piUserUnmodeledRoundTrips label raw
            | _ => false))
    | .otherMsg _ blocks => blocks.any (fun
        | .unmodeled label raw => !piOpenRoleUnmodeledRoundTrips label raw
        | _ => false)
    | _ => false

private def nonemptyString? (value : Option String) : Bool :=
  match value with
  | some text => !text.isEmpty
  | none => false

private def piCallHasExportableId (t : Transcript) : CallRef → Bool
  | .resolved entry block =>
      match t.entries[entry]? with
      | some { payload := .assistantMsg blocks, .. } =>
          match blocks[block]? with
          | some (.toolCall _ _ rawId) => nonemptyString? rawId
          | _ => false
      | _ => false
  | .unresolved _ _ => false

def hasPiUnexportableToolLifecycle (t : Transcript) : Bool :=
  t.entries.toList.any fun entry =>
    match entry.payload with
    | .assistantMsg blocks => blocks.any (fun
        | .toolCall name _ rawId => name.raw.isEmpty || !nonemptyString? rawId
        | _ => false)
    | .envMsg [] => true
    | .envMsg blocks => blocks.any (fun
        | .toolResult _ _ (.inferred _ _) => true
        | .toolResult call _ _ => !piCallHasExportableId t call
        | .unmodeled _ _ => true)
    | _ => false

private def piRawEntry? (origin : Origin) : Option Lean.Json :=
  origin.extras >>= fun extras => jsonObject? extras "piRaw"

private def piProviderAvailable (t : Transcript) (entry : Entry) : Bool :=
  nonemptyString? ((piRawEntry? entry.origin) >>= fun raw => jsonString? raw "provider") ||
  nonemptyString? t.env.provider ||
  match t.origin.format with
  | .claudeCode | .codexCli | .googleAiStudio | .cursorAgent | .cursorIde | .hermes => true
  | _ => false

private def piCustomEventRoundTrips
    (entry : Entry) (label : String) (raw : Lean.Json) : Bool :=
  !label.isEmpty &&
    if entry.origin.format == Format.pi then piRawEntry? entry.origin == some raw
    else true

def hasPiUnrepresentableEvents (t : Transcript) : Bool :=
  t.entries.toList.any fun entry =>
    match entry.payload with
    | .event (.permissionMode _) => true
    | .event (.modelChange _ next) =>
        !nonemptyString? next || !piProviderAvailable t entry
    | .event (.thinkingLevelChange _ next) => !nonemptyString? next
    | .event (.custom label raw) => !piCustomEventRoundTrips entry label raw
    | _ => false

def hasPiUnexportableOtherRoles (t : Transcript) : Bool :=
  t.entries.toList.any fun entry =>
    match entry.payload with
    | .otherMsg role _ => role.isEmpty ||
        ["user", "assistant", "toolResult"].contains role
    | _ => false

/-- Cursor Agent has no carrier envelope inside message content. Safe unknowns
are exactly those that its importer will classify as the same unknown label. -/
private def cursorUserUnmodeledRoundTrips (label : String) (raw : Lean.Json) : Bool :=
  match rawType raw with
  | some kind => label == kind && kind != "text" && kind != "tool_use"
  | none => !jsonHasKey raw "type" && label == "cursor_agent.content"

private def cursorAssistantUnmodeledRoundTrips
    (label : String) (raw : Lean.Json) : Bool :=
  cursorUserUnmodeledRoundTrips label raw

def hasCursorUnexportableUnmodeled (t : Transcript) : Bool :=
  t.entries.toList.any fun entry =>
    match entry.payload with
    | .userMsg blocks => blocks.any (fun
        | .unmodeled label raw => !cursorUserUnmodeledRoundTrips label raw
        | _ => false)
    | .assistantMsg blocks => blocks.any (fun
        | .unmodeled label raw => !cursorAssistantUnmodeledRoundTrips label raw
        | _ => false)
    | _ => false

private def cursorToolCallRoundTrips
    (name : ToolName) (arguments : Lean.Json) : Bool :=
  !name.raw.isEmpty &&
    (isJsonObject arguments ||
      (match arguments with
       | .str _ => name.raw == "ApplyPatch"
       | _ => false))

def hasCursorUnexportableToolCalls (t : Transcript) : Bool :=
  t.entries.toList.any fun entry =>
    match entry.payload with
    | .assistantMsg blocks => blocks.any (fun
        | .toolCall name arguments _ =>
            !cursorToolCallRoundTrips name arguments
        | _ => false)
    | _ => false

private def cursorTurnEndedRoundTrips (raw : Lean.Json) : Bool :=
  let status := jsonString? raw "status"
  let errorFieldValid := !jsonHasKey raw "error" || (jsonString? raw "error").isSome
  nonemptyString? status && errorFieldValid &&
    (status != some "error" || (jsonString? raw "error").isSome)

private def cursorCustomEventRoundTrips (label : String) (raw : Lean.Json) : Bool :=
  match raw with
  | .obj _ =>
      if jsonHasKey raw "type" then
        match rawType raw with
        | some "turn_ended" =>
            label == "cursor_agent.turn_ended" && cursorTurnEndedRoundTrips raw
        | some kind => label == "cursor_agent." ++ kind
        | none => label == "cursor_agent.unknown_type"
      else if jsonHasKey raw "uuid" || jsonHasKey raw "parentUuid" ||
          jsonHasKey raw "sessionId" then
        label == "cursor_agent.foreign_record"
      else if jsonHasKey raw "role" || jsonHasKey raw "message" then false
      else label == "cursor_agent.unknown_record"
  | _ => label == "cursor_agent.non_object"

def hasCursorUnexportableEvents (t : Transcript) : Bool :=
  t.entries.toList.any fun entry =>
    match entry.payload with
    | .event (.custom label raw) => !cursorCustomEventRoundTrips label raw
    | .event _ => true
    | _ => false

/-! ## Metadata and identity fidelity

These losses are separate from content-shape obligations. Some change
continuation meaning or executable trust and must block; exact vendor records
that serve only forensic audit are still reported, but need not make an
otherwise faithful continuation unusable. The typed impact surface below keeps
that distinction executable without pretending that minting a target identifier
preserves an identifier the source already had.
-/

inductive MetadataLoss where
  | sourceIdentity
  | environment (fields : List String)
  | originProvenance
  | safetyProvenance
  | toolCallIds
  | timeProvenance
  deriving Repr, DecidableEq

private def hasDuplicateString (values : List String) : Bool := Id.run do
  let mut seen : List String := []
  for value in values do
    if seen.contains value then return true
    seen := value :: seen
  return false

private def preferredEntryId (entryIdx : Nat) (entry : Entry) : String :=
  match entry.origin.rawId with
  | some rawId => if rawId.isEmpty then s!"e{entryIdx}" else rawId
  | none => s!"e{entryIdx}"

private def piPreferredPhysicalEntryIds (entryIdx : Nat) (entry : Entry) : List String :=
  let id := preferredEntryId entryIdx entry
  match entry.payload with
  | .envMsg blocks =>
      if blocks.length <= 1 then [id]
      else blocks.zipIdx.map (fun (_, blockIdx) =>
        if blockIdx == 0 then id else s!"{id}#r{blockIdx}")
  | _ => [id]

/-- Pi and Claude plan target record IDs from source entry IDs. The plan is
identity-preserving only when every present ID is nonempty and the complete
preferred-ID domain is collision-free. Missing IDs are synthesis, not loss. -/
private def plannedEntryIdsPreservePresentIds (t : Transcript) : Bool :=
  let preferred := t.entries.toList.zipIdx.flatMap (fun (entry, entryIdx) =>
    piPreferredPhysicalEntryIds entryIdx entry)
  let presentIdsValid := t.entries.toList.all (fun entry =>
    match entry.origin.rawId with
    | some rawId => !rawId.isEmpty
    | none => true)
  presentIdsValid && !hasDuplicateString preferred

private def claudeHexDigit (char : Char) : Bool :=
  ('0' <= char && char <= '9') || ('a' <= char && char <= 'f') ||
    ('A' <= char && char <= 'F')

private def claudeUuidValid (value : String) : Bool :=
  match value.splitOn "-" with
  | [a, b, c, d, e] =>
      a.length == 8 && b.length == 4 && c.length == 4 && d.length == 4 &&
        e.length == 12 && [a, b, c, d, e].all (fun part =>
          part.toList.all claudeHexDigit)
  | _ => false

private def claudeEntryIdentityNeedsSynthesis (t : Transcript) : Bool :=
  let explicit := t.entries.toList.filterMap (fun entry =>
    entry.origin.rawId.bind (fun rawId =>
      if claudeUuidValid rawId then some rawId else none))
  t.entries.toList.any (fun entry =>
    match entry.origin.rawId with
    | some rawId => !claudeUuidValid rawId || explicit.count rawId != 1
    | none => true)

private def hasPresentEntryIdentity (t : Transcript) : Bool :=
  t.entries.toList.any (fun entry => entry.origin.rawId.isSome)

def sourceTargetConfigurationArchiveKey : String :=
  "_agent_convert_source_target_configuration"

def sourceTargetConfigurationArchiveProtocol : String :=
  "agent-convert.source-target-configuration.v1"

def sourceOriginExtrasArchiveKey : String :=
  "_agent_convert_source_origin_extras"

def sourceOriginExtrasArchiveProtocol : String :=
  "agent-convert.source-origin-extras.v1"

/-- Recognize Main's versioned source-provenance archive. Recognition never
activates the nested values; target selection reads direct origin fields only. -/
def sourceTargetConfigurationArchiveStamped (origin : Origin) : Bool :=
  match origin.extras >>= fun extras => jsonObject? extras
      sourceTargetConfigurationArchiveKey with
  | some archive => jsonString? archive "protocol" ==
      some sourceTargetConfigurationArchiveProtocol
  | none => false

/-- Main wraps a non-object source `Origin.extras` value before adding direct
target fields. The wrapped raw value remains provenance and is never searched
for active target controls. -/
def sourceOriginExtrasArchiveStamped (origin : Origin) : Bool :=
  match origin.extras >>= fun extras => jsonObject? extras
      sourceOriginExtrasArchiveKey with
  | some archive => jsonString? archive "protocol" ==
      some sourceOriginExtrasArchiveProtocol
  | none => false

/-- Read a control supplied for the current target invocation. This lookup is
deliberately shallow: archived `cleared`/`prior` values are source history, not
authority for a later target. -/
private def transcriptTargetString (t : Transcript) (key : String) : Option String :=
  t.origin.extras >>= fun extras => jsonString? extras key >>= fun value =>
    if value.isEmpty then none else some value

/-- Pi's complete target launch bundle emits a separate, versioned
`sourceEnvironment` value containing all six `EnvInfo` fields. Target controls
may differ without being mistaken for source preservation. -/
def piTargetHarnessVersion : String := "0.74.0"

private def piCarriesSourceEnvironment (t : Transcript) : Bool :=
  ["target_session_id", "target_cwd", "target_provider", "target_model",
    "target_timestamp"].all (fun key => (transcriptTargetString t key).isSome) &&
    transcriptTargetString t "target_harness_version" ==
      some piTargetHarnessVersion

private def transcriptRawIdentityPreserved (tgt : Format) (t : Transcript) : Bool :=
  match t.origin.rawId with
  | none => true
  | some rawId =>
      if rawId.isEmpty then false
      else match tgt with
        | .pi =>
            let emitted := transcriptTargetString t "target_session_id" <|>
              if t.origin.format == Format.pi then
                t.env.sessionId <|> some rawId
              else none
            emitted == some rawId
        | .claudeCode => true -- changed identities use the versioned identity carrier
        | .codexCli => t.env.sessionId == some rawId
        | .openCode => true -- source identities ride in _agentConvert metadata
        | _ => false

def hasUnpreservedSourceIdentity (tgt : Format) (t : Transcript) : Bool :=
  let sessionLost :=
    t.env.sessionId.isSome &&
      (tgt == Format.cursorAgent ||
        (tgt == Format.pi && !piCarriesSourceEnvironment t))
  let entryIdsLost :=
    if !hasPresentEntryIdentity t then false
    else match tgt with
      | .pi => !plannedEntryIdsPreservePresentIds t
      | .claudeCode => false -- invalid/duplicate IDs are archived before UUID synthesis
      | .openCode => false -- source ids are retained in part/session metadata
      | _ => true
  sessionLost || entryIdsLost || !transcriptRawIdentityPreserved tgt t

/-- A direct target timestamp selects Codex's fresh-target export path. That
path always writes all six source `EnvInfo` fields into the exact inert
`historical_source_provenance` archive. Adapter preflight separately requires
the complete 0.144.1 target bundle and exact operational controls. -/
private def codexCarriesSourceEnvironment (t : Transcript) : Bool :=
  (transcriptTargetString t "target_timestamp").isSome

/-- External Claude build against which the source-environment carrier path is
validated. This policy constant is cross-pinned to the adapter constant in the
requirements proofs, avoiding a dependency from conversion policy back into an
exporter. -/
def claudeTargetHarnessVersion : String := "2.1.216"

private def jsonNullableStringField (value : Lean.Json) (key : String) : Bool :=
  match value.getObjVal? key with
  | .ok (.str _) | .ok .null => true
  | _ => false

private def claudeSourceEnvironmentCarrierValid (t : Transcript) : Bool :=
  match t.origin.extras >>= fun extras => jsonObject? extras "source_env" with
  | none => false
  | some carrier =>
      jsonString? carrier "carrier" ==
          some "agent-convert.claude-source-env.v1" &&
        ["cwd", "model", "provider", "harnessVersion", "instructions",
          "sessionId"].all (jsonNullableStringField carrier)

private def claudeHasDirectTargetKey (t : Transcript) : Bool :=
  match t.origin.extras with
  | some (.obj fields) =>
      fields.toList.any (fun (key, _) => key.startsWith "target_")
  | _ => false

/-- A source-native, unretargeted Claude export physically writes only cwd and
session identity from `EnvInfo`. Model/provider/instructions/version do not have
equivalent transcript-level slots and therefore receive no native exception. -/
private def claudeNativePreservesEnvironmentField
    (t : Transcript) (field : String) : Bool :=
  let hasSourceCarrier :=
    (t.origin.extras >>= fun extras =>
      (extras.getObjVal? "source_env").toOption).isSome
  t.origin.format == Format.claudeCode && !claudeHasDirectTargetKey t &&
    !hasSourceCarrier && (field == "cwd" || field == "sessionId")

/-- A non-native Claude target writes every source `EnvInfo` field, including
explicit absence, into its exact inert source-environment carrier. The physical
target cwd/session are independent launch controls and must be explicit before
policy credits that carrier. The reader-version assertion is validated
separately and does not change what the carrier encodes. A re-imported valid
carrier keeps the same guarantee for a subsequent hop. -/
private def claudeCarriesSourceEnvironment (t : Transcript) : Bool :=
  let retargeted := t.origin.format != Format.claudeCode ||
    (transcriptTargetString t "target_cwd").isSome ||
    (transcriptTargetString t "target_session_id").isSome ||
    claudeSourceEnvironmentCarrierValid t
  retargeted &&
    (transcriptTargetString t "target_cwd").isSome &&
    (transcriptTargetString t "target_session_id").isSome

private def targetPreservesEnvironmentField
    (tgt : Format) (t : Transcript) (field : String) : Bool :=
  match field, tgt with
  | _, .pi => piCarriesSourceEnvironment t
  | field, .claudeCode =>
      claudeCarriesSourceEnvironment t ||
        claudeNativePreservesEnvironmentField t field
  | _, .codexCli => codexCarriesSourceEnvironment t ||
      t.origin.format == Format.codexCli
  | _, .openCode => true
  | _, _ => false

def unpreservedEnvironmentFields (tgt : Format) (t : Transcript) : List String :=
  [ ("cwd", t.env.cwd.isSome),
    ("model", t.env.model.isSome),
    ("provider", t.env.provider.isSome),
    ("harnessVersion", t.env.harnessVersion.isSome),
    ("instructions", t.env.instructions.isSome),
    ("sessionId", t.env.sessionId.isSome) ].filterMap (fun (field, present) =>
      if present && !targetPreservesEnvironmentField tgt t field then some field else none)

private def targetOptionKey (key : String) : Bool :=
  ["target_timestamp", "target_model", "target_cli_version",
   "target_harness_version",
   "target_originator", "target_model_provider", "target_turn_context_record",
   "target_codex_controls", "target_cursor_agent_controls",
   "target_session_id", "target_cwd", "target_provider",
   "pi_assistant_history", "ts"].contains key

private def originCarriesSourceExtras (origin : Origin) : Bool :=
  match origin.extras with
  | none => false
  | some (.obj fields) =>
      (fields.get? sourceTargetConfigurationArchiveKey).isSome ||
        (fields.get? sourceOriginExtrasArchiveKey).isSome ||
        !fields.all (fun key _ => targetOptionKey key)
  | some _ => true

private def cursorNativeOriginPreserved (origin : Origin) : Bool :=
  origin.format == Format.cursorAgent &&
    match origin.extras with
    | some (.obj fields) =>
        (fields.get? "rawRecord").isSome && fields.all (fun key _ => key == "rawRecord")
    | _ => false

private def targetPreservesNativeOrigin (tgt : Format) (origin : Origin) : Bool :=
  if tgt == Format.cursorAgent then cursorNativeOriginPreserved origin
  else origin.format == tgt &&
    [Format.pi, Format.claudeCode, Format.codexCli].contains tgt

def hasUnpreservedOriginProvenance (tgt : Format) (t : Transcript) : Bool :=
  (originCarriesSourceExtras t.origin && !targetPreservesNativeOrigin tgt t.origin) ||
    t.entries.toList.any (fun entry =>
      originCarriesSourceExtras entry.origin &&
        !targetPreservesNativeOrigin tgt entry.origin)

def hasUnpreservedSafetyProvenance (tgt : Format) (t : Transcript) : Bool :=
  !preservesHistoricalDisposition tgt && t.entries.toList.any (fun entry =>
    entry.disposition == EntryDisposition.historicalUnverified)

def hasUnpreservedToolCallIds (tgt : Format) (t : Transcript) : Bool :=
  if tgt != Format.cursorAgent then false
  else t.entries.toList.any (fun entry =>
    match entry.payload with
    | .assistantMsg blocks => blocks.any (fun block =>
        match block with
        | .toolCall _ _ (some rawId) => rawId.isEmpty
        | _ => false)
    | _ => false)

/-- Pi, Claude, and Codex emit a stamped, typed carrier and reconstruct every
non-recorded `Time` constructor exactly. Codex still uses its launch timestamp
operationally, but its separate carrier restores the source value. Cursor has
no carrier for interpolated/sequenced facts. -/
def preservesNonRecordedTimeProvenance : Format → Bool
  | .pi | .claudeCode | .codexCli | .openCode => true
  | _ => false

private def losesNonRecordedTimeProvenance (tgt : Format) (t : Transcript) : Bool :=
  if preservesNonRecordedTimeProvenance tgt then false
  else
    let targetMintsTimestamp := tgt == Format.codexCli
    t.entries.toList.any (fun entry =>
      match entry.time with
      | .interpolated _ _ | .sequenced _ => true
      | .absent => targetMintsTimestamp
      | .recorded _ => false)

def metadataLosses (tgt : Format) (t : Transcript) : List MetadataLoss := Id.run do
  let mut losses : Array MetadataLoss := #[]
  if hasUnpreservedSourceIdentity tgt t then
    losses := losses.push .sourceIdentity
  let environment := unpreservedEnvironmentFields tgt t
  if !environment.isEmpty then losses := losses.push (.environment environment)
  if hasUnpreservedOriginProvenance tgt t then
    losses := losses.push .originProvenance
  if hasUnpreservedSafetyProvenance tgt t then
    losses := losses.push .safetyProvenance
  if hasUnpreservedToolCallIds tgt t then
    losses := losses.push .toolCallIds
  if losesNonRecordedTimeProvenance tgt t then
    losses := losses.push .timeProvenance
  return losses.toList

/-- Any entry whose time is not `recorded` — i.e. fabricated or missing. -/
def hasNonRecordedTime (t : Transcript) : Bool :=
  t.entries.toList.any fun e =>
    match e.time with
    | .recorded _ => false
    | _ => true

def hasRecordedTime (t : Transcript) : Bool :=
  t.entries.toList.any fun entry =>
    match entry.time with
    | .recorded _ => true
    | _ => false

/-- Timestamped target exporters that serialize `Time.recorded` as UTC and
whose importers lift that exact millisecond value back into the IR. -/
def preservesRecordedTime : Format → Bool
  | .pi | .claudeCode | .codexCli | .openCode => true
  | _ => false

/-- Actual recorded time is destructive only when the target cannot carry the
recorded epoch. Absent/interpolated/sequenced values are handled separately as
observable timestamp synthesis (or as `MetadataLoss.timeProvenance` for a
timestamp-free target); they are not mislabeled as dropped recorded facts. -/
def hasUnexportableTime (tgt : Format) (t : Transcript) : Bool :=
  t.entries.toList.any fun entry =>
    match entry.time with
    | .recorded _ => !preservesRecordedTime tgt
    | .absent | .interpolated _ _ | .sequenced _ => false

def synthesizesTargetTimestamps : Format → Bool
  | .pi | .claudeCode | .codexCli | .openCode => true
  | _ => false

/-- Pi's exporter currently prefers a source-scoped `extras.ts` or explicit
target timestamp over typed time. Reject an invalid preferred spelling before
emitting JSONL that Pi's strict importer cannot consume. -/
def hasInvalidPiPreferredTimestamp (t : Transcript) : Bool :=
  let invalid := fun value => (iso8601ToEpochMs? value).isNone
  let invalidTarget := match t.origin.extras >>= fun extras => jsonString? extras "target_timestamp" with
    | some value => invalid value
    | none => false
  invalidTarget || t.entries.toList.any (fun entry =>
    match entry.origin.extras >>= fun extras => jsonString? extras "ts" with
    | some value => invalid value
    | none => false)

/-- Positions (entry, block) of all top-level tool calls. -/
def callSites (t : Transcript) : List (Nat × Nat) := Id.run do
  let mut out : Array (Nat × Nat) := #[]
  let mut i : Nat := 0
  for e in t.entries do
    match e.payload with
    | .assistantMsg blocks => do
        let mut j : Nat := 0
        for b in blocks do
          match b with
          | .toolCall _ _ _ => out := out.push (i, j)
          | _ => pure ()
          j := j + 1
    | _ => pure ()
    i := i + 1
  return out.toList

/-- Positions of calls that some result resolves to. -/
def resolvedRefs (t : Transcript) : List (Nat × Nat) := Id.run do
  let mut out : Array (Nat × Nat) := #[]
  for e in t.entries do
    match e.payload with
    | .envMsg blocks =>
        for b in blocks do
          match b with
          | .toolResult (.resolved re rb) _ _ => out := out.push (re, rb)
          | _ => pure ()
    | _ => pure ()
  return out.toList

/-- Calls that never received a result. Legitimate in a crashed session;
an export obligation for targets that require closure (Claude resume —
the 2.27 orphan-closing fix, now a computable fact). -/
def openCalls (t : Transcript) : List (Nat × Nat) :=
  let refs := resolvedRefs t
  (callSites t).filter fun c => !(refs.contains c)

/-- What an exporter must do to a *specific transcript* for a *specific
target*. -/
inductive Obligation where
  /-- Target requires every tool call closed before resume (Claude); count
  of open calls that need synthetic closure — the 2.27 fix, as a type. -/
  | closeOpenToolCalls (count : Nat)
  | dropThinking
  | dropSidechains
  /-- Target cannot exactly preserve the parent tree plus `activeLeaf`, or a
  nonempty source has no active selection. An active path must be selected and
  the choice recorded before producing a resumable target. -/
  | linearizeBranches
  /-- The source has no ID for at least one identity-bearing target record, so
  a new target ID must be minted. A present source ID is never covered by this
  obligation: replacing one is `MetadataLoss.sourceIdentity` instead. -/
  | synthesizeEntryIds
  /-- Target records native time but this transcript carries fabricated or
  absent times; exporting mints timestamps that did not exist. -/
  | synthesizeTimestamps
  /-- The selected exporter would silently discard an actually recorded epoch.
  Non-recorded provenance has its own synthesis/loss cases below. -/
  | dropRecordedTime
  /-- Transcript has compaction summaries the target cannot represent. -/
  | dropCompaction
  | dropMedia
  | dropUnmodeled
  | dropToolResults
  | dropOtherRoles
  | dropEvents
  /-- A source-carried session or entry identity would be replaced or erased
  without a reversible provenance carrier. -/
  | dropSourceIdentity
  /-- Operational environment facts that the target cannot restore. -/
  | dropEnvironment (fields : List String)
  /-- Format-scoped raw/extras provenance has no exact target carrier. -/
  | dropOriginProvenance
  /-- A present tool-call ID would be erased or replaced. -/
  | dropToolCallIds
  /-- Exact absent/interpolated/sequenced provenance would disappear. Minting
  a target-native timestamp is not preservation of the source `Time` value. -/
  | dropTimeProvenance
  deriving Repr, DecidableEq

/-- How the release gate must treat an observable export obligation. -/
inductive ObligationImpact where
  /-- Work the exporter must perform and report without dropping a source fact. -/
  | fulfillment
  /-- Forensic/audit degradation that must be reported but does not alter the
  continuation's authorship, content, controls, linkage, or active path. -/
  | reportOnly
  /-- A semantic, operational, identity, linkage, or safety fact would be lost. -/
  | destructive
  deriving Repr, DecidableEq

private def environmentLossIsDestructive (fields : List String) : Bool :=
  fields.any (fun field => field != "harnessVersion")

private def hasExplicitTargetSessionIdentity (tgt : Format) (t : Transcript) : Bool :=
  (transcriptTargetString t "target_session_id").isSome ||
    (t.origin.format == tgt && nonemptyString? t.env.sessionId &&
      targetPreservesEnvironmentField tgt t "sessionId")

/-! ### Losses forced by the target versus losses chosen by the exporter

`LoomOps.Interop.Emission.refused` permits refusal "only when emitting would
produce a corrupt or actively misleading artifact — never merely because output
would be lossy", and `Interop.LossImpact` makes that decidable: a fact the
target has **no slot for** is `reportable`, because what is emitted is still
valid, still resumable, and still an honest record of what it does contain.

Every predicate below is target-scoped on purpose. The same obligation against
a target that *does* have the slot stays `destructive`: there the exporter is
discarding a fact the format could have written, which is an exporter defect
rather than an expressiveness limit. Among the five export targets only
`cursorAgent` answers `false`/`Support.absent` to any of them, so this section
changes the classification for no other target.

Without this, `obligationImpactFor`'s catch-all made cursor-agent unreachable
from every real Claude or Codex session: a source with timestamps and a cwd —
i.e. all of them — tripped `dropRecordedTime` and `dropEnvironment` before any
content was examined. -/

/-- Does the target's wire format have a tool-result record at all?

Cursor Agent is the one target that does not. The 2026-07-06 census over 427
files / ~14,863 records (`Loom.Formats.CursorAgent`, claim `L9`) found 16,210
`tool_use` blocks and **zero** results in any of the format's three record
shapes, so a cursor-agent transcript never carries a result. Emitting calls
without results is what a native session looks like, not a corruption of one. -/
def targetStoresToolResults : Format → Bool
  | .cursorAgent => false
  | _ => true

/-- Does the target's wire format have session-environment slots at all?

`Concept.environment` is `.approximate` for cursor-agent rather than `.absent`
only because its session id is recoverable from the **file name**. That is a
path convention, not transcript content, so no `EnvInfo` field survives inside
the artifact and `targetPreservesEnvironmentField` already answers `false` for
every field of that target. -/
def targetStoresEnvironment : Format → Bool
  | .cursorAgent => false
  | _ => true

/-- Is this obligation forced by the target's expressiveness rather than chosen?
Answers for the exact obligations whose losses `Interop.knownLosses` classifies
`reportable`; everything else keeps the conservative default. -/
def obligationForcedByTargetLimits (tgt : Format) : Obligation → Bool
  | .dropThinking => supports tgt .thinkingContent == .absent
  | .dropToolResults => !targetStoresToolResults tgt
  | .dropRecordedTime | .dropTimeProvenance => supports tgt .time == .absent
  | .dropSourceIdentity => supports tgt .identity == .absent
  | .dropEnvironment _ => !targetStoresEnvironment tgt
  | _ => false

/-- Central impact classification for CLI policy. Provenance impact depends on
typed entry disposition: generic vendor raw records are report-only, while
losing `historicalUnverified` can upgrade data to executable state.
`harnessVersion` is audit context; cwd/model/provider/instructions/session
identity can change continuation behavior. Source session/entry ID spelling is
report-only once the target has an explicit registration identity; topology,
active selection, and tool linkage remain independently checked obligations.
Recorded and non-recorded typed time are source facts. A target timestamp may
fulfil a target schema, but it does not preserve absent/interpolated/sequenced
provenance.

An obligation `obligationForcedByTargetLimits` answers `true` for is
`reportOnly` regardless of the rules below: the target has no slot, so no
exporter choice could have kept the fact, and `Interop.Emission.refused` does
not reach a merely lossy artifact. -/
def obligationImpactFor (tgt : Format) (t : Transcript) :
    Obligation -> ObligationImpact
  | .synthesizeEntryIds | .synthesizeTimestamps => .fulfillment
  | .dropSourceIdentity =>
      if hasExplicitTargetSessionIdentity tgt t ||
          obligationForcedByTargetLimits tgt .dropSourceIdentity then .reportOnly
      else .destructive
  | .dropOriginProvenance =>
      if hasUnpreservedSafetyProvenance tgt t then .destructive else .reportOnly
  | .dropTimeProvenance =>
      if obligationForcedByTargetLimits tgt .dropTimeProvenance then .reportOnly
      else .destructive
  | .dropEnvironment fields =>
      if obligationForcedByTargetLimits tgt (.dropEnvironment fields) then .reportOnly
      else if environmentLossIsDestructive fields then .destructive else .reportOnly
  | obligation =>
      if obligationForcedByTargetLimits tgt obligation then .reportOnly
      else .destructive

def obligationIsDestructiveFor
    (tgt : Format) (t : Transcript) (obligation : Obligation) : Bool :=
  obligationImpactFor tgt t obligation == .destructive

def obligationIsReportOnlyFor
    (tgt : Format) (t : Transcript) (obligation : Obligation) : Bool :=
  obligationImpactFor tgt t obligation == .reportOnly

private def hasEntryNeedingTargetId (t : Transcript) : Bool :=
  t.entries.toList.any (fun entry =>
    entry.origin.rawId.isNone || entry.origin.rawId == some "" ||
      match entry.payload with
      | .envMsg blocks => blocks.length > 1
      | _ => false)

private def cursorNativeToolIdMissing (entry : Entry) (blockIdx : Nat) : Bool :=
  if entry.origin.format != Format.cursorAgent then false
  else
    match entry.origin.extras >>= fun extras => jsonObject? extras "rawRecord" >>=
        fun record => jsonObject? record "message" >>= fun message =>
          jsonArray? message "content" >>= fun content => content[blockIdx]? with
    | some raw =>
        match raw.getObjVal? "id" with
        | .error _ | .ok .null => true
        | .ok _ => false
    | none => false

private def hasCursorCallNeedingTargetId (t : Transcript) : Bool :=
  let callIds := t.entries.toList.flatMap (fun entry =>
    match entry.payload with
    | .assistantMsg blocks => blocks.filterMap (fun
        | .toolCall _ _ rawId => rawId
        | _ => none)
    | _ => [])
  let sourceAlreadySynthesized := t.importNotes.any (fun note =>
    match note.kind with | .idSynthesized => true | _ => false)
  sourceAlreadySynthesized || hasDuplicateString callIds ||
    t.entries.toList.any (fun entry =>
      match entry.payload with
      | .assistantMsg blocks => blocks.zipIdx.any (fun (block, blockIdx) =>
          match block with
          | .toolCall _ _ none => true
          | .toolCall _ _ _ => cursorNativeToolIdMissing entry blockIdx
          | _ => false)
      | _ => false)

def needsSynthesizedEntryIds (tgt : Format) (t : Transcript) : Bool :=
  match tgt with
  | .pi => hasEntryNeedingTargetId t
  | .claudeCode => claudeEntryIdentityNeedsSynthesis t ||
      t.entries.toList.any (fun entry =>
        match entry.payload with | .envMsg blocks => blocks.length > 1 | _ => false)
  | .cursorAgent => hasCursorCallNeedingTargetId t
  | _ => false

def obligations (tgt : Format) (t : Transcript) : List Obligation := Id.run do
  let mut out : Array Obligation := #[]
  let nativeSurface := nativeRepresentationSurface tgt t
  if hasThinking nativeSurface then
    match supports tgt .thinkingContent with
    | .absent => out := out.push .dropThinking
    | _ => pure ()
  if hasSidechains t then
    match supports tgt .sidechains with
    | .absent => out := out.push .dropSidechains
    | _ => pure ()
  if (!t.entries.isEmpty && t.activeLeaf.isNone) ||
      (hasBranches t && !preservesParentAndActiveLeaf tgt) then
    out := out.push .linearizeBranches
  -- These checks describe shipped exporters, not only the format matrix. Pi
  -- has a native form, Claude has a typed carrier, and Codex accepts either an
  -- exact native checkpoint or a typed historical carrier. Cursor has no native
  -- compaction form.
  if hasCompaction nativeSurface then
    if tgt == Format.pi || tgt == Format.claudeCode || tgt == Format.openCode then
      pure ()
    else if tgt == Format.codexCli then
      if !codexTargetCompactionsValid t then out := out.push .dropCompaction
    else
      out := out.push .dropCompaction
  if hasEvents nativeSurface then
    if tgt = Format.pi || tgt = Format.claudeCode || tgt = Format.openCode then
      pure ()
    else if tgt = Format.codexCli then
      if hasCodexUnexportableEvents nativeSurface then out := out.push .dropEvents
    else if tgt = Format.cursorAgent then
      if hasCursorUnexportableEvents nativeSurface then out := out.push .dropEvents
    else
      out := out.push .dropEvents
  if tgt = Format.cursorAgent then
    if hasMedia nativeSurface then out := out.push .dropMedia
    if hasCursorUnexportableUnmodeled nativeSurface ||
        hasCursorUnexportableToolCalls nativeSurface then
      out := out.push .dropUnmodeled
    if hasEnvMessages nativeSurface then out := out.push .dropToolResults
    if hasOtherRoles nativeSurface then out := out.push .dropOtherRoles
  if tgt = Format.claudeCode then
    if nativeSurface.entries.toList.any (fun entry => match entry.payload with
        | .envMsg [] => true
        | _ => false) then out := out.push .dropToolResults
  if tgt = Format.codexCli then
    if hasCodexUnexportableMedia nativeSurface then out := out.push .dropMedia
    if hasCodexUnexportableUnmodeled nativeSurface ||
        hasCodexEmptyMessages nativeSurface then
      out := out.push .dropUnmodeled
    if nativeSurface.entries.toList.any (fun entry => match entry.payload with
        | .envMsg [] => true
        | _ => false) then out := out.push .dropToolResults
    if hasOtherRoles nativeSurface then out := out.push .dropOtherRoles
  for loss in metadataLosses tgt t do
    match loss with
    | .sourceIdentity => out := out.push .dropSourceIdentity
    | .environment fields => out := out.push (.dropEnvironment fields)
    | .originProvenance => out := out.push .dropOriginProvenance
    | .safetyProvenance =>
        if !out.contains .dropOriginProvenance then
          out := out.push .dropOriginProvenance
    | .toolCallIds => out := out.push .dropToolCallIds
    | .timeProvenance => out := out.push .dropTimeProvenance
  if needsSynthesizedEntryIds tgt t then
    out := out.push .synthesizeEntryIds
  if hasNonRecordedTime t && synthesizesTargetTimestamps tgt then
    out := out.push .synthesizeTimestamps
  if hasUnexportableTime tgt t then
    out := out.push .dropRecordedTime
  return out.toList

end Loom.Ops
