import LoomConvert.ClaudeCode

/-!
# LoomConvert.ClaudeSubagents — sub-agent stitching (D16)

A capability the TS toolchain does **not** have. `claudeAdapter.ts` (and Loom's
own `importClaudeCode`) reconstruct only the newest non-sidechain **main** thread
and DROP every sub-agent transcript. Claude externalizes each sub-agent to a
sidecar under `<session>/subagents/agent-<id>.jsonl`, with a sibling
`agent-<id>.meta.json` carrying `{agentType, description, toolUseId, spawnDepth}`.
The census (`Loom.Formats.ClaudeCode`, claim L14) confirmed the sidecar's
`toolUseId` matches the spawning `Agent`/`Task` tool_use `id` in the parent
session (18/18 in session `3e18e37d`). This module walks that sidecar subtree and
**stitches** each child in as a first-class `Thread`, anchored to the tool call
that spawned it — realizing the `ThreadKind.sidechain (anchor)` the core IR was
designed for (`Loom.Core`, structural commitment 3).

## The stitch (pure core: `stitchSubagents`)

Each child is itself claude-shaped JSONL, so it is imported by the SAME
`importClaudeCode` (its own leaf-walk, its own thread 0 chained `parent := i-1`).
Stitching then re-bases that self-contained transcript into the combined one:

* a NEW `Thread` is appended per child. Its `kind` is
  `ThreadKind.sidechain (CallRef.resolved e b)` when the meta's `toolUseId`
  resolves to a main-thread `AssistantBlock.toolCall` whose `rawId` matches
  (`findAnchor`) — a **positional** ref into the main thread, exactly the Loom
  discipline (link by index, raw id rides along in `Origin`). No match →
  `ThreadKind.detached "toolUseId=<x> unmatched"`: representable, flagged, honest.
* the child's entries are appended to `Transcript.entries` at `offset :=
  entries.size`, each re-based by `rebaseEntry`:
  - `thread := <new thread index>` (tags membership);
  - `parent := parent.map (· + offset)` — the child chains WITHIN its own thread
    (its root keeps `parent := none`); the cross-thread link is carried ONLY by
    the `sidechain` anchor, never by an entry parent;
  - any `EnvBlock.toolResult` `CallRef.resolved e b` is shifted to `(e+offset)` so
    a child's tool results keep pointing at the child's OWN tool calls, not into
    the main region they now sit after.

## Well-formedness (verified, not assumed)

The result stays in normal form (`Loom.WellFormed`): main entries are untouched
and occupy `[0, mainSize)`; every child parent/CallRef is `< own index` before
the shift and both sides shift by the same `offset`, so the order is preserved;
`thread` indices are all `< threads.size`; the anchor points into the earlier
main region and — being on the `Thread`, not in a payload — is not even a
violation surface. The only residual violation class, an orphan `tool_result`
(`unresolvedCallRef`), is inherited verbatim from `importClaudeCode`, so a clean
main+children import stitches to a clean combined IR.

## Scope / honesty

Anchors resolve against the MAIN thread only (per L14): a `spawnDepth ≥ 2` nested
sub-agent, whose spawning `Agent` call lives inside a SIBLING sidecar rather than
the main session, will fall to `detached`. Also, `#children` need not equal
`#main-thread dispatch calls`: a child whose `Agent` call sits on an
edit-abandoned branch (which the leaf-walk excludes) or was auto-spawned outside
the reconstructed active path resolves to `detached` — the census's "#children ≠
#dispatch-calls" caveat, made explicit rather than silently dropped.

VERIFY: no TS oracle exists for the stitched result (TS has no such capability),
so this is verified by well-formedness + structure, never cross-parity.
-/

namespace LoomConvert
open Loom
open Lean (Json)

/-! ## Anchor resolution (pure) -/

/-- Locate every positional `CallRef` whose raw id equals `toolUseId`, in document
order. Retaining the whole match set prevents duplicate native ids from being
silently attached to the first call. -/
def findAnchors (main : Transcript) (toolUseId : String) : List (Nat × Nat) :=
  main.entries.toList.zipIdx.flatMap (fun (e, ei) =>
    match e.payload with
    | Payload.assistantMsg blocks =>
        blocks.zipIdx.filterMap (fun (b, bi) =>
          match b with
          | AssistantBlock.toolCall _ _ (some rid) =>
              if rid == toolUseId then some ((ei, bi) : Nat × Nat) else none
          | _ => none)
    | _ => [])

/-- Resolve a native sidecar key only when it identifies one call. Duplicate raw
ids are not enough evidence for an anchor and are left detached by the stitcher. -/
def findAnchor (main : Transcript) (toolUseId : String) : Option (Nat × Nat) :=
  match findAnchors main toolUseId with
  | [anchor] => some anchor
  | _ => none

/-! ## Re-basing a child transcript into the combined entry array -/

