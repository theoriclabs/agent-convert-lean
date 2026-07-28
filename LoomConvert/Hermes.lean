import Loom
import LoomConvert.Parity

/-!
# LoomConvert.Hermes — the Hermes importer (Nous Research CLI agent)

Second executable importer in the Loom port (after `LoomConvert.Pi`). Unlike
every other harness, Hermes is **not JSONL**: a session is a *single JSON
object* (`~/.hermes/sessions/session_*.json`) whose conversation lives in
`messages[]`. So the whole input is parsed once with `Lean.Json.parse` (no
line-by-line stream), which is also why the live-follow tooling excludes
Hermes (`followAdapter.ts:16-18`).

This importer keeps the TS adapter's modeled projection while enforcing a
stricter, loss-aware source contract. It is grounded in `Loom.Formats.Hermes`
(the census over 8 files / 462 messages, 2026-07-06). Importer only — no
exporter.

Mapping (see `Loom.Formats.Hermes.disposition`), under the role-content-sum:

* `role user`      → `Payload.userMsg` with a single `UserBlock.text` from
  `content`, including an explicitly recorded empty string.
* `role assistant` → `Payload.assistantMsg`; blocks in wire order
  reasoning → text → tool_calls. `reasoning_content` (preferred) / `reasoning`
  become an `AssistantBlock.thinking` ONLY when non-whitespace (zero in the
  deepseek corpus). Each `tool_calls[].function` becomes an
  `AssistantBlock.toolCall`: the raw name is preserved and, when it is one of
  the four census-confirmed built-ins (`terminal|read_file|write_file|
  search_files`), a `CanonicalTool` is attached (`toolNameMap`,
  `hermes.ts:60-65`); `arguments` (a JSON-encoded string) is parsed.
  Unknown tool-call variants and empty assistant messages remain exact
  `.unmodeled` blocks instead of disappearing.
* `role tool`      → environment-authored `Payload.envMsg` with a single
  `EnvBlock.toolResult` (its content a `UserBlock.text`). The result carries
  `ErrorSignal.unrecorded`, NOT `native false`: the census (claim
  L3-hermes-error-unrecorded) confirmed there is *no* error field to read —
  `hermes.ts:298`'s hardcoded `isError:false` is not masking a field, there is
  none. The call linkage is resolved positionally and by occurrence from
  `tool_call_id` back to the emitting `AssistantBlock.toolCall`; missing ids
  can link only to missing-id calls and never trigger a synthesized identity.

Malformed known records are rejected with a source path. Unknown message roles
become exact non-conversation events. Every message and the complete session
object are retained in `Origin.extras`; `system_prompt` is also promoted to
`env.instructions`, while top-level tool declarations stay configuration
rather than user dialogue.

Divergences from the pi/TS pipeline (all "leanCore is strictly more faithful",
adjudicated like the L12 signature divergence — see the report / bottom of file):
Loom keeps the *raw* tool name (TS remaps destructively), models the tool
result as a structured `EnvBlock.toolResult` with an honest `unrecorded` error
(TS emits a text block + hardcoded `isError:false`), and records "no cwd" as
`none` (TS fabricates `""`).

Time: Hermes has no per-message timestamps, so every entry is `Time.absent`
rather than interpolated (contrast `hermes.ts:210-212`, which smears
session_start→last_updated).
-/

namespace LoomConvert
open Loom
open Lean (Json)

/-! ## Small Json accessors (copied scaffold from `LoomConvert.Pi`). -/

private def ostr (j : Json) (k : String) : Option String :=
  (j.getObjVal? k >>= Json.getStr?).toOption

private def oobj (j : Json) (k : String) : Option Json :=
  (j.getObjVal? k).toOption

private def hSchemaError (ctx detail : String) : Except String α :=
  .error s!"malformed Hermes {ctx}: {detail}"

private def hEnsureObject (ctx : String) : Json → Except String Unit
  | .obj _ => pure ()
  | _ => hSchemaError ctx "expected an object"

