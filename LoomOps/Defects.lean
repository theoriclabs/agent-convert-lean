import Loom.Provenance

/-!
# Loom.Ops — conversion defect taxonomy

The shared scoreboard for evaluating any conversion implementation (the TS
toolchain, a Loom-checked pipeline, a future Lean core) against the same
typed objects. Four axes:

* `DefectLocus` — where the defect lives.
* `Visibility` — loud vs silent. Silent is the severe pole: a loud refusal
  is a *success* when the counterfactual was silent corruption.
* `CatchTime` — when it surfaced. Later is worse.
* `CatchClass` — how a given arm relates to a given defect. The ladder is
  ordered; "would have caught" claims only count as `detected` when
  **sabotage-verified** (re-introduce the fault, show the check go red) —
  argued catches stay `declaredOnly`. This is the falsifiability-table
  discipline applied to the evaluation itself.

Observed defects live here. *Risks* (believed-possible, never observed —
e.g. the Codex dedup false-drop) stay in `Loom.Claims` on the what-side; a
risk that fires graduates into this file.
-/

namespace Loom.Ops

/-- Where a conversion defect lives. -/
inductive DefectLocus where
  /-- Our model of a harness format is wrong or incomplete — the world
  surprised us (unknown line kind, wrong error heuristic). -/
  | formatKnowledge
  /-- Model right, transformation logic wrong (wrong leaf, scrambled
  order, over-eager dedup). -/
  | mapping
  /-- Output violates the target's structural invariants (orphan
  tool_use, dangling parent, duplicate ids). -/
  | structural
  /-- Fabrication or inference presented as recorded fact (smeared
  timestamps, guessed error status, synthesized ids passed off as native). -/
  | provenance
  /-- Corrupt, hostile, or concurrently-written input mishandled
  (cycle hangs, mid-write reads, truncated tails). -/
  | robustness
  /-- Tooling and process: write atomicity, backups, clobbered state. -/
  | process
  deriving Repr, DecidableEq

/-- How a defect manifests. -/
inductive Visibility where
  | loud    -- crash, hang, refusal, red gate: someone notices
  | silent  -- wrong output accepted downstream: nobody notices
  deriving Repr, DecidableEq

/-- When the defect surfaced. -/
inductive CatchTime where
  | importTime
  | exportTime
  | downstreamUse   -- e.g. `claude --resume` rejects or corrupts
  | latent          -- surfaced only by later audit; unknown blast radius
  deriving Repr, DecidableEq

/-- How an evaluation arm relates to a defect. Ordered strongest-first. -/
inductive CatchClass where
  /-- Impossible by construction (normal form excludes cycles; positional
  linking excludes duplicate-id corruption). Strongest, and rarest. -/
  | unrepresentable
  /-- A mechanical check goes red — only claimable when sabotage-verified. -/
  | detected
  /-- A claim/docstring names the risk; nothing executable checks it. -/
  | declaredOnly
  | missed
  deriving Repr, DecidableEq

/-- Ordinal severity, NOT cardinal: use for ranking and severity-weighted
counts, never for arithmetic claims like "twice as bad". Calibration of
the weights is itself ESTIMATED and revisable. -/
def severityRank (v : Visibility) (ct : CatchTime) : Nat :=
  let vBase := match v with
    | .silent => 4
    | .loud   => 0
  let tBase := match ct with
    | .importTime    => 0
    | .exportTime    => 1
    | .downstreamUse => 2
    | .latent        => 3
  vBase + tBase

/-- An observed conversion defect. `evidence` cites the fix (release,
campaign phase, commit) — every entry is a MEASURED historical fact, not a
hypothetical. -/
structure Defect where
  id         : String
  summary    : String
  locus      : DefectLocus
  visibility : Visibility
  caughtAt   : CatchTime
  formats    : List Format
  evidence   : String
  deriving Repr

