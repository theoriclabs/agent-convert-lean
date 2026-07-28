import Loom
import LoomOps

open Loom Loom.Ops

-- A minimal Claude-origin transcript: main thread + one sidechain,
-- one open (unanswered) tool call, one entry with a bad parent pointer.
def org : Origin := { format := .claudeCode, sourceRef := "smoke" }

def t : Transcript := {
  threads := #[
    { kind := .main },
    { kind := .sidechain (.resolved 0 0) }
  ],
  entries := #[
    { payload := .assistantMsg
        [.toolCall { raw := "Task", canonical := some .agentSpawn } Lean.Json.null none],
      time := Time.recorded ⟨1000⟩, origin := org },
    { parent := some 0,
      payload := .userMsg [.text "hello"],
      time := Time.absent, origin := org },
    { parent := some 5,  -- dangling forward parent: violation
      payload := .assistantMsg [.text "world"],
      time := Time.sequenced 2, origin := org }
  ],
  origin := org
}

#eval violations t
#eval openCalls t
#eval (lossyConcepts .claudeCode .pi).map reprStr
#eval (obligations .pi t).map reprStr
#eval (obligations .claudeCode t).map reprStr

-- Census facts, now queryable from the spec:
-- every concept has 7 format answers (media forces the 15th row).
#eval Concept.all.length                         -- 15 (media added)
#eval (Concept.all.map (fun c => supports .cursorIde c)).length  -- 15, total
-- Cursor IDE is the richest source; cursor-agent CLI the poorest.
#eval Concept.all.filter (fun c => supports .cursorIde c = Support.native) |>.length
#eval Concept.all.filter (fun c => supports .cursorAgent c = Support.absent) |>.length
-- claims register grew as the census refuted/confirmed items
#eval claims.length
#eval openClaims.map (·.id)

-- Defect taxonomy: silent+latent outranks loud+import; census added D13–D17.
#eval severityRank .silent .latent   -- 7
#eval severityRank .loud .importTime -- 0
#eval knownDefects.length            -- 17 (was 12)
#eval (knownDefects.filter (fun d => d.visibility = Visibility.silent)).length
#eval metrics.map (·.id)
#eval decisionRules.map (·.id)
