import LoomConvert.Parity

/-!
# LoomConvert.CursorIde — the Cursor IDE importer (richest source of the seven)

Ports the `convert-to-pi cursor` reader (`utils/src/pi/cursor.ts`,
`importCursorChatToPi`) to Lean, producing the Loom IR from Cursor's
composer + bubble records. Census-grounded against
`Loom/Formats/CursorIde.lean` (the 2026-07-06 census of the live
`state.vscdb`, 400,418 cursorDiskKV rows).

## ACTUATOR SCOPE (this cut is importer LOGIC only, JSON → IR)

Cursor's true source is a **SQLite** database (`state.vscdb`, `cursorDiskKV`
table: `composerData:<id>` + `bubbleId:<composerId>:<bubbleId>` records).
Reading it is a *separable, thin actuator*, now built as
`LoomConvert.CursorIdeActuator`. This importer operates on a JSON REPRESENTATION
of exactly what that actuator extracts:

```
{ "composer": { "composerId": …, … },
  "workspaceIdentifier": { "uri": { "fsPath": … } }, // optional enrichment
  "bubbles":  [ { "bubbleId", "type", "text", "thinking", "toolFormerData", … }, … ] }
```

`bubbles` may be pre-ordered, but recorded headers remain authoritative. The
importer resolves each header only against unique id/type evidence and retains
missing or ambiguous slots as inert events. This file owns the IR-building
logic; `CursorIdeActuator.lean` owns sqlite extraction.

## Mapping (matches cursor.ts `importCursorChatToPi`)

* `composer.workspaceIdentifier.uri.fsPath`, falling back to the enriched
  envelope `workspaceIdentifier.uri.fsPath`, → `EnvInfo.cwd`; `composerId` →
  transcript `Origin.rawId` + `EnvInfo.sessionId`.  (cursor.ts mints a *new*
  random pi session id and stashes the composerId in `cursorExtras`; Loom
  keeps the real identity in `Origin`, which is strictly more faithful.)
* bubble `type` int enum: `1` → `Payload.userMsg`, `2` →
  `Payload.assistantMsg`; any other → inert raw `MetaEvent.custom`.
* `bubble.text` → `UserBlock.text` (type 1) / `AssistantBlock.text` (type 2).
* `bubble.thinking.{text, signature}` → `AssistantBlock.thinking text (some signature)`.
  cursor.ts drops the signature (pi's Block has no signature field, it goes to
  `cursorExtras.thinkingSignature`); Loom carries it **in the block** — Cursor
  IDE natively records it. This is the L12 "leanCore is strictly better"
  divergence noted in `LoomConvert.Parity`.
* Only assistant `toolFormerData` with a valid numeric `tool` yields a tool
  call. Metadata shells remain unmodeled. A source-recorded result yields a
  following positional environment result; non-string JSON stays exact in an
  unmodeled result block. Result-less records remain open calls, even with a
  terminal status, so no successful output is invented.
  Valid native `toolCallId` strings are copied exactly, including duplicates;
  absent or null ids remain absent because positional `CallRef`s provide local
  linkage. Empty or non-string ids make the local bubble inert rather than
  becoming executable anonymous/empty-id calls.
* Numeric epoch-ms and exactly representable UTC `createdAt` strings become
  `Time.recorded`; malformed timestamps are rejected rather than erased.
* Every entry carries the complete source bubble in `Origin.extras.rawBubble`;
  the transcript carries the exact envelope/composer. Usage, model, media
  extensions, branch metadata, and additive fields therefore remain auditable.
* `fullConversationHeadersOnly` determines active order when present. Missing,
  duplicate, mismatched, and malformed slots are refused locally as inert raw
  events; valid neighbors remain readable and the IR remains well-formed.
  Without usable headers, supplied order carries an `activeLeafGuessed` note.

## Remaining actuator work

1. **sqlite actuator** — DONE. Built as `LoomConvert.CursorIdeActuator`
   (`readCursorIdeStore` / `importCursorIdeFromStore`): a `sqlite3` subprocess
   that reads `composerData:<id>` + `bubbleId:<composerId>:<bubbleId>` out of
   `state.vscdb` into the JSON shape above, mirroring `openStateDbReadonly` /
   `fetchComposer` / the per-bubble `SELECT` loop in `cursor.ts`. (A `libsqlite3`
   FFI would remove the subprocess for a shipped binary.)
2. **cross-parity** — DONE (RC1; the last of the seven formats to cross-validate).
   A decide-pin against `convert-to-pi cursor` now exists
   (`crossParityOkWith importCursorIde cursorIdeCase1`, below). The synthetic
   `spec/loom/test.vscdb` store is read by the sqlite actuator into
   `cursorIdeParityInput`, and its `normalize` projection is pinned equal to the
   golden captured from `convert-to-pi cursor --chat-id cmp-fix --state-db-path
   test.vscdb` (`importCursorChatToPi`, `src/pi/cursor.ts`).
3. **branching / best-of-N** — the recorded active path is validated and
   imported; branch metadata is retained exactly with a typed note. Off-path
   bubble bodies are outside this extracted JSON input and remain actuator work.
4. **subagent inlining** — tool enum 48 (`dispatch_subagent`) spawns child
   composers (`subagentComposerIds` + `subagentInfo`); cursor.ts inlines them
   as bracketed sidechains up to `--max-subagent-depth`. Loom can represent
   these first-class as `ThreadKind.sidechain` anchored to the spawning
   `CallRef`; not built in this cut.
-/

namespace LoomConvert
open Loom
open Lean (Json)

/-! ## Small Json accessors (Except → Option), copied from the Pi.lean scaffold. -/

private def ostr (j : Json) (k : String) : Option String :=
  (j.getObjVal? k >>= Json.getStr?).toOption

private def oobj (j : Json) (k : String) : Option Json :=
  (j.getObjVal? k).toOption

private def hasKey (j : Json) (k : String) : Bool :=
  (j.getObjVal? k).toOption.isSome

private def field? (j : Json) (k : String) : Option Json :=
  (j.getObjVal? k).toOption

private def requireObjectField (ctx : String) (j : Json) (k : String) : Except String Json :=
  match j.getObjVal? k with
  | .ok value@(Json.obj _) => pure value
  | .ok _ => throw s!"{ctx}.{k}: expected object"
  | .error _ => throw s!"{ctx}.{k}: missing required object"

private def optionalObjectField (ctx : String) (j : Json) (k : String) : Except String (Option Json) :=
  match j.getObjVal? k with
  | .ok Json.null => pure none
  | .ok value@(Json.obj _) => pure (some value)
  | .ok _ => throw s!"{ctx}.{k}: expected object when present"
  | .error _ => pure none

private def requireArrayField (ctx : String) (j : Json) (k : String) : Except String (Array Json) :=
  match j.getObjVal? k with
  | .ok (Json.arr values) => pure values
  | .ok _ => throw s!"{ctx}.{k}: expected array"
  | .error _ => throw s!"{ctx}.{k}: missing required array"

private def optionalArrayField (ctx : String) (j : Json) (k : String) : Except String (Array Json) :=
  match j.getObjVal? k with
  | .ok Json.null => pure #[]
  | .ok (Json.arr values) => pure values
  | .ok _ => throw s!"{ctx}.{k}: expected array when present"
  | .error _ => pure #[]

private def requireStringField (ctx : String) (j : Json) (k : String) : Except String String :=
  match j.getObjVal? k with
  | .ok (Json.str value) => pure value
  | .ok _ => throw s!"{ctx}.{k}: expected string"
  | .error _ => throw s!"{ctx}.{k}: missing required string"

private def requireNonemptyStringField (ctx : String) (j : Json) (k : String) : Except String String := do
  let value ← requireStringField ctx j k
  if value.isEmpty then throw s!"{ctx}.{k}: must be non-empty"
  pure value

private def optionalStringField (ctx : String) (j : Json) (k : String) : Except String (Option String) :=
  match j.getObjVal? k with
  | .ok Json.null => pure none
  | .ok (Json.str value) => pure (some value)
  | .ok _ => throw s!"{ctx}.{k}: expected string when present"
  | .error _ => pure none

private def requireNatField (ctx : String) (j : Json) (k : String) : Except String Nat :=
  match j.getObjVal? k with
  | .ok value =>
      match value.getNat? with
      | .ok n => pure n
      | .error _ => throw s!"{ctx}.{k}: expected non-negative integer"
  | .error _ => throw s!"{ctx}.{k}: missing required integer"

