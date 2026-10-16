#!/usr/bin/env bash
# Repository-local checks; no TypeScript host, harness login, or private sessions.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

for tool in lake node python3 sqlite3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: $tool not found on PATH" >&2
    exit 2
  fi
done

scratch="$(mktemp -d "${TMPDIR:-/tmp}/loom-verify-local.XXXXXX")"
# Preserve failing audit receipts for diagnosis. Successful runs clean up the
# read-only snapshots sealed by the lifecycle audit.
cleanup() {
  local status=$?
  if (( status != 0 )); then
    echo "verification failed; evidence retained in $scratch" >&2
    return
  fi
  chmod -R u+w "$scratch"
  rm -rf "$scratch"
}
trap cleanup EXIT
export LOOM_BIN="$ROOT/.lake/build/bin/loom"

echo "== product build and Lean smoke checks =="
lake build loom LoomOps LoomRequirements
lake env lean smoke.lean
lake env lean convert_smoke.lean
lake env lean testdata/codex/checkpoint-pins.lean
lake env lean testdata/codex/prose-guard-pins.lean

echo "== filesystem publication and wire contracts =="
"$LOOM_BIN" self-test-sidecar-publication
node scripts/test-wire-required.mjs "$LOOM_BIN" "$scratch/wire"

echo "== native tool history and control provenance =="
node scripts/test-cursor-native-history.mjs
node scripts/test-codex-call-ids.mjs
node scripts/test-claude-exec-history.mjs
node scripts/test-claude-notes-history.mjs
node scripts/test-codex-checkpoints.mjs
node scripts/check-codex-corpus.mjs
node scripts/test-codex-exec-status.mjs
node scripts/test-codex-item-completed.mjs
node scripts/test-claude-event-batch.mjs
node scripts/test-source-version.mjs
node scripts/test-continuation-probe.mjs
python3 scripts/test-claude-task-notifications.py
python3 scripts/test-cursor-ide-transcript.py

echo "== audit harness self-tests =="
node scripts/audit-corpora.self-test.mjs
node scripts/audit-codex-claude.self-test.mjs
node scripts/audit-lifecycle-matrix.mjs --loom "$LOOM_BIN" \
  --scratch "$scratch/lifecycle-input" --output "$scratch/lifecycle-output" \
  --report "$scratch/lifecycle-report.json"

echo "== route and release metadata =="
node scripts/check-conversion-matrix.mjs
node scripts/check-reviewed-versions.mjs
node scripts/release-notes.mjs --check

echo "repository-local verification passed"
