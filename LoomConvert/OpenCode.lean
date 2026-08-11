import Loom

/-!
# LoomConvert.OpenCode

Importer/exporter for the document produced by `opencode export` and consumed
by `opencode import`.  OpenCode stores a tool invocation and its terminal state
in one assistant `tool` part; the importer splits it into Loom's authored call
and environment-authored result, while the exporter joins a resolved pair.
-/

namespace LoomConvert
open Loom
open Lean (Json)

def openCodeTargetVersion : String := "1.1.34"

private def ocError (ctx detail : String) : Except String α :=
  .error s!"malformed OpenCode {ctx}: {detail}"

private def ocObject (ctx : String) : Json → Except String Json
  | value@(.obj _) => pure value
  | _ => ocError ctx "expected an object"

private def ocField (ctx : String) (j : Json) (key : String) : Except String Json := do
  let _ ← ocObject ctx j
  match j.getObjVal? key with
  | .ok value => pure value
  | .error _ => ocError ctx s!"missing required field '{key}'"

private def ocString (ctx : String) (j : Json) (key : String) : Except String String := do
  match ← ocField ctx j key with
  | .str value => pure value
  | _ => ocError ctx s!"field '{key}' must be a string"

private def ocArray (ctx : String) (j : Json) (key : String) : Except String (Array Json) := do
  match ← ocField ctx j key with
  | .arr value => pure value
  | _ => ocError ctx s!"field '{key}' must be an array"

private def ocOptString (ctx : String) (j : Json) (key : String) : Except String (Option String) := do
  let _ ← ocObject ctx j
  match j.getObjVal? key with
  | .error _ | .ok .null => pure none
  | .ok (.str value) => pure (some value)
  | .ok _ => ocError ctx s!"field '{key}' must be a string or null"

private def ocOptBool (ctx : String) (j : Json) (key : String) : Except String (Option Bool) := do
  let _ ← ocObject ctx j
  match j.getObjVal? key with
  | .error _ | .ok .null => pure none
  | .ok (.bool value) => pure (some value)
  | .ok _ => ocError ctx s!"field '{key}' must be a boolean or null"

private def ocOptNat (ctx : String) (j : Json) (key : String) : Except String (Option Nat) := do
  let _ ← ocObject ctx j
  match j.getObjVal? key with
  | .error _ | .ok .null => pure none
  | .ok value =>
      match value.getNat? with
      | .ok n => pure (some n)
      | .error _ => ocError ctx s!"field '{key}' must be a non-negative integer"

private def ocOptObject (ctx : String) (j : Json) (key : String) : Except String (Option Json) := do
  let _ ← ocObject ctx j
  match j.getObjVal? key with
  | .error _ | .ok .null => pure none
  | .ok value@(.obj _) => pure (some value)
  | .ok _ => ocError ctx s!"field '{key}' must be an object or null"

private def ocOptArray (ctx : String) (j : Json) (key : String) : Except String (Option (Array Json)) := do
  let _ ← ocObject ctx j
  match j.getObjVal? key with
  | .error _ | .ok .null => pure none
  | .ok (.arr value) => pure (some value)
  | .ok _ => ocError ctx s!"field '{key}' must be an array or null"

private def canonicalTool : String → Option CanonicalTool
  | "bash" | "shell" => some .bash
  | "read" => some .read
  | "write" => some .write
  | "edit" => some .edit
  | "grep" => some .grep
  | "glob" => some .glob
  | "webfetch" | "web_fetch" => some .webFetch
  | "websearch" | "web_search" => some .webSearch
  | "task" | "subtask" => some .agentSpawn
  | "apply_patch" | "applypatch" => some .applyPatch
  | _ => none

private def timeToCarrier : Time → Json
  | .recorded ⟨ms⟩ => Json.mkObj [("kind", .str "recorded"), ("ms", .num ms)]
  | .interpolated ⟨ms⟩ basis => Json.mkObj [
      ("kind", .str "interpolated"), ("ms", .num ms), ("basis", .str basis)]
  | .sequenced ordinal => Json.mkObj [
      ("kind", .str "sequenced"), ("ordinal", .num ordinal)]
  | .absent => Json.mkObj [("kind", .str "absent")]

private def timeFromCarrier (j : Json) : Option Time := do
  let kind ← (j.getObjVal? "kind" >>= Json.getStr?).toOption
  match kind with
  | "recorded" =>
      let ms ← (j.getObjVal? "ms" >>= Json.getNat?).toOption
      some (.recorded ⟨ms⟩)
  | "interpolated" =>
      let ms ← (j.getObjVal? "ms" >>= Json.getNat?).toOption
      let basis ← (j.getObjVal? "basis" >>= Json.getStr?).toOption
      some (.interpolated ⟨ms⟩ basis)
  | "sequenced" =>
      let ordinal ← (j.getObjVal? "ordinal" >>= Json.getNat?).toOption
      some (.sequenced ordinal)
  | "absent" => some .absent
  | _ => none

