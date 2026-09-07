import Lean

/-! Cursor persists agent.v1.ToolCall protobufs as base64 in toolCallBinary.
The inline result is a UI projection and may be removed while the binary still
holds the recorded output. This bounded decoder covers the result schemas for
grep, edit, and conversation search. Field numbers/JSON names were checked
against Cursor's installed protobuf descriptors (2026-09-07); no Cursor runtime
or JavaScript dependency is needed by Loom. Unsupported or malformed data is
reported, never interpreted as proof that the source result is absent. -/

namespace LoomConvert.CursorToolBinary
open Lean

private def base64Digit (c : Char) : Option Nat :=
  if 'A' ≤ c && c ≤ 'Z' then some (c.toNat - 'A'.toNat)
  else if 'a' ≤ c && c ≤ 'z' then some (c.toNat - 'a'.toNat + 26)
  else if '0' ≤ c && c ≤ '9' then some (c.toNat - '0'.toNat + 52)
  else if c == '+' then some 62 else if c == '/' then some 63 else none

def decodeBase64 (s : String) : Except String ByteArray := do
  if s.length > 24000000 then throw "toolCallBinary exceeds decoder limit"
  if s.length % 4 != 0 then throw "invalid base64 length"
  let mut out := ByteArray.empty
  let mut acc := 0
  let mut bits := 0
  let mut padding := 0
  for c in s.toList do
    if c == '=' then padding := padding + 1
    else
      if padding > 0 then throw "base64 data after padding"
      let some n := base64Digit c | throw "invalid base64 character"
      acc := acc * 64 + n
      bits := bits + 6
      if bits ≥ 8 then
        bits := bits - 8
        out := out.push (UInt8.ofNat (acc / 2 ^ bits))
        acc := acc % 2 ^ bits
  if padding > 2 || acc != 0 || bits != padding * 2 then
    throw "invalid base64 padding"
  pure out

private structure Field where
  number : Nat
  wire : Nat
  value : Nat := 0
  bytes : ByteArray := ByteArray.empty
  deriving Inhabited

private def varint (bytes : ByteArray) (start : Nat) : Except String (Nat × Nat) := do
  let mut value := 0
  let mut pos := start
  for i in [:10] do
    if pos ≥ bytes.size then throw "truncated protobuf varint"
    let b := bytes[pos]!.toNat
    if i == 9 && b > 1 then throw "protobuf varint overflow"
    pos := pos + 1
    value := value + (b % 128) * 2 ^ (7 * i)
    if b < 128 then return (value, pos)
  throw "protobuf varint overflow"

private def fields (bytes : ByteArray) : Except String (Array Field) := do
  let mut out := #[]
  let mut pos := 0
  for _ in [:bytes.size] do
    if pos == bytes.size then break
    let (tag, next) ← varint bytes pos
    pos := next
    let number := tag / 8
    let wire := tag % 8
    if number == 0 || number ≥ 2 ^ 29 then throw "invalid protobuf field number"
    if wire == 0 then
      let (value, next) ← varint bytes pos
      pos := next
      out := out.push { number, wire, value }
    else if wire == 2 || wire == 1 || wire == 5 then
      let (size, next) ← if wire == 2 then varint bytes pos
        else pure (if wire == 1 then 8 else 4, pos)
      if next + size > bytes.size then throw "truncated protobuf field"
      out := out.push { number, wire, bytes := bytes.extract next (next + size) }
      pos := next + size
    else throw "unsupported protobuf wire type"
  pure out

private def unique (fs : Array Field) (number : Nat) : Except String (Option Field) :=
  match (fs.filter (·.number == number)).toList with
  | [] => .ok none
  | [f] => .ok (some f)
  | _ => .error s!"ambiguous repeated protobuf field {number}"

private def textField (f : Field) : Except String String := do
  if f.wire != 2 then throw "expected protobuf string"
  let some text := String.fromUTF8? f.bytes | throw "invalid protobuf UTF-8"
  pure text

private structure Spec where
  number : Nat
  name : String
  kind : String
  repeated : Bool := false
  optional : Bool := false
  oneof : Bool := false

private def scalar (n : Nat) (name kind : String) (optional := false) : Spec :=
  ⟨n, name, kind, false, optional, false⟩
private def msg (n : Nat) (name kind : String) (repeated := false) : Spec :=
  ⟨n, name, kind, repeated, false, false⟩
private def choice (n : Nat) (name kind : String) : Spec :=
  ⟨n, name, kind, false, false, true⟩

