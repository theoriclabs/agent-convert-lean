import LoomConvert.Cli.Formats

/-!
# CLI output publication

Single-file staging and multi-file sidecar publication, including thread
projection, ownership checks, rollback, and fault-injection regressions.
Only the publication entry points and subagent policy are public. Transaction
mechanics and fault injection stay private to this module.
-/

namespace LoomConvert.Cli
open Loom

/-- Thread index containing the root conversation. Importers write this at index
0, but the wire format is explicit, so prefer the declared `main` thread. -/
private def mainThreadIndex (t : Transcript) : Nat :=
  match t.threads.toList.zipIdx.find? (fun p => p.1.kind == ThreadKind.main) with
  | some p => p.2
  | none => 0

private def nonMainThreadInfos (t : Transcript) : List (Nat × Thread) :=
  t.threads.toList.zipIdx.filterMap (fun p =>
    match p.1.kind with
    | ThreadKind.main => none
    | _ => some (p.2, p.1))

private def projectedIndex? (oldIdxs : List Nat) (old : Nat) : Option Nat :=
  (oldIdxs.zipIdx.find? (fun p => p.1 == old)).map (fun p => p.2)

private def projectCallRef (t : Transcript) (oldIdxs : List Nat) : CallRef → CallRef
  | CallRef.resolved e b =>
      match projectedIndex? oldIdxs e with
      | some e' => CallRef.resolved e' b
      | none => CallRef.unresolved (callRefToolUseId t (CallRef.resolved e b))
          "call outside projected sidecar"
  | other => other

private def projectEnvBlock (t : Transcript) (oldIdxs : List Nat) : EnvBlock → EnvBlock
  | EnvBlock.toolResult call content err =>
      EnvBlock.toolResult (projectCallRef t oldIdxs call) content err
  | other => other

private def projectPayload (t : Transcript) (oldIdxs : List Nat) (entry : Entry) : Payload :=
  match projectClaudeHistoricalCarrierCoordinates oldIdxs entry with
  | Payload.envMsg blocks => Payload.envMsg (blocks.map (projectEnvBlock t oldIdxs))
  | projected => projected

/-- Project one Loom thread to a standalone flat-format transcript. Parents and
tool-result `CallRef`s that point inside the selected thread are re-based to the
new entry indices; cross-thread links are intentionally not encoded as parents.
Sidechain anchoring is carried by the sidecar metadata/layout instead. -/
private def projectThread (t : Transcript) (threadIdx : Nat) : Transcript :=
  let pairs := t.entries.toList.zipIdx.filter (fun p => p.1.thread == threadIdx)
  let oldIdxs := pairs.map (fun p => p.2)
  let label := (t.threads[threadIdx]?).bind (fun th => th.label)
  let entries := (pairs.map (fun p =>
    let e := p.1
    { e with
      parent := e.parent.bind (projectedIndex? oldIdxs)
      thread := 0
      payload := projectPayload t oldIdxs e })).toArray
  let active? := t.activeLeaf.bind (projectedIndex? oldIdxs)
  let fallback := if entries.isEmpty then none else some (entries.size - 1)
  { t with
    threads := #[{ kind := ThreadKind.main, label := label }]
    entries := entries
    activeLeaf := match active? with | some a => some a | none => fallback }

def sidecarTarget (toFmt : String) : Bool :=
  toFmt == "claude" || toFmt == "cursor-agent"

/-- Targets that can retain sidechain/detached threads without flattening. -/
private def preservesSubagentThreads (toFmt : String) : Bool :=
  toFmt == "loom" || sidecarTarget toFmt

/-- Subagent sidecars are on by default for inspect and for targets that can
keep threads. Flat exporters (pi/codex) stay main-branch unless
`--with-subagents` is explicit — otherwise real Claude sessions would refuse. -/
def resolveWithSubagents (toFmt? : Option String) (flag : Option Bool) : Bool :=
  match flag with
  | some b => b
  | none =>
      match toFmt? with
      | none => true
      | some toFmt => preservesSubagentThreads toFmt

private def claudeSubagentsDir (path : System.FilePath) : System.FilePath :=
  let base := path.toString
  let stemPath := if base.endsWith ".jsonl" then (base.dropEnd 6).toString else base
  stemPath ++ "/subagents"

private def cursorSubagentsDir (path : System.FilePath) : System.FilePath :=
  (path.parent.getD ("." : System.FilePath)) / "subagents"

private def sidecarFileTypeName : IO.FS.FileType → String
  | .file => "regular file"
  | .dir => "directory"
  | .symlink => "symbolic link"
  | .other => "special filesystem entry"

/-- `pathExists` follows symlinks, which is unsafe for publication ownership
checks. This probe uses `lstat` semantics and distinguishes absence from every
other filesystem error. -/
private def sidecarPathType? (path : System.FilePath) :
    IO (Except String (Option IO.FS.FileType)) := do
  match ← path.symlinkMetadata.toBaseIO with
  | .ok metadata => pure (.ok (some metadata.type))
  | .error (.noFileOrDirectory ..) => pure (.ok none)
  | .error error => pure (.error s!"cannot inspect '{path}': {error}")

/-- A sidecar directory is replaceable only when every immediate entry is one
of the exact generated names and is an ordinary file. Unknown files, nested
directories, symlinks, and special entries are all unowned data. -/
private def ensureExpectedSidecarDirectory (family : String) (subDir : System.FilePath)
    (allowed : List String) : IO (Except String Unit) := do
  match ← sidecarPathType? subDir with
  | .error error => pure (.error error)
  | .ok none => pure (.ok ())
  | .ok (some kind) =>
      if kind != .dir then
        pure (.error s!"refusing {family} sidecar export: '{subDir}' is a {sidecarFileTypeName kind}, not an owned directory")
      else do
        let entries ← try
          pure (← subDir.readDir)
        catch error =>
          return .error s!"cannot inventory {family} sidecar directory '{subDir}': {error}"
        let mut blockers : List String := []
        for entry in entries do
          match ← sidecarPathType? entry.path with
          | .error error => blockers := error :: blockers
          | .ok none =>
              blockers := s!"{entry.fileName} (vanished while ownership was checked)" :: blockers
          | .ok (some entryKind) =>
              if !(allowed.contains entry.fileName) then
                blockers :=
                  s!"{entry.fileName} ({sidecarFileTypeName entryKind}; unexpected name)" ::
                    blockers
              else if entryKind != .file then
                blockers :=
                  s!"{entry.fileName} ({sidecarFileTypeName entryKind}; expected a regular file)" ::
                    blockers
        if blockers.isEmpty then
          pure (.ok ())
        else
          pure (.error s!"refusing {family} sidecar export because '{subDir}' contains unowned entries: {String.intercalate ", " blockers.reverse}")

