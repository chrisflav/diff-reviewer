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

/-- The transitions a person makes from the platform, and the agent's submission. -/
def JobStatus.canMove : JobStatus → JobStatus → Bool
  | .pending,  .queued   => true
  | .queued,   .running  => true
  | .running,  .draft    => true
  -- A draft is edited in place and stays a draft; these are the decisions on it.
  | .draft,    .approved => true
  | .draft,    .rejected => true
  | .draft,    .stale    => true
  | .approved, .draft    => true
  | .approved, .posted   => true
  | .rejected, .draft    => true
  | _,         _         => false

structure Job where
  id         : String
  owner      : String
  name       : String
  prNumber   : Nat
  headSha    : Option String := none
  status     : JobStatus := .pending
  queueEntry : Option String := none
  review     : Option Review := none
  createdAt  : String
  updatedAt  : String

private def optStr : Option String → Json
  | some s => .str s
  | none   => .null

def Job.toJson (j : Job) : Json :=
  .mkObj [
    ("id", j.id), ("owner", j.owner), ("name", j.name), ("prNumber", j.prNumber),
    ("headSha", optStr j.headSha), ("status", j.status.toString),
    ("queueEntry", optStr j.queueEntry),
    ("review", match j.review with | some r => r.toJson | none => .null),
    ("createdAt", j.createdAt), ("updatedAt", j.updatedAt)]

/-- The job a row holds. A review that no longer parses is dropped rather than failing the whole
    job: the job is still worth listing, and the next edit replaces the review. -/
private def Job.ofRow (row : Store.JobRow) : Job :=
  { id := row.id, owner := row.owner, name := row.name, prNumber := row.pr_number.toNat
  , headSha := row.head_sha
  , status := (JobStatus.ofString? row.status).getD .pending
  , queueEntry := row.queue_entry
  , review := row.review.bind fun s => (Review.ofJsonString s).toOption
  , createdAt := row.created_at, updatedAt := row.updated_at }

private def Job.toRow (j : Job) : Store.JobRow :=
  { id := j.id, owner := j.owner, name := j.name, pr_number := j.prNumber
  , head_sha := j.headSha, status := j.status.toString, queue_entry := j.queueEntry
  , review := j.review.map (·.toJson.compress)
  , created_at := j.createdAt, updated_at := j.updatedAt }

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

/-- Create or replace a repository. Answers whether it existed before. -/
def putRepo (owner name : String) (mode : PostingMode) : IO Bool := do
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
    (.and (.eq (.var Store.RepoRowIndex.owner .text) (.text owner))
          (.eq (.var Store.RepoRowIndex.name .text) (.text name)))
  return n > 0

def listJobs : IO (Array Job) := do
  let rows ← Store.run <| HasModel.fetch <| query% do
    let j ← from Store.JobRow
    select j
    order_by_desc j.created_at
    order_by_desc j.id
  return rows.map Job.ofRow

def findJob (id : String) : IO (Option Job) := do
  let rows ← Store.run <| HasModel.fetch <| query% do
    let j ← from Store.JobRow
    guard j.id = id
    select j
  return rows[0]?.map Job.ofRow

def saveJob (j : Job) : IO Unit :=
  Store.run <| HasModel.save j.toRow

/-- A new job for pull request `prNumber` of a registered repository. -/
def createJob (repo : Repo) (prNumber : Nat) (headSha : Option String) : IO Job := do
  let now ← nowIso
  let job : Job :=
    { id := ← randomHex 8, owner := repo.owner, name := repo.name, prNumber, headSha
    , createdAt := now, updatedAt := now }
  saveJob job
  return job

end Platform

end DiffReviewer