import LoomConvert.ClaudeSubagents
import LoomConvert.CursorAgent

/-!
# LoomConvert.CursorAgentSubagents — cursor-agent sub-agent stitching (D16)

Closes `D16-cursor-cli-subagents-dropped` (census `Loom.Formats.CursorAgent`,
gap `D16-subagent-sidechains`). The cursor-agent **CLI** externalizes each
sub-agent's child transcript to a sidecar under the SAME directory as the root
session file; `importCursorAgent` (like the TS `adaptCursorAgent`) reads only the
root file and DROPS the children (census: **144 child transcripts on disk**). This
module walks that sidecar dir and **stitches** each child in as a first-class
`Thread`, reusing the FORMAT-AGNOSTIC core from `LoomConvert.ClaudeSubagents`
(`stitchSubagents` / `SubagentChild` / the `*ThreadCount` + `stitchReport`
helpers) unchanged — only the ACTUATOR (which files, and the anchor scheme) is
cursor-specific.

## The on-disk layout (verified, structural)

    ~/.cursor/projects/<cwd-slug>/agent-transcripts/<uuid>/<uuid>.jsonl   -- root
    ~/.cursor/projects/<cwd-slug>/agent-transcripts/<uuid>/subagents/<child-uuid>.jsonl

The `subagents/` dir is a **sibling of the root file** (same parent dir), NOT
`<stem>/subagents` as in Claude. Each child is itself cursor-agent-shaped JSONL
(`{role, message:{content:[text|tool_use]}}`), so the SAME `importCursorAgent`
imports it as its own linear thread. Native tool calls retain absent `rawId`
exactly; no call identity is synthesized for stitching.
There is **no `.meta.json` sidecar** (144/144 files on disk are `.jsonl`); the
child carries no back-pointer of any kind.

## The anchor scheme — DIFFERENT from Claude (this is why `findAnchorCursor`)

Claude has an IN-BAND anchor: `agent-<id>.meta.json` records a `toolUseId` that
equals the spawning tool_use `id` in the parent — `findAnchor` matches it to a
main-thread `AssistantBlock.toolCall.rawId` (reliable, 18/18). **cursor-agent has
no such key** (measured, not assumed):

* the child UUID (its filename) appears **0 times** inside the root file;
* there is no meta sidecar to carry a `toolUseId`;
* the CLI stores tool CALLS but **never tool RESULTS**, so the Cursor *IDE*
  linkage (`extractAgentIdFromResult(tf.result)` in `src/pi/cursor.ts`, which
  pulls the child composer id out of the `task_v2` result) is structurally
  unavailable here.

So child→parent linkage is NOT in-band. The only signal is directory containment
plus a **positional heuristic**: the CLI's `Task` / `Subagent` / `Agent` spellings
are interpreted as `CanonicalTool.agentSpawn` while remaining exact in
`ToolName.raw`, and we pair the i-th externalized child (children sorted by
filename, for determinism) with the i-th main-thread spawn call. `findAnchorCursor`
returns that spawn call's positional `CallRef`, which is supplied directly as the
native child's explicit `ThreadKind.sidechain` override. No fabricated string id
or shared raw-id lookup participates. Children past the last spawn call (or in a
root with zero spawn calls — auto-spawned helpers) fall to `detached`.

This pairing is **approximate by construction** (census: `#children ≠ #spawn-calls`
in 18/27 dirs; sorted-filename order need not be spawn order) and is flagged as
such — exactly the census's "any parent-call binding must be heuristic and
approximate". It is honest: representable, anchored where a spawn call exists,
`detached` (never fabricated) otherwise.

VERIFY: this is a NEW capability the TS toolchain does not have — `adaptCursorAgent`
is single-file, so there is NO multi-file reference oracle for the stitched result
(census D16 plan). It is therefore verified by well-formedness (`violations = 0`)
+ structure, never by cross-parity.
-/

namespace LoomConvert
open Loom

/-! ## Cursor anchor scheme (pure) -/

