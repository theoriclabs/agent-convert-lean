import Viewer.Server

/-! `loom_viewer_checks`: the catalog and the HTTP layer over a fixture home under
`.lake/checks-home`, one lifecycle fixture per harness, laid out as each store lays out its files.
Run from the `viewer` directory. -/

open Viewer

def check (name : String) (ok : Bool) : IO Unit := do
  if ok then IO.println s!"ok   {name}" else throw (IO.userError s!"FAIL {name}")

def copyFile (src dst : System.FilePath) : IO Unit := do
  if let some dir := dst.parent then IO.FS.createDirAll dir
  IO.FS.writeBinFile dst (← IO.FS.readBinFile src)

def claudeId := "11111111-1111-1111-1111-111111111111"
def codexId := "22222222-2222-2222-2222-222222222222"
def piId := "33333333-3333-3333-3333-333333333333"

/-- Fixture name and where its store keeps it, relative to the home directory. -/
def fixtures : List (String × String) := [
  ("claude.jsonl", s!".claude/projects/-proj/{claudeId}.jsonl"),
  ("codex.jsonl", s!".codex/sessions/2026/01/01/rollout-2026-01-01T00-00-00-{codexId}.jsonl"),
  ("pi.jsonl", s!".pi/agent/sessions/-slug-/2026-01-01T00-00-00-000Z_{piId}.jsonl"),
  ("cursor-agent.jsonl", ".cursor/projects/a/b/c/d/e/agent.jsonl"),
  ("hermes.json", ".hermes/sessions/hermes.json")]

def expectedIds : List (String × String) :=
  [("claude", claudeId), ("codex", codexId), ("pi", piId), ("cursor-agent", "agent"), ("hermes", "hermes")]

/-- Some tool call of the conversation carries its result. -/
def hasResolvedCall (c : Conversation) : Bool :=
  c.messages.any fun m => m.parts.any fun
    | .toolCall _ _ _ (some _) => true
    | _ => false

def sessionOf (sessions : Array Viewer.Session) (h : Harness) : IO Viewer.Session :=
  match sessions.find? (·.file.harness == h) with
  | some s => pure s
  | none => throw (IO.userError s!"no {h.slug} session on the page")

def jsonArraySize (reply : LeanApi.Test.Reply) (field : String) : Nat :=
  match reply.json? with
  | some j => match j.getObjVal? field >>= Lean.Json.getArr? with
    | .ok arr => arr.size
    | .error _ => 0
  | none => 0

def jsonNat (reply : LeanApi.Test.Reply) (field : String) : Option Nat :=
  match reply.json? with
  | some j => (j.getObjVal? field >>= Lean.Json.getNat?).toOption
  | none => none

def catalogChecks (catalog : Catalog) : IO Unit := do
  IO.println "• scan"
  let files ← catalog.scan
  check "scan finds exactly 5 session files" (files.size == 5)
  let ids := files.map fun f => (f.harness.slug, f.id)
  for (slug, id) in expectedIds do
    check s!"scan finds {slug} {id}" (ids.contains (slug, id))
  check "scan is newest first" ((files.zip (files.extract 1 files.size)).all fun (a, b) => a.modifiedMs ≥ b.modifiedMs)
  check "scan reads sizes" (files.all fun f => f.bytes > 0)
  check "find codex" ((← catalog.find .codexCli codexId).isSome)
  check "find a missing id" ((← catalog.find .codexCli "missing").isNone)

  IO.println "• pages"
  let (all, total) ← catalog.page {}
  check "page with no filter: 5 sessions, total 5" (all.size == 5 && total == 5)
  let (codex, codexTotal) ← catalog.page { harness := some .codexCli }
  check "page with harness codex: 1" (codex.size == 1 && codexTotal == 1 && codex[0]!.file.id == codexId)
  let (byText, textTotal) ← catalog.page { text := "3333" }
  check "page with text 3333: 1 (the pi id)" (byText.size == 1 && textTotal == 1 && byText[0]!.file.id == piId)
  let (window, windowTotal) ← catalog.page { offset := 3, limit := 1 }
  check "page window offset 3 limit 1: 1 of 5" (window.size == 1 && windowTotal == 5)
  let (byTitle, _) ← catalog.page { text := "NO RESULT WAS RECORDED" }
  check "page with text matches a cached title, ignoring case" (byTitle.size == 1 && byTitle[0]!.file.harness == .hermes)
  let (byCwd, _) ← catalog.page { text := "lifecycle-pi" }
  check "page with text matches a cached cwd" (byCwd.size == 1 && byCwd[0]!.file.harness == .pi)

  IO.println "• previews"
  for s in all do
    IO.println s!"     {s.file.harness.slug}: {repr s.preview}"
  let claude ← sessionOf all .claudeCode
  check "claude preview: cwd" (claude.preview.cwd == some "/tmp/lifecycle-claude")
  check "claude preview: no user words in the fixture, so no title" claude.preview.title.isNone
  check "claude preview: startedMs" claude.preview.startedMs.isSome
  check "claude preview: turns > 0" (claude.preview.turns > 0)
  let codex ← sessionOf all .codexCli
  check "codex preview: cwd" (codex.preview.cwd == some "/tmp/lifecycle-codex")
  check "codex preview: no user words in the fixture, so no title" codex.preview.title.isNone
  check "codex preview: startedMs" codex.preview.startedMs.isSome
  check "codex preview: turns > 0" (codex.preview.turns > 0)
  let pi ← sessionOf all .pi
  check "pi preview: cwd" (pi.preview.cwd == some "/tmp/lifecycle-pi")
  check "pi preview: no user words in the fixture, so no title" pi.preview.title.isNone
  check "pi preview: startedMs" pi.preview.startedMs.isSome
  check "pi preview: turns > 0" (pi.preview.turns > 0)
  let hermes ← sessionOf all .hermes
  check "hermes preview: title is the person's first words" (hermes.preview.title == some "no result was recorded for the last call")
  check "hermes preview: model" (hermes.preview.model == some "fixture-model")
  check "hermes preview: turns > 0" (hermes.preview.turns > 0)
  let cursor ← sessionOf all .cursorAgent
  check "cursor-agent preview: no user words in the fixture, so no title" cursor.preview.title.isNone
  check "cursor-agent preview: turns > 0" (cursor.preview.turns > 0)
  check "previews are cached" ((← catalog.previews.get).size == 5)

  IO.println "• conversations"
  for s in all do
    match ← catalog.conversation s.file with
    | .error e => throw (IO.userError s!"{s.file.harness.slug}: import failed: {e}")
    | .ok c =>
      IO.println s!"     {s.file.harness.slug}: {c.messages.size} messages, {c.sidechains} sidechains, {c.importNotes} import notes"
      check s!"{s.file.harness.slug} conversation has messages" (c.messages.size > 0)
  for h in [Harness.claudeCode, .codexCli, .pi, .hermes] do
    let s ← sessionOf all h
    let .ok c ← catalog.conversation s.file | throw (IO.userError s!"{h.slug}: import failed")
    check s!"{h.slug} conversation shows a tool call with its result" (hasResolvedCall c)
  check "conversation cache holds the 5" ((← catalog.conversations.get).entries.size == 5)
  let full := (List.range 9).foldl (fun (cache : ConversationCache) i => cache.insert s!"k{i}" default) {}
  check "conversation cache keeps 8, dropping the oldest" (full.entries.size == 8 && !(full.entries.contains "k0") && full.entries.contains "k8")