private def hRequireField (ctx : String) (j : Json) (key : String) : Except String Json := do
  hEnsureObject ctx j
  match j.getObjVal? key with
  | .ok value => pure value
  | .error _ => hSchemaError ctx s!"missing required field '{key}'"

private def hRequireString (ctx : String) (j : Json) (key : String) : Except String String := do
  match ← hRequireField ctx j key with
  | .str value => pure value
  | _ => hSchemaError ctx s!"field '{key}' must be a string"

private def hRequireNonemptyString
    (ctx : String) (j : Json) (key : String) : Except String String := do
  let value ← hRequireString ctx j key
  if value.isEmpty then hSchemaError ctx s!"field '{key}' must not be empty"
  else pure value

private def hOptionalString
    (ctx : String) (j : Json) (key : String) : Except String (Option String) := do
  hEnsureObject ctx j
  match j.getObjVal? key with
  | .error _ | .ok .null => pure none
  | .ok (.str value) => pure (some value)
  | .ok _ => hSchemaError ctx s!"field '{key}' must be a string or null when present"

private def hOptionalNonemptyString
    (ctx : String) (j : Json) (key : String) : Except String (Option String) := do
  match ← hOptionalString ctx j key with
  | none => pure none
  | some value =>
      if value.isEmpty then hSchemaError ctx s!"field '{key}' must not be empty"
      else pure (some value)

private def hOptionalBool
    (ctx : String) (j : Json) (key : String) : Except String (Option Bool) := do
  hEnsureObject ctx j
  match j.getObjVal? key with
  | .error _ | .ok .null => pure none
  | .ok (.bool value) => pure (some value)
  | .ok _ => hSchemaError ctx s!"field '{key}' must be a boolean or null when present"

private def hOptionalArray
    (ctx : String) (j : Json) (key : String) : Except String (Option (Array Json)) := do
  hEnsureObject ctx j
  match j.getObjVal? key with
  | .error _ | .ok .null => pure none
  | .ok (.arr values) => pure (some values)
  | .ok _ => hSchemaError ctx s!"field '{key}' must be an array or null when present"

private def hRequireArray
    (ctx : String) (j : Json) (key : String) : Except String (Array Json) := do
  match ← hRequireField ctx j key with
  | .arr values => pure values
  | _ => hSchemaError ctx s!"field '{key}' must be an array"

/-- Empty or whitespace-only (matches JS `!s.trim()`). -/
private def blank (s : String) : Bool := s.all Char.isWhitespace

/-! ## Tool-name canonicalization.

The four census-confirmed Hermes built-ins that semantically equal a
pi-canonical tool (`hermes.ts:60-65` == `Loom.Formats.Hermes.toolNameMap`).
Everything else (`patch`, `edit`, `browser_*`, `kanban_*`, …) stays `none` —
the raw name is always preserved on the `ToolName`. -/
private def lookupTool : String → Option Loom.CanonicalTool
  | "terminal"     => some .bash
  | "read_file"    => some .read
  | "write_file"   => some .write
  | "search_files" => some .grep
  | _              => none

/-! ## Argument decoding.

Mirrors `parseToolCallArguments` (`hermes.ts:140-150`): `arguments` is a
JSON-encoded string per the OpenAI tool-call wire format. Best effort — parse
it; if it is an object/array use it verbatim; otherwise (primitive, or parse
failure, or empty) fall back so the next harness still has the bytes. -/
private def parseArgs (s : String) : Json × Bool :=
  if s.isEmpty then (Json.mkObj [], false)
  else match Json.parse s with
    | .ok j =>
      match j with
      | .obj _ | .arr _ => (j, false)
      | _ => (Json.mkObj [("_raw", Json.str s)], true)
    | .error _ => (Json.mkObj [("_raw", Json.str s)], true)

/-! ## `tool_calls[]` → `AssistantBlock.toolCall`s.

Pure helper (its own `Id.run`) so the outer fold never nests mutation. Returns
the toolCall blocks, the `callId → (entryIdx, blockIdx)` records used to
resolve tool results positionally, and any `toolNameMapped` notes. `startBlock`
is the number of blocks already emitted (reasoning/text) so block indices —
and the `tc_<msg>_<block>` id fallback (`hermes.ts:262`) — line up. -/
private structure HermesCallOccurrence where
  rawId : Option String
  name   : String
  entry  : Nat
  block  : Nat

