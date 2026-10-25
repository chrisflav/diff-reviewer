import Db

/-!
# The platform's database

One `@[model]` structure per table, and the migrations that build them. SQLite, through `Db`: the
platform is one service with one writer, and SQLite needs nothing on the machine but the binary.

The rows are flat — a column holds a `String`, `Int`, `Bool` or an `Option` of one — so anything
structured, a review above all, is a `text` column holding the JSON its own `toJson` produces. The
conversions live in `DiffReviewer.Platform`, beside the records they convert.

`Store.target` is the schema the code declares and `migrations` is how a database gets there;
`DiffReviewerTest.Platform` asserts that the two agree, so a model change without a migration fails
the suite rather than a deployment.
-/

namespace DiffReviewer.Store

initialize_database reviewdb

/-- A repository the platform reviews pull requests of. -/
@[model (dbName := "repo") (primaryKey := ["owner", "name"]) reviewdb]
structure RepoRow where
  owner : String
  name : String
  /-- `staged` (a person approves each review before it is posted) or `direct`. -/
  mode : String
  created_at : String
  /-- Whether the platform finds the repository's pull requests itself (`0002`); a row written
      before has none, which is `false`. -/
  auto_review : Option Bool
  /-- The GitHub logins whose reviews calibration learns from, as a JSON array of strings
      (`0004`); a row written before has none, which is nobody. -/
  trusted_reviewers : Option String
  /-- Incremented by every write of the repository's settings (`0004`); a row written before has
      none, which is 1. -/
  version : Option Int
  deriving Repr

/-- One review of one pull request at one head commit: queued, run, drafted, approved, posted. -/
@[model (dbName := "review_job") (primaryKey := ["id"]) reviewdb]
structure JobRow where
  id : String
  owner : String
  name : String
  pr_number : Int
  /-- The head commit the review was asked for, when known. -/
  head_sha : Option String
  status : String
  /-- The orchestra queue entry running the review, once it has been queued. -/
  queue_entry : Option String
  /-- The current review, as `Review.toJson`: the agent's draft, then each edit over it. -/
  review : Option String
  /-- Incremented by every write; what a client sends back to say which job it acted on. -/
  version : Int
  created_at : String
  updated_at : String
  /-- The pull request's base commit, title and description, as GitHub gave them when the job was
      made or queued (`0002`). -/
  base_sha : Option String
  title : Option String
  pr_body : Option String
  /-- What the last platform step on the job failed with — queueing, the run, posting — cleared
      when one succeeds (`0002`). -/
  error : Option String
  /-- The kind of pull request the agent said it reviewed (`0002`). -/
  pr_type : Option String
  /-- How many times the job has been queued on orchestra (`0002`); none is 0. -/
  attempts : Option Int
  /-- When posting the review to GitHub last began: the claim that keeps it from being posted
      twice, kept until the outcome is known (`0002`). -/
  post_started_at : Option String
  /-- The posted review on GitHub (`0002`). -/
  posted_url : Option String
  /-- How the review was posted, when that differs from what it says — a decision posted as a
      comment (`0002`). -/
  post_note : Option String
  /-- The review as GitHub holds it, `{"id", "url", "body"}`: what was posted, which after a
      reconciliation may not be the job's own review (`0002`). -/
  posted_review : Option String
  /-- The version of the repository's rubric the review was checked against, 0 for none (`0003`).
      Null for a job reviewed before rubrics existed. -/
  rubric_version : Option Int
  /-- How many times the platform has posted the review on its own, in a `direct` repository: each
      a claim, and a request to GitHub (`0003`); none is 0. A person's posts are not counted. -/
  direct_posts : Option Int
  /-- Whether the last claim to post was the platform's own, in a `direct` repository, and so a
      post the platform may make again once the claim is settled as not having reached GitHub
      (`0003`); none is `false`. -/
  post_direct : Option Bool
  /-- What the job is for: none (or `review`) is a review of a pull request, posted once a person
      approves it; `calibration` is a review of a past commit, scored against a person's review
      of it and never posted (`0004`). -/
  kind : Option String
  /-- The calibration sample a `calibration` job reviews, and the run that asked for it
      (`0004`). -/
  sample_id : Option String
  run_id : Option String
  deriving Repr

/-- The diff of a pull request at one head commit, as GitHub gave it. A commit's diff never
    changes, so it is fetched once and kept: the agent and the front-end both read it, and neither
    should cost a GitHub request each time (`0002`). -/
