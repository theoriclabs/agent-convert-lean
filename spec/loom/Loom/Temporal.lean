import Std.Time
import Loom.Core

/-!
# Loom timestamp codecs

Harnesses persist RFC 3339/ISO-8601 UTC strings while the IR records Unix epoch
milliseconds. These total helpers keep that conversion in the Lean semantic
core. Parsing is deliberately conservative: seconds-only and exactly
millisecond-precision `Z` timestamps are lifted to `Time.recorded`; other source
spellings remain available through `Origin.extras` without inventing precision.
-/

namespace Loom

private def padNat (width value : Nat) : String :=
  let rendered := toString value
  String.ofList (List.replicate (width - rendered.length) '0') ++ rendered

/-- Render a non-negative Unix epoch millisecond value as UTC with an explicit
three-digit millisecond component. -/
def epochMsToIso8601 (value : Timestamp) : String :=
  let stamp := Std.Time.Timestamp.ofMillisecondsSinceUnixEpoch
    (Std.Time.Millisecond.Offset.ofNat value.ms)
  let utc := Std.Time.DateTime.ofTimestamp stamp .GMT
  let wholeSeconds := Std.Time.DateTime.toISO8601String utc
  let utcPrefix := if wholeSeconds.endsWith "Z" then
      (wholeSeconds.dropEnd 1).toString
    else wholeSeconds
  utcPrefix ++ "." ++ padNat 3 (value.ms % 1000) ++ "Z"

private def wholeSecondEpochMs? (value : String) : Option Nat := do
  let parsed ← (Std.Time.ZonedDateTime.fromISO8601String value).toOption
  let milliseconds := parsed.timestamp.toMillisecondsSinceUnixEpoch.val
  guard (milliseconds ≥ 0)
  pure milliseconds.toNat

/-- Parse the UTC forms emitted by supported harnesses when their precision is
exactly representable by `Timestamp`: `YYYY-MM-DDTHH:mm:ssZ` or the same form with
exactly three fractional digits. -/
def iso8601ToEpochMs? (value : String) : Option Timestamp := do
  guard (value.endsWith "Z")
  let body := (value.dropEnd 1).toString
  match body.splitOn "." with
  | [whole] =>
      pure ⟨← wholeSecondEpochMs? (whole ++ "Z")⟩
  | [whole, fraction] =>
      guard (fraction.length == 3)
      guard (fraction.toList.all Char.isDigit)
      let fractionMs ← fraction.toNat?
      pure ⟨(← wholeSecondEpochMs? (whole ++ "Z")) + fractionMs⟩
  | _ => none

def recordedTimeIso8601? : Time → Option String
  | .recorded value => some (epochMsToIso8601 value)
  | _ => none

def recordedTimeFromIso8601 (value : String) : Time :=
  match iso8601ToEpochMs? value with
  | some epoch => .recorded epoch
  | none => .absent

example : epochMsToIso8601 ⟨0⟩ = "1970-01-01T00:00:00.000Z" := by native_decide
example : epochMsToIso8601 ⟨1720000000001⟩ = "2024-07-03T09:46:40.001Z" := by native_decide
example : iso8601ToEpochMs? "2024-07-03T09:46:40.001Z" = some ⟨1720000000001⟩ := by
  native_decide
example : iso8601ToEpochMs? "2024-07-03T09:46:40.000001Z" = none := by native_decide

end Loom
