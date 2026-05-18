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
-- When `pending` is true the review is saved as a draft; false submits it immediately.
private def buildRequestBody (r : Review) (pending : Bool) : String :=
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
  -- Omitting `event` creates a pending/draft review; including it submits immediately.
  let baseFields : List (String × Lean.Json) := [
    ("body",     r.body),
    ("comments", .arr comments.toArray)
  ]
  let fields := if pending then baseFields
    else baseFields ++ [("event", (r.decision.toGitHubEvent : Lean.Json))]
  (Lean.Json.mkObj fields).pretty

/-- Submit `review` to the given GitHub pull request using the `gh` CLI.
    `repo` should be in the form "owner/repo".
    When `pending` is true (the default) the review is saved as a draft. -/
def submitReview (repo : String) (prNumber : Nat) (review : Review)
    (pending : Bool := true) : IO (Except String Unit) := do
  let body := buildRequestBody review pending
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
