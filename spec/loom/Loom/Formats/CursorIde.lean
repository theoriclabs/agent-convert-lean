import Loom.Concepts

/-!
# Format — Cursor IDE

A **different store entirely** from the cursor-agent CLI: IDE chats live as
composer + bubble records inside a SQLite database
(`~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`),
read via `convert-to-pi cursor`. This is the **richest source format of all
seven** — natively timestamped, with colocated tool call+result+status,
signed thinking, per-turn token accounting, and best-of-N branching.

The 2026-07-06 census produced the first ontology (was the L10 stub). Two
record kinds in the `cursorDiskKV` table:
* `composerData:<id>` (689 rows) — thread record, ~110 keys.
* `bubbleId:<composerId>:<bubbleId>` (156,612 rows) — message record,
  schema `_v:3`, ~70 keys.

The importer deliberately **linearizes**: it walks `fullConversationHeadersOnly`
in order and drops the native branching/best-of-N structure.

Evidence base: `utils/src/convertToPi.ts` cursor subcommand + `cursor.ts`
reader + a census of the live `state.vscdb` (400,418 cursorDiskKV rows).
-/

namespace Loom.Formats.CursorIde

def storage : String :=
  "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb — cursorDiskKV table (composerData:<id>, bubbleId:<composerId>:<bubbleId>)"

def fileShape : FileShape := .sqliteStore

/-- Native record kinds. -/
inductive RecordKind where
  | composerThread   -- 689  composerData:<id>
  | messageBubble    -- 156,612  bubbleId:<composerId>:<bubbleId>, _v:3
  | unrecognized (label : String)
  deriving Repr, DecidableEq

/-- Bubble `type` (role) is an int enum. -/
inductive BubbleType where
  | user       -- 1  (4,930)
  | assistant  -- 2  (151,681)
  | unrecognized (n : Int)
  deriving Repr, DecidableEq

def disposition : RecordKind → Disposition
  | .composerThread =>
      .mapped "transcript Origin.rawId + EnvInfo.sessionId from composerId and cwd from workspaceIdentifier.uri.fsPath; active path is linearized while the exact composer/envelope preserves branching, worktree, summary, and additive fields"
  | .messageBubble =>
      .conditional "type 1→user, type 2→assistant; toolFormerData → toolCall + separate toolResult (isError from status∈{error,cancelled}); thinking from thinking.text (+redactedThinking); tool-48 spawns recursed as inlined sidechains; exact bubble retained in Origin.extras.rawBubble"
  | .unrecognized _ => .unverified

/-- Expressiveness row — native at almost everything the source stores;
`approximate` cells mark where the importer degrades a native source. -/
def supports : Concept → Support
  | .identity        => .native  -- bubbleId/composerId/requestId (importer re-mints session id on export)
  | .threading       => .native  -- fullConversationHeadersOnly ordered array
  | .time            => .native  -- createdAt on ~100% of bubbles (156,611/156,612)
  | .roles           => .native  -- type 1/2
  | .textContent     => .native
  | .thinkingContent => .native  -- thinking object {text, signature, redactedThinking} on 40,854 bubbles
  | .toolLifecycle   => .native  -- toolFormerData colocates call+result+status+toolCallId (82,782 bubbles)
  | .errorSignaling  => .native  -- toolFormerData.status ∈ {completed, error, loading, cancelled}
  | .compaction      => .approximate
      "latestConversationSummary/summarizedComposers exist on the thread; not consumed by the importer"
  | .branching       => .approximate
      "native best-of-N in store (branches, isBestOfNParent, bestOfNJudgeWinner); importer LINEARIZES and drops it"
  | .sidechains      => .native
      -- subagentComposerIds + subagentInfo{parentComposerId, toolCallId, subagentType};
      -- anchor via toolCallId, inlined by --max-subagent-depth (default 5)
  | .usage           => .native  -- tokenCount{inputTokens,outputTokens} per bubble; usageData on thread
  | .environment     => .native  -- workspaceIdentifier.uri.fsPath = cwd; trackedGitRepos, addedFiles, …
  | .metaEvents      => .native  -- checkpointId, status, worktree flags, modelInfo.modelName per bubble
  | .media           => .approximate
      "recognized images with MIME+locator map to media blocks; opaque images, attachedFolders, gitDiffs, and additive media fields remain exact in raw bubble/envelope provenance"

def claims : List Claim := [
  { id := "L10-cursor-ide-ontology"
    statement :=
      "The Cursor IDE composer store has a describable, richly native record \
       ontology (composerData threads + versioned bubble messages) that Loom \
       hosts — the richest source of the seven formats."
    status := .confirmed
      ("2026-07-06 census over the live state.vscdb (400,418 cursorDiskKV \
        rows): composerData (689) + bubbleId (156,612, _v:3); native \
        timestamps (~100%), thinking objects with signatures (40,854), \
        toolFormerData with colocated result+status (82,782), per-bubble \
        tokenCount, and best-of-N branching. Resolves the L10 stub.") },
  { id := "L17-cursor-ide-enum-drift"
    statement :=
      "The importer's toolFormerData.tool→name table lags the live store; \
       unmapped enums degrade to cursor_tool_<n>."
    status := .confirmed
      ("RESOLVED 2026-07-06: re-censused 81,429 live tool bubbles; the two \
        lagging enums are now mapped — 0→update_current_step (128/129; a lone \
        set_active_branch on the protobuf default slot) and 62→await (37/37) \
        — eliminating the cursor_tool_0/62 degradations (166 bubbles). All 18 \
        pre-existing mappings re-verified against the live distribution, no \
        corrections; tsc clean, 6 cursor tests pass. Longer term the table \
        should be derived from this format file rather than hand-maintained.") }
]

end Loom.Formats.CursorIde
