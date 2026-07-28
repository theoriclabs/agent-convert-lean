import Loom.Concepts

/-!
# Format — Hermes

Not JSONL: a **single JSON object per session** (`fileShape` singleJson),
which is why the live-follow tooling excludes Hermes
(`followAdapter.ts:16-18`) — there is no append-only line stream to tail.

Structure (census-confirmed): top-level keys `session_id, model, base_url,
platform, session_start, last_updated, system_prompt, tools, message_count,
messages`. `message_count` is accurate. Messages have roles user / assistant
/ tool; **no per-message timestamp** (importers interpolate from
session-level start/end, `hermes.ts:210-212`). Assistant tool calls carry
`tool_calls[]` with `function.{name, arguments}` where `arguments` is a
JSON-encoded string.

Evidence base: `utils/src/pi/hermes.ts` + a census of the local corpus —
**8 session files / 462 messages**, censused 2026-07-06.
-/

namespace Loom.Formats.Hermes

/-- CORRECTED storage: source path is defined in `hermes.ts`, not
`sessionPaths.ts` (which only resolves the pi output dir). -/
def storage : String := "~/.hermes/sessions/session_<YYYYMMDD>_<HHMMSS>_<hex>.json (hermes.ts:347-349)"

def fileShape : FileShape := .singleJsonMutating

/-- Message roles (census counts). -/
inductive MessageRole where
  | user       -- 8
  | assistant  -- 223
  | tool       -- 231  (tool RESULT carrier: role, name, content, tool_call_id)
  | unrecognized (label : String)
  deriving Repr, DecidableEq

def disposition : MessageRole → Disposition
  | .user =>
      .mapped "Payload.message role user, single text block; empty→skip"
  | .assistant =>
      .mapped "Payload.message; blocks reasoning→text→toolCall; reasoning/reasoning_content whitespace-only across corpus so ZERO thinking blocks imported; tool_calls[] → Block.toolCall (arguments JSON-parsed)"
  | .tool =>
      .mapped "Payload.message role toolResult; content text block; isError:false HARDCODED (hermes.ts:298) — but no error field exists to read (claim L3)"
  | .unrecognized _ => .unverified

/-- CORRECTED Hermes-native tool names → canonical vocabulary
(`hermes.ts:60-65`). The earlier spec's `edit_file→edit` was wrong;
`edit_file` occurs nowhere in the corpus. Many called tools (patch, browser_*,
kanban_*, and a tool literally named `edit`) are UNMAPPED and pass through. -/
def toolNameMap : List (String × CanonicalTool) := [
  ("terminal",     .bash),
  ("read_file",    .read),
  ("write_file",   .write),
  ("search_files", .grep)
]

/-- Expressiveness row. -/
def supports : Concept → Support
  | .identity        => .approximate "session id present; per-message fallback ids (phase-7 deferral)"
  | .threading       => .approximate "array order in a single JSON object"
  | .time            => .approximate
      "session-level start/end only; per-message times interpolated on import (hermes.ts:210-212)"
  | .roles           => .native
  | .textContent     => .native
  | .thinkingContent => .absent
      -- RESOLVED (was unverified): reasoning/reasoning_content keys exist but
      -- are null/whitespace across the whole corpus; zero thinking imported.
  | .toolLifecycle   => .approximate "tool names remapped (see toolNameMap); many tools unmapped, pass through"
  | .errorSignaling  => .absent  -- confirmed: no error field exists (claim L3)
  | .compaction      => .absent
  | .branching       => .absent
  | .sidechains      => .absent  -- a `delegate_task` tool is declared, but no sidechain structure in the store
  | .usage           => .absent
      -- RESOLVED (was unverified): no token/usage/cost key exists anywhere.
  | .environment     => .approximate "model/base_url/platform preserved via hermesExtras"
  | .metaEvents      => .absent
  | .media           => .absent  -- browser_* tools exist but no media content blocks in the corpus

def claims : List Claim := [
  { id := "L3-hermes-error-unrecorded"
    statement :=
      "The Hermes session format records no per-tool error status; success \
       cannot be distinguished from failure from the file alone. The \
       adapter's hardcoded isError:false is not masking a field — there is \
       none."
    status := .confirmed
      ("2026-07-06 census over 8 files: recursive key scan found no \
        error/is_error/exit_code/status result field; the sole `status` hit \
        is a JSON-Schema enum inside the todo tool's parameter definition, \
        not a result field. UPGRADED from tentative — L3 is now settled.") },
  { id := "L18-hermes-toolmap-and-usage"
    statement :=
      "Hermes maps exactly terminal→bash, read_file→read, write_file→write, \
       search_files→grep; all other tools (incl. the actual file-editor \
       `patch` and a tool named `edit`) pass through unmapped. The format \
       carries no usage/token data."
    status := .confirmed
      ("census: 18 distinct called tool names, only those 4 mapped \
        (hermes.ts:60-65); `edit_file` never occurs; no token/cost key \
        anywhere. Corrects the earlier toolNameMap (edit_file→edit) and the \
        `usage=unverified` cell.") }
]

end Loom.Formats.Hermes
