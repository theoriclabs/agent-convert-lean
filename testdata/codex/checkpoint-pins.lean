import LoomConvert.CodexCli

open Loom LoomConvert

private def malformedCount (t : Transcript) : Nat :=
  t.importNotes.countP (fun note => match note.kind with
    | .other "codex-malformed-compaction-record" => true
    | _ => false)

private def checkpointImportsAgree (source : String) : Bool :=
  match importCodexCli source, importCodexCliActive source with
  | .ok full, .ok active =>
      malformedCount full == malformedCount active && malformedCount full == 0 &&
      codexActiveContextCompactionBoundaries? full ==
        codexActiveContextCompactionBoundaries? active &&
      (codexActiveContextCompactionBoundaries? full).any (fun xs => xs.size == 1) &&
      codexActiveContextExcludedRecordCount? full == some 0
  | _, _ => false

example : checkpointImportsAgree (include_str "0.144.1/compacted-rollout.jsonl") = true := by native_decide
example : checkpointImportsAgree (include_str "0.153.0/compacted-rollout.jsonl") = true := by native_decide
example : checkpointImportsAgree (include_str "0.162.1/compacted-rollout.jsonl") = true := by native_decide

private def retainedDialogueImported : Bool :=
  match importCodexCliActive (include_str "0.162.1/compacted-rollout.jsonl") with
  | .error _ => false
  | .ok t =>
      t.entries.size == 8 &&
      t.entries[0]?.any (fun e => (match e.payload with | .userMsg [.text text] => text == "RETAINED-USER Build the task viewer." | _ => false) &&
        e.origin.rawId == some "msg_01" && e.time == .absent) &&
      t.entries[1]?.any (fun e => (match e.payload with | .assistantMsg [.text text] => text == "RETAINED-ASSISTANT The task viewer renders correctly." | _ => false) &&
        e.origin.rawId == some "msg_03") &&
      t.entries[2]?.any (fun e => (match e.payload with | .userMsg [.text text] => text == "RETAINED-USER Deploy only to the synthetic preview." | _ => false) &&
        e.origin.rawId == some "msg_02") &&
      (t.entries.filter (fun e => match e.payload with | .userMsg _ => true | _ => false)).size == 2

example : retainedDialogueImported = true := by native_decide

private def unknownRetainedContentWarns : Bool :=
  let source := (include_str "0.162.1/compacted-rollout.jsonl").replace
    "\"retained_context\":" "\"retained_context_v3\":"
  [importCodexCli source, importCodexCliActive source].all (fun result =>
    match result with
    | .error _ => false
    | .ok t => t.importNotes.any (fun note =>
        note.kind == .other "codex-unconsumed-checkpoint-content" &&
        note.detail == "retained_context_v3: 3 message-shaped items not imported" &&
        note.loc == some "record2"))

example : unknownRetainedContentWarns = true := by native_decide