private def processToolCalls (msgIdx entryIdx startBlock : Nat) (tcs : Array Json) :
    Except String (List AssistantBlock × List HermesCallOccurrence × List ImportNote) := do
  let mut blocks : List AssistantBlock := []
  let mut calls  : List HermesCallOccurrence := []
  let mut notes  : List ImportNote := []
  let mut bi := startBlock
  for (tc, toolIdx) in tcs.toList.zipIdx do
    let ctx := s!"messages[{msgIdx}].tool_calls[{toolIdx}]"
    hEnsureObject ctx tc
    let callKind ← hOptionalNonemptyString ctx tc "type"
    match callKind with
    | some kind =>
        if kind != "function" then
          blocks := blocks ++ [.unmodeled s!"hermes-tool-call:{kind}" tc]
          notes := notes ++ [
            { kind := (.other "hermes-unmodeled-tool-call"),
              loc := some ctx,
              detail := s!"preserved unknown Hermes tool-call type '{kind}' verbatim" }]
          bi := bi + 1
          continue
        else pure ()
    | none => pure ()
    let fn ← match ← hRequireField ctx tc "function" with
      | value@(.obj _) => pure value
      | _ => hSchemaError ctx "field 'function' must be an object"
    let rawName ← hRequireNonemptyString (ctx ++ ".function") fn "name"
    let rawArgs ← hRequireString (ctx ++ ".function") fn "arguments"
    let (args, argsWrapped) := parseArgs rawArgs
    let id ← hOptionalNonemptyString ctx tc "id"
    let callId ← hOptionalNonemptyString ctx tc "call_id"
    if id.isSome && callId.isSome && id != callId then
      hSchemaError ctx "fields 'id' and 'call_id' disagree"
    else pure ()
    let rawId := id <|> callId
    let canonical := lookupTool rawName
    blocks := blocks ++ [AssistantBlock.toolCall
      { raw := rawName, canonical := canonical } args rawId]
    calls := calls ++ [{ rawId, name := rawName, entry := entryIdx, block := bi }]
    if argsWrapped then
      notes := notes ++ [
        { kind := (.other "hermes-raw-tool-arguments"),
          loc := some (ctx ++ ".function.arguments"),
          detail := "tool arguments were not a JSON object/array; exact string retained under _raw and in message provenance" }]
    else pure ()
    if rawId.isNone then
      notes := notes ++ [
        { kind := (.other "hermes-missing-tool-id"),
          loc := some ctx,
          detail := "tool call has no id/call_id; retained with rawId = none for occurrence-safe anonymous linkage" }]
    else pure ()
    match canonical with
    | some _ => notes := notes ++ [
        { kind := .toolNameMapped,
          loc := some ctx,
          detail := s!"tool name '{rawName}' mapped to a CanonicalTool (raw preserved)" }]
    | none => pure ()
    bi := bi + 1
  return (blocks, calls, notes)

/-- One Hermes entry: linear `parent`, no thread/time, hermes-scoped origin.
Built outside `do` so the multi-line record literal is unconstrained. -/
private def mkEntry (parent : Option Nat) (src : String) (raw : Json)
    (payload : Loom.Payload) : Loom.Entry :=
  { parent := parent, thread := 0, time := Loom.Time.absent, payload := payload,
    origin := {
      format := .hermes,
      sourceRef := src,
      extras := some (Json.mkObj [("hermesRaw", raw)]) } }

/-! ## Fold `messages[]` into entries.

