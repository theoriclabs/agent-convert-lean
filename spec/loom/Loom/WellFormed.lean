import Loom.Core

/-!
# Loom — well-formedness

Well-formedness is a **family**, not one predicate:

* `violations` / `WellFormed` — structural integrity of the IR itself
  (decidable, O(n), local checks only). That is the *what*: this file
  defines validity, full stop.
* Export readiness is *per target* and is a how-question — it lives in
  `LoomOps.Conversion.obligations`. A transcript can be perfectly
  well-formed and still need repairs before a given harness will resume it
  (the 2.27 orphan-`tool_use` closing is a Claude export obligation, not an
  IR defect).

Violations are an enumeration, not a `Bool`: tooling wants the list, proofs
want the predicate. `WellFormed t := violations t = []` gives both.

Scope note (v0, deliberate): references can only target *top-level* assistant
blocks. Blocks nested inside `toolResult.content` cannot contain calls by type,
so there is no recursive reference surface to validate.
-/

namespace Loom

/-- Everything that can be structurally wrong with a `Transcript`. Each
constructor names a defect class observed in the wild in the TS toolchain. -/
inductive Violation where
  /-- A transcript has exactly one root conversation thread. Zero roots make
  mainline export ambiguous; multiple roots make it under-specified. -/
  | mainThreadCount (count : Nat)
  /-- Parent reference does not point strictly earlier: normal-form breach.
  Subsumes cycles (phase-1 cycle-guard DoS) and dangling forward refs. -/
  | parentNotEarlier (entry parent : Nat)
  /-- Parent and child entries must belong to the same thread. Sidechains are
  connected to the main conversation by `ThreadKind.sidechain`, not by an entry
  parent that crosses thread boundaries. -/
  | parentThreadMismatch (entry parent entryThread parentThread : Nat)
  /-- Entry references a thread index that does not exist. -/
  | threadOutOfRange (entry thread : Nat)
  /-- A tool result resolves to a call at the same or a later entry:
  results must follow their calls. -/
  | callRefNotEarlier (entry refEntry : Nat)
  /-- A tool result whose call could not be resolved (orphan result —
  truncated import, corrupt source). -/
  | unresolvedCallRef (entry : Nat) (note : String)
  /-- A resolved result names a block index that does not exist. -/
  | callRefBlockOutOfRange (entry refEntry refBlock : Nat)
  /-- A resolved result names an existing block that is not a tool call. -/
  | callRefNotToolCall (entry refEntry refBlock : Nat)
  /-- A sidechain must use a resolved anchor. An unresolvable child is modeled
  as `ThreadKind.detached`, not as a falsely anchored sidechain. -/
  | unresolvedSidechainAnchor (thread : Nat) (note : String)
  /-- A sidechain anchor names an entry outside the transcript. -/
  | sidechainAnchorEntryOutOfRange (thread refEntry : Nat)
  /-- A sidechain anchor names a block outside its entry. -/
  | sidechainAnchorBlockOutOfRange (thread refEntry refBlock : Nat)
  /-- A sidechain anchor must name an assistant tool call. -/
  | sidechainAnchorNotToolCall (thread refEntry refBlock : Nat)
  /-- Sidechains are spawned from the main conversation, so their anchor must
  live on the unique main thread. -/
  | sidechainAnchorNotMain (thread refEntry refThread : Nat)
  /-- `activeLeaf` points outside the entry array. -/
  | activeLeafOutOfRange (leaf : Nat)
  /-- `activeLeaf` points to an entry that has a child, so it is not a leaf. -/
  | activeLeafHasChild (leaf : Nat)
  /-- A compaction's `firstKept` points outside the entry array. -/
  | compactionKeptOutOfRange (entry firstKept : Nat)
  deriving Repr, DecidableEq

-- Tool results (the only CallRef-bearing blocks) now live solely in `envMsg`
-- (role-content-sum), so only env blocks need checking; user/assistant blocks
-- structurally cannot carry a CallRef.
private def callTargetViolations (t : Transcript) (idx refEntry refBlock : Nat) : List Violation :=
  match t.entries[refEntry]? with
  | none => [.callRefNotEarlier idx refEntry]
  | some e =>
      match e.payload with
      | .assistantMsg blocks =>
          match blocks[refBlock]? with
          | none => [.callRefBlockOutOfRange idx refEntry refBlock]
          | some (.toolCall _ _ _) => []
          | some _ => [.callRefNotToolCall idx refEntry refBlock]
      | _ => [.callRefNotToolCall idx refEntry refBlock]

