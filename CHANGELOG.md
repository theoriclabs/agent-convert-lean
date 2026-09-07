# Changelog

User-visible changes are recorded here. Add entries under `Unreleased` as work
lands; move them into a dated version section when publishing a release.

## [Unreleased]

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

[Unreleased]: https://github.com/theoriclabs/agent-convert-lean/compare/v0.2.0-preview.1...HEAD
[0.2.0-preview.1]: https://github.com/theoriclabs/agent-convert-lean/releases/tag/v0.2.0-preview.1
