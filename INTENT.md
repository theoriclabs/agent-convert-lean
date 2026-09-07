# Conversation continuity across harnesses

Convert a session so the destination continues the same conversation, with the
same prior actions and knowledge. A tool call performed in Cursor should reach
Codex as a past assistant tool call, with its recorded result and execution
state. The resumed model should reason from it as part of its own conversation
history. Changing harnesses does not make an action hypothetical or unverified.

This is the product intent, clarified on 2026-09-07. It agrees with P1 and P2 in
`LoomOps/Interop.lean` and takes precedence over older requirements or validation
expectations that treat readable tool-carrier prose as equivalent fidelity.
Existing evidence records describe what was tested, not what the product should
settle for. This document does not claim the implementation already complies.

## What fidelity means

- Emit the destination's native conversation and tool-history structures
  whenever it can express the source fact. Preserve order, arguments, results,
  call/result links, execution state, and the active continuation context.
- Preserve recorded execution as execution. Importing history must not rerun
  tools. Native history records and new tool execution are different operations.
- Distinguish execution state from output availability. A completed call with a
  pruned result is still completed. An interrupted or unknown call must retain
  that state; absence of a result alone does not decide whether a call ran.
- Recover recorded outputs from the available source data before treating them
  as unavailable. Absence from one field or from Loom's current extraction is
  an unresolved acquisition gap, not proof of absence from the source history.
  Investigate source retrieval paths and state the scope of any established
  limitation. Never reconstruct old outputs by running tools against today's
  environment or invent a successful result.
- If the target requires an output record when the source retained none, use a
  minimal, accurately labeled unavailable-output representation in the native
  tool-result channel. Keep the recorded completion/error state and mark any
  target-required placeholder out of band. This is a compatibility adaptation,
  not a recovered source result.
- Put source identities, ID mappings, raw provenance, and conversion diagnostics
  in metadata or a sidecar. Do not add assistant messages such as
  `[Historical tool call ...; not executed by Codex]` or carrier JSON. Removing
  the heading alone is not a fix: the tool must remain a tool in target context.
- Use a compatible native history representation without assuming the source
  tool must exist in the destination's current callable registry. Validate the
  destination's actual history constraints. Where translation of names,
  arguments, or IDs is required, preserve semantics and reversible mappings.
- When a target truly cannot represent a fact, keep as much as possible in
  metadata and report the limitation. Do not describe an archive or a prose
  approximation as a fully faithful continuation.

## How to judge success

Check what the destination shows and what its resumed model receives, as well
as what Loom can re-import. A reversible prose carrier may pass a round-trip
test while failing conversation continuity. The tests must catch that failure.

Use native tool records in representable cases, verify completion and missing
output separately, and verify that loading/resuming history performs no old
actions. A target-parser read proves readability; a continuation probe must
also show that the model understands the seeded prior tool activity without
needing a converter explanation. Each additional conversion should preserve
this meaning rather than progressively turn history into prose.

Implementation status and remaining limits: `docs/cursor-tool-binary.md`.
Original defect and broader plan: `docs/bugs/native-tool-history.md` and
`docs/plans/native-tool-history.md`.
