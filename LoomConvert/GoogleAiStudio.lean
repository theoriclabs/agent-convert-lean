import LoomConvert.Parity

/-!
# LoomConvert.GoogleAiStudio — the Google AI Studio importer (Loom port)

Ports `utils/src/pi/googleAiStudio.ts` (`importGoogleAiStudioToPiJsonl`, the
`convert-to-pi google-ai-studio` engine) into the Loom IR. **Importer only** —
no exporter (GAIS is a one-way ingest; there is no "export to AI Studio").

Source shape (see `Loom/Formats/GoogleAiStudio.lean`, censused 2026-07-06): a
single **export blob** (one JSON object), NOT JSONL. Top-level keys
`runSettings.{model,thinkingLevel}`, `systemInstruction`, and the conversation
under `chunkedPrompt.chunks[]`. Each chunk carries `role` (`user`/`model`),
`text`, `parts[].{text,thought}`, `isThought`, `tokenCount`.

## Mapping (TS-compatible base plus Loom enrichments)

* `runSettings.model` → a leading `Payload.event (MetaEvent.modelChange …)`
  only when the source records a non-empty model. A missing model remains
  `none`; no placeholder identity is fabricated. `runSettings.thinkingLevel`, normalized by
  stripping a leading `thinking[_-]?`, → `MetaEvent.thinkingLevelChange` — only
  when the normalized value is non-empty (matches the TS falsy check).
* `systemInstruction.text` (current exports) or legacy
  `systemInstruction.parts[].text` → `env.instructions`; the exact object
  remains session provenance and never becomes a user turn.
* role `user` → user text/media blocks; role `model` → assistant
  text/thinking/media/tool-call blocks. Mixed visible and thought parts retain
  every part in source order and preserve each thought signature.
* `functionCall`/`functionResponse` parts become positionally linked tool
  calls/results. Result errors are native when `isError` exists, inferred with
  a named heuristic when `response.error` exists, and otherwise unrecorded.
* Empty recognized chunks, unknown parts, and unknown roles are preserved as
  exact unmodeled blocks/events. Unknown roles never become user turns.
* Every chunk and the complete export object remain exact in `Origin.extras`,
  retaining usage, finish, branch, configuration, and additive fields even
  when the IR has no first-class slot.

## Structural choices

* **Linear thread** — `chunkedPrompt.chunks[]` is array-ordered with no native
  parent pointers read; parent of entry *i* is *i-1* (matches the TS `parentId`
  chain). WellFormed by construction (parent strictly earlier).
* **Time** — exactly representable UTC `createTime` values become
  `Time.recorded`. Missing or higher-precision values use `Time.sequenced`;
  the exact source spelling remains provenance and the fallback is logged.
* **cwd** — the blob has none; the TS injects `opts.cwd` (`process.cwd()`).
  We leave `env.cwd := none` (never fabricate); a same-format re-emit that
  needs a cwd supplies it out of band.

## Newly modeled — the richest dropped set (S5+S6; spec claim L19)

The census (`Loom/Formats/GoogleAiStudio.lean`) found the export is far richer
than the original TS adapter read. This port now RECOVERS three of the dropped
sets. Two remain **Lean-only** enrichments (thought signatures and media refs);
`src/pi/googleAiStudio.ts` now also preserves `errorMessage` chunks as pi event
entries. Loom's `normalize` here is still deliberately *richer* than the TS
golden for signatures/media — **no cross-parity pin covers this content** (a
pin would fail). It is verified by `gaisRichFixture`'s local checks instead.

* `thoughtSignature` on reasoning parts → `AssistantBlock.thinking … (some sig)`
  (the IR has the signature slot; mirrors how pi/claude preserve it, claim L12).
  Each part keeps its own signature and position.
* `driveDocument`/`driveImage`/`driveAudio`/`inlineFile` attachment chunks →
  a `.media` block (`AssistantBlock.media` for role `model`, `UserBlock.media`
  otherwise). mimeType comes from nested `mimeType` or a kind default. When no
  stable locator exists, the exact attachment object remains `.unmodeled`
  instead of inventing a path (the inline base64 payload is never a locator).
  ~120/file were previously counted as `skippedChunks`.
* per-chunk `errorMessage` → `Payload.event (MetaEvent.custom "error" chunk)`
  (the whole chunk verbatim). The TS importer now emits the same source fact as
  a `google-ai-studio:error` pi event; 7 such chunks were seen across the 4 real
  blobs.

## Still dropped (future work)

`branchParent`/`branchChildren` (best-of-N branching) are still linearized
by array order and logged; `finishReason` has no first-class IR home. Both
remain exact in chunk provenance.
-/

namespace LoomConvert
open Loom
open Lean (Json)

/-! ## Small Json accessors (Pi.lean's scaffold — those are `private`, so re-declared) -/

private def ostr (j : Json) (k : String) : Option String :=
  (j.getObjVal? k >>= Json.getStr?).toOption

private def oobj (j : Json) (k : String) : Option Json :=
  (j.getObjVal? k).toOption

private def hasField (j : Json) (k : String) : Bool :=
  match j.getObjVal? k with
  | .ok _ => true
  | .error _ => false

private def gSchemaError (ctx detail : String) : Except String α :=
  .error s!"malformed Google AI Studio {ctx}: {detail}"

private def gEnsureObject (ctx : String) : Json → Except String Unit
  | .obj _ => pure ()
  | _ => gSchemaError ctx "expected an object"

private def gRequireField (ctx : String) (j : Json) (key : String) : Except String Json := do
  gEnsureObject ctx j
  match j.getObjVal? key with
  | .ok value => pure value
  | .error _ => gSchemaError ctx s!"missing required field '{key}'"

private def gRequireString (ctx : String) (j : Json) (key : String) : Except String String := do
  match ← gRequireField ctx j key with
  | .str value => pure value
  | _ => gSchemaError ctx s!"field '{key}' must be a string"

private def gRequireNonemptyString
    (ctx : String) (j : Json) (key : String) : Except String String := do
  let value ← gRequireString ctx j key
  if value.isEmpty then gSchemaError ctx s!"field '{key}' must not be empty"
  else pure value

private def gOptionalString
    (ctx : String) (j : Json) (key : String) : Except String (Option String) := do
  gEnsureObject ctx j
  match j.getObjVal? key with
  | .error _ | .ok .null => pure none
  | .ok (.str value) => pure (some value)
  | .ok _ => gSchemaError ctx s!"field '{key}' must be a string or null when present"

