import DiffReviewer.Types
import DiffReviewer.Http
import Lean.Data.Json

open Lean (Json)

/-!
# GitHub

What the platform needs of GitHub's REST API: the open pull requests of a repository (discovery),
one pull request's title, body, base and head, its diff, and posting a review; and for
calibration, the recent closed pull requests, their reviews and inline review comments, and the
merge base a commit of one had. Of the rubrics repository (`DiffReviewer.Rubrics`): its branch's
head, commits, trees and blobs, the commits that change a directory, and — for a rubric proposal
only — a tree, a commit, a branch and a pull request of its own, and reading that pull request.
Every path is under `/repos/{owner}/{name}/`, which is what kleis's `diff-reviewer-poster` grant
allows.

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
  /-- Whether a closed pull request was merged, and the commit its merge made: a rubric proposal
      follows its pull request by them. -/
  merged  : Bool := false
  mergeCommitSha : Option String := none
  /-- The pull request on github.com. -/
  htmlUrl : String := ""
  /-- The repository its head branch is of, `owner/name`, in lower case. -/
  headRepo : String := ""
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
  -- A listing has no `merged`, but has `merged_at`.
  let merged := (j.getObjValAs? Bool "merged").toOption.getD false ||
    (j.getObjValAs? String "merged_at").toOption.isSome
  let mergeCommitSha := (j.getObjValAs? String "merge_commit_sha").toOption.map String.toLower
  let htmlUrl := (j.getObjValAs? String "html_url").toOption.getD ""
  let headRepo := (((j.getObjVal? "head").bind (·.getObjVal? "repo")).bind
    (·.getObjValAs? String "full_name")).toOption.getD ""
  return { number, title, body, headSha := headSha.toLower, baseSha := baseSha.toLower, draft
         , author, state, merged, mergeCommitSha, htmlUrl, headRepo := headRepo.toLower }

/-- A commit, as the git data API gives it (`GET /repos/{o}/{n}/git/commits/{sha}`) — or as a
    listing of commits does (`GET /repos/{o}/{n}/commits`), which nests it. -/
structure GitCommit where
  sha     : String
  tree    : String := ""
  parents : Array String := #[]
  message : String := ""
  authorName : String := ""
  /-- The GitHub login of the author, when GitHub knows one (listings only). -/
  authorLogin : Option String := none
  /-- When it was authored, RFC 3339. -/
  date    : String := ""
  deriving Repr, BEq, Inhabited

def GitCommit.ofJson (j : Json) : Except String GitCommit := do
  let sha ← j.getObjValAs? String "sha"
  -- A listing nests the commit under `commit`; the git data API gives it bare.
  let c := (j.getObjVal? "commit").toOption.getD j
  let tree := ((c.getObjVal? "tree").bind (·.getObjValAs? String "sha")).toOption.getD ""
  let parents := match j.getObjVal? "parents" >>= (·.getArr?) with
    | .ok ps => ps.filterMap fun p => (p.getObjValAs? String "sha").toOption.map String.toLower
    | .error _ => #[]
  let author := (c.getObjVal? "author").toOption.getD .null
  let login := ((j.getObjVal? "author").bind (·.getObjValAs? String "login")).toOption
  return { sha := sha.toLower, tree := tree.toLower, parents
         , message := (c.getObjValAs? String "message").toOption.getD ""
         , authorName := (author.getObjValAs? String "name").toOption.getD ""
         , authorLogin := login, date := (author.getObjValAs? String "date").toOption.getD "" }

/-- One entry of a git tree: its path (within the tree read), `blob` or `tree`, and its object. -/
structure TreeEntry where
  path : String
  type : String
  sha  : String
  deriving Repr, BEq, Inhabited

def TreeEntry.ofJson (j : Json) : Except String TreeEntry := do
  return { path := ← j.getObjValAs? String "path", type := ← j.getObjValAs? String "type"
         , sha := (← j.getObjValAs? String "sha").toLower }

/-- One change of a tree written on top of another (`POST /repos/{o}/{n}/git/trees` with
    `base_tree`): the file at `path` with `content`, or, `none`, the file removed. -/
structure TreeChange where
  path    : String
  content : Option String
  deriving Repr, BEq

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
  /-- The commit the review was written against; empty when GitHub did not say. -/
  commitId : String := ""
  /-- When it was submitted; `none` for a pending review. -/
  submittedAt : Option String := none
  deriving Repr, BEq

