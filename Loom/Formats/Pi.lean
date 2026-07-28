import Loom.Concepts

/-!
# Format — pi

A spoke like the others — listing pi's row is the point: the hub must be
able to describe pi's gaps, so pi cannot be the hub.

Sessions are JSONL under `~/.pi/agent/sessions/<cwd-slug>/*.jsonl`: line 0
is a session header (`type:"session"`, id, timestamp, cwd, version), every
subsequent line an entry with `id`/`parentId`/`timestamp`. The `parentId`
chain is authoritative (file order is not); branching is emergent via
shared parents; compactions are real entries carrying a summary and
`firstKeptEntryId`. Headers carry an open index signature, which is where
importers stash lossless extras blobs (`codexExtras`, `hermesExtras`, …).

Evidence base: `utils/src/pi/sessionCore.ts` + a full census of the local
corpus — **315 files / ~185,400 entries, all header version 3**, censused
2026-07-06. The format is open-ended: anything with the `BaseEntry` shape
is a valid entry, so the kind list below is "what's been observed," not a
closed set.
-/

namespace Loom.Formats.Pi

def storage : String := "~/.pi/agent/sessions/<cwd-slug>/*.jsonl"

def fileShape : FileShape := .jsonlAppend

/-- Native entry kinds. The first six are typed in `sessionCore.ts`; the
next four are observed in the corpus with no interface (they fall to the
`BaseEntry` catch-all). Counts are from the 2026-07-06 census. -/
inductive EntryKind where
  | sessionHeader        -- 315
  | message              -- 183,507
  | compaction           -- 266
  | branchSummary        -- 186
  | modelChange          -- 992
  | thinkingLevelChange  -- 527
  /-- Undocumented but real: app-level extensions on the BaseEntry shape. -/
  | custom               -- 76  (customType + data object)
  | sessionInfo          -- 71  (name)
  | customMessage        -- 32  (customType + content + display)
  | label                -- 3   (label + targetId)
  | unrecognized (label : String)
  deriving Repr, DecidableEq

def disposition : EntryKind → Disposition
  | .sessionHeader       => .mapped "EnvInfo + transcript Origin; native parentSession fork-lineage field (25 files) passes through extras, unconsumed by tooling"
  | .message             => .mapped "Payload.message"
  | .compaction          =>
      .conditional
        "two on-disk variants: agent-native NON-destructive (250/266; first-kept keeps its original parent, firstKeptEntryId is a render-pointer, carries details{modifiedFiles,readFiles}+fromHook) vs piedit destructive re-parent (16/266; firstKept.parentId==compaction.id, tokensBefore:0)"
  | .branchSummary       => .mapped "MetaEvent.branchSummary (shares the details/fromHook/fromId provenance shape)"
  | .modelChange         => .mapped "MetaEvent.modelChange"
  | .thinkingLevelChange => .mapped "MetaEvent.thinkingLevelChange"
  | .custom              => .unverified  -- customType ∈ {context_annotation, agent_message, clockworks.*, ceo_brief, …}
  | .sessionInfo         => .unverified
  | .customMessage       => .preservedInExtras  -- carries import provenance, e.g. customType "google-ai-studio-import"
  | .label               => .unverified
  | .unrecognized _      => .unverified

/-- Expressiveness row. -/
def supports : Concept → Support
  | .identity        => .native
  | .threading       => .native  -- parentId tree
  | .time            => .native
  | .roles           => .native  -- user/assistant/toolResult, plus rare bashExecution
  | .textContent     => .native
  | .thinkingContent => .native
      -- CORRECTED (was approximate): signatures ARE stored on disk —
      -- thinkingSignature on 97.8% of thinking blocks (26,697), plus
      -- textSignature (3,218) and Gemini thoughtSignature on toolCalls (731).
      -- pi→pi round-trip is signature-lossless; the `Block` TS type omits
      -- them but the JSONL preserves them as pass-through keys.
  | .toolLifecycle   => .native  -- toolCall blocks; toolResult with toolCallId+isError (1:1)
  | .errorSignaling  => .native  -- isError, boolean, only on toolResult (89,687, clean)
  | .compaction      => .native  -- compaction entries with firstKeptEntryId
  | .branching       => .native  -- emergent, shared parents (105/315 files branch)
  | .sidechains      => .absent  -- why claudeAdapter drops Claude sidechains today
  | .usage           => .native  -- PiUsage present on 100% of assistant messages
  | .environment     => .native  -- header cwd; extras blobs
  | .metaEvents      => .approximate
      "model_change/thinking_level_change/branch_summary typed; custom/session_info/label/custom_message carry app events untyped; foreign meta survives via header extras"
  | .media           => .approximate
      "image blocks exist on disk ([data,mimeType,type], 142) but are not in the sessionCore Block type"

def claims : List Claim := [
  { id := "L5-sidechain-loss-via-pi"
    statement :=
      "Converting Claude Code sessions through pi drops sidechain (subagent) \
       threads entirely; the information exists in the source and is \
       representable in Loom."
    status := .confirmed
      ("claudeAdapter walks the newest non-sidechain leaf \
        (claudeAdapter.ts:132-135); sidechain lines are never imported. \
        In Loom the drop becomes an export obligation to pi — visible, \
        counted, and attributable to pi's row in the matrix.") },
  { id := "L12-pi-signatures-on-disk"
    statement :=
      "pi stores provider reasoning signatures on disk (thinkingSignature, \
       textSignature, thoughtSignature), so pi→pi round-trip preserves them \
       even though the sessionCore Block type does not model them."
    status := .confirmed
      ("2026-07-06 census: thinkingSignature on 26,697/27,285 thinking \
        blocks, textSignature 3,218, thoughtSignature 731; grep confirmed \
        exactly these three keys, all pass through as untyped block fields.") },
  { id := "L13-pi-open-entry-set"
    statement :=
      "The pi on-disk format is open-ended: any BaseEntry-shaped record is a \
       valid entry, and app code writes kinds beyond the six typed ones."
    status := .confirmed
      ("census: custom (76), session_info (71), custom_message (32), label \
        (3) all present with no sessionCore interface; customType values \
        span context_annotation, agent_message, clockworks.*, ceo_brief, \
        google-ai-studio-import.") }
]

end Loom.Formats.Pi
