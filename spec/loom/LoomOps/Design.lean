/-!
# Loom.Ops — ontology design analysis

A design exploration (2026-07-07, branch thread): how to formalize the
transcript domain in Lean more strongly, leaner, more accurately. Recorded
as typed data so the methods and their centers are queryable and compose
with the rest of the meta-state; the prose that resists typing lives here.

## The lens: where does format-specific truth live?

Every method is a different answer to one question — where does the fact
"Cursor-CLI has no timestamps" physically reside? The test that separates
good answers from bad: **what nonsense does the method make unrepresentable,
and what truth does it force you to write down?** (The honest-description
thesis, turned into a type-theory criterion.)

By that test the current design (`union-container`) scores poorly in a
precise way: it has ONE widest IR plus an EXTERNAL matrix
(`supports : Format → Concept → Support`) — truth lives in data BESIDE the
types, not IN them. So `message .user [.toolCall …]` (a user message holding
a tool call) typechecks; so does a Cursor-CLI transcript with
`Time.recorded`. Three parallel structures (IR, matrix, WellFormed/
obligations) that can drift. That drift-surface is the real cost.

## The unification worth chasing (the elegance argument)

"Leaner" should mean *fewer moving parts that can drift*. The refinement
lattice collapses THREE of our structures into ONE: WellFormed is the base
predicate `WF_loom`; the support matrix is the per-format family `WF_F`;
export obligations (F→F′) are exactly the **predicate diff** — the conjuncts
`WF_F` permits that `WF_F′` forbids, which is what an exporter must resolve.
Conversion becomes navigation in the lattice: coerce losslessly up when
`WF_F ⟹ WF_F′`, project lossily down to satisfy the stricter predicate. One
predicate family subsumes validity, expressiveness, and loss — three things
that can currently drift become one that cannot. And it is AFFORDABLE
because our invariants are decidable and we are description-first: it costs
decidable predicate definitions (`⟨g, by decide⟩`, the `Checked` move we
already make), not proof engineering. The flat `supports` matrix is this
lattice **decategorified** — its per-concept-boolean shadow.

## The through-line and the caveat

Organize around the **refinement lattice** (formats as ordered decidable
predicates over one grammar) with an **event-log-flavored, role-indexed
content core** underneath. Leaner (fewer drift-prone parts), more elegant
(one family does three jobs), more accurate (per-format nonsense becomes
unrepresentable) — reachable in decidable steps, no theorems.

CAVEAT: do not let the lattice's beauty pull the whole thing dependent-typed.
The moment `Transcript` is indexed by a `FormatSpec`, generic tools need
`∀ spec` and definitional-equality fights begin. Subtypes over a FIXED grammar
stay in the ergonomic sweet spot; the indexed family is the line not to cross
yet (that is method `generative-universe`, the far ceiling).
-/

namespace Loom.Ops.Design

/-- A formalization strategy for the domain. `center` = the one load-bearing
idea everything orbits (the thing the user asked to name). The honest-
description test is split across `unrepresentable` (nonsense it forbids) and
`forcesYouToState` (truth it makes you write down). -/
structure Method where
  id              : String
  name            : String
  center          : String
  unrepresentable : String
  forcesYouToState : String
  leanness        : String
  cost            : String
  verdict         : String
  deriving Repr

