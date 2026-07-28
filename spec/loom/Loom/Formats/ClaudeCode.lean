import Loom.Concepts

/-!
# Format — Claude Code

The richest spoke. Top-level sessions are append-only JSONL under
`~/.claude/projects/<cwd-slug>/<session-uuid>.jsonl`, one record per line.

Two structural families of line (census term):
* **Envelope/DAG lines** — `user`, `assistant`, `system`, `attachment` —
  carry `uuid`/`parentUuid`/`timestamp`/`cwd`/`version`/`gitBranch`/
  `isSidechain` and form the conversation graph.
* **Control/state lines** — 10 kinds keyed only by `sessionId`
  (`last-prompt`, `mode`, `permission-mode`, `agent-name`, `custom-title`,
  `ai-title`, `pr-link`, `queue-operation`, `bridge-session`,
  `file-history-snapshot`) — interleaved session state, not graph nodes.
  Only `type` is universal across all lines; not even `uuid` or `sessionId`.

Tool results serialized inside `user`-role messages are environment output,
not user authorship (Loom records them as `environment`). Big tool outputs
are offloaded to `tool-results/<toolUseId>.txt` sidecars.

Evidence base: `utils/src/pi/claudeAdapter.ts` + a full census of the local
corpus — **35 top-level files / 55,930 lines + 158 subagent files, versions
2.1.141–2.1.202**, censused 2026-07-06. The 14-type schema is stable across
that window.
-/

namespace Loom.Formats.ClaudeCode

def storage : String := "~/.claude/projects/<cwd-slug>/<session-uuid>.jsonl"

/-- Sidechains and large tool results are externalized into a sibling
subtree, NOT inlined — a parser reading only the top-level JSONL sees
neither. -/
def sidechainStorage : String :=
  "~/.claude/projects/<cwd-slug>/<session-uuid>/subagents/agent-<agentId>.jsonl (+ agent-<agentId>.meta.json)"
def toolResultOverflow : String :=
  "~/.claude/projects/<cwd-slug>/<session-uuid>/tool-results/<toolUseId>.txt"

def fileShape : FileShape := .jsonlAppend

/-- Native line kinds (census counts, top-level corpus). The four envelope
kinds are graph nodes; the ten control kinds are session state. There is
**no `summary` kind** in the modern format (see claim L11). -/
inductive LineKind where
  -- envelope / DAG
  | user                 -- 9,639
  | assistant            -- 20,167
  | system               -- 3,152  (discriminated by .subtype)
  | attachment           -- 2,105
  -- control / state (sessionId-keyed, no uuid/parentUuid)
  | lastPrompt           -- 3,106  (leafUuid resume pointer)
  | mode                 -- 3,094
  | permissionMode       -- 3,028
  | queueOperation       -- 2,316
  | agentName            -- 2,156
  | customTitle          -- 2,037
  | prLink               -- 1,556
  | fileHistorySnapshot  -- 1,403  (only kind with no sessionId)
  | aiTitle              -- 1,101
  | bridgeSession        -- 1,070
  | unrecognized (label : String)
  deriving Repr, DecidableEq

/-- `system.subtype` — 8 observed. `compact_boundary` is half of the
compaction pair (claim L11). -/
inductive SystemSubtype where
  | turnDuration | stopHookSummary | awaySummary | apiError
  | localCommand | compactBoundary | bridgeStatus | modelRefusalFallback
  | unrecognized (label : String)
  deriving Repr, DecidableEq

/-- What the importer does with each native kind. Evidence: the drop list
`claudeAdapter.ts:29-33`; mapping `:197-249`; leaf/sidechain selection
`:124,:132-135`. -/
def disposition : LineKind → Disposition
  | .user =>
      .mapped "Payload.message role user; lines carrying tool_result blocks → environment-authored toolResult (roleCoerced)"
  | .assistant =>
      .mapped "Payload.message role assistant; tool_use → Block.toolCall; usage mapped"
  | .attachment =>
      .droppedDeliberately "rich injected-context payload (diffs/skill-lists/MCP-state) dropped — a fidelity loss (claudeAdapter.ts:29-33)"
  | .system =>
      .conditional "dropped by the user||assistant leaf filter; BUT subtype compact_boundary carries the compaction boundary + logicalParentUuid the adapter never reads"
  | .lastPrompt =>
      .mapped "not an entry — supplies activeLeaf via leafUuid (resume pointer); Loom stores it on Transcript.activeLeaf"
  | .fileHistorySnapshot => .droppedDeliberately "editor state (claudeAdapter.ts:29-33)"
  | .permissionMode      => .droppedDeliberately "harness config; candidate for MetaEvent.custom"
  | .queueOperation      => .droppedDeliberately "claudeAdapter.ts:29-33"
  | .mode                => .droppedDeliberately "not in the adapter's named drop list, dropped by the envelope filter"
  | .agentName           => .droppedDeliberately "session label"
  | .customTitle         => .droppedDeliberately "session label"
  | .aiTitle             => .droppedDeliberately "session label; not in the adapter's named drop list"
  | .prLink              => .droppedDeliberately "PR association metadata"
  | .bridgeSession       => .droppedDeliberately "IDE/remote bridge linkage; not in the adapter's named drop list"
  | .unrecognized _      => .unverified