private def optionalNatField (ctx : String) (j : Json) (k : String) : Except String (Option Nat) :=
  match j.getObjVal? k with
  | .ok Json.null => pure none
  | .ok value =>
      match value.getNat? with
      | .ok n => pure (some n)
      | .error _ => throw s!"{ctx}.{k}: expected non-negative integer when present"
  | .error _ => pure none

/-- `workspaceIdentifier.uri.fsPath`, with no path synthesis. -/
private def parseWorkspacePath (ctx : String) (workspace : Json) : Except String (Option String) := do
  match ← optionalObjectField ctx workspace "uri" with
  | none => pure none
  | some uri => optionalStringField s!"{ctx}.uri" uri "fsPath"

/-- Prefer the historical `composer.workspaceIdentifier`; when it is absent,
accept the actuator-enriched top-level `workspaceIdentifier` copied from the
matching global composer header. -/
private def parsePath (envelope composer : Json) : Except String (Option String) := do
  match ← optionalObjectField "composer" composer "workspaceIdentifier" with
  | some workspace => parseWorkspacePath "composer.workspaceIdentifier" workspace
  | none =>
      match ← optionalObjectField "importCursorIde" envelope "workspaceIdentifier" with
      | some workspace => parseWorkspacePath "importCursorIde.workspaceIdentifier" workspace
      | none => pure none

/-! ## Per-entry construction helpers. -/

private def rawBubbleOrigin (sref : String) (rawId : Option String) (bubble : Json) : Loom.Origin :=
  { format := Loom.Format.cursorIde, sourceRef := sref, rawId := rawId,
    extras := some (Json.mkObj [("rawBubble", bubble)]) }

/-- Linear thread: parent = previous entry index (`none` for the first entry). -/
private def parentOf (idx : Nat) : Option Nat :=
  if idx = 0 then none else some (idx - 1)

/-- `createdAt` → `Time`. Numeric epoch-ms and exactly representable UTC ISO
strings become `recorded`; malformed, unsupported-precision, or absent values
are respectively rejected or remain `absent`; no clock value is fabricated. -/
private def parseTime (ctx : String) (b : Json) : Except String Loom.Time :=
  match b.getObjVal? "createdAt" with
  | .error _ | .ok Json.null => pure Loom.Time.absent
  | .ok value@(Json.num _) =>
      match value.getNat? with
      | .ok ms => pure (Loom.Time.recorded { ms := ms })
      | .error _ => throw s!"{ctx}.createdAt: expected non-negative epoch milliseconds"
  | .ok (Json.str value) =>
      match Loom.iso8601ToEpochMs? value with
      | some timestamp => pure (.recorded timestamp)
      | none => throw s!"{ctx}.createdAt: unsupported or malformed UTC timestamp"
  | .ok _ => throw s!"{ctx}.createdAt: expected epoch milliseconds or UTC string"

/-- `toolFormerData.rawArgs` (or `.params`) → argument Json, mirroring
cursor.ts `parseRawArgs` for strings while retaining future JSON values rather
than rejecting the surrounding bubble. -/
private def parseRawArgs (_ctx : String) : Option Json → Except String Json
  | some (Json.str s) => pure ((Json.parse s).toOption.getD (Json.mkObj [("_raw", Json.str s)]))
  | some Json.null => pure (Json.mkObj [])
  | some value@(Json.obj _) => pure value
  | some value@(Json.arr _) => pure value
  | some value => pure value
  | none => pure (Json.mkObj [])

private def cursorToolEnumToName : Nat → String
  | 0 => "update_current_step"
  | 9 => "codebase_search"
  | 11 => "delete_file"
  | 15 => "bash"
  | 18 => "web_search"
  | 19 => "mcp_call"
  | 30 => "read_lints"
  | 35 => "todo_write"
  | 38 => "edit"
  | 39 => "list_directory"
  | 40 => "read_file"
  | 41 => "grep"
  | 42 => "glob"
  | 43 => "create_plan"
  | 45 => "mcp_resource_read"
  | 48 => "dispatch_subagent"
  | 51 => "ask_question"
  | 52 => "switch_mode"
  | 57 => "web_fetch"
  | 62 => "await"
  | n => s!"cursor_tool_{n}"

private def cursorCanonicalName : String → Option Loom.CanonicalTool
  | "bash" | "run_terminal_command_v2" | "run_terminal_cmd" => some .bash
  | "read" | "read_file" | "read_file_v2" => some .read
  | "write" => some .write
  | "edit" | "search_replace" | "edit_file_v2" => some .edit
  | "apply_patch" => some .applyPatch
  | "grep" | "rg" | "ripgrep_raw_search" => some .grep
  | "glob" | "glob_file_search" => some .glob
  | "web_fetch" => some .webFetch
  | "web_search" => some .webSearch
  | "dispatch_subagent" | "task" | "task_v2" => some .agentSpawn
  | _ => none

private def cursorCanonicalTool (nativeName fallback : String) : Option Loom.CanonicalTool :=
  (cursorCanonicalName nativeName).orElse fun _ => cursorCanonicalName fallback

private def firstPresentField (j : Json) : List String → Option (String × Json)
  | [] => none
  | key :: rest =>
      match field? j key with
      | some value => some (key, value)
      | none => firstPresentField j rest

private def cursorMedia? (ctx : String) (raw : Json) : Except String (Option (String × String)) := do
  match raw with
  | Json.str locator =>
      if locator.isEmpty then throw s!"{ctx}: image locator must be non-empty"
      pure (some ("image", locator))
  | Json.obj _ =>
      match firstPresentField raw ["url", "uri", "path", "imageUrl", "data"] with
      | none => pure none
      | some (key, Json.str locator) =>
          if locator.isEmpty then throw s!"{ctx}.{key}: image locator must be non-empty"
          let mime ← optionalStringField ctx raw "mimeType"
          match mime with
          | some "" => throw s!"{ctx}.mimeType: must be non-empty when present"
          | _ => pure (some (mime.getD "image", locator))
      | some (key, _) => throw s!"{ctx}.{key}: expected string image locator"
  | _ => pure none

private def userImageBlocks (ctx : String) (b : Json) : Except String (List Loom.UserBlock) := do
  let images ← optionalArrayField ctx b "images"
  images.toList.zipIdx.mapM fun (raw, idx) => do
    match ← cursorMedia? s!"{ctx}.images[{idx}]" raw with
    | some (mime, locator) => pure (.media mime locator)
    | none => pure (.unmodeled "cursor_ide.image" raw)

private def assistantImageBlocks (ctx : String) (b : Json) : Except String (List Loom.AssistantBlock) := do
  let images ← optionalArrayField ctx b "images"
  images.toList.zipIdx.mapM fun (raw, idx) => do
    match ← cursorMedia? s!"{ctx}.images[{idx}]" raw with
    | some (mime, locator) => pure (.media mime locator)
    | none => pure (.unmodeled "cursor_ide.image" raw)

private def assistantThinkingBlocks (ctx : String) (b : Json) : Except String (List Loom.AssistantBlock) := do
  match ← optionalObjectField ctx b "thinking" with
  | none => pure []
  | some thinking =>
      let text? ← optionalStringField s!"{ctx}.thinking" thinking "text"
      let signature? ← optionalStringField s!"{ctx}.thinking" thinking "signature"
      let redacted? ← optionalStringField s!"{ctx}.thinking" thinking "redactedThinking"
      let primary := match text? with
        | some text => if text.isEmpty then [] else [.thinking text signature?]
        | none => []
      let redacted := match redacted? with
        | some text => if text.isEmpty then [] else [.thinking s!"[redacted] {text}" none]
        | none => []
      if primary.isEmpty && redacted.isEmpty then
        pure [.unmodeled "cursor_ide.thinking" thinking]
      else pure (primary ++ redacted)

private def mkEntry (parent : Option Nat) (time : Loom.Time)
    (payload : Loom.Payload) (origin : Loom.Origin) : Loom.Entry :=
  { parent := parent, thread := 0, time := time, payload := payload, origin := origin }

private def cursorNote (kind : Loom.AssumptionKind) (loc detail : String) : Loom.ImportNote :=
  { kind, loc := some loc, detail }

private inductive CursorToolFormerData where
  | absent
  | metadata (raw : Json) (reason : String)
  | executable (raw : Json) (toolEnum : Nat)