private def gOptionalNonemptyString
    (ctx : String) (j : Json) (key : String) : Except String (Option String) := do
  match ← gOptionalString ctx j key with
  | none => pure none
  | some value =>
      if value.isEmpty then gSchemaError ctx s!"field '{key}' must not be empty"
      else pure (some value)

private def gOptionalBool
    (ctx : String) (j : Json) (key : String) : Except String (Option Bool) := do
  gEnsureObject ctx j
  match j.getObjVal? key with
  | .error _ | .ok .null => pure none
  | .ok (.bool value) => pure (some value)
  | .ok _ => gSchemaError ctx s!"field '{key}' must be a boolean or null when present"

private def gOptionalArray
    (ctx : String) (j : Json) (key : String) : Except String (Option (Array Json)) := do
  gEnsureObject ctx j
  match j.getObjVal? key with
  | .error _ | .ok .null => pure none
  | .ok (.arr values) => pure (some values)
  | .ok _ => gSchemaError ctx s!"field '{key}' must be an array or null when present"

private def gRequireArray
    (ctx : String) (j : Json) (key : String) : Except String (Array Json) := do
  match ← gRequireField ctx j key with
  | .arr values => pure values
  | _ => gSchemaError ctx s!"field '{key}' must be an array"

private def gOptionalObject
    (ctx : String) (j : Json) (key : String) : Except String (Option Json) := do
  gEnsureObject ctx j
  match j.getObjVal? key with
  | .error _ | .ok .null => pure none
  | .ok value@(.obj _) => pure (some value)
  | .ok _ => gSchemaError ctx s!"field '{key}' must be an object or null when present"

/-- Strip a leading `thinking` optionally followed by one `_`/`-`, lowercased —
`normalizeThinkingLevel` (TS regex `^thinking[_-]?`). Returns `""` for a bare
`"thinking"`, which the caller treats as absent. -/
private def normalizeThinkingLevel (level : String) : String :=
  let lower := level.toLower
  if lower.startsWith "thinking_" || lower.startsWith "thinking-" then
    (lower.toRawSubstring.drop 9).toString
  else if lower.startsWith "thinking" then
    (lower.toRawSubstring.drop 8).toString
  else lower

/-! ## Chunk → IR -/

/-! ### Recovery of dropped chunk kinds (S5+S6; TS drops all of this — L19) -/

/-- Candidate locator fields on an attachment object, most specific first.
The inline `data` (base64 payload) is deliberately excluded — a locator is a
*ref*, not the bytes. -/
private def attRefKeys : List String :=
  ["id", "fileId", "driveId", "documentId", "fileUri", "uri", "url", "name", "fileName"]

/-- Default mimeType per attachment kind, used only when the attachment object
carries no explicit `mimeType`. -/
private def attachmentKindMime : String → String
  | "driveImage"    => "image/*"
  | "driveAudio"    => "audio/*"
  | "driveDocument" => "application/vnd.google-apps.document"
  | "inlineFile"    => "application/octet-stream"
  | _               => "application/octet-stream"

/-- First present string value among `keys`, in order. -/
private def firstStr (j : Json) (keys : List String) : Option String :=
  keys.findSome? (fun (k : String) => ostr j k)

/-- One entry-to-be: the payload plus provenance. Parent is assigned
positionally afterwards (linear thread: parent = previous emitted index). -/
private structure GaisResult where
  rawId   : Option String
  name    : String
  content : List UserBlock
  error   : ErrorSignal

private inductive GaisAtom where
  | user (block : UserBlock)
  | assistant (block : AssistantBlock)
  | result (value : GaisResult)

private inductive GaisDraft where
  | payload (value : Payload)
  | result (value : GaisResult)

private structure Emit where
  draft     : GaisDraft
  sourceRef : String
  raw       : Json
  time      : Option Time := none

private def gNote (label loc detail : String) : ImportNote :=
  { kind := .other label, loc := some loc, detail }

/-- Preserve source part order while coalescing adjacent blocks by authorship.
Function responses become environment entries, never user turns. -/
private def atomsToDrafts (atoms : List GaisAtom) : List GaisDraft := Id.run do
  let mut drafts : List GaisDraft := []
  let mut users : List UserBlock := []
  let mut assistants : List AssistantBlock := []
  for atom in atoms do
    match atom with
    | .user block =>
        if !assistants.isEmpty then
          drafts := drafts ++ [.payload (.assistantMsg assistants)]
          assistants := []
        else pure ()
        users := users ++ [block]
    | .assistant block =>
        if !users.isEmpty then
          drafts := drafts ++ [.payload (.userMsg users)]
          users := []
        else pure ()
        assistants := assistants ++ [block]
    | .result value =>
        if !users.isEmpty then
          drafts := drafts ++ [.payload (.userMsg users)]
          users := []
        else pure ()
        if !assistants.isEmpty then
          drafts := drafts ++ [.payload (.assistantMsg assistants)]
          assistants := []
        else pure ()
        drafts := drafts ++ [.result value]
  if !users.isEmpty then drafts := drafts ++ [.payload (.userMsg users)]
  else pure ()
  if !assistants.isEmpty then
    drafts := drafts ++ [.payload (.assistantMsg assistants)]
  else pure ()
  return drafts

private def gaisAliasedId
    (ctx : String) (j : Json) : Except String (Option String) := do
  let id ← gOptionalNonemptyString ctx j "id"
  let callId ← gOptionalNonemptyString ctx j "callId"
  if id.isSome && callId.isSome && id != callId then
    gSchemaError ctx "fields 'id' and 'callId' disagree"
  else pure (id <|> callId)

private def responseErrorSignal (ctx : String) (response : Json)
    (functionResponse : Json) : Except String (ErrorSignal × List ImportNote) := do
  match ← gOptionalBool ctx functionResponse "isError" with
  | some value => pure (.native value, [])
  | none =>
      if hasField response "error" then
        pure (.inferred true "google-ai-studio:functionResponse.response.error-present",
          [{ kind := .errorInferred, loc := some (ctx ++ ".response.error"),
             detail := "function response error inferred from presence of response.error" }])
      else
        pure (.unrecorded,
          [gNote "gais-error-unrecorded" ctx
            "functionResponse carries no explicit isError field; status remains unrecorded"])

