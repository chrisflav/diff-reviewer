import DiffReviewer

open DiffReviewer

private def usage : String :=
"diff-reviewer — code review tool

USAGE:
  diff-reviewer github   <owner/repo> <pr-number> <review.json> [--submit]
      Submit the review to a GitHub pull request via the gh CLI.
      Requires gh to be authenticated (gh auth login).
      By default the review is saved as a pending (draft) review.
      Pass --submit to publish it immediately.

  diff-reviewer from-git <git-range>
      Parse commits in <git-range> (e.g. main..HEAD) and print a
      Review JSON to stdout.
"

private def cmdGitHub (repo : String) (prStr : String) (jsonPath : String)
    (pending : Bool) : IO Unit := do
  let prNumber := prStr.toNat?.getD 0
  if prNumber == 0 then
    IO.eprintln s!"error: invalid PR number '{prStr}'"
    IO.Process.exit 1
  let contents ← IO.FS.readFile jsonPath
  match Review.ofJsonString contents with
  | .error e =>
    IO.eprintln s!"error: could not parse review from {jsonPath}: {e}"
    IO.Process.exit 1
  | .ok review =>
    match ← submitReview repo prNumber review pending with
    | .ok ()   =>
      IO.println (if pending then "Review saved as pending." else "Review submitted successfully.")
    | .error e =>
      IO.eprintln s!"error: {e}"
      IO.Process.exit 1

private def cmdFromGit (range : String) : IO Unit := do
  match ← reviewFromGit range with
  | .error e =>
    IO.eprintln s!"error: {e}"
    IO.Process.exit 1
  | .ok review =>
    IO.println review.toJsonString

def main (args : List String) : IO Unit := do
  match args with
  | ["github", repo, prNumber, jsonPath]             => cmdGitHub repo prNumber jsonPath true
  | ["github", repo, prNumber, jsonPath, "--submit"] => cmdGitHub repo prNumber jsonPath false
  | ["from-git", range]                  => cmdFromGit range
  | _ =>
    IO.print usage
    IO.Process.exit 1
