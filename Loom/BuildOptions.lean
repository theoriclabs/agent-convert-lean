import Lean

register_option loom.coreRevision : String := {
  defValue := "working-tree"
  descr := "immutable source revision represented by this Loom binary"
}