/-- Parse one Google content part without collapsing thought/text or lifecycle
variants. Unknown parts stay role-indexed unmodeled blocks with exact JSON. -/
private def parsePart (role : String) (chunkThought : Bool)
    (ctx : String) (part : Json) : Except String (List GaisAtom × List ImportNote) := do
  gEnsureObject ctx part
  let functionCall ← gOptionalObject ctx part "functionCall"
  let functionResponse ← gOptionalObject ctx part "functionResponse"
  if functionCall.isSome && functionResponse.isSome then
    gSchemaError ctx "a part cannot contain both functionCall and functionResponse"
  else pure ()
  if (functionCall.isSome || functionResponse.isSome) && hasField part "text" then
    gSchemaError ctx "a lifecycle part cannot also contain text"
  else pure ()
  match functionCall, functionResponse with
  | some call, none =>
      if role != "model" then
        gSchemaError ctx "functionCall is only valid in a model chunk"
      else pure ()
      let callCtx := ctx ++ ".functionCall"
      let name ← gRequireNonemptyString callCtx call "name"
      let args ← match ← gRequireField callCtx call "args" with
        | value@(.obj _) => pure value
        | _ => gSchemaError callCtx "field 'args' must be an object"
      let rawId ← gaisAliasedId callCtx call
      let notes := if rawId.isNone then
          [gNote "gais-missing-tool-id" callCtx
            "functionCall has no id/callId; retained for name-and-occurrence linkage"]
        else []
      pure ([.assistant (.toolCall { raw := name } args rawId)], notes)
  | none, some responseEnvelope =>
      if role != "user" then
        gSchemaError ctx "functionResponse is only valid in a user chunk"
      else pure ()
      let responseCtx := ctx ++ ".functionResponse"
      let name ← gRequireNonemptyString responseCtx responseEnvelope "name"
      let response ← gRequireField responseCtx responseEnvelope "response"
      let rawId ← gaisAliasedId responseCtx responseEnvelope
      let (error, notes) ← responseErrorSignal responseCtx response responseEnvelope
      let content := match response with
        | .str text => [UserBlock.text text]
        | raw => [UserBlock.unmodeled "google-ai-studio-function-response" raw]
      pure ([.result { rawId, name, content, error }], notes)
  | none, none =>
      let text ← gOptionalString ctx part "text"
      let thought ← gOptionalBool ctx part "thought"
      let signature ← gOptionalNonemptyString ctx part "thoughtSignature"
      match text with
      | some value =>
          if role == "user" then
            if chunkThought || thought.getD false || signature.isSome then
              gSchemaError ctx "thought text/signature is not valid in a user chunk"
            else pure ([.user (.text value)], [])
          else
            let isThinking := chunkThought || thought.getD false || signature.isSome
            if isThinking then pure ([.assistant (.thinking value signature)], [])
            else pure ([.assistant (.text value)], [])
      | none =>
          let label := if role == "user" then "google-ai-studio-user-part"
            else "google-ai-studio-model-part"
          let atom := if role == "user" then
              GaisAtom.user (.unmodeled label part)
            else GaisAtom.assistant (.unmodeled label part)
          pure ([atom],
            [gNote "gais-unmodeled-part" ctx
              "preserved unknown Google AI Studio part verbatim"])
  | _, _ => gSchemaError ctx "invalid part discriminator state"

private def attachmentAtoms (role src : String) (chunk : Json) :
    Except String (List GaisAtom × List ImportNote) := do
  let mut atoms : List GaisAtom := []
  let mut notes : List ImportNote := []
  for kind in (["driveImage", "driveAudio", "driveDocument", "inlineFile"] : List String) do
    match ← gOptionalObject src chunk kind with
    | none => pure ()
    | some attachment =>
        let mimeSource ← gOptionalNonemptyString (src ++ "." ++ kind)
          attachment "mimeType"
        let mime := mimeSource.getD (attachmentKindMime kind)
        if mimeSource.isNone then
          notes := notes ++ [gNote "gais-attachment-mime-inferred"
            (src ++ "." ++ kind ++ ".mimeType")
            s!"mimeType absent; used format default '{attachmentKindMime kind}'"]
        else pure ()
        match firstStr attachment attRefKeys with
        | some locator =>
            if role == "user" then
              atoms := atoms ++ [.user (.media mime locator)]
            else
              atoms := atoms ++ [.assistant (.media mime locator)]
        | none =>
            let label := "google-ai-studio-" ++ kind
            if role == "user" then
              atoms := atoms ++ [.user (.unmodeled label attachment)]
            else
              atoms := atoms ++ [.assistant (.unmodeled label attachment)]
            notes := notes ++ [gNote "gais-attachment-without-locator"
              (src ++ "." ++ kind)
              "attachment has no stable locator; preserved exact object instead of fabricating one"]
  pure (atoms, notes)

private def chunkTimeAndNotes (src : String) (chunk : Json) :
    Except String (Option Time × List ImportNote) := do
  match ← gOptionalString src chunk "createTime" with
  | none => pure (none, [])
  | some value =>
      match iso8601ToEpochMs? value with
      | some stamp => pure (some (.recorded stamp), [])
      | none => pure (none,
          [gNote "gais-source-time-unparsed" (src ++ ".createTime")
            "createTime spelling/precision is not exactly representable; raw value retained and order sequenced"])

