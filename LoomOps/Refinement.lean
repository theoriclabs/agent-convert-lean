import LoomOps.Conversion

/-!
# Loom.Ops — the refinement lattice (Design.lean center, first increment)

The rest of `LoomOps.Design` beyond the role-content sum: express each
format's structural constraints as a **decidable predicate** `wf_F :
Transcript → Bool` (the `WF_F` family), order them by implication into an
**expressiveness lattice**, and show that:

* the support matrix (`Loom.Formats.supports`) is the lattice's dual — a
  format supports concept C iff a `wf_F`-valid transcript can carry C;
* export obligations (`LoomOps.Conversion.obligations`) are the **predicate
  diff** — exporting to F′ must establish exactly the constraints `wf_F′`
  adds over `wf_F`.

Per Design.lean's own caveat ("do not let the lattice's beauty pull the whole
thing dependent-typed"), this is decidable Bool predicates over the ONE
grammar — checkable per-transcript, no theorems, no `FormatSpec`-indexed
`Transcript`. The universal claims (∀ t, edge holds) are description-first
targets a corpus scan confirms; here they are decidable on any concrete t.
-/

namespace Loom.Ops
open Loom

/-! ## The WF_F family — each format's constraints as a predicate.

Built from the existing feature probes (`hasBranches`, `hasCompaction`,
`hasSidechains`, time). A format's predicate encodes what a VALID transcript
of that format looks like: the poorer the format, the stricter the predicate. -/

private def allAbsentTime (t : Transcript) : Bool :=
  t.entries.toList.all (fun e => match e.time with | .absent => true | _ => false)

/-- cursor-agent: linear, timeless, no compaction, no sidechains — the
format's expressive poverty, as a constraint. -/
def wfCursorAgent (t : Transcript) : Bool :=
  (! hasBranches t) && (! hasCompaction t) && (! hasSidechains t) && allAbsentTime t

/-- codex: linear (no parentId graph), no sidechains in the flattened read. -/
def wfCodex (t : Transcript) : Bool :=
  (! hasBranches t) && (! hasSidechains t)

/-- hermes: linear, no compaction, no sidechains. -/
def wfHermes (t : Transcript) : Bool :=
  (! hasBranches t) && (! hasCompaction t) && (! hasSidechains t)

/-- google-ai-studio: linear, no compaction, no sidechains (branching is
present in the source but linearized on import). -/
def wfGais (t : Transcript) : Bool :=
  (! hasBranches t) && (! hasCompaction t) && (! hasSidechains t)

/-- pi: the most permissive of the on-disk formats — branching, compaction,
native time all allowed; only sidechains are absent (pi's one gap). -/
def wfPi (t : Transcript) : Bool :=
  ! hasSidechains t

/-- claude: the top of the lattice — everything (branching, sidechains,
compaction, native time). -/
def wfClaude (_ : Transcript) : Bool := true

def wfFormat : Format → Transcript → Bool
  | .cursorAgent    => wfCursorAgent
  | .codexCli       => wfCodex
  | .hermes         => wfHermes
  | .googleAiStudio => wfGais
  | .pi             => wfPi
  | .claudeCode     => wfClaude
  | _               => fun _ => true

/-! ## The lattice — predicates ordered by implication. -/

/-- `strict` refines `loose`: every `wf_strict`-valid transcript is
`wf_loose`-valid (strict is more constrained ⇒ less expressive). -/
structure RefinementEdge where
  strict : Format
  loose  : Format
  note   : String
  deriving Repr

def latticeEdges : List RefinementEdge := [
  { strict := .cursorAgent, loose := .pi,
    note := "cursor-agent (linear, timeless, no compaction) ⊑ pi" },
  { strict := .codexCli, loose := .pi,
    note := "codex (linear) ⊑ pi (branching, compaction)" },
  { strict := .hermes, loose := .pi,
    note := "hermes (linear, no compaction) ⊑ pi" },
  { strict := .googleAiStudio, loose := .pi,
    note := "gais (linearized) ⊑ pi" },
  { strict := .pi, loose := .claudeCode,
    note := "pi (no sidechains) ⊑ claude (sidechains too) — claude is the top" }
]

/-- Check an edge on a concrete transcript: `wf_strict t → wf_loose t`. The
lattice is the claim this holds for ALL t; decidable here per-t, so
`latticeEdges.all (edgeHoldsOn t)` validates the recorded lattice against any
sample (the description-first upgrade path — a corpus scan confirms it
universally; a theorem is the far, optional end). -/
def edgeHoldsOn (t : Transcript) (e : RefinementEdge) : Bool :=
  (! wfFormat e.strict t) || wfFormat e.loose t

def latticeHoldsOn (t : Transcript) : Bool :=
  latticeEdges.all (edgeHoldsOn t)

/-! ## Obligations = the predicate diff.

Exporting to F′ must establish the constraints `wf_F′` adds. A transcript
needs work for F′ exactly when `wfFormat F′ t = false`; WHICH work = which
constraint fails. This parallels `LoomOps.Conversion.obligations`, showing
that function is the decategorified shadow of the predicate diff. -/

/-- The structural constraints of `wf_tgt` that transcript `t` violates — the
work an exporter to `tgt` must do, derived from the predicate rather than
enumerated by hand. -/
def predicateDiff (tgt : Format) (t : Transcript) : List String := Id.run do
  if wfFormat tgt t then
    return []   -- already valid for tgt: nothing to establish (lossless coerce up)
  let mut out : Array String := #[]
  -- decompose which constraint of wf_tgt fails on t:
  if hasBranches t && (tgt == Format.cursorAgent || tgt == Format.codexCli
      || tgt == Format.hermes || tgt == Format.googleAiStudio) then
    out := out.push "linearizeBranches (wf_tgt forbids branching)"
  if hasCompaction t && (tgt == Format.cursorAgent || tgt == Format.hermes
      || tgt == Format.googleAiStudio) then
    out := out.push "dropCompaction (wf_tgt forbids compaction)"
  if hasSidechains t && tgt != Format.claudeCode then
    out := out.push "dropSidechains (only claude's wf permits sidechains)"
  if (! allAbsentTime t) && tgt == Format.cursorAgent then
    out := out.push "dropTime (cursor-agent is timeless)"
  return out.toList

end Loom.Ops