private def ensureNoExtraClaudeSidecars (subDir : System.FilePath) (agentIds : List String) :
    IO (Except String Unit) :=
  ensureExpectedSidecarDirectory "Claude" subDir
    (agentIds.flatMap (fun id => [s!"{id}.jsonl", s!"{id}.meta.json"]))

private def ensureNoExtraCursorSidecars (subDir : System.FilePath) (childIds : List String) :
    IO (Except String Unit) :=
  ensureExpectedSidecarDirectory "Cursor Agent" subDir
    (childIds.flatMap (fun id => [s!"{id}.jsonl", s!"{id}.meta.json"]))

private def threadHasActiveLeaf (t : Transcript) (threadIdx : Nat) : Bool :=
  match t.activeLeaf with
  | some leaf => (t.entries[leaf]?).any (fun entry => entry.thread == threadIdx)
  | none => false

/-- Sidecar files project the main thread to a standalone transcript, so an
anchor stored in sidecar metadata must use that projected entry coordinate,
not the combined transcript's global entry index. -/
private def projectSidecarThreadAnchor (t : Transcript) (th : Thread) : Except String Thread :=
  match th.kind with
  | .sidechain (.resolved entry block) =>
      let mainIdx := mainThreadIndex t
      let mainEntries := t.entries.toList.zipIdx.filterMap (fun (candidate, index) =>
        if candidate.thread == mainIdx then some index else none)
      match projectedIndex? mainEntries entry with
      | some projected =>
          .ok { th with kind := .sidechain (.resolved projected block) }
      | none =>
          .error s!"sidechain anchor entry {entry} is not in the projected main thread"
  | _ => .ok th

private structure PreparedSidecarThread where
  threadIdx : Nat
  sourceThread : Thread
  metadataThread : Thread

private def prepareSidecarThreads (t : Transcript) : Except String (List PreparedSidecarThread) :=
  (nonMainThreadInfos t).mapM (fun (threadIdx, sourceThread) => do
    let metadataThread ← projectSidecarThreadAnchor t sourceThread
    pure { threadIdx, sourceThread, metadataThread })

private def exactSidecarThreadJson (th : Thread) (globalActive : Bool)
    (anchorEncoding : Option String := none) : Lean.Json :=
  let label := match th.label with
    | some value => Lean.Json.str value
    | none => Lean.Json.null
  Lean.Json.mkObj ([
    ("protocol", Lean.Json.str "agent-convert.sidecar-child.v1"),
    ("label", label),
    ("globalActive", Lean.Json.bool globalActive)
  ] ++ (match th.kind with
    | .sidechain (.resolved entry block) => [
        ("threadKind", Lean.Json.str "sidechain"),
        ("anchorEntry", Lean.Json.str (toString entry)),
        ("anchorBlock", Lean.Json.str (toString block))]
    | .sidechain (.unresolved _ note) => [
        ("threadKind", Lean.Json.str "detached"),
        ("detachedReason", Lean.Json.str s!"unresolved source anchor: {note}")]
    | .detached note => [
        ("threadKind", Lean.Json.str "detached"),
        ("detachedReason", Lean.Json.str note)]
    | .main => [
        ("threadKind", Lean.Json.str "detached"),
        ("detachedReason", Lean.Json.str "invalid additional main thread")]) ++
    (match th.kind, anchorEncoding with
     | .sidechain (.resolved _ _), some encoding => [
         ("anchorEncoding", Lean.Json.str encoding)]
     | _, _ => []))

private def claudeMetaJson (agentId : String) (th : Thread)
    (toolUseId : Option String) (globalActive nativeAnchor : Bool) : Lean.Json :=
  let anchorEncoding := match th.kind with
    | .sidechain (.resolved _ _) =>
        some (if nativeAnchor then "native-tool-use" else "historical-carrier")
    | _ => none
  Lean.Json.mkObj ([
    ("agentType", Lean.Json.str "loom-export"),
    ("description", Lean.Json.str (th.label.getD agentId)),
    ("spawnDepth", Lean.Json.str "1"),
    ("_agentConvert", exactSidecarThreadJson th globalActive anchorEncoding)
  ] ++
    (match if nativeAnchor then toolUseId else none with
     | some tid => [("toolUseId", Lean.Json.str tid)]
     | none => []) ++
    (match th.kind with
     | ThreadKind.detached note => [("detached", Lean.Json.bool true), ("note", Lean.Json.str note)]
     | _ => []))

private def cursorMetaJson (th : Thread) (toolUseId : Option String)
    (globalActive : Bool) : Lean.Json :=
  Lean.Json.mkObj ([
    ("_agentConvert", exactSidecarThreadJson th globalActive)
  ] ++ match toolUseId with
    | some id => [("toolUseId", Lean.Json.str id)]
    | none => [])

private structure SidecarChildOutput where
  transcriptPath : System.FilePath
  transcriptText : String
  metadataPath : System.FilePath
  metadataText : String

/-- Remove a path that this invocation proved it created or quarantined. The
`lstat` check prevents a symlink from being traversed as a directory. -/
private def removeOwnedPathChecked (path : System.FilePath) : IO (Except String Unit) := do
  match ← sidecarPathType? path with
  | .error error => pure (.error error)
  | .ok none => pure (.ok ())
  | .ok (some kind) =>
      try
        if kind == .dir then IO.FS.removeDirAll path else IO.FS.removeFile path
        pure (.ok ())
      catch error =>
        pure (.error s!"cannot remove converter-owned path '{path}': {error}")

