/-!
# A minimal test harness

A test is an `IO` action answering the failures it found, empty when it passed. `run` runs every
test in `all` and reports, and `TestDriver` exits non-zero when any failed.
-/

namespace DiffReviewerTest

abbrev Test := IO (Array String)

/-- `[msg]` unless `cond`. -/
def check (cond : Bool) (msg : String) : Array String :=
  if cond then #[] else #[msg]

def checkEq [BEq α] [Repr α] (a b : α) (what : String) : Array String :=
  check (a == b) s!"{what}: expected {repr b}, got {repr a}"

/-- Run `tests` and print one line each; answers whether they all passed. -/
def run (tests : List (String × Test)) : IO Bool := do
  let mut failed := 0
  for (name, t) in tests do
    let failures ← try t catch e => pure #[s!"threw: {e}"]
    if failures.isEmpty then
      IO.println s!"  ✓ {name}"
    else
      failed := failed + 1
      IO.println s!"  ✗ {name}"
      for f in failures do IO.println s!"    - {f}"
  IO.println s!"Results: {tests.length - failed} passed, {failed} failed."
  return failed == 0

end DiffReviewerTest