private def eventToCarrier : MetaEvent → Json
  | .modelChange prev next => Json.mkObj [
      ("kind", .str "modelChange"),
      ("prev", prev.map Json.str |>.getD .null),
      ("next", next.map Json.str |>.getD .null)]
  | .thinkingLevelChange prev next => Json.mkObj [
      ("kind", .str "thinkingLevelChange"),
      ("prev", prev.map Json.str |>.getD .null),
      ("next", next.map Json.str |>.getD .null)]
  | .permissionMode mode => Json.mkObj [
      ("kind", .str "permissionMode"), ("mode", .str mode)]
  | .branchSummary summary => Json.mkObj [
      ("kind", .str "branchSummary"), ("summary", .str summary)]
  | .custom label raw => Json.mkObj [
      ("kind", .str "custom"), ("label", .str label), ("raw", raw)]

private def nullableString (j : Json) (key : String) : Option (Option String) :=
  match j.getObjVal? key with
  | .ok .null => some none
  | .ok (.str value) => some (some value)
  | _ => none

private def eventFromCarrier (j : Json) : Option MetaEvent := do
  let kind ← (j.getObjVal? "kind" >>= Json.getStr?).toOption
  match kind with
  | "modelChange" => some (.modelChange (← nullableString j "prev") (← nullableString j "next"))
  | "thinkingLevelChange" =>
      some (.thinkingLevelChange (← nullableString j "prev") (← nullableString j "next"))
  | "permissionMode" =>
      some (.permissionMode (← (j.getObjVal? "mode" >>= Json.getStr?).toOption))
  | "branchSummary" =>
      some (.branchSummary (← (j.getObjVal? "summary" >>= Json.getStr?).toOption))
  | "custom" =>
      let label ← (j.getObjVal? "label" >>= Json.getStr?).toOption
      let raw ← (j.getObjVal? "raw").toOption
      some (.custom label raw)
  | _ => none

private def agentConvertMetadata? (part : Json) : Option Json := do
  let metadata ← (part.getObjVal? "metadata").toOption
  (metadata.getObjVal? "_agentConvert").toOption

private def carrierKind? (part : Json) : Option String := do
  let metadata ← agentConvertMetadata? part
  (metadata.getObjVal? "kind" >>= Json.getStr?).toOption

private def carrierTime? (parts : Array Json) : Option Time := do
  let part ← parts[0]?
  let metadata ← agentConvertMetadata? part
  let value ← (metadata.getObjVal? "sourceTime").toOption
  timeFromCarrier value

private def carrierRawId? (parts : Array Json) : Option String := do
  let part ← parts[0]?
  let metadata ← agentConvertMetadata? part
  (metadata.getObjVal? "sourceRawId" >>= Json.getStr?).toOption

private def carrierEvent? (parts : Array Json) : Option MetaEvent := do
  let part ← parts[0]?
  let metadata ← agentConvertMetadata? part
  guard ((metadata.getObjVal? "kind" >>= Json.getStr?).toOption == some "event")
  let value ← (metadata.getObjVal? "event").toOption
  eventFromCarrier value

private def noteSkipped (loc kind : String) : ImportNote := {
  kind := .contentSkipped
  loc := some loc
  detail := s!"OpenCode bookkeeping part '{kind}' retained in message provenance"
}

private def compactionRequestNote (loc : String) : ImportNote := {
  kind := .contentSkipped
  loc := some loc
  detail := "compaction request represented by the following OpenCode summary message"
}

private def mkOpenCodeEntry (entries : Array Entry) (payload : Payload)
    (time : Time) (rawId : Option String) (sourceRef : String) (raw : Json) : Entry := {
  parent := if entries.isEmpty then none else some (entries.size - 1)
  thread := 0
  time
  payload
  origin := {
    format := .openCode
    sourceRef
    rawId
    extras := some (Json.mkObj [("opencodeRawMessage", raw)])
  }
}

private def parseFileBlock (ctx : String) (part : Json) : Except String (String × String) := do
  let mime ← ocString ctx part "mime"
  let url ← ocString ctx part "url"
  pure (mime, url)