private def removeOwnedPathsChecked (paths : List System.FilePath) : IO (List String) := do
  let mut errors : List String := []
  for path in paths do
    match ← removeOwnedPathChecked path with
    | .ok _ => pure ()
    | .error error => errors := error :: errors
  pure errors.reverse

/-- The single-file writer has no recovery transaction. It still uses the
symlink-safe remover, but its primary write error remains the public result. -/
private def cleanupOwnedPath (path : System.FilePath) : IO Unit := do
  let _ ← removeOwnedPathChecked path
  pure ()

/-- Create a staging file exclusively. This closes the check/create race that
would otherwise allow an existing symlink to redirect a converter-owned write. -/
private def writeNewTextFile (path : System.FilePath) (content : String) : IO Unit := do
  let handle ← IO.FS.Handle.mk path .writeNew
  handle.putStr content
  handle.flush

private inductive SidecarCommitPhase where
  | staged
  | mainHidden
  | originalsQuarantined
  | candidateSidecarsVisible
  | committed
  deriving BEq, Repr

private inductive SidecarRollbackPoint where
  | quarantineCandidate
  | restoreSidecars
  | restoreMain
  | cleanupStages
  deriving BEq, Repr

/-- Fault injection is reachable only from the in-module IO regression. -/
private structure SidecarFaultInjection where
  failCommitAt : Option SidecarCommitPhase := none
  failRollbackAt : Option SidecarRollbackPoint := none
  failPostCommitCleanup : Bool := false

structure SidecarPublishSuccess where
  warnings : List String := []

private def sidecarCommitFault? (fault : SidecarFaultInjection)
    (phase : SidecarCommitPhase) : Option String :=
  if fault.failCommitAt == some phase then
    some s!"injected commit failure at {reprStr phase}"
  else none

private def sidecarRollbackFault? (fault : SidecarFaultInjection)
    (point : SidecarRollbackPoint) : Option String :=
  if fault.failRollbackAt == some point then
    some s!"injected rollback failure at {reprStr point}"
  else none

private def renameIntoAbsent (source destination : System.FilePath)
    (operation : String) : IO (Except String Unit) := do
  match ← sidecarPathType? destination with
  | .error error => pure (.error s!"{operation}: {error}")
  | .ok (some kind) =>
      pure (.error s!"{operation}: destination '{destination}' is already a {sidecarFileTypeName kind}")
  | .ok none =>
      try
        IO.FS.rename source destination
        pure (.ok ())
      catch error =>
        pure (.error s!"{operation}: cannot rename '{source}' to '{destination}': {error}")

private def sidecarOutputNames (children : List SidecarChildOutput) : List String :=
  children.flatMap (fun child => [
    child.transcriptPath.fileName.getD child.transcriptPath.toString,
    child.metadataPath.fileName.getD child.metadataPath.toString])

private structure SidecarRollbackReport where
  priorOutputsSafe : Bool
  restorationErrors : List String
  cleanupErrors : List String

private def rollbackSidecarBundle (path subDir mainStage sidecarStage mainBackup
    sidecarBackup : System.FilePath) (hadMain hadSidecars : Bool)
    (phase : SidecarCommitPhase) (fault : SidecarFaultInjection) :
    IO SidecarRollbackReport := do
  let mainWasHidden := phase != .staged
  let sidecarsWereQuarantined :=
    phase == .originalsQuarantined || phase == .candidateSidecarsVisible
  let candidateWasInstalled := phase == .candidateSidecarsVisible
  let mut restorationErrors : List String := []
  let mut sidecarsReady := true

  -- Move the candidate generation out of view before restoring old sidecars.
  if candidateWasInstalled then
    match sidecarRollbackFault? fault .quarantineCandidate with
    | some error =>
        restorationErrors := error :: restorationErrors
        sidecarsReady := false
    | none =>
        match ← renameIntoAbsent subDir sidecarStage "cannot quarantine candidate sidecars" with
        | .ok _ => pure ()
        | .error error =>
            restorationErrors := error :: restorationErrors
            sidecarsReady := false

  if sidecarsReady && sidecarsWereQuarantined && hadSidecars then
    match sidecarRollbackFault? fault .restoreSidecars with
    | some error =>
        restorationErrors := error :: restorationErrors
        sidecarsReady := false
    | none =>
        match ← renameIntoAbsent sidecarBackup subDir "cannot restore prior sidecars" with
        | .ok _ => pure ()
        | .error error =>
            restorationErrors := error :: restorationErrors
            sidecarsReady := false

  -- The old main marker is restored only after matching sidecars are ready.
  if mainWasHidden && hadMain then
    if sidecarsReady then
      match sidecarRollbackFault? fault .restoreMain with
      | some error => restorationErrors := error :: restorationErrors
      | none =>
          match ← renameIntoAbsent mainBackup path "cannot restore prior main marker" with
          | .ok _ => pure ()
          | .error error => restorationErrors := error :: restorationErrors
    else
      restorationErrors :=
        "prior main marker intentionally remains hidden because sidecar restoration is incomplete" ::
          restorationErrors

  let finalRestorationErrors := restorationErrors.reverse
  let mut cleanupErrors : List String := []
  if finalRestorationErrors.isEmpty then
    match sidecarRollbackFault? fault .cleanupStages with
    | some error => cleanupErrors := [error]
    | none => cleanupErrors ← removeOwnedPathsChecked [mainStage, sidecarStage]
  pure {
    priorOutputsSafe := finalRestorationErrors.isEmpty
    restorationErrors := finalRestorationErrors
    cleanupErrors := cleanupErrors
  }

private def appendSidecarDiagnostics (message label : String) (errors : List String) : String :=
  if errors.isEmpty then message
  else s!"{message}; {label}: {String.intercalate "; " errors}"

