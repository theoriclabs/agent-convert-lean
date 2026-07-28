import Loom.Concepts

/-!
# Format — Codex CLI

Linear by construction. Sessions live under
`~/.codex/sessions/YYYY/MM/DD/rollout-<ISO8601>-<uuidv7>.jsonl`; line 0 is a
`session_meta` record, then a stream of `response_item` / `event_msg` /
`turn_context` / `compacted` records.

The format's defining quirk is **duality**: user/agent utterances are
emitted twice — once as a `response_item.message` and once as an `event_msg`
— but the ordering is **role-asymmetric** (user: response_item→event_msg;
assistant: event_msg→response_item), which breaks the adapter's dedup for
assistant turns (see claim L2 and defect D13). Tool failures carry no
structured flag; error status is *inferred* from output text.

Evidence base: `utils/src/pi/codexAdapter.ts` + a full census of the local
corpus — **425 files, cli_version 0.84.0–0.142.4, ~700k records**, censused
2026-07-06. The schema is a moving target across that version range
(`base_instructions` shifted string→`{text}`; `source`, `window_id`
polymorphic), so any model needs version-tolerant optional fields.
-/

namespace Loom.Formats.CodexCli

def storage : String :=
  "~/.codex/sessions/YYYY/MM/DD/rollout-<ISO8601>-<uuidv7>.jsonl (+ archived_sessions/; session_index.jsonl and history.jsonl are separate, not transcripts)"

def fileShape : FileShape := .jsonlAppend

/-- Top-level record kinds (census counts). `token_count` is NOT here — it
is an `event_msg` subtype (a correction from the earlier draft). -/
inductive RecordKind where
  | sessionMeta    -- 471 (> 425 files: 23 files concatenate multiple sessions/forks)
  | responseItem   -- 427,484
  | eventMsg       -- 259,053
  | turnContext    -- 17,885
  | compacted      -- 882 (paired 1:1 with event_msg.context_compacted)
  | unrecognized (label : String)
  deriving Repr, DecidableEq

/-- `response_item.payload.type` — 9 observed. The last three are unhandled
by the piview adapter. -/
inductive ResponseItemKind where
  | message              -- 72,927  (roles: assistant, user, AND developer/2,508)
  | functionCall         -- 128,559
  | functionCallOutput   -- 128,546
  | reasoning            -- 68,951  (~98% empty summary + encrypted_content only)
  | customToolCall       -- 13,782
  | customToolCallOutput -- 13,782
  | webSearchCall        -- 857  (unhandled → invisible)
  | toolSearchCall       -- 40   (unhandled)
  | toolSearchOutput     -- 40   (unhandled)
  | unrecognized (label : String)
  deriving Repr, DecidableEq

/-- `event_msg.payload.type` — 23 observed; only user/agent_message are
mapped, three (task_started/task_complete/token_count) are explicitly
skipped, the rest silently dropped. Content-bearing drops with no
response_item twin (web_search_end, error) are true invisibility. -/
inductive EventMsgKind where
  | tokenCount          -- 110,622 (rich per-turn usage; TS convert importer now projects it, Loom IR still has no usage field)
  | agentMessage        -- 54,573
  | execCommandEnd      -- 29,973
  | taskStarted         -- 15,707
  | taskComplete        -- 15,373
  | userMessage         -- 13,580
  | patchApplyEnd       -- 13,056
  | contextCompacted    -- 882
  | other (label : String)  -- guardian_assessment, error, web_search_end, turn_aborted, thread_rolled_back, …
  deriving Repr, DecidableEq

def disposition : RecordKind → Disposition
  | .sessionMeta =>
      .mapped "EnvInfo (cwd, cli_version→harnessVersion, base_instructions{text}) + round-trip extras. Adapter reads legacy `instructions` key present in only 12/471 files → instructions empty for ~97% (bug). Only the FIRST meta is read; later forks in the same file are silently merged."
  | .responseItem =>
      .conditional "per payload.type (see ResponseItemKind); message role developer→assistant in piview but →user in convert path (the two directions DISAGREE)"
  | .eventMsg =>
      .conditional "user/agent_message deduped CROSS-CHANNEL + channel-guarded (dropped only when it repeats the previous entry from the OTHER channel: response_item↔event_msg) — works BOTH directions since the D13 fix (codexAdapter.ts); all other subtypes dropped"
  | .turnContext => .droppedDeliberately "per-turn config; candidate for MetaEvent.custom"
  | .compacted =>
      .conditional "piview adapter ignores it entirely (compaction invisible); convert path default splices replacement_history as synthetic entries, --keep-pre-compaction-history maps each to a branch_summary; raw events preserved in codexExtras for round-trip"
  | .unrecognized _ => .unverified

