import Lean.Data.Json
import DiffReviewer.Types
import DiffReviewer.Store

open Lean (Json)

/-!
# The platform's records

What the review platform keeps: the repositories it reviews, and one **job** per review of a pull
request. A job moves through `pending → queued → running → draft → approved → posted`; `rejected`
is a draft somebody discarded, `stale` a draft whose pull request has moved on since, and `failed`
a run that ended without a review. The moves a person may make are here (`personCanMove`); the
platform's own — queueing, following the run, the agent's submission, posting — are made by
`DiffReviewer.Workers` and the agent API, each with the check of the state it expects.
-/

namespace DiffReviewer

/-! ## Time and ids -/

/-- Days since 1970-01-01 to a civil date (Howard Hinnant's `civil_from_days`). -/
private def civilOfDays (z : Int) : Int × Nat × Nat :=
  let z := z + 719468
  let era := (if z ≥ 0 then z else z - 146096) / 146097
  let doe := z - era * 146097
  let yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
  let y := yoe + era * 400
  let doy := doe - (365 * yoe + yoe / 4 - yoe / 100)
  let mp := (5 * doy + 2) / 153
  let d := doy - (153 * mp + 2) / 5 + 1
  let m := if mp < 10 then mp + 3 else mp - 9
  ((if m ≤ 2 then y + 1 else y), m.toNat, d.toNat)

private def pad2 (n : Nat) : String := if n < 10 then s!"0{n}" else toString n

/-- An epoch second as RFC 3339 in UTC, `2026-10-24T20:18:25Z`. -/
def isoOfEpoch (t : Int) : String :=
  let days := (if t ≥ 0 then t else t - 86399) / 86400
  let secs := (t - days * 86400).toNat
  let (y, m, d) := civilOfDays days
  s!"{y}-{pad2 m}-{pad2 d}T{pad2 (secs / 3600)}:{pad2 (secs / 60 % 60)}:{pad2 (secs % 60)}Z"

def nowIso : IO String := do
  return isoOfEpoch (← Std.Time.Timestamp.now).toSecondsSinceUnixEpoch.val

private def hexDigit (n : Nat) : Char :=
  "0123456789abcdef".toList[n % 16]!

/-- `n` random bytes, hex-encoded. -/
def randomHex (n : Nat) : IO String := do
  let bytes ← IO.getRandomBytes n.toUSize
  return String.ofList (bytes.toList.flatMap fun b => [hexDigit (b.toNat / 16), hexDigit b.toNat])

/-! ## Repositories -/

/-- Whether a review is posted as soon as the agent submits it, or waits for a person. -/
inductive PostingMode where
  | staged
  | direct
  deriving Repr, BEq, DecidableEq

def PostingMode.toString : PostingMode → String
  | .staged => "staged"
  | .direct => "direct"

def PostingMode.ofString? : String → Option PostingMode
  | "staged" => some .staged
  | "direct" => some .direct
  | _        => none

structure Repo where
  owner      : String
  name       : String
  mode       : PostingMode := .staged
  /-- Whether the platform finds the open pull requests itself and makes a job for each new head,
      rather than reviewing only what it is asked to. -/
  autoReview : Bool := false
  createdAt  : String
  deriving Repr

def Repo.slug (r : Repo) : String := s!"{r.owner}/{r.name}"

def Repo.toJson (r : Repo) : Json :=
  .mkObj [("owner", r.owner), ("name", r.name), ("mode", r.mode.toString),
          ("autoReview", r.autoReview), ("createdAt", r.createdAt)]

private def Repo.ofRow (row : Store.RepoRow) : Repo :=
  { owner := row.owner, name := row.name, createdAt := row.created_at
  , mode := (PostingMode.ofString? row.mode).getD .staged
  , autoReview := row.auto_review.getD false }

/-- Whether `s` can be one half of a GitHub `owner/name`: letters, digits, `-`, `_` and `.`, not
    starting with a dot. Checked because both halves end up in URLs and, later, clone paths. -/
def validSlugPart (s : String) : Bool :=
  !s.isEmpty && s.length ≤ 100 && !s.startsWith "." &&
    s.all fun c => c.isAlphanum || c == '-' || c == '_' || c == '.'

/-! ## Jobs -/

inductive JobStatus where
  | pending | queued | running | draft | approved | posted | rejected | stale | failed
  deriving Repr, BEq, DecidableEq

def JobStatus.all : List JobStatus :=
  [.pending, .queued, .running, .draft, .approved, .posted, .rejected, .stale, .failed]

def JobStatus.toString : JobStatus → String
  | .pending  => "pending"
  | .queued   => "queued"
  | .running  => "running"
  | .draft    => "draft"
  | .approved => "approved"
  | .posted   => "posted"
  | .rejected => "rejected"
  | .stale    => "stale"
  | .failed   => "failed"

def JobStatus.ofString? (s : String) : Option JobStatus :=
  JobStatus.all.find? (·.toString == s)

/-- The moves a person makes on a job from the platform. Everything else — queueing, running, the
    agent's draft, posting to GitHub — is the platform's own doing, and no request can claim it.
    Posting is asked for with its own action (`POST /api/v1/jobs/{id}/post`), which makes the
    `approved → posted` move only once GitHub has the review; `failed → pending` asks for another
    run. -/
def JobStatus.personCanMove : JobStatus → JobStatus → Bool
  | .draft,    .approved => true
  | .draft,    .rejected => true
  | .draft,    .stale    => true
  | .approved, .draft    => true
  | .rejected, .draft    => true
  | .failed,   .pending  => true
  | _,         _         => false

/-- Whether a person may replace the review of a job in this state. Not while the agent may still
    be writing one (`queued`, `running`), and not once it is history (`posted`, `stale`). A
    `pending` job may be reviewed by hand. -/
def JobStatus.personCanEdit : JobStatus → Bool
  | .pending | .draft | .approved | .rejected => true
  | _ => false

/-- One review job.

    The status and the review are kept as the strings the row holds, and parsed when read: a value
    this build does not understand — a status a newer one wrote, a review with a decision it does
    not know — is shown as it is and written back untouched, never replaced by a default. Such a
    job is read-only to this build. -/
structure Job where
  id         : String
  owner      : String
  name       : String
  prNumber   : Nat
  headSha    : Option String := none
  statusRaw  : String := "pending"
  queueEntry : Option String := none
  /-- The review as stored: `Review.toJson`, compressed. -/
  reviewRaw  : Option String := none
  /-- Incremented by every write, so that a client acting on what it last read can be told it was
      not the latest (`409`) instead of overwriting what it never saw. -/
  version    : Nat := 1
  createdAt  : String
  updatedAt  : String
  /-- The pull request's base commit, title and description, from GitHub. -/
  baseSha    : Option String := none
  title      : Option String := none
  prBody     : Option String := none
  /-- What the last platform step on the job failed with, until one succeeds. -/
  error      : Option String := none
  /-- The kind of pull request the agent said it reviewed. -/
  prType     : Option String := none
  /-- How many times the job has been queued on orchestra. -/
  attempts   : Nat := 0
  /-- When posting the review last began, while its outcome is not known. -/
  postStartedAt : Option String := none
  /-- The posted review on GitHub. -/
  postedUrl  : Option String := none
  /-- How the review was posted, when that differs from what it says. -/
  postNote   : Option String := none

def Job.status? (j : Job) : Option JobStatus := JobStatus.ofString? j.statusRaw

/-- The review, `none` when there is none, and an error when the stored one does not parse. -/
def Job.review? (j : Job) : Option (Except String Review) :=
  j.reviewRaw.map Review.ofJsonString

def Job.setReview (j : Job) (r : Review) : Job :=
  { j with reviewRaw := some r.toJson.compress }

private def optStr : Option String → Json
  | some s => .str s
  | none   => .null

def Job.toJson (j : Job) : Json :=
  let (review, reviewError) : Json × Json := match j.review? with
    | none            => (.null, .null)
    | some (.ok r)    => (r.toJson, .null)
    | some (.error e) => (.null, .str e)
  .mkObj [
    ("id", j.id), ("owner", j.owner), ("name", j.name), ("prNumber", j.prNumber),
    ("headSha", optStr j.headSha), ("status", j.statusRaw),
    ("queueEntry", optStr j.queueEntry), ("review", review), ("reviewError", reviewError),
    ("version", j.version), ("createdAt", j.createdAt), ("updatedAt", j.updatedAt),
    ("baseSha", optStr j.baseSha), ("title", optStr j.title), ("prBody", optStr j.prBody),
    ("error", optStr j.error), ("prType", optStr j.prType), ("attempts", j.attempts),
    ("postStartedAt", optStr j.postStartedAt), ("postedUrl", optStr j.postedUrl),
    ("postNote", optStr j.postNote)]

private def Job.ofRow (row : Store.JobRow) : Job :=
  { id := row.id, owner := row.owner, name := row.name, prNumber := row.pr_number.toNat
  , headSha := row.head_sha, statusRaw := row.status, queueEntry := row.queue_entry
  , reviewRaw := row.review, version := row.version.toNat
  , createdAt := row.created_at, updatedAt := row.updated_at
  , baseSha := row.base_sha, title := row.title, prBody := row.pr_body, error := row.error
  , prType := row.pr_type, attempts := (row.attempts.getD 0).toNat
  , postStartedAt := row.post_started_at, postedUrl := row.posted_url, postNote := row.post_note }

private def Job.toRow (j : Job) : Store.JobRow :=
  { id := j.id, owner := j.owner, name := j.name, pr_number := j.prNumber
  , head_sha := j.headSha, status := j.statusRaw, queue_entry := j.queueEntry
  , review := j.reviewRaw, version := j.version
  , created_at := j.createdAt, updated_at := j.updatedAt
  , base_sha := j.baseSha, title := j.title, pr_body := j.prBody, error := j.error
  , pr_type := j.prType, attempts := some j.attempts
  , post_started_at := j.postStartedAt, posted_url := j.postedUrl, post_note := j.postNote }

/-- The largest pull request number accepted: what fits a 32-bit column with room to spare. -/
def maxPrNumber : Nat := 2147483647

/-- Whether `s` is a whole git commit id: 40 hexadecimal digits (SHA-1), or 64 (SHA-256). Never an
    abbreviation: a job's head is what a review is pinned to and compared against, and a prefix is
    neither unique nor what GitHub answers. -/
def validSha (s : String) : Bool :=
  (s.length == 40 || s.length == 64) && s.all fun c => c.isDigit || ('a' ≤ c && c ≤ 'f')

/-! ## The store -/

namespace Platform

open Db.Query.DSL

def listRepos : IO (Array Repo) := do
  let rows ← Store.run <| HasModel.fetch <| query% do
    let r ← from Store.RepoRow
    select r
    order_by r.owner
    order_by r.name
  return rows.map Repo.ofRow

def findRepo (owner name : String) : IO (Option Repo) := do
  let rows ← Store.run <| HasModel.fetch <| query% do
    let r ← from Store.RepoRow
    guard r.owner = owner
    guard r.name = name
    select r
  return rows[0]?.map Repo.ofRow

/-- Create or replace a repository. Answers whether it existed before. Names are stored in lower
    case, as GitHub compares them, so `Acme/Widgets` and `acme/widgets` are one repository. -/
def putRepo (owner name : String) (mode : PostingMode) (autoReview : Bool := false) : IO Bool := do
  let owner := owner.toLower
  let name := name.toLower
  let existing ← findRepo owner name
  let createdAt ← match existing with
    | some r => pure r.createdAt
    | none   => nowIso
  Store.run <| HasModel.save
    ({ owner, name, mode := mode.toString, created_at := createdAt
     , auto_review := some autoReview } : Store.RepoRow)
  return existing.isSome

/-- Delete a repository. Its jobs are kept: they are the record of reviews that happened. -/
def deleteRepo (owner name : String) : IO Bool := do
  let n ← Store.run <| HasModel.delete (α := Store.RepoRow)
    (.and (.eq (.var Store.RepoRowIndex.owner .text) (.text owner.toLower))
          (.eq (.var Store.RepoRowIndex.name .text) (.text name.toLower)))
  return n > 0

def listJobs : IO (Array Job) := do
  let rows ← Store.run <| HasModel.fetch <| query% do
    let j ← from Store.JobRow
    select j
    order_by_desc j.created_at
    order_by_desc j.id
  return rows.map Job.ofRow

private def fetchJob (id : String) : Sqlite.M (Option Job) := do
  let rows ← HasModel.fetch <| query% do
    let j ← from Store.JobRow
    guard j.id = id
    select j
  return rows[0]?.map Job.ofRow

def findJob (id : String) : IO (Option Job) :=
  Store.run (fetchJob id)

/-- A new job for pull request `prNumber` of a registered repository. -/
def createJob (repo : Repo) (prNumber : Nat) (headSha : Option String) : IO Job := do
  let now ← nowIso
  let job : Job :=
    { id := ← randomHex 8, owner := repo.owner, name := repo.name, prNumber, headSha
    , createdAt := now, updatedAt := now }
  Store.run <| HasModel.save job.toRow
  return job

/-- The jobs of one pull request, newest first. -/
def jobsOfPull (owner name : String) (prNumber : Nat) : IO (Array Job) := do
  let rows ← Store.run <| HasModel.fetch <| query% do
    let j ← from Store.JobRow
    guard j.owner = owner
    guard j.name = name
    guard j.pr_number = (prNumber : Int)
    select j
    order_by_desc j.created_at
    order_by_desc j.id
  return rows.map Job.ofRow

/-- The jobs in one of `statuses`, oldest first: the order the workers take them in. -/
def jobsWithStatus (statuses : List JobStatus) : IO (Array Job) := do
  let names := statuses.map (·.toString)
  return ((← listJobs).filter (names.contains ·.statusRaw)).reverse

/-- A new job for a pull request at head `headSha`, unless one already exists for that head: one
    review per commit. The check and the write are one transaction, so discovery running twice
    over the same head makes one job. Answers the job made, if one was. -/
def createJobForHead (repo : Repo) (prNumber : Nat) (headSha : String)
    (baseSha title body : Option String) : IO (Option Job) := do
  let now ← nowIso
  let job : Job :=
    { id := ← randomHex 8, owner := repo.owner, name := repo.name, prNumber
    , headSha := some headSha, baseSha, title, prBody := body
    , createdAt := now, updatedAt := now }
  Store.transact do
    let rows ← HasModel.fetch <| query% do
      let j ← from Store.JobRow
      guard j.owner = repo.owner
      guard j.name = repo.name
      guard j.pr_number = (prNumber : Int)
      select j
    if rows.any (·.head_sha == some headSha) then return none
    HasModel.save job.toRow
    return some job

/-- How many jobs of `owner/name` were made at or after `since` (RFC 3339, so that the strings
    compare as the instants do). -/
def jobsSince (owner name since : String) : IO Nat := do
  let rows ← Store.run <| HasModel.fetch <| query% do
    let j ← from Store.JobRow
    guard j.owner = owner
    guard j.name = name
    select j
  return (rows.filter (·.created_at ≥ since)).size

/-- The statuses in which a job still has a use for its diff. -/
def liveStatuses : List JobStatus := [.pending, .queued, .running, .draft, .approved]

/-- Drop the kept diffs no live job is of, and every one fetched before `before`. Answers how many
    were dropped. -/
def pruneDiffs (before : String) : IO Nat := do
  -- `before` is an instant this process formatted, and the statuses are constants: nothing in the
  -- statement comes from a request.
  let live := ", ".intercalate (liveStatuses.map fun st => s!"'{st.toString}'")
  Store.run do
    let db ← read
    SQLite.exec db s!"DELETE FROM pull_diff WHERE fetched_at < '{before}' OR NOT EXISTS \
(SELECT 1 FROM review_job j WHERE j.owner = pull_diff.owner AND j.name = pull_diff.name AND \
j.base_sha = pull_diff.base_sha AND j.head_sha = pull_diff.head_sha AND j.status IN ({live}))"
    return (← db.changes).toInt.toNat

/-- The diff kept for a pull request with base `base` at head `head`. -/
def cachedDiff (owner name base head : String) : IO (Option String) := do
  let rows ← Store.run <| HasModel.fetch <| query% do
    let d ← from Store.DiffRow
    guard d.owner = owner
    guard d.name = name
    guard d.base_sha = base
    guard d.head_sha = head
    select d
  return rows[0]?.map (·.diff)

def cacheDiff (owner name base head diff : String) : IO Unit := do
  let fetched_at ← nowIso
  Store.run <| HasModel.save
    ({ owner, name, base_sha := base, head_sha := head, diff, fetched_at } : Store.DiffRow)

/-- Why an update was not made. -/
inductive UpdateError where
  | notFound
  /-- The job is not in a state, or not at the version, the update was meant for. -/
  | conflict (why : String)
  | invalid (why : String)

/-- Change job `id` with `f`, reading and writing it under one hold of the store's lock and in one
    transaction, so no other write — from this process or another — can land between the check `f`
    makes and the write that follows it. Bumps the version and the time on every write. -/
def updateJob (id : String) (f : Job → Except UpdateError Job) : IO (Except UpdateError Job) := do
  let now ← nowIso
  Store.transact do
    let some job ← fetchJob id | return .error .notFound
    match f job with
    | .error e => return .error e
    | .ok next =>
      let next := { next with version := job.version + 1, updatedAt := now }
      HasModel.save next.toRow
      return .ok next

end Platform

end DiffReviewer