@[model (dbName := "pull_diff") (primaryKey := ["owner", "name", "base_sha", "head_sha"]) reviewdb]
structure DiffRow where
  owner : String
  name : String
  base_sha : String
  head_sha : String
  diff : String
  fetched_at : String
  deriving Repr

/-- One version of a repository's rubric document, as `Rubric.toJson` (`0003`). Never changed once
    written: a change is the next version. -/
@[model (dbName := "repo_rubric") (primaryKey := ["owner", "name", "version"]) reviewdb]
structure RubricRow where
  owner : String
  name : String
  version : Int
  document : String
  created_at : String
  deriving Repr

/-- One write of a job's review: who wrote it — the agent, a person, or GitHub, as what it holds
    once posted — and the review as written (`0003`). `version` is the job's version the write
    made, so a revision is named by the job's history and no two share one. -/
@[model (dbName := "review_revision") (primaryKey := ["job_id", "version"]) reviewdb]
structure RevisionRow where
  job_id : String
  version : Int
  author : String
  review : String
  created_at : String
  deriving Repr

/-- What one trusted reviewer said of one commit of a pull request — every review they submitted
    of it, merged — kept to score the agent's review of the same commit against (`0004`). An import
    that finds another review of the group adds it; deleting the sample sets `deleted_at`, and the
    row stays, so that importing again neither brings it back nor adds to it. -/
@[model (dbName := "calibration_sample") (primaryKey := ["id"]) reviewdb]
structure SampleRow where
  id : String
  owner : String
  name : String
  pr_number : Int
  /-- GitHub's ids of the reviews merged into it, as a JSON array. -/
  review_ids : String
  reviewer : String
  /-- The strongest `state` of its reviews, as GitHub gave it: `CHANGES_REQUESTED`, then
      `APPROVED`, then `COMMENTED`. -/
  state : String
  body : String
  /-- The commit the review was of, and the base the pull request's diff had there. -/
  commit_id : String
  base_sha : String
  title : String
  pr_body : String
  /-- The review's inline comments on the new side of the diff, as a JSON array. -/
  comments : String
  /-- The review's comments that were not kept: on the old side, not on a line of the review's
      commit, or replies in a thread. -/
  dropped_left : Int
  dropped_outdated : Int
  dropped_replies : Int
  /-- What it is scored for: `full`; `partial`, when comments were dropped and its comments are
      not the whole of what was said, so that only its decision counts; `decision`, an approval or
      a request for changes that says nothing else. -/
  scope : String
  submitted_at : Option String
  imported_at : String
  updated_at : String
  deleted_at : Option String
  deriving Repr

/-- Every review an import has looked at and what became of it (`0004`): what makes importing
    idempotent by GitHub's review id — a review in here is never looked at again, whether it
    went into a sample or was dropped — so that importing again neither adds nor counts it. -/
@[model (dbName := "calibration_review") (primaryKey := ["owner", "name", "review_id"]) reviewdb]
structure ReviewSeenRow where
  owner : String
  name : String
  review_id : Int
  /-- `sample` (it went into `sample_id`), `empty`, `unreachable` or `deleted` (its group's
      sample had been deleted). -/
  outcome : String
  sample_id : Option String
  seen_at : String
  deriving Repr

/-- One calibration job's claim on its repository's daily cap (`0004`): one when a run makes it,
    and one each time a person runs it again. -/
@[model (dbName := "calibration_charge") (primaryKey := ["id"]) reviewdb]
structure ChargeRow where
  id : String
  owner : String
  name : String
  job_id : String
  charged_at : String
  deriving Repr

/-- A request to import the samples of a repository's recent closed pull requests, and how far
    the workers have got with it (`0004`). -/
@[model (dbName := "calibration_import") (primaryKey := ["id"]) reviewdb]
structure ImportRow where
  id : String
  owner : String
  name : String
  /-- How many recent closed pull requests to read. -/
  pull_limit : Int
  /-- `queued`, `running`, `done`, `failed` or `cancelled`. -/
  status : String
  /-- The pull requests to read, as a JSON array, once they have been listed. -/
  pulls : Option String
  /-- How many of `pulls` have been read. -/
  next_index : Int
  /-- How many times reading the next of them has failed; past 3 it is skipped. -/
  failures : Int
  /-- What was found so far, as a JSON object of counts. -/
  stats : String
  error : Option String
  requested_at : String
  updated_at : String
  deriving Repr

