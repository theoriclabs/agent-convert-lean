import LoomConvert
import LoomOps.Conversion
import Loom.Render
import Loom.Text
import Loom.BuildOptions

/-!
# `lake exe loom` — the conversion CLI

The user-facing entry point of the Lean port: `loom convert <from> <to>
<input> [output]`. Pure Lean — file IO for the JSONL/JSON formats, the
`sqlite3` subprocess for Cursor IDE. This is the "kill TS" tool actually
running end to end.
-/

open Loom LoomConvert

/-- CLI source/target string → format row, for export-readiness checks. -/
def formatByCliName? (fmt : String) : Option Format :=
  match fmt with
  | "pi"                        => some .pi
  | "claude"                    => some .claudeCode
  | "codex"                     => some .codexCli
  | "cursor-agent"              => some .cursorAgent
  | "hermes"                    => some .hermes
  | "gais" | "google-ai-studio" => some .googleAiStudio
  | "cursor-ide"                => some .cursorIde
  | "opencode"                  => some .openCode
  | _                           => none

/-- Single-file flat exporters write only the main thread. Sidechain/detached
threads are preserved by the `loom` wire target, not by these flat targets. -/
def hasNonMainThreads (t : Transcript) : Bool :=
  t.threads.toList.any (fun th =>
    match th.kind with
    | ThreadKind.main => false
    | _ => true)

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

private def sidecarTarget (toFmt : String) : Bool :=
  toFmt == "claude" || toFmt == "cursor-agent"

/-- Targets that can retain sidechain/detached threads without flattening. -/
private def preservesSubagentThreads (toFmt : String) : Bool :=
  toFmt == "loom" || sidecarTarget toFmt

/-- Subagent sidecars are on by default for inspect and for targets that can
keep threads. Flat exporters (pi/codex) stay main-branch unless
`--with-subagents` is explicit — otherwise real Claude sessions would refuse. -/
private def resolveWithSubagents (toFmt? : Option String) (flag : Option Bool) : Bool :=
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

private structure SidecarPublishSuccess where
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
private def runSidecarPublicationSelfTest : IO UInt32 := do
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

private def exportSidecarByFormat (toFmt : String) (path : System.FilePath) (t : Transcript) :
    IO (Except String SidecarPublishSuccess) := do
  try
    match toFmt with
    | "claude" => exportClaudeSidecar path t
    | "cursor-agent" => exportCursorAgentSidecar path t
    | _ => pure (.error s!"target '{toFmt}' has no sidecar exporter")
  catch error =>
    pure (.error s!"sidecar export failed: {error}")

private def targetValidityBlocker? (toFmt : String) (t : Transcript) : Option String :=
  let failure? := match toFmt with
    | "pi" => match piExportPreflight t with
      | .ok _ => none
      | .error error => some error
    | "claude" => match claudeExportPreflight t with
      | .ok _ => none
      | .error error => some error
    | "codex" => (codexTargetExportPrerequisiteFailures t).head?
    | "cursor-agent" => match LoomConvert.exportCursorAgentTargetChecked t with
      | .ok _ => none
      | .error error => some error
    | "opencode" => (openCodeTargetExportPrerequisiteFailures t).head?
    | _ => none
  failure?.map (fun error => s!"target '{toFmt}' validity preflight failed: {error}")

/-- Losses that the current executable refuses rather than silently flattening.
Stable/default flat-export scope is mainline-only: even targets whose broader
format can store sidechains need a multi-file/sidecar exporter before this CLI
can promise native resumable sidechain output. -/
def exportBlocker? (toFmt : String) (t : Transcript) : Option String :=
  if toFmt == "loom" then
    none
  else if hasNonMainThreads t then
    some "single-file flat exporter does not preserve sidechain/detached thread metadata — refusing silent flattening; use `loom` or an explicit sidecar export"
  else
    match formatByCliName? toFmt with
    | none => none
    | some target =>
      let destructive := (Loom.Ops.obligations target t).filter
        (Loom.Ops.obligationIsDestructiveFor target t)
      let semanticBlocker := if destructive.isEmpty then none
        else some s!"target '{toFmt}' has destructive export obligations: {reprStr destructive} — refusing silent loss; use the loom wire target to preserve the full transcript"
      semanticBlocker.orElse (fun _ => targetValidityBlocker? toFmt t)

private def sidecarProjectionBlocker? (toFmt : String) (t : Transcript) : Option String :=
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

/-- Source format → Loom IR. Every importer the fan-out produced. -/
def importByFormat (fmt text : String) : Except String Transcript :=
  match fmt with
  | "loom"                      => importLoomWire text
  | "pi"                        => importPi text
  | "claude"                    => importClaudeCode text
  | "codex"                     => importCodexCli text
  | "cursor-agent"              => importCursorAgent text
  | "hermes"                    => importHermes text
  | "gais" | "google-ai-studio" => importGoogleAiStudio text
  | "cursor-ide"                => importCursorIde text  -- text = {composer,bubbles} JSON
  | "opencode"                  => importOpenCode text
  | _ => .error s!"unknown source format: {fmt}"

/-- Loom IR → target format text. `loom` is the versioned, thread-preserving
wire form; the others are flat harness targets. -/
def exportByFormat (fmt : String) (t : Transcript) : Except String String :=
  match fmt with
  | "pi"           => exportPiChecked t
  | "loom"         => .ok (exportLoomWire t)
  | "claude"       => exportClaudeCodeChecked t
  | "codex"        => exportCodexCliChecked t
  | "cursor-agent" => LoomConvert.exportCursorAgentTargetChecked t
  | "opencode"     => exportOpenCodeChecked t
  | _ => .error s!"no exporter for target '{fmt}' (exporters: loom, pi, claude, codex, cursor-agent, opencode)"

/-- Import → (well-formedness + hard export-obligation checks) → export. Refuses
to emit a structurally invalid IR, or a stitched sidechain transcript through a
flat exporter that would silently drop thread anchors. -/
def runPipeline (_fromFmt toFmt : String) (t : Transcript) : Except String String := do
  let vs := violations t
  if vs.length > 0 then
    .error s!"source imported to a malformed IR ({vs.length} violations) — refusing to export"
  else if let some blocker := exportBlocker? toFmt t then
    .error blocker
  else
    exportByFormat toFmt t

private def readInputText (path : String) : IO (Except String String) := do
  try
    pure (.ok (← IO.FS.readFile path))
  catch error =>
    pure (.error s!"cannot read '{path}': {error}")

private def writeOutputText (path output : String) : IO (Except String Unit) := do
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

def emit (out : String) (outp : Option String) (n : Nat) : IO UInt32 := do
  match outp with
  | some o =>
      match ← writeOutputText o out with
      | .error error => IO.eprintln s!"export error: {error}"; pure 3
      | .ok _ => IO.println s!"wrote {o} ({n} entries)"; pure 0
  | none   => IO.print out; pure 0

structure CliOptions where
  tsParity     : Bool := false
  /-- `none` = default policy (`resolveWithSubagents`); `some` = explicit flag. -/
  withSubagents : Option Bool := none
  json         : Bool := false
  cwd          : Option String := none
  provider     : Option String := none
  model        : Option String := none
  harnessVersion : Option String := none
  sessionId    : Option String := none
  targetTimestamp : Option String := none
  piAssistantHistory : Option String := none
  codexApprovalPolicy : Option String := none
  codexNetworkAccess : Option Bool := none
  codexExcludeTmpdirEnvVar : Option Bool := none
  codexExcludeSlashTmp : Option Bool := none
  codexSummary : Option String := none
  store        : Option String := none
  limit        : Option Nat := none
  role         : Option String := none

private def parseCliBool (option value : String) : Except String Bool :=
  if value == "true" then .ok true
  else if value == "false" then .ok false
  else .error s!"{option} requires 'true' or 'false', got '{value}'"

private def parseCli (args : List String) : Except String (CliOptions × List String) :=
  let rec loop (remaining : List String) (opts : CliOptions) (positional : List String) :=
    match remaining with
    | [] => .ok (opts, positional.reverse)
    | "--ts-parity" :: rest => loop rest { opts with tsParity := true } positional
    | "--with-subagents" :: rest => loop rest { opts with withSubagents := some true } positional
    | "--no-subagents" :: rest => loop rest { opts with withSubagents := some false } positional
    | "--json" :: rest => loop rest { opts with json := true } positional
    | "--cwd" :: value :: rest => loop rest { opts with cwd := some value } positional
    | "--target-cwd" :: value :: rest => loop rest { opts with cwd := some value } positional
    | "--provider" :: value :: rest => loop rest { opts with provider := some value } positional
    | "--target-provider" :: value :: rest =>
        loop rest { opts with provider := some value } positional
    | "--model" :: value :: rest => loop rest { opts with model := some value } positional
    | "--target-model" :: value :: rest =>
        loop rest { opts with model := some value } positional
    | "--harness-version" :: value :: rest =>
        loop rest { opts with harnessVersion := some value } positional
    | "--target-harness-version" :: value :: rest =>
        loop rest { opts with harnessVersion := some value } positional
    | "--session-id" :: value :: rest =>
        loop rest { opts with sessionId := some value } positional
    | "--target-session-id" :: value :: rest =>
        loop rest { opts with sessionId := some value } positional
    | "--target-timestamp" :: value :: rest =>
        loop rest { opts with targetTimestamp := some value } positional
    | "--pi-assistant-history" :: value :: rest =>
        loop rest { opts with piAssistantHistory := some value } positional
    | "--target-codex-approval-policy" :: value :: rest =>
        loop rest { opts with codexApprovalPolicy := some value } positional
    | "--target-codex-network-access" :: value :: rest =>
        match parseCliBool "--target-codex-network-access" value with
        | .ok parsed => loop rest { opts with codexNetworkAccess := some parsed } positional
        | .error error => .error error
    | "--target-codex-exclude-tmpdir-env-var" :: value :: rest =>
        match parseCliBool "--target-codex-exclude-tmpdir-env-var" value with
        | .ok parsed =>
            loop rest { opts with codexExcludeTmpdirEnvVar := some parsed } positional
        | .error error => .error error
    | "--target-codex-exclude-slash-tmp" :: value :: rest =>
        match parseCliBool "--target-codex-exclude-slash-tmp" value with
        | .ok parsed => loop rest { opts with codexExcludeSlashTmp := some parsed } positional
        | .error error => .error error
    | "--target-codex-summary" :: value :: rest =>
        loop rest { opts with codexSummary := some value } positional
    | "--store" :: value :: rest => loop rest { opts with store := some value } positional
    | "--role" :: value :: rest => loop rest { opts with role := some value } positional
    | "--limit" :: value :: rest =>
        match value.toNat? with
        | some n => loop rest { opts with limit := some n } positional
        | none => .error s!"--limit requires a non-negative integer, got '{value}'"
    | arg :: rest =>
        if arg.startsWith "--" then .error s!"unknown or incomplete option: {arg}"
        else loop rest opts (arg :: positional)
  loop args {} []

private def sourceOriginExtrasArchiveKey : String :=
  "_agent_convert_source_origin_extras"

private def setOriginExtra (origin : Origin) (key : String) (value : Lean.Json) : Origin :=
  let extras := match origin.extras with
    | some (.obj fields) => Lean.Json.obj (fields.insert key value)
    | some prior => Lean.Json.mkObj [
        (sourceOriginExtrasArchiveKey, Lean.Json.mkObj [
          ("protocol", Lean.Json.str "agent-convert.source-origin-extras.v1"),
          ("raw", prior)]),
        (key, value)]
    | none => Lean.Json.mkObj [(key, value)]
  { origin with extras := some extras }

