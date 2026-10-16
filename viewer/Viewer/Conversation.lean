import Viewer.Session
import AssistantUI
import Loom.Text

/-! # The projection to a thread

Loom already normalizes every harness into one IR with role-indexed payloads and positional tool
links. This module projects that IR onto the thread vocabulary of assistant-ui for Lean: one
`AssistantUI.Entry` per message block, in entry order, over the main thread. Tool arguments become
named fields ordered by Loom's canonical tool, so a shell call reads as its command and a file
tool as its path. Harness bookkeeping rows (`MetaEvent.custom`) and blocks whose content the
harness withheld are not conversation; they are counted (`Hidden`), not shown. Tool calls are
identified positionally (`entry.block`), exactly as Loom links results to calls, so a result
reaches its call without trusting source ids. The harness's own scaffolding, which Loom keeps
as user rows, renders as system. -/

namespace Viewer
open AssistantUI

/-- What the thread leaves out, counted so nothing disappears silently. -/
structure Hidden where
  /-- Harness bookkeeping rows (Codex item lifecycle, hook results): not conversation. -/
  events : Nat := 0
  /-- Assistant blocks whose content the harness withheld (encrypted reasoning). -/
  redacted : Nat := 0
  deriving Repr, DecidableEq, Inhabited

/-- A transcript as the thread shows it. -/
structure Conversation where
  messages : Array Message
  /-- Threads beyond the main one (subagent sidechains, detached threads). -/
  sidechains : Nat
  importNotes : Nat
  hidden : Hidden
  deriving Repr, Inhabited

namespace Conversation

def callId (entry block : Nat) : String := s!"{entry}.{block}"

