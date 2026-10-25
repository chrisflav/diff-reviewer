import Lean.Data.Json
import DiffReviewer.Types
import DiffReviewer.Rubric
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

A job is of a **kind** (`JobKind`): a `review` of a pull request, posted once a person approves
it, or a `calibration` — a review of a past commit, scored against a trusted reviewer's review of
it (`DiffReviewer.Calibration`) and never approved, claimed or posted. A kind this build does not
know is treated as one that is never posted.

Beside them, two histories that are only ever appended to: the versions of each repository's
rubric document (`putRubric`), and the **revisions** of each job's review — every write of it, by
the agent, a person or (once posted) GitHub, with what it said. The agent's draft beside what was
posted is what calibration learns from, so a revision is written in the same transaction as the
write it records (`updateJob`'s `revision`): there is no review the history does not have.
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
  /-- The GitHub logins, in lower case, whose reviews of the repository's pull requests
      calibration imports and scores the agent against. -/
  trustedReviewers : List String := []
  /-- What the operator says of how the repository's reviews are written — tone, length, what to
      leave out — in markdown, at most `maxStyleNotesBytes`. The agent's instructions carry it
      after the rubric. -/
  styleNotes : String := ""
  /-- The share of new calibration samples, in percent, held out for measuring (`eval`); the rest
      are the `pool` examples and proposals learn from. A sample's split is fixed once made. -/
  evalShare  : Nat := 50
  /-- The version of the style notes (`notesAt`), which records what they were derived from; 0
      before any. -/
  styleNotesVersion : Nat := 0
  /-- Incremented by every write of the settings, so that a stale page is refused (`409`) rather
      than overwriting what it never saw. -/
  version    : Nat := 1
  createdAt  : String
  deriving Repr

def Repo.slug (r : Repo) : String := s!"{r.owner}/{r.name}"

def Repo.toJson (r : Repo) : Json :=
  .mkObj [("owner", r.owner), ("name", r.name), ("mode", r.mode.toString),
          ("autoReview", r.autoReview),
          ("trustedReviewers", .arr (r.trustedReviewers.map Json.str).toArray),
          ("styleNotes", r.styleNotes), ("evalShare", r.evalShare),
          ("styleNotesVersion", r.styleNotesVersion),
          ("version", r.version), ("createdAt", r.createdAt)]

/-- The strings a column holding a JSON array of strings holds; anything else is none. -/
def stringsOfRaw (raw : Option String) : List String :=
  match raw.map Json.parse with
  | some (.ok (.arr xs)) => xs.toList.filterMap (·.getStr?.toOption)
  | _ => []

private def trustedOfRaw (raw : Option String) : List String := stringsOfRaw raw

/-- `xs` as a column of a JSON array of strings. -/
def rawOfStrings (xs : List String) : String := (Json.arr (xs.map Json.str).toArray).compress

private def Repo.ofRow (row : Store.RepoRow) : Repo :=
  { owner := row.owner, name := row.name, createdAt := row.created_at
  , mode := (PostingMode.ofString? row.mode).getD .staged
  , autoReview := row.auto_review.getD false
  , trustedReviewers := trustedOfRaw row.trusted_reviewers
  , styleNotes := row.style_notes.getD ""
  , evalShare := (row.eval_share.getD 50).toNat
  , styleNotesVersion := (row.style_notes_version.getD 0).toNat
  , version := (row.version.getD 1).toNat }

/-- The repository as its row, for a write. -/
private def Repo.toRow (r : Repo) : Store.RepoRow :=
  { owner := r.owner, name := r.name, mode := r.mode.toString, created_at := r.createdAt
  , auto_review := some r.autoReview
  , trusted_reviewers := some (Json.arr (r.trustedReviewers.map Json.str).toArray).compress
  , style_notes := some r.styleNotes, eval_share := some r.evalShare
  , style_notes_version := some r.styleNotesVersion, version := some r.version }

/-! ## Provenance -/

/-- What a rubric version or a version of the style notes was derived from: the calibration
    samples (by id) and the pull requests (`owner/name#pr`) the context of the rubric proposal it
    came from drew on — its misses, its unmatched comments, its people's edits — and every earlier
    version's, since what a version learned is never forgotten by the next. A score of any sample
    of those pull requests, made under such a version, is `derived`
    (`Calibration.derivedOf`). -/
structure Provenance where
  samples : List String := []
  prs     : List String := []
  deriving Repr, BEq, Inhabited

def Provenance.union (a b : Provenance) : Provenance :=
  { samples := (a.samples ++ b.samples).eraseDups, prs := (a.prs ++ b.prs).eraseDups }

/-- The key of pull request `pr` of `owner/name`, as provenance records it. -/
def prKey (owner name : String) (pr : Nat) : String := s!"{owner}/{name}#{pr}"

/-- Whether `s` can be a GitHub login: 1 to 39 letters, digits and single hyphens, not starting or
    ending with one. -/
def validLogin (s : String) : Bool :=
  !s.isEmpty && s.length ≤ 39 && !s.startsWith "-" && !s.endsWith "-" &&
    (s.splitOn "--").length == 1 && s.all fun c => c.isAlphanum || c == '-'

/-- The most trusted reviewers a repository names. -/
def maxTrustedReviewers : Nat := 50

/-- The longest style notes, in bytes: a page of guidance, not a second rubric. -/
def maxStyleNotesBytes : Nat := 16384

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

/-- What a job is for. -/
inductive JobKind where
  /-- A review of a pull request, posted once a person approves it. -/
  | review
  /-- A review of a past commit of a closed pull request, scored against a trusted reviewer's
      review of the same commit. Never posted, never approved, never made `stale` by discovery. -/
  | calibration
  /-- A rubric proposal: an agent reads the repository's calibration data and proposes a rubric
      document, which a person accepts or rejects (`DiffReviewer.Proposal`). Of the repository,
      not of a pull request (its `prNumber` is 0), and never posted. -/
  | proposal
  deriving Repr, BEq, DecidableEq

def JobKind.toString : JobKind → String
  | .review      => "review"
  | .calibration => "calibration"
  | .proposal    => "proposal"

def JobKind.ofString? : String → Option JobKind
  | "review"      => some .review
  | "calibration" => some .calibration
  | "proposal"    => some .proposal
  | _             => none

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
  /-- The review as GitHub holds it, `{"id", "url", "body"}`, once posted. -/
  postedReview : Option String := none
  /-- The version of the repository's rubric the review was checked against: 0 when the repository
      had none, `none` for a job reviewed before rubrics existed. -/
  rubricVersion : Option Nat := none
  /-- How many times the platform has posted the review on its own (`direct`). -/
  directPosts : Nat := 0
  /-- Whether the last claim to post was the platform's own, which it may make again. -/
  postDirect : Bool := false
  /-- What the job is for, as stored: `none` is a review (`JobKind`). -/
  kindRaw    : Option String := none
  /-- The calibration sample a `calibration` job reviews, and the run that asked for it. -/
  sampleId   : Option String := none
  runId      : Option String := none
  /-- The version of the style notes the agent was given when it read the job, as
      `rubricVersion` records the rubric: what `Calibration.derivedOf` judges its score by. -/
  notesVersion : Option Nat := none

def Job.status? (j : Job) : Option JobStatus := JobStatus.ofString? j.statusRaw

/-- The job's kind; `none` for a kind this build does not know. -/
def Job.kind? (j : Job) : Option JobKind :=
  match j.kindRaw with
  | none   => some .review
  | some k => JobKind.ofString? k

/-- Whether the job is a review to post: of the kind `review`. A job of any other kind — a
    calibration, or a kind a newer build wrote — is never approved, claimed or posted. -/
def Job.isReview (j : Job) : Bool := j.kind? == some .review

/-- Why job `j` is not one to approve, claim or post, if it is not one: anything but a review. -/
def Job.notPostable (j : Job) : Option String :=
  if j.isReview then none
  else s!"job {j.id} is a {j.kindRaw.getD "review"} job; it is never approved or posted"

/-- The review, `none` when there is none, and an error when the stored one does not parse. -/
def Job.review? (j : Job) : Option (Except String Review) :=
  j.reviewRaw.map Review.ofJsonString

/-- Why job `j` may not leave `approved`, have its review replaced or be made `stale` now: a post
    of it may have reached GitHub, and until that is known, what it says is what was posted. -/
def Job.claimBlocks (j : Job) : Option String :=
  j.postStartedAt.map fun t =>
    s!"a post of job {j.id} (begun {t}) may have reached GitHub; it is being checked — post it \
again (POST /api/v1/jobs/{j.id}/post) or check it (POST /api/v1/jobs/{j.id}/reconcile) to \
settle it"

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
    ("postNote", optStr j.postNote),
    ("postedReview", (j.postedReview.bind (Json.parse · |>.toOption)).getD .null),
    ("rubricVersion", (j.rubricVersion.map fun v => (v : Json)).getD .null),
    ("directPosts", j.directPosts), ("postDirect", j.postDirect),
    ("kind", j.kindRaw.getD JobKind.review.toString), ("sampleId", optStr j.sampleId),
    ("runId", optStr j.runId),
    ("notesVersion", (j.notesVersion.map fun v => (v : Json)).getD .null)]