/-- Spawn classification consumes the interpretation layer, never source
spelling. An explicit non-spawn canonical value remains non-spawn even when its
raw label happens to resemble a known Cursor spawn tool. -/
def isCursorSpawnTool (name : ToolName) : Bool :=
  match name.canonical with
  | some .agentSpawn => true
  | _ => false

/-- Every native main-thread sub-agent-spawn tool-call coordinate, in document
order. Historical-unverified entries are inert archival data and cannot consume
a child ordinal. The inventory is positional because cursor-agent has no in-band
child→parent identity. `rawId` is deliberately irrelevant: native calls commonly
have none, and duplicate explicit ids do not make coordinates ambiguous. -/
def cursorSpawnCallRefs (main : Transcript) : Array CallRef := Id.run do
  let mainThreads := main.threads.toList.zipIdx.filterMap fun (thread, index) =>
    if thread.kind == ThreadKind.main then some index else none
  let some mainThread := match mainThreads with | [index] => some index | _ => none
    | return #[]
  let mut refs : Array CallRef := #[]
  for (entry, entryIdx) in main.entries.toList.zipIdx do
    if entry.thread == mainThread &&
        entry.disposition == EntryDisposition.native then
      match entry.payload with
      | .assistantMsg blocks =>
          for (block, blockIdx) in blocks.zipIdx do
            match block with
            | .toolCall name _ _ =>
                if isCursorSpawnTool name then
                  refs := refs.push (.resolved entryIdx blockIdx)
            | _ => pure ()
      | _ => pure ()
  return refs

/-- Cursor's anchor resolver — the analogue of Claude's `findAnchor`, but
POSITIONAL instead of in-band. It maps a child ORDINAL (its rank among the
filename-sorted children) to the positionally paired spawn `CallRef`, or `none`
when there are fewer spawn calls than children (→ that child is detached).
Contrast Claude, where an id is read from child metadata and matched exactly;
here the coordinate is inferred by position and is approximate. -/
def findAnchorCursor (main : Transcript) (childOrdinal : Nat) : Option CallRef :=
  (cursorSpawnCallRefs main)[childOrdinal]?

/-! ## Actuator: the only IO. -/

/-- Import a cursor-agent CLI session AND stitch in its externalized sub-agents.

