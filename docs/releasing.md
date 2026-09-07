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
   check, and relevant builds and regressions. Record known failures rather
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
