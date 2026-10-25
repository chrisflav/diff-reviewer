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
  /-- What the operator says of how the repository's reviews are written, in markdown, which the
      agent's instructions carry (`0005`); a row written before has none, which is nothing. -/
  style_notes : Option String
  /-- The share of new calibration samples, in percent, held out for measuring (`eval`); the rest
      are the `pool` that examples and proposals learn from (`0005`). None is 50. -/
  eval_share : Option Int
  /-- The version of the style notes the repository has (`NotesRow`), whose provenance a job's
      agent saw (`0005`); none is none yet. -/
  style_notes_version : Option Int
  /-- The pull request type every review of the repository is of, fixed by the operator rather
      than picked by the agent — what a fan-out needs before it is queued (`0006`); none lets the
      agent pick. -/
  pr_type : Option String
  /-- The most sub-runs one fan-out review may make (`0006`); none is 8. -/
  max_fanout : Option Int
  /-- Whether a new head of a pull request with a posted review is reviewed incrementally, the
      changes since that review only (`0007`); none is `true`. -/
  incremental : Option Bool
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
  /-- The version of the repository's style notes the agent was given when it read the job
      (`0005`), as `rubric_version` records the rubric it was checked against; none is none. -/
  notes_version : Option Int
  /-- The round of sub-runs the job is reviewed by, when its current attempt fanned out
      (`0006`); none for a job run as one run. Sub-runs of any other round are history. -/
  fanout_round : Option Int
  /-- An incremental re-review (`0007`): the job whose posted review it follows up, the head that
      review was of — the diff it reviews is from there — and the commits since, as a JSON array
      of `{"sha", "message"}`. None for a full review. -/
  previous_job : Option String
  incremental_since : Option String
  incremental_commits : Option String
  /-- Why a review that would have been incremental is a full one: the head the last review was
      of is not an ancestor of this one (a force-push) (`0007`). -/
  full_review_reason : Option String
  /-- The head the incremental decision above was made at (`0007`): made once a head, not on
      every pass a job waits; none before it is made. -/
  incremental_head : Option String
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
  /-- The calibration samples, and the pull requests (`owner/name#pr`), whose evidence the version
      was written from, as JSON arrays: those of the proposal it came from, and every earlier
      version's (`0005`). -/
  derived_samples : Option String
  derived_prs : Option String
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
  /-- `eval` (held out: what runs measure) or `pool` (what examples and proposals learn from),
      assigned once by a stable hash of the group (`0005`); none is not assigned yet. -/
  split : Option String
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
  /-- When GitHub's rate limit resets, while the import waits for it — refused for the limit, or
      paused under the reserve (`0005`); none otherwise. -/
  reset_at : Option String
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

/-- The last version of a deleted repository's settings (`0005`), so that registering it again
    goes on from there: a version is never given twice to one `owner/name`, and a page that read a
    version of the old registration cannot have its write taken for one of the new. -/
@[model (dbName := "repo_tombstone") (primaryKey := ["owner", "name"]) reviewdb]
structure TombstoneRow where
  owner : String
  name : String
  version : Int
  deleted_at : String
  deriving Repr

/-- A rubric document an agent proposed for a repository, from its calibration data, and what a
    person made of it (`0005`). Written once by the agent's submission; a person's decision sets
    `status` and `decided_at`, and an accepted one the rubric version it became. -/
@[model (dbName := "rubric_proposal") (primaryKey := ["id"]) reviewdb]
structure ProposalRow where
  id : String
  owner : String
  name : String
  /-- The `proposal` job that wrote it. -/
  job_id : String
  /-- The rubric version it was written from, 0 for none. -/
  base_version : Int
  /-- The proposed document, as `Rubric.toJson`. -/
  document : String
  /-- The style notes it proposes, if it proposes any, and the ones its agent was given when it
      first read its context (`ContextRow`), which applying its notes checks are still the
      repository's. -/
  style_notes : Option String
  base_style_notes : Option String
  /-- The calibration samples and the pull requests its context drew on, as JSON arrays. -/
  context_samples : Option String
  context_prs : Option String
  /-- Why, in markdown. -/
  rationale : String
  /-- `pending`, `accepted` or `rejected`. -/
  status : String
  created_at : String
  decided_at : Option String
  /-- The rubric version accepting it wrote. -/
  accepted_version : Option Int
  deriving Repr

/-- What a rubric proposal job's agent was first given (`0005`): the style notes it read, which
    accepting the proposal's notes checks are still the repository's, and the calibration samples
    its context drew on, which every rubric and style notes accepted from it record. -/
