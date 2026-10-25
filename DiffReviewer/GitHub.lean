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
  /-- The login of the pull request's author. -/
  author  : String := ""
  /-- `open` or `closed`. -/
  state   : String := "open"
  deriving Repr, BEq

def Pull.ofJson (j : Json) : Except String Pull := do
  let number ← j.getObjValAs? Nat "number"
  let title ← j.getObjValAs? String "title"
  -- A pull request without a description has `"body": null`.
  let body := (j.getObjValAs? String "body").toOption.getD ""
  let headSha ← (← j.getObjVal? "head").getObjValAs? String "sha"
  let baseSha ← (← j.getObjVal? "base").getObjValAs? String "sha"
  let draft := (j.getObjValAs? Bool "draft").toOption.getD false
  let author := ((j.getObjVal? "user").bind (·.getObjValAs? String "login")).toOption.getD ""
  let state := (j.getObjValAs? String "state").toOption.getD "open"
  return { number, title, body, headSha := headSha.toLower, baseSha := baseSha.toLower, draft
         , author, state }

/-- A review on a pull request, as the platform looks for its own among them. -/
structure PostedReview where
  id     : Nat
  body   : String
  url    : String
  /-- The login of the review's author. -/
  author : String := ""
  /-- What GitHub says the review is: `APPROVED`, `CHANGES_REQUESTED`, `COMMENTED`, … ; empty
      when it did not say. -/
  state  : String := ""
  deriving Repr, BEq

def PostedReview.ofJson (j : Json) : Except String PostedReview := do
  let id ← j.getObjValAs? Nat "id"
  let body := (j.getObjValAs? String "body").toOption.getD ""
  let url := (j.getObjValAs? String "html_url").toOption.getD ""
  let author := ((j.getObjVal? "user").bind (·.getObjValAs? String "login")).toOption.getD ""
  let state := (j.getObjValAs? String "state").toOption.getD ""
  return { id, body, url, author, state }

/-- The decision a review GitHub holds is, by its `state`, when that is one. -/
def PostedReview.decision? (r : PostedReview) : Option Decision :=
  match r.state with
  | "APPROVED" => some .approve
  | "CHANGES_REQUESTED" => some .requestChanges
  | "COMMENTED" => some .comment
  | _ => none

def PostedReview.toJson (r : PostedReview) : Json :=
  .mkObj [("id", r.id), ("url", r.url), ("body", r.body)]

/-- Seconds before a request to GitHub is given up. -/
def requestTimeout : Nat := 60

/-- Why a GitHub request did not do what it was for. The difference between the first two is what
    posting turns on: after a `definite` failure nothing was posted, after an `indefinite` one
    something may have been. -/
inductive Error where
  /-- GitHub answered, and refused (a `4xx`), or the request was never sent. -/
  | definite (why : String)
  /-- No answer, or a `5xx`: the request may or may not have taken effect. -/
  | indefinite (why : String)
  /-- The diff is larger than the platform takes. -/
  | tooLarge (limit : Nat)
  deriving Repr, BEq

def Error.message : Error → String
  | .definite why | .indefinite why => why
  | .tooLarge limit => s!"the diff is larger than {limit} bytes, the most the platform reviews"

/-- GitHub's name for a decision, as a review's `event`. -/
def Decision.toEvent : Decision → String
  | .comment        => "COMMENT"
  | .approve        => "APPROVE"
  | .requestChanges => "REQUEST_CHANGES"

/-- The body of `POST /repos/{owner}/{repo}/pulls/{number}/reviews`. Every comment is on the
    right-hand (new) side, at `line` with `start_line` for a range. Without an `event` GitHub keeps
    the review pending — a draft only its author sees; with one it is submitted as that event, which
    need not be the review's own decision. `commitId` pins the review to the commit it was written
    against, so that its line numbers mean what they meant. -/
def reviewRequestBody (r : Review) (commitId : Option String) (event : Option Decision) : Json :=
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
  .mkObj (match event with
    | none => fields
    | some e => fields ++ [("event", (Decision.toEvent e : Json))])

/-- What the platform does on GitHub. Every operation answers an error rather than throwing:
    GitHub being unreachable is a state a worker records and retries, not a crash. -/
structure Client where
  /-- The open pull requests of `owner/name`, every page of them. -/
  listOpenPulls : (owner name : String) → IO (Except Error (Array Pull))
  getPull : (owner name : String) → (number : Nat) → IO (Except Error Pull)
  /-- The unified diff a pull request with base `base` shows at head `head`: from their merge base
      to `head`, which is what GitHub's own diff of the pull request is. -/
  diff : (owner name base head : String) → IO (Except Error String)
  /-- The reviews on a pull request, every page of them. -/
  listReviews : (owner name : String) → (number : Nat) → IO (Except Error (Array PostedReview))
  /-- Post a review as `event` (`none`: pending), with its body as given. -/
  postReview : (owner name : String) → (number : Nat) → (review : Review) →
    (commitId : Option String) → (event : Option Decision) → IO (Except Error PostedReview)