Linear thread: each pushed entry's `parent` is the immediately preceding pushed
entry (skipped messages leave no gap, matching `hermes.ts`'s `pushEntry`
advancing `parentId` only on emit). -/
private def buildEntries (msgs : List Json) :
    Except String (Array Loom.Entry × List Loom.ImportNote) := do
  let mut entries : Array Loom.Entry := #[]
  let mut calls : List HermesCallOccurrence := []
  let mut resolvedCallSites : List (Nat × Nat) := []
  let mut notes   : List Loom.ImportNote := []
  for mi in msgs.zipIdx do
    let (m, i) := mi
    let src := s!"messages[{i}]"
    hEnsureObject src m
    let parent : Option Nat := if entries.size == 0 then none else some (entries.size - 1)
    let role ← hRequireNonemptyString src m "role"
    if role == "user" then
      let txt ← hRequireString src m "content"
      entries := entries.push (mkEntry parent src m
        (Loom.Payload.userMsg [Loom.UserBlock.text txt]))
    else if role == "assistant" then
      let entryIdx := entries.size
      let rc ← hOptionalString src m "reasoning_content"
      let r ← hOptionalString src m "reasoning"
      -- prefer non-empty reasoning_content, else reasoning, else "" (hermes.ts:244-246)
      let reasoning := match rc with
        | some s => if blank s then r.getD "" else s
        | none   => r.getD ""
      let mut pre : List Loom.AssistantBlock := []
      if !blank reasoning then
        pre := pre ++ [Loom.AssistantBlock.thinking reasoning none]
      match ← hOptionalString src m "content" with
      | some c => if !c.isEmpty then pre := pre ++ [Loom.AssistantBlock.text c]   -- length>0, untrimmed (hermes.ts:252)
      | none   => pure ()
      let tcs := (← hOptionalArray src m "tool_calls").getD #[]
      let (tcBlocks, newCalls, tcNotes) ← processToolCalls i entryIdx pre.length tcs
      let blocks := pre ++ tcBlocks
      if blocks.isEmpty then
        entries := entries.push (mkEntry parent src m
          (Loom.Payload.assistantMsg [.unmodeled "hermes-empty-assistant" m]))
        notes := notes ++ [
          { kind := (.other "hermes-empty-assistant"),
            loc := some src,
            detail := "preserved assistant message with no modeled content as exact unmodeled data" }]
      else
        calls := calls ++ newCalls
        notes := notes ++ tcNotes
        entries := entries.push (mkEntry parent src m (Loom.Payload.assistantMsg blocks))
    else if role == "tool" then
      let txt ← hRequireString src m "content"
      let tcid ← hOptionalNonemptyString src m "tool_call_id"
      let resultName ← hOptionalNonemptyString src m "name"
      let idCandidates : List HermesCallOccurrence := match tcid with
        | some id => calls.filter (fun call => call.rawId == some id)
        | none => []
      let candidates := idCandidates.filter (fun call =>
        match resultName with
        | some name => call.name == name
        | none => true)
      if resultName.isSome && !idCandidates.isEmpty && candidates.isEmpty then
        hSchemaError src
          s!"tool result name '{resultName.getD ""}' disagrees with every matching call"
      else pure ()
      let unmatched := candidates.filter (fun call =>
        !resolvedCallSites.contains (call.entry, call.block))
      let candidate := if candidates.length == 1 then candidates.head?
        else if unmatched.length == 1 then unmatched.head? else none
      let callRef : Loom.CallRef :=
        match candidate with
        | some call => Loom.CallRef.resolved call.entry call.block
        | none => Loom.CallRef.unresolved tcid
            (if tcid.isNone then
              "Hermes tool result has no tool_call_id; name/order alone cannot prove linkage"
            else if unmatched.length > 1 then
              "multiple unmatched Hermes tool_call occurrences share this id/name"
            else if !candidates.isEmpty then
              "every matching Hermes tool_call occurrence already has a result"
            else
              "no matching prior Hermes tool_call occurrence with this id")
      if candidate.isSome then
        match candidate with
        | some call => resolvedCallSites := resolvedCallSites ++ [(call.entry, call.block)]
        | none => pure ()
      else
        notes := notes ++ [
          { kind := (.other "hermes-unresolved-tool-result"),
            loc := some (src ++ ".tool_call_id"),
            detail := "preserved tool result with no matching prior call occurrence" }]
      if unmatched.length > 1 then
        notes := notes ++ [
          { kind := (.other "hermes-ambiguous-tool-result"),
            loc := some (src ++ ".tool_call_id"),
            detail := "duplicate Hermes tool-call id/name is ambiguous; result retained unresolved" }]
      else pure ()
      if candidate.isNone && !candidates.isEmpty && unmatched.isEmpty then
        notes := notes ++ [
          { kind := (.other "hermes-duplicate-tool-result"),
            loc := some (src ++ ".tool_call_id"),
            detail := "all matching calls already have results; additional result retained unresolved" }]
      else pure ()
      let snakeError ← hOptionalBool src m "is_error"
      let camelError ← hOptionalBool src m "isError"
      if snakeError.isSome && camelError.isSome && snakeError != camelError then
        hSchemaError src "fields 'is_error' and 'isError' disagree"
      else pure ()
      let error := match snakeError <|> camelError with
        | some value => Loom.ErrorSignal.native value
        | none => Loom.ErrorSignal.unrecorded
      let trBlock := Loom.EnvBlock.toolResult callRef [Loom.UserBlock.text txt] error
      entries := entries.push (mkEntry parent src m (Loom.Payload.envMsg [trBlock]))
      if snakeError.isNone && camelError.isNone then
        notes := notes ++ [
          { kind := (.other "errorUnrecorded"),
            loc := some src,
            detail := "Hermes result has no native error field; ErrorSignal.unrecorded, not native false" }]
      else pure ()
    else
      entries := entries.push (mkEntry parent src m
        (Loom.Payload.event (.custom "hermes-unmodeled-message" m)))
      notes := notes ++ [
        { kind := (.other "hermes-unmodeled-role"),
          loc := some src,
          detail := s!"preserved unknown Hermes role '{role}' as non-conversation event" }]
  return (entries, notes)

