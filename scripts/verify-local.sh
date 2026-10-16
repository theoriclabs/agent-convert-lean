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
# The lifecycle audit seals its owned snapshots read-only until verification ends.
trap 'chmod -R u+w "$scratch"; rm -rf "$scratch"' EXIT
export LOOM_BIN="$ROOT/.lake/build/bin/loom"

echo "== product build and Lean smoke checks =="
lake build loom LoomOps LoomRequirements
lake env lean smoke.lean
lake env lean convert_smoke.lean
lake env lean testdata/codex/checkpoint-pins.lean

echo "== filesystem publication and wire contracts =="
"$LOOM_BIN" self-test-sidecar-publication
node scripts/test-wire-required.mjs "$LOOM_BIN" "$scratch/wire"

echo "== native tool history and control provenance =="
node scripts/test-cursor-native-history.mjs
node scripts/test-codex-call-ids.mjs
node scripts/test-claude-exec-history.mjs
node scripts/test-codex-checkpoints.mjs
node scripts/test-codex-exec-status.mjs
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
node scripts/release-notes.mjs --check

echo "repository-local verification passed"