def methods : List Method := [
  { id := "union-container"
    name := "Union container + side-table (CURRENT)"
    center := "One widest concrete type; format truth lives in an external matrix beside the types."
    unrepresentable := "Almost nothing per-format: user-message-with-toolCall and Cursor-CLI-with-timestamps both typecheck."
    forcesYouToState := "Only the base structural shape; the matrix is an optional promise the IR does not keep."
    leanness := "Simplest to start; but three parallel structures (IR, matrix, obligations) that drift."
    cost := "The matrix can lie relative to the IR; escape hatches (unmodeled/approximate) proliferate."
    verdict := "Fine as a v0 scaffold; the thing to move past." },
  { id := "refinement-lattice"
    name := "Refinement lattice (the proposal)"
    center := "One grammar G; each format is a decidable predicate WF_F : G → Prop, and the predicates are ORDERED by implication into an expressiveness lattice."
    unrepresentable := "Per-format malformed values: an importer for F cannot produce a transcript that violates WF_F (it must discharge it)."
    forcesYouToState := "Each format's invariants AS a predicate; the lattice edges (which format refines which) become the loss story."
    leanness := "Leanest: subsumes WellFormed + matrix + obligations into one predicate family. Matrix becomes its decategorified shadow."
    cost := "A format richer than the core still forces G to grow (unavoidable in any single-hub design). Subtype ergonomics — but decidable, so `by decide`, not proofs."
    verdict := "RECOMMENDED CENTER for the format layer." },
  { id := "faithful-surface-typeclass"
    name := "Faithful per-format types + typeclass"
    center := "Each format is its OWN honest grammar (Claude's 14 line-kinds are 14 constructors); sharing is behavioral via a typeclass, not a shared data type."
    unrepresentable := "The most: each type IS its format, so format-illegal states cannot be built at all."
    forcesYouToState := "The full real grammar of every format, up front."
    leanness := "Maximal accuracy, zero union-committee compromise; but no shared data type, so conversion is bespoke and tools re-invent a lowest-common-denominator interface."
    cost := "The typeclass's Option-returning methods re-encode the matrix as signatures; N² conversion pressure without a hub."
    verdict := "RECOMMENDED as the SURFACE layer, refined into the shared core." },
  { id := "concept-columns"
    name := "Concept columns (relational shred)"
    center := "Concepts are orthogonal axes; a format is a subset of columns, each independently typed."
    unrepresentable := "Absence becomes a missing field (structural), not a runtime tag; a format lacking time literally has no time column."
    forcesYouToState := "Which axes a format has, and each axis's representation."
    leanness := "Very lean per-axis; adding a concept never disturbs existing formats."
    cost := "Transcripts are row-shaped (a line carries id+time+role+content together); shredding fights the grain and makes row-reassembly the hard part."
    verdict := "Elegant in theory, awkward for a linked-list-of-turns medium." },
  { id := "generative-universe"
    name := "Generative universe (Tarski-style)"
    center := "The format ontology is itself a datatype; Transcript : FormatSpec → Type interprets a format-description into its type. The matrix becomes generative, not descriptive."
    unrepresentable := "Everything the FormatSpec excludes, by construction; types cannot drift from the spec because they are computed from it."
    forcesYouToState := "A total, orthogonal factoring of the whole domain into a spec language."
    leanness := "Maximal DRY and the elegant end-state — one interpreter, N formats as data."
    cost := "Dependent-type ergonomics (∀ spec, defeq fights); the premature-theoremization trap; idiosyncrasies (Codex duality, sidecar files) resist clean factoring."
    verdict := "Far ceiling. Name it; do NOT build it yet." },
  { id := "event-log"
    name := "Typed event log"
    center := "A transcript literally IS a typed append-only log; threading is derived from parent fields. Most faithful to the on-disk medium."
    unrepresentable := "Makes 'thinking is a thing' true by construction (its own event kind — exactly Codex's reasoning record)."
    forcesYouToState := "The event vocabulary; each event kind precisely typed."
    leanness := "Matches what transcripts actually are (Claude/Codex/pi are event logs)."
    cost := "Prefers flat, so Claude's nested blocks-in-a-message must stay nested inside a MessageAdded event or be flattened (mirror of the columns tension)."
    verdict := "RECOMMENDED flavor for the content/temporal core, under the refinement lattice." }
]

/-- A content-level ontology fork the current flat `(role, List Block)`
encoding leaves implicit — the sharp part of the user's intuition
(message is a thing, thinking is a thing, user/agent messages have sub-formats). -/
structure ContentFork where
  id              : String
  question        : String
  currentEncoding : String
  betterEncoding  : String
  recommendation  : String
  deriving Repr

def contentForks : List ContentFork := [
  { id := "role-content-correlation"
    question := "May a user message contain a tool call?"
    currentEncoding := "message (role : Role) (blocks : List Block) — yes, `message .user [.toolCall …]` typechecks (representable nonsense)."
    betterEncoding := "A sum indexed by author: Message = user UserContent | assistant AssistantContent | env ToolResult, each carrying only its admissible content."
    recommendation := "DO THIS FIRST — highest value, lowest cost. Your sub-formats made structural; kills a whole nonsense class for free." },
  { id := "message-stream-vs-record"
    question := "Is a message an ordered stream of blocks, or a structured record of facets?"
    currentEncoding := "Ordered List Block (preserves think→text→think interleaving; does not capture that they are facets of one turn)."
    betterEncoding := "A record { thinking, text, calls } captures the facet grouping but LOSES interleaving order. No free lunch: Claude/pi are stream-shaped; a turn abstraction is record-shaped."
    recommendation := "Keep an ORDERED content sequence INSIDE each role-typed message; do not rotate to pure records and silently lose interleaving." },
  { id := "thinking-location"
    question := "Is thinking nested in a message, or its own peer thing?"
    currentEncoding := "Block.thinking (nested) — which forces Codex's SIBLING reasoning record and GAIS's thought PART into a nested position."
    betterEncoding := "Thinking is first-class ASSISTANT CONTENT in the IR; nested-vs-sibling-vs-part is a per-format SERIALIZATION disposition, not a different shape."
    recommendation := "Treat nesting as a disposition, not an ontology fork. Dissolves the Codex-reasoning vs Claude-thinking tension we currently paper over." }
]

