import Loom.WellFormed

/-!
# Human-readable transcript rendering

This is the review surface for a `Transcript`. It is deliberately separate
from `LoomConvert.Parity.normalize`: parity is a lossy comparison projection,
while this renderer exposes roles, threads, tool names and arguments, call
links, error provenance, compactions, events, and import judgments.
-/

namespace Loom

private def optionText (fallback : String) : Option String -> String
  | some value => value
  | none => fallback

private def formatText : Format -> String
  | .pi => "pi"
  | .claudeCode => "claude"
  | .codexCli => "codex"
  | .cursorAgent => "cursor-agent"
  | .cursorIde => "cursor-ide"
  | .hermes => "hermes"
  | .googleAiStudio => "google-ai-studio"
  | .openCode => "opencode"
  | .other name => name

private def timeText : Time -> String
  | .recorded timestamp => s!"recorded epoch-ms={timestamp.ms}"
  | .interpolated timestamp basis =>
      s!"interpolated epoch-ms={timestamp.ms}; basis={basis}"
  | .sequenced ordinal => s!"sequenced ordinal={ordinal}"
  | .absent => "absent"

private def callRefText : CallRef -> String
  | .resolved entry block => s!"entry {entry}, block {block}"
  | .unresolved rawId note =>
      let id := optionText "(no id)" rawId
      s!"unresolved {id}: {note}"

private def errorText : ErrorSignal -> String
  | .native false => "success (recorded)"
  | .native true => "error (recorded)"
  | .inferred false heuristic => s!"success (inferred: {heuristic})"
  | .inferred true heuristic => s!"error (inferred: {heuristic})"
  | .unrecorded => "unknown (not recorded)"

private def dispositionText : EntryDisposition -> String
  | .native => "native"
  | .historicalUnverified => "historical/unverified carrier-derived"

private def userBlockLines : UserBlock -> List String
  | .text text => [text]
  | .media mime locator => [s!"[media {mime}] {locator}"]
  | .unmodeled label raw => [s!"[unmodeled user block: {label}]", raw.pretty]

private def assistantBlockLines : AssistantBlock -> List String
  | .text text => [text]
  | .thinking text signature =>
      let sig := if signature.isSome then "present" else "absent"
      [s!"[thinking; signature={sig}]", text]
  | .toolCall name args rawId =>
      let id := optionText "absent" rawId
      [s!"[tool call {name.raw}; id={id}]", args.pretty]
  | .media mime locator => [s!"[media {mime}] {locator}"]
  | .unmodeled label raw => [s!"[unmodeled assistant block: {label}]", raw.pretty]

/-- Human inspect exposes signature presence without printing opaque encrypted
payloads. Canonical JSON retains the exact signature for audit/round trip. -/
example : assistantBlockLines (.thinking "plan" (some "encrypted-secret")) =
    ["[thinking; signature=present]", "plan"] := by native_decide

private def envBlockLines : EnvBlock -> List String
  | .toolResult call content error =>
      [s!"[tool result for {callRefText call}; {errorText error}]"] ++
        content.flatMap userBlockLines
  | .unmodeled label raw => [s!"[unmodeled environment block: {label}]", raw.pretty]

private def payloadLines : Payload -> String × List String
  | .userMsg blocks => ("USER", blocks.flatMap userBlockLines)
  | .assistantMsg blocks => ("ASSISTANT", blocks.flatMap assistantBlockLines)
  | .envMsg blocks => ("ENVIRONMENT", blocks.flatMap envBlockLines)
  | .otherMsg role blocks => (s!"ROLE {role}", blocks.flatMap userBlockLines)
  | .compaction summary coverage tokensBefore =>
      let extent := match coverage with
        | .knownPrefix firstKept => s!"known prefix before entry {firstKept}"
        | .unknownPrefix => "unknown prefix"
      let tokens := tokensBefore.map toString |>.getD "unknown"
      ("COMPACTION",
        [s!"coverage: {extent}",
         s!"tokens before: {tokens}", summary])
  | .event event =>
      match event with
      | .modelChange prev next =>
          let fromModel := optionText "unknown" prev
          let toModel := optionText "unknown" next
          ("EVENT", [s!"model: {fromModel} -> {toModel}"])
      | .thinkingLevelChange prev next =>
          let fromLevel := optionText "unknown" prev
          let toLevel := optionText "unknown" next
          ("EVENT", [s!"thinking level: {fromLevel} -> {toLevel}"])
      | .permissionMode mode => ("EVENT", [s!"permission mode: {mode}"])
      | .branchSummary summary => ("EVENT", ["branch summary", summary])
      | .custom label raw => ("EVENT", [s!"custom: {label}", raw.pretty])

