import Loom.Provenance
import Loom.Concepts

/-!
# Loom — core IR

The hub data model. Three structural commitments, each fixing a known bug
class from the TS toolchain:

1. **Positional linking.** Entries link to parents and tool results link to
   calls by *index*, not by string id. Duplicate source tool-ids (fixed in
   utils 2.27 by uniquification) cannot corrupt IR linkage — raw ids ride
   along in `Origin` as provenance for same-format export.

2. **Normal form.** A parent reference must point *strictly earlier* in the
   entry array. Cycles — the phase-1 cycle-guard DoS — are excluded by a
   local O(n) decidable check (`Loom.WellFormed`), not a graph traversal
   that every reader must re-implement defensively.

3. **Threads are first-class.** Claude sidechains (subagent transcripts) are
   currently *dropped* on import to pi (`claudeAdapter.ts:132-135` walks the
   newest non-sidechain leaf). In Loom they are representable: a sidechain
   is a thread anchored to the tool call that spawned it. Dropping them
   becomes an explicit export obligation, not a silent import loss.
-/

namespace Loom

/-- Authorship, decoupled from serialization.

Claude Code serializes tool results inside `user`-role messages; Codex uses
`function_call_output` items. Both are *serialization quirks*. Loom records
who authored the content: tool output is authored by the `environment`
(harness/tool runtime), never by the user. Importers that re-attribute must
log `AssumptionKind.roleCoerced`. -/
inductive Role where
  | user
  | assistant
  | environment
  | system
  deriving Repr, DecidableEq

/-- A tool name carries both the fact (`raw`, exactly as the source spelled
it) and our interpretation (`canonical`, if we map it). Never discard `raw`:
round-trip and forensics depend on it. -/
structure ToolName where
  raw       : String
  canonical : Option CanonicalTool := none
  deriving Repr, DecidableEq

/-- Link from a tool result back to its call.

`resolved` is positional: (entry index, block index within that entry's
top-level blocks). `unresolved` keeps orphan results *representable* —
truncated or corrupt sources produce them — while `Loom.WellFormed`
enumerates them as violations instead of readers crashing or guessing. -/
inductive CallRef where
  | resolved (entry : Nat) (block : Nat)
  | unresolved (rawId : Option String) (note : String)
  deriving Repr, DecidableEq

/-! ## Role-indexed content (the role-content-sum, `LoomOps.Design`)

Content blocks are split by author so each message carries only its admissible
content: a user message holding a tool call, or a tool result authored by the
user, is now a **type error**, not a runtime check. `unmodeled` is the
open-world escape hatch on every arm. -/

/-- User-authored content. No tool calls, no tool results — unrepresentable. -/
inductive UserBlock where
  | text (s : String)
  | media (mimeType : String) (locator : String)
  | unmodeled (label : String) (raw : Lean.Json)

