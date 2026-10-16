# Changelog

User-visible changes are recorded here. Add entries under `Unreleased` as work
lands; move them into a dated version section when publishing a release.

## [Unreleased]

- Keep foreign reasoning readable in Claude without presenting foreign
  ciphertext as a Claude thinking signature. Preserve exact opaque reasoning
  in validated metadata and forward unchanged native Claude signatures only
  when backed by their physical source block (#2).

- Add an opt-in Claude continuation probe that checks the resumed model's
  current request and last tool outcome, with temporary sessions and retained
  hash-bound receipts; document the per-version release gate (#28).

### Fixed

- Refuse OpenCode export when a failed tool result contains images or files,
  with the exact entry/block location. The native error state cannot carry
  attachments; successful results retain their media and text-only failures
  remain supported (#7).

- Preserve OpenCode message and part order beyond entry 9 with fixed-width
  sequence IDs. Keep compaction requests before their summaries and imported
  history before newly appended native turns (#6).

- Give foreign OpenCode exports stable source-specific session IDs and scope
  all message, part, metadata, and attachment IDs to the selected target session.
  Refuse invalid explicit session IDs instead of using a shared fallback (#5).

- Add a CI corpus gate for compacted Codex 0.144.1, 0.153.0, and 0.162.1
  rollouts. Check active-window size, retained dialogue, native tool history,
  status, both subagent policies, and mutations of the reported regressions
  ([#27](https://github.com/theoriclabs/agent-convert-lean/issues/27)).
- Warn when a recorded source version exceeds its reviewed fixture baseline,
  with a typed import note and `sourceVersionBeyondReviewed` JSON evidence.
  Compare semantic versions and check fixture directories against the single
  baseline table during verification
  ([#26](https://github.com/theoriclabs/agent-convert-lean/issues/26)).
- Batch Claude event and archive provenance into one header, retaining event
  positions, exact Codex completion records, and original graph links for
  re-import. Keep events out of the physical conversation chain. Report
  `inertByteShare` in JSON and warn when provenance exceeds 10% of the file
  ([#25](https://github.com/theoriclabs/agent-convert-lean/issues/25)).
- Consume Codex `item_completed` mirrors and command completions without extra
  conversation entries. Keep exact events and source positions on typed entries,
  attach other reviewed item kinds to nearby entries, and retain unmatched or
  future conversation events explicitly
  ([#24](https://github.com/theoriclabs/agent-convert-lean/issues/24)).
- Block avoidable tool-history prose before continuation publication. Independent
  native-shape checks cover Claude and sidecars; serialized-output checks cover
  continuation targets while preserving literal source quotes, duplicate-id
  exceptions, and explicitly inert history
  ([#18](https://github.com/theoriclabs/agent-convert-lean/issues/18)).
- Preserve native Claude call/result history for encrypted and unsupported
  result content. Emit a labeled unavailable-output block, retain the complete
  original content in validated metadata, and restore it on re-import
  ([#17](https://github.com/theoriclabs/agent-convert-lean/issues/17)).
- Keep valid completed source tools as raw-name native Claude history when no
  semantic translation exists. Preserve Codex notes/history tool namespaces and
  exact source arguments in reversible metadata
  ([#16](https://github.com/theoriclabs/agent-convert-lean/issues/16)).
- Refuse contradictory continuation error flags before publication, naming the
  source entry, call id, and successful status evidence. Inner command failures
  remain valid under an outer successful runner. Pi and OpenCode now preserve
  heuristic errors as metadata without asserting native failure
  ([#15](https://github.com/theoriclabs/agent-convert-lean/issues/15)).
- Keep heuristic tool-error guesses out of Claude’s native `is_error` flag.
  Preserve structured, heuristic, and unknown signals in validated record metadata
  so native history retains exact error provenance across repeated conversions
  ([#14](https://github.com/theoriclabs/agent-convert-lean/issues/14)).
- Read Codex runner status, whole-chunk exit codes, and unambiguously associated
  command-completion events as structured error evidence. Preserve the deciding
  source and raw command events; inner failures override outer-runner success
  ([#12](https://github.com/theoriclabs/agent-convert-lean/issues/12)).
- Split derived tool errors into `structured` source evidence and `heuristic`
  guesses. Preserve both through wire and historical-carrier codecs, and decode
  legacy `inferred` records as heuristic evidence
  ([#13](https://github.com/theoriclabs/agent-convert-lean/issues/13)).
- Restrict Codex error inference to runner headers. Successful output that prints
  timeout limits, quoted failures, or exit-status text stays successful
  ([#11](https://github.com/theoriclabs/agent-convert-lean/issues/11)).
- Warn when unknown Codex checkpoint fields contain unconsumed message-shaped
  content. Include field names, counts, source locations, and samples in JSON
  diagnostics, and name the fields in no-dialogue export refusals
  ([#23](https://github.com/theoriclabs/agent-convert-lean/issues/23)).
- Refuse continuation exports whose active window has no native user text turn.
  Report source/checkpoint context and support an explicit, JSON-reported
  `--allow-empty-dialogue` override for deliberate tool-only archives
  ([#20](https://github.com/theoriclabs/agent-convert-lean/issues/20)).
- Restore Codex checkpoint `retained_context` dialogue in source order, with exact
  message identities and metadata. Preserve retention flags and verified answers
  in archive provenance and JSON reports; refuse ambiguous retained message data
  ([#19](https://github.com/theoriclabs/agent-convert-lean/issues/19)).
- Repair all three failing requirements proofs: align the Claude validation
  version, follow it in refusal checks, and verify native tool translation with
  exact source-call provenance. Include `LoomRequirements` in local verification.
- Repair lifecycle-audit identity validation for compiler/capability metadata
  and update its Claude target version. All 40 conversion cells now pass;
  local verification runs the full matrix, including its mutation self-tests.
- Accept Codex checkpoints whose replacement history omits the optional trailing
  compaction signature, retaining the complete checkpoint as provenance while
  continuing to reject malformed histories ([#21](https://github.com/theoriclabs/agent-convert-lean/issues/21)).
- Share checkpoint validation between Codex archive and active-context imports,
  including retained native tool activity and optional window metadata. Both
  modes report the same selected boundaries; three versioned fixtures pin their
  agreement ([#22](https://github.com/theoriclabs/agent-convert-lean/issues/22)).

## [0.2.0-preview.4] - 2026-10-15

### Added

- Add the separate Loom viewer for browsing local agent sessions as chat threads.

- Add `scripts/verify-local.sh` for the product build, smoke checks, filesystem
  publication, wire contracts, native history, and audit self-tests without a
  separate TypeScript host checkout. Document the module boundaries and isolate
  CLI format dispatch and output publication in `LoomConvert/Cli/`.

- Add a repository `SKILL.md` for session conversion and handoff, simplify the
  README quick start, and point the existing agent runbook to the skill.

### Fixed

- Recover tool results omitted by Cursor IDE's native JSONL transcript exports
  from the same saved composer. Check session identity, visible messages, tool
  order, and arguments before restoring recorded results and missing call IDs.
  Preserve the exported dialogue and arguments, refuse stale/mismatched sources,
  and warn when no matching store is available. Target defaults and Claude
  installation now use the same path-aware acquisition as conversion. Keep
  `turn_ended` bookkeeping in exact control metadata rather than dialogue.
- Replace the removed `String.trim` call in the CLI with `trimAscii.toString`
  so the product builds with the locally selected Lean toolchain.

- Import Claude Code peer lines (a subagent's hand-back or a teammate's message,
  relayed by the harness as a `user` row with `turnOrigin: "peer"`) as `peer`
  messages carrying the body from the record's `origin`, with a role-coercion
  note, instead of showing another agent's report as the person's words.

- Archive Claude background-task notifications with system-origin metadata
  even when recent Claude versions omit `isMeta`. Their completion details stay
  in provenance instead of appearing as user prompts in a converted session;
  literal user examples of the same XML remain ordinary conversation.

- Accept Claude Code 2.1.274's decoupled compaction shape: `isCompactSummary`'s
  `parentUuid` now names the ordinary record that preceded it in real time,
  not the `compact_boundary` itself, and a session's sole boundary can sit off
  the summary's selected path entirely. The importer previously refused such
  transcripts outright ("compact_boundary must have exactly one
  isCompactSummary child, found 0"), discarding an intact multi-megabyte
  session over a bookkeeping assumption two Claude Code versions had already
  moved past. The compaction summary text still becomes the resumable entry;
  when the boundary is off the selected path its own `compactMetadata` is
  preserved as an archived raw record rather than cross-linked, which is an
  honest degradation, not silent loss.

### Validation and limits

- Experimental prerelease. The macOS ARM64 release binary is built from the
  tagged commit with the pinned Lean 4.33.0 toolchain. Native-history, Cursor
  recovery, wire-contract, and filesystem-publication artifact checks pass.
- Cursor recovery requires the matching saved IDE conversation. Results absent
  from both the transcript and the database cannot be reconstructed. Recorded
  calls are never rerun during import.
- Live model continuation and the separate viewer build were not tested for
  this release. The three pre-existing requirements failures in `CLAUDE.md`
  remain; the full external integration gate was not run.
- Binary downloads are macOS ARM64 only and are not notarized. This is not an
  npm release or completion of the historical qualification process.

## [0.2.0-preview.3] - 2026-09-08

### Fixed

- Map overlong imported Codex tool-call IDs to unique API-compatible IDs of
  at most 64 characters. Preserve original IDs in metadata and remap matching
  results together, including when repairing an already-converted rollout.
- Exercise long source IDs in the live Codex continuation regression; a local
  rollout-reader check alone did not catch the API and remote-compaction limit.
- Allow release upgrades to retain and verify an older installed binary for
  rollback, while still requiring the candidate to match the new version.

### Validation and limits

- Boundary-length, collision, metadata-restoration, and old-rollout repair
  regressions cover the fix. Synthetic Codex CLI 0.153.4 continuation and remote
  compaction preserve prior-result recall with zero new tool calls.
- Includes the native Claude `exec` history fix from `0.2.0-preview.2`.
- The three pre-existing requirements failures documented in `CLAUDE.md`
  remain. Binary downloads are macOS ARM64 only and are not notarized.

## [0.2.0-preview.2] - 2026-09-08

### Fixed

- Preserve completed Codex JavaScript `exec` calls as native Claude tool
  history when the wrapper cannot be translated to a single Bash operation.
  Keep original inputs and recorded results without rerunning tools or adding
  historical-tool disclaimers.

### Added

- Regression coverage for composite, dynamic, and privileged Codex wrappers,
  exact outputs, failure status, compaction selection, and stable re-export.
- An opt-in Claude continuation test that checks prior-result recall with
  tools disabled and session persistence off; documented in the conversion matrix.

### Known limitations

- The three pre-existing requirements failures documented in `CLAUDE.md`
  remain. This fix does not extend support to every tool schema or unresolved
  lifecycle.

## [0.2.0-preview.1] - 2026-09-07

First public prerelease of the Lean session converter.

### Added

- Conversion routes for nine source formats and six targets, including OpenCode
  import/export documents and rich Cursor IDE store extraction.
- Cross-store `loom search`, JSON search rows through `loom text`, and a
  zero-dependency Node MCP server.
- A [conversion matrix](https://github.com/theoriclabs/agent-convert-lean/blob/v0.2.0-preview.1/docs/conversion-matrix.md)
  covering input formats, native tool-history support, output workflows, and
  known limits. An inventory check detects drift from the CLI routes.
- Synthetic Cursor result-recovery tests and an opt-in live Codex continuation
  probe that checks prior-result recall without rerunning tools.

### Fixed

- Recover Cursor results retained in `toolFormerData.toolCallBinary` when the
  inline result is absent. Supported binary schemas cover grep, edit, and
  conversation search. ([#9](https://github.com/theoriclabs/agent-convert-lean/issues/9))
- Keep recovered Cursor calls and results in native Codex history. Preserve
  recorded error provenance in metadata even when the output disagrees with
  Codex's error-text heuristic. ([#8](https://github.com/theoriclabs/agent-convert-lean/issues/8))
- Preserve empty-message positions without adding converter-authored dialogue.
- Use Codex's active compaction context for every continuation target, including
  when subagent discovery is enabled. Keep full history for Loom archives.
- Align release-builder identity checks with the current `0.2.0-preview.1` CLI.
- Fix release builds from the flattened repository root, where Git rejects an
  empty pathspec during the clean-worktree check.

### Known limitations

- This is an experimental prerelease. The full requirements build has three
  pre-existing failing assertions: `environmentLossPolicyPinned`,
  `previewRequiredSuccessesPass`, and `previewRequiredRefusalsPass`.
- A supported route does not guarantee complete fidelity for every transcript.
  Unsupported content and unresolved tool lifecycles can still produce legacy
  carriers or refusals. Cursor Agent has no native tool-result channel in the
  supported transcript schema; some other targets lose error provenance or
  result-block boundaries. See the conversion matrix for details.
- The binary download is macOS ARM64 only and is not notarized. Other platforms
  must build from source with the pinned Lean toolchain. Cursor IDE extraction
  requires `sqlite3`; the optional MCP server requires Node.js.

[Unreleased]: https://github.com/theoriclabs/agent-convert-lean/compare/v0.2.0-preview.4...HEAD
[0.2.0-preview.4]: https://github.com/theoriclabs/agent-convert-lean/releases/tag/v0.2.0-preview.4
[0.2.0-preview.3]: https://github.com/theoriclabs/agent-convert-lean/releases/tag/v0.2.0-preview.3
[0.2.0-preview.2]: https://github.com/theoriclabs/agent-convert-lean/compare/v0.2.0-preview.1...v0.2.0-preview.2
[0.2.0-preview.1]: https://github.com/theoriclabs/agent-convert-lean/releases/tag/v0.2.0-preview.1
