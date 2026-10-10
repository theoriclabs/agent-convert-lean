import Std.Data.HashMap
import Viewer.Conversation

/-! # The catalog

What is on disk, per harness store, and what each file says about itself. The scan is cheap and
never cached (a session being written changes under the viewer); what is cached is the work per
file, keyed by `(path, modifiedMs)` so a rewritten file is never served stale. Previews are read
from a bounded prefix because stores hold gigabytes; conversations are read whole, and only the
last few stay in memory. -/

namespace Viewer

/-- A cache key: the path and the modification time. -/
private def cacheKey (file : SessionFile) : String := s!"{file.path}#{file.modifiedMs}"

private def pathOf (file : SessionFile) : System.FilePath := ⟨file.path⟩

/-- The most recently imported conversations, at most `capacity`, oldest inserted first in `order`. -/
structure ConversationCache where
  entries : Std.HashMap String Conversation := ∅
  order : Array String := #[]

namespace ConversationCache

def capacity : Nat := 8

/-- Insert, dropping the oldest entry past `capacity`. -/
def insert (c : ConversationCache) (key : String) (value : Conversation) : ConversationCache :=
  if c.entries.contains key then { c with entries := c.entries.insert key value } else
  let c : ConversationCache := { entries := c.entries.insert key value, order := c.order.push key }
  if c.order.size ≤ capacity then c else
  match c.order[0]? with
  | some oldest => { entries := c.entries.erase oldest, order := c.order.extract 1 c.order.size }
  | none => c

end ConversationCache

structure Catalog where
  /-- Store roots are `<home>/<Store.root>`. -/
  home : String
  previews : IO.Ref (Std.HashMap String Preview)
  conversations : IO.Ref ConversationCache

def Catalog.create (home : String) : IO Catalog := do
  return { home, previews := ← IO.mkRef ∅, conversations := ← IO.mkRef {} }

/-! ## The scan -/

/-- Files at most `depth` directory levels under `root` whose name ends with `suffix`. Loom's
rule: depth-bounded, and a missing or unreadable directory is an empty result, never an error. -/
partial def filesEndingWith (root : System.FilePath) (suffix : String) (depth : Nat) :
    IO (Array System.FilePath) := do
  if depth == 0 then return #[]
  unless ← root.isDir do return #[]
  let entries ← try root.readDir catch _ => pure #[]
  let mut hits : Array System.FilePath := #[]
  for entry in entries do
    if ← entry.path.isDir then
      hits := hits ++ (← filesEndingWith entry.path suffix (depth - 1))
    else if entry.fileName.endsWith suffix then
      hits := hits.push entry.path
  return hits

/-- Milliseconds since the epoch; a time before it clamps to 0. -/
private def modifiedMsOf (m : IO.FS.Metadata) : Nat :=
  (m.modified.sec * 1000 + (m.modified.nsec.toNat / 1000000 : Nat)).toNat

/-- The session file behind a path in `h`'s store; `none` when its metadata cannot be read. -/
private def sessionFileOf (h : Harness) (path : System.FilePath) : IO (Option SessionFile) := do
  let store := h.store
  let some name := path.fileName | return none
  let stem := String.ofList (name.toList.take (name.length - store.suffix.length))
  try
    let info ← path.metadata
    return some {
      harness := h
      id := store.sessionId stem
      path := path.toString
      modifiedMs := modifiedMsOf info
      bytes := info.byteSize.toNat }
  catch _ => return none

/-- Every session file in every store, newest first. -/
def Catalog.scan (c : Catalog) : IO (Array SessionFile) := do
  let mut files : Array SessionFile := #[]
  for h in Harness.all do
    let store := h.store
    let root : System.FilePath := (⟨c.home⟩ : System.FilePath) / store.root
    for path in (← filesEndingWith root store.suffix store.depth).filter (fun p => store.isSession (p.fileName.getD "")) do
      if let some file ← sessionFileOf h path then files := files.push file
  return files.qsort fun a b => a.modifiedMs > b.modifiedMs

/-- The file with that harness and id, if the store holds one. -/
def Catalog.find (c : Catalog) (h : Harness) (id : String) : IO (Option SessionFile) := do
  return (← c.scan).find? fun f => f.harness == h && f.id == id

/-! ## Previews -/