/-- Parse a chunk to one or more author-correct drafts. Unknown roles and empty
recognized chunks become exact custom events instead of disappearing. -/
private def parseChunk (idx : Nat) (chunk : Json) :
    Except String (List Emit × List ImportNote) := do
  let src := s!"chunkedPrompt.chunks[{idx}]"
  gEnsureObject src chunk
  let role ← gRequireNonemptyString src chunk "role"
  let (sourceTime, timeNotes) ← chunkTimeAndNotes src chunk
  if role != "user" && role != "model" then
    pure ([
      { draft := .payload (.event (.custom
          "google-ai-studio-unmodeled-chunk" chunk)),
        sourceRef := src,
        raw := chunk,
        time := sourceTime }],
      timeNotes ++ [gNote "gais-unmodeled-role" (src ++ ".role")
        s!"preserved unknown chunk role '{role}' as a non-conversation event"])
  else
    let chunkThought := (← gOptionalBool src chunk "isThought").getD false
    if role == "user" && chunkThought then
      gSchemaError src "isThought=true is not valid for role 'user'"
    else pure ()
    let parts := (← gOptionalArray src chunk "parts").getD #[]
    let chunkText ← gOptionalString src chunk "text"
    let mut atoms : List GaisAtom := []
    let mut notes : List ImportNote := timeNotes
    if parts.isEmpty then
      match chunkText with
      | some value =>
          if role == "user" then atoms := [.user (.text value)]
          else if chunkThought then
            atoms := [.assistant (.thinking value none)]
          else atoms := [.assistant (.text value)]
      | none => pure ()
    else
      for (part, partIdx) in parts.toList.zipIdx do
        let (partAtoms, partNotes) ← parsePart role chunkThought
          s!"{src}.parts[{partIdx}]" part
        atoms := atoms ++ partAtoms
        notes := notes ++ partNotes
      -- Real AI Studio exports record `text` alongside `parts`. It is normally
      -- the exact concatenation of part text and must not be emitted twice. A
      -- disagreement is retained as inert role-authored data instead of being
      -- silently discarded or replayed as ordinary conversation text.
      match chunkText with
      | none => pure ()
      | some text =>
          let projected := String.join
            (parts.toList.filterMap (fun part => ostr part "text"))
          if text != projected then
            let shadow := Json.mkObj [
              ("text", Json.str text),
              ("partsText", Json.str projected)]
            if role == "user" then
              atoms := atoms ++ [.user (.unmodeled
                "google-ai-studio-chunk-text-shadow" shadow)]
            else
              atoms := atoms ++ [.assistant (.unmodeled
                "google-ai-studio-chunk-text-shadow" shadow)]
            notes := notes ++ [gNote "gais-chunk-text-shadow" (src ++ ".text")
              "chunk text differs from the ordered part-text projection; retained as inert unmodeled data"]
          else pure ()
    let (mediaAtoms, mediaNotes) ← attachmentAtoms role src chunk
    atoms := atoms ++ mediaAtoms
    notes := notes ++ mediaNotes
    let errorMessage ← gOptionalString src chunk "errorMessage"
    let errorDrafts := match errorMessage with
      | some _ => [GaisDraft.payload (.event (.custom "error" chunk))]
      | none => []
    let drafts := errorDrafts ++ atomsToDrafts atoms
    let drafts := if drafts.isEmpty then
        [GaisDraft.payload (.event (.custom
          "google-ai-studio-unmodeled-chunk" chunk))]
      else drafts
    if errorDrafts.isEmpty && atoms.isEmpty then
      notes := notes ++ [gNote "gais-empty-or-unmodeled-chunk" src
        "recognized-role chunk had no modeled payload; preserved exact chunk as event"]
    else pure ()
    if hasField chunk "branchParent" || hasField chunk "branchChildren" then
      notes := notes ++ [gNote "gais-branch-linearized" src
        "native branch metadata retained verbatim; entry order is linearized because branch semantics are not yet modeled"]
    else pure ()
    pure (drafts.map (fun draft =>
      { draft, sourceRef := src, raw := chunk, time := sourceTime }), notes)

private structure GaisCallOccurrence where
  rawId : Option String
  name   : String
  entry  : Nat
  block  : Nat

private def callMatchesResult
    (call : GaisCallOccurrence) (result : GaisResult) : Bool :=
  match result.rawId with
  | some id => call.rawId == some id && call.name == result.name
  | none => call.name == result.name

private def materialize (emits : List Emit) :
    Except String (Array Entry × List ImportNote) := do
  let mut entries : Array Entry := #[]
  let mut calls : List GaisCallOccurrence := []
  let mut resolvedCallSites : List (Nat × Nat) := []
  let mut notes : List ImportNote := []
  for emit in emits do
    let entryIdx := entries.size
    let parent := if entryIdx == 0 then none else some (entryIdx - 1)
    let origin : Origin := {
      format := .googleAiStudio,
      sourceRef := emit.sourceRef,
      extras := some (Json.mkObj [("googleAiStudioRaw", emit.raw)]) }
    let time := emit.time.getD (.sequenced entryIdx)
    match emit.draft with
    | .payload payload =>
        match payload with
        | .assistantMsg blocks =>
            for (block, blockIdx) in blocks.zipIdx do
              match block with
              | .toolCall name _ rawId =>
                  calls := calls ++ [
                    { rawId,
                      name := name.raw,
                      entry := entryIdx,
                      block := blockIdx }]
              | _ => pure ()
        | _ => pure ()
        entries := entries.push { parent, thread := 0, time, payload, origin }
    | .result result =>
        let idCandidates : List GaisCallOccurrence := match result.rawId with
          | some id => calls.filter (fun call => call.rawId == some id)
          | none => []
        let candidates := if result.rawId.isSome then
            calls.filter (fun call => callMatchesResult call result)
          else []
        if result.rawId.isSome && !idCandidates.isEmpty && candidates.isEmpty then
          gSchemaError emit.sourceRef
            s!"functionResponse id matches an earlier call but name '{result.name}' does not"
        else pure ()
        let unmatched := candidates.filter (fun call =>
          !resolvedCallSites.contains (call.entry, call.block))
        let candidate := if candidates.length == 1 then candidates.head?
          else if unmatched.length == 1 then unmatched.head? else none
        let callRef := match candidate with
          | some call => CallRef.resolved call.entry call.block
          | none => CallRef.unresolved result.rawId
              (if result.rawId.isNone then
                "Google AI Studio functionResponse has no id/callId; name/order alone cannot prove linkage"
              else if unmatched.length > 1 then
                "multiple unmatched Google AI Studio functionCall occurrences share this id/name"
              else if !candidates.isEmpty then
                "every matching Google AI Studio functionCall occurrence already has a response"
              else
                s!"no prior Google AI Studio functionCall occurrence matches '{result.name}'")
        if let some call := candidate then
          resolvedCallSites := resolvedCallSites ++ [(call.entry, call.block)]
        else
          notes := notes ++ [gNote "gais-unresolved-tool-result" emit.sourceRef
            "preserved functionResponse with no matching prior functionCall occurrence"]
        if unmatched.length > 1 then
          notes := notes ++ [gNote "gais-ambiguous-tool-result" emit.sourceRef
            "duplicate function call id/name is ambiguous; response retained unresolved"]
        else pure ()
        if candidate.isNone && !candidates.isEmpty && unmatched.isEmpty then
          notes := notes ++ [gNote "gais-duplicate-tool-result" emit.sourceRef
            "all matching calls already have responses; additional response retained unresolved"]
        else pure ()
        let payload := Payload.envMsg [
          EnvBlock.toolResult callRef result.content result.error]
        entries := entries.push { parent, thread := 0, time, payload, origin }
  pure (entries, notes)

