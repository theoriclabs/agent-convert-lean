import LeanApi
import Viewer.Catalog
import Viewer.Wire

/-! # The server

LeanAPI's raw router over the catalog: the route table of CONTRACT.md. The typed `api!` layer is
pure by construction and cannot read files, so the handlers here are plain `Req → IO Res`. -/

namespace Viewer
open LeanApi
open Lean (Json toJson)

private def problem (status : Nat) (detail : String) : Res := (Problem.make status (some detail)).toRes

/-- The page size when the request names none, and the most a request may ask for. -/
def defaultLimit : Nat := 40
def maxLimit : Nat := 200

/-- A numeric query parameter: `default` when absent, `none` when present but not a number. -/
private def natQuery (req : Req) (name : String) (default : Nat) : Option Nat :=
  match req.query? name with
  | none => some default
  | some s => s.toNat?

/-- The page a listing request asks for, or the 422 that answers a malformed one. -/
def pageOf (req : Req) : Except Res Page := do
  let harness ← match req.query? "harness" with
    | none => pure none
    | some slug => match Harness.parse slug with
      | some h => pure (some h)
      | none => throw (problem 422 s!"unknown harness: {slug}")
  let offset ← match natQuery req "offset" 0 with
    | some n => pure n
    | none => throw (problem 422 "offset must be a number")
  let limit ← match natQuery req "limit" defaultLimit with
    | some n => pure (min n maxLimit)
    | none => throw (problem 422 "limit must be a number")
  return { harness, text := (req.query? "q").getD "", offset, limit }

private def sessionsHandler (c : Catalog) : App := fun req =>
  match pageOf req with
  | .error res => pure res
  | .ok page => do
    let (sessions, total) ← c.page page
    pure (Res.json (Json.mkObj [("sessions", toJson sessions), ("total", toJson total)]))

private def conversationHandler (c : Catalog) : App := fun req => do
  let slug := (req.param? "harness").getD ""
  let id := (req.param? "id").getD ""
  match Harness.parse slug with
  | none => pure (problem 422 s!"unknown harness: {slug}")
  | some h =>
    match ← c.find h id with
    | none => pure Problem.notFound.toRes
    | some file =>
      match ← c.conversation file with
      | .ok conversation => pure (Res.ofJson conversation)
      | .error e => pure (problem 500 e)

/-- `web/index.html`, read at request time. -/
private def indexHandler (web : System.FilePath) : App := fun _ => do
  let path := web / "index.html"
  if ← path.pathExists then return Res.html (← IO.FS.readFile path)
  return Problem.notFound.toRes

/-- A file of the web directory, read at request time. -/
private def staticHandler (web : System.FilePath) (name contentType : String) : App := fun _ => do
  let path := web / name
  if ← path.pathExists then return Res.bytes (← IO.FS.readBinFile path) contentType
  return Problem.notFound.toRes

def routes (c : Catalog) (web : System.FilePath) : List Route := [
  Route.get "/api/health" fun _ => pure (Res.json (Json.mkObj [("ok", Json.bool true)])),
  Route.get "/api/sessions" (sessionsHandler c),
  Route.get "/api/sessions/{harness}/{id}" (conversationHandler c),
  Route.get "/" (indexHandler web),
  Route.get "/app.js" (staticHandler web "app.js" "text/javascript; charset=utf-8"),
  Route.get "/style.css" (staticHandler web "style.css" "text/css; charset=utf-8"),
  Route.get "/thread.css" (staticHandler web "thread.css" "text/css; charset=utf-8")]

def service (c : Catalog) (web : System.FilePath) : Service :=
  Service.ofRouter (Router.build! (routes c web)) (Stack.of [accessLog, recover])

end Viewer