/-- A set of calibration jobs asked for together (`0004`). -/
@[model (dbName := "calibration_run") (primaryKey := ["id"]) reviewdb]
structure RunRow where
  id : String
  owner : String
  name : String
  /-- The samples it reviews, as a JSON array of ids. -/
  sample_ids : String
  created_at : String
  deriving Repr

/-- The score of one calibration job's review against its sample, by one version of the matcher
    (`0004`). A better matcher writes rows of its own version beside the old ones rather than over
    them. -/
@[model (dbName := "calibration_score") (primaryKey := ["job_id", "matcher_version"]) reviewdb]
structure ScoreRow where
  job_id : String
  matcher_version : Int
  run_id : Option String
  sample_id : String
  owner : String
  name : String
  rubric_version : Option Int
  /-- The score, as `Score.toJson`. -/
  score : String
  created_at : String
  /-- Whether the sample has grown since — a later review of its commit by its reviewer joined
      it — so that the score is of a sample that is no longer the whole of it. The score itself is
      left as it was; aggregates leave a stale one out unless asked. None is `false`. -/
  stale : Option Bool
  deriving Repr

/-- Calibration's jobs are found by their kind, among every review the platform has made. -/
def jobKindIndex : TableIndex String :=
  { name := "idx_review_job_kind", keys := [{ column := "kind" }] }

def target : DatabaseRecipe :=
  (%database reviewdb).recipe.withIndexes "review_job" [jobKindIndex]

/-- `0001_initial`: the repositories and the review jobs. -/
def migration0001 : Db.Migration.Migration where
  name := "0001_initial"
  steps := [
    .createTable "repo"
      { columns := .ofList
          [("owner", { type := .text, nullable := false }),
           ("name", { type := .text, nullable := false }),
           ("mode", { type := .text, nullable := false }),
           ("created_at", { type := .text, nullable := false })],
        primaryKey := ["owner", "name"] },
    .createTable "review_job"
      { columns := .ofList
          [("id", { type := .text, nullable := false }),
           ("owner", { type := .text, nullable := false }),
           ("name", { type := .text, nullable := false }),
           ("pr_number", { type := .int, nullable := false }),
           ("head_sha", { type := .text, nullable := true }),
           ("status", { type := .text, nullable := false }),
           ("queue_entry", { type := .text, nullable := true }),
           ("review", { type := .text, nullable := true }),
           ("version", { type := .int, nullable := false }),
           ("created_at", { type := .text, nullable := false }),
           ("updated_at", { type := .text, nullable := false })],
        primaryKey := ["id"] }]

/-- `0002_m1`: what queueing on orchestra and posting to GitHub keep — a repository's
    `auto_review`, a job's pull request metadata, last error, pull request type, attempts and
    posting record, and the diff cache. Every new column is nullable, so the rows `0001` wrote are
    valid as they are. -/
def migration0002 : Db.Migration.Migration where
  name := "0002_m1"
  steps := [
    .addColumn "repo" "auto_review" { type := .bool, nullable := true },
    .addColumn "review_job" "base_sha" { type := .text, nullable := true },
    .addColumn "review_job" "title" { type := .text, nullable := true },
    .addColumn "review_job" "pr_body" { type := .text, nullable := true },
    .addColumn "review_job" "error" { type := .text, nullable := true },
    .addColumn "review_job" "pr_type" { type := .text, nullable := true },
    .addColumn "review_job" "attempts" { type := .int, nullable := true },
    .addColumn "review_job" "post_started_at" { type := .text, nullable := true },
    .addColumn "review_job" "posted_url" { type := .text, nullable := true },
    .addColumn "review_job" "post_note" { type := .text, nullable := true },
    .addColumn "review_job" "posted_review" { type := .text, nullable := true },
    .createTable "pull_diff"
      { columns := .ofList
          [("owner", { type := .text, nullable := false }),
           ("name", { type := .text, nullable := false }),
           ("base_sha", { type := .text, nullable := false }),
           ("head_sha", { type := .text, nullable := false }),
           ("diff", { type := .text, nullable := false }),
           ("fetched_at", { type := .text, nullable := false })],
        primaryKey := ["owner", "name", "base_sha", "head_sha"] }]

