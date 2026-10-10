import Viewer.Harness

/-! # Sessions

A session is a file in a harness store. `SessionFile` is what the file system says about it;
`Preview` is what its transcript says it is about; `Session` is both, as the catalog lists it. -/

namespace Viewer

/-- A session file, from the file system alone. -/
structure SessionFile where
  harness : Harness
  id : String
  path : String
  /-- Last modification, milliseconds since the Unix epoch. -/
  modifiedMs : Nat
  bytes : Nat
  deriving Repr, DecidableEq, Inhabited

/-- What a session is about, read from its transcript. -/
structure Preview where
  /-- The person's first words, one line; `none` when every user row is harness scaffolding. -/
  title : Option String
  cwd : Option String
  model : Option String
  startedMs : Option Nat
  turns : Nat
  /-- The harness ran this session for itself. -/
  internal : Bool := false
  deriving Repr, DecidableEq, Inhabited

structure Session where
  file : SessionFile
  preview : Preview
  deriving Repr, DecidableEq, Inhabited

/-- A session's name in a list: its title, else what it is, else its id. -/
def Session.name (s : Session) : String :=
  s.preview.title.getD (if s.preview.internal then s!"{s.file.harness.label} internal session" else s.file.id)

/-- The last segment of a path, ignoring trailing slashes; the path itself when it has none.
List-based: the browser-side Lean renders it, and LeanJS has no `String.splitOn`. -/
def lastSegment (path : String) : String :=
  let reversed := path.toList.reverse.dropWhile (· == '/')
  let segment := (reversed.takeWhile (· != '/')).reverse
  if segment.isEmpty then path else String.ofList segment

/-- The project a session belongs to: the last path segment of its cwd. -/
def Session.project (s : Session) : Option String := s.preview.cwd.map lastSegment

example : lastSegment "/Users/x/code/leanreact" = "leanreact" := by native_decide
example : lastSegment "/Users/x/code/leanreact/" = "leanreact" := by native_decide
example : lastSegment "///" = "///" := by native_decide

/-- Whitespace trimmed from both ends. List-based so the browser-side Lean compiles it too. -/
def trimSpaces (s : String) : String :=
  String.ofList ((s.toList.dropWhile Char.isWhitespace).reverse.dropWhile Char.isWhitespace).reverse

/-- `width` characters of the first non-blank line of `text`, with an ellipsis when cut. -/
def headline (text : String) (width : Nat := 120) : String :=
  let line := trimSpaces (((text.splitOn "\n").find? fun l => !(trimSpaces l).isEmpty).getD "")
  if line.length ≤ width then line else trimSpaces (String.ofList (line.toList.take width)) ++ "…"

private def userText (blocks : List Loom.UserBlock) : String :=
  String.intercalate "\n" (blocks.filterMap fun
    | .text s => some s
    | _ => none)

private def timeMs : Loom.Time → Option Nat
  | .recorded t => some t.ms
  | .interpolated t _ => some t.ms
  | _ => none

/-- The preview of a transcript imported from harness `h`: the first user text that is not the
harness's scaffolding becomes the title. -/
def Preview.ofTranscript (h : Harness) (t : Loom.Transcript) : Preview :=
  let store := h.store
  let firstWords := t.entries.toList.findSome? fun entry =>
    match entry.payload with
    | .userMsg blocks =>
      let text := userText blocks
      if (trimSpaces text).isEmpty || store.scaffolding text then none else some (headline text)
    | _ => none
  { title := firstWords
    cwd := t.env.cwd
    model := t.env.model
    startedMs := t.entries.toList.findSome? fun entry => timeMs entry.time
    turns := Loom.turnCount t
    internal := store.internal t }

/-! ## Calendar text, portable

Dates are shown by the browser-side Lean too, so the formatter is plain arithmetic here rather
than a host call. `civil` is the standard days-from-epoch conversion. -/

/-- `(year, month, day)` of a day count since 1970-01-01 (proleptic Gregorian). -/
def civil (days : Nat) : Nat × Nat × Nat :=
  let z := days + 719468
  let era := z / 146097
  let doe := z - era * 146097
  let yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
  let y := yoe + era * 400
  let doy := doe - (365 * yoe + yoe / 4 - yoe / 100)
  let mp := (5 * doy + 2) / 153
  let d := doy - (153 * mp + 2) / 5 + 1
  let m := if mp < 10 then mp + 3 else mp - 9
  (if m ≤ 2 then y + 1 else y, m, d)

private def pad2 (n : Nat) : String := if n < 10 then s!"0{n}" else toString n

/-- `YYYY-MM-DD HH:MM` in UTC. -/
def clockText (ms : Nat) : String :=
  let seconds := ms / 1000
  let (y, m, d) := civil (seconds / 86400)
  let minuteOfDay := (seconds % 86400) / 60
  s!"{y}-{pad2 m}-{pad2 d} {pad2 (minuteOfDay / 60)}:{pad2 (minuteOfDay % 60)}"

example : civil 0 = (1970, 1, 1) := by native_decide
example : civil 20000 = (2024, 10, 4) := by native_decide
example : clockText 1791589431313 = "2026-10-09 23:43" := by native_decide
example : trimSpaces "  a b \n" = "a b" := by native_decide
example : headline "  first line here\nsecond" = "first line here" := by native_decide
example : headline "abcdefgh" 5 = "abcde…" := by native_decide

end Viewer