def PostedReview.ofJson (j : Json) : Except String PostedReview := do
  let id ← j.getObjValAs? Nat "id"
  let body := (j.getObjValAs? String "body").toOption.getD ""
  let url := (j.getObjValAs? String "html_url").toOption.getD ""
  let author := ((j.getObjVal? "user").bind (·.getObjValAs? String "login")).toOption.getD ""
  let state := (j.getObjValAs? String "state").toOption.getD ""
  let commitId := ((j.getObjValAs? String "commit_id").toOption.getD "").toLower
  let submittedAt := (j.getObjValAs? String "submitted_at").toOption
  return { id, body, url, author, state, commitId, submittedAt }

/-- The decision a review GitHub holds is, by its `state`, when that is one. -/
def PostedReview.decision? (r : PostedReview) : Option Decision :=
  match r.state with
  | "APPROVED" => some .approve
  | "CHANGES_REQUESTED" => some .requestChanges
  | "COMMENTED" => some .comment
  | _ => none

def PostedReview.toJson (r : PostedReview) : Json :=
  .mkObj [("id", r.id), ("url", r.url), ("body", r.body)]

/-- An inline comment of a review, as `GET /repos/{o}/{n}/pulls/{pr}/comments` gives it. The
    `original*` fields place it on the commit it was written against (`originalCommitId`); the
    others on the pull request's head now, and are `none` once the code it was on has changed —
    GitHub's "outdated". -/
structure ReviewComment where
  id : Nat
  /-- The review it belongs to. -/
  reviewId : Option Nat := none
  path : String
  body : String := ""
  /-- `RIGHT` (the new side) or `LEFT` (the old); `none` for a comment on the whole file. -/
  side : Option String := none
  startSide : Option String := none
  originalLine : Option Nat := none
  originalStartLine : Option Nat := none
  originalCommitId : String := ""
  /-- The comment it answers, when it is a reply in a thread. -/
  inReplyTo : Option Nat := none
  deriving Repr, BEq

def ReviewComment.ofJson (j : Json) : Except String ReviewComment := do
  let id ← j.getObjValAs? Nat "id"
  let path ← j.getObjValAs? String "path"
  let nat? (k : String) : Option Nat := (j.getObjValAs? Nat k).toOption
  let str? (k : String) : Option String := (j.getObjValAs? String k).toOption
  return { id, path, reviewId := nat? "pull_request_review_id", body := (str? "body").getD ""
         , side := str? "side", startSide := str? "start_side"
         , originalLine := nat? "original_line", originalStartLine := nat? "original_start_line"
         , originalCommitId := ((str? "original_commit_id").getD "").toLower
         , inReplyTo := nat? "in_reply_to_id" }
/-- What GitHub says of two commits, `base...head`: how `head` stands to `base` — `ahead` when
    `base` is an ancestor of `head`, otherwise `behind`, `diverged` or `identical` — and the commits
    from their merge base to `head`, each its id and message. -/
structure Comparison where
  status  : String
  commits : Array (String × String) := #[]
  /-- How many commits there are in all (`total_commits`): a page holds 100 at most. -/
  totalCommits : Nat := commits.size
  deriving Repr, BEq

def Comparison.ofJson (j : Json) : Except String Comparison := do
  let status ← j.getObjValAs? String "status"
  let total := (j.getObjValAs? Nat "total_commits").toOption
  let commits := match j.getObjVal? "commits" >>= (·.getArr?) with
    | .ok xs => xs.filterMap fun c =>
      match c.getObjValAs? String "sha" with
      | .ok sha =>
        let msg := ((c.getObjVal? "commit").bind (·.getObjValAs? String "message")).toOption
        some (sha.toLower, msg.getD "")
      | .error _ => none
    | .error _ => #[]
  return { status, commits, totalCommits := total.getD commits.size }

/-- The path of page `page` of the comparison of `base` and `head` in `owner/name`, 100 commits
    a page: what `Client.curl`'s `compare` reads, for `compareNewest`. -/
def comparePagePath (owner name base head : String) (page : Nat) : String :=
  s!"/repos/{owner}/{name}/compare/{base}...{head}?per_page=100&page={page}"