/-- `0003_m2`: rubrics, and the history of each job's review — the rubric versions of a repository,
    a job's revisions, the rubric version a job was reviewed against, and the platform's own posts
    of it. The new columns are nullable: `rubric_version` is null for a job written before rubrics
    existed (a job reviewed against no rubric has 0), and the posting columns read as none yet. -/
def migration0003 : Db.Migration.Migration where
  name := "0003_m2"
  steps := [
    .addColumn "review_job" "rubric_version" { type := .int, nullable := true },
    .addColumn "review_job" "direct_posts" { type := .int, nullable := true },
    .addColumn "review_job" "post_direct" { type := .bool, nullable := true },
    .createTable "repo_rubric"
      { columns := .ofList
          [("owner", { type := .text, nullable := false }),
           ("name", { type := .text, nullable := false }),
           ("version", { type := .int, nullable := false }),
           ("document", { type := .text, nullable := false }),
           ("created_at", { type := .text, nullable := false })],
        primaryKey := ["owner", "name", "version"] },
    .createTable "review_revision"
      { columns := .ofList
          [("job_id", { type := .text, nullable := false }),
           ("version", { type := .int, nullable := false }),
           ("author", { type := .text, nullable := false }),
           ("review", { type := .text, nullable := false }),
           ("created_at", { type := .text, nullable := false })],
        primaryKey := ["job_id", "version"] }]

/-- `0004_m3`: calibration — a repository's trusted reviewers and the version of its settings, a
    job's kind with its sample and run (and an index on the kind), and the samples, the reviews
    imports have seen, imports, runs, charges on the daily cap and scores. The new columns
    are nullable: a repository written before has no trusted reviewers and is at version 1, and a
    job written before is a review. -/
def migration0004 : Db.Migration.Migration where
  name := "0004_m3"
  steps := [
    .addColumn "repo" "trusted_reviewers" { type := .text, nullable := true },
    .addColumn "repo" "version" { type := .int, nullable := true },
    .addColumn "review_job" "kind" { type := .text, nullable := true },
    .addColumn "review_job" "sample_id" { type := .text, nullable := true },
    .addColumn "review_job" "run_id" { type := .text, nullable := true },
    .createTable "calibration_sample"
      { columns := .ofList
          [("id", { type := .text, nullable := false }),
           ("owner", { type := .text, nullable := false }),
           ("name", { type := .text, nullable := false }),
           ("pr_number", { type := .int, nullable := false }),
           ("review_ids", { type := .text, nullable := false }),
           ("reviewer", { type := .text, nullable := false }),
           ("state", { type := .text, nullable := false }),
           ("body", { type := .text, nullable := false }),
           ("commit_id", { type := .text, nullable := false }),
           ("base_sha", { type := .text, nullable := false }),
           ("title", { type := .text, nullable := false }),
           ("pr_body", { type := .text, nullable := false }),
           ("comments", { type := .text, nullable := false }),
           ("dropped_left", { type := .int, nullable := false }),
           ("dropped_outdated", { type := .int, nullable := false }),
           ("dropped_replies", { type := .int, nullable := false }),
           ("scope", { type := .text, nullable := false }),
           ("submitted_at", { type := .text, nullable := true }),
           ("imported_at", { type := .text, nullable := false }),
           ("updated_at", { type := .text, nullable := false }),
           ("deleted_at", { type := .text, nullable := true })],
        primaryKey := ["id"] },
    .createTable "calibration_review"
      { columns := .ofList
          [("owner", { type := .text, nullable := false }),
           ("name", { type := .text, nullable := false }),
           ("review_id", { type := .int, nullable := false }),
           ("outcome", { type := .text, nullable := false }),
           ("sample_id", { type := .text, nullable := true }),
           ("seen_at", { type := .text, nullable := false })],
        primaryKey := ["owner", "name", "review_id"] },
    .createTable "calibration_charge"
      { columns := .ofList
          [("id", { type := .text, nullable := false }),
           ("owner", { type := .text, nullable := false }),
           ("name", { type := .text, nullable := false }),
           ("job_id", { type := .text, nullable := false }),
           ("charged_at", { type := .text, nullable := false })],
        primaryKey := ["id"] },
    .createTable "calibration_import"
      { columns := .ofList
          [("id", { type := .text, nullable := false }),
           ("owner", { type := .text, nullable := false }),
           ("name", { type := .text, nullable := false }),
           ("pull_limit", { type := .int, nullable := false }),
           ("status", { type := .text, nullable := false }),
           ("pulls", { type := .text, nullable := true }),
           ("next_index", { type := .int, nullable := false }),
           ("failures", { type := .int, nullable := false }),
           ("stats", { type := .text, nullable := false }),
           ("error", { type := .text, nullable := true }),
           ("requested_at", { type := .text, nullable := false }),
           ("updated_at", { type := .text, nullable := false })],
        primaryKey := ["id"] },
    .createTable "calibration_run"
      { columns := .ofList
          [("id", { type := .text, nullable := false }),
           ("owner", { type := .text, nullable := false }),
           ("name", { type := .text, nullable := false }),
           ("sample_ids", { type := .text, nullable := false }),
           ("created_at", { type := .text, nullable := false })],
        primaryKey := ["id"] },
    .createTable "calibration_score"
      { columns := .ofList
          [("job_id", { type := .text, nullable := false }),
           ("matcher_version", { type := .int, nullable := false }),
           ("run_id", { type := .text, nullable := true }),
           ("sample_id", { type := .text, nullable := false }),
           ("owner", { type := .text, nullable := false }),
           ("name", { type := .text, nullable := false }),
           ("rubric_version", { type := .int, nullable := true }),
           ("score", { type := .text, nullable := false }),
           ("created_at", { type := .text, nullable := false }),
           ("stale", { type := .bool, nullable := true })],
        primaryKey := ["job_id", "matcher_version"] },
    .createIndex "review_job" jobKindIndex]