/-- Expressiveness row. -/
def supports : Concept → Support
  | .identity        => .native  -- uuid per envelope line
  | .threading       => .native  -- parentUuid tree
  | .time            => .native
  | .roles           => .approximate
      "tool results serialized inside user-role messages; authorship recovered on import (roleCoerced)"
  | .textContent     => .native
  | .thinkingContent => .native  -- thinking blocks with signatures
  | .toolLifecycle   => .native  -- tool_use/tool_result with ids
  | .errorSignaling  => .native  -- is_error
  | .compaction      => .native  -- compact_boundary + isCompactSummary pair (see L11)
  | .branching       => .native  -- multiple children per parentUuid; forkedFrom cross-file lineage
  | .sidechains      => .native
      -- externalized to subagents/*.jsonl; anchor recoverable via
      -- meta.json.toolUseId → parent Agent tool_use id (census: 18/18 matched)
  | .usage           => .native
  | .environment     => .native  -- cwd, version, gitBranch per envelope line
  | .metaEvents      => .native  -- 10 control kinds + 8 system subtypes
  | .media           => .approximate
      "image content blocks (8) and attachment payloads exist; adapter handles neither top-level image nor fallback blocks"

def claims : List Claim := [
  { id := "L11-claude-compaction-shape"
    statement :=
      "Claude compaction is a `system.subtype:compact_boundary` line \
       (with compactMetadata + logicalParentUuid) immediately followed by a \
       `user` line with `isCompactSummary:true`; the resume pointer is a \
       separate `last-prompt.leafUuid`. There is NO `type:\"summary\"` line."
    status := .confirmed
      ("2026-07-06 census over 206 files, versions 2.1.141–2.1.202: 0 \
        summary lines; 15 compact_boundary system lines; 17 isCompactSummary \
        user lines (the 2 surplus are line-0 carried-in summaries from a \
        prior session). REVISES the earlier L11, which assumed a summary \
        line — that record was retired in the modern format.") },
  { id := "L14-claude-sidechain-anchor"
    statement :=
      "Claude subagent transcripts are externalized to \
       <session>/subagents/agent-<id>.jsonl, and the spawning anchor is \
       recoverable from the agent-<id>.meta.json sidecar's toolUseId, which \
       matches the parent Agent tool_use id."
    status := .confirmed
      ("census session 3e18e37d: 18 Agent tool_use calls ↔ 18 meta.json \
        files, 18/18 toolUseId matched, zero unmatched; spawnDepth up to 2 \
        proves nested subagents. Caveat: the anchor lives in the sidecar, \
        not the JSONL line stream — an importer must walk subagents/ to \
        recover it. Validates ThreadKind.sidechain(anchor).") },
  { id := "L15-claude-forward-refs-normal"
    statement :=
      "In harness-written Claude files, a line's parentUuid may point to a \
       line appearing LATER in file byte-order (forward reference); this is \
       normal, not corruption. Cross-file dangling parents also occur \
       (forkedFrom {sessionId,messageUuid}, logicalParentUuid)."
    status := .confirmed
      ("census: 29 forward references (0 cycles, 0 duplicate uuids), plus 3 \
        cross-file dangling parents. CONSEQUENCE: Loom's normal form \
        (parent strictly earlier) is an IMPORT-TIME property the importer \
        must establish by reordering, NOT a property of the Claude source. \
        Contrast pi, which is topologically file-ordered (claim L1).") }
]

end Loom.Formats.ClaudeCode