(1) import the root session with its path identity (`importCursorAgentAtPath`);
(2) locate the sibling
`subagents/` dir (same parent dir as the root file) and glob `*.jsonl`, sorted by
filename for deterministic thread indices; (3) import each child (itself
cursor-agent-shaped) and either read converter-owned exact thread metadata or,
for native files, assign an explicit positional `CallRef` via `findAnchorCursor`
(the i-th child ↔ the i-th main-thread spawn call); (4) the checked stitch adds
each as a `sidechain` (anchored) or `detached` thread with the child's entries
appended and re-based. Sessions with no `subagents/` dir return the root
transcript unchanged (identical to `importCursorAgent`). -/
def importCursorAgentSessionWithSubagents (sessionFile : System.FilePath) :
    IO (Except String Transcript) := do
  let mainText ← IO.FS.readFile sessionFile
  match importCursorAgentAtPath sessionFile mainText with
  | .error e => pure (.error e)
  | .ok main => do
    -- The `subagents/` dir sits beside the root file (NOT `<stem>/subagents`).
    let subDir : System.FilePath := (sessionFile.parent.getD ("." : System.FilePath)) / "subagents"
    if ← subDir.isDir then
      let dents ← subDir.readDir
      -- Glob `*.jsonl`, sorted so child ordinal (→ positional anchor) is stable.
      let childFiles := (dents.filter (fun (de : IO.FS.DirEntry) =>
        de.fileName.endsWith ".jsonl")).qsort
          (fun (a b : IO.FS.DirEntry) => decide (a.fileName < b.fileName))
      -- Precompute positional spawn coordinates once; no native raw id exists.
      let spawnRefs := cursorSpawnCallRefs main
      let mut children : Array SubagentChild := #[]
      let mut failures : List String := []
      for (de, i) in childFiles.toList.zipIdx do
        let childText ← IO.FS.readFile de.path
        let agentId := (de.fileName.dropEnd 6).toString  -- strip ".jsonl"
        let metaPath : System.FilePath := (de.path.toString.dropEnd 6).toString ++ ".meta.json"
        match ← readSidecarChildMetadata metaPath with
        | .error err => failures := failures ++ [s!"{agentId}: {err}"]
        | .ok metadata =>
          -- Exact converter metadata keeps its recorded coordinate and optional
          -- real id. Native files have neither, so use only the positional ref.
          let nativePositional :=
            metadata.threadKindOverride.isNone && metadata.toolUseId.isNone
          let positionalRef := if nativePositional then spawnRefs[i]? else none
          let threadKindOverride := match metadata.threadKindOverride with
            | some kind => some kind
            | none => match metadata.toolUseId with
              | some _ => none
              | none => positionalRef.map (fun ref => ThreadKind.sidechain ref)
          match importCursorAgentAtPath de.path childText with
          | .error err =>
              failures := failures ++ [s!"{agentId}: {err}"]
          | .ok child =>
              if metadata.globalActive && child.activeLeaf.isNone then
                failures := failures ++ [s!"{agentId}: active sidecar has no active leaf"]
              else
                let child := if nativePositional then
                    let detail := match positionalRef with
                      | some (.resolved entry block) =>
                          s!"child ordinal {i} paired approximately with main tool-call coordinate {entry}:{block}"
                      | some (.unresolved _ _) =>
                          s!"child ordinal {i} had an unexpected unresolved positional anchor"
                      | none =>
                          s!"child ordinal {i} has no positional spawn call and remains detached"
                    { child with importNotes := child.importNotes ++ [{
                        kind := .other "cursorAgentPositionalSubagentAnchor",
                        loc := some "positional-anchor", detail }] }
                  else child
                children := children.push {
                  agentId := agentId
                  toolUseId := metadata.toolUseId
                  transcript := child
                  threadKindOverride := threadKindOverride
                  threadLabelOverride := metadata.threadLabelOverride
                  globalActive := metadata.globalActive }
      if !failures.isEmpty then
        pure (.error s!"{failures.length} subagent sidecar import(s) failed: {String.intercalate "; " failures}")
      else
        pure (stitchSubagentsChecked main children.toList)
    else
      pure (.ok main)   -- no subagents/ dir → root session unchanged

/-- Structural, content-free one-line report for a real session file (used by the
store-verification driver; emits `stitchReport` counts only, never conversation
text). -/
def reportCursorSession (sessionFile : System.FilePath) : IO String := do
  match ← importCursorAgentSessionWithSubagents sessionFile with
  | .error e => pure s!"ERROR {e}"
  | .ok t    => pure (stitchReport t)

/-! ## Synthetic well-formedness pin (build-time, no store access).

A real cursor-agent store exists locally and is verified separately (structural
report over real dirs). This pin makes the module self-verifying at BUILD time,
independent of the store, mirroring `ClaudeSubagents`.

`caParentFixture` is a cursor-agent root with TWO no-id spawn calls (`Task` and
`Subagent`); `caChildFixture` is a two-entry child. Stitching THREE copies —
ordinals 0,1 anchor directly to the two call coordinates, ordinal 2 has no spawn
call and detaches — must yield a well-formed IR of the expected shape. Structure
only; no real conversation content. -/

private def caParentFixture : String := String.intercalate "\n" [
  "{\"role\":\"user\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"go\"}]}}",
  "{\"role\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"dispatching\"},{\"type\":\"tool_use\",\"name\":\"Task\",\"input\":{\"x\":1}},{\"type\":\"tool_use\",\"name\":\"Subagent\",\"input\":{\"y\":2}}]}}"
]