/-- Shift a positional `CallRef` by `offset` (resolved refs only; unresolved
orphans carry no index to move). -/
private def shiftCallRef (offset : Nat) : CallRef → CallRef
  | CallRef.resolved e b => CallRef.resolved (e + offset) b
  | other                => other

/-- Shift the `CallRef` inside a tool-result env block so a child's results keep
pointing at the child's own tool calls after the child is appended at `offset`. -/
private def shiftEnvBlock (offset : Nat) : EnvBlock → EnvBlock
  | EnvBlock.toolResult call content err => EnvBlock.toolResult (shiftCallRef offset call) content err
  | other                                => other

/-- Re-base one child entry for insertion into the combined transcript at
`offset`, as thread `threadIdx`: shift its intra-thread parent and its tool-result
CallRefs by `offset`, tag its thread, and stamp the sidecar's `agentId` into the
`Origin.sourceRef` (provenance: which sub-agent file this entry came from). -/
private def rebaseEntry (offset threadIdx : Nat) (agentId : String) (e : Entry) : Entry :=
  { e with
    parent  := e.parent.map (· + offset)
    thread  := threadIdx
    payload := match e.payload with
      | Payload.envMsg blocks => Payload.envMsg (blocks.map (shiftEnvBlock offset))
      | p                     => p
    origin  := { e.origin with sourceRef := s!"subagent:{agentId}:{e.origin.sourceRef}" } }

private def qualifyChildNote (agentId : String) (note : ImportNote) : ImportNote :=
  { note with loc := some (match note.loc with
      | some loc => s!"subagent:{agentId}:{loc}"
      | none => s!"subagent:{agentId}") }

/-! ## The stitch -/

/-- One imported sub-agent sidecar: the `agentId` (from `agent-<id>.jsonl`), the
meta's `toolUseId` (the spawning-call anchor key, `none` if metadata is absent),
and the child's own imported `Transcript`. Malformed metadata is refused before
this value is constructed. -/
structure SubagentChild where
  agentId    : String
  toolUseId  : Option String
  transcript : Transcript
  /-- Converter-owned sidecars carry the exact source thread disposition. Real
  vendor sidecars leave this absent and use the native anchor inference above. -/
  threadKindOverride : Option ThreadKind := none
  /-- Outer `some` means converter metadata explicitly recorded the label;
  inner `none` preserves an absent label rather than fabricating the file id. -/
  threadLabelOverride : Option (Option String) := none
  /-- This child contained the combined transcript's active leaf. -/
  globalActive : Bool := false