/-- Only a JSON object with a valid numeric enum is executable. Cursor also
stores metadata-only shells such as `{additionalData:{status:"error"}}`; those
must not become tool calls merely because the field exists. -/
private def classifyToolFormerData (b : Json) : CursorToolFormerData :=
  match field? b "toolFormerData" with
  | none | some Json.null => .absent
  | some tf@(Json.obj _) =>
      match field? tf "tool" with
      | some value =>
          match value.getNat? with
          | .ok toolEnum => .executable tf toolEnum
          | .error _ => .metadata tf "tool is not a non-negative integer"
      | none => .metadata tf "numeric tool discriminator is absent"
  | some raw => .metadata raw "toolFormerData is not an object"

private def cursorResultContent (raw : Json) : List Loom.UserBlock :=
  match raw with
  | Json.str text => [.text text]
  | other => [.unmodeled "cursor_ide.tool_result" other]

private structure CursorBubbleImport where
  entries : List Loom.Entry
  notes : List Loom.ImportNote := []
  nativeToolCallId : Option String := none

/-- One bubble → the IR entries it contributes, given the absolute index
`startIdx` at which the first lands. Every valid bubble yields at least one
entry; a terminal tool bubble with recorded result data yields two. -/
private def bubbleEntries (startIdx sourceIdx : Nat)
    (b : Json) : Except String CursorBubbleImport := do
  let ctx := s!"bubbles[{sourceIdx}]"
  match b with
  | Json.obj _ => pure ()
  | _ => throw s!"{ctx}: expected object"
  let bubbleId ← requireNonemptyStringField ctx b "bubbleId"
  let bubbleType ← requireNatField ctx b "type"
  let time ← parseTime ctx b
  let text? ← optionalStringField ctx b "text"
  let sourceRef := s!"bubble:{bubbleId}"
  let origin := rawBubbleOrigin sourceRef (some bubbleId) b
  match bubbleType with
  | 1 =>
      match field? b "thinking" with
      | some value => if value != Json.null then
          throw s!"{ctx}.thinking: user bubble cannot carry assistant thinking"
      | none => pure ()
      let images ← userImageBlocks ctx b
      let textBlocks := match text? with
        | some text => if text.isEmpty then [] else [Loom.UserBlock.text text]
        | none => []
      let mut blocks := textBlocks ++ images
      let mut notes : Array Loom.ImportNote := #[]
      match classifyToolFormerData b with
      | .absent => pure ()
      | .metadata raw reason =>
          blocks := blocks ++ [.unmodeled "cursor_ide.toolFormerData.metadata" raw]
          notes := notes.push (cursorNote (.other "cursorIdeToolMetadataOnly") sourceRef
            s!"retained non-executable user toolFormerData: {reason}")
      | .executable raw toolEnum =>
          blocks := blocks ++ [.unmodeled "cursor_ide.toolFormerData.user" raw]
          notes := notes.push (cursorNote (.other "cursorIdeUserToolData") sourceRef
            s!"refused to execute tool enum {toolEnum} from a user-authored bubble; retained it as unmodeled data")
      pure { entries := [mkEntry (parentOf startIdx) time
        (.userMsg blocks) origin], notes := notes.toList }
  | 2 =>
      let thinking ← assistantThinkingBlocks ctx b
      let images ← assistantImageBlocks ctx b
      let textBlocks := match text? with
        | some text => if text.isEmpty then [] else [Loom.AssistantBlock.text text]
        | none => []
      let preBlocks := thinking ++ textBlocks ++ images
      match classifyToolFormerData b with
      | .absent =>
          pure { entries := [mkEntry (parentOf startIdx) time (.assistantMsg preBlocks) origin] }
      | .metadata raw reason =>
          let note := cursorNote (.other "cursorIdeToolMetadataOnly") sourceRef
            s!"retained non-executable assistant toolFormerData: {reason}"
          let metadataBlock := Loom.AssistantBlock.unmodeled
            "cursor_ide.toolFormerData.metadata" raw
          let entry := mkEntry (parentOf startIdx) time
            (.assistantMsg (preBlocks ++ [metadataBlock])) origin
          pure { entries := [entry], notes := [note] }
      | .executable tf toolEnum =>
          let tfCtx := s!"{ctx}.toolFormerData"
          let fallbackName := cursorToolEnumToName toolEnum
          let mut notes : Array Loom.ImportNote := #[]
          let nativeName? ← match field? tf "name" with
            | none | some Json.null => pure none
            | some (Json.str "") =>
                notes := notes.push (cursorNote (.other "cursorIdeMalformedToolName") sourceRef
                  "empty native tool name ignored; numeric enum remains authoritative")
                pure none
            | some (Json.str name) => pure (some name)
            | some _ =>
                notes := notes.push (cursorNote (.other "cursorIdeMalformedToolName") sourceRef
                  "non-string native tool name ignored; numeric enum remains authoritative")
                pure none
          let rawName := nativeName?.getD fallbackName
          let canonical := cursorCanonicalTool rawName fallbackName
          let argsSource := match field? tf "rawArgs" with
            | some value => some value
            | none => field? tf "params"
          let args ← parseRawArgs s!"{tfCtx}.rawArgs" argsSource
          let _toolIndex? ← match field? tf "toolIndex" with
            | none | some Json.null => pure none
            | some value => match value.getNat? with
              | .ok index => pure (some index)
              | .error _ =>
                  notes := notes.push (cursorNote (.other "cursorIdeMalformedToolIndex") sourceRef
                    "non-numeric toolIndex ignored")
                  pure none
          let nativeCallId? ← optionalStringField tfCtx tf "toolCallId"
          match nativeCallId? with
          | some "" => throw s!"{tfCtx}.toolCallId: must be non-empty when present"
          | _ => pure ()
          if nativeName?.isNone then
            notes := notes.push (cursorNote .toolNameMapped sourceRef
              s!"interpreted Cursor tool enum {toolEnum} as '{fallbackName}'")
          let result? := match field? tf "result" with
            | none | some Json.null => none
            | some raw => some raw
          let status? ← match field? tf "status" with
            | none | some Json.null => pure none
            | some (Json.str status) => pure (some status)
            | some _ =>
                notes := notes.push (cursorNote (.other "cursorIdeMalformedToolStatus") sourceRef
                  "non-string status retained only in raw provenance; error state is unrecorded")
                pure none
          let mut resultSpec : Option (List Loom.UserBlock × Loom.ErrorSignal) := none
          match status? with
          | some "completed" =>
              match result? with
              | some result => resultSpec := some (cursorResultContent result, .native false)
              | none => notes := notes.push (cursorNote (.other "cursorIdeTerminalWithoutResult") sourceRef
                  "completed tool has no recorded result; retained as an open call without fabricating success output")
          | some "error" | some "cancelled" =>
              match result? with
              | some result => resultSpec := some (cursorResultContent result, .native true)
              | none => notes := notes.push (cursorNote (.other "cursorIdeTerminalWithoutResult") sourceRef
                  "error/cancelled tool has no recorded result; retained as an open call with terminal state in raw provenance")
          | some "loading" =>
              notes := notes.push (cursorNote (.other "cursorIdePendingTool") sourceRef
                "tool status is loading; retained as an open call without a result")
              if result?.isSome then
                notes := notes.push (cursorNote (.other "cursorIdePartialToolResult") sourceRef
                  "loading tool carried provisional result data; kept only in raw provenance")
          | none =>
              match result? with
              | some result =>
                  resultSpec := some (cursorResultContent result, .unrecorded)
                  notes := notes.push (cursorNote (.other "errorUnrecorded") sourceRef
                    "tool result exists but status is absent; error provenance is unrecorded")
              | none => notes := notes.push (cursorNote (.other "cursorIdePendingTool") sourceRef
                  "tool has neither terminal status nor result; retained as an open call")
          | some status =>
              match result? with
              | some result =>
                  resultSpec := some (cursorResultContent result, .unrecorded)
                  notes := notes.push (cursorNote (.other "cursorIdeUnknownToolStatus") sourceRef
                    s!"unknown status '{status}'; result retained with unrecorded error provenance")
              | none => notes := notes.push (cursorNote (.other "cursorIdePendingTool") sourceRef
                  s!"unknown nonterminal status '{status}'; retained as an open call")
          let callIdx := preBlocks.length
          let callBlock := Loom.AssistantBlock.toolCall
            { raw := rawName, canonical } args nativeCallId?
          let callEntry := mkEntry (parentOf startIdx) time
            (.assistantMsg (preBlocks ++ [callBlock])) origin
          match resultSpec with
          | none => pure { entries := [callEntry], notes := notes.toList,
                           nativeToolCallId := nativeCallId? }
          | some (result, error) =>
              if result.any (fun block => match block with
                  | .unmodeled "cursor_ide.tool_result" _ => true
                  | _ => false) then
                notes := notes.push (cursorNote (.other "cursorIdeStructuredToolResult") sourceRef
                  "retained non-string tool result as an exact unmodeled result block")
              let resultBlock := Loom.EnvBlock.toolResult
                (.resolved startIdx callIdx) result error
              let resultOrigin := rawBubbleOrigin s!"{sourceRef}#result"
                nativeCallId? b
              notes := notes.push (cursorNote .roleCoerced sourceRef
                "Cursor colocates tool result data in an assistant bubble; Loom attributes it to the environment")
              pure { entries := [callEntry, mkEntry (some startIdx) time
                       (.envMsg [resultBlock]) resultOrigin],
                     notes := notes.toList,
                     nativeToolCallId := nativeCallId? }
  | other =>
      let label := s!"cursor_ide.bubble_type_{other}"
      let payload := Loom.Payload.event (Loom.MetaEvent.custom label b)
      let entry := mkEntry (parentOf startIdx) time payload origin
      let note := cursorNote (.other "cursorIdeUnmodeledBubble") sourceRef
        s!"retained unknown Cursor bubble type {other} as an inert raw event"
      pure { entries := [entry], notes := [note] }

