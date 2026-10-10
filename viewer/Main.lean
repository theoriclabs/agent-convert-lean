import Viewer.Server

/-! `loom_viewer`: serve the catalog of this machine's sessions and the browser page.

Environment: `LOOM_VIEWER_HOME` (store roots are `<home>/<Store.root>`; default `$HOME`),
`LOOM_VIEWER_PORT` (default 4800), `LOOM_VIEWER_HOST` (default 127.0.0.1), `LOOM_VIEWER_WEB`
(the built page, default `web/dist`). -/

open Viewer LeanApi

def main (_args : List String) : IO UInt32 := do
  let homeEnv ← IO.getEnv "LOOM_VIEWER_HOME"
  let userHome ← IO.getEnv "HOME"
  let home := homeEnv.getD (userHome.getD ".")
  let port := ((← IO.getEnv "LOOM_VIEWER_PORT").bind String.toNat?).getD 4800
  let host := (← IO.getEnv "LOOM_VIEWER_HOST").getD "127.0.0.1"
  let web : System.FilePath := ⟨(← IO.getEnv "LOOM_VIEWER_WEB").getD "web/dist"⟩
  let catalog ← Catalog.create home
  let index := web / "index.html"
  unless ← index.pathExists do
    IO.eprintln s!"Loom viewer: {index} is missing, so only the API is served; run `node scripts/build.mjs` to build the page."
  serve (service catalog web) { host, port := port.toUInt16 }
    (onReady := fun p => do
      IO.println s!"Loom viewer: http://{host}:{p}"
      (← IO.getStdout).flush)
  return 0
