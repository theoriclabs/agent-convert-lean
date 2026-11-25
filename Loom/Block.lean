import Loom.Core

/-! Role-generic observations over the three concrete content sums. The IR
continues to enforce authorship through UserBlock, AssistantBlock and EnvBlock. -/
namespace Loom

class Block (β : Type) where
  text? : β → Option String
  media? : β → Option (String × String)
  unmodeled? : β → Option (String × Lean.Json)

instance : Block UserBlock where
  text? | .text value => some value | _ => none
  media? | .media mime locator => some (mime, locator) | _ => none
  unmodeled? | .unmodeled label raw => some (label, raw) | _ => none

instance : Block AssistantBlock where
  text? | .text value => some value | _ => none
  media? | .media mime locator => some (mime, locator) | _ => none
  unmodeled? | .unmodeled label raw => some (label, raw) | _ => none

instance : Block EnvBlock where
  text? := fun _ => none
  media? := fun _ => none
  unmodeled? | .unmodeled label raw => some (label, raw) | _ => none

def Block.isText {β : Type} [Block β] (block : β) : Bool :=
  (Block.text? block).isSome

def Block.mentions {β : Type} [Block β] (needle : String) (block : β) : Bool :=
  (Block.text? block).any (fun text => (text.splitOn needle).length > 1)

/-- Common arms share policy; role-specific tool and thinking arms are left to
an adapter. A text block always has a native textual representation. -/
def Block.commonNeedsCarrier {β : Type} [Block β] (block : β)
    (mediaSupported : String → String → Bool)
    (unmodeledSupported : String → Lean.Json → Bool := fun _ _ => false) : Option Bool :=
  if (Block.text? block).isSome then some false
  else if let some (mime, locator) := Block.media? block then
    some (!mediaSupported mime locator)
  else if let some (label, raw) := Block.unmodeled? block then
    some (!unmodeledSupported label raw)
  else none

end Loom