private def bubbleDescriptor (idx : Nat) (b : Json) : Except String (String × Nat) := do
  let ctx := s!"bubbles[{idx}]"
  match b with
  | Json.obj _ => pure ()
  | _ => throw s!"{ctx}: expected object"
  pure (← requireNonemptyStringField ctx b "bubbleId", ← requireNatField ctx b "type")

private def headerDescriptor (idx : Nat) (h : Json) : Except String (String × Nat) := do
  let ctx := s!"composer.fullConversationHeadersOnly[{idx}]"
  match h with
  | Json.obj _ => pure ()
  | _ => throw s!"{ctx}: expected object"
  pure (← requireNonemptyStringField ctx h "bubbleId", ← requireNatField ctx h "type")

private structure CursorIdeImportState where
  entries : Array Loom.Entry := #[]
  notes : Array Loom.ImportNote := #[]
  /-- Source-native ids observed while walking selected bubbles. -/
  seenToolIds : List String := []

private def appendCursorBubble (state : CursorIdeImportState)
    (sourceIdx : Nat) (bubble : Json) : CursorIdeImportState :=
  match bubbleEntries state.entries.size sourceIdx bubble with
  | .error error =>
      let rawId := (ostr bubble "bubbleId").bind fun id => if id.isEmpty then none else some id
      let sourceRef := rawId.map (fun id => s!"bubble:{id}") |>.getD s!"bubbles[{sourceIdx}]"
      let entry := mkEntry (parentOf state.entries.size) Loom.Time.absent
        (.event (.custom "cursor_ide.malformed_bubble" bubble))
        (rawBubbleOrigin sourceRef rawId bubble)
      { state with
        entries := state.entries.push entry
        notes := state.notes.push (cursorNote (.other "cursorIdeMalformedBubble") sourceRef
          s!"refused local interpretation of malformed known bubble: {error}; retained exact raw event") }
  | .ok imported =>
      let notes := match imported.nativeToolCallId with
        | some nativeId =>
            if state.seenToolIds.contains nativeId then
              let sourceRef := (ostr bubble "bubbleId").map (fun id => s!"bubble:{id}")
                |>.getD s!"bubbles[{sourceIdx}]"
              state.notes.push (cursorNote (.other "cursorIdeDuplicateToolCallId") sourceRef
                s!"duplicate native tool-call id '{nativeId}' preserved exactly in ToolCall.rawId; colocated positional result linkage remains unambiguous")
            else state.notes
        | none => state.notes
      let seenToolIds := match imported.nativeToolCallId with
        | some nativeId => nativeId :: state.seenToolIds
        | none => state.seenToolIds
      { entries := state.entries ++ imported.entries.toArray,
        notes := notes ++ imported.notes.toArray,
        seenToolIds }

private def appendActiveRefusal (state : CursorIdeImportState) (sourceRef : String)
    (rawId : Option String) (label noteLabel detail : String) (raw : Json) : CursorIdeImportState :=
  let origin : Loom.Origin := {
    format := .cursorIde, sourceRef, rawId,
    extras := some (Json.mkObj [("rawActiveSlot", raw)])
  }
  let entry := mkEntry (parentOf state.entries.size) Loom.Time.absent
    (.event (.custom label raw)) origin
  { state with
    entries := state.entries.push entry
    notes := state.notes.push (cursorNote (.other noteLabel) sourceRef detail) }

/-- JSON representation of an extracted Cursor IDE chat → Loom IR.

