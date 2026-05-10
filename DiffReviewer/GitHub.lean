import DiffReviewer.Types
import Lean.Data.Json

namespace DiffReviewer

private def runProcess (cmd : String) (args : Array String) : IO (Except String String) := do
  let result ← IO.Process.output { cmd, args }
  if result.exitCode == 0 then
    return .ok result.stdout
  else
    return .error (if result.stderr.isEmpty then result.stdout else result.stderr)

private def Decision.toGitHubEvent : Decision → String
  | .comment        => "COMMENT"
  | .approve        => "APPROVE"
  | .requestChanges => "REQUEST_CHANGES"

-- Build the JSON body for POST /repos/{owner}/{repo}/pulls/{pull_number}/reviews.
private def buildRequestBody (r : Review) : String :=
  let event := r.decision.toGitHubEvent
  let comments : List Lean.Json := r.comments.map fun c =>
    let suggBody := match c.suggestion with
      | none   => c.body
      | some s => c.body ++ "\n\n```suggestion\n" ++ s ++ "\n```"
    let fields : List (String × Lean.Json) := [
      ("path", c.file),
      ("line", c.range.endLine),
      ("body", suggBody)
    ]
    let fields :=
      if c.range.startLine < c.range.endLine then
        fields ++ [("start_line", (c.range.startLine : Lean.Json))]
      else fields
    .mkObj fields
  let body : Lean.Json := .mkObj [
    ("body",     r.body),
    ("event",    event),
    ("comments", .arr comments.toArray)
  ]
  body.pretty

/-- Submit `review` to the given GitHub pull request using the `gh` CLI.
    `repo` should be in the form "owner/repo". -/
def submitReview (repo : String) (prNumber : Nat) (review : Review) : IO (Except String Unit) := do
  let body := buildRequestBody review
  let tmpPath := s!"/tmp/diff-reviewer-review-{prNumber}.json"
  IO.FS.writeFile tmpPath body
  let result ← runProcess "gh" #["api",
    "--method", "POST",
    "-H", "Accept: application/vnd.github+json",
    s!"/repos/{repo}/pulls/{prNumber}/reviews",
    "--input", tmpPath]
  IO.FS.removeFile tmpPath |>.catchExceptions (fun _ => pure ())
  match result with
  | .ok _    => return .ok ()
  | .error e => return .error e

end DiffReviewer