private def schema : String → List Spec
  | "GrepResult" => [choice 1 "success" "GrepSuccess", choice 2 "error" "Error"]
  | "GrepSuccess" => [scalar 1 "pattern" "string", scalar 2 "path" "string",
      scalar 3 "outputMode" "string", msg 4 "workspaceResults" "map:GrepUnion",
      msg 5 "activeEditorResult" "GrepUnion"]
  | "GrepUnion" => [choice 1 "count" "GrepCount", choice 2 "files" "GrepFiles",
      choice 3 "content" "GrepContent"]
  | "GrepCount" => [msg 1 "counts" "GrepFileCount" true,
      scalar 2 "totalFiles" "int32", scalar 3 "totalMatches" "int32",
      scalar 4 "clientTruncated" "bool", scalar 5 "ripgrepTruncated" "bool",
      scalar 6 "headLimitApplied" "int32" true, scalar 7 "offsetApplied" "int32" true]
  | "GrepFileCount" => [scalar 1 "file" "string", scalar 2 "count" "int32"]
  | "GrepFiles" => [⟨1, "files", "string", true, false, false⟩,
      scalar 2 "totalFiles" "int32", scalar 3 "clientTruncated" "bool",
      scalar 4 "ripgrepTruncated" "bool", scalar 5 "headLimitApplied" "int32" true,
      scalar 6 "offsetApplied" "int32" true]
  | "GrepContent" => [msg 1 "matches" "GrepFileMatch" true,
      scalar 2 "totalLines" "int32", scalar 3 "totalMatchedLines" "int32",
      scalar 4 "clientTruncated" "bool", scalar 5 "ripgrepTruncated" "bool",
      scalar 6 "headLimitApplied" "int32" true, scalar 7 "offsetApplied" "int32" true]
  | "GrepFileMatch" => [scalar 1 "file" "string", msg 2 "matches" "GrepMatch" true]
  | "GrepMatch" => [scalar 1 "lineNumber" "int32", scalar 2 "content" "string",
      scalar 3 "contentTruncated" "bool", scalar 4 "isContextLine" "bool"]
  | "Error" => [scalar 1 "error" "string"]
  | "EditResult" => [choice 1 "success" "EditSuccess", choice 2 "fileNotFound" "Path",
      choice 3 "readPermissionDenied" "Path", choice 4 "writePermissionDenied" "WriteDenied",
      choice 6 "rejected" "Rejected", choice 7 "error" "EditError"]
  | "EditSuccess" => [scalar 1 "path" "string", scalar 3 "linesAdded" "int32" true,
      scalar 4 "linesRemoved" "int32" true, scalar 5 "diffString" "string" true,
      scalar 6 "beforeFullFileContent" "string" true, scalar 7 "afterFullFileContent" "string",
      scalar 8 "message" "string" true]
  | "Path" => [scalar 1 "path" "string"]
  | "WriteDenied" => [scalar 1 "path" "string", scalar 2 "error" "string",
      scalar 3 "isReadonly" "bool"]
  | "Rejected" => [scalar 1 "path" "string", scalar 2 "reason" "string"]
  | "EditError" => [scalar 1 "path" "string", scalar 2 "error" "string",
      scalar 5 "modelVisibleError" "string" true]
  | "SearchResult" => [choice 1 "success" "SearchSuccess", choice 2 "error" "Error"]
  | "SearchSuccess" => [msg 1 "hits" "SearchHit" true, scalar 2 "truncated" "bool",
      scalar 3 "partial" "bool", scalar 4 "rebuilding" "bool"]
  | "SearchHit" => [scalar 1 "conversationId" "string", scalar 2 "title" "string",
      scalar 3 "source" "sourceEnum", scalar 4 "updatedAtMs" "int64",
      scalar 5 "snippet" "string" true]
  | _ => []

private def signed (n bits : Nat) : Int :=
  let n := n % 2 ^ bits
  if n ≥ 2 ^ (bits - 1) then Int.ofNat n - Int.ofNat (2 ^ bits) else Int.ofNat n

