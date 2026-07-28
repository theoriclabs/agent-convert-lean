import LoomOps.Defects

/-!
# Loom.Ops — evaluation protocol

How we'll know whether the Lean approach beats the TS toolchain — decided
before the results exist.

**Decision made (2026-07-06, mandate-driven).** The Lean implementation IS
the release; the TS toolchain will be retired (semantic core is always Lean;
the factory does not let TS be semantic authority). So this protocol is no
longer "decide IF leanCore" — it is "verify leanCore reaches parity so TS
can be retired SAFELY." The arms stay but their roles shift: `tsBaseline` is
now the **reference oracle** the port is checked against — never deleted
until parity + burn-in hold (the ratchet principle) — and `leanCore` is the
committed target. The metrics below become migration quality-gates, not a
go/no-go on building Lean at all.

**"Better" is severity-asymmetric and lexicographic:**
1. minimize silent corruption/loss of resumable sessions,
2. minimize undeclared anything (fabrication, loss, assumptions),
3. hold coverage — refusing a lie is a win; refusing the truth is a
   regression,
4. bounded cost.

Raw bug-count parity against the mature TS suite is the wrong scoreboard;
the question is the severity-weighted *set difference* of catches, in both
directions. A silent resumable-session corruption that one arm demonstrably
prevents outweighs aggregate scores (severity veto). "Better" must not mean
elegance or Lean-ness — a spec nobody queries is theatre and scores negative.

**Standing threats** (with mitigations baked into the rules below):
rewrite-effect (any rewrite looks better second time → credit leanCore only
as delta over tsWithOracle); counterfactual bias (→ sabotage rule, see
`CatchClass`); fixture inbreeding (spec written from the TS test fixtures →
census runs on held-out corpus); self-grading (→ adjudication by an
evaluator who never reads the spec author's reasoning); moving baseline
(→ freeze tsBaseline at a named SHA).
-/

namespace Loom.Ops

/-- The arms under comparison. -/
inductive Arm where
  /-- utils v2.27.0 TS toolchain, frozen at a named SHA. -/
  | tsBaseline
  /-- Same TS implementation + Loom validators via the bridge. Isolates the
  SPEC's value with zero rewrite risk. -/
  | tsWithOracle
  /-- Conversion core in Lean. Hypothetical; built only if `tsWithOracle`
  clears rule R1. -/
  | leanCore
  deriving Repr, DecidableEq

/-- Honesty tag for any reported number. -/
inductive Rigor where
  | measured
  | derived
  | estimated
  deriving Repr, DecidableEq

/-- A metric plus the trap it guards against — a metric without a trap is
decoration. -/
structure Metric where
  id            : String
  definition    : String
  guardsAgainst : String
  deriving Repr

def metrics : List Metric := [
  { id := "M1-differential-catch"
    definition :=
      "Historical ledger (knownDefects, fully mined) + seeded mutations per \
       DefectLocus, scored per arm. Report kill-SET differences both \
       directions; `detected` requires sabotage demonstration."
    guardsAgainst := "Counterfactual bias; totals hiding that both arms kill the same easy faults." },
  { id := "M2-corpus-honesty"
    definition :=
      "Validators over the full local session corpus: violations per 1k \
       sessions with adjudicated precision, plus an independent audit of \
       sampled conversions — every loss/fabrication must trace to a matrix \
       cell, Obligation, or ImportNote. Undeclared items per conversion."
    guardsAgainst := "Goodharted violation counts; the spec declaring only what its author remembered." },
  { id := "M3-silent-mass"
    definition :=
      "Shadow-mode incident ledger over real usage: Σ severityRank of \
       incidents reaching downstreamUse/latent, per 1k conversions, per arm."
    guardsAgainst := "Improvement claims with no incident denominator." },
  { id := "M4-drift"
    definition :=
      "Primary mechanism: decide-pinned captures — golden-fixture TS outputs \
       folded into lake build, so cross-implementation divergence is a \
       compile error (the Tgrad technique). Plus stale-cell escapes per \
       adapter PR and spec-commit liveness (<3/month while adapters are \
       active ≈ theatre)."
    guardsAgainst := "Museum spec; wire shapes hand-written thrice (the Webmapper failure)." },
  { id := "M5-cost"
    definition :=
      "Representative changes implemented in each arm: wall-clock + tokens, \
       dual-maintenance overhead. Plus false-refusal rate: oracle-refused \
       conversions adjudicated as actually-fine."
    guardsAgainst := "Ignoring the tax; counting every refusal as safety." }
]

/-- Phases, each with a mechanical exit condition. Thresholds are set from
E1 baselines, not invented — until then every target is `estimated`. -/
structure Phase where
  id   : String
  exit : String
  deriving Repr

def phases : List Phase := [
  { id := "E0-ledger",  exit := "Full CHANGELOG 2.20–2.27 mined into knownDefects; retrospectiveScores nonempty; every `detected` sabotage-demonstrated." },
  { id := "E1-census",  exit := "M2 run on held-out corpus; precision adjudicated by non-author; thresholds set from these baselines." },
  { id := "E2-sabotage", exit := "M1 mutation set covers every DefectLocus; kill-set differences reported both directions." },
  { id := "E3-shadow",  exit := "M3 ledger append-only over real usage; every incident classified on all four axes." },
  { id := "E4-cost",    exit := "M5 measured on the same changes in both arms, recorded not recalled." }
]

/-- The ratchet, written before the results exist. -/
structure DecisionRule where
  id      : String
  trigger : String
  action  : String
  deriving Repr

def decisionRules : List DecisionRule := [
  { id := "RC1-parity-gate"
    trigger := "leanCore matches tsBaseline on the decide-pinned golden fixtures AND on a corpus-wide round-trip differential (per format, both directions), every divergence adjudicated as a leanCore improvement or a fixed leanCore bug."
    action  := "Only then may a consumer (piview / pi-search / convert) cut over to leanCore. No cutover on unverified parity." },
  { id := "RC2-dual-run-burnin"
    trigger := "After a consumer cuts over, leanCore and tsBaseline run in parallel over real usage for a burn-in window; output diffs adjudicated, zero silent regressions."
    action  := "Hold both live until the window is clean; a regression reverts the cutover, not the user." },
  { id := "RC3-retire-not-delete"
    trigger := "Burn-in clean across all consumers."
    action  := "Retire TS from the shipped path but ARCHIVE it as the reference oracle — the decide-pinned fixtures are captured from it, and the ratchet forbids deleting recoverable prior state. Mirrors the agent-ops process-migration ratchet: dual-path → cutover → canonical flip → archive." },
  { id := "R3-theatre-guard"
    trigger := "M4 liveness below threshold two consecutive months while the port is active."
    action  := "Re-embed the spec in the port workflow or admit it isn't load-bearing — a stale spec testifies to discipline that no longer exists." }
]

end Loom.Ops
