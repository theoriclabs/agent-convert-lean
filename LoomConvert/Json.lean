import Lean

/-! Shared JSON accessors. Optional readers are strict about JSON types; wire
readers additionally accept the numeric and boolean strings emitted by v0. -/
namespace LoomConvert
open Lean (Json)

def ostr (j : Json) (k : String) : Option String :=
  (j.getObjVal? k >>= Json.getStr?).toOption

def oobj (j : Json) (k : String) : Option Json :=
  (j.getObjVal? k).toOption

def onat (j : Json) (k : String) : Option Nat :=
  (j.getObjVal? k >>= Json.getNat?).toOption

def oarr (j : Json) (k : String) : Option (Array Json) :=
  (j.getObjVal? k >>= Json.getArr?).toOption

def obool (j : Json) (k : String) : Option Bool :=
  (j.getObjVal? k >>= Json.getBool?).toOption

def oboolD (j : Json) (k : String) : Bool := (obool j k).getD false

def optStr (k : String) : Option String → List (String × Json)
  | some s => [(k, Json.str s)]
  | none => []

def optJson (k : String) : Option Json → List (String × Json)
  | some j => [(k, j)]
  | none => []

def optNat (k : String) : Option Nat → List (String × Json)
  | some n => [(k, Json.str (toString n))]
  | none => []

def ensureObj (ctx : String) : Json → Except String Unit
  | Json.obj _ => .ok ()
  | _ => .error s!"{ctx}: expected object"

def objField (ctx : String) (j : Json) (k : String) : Except String Json := do
  ensureObj ctx j
  match j.getObjVal? k with
  | .ok v => .ok v
  | .error _ => .error s!"{ctx}: missing required field '{k}'"

def strJson (ctx : String) (j : Json) : Except String String :=
  match Json.getStr? j with
  | .ok s => .ok s
  | .error _ => .error s!"{ctx}: expected string"

def strField (ctx : String) (j : Json) (k : String) : Except String String := do
  strJson s!"{ctx}.{k}" (← objField ctx j k)

def optStrField (ctx : String) (j : Json) (k : String) : Except String (Option String) := do
  ensureObj ctx j
  match j.getObjVal? k with
  | .ok v => do pure (some (← strJson s!"{ctx}.{k}" v))
  | .error _ => .ok none

def arrJson (ctx : String) (j : Json) : Except String (Array Json) :=
  match Json.getArr? j with
  | .ok a => .ok a
  | .error _ => .error s!"{ctx}: expected array"

def arrField (ctx : String) (j : Json) (k : String) : Except String (Array Json) := do
  arrJson s!"{ctx}.{k}" (← objField ctx j k)

def natJson (ctx : String) (j : Json) : Except String Nat :=
  match Json.getNat? j with
  | .ok n => .ok n
  | .error _ =>
      match Json.getStr? j with
      | .ok s =>
          match s.toNat? with
          | some n => .ok n
          | none => .error s!"{ctx}: expected natural-number string"
      | .error _ => .error s!"{ctx}: expected natural number or natural-number string"

def natField (ctx : String) (j : Json) (k : String) : Except String Nat := do
  natJson s!"{ctx}.{k}" (← objField ctx j k)

def optNatField (ctx : String) (j : Json) (k : String) : Except String (Option Nat) := do
  ensureObj ctx j
  match j.getObjVal? k with
  | .ok v => do pure (some (← natJson s!"{ctx}.{k}" v))
  | .error _ => .ok none

def boolJson (ctx : String) (j : Json) : Except String Bool :=
  match Json.getBool? j with
  | .ok b => .ok b
  | .error _ =>
      match Json.getStr? j with
      | .ok "true" => .ok true
      | .ok "false" => .ok false
      | .ok _ => .error s!"{ctx}: expected boolean string"
      | .error _ => .error s!"{ctx}: expected boolean or boolean string"

def boolField (ctx : String) (j : Json) (k : String) : Except String Bool := do
  boolJson s!"{ctx}.{k}" (← objField ctx j k)

def optBoolField (ctx : String) (j : Json) (k : String) : Except String (Option Bool) := do
  ensureObj ctx j
  match j.getObjVal? k with
  | .ok v => do pure (some (← boolJson s!"{ctx}.{k}" v))
  | .error _ => .ok none

def parseJsonList {α : Type} (ctx : String) (a : Array Json)
    (f : String → Json → Except String α) : Except String (List α) :=
  (a.toList.zipIdx).mapM (fun (j, i) => f s!"{ctx}[{i}]" j)

end LoomConvert
