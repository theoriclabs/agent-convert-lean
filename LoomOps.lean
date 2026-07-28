import LoomOps.Conversion
import LoomOps.Defects
import LoomOps.Eval
import LoomOps.Roadmap
import LoomOps.Design
import LoomOps.Interop
import LoomOps.Refinement

/-!
# LoomOps — the HOW

Everything operational about transcript conversion: what an exporter must do
(`LoomOps.Conversion`), how conversion failures classify (`LoomOps.Defects`),
how we'll judge the whole approach (`LoomOps.Eval`), and the project's own
lessons + next steps (`LoomOps.Roadmap`).

The dependency direction is the design: **LoomOps imports Loom; Loom can
never import LoomOps.** The description of the domain (what a transcript is,
what formats can say, what's valid, what we believe) stays free of process,
and the compiler enforces it.
-/