private def sidecarReservedPaths (path subDir : System.FilePath) : List System.FilePath := [
  path.toString ++ ".agent-convert-stage",
  subDir.toString ++ ".agent-convert-stage",
  path.toString ++ ".agent-convert-backup",
  subDir.toString ++ ".agent-convert-backup"]

/-- All target candidates are rendered and checked before this function runs.

Publication is an ordered multi-path protocol, not an OS-level transaction:
the prior main marker is hidden first, sidecars are swapped while no main marker
is visible, and the candidate main is renamed into place last. Thus a returned
success exposes a matching candidate generation, and rollback restores the old
main only after old sidecars are back. A crash before the final rename can leave
the main absent plus converter stage/backup paths; a crash after it can leave a
complete new generation plus stale backups. The next run refuses either stale
state without deleting it. This ordering assumes other writers honor the same
reserved paths; it does not promise cross-path atomicity, power-loss durability,
or safety against a non-cooperating process mutating destinations concurrently. -/
private def writeSidecarBundle (family : String) (path : System.FilePath) (output : String)
    (subDir : System.FilePath) (children : List SidecarChildOutput)
    (fault : SidecarFaultInjection) :
    IO (Except String SidecarPublishSuccess) := do
  let mainStage : System.FilePath := path.toString ++ ".agent-convert-stage"
  let sidecarStage : System.FilePath := subDir.toString ++ ".agent-convert-stage"
  let mainBackup : System.FilePath := path.toString ++ ".agent-convert-backup"
  let sidecarBackup : System.FilePath := subDir.toString ++ ".agent-convert-backup"
  let reserved := sidecarReservedPaths path subDir
  let expectedNames := sidecarOutputNames children
  let mut stale : List String := []
  for reservedPath in reserved do
    match ← sidecarPathType? reservedPath with
    | .error error => return .error error
    | .ok none => pure ()
    | .ok (some kind) =>
        stale := s!"{reservedPath} ({sidecarFileTypeName kind})" :: stale
  if !stale.isEmpty then
    return .error s!"refusing {family} sidecar export: stale converter stage/backup state exists and will not be recovered or deleted automatically: {String.intercalate ", " stale.reverse}"

  let initialMainType ← match ← sidecarPathType? path with
    | .ok kind => pure kind
    | .error error => return .error error
  match initialMainType with
  | some .file | none => pure ()
  | some kind =>
      return .error s!"refusing {family} sidecar export: main output '{path}' is a {sidecarFileTypeName kind}"
  match ← ensureExpectedSidecarDirectory family subDir expectedNames with
  | .ok _ => pure ()
  | .error error => return .error error
  let initialSidecarType ← match ← sidecarPathType? subDir with
    | .ok kind => pure kind
    | .error error => return .error error
  let hadMain := initialMainType.isSome
  let hadSidecars := initialSidecarType.isSome

  try
    if let some parent := sidecarStage.parent then IO.FS.createDirAll parent
    IO.FS.createDir sidecarStage
    writeNewTextFile mainStage output
    for child in children do
      let transcriptName := child.transcriptPath.fileName.getD
        child.transcriptPath.toString
      let metadataName := child.metadataPath.fileName.getD
        child.metadataPath.toString
      writeNewTextFile (sidecarStage / transcriptName) child.transcriptText
      writeNewTextFile (sidecarStage / metadataName) child.metadataText
  catch error =>
    let cleanupErrors ← removeOwnedPathsChecked [mainStage, sidecarStage]
    return .error (appendSidecarDiagnostics
      s!"cannot stage {family} sidecar export: {error}"
      "converter-owned staging cleanup failed" cleanupErrors)

  -- Close the render/preflight race for cooperating writers immediately before
  -- the first rename. No destination has been mutated at this point.
  match ← ensureExpectedSidecarDirectory family subDir expectedNames with
  | .error error =>
      let cleanupErrors ← removeOwnedPathsChecked [mainStage, sidecarStage]
      return .error (appendSidecarDiagnostics
        s!"refusing {family} publication because sidecar ownership changed before commit: {error}"
        "converter-owned staging cleanup failed" cleanupErrors)
  | .ok _ => pure ()
  let currentMainType ← match ← sidecarPathType? path with
    | .ok kind => pure kind
    | .error error =>
        let cleanupErrors ← removeOwnedPathsChecked [mainStage, sidecarStage]
        return .error (appendSidecarDiagnostics error
          "converter-owned staging cleanup failed" cleanupErrors)
  let currentSidecarType ← match ← sidecarPathType? subDir with
    | .ok kind => pure kind
    | .error error =>
        let cleanupErrors ← removeOwnedPathsChecked [mainStage, sidecarStage]
        return .error (appendSidecarDiagnostics error
          "converter-owned staging cleanup failed" cleanupErrors)
  if currentMainType != initialMainType || currentSidecarType != initialSidecarType then
    let cleanupErrors ← removeOwnedPathsChecked [mainStage, sidecarStage]
    return .error (appendSidecarDiagnostics
      s!"refusing {family} publication because destination presence/type changed before commit"
      "converter-owned staging cleanup failed" cleanupErrors)

  let phaseRef ← IO.mkRef SidecarCommitPhase.staged
  let commitResult ← (do
    if hadMain then
      match ← renameIntoAbsent path mainBackup "cannot hide prior main marker" with
      | .error error => return .error error
      | .ok _ => pure ()
    phaseRef.set .mainHidden
    if let some error := sidecarCommitFault? fault .mainHidden then return .error error

    if hadSidecars then
      match ← renameIntoAbsent subDir sidecarBackup "cannot quarantine prior sidecars" with
      | .error error => return .error error
      | .ok _ => pure ()
    phaseRef.set .originalsQuarantined
    if let some error := sidecarCommitFault? fault .originalsQuarantined then
      return .error error

    match ← renameIntoAbsent sidecarStage subDir "cannot install candidate sidecars" with
    | .error error => return .error error
    | .ok _ => pure ()
    phaseRef.set .candidateSidecarsVisible
    if let some error := sidecarCommitFault? fault .candidateSidecarsVisible then
      return .error error

    match ← renameIntoAbsent mainStage path "cannot publish candidate main marker" with
    | .error error => return .error error
    | .ok _ => pure ()
    phaseRef.set .committed
    pure (.ok ()) : IO (Except String Unit))
  let phase ← phaseRef.get

  match commitResult with
  | .ok _ =>
      let cleanupErrors ← if fault.failPostCommitCleanup then
        pure ["injected post-commit backup cleanup failure"]
      else
        removeOwnedPathsChecked [mainBackup, sidecarBackup]
      let warnings := if cleanupErrors.isEmpty then [] else [
        s!"{family} sidecar publication succeeded with a matching main/sidecar generation, but prior backup cleanup was not completed; backup paths remain or require inspection: {String.intercalate "; " cleanupErrors}"]
      pure (.ok { warnings := warnings })
  | .error commitError =>
      let report ← rollbackSidecarBundle path subDir mainStage sidecarStage mainBackup
        sidecarBackup hadMain hadSidecars phase fault
      let recoveryPaths := String.intercalate ", "
        (reserved.map (fun reservedPath => reservedPath.toString))
      if report.priorOutputsSafe then
        let preservation := if phase == .staged then
          "prior outputs were not mutated"
        else
          "prior outputs were restored"
        let message := s!"cannot commit {family} sidecar export at {reprStr phase}: {commitError}; {preservation}"
        pure (.error (appendSidecarDiagnostics message
          "converter-owned staging cleanup failed" report.cleanupErrors))
      else
        pure (.error s!"cannot commit {family} sidecar export at {reprStr phase}: {commitError}; rollback incomplete: {String.intercalate "; " report.restorationErrors}; no candidate main marker was published by this invocation, and recovery paths were preserved for inspection: {recoveryPaths}")

