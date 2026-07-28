import LoomOps.Defects

/-!
# Loom.Ops — lessons & roadmap

The project's own meta-state, typed so it composes with the rest of the how-
side: lessons carry the evidence that earned them; steps cross-reference the
claim ids (`Loom.Claims`) and defect ids (`LoomOps.Defects`) they close.

Following the corpus census of 2026-07-06. Prose is the artifact here
(guide ch. 1: prose is coequal); the types are handles for querying, not a
substitute for the insight.
-/

namespace Loom.Ops

/-- Scope of a lesson: specific to Loom, or a reusable operating insight
that should eventually be promoted to `agent-ops`. -/
inductive Scope where
  | loomSpecific
  | practiceGeneral
  deriving Repr, DecidableEq

structure Lesson where
  id      : String
  insight : String
  evidence : String
  scope    : Scope
  deriving Repr

def lessons : List Lesson := [
  { id := "LN1-description-found-bugs"
    insight :=
      "Writing the honest description — with no conversion code — is itself \
       a bug-finding activity. Forcing every format cell to be true against \
       real data surfaced five silent defects in the SHIPPING toolchain and \
       refuted three of our own confident claims. This is the empirical \
       answer to 'does the Lean spec earn its keep': yes, before the bridge \
       exists."
    evidence :=
      "census found D13 (Codex assistant double-emit 53,917×), D14–D17; \
       refuted L2, L11, and the Hermes tool map; corrected Hermes storage."
    scope := .practiceGeneral },
  { id := "LN2-cheap-honesty"
    insight :=
      "Every `unverified` cell had an upgrade path that was a jq query, not \
       an experiment, because the corpus lives on the machine. Front-load \
       the census: the domain's defining advantage (truth is on disk, now) \
       is only cashed in if you actually read the disk. Guesses that felt \
       safe (Codex reasoning is `native`; Hermes usage `unverified`) were \
       exactly the wrong ones."
    evidence :=
      "resolveBy for L2/L3/L9/L12/L16 were all corpus scans; each flipped a \
       cell or a claim when run."
    scope := .practiceGeneral },
  { id := "LN3-hub-not-ceiling"
    insight :=
      "Giving pi its own matrix row (a spoke, not the hub) is what turned \
       'the adapter drops sidechains' from an implementation fact into an \
       attributable, derivable loss. Never let one implementation's model \
       become the ceiling of what you can describe losing."
    evidence :=
      "piSupports.sidechains = absent makes lossyConcepts/obligations derive \
       the Claude→pi sidechain drop automatically (claim L5)."
    scope := .loomSpecific },
  { id := "LN4-description-over-proofs"
    insight :=
      "Zero theorems; all leverage came from typed records, exhaustive \
       matches, rich docstrings, and TOTAL dispatches. Adding the `media` \
       concept broke all seven format rows until each answered — the type \
       checker as completeness auditor, a stronger daily driver than any \
       proof would have been at this stage. Premature theoremization would \
       have spent the census budget."
    evidence :=
      "supports/disposition are total functions; the media addition forced \
       7 edits; the only decidability instance (WellFormed) is computation."
    scope := .practiceGeneral },
  { id := "LN5-structure-creates-questions"
    insight :=
      "One-file-per-format made description depth vary honestly and gave new \
       claims a home the monolith didn't have. Splitting the files is what \
       surfaced L9–L14; the act of asking 'what does THIS format store' per \
       file generated the census questions."
    evidence :=
      "L9 (cursor kinds), L10 (cursor IDE ontology), L11–L15 all originated \
       in the per-format split, not the aggregate."
    scope := .loomSpecific },
  { id := "LN6-what-how-held"
    insight :=
      "When the census found the Codex double-emit, the what/how split kept \
       it untangled: the FACT (assistant text is double-emitted) landed in \
       the support row + claim on the what-side; the DEFECT (adapter bug) \
       landed in the how-side ledger. The compiler-enforced import direction \
       did real work under pressure."
    evidence :=
      "L2 (Loom.Claims, what) vs D13 (LoomOps.Defects, how); LoomOps imports \
       Loom, never the reverse."
    scope := .loomSpecific },
  { id := "LN7-adapters-disagree"
    insight :=
      "The two TS conversion paths silently disagree with each other, and \
       only a shared spec catches it. This is the 'wire shapes hand-written \
       thrice' / Tgrad `_TRIPLE_SET` leak the bridge guide names — the spec \
       IS the missing shared source of truth between piview and convert."
    evidence :=
      "D15: Codex `developer` role → assistant in codexAdapter.ts:164 but → \
       user in codex.ts:941-947."
    scope := .practiceGeneral },
  { id := "LN8-sidecars-and-import-time-normal-form"
    insight :=
      "Two structural facts an importer must respect: (1) 'read the .jsonl' \
       is insufficient — Claude externalizes subagents and big tool outputs \
       to sidecar trees that must be walked; (2) normal form (parent earlier \
       in order) is an IMPORT-TIME obligation for Claude (forward refs are \
       normal), not a source guarantee — so the reader's cycle guard is \
       defensive-only and the importer must build the id map before \
       resolving parents."
    evidence :=
      "L14 (subagents/ + tool-results/ sidecars), L1b (Claude 29 forward \
       refs vs pi 0)."
    scope := .loomSpecific }
]

