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

/-- The migrations, in the order they are applied. Appended to, never edited. -/
def migrations : List Db.Migration.Migration := [migration0001]

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

end DiffReviewer.Store