/-- Exemplar ledger: a **sample** of the 2.25–2.27 hardening arc plus the
phase-7 deferrals, chosen to exercise every locus. NOT a census — the
upgrade path is mining the full CHANGELOG and gate-evidence JSON into this
list (mechanical, boring, worth doing before scoring arms). -/
def knownDefects : List Defect := [
  { id := "D1-cycle-hang"
    summary := "Hand-edited parent cycle hangs every reader (DoS)"
    locus := .robustness, visibility := .loud, caughtAt := .importTime
    formats := [.pi, .claudeCode]
    evidence := "toolchain-hardening phase-1; seen-set guards added everywhere" },
  { id := "D2-sidechain-leaf"
    summary := "Active path resumed from a sidechain leaf — wrong branch rendered as the conversation"
    locus := .mapping, visibility := .silent, caughtAt := .downstreamUse
    formats := [.claudeCode]
    evidence := "v2.25 fix: walk newest non-sidechain leaf (claudeAdapter.ts:132-135)" },
  { id := "D3-codex-iserror"
    summary := "Codex tool failures imported as successes (no structured flag, heuristic absent)"
    locus := .formatKnowledge, visibility := .silent, caughtAt := .latent
    formats := [.codexCli]
    evidence := "v2.25 fix: codexOutputIndicatesError heuristic (codexAdapter.ts:75)" },
  { id := "D4-orphan-tooluse"
    summary := "Exported Claude session with unclosed tool_use rejected on resume"
    locus := .structural, visibility := .loud, caughtAt := .downstreamUse
    formats := [.claudeCode]
    evidence := "v2.27 fix: exporter closes orphan tool_use blocks" },
  { id := "D5-gais-thought-leak"
    summary := "thought:true parts leaked into the visible answer text"
    locus := .mapping, visibility := .silent, caughtAt := .downstreamUse
    formats := [.googleAiStudio]
    evidence := "v2.27 fix: thought parts split into thinking blocks" },
  { id := "D6-cursor-double-wrap"
    summary := "cursor→pi→cursor re-import wraps content again (idempotence failure)"
    locus := .mapping, visibility := .silent, caughtAt := .latent
    formats := [.cursorAgent, .pi]
    evidence := "toolchain-hardening phase-7: deferred, documented in gate_evidence/phase-7.json" },
  { id := "D7-codex-compaction-orphan"
    summary := "Compaction replay references items the import dropped"
    locus := .formatKnowledge, visibility := .silent, caughtAt := .latent
    formats := [.codexCli]
    evidence := "toolchain-hardening phase-7: deferred" },
  { id := "D8-hermes-fallback-id"
    summary := "Unstable fallback ids minted on Hermes import"
    locus := .formatKnowledge, visibility := .silent, caughtAt := .latent
    formats := [.hermes]
    evidence := "toolchain-hardening phase-7: deferred" },
  { id := "D9-claude-block-order"
    summary := "Exported block order scrambled relative to source"
    locus := .structural, visibility := .silent, caughtAt := .downstreamUse
    formats := [.claudeCode]
    evidence := "v2.27 fix: block-order preservation" },
  { id := "D10-detect-scan-cap"
    summary := "Long meta preamble mis-detected format; session rendered as 0 turns"
    locus := .formatKnowledge, visibility := .silent, caughtAt := .downstreamUse
    formats := [.claudeCode]
    evidence := "v2.26 fix: detection scan cap widened 20→200 lines, in BOTH detector implementations" },
  { id := "D11-nonatomic-write"
    summary := "Crash mid-write could leave a live, resumable session half-written"
    locus := .process, visibility := .silent, caughtAt := .latent
    formats := [.pi, .claudeCode, .codexCli]
    evidence := "toolchain-hardening phase-1: atomicWrite (tmp + rename) adopted by all mutators" },
  { id := "D12-hermes-time-as-fact"
    summary := "Interpolated Hermes timestamps indistinguishable from recorded ones downstream (--since misleads)"
    locus := .provenance, visibility := .silent, caughtAt := .latent
    formats := [.hermes]
    evidence := "hermes.ts:210-212; accepted-by-design in TS, typed as Time.interpolated in Loom" },
  -- D13–D17: NEWLY FOUND by the 2026-07-06 Loom corpus census (not yet
  -- fixed in the TS toolchain). These are the retrospective-catch evidence
  -- that the census pass produced real, previously-unlogged defects — the
  -- strongest signal the spec earns its keep. Each needs a filed issue.
  { id := "D13-codex-assistant-double-emit"
    summary := "Codex assistant messages double-emitted (53,917×): event_msg precedes response_item so the compare-to-previous dedup never fires"
    locus := .mapping, visibility := .silent, caughtAt := .latent
    formats := [.codexCli]
    evidence := "census 2026-07-06: dedup is role-asymmetric (user RI→EM works, assistant EM→RI misses); codexAdapter.ts. RESOLVED 2026-07-06: dedup made cross-channel + channel-guarded, regression test codexAdapter.d13-dedup.test.mjs, 469/469 green. NOTE: the OSS copy at agent-convert still carries the bug — port before public launch (roadmap S14)." },
  { id := "D14-codex-usage-fabricated"
    summary := "Codex token_count usage was discarded and fabricated as makePiUsage(); TS convert import now projects real usage, Loom/default remains scoped"
    locus := .provenance, visibility := .silent, caughtAt := .latent
    formats := [.codexCli]
    evidence := "census: 110,622 token_count records unread; codexAdapter.ts:228 skip, codex.ts:939+ fabricated. PARTIAL 2026-07-08: `src/pi/codex.ts` now captures raw `event_msg.token_count` records in `header.codexExtras.rawTokenCountEvents` and projects `payload.info.last_token_usage` (fallback `total_token_usage`) onto the latest assistant-authored imported message as real pi `message.usage`, with the source snapshot retained under `usage.codex`; regression `convert-to-pi codex projects real event_msg.token_count usage onto assistant output`. Remaining scoped non-claim: the parseSession adapter still skips token_count, the Loom IR/Pi exporter has no usage field, and `convert-from-pi codex` does not re-emit Codex token_count events. Therefore the stable Loom default must not claim real Codex usage provenance yet." },
  { id := "D15-codex-two-oracles-disagree"
    summary := "Codex has TWO internally-inconsistent TS paths — the parseSession READ-path (adaptCodex) and the convert-to-pi CONVERT-path (codex.ts) disagree in FOUR+ ways that every real session trips. RESOLVED 2026-07-08: Loom now reproduces EITHER oracle — faithful default = adaptCodex; `--ts-parity` = codex.ts at 100% real-corpus parity — so the cutover no longer blocks on 'which is canonical'"
    locus := .mapping, visibility := .silent, caughtAt := .latent
    formats := [.codexCli]
    evidence := "RC2 real-corpus burn-in 2026-07-07 (17 files, Jan–Jul, 23KB–30MB) quantified the split: (1) DEVELOPER role — codex.ts→user '[developer] …', adaptCodex/Lean→assistant (14 rows/7 files); (2) EXEC-ENVELOPE unwrap — codex.ts strips 'Chunk ID:…Output:' → '[codex: exit=N]', adaptCodex/Lean keep raw (DOMINANT: 94% of function_call_outputs, 121437/128546); (3) MULTI-BLOCK text-join — codex.ts joins N text items→1, adaptCodex/Lean keep N; (4) COMPACTION 'latest' — codex.ts truncates before the last `compacted` + splices replacement_history (30MB file: 15481 lines→579 entries), adaptCodex/Lean keep the full linear stream (the one UNBOUNDED deferred feature). Loom's importCodexCli matches adaptCodex (its stated oracle) → 13/17 exact vs adaptCodex (rest = deliberate web_search/tool_search enrichment). NOT a Lean bug — a TS-internal inconsistency. CUTOVER DECISION: gate against adaptCodex (Lean ~exact), or reconcile codex.ts→adaptCodex (compaction-latest is the piece to design). The custom_tool_call/output import gap the same run found was FIXED (apply_patch, 1216 rows on the 30MB file now match). RESOLVED 2026-07-08 (goal: full codex conversion parity): `LoomConvert.CodexCli` now reproduces codex.ts for cutover gating (opt-in `loom convert codex pi --ts-parity`; `loom-diff --ts-parity` passes it through Lean-side) WITHOUT regressing the faithful default. TWO layers: (a) `importCodexCliTsParity` applies INPUT-level rewrites — transform 4 compaction-`latest` (`applyLatestCompaction`: drop records before the last `compacted`, splice its `replacement_history` as synthetic response_items) AND `web_search_call` result-pairing (`pairWebSearch`: fabricate the synthetic toolResult codex.ts emits, sharing a `call_id` so it resolves → no orphan); (b) `codexTsParity` applies OUTPUT-level transforms — developer-prefix (1, via `dev-entry` tag), exec-envelope unwrap (2, ONLY for `function_call_output` via an `envelopeEligible`/`fnout-entry` tag — `custom_tool_call_output`/apply_patch kept RAW, matching codex.ts), multi-block join (3). All four transforms + web_search carry `native_decide` pins. Two more INPUT-level drops (`dropTsParityNoise`) then closed the tail to FULL parity: (5) ALL `event_msg` — codex.ts:911 processes ONLY response_item; Loom kept user_message/agent_message (matching the READ path) and leaned on cross-channel dedup, but review-mode `<user_action>` sessions emit event_msg user_messages with NO response_item twin, so they survived as phantom entries; dropping event_msg is safe (normal sessions keep the response_item twin, identical text); (6) `tool_search_call`/`_output` (S6 enrichment codex.ts drops) — which ALSO removed the offset that had made unrelated call/text entries look mis-ordered (the apparent 'ordering' divergence was an artifact, not real). MEASURED: real-corpus `loom-diff --ts-parity` climbed from ~50% (compaction-free) / 0% (compaction) to **100% of every file codex.ts can convert** — 15/15 targeted, 79/79, and an independent fresh 50/50 (incl. compaction/apply_patch/web_search/tool_search/developer/review-mode). The only non-agreeing files are ones codex.ts ITSELF errors on (e.g. a session_meta-only empty rollout → 'No importable messages'), where Loom is strictly more tolerant. Faithful default + all prior pins UNCHANGED (build green, node 469/469, faithful codex clean, claude 3/3). EXHAUSTIVE full-corpus burn-ins 2026-07-08: first pass ALL 429 local rollouts (incl. a 93MB / 15k-line compaction session): **426 AGREE / 0 DIVERGE / 3 error**; latest pass ALL 433 local rollouts: **429 AGREE / 0 DIVERGE / 4 TS-ERROR**, all TS-side no-importable/empty-rollout refusals (Loom is more tolerant) = 100% of every file codex.ts can convert. The first burn-in caught ONE residual class the samples missed: inline-image text split — a user message `[input_text, input_image, input_text]` projected as TWO text blocks (`<img>;text:</img>`) because `mergeUserTextRuns` merged only ADJACENT text, while codex.ts's `codexMessageText` joins ALL text across the dropped image; fixed to join all text (order-safe: codex `message` entries carry only text/media), pinned. 5 CodexCli decide-pins." },
  { id := "D16-cursor-cli-subagents-dropped"
    summary := "cursor-agent CLI subagent child transcripts (subagents/*.jsonl) were dropped by the single-file adapter; Loom now stitches them as sidechain/detached threads"
    locus := .formatKnowledge, visibility := .silent, caughtAt := .latent
    formats := [.cursorAgent]
    evidence := "census: 144 child transcripts on disk, adapter reads one file only. NOTE 2026-07-07: the reusable stitching MECHANISM first landed in `LoomConvert.ClaudeSubagents`, which stitches Claude Code sidecars (`<session>/subagents/agent-*.jsonl` + `.meta.json`) as anchored `ThreadKind.sidechain`/`detached` threads via `stitchSubagents` + `findAnchor` (a capability BEYOND TS). The public `loom convert claude loom --with-subagents` path preserves those sidecar threads in `schema: loom.transcript.v0`; flat harness targets still refuse so anchors are not silently flattened. Verified on a real session, 48 children stitched, well-formed. RESOLVED 2026-07-08: `LoomConvert.CursorAgentSubagents` (`importCursorAgentSessionWithSubagents`) ports the same `stitchSubagents` core to cursor-agent, and the public `loom convert cursor-agent loom --with-subagents` path can preserve them. Real layout differs from Claude — sidecars live at `<slug>/agent-transcripts/<uuid>/subagents/<child>.jsonl` (SIBLING of the root file), 144 children, and there is NO `.meta.json` and NO in-band child→parent key, so anchoring is POSITIONAL (`findAnchorCursor` pairs the i-th child with the i-th main-thread `Task`/`Subagent` spawn call) — approximate BY CONSTRUCTION, documented as such (cursor cannot do better: it never stores tool results). Verified over the REAL store on 5 sessions (clean 1:1-anchored, mixed anchored+detached, and the census's zero-dispatch all-detached case): ALL violations = 0. A NEW capability beyond TS (`adaptCursorAgent` is single-file → no multi-file oracle; verified by well-formedness + structure, roadmap S23)." },
  { id := "D17-gais-error-branch-dropped"
    summary := "GAIS export carries errorMessage + branchParent/branchChildren; error events are captured, branch topology is still linearized"
    locus := .formatKnowledge, visibility := .silent, caughtAt := .latent
    formats := [.googleAiStudio]
    evidence := "census over 4 real blobs: errorMessage (7 chunks), branch pointers (2 files); googleAiStudio.ts:225 dropped both in TS. PARTIAL 2026-07-08: `LoomConvert.GoogleAiStudio` maps errorMessage into MetaEvent.custom events and `src/pi/googleAiStudio.ts` emits `google-ai-studio:error` pi events with the raw chunk retained; regression `preserves Google AI Studio errorMessage chunks as events without claiming branch topology`. BranchParent/branchChildren are still not modeled as shared-parent topology and the pi output remains a linearized chunk-order view, so GAIS branching fidelity remains an explicit non-claim." },
  { id := "D18-fast-path-no-cursor-agent"
    summary := "parseSessionFast (the `piview ls` fast path) has no cursor-agent branch → returns no header for cursor-agent files, so they are invisible/misrendered in fast listing"
    locus := .formatKnowledge, visibility := .silent, caughtAt := .latent
    formats := [.cursorAgent]
    evidence := "found by the L7 detector-agreement test 2026-07-06: 21/21 sampled cursor-agent files returned no header from parseSessionFast (sessionCore.ts:207). RESOLVED 2026-07-07: added a cursor-agent branch (looksLikeCursorAgentLine → synthesize basename-id header, matching full parseSession); L7 7/7 (coverage 21/21), cursor-agent/pi-search 47/47, the gap-encoding test updated to expect the header." },
  { id := "D19-exportpi-flat-threading"
    summary := "exportPi dropped parent links for synthesized-id formats: parentId was derived from the parent's rawId, which codex/hermes/gais importers set to none, so their IR→pi export emitted no parentId (flat thread) despite correct positional parents in the IR"
    locus := .mapping, visibility := .silent, caughtAt := .latent
    formats := [.codexCli, .hermes, .googleAiStudio, .pi]
    evidence := "found by the S18 cutover harness (loom-diff) 2026-07-07 — a bug ALL 11 decide-pins missed (they check import→normalize and same-format round-trip, never the cross-format import→exportPi→pi path the CLI uses). RESOLVED same day: parentId now falls back to the same `e{p}` id synthesis the entry id uses (Pi.lean entryToJson); codex→pi now threads e1→e0→…; pi round-trip pin unaffected (pi has real ids). The harness earned its keep on its first run." }
]

/-- One arm's relationship to one defect. `demonstrated = true` requires the
sabotage protocol: the fault was re-introduced (or a fixture embodying it
constructed) and the arm's check observably fired. Anything else is an
argument, and arguments score as `declaredOnly` at best. -/
structure ArmScore where
  arm          : String
  defectId     : String
  catchClass   : CatchClass
  demonstrated : Bool
  note         : String
  deriving Repr

/-- Filled by evaluation phase E0 (see `Loom.Eval`). Deliberately empty at
authoring time: pre-filling it with the author's own "would have caught"
judgments is exactly the counterfactual bias the protocol exists to kill. -/
def retrospectiveScores : List ArmScore := []

end Loom.Ops
