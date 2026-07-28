import Loom.Concepts

/-!
# Format — Google AI Studio

A one-shot **export blob**, not a live session store: the user downloads a
JSON file. Top-level keys `runSettings, systemInstruction, chunkedPrompt`;
the conversation is `chunkedPrompt.chunks[]` with roles user / model.

The census (4 real export blobs) showed the format is **substantially
richer than the original TS importer reads** — it carries function-call
capability flags, per-chunk error messages, best-of-N branch pointers,
thought signatures, finish reasons, multimodal attachment refs, and occasional
timestamps. Loom's importer now recovers the high-value non-branch payloads
(error events, signatures, and media refs), and the TS importer preserves
errorMessage chunks as pi event entries; branchParent/branchChildren remain
linearized until GAIS branching is modeled first-class.

Evidence base: `utils/src/pi/googleAiStudio.ts` + 4 real export blobs in
`~/Downloads`, censused 2026-07-06.
-/

namespace Loom.Formats.GoogleAiStudio

def storage : String := "(user-downloaded export JSON; no canonical path, no live store)"

def fileShape : FileShape := .exportBlob

/-- Native chunk kinds and the part shapes within them. Census part-shapes:
`[text]`, `[text,thought]` (reasoning), `[text,thoughtSignature]` (signed). -/
inductive ChunkKind where
  | userChunk        -- role user
  | modelChunk       -- role model (answer); may carry finishReason, tokenCount
  | thoughtPart      -- thought:true parts inside model chunks
  | signedPart       -- text+thoughtSignature parts (90–127 per file)
  | errorChunk       -- carries errorMessage (7 across 4 files)
  | attachmentChunk  -- driveDocument/driveImage/driveAudio/inlineFile (~120/file)
  | unrecognized (label : String)
  deriving Repr, DecidableEq

def disposition : ChunkKind → Disposition
  | .userChunk  => .mapped "Payload.message role user; Time.sequenced"
  | .modelChunk => .mapped "Payload.message role assistant; usage=makePiUsage(tokenCount); finishReason dropped"
  | .thoughtPart =>
      .mapped "Block.thinking, split from visible text (leak fixed v2.27; --no-thoughts drops)"
  | .signedPart =>
      .mapped "Loom preserves thoughtSignature on thinking blocks; the TS adapter still drops signatures"
  | .errorChunk =>
      .mapped "Loom maps errorMessage to MetaEvent.custom; the TS adapter emits a google-ai-studio:error pi event"
  | .attachmentChunk =>
      .mapped "Loom preserves drive*/inlineFile refs as media blocks; the TS adapter still drops them"
  | .unrecognized _ => .unverified

/-- Expressiveness row. Cells reflect the SOURCE format's capability;
`approximate` marks where the importer degrades or drops it. -/
def supports : Concept → Support
  | .identity        => .absent
  | .threading       => .approximate "chunk order; native branchParent/branchChildren dropped (see branching)"
  | .time            => .approximate
      "mostly absent → synthesized monotonic sequence (googleAiStudio.ts:92-94); a few chunks carry createTime, ignored (refines L6)"
  | .roles           => .native  -- user / model
  | .textContent     => .native
  | .thinkingContent => .native  -- thought:true parts (but thoughtSignature dropped)
  | .toolLifecycle   => .approximate
      "runSettings enableAutoFunctionResponse/enableCodeExecution show function capability; no functionCall parts in the 4 sampled blobs; adapter has ZERO tool handling either way (was `unverified`)"
  | .errorSignaling  => .approximate
      "per-chunk errorMessage EXISTS in source (7 across 4 files); Loom maps it to an event and the TS adapter emits a pi event"
  | .compaction      => .absent
  | .branching       => .approximate
      "native branchParent/branchChildren on chunks (2 of 4 files); adapter linearizes by array order and drops them (was `absent`)"
  | .sidechains      => .absent
  | .usage           => .approximate "tokenCount on model chunks only"
  | .environment     => .approximate "model + thinkingLevel read; ~11 other runSettings + systemInstruction dropped"
  | .metaEvents      => .approximate "model_change/thinking_level_change synthesized on import"
  | .media           => .approximate
      "driveDocument/driveImage/driveAudio/inlineFile chunks present (~120/file); Loom preserves refs, while the TS adapter drops them"

def claims : List Claim := [
  { id := "L6-gais-time-synthetic"
    statement :=
      "Google AI Studio time is fabricated: the importer synthesizes a \
       monotonic sequence. (Refined: a few chunks DO carry createTime, so \
       'no timestamps anywhere' was slightly overstated — but the importer \
       ignores them regardless.)"
    status := .confirmed
      ("googleAiStudio.ts:92-94 synthesizes ms sequence; census found \
        createTime on 4 chunks in one of 4 files, unread. Loom types \
        imported time as Time.sequenced so --since can refuse.") },
  { id := "L19-gais-source-richer-than-import"
    statement :=
      "The GAIS export carries error signaling (errorMessage), branching \
       (branchParent/branchChildren), reasoning signatures (thoughtSignature), \
       finishReason, and multimodal attachments — all present in real blobs. \
       Loom now preserves error events, signatures, and media refs; the TS \
       importer preserves error events; branch pointers and finishReason \
       remain dropped/linearized."
    status := .confirmed
      ("2026-07-06 census over 4 real exports: errorMessage (7 chunks), \
        branch pointers (2 files), thoughtSignature (90–127/file), \
        finishReason (100–300/file), drive*/inlineFile (~120/file). \
        Corrects the errorSignaling and branching cells from absent/unverified \
        to source-present; 2026-07-08 Loom importer recovers errors/signatures/media \
        and the TS importer recovers error events, but neither claims GAIS \
        branch topology or finishReason fidelity.") }
]

end Loom.Formats.GoogleAiStudio