private def threadKindText : ThreadKind -> String
  | .main => "main"
  | .sidechain anchor => s!"sidechain anchored at {callRefText anchor}"
  | .detached note => s!"detached: {note}"

private def renderThread (pair : Thread × Nat) : String :=
  let thread := pair.1
  let index := pair.2
  s!"- {index}: {threadKindText thread.kind}" ++
    (thread.label.map (fun label => s!" ({label})") |>.getD "")

private def renderEntry (pair : Entry × Nat) : String :=
  let entry := pair.1
  let index := pair.2
  let parent := entry.parent.map toString |>.getD "root"
  let rawId := optionText "absent" entry.origin.rawId
  let (role, lines) := payloadLines entry.payload
  let body := if lines.isEmpty then "(empty)" else String.intercalate "\n" lines
  s!"\n## {index} {role}\nthread: {entry.thread}; parent: {parent}; time: {timeText entry.time}\ndisposition: {dispositionText entry.disposition}\norigin: {formatText entry.origin.format}; source: {entry.origin.sourceRef}; raw id: {rawId}\n\n{body}"

private def historicalReviewEntry : Entry := {
  payload := .assistantMsg [.text "historical payload"]
  origin := { format := .other "fixture", sourceRef := "review" }
  disposition := .historicalUnverified
}

example : (renderEntry (historicalReviewEntry, 0)).contains
    "disposition: historical/unverified carrier-derived" = true := by native_decide

private def renderNote (pair : ImportNote × Nat) : String :=
  let note := pair.1
  let index := pair.2
  let source := optionText "unknown" note.loc
  s!"- {index}: {reprStr note.kind}; source={source}; {note.detail}"

/-- Deterministic review rendering. No source bytes are re-parsed here: every
line comes from the canonical, structurally checked representation. -/
def renderTranscript (transcript : Transcript) : String :=
  let session := optionText "unknown" transcript.env.sessionId
  let cwd := optionText "unknown" transcript.env.cwd
  let model := optionText "unknown" transcript.env.model
  let provider := optionText "unknown" transcript.env.provider
  let harnessVersion := optionText "unknown" transcript.env.harnessVersion
  let instructions := match transcript.env.instructions with
    | some value => s!"present ({value.length} characters)"
    | none => "absent"
  let active := transcript.activeLeaf.map toString |>.getD "none"
  let violationCount := (violations transcript).length
  let header :=
    s!"# Transcript\n\nsession: {session}\ncwd: {cwd}\nmodel: {model}\nprovider: {provider}\nharness version: {harnessVersion}\ninstructions: {instructions}\nentries: {transcript.entries.size}\nactive leaf: {active}\nviolations: {violationCount}"
  let threads :=
    "\n\n# Threads\n" ++ String.intercalate "\n" (transcript.threads.toList.zipIdx.map renderThread)
  let entries := String.intercalate "\n" (transcript.entries.toList.zipIdx.map renderEntry)
  let notes := if transcript.importNotes.isEmpty then ""
    else "\n\n# Import Judgments\n" ++
      String.intercalate "\n" (transcript.importNotes.zipIdx.map renderNote)
  header ++ threads ++ "\n\n# Entries\n" ++ entries ++ notes ++ "\n"

end Loom
