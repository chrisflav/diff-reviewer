import DiffReviewer.Store

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

/-- Run `act` against a fresh database under `.lake/test/`, so a test never touches a real one. -/
def withTempDb (act : IO α) : IO α := do
  let dir : System.FilePath := ".lake" / "test"
  IO.FS.createDirAll dir
  let path := dir / s!"test-{← IO.monoNanosNow}.db"
  DiffReviewer.Store.setPath path
  try act finally
    for p in [path, ⟨path.toString ++ "-wal"⟩, ⟨path.toString ++ "-shm"⟩] do
      try IO.FS.removeFile p catch _ => pure ()

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