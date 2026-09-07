# Loom audit — interop fidelity

> **2026-09-07 recurrence:** Cursor completed/pruned calls still become Codex
> assistant carrier prose because native emission requires a retained result.
> The importer keeps completion only in raw metadata. See [current intent](./INTENT.md),
> [bug](./docs/bugs/native-tool-history.md), and [plan](./docs/plans/native-tool-history.md).
> The dated findings below remain historical; the native-history goal is not met
> merely by retaining a reversible carrier or passing a target-parser read.

**Date:** 2026-07-24
**Scope:** whole project, against the stated purpose: *"enable interoperability
across harnesses… use a transcript started in codex in claude, then maybe in
codex again."*
**Method:** direct measurement with the working-tree binary, plus four parallel
code audits. Normative principles live in `LoomOps/Interop.lean` (typed,
compiles, queryable); this document records evidence and recommendations.

Claims below are marked **[verified]** where I reproduced them myself with the
CLI, and **[reported]** where they come from a code audit I did not
independently re-run. One agent claim that failed to reproduce is recorded in
§7 rather than dropped.

---

> **Status update 2026-07-24 (commit af0b289e).** §2–§6 describe the state at
> audit time. The core defect is now **fixed for claude↔codex and hermes→claude**:
> `codex → claude → codex` preserves 42/42 tool calls and 42/42 results natively,
> where it previously preserved 0. The pi and cursor-agent targets are unchanged
> and still degrade or refuse, and the `LoomRequirements` evidence layer no
> longer builds — six of its pins still assert carrier behaviour. §8 records
> which recommendations landed.

> **Status update 2026-07-27.** The evidence layer **builds again** and `lake
> build` is green across all four libraries. Nine `LoomRequirements` pins were
> reconciled with the shipped policy rather than the reverse; §8 "Landed"
> records each one and why. Also fixed here: a release-blocking regression in
> which `exportCodexCliChecked` — the path the CLI actually uses for the codex
> target — refused **every** foreign transcript carrying a thinking signature,
> because it compared the raw source payload against its own correct
> post-policy expectation and rated the intentional drop as corruption.
>
> Two things this update does **not** establish. Cursor-agent's
> `lifecycleRoundTrip` is still recorded as `.semanticIdentity` when the honest
> ceiling is `.nonAccumulating` (`Interop.targetGoals` carries the note), and
> P6's version pins are now actively blocking: `scripts/verify.sh` fails its
> final gate because the pinned Claude Code `2.1.216` / Codex `0.144.1` no
> longer match the installed `2.1.220` / `0.145.0`. Everything in that script
> before the version gate passes.

## 1. Verdict

The converter did not achieve its purpose for any cross-harness pair, and the
verification layer pinned that outcome as the expected result.

The import layer is genuinely good — parsing, normalization, call↔result
linkage, provenance and loss reporting are careful and correct. The defect is
a thin policy layer on top of the exporters that discards that work. This is
the encouraging part: the expensive half is built and sound.

---

## 2. The defect

`LoomConvert/ClaudeCode.lean:3595`:

```lean
private def cClaudeNativeEntryProvenance (t : Transcript) (entryIdx : Nat) : Bool :=
  t.origin.format == Format.claudeCode &&
    match t.entries[entryIdx]? with
    | some entry => entry.origin.format == Format.claudeCode &&
        entry.disposition == EntryDisposition.native
    | none => false
```

A native Claude `tool_use` is emitted only when the source was **already
Claude** — the one case where conversion is unnecessary. Everything else
becomes text inside `message.content`:

```
[Historical tool call from source transcript; not executed by Claude]
{"arguments":{…},"carrier":"agent-convert.claude-tool-call.v1","id":"call_…"}
```

**[reported]** The same gate exists in all four exporters, with escalating
strictness — `Pi.lean:819` < `ClaudeCode.lean:3596` (applied twice: call site
and result site) < `CursorAgent.lean:1179` < `CodexCli.lean:3102`, where three
of four additionally require the verbatim original source record still be
attached in `origin.extras`. Foreign-source native emission is 0% for all four
targets.

Three independent secondary blockers, each sufficient on its own:

- **Error-signal strictness.** Native emission requires `ErrorSignal.native`.
  Codex has no structured error flag, so its importer always produces
  `.inferred` — and all three targets serialize error as a plain bool anyway.
  Same check duplicated at `ClaudeCode.lean:3618`, `CodexCli.lean:3224`,
  `Pi.lean:844`. **[reported]**
- **Pre-degradation before the exporter runs.** `Main.lean:2029` →
  `historicalizeCodexToolsForClaude` (`ClaudeCode.lean:2800`) rewrites every
  call and result to carriers and stamps `historicalUnverified` whenever the
  source is Codex. Fixing the provenance gate alone would change nothing on
  that path. **[reported]**
