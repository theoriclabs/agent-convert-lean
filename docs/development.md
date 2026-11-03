# Development guide

## Module boundaries

The core dependency direction is useful and should stay explicit:

| Location | Responsibility |
| --- | --- |
| `Loom/` | Transcript IR, provenance, validity, format descriptions, rendering |
| `LoomOps/` | Conversion obligations, fidelity policy, operational requirements |
| `LoomConvert/<Format>.lean` | Format parsers, exporters, and compile-time regression pins |
| `LoomConvert/CursorIdeActuator.lean` | Read-only SQLite acquisition of a selected IDE composer |
| `LoomConvert/CursorIdeTranscript.lean` | Checked recovery of results omitted by IDE JSONL exports |
| `LoomConvert/Cli/Formats.lean` | Pure detection, routing, and flat-export validation |
| `LoomConvert/Cli/Publication.lean` | Staged file writes, sidecar projection, ownership, rollback, and fault-injection tests |
| `LoomConvert/Main.lean` | CLI options, target defaults, continuation policy, reporting, discovery, and command orchestration |
| `LoomRequirements/` | Requirements and implementation evidence; imports the product, never the reverse |
| `cli/` | Installed session workflow: source lookup, PDF projection, native Codex validation, publication, naming, and receipts |
| `mcp/`, `viewer/` | Clients of the conversion core; the viewer is a separate package with external dependencies |

The CLI split keeps the existing public dispatch names available to callers
importing `LoomConvert.Main`. Publication internals remain private; its IO
regressions stay beside the transaction so fault injection need not become a
public API. The `LoomConvert` umbrella imports adapters, not CLI modules.

Codex active-context selection remains in `Main.lean`: continuation targets
use `importSourceText`, independently of subagent policy. The moved format
dispatcher is a raw importer and must not replace that continuation entry point.

Cursor's JSONL format is shared by IDE exports and Agent transcripts. The pure
`importCursorAgent` parser reads only supplied bytes. CLI acquisition uses
`importCursorTranscriptFile` (or its already-read-text counterpart) to recover
matching IDE results. Recovery and SQLite access do not belong in the parser.
Both default derivation and the actual conversion must use path-aware reads.

## Local checks

With Lean/Lake, Node, Python 3, `sqlite3`, and Poppler (`pdftotext` / `pdftoppm`) on PATH:

```sh
scripts/verify-local.sh
```

This builds `loom`, `LoomOps`, and `LoomRequirements`, runs the two Lean smoke programs, tests
publication rollback and wire mutations, exercises native tool history and
Cursor store recovery using synthetic data, and checks audit harnesses, route
inventory, and release metadata. No authenticated model requests are made.
Lean `example`/`native_decide` pins remain part of the build.

Useful focused commands:

```sh
lake build loom
python3 scripts/test-cursor-ide-transcript.py
node scripts/test-cursor-native-history.mjs
node scripts/check-conversion-matrix.mjs
```

`scripts/verify.sh` is the older integration/release gate. It requires a separate
TypeScript host checkout via `LOOM_UTILS_ROOT` and includes external harness
checks. It is not the local development entry point. The viewer has its own
[build and checks](../viewer/README.md).

## Validation gaps and remaining structure work

The full `lake build LoomRequirements` gate and the lifecycle audit's 8-by-5
conversion matrix pass and are included in local verification. The matrix also
runs its mutation self-tests. These are artifact checks; they do not replace
authenticated continuation probes or cover formats absent from that fixture set.

The largest remaining modules are the Codex, Claude, and Pi adapters. They mix
parsing, target emission, helpers, and regression fixtures. `Parity.lean` and
`Wire.lean` import `Pi.lean`, so extracting genuinely shared codec utilities
would reduce that coupling before splitting adapters into import/export/tests.
Keep compile-time pins in the build during any such move. Historical release
evidence and recovered session artifacts should be inventoried before moving
them; they are not interchangeable with synthetic test fixtures.

## Installed session CLI

`python3 scripts/install-agent-convert.py --build` builds the current committed
core with its pinned toolchain in an isolated directory. The installer copies
that binary and `cli/` under `~/.local/share/agent-convert`, adds a launcher in
`~/.local/bin`, and installs `skills/agent-session-converter` for Codex discovery.
`--core /path/to/loom` reuses a built/released binary. Source edits do not silently
change an installed core. `agent-convert version` reports the exact core revision.

The CLI owns mechanical session migration. It delegates IR conversion and
compaction policy to Loom. Claude results, images, and authenticated peer context
are projected through a main-thread archive; Codex continuation sources always enter the core directly,
so active-context selection remains in force. PDF and image bytes are read from
recorded results, with originals retained. Missing results are recovered only from
unambiguous same-session records matching retained calls and source order;
conflicting observations refuse publication. No historical tool is executed.

```sh
LOOM_BIN=/path/to/loom python3 scripts/test-agent-convert.py
python3 scripts/test-agent-convert.py --core /path/to/loom --native
```

The first command checks file conversion, PDF/source fidelity, ID remapping,
installation in a temporary store, and refusal cases. It needs Poppler for the
PDF case. The native variant also needs Codex and localhost binding; it runs
Codex against a local fixed-response provider, verifies exact native calls and
outputs in the captured request, and makes no external model request. These
checks do not prove live recall by a model. Failure work is retained for diagnosis;
successful work is removed unless `--keep-work` is requested.