def httpChecks (catalog : Catalog) (web : System.FilePath) : IO Unit := do
  IO.println "• http"
  let svc := service catalog web
  let health ← LeanApi.Test.get svc "/api/health"
  check "GET /api/health is 200 {\"ok\":true}" (health.status == 200 && health.body == "{\"ok\":true}")
  let list ← LeanApi.Test.get svc "/api/sessions"
  check "GET /api/sessions is 200 with 5 sessions, total 5"
    (list.status == 200 && jsonArraySize list "sessions" == 5 && jsonNat list "total" == some 5)
  let filtered ← LeanApi.Test.get svc "/api/sessions?harness=codex"
  check "GET /api/sessions?harness=codex lists 1" (filtered.status == 200 && jsonArraySize filtered "sessions" == 1)
  let searched ← LeanApi.Test.get svc "/api/sessions?q=3333&limit=200"
  check "GET /api/sessions?q=3333 lists 1" (searched.status == 200 && jsonArraySize searched "sessions" == 1)
  let window ← LeanApi.Test.get svc "/api/sessions?offset=4&limit=1"
  check "GET /api/sessions?offset=4&limit=1 lists 1 of 5"
    (window.status == 200 && jsonArraySize window "sessions" == 1 && jsonNat window "total" == some 5)
  check "GET /api/sessions?limit=abc is 422" ((← LeanApi.Test.get svc "/api/sessions?limit=abc").status == 422)
  check "GET /api/sessions?offset=-1 is 422" ((← LeanApi.Test.get svc "/api/sessions?offset=-1").status == 422)
  check "GET /api/sessions?harness=nope is 422" ((← LeanApi.Test.get svc "/api/sessions?harness=nope").status == 422)
  let conversation ← LeanApi.Test.get svc s!"/api/sessions/codex/{codexId}"
  check "GET /api/sessions/codex/<id> is 200 with messages"
    (conversation.status == 200 && jsonArraySize conversation "messages" > 0)
  check "GET /api/sessions/nope/x is 422" ((← LeanApi.Test.get svc "/api/sessions/nope/x").status == 422)
  check "GET /api/sessions/codex/missing is 404" ((← LeanApi.Test.get svc "/api/sessions/codex/missing").status == 404)
  let index ← LeanApi.Test.get svc "/"
  check s!"GET / answers {index.status} (200 when web/dist is built, else 404)" (index.status == 200 || index.status == 404)
  check "GET /nothing is 404" ((← LeanApi.Test.get svc "/nothing").status == 404)

def main : IO UInt32 := do
  let cwd ← IO.currentDir
  let home := cwd / ".lake" / "checks-home"
  if ← home.pathExists then IO.FS.removeDirAll home
  for (name, rel) in fixtures do
    copyFile (cwd / ".." / "testdata" / "lifecycle" / name) (home / rel)
  let catalog ← Catalog.create home.toString
  catalogChecks catalog
  httpChecks catalog (cwd / "web" / "dist")
  LeanApi.blockingThreads.releaseIdle
  IO.println "loom_viewer_checks: all checks passed"
  return 0