/-- The comparison of two commits with its newest `keep` commits (at most 100), from `fetch`,
    which answers page `n` of the comparison as GitHub does: 100 commits a page, oldest first, and
    `total_commits` in all. The first page says how many there are; the newest are on the last
    page and, when that one is short, the page before it. -/
def compareNewest (fetch : Nat → IO (Except Error Comparison)) (keep : Nat := 100) :
    IO (Except Error Comparison) := do
  let first ← match ← fetch 1 with
    | .ok c => pure c
    | .error e => return .error e
  let total := first.totalCommits
  if total ≤ 100 then
    return .ok { first with commits := first.commits.extract (first.commits.size - keep) }
  let last := (total + 99) / 100
  let lastPage ← match ← fetch last with
    | .ok c => pure c.commits
    | .error e => return .error e
  let before ← if lastPage.size ≥ keep then pure #[]
    else if last == 2 then pure first.commits
    else match ← fetch (last - 1) with
      | .ok c => pure c.commits
      | .error e => return .error e
  let all := before ++ lastPage
  return .ok { first with commits := all.extract (all.size - keep) }

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
  /-- GitHub refused for its rate limit (a `429`, or a `403` that says so): nothing was done, and
      asking again before the limit resets is refused too. -/
  | rateLimited (why : String)
  deriving Repr, BEq

def Error.message : Error → String
  | .definite why | .indefinite why | .rateLimited why => why
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

/-- What GitHub last said of the token's rate limit: the requests left, and when the window
    resets (epoch seconds). -/
structure RateLimit where
  remaining : Nat
  resetAt   : Int
  deriving Repr, BEq

/-- The rate limit an answer's `X-RateLimit-Remaining` and `X-RateLimit-Reset` give, if both are
    there. -/
def RateLimit.ofResponse? (r : Http.Response) : Option RateLimit := do
  let remaining ← (← r.header? "x-ratelimit-remaining").toNat?
  let resetAt ← (← r.header? "x-ratelimit-reset").toNat?
  return { remaining, resetAt := resetAt }

/-- The rate limit the curl client last saw. One per process: the platform holds one GitHub
    token, and every request with it draws on one budget. -/
initialize lastRateLimit : IO.Ref (Option RateLimit) ← IO.mkRef none

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
  /-- The most recently updated closed pull requests of `owner/name`, at most `limit`. -/
  listClosedPulls : (owner name : String) → (limit : Nat) → IO (Except Error (Array Pull)) :=
    fun _ _ _ => return .error (.definite "listing closed pull requests is not supported")
  /-- The inline review comments on a pull request, every page of them. -/
  listReviewComments : (owner name : String) → (number : Nat) →
      IO (Except Error (Array ReviewComment)) :=
    fun _ _ _ => return .error (.definite "listing review comments is not supported")
  /-- The merge base of `base` and `head`: the base a pull request whose base is `base` had at
      `head`. -/
  mergeBase : (owner name base head : String) → IO (Except Error String) :=
    fun _ _ _ _ => return .error (.definite "comparing commits is not supported")
  /-- How `head` stands to `base`, and the newest 100 commits between (`compareNewest`): whether
      a pull request's new head descends from the head reviewed last. -/
  compare : (owner name base head : String) → IO (Except Error Comparison) :=
    fun _ _ _ _ => return .error (.definite "comparing commits is not supported")
  /-- What GitHub last said of the rate limit, if it has said anything. -/
  rateLimit : IO (Option RateLimit) := pure none
  /-- The commit branch `branch` of `owner/name` is at; `none` when the repository has no such
      branch, an empty repository among them. A repository not found — or one the token cannot
      read, which GitHub answers the same — is an error, never `none`. -/
  branchHead : (owner name branch : String) → IO (Except Error (Option String)) :=
    fun _ _ _ => return .error (.definite "reading branches is not supported")
  getCommit : (owner name sha : String) → IO (Except Error GitCommit) :=
    fun _ _ _ => return .error (.definite "reading commits is not supported")
  /-- The entries of tree `sha`; with `recursive`, of every tree below it too, by their paths
      from it. -/
  getTree : (owner name sha : String) → (recursive : Bool) → IO (Except Error (Array TreeEntry)) :=
    fun _ _ _ _ => return .error (.definite "reading trees is not supported")
  /-- The contents of blob `sha`, as text. -/
  getBlob : (owner name sha : String) → IO (Except Error String) :=
    fun _ _ _ => return .error (.definite "reading blobs is not supported")
  /-- The newest commits of `branch` that change `path`, at most `limit`, newest first. -/
  listCommits : (owner name branch path : String) → (limit : Nat) →
      IO (Except Error (Array GitCommit)) :=
    fun _ _ _ _ _ => return .error (.definite "listing commits is not supported")
  /-- A tree of `changes` over tree `baseTree`: its sha. -/
  createTree : (owner name baseTree : String) → (changes : Array TreeChange) →
      IO (Except Error String) :=
    fun _ _ _ _ => return .error (.definite "writing trees is not supported")
  /-- A commit of `tree` on `parents` with `message`: its sha. -/
  createCommit : (owner name message tree : String) → (parents : Array String) →
      IO (Except Error String) :=
    fun _ _ _ _ _ => return .error (.definite "writing commits is not supported")
  /-- Branch `branch` at `sha`, made. -/
  createBranch : (owner name branch sha : String) → IO (Except Error Unit) :=
    fun _ _ _ _ => return .error (.definite "writing branches is not supported")
  /-- A pull request from `head` (a branch of `owner/name`) into `base`. -/
  createPull : (owner name title head base body : String) → IO (Except Error Pull) :=
    fun _ _ _ _ _ _ => return .error (.definite "opening pull requests is not supported")
  /-- The pull request from branch `head` of `owner/name`, open or closed, if there is one. -/
  findPull : (owner name head : String) → IO (Except Error (Option Pull)) :=
    fun _ _ _ => return .error (.definite "listing pull requests is not supported")

