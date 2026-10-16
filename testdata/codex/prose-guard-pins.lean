import LoomConvert.Cli.Formats

open Loom LoomConvert Lean

private def proseGuardPinned : Bool :=
  match importCodexCliActive (include_str "0.162.1/notes-tool.jsonl") with
  | .error _ => false
  | .ok transcript =>
    let args := Json.mkObj [("path", Json.str "priority")]
    let text := claudeOpenToolCarrierText { raw := "read_file" } args (some "call_notes")
    let legacy := (Json.mkObj [("type", Json.str "assistant"), ("message", Json.mkObj [
      ("role", Json.str "assistant"), ("content", Json.arr #[Json.mkObj [
        ("type", Json.str "text"), ("text", Json.str text)]])])]).compress
    let duplicate := { transcript with entries := transcript.entries ++ (transcript.entries.toList.drop 1 |>.take 1).toArray }
    let historical := { transcript with entries := transcript.entries.modify 1 (fun entry =>
      { entry with disposition := .historicalUnverified }) }
    let literal := { transcript with entries := transcript.entries.push {
      parent := some 3, payload := .userMsg [.text text], origin := transcript.origin } }
    ["claude", "pi", "codex", "opencode"].all (fun target =>
      (avoidableProseCarrierBlocker? target transcript legacy).isSome &&
      (avoidableProseCarrierBlocker? target duplicate legacy).isNone &&
      (avoidableProseCarrierBlocker? target historical legacy).isNone &&
      (avoidableProseCarrierBlocker? target literal legacy).isNone) &&
      (avoidableProseCarrierBlocker? "loom" transcript legacy).isNone &&
      (avoidableProseCarrierBlocker? "cursor-agent" transcript legacy).isNone &&
      (avoidableNativeHistoryBlocker? "claude" transcript).isNone &&
      claudeToolCallEmitsNativeAt transcript 1 0

example : proseGuardPinned = true := by native_decide