private def parseSystemInstructionParts (parts : Array Json) :
    Except String String := do
  let texts ← parts.toList.zipIdx.mapM (fun (part, idx) => do
    let ctx := s!"systemInstruction.parts[{idx}]"
    gEnsureObject ctx part
    gRequireString ctx part "text")
  pure (String.join texts)

private def parseSystemInstruction (root : Json) :
    Except String (Option String) := do
  match ← gOptionalObject "export" root "systemInstruction" with
  | none => pure none
  | some instruction =>
      let direct ← gOptionalString "systemInstruction" instruction "text"
      let parts ← gOptionalArray "systemInstruction" instruction "parts"
      match direct, parts with
      | none, none => pure none
      | some text, none => pure (some text)
      | none, some values => pure (some (← parseSystemInstructionParts values))
      | some text, some values =>
          let joined ← parseSystemInstructionParts values
          if text == joined then pure (some text)
          else
            gSchemaError "systemInstruction"
              "fields 'text' and 'parts' disagree"

/-! ## The importer -/

/-- Google AI Studio export JSON → Loom IR. Parses the whole input as ONE JSON
object and walks `chunkedPrompt.chunks[]`. Meta events (from `runSettings`)
lead, then one entry per non-skipped chunk, linked in a linear parent chain. -/
def importGoogleAiStudio (text : String) : Except String Transcript := do
  let root ← Json.parse text
  gEnsureObject "export" root
  let chunkedPrompt ← match ← gRequireField "export" root "chunkedPrompt" with
    | value@(.obj _) => pure value
    | _ => gSchemaError "export" "field 'chunkedPrompt' must be an object"
  let chunks ← gRequireArray "chunkedPrompt" chunkedPrompt "chunks"
  let runSettings := (← gOptionalObject "export" root "runSettings").getD (Json.mkObj [])
  let provider := "google-ai-studio"
  let modelId ← gOptionalNonemptyString "runSettings" runSettings "model"
  let instructions ← parseSystemInstruction root
  let modelEmit? : Option Emit := modelId.map (fun model =>
    { draft := .payload (.event (.modelChange none (some model))),
      sourceRef := "runSettings.model", raw := runSettings })
  let thinkingSetting ← gOptionalNonemptyString "runSettings" runSettings "thinkingLevel"
  let thinkEmit? ←
    match thinkingSetting with
    | none => pure none
    | some raw =>
        let lvl := normalizeThinkingLevel raw
        if lvl.isEmpty then
          gSchemaError "runSettings" "field 'thinkingLevel' has no level after normalization"
        else pure (some {
          draft := .payload (.event (.thinkingLevelChange none (some lvl))),
          sourceRef := "runSettings.thinkingLevel", raw := runSettings })
  let metaEmits : List Emit :=
    modelEmit?.toList ++ thinkEmit?.toList
  let noteTime : ImportNote :=
    { kind := .timeSequenced,
      detail := "GAIS entries without an exactly representable createTime use monotonic Time.sequenced order." }
  let parsedChunks ← chunks.toList.zipIdx.mapM (fun (chunk, idx) =>
    parseChunk idx chunk)
  let chunkEmits := parsedChunks.flatMap (fun parsed => parsed.1)
  let chunkNotes := parsedChunks.flatMap (fun parsed => parsed.2)
  let allEmits := metaEmits ++ chunkEmits
  let (entries, lifecycleNotes) ← materialize allEmits
  let modelNotes := if modelId.isNone then
      [gNote "gais-model-absent" "runSettings.model"
        "source records no model; importer did not fabricate one"]
    else []
  pure {
    threads := #[{ kind := ThreadKind.main }],
    entries,
    env := {
      cwd := none,
      model := modelId,
      provider := some provider,
      instructions },
    activeLeaf := if entries.isEmpty then none else some (entries.size - 1),
    importNotes := noteTime :: (modelNotes ++ chunkNotes ++ lifecycleNotes),
    origin := {
      format := Format.googleAiStudio,
      sourceRef := "importGoogleAiStudio",
      rawId := none,
      extras := some (Json.mkObj [("googleAiStudioRaw", root)]) }
  }

/-! ## Actuator: the only IO. -/

/-- Read a Google AI Studio export file from disk into the IR. -/
def importGoogleAiStudioFile (path : System.FilePath) : IO (Except String Transcript) := do
  let text ← IO.FS.readFile path
  pure (importGoogleAiStudio text)

/-! ## Structure-only fixture (synthesized; no real content)

A minimal cross-parity export: one user chunk, one model thought chunk (two
`thought:true` parts → thinking blocks), and one model answer chunk. The
separate adversarial witnesses below cover mixed thought/visible chunks because
the legacy TS projection intentionally cannot represent that richer result.
`runSettings` drives both meta events. -/
def gaisFixture : String :=
  "{\"runSettings\":{\"model\":\"gemini-2.5-pro\",\"thinkingLevel\":\"thinking_high\"}," ++
  "\"systemInstruction\":{\"parts\":[{\"text\":\"You are helpful.\"}]}," ++
  "\"chunkedPrompt\":{\"chunks\":[" ++
    "{\"role\":\"user\",\"text\":\"What is 2+2?\"}," ++
    "{\"role\":\"model\",\"isThought\":true,\"parts\":[" ++
      "{\"text\":\"Consider the sum.(scratch)\",\"thought\":true}]}," ++
    "{\"role\":\"model\",\"tokenCount\":12,\"parts\":[" ++
      "{\"text\":\"The answer is 4.\"}]}" ++
  "]}}"

-- Well-formed IR, entries emitted, zero structural violations.
example :
    (match importGoogleAiStudio gaisFixture with
     | .ok t => t.entries.size == 5 && (Loom.violations t).isEmpty
     | .error _ => false) = true := by native_decide

/-- Cross-parity golden: TS `convert-to-pi google-ai-studio` → pi JSONL →
parseSession → `normalize`, captured 2026-07-07. -/
def gaisCase1 : CrossParityCase := {
  name := "google-ai-studio",
  input := gaisFixture,
  tsGolden := "session\n0|-|event|\n1|0|event|\n2|1|user|text:What is 2+2?\n3|2|assistant|think:Consider the sum.(scratch)\n4|3|assistant|text:The answer is 4."
}