def Job.ofRow (row : Store.JobRow) : Job :=
  { id := row.id, owner := row.owner, name := row.name, prNumber := row.pr_number.toNat
  , headSha := row.head_sha, statusRaw := row.status, queueEntry := row.queue_entry
  , reviewRaw := row.review, version := row.version.toNat
  , createdAt := row.created_at, updatedAt := row.updated_at
  , baseSha := row.base_sha, title := row.title, prBody := row.pr_body, error := row.error
  , prType := row.pr_type, attempts := (row.attempts.getD 0).toNat
  , postStartedAt := row.post_started_at, postedUrl := row.posted_url, postNote := row.post_note
  , postedReview := row.posted_review, rubricVersion := row.rubric_version.map (·.toNat)
  , directPosts := (row.direct_posts.getD 0).toNat, postDirect := row.post_direct.getD false
  , kindRaw := row.kind, sampleId := row.sample_id, runId := row.run_id
  , notesVersion := row.notes_version.map (·.toNat) }

def Job.toRow (j : Job) : Store.JobRow :=
  { id := j.id, owner := j.owner, name := j.name, pr_number := j.prNumber
  , head_sha := j.headSha, status := j.statusRaw, queue_entry := j.queueEntry
  , review := j.reviewRaw, version := j.version
  , created_at := j.createdAt, updated_at := j.updatedAt
  , base_sha := j.baseSha, title := j.title, pr_body := j.prBody, error := j.error
  , pr_type := j.prType, attempts := some j.attempts
  , post_started_at := j.postStartedAt, posted_url := j.postedUrl, post_note := j.postNote
  , posted_review := j.postedReview, rubric_version := j.rubricVersion.map Int.ofNat
  , direct_posts := some j.directPosts, post_direct := some j.postDirect
  , kind := j.kindRaw, sample_id := j.sampleId, run_id := j.runId
  , notes_version := j.notesVersion.map Int.ofNat }