/-- Lessons worth promoting into `agent-ops` as reusable operating patterns. -/
def practiceGeneralLessons : List Lesson :=
  lessons.filter (fun l => l.scope = .practiceGeneral)

inductive StepStatus where
  | done      -- completed this arc
  | next      -- ready, cheap, high-value — do these first
  | later     -- real but sequenced behind `next`
  | blocked   -- waiting on a decision or an upstream step
  | deferred  -- deliberately out of scope for now
  deriving Repr, DecidableEq

/-- A roadmap step. `refs` points at the claim/defect ids it closes;
`detail` carries the actual content (prose is the artifact). -/
structure Step where
  id     : String
  title  : String
  detail : String
  status : StepStatus
  refs   : List String := []
  deriving Repr

def roadmap : List Step := [
  -- ── done this arc ──────────────────────────────────────────────
  { id := "S0-census"
    title := "Corpus-ground all seven format specs"
    detail := "Done 2026-07-06: five parallel censuses over the on-machine corpora; every kind/disposition/support-row resolved against real data; 16/20 claims confirmed."
    status := .done },

  -- ── next: cheap, high-value, mostly corpus-scan-shaped ─────────
  { id := "S1-fix-d13"
    title := "Fix D13 (Codex assistant double-emit) + regression test"
    detail :=
      "DONE 2026-07-06: codexAdapter.ts dedup made cross-channel + channel-guarded; assistant double-emit eliminated, constraints preserved (+10 rescued); test codexAdapter.d13-dedup.test.mjs, suite 469/469. Closed claim L2. Filing D14–D17 as public issues is left to the user (outward-facing, agent-convert OSS repo)."
    status := .done
    refs := ["D13", "L2"] },
  { id := "S2-detection-differential"
    title := "Close L7 with a differential detector test"
    detail :=
      "DONE 2026-07-06: test/detector-agreement.test.mjs runs both detectors over 110 files (80 real) and asserts agreement, 7/7. Surfaced defect D18 (parseSessionFast has no cursor-agent branch)."
    status := .done
    refs := ["L7", "D18"] },
  { id := "S3-cursor-enum-refresh"
    title := "Close L17: refresh the Cursor IDE tool-enum table"
    detail :=
      "DONE 2026-07-06: censused 81.4k live tool bubbles; mapped enum 0→update_current_step and 62→await; all 18 existing entries re-verified. tsc clean, cursor tests pass. Closed claim L17."
    status := .done
    refs := ["L17"] },

  -- ── next: follow-ons surfaced while closing S1–S3 ─────────────
  { id := "S14-port-d13-to-agent-convert"
    title := "Port the D13 fix to the agent-convert OSS repo"
    detail :=
      "MOOT as of 2026-07-06: the TS HN launch is pulled (going Lean-first), so the agent-convert TS package won't ship and its D13 bug no longer matters. The already-fixed utils TS copy remains the reference oracle for the port (RC1). Revisit only if the TS launch is un-cancelled."
    status := .deferred
    refs := ["D13"] },
  { id := "S15-fast-path-cursor-agent"
    title := "Give parseSessionFast a cursor-agent branch (D18)"
    detail :=
      "DONE 2026-07-07: added the cursor-agent branch to parseSessionFast (sessionCore.ts) — synthesizes a basename-id header via looksLikeCursorAgentLine, matching full parseSession, so `piview ls` fast-listing sees cursor-agent files. L7 detector-agreement 7/7 (coverage 21/21), cursor-agent/pi-search 47/47, the gap-encoding test updated. (A TS fix — piview stays TS for now; D18 resolved.)"
    status := .done
    refs := ["D18"] },
  { id := "S15b-cursor-ide-sqlite-actuator"
    title := "Cursor IDE sqlite actuator + hermes/gais cross-parity"
    detail :=
      "DONE 2026-07-07, EXTENDED 2026-07-08: (a) LoomConvert.CursorIdeActuator reads state.vscdb via a `sqlite3` subprocess (thin actuator; libsqlite3 FFI is a later no-subprocess option), assembles composer+bubbles JSON, feeds importCursorIde — verified end-to-end and wired into `loom cursor-ide`. (b) hermes/gais cross-parity now pinned green (convert-to-pi → pi JSONL → capture → native_decide). (c) Cursor IDE cross-parity is now covered by S24 with a synthetic structure-only vscdb plus release-gate actuator smoke."
    status := .done },

  { id := "S19-role-content-sum"
    title := "Role-content-sum IR refactor (LoomOps.Design 'now' step)"
    detail :=
      "DONE 2026-07-07: Core split — Block → UserBlock/AssistantBlock/EnvBlock, Payload.message → userMsg/assistantMsg/envMsg/otherMsg — so `userMsg [.toolCall …]` is a TYPE ERROR, not a runtime check, and tool RESULTS (envMsg/EnvBlock) are structurally distinct from tool CALLS (assistantMsg/AssistantBlock). I adapted Core/WellFormed/Conversion/Pi/Parity/smokes; a 6-way fan-out adapted the format importers+exporters. Full build green; ALL 11 decide-pins stayed green + round-trip + signature preservation + CLI all unchanged = machine-checked proof the foundational refactor changed ZERO observable behavior (the 'importers are the regression corpus' thesis, realized). Still open from Design.Design: reframe the support matrix as the derived shadow of a decidable WF_F family (the full refinement-lattice; the role-content sum was its cheapest high-value part)."
    status := .done },

  -- ── later: spec deepening (still pure description) ─────────────
  { id := "S4-nested-block-wf-RESOLVED"
    title := "Recurse well-formedness into toolResult.content — RESOLVED by S19"
    detail :=
      "MOOT 2026-07-07: after the role-content-sum, EnvBlock.toolResult content is List UserBlock, and UserBlock cannot hold a tool result — so nested tool results are UNREPRESENTABLE and there is nothing to recurse into. The refactor dissolved this item structurally."
    status := .done },

  { id := "S5-model-dropped-richness"
    title := "Model the currently-dropped rich payloads"
    detail :=
      "DONE 2026-07-07 (3-way fan-out) for the highest-value formats: Claude (unknown block kinds → .unmodeled instead of dropped), Codex (web_search/tool_search → toolCall/.unmodeled; event_msg.error → MetaEvent.custom event, via a new KPayload.kevent arm), GAIS (errorMessage → event; branchParent/finishReason noted as remaining). Each captures the content as .unmodeled/.event (the escape hatch) with a NEW fixture + local compile-time check; GAIS error events are now also covered by the TS importer, while signatures/media remain Loom-richer and unpinned against TS. Remaining/lower-value: pi customType vocab (L13), cursor-ide branching/subagents, Claude attachment 52-key sub-schema (kept as .unmodeled raw, not exploded)."
    status := .done
    refs := ["L13", "L19"] },
  { id := "S6-media-per-format"
    title := "Flesh out the media concept per format"
    detail :=
      "DONE 2026-07-07: the role-content-sum added .media to UserBlock/AssistantBlock; the importers now populate it — Claude image blocks → .media, Codex input_image → .media, GAIS drive*/inlineFile → .media, and GAIS thoughtSignature PRESERVED (L12-class fidelity win). All elide base64 to a ref/placeholder (never inline bytes). Verified by local compile-time checks; not cross-parity-pinned (TS drops media → Loom richer). pi image blocks + Cursor IDE images are the remaining smaller cases."
    status := .done },
  { id := "S7-version-tolerance"
    title := "Version-scope the Codex model"
    detail :=
      "LARGELY SATISFIED by construction: the Lean importers parse every field through Option accessors (ostr/oobj → .getD default), so a missing or newly-shaped field never crashes — it degrades to a default or an `.unmodeled` block. So cli_version drift (base_instructions string→{text}, polymorphic source/window_id) is tolerated. What remains is DOCUMENTARY: record in each Loom/Formats/* the version window it was censused against (a docstring convention), not code."
    status := .done },
  { id := "S20-refinement-lattice"
    title := "Refinement lattice — first increment (rest of Design.lean)"
    detail :=
      "DONE 2026-07-07 (LoomOps.Refinement): per-format wf_F decidable predicates (cursorAgent/codex/hermes/gais/pi/claude — each format's structural constraints as a Bool), ordered into an expressiveness lattice (latticeEdges + edgeHoldsOn), and obligations DERIVED as the predicate diff (predicateDiff tgt t = the wf_tgt constraints t violates — parallels LoomOps.Conversion.obligations, showing it's the matrix's decategorified shadow). Decidable Bools per-transcript, no theorems, no FormatSpec-indexed Transcript (Design.lean's caveat honored). Remaining Design.lean far-ceiling (generative universe Transcript:FormatSpec→Type) deliberately NOT built."
    status := .done },

  -- ── committed: the Lean port + TS retirement (decision 2026-07-06) ──
  -- Sequencing law (bridge guide §5, agent-ops process-migration ratchet):
  -- parity BEFORE retirement. TS stays the reference oracle until leanCore
  -- passes RC1+RC2; retiring the working converter before the Lean one
  -- executes is the exact string-ferry/dead-emitter failure the guide warns
  -- of. The actuator here is only file IO + one sqlite read — both Lean-
  -- reachable — so leanCore can be near-standalone (~pure Lean), the EASY
  -- case for the doctrine, not the GPU/browser hard cases.
  { id := "S8-serialization"
    title := "deriving ToJson/FromJson on Core (Lean-native IO.FS/Json)"
    detail :=
      "SUBSUMED 2026-07-07: the per-format importers/exporters ARE the codecs (format JSON ↔ Loom IR, via Lean.Data.Json + IO.FS, no host bridge). A generic IR ToJson/FromJson isn't needed for the conversion path; add later only if a canonical IR wire form is wanted."
    status := .done },
  { id := "S9-decide-pin-fixtures"
    title := "Decide-pin TS outputs on golden fixtures — the parity harness (RC1/M4)"
    detail :=
      "HARNESS DONE 2026-07-06 (LoomConvert.Parity): both halves of RC1 are live as native_decide pins folded into lake build — self-parity (round-trip stable under `normalize`) and cross-parity (Lean's `normalize` == TS golden captured by parity/capture-parity.ts). Non-vacuous by construction (can't prove false=true). Coverage now grows one fixture/format at a time as S16 lands; each divergence is adjudicated as a leanCore bug or an improvement (then re-pin)."
    status := .done
    refs := ["M4-drift", "RC1-parity-gate"] },
  { id := "S16-lean-importers"
    title := "Port the six importers to Lean (host → Loom IR)"
    detail :=
      "DONE 2026-07-07 (6-way sub-agent fan-out): all six importers ship as LoomConvert/* — pi, claude, codex, cursor-agent, cursor-ide, hermes, gais — each producing a well-formed IR (0 violations) from its Loom/Formats/* disposition table, with import assumptions logged as ImportNotes. FOUR have green cross-parity native_decide pins vs the TS oracle (pi, claude, codex incl. the D13 dedup both directions, cursor-agent). Hermes/gais importers land with reported normalize (cross-parity needs the convert-to-pi capture path — follow-up). Cursor-ide lands on a JSON representation; its sqlite actuator + cross-parity are S15b. The fan-out surfaced a consistent 3-class 'Loom refines TS' divergence set (cwd, tool-name, toolResult) that validates LoomOps.Design's refinement-lattice thesis — the parity projection was reconciled to a structural-content skeleton so enrichments are adjudicated-better, not gate failures."
    status := .done },
  { id := "S17-lean-exporters-cli"
    title := "Port exporters + the CLI surface to Lean (`lake exe loom`)"
    detail :=
      "DONE 2026-07-07: exporters for the convert-from-pi targets (pi, claude, codex, cursor-agent) via a 3-way fan-out, each with a green round-trip self-parity native_decide pin (import→export→import stable under normalize). `lake exe loom convert <from> <to> <input> [output]` + `loom cursor-ide <db> <cid> <to>` works end-to-end for all formats, refusing to export a malformed IR. Distribution is now a lake/elan package or prebuilt binary (npm reservation moot). Remaining: piview/pi-search interactive read surface (bigger, ecosystem-favored on Node — separate call, not part of the converter kill)."
    status := .done },
  { id := "S18-cutover-retire-ts"
    title := "Cut over consumers, burn-in, retire TS (RC1→RC2→RC3)"
    detail :=
      "HARNESS BUILT 2026-07-07 (parity/loom-diff.ts, the RC2 dual-run differ): runs Lean `loom` and TS `convert-to-pi` on a corpus and reports normalize-level AGREE/DIVERGE per file, exit-1 on any divergence (gate-able). Earned its keep immediately — found D19 (exportPi flat threading, a bug all 11 pins missed), now fixed, and re-surfaced D15 (codex developer role, TS-side). The MECHANISM is done; the actual cutover→burn-in→retire needs running it over the real corpus (an operating step, not more code), and reconciling any remaining divergences. TS is archived-as-oracle at retirement, never deleted (RC3)."
    status := .done
    refs := ["RC1-parity-gate", "RC2-dual-run-burnin", "RC3-retire-not-delete", "D19-exportpi-flat-threading"] },

  -- ── process / productization ───────────────────────────────────
  { id := "S11-promote-lessons"
    title := "Promote practice-general lessons to agent-ops"
    detail :=
      "DONE 2026-07-07: created agent-ops/processes/spec-driven-reimplementation/ (README + process.yaml, registered in the index) as a `process`, maturity `pilot` (Loom is its one run). The four moves: census-first → pin-the-reference → fan-out-behind-the-gate → adjudicate-divergences. The agent independently verified the claims (counted the 11 pins, confirmed D13–D17) and honestly framed it as a pin-gated rewrite, not a completed cutover."
    status := .done },
  { id := "S12-oss-differentiator"
    title := "Wire Loom into the OSS story"
    detail :=
      "REFRAMED by the Lean-first pivot: Loom is the release vehicle for the developer-preview conversion path, not just a TS-package differentiator. PACKAGING DONE 2026-07-08: `lake build loom` → self-contained binary at `.lake/build/bin/loom` (verified standalone, no lake needed); README now leads with developer quickstart, CLI surface, examples, release gate, fallback behavior, and versioned `loom` wire import/export; the spec dir ships clean (no secrets, no fixtures to scrub). RC1 parity gate MET — latest fresh burn-in: codex 433 files = 429 agree / 0 diverge / 4 TS-only empty-rollout refusals, cursor-agent 427/427, claude 237/237 under TS-parity projection, every transform decide-pinned. RC3 developer preview is DONE for Codex/Claude/GAIS/Hermes when the Loom binary is discoverable; installed packages fall back to TS when not, Cursor IDE remains TS by default until the sqlite actuator is packaged, and release notes must not claim stable/default replacement parity."
    status := .done
    refs := ["D13", "D14", "D15", "D16", "D17", "D18"] },

  -- ── deferred ───────────────────────────────────────────────────
  { id := "S13-turn-semantics"
    title := "Typed turn view functions"
    detail :=
      "DONE 2026-07-07 (Loom.Turns): the role-content-sum unblocked it — a turn boundary is exactly a `userMsg` (role-typed across every format), so a single CANONICAL view replaces the per-harness definitions L8 feared. `turns`/`turnCount`/`turnOfEntry` over the entries array; cross-format turn-count parity is now `turnCount (importF file)` on the shared IR (a view property, as claim L8 states — now resolved). turnCount is axiom-clean (no sorry)."
    status := .done
    refs := ["L8"] },

  -- ── cutover-gating trio (GM checkpoint 2026-07-07) ─────────────
  { id := "S21-ts-parity-gating"
    title := "TS-parity gating mode + codex convert-path renderer"
    detail :=
      "DONE 2026-07-07, EXTENDED to full parity 2026-07-08. Two halves of a gate-able cutover: (a) `LoomConvert.Parity.normalizeTsParity` + `loom-diff --ts-parity` drop Loom's ADDITIVE enrichments (media/unmodeled); (b) `LoomConvert.CodexCli` reproduces codex.ts's TRANSFORMATIVE convert-path via `importCodexCliTsParity` (INPUT-level: transform 4 compaction-`latest` = `applyLatestCompaction`, and `web_search_call` result-pairing = `pairWebSearch`) composed with `codexTsParity` (OUTPUT-level: developer-prefix, exec-envelope unwrap — `function_call_output` ONLY via `fnout-entry` tag, multi-block join). ALL FOUR D15 transforms + web_search-pairing + two input drops (`dropTsParityNoise`: all `event_msg` since codex.ts processes only response_item, and `tool_search_*`), each `native_decide`-pinned. Wired `loom convert codex pi --ts-parity`. Result: real-corpus `loom-diff --ts-parity` climbed ~50%/0% → **100% of every file codex.ts can convert** (15/15 targeted, 79/79, independent fresh 50/50 incl. compaction/apply_patch/web_search/tool_search/review-mode). Non-agreeing files are ones codex.ts itself errors on (empty rollouts). Faithful default UNCHANGED — pins green, node 469/469, claude 3/3."
    status := .done
    refs := ["D15"] },
  { id := "S22-claude-subagent-stitch"
    title := "Claude sidechain stitching (capability beyond TS)"
    detail :=
      "DONE 2026-07-07, WIRE-EXPORT COVERED 2026-07-08. `LoomConvert.ClaudeSubagents` stitches Claude Code sub-agent sidecars (`<session>/subagents/agent-*.jsonl` + `.meta.json` `toolUseId`) into the main transcript as anchored `ThreadKind.sidechain` threads (`stitchSubagents`/`findAnchor`/`rebaseEntry`; unmatched → `detached`). The public `loom convert claude loom --with-subagents` path preserves those sidecar threads in `schema: loom.transcript.v0`; flat harness targets still refuse so anchors are not silently flattened. Verified on a real session (48 children stitched, well-formed, 96→3437 entries) + a synthetic `native_decide` pin. This is NOT D16 (which is cursor-agent) — it is the reusable template a cursor port would apply; D16 stays open (until S23)."
    status := .done
    refs := ["D16"] },

  -- ── coverage completion + cutover staging (2026-07-08) ─────────
  { id := "S23-cursor-agent-subagent-stitch"
    title := "Cursor-agent sidechain stitching (D16 resolved)"
    detail :=
      "DONE 2026-07-08. `LoomConvert.CursorAgentSubagents` ports the `stitchSubagents` core to cursor-agent, RESOLVING D16. Real layout: `<slug>/agent-transcripts/<uuid>/subagents/<child>.jsonl` (sibling of root), 144 children, NO `.meta.json` and NO in-band child→parent key — so `findAnchorCursor` pairs the i-th child with the i-th main-thread `Task`/`Subagent` spawn call (POSITIONAL, approximate by construction; cursor never stores tool results). Verified over the REAL store on 5 sessions (clean 1:1, mixed anchored+detached, zero-dispatch all-detached): all violations = 0, + 3 synthetic `native_decide` pins. Capability beyond TS (single-file adapter → no oracle)."
    status := .done
    refs := ["D16"] },
  { id := "S24-cursor-ide-cross-parity"
    title := "Cursor IDE cross-parity — the last uncovered format cell"
    detail :=
      "DONE 2026-07-08. Cursor IDE was the only format never cross-validated against a TS oracle. Found it (`importCursorChatToPi`, cursor.ts:1849, `convert-to-pi cursor --chat-id`), discovered `test.vscdb` was a 0-byte placeholder, populated it with a synthetic STRUCTURE-ONLY store (real schema, no real content), and added a `native_decide` cross-parity pin `crossParityOkWith importCursorIde cursorIdeCase1` for the JSON importer — both sides land on the identical normalize skeleton (4 entries, 0 violations). The sqlite actuator itself is IO, so release verification smoke-runs `loom cursor-ide test.vscdb cmp-fix pi`. ALL SEVEN format cells now have a cross- or self-validation story, with Cursor IDE split into compile-time importer pin + runtime actuator smoke."
    status := .done
    refs := [] },
  { id := "S25-cutover-staged"
    title := "Developer-preview convert cutover flipped (scoped RC3)"
    detail :=
      "DONE 2026-07-08. `src/convertToPi.ts` now delegates to the `loom` binary by default for Codex (`--ts-parity`), Claude, Google AI Studio, and Hermes when the binary is discoverable via `LOOM_BIN`, repo build, or PATH; `PI_CONVERT_ENGINE=ts` is the explicit rollback path, and missing runtime binary falls back to TS instead of failing. The Loom branch honors safe header/provider overrides; Codex preserves `codexExtras` and `--strip-extras`; semantic modes not modeled in Lean route that invocation through TS. Cursor IDE remains TS by default because the Lean actuator shells out to system sqlite3, with explicit `PI_CONVERT_ENGINE=loom` available for validation. RC1 gate met (latest codex full-corpus: 433 files, 429 agree, 0 diverge, 4 TS-only empty-rollout refusals), RC2 shadow = loom-diff, RC3 developer preview = done without claiming stable/default replacement parity."
    status := .done
    refs := ["D15"] }
]

/-- The immediate work queue, as a query. -/
def nextUp : List Step := roadmap.filter (fun s => s.status = .next)

end Loom.Ops
