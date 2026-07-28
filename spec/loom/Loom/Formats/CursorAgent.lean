import Loom.Concepts

/-!
# Format — cursor-agent CLI

The most impoverished spoke, and **distinct from the Cursor IDE store**
(`CursorIde.lean`): the CLI writes Claude-like JSONL transcripts; the IDE
keeps composers in `state.vscdb`.

Structure (census-confirmed): linear records in file order; **no per-entry
ids, no timestamps, no cwd on any record**. The importer synthesizes
`caNNNN` entry ids and `ca-tcNNNN` tool-call ids; the path-aware file importer
stamps transcript/session identity from the `.jsonl` filename. The project
directory slug (`/`→`-`) is not injective, so cwd is not guessed.

The sharpest fact: the CLI stores tool CALLS but **never tool RESULTS** —
there is no tool_result record anywhere, so tool-level error signaling
cannot exist in this format.

Evidence base: `utils/src/pi/cursorAgentAdapter.ts` + a census of the local
corpus — **427 files (283 root + 144 subagent) / ~14,863 records**, censused
2026-07-06. Note: `test/fixtures/cursor/` are IDE fixtures, not CLI ones —
the CLI adapter has no dedicated fixtures.
-/

namespace Loom.Formats.CursorAgent

def storage : String :=
  "~/.cursor/projects/<cwd-slug>/agent-transcripts/<uuid>/<uuid>.jsonl (subagents under .../<parent>/subagents/<child>.jsonl)"

def fileShape : FileShape := .jsonlAppend

/-- Native record kinds — EXACTLY 3 top-level shapes across the corpus
(completes claim L9). No standalone tool record exists: tool calls are
`tool_use` BLOCKS inside `message` records. -/
inductive RecordKind where
  | message              -- 14,859  {role, message}; role ∈ {assistant, user}
  /-- turn_ended metaevent, success variant. -/
  | turnEnded            -- 2  {status, type}
  /-- turn_ended metaevent, error variant. -/
  | turnEndedError       -- 2  {error, status, type}
  | unrecognized (label : String)
  deriving Repr, DecidableEq

/-- Content blocks inside `message.content[]` — EXACTLY 2 kinds. No
thinking, no tool_result. -/
inductive BlockKind where
  | text                 -- 12,862  {type, text}
  | toolUse              -- 16,210  {type, name, input} — NO id, NO result
  | unrecognized (label : String)
  deriving Repr, DecidableEq

def disposition : RecordKind → Disposition
  | .message =>
      .mapped "role-indexed userMsg/assistantMsg — Time.absent, entry identity synthesized; tool_use blocks become toolCall with globally unique local ids; no toolResult exists"
  | .turnEnded =>
      .mapped "Payload.event (.custom \"cursor_agent.turn_ended\" raw) — exact native record retained and re-exported"
  | .turnEndedError =>
      .mapped "Payload.event (.custom \"cursor_agent.turn_ended\" raw) — turn-level error string retained exactly without fabricating a tool result"
  | .unrecognized _ => .unverified

/-- Expressiveness row (census-resolved). -/
def supports : Concept → Support
  | .identity        => .absent  -- no source ids; caNNNN synthesized
  | .threading       => .approximate "implicit file order only"
  | .time            => .absent  -- no timestamp key on any record (confirmed)
  | .roles           => .native  -- assistant / user
  | .textContent     => .native
  | .thinkingContent => .absent  -- RESOLVED (was unverified): no thinking/reasoning block exists
  | .toolLifecycle   => .approximate "call-only: tool_use inputs stored, results NEVER stored; synthetic ca-tcNNNN ids"
  | .errorSignaling  => .absent
      -- No tool result/error exists. `turn_ended.error` is retained as a
      -- session metaevent, not misrepresented as tool-level error evidence.
  | .compaction      => .absent
  | .branching       => .absent
  | .sidechains      => .approximate
      "144 subagent child transcripts under `<uuid>/subagents/`; the single-file adapter drops them, but `LoomConvert.CursorAgentSubagents` (D16, resolved 2026-07-08) now stitches them as `sidechain`/`detached` threads. `.approximate` because cursor stores NO child→parent key — anchoring is POSITIONAL (i-th child ↔ i-th spawn call), verified well-formed over the real store"
  | .usage           => .absent
  | .environment     => .approximate
      "session id is recoverable from the native .jsonl filename; no record carries cwd, and the project-directory slug is not injectively decoded"
  | .metaEvents      => .native  -- turn_ended success/error records are retained and re-exported exactly
  | .media           => .absent

def claims : List Claim := [
  { id := "L4-cursor-agent-identity"
    statement :=
      "cursor-agent CLI transcripts carry no per-entry identity, so \
       same-format round-trip cannot preserve ids; equivalence is only \
       definable at the content level."
    status := .confirmed
      ("cursorAgentAdapter synthesizes caNNNN/ca-tcNNNN ids; header id is \
        recovered from the filename by the path-aware importer. Census: no uuid/id key on any of the 3 \
        record shapes. The cursor-render-equivalence tests are content-level \
        for exactly this reason.") },
  { id := "L9-cursor-agent-kinds"
    statement :=
      "The cursor-agent CLI writes exactly three top-level record shapes: \
       `message` (role + content of text/tool_use blocks) and two \
       `turn_ended` metaevent variants (success, error). Tool results are \
       never stored."
    status := .confirmed
      ("2026-07-06 census over 427 files: 14,859 message, 2 turn_ended, 2 \
        turn_ended+error; content blocks only text (12,862) + tool_use \
        (16,210, no id/result); zero thinking, zero tool_result. Resolves \
        the earlier tentative inventory.") }
]

end Loom.Formats.CursorAgent