/-! ## Session-level extras (the `hermesExtras` pattern, `hermes.ts:182-188`).

Hermes-specific bits with no first-class pi/Loom shape, kept verbatim on the
transcript `Origin.extras` for same-format round-trip / cross-reference. -/
private def hermesExtrasOf (session : Json) : Json :=
  Json.mkObj [("hermesRaw", session)]

/-- Assemble the transcript (outside `do`; multi-line record literal is fine here).
`env.cwd` stays `none` — Hermes is a host-installed CLI with no cwd concept, and
`EnvInfo.cwd` is never fabricated (Core.lean). `activeLeaf` is the linear tip. -/
private def mkTranscript (session : Json) (entries : Array Loom.Entry)
    (model sessionId instructions : Option String)
    (notes : List Loom.ImportNote) : Loom.Transcript :=
  { threads     := #[({ kind := Loom.ThreadKind.main } : Loom.Thread)],
    entries     := entries,
    env         := { cwd := none, model, instructions, sessionId },
    activeLeaf  := if entries.size == 0 then none else some (entries.size - 1),
    importNotes := notes,
    origin      := { format := Loom.Format.hermes, sourceRef := "importHermes",
                     rawId := sessionId, extras := some (hermesExtrasOf session) } }

/-- Parse an entire Hermes session (one JSON object) into the Loom IR. -/
def importHermes (text : String) : Except String Loom.Transcript := do
  let session ← Json.parse text
  hEnsureObject "session" session
  let msgs ← hRequireArray "session" session "messages"
  let model ← hOptionalNonemptyString "session" session "model"
  let sessionId ← hOptionalNonemptyString "session" session "session_id"
  let instructions ← hOptionalString "session" session "system_prompt"
  let _ ← hOptionalArray "session" session "tools"
  match session.getObjVal? "message_count" with
  | .error _ => pure ()
  | .ok value =>
      match Json.getNat? value with
      | .ok count =>
          if count != msgs.size then
            hSchemaError "session" s!"message_count is {count}, but messages has {msgs.size} records"
          else pure ()
      | .error _ => hSchemaError "session" "field 'message_count' must be a natural number"
  let (entries, entryNotes) ← buildEntries msgs.toList
  let timeNote : Loom.ImportNote := { kind := (.other "timeAbsent"), detail := "Hermes has no per-message timestamps; first cut uses Time.absent (not interpolated, cf hermes.ts:210-212)" }
  pure (mkTranscript session entries model sessionId instructions (timeNote :: entryNotes))