@[model (dbName := "proposal_context") (primaryKey := ["job_id"]) reviewdb]
structure ContextRow where
  job_id : String
  style_notes : String
  /-- A JSON array of sample ids, and one of pull requests (`owner/name#pr`). -/
  sample_ids : String
  prs : String
  read_at : String
  deriving Repr

/-- One version of a repository's style notes, and what they were derived from (`0005`). Kept by
    name, like the rubric's versions: deleting a repository keeps them, and registering it again
    goes on from the last, so provenance is never lost. -/
@[model (dbName := "repo_notes") (primaryKey := ["owner", "name", "version"]) reviewdb]
structure NotesRow where
  owner : String
  name : String
  version : Int
  notes : String
  /-- The samples and pull requests (`owner/name#pr`) the notes were derived from, by rubric
      proposals, as JSON arrays: this version's and every earlier one's. -/
  derived_samples : String
  derived_prs : String
  created_at : String
  deriving Repr

/-- One sub-run of a fan-out review (`0006`): the review of one category of the job's pull request
    type, or the default review beside them, run as an orchestra task of its own and submitted as
    a partial review, which the platform merges with the others into the job's draft. A job
    fanned out again — a person ran a failed one again — has a new `round`; the old rows stay, and
    count towards the day's spend. -/
@[model (dbName := "fanout_run") (primaryKey := ["id"]) reviewdb]
structure SubRunRow where
  id : String
  job_id : String
  owner : String
  name : String
  /-- The job's attempt the fan-out was made at: the current sub-runs are the latest round's. -/
  round : Int
  /-- Its place in the merge: the default first, then the categories as the rubric lists them. -/
  position : Int
  /-- Unique within the round, made of the category's name: what the agent names it by (`--job
      <job>.<key>`), and the end of its orchestra `external_id`. -/
  key : String
  /-- The category it reviews; none for the default review. -/
  category : Option String
  /-- `pending`, `queued`, `running`, `submitted`, `failed` or `cancelled`. -/
  status : String
  queue_entry : Option String
  /-- How many times it has been queued on orchestra. -/
  attempts : Int
  /-- What its orchestra `external_id`s start with: the job's own for the attempt that fanned
      out. -/
  external_base : String
  /-- The partial review it submitted, as `Review.toJson`. -/
  review : Option String
  error : Option String
  created_at : String
  updated_at : String
  deriving Repr

/-- Calibration's jobs are found by their kind, among every review the platform has made. -/
def jobKindIndex : TableIndex String :=
  { name := "idx_review_job_kind", keys := [{ column := "kind" }] }

/-- A job's sub-runs are found by the job. -/
def subRunJobIndex : TableIndex String :=
  { name := "idx_fanout_run_job", keys := [{ column := "job_id" }] }

def target : DatabaseRecipe :=
  (%database reviewdb).recipe.withIndexes "review_job" [jobKindIndex]
    |>.withIndexes "fanout_run" [subRunJobIndex]

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

/-- `0005_m4`: learned review style — a repository's style notes, their versions and the share
    of samples held out, each sample's split, the rubric proposals agents write from the
    calibration data with what each was given, the samples and pull requests each rubric version
    and notes version were derived from, and the notes version each job's agent was given — when
    the rate limit an import waits for resets, and the last settings version of each deleted
    repository, which registering it again goes on from. The new columns are nullable: a
    repository written before has no style notes and holds out half, a sample no split yet (it is
    given one when next read for a run, an example, a proposal or an aggregate), a rubric version
    is derived from nothing, a job was given no notes, and an import has no reset to wait for. -/
def migration0005 : Db.Migration.Migration where
  name := "0005_m4"
  steps := [
    .addColumn "repo" "style_notes" { type := .text, nullable := true },
    .addColumn "repo" "eval_share" { type := .int, nullable := true },
    .addColumn "repo" "style_notes_version" { type := .int, nullable := true },
    .addColumn "review_job" "notes_version" { type := .int, nullable := true },
    .addColumn "repo_rubric" "derived_samples" { type := .text, nullable := true },
    .addColumn "repo_rubric" "derived_prs" { type := .text, nullable := true },
    .addColumn "calibration_sample" "split" { type := .text, nullable := true },
    .addColumn "calibration_import" "reset_at" { type := .text, nullable := true },
    .createTable "proposal_context"
      { columns := .ofList
          [("job_id", { type := .text, nullable := false }),
           ("style_notes", { type := .text, nullable := false }),
           ("sample_ids", { type := .text, nullable := false }),
           ("prs", { type := .text, nullable := false }),
           ("read_at", { type := .text, nullable := false })],
        primaryKey := ["job_id"] },
    .createTable "repo_notes"
      { columns := .ofList
          [("owner", { type := .text, nullable := false }),
           ("name", { type := .text, nullable := false }),
           ("version", { type := .int, nullable := false }),
           ("notes", { type := .text, nullable := false }),
           ("derived_samples", { type := .text, nullable := false }),
           ("derived_prs", { type := .text, nullable := false }),
           ("created_at", { type := .text, nullable := false })],
        primaryKey := ["owner", "name", "version"] },
    .createTable "repo_tombstone"
      { columns := .ofList
          [("owner", { type := .text, nullable := false }),
           ("name", { type := .text, nullable := false }),
           ("version", { type := .int, nullable := false }),
           ("deleted_at", { type := .text, nullable := false })],
        primaryKey := ["owner", "name"] },
    .createTable "rubric_proposal"
      { columns := .ofList
          [("id", { type := .text, nullable := false }),
           ("owner", { type := .text, nullable := false }),
           ("name", { type := .text, nullable := false }),
           ("job_id", { type := .text, nullable := false }),
           ("base_version", { type := .int, nullable := false }),
           ("document", { type := .text, nullable := false }),
           ("style_notes", { type := .text, nullable := true }),
           ("base_style_notes", { type := .text, nullable := true }),
           ("context_samples", { type := .text, nullable := true }),
           ("context_prs", { type := .text, nullable := true }),
           ("rationale", { type := .text, nullable := false }),
           ("status", { type := .text, nullable := false }),
           ("created_at", { type := .text, nullable := false }),
           ("decided_at", { type := .text, nullable := true }),
           ("accepted_version", { type := .int, nullable := true })],
        primaryKey := ["id"] }]

/-- `0006_m5`: fan-out — a repository's fixed pull request type and its bound on sub-runs, the
    round of sub-runs a job is reviewed by, and the sub-runs of each fan-out review, found by
    their job. The new columns are nullable: a repository written before
    lets the agent pick its type and may fan out to 8 sub-runs. -/
def migration0006 : Db.Migration.Migration where
  name := "0006_m5"
  steps := [
    .addColumn "repo" "pr_type" { type := .text, nullable := true },
    .addColumn "repo" "max_fanout" { type := .int, nullable := true },
    .addColumn "review_job" "fanout_round" { type := .int, nullable := true },
    .createTable "fanout_run"
      { columns := .ofList
          [("id", { type := .text, nullable := false }),
           ("job_id", { type := .text, nullable := false }),
           ("owner", { type := .text, nullable := false }),
           ("name", { type := .text, nullable := false }),
           ("round", { type := .int, nullable := false }),
           ("position", { type := .int, nullable := false }),
           ("key", { type := .text, nullable := false }),
           ("category", { type := .text, nullable := true }),
           ("status", { type := .text, nullable := false }),
           ("queue_entry", { type := .text, nullable := true }),
           ("attempts", { type := .int, nullable := false }),
           ("external_base", { type := .text, nullable := false }),
           ("review", { type := .text, nullable := true }),
           ("error", { type := .text, nullable := true }),
           ("created_at", { type := .text, nullable := false }),
           ("updated_at", { type := .text, nullable := false })],
        primaryKey := ["id"] },
    .createIndex "fanout_run" subRunJobIndex]

/-- `0007_m6`: incremental re-review — a repository's switch for it, and a job's previous job, the
    head it reviews from with the commits since, and why it is a full review when it would have
    been incremental. The new columns are nullable: a repository written before reviews
    incrementally, and a job written before was a full review. -/
def migration0007 : Db.Migration.Migration where
  name := "0007_m6"
  steps := [
    .addColumn "repo" "incremental" { type := .bool, nullable := true },
    .addColumn "review_job" "previous_job" { type := .text, nullable := true },
    .addColumn "review_job" "incremental_since" { type := .text, nullable := true },
    .addColumn "review_job" "incremental_commits" { type := .text, nullable := true },
    .addColumn "review_job" "full_review_reason" { type := .text, nullable := true },
    .addColumn "review_job" "incremental_head" { type := .text, nullable := true }]

/-- The migrations, in the order they are applied. Appended to, never edited. -/
def migrations : List Db.Migration.Migration :=
  [migration0001, migration0002, migration0003, migration0004, migration0005, migration0006,
   migration0007]

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