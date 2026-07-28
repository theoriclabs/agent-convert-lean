import Loom.Formats

/-!
# Loom — the claims register

Format-specific claims live in their format's file under `Loom/Formats/`;
this file holds the **cross-cutting** claims (about the IR, the toolchain,
or derived views) and aggregates everything into one queryable register.

Most upgrade paths are corpus scans over `~/.claude` / `~/.codex` / `~/.pi`,
which is what makes this domain unusually cheap to be honest in.
-/

namespace Loom

/-- Claims that belong to no single format. -/
def globalClaims : List Claim := [
  { id := "L1-acyclic-in-wild"
    statement :=
      "Parent chains in harness-written session files are acyclic. \
       CONFIRMED by census. Distinct from the stronger topological property \
       (parent always earlier in file order), which holds for pi but NOT \
       for Claude — see L1b."
    status := .confirmed
      ("2026-07-06 census: pi 0 cycles across ~185k entries; Claude 0 cycles \
        across 55,930 lines; dangling (not cyclic) parentIds occur only in \
        hand-forked/split files. The `seen` cycle guard in every reader is \
        thus defensive against a case never observed in agent output — but \
        cheap and correct to keep, since piedit hand-edits can introduce it. \
        Loom's normal form excludes cycles by construction at import.") },
  { id := "L1b-file-order-topology-varies"
    statement :=
      "Whether a parent always precedes its child in FILE order is \
       format-specific: pi is topologically file-ordered; Claude is not."
    status := .confirmed
      ("census: pi 0 forward-references across 315 files; Claude 29 forward- \
        references (parent physically later than child) plus cross-file \
        dangling parents (forkedFrom, logicalParentUuid). CONSEQUENCE: \
        Loom's normal form (parent strictly earlier index) is an IMPORT-TIME \
        property a Claude importer must ESTABLISH by reordering the graph, \
        not something the Claude source guarantees. A streaming importer \
        must build the full id map before resolving parents.") },
  { id := "L7-detection-agreement"
    statement :=
      "The two independent format-detection implementations \
       (sessionCore.parseSession and followAdapter.detectFormat) agree on \
       every real session file."
    status := .confirmed
      ("2026-07-06: differential test test/detector-agreement.test.mjs runs \
        both over 110 files (80 real across pi/claude/codex/cursor-agent + \
        fixtures + synthesized) and asserts agreement — now mechanically \
        enforced, 7/7. Non-vacuity checked: a format-mixed adversarial file \
        makes them diverge and the test fails naming both verdicts. NUANCE: \
        a THIRD, weaker sniffer parseSessionFast has NO cursor-agent branch \
        (defect D18), and detectFormat throws on bare-primitive lines where \
        parseSession degrades — both latent, neither an L7 violation for the \
        two named detectors.") },
  { id := "L8-turn-semantics"
    statement :=
      "'Turn' is a derived view, not a stored fact; cross-format turn-count \
       parity is a property of a view function over the unified IR."
    status := .confirmed
      ("RESOLVED 2026-07-07 (Loom.Turns): the role-content-sum made a single \
        CANONICAL turn view possible (a turn boundary is exactly a `userMsg`, \
        role-typed across every format), dissolving the per-harness problem \
        that forced the earlier deferral. `turns`/`turnCount`/`turnOfEntry` \
        are defined over the entries array; cross-format turn-count parity is \
        now `turnCount (importF file)` on the shared IR — a view property, as \
        the claim states, no longer a per-harness reimplementation.") }
]

/-- Every claim in the package, format-local and global. -/
def claims : List Claim :=
  globalClaims
  ++ Formats.Pi.claims
  ++ Formats.ClaudeCode.claims
  ++ Formats.CodexCli.claims
  ++ Formats.CursorAgent.claims
  ++ Formats.CursorIde.claims
  ++ Formats.Hermes.claims
  ++ Formats.GoogleAiStudio.claims

/-- Claims still carrying open work — the investigation queue, as a query. -/
def openClaims : List Claim :=
  claims.filter fun c =>
    match c.status with
    | .confirmed _ => false
    | _ => true

end Loom