/-! ## Actuator: the only IO. -/

/-- Read a Hermes session file from disk into the IR. -/
def importHermesFile (path : System.FilePath) : IO (Except String Loom.Transcript) := do
  let text ← IO.FS.readFile path
  pure (importHermes text)

/-! ## Fixture (structure only — no real conversation content).

A single Hermes session object: a user message, an assistant message with a
mapped tool_call (`terminal` → bash, arguments a JSON-encoded string), and a
tool result referencing that call. Hermes is not JSONL, so the fixture is an
in-file constant, NOT a `parity/fixtures/*.jsonl` entry. -/
def hermesFixture : String := "{
  \"session_id\": \"20260504_201140_ea41df\",
  \"model\": \"deepseek-chat\",
  \"base_url\": \"https://api.deepseek.com/v1\",
  \"platform\": \"cli\",
  \"session_start\": \"2026-05-04T20:11:40.194826\",
  \"last_updated\": \"2026-05-04T20:11:55.234422\",
  \"system_prompt\": \"You are Hermes, a helpful CLI agent.\",
  \"tools\": [],
  \"message_count\": 3,
  \"messages\": [
    { \"role\": \"user\", \"content\": \"List the files here.\" },
    { \"role\": \"assistant\", \"content\": \"Sure, running that now.\",
      \"reasoning\": \"\", \"reasoning_content\": \"\", \"finish_reason\": \"tool_calls\",
      \"tool_calls\": [
        { \"id\": \"call_0\", \"call_id\": \"call_0\", \"type\": \"function\",
          \"function\": { \"name\": \"terminal\", \"arguments\": \"{\\\"command\\\":\\\"ls -la\\\"}\" } }
      ] },
    { \"role\": \"tool\", \"tool_call_id\": \"call_0\", \"name\": \"terminal\",
      \"content\": \"total 0 drwxr-xr-x README.md\" }
  ]
}"

/-! ## Checks -/

-- entries>0 and the IR is well-formed (0 structural violations).
example :
    (match importHermes hermesFixture with
     | .ok t => t.entries.size == 3 && (Loom.violations t).isEmpty
     | .error _ => false) = true := by native_decide

/-- Cross-parity golden: TS `convert-to-pi hermes` → pi JSONL → parseSession →
`normalize` (positional projection), captured 2026-07-07. The 3-class divergence
the fanout found (cwd, tool-name, toolResult) is resolved at the projection layer,
so this now holds. -/
def hermesCase1 : CrossParityCase := {
  name := "hermes",
  input := hermesFixture,
  tsGolden := "session\n0|-|user|text:List the files here.\n1|0|assistant|text:Sure, running that now.;call\n2|1|toolResult|text:total 0 drwxr-xr-x README.md"
}

/-- THE DECIDE-PIN (cross-parity, RC1): importHermes agrees with TS `convert-to-pi hermes`. -/
example : crossParityOkWith importHermes hermesCase1 = true := by native_decide

/-! ## Adversarial importer witnesses -/

private def hermesRejects (source : String) : Bool :=
  match importHermes source with
  | .error _ => true
  | .ok _ => false

private def hermesConfigFixture : String :=
  "{" ++
  "\"session_id\":\"cfg\",\"model\":\"m\"," ++
  "\"system_prompt\":\"policy\",\"tools\":[{\"name\":\"terminal\",\"future\":1}]," ++
  "\"futureRoot\":{\"kept\":true},\"messages\":[" ++
    "{\"role\":\"user\",\"content\":\"hello\",\"futureMessage\":[1,2]}" ++
  "]}"

private def hermesConfigAndRawPreserved : Bool :=
  match importHermes hermesConfigFixture, Json.parse hermesConfigFixture with
  | .ok t, .ok source =>
      t.env.model == some "m" &&
      t.env.instructions == some "policy" &&
      t.env.sessionId == some "cfg" &&
      t.origin.extras.bind (fun extras => oobj extras "hermesRaw") == some source &&
      match t.entries[0]? with
      | some entry =>
          entry.origin.extras.bind (fun extras => oobj extras "hermesRaw") ==
            (source.getObjVal? "messages").toOption.bind (fun messages =>
              (Json.getArr? messages).toOption.bind (fun values => values[0]?))
      | none => false
  | _, _ => false