private partial def decode (kind : String) (bytes : ByteArray) (depth : Nat) :
    Except String Json := do
  if depth == 0 then throw "protobuf nesting limit"
  let fs ← fields bytes
  let specs := schema kind
  if specs.isEmpty then throw s!"unsupported protobuf message {kind}"
  for f in fs do
    if !specs.any (·.number == f.number) then
      throw s!"unsupported protobuf field {kind}.{f.number}; raw binary retained"
  if (fs.filter fun f => specs.any (fun s => s.oneof && s.number == f.number)).size > 1 then
    throw s!"ambiguous protobuf oneof {kind}"
  let mut out : List (String × Json) := []
  for spec in specs do
    let values := fs.filter (·.number == spec.number)
    if values.isEmpty then continue
    if spec.kind.startsWith "map:" then
      let mut entries : List (String × Json) := []
      for f in values do
        if f.wire != 2 then throw "expected protobuf map"
        let item ← fields f.bytes
        if item.any (fun x => x.number != 1 && x.number != 2) then throw "unknown map field"
        let key ← match ← unique item 1 with
          | some field => textField field
          | none => pure ""
        if entries.any (·.1 == key) then throw "duplicate protobuf map key"
        let some value ← unique item 2 | throw "protobuf map value missing"
        if value.wire != 2 then throw "expected protobuf map message"
        let decoded ← decode (spec.kind.drop 4 |>.toString) value.bytes (depth - 1)
        entries := entries ++ [(key, decoded)]
      out := out ++ [(spec.name, Json.mkObj entries)]
      continue
    if !spec.repeated && values.size > 1 then throw "duplicate singular protobuf field"
    let mut decoded : Array Json := #[]
    for f in values do
      let value ← if spec.kind == "string" then pure (Json.str (← textField f))
        else if ["bool", "int32", "int64", "sourceEnum"].contains spec.kind then do
          if f.wire != 0 then throw "expected protobuf varint scalar"
          if spec.kind == "bool" then pure (Json.bool (f.value != 0))
          else if spec.kind == "int32" then pure (toJson (signed f.value 32))
          else if spec.kind == "int64" then pure (Json.str (toString (signed f.value 64)))
          else match f.value with
            | 0 => pure (Json.str "CONVERSATION_SEARCH_SOURCE_UNSPECIFIED")
            | 1 => pure (Json.str "CONVERSATION_SEARCH_SOURCE_LOCAL")
            | 2 => pure (Json.str "CONVERSATION_SEARCH_SOURCE_CLOUD_CACHE")
            | n => pure (toJson (signed n 32))
        else do
          if f.wire != 2 then throw "expected protobuf message"
          decode spec.kind f.bytes (depth - 1)
      let defaultScalar := (spec.kind == "string" && value == Json.str "") ||
        (spec.kind == "bool" && value == Json.bool false) ||
        (spec.kind == "int32" && f.value == 0) || (spec.kind == "int64" && f.value == 0) ||
        (spec.kind == "sourceEnum" && f.value == 0)
      if !defaultScalar || spec.optional || spec.repeated then decoded := decoded.push value
    if !decoded.isEmpty then
      out := out ++ [(spec.name, if spec.repeated then Json.arr decoded else decoded[0]!)]
  pure (Json.mkObj out)

/-- Recover a result only from a supported tool family and the same recorded
call ID. Whole raw binaries remain in the source entry's provenance. -/
def recoverResult (encoded : String) (toolEnum : Nat) (name : String)
    (callId : Option String) : Except String (Option Json) := do
  let (tag, kind) ← match toolEnum, name with
    | 41, _ => pure (5, "GrepResult")
    | 38, _ => pure (12, "EditResult")
    | 0, "search_conversations" => pure (69, "SearchResult")
    | _, _ => throw "unsupported toolCallBinary tool family; result recovery unresolved"
  let root ← fields (← decodeBase64 encoded)
  let tools := root.filter (fun f => ![54, 57, 59, 60].contains f.number)
  if tools.size != 1 || tools[0]!.number != tag || tools[0]!.wire != 2 then
    throw "toolCallBinary tool family mismatch"
  match ← unique root 57 with
  | some f =>
      let id ← textField f
      if callId != some id then throw "toolCallBinary call ID mismatch"
  | none => pure () -- Older binaries predate this optional field; bubble owns the binary.
  let call ← fields tools[0]!.bytes
  let some result ← unique call 2 | return none
  if result.wire != 2 then throw "invalid binary tool result"
  pure (some (← decode kind result.bytes 32))

example : ((decodeBase64 "AQID").toOption.map (fun b => b.data == #[1, 2, 3])) = some true := by native_decide
example : (decodeBase64 "A===" |>.toOption).isNone := by native_decide
example : (decodeBase64 "AB==" |>.toOption).isNone := by native_decide

end LoomConvert.CursorToolBinary