private def caChildFixture : String := String.intercalate "\n" [
  "{\"role\":\"user\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"child task\"}]}}",
  "{\"role\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"child work\"},{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{}}]}}"
]

private def caParentToolIdentityExact (main : Transcript) : Bool :=
  match main.entries[1]? with
  | some entry =>
      match entry.payload with
      | .assistantMsg [
          .text _,
          .toolCall taskName _ taskId,
          .toolCall subagentName _ subagentId] =>
            taskName.raw == "Task" &&
            decide (taskName.canonical = some .agentSpawn) &&
            taskId.isNone &&
            subagentName.raw == "Subagent" &&
            decide (subagentName.canonical = some .agentSpawn) &&
            subagentId.isNone
      | _ => false
  | none => false

/-- Canonical meaning is authoritative for anchor discovery. Raw source labels
are neither required to have a particular spelling nor sufficient by themselves. -/
def cursorSpawnClassificationUsesCanonicalMeaning : Bool :=
  ["Task", "Subagent", "Agent"].all (fun raw =>
    isCursorSpawnTool { raw, canonical := cursorCanonicalTool (some raw) }) &&
  isCursorSpawnTool { raw := "future_spawn", canonical := some .agentSpawn } &&
  !isCursorSpawnTool { raw := "Task", canonical := some .bash } &&
  !isCursorSpawnTool { raw := "task", canonical := none }

example : cursorSpawnClassificationUsesCanonicalMeaning = true := by native_decide

/-- Pin the cursor anchor scheme itself: the parent's exact raw names and typed
spawn interpretations survive import with `rawId = none`; positional discovery
resolves ordinals 0/1 to their exact call coordinates, and ordinal 2 (past the
last spawn) resolves to `none`. -/
example :
    (match importCursorAgent caParentFixture with
     | .ok m => caParentToolIdentityExact m
                && cursorSpawnCallRefs m == #[.resolved 1 1, .resolved 1 2]
                && findAnchorCursor m 0 == some (.resolved 1 1)
                && findAnchorCursor m 1 == some (.resolved 1 2)
                && findAnchorCursor m 2 == none
     | .error _ => false) = true := by native_decide

private def caHistoricalSpawnInterleaveFixture : String := String.intercalate "\n" [
  "{\"role\":\"assistant\",\"message\":{\"content\":[{\"type\":\"agent_convert_tool_call\",\"rawName\":\"Task\",\"args\":{}}]}}",
  "{\"role\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":null,\"name\":\"Task\",\"input\":{}}]}}",
  "{\"role\":\"assistant\",\"message\":{\"content\":[{\"type\":\"agent_convert_tool_call\",\"rawName\":\"Subagent\",\"args\":{},\"rawId\":\"duplicate-spawn\"}]}}",
  "{\"role\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"duplicate-spawn\",\"name\":\"Agent\",\"input\":{}}]}}",
  "{\"role\":\"assistant\",\"message\":{\"content\":[{\"type\":\"agent_convert_tool_call\",\"rawName\":\"Agent\",\"args\":{},\"rawId\":\"duplicate-spawn\"}]}}",
  "{\"role\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"duplicate-spawn\",\"name\":\"Subagent\",\"input\":{}}]}}"
]

private def caSingleSpawnEntryHas (entry : Entry) (disposition : EntryDisposition)
    (rawId : Option String) : Bool :=
  entry.disposition == disposition &&
    match entry.payload with
    | .assistantMsg [.toolCall name _ actualId] =>
        isCursorSpawnTool name && actualId == rawId
    | _ => false