/-! ## Sidecar publication IO regression -/

private def sidecarTestContains (text needle : String) : Bool :=
  decide ((text.splitOn needle).length > 1)

private def sidecarTestAssert (condition : Bool) (message : String) : IO Unit := do
  if !condition then throw (IO.userError message)

private def sidecarTestExpectError {α : Type} (result : Except String α) (needles : List String) :
    IO String := do
  match result with
  | .ok _ => throw (IO.userError "sidecar regression expected failure, but publication succeeded")
  | .error error =>
      for needle in needles do
        sidecarTestAssert (sidecarTestContains error needle)
          s!"sidecar regression error omitted '{needle}': {error}"
      pure error

private def sidecarTestAssertFile (path : System.FilePath) (expected : String) : IO Unit := do
  let actual ← IO.FS.readFile path
  sidecarTestAssert (actual == expected)
    s!"sidecar regression changed '{path}': expected {reprStr expected}, got {reprStr actual}"

private def sidecarTestAssertAbsent (path : System.FilePath) : IO Unit := do
  match ← sidecarPathType? path with
  | .ok none => pure ()
  | .ok (some kind) =>
      throw (IO.userError s!"sidecar regression expected '{path}' to be absent, found {sidecarFileTypeName kind}")
  | .error error => throw (IO.userError error)

private def sidecarTestAssertType (path : System.FilePath) (expected : IO.FS.FileType) :
    IO Unit := do
  match ← sidecarPathType? path with
  | .ok (some actual) =>
      sidecarTestAssert (actual == expected)
        s!"sidecar regression expected '{path}' to be {sidecarFileTypeName expected}, found {sidecarFileTypeName actual}"
  | .ok none => throw (IO.userError s!"sidecar regression expected '{path}' to exist")
  | .error error => throw (IO.userError error)

private def sidecarTestChildren (subDir : System.FilePath) (stem : String) :
    List SidecarChildOutput := [{
  transcriptPath := subDir / s!"{stem}-0001.jsonl"
  transcriptText := "candidate-child\n"
  metadataPath := subDir / s!"{stem}-0001.meta.json"
  metadataText := "candidate-metadata\n"
}]

private def sidecarTestSubDir (family : String) (mainPath : System.FilePath) :
    System.FilePath :=
  if family == "Claude" then claudeSubagentsDir mainPath else cursorSubagentsDir mainPath

private def sidecarTestPreparePrior (mainPath subDir : System.FilePath)
    (children : List SidecarChildOutput) : IO Unit := do
  if let some parent := mainPath.parent then IO.FS.createDirAll parent
  IO.FS.writeFile mainPath "prior-main\n"
  IO.FS.createDirAll subDir
  for child in children do
    IO.FS.writeFile child.transcriptPath "prior-child\n"
    IO.FS.writeFile child.metadataPath "prior-metadata\n"

private def sidecarTestAssertPrior (mainPath : System.FilePath)
    (children : List SidecarChildOutput) : IO Unit := do
  sidecarTestAssertFile mainPath "prior-main\n"
  for child in children do
    sidecarTestAssertFile child.transcriptPath "prior-child\n"
    sidecarTestAssertFile child.metadataPath "prior-metadata\n"

private def sidecarTestAssertCandidate (mainPath : System.FilePath)
    (children : List SidecarChildOutput) : IO Unit := do
  sidecarTestAssertFile mainPath "candidate-main\n"
  for child in children do
    sidecarTestAssertFile child.transcriptPath child.transcriptText
    sidecarTestAssertFile child.metadataPath child.metadataText

private def sidecarTestAssertReservedAbsent (mainPath subDir : System.FilePath) : IO Unit := do
  for path in sidecarReservedPaths mainPath subDir do
    sidecarTestAssertAbsent path

private def sidecarTestCreateSymlink (target link : System.FilePath) : IO Bool := do
  if System.Platform.isWindows then
    pure false
  else
    try
      let output ← IO.Process.output {
        cmd := "/bin/ln"
        args := #["-s", target.toString, link.toString]
      }
      pure (output.exitCode == 0)
    catch _ => pure false

