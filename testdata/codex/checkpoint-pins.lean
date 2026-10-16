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