/-- The API's root, `https://api.github.com` unless `DIFF_REVIEWER_GITHUB_API` names another. -/
def defaultApi : IO String := do
  let api := (← IO.getEnv "DIFF_REVIEWER_GITHUB_API").getD "https://api.github.com"
  return (api.dropEndWhile (· == '/')).toString

private def errorOf (r : Http.Response) : String :=
  let msg := ((Json.parse r.body).toOption.bind (·.getObjValAs? String "message" |>.toOption))
  s!"GitHub answered {r.status}{(msg.map (": " ++ ·)).getD ""}"

/-- Whether `r` is GitHub refusing for its rate limit: a `429`, or a `403` whose message says so
    (GitHub answers both, for its primary and its secondary limits). -/
def rateLimited (r : Http.Response) : Bool :=
  r.status == 429 || (r.status == 403 && ((errorOf r).toLower.splitOn "rate limit").length > 1)

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
      if let some l := RateLimit.ofResponse? r then lastRateLimit.set (some l)
      if 200 ≤ r.status && r.status < 300 then return .ok r
      else if rateLimited r then return .error (.rateLimited (errorOf r))
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
        (parse PostedReview.ofJson)
    listClosedPulls := fun owner name limit => do
      let path := s!"/repos/{owner}/{name}/pulls?state=closed&sort=updated&direction=desc&"
      let mut all := #[]
      for page in [1:(limit + 99) / 100 + 1] do
        match (← call "GET" s!"{path}per_page=100&page={page}").bind
            (parse fun j => do (← j.getArr?).mapM Pull.ofJson) with
        | .error e => return .error e
        | .ok xs =>
          all := all ++ xs
          if xs.size < 100 then break
      return .ok (all.extract 0 limit)
    listReviewComments := fun owner name number =>
      pages s!"/repos/{owner}/{name}/pulls/{number}/comments?" ReviewComment.ofJson
    mergeBase := fun owner name base head => do
      return (← call "GET" s!"/repos/{owner}/{name}/compare/{base}...{head}?per_page=1").bind
        (parse fun j => do
          return (← (← j.getObjVal? "merge_base_commit").getObjValAs? String "sha").toLower)
    compare := fun owner name base head =>
      compareNewest fun page => do
        return (← call "GET" (comparePagePath owner name base head page)).bind
          (parse Comparison.ofJson)
    rateLimit := lastRateLimit.get
    branchHead := fun owner name branch => do
      -- An empty repository answers 409, a branch it does not have 404: neither has a head. But a
      -- repository the token cannot see answers 404 too, so a 404 asks after the repository.
      match ← call "GET" s!"/repos/{owner}/{name}/git/ref/heads/{branch}" with
      | .error (.definite why) =>
        if why.startsWith "GitHub answered 409" then return .ok none
        unless why.startsWith "GitHub answered 404" do return .error (.definite why)
        match ← call "GET" s!"/repos/{owner}/{name}" with
        | .ok _ => return .ok none
        | .error (.definite w) =>
          if w.startsWith "GitHub answered 404" then
            return .error (.definite s!"{owner}/{name} was not found, or the token cannot read \
it ({w})")
          return .error (.definite w)
        | .error e => return .error e
      | .error e => return .error e
      | .ok r => return (parse (fun j => do
          return some (← (← j.getObjVal? "object").getObjValAs? String "sha").toLower) r)
    getCommit := fun owner name sha => do
      return (← call "GET" s!"/repos/{owner}/{name}/git/commits/{sha}").bind
        (parse GitCommit.ofJson)
    getTree := fun owner name sha recursive => do
      let q := if recursive then "?recursive=1" else ""
      return (← call "GET" s!"/repos/{owner}/{name}/git/trees/{sha}{q}").bind
        (parse fun j => do
          if (j.getObjValAs? Bool "truncated").toOption == some true then
            throw "the tree is too large for GitHub to list whole"
          (← (← j.getObjVal? "tree").getArr?).mapM TreeEntry.ofJson)
    getBlob := fun owner name sha => do
      return (← call "GET" s!"/repos/{owner}/{name}/git/blobs/{sha}"
        (accept := "application/vnd.github.raw+json")).map (·.body)
    listCommits := fun owner name branch path limit => do
      let per := min limit 100
      let mut all := #[]
      for page in [1:(limit + per - 1) / max per 1 + 1] do
        match (← call "GET" s!"/repos/{owner}/{name}/commits?sha={branch}&path={path}\
&per_page={per}&page={page}").bind (parse fun j => do (← j.getArr?).mapM GitCommit.ofJson) with
        | .error e => return .error e
        | .ok xs =>
          all := all ++ xs
          if xs.size < per then break
      return .ok (all.extract 0 limit)
    createTree := fun owner name baseTree changes => do
      let entries := changes.map fun c =>
        Json.mkObj [("path", c.path), ("mode", "100644"), ("type", "blob"),
          match c.content with
          | some t => ("content", (t : Json))
          | none => ("sha", Json.null)]
      return (← call "POST" s!"/repos/{owner}/{name}/git/trees"
          (body := some (.mkObj [("base_tree", baseTree), ("tree", .arr entries)]))).bind
        (parse fun j => return (← j.getObjValAs? String "sha").toLower)
    createCommit := fun owner name message tree parents => do
      return (← call "POST" s!"/repos/{owner}/{name}/git/commits"
          (body := some (.mkObj [("message", message), ("tree", tree),
                                 ("parents", .arr (parents.map Json.str))]))).bind
        (parse fun j => return (← j.getObjValAs? String "sha").toLower)
    createBranch := fun owner name branch sha => do
      return (← call "POST" s!"/repos/{owner}/{name}/git/refs"
          (body := some (.mkObj [("ref", s!"refs/heads/{branch}"), ("sha", sha)]))).map
        fun _ => ()
    createPull := fun owner name title head base body => do
      return (← call "POST" s!"/repos/{owner}/{name}/pulls"
          (body := some (.mkObj [("title", title), ("head", head), ("base", base),
                                 ("body", body)]))).bind
        (parse Pull.ofJson)
    findPull := fun owner name head => do
      return (← call "GET" s!"/repos/{owner}/{name}/pulls?head={owner}:{head}&state=all").bind
        (parse fun j => do return (← (← j.getArr?).mapM Pull.ofJson)[0]?) }

/-- The client configured by the environment: the token in `DIFF_REVIEWER_GITHUB_TOKEN_FILE`, or
    `none` when it is unset. -/
def Client.fromEnv (maxDiffBytes : Nat := defaultMaxDiffBytes) : IO (Option Client) := do
  let some path ← IO.getEnv "DIFF_REVIEWER_GITHUB_TOKEN_FILE" | return none
  return some (Client.curl (← Http.readTokenFile path) (← defaultApi) maxDiffBytes)

end DiffReviewer.GitHub