/-- The staged recommendation (graduated formalization: cheap decidable wins
now, structural split when it earns it, the elegant ceiling deferred). -/
structure DesignStep where
  stage     : String
  change    : String
  rationale : String
  refs      : List String := []
  deriving Repr

def recommendation : List DesignStep := [
  { stage := "now"
    change := "Role-indexed content sum for messages; thinking as assistant-content with nesting-as-disposition; reframe the matrix as the derived shadow of a decidable WF_F predicate family."
    rationale := "All decidable, no theorems, high accuracy — makes per-format nonsense unrepresentable and stops the IR/matrix/obligations trio from drifting."
    refs := ["role-content-correlation", "thinking-location", "refinement-lattice"] },
  { stage := "medium"
    change := "Split SURFACE (faithful per-format type, method faithful-surface-typeclass) from CORE (shared refined IR, method refinement-lattice). Today Loom collapses them."
    rationale := "The pain of mapping straight-to-core will show the seam when the second importer lands. Surface = accuracy, core = leverage; stop choosing."
    refs := ["faithful-surface-typeclass", "refinement-lattice", "S16-lean-importers"] },
  { stage := "far-ceiling"
    change := "The generative universe (Transcript : FormatSpec → Type). Name it, do not build it."
    rationale := "Where it wants to end once the ontology stops moving; building now spends the budget on encoding and the idiosyncrasies are not stable enough to factor."
    refs := ["generative-universe"] }
]

/-- Recommended-center methods, as a query. -/
def recommendedMethods : List Method :=
  methods.filter (fun m => m.id == "refinement-lattice"
                        || m.id == "faithful-surface-typeclass"
                        || m.id == "event-log")

/-!
## Are we using dependent / refinement types WELL? (2026-07-07)

Audit: barely. One top-level refinement (`Checked = {t // WellFormed t}`);
everything else is EXTRINSIC (`violations` is a runtime check) or plain sums.
Large headroom.

**The key distinction — two kinds of dependent typing, only one costs proofs:**
* *Guarantee-by-construction* (Fin-indexed refs, intrinsically-typed syntax,
  indexed families): the constructor IS the proof. Zero theorem burden —
  fully compatible with description-over-proofs.
* *Prop-proving* (`{t // P t}` with nontrivial P): costs proof engineering.

Our "no theorems" stance forbids the second, not the first. The first is
wide open and unused. So pushing dependent types HARD is not in tension with
the doctrine — as long as we push the construction-guarantee kind.

**The spectrum** for any invariant:
extrinsic check (bad states representable, validity a separate function) →
refinement `{t // P t}` (representable, validity attached, carry proofs) →
intrinsic index (bad states UNREPRESENTABLE). "Push further" = move
extrinsic → intrinsic exactly where it pays.

**The boundary that decides how far:** intrinsic typing is lovely to FOLD
(convert = consume the whole thing) but hostile to MUTATE (an edit re-indexes
everything, every structural change becomes a re-proof). So: push intrinsic
in the convert/fold core; stay looser where piview/piedit MUTATE (compact,
trim, split, append) — smart constructors that re-establish invariants over
a looser rep.
-/

/-- One place the type system could be stronger, and how far to push. -/
structure TypingLever where
  id              : String
  invariant       : String
  currentEncoding : String
  strongerEncoding : String
  mechanism       : String   -- extrinsic | refinement | dependent-sum | intrinsic-index
  payoff          : String
  cost            : String
  verdict         : String
  deriving Repr