/-- The API's root, `https://api.github.com` unless `DIFF_REVIEWER_GITHUB_API` names another. -/
def defaultApi : IO String := do
  let api := (← IO.getEnv "DIFF_REVIEWER_GITHUB_API").getD "https://api.github.com"
  return (api.dropEndWhile (· == '/')).toString

private def errorOf (r : Http.Response) : String :=
  let msg := ((Json.parse r.body).toOption.bind (·.getObjValAs? String "message" |>.toOption))
  s!"GitHub answered {r.status}{(msg.map (": " ++ ·)).getD ""}"

/-- The most pages of 100 a listing reads: 1000 open pull requests, or reviews on one. -/
def maxPages : Nat := 10

/-- Every page of a listing of 100 a page, `fetch`ed from page 1 until one is short, at most
    `maxPages`. -/
def collectPages {α : Type} (fetch : Nat → IO (Except Error (Array α))) :
    IO (Except Error (Array α)) := do
  let mut all := #[]
  for page in [1:maxPages + 1] do
    match ← fetch page with
    | .error e => return .error e
    | .ok xs =>
      all := all ++ xs
      if xs.size < 100 then break
  return .ok all

/-- The default for `maxDiffBytes`: 5 MB. -/
def defaultMaxDiffBytes : Nat := 5 * 1024 * 1024

/-- The client that talks to `api` with `token`, through curl, refusing a diff past
    `maxDiffBytes`. -/
def Client.curl (token : String) (api : String) (maxDiffBytes : Nat := defaultMaxDiffBytes) :
    Client :=
  let call (method path : String) (accept := "application/vnd.github+json")
      (body : Option Json := none) (maxBytes : Option Nat := none) :
      IO (Except Error Http.Response) := do
    let headers := [("Authorization", s!"Bearer {token}"), ("Accept", accept),
                    ("X-GitHub-Api-Version", "2022-11-28"), ("User-Agent", "diff-reviewer")] ++
      (if body.isSome then [("Content-Type", "application/json")] else [])
    match ← Http.send { method, url := api ++ path, headers, body := body.map (·.compress)
                      , maxBytes, timeout := requestTimeout } with
    | .error (.refused why) => return .error (.definite why)
    -- 63: curl's "maximum file size exceeded".
    | .error (.noAnswer _ 63) => return .error (.tooLarge maxDiffBytes)
    | .error (.noAnswer why _) => return .error (.indefinite why)
    | .ok r =>
      if 200 ≤ r.status && r.status < 300 then return .ok r
      else if r.status < 500 then return .error (.definite (errorOf r))
      else return .error (.indefinite (errorOf r))
  let parse {α : Type} (f : Json → Except String α) (r : Http.Response) : Except Error α :=
    match Json.parse r.body >>= f with
    | .ok a => .ok a
    | .error e => .error (.indefinite s!"GitHub's answer is not what was expected: {e}")
  let pages {α : Type} (path : String) (f : Json → Except String α) :
      IO (Except Error (Array α)) :=
    collectPages fun page => do
      return (← call "GET" s!"{path}per_page=100&page={page}").bind
        (parse fun j => do (← j.getArr?).mapM f)
  { listOpenPulls := fun owner name =>
      pages s!"/repos/{owner}/{name}/pulls?state=open&" Pull.ofJson
    getPull := fun owner name number => do
      return (← call "GET" s!"/repos/{owner}/{name}/pulls/{number}").bind (parse Pull.ofJson)
    diff := fun owner name base head => do
      -- The three-dot compare is the merge-base diff, and unlike the pull request's own diff
      -- endpoint it is of the commits named rather than of whatever the head is by now.
      match ← call "GET" s!"/repos/{owner}/{name}/compare/{base}...{head}"
          (accept := "application/vnd.github.diff") (maxBytes := some maxDiffBytes) with
      | .error e => return .error e
      | .ok r =>
        -- A chunked answer has no length for curl to refuse up front.
        if r.body.utf8ByteSize > maxDiffBytes then return .error (.tooLarge maxDiffBytes)
        return .ok r.body
    listReviews := fun owner name number =>
      pages s!"/repos/{owner}/{name}/pulls/{number}/reviews?" PostedReview.ofJson
    postReview := fun owner name number review commitId event => do
      return (← call "POST" s!"/repos/{owner}/{name}/pulls/{number}/reviews"
          (body := some (reviewRequestBody review commitId event))).bind
        (parse PostedReview.ofJson) }

/-- The client configured by the environment: the token in `DIFF_REVIEWER_GITHUB_TOKEN_FILE`, or
    `none` when it is unset. -/
def Client.fromEnv (maxDiffBytes : Nat := defaultMaxDiffBytes) : IO (Option Client) := do
  let some path ← IO.getEnv "DIFF_REVIEWER_GITHUB_TOKEN_FILE" | return none
  return some (Client.curl (← Http.readTokenFile path) (← defaultApi) maxDiffBytes)

end DiffReviewer.GitHub