The linear walk resolves each active header only when its id is unique and its
row/type agree. Missing, duplicated, mismatched, and malformed slots become
inert raw events with refusal notes; neighboring readable history still imports.
`entries.size` supplies the running absolute index so parents and tool-result
`CallRef`s stay positional. -/
def importCursorIde (text : String) : Except String Loom.Transcript := do
  let j ← Json.parse text
  match j with
  | Json.obj _ => pure ()
  | _ => throw "importCursorIde: expected object envelope"
  let composer ← requireObjectField "importCursorIde" j "composer"
  let composerId ← requireNonemptyStringField "composer" composer "composerId"
  let cwd ← parsePath j composer
  let bubbles ← requireArrayField "importCursorIde" j "bubbles"
  let mut notes : Array Loom.ImportNote := #[]
  if hasKey composer "branches" || hasKey composer "isBestOfNParent" ||
      hasKey composer "bestOfNJudgeWinner" ||
      bubbles.toList.any (fun b => hasKey b "branches" || hasKey b "isBestOfNParent" ||
        hasKey b "bestOfNJudgeWinner") then
    notes := notes.push (cursorNote (.other "cursorIdeBranchMetadata") "composer"
      "preserved branch/best-of-N metadata in exact raw provenance while importing the recorded active path")
  let mut state : CursorIdeImportState := { notes }
  let mut usedBubbleIndices : List Nat := []
  match field? composer "fullConversationHeadersOnly" with
  | none | some Json.null =>
      state := { state with notes := state.notes.push (cursorNote .activeLeafGuessed "composer"
        "fullConversationHeadersOnly is absent; trusted supplied bubble order as the active path") }
      for (bubble, sourceIdx) in bubbles.zipIdx do
        let duplicateCount := (bubbles.toList.filter fun candidate =>
          match ostr bubble "bubbleId" with
          | some id => !id.isEmpty && ostr candidate "bubbleId" == some id
          | none => false).length
        if duplicateCount > 1 then
          let sourceRef := (ostr bubble "bubbleId").map (fun id => s!"bubble:{id}")
            |>.getD s!"bubbles[{sourceIdx}]"
          let note := cursorNote (.other "cursorIdeDuplicateBubbleId") sourceRef
            "duplicate bubble id retained in explicit supplied order; identity is ambiguous but no id-based linkage is performed"
          state := { state with notes := state.notes.push note }
        state := appendCursorBubble state sourceIdx bubble
        usedBubbleIndices := sourceIdx :: usedBubbleIndices
  | some (Json.arr headers) =>
      state := { state with notes := state.notes.push (cursorNote (.other "cursorIdeActivePath") "composer"
        "resolved each fullConversationHeadersOnly slot only against unique matching bubble evidence") }
      let validHeaderDescriptors := headers.toList.zipIdx.filterMap fun (header, idx) =>
        (headerDescriptor idx header).toOption
      for (header, headerIdx) in headers.zipIdx do
        match headerDescriptor headerIdx header with
        | .error error =>
            state := appendActiveRefusal state s!"composer.fullConversationHeadersOnly[{headerIdx}]"
              none "cursor_ide.active_header_malformed" "cursorIdeMalformedActiveHeader"
              s!"refused malformed active header locally: {error}" header
        | .ok descriptor =>
            let bubbleId := descriptor.1
            let sourceRef := s!"header:{bubbleId}"
            let duplicateHeaders := validHeaderDescriptors.countP (fun item => item.1 == bubbleId)
            if duplicateHeaders > 1 then
              state := appendActiveRefusal state sourceRef (some bubbleId)
                "cursor_ide.active_header_ambiguous" "cursorIdeAmbiguousActiveHeader"
                s!"bubble id '{bubbleId}' appears {duplicateHeaders} times in active headers; refused to choose a body" header
            else
              let candidates := bubbles.toList.zipIdx.filter fun (bubble, _) =>
                ostr bubble "bubbleId" == some bubbleId
              match candidates with
              | [] =>
                  state := appendActiveRefusal state sourceRef (some bubbleId)
                    "cursor_ide.active_header_missing_bubble" "cursorIdeMissingActiveBubble"
                    s!"active header references missing bubble row '{bubbleId}'" header
              | [(bubble, sourceIdx)] =>
                  usedBubbleIndices := sourceIdx :: usedBubbleIndices
                  match bubbleDescriptor sourceIdx bubble with
                  | .ok actual =>
                      if actual == descriptor then
                        state := appendCursorBubble state sourceIdx bubble
                      else
                        let raw := Json.mkObj [("header", header), ("bubble", bubble)]
                        state := appendActiveRefusal state sourceRef (some bubbleId)
                          "cursor_ide.active_header_type_mismatch" "cursorIdeActiveHeaderTypeMismatch"
                          s!"active header type {descriptor.2} disagrees with bubble type {actual.2}; refused interpretation" raw
                  | .error error =>
                      let raw := Json.mkObj [("header", header), ("bubble", bubble)]
                      state := appendActiveRefusal state sourceRef (some bubbleId)
                        "cursor_ide.active_header_malformed_bubble" "cursorIdeMalformedActiveBubble"
                        s!"matching bubble is malformed; refused interpretation locally: {error}" raw
              | candidates =>
                  let raw := Json.mkObj [("header", header),
                    ("candidateBubbles", Json.arr (candidates.map (fun candidate => candidate.1)).toArray)]
                  state := appendActiveRefusal state sourceRef (some bubbleId)
                    "cursor_ide.active_header_ambiguous" "cursorIdeAmbiguousActiveHeader"
                    s!"active header has {candidates.length} candidate bubble rows for id '{bubbleId}'; refused to choose" raw
  | some _ =>
      let malformedNote := cursorNote (.other "cursorIdeMalformedActiveHeaders") "composer"
        "fullConversationHeadersOnly is not an array; retained it in raw provenance and trusted supplied bubble order"
      let guessedNote := cursorNote .activeLeafGuessed "composer"
        "malformed fullConversationHeadersOnly cannot record a path; trusted supplied bubble order"
      state := { state with notes := (state.notes.push malformedNote).push guessedNote }
      for (bubble, sourceIdx) in bubbles.zipIdx do
        state := appendCursorBubble state sourceIdx bubble
        usedBubbleIndices := sourceIdx :: usedBubbleIndices
  let unselectedCount := bubbles.size - usedBubbleIndices.length
  if unselectedCount > 0 then
    state := { state with notes := state.notes.push (cursorNote (.other "cursorIdeUnselectedBubbles") "bubbles"
      s!"{unselectedCount} supplied bubble row(s) were not uniquely selected by the recorded active path; retained in raw envelope provenance") }
  let transcriptOrigin : Loom.Origin := {
    format := Loom.Format.cursorIde,
    sourceRef := "importCursorIde",
    rawId := some composerId,
    extras := some (Json.mkObj [("rawEnvelope", j), ("rawComposer", composer)])
  }
  let transcript : Loom.Transcript := {
    threads := #[{ kind := Loom.ThreadKind.main }],
    entries := state.entries,
    env := { cwd, sessionId := some composerId },
    activeLeaf := if state.entries.isEmpty then none else some (state.entries.size - 1),
    importNotes := state.notes.toList,
    origin := transcriptOrigin
  }
  if !(Loom.violations transcript).isEmpty then
    throw "importCursorIde: importer produced structurally invalid transcript"
  pure transcript

/-! ## Structure-only fixture (the JSON REPRESENTATION the actuator would emit).

Two bubbles: a user turn, then an assistant tool turn carrying text + signed
thinking + a `toolFormerData` (status `completed`). Exercises every mapping:
cwd, both roles, text, thinking-with-signature, tool call + split tool result,
tokenCount/model → extras, and numeric `createdAt` → `Time.recorded`. -/
def cursorIdeFixture : String :=
  "{\"composer\":{\"composerId\":\"cmp-7f3a\"," ++
  "\"workspaceIdentifier\":{\"uri\":{\"fsPath\":\"/Users/dev/proj\"}}," ++
  "\"fullConversationHeadersOnly\":[{\"bubbleId\":\"b0\",\"type\":1},{\"bubbleId\":\"b1\",\"type\":2}]}," ++
  "\"bubbles\":[" ++
  "{\"type\":1,\"bubbleId\":\"b0\",\"text\":\"hi cursor\"}," ++
  "{\"type\":2,\"bubbleId\":\"b1\",\"text\":\"on it\",\"createdAt\":1720000000000," ++
  "\"thinking\":{\"text\":\"let me think\",\"signature\":\"SIG123\"}," ++
  "\"tokenCount\":{\"inputTokens\":10,\"outputTokens\":20}," ++
  "\"modelInfo\":{\"modelName\":\"claude-x\"}," ++
  "\"toolFormerData\":{\"tool\":38,\"name\":\"search_replace\",\"toolCallId\":\"tc-1\"," ++
  "\"rawArgs\":{\"file_path\":\"a.txt\",\"old_string\":\"x\",\"new_string\":\"y\"}," ++
  "\"result\":\"edit applied\",\"status\":\"completed\"}}" ++
  "]}"

example :
    (match importCursorIde cursorIdeFixture with
     | .ok t => t.entries.size == 3 && (Loom.violations t).isEmpty
     | .error _ => false) = true := by native_decide

private def cursorIdeSingleBubble (bubbleType : Nat) (bubble : String) : String :=
  "{\"composer\":{\"composerId\":\"cmp-test\",\"fullConversationHeadersOnly\":[" ++
  "{\"bubbleId\":\"b\",\"type\":" ++ toString bubbleType ++ "}" ++
  "]},\"bubbles\":[" ++ bubble ++ "]}"

private def cursorIdeRejects (text : String) : Bool :=
  match importCursorIde text with
  | .error _ => true
  | .ok _ => false

private def cursorIdeHasOtherNote (transcript : Loom.Transcript) (label : String) : Bool :=
  transcript.importNotes.any fun note =>
    match note.kind with
    | .other actual => actual == label
    | _ => false

private def cursorIdeHasKind (transcript : Loom.Transcript) (kind : Loom.AssumptionKind) : Bool :=
  transcript.importNotes.any fun note => decide (note.kind = kind)

/-- `loading` with no result is an open call, not a fabricated successful empty
result. The exact source status remains in `rawBubble` provenance. -/
def cursorIdePendingToolIsCallOnly : Bool :=
  let source := cursorIdeSingleBubble 2
    "{\"type\":2,\"bubbleId\":\"b\",\"createdAt\":1720000000000,\"toolFormerData\":{\"tool\":15,\"name\":\"future-terminal-name\",\"toolCallId\":\"open-1\",\"rawArgs\":{},\"status\":\"loading\"}}"
  match importCursorIde source with
  | .ok transcript =>
      match transcript.entries.toList with
      | [entry] =>
          match entry.payload, entry.origin.extras with
          | .assistantMsg [.toolCall name _ (some "open-1")], some extras =>
              name.raw == "future-terminal-name" && decide (name.canonical = some .bash) &&
              cursorIdeHasOtherNote transcript "cursorIdePendingTool" &&
              (oobj extras "rawBubble").bind (fun raw =>
                (oobj raw "toolFormerData").bind (fun tf => ostr tf "status")) == some "loading"
          | _, _ => false
      | _ => false
  | .error _ => false

example : cursorIdePendingToolIsCallOnly = true := by native_decide

/-- Envelope identity and container shape are boundary-level invariants.
Malformed rows inside a readable envelope are localized as inert events. -/
def cursorIdeMalformedKnownShapesRejected : Bool :=
  [
    "{}",
    "{\"composer\":null,\"bubbles\":[]}",
    "{\"composer\":{\"composerId\":\"\"},\"bubbles\":[{}]}",
    "{\"composer\":{\"composerId\":\"c\"},\"bubbles\":{}}"
  ].all cursorIdeRejects

example : cursorIdeMalformedKnownShapesRejected = true := by native_decide