def typingLevers : List TypingLever := [
  { id := "intrinsic-well-scoping"
    invariant := "parent + tool-result refs point to valid strictly-earlier entries (no cycles, forward-refs, or dangling refs)."
    currentEncoding := "parent : Option Nat, CallRef, checked extrinsically by `violations` at runtime — bad states representable."
    strongerEncoding := "entry i's parent : Fin i; tool-result refs indexed by the in-scope call-context (well-scoped de Bruijn syntax)."
    mechanism := "intrinsic-index"
    payoff := "Discharges claims L1 + L1b AND the dangling-ref/cycle bug classes BY CONSTRUCTION — and needs NO theorems (construction = proof)."
    cost := "Transformations (piedit edits) become re-indexing proofs; great for fold/convert, hostile to mutate."
    verdict := "PUSH — the single biggest win. In the convert/fold CORE; surface stays loose, importer type is Loose → Except Err Ordered (the topo-sort IS the evidence)." },
  { id := "format-refinements"
    invariant := "each format's expressiveness / well-formedness (WF_F)."
    currentEncoding := "external matrix `supports : Format → Concept → Support` beside the types."
    strongerEncoding := "decidable, composable refinements `{ t // WF_F t }`, ordered into the expressiveness lattice."
    mechanism := "refinement"
    payoff := "Matrix becomes the derived shadow; per-format malformed is unrepresentable-as-refined; unifies WellFormed + matrix + obligations."
    cost := "Carry proofs — but decidable, so `by decide`, cheap."
    verdict := "PUSH (the refinement-lattice center)." },
  { id := "role-content-sum"
    invariant := "role determines admissible content (no user-message-with-toolCall)."
    currentEncoding := "message (role : Role) (blocks : List Block) — nonsense representable."
    strongerEncoding := "a plain SUM: user UserContent | assistant AssistantContent | env ToolResult."
    mechanism := "dependent-sum"
    payoff := "Kills the nonsense class; leaner."
    cost := "None for the plain sum. The DEPENDENT family (Content : Role → Type) adds cost for no gain unless role-generic code exists."
    verdict := "USE THE SUM. Go dependent only if role-generic code must respect the law — else it is dependency for its own sake. 'Push further' ≠ 'always more dependent'." },
  { id := "format-spec-index"
    invariant := "the whole format ontology, as a type index."
    currentEncoding := "n/a (external matrix)."
    strongerEncoding := "Transcript : FormatSpec → Type (indexed family; types generated from the spec)."
    mechanism := "intrinsic-index"
    payoff := "Types cannot drift from the spec."
    cost := "∀ spec on every generic fn; Transcript s1 ≠ Transcript s2 definitionally; coercions everywhere — ergonomic explosion."
    verdict := "FAR CEILING. The dependent typing that does NOT earn its keep yet — the line not to cross." }
]

/-- Levers to push now (construction-guarantee, high payoff). -/
def pushNow : List TypingLever :=
  typingLevers.filter (fun l => l.id == "intrinsic-well-scoping" || l.id == "format-refinements")

/-!
## Techniques per substructure (2026-07-07)

The refinement lattice is the ROOF; the domain has distinct sub-structures,
and each has a type-theoretic (or data-structure) tool that fits it almost
exactly. These do not compete with the lattice — they fill the corners the
flat union IR handles clumsily. Two of them are already LATENT in the port
built this turn; the theory just names them and states the property to hold
them to.

* `normalize` (the parity skeleton the fanout reconciled to) IS a quotient
  canonical form — parity is equality in the quotient by the 3-class
  refinement noise. The property to hold it to: sound AND **complete** (a
  too-coarse skeleton would let a real divergence pass silently).
* The tool-call linkage the importers reconstruct IS a session/linear-typed
  protocol; "resumable" (defect D4) is "open-call set empty".

`useAs` says how to take each one: `encode` (build it), `data-structure`
(use the structure), `principle` (shape the design by it), `lens` (a framing
that sharpens what to state), `far-ceiling` (the disciplined form of M5).
-/

/-- A technique matched to the domain substructure it fits. -/
structure Technique where
  id        : String
  nails     : String   -- the substructure it fits
  mechanism : String
  useAs     : String
  captures  : String   -- the bug class / property it makes type-level or free
  cost      : String
  verdict   : String
  deriving Repr