private def runSidecarOwnershipIoTests (root : System.FilePath) : IO Unit := do
  for (family, stem) in [("Claude", "agent"), ("Cursor Agent", "child")] do
    let tag := if family == "Claude" then "claude" else "cursor"

    let fileMain := root / s!"{tag}-unrelated-file" / "root.jsonl"
    let fileSubDir := sidecarTestSubDir family fileMain
    let fileChildren := sidecarTestChildren fileSubDir stem
    sidecarTestPreparePrior fileMain fileSubDir fileChildren
    let unrelated := fileSubDir / "README.keep"
    IO.FS.writeFile unrelated "unowned\n"
    let fileResult ← writeSidecarBundle family fileMain "candidate-main\n"
      fileSubDir fileChildren {}
    let _ ← sidecarTestExpectError fileResult ["contains unowned entries", "README.keep"]
    sidecarTestAssertPrior fileMain fileChildren
    sidecarTestAssertFile unrelated "unowned\n"
    sidecarTestAssertReservedAbsent fileMain fileSubDir

    let dirMain := root / s!"{tag}-nested-directory" / "root.jsonl"
    let dirSubDir := sidecarTestSubDir family dirMain
    let dirChildren := sidecarTestChildren dirSubDir stem
    sidecarTestPreparePrior dirMain dirSubDir dirChildren
    let nested := dirSubDir / "nested-unowned"
    IO.FS.createDirAll nested
    IO.FS.writeFile (nested / "keep.txt") "nested-unowned\n"
    let dirResult ← writeSidecarBundle family dirMain "candidate-main\n"
      dirSubDir dirChildren {}
    let _ ← sidecarTestExpectError dirResult
      ["contains unowned entries", "nested-unowned", "directory"]
    sidecarTestAssertPrior dirMain dirChildren
    sidecarTestAssertFile (nested / "keep.txt") "nested-unowned\n"
    sidecarTestAssertReservedAbsent dirMain dirSubDir

    let linkMain := root / s!"{tag}-symlink" / "root.jsonl"
    let linkSubDir := sidecarTestSubDir family linkMain
    let linkChildren := sidecarTestChildren linkSubDir stem
    sidecarTestPreparePrior linkMain linkSubDir linkChildren
    let expectedLink := (linkChildren.head?).map (·.transcriptPath)
    match expectedLink with
    | none => throw (IO.userError "sidecar symlink regression has no expected child")
    | some link =>
        IO.FS.removeFile link
        let target := linkMain.parent.getD root / "symlink-target.txt"
        IO.FS.writeFile target "outside-sidecar-entry\n"
        if ← sidecarTestCreateSymlink target link then
          let linkResult ← writeSidecarBundle family linkMain "candidate-main\n"
            linkSubDir linkChildren {}
          let _ ← sidecarTestExpectError linkResult
            ["contains unowned entries", "symbolic link", "expected a regular file"]
          sidecarTestAssertFile linkMain "prior-main\n"
          sidecarTestAssertType link .symlink
          sidecarTestAssertFile target "outside-sidecar-entry\n"
          sidecarTestAssertReservedAbsent linkMain linkSubDir
        else
          IO.println s!"sidecar publication IO regression: symlink case skipped for {family}"

private def runSidecarStaleStateIoTests (root : System.FilePath) : IO Unit := do
  for (family, stem) in [("Claude", "agent"), ("Cursor Agent", "child")] do
    let tag := if family == "Claude" then "claude" else "cursor"
    for (_, ordinal) in [0, 1, 2, 3].zipIdx do
      let mainPath := root / s!"{tag}-stale-{ordinal}" / "root.jsonl"
      let subDir := sidecarTestSubDir family mainPath
      let children := sidecarTestChildren subDir stem
      sidecarTestPreparePrior mainPath subDir children
      let reserved := sidecarReservedPaths mainPath subDir
      let stalePath ← match reserved[ordinal]? with
        | some path => pure path
        | none => throw (IO.userError s!"missing reserved-path regression index {ordinal}")
      IO.FS.writeFile stalePath "stale-state-must-survive\n"
      let result ← writeSidecarBundle family mainPath "candidate-main\n" subDir children {}
      let _ ← sidecarTestExpectError result
        ["stale converter stage/backup state", "will not be recovered or deleted automatically"]
      sidecarTestAssertPrior mainPath children
      sidecarTestAssertFile stalePath "stale-state-must-survive\n"

