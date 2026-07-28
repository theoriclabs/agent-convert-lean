import Lean.Data.Json

/-!
# Loom — provenance layer

The layer that keeps the IR honest. Nothing in here describes *conversation
content*; it describes **how each datum came to exist** in the IR.

Design rule: a provenance wrapper exists exactly where importers are known to
**fabricate or infer** values (time, error status, identity, dedup decisions).
Where data is merely present-or-absent (usage, cwd, model), a plain `Option`
suffices — wrapping those too would be ceremony, not honesty
(guide: 02_epistemic_states, "what gets tagged").
-/

namespace Loom

/-- The transcript formats Loom knows about.

`pi` is deliberately a **spoke, not the hub**. It has its own expressiveness
gaps (no sidechains, approximate meta-events — see `Loom.Formats.piSupports`),
so treating it as the IR would make those gaps undescribable. -/
inductive Format where
  | pi
  | claudeCode
  | codexCli
  | cursorAgent
  | cursorIde
  | hermes
  | googleAiStudio
  | other (name : String)
  deriving Repr, DecidableEq

/-- Milliseconds since the Unix epoch. -/
structure Timestamp where
  ms : Nat
  deriving Repr, DecidableEq

/-- How an entry's time value came to exist.

This type exists because two importers **fabricate** time and the fabrication
currently masquerades as recorded fact downstream:

* Hermes has only session-level start/end; per-message times are linearly
  interpolated ("smeared", `hermes.ts:210-212`) so `--since` stays usable.
* Google AI Studio exports carry no timestamps; the importer synthesizes a
  monotonic sequence (`googleAiStudio.ts:92-94`).
* cursor-agent CLI transcripts carry no time at all
  (`cursorAgentAdapter.ts:79`).

Consumers must `match`: any "newest leaf" or `--since` logic that silently
treats `interpolated`/`sequenced` as `recorded` is reproducing a known bug
class. Illegal state made unrepresentable: `absent` cannot carry a value. -/
inductive Time where
  | recorded (t : Timestamp)
  | interpolated (t : Timestamp) (basis : String)
  | sequenced (ord : Nat)
  | absent
  deriving Repr, DecidableEq

/-- How we know whether a tool invocation failed.

* `native` — the source format records it (Claude `is_error`, pi `isError`).
* `inferred` — guessed from content. Codex has no structured flag; the
  adapter applies a substring heuristic (`codexOutputIndicatesError`,
  `codexAdapter.ts:75`). The heuristic string names the method so the guess
  is auditable.
* `unrecorded` — the format cannot say (Hermes always reports success,
  `hermes.ts:298`). Distinct from "no error": we *don't know*. -/
inductive ErrorSignal where
  | native (isError : Bool)
  | inferred (isError : Bool) (heuristic : String)
  | unrecorded
  deriving Repr, DecidableEq

/-- Where a datum came from in the source artifact.

`extras` carries source fields the importer recognized but did not model —
the open-world escape hatch (JSONL is open-world; Lean records are not).
Extras are **format-scoped**: they exist for same-format round-trip fidelity
(the `codexExtras`/`hermesExtras` pattern) and exporters to *other* formats
must ignore them. -/
structure Origin where
  format    : Format
  /-- Format-specific locator: line index, uuid, chunk path, etc. -/
  sourceRef : String
  /-- The identifier the source carried, if any. `none` means the source has
  no native identity for this datum (cursor-agent), which is why same-format
  round-trip cannot preserve identity there. -/
  rawId     : Option String := none
  /-- Unconsumed source fields, verbatim. -/
  extras    : Option Lean.Json := none

/-- The kinds of judgment calls an importer can exercise. Every application
of one MUST be logged as an `ImportNote` — the conversion emits a typed
trace of its assumptions, not just data. -/
inductive AssumptionKind where
  /-- Dropped a source message as a duplicate (e.g. Codex
  `response_item`/`event_msg` pairing, `codexAdapter.ts:239-248`).
  Assumption on record: adjacent identical text+role ⇒ same utterance. -/
  | dedupDropped
  | timeInterpolated
  | timeSequenced
  | errorInferred
  /-- Re-attributed authorship (e.g. Claude serializes tool results inside
  user-role messages; Loom records them as `environment`). -/
  | roleCoerced
  | toolNameMapped
  | idSynthesized
  | contentSkipped
  /-- Active leaf chosen by heuristic (newest timestamp) rather than
  recorded fact. -/
  | activeLeafGuessed
  | other (label : String)
  deriving Repr, DecidableEq

/-- One import-time judgment call, as data. Auditable after the fact:
"show every message the dedup heuristic dropped across the corpus" is a
filter over these, not an archaeology project. -/
structure ImportNote where
  kind   : AssumptionKind
  /-- Source locator, when one exists. -/
  loc    : Option String := none
  detail : String
  deriving Repr

end Loom
