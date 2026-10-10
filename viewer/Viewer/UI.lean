import LeanReact
import AssistantUI
import Viewer.Conversation

/-! # The browser side

Portable Lean, compiled by LeanJS (`Generate.lean`): the session list on the left, the thread on
the right, both loaded through `Service`, which `web/client.mjs` implements over fetch. The
thread itself is assistant-ui for Lean, read-only: the viewer shows what the harnesses recorded. -/

namespace Viewer.UI
open LeanReact AssistantUI

/-- A page of the catalog. -/
structure Query where
  harness : Option Harness := none
  /-- A substring of the title, project path or id. -/
  text : String := ""
  offset : Nat := 0
  limit : Nat := 40
  deriving Repr, Inhabited

structure SessionPage where
  sessions : Array Session
  /-- Sessions matching the query, across all pages. -/
  total : Nat
  deriving Repr, Inhabited

/-- What the browser asks the server. -/
structure Service where
  sessions : Query → Action (Except String SessionPage)
  conversation : Harness → String → Action (Except String Conversation)

structure AppProps where
  service : Service

def failureText (failure : ResourceFailure String) : String :=
  match Resource.failureAs failure with
  | .ok message => message
  | .error .unauthenticated => "Not signed in."
  | .error .forbidden => "Not allowed."
  | .error .cancelled => "Cancelled."
  | .error (.incompatible _ _) => "The server speaks another version of the viewer."
  | .error (.decode code) | .error (.protocol code) | .error (.transport code) =>
    s!"The server answered unexpectedly ({code})."

def harnessKey : Option Harness → String
  | some h => h.slug
  | none => ""

def pageSize : Nat := 40

def plural (n : Nat) (one many : String) : String := if n == 1 then s!"1 {one}" else s!"{n} {many}"

/-- What the thread leaves out: subagent threads, harness bookkeeping rows, withheld reasoning. -/
def hiddenNote (sidechains : Nat) (hidden : Hidden) : String :=
  String.intercalate " " (
    (if sidechains == 0 then [] else [plural sidechains "subagent thread is" "subagent threads are" ++ " not shown yet."]) ++
    (if hidden.events == 0 then [] else [plural hidden.events "harness event is" "harness events are" ++ " not shown."]) ++
    (if hidden.redacted == 0 then [] else [plural hidden.redacted "reasoning block was" "reasoning blocks were" ++ " withheld by the harness."]))

private def sessionRow (current : Option Session) (select : Session → Action Unit) (s : Session) : Element :=
  let chosen := match current with
    | some c => c.file == s.file
    | none => false
  DOM.li {} #[
    DOM.button {
      className := some (if chosen then "session chosen" else "session")
      ariaLabel := some s.name
      onPress := some (select s) } #[
      DOM.span { className := some "session-title" } #[text s.name],
      DOM.span { className := some "session-meta" } #[
        text s!"{s.file.harness.label}{(if s.preview.internal then " · internal" else "")} · {s.project.getD "no project"} · {clockText s.file.modifiedMs} UTC"]]]

private def harnessChip (current : Option Harness) (choose : Option Harness → Action Unit)
    (option : Option Harness) (label : String) : Element :=
  DOM.button {
    className := some (if current == option then "chip chosen" else "chip")
    onPress := some (choose option) } #[text label]

def App : Component AppProps := Component.named "LoomViewer" <| component fun props => do
  let harness ← useState (none : Option Harness) "harness"
  let search ← useState "" "search"
  let offset ← useState 0 "offset"
  let selected ← useState (none : Option Session) "selected"
  let page ← useResource (Key.string "sessions")
    (fun _ => props.service.sessions { harness := harness.value, text := search.value, offset := offset.value, limit := pageSize })
    #[.string (harnessKey harness.value), .string search.value, .nat offset.value] true "sessions"
  let selectedKey := match selected.value with
    | some s => s.file.harness.slug ++ ":" ++ s.file.id
    | none => ""
  let conversation ← useResource (Key.string "conversation")
    (fun _ => match selected.value with
      | some s => props.service.conversation s.file.harness s.file.id
      | none => pure (.error "Nothing selected."))
    #[.string selectedKey] selected.value.isSome "conversation"
  let choose (h : Option Harness) : Action Unit := do harness.set h; offset.set 0
  let chips := #[harnessChip harness.value choose none "All"] ++
    Harness.all.toArray.map fun h => harnessChip harness.value choose (some h) h.label
  let listing : Element := match page.state with
    | .idle => empty
    | .loading _ => DOM.p { className := some "note" } #[text "Listing sessions…"]
    | .failure _ failure => DOM.p { role := some "alert" } #[text (failureText failure)]
    | .success _ result =>
      if result.sessions.isEmpty then DOM.p { className := some "note" } #[text "No sessions match."]
      else DOM.div {} #[
        DOM.ul { className := some "sessions" } (result.sessions.map (sessionRow selected.value fun s => selected.set (some s))),
        DOM.div { className := some "pager" } #[
          DOM.button { onPress := some (offset.modify fun o => o - pageSize), disabled := offset.value == 0 } #[text "Newer"],
          DOM.span { className := some "note" } #[
            text s!"{offset.value + 1}–{offset.value + result.sessions.size} of {result.total}"],
          DOM.button {
            onPress := some (offset.modify (· + pageSize))
            disabled := offset.value + result.sessions.size ≥ result.total } #[text "Older"]]]
  let pane : Element := match selected.value with
    | none => DOM.p { className := some "note placeholder" } #[text "Pick a conversation."]
    | some s => DOM.div { className := some "conversation" } #[
      DOM.header { className := some "conversation-header" } #[
        DOM.h2 {} #[text s.name],
        DOM.p { className := some "meta" } #[text (String.intercalate " · " ([s.file.harness.label] ++
          (s.preview.cwd.map fun cwd => [cwd]).getD [] ++ (s.preview.model.map fun m => [m]).getD [] ++
          [s!"{s.preview.turns} turns"]))],
        DOM.p { className := some "meta mono" } #[text s.file.path],
        (if s.preview.internal then DOM.p { className := some "note" }
          #[text "A session the harness ran for itself; its first message is the harness's own prompt."] else empty)],
      match conversation.state with
      | .idle => empty
      | .loading _ => DOM.p { className := some "note" } #[text "Importing the transcript…"]
      | .failure _ failure => DOM.p { role := some "alert" } #[text (failureText failure)]
      | .success _ c => DOM.div { className := some "thread-area" } #[
        (if c.sidechains == 0 && c.hidden == {} then empty
          else DOM.p { className := some "note" } #[text (hiddenNote c.sidechains c.hidden)]),
        thread { messages := c.messages, emptyText := "This conversation has no messages." }]]
  pure <| DOM.div { className := some "viewer" } #[
    DOM.aside { className := some "catalog" } #[
      DOM.h1 {} #[text "Conversations"],
      DOM.div { className := some "chips" } chips,
      DOM.input {
        className := some "search"
        placeholder := some "Search titles, projects, ids"
        value := some search.value
        onChange := some fun event => do search.set event.value; offset.set 0 },
      listing],
    DOM.main { className := some "pane" } #[pane]]

end Viewer.UI