/-- A media locator as `<img>` can load it: a `data:` or `http(s):` URL as given, a base64 payload
(Claude Code's pasted images, with or without a `base64:` prefix) as a `data:` URL. -/
def imageUrl? (mime locator : String) : Option String :=
  let isImage := mime == "image" || (mime.toList.take 6 == "image/".toList)
  if locator.toList.take 5 == "data:".toList || locator.toList.take 4 == "http".toList then some locator
  else if isImage then
    let payload := if locator.toList.take 7 == "base64:".toList then String.ofList (locator.toList.drop 7) else locator
    let mediaType := if mime == "image" then "image/png" else mime
    some s!"data:{mediaType};base64,{payload}"
  else none

/-- Media as text, where only text fits (tool results): a short locator as given, never a payload. -/
private def mediaText (mime locator : String) : String :=
  if locator.toList.take 5 == "data:".toList then s!"[{mime}, {locator.length} characters inline]"
  else if locator.length < 200 then s!"[{mime}] {locator}"
  else s!"[{mime}, {locator.length} characters]"

private def userBlockText : Loom.UserBlock → String
  | .text s => s
  | .media mime locator => mediaText mime locator
  | .unmodeled label _ => s!"[{label}]"

private def refId : Loom.CallRef → String
  | .resolved entry block => callId entry block
  | .unresolved (some raw) _ => raw
  | .unresolved none note => s!"unresolved: {note}"

private def isError : Loom.ErrorSignal → Bool
  | .native e => e
  | .heuristic e _ | .structured e _ => e
  | .unrecorded => false

private def timeMs : Loom.Time → Option Nat
  | .recorded t => some t.ms
  | .interpolated t _ => some t.ms
  | _ => none

/-- The keys a tool's arguments are read in, so the field that names the call comes first. -/
private def preferredKeys : Option Loom.CanonicalTool → List String
  | some .bash => ["description", "command", "cmd", "input"]
  | some .read => ["file_path", "path", "offset", "limit"]
  | some .write => ["file_path", "path", "content"]
  | some .edit => ["file_path", "path", "old_string", "new_string", "replace_all"]
  | some .grep => ["pattern", "path", "glob", "output_mode"]
  | some .glob => ["pattern", "path"]
  | some .webFetch => ["url", "prompt"]
  | some .webSearch => ["query"]
  | some .agentSpawn => ["description", "subagent_type", "prompt"]
  | some .applyPatch => ["patch", "input"]
  | none => ["description", "command", "cmd", "input", "query", "pattern", "file_path", "path", "url", "prompt"]

private def fieldText : Lean.Json → String
  | .str s => s
  | other => other.compress

/-- Tool arguments for display: a JSON object's members as fields, the tool's own keys first and
the rest in key order; anything else as the text it was. -/
def toolArguments (name : Loom.ToolName) (args : Lean.Json) : ToolArguments :=
  match args with
  | .obj members =>
    let entries : Array (String × String) := members.foldl (fun acc key value => acc.push (key, fieldText value)) #[]
    let preferred := preferredKeys name.canonical
    let first := preferred.filterMap fun key => entries.find? (·.1 == key)
    let rest := entries.filter fun (key, _) => !preferred.contains key
    .fields (first.toArray ++ rest)
  | .str s => .raw s
  | other => .raw other.compress

private def mainThread (t : Loom.Transcript) : Nat :=
  match t.threads.toList.zipIdx.find? (fun p => p.1.kind == .main) with
  | some p => p.2
  | none => 0

/-- The entries of one Loom entry, at index `i`. -/
def entriesOf (h : Harness) (i : Nat) (e : Loom.Entry) : List Entry :=
  let when := timeMs e.time
  let one (role : Role) (content : Content) : Entry := { id := toString i, role, content, atMs := when }
  match e.payload with
  | .userMsg blocks =>
    let texts := blocks.filterMap fun block => match block with
      | .media mime locator => if (imageUrl? mime locator).isSome then none else some (userBlockText block)
      | other => some (userBlockText other)
    let text := String.intercalate "\n" texts
    let role := if h.store.scaffolding text then Role.system else Role.user
    (if text.isEmpty then [] else [one role (.text text)]) ++
      blocks.filterMap fun block => match block with
        | .media mime locator => (imageUrl? mime locator).map fun url => one role (.image url)
        | _ => none
  | .assistantMsg blocks =>
    blocks.zipIdx.filterMap fun (block, j) =>
      let content : Option Content := match block with
        | .text s => some (.text s)
        | .thinking s _ => some (.reasoning s)
        | .toolCall name args _ => some (.toolCall (callId i j) name.raw (toolArguments name args))
        | .media mime locator => some ((imageUrl? mime locator).map Content.image |>.getD (.text (mediaText mime locator)))
        | .unmodeled _ _ => none
      content.map fun content => { id := callId i j, role := .assistant, content, atMs := when }
  | .envMsg blocks =>
    blocks.map fun block =>
      match block with
      | .toolResult call content error =>
        one .assistant (.toolResult (refId call) (String.intercalate "\n" (content.map userBlockText)) (isError error))
      | .unmodeled label _ => one .system (.text s!"[{label}]")
  | .otherMsg "peer" blocks => [one .system (.text (String.intercalate "\n" (blocks.map userBlockText)))]
  | .otherMsg role blocks => [one .system (.text (s!"[{role}] " ++ String.intercalate "\n" (blocks.map userBlockText)))]
  | .compaction summary _ _ => [one .system (.text s!"Compaction summary:\n{summary}")]
  | .event (.custom _ _) => []
  | .event event => [one .system (.text (Loom.searchText (.event event)))]

/-- A harness bookkeeping row: an event Loom keeps only as a labelled raw record. -/
def isBookkeeping (e : Loom.Entry) : Bool :=
  match e.payload with
  | .event (.custom _ _) => true
  | _ => false

/-- Assistant blocks Loom could only keep verbatim (Codex's encrypted reasoning): withheld content. -/
def redactedBlocks (e : Loom.Entry) : Nat :=
  match e.payload with
  | .assistantMsg blocks => (blocks.filter fun block => match block with | .unmodeled _ _ => true | _ => false).length
  | _ => 0

/-- The main thread of a transcript imported from `h`, as thread entries. -/
def entries (h : Harness) (t : Loom.Transcript) : Array Entry :=
  let main := mainThread t
  (t.entries.toList.zipIdx.filterMap fun (e, i) =>
    if e.thread == main then some (entriesOf h i e) else none).flatten.toArray

def ofTranscript (h : Harness) (t : Loom.Transcript) : Conversation :=
  let main := mainThread t
  let mainEntries := t.entries.filter (·.thread == main)
  { messages := Message.ofTranscript (entries h t)
    sidechains := t.threads.size - 1
    importNotes := t.importNotes.length
    hidden := { events := (mainEntries.filter isBookkeeping).size
                redacted := mainEntries.foldl (fun n e => n + redactedBlocks e) 0 } }

end Conversation
end Viewer
