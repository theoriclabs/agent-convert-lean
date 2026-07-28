/-!
# Loom — shared vocabulary

The common concepts every format description is written against. This file
is pure ontology: no IR, no format specifics, no process.

Stance for the whole package: **strong description over proofs.** Typed
records, exhaustive matches, and computable checks — no theorems. Proofs
enter only when the ontology has stabilized and a specific invariant has
earned the cost (graduated formalization).
-/

namespace Loom

/-- The transcript concept space — the union of concepts observed across all
known harness formats. Each format is a partial interpretation of this
space; so is pi. Adding a constructor here breaks every format's `supports`
row until it is answered — the type checker as completeness auditor. -/
inductive Concept where
  /-- Stable per-entry identity carried by the source. -/
  | identity
  /-- Explicit entry ordering/chaining (linear order or parent pointers). -/
  | threading
  /-- Per-entry wall-clock time. -/
  | time
  /-- Authorship vocabulary (user/assistant/environment/system). -/
  | roles
  | textContent
  /-- Reasoning blocks, including provider signatures. -/
  | thinkingContent
  /-- Tool call/result pairing with linkage. -/
  | toolLifecycle
  /-- Structured success/failure marking on tool results. -/
  | errorSignaling
  /-- History-rewrite summaries (compaction). -/
  | compaction
  /-- Multiple children of one entry; divergent history. -/
  | branching
  /-- Subagent transcripts anchored to a spawning call. -/
  | sidechains
  /-- Token/cost accounting. -/
  | usage
  /-- Session environment: cwd, model, harness version, instructions. -/
  | environment
  /-- Config/meta events: model change, permission mode, etc. -/
  | metaEvents
  /-- Multimodal content: images, file/media attachments. Added after the
  2026-07-06 corpus census found media in five of seven formats (pi image
  blocks, Claude image/attachment payloads, Codex input_image, Cursor IDE
  images, GAIS drive*/inlineFile chunks). -/
  | media
  deriving Repr, DecidableEq

def Concept.all : List Concept :=
  [.identity, .threading, .time, .roles, .textContent, .thinkingContent,
   .toolLifecycle, .errorSignaling, .compaction, .branching, .sidechains,
   .usage, .environment, .metaEvents, .media]

/-- How well a format represents a concept. -/
inductive Support where
  | native
  /-- Representable only degraded; `mechanism` names how. -/
  | approximate (mechanism : String)
  | absent
  /-- Not yet investigated. An honest cell, with a cheap upgrade path. -/
  | unverified
  deriving Repr, DecidableEq

/-- What an importer does with one of a format's native record kinds.
Exhaustive per format: every native kind must be given a disposition, so a
newly-observed kind cannot be silently ignored. -/
inductive Disposition where
  /-- Imported; `target` names the Loom shape it becomes. -/
  | mapped (target : String)
  /-- Imported or dropped depending on a stated rule (e.g. the Codex
  event_msg dedup). Rule applications must be logged as `ImportNote`s. -/
  | conditional (rule : String)
  | droppedDeliberately (rationale : String)
  | preservedInExtras
  /-- Handling not yet established — an honest gap. -/
  | unverified
  deriving Repr, DecidableEq

/-- Physical shape of a format's on-disk store. -/
inductive FileShape where
  /-- Append-only JSONL, one record per line. -/
  | jsonlAppend
  /-- A single JSON object rewritten in place as the session grows. -/
  | singleJsonMutating
  /-- A one-shot exported blob (no live session file). -/
  | exportBlob
  /-- Records inside a SQLite database. -/
  | sqliteStore
  deriving Repr, DecidableEq

/-- Cross-harness canonical tool vocabulary — the *interpretation* layer
over raw tool names (Hermes `terminal` → `bash`, `read_file` → `read`, …).
Closed enum by design: an unmapped tool stays `none` rather than being
forced into a lossy bucket. -/
inductive CanonicalTool where
  | bash
  | read
  | write
  | edit
  | grep
  | glob
  | webFetch
  | webSearch
  | agentSpawn
  | applyPatch
  deriving Repr, DecidableEq

/-- Epistemic status of a schema-level claim (guide ch. 2 core four). -/
inductive Status where
  | confirmed (evidence : String)
  | tentative (basis : String) (upgradeBy : String)
  | unknown (whatMissing : String) (resolveBy : String)
  | deferred (whatMissing : String) (rationale : String)
  deriving Repr

structure Claim where
  id        : String
  statement : String
  status    : Status
  deriving Repr

end Loom
