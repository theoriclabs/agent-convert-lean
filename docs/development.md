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

With Lean/Lake, Node, Python 3, and `sqlite3` on PATH:

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

The full `lake build LoomRequirements` gate passes and is included in local
verification. The lifecycle audit's identity validator still uses an exact key whitelist
that rejects the CLI's additive `compilerVersion` and `capabilities` fields;
its self-tests passing does not mean its 8-by-5 product audit passes.

The largest remaining modules are the Codex, Claude, and Pi adapters. They mix
parsing, target emission, helpers, and regression fixtures. `Parity.lean` and
`Wire.lean` import `Pi.lean`, so extracting genuinely shared codec utilities
would reduce that coupling before splitting adapters into import/export/tests.
Keep compile-time pins in the build during any such move. Historical release
evidence and recovered session artifacts should be inventoried before moving
them; they are not interchangeable with synthetic test fixtures.
