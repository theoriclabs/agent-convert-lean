import LoomConvert.Pi

/-!
# LoomConvert.Parity — the harness that gates TS retirement (S9, RC1)

The decide-pin technique from the bridge guide (Tgrad §6.2): fold a captured
reference into the build so drift is a **compile error**. Two halves of RC1:

* **Self-parity** — `import → export → import` is stable under `normalize`.
* **Cross-parity** — a format importer's `normalize` output equals the TS
  toolchain's, captured as a pinned golden by `parity/capture-parity.ts`.

`normalize` is **positional and synthesis-independent**: entries are keyed by
array index and parent index, never by the per-format synthesized id strings
(claNNNN / cdxNNNN / caNNNN), and tool calls project to name only. So the gate
checks structure (roles, block kinds, names, text, parent tree) and is
comparable across every format regardless of how each side mints ids. It also
excludes provider signatures: TS `parseSession`'s Block model has no
`thinkingSignature`, so signature preservation is a separate Lean-only property
(claim L12) — an adjudicated "leanCore is strictly better here" divergence.
-/

namespace LoomConvert
open Loom

/-- Per-role block projections, shared byte-for-byte with the TS capture
script. A STRUCTURAL-CONTENT SKELETON: it deliberately excludes the
representation choices where Loom refines/enriches TS (verified separately,
adjudicated leanCore improvements) — synthesized ids, provider signatures,
tool-name canonicalization (`call`, not the name), and the toolResult wrapper
(projected to its content text to match TS's flatten). What it DOES check:
entry count/positions, parent tree, roles, block kinds, and text/thinking
content. Under the role-content-sum there is one tag per role's block type.

The `tsParity : Bool` parameter selects the projection *variant*. Loom's
importers are deliberately RICHER than the TS converters: they keep `media`
(images/attachments) and `unmodeled` (unknown block kinds like Claude's
`fallback`) blocks that TS silently drops. With `tsParity := false` (the
default, driving `normalize`) every block projects — byte-identical to the
pinned goldens. With `tsParity := true` (driving `normalizeTsParity`) those two
Loom-richer constructors project to `none` and vanish, so a transcript that
differs from TS ONLY by extra media/unmodeled blocks projects identically to
TS's output. Blocks are collected with `filterMap`, so a dropped block leaves no
empty `;`-segment behind. -/
def userBlockTag (tsParity : Bool) : UserBlock → Option String
  | .text s => some ("text:" ++ s)
  | .media m _ => if tsParity then none else some ("media:" ++ m)
  | .unmodeled l _ => if tsParity then none else some ("unmodeled:" ++ l)

def assistantBlockTag (tsParity : Bool) : AssistantBlock → Option String
  | .text s => some ("text:" ++ s)
  | .thinking s _ => some ("think:" ++ s)
  | .toolCall _ _ _ => some "call"
  | .media m _ => if tsParity then none else some ("media:" ++ m)
  | .unmodeled l _ => if tsParity then none else some ("unmodeled:" ++ l)

def envBlockTag (tsParity : Bool) : EnvBlock → Option String
  | .toolResult _ content _ =>
      some (String.intercalate ";" (content.filterMap (userBlockTag tsParity)))
  | .unmodeled l _ => if tsParity then none else some ("unmodeled:" ++ l)

/-- One entry, projected positionally: `<index>|<parentIndex or ->|<payload>`.
The role comes from the message constructor (role-content-sum). -/
def entryTag (tsParity : Bool) (i : Nat) (e : Entry) : String :=
  let par := (e.parent.map toString).getD "-"
  let ptag := match e.payload with
    | .userMsg blocks       => "user|" ++ String.intercalate ";" (blocks.filterMap (userBlockTag tsParity))
    | .assistantMsg blocks  => "assistant|" ++ String.intercalate ";" (blocks.filterMap (assistantBlockTag tsParity))
    | .envMsg blocks        => "toolResult|" ++ String.intercalate ";" (blocks.filterMap (envBlockTag tsParity))
    | .otherMsg role blocks => role ++ "|" ++ String.intercalate ";" (blocks.filterMap (userBlockTag tsParity))
    | .compaction summary _ _ => "compaction|" ++ summary
    | .event _ => "event|"
  toString i ++ "|" ++ par ++ "|" ++ ptag

/-- Canonical, deterministic, positional projection, parameterized by the
projection variant (`tsParity`). The header carries no cwd: TS fabricates one
(empty string, or `process.cwd()` for import-only formats — machine-dependent,
unpinnable), Loom honestly emits `none`; that divergence is an adjudicated
leanCore improvement, not a gate. -/
def normalizeWith (tsParity : Bool) (t : Transcript) : String :=
  let n := t.entries.size
  let lines := (List.range n).filterMap (fun i => (t.entries[i]?).map (fun e => entryTag tsParity i e))
  String.intercalate "\n" ("session" :: lines)

/-- The default projection: every block projects (Loom's media/unmodeled
enrichments included). This is what the decide-pins and `capture-parity.ts`
goldens are cut against, so it must stay byte-identical. -/
def normalize (t : Transcript) : String := normalizeWith false t

/-- The TS-parity projection: the SAME structural skeleton as `normalize`, but
Loom's deliberate enrichments (`media`, `unmodeled`) are dropped so the result
is apples-to-apples with what the TS converters emit. A transcript that differs
from TS ONLY by extra media/unmodeled blocks projects identically here — which
is exactly what lets the cutover gate (`loom-diff --ts-parity`) tell a REAL
regression from a Loom-is-richer difference. -/
def normalizeTsParity (t : Transcript) : String := normalizeWith true t

/-- Normalize whatever a given importer produces from raw source text. -/
def normalizeVia (imp : String → Except String Transcript) (text : String) : String :=
  match imp text with
  | .ok t => normalize t
  | .error e => "ERR:" ++ e

def normalizeOf (text : String) : String := normalizeVia importPi text

/-- Self-parity: import → export → import is stable under `normalize`. -/
def roundTripStable (text : String) : Bool :=
  match importPi text with
  | .error _ => false
  | .ok t => normalize t == normalizeOf (exportPi t)

/-- Cross-parity case: a Lean importer's normalized output must equal the
pinned TS golden for the same input. -/
structure CrossParityCase where
  name     : String
  input    : String
  tsGolden : String

/-- Generalized cross-parity check: parameterized by the importer under test,
so each format pins with its own importer (`crossParityOkWith importClaude …`). -/
def crossParityOkWith (imp : String → Except String Transcript) (c : CrossParityCase) : Bool :=
  normalizeVia imp c.input == c.tsGolden

def crossParityOk (c : CrossParityCase) : Bool := crossParityOkWith importPi c

/-! ## Pinned fixtures (synthesized — structure only, no real content) -/

def fix1 : String := String.intercalate "\n" [
  "{\"type\":\"session\",\"version\":3,\"id\":\"s1\",\"timestamp\":\"2024-01-01T00:00:00.000Z\",\"cwd\":\"/tmp/x\"}",
  "{\"type\":\"message\",\"id\":\"a1\",\"parentId\":null,\"timestamp\":\"2024-01-01T00:00:00.000Z\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"hi\"}],\"timestamp\":1704067200000}}",
  "{\"type\":\"message\",\"id\":\"a2\",\"parentId\":\"a1\",\"timestamp\":\"2024-01-01T00:00:00.001Z\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"hmm\",\"thinkingSignature\":\"SIG\"},{\"type\":\"text\",\"text\":\"yo\"},{\"type\":\"toolCall\",\"id\":\"tc1\",\"name\":\"Bash\",\"arguments\":{}}],\"api\":\"anthropic-messages\",\"provider\":\"anthropic\",\"model\":\"fixture-model\",\"usage\":{\"input\":0,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0,\"totalTokens\":0,\"cost\":{\"input\":0,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0,\"total\":0}},\"stopReason\":\"toolUse\",\"timestamp\":1704067200001}}"
]

/-- THE DECIDE-PIN (self-parity): round-trip stability folded into `lake build`. -/
example : roundTripStable fix1 = true := by native_decide

/-- Cross-parity golden, captured from the TS toolchain (`parseSession`) via
`parity/capture-parity.ts`, positional projection. -/
def case1 : CrossParityCase := {
  name := "pi",
  input := fix1,
  tsGolden := "session\n0|-|user|text:hi\n1|0|assistant|think:hmm;text:yo;call"
}

/-- THE DECIDE-PIN (cross-parity, RC1): the Lean pi importer agrees with the TS
reference oracle. If leanCore drifts from tsBaseline, this stops compiling. -/
example : crossParityOk case1 = true := by native_decide

/-! ## TS-parity demonstration

A user turn whose content is a text block PLUS a Loom-richer `media` block (an
image TS's importer would discard). The default `normalize` keeps `media:…`;
`normalizeTsParity` drops it, so the ts-parity skeleton matches what TS emits. -/

def fixMedia : String := String.intercalate "\n" [
  "{\"type\":\"session\",\"version\":3,\"id\":\"s1\",\"timestamp\":\"2024-01-01T00:00:00.000Z\",\"cwd\":\"/tmp/x\"}",
  "{\"type\":\"message\",\"id\":\"a1\",\"parentId\":null,\"timestamp\":\"2024-01-01T00:00:00.000Z\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"hi\"},{\"type\":\"image\",\"mimeType\":\"image/png\",\"data\":\"L\"}],\"timestamp\":1704067200000}}"
]

-- Executable check: the two projections differ ONLY by the media block, and the
-- ts-parity skeleton is exactly the media-free one.
example : (match importPi fixMedia with
  | .ok t => normalize t != normalizeTsParity t
             && normalizeTsParity t == "session\n0|-|user|text:hi"
             && normalize t == "session\n0|-|user|text:hi;media:image/png"
  | .error _ => false) = true := by native_decide

end LoomConvert