/-- Child ordinals are ranks in explicit filename order, but only native spawn
entries populate those ranks. Interleaved historical spawn-shaped calls neither
shift the three anchors nor force identity synthesis; native null and duplicate
ids remain exact because the anchor is the positional `CallRef`. -/
def cursorFilenameOrdinalsIgnoreHistoricalSpawnCalls : Bool :=
  match importCursorAgent caHistoricalSpawnInterleaveFixture with
  | .error _ => false
  | .ok main =>
      let filenames := (#[] : Array String)
        |>.push "zeta.jsonl" |>.push "alpha.jsonl" |>.push "middle.jsonl"
        |>.qsort (fun a b => decide (a < b))
      filenames == #["alpha.jsonl", "middle.jsonl", "zeta.jsonl"] &&
      (match main.entries.toList with
       | [h0, n1, h2, n3, h4, n5] =>
           caSingleSpawnEntryHas h0 .historicalUnverified none &&
           caSingleSpawnEntryHas n1 .native none &&
           caSingleSpawnEntryHas h2 .historicalUnverified
             (some "duplicate-spawn") &&
           caSingleSpawnEntryHas n3 .native (some "duplicate-spawn") &&
           caSingleSpawnEntryHas h4 .historicalUnverified
             (some "duplicate-spawn") &&
           caSingleSpawnEntryHas n5 .native (some "duplicate-spawn")
       | _ => false) &&
      cursorSpawnCallRefs main == #[
        .resolved 1 0, .resolved 3 0, .resolved 5 0] &&
      findAnchorCursor main 0 == some (.resolved 1 0) &&
      findAnchorCursor main 1 == some (.resolved 3 0) &&
      findAnchorCursor main 2 == some (.resolved 5 0) &&
      findAnchorCursor main 3 == none

example : cursorFilenameOrdinalsIgnoreHistoricalSpawnCalls = true := by
  native_decide

/-- The stitched synthetic transcript (root + two anchored + one detached child),
built with the same direct positional overrides as the actuator. -/
private def caSubDemo : Except String Transcript := do
  let main  ← importCursorAgent caParentFixture
  let child ← importCursorAgent caChildFixture
  stitchSubagentsChecked main [
    { agentId := "child-a", toolUseId := none, transcript := child,
      threadKindOverride := (findAnchorCursor main 0).map ThreadKind.sidechain },
    { agentId := "child-b", toolUseId := none, transcript := child,
      threadKindOverride := (findAnchorCursor main 1).map ThreadKind.sidechain },
    { agentId := "child-c", toolUseId := none, transcript := child,
      threadKindOverride := (findAnchorCursor main 2).map ThreadKind.sidechain }]

/-- THE PIN: the stitched synthetic IR is well-formed (0 structural violations).
The child's intra-thread parent is re-based across the append and the anchors are
positional `CallRef`s into the earlier main thread, so `Loom.WellFormed` holds. If
the re-basing or the anchor scheme regresses, this stops compiling. -/
example : (match caSubDemo with
            | .ok t  => Loom.violations t == []
            | .error _ => false) = true := by native_decide

/-- Structural shape of the synthetic stitch (task VERIFY step, no content):
`threads=4 (main=1, subagents=3: anchored=2, detached=1) mainEntries=2
totalEntries=8 violations=0`, with the two anchors pointing at the two spawn
calls (block 1 and block 2 of the assistant entry) and the third thread detached. -/
example :
    (match caSubDemo with
     | .ok t =>
         t.threads.size == 4
         && sidechainThreadCount t == 2
         && detachedThreadCount t == 1
         && threadEntryCount t 0 == 2
         && t.entries.size == 8
         && (match t.threads[1]?, t.threads[2]?, t.threads[3]? with
             | some th1, some th2, some th3 =>
                 th1.kind == ThreadKind.sidechain (CallRef.resolved 1 1)
                 && th2.kind == ThreadKind.sidechain (CallRef.resolved 1 2)
                 && (match th3.kind with | ThreadKind.detached _ => true | _ => false)
             | _, _, _ => false)
         && (Loom.violations t).isEmpty
     | .error _ => false) = true := by native_decide

private def caExactParentFixture : String := String.intercalate "\n" [
  "{\"role\":\"user\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"go\"}]}}",
  "{\"role\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"dispatching\"},{\"type\":\"tool_use\",\"name\":\"Task\",\"input\":{\"x\":1}},{\"type\":\"tool_use\",\"id\":\"source-spawn-2\",\"name\":\"Subagent\",\"input\":{\"y\":2}}]}}"
]

