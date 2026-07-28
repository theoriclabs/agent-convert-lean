import LoomConvert.CursorIde

/-!
# LoomConvert.CursorIdeActuator — the one non-file-IO actuator

Cursor IDE's source is a SQLite `state.vscdb`, the only format whose actuator
isn't plain file IO. Per the bridge doctrine the actuator is thin and carries
no meaning: this reads composer + bubble rows via the `sqlite3` CLI subprocess
and assembles the `{composer, bubbles}` JSON that `importCursorIde` (the
semantic core) consumes. A libsqlite3 `@[extern]` FFI would remove the
subprocess dependency for a shipped binary; the subprocess is the simplest
first cut and keeps zero C in the tree.
-/

namespace LoomConvert
open Loom

/-- Run a read-only query via the `sqlite3` CLI. Actuator = a pair of hands. -/
def runSqlite (dbPath query : String) : IO (Except String String) := do
  try
    let out ← IO.Process.output {
      cmd := "sqlite3", args := #["-readonly", "-batch", dbPath, query] }
    if out.exitCode == 0 then
      pure (.ok out.stdout.trimAscii.toString)
    else if out.exitCode == 255 &&
        out.stderr.contains "could not execute external process" then
      pure (.error s!"cannot start sqlite3: {out.stderr.trimAscii.toString}")
    else
      pure (.error s!"sqlite3 failed ({out.exitCode}): {out.stderr}")
  catch error =>
    pure (.error s!"cannot start sqlite3: {error}")

private def sqlString (value : String) : String :=
  "'" ++ value.replace "'" "''" ++ "'"

private def workspaceForComposer (headers : Lean.Json) (composerId : String) : Lean.Json :=
  let matchedHeaders := match (headers.getObjVal? "allComposers" >>= Lean.Json.getArr?).toOption with
    | some composers => composers.toList.filter (fun (composer : Lean.Json) =>
        (composer.getObjVal? "composerId" >>= Lean.Json.getStr?).toOption == some composerId)
    | none => []
  match matchedHeaders with
  | [composer] =>
      match (composer.getObjVal? "workspaceIdentifier").toOption with
      | some workspace@(.obj _) => workspace
      | _ => Lean.Json.null
  | _ => Lean.Json.null

/-- Read a Cursor IDE composer thread + its bubbles from a `state.vscdb` into
the JSON shape `importCursorIde` consumes: `{composer, bubbles:[...]}`, bubbles
ordered per the composer's `fullConversationHeadersOnly`. -/
def readCursorIdeStore (dbPath composerId : String) : IO (Except String String) := do
  let composerKey := sqlString s!"composerData:{composerId}"
  match ← runSqlite dbPath s!"SELECT value FROM cursorDiskKV WHERE key={composerKey}" with
  | .error e => pure (.error e)
  | .ok composerStr =>
    if composerStr.isEmpty then pure (.error s!"composer {composerId} not found") else
    match Lean.Json.parse composerStr with
    | .error e => pure (.error s!"composer JSON parse: {e}")
    | .ok cj => do
      let bubbleIds : List String :=
        match (cj.getObjVal? "fullConversationHeadersOnly" >>= Lean.Json.getArr?).toOption with
        | some arr => arr.toList.filterMap (fun h => (h.getObjVal? "bubbleId" >>= Lean.Json.getStr?).toOption)
        | none => []
      let mut bubbles : Array String := #[]
      for bid in bubbleIds do
        let bubbleKey := sqlString s!"bubbleId:{composerId}:{bid}"
        let r ← runSqlite dbPath s!"SELECT value FROM cursorDiskKV WHERE key={bubbleKey}"
        match r with
        | .ok b => if !b.isEmpty then bubbles := bubbles.push b
        | .error e => return .error e
      let workspaceIdentifier ←
        match ← runSqlite dbPath
            "SELECT value FROM ItemTable WHERE key='composer.composerHeaders'" with
        | .error e => return .error e
        | .ok headersStr =>
            if headersStr.isEmpty then
              pure Lean.Json.null
            else
              match Lean.Json.parse headersStr with
              | .error e => return .error s!"composer headers JSON parse: {e}"
              | .ok headers => pure (workspaceForComposer headers composerId)
      let json := "{\"composer\":" ++ composerStr
        ++ ",\"workspaceIdentifier\":" ++ workspaceIdentifier.compress
        ++ ",\"bubbles\":[" ++ String.intercalate "," bubbles.toList ++ "]}"
      pure (.ok json)

/-- End-to-end: read the store and import to the Loom IR (the shipped path for
Cursor IDE — sqlite actuator + semantic core, pure Lean + one subprocess). -/
def importCursorIdeFromStore (dbPath composerId : String) : IO (Except String Transcript) := do
  match ← readCursorIdeStore dbPath composerId with
  | .error e => pure (.error e)
  | .ok json => pure (importCursorIde json)

private def actuatorHeadersFixture : Lean.Json := Lean.Json.mkObj [
  ("allComposers", Lean.Json.arr #[
    Lean.Json.mkObj [
      ("composerId", Lean.Json.str "one"),
      ("workspaceIdentifier", Lean.Json.mkObj [
        ("uri", Lean.Json.mkObj [("fsPath", Lean.Json.str "/one")])])],
    Lean.Json.mkObj [
      ("composerId", Lean.Json.str "duplicate"),
      ("workspaceIdentifier", Lean.Json.mkObj [
        ("uri", Lean.Json.mkObj [("fsPath", Lean.Json.str "/first")])])],
    Lean.Json.mkObj [
      ("composerId", Lean.Json.str "duplicate"),
      ("workspaceIdentifier", Lean.Json.mkObj [
        ("uri", Lean.Json.mkObj [("fsPath", Lean.Json.str "/second")])])]])]

example : sqlString "a'b" = "'a''b'" := by native_decide
example : (workspaceForComposer actuatorHeadersFixture "one").compress =
    (Lean.Json.mkObj [
      ("uri", Lean.Json.mkObj [("fsPath", Lean.Json.str "/one")])]).compress := by
  native_decide
example : (workspaceForComposer actuatorHeadersFixture "duplicate").compress = "null" := by
  native_decide
example : (workspaceForComposer actuatorHeadersFixture "missing").compress = "null" := by
  native_decide

end LoomConvert