/-- The migrations, in the order they are applied. Appended to, never edited. -/
def migrations : List Db.Migration.Migration :=
  [migration0001, migration0002, migration0003, migration0004]

/-- Where the database is. Set once at start-up (`serve --db`), and by the tests. -/
initialize pathRef : IO.Ref System.FilePath ← IO.mkRef (System.FilePath.mk "diff-reviewer.db")

/-- The paths whose schema this process has already brought up to date. -/
private initialize migratedRef : IO.Ref (List System.FilePath) ← IO.mkRef []

/-- Serialises opening the database: the first use migrates it, and the HTTP server answers
    requests on several threads. -/
private initialize storeMutex : Std.BaseMutex ← Std.BaseMutex.new

def setPath (p : System.FilePath) : IO Unit := pathRef.set p

private def configure : Sqlite.M Unit := do
  let db ← read
  SQLite.exec db "PRAGMA busy_timeout = 5000; PRAGMA journal_mode = WAL"

/-- Run a database computation against the configured database, migrating it first if this
    process has not yet.

    Serialised: SQLite has one writer, and a connection per call under one lock is simpler than a
    pool for a platform whose traffic is one person and a handful of agents. Each connection uses
    WAL and waits for a lock rather than failing, so another process — a backup, a later worker —
    reading the file does not turn requests into `SQLITE_BUSY` errors. -/
def run {α : Type} (x : Sqlite.M α) : IO α := do
  storeMutex.lock
  try
    let p ← pathRef.get
    unless (← migratedRef.get).contains p do
      let now := (← Std.Time.Timestamp.now).toSecondsSinceUnixEpoch.val
      Sqlite.runDB p do
        configure
        let _ ← Db.Migration.migrate migrations now
      migratedRef.modify (p :: ·)
    Sqlite.runDB p do
      configure
      x
  finally
    storeMutex.unlock

/-- `run`, inside one transaction: for a read and the write that depends on it. The lock keeps the
    threads of this process apart, and the transaction keeps out a second process on the same file
    — a `serve` started twice by mistake, a repair by hand — which the lock knows nothing of.

    `BEGIN IMMEDIATE` rather than the default deferred `BEGIN`: it takes the write lock before the
    read, so two processes cannot both read a job and then both try to write it, which in SQLite
    ends with one of them failing `SQLITE_BUSY` without waiting. -/
def transact {α : Type} (x : Sqlite.M α) : IO α :=
  run do
    let db ← read
    SQLite.exec db "BEGIN IMMEDIATE"
    try
      let a ← x
      SQLite.exec db "COMMIT"
      return a
    catch e =>
      try SQLite.exec db "ROLLBACK" catch _ => pure ()
      throw e

end DiffReviewer.Store