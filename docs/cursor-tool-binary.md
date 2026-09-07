# Cursor result recovery and native Codex history

Fixes for #8 and #9 are included in the source checkout. This is not a claim
that a packaged release or every source/target route has been validated.

Cursor can remove `toolFormerData.result` while retaining the recorded result
in the same bubble's base64 `toolCallBinary`. That binary is an
`agent.v1.ToolCall` protobuf, not a display summary. The importer now tries it
when the inline result is absent or null. An existing inline result, including
an empty string, remains authoritative.

`LoomConvert/CursorToolBinary.lean` decodes these observed schemas without a
Cursor or JavaScript runtime dependency:

| Cursor tool | ToolCall field | Nested result |
| --- | --- | --- |
| 41, grep | 5 | field 2, GrepResult |
| 38, edit | 12 | field 2, EditResult |
| 0, search_conversations | 69 | field 2, ConversationSearchResult |

Field numbers and protobuf-JSON behavior were checked against the installed
Cursor descriptors on 2026-09-07. An independent check used Cursor's own
`@bufbuild/protobuf` types and `fromBinary(...).toJson()`, not Loom's decoder.
Recovered values matched those decoded results, including full search lines.
No private source content is included in the repository fixtures.

The decoder preserves optional zero/empty fields, repeated values, map entries,
error messages, truncation flags, and 64-bit timestamps as JSON strings. It
checks the tool family and the embedded call ID when present. Older binaries
without that optional ID remain owned by their enclosing bubble; there is no
global join on potentially duplicated IDs. Malformed, unsupported, ambiguous,
or status-conflicting payloads retain their raw evidence and report recovery
as unresolved. Limits bound base64 size and nesting.

This does not claim every Cursor tool schema or every historical storage
version is supported. A binary may itself contain truncated output. Its
truncation flags remain facts, not a promise that all original output exists.
Summaries, current filesystem contents, and newly executed tools are never
substituted for a historical result.

## Codex representation

Recovered pairs use native `function_call` / `function_call_output` records.
Foreign tool names and original IDs, including newline-containing IDs, survive.
The exact `ErrorSignal` travels in `_agent_convert` metadata beside the output,
so a text heuristic cannot flip its value or force the pair into assistant
prose. Existing Codex records without this metadata still use the original
heuristic. The legacy unrecorded-error marker remains readable.

Empty messages retain their position and source role through a metadata-marked
empty message, with no converter-authored dialogue. Legacy visible carriers
remain readable for compatibility; this change does not automatically upgrade
old, incomplete Loom archives. Re-extract the Cursor source before repairing
such a conversion.

## Checks

```sh
lake build loom LoomOps.Interop
node scripts/test-cursor-native-history.mjs
node scripts/audit-codex-claude.self-test.mjs
```

The synthetic regression suite covers full grep output, count/files modes,
truncation, edit success/error, conversation search, optional fields, 64-bit
timestamps, malformed binaries, call ownership, pending/cancelled states,
inline precedence, native records, exact error provenance, and repeated hops.

An opt-in live continuation check installs a new synthetic session and makes
one authenticated model request. It never loads a private conversation:

```sh
node scripts/probe-codex-native-history.mjs --run
```

The live check passed with the installed Codex: exact prior-result recall,
correct interpretation of a failed edit, and zero new tool calls. It also
checked that resume appended to, rather than rewrote, existing history.

The full `lake build LoomRequirements` retains three pre-existing failing
assertions: `environmentLossPolicyPinned`, `previewRequiredSuccessesPass`, and
`previewRequiredRefusalsPass`. Relevant new and updated checks pass; this is
not a claim that the entire requirements suite or every harness route passes.
