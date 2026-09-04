import Loom.Core
import Loom.Temporal
import Loom.WellFormed

/-!
# Search-text projection

A flat, deliberately lossy projection of a `Transcript` to one JSON row per
entry, for hosts that index or grep transcripts (`loom text`). It is the
search counterpart of `Loom.Render`: `Render` is the human review surface,
this is the machine one. Nothing here re-parses source bytes; every row comes
from the canonical IR, so a search hit in any harness format means the same
thing.

Roles are the search vocabulary hosts already use (`user`, `assistant`,
`toolResult`), not the serialization roles of any one harness: a Claude
`tool_result` packed inside a user line and a Codex `function_call_output`
both surface as `toolResult`, because the IR already attributes them to the
environment.
-/

namespace Loom

open Lean

private def userBlockText : UserBlock → String
  | .text s => s
  | .media mime locator => s!"[media {mime}] {locator}"
  | .unmodeled label raw => s!"[{label}] {raw.compress}"

/-- Tool calls render as `name(args)` so a query for a tool name or an
argument fragment lands on the call site, not only on its result. -/
private def assistantBlockText : AssistantBlock → String
  | .text s => s
  | .thinking s _ => s
  | .toolCall name args _ => s!"{name.raw}({args.compress})"
  | .media mime locator => s!"[media {mime}] {locator}"
  | .unmodeled label raw => s!"[{label}] {raw.compress}"

private def envBlockText : EnvBlock → String
  | .toolResult _ content _ => String.intercalate "\n" (content.map userBlockText)
  | .unmodeled label raw => s!"[{label}] {raw.compress}"

private def optionOr (fallback : String) : Option String → String
  | some value => value
  | none => fallback

/-- Search role of a payload. `other` covers rare serialization roles
(`system`, `developer`, `bashExecution`); hosts usually skip them. -/
def searchRole : Payload → String
  | .userMsg _ => "user"
  | .assistantMsg _ => "assistant"
  | .envMsg _ => "toolResult"
  | .otherMsg _ _ => "other"
  | .compaction .. => "compaction"
  | .event _ => "event"

/-- Searchable text of a payload: every text, thinking, tool-call, tool-result
and summary string, newline-joined. Signatures and encrypted payloads are
never included. -/
def searchText : Payload → String
  | .userMsg blocks => String.intercalate "\n" (blocks.map userBlockText)
  | .assistantMsg blocks => String.intercalate "\n" (blocks.map assistantBlockText)
  | .envMsg blocks => String.intercalate "\n" (blocks.map envBlockText)
  | .otherMsg role blocks =>
      s!"[{role}] " ++ String.intercalate "\n" (blocks.map userBlockText)
  | .compaction summary _ _ => summary
  | .event event =>
      match event with
      | .modelChange prev next =>
          s!"model change: {optionOr "unknown" prev} -> {optionOr "unknown" next}"
      | .thinkingLevelChange prev next =>
          s!"thinking level: {optionOr "unknown" prev} -> {optionOr "unknown" next}"
      | .permissionMode mode => s!"permission mode: {mode}"
      | .branchSummary summary => summary
      | .custom label raw => s!"[{label}] {raw.compress}"

/-- Raw tool names called in an assistant entry (empty for every other kind). -/
def toolNames : Payload → List String
  | .assistantMsg blocks =>
      blocks.filterMap (fun block =>
        match block with
        | .toolCall name _ _ => some name.raw
        | _ => none)
  | _ => []

private def timeMs? : Time → Option Timestamp
  | .recorded value => some value
  | .interpolated value _ => some value
  | _ => none

private def optStrJson (key : String) : Option String → List (String × Json)
  | some value => [(key, Json.str value)]
  | none => [(key, Json.null)]

/-- One entry row. `ms`/`iso` are null when the source recorded no usable
time (cursor-agent, hermes): hosts fall back to file mtime, as they always
did, instead of receiving an invented timestamp. -/
def searchRow (index : Nat) (entry : Entry) : Json :=
  let time := timeMs? entry.time
  Json.mkObj ([
    ("kind", Json.str "entry"),
    ("index", toJson index),
    ("thread", toJson entry.thread),
    ("parent", match entry.parent with | some p => toJson p | none => Json.null),
    ("role", Json.str (searchRole entry.payload)),
    ("ms", match time with | some t => toJson t.ms | none => Json.null),
    ("iso", match time with | some t => Json.str (epochMsToIso8601 t) | none => Json.null),
    ("historical", Json.bool (entry.disposition == .historicalUnverified)),
    ("tools", Json.arr ((toolNames entry.payload).map Json.str).toArray),
    ("text", Json.str (searchText entry.payload))
  ])

private def threadKindName : ThreadKind → String
  | .main => "main"
  | .sidechain _ => "sidechain"
  | .detached _ => "detached"

private def threadRow (index : Nat) (thread : Thread) : Json :=
  Json.mkObj ([
    ("index", toJson index),
    ("kind", Json.str (threadKindName thread.kind))
  ] ++ optStrJson "label" thread.label)

/-- The session header row emitted before a transcript's entry rows. -/
def searchSessionRow (file format : String) (t : Transcript) : Json :=
  Json.mkObj ([
    ("kind", Json.str "session"),
    ("file", Json.str file),
    ("format", Json.str format)
  ] ++ optStrJson "sessionId" t.env.sessionId
    ++ optStrJson "cwd" t.env.cwd
    ++ optStrJson "model" t.env.model
    ++ optStrJson "provider" t.env.provider
    ++ [
    ("entries", toJson t.entries.size),
    ("threads", Json.arr ((t.threads.toList.zipIdx.map (fun (th, i) => threadRow i th)).toArray)),
    ("activeLeaf", match t.activeLeaf with | some leaf => toJson leaf | none => Json.null),
    ("violations", toJson (violations t).length),
    ("importNotes", toJson t.importNotes.length)
  ])

/-- All entry rows of a transcript, in entry order. -/
def searchRows (t : Transcript) : List Json :=
  t.entries.toList.zipIdx.map (fun (entry, index) => searchRow index entry)

private def userPayload : Payload := .userMsg [.text "find the cron server"]

private def assistantPayload : Payload :=
  .assistantMsg [.thinking "plan" (some "sig"), .text "looking",
    .toolCall { raw := "bash" } (Json.mkObj [("cmd", Json.str "ls")]) (some "c1")]

private def toolResultPayload : Payload :=
  .envMsg [.toolResult (.resolved 1 2) [.text "cron-server.ts"] (.native false)]

private def textFixture : Transcript := {
  threads := #[{ kind := .main }]
  entries := #[
    { payload := userPayload
      origin := { format := .other "fixture", sourceRef := "t0" }
      time := .recorded ⟨1720000000001⟩ },
    { payload := assistantPayload
      origin := { format := .other "fixture", sourceRef := "t1" }
      parent := some 0 },
    { payload := toolResultPayload
      origin := { format := .other "fixture", sourceRef := "t2" }
      parent := some 1 }
  ]
  origin := { format := .other "fixture", sourceRef := "fixture" }
}

example : searchRole toolResultPayload = "toolResult" := by native_decide
example : searchText assistantPayload = "plan\nlooking\nbash({\"cmd\":\"ls\"})" := by
  native_decide
example : toolNames assistantPayload = ["bash"] := by native_decide
example : (searchRows textFixture).length = 3 := by native_decide
/-- Signatures never reach the search surface. -/
example : ((searchText assistantPayload).splitOn "sig").length = 1 := by native_decide

end Loom
