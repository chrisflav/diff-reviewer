import DiffReviewer.Types
import DiffReviewer.Http
import Lean.Data.Json

open Lean (Json)

/-!
# GitHub

What the platform needs of GitHub's REST API: the open pull requests of a repository (discovery),
one pull request's title, body, base and head, its diff, and posting a review.

`Client` is a record of functions rather than a module of them, so that the workers and the
server can be run against a fake in the suite; `Client.curl` is the real one. It sends
`Authorization: Bearer <token>` with the token read from `DIFF_REVIEWER_GITHUB_TOKEN_FILE`. In
production the process runs with `HTTPS_PROXY` pointing at kleis and the token is the placeholder
`kleis`, which kleis swaps for the operator's own: the platform never holds a real GitHub
credential.
-/

namespace DiffReviewer.GitHub

/-- What the platform keeps of a pull request. -/
structure Pull where
  number  : Nat
  title   : String
  body    : String
  headSha : String
  baseSha : String
  /-- A GitHub draft pull request: not ready for review. -/
  draft   : Bool := false
  deriving Repr, BEq

def Pull.ofJson (j : Json) : Except String Pull := do
  let number ← j.getObjValAs? Nat "number"
  let title ← j.getObjValAs? String "title"
  -- A pull request without a description has `"body": null`.
  let body := (j.getObjValAs? String "body").toOption.getD ""
  let headSha ← (← j.getObjVal? "head").getObjValAs? String "sha"
  let baseSha ← (← j.getObjVal? "base").getObjValAs? String "sha"
  let draft := (j.getObjValAs? Bool "draft").toOption.getD false
  return { number, title, body, headSha := headSha.toLower, baseSha := baseSha.toLower, draft }

/-- GitHub's name for a decision, as a review's `event`. -/
def Decision.toEvent : Decision → String
  | .comment        => "COMMENT"
  | .approve        => "APPROVE"
  | .requestChanges => "REQUEST_CHANGES"

/-- The body of `POST /repos/{owner}/{repo}/pulls/{number}/reviews`. Every comment is on the
    right-hand (new) side, at `line` with `start_line` for a range. Without `event` GitHub keeps the
    review pending — a draft only its author sees; with one it is submitted. `commitId` pins the
    review to the commit it was written against, so that its line numbers mean what they meant. -/
def reviewRequestBody (r : Review) (commitId : Option String) (pending : Bool) : Json :=
  let comments : List Json := r.comments.map fun c =>
    let body := match c.suggestion with
      | none   => c.body
      | some s => c.body ++ "\n\n```suggestion\n" ++ s ++ "\n```"
    let fields : List (String × Json) :=
      [("path", c.file), ("line", c.range.endLine), ("side", "RIGHT"), ("body", body)]
    let fields := if c.range.startLine < c.range.endLine then
        fields ++ [("start_line", (c.range.startLine : Json)), ("start_side", "RIGHT")]
      else fields
    .mkObj fields
  let fields : List (String × Json) := [("body", r.body), ("comments", .arr comments.toArray)]
  let fields := match commitId with
    | some sha => fields ++ [("commit_id", (sha : Json))]
    | none => fields
  .mkObj (if pending then fields else fields ++ [("event", (Decision.toEvent r.decision : Json))])

/-- What the platform does on GitHub. Every operation answers an error message rather than
    throwing: GitHub being unreachable is a state a worker records and retries, not a crash. -/
structure Client where
  /-- The open pull requests of `owner/name`. -/
  listOpenPulls : (owner name : String) → IO (Except String (Array Pull))
  getPull : (owner name : String) → (number : Nat) → IO (Except String Pull)
  /-- The unified diff a pull request with base `base` shows at head `head`: from their merge base
      to `head`, which is what GitHub's own diff of the pull request is. -/
  diff : (owner name base head : String) → IO (Except String String)
  /-- Post a review; answers the URL of the posted review. -/
  postReview : (owner name : String) → (number : Nat) → (review : Review) →
    (commitId : Option String) → (pending : Bool) → IO (Except String String)

/-- The API's root, `https://api.github.com` unless `DIFF_REVIEWER_GITHUB_API` names another. -/
def defaultApi : IO String := do
  let api := (← IO.getEnv "DIFF_REVIEWER_GITHUB_API").getD "https://api.github.com"
  return (api.dropEndWhile (· == '/')).toString

private def errorOf (r : Http.Response) : String :=
  let msg := ((Json.parse r.body).toOption.bind (·.getObjValAs? String "message" |>.toOption))
  s!"GitHub answered {r.status}{(msg.map (": " ++ ·)).getD ""}"

/-- The client that talks to `api` with `token`, through curl. -/
def Client.curl (token : String) (api : String) : Client :=
  let call (method path : String) (accept := "application/vnd.github+json")
      (body : Option Json := none) : IO (Except String Http.Response) := do
    let headers := [("Authorization", s!"Bearer {token}"), ("Accept", accept),
                    ("X-GitHub-Api-Version", "2022-11-28"), ("User-Agent", "diff-reviewer")] ++
      (if body.isSome then [("Content-Type", "application/json")] else [])
    match ← Http.send { method, url := api ++ path, headers, body := body.map (·.compress) } with
    | .error e => return .error e
    | .ok r => return if 200 ≤ r.status && r.status < 300 then .ok r else .error (errorOf r)
  let json (r : Http.Response) : Except String Json :=
    (Json.parse r.body).mapError (s!"GitHub's answer is not JSON: " ++ ·)
  { listOpenPulls := fun owner name => do
      -- One page of 100: discovery is for repositories with a reviewable number of open pull
      -- requests, and the newest are first.
      match ← call "GET" s!"/repos/{owner}/{name}/pulls?state=open&per_page=100" with
      | .error e => return .error e
      | .ok r => return do
        let arr ← (← json r).getArr?
        arr.mapM Pull.ofJson
    getPull := fun owner name number => do
      match ← call "GET" s!"/repos/{owner}/{name}/pulls/{number}" with
      | .error e => return .error e
      | .ok r => return (json r).bind Pull.ofJson
    diff := fun owner name base head => do
      -- The three-dot compare is the merge-base diff, and unlike the pull request's own diff
      -- endpoint it is of the commits named rather than of whatever the head is by now.
      match ← call "GET" s!"/repos/{owner}/{name}/compare/{base}...{head}"
          (accept := "application/vnd.github.diff") with
      | .error e => return .error e
      | .ok r => return .ok r.body
    postReview := fun owner name number review commitId pending => do
      match ← call "POST" s!"/repos/{owner}/{name}/pulls/{number}/reviews"
          (body := some (reviewRequestBody review commitId pending)) with
      | .error e => return .error e
      | .ok r =>
        let url := (json r).toOption.bind (·.getObjValAs? String "html_url" |>.toOption)
        return .ok (url.getD "") }

/-- The client configured by the environment: the token in `DIFF_REVIEWER_GITHUB_TOKEN_FILE`, or
    `none` when it is unset. -/
def Client.fromEnv : IO (Option Client) := do
  let some path ← IO.getEnv "DIFF_REVIEWER_GITHUB_TOKEN_FILE" | return none
  return some (Client.curl (← Http.readTokenFile path) (← defaultApi))

end DiffReviewer.GitHub