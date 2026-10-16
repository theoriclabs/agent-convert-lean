# Publishing a prerelease

`CHANGELOG.md` is the source for GitHub release notes. Add user-visible fixes
and limitations under `Unreleased` in the same change that introduces them.
Keep entries brief and link issues when useful. Do not include private sessions.

Before publishing:

1. Choose a new tag matching `coreVersion` in `LoomConvert/Main.lean`. Update the
   version checks and synthetic identities in `scripts/build-release.sh` and
   `scripts/verify.sh` when the version changes. Never move an existing tag.
2. Move the relevant `Unreleased` entries into a dated version section; keep
   `Unreleased` for subsequent work. Update the changelog's release/compare links.
3. Run `node scripts/release-notes.mjs --check`, the conversion-matrix inventory
   check, `node scripts/check-reviewed-versions.mjs`, and relevant builds and
   regressions. Record known failures rather
   than presenting a prerelease as fully validated.
4. Commit the release metadata. Run `bash scripts/build-release.sh` from that
   clean tracked revision. It builds an archive of committed source and stamps
   the revision into `.lake/release/loom`; untracked private artifacts are excluded.
5. Test that exact binary, including `version --json` and relevant conversions.
   Check that `coreRevision` equals the release commit. Package it with the MIT
   license and the pinned Lean toolchain's `LICENSE` and `LICENSES` notices.
   Include SHA-256 checksums and record the platform and test results.
6. Push the commit and an annotated version tag. Create a draft GitHub prerelease
   with notes from `node scripts/release-notes.mjs <tag>`, attach the verified
   assets, check the draft, and publish it with the prerelease flag.

Publish only the platforms actually built and tested. A local macOS build does
not establish Linux support or notarization. A GitHub prerelease does not imply
an npm release or completion of the historical qualification process in
`RELEASE_CHECKLIST.md`.

The first release is `v0.2.0-preview.1`. Later work starts in `Unreleased` and
uses a new version; published notes and assets should not be silently replaced.

Source-version review is separate from target-harness qualification.
`LoomConvert/SourceVersion.lean` records the newest reviewed fixture version for
Codex, Claude, OpenCode, and Pi's numeric file schema. A newer source produces a
warning and `sourceVersionBeyondReviewed` evidence; it remains importable when
its semantic shape is valid. Add a synthetic version directory and review its
shape before advancing a baseline. The fixture check refuses both unacknowledged
new directories and baseline bumps without fixtures. Cursor Agent has no release
version in the reviewed native corpus, so its shared hook has no baseline yet.

`node scripts/check-codex-corpus.mjs` checks the synthetic 0.144.1, 0.153.0,
and 0.162.1 compacted rollouts. It verifies full archival checkpoints, active
window bounds, retained user dialogue, native tool history, successful exec
status, and the same behavior with default and disabled subagent stitching.
The 0.162 fixture includes unsigned replacement history, retained context,
notes tools with opaque output, and structured completion events. The checker
also rejects mutations reproducing the reported failures. `recordIndex` is the
zero-based index after the session header; the recorded source `ordinal` is
checked separately in exact boundary provenance. Use `--report <path>` to keep
the fixture hashes and results. The repository CI workflow runs this checker in
`scripts/verify-local.sh` alongside the route and lifecycle checks. These are
artifact checks; signed-in harness continuation is a separate release gate.

Before a release, run the opt-in continuation gate with the exact release
binary and a signed-in Claude Code installation:

```sh
LOOM_BIN=/path/to/release/loom node scripts/continuation-probe.mjs testdata/codex/0.144.1/compacted-rollout.jsonl claude --expect viewer --expect-outcome README.md --report /tmp/probe-0.144.json
LOOM_BIN=/path/to/release/loom node scripts/continuation-probe.mjs testdata/codex/0.153.0/compacted-rollout.jsonl claude --expect viewer --expect-outcome README.md --report /tmp/probe-0.153.json
LOOM_BIN=/path/to/release/loom node scripts/continuation-probe.mjs testdata/codex/0.162.1/compacted-rollout.jsonl claude --expect preview --expect-outcome README.md --report /tmp/probe-0.162.json
```

The script installs a fresh UUID under a temporary project's Claude store,
resumes a nonpersistent fork with tools, MCP, and customizations disabled, and
asks for the current user request and last tool outcome. It rejects missing
context, missing expected words, and error claims when the source's last
selected tool result has authoritative success status. Pick `--expect` from
the current source dialogue; repeat it for multiple required words. Add
`--expect-outcome` to check result content. Heuristic or absent status does not
establish success. This is a keyword continuity check, not a general semantic
judge or proof of non-execution across all harness modes.

The receipt includes the exact prompt and reply, harness version, source and
binary hashes, conversion diagnostics, and pass/fail result. The installed
session is deleted even on failure unless `--keep` is explicit; private
diagnostics remain in a temporary directory. Only Claude is implemented;
other target names fail before installation. The gate incurs a model request
and requires existing authentication, so ordinary CI runs only its offline
negative checks. Retain synthetic receipts and record observed transcripts in
`REQUIREMENTS_EVIDENCE.md`; do not commit private session contents. Each
release needs its own candidate-bound receipts.

Check a fact present only in a compaction summary as well:

```sh
LOOM_BIN=/path/to/release/loom node scripts/continuation-probe.mjs testdata/claude/2.1.274/compaction-summary.jsonl claude --expect PostgreSQL --expect violet-river --prompt 'Which database and migration codename did we choose? Reply in one sentence from the existing conversation.' --report /tmp/probe-claude-summary.json
LOOM_BIN=/path/to/release/loom node scripts/compaction-continuation-probe.mjs /tmp/probe-pi-summary.json
```

The Pi probe uses the configured provider/model, disables tools and project
customizations, and resumes a converted synthetic fixture in a temporary
directory. It never installs or overwrites an existing conversation. Optional
`PI_PROBE_PROVIDER` and `PI_PROBE_MODEL` variables select a model for this test
only. Authentication errors fail the check. To inspect Pi's actual model input
without a model request, set `PI_PACKAGE_ROOT` to the installed Pi package root
and run `node scripts/test-compaction-context.mjs`; it calls the installed
`buildSessionContext` and `convertToLlm` implementations on both native and
projected summaries. The ordinary CI test covers artifact shape, repeated
conversion, typed coverage, and malformed metadata without that dependency.