/-- Expressiveness row. -/
def supports : Concept → Support
  | .identity        => .approximate
      "payload.id absent ~97%; importer always synthesizes cdxNNNN even when present"
  | .threading       => .approximate
      "linear per segment, but one file may concatenate multiple sessions/forks (23/425); parent_thread_id/forked_from_id in session_meta record real lineage the linear read flattens"
  | .time            => .native  -- per-record RFC3339 timestamp
  | .roles           => .approximate "third role `developer` (2,508) mapped inconsistently across the two adapters"
  | .textContent     => .approximate
      "duality: each utterance on two channels; deduped cross-channel + channel-guarded in BOTH directions since the D13 fix. Still approximate because the pairing is heuristic — L2 records genuine adjacent-identical user pairs a broader text-equality dedup would wrongly collapse (the channel guard avoids that)"
  | .thinkingContent => .approximate
      "reasoning items exist but ~98% are empty-summary + encrypted_content; dropped unless --keep-encrypted-reasoning (was optimistically `native`)"
  | .toolLifecycle   => .native  -- function_call/function_call_output + custom_tool_call with call_ids
  | .errorSignaling  => .approximate
      "no structured flag; inferred from output text (codexOutputIndicatesError, codexAdapter.ts:75)"
  | .compaction      => .native
      -- CORRECTED (was approximate 'extent unrecorded'): `compacted`
      -- carries full replacement_history; the piview adapter just drops it.
  | .branching       => .approximate
      "not in the linear stream, but forked_from_id/parent_thread_id in session_meta record forks/subagent spawns the linear read flattens (was `absent`)"
  | .sidechains      => .approximate
      "subagent lineage recorded in session_meta.source.subagent.thread_spawn {parent_thread_id, depth, agent_path} and across files (was `absent`); not reconstructed by the linear adapter"
  | .usage           => .approximate
      "event_msg.token_count carries per-turn total_/last_token_usage. The TS convert importer now projects last_token_usage into pi message.usage and keeps rawTokenCountEvents in codexExtras; the parseSession adapter and Loom IR/default path still do not model usage, so real usage provenance is a scoped non-claim there."
  | .environment     => .native  -- session_meta: cwd, cli_version, git, originator
  | .metaEvents      => .native  -- turn_context + 23 event_msg subtypes
  | .media           => .approximate
      "input_image content blocks (16) exist; dropped by the text-only extractor (an image-only message yields zero blocks → skipped)"

def claims : List Claim := [
  { id := "L2-codex-dedup"
    statement :=
      "REFUTED AS STATED. The premise 'adjacent identical text+role are the \
       same utterance serialized twice, never two genuine messages' is \
       false, and the adapter's dedup is one-directional."
    status := .confirmed
      ("2026-07-06 census refuted the naive premise (dedup is role- \
        asymmetric; 832 adjacent-identical genuine user pairs exist, one >1h \
        apart) AND found the adapter DOUBLE-EMITTED assistant turns 53,917× \
        (defect D13). FIXED same day: codexAdapter.ts dedup made \
        cross-channel + channel-guarded — a text utterance is dropped only \
        when it repeats the previous entry from the OTHER channel \
        (response_item↔event_msg), which fixes the assistant direction while \
        preserving single-channel event_msgs and same-channel user repeats \
        (+10 genuine utterances rescued). Regression test \
        codexAdapter.d13-dedup.test.mjs (4 cases); full suite 469/469. The \
        correct dedup key is channel-pairing, never text equality.") },
  { id := "L16-codex-usage-discarded"
    statement :=
      "Codex records rich per-turn usage (event_msg.token_count with \
       last_token_usage/total_token_usage). The TS convert importer now \
       projects it into pi usage, but the parseSession adapter and Loom IR \
       still do not model it."
    status := .confirmed
      ("census: 110,622 token_count records. PARTIAL 2026-07-08: \
        src/pi/codex.ts captures rawTokenCountEvents and projects \
        last_token_usage onto assistant-authored pi messages. Remaining \
        non-claim: codexAdapter.ts still skips token_count and Loom IR/Pi \
        export has no usage field, so default Loom conversion cannot claim \
        real Codex usage provenance.") }
]

end Loom.Formats.CodexCli