/-- A malformed known row is refused locally as an inert exact event. Valid
neighbors remain role-typed and the resulting active chain stays well-formed. -/
def cursorIdeMalformedBubbleIsLocalized : Bool :=
  let source :=
    "{\"composer\":{\"composerId\":\"local\",\"fullConversationHeadersOnly\":[" ++
    "{\"bubbleId\":\"u\",\"type\":1},{\"bubbleId\":\"bad\",\"type\":1},{\"bubbleId\":\"a\",\"type\":2}]}," ++
    "\"bubbles\":[{\"type\":2,\"bubbleId\":\"a\",\"text\":\"after\"}," ++
    "{\"type\":1,\"bubbleId\":\"bad\",\"text\":7}," ++
    "{\"type\":1,\"bubbleId\":\"u\",\"text\":\"before\"}]}"
  match importCursorIde source with
  | .ok transcript =>
      match transcript.entries.toList with
      | [before, bad, after] =>
          match before.payload, bad.payload, after.payload with
          | .userMsg [.text "before"],
            .event (.custom "cursor_ide.malformed_bubble" raw),
            .assistantMsg [.text "after"] =>
              ostr raw "bubbleId" == some "bad" &&
                cursorIdeHasOtherNote transcript "cursorIdeMalformedBubble" &&
                transcript.activeLeaf == some 2 && (Loom.violations transcript).isEmpty
          | _, _, _ => false
      | _ => false
  | .error _ => false

example : cursorIdeMalformedBubbleIsLocalized = true := by native_decide

/-- Metadata-only tool shells on either author remain unmodeled provenance and
never become executable calls or erase adjacent text. -/
def cursorIdeMetadataOnlyToolShellsAreInert : Bool :=
  let source :=
    "{\"composer\":{\"composerId\":\"metadata\",\"fullConversationHeadersOnly\":[" ++
    "{\"bubbleId\":\"u\",\"type\":1},{\"bubbleId\":\"a\",\"type\":2}]},\"bubbles\":[" ++
    "{\"type\":1,\"bubbleId\":\"u\",\"text\":\"user text\",\"toolFormerData\":{\"additionalData\":{\"status\":\"error\"}}}," ++
    "{\"type\":2,\"bubbleId\":\"a\",\"text\":\"assistant text\",\"toolFormerData\":{\"additionalData\":{\"status\":\"error\"}}}]}"
  match importCursorIde source with
  | .ok transcript =>
      match transcript.entries.toList with
      | [user, assistant] =>
          match user.payload, assistant.payload with
          | .userMsg [.text "user text", .unmodeled "cursor_ide.toolFormerData.metadata" userRaw],
            .assistantMsg [.text "assistant text", .unmodeled "cursor_ide.toolFormerData.metadata" assistantRaw] =>
              (oobj userRaw "additionalData").bind (fun data => ostr data "status") == some "error" &&
                (oobj assistantRaw "additionalData").bind (fun data => ostr data "status") == some "error" &&
                cursorIdeHasOtherNote transcript "cursorIdeToolMetadataOnly" &&
                (Loom.violations transcript).isEmpty
          | _, _ => false
      | _ => false
  | .error _ => false

example : cursorIdeMetadataOnlyToolShellsAreInert = true := by native_decide

/-- Corpus-shaped lifecycle cases: terminal calls without output remain open,
while object/number outputs are retained exactly and carry native status. -/
def cursorIdeTerminalAndStructuredResultsAreLossAware : Bool :=
  let source :=
    "{\"composer\":{\"composerId\":\"lifecycle\",\"fullConversationHeadersOnly\":[" ++
    "{\"bubbleId\":\"c0\",\"type\":2},{\"bubbleId\":\"c1\",\"type\":2}," ++
    "{\"bubbleId\":\"c2\",\"type\":2},{\"bubbleId\":\"c3\",\"type\":2}]},\"bubbles\":[" ++
    "{\"type\":2,\"bubbleId\":\"c0\",\"toolFormerData\":{\"tool\":15,\"status\":\"completed\"}}," ++
    "{\"type\":2,\"bubbleId\":\"c1\",\"toolFormerData\":{\"tool\":15,\"status\":\"error\"}}," ++
    "{\"type\":2,\"bubbleId\":\"c2\",\"toolFormerData\":{\"tool\":15,\"status\":\"completed\",\"result\":{\"stdout\":\"ok\",\"exitCode\":0}}}," ++
    "{\"type\":2,\"bubbleId\":\"c3\",\"toolFormerData\":{\"tool\":15,\"status\":\"error\",\"result\":7}}]}"
  match importCursorIde source with
  | .ok transcript =>
      match transcript.entries[0]?, transcript.entries[1]?, transcript.entries[3]?, transcript.entries[5]? with
      | some openCompleted, some openError, some objectResult, some numberResult =>
          match openCompleted.payload, openError.payload, objectResult.payload, numberResult.payload with
          | .assistantMsg [.toolCall _ _ _], .assistantMsg [.toolCall _ _ _],
            .envMsg [.toolResult (.resolved 2 0) [.unmodeled "cursor_ide.tool_result" objectRaw] (.native false)],
            .envMsg [.toolResult (.resolved 4 0) [.unmodeled "cursor_ide.tool_result" numberRaw] (.native true)] =>
              field? objectRaw "stdout" == some (Json.str "ok") &&
                numberRaw.getNat?.toOption == some 7 &&
                cursorIdeHasOtherNote transcript "cursorIdeTerminalWithoutResult" &&
                cursorIdeHasOtherNote transcript "cursorIdeStructuredToolResult" &&
                transcript.entries.size == 6 && (Loom.violations transcript).isEmpty
          | _, _, _, _ => false
      | _, _, _, _ => false
  | .error _ => false

example : cursorIdeTerminalAndStructuredResultsAreLossAware = true := by native_decide

/-- Active headers are authoritative for order, but duplicate ids and missing
rows are not guessed. Their slots survive as inert events between uniquely
resolved neighbors, including when the supplied bubble array is scrambled. -/
def cursorIdeMissingAndDuplicateActiveHeadersAreLocal : Bool :=
  let source :=
    "{\"composer\":{\"composerId\":\"active\",\"fullConversationHeadersOnly\":[" ++
    "{\"bubbleId\":\"u\",\"type\":1},{\"bubbleId\":\"missing\",\"type\":2}," ++
    "{\"bubbleId\":\"dup\",\"type\":2},{\"bubbleId\":\"dup\",\"type\":2}," ++
    "{\"bubbleId\":\"a\",\"type\":2}]},\"bubbles\":[" ++
    "{\"type\":2,\"bubbleId\":\"a\",\"text\":\"last\"}," ++
    "{\"type\":2,\"bubbleId\":\"dup\",\"text\":\"ambiguous\"}," ++
    "{\"type\":1,\"bubbleId\":\"u\",\"text\":\"first\"}]}"
  match importCursorIde source with
  | .ok transcript =>
      match transcript.entries.toList with
      | [first, missing, dup1, dup2, last] =>
          match first.payload, missing.payload, dup1.payload, dup2.payload, last.payload with
          | .userMsg [.text "first"],
            .event (.custom "cursor_ide.active_header_missing_bubble" missingRaw),
            .event (.custom "cursor_ide.active_header_ambiguous" firstDupRaw),
            .event (.custom "cursor_ide.active_header_ambiguous" secondDupRaw),
            .assistantMsg [.text "last"] =>
              ostr missingRaw "bubbleId" == some "missing" &&
                ostr firstDupRaw "bubbleId" == some "dup" &&
                ostr secondDupRaw "bubbleId" == some "dup" &&
                cursorIdeHasOtherNote transcript "cursorIdeMissingActiveBubble" &&
                cursorIdeHasOtherNote transcript "cursorIdeAmbiguousActiveHeader" &&
                cursorIdeHasOtherNote transcript "cursorIdeUnselectedBubbles" &&
                transcript.activeLeaf == some 4 && (Loom.violations transcript).isEmpty
          | _, _, _, _, _ => false
      | _ => false
  | .error _ => false

example : cursorIdeMissingAndDuplicateActiveHeadersAreLocal = true := by native_decide

