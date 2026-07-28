import Loom
import LoomConvert

open Loom LoomConvert

/-- Minimal well-formed Pi session (structure only). Fields match the current
Pi importer contract used by `parity/fixtures/pi.jsonl`. -/
def sample : String := String.intercalate "\n" [
  "{\"type\":\"session\",\"id\":\"s1\",\"cwd\":\"/tmp/x\",\"version\":3,\"timestamp\":\"2024-01-01T00:00:00.000Z\"}",
  "{\"type\":\"message\",\"id\":\"a1\",\"parentId\":null,\"timestamp\":\"2024-01-01T00:00:00.000Z\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"hi\"}],\"timestamp\":1704067200000}}",
  "{\"type\":\"message\",\"id\":\"a2\",\"parentId\":\"a1\",\"timestamp\":\"2024-01-01T00:00:00.001Z\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"hmm\",\"thinkingSignature\":\"SIG\"},{\"type\":\"text\",\"text\":\"yo\"},{\"type\":\"toolCall\",\"id\":\"tc1\",\"name\":\"Bash\",\"arguments\":{}}],\"api\":\"anthropic-messages\",\"provider\":\"anthropic\",\"model\":\"fixture-model\",\"usage\":{\"input\":0,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0,\"totalTokens\":0,\"cost\":{\"input\":0,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0,\"total\":0}},\"stopReason\":\"toolUse\",\"timestamp\":1704067200001}}"
]

-- Import works: 2 entries, and the IR is well-formed (0 structural violations).
#eval match importPi sample with
  | .ok t => s!"entries={t.entries.size} violations={(Loom.violations t).length}"
  | .error e => s!"import error: {e}"

-- Round-trip: import → export → re-import, then compare the load-bearing
-- projections. rawId + parent links must survive exactly (the extras/rawId
-- round-trip thesis, executable).
#eval
  match importPi sample with
  | .error e => s!"import err: {e}"
  | .ok t1 =>
    match importPi (exportPi t1) with
    | .error e => s!"re-import err: {e}"
    | .ok t2 =>
      let ids1 := t1.entries.toList.filterMap (fun (e : Entry) => e.origin.rawId)
      let ids2 := t2.entries.toList.filterMap (fun (e : Entry) => e.origin.rawId)
      let par1 := t1.entries.toList.map (fun (e : Entry) => e.parent)
      let par2 := t2.entries.toList.map (fun (e : Entry) => e.parent)
      let bcount := fun (e : Entry) => match e.payload with
        | Payload.userMsg bs => bs.length
        | Payload.assistantMsg bs => bs.length
        | Payload.envMsg bs => bs.length
        | Payload.otherMsg _ bs => bs.length
        | _ => 0
      let blocks1 := t1.entries.toList.map bcount
      let blocks2 := t2.entries.toList.map bcount
      s!"ids_match={ids1 == ids2} ({ids1}) parents_match={par1 == par2} ({par2}) blocks_match={blocks1 == blocks2} ({blocks1})"

-- Signature preservation: the assistant's thinking block keeps its signature
-- through the round-trip (the pi thinkingSignature-on-disk fact, claim L12).
#eval
  match importPi sample >>= (fun t => importPi (exportPi t)) with
  | .error e => s!"err: {e}"
  | .ok t =>
    let sigs := t.entries.toList.flatMap (fun (e : Entry) => match e.payload with
      | Payload.assistantMsg bs => bs.filterMap (fun b => match b with
          | AssistantBlock.thinking _ (some g) => some g | _ => none)
      | _ => [])
    s!"signatures_preserved={sigs}"
