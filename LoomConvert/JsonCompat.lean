import Lean.Data.Json.Parser

namespace LoomConvert

open Lean
open Std.Internal.Parsec Std.Internal.Parsec.String

mutual
  private partial def recordedValue : Parser Json := do
    match ← peek! with
    | '{' =>
      skipChar '{'
      ws
      let members ← if (← peek!) == '}' then pure [] else recordedMembers []
      skipChar '}'
      ws
      return Json.mkObj members.reverse
    | '[' =>
      skipChar '['
      ws
      let elements ← if (← peek!) == ']' then pure #[] else recordedElements #[]
      skipChar ']'
      ws
      return .arr elements
    | _ => Json.Parser.anyCore

  private partial def recordedMembers (members : List (String × Json)) :
      Parser (List (String × Json)) := do
    skipChar '"'
    let key ← Json.Parser.str
    ws
    skipChar ':'
    ws
    let value ← recordedValue
    let members := (key, value) :: members
    if (← peek!) == ',' then
      skipChar ','
      ws
      recordedMembers members
    else
      pure members

  private partial def recordedElements (elements : Array Json) : Parser (Array Json) := do
    let value ← recordedValue
    let elements := elements.push value
    if (← peek!) == ',' then
      skipChar ','
      ws
      recordedElements elements
    else
      pure elements
end

/-- Normalize duplicate keys in historical JSONL using the last recorded value,
as Lean 4.33 did. Callers must apply their original-byte validation to any
exporter-owned extensions before interpreting them. -/
def parseRecordedJson (text : String) : Except String Json :=
  match Json.parse text with
  | .ok value => .ok value
  | .error error =>
    if (error.splitOn "duplicate object key ").length == 1 then .error error
    else Parser.run (ws *> recordedValue <* eof) text

end LoomConvert