/-- The enriched actuator envelope supplies a global-header workspace only when
the composer row lacks one; the historical composer-local field keeps priority. -/
def cursorIdeEnrichedWorkspaceFallback : Bool :=
  let enriched :=
    "{\"workspaceIdentifier\":{\"uri\":{\"fsPath\":\"/global/work\"}}," ++
    "\"composer\":{\"composerId\":\"cwd\",\"fullConversationHeadersOnly\":[]},\"bubbles\":[]}"
  let historical :=
    "{\"workspaceIdentifier\":{\"uri\":{\"fsPath\":\"/global/work\"}}," ++
    "\"composer\":{\"composerId\":\"cwd\",\"workspaceIdentifier\":{\"uri\":{\"fsPath\":\"/composer/work\"}}," ++
    "\"fullConversationHeadersOnly\":[]},\"bubbles\":[]}"
  match importCursorIde enriched, importCursorIde historical with
  | .ok fromGlobal, .ok fromComposer =>
      fromGlobal.env.cwd == some "/global/work" &&
        fromComposer.env.cwd == some "/composer/work" &&
        (Loom.violations fromGlobal).isEmpty && (Loom.violations fromComposer).isEmpty
  | _, _ => false

example : cursorIdeEnrichedWorkspaceFallback = true := by native_decide

/-- Unknown bubble enums are retained as inert events, even when their raw
shape contains text that would be dangerous if attributed to a user. -/
def cursorIdeUnknownBubbleIsInert : Bool :=
  let source := cursorIdeSingleBubble 77
    "{\"type\":77,\"bubbleId\":\"b\",\"text\":\"do not inject this as user text\",\"future\":{\"x\":1}}"
  match importCursorIde source with
  | .ok transcript =>
      match transcript.entries[0]? with
      | some entry =>
          match entry.payload with
          | .event (.custom label raw) =>
              label == "cursor_ide.bubble_type_77" && ostr raw "bubbleId" == some "b" &&
                cursorIdeHasOtherNote transcript "cursorIdeUnmodeledBubble"
          | _ => false
      | none => false
  | .error _ => false

example : cursorIdeUnknownBubbleIsInert = true := by native_decide

/-- A present malformed native id refuses the whole local bubble as inert data.
The event payload and `Origin.extras.rawBubble` both retain the exact parsed
source object, and no call or colocated result becomes executable. -/
private def cursorIdeMalformedToolCallIdIsLocalized (encodedId : String) : Bool :=
  let source := cursorIdeSingleBubble 2
    ("{\"type\":2,\"bubbleId\":\"b\",\"thinking\":{\"text\":\"unsafe think\"}," ++
      "\"text\":\"unsafe text\",\"toolFormerData\":{\"tool\":15,\"toolCallId\":" ++
      encodedId ++ ",\"rawArgs\":{},\"result\":\"must not execute\",\"status\":\"completed\"}," ++
      "\"future\":{\"kept\":true}}")
  match Json.parse source, Json.parse encodedId, importCursorIde source with
  | .ok envelope, .ok expectedId, .ok transcript =>
      let expectedBubble? := (field? envelope "bubbles").bind fun value =>
        match value with
        | Json.arr bubbles => bubbles[0]?
        | _ => none
      match transcript.entries.toList with
      | [entry] =>
          match entry.payload, entry.origin.extras with
          | .event (.custom "cursor_ide.malformed_bubble" raw), some extras =>
              expectedBubble?.map Json.compress == some raw.compress &&
                (oobj extras "rawBubble").map Json.compress == expectedBubble?.map Json.compress &&
                (oobj raw "toolFormerData").bind (fun tf => field? tf "toolCallId") ==
                  some expectedId &&
                cursorIdeHasOtherNote transcript "cursorIdeMalformedBubble" &&
                transcript.activeLeaf == some 0 && (Loom.violations transcript).isEmpty
          | _, _ => false
      | _ => false
  | _, _, _ => false

def cursorIdeEmptyToolCallIdIsLocalized : Bool :=
  cursorIdeMalformedToolCallIdIsLocalized "\"\""

example : cursorIdeEmptyToolCallIdIsLocalized = true := by native_decide

def cursorIdeNonStringToolCallIdsAreLocalized : Bool :=
  ["0", "false", "[]", "{}"].all cursorIdeMalformedToolCallIdIsLocalized

example : cursorIdeNonStringToolCallIdsAreLocalized = true := by native_decide

/-- Duplicate native call ids remain exact on both calls and cannot cross-link
results because each result resolves to its colocated call position. -/
def cursorIdeDuplicateToolIdsLinkPositionally : Bool :=
  let source :=
    "{\"composer\":{\"composerId\":\"dup-tools\",\"fullConversationHeadersOnly\":[{\"bubbleId\":\"b1\",\"type\":2},{\"bubbleId\":\"b2\",\"type\":2}]},\"bubbles\":[" ++
    "{\"type\":2,\"bubbleId\":\"b1\",\"toolFormerData\":{\"tool\":15,\"toolCallId\":\"dup\",\"rawArgs\":{},\"result\":\"first\",\"status\":\"completed\"}}," ++
    "{\"type\":2,\"bubbleId\":\"b2\",\"toolFormerData\":{\"tool\":40,\"toolCallId\":\"dup\",\"rawArgs\":{},\"result\":\"second\",\"status\":\"error\"}}]}"
  match importCursorIde source with
  | .ok transcript =>
      match transcript.entries.toList with
      | [firstCall, firstResult, secondCall, secondResult] =>
          match firstCall.payload, firstResult.payload,
              secondCall.payload, secondResult.payload with
          | .assistantMsg [.toolCall _ _ (some "dup")],
            .envMsg [.toolResult (.resolved 0 0) [.text "first"] (.native false)],
            .assistantMsg [.toolCall _ _ (some "dup")],
            .envMsg [.toolResult (.resolved 2 0) [.text "second"] (.native true)] =>
              cursorIdeHasOtherNote transcript "cursorIdeDuplicateToolCallId" &&
                !cursorIdeHasKind transcript .idSynthesized &&
                (Loom.violations transcript).isEmpty
          | _, _, _, _ => false
      | _ => false
  | .error _ => false

example : cursorIdeDuplicateToolIdsLinkPositionally = true := by native_decide

/-- Absent and explicit-null ids remain semantically absent, while duplicate
native strings remain exact duplicates. Every result resolves to its colocated
call position; the null-id bubble also pins thinking/text/call block order. -/
def cursorIdeDuplicateAndMissingToolIdsStayExact : Bool :=
  let source :=
    "{\"composer\":{\"composerId\":\"id-safety\",\"fullConversationHeadersOnly\":[" ++
    "{\"bubbleId\":\"a\",\"type\":2},{\"bubbleId\":\"b\",\"type\":2}," ++
    "{\"bubbleId\":\"c\",\"type\":2},{\"bubbleId\":\"d\",\"type\":2}]},\"bubbles\":[" ++
    "{\"type\":2,\"bubbleId\":\"a\",\"toolFormerData\":{\"tool\":15,\"rawArgs\":{},\"result\":\"missing\",\"status\":\"completed\"}}," ++
    "{\"type\":2,\"bubbleId\":\"b\",\"thinking\":{\"text\":\"null think\",\"signature\":\"N\"}," ++
    "\"text\":\"null text\",\"toolFormerData\":{\"tool\":15,\"toolCallId\":null,\"rawArgs\":{},\"result\":\"null\",\"status\":\"completed\"}}," ++
    "{\"type\":2,\"bubbleId\":\"c\",\"toolFormerData\":{\"tool\":15,\"toolCallId\":\"dup\",\"rawArgs\":{},\"result\":\"first dup\",\"status\":\"completed\"}}," ++
    "{\"type\":2,\"bubbleId\":\"d\",\"toolFormerData\":{\"tool\":15,\"toolCallId\":\"dup\",\"rawArgs\":{},\"result\":\"second dup\",\"status\":\"completed\"}}]}"
  match importCursorIde source with
  | .ok transcript =>
      match transcript.entries.toList with
      | [missing, missingResult, nullId, nullResult,
          firstDup, firstDupResult, secondDup, secondDupResult] =>
          match missing.payload, missingResult.payload, nullId.payload, nullResult.payload,
              firstDup.payload, firstDupResult.payload, secondDup.payload, secondDupResult.payload with
          | .assistantMsg [.toolCall _ _ none],
            .envMsg [.toolResult (.resolved 0 0) [.text "missing"] (.native false)],
            .assistantMsg [.thinking "null think" (some "N"), .text "null text",
              .toolCall _ _ none],
            .envMsg [.toolResult (.resolved 2 2) [.text "null"] (.native false)],
            .assistantMsg [.toolCall _ _ (some "dup")],
            .envMsg [.toolResult (.resolved 4 0) [.text "first dup"] (.native false)],
            .assistantMsg [.toolCall _ _ (some "dup")],
            .envMsg [.toolResult (.resolved 6 0) [.text "second dup"] (.native false)] =>
              !cursorIdeHasKind transcript .idSynthesized &&
                cursorIdeHasOtherNote transcript "cursorIdeDuplicateToolCallId" &&
                transcript.activeLeaf == some 7 &&
                (Loom.violations transcript).isEmpty
          | _, _, _, _, _, _, _, _ => false
      | _ => false
  | .error _ => false