- **Codex's registry is a two-name whitelist.** `isNativeCodexCall`
  (`CodexCli.lean:3078`) accepts only `exec_command` and `update_plan`.
  Measured against real `~/.codex/sessions`: of 133,275 `function_call`
  records, 19,928 (14.95%) fail on tool name alone. **[reported]**

---

## 3. Measurements

All run with the working-tree binary.

**Cross-format, the stated workflow — `codex → claude → codex`** on
`testdata/codex/tool-lifecycle-controls.jsonl`: **[verified]**

| | function_call | function_call_output | custom_tool_call | tool_search_call |
|---|---|---|---|---|
| source | 1 | 1 | 1 | 1 |
| after round trip | 0 | 0 | 0 | 0 |

All four became assistant text messages reading `[Historical tool call from
source transcript; not executed by Codex]`.

**Same format — `codex → codex`** on the project's own gate fixture
`tool-lifecycle-controls.jsonl`: **[verified]** 3 calls imported, **0 emitted
native**, 3 carried; zero lifecycle records in the output. A same-format
conversion is not an identity.

**Real session** (`~/.codex/…/019f8c81-….jsonl`, the leandb session):
**[verified]**

```
toolCallsImported            21     toolCallsEmittedNative      0
toolCallsCarriedAsHistory    21     toolResultsEmitted          0
toolResultsImported          20     toolResultsCarriedAsHistory 20
```

100% degradation. Note `toolCallsEmittedNative: 0` is printed on **every run**
— the metric that proves the product doesn't work was always being computed and
reported, and no gate ever read it.

**Loss compounds per hop.** Because carrier prose is a native text block of the
new source format, a further hop cannot recover it. That is the difference
between "lossy" (tolerable) and "not a portability tool" (`RoundTripLevel.degrading`
in `LoomOps/Interop.lean`).

**The IR is not at fault, and the fix is feasible.** `loom inspect codex` on the
same fixture shows correct structure: **[verified]**

```
## 1 ASSISTANT   [tool call exec_command; id=call-function]
## 2 ENVIRONMENT [tool result for entry 1, block 0; success (inferred: …)]
```

Valid tool name, valid id charset, object arguments, strict ordering, resolved
positional linkage — everything a native `tool_use`/`tool_result` pair requires
is present and already passes every *structural* check. Only the provenance
conjunct and the `.native` error demand block it.

---

## 4. Why verification did not catch it

The behavior is pinned as the passing condition at four independent levels.

- `scripts/verify.sh:436` and `:470` assert `toolCallsEmittedNative: 0` as the
  **expected** value for codex→claude and claude→codex. **[verified]**
- `LoomConvert/Main.lean:1814-1816` pins the same via `native_decide`. **[verified]**
- `scripts/audit-codex-claude.mjs:373` throws *"Codex-origin lifecycle was
  emitted as native Claude tool state"* if a native call survives — the
  "independent audit" audits that degradation occurred. **[reported]**
- `LoomRequirements/Proofs.lean:2502` asserts the export does **not** contain
  `"type":"function_call"` and **does** contain `[Historical tool call…]`.
  Cross-format degradation is a theorem of this codebase. **[reported]**

**Fixing the exporter turns CI red.** The defect is load-bearing in the
verification layer; any fix must rewrite these pins in the same change.

Supporting structure: **[reported]**

- **Zero A→B→A tests exist.** All four "round trips" are import→export→import
  within one format, which pass *because of* the provenance gate.
- Of 433 `native_decide` pins: 179 refusal/blocker vs 76 native/preserve. For
  cross-format the ratio is ∞:0 — ten pins assert carriers are present or
  native constructs absent; **zero** assert a cross-format export contains a
  native construct.
- The 8×5 lifecycle matrix whitelists `allow-native-to-historical` as a pass
  for 19 of 40 cells, including `codex→codex`.
- No automated test reads a real transcript. Fixtures are 2–13 lines;
  `encrypted_content` is the 3-byte string `"enc"`.
- `V-009` (`REQUIREMENTS_EVIDENCE.md:229`) records a real 77-call Codex session
  producing *"0 native historical tool records"* as **positive evidence**. A
  human observed this at scale and signed it off.

---

## 5. The load-bearing assumption

Everything above rests on one assumption the project itself marks unvalidated.

`REQUIREMENTS.md:239`: **[verified]**

> **D-008** | Foreign historical tools cannot be assumed native in a target
> registry | *Conditional* | falsified by: "A pinned target safely accepts
> arbitrary foreign names/schemas" | *Tool-rich target probe* — never run

`REQUIREMENTS_EVIDENCE.md:472` gives the whole rationale: **[verified]**