/-- Assemble imported sub-agent children into the main transcript (pure core).
Callers handling external metadata use `stitchSubagentsChecked`. Each
child becomes a new `Thread` (`sidechain` if its `toolUseId` anchors to a
main-thread tool call, else `detached`) and its entries are appended, re-based by
`rebaseEntry`. Main entries/env remain unchanged; an explicitly global-active
child replaces the main active leaf, and child import judgments remain qualified
by sidecar id. -/
def stitchSubagents (main : Transcript) (children : List SubagentChild) : Transcript :=
  let init : Array Thread × Array Entry × List ImportNote × Option Nat :=
    (main.threads, main.entries, main.importNotes, none)
  let (threads, entries, notes, childActiveLeaf) :=
    children.foldl (fun
        (acc : Array Thread × Array Entry × List ImportNote × Option Nat)
        (c : SubagentChild) =>
      let (ths, ents, nts, active) := acc
      let offset    := ents.size
      let threadIdx := ths.size
      let inferredKind : ThreadKind :=
        match c.toolUseId with
        | none => ThreadKind.detached "no meta.json toolUseId"
        | some tid =>
            match findAnchors main tid with
            | [(ae, ab)] => ThreadKind.sidechain (CallRef.resolved ae ab)
            | [] => ThreadKind.detached s!"toolUseId={tid} unmatched"
            | many => ThreadKind.detached
                s!"toolUseId={tid} ambiguous ({many.length} matching calls)"
      let kind := c.threadKindOverride.getD inferredKind
      let label := c.threadLabelOverride.getD (some c.agentId)
      let ths'  := ths.push { kind := kind, label := label }
      let ents' := ents ++ c.transcript.entries.map (rebaseEntry offset threadIdx c.agentId)
      let anchorWord : String := match kind with | .sidechain _ => "anchored" | _ => "detached"
      let note : ImportNote :=
        { kind := AssumptionKind.other "subagentStitched"
          loc := some c.agentId
          detail := s!"{c.transcript.entries.size} entries; {anchorWord}" }
      let active' := if c.globalActive then
          c.transcript.activeLeaf.map (fun leaf => leaf + offset)
        else active
      let childNotes := c.transcript.importNotes.map (qualifyChildNote c.agentId)
      (ths', ents', nts ++ childNotes ++ [note], active')) init
  { main with
    threads := threads
    entries := entries
    importNotes := notes
    activeLeaf := match childActiveLeaf with
      | some leaf => some leaf
      | none => main.activeLeaf }

/-- Validate an exact converter-owned sidechain anchor against the imported main
thread. The positional anchor and the redundant native tool id must agree when
both are present. -/
private def validateExactSidechainAnchor (main : Transcript) (agentId : String)
    (toolUseId : Option String) (refEntry refBlock : Nat) : Except String Unit := do
  let mainIdx ←
    match main.threads.toList.zipIdx.filterMap (fun (thread, index) =>
        if thread.kind == ThreadKind.main then some index else none) with
    | [index] => pure index
    | indexes => .error s!"{agentId}: exact sidecar anchor requires one main thread; found {indexes.length}"
  let entry ← match main.entries[refEntry]? with
    | some value => pure value
    | none => .error s!"{agentId}: exact sidecar anchor entry {refEntry} is out of range"
  if entry.thread != mainIdx then
    .error s!"{agentId}: exact sidecar anchor entry {refEntry} belongs to thread {entry.thread}, not main thread {mainIdx}"
  else
    match entry.payload with
    | .assistantMsg blocks =>
        match blocks[refBlock]? with
        | some (.toolCall _ _ rawId) =>
            match toolUseId with
            | none => pure ()
            | some expected =>
                match rawId with
                | some actual =>
                    if actual == expected then pure ()
                    else .error s!"{agentId}: exact sidecar anchor tool id '{actual}' does not match metadata toolUseId '{expected}'"
                | none => .error s!"{agentId}: exact sidecar anchor has no tool id but metadata names '{expected}'"
        | some _ => .error s!"{agentId}: exact sidecar anchor {refEntry}:{refBlock} is not a tool call"
        | none => .error s!"{agentId}: exact sidecar anchor block {refEntry}:{refBlock} is out of range"
    | _ => .error s!"{agentId}: exact sidecar anchor entry {refEntry} is not an assistant message"

private def validateSubagentChild (main : Transcript) (child : SubagentChild) : Except String Unit := do
  if child.globalActive && child.transcript.activeLeaf.isNone then
    .error s!"{child.agentId}: active sidecar has no active leaf"
  else
    match child.threadKindOverride with
    | none => pure ()
    | some .main => .error s!"{child.agentId}: converter sidecar cannot declare another main thread"
    | some (.sidechain (.unresolved _ note)) =>
        .error s!"{child.agentId}: converter sidecar cannot declare unresolved sidechain anchor '{note}'"
    | some (.sidechain (.resolved entry block)) =>
        validateExactSidechainAnchor main child.agentId child.toolUseId entry block
    | some (.detached _) =>
        if child.toolUseId.isSome then
          .error s!"{child.agentId}: detached converter sidecar cannot also declare toolUseId"
        else pure ()

/-- Release-facing stitch boundary. It rejects contradictory metadata, multiple
global-active claims, and every structural defect instead of returning an
apparently successful but unsafe combined transcript. -/
def stitchSubagentsChecked (main : Transcript) (children : List SubagentChild) :
    Except String Transcript := do
  let activeClaims := children.filter (fun child => child.globalActive)
  if activeClaims.length > 1 then
    .error s!"multiple subagent sidecars claim the combined active leaf: {String.intercalate ", " (activeClaims.map (fun child => child.agentId))}"
  else
    for child in children do
      validateSubagentChild main child
    let stitched := stitchSubagents main children
    let structural := Loom.violations stitched
    if structural.isEmpty then pure stitched
    else .error s!"stitched subagent transcript is structurally invalid ({structural.length} violation(s))"

/-! ## Reporting (structural only — never conversation content) -/

/-- Number of anchored sub-agent threads (`ThreadKind.sidechain`). -/
def sidechainThreadCount (t : Transcript) : Nat :=
  (t.threads.toList.filter (fun (th : Thread) =>
    match th.kind with | ThreadKind.sidechain _ => true | _ => false)).length

/-- Number of sub-agent threads whose anchor could not be resolved
(`ThreadKind.detached`). -/
def detachedThreadCount (t : Transcript) : Nat :=
  (t.threads.toList.filter (fun (th : Thread) =>
    match th.kind with | ThreadKind.detached _ => true | _ => false)).length

/-- Total sub-agent threads stitched (anchored + detached). -/
def subagentThreadCount (t : Transcript) : Nat :=
  sidechainThreadCount t + detachedThreadCount t

/-- Entries belonging to a given thread index. -/
def threadEntryCount (t : Transcript) (k : Nat) : Nat :=
  (t.entries.toList.filter (fun (e : Entry) => e.thread == k)).length

/-- A one-line structural summary (counts only, no content) for tests/logs. -/
def stitchReport (t : Transcript) : String :=
  s!"threads={t.threads.size} (main=1, subagents={subagentThreadCount t}: \
     anchored={sidechainThreadCount t}, detached={detachedThreadCount t}) \
     mainEntries={threadEntryCount t 0} totalEntries={t.entries.size} \
     violations={(Loom.violations t).length}"

/-! ## Actuator: the only IO. -/

structure SidecarChildMetadata where
  toolUseId : Option String := none
  threadKindOverride : Option ThreadKind := none
  threadLabelOverride : Option (Option String) := none
  globalActive : Bool := false

private def ensureMetaObject (ctx : String) : Json → Except String Unit
  | .obj _ => pure ()
  | _ => .error s!"{ctx}: expected object"

private def optionalMetaString (ctx : String) (j : Json) (key : String) :
    Except String (Option String) := do
  ensureMetaObject ctx j
  match j.getObjVal? key with
  | .error _ | .ok .null => pure none
  | .ok (.str value) => pure (some value)
  | .ok _ => .error s!"{ctx}.{key}: expected string or null"

private def metaHasField (j : Json) (key : String) : Bool :=
  match j.getObjVal? key with
  | .ok _ => true
  | .error _ => false

private def requiredMetaJson (ctx : String) (j : Json) (key : String) : Except String Json :=
  match j.getObjVal? key with
  | .ok value => .ok value
  | .error _ => .error s!"{ctx}: missing required field '{key}'"

private def requiredMetaString (ctx : String) (j : Json) (key : String) : Except String String := do
  match Json.getStr? (← requiredMetaJson ctx j key) with
  | .ok value => pure value
  | .error _ => .error s!"{ctx}.{key}: expected string"

private def requiredMetaNat (ctx : String) (j : Json) (key : String) : Except String Nat := do
  let value ← requiredMetaJson ctx j key
  match Json.getNat? value with
  | .ok number => pure number
  | .error _ =>
      match Json.getStr? value with
      | .ok text => match text.toNat? with
        | some number => pure number
        | none => .error s!"{ctx}.{key}: expected natural-number string"
      | .error _ => .error s!"{ctx}.{key}: expected natural number or string"

private def generatedChildMetadata (root : Json) : Except String (Option SidecarChildMetadata) := do
  ensureMetaObject "sidecar metadata" root
  let toolUseId ← optionalMetaString "sidecar metadata" root "toolUseId"
  let description ← optionalMetaString "sidecar metadata" root "description"
  match root.getObjVal? "_agentConvert" with
  | .error _ =>
      let label := match description with
        | some description => some (some description)
        | none => none
      pure (some {
        toolUseId := toolUseId
        threadLabelOverride := label })
  | .ok extension =>
      let ctx := "sidecar metadata._agentConvert"
      ensureMetaObject ctx extension
      let protocol ← requiredMetaString ctx extension "protocol"
      if protocol != "agent-convert.sidecar-child.v1" then
        .error s!"{ctx}: unsupported protocol '{protocol}'"
      else
        let labelValue ← requiredMetaJson ctx extension "label"
        let label ← match labelValue with
          | .null => pure none
          | value => match Json.getStr? value with
            | .ok text => pure (some text)
            | .error _ => .error s!"{ctx}.label: expected string or null"
        let kindLabel ← requiredMetaString ctx extension "threadKind"
        let kind ← match kindLabel with
          | "sidechain" =>
              if metaHasField extension "detachedReason" then
                .error s!"{ctx}: sidechain metadata cannot contain detachedReason"
              else pure (ThreadKind.sidechain (.resolved
                (← requiredMetaNat ctx extension "anchorEntry")
                (← requiredMetaNat ctx extension "anchorBlock")))
          | "detached" =>
              if metaHasField extension "anchorEntry" || metaHasField extension "anchorBlock" then
                .error s!"{ctx}: detached metadata cannot contain anchorEntry or anchorBlock"
              else if toolUseId.isSome then
                .error s!"{ctx}: detached metadata cannot contain toolUseId"
              else pure (ThreadKind.detached
                (← requiredMetaString ctx extension "detachedReason"))
          | other => .error s!"{ctx}: unsupported threadKind '{other}'"
        let activeValue ← requiredMetaJson ctx extension "globalActive"
        let active ← match Json.getBool? activeValue with
          | .ok value => pure value
          | .error _ => .error s!"{ctx}.globalActive: expected boolean"
        pure (some {
          toolUseId := toolUseId
          threadKindOverride := some kind
          threadLabelOverride := some label
          globalActive := active })

private def parseSidecarMetadataText (text : String) : Except String SidecarChildMetadata := do
  let root ← Json.parse text
  match ← generatedChildMetadata root with
  | some metadata => pure metadata
  | none => pure {}

private def metadataTextRejected (text : String) : Bool :=
  match parseSidecarMetadataText text with
  | .error _ => true
  | .ok _ => false

/-- Converter metadata is a strict discriminated record: exact anchors, detached
reasons, nullable labels, and the global-active claim all retain their types. -/
def converterSidecarMetadataExact : Bool :=
  let sidechain :=
    "{\"toolUseId\":\"toolu_AG1\",\"_agentConvert\":{\"protocol\":\"agent-convert.sidecar-child.v1\",\"label\":\"worker\",\"globalActive\":true,\"threadKind\":\"sidechain\",\"anchorEntry\":\"1\",\"anchorBlock\":2}}"
  let detached :=
    "{\"_agentConvert\":{\"protocol\":\"agent-convert.sidecar-child.v1\",\"label\":null,\"globalActive\":false,\"threadKind\":\"detached\",\"detachedReason\":\"source anchor absent\"}}"
  match parseSidecarMetadataText sidechain, parseSidecarMetadataText detached with
  | .ok side, .ok away =>
      side.toolUseId == some "toolu_AG1" &&
      decide (side.threadKindOverride = some (.sidechain (.resolved 1 2))) &&
      decide (side.threadLabelOverride = some (some "worker")) &&
      side.globalActive &&
      away.toolUseId.isNone &&
      decide (away.threadKindOverride = some (.detached "source anchor absent")) &&
      decide (away.threadLabelOverride = some none) &&
      !away.globalActive
  | _, _ => false

example : converterSidecarMetadataExact = true := by native_decide

/-- Every malformed or contradictory v1 shape is rejected rather than treated
as absent/native metadata. -/
def malformedConverterSidecarMetadataRejected : Bool :=
  [
    "[]",
    "{\"_agentConvert\":null}",
    "{\"_agentConvert\":{\"protocol\":\"wrong\",\"label\":null,\"globalActive\":false,\"threadKind\":\"detached\",\"detachedReason\":\"x\"}}",
    "{\"_agentConvert\":{\"protocol\":\"agent-convert.sidecar-child.v1\",\"globalActive\":false,\"threadKind\":\"detached\",\"detachedReason\":\"x\"}}",
    "{\"_agentConvert\":{\"protocol\":\"agent-convert.sidecar-child.v1\",\"label\":7,\"globalActive\":false,\"threadKind\":\"detached\",\"detachedReason\":\"x\"}}",
    "{\"_agentConvert\":{\"protocol\":\"agent-convert.sidecar-child.v1\",\"label\":null,\"globalActive\":false,\"threadKind\":\"sidechain\",\"anchorEntry\":\"1\"}}",
    "{\"_agentConvert\":{\"protocol\":\"agent-convert.sidecar-child.v1\",\"label\":null,\"globalActive\":false,\"threadKind\":\"detached\"}}",
    "{\"_agentConvert\":{\"protocol\":\"agent-convert.sidecar-child.v1\",\"label\":null,\"globalActive\":\"false\",\"threadKind\":\"detached\",\"detachedReason\":\"x\"}}",
    "{\"_agentConvert\":{\"protocol\":\"agent-convert.sidecar-child.v1\",\"label\":null,\"globalActive\":false,\"threadKind\":\"sidechain\",\"anchorEntry\":1,\"anchorBlock\":0,\"detachedReason\":\"x\"}}",
    "{\"_agentConvert\":{\"protocol\":\"agent-convert.sidecar-child.v1\",\"label\":null,\"globalActive\":false,\"threadKind\":\"detached\",\"detachedReason\":\"x\",\"anchorEntry\":1}}",
    "{\"toolUseId\":\"toolu_AG1\",\"_agentConvert\":{\"protocol\":\"agent-convert.sidecar-child.v1\",\"label\":null,\"globalActive\":false,\"threadKind\":\"detached\",\"detachedReason\":\"x\"}}",
    "{\"toolUseId\":9}"
  ].all metadataTextRejected

example : malformedConverterSidecarMetadataRejected = true := by native_decide

/-- Native Claude metadata and a missing/native Cursor metadata record retain the
legacy inference contract: no exact kind is invented, and absent fields stay
absent. -/
def nativeSidecarMetadataCompatible : Bool :=
  let missing : SidecarChildMetadata := {}
  match parseSidecarMetadataText
      "{\"agentType\":\"Explore\",\"description\":\"native worker\",\"toolUseId\":\"toolu_AG1\",\"spawnDepth\":\"1\"}" with
  | .ok native =>
      native.toolUseId == some "toolu_AG1" &&
      native.threadKindOverride.isNone &&
      decide (native.threadLabelOverride = some (some "native worker")) &&
      !native.globalActive &&
      missing.toolUseId.isNone && missing.threadKindOverride.isNone &&
      missing.threadLabelOverride.isNone && !missing.globalActive
  | .error _ => false

example : nativeSidecarMetadataCompatible = true := by native_decide

/-- Read native metadata plus the converter-owned exact thread extension. An
existing malformed file is an import error; treating it as absent would silently
change an anchor, detached reason, label, or active path. -/
def readSidecarChildMetadata (metaPath : System.FilePath) :
    IO (Except String SidecarChildMetadata) := do
  if ← metaPath.pathExists then
    match Json.parse (← IO.FS.readFile metaPath) with
    | .error error => pure (.error s!"{metaPath}: malformed JSON: {error}")
    | .ok root =>
        match generatedChildMetadata root with
        | .error error => pure (.error s!"{metaPath}: {error}")
        | .ok (some metadata) => pure (.ok metadata)
        | .ok none => pure (.ok {})
  else pure (.ok {})

/-- Import a Claude Code session AND stitch in its externalized sub-agents.

(1) import the main session (`importClaudeCode`); (2) locate the sibling
`<session-stem>/subagents/` dir and glob `agent-*.jsonl`; (3) import each child
(itself claude-shaped) and read its paired `agent-*.meta.json` for the
`toolUseId` and optional exact converter extension; (4) the checked stitch adds
each as a `sidechain`/`detached` thread with the child's entries appended.
Sessions with no `subagents/` dir return the main transcript unchanged
(identical to `importClaudeCode`). -/
def importClaudeSessionWithSubagents (sessionFile : System.FilePath) : IO (Except String Transcript) := do
  let mainText ← IO.FS.readFile sessionFile
  match importClaudeCode mainText with
  | .error e => pure (.error e)
  | .ok main => do
    -- Sibling `<session-stem>/subagents/` (drop the `.jsonl`, append the dir).
    let base := sessionFile.toString
    let stemPath := if base.endsWith ".jsonl" then (base.dropEnd 6).toString else base
    let subDir : System.FilePath := stemPath ++ "/subagents"
    if ← subDir.isDir then
      let dents ← subDir.readDir
      -- Glob agent-*.jsonl, sorted for deterministic thread indices.
      let childFiles := (dents.filter (fun (de : IO.FS.DirEntry) =>
        de.fileName.startsWith "agent-" && de.fileName.endsWith ".jsonl")).qsort
          (fun (a b : IO.FS.DirEntry) => decide (a.fileName < b.fileName))
      let mut children : Array SubagentChild := #[]
      let mut failures : List String := []
      for de in childFiles do
        let childText ← IO.FS.readFile de.path
        let agentId := (de.fileName.dropEnd 6).toString           -- strip ".jsonl"
        let metaPath : System.FilePath := (de.path.toString.dropEnd 6).toString ++ ".meta.json"
        match ← readSidecarChildMetadata metaPath with
        | .error err => failures := failures ++ [s!"{agentId}: {err}"]
        | .ok metadata =>
          match importClaudeCode childText with
          | .error err =>
              failures := failures ++ [s!"{agentId}: {err}"]
          | .ok child =>
              if metadata.globalActive && child.activeLeaf.isNone then
                failures := failures ++ [s!"{agentId}: active sidecar has no active leaf"]
              else
                children := children.push {
                  agentId := agentId
                  toolUseId := metadata.toolUseId
                  transcript := child
                  threadKindOverride := metadata.threadKindOverride
                  threadLabelOverride := metadata.threadLabelOverride
                  globalActive := metadata.globalActive }
      if !failures.isEmpty then
        pure (.error s!"{failures.length} subagent sidecar import(s) failed: {String.intercalate "; " failures}")
      else
        pure (stitchSubagentsChecked main children.toList)
    else
      pure (.ok main)   -- no subagents/ dir → main session unchanged

/-! ## Synthetic well-formedness pin (build-time, no store access).

Two tiny claude-shaped sessions: a `main` with one `Agent` tool_use (`toolu_AG1`),
and a `child`. Stitching `main` with two children — one keyed to `toolu_AG1`
(anchors), one to a bogus id (detaches) — must yield a well-formed IR with the
expected thread shape. Structure only; no real conversation content. -/

private def subMainFixture : String := String.intercalate "\n" [
  "{\"type\":\"user\",\"uuid\":\"6a000000-0000-4000-8000-000000000001\",\"parentUuid\":null,\"sessionId\":\"6a000000-0000-4000-8000-000000000000\",\"cwd\":\"/w\",\"timestamp\":\"2026-07-20T04:00:00.000Z\",\"isSidechain\":false,\"message\":{\"role\":\"user\",\"content\":\"go\"}}",
  "{\"type\":\"assistant\",\"uuid\":\"6a000000-0000-4000-8000-000000000002\",\"parentUuid\":\"6a000000-0000-4000-8000-000000000001\",\"sessionId\":\"6a000000-0000-4000-8000-000000000000\",\"cwd\":\"/w\",\"timestamp\":\"2026-07-20T04:00:01.000Z\",\"isSidechain\":false,\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"dispatching\"},{\"type\":\"tool_use\",\"id\":\"toolu_AG1\",\"name\":\"Agent\",\"input\":{\"x\":1}}]}}"
]

private def subChildFixture : String := String.intercalate "\n" [
  "{\"type\":\"user\",\"uuid\":\"6a000000-0000-4000-8000-000000000003\",\"parentUuid\":null,\"sessionId\":\"6a000000-0000-4000-8000-000000000000\",\"cwd\":\"/w\",\"timestamp\":\"2026-07-20T04:00:02.000Z\",\"isSidechain\":true,\"message\":{\"role\":\"user\",\"content\":\"child task\"}}",
  "{\"type\":\"assistant\",\"uuid\":\"6a000000-0000-4000-8000-000000000004\",\"parentUuid\":\"6a000000-0000-4000-8000-000000000003\",\"sessionId\":\"6a000000-0000-4000-8000-000000000000\",\"cwd\":\"/w\",\"timestamp\":\"2026-07-20T04:00:03.000Z\",\"isSidechain\":true,\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"toolu_C1\",\"name\":\"bash\",\"input\":{}}]}}",
  "{\"type\":\"user\",\"uuid\":\"6a000000-0000-4000-8000-000000000005\",\"parentUuid\":\"6a000000-0000-4000-8000-000000000004\",\"sessionId\":\"6a000000-0000-4000-8000-000000000000\",\"cwd\":\"/w\",\"timestamp\":\"2026-07-20T04:00:04.000Z\",\"isSidechain\":true,\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_C1\",\"is_error\":false,\"content\":\"child result\"}]}}"
]

/-- The stitched synthetic transcript (main + one anchored + one detached child). -/
private def subStitchedDemo : Except String Transcript := do
  let main  ← importClaudeCode subMainFixture
  let child ← importClaudeCode subChildFixture
  stitchSubagentsChecked main [
    { agentId := "agent-anchored", toolUseId := some "toolu_AG1", transcript := child },
    { agentId := "agent-detached", toolUseId := some "toolu_NOPE", transcript := child }]

/-- THE PIN: the stitched synthetic IR is well-formed (0 structural violations).
The child's tool_result CallRef is re-based across the append, main entries are
untouched, and the anchor is a positional ref into the earlier main thread — so
`Loom.WellFormed` holds. If the re-basing regresses, this stops compiling. -/
example : (match subStitchedDemo with
            | .ok t  => Loom.violations t == []
            | .error _ => false) = true := by native_decide

-- Structural shape of the synthetic stitch (task VERIFY step, no content):
-- expect `threads=3 (main=1, subagents=2: anchored=1, detached=1) mainEntries=2
-- totalEntries=8 violations=0`.
example :
    (match subStitchedDemo with
     | .ok t =>
         t.threads.size == 3
         && sidechainThreadCount t == 1
         && detachedThreadCount t == 1
         && threadEntryCount t 0 == 2
         && t.entries.size == 8
         && (match t.threads[1]?, t.threads[2]? with
             | some th1, some th2 =>
                 th1.kind == ThreadKind.sidechain (CallRef.resolved 1 1)
                 && th2.kind == ThreadKind.detached "toolUseId=toolu_NOPE unmatched"
             | _, _ => false)
         && (Loom.violations t).isEmpty
     | .error _ => false) = true := by native_decide

private def exactMetadataStitchDemo : Except String Transcript := do
  let main ← importClaudeCode subMainFixture
  let child ← importClaudeCode subChildFixture
  let side ← parseSidecarMetadataText
    "{\"toolUseId\":\"toolu_AG1\",\"_agentConvert\":{\"protocol\":\"agent-convert.sidecar-child.v1\",\"label\":\"worker\",\"globalActive\":false,\"threadKind\":\"sidechain\",\"anchorEntry\":1,\"anchorBlock\":1}}"
  let away ← parseSidecarMetadataText
    "{\"_agentConvert\":{\"protocol\":\"agent-convert.sidecar-child.v1\",\"label\":null,\"globalActive\":true,\"threadKind\":\"detached\",\"detachedReason\":\"exact detached reason\"}}"
  stitchSubagentsChecked main [
    { agentId := "agent-exact-sidechain", toolUseId := side.toolUseId,
      transcript := child, threadKindOverride := side.threadKindOverride,
      threadLabelOverride := side.threadLabelOverride, globalActive := side.globalActive },
    { agentId := "agent-exact-detached", toolUseId := away.toolUseId,
      transcript := child, threadKindOverride := away.threadKindOverride,
      threadLabelOverride := away.threadLabelOverride, globalActive := away.globalActive }]

/-- Parser-to-stitch pin: exact kind/anchor, detached reason, optional labels,
and a child-local active leaf survive in the combined global coordinate space. -/
example :
    (match exactMetadataStitchDemo with
     | .ok t =>
         t.activeLeaf == some 7 &&
         (t.entries[7]?).any (fun entry => entry.thread == 2) &&
         t.importNotes.any (fun note => note.loc.any
           (fun loc => loc.startsWith "subagent:agent-exact-sidechain")) &&
         (match t.threads[1]?, t.threads[2]? with
          | some side, some away =>
              side.kind == .sidechain (.resolved 1 1) &&
              side.label == some "worker" &&
              away.kind == .detached "exact detached reason" &&
              away.label.isNone
          | _, _ => false) &&
         (Loom.violations t).isEmpty
     | .error _ => false) = true := by native_decide

private def stitchRejected (result : Except String Transcript) : Bool :=
  match result with
  | .error _ => true
  | .ok _ => false

/-- The checked boundary rejects every metadata path that could install an
invalid, non-tool, mismatched, unresolved, or cross-thread exact anchor. -/
def unsafeExactSidecarAnchorsRejected : Bool :=
  match importClaudeCode subMainFixture, importClaudeCode subChildFixture with
  | .ok main, .ok child =>
      let outOfRange := stitchSubagentsChecked main [{
        agentId := "out-of-range", toolUseId := none, transcript := child,
        threadKindOverride := some (.sidechain (.resolved 99 0)) }]
      let notToolCall := stitchSubagentsChecked main [{
        agentId := "not-tool", toolUseId := none, transcript := child,
        threadKindOverride := some (.sidechain (.resolved 0 0)) }]
      let mismatchedId := stitchSubagentsChecked main [{
        agentId := "mismatch", toolUseId := some "other", transcript := child,
        threadKindOverride := some (.sidechain (.resolved 1 1)) }]
      let unresolved := stitchSubagentsChecked main [{
        agentId := "unresolved", toolUseId := none, transcript := child,
        threadKindOverride := some (.sidechain (.unresolved none "bad")) }]
      let extraMain := stitchSubagentsChecked main [{
        agentId := "extra-main", toolUseId := none, transcript := child,
        threadKindOverride := some .main }]
      let crossThread :=
        match stitchSubagentsChecked main [{
            agentId := "first", toolUseId := some "toolu_AG1", transcript := child }] with
        | .error _ => false
        | .ok combined => stitchRejected (stitchSubagentsChecked combined [{
            agentId := "cross-thread", toolUseId := none, transcript := child,
            threadKindOverride := some (.sidechain (.resolved 2 0)) }])
      stitchRejected outOfRange && stitchRejected notToolCall &&
      stitchRejected mismatchedId && stitchRejected unresolved &&
      stitchRejected extraMain && crossThread
  | _, _ => false

example : unsafeExactSidecarAnchorsRejected = true := by native_decide

/-- Multiple converter sidecars cannot race to replace the combined active leaf. -/
def multipleGlobalActiveSidecarsRejected : Bool :=
  match importClaudeCode subMainFixture, importClaudeCode subChildFixture with
  | .ok main, .ok child => stitchRejected (stitchSubagentsChecked main [
      { agentId := "active-a", toolUseId := none, transcript := child,
        threadKindOverride := some (.detached "a"), globalActive := true },
      { agentId := "active-b", toolUseId := none, transcript := child,
        threadKindOverride := some (.detached "b"), globalActive := true }])
  | _, _ => false

example : multipleGlobalActiveSidecarsRejected = true := by native_decide

/-- A native Claude child with no metadata is retained as an explicitly detached
thread; absence never fabricates a parent anchor or a source label. -/
def claudeNativeMissingMetadataDetaches : Bool :=
  match importClaudeCode subMainFixture, importClaudeCode subChildFixture with
  | .ok main, .ok child =>
      match stitchSubagentsChecked main [{
          agentId := "native-no-meta", toolUseId := none, transcript := child }] with
      | .ok stitched =>
          (stitched.threads[1]?).any (fun thread =>
            thread.kind == .detached "no meta.json toolUseId" &&
            thread.label == some "native-no-meta") &&
          stitched.activeLeaf == main.activeLeaf &&
          (Loom.violations stitched).isEmpty
      | .error _ => false
  | _, _ => false

example : claudeNativeMissingMetadataDetaches = true := by native_decide

/-- Native metadata remains inferential, but duplicate native tool ids are
reported as detached ambiguity rather than falsely selecting the first call. -/
def duplicateNativeSidecarAnchorIsHonest : Bool :=
  match importClaudeCode subMainFixture, importClaudeCode subChildFixture with
  | .ok main, .ok child =>
      match main.entries[1]? with
      | none => false
      | some callEntry =>
          let duplicateMain := { main with
            entries := main.entries.push { callEntry with parent := some 0 }
            activeLeaf := some 2 }
          match stitchSubagentsChecked duplicateMain [{
              agentId := "native-duplicate", toolUseId := some "toolu_AG1",
              transcript := child }] with
          | .ok stitched =>
              (stitched.threads[1]?).any (fun thread =>
                thread.kind == .detached
                  "toolUseId=toolu_AG1 ambiguous (2 matching calls)")
          | .error _ => false
  | _, _ => false

example : duplicateNativeSidecarAnchorIsHonest = true := by native_decide

end LoomConvert