private def runSidecarCommitIoTests (root : System.FilePath) : IO Unit := do
  let family := "Claude"
  let stem := "agent"
  for (phase, ordinal) in [
      SidecarCommitPhase.mainHidden,
      .originalsQuarantined,
      .candidateSidecarsVisible].zipIdx do
    let mainPath := root / s!"commit-rollback-{ordinal}" / "root.jsonl"
    let subDir := sidecarTestSubDir family mainPath
    let children := sidecarTestChildren subDir stem
    sidecarTestPreparePrior mainPath subDir children
    let result ← writeSidecarBundle family mainPath "candidate-main\n" subDir children
      { failCommitAt := some phase }
    let _ ← sidecarTestExpectError result
      ["injected commit failure", "prior outputs were restored"]
    sidecarTestAssertPrior mainPath children
    sidecarTestAssertReservedAbsent mainPath subDir

  let cleanupMain := root / "rollback-cleanup-failure" / "root.jsonl"
  let cleanupSubDir := sidecarTestSubDir family cleanupMain
  let cleanupChildren := sidecarTestChildren cleanupSubDir stem
  sidecarTestPreparePrior cleanupMain cleanupSubDir cleanupChildren
  let cleanupResult ← writeSidecarBundle family cleanupMain "candidate-main\n"
    cleanupSubDir cleanupChildren {
      failCommitAt := some .candidateSidecarsVisible
      failRollbackAt := some .cleanupStages
    }
  let _ ← sidecarTestExpectError cleanupResult
    ["prior outputs were restored", "staging cleanup failed", "injected rollback failure"]
  sidecarTestAssertPrior cleanupMain cleanupChildren
  sidecarTestAssertType (cleanupMain.toString ++ ".agent-convert-stage") .file
  sidecarTestAssertType (cleanupSubDir.toString ++ ".agent-convert-stage") .dir

  let quarantineMain := root / "rollback-quarantine-failure" / "root.jsonl"
  let quarantineSubDir := sidecarTestSubDir family quarantineMain
  let quarantineChildren := sidecarTestChildren quarantineSubDir stem
  sidecarTestPreparePrior quarantineMain quarantineSubDir quarantineChildren
  let quarantineResult ← writeSidecarBundle family quarantineMain "candidate-main\n"
    quarantineSubDir quarantineChildren {
      failCommitAt := some .candidateSidecarsVisible
      failRollbackAt := some .quarantineCandidate
    }
  let _ ← sidecarTestExpectError quarantineResult
    ["rollback incomplete", "no candidate main marker was published", "intentionally remains hidden"]
  sidecarTestAssertAbsent quarantineMain
  sidecarTestAssertCandidate
    (quarantineMain.toString ++ ".agent-convert-stage") quarantineChildren
  sidecarTestAssertFile (quarantineMain.toString ++ ".agent-convert-backup") "prior-main\n"
  let quarantineSidecarBackup : System.FilePath :=
    quarantineSubDir.toString ++ ".agent-convert-backup"
  sidecarTestAssertFile
    (quarantineSidecarBackup / "agent-0001.jsonl")
    "prior-child\n"

  let restoreMain := root / "rollback-main-restore-failure" / "root.jsonl"
  let restoreSubDir := sidecarTestSubDir family restoreMain
  let restoreChildren := sidecarTestChildren restoreSubDir stem
  sidecarTestPreparePrior restoreMain restoreSubDir restoreChildren
  let restoreResult ← writeSidecarBundle family restoreMain "candidate-main\n"
    restoreSubDir restoreChildren {
      failCommitAt := some .candidateSidecarsVisible
      failRollbackAt := some .restoreMain
    }
  let _ ← sidecarTestExpectError restoreResult
    ["rollback incomplete", "no candidate main marker was published", "restoreMain"]
  sidecarTestAssertAbsent restoreMain
  for child in restoreChildren do
    sidecarTestAssertFile child.transcriptPath "prior-child\n"
    sidecarTestAssertFile child.metadataPath "prior-metadata\n"
  sidecarTestAssertFile (restoreMain.toString ++ ".agent-convert-backup") "prior-main\n"
  sidecarTestAssertType (restoreSubDir.toString ++ ".agent-convert-stage") .dir

  let warningMain := root / "post-commit-cleanup-warning" / "root.jsonl"
  let warningSubDir := sidecarTestSubDir family warningMain
  let warningChildren := sidecarTestChildren warningSubDir stem
  sidecarTestPreparePrior warningMain warningSubDir warningChildren
  let warningResult ← writeSidecarBundle family warningMain "candidate-main\n"
    warningSubDir warningChildren { failPostCommitCleanup := true }
  let warnings ← match warningResult with
    | .error error =>
        throw (IO.userError s!"post-commit cleanup regression returned failed export: {error}")
    | .ok success => pure success.warnings
  sidecarTestAssert (warnings.length == 1)
    s!"post-commit cleanup regression expected one warning, got {reprStr warnings}"
  let warning := warnings.head?.getD ""
  sidecarTestAssert (sidecarTestContains warning "publication succeeded")
    s!"post-commit cleanup warning did not report successful publication: {warning}"
  sidecarTestAssert (sidecarTestContains warning "backup cleanup was not completed")
    s!"post-commit cleanup warning claimed cleanup completion: {warning}"
  sidecarTestAssert (sidecarTestContains warning "backup paths remain or require inspection")
    s!"post-commit cleanup warning did not preserve backup uncertainty: {warning}"
  sidecarTestAssertCandidate warningMain warningChildren
  sidecarTestAssertFile (warningMain.toString ++ ".agent-convert-backup") "prior-main\n"
  let warningSidecarBackup : System.FilePath :=
    warningSubDir.toString ++ ".agent-convert-backup"
  sidecarTestAssertFile (warningSidecarBackup / "agent-0001.jsonl") "prior-child\n"
  sidecarTestAssertAbsent (warningMain.toString ++ ".agent-convert-stage")
  sidecarTestAssertAbsent (warningSubDir.toString ++ ".agent-convert-stage")

  let successMain := root / "successful-replacement" / "root.jsonl"
  let successSubDir := sidecarTestSubDir family successMain
  let successChildren := sidecarTestChildren successSubDir stem
  sidecarTestPreparePrior successMain successSubDir successChildren
  match ← writeSidecarBundle family successMain "candidate-main\n" successSubDir
      successChildren {} with
  | .error error => throw (IO.userError s!"successful sidecar regression failed: {error}")
  | .ok _ => pure ()
  sidecarTestAssertCandidate successMain successChildren
  sidecarTestAssertReservedAbsent successMain successSubDir

/-- Executable filesystem regression for the multi-path publication contract.
This command uses a secure temporary directory and never touches user paths. -/
def runSidecarPublicationSelfTest : IO UInt32 := do
  try
    IO.FS.withTempDir fun root => do
      runSidecarOwnershipIoTests root
      runSidecarStaleStateIoTests root
      runSidecarCommitIoTests root
    IO.println "sidecar publication IO regressions: pass"
    pure 0
  catch error =>
    IO.eprintln s!"sidecar publication IO regressions: FAIL: {error}"
    pure 1