/-- Assistant-authored content. `thinking` carries the provider signature (kept
so Claude-export's drop is a typed decision, not an import loss). Tool CALLS
live here; tool RESULTS do not (they are environment-authored). -/
inductive AssistantBlock where
  | text (s : String)
  | thinking (s : String) (signature : Option String)
  | toolCall (name : ToolName) (args : Lean.Json) (rawId : Option String)
  | media (mimeType : String) (locator : String)
  | unmodeled (label : String) (raw : Lean.Json)

/-- Environment-authored content: tool results (the runtime is the author,
never the user). Result content is user-shaped (text/media). -/
inductive EnvBlock where
  | toolResult (call : CallRef) (content : List UserBlock) (error : ErrorSignal)
  | unmodeled (label : String) (raw : Lean.Json)

/-- What a compaction summary replaced.

pi records `firstKeptEntryId`; other formats have summaries whose replaced
extent is unrecorded (the Codex compaction-orphan deferral from
toolchain-hardening phase-7 lives exactly in this gap). -/
inductive CompactionCoverage where
  | knownPrefix (firstKept : Nat)
  | unknownPrefix
  deriving Repr, DecidableEq

/-- Harness meta events, unified. Kept deliberately stringly-typed at this
stage (graduated formalization: type the scaffold, harden constructors when
the vocabulary stabilizes). `custom` preserves anything else verbatim. -/
inductive MetaEvent where
  | modelChange (prev next : Option String)
  | thinkingLevelChange (prev next : Option String)
  | permissionMode (mode : String)
  | branchSummary (summary : String)
  | custom (label : String) (raw : Lean.Json)

/-- What an entry can be. Messages are role-indexed (role-content-sum) so each
carries only its admissible content. `otherMsg` keeps rare roles (system,
bashExecution) loose rather than forcing them into the three main arms.
Compactions are entries (they occupy a position in history and other entries
chain past them), not annotations — this follows pi, which got this right. -/
inductive Payload where
  | userMsg (blocks : List UserBlock)
  | assistantMsg (blocks : List AssistantBlock)
  | envMsg (blocks : List EnvBlock)
  | otherMsg (roleLabel : String) (blocks : List UserBlock)
  | compaction (summary : String) (coverage : CompactionCoverage)
      (tokensBefore : Option Nat)
  | event (e : MetaEvent)

/-- Dispatch a parsed `Role` + role-appropriate blocks to the right message
constructor. A migration/ergonomics helper for importers — the type still
forbids building a user message with assistant content, since the block lists
are role-typed at the call site. -/
def Payload.userMessage (blocks : List UserBlock) : Payload := .userMsg blocks
def Payload.assistantMessage (blocks : List AssistantBlock) : Payload := .assistantMsg blocks
def Payload.envMessage (blocks : List EnvBlock) : Payload := .envMsg blocks

/-- Whether an entry came from ordinary source syntax or from an in-band
historical-data carrier.

Carrier markers self-identify data emitted by an adapter, but they are not
authentication. Importers therefore restore their useful typed payload while
marking it `historicalUnverified`; exporters must preserve that inert status
instead of promoting the payload to target-native executable state.

This is shared IR state rather than `Origin.extras`: conversion policy must not
depend on knowing each format's private carrier encoding. -/
inductive EntryDisposition where
  | native
  | historicalUnverified
  deriving Repr, DecidableEq

/-- One transcript entry.

`parent` is an index into `Transcript.entries` and must be strictly smaller
than the entry's own index (normal form). Branching is emergent — two
entries sharing a parent — exactly as in pi, because parent-pointer sharing
is the only representation that lets branches share history without
duplication. -/
structure Entry where
  parent  : Option Nat := none
  /-- Index into `Transcript.threads`. -/
  thread  : Nat := 0
  time    : Time := Time.absent
  payload : Payload
  origin  : Origin
  disposition : EntryDisposition := .native

/-- Why a thread exists.

`sidechain` anchors a subagent transcript to the tool call that spawned it
(Claude's `isSidechain` lines, Codex `spawn_agent` streams). `detached`
admits threads whose anchor could not be determined — representable,
flagged, honest. -/
inductive ThreadKind where
  | main
  | sidechain (anchor : CallRef)
  | detached (note : String)
  deriving Repr, DecidableEq

structure Thread where
  kind  : ThreadKind
  label : Option String := none
  deriving Repr, DecidableEq

/-- Session-level environment facts. Plain `Option`s, not provenance
wrappers: these are present-or-absent, never fabricated by importers. -/
structure EnvInfo where
  cwd            : Option String := none
  model          : Option String := none
  provider       : Option String := none
  harnessVersion : Option String := none
  instructions   : Option String := none
  sessionId      : Option String := none
  deriving Repr, DecidableEq

/-- A transcript in the Loom IR.

`activeLeaf` is stored, not derived. pi derives the active branch tip as
"newest message leaf by timestamp" — a heuristic that is *undefined* when
`Time` is `sequenced` or `absent` (cursor-agent). The importer, which has
file-order knowledge, records its choice here; if it guessed, it logs
`AssumptionKind.activeLeafGuessed`.

`importNotes` is the typed trace of every judgment call exercised during
import. A conversion that made no notes made no assumptions. -/
structure Transcript where
  threads     : Array Thread
  entries     : Array Entry
  env         : EnvInfo := {}
  activeLeaf  : Option Nat := none
  importNotes : List ImportNote := []
  origin      : Origin

end Loom