/-- The largest pull request number accepted: what fits a 32-bit column with room to spare. -/
def maxPrNumber : Nat := 2147483647

/-- Whether `s` is a whole git commit id: 40 hexadecimal digits (SHA-1), or 64 (SHA-256). Never an
    abbreviation: a job's head is what a review is pinned to and compared against, and a prefix is
    neither unique nor what GitHub answers. -/
def validSha (s : String) : Bool :=
  (s.length == 40 || s.length == 64) && s.all fun c => c.isDigit || ('a' ≤ c && c ≤ 'f')

/-! ## Rubrics and revisions -/

/-- One version of a repository's rubric document. The document is kept as the row holds it and
    parsed when read, so that one this build cannot read is shown as it is, never defaulted. -/
structure RubricVersion where
  owner     : String
  name      : String
  /-- 1 for the first document, and one more for each change. -/
  version   : Nat
  createdAt : String
  documentRaw : String
  /-- What it was derived from: the rubric proposal it came from, and every earlier version's —
      a version a person wrote over a derived one may keep what it learned. -/
  derived : Provenance := {}

def RubricVersion.rubric? (r : RubricVersion) : Except String Rubric :=
  (Json.parse r.documentRaw).bind Rubric.ofJson

def RubricVersion.toJson (r : RubricVersion) : Json :=
  let fields : List (String × Json) :=
    [("owner", r.owner), ("name", r.name), ("version", r.version), ("createdAt", r.createdAt),
     ("derivedFrom", .arr (r.derived.samples.map Json.str).toArray),
     ("derivedFromPulls", .arr (r.derived.prs.map Json.str).toArray)]
  -- The document's own fields, those this build does not know among them, under the version's.
  match r.rubric? with
  | .ok doc =>
    let known : List (String × Json) := [("defaultRubric", doc.defaultRubric),
      ("prTypes", .arr (doc.prTypes.map PrType.toJson).toArray), ("documentError", .null)]
    .mkObj (doc.extra ++ fields ++ known)
  | .error e =>
    let known : List (String × Json) :=
      [("defaultRubric", .null), ("prTypes", .null), ("documentError", e)]
    .mkObj (fields ++ known)

