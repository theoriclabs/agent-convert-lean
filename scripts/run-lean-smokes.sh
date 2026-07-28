#!/usr/bin/env bash
# Build product libs, then run the root Lean #eval smokes.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
lake build Loom LoomOps LoomConvert
lake env lean smoke.lean
lake env lean convert_smoke.lean
