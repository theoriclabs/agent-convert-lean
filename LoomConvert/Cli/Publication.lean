import LoomConvert.Cli.Formats
import LoomConvert.Sidecar

/-! Typed format routing for the shared sidecar publication engine. -/
namespace LoomConvert.Cli
open Loom

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


end LoomConvert.Cli
