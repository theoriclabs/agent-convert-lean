import Loom

/-! Reviewed source versions are evidence boundaries, not acceptance whitelists.
Unknown additive fields remain open-world. Pi's recorded version is a file-schema
number. Cursor Agent's reviewed native records do not contain a release version,
so there is deliberately no invented baseline for that format. -/

namespace LoomConvert
open Loom
open Lean (Json)

/-- Keep this table aligned with the versioned synthetic fixture directories;
`scripts/check-reviewed-versions.mjs` checks the equality in both directions. -/
def reviewedSourceVersion : Format → Option String
  | .codexCli => some "0.162.1"
  | .claudeCode => some "2.1.274"
  | .pi => some "3"
  | .openCode => some "1.1.34"
  | .cursorAgent | .cursorIde | .hermes | .googleAiStudio | .other _ => none

private def versionNat? (part : String) : Option Nat := do
  guard (!part.isEmpty && part.toList.all Char.isDigit)
  guard (part == "0" || !part.startsWith "0")
  part.toNat?

private def versionParts? (version : String) : Option (List Nat × List String) := do
  let value := if version.startsWith "v" then (version.drop 1).toString else version
  let coreAndPre := (value.splitOn "+").head!
  let parts := coreAndPre.splitOn "-"
  let core := (parts.head!).splitOn "."
  guard (core.length == 3 || core.length == 1)
  let numbers ← core.mapM versionNat?
  let prerelease := if parts.length == 1 then [] else
    (String.intercalate "-" parts.tail!).splitOn "."
  guard (prerelease.all (fun part =>
    !part.isEmpty && part.toList.all (fun c => c.isAlphanum || c == '-') &&
      (!part.toList.all Char.isDigit || (versionNat? part).isSome)))
  pure (numbers, prerelease)

private def compareVersionNumbers : List Nat → List Nat → Ordering
  | [], [] => .eq
  | [], _ => .lt
  | _, [] => .gt
  | a :: as, b :: bs => if a == b then compareVersionNumbers as bs else compare a b

private def comparePrerelease : List String → List String → Ordering
  | [], [] => .eq
  | [], _ => .lt
  | _, [] => .gt
  | a :: as, b :: bs =>
      if a == b then comparePrerelease as bs else
      match a.toNat?, b.toNat? with
      | some x, some y => compare x y
      | some _, none => .lt
      | none, some _ => .gt
      | none, none => compare a b

/-- Semver precedence, ignoring build metadata; opaque vendor versions compare
lexicographically. Single numeric versions support recorded file-schema numbers. -/
def compareSourceVersions (observed reviewed : String) : Ordering :=
  match versionParts? observed, versionParts? reviewed with
  | some (a, ap), some (b, bp) =>
      match compareVersionNumbers a b with
      | .eq => if ap.isEmpty && !bp.isEmpty then .gt
        else if !ap.isEmpty && bp.isEmpty then .lt else comparePrerelease ap bp
      | order => order
  | _, _ => compare observed reviewed

def latestSourceVersion (versions : List String) : Option String :=
  (versions.filter (fun value => !value.isEmpty)).foldl (fun best value =>
    match best with
    | none => some value
    | some previous => if compareSourceVersions value previous == .gt then some value else best) none

def sourceVersionBeyondReviewed (format : Format) (observed : String) : Bool :=
  (reviewedSourceVersion format).any (fun reviewed =>
    compareSourceVersions observed reviewed == .gt)

def codexVersionBeyondReviewed (observed : String) : Bool :=
  sourceVersionBeyondReviewed .codexCli observed

private def sourceReviewName : Format → String
  | .codexCli => "Codex"
  | .claudeCode => "Claude Code"
  | .cursorAgent => "Cursor Agent"
  | .pi => "Pi schema"
  | .openCode => "OpenCode"
  | .cursorIde => "Cursor IDE"
  | .hermes => "Hermes"
  | .googleAiStudio => "Google AI Studio"
  | .other name => name

/-- Importers pass the version on the physical source record, never a restored
foreign source environment or a target-version override. Emit at most one note
per import and retain machine-readable evidence beside the original extras. -/
def reviewSourceVersion (format : Format) (observed : Option String)
    (transcript : Transcript) : Transcript :=
  match observed, reviewedSourceVersion format with
  | some observed, some reviewed =>
      if compareSourceVersions observed reviewed != .gt then transcript else
      let evidence := Json.mkObj [("observed", Json.str observed), ("reviewed", Json.str reviewed)]
      let extras := match transcript.origin.extras with
        | some (Json.obj fields) => Json.obj (fields.insert "source_version_beyond_reviewed" evidence)
        | _ => Json.mkObj [("source_version_beyond_reviewed", evidence)]
      { transcript with
        importNotes := transcript.importNotes ++ [{
          kind := .other "source-version-beyond-reviewed"
          detail := s!"{sourceReviewName format} {observed} is newer than the newest reviewed source schema ({reviewed}); check import notes for unconsumed content" }]
        origin := { transcript.origin with extras := some extras } }
  | _, _ => transcript

example : codexVersionBeyondReviewed "0.163.0" = true := by native_decide
example : codexVersionBeyondReviewed "0.162.1" = false := by native_decide
example : codexVersionBeyondReviewed "0.153.0" = false := by native_decide
example : compareSourceVersions "0.100.0" "0.99.0" = .gt := by native_decide
example : compareSourceVersions "1.0.0-rc.10" "1.0.0-rc.2" = .gt := by native_decide
example : compareSourceVersions "1.0.0-rc.1" "1.0.0" = .lt := by native_decide
example : compareSourceVersions "1.0.0+new" "1.0.0+old" = .eq := by native_decide
example : compareSourceVersions "vendor-z" "vendor-a" = .gt := by native_decide

end LoomConvert