example : hermesConfigAndRawPreserved = true := by native_decide

private def hermesUnknownRoleFixture : String :=
  "{\"messages\":[{\"role\":\"future-control\",\"payload\":{\"x\":1}}]}"

private def hermesUnknownRoleIsNotConversation : Bool :=
  match importHermes hermesUnknownRoleFixture with
  | .ok t =>
      match t.entries.toList with
      | [{ payload := .event (.custom "hermes-unmodeled-message" raw), .. }] =>
          ostr raw "role" == some "future-control" &&
          t.importNotes.any (fun note =>
            note.kind == .other "hermes-unmodeled-role")
      | _ => false
  | .error _ => false

example : hermesUnknownRoleIsNotConversation = true := by native_decide

private def hermesMalformedKnownRecords : List String := [
  "{\"messages\":{}}",
  "{\"messages\":[{\"role\":\"user\",\"content\":7}]}",
  "{\"messages\":[{\"role\":\"assistant\",\"tool_calls\":[{\"type\":\"function\",\"function\":{\"arguments\":\"{}\"}}]}]}",
  "{\"messages\":[{\"role\":\"assistant\",\"tool_calls\":[{\"id\":\"a\",\"call_id\":\"b\",\"type\":\"function\",\"function\":{\"name\":\"terminal\",\"arguments\":\"{}\"}}]}]}",
  "{\"messages\":[{\"role\":\"tool\",\"content\":{\"bad\":true}}]}",
  "{\"message_count\":2,\"messages\":[{\"role\":\"user\",\"content\":\"one\"}]}",
  "{\"messages\":[" ++
    "{\"role\":\"assistant\",\"tool_calls\":[{\"id\":\"same\",\"type\":\"function\",\"function\":{\"name\":\"x\",\"arguments\":\"{}\"}}]}," ++
    "{\"role\":\"tool\",\"tool_call_id\":\"same\",\"name\":\"y\",\"content\":\"bad\"}]}"
]

example : hermesMalformedKnownRecords.all hermesRejects = true := by native_decide

private def hermesOccurrenceFixture : String :=
  "{\"messages\":[" ++
    "{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[" ++
      "{\"id\":\"same\",\"type\":\"function\",\"function\":{\"name\":\"terminal\",\"arguments\":\"{\\\"n\\\":1}\"}}," ++
      "{\"id\":\"same\",\"type\":\"function\",\"function\":{\"name\":\"terminal\",\"arguments\":\"{\\\"n\\\":2}\"}}" ++
    "]}," ++
    "{\"role\":\"tool\",\"tool_call_id\":\"same\",\"name\":\"terminal\",\"content\":\"first\",\"is_error\":false}," ++
    "{\"role\":\"tool\",\"tool_call_id\":\"same\",\"name\":\"terminal\",\"content\":\"second\",\"isError\":true}" ++
  "]}"

private def hermesDuplicateIdsRemainAmbiguous : Bool :=
  match importHermes hermesOccurrenceFixture with
  | .ok t =>
      match t.entries.toList with
      | [{ payload := .assistantMsg [
              .toolCall _ _ (some "same"), .toolCall _ _ (some "same")], .. },
          { payload := .envMsg [
              .toolResult (.unresolved (some "same") _) [.text "first"]
                (.native false)], .. },
          { payload := .envMsg [
              .toolResult (.unresolved (some "same") _) [.text "second"]
                (.native true)], .. }] =>
          t.importNotes.any (fun note =>
            note.kind == .other "hermes-ambiguous-tool-result")
      | _ => false
  | .error _ => false

example : hermesDuplicateIdsRemainAmbiguous = true := by native_decide