/-- THE DECIDE-PIN (cross-parity, RC1): importGoogleAiStudio agrees with TS
`convert-to-pi google-ai-studio`. -/
example : crossParityOkWith importGoogleAiStudio gaisCase1 = true := by native_decide

/-! ## Rich fixture — the S5+S6 recovery (thoughtSignature + attachment + errorMessage)

Exercises the three newly-modeled rich sets: a **signed** thought part
(`thoughtSignature`), a `driveImage` **attachment** chunk, and an `errorMessage`
chunk. TS now preserves the error chunk as a pi event but still drops signatures
and media refs, so — unlike `gaisCase1` — there is deliberately **no cross-parity
pin** here: a pin would fail because Loom is strictly richer. The divergence is
verified by local compile-time checks only. -/

/-- First preserved reasoning signature in the transcript. -/
private def findSignature (t : Transcript) : Option String :=
  t.entries.toList.findSome? (fun (e : Entry) => match e.payload with
    | .assistantMsg blocks => blocks.findSome? (fun (b : AssistantBlock) => match b with
        | AssistantBlock.thinking _ (some sig) => some sig
        | _ => none)
    | _ => none)

/-- First recovered `.media` attachment (mimeType, locator), user- or
assistant-authored. -/
private def findMedia (t : Transcript) : Option (String × String) :=
  t.entries.toList.findSome? (fun (e : Entry) => match e.payload with
    | .userMsg blocks => blocks.findSome? (fun (b : UserBlock) => match b with
        | UserBlock.media m loc => some (m, loc)
        | _ => none)
    | .assistantMsg blocks => blocks.findSome? (fun (b : AssistantBlock) => match b with
        | AssistantBlock.media m loc => some (m, loc)
        | _ => none)
    | _ => none)

/-- First recovered per-chunk `errorMessage`, pulled from the custom error event. -/
private def findError (t : Transcript) : Option String :=
  t.entries.toList.findSome? (fun (e : Entry) => match e.payload with
    | .event (MetaEvent.custom "error" raw) => ostr raw "errorMessage"
    | _ => none)

def gaisRichFixture : String :=
  "{\"runSettings\":{\"model\":\"gemini-2.5-pro\",\"thinkingLevel\":\"thinking_high\"}," ++
  "\"chunkedPrompt\":{\"chunks\":[" ++
    "{\"role\":\"user\",\"text\":\"Analyze the attached image.\"}," ++
    "{\"role\":\"model\",\"isThought\":true,\"parts\":[" ++
      "{\"text\":\"Deliberating carefully.\",\"thought\":true,\"thoughtSignature\":\"SIG-ABC123\"}]}," ++
    "{\"role\":\"user\",\"driveImage\":{\"id\":\"drv-img-1\",\"mimeType\":\"image/png\"}}," ++
    "{\"role\":\"model\",\"errorMessage\":\"RESOURCE_EXHAUSTED: quota exceeded\"}," ++
    "{\"role\":\"model\",\"tokenCount\":7,\"parts\":[{\"text\":\"Here is the analysis.\"}]}" ++
  "]}}"

-- Well-formed, all three previously-dropped sets recovered.
example :
    (match importGoogleAiStudio gaisRichFixture with
     | .ok t =>
         t.entries.size == 7
         && (Loom.violations t).isEmpty
         && findSignature t == some "SIG-ABC123"
         && (match findMedia t with
             | some ("image/png", "drv-img-1") => true
             | _ => false)
         && findError t == some "RESOURCE_EXHAUSTED: quota exceeded"
     | .error _ => false) = true := by native_decide

/-! ## Adversarial importer witnesses -/

private def gaisRejects (source : String) : Bool :=
  match importGoogleAiStudio source with
  | .error _ => true
  | .ok _ => false

private def gaisConfigurationFixture : String :=
  "{\"runSettings\":{\"thinkingLevel\":\"thinking_low\",\"future\":7}," ++
  "\"systemInstruction\":{\"parts\":[{\"text\":\"policy A\"},{\"text\":\" + B\"}]," ++
    "\"futureInstruction\":true}," ++
  "\"futureRoot\":{\"exact\":[1,2]},\"chunkedPrompt\":{\"chunks\":[" ++
    "{\"role\":\"user\",\"text\":\"hello\",\"futureChunk\":{\"k\":9}}" ++
  "]}}"

private def gaisConfigurationIsHonestAndExact : Bool :=
  match importGoogleAiStudio gaisConfigurationFixture,
      Json.parse gaisConfigurationFixture with
  | .ok t, .ok source =>
      t.env.model.isNone &&
      t.env.harnessVersion.isNone &&
      t.env.instructions == some "policy A + B" &&
      t.activeLeaf == some (t.entries.size - 1) &&
      !t.entries.toList.any (fun entry => match entry.payload with
        | .event (.modelChange _ _) => true
        | _ => false) &&
      t.origin.extras.bind (fun extras =>
        oobj extras "googleAiStudioRaw") == some source &&
      match t.entries.toList.getLast? with
      | some entry =>
          entry.origin.extras.bind (fun extras =>
            oobj extras "googleAiStudioRaw") ==
              (source.getObjVal? "chunkedPrompt").toOption.bind (fun prompt =>
                (prompt.getObjVal? "chunks").toOption.bind (fun rawChunks =>
                  (Json.getArr? rawChunks).toOption.bind (fun values => values[0]?)))
      | none => false
  | _, _ => false

example : gaisConfigurationIsHonestAndExact = true := by native_decide

private def gaisUnknownRoleAttachmentFixture : String :=
  "{\"chunkedPrompt\":{\"chunks\":[{" ++
    "\"role\":\"future-control\",\"text\":\"must not be user\"," ++
    "\"driveImage\":{\"id\":\"img-1\"}}]}}"

example :
    (match importGoogleAiStudio gaisUnknownRoleAttachmentFixture with
     | .ok t =>
         match t.entries.toList with
         | [{ payload := .event (.custom
                "google-ai-studio-unmodeled-chunk" raw), .. }] =>
             ostr raw "role" == some "future-control" &&
             !t.entries.toList.any (fun entry => match entry.payload with
               | .userMsg _ | .assistantMsg _ => true
               | _ => false) &&
             t.importNotes.any (fun note =>
               note.kind == .other "gais-unmodeled-role")
         | _ => false
     | .error _ => false) = true := by native_decide

private def gaisMixedPartsFixture : String :=
  "{\"runSettings\":{\"model\":\"gemini-mixed\"}," ++
  "\"chunkedPrompt\":{\"chunks\":[{\"role\":\"model\",\"parts\":[" ++
    "{\"text\":\"visible-1\"}," ++
    "{\"text\":\"private-thought\",\"thought\":true,\"thoughtSignature\":\"sig\"}," ++
    "{\"text\":\"visible-2\"}" ++
  "]}]}}"

example :
    (match importGoogleAiStudio gaisMixedPartsFixture with
     | .ok t =>
         match t.entries.toList with
         | [{ payload := .event (.modelChange _ (some "gemini-mixed")), .. },
            { payload := .assistantMsg [
                .text "visible-1",
                .thinking "private-thought" (some "sig"),
                .text "visible-2"], .. }] => true
         | _ => false
     | .error _ => false) = true := by native_decide

private def gaisCurrentWireShapeFixture : String :=
  "{\"systemInstruction\":{\"text\":\"policy\"}," ++
  "\"chunkedPrompt\":{\"chunks\":[{\"role\":\"model\"," ++
    "\"text\":\"visible\",\"parts\":[{\"text\":\"visible\"}]}]}}"

example :
    (match importGoogleAiStudio gaisCurrentWireShapeFixture with
     | .ok t =>
         t.env.instructions == some "policy" &&
         match t.entries.toList with
         | [{ payload := .assistantMsg [.text "visible"], .. }] =>
             !t.importNotes.any (fun note =>
               note.kind == .other "gais-chunk-text-shadow")
         | _ => false
     | .error _ => false) = true := by native_decide

private def gaisDivergentChunkTextFixture : String :=
  "{\"chunkedPrompt\":{\"chunks\":[{\"role\":\"model\"," ++
    "\"text\":\"aggregate\",\"parts\":[{\"text\":\"part\"}]}]}}"

example :
    (match importGoogleAiStudio gaisDivergentChunkTextFixture with
     | .ok t =>
         match t.entries.toList with
         | [{ payload := .assistantMsg [
                .text "part",
                .unmodeled "google-ai-studio-chunk-text-shadow" shadow], .. }] =>
             ostr shadow "text" == some "aggregate" &&
             ostr shadow "partsText" == some "part" &&
             t.importNotes.any (fun note =>
               note.kind == .other "gais-chunk-text-shadow")
         | _ => false
     | .error _ => false) = true := by native_decide

private def gaisUnknownPartFixture : String :=
  "{\"chunkedPrompt\":{\"chunks\":[{\"role\":\"model\",\"parts\":[" ++
    "{\"futurePart\":{\"opaque\":[1,false,null]}}" ++
  "]}]}}"

example :
    (match importGoogleAiStudio gaisUnknownPartFixture with
     | .ok t =>
         match t.entries.toList with
         | [{ payload := .assistantMsg [
                .unmodeled "google-ai-studio-model-part" raw], .. }] =>
             hasField raw "futurePart" &&
             t.importNotes.any (fun note =>
               note.kind == .other "gais-unmodeled-part")
         | _ => false
     | .error _ => false) = true := by native_decide

private def gaisLifecycleFixture : String :=
  "{\"chunkedPrompt\":{\"chunks\":[" ++
    "{\"role\":\"model\",\"parts\":[" ++
      "{\"functionCall\":{\"id\":\"same\",\"name\":\"lookup\",\"args\":{\"n\":1}}}," ++
      "{\"functionCall\":{\"id\":\"same\",\"name\":\"lookup\",\"args\":{\"n\":2}}}" ++
    "]}," ++
    "{\"role\":\"user\",\"parts\":[{\"functionResponse\":{" ++
      "\"id\":\"same\",\"name\":\"lookup\",\"isError\":false,\"response\":\"first\"}}]}," ++
    "{\"role\":\"user\",\"parts\":[{\"functionResponse\":{" ++
      "\"id\":\"same\",\"name\":\"lookup\",\"response\":{\"error\":{\"code\":7}}}}]}" ++
  "]}}"

private def gaisDuplicateLifecycleStaysAmbiguous : Bool :=
  match importGoogleAiStudio gaisLifecycleFixture with
  | .ok t =>
      match t.entries.toList with
      | [{ payload := .assistantMsg [
              .toolCall { raw := "lookup", .. } _ (some "same"),
              .toolCall { raw := "lookup", .. } _ (some "same")], .. },
          { payload := .envMsg [
              .toolResult (.unresolved (some "same") _) [.text "first"]
                (.native false)], .. },
          { payload := .envMsg [
              .toolResult (.unresolved (some "same") _)
                [.unmodeled "google-ai-studio-function-response" response]
                (.inferred true
                  "google-ai-studio:functionResponse.response.error-present")], .. }] =>
          hasField response "error" &&
          t.importNotes.any (fun note =>
            note.kind == .other "gais-ambiguous-tool-result") &&
          t.importNotes.any (fun note => note.kind == .errorInferred)
      | _ => false
  | .error _ => false

example : gaisDuplicateLifecycleStaysAmbiguous = true := by native_decide

private def gaisUniqueLifecycleFixture : String :=
  "{\"chunkedPrompt\":{\"chunks\":[" ++
    "{\"role\":\"model\",\"parts\":[{\"functionCall\":{" ++
      "\"id\":\"unique\",\"name\":\"lookup\",\"args\":{\"n\":1}}}]}," ++
    "{\"role\":\"user\",\"parts\":[{\"functionResponse\":{" ++
      "\"id\":\"unique\",\"name\":\"lookup\",\"response\":\"done\"}}]}]}}"

example :
    (match importGoogleAiStudio gaisUniqueLifecycleFixture with
     | .ok t =>
         match t.entries.toList with
         | [{ payload := .assistantMsg [
                .toolCall _ _ (some "unique")], .. },
            { payload := .envMsg [
                .toolResult (.resolved 0 0) [.text "done"] .unrecorded], .. }] => true
         | _ => false
     | .error _ => false) = true := by native_decide

private def gaisRepeatedResponseFixture : String :=
  "{\"chunkedPrompt\":{\"chunks\":[" ++
    "{\"role\":\"model\",\"parts\":[{\"functionCall\":{" ++
      "\"id\":\"unique\",\"name\":\"lookup\",\"args\":{}}}]}," ++
    "{\"role\":\"user\",\"parts\":[{\"functionResponse\":{" ++
      "\"id\":\"unique\",\"name\":\"lookup\",\"response\":\"one\"}}]}," ++
    "{\"role\":\"user\",\"parts\":[{\"functionResponse\":{" ++
      "\"id\":\"unique\",\"name\":\"lookup\",\"response\":\"two\"}}]}]}}"

example :
    (match importGoogleAiStudio gaisRepeatedResponseFixture with
     | .ok t =>
         match t.entries[1]?, t.entries[2]? with
         | some first, some second =>
             match first.payload, second.payload with
             | .envMsg [.toolResult (.resolved 0 0) [.text "one"] _],
               .envMsg [.toolResult (.resolved 0 0) [.text "two"] _] => true
             | _, _ => false
         | _, _ => false
     | .error _ => false) = true := by native_decide

private def gaisAnonymousLifecycleFixture : String :=
  "{\"chunkedPrompt\":{\"chunks\":[" ++
    "{\"role\":\"model\",\"parts\":[" ++
      "{\"functionCall\":{\"name\":\"lookup\",\"args\":{\"n\":1}}}," ++
      "{\"functionCall\":{\"name\":\"lookup\",\"args\":{\"n\":2}}}" ++
    "]}," ++
    "{\"role\":\"user\",\"parts\":[{\"functionResponse\":{" ++
      "\"name\":\"lookup\",\"response\":\"one\"}}]}," ++
    "{\"role\":\"user\",\"parts\":[{\"functionResponse\":{" ++
      "\"name\":\"lookup\",\"response\":\"two\"}}]}" ++
  "]}}"

example :
    (match importGoogleAiStudio gaisAnonymousLifecycleFixture with
     | .ok t =>
         match t.entries.toList with
         | [{ payload := .assistantMsg [
                .toolCall _ _ none, .toolCall _ _ none], .. },
            { payload := .envMsg [
                .toolResult (.unresolved none _) _ .unrecorded], .. },
            { payload := .envMsg [
                .toolResult (.unresolved none _) _ .unrecorded], .. }] => true
         | _ => false
     | .error _ => false) = true := by native_decide

private def gaisRecordedTimeFixture : String :=
  "{\"chunkedPrompt\":{\"chunks\":[{" ++
    "\"role\":\"user\",\"text\":\"timed\"," ++
    "\"createTime\":\"2024-07-03T09:46:40.001Z\"}]}}"

private def gaisUnrepresentableTimeFixture : String :=
  "{\"chunkedPrompt\":{\"chunks\":[{" ++
    "\"role\":\"user\",\"text\":\"timed\"," ++
    "\"createTime\":\"2024-07-03T09:46:40.000001Z\"}]}}"

example :
    (match importGoogleAiStudio gaisRecordedTimeFixture with
     | .ok t =>
         match t.entries.toList with
         | [{ time := .recorded { ms := 1720000000001 }, .. }] => true
         | _ => false
     | .error _ => false) = true := by native_decide

example :
    (match importGoogleAiStudio gaisUnrepresentableTimeFixture with
     | .ok t =>
         match t.entries.toList with
         | [{ time := .sequenced 0, .. }] =>
             t.importNotes.any (fun note =>
               note.kind == .other "gais-source-time-unparsed")
         | _ => false
     | .error _ => false) = true := by native_decide

private def gaisMalformedKnownRecords : List String := [
  "[]",
  "{}",
  "{\"chunkedPrompt\":[]}",
  "{\"runSettings\":{\"model\":7},\"chunkedPrompt\":{\"chunks\":[]}}",
  "{\"runSettings\":{\"thinkingLevel\":\"thinking\"},\"chunkedPrompt\":{\"chunks\":[]}}",
  "{\"systemInstruction\":{\"parts\":{}},\"chunkedPrompt\":{\"chunks\":[]}}",
  "{\"systemInstruction\":{\"parts\":[{\"text\":7}]},\"chunkedPrompt\":{\"chunks\":[]}}",
  "{\"systemInstruction\":{\"text\":\"a\",\"parts\":[{\"text\":\"b\"}]},\"chunkedPrompt\":{\"chunks\":[]}}",
  "{\"chunkedPrompt\":{\"chunks\":[{\"text\":\"missing role\"}]}}",
  "{\"chunkedPrompt\":{\"chunks\":[{\"role\":\"user\",\"isThought\":true,\"text\":\"x\"}]}}",
  "{\"chunkedPrompt\":{\"chunks\":[{\"role\":\"model\",\"parts\":{}}]}}",
  "{\"chunkedPrompt\":{\"chunks\":[{\"role\":\"model\",\"parts\":[{\"text\":7}]}]}}",
  "{\"chunkedPrompt\":{\"chunks\":[{\"role\":\"user\",\"parts\":[{\"functionCall\":{\"name\":\"x\",\"args\":{}}}]}]}}",
  "{\"chunkedPrompt\":{\"chunks\":[{\"role\":\"model\",\"parts\":[{\"functionCall\":{\"name\":\"x\"}}]}]}}",
  "{\"chunkedPrompt\":{\"chunks\":[{\"role\":\"model\",\"parts\":[{\"functionCall\":{\"name\":\"x\",\"args\":[]}}]}]}}",
  "{\"chunkedPrompt\":{\"chunks\":[{\"role\":\"model\",\"parts\":[{\"functionResponse\":{\"name\":\"x\",\"response\":{}}}]}]}}",
  "{\"chunkedPrompt\":{\"chunks\":[{\"role\":\"user\",\"driveImage\":\"bad\"}]}}",
  "{\"chunkedPrompt\":{\"chunks\":[{\"role\":\"model\",\"errorMessage\":7}]}}",
  "{\"chunkedPrompt\":{\"chunks\":[{\"role\":\"user\",\"createTime\":7,\"text\":\"x\"}]}}",
  "{\"chunkedPrompt\":{\"chunks\":[{\"role\":\"model\",\"parts\":[{" ++
    "\"functionCall\":{\"name\":\"x\",\"args\":{}}," ++
    "\"functionResponse\":{\"name\":\"x\",\"response\":{}}}]}]}}",
  "{\"chunkedPrompt\":{\"chunks\":[" ++
    "{\"role\":\"model\",\"parts\":[{\"functionCall\":{\"id\":\"same\",\"name\":\"x\",\"args\":{}}}]}," ++
    "{\"role\":\"user\",\"parts\":[{\"functionResponse\":{\"id\":\"same\",\"name\":\"y\",\"response\":{}}}]}]}}"
]

example : gaisMalformedKnownRecords.all gaisRejects = true := by native_decide

end LoomConvert
