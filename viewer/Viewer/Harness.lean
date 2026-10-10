import Loom
import LoomConvert

/-! # Harnesses and their stores

The harnesses whose sessions this machine may hold, and how each keeps them. Everything a
harness does differently lives in its `Store` instance: where its files are, how deep, how a
file name spells the session id, which importer reads it, and which leading user texts are the
harness's own scaffolding rather than the person's words. The catalog and the server never
branch on the harness; they ask the instance. Adding a harness is one instance. -/

namespace Viewer

/-- A harness with a local session store. Closed by design: the viewer shows what is on disk. -/
inductive Harness where
  | claudeCode
  | codexCli
  | pi
  | cursorAgent
  | hermes
  deriving Repr, DecidableEq, Inhabited

def Harness.all : List Harness := [.claudeCode, .codexCli, .pi, .cursorAgent, .hermes]

/-- The spelling in URLs and on the wire; `loom search --store` uses the same names. -/
def Harness.slug : Harness → String
  | .claudeCode => "claude"
  | .codexCli => "codex"
  | .pi => "pi"
  | .cursorAgent => "cursor-agent"
  | .hermes => "hermes"

def Harness.parse : String → Option Harness
  | "claude" => some .claudeCode
  | "codex" => some .codexCli
  | "pi" => some .pi
  | "cursor-agent" => some .cursorAgent
  | "hermes" => some .hermes
  | _ => none

/-- The human name. -/
def Harness.label : Harness → String
  | .claudeCode => "Claude Code"
  | .codexCli => "Codex CLI"
  | .pi => "Pi"
  | .cursorAgent => "Cursor Agent"
  | .hermes => "Hermes"

theorem Harness.parse_slug (h : Harness) : Harness.parse h.slug = some h := by
  cases h <;> rfl

/-- How one harness keeps its sessions and what its files mean. -/
class Store (h : Harness) where
  /-- The store root, relative to the home directory. -/
  root : String
  /-- How many directory levels below the root session files sit (Loom's depth budget). -/
  depth : Nat
  /-- The file name suffix of a session file. -/
  suffix : String := ".jsonl"
  /-- Whether a file name with that suffix is a session; a store may keep other files beside them. -/
  isSession : String → Bool := fun _ => true
  /-- The session id spelled by a file name without its suffix. -/
  sessionId : String → String := id
  /-- Parse a session's full text with the harness's importer. -/
  parse : String → Except String Loom.Transcript
  /-- Whether a user text is the harness talking to itself (slash-command envelopes, injected
  environment context), not the person. Such texts never become a title and render as system. -/
  scaffolding : String → Bool := fun _ => false
  /-- Whether a transcript is a session the harness ran for itself (Codex's auto-review of a
  request action), not a conversation with the person. -/
  internal : Loom.Transcript → Bool := fun _ => false

/-- The last `n` characters of `s`. -/
private def takeRight (s : String) (n : Nat) : String :=
  String.ofList (s.toList.drop (s.length - n))

private def afterLast (sep : Char) (s : String) : String :=
  match (s.splitOn (String.singleton sep)).getLast? with
  | some last => last
  | none => s

private def startsWithAny (prefixes : List String) (s : String) : Bool :=
  let s := String.ofList (s.toList.dropWhile Char.isWhitespace)
  prefixes.any fun p => s.startsWith p

/-- `<proj>/<uuid>.jsonl`. Slash commands and their output arrive as user rows wrapped in
`<command-name>`, `<local-command-stdout>` and friends. -/
instance : Store .claudeCode where
  root := ".claude/projects"
  depth := 2
  parse := LoomConvert.importClaudeCode
  scaffolding := startsWithAny ["<command-name>", "<command-message>", "<local-command-caveat>",
    "<local-command-stdout>", "<local-command-stderr>", "<system-reminder>", "<task-notification>"]

/-- `YYYY/MM/DD/rollout-<timestamp>-<uuid>.jsonl`: the id is the last 36 characters of the stem.
The harness injects environment context and instructions as user rows. -/
instance : Store .codexCli where
  root := ".codex/sessions"
  depth := 4
  sessionId := fun stem => takeRight stem 36
  parse := LoomConvert.importCodexCli
  scaffolding := startsWithAny ["<environment_context>", "<user_instructions>", "<permissions",
    "<INSTRUCTIONS>", "<turn_aborted>", "The following is the Codex agent history"]
  internal := fun t => t.env.model == some "codex-auto-review"

/-- `<cwd-slug>/<timestamp>_<uuid>.jsonl`: the id follows the last underscore. -/
instance : Store .pi where
  root := ".pi/agent/sessions"
  depth := 2
  sessionId := afterLast '_'
  parse := LoomConvert.importPi

instance : Store .cursorAgent where
  root := ".cursor/projects"
  depth := 6
  parse := LoomConvert.importCursorAgent

/-- `session_<stamp>_<id>.json`, beside an index `sessions.json` that is not a session. -/
instance : Store .hermes where
  root := ".hermes/sessions"
  depth := 1
  suffix := ".json"
  isSession := fun name => name.startsWith "session_"
  parse := LoomConvert.importHermes

/-- The instance behind a harness value, for code that walks `Harness.all`. -/
@[instance_reducible] def Harness.store : (h : Harness) → Store h
  | .claudeCode => inferInstance
  | .codexCli => inferInstance
  | .pi => inferInstance
  | .cursorAgent => inferInstance
  | .hermes => inferInstance

example : (Harness.store .codexCli).sessionId "rollout-2026-10-09T14-41-45-01a12244-c621-7971-870e-e2bd8ee07b96" =
    "01a12244-c621-7971-870e-e2bd8ee07b96" := by native_decide
example : (Harness.store .pi).sessionId "2026-05-29T04-04-53-275Z_019e71e8-0b99-7348-baf3-00c33edf2562" =
    "019e71e8-0b99-7348-baf3-00c33edf2562" := by native_decide
example : (Harness.store .claudeCode).scaffolding "<command-name>/model</command-name>" = true := by native_decide
example : (Harness.store .claudeCode).scaffolding "Build a GREAT overview" = false := by native_decide
example : (Harness.store .hermes).isSession "sessions.json" = false := by native_decide
example : (Harness.store .hermes).isSession "session_20260504_201140_ea41df.json" = true := by native_decide

end Viewer