private def applyTargetExtra (origin : Origin) (key : String) : Option String -> Origin
  | some value => setOriginExtra origin key (Lean.Json.str value)
  | none => origin

private def targetConfigurationKeys : List String := [
  "target_cwd", "target_provider", "target_model", "target_session_id",
  "target_timestamp", "target_harness_version", "target_cli_version",
  "target_originator", "target_turn_context_record", codexTargetControlsKey,
  cursorAgentTargetControlsKey, "pi_assistant_history"]

private def sourceTargetConfigurationArchiveKey : String :=
  "_agent_convert_source_target_configuration"

/-- A source artifact cannot authorize the next target's identity or runtime
controls. Only values supplied by this invocation are eligible for activation. -/
private def clearTargetConfiguration (origin : Origin) : Origin :=
  match origin.extras with
  | some (.obj fields) =>
      let raw := Lean.Json.obj fields
      let cleared := targetConfigurationKeys.filterMap (fun key =>
        (raw.getObjVal? key).toOption.map (fun value => (key, value)))
      let retained := targetConfigurationKeys.foldl (fun acc key => acc.erase key) fields
      let retained := if cleared.isEmpty then retained else
        let prior := (raw.getObjVal? sourceTargetConfigurationArchiveKey).toOption
        retained.insert sourceTargetConfigurationArchiveKey (Lean.Json.mkObj [
          ("protocol", Lean.Json.str "agent-convert.source-target-configuration.v1"),
          ("prior", prior.getD Lean.Json.null),
          ("cleared", Lean.Json.mkObj cleared)])
      { origin with extras := some (.obj retained) }
  | _ => origin

private def cliCodexTargetControls? (opts : CliOptions) : Option Lean.Json := do
  let approvalPolicy ← opts.codexApprovalPolicy
  let networkAccess ← opts.codexNetworkAccess
  let excludeTmpdirEnvVar ← opts.codexExcludeTmpdirEnvVar
  let excludeSlashTmp ← opts.codexExcludeSlashTmp
  let summary ← opts.codexSummary
  pure (Lean.Json.mkObj [
    ("protocol", Lean.Json.str codexTargetControlsProtocol),
    ("approval_policy", Lean.Json.str approvalPolicy),
    ("sandbox_policy", Lean.Json.mkObj [
      ("type", Lean.Json.str "workspace-write"),
      ("network_access", Lean.Json.bool networkAccess),
      ("exclude_tmpdir_env_var", Lean.Json.bool excludeTmpdirEnvVar),
      ("exclude_slash_tmp", Lean.Json.bool excludeSlashTmp)]),
    ("summary", Lean.Json.str summary)])

private def missingCodexControlFlags (opts : CliOptions) : List String :=
  [
    ("--target-codex-approval-policy", opts.codexApprovalPolicy.isNone),
    ("--target-codex-network-access", opts.codexNetworkAccess.isNone),
    ("--target-codex-exclude-tmpdir-env-var", opts.codexExcludeTmpdirEnvVar.isNone),
    ("--target-codex-exclude-slash-tmp", opts.codexExcludeSlashTmp.isNone),
    ("--target-codex-summary", opts.codexSummary.isNone)
  ].filterMap (fun (flag, missing) => if missing then some flag else none)

private def hasAnyCodexControlOption (opts : CliOptions) : Bool :=
  (missingCodexControlFlags opts).length < 5

private def targetCliConfigurationError? (toFmt : String) (opts : CliOptions) : Option String :=
  let missing := missingCodexControlFlags opts
  if toFmt == "codex" && !missing.isEmpty then
    some s!"Codex target requires explicit controls: {String.intercalate ", " missing}"
  else if toFmt != "codex" && hasAnyCodexControlOption opts then
    some "--target-codex-* options are valid only when the target is codex"
  else none

/-- Launch configuration belongs to the target artifact. It must never overwrite
the source transcript's `EnvInfo`, because doing so would erase the very source
facts that conversion policy and reversible carriers are required to account for. -/
private def applyCliOverrides (toFmt : String) (opts : CliOptions)
    (t : Transcript) : Transcript :=
  let origin := applyTargetExtra (clearTargetConfiguration t.origin) "target_cwd" opts.cwd
  let origin := applyTargetExtra origin "target_provider" opts.provider
  let origin := applyTargetExtra origin "target_model" opts.model
  let origin := applyTargetExtra origin "target_session_id" opts.sessionId
  let origin := applyTargetExtra origin "target_timestamp" opts.targetTimestamp
  let origin := applyTargetExtra origin "target_harness_version" opts.harnessVersion
  let origin := if toFmt == "codex" then
      match cliCodexTargetControls? opts with
      | some controls => setOriginExtra origin codexTargetControlsKey controls
      | none => origin
    else origin
  let origin := if toFmt == "pi" then
      applyTargetExtra origin "pi_assistant_history" opts.piAssistantHistory
    else origin
  { t with origin }

private def cliTargetOptionsPreserveSourceEnvironment : Bool :=
  let sourceEnv : EnvInfo := {
    cwd := some "/source"
    provider := some "source-provider"
    model := some "source-model"
    harnessVersion := some "source-version"
    instructions := some "source instructions"
    sessionId := some "source-session"
  }
  let source : Transcript := {
    threads := #[{ kind := .main }]
    entries := #[]
    env := sourceEnv
    origin := {
      format := .googleAiStudio
      sourceRef := "target-option-regression"
      extras := some (Lean.Json.mkObj [
        ("sourceMarker", .str "retained"),
        ("target_session_id", .str "stale-session"),
        ("target_originator", .str "stale-originator"),
        ("target_turn_context_record", Lean.Json.mkObj []),
        (codexTargetControlsKey, Lean.Json.mkObj []),
        (cursorAgentTargetControlsKey, Lean.Json.mkObj []),
        ("pi_assistant_history", .str "carrier")])
    }
  }
  let options : CliOptions := {
    cwd := some "/target"
    provider := some "target-provider"
    model := some "target-model"
    harnessVersion := some "target-version"
    sessionId := some "target-session"
    targetTimestamp := some "2026-07-20T00:00:00.000Z"
    piAssistantHistory := some "context"
    codexApprovalPolicy := some "on-request"
    codexNetworkAccess := some false
    codexExcludeTmpdirEnvVar := some true
    codexExcludeSlashTmp := some true
    codexSummary := some "concise"
  }
  ["pi", "claude", "codex", "cursor-agent"].all (fun target =>
    let configured := applyCliOverrides target options source
      let stringExtra := fun key => configured.origin.extras >>= fun extras =>
        (extras.getObjVal? key >>= Lean.Json.getStr?).toOption
      let archiveExtra := configured.origin.extras >>= fun extras =>
        (extras.getObjVal? sourceTargetConfigurationArchiveKey).toOption
    configured.env == sourceEnv &&
      stringExtra "sourceMarker" == some "retained" &&
      stringExtra "target_cwd" == some "/target" &&
      stringExtra "target_provider" == some "target-provider" &&
      stringExtra "target_model" == some "target-model" &&
      stringExtra "target_harness_version" == some "target-version" &&
      stringExtra "target_session_id" == some "target-session" &&
      stringExtra "target_timestamp" == some "2026-07-20T00:00:00.000Z" &&
      (stringExtra "target_originator").isNone &&
      (stringExtra "target_turn_context_record").isNone &&
      archiveExtra.isSome &&
      (stringExtra "pi_assistant_history").isSome == (target == "pi") &&
      ((configured.origin.extras >>= fun extras =>
        (extras.getObjVal? codexTargetControlsKey).toOption).isSome ==
          (target == "codex")))

example : cliTargetOptionsPreserveSourceEnvironment = true := by native_decide