example : cursorIdeDuplicateAndMissingToolIdsStayExact = true := by native_decide

/-- A missing id remains absent even when the call has a positional result; an
absent status remains `unrecorded` rather than being called successful. -/
def cursorIdeMissingIdAndErrorProvenanceExplicit : Bool :=
  let source := cursorIdeSingleBubble 2
    "{\"type\":2,\"bubbleId\":\"b\",\"createdAt\":\"2024-07-03T09:46:40.001Z\",\"toolFormerData\":{\"tool\":57,\"rawArgs\":{},\"result\":\"body\"}}"
  match importCursorIde source with
  | .ok transcript =>
      match transcript.entries[0]?, transcript.entries[1]? with
      | some call, some result =>
          match call.time, result.time, call.payload, result.payload with
          | .recorded t1, .recorded t2,
            .assistantMsg [.toolCall name _ none],
            .envMsg [.toolResult (.resolved 0 0) [.text "body"] .unrecorded] =>
              t1.ms == 1720000000001 && t2 == t1 &&
                name.raw == "web_fetch" && decide (name.canonical = some .webFetch) &&
                !cursorIdeHasKind transcript .idSynthesized &&
                cursorIdeHasOtherNote transcript "errorUnrecorded" &&
                (Loom.violations transcript).isEmpty
          | _, _, _, _ => false
      | _, _ => false
  | .error _ => false

example : cursorIdeMissingIdAndErrorProvenanceExplicit = true := by native_decide

/-- Media is mapped when its locator is understood; opaque media and every
additive source field remain byte-exact under raw entry/session provenance. -/
def cursorIdeMediaAndAdditiveProvenanceExact : Bool :=
  let source :=
    "{\"envelopeFuture\":true,\"composer\":{\"composerId\":\"media\",\"branches\":[{\"id\":\"alt\"}],\"fullConversationHeadersOnly\":[{\"bubbleId\":\"b\",\"type\":1}]}," ++
    "\"bubbles\":[{\"type\":1,\"bubbleId\":\"b\",\"text\":\"see image\",\"images\":[{\"mimeType\":\"image/png\",\"url\":\"file:///tmp/a.png\",\"future\":1},{\"futureImage\":true}],\"attachedFolders\":[{\"path\":\"/tmp\"}],\"gitDiffs\":[{\"patch\":\"exact\"}],\"futureBubble\":{\"n\":2}}]}"
  match Json.parse source, importCursorIde source with
  | .ok raw, .ok transcript =>
      let sourceBubble? := (field? raw "bubbles").bind fun value =>
        match value with | Json.arr bubbles => bubbles[0]? | _ => none
      let keptBubble? := transcript.entries[0]?.bind (fun entry => entry.origin.extras)
        |>.bind (fun extras => oobj extras "rawBubble")
      let keptEnvelope? := transcript.origin.extras.bind (fun extras => oobj extras "rawEnvelope")
      match transcript.entries[0]? with
      | some entry =>
          match entry.payload with
          | Loom.Payload.userMsg [Loom.UserBlock.text "see image",
              Loom.UserBlock.media "image/png" "file:///tmp/a.png",
              Loom.UserBlock.unmodeled "cursor_ide.image" rawOpaque] =>
              field? rawOpaque "futureImage" == some (Json.bool true) &&
              keptBubble?.map Json.compress == sourceBubble?.map Json.compress &&
              keptEnvelope?.map Json.compress == some raw.compress &&
              cursorIdeHasOtherNote transcript "cursorIdeBranchMetadata" &&
              cursorIdeHasOtherNote transcript "cursorIdeActivePath"
          | _ => false
      | none => false
  | _, _ => false

example : cursorIdeMediaAndAdditiveProvenanceExact = true := by native_decide

/-! ## Cross-parity pin (RC1) — agreement with the TS `convert-to-pi cursor` oracle.

The gap the other six formats had closed but Cursor IDE could not: a decide-pin
that the Lean importer's `normalize` output equals the TS toolchain's
(`importCursorChatToPi`, `src/pi/cursor.ts`). It was unpinnable before because
the TS oracle reads a real sqlite `state.vscdb` and no captured golden existed.
It exists now.

`spec/loom/test.vscdb` is a **synthetic, structure-only** Cursor store (two
`cursorDiskKV` record kinds + a `composer.composerHeaders` `ItemTable` row, no
real conversation content). `cursorIdeParityInput` below is the captured JSON
shape produced from that store by the sqlite actuator
(`readCursorIdeStore test.vscdb "cmp-fix"`) when this pin was cut — composer
value verbatim, bubbles in `fullConversationHeadersOnly` order. The release gate
also smoke-runs the actuator against the same store. The golden `tsGolden` was
captured by running `convert-to-pi cursor --chat-id cmp-fix --state-db-path
test.vscdb` and projecting its pi output through the shared positional
`normalize` skeleton (byte-identical to `parity/capture-parity.ts`). Both sides
land on 4 entries, 0 violations.

The fixture is deliberately **TS-parity-clean**: its tool bubble carries no
standalone `text`. Cursor's oracle drops assistant text colocated with a tool
call; Loom keeps it (an adjudicated leanCore divergence — exercised by
`cursorIdeFixture` above, avoided here so the skeletons agree). Tool *names*
also differ (Loom uses `toolFormerData.name` = `read_file`; TS enum-maps 15 →
`bash`) but `normalize` projects both to `call`, and thinking *signatures* are
Lean-only (L12) and excluded from the skeleton — so the two adjudicated
divergences don't reach the gate. -/
def cursorIdeParityInput : String :=
  "{\"composer\":" ++
  "{\"composerId\":\"cmp-fix\",\"createdAt\":1720000000000,\"name\":\"parity fixture\"," ++
  "\"workspaceIdentifier\":{\"uri\":{\"fsPath\":\"/w\"}}," ++
  "\"fullConversationHeadersOnly\":[{\"bubbleId\":\"b0\",\"type\":1},{\"bubbleId\":\"b1\",\"type\":2},{\"bubbleId\":\"b2\",\"type\":2}]}," ++
  "\"bubbles\":[" ++
  "{\"_v\":3,\"type\":1,\"bubbleId\":\"b0\",\"text\":\"hello cursor\"}," ++
  "{\"_v\":3,\"type\":2,\"bubbleId\":\"b1\",\"text\":\"sure thing\"," ++
  "\"thinking\":{\"text\":\"reasoning\",\"signature\":\"SIG\"},\"createdAt\":1720000000001," ++
  "\"tokenCount\":{\"inputTokens\":5,\"outputTokens\":7},\"modelInfo\":{\"modelName\":\"claude-x\"}}," ++
  "{\"_v\":3,\"type\":2,\"bubbleId\":\"b2\",\"thinking\":{\"text\":\"tool time\"},\"createdAt\":1720000000002," ++
  "\"toolFormerData\":{\"tool\":15,\"name\":\"read_file\",\"toolCallId\":\"tc-1\"," ++
  "\"rawArgs\":{\"path\":\"a.txt\"},\"result\":\"file body\",\"status\":\"completed\"}}" ++
  "]}"

/-- Cross-parity golden, captured from `convert-to-pi cursor` on the synthetic
`test.vscdb`, projected through the shared positional `normalize` skeleton. -/
def cursorIdeCase1 : CrossParityCase := {
  name := "cursor-ide",
  input := cursorIdeParityInput,
  tsGolden := "session\n0|-|user|text:hello cursor\n1|0|assistant|think:reasoning;text:sure thing\n2|1|assistant|think:tool time;call\n3|2|toolResult|text:file body"
}

/-- THE DECIDE-PIN (cross-parity, RC1): the Lean Cursor IDE importer agrees with
the TS `convert-to-pi cursor` oracle on the shared `normalize` skeleton. Closes
the last Loom parity-coverage cell; if leanCore drifts from the TS baseline this
stops compiling. -/
example : crossParityOkWith importCursorIde cursorIdeCase1 = true := by native_decide

end LoomConvert
