import Lake
open Lake DSL

package loom where
  moreLeanArgs := #[s!"-Dweak.loom.coreRevision={(get_config? coreRevision).getD "working-tree"}"]

/-- The WHAT: transcript IR, format matrix, validity, claims. -/
@[default_target]
lean_lib Loom

/-- The HOW: obligations, defect taxonomy, evaluation protocol.
Imports Loom; never the reverse. -/
@[default_target]
lean_lib LoomOps

/-- The executable port (the "kill TS" target): importers/exporters in Lean.
Imports Loom (spec); the actuator is only file IO. -/
@[default_target]
lean_lib LoomConvert

/-- The requirements case and its implementation evidence. Imports the product;
the product libraries never import the requirements package. -/
@[default_target]
lean_lib LoomRequirements

/-- `lake exe loom convert <from> <to> <input> [output]` — the CLI. -/
lean_exe loom where
  root := `LoomConvert.Main
