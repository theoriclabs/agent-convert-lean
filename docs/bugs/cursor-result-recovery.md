# [P1] Cursor result extraction stops at toolFormerData.result and can omit retained tool output

Status: reported acquisition defect fixed; supported schemas and limits documented below.

## Resolution

The missing lookup was `toolFormerData.toolCallBinary`, a base64
`agent.v1.ToolCall` protobuf that can retain output omitted from the inline
field. The importer now recovers supported grep, edit, and conversation-search
results from that binary, checking ownership and preserving recorded content
and error state. Unsupported or contradictory evidence is reported as
unresolved, not as a missing source result.

Schema details, independent Cursor-decoder validation, synthetic regression
coverage, and remaining limits: [implementation notes](../cursor-tool-binary.md).
The sections below retain the original report and investigation checklist.

Filed as [GitHub issue #9](https://github.com/theoriclabs/agent-convert-lean/issues/9).

## Problem

The Cursor IDE importer reads a tool's result from `toolFormerData.result`.
If that field is absent on a completed call, it reports that the tool has
"no recorded result" and emits only a call. That conclusion exceeds the
evidence: absence from this field does not establish absence from Cursor's
conversation history or storage.

The store reader in `LoomConvert/CursorIdeActuator.lean` fetches the composer
and the bubbles referenced by `fullConversationHeadersOnly`. It does not
resolve a complete result history across alternate representations or linked
records. Preserving those extracted bubbles in a Loom archive does not prove
that acquisition captured every source result.

This is a source acquisition/import bug, separate from issue #8's export of
tool calls as assistant carrier prose. Fixing native emission or supplying an
unavailable-output placeholder does not resolve incomplete extraction.

## Reproduction and evidence boundary

A synthetic completed tool bubble can omit `toolFormerData.result` and carry
`additionalData.isPruned = true`. The importer immediately takes the
`cursorIdeTerminalWithoutResult` path. It does not first establish whether
Cursor retains that call's output elsewhere.

The established code limitation is the narrow lookup and the overconfident
diagnostic. The actual alternate result location and its schema still need
investigation. `isPruned` is not proof that the underlying result is gone.
No private transcript, identifiers, filesystem paths, or session statistics
are included in this report.

## Investigation

1. Trace Cursor's own transcript/export and conversation-reader paths for
   retrieving results, using a read-only snapshot of a selected conversation.
2. Follow composer, bubble, call, request/model-call, and branch relationships.
   Inspect separate result records, alternate bubble fields, serialized/binary
   payloads, agent transcript exports, and referenced retained data as candidate
   locations. These are hypotheses to check, not asserted recovery sources.
3. Establish how a pruned display record relates to the original output. Compare
   the recovered result with Cursor's own history representation where available.
4. Keep exact output distinct from summaries, snippets, counts, and today's
   filesystem contents. Do not rerun a tool to recreate historical output.

## Acceptance criteria

- Recover the complete recorded output from supported Cursor storage locations
  and link it to the correct call occurrence and branch, preserving order,
  content blocks, and recorded error/execution state.
- Add a sanitized regression fixture with the result genuinely stored outside
  `toolFormerData.result`, based on the discovered schema. Test repeated IDs,
  multiple candidate records, pruned display data, and partial result chunks.
- Reconcile extracted results against an independent Cursor history/export
  view; exporter/importer agreement alone cannot detect omitted source data.
- Use "result not yet located/extracted" while recovery is unresolved. Claim
  "unavailable in the inspected source" only after enumerating the checked
  stores, references, and supported retrieval paths. Do not make an unqualified
  claim that Cursor has lost the result.
- Resolve this acquisition defect before treating a placeholder-based version
  of an affected conversion as complete. Preserve the original store throughout.

Related: #8 handles the downstream native-history representation. Both defects
must be addressed for a faithful conversion.
