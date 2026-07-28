import Loom.Provenance
import Loom.Formats.Pi
import Loom.Formats.ClaudeCode
import Loom.Formats.CodexCli
import Loom.Formats.CursorAgent
import Loom.Formats.CursorIde
import Loom.Formats.Hermes
import Loom.Formats.GoogleAiStudio

/-!
# Loom — the format registry

One file per format lives under `Loom/Formats/`; each owns everything known
about that format (storage, file shape, native record kinds, import
dispositions, expressiveness row, format-specific claims). This file only
*aggregates*: the total `supports` dispatch and the derived loss between
any pair of formats.

The dispatch is total over `Format × Concept` — adding a `Concept`
constructor breaks every format file until its row answers it; adding a
`Format` constructor breaks this dispatch until a format file exists. The
type checker as completeness auditor, in both directions.
-/

namespace Loom

/-- The matrix, total over formats and concepts. -/
def supports : Format → Concept → Support
  | .pi,             c => Formats.Pi.supports c
  | .claudeCode,     c => Formats.ClaudeCode.supports c
  | .codexCli,       c => Formats.CodexCli.supports c
  | .cursorAgent,    c => Formats.CursorAgent.supports c
  | .cursorIde,      c => Formats.CursorIde.supports c
  | .hermes,         c => Formats.Hermes.supports c
  | .googleAiStudio, c => Formats.GoogleAiStudio.supports c
  | .other _,        _ => .unverified

/-- Concepts degraded or dropped when converting `src → tgt`.
Derived, not asserted: e.g. `lossyConcepts .claudeCode .pi` computes the
current adapter's silent drops, as data. -/
def lossyConcepts (src tgt : Format) : List Concept :=
  Concept.all.filter fun c =>
    match supports src c, supports tgt c with
    | .native,        .absent        => true
    | .native,        .approximate _ => true
    | .approximate _, .absent        => true
    | _,              _              => false

end Loom