private def exportClaudeSidecar (path : System.FilePath) (t : Transcript) :
    IO (Except String SidecarPublishSuccess) := do
  let children ← match prepareSidecarThreads t with
    | .error error => return .error error
    | .ok prepared => pure prepared
  let agentIds := children.zipIdx.map (fun p => s!"agent-{pad4 (p.2 + 1)}")
  let subDir := claudeSubagentsDir path
  match ← ensureNoExtraClaudeSidecars subDir agentIds with
  | .error e => pure (.error e)
  | .ok _ => do
      let prepared : Except String (String × List SidecarChildOutput) := do
          let mainProjection := projectThread t (mainThreadIndex t)
          let mainOutput ← exportClaudeCodeChecked mainProjection
          let childOutputs ← children.zipIdx.mapM (fun p => do
            let child := p.1
            let ordinal := p.2
            let agentId := s!"agent-{pad4 (ordinal + 1)}"
            let threadIdx := child.threadIdx
            let th := child.sourceThread
            let childOutput ← exportClaudeCodeChecked (projectThread t threadIdx)
            let toolUseId :=
              match th.kind with
              | ThreadKind.sidechain anchor => callRefToolUseId t anchor
              | _ => none
            let nativeAnchor := match child.metadataThread.kind with
              | .sidechain (.resolved entry block) =>
                  claudeToolCallEmitsNativeAt mainProjection entry block
              | _ => false
            let globalActive := threadHasActiveLeaf t threadIdx
            pure {
              transcriptPath := subDir / s!"{agentId}.jsonl"
              transcriptText := childOutput
              metadataPath := subDir / s!"{agentId}.meta.json"
              metadataText :=
                (claudeMetaJson agentId child.metadataThread toolUseId globalActive
                  nativeAnchor).compress })
          pure (mainOutput, childOutputs)
      match prepared with
      | .error error => pure (.error s!"Claude sidecar target validation failed: {error}")
      | .ok (mainOutput, childOutputs) =>
          writeSidecarBundle "Claude" path mainOutput subDir childOutputs {}

private def exportCursorAgentSidecar (path : System.FilePath) (t : Transcript) :
    IO (Except String SidecarPublishSuccess) := do
  let children ← match prepareSidecarThreads t with
    | .error error => return .error error
    | .ok prepared => pure prepared
  let childIds := children.zipIdx.map (fun p => s!"child-{pad4 (p.2 + 1)}")
  let subDir := cursorSubagentsDir path
  match ← ensureNoExtraCursorSidecars subDir childIds with
  | .error e => pure (.error e)
  | .ok _ => do
      let prepared : Except String (String × List SidecarChildOutput) := do
        let mainOutput ← LoomConvert.exportCursorAgentTargetChecked
          (projectThread t (mainThreadIndex t))
        let childOutputs ← children.zipIdx.mapM (fun p => do
          let child := p.1
          let ordinal := p.2
          let childId := s!"child-{pad4 (ordinal + 1)}"
          let threadIdx := child.threadIdx
          let th := child.sourceThread
          let childOutput ← LoomConvert.exportCursorAgentTargetChecked
            (projectThread t threadIdx)
          let toolUseId := match th.kind with
            | .sidechain anchor => callRefToolUseId t anchor
            | _ => none
          let globalActive := threadHasActiveLeaf t threadIdx
          pure {
            transcriptPath := subDir / s!"{childId}.jsonl"
            transcriptText := childOutput
            metadataPath := subDir / s!"{childId}.meta.json"
            metadataText :=
              (cursorMetaJson child.metadataThread toolUseId globalActive).compress })
        pure (mainOutput, childOutputs)
      match prepared with
      | .error error => pure (.error s!"Cursor Agent sidecar target validation failed: {error}")
      | .ok (mainOutput, childOutputs) =>
          writeSidecarBundle "Cursor Agent" path mainOutput subDir childOutputs {}

def exportSidecarByFormat (toFmt : String) (path : System.FilePath) (t : Transcript) :
    IO (Except String SidecarPublishSuccess) := do
  try
    match toFmt with
    | "claude" => exportClaudeSidecar path t
    | "cursor-agent" => exportCursorAgentSidecar path t
    | _ => pure (.error s!"target '{toFmt}' has no sidecar exporter")
  catch error =>
    pure (.error s!"sidecar export failed: {error}")

def sidecarProjectionBlocker? (toFmt : String) (t : Transcript) : Option String :=
  if t.activeLeaf.isNone then
    some "sidecar export requires a recorded active leaf so re-import cannot fabricate an active path"
  else
    let anchorSites := t.threads.toList.filterMap (fun thread =>
      match thread.kind with
      | .sidechain (.resolved entry block) => some (entry, block)
      | _ => none)
    let threadIdxs := (mainThreadIndex t) :: (nonMainThreadInfos t).map (·.1)
    let rec firstBlocker : List Nat → Option String
      | [] => none
      | threadIdx :: rest =>
          let projected := projectThread t threadIdx
          let hasUnsafeOpenCall := (Loom.Ops.openCalls t).any (fun site =>
            match t.entries[site.1]? with
            | some entry => entry.thread == threadIdx && !anchorSites.contains site
            | none => true)
          match formatByCliName? toFmt with
          | none => firstBlocker rest
          | some target =>
              let destructive := (Loom.Ops.obligations target projected).filter
                (fun obligation =>
                  match obligation with
                  | .closeOpenToolCalls _ => hasUnsafeOpenCall
                  | other => Loom.Ops.obligationIsDestructiveFor target projected other)
              if !destructive.isEmpty then
                some s!"thread {threadIdx}: target '{toFmt}' has destructive export obligations: {reprStr destructive} — refusing silent loss"
              else
                match targetValidityBlocker? toFmt projected with
                | some blocker => some s!"thread {threadIdx}: {blocker}"
                | none => firstBlocker rest
    firstBlocker threadIdxs

def writeOutputText (path output : String) : IO (Except String Unit) := do
  let destination : System.FilePath := path
  let stage : System.FilePath := path ++ ".agent-convert-stage"
  if ← stage.pathExists then
    return .error s!"cannot write '{path}': converter staging path already exists: {stage}"
  if (← destination.pathExists) && (← destination.isDir) then
    return .error s!"cannot write '{path}': destination is a directory"
  try
    writeNewTextFile stage output
    IO.FS.rename stage destination
    pure (.ok ())
  catch error =>
    cleanupOwnedPath stage
    pure (.error s!"cannot write '{path}': {error}")

end LoomConvert.Cli