private def cliNonObjectOriginExtrasPreserved : Bool :=
  let source : Transcript := {
    threads := #[{ kind := .main }]
    entries := #[]
    origin := {
      format := .other "fixture"
      sourceRef := "non-object-origin-extras"
      extras := some (Lean.Json.arr #[Lean.Json.str "opaque", Lean.Json.num 7])
    }
  }
  let configured := applyCliOverrides "pi" { cwd := some "/target" } source
  match configured.origin.extras with
  | some extras =>
      (extras.getObjVal? sourceOriginExtrasArchiveKey >>= fun archive =>
        archive.getObjVal? "raw").toOption == source.origin.extras &&
      (extras.getObjVal? "target_cwd" >>= Lean.Json.getStr?).toOption == some "/target"
  | none => false

example : cliNonObjectOriginExtrasPreserved = true := by native_decide

private def claudeSameFormatNoOverrideInput : String :=
  (Lean.Json.mkObj [
    ("type", .str "user"),
    ("uuid", .str "71000000-0000-4000-8000-000000000001"),
    ("parentUuid", .null),
    ("sessionId", .str "71000000-0000-4000-8000-000000000000"),
    ("cwd", .str "/tmp/claude-same-format"),
    ("timestamp", .str "2026-07-20T01:02:03.004Z"),
    ("isSidechain", .bool false),
    ("message", Lean.Json.mkObj [
      ("role", .str "user"),
      ("content", .str "same-format environment regression")])]).compress ++ "\n"

/-- A native Claude-to-Claude invocation with no target options writes the same
physical cwd/session fields, so those two source-environment facts are not
destructive losses and must not block the checked pipeline. -/
private def claudeSameFormatNoOverridesPreservesEnvironment : Bool :=
  match importByFormat "claude" claudeSameFormatNoOverrideInput with
  | .error _ => false
  | .ok source =>
      let configured := applyCliOverrides "claude" {} source
      let destructive := (Loom.Ops.obligations .claudeCode configured).filter
        (Loom.Ops.obligationIsDestructiveFor .claudeCode configured)
      targetCliConfigurationError? "claude" {} == none &&
        configured.env == source.env &&
        configured.env.cwd == some "/tmp/claude-same-format" &&
        configured.env.sessionId == some "71000000-0000-4000-8000-000000000000" &&
        destructive.isEmpty &&
        (exportBlocker? "claude" configured).isNone &&
        match runPipeline "claude" "claude" configured with
        | .error _ => false
        | .ok output =>
            !output.isEmpty &&
              match importByFormat "claude" output with
              | .error _ => false
              | .ok restored =>
                  restored.env.cwd == configured.env.cwd &&
                    restored.env.sessionId == configured.env.sessionId

example : claudeSameFormatNoOverridesPreservesEnvironment = true := by native_decide

/-! ## Cursor Agent runtime dispatch pins -/

private def mainContains (text needle : String) : Bool :=
  decide ((text.splitOn needle).length > 1)

private def mainErrorContains (result : Except String String) (needle : String) : Bool :=
  match result with
  | .error error => mainContains error needle
  | .ok _ => false

private def mainBlockerContains (blocker : Option String) (needle : String) : Bool :=
  blocker.any (fun error => mainContains error needle)

/-- This is the exact branch condition used by `emit`: only successful pipeline
bytes can reach the atomic output writer. -/
private def mainOutputEligible : Except String String -> Option String
  | .ok output => some output
  | .error _ => none

/-- Synthetic, non-imported fixture entry for the runtime dispatch pins below.
`format` must NOT be `.cursorAgent`: `cursorAgentRawRecordAuthorizesRole` fails
closed on cursor-origin entries with no backing raw record (by design — an
unverified claim of Cursor origin must not be treated as native), and this
fixture was never actually imported from Cursor Agent. `.pi` matches the
"foreign-format modeled entries... judged by their payload" convention used by
the other synthetic fixtures in this file (e.g. `codexSignatureFixture`). -/
private def cursorRuntimeOrigin : Origin := {
  format := .pi
  sourceRef := "main-runtime-dispatch-pin"
}

private def cursorRuntimeEntry : Entry := {
  payload := .userMsg [.text "cursor runtime dispatch"]
  origin := cursorRuntimeOrigin
}

private def cursorRuntimeMetadataFreeTarget : Transcript := {
  threads := #[{ kind := .main }]
  entries := #[cursorRuntimeEntry]
  activeLeaf := some 0
  origin := cursorRuntimeOrigin
}

private def cursorRuntimeSidechainTarget : Transcript := {
  cursorRuntimeMetadataFreeTarget with
  threads := #[{ kind := .main }, { kind := .detached "runtime pin" }]
}

private def cursorRuntimeWithExtra (key : String) (value : Lean.Json) : Transcript :=
  { cursorRuntimeMetadataFreeTarget with
    origin := setOriginExtra cursorRuntimeMetadataFreeTarget.origin key value }

private def cursorRuntimeSidechainWithExtra
    (key : String) (value : Lean.Json) : Transcript :=
  { cursorRuntimeSidechainTarget with
    origin := setOriginExtra cursorRuntimeSidechainTarget.origin key value }

private def cursorRuntimeTargetControls : Lean.Json :=
  Lean.Json.mkObj [
    ("protocol", Lean.Json.str cursorAgentTargetControlsProtocol),
    ("permission_mode", Lean.Json.str "plan")]

private def cursorRuntimeValidTargetSucceeds : Bool :=
  (LoomConvert.cursorAgentTargetExportPrerequisiteFailures
      cursorRuntimeMetadataFreeTarget).isEmpty &&
  match LoomConvert.exportCursorAgentTargetChecked cursorRuntimeMetadataFreeTarget,
      exportByFormat "cursor-agent" cursorRuntimeMetadataFreeTarget,
      runPipeline "loom" "cursor-agent" cursorRuntimeMetadataFreeTarget with
  | .ok adapterOutput, .ok dispatchOutput, .ok pipelineOutput =>
      !adapterOutput.isEmpty && adapterOutput == dispatchOutput &&
        dispatchOutput == pipelineOutput
  | _, _, _ => false

example : cursorRuntimeValidTargetSucceeds = true := by native_decide

private def cursorRuntimeNamedLaunchRefusal (key : String) : Bool :=
  let expected := s!"Cursor Agent JSONL has no native field for origin.extras.{key}"
  let target := cursorRuntimeWithExtra key (Lean.Json.str s!"configured-{key}")
  let sidechain := cursorRuntimeSidechainWithExtra key
    (Lean.Json.str s!"configured-{key}")
  (LoomConvert.cursorAgentTargetExportPrerequisiteFailures target).contains expected &&
    mainBlockerContains (targetValidityBlocker? "cursor-agent" target) expected &&
    mainErrorContains (exportByFormat "cursor-agent" target) expected &&
    mainErrorContains (runPipeline "loom" "cursor-agent" target) expected &&
    (mainOutputEligible (runPipeline "loom" "cursor-agent" target)).isNone &&
    mainBlockerContains (sidecarProjectionBlocker? "cursor-agent" sidechain) expected

private def cursorRuntimeNamedControlRefusal (value : Lean.Json)
    (expected : String) : Bool :=
  let target := cursorRuntimeWithExtra cursorAgentTargetControlsKey value
  let sidechain := cursorRuntimeSidechainWithExtra cursorAgentTargetControlsKey value
  (LoomConvert.cursorAgentTargetExportPrerequisiteFailures target).contains expected &&
    mainBlockerContains (targetValidityBlocker? "cursor-agent" target) expected &&
    mainErrorContains (exportByFormat "cursor-agent" target) expected &&
    mainErrorContains (runPipeline "loom" "cursor-agent" target) expected &&
    (mainOutputEligible (runPipeline "loom" "cursor-agent" target)).isNone &&
    mainBlockerContains (sidecarProjectionBlocker? "cursor-agent" sidechain) expected

private def cursorRuntimeMetadataRefusalsArePreOutput : Bool :=
  cursorAgentTargetLaunchOptionKeys.all cursorRuntimeNamedLaunchRefusal &&
    cursorRuntimeNamedControlRefusal cursorRuntimeTargetControls
      "Cursor Agent JSONL cannot encode operational controls from origin.extras.target_cursor_agent_controls" &&
    cursorRuntimeNamedControlRefusal (Lean.Json.str "malformed")
      "origin.extras.target_cursor_agent_controls must be an exact agent-convert.cursor-agent-target-controls.v1 object"

example : cursorRuntimeMetadataRefusalsArePreOutput = true := by native_decide

private def directOriginExtra? (t : Transcript) (key : String) : Option Lean.Json :=
  t.origin.extras >>= fun extras => (extras.getObjVal? key).toOption

/-- Source-carried launch metadata is archived as inert provenance. With no
current invocation options, neither Loom nor Cursor receives a direct target
launch/control field that could be reactivated or discarded by an exporter. -/
private def loomAndCursorDoNotInheritTargetLaunchMetadata : Bool :=
  let staleOrigin := cursorAgentTargetLaunchOptionKeys.foldl (fun origin key =>
    setOriginExtra origin key (Lean.Json.str s!"stale-{key}"))
      cursorRuntimeMetadataFreeTarget.origin
  let staleOrigin := setOriginExtra staleOrigin cursorAgentTargetControlsKey
    cursorRuntimeTargetControls
  let stale : Transcript := { cursorRuntimeMetadataFreeTarget with origin := staleOrigin }
  ["loom", "cursor-agent"].all (fun target =>
    let configured := applyCliOverrides target {} stale
    cursorAgentTargetLaunchOptionKeys.all (fun key =>
      (directOriginExtra? configured key).isNone) &&
      (directOriginExtra? configured cursorAgentTargetControlsKey).isNone &&
      (directOriginExtra? configured sourceTargetConfigurationArchiveKey).isSome)

example : loomAndCursorDoNotInheritTargetLaunchMetadata = true := by
  native_decide

/-- The stronger adapter check must not reorder the pipeline's established
policy failures: sidechains are still classified by the flat-output gate.

INVERTED 2026-07-26 for time and source environment. This pin used to require
that a recorded timestamp and a source cwd each refuse the whole export, at
adapter, dispatch and pipeline level. That is the refuse-on-lossy policy
`LoomOps.Interop.Emission.refused` rules out, and because Cursor Agent JSONL has
no timestamp key and no environment record, it made the target unreachable from
every real Claude or Codex session — a transcript with neither is not a
transcript any harness writes. Both are now `ObligationImpact.reportOnly` and
both artifacts are produced. The property that replaced it is strictly stronger
than "does not refuse": the loss must still be REPORTED, so a silent drop fails
this pin exactly as a refusal now would. -/
private def cursorRuntimeExistingRefusalsRemain : Bool :=
  let timed : Transcript := { cursorRuntimeMetadataFreeTarget with
    entries := #[{ cursorRuntimeEntry with time := .recorded ⟨1700000000000⟩ }] }
  let sourceEnv : Transcript := { cursorRuntimeMetadataFreeTarget with
    env := { cwd := some "/source/worktree" } }
  let reportsOnly := fun (t : Transcript) (obligation : Loom.Ops.Obligation) =>
    (Loom.Ops.obligations Loom.Format.cursorAgent t).contains obligation &&
      Loom.Ops.obligationImpactFor Loom.Format.cursorAgent t obligation ==
        Loom.Ops.ObligationImpact.reportOnly
  let exportsCleanly := fun (t : Transcript) =>
    (targetValidityBlocker? "cursor-agent" t).isNone &&
      (exportBlocker? "cursor-agent" t).isNone &&
      (mainOutputEligible (exportByFormat "cursor-agent" t)).isSome &&
      (mainOutputEligible (runPipeline "loom" "cursor-agent" t)).isSome
  mainErrorContains
      (runPipeline "loom" "cursor-agent" cursorRuntimeSidechainTarget)
      "sidechain/detached thread metadata" &&
    (mainOutputEligible
      (runPipeline "loom" "cursor-agent" cursorRuntimeSidechainTarget)).isNone &&
    reportsOnly timed .dropRecordedTime &&
    exportsCleanly timed &&
    reportsOnly sourceEnv (.dropEnvironment ["cwd"]) &&
    exportsCleanly sourceEnv

example : cursorRuntimeExistingRefusalsRemain = true := by native_decide

open Lean Elab Term in
elab "loomCoreRevision%" : term => do
  let revision := loom.coreRevision.get (← getOptions)
  elabTerm (Syntax.mkStrLit revision) (some (mkConst ``String))

def coreVersion : String := "0.2.0-preview.1"
def coreProtocol : String := "loom.cli.v1"
def coreRevision : String := loomCoreRevision%
def coreSourceRepository : String := "https://github.com/theoriclabs/agent-convert-lean"
def coreSourcePath : String := "."
def coreWireSchema : String := "loom.transcript.v0"
def coreCapabilities : Array String := #["claude.semantic-tool-translation.v1"]

private def coreCapabilitiesJson : Lean.Json :=
  Lean.Json.arr (coreCapabilities.map Lean.Json.str)

private def transcriptMessageCount (t : Transcript) : Nat :=
  t.entries.toList.countP (fun e => match e.payload with
    | .userMsg _ | .assistantMsg _ | .envMsg _ | .otherMsg _ _ => true
    | _ => false)

private def transcriptToolCallCount (t : Transcript) : Nat :=
  t.entries.toList.foldl (fun n e => n + match e.payload with
    | .assistantMsg blocks => blocks.countP (fun
        | AssistantBlock.toolCall _ _ _ => true | _ => false)
    | _ => 0) (0 : Nat)

private def transcriptToolResultCount (t : Transcript) : Nat :=
  t.entries.toList.foldl (fun n e => n + match e.payload with
    | .envMsg blocks => blocks.countP (fun
        | EnvBlock.toolResult _ _ _ => true | _ => false)
    | _ => 0) (0 : Nat)

private def transcriptThinkingCount (t : Transcript) : Nat :=
  t.entries.toList.foldl (fun n e => n + match e.payload with
    | .assistantMsg blocks => blocks.countP (fun
        | AssistantBlock.thinking _ _ => true | _ => false)
    | _ => 0) (0 : Nat)

private def archivedControlCount (t : Transcript) : Nat :=
  match t.origin.extras with
  | some extras =>
      match (extras.getObjVal? "raw_control_messages" >>= Lean.Json.getArr?).toOption with
      | some controls => controls.size
      | none => 0
  | none => 0

private def excludedSourceRecordCount (t : Transcript) : Nat :=
  t.importNotes.countP (fun note =>
    match note.kind with
    | .contentSkipped | .dedupDropped => true
    | _ => false)

private def transcriptUsesActiveContext (t : Transcript) : Bool :=
  match t.origin.extras with
  | some extras =>
      (extras.getObjVal? "active_context" >>= Lean.Json.getBool?).toOption.getD false
  | none => false

private def assumptionKindName : AssumptionKind → String
  | .dedupDropped => "dedupDropped"
  | .timeInterpolated => "timeInterpolated"
  | .timeSequenced => "timeSequenced"
  | .errorInferred => "errorInferred"
  | .roleCoerced => "roleCoerced"
  | .toolNameMapped => "toolNameMapped"
  | .idSynthesized => "idSynthesized"
  | .contentSkipped => "contentSkipped"
  | .activeLeafGuessed => "activeLeafGuessed"
  | .other label => label

private def importJudgmentJson (note : ImportNote) : Lean.Json :=
  Lean.Json.mkObj ([
    ("kind", Lean.Json.str (assumptionKindName note.kind)),
    ("detail", Lean.Json.str note.detail)] ++
    match note.loc with
    | some loc => [("sourceRef", Lean.Json.str loc)]
    | none => [])

private def obligationImpactName : Loom.Ops.ObligationImpact → String
  | .fulfillment => "fulfillment"
  | .reportOnly => "reportOnly"
  | .destructive => "destructive"

private def exportObligationJson (target : Format) (t : Transcript)
    (obligation : Loom.Ops.Obligation) : Lean.Json :=
  let fields : List (String × Lean.Json) := match obligation with
    | .closeOpenToolCalls count => [
        ("kind", Lean.Json.str "closeOpenToolCalls"),
        ("count", Lean.Json.num count)]
    | .dropThinking => [("kind", Lean.Json.str "dropThinking")]
    | .dropSidechains => [("kind", Lean.Json.str "dropSidechains")]
    | .linearizeBranches => [("kind", Lean.Json.str "linearizeBranches")]
    | .synthesizeEntryIds => [("kind", Lean.Json.str "synthesizeEntryIds")]
    | .synthesizeTimestamps => [("kind", Lean.Json.str "synthesizeTimestamps")]
    | .dropRecordedTime => [("kind", Lean.Json.str "dropRecordedTime")]
    | .dropCompaction => [("kind", Lean.Json.str "dropCompaction")]
    | .dropMedia => [("kind", Lean.Json.str "dropMedia")]
    | .dropUnmodeled => [("kind", Lean.Json.str "dropUnmodeled")]
    | .dropToolResults => [("kind", Lean.Json.str "dropToolResults")]
    | .dropOtherRoles => [("kind", Lean.Json.str "dropOtherRoles")]
    | .dropEvents => [("kind", Lean.Json.str "dropEvents")]
    | .dropSourceIdentity => [("kind", Lean.Json.str "dropSourceIdentity")]
    | .dropEnvironment environmentFields => [
        ("kind", Lean.Json.str "dropEnvironment"),
        ("fields", Lean.Json.arr (environmentFields.map Lean.Json.str).toArray)]
    | .dropOriginProvenance => [("kind", Lean.Json.str "dropOriginProvenance")]
    | .dropToolCallIds => [("kind", Lean.Json.str "dropToolCallIds")]
    | .dropTimeProvenance => [("kind", Lean.Json.str "dropTimeProvenance")]
  let impact := obligationImpactName (Loom.Ops.obligationImpactFor target t obligation)
  Lean.Json.mkObj (fields ++ [("impact", Lean.Json.str impact)])

private def exportObligationsFor (toFmt : String) (t : Transcript) : List Loom.Ops.Obligation :=
  match formatByCliName? toFmt with
  | some target => Loom.Ops.obligations target t
  | none => []

private def reportExportObligations (toFmt : String) (t : Transcript) : IO Unit := do
  let obligations := exportObligationsFor toFmt t
  unless obligations.isEmpty do
    IO.eprintln s!"export obligations: {reprStr obligations}"

private def transcriptCompactionEventCount (t : Transcript) : Nat :=
  match t.origin.extras with
  | some extras =>
      (extras.getObjVal? "compaction_events" >>= Lean.Json.getNat?).toOption.getD 0
  | none => 0

private def activeContextBoundarySummary (boundary : Lean.Json) : Lean.Json :=
  let value (key : String) : Lean.Json :=
    (boundary.getObjVal? key).toOption.getD Lean.Json.null
  Lean.Json.mkObj [
    ("segment", value "segment"),
    ("recordIndex", value "record_index"),
    ("segmentRecordIndex", value "segment_record_index"),
    ("excludedRecordCount", value "excluded_record_count"),
    ("retainedPrefixTurnContextCount",
      value "retained_prefix_turn_context_count"),
    ("replacementHistoryCount", value "replacement_history_count")]

private def targetOptionString (t : Transcript) (key : String) : Option String :=
  t.origin.extras >>= fun extras =>
    (extras.getObjVal? key >>= Lean.Json.getStr?).toOption.bind (fun value =>
      if value.isEmpty then none else some value)

private def transcriptSummaryJson
    (fromFmt toFmt inp outp : String) (source emitted : Transcript)
    (callsCarriedByTransform resultsCarriedByTransform : Nat) : Lean.Json :=
  let messagesImported := transcriptMessageCount source
  let messagesWritten := if toFmt == "cursor-agent" then
    cursorAgentTargetRecordCount emitted else transcriptMessageCount emitted
  let toolCallsImported := transcriptToolCallCount source
  let toolResultsImported := transcriptToolResultCount source
  let toolCallsEmitted := if toFmt == "pi" then
    piNativeToolCallCount emitted else if toFmt == "codex" then
    codexNativeToolCallCount emitted else if toFmt == "claude" then
    claudeNativeToolCallCount emitted else if toFmt == "cursor-agent" then
    cursorAgentNativeToolCallCount emitted else transcriptToolCallCount emitted
  let toolCallsCarried := if toFmt == "pi" then
    piHistoricalToolCallCarrierCount emitted else if toFmt == "codex" then
    codexHistoricalToolCallCount emitted else if toFmt == "claude" then
    callsCarriedByTransform + claudeHistoricalToolCallCount emitted else
    if toFmt == "cursor-agent" then
      callsCarriedByTransform + cursorAgentHistoricalToolCallCount emitted else
    callsCarriedByTransform
  -- cursor-agent has no tool-result record at all, so a source-side count would
  -- claim the artifact holds results it structurally cannot hold.
  let toolResultsEmitted := if toFmt == "pi" then
    piNativeToolResultCount emitted else if toFmt == "codex" then
    codexNativeToolResultCount emitted else if toFmt == "claude" then
    claudeNativeToolResultCount emitted else if toFmt == "cursor-agent" then
    cursorAgentNativeToolResultCount emitted else transcriptToolResultCount emitted
  let toolResultsCarried := if toFmt == "pi" then
    piHistoricalToolResultCarrierCount emitted else if toFmt == "codex" then
    codexHistoricalToolResultCount emitted else if toFmt == "claude" then
    resultsCarriedByTransform + claudeHistoricalToolResultCount emitted else
    resultsCarriedByTransform
  let thinking := transcriptThinkingCount source
  let exportObligations := exportObligationsFor toFmt emitted
  let exportObligationJsons : Array Lean.Json :=
    match formatByCliName? toFmt with
    | some target =>
        (exportObligations.map (exportObligationJson target emitted)).toArray
    | none => #[]
  let excludedRecords :=
    (codexActiveContextExcludedRecordCount? source).getD
      (excludedSourceRecordCount source)
  let activeBoundaries :=
    ((codexActiveContextCompactionBoundaries? source).getD #[]).map
      activeContextBoundarySummary
  Lean.Json.mkObj [
    ("engine", Lean.Json.str "lean"),
    ("engineVersion", Lean.Json.str coreVersion),
    ("protocolVersion", Lean.Json.str coreProtocol),
    ("coreRevision", Lean.Json.str coreRevision),
    ("capabilities", coreCapabilitiesJson),
    ("targetTriple", Lean.Json.str System.Platform.target),
    ("from", Lean.Json.str fromFmt),
    ("to", Lean.Json.str toFmt), ("input", Lean.Json.str inp),
    ("output", Lean.Json.str outp), ("installed", Lean.Json.null),
    ("sessionId", source.env.sessionId.map Lean.Json.str |>.getD Lean.Json.null),
    ("hermesSessionId", if fromFmt == "hermes" then
      source.env.sessionId.map Lean.Json.str |>.getD Lean.Json.null else Lean.Json.null),
    ("cwd", source.env.cwd.map Lean.Json.str |>.getD Lean.Json.null),
    ("model", source.env.model.map Lean.Json.str |>.getD Lean.Json.null),
    ("provider", source.env.provider.map Lean.Json.str |>.getD Lean.Json.null),
    ("harnessVersion",
      source.env.harnessVersion.map Lean.Json.str |>.getD Lean.Json.null),
    ("targetSessionId", (targetOptionString emitted "target_session_id").map
      Lean.Json.str |>.getD Lean.Json.null),
    ("targetCwd", (targetOptionString emitted "target_cwd").map
      Lean.Json.str |>.getD Lean.Json.null),
    ("targetProvider", (targetOptionString emitted "target_provider").map
      Lean.Json.str |>.getD Lean.Json.null),
    ("targetModel", (targetOptionString emitted "target_model").map
      Lean.Json.str |>.getD Lean.Json.null),
    ("targetHarnessVersion", (targetOptionString emitted "target_harness_version").map
      Lean.Json.str |>.getD Lean.Json.null),
    ("targetTimestamp", (targetOptionString emitted "target_timestamp").map
      Lean.Json.str |>.getD Lean.Json.null),
    ("messagesWritten", Lean.Json.num messagesWritten),
    ("messagesImported", Lean.Json.num messagesImported),
    ("toolCallsImported", Lean.Json.num toolCallsImported),
    ("toolResultsImported", Lean.Json.num toolResultsImported),
    ("toolCallsCarriedAsHistory", Lean.Json.num toolCallsCarried),
    ("toolCallsEmittedNative", Lean.Json.num toolCallsEmitted),
    ("toolResultsEmitted", Lean.Json.num toolResultsEmitted),
    ("toolResultsCarriedAsHistory", Lean.Json.num toolResultsCarried),
    ("nativeAssistantContextMessages", if toFmt == "pi" then
      Lean.Json.num (piNativeAssistantContextCount emitted) else Lean.Json.null),
    ("historicalAssistantCarriers", if toFmt == "pi" then
      Lean.Json.num (piHistoricalAssistantCarrierCount emitted) else Lean.Json.null),
    ("targetResumable", if toFmt == "pi" then
      Lean.Json.bool (piTargetResumable emitted) else Lean.Json.null),
    ("openToolCallsImported", Lean.Json.num (Loom.Ops.openCalls source).length),
    ("openToolCallsEmittedNative", Lean.Json.num
      (if toFmt == "pi" then piNativeOpenToolCallCount emitted
       else if toFmt == "codex" || toFmt == "claude" then 0
       -- Every cursor-agent call is open: the format stores no results.
       else if toFmt == "cursor-agent" then cursorAgentNativeToolCallCount emitted
       else (Loom.Ops.openCalls emitted).length)),
    ("syntheticToolResults", Lean.Json.num 0),
    ("controlsArchived", Lean.Json.num (archivedControlCount source)),
    ("importJudgmentCount", Lean.Json.num source.importNotes.length),
    ("importJudgments", Lean.Json.arr
      (source.importNotes.map importJudgmentJson).toArray),
    ("exportObligationCount", Lean.Json.num exportObligations.length),
    ("exportObligations", Lean.Json.arr exportObligationJsons),
    ("activeContext", Lean.Json.bool (transcriptUsesActiveContext source)),
    ("excludedSourceRecords", Lean.Json.num excludedRecords),
    ("activeContextCompactionBoundaries", Lean.Json.arr activeBoundaries),
    ("thinkingBlocksImported", Lean.Json.num thinking),
    ("reasoningBlocksImported", Lean.Json.num thinking),
    ("compactionEvents", Lean.Json.num (transcriptCompactionEventCount source)),
    ("skippedLines", Lean.Json.num (excludedSourceRecordCount source))]

private def summaryCodexHistoricalOrigin : Origin := {
  format := .codexCli
  sourceRef := "summary-codex-history-pin"
}

private def summaryCodexHistoricalFixture : Transcript := {
  threads := #[{ kind := .main }]
  entries := #[
    { payload := .assistantMsg [
        .toolCall { raw := "first", canonical := none } Lean.Json.null (some "call-1"),
        .toolCall { raw := "second", canonical := none } Lean.Json.null (some "call-2"),
        .toolCall { raw := "open", canonical := none } Lean.Json.null (some "call-3")]
      origin := summaryCodexHistoricalOrigin },
    { parent := some 0
      payload := .envMsg [
        .toolResult (.resolved 0 0) [.text "first result"] (.native false),
        .toolResult (.resolved 0 1) [.text "second result"] (.native false)]
      origin := summaryCodexHistoricalOrigin }]
  activeLeaf := some 1
  origin := summaryCodexHistoricalOrigin
}

/-- Summary accounting includes tool lifecycles already replaced by inert
Claude history carriers, not only tool constructors left in the post-policy IR. -/
private def codexClaudeHistoricalSummaryCountsPinned : Bool :=
  let source := summaryCodexHistoricalFixture
  let (emitted, counts) := historicalizeCodexToolsForClaude source
  let summary := transcriptSummaryJson "codex" "claude" "input" "output"
    source emitted counts.calls counts.results
  let field := fun key =>
    (summary.getObjVal? key >>= Lean.Json.getNat?).toOption
  transcriptToolCallCount emitted == 0 &&
    transcriptToolResultCount emitted == 0 &&
    field "toolCallsImported" == some 3 &&
    field "toolResultsImported" == some 2 &&
    field "toolCallsCarriedAsHistory" == some 3 &&
    field "toolResultsCarriedAsHistory" == some 2 &&
    field "toolCallsEmittedNative" == some 0 &&
    field "toolResultsEmitted" == some 0

example : codexClaudeHistoricalSummaryCountsPinned = true := by native_decide

private def jsonString? (json : Lean.Json) (key : String) : Option String :=
  (json.getObjVal? key >>= Lean.Json.getStr?).toOption

private def jsonValue? (json : Lean.Json) (key : String) : Option Lean.Json :=
  (json.getObjVal? key).toOption

private def detectionRecords (text : String) : Except String (List Lean.Json) := do
  match Lean.Json.parse text with
  | .ok document => pure [document]
  | .error _ =>
      let lines := (text.splitOn "\n").filter (fun line => !line.trimAscii.isEmpty)
      if lines.isEmpty then .error "empty input"
      else
        lines.zipIdx.mapM (fun (line, index) =>
          match Lean.Json.parse line with
          | .ok value => pure value
          | .error error =>
              .error s!"malformed JSONL at line {index + 1}: {error}")

private def hasEnvelopeField (record : Lean.Json) (key : String) : Bool :=
  (jsonValue? record key).isSome

private def looksLikeClaudeRecord (record : Lean.Json) : Bool :=
  let hasIdentity := hasEnvelopeField record "uuid" ||
    hasEnvelopeField record "parentUuid" ||
    (jsonString? record "sessionId").isSome
  jsonString? record "type" == some "file-history-snapshot" ||
    ((jsonString? record "type").isSome && hasIdentity)

private def looksLikeCursorAgentRecord (record : Lean.Json) : Bool :=
  let messageLike := (jsonValue? record "message").isSome &&
    ((jsonString? record "role").isSome ||
      ["user", "assistant"].contains ((jsonString? record "type").getD ""))
  messageLike && !hasEnvelopeField record "uuid" &&
    !hasEnvelopeField record "parentUuid"

/-- Detect from structured envelope fields inside Lean. This is intentionally
part of the semantic core: the host launcher never reads transcript bytes. -/
def detectFormat (text : String) : Except String String := do
  let records ← detectionRecords text
  let first ← match records.head? with
    | some record => pure record
    | none => .error "empty input"
  if jsonString? first "schema" == some "loom.transcript.v0" then .ok "loom"
  else if (jsonValue? first "info").isSome &&
      (jsonValue? first "messages").isSome &&
      ((jsonValue? first "info").bind (fun info => jsonString? info "id")).isSome &&
      ((jsonValue? first "info").bind (fun info => jsonString? info "version")).isSome
    then .ok "opencode"
  else if (jsonValue? first "composer").isSome &&
      (jsonValue? first "bubbles").isSome then .ok "cursor-ide"
  else if (jsonValue? first "chunkedPrompt").isSome then .ok "gais"
  else if (jsonString? first "session_id").isSome &&
      (jsonValue? first "messages").isSome then .ok "hermes"
  else if jsonString? first "type" == some "session" then .ok "pi"
  else
    let labels :=
      (if records.any (fun record =>
          jsonString? record "type" == some "session_meta") then ["codex"] else []) ++
      (if records.any looksLikeClaudeRecord then ["claude"] else []) ++
      (if records.any looksLikeCursorAgentRecord then ["cursor-agent"] else [])
    match labels with
    | [format] => .ok format
    | [] => .error "unrecognized transcript envelope"
    | _ => .error s!"ambiguous transcript envelope: {String.intercalate ", " labels}"

private def detectsAs (expected source : String) : Bool :=
  match detectFormat source with
  | .ok actual => actual == expected
  | .error _ => false

private def detectionRejects (source : String) : Bool :=
  match detectFormat source with
  | .error _ => true
  | .ok _ => false

example : detectsAs "claude"
    ("{\"type\":\"permission-mode\",\"sessionId\":\"S\"}\n" ++
     "{\"type\":\"user\",\"uuid\":\"u\",\"parentUuid\":null," ++
       "\"sessionId\":\"S\",\"message\":{\"role\":\"user\",\"content\":\"hi\"}}\n") =
    true := by native_decide

example : detectsAs "cursor-agent"
    "{\"role\":\"user\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}}\n" =
    true := by native_decide

example : detectsAs "cursor-ide"
    "{\"composer\":{\"composerId\":\"c\"},\"bubbles\":[]}" = true := by
  native_decide

example : detectsAs "opencode"
    "{\"info\":{\"id\":\"ses_x\",\"version\":\"1.1.34\"},\"messages\":[]}" = true := by
  native_decide

example : detectionRejects
    ("{\"type\":\"user\",\"uuid\":\"u\",\"sessionId\":\"S\",\"message\":{}}\n" ++
     "{\"role\":\"user\",\"message\":{}}\n") = true := by native_decide

example : detectionRejects
    ("{\"type\":\"session\",\"id\":\"S\"}\n{not-json}\n") = true := by
  native_decide

def runDetect (inp : String) (json : Bool) : IO UInt32 := do
  match ← readInputText inp with
  | .error error => IO.eprintln s!"import error: {error}"; pure 2
  | .ok text =>
      match detectFormat text with
      | .error error => IO.eprintln s!"import error: cannot detect source format: {error}"; pure 2
      | .ok format =>
          if json then IO.println (Lean.Json.mkObj [
            ("engine", Lean.Json.str "lean"),
            ("engineVersion", Lean.Json.str coreVersion),
            ("protocolVersion", Lean.Json.str coreProtocol),
            ("coreRevision", Lean.Json.str coreRevision),
            ("targetTriple", Lean.Json.str System.Platform.target),
            ("format", Lean.Json.str format)]).compress
          else IO.println format
          pure 0

def runVersion (json : Bool) : IO UInt32 := do
  if json then IO.println (Lean.Json.mkObj [
    ("engine", Lean.Json.str "lean"),
    ("engineVersion", Lean.Json.str coreVersion),
    ("protocolVersion", Lean.Json.str coreProtocol),
    ("coreRevision", Lean.Json.str coreRevision),
    ("compilerVersion", Lean.Json.str Lean.versionString),
    ("capabilities", coreCapabilitiesJson),
    ("sourceRepository", Lean.Json.str coreSourceRepository),
    ("sourcePath", Lean.Json.str coreSourcePath),
    ("targetTriple", Lean.Json.str System.Platform.target),
    ("wireSchemas", Lean.Json.arr #[Lean.Json.str coreWireSchema])]).compress
  else IO.println s!"agent-convert core {coreVersion} ({coreRevision})"
  pure 0

/-- Read-only import shared by `inspect` and `text`: sidecar sub-agents are
stitched when requested, and cursor-agent is always read through its
path-aware importer. -/
private def importForRead (fromFmt inp : String) (withSubagents : Bool) :
    IO (Except String Transcript) := do
  try
    if withSubagents then
      match fromFmt with
      | "claude"       => importClaudeSessionWithSubagents inp
      | "cursor-agent" => importCursorAgentSessionWithSubagents inp
      | _ => do
          match ← readInputText inp with
          | .ok text => pure (importByFormat fromFmt text)
          | .error error => pure (.error error)
    else do
      if fromFmt == "cursor-agent" then
        importCursorAgentFile inp
      else
        match ← readInputText inp with
        | .ok text => pure (importByFormat fromFmt text)
        | .error error => pure (.error error)
  catch error =>
    pure (.error s!"cannot read '{inp}': {error}")

def runInspect (fromFmt inp : String) (withSubagents json : Bool) : IO UInt32 := do
  let imported ← importForRead fromFmt inp withSubagents
  match imported with
  | .error e => IO.eprintln s!"inspect error: {e}"; pure 2
  | .ok transcript =>
      let vs := violations transcript
      if !vs.isEmpty then
        IO.eprintln s!"inspect error: source imported to a malformed IR ({vs.length} violations)"
        pure 3
      else
        if json then
          IO.println (Lean.Json.mkObj [
            ("engine", Lean.Json.str "lean"),
            ("engineVersion", Lean.Json.str coreVersion),
            ("protocolVersion", Lean.Json.str coreProtocol),
            ("coreRevision", Lean.Json.str coreRevision),
            ("targetTriple", Lean.Json.str System.Platform.target),
            ("source", Lean.Json.str fromFmt),
            ("transcript", exportLoomWireJson transcript)]).compress
        else
          IO.print (s!"# Engine\n\nengine: lean\nengine version: {coreVersion}\ncore revision: {coreRevision}\nsource: {fromFmt}\n\n" ++
            renderTranscript transcript)
        pure 0

/-- Import the source (optionally stitching sidecar sub-agents), optionally apply
the codex TS-parity renderer, well-formedness-check, then export.
Subagent sidecars default on for `loom` / Claude / Cursor Agent targets (and
for inspect); use `--no-subagents` to force main-branch only, or
`--with-subagents` to force sidecar stitch even when the target is flat
(flat exporters still refuse non-main threads). `--ts-parity` currently
affects codex only (the `codexTsParity` D15 renderer); for other formats it
is a no-op at the IR level — their TS-parity is an additive-block drop
handled inside `loom-diff --ts-parity`. -/
def runConvert (fromFmt toFmt inp : String) (outp : Option String)
    (opts : CliOptions) : IO UInt32 := do
  if let some error := targetCliConfigurationError? toFmt opts then
    IO.eprintln s!"invocation error: {error}"
    return 1
  let withSubagents := resolveWithSubagents (some toFmt) opts.withSubagents
  let imported ← try
    if withSubagents then
      match fromFmt with
      | "claude"       => importClaudeSessionWithSubagents inp
      | "cursor-agent" => importCursorAgentSessionWithSubagents inp
      | _ => do
          match ← readInputText inp with
          | .ok text => pure (importByFormat fromFmt text)
          | .error error => pure (.error error)
    else do
      if fromFmt == "cursor-agent" then
        importCursorAgentFile inp
      else
        match ← readInputText inp with
        | .error error => pure (.error error)
        | .ok text =>
            if opts.tsParity && fromFmt == "codex" then
              pure (importCodexCliTsParity text)  -- transform 4 (compaction-latest)
            else if fromFmt == "codex" && toFmt != "loom" then
              pure (importCodexCliActive text)
            else
              pure (importByFormat fromFmt text)
  catch error =>
    pure (.error s!"cannot read '{inp}': {error}")
  match imported with
  | .error e => IO.eprintln s!"import error: {e}"; pure 2
  | .ok t0 =>
    let t0 := if opts.tsParity && fromFmt == "codex" then codexTsParity t0 else t0
    let source := applyCliOverrides toFmt opts t0
    let sourceVs := violations source
    if sourceVs.length > 0 then
      IO.eprintln s!"export error: source imported to a malformed IR ({sourceVs.length} violations) — refusing to export"
      pure 3
    else
      -- Uniform for every source: only genuinely open (unpaired) calls are
      -- carried, because Claude requires tool_use/tool_result pairing. Paired
      -- lifecycles render natively regardless of which harness produced them.
      let (t, callsCarried, resultsCarried) := if toFmt == "claude" then
          let (historical, count) := historicalizeOpenToolCallsForClaude source
          (historical, count, 0)
      else (source, 0, 0)
      let transformedVs := violations t
      if transformedVs.length > 0 then
        IO.eprintln s!"export error: target policy produced a malformed IR ({transformedVs.length} violations) — refusing to export"
        pure 3
      else if withSubagents && hasNonMainThreads t && sidecarTarget toFmt then
        match sidecarProjectionBlocker? toFmt t with
        | some blocker => IO.eprintln s!"export error: {blocker}"; pure 3
        | none =>
          match outp with
          | none =>
              IO.eprintln "export error: sidecar export for sidechain/detached threads requires an output path"
              pure 3
          | some o =>
              match ← exportSidecarByFormat toFmt o t with
              | .error e => IO.eprintln s!"export error: {e}"; pure 3
              | .ok success =>
                  for warning in success.warnings do
                    IO.eprintln s!"warning: {warning}"
                  if opts.json then
                    IO.println (transcriptSummaryJson fromFmt toFmt inp o source t
                      callsCarried resultsCarried).compress
                  else do
                    reportExportObligations toFmt t
                    IO.println s!"wrote {o} + sidecar subagents ({t.entries.size} entries; subagents={subagentThreadCount t})"
                  pure 0
      else
        match runPipeline fromFmt toFmt t with
        | .error e => IO.eprintln s!"export error: {e}"; pure 3
        | .ok out =>
            if opts.json then
              match outp with
              | none => IO.eprintln "invocation error: --json requires an output path"; pure 1
              | some output =>
                  match ← writeOutputText output out with
                  | .error error => IO.eprintln s!"export error: {error}"; pure 3
                  | .ok _ =>
                      IO.println (transcriptSummaryJson fromFmt toFmt inp output source t
                        callsCarried resultsCarried).compress
                      pure 0
            else do
              reportExportObligations toFmt t
              emit out outp t.entries.size

private def runCursorIde (db composerId toFmt : String) (outp : Option String)
    (opts : CliOptions) : IO UInt32 := do
  if let some error := targetCliConfigurationError? toFmt opts then
    IO.eprintln s!"invocation error: {error}"
    return 1
  match ← importCursorIdeFromStore db composerId with
  | .error error => IO.eprintln s!"import error: {error}"; pure 2
  | .ok imported =>
      let source := applyCliOverrides toFmt opts imported
      match runPipeline "cursor-ide" toFmt source with
      | .error error => IO.eprintln s!"export error: {error}"; pure 3
      | .ok output =>
          if opts.json then
            match outp with
            | none =>
                IO.eprintln "invocation error: --json requires an output path"
                pure 1
            | some path =>
                match ← writeOutputText path output with
                | .error error => IO.eprintln s!"export error: {error}"; pure 3
                | .ok _ =>
                    IO.println (transcriptSummaryJson "cursor-ide" toFmt
                      s!"{db}#{composerId}" path source source 0 0).compress
                    pure 0
          else do
            reportExportObligations toFmt source
            emit output outp source.entries.size

/-! ## `resume` — one-command handoff into a resumable target session

`loom resume <to> …` converts a session and publishes it where that harness
will find it, deriving launch metadata from the source instead of asking the
caller to restate facts the transcript already contains. Everything this needs
is already typed in the IR, so it stays in Lean: the source's `EnvInfo`
carries `cwd` and `sessionId`, and `Loom.epochMsToIso8601` turns a recorded
entry time into the launch stamp. No shell, no second JSON parser, no
re-derivation of facts the importer already established.

Today only `claude` is wired as a resume target. Other exporters remain
`convert` destinations until they grow an equivalent store publication path. -/

/-- Claude Code names a project directory by replacing every character outside
`[A-Za-z0-9]` in the absolute cwd with `-`.

The rule is the WHOLE class, not just `/`. Until 2026-07-27 this mapped `/`
alone, which is invisible for a path like `/Users/me/code` and wrong the moment
a segment contains anything else: cwd `/Users/harshwork/code/kernel_search`
produced `-Users-harshwork-code-kernel_search` while Claude Code reads
`-Users-harshwork-code-kernel-search`. The transcript published fine and then
`claude --resume` silently found nothing, because a session in the wrong project
directory is not a failure any exporter check can see.

`utils/src/pi/claudeCode.ts` (`encodeClaudeCwd`) is the oracle here and is
already pinned by `utils/test/pi-session-core.test.mjs`; the examples below
mirror its cases so the two implementations cannot drift apart silently. -/
private def claudeProjectDirName (cwd : String) : String :=
  cwd.map (fun c => if c.isAlphanum then c else '-')

/-- Every char outside `[A-Za-z0-9]` collapses, not just the separator. The
underscore case is the regression that motivated the rule. -/
example : claudeProjectDirName "/Users/harshwork/code/kernel_search" =
    "-Users-harshwork-code-kernel-search" := by native_decide

/-- Mirrors `encodeClaudeCwd("/Users/foo/code")` in the TS oracle. -/
example : claudeProjectDirName "/Users/foo/code" = "-Users-foo-code" := by
  native_decide

/-- Mirrors `encodeClaudeCwd("/tmp/a.b_c")`: dots and underscores both go. -/
example : claudeProjectDirName "/tmp/a.b_c" = "-tmp-a-b-c" := by native_decide

/-- Already-safe strings pass through untouched. -/
example : claudeProjectDirName "plain" = "plain" := by native_decide

/-- Nothing in the class survives, including spaces and non-ASCII. -/
example : claudeProjectDirName "/a b/Ç9" = "-a-b--9" := by native_decide

/-- Latest recorded entry time, as the target launch stamp. The converted
session is stamped from the conversation it contains, not from the wall clock
at conversion time — so converting the same source twice is deterministic. -/
private def latestRecordedIso? (t : Transcript) : Option String :=
  (t.entries.toList.foldl (fun acc entry =>
    match entry.time with
    | .recorded value =>
        match acc with
        | some best => some (if value.ms > best then value.ms else best)
        | none => some value.ms
    | _ => acc) none).map (fun ms => Loom.epochMsToIso8601 ⟨ms⟩)

private def firstRecordedIso? (t : Transcript) : Option String :=
  (t.entries.toList.foldl (fun acc entry =>
    match entry.time with
    | .recorded value =>
        match acc with
        | some best => some (if value.ms < best then value.ms else best)
        | none => some value.ms
    | _ => acc) none).map (fun ms => Loom.epochMsToIso8601 ⟨ms⟩)

/-- First genuine user prompt, for the session picker. Control envelopes are
angle-bracketed and are not what a human typed. -/
private def firstUserPrompt? (t : Transcript) : Option String :=
  t.entries.toList.findSome? (fun entry =>
    match entry.payload with
    | .userMsg blocks => blocks.findSome? (fun block =>
        match block with
        | .text text =>
            let trimmed := text.trim
            if trimmed.isEmpty || trimmed.startsWith "<" then none
            else some (((trimmed.splitOn "\n").headD trimmed).take 200).toString
        | _ => none)
    | _ => none)

private def conversationalEntryCount (t : Transcript) : Nat :=
  t.entries.toList.countP (fun entry =>
    match entry.payload with
    | .userMsg _ | .assistantMsg _ | .envMsg _ => true
    | _ => false)

private def sessionIndexEntryJson (sessionId dest cwd firstPrompt created modified : String)
    (count : Nat) : Lean.Json :=
  Lean.Json.mkObj [
    ("sessionId", Lean.Json.str sessionId),
    ("fullPath", Lean.Json.str dest),
    ("firstPrompt", Lean.Json.str firstPrompt),
    ("summary", Lean.Json.str firstPrompt),
    ("messageCount", Lean.Json.num (Lean.JsonNumber.fromNat count)),
    ("created", Lean.Json.str created),
    ("modified", Lean.Json.str modified),
    ("projectPath", Lean.Json.str cwd),
    ("isSidechain", Lean.Json.bool false)]

/-- Replace this session's row and keep every other row byte-intact. An
unreadable or malformed index is rebuilt rather than propagated, but a readable
one is never reordered or rewritten beyond the single replaced entry. -/
private def mergeSessionIndex (existing : Option Lean.Json) (sessionId : String)
    (entry : Lean.Json) : Lean.Json :=
  let priorEntries : List Lean.Json :=
    match existing with
    | some index =>
        match (index.getObjVal? "entries").toOption.bind (fun a => (a.getArr?).toOption) with
        | some rows => rows.toList.filter (fun row =>
            ((row.getObjVal? "sessionId" >>= Lean.Json.getStr?).toOption) != some sessionId)
        | none => []
    | none => []
  Lean.Json.mkObj [
    ("version", Lean.Json.num (Lean.JsonNumber.fromNat 1)),
    ("entries", Lean.Json.arr (priorEntries ++ [entry]).toArray)]

/-! ### Resolving a bare session id

A session id is what a person has: it is in the harness UI, in a resume command,
in a bug report. The file behind it is an implementation detail of whichever
store wrote it. Requiring the path means the caller does the search by hand
before the converter will run, which is the difference between one command and
three. -/

/-- Files at most `depth` directory levels under `root` whose name ends with
`suffix`.

Depth-BOUNDED rather than unbounded: these stores nest a couple of levels
(`~/.codex/sessions/2026/07/27/`), and a converter has no business walking an
arbitrary subtree of someone's home directory because an id did not match.
Unreadable directories are skipped rather than fatal — a store the caller cannot
read is a store the session is not in. -/
private partial def sessionFilesEndingWith
    (root : System.FilePath) (suffix : String) (depth : Nat) :
    IO (Array System.FilePath) := do
  if depth == 0 then return #[]
  unless ← root.pathExists do return #[]
  unless ← root.isDir do return #[]
  let entries ← try root.readDir catch _ => pure #[]
  let mut hits : Array System.FilePath := #[]
  for entry in entries do
    if ← entry.path.isDir then
      hits := hits ++ (← sessionFilesEndingWith entry.path suffix (depth - 1))
    else if entry.fileName.endsWith suffix then
      hits := hits.push entry.path
  return hits

/-- Where each harness keeps its sessions, and how deep to look.

One suffix rule covers all three, because every store ends its filename with the
id: codex `rollout-<ts>-<id>.jsonl`, Claude `<id>.jsonl`, pi `<ts>_<id>.jsonl`.
Codex gets the deeper budget for its `YYYY/MM/DD/` nesting — and the budget is a
depth, not a date pattern, because that tree also holds non-date directories. -/
private def sessionStoreRoots (home : String) : List (String × System.FilePath × Nat) :=
  [("codex", home ++ "/.codex/sessions", 4),
   ("claude", home ++ "/.claude/projects", 2),
   ("pi", home ++ "/.pi/agent/sessions", 2)]

/-- Resolve a positional argument to a transcript file.

An existing path is used as given. Otherwise the argument is treated as a
session id and looked up across the known stores.

Three rules keep this from guessing. The DESTINATION store is not a source:
`install-claude` writes into `~/.claude/projects`, so a Claude file with this id
is this command's own previous output, not an input. Skipping it is what makes
the command re-runnable — otherwise the second run of the same conversion is
always "ambiguous" with the first run's result. Ambiguity among the remaining
stores is still an ERROR: every match is printed and the explicit
two-positional form demanded, because picking one would silently convert a
session the caller did not name. And the format comes from `detectFormat`
reading the bytes, never from which directory the file sat in — the store layout
is a hint for FINDING the file, and a hint is not evidence about what is inside
it. -/
private def resolveSessionInput (arg : String) (destinationStore : String) :
    IO (Except String (String × String)) := do
  let readDetect := fun (path : String) => do
    match ← readInputText path with
    | .error error => pure (.error s!"cannot read {path}: {error}")
    | .ok text =>
        match detectFormat text with
        | .error error => pure (.error s!"cannot detect source format of {path}: {error}")
        | .ok format => pure (.ok (format, path))
  if ← (System.FilePath.mk arg).pathExists then
    return ← readDetect arg
  let some home ← IO.getEnv "HOME"
    | return .error "HOME is not set, so a session id cannot be resolved to a file"
  let mut found : Array System.FilePath := #[]
  let mut inDestination : Array System.FilePath := #[]
  for (store, root, depth) in sessionStoreRoots home do
    let hits ← sessionFilesEndingWith root (arg ++ ".jsonl") depth
    if store == destinationStore then
      inDestination := inDestination ++ hits
    else
      found := found ++ hits
  match found.toList with
  | [] =>
      -- Distinguish "nowhere" from "only where this command would write it";
      -- the second is a different situation and a different thing to do next.
      if inDestination.isEmpty then
        return .error (s!"no file and no session named '{arg}' in " ++
          "~/.codex/sessions, ~/.claude/projects, or ~/.pi/agent/sessions")
      else
        return .error (s!"session '{arg}' exists only as an installed " ++
          s!"{destinationStore} session, which is this command's output rather " ++
          "than a source; pass an explicit <from> <input> to convert it anyway")
  | [only] => readDetect only.toString
  | several =>
      return .error (s!"session '{arg}' is ambiguous across {several.length} files; " ++
        "pass an explicit <from> <input> instead:\n  " ++
        String.intercalate "\n  " (several.map (·.toString)))

/-- Convert a session and install it where Claude Code will find it, deriving
every target field from the source instead of asking the caller to restate
facts the transcript already contains. -/
def runInstallClaude (fromFmt inp : String) (opts : CliOptions) : IO UInt32 := do
  let sourceText ← match ← readInputText inp with
    | .ok text => pure text
    | .error error => IO.eprintln s!"import error: {error}"; return 2
  let source ← match importByFormat fromFmt sourceText with
    | .ok transcript => pure transcript
    | .error error => IO.eprintln s!"import error: {error}"; return 2
  let some cwd := opts.cwd.orElse (fun _ => source.env.cwd)
    | IO.eprintln "invocation error: source records no cwd; pass --target-cwd"; return 1
  let some sessionId := opts.sessionId.orElse (fun _ => source.env.sessionId)
    | IO.eprintln "invocation error: source records no session id; pass --target-session-id"
      return 1
  let some stamp := opts.targetTimestamp.orElse (fun _ => latestRecordedIso? source)
    | IO.eprintln "invocation error: source has no recorded entry time; pass --target-timestamp"
      return 1
  let some home ← IO.getEnv "HOME"
    | IO.eprintln "invocation error: HOME is not set"; return 1
  let projectsRoot := (← IO.getEnv "CLAUDE_PROJECTS").getD (home ++ "/.claude/projects")
  let destDir : System.FilePath := projectsRoot ++ "/" ++ claudeProjectDirName cwd
  let dest : System.FilePath := destDir / (sessionId ++ ".jsonl")
  if ← dest.pathExists then
    IO.println s!"note: replacing existing transcript at {dest}"
  match ← (IO.FS.createDirAll destDir).toBaseIO with
  | .ok _ => pure ()
  | .error error =>
      IO.eprintln s!"export error: cannot create {destDir}: {error}"
      return 3
  let convertOpts := { opts with
    cwd := some cwd, sessionId := some sessionId, targetTimestamp := some stamp,
    harnessVersion := some (opts.harnessVersion.getD claudeTargetValidationBuild) }
  let status ← runConvert fromFmt "claude" inp (some dest.toString) convertOpts
  if status != 0 then return status
  -- Index refresh is a separate, non-fatal step: the transcript is already
  -- published and resumable by id even if the picker entry cannot be written.
  -- MERGE-ONLY. An index that already exists is this directory's own record of
  -- every session in it, so adding a row to it is additive and safe. CREATING
  -- one is not: a directory with no index has its sessions discovered from the
  -- `.jsonl` files themselves, and writing a fresh single-row index there
  -- publishes the claim "this directory contains one session" over a directory
  -- that may contain many. The installed transcript is resumable by id either
  -- way, so the picker entry is never worth risking the picker's completeness.
  let indexPath := destDir / "sessions-index.json"
  if ← indexPath.pathExists then
    let existing := match Lean.Json.parse (← IO.FS.readFile indexPath) with
      | .ok parsed => some parsed
      | .error _ => none
    let entry := sessionIndexEntryJson sessionId dest.toString cwd
      ((firstUserPrompt? source).getD "") ((firstRecordedIso? source).getD stamp) stamp
      (conversationalEntryCount source)
    match ← (IO.FS.writeFile indexPath
        ((mergeSessionIndex existing sessionId entry).pretty ++ "\n")).toBaseIO with
    | .ok _ => pure ()
    | .error error =>
        IO.eprintln s!"warning: transcript installed but session index not updated: {error}"
  IO.println s!"\nresume with:\n  cd {cwd} && claude --resume {sessionId}"
  pure 0

/-! ### One-command conversion

`runConvert` is the explicit protocol surface used by compatibility hosts. The
public CLI is deliberately smaller: give `loom convert` a session id or path
and a target. This wrapper resolves and detects the source, derives only target
values that have an unambiguous continuation default, and delegates to the same
checked pipeline. Explicit flags always win. -/

/-- Stable UUIDv8 for a foreign source whose native session id is not a UUID.
An explicit `--target-session-id` is never repaired, so invalid caller input
still receives the target validator's diagnostic. -/
private def smartGeneratedUuid (material : String) : String :=
  let upper := (String.hash ("agent-convert.smart.uuid.a|" ++ material)).toNat
  let lower := (String.hash ("agent-convert.smart.uuid.b|" ++ material)).toNat
  let packed := upper * (2 ^ 64) + lower
  let raw := (Nat.toDigits 16 packed).reverse.take 30 |>.reverse
  let digits := List.replicate (30 - raw.length) '0' ++ raw
  String.ofList (digits.take 8) ++ "-" ++
    String.ofList ((digits.drop 8).take 4) ++ "-8" ++
    String.ofList ((digits.drop 12).take 3) ++ "-8" ++
    String.ofList ((digits.drop 15).take 3) ++ "-" ++
    String.ofList ((digits.drop 18).take 12)

private def smartTargetOptions (toFmt : String) (source : Transcript)
    (opts : CliOptions) : CliOptions :=
  let continuation : CliOptions := { opts with
    cwd := opts.cwd.orElse (fun _ => source.env.cwd)
    sessionId := opts.sessionId.orElse (fun _ => source.env.sessionId)
    targetTimestamp := opts.targetTimestamp.orElse (fun _ => latestRecordedIso? source) }
  match toFmt with
  | "claude" => { continuation with
      harnessVersion := continuation.harnessVersion.orElse
        (fun _ => some claudeTargetValidationBuild) }
  | "pi" => { continuation with
      provider := continuation.provider.orElse (fun _ =>
        if source.origin.format == .pi then
          source.env.provider.orElse (fun _ => some "deepseek")
        else some "deepseek")
      model := continuation.model.orElse (fun _ =>
        if source.origin.format == .pi then
          source.env.model.orElse (fun _ => some "deepseek-v4-flash")
        else some "deepseek-v4-flash")
      harnessVersion := continuation.harnessVersion.orElse (fun _ => some piTargetVersion)
      piAssistantHistory := continuation.piAssistantHistory.orElse (fun _ => some "context") }
  | "codex" => { continuation with
      sessionId := match opts.sessionId with
        | some explicit => some explicit
        | none => match source.env.sessionId with
          | some native =>
              if codexUuidValid native then some native
              else some (smartGeneratedUuid (native ++ "|" ++ toString source.entries.size))
          | none => some (smartGeneratedUuid
              (source.origin.sourceRef ++ "|" ++ toString source.entries.size))
      provider := continuation.provider.orElse (fun _ =>
        if source.origin.format == .codexCli then
          source.env.provider.orElse (fun _ => some "openai")
        else some "openai")
      model := continuation.model.orElse (fun _ =>
        if source.origin.format == .codexCli then
          source.env.model.orElse (fun _ => some "gpt-5.5")
        else some "gpt-5.5")
      harnessVersion := continuation.harnessVersion.orElse
        (fun _ => some codexCliTargetVersion)
      codexApprovalPolicy := continuation.codexApprovalPolicy.orElse
        (fun _ => some "on-request")
      codexNetworkAccess := continuation.codexNetworkAccess.orElse (fun _ => some false)
      codexExcludeTmpdirEnvVar := continuation.codexExcludeTmpdirEnvVar.orElse
        (fun _ => some true)
      codexExcludeSlashTmp := continuation.codexExcludeSlashTmp.orElse (fun _ => some true)
      codexSummary := continuation.codexSummary.orElse (fun _ => some "auto") }
  | "opencode" => { continuation with
      provider := continuation.provider.orElse (fun _ => some "openai")
      model := continuation.model.orElse (fun _ => some "gpt-5")
      harnessVersion := continuation.harnessVersion.orElse
        (fun _ => some openCodeTargetVersion) }
  | _ => opts

private def smartTargetDefaultsAreComplete : Bool :=
  let source : Transcript := {
    threads := #[{ kind := .main }]
    entries := #[]
    env := {
      cwd := some "/source/project"
      provider := some "source-provider"
      model := some "source-model"
      sessionId := some "41000000-0000-4000-8000-000000000000" }
    origin := { format := .claudeCode, sourceRef := "smart-defaults" }
  }
  let claude := smartTargetOptions "claude" source {}
  let pi := smartTargetOptions "pi" source {}
  let codex := smartTargetOptions "codex" source {}
  let overridden := smartTargetOptions "codex" source {
    provider := some "chosen-provider", model := some "chosen-model" }
  claude.cwd == source.env.cwd &&
    claude.sessionId == source.env.sessionId &&
    claude.harnessVersion == some claudeTargetValidationBuild &&
    pi.provider == some "deepseek" &&
    pi.model == some "deepseek-v4-flash" &&
    pi.harnessVersion == some piTargetVersion &&
    pi.piAssistantHistory == some "context" &&
    codex.provider == some "openai" &&
    codex.model == some "gpt-5.5" &&
    codex.harnessVersion == some codexCliTargetVersion &&
    codex.codexApprovalPolicy == some "on-request" &&
    codex.codexNetworkAccess == some false &&
    codex.codexExcludeTmpdirEnvVar == some true &&
    codex.codexExcludeSlashTmp == some true &&
    codex.codexSummary == some "auto" &&
    overridden.provider == some "chosen-provider" &&
    overridden.model == some "chosen-model"

example : smartTargetDefaultsAreComplete = true := by native_decide

private def smartTarget (target : String) : Bool :=
  ["loom", "pi", "claude", "codex", "cursor-agent", "opencode"].contains target

private def explicitSourceName (source : String) : Bool :=
  ["loom", "pi", "claude", "codex", "cursor-agent", "hermes", "gais",
    "google-ai-studio", "cursor-ide", "opencode"].contains source

/-- `loom convert <session-id|input> <target> [output]`.

With no output, Claude is installed into its native project store and every
other target is written to stdout. Supplying an output always requests a plain
file conversion. The longer explicit-source form remains supported below for
existing callers. -/
def runSmartConvert (ref toFmt : String) (outp : Option String)
    (opts : CliOptions) : IO UInt32 := do
  unless smartTarget toFmt do
    IO.eprintln s!"invocation error: unsupported target '{toFmt}'"
    return 1
  let destinationStore := if toFmt == "claude" && outp.isNone then "claude" else ""
  let (fromFmt, inp) ← match ← resolveSessionInput ref destinationStore with
    | .error error => IO.eprintln s!"invocation error: {error}"; return 1
    | .ok resolved => pure resolved
  let resolution := s!"resolved {ref} -> {fromFmt}: {inp}"
  -- Keep stdout machine-clean when it is the conversion artifact.
  if outp.isNone && toFmt != "claude" then IO.eprintln resolution
  else IO.println resolution
  if toFmt == "claude" && outp.isNone then
    runInstallClaude fromFmt inp opts
  else
    let text ← match ← readInputText inp with
      | .error error => IO.eprintln s!"import error: {error}"; return 2
      | .ok value => pure value
    let source ← match importByFormat fromFmt text with
      | .error error => IO.eprintln s!"import error: {error}"; return 2
      | .ok transcript => pure transcript
    runConvert fromFmt toFmt inp outp (smartTargetOptions toFmt source opts)

/-- `loom text <session-id|input>...` — the search projection (`Loom.Text`).

Emits JSON lines on stdout: one `session` row per input followed by one
`entry` row per IR entry, then continues with the next input. A source that
cannot be resolved or imported yields a single `error` row for that input;
the other inputs are still projected, so an indexer can batch many files per
process. Exit status is 0 when at least one input was projected and 2 when
every input failed. Malformed-IR sources are projected anyway, with the
violation count on the session row, because a search index would rather see
a damaged session than lose it. -/
def runText (refs : List String) (withSubagents : Bool) : IO UInt32 := do
  let mut failures := 0
  for ref in refs do
    let errorRow := fun (error : String) =>
      (Lean.Json.mkObj [
        ("kind", Lean.Json.str "error"),
        ("file", Lean.Json.str ref),
        ("error", Lean.Json.str error)]).compress
    match ← resolveSessionInput ref "" with
    | .error error =>
        IO.println (errorRow error)
        failures := failures + 1
    | .ok (fromFmt, path) =>
        match ← importForRead fromFmt path withSubagents with
        | .error error =>
            IO.println (errorRow error)
            failures := failures + 1
        | .ok transcript =>
            let rows := (searchSessionRow path fromFmt transcript).compress ::
              (searchRows transcript).map Lean.Json.compress
            IO.print (String.intercalate "\n" rows ++ "\n")
  pure (if failures == refs.length then 2 else 0)

/-! ## `loom search` — native cross-store transcript search

Queries every known session store, matching a whitespace-separated,
case-insensitive AND-of-tokens against the canonical `Loom.searchText`
projection of each entry. A cheap raw-byte prefilter skips importing any
file that cannot contain every token, so a specific query imports only a
handful of sessions even across a multi-gigabyte store. This keeps the
match semantics in the verified core rather than re-deriving them per host.
-/

/-- Whitespace (space/tab/newline/carriage-return). -/
private def isSearchSpace (c : Char) : Bool :=
  c == ' ' || c == '\t' || c == '\n' || c == '\r'

/-- Does `haystack` contain `needle` as a substring? Both are supplied at the
same case by the caller (lowercased for token matching, raw for cwd paths). -/
private def substrPresent (haystack needle : String) : Bool :=
  (haystack.splitOn needle).length > 1

/-- Every token present in the (already same-cased) haystack. An empty token
list matches nothing; callers guard against it. -/
private def matchesAllTokens (haystackLower : String) (tokens : List String) : Bool :=
  tokens.all (substrPresent haystackLower)

/-- Split a query into lowercased, non-empty whitespace-separated tokens. -/
private def searchTokens (query : String) : List String :=
  let normalized := query.map (fun c => if isSearchSpace c then ' ' else c)
  List.filterMap
    (fun t => if t.isEmpty then none else some (t.map Char.toLower))
    (normalized.splitOn " ")

example : searchTokens "  Cron-Server\tFoo " = ["cron-server", "foo"] := by native_decide
example : matchesAllTokens "the cron-server logs" ["cron-server", "logs"] = true := by
  native_decide
example : matchesAllTokens "only cron here" ["cron", "server"] = false := by native_decide

/-- Flatten whitespace to single spaces and clip to `n` characters for one-line output. -/
private def searchSnippet (text : String) (n : Nat) : String :=
  let flat := text.map (fun c => if isSearchSpace c then ' ' else c)
  if flat.length ≤ n then flat else (flat.toList.take n).asString ++ "…"

/-- Session stores walked by `search`, with the filename suffix and depth budget
for each. Extends the resolve-time roots with the cursor-agent and hermes
stores so search covers every locally readable harness. -/
private def searchStoreRoots (home : String) :
    List (String × System.FilePath × String × Nat) :=
  [("codex", home ++ "/.codex/sessions", ".jsonl", 4),
   ("claude", home ++ "/.claude/projects", ".jsonl", 2),
   ("pi", home ++ "/.pi/agent/sessions", ".jsonl", 2),
   ("cursor-agent", home ++ "/.cursor/projects", ".jsonl", 6),
   ("hermes", home ++ "/.hermes/sessions", ".json", 1)]

private structure SearchHit where
  store : String
  file  : String
  role  : String
  index : Nat
  text  : String

private def searchCwdOk (cwdFilter : Option String) (t : Transcript) : Bool :=
  match cwdFilter with
  | none => true
  | some c => (t.env.cwd.map (substrPresent · c)).getD false

/-- Every entry of one imported session that matches the query and role filter. -/
private def searchFileHits (store file : String) (roleFilter : Option String)
    (tokens : List String) (t : Transcript) : Array SearchHit := Id.run do
  let mut hits : Array SearchHit := #[]
  for (entry, idx) in t.entries.toList.zipIdx do
    let erole := Loom.searchRole entry.payload
    if roleFilter.isNone || roleFilter == some erole then
      let etext := Loom.searchText entry.payload
      if matchesAllTokens (etext.map Char.toLower) tokens then
        hits := hits.push { store, file, role := erole, index := idx, text := etext }
  return hits

/-- `loom search <query>` — match across every locally readable session store.
Options: `--store <name>` restricts to one harness, `--role <r>` to one role,
`--cwd <substr>` to sessions whose recorded cwd contains the substring,
`--limit <n>` caps hits (default 200), `--json` emits one row per hit. Matching
is a case-insensitive AND of whitespace tokens; regex is intentionally not in
the core. Unreadable, undetectable, or malformed sessions are skipped. -/
def runSearch (query : String) (opts : CliOptions) : IO UInt32 := do
  let tokens := searchTokens query
  if tokens.isEmpty then
    IO.eprintln "search error: empty query"
    return 1
  let some home ← IO.getEnv "HOME"
    | IO.eprintln "search error: HOME is not set"; return 1
  let limit := opts.limit.getD 200
  let mut hits : Array SearchHit := #[]
  let mut scanned : Nat := 0
  let mut imported : Nat := 0
  for (store, root, suffix, depth) in searchStoreRoots home do
    if opts.store.isSome && opts.store != some store then
      continue
    let files ← sessionFilesEndingWith root suffix depth
    for file in files do
      if hits.size ≥ limit then break
      scanned := scanned + 1
      -- Raw-byte prefilter: only import files that can contain every token.
      match ← readInputText file.toString with
      | .error _ => pure ()
      | .ok text =>
        if matchesAllTokens (text.map Char.toLower) tokens then
          match detectFormat text with
          | .error _ => pure ()
          | .ok fmt =>
            match ← importForRead fmt file.toString false with
            | .error _ => pure ()
            | .ok t =>
              imported := imported + 1
              if searchCwdOk opts.cwd t then
                hits := hits ++ searchFileHits store file.toString opts.role tokens t
  let shown := hits.toList.take limit
  if opts.json then
    for h in shown do
      IO.println (Lean.Json.mkObj [
        ("store", Lean.Json.str h.store),
        ("file", Lean.Json.str h.file),
        ("role", Lean.Json.str h.role),
        ("index", Lean.Json.num (Lean.JsonNumber.fromNat h.index)),
        ("snippet", Lean.Json.str (searchSnippet h.text 400))]).compress
  else
    let mut lastFile := ""
    for h in shown do
      if h.file != lastFile then
        IO.println ""
        IO.println s!"── [{h.store}] {h.file}"
        lastFile := h.file
      IO.println s!"   [#{h.index} {h.role}] {searchSnippet h.text 160}"
    IO.println ""
    IO.println s!"{shown.length} match(es); scanned {scanned} sessions, imported {imported}"
  return 0

def usage : String :=
  "loom — convert a coding-agent session to another harness\n\n" ++
  "  loom convert <session-id|input> <target> [output] [options]\n" ++
  "  loom text <session-id|input>...   search rows (JSON lines) for indexing\n\n" ++
  "  loom search <query> [--store <h>] [--role <r>] [--cwd <s>] [--limit <n>]\n\n" ++
  "  target: loom | pi | claude | codex | cursor-agent | opencode\n" ++
  "  no output: install Claude sessions; write other targets to stdout\n" ++
  "  output:    write a converted file\n\n" ++
  "Options override detected/default target values:\n" ++
  "  --target-cwd <dir>  --target-provider <name>  --target-model <name>\n" ++
  "  --target-session-id <id>  --target-timestamp <iso>\n" ++
  "  --with-subagents | --no-subagents  --json\n"

def main (args : List String) : IO UInt32 := do
  let (opts, pos) ← match parseCli args with
    | .ok parsed => pure parsed
    | .error e => IO.eprintln s!"invocation error: {e}\n{usage}"; return 1
  match pos with
  | ["convert", ref, target]    => runSmartConvert ref target none opts
  | ["convert", a, b, c]        =>
      -- Preserve the established `<from> <to> <input>` form. Otherwise the
      -- third positional is the output of the one-command form.
      if explicitSourceName a && smartTarget b then
        runConvert a b c none opts
      else
        runSmartConvert a b (some c) opts
  | ["convert", f, t, inp, o]   => runConvert f t inp (some o) opts
  | ["inspect", f, inp]         =>
      runInspect f inp (resolveWithSubagents none opts.withSubagents) opts.json
  | ["detect", inp]             => runDetect inp opts.json
  | "text" :: refs              =>
      if refs.isEmpty then IO.eprintln usage; pure 1
      else runText refs (resolveWithSubagents none opts.withSubagents)
  | ["search", query]           => runSearch query opts
  | ["search"]                  => IO.eprintln usage; pure 1
  | ["version"]                 => runVersion opts.json
  | ["self-test-sidecar-publication"] => runSidecarPublicationSelfTest
  | ["install-claude", f, inp] => runInstallClaude f inp opts
  -- One positional: a path or a bare session id, with the format detected from
  -- the bytes. The two-positional form above stays exactly as it was — this CLI
  -- has production callers, so the shorthand is additive.
  | ["install-claude", ref] =>
      match ← resolveSessionInput ref "claude" with
      | .error error => IO.eprintln s!"invocation error: {error}"; pure 1
      | .ok (format, path) =>
          IO.println s!"resolved {ref} -> {format}: {path}"
          runInstallClaude format path opts
  | ["cursor-ide", db, cid, to] => runCursorIde db cid to none opts
  | ["cursor-ide", db, cid, to, outp] => runCursorIde db cid to (some outp) opts
  | _ => IO.eprintln usage; pure 1
