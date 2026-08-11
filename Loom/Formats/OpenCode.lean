import Loom.Concepts

/-!
# Format — OpenCode

OpenCode's supported interchange surface is the JSON document emitted by
`opencode export`: a session `info` object and `messages[]`, where each message
contains an `info` envelope and ordered `parts[]`.  The same document is
accepted by `opencode import <file>`.

Tool calls and their terminal result are combined in one `tool` part.  Loom's
adapter splits that part into a positionally linked assistant call and
environment result on import, then joins the pair again on export.
-/

namespace Loom.Formats.OpenCode

def storage : String := "opencode export <session-id> / opencode import <file>"

def fileShape : FileShape := .exportBlob

inductive PartKind where
  | text
  | reasoning
  | file
  | tool
  | compaction
  | subtask
  | stepStart
  | stepFinish
  | snapshot
  | patch
  | agent
  | retry
  | unrecognized (label : String)
  deriving Repr, DecidableEq

def disposition : PartKind → Disposition
  | .text       => .mapped "UserBlock.text / AssistantBlock.text"
  | .reasoning  => .mapped "AssistantBlock.thinking"
  | .file       => .mapped "UserBlock.media / AssistantBlock.media"
  | .tool       => .mapped "AssistantBlock.toolCall + EnvBlock.toolResult"
  | .compaction => .mapped "Payload.compaction (paired summary message)"
  | .subtask    => .preservedInExtras
  | .stepStart  => .preservedInExtras
  | .stepFinish => .preservedInExtras
  | .snapshot   => .preservedInExtras
  | .patch      => .preservedInExtras
  | .agent      => .preservedInExtras
  | .retry      => .preservedInExtras
  | .unrecognized _ => .unverified

def supports : Concept → Support
  | .identity        => .native
  | .threading       => .native
  | .time            => .native
  | .roles           => .native
  | .textContent     => .native
  | .thinkingContent => .approximate "reasoning text is native; provider signature metadata is open-ended"
  | .toolLifecycle   => .native
  | .errorSignaling  => .native
  | .compaction      => .native
  | .branching       => .absent
  | .sidechains      => .absent
  | .usage           => .native
  | .environment     => .native
  | .metaEvents      => .approximate "converter events use ignored synthetic parts"
  | .media           => .native

end Loom.Formats.OpenCode