def techniques : List Technique := [
  { id := "session-typestate-toolcalls"
    nails := "the tool-call sublanguage: a call opens an obligation, a result discharges exactly one."
    mechanism := "index a message stream by the multiset of OPEN tool-calls (call adds, result requires-and-removes); Resumable := open-set empty."
    useAs := "encode"
    captures := "Defect D4 (orphan tool_use rejected on resume) becomes UNREPRESENTABLE; 'resumable' becomes a type. Same family as well-scoping, specialized to call→result binding."
    cost := "No native linear types in Lean; the open-set index carries it (indexed state)."
    verdict := "HIGHEST-FIT new lever — maps a shipped bug AND a real property onto a by-construction guarantee." },
  { id := "ornaments-surface-core"
    nails := "formats-as-refinements-of-a-shared-spine (the turn-1 'global format + refinements')."
    mechanism := "ornaments: datatype B = A's recursive spine decorated with extra data (Claude adds uuid+sidechain; Codex the dual channel; Cursor tokenCount)."
    useAs := "principle"
    captures := "The forgetful projection (format→skeleton) and operation-lifting, for free — the categorical content of the refinement lattice."
    cost := "Research-grade; no Lean library. Encoding the full apparatus is not worth it."
    verdict := "Use as a DESIGN PRINCIPLE: make every format literally a decorated shared spine. The honest form of 'global format + refinements'." },
  { id := "zipper-edits"
    nails := "localized edits on the well-scoped tree (piedit compact/trim/split/append; piview active-path)."
    mechanism := "a zipper — efficient local edits in an immutable/typed tree; its context IS the scope."
    useAs := "data-structure"
    captures := "Resolves the convert-vs-mutate tension: intrinsic well-scoping is hostile to global re-indexing but a zipper edits LOCALLY and maintains the invariant. piedit ops become zipper walks."
    cost := "A typed zipper is some boilerplate; standard."
    verdict := "The answer to 'does dependent typing kill piedit' — no, you edit through a zipper." },
  { id := "quotient-normalize"
    nails := "parity = semantic equality up to representation noise (the 3-class refinement set)."
    mechanism := "normalize is the canonical form of the quotient Transcript / ≈ where ≈ mods out id-synthesis, cwd fabrication, tool-name canonicalization, toolResult flattening."
    useAs := "lens"
    captures := "Names what the fanout already built. The property to enforce: sound (same content ⟹ same skeleton) AND complete (same skeleton ⟹ same content)."
    cost := "None to keep normalize a function; Lean's Quot would be heavy (everything must respect ≈)."
    verdict := "ALREADY LATENT. Do not reach for Quot; hold normalize to the completeness half — a too-coarse skeleton passes real divergences silently." },
  { id := "merkle-dag"
    nails := "branching + structural sharing + dedup + integrity, together (sessions are version-tree / git-shaped)."
    mechanism := "content-address entries; reference parents by hash."
    useAs := "data-structure"
    captures := "Branches share their common prefix (no duplication); identical content dedups by hash (the D13 family = a visible hash collision); integrity free; parent-by-hash is acyclic by construction."
    cost := "Hashing + a content-addressed store; changes the ref representation."
    verdict := "The data-structure answer to branching/dedup that flat `parent : Option Nat` handles clumsily. 'git for transcripts.'" },
  { id := "initial-algebra-adjunction"
    nails := "the content ontology + the conversion round-trip."
    mechanism := "the transcript inductive IS the initial algebra of the agent-effect signature F = {Think, Say, Call, Recv, Compact, Branch}; import ⊣ export is an adjunction."
    useAs := "lens"
    captures := "'message is a thing, thinking is a thing' = F's operations; exporters are F-algebras (folds). Round-trip laws = unit/counit; lossless = the sublattice where the unit is an iso."
    cost := "None — do not build Free F; recognize you have the initial algebra."
    verdict := "Framings that sharpen what to state: exporters should be folds; state the round-trips the adjunction picks out." },
  { id := "datatype-descriptions"
    nails := "the generative universe (M5), done without ergonomic collapse."
    mechanism := "a universe of datatype descriptions/codes + one generic interpreter, instead of raw Transcript : FormatSpec → Type."
    useAs := "far-ceiling"
    captures := "Generic map/fold developed once tames the ∀-spec explosion."
    cost := "Still heavy; only if the ontology stops moving."
    verdict := "If M5 is ever built, THIS is its disciplined form — not the raw indexed family." }
]

/-- Techniques already latent in the port built this turn — the theory names
them and states the property to hold them to. -/
def alreadyLatent : List Technique :=
  techniques.filter (fun t => t.id == "quotient-normalize" || t.id == "session-typestate-toolcalls")

end Loom.Ops.Design
