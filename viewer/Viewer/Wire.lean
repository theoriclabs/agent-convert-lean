import Viewer.Conversation

/-! # The wire

JSON for the browser, written once here and decoded once in `web/client.mjs`. The shapes are the
domain's: a session is its file facts and preview flattened; a message is its id, role, time,
status and parts. -/

namespace Viewer
open Lean (Json ToJson toJson)
open AssistantUI

private def optional [ToJson α] : Option α → Json
  | some value => toJson value
  | none => Json.null

instance : ToJson Harness := ⟨fun h => Json.str h.slug⟩

instance : ToJson Session := ⟨fun s => Json.mkObj [
  ("harness", toJson s.file.harness), ("id", Json.str s.file.id), ("path", Json.str s.file.path),
  ("modifiedMs", toJson s.file.modifiedMs), ("bytes", toJson s.file.bytes),
  ("title", optional s.preview.title), ("cwd", optional s.preview.cwd), ("model", optional s.preview.model),
  ("startedMs", optional s.preview.startedMs), ("turns", toJson s.preview.turns),
  ("internal", Json.bool s.preview.internal)]⟩

def Role.wire : Role → String
  | .user => "user"
  | .assistant => "assistant"
  | .system => "system"

def ToolArguments.wire : ToolArguments → Json
  | .raw text => Json.mkObj [("raw", Json.str text)]
  | .fields entries => Json.mkObj [("fields", Json.arr (entries.map fun (key, value) => Json.arr #[Json.str key, Json.str value]))]

def Part.wire : Part → Json
  | .text value => Json.mkObj [("type", Json.str "text"), ("text", Json.str value)]
  | .reasoning value => Json.mkObj [("type", Json.str "reasoning"), ("text", Json.str value)]
  | .image url => Json.mkObj [("type", Json.str "image"), ("url", Json.str url)]
  | .toolCall callId name arguments result => Json.mkObj [
      ("type", Json.str "toolCall"), ("callId", Json.str callId), ("name", Json.str name), ("arguments", ToolArguments.wire arguments),
      ("result", match result with
        | some r => Json.mkObj [("value", Json.str r.value), ("isError", Json.bool r.isError)]
        | none => Json.null)]

def MessageStatus.wire : MessageStatus → Json
  | .complete => Json.mkObj [("type", Json.str "complete")]
  | .running => Json.mkObj [("type", Json.str "running")]
  | .cancelled => Json.mkObj [("type", Json.str "cancelled")]
  | .failed error => Json.mkObj [("type", Json.str "failed"), ("error", Json.str error)]
  | .requiresAction => Json.mkObj [("type", Json.str "requiresAction")]

instance : ToJson Message := ⟨fun m => Json.mkObj [
  ("id", Json.str m.id), ("role", Json.str (Role.wire m.role)), ("atMs", optional m.createdAtMs),
  ("status", MessageStatus.wire m.status), ("parts", Json.arr (m.parts.map Part.wire))]⟩

instance : ToJson Conversation := ⟨fun c => Json.mkObj [
  ("messages", toJson c.messages), ("sidechains", toJson c.sidechains), ("importNotes", toJson c.importNotes),
  ("hidden", Json.mkObj [("events", toJson c.hidden.events), ("redacted", toJson c.hidden.redacted)])]⟩

end Viewer