private def caExactSidecarDemo : Except String Transcript := do
  let main ← importCursorAgent caExactParentFixture
  let child ← importCursorAgent caChildFixture
  stitchSubagentsChecked main [
    { agentId := "cursor-exact-side", toolUseId := some "source-spawn-2", transcript := child,
      threadKindOverride := some (.sidechain (.resolved 1 2)),
      threadLabelOverride := some none, globalActive := true },
    { agentId := "cursor-exact-away", toolUseId := none, transcript := child,
      threadKindOverride := some (.detached "exact cursor detached"),
      threadLabelOverride := some (some "detached cursor worker") }]

/-- Converter-owned Cursor metadata preserves exact structural disposition,
cross-checks a real recorded source id against its coordinate, and maps the
selected child's local leaf into the combined global entry array. -/
example :
    (match caExactSidecarDemo with
     | .ok t =>
         t.activeLeaf == some 3 &&
         (t.entries[3]?).any (fun entry => entry.thread == 1) &&
         (match t.threads[1]?, t.threads[2]? with
          | some side, some away =>
              side.kind == .sidechain (.resolved 1 2) && side.label.isNone &&
              away.kind == .detached "exact cursor detached" &&
              away.label == some "detached cursor worker"
          | _, _ => false) &&
         (Loom.violations t).isEmpty
     | .error _ => false) = true := by native_decide

private def caCheckedRejected (result : Except String Transcript) : Bool :=
  match result with
  | .error _ => true
  | .ok _ => false

/-- A native Cursor directory with no `.meta.json` uses an explicit positional
sidechain coordinate, keeps `toolUseId = none`, and labels the child honestly
from its filename. -/
def cursorNativeMissingMetadataFallbackExact : Bool :=
  match importCursorAgent caParentFixture, importCursorAgent caChildFixture with
  | .ok main, .ok child =>
      match stitchSubagentsChecked main [{
          agentId := "native-child", toolUseId := none, transcript := child,
          threadKindOverride := (findAnchorCursor main 0).map ThreadKind.sidechain }] with
      | .ok stitched =>
          stitched.activeLeaf == main.activeLeaf &&
          (stitched.threads[1]?).any (fun thread =>
            thread.kind == .sidechain (.resolved 1 1) &&
            thread.label == some "native-child") &&
          (Loom.violations stitched).isEmpty
      | .error _ => false
  | _, _ => false

example : cursorNativeMissingMetadataFallbackExact = true := by native_decide

/-- Cursor uses the same checked stitch boundary: duplicate active claims and
exact anchors into a non-main thread are rejected. -/
def cursorUnsafeMetadataRejected : Bool :=
  match importCursorAgent caParentFixture, importCursorAgent caChildFixture with
  | .ok main, .ok child =>
      let duplicateActive := caCheckedRejected (stitchSubagentsChecked main [
        { agentId := "cursor-active-a", toolUseId := none, transcript := child,
          threadKindOverride := some (.detached "a"), globalActive := true },
        { agentId := "cursor-active-b", toolUseId := none, transcript := child,
          threadKindOverride := some (.detached "b"), globalActive := true }])
      let crossThread :=
        match stitchSubagentsChecked main [{
            agentId := "cursor-first", toolUseId := none, transcript := child,
            threadKindOverride := (findAnchorCursor main 0).map ThreadKind.sidechain }] with
        | .error _ => false
        | .ok combined => caCheckedRejected (stitchSubagentsChecked combined [{
            agentId := "cursor-cross-thread", toolUseId := none, transcript := child,
            threadKindOverride := some (.sidechain (.resolved 2 0)) }])
      duplicateActive && crossThread
  | _, _ => false

example : cursorUnsafeMetadataRejected = true := by native_decide

end LoomConvert
