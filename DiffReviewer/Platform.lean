import Lean.Data.Json
import DiffReviewer.Types
import DiffReviewer.Store

open Lean (Json)

/-!
# The platform's records

What the review platform keeps: the repositories it reviews, and one **job** per review of a pull
request. A job moves through `pending → queued → running → draft → approved → posted`; `rejected`
is a draft somebody discarded and `stale` a draft whose pull request has moved on since. Only the
transitions a person or the agent makes are here; queueing on orchestra and posting to GitHub are
the milestones after this one.
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
  owner     : String
  name      : String
  mode      : PostingMode := .staged
  createdAt : String
  deriving Repr

def Repo.slug (r : Repo) : String := s!"{r.owner}/{r.name}"

def Repo.toJson (r : Repo) : Json :=
  .mkObj [("owner", r.owner), ("name", r.name), ("mode", r.mode.toString),
          ("createdAt", r.createdAt)]

private def Repo.ofRow (row : Store.RepoRow) : Repo :=
  { owner := row.owner, name := row.name, createdAt := row.created_at
  , mode := (PostingMode.ofString? row.mode).getD .staged }

/-- Whether `s` can be one half of a GitHub `owner/name`: letters, digits, `-`, `_` and `.`, not
    starting with a dot. Checked because both halves end up in URLs and, later, clone paths. -/
def validSlugPart (s : String) : Bool :=
  !s.isEmpty && s.length ≤ 100 && !s.startsWith "." &&
    s.all fun c => c.isAlphanum || c == '-' || c == '_' || c == '.'

/-! ## Jobs -/

inductive JobStatus where
  | pending | queued | running | draft | approved | posted | rejected | stale
  deriving Repr, BEq, DecidableEq

def JobStatus.all : List JobStatus :=
  [.pending, .queued, .running, .draft, .approved, .posted, .rejected, .stale]

def JobStatus.toString : JobStatus → String
  | .pending  => "pending"
  | .queued   => "queued"
  | .running  => "running"
  | .draft    => "draft"
  | .approved => "approved"
  | .posted   => "posted"
  | .rejected => "rejected"
  | .stale    => "stale"

def JobStatus.ofString? (s : String) : Option JobStatus :=
  JobStatus.all.find? (·.toString == s)

/-- The moves a person makes on a job from the platform. Everything else — queueing, running, the
    agent's draft, posting to GitHub — is the platform's own doing, and no request can claim it. -/
def JobStatus.personCanMove : JobStatus → JobStatus → Bool
  | .draft,    .approved => true
  | .draft,    .rejected => true
  | .draft,    .stale    => true
  | .approved, .draft    => true
  | .rejected, .draft    => true
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
    ("version", j.version), ("createdAt", j.createdAt), ("updatedAt", j.updatedAt)]

private def Job.ofRow (row : Store.JobRow) : Job :=
  { id := row.id, owner := row.owner, name := row.name, prNumber := row.pr_number.toNat
  , headSha := row.head_sha, statusRaw := row.status, queueEntry := row.queue_entry
  , reviewRaw := row.review, version := row.version.toNat
  , createdAt := row.created_at, updatedAt := row.updated_at }

private def Job.toRow (j : Job) : Store.JobRow :=
  { id := j.id, owner := j.owner, name := j.name, pr_number := j.prNumber
  , head_sha := j.headSha, status := j.statusRaw, queue_entry := j.queueEntry
  , review := j.reviewRaw, version := j.version
  , created_at := j.createdAt, updated_at := j.updatedAt }

/-- The largest pull request number accepted: what fits a 32-bit column with room to spare. -/
def maxPrNumber : Nat := 2147483647

/-- Whether `s` can be a git commit id: 7 to 64 hexadecimal digits. -/
def validSha (s : String) : Bool :=
  s.length ≥ 7 && s.length ≤ 64 && s.all fun c => c.isDigit || ('a' ≤ c && c ≤ 'f')

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
def putRepo (owner name : String) (mode : PostingMode) : IO Bool := do
  let owner := owner.toLower
  let name := name.toLower
  let existing ← findRepo owner name
  let createdAt ← match existing with
    | some r => pure r.createdAt
    | none   => nowIso
  Store.run <| HasModel.save
    ({ owner, name, mode := mode.toString, created_at := createdAt } : Store.RepoRow)
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

/-- Why an update was not made. -/
inductive UpdateError where
  | notFound
  /-- The job is not in a state, or not at the version, the update was meant for. -/
  | conflict (why : String)
  | invalid (why : String)

/-- Change job `id` with `f`, reading and writing it under one hold of the store's lock, so no
    other write can land between the check `f` makes and the write that follows it. Bumps the
    version and the time on every write. -/
def updateJob (id : String) (f : Job → Except UpdateError Job) : IO (Except UpdateError Job) := do
  let now ← nowIso
  Store.run do
    let some job ← fetchJob id | return .error .notFound
    match f job with
    | .error e => return .error e
    | .ok next =>
      let next := { next with version := job.version + 1, updatedAt := now }
      HasModel.save next.toRow
      return .ok next

end Platform

end DiffReviewer