private def envBlockViolations (t : Transcript) (idx : Nat) (b : EnvBlock) : List Violation :=
  match b with
  | .toolResult (.resolved refEntry refBlock) _ _ =>
      if refEntry ≥ idx then [.callRefNotEarlier idx refEntry]
      else callTargetViolations t idx refEntry refBlock
  | .toolResult (.unresolved _ note) _ _ =>
      [.unresolvedCallRef idx note]
  | _ => []

private def mainThreadCount (t : Transcript) : Nat :=
  t.threads.toList.countP fun th => th.kind == ThreadKind.main

private def mainThreadIndex? (t : Transcript) : Option Nat :=
  (t.threads.toList.zipIdx.find? fun p => p.1.kind == ThreadKind.main).map (·.2)

private def sidechainAnchorViolations (t : Transcript) (mainIdx : Option Nat)
    (threadIdx : Nat) (anchor : CallRef) : List Violation :=
  match anchor with
  | .unresolved _ note => [.unresolvedSidechainAnchor threadIdx note]
  | .resolved refEntry refBlock =>
      match t.entries[refEntry]? with
      | none => [.sidechainAnchorEntryOutOfRange threadIdx refEntry]
      | some e =>
          let mainViolation :=
            match mainIdx with
            | some m => if e.thread == m then [] else [.sidechainAnchorNotMain threadIdx refEntry e.thread]
            | none => []
          let targetViolation :=
            match e.payload with
            | .assistantMsg blocks =>
                match blocks[refBlock]? with
                | none => [.sidechainAnchorBlockOutOfRange threadIdx refEntry refBlock]
                | some (.toolCall _ _ _) => []
                | some _ => [.sidechainAnchorNotToolCall threadIdx refEntry refBlock]
            | _ => [.sidechainAnchorNotToolCall threadIdx refEntry refBlock]
          mainViolation ++ targetViolation

/-- All structural violations, in entry order. Computable — this is the
function a Lean⇔Host bridge exposes as a validation oracle. -/
def violations (t : Transcript) : List Violation := Id.run do
  let mut vs : Array Violation := #[]
  let mains := mainThreadCount t
  if mains != 1 then
    vs := vs.push (.mainThreadCount mains)
  let mut i : Nat := 0
  for e in t.entries do
    if let some p := e.parent then
      if p ≥ i then
        vs := vs.push (.parentNotEarlier i p)
      else if let some pe := t.entries[p]? then
        if pe.thread != e.thread then
          vs := vs.push (.parentThreadMismatch i p e.thread pe.thread)
    if e.thread ≥ t.threads.size then
      vs := vs.push (.threadOutOfRange i e.thread)
    match e.payload with
    | .envMsg blocks =>
        for b in blocks do
          for v in envBlockViolations t i b do
            vs := vs.push v
    | .compaction _ (.knownPrefix k) _ =>
        if k ≥ t.entries.size then
          vs := vs.push (.compactionKeptOutOfRange i k)
    | _ => pure ()
    i := i + 1
  let mainIdx := mainThreadIndex? t
  let mut threadIdx : Nat := 0
  for th in t.threads do
    match th.kind with
    | .sidechain anchor =>
        for v in sidechainAnchorViolations t mainIdx threadIdx anchor do
          vs := vs.push v
    | _ => pure ()
    threadIdx := threadIdx + 1
  if let some l := t.activeLeaf then
    if l ≥ t.entries.size then
      vs := vs.push (.activeLeafOutOfRange l)
    else if t.entries.toList.any (fun e => e.parent == some l) then
      vs := vs.push (.activeLeafHasChild l)
  return vs.toList

/-- Structural well-formedness. Decidable, so it can gate imports
mechanically: importers return `Except ImportRefusal Checked`, never a
silently-broken transcript (the typed-refusal-before-runtime pattern). -/
def WellFormed (t : Transcript) : Prop := violations t = []

instance (t : Transcript) : Decidable (WellFormed t) :=
  inferInstanceAs (Decidable (violations t = []))

/-- A transcript that has passed the structural checks. Consumers written
against `Checked` need no defensive cycle guards — the guarantee travels
with the value. -/
abbrev Checked := { t : Transcript // WellFormed t }

end Loom