private def hermesDuplicateIdNameFixture : String :=
  "{\"messages\":[" ++
    "{\"role\":\"assistant\",\"tool_calls\":[" ++
      "{\"id\":\"same\",\"type\":\"function\",\"function\":{\"name\":\"x\",\"arguments\":\"{}\"}}," ++
      "{\"id\":\"same\",\"type\":\"function\",\"function\":{\"name\":\"y\",\"arguments\":\"{}\"}}]}," ++
    "{\"role\":\"tool\",\"tool_call_id\":\"same\",\"name\":\"y\",\"content\":\"y-result\"}," ++
    "{\"role\":\"tool\",\"tool_call_id\":\"same\",\"name\":\"x\",\"content\":\"x-result\"}]}"

example :
    (match importHermes hermesDuplicateIdNameFixture with
     | .ok transcript =>
         match transcript.entries[1]?, transcript.entries[2]? with
         | some yResult, some xResult =>
             match yResult.payload, xResult.payload with
             | .envMsg [.toolResult (.resolved 0 1) _ _],
               .envMsg [.toolResult (.resolved 0 0) _ _] => true
             | _, _ => false
         | _, _ => false
     | .error _ => false) = true := by native_decide

private def hermesAnonymousFixture : String :=
  "{\"messages\":[" ++
    "{\"role\":\"assistant\",\"tool_calls\":[" ++
      "{\"type\":\"function\",\"function\":{\"name\":\"terminal\",\"arguments\":\"{}\"}}," ++
      "{\"type\":\"function\",\"function\":{\"name\":\"terminal\",\"arguments\":\"{}\"}}" ++
    "]}," ++
    "{\"role\":\"tool\",\"name\":\"terminal\",\"content\":\"one\"}," ++
    "{\"role\":\"tool\",\"name\":\"terminal\",\"content\":\"two\"}" ++
  "]}"

example :
    (match importHermes hermesAnonymousFixture with
     | .ok t =>
         match t.entries.toList with
         | [{ payload := .assistantMsg [
                .toolCall _ _ none, .toolCall _ _ none], .. },
            { payload := .envMsg [
                .toolResult (.unresolved none _) _ .unrecorded], .. },
            { payload := .envMsg [
                .toolResult (.unresolved none _) _ .unrecorded], .. }] => true
         | _ => false
     | .error _ => false) = true := by native_decide

private def hermesRepeatedResultFixture : String :=
  "{\"messages\":[" ++
    "{\"role\":\"assistant\",\"tool_calls\":[{" ++
      "\"id\":\"unique\",\"type\":\"function\",\"function\":{" ++
        "\"name\":\"terminal\",\"arguments\":\"{}\"}}]}," ++
    "{\"role\":\"tool\",\"tool_call_id\":\"unique\",\"content\":\"one\"}," ++
    "{\"role\":\"tool\",\"tool_call_id\":\"unique\",\"content\":\"two\"}] }"

example :
    (match importHermes hermesRepeatedResultFixture with
     | .ok t =>
         match t.entries[1]?, t.entries[2]? with
         | some first, some second =>
             match first.payload, second.payload with
             | .envMsg [.toolResult (.resolved 0 0) [.text "one"] _],
               .envMsg [.toolResult (.resolved 0 0) [.text "two"] _] => true
             | _, _ => false
         | _, _ => false
     | .error _ => false) = true := by native_decide

private def hermesUnknownToolAndRawArgsFixture : String :=
  "{\"messages\":[{\"role\":\"assistant\",\"future\":9,\"tool_calls\":[" ++
    "{\"type\":\"future_call\",\"opaque\":{\"k\":1}}," ++
    "{\"type\":\"function\",\"function\":{\"name\":\"x\",\"arguments\":\"not-json\"}}" ++
  "]}]}"

example :
    (match importHermes hermesUnknownToolAndRawArgsFixture with
     | .ok t =>
         match t.entries.toList with
         | [{ payload := .assistantMsg [
                .unmodeled "hermes-tool-call:future_call" raw,
                .toolCall { raw := "x", .. } args none],
              origin := origin, .. }] =>
             ostr raw "type" == some "future_call" &&
             ostr args "_raw" == some "not-json" &&
             (origin.extras.bind (fun extras => oobj extras "hermesRaw")).isSome
         | _ => false
     | .error _ => false) = true := by native_decide

end LoomConvert
