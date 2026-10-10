import Viewer.UI
import LeanReact.Compiler

/-! Emit the browser module: `lake env lean Generate.lean` writes `web/generated/viewer.mjs`,
which `scripts/build.mjs` bundles with the LeanReact runtime and assistant-ui for Lean. The
intrinsic module path is relative to the generated file. -/

run_meta do
  IO.FS.createDirAll "web/generated"
  LeanJS.writeModule "web/generated/viewer.mjs" #[
    `Viewer.UI.App, `Viewer.UI.pageSize, `Viewer.Harness.parse, `Viewer.Harness.slug, `Viewer.Harness.all,
    `Viewer.Harness.label, `AssistantUI.Message.ofTranscript]
    (LeanReact.Compiler.options "../../../../leanreact/engine/adapters/leanjs-react.mjs")
