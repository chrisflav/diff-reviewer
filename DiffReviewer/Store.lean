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
  /-- The version of the repository's rubric the review was checked against (`0003`). -/
  rubric_version : Option Int
  /-- How many times posting the review has been claimed: each a request to GitHub (`0003`); none
      is 0. -/
  post_attempts : Option Int
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

def target : DatabaseRecipe :=
  (%database reviewdb).recipe

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
    a job's revisions, the rubric version a job was reviewed against, and how many times posting
    it was attempted. The new columns are nullable: a job reviewed before rubrics existed was
    reviewed against none, and its attempts are not known. -/
def migration0003 : Db.Migration.Migration where
  name := "0003_m2"
  steps := [
    .addColumn "review_job" "rubric_version" { type := .int, nullable := true },
    .addColumn "review_job" "post_attempts" { type := .int, nullable := true },
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

/-- The migrations, in the order they are applied. Appended to, never edited. -/
def migrations : List Db.Migration.Migration := [migration0001, migration0002, migration0003]

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