> "Codex and Claude do not share an executable tool registry, so every
> Codex-origin call/result is now a reversible historical carrier rather than a
> Claude-native lifecycle."

This conflates two different things. A tool registry governs what the model
**may call next**. A historical `tool_use`/`tool_result` pair in replayed
history is a *record of something that already happened*. Nothing re-executes
it. If historical blocks do not require registry membership — testable in about
an hour by opening a natively-converted session in Claude Code — D-008 is false
and the carrier apparatus is unnecessary.

**This is the highest-leverage hour available in the project.** Do it before
any other work here.

### The safety argument is inverted

The rationale (`ClaudeCode.lean:384-393`) defends against a harness
auto-replaying historical tool calls. No supported harness does this. The
remedy takes attacker-influenced JSON *out of* a structured `tool_use` slot and
concatenates it into visible assistant prose — the highest-trust channel the
model reads. That is a strict **increase** in prompt-injection surface, paid
for with 100% of the product's value.

**[reported]** The anti-laundering property is carried entirely by
`EntryDisposition.historicalUnverified` and the carrier markers, all
independent of `origin.format`. A forger who can set `disposition := .native`
can equally set `origin.format := .claudeCode`. The format equality adds no
security; it only blocks honest conversions.

---

## 6. Other systemic findings **[reported]**

- **Cursor is unreachable, not merely degraded.** `cursorAgentTargetExport…`
  requires every entry's `Time` to be `.absent` (`CursorAgent.lean:1541`) and
  refuses if any `EnvInfo` field is present (`1396`). Claude and Codex sources
  always carry both, so claude→cursor and codex→cursor are **unconditionally
  refused** before content is examined. Inverted logic: "target has no
  timestamp field" should mean drop it, not reject the transcript.
- **An amplifier deletes visible prose.** `cEntryNeedsWholeHistoricalCarrier`
  (`ClaudeCode.lean:3755`): an assistant message mixing a carrier-forced block
  with a native one — the ordinary `[text, toolCall]` shape — collapses the
  *entire entry* to `{"type":"system","subtype":"agent_convert_inert"}`, and
  the assistant's text vanishes from the dialogue.
- **Refusals hiding in the obligation layer.** `obligationImpactFor`
  (`LoomOps/Conversion.lean:1075`) defaults to `.destructive`, making these
  refusals rather than degradations: `linearizeBranches` fires for any branched
  transcript on 3/4 targets and **no linearizer exists**; `dropOtherRoles`
  makes claude→codex refuse on any transcript containing a `system` or
  `developer` record.
- **Vocabulary drift.** Across the markdown: 172 occurrences of
  refuse/refusal/reject/blocked/blocker vs 17 of resume/resumable/continue.
  "Interop"/"portability" appear in 2 files total. The documentation optimizes
  for defensibility; the product goal appears as one requirements row.
- **Ceremony vs. yield.** ~17,000–25,000 lines of gate/requirements/validation
  machinery certified a total interop failure at four layers, including a
  546-line blinded human-validation protocol whose answer key *requires* the
  reviewer to affirm the carriers are correct. By contrast the V-001–V-013
  census ledger found five real bugs — keep that, it is the highest-yield
  artifact in the repo.

---

## 7. Audit limitations

One agent claim **failed to reproduce** and is not relied on above: that
`codex→codex` on `parity/fixtures/codex.jsonl` loses `function_call` after two
hops. Measured directly, native emission survived both hops (1 → 1 → 1). The
same-format failure is real but fixture-dependent — it reproduces on
`tool-lifecycle-controls.jsonl`, whose tools fall outside the two-name
whitelist. Per-tool-name behavior, not a blanket same-format break.

Findings marked **[reported]** above were produced by code reading and have not
been individually re-executed.

---

## 8. Recommendations, prioritized

### Landed (commit af0b289e)

* **P1 — provenance gates deleted** in the Claude and Codex native paths, plus
  the `historicalizeCodexToolsForClaude` pre-pass. Every structural check was
  kept; only the `origin.format` conjuncts went.
* **P2 — decided error signals accepted.** The `ErrorSignal.native` demand was
  three separate over-strict checks; two are removed, Pi's remains.
* **P3 — pins inverted.** Fourteen Codex `native_decide` pins now assert native
  emission; `claudeNativeRegistryPolicyChecked` asserts the inverse of what it
  used to. Two additional discriminators were found while doing it and are
  *deliberately* kept as carriers, because they are genuine target limits, not
  provenance: Codex has no wire slot for Loom's canonical tool identity, and
  multi-block results must use Codex's array `output` form or block boundaries
  collapse (`["ab","c"]` and `["a","bc"]` both flattening to `"abc"`).
* **Unplanned, found only by running real data:** a single dangling `parentUuid`
  — 1 in 1323 records of a live session — rejected the entire transcript. It now
  degrades to a flagged thread root. This is the fixture-realism gap in §4
  biting exactly as predicted.

### Landed (2026-07-27, evidence layer)

* **P3 completed in `LoomRequirements`.** The inversion of af0b289e reached the
  product libraries but not the evidence layer, which kept the build red. Nine
  pins were reconciled against measured behaviour:
  * `claudeToCodexReadableCarrierWitness` → `claudeToCodexNativeLifecycleWitness`
    and `codexNativeContinuationWitness` now assert native `function_call` /
    `function_call_output` and all-`.native` dispositions. They previously
    asserted the *absence* of a native call and the presence of "[Historical
    tool call …]" prose — i.e. they pinned D-008 as the expected result. The
    rename matters: a pin named `…ReadableCarrierWitness` that checks native
    emission would misdescribe the evidence it supplies.
  * `codexLossyNativePairsUseCarrier` → `codexUnrepresentableResultPairsUseCarrier`,
    split because its two fixtures stopped agreeing. The extra-argument case is
    representable and now native; only the multi-block RESULT still needs the
    carrier, which is a target limit (`collapseResultBlockBoundaries` is
    `.corrupting`), not a provenance gate. The old combined pin implied
    lossiness in general justified a carrier.
  * `destructiveLossesBlocked` lost four cursor-agent rows that asserted
    refusals a0072e79 deliberately removed; `cursorAgentReportableLossesAreDisclosedNotRefused`
    replaces them by asserting each case still exports **and** still names its
    loss. The foreign-tool-id case is now lossless — native `tool_use`, exact
    id, canonical identity preserved — so it is required to report nothing.
  * `historicalCapabilityPolicyIsDispositionAware` splits destructive from
    reportable: `.dropThinking` and `.dropToolResults` are named but no longer
    destructive for cursor-agent, while `.dropToolResults` stays destructive for
    Claude, which HAS the slot. That asymmetry is the disposition-awareness the
    pin is named for.
  * `previewRequiredRefusalsPass` / `timestampSynthesisAndLossAreDistinct`
    follow `knownLosses` rating `dropTimeProvenance` `.reportable`: losing a
    non-recorded time is honest, minting one over it is not.
* **P4, partially — the missing law now has a shape.**
  `targetPreservesOrExplicitlyRefuses` was a two-way predicate, so the seven
  cells that began exporting-with-loss were indistinguishable from silent
  corruption and it called them all corruption.
  `targetExportsWithDisclosedLoss` adds the third disposition, admitting a cell
  **only** on positive disclosure: at least one obligation named, every named
  obligation non-destructive. A cell that loses something unnamed still fails.
  This is weaker than preservation by design — it is evidence that a loss was
  disclosed, never that it is acceptable — and it is a change to requirements
  semantics that warrants owner review rather than silent adoption.

### Still open

**P0 — Falsify D-008 first.** One afternoon. Convert a real Codex session with
native `tool_use` blocks, open it in Claude Code, confirm it loads and
continues. Everything below is conditional on the result; if D-008 is false,
roughly 8,000–10,000 lines of carrier machinery become deletable.

**P1 — Delete the provenance gates.** Remove the `origin.format ==` conjunct
from all four native predicates, and the `historicalizeCodexToolsForClaude`
pre-pass. Keep every structural check — name charset, object arguments, id
validity and uniqueness, single resolved result site, ordering. They are
correct and already pass. The corrected rule is `EmissionRule.choose` in
`LoomOps/Interop.lean`: it takes no source-format argument, and that absence is
the fix.

**P2 — Accept decided error signals.** Replace the `ErrorSignal.native` demand
with the total `ErrorSignal → Bool` projection already sitting beside each
check. Record inference in provenance, not by refusing native emission.

**P3 — Invert the pins.** Change `toolCallsEmittedNative: 0` to
`toolCallsEmittedNative == toolCallsImported`, and add the dual Lean pin
asserting some cross-format export *does* emit `tool_use`. That pin will not
compile until P1 lands, which converts the design decision into a
build-breaking obligation.

**P4 — Add the missing law.** A 12-cell A→B→A native-record census asserting
`RoundTripLevel.nonAccumulating` at minimum, reusing the existing per-format
parsers. This is the test that would have caught everything in this document.

**P5 — Move provenance out of content.** The `_agent_convert` top-level
envelope already exists and is already round-tripped; it currently only indexes
*into* content carriers. Put the payload there instead and leave
`message.content` native. Satisfies P2-provenance-out-of-band and improves the
injection posture.

**P6 — Relax the version pins** to ranges (Codex is already at 0.145.0 while
the pin is 0.144.1) and make unknown-record preservation two-way.

**P7 — Retarget the docs** around the goal, and demote refusal from default to
last resort per P4-report-loss-do-not-enact-it.