/-- The fields of a rubric answer that are the version's, not the document's: a client that sends
    the answer back as its next write sends them too, and they are not kept as the document's. -/
def RubricVersion.fields : List String :=
  ["version", "owner", "name", "createdAt", "documentError", "derivedFrom", "derivedFromPulls",
   "fromProposal"]

/-- The answer for a repository with no rubric yet: version 0, an empty document. -/
def RubricVersion.none (owner name : String) : Json :=
  .mkObj [("owner", owner), ("name", name), ("version", (0 : Nat)), ("createdAt", .null),
          ("derivedFrom", .arr #[]), ("derivedFromPulls", .arr #[]), ("defaultRubric", ""),
          ("prTypes", .arr #[]), ("documentError", .null)]

private def RubricVersion.ofRow (row : Store.RubricRow) : RubricVersion :=
  { owner := row.owner, name := row.name, version := row.version.toNat
  , createdAt := row.created_at, documentRaw := row.document
  , derived := { samples := stringsOfRaw row.derived_samples
               , prs := stringsOfRaw row.derived_prs } }

/-- Who wrote a revision of a job's review. -/
inductive Author where
  /-- The agent's submission. -/
  | agent
  /-- A person's edit. -/
  | person
  /-- What GitHub holds once the review is posted. -/
  | github
  deriving Repr, BEq

def Author.toString : Author → String
  | .agent  => "agent"
  | .person => "person"
  | .github => "github"

/-- One write of a job's review. -/
structure Revision where
  jobId     : String
  /-- The job's version the write made. -/
  version   : Nat
  /-- `agent`, `person` or `github`; kept as stored. -/
  author    : String
  /-- The review as written, `Review.toJson`, compressed. -/
  reviewRaw : String
  createdAt : String

def Revision.toJson (r : Revision) : Json :=
  -- The JSON as it was written, not as this build reads reviews: a revision is a record.
  let (review, err) : Json × Json := match Json.parse r.reviewRaw with
    | .ok j => (j, .null)
    | .error e => (.null, .str e)
  .mkObj [("jobId", r.jobId), ("version", r.version), ("author", r.author),
          ("review", review), ("reviewError", err), ("createdAt", r.createdAt)]

/-- The revision a write of `j`'s own review records: by `author`, the review as now stored. -/
def Job.revisionBy (author : Author) (j : Job) : Option (Author × String) :=
  j.reviewRaw.map (author, ·)

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

/-- What a write of a repository's settings changes. A field left `none` keeps the current value
    — or, for a repository not yet registered, the default — so that a client that does not know
    a setting cannot wipe it. -/
structure RepoUpdate where
  mode             : Option PostingMode := none
  autoReview       : Option Bool := none
  trustedReviewers : Option (List String) := none
  styleNotes       : Option String := none
  evalShare        : Option Nat := none
  /-- Run first in the write's transaction: what the style notes written are derived from (a
      rubric proposal they came from, which it marks accepted), or why nothing is to be written. -/
  provenance       : Sqlite.M (Except String Provenance) := pure (.ok {})
  /-- The version of the settings the client last read (0 for a repository not yet registered);
      `none` writes whatever is there. -/
  expected         : Option Nat := none

/-- One version of a repository's style notes, and what it was derived from. -/
structure NotesVersion where
  version : Nat
  notes   : String
  derived : Provenance

private def NotesVersion.ofRow (r : Store.NotesRow) : NotesVersion :=
  { version := r.version.toNat, notes := r.notes
  , derived := { samples := stringsOfRaw (some r.derived_samples)
               , prs := stringsOfRaw (some r.derived_prs) } }

/-- The latest version of `owner/name`'s style notes, if there is one. -/
def fetchNotes (owner name : String) : Sqlite.M (Option NotesVersion) := do
  let rows ← HasModel.fetch <| query% do
    let n ← from Store.NotesRow
    guard n.owner = owner
    guard n.name = name
    select n
    order_by_desc n.version
    limit 1
  return rows[0]?.map NotesVersion.ofRow

/-- Every version of `owner/name`'s style notes, newest first. -/
def notesHistory (owner name : String) : IO (Array NotesVersion) := do
  let rows ← Store.run <| HasModel.fetch <| query% do
    let n ← from Store.NotesRow
    guard n.owner = owner
    guard n.name = name
    select n
    order_by_desc n.version
  return rows.map NotesVersion.ofRow

/-- `repo` with its style notes recorded: a new notes version when they, or what they are derived
    from, differ from the latest — derived from the latest's provenance and `derived` together, so
    that nothing a version learned is forgotten, not even across a delete and a registration
    again. The latest is the repository's otherwise. -/
def writeNotesIn (repo : Repo) (derived : Provenance) (now : String) : Sqlite.M Repo := do
  let latest ← fetchNotes repo.owner repo.name
  let base := (latest.map (·.derived)).getD {}
  let prov := base.union derived
  let same := latest.any fun l => l.notes == repo.styleNotes && l.derived == prov
  if same || (latest.isNone && repo.styleNotes.isEmpty && derived == {}) then
    return { repo with styleNotesVersion := (latest.map (·.version)).getD 0 }
  let version := (latest.map (·.version)).getD 0 + 1
  HasModel.save ({ owner := repo.owner, name := repo.name, version, notes := repo.styleNotes
                 , derived_samples := rawOfStrings prov.samples
                 , derived_prs := rawOfStrings prov.prs, created_at := now } : Store.NotesRow)
  return { repo with styleNotesVersion := version }

/-- The last settings version of `owner/name` when it was deleted, if it ever was. -/
private def fetchTombstone (owner name : String) : Sqlite.M (Option Store.TombstoneRow) := do
  let rows ← HasModel.fetch <| query% do
    let t ← from Store.TombstoneRow
    guard t.owner = owner
    guard t.name = name
    select t
  return rows[0]?

/-- Create or update a repository: a versioned write, the check and the write in one transaction.
    Answers whether it existed before, and the repository as written. Names are stored in lower
    case, as GitHub compares them, so `Acme/Widgets` and `acme/widgets` are one repository; so are
    the trusted reviewers' logins. -/
def putRepo (owner name : String) (u : RepoUpdate) : IO (Except String (Bool × Repo)) := do
  let owner := owner.toLower
  let name := name.toLower
  let now ← nowIso
  Store.transact do
    let rows ← HasModel.fetch <| query% do
      let r ← from Store.RepoRow
      guard r.owner = owner
      guard r.name = name
      select r
    let existing := rows[0]?.map Repo.ofRow
    -- A registration is version 0 to a client, but goes on from the last version a deleted one of
    -- the same name had: versions never repeat, so a page of the old one is refused by the new.
    let current := (existing.map (·.version)).getD 0
    let last := ((← fetchTombstone owner name).map (·.version.toNat)).getD 0
    if let some v := u.expected then
      unless v == current do
        return .error s!"the settings of {owner}/{name} have changed since they were read \
(version {v}, now {current}); reload them"
    let latest ← fetchNotes owner name
    let old : Repo := existing.getD { owner, name, createdAt := now, version := last
                                    , styleNotesVersion := (latest.map (·.version)).getD 0 }
    let trusted := (u.trustedReviewers.map (·.map String.toLower |>.eraseDups)).getD
      old.trustedReviewers
    let repo : Repo :=
      { old with mode := u.mode.getD old.mode, autoReview := u.autoReview.getD old.autoReview
                 trustedReviewers := trusted, styleNotes := u.styleNotes.getD old.styleNotes
                 evalShare := u.evalShare.getD old.evalShare, version := old.version + 1 }
    let prov ← match ← u.provenance with
      | .ok p => pure p
      | .error why => return .error why
    let repo ← writeNotesIn repo prov now
    HasModel.save repo.toRow
    return .ok (existing.isSome, repo)

/-- Repository `owner/name` read inside a transaction, as `findRepo` reads it. -/
def fetchRepo (owner name : String) : Sqlite.M (Option Repo) := do
  let rows ← HasModel.fetch <| query% do
    let r ← from Store.RepoRow
    guard r.owner = owner
    guard r.name = name
    select r
  return rows[0]?.map Repo.ofRow

/-- Write `notes` as `repo`'s style notes, derived from `derived`, as the next version of its
    settings: for a write that has made its own checks in the transaction it is part of
    (accepting a rubric proposal). -/
def saveStyleNotes (repo : Repo) (notes : String) (derived : Provenance) : Sqlite.M Repo := do
  let repo ← writeNotesIn { repo with styleNotes := notes, version := repo.version + 1 } derived
    (← nowIso)
  HasModel.save repo.toRow
  return repo

/-- Delete a repository. Its jobs are kept: they are the record of reviews that happened. So are
    its rubric versions, which those jobs name (`rubricVersion`): registering the repository again
    picks up its rubric where it was. Its row goes — every lookup, listing, worker and agent route
    finds it gone — and the version its settings had is kept apart (`Store.TombstoneRow`), for
    registering it again to go on from. -/
def deleteRepo (owner name : String) : IO Bool := do
  let (owner, name) := (owner.toLower, name.toLower)
  let now ← nowIso
  Store.transact do
    let some repo ← fetchRepo owner name | return false
    let _ ← HasModel.delete (α := Store.RepoRow)
      (.and (.eq (.var Store.RepoRowIndex.owner .text) (.text owner))
            (.eq (.var Store.RepoRowIndex.name .text) (.text name)))
    -- What registering it again goes on from (`putRepo`).
    HasModel.save ({ owner, name, version := repo.version, deleted_at := now }
      : Store.TombstoneRow)
    return true

def listJobs : IO (Array Job) := do
  let rows ← Store.run <| HasModel.fetch <| query% do
    let j ← from Store.JobRow
    select j
    order_by_desc j.created_at
    order_by_desc j.id
  return rows.map Job.ofRow

def fetchJob (id : String) : Sqlite.M (Option Job) := do
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

/-- A new job for a pull request at head `headSha`, unless a review job already exists for that
    head: one review per commit, whatever calibration jobs there are of it. The check and the
    write are one transaction, so discovery running twice over the same head makes one job.
    Answers the job made, if one was. -/
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
    if rows.any fun r => r.head_sha == some headSha && (Job.ofRow r).isReview then return none
    HasModel.save job.toRow
    return some job

/-- The jobs of `owner/name` of kind `kind` made at or after `since` (RFC 3339, so that the
    strings compare as the instants do): what the daily caps count. A job of a kind this build
    does not know counts as neither. -/
def jobsSinceIn (owner name since : String) (kind : JobKind) : Sqlite.M Nat := do
  let rows ← HasModel.fetch <| query% do
    let j ← from Store.JobRow
    guard j.owner = owner
    guard j.name = name
    select j
  return (rows.filter fun r => r.created_at ≥ since && (Job.ofRow r).kind? == some kind).size

/-- How many review jobs of `owner/name` were made at or after `since`. -/
def jobsSince (owner name since : String) : IO Nat :=
  Store.run (jobsSinceIn owner name since .review)

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

/-- The most recent revisions of a job's review kept, beside its first draft and what was posted. -/
def maxRevisions : Nat := 100

/-- Bound job `id`'s history: keep the agent's first draft, every revision by GitHub — what was
    posted — and the last `maxRevisions`; drop the rest. What calibration needs is the draft and
    the posted review; the edits between are kept as far back as is useful, and a job edited
    without end does not grow without bound. -/
private def pruneRevisions (id : String) : Sqlite.M Unit := do
  let rows ← HasModel.fetch <| query% do
    let r ← from Store.RevisionRow
    guard r.job_id = id
    select r
    order_by r.version
  if rows.size ≤ maxRevisions + 1 then return
  let firstDraft := (rows.find? (·.author == Author.agent.toString)).map (·.version)
  let recent := (rows.extract (rows.size - maxRevisions) rows.size).map (·.version)
  let drop := rows.filter fun r =>
    some r.version != firstDraft && !recent.contains r.version &&
      r.author != Author.github.toString
  if drop.isEmpty then return
  let _ ← HasModel.delete (α := Store.RevisionRow)
    (.and (.eq (.var Store.RevisionRowIndex.job_id .text) (.text id))
          (.inList (.var Store.RevisionRowIndex.version .int) (drop.map (·.version)).toList))

/-- Change job `id` with `f`, reading and writing it under one hold of the store's lock and in one
    transaction, so no other write — from this process or another — can land between the check `f`
    makes and the write that follows it. Bumps the version and the time on every write.

    A write of the review passes `revision`, which given the job as written answers who wrote the
    review and what it says; the revision is appended in the same transaction, at the job's new
    version. -/
def updateJob (id : String) (f : Job → Except UpdateError Job)
    (revision : Job → Option (Author × String) := fun _ => none) :
    IO (Except UpdateError Job) := do
  let now ← nowIso
  Store.transact do
    let some job ← fetchJob id | return .error .notFound
    match f job with
    | .error e => return .error e
    | .ok next =>
      let next := { next with version := job.version + 1, updatedAt := now }
      HasModel.save next.toRow
      if let some (author, review) := revision next then
        HasModel.save ({ job_id := id, version := next.version, author := author.toString
                       , review, created_at := now } : Store.RevisionRow)
        pruneRevisions id
      return .ok next

/-- The revisions of job `id`'s review, oldest first. -/
def revisions (id : String) : IO (Array Revision) := do
  let rows ← Store.run <| HasModel.fetch <| query% do
    let r ← from Store.RevisionRow
    guard r.job_id = id
    select r
    order_by r.version
  return rows.map fun r =>
    { jobId := r.job_id, version := r.version.toNat, author := r.author, reviewRaw := r.review
    , createdAt := r.created_at }

private def fetchRubrics (owner name : String) : Sqlite.M (Array RubricVersion) := do
  let rows ← HasModel.fetch <| query% do
    let r ← from Store.RubricRow
    guard r.owner = owner
    guard r.name = name
    select r
    order_by_desc r.version
  return rows.map RubricVersion.ofRow

/-- Every version of `owner/name`'s rubric document, newest first. -/
def rubricHistory (owner name : String) : IO (Array RubricVersion) :=
  Store.run (fetchRubrics owner name)

def fetchCurrentRubric (owner name : String) : Sqlite.M (Option RubricVersion) := do
  let rows ← HasModel.fetch <| query% do
    let r ← from Store.RubricRow
    guard r.owner = owner
    guard r.name = name
    select r
    order_by_desc r.version
    limit 1
  return rows[0]?.map RubricVersion.ofRow

/-- The current version of `owner/name`'s rubric document, if it has one. -/
def currentRubric (owner name : String) : IO (Option RubricVersion) :=
  Store.run (fetchCurrentRubric owner name)

/-- Version `version` of `owner/name`'s rubric document. -/
def rubricAt (owner name : String) (version : Nat) : IO (Option RubricVersion) := do
  let rows ← Store.run <| HasModel.fetch <| query% do
    let r ← from Store.RubricRow
    guard r.owner = owner
    guard r.name = name
    guard r.version = (version : Int)
    select r
  return rows[0]?.map RubricVersion.ofRow

/-- `putRubric`'s check and write, inside a transaction the caller holds: for a write that changes
    the rubric together with something else (accepting a rubric proposal). -/
def putRubricIn (owner name : String) (expected : Nat) (doc : Rubric) (now : String)
    (derived : Provenance := {}) : Sqlite.M (Except UpdateError RubricVersion) := do
  let cur ← fetchCurrentRubric owner name
  if let some c := cur then
    if let .error e := c.rubric? then
      return .error (.conflict s!"the rubric of {owner}/{name} (version {c.version}) cannot be \
read by this build ({e}); it is left as it is")
  let current := (cur.map (·.version)).getD 0
  unless current == expected do
    return .error (.conflict s!"the rubric of {owner}/{name} has changed since it was read \
(version {expected}, now {current}); reload it")
  -- What the version learned from is never forgotten: a version is derived from what the one it
  -- replaces was, and from what a proposal accepted as it drew on.
  let derived := ((cur.map fun (c : RubricVersion) => c.derived).getD {}).union derived
  let row : Store.RubricRow :=
    { owner, name, version := current + 1, document := doc.toJson.compress, created_at := now
    , derived_samples := some (rawOfStrings derived.samples)
    , derived_prs := some (rawOfStrings derived.prs) }
  HasModel.save row
  return .ok (RubricVersion.ofRow row)

/-- Write `doc` as the next version of `owner/name`'s rubric, if `expected` is the current
    version (0 for none yet): a versioned write, like a job's, so that two people editing the
    rubric cannot overwrite each other unseen. The check and the write are one transaction. A
    current version this build cannot read is not replaced (`conflict`): the person writing never
    saw what it says, and the build that can read it should be the one to change it. -/
def putRubric (owner name : String) (expected : Nat) (doc : Rubric) :
    IO (Except UpdateError RubricVersion) := do
  let now ← nowIso
  Store.transact (putRubricIn owner name expected doc now)

end Platform

end DiffReviewer