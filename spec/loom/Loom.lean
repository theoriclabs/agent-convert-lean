import Loom.Concepts
import Loom.Provenance
import Loom.Core
import Loom.Temporal
import Loom.WellFormed
import Loom.Render
import Loom.Fidelity
import Loom.Turns
import Loom.Formats
import Loom.Claims
import Loom.BuildOptions

/-!
# Loom — the WHAT

A hub IR for agent transcripts (Claude Code, Codex CLI, cursor-agent,
Cursor IDE, Hermes, Google AI Studio, pi), built on the
Lean-as-universal-specification-language practice. pi is a spoke, not the
hub: the hub is the union concept space (`Loom.Concept`), and every format —
pi included — is a partial interpretation of it.

This library is pure description, organized as:

* `Loom.Concepts` — shared vocabulary: the concept space, support levels,
  import dispositions, canonical tools, claim epistemics.
* `Loom.Provenance` — how each datum came to exist (fabricated time,
  inferred errors, synthesized ids, logged import assumptions).
* `Loom.Core` — the IR: threads, entries, blocks; positional linking;
  normal form.
* `Loom.WellFormed` — what a valid transcript IS (decidable, typed
  violations).
* `Loom/Formats/<Format>.lean` — one file per format: storage, file shape,
  native record kinds, import dispositions, expressiveness row,
  format-specific claims.
* `Loom.Formats` — the aggregated matrix and derived loss.
* `Loom.Claims` — cross-cutting claims + the aggregated register.

Stance: **strong description before proof** — typed records, exhaustive
matches, computable checks, and rich docstrings in this ontology library. The
universal adequacy and implementation-safety theorems that have earned their
cost live in `LoomRequirements`, which imports this library; `Loom` never
depends on its requirements/evidence layer.

Everything operational — export obligations, defect classification, the
evaluation protocol — lives in the sibling `LoomOps` library, which imports
this one. The reverse import is impossible by construction.
-/
