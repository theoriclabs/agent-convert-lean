import Loom.Core

/-!
# Loom — the turn view (S13, claim L8)

A "turn" is a **derived view**, not stored data (claim L8): a user message
plus the responses (assistant / environment / events) that follow it, up to
the next user message. L8 deferred this because "turn" was per-harness and a
premature definition would freeze a wrong shape. The role-content-sum resolves
that: with role-indexed messages over ONE IR, a turn boundary is exactly a
`userMsg`, so a single canonical view works across every format — and
cross-format turn-count parity becomes a property of this one view function
applied to each importer's output, not a per-harness reimplementation.

Defined over the entries array (the linear order importers produce). For a
branched transcript this is the file-order view; a path-relative view is a
thin variation over a chosen leaf (future, if needed).
-/

namespace Loom

/-- A user message opens a turn; nothing else does. (Codex `developer` maps to
`assistantMsg`, so it is not a boundary — turns are user-initiated.) -/
def Payload.isTurnBoundary : Payload → Bool
  | .userMsg _ => true
  | _ => false

/-- One turn: the index of its opening user message (`none` for a leading
non-user preamble before any user message), and all entry indices it covers. -/
structure Turn where
  opener  : Option Nat
  entries : List Nat
  deriving Repr, DecidableEq

/-- Group a transcript's entries into turns, in order: a new turn begins at
each user message; non-user entries attach to the current turn. -/
def turns (t : Transcript) : List Turn := Id.run do
  let mut result : Array Turn := #[]
  let mut cur : Option Turn := none
  let mut i : Nat := 0
  for e in t.entries do
    if e.payload.isTurnBoundary then
      if let some c := cur then result := result.push c
      cur := some { opener := some i, entries := [i] }
    else
      match cur with
      | some c => cur := some { c with entries := c.entries ++ [i] }
      | none   => cur := some { opener := none, entries := [i] }  -- leading preamble
    i := i + 1
  if let some c := cur then result := result.push c
  return result.toList

/-- The canonical turn count — the cross-format-comparable metric (each side
is `turnCount (importF file)` over the unified IR). -/
def turnCount (t : Transcript) : Nat := (turns t).length

/-- Which turn (0-indexed) an entry belongs to, or `none` if out of range. -/
def turnOfEntry (t : Transcript) (entryIdx : Nat) : Option Nat := Id.run do
  let ts := turns t
  let mut ti : Nat := 0
  for turn in ts do
    if turn.entries.contains entryIdx then return some ti
    ti := ti + 1
  return none

end Loom
