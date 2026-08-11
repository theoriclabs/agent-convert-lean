import LoomConvert.Pi
import LoomConvert.Parity
import LoomConvert.ClaudeCode
import LoomConvert.CodexCli
import LoomConvert.CursorAgent
import LoomConvert.CursorIde
import LoomConvert.Hermes
import LoomConvert.GoogleAiStudio
import LoomConvert.OpenCode
import LoomConvert.CursorIdeActuator
import LoomConvert.ClaudeSubagents
import LoomConvert.CursorAgentSubagents
import LoomConvert.Wire

/-!
# LoomConvert — the executable port

The Lean implementation of transcript conversion (the "kill TS" target).
Imports `Loom` (the spec: IR + WellFormed + format matrix); each format's
importer/exporter realizes that format's file under `Loom/Formats/`.

Three-role model (bridge guide §1): the **semantic core** is here, in Lean —
parsing, the IR, well-formedness, obligations. The **actuator** is only
`IO.FS` (read/write JSONL) plus, for Cursor IDE, a single `sqlite3` read;
it carries no meaning. There is no separate authoring surface — the harnesses
authored the transcripts already.

Status: the developer-preview implementation imports Loom wire, pi, Claude,
Codex, Cursor Agent, OpenCode, Cursor IDE, Hermes, and Google AI Studio;
exports Loom wire, pi, Claude, Codex, Cursor Agent, and OpenCode; and carries build-checked parity,
round-trip, wire-compatibility, and sidechain witnesses. The requirements and
proof boundary are in the sibling `LoomRequirements` library.
-/
