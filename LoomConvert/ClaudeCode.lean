import Loom
import LoomConvert.Parity
import LoomOps.Conversion

/-!
# LoomConvert.ClaudeCode — the Claude Code importer

Claude Code JSONL → Loom IR, in pure Lean. Second vertical after
`LoomConvert.Pi`; copies that scaffold (the `ostr`/`oobj` Json helpers, the
two-pass id→index parent resolution, the `RawEntry`/`Proto` pattern,
`Origin`/`rawId` provenance, `Except` plumbing) and specializes it to Claude's
shape.

Source of truth for the mapping is `Loom.Formats.ClaudeCode` (the census-grounded
disposition table) and the reference oracle `src/pi/claudeAdapter.ts`.

## Mapping (native LineKind → Loom IR), per the disposition table

* `user` envelope line
    * string `content`               → `Payload.userMsg [UserBlock.text]`, unless
      it is a known whole-string synthetic control envelope; controls are
      archived outside conversation with readable import judgments and exact
      raw wrappers in transcript `Origin.extras`
    * `content[].type = "text"`      → the same conservative text/control path
    * `content[].type = "tool_result"` → `Payload.envMsg
        [EnvBlock.toolResult]` (authorship re-attributed; logged `roleCoerced`);
        `is_error` → `ErrorSignal.native`; `tool_use_id` → positional
        `CallRef` to the spawning call.
* `assistant` envelope line          → `Payload.assistantMsg [AssistantBlock…]`
    * `text`     → `AssistantBlock.text`
    * `thinking` → `AssistantBlock.thinking` (carries the provider `signature`)
    * `tool_use` → `AssistantBlock.toolCall` (raw name preserved verbatim)
* `user.isCompactSummary:true` plus its paired
  `system.subtype:compact_boundary` → one `Payload.compaction`; both complete
  source records remain in format-scoped entry provenance. Pairing accepts the
  classic `parentUuid → boundary` link, or Claude 2.1.220+'s adjacent form where
  the boundary sits immediately before the summary while `parentUuid` still
  names the prior conversational node (the boundary is the effective soft cut).
* `last-prompt.leafUuid` is the authoritative resume pointer. It may address a
  non-conversational graph node such as an attachment; the ancestry walk crosses
  that node and retains the conversational ancestors.
* explicit envelope/message role mismatches and system/developer records are
  never dialogue. Active-path instances are archived byte-exactly in transcript
  provenance with an import judgment.

Semantic graph records are identity-checked before traversal. Ordinary inert
controls do not participate in UUID uniqueness or leaf selection unless an
authoritative pointer or selected parent requires that exact occurrence as a
graph bridge. Duplicate or missing semantic UUIDs and malformed semantic parent
fields are refused; kept entries are then chained in active-path order so their
positional parents are always well formed.

## Scope of this slice (honest, graduated)

ACTIVE-THREAD reconstruction, extending the TS oracle `importClaudeCodeToPi`
(`claudeCode.ts:583-610`) with Claude's recorded resume pointer. We use the last
validated `last-prompt.leafUuid` when present; otherwise we log an
`activeLeafGuessed` judgment and pick the newest **non-sidechain** leaf. We walk
`parentUuid` to root through the full line graph, keep the semantic records, and
chain them sequentially. RC2 burn-in: 26/32 real top-level sessions agree with
TS at the `normalize` skeleton; the rest diverge only where Loom is deliberately
richer (below) — plus two the differ mis-scored (its noise filter eats pi lines
whose *text* contains the substring "Replayed"; an importer-external harness bug).

Resolved (were deferred; now covered by the leaf-walk + the unique-id pass):
* branching — the walk keeps only the active leaf's ancestry; abandoned edit
  branches are dropped, exactly as the TS oracle does.
* sidechains — a subagent's `isSidechain` lines fork off the main thread, so the
  non-sidechain-leaf walk never traverses them; they're excluded from the main
  thread (importing them as their OWN `Thread` is still future work).
* forward references — the walk is causal (child→parent), so entry order is
  root→leaf regardless of byte order, and sequential chaining stays in normal form.
* multi-entry lines — a `user` line with several blocks expands to several
  entries; a unique-`rawId` pass (`uuid#k`) stops the pi/claude exporters
  collapsing their ids, and sequential chaining re-links them like TS's fresh ids.

Deliberately RICHER than the TS oracle (adjudicated leanCore wins, NOT defects —
they make a `normalize` cross-parity pin correctly fail; see the S5+S6 section):
* exactly reconstructable `image` blocks → `.media` (census S5); additive or
  unfamiliar image shapes and unknown block kinds → `.unmodeled` (census S6,
  e.g. Claude's `fallback` block). Both paths preserve the source where the TS
  importer drops it. A line whose *sole* block is such a kind therefore yields
  one extra Loom entry.

Still deferred:
* sidechains as their own `Thread` — subagent transcripts are excluded from the
  main thread (for parity), not yet imported as sibling threads.
* attachment payloads and non-path control kinds are not promoted into Loom
  entries; attachment graph nodes are still traversed for resume topology.
* sub-millisecond or non-UTC timestamp spellings remain verbatim only in
  `Origin.extras`; UTC seconds/milliseconds are also lifted to `Time.recorded`.
-/

namespace LoomConvert
open Loom
open Lean (Json)

/-! ## Small Json accessors (Except → Option), distinct from Pi's privates. -/

private def cstr (j : Json) (k : String) : Option String :=
  (j.getObjVal? k >>= Json.getStr?).toOption

private def cobj (j : Json) (k : String) : Option Json :=
  (j.getObjVal? k).toOption

private def carr (j : Json) (k : String) : Option (Array Json) :=
  (j.getObjVal? k >>= Json.getArr?).toOption

private def cbool (j : Json) (k : String) : Bool :=
  ((j.getObjVal? k >>= Json.getBool?).toOption).getD false

private def cbool? (j : Json) (k : String) : Option Bool :=
  (j.getObjVal? k >>= Json.getBool?).toOption

private def cClaudeHexDigit (char : Char) : Bool :=
  ('0' <= char && char <= '9') || ('a' <= char && char <= 'f') ||
    ('A' <= char && char <= 'F')

/-- Claude Code 2.1.214 validates persisted graph and resume identities as
UUIDs. Accept the canonical five-group spelling, case-insensitively. -/
def claudeUuidValid (value : String) : Bool :=
  match value.splitOn "-" with
  | [a, b, c, d, e] =>
      a.length == 8 && b.length == 4 && c.length == 4 && d.length == 4 &&
        e.length == 12 && [a, b, c, d, e].all (fun part =>
          part.toList.all cClaudeHexDigit)
  | _ => false

/-- A deterministic custom UUIDv8 for generated Claude entry identities. Two
independently salted stable hashes bind the candidate to the target session and
counter; the transcript allocator still collision-probes every candidate
against all explicit and generated IDs. -/
private def cGeneratedClaudeUuid (scopeKey : String) (counter : Nat) : String :=
  let material := scopeKey ++ "|" ++ toString counter
  let upper := (String.hash ("agent-convert.claude.uuid.a|" ++ material)).toNat
  let lower := (String.hash ("agent-convert.claude.uuid.b|" ++ material)).toNat
  let packed := upper * (2 ^ 64) + lower
  let raw := (Nat.toDigits 16 packed).reverse.take 30 |>.reverse
  let digits := List.replicate (30 - raw.length) '0' ++ raw
  String.ofList (digits.take 8) ++ "-" ++
    String.ofList ((digits.drop 8).take 4) ++ "-8" ++
    String.ofList ((digits.drop 12).take 3) ++ "-8" ++
    String.ofList ((digits.drop 15).take 3) ++ "-" ++
    String.ofList ((digits.drop 18).take 12)

private partial def cFreshGeneratedClaudeUuid
    (scopeKey : String) (reserved used : List String)
    (counter : Nat) : String × Nat :=
  let candidate := cGeneratedClaudeUuid scopeKey counter
  if reserved.contains candidate || used.contains candidate then
    cFreshGeneratedClaudeUuid scopeKey reserved used (counter + 1)
  else (candidate, counter + 1)

/-! ## Claude synthetic-user control envelopes

Claude serializes several harness events as user text wrapped in XML-like tags.
They are not user-authored prose, but they also are not tool results: notably,
most task notifications already have a native `tool_result` elsewhere in the
thread. Normalize only complete, census-observed wrapper shapes and keep every
field as labeled text. Any prefix, suffix, missing/reordered field, or unknown
shape falls through byte-for-byte as ordinary user text. -/

/-- A recognized synthetic-user wrapper and its readable rendering. `raw` is
carried into the resulting entry's format-scoped provenance. -/
private structure ClaudeControlEnvelope where
  kind     : String
  rendered : String
  raw      : String

private structure ClaudeTaskUsage where
  subagentTokens : String
  toolUses       : String
  durationMs     : String

/-- Strip one exact prefix and suffix. This is deliberately anchored at both
ends; it is not a general XML parser. -/
private def cUnwrapExact? (s opener closer : String) : Option String := do
  let rest ← s.dropPrefix? opener
  let body := rest.toString
  if body.endsWith closer then
    some (body.dropEnd closer.length).toString
  else
    none

/-- Consume exactly one `<tag>value</tag>` from the front, returning the value
and untouched suffix. More than one closing delimiter is rejected, which keeps
the recognizer conservative on code samples containing control-tag text. -/
private def cTakeTag? (s tag : String) : Option (String × String) := do
  let rest ← s.dropPrefix? s!"<{tag}>"
  match rest.toString.splitOn s!"</{tag}>" with
  | [value, tail] => some (value, tail)
  | _ => none

/-- `cTakeTag?`, additionally requiring the observed newline before the next
field. -/
private def cTakeTagLine? (s tag : String) : Option (String × String) := do
  let (value, tail) ← cTakeTag? s tag
  let rest ← tail.dropPrefix? "\n"
  some (value, rest.toString)

private def cField (label value : String) : String := s!"{label}: {value}"

private def cRenderTask
    (taskId : String) (toolUseId outputFile status : Option String)
    (summary : String) (note result : Option String)
    (usage : Option ClaudeTaskUsage) : String :=
  let fields :=
    [cField "Task ID" taskId]
    ++ (match toolUseId with | some x => [cField "Tool use ID" x] | none => [])
    ++ (match outputFile with | some x => [cField "Output file" x] | none => [])
    ++ (match status with | some x => [cField "Status" x] | none => [])
    ++ [cField "Summary" summary]
    ++ (match note with | some x => [cField "Note" x] | none => [])
    ++ (match result with | some x => [cField "Result" x] | none => [])
    ++ (match usage with
        | some u => ["Usage:", cField "  Subagent tokens" u.subagentTokens,
                     cField "  Tool uses" u.toolUses,
                     cField "  Duration (ms)" u.durationMs]
        | none => [])
  String.intercalate "\n" ("Task notification" :: fields)

private def cParseTaskUsage? (s : String) : Option ClaudeTaskUsage := do
  let (tokens, rest) ← cTakeTag? s "subagent_tokens"
  let (uses, rest) ← cTakeTag? rest "tool_uses"
  let (duration, rest) ← cTakeTag? rest "duration_ms"
  if rest.isEmpty then
    some { subagentTokens := tokens, toolUses := uses, durationMs := duration }
  else
    none

private def cNormalizeCommand? (s : String) : Option ClaudeControlEnvelope := do
  let (name, rest) ← cTakeTag? s "command-name"
  let (message, rest) ← cTakeTag? rest.trimAscii.toString "command-message"
  let (args, rest) ← cTakeTag? rest.trimAscii.toString "command-args"
  if rest.trimAscii.isEmpty && !message.isEmpty && name == "/" ++ message then
    some {
      kind := "command"
      rendered := String.intercalate "\n"
        ["Command", cField "Name" name, cField "Message" message,
         cField "Arguments" args]
      raw := s }
  else
    none

private def cNormalizeTask? (s : String) : Option ClaudeControlEnvelope := do
  let body ← cUnwrapExact? s "<task-notification>\n" "\n</task-notification>"
  let (taskId, rest) ← cTakeTagLine? body "task-id"
  -- Event notifications have a distinct exact field sequence and a fixed
  -- untagged instruction after `<event>`.
  if rest.startsWith "<summary>" then
    let (summary, rest) ← cTakeTagLine? rest "summary"
    let (event, instruction) ← cTakeTagLine? rest "event"
    let expectedInstruction :=
      "If this event is something the user would act on now, send a PushNotification. " ++
      "Routine or benign output doesn't need one."
    if instruction == expectedInstruction then
      some {
        kind := "task-notification-event"
        rendered := String.intercalate "\n"
          ["Task notification", cField "Task ID" taskId,
           cField "Summary" summary, cField "Event" event,
           cField "Instruction" instruction]
        raw := s }
    else
      none
  else
    let toolAndRest : Option (Option String × String) :=
      if rest.startsWith "<tool-use-id>" then
        (cTakeTagLine? rest "tool-use-id").map (fun (value, tail) => (some value, tail))
      else
        some (none, rest)
    let (toolUseId, rest) ← toolAndRest
    let (outputFile, rest) ← cTakeTagLine? rest "output-file"
    let (status, rest) ← cTakeTagLine? rest "status"
    let (summary, tail) ← cTakeTag? rest "summary"
    if tail.isEmpty then
      some {
        kind := "task-notification-compact"
        rendered := cRenderTask taskId toolUseId (some outputFile) (some status)
          summary none none none
        raw := s }
    else
      let rest ← tail.dropPrefix? "\n"
      let noteAndRest : Option (Option String × String) :=
        if rest.startsWith "<note>" then
          (cTakeTagLine? rest.toString "note").map (fun (value, tail) => (some value, tail))
        else
          some (none, rest.toString)
      let (note, rest) ← noteAndRest
      let (result, rest) ← cTakeTagLine? rest "result"
      let usageBody ← cUnwrapExact? rest "<usage>" "</usage>"
      let usage ← cParseTaskUsage? usageBody
      some {
        kind := "task-notification-detailed"
        rendered := cRenderTask taskId toolUseId (some outputFile) (some status)
          summary note (some result) (some usage)
        raw := s }

private def cNormalizeSingleton?
    (s kind label opener closer : String) : Option ClaudeControlEnvelope := do
  let body ← cUnwrapExact? s opener closer
  some { kind := kind, rendered := s!"{label}:\n{body.trimAscii}", raw := s }

private def cNormalizeBashOutput? (s : String) : Option ClaudeControlEnvelope := do
  let (stdout, rest) ← cTakeTag? s "bash-stdout"
  let (stderr, rest) ← cTakeTag? rest "bash-stderr"
  if rest.isEmpty then
    let stdout :=
      match cUnwrapExact? stdout "<persisted-output>\n" "\n</persisted-output>" with
      | some persisted => s!"Persisted output:\n{persisted}"
      | none => stdout
    some {
      kind := "bash-output"
      rendered := s!"Bash stdout:\n{stdout}\nBash stderr:\n{stderr}"
      raw := s }
  else
    none

/-- Recognize only complete census-observed Claude control wrappers. `none`
means the caller must retain `s` byte-for-byte as ordinary user content. -/
private def normalizeClaudeControlEnvelope? (s : String) : Option ClaudeControlEnvelope :=
  match cNormalizeCommand? s with
  | some x => some x
  | none => match cNormalizeTask? s with
    | some x => some x
    | none => match cNormalizeSingleton? s "system-reminder" "System reminder"
        "<system-reminder>" "</system-reminder>" with
      | some x => some x
      | none => match cNormalizeSingleton? s "local-command-caveat" "Local command caveat"
          "<local-command-caveat>" "</local-command-caveat>" with
        | some x => some x
        | none => match cNormalizeSingleton? s "local-command-stdout" "Local command stdout"
            "<local-command-stdout>" "</local-command-stdout>" with
          | some x => some x
          | none => match cNormalizeSingleton? s "bash-input" "Bash input"
              "<bash-input>" "</bash-input>" with
            | some x => some x
            | none => match cNormalizeBashOutput? s with
              | some x => some x
              | none => match cNormalizeSingleton? s "ide-opened-file" "IDE opened file"
                  "<ide_opened_file>" "</ide_opened_file>" with
                | some x => some x
                | none => cNormalizeSingleton? s "ide-selection" "IDE selection"
                    "<ide_selection>" "</ide_selection>"

/-- Lossless locator for a native Claude base64 image source. The IR has only a
single media-locator field, so a data URI is the smallest reversible encoding of
`source.media_type` plus `source.data`. -/
private def cBase64ImageLocator (mime data : String) : String :=
  s!"data:{mime};base64,{data}"

/-- Decode an image natively only when the complete block is exactly one of the
shapes this exporter can reconstruct. Additive or unfamiliar fields stay in an
open-world block instead of disappearing during the media projection. -/
private def cExactImageRef? (b : Json) : Option (String × String) := do
  let src ← cobj b "source"
  match cstr src "type" with
  | some "base64" =>
      let mime ← cstr src "media_type"
      let data ← cstr src "data"
      let expectedSource := Json.mkObj [
        ("type", Json.str "base64"), ("media_type", Json.str mime),
        ("data", Json.str data)]
      let expectedBlock := Json.mkObj [
        ("type", Json.str "image"), ("source", expectedSource)]
      guard (mime.startsWith "image/" && !data.isEmpty)
      guard (b == expectedBlock)
      pure (mime, cBase64ImageLocator mime data)
  | some "url" =>
      let url ← cstr src "url"
      let expectedSource := Json.mkObj [
        ("type", Json.str "url"), ("url", Json.str url)]
      let expectedBlock := Json.mkObj [
        ("type", Json.str "image"), ("source", expectedSource)]
      guard (b == expectedBlock)
      pure ("image", url)
  | some "file" =>
      let fileId ← cstr src "file_id"
      let expectedSource := Json.mkObj [
        ("type", Json.str "file"), ("file_id", Json.str fileId)]
      let expectedBlock := Json.mkObj [
        ("type", Json.str "image"), ("source", expectedSource)]
      guard (b == expectedBlock)
      pure ("image", "claude-file:" ++ fileId)
  | _ => none

/-! ## Reversible historical carriers

Carrier-looking text is inert unless its exact content-block index is listed in
the exporter-stamped top-level marker and its encoded occurrence agrees with the
containing semantic entry/block. The marker self-identifies this format; it is
not authentication and does not establish that the record is trustworthy. An
attacker able to forge the complete marker, index, occurrence, and IDs reaches
the historical-data representation, but `carrierBlocks` permanently prevents
that representation from exporting as native executable state. Everything
outside that exact collision boundary remains ordinary or unmodeled inert data. -/

def claudeCarrierMarkerKey : String := "_agent_convert"

def claudeCarrierProtocol : String := "agent-convert.claude-carriers.v1"

private def claudeCarrierBlocksExtrasKey : String := "claudeCarrierBlocks"

def claudeHistoricalToolCallCarrierHeader : String :=
  "[Historical tool call from source transcript; not executed by Claude]"

def claudeHistoricalToolResultCarrierHeader : String :=
  "[Historical tool result from source transcript; not executed by Claude]"

def claudeMediaCarrierHeader : String :=
  "[Historical image source from source transcript]"

def claudeUnmodeledAssistantCarrierHeader : String :=
  "[Historical unmodeled assistant block from source transcript]"

def claudeUnmodeledUserCarrierHeader : String :=
  "[Historical unmodeled user block from source transcript]"

def claudeUnmodeledEnvCarrierHeader : String :=
  "[Historical unmodeled environment block from source transcript]"

-- Backward-compatible public names retained for the CLI code that introduced
-- the interrupted-call policy. The representation is now the general v1 call
-- carrier used for every Codex call, open or closed.
def claudeOpenToolCarrierHeader : String := claudeHistoricalToolCallCarrierHeader

def claudeStructuredToolResultCarrierHeader : String :=
  "[Historical structured tool result from source transcript]"

/-! ## Source vs. target environment

Two distinct facts live side by side once a foreign transcript is retargeted to
Claude:

* **Source `EnvInfo`** — the cwd/model/provider/harnessVersion/instructions/
  sessionId (and their *absence*) of the pre-conversion harness. This is source
  provenance. It is never launch policy for the Claude target and must survive a
  round trip byte-for-byte, `none`s included.
* **Target launch identity** — the physical Claude cwd/sessionId/timestamp that a
  resumed Claude session actually runs under. These come only from the caller's
  explicit `origin.extras.target_cwd` / `target_session_id` / `target_timestamp`
  (never by relabelling source `EnvInfo`), and after one hop they are the cwd /
  sessionId physically stamped on the emitted Claude records.

Source `EnvInfo` travels in an inert, versioned transcript-level carrier below.
The carrier is data, not authority: importing it restores source `EnvInfo` but a
forged carrier can never become target policy, because the target cwd/sessionId
are derived from the physical records, not from the carrier. -/

/-- The versioned source-environment carrier id. A carrier that does not
self-identify with this exact string is not decoded. -/
def claudeSourceEnvCarrierId : String := "agent-convert.claude-source-env.v1"

private def claudeSourceEnvRawCarrierExtrasKey : String :=
  "claudeSourceEnvRawCarrier"

/-- The external Claude Code build these emissions are validated against
(installed 2.1.216; the resumable JSONL schema was stable across 2.1.206–2.1.216).
This is an assumption we *report*, not a value we emit: Claude's resumable JSONL
has no grounded target-version slot, so no harness/version string is ever written
into the target records. A source harnessVersion is preserved only as inert
provenance in the source-environment carrier, never conflated with this target. -/
def claudeTargetValidationBuild : String := "2.1.216"

/-- Encode a complete `EnvInfo` as the versioned source-environment payload.
Every field is emitted as string-or-null so absence is explicit and reversible. -/
private def cSourceEnvJson (env : EnvInfo) : Json :=
  let nullable : Option String → Json := fun
    | some value => Json.str value
    | none => Json.null
  Json.mkObj [
    ("carrier", Json.str claudeSourceEnvCarrierId),
    ("cwd", nullable env.cwd),
    ("model", nullable env.model),
    ("provider", nullable env.provider),
    ("harnessVersion", nullable env.harnessVersion),
    ("instructions", nullable env.instructions),
    ("sessionId", nullable env.sessionId)]

private def cOverlayJsonObject (base overlay : Json) : Json :=
  match base, overlay with
  | Json.obj baseFields, Json.obj overlayFields =>
      Json.obj (overlayFields.toList.foldl
        (fun (fields : Std.TreeMap.Raw String Json) (key, value) =>
          fields.insert key value) baseFields)
  | _, Json.obj _ => overlay
  | Json.obj _, _ => base
  | _, _ => overlay

private def cDecodeNullableString (j : Json) (key : String) : Option (Option String) :=
  match j.getObjVal? key with
  | .ok (Json.str value) => some (some value)
  | .ok Json.null => some none
  | _ => none

/-- Decode a source-environment payload. Requires the exact versioned carrier id
and all six `EnvInfo` fields present as string-or-null; a missing field, wrong
type, or foreign carrier id refuses (returns `none`) so malformed carriers cannot
be silently accepted. -/
private def cDecodeSourceEnv? (j : Json) : Option EnvInfo := do
  guard (cstr j "carrier" == some claudeSourceEnvCarrierId)
  let cwd ← cDecodeNullableString j "cwd"
  let model ← cDecodeNullableString j "model"
  let provider ← cDecodeNullableString j "provider"
  let harnessVersion ← cDecodeNullableString j "harnessVersion"
  let instructions ← cDecodeNullableString j "instructions"
  let sessionId ← cDecodeNullableString j "sessionId"
  pure { cwd, model, provider, harnessVersion, instructions, sessionId }

/-- A grounded absolute-path predicate for a Claude target cwd. A resumable
Claude session launches from a concrete working directory, so a relative or empty
value is not a valid launch target. Accepts POSIX absolute paths (`/…`) and, when
a Windows target is intended, drive-absolute (`C:\…` / `C:/…`) and UNC
(`\\server\share`) forms. -/
def claudeAbsoluteTargetCwd (path : String) : Bool :=
  if path.isEmpty then false
  else if path.startsWith "/" then true
  else if path.startsWith "\\\\" then true
  else match path.toList with
    | drive :: ':' :: sep :: _ =>
        (('A' ≤ drive && drive ≤ 'Z') || ('a' ≤ drive && drive ≤ 'z')) &&
          (sep == '/' || sep == '\\')
    | _ => false

/-! ## Target launch identity resolution

The launch identity is resolved by a hard switch, never a source/target merge:

* **Native (physical) target** — a genuine Claude session (Claude-format origin,
  no explicit `target_*` key, no restored source-env carrier). Then the
  transcript `env` cwd/sessionId *are* the physical launch identity.
* **Retargeted target** — anything else (foreign source, any explicit target key,
  or a restored source-env carrier). The launch cwd/session must be supplied
  explicitly via `origin.extras`; source `EnvInfo` is never consulted, and if any
  supported target key is present the *complete* explicit bundle is required. -/

private def cClaudeExtraString? (t : Transcript) (key : String) : Option String :=
  t.origin.extras >>= fun extras => cstr extras key

private def cClaudeExtraNonempty? (t : Transcript) (key : String) : Option String :=
  (cClaudeExtraString? t key).bind (fun value =>
    if value.isEmpty then none else some value)

private def cNonemptyOpt? : Option String → Option String
  | some value => if value.isEmpty then none else some value
  | none => none

/-- The supported Claude target keys. `target_cwd`/`target_session_id`/
`target_timestamp` are the grounded launch identity written into the records;
`target_harness_version` is a non-serialized reader-version assertion consumed in
preflight only. Every other `target_*` key (model/provider/…) has no Claude slot
and is refused. -/
private def cClaudeSupportedTargetKey (key : String) : Bool :=
  ["target_cwd", "target_session_id", "target_timestamp",
    "target_harness_version"].contains key

private def cClaudeUnsupportedTargetKeys (t : Transcript) : List String :=
  match t.origin.extras with
  | some (Json.obj fields) =>
      fields.toList.filterMap (fun (key, _) =>
        if key.startsWith "target_" && !cClaudeSupportedTargetKey key then some key
        else none)
  | _ => []

private def cClaudeHasAnyTargetKey (t : Transcript) : Bool :=
  match t.origin.extras with
  | some (Json.obj fields) =>
      fields.toList.any (fun (key, _) => key.startsWith "target_")
  | none => false
  | some _ => false

private def cClaudeSourceEnvCarrier? (t : Transcript) : Option EnvInfo :=
  t.origin.extras >>= fun extras => cobj extras "source_env" >>= cDecodeSourceEnv?

/-- Native ⟺ genuine Claude session whose `env` is the physical launch identity.
Any explicit target key or a restored source-env carrier marks a retargeted
export whose launch identity comes only from `origin.extras`. -/
private def cClaudeEnvIsPhysicalTarget (t : Transcript) : Bool :=
  t.origin.format == Format.claudeCode && !cClaudeHasAnyTargetKey t &&
    (cClaudeSourceEnvCarrier? t).isNone

private def cClaudeNativeSessionRequested? (t : Transcript) : Option String :=
  (cNonemptyOpt? t.env.sessionId).orElse (fun _ => cNonemptyOpt? t.origin.rawId)

/-- Resolved target launch cwd (raw, pre-validation). Retargeted exports read
`target_cwd` only — source `EnvInfo` is never inferred as a target. -/
private def cClaudeTargetCwd? (t : Transcript) : Option String :=
  if cClaudeEnvIsPhysicalTarget t then cNonemptyOpt? t.env.cwd
  else cClaudeExtraNonempty? t "target_cwd"

private def cClaudeTargetSessionRequested? (t : Transcript) : Option String :=
  if cClaudeEnvIsPhysicalTarget t then cClaudeNativeSessionRequested? t
  else cClaudeExtraNonempty? t "target_session_id"

private def cClaudeTargetSessionId? (t : Transcript) : Option String :=
  (cClaudeTargetSessionRequested? t).bind (fun sessionId =>
    if claudeUuidValid sessionId then some sessionId else none)

private def cClaudeTargetSessionId (t : Transcript) : String :=
  (cClaudeTargetSessionId? t).getD "00000000-0000-5000-8000-000000000000"

private def cClaudeTargetTimestamp? (t : Transcript) : Option String :=
  cClaudeExtraNonempty? t "target_timestamp"

private def cOccurrence (entry block : Nat) : String := s!"{entry}:{block}"

private def cCallRefRawId (t : Transcript) : CallRef → Option String
  | .resolved entry block => do
      let e ← t.entries[entry]?
      match e.payload with
      | .assistantMsg blocks =>
          match blocks[block]? with
          | some (.toolCall _ _ rawId) => rawId
          | _ => none
      | _ => none
  | .unresolved rawId _ => rawId

private def cHistoricalUserBlockJson : UserBlock → Json
  | .text text => Json.mkObj [("kind", Json.str "text"), ("text", Json.str text)]
  | .media mime locator => Json.mkObj [
      ("kind", Json.str "media"), ("mimeType", Json.str mime),
      ("locator", Json.str locator)]
  | .unmodeled label raw => Json.mkObj [
      ("kind", Json.str "unmodeled"), ("label", Json.str label), ("raw", raw)]

private def cParseHistoricalUserBlock? (j : Json) : Option UserBlock := do
  match ← cstr j "kind" with
  | "text" => pure (.text (← cstr j "text"))
  | "media" => pure (.media (← cstr j "mimeType") (← cstr j "locator"))
  | "unmodeled" => pure (.unmodeled (← cstr j "label") (← cobj j "raw"))
  | _ => none

private def cErrorSignalJson : ErrorSignal → Json
  | .native isError => Json.mkObj [
      ("kind", Json.str "native"), ("isError", Json.bool isError)]
  | .inferred isError heuristic => Json.mkObj [
      ("kind", Json.str "inferred"), ("isError", Json.bool isError),
      ("heuristic", Json.str heuristic)]
  | .unrecorded => Json.mkObj [("kind", Json.str "unrecorded")]

private def cParseErrorSignal? (j : Json) : Option ErrorSignal := do
  match ← cstr j "kind" with
  | "native" => pure (.native (← cbool? j "isError"))
  | "inferred" => pure (.inferred (← cbool? j "isError") (← cstr j "heuristic"))
  | "unrecorded" => pure .unrecorded
  | _ => none

private def cCanonicalToolName : CanonicalTool → String
  | .bash => "bash"
  | .read => "read"
  | .write => "write"
  | .edit => "edit"
  | .grep => "grep"
  | .glob => "glob"
  | .webFetch => "webFetch"
  | .webSearch => "webSearch"
  | .agentSpawn => "agentSpawn"
  | .applyPatch => "applyPatch"

private def cParseCanonicalTool? : String → Option CanonicalTool
  | "bash" => some .bash
  | "read" => some .read
  | "write" => some .write
  | "edit" => some .edit
  | "grep" => some .grep
  | "glob" => some .glob
  | "webFetch" => some .webFetch
  | "webSearch" => some .webSearch
  | "agentSpawn" => some .agentSpawn
  | "applyPatch" => some .applyPatch
  | _ => none

private def cParseCanonicalToolField? (j : Json) : Option (Option CanonicalTool) :=
  match cobj j "canonical" with
  | none | some Json.null => some none
  | some (Json.str name) => (cParseCanonicalTool? name).map some
  | some _ => none

private def cHistoricalCallRecord
    (name : ToolName) (args : Json) (rawId occurrence : Option String)
    (reason : String) : Json :=
  Json.mkObj ([
    ("carrier", Json.str "agent-convert.claude-tool-call.v1"),
    ("id", rawId.map Json.str |>.getD Json.null),
    ("name", Json.str name.raw),
    ("canonical", name.canonical.map (Json.str ∘ cCanonicalToolName) |>.getD Json.null),
    ("arguments", args),
    ("reason", Json.str reason)] ++
    (match occurrence with
     | some key => [("occurrence", Json.str key)]
     | none => []))

private def cHistoricalToolCallCarrierText
    (name : ToolName) (args : Json) (rawId occurrence : Option String)
    (reason : String) : String :=
  claudeHistoricalToolCallCarrierHeader ++ "\n" ++
    (cHistoricalCallRecord name args rawId occurrence reason).compress

private def cHistoricalToolCallCarrierTextAt
    (entry block : Nat) (name : ToolName) (args : Json) (rawId : Option String)
    (reason : String := "historical source lifecycle") : String :=
  cHistoricalToolCallCarrierText name args rawId (some (cOccurrence entry block)) reason

def claudeOpenToolCarrierText
    (name : ToolName) (args : Json) (rawId : Option String) : String :=
  cHistoricalToolCallCarrierText name args rawId none
    "source transcript recorded no matching tool result"

private structure ClaudeHistoricalCall where
  block      : AssistantBlock
  occurrence : Option String

private def parseClaudeHistoricalToolCallCarrier? (text : String) : Option ClaudeHistoricalCall := do
  let encoded ← text.dropPrefix? (claudeHistoricalToolCallCarrierHeader ++ "\n")
  let record ← (Json.parse encoded.toString).toOption
  guard (cstr record "carrier" == some "agent-convert.claude-tool-call.v1")
  let name ← cstr record "name"
  let canonical ← cParseCanonicalToolField? record
  let args ← cobj record "arguments"
  pure {
    block := .toolCall { raw := name, canonical } args (cstr record "id"),
    occurrence := cstr record "occurrence" }

private def cCarrierCallRefJson (t : Transcript) : CallRef → Json
  | .resolved entry block => Json.mkObj [
      ("kind", Json.str "resolved"),
      ("occurrence", Json.str (cOccurrence entry block)),
      ("rawId", (cCallRefRawId t (.resolved entry block)).map Json.str |>.getD Json.null)]
  | .unresolved rawId note => Json.mkObj [
      ("kind", Json.str "unresolved"),
      ("rawId", rawId.map Json.str |>.getD Json.null),
      ("note", Json.str note)]

def claudeHistoricalToolResultCarrierText
    (t : Transcript) (entry block : Nat) (call : CallRef)
    (content : List UserBlock) (error : ErrorSignal) : String :=
  let record := Json.mkObj [
    ("carrier", Json.str "agent-convert.claude-tool-result.v1"),
    ("occurrence", Json.str (cOccurrence entry block)),
    ("id", (cCallRefRawId t call).map Json.str |>.getD Json.null),
    ("call", cCarrierCallRefJson t call),
    ("content", Json.arr (content.map cHistoricalUserBlockJson).toArray),
    ("error", cErrorSignalJson error)]
  claudeHistoricalToolResultCarrierHeader ++ "\n" ++ record.compress

private inductive ClaudeHistoricalCallRef where
  | resolved (occurrence : String) (rawId : Option String)
  | unresolved (rawId : Option String) (note : String)

private structure ClaudeHistoricalResult where
  occurrence : String
  call       : ClaudeHistoricalCallRef
  rawId      : Option String
  content    : List UserBlock
  error      : ErrorSignal

private def parseClaudeHistoricalToolResultCarrier?
    (text : String) : Option ClaudeHistoricalResult := do
  let encoded ← text.dropPrefix? (claudeHistoricalToolResultCarrierHeader ++ "\n")
  let record ← (Json.parse encoded.toString).toOption
  guard (cstr record "carrier" == some "agent-convert.claude-tool-result.v1")
  let callJson ← cobj record "call"
  let call ← match cstr callJson "kind" with
    | some "resolved" =>
        some (.resolved (← cstr callJson "occurrence") (cstr callJson "rawId"))
    | some "unresolved" =>
        some (.unresolved (cstr callJson "rawId") (← cstr callJson "note"))
    | _ => none
  let contentJson ← carr record "content"
  let content ← contentJson.toList.mapM cParseHistoricalUserBlock?
  let error ← cobj record "error" >>= cParseErrorSignal?
  pure {
    occurrence := ← cstr record "occurrence"
    call, rawId := cstr record "id", content, error }

private def cProjectedHistoricalOccurrence?
    (oldEntryIndices : List Nat) (occurrence : String) : Option String := do
  let (entryText, blockText) ← match occurrence.splitOn ":" with
    | [entryText, blockText] => some (entryText, blockText)
    | _ => none
  let oldEntry ← entryText.toNat?
  let block ← blockText.toNat?
  let projected ← (oldEntryIndices.zipIdx.find? (fun pair => pair.1 == oldEntry))
    |>.map Prod.snd
  pure (cOccurrence projected block)

private def cPutJsonField (value : Json) (key : String) (field : Json) : Json :=
  match value with
  | Json.obj fields => Json.obj (fields.insert key field)
  | other => other

private def cProjectHistoricalCallCarrierText?
    (oldEntryIndices : List Nat) (text : String) : Option String := do
  let encoded ← text.dropPrefix? (claudeHistoricalToolCallCarrierHeader ++ "\n")
  let record ← (Json.parse encoded.toString).toOption
  guard (cstr record "carrier" == some "agent-convert.claude-tool-call.v1")
  match cstr record "occurrence" with
  | none => pure text
  | some occurrence =>
      let projected ← cProjectedHistoricalOccurrence? oldEntryIndices occurrence
      pure (claudeHistoricalToolCallCarrierHeader ++ "\n" ++
        (cPutJsonField record "occurrence" (Json.str projected)).compress)

private def cProjectHistoricalResultCarrierText?
    (oldEntryIndices : List Nat) (text : String) : Option String := do
  let encoded ← text.dropPrefix? (claudeHistoricalToolResultCarrierHeader ++ "\n")
  let record ← (Json.parse encoded.toString).toOption
  guard (cstr record "carrier" == some "agent-convert.claude-tool-result.v1")
  let ownOccurrence ← cstr record "occurrence"
  let projectedOwn ← cProjectedHistoricalOccurrence? oldEntryIndices ownOccurrence
  let call ← cobj record "call"
  let projectedCall :=
    if cstr call "kind" == some "resolved" then
      match cstr call "occurrence" >>= cProjectedHistoricalOccurrence? oldEntryIndices with
      | some projected => cPutJsonField call "occurrence" (Json.str projected)
      | none => cOverlayJsonObject call (Json.mkObj [
          ("kind", Json.str "unresolved"),
          ("note", Json.str "historical call is outside the projected sidecar")])
    else call
  let projectedRecord := cPutJsonField
    (cPutJsonField record "occurrence" (Json.str projectedOwn)) "call" projectedCall
  pure (claudeHistoricalToolResultCarrierHeader ++ "\n" ++ projectedRecord.compress)

private def cProjectHistoricalCarrierText
    (oldEntryIndices : List Nat) (text : String) : String :=
  (cProjectHistoricalCallCarrierText? oldEntryIndices text).orElse (fun _ =>
    cProjectHistoricalResultCarrierText? oldEntryIndices text) |>.getD text

def claudeMediaCarrierText (mime locator : String) : String :=
  claudeMediaCarrierHeader ++ "\n" ++ (Json.mkObj [
    ("carrier", Json.str "agent-convert.claude-media.v1"),
    ("mimeType", Json.str mime), ("locator", Json.str locator)]).compress

private def parseClaudeMediaCarrier? (text : String) : Option (String × String) := do
  let encoded ← text.dropPrefix? (claudeMediaCarrierHeader ++ "\n")
  let record ← (Json.parse encoded.toString).toOption
  guard (cstr record "carrier" == some "agent-convert.claude-media.v1")
  pure (← cstr record "mimeType", ← cstr record "locator")

private def claudeUnmodeledAssistantCarrierText (label : String) (raw : Json) : String :=
  claudeUnmodeledAssistantCarrierHeader ++ "\n" ++ (Json.mkObj [
    ("carrier", Json.str "agent-convert.claude-assistant-block.v1"),
    ("label", Json.str label), ("raw", raw)]).compress

private def parseClaudeUnmodeledAssistantCarrier?
    (text : String) : Option AssistantBlock := do
  let encoded ← text.dropPrefix? (claudeUnmodeledAssistantCarrierHeader ++ "\n")
  let record ← (Json.parse encoded.toString).toOption
  guard (cstr record "carrier" == some "agent-convert.claude-assistant-block.v1")
  pure (.unmodeled (← cstr record "label") (← cobj record "raw"))

private def cUnmodeledCarrierText
    (header carrier label : String) (raw : Json) : String :=
  header ++ "\n" ++ (Json.mkObj [
    ("carrier", Json.str carrier), ("label", Json.str label), ("raw", raw)]).compress

private def claudeUnmodeledUserCarrierText (label : String) (raw : Json) : String :=
  cUnmodeledCarrierText claudeUnmodeledUserCarrierHeader
    "agent-convert.claude-user-block.v1" label raw

private def claudeUnmodeledEnvCarrierText (label : String) (raw : Json) : String :=
  cUnmodeledCarrierText claudeUnmodeledEnvCarrierHeader
    "agent-convert.claude-env-block.v1" label raw

private def cParseUnmodeledCarrier?
    (header carrier text : String) : Option (String × Json) := do
  let encoded ← text.dropPrefix? (header ++ "\n")
  let record ← (Json.parse encoded.toString).toOption
  guard (cstr record "carrier" == some carrier)
  pure (← cstr record "label", ← cobj record "raw")

private def parseClaudeUnmodeledUserCarrier? (text : String) : Option UserBlock := do
  let (label, raw) ← cParseUnmodeledCarrier? claudeUnmodeledUserCarrierHeader
    "agent-convert.claude-user-block.v1" text
  pure (.unmodeled label raw)

private def parseClaudeUnmodeledEnvCarrier? (text : String) : Option EnvBlock := do
  let (label, raw) ← cParseUnmodeledCarrier? claudeUnmodeledEnvCarrierHeader
    "agent-convert.claude-env-block.v1" text
  pure (.unmodeled label raw)

private def cCompactionCoverageJson : CompactionCoverage → Json
  | .unknownPrefix => Json.mkObj [("kind", Json.str "unknownPrefix")]
  | .knownPrefix firstKept => Json.mkObj [
      ("kind", Json.str "knownPrefix"),
      ("firstKept", Json.num (Lean.JsonNumber.fromNat firstKept))]

private def cParseCompactionCoverage? (j : Json) : Option CompactionCoverage := do
  match ← cstr j "kind" with
  | "unknownPrefix" => pure .unknownPrefix
  | "knownPrefix" =>
      let firstKept ← (j.getObjVal? "firstKept" >>= Json.getNat?).toOption
      pure (.knownPrefix firstKept)
  | _ => none

private structure ClaudeCompactionCarrier where
  summary        : String
  coverage       : CompactionCoverage
  tokensBefore   : Option Nat
  sourceEnvelope : Option Json
  sourceBoundary : Option Json

private def cNonNull : Option Json → Option Json
  | some Json.null => none
  | other => other

private def cTimeProvenanceJson : Time → Option Json
  | .recorded _ => none
  | .interpolated timestamp basis => some (Json.mkObj [
      ("carrier", Json.str "agent-convert.time-provenance.v1"),
      ("kind", Json.str "interpolated"),
      ("ms", Json.num timestamp.ms), ("basis", Json.str basis)])
  | .sequenced ordinal => some (Json.mkObj [
      ("carrier", Json.str "agent-convert.time-provenance.v1"),
      ("kind", Json.str "sequenced"), ("ordinal", Json.num ordinal)])
  | .absent => some (Json.mkObj [
      ("carrier", Json.str "agent-convert.time-provenance.v1"),
      ("kind", Json.str "absent")])

private def cParseTimeProvenance? (j : Json) : Option Time := do
  guard (cstr j "carrier" == some "agent-convert.time-provenance.v1")
  match ← cstr j "kind" with
  | "interpolated" =>
      let ms ← (j.getObjVal? "ms" >>= Json.getNat?).toOption
      pure (.interpolated ⟨ms⟩ (← cstr j "basis"))
  | "sequenced" =>
      pure (.sequenced (← (j.getObjVal? "ordinal" >>= Json.getNat?).toOption))
  | "absent" => pure .absent
  | _ => none

private def cCarrierTimeProvenance? (j : Json) : Option Time := do
  let marker ← cobj j claudeCarrierMarkerKey
  guard (cstr marker "protocol" == some claudeCarrierProtocol)
  cobj marker "timeProvenance" >>= cParseTimeProvenance?

private def cOptionalNat? (j : Json) (key : String) : Option (Option Nat) :=
  match cobj j key with
  | none | some Json.null => some none
  | some value => (value.getNat?).toOption.map some

private def cParseCompactionCarrier? (j : Json) : Option ClaudeCompactionCarrier := do
  guard (cstr j "type" == some "system")
  guard (cstr j "subtype" == some "agent_convert_compaction")
  let marker ← cobj j claudeCarrierMarkerKey
  guard (cstr marker "protocol" == some claudeCarrierProtocol)
  let record ← cobj marker "compaction"
  guard (cstr record "carrier" == some "agent-convert.claude-compaction.v1")
  pure {
    summary := ← cstr record "summary"
    coverage := ← cobj record "coverage" >>= cParseCompactionCoverage?
    tokensBefore := ← cOptionalNat? record "tokensBefore"
    sourceEnvelope := cNonNull (cobj record "sourceEnvelope")
    sourceBoundary := cNonNull (cobj record "sourceBoundary") }

private def cCompactionCarrierMarker
    (summary : String) (coverage : CompactionCoverage) (tokensBefore : Option Nat)
    (sourceEnvelope sourceBoundary : Option Json)
    (identityProvenance : Option Json := none)
    (timeProvenance : Option Json := none) : Json :=
  Json.mkObj ([
    ("protocol", Json.str claudeCarrierProtocol),
    ("compaction", Json.mkObj [
      ("carrier", Json.str "agent-convert.claude-compaction.v1"),
      ("summary", Json.str summary),
      ("coverage", cCompactionCoverageJson coverage),
      ("tokensBefore", tokensBefore.map (fun n =>
        Json.num (Lean.JsonNumber.fromNat n)) |>.getD Json.null),
      ("sourceEnvelope", sourceEnvelope.getD Json.null),
      ("sourceBoundary", sourceBoundary.getD Json.null)])] ++
    (match identityProvenance with
     | some identity => [("identityProvenance", identity)]
     | none => []) ++
    (match timeProvenance with
     | some value => [("timeProvenance", value)]
     | none => []))

private def cNullableStringJson : Option String → Json
  | some value => Json.str value
  | none => Json.null

private def cParseNullableStringField?
    (j : Json) (key : String) : Option (Option String) :=
  match cobj j key with
  | some Json.null => some none
  | some (Json.str value) => some (some value)
  | _ => none

private def cHistoricalAssistantBlockJson : AssistantBlock -> Json
  | .text text => Json.mkObj [("kind", Json.str "text"), ("text", Json.str text)]
  | .thinking thinking signature => Json.mkObj [
      ("kind", Json.str "thinking"), ("thinking", Json.str thinking),
      ("signature", signature.map Json.str |>.getD Json.null)]
  | .toolCall name arguments rawId => Json.mkObj [
      ("kind", Json.str "toolCall"), ("name", Json.str name.raw),
      ("canonical", name.canonical.map (Json.str ∘ cCanonicalToolName)
        |>.getD Json.null),
      ("arguments", arguments), ("rawId", rawId.map Json.str |>.getD Json.null)]
  | .media mime locator => Json.mkObj [
      ("kind", Json.str "media"), ("mimeType", Json.str mime),
      ("locator", Json.str locator)]
  | .unmodeled label raw => Json.mkObj [
      ("kind", Json.str "unmodeled"), ("label", Json.str label), ("raw", raw)]

private def cParseHistoricalAssistantBlock? (j : Json) : Option AssistantBlock := do
  match ← cstr j "kind" with
  | "text" => pure (.text (← cstr j "text"))
  | "thinking" => pure (.thinking (← cstr j "thinking")
      (← cParseNullableStringField? j "signature"))
  | "toolCall" =>
      let canonical ← cParseCanonicalToolField? j
      pure (.toolCall { raw := ← cstr j "name", canonical }
        (← cobj j "arguments") (← cParseNullableStringField? j "rawId"))
  | "media" => pure (.media (← cstr j "mimeType") (← cstr j "locator"))
  | "unmodeled" => pure (.unmodeled (← cstr j "label") (← cobj j "raw"))
  | _ => none

private def cHistoricalDirectCallRefJson : CallRef -> Json
  | .resolved entry block => Json.mkObj [
      ("kind", Json.str "resolved"), ("entry", Json.num entry),
      ("block", Json.num block)]
  | .unresolved rawId note => Json.mkObj [
      ("kind", Json.str "unresolved"),
      ("rawId", rawId.map Json.str |>.getD Json.null), ("note", Json.str note)]

private def cParseHistoricalDirectCallRef? (j : Json) : Option CallRef := do
  match ← cstr j "kind" with
  | "resolved" => pure (.resolved
      (← (j.getObjVal? "entry" >>= Json.getNat?).toOption)
      (← (j.getObjVal? "block" >>= Json.getNat?).toOption))
  | "unresolved" => pure (.unresolved
      (← cParseNullableStringField? j "rawId") (← cstr j "note"))
  | _ => none

private def cHistoricalEnvBlockJson : EnvBlock -> Json
  | .toolResult call content error => Json.mkObj [
      ("kind", Json.str "toolResult"), ("call", cHistoricalDirectCallRefJson call),
      ("content", Json.arr (content.map cHistoricalUserBlockJson).toArray),
      ("error", cErrorSignalJson error)]
  | .unmodeled label raw => Json.mkObj [
      ("kind", Json.str "unmodeled"), ("label", Json.str label), ("raw", raw)]

private def cParseHistoricalEnvBlock? (j : Json) : Option EnvBlock := do
  match ← cstr j "kind" with
  | "toolResult" =>
      let content ← carr j "content"
      pure (.toolResult
        (← cobj j "call" >>= cParseHistoricalDirectCallRef?)
        (← content.toList.mapM cParseHistoricalUserBlock?)
        (← cobj j "error" >>= cParseErrorSignal?))
  | "unmodeled" => pure (.unmodeled (← cstr j "label") (← cobj j "raw"))
  | _ => none

private def cMetaEventJson : MetaEvent → Json
  | .modelChange prev next => Json.mkObj [
      ("kind", Json.str "modelChange"),
      ("prev", cNullableStringJson prev), ("next", cNullableStringJson next)]
  | .thinkingLevelChange prev next => Json.mkObj [
      ("kind", Json.str "thinkingLevelChange"),
      ("prev", cNullableStringJson prev), ("next", cNullableStringJson next)]
  | .permissionMode mode => Json.mkObj [
      ("kind", Json.str "permissionMode"), ("mode", Json.str mode)]
  | .branchSummary summary => Json.mkObj [
      ("kind", Json.str "branchSummary"), ("summary", Json.str summary)]
  | .custom label raw => Json.mkObj [
      ("kind", Json.str "custom"), ("label", Json.str label), ("raw", raw)]

private def cParseMetaEvent? (j : Json) : Option MetaEvent := do
  match ← cstr j "kind" with
  | "modelChange" =>
      pure (.modelChange (← cParseNullableStringField? j "prev")
        (← cParseNullableStringField? j "next"))
  | "thinkingLevelChange" =>
      pure (.thinkingLevelChange (← cParseNullableStringField? j "prev")
        (← cParseNullableStringField? j "next"))
  | "permissionMode" => pure (.permissionMode (← cstr j "mode"))
  | "branchSummary" => pure (.branchSummary (← cstr j "summary"))
  | "custom" => pure (.custom (← cstr j "label") (← cobj j "raw"))
  | _ => none

private def cInertPayloadJson : Payload → Option Json
  | .userMsg blocks => some (Json.mkObj [
      ("kind", Json.str "userMsg"),
      ("blocks", Json.arr (blocks.map cHistoricalUserBlockJson).toArray)])
  | .assistantMsg blocks => some (Json.mkObj [
      ("kind", Json.str "assistantMsg"),
      ("blocks", Json.arr (blocks.map cHistoricalAssistantBlockJson).toArray)])
  | .envMsg blocks => some (Json.mkObj [
      ("kind", Json.str "envMsg"),
      ("blocks", Json.arr (blocks.map cHistoricalEnvBlockJson).toArray)])
  | .otherMsg role blocks => some (Json.mkObj [
      ("kind", Json.str "otherMsg"), ("role", Json.str role),
      ("blocks", Json.arr (blocks.map cHistoricalUserBlockJson).toArray)])
  | .event event => some (Json.mkObj [
      ("kind", Json.str "event"), ("event", cMetaEventJson event)])
  | _ => none

private def cParseInertPayloadJson? (j : Json) : Option Payload := do
  match ← cstr j "kind" with
  | "userMsg" =>
      let blocks ← carr j "blocks"
      pure (.userMsg (← blocks.toList.mapM cParseHistoricalUserBlock?))
  | "assistantMsg" =>
      let blocks ← carr j "blocks"
      pure (.assistantMsg (← blocks.toList.mapM cParseHistoricalAssistantBlock?))
  | "envMsg" =>
      let blocks ← carr j "blocks"
      pure (.envMsg (← blocks.toList.mapM cParseHistoricalEnvBlock?))
  | "otherMsg" =>
      let blocks ← carr j "blocks"
      pure (.otherMsg (← cstr j "role")
        (← blocks.toList.mapM cParseHistoricalUserBlock?))
  | "event" => pure (.event (← cobj j "event" >>= cParseMetaEvent?))
  | _ => none

private def cParseInertPayloadCarrier? (j : Json) : Option Payload := do
  guard (cstr j "type" == some "system")
  guard (cstr j "subtype" == some "agent_convert_inert")
  let marker ← cobj j claudeCarrierMarkerKey
  guard (cstr marker "protocol" == some claudeCarrierProtocol)
  let record ← cobj marker "inertPayload"
  guard (cstr record "carrier" ==
    some "agent-convert.claude-inert-payload.v1")
  cobj record "payload" >>= cParseInertPayloadJson?

/-- The envelope that actually carries an inert payload across the hop.

Its three emission sites write `content: null` rather than prose. They used to
write "Historical inert payload retained by agent-convert; not dialogue", and
Claude Code renders a `system` row's `content` in the transcript — so a Codex
session with 75 unrepresentable meta events (`thread_settings_applied`,
`token_count`, …) arrived as 75 lines of converter bookkeeping interleaved with
the conversation. That is `Interop`'s `P2-provenance-out-of-band` violated by
the exporter that documents it: the payload belongs in this marker, which
survives the round trip, and nowhere a reader will mistake it for dialogue.

Dropping the text costs no fidelity. `cParseInertPayloadCarrier?` restores the
payload from `subtype` plus this marker and never reads `content`, so the record
still returns to its source format intact.

Compaction rows deliberately KEEP their text: there are a handful, not dozens,
and a compaction boundary is real conversation structure that Claude Code models
itself as `compact_boundary`. -/
private def cInertPayloadCarrierMarker
    (payload : Payload) (sourceEnvelope : Option Json)
    (identityProvenance : Option Json := none)
    (timeProvenance : Option Json := none) : Json :=
  let inert := (cInertPayloadJson payload).getD (Json.mkObj [])
  Json.mkObj ([
    ("protocol", Json.str claudeCarrierProtocol),
    ("inertPayload", Json.mkObj [
      ("carrier", Json.str "agent-convert.claude-inert-payload.v1"),
      ("payload", inert)])] ++
    (match sourceEnvelope with
     | some raw => [("provenance", Json.mkObj [
         ("carrier", Json.str "agent-convert.claude-envelope-provenance.v1"),
         ("rawEnvelope", raw)])]
     | none => []) ++
    (match identityProvenance with
     | some identity => [("identityProvenance", identity)]
     | none => []) ++
    (match timeProvenance with
     | some value => [("timeProvenance", value)]
     | none => []))

def claudeStructuredToolResultCarrierText (label : String) (raw : Json) : String :=
  claudeStructuredToolResultCarrierHeader ++ "\n" ++ (Json.mkObj [
    ("carrier", Json.str "agent-convert.tool-result-block.v1"),
    ("label", Json.str label),
    ("raw", raw)]).compress

private def parseClaudeStructuredToolResultCarrier? (text : String) : Option UserBlock := do
  let encoded ← text.dropPrefix? (claudeStructuredToolResultCarrierHeader ++ "\n")
  let record ← (Json.parse encoded.toString).toOption
  guard (cstr record "carrier" == some "agent-convert.tool-result-block.v1")
  let label ← cstr record "label"
  let raw ← cobj record "raw"
  pure (UserBlock.unmodeled label raw)

/-- Preserve Claude's string-or-array tool result content as ordered IR blocks. -/
private def parseToolResultContent
    (carrierMarked : Bool) (content : Option Json) : List UserBlock :=
  match content with
  | some (Json.str s) =>
      [if carrierMarked then
         (parseClaudeStructuredToolResultCarrier? s).getD (UserBlock.text s)
       else UserBlock.text s]
  | some (Json.arr bs) =>
      bs.toList.map (fun (b : Json) =>
        match cstr b "type" with
        | some "text" =>
            let text := (cstr b "text").getD ""
            if carrierMarked then
              (parseClaudeStructuredToolResultCarrier? text).getD (UserBlock.text text)
            else UserBlock.text text
        | some "image" =>
            match cExactImageRef? b with
            | some (mime, loc) => UserBlock.media mime loc
            | none => UserBlock.unmodeled "image" b
        | other => UserBlock.unmodeled (other.getD "tool_result_item") b)
  | some value => [UserBlock.unmodeled "tool_result_content" value]
  | none => []

/-- One `assistant` content block → an optional Loom `AssistantBlock`. Empty
text/thinking remain explicit blocks, tool uses are modeled, exact images become
media, and every other shape stays byte-exact in `.unmodeled`. -/
private structure ClaudeParsedAssistantBlock where
  block      : AssistantBlock
  occurrence : Option String := none
  wasCarrier : Bool := false

private def cCarrierBlockIndices? (j : Json) : Option (List Nat) := do
  let marker ← cobj j claudeCarrierMarkerKey
  guard (cstr marker "protocol" == some claudeCarrierProtocol)
  match cobj marker "contentBlocks" with
  | none => pure []
  | some (Json.arr values) =>
      values.toList.mapM (fun value => (value.getNat?).toOption)
  | some _ => none

private def cCarrierBlockIndices (j : Json) : List Nat :=
  (cCarrierBlockIndices? j).getD []

/-- Recover `ToolName.canonical` for natively emitted `tool_use` blocks.

Claude's `tool_use` block has slots for exactly `{id, name, input}` and no slot
for Loom's canonical tool identity. The exporter therefore stamps
block-index → canonical pairs into the same record-level `_agent_convert`
marker that already carries `contentBlocks` and the provenance members —
`Emission.envelopePreserved` in `LoomOps.Interop` terms — and this reads them
back. The block itself stays a real, executable Claude `tool_use`.

`none` means the member is present but malformed, which
`cValidateConversationCarrierMarker` rejects at schema time; an absent member
is the ordinary case and yields `[]`. -/
private def cCarrierToolCanonical? (j : Json) : Option (List (Nat × CanonicalTool)) := do
  let marker ← cobj j claudeCarrierMarkerKey
  guard (cstr marker "protocol" == some claudeCarrierProtocol)
  match cobj marker "toolCanonical" with
  | none => pure []
  | some (Json.arr values) =>
      values.toList.mapM (fun value => do
        let blockIdx ← (cobj value "block").bind (fun raw => raw.getNat?.toOption)
        let canonical ← cParseCanonicalToolField? value
        let canonical ← canonical
        pure (blockIdx, canonical))
  | some _ => none

private def cCarrierToolCanonical (j : Json) : List (Nat × CanonicalTool) :=
  (cCarrierToolCanonical? j).getD []

private def cCanonicalForBlock
    (overrides : List (Nat × CanonicalTool)) (blockIdx : Nat) : Option CanonicalTool :=
  (overrides.find? (fun entry => entry.1 == blockIdx)).map Prod.snd

/-- Recover the exact native envelope nested in an exporter provenance marker.
The carrier is data only: structural fields are always read from the containing
record, while this copy is retained for later same-format export. -/
private def cCarrierRawEnvelope? (j : Json) : Option Json := do
  let marker ← cobj j claudeCarrierMarkerKey
  guard (cstr marker "protocol" == some claudeCarrierProtocol)
  let provenance ← cobj marker "provenance"
  guard (cstr provenance "carrier" ==
    some "agent-convert.claude-envelope-provenance.v1")
  let raw ← cobj provenance "rawEnvelope"
  match raw with
  | Json.obj _ => pure raw
  | _ => none

private def cCarrierIdentityProvenance? (j : Json) : Option Json := do
  let marker ← cobj j claudeCarrierMarkerKey
  guard (cstr marker "protocol" == some claudeCarrierProtocol)
  let identity ← cobj marker "identityProvenance"
  guard (cstr identity "carrier" ==
    some "agent-convert.claude-identity-provenance.v1")
  guard (cstr identity "trust" == some "historical-unverified")
  pure identity

private def cParseAssistantBlock
    (carrierMarked : Bool) (expectedOccurrence : String)
    (canonicalOverride : Option CanonicalTool)
    (b : Json) : Option ClaudeParsedAssistantBlock :=
  match cstr b "type" with
  | some "text" =>
      let t := (cstr b "text").getD ""
      if carrierMarked then
        match parseClaudeHistoricalToolCallCarrier? t with
        | some call =>
            if call.occurrence == some expectedOccurrence then
              some { block := call.block, occurrence := call.occurrence,
                     wasCarrier := true }
            else
              some { block := .unmodeled "historical-carrier-occurrence" (Json.str t),
                     wasCarrier := true }
        | none => match parseClaudeMediaCarrier? t with
          | some (mime, locator) =>
              some { block := .media mime locator, wasCarrier := true }
          | none => match parseClaudeUnmodeledAssistantCarrier? t with
            | some block => some { block, wasCarrier := true }
            | none => some { block := .text t }
      else some { block := .text t }
  | some "thinking" =>
      let t := (cstr b "thinking").getD ""
      some { block := .thinking t (cstr b "signature") }
  | some "tool_use" =>
      -- `canonicalOverride` comes from the record-level `_agent_convert`
      -- envelope, not from the block: Claude has no wire slot for it. Absent
      -- (the claude-origin case) it is `none` and this is unchanged.
      some { block := .toolCall
                           { raw := (cstr b "name").getD "",
                             canonical := canonicalOverride }
                           ((cobj b "input").getD (Json.mkObj [])) (cstr b "id") }
  | some "image" =>
      match cExactImageRef? b with
      | some (mime, loc) => some { block := .media mime loc }
      | none => some { block := .unmodeled "image" b }
  | other =>
      -- census S6 (was DROPPED): any other block kind (redacted_thinking,
      -- server_tool_use, …) captured verbatim via the open-world escape hatch —
      -- representable + round-trippable, rather than silently dropped.
      some { block := .unmodeled (other.getD "unknown") b }

/-- A recognized harness control removed from conversation but retained with a
stable source locator, readable rendering, and byte-exact wrapper text. -/
private structure ClaudeArchivedControl where
  uuid        : Option String
  sourceBlock : Nat
  ts          : Option String
  envelope    : ClaudeControlEnvelope
  rawRecord   : Json

/-- A graph record intentionally excluded from dialogue. Keeping the complete
record in transcript provenance prevents a role mismatch or system record from
being silently reclassified or discarded. -/
private structure ClaudeArchivedRecord where
  uuid   : Option String
  ts     : Option String
  kind   : String
  role   : Option String
  reason : String
  raw    : Json

/-- A pre-linkage entry: a role-typed `Payload`, plus the source uuid/parentUuid
still as strings (resolved to indices in the second pass). -/
private structure Proto where
  uuid          : Option String
  parentUuid    : Option String
  ts            : Option String
  payload       : Payload
  carrierBlocks : List Nat := []
  rawEnvelope   : Option Json := none
  rawCompactionBoundary : Option Json := none
  identityProvenance : Option Json := none
  unverifiedCarrier : Bool := false
  timeOverride : Option Time := none

/-- Fold state: the protos so far, a `tool_use` id → (entryIndex, blockIndex)
map, and the call sites already consumed by native results. Tracking sites rather
than result IDs ensures an orphan cannot consume a later reused-ID call. -/
private structure Acc where
  protos       : Array Proto
  tmap         : List (String × (Nat × Nat))
  omap         : List (String × (Nat × Nat))
  matchedCalls : List (Nat × Nat)
  controls     : Array ClaudeArchivedControl
  archived     : Array ClaudeArchivedRecord

private def mkProto (uuid parentUuid ts : Option String) (payload : Payload)
    (carrierBlocks : List Nat := []) (rawEnvelope : Option Json := none)
    (rawCompactionBoundary : Option Json := none)
    (identityProvenance : Option Json := none)
    (unverifiedCarrier : Bool := false)
    (timeOverride : Option Time := none) : Proto :=
  { uuid := uuid, parentUuid := parentUuid, ts := ts, payload := payload,
    carrierBlocks := carrierBlocks, rawEnvelope := rawEnvelope,
    rawCompactionBoundary := rawCompactionBoundary,
    identityProvenance := identityProvenance,
    unverifiedCarrier := unverifiedCarrier, timeOverride := timeOverride }

/-- Construct ordinary user text after the caller has ruled out a complete
synthetic control envelope. -/
private def mkUserTextProto
    (uuid parentUuid ts : Option String) (text : String) (raw : Json) : Proto :=
  mkProto uuid parentUuid ts (Payload.userMsg [UserBlock.text text])
    (rawEnvelope := some raw)

private def cControlLoc (control : ClaudeArchivedControl) : Option String :=
  control.uuid.map (fun uuid => s!"{uuid}:content[{control.sourceBlock}]")

private def cArchiveControl
    (a : Acc) (uuid ts : Option String) (sourceBlock : Nat)
    (envelope : ClaudeControlEnvelope) (rawRecord : Json) : Acc :=
  { a with controls := a.controls.push {
      uuid, sourceBlock, ts, envelope, rawRecord } }

private def cPushOrdinaryOrControl
    (a : Acc) (uuid parentUuid ts : Option String) (sourceBlock : Nat)
    (syntheticControl : Bool) (text : String) (raw : Json) : Acc :=
  if syntheticControl then
    match normalizeClaudeControlEnvelope? text with
    | some envelope => cArchiveControl a uuid ts sourceBlock envelope raw
    | none =>
        { a with protos := a.protos.push (mkUserTextProto uuid parentUuid ts text raw) }
  else
    { a with protos := a.protos.push (mkUserTextProto uuid parentUuid ts text raw) }

private def cAccCallRawId?
    (a : Acc) (entry block : Nat) : Option (Option String) := do
  let proto ← a.protos[entry]?
  match proto.payload with
  | .assistantMsg blocks =>
      match blocks[block]? with
      | some (.toolCall _ _ rawId) => some rawId
      | _ => none
  | _ => none

/-- Historical result linkage is occurrence-addressed, but the occurrence is
not enough on its own: exactly one earlier carrier call must claim it and all
three recorded ID copies must agree. A collision or forged disagreement remains
explicitly unresolved instead of binding to whichever marker appeared first. -/
private def cResolveHistoricalCall
    (a : Acc) (curIdx : Nat) (resultRawId : Option String) :
    ClaudeHistoricalCallRef → CallRef
  | .resolved occurrence rawId =>
      let unresolvedId := resultRawId.orElse (fun _ => rawId)
      match (a.omap.filter (fun kv => kv.1 == occurrence)).map Prod.snd with
      | [(entry, block)] =>
          if !(entry < curIdx) then
            .unresolved unresolvedId "historical tool call occurrence is not earlier"
          else if resultRawId != rawId || cAccCallRawId? a entry block != some rawId then
            .unresolved unresolvedId
              "historical tool call occurrence and raw IDs disagree"
          else .resolved entry block
      | [] => .unresolved unresolvedId
          s!"historical tool call occurrence '{occurrence}' was not found"
      | _ => .unresolved unresolvedId
          s!"historical tool call occurrence '{occurrence}' is ambiguous"
  | .unresolved rawId note => .unresolved rawId note

private def cRememberResolvedCall
    (matched : List (Nat × Nat)) : CallRef → List (Nat × Nat)
  | .resolved entry block =>
      if matched.contains (entry, block) then matched else matched ++ [(entry, block)]
  | .unresolved _ _ => matched

private def cPushHistoricalResult
    (a : Acc) (uuid parentUuid ts : Option String)
    (result : ClaudeHistoricalResult) (raw : Json) : Acc :=
  let curIdx := a.protos.size
  let call := cResolveHistoricalCall a curIdx result.rawId result.call
  let block := EnvBlock.toolResult call result.content result.error
  { a with
    protos := a.protos.push
      (mkProto uuid parentUuid ts (Payload.envMsg [block]) [0]
        (rawEnvelope := some raw)),
    matchedCalls := cRememberResolvedCall a.matchedCalls call }

private def cPushHistoricalResults
    (a : Acc) (uuid parentUuid ts : Option String)
    (results : List ClaudeHistoricalResult) (raw : Json) : Acc :=
  let curIdx := a.protos.size
  let calls := results.map (fun result =>
    cResolveHistoricalCall a curIdx result.rawId result.call)
  let blocks := List.zipWith (fun result call =>
    EnvBlock.toolResult call result.content result.error) results calls
  { a with
    protos := a.protos.push (mkProto uuid parentUuid ts
      (Payload.envMsg blocks) (List.range results.length) (rawEnvelope := some raw)),
    matchedCalls := calls.foldl cRememberResolvedCall a.matchedCalls }

private def cHistoricalResultArray?
    (entryIdx : Nat) (carrierIndices : List Nat)
    (blocks : Array Json) : Option (List ClaudeHistoricalResult) := do
  guard (!blocks.isEmpty)
  blocks.toList.zipIdx.mapM (fun (block, blockIdx) => do
    guard (carrierIndices.contains blockIdx)
    guard (cstr block "type" == some "text")
    let result ← parseClaudeHistoricalToolResultCarrier? ((cstr block "text").getD "")
    guard (result.occurrence == cOccurrence entryIdx blockIdx)
    pure result)

private def cPushCarrierOccurrenceCollision
    (a : Acc) (uuid parentUuid ts : Option String)
    (text : String) (raw : Json) : Acc :=
  { a with protos := a.protos.push (mkProto uuid parentUuid ts
      (.otherMsg "claude.carrier-collision" [
        .unmodeled "historical-carrier-occurrence" (Json.str text)])
      (rawEnvelope := some raw)) }

private def cPushUserText
    (a : Acc) (uuid parentUuid ts : Option String)
    (sourceBlock : Nat) (carrierMarked syntheticControl : Bool)
    (text : String) (raw : Json) : Acc :=
  if carrierMarked then
    match parseClaudeHistoricalToolResultCarrier? text with
    | some result =>
        if sourceBlock == 0 && result.occurrence == cOccurrence a.protos.size 0 then
          cPushHistoricalResult a uuid parentUuid ts result raw
        else cPushCarrierOccurrenceCollision a uuid parentUuid ts text raw
    | none => match parseClaudeMediaCarrier? text with
      | some (mime, locator) =>
          let proto := mkProto uuid parentUuid ts
            (Payload.userMsg [UserBlock.media mime locator]) [0]
            (rawEnvelope := some raw)
          { a with protos := a.protos.push proto }
      | none => match parseClaudeUnmodeledUserCarrier? text with
        | some block =>
            { a with protos := a.protos.push (mkProto uuid parentUuid ts
                (Payload.userMsg [block]) [0] (rawEnvelope := some raw)) }
        | none => match parseClaudeUnmodeledEnvCarrier? text with
          | some block =>
              { a with protos := a.protos.push (mkProto uuid parentUuid ts
                  (Payload.envMsg [block]) [0] (rawEnvelope := some raw)) }
          | none => cPushOrdinaryOrControl a uuid parentUuid ts sourceBlock
              syntheticControl text raw
  else cPushOrdinaryOrControl a uuid parentUuid ts sourceBlock syntheticControl text raw

private def cProtoExtras (p : Proto) : Option Json :=
  let fields : List (String × Json) :=
    (match p.ts with | some ts => [("ts", Json.str ts)] | none => [])
    ++ (if p.carrierBlocks.isEmpty then [] else
          [(claudeCarrierBlocksExtrasKey,
            Json.arr (p.carrierBlocks.map (fun n =>
              Json.num (Lean.JsonNumber.fromNat n))).toArray)])
    ++ (match p.rawEnvelope with
        | some raw => [("claudeRawEnvelope", raw)]
        | none => [])
    ++ (match p.rawCompactionBoundary with
        | some raw => [("claudeRawCompactionBoundary", raw)]
        | none => [])
    ++ (match p.identityProvenance with
        | some identity => [("claudeIdentityProvenance", identity)]
        | none => [])
    ++ (if p.unverifiedCarrier || !p.carrierBlocks.isEmpty then
          [("claudeCarrierDisposition", Json.str
            "agent-convert-historical-unverified")]
        else [])
  if fields.isEmpty then none else some (Json.mkObj fields)

private def cOriginCarrierBlocks (origin : Origin) : List Nat :=
  match origin.extras.bind (fun extras => carr extras claudeCarrierBlocksExtrasKey) with
  | some values =>
      match values.toList.mapM (fun value => (value.getNat?).toOption) with
      | some blocks =>
          if blocks.zipIdx.all (fun (block, index) =>
              !(blocks.take index).contains block) then blocks else []
      | none => []
  | none => []

private def cMarkOriginCarrierBlocks (origin : Origin) (blocks : List Nat) : Origin :=
  let prior := cOriginCarrierBlocks origin
  let merged : List Nat := (prior ++ blocks).foldl (fun out block =>
    if out.contains block then out else out ++ [block]) []
  let value := Json.arr (merged.map (fun n =>
    Json.num (Lean.JsonNumber.fromNat n))).toArray
  let extras :=
    match origin.extras with
    | some (Json.obj fields) =>
        some (Json.obj ((fields.insert claudeCarrierBlocksExtrasKey value).insert
          "claudeCarrierDisposition" (Json.str "agent-convert-historical-unverified")))
    | some previous => some (Json.mkObj [
        ("priorExtras", previous), (claudeCarrierBlocksExtrasKey, value),
        ("claudeCarrierDisposition", Json.str "agent-convert-historical-unverified")])
    | none => some (Json.mkObj [
        (claudeCarrierBlocksExtrasKey, value),
        ("claudeCarrierDisposition", Json.str "agent-convert-historical-unverified")])
  { origin with extras := extras }

/-- Rebase only exporter-owned occurrence-addressed carrier blocks during thread
projection. Header-looking ordinary text has no `claudeCarrierBlocks` ownership
index and therefore remains byte-exact. -/
def projectClaudeHistoricalCarrierCoordinates
    (oldEntryIndices : List Nat) (entry : Entry) : Payload :=
  let stamped := entry.origin.extras.bind (fun extras =>
    cstr extras "claudeCarrierDisposition") ==
      some "agent-convert-historical-unverified"
  let carrierBlocks := if entry.disposition == .historicalUnverified || stamped then
    cOriginCarrierBlocks entry.origin else []
  let projectUser := fun (blocks : List UserBlock) => blocks.zipIdx.map (fun (block, blockIdx) =>
    if !carrierBlocks.contains blockIdx then block else
      match block with
      | .text text => .text (cProjectHistoricalCarrierText oldEntryIndices text)
      | other => other)
  let projectAssistant := fun (blocks : List AssistantBlock) =>
    blocks.zipIdx.map (fun (block, blockIdx) =>
      if !carrierBlocks.contains blockIdx then block else
        match block with
        | .text text => .text (cProjectHistoricalCarrierText oldEntryIndices text)
        | other => other)
  match entry.payload with
  | .userMsg blocks => .userMsg (projectUser blocks)
  | .assistantMsg blocks => .assistantMsg (projectAssistant blocks)
  | .otherMsg role blocks => .otherMsg role (projectUser blocks)
  | payload => payload

/-- Claude's envelope `type` is authoritative when `message.role` is absent,
but an explicit mismatched role denotes control/runtime context rather than
conversation. Such lines remain available to the parent walk as graph nodes. -/
private def cConversationKind? (j : Json) : Option String :=
  let kind := cstr j "type"
  let role := cobj j "message" >>= fun message => cstr message "role"
  match kind with
  | some "user" => if role.isNone || role == some "user" then some "user" else none
  | some "assistant" =>
      if role.isNone || role == some "assistant" then some "assistant" else none
  | _ => none

private def cPathRecord (j : Json) : Bool :=
  match cstr j "type" with
  | some "user" | some "assistant" | some "system" => true
  | _ => false

private def cGraphRecord (j : Json) : Bool :=
  cPathRecord j || cstr j "type" == some "attachment"

private def cCompactionBoundary (j : Json) : Bool :=
  cstr j "type" == some "system" && cstr j "subtype" == some "compact_boundary"

/-- Records that natively participate in Claude's resumable graph. Ordinary
system/control records and explicit role mismatches are only graph-addressable
fallbacks: they matter when an actual parent/pointer edge names them, but they
must not compete with a dialogue node that happens to reuse their UUID. -/
private def cSemanticGraphRecord (j : Json) : Bool :=
  (cConversationKind? j).isSome || cCompactionBoundary j ||
    (cParseCompactionCarrier? j).isSome || (cParseInertPayloadCarrier? j).isSome ||
    cstr j "type" == some "attachment"

private def cKnownStateRecordType (kind : String) : Bool :=
  ["mode", "permission-mode", "queue-operation", "agent-name", "custom-title",
   "ai-title", "pr-link", "file-history-snapshot", "bridge-session"].contains kind

private def cArchivedRecordReason? (j : Json) : Option String :=
  match cstr j "type" with
  | some "user" =>
      if (cobj j "message" >>= fun message => cstr message "role") == some "user" then none
      else some "envelope type and message.role disagree; retained as inert provenance"
  | some "assistant" =>
      if (cobj j "message" >>= fun message => cstr message "role") == some "assistant" then none
      else some "envelope type and message.role disagree; retained as inert provenance"
  | some "system" =>
      if cCompactionBoundary j || (cParseCompactionCarrier? j).isSome ||
          (cParseInertPayloadCarrier? j).isSome then none
      else some "system/developer record retained as inert provenance"
  | some "attachment" =>
      some "attachment record retained as inert graph provenance"
  | some "last-prompt" =>
      some "resume-pointer record retained as inert provenance"
  | some "agent-convert-provenance" => none
  | some kind =>
      if cKnownStateRecordType kind then
        some s!"Claude state record '{kind}' retained as inert provenance"
      else some s!"unknown Claude record type '{kind}' retained as inert provenance"
  | none => some "record without a usable type retained as inert provenance"

private def cMkArchivedRecord (j : Json) (reason : String) : ClaudeArchivedRecord :=
  let message := cobj j "message"
  { uuid := cstr j "uuid", ts := cstr j "timestamp",
    kind := (cstr j "type").getD "unknown",
    role := message >>= fun m => cstr m "role",
    reason := reason, raw := j }

/-- A pointer-selected graph node which produced no dialogue entry still needs
an occurrence in the IR. This inert payload keeps the exact node outside all
dialogue roles, gives `activeLeaf` the authoritative identity, and lets the
existing inert carrier reproduce it without pretending it was user content. -/
private def cAuthoritativeLeafPayload (j : Json) : Payload :=
  .otherMsg "claude.graph-record" [
    .unmodeled ((cstr j "type").getD "unknown") j]

private def cOptionalStringField?
    (j : Json) (key : String) : Option (Option String) :=
  match cobj j key with
  | none => some none
  | some (Json.str value) => some (some value)
  | some _ => none

private def cParseArchivedControlJson? (j : Json) : Option ClaudeArchivedControl := do
  let sourceBlock ← (j.getObjVal? "contentBlock" >>= Json.getNat?).toOption
  let rawRecord ← cobj j "record"
  let _ ← match rawRecord with | Json.obj _ => some () | _ => none
  pure {
    uuid := ← cOptionalStringField? j "uuid"
    sourceBlock
    ts := ← cOptionalStringField? j "timestamp"
    envelope := {
      kind := ← cstr j "kind"
      rendered := ← cstr j "rendered"
      raw := ← cstr j "raw" }
    rawRecord }

private def cParseArchivedRecordJson? (j : Json) : Option ClaudeArchivedRecord := do
  let raw ← cobj j "raw"
  let _ ← match raw with | Json.obj _ => some () | _ => none
  pure {
    uuid := ← cOptionalStringField? j "uuid"
    ts := ← cOptionalStringField? j "timestamp"
    kind := ← cstr j "kind"
    role := ← cOptionalStringField? j "role"
    reason := ← cstr j "reason"
    raw }

private inductive ClaudeTranscriptProvenance where
  | control (value : ClaudeArchivedControl)
  | record (value : ClaudeArchivedRecord)
  /-- Inert source `EnvInfo` provenance. Restored on import as source facts; it
  is never a target-policy input. -/
  | sourceEnv (value : EnvInfo) (rawCarrier : Json)

private def cParseTranscriptProvenanceCarrier?
    (j : Json) : Option ClaudeTranscriptProvenance := do
  guard (cstr j "type" == some "agent-convert-provenance")
  let marker ← cobj j claudeCarrierMarkerKey
  guard (cstr marker "protocol" == some claudeCarrierProtocol)
  let carrier ← cobj marker "transcriptProvenance"
  guard (cstr carrier "carrier" ==
    some "agent-convert.claude-transcript-provenance.v1")
  let payload ← cobj carrier "payload"
  match ← cstr carrier "kind" with
  | "control" => pure (.control (← cParseArchivedControlJson? payload))
  | "record" => pure (.record (← cParseArchivedRecordJson? payload))
  | "sourceEnv" => pure (.sourceEnv (← cDecodeSourceEnv? payload) j)
  | _ => none

private def cTranscriptSourceEnv? (records : List Json) : Option EnvInfo :=
  records.findSome? (fun record =>
    match cParseTranscriptProvenanceCarrier? record with
    | some (.sourceEnv env _) => some env
    | _ => none)

private def cTranscriptSourceEnvCarrier? (records : List Json) : Option Json :=
  records.findSome? (fun record =>
    match cParseTranscriptProvenanceCarrier? record with
    | some (.sourceEnv _ rawCarrier) => some rawCarrier
    | _ => none)

private def cTranscriptSourceEnvCount (records : List Json) : Nat :=
  records.countP (fun record =>
    match cParseTranscriptProvenanceCarrier? record with
    | some (.sourceEnv _ _) => true
    | _ => false)

private def cCompactionTokensBefore? (boundary : Json) : Option Nat := do
  let metadata ← cobj boundary "compactMetadata"
  (metadata.getObjVal? "preTokens" >>= Json.getNat?).toOption

private def cStampNewProtoProvenance
    (priorSize : Nat) (identity : Option Json) (unverified : Bool)
    (timeOverride : Option Time)
    (acc : Acc) : Acc :=
  if identity.isNone && !unverified && timeOverride.isNone then acc else
    let protos := acc.protos.toList.zipIdx.map (fun (proto, index) =>
      if index < priorSize then proto else
        { proto with
          identityProvenance := identity.orElse (fun _ => proto.identityProvenance)
          unverifiedCarrier := proto.unverifiedCarrier || unverified
          timeOverride := timeOverride.orElse (fun _ => proto.timeOverride) })
    { acc with protos := protos.toArray }

/-- Process one `user`/`assistant` line into zero or more protos. Tool-result
`CallRef`s resolve against `tmap`, which is populated by the assistant lines
that precede them (a well-formed source calls before it results). -/
private def stepLine (byUuid : List (String × Json)) (acc : Acc) (j : Json) : Acc :=
  let mj := (cobj j "message").getD Json.null
  let raw := (cCarrierRawEnvelope? j).getD j
  let uuid := cstr j "uuid"
  let parentUuid := cstr j "parentUuid"
  let ts := cstr j "timestamp"
  let carrierIndices := cCarrierBlockIndices j
  let toolCanonical := cCarrierToolCanonical j
  let syntheticControl := cbool j "isMeta"
  let identity := cCarrierIdentityProvenance? j
  let timeOverride := cCarrierTimeProvenance? j
  let unverified := (cParseInertPayloadCarrier? j).isSome ||
    (cParseCompactionCarrier? j).isSome
  let priorSize := acc.protos.size
  let out := match cParseInertPayloadCarrier? j, cParseCompactionCarrier? j,
      cConversationKind? j with
  | some payload, _, _ =>
      let entryIdx := acc.protos.size
      let calls : List (Nat × Option String) := match payload with
        | .assistantMsg blocks => blocks.zipIdx.filterMap (fun (block, blockIdx) =>
            match block with
            | AssistantBlock.toolCall _ _ rawId => some (blockIdx, rawId)
            | _ => none)
        | _ => []
      { acc with
        protos := acc.protos.push (mkProto uuid parentUuid ts payload
          (rawEnvelope := cCarrierRawEnvelope? j))
        tmap := acc.tmap ++ calls.filterMap (fun (blockIdx, rawId) =>
          rawId.map (fun id => (id, (entryIdx, blockIdx))))
        omap := acc.omap ++ calls.map (fun (blockIdx, _) =>
          (cOccurrence entryIdx blockIdx, (entryIdx, blockIdx))) }
  | none, some carrier, _ =>
      { acc with protos := acc.protos.push (mkProto uuid parentUuid ts
          (.compaction carrier.summary carrier.coverage carrier.tokensBefore)
          (rawEnvelope := carrier.sourceEnvelope)
          (rawCompactionBoundary := carrier.sourceBoundary)) }
  | none, none, some "assistant" =>
      let content := (carr mj "content").getD #[]
      let entryIdx := acc.protos.size
      let parsed := content.toList.zipIdx.filterMap (fun (b, sourceIdx) =>
        cParseAssistantBlock (carrierIndices.contains sourceIdx)
          (cOccurrence entryIdx sourceIdx)
          (cCanonicalForBlock toolCanonical sourceIdx) b)
      let blocks := parsed.map (·.block)
      let idx := entryIdx
      let additions := blocks.zipIdx.filterMap (fun (blk, bi) =>
        match blk with
        | AssistantBlock.toolCall _ _ (some rid) => some (rid, (idx, bi))
        | _ => none)
      let occurrenceAdditions := parsed.zipIdx.filterMap (fun (blk, bi) =>
        blk.occurrence.map (fun occurrence => (occurrence, (idx, bi))))
      let carrierBlocks := parsed.zipIdx.filterMap (fun (blk, bi) =>
        if blk.wasCarrier then some bi else none)
      { acc with
        protos := acc.protos.push (mkProto uuid parentUuid ts
          (Payload.assistantMsg blocks) carrierBlocks (rawEnvelope := some raw)),
        tmap := acc.tmap ++ additions,
        omap := acc.omap ++ occurrenceAdditions }
  | none, none, some "user" =>
      if cbool j "isCompactSummary" then
        let summary := (cstr mj "content").getD ""
        let boundaryFromParent := parentUuid.bind (fun parent =>
          (byUuid.find? (fun item => item.1 == parent)).map Prod.snd) |>.filter
            cCompactionBoundary
        -- After adjacent soft-cut injection, the selected path carries exactly
        -- one compact_boundary even when parentUuid names the prior user node.
        let boundaryFromPath :=
          let boundaries := byUuid.filterMap (fun (_, record) =>
            if cCompactionBoundary record then some record else none)
          match boundaries with | [boundary] => some boundary | _ => none
        let boundary := boundaryFromParent.orElse (fun _ => boundaryFromPath)
        { acc with protos := acc.protos.push (mkProto uuid parentUuid ts
            (.compaction summary .unknownPrefix (boundary >>= cCompactionTokensBefore?))
            (rawEnvelope := some raw) (rawCompactionBoundary := boundary)) }
      else match cobj mj "content" with
      | some (Json.str s) =>
          cPushUserText acc uuid parentUuid ts 0 (carrierIndices.contains 0)
            syntheticControl s raw
      | some (Json.arr blks) =>
          if blks.isEmpty then
            { acc with protos := acc.protos.push (mkProto uuid parentUuid ts
                (Payload.userMsg []) (rawEnvelope := some raw)) }
          else match cHistoricalResultArray? acc.protos.size carrierIndices blks with
          | some results => cPushHistoricalResults acc uuid parentUuid ts results
              raw
          | none =>
              blks.toList.zipIdx.foldl (fun (a : Acc) (b, sourceIdx) =>
                let carrierMarked := carrierIndices.contains sourceIdx
                match cstr b "type" with
                | some "tool_result" =>
                    let curIdx := a.protos.size
                    let tid := (cstr b "tool_use_id").getD ""
                    let matchingCalls := a.tmap.filter (fun kv =>
                      kv.1 == tid && kv.2.1 < curIdx && !a.matchedCalls.contains kv.2)
                    let call :=
                      match matchingCalls.map Prod.snd with
                      | [(e, bi)] => CallRef.resolved e bi
                      | [] => CallRef.unresolved (cstr b "tool_use_id")
                          "no unmatched earlier tool_use occurrence"
                      | _ => CallRef.unresolved (cstr b "tool_use_id")
                          "ambiguous tool_use_id: multiple unmatched earlier occurrences"
                    let blk := EnvBlock.toolResult call
                      (parseToolResultContent carrierMarked (cobj b "content"))
                      (match cobj b "is_error" with
                       | some (Json.bool value) => ErrorSignal.native value
                       | _ => ErrorSignal.unrecorded)
                    { a with
                      protos := a.protos.push (mkProto uuid parentUuid ts
                        (Payload.envMsg [blk]) (if carrierMarked then [0] else [])
                        (rawEnvelope := some raw)),
                      matchedCalls := cRememberResolvedCall a.matchedCalls call }
                | some "text" =>
                    let t := (cstr b "text").getD ""
                    cPushUserText a uuid parentUuid ts sourceIdx carrierMarked
                      syntheticControl t raw
                | some "image" =>
                    let block := match cExactImageRef? b with
                      | some (mime, loc) => UserBlock.media mime loc
                      | none => UserBlock.unmodeled "image" b
                    { a with protos := a.protos.push (mkProto uuid parentUuid ts
                        (Payload.userMsg [block]) (rawEnvelope := some raw)) }
                | other =>
                    -- census S6 (was DROPPED): unknown user content block captured
                    -- verbatim via the open-world escape hatch — representable + round-trippable.
                    { a with protos := a.protos.push (mkProto uuid parentUuid ts
                        (Payload.userMsg [UserBlock.unmodeled (other.getD "unknown") b])
                        (rawEnvelope := some raw)) }) acc
      | _ => acc
  | _, _, _ => acc
  cStampNewProtoProvenance priorSize identity unverified timeOverride out

/-! ## Active-path reconstruction (leaf-walk) — mirrors `importClaudeCodeToPi`
(`src/pi/claudeCode.ts:583-610`), the TS oracle the cutover harness diffs against.

Claude sessions BRANCH (alternate edits fork the `parentUuid` chain) and carry
externalized subagent **sidechains** (`isSidechain:true` lines). `claude --resume`
— and the TS importer — reconstruct the newest **non-sidechain** leaf's ancestry,
NOT every chat line in file order. The earlier slice took chat lines in file
order, so abandoned branches + sidechains got spliced into the main thread and
the IR became a strict superset of the TS active path (RC2 census: 11/15 real
sessions, up to 1646-vs-306 entries). We now reproduce the walk exactly: pick the
leaf, follow `parentUuid` to root, keep the user/assistant lines, and chain them
**sequentially** (parent = previous kept entry) as the TS oracle does. -/

/-- Timestamp of a line (missing → ""), for the newest-leaf pick. -/
private def clTs (j : Json) : String := (cstr j "timestamp").getD ""

/-- Fold to the newest line, ties → earliest in original order (replace only on a
strictly-greater timestamp) — the head of a stable descending sort, i.e. what
`leaves.sort(desc).find(...)`/`[0]` picks in `claudeCode.ts:598-601`. ISO-8601
timestamps order identically under codepoint `<` and JS `localeCompare`. -/
private def newestLine (best : Option Json) (cand : Json) : Option Json :=
  match best with
  | none => some cand
  | some b => if clTs b < clTs cand then some cand else some b

/-- Walk `parentUuid` from `start` toward root through `byUuid` (ALL lines, so the
chain traverses dropped meta lines exactly like the TS walk), collecting the
user/assistant lines in leaf→root order. `fuel` bounds the recursion for
structural termination and, with `seen`, guards cycles (the TS `while …
!seen.has` loop). -/
private def walkLeafToRoot
    (byUuid : List (String × Json)) : Nat → Option Json → List String → List Json
  | 0, _, _ => []
  | _+1, none, _ => []
  | fuel+1, some cur, seen =>
      match cstr cur "uuid" with
      | none => []
      | some u =>
        if seen.contains u then []
        else
          let parent := (cstr cur "parentUuid").bind (fun pu =>
            (byUuid.find? (fun kv => kv.1 == pu)).map Prod.snd)
          let rest := walkLeafToRoot byUuid fuel parent (u :: seen)
          if cPathRecord cur then cur :: rest else rest

/-! `Lean.Json` stores objects in a map, so duplicate members are no longer
observable after parsing. Reserved exporter-owned JSON is scanned structurally
first and duplicate member paths are rejected before normalization. -/

private structure ClaudeRawJsonScan where
  rest : List Char
  duplicatePaths : List String

private def cRawJsonWhitespace (char : Char) : Bool :=
  char == ' ' || char == '\n' || char == '\r' || char == '\t'

private def cDropRawJsonWhitespace (chars : List Char) : List Char :=
  chars.dropWhile cRawJsonWhitespace

private partial def cTakeRawJsonString
    (chars reversed : List Char) : Except String (String × List Char) :=
  match chars with
  | [] => .error "unterminated JSON string"
  | '"' :: rest => .ok (String.ofList reversed.reverse, rest)
  | '\\' :: escaped :: rest =>
      cTakeRawJsonString rest (escaped :: '\\' :: reversed)
  | '\\' :: [] => .error "unterminated JSON string escape"
  | char :: rest => cTakeRawJsonString rest (char :: reversed)

private def cDecodeRawJsonKey (encoded : String) : Except String String :=
  match Json.parse ("\"" ++ encoded ++ "\"") with
  | .ok (Json.str key) => .ok key
  | .ok _ => .error "JSON object key did not decode as a string"
  | .error error => .error error

private def cRawJsonMemberPath (parent key : String) : String :=
  if parent.isEmpty then key else parent ++ "." ++ key

private def cDropRawJsonPrimitive : List Char → List Char
  | [] => []
  | input@(char :: rest) =>
      if char == ',' || char == ']' || char == '}' then input
      else cDropRawJsonPrimitive rest

mutual
  private partial def cScanRawJsonValue
      (chars : List Char) (path : String) : Except String ClaudeRawJsonScan := do
    match cDropRawJsonWhitespace chars with
    | [] => .error "missing JSON value"
    | '{' :: rest => cScanRawJsonObject rest path [] []
    | '[' :: rest => cScanRawJsonArray rest path 0 []
    | '"' :: rest =>
        let (_, tail) ← cTakeRawJsonString rest []
        pure { rest := tail, duplicatePaths := [] }
    | primitive => pure {
        rest := cDropRawJsonPrimitive primitive
        duplicatePaths := [] }

  private partial def cScanRawJsonObject
      (chars : List Char) (path : String) (seen : List String)
      (duplicates : List String) : Except String ClaudeRawJsonScan := do
    match cDropRawJsonWhitespace chars with
    | [] => .error "unterminated JSON object"
    | '}' :: rest => pure { rest, duplicatePaths := duplicates }
    | '"' :: rest =>
        let (encodedKey, afterKey) ← cTakeRawJsonString rest []
        let key ← cDecodeRawJsonKey encodedKey
        let afterKey := cDropRawJsonWhitespace afterKey
        let afterColon ← match afterKey with
          | ':' :: tail => pure tail
          | _ => .error "JSON object key is missing ':'"
        let memberPath := cRawJsonMemberPath path key
        let value ← cScanRawJsonValue afterColon memberPath
        let duplicates := duplicates ++ value.duplicatePaths ++
          (if seen.contains key then [memberPath] else [])
        match cDropRawJsonWhitespace value.rest with
        | ',' :: tail => cScanRawJsonObject tail path (key :: seen) duplicates
        | '}' :: tail => pure { rest := tail, duplicatePaths := duplicates }
        | _ => .error "JSON object member is missing ',' or '}'"
    | _ => .error "JSON object key must be a string"

  private partial def cScanRawJsonArray
      (chars : List Char) (path : String) (index : Nat)
      (duplicates : List String) : Except String ClaudeRawJsonScan := do
    match cDropRawJsonWhitespace chars with
    | [] => .error "unterminated JSON array"
    | ']' :: rest => pure { rest, duplicatePaths := duplicates }
    | valueChars =>
        let value ← cScanRawJsonValue valueChars s!"{path}[{index}]"
        let duplicates := duplicates ++ value.duplicatePaths
        match cDropRawJsonWhitespace value.rest with
        | ',' :: tail => cScanRawJsonArray tail path (index + 1) duplicates
        | ']' :: tail => pure { rest := tail, duplicatePaths := duplicates }
        | _ => .error "JSON array member is missing ',' or ']'"
end

private def cRawJsonDuplicatePaths (text : String) : Except String (List String) := do
  let scanned ← cScanRawJsonValue text.toList ""
  if (cDropRawJsonWhitespace scanned.rest).isEmpty then
    pure scanned.duplicatePaths
  else
    .error "trailing content after JSON value"

private def cReservedOuterDuplicatePath? (paths : List String) : Option String :=
  paths.find? (fun path => path == claudeCarrierMarkerKey ||
    path.startsWith (claudeCarrierMarkerKey ++ ".") ||
    path.startsWith (claudeCarrierMarkerKey ++ "["))

/-- Parse every JSONL record or refuse the import with a one-based source line.
Only the empty segment produced by one terminal record delimiter is ignored;
blank interior records, malformed JSON, and non-object JSON values are errors.
Consequently a successful import has skipped exactly zero source records. -/
private def cParseClaudeJsonLines (text : String) : Except String (List Json) := do
  if text.isEmpty then
    .error "empty session"
  else
    let split := text.splitOn "\n"
    let records := split.zipIdx.filter (fun (line, index) =>
      !(line.isEmpty && text.endsWith "\n" && index + 1 == split.length))
    if records.isEmpty then
      .error "empty session"
    else
      records.mapM (fun (line, index) =>
        if line.isEmpty then
          .error s!"malformed Claude JSONL at line {index + 1}: empty record"
        else
          match Json.parse line with
          | .error error =>
              .error s!"malformed Claude JSONL at line {index + 1}: {error}"
          | .ok parsed =>
              match parsed with
              | Json.obj _ =>
                  match cRawJsonDuplicatePaths line with
                  | .error error =>
                      .error s!"malformed Claude JSONL at line {index + 1}: reserved JSON scan failed: {error}"
                  | .ok duplicatePaths =>
                      match cReservedOuterDuplicatePath? duplicatePaths with
                      | some path =>
                          .error s!"malformed Claude record at line {index + 1}: exporter-owned reserved JSON contains duplicate object member '{path}'"
                      | none => .ok parsed
              | _ => .error s!"malformed Claude JSONL at line {index + 1}: expected JSON object")

private def cSchemaError (line : Nat) (path detail : String) : Except String α :=
  .error s!"malformed Claude record at line {line}: {path} {detail}"

private def cRequireString
    (line : Nat) (path key : String) (j : Json) : Except String String :=
  match cobj j key with
  | none => cSchemaError line (path ++ key) "is required"
  | some (Json.str value) => .ok value
  | some _ => cSchemaError line (path ++ key) "must be a string"

private def cRequireNonemptyString
    (line : Nat) (path key : String) (j : Json) : Except String String := do
  let value ← cRequireString line path key j
  if value.isEmpty then cSchemaError line (path ++ key) "must not be empty"
  else pure value

private def cRequireUuidString
    (line : Nat) (path key : String) (j : Json) : Except String String := do
  let value ← cRequireNonemptyString line path key j
  if claudeUuidValid value then pure value
  else cSchemaError line (path ++ key) "must be a UUID"

private def cRequireObject
    (line : Nat) (path key : String) (j : Json) : Except String Json :=
  match cobj j key with
  | none => cSchemaError line (path ++ key) "is required"
  | some value@(Json.obj _) => .ok value
  | some _ => cSchemaError line (path ++ key) "must be an object"

private def cHasDuplicateNat (values : List Nat) : Bool := Id.run do
  let mut seen : List Nat := []
  for value in values do
    if seen.contains value then return true
    seen := value :: seen
  return false

private def cMarkedConversationCarrierValid (role text : String) : Bool :=
  if role == "assistant" then
    (parseClaudeHistoricalToolCallCarrier? text).isSome ||
      (parseClaudeMediaCarrier? text).isSome ||
      (parseClaudeUnmodeledAssistantCarrier? text).isSome
  else if role == "user" then
    (parseClaudeHistoricalToolResultCarrier? text).isSome ||
      (parseClaudeMediaCarrier? text).isSome ||
      (parseClaudeUnmodeledUserCarrier? text).isSome ||
      (parseClaudeUnmodeledEnvCarrier? text).isSome
  else false

private def cMarkedCarrierEncodedJson? (text : String) : Option String :=
  [claudeHistoricalToolCallCarrierHeader, claudeHistoricalToolResultCarrierHeader,
    claudeMediaCarrierHeader, claudeUnmodeledAssistantCarrierHeader,
    claudeUnmodeledUserCarrierHeader, claudeUnmodeledEnvCarrierHeader].findSome?
      (fun header => (text.dropPrefix? (header ++ "\n")).map (fun slice => slice.toString))

private def cValidateMarkedCarrierDuplicateMembers
    (line blockIdx : Nat) (text : String) : Except String Unit :=
  match cMarkedCarrierEncodedJson? text with
  | none => pure ()
  | some encoded =>
      match cRawJsonDuplicatePaths encoded with
      | .ok (path :: _) =>
          cSchemaError line s!"message.content[{blockIdx}]"
            s!"exporter-owned carrier JSON contains duplicate object member '{path}'"
      | .ok [] | .error _ => pure ()

private def cValidateCarrierProtocol
    (line : Nat) (record : Json) : Except String Unit :=
  match record.getObjVal? claudeCarrierMarkerKey with
  | .error _ => pure ()
  | .ok marker@(Json.obj _) =>
      match cstr marker "protocol" with
      | some protocol =>
          if protocol == claudeCarrierProtocol then pure ()
          else cSchemaError line (claudeCarrierMarkerKey ++ ".protocol")
            s!"must be '{claudeCarrierProtocol}'"
      | none => cSchemaError line (claudeCarrierMarkerKey ++ ".protocol")
          "is required and must be a string"
  | .ok _ => cSchemaError line claudeCarrierMarkerKey "must be an object"

private def cValidateConversationCarrierMarker
    (line : Nat) (kind role : String) (content : Json) (record : Json) :
    Except String Unit := do
  match record.getObjVal? claudeCarrierMarkerKey with
  | .error _ => pure ()
  | .ok marker =>
      if kind != role then
        cSchemaError line claudeCarrierMarkerKey
          "cannot annotate an envelope/message role mismatch"
      else pure ()
      let recognizedPurpose :=
        ["contentBlocks", "provenance", "identityProvenance", "timeProvenance",
          "toolCanonical"].any
          (fun key => (marker.getObjVal? key).toOption.isSome)
      if !recognizedPurpose then
        cSchemaError line claudeCarrierMarkerKey
          "has no recognized conversation-carrier payload"
      else pure ()
      match marker.getObjVal? "toolCanonical" with
      | .error _ => pure ()
      | .ok (Json.arr rawCanonical) =>
          if rawCanonical.isEmpty then
            cSchemaError line (claudeCarrierMarkerKey ++ ".toolCanonical")
              "must not be empty when present"
          else pure ()
          let pairs ← match cCarrierToolCanonical? record with
            | some pairs => pure pairs
            | none => (cSchemaError line
                (claudeCarrierMarkerKey ++ ".toolCanonical")
                "must list block/canonical members naming a recognized canonical tool")
          if cHasDuplicateNat (pairs.map Prod.fst) then
            cSchemaError line (claudeCarrierMarkerKey ++ ".toolCanonical")
              "must not contain duplicate block indices"
          else pure ()
          -- The stamp annotates the target's OWN construct; it can only name a
          -- block that is actually a native `tool_use`, never invent one.
          let nativeCallIndices : List Nat := match content with
            | Json.arr blocks => blocks.toList.zipIdx.filterMap
                (fun (block, blockIdx) =>
                  if cstr block "type" == some "tool_use" then some blockIdx else none)
            | _ => []
          pairs.forM (fun (blockIdx, _) =>
            if nativeCallIndices.contains blockIdx then pure ()
            else cSchemaError line (claudeCarrierMarkerKey ++ ".toolCanonical")
              s!"block index {blockIdx} does not address a native tool_use block")
      | .ok _ => (cSchemaError line
          (claudeCarrierMarkerKey ++ ".toolCanonical") "must be an array")
      match marker.getObjVal? "provenance" with
      | .error _ => pure ()
      | .ok _ =>
          if (cCarrierRawEnvelope? record).isSome then pure ()
          else cSchemaError line (claudeCarrierMarkerKey ++ ".provenance") ("is not a valid envelope-provenance carrier")
      match marker.getObjVal? "identityProvenance" with
      | .error _ => pure ()
      | .ok _ =>
          if (cCarrierIdentityProvenance? record).isSome then pure ()
          else cSchemaError line (claudeCarrierMarkerKey ++ ".identityProvenance") ("is not a valid historical identity carrier")
      match marker.getObjVal? "contentBlocks" with
      | .error _ => pure ()
      | .ok (Json.arr rawIndices) =>
          if rawIndices.isEmpty then
            cSchemaError line (claudeCarrierMarkerKey ++ ".contentBlocks")
              "must not be empty when present"
          else pure ()
          let indices ← rawIndices.toList.zipIdx.mapM (fun (value, memberIdx) =>
            match value.getNat? with
            | .ok index => pure index
            | .error _ => cSchemaError line
                s!"{claudeCarrierMarkerKey}.contentBlocks[{memberIdx}]"
                "must be a natural number")
          if cHasDuplicateNat indices then
            cSchemaError line (claudeCarrierMarkerKey ++ ".contentBlocks")
              "must not contain duplicate indices"
          else pure ()
          let texts : Array String ← match content with
            | Json.str text => pure #[text]
            | Json.arr blocks => blocks.toList.zipIdx.mapM (fun (block, blockIdx) =>
                match block with
                | Json.obj _ =>
                    if cstr block "type" != some "text" then
                      if indices.contains blockIdx then
                        cSchemaError line s!"message.content[{blockIdx}].type"
                          "a marked carrier block must be text"
                      else pure ""
                    else
                      match cstr block "text" with
                      | some text => pure text
                      | none => cSchemaError line s!"message.content[{blockIdx}].text"
                          "is required and must be a string"
                | _ => cSchemaError line s!"message.content[{blockIdx}]"
                    "must be an object") |>.map List.toArray
            | _ => cSchemaError line "message.content" ("must be a string or an array")
          let _ ← indices.mapM (fun blockIdx =>
            match texts[blockIdx]? with
            | none => cSchemaError line
                (claudeCarrierMarkerKey ++ ".contentBlocks")
                s!"index {blockIdx} is out of range for message.content"
            | some text => do
                let _ ← cValidateMarkedCarrierDuplicateMembers line blockIdx text
                if cMarkedConversationCarrierValid role text then pure ()
                else cSchemaError line s!"message.content[{blockIdx}]" s!"is not a valid {role} historical carrier (header, role, schema, and carrier id must agree)")
          pure ()
      | .ok _ => cSchemaError line (claudeCarrierMarkerKey ++ ".contentBlocks") ("must be an array")

private def cValidateImageBlock
    (line : Nat) (path : String) (block : Json) : Except String Unit := do
  let source ← cRequireObject line path "source" block
  let sourceType ← cRequireNonemptyString line (path ++ "source.") "type" source
  match sourceType with
  | "base64" =>
      let _ ← cRequireNonemptyString line (path ++ "source.") "media_type" source
      let _ ← cRequireString line (path ++ "source.") "data" source
      pure ()
  | "url" =>
      let _ ← cRequireNonemptyString line (path ++ "source.") "url" source
      pure ()
  | "file" =>
      let _ ← cRequireNonemptyString line (path ++ "source.") "file_id" source
      pure ()
  | _ => pure ()

private partial def cValidateResultContent
    (line : Nat) (path : String) (content : Json) : Except String Unit :=
  match content with
  | Json.str _ => pure ()
  | Json.arr blocks => do
      let _ ← blocks.toList.zipIdx.mapM (fun (block, blockIdx) => do
        let blockPath := s!"{path}[{blockIdx}]."
        match block with
        | Json.obj _ =>
            let kind ← cRequireNonemptyString line blockPath "type" block
            match kind with
            | "text" =>
                let _ ← cRequireString line blockPath "text" block
                pure ()
            | "image" => cValidateImageBlock line blockPath block
            | _ => pure ()
        | _ => cSchemaError line (path ++ s!"[{blockIdx}]") "must be an object")
      pure ()
  | _ => cSchemaError line path "must be a string or an array"

private def cValidateContentBlocks
    (line : Nat) (dialogueRole : String) (blocks : Array Json) : Except String Unit := do
  let _ ← blocks.toList.zipIdx.mapM (fun (block, blockIdx) => do
    let path := s!"message.content[{blockIdx}]."
    match block with
    | Json.obj _ =>
        let kind ← cRequireNonemptyString line path "type" block
        match kind with
        | "text" =>
            let _ ← cRequireString line path "text" block
            pure ()
        | "thinking" =>
            let _ ← cRequireString line path "thinking" block
            match cobj block "signature" with
            | none | some (Json.str _) => pure ()
            | some _ => cSchemaError line (path ++ "signature") "must be a string"
        | "tool_use" =>
            if dialogueRole == "user" then
              cSchemaError line (path ++ "type")
                "tool_use is not valid in a user dialogue record"
            else
              let _ ← cRequireNonemptyString line path "id" block
              let _ ← cRequireNonemptyString line path "name" block
              let _ ← cRequireObject line path "input" block
              pure ()
        | "tool_result" =>
            if dialogueRole == "assistant" then
              cSchemaError line (path ++ "type")
                "tool_result is not valid in an assistant dialogue record"
            else
              let _ ← cRequireNonemptyString line path "tool_use_id" block
              match cobj block "is_error" with
              | none | some (Json.bool _) => pure ()
              | some _ => cSchemaError line (path ++ "is_error") "must be a boolean"
              match cobj block "content" with
              | none => cSchemaError line (path ++ "content") "is required"
              | some content => cValidateResultContent line (path ++ "content") content
        | "image" => cValidateImageBlock line path block
        | _ => pure ()
    | _ => cSchemaError line s!"message.content[{blockIdx}]" "must be an object")
  pure ()

private def cValidateConversationRecord
    (line : Nat) (kind : String) (j : Json) : Except String Unit := do
  let message ← cRequireObject line "" "message" j
  let role ← cRequireNonemptyString line "message." "role" message
  let compactSummary ←
    match cobj j "isCompactSummary" with
    | none => pure false
    | some (Json.bool value) => pure value
    | some _ => cSchemaError line "isCompactSummary" "must be a boolean"
  if compactSummary && (kind != "user" || role != "user") then
    cSchemaError line "isCompactSummary"
      "is only valid on a user envelope with message.role user"
  else pure ()
  let content ← match cobj message "content" with
  | none => cSchemaError line "message.content" "is required"
  | some content@(Json.str _) =>
      if kind == "assistant" then
        cSchemaError line "message.content" "must be an array for an assistant record"
      else pure content
  | some content@(Json.arr blocks) =>
      if compactSummary then
        cSchemaError line "message.content"
          "must be a string when isCompactSummary is true"
      else
        let _ ← cValidateContentBlocks line (if kind == role then role else "inert") blocks
        pure content
  | some _ => cSchemaError line "message.content" "must be a string or an array"
  cValidateConversationCarrierMarker line kind role content j

private def cValidateGraphIdentity
    (line : Nat) (j : Json) : Except String Unit := do
  let _ ← cRequireUuidString line "" "uuid" j
  let _ ← cRequireUuidString line "" "sessionId" j
  match cobj j "parentUuid" with
  | none => cSchemaError line "parentUuid" "is required"
  | some Json.null => pure ()
  | some (Json.str value) =>
      if claudeUuidValid value then pure ()
      else cSchemaError line "parentUuid" "must be a UUID or null"
  | some _ => cSchemaError line "parentUuid" "must be a string or null"
  match cobj j "forkedFrom" with
  | none => pure ()
  | some fork@(Json.obj _) =>
      let _ ← cRequireUuidString line "forkedFrom." "sessionId" fork
      let _ ← cRequireUuidString line "forkedFrom." "messageUuid" fork
      pure ()
  | some _ => cSchemaError line "forkedFrom" "must be an object"

private def cValidateCarrierTimeProvenance
    (line : Nat) (record : Json) : Except String Unit :=
  match cobj record claudeCarrierMarkerKey with
  | some marker =>
      if cstr marker "protocol" != some claudeCarrierProtocol then pure ()
      else
        match cobj marker "timeProvenance" with
        | none => pure ()
        | some _ =>
            if (cCarrierTimeProvenance? record).isSome then pure ()
            else cSchemaError line
              (claudeCarrierMarkerKey ++ ".timeProvenance")
              "is not a valid agent-convert time provenance carrier"
  | none => pure ()

private def cValidateRecord (j : Json) (index : Nat) : Except String Unit := do
  let line := index + 1
  cValidateCarrierProtocol line j
  cValidateCarrierTimeProvenance line j
  let kind ← cRequireNonemptyString line "" "type" j
  match kind with
  | "user" =>
      let _ ← cValidateGraphIdentity line j
      cValidateConversationRecord line "user" j
  | "assistant" =>
      let _ ← cValidateGraphIdentity line j
      cValidateConversationRecord line "assistant" j
  | "system" =>
      if cCompactionBoundary j then
        let _ ← cValidateGraphIdentity line j
        let _ ← cRequireString line "" "content" j
        let metadata ← cRequireObject line "" "compactMetadata" j
        let _ ← cRequireUuidString line "" "logicalParentUuid" j
        match cobj metadata "preTokens" with
        | none => pure ()
        | some value =>
            match value.getNat? with
            | .ok _ => pure ()
            | .error _ =>
                cSchemaError line "compactMetadata.preTokens" "must be a natural number"
      else if cstr j "subtype" == some "agent_convert_compaction" then
        if (cParseCompactionCarrier? j).isSome then cValidateGraphIdentity line j
        else
          cSchemaError line (claudeCarrierMarkerKey ++ ".compaction")
            "is not a valid agent-convert compaction carrier"
      else if cstr j "subtype" == some "agent_convert_inert" then
        if (cParseInertPayloadCarrier? j).isSome then cValidateGraphIdentity line j
        else
          cSchemaError line (claudeCarrierMarkerKey ++ ".inertPayload")
            "is not a valid agent-convert inert payload carrier"
      else pure ()
  | "attachment" => cValidateGraphIdentity line j
  | "last-prompt" =>
      let _ ← cRequireUuidString line "" "leafUuid" j
      let _ ← cRequireUuidString line "" "sessionId" j
      match cobj j "lastPrompt" with
      | none | some (Json.str _) => pure ()
      | some _ => cSchemaError line "lastPrompt" "must be a string"
  | "agent-convert-provenance" =>
      if (cParseTranscriptProvenanceCarrier? j).isSome then pure ()
      else cSchemaError line (claudeCarrierMarkerKey ++ ".transcriptProvenance") "is not a valid agent-convert transcript provenance carrier"
  | _ => pure ()

/-- Claude 2.1.220+ may insert `compact_boundary` immediately before
`isCompactSummary` without making the boundary the summary's `parentUuid`. -/
private def cAdjacentCompactionBoundary?
    (records : List (Json × Nat)) (summaryIndex : Nat) : Option (Json × Nat) :=
  records.find? (fun (candidate, index) =>
    index + 1 == summaryIndex && cCompactionBoundary candidate &&
      cstr candidate "sessionId" ==
        (records.find? (fun (_, i) => i == summaryIndex) >>= fun (summary, _) =>
          cstr summary "sessionId"))

private def cSummaryLinksBoundary
    (summary : Json) (summaryIndex : Nat) (boundary : Json)
    (records : List (Json × Nat)) : Bool :=
  cstr summary "sessionId" == cstr boundary "sessionId" &&
    (cstr summary "parentUuid" == cstr boundary "uuid" ||
      (cAdjacentCompactionBoundary? records summaryIndex).any (fun (adjacent, _) =>
        cstr adjacent "uuid" == cstr boundary "uuid"))

private def cValidateCompactionLinks
    (records : List (Json × Nat)) : Except String Unit := do
  let _ ← records.mapM (fun (record, index) => do
    let line := index + 1
    if cbool record "isCompactSummary" then
      match cobj record "parentUuid" with
      | some (Json.str parent) =>
          let candidates := records.filter (fun (candidate, _) =>
            cstr candidate "uuid" == some parent && cCompactionBoundary candidate)
          let sameSession := candidates.filter (fun (candidate, _) =>
            cstr candidate "sessionId" == cstr record "sessionId")
          match sameSession with
          | [_] => pure ()
          | [] =>
              match cAdjacentCompactionBoundary? records index with
              | some _ => pure ()
              | none =>
                  if candidates.isEmpty then
                    cSchemaError line "parentUuid" (s!"references missing compact_boundary UUID '{parent}'")
                  else
                    cSchemaError line "parentUuid" (s!"references compact_boundary '{parent}' in a different session")
          | _ => cSchemaError line "parentUuid" (s!"references ambiguous compact_boundary UUID '{parent}'")
      | _ =>
          match cAdjacentCompactionBoundary? records index with
          | some _ => pure ()
          | none =>
              cSchemaError line "parentUuid" "must reference a real compact_boundary when isCompactSummary is true"
    else if cCompactionBoundary record then
      let summaries := records.filter (fun (candidate, candIndex) =>
        cbool candidate "isCompactSummary" &&
          cSummaryLinksBoundary candidate candIndex record records)
      if summaries.length == 1 then pure ()
      else
        let detail :=
          s!"compact_boundary must have exactly one isCompactSummary child, found {summaries.length}"
        cSchemaError line "subtype" detail
    else pure ())
  pure ()

private def cValidateClaudeRecords (records : List Json) : Except String Unit := do
  let indexed := records.zipIdx
  let _ ← indexed.mapM (fun (record, index) => cValidateRecord record index)
  if cTranscriptSourceEnvCount records > 1 then
    .error "malformed Claude session: more than one source-environment carrier is ambiguous and refused"
  cValidateCompactionLinks indexed

private def cArchivedControlJson (control : ClaudeArchivedControl) : Json :=
  Json.mkObj
    ([
      ("kind", Json.str control.envelope.kind),
      ("contentBlock", Json.num (Lean.JsonNumber.fromNat control.sourceBlock)),
      ("rendered", Json.str control.envelope.rendered),
      ("raw", Json.str control.envelope.raw),
      ("record", control.rawRecord)
    ] ++
    (match control.uuid with | some uuid => [("uuid", Json.str uuid)] | none => []) ++
    (match control.ts with | some ts => [("timestamp", Json.str ts)] | none => []))

private def cArchivedRecordJson (record : ClaudeArchivedRecord) : Json :=
  Json.mkObj ([
    ("kind", Json.str record.kind), ("reason", Json.str record.reason),
    ("raw", record.raw)] ++
    (match record.uuid with | some uuid => [("uuid", Json.str uuid)] | none => []) ++
    (match record.role with | some role => [("role", Json.str role)] | none => []) ++
    (match record.ts with | some ts => [("timestamp", Json.str ts)] | none => []))

private def cTranscriptProvenanceCarrier
    (kind : String) (payload : Json) : Json :=
  Json.mkObj [
    ("type", Json.str "agent-convert-provenance"),
    (claudeCarrierMarkerKey, Json.mkObj [
      ("protocol", Json.str claudeCarrierProtocol),
      ("transcriptProvenance", Json.mkObj [
        ("carrier", Json.str "agent-convert.claude-transcript-provenance.v1"),
        ("kind", Json.str kind), ("payload", payload)])])]

private def cSourceEnvCarrierPayload? (rawCarrier : Json) : Option Json := do
  match cParseTranscriptProvenanceCarrier? rawCarrier with
  | some (.sourceEnv _ _) => pure ()
  | _ => none
  let marker ← cobj rawCarrier claudeCarrierMarkerKey
  let carrier ← cobj marker "transcriptProvenance"
  cobj carrier "payload"

private def cClaudeRawSourceEnvCarrier? (t : Transcript) : Option Json := do
  let raw ← t.origin.extras >>= fun extras =>
    cobj extras claudeSourceEnvRawCarrierExtrasKey
  let _ ← cSourceEnvCarrierPayload? raw
  pure raw

/-- Re-emit an accepted source-environment carrier as an open-world envelope.
Unknown record, marker, carrier, and payload fields survive; generated
discriminators and the current typed `EnvInfo` always win for controlled fields. -/
private def cSourceEnvCarrierForExport (t : Transcript) : Json :=
  let rawRecord := (cClaudeRawSourceEnvCarrier? t).getD (Json.mkObj [])
  let rawMarker := (cobj rawRecord claudeCarrierMarkerKey).getD (Json.mkObj [])
  let rawCarrier := (cobj rawMarker "transcriptProvenance").getD (Json.mkObj [])
  let rawPayload := (cobj rawCarrier "payload").getD (Json.mkObj [])
  let currentPayload := (t.origin.extras >>= fun extras =>
    cobj extras "source_env").getD (Json.mkObj [])
  let payload := cOverlayJsonObject
    (cOverlayJsonObject rawPayload currentPayload) (cSourceEnvJson t.env)
  let carrier := cOverlayJsonObject rawCarrier (Json.mkObj [
    ("carrier", Json.str "agent-convert.claude-transcript-provenance.v1"),
    ("kind", Json.str "sourceEnv"), ("payload", payload)])
  let marker := cOverlayJsonObject rawMarker (Json.mkObj [
    ("protocol", Json.str claudeCarrierProtocol),
    ("transcriptProvenance", carrier)])
  cOverlayJsonObject rawRecord (Json.mkObj [
    ("type", Json.str "agent-convert-provenance"),
    (claudeCarrierMarkerKey, marker)])

/-- Build the transcript-level `origin.extras`.

When a source-environment carrier was decoded (`sourceEnv?`), the transcript is a
retargeted Claude artifact, not a native session: the inert source env is kept
under `source_env`, and the target launch identity is set from the *physical*
Claude records (`physicalCwd`/`physicalSession`) so a second export re-emits the
same target without ever consulting the restored source env. -/
private def cTranscriptExtras
    (controls : List ClaudeArchivedControl) (archived : List ClaudeArchivedRecord)
    (lastPrompt : Option Json)
    (sourceEnv? : Option EnvInfo := none)
    (sourceEnvCarrier? : Option Json := none)
    (physicalCwd physicalSession physicalTimestamp : Option String := none) : Option Json :=
  let fields : List (String × Json) :=
    (if controls.isEmpty then [] else [
      ("raw_control_messages", Json.arr (controls.map cArchivedControlJson).toArray)]) ++
    (if archived.isEmpty then [] else [
      ("raw_inert_records", Json.arr (archived.map cArchivedRecordJson).toArray)]) ++
    (match lastPrompt with
     | some record => [("raw_last_prompt", record)]
     | none => []) ++
    (match sourceEnv? with
     | some env => [
         ("source_env", (sourceEnvCarrier? >>= cSourceEnvCarrierPayload?).getD
           (cSourceEnvJson env))] ++
         (match sourceEnvCarrier? with
          | some raw => [(claudeSourceEnvRawCarrierExtrasKey, raw)]
          | none => [])
     | none => []) ++
    (match sourceEnv?, physicalCwd with
     | some _, some cwd => [("target_cwd", Json.str cwd)]
     | _, _ => []) ++
    (match sourceEnv?, physicalSession with
     | some _, some session => [("target_session_id", Json.str session)]
     | _, _ => []) ++
    (match sourceEnv?, physicalTimestamp with
     | some _, some timestamp => [("target_timestamp", Json.str timestamp)]
     | _, _ => []) ++
    -- The reader-version assertion is not serialized into the records, so a
    -- retargeted artifact re-asserts the validation build on reimport. Any re-emit
    -- targets that same reader, keeping a second hop deterministic.
    (match sourceEnv? with
     | some _ => [("target_harness_version", Json.str claudeTargetValidationBuild)]
     | none => [])
  if fields.isEmpty then none else some (Json.mkObj fields)

private def cResumableRecord (j : Json) : Bool :=
  (cConversationKind? j).isSome || (cParseCompactionCarrier? j).isSome ||
    (cParseInertPayloadCarrier? j).isSome

private def cGraphCandidates
    (records : List (Json × Nat)) (uuid sessionId : String) : List (Json × Nat) :=
  let addressable := records.filter (fun (record, _) =>
    cGraphRecord record && cstr record "uuid" == some uuid &&
      cstr record "sessionId" == some sessionId)
  let semantic := addressable.filter (fun (record, _) => cSemanticGraphRecord record)
  if semantic.isEmpty then addressable else semantic

private def cAllGraphCandidates
    (records : List (Json × Nat)) (uuid : String) : List (Json × Nat) :=
  let addressable := records.filter (fun (record, _) =>
    cGraphRecord record && cstr record "uuid" == some uuid)
  let semantic := addressable.filter (fun (record, _) => cSemanticGraphRecord record)
  if semantic.isEmpty then addressable else semantic

private def cHasExternalLineage (record : Json) : Bool :=
  match cobj record "forkedFrom" with
  | some fork@(Json.obj _) =>
      cstr fork "messageUuid" == cstr record "uuid" &&
        cstr fork "sessionId" != cstr record "sessionId"
  | _ => false

private partial def cValidateSelectedPath
    (records : List (Json × Nat)) (fuel : Nat) (current : Json × Nat)
    (seen : List String := []) : Except String (List (Json × Nat) × List ImportNote) := do
  let (record, index) := current
  let line := index + 1
  if fuel == 0 then
    cSchemaError line "parentUuid" "exceeded graph depth while validating ancestry"
  else
    let uuid ← cRequireNonemptyString line "" "uuid" record
    let sessionId ← cRequireNonemptyString line "" "sessionId" record
    if seen.contains uuid then
      cSchemaError line "parentUuid" s!"closes a cycle at UUID '{uuid}'"
    else pure ()
    let selfCandidates := cGraphCandidates records uuid sessionId
    if selfCandidates.length != 1 then
      cSchemaError line "uuid" (s!"is ambiguous in the selected graph: found {selfCandidates.length} occurrences of '{uuid}'")
    else pure ()
    -- Claude 2.1.220+ may place compact_boundary immediately before
    -- isCompactSummary while leaving parentUuid on the prior conversational
    -- node. Treat that adjacent boundary as the effective soft-cut parent so
    -- pre-compaction history is not pulled into the active leaf walk.
    let adjacentBoundary? :=
      if cbool record "isCompactSummary" then
        cAdjacentCompactionBoundary? records index
      else none
    match cobj record "parentUuid", adjacentBoundary? with
    | some Json.null, some boundary =>
        let (ancestors, notes) ←
          cValidateSelectedPath records (fuel - 1) boundary (uuid :: seen)
        pure (current :: ancestors, ({
          kind := AssumptionKind.other "adjacentCompactionBoundary"
          loc := some uuid
          detail := "isCompactSummary paired with the immediately preceding compact_boundary \
            (Claude 2.1.220+ soft cut); parentUuid was null" } : ImportNote) :: notes)
    | some Json.null, none => pure ([current], [])
    | some (Json.str parentUuid), adjacent =>
        let sameSession := cGraphCandidates records parentUuid sessionId
        let parentIsBoundary := sameSession.any (fun (candidate, _) =>
          cCompactionBoundary candidate)
        match adjacent, parentIsBoundary with
        | some boundary, false =>
            let (ancestors, notes) ←
              cValidateSelectedPath records (fuel - 1) boundary (uuid :: seen)
            pure (current :: ancestors, ({
              kind := AssumptionKind.other "adjacentCompactionBoundary"
              loc := some uuid
              detail := s!"isCompactSummary paired with the immediately preceding compact_boundary \
                (Claude 2.1.220+ soft cut); parentUuid '{parentUuid}' names the prior conversational node" } : ImportNote) :: notes)
        | _, _ =>
            match sameSession with
            | [parent] =>
                let (ancestors, notes) ←
                  cValidateSelectedPath records (fuel - 1) parent (uuid :: seen)
                pure (current :: ancestors, notes)
            | [] =>
                if cHasExternalLineage record then
                  pure ([current], [({
                    kind := AssumptionKind.other "externalLineage"
                    loc := some uuid
                    detail := s!"parentUuid '{parentUuid}' is external to this file/session; \
                      forkedFrom retained verbatim and no local edge was invented" } : ImportNote)])
                else
                  match cAllGraphCandidates records parentUuid with
                  | foreign :: _ =>
                      let foreignSession := (cstr foreign.1 "sessionId").getD "<missing>"
                      cSchemaError line "parentUuid" (s!"references UUID '{parentUuid}' in session '{foreignSession}', expected '{sessionId}'")
                  | [] =>
                      -- A parent UUID absent from the file is normal in real
                      -- sessions: a live transcript can reference a record that was
                      -- never written, or was written by another process. Refusing
                      -- discarded an otherwise intact multi-megabyte session over a
                      -- single edge — measured: 1 dangling ref in 1323 records.
                      -- Loom's rule for orphans elsewhere (`CallRef.unresolved`) is
                      -- representable, flagged, honest; parent edges get the same.
                      -- The edge is not invented: the entry becomes a thread root
                      -- and the assumption is logged.
                      pure ([current], [({
                        kind := AssumptionKind.other "danglingParent"
                        loc := some uuid
                        detail := s!"parentUuid '{parentUuid}' is not present in this file; \
                          treated as a thread root and no local edge was invented" } : ImportNote)])
            | _ => cSchemaError line "parentUuid" (s!"references ambiguous UUID '{parentUuid}' in session '{sessionId}'")
    | _, _ => cSchemaError line "parentUuid" "must be a string or null"

private def cNewestIndexedLine
    (best : Option (Json × Nat)) (cand : Json × Nat) : Option (Json × Nat) :=
  match best with
  | none => some cand
  | some prior => if clTs prior.1 < clTs cand.1 then some cand else some prior

private def cValidateLastPromptTarget
    (records : List (Json × Nat)) :
    Except String (Option ((Json × Nat) × (Json × Nat))) := do
  let pointers := records.filter (fun (record, _) =>
    cstr record "type" == some "last-prompt")
  match pointers.getLast? with
  | none => pure none
  | some pointer@(record, index) =>
    let line := index + 1
    let leafUuid ← cRequireNonemptyString line "" "leafUuid" record
    let pointerSession ← cRequireNonemptyString line "" "sessionId" record
    match cGraphCandidates records leafUuid pointerSession with
    | [target] => pure (some (pointer, target))
    | [] =>
        match cAllGraphCandidates records leafUuid with
        | foreign :: _ =>
            let targetSession := (cstr foreign.1 "sessionId").getD "<missing>"
            cSchemaError line "leafUuid" (s!"references record in session '{targetSession}', expected '{pointerSession}'")
        | [] => cSchemaError line "leafUuid" s!"references missing UUID '{leafUuid}'"
    | _ => cSchemaError line "leafUuid" (s!"references ambiguous UUID '{leafUuid}'")

/-- Claude Code JSONL → Loom IR. Reconstructs the active thread by the TS oracle's
leaf-walk (branch- and sidechain-aware), re-attributes tool results to
`environment`, chains the kept lines sequentially, and emits an `Origin`
(format `claudeCode`, `rawId := uuid`) per entry. -/
def importClaudeCode (text : String) : Except String Transcript := do
  let parsed ← cParseClaudeJsonLines text
  let _ ← cValidateClaudeRecords parsed
  match parsed with
  | [] => .error "empty session"
  | _ =>
    let indexed := parsed.zipIdx
    let lastPrompt ← cValidateLastPromptTarget indexed
    let chatLines := indexed.filter (fun (record, _) => cResumableRecord record)
    let hasSameSessionChild := fun (record : Json) =>
      match cstr record "uuid", cstr record "sessionId" with
      | some uuid, some sessionId => indexed.any (fun (child, _) =>
          cSemanticGraphRecord child && cstr child "parentUuid" == some uuid &&
            cstr child "sessionId" == some sessionId)
      | _, _ => false
    -- Leaves = chat lines nothing points to; prefer the newest non-sidechain one,
    -- else the newest leaf, else the last chat line (claudeCode.ts:598-601).
    let leaves := chatLines.filter (fun (record, _) => !(hasSameSessionChild record))
    let nonSide := leaves.filter (fun (record, _) => !(cbool record "isSidechain"))
    let guessedLeaf : Option (Json × Nat) :=
      ((nonSide.foldl cNewestIndexedLine none).orElse
        (fun _ => leaves.foldl cNewestIndexedLine none)).orElse
        (fun _ => chatLines.getLast?)
    let leaf ← match lastPrompt.map (fun pair => pair.2) |>.orElse (fun _ => guessedLeaf) with
      | some value => pure value
      | none => .error "Claude session contains no resumable user, assistant, or compaction record"
    -- Validate and materialize only the authoritative ancestry. Duplicate UUIDs
    -- in unrelated inert/history records are archived by occurrence and cannot
    -- poison the selected graph.
    let (selectedLeafToRoot, graphNotes) ←
      cValidateSelectedPath indexed parsed.length leaf
    let selectedRootToLeaf := selectedLeafToRoot.reverse
    let active := selectedRootToLeaf.filterMap (fun (record, _) =>
      if cPathRecord record then some record else none)
    let selectedIndices := selectedLeafToRoot.map Prod.snd
    let byUuid : List (String × Json) := selectedLeafToRoot.filterMap (fun (record, _) =>
      (cstr record "uuid").map (fun uuid => (uuid, record)))
    let sid := cstr leaf.1 "sessionId"
    let stamped := parsed.find? (fun record =>
      cstr record "sessionId" == sid && (cstr record "cwd").isSome)
    let cwd := stamped.bind (fun record => cstr record "cwd")
    let decodedProvenance := parsed.filterMap cParseTranscriptProvenanceCarrier?
    let decodedControls := decodedProvenance.filterMap (fun
      | .control value => some value
      | _ => none)
    let decodedRecords := decodedProvenance.filterMap (fun
      | .record value => some value
      | _ => none)
    -- A single inert source-environment carrier (duplicates already refused by
    -- `cValidateClaudeRecords`). When present, this transcript is a retargeted
    -- Claude artifact: source `EnvInfo` is restored verbatim below and the target
    -- launch identity is taken from the physical records, never from the carrier.
    let sourceEnv? := cTranscriptSourceEnv? parsed
    let sourceEnvCarrier? := cTranscriptSourceEnvCarrier? parsed
    let authoritativePointerIndex := lastPrompt.map (fun pair => pair.1.2)
    let folded0 := active.foldl (stepLine byUuid) {
      protos := #[], tmap := [], omap := [], matchedCalls := [],
      controls := decodedControls.toArray, archived := decodedRecords.toArray }
    let leafUuid := cstr leaf.1 "uuid"
    let representedLeafUuid := folded0.protos.back?.bind (fun proto => proto.uuid)
    let needsAuthoritativeLeafCarrier :=
      lastPrompt.isSome && representedLeafUuid != leafUuid
    let folded :=
      if needsAuthoritativeLeafCarrier then
        { folded0 with protos := folded0.protos.push (mkProto
            (cstr leaf.1 "uuid") (cstr leaf.1 "parentUuid") (cstr leaf.1 "timestamp")
            (cAuthoritativeLeafPayload leaf.1) (rawEnvelope := some leaf.1)
            -- Graph bridges (attachment leaves, etc.) are not dialogue; keep them
            -- historical so flat targets can retain them via inert carriers
            -- instead of refusing dropOtherRoles.
            (unverifiedCarrier := true)) }
      else folded0
    let archivedRecords0 := indexed.filterMap (fun (record, index) =>
      match cParseTranscriptProvenanceCarrier? record with
      | some _ => none
      | none =>
          if cstr record "type" == some "last-prompt" &&
              authoritativePointerIndex == some index then none else
          if needsAuthoritativeLeafCarrier && index == leaf.2 then none else
          match cArchivedRecordReason? record with
          | some reason => some (cMkArchivedRecord record reason)
          | none =>
              if cGraphRecord record &&
                  !(selectedIndices.contains index) then
                some (cMkArchivedRecord record
                  "record is outside the authoritative active branch; retained as inert provenance")
              else none)
    let folded := { folded with archived := (decodedRecords ++ archivedRecords0).toArray }
    let protos0 := folded.protos.toList
    let archivedControls := folded.controls.toList
    let archivedRecords := folded.archived.toList
    -- Unique rawId per entry. A multi-block source line (several tool_results, or
    -- text+tool_result) emits several protos sharing ONE source uuid; both the pi
    -- and claude exporters key entry ids off `rawId`, so a shared uuid collapses two
    -- pi ids into one and the parent map then resolves a child to itself. Suffix the
    -- 2nd+ occurrence (`uuid#k`) — matching the TS oracle minting a fresh id per
    -- entry (claudeCode.ts:636) — which also makes multi-result lines round-trip.
    let uuids : List (Option String) := protos0.map (·.uuid)
    let protos : List Proto := protos0.zipIdx.map (fun (p, i) =>
      match p.uuid with
      | none => p
      | some u =>
          let prior := ((uuids.take i).filter (fun x => x == some u)).length
          if prior == 0 then p else { p with uuid := some s!"{u}#{prior}" })
    -- Sequential chaining: parent = previous kept entry (the TS `parentId` link),
    -- so `normalize` sees the same linear thread. Always strictly earlier (normal
    -- form), and it subsumes the multi-result-line re-chaining the map-lookup missed.
    let entries := protos.zipIdx.map (fun (p, i) =>
      ({ parent := if i == 0 then none else some (i - 1),
         thread := 0,
         time := p.timeOverride.getD
           (p.ts.map recordedTimeFromIso8601 |>.getD Time.absent),
         payload := p.payload,
         origin := { format := Format.claudeCode, sourceRef := s!"active{i}",
                     rawId := p.uuid,
                     extras := cProtoExtras p },
         disposition := if p.unverifiedCarrier || !p.carrierBlocks.isEmpty then
           .historicalUnverified else .native } : Entry))
    -- Re-attribution and control removal are separate, auditable judgments.
    -- Controls remain readable here but never acquire a conversational payload.
    let roleNotes : List ImportNote := protos.flatMap (fun p =>
      match p.payload with
      | Payload.envMsg _ =>
          [({ kind := AssumptionKind.roleCoerced, loc := p.uuid,
              detail := "tool_result serialized inside a user-role line; \
                         authorship re-attributed to environment" } : ImportNote)]
      | _ => [])
    let carrierNotes : List ImportNote := protos.filterMap (fun p =>
      if p.unverifiedCarrier || !p.carrierBlocks.isEmpty then some ({
        kind := AssumptionKind.other "unverifiedAgentConvertCarrier"
        loc := p.uuid
        detail := "in-band agent-convert carrier decoded as historical, unverified provenance; it cannot authenticate native Claude execution or compaction" }
        : ImportNote) else none)
    let controlNotes : List ImportNote := archivedControls.map (fun control =>
      ({ kind := AssumptionKind.contentSkipped, loc := cControlLoc control,
         detail := s!"Claude synthetic-user {control.envelope.kind} control archived \
                      outside conversational entries; exact raw wrapper retained in \
                      transcript Origin.extras.\n{control.envelope.rendered}" } : ImportNote))
    let archivedNotes : List ImportNote := archivedRecords.map (fun record =>
      ({ kind := AssumptionKind.contentSkipped, loc := record.uuid,
         detail := record.reason ++ "; exact record retained in transcript Origin.extras" }
        : ImportNote))
    let leafNotes : List ImportNote :=
      if lastPrompt.isSome then [] else
        [({ kind := AssumptionKind.activeLeafGuessed,
            loc := cstr leaf.1 "uuid",
            detail := "no last-prompt resume pointer was present; selected newest non-sidechain leaf" }
          : ImportNote)]
    let sourceEnvNotes : List ImportNote :=
      match sourceEnv? with
      | some _ => [({
          kind := AssumptionKind.other "sourceEnvironmentRestored"
          loc := none
          detail := "inert source-environment carrier decoded; source EnvInfo restored as provenance, target launch identity taken from the physical Claude records" }
          : ImportNote)]
      | none => []
    let notes := roleNotes ++ carrierNotes ++ controlNotes ++ archivedNotes ++
      graphNotes ++ leafNotes ++ sourceEnvNotes
    let n := entries.length
    -- Retargeted artifacts restore the inert source env; native sessions keep the
    -- physical record identity as their env. The target launch identity is always
    -- the physical records (`cwd`/`sid`), carried in `origin.extras` when retargeted.
    let env : EnvInfo := match sourceEnv? with
      | some sourceEnv => sourceEnv
      | none => { cwd := cwd, sessionId := sid }
    let physicalTimestamp := stamped.bind (fun record => cstr record "timestamp")
    pure {
      threads := #[{ kind := ThreadKind.main }],
      entries := entries.toArray,
      env := env,
      activeLeaf := if n == 0 then none else some (n - 1),
      importNotes := notes,
      origin := { format := Format.claudeCode, sourceRef := "importClaudeCode",
                  rawId := sid,
                  extras := cTranscriptExtras archivedControls archivedRecords
                    (lastPrompt.map (fun pair => pair.1.1)) sourceEnv?
                    sourceEnvCarrier? cwd sid physicalTimestamp }
    }

/-! ## Target policy: Codex tools are historical in Claude

Codex and Claude do not share a trustworthy executable tool registry. A Codex
tool lifecycle is therefore rendered as readable history, never as resumable
Claude `tool_use` / `tool_result` state. The transformation is data-preserving:
it changes only the role/block constructors used for target rendering, and the
carrier records retain every field needed to reconstruct the original IR. -/

structure ClaudeHistoricalToolCounts where
  calls   : Nat
  results : Nat
  deriving Repr, DecidableEq

private def cToolResultCount (t : Transcript) : Nat :=
  t.entries.toList.foldl (fun total entry =>
    total + match entry.payload with
      | .envMsg blocks => blocks.countP (fun
          | .toolResult _ _ _ => true
          | _ => false)
      | _ => 0) 0

/-- Convert every tool call and every recorded tool result in a Codex-origin
transcript to occurrence-addressed, versioned text carriers for Claude. Closed
and open calls follow the same policy; no result is synthesized. Non-Codex
transcripts are returned unchanged. -/
def historicalizeCodexToolsForClaude
    (t : Transcript) : Transcript × ClaudeHistoricalToolCounts :=
  if t.origin.format != Format.codexCli then
    (t, { calls := 0, results := 0 })
  else
    let entries := t.entries.toList.zipIdx.map (fun (entry, entryIdx) =>
      match entry.payload with
      | .assistantMsg blocks =>
          let carrierIndices := blocks.zipIdx.filterMap (fun (block, blockIdx) =>
            match block with
            | .toolCall _ _ _ => some blockIdx
            | _ => none)
          let historicalBlocks := blocks.zipIdx.map (fun (block, blockIdx) =>
            match block with
            | .toolCall name args rawId =>
                .text (cHistoricalToolCallCarrierTextAt entryIdx blockIdx
                  name args rawId)
            | other => other)
          if carrierIndices.isEmpty then entry else
            let entry := { entry with payload := Payload.assistantMsg historicalBlocks, disposition := .historicalUnverified }
            { entry with origin := cMarkOriginCarrierBlocks entry.origin carrierIndices }
      | .envMsg blocks =>
          let carrierIndices := blocks.zipIdx.filterMap (fun (block, blockIdx) =>
            match block with
            | .toolResult _ _ _ | .unmodeled _ _ => some blockIdx)
          if carrierIndices.isEmpty then entry else
            let historicalBlocks : List UserBlock := blocks.zipIdx.map (fun (block, blockIdx) =>
              match block with
              | .toolResult call content error =>
                  .text (claudeHistoricalToolResultCarrierText t entryIdx blockIdx
                    call content error)
              | .unmodeled label raw =>
                  .text (claudeUnmodeledEnvCarrierText label raw))
            let entry := { entry with payload := Payload.userMsg historicalBlocks, disposition := .historicalUnverified }
            { entry with origin := cMarkOriginCarrierBlocks entry.origin carrierIndices }
      | _ => entry)
    ({ t with entries := entries.toArray },
      { calls := Loom.Ops.callSites t |>.length, results := cToolResultCount t })

/-- Entry point used by the CLI. Carries ONLY genuinely open (unpaired) tool
calls, for every source format alike.

Claude's API requires each `tool_use` to be matched by a `tool_result`, so an
unpaired call cannot be emitted natively and must become a carrier — that is a
real target constraint, not a provenance judgement. Paired calls are left
alone and render natively.

Previously this delegated Codex-origin transcripts to
`historicalizeCodexToolsForClaude`, which rewrote *every* call and result to
prose and stamped `historicalUnverified`, pre-degrading the transcript before
the exporter ever ran. That made the Codex path lossy regardless of exporter
policy (`LoomOps.Interop`, principle P1). -/
def historicalizeOpenToolCallsForClaude (t : Transcript) : Transcript × Nat :=
    let anchorSites := t.threads.toList.filterMap (fun thread =>
      match thread.kind with
      | .sidechain (.resolved entry block) => some (entry, block)
      | _ => none)
    -- A sidechain sidecar is the recorded outcome of its spawning call. Keep
    -- that call native so sidecar metadata can continue to address it.
    let opens := (Loom.Ops.openCalls t).filter (fun site => !anchorSites.contains site)
    let entries := t.entries.toList.zipIdx.map (fun (entry, entryIdx) =>
      match entry.payload with
      | .assistantMsg blocks =>
          let carrierIndices := blocks.zipIdx.filterMap (fun (_, blockIdx) =>
            if opens.contains (entryIdx, blockIdx) then some blockIdx else none)
          let historicalBlocks := blocks.zipIdx.map (fun (block, blockIdx) =>
            if opens.contains (entryIdx, blockIdx) then
              match block with
              | .toolCall name args rawId =>
                  .text (cHistoricalToolCallCarrierTextAt entryIdx blockIdx
                    name args rawId)
              | other => other
            else block)
          if carrierIndices.isEmpty then entry else
            let entry := { entry with payload := Payload.assistantMsg historicalBlocks, disposition := .historicalUnverified }
            { entry with origin := cMarkOriginCarrierBlocks entry.origin carrierIndices }
      | _ => entry)
    ({ t with entries := entries.toArray }, opens.length)

/-! ## Actuator: the only IO. -/

/-- Read a Claude Code session file from disk into the IR. -/
def importClaudeCodeFile (path : System.FilePath) : IO (Except String Transcript) := do
  let text ← IO.FS.readFile path
  pure (importClaudeCode text)

/-! ## Synthetic-user control-envelope fixtures (local pins, no TS golden)

These are structure-only synthetic fixtures. They exercise the census-observed
shapes without embedding any real session contents or changing the historical
cross-parity fixture below. -/

structure ClaudeControlEnvelopeFixture where
  name     : String
  kind     : String
  source   : String
  rendered : String
  deriving Repr, DecidableEq, Inhabited

def claudeControlCommandRaw : String :=
  "<command-name>/model</command-name>\n            " ++
  "<command-message>model</command-message>\n            " ++
  "<command-args>opus</command-args>"

def claudeControlCommandCompactRaw : String :=
  "<command-name>/goal</command-name>\n" ++
  "<command-message>goal</command-message>\n" ++
  "<command-args>preserve the conversation</command-args>"

def claudeControlTaskCompactRaw : String := String.intercalate "\n" [
  "<task-notification>",
  "<task-id>b1</task-id>",
  "<tool-use-id>tu1</tool-use-id>",
  "<output-file>/tmp/b1.output</output-file>",
  "<status>completed</status>",
  "<summary>Background command completed</summary>",
  "</task-notification>"
]

def claudeControlTaskCompactNoToolRaw : String := String.intercalate "\n" [
  "<task-notification>",
  "<task-id>b2</task-id>",
  "<output-file>/tmp/b2.output</output-file>",
  "<status>stopped</status>",
  "<summary>No completion record was found</summary>",
  "</task-notification>"
]

def claudeControlTaskDetailedRaw : String := String.intercalate "\n" [
  "<task-notification>",
  "<task-id>a1</task-id>",
  "<tool-use-id>tu2</tool-use-id>",
  "<output-file>/tmp/a1.output</output-file>",
  "<status>completed</status>",
  "<summary>Agent finished</summary>",
  "<note>This task may notify more than once.</note>",
  "<result>First line\nSecond line &amp; retained</result>",
  "<usage><subagent_tokens>120</subagent_tokens><tool_uses>7</tool_uses>" ++
    "<duration_ms>4500</duration_ms></usage>",
  "</task-notification>"
]

def claudeControlTaskDetailedNoOptionalsRaw : String := String.intercalate "\n" [
  "<task-notification>",
  "<task-id>a2</task-id>",
  "<output-file>/tmp/a2.output</output-file>",
  "<status>completed</status>",
  "<summary>Agent completed</summary>",
  "<result>Done</result>",
  "<usage><subagent_tokens>3</subagent_tokens><tool_uses>1</tool_uses>" ++
    "<duration_ms>25</duration_ms></usage>",
  "</task-notification>"
]

def claudeControlTaskEventRaw : String := String.intercalate "\n" [
  "<task-notification>",
  "<task-id>m1</task-id>",
  "<summary>Monitor event</summary>",
  "<event>state=running</event>",
  "If this event is something the user would act on now, send a PushNotification. " ++
    "Routine or benign output doesn't need one.",
  "</task-notification>"
]

def claudeControlSystemReminderRaw : String :=
  "<system-reminder>\nThe user named this session \"fixture\".\n</system-reminder>"

def claudeControlSystemReminderCompactRaw : String :=
  "<system-reminder>Use normalized context.</system-reminder>"

def claudeControlCaveatRaw : String :=
  "<local-command-caveat>Caveat text.</local-command-caveat>"

def claudeControlStdoutRaw : String :=
  "<local-command-stdout>Set model to Opus</local-command-stdout>"

def claudeControlBashInputRaw : String := "<bash-input>pwd</bash-input>"

def claudeControlBashOutputRaw : String :=
  "<bash-stdout>/work</bash-stdout><bash-stderr>warning</bash-stderr>"

def claudeControlPersistedBashOutputRaw : String :=
  "<bash-stdout><persisted-output>\nsaved preview\n</persisted-output></bash-stdout>" ++
  "<bash-stderr></bash-stderr>"

def claudeControlIdeRaw : String :=
  "<ide_opened_file>The user opened /work/Main.lean.</ide_opened_file>"

def claudeControlIdeSelectionRaw : String :=
  "<ide_selection>The user selected lines 10-12 in /work/Main.lean.</ide_selection>"

def claudeControlEnvelopeFixtures : List ClaudeControlEnvelopeFixture := [
  { name := "command", kind := "command", source := claudeControlCommandRaw,
    rendered := String.intercalate "\n"
      ["Command", "Name: /model", "Message: model", "Arguments: opus"] },
  { name := "command-compact", kind := "command", source := claudeControlCommandCompactRaw,
    rendered := String.intercalate "\n"
      ["Command", "Name: /goal", "Message: goal",
       "Arguments: preserve the conversation"] },
  { name := "task-compact", kind := "task-notification-compact",
    source := claudeControlTaskCompactRaw,
    rendered := String.intercalate "\n"
      ["Task notification", "Task ID: b1", "Tool use ID: tu1",
       "Output file: /tmp/b1.output", "Status: completed",
       "Summary: Background command completed"] },
  { name := "task-compact-no-tool", kind := "task-notification-compact",
    source := claudeControlTaskCompactNoToolRaw,
    rendered := String.intercalate "\n"
      ["Task notification", "Task ID: b2", "Output file: /tmp/b2.output",
       "Status: stopped", "Summary: No completion record was found"] },
  { name := "task-detailed", kind := "task-notification-detailed",
    source := claudeControlTaskDetailedRaw,
    rendered := String.intercalate "\n"
      ["Task notification", "Task ID: a1", "Tool use ID: tu2",
       "Output file: /tmp/a1.output", "Status: completed", "Summary: Agent finished",
       "Note: This task may notify more than once.",
       "Result: First line\nSecond line &amp; retained", "Usage:",
       "  Subagent tokens: 120", "  Tool uses: 7", "  Duration (ms): 4500"] },
  { name := "task-detailed-no-optionals", kind := "task-notification-detailed",
    source := claudeControlTaskDetailedNoOptionalsRaw,
    rendered := String.intercalate "\n"
      ["Task notification", "Task ID: a2", "Output file: /tmp/a2.output",
       "Status: completed", "Summary: Agent completed", "Result: Done", "Usage:",
       "  Subagent tokens: 3", "  Tool uses: 1", "  Duration (ms): 25"] },
  { name := "task-event", kind := "task-notification-event",
    source := claudeControlTaskEventRaw,
    rendered := String.intercalate "\n"
      ["Task notification", "Task ID: m1", "Summary: Monitor event",
       "Event: state=running",
       "Instruction: If this event is something the user would act on now, send a " ++
         "PushNotification. Routine or benign output doesn't need one."] },
  { name := "system-reminder", kind := "system-reminder",
    source := claudeControlSystemReminderRaw,
    rendered := "System reminder:\nThe user named this session \"fixture\"." },
  { name := "system-reminder-compact", kind := "system-reminder",
    source := claudeControlSystemReminderCompactRaw,
    rendered := "System reminder:\nUse normalized context." },
  { name := "local-command-caveat", kind := "local-command-caveat",
    source := claudeControlCaveatRaw,
    rendered := "Local command caveat:\nCaveat text." },
  { name := "local-command-stdout", kind := "local-command-stdout",
    source := claudeControlStdoutRaw,
    rendered := "Local command stdout:\nSet model to Opus" },
  { name := "bash-input", kind := "bash-input", source := claudeControlBashInputRaw,
    rendered := "Bash input:\npwd" },
  { name := "bash-output", kind := "bash-output", source := claudeControlBashOutputRaw,
    rendered := "Bash stdout:\n/work\nBash stderr:\nwarning" },
  { name := "bash-output-persisted", kind := "bash-output",
    source := claudeControlPersistedBashOutputRaw,
    rendered := "Bash stdout:\nPersisted output:\nsaved preview\nBash stderr:\n" },
  { name := "ide-opened-file", kind := "ide-opened-file", source := claudeControlIdeRaw,
    rendered := "IDE opened file:\nThe user opened /work/Main.lean." },
  { name := "ide-selection", kind := "ide-selection",
    source := claudeControlIdeSelectionRaw,
    rendered := "IDE selection:\nThe user selected lines 10-12 in /work/Main.lean." }
]

def claudeKnownControlTagNames : List String := [
  "command-name", "command-message", "command-args", "task-notification",
  "task-id", "tool-use-id", "output-file", "status", "summary", "note",
  "result", "usage", "subagent_tokens", "tool_uses", "duration_ms", "event",
  "system-reminder", "local-command-caveat", "local-command-stdout", "bash-input",
  "bash-stdout", "bash-stderr", "persisted-output", "ide_opened_file", "ide_selection"
]

private def cNoKnownControlTags (s : String) : Bool :=
  claudeKnownControlTagNames.all (fun tag =>
    !(s.contains s!"<{tag}>") && !(s.contains s!"</{tag}>"))

-- Every complete observed shape is recognized and rendered exactly as pinned.
example :
    claudeControlEnvelopeFixtures.all (fun fixture =>
      match normalizeClaudeControlEnvelope? fixture.source with
      | some envelope => envelope.kind == fixture.kind
          && envelope.rendered == fixture.rendered && envelope.raw == fixture.source
      | none => false) = true := by native_decide

-- Rendering removes every structural Claude control tag, including nested task
-- usage fields and persisted-output wrappers.
example :
    claudeControlEnvelopeFixtures.all (fun fixture =>
      match normalizeClaudeControlEnvelope? fixture.source with
      | some envelope => cNoKnownControlTags envelope.rendered
      | none => false) = true := by native_decide

def claudeOrdinaryXmlSamples : List String := [
  "<root><task-notification>literal XML</task-notification></root>",
  "prefix <bash-input>pwd</bash-input>",
  "prefix <system-reminder>embedded reminder</system-reminder>",
  "<command-name>/x</command-name>\n  <command-message>different</command-message>\n  " ++
    "<command-args></command-args>",
  "<task-notification>\n<task-id>x</task-id>\n<summary>not an observed full shape</summary>\n" ++
    "</task-notification>"
]

-- Partial, embedded, or merely similar XML is not recognized.
example :
    claudeOrdinaryXmlSamples.all (fun source =>
      (normalizeClaudeControlEnvelope? source).isNone) = true := by native_decide

def claudeControlOrdinaryString : String :=
  "<root><task-notification>literal XML</task-notification></root>"

def claudeControlOrdinaryTextBlock : String :=
  "const x = \"<bash-input>pwd</bash-input>\";"

def claudeControlUnknownTagText : String :=
  "<future-runtime-context>keep this as user text</future-runtime-context>"

private def cClaudeFixtureTimestamp : String → String
  | "T0" => "2026-07-20T00:00:00.000Z"
  | "T1" => "2026-07-20T00:00:01.000Z"
  | "T2" => "2026-07-20T00:00:02.000Z"
  | "T3" => "2026-07-20T00:00:03.000Z"
  | "T4" => "2026-07-20T00:00:04.000Z"
  | "T5" => "2026-07-20T00:00:05.000Z"
  | "T6" => "2026-07-20T00:00:06.000Z"
  | "T7" => "2026-07-20T00:00:07.000Z"
  | "T8" => "2026-07-20T00:00:08.000Z"
  | "T9" => "2026-07-20T00:00:09.000Z"
  | timestamp => timestamp

private def cClaudeFixtureUuid (label : String) : String :=
  if claudeUuidValid label then label
  else cGeneratedClaudeUuid "agent-convert.claude.test-fixture"
    (String.hash label).toNat

private def cReplaceJsonField (j : Json) (key : String) (value : Json) : Json :=
  match j with
  | Json.obj fields => Json.obj (fields.insert key value)
  | other => other

private def cUuidFixtureField (j : Json) (key : String) : Json :=
  match cstr j key with
  | some value => cReplaceJsonField j key (Json.str (cClaudeFixtureUuid value))
  | none => j

private def cUuidFixtureRecord (j : Json) : Json :=
  let record := ["uuid", "parentUuid", "sessionId", "leafUuid", "logicalParentUuid"].foldl
    cUuidFixtureField j
  match cobj record "forkedFrom" with
  | some fork@(Json.obj _) =>
      let fork := ["sessionId", "messageUuid"].foldl cUuidFixtureField fork
      cReplaceJsonField record "forkedFrom" fork
  | _ => record

private def cUuidFixtureSource (source : String) : String :=
  String.intercalate "\n" (source.splitOn "\n" |>.map (fun line =>
    if line.isEmpty then line else
      match Json.parse line with
      | .ok record@(Json.obj _) => (cUuidFixtureRecord record).compress
      | _ => line))

private def cControlFixtureUserLine
    (uuid : String) (parent : Option String) (timestamp : String) (content : Json)
    (isMeta : Bool := false) : String :=
  (Json.mkObj [
    ("type", Json.str "user"), ("uuid", Json.str (cClaudeFixtureUuid uuid)),
    ("parentUuid", match parent with
      | some p => Json.str (cClaudeFixtureUuid p) | none => Json.null),
    ("sessionId", Json.str (cClaudeFixtureUuid "CE0")), ("cwd", Json.str "/w"),
    ("timestamp", Json.str (cClaudeFixtureTimestamp timestamp)),
    ("isSidechain", Json.bool false),
    ("isMeta", Json.bool isMeta),
    ("message", Json.mkObj [("role", Json.str "user"), ("content", content)])
  ]).compress

def claudeControlImportFixture : String := String.intercalate "\n" [
  cControlFixtureUserLine "ce1" none "T1" (Json.str claudeControlOrdinaryString),
  cControlFixtureUserLine "ce2" (some "ce1") "T2" (Json.str claudeControlCommandRaw)
    true,
  cControlFixtureUserLine "ce3" (some "ce2") "T3" (Json.arr #[
    Json.mkObj [("type", Json.str "text"), ("text", Json.str claudeControlOrdinaryTextBlock)],
    Json.mkObj [("type", Json.str "text"), ("text", Json.str claudeControlIdeRaw)],
    Json.mkObj [("type", Json.str "text"), ("text", Json.str claudeControlUnknownTagText)]
  ]) true,
  cControlFixtureUserLine "ce4" (some "ce3") "T4"
    (Json.str claudeControlTaskDetailedRaw) true
]

private def cEntryUserText? (t : Transcript) (i : Nat) : Option String := do
  let entry ← t.entries[i]?
  match entry.payload with
  | Payload.userMsg [UserBlock.text text] => some text
  | _ => none

private def cArchivedControls? (t : Transcript) : Option (Array Json) := do
  let extras ← t.origin.extras
  carr extras "raw_control_messages"

private def cArchivedControlValue?
    (t : Transcript) (i : Nat) (key : String) : Option String := do
  let controls ← cArchivedControls? t
  let control ← controls[i]?
  cstr control key

private def cControlNoteLocs (t : Transcript) : List String :=
  t.importNotes.filterMap (fun note =>
    match note.kind with
    | AssumptionKind.contentSkipped => note.loc
    | _ => none)

private def cControlConversationPreserved (t : Transcript) : Bool :=
  t.entries.size == 3 &&
  cEntryUserText? t 0 == some claudeControlOrdinaryString &&
  cEntryUserText? t 1 == some claudeControlOrdinaryTextBlock &&
  cEntryUserText? t 2 == some claudeControlUnknownTagText

/-- End-to-end control isolation: complete recognized wrappers are absent from
conversation and export, normalized text remains readable in inspect, exact raw
wrappers live in provenance, and embedded/unknown tag-like text stays user-authored. -/
def claudeControlsArchivedOutsideConversation : Bool :=
  match importClaudeCode claudeControlImportFixture with
  | .error _ => false
  | .ok t =>
      let rendered := renderTranscript t
      cControlConversationPreserved t &&
      (cArchivedControls? t).map Array.size == some 3 &&
      cArchivedControlValue? t 0 "kind" == some "command" &&
      cArchivedControlValue? t 0 "raw" == some claudeControlCommandRaw &&
      cArchivedControlValue? t 1 "kind" == some "ide-opened-file" &&
      cArchivedControlValue? t 1 "raw" == some claudeControlIdeRaw &&
      cArchivedControlValue? t 2 "kind" == some "task-notification-detailed" &&
      cArchivedControlValue? t 2 "raw" == some claudeControlTaskDetailedRaw &&
      cControlNoteLocs t ==
        [s!"{cClaudeFixtureUuid "ce2"}:content[0]",
         s!"{cClaudeFixtureUuid "ce3"}:content[1]",
         s!"{cClaudeFixtureUuid "ce4"}:content[0]"] &&
      rendered.contains "Name: /model" && rendered.contains "IDE opened file:" &&
      rendered.contains "Task ID: a1" &&
      (Loom.violations t).isEmpty

example : claudeControlsArchivedOutsideConversation = true := by native_decide

def claudeControlLiteralCollisionText : String :=
  "<system-reminder>literal example</system-reminder>"

/-- Text alone is not authority for control extraction. The unmarked literal is
conversation, while the byte-identical `isMeta:true` record remains archived as
a genuine Claude synthetic-user control. -/
def claudeControlLiteralCollisionPreserved : Bool :=
  let source := String.intercalate "\n" [
    cControlFixtureUserLine "collision-user" none "T1"
      (Json.str claudeControlLiteralCollisionText),
    cControlFixtureUserLine "collision-control" (some "collision-user") "T2"
      (Json.str claudeControlLiteralCollisionText) true]
  match importClaudeCode source with
  | .error _ => false
  | .ok transcript =>
      transcript.entries.size == 1 &&
      cEntryUserText? transcript 0 == some claudeControlLiteralCollisionText &&
      (cArchivedControls? transcript).map Array.size == some 1 &&
      cArchivedControlValue? transcript 0 "kind" == some "system-reminder" &&
      cArchivedControlValue? transcript 0 "raw" == some claudeControlLiteralCollisionText

example : claudeControlLiteralCollisionPreserved = true := by native_decide

def claudeMalformedJsonLineFixture : String := String.intercalate "\n" [
  cControlFixtureUserLine "jm1" none "T1" (Json.str "before"),
  "{\"type\":\"user\",\"message\":",
  cControlFixtureUserLine "jm2" (some "jm1") "T2" (Json.str "after")
]

def claudeBlankJsonLineFixture : String :=
  cControlFixtureUserLine "jb1" none "T1" (Json.str "before") ++ "\n\n" ++
  cControlFixtureUserLine "jb2" (some "jb1") "T2" (Json.str "after")

def claudeNonObjectJsonLineFixture : String :=
  cControlFixtureUserLine "jo1" none "T1" (Json.str "before") ++ "\n42\n" ++
  cControlFixtureUserLine "jo2" (some "jo1") "T2" (Json.str "after")

private def cClaudeImportRejectedAtLine2 (source : String) : Bool :=
  match importClaudeCode source with
  | .ok _ => false
  | .error error => error.startsWith "malformed Claude JSONL at line 2:"

/-- No JSONL record can disappear behind `filterMap`: malformed JSON, blank
interior records, and valid non-object JSON all refuse with the source line. -/
def claudeMalformedLinesRefused : Bool :=
  [claudeMalformedJsonLineFixture, claudeBlankJsonLineFixture,
   claudeNonObjectJsonLineFixture].all cClaudeImportRejectedAtLine2

example : claudeMalformedLinesRefused = true := by native_decide

/-! ## Cross-parity (RC1) — decide-pinned against the TS reference oracle.

The fixture below is byte-identical to `parity/fixtures/claude.jsonl`. Claude is
auto-detected by `parseSession` (parentUuid + sessionId/cwd), so the TS golden is
captured directly by `parity/capture-parity.ts`. -/

def claudeFixture : String := cUuidFixtureSource (String.intercalate "\n" [
  "{\"type\":\"file-history-snapshot\",\"messageId\":\"fh0\",\"sessionId\":\"S0\"}",
  "{\"type\":\"user\",\"uuid\":\"u1\",\"parentUuid\":null,\"sessionId\":\"S0\",\"cwd\":\"/w\",\"timestamp\":\"2026-07-20T00:00:01.000Z\",\"isSidechain\":false,\"message\":{\"role\":\"user\",\"content\":\"hi\"}}",
  "{\"type\":\"assistant\",\"uuid\":\"u2\",\"parentUuid\":\"u1\",\"sessionId\":\"S0\",\"cwd\":\"/w\",\"timestamp\":\"2026-07-20T00:00:02.000Z\",\"isSidechain\":false,\"message\":{\"role\":\"assistant\",\"model\":\"m\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"th\",\"signature\":\"sig1\"},{\"type\":\"text\",\"text\":\"tx\"},{\"type\":\"tool_use\",\"id\":\"tu1\",\"name\":\"bash\",\"input\":{\"a\":1}}]}}",
  "{\"type\":\"mode\",\"mode\":\"default\",\"sessionId\":\"S0\"}",
  "{\"type\":\"user\",\"uuid\":\"u3\",\"parentUuid\":\"u2\",\"sessionId\":\"S0\",\"cwd\":\"/w\",\"timestamp\":\"2026-07-20T00:00:03.000Z\",\"isSidechain\":false,\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"tu1\",\"is_error\":false,\"content\":\"tr\"}]}}",
  "{\"type\":\"assistant\",\"uuid\":\"u4\",\"parentUuid\":\"u3\",\"sessionId\":\"S0\",\"cwd\":\"/w\",\"timestamp\":\"2026-07-20T00:00:04.000Z\",\"isSidechain\":false,\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"tx2\"}]}}"
])

/-- The positional golden captured from the TS toolchain (`parseSession`) via
`parity/capture-parity.ts` on 2026-07-07. -/
def claudeTsGolden : String :=
  "session\n0|-|user|text:hi\n1|0|assistant|think:th;text:tx;call\n2|1|toolResult|text:tr\n3|2|assistant|text:tx2"

def claudeCase1 : CrossParityCase :=
  { name := "claude", input := claudeFixture, tsGolden := claudeTsGolden }

/-- THE DECIDE-PIN (cross-parity, RC1). The earlier tool_result divergence
(Loom's richer `EnvBlock.toolResult` + `CallRef` + `ErrorSignal` vs TS's flattened
text) is resolved at the projection layer: `normalize` projects a toolResult to
its content text, matching TS's flatten, while Loom's enrichment is verified
separately (an adjudicated leanCore improvement, same class as the L12 signature
exclusion). Structure — roles, parent tree, block kinds, content — matches the TS
oracle byte-for-byte. If either side drifts, this stops compiling. -/
example : crossParityOkWith importClaudeCode claudeCase1 = true := by native_decide

-- Well-formedness + non-emptiness of the imported fixture.
example :
    (match importClaudeCode claudeFixture with
     | .ok t => t.entries.size == 4 && (Loom.violations t).isEmpty
     | .error _ => false) = true := by native_decide

/-! ## S5+S6 deepening — `image` blocks + unknown block kinds (leanCore-richer).

The census (`Loom.Formats.ClaudeCode`) marks Claude `image` content blocks (8
observed) and every unrecognized block kind as DROPPED by the importer. They are
now modeled: `image` → `.media` (base64 sources use a lossless data-URI locator),
anything else → `.unmodeled` (the open-world escape hatch — representable +
round-trippable back out via the exporter's `media`/`unmodeled` arms).

DIVERGENCE (deliberate, NOT pinned): TS `parseSession`/`adaptClaude` DROP both,
so Loom is strictly RICHER here. A cross-parity pin against the TS oracle would
(correctly) FAIL — this is an adjudicated leanCore improvement, same class as the
L12 signature exclusion. Hence this fixture is verified by a local compile-time
check (well-formed IR + blocks captured), never by a `crossParityOkWith`/
`roundTripClaude` cross-parity pin against the poorer TS oracle. -/

def claudeMediaFixture : String := cUuidFixtureSource (String.intercalate "\n" [
  "{\"type\":\"user\",\"uuid\":\"m1\",\"parentUuid\":null,\"sessionId\":\"S0\",\"cwd\":\"/w\",\"timestamp\":\"2026-07-20T00:00:01.000Z\",\"isSidechain\":false,\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"iVBORw0KGgoAAAA\"}},{\"type\":\"custom_widget\",\"payload\":{\"k\":\"v\"}}]}}",
  "{\"type\":\"assistant\",\"uuid\":\"m2\",\"parentUuid\":\"m1\",\"sessionId\":\"S0\",\"cwd\":\"/w\",\"timestamp\":\"2026-07-20T00:00:02.000Z\",\"isSidechain\":false,\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/jpeg\",\"data\":\"/9j/4AAQSkZJRg\"}},{\"type\":\"redacted_thinking\",\"data\":\"ENCRYPTED_BLOB\"}]}}"
])

/-- Count `.media` / `.unmodeled` blocks across all entries (both roles) so the
local check can confirm the S5+S6 blocks actually landed in the IR. -/
private def mediaUnmodeledCounts (t : Transcript) : Nat × Nat :=
  t.entries.toList.foldl (fun (acc : Nat × Nat) (e : Entry) =>
    match e.payload with
    | Payload.userMsg blocks =>
        blocks.foldl (fun (a : Nat × Nat) (b : UserBlock) => match b with
          | UserBlock.media _ _     => (a.1 + 1, a.2)
          | UserBlock.unmodeled _ _ => (a.1, a.2 + 1)
          | _ => a) acc
    | Payload.assistantMsg blocks =>
        blocks.foldl (fun (a : Nat × Nat) (b : AssistantBlock) => match b with
          | AssistantBlock.media _ _     => (a.1 + 1, a.2)
          | AssistantBlock.unmodeled _ _ => (a.1, a.2 + 1)
          | _ => a) acc
    | _ => acc) (0, 0)

-- Media/unmodeled deepening: well-formed IR + blocks present. One image + one
-- unknown block per role, all captured where the TS toolchain drops them.
example :
    (match importClaudeCode claudeMediaFixture with
     | .ok t =>
         let (media, unmodeled) := mediaUnmodeledCounts t
         t.entries.size == 3 && (Loom.violations t).isEmpty
         && media == 2 && unmodeled == 2
     | .error _ => false) = true := by native_decide

/-! ## Export: Loom IR → Claude Code JSONL.

Renders each `Entry` back to one Claude envelope line, inverting the importer's
disposition table exactly:

* `Payload.userMsg`      → `{type:"user",      message:{role:"user",      content:[…]}}`
* `Payload.assistantMsg` → `{type:"assistant", message:{role:"assistant", content:[…]}}`
* `Payload.envMsg`       → `{type:"user",      message:{role:"user",      content:[tool_result]}}`
  (re-serializing the authorship coercion Claude performs natively — the
  `roleCoerced` note's inverse).

Blocks invert `cParseAssistantBlock` / `parseToolResultContent` per role type:
`.text`→`{type:text,text}`, `.thinking`→`{type:thinking,thinking,signature?}`,
`.toolCall`→`{type:tool_use,id,name,input}`, `.toolResult`→`{type:tool_result,
tool_use_id,is_error,content}` — the `tool_use_id` recovered from the `CallRef`'s
target `toolCall`, so a re-import re-resolves the same positional `CallRef`.
Unmodeled blocks in every role and any lifecycle that cannot be proven closed,
unique, schema-valid, and Claude-origin are emitted only as marked inert text
carriers. A compaction is likewise a marked `system` carrier, never a user turn.

`uuid` preserves a source raw ID only when it is a valid, transcript-unique
UUID. Every valid explicit UUID is reserved before deterministic synthesis, so
an early generated ID cannot collide with a later native ID. Invalid, missing,
and duplicate raw identities remain in unverified provenance. A child's
`parentUuid` comes from the same allocation table. `sessionId` must be an
explicit valid UUID; `cwd` and the selected timestamp are stamped on every line.

Fidelity notes (the semantic IR round-trips, while native record layout may not):
* multi-result lines — several `tool_result` blocks that shared ONE source
  `user` uuid become several IR entries carrying that same `rawId`; export
  re-emits them as several one-result `user` lines (each with a distinct planned
  UUID), not one multi-result line (mirrors the importer's own multi-entry TODO).
* archived controls and role-mismatched/system records stay inert in provenance;
  they are not replayed as conversation.
* native compaction boundary/summary pairs re-export as one versioned system
  carrier containing the typed summary and exact source provenance. Events use
  a totality fallback because Claude has no safe native event encoding here. -/

/-- Claude serializes a native tool-result's `is_error` as a bool. Non-native
provenance is carried instead of being collapsed through this projection. -/
def errorBool : ErrorSignal → Bool
  | ErrorSignal.native b => b
  | ErrorSignal.inferred b _ => b
  | ErrorSignal.unrecorded => false

/-- Recover the source `tool_use_id` for a `toolResult` from its `CallRef`: a
resolved ref points at the spawning `toolCall`, whose `rawId` IS that id; an
unresolved ref carries whatever raw id it recorded. Lets a re-import rebuild the
same positional `CallRef` via `tmap`. -/
def callRefToolUseId (t : Transcript) : CallRef → Option String
  | call => cCallRefRawId t call

/-- Human-readable text projection of result content. -/
def toolResultText (blocks : List UserBlock) : String :=
  String.intercalate "" (blocks.map (fun (b : UserBlock) => match b with
    | UserBlock.text s => s
    | UserBlock.media _ _ => "[image tool result omitted]"
    | _ => ""))

private def cClaudeImageSource? (mime locator : String) : Option Json :=
  match locator.dropPrefix? "data:" with
  | some rest =>
      match rest.toString.splitOn ";base64," with
      | [encodedMime, data] =>
          if encodedMime != mime || !encodedMime.startsWith "image/" || data.isEmpty then
            none
          else
            some (Json.mkObj [
              ("type", Json.str "base64"),
              ("media_type", Json.str encodedMime),
              ("data", Json.str data)])
      | _ => none
  | none =>
      if mime == "image" &&
          (locator.startsWith "https://" || locator.startsWith "http://") then
        some (Json.mkObj [("type", Json.str "url"), ("url", Json.str locator)])
      else match locator.dropPrefix? "claude-file:" with
        | some fileId =>
            if mime != "image" || fileId.isEmpty then none else some (Json.mkObj [
              ("type", Json.str "file"), ("file_id", Json.str fileId.toString)])
        | none => none

private def cClaudeImageBlock? (mime locator : String) : Option Json :=
  (cClaudeImageSource? mime locator).map (fun source => Json.mkObj [
    ("type", Json.str "image"), ("source", source)])

/-- One Loom `UserBlock` → one schema-valid Claude content block. Media which
cannot be expressed as a native Claude source is a readable carrier; callers
that serialize a containing line stamp its block index for marked decoding. -/
def claudeUserBlockToJson : UserBlock → Json
  | UserBlock.text s => Json.mkObj [("type", Json.str "text"), ("text", Json.str s)]
  | UserBlock.media mime locator =>
      (cClaudeImageBlock? mime locator).getD (Json.mkObj [
        ("type", Json.str "text"),
        ("text", Json.str (claudeMediaCarrierText mime locator))])
  | UserBlock.unmodeled label raw => Json.mkObj [
      ("type", Json.str "text"),
      ("text", Json.str (claudeUnmodeledUserCarrierText label raw))]

private def claudeToolResultBlockToJson : UserBlock → Json
  | UserBlock.unmodeled label raw => Json.mkObj [
      ("type", Json.str "text"),
      ("text", Json.str (claudeStructuredToolResultCarrierText label raw))]
  | other => claudeUserBlockToJson other

private def claudeToolResultContentToJson (blocks : List UserBlock) : Json :=
  match blocks with
  | [UserBlock.text text] => Json.str text
  | _ => Json.arr ((blocks.map claudeToolResultBlockToJson).toArray)

/-- A raw open-world block with a native lifecycle discriminator must not skip
the modeled lifecycle checks merely because it sits in `.unmodeled`. -/
private def cRawClaudeLifecycleBlock (raw : Json) : Bool :=
  match cstr raw "type" with
  | some kind =>
      kind == "tool_use" || kind == "tool_result" ||
      kind.endsWith "_tool_use" || kind.endsWith "_tool_result"
  | none => false

/-- Codex response_item payloads that carry an opaque `encrypted_content` ciphertext
alongside a `type` tag — the shape used by Codex's `reasoning` items (`summary:
[{"type":"summary_text","text":...}]`, `encrypted_content: <ciphertext>`) and, as
of Codex CLI 0.145.0, also by a new `compaction` response_item this importer (built
against the pinned 0.144.1) does not yet model. CodexCli.lean's importer keeps
both as `.unmodeled <label> raw` (preserving the exact raw payload, including
provider-internal extras, for lossless Codex round-trip) — for the ~98%-empty-
summary reasoning case and for any not-yet-recognized Codex record, verbatim
preservation is the correct import behavior. But recognizing the `type` +
`encrypted_content` shape here lets *export* to Claude use Claude's own native
opaque `thinking` block instead of dumping the raw ciphertext JSON as visible
chat text: Claude Code already renders a signature-only thinking block sanely,
has no reason to render raw Codex JSON, and no other format's unmodeled blocks
carry this exact `type`+`encrypted_content` shape by coincidence. -/
private def cCodexReasoningSummaryText? (raw : Json) : Option String :=
  match carr raw "summary" with
  | none => some ""
  | some summary =>
      (summary.toList.mapM (fun item => do
        guard (cstr item "type" == some "summary_text")
        cstr item "text")).map (String.intercalate "\n")

private def cCodexReasoningEncryptedContent? (raw : Json) : Option String :=
  match cstr raw "type", cobj raw "encrypted_content" with
  | some _, some (Json.str value) => if value.isEmpty then none else some value
  | _, _ => none

/-- Conservative context-free block conversion. Tool calls require lifecycle
context to prove closure and ID uniqueness, so this public helper carries them;
`claudeEntryToJson` below emits native calls only after the full check. -/
def claudeAssistantBlockToJson : AssistantBlock → Json
  | AssistantBlock.text s => Json.mkObj [("type", Json.str "text"), ("text", Json.str s)]
  | AssistantBlock.thinking s sig =>
      Json.mkObj ([("type", Json.str "thinking"), ("thinking", Json.str s)]
        ++ (match sig with | some g => [("signature", Json.str g)] | none => []))
  | AssistantBlock.toolCall name args rid =>
      Json.mkObj [("type", Json.str "text"),
        ("text", Json.str (cHistoricalToolCallCarrierText name args rid none
          "context-free export cannot prove a valid closed Claude lifecycle"))]
  | AssistantBlock.media mime locator =>
      (cClaudeImageBlock? mime locator).getD (Json.mkObj [
        ("type", Json.str "text"),
        ("text", Json.str (claudeMediaCarrierText mime locator))])
  | AssistantBlock.unmodeled label raw =>
      match cCodexReasoningEncryptedContent? raw with
      | some encrypted =>
          Json.mkObj [("type", Json.str "thinking"),
            ("thinking", Json.str ((cCodexReasoningSummaryText? raw).getD "")),
            ("signature", Json.str encrypted)]
      | none =>
          Json.mkObj [("type", Json.str "text"),
            ("text", Json.str (claudeUnmodeledAssistantCarrierText label raw))]

private def cAsciiAlphaNum (c : Char) : Bool :=
  let n := c.toNat
  decide ((48 ≤ n && n ≤ 57) || (65 ≤ n && n ≤ 90) || (97 ≤ n && n ≤ 122))

private def cClaudeIdChar (c : Char) : Bool :=
  cAsciiAlphaNum c || c == '_' || c == '-'

/-- Conservative validator for Claude persisted tool-use IDs. Invalid or absent
IDs are carried; they are never omitted from a native `tool_use`. -/
def claudeNativeToolIdValid (id : String) : Bool :=
  !id.isEmpty && decide (id.length ≤ 128) && id.toList.all cClaudeIdChar

private def cClaudeToolNameValid (name : String) : Bool :=
  !name.isEmpty && decide (name.length ≤ 128) && name.toList.all cClaudeIdChar

private def cJsonIsObject : Json → Bool
  | Json.obj _ => true
  | _ => false

private def cNativeResultContentValid (content : List UserBlock) : Bool :=
  content.all (fun block => match block with
    | .text _ => true
    | .media mime locator => (cClaudeImageSource? mime locator).isSome
    | .unmodeled _ _ => false)

private structure ClaudeResultSite where
  entry   : Nat
  block   : Nat
  content : List UserBlock
  error   : ErrorSignal

private def cResultSitesForCall
    (t : Transcript) (callEntry callBlock : Nat) : List ClaudeResultSite :=
  t.entries.toList.zipIdx.flatMap (fun (entry, entryIdx) =>
    match entry.payload with
    | .envMsg blocks => blocks.zipIdx.filterMap (fun (block, blockIdx) =>
        match block with
        | .toolResult (.resolved targetEntry targetBlock) content error =>
            if targetEntry == callEntry && targetBlock == callBlock then
              some { entry := entryIdx, block := blockIdx, content, error }
            else none
        | _ => none)
    | _ => [])

private def cCallIdCount (t : Transcript) (id : String) : Nat :=
  t.entries.toList.foldl (fun total entry =>
    total + match entry.payload with
      | .assistantMsg blocks => blocks.countP (fun block => match block with
          | .toolCall _ _ (some rawId) => rawId == id
          | _ => false)
      | _ => 0) 0

private def cEntryCarrierForced
    (t : Transcript) (entryIdx blockIdx : Nat) : Bool :=
  match t.entries[entryIdx]? with
  | some entry =>
      entry.disposition == EntryDisposition.historicalUnverified ||
        (cOriginCarrierBlocks entry.origin).contains blockIdx
  | none => false

/-- Whether this entry may render as native executable Claude state.

Source format is deliberately NOT consulted. Whether Claude can express a tool
call is a fact about Claude; it cannot depend on whether the transcript arrived
from Codex or from Claude. Gating on `origin.format` made native emission
reachable only when source == target — i.e. only when conversion is
unnecessary — which is what made every cross-harness transcript arrive as
prose (see `LoomOps.Interop`, principle P1).

`disposition` remains the anti-laundering guard, and it is the *only* one that
ever carried that property: it is independent of `origin.format`, so a forger
able to set `disposition := .native` could equally set
`origin.format := .claudeCode`. The format equality added no safety; it only
blocked honest conversions. -/
private def cClaudeNativeEntryProvenance (t : Transcript) (entryIdx : Nat) : Bool :=
  match t.entries[entryIdx]? with
  | some entry => entry.disposition == EntryDisposition.native
  | none => false

private def cNativeClaudeCallAt
    (t : Transcript) (entryIdx blockIdx : Nat)
    (name : ToolName) (args : Json) (rawId : Option String) : Bool :=
  cClaudeNativeEntryProvenance t entryIdx &&
  !(cEntryCarrierForced t entryIdx blockIdx) &&
  cClaudeToolNameValid name.raw && cJsonIsObject args &&
  match rawId with
  | none => false
  | some id =>
      claudeNativeToolIdValid id && cCallIdCount t id == 1 &&
      match cResultSitesForCall t entryIdx blockIdx with
      | [site] =>
          decide (entryIdx < site.entry) &&
          cClaudeNativeEntryProvenance t site.entry &&
          !(cEntryCarrierForced t site.entry site.block) &&
          -- The error signal is deliberately NOT gated on `.native`. Claude's
          -- `is_error` is a plain bool and `errorBool` is a total projection
          -- from every ErrorSignal, so an inferred signal is fully
          -- representable. Codex has no structured error flag and therefore
          -- always yields `.inferred`; demanding `.native` here forced every
          -- Codex result to prose. Inference stays recorded in provenance.
          cNativeResultContentValid site.content
      | _ => false

private def cCallAtIsNative (t : Transcript) (entry block : Nat) : Bool :=
  match t.entries[entry]? with
  | some { payload := .assistantMsg blocks, .. } =>
      match blocks[block]? with
      | some (.toolCall name args rawId) =>
          cNativeClaudeCallAt t entry block name args rawId
      | _ => false
  | _ => false

/-- Whether the checked renderer will place a physical native `tool_use` at an
exact entry/block location. Sidecar metadata uses this instead of inferring
native eligibility from the typed call's mere presence. -/
def claudeToolCallEmitsNativeAt (t : Transcript) (entry block : Nat) : Bool :=
  cCallAtIsNative t entry block

private def cHistoricalCallReason
    (_t : Transcript) (_entry _block : Nat) (_args : Json)
    (_rawId : Option String) : String :=
  "historical source lifecycle"

private def cAssistantBlockToJsonAt
    (t : Transcript) (entryIdx blockIdx : Nat) : AssistantBlock → Json
  | .toolCall name args rawId =>
      if cNativeClaudeCallAt t entryIdx blockIdx name args rawId then
        Json.mkObj [
          ("type", Json.str "tool_use"), ("id", Json.str rawId.get!),
          ("name", Json.str name.raw), ("input", args)]
      else
        Json.mkObj [("type", Json.str "text"),
          ("text", Json.str (cHistoricalToolCallCarrierTextAt entryIdx blockIdx
            name args rawId (cHistoricalCallReason t entryIdx blockIdx args rawId)))]
  | block => claudeAssistantBlockToJson block

private def cEnvBlockToJsonAt
    (t : Transcript) (entryIdx blockIdx : Nat) : EnvBlock → Json
  | .toolResult call content error =>
      let native := match call with
        | .resolved callEntry callBlock => cCallAtIsNative t callEntry callBlock
        | .unresolved _ _ => false
      if native then
        -- `is_error` is OMITTED for `ErrorSignal.unrecorded`, never emitted as
        -- `false`. Claude's field is a bare bool with no "unknown" state, so
        -- writing `false` would turn "the source did not record whether this
        -- errored" into "the source recorded that it succeeded" — an error
        -- state the source never asserted, which `LoomOps.Interop` rates
        -- `corrupting` rather than merely lossy.
        --
        -- Omitting it is exactly reversible rather than a mere approximation:
        -- the importer already maps an absent `is_error` back to `.unrecorded`
        -- (see the `| _ => ErrorSignal.unrecorded` arm), so `.unrecorded`
        -- round-trips through this target with no carrier and no loss.
        --
        -- `.inferred` is deliberately still emitted through `errorBool`: there
        -- the VALUE is real and only the provenance normalizes to `.native` on
        -- re-import, which is the reportable class (Interop P2/P4).
        Json.mkObj ([
          ("type", Json.str "tool_result"),
          ("tool_use_id", Json.str (callRefToolUseId t call).get!)] ++
          (match error with
           | ErrorSignal.unrecorded => []
           | _ => [("is_error", Json.bool (errorBool error))]) ++
          [("content", claudeToolResultContentToJson content)])
      else
        Json.mkObj [("type", Json.str "text"),
          ("text", Json.str (claudeHistoricalToolResultCarrierText t entryIdx blockIdx
            call content error))]
  | .unmodeled label raw => Json.mkObj [
      ("type", Json.str "text"),
      ("text", Json.str (claudeUnmodeledEnvCarrierText label raw))]

/-- One Loom `EnvBlock` → one Claude content-block Json (inverse of the importer's
tool_result handling). The `tool_use_id` is recovered from the `CallRef`'s target
`toolCall`, so a re-import re-resolves the same positional `CallRef`. -/
def claudeEnvBlockToJson (t : Transcript) : EnvBlock → Json
  | block => cEnvBlockToJsonAt t 0 0 block

private def cUserBlockNeedsCarrier : UserBlock → Bool
  | .media mime locator => (cClaudeImageSource? mime locator).isNone
  | .unmodeled _ _ => true
  | _ => false

private def cAssistantBlockNeedsCarrier
    (t : Transcript) (entry block : Nat) : AssistantBlock → Bool
  | .toolCall name args rawId =>
      !(cNativeClaudeCallAt t entry block name args rawId)
  | .media mime locator => (cClaudeImageSource? mime locator).isNone
  | .unmodeled _ raw => (cCodexReasoningEncryptedContent? raw).isNone
  | _ => false

private def cEnvBlockNeedsCarrier (t : Transcript) : EnvBlock → Bool
  | .toolResult (.resolved callEntry callBlock) _ _ =>
      !(cCallAtIsNative t callEntry callBlock)
  | .toolResult (.unresolved _ _) _ _ => true
  | .unmodeled _ _ => true

def claudeNativeToolCallCount (t : Transcript) : Nat :=
  t.entries.toList.zipIdx.foldl (fun total (entry, entryIdx) =>
    total + match entry.payload with
      | .assistantMsg blocks => blocks.zipIdx.countP (fun (block, blockIdx) =>
          match block with
          | .toolCall _ _ _ => cCallAtIsNative t entryIdx blockIdx
          | _ => false)
      | _ => 0) 0

def claudeHistoricalToolCallCount (t : Transcript) : Nat :=
  t.entries.toList.zipIdx.foldl (fun total (entry, entryIdx) =>
    total + match entry.payload with
      | .assistantMsg blocks => blocks.zipIdx.countP (fun (block, blockIdx) =>
          match block with
          | .toolCall _ _ _ => !(cCallAtIsNative t entryIdx blockIdx)
          | _ => false)
      | _ => 0) 0

private def cToolResultAtIsNative (t : Transcript) : EnvBlock → Bool
  | .toolResult (.resolved callEntry callBlock) _ _ =>
      cCallAtIsNative t callEntry callBlock
  | .toolResult (.unresolved _ _) _ _ | .unmodeled _ _ => false

def claudeNativeToolResultCount (t : Transcript) : Nat :=
  t.entries.toList.foldl (fun total entry =>
    total + match entry.payload with
      | .envMsg blocks => blocks.countP (cToolResultAtIsNative t)
      | _ => 0) 0

def claudeHistoricalToolResultCount (t : Transcript) : Nat :=
  t.entries.toList.foldl (fun total entry =>
    total + match entry.payload with
      | .envMsg blocks => blocks.countP (fun block =>
          match block with
          | .toolResult _ _ _ => !(cToolResultAtIsNative t block)
          | .unmodeled _ _ => false)
      | _ => 0) 0

private def cEntryCarrierIndices
    (t : Transcript) (entryIdx : Nat) (entry : Entry) : List Nat :=
  let forced := cOriginCarrierBlocks entry.origin
  match entry.payload with
  | .userMsg blocks => blocks.zipIdx.filterMap (fun (block, blockIdx) =>
      if forced.contains blockIdx || cUserBlockNeedsCarrier block then some blockIdx else none)
  | .assistantMsg blocks => blocks.zipIdx.filterMap (fun (block, blockIdx) =>
      if forced.contains blockIdx || cAssistantBlockNeedsCarrier t entryIdx blockIdx block
      then some blockIdx else none)
  | .envMsg blocks => blocks.zipIdx.filterMap (fun (block, blockIdx) =>
      if forced.contains blockIdx || cEnvBlockNeedsCarrier t block then some blockIdx else none)
  | .otherMsg _ blocks => blocks.zipIdx.filterMap (fun (block, blockIdx) =>
      if forced.contains blockIdx || cUserBlockNeedsCarrier block then some blockIdx else none)
  | _ => []

/-- Block index → canonical tool identity, for the calls this entry emits as
native `tool_use` blocks and only those.

Claude's `tool_use` has slots for exactly `{id, name, input}`, so the canonical
identity a source asserted has nowhere to go *inside the block*. Rendering the
call as prose to keep the field would trade the target's own construct for one
scalar; dropping the field silently would discard an interpretation the source
made. `LoomOps.Interop.Emission.envelopePreserved` is the third option and the
contract's preferred one: emit the native block and stash the field in the
record-level `_agent_convert` marker, where `cCarrierToolCanonical?` recovers
it. Both facts survive.

The list is empty unless a natively emitted call actually carries a canonical
identity. The Claude importer only ever produces `canonical` from a historical
carrier block, and carrier blocks are never native (`cEntryCarrierForced`), so
a claude → claude trip adds no member and the record stays byte-identical. -/
private def cEntryToolCanonical
    (t : Transcript) (entryIdx : Nat) (entry : Entry) : List (Nat × CanonicalTool) :=
  match entry.payload with
  | .assistantMsg blocks => blocks.zipIdx.filterMap (fun (block, blockIdx) =>
      match block with
      | .toolCall name args rawId =>
          if cNativeClaudeCallAt t entryIdx blockIdx name args rawId then
            name.canonical.map (fun canonical => (blockIdx, canonical))
          else none
      | _ => none)
  | _ => []

/-- If a carrier-bearing entry also contains a block that would otherwise look
native, carry the whole payload in a system record. Entries made entirely of
the existing inert block carriers keep that representation for E-I-E stability. -/
private def cEntryNeedsWholeHistoricalCarrier
    (t : Transcript) (entryIdx : Nat) (entry : Entry)
    (carrierIndices : List Nat) : Bool :=
  let userBlockAlreadyInert := fun (block : UserBlock) =>
    match block with
    | .text text =>
        (parseClaudeHistoricalToolResultCarrier? text).isSome ||
          (parseClaudeMediaCarrier? text).isSome ||
          (parseClaudeUnmodeledUserCarrier? text).isSome ||
          (parseClaudeUnmodeledEnvCarrier? text).isSome
    | _ => false
  let assistantBlockAlreadyInert := fun (block : AssistantBlock) =>
    match block with
    | .text text =>
        (parseClaudeHistoricalToolCallCarrier? text).isSome ||
          (parseClaudeMediaCarrier? text).isSome ||
          (parseClaudeUnmodeledAssistantCarrier? text).isSome
    | _ => false
  let carrierBearing := entry.disposition == EntryDisposition.historicalUnverified ||
    !carrierIndices.isEmpty
  if !carrierBearing then false else
    match entry.payload with
    | .userMsg blocks => blocks.isEmpty || blocks.zipIdx.any (fun (block, blockIdx) =>
        !cUserBlockNeedsCarrier block &&
          !(carrierIndices.contains blockIdx && userBlockAlreadyInert block))
    | .assistantMsg blocks => blocks.isEmpty || blocks.zipIdx.any (fun (block, blockIdx) =>
        !cAssistantBlockNeedsCarrier t entryIdx blockIdx block &&
          !(carrierIndices.contains blockIdx && assistantBlockAlreadyInert block))
    | .envMsg blocks => blocks.isEmpty || blocks.any (fun block =>
        !cEnvBlockNeedsCarrier t block)
    | .otherMsg _ _ | .compaction _ _ _ | .event _ =>
        entry.disposition == EntryDisposition.historicalUnverified

private def cWholeHistoricalPayload
    (entryIdx : Nat) (entry : Entry) (carrierIndices : List Nat) : Payload :=
  match entry.payload with
  | .assistantMsg blocks =>
      .assistantMsg (blocks.zipIdx.map (fun (block, blockIdx) =>
        if !carrierIndices.contains blockIdx then block else
          match block with
          | .text text =>
              match parseClaudeHistoricalToolCallCarrier? text with
              | some call =>
                  if call.occurrence == some (cOccurrence entryIdx blockIdx) then
                    call.block else block
              | none =>
                  match parseClaudeMediaCarrier? text with
                  | some (mime, locator) => .media mime locator
                  | none => (parseClaudeUnmodeledAssistantCarrier? text).getD block
          | _ => block))
  | .userMsg blocks =>
      .userMsg (blocks.zipIdx.map (fun (block, blockIdx) =>
        if !carrierIndices.contains blockIdx then block else
          match block with
          | .text text =>
              match parseClaudeMediaCarrier? text with
              | some (mime, locator) => .media mime locator
              | none => (parseClaudeUnmodeledUserCarrier? text).getD block
          | _ => block))
  | payload => payload

private def cIdentityJson : Option String → Json
  | some value => Json.str value
  | none => Json.null

private def cEntryIdentityProvenance?
    (t : Transcript) (uuidPlan : List String) (entryIdx : Nat)
    (entry : Entry) : Option Json :=
  match entry.origin.extras >>= fun extras => cobj extras "claudeIdentityProvenance" with
  | some identity =>
      if cstr identity "carrier" ==
          some "agent-convert.claude-identity-provenance.v1" &&
          cstr identity "trust" == some "historical-unverified" then
        some identity
      else none
  | none =>
      let emittedId := uuidPlan[entryIdx]?
      let sourceParentId := entry.parent.bind (fun parent =>
        t.entries[parent]? >>= fun parentEntry => parentEntry.origin.rawId)
      let emittedParentId := entry.parent.bind (fun parent => uuidPlan[parent]?)
      let sourceSessionId := t.origin.rawId
      let requestedSessionId := cClaudeTargetSessionRequested? t
      let emittedSessionId := requestedSessionId.bind (fun sessionId =>
        if !sessionId.isEmpty && claudeUuidValid sessionId then some sessionId else none)
      let entryChanged := entry.origin.rawId != emittedId
      let parentChanged := sourceParentId != emittedParentId
      let sessionChanged := sourceSessionId.isSome && sourceSessionId != emittedSessionId
      if !entryChanged && !parentChanged && !sessionChanged then none else
        some (Json.mkObj ([
          ("carrier", Json.str "agent-convert.claude-identity-provenance.v1"),
          ("trust", Json.str "historical-unverified")] ++
          (if entryChanged then [("sourceEntryId", cIdentityJson entry.origin.rawId)] else []) ++
          (if parentChanged then [("sourceParentId", cIdentityJson sourceParentId)] else []) ++
          (if sessionChanged then [("sourceSessionId", cIdentityJson sourceSessionId)] else [])))

private def cToolCanonicalJson (pairs : List (Nat × CanonicalTool)) : Json :=
  Json.arr (pairs.map (fun (blockIdx, canonical) => Json.mkObj [
    ("block", Json.num (Lean.JsonNumber.fromNat blockIdx)),
    ("canonical", Json.str (cCanonicalToolName canonical))])).toArray

private def cCarrierMarker
    (indices : List Nat) (rawEnvelope : Option Json := none)
    (identityProvenance : Option Json := none)
    (timeProvenance : Option Json := none)
    (toolCanonical : List (Nat × CanonicalTool) := []) : Option Json :=
  if indices.isEmpty && rawEnvelope.isNone && identityProvenance.isNone &&
      timeProvenance.isNone && toolCanonical.isEmpty then none else
    some (Json.mkObj ([
      ("protocol", Json.str claudeCarrierProtocol)] ++
      (if indices.isEmpty then [] else [
        ("contentBlocks", Json.arr (indices.map (fun n =>
          Json.num (Lean.JsonNumber.fromNat n))).toArray)]) ++
      (if toolCanonical.isEmpty then [] else [
        ("toolCanonical", cToolCanonicalJson toolCanonical)]) ++
      (match rawEnvelope with
       | some raw => [("provenance", Json.mkObj [
           ("carrier", Json.str "agent-convert.claude-envelope-provenance.v1"),
           ("rawEnvelope", raw)])]
       | none => []) ++
      (match identityProvenance with
       | some identity => [("identityProvenance", identity)]
       | none => []) ++
      (match timeProvenance with
       | some value => [("timeProvenance", value)]
       | none => [])))

private def cCarrierTopLevelStamp (indices : List Nat) : List (String × Json) :=
  match cCarrierMarker indices with
  | some marker => [(claudeCarrierMarkerKey, marker)]
  | none => []

private def cCarrierTopLevelStampWithRaw
    (indices : List Nat) (rawEnvelope : Option Json)
    (identityProvenance : Option Json := none)
    (timeProvenance : Option Json := none)
    (toolCanonical : List (Nat × CanonicalTool) := []) : List (String × Json) :=
  match cCarrierMarker indices rawEnvelope identityProvenance timeProvenance
      toolCanonical with
  | some marker => [(claudeCarrierMarkerKey, marker)]
  | none => []

private def cRawEnvelopeForExport (t : Transcript) (entry : Entry) : Option Json :=
  if t.origin.format == Format.claudeCode && entry.origin.format == Format.claudeCode then
    entry.origin.extras >>= fun extras => cNonNull (cobj extras "claudeRawEnvelope")
  else none

/-- Merge preserved metadata into a generated envelope. Native structural
fields are removed from the preserved object first, and generated `message`
role/content override their source copies while retaining model/usage and any
future metadata fields. -/
private def cMergeClaudeEnvelopeMetadata (raw generated : Json) : Json :=
  match raw, generated with
  | Json.obj rawFields, Json.obj generatedFields =>
      let protectedKeys := [
        "type", "subtype", "uuid", "parentUuid", "sessionId", "cwd",
        "timestamp", "isSidechain", "isMeta", "isCompactSummary", "logicalParentUuid",
        "compactMetadata", "content", "message", claudeCarrierMarkerKey]
      let metadata := protectedKeys.foldl
        (fun (fields : Std.TreeMap.Raw String Json) key => fields.erase key) rawFields
      let generatedFields :=
        match cobj raw "message", cobj generated "message" with
        | some (Json.obj rawMessage), some (Json.obj generatedMessage) =>
            let rawMessage := ["role", "content"].foldl
              (fun (fields : Std.TreeMap.Raw String Json) key => fields.erase key) rawMessage
            let mergedMessage := generatedMessage.toList.foldl
              (fun (fields : Std.TreeMap.Raw String Json) (key, value) =>
                fields.insert key value) rawMessage
            generatedFields.insert "message" (Json.obj mergedMessage)
        | _, _ => generatedFields
      Json.obj (generatedFields.toList.foldl
        (fun (fields : Std.TreeMap.Raw String Json) (key, value) =>
          fields.insert key value) metadata)
  | _, _ => generated

/-- The preferred UUID for an entry before transcript-wide collision handling.
Invalid source identities are never emitted into Claude's native graph. -/
def claudeEntryUuid (i : Nat) (e : Entry) : String :=
  match e.origin.rawId with
  | some rawId => if claudeUuidValid rawId then rawId
      else cGeneratedClaudeUuid "agent-convert.claude.standalone" (i + 1)
  | none => cGeneratedClaudeUuid "agent-convert.claude.standalone" (i + 1)

/-- Allocate all exported UUIDs in one collision domain. Every valid explicit
UUID is reserved before synthesis, including values occurring later in the
transcript. A raw UUID is preserved only when it occurs exactly once; invalid,
missing, and duplicate identities receive deterministic UUIDs outside the
reserved set. -/
private def cClaudeEntryUuidPlan (t : Transcript) : List String := Id.run do
  let scopeKey := (cClaudeTargetSessionId? t).getD
    ("agent-convert.claude.source|" ++ t.origin.sourceRef)
  let explicit := t.entries.toList.filterMap (fun entry =>
    entry.origin.rawId.bind (fun rawId =>
      if claudeUuidValid rawId then some rawId else none))
  let mut used : List String := []
  let mut counter := 1
  for entry in t.entries.toList do
    let preserve := entry.origin.rawId.bind (fun rawId =>
      if claudeUuidValid rawId && explicit.count rawId == 1 then some rawId
      else none)
    let (uuid, nextCounter) := match preserve with
      | some rawId => (rawId, counter)
      | none => cFreshGeneratedClaudeUuid scopeKey explicit used counter
    used := used ++ [uuid]
    counter := nextCounter
  return used

private def cNonemptyString? : Option String → Option String
  | some text => if text.isEmpty then none else some text
  | none => none

private def cClaudeEntryTimestamp? (t : Transcript) (e : Entry) : Option String :=
  match e.time with
  | .recorded timestamp => some (epochMsToIso8601 timestamp)
  | .absent | .interpolated _ _ | .sequenced _ =>
      cClaudeTargetTimestamp? t <|>
        (e.origin.extras >>= fun extras => cstr extras "ts")

/-- One entry → one Claude JSONL line object using the transcript's UUID plan. -/
private def cClaudeEntryToJson
    (t : Transcript) (uuidPlan : List String) (i : Nat) (e : Entry) : Json :=
  let uuid := (uuidPlan[i]?).getD (claudeEntryUuid i e)
  let parentUuid : Json :=
    match e.parent.bind (fun p => uuidPlan[p]?) with
    | some pu => Json.str pu
    | none => Json.null
  let ts := cClaudeEntryTimestamp? t e
  let carrierIndices := cEntryCarrierIndices t i e
  let rawEnvelope := cRawEnvelopeForExport t e
  let identityProvenance := cEntryIdentityProvenance? t uuidPlan i e
  let timeProvenance := cTimeProvenanceJson e.time
  let toolCanonical := cEntryToolCanonical t i e
  let stamp : List (String × Json) :=
    [("uuid", Json.str uuid), ("parentUuid", parentUuid)]
    ++ [("sessionId", Json.str (cClaudeTargetSessionId t))]
    ++ (match cClaudeTargetCwd? t with | some c => [("cwd", Json.str c)] | none => [])
    ++ (match ts with | some s => [("timestamp", Json.str s)] | none => [])
    ++ [("isSidechain", Json.bool false)]
  let render := fun (provenanceRaw : Option Json) =>
    let ordinaryStamp := stamp ++
      cCarrierTopLevelStampWithRaw carrierIndices provenanceRaw
        identityProvenance timeProvenance toolCanonical
    if cEntryNeedsWholeHistoricalCarrier t i e carrierIndices then
      match e.payload with
      | Payload.compaction summary coverage tokensBefore =>
          let sourceBoundary := e.origin.extras.bind (fun extras =>
            cNonNull (cobj extras "claudeRawCompactionBoundary"))
          Json.mkObj ([("type", Json.str "system"),
              ("subtype", Json.str "agent_convert_compaction")] ++ stamp ++ [
            ("content", Json.str
              "Historical compaction summary retained by agent-convert; not user dialogue"),
            (claudeCarrierMarkerKey, cCompactionCarrierMarker summary coverage tokensBefore
              provenanceRaw sourceBoundary identityProvenance timeProvenance)])
      | _ =>
          let payload := cWholeHistoricalPayload i e carrierIndices
          Json.mkObj ([
            ("type", Json.str "system"), ("subtype", Json.str "agent_convert_inert")]
            ++ stamp ++ [
              -- No visible text: see `cInertPayloadCarrierMarker`.
              ("content", Json.null),
              (claudeCarrierMarkerKey,
                cInertPayloadCarrierMarker payload provenanceRaw
                  identityProvenance timeProvenance)])
    else match e.payload with
    | Payload.userMsg blocks =>
        Json.mkObj ([("type", Json.str "user")] ++ ordinaryStamp
          ++ [("message", Json.mkObj [("role", Json.str "user"),
                ("content", Json.arr ((blocks.map claudeUserBlockToJson).toArray))])])
    | Payload.assistantMsg blocks =>
        Json.mkObj ([("type", Json.str "assistant")] ++ ordinaryStamp
          ++ [("message", Json.mkObj [("role", Json.str "assistant"),
                ("content", Json.arr ((blocks.zipIdx.map (fun (block, blockIdx) =>
                  cAssistantBlockToJsonAt t i blockIdx block)).toArray))])])
    | Payload.envMsg blocks =>
        Json.mkObj ([("type", Json.str "user")] ++ ordinaryStamp
          ++ [("message", Json.mkObj [("role", Json.str "user"),
                ("content", Json.arr ((blocks.zipIdx.map (fun (block, blockIdx) =>
                  cEnvBlockToJsonAt t i blockIdx block)).toArray))])])
    | payload@(.otherMsg _ _) =>
        Json.mkObj ([
          ("type", Json.str "system"), ("subtype", Json.str "agent_convert_inert")]
          ++ stamp ++ [
            -- No visible text: see `cInertPayloadCarrierMarker`.
            ("content", Json.null),
            (claudeCarrierMarkerKey,
              cInertPayloadCarrierMarker payload provenanceRaw
                identityProvenance timeProvenance)])
    | Payload.compaction summary coverage tokensBefore =>
        let sourceBoundary := e.origin.extras.bind (fun extras =>
          cNonNull (cobj extras "claudeRawCompactionBoundary"))
        Json.mkObj ([("type", Json.str "system"),
            ("subtype", Json.str "agent_convert_compaction")] ++ stamp ++ [
          ("content", Json.str
            "Historical compaction summary retained by agent-convert; not user dialogue"),
          (claudeCarrierMarkerKey, cCompactionCarrierMarker summary coverage tokensBefore
            provenanceRaw sourceBoundary identityProvenance timeProvenance)])
    | payload@(.event _) =>
        Json.mkObj ([
          ("type", Json.str "system"), ("subtype", Json.str "agent_convert_inert")]
          ++ stamp ++ [
            -- No visible text: see `cInertPayloadCarrierMarker`.
            ("content", Json.null),
            (claudeCarrierMarkerKey,
              cInertPayloadCarrierMarker payload provenanceRaw
                identityProvenance timeProvenance)])
  let base := render none
  let mergedBase := match rawEnvelope with
    | some raw => cMergeClaudeEnvelopeMetadata raw base
    | none => base
  let provenanceRaw := rawEnvelope.filter (fun raw => raw != mergedBase)
  let generated := render provenanceRaw
  match rawEnvelope with
  | some raw => cMergeClaudeEnvelopeMetadata raw generated
  | none => generated

/-- Public single-entry renderer. UUID allocation still considers the complete
transcript so standalone calls cannot disagree with `exportClaudeCode`. -/
def claudeEntryToJson (t : Transcript) (i : Nat) (e : Entry) : Json :=
  cClaudeEntryToJson t (cClaudeEntryUuidPlan t) i e

private def cTranscriptArchivedControls (t : Transcript) : List ClaudeArchivedControl :=
  match t.origin.extras >>= fun extras => carr extras "raw_control_messages" with
  | some values => values.toList.filterMap cParseArchivedControlJson?
  | none => []

private def cTranscriptArchivedRecords (t : Transcript) : List ClaudeArchivedRecord :=
  match t.origin.extras >>= fun extras => carr extras "raw_inert_records" with
  | some values => values.toList.filterMap cParseArchivedRecordJson?
  | none => []

private def cExportLastPrompt?
    (t : Transcript) (uuidPlan : List String) : Option Json := do
  let active ← t.activeLeaf
  let leafUuid ← uuidPlan[active]?
  let generated := Json.mkObj [
    ("type", Json.str "last-prompt"),
    ("sessionId", Json.str (cClaudeTargetSessionId t)),
    ("leafUuid", Json.str leafUuid)]
  let raw := t.origin.extras >>= fun extras => cobj extras "raw_last_prompt"
  pure (match raw with
    | some source => cMergeClaudeEnvelopeMetadata source generated
    | none => generated)

private def cClaudeTimestampFieldError
    (ctx key : String) (j : Json) : Option String :=
  match cobj j key with
  | none => none
  | some (Json.str value) =>
      if (iso8601ToEpochMs? value).isSome then none
      else some s!"{ctx} must be UTC ISO-8601 with optional seconds or exactly millisecond precision"
  | some _ => some s!"{ctx} must be a string"

private def cClaudeOriginTimestampErrors
    (ctx : String) (origin : Origin) : List String :=
  match origin.extras with
  | none => []
  | some extras =>
      (match cClaudeTimestampFieldError (ctx ++ ".ts") "ts" extras with
       | some error => [error]
       | none => []) ++
      (match cobj extras "claudeRawEnvelope" with
       | some raw@(Json.obj _) =>
           match cClaudeTimestampFieldError
               (ctx ++ ".claudeRawEnvelope.timestamp") "timestamp" raw with
           | some error => [error]
           | none => []
       | _ => [])

private def cClaudeTimestampMs? (j : Json) (key : String) : Option Nat := do
  let value ← cstr j key
  pure (← iso8601ToEpochMs? value).ms

private def cClaudeRecordedTimeConflictErrors
    (ctx : String) (entry : Entry) : List String :=
  match entry.time, entry.origin.extras with
  | .recorded timestamp, some extras =>
      let conflict := fun (field : String) (value : Option Nat) =>
        match value with
        | some milliseconds =>
            if milliseconds == timestamp.ms then []
            else [s!"{ctx}.{field} conflicts with typed recorded time"]
        | none => []
      conflict "origin.ts" (cClaudeTimestampMs? extras "ts") ++
        (match cobj extras "claudeRawEnvelope" with
         | some raw@(Json.obj _) => conflict "origin.claudeRawEnvelope.timestamp"
             (cClaudeTimestampMs? raw "timestamp")
         | _ => [])
  | _, _ => []

/-- Public conversion-policy probe: a preferred target/source/raw timestamp is
present but cannot be emitted as a valid Claude UTC timestamp. Conversion/Main
can surface this before invoking the checked renderer. -/
def claudeHasInvalidPreferredTimestamp (t : Transcript) : Bool :=
  let targetErrors :=
    match t.origin.extras with
    | some extras =>
        match cClaudeTimestampFieldError "target_timestamp" "target_timestamp" extras with
        | some _ => true
        | none => false
    | none => false
  targetErrors || !(cClaudeOriginTimestampErrors "transcript.origin" t.origin).isEmpty ||
    t.entries.toList.zipIdx.any (fun (entry, entryIdx) =>
      !(cClaudeOriginTimestampErrors s!"entries[{entryIdx}].origin"
        entry.origin).isEmpty ||
      !(cClaudeRecordedTimeConflictErrors s!"entries[{entryIdx}]" entry).isEmpty)

/-- Precise, stable prerequisites for producing resumable Claude JSONL.
Claude has no resumable representation for an empty or provenance-only
transcript, so both are refused before any artifact is emitted. -/
def claudeExportPrerequisiteErrors (t : Transcript) : List String :=
  if t.entries.isEmpty then
    ["Claude export requires at least one entry for a resumable target"]
  else
    let targetErrors :=
      match t.origin.extras with
      | some extras =>
          match cClaudeTimestampFieldError
              "target_timestamp" "target_timestamp" extras with
          | some error => [error]
          | none => []
      | none => []
    let retargeted := !cClaudeEnvIsPhysicalTarget t
    -- Unsupported and malformed target/source-env controls refuse before emission,
    -- so no target_* key is silently ignored and no forged carrier survives.
    let unsupportedTargetErrors := (cClaudeUnsupportedTargetKeys t).map (fun key =>
      s!"Claude export does not support target field '{key}'; Claude's resumable JSONL has no slot for it")
    let carrierErrors :=
      match t.origin.extras >>= fun extras => cobj extras "source_env" with
      | some _ =>
          if (cClaudeSourceEnvCarrier? t).isSome then []
          else ["Claude export source_env carrier is malformed and refused"]
      | none => []
    let rawCarrierErrors :=
      match t.origin.extras >>= fun extras =>
          cobj extras claudeSourceEnvRawCarrierExtrasKey with
      | some _ =>
          if (cClaudeRawSourceEnvCarrier? t).isSome then []
          else ["Claude export preserved source-environment carrier is malformed and refused"]
      | none => []
    -- A retargeted export asserts, but never serializes, the reader Claude Code
    -- build. It must match the external validation build exactly; source
    -- harnessVersion lives only in the inert source-env carrier.
    let harnessVersionErrors :=
      if retargeted then
        match cClaudeExtraNonempty? t "target_harness_version" with
        | none =>
            [s!"Claude export requires origin.extras.target_harness_version = '{claudeTargetValidationBuild}' for a non-native target"]
        | some version =>
            if version == claudeTargetValidationBuild then []
            else [s!"Claude export target_harness_version must be '{claudeTargetValidationBuild}', got '{version}'"]
      else []
    let targetTimestampPresent :=
      (t.origin.extras >>= fun extras =>
        (extras.getObjVal? "target_timestamp").toOption).isSome
    let targetTimestampErrors :=
      if retargeted && !targetTimestampPresent then
        ["Claude export requires origin.extras.target_timestamp for a non-native target"]
      else []
    -- Launch identity: retargeted exports require the complete explicit bundle
    -- (absolute cwd + UUID session) and never fall back to source EnvInfo.
    let cwdErrors :=
      match cClaudeTargetCwd? t with
      | none =>
          if retargeted then
            ["Claude export requires origin.extras.target_cwd for a non-native target; source EnvInfo is not a launch target"]
          else ["Claude export requires a nonempty cwd for a nonempty transcript"]
      | some cwd =>
          if retargeted && !claudeAbsoluteTargetCwd cwd then
            [s!"Claude export target_cwd must be an absolute path, got '{cwd}'"]
          else []
    let sessionErrors :=
      match cClaudeTargetSessionRequested? t with
      | none =>
          if retargeted then
            ["Claude export requires origin.extras.target_session_id (a UUID) for a non-native target"]
          else ["Claude export requires a UUID env.sessionId or transcript origin.rawId for a resumable target"]
      | some sessionId =>
          if claudeUuidValid sessionId then []
          else ["Claude export target sessionId must be a UUID"]
    let entryErrors := t.entries.toList.zipIdx.flatMap (fun (entry, entryIdx) =>
      cClaudeOriginTimestampErrors s!"entries[{entryIdx}].origin" entry.origin ++
      cClaudeRecordedTimeConflictErrors s!"entries[{entryIdx}]" entry ++
      (if retargeted || (cClaudeEntryTimestamp? t entry).isSome then [] else
        [s!"entries[{entryIdx}] requires a valid source timestamp, recorded time, or target_timestamp"]))
    let activeErrors :=
      match t.activeLeaf with
      | none => ["Claude export requires activeLeaf for a nonempty transcript"]
      | some active =>
          if active >= t.entries.size then
            [s!"Claude export activeLeaf {active} is out of range"]
          else if t.entries.toList.any (fun entry => entry.parent == some active) then
            [s!"Claude export activeLeaf {active} has a child and is not a leaf"]
          else []
    targetErrors ++ unsupportedTargetErrors ++ carrierErrors ++ rawCarrierErrors ++
      harnessVersionErrors ++ targetTimestampErrors ++
      cClaudeOriginTimestampErrors "transcript.origin" t.origin ++
      cwdErrors ++ sessionErrors ++ entryErrors ++ activeErrors

def claudeExportPreflight (t : Transcript) : Except String Unit :=
  let structural := Loom.violations t
  if !structural.isEmpty then
    .error s!"Claude source transcript has structural violations: {reprStr structural}"
  else
    let destructive := (Loom.Ops.obligations .claudeCode t).filter
      (Loom.Ops.obligationIsDestructiveFor .claudeCode t)
    if !destructive.isEmpty then
      .error s!"Claude target has destructive export obligations: {reprStr destructive}"
    else
      match claudeExportPrerequisiteErrors t with
      | [] => pure ()
      | error :: _ => .error error

/-- Loom IR → Claude Code JSONL (one compact JSON object per line). The terminal
delimiter is required because Claude appends resumed turns in place. The inverse
of `importClaudeCode`; `roundTripClaude` pins that import→export→import is stable
under the structural projection `normalize`. -/
private def cRenderClaudeCodeCandidate (t : Transcript) : String :=
  let n := t.entries.size
  let uuidPlan := cClaudeEntryUuidPlan t
  let entryLines := (List.range n).filterMap (fun i =>
    (t.entries[i]?).map (fun (e : Entry) =>
      (cClaudeEntryToJson t uuidPlan i e).compress))
  let controlLines := (cTranscriptArchivedControls t).map (fun control =>
    (cTranscriptProvenanceCarrier "control" (cArchivedControlJson control)).compress)
  let recordLines := (cTranscriptArchivedRecords t).map (fun record =>
    (cTranscriptProvenanceCarrier "record" (cArchivedRecordJson record)).compress)
  -- A retargeted export preserves the complete source `EnvInfo` in one inert
  -- carrier. A native session emits none, so native output stays byte-stable.
  let sourceEnvLines :=
    if cClaudeEnvIsPhysicalTarget t then []
    else [(cSourceEnvCarrierForExport t).compress]
  let pointerLines := (cExportLastPrompt? t uuidPlan).map (fun pointer =>
    [pointer.compress]) |>.getD []
  let lines := entryLines ++ controlLines ++ recordLines ++ sourceEnvLines ++ pointerLines
  if lines.isEmpty then "" else String.intercalate "\n" lines ++ "\n"

/-- Checked Claude exporter. Besides validating all preferred timestamps and
required target fields, it re-imports the candidate and verifies that Claude's
authoritative resume pointer still identifies the requested active occurrence. -/
def exportClaudeCodeChecked (t : Transcript) : Except String String := do
  claudeExportPreflight t
  let output := cRenderClaudeCodeCandidate t
  let restored ← importClaudeCode output
  let active ← match t.activeLeaf with
    | some active => pure active
    | none => .error "Claude export requires activeLeaf for a nonempty transcript"
  let expectedUuid ← match (cClaudeEntryUuidPlan t)[active]? with
    | some uuid => pure uuid
    | none => .error s!"Claude export activeLeaf {active} is out of range"
  let actualUuid := restored.activeLeaf.bind (fun leaf =>
    restored.entries[leaf]? >>= fun entry => entry.origin.rawId)
  if actualUuid == some expectedUuid then pure output
  else .error s!"Claude active-leaf round trip selected {actualUuid}, expected '{expectedUuid}'"

/-- Compatibility API. Checked-export failure returns no artifact; callers that
need the diagnostic use `exportClaudeCodeChecked`. -/
def exportClaudeCode (t : Transcript) : String :=
  match exportClaudeCodeChecked t with
  | .ok output => output
  | .error _ => ""

/-- Archived Claude controls never become conversation. Export carries their
typed archive records, and re-import restores that archive exactly. -/
def claudeControlsNeverExportedAsConversation : Bool :=
  match importClaudeCode claudeControlImportFixture with
  | .error _ => false
  | .ok imported =>
      let exported := exportClaudeCode imported
      match cParseClaudeJsonLines exported, importClaudeCode exported with
      | .ok records, .ok restored =>
          records.countP (fun record =>
            cstr record "type" == some "user" ||
              cstr record "type" == some "assistant") == 3 &&
          cControlConversationPreserved restored &&
          (cArchivedControls? restored).map Array.size ==
            (cArchivedControls? imported).map Array.size
      | _, _ => false

example : claudeControlsNeverExportedAsConversation = true := by native_decide

/-! ## Self-parity (RC1) — import → export → import stable under `normalize`. -/

/-- Import → export → import must be stable under the structural projection
`normalize`. If `exportClaudeCode` drops or reshapes anything the importer then
reads back differently, the two normal forms diverge and this stops compiling. -/
def roundTripClaude (text : String) : Bool :=
  match importClaudeCode text with
  | .error _ => false
  | .ok t => normalize t == (match importClaudeCode (exportClaudeCode t) with
                             | .ok t2 => normalize t2
                             | .error _ => "ERR")

/-- THE DECIDE-PIN (self-parity, RC1): round-trip stability of the Claude
importer/exporter pair, folded into `lake build`. Proves import→export→import is
a fixed point of `normalize` for the same fixture the cross-parity pin uses. -/
example : roundTripClaude claudeFixture = true := by native_decide

def claudeExportEndsWithRecordDelimiter : Bool :=
  match importClaudeCode claudeFixture with
  | .ok transcript => (exportClaudeCode transcript).endsWith "\n"
  | .error _ => false

example : claudeExportEndsWithRecordDelimiter = true := by native_decide

private def cClaudeFixtureTargetReady (t : Transcript) : Transcript :=
  let cwd := (cNonemptyString? t.env.cwd).getD "/tmp"
  let session := cClaudeFixtureUuid
    ((cNonemptyString? t.env.sessionId).getD "claude-test-session")
  let target := "2026-07-20T00:00:00.000Z"
  let bundle : List (String × Json) := [
    ("target_timestamp", Json.str target), ("target_cwd", Json.str cwd),
    ("target_session_id", Json.str session),
    ("target_harness_version", Json.str claudeTargetValidationBuild)]
  let extras := match t.origin.extras with
    | some (Json.obj fields) =>
        Json.obj (bundle.foldl (fun (f : Std.TreeMap.Raw String Json) (k, v) =>
          f.insert k v) fields)
    | some prior => Json.mkObj (("priorExtras", prior) :: bundle)
    | none => Json.mkObj bundle
  { t with
    env := { t.env with cwd := some cwd, sessionId := some session }
    origin := { t.origin with extras := some extras } }

private def cExportClaudeFixture (t : Transcript) : String :=
  exportClaudeCode (cClaudeFixtureTargetReady t)

private def claudeOpenToolCarrierFixture : Transcript :=
  let entryOrigin : Origin := {
    format := Format.codexCli, sourceRef := "open-tool-fixture", rawId := some "entry-0" }
  { threads := #[{ kind := ThreadKind.main }],
    entries := #[{
      payload := Payload.assistantMsg [AssistantBlock.toolCall
        { raw := "exec", canonical := none }
        (Json.mkObj [("input", Json.str "text(await tools.exec_command({cmd: 'pwd'}))")])
        (some "call-open")],
      origin := entryOrigin }],
    activeLeaf := some 0,
    origin := { format := Format.codexCli, sourceRef := "open-tool-fixture" } }

/-- The Claude safety carrier has three checked properties: no native open call
or fabricated result is emitted, one carrier is reported, and importing the
emitted Claude artifact reconstructs the exact id/name/arguments. -/
def claudeOpenToolCarrierRoundTrip : Bool :=
  let (safe, carried) := historicalizeOpenToolCallsForClaude claudeOpenToolCarrierFixture
  let safeHasNoNativeCall := Loom.Ops.openCalls safe == []
  let safeHasNoResult := Loom.Ops.resolvedRefs safe == []
  let restored := importClaudeCode (cExportClaudeFixture safe)
  carried == 1 && safeHasNoNativeCall && safeHasNoResult &&
    match restored with
    | .error _ => false
    | .ok transcript =>
        match transcript.entries[0]? with
        | some entry =>
            match entry.payload with
            | Payload.assistantMsg [AssistantBlock.toolCall name args rawId] =>
                name.raw == "exec" && rawId == some "call-open" &&
                args == Json.mkObj [
                  ("input", Json.str "text(await tools.exec_command({cmd: 'pwd'}))")]
            | _ => false
        | none => false

example : claudeOpenToolCarrierRoundTrip = true := by native_decide

private def claudeAnchoredOpenToolFixture : Transcript :=
  let origin : Origin := {
    format := .claudeCode, sourceRef := "anchored-open-tool-fixture" }
  { threads := #[
      { kind := .main },
      { kind := .sidechain (.resolved 0 0), label := some "worker" }],
    entries := #[
      { payload := .assistantMsg [
          .toolCall { raw := "Task" }
            (Json.mkObj [("prompt", Json.str "child")]) (some "toolu_child")],
        origin := origin },
      { thread := 1, payload := .assistantMsg [.text "child done"],
        origin := origin }],
    activeLeaf := some 1,
    origin := origin }

/-- Sidecar anchors are structural links, not interrupted calls. The Claude
target policy must retain them natively or it would invalidate the thread. -/
def claudeSidechainAnchorSurvivesOpenCallPolicy : Bool :=
  let (safe, carried) := historicalizeOpenToolCallsForClaude claudeAnchoredOpenToolFixture
  carried == 0 && (Loom.violations safe).isEmpty &&
    match safe.entries[0]? with
    | some entry =>
        match entry.payload with
        | .assistantMsg [.toolCall _ _ (some "toolu_child")] => true
        | _ => false
    | none => false

example : claudeSidechainAnchorSurvivesOpenCallPolicy = true := by native_decide

/-! ## Historical-tool policy pins -/

private def cContains (text needle : String) : Bool :=
  decide ((text.splitOn needle).length > 1)

private def claudeUuidTopologyFixture : Transcript :=
  let origin (rawId : Option String) : Origin := {
    format := .claudeCode, sourceRef := "uuid-topology-fixture", rawId }
  { threads := #[{ kind := .main }],
    entries := #[
      { payload := .userMsg [.text "root"], origin := origin (some "dup") },
      { parent := some 0, payload := .assistantMsg [.text "left"],
        origin := origin none },
      { parent := some 1, payload := .assistantMsg [.text "right"],
        origin := origin (some "dup") },
      { parent := some 2, payload := .userMsg [.text "left child"],
        origin := origin (some "e1") },
      { parent := some 3, payload := .userMsg [.text "right child"],
        origin := origin (some "dup#loom1") }],
    activeLeaf := some 4,
    origin := { format := .claudeCode, sourceRef := "uuid-topology-fixture" } }

private def cStringsDistinct (values : List String) : Bool :=
  values.zipIdx.all (fun (value, index) => !(values.take index).contains value)

/-- UUID allocation covers invalid, missing, and duplicate source IDs in one
domain, and parent references use exactly the same allocation table. -/
def claudeExportUuidTopologyChecked : Bool :=
  let source := claudeUuidTopologyFixture
  match cParseClaudeJsonLines (cExportClaudeFixture source) with
  | .error _ => false
  | .ok records =>
      let entryRecords := records.filter (fun record => (cstr record "uuid").isSome)
      let uuids := entryRecords.filterMap (fun record => cstr record "uuid")
      uuids.length == source.entries.size && cStringsDistinct uuids &&
        entryRecords.zipIdx.all (fun (record, entryIdx) =>
          match source.entries[entryIdx]? with
          | none => false
          | some entry =>
              cstr record "uuid" == uuids[entryIdx]? &&
              cstr record "parentUuid" == entry.parent.bind (fun parent => uuids[parent]?))

example : claudeExportUuidTopologyChecked = true := by native_decide

private def claudeCodexHistoricalFixture : Transcript :=
  let origin (id : String) : Origin := {
    format := .codexCli, sourceRef := "codex-history-fixture", rawId := some id }
  let callArgsA := Json.arr #[
    Json.num (Lean.JsonNumber.fromNat 7),
    Json.mkObj [("nested", Json.arr #[Json.bool true, Json.null])]]
  let callArgsB := Json.mkObj [
    ("path", Json.str "/tmp/a b"),
    ("payload", Json.mkObj [("quote", Json.str "x\ny\"z")])]
  { threads := #[{ kind := .main }],
    entries := #[
      { payload := .assistantMsg [
          .text "before",
          .toolCall { raw := "array_args", canonical := none } callArgsA (some "dup"),
          .text "between",
          .toolCall { raw := "object_args", canonical := none } callArgsB (some "dup"),
          .toolCall { raw := "boolean_args", canonical := none } (Json.bool false)
            (some "third:id"),
          .toolCall { raw := "open_call", canonical := none } Json.null none],
        origin := origin "hc0" },
      { parent := some 0,
        payload := .envMsg [
          .toolResult (.resolved 0 3) [
            .text "B-1",
            .media "image/png" "data:image/png;base64,iVBORw0KGgoAAAA",
            .unmodeled "structured" (Json.mkObj [
              ("type", Json.str "custom_result"),
              ("items", Json.arr #[Json.num (Lean.JsonNumber.fromNat 1), Json.bool false])])]
            (.inferred true "codex exit-code heuristic"),
          .toolResult (.resolved 0 1) [.text "A-1", .text "A-2"] (.native false),
          .toolResult (.resolved 0 4) [] .unrecorded],
        origin := origin "hc1" },
      { parent := some 1, payload := .assistantMsg [.text "after"],
        origin := origin "hc2" }],
    activeLeaf := some 2,
    origin := { format := .codexCli, sourceRef := "codex-history-fixture" } }

private def cCodexHistoricalCallsRestored : Payload → Bool
  | .assistantMsg [
      .text "before",
      .toolCall nameA argsA (some "dup"),
      .text "between",
      .toolCall nameB argsB (some "dup"),
      .toolCall nameC argsC (some "third:id"),
      .toolCall nameD argsD none] =>
      nameA.raw == "array_args" &&
      argsA == Json.arr #[
        Json.num (Lean.JsonNumber.fromNat 7),
        Json.mkObj [("nested", Json.arr #[Json.bool true, Json.null])]] &&
      nameB.raw == "object_args" &&
      argsB == Json.mkObj [
        ("path", Json.str "/tmp/a b"),
        ("payload", Json.mkObj [("quote", Json.str "x\ny\"z")])] &&
      nameC.raw == "boolean_args" && argsC == Json.bool false &&
      nameD.raw == "open_call" && argsD == Json.null
  | _ => false

private def cCodexHistoricalResultsRestored : Payload → Bool
  | .envMsg [
      .toolResult (.resolved 0 3)
        [.text "B-1", .media "image/png" image,
         .unmodeled "structured" raw]
        (.inferred true "codex exit-code heuristic"),
      .toolResult (.resolved 0 1) [.text "A-1", .text "A-2"] (.native false),
      .toolResult (.resolved 0 4) [] .unrecorded] =>
      image == "data:image/png;base64,iVBORw0KGgoAAAA" &&
      raw == Json.mkObj [
        ("type", Json.str "custom_result"),
        ("items", Json.arr #[Json.num (Lean.JsonNumber.fromNat 1), Json.bool false])]
  | _ => false

private def cCodexHistoricalRestored (t : Transcript) : Bool :=
  t.entries.size == 3 &&
  match t.entries[0]?, t.entries[1]?, t.entries[2]? with
  | some first, some second, some third =>
      cCodexHistoricalCallsRestored first.payload &&
      cCodexHistoricalResultsRestored second.payload &&
      (match third.payload with | .assistantMsg [.text "after"] => true | _ => false)
  | _, _, _ => false

/-- Codex policy: every call/result is a carrier, direct export cannot bypass
the policy, no synthetic result appears, and re-import restores exact lifecycle
data plus occurrence linkage despite duplicate IDs and result reordering. -/
def claudeCodexHistoricalLifecycleRoundTrip : Bool :=
  let source := claudeCodexHistoricalFixture
  let (historical, counts) := historicalizeCodexToolsForClaude source
  let transformedExport := cExportClaudeFixture historical
  let directExport := cExportClaudeFixture source
  counts == { calls := 4, results := 3 } &&
  Loom.Ops.callSites historical == [] && cToolResultCount historical == 0 &&
  !cContains transformedExport "\"type\":\"tool_use\"" &&
  !cContains transformedExport "\"type\":\"tool_result\"" &&
  !cContains directExport "\"type\":\"tool_use\"" &&
  !cContains directExport "\"type\":\"tool_result\"" &&
  cContains directExport ("\"" ++ claudeCarrierMarkerKey ++ "\"") &&
  -- entries + resume pointer + one inert source-environment carrier (retargeted).
  ((directExport.splitOn "\n").filter (fun line => !line.isEmpty)).length ==
      source.entries.size + 2 &&
  match importClaudeCode directExport, importClaudeCode transformedExport with
  | .ok direct, .ok transformed =>
      cCodexHistoricalRestored direct && cCodexHistoricalRestored transformed &&
      cToolResultCount direct == 3 && Loom.Ops.openCalls direct == [(0, 5)]
  | _, _ => false

example : claudeCodexHistoricalLifecycleRoundTrip = true := by native_decide

private def cClaudeTestLine
    (kind role uuid : String) (parent : Option String) (timestamp : String)
    (content : Array Json) (carrierBlocks : List Nat := []) : String :=
  (Json.mkObj ([
    ("type", Json.str kind), ("uuid", Json.str (cClaudeFixtureUuid uuid)),
    ("parentUuid", parent.map (fun value => Json.str (cClaudeFixtureUuid value))
      |>.getD Json.null),
    ("sessionId", Json.str (cClaudeFixtureUuid "carrier-test")),
    ("cwd", Json.str "/tmp"),
    ("timestamp", Json.str (cClaudeFixtureTimestamp timestamp)),
    ("isSidechain", Json.bool false)] ++
    cCarrierTopLevelStamp carrierBlocks ++
    [("message", Json.mkObj [
      ("role", Json.str role), ("content", Json.arr content)])])).compress

private def claudeOrphanReuseFixture : String := String.intercalate "\n" [
  cClaudeTestLine "user" "user" "or0" none "T0" #[
    Json.mkObj [("type", Json.str "tool_result"),
      ("tool_use_id", Json.str "reused-id"), ("is_error", Json.bool true),
      ("content", Json.str "orphan")]],
  cClaudeTestLine "assistant" "assistant" "or1" (some "or0") "T1" #[
    Json.mkObj [("type", Json.str "tool_use"), ("id", Json.str "reused-id"),
      ("name", Json.str "later_call"), ("input", Json.mkObj [("n", Json.num 1)])]],
  cClaudeTestLine "user" "user" "or2" (some "or1") "T2" #[
    Json.mkObj [("type", Json.str "tool_result"),
      ("tool_use_id", Json.str "reused-id"), ("is_error", Json.bool false),
      ("content", Json.str "valid")]],
  cClaudeTestLine "user" "user" "or3" (some "or2") "T3" #[
    Json.mkObj [("type", Json.str "tool_result"),
      ("tool_use_id", Json.str "reused-id"), ("is_error", Json.bool true),
      ("content", Json.str "repeat")]]
]

private def cOrphanReuseShape (t : Transcript) : Bool :=
  t.entries.size == 4 &&
  match t.entries[0]?, t.entries[1]?, t.entries[2]?, t.entries[3]? with
  | some orphan, some call, some valid, some repeated =>
      (match orphan.payload with
       | .envMsg [.toolResult (.unresolved (some "reused-id") _)
           [.text "orphan"] (.native true)] => true
       | _ => false) &&
      (match call.payload with
       | .assistantMsg [.toolCall name _ (some "reused-id")] =>
           name.raw == "later_call"
       | _ => false) &&
      (match valid.payload with
       | .envMsg [.toolResult (.resolved 1 0) [.text "valid"] (.native false)] => true
       | _ => false) &&
      (match repeated.payload with
       | .envMsg [.toolResult (.unresolved (some "reused-id") _)
           [.text "repeat"] (.native true)] => true
       | _ => false)
  | _, _, _, _ => false

/-- An orphan does not consume a call occurrence. The next real call/result pair
links, while a subsequent repeat truthfully remains unresolved. The checked
export boundary refuses the resulting malformed IR instead of normalizing away
either unresolved occurrence. -/
def claudeOrphanReuseOccurrenceChecked : Bool :=
  match importClaudeCode claudeOrphanReuseFixture with
  | .error _ => false
  | .ok imported =>
      cOrphanReuseShape imported &&
      !(Loom.violations imported).isEmpty && exportClaudeCode imported == "" &&
      match exportClaudeCodeChecked imported with
      | .error error => error.startsWith
          "Claude source transcript has structural violations:"
      | .ok _ => false

example : claudeOrphanReuseOccurrenceChecked = true := by native_decide

private def claudeControlRoleFixture : Transcript :=
  let origin (id : String) : Origin := {
    format := .claudeCode, sourceRef := "control-role-fixture", rawId := some id }
  { threads := #[{ kind := .main }],
    entries := #[
      { payload := .userMsg [.text "before"], origin := origin "cr0" },
      { parent := some 0, payload := .otherMsg "system" [.text "system context"],
        origin := origin "cr1" },
      { parent := some 1, payload := .otherMsg "developer" [.text "developer context"],
        origin := origin "cr2" },
      { parent := some 2, payload := .assistantMsg [.text "after"],
        origin := origin "cr3" }],
    activeLeaf := some 3,
    origin := { format := .claudeCode, sourceRef := "control-role-fixture" } }

private def claudeMismatchedRoleFixture : String := String.intercalate "\n" [
  cClaudeTestLine "user" "user" "mr0" none "T0" #[
    Json.mkObj [("type", Json.str "text"), ("text", Json.str "before")]],
  cClaudeTestLine "user" "system" "mr1" (some "mr0") "T1" #[
    Json.mkObj [("type", Json.str "text"), ("text", Json.str "system context")]],
  cClaudeTestLine "user" "developer" "mr2" (some "mr1") "T2" #[
    Json.mkObj [("type", Json.str "text"), ("text", Json.str "developer context")]],
  cClaudeTestLine "assistant" "assistant" "mr3" (some "mr2") "T3" #[
    Json.mkObj [("type", Json.str "text"), ("text", Json.str "after")]]
]

private def cControlRolesAbsentFromDialogue (t : Transcript) : Bool :=
  t.entries.size == 2 &&
  match t.entries[0]?, t.entries[1]? with
  | some before, some after =>
      (match before.payload with | .userMsg [.text "before"] => true | _ => false) &&
      (match after.payload with | .assistantMsg [.text "after"] => true | _ => false) &&
      after.parent == some 0
  | _, _ => false

/-- `.otherMsg` round-trips through graph-preserving inert carriers, while
explicit user-envelope role mismatches are archived rather than reclassified. -/
def claudeControlRolesNeverBecomeUserDialogue : Bool :=
  let exported := cExportClaudeFixture claudeControlRoleFixture
  match cParseClaudeJsonLines exported, importClaudeCode exported,
        importClaudeCode claudeMismatchedRoleFixture with
  | .ok records, .ok restored, .ok mismatched =>
      match records[1]?, records[2]? with
      | some systemRecord, some developerRecord =>
          cstr systemRecord "type" == some "system" &&
          cstr developerRecord "type" == some "system" &&
          (match restored.entries[1]?, restored.entries[2]? with
           | some systemEntry, some developerEntry =>
               (match systemEntry.payload with
                | .otherMsg "system" [.text "system context"] => true
                | _ => false) &&
               (match developerEntry.payload with
                | .otherMsg "developer" [.text "developer context"] => true
                | _ => false)
           | _, _ => false) && restored.entries.size == 4 &&
          cControlRolesAbsentFromDialogue mismatched
      | _, _ => false
  | _, _, _ => false

example : claudeControlRolesNeverBecomeUserDialogue = true := by native_decide

private def claudeCarrierSpoofText : String :=
  cHistoricalToolCallCarrierText { raw := "quoted_tool", canonical := none }
    (Json.mkObj [("quoted", Json.bool true)]) (some "quoted-id") (some "0:0")
    "quoted carrier example"

private def claudeResultCarrierSpoofText : String :=
  claudeHistoricalToolResultCarrierText claudeCodexHistoricalFixture 1 0
    (.resolved 0 1) [.text "quoted result"] (.inferred false "quoted heuristic")

private def claudeCarrierSpoofFixture : String := String.intercalate "\n" [
  cClaudeTestLine "assistant" "assistant" "sp0" none "T0" #[
    Json.mkObj [("type", Json.str "text"), ("text", Json.str claudeCarrierSpoofText)]],
  cClaudeTestLine "user" "user" "sp1" (some "sp0") "T1" #[
    Json.mkObj [("type", Json.str "text"), ("text", Json.str claudeResultCarrierSpoofText)]]
]

private def claudeIndexedCarrierFixture : String :=
  cClaudeTestLine "assistant" "assistant" "ix0" none "T0" #[
    Json.mkObj [("type", Json.str "text"), ("text", Json.str claudeCarrierSpoofText)],
    Json.mkObj [("type", Json.str "text"), ("text", Json.str claudeCarrierSpoofText)]] [0]

/-- Carrier decoding requires both the self-identifying protocol marker and the
exact content-block index. This is a format distinction, not authentication.
Unmarked byte-identical text and unlisted siblings remain ordinary prose. -/
def claudeCarrierMarkerChecked : Bool :=
  match importClaudeCode claudeCarrierSpoofFixture,
        importClaudeCode claudeIndexedCarrierFixture with
  | .ok spoof, .ok indexed =>
      let indexedExport := exportClaudeCode indexed
      cToolResultCount spoof == 0 && Loom.Ops.callSites spoof == [] &&
      (match spoof.entries[0]?, spoof.entries[1]? with
       | some first, some second =>
           (match first.payload, second.payload with
            | .assistantMsg [.text callText], .userMsg [.text resultText] =>
                callText == claudeCarrierSpoofText &&
                resultText == claudeResultCarrierSpoofText
            | _, _ => false)
       | _, _ => false) &&
      (match indexed.entries[0]? with
       | some entry => match entry.payload with
         | .assistantMsg [
             .toolCall name args (some "quoted-id"), .text ordinary] =>
             name.raw == "quoted_tool" &&
             args == Json.mkObj [("quoted", Json.bool true)] &&
             ordinary == claudeCarrierSpoofText
         | _ => false
       | _ => false) &&
      !cContains indexedExport "\"type\":\"tool_use\"" &&
      match importClaudeCode indexedExport with
      | .ok restored => Loom.Ops.callSites restored == [(0, 0)]
      | .error _ => false
  | _, _ => false

example : claudeCarrierMarkerChecked = true := by native_decide

private def claudeDuplicateToolIdFixture : String := String.intercalate "\n" [
  cClaudeTestLine "assistant" "assistant" "du0" none "T0" #[
    Json.mkObj [("type", Json.str "tool_use"), ("id", Json.str "same-id"),
      ("name", Json.str "first"), ("input", Json.mkObj [("n", Json.num 1)])],
    Json.mkObj [("type", Json.str "tool_use"), ("id", Json.str "same-id"),
      ("name", Json.str "second"), ("input", Json.mkObj [("n", Json.num 2)])]],
  cClaudeTestLine "user" "user" "du1" (some "du0") "T1" #[
    Json.mkObj [("type", Json.str "tool_result"), ("tool_use_id", Json.str "same-id"),
      ("is_error", Json.bool false), ("content", Json.str "first-result")],
    Json.mkObj [("type", Json.str "tool_result"), ("tool_use_id", Json.str "same-id"),
      ("is_error", Json.bool true), ("content", Json.str "second-result")]]
]

/-- Duplicate unmatched Claude IDs are never paired by list order. Both results
remain explicitly ambiguous, and checked export refuses the malformed IR with
no artifact. -/
def claudeDuplicateToolIdOccurrenceChecked : Bool :=
  let shape := fun (transcript : Transcript) =>
    match transcript.entries[1]?, transcript.entries[2]? with
    | some first, some second =>
        match first.payload, second.payload with
        | .envMsg [
            .toolResult (.unresolved (some "same-id") _)
              [.text "first-result"] (.native false)],
          .envMsg [
            .toolResult (.unresolved (some "same-id") _)
              [.text "second-result"] (.native true)] => true
        | _, _ => false
    | _, _ => false
  match importClaudeCode claudeDuplicateToolIdFixture with
  | .error _ => false
  | .ok transcript =>
      shape transcript && !(Loom.violations transcript).isEmpty &&
      exportClaudeCode transcript == "" &&
      (match exportClaudeCodeChecked transcript with
       | .error error => error.startsWith
           "Claude source transcript has structural violations:"
       | .ok _ => false)

example : claudeDuplicateToolIdOccurrenceChecked = true := by native_decide

private def claudeForeignToolFixture (rawId : String) (args : Json) : Transcript :=
  let origin (id : String) : Origin := {
    format := .claudeCode, sourceRef := "native-schema-fixture", rawId := some id }
  { threads := #[{ kind := .main }],
    entries := #[
      { payload := .assistantMsg [
          .toolCall { raw := "checked_tool", canonical := none } args (some rawId)],
        origin := origin "ns0" },
      { parent := some 0,
        payload := .envMsg [
          .toolResult (.resolved 0 0) [.text "checked-result"] (.native false)],
        origin := origin "ns1" }],
    activeLeaf := some 1,
    origin := { format := .claudeCode, sourceRef := "native-schema-fixture" } }

private def cForeignToolRestored (expectedId : String) (expectedArgs : Json)
    (text : String) : Bool :=
  match importClaudeCode text with
  | .error _ => false
  | .ok transcript =>
      match transcript.entries[0]?, transcript.entries[1]? with
      | some callEntry, some resultEntry =>
          (match callEntry.payload with
           | .assistantMsg [.toolCall name args (some rawId)] =>
               name.raw == "checked_tool" && rawId == expectedId && args == expectedArgs
           | _ => false) &&
          (match resultEntry.payload with
           | .envMsg [
               .toolResult (.resolved 0 0) [.text "checked-result"] (.native false)] => true
           | _ => false)
      | _, _ => false

/-- Outside the Codex-wide policy, malformed native Claude calls are still not
emitted: invalid IDs and non-object `input` values get reversible lifecycle
carriers rather than an invalid `tool_use` schema. -/
def claudeNativeSchemaFallbackChecked : Bool :=
  let invalidIdArgs := Json.mkObj [("ok", Json.bool true)]
  let nonObjectArgs := Json.arr #[Json.str "not", Json.str "an object"]
  let invalidIdExport := cExportClaudeFixture
    (claudeForeignToolFixture "bad id" invalidIdArgs)
  let nonObjectExport := cExportClaudeFixture
    (claudeForeignToolFixture "valid-id" nonObjectArgs)
  !cContains invalidIdExport "\"type\":\"tool_use\"" &&
  !cContains invalidIdExport "\"type\":\"tool_result\"" &&
  !cContains nonObjectExport "\"type\":\"tool_use\"" &&
  !cContains nonObjectExport "\"type\":\"tool_result\"" &&
  cContains invalidIdExport ("\"" ++ claudeCarrierMarkerKey ++ "\"") &&
  cContains nonObjectExport ("\"" ++ claudeCarrierMarkerKey ++ "\"") &&
  cForeignToolRestored "bad id" invalidIdArgs invalidIdExport &&
  cForeignToolRestored "valid-id" nonObjectArgs nonObjectExport

example : claudeNativeSchemaFallbackChecked = true := by native_decide

private def claudeCrossFormatClosedToolFixture : Transcript :=
  let origin (id : String) : Origin := {
    format := .pi, sourceRef := "cross-format-tool-fixture", rawId := some id }
  { threads := #[{ kind := .main }],
    entries := #[
      { payload := .assistantMsg [
          .toolCall { raw := "checked_tool", canonical := none }
            (Json.mkObj [("path", Json.str "/tmp/foreign")]) (some "foreign-call")],
        origin := origin "xf0" },
      { parent := some 0,
        payload := .envMsg [
          .toolResult (.resolved 0 0) [.text "checked-result"] (.native false)],
        origin := origin "xf1" }],
    activeLeaf := some 1,
    origin := { format := .pi, sourceRef := "cross-format-tool-fixture" } }

private def claudeRawToolUseFixture : Transcript :=
  let origin : Origin := {
    format := .claudeCode, sourceRef := "raw-tool-use-fixture", rawId := some "rt0" }
  { threads := #[{ kind := .main }],
    entries := #[{
      payload := .assistantMsg [.unmodeled "raw-tool-use" (Json.mkObj [
        ("type", Json.str "tool_use"), ("id", Json.str "raw-call"),
        ("name", Json.str "raw_tool"),
        ("input", Json.mkObj [("unsafe", Json.bool true)])])],
      origin }],
    activeLeaf := some 0,
    origin }

private def cRawToolUseRestored (text : String) : Bool :=
  match importClaudeCode text with
  | .ok transcript =>
      match transcript.entries[0]? with
      | some entry => match entry.payload with
        | .assistantMsg [.unmodeled "raw-tool-use" raw] =>
            raw == Json.mkObj [
              ("type", Json.str "tool_use"), ("id", Json.str "raw-call"),
              ("name", Json.str "raw_tool"),
              ("input", Json.mkObj [("unsafe", Json.bool true)])]
        | _ => false
      | none => false
  | .error _ => false

/-- Native lifecycle output depends on target capability and structural
validity, never on source format.

A closed, structurally valid call therefore emits a native Claude lifecycle
whatever harness it came from, and survives re-import unchanged — this is the
property that makes a converted session resumable (`LoomOps.Interop`, P1).
This pin is the deliberate inverse of its former self, which asserted that
cross-format exports must NOT contain `tool_use`; that assertion made the
product's central defect a theorem of this codebase.

Raw lifecycle-SHAPED open-world blocks stay carriers: an `.unmodeled` blob
must never be promoted to executable state merely because its JSON resembles a
tool call. That distinction is structural, not provenance-based. -/
def claudeNativeRegistryPolicyChecked : Bool :=
  let foreignArgs := Json.mkObj [("path", Json.str "/tmp/foreign")]
  let crossExport := cExportClaudeFixture claudeCrossFormatClosedToolFixture
  let mixedOrigin := { claudeCrossFormatClosedToolFixture with
    origin := { format := .claudeCode, sourceRef := "mixed-origin-tool-fixture" } }
  let mixedExport := cExportClaudeFixture mixedOrigin
  let rawExport := cExportClaudeFixture claudeRawToolUseFixture
  cContains crossExport "\"type\":\"tool_use\"" &&
  cContains crossExport "\"type\":\"tool_result\"" &&
  cContains mixedExport "\"type\":\"tool_use\"" &&
  cContains mixedExport "\"type\":\"tool_result\"" &&
  !cContains rawExport "\"type\":\"tool_use\"" &&
  cContains rawExport ("\"" ++ claudeCarrierMarkerKey ++ "\"") &&
  cForeignToolRestored "foreign-call" foreignArgs crossExport &&
  cForeignToolRestored "foreign-call" foreignArgs mixedExport &&
  cRawToolUseRestored rawExport &&
  match importClaudeCode crossExport with
  | .ok restored => exportClaudeCode restored == crossExport
  | .error _ => false

example : claudeNativeRegistryPolicyChecked = true := by native_decide

private def claudeValidNativeImageFixture : Transcript :=
  let origin (id : String) : Origin := {
    format := .claudeCode, sourceRef := "native-image-fixture",
    rawId := some (cClaudeFixtureUuid id) }
  { threads := #[{ kind := .main }],
    entries := #[
      { payload := .assistantMsg [
          .toolCall { raw := "valid_tool", canonical := none }
            (Json.mkObj [("path", Json.str "/tmp/image.png")])
            (some "toolu_valid-1")],
        origin := origin "ni0" },
      { parent := some 0,
        payload := .envMsg [
          .toolResult (.resolved 0 0) [
            .text "image-result",
            .media "image/png" "data:image/png;base64,RESULT_IMAGE_BYTES"]
            (.native false)],
        origin := origin "ni1" }],
    activeLeaf := some 1,
    origin := { format := .claudeCode, sourceRef := "native-image-fixture" } }

/-- A valid, uniquely identified, closed Claude lifecycle remains native, its
absent source time is carried without laundering, and its result image uses the
native nested source shape with bytes intact. -/
def claudeValidNativeLifecycleChecked : Bool :=
  let exported := cExportClaudeFixture claudeValidNativeImageFixture
  cContains exported "\"type\":\"tool_use\"" &&
  cContains exported "\"type\":\"tool_result\"" &&
  cContains exported "\"timeProvenance\":{\"carrier\":\"agent-convert.time-provenance.v1\",\"kind\":\"absent\"}" &&
  cContains exported
    "\"source\":{\"data\":\"RESULT_IMAGE_BYTES\",\"media_type\":\"image/png\",\"type\":\"base64\"}" &&
  match importClaudeCode exported with
  | .ok transcript =>
      match transcript.entries[1]? with
      | some resultEntry => resultEntry.disposition == .native &&
        resultEntry.time == .absent && match resultEntry.payload with
        | .envMsg [.toolResult (.resolved 0 0)
            [.text "image-result",
             .media "image/png" "data:image/png;base64,RESULT_IMAGE_BYTES"]
            (.native false)] => true
        | _ => false
      | none => false
  | .error _ => false

example : claudeValidNativeLifecycleChecked = true := by native_decide

private def cClaudeMediaDataPreserved (t : Transcript) : Bool :=
  match t.entries[0]?, t.entries[2]? with
  | some userEntry, some assistantEntry =>
      (match userEntry.payload with
       | .userMsg [.media "image/png" locator] =>
           locator == "data:image/png;base64,iVBORw0KGgoAAAA"
       | _ => false) &&
      (match assistantEntry.payload with
       | .assistantMsg [
           .media "image/jpeg" locator, .unmodeled "redacted_thinking" _] =>
           locator == "data:image/jpeg;base64,/9j/4AAQSkZJRg"
       | _ => false)
  | _, _ => false

/-- Native Claude user/assistant image data is retained in the IR and emitted
back under `image.source`, not the old top-level `mimeType`/`data` pseudo-shape. -/
def claudeImageSourceRoundTripChecked : Bool :=
  match importClaudeCode claudeMediaFixture with
  | .error _ => false
  | .ok imported =>
      let exported := exportClaudeCode imported
      cClaudeMediaDataPreserved imported &&
      cContains exported
        "\"source\":{\"data\":\"iVBORw0KGgoAAAA\",\"media_type\":\"image/png\",\"type\":\"base64\"}" &&
      cContains exported
        "\"source\":{\"data\":\"/9j/4AAQSkZJRg\",\"media_type\":\"image/jpeg\",\"type\":\"base64\"}" &&
      match importClaudeCode exported with
      | .ok restored => cClaudeMediaDataPreserved restored
      | .error _ => false

example : claudeImageSourceRoundTripChecked = true := by native_decide
example : roundTripClaude claudeMediaFixture = true := by native_decide

private def claudeNonDefaultMimeLocatorFixture : Transcript :=
  let origin : Origin := {
    format := .claudeCode, sourceRef := "mime-locator-fixture", rawId := some "ml0" }
  { threads := #[{ kind := .main }],
    entries := #[{
      payload := .assistantMsg [
        .media "image/jpeg" "https://example.invalid/photo",
        .media "image/gif" "claude-file:file-123"],
      origin }],
    activeLeaf := some 0,
    origin }

/-- Claude URL/file source objects do not retain MIME in the shape emitted here,
so non-default MIME values must take the reversible carrier path. -/
def claudeNonDefaultMimeLocatorChecked : Bool :=
  let exported := cExportClaudeFixture claudeNonDefaultMimeLocatorFixture
  !cContains exported "\"type\":\"image\"" &&
  cContains exported ("\"" ++ claudeCarrierMarkerKey ++ "\"") &&
  match importClaudeCode exported with
  | .ok restored =>
      match restored.entries[0]? with
      | some entry => match entry.payload with
        | .assistantMsg [
            .media "image/jpeg" "https://example.invalid/photo",
            .media "image/gif" "claude-file:file-123"] => true
        | _ => false
      | none => false
  | .error _ => false

example : claudeNonDefaultMimeLocatorChecked = true := by native_decide

/-! ## Adversarial release-boundary pins -/

private def cLastPromptRecord (leafUuid : String) : Json :=
  Json.mkObj [
    ("type", Json.str "last-prompt"),
    ("sessionId", Json.str (cClaudeFixtureUuid "carrier-test")),
    ("lastPrompt", Json.str "resume"),
    ("leafUuid", Json.str (cClaudeFixtureUuid leafUuid))]

private def cLastPromptPointerRecord (leafUuid : String) : Json :=
  Json.mkObj [
    ("type", Json.str "last-prompt"),
    ("sessionId", Json.str (cClaudeFixtureUuid "carrier-test")),
    ("leafUuid", Json.str (cClaudeFixtureUuid leafUuid))]

private def claudeLastPromptFixture : String := String.intercalate "\n" [
  cClaudeTestLine "user" "user" "lp-root" none "T0" #[
    Json.mkObj [("type", Json.str "text"), ("text", Json.str "root")]],
  cClaudeTestLine "assistant" "assistant" "lp-selected" (some "lp-root") "T1" #[
    Json.mkObj [("type", Json.str "text"), ("text", Json.str "selected")]],
  cClaudeTestLine "assistant" "assistant" "lp-newer" (some "lp-root") "T9" #[
    Json.mkObj [("type", Json.str "text"), ("text", Json.str "newer sibling")]],
  (cUuidFixtureRecord (Json.mkObj [
    ("type", Json.str "attachment"), ("uuid", Json.str "lp-attachment"),
    ("parentUuid", Json.str "lp-selected"),
    ("sessionId", Json.str "carrier-test"), ("cwd", Json.str "/tmp"),
    ("timestamp", Json.str (cClaudeFixtureTimestamp "T2")),
    ("attachment", Json.mkObj [])])).compress,
  (cLastPromptRecord "lp-attachment").compress]

def claudeLastPromptAuthoritativeChecked : Bool :=
  let shape := fun (transcript : Transcript) =>
    transcript.entries.size == 3 && transcript.activeLeaf == some 2 &&
    (match transcript.entries[1]?, transcript.entries[2]? with
     | some selected, some leaf =>
         (match selected.payload with
          | .assistantMsg [.text "selected"] => true
          | _ => false) &&
         (match leaf.payload with
          | .otherMsg "claude.graph-record" [
              .unmodeled "attachment" raw] =>
                cstr raw "uuid" == some (cClaudeFixtureUuid "lp-attachment")
          | _ => false) &&
         leaf.disposition == EntryDisposition.historicalUnverified &&
         leaf.origin.rawId == some (cClaudeFixtureUuid "lp-attachment")
     | _, _ => false)
  match importClaudeCode claudeLastPromptFixture with
  | .ok transcript =>
      shape transcript &&
      (transcript.origin.extras >>= fun extras => cobj extras "raw_last_prompt" >>=
        fun record => cstr record "leafUuid") ==
          some (cClaudeFixtureUuid "lp-attachment") &&
      let exported := exportClaudeCode transcript
      (match cParseClaudeJsonLines exported with
       | .ok records =>
           (records.getLast? >>= fun pointer => cstr pointer "leafUuid") ==
             some (cClaudeFixtureUuid "lp-attachment")
       | .error _ => false) &&
      match importClaudeCode exported with
      | .ok restored => shape restored && exportClaudeCode restored == exported
      | .error _ => false
  | .error _ => false

def claudeLastPromptValidationChecked : Bool :=
  let source := String.intercalate "\n" [
    cClaudeTestLine "user" "user" "lp-only" none "T0" #[
      Json.mkObj [("type", Json.str "text"), ("text", Json.str "root")]],
    (cLastPromptRecord "missing-leaf").compress]
  match importClaudeCode source with
  | .error error => error ==
      s!"malformed Claude record at line 2: leafUuid references missing UUID '{cClaudeFixtureUuid "missing-leaf"}'"
  | .ok _ => false

/-- `leafUuid` is the resume pointer; some real Claude versions omit the
descriptive `lastPrompt` copy. Its absence must not make an otherwise valid
session unreadable. -/
def claudeOptionalLastPromptTextChecked : Bool :=
  let source := String.intercalate "\n" [
    cClaudeTestLine "user" "user" "lp-pointer" none "T0" #[
      Json.mkObj [("type", Json.str "text"), ("text", Json.str "root")]],
    (cLastPromptPointerRecord "lp-pointer").compress]
  match importClaudeCode source with
  | .ok transcript =>
      transcript.activeLeaf == some 0 &&
      (transcript.origin.extras >>= fun extras => cobj extras "raw_last_prompt" >>=
        fun record => cstr record "leafUuid") ==
          some (cClaudeFixtureUuid "lp-pointer") &&
      (transcript.origin.extras >>= fun extras => cobj extras "raw_last_prompt" >>=
        fun record => cobj record "lastPrompt") == none
  | .error _ => false

example : claudeLastPromptAuthoritativeChecked = true := by native_decide
example : claudeLastPromptValidationChecked = true := by native_decide
example : claudeOptionalLastPromptTextChecked = true := by native_decide

private def claudeCompactionBoundaryJson : Json := cUuidFixtureRecord (Json.mkObj [
  ("type", Json.str "system"), ("subtype", Json.str "compact_boundary"),
  ("uuid", Json.str "compact-boundary"), ("parentUuid", Json.null),
  ("logicalParentUuid", Json.str "prior-tail"),
  ("sessionId", Json.str "carrier-test"), ("cwd", Json.str "/tmp"),
  ("timestamp", Json.str (cClaudeFixtureTimestamp "T0")),
  ("content", Json.str "Conversation compacted"),
  ("compactMetadata", Json.mkObj [
    ("trigger", Json.str "manual"),
    ("preTokens", Json.num (Lean.JsonNumber.fromNat 321))])])

private def claudeCompactionSummaryJson : Json := cUuidFixtureRecord (Json.mkObj [
  ("type", Json.str "user"), ("uuid", Json.str "compact-summary"),
  ("parentUuid", Json.str "compact-boundary"),
  ("sessionId", Json.str "carrier-test"), ("cwd", Json.str "/tmp"),
  ("timestamp", Json.str (cClaudeFixtureTimestamp "T1")),
  ("isCompactSummary", Json.bool true),
  ("message", Json.mkObj [
    ("role", Json.str "user"), ("content", Json.str "summary text")])])

private def claudeCompactionFixture : String := String.intercalate "\n" [
  claudeCompactionBoundaryJson.compress, claudeCompactionSummaryJson.compress,
  (cLastPromptRecord "compact-summary").compress]

private def cCompactionShape (transcript : Transcript) : Bool :=
  transcript.entries.size == 1 &&
  match transcript.entries[0]? with
  | some entry =>
      (match entry.payload with
       | .compaction "summary text" .unknownPrefix (some 321) => true
       | _ => false) &&
      (entry.origin.extras >>= fun extras => cobj extras "claudeRawEnvelope") ==
        some claudeCompactionSummaryJson &&
      (entry.origin.extras >>= fun extras =>
        cobj extras "claudeRawCompactionBoundary") == some claudeCompactionBoundaryJson
  | none => false

def claudeCompactionBoundaryChecked : Bool :=
  match importClaudeCode claudeCompactionFixture with
  | .error _ => false
  | .ok imported =>
      let exported := exportClaudeCode imported
      cCompactionShape imported &&
      match cParseClaudeJsonLines exported, importClaudeCode exported with
      | .ok [record, pointer], .ok restored =>
          cstr record "type" == some "system" &&
          cstr record "subtype" == some "agent_convert_compaction" &&
          (cobj record claudeCarrierMarkerKey >>= fun marker =>
            cobj marker "compaction" >>= fun carrier => cstr carrier "summary") ==
              some "summary text" &&
          cstr pointer "type" == some "last-prompt" &&
          cstr pointer "leafUuid" == cstr record "uuid" &&
          cCompactionShape restored
      | _, _ => false

example : claudeCompactionBoundaryChecked = true := by native_decide

/-- Claude 2.1.220+ soft cut: compact_boundary immediately precedes the
isCompactSummary while parentUuid still names the prior user message. -/
private def claudeAdjacentCompactionFixture : String := String.intercalate "\n" [
  (cUuidFixtureRecord (Json.mkObj [
    ("type", Json.str "user"), ("uuid", Json.str "adj-prior"),
    ("parentUuid", Json.null), ("sessionId", Json.str "carrier-test"),
    ("cwd", Json.str "/tmp"),
    ("timestamp", Json.str (cClaudeFixtureTimestamp "T0")),
    ("message", Json.mkObj [
      ("role", Json.str "user"), ("content", Json.str "prior")])])).compress,
  (cUuidFixtureRecord (Json.mkObj [
    ("type", Json.str "system"), ("subtype", Json.str "compact_boundary"),
    ("uuid", Json.str "adj-boundary"), ("parentUuid", Json.null),
    ("logicalParentUuid", Json.str "adj-prior"),
    ("sessionId", Json.str "carrier-test"), ("cwd", Json.str "/tmp"),
    ("timestamp", Json.str (cClaudeFixtureTimestamp "T1")),
    ("content", Json.str "Conversation compacted"),
    ("compactMetadata", Json.mkObj [
      ("trigger", Json.str "manual"),
      ("preTokens", Json.num (Lean.JsonNumber.fromNat 99))])])).compress,
  (cUuidFixtureRecord (Json.mkObj [
    ("type", Json.str "user"), ("uuid", Json.str "adj-summary"),
    ("parentUuid", Json.str "adj-prior"),
    ("sessionId", Json.str "carrier-test"), ("cwd", Json.str "/tmp"),
    ("timestamp", Json.str (cClaudeFixtureTimestamp "T2")),
    ("isCompactSummary", Json.bool true),
    ("message", Json.mkObj [
      ("role", Json.str "user"), ("content", Json.str "adjacent summary")])])).compress,
  (cLastPromptRecord "adj-summary").compress]

def claudeAdjacentCompactionBoundaryChecked : Bool :=
  match importClaudeCode claudeAdjacentCompactionFixture with
  | .error _ => false
  | .ok imported =>
      imported.entries.size == 1 &&
      (match imported.entries[0]? with
       | some entry =>
           (match entry.payload with
            | .compaction "adjacent summary" .unknownPrefix (some 99) => true
            | _ => false) &&
           (entry.origin.extras >>= fun extras =>
             cobj extras "claudeRawCompactionBoundary" >>= fun boundary =>
               cstr boundary "uuid") == some (cClaudeFixtureUuid "adj-boundary") &&
           imported.importNotes.any (fun note =>
             match note.kind with
             | .other "adjacentCompactionBoundary" => true
             | _ => false)
       | none => false)

example : claudeAdjacentCompactionBoundaryChecked = true := by native_decide

private def cMalformedEnvelope (uuid : Option String) (content : Option Json) : Json :=
  Json.mkObj ((match uuid with
    | some id => [("uuid", Json.str (cClaudeFixtureUuid id))]
    | none => []) ++ [
    ("type", Json.str "user"), ("parentUuid", Json.null),
    ("sessionId", Json.str (cClaudeFixtureUuid "schema-test")),
    ("message", Json.mkObj ([("role", Json.str "user")] ++
      (match content with | some value => [("content", value)] | none => [])))])

private def cRejectedWith (source expected : String) : Bool :=
  match importClaudeCode source with
  | .error error => error == expected
  | .ok _ => false

/-- Imports, roots the orphaned entry, and logs the assumption — the honest
degradation for a parent edge that simply is not in the file. -/
private def cRootedWithDanglingParentNote (source : String) : Bool :=
  match importClaudeCode source with
  | .error _ => false
  | .ok transcript =>
      transcript.entries.toList.all (fun entry =>
        match entry.parent with
        | some parent => decide (parent < transcript.entries.size)
        | none => true) &&
      transcript.importNotes.any (fun note =>
        match note.kind with
        | .other "danglingParent" => true
        | _ => false)

def claudeRecognizedSchemaRefusalChecked : Bool :=
  let wrongError := Json.mkObj [
    ("type", Json.str "tool_result"), ("tool_use_id", Json.str "call"),
    ("is_error", Json.str "false"), ("content", Json.str "result")]
  let duplicate := String.intercalate "\n" [
    (cMalformedEnvelope (some "duplicate") (some (Json.str "one"))).compress,
    (cMalformedEnvelope (some "duplicate") (some (Json.str "two"))).compress]
  cRejectedWith (cMalformedEnvelope (some "wrong-content")
      (some (Json.num 42))).compress
    "malformed Claude record at line 1: message.content must be a string or an array" &&
  cRejectedWith (cMalformedEnvelope (some "missing-content") none).compress
    "malformed Claude record at line 1: message.content is required" &&
  cRejectedWith (cMalformedEnvelope (some "wrong-error")
      (some (Json.arr #[wrongError]))).compress
    "malformed Claude record at line 1: message.content[0].is_error must be a boolean" &&
  cRejectedWith (cMalformedEnvelope none (some (Json.str "missing uuid"))).compress
    "malformed Claude record at line 1: uuid is required" &&
  cRejectedWith duplicate
    s!"malformed Claude record at line 1: uuid is ambiguous in the selected graph: found 2 occurrences of '{cClaudeFixtureUuid "duplicate"}'"

example : claudeRecognizedSchemaRefusalChecked = true := by native_decide

/-- A missing native error flag is represented as unknown, not fabricated as
success and not rejected. Present non-boolean flags remain schema errors above. -/
def claudeOptionalToolResultErrorChecked : Bool :=
  let missingError := Json.mkObj [
    ("type", Json.str "tool_result"), ("tool_use_id", Json.str "call"),
    ("content", Json.str "result")]
  let source := (cMalformedEnvelope (some "missing-error")
    (some (Json.arr #[missingError]))).compress
  match importClaudeCode source with
  | .ok transcript =>
      match transcript.entries[0]? with
      | some entry => match entry.payload with
        | .envMsg [.toolResult (.unresolved (some "call") _) [.text "result"]
            .unrecorded] => true
        | _ => false
      | none => false
  | .error _ => false

example : claudeOptionalToolResultErrorChecked = true := by native_decide

private def claudeRawServerToolUse : Json := Json.mkObj [
  ("type", Json.str "server_tool_use"), ("id", Json.str "server-1"),
  ("name", Json.str "web_search"), ("input", Json.mkObj [("q", Json.str "x")])]

private def claudeRawWebToolResult : Json := Json.mkObj [
  ("type", Json.str "web_search_tool_result"),
  ("tool_use_id", Json.str "server-1"), ("payload", Json.str "raw-result")]

private def claudeRawUserToolResult : Json := Json.mkObj [
  ("type", Json.str "tool_result"), ("tool_use_id", Json.str "raw-user"),
  ("is_error", Json.bool false), ("content", Json.str "raw-user-result")]

private def claudeRawLifecycleFixture : Transcript :=
  let origin (id : String) : Origin := {
    format := .claudeCode, sourceRef := "raw-lifecycle", rawId := some id }
  { threads := #[{ kind := .main }], entries := #[
      { payload := .userMsg [.unmodeled "user-lifecycle" claudeRawUserToolResult],
        origin := origin "raw-user" },
      { parent := some 0,
        payload := .assistantMsg [.unmodeled "server-lifecycle" claudeRawServerToolUse],
        origin := origin "raw-assistant" },
      { parent := some 1,
        payload := .envMsg [.unmodeled "result-lifecycle" claudeRawWebToolResult],
        origin := origin "raw-env" }],
    activeLeaf := some 2,
    origin := { format := .claudeCode, sourceRef := "raw-lifecycle" } }

private def cRawLifecycleShape (transcript : Transcript) : Bool :=
  match transcript.entries[0]?, transcript.entries[1]?, transcript.entries[2]? with
  | some user, some assistant, some env =>
      (match user.payload with
       | .userMsg [.unmodeled "user-lifecycle" raw] => raw == claudeRawUserToolResult
       | _ => false) &&
      (match assistant.payload with
       | .assistantMsg [.unmodeled "server-lifecycle" raw] =>
           raw == claudeRawServerToolUse
       | _ => false) &&
      (match env.payload with
       | .envMsg [.unmodeled "result-lifecycle" raw] => raw == claudeRawWebToolResult
       | _ => false)
  | _, _, _ => false

def claudeOpenWorldLifecycleSafetyChecked : Bool :=
  let exported := cExportClaudeFixture claudeRawLifecycleFixture
  cRawClaudeLifecycleBlock claudeRawServerToolUse &&
  cRawClaudeLifecycleBlock claudeRawWebToolResult &&
  cstr (claudeUserBlockToJson (.unmodeled "user-lifecycle" claudeRawUserToolResult))
      "type" == some "text" &&
  cstr (claudeAssistantBlockToJson
      (.unmodeled "server-lifecycle" claudeRawServerToolUse)) "type" == some "text" &&
  cstr (claudeEnvBlockToJson claudeRawLifecycleFixture
      (.unmodeled "result-lifecycle" claudeRawWebToolResult)) "type" == some "text" &&
  match cParseClaudeJsonLines exported, importClaudeCode exported with
  | .ok records, .ok restored =>
      (records.take 3).all (fun record =>
        (cobj record "message" >>= fun message => carr message "content" >>=
          fun blocks => blocks[0]? >>= fun block => cstr block "type") == some "text") &&
      cRawLifecycleShape restored
  | _, _ => false

example : claudeOpenWorldLifecycleSafetyChecked = true := by native_decide

def claudeMismatchedRolesArchivedChecked : Bool :=
  match importClaudeCode claudeMismatchedRoleFixture with
  | .error _ => false
  | .ok transcript =>
      match transcript.origin.extras >>= fun extras => carr extras "raw_inert_records" with
      | some records =>
          records.size == 2 &&
          (records[0]? >>= fun record => cobj record "raw" >>= fun raw =>
            cobj raw "message" >>= fun message => cstr message "role") == some "system" &&
          (records[1]? >>= fun record => cobj record "raw" >>= fun raw =>
            cobj raw "message" >>= fun message => cstr message "role") == some "developer"
      | none => false

example : claudeMismatchedRolesArchivedChecked = true := by native_decide

private def claudeAdditiveImageA : Json := Json.mkObj [
  ("type", Json.str "image"),
  ("source", Json.mkObj [
    ("type", Json.str "url"), ("url", Json.str "https://example.invalid/a.png")]),
  ("alt", Json.str "must survive")]

private def claudeAdditiveImageB : Json := Json.mkObj [
  ("type", Json.str "image"),
  ("source", Json.mkObj [
    ("type", Json.str "base64"), ("media_type", Json.str "image/png"),
    ("data", Json.str "AA=="), ("detail", Json.str "high")])]

private def claudeAdditiveImageFixture : String :=
  cClaudeTestLine "assistant" "assistant" "image-additive" none "T0"
    #[claudeAdditiveImageA, claudeAdditiveImageB]

private def cAdditiveImageShape (transcript : Transcript) : Bool :=
  match transcript.entries[0]? with
  | some entry => match entry.payload with
    | .assistantMsg [.unmodeled "image" first, .unmodeled "image" second] =>
        first == claudeAdditiveImageA && second == claudeAdditiveImageB
    | _ => false
  | none => false

def claudeAdditiveImageFidelityChecked : Bool :=
  match importClaudeCode claudeAdditiveImageFixture with
  | .error _ => false
  | .ok imported =>
      cAdditiveImageShape imported &&
      match importClaudeCode (exportClaudeCode imported) with
      | .ok restored => cAdditiveImageShape restored
      | .error _ => false

example : claudeAdditiveImageFidelityChecked = true := by native_decide

private def claudeMetadataRecord : Json := cUuidFixtureRecord (Json.mkObj [
  ("type", Json.str "assistant"), ("uuid", Json.str "metadata"),
  ("parentUuid", Json.null), ("sessionId", Json.str "metadata-session"),
  ("cwd", Json.str "/metadata"),
  ("timestamp", Json.str (cClaudeFixtureTimestamp "T0")),
  ("version", Json.str "2.1.199"), ("gitBranch", Json.str "feature/provenance"),
  ("environment", Json.mkObj [("sandbox", Json.str "workspace-write")]),
  ("message", Json.mkObj [
    ("role", Json.str "assistant"), ("model", Json.str "claude-test"),
    ("usage", Json.mkObj [
      ("input_tokens", Json.num (Lean.JsonNumber.fromNat 7)),
      ("output_tokens", Json.num (Lean.JsonNumber.fromNat 11))]),
    ("content", Json.arr #[
      Json.mkObj [("type", Json.str "text"), ("text", Json.str "metadata")]])])])

def claudeMetadataProvenanceChecked : Bool :=
  match importClaudeCode claudeMetadataRecord.compress with
  | .error _ => false
  | .ok transcript =>
      transcript.env.cwd == some "/metadata" &&
      transcript.env.sessionId == some (cClaudeFixtureUuid "metadata-session") &&
      (match transcript.entries[0]? with
       | some entry =>
           (entry.origin.extras >>= fun extras => cobj extras "claudeRawEnvelope") ==
             some claudeMetadataRecord
       | none => false) &&
      match cParseClaudeJsonLines (exportClaudeCode transcript) with
      | .ok [record, pointer] =>
          cstr record "type" == some "assistant" &&
          cstr record "uuid" == some (cClaudeFixtureUuid "metadata") &&
          cstr record "sessionId" == some (cClaudeFixtureUuid "metadata-session") &&
          cstr record "version" == some "2.1.199" &&
          cstr record "gitBranch" == some "feature/provenance" &&
          (cobj record "environment" >>= fun environment =>
            cstr environment "sandbox") == some "workspace-write" &&
          (cobj record "message" >>= fun message => cstr message "model") ==
            some "claude-test" &&
          (cobj record "message" >>= fun message => cobj message "usage") ==
            (cobj claudeMetadataRecord "message" >>= fun message =>
              cobj message "usage") &&
          cstr pointer "type" == some "last-prompt" &&
          cstr pointer "leafUuid" == some (cClaudeFixtureUuid "metadata") &&
          match importClaudeCode (exportClaudeCode transcript) with
          | .ok restored =>
              (restored.entries[0]? >>= fun entry => entry.origin.extras >>=
                fun extras => cobj extras "claudeRawEnvelope") ==
                  some claudeMetadataRecord
          | .error _ => false
      | _ => false

example : claudeMetadataProvenanceChecked = true := by native_decide

private def claudeSequentialToolReuseFixture : String := String.intercalate "\n" [
  cClaudeTestLine "assistant" "assistant" "sr0" none "T0" #[
    Json.mkObj [("type", Json.str "tool_use"), ("id", Json.str "reused"),
      ("name", Json.str "first"), ("input", Json.mkObj [("turn", Json.num 1)])]],
  cClaudeTestLine "user" "user" "sr1" (some "sr0") "T1" #[
    Json.mkObj [("type", Json.str "tool_result"),
      ("tool_use_id", Json.str "reused"), ("is_error", Json.bool false),
      ("content", Json.str "first-result")]],
  cClaudeTestLine "assistant" "assistant" "sr2" (some "sr1") "T2" #[
    Json.mkObj [("type", Json.str "tool_use"), ("id", Json.str "reused"),
      ("name", Json.str "second"), ("input", Json.mkObj [("turn", Json.num 2)])]],
  cClaudeTestLine "user" "user" "sr3" (some "sr2") "T3" #[
    Json.mkObj [("type", Json.str "tool_result"),
      ("tool_use_id", Json.str "reused"), ("is_error", Json.bool true),
      ("content", Json.str "second-result")]]]

private def cSequentialToolReuseShape (transcript : Transcript) : Bool :=
  transcript.entries.size == 4 &&
  match transcript.entries[1]?, transcript.entries[3]? with
  | some first, some second =>
      (match first.payload with
       | .envMsg [.toolResult (.resolved 0 0) [.text "first-result"]
           (.native false)] => true
       | _ => false) &&
      (match second.payload with
       | .envMsg [.toolResult (.resolved 2 0) [.text "second-result"]
           (.native true)] => true
       | _ => false)
  | _, _ => false

/-- Reusing a raw ID after its first lifecycle closes is unambiguous. -/
def claudeSequentialToolReuseChecked : Bool :=
  match importClaudeCode claudeSequentialToolReuseFixture with
  | .error _ => false
  | .ok imported =>
      cSequentialToolReuseShape imported &&
      match importClaudeCode (exportClaudeCode imported) with
      | .ok restored => cSequentialToolReuseShape restored
      | .error _ => false

example : claudeSequentialToolReuseChecked = true := by native_decide

private def cGraphLine
    (kind role uuid session : String) (parent : Option String) (text : String)
    (extra : List (String × Json) := []) : Json :=
  let content :=
    if role == "assistant" then
      Json.arr #[Json.mkObj [("type", Json.str "text"), ("text", Json.str text)]]
    else Json.str text
  cUuidFixtureRecord (Json.mkObj ([
    ("type", Json.str kind), ("uuid", Json.str (cClaudeFixtureUuid uuid)),
    ("parentUuid", parent.map (fun value => Json.str (cClaudeFixtureUuid value))
      |>.getD Json.null),
    ("sessionId", Json.str (cClaudeFixtureUuid session)), ("cwd", Json.str "/tmp"),
    ("timestamp", Json.str "2026-07-20T00:00:00.000Z")] ++ extra ++ [
    ("message", Json.mkObj [
      ("role", Json.str role), ("content", content)])]))

private def cSessionPointer (session leaf : String) : Json := Json.mkObj [
  ("type", Json.str "last-prompt"),
  ("sessionId", Json.str (cClaudeFixtureUuid session)),
  ("leafUuid", Json.str (cClaudeFixtureUuid leaf))]

def claudeSelectedGraphValidationChecked : Bool :=
  let missing := String.intercalate "\n" [
    (cGraphLine "user" "user" "missing-child" "graph" (some "absent")
      "child").compress,
    (cSessionPointer "graph" "missing-child").compress]
  let cycle := String.intercalate "\n" [
    (cGraphLine "user" "user" "cycle-a" "graph" (some "cycle-b") "a").compress,
    (cGraphLine "assistant" "assistant" "cycle-b" "graph" (some "cycle-a")
      "b").compress,
    (cSessionPointer "graph" "cycle-b").compress]
  let crossSession := String.intercalate "\n" [
    (cGraphLine "user" "user" "foreign-parent" "foreign" none "foreign").compress,
    (cGraphLine "assistant" "assistant" "local-child" "local"
      (some "foreign-parent") "local").compress,
    (cSessionPointer "local" "local-child").compress]
  let forgedLineage := String.intercalate "\n" [
    (cGraphLine "user" "user" "forged-child" "local" (some "absent")
      "forged" [("forkedFrom", Json.mkObj [
        ("sessionId", Json.str "external"),
        ("messageUuid", Json.str "different-message")])]).compress,
    (cSessionPointer "local" "forged-child").compress]
  -- A parent absent from the file is a real, common shape in live sessions
  -- (measured: 1 in 1323 records of a working transcript), so it degrades to a
  -- flagged thread root instead of discarding the whole session. The edge is
  -- never invented: `parent` stays `none` and the assumption is logged.
  cRootedWithDanglingParentNote missing &&
  cRootedWithDanglingParentNote forgedLineage &&
  -- These two remain hard refusals. A cycle is structurally impossible in the
  -- IR's normal form, and a cross-session parent is a positive claim about a
  -- DIFFERENT session's record — neither is a merely-absent edge.
  cRejectedWith cycle
      s!"malformed Claude record at line 2: parentUuid closes a cycle at UUID '{cClaudeFixtureUuid "cycle-b"}'" &&
  cRejectedWith crossSession
      s!"malformed Claude record at line 2: parentUuid references UUID '{cClaudeFixtureUuid "foreign-parent"}' in session '{cClaudeFixtureUuid "foreign"}', expected '{cClaudeFixtureUuid "local"}'"

example : claudeSelectedGraphValidationChecked = true := by native_decide

private def claudeExternalLineageRecord : Json :=
  cGraphLine "user" "user" "external-child" "local" (some "external-parent")
    "continued here" [
      ("forkedFrom", Json.mkObj [
        ("sessionId", Json.str "external"),
        ("messageUuid", Json.str "external-child")])]

def claudeExternalLineageIsInertChecked : Bool :=
  let source := String.intercalate "\n" [claudeExternalLineageRecord.compress,
    (cSessionPointer "local" "external-child").compress]
  match importClaudeCode source with
  | .error _ => false
  | .ok transcript =>
      transcript.entries.size == 1 && transcript.entries[0]?.bind (fun entry =>
        entry.parent) == none &&
      (transcript.entries[0]? >>= fun entry => entry.origin.extras >>=
        fun extras => cobj extras "claudeRawEnvelope") ==
          some claudeExternalLineageRecord &&
      transcript.importNotes.any (fun note =>
        match note.kind with
        | .other "externalLineage" => true
        | _ => false)

example : claudeExternalLineageIsInertChecked = true := by native_decide

private def cLocalCommandControl (slug : String) : Json := cUuidFixtureRecord (Json.mkObj [
  ("type", Json.str "system"), ("subtype", Json.str "local_command"),
  ("uuid", Json.str "duplicate-control"), ("parentUuid", Json.str "control-root"),
  ("sessionId", Json.str "carrier-test"), ("timestamp", Json.str "T1"),
  ("content", Json.str "local command"), ("slug", Json.str slug),
  ("forkedFrom", Json.mkObj [
    ("sessionId", Json.str "archive"), ("messageUuid", Json.str "prior")])])

private def cArchivedRaws (transcript : Transcript) : List Json :=
  match transcript.origin.extras >>= fun extras => carr extras "raw_inert_records" with
  | some records => records.toList.filterMap (fun record => cobj record "raw")
  | none => []

def claudeDuplicateInertControlsAreOccurrencesChecked : Bool :=
  let first := cLocalCommandControl "first"
  let second := cLocalCommandControl "second"
  let source := String.intercalate "\n" [
    cClaudeTestLine "user" "user" "duplicate-control" none "T0" #[
      Json.mkObj [("type", Json.str "text"), ("text", Json.str "root")]],
    first.compress, second.compress,
    (cLastPromptPointerRecord "duplicate-control").compress]
  match importClaudeCode source with
  | .error _ => false
  | .ok imported =>
      cArchivedRaws imported == [first, second] &&
      match importClaudeCode (exportClaudeCode imported) with
      | .ok restored => cArchivedRaws restored == [first, second]
      | .error _ => false

example : claudeDuplicateInertControlsAreOccurrencesChecked = true := by native_decide

private def claudeFileHistoryRecord : Json := Json.mkObj [
  ("type", Json.str "file-history-snapshot"), ("messageId", Json.str "audit-1"),
  ("snapshot", Json.mkObj [("tracked", Json.arr #[Json.str "A.lean"])])]

private def claudeModeRecord : Json := Json.mkObj [
  ("type", Json.str "mode"), ("mode", Json.str "plan"),
  ("source", Json.str "shortcut")]

private def claudeUnknownRecord : Json := Json.mkObj [
  ("type", Json.str "future-state"), ("opaque", Json.arr #[Json.num 7, Json.null])]

private def claudeAttachmentRecord : Json := cUuidFixtureRecord (Json.mkObj [
  ("type", Json.str "attachment"), ("uuid", Json.str "audit-attachment"),
  ("parentUuid", Json.str "audit-root"), ("sessionId", Json.str "carrier-test"),
  ("attachment", Json.mkObj [("kind", Json.str "file"),
    ("payload", Json.str "opaque")])])

def claudeEveryTopLevelRecordIsAccountedForChecked : Bool :=
  let expected := [claudeFileHistoryRecord, claudeModeRecord,
    claudeUnknownRecord, claudeAttachmentRecord]
  let source := String.intercalate "\n" [
    cClaudeTestLine "user" "user" "audit-root" none "T0" #[
      Json.mkObj [("type", Json.str "text"), ("text", Json.str "root")]],
    claudeFileHistoryRecord.compress, claudeModeRecord.compress,
    claudeUnknownRecord.compress, claudeAttachmentRecord.compress,
    (cLastPromptPointerRecord "audit-root").compress]
  let malformedTypes :=
    cRejectedWith (Json.mkObj []).compress
        "malformed Claude record at line 1: type is required" &&
    cRejectedWith (Json.mkObj [("type", Json.num 7)]).compress
        "malformed Claude record at line 1: type must be a string" &&
    cRejectedWith (Json.mkObj [("type", Json.str "")]).compress
        "malformed Claude record at line 1: type must not be empty"
  malformedTypes &&
  match importClaudeCode source with
  | .error _ => false
  | .ok imported =>
      cArchivedRaws imported == expected &&
      (imported.importNotes.filter (fun note =>
        match note.kind with | .contentSkipped => true | _ => false)).length == 4 &&
      match importClaudeCode (exportClaudeCode imported) with
      | .ok restored => cArchivedRaws restored == expected
      | .error _ => false

example : claudeEveryTopLevelRecordIsAccountedForChecked = true := by native_decide

private def cCompactSummaryWithParent (parent : Json) : Json := cUuidFixtureRecord (Json.mkObj [
  ("type", Json.str "user"), ("uuid", Json.str "strict-summary"),
  ("parentUuid", parent), ("sessionId", Json.str "carrier-test"),
  ("isCompactSummary", Json.bool true),
  ("message", Json.mkObj [
    ("role", Json.str "user"), ("content", Json.str "summary")])])

def claudeCompactSummaryParentValidationChecked : Bool :=
  let nullParent := (cCompactSummaryWithParent Json.null).compress
  let orphan := (cCompactSummaryWithParent (Json.str "missing-boundary")).compress
  let wrongParent := String.intercalate "\n" [
    cClaudeTestLine "user" "user" "ordinary-parent" none "T0" #[
      Json.mkObj [("type", Json.str "text"), ("text", Json.str "ordinary")]],
    (cCompactSummaryWithParent (Json.str "ordinary-parent")).compress]
  cRejectedWith nullParent
      "malformed Claude record at line 1: parentUuid must reference a real compact_boundary when isCompactSummary is true" &&
  cRejectedWith orphan
      s!"malformed Claude record at line 1: parentUuid references missing compact_boundary UUID '{cClaudeFixtureUuid "missing-boundary"}'" &&
  cRejectedWith wrongParent
      s!"malformed Claude record at line 2: parentUuid references missing compact_boundary UUID '{cClaudeFixtureUuid "ordinary-parent"}'"

example : claudeCompactSummaryParentValidationChecked = true := by native_decide

private def claudeInertPayloadFixture : Transcript :=
  let origin (id : String) : Origin := {
    format := .claudeCode, sourceRef := "inert-payload-fixture", rawId := some id }
  { threads := #[{ kind := .main }],
    entries := #[
      { payload := .otherMsg "system" [.text "historical system payload"],
        origin := origin "inert-other" },
      { parent := some 0,
        payload := .event (.custom "runtime-event"
          (Json.mkObj [("phase", Json.str "complete"), ("code", Json.num 9)])),
        origin := origin "inert-event" }],
    env := { sessionId := some "inert-payload-session" },
    activeLeaf := some 1,
    origin := { format := .claudeCode, sourceRef := "inert-payload-fixture" } }

private def cInertPayloadShape (transcript : Transcript) : Bool :=
  transcript.entries.size == 2 && transcript.activeLeaf == some 1 &&
  match transcript.entries[0]?, transcript.entries[1]? with
  | some other, some event =>
      (match other.payload with
       | .otherMsg "system" [.text "historical system payload"] => true
       | _ => false) &&
      (match event.payload with
       | .event (.custom "runtime-event" raw) =>
           raw == Json.mkObj [("phase", Json.str "complete"), ("code", Json.num 9)]
       | _ => false)
  | _, _ => false

def claudeInertPayloadCarriersChecked : Bool :=
  let exported := cExportClaudeFixture claudeInertPayloadFixture
  match cParseClaudeJsonLines exported, importClaudeCode exported with
  | .ok [other, event, sourceEnv, pointer], .ok restored =>
      [other, event].all (fun record =>
        cstr record "type" == some "system" &&
        cstr record "subtype" == some "agent_convert_inert") &&
      cstr sourceEnv "type" == some "agent-convert-provenance" &&
      (match cParseTranscriptProvenanceCarrier? sourceEnv with
       | some (.sourceEnv _ _) => true | _ => false) &&
      cstr pointer "type" == some "last-prompt" &&
      cInertPayloadShape restored &&
      exportClaudeCode restored == exported
  | _, _ => false

example : claudeInertPayloadCarriersChecked = true := by native_decide

private def claudeSelectedBranchFixture : Transcript :=
  let origin (id : String) : Origin := {
    format := .claudeCode, sourceRef := "selected-branch-fixture",
    rawId := some (cClaudeFixtureUuid id) }
  { threads := #[{ kind := .main }],
    entries := #[
      { payload := .userMsg [.text "root"], origin := origin "branch-root" },
      { parent := some 0, payload := .assistantMsg [.text "selected"],
        origin := origin "branch-left" },
      { parent := some 0, payload := .assistantMsg [.text "unselected"],
        origin := origin "branch-right" }],
    env := { sessionId := some (cClaudeFixtureUuid "branch-session") },
    activeLeaf := some 1,
    origin := { format := .claudeCode, sourceRef := "selected-branch-fixture" } }

def claudeExportedActiveLeafIsAuthoritativeChecked : Bool :=
  let source := cClaudeFixtureTargetReady claudeSelectedBranchFixture
  (Loom.Ops.obligations .claudeCode source).contains .linearizeBranches &&
  exportClaudeCode source == "" &&
  match exportClaudeCodeChecked source with
  | .error error => error ==
      "Claude target has destructive export obligations: [Loom.Ops.Obligation.linearizeBranches]"
  | .ok _ => false

example : claudeExportedActiveLeafIsAuthoritativeChecked = true := by native_decide

private def claudeCanonicalCarrierFixture : Transcript :=
  let origin : Origin := {
    format := .claudeCode, sourceRef := "canonical-carrier-fixture",
    rawId := some "canonical-call" }
  { threads := #[{ kind := .main }],
    entries := #[{
      payload := .assistantMsg [
        .toolCall { raw := "custom-shell", canonical := some .bash }
          (Json.mkObj [("command", Json.str "true")]) (some "open-call")],
      origin }],
    env := { sessionId := some "canonical-session" }, activeLeaf := some 0,
    origin := { format := .claudeCode, sourceRef := "canonical-carrier-fixture" } }

def claudeHistoricalCarrierCanonicalNameChecked : Bool :=
  let exported := cExportClaudeFixture claudeCanonicalCarrierFixture
  match importClaudeCode exported with
  | .ok restored =>
      match restored.entries[0]? with
      | some entry => match entry.payload with
        | .assistantMsg [.toolCall name _ (some "open-call")] =>
            name.raw == "custom-shell" && name.canonical == some .bash
        | _ => false
      | none => false
  | .error _ => false

example : claudeHistoricalCarrierCanonicalNameChecked = true := by native_decide

private def claudePoisonedRawEnvelope : Json := Json.mkObj [
  ("type", Json.str "user"), ("subtype", Json.str "poison"),
  ("uuid", Json.str "poison-id"), ("parentUuid", Json.str "poison-parent"),
  ("sessionId", Json.str "poison-session"), ("cwd", Json.str "/poison"),
  ("timestamp", Json.str "2026-07-20T00:00:09.000Z"),
  ("isSidechain", Json.bool true),
  ("version", Json.str "poison-metadata-version"),
  ("message", Json.mkObj [
    ("role", Json.str "user"), ("model", Json.str "metadata-model"),
    ("usage", Json.mkObj [("input_tokens", Json.num 13)]),
    ("content", Json.str "poison content")])]

private def claudePoisonedMetadataFixture : Transcript :=
  let entryOrigin : Origin := {
    format := .claudeCode, sourceRef := "poisoned-metadata-fixture",
    rawId := some (cClaudeFixtureUuid "generated-id"), extras := some (Json.mkObj [
      ("claudeRawEnvelope", claudePoisonedRawEnvelope)]) }
  let targetEnv : EnvInfo := {
    cwd := some "/generated",
    sessionId := some (cClaudeFixtureUuid "generated-session") }
  { threads := #[{ kind := .main }],
    entries := #[{
      payload := .assistantMsg [.text "generated content"],
      origin := entryOrigin }],
    env := targetEnv,
    activeLeaf := some 0,
    origin := { format := .claudeCode, sourceRef := "poisoned-metadata-fixture" } }

def claudeRawEnvelopeCannotOverrideStructureChecked : Bool :=
  match cParseClaudeJsonLines (cExportClaudeFixture claudePoisonedMetadataFixture) with
  | .ok [record, _sourceEnv, pointer] =>
      cstr record "type" == some "assistant" && cstr record "subtype" == none &&
      cstr record "uuid" == some (cClaudeFixtureUuid "generated-id") &&
      cobj record "parentUuid" == some Json.null &&
      cstr record "sessionId" == some (cClaudeFixtureUuid "generated-session") &&
      cstr record "cwd" == some "/generated" &&
      !cbool record "isSidechain" &&
      cstr record "timestamp" == some "2026-07-20T00:00:00.000Z" &&
      cstr record "version" == some "poison-metadata-version" &&
      (cobj record "message" >>= fun message => cstr message "role") ==
        some "assistant" &&
      (cobj record "message" >>= fun message => cstr message "model") ==
        some "metadata-model" &&
      (cobj record "message" >>= fun message => carr message "content" >>=
        fun blocks => blocks[0]? >>= fun block => cstr block "text") ==
          some "generated content" &&
      cstr pointer "leafUuid" == some (cClaudeFixtureUuid "generated-id") &&
      match importClaudeCode (cExportClaudeFixture claudePoisonedMetadataFixture) with
      | .ok restored =>
          (restored.entries[0]? >>= fun entry => entry.origin.extras >>=
            fun extras => cobj extras "claudeRawEnvelope") ==
              some claudePoisonedRawEnvelope
      | .error _ => false
  | _ => false

example : claudeRawEnvelopeCannotOverrideStructureChecked = true := by native_decide

/-! ## Audit adversaries: graph occurrence, role, export, and carrier boundaries -/

private def claudeInertLeafDistractorFixture : String :=
  let inertChild := Json.mkObj [
    ("type", Json.str "system"), ("subtype", Json.str "local_command"),
    ("uuid", Json.str "inert-child"), ("parentUuid", Json.str "newest-root"),
    ("sessionId", Json.str "carrier-test"), ("cwd", Json.str "/tmp"),
    ("timestamp", Json.str (cClaudeFixtureTimestamp "T9")),
    ("content", Json.str "inert command bookkeeping")]
  String.intercalate "\n" [
    cClaudeTestLine "user" "user" "newest-root" none "T9" #[
      Json.mkObj [("type", Json.str "text"), ("text", Json.str "newest")]],
    cClaudeTestLine "user" "user" "older-root" none "T1" #[
      Json.mkObj [("type", Json.str "text"), ("text", Json.str "older")]],
    inertChild.compress]

/-- An inert graph-shaped control is not a child for guessed-leaf selection. -/
def claudeInertControlsDoNotResolveLeaves : Bool :=
  match importClaudeCode claudeInertLeafDistractorFixture with
  | .ok transcript =>
      transcript.entries.size == 1 &&
      match transcript.entries[0]? with
      | some entry => match entry.payload with
        | .userMsg [.text "newest"] => true
        | _ => false
      | none => false
  | .error _ => false

example : claudeInertControlsDoNotResolveLeaves = true := by native_decide

private def claudeCrossSessionSharedUuidFixture : String :=
  let selected := cGraphLine "user" "user" "shared-dialogue-id" "selected-session"
    none "selected"
  let foreign := cGraphLine "assistant" "assistant" "shared-dialogue-id"
    "foreign-session" none "foreign"
  String.intercalate "\n" [
    selected.compress, foreign.compress,
    (cSessionPointer "selected-session" "shared-dialogue-id").compress]

/-- Selection membership is the exact source occurrence, not just its UUID.
The complete same-UUID record from another session remains in inert provenance
and survives another export/import cycle. -/
def claudeSelectedMembershipIsOccurrenceScoped : Bool :=
  let foreign := cGraphLine "assistant" "assistant" "shared-dialogue-id"
    "foreign-session" none "foreign"
  match importClaudeCode claudeCrossSessionSharedUuidFixture with
  | .error _ => false
  | .ok imported =>
      imported.entries.size == 1 &&
      (match imported.entries[0]? with
       | some entry => match entry.payload with
         | .userMsg [.text "selected"] => true
         | _ => false
       | none => false) &&
      cArchivedRaws imported == [foreign] &&
      match importClaudeCode (exportClaudeCode imported) with
      | .ok restored => cArchivedRaws restored == [foreign]
      | .error _ => false

example : claudeSelectedMembershipIsOccurrenceScoped = true := by native_decide

/-- Exact native lifecycle discriminators are role-isolated. Open-world names
such as server_tool_use remain preservable, but native tool_use in user
dialogue and tool_result in assistant dialogue are schema errors. -/
def claudeWrongRoleLifecycleBlocksRefused : Bool :=
  let userToolUse := cClaudeTestLine "user" "user" "wrong-user" none "T0" #[
    Json.mkObj [
      ("type", Json.str "tool_use"), ("id", Json.str "call"),
      ("name", Json.str "bash"), ("input", Json.mkObj [])]]
  let assistantToolResult :=
    cClaudeTestLine "assistant" "assistant" "wrong-assistant" none "T0" #[
      Json.mkObj [
        ("type", Json.str "tool_result"), ("tool_use_id", Json.str "call"),
        ("is_error", Json.bool false), ("content", Json.str "result")]]
  cRejectedWith userToolUse
      "malformed Claude record at line 1: message.content[0].type tool_use is not valid in a user dialogue record" &&
    cRejectedWith assistantToolResult
      "malformed Claude record at line 1: message.content[0].type tool_result is not valid in an assistant dialogue record"

example : claudeWrongRoleLifecycleBlocksRefused = true := by native_decide

private def cClaudeExportPrerequisiteFixture
    (targetCwd : Option String) (targetTimestamp : Option Json)
    (entryExtras : Option Json := none) (entryTime : Time := .absent)
    (targetSession : Option String := some (cClaudeFixtureUuid "target-session"))
    (targetHarnessVersion : Option String := some claudeTargetValidationBuild) : Transcript :=
  let transcriptExtras := Json.mkObj (
    (match targetTimestamp with
     | some timestamp => [("target_timestamp", timestamp)]
     | none => []) ++
    (match targetCwd with
     | some cwd => [("target_cwd", Json.str cwd)]
     | none => []) ++
    (match targetSession with
     | some session => [("target_session_id", Json.str session)]
     | none => []) ++
    (match targetHarnessVersion with
     | some version => [("target_harness_version", Json.str version)]
     | none => []))
  { threads := #[{ kind := .main }],
    entries := #[{
      payload := .userMsg [.text "foreign target entry"],
      time := entryTime,
      origin := {
        format := .pi, sourceRef := "claude-export-prerequisite",
        rawId := some "", extras := entryExtras } }],
    env := {
      cwd := some "/source", model := some "source-model",
      provider := some "source-provider", harnessVersion := some "source-version",
      instructions := some "source instructions",
      sessionId := some (cClaudeFixtureUuid "source-session") },
    activeLeaf := some 0,
    origin := {
      format := .pi, sourceRef := "claude-export-prerequisite",
      extras := some transcriptExtras } }

private def cClaudeBadRawTimestampExtras : Json := Json.mkObj [
  ("claudeRawEnvelope", Json.mkObj [
    ("timestamp", Json.str "not-a-timestamp")])]

/-- Target metadata is either consumed and validated or refused precisely.
The valid foreign case also pins export→import→export byte stability and proves
that replaced source identity remains in an explicitly unverified marker. -/
def claudeExportPrerequisitesAndStabilityChecked : Bool :=
  let target := "2030-01-02T03:04:05.006Z"
  let valid := cClaudeExportPrerequisiteFixture
    (some "/target") (some (Json.str target))
  let badTarget := cClaudeExportPrerequisiteFixture
    (some "/target") (some (Json.str "tomorrow"))
  let badSource := cClaudeExportPrerequisiteFixture
    (some "/target") (some (Json.str target))
    (some (Json.mkObj [("ts", Json.str "later")]))
  let badRaw := cClaudeExportPrerequisiteFixture
    (some "/target") (some (Json.str target))
    (some cClaudeBadRawTimestampExtras)
  let missingCwd := cClaudeExportPrerequisiteFixture
    none (some (Json.str target))
  let missingTime := cClaudeExportPrerequisiteFixture
    (some "/target") none
  let missingSession := cClaudeExportPrerequisiteFixture
    (some "/target") (some (Json.str target)) none .absent none
  let invalidSession := cClaudeExportPrerequisiteFixture
    (some "/target") (some (Json.str target)) none .absent
    (some "not-a-uuid")
  let missingHarnessVersion := cClaudeExportPrerequisiteFixture
    (some "/target") (some (Json.str target)) none .absent
    (some (cClaudeFixtureUuid "target-session")) none
  let wrongHarnessVersion := cClaudeExportPrerequisiteFixture
    (some "/target") (some (Json.str target)) none .absent
    (some (cClaudeFixtureUuid "target-session")) (some "2.1.206")
  let interpolated := cClaudeExportPrerequisiteFixture
    (some "/target") (some (Json.str target)) none
    (.interpolated ⟨17⟩ "fixture interpolation")
  let sequenced := cClaudeExportPrerequisiteFixture
    (some "/target") (some (Json.str target)) none (.sequenced 7)
  let recordedTimestamp := (iso8601ToEpochMs? target).getD ⟨0⟩
  let recorded := cClaudeExportPrerequisiteFixture
    (some "/target") (some (Json.str "2040-01-01T00:00:00.000Z"))
    (some (Json.mkObj [("ts", Json.str target)])) (.recorded recordedTimestamp)
  let recordedConflict := cClaudeExportPrerequisiteFixture
    (some "/target") (some (Json.str target))
    (some (Json.mkObj [("ts", Json.str "2031-01-02T03:04:05.006Z")]))
    (.recorded recordedTimestamp)
  let emitsTarget := fun (transcript : Transcript) =>
    match exportClaudeCodeChecked transcript with
    | .ok output =>
        match cParseClaudeJsonLines output with
        | .ok (record :: _) => cstr record "timestamp" == some target
        | _ => false
    | .error _ => false
  let preservesTime := fun (transcript : Transcript) (expected : Time) =>
    match exportClaudeCodeChecked transcript with
    | .error _ => false
    | .ok first =>
        match importClaudeCode first with
        | .error _ => false
        | .ok restored =>
            restored.entries[0]?.map (fun entry => entry.time) == some expected &&
              match exportClaudeCodeChecked restored with
              | .ok second => second == first
              | .error _ => false
  let empty : Transcript := {
    threads := #[{ kind := .main }], entries := #[],
    origin := { format := .pi, sourceRef := "empty-claude-export" } }
  exportClaudeCode empty == "" &&
  (match exportClaudeCodeChecked empty with
   | .error error =>
       error == "Claude export requires at least one entry for a resumable target"
   | .ok _ => false) &&
  claudeHasInvalidPreferredTimestamp badTarget &&
  claudeHasInvalidPreferredTimestamp badSource &&
  claudeHasInvalidPreferredTimestamp badRaw &&
  claudeHasInvalidPreferredTimestamp recordedConflict &&
  claudeExportPrerequisiteErrors badTarget ==
    ["target_timestamp must be UTC ISO-8601 with optional seconds or exactly millisecond precision"] &&
  claudeExportPrerequisiteErrors badSource ==
    ["entries[0].origin.ts must be UTC ISO-8601 with optional seconds or exactly millisecond precision"] &&
  claudeExportPrerequisiteErrors badRaw ==
    ["entries[0].origin.claudeRawEnvelope.timestamp must be UTC ISO-8601 with optional seconds or exactly millisecond precision"] &&
  claudeExportPrerequisiteErrors recordedConflict ==
    ["entries[0].origin.ts conflicts with typed recorded time"] &&
  claudeExportPrerequisiteErrors missingCwd ==
    ["Claude export requires origin.extras.target_cwd for a non-native target; source EnvInfo is not a launch target"] &&
  claudeExportPrerequisiteErrors missingTime ==
    ["Claude export requires origin.extras.target_timestamp for a non-native target"] &&
  claudeExportPrerequisiteErrors missingSession ==
    ["Claude export requires origin.extras.target_session_id (a UUID) for a non-native target"] &&
  claudeExportPrerequisiteErrors invalidSession ==
    ["Claude export target sessionId must be a UUID"] &&
  claudeExportPrerequisiteErrors missingHarnessVersion ==
    ["Claude export requires origin.extras.target_harness_version = '2.1.216' for a non-native target"] &&
  claudeExportPrerequisiteErrors wrongHarnessVersion ==
    ["Claude export target_harness_version must be '2.1.216', got '2.1.206'"] &&
  claudeExportPrerequisiteErrors interpolated == [] &&
  claudeExportPrerequisiteErrors sequenced == [] &&
  emitsTarget valid && emitsTarget interpolated && emitsTarget sequenced &&
  emitsTarget recorded &&
  preservesTime valid .absent &&
  preservesTime interpolated (.interpolated ⟨17⟩ "fixture interpolation") &&
  preservesTime sequenced (.sequenced 7) &&
  preservesTime recorded (.recorded recordedTimestamp) &&
  !(Loom.Ops.obligations .claudeCode interpolated).contains .dropRecordedTime &&
  !(Loom.Ops.obligations .claudeCode sequenced).contains .dropRecordedTime &&
  (Loom.Ops.obligations .claudeCode interpolated).contains .synthesizeTimestamps &&
  (Loom.Ops.obligations .claudeCode sequenced).contains .synthesizeTimestamps &&
  (Loom.Ops.obligations .claudeCode valid).contains .synthesizeTimestamps &&
  match exportClaudeCodeChecked valid with
  | .error _ => false
  | .ok first =>
      cContains first ("\"" ++ claudeCarrierMarkerKey ++ "\"") &&
      match cParseClaudeJsonLines first, importClaudeCode first with
      | .ok [record, sourceEnv, pointer], .ok restored =>
          cstr record "uuid" == some (cGeneratedClaudeUuid
            (cClaudeFixtureUuid "target-session") 1) &&
          cstr record "sessionId" == some (cClaudeFixtureUuid "target-session") &&
          cstr record "cwd" == some "/target" &&
          cstr record "timestamp" == some target &&
          (match cParseTranscriptProvenanceCarrier? sourceEnv with
           | some (.sourceEnv env _) => env == valid.env
           | _ => false) &&
          restored.env == valid.env &&
          (cobj record claudeCarrierMarkerKey >>= fun marker =>
            cobj marker "identityProvenance" >>= fun identity =>
            cstr identity "sourceEntryId") == some "" &&
          cstr pointer "leafUuid" == some (cGeneratedClaudeUuid
            (cClaudeFixtureUuid "target-session") 1) &&
          match exportClaudeCodeChecked restored with
          | .ok second => second == first
          | .error _ => false
      | _, _ => false

example : claudeExportPrerequisitesAndStabilityChecked = true := by native_decide

private def cRawClaudeIdentityLine
    (uuid : String) (parentUuid : Json) (sessionId : String) : String :=
  (Json.mkObj [
    ("type", Json.str "user"), ("uuid", Json.str uuid),
    ("parentUuid", parentUuid), ("sessionId", Json.str sessionId),
    ("cwd", Json.str "/tmp"),
    ("timestamp", Json.str (cClaudeFixtureTimestamp "T0")),
    ("message", Json.mkObj [
      ("role", Json.str "user"), ("content", Json.str "identity")])]).compress

/-- Every native graph and resume-pointer identity is checked against Claude
Code 2.1.214's observed case-insensitive 8-4-4-4-12 UUID contract. -/
def claudeNativeUuidContractChecked : Bool :=
  let validEntry := cClaudeFixtureUuid "valid-entry"
  let validParent := cClaudeFixtureUuid "valid-parent"
  let validSession := cClaudeFixtureUuid "valid-session"
  let badEntry := cRawClaudeIdentityLine "entry-id" Json.null validSession
  let badSession := cRawClaudeIdentityLine validEntry Json.null "session-id"
  let badParent := cRawClaudeIdentityLine validEntry (Json.str "parent-id") validSession
  let badPointer := (Json.mkObj [
    ("type", Json.str "last-prompt"), ("sessionId", Json.str validSession),
    ("leafUuid", Json.str "leaf-id")]).compress
  let valid := cRawClaudeIdentityLine validEntry Json.null validSession
  claudeUuidValid validEntry && claudeUuidValid validParent &&
  !claudeUuidValid "00000000-0000-0000-0000-00000000000g" &&
  cRejectedWith badEntry
    "malformed Claude record at line 1: uuid must be a UUID" &&
  cRejectedWith badSession
    "malformed Claude record at line 1: sessionId must be a UUID" &&
  cRejectedWith badParent
    "malformed Claude record at line 1: parentUuid must be a UUID or null" &&
  cRejectedWith (String.intercalate "\n" [valid, badPointer])
    "malformed Claude record at line 2: leafUuid must be a UUID"

example : claudeNativeUuidContractChecked = true := by native_decide

private def claudeUuidReservationFixture : Transcript :=
  let sessionId := cClaudeFixtureUuid "uuid-reservation-session"
  let reservedLater := cGeneratedClaudeUuid sessionId 1
  let duplicated := "11111111-1111-4111-8111-111111111111"
  let origin (rawId : String) : Origin := {
    format := .pi, sourceRef := "uuid-reservation-adversary", rawId := some rawId }
  let sourceEnv : EnvInfo := {
    cwd := some "/source", model := some "source-model",
    provider := some "source-provider", harnessVersion := some "source-version",
    instructions := some "source controls stay inert",
    sessionId := some (cClaudeFixtureUuid "uuid-reservation-source") }
  { threads := #[{ kind := .main }],
    entries := #[
      { payload := .userMsg [.text "invalid identity"],
        origin := origin "foreign-entry" },
      { parent := some 0, payload := .assistantMsg [.text "reserved later"],
        origin := origin reservedLater },
      { parent := some 1, payload := .userMsg [.text "duplicate one"],
        origin := origin duplicated },
      { parent := some 2, payload := .assistantMsg [.text "duplicate leaf"],
        origin := origin duplicated }],
    env := sourceEnv,
    activeLeaf := some 3,
    origin := {
      format := .pi, sourceRef := "uuid-reservation-adversary",
      extras := some (Json.mkObj [
        ("target_timestamp", Json.str "2030-01-02T03:04:05.006Z"),
        ("target_cwd", Json.str "/target"),
        ("target_session_id", Json.str sessionId),
        ("target_harness_version", Json.str claudeTargetValidationBuild)]) } }

private def cIdentitySourceEntry? (record : Json) : Option Json := do
  let marker ← cobj record claudeCarrierMarkerKey
  let identity ← cobj marker "identityProvenance"
  cobj identity "sourceEntryId"

/-- Reservation is transcript-wide, not left-to-right: an invalid early ID
cannot synthesize the UUID explicitly owned by a later entry. Duplicate valid
raw UUIDs are all replaced, every emitted UUID is distinct, the generated leaf
is a valid resume pointer, and identity provenance is byte-stable under E-I-E. -/
def claudeUuidReservationAndStabilityChecked : Bool :=
  let sessionId := cClaudeFixtureUuid "uuid-reservation-session"
  let expected := [cGeneratedClaudeUuid sessionId 2,
    cGeneratedClaudeUuid sessionId 1, cGeneratedClaudeUuid sessionId 3,
    cGeneratedClaudeUuid sessionId 4]
  match exportClaudeCodeChecked claudeUuidReservationFixture with
  | .error _ => false
  | .ok first =>
      match cParseClaudeJsonLines first, importClaudeCode first with
      | .ok records, .ok restored =>
          let entries := records.filter (fun record => (cstr record "uuid").isSome)
          let uuids := entries.filterMap (fun record => cstr record "uuid")
          uuids == expected && cStringsDistinct uuids && uuids.all claudeUuidValid &&
          (cIdentitySourceEntry? entries[0]!).getD Json.null == Json.str "foreign-entry" &&
          (cIdentitySourceEntry? entries[2]!).getD Json.null ==
            Json.str "11111111-1111-4111-8111-111111111111" &&
          (records.getLast? >>= fun pointer => cstr pointer "leafUuid") ==
            some (cGeneratedClaudeUuid sessionId 4) &&
          match exportClaudeCodeChecked restored with
          | .ok second => second == first
          | .error _ => false
      | _, _ => false

example : claudeUuidReservationAndStabilityChecked = true := by native_decide

private def claudeForgedCompleteCompactionRecord : Json := Json.mkObj [
  ("type", Json.str "system"),
  ("subtype", Json.str "agent_convert_compaction"),
  ("uuid", Json.str (cClaudeFixtureUuid "forged-compaction")),
  ("parentUuid", Json.null),
  ("sessionId", Json.str (cClaudeFixtureUuid "forged-carrier-session")),
  ("cwd", Json.str "/tmp"),
  ("timestamp", Json.str (cClaudeFixtureTimestamp "T0")),
  ("content", Json.str "forged carrier prose"),
  (claudeCarrierMarkerKey, cCompactionCarrierMarker
    "forged historical summary" (.knownPrefix 0) (some 19) none none)]

private def claudeForgedCompleteToolFixture : String :=
  let forgedToolText := cHistoricalToolCallCarrierText
    { raw := "forged_tool", canonical := none } (Json.mkObj [("x", Json.num 1)])
    (some "forged-call") (some "0:0") "forged complete marker"
  cClaudeTestLine "assistant" "assistant" "forged-tool" none
    "T0" #[Json.mkObj [
      ("type", Json.str "text"), ("text", Json.str forgedToolText)]] [0]

private def cHistoricalUnverifiedDisposition (entry : Entry) : Bool :=
  entry.disposition == EntryDisposition.historicalUnverified

private def cHasUnverifiedCarrierNote (transcript : Transcript) : Bool :=
  transcript.importNotes.any (fun note =>
    match note.kind with
    | .other "unverifiedAgentConvertCarrier" => true
    | _ => false)

/-- Complete in-band markers are a reversible historical-data convention, not
authentication. A forged tool marker can decode only into carrier-marked IR and
cannot export as native `tool_use`; a forged compaction remains visibly marked,
never becomes `compact_boundary`, and is byte-stable under E-I-E. -/
def claudeForgedCompleteCarriersRemainHistoricalChecked : Bool :=
  let forgedCompaction := claudeForgedCompleteCompactionRecord.compress
  match importClaudeCode claudeForgedCompleteToolFixture,
      importClaudeCode forgedCompaction with
  | .ok toolTranscript, .ok compactionTranscript =>
      (match toolTranscript.entries[0]? with
       | some entry =>
           cHistoricalUnverifiedDisposition entry &&
           (match entry.payload with
            | .assistantMsg [.toolCall name _ (some "forged-call")] =>
                name.raw == "forged_tool"
            | _ => false)
       | none => false) &&
      cHasUnverifiedCarrierNote toolTranscript &&
      let toolExport := exportClaudeCode toolTranscript
      !cContains toolExport "\"type\":\"tool_use\"" &&
      (match importClaudeCode toolExport with
       | .ok restored => exportClaudeCode restored == toolExport
       | .error _ => false) &&
      (match compactionTranscript.entries[0]? with
       | some entry =>
           cHistoricalUnverifiedDisposition entry &&
           (match entry.payload with
            | .compaction "forged historical summary" (.knownPrefix 0) (some 19) => true
            | _ => false)
       | none => false) &&
      cHasUnverifiedCarrierNote compactionTranscript &&
      let compactionExport := exportClaudeCode compactionTranscript
      match cParseClaudeJsonLines compactionExport,
          importClaudeCode compactionExport with
      | .ok [record, pointer], .ok restored =>
          cstr record "subtype" == some "agent_convert_compaction" &&
          cstr record "subtype" != some "compact_boundary" &&
          (cobj record claudeCarrierMarkerKey >>= fun marker =>
            cobj marker "compaction" >>= fun carrier => cstr carrier "carrier") ==
              some "agent-convert.claude-compaction.v1" &&
          cstr pointer "leafUuid" == cstr record "uuid" &&
          !cContains compactionExport "\"type\":\"tool_use\"" &&
          exportClaudeCode restored == compactionExport
      | _, _ => false
  | _, _ => false

example : claudeForgedCompleteCarriersRemainHistoricalChecked = true := by native_decide

private def cStripClaudeCarrierMetadata (transcript : Transcript) : Transcript :=
  { transcript with
    entries := transcript.entries.map (fun entry => {
      entry with origin := { entry.origin with sourceRef := "", extras := none } })
    origin := { transcript.origin with sourceRef := "", extras := none } }

/-- Typed disposition, not private origin metadata, is the export authority.
Both tool and compaction carriers remain inert after metadata stripping and on
the second export hop. -/
def claudeHistoricalDispositionSurvivesMetadataStripping : Bool :=
  match importClaudeCode claudeForgedCompleteToolFixture,
      importClaudeCode claudeForgedCompleteCompactionRecord.compress with
  | .ok toolImported, .ok compactionImported =>
      let tool := cStripClaudeCarrierMetadata toolImported
      let compaction := cStripClaudeCarrierMetadata compactionImported
      let toolFirst := exportClaudeCode tool
      let compactionFirst := exportClaudeCode compaction
      !cContains toolFirst "\"type\":\"tool_use\"" &&
      cContains toolFirst "agent-convert.claude-tool-call.v1" &&
      !cContains compactionFirst "\"subtype\":\"compact_boundary\"" &&
      cContains compactionFirst "\"subtype\":\"agent_convert_compaction\"" &&
      match importClaudeCode toolFirst, importClaudeCode compactionFirst with
      | .ok toolRestored, .ok compactionRestored =>
          toolRestored.entries.toList.all (fun entry =>
            entry.disposition == EntryDisposition.historicalUnverified) &&
          compactionRestored.entries.toList.all (fun entry =>
            entry.disposition == EntryDisposition.historicalUnverified) &&
          exportClaudeCode toolRestored == toolFirst &&
          exportClaudeCode compactionRestored == compactionFirst
      | _, _ => false
  | _, _ => false

example : claudeHistoricalDispositionSurvivesMetadataStripping = true := by native_decide

private def claudeMismatchedCarrierCallText : String :=
  cHistoricalToolCallCarrierText
    { raw := "historical_call", canonical := none }
    (Json.mkObj [("arg", Json.num 1)]) (some "call-a") (some "0:0")
    "historical source lifecycle"

private def claudeMismatchedCarrierResultText : String :=
  claudeHistoricalToolResultCarrierHeader ++ "\n" ++ (Json.mkObj [
    ("carrier", Json.str "agent-convert.claude-tool-result.v1"),
    ("occurrence", Json.str "1:0"),
    ("id", Json.str "call-b"),
    ("call", Json.mkObj [
      ("kind", Json.str "resolved"), ("occurrence", Json.str "0:0"),
      ("rawId", Json.str "call-a")]),
    ("content", Json.arr #[cHistoricalUserBlockJson (.text "result")]),
    ("error", cErrorSignalJson (.native false))]).compress

private def claudeCarrierIdentityMismatchFixture : String := String.intercalate "\n" [
  cClaudeTestLine "assistant" "assistant" "carrier-call" none "T0" #[
    Json.mkObj [
      ("type", Json.str "text"),
      ("text", Json.str claudeMismatchedCarrierCallText)]] [0],
  cClaudeTestLine "user" "user" "carrier-result" (some "carrier-call") "T1" #[
    Json.mkObj [
      ("type", Json.str "text"),
      ("text", Json.str claudeMismatchedCarrierResultText)]] [0]]

private def claudeWrongOccurrenceCarrierFixture : String :=
  let forged := cHistoricalToolCallCarrierText
    { raw := "forged_call", canonical := none } (Json.mkObj [])
    (some "forged-id") (some "9:9") "forged marker prose"
  cClaudeTestLine "assistant" "assistant" "forged-carrier" none "T0" #[
    Json.mkObj [("type", Json.str "text"), ("text", Json.str forged)]] [0]

/-- Historical linkage requires one canonical occurrence plus agreement between
the result ID, call-reference ID, and actual call ID. Wrong coordinates decode
only to unmodeled inert data, and no such case can emit native tool state. -/
def claudeCarrierOccurrenceAndIdentityChecked : Bool :=
  match importClaudeCode claudeCarrierIdentityMismatchFixture,
      importClaudeCode claudeWrongOccurrenceCarrierFixture with
  | .ok mismatch, .ok wrongOccurrence =>
      (match mismatch.entries[1]? with
       | some entry => match entry.payload with
         | .envMsg [.toolResult
             (.unresolved (some "call-b")
               "historical tool call occurrence and raw IDs disagree")
             [.text "result"] (.native false)] => true
         | _ => false
       | none => false) &&
      (match wrongOccurrence.entries[0]? with
       | some entry => match entry.payload with
         | .assistantMsg [
             .unmodeled "historical-carrier-occurrence" (Json.str _)] => true
         | _ => false
       | none => false) &&
      let mismatchExport := exportClaudeCode mismatch
      let wrongExport := exportClaudeCode wrongOccurrence
      !cContains mismatchExport "\"type\":\"tool_use\"" &&
      !cContains mismatchExport "\"type\":\"tool_result\"" &&
      !cContains wrongExport "\"type\":\"tool_use\"" &&
      match importClaudeCode wrongExport with
      | .ok restored =>
          match restored.entries[0]? with
          | some entry => match entry.payload with
            | .assistantMsg [
                .unmodeled "historical-carrier-occurrence" (Json.str _)] => true
            | _ => false
          | none => false
      | .error _ => false
  | _, _ => false

example : claudeCarrierOccurrenceAndIdentityChecked = true := by native_decide

/-! ## Checked-boundary and carrier-schema regressions -/

private def cCheckedClaudeBoundaryFixture (payload : Payload) : Transcript :=
  let base := cClaudeExportPrerequisiteFixture
    (some "/checked-target")
    (some (Json.str "2030-01-02T03:04:05.006Z"))
  { base with entries := base.entries.map (fun entry => { entry with payload }) }

/-- Direct callers receive the same source-validity and destructive-loss gates
as the CLI. Neither an invalid parent nor an empty environment payload can be
normalized into an artifact. -/
def claudeCheckedExportRejectsInvalidIrAndDestructiveLoss : Bool :=
  let valid := cCheckedClaudeBoundaryFixture (.userMsg [.text "valid"])
  let invalidParent := { valid with
    entries := valid.entries.map (fun entry => { entry with parent := some 99 }) }
  let destructive := cCheckedClaudeBoundaryFixture (.envMsg [])
  !(Loom.violations invalidParent).isEmpty &&
  (Loom.violations destructive).isEmpty &&
  (Loom.Ops.obligations .claudeCode destructive).contains .dropToolResults &&
  exportClaudeCode invalidParent == "" && exportClaudeCode destructive == "" &&
  (match exportClaudeCodeChecked invalidParent with
   | .error error => error.startsWith
       "Claude source transcript has structural violations:"
   | .ok _ => false) &&
  (match exportClaudeCodeChecked destructive with
   | .error error => error ==
       "Claude target has destructive export obligations: [Loom.Ops.Obligation.dropToolResults]"
   | .ok _ => false)

example : claudeCheckedExportRejectsInvalidIrAndDestructiveLoss = true := by
  native_decide

private def cReservedConversationCarrierRecord
    (kind role text : String) (indices : Array Json)
    (protocol : String := claudeCarrierProtocol) : Json :=
  cUuidFixtureRecord (Json.mkObj [
    ("type", Json.str kind), ("uuid", Json.str "reserved-carrier"),
    ("parentUuid", Json.null), ("sessionId", Json.str "carrier-test"),
    ("cwd", Json.str "/tmp"),
    ("timestamp", Json.str (cClaudeFixtureTimestamp "T0")),
    ("isSidechain", Json.bool false),
    (claudeCarrierMarkerKey, Json.mkObj [
      ("protocol", Json.str protocol), ("contentBlocks", Json.arr indices)]),
    ("message", Json.mkObj [
      ("role", Json.str role), ("content", Json.arr #[
        Json.mkObj [("type", Json.str "text"), ("text", Json.str text)]])])])

private def cReservedCarrierRejected (record : Json) : Bool :=
  match importClaudeCode record.compress with
  | .error error => error.startsWith "malformed Claude record at line 1:"
  | .ok _ => false

private def cReservedCarrierRawMarkerMember
    (kind role text rawMember : String) : String :=
  let marker := Json.mkObj [
    ("protocol", Json.str claudeCarrierProtocol),
    ("contentBlocks", Json.arr #[Json.num 0])]
  let record := cReservedConversationCarrierRecord kind role text #[Json.num 0]
  let generated := "\"" ++ claudeCarrierMarkerKey ++ "\":" ++ marker.compress
  record.compress.replace generated rawMember

private def cDuplicateReservedSourceRejected (source : String) : Bool :=
  match importClaudeCode source with
  | .error error => cContains error "duplicate object member"
  | .ok _ => false

/-- Presence of the reserved marker closes the schema boundary. Malformed JSON,
foreign carrier IDs/protocols, duplicate or invalid indices, out-of-range
indices, and role/header disagreement all refuse instead of becoming text. -/
def claudeMalformedReservedConversationCarriersRefused : Bool :=
  let validCallRecord := cHistoricalCallRecord
    { raw := "reserved_tool", canonical := none } (Json.mkObj [])
    (some "reserved-call") (some "0:0") "historical source lifecycle"
  let validCallText := claudeHistoricalToolCallCarrierHeader ++ "\n" ++
    validCallRecord.compress
  let malformedJson := claudeHistoricalToolCallCarrierHeader ++ "\n{"
  let wrongCarrierId := claudeHistoricalToolCallCarrierHeader ++ "\n" ++
    (cPutJsonField validCallRecord "carrier"
      (Json.str "agent-convert.claude-tool-call.v999")).compress
  [
    cReservedConversationCarrierRecord "assistant" "assistant" malformedJson #[Json.num 0],
    cReservedConversationCarrierRecord "assistant" "assistant" wrongCarrierId #[Json.num 0],
    cReservedConversationCarrierRecord "assistant" "assistant" validCallText
      #[Json.num 0, Json.num 0],
    cReservedConversationCarrierRecord "assistant" "assistant" validCallText #[Json.num 1],
    cReservedConversationCarrierRecord "assistant" "assistant" validCallText
      #[Json.str "0"],
    cReservedConversationCarrierRecord "user" "user" validCallText #[Json.num 0],
    cReservedConversationCarrierRecord "assistant" "assistant" validCallText
      #[Json.num 0] "agent-convert.claude-carriers.v999"
  ].all cReservedCarrierRejected

example : claudeMalformedReservedConversationCarriersRefused = true := by
  native_decide

/-- Duplicate members in reserved outer markers and marked carrier JSON are
rejected before map normalization, independent of member order. The same text
without an ownership marker remains ordinary assistant content. -/
def claudeDuplicateReservedJsonMembersRefused : Bool :=
  let validCarrierId := "agent-convert.claude-tool-call.v1"
  let invalidCarrierId := "agent-convert.claude-tool-call.invalid"
  let validMarker := Json.mkObj [
    ("protocol", Json.str claudeCarrierProtocol),
    ("contentBlocks", Json.arr #[Json.num 0])]
  let invalidMarker := Json.mkObj [
    ("protocol", Json.str "agent-convert.claude-carriers.invalid"),
    ("contentBlocks", Json.arr #[Json.num 0])]
  let callJson := "{\"carrier\":\"" ++ validCarrierId ++
    "\",\"id\":\"duplicate-call\",\"name\":\"duplicate_tool\",\"canonical\":null," ++
    "\"arguments\":{},\"reason\":\"historical source lifecycle\",\"occurrence\":\"0:0\"}"
  let callText := claudeHistoricalToolCallCarrierHeader ++ "\n" ++ callJson
  let markerMember := fun (marker : Json) =>
    "\"" ++ claudeCarrierMarkerKey ++ "\":" ++ marker.compress
  let duplicateTop := fun (first second : Json) =>
    markerMember first ++ "," ++ markerMember second
  let duplicateProtocol := fun (first second : String) =>
    "\"" ++ claudeCarrierMarkerKey ++ "\":{" ++
      "\"protocol\":\"" ++ first ++ "\",\"protocol\":\"" ++ second ++
      "\",\"contentBlocks\":[0]}"
  let duplicateCarrierJson := fun (first second : String) =>
    "{\"carrier\":\"" ++ first ++ "\",\"carrier\":\"" ++ second ++
      "\",\"id\":\"duplicate-call\",\"name\":\"duplicate_tool\",\"canonical\":null," ++
      "\"arguments\":{},\"reason\":\"historical source lifecycle\",\"occurrence\":\"0:0\"}"
  let duplicateResultJson := fun (first second : String) =>
    "{\"carrier\":\"agent-convert.claude-tool-result.v1\",\"occurrence\":\"0:0\"," ++
      "\"id\":\"duplicate-call\",\"call\":{" ++
      "\"kind\":\"" ++ first ++ "\",\"kind\":\"" ++ second ++
      "\",\"rawId\":\"duplicate-call\",\"note\":\"historical\"}," ++
      "\"content\":[{\"kind\":\"text\",\"text\":\"result\"}]," ++
      "\"error\":{\"kind\":\"native\",\"isError\":false}}"
  let markedCall := fun rawJson => cReservedConversationCarrierRecord
    "assistant" "assistant" (claudeHistoricalToolCallCarrierHeader ++ "\n" ++ rawJson)
      #[Json.num 0] |>.compress
  let markedResult := fun rawJson => cReservedConversationCarrierRecord
    "user" "user" (claudeHistoricalToolResultCarrierHeader ++ "\n" ++ rawJson)
      #[Json.num 0] |>.compress
  let duplicateSources := [
    cReservedCarrierRawMarkerMember "assistant" "assistant" callText
      (duplicateTop invalidMarker validMarker),
    cReservedCarrierRawMarkerMember "assistant" "assistant" callText
      (duplicateTop validMarker invalidMarker),
    cReservedCarrierRawMarkerMember "assistant" "assistant" callText
      (duplicateProtocol "agent-convert.claude-carriers.invalid" claudeCarrierProtocol),
    cReservedCarrierRawMarkerMember "assistant" "assistant" callText
      (duplicateProtocol claudeCarrierProtocol "agent-convert.claude-carriers.invalid"),
    markedCall (duplicateCarrierJson invalidCarrierId validCarrierId),
    markedCall (duplicateCarrierJson validCarrierId invalidCarrierId),
    markedResult (duplicateResultJson "future" "unresolved"),
    markedResult (duplicateResultJson "unresolved" "future")]
  let ordinaryDuplicateText := claudeHistoricalToolCallCarrierHeader ++ "\n" ++
    duplicateCarrierJson invalidCarrierId validCarrierId
  duplicateSources.all cDuplicateReservedSourceRejected &&
    match importClaudeCode (cClaudeTestLine "assistant" "assistant"
      "ordinary-duplicate-carrier" none "T0" #[
        Json.mkObj [("type", Json.str "text"), ("text", Json.str ordinaryDuplicateText)]]) with
    | .ok ordinary =>
        match ordinary.entries[0]? with
        | some entry => match entry.payload with
          | .assistantMsg [.text text] => text == ordinaryDuplicateText
          | _ => false
        | none => false
    | .error _ => false

example : claudeDuplicateReservedJsonMembersRefused = true := by native_decide

private def claudeProjectedChildCallText : String :=
  cHistoricalToolCallCarrierText
    { raw := "child_tool", canonical := none }
    (Json.mkObj [("path", Json.str "/tmp/child")])
    (some "child-call") (some "3:0") "historical source lifecycle"

private def claudeProjectedChildResultText : String :=
  claudeHistoricalToolResultCarrierHeader ++ "\n" ++ (Json.mkObj [
    ("carrier", Json.str "agent-convert.claude-tool-result.v1"),
    ("occurrence", Json.str "5:0"), ("id", Json.str "child-call"),
    ("call", Json.mkObj [
      ("kind", Json.str "resolved"), ("occurrence", Json.str "3:0"),
      ("rawId", Json.str "child-call")]),
    ("content", Json.arr #[cHistoricalUserBlockJson (.text "child result")]),
    ("error", cErrorSignalJson (.native false))]).compress

/-- Interleaved child projection maps global 3:0/5:0 to local 1:0/2:0 in
both carriers. Reimport reconstructs a typed, resolved lifecycle whose two
entries remain historical and structurally valid. -/
def claudeProjectedHistoricalChildLifecycleChecked : Bool :=
  let carrierOrigin := cMarkOriginCarrierBlocks
    { format := .claudeCode, sourceRef := "projected-child" } [0]
  let callEntry : Entry := {
    payload := .assistantMsg [.text claudeProjectedChildCallText]
    origin := carrierOrigin
    disposition := .historicalUnverified }
  let resultEntry : Entry := {
    payload := .userMsg [.text claudeProjectedChildResultText]
    origin := carrierOrigin
    disposition := .historicalUnverified }
  let callPayload := projectClaudeHistoricalCarrierCoordinates [1, 3, 5] callEntry
  let resultPayload := projectClaudeHistoricalCarrierCoordinates [1, 3, 5] resultEntry
  match callPayload, resultPayload with
  | .assistantMsg [.text callText], .userMsg [.text resultText] =>
      let source := String.intercalate "\n" [
        cClaudeTestLine "user" "user" "projected-child-root" none "T0" #[
          Json.mkObj [("type", Json.str "text"), ("text", Json.str "child root")]],
        cClaudeTestLine "assistant" "assistant" "projected-child-call"
          (some "projected-child-root") "T1" #[
            Json.mkObj [("type", Json.str "text"), ("text", Json.str callText)]] [0],
        cClaudeTestLine "user" "user" "projected-child-result"
          (some "projected-child-call") "T2" #[
            Json.mkObj [("type", Json.str "text"), ("text", Json.str resultText)]] [0]]
      match importClaudeCode source with
      | .error _ => false
      | .ok restored =>
          (Loom.violations restored).isEmpty &&
          (match restored.entries[1]?, restored.entries[2]? with
           | some callEntry, some resultEntry =>
               callEntry.disposition == .historicalUnverified &&
               resultEntry.disposition == .historicalUnverified &&
               (match callEntry.payload with
                | .assistantMsg [.toolCall name _ (some "child-call")] =>
                    name.raw == "child_tool"
                | _ => false) &&
               (match resultEntry.payload with
                | .envMsg [.toolResult (.resolved 1 0) [.text "child result"]
                    (.native false)] => true
                | _ => false)
           | _, _ => false)
  | _, _ => false

example : claudeProjectedHistoricalChildLifecycleChecked = true := by
  native_decide

/-- Header-looking text is not an exporter-owned carrier unless its exact block
index is present in entry provenance. Sidecar projection must not parse or
canonicalize an ordinary collision. -/
def claudeProjectionRequiresOwnedCarrierMarker : Bool :=
  let ordinaryCall : Entry := {
    payload := .assistantMsg [.text claudeProjectedChildCallText]
    origin := { format := .claudeCode, sourceRef := "ordinary-call-collision" } }
  let ordinaryResult : Entry := {
    payload := .userMsg [.text claudeProjectedChildResultText]
    origin := { format := .claudeCode, sourceRef := "ordinary-result-collision" } }
  (match projectClaudeHistoricalCarrierCoordinates [1, 3, 5] ordinaryCall with
   | .assistantMsg [.text text] => text == claudeProjectedChildCallText
   | _ => false) &&
    (match projectClaudeHistoricalCarrierCoordinates [1, 3, 5] ordinaryResult with
     | .userMsg [.text text] => text == claudeProjectedChildResultText
     | _ => false)

example : claudeProjectionRequiresOwnedCarrierMarker = true := by native_decide

private def cSourceEnvExtensionCarrier (env : EnvInfo) : Json :=
  let payload := cOverlayJsonObject (cSourceEnvJson env) (Json.mkObj [
    ("futurePayload", Json.mkObj [("marker", Json.str "payload-extension")])])
  let base := cTranscriptProvenanceCarrier "sourceEnv" payload
  let marker := (cobj base claudeCarrierMarkerKey).getD (Json.mkObj [])
  let carrier := (cobj marker "transcriptProvenance").getD (Json.mkObj [])
  let carrier := cOverlayJsonObject carrier (Json.mkObj [
    ("futureCarrier", Json.str "carrier-extension")])
  let marker := cOverlayJsonObject marker (Json.mkObj [
    ("futureMarker", Json.str "marker-extension"),
    ("transcriptProvenance", carrier)])
  cOverlayJsonObject base (Json.mkObj [
    ("futureRecord", Json.str "record-extension"),
    (claudeCarrierMarkerKey, marker)])

/-- Source-environment carriers are additive/open-world. Unknown fields at all
four envelope levels survive E-I-E, while a mutation to typed `EnvInfo` replaces
the carrier's controlled fields on the next export. -/
def claudeSourceEnvironmentExtensionsRoundTripChecked : Bool :=
  let sourceEnv : EnvInfo := {
    cwd := some "/source/old", model := some "old-model",
    provider := some "old-provider", harnessVersion := some "old-version",
    instructions := some "old instructions",
    sessionId := some (cClaudeFixtureUuid "source-old-session") }
  let carrier := cSourceEnvExtensionCarrier sourceEnv
  let source := String.intercalate "\n" [
    cControlFixtureUserLine "source-env-target" none "T1"
      (Json.str "target conversation"), carrier.compress]
  match importClaudeCode source with
  | .error _ => false
  | .ok imported =>
      let mutatedEnv : EnvInfo := {
        cwd := some "/source/new", model := some "new-model",
        provider := some "new-provider", harnessVersion := some "new-version",
        instructions := some "new instructions",
        sessionId := some (cClaudeFixtureUuid "source-new-session") }
      let mutated := { imported with env := mutatedEnv }
      match exportClaudeCodeChecked mutated with
      | .error _ => false
      | .ok first =>
          match cParseClaudeJsonLines first, importClaudeCode first with
          | .ok records, .ok restored =>
              match records.find? (fun record =>
                cstr record "type" == some "agent-convert-provenance"),
                exportClaudeCodeChecked restored with
              | some emittedCarrier, .ok second =>
                  let marker := (cobj emittedCarrier claudeCarrierMarkerKey).getD
                    (Json.mkObj [])
                  let provenance := (cobj marker "transcriptProvenance").getD
                    (Json.mkObj [])
                  let payload := (cobj provenance "payload").getD (Json.mkObj [])
                  restored.env == mutatedEnv && second == first &&
                  cstr emittedCarrier "futureRecord" == some "record-extension" &&
                  cstr marker "futureMarker" == some "marker-extension" &&
                  cstr provenance "futureCarrier" == some "carrier-extension" &&
                  (cobj payload "futurePayload" >>= fun extension =>
                    cstr extension "marker") == some "payload-extension" &&
                  cstr payload "cwd" == mutatedEnv.cwd &&
                  cstr payload "model" == mutatedEnv.model &&
                  cstr payload "provider" == mutatedEnv.provider &&
                  cstr payload "harnessVersion" == mutatedEnv.harnessVersion &&
                  cstr payload "instructions" == mutatedEnv.instructions &&
                  cstr payload "sessionId" == mutatedEnv.sessionId
              | _, _ => false
          | _, _ => false

example : claudeSourceEnvironmentExtensionsRoundTripChecked = true := by
  native_decide

/-! ## Current typed `isMeta` authority regression -/

private def cArchivedControlRecordIsMeta (transcript : Transcript) (index : Nat) : Bool :=
  ((cArchivedControls? transcript >>= fun controls => controls[index]? >>= fun control =>
    cobj control "record" >>= fun record => cbool? record "isMeta")).getD false

def claudeStaleIsMetaMutationText : String :=
  "<system-reminder>literal current user text</system-reminder>"

/-- Preserved raw metadata cannot turn current typed user content back into a
synthetic control. Archived genuine controls retain their exact `isMeta:true`
source record inside inert transcript provenance. -/
def claudeTypedUserClearsStaleIsMetaChecked : Bool :=
  let staleSource := cControlFixtureUserLine "stale-meta-user" none "T1"
    (Json.str "ordinary source user text") true
  let genuineSource := String.intercalate "\n" [
    cControlFixtureUserLine "genuine-meta-root" none "T1"
      (Json.str "ordinary root"),
    cControlFixtureUserLine "genuine-meta-control" (some "genuine-meta-root") "T2"
      (Json.str claudeControlLiteralCollisionText) true]
  match importClaudeCode staleSource, importClaudeCode genuineSource with
  | .ok imported, .ok genuine =>
      let mutated := { imported with entries := imported.entries.map (fun entry =>
        { entry with payload := .userMsg [.text claudeStaleIsMetaMutationText] }) }
      cArchivedControlRecordIsMeta genuine 0 &&
        match exportClaudeCodeChecked mutated, exportClaudeCodeChecked genuine with
        | .ok first, .ok genuineExport =>
            let ordinaryRecord := (cParseClaudeJsonLines first).toOption >>= fun records =>
              records.find? (fun record => cstr record "type" == some "user")
            ordinaryRecord.isSome &&
              (ordinaryRecord >>= fun record => cbool? record "isMeta").isNone &&
              match importClaudeCode first, importClaudeCode genuineExport with
              | .ok restored, .ok restoredGenuine =>
                  restored.entries.size == 1 &&
                    cEntryUserText? restored 0 == some claudeStaleIsMetaMutationText &&
                    (cArchivedControls? restored).isNone &&
                    restoredGenuine.entries.size == 1 &&
                    cArchivedControlRecordIsMeta restoredGenuine 0 &&
                    match exportClaudeCodeChecked restored with
                    | .ok second => second == first
                    | .error _ => false
              | _, _ => false
        | _, _ => false
  | _, _ => false

example : claudeTypedUserClearsStaleIsMetaChecked = true := by native_decide

/-! ## Complete target-bundle regressions -/

def claudeCompleteTargetBundleRequiredChecked : Bool :=
  let target := "2030-01-02T03:04:05.006Z"
  let recorded := (iso8601ToEpochMs? target).getD ⟨0⟩
  let targetSession := cClaudeFixtureUuid "native-version-target-session"
  let foreignRecorded := cClaudeExportPrerequisiteFixture
    (some "/target") none none (.recorded recorded)
  let nativeTargetExtras := Json.mkObj [
    ("target_cwd", Json.str "/native"),
    ("target_session_id", Json.str targetSession),
    ("target_timestamp", Json.str target),
    ("target_harness_version", Json.str "2.1.206")]
  let nativeWrongVersion : Transcript := {
    threads := #[{ kind := .main }],
    entries := #[{
      payload := .userMsg [.text "native explicit version"],
      time := .recorded recorded,
      origin := { format := .claudeCode, sourceRef := "native-version", rawId := some (cClaudeFixtureUuid "native-version-entry") } }],
    activeLeaf := some 0,
    origin := { format := .claudeCode, sourceRef := "native-version", extras := some nativeTargetExtras } }
  claudeExportPrerequisiteErrors foreignRecorded ==
      ["Claude export requires origin.extras.target_timestamp for a non-native target"] &&
    exportClaudeCode foreignRecorded == "" &&
    (match exportClaudeCodeChecked foreignRecorded with
     | .error error => error ==
         "Claude export requires origin.extras.target_timestamp for a non-native target"
     | .ok _ => false) &&
    !cClaudeEnvIsPhysicalTarget nativeWrongVersion &&
    exportClaudeCode nativeWrongVersion == "" &&
    (match exportClaudeCodeChecked nativeWrongVersion with
     | .error error => error ==
         "Claude export target_harness_version must be '2.1.216', got '2.1.206'"
     | .ok _ => false)

example : claudeCompleteTargetBundleRequiredChecked = true := by native_decide

end LoomConvert
