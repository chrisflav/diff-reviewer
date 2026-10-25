import DiffReviewerTest

def main : IO UInt32 := do
  let ok ← DiffReviewerTest.run (DiffReviewerTest.Platform.all ++ DiffReviewerTest.Server.all ++
    DiffReviewerTest.Workers.all)
  return if ok then 0 else 1