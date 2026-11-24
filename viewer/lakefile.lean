import Lake

open Lake DSL

package loom_viewer where
  version := v!"0.1.1"
  -- The bundled linker emits a signature that macOS rejects for these binaries.
  moreLinkArgs := if System.Platform.isOSX then #["-fuse-ld=/usr/bin/ld"] else #[]

require loom from ".."
require leanreact from git "https://github.com/theoriclabs/lean-react" @ "v0.4.0"

lean_lib AssistantUI where
  srcDir := "vendor/assistant-ui"

@[default_target]
lean_lib Viewer

@[default_target]
lean_exe loom_viewer where
  root := `Main

lean_exe loom_viewer_checks where
  root := `Checks