private def toolResultContent (ctx : String) (state : Json) : Except String (List UserBlock) := do
  let output ← match ← ocOptString ctx state "output" with
    | some value => pure value
    | none => match ← ocOptString ctx state "error" with
      | some value => pure value
      | none => ocError ctx "terminal tool state requires output or error"
  let attachments ← (ocOptArray ctx state "attachments").map (Option.getD · #[])
  let mut content : List UserBlock := [.text output]
  for (attachment, index) in attachments.toList.zipIdx do
    let (mime, url) ← parseFileBlock s!"{ctx}.attachments[{index}]" attachment
    content := content ++ [.media mime url]
  pure content

private def messageTime (ctx : String) (info : Json) (parts : Array Json) : Except String Time := do
  match carrierTime? parts with
  | some value => pure value
  | none =>
      let time ← ocField ctx info "time" >>= ocObject (ctx ++ ".time")
      let created ← ocOptNat (ctx ++ ".time") time "created"
      match created with
      | some ms => pure (.recorded ⟨ms⟩)
      | none => ocError (ctx ++ ".time") "missing required field 'created'"

/-- Import the official `opencode export` document. -/
def importOpenCode (text : String) : Except String Transcript := do
  let document ← match Json.parse text with
    | .ok value => pure value
    | .error error => ocError "document" s!"invalid JSON: {error}"
  let info ← ocField "document" document "info" >>= ocObject "info"
  let messages ← ocArray "document" document "messages"
  let sessionId ← ocString "info" info "id"
  let directory ← ocString "info" info "directory"
  let version ← ocString "info" info "version"
  let sessionModel ← ocOptObject "info" info "model"
  let mut model := sessionModel.bind (fun value =>
    (value.getObjVal? "id" >>= Json.getStr?).toOption)
  let mut provider := sessionModel.bind (fun value =>
    (value.getObjVal? "providerID" >>= Json.getStr?).toOption)
  let mut instructions : Option String := none
  let mut entries : Array Entry := #[]
  let mut notes : List ImportNote := []

  for (message, messageIndex) in messages.toList.zipIdx do
    let msgCtx := s!"messages[{messageIndex}]"
    let _ ← ocObject msgCtx message
    let msgInfo ← ocField msgCtx message "info" >>= ocObject (msgCtx ++ ".info")
    let parts ← ocArray msgCtx message "parts"
    let role ← ocString (msgCtx ++ ".info") msgInfo "role"
    let nativeMessageId ← ocString (msgCtx ++ ".info") msgInfo "id"
    let rawId := carrierRawId? parts <|> some nativeMessageId
    let time ← messageTime (msgCtx ++ ".info") msgInfo parts
    match carrierEvent? parts with
    | some event =>
        entries := entries.push (mkOpenCodeEntry entries (.event event) time rawId msgCtx message)
        continue
    | none => pure ()
    if role == "user" then
      if instructions.isNone then instructions := ← ocOptString (msgCtx ++ ".info") msgInfo "system"
      match ← ocOptObject (msgCtx ++ ".info") msgInfo "model" with
      | some selected =>
          model := model <|> (selected.getObjVal? "modelID" >>= Json.getStr?).toOption
          provider := provider <|> (selected.getObjVal? "providerID" >>= Json.getStr?).toOption
      | none => pure ()
      let mut blocks : List UserBlock := []
      let mut sawCompaction := false
      for (part, partIndex) in parts.toList.zipIdx do
        let partCtx := s!"{msgCtx}.parts[{partIndex}]"
        let _ ← ocObject partCtx part
        let kind ← ocString partCtx part "type"
        match kind with
        | "text" =>
            let ignored := (← ocOptBool partCtx part "ignored").getD false
            if ignored && carrierKind? part == some "entry-metadata" then pure ()
            else if ignored then
              blocks := blocks ++ [.unmodeled "opencode.ignored-text" part]
            else
              blocks := blocks ++ [.text (← ocString partCtx part "text")]
        | "file" =>
            let (mime, url) ← parseFileBlock partCtx part
            blocks := blocks ++ [.media mime url]
        | "compaction" => sawCompaction := true
        | "subtask" | "agent" | "snapshot" | "patch" | "step-start" | "step-finish" | "retry" =>
            notes := notes ++ [noteSkipped partCtx kind]
        | other => blocks := blocks ++ [.unmodeled s!"opencode.{other}" part]
      if !blocks.isEmpty then
        entries := entries.push (mkOpenCodeEntry entries (.userMsg blocks) time rawId msgCtx message)
      else if sawCompaction then
        notes := notes ++ [compactionRequestNote msgCtx]
      else
        entries := entries.push (mkOpenCodeEntry entries (.userMsg []) time rawId msgCtx message)
    else if role == "assistant" then
      model := model <|> (← ocOptString (msgCtx ++ ".info") msgInfo "modelID")
      provider := provider <|> (← ocOptString (msgCtx ++ ".info") msgInfo "providerID")
      let isSummary := (← ocOptBool (msgCtx ++ ".info") msgInfo "summary").getD false
      if isSummary then
        let mut summaryParts : List String := []
        for (part, partIndex) in parts.toList.zipIdx do
          let partCtx := s!"{msgCtx}.parts[{partIndex}]"
          let kind ← ocString partCtx part "type"
          if kind == "text" then summaryParts := summaryParts ++ [← ocString partCtx part "text"]
          else notes := notes ++ [noteSkipped partCtx kind]
        entries := entries.push (mkOpenCodeEntry entries
          (.compaction (String.intercalate "\n" summaryParts) .unknownPrefix none)
          time rawId msgCtx message)
      else
        let mut blocks : List AssistantBlock := []
        for (part, partIndex) in parts.toList.zipIdx do
          let partCtx := s!"{msgCtx}.parts[{partIndex}]"
          let _ ← ocObject partCtx part
          let kind ← ocString partCtx part "type"
          match kind with
          | "text" =>
              let ignored := (← ocOptBool partCtx part "ignored").getD false
              if ignored && carrierKind? part == some "entry-metadata" then pure ()
              else if ignored then blocks := blocks ++ [.unmodeled "opencode.ignored-text" part]
              else blocks := blocks ++ [.text (← ocString partCtx part "text")]
          | "reasoning" =>
              let signature := agentConvertMetadata? part >>= fun metadata =>
                (metadata.getObjVal? "reasoningSignature" >>= Json.getStr?).toOption
              blocks := blocks ++ [.thinking (← ocString partCtx part "text") signature]
          | "file" =>
              let (mime, url) ← parseFileBlock partCtx part
              blocks := blocks ++ [.media mime url]
          | "tool" =>
              let name ← ocString partCtx part "tool"
              let callId ← ocString partCtx part "callID"
              let state ← ocField partCtx part "state" >>= ocObject (partCtx ++ ".state")
              let status ← ocString (partCtx ++ ".state") state "status"
              let args ← ocField (partCtx ++ ".state") state "input"
              let callBlock := blocks.length
              blocks := blocks ++ [.toolCall { raw := name, canonical := canonicalTool name.toLower } args (some callId)]
              if status == "completed" || status == "error" then
                let callEntry := entries.size
                entries := entries.push (mkOpenCodeEntry entries (.assistantMsg blocks)
                  time rawId msgCtx message)
                blocks := []
                let content ← toolResultContent (partCtx ++ ".state") state
                let signal := ErrorSignal.native (status == "error")
                entries := entries.push (mkOpenCodeEntry entries
                  (.envMsg [.toolResult (.resolved callEntry callBlock) content signal])
                  time none (partCtx ++ ".state") part)
              else if status == "pending" || status == "running" then pure ()
              else ocError (partCtx ++ ".state") s!"unknown tool status '{status}'"
          | "subtask" | "agent" | "snapshot" | "patch" | "step-start" | "step-finish" | "retry" | "compaction" =>
              notes := notes ++ [noteSkipped partCtx kind]
          | other => blocks := blocks ++ [.unmodeled s!"opencode.{other}" part]
        if !blocks.isEmpty then
          entries := entries.push (mkOpenCodeEntry entries (.assistantMsg blocks) time rawId msgCtx message)
        else pure ()
        match ← ocOptObject (msgCtx ++ ".info") msgInfo "error" with
        | some error =>
            entries := entries.push (mkOpenCodeEntry entries
              (.event (.custom "opencode.assistant-error" error)) time none
              (msgCtx ++ ".info.error") error)
        | none => pure ()
    else
      ocError (msgCtx ++ ".info") s!"unsupported role '{role}'"

  let activeLeaf := if entries.isEmpty then none else some (entries.size - 1)
  pure {
    threads := #[{ kind := .main }]
    entries
    env := {
      cwd := some directory
      model
      provider
      harnessVersion := some version
      instructions
      sessionId := some sessionId
    }
    activeLeaf
    importNotes := notes
    origin := {
      format := .openCode
      sourceRef := "opencode export"
      rawId := some sessionId
      extras := some (Json.mkObj [("opencodeRawInfo", info)])
    }
  }

private def isObject : Json → Bool
  | .obj _ => true
  | _ => false

private def resultContentExportable : List UserBlock → Bool
  | [] => true
  | .text _ :: rest | .media _ _ :: rest => resultContentExportable rest
  | .unmodeled _ _ :: _ => false

private def callAt? (t : Transcript) (entry block : Nat) : Option AssistantBlock := do
  let source ← t.entries[entry]?
  match source.payload with
  | .assistantMsg blocks => blocks[block]?
  | _ => none

def openCodeTargetExportPrerequisiteFailures (t : Transcript) : List String := Id.run do
  let mut failures : List String := []
  for (entry, entryIndex) in t.entries.toList.zipIdx do
    if entry.disposition == .historicalUnverified then
      failures := failures ++ [s!"entry {entryIndex}: historical/unverified entries have no reviewed OpenCode inert carrier"]
    match entry.payload with
    | .userMsg blocks =>
        if blocks.any (fun | .unmodeled _ _ => true | _ => false) then
          failures := failures ++ [s!"entry {entryIndex}: unmodeled user content is not safely exportable"]
    | .assistantMsg blocks =>
        for (block, blockIndex) in blocks.zipIdx do
          match block with
          | .toolCall name args _ =>
              if name.raw.isEmpty then failures := failures ++ [s!"entry {entryIndex}, block {blockIndex}: empty tool name"]
              if !isObject args then failures := failures ++ [s!"entry {entryIndex}, block {blockIndex}: OpenCode tool input must be an object"]
          | .unmodeled _ _ =>
              failures := failures ++ [s!"entry {entryIndex}, block {blockIndex}: unmodeled assistant content is not safely exportable"]
          | _ => pure ()
    | .envMsg blocks =>
        for (block, blockIndex) in blocks.zipIdx do
          match block with
          | .toolResult (.resolved callEntry callBlock) content signal =>
              match callAt? t callEntry callBlock with
              | some (.toolCall _ _ _) => pure ()
              | _ => failures := failures ++ [s!"entry {entryIndex}, block {blockIndex}: result does not reference a tool call"]
              if !resultContentExportable content then
                failures := failures ++ [s!"entry {entryIndex}, block {blockIndex}: unmodeled tool-result content"]
              if signal == .unrecorded then
                failures := failures ++ [s!"entry {entryIndex}, block {blockIndex}: OpenCode requires a known terminal tool status"]
          | .toolResult (.unresolved _ _) _ _ =>
              failures := failures ++ [s!"entry {entryIndex}, block {blockIndex}: unresolved tool result"]
          | .unmodeled _ _ =>
              failures := failures ++ [s!"entry {entryIndex}, block {blockIndex}: unmodeled environment content"]
    | .otherMsg role _ =>
        failures := failures ++ [s!"entry {entryIndex}: OpenCode has no standalone '{role}' message role"]
    | .compaction _ _ _ | .event _ => pure ()
  return failures

private structure OCResult where
  content : List UserBlock
  error : ErrorSignal

private def resultFor? (t : Transcript) (entry block : Nat) : Option OCResult :=
  t.entries.toList.findSome? fun candidate =>
    match candidate.payload with
    | .envMsg blocks => blocks.findSome? fun
        | .toolResult (.resolved e b) content error =>
            if e == entry && b == block then some { content, error } else none
        | _ => none
    | _ => none

private def targetString (t : Transcript) (key : String) : Option String := do
  let extras ← t.origin.extras
  let value ← (extras.getObjVal? key >>= Json.getStr?).toOption
  if value.isEmpty then none else some value

private def validSessionId (value : String) : Bool := value.startsWith "ses"

private def exportSessionId (t : Transcript) : String :=
  match targetString t "target_session_id" <|> t.env.sessionId with
  | some value => if validSessionId value then value else "ses_loom_converted"
  | none => "ses_loom_converted"

private def exportTimestamp (base : Nat) (entry : Entry) (ordinal : Nat) : Nat :=
  match entry.time with
  | .recorded ⟨ms⟩ | .interpolated ⟨ms⟩ _ => ms
  | .sequenced sequence => base + sequence
  | .absent => base + ordinal

private def sourceMetadata (entry : Entry) (extra : List (String × Json) := []) : Json :=
  Json.mkObj [
    ("_agentConvert", Json.mkObj ([
      ("protocol", .str "agent-convert.opencode.v1"),
      ("sourceTime", timeToCarrier entry.time)] ++
      (match entry.origin.rawId with
       | some value => [("sourceRawId", .str value)]
       | none => []) ++ extra))]

private def addSourceMetadata (part : Json) (entry : Entry)
    (extra : List (String × Json) := []) : Json :=
  match part with
  | .obj fields =>
      let generated := match sourceMetadata entry extra with
        | .obj metadata => metadata
        | _ => {}
      let generatedAgent := match generated.get? "_agentConvert" with
        | some (.obj values) => values
        | _ => {}
      let existingMetadata := match fields.get? "metadata" with
        | some (.obj metadata) => metadata
        | _ => {}
      let existingAgent := match existingMetadata.get? "_agentConvert" with
        | some (.obj values) => values
        | _ => {}
      let mergedAgent := generatedAgent.foldl (fun acc key value => acc.insert key value)
        existingAgent
      .obj (fields.insert "metadata"
        (.obj (existingMetadata.insert "_agentConvert" (.obj mergedAgent))))
  | other => other

private def partSupportsMetadata (part : Json) : Bool :=
  match (part.getObjVal? "type" >>= Json.getStr?).toOption with
  | some "text" | some "reasoning" | some "tool" => true
  | _ => false

private def attachEntryMetadata (sessionId messageId : String) (entry : Entry)
    (entryIndex : Nat) (parts : Array Json) : Array Json :=
  match parts[0]? with
  | some first =>
      if partSupportsMetadata first then
        parts.set! 0 (addSourceMetadata first entry)
      else
        let carrier := Json.mkObj [
          ("id", .str s!"prt_loom_{entryIndex}_meta"),
          ("sessionID", .str sessionId), ("messageID", .str messageId),
          ("type", .str "text"), ("text", .str ""),
          ("synthetic", .bool true), ("ignored", .bool true)]
        #[addSourceMetadata carrier entry [("kind", .str "entry-metadata")]] ++ parts
  | none => parts

private def ocPartBase (sessionId messageId partId kind : String) : List (String × Json) := [
  ("id", .str partId), ("sessionID", .str sessionId),
  ("messageID", .str messageId), ("type", .str kind)]

private def attachmentJson (sessionId messageId partId mime url : String) : Json :=
  Json.mkObj (ocPartBase sessionId messageId partId "file" ++ [
    ("mime", .str mime), ("url", .str url)])

private def contentOutput (content : List UserBlock) : String :=
  String.intercalate "\n" (content.filterMap fun
    | .text value => some value
    | _ => none)

private def contentAttachments (sessionId messageId baseId : String)
    (content : List UserBlock) : Array Json :=
  (content.filterMap (fun
    | .media mime url => some (mime, url)
    | _ => none)).zipIdx.map (fun ((mime, url), index) =>
      attachmentJson sessionId messageId s!"{baseId}_att_{index}" mime url) |>.toArray

private def userBlockPart (sessionId messageId : String)
    (entryIndex blockIndex : Nat) : UserBlock → Json
  | .text value => Json.mkObj (ocPartBase sessionId messageId
      s!"prt_loom_{entryIndex}_{blockIndex}" "text" ++ [("text", .str value)])
  | .media mime url => attachmentJson sessionId messageId
      s!"prt_loom_{entryIndex}_{blockIndex}" mime url
  | .unmodeled _ raw => raw

private def assistantBlockPart (t : Transcript) (sessionId messageId : String)
    (entry : Entry) (entryIndex blockIndex created : Nat) : AssistantBlock → Json
  | .text value => Json.mkObj (ocPartBase sessionId messageId
      s!"prt_loom_{entryIndex}_{blockIndex}" "text" ++ [("text", .str value)])
  | .thinking value signature =>
      let raw := Json.mkObj (ocPartBase sessionId messageId
        s!"prt_loom_{entryIndex}_{blockIndex}" "reasoning" ++ [
          ("text", .str value), ("time", Json.mkObj [("start", .num created)])])
      match signature with
      | some sig => addSourceMetadata raw entry [("reasoningSignature", .str sig)]
      | none => raw
  | .media mime url => attachmentJson sessionId messageId
      s!"prt_loom_{entryIndex}_{blockIndex}" mime url
  | .toolCall name args rawId =>
      let partId := s!"prt_loom_{entryIndex}_{blockIndex}"
      let callId := match rawId with
        | some value => if value.isEmpty then s!"call_loom_{entryIndex}_{blockIndex}" else value
        | none => s!"call_loom_{entryIndex}_{blockIndex}"
      let started := created
      let state := match resultFor? t entryIndex blockIndex with
        | none => Json.mkObj [
            ("status", .str "pending"), ("input", args), ("raw", .str args.compress)]
        | some result =>
            let failed := match result.error with
              | .native value | .inferred value _ => value
              | .unrecorded => false
            if failed then Json.mkObj [
              ("status", .str "error"), ("input", args),
              ("error", .str (contentOutput result.content)),
              ("time", Json.mkObj [("start", .num started), ("end", .num started)])]
            else Json.mkObj [
              ("status", .str "completed"), ("input", args),
              ("output", .str (contentOutput result.content)), ("title", .str name.raw),
              ("metadata", Json.mkObj []),
              ("time", Json.mkObj [("start", .num started), ("end", .num started)]),
              ("attachments", .arr (contentAttachments sessionId messageId partId result.content))]
      Json.mkObj (ocPartBase sessionId messageId partId "tool" ++ [
        ("callID", .str callId), ("tool", .str name.raw), ("state", state)])
  | .unmodeled _ raw => raw

private def messageInfoBase (sessionId messageId role : String) (created : Nat) : List (String × Json) := [
  ("id", .str messageId), ("sessionID", .str sessionId), ("role", .str role),
  ("time", Json.mkObj [("created", .num created)])]

private def zeroTokens : Json := Json.mkObj [
  ("input", .num 0), ("output", .num 0), ("reasoning", .num 0),
  ("cache", Json.mkObj [("read", .num 0), ("write", .num 0)])]

private def mkUserInfo (sessionId messageId provider model agent : String)
    (created : Nat) (system : Option String := none) : Json :=
  Json.mkObj (messageInfoBase sessionId messageId "user" created ++ [
    ("agent", .str agent),
    ("model", Json.mkObj [("providerID", .str provider), ("modelID", .str model)])] ++
    (match system with | some value => [("system", .str value)] | none => []))

private def mkAssistantInfo (sessionId messageId parentId provider model agent cwd : String)
    (created : Nat) (summary : Bool := false) : Json :=
  Json.mkObj ([
    ("id", .str messageId), ("sessionID", .str sessionId),
    ("role", .str "assistant"),
    ("time", Json.mkObj [("created", .num created), ("completed", .num created)]),
    ("parentID", .str parentId),
    ("modelID", .str model), ("providerID", .str provider),
    ("mode", .str agent), ("agent", .str agent),
    ("path", Json.mkObj [("cwd", .str cwd), ("root", .str cwd)]),
    ("summary", .bool summary), ("cost", .num 0), ("tokens", zeroTokens),
    ("finish", .str "stop")])

private def eventMessage (sessionId messageId provider model agent : String)
    (entry : Entry) (entryIndex created : Nat) (event : MetaEvent) : Json :=
  let part := Json.mkObj (ocPartBase sessionId messageId s!"prt_loom_{entryIndex}_0" "text" ++ [
    ("text", .str ""), ("synthetic", .bool true), ("ignored", .bool true)])
  let part := addSourceMetadata part entry [("kind", .str "event"), ("event", eventToCarrier event)]
  Json.mkObj [
    ("info", mkUserInfo sessionId messageId provider model agent created),
    ("parts", .arr #[part])]

/-- Export a Loom transcript as an importable OpenCode session document. -/
def exportOpenCodeChecked (t : Transcript) : Except String String := do
  let failures := openCodeTargetExportPrerequisiteFailures t
  if !failures.isEmpty then
    .error s!"OpenCode target prerequisites failed: {String.intercalate "; " failures}"
  let sessionId := exportSessionId t
  let cwd := (targetString t "target_cwd" <|> t.env.cwd).getD "."
  let provider := (targetString t "target_provider" <|> t.env.provider).getD "openai"
  let model := (targetString t "target_model" <|> t.env.model).getD "gpt-5"
  let version := (targetString t "target_harness_version" <|> t.env.harnessVersion).getD openCodeTargetVersion
  let targetBase := (targetString t "target_timestamp" >>= iso8601ToEpochMs?).map
    (fun timestamp => timestamp.ms) |>.getD 0
  let agent := "build"
  let mut messages : Array Json := #[]
  let mut lastMessageId := "msg_loom_root"
  let mut usedInstructions := false
  for (entry, entryIndex) in t.entries.toList.zipIdx do
    let created := exportTimestamp targetBase entry entryIndex
    let messageId := s!"msg_loom_{entryIndex}"
    match entry.payload with
    | .userMsg blocks =>
        let mut parts := (blocks.zipIdx.map (fun (block, blockIndex) =>
          userBlockPart sessionId messageId entryIndex blockIndex block)).toArray
        if parts.isEmpty then
          parts := #[Json.mkObj (ocPartBase sessionId messageId s!"prt_loom_{entryIndex}_0" "text" ++ [("text", .str "")])]
        parts := attachEntryMetadata sessionId messageId entry entryIndex parts
        let system := if usedInstructions then none else t.env.instructions
        if system.isSome then usedInstructions := true
        messages := messages.push (Json.mkObj [
          ("info", mkUserInfo sessionId messageId provider model agent created system),
          ("parts", .arr parts)])
        lastMessageId := messageId
    | .assistantMsg blocks =>
        let mut parts := (blocks.zipIdx.map (fun (block, blockIndex) =>
          assistantBlockPart t sessionId messageId entry entryIndex blockIndex created block)).toArray
        if parts.isEmpty then
          parts := #[Json.mkObj (ocPartBase sessionId messageId s!"prt_loom_{entryIndex}_0" "text" ++ [("text", .str "")])]
        parts := attachEntryMetadata sessionId messageId entry entryIndex parts
        messages := messages.push (Json.mkObj [
          ("info", mkAssistantInfo sessionId messageId lastMessageId provider model agent cwd created),
          ("parts", .arr parts)])
        lastMessageId := messageId
    | .envMsg _ => pure ()
    | .compaction summary _ _ =>
        let requestId := s!"msg_loom_{entryIndex}_compact"
        let requestPart := Json.mkObj (ocPartBase sessionId requestId
          s!"prt_loom_{entryIndex}_compact" "compaction" ++ [("auto", .bool false)])
        messages := messages.push (Json.mkObj [
          ("info", mkUserInfo sessionId requestId provider model agent created),
          ("parts", .arr #[requestPart])])
        let summaryPart := addSourceMetadata (Json.mkObj (ocPartBase sessionId messageId
          s!"prt_loom_{entryIndex}_0" "text" ++ [("text", .str summary)])) entry
        messages := messages.push (Json.mkObj [
          ("info", mkAssistantInfo sessionId messageId requestId provider model agent cwd created true),
          ("parts", .arr #[summaryPart])])
        lastMessageId := messageId
    | .event event =>
        messages := messages.push (eventMessage sessionId messageId provider model agent
          entry entryIndex created event)
        lastMessageId := messageId
    | .otherMsg _ _ => pure ()
  let created := t.entries[0]?.map (fun entry => exportTimestamp targetBase entry 0) |>.getD targetBase
  let updated := t.entries.back?.map (fun entry =>
    exportTimestamp targetBase entry (t.entries.size - 1)) |>.getD created
  let metadata := Json.mkObj [
    ("_agentConvert", Json.mkObj [
      ("protocol", .str "agent-convert.opencode.v1"),
      ("sourceSessionId", t.env.sessionId.map Json.str |>.getD .null),
      ("sourceOriginRawId", t.origin.rawId.map Json.str |>.getD .null),
      ("sourceEnvironment", Json.mkObj [
        ("cwd", t.env.cwd.map Json.str |>.getD .null),
        ("model", t.env.model.map Json.str |>.getD .null),
        ("provider", t.env.provider.map Json.str |>.getD .null),
        ("harnessVersion", t.env.harnessVersion.map Json.str |>.getD .null),
        ("instructions", t.env.instructions.map Json.str |>.getD .null),
        ("sessionId", t.env.sessionId.map Json.str |>.getD .null)])])]
  let info := Json.mkObj [
    ("id", .str sessionId), ("slug", .str sessionId), ("projectID", .str "global"),
    ("directory", .str cwd), ("title", .str "Converted Loom session"),
    ("version", .str version), ("metadata", metadata),
    ("model", Json.mkObj [("id", .str model), ("providerID", .str provider)]),
    ("time", Json.mkObj [("created", .num created), ("updated", .num updated)])]
  pure ((Json.mkObj [("info", info), ("messages", .arr messages)]).pretty ++ "\n")

private def openCodeFixture : String :=
  "{\"info\":{\"id\":\"ses_fixture\",\"slug\":\"fixture\",\"projectID\":\"global\",\"directory\":\"/tmp/project\",\"title\":\"Fixture\",\"version\":\"1.1.34\",\"time\":{\"created\":1000,\"updated\":1002}},\"messages\":[{\"info\":{\"id\":\"msg_user\",\"sessionID\":\"ses_fixture\",\"role\":\"user\",\"time\":{\"created\":1000},\"agent\":\"build\",\"model\":{\"providerID\":\"openai\",\"modelID\":\"gpt-5\"}},\"parts\":[{\"id\":\"prt_user\",\"sessionID\":\"ses_fixture\",\"messageID\":\"msg_user\",\"type\":\"text\",\"text\":\"hello\"}]},{\"info\":{\"id\":\"msg_assistant\",\"sessionID\":\"ses_fixture\",\"role\":\"assistant\",\"time\":{\"created\":1001,\"completed\":1002},\"parentID\":\"msg_user\",\"modelID\":\"gpt-5\",\"providerID\":\"openai\",\"mode\":\"build\",\"agent\":\"build\",\"path\":{\"cwd\":\"/tmp/project\",\"root\":\"/tmp/project\"},\"cost\":0,\"tokens\":{\"input\":0,\"output\":0,\"reasoning\":0,\"cache\":{\"read\":0,\"write\":0}},\"finish\":\"stop\"},\"parts\":[{\"id\":\"prt_reason\",\"sessionID\":\"ses_fixture\",\"messageID\":\"msg_assistant\",\"type\":\"reasoning\",\"text\":\"think\",\"time\":{\"start\":1001}},{\"id\":\"prt_tool\",\"sessionID\":\"ses_fixture\",\"messageID\":\"msg_assistant\",\"type\":\"tool\",\"callID\":\"call_1\",\"tool\":\"bash\",\"state\":{\"status\":\"completed\",\"input\":{\"command\":\"pwd\"},\"output\":\"/tmp/project\",\"title\":\"pwd\",\"metadata\":{},\"time\":{\"start\":1001,\"end\":1002}}},{\"id\":\"prt_text\",\"sessionID\":\"ses_fixture\",\"messageID\":\"msg_assistant\",\"type\":\"text\",\"text\":\"done\"}]}]}"

def openCodeImportExportFixturePasses : Bool :=
  match importOpenCode openCodeFixture with
  | .error _ => false
  | .ok transcript =>
      transcript.entries.size == 4 &&
      transcript.env.sessionId == some "ses_fixture" &&
      (match exportOpenCodeChecked transcript with
       | .error _ => false
       | .ok output => match importOpenCode output with
         | .error _ => false
         | .ok restored => restored.entries.size == 4)

example : openCodeImportExportFixturePasses = true := by native_decide

end LoomConvert