/-- How much of a session file a preview reads. -/
def previewLimit : Nat := 262144

/-- The index of the last newline byte in `b` before position `n`. -/
private def lastNewline (b : ByteArray) : Nat → Option Nat
  | 0 => none
  | i + 1 => if b[i]! == 10 then some i else lastNewline b i

/-- Up to the first `previewLimit` bytes of a JSONL file as text. A longer file is cut at the last
newline of the prefix: a newline byte never sits inside a multibyte character, so the cut is on a
character boundary and the text is a complete-line prefix, which every JSONL importer reads as a
shorter transcript. Should the prefix still not decode, the whole file is read instead. -/
private def readPrefix (path : System.FilePath) : IO String := do
  let handle ← IO.FS.Handle.mk path .read
  let bytes ← handle.read previewLimit.toUSize
  let bytes := if bytes.size < previewLimit then bytes else
    match lastNewline bytes bytes.size with
    | some i => bytes.extract 0 (i + 1)
    | none => bytes
  match String.fromUTF8? bytes with
  | some text => return text
  | none => IO.FS.readFile path

/-- What a parse failure yields. -/
def Preview.unknown : Preview := { title := none, cwd := none, model := none, startedMs := none, turns := 0 }

/-- The preview of a session, cached by `(path, modifiedMs)`. A file that cannot be read or parsed
yields `Preview.unknown` and one line on stderr. -/
def Catalog.preview (c : Catalog) (file : SessionFile) : IO Preview := do
  let key := cacheKey file
  if let some preview := (← c.previews.get).get? key then return preview
  let store := file.harness.store
  let parsed : Except String Loom.Transcript ← try
      let text ← if store.suffix == ".jsonl" then readPrefix (pathOf file) else IO.FS.readFile (pathOf file)
      pure (store.parse text)
    catch e => pure (.error (toString e))
  let preview ← match parsed with
    | .ok t => pure (Preview.ofTranscript file.harness t)
    | .error e => do
      IO.eprintln s!"loom viewer: no preview for {file.harness.slug} {file.id} ({file.path}): {e}"
      pure Preview.unknown
  c.previews.modify (·.insert key preview)
  return preview

/-! ## Conversations -/

/-- The whole file through the harness's importer, cached (the last few) by `(path, modifiedMs)`. -/
def Catalog.conversation (c : Catalog) (file : SessionFile) : IO (Except String Conversation) := do
  let key := cacheKey file
  if let some conversation := (← c.conversations.get).entries.get? key then return .ok conversation
  let text ← try IO.FS.readFile (pathOf file) catch e => return .error (toString e)
  match (file.harness.store).parse text with
  | .error e => return .error e
  | .ok t =>
    let conversation := Conversation.ofTranscript file.harness t
    c.conversations.modify (·.insert key conversation)
    return .ok conversation

/-! ## Pages -/

/-- One page of the catalog. -/
structure Page where
  harness : Option Harness := none
  /-- A case-insensitive substring of the id, path, title or cwd (the last two only when the
  preview is already known). Empty matches everything. -/
  text : String := ""
  offset : Nat := 0
  limit : Nat := 40
  deriving Repr, Inhabited

/-- `needle` (lower-cased, non-empty) occurs in `hay`, ignoring case. -/
private def containsText (hay needle : String) : Bool :=
  (hay.toLower.splitOn needle).length > 1

/-- The sessions on a page, newest first, with the count of every session matching the query.
Previews are computed for the page only. -/
def Catalog.page (c : Catalog) (p : Page) : IO (Array Session × Nat) := do
  let files ← c.scan
  let previews ← c.previews.get
  let needle := p.text.toLower
  let keep (f : SessionFile) : Bool :=
    (match p.harness with
      | some h => f.harness == h
      | none => true) &&
    (needle.isEmpty || containsText f.id needle || containsText f.path needle ||
      (match previews.get? (cacheKey f) with
        | some preview => preview.title.any (containsText · needle) || preview.cwd.any (containsText · needle)
        | none => false))
  let hits := files.filter keep
  let mut sessions : Array Session := #[]
  for file in hits.extract p.offset (p.offset + p.limit) do
    sessions := sessions.push { file, preview := ← c.preview file }
  return (sessions, hits.size)

end Viewer
