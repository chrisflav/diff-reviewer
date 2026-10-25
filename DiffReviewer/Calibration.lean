import Lean.Data.Json
import DiffReviewer.Platform
import DiffReviewer.GitHub
import DiffReviewer.Score

open Lean (Json)

/-!
# Calibration

How good are the agent's reviews? Calibration answers it against the reviews the people a
repository trusts (`Repo.trustedReviewers`) wrote on its past pull requests:

  * **Import** (`requestImport`, then `importStep` on every pass of the workers). The recent closed
    pull requests are listed, and of each, the reviews by trusted reviewers and their inline
    comments are read. Each review becomes a **sample**: the commit it was of, the base the pull
    request had there (the merge base of its base and that commit, which is what GitHub's diff of
    the pull request showed), who wrote it, its state and body, and its comments on the new side of
    the diff at that commit. A comment on the old side, one not placed on a line of the review's
    commit, and a reply in a thread are dropped — the agent writes none of those — and counted. A
    comment GitHub calls outdated *now* is kept: it is placed by its `original_line` on the commit
    it was written against, which is the sample's, and dropping it would drop exactly the comments
    the author acted on. Importing is idempotent by GitHub's review id, deleted samples included,
    so importing again adds only what is new and never brings back what a person deleted. It reads
    a bounded number of pull requests a pass, and stops, to go on the next pass, when GitHub says
    its rate limit is reached.
  * **Runs** (`createRun`). A run asks for one `calibration` job per sample, at the sample's commit
    and with its base for the diff. The jobs go through the queue and the agent as any review does,
    with the same prompt and rubric — and a token narrowed to cloning and fetching from GitHub
    (`Workers.calibrationNarrowing`) — but the review is never posted (`Job.notPostable`), discovery
    never makes them `stale`, and they count toward a daily cap of their own
    (`maxCalibrationJobsPerDay`), checked with the run's creation in one transaction. What the
    agent is given names no sample and says nothing of the person's review.
  * **Scores** (`scoreJob`, and `scorePending` on every pass). When a calibration job's review is a
    draft, the agent's first draft is scored against its sample (`DiffReviewer.Score`) and kept per
    job and matcher version; runs and the repository are aggregates of those (`runJson`,
    `summaryJson`).
-/

namespace DiffReviewer.Calibration

open Db.Query.DSL
open Score (HumanComment)

/-! ## Samples -/

/-- One trusted reviewer's review of one commit of a pull request. -/
structure Sample where
  id          : String
  owner       : String
  name        : String
  prNumber    : Nat
  reviewId    : Nat
  reviewer    : String
  /-- GitHub's `state`, as it gave it. -/
  state       : String
  body        : String
  commitId    : String
  baseSha     : String
  title       : String
  prBody      : String
  /-- The comments kept, as stored: a JSON array of `HumanComment.toJson`. -/
  commentsRaw : String
  droppedLeft : Nat
  droppedOutdated : Nat
  droppedReplies  : Nat
  submittedAt : Option String
  importedAt  : String
  deletedAt   : Option String

def Sample.comments (s : Sample) : List HumanComment :=
  match Json.parse s.commentsRaw >>= (·.getArr?) with
  | .ok xs => xs.toList.filterMap (HumanComment.ofJson · |>.toOption)
  | .error _ => []

private def optStr : Option String → Json
  | some s => .str s
  | none   => .null

def Sample.toJson (s : Sample) : Json :=
  .mkObj [("id", s.id), ("owner", s.owner), ("name", s.name), ("prNumber", s.prNumber),
          ("reviewId", s.reviewId), ("reviewer", s.reviewer), ("state", s.state),
          ("body", s.body), ("commitId", s.commitId), ("baseSha", s.baseSha),
          ("title", s.title),
          ("comments", .arr (s.comments.map HumanComment.toJson).toArray),
          ("dropped", .mkObj [("left", s.droppedLeft), ("outdated", s.droppedOutdated),
                              ("replies", s.droppedReplies)]),
          ("submittedAt", optStr s.submittedAt), ("importedAt", s.importedAt)]

private def Sample.ofRow (r : Store.SampleRow) : Sample :=
  { id := r.id, owner := r.owner, name := r.name, prNumber := r.pr_number.toNat
  , reviewId := r.review_id.toNat, reviewer := r.reviewer, state := r.state, body := r.body
  , commitId := r.commit_id, baseSha := r.base_sha, title := r.title, prBody := r.pr_body
  , commentsRaw := r.comments, droppedLeft := r.dropped_left.toNat
  , droppedOutdated := r.dropped_outdated.toNat, droppedReplies := r.dropped_replies.toNat
  , submittedAt := r.submitted_at, importedAt := r.imported_at, deletedAt := r.deleted_at }

private def Sample.toRow (s : Sample) : Store.SampleRow :=
  { id := s.id, owner := s.owner, name := s.name, pr_number := s.prNumber
  , review_id := s.reviewId, reviewer := s.reviewer, state := s.state, body := s.body
  , commit_id := s.commitId, base_sha := s.baseSha, title := s.title, pr_body := s.prBody
  , comments := s.commentsRaw, dropped_left := s.droppedLeft
  , dropped_outdated := s.droppedOutdated, dropped_replies := s.droppedReplies
  , submitted_at := s.submittedAt, imported_at := s.importedAt, deleted_at := s.deletedAt }

private def fetchSamples (owner name : String) : Sqlite.M (Array Sample) := do
  let rows ← HasModel.fetch <| query% do
    let s ← from Store.SampleRow
    guard s.owner = owner
    guard s.name = name
    select s
  return rows.map Sample.ofRow

/-- The samples of `owner/name` not deleted, the most recently reviewed first. -/
def listSamples (owner name : String) : IO (Array Sample) := do
  let all ← Store.run (fetchSamples owner name)
  -- The id breaks ties between reviews submitted in the same second, so the order is total.
  let key (s : Sample) : String := s.submittedAt.getD s.importedAt
  return (all.filter (·.deletedAt.isNone)).qsort fun a b =>
    key a > key b || (key a == key b && a.id > b.id)

/-- Sample `id`, deleted or not. -/
def findSample (id : String) : IO (Option Sample) := do
  let rows ← Store.run <| HasModel.fetch <| query% do
    let s ← from Store.SampleRow
    guard s.id = id
    select s
  return rows[0]?.map Sample.ofRow

/-- Delete sample `id` of `owner/name`: it is no longer listed or picked for a run, and importing
    again does not bring it back. Its scores are kept, as the record of the runs that used it.
    Answers whether there was such a sample to delete. -/
def deleteSample (owner name id : String) : IO Bool := do
  let now ← nowIso
  Store.transact do
    let rows ← HasModel.fetch <| query% do
      let s ← from Store.SampleRow
      guard s.id = id
      select s
    let some r := rows[0]? | return false
    unless r.owner == owner && r.name == name && r.deleted_at.isNone do return false
    HasModel.save { r with deleted_at := some now }
    return true

/-- Store `s` unless a sample of the same GitHub review is stored already, deleted or not; the
    check and the write are one transaction. Answers whether it was stored. -/
private def insertSample (s : Sample) : IO Bool :=
  Store.transact do
    let known ← fetchSamples s.owner s.name
    if known.any (·.reviewId == s.reviewId) then return false
    HasModel.save s.toRow
    return true

/-! ## Imports -/

/-- What an import keeps of a pull request it is to read. -/
structure PullRef where
  number  : Nat
  title   : String
  body    : String
  baseSha : String

def PullRef.toJson (p : PullRef) : Json :=
  .mkObj [("number", p.number), ("title", p.title), ("body", p.body), ("baseSha", p.baseSha)]

def PullRef.ofJson (j : Json) : Except String PullRef := do
  return { number := ← j.getObjValAs? Nat "number", title := ← j.getObjValAs? String "title"
         , body := ← j.getObjValAs? String "body", baseSha := ← j.getObjValAs? String "baseSha" }

/-- The default and the most closed pull requests an import reads. -/
def defaultImportLimit : Nat := 50

def maxImportLimit : Nat := 200

/-- What an import counts, in this order. -/
def statKeys : List String :=
  ["pulls", "reviews", "imported", "known", "empty", "unreachable", "unreadable", "droppedLeft",
   "droppedOutdated", "droppedReplies"]

/-- A request to import, and how far it has got. -/
structure Import where
  id         : String
  owner      : String
  name       : String
  limit      : Nat
  /-- `queued`, `running`, `done` or `failed`. -/
  status     : String
  pulls      : Option (Array PullRef)
  nextIndex  : Nat
  stats      : List (String × Nat)
  error      : Option String
  requestedAt : String
  updatedAt  : String

def Import.stat (i : Import) (k : String) : Nat := ((i.stats.lookup k).getD 0)

def Import.toJson (i : Import) : Json :=
  .mkObj [("id", i.id), ("owner", i.owner), ("name", i.name), ("limit", i.limit),
          ("status", i.status),
          ("pullsListed", (i.pulls.map fun ps => (ps.size : Json)).getD .null),
          ("pullsRead", i.nextIndex),
          ("stats", .mkObj (statKeys.map fun k => (k, (i.stat k : Json)))),
          ("error", optStr i.error), ("requestedAt", i.requestedAt),
          ("updatedAt", i.updatedAt)]

private def Import.ofRow (r : Store.ImportRow) : Import :=
  let pulls := r.pulls.bind fun raw =>
    (Json.parse raw >>= (·.getArr?) >>= (·.mapM PullRef.ofJson)).toOption
  let stats := match Json.parse r.stats >>= (·.getObj?) with
    | .ok kvs => kvs.toList.filterMap fun (k, v) => (v.getNat?.toOption.map (k, ·))
    | .error _ => []
  { id := r.id, owner := r.owner, name := r.name, limit := r.pull_limit.toNat
  , status := r.status, pulls, nextIndex := r.next_index.toNat, stats, error := r.error
  , requestedAt := r.requested_at, updatedAt := r.updated_at }

private def Import.toRow (i : Import) : Store.ImportRow :=
  { id := i.id, owner := i.owner, name := i.name, pull_limit := i.limit, status := i.status
  , pulls := i.pulls.map fun ps => (Json.arr (ps.map PullRef.toJson)).compress
  , next_index := i.nextIndex
  , stats := (Json.mkObj (i.stats.map fun (k, v) => (k, (v : Json)))).compress
  , error := i.error, requested_at := i.requestedAt, updated_at := i.updatedAt }

private def fetchImports : Sqlite.M (Array Import) := do
  let rows ← HasModel.fetch <| query% do
    let i ← from Store.ImportRow
    select i
    order_by i.requested_at
    order_by i.id
  return rows.map Import.ofRow

/-- The imports of `owner/name`, newest first. -/
def importsOf (owner name : String) : IO (Array Import) := do
  return ((← Store.run fetchImports).filter fun i => i.owner == owner && i.name == name).reverse

private def active (i : Import) : Bool := i.status == "queued" || i.status == "running"

/-- Queue an import of the `limit` most recently updated closed pull requests of `repo`. One
    import of a repository runs at a time: while one is queued or running, another is refused
    with it (`.error`). -/
def requestImport (repo : Repo) (limit : Nat) : IO (Except Import Import) := do
  let now ← nowIso
  let i : Import :=
    { id := ← randomHex 8, owner := repo.owner, name := repo.name, limit, status := "queued"
    , pulls := none, nextIndex := 0, stats := [], error := none, requestedAt := now
    , updatedAt := now }
  Store.transact do
    if let some cur := (← fetchImports).find? fun j =>
        j.owner == repo.owner && j.name == repo.name && active j then
      return .error cur
    HasModel.save i.toRow
    return .ok i

private def saveImport (i : Import) : IO Import := do
  let i := { i with updatedAt := ← nowIso }
  Store.run (HasModel.save i.toRow)
  return i

private def addStats (a b : List (String × Nat)) : List (String × Nat) :=
  statKeys.filterMap fun k =>
    let v := (a.lookup k).getD 0 + (b.lookup k).getD 0
    if v == 0 then none else some (k, v)

/-- Why a pull request could not be read on this pass. -/
inductive ReadError where
  /-- GitHub's rate limit: nothing more is asked of it on this pass. -/
  | rateLimited (why : String)
  /-- No answer, or a `5xx`: the pull request is read again on the next pass. -/
  | retry (why : String)

private def readError (e : GitHub.Error) : ReadError :=
  match e with
  | .rateLimited why => .rateLimited why
  | e => .retry e.message

/-- Read pull request `p` of `repo` and store a sample for each review of it by a trusted
    reviewer that is not stored yet. Answers what it counted. A pull request GitHub refuses to
    show (a `4xx`) counts as `unreadable`, and a commit it cannot compare as `unreachable` — a
    force-push may have left it unreachable — so that neither holds the import up. -/
def importPull (gh : GitHub.Client) (repo : Repo) (p : PullRef) :
    IO (Except ReadError (List (String × Nat))) := do
  let trusted := repo.trustedReviewers
  let reviews ← match ← gh.listReviews repo.owner repo.name p.number with
    | .ok rs => pure rs
    | .error (.definite _) => return .ok [("unreadable", 1)]
    | .error e => return .error (readError e)
  let mine := reviews.filter fun r =>
    trusted.contains r.author.toLower && r.state != "PENDING" && validSha r.commitId
  if mine.isEmpty then return .ok []
  let known := (← Store.run (fetchSamples repo.owner repo.name)).map (·.reviewId)
  let fresh := mine.filter (!known.contains ·.id)
  let stats := [("reviews", mine.size), ("known", mine.size - fresh.size)]
  if fresh.isEmpty then return .ok stats
  let comments ← match ← gh.listReviewComments repo.owner repo.name p.number with
    | .ok cs => pure cs
    | .error (.definite _) => return .ok (addStats stats [("unreadable", 1)])
    | .error e => return .error (readError e)
  let mut stats := stats
  let mut bases : List (String × Option String) := []
  for r in fresh do
    let base ← match bases.lookup r.commitId with
      | some b => pure b
      | none =>
        let b ← match ← gh.mergeBase repo.owner repo.name p.baseSha r.commitId with
          | .ok b => pure (some b)
          | .error (.definite _) => pure none
          | .error e => return .error (readError e)
        bases := (r.commitId, b) :: bases
        pure b
    let some base := base
      | stats := addStats stats [("unreachable", 1)]
        continue
    let mut kept : Array HumanComment := #[]
    let mut left := 0
    let mut outdated := 0
    let mut replies := 0
    for c in comments do
      unless c.reviewId == some r.id do continue
      if c.inReplyTo.isSome then replies := replies + 1
      else if c.side == some "LEFT" || c.startSide == some "LEFT" then left := left + 1
      else match c.side, c.originalLine with
        | some "RIGHT", some line =>
          if !c.originalCommitId.isEmpty && c.originalCommitId != r.commitId then
            outdated := outdated + 1
          else
            let start := (c.originalStartLine.getD line)
            kept := kept.push { id := c.id, path := c.path, startLine := min start line, line
                              , body := c.body }
        | _, _ => outdated := outdated + 1
    stats := addStats stats [("droppedLeft", left), ("droppedOutdated", outdated),
                             ("droppedReplies", replies)]
    if kept.isEmpty && r.body.trimAscii.isEmpty then
      stats := addStats stats [("empty", 1)]
      continue
    let s : Sample :=
      { id := ← randomHex 8, owner := repo.owner, name := repo.name, prNumber := p.number
      , reviewId := r.id, reviewer := r.author.toLower, state := r.state, body := r.body
      , commitId := r.commitId, baseSha := base, title := p.title, prBody := p.body
      , commentsRaw := (Json.arr (kept.map HumanComment.toJson)).compress
      , droppedLeft := left, droppedOutdated := outdated, droppedReplies := replies
      , submittedAt := r.submittedAt, importedAt := ← nowIso, deletedAt := none }
    stats := addStats stats [(if ← insertSample s then "imported" else "known", 1)]
  return .ok stats

/-- Record `why` as the import's error, unless it is the one recorded: a failure repeated on every
    pass is written once. -/
private def importFailed (i : Import) (why : String) (status := i.status) : IO Import := do
  if i.error == some why && i.status == status then return i
  saveImport { i with error := some why, status }

/-- One pass of importing: the queued and running imports, oldest first, reading at most
    `budget` pull requests in all. Each pull request's outcome is written as soon as it is read,
    so a pass cut short loses nothing. GitHub's rate limit ends the pass: the import goes on where
    it stopped on the next. -/
def importStep (gh : GitHub.Client) (log : String → IO Unit) (budget : Nat) : IO Unit := do
  let mut budget := budget
  for i in (← Store.run fetchImports).filter active do
    if budget == 0 then return
    let some repo ← Platform.findRepo i.owner i.name
      | let _ ← importFailed i "the repository is no longer registered" "failed"
        continue
    if repo.trustedReviewers.isEmpty then
      let _ ← importFailed i "the repository names no trusted reviewers" "failed"
      continue
    let mut i := i
    let pulls ← match i.pulls with
      | some ps => pure ps
      | none =>
        match ← gh.listClosedPulls repo.owner repo.name i.limit with
        | .ok ps =>
          let ps := ps.map fun p =>
            ({ number := p.number, title := p.title, body := p.body, baseSha := p.baseSha }
              : PullRef)
          i ← saveImport { i with pulls := some ps, status := "running", error := none
                                  stats := addStats i.stats [("pulls", ps.size)] }
          log s!"calibration import {i.id} of {repo.slug}: {ps.size} closed pull request(s)"
          pure ps
        | .error (.rateLimited why) =>
          let _ ← importFailed i s!"GitHub's rate limit ({why}); it goes on by itself"
          return
        | .error (.definite why) =>
          let _ ← importFailed i s!"listing the closed pull requests: {why}" "failed"
          continue
        | .error e =>
          let _ ← importFailed i s!"listing the closed pull requests: {e.message}"
          continue
    while i.nextIndex < pulls.size && budget > 0 do
      let some p := pulls[i.nextIndex]? | break
      budget := budget - 1
      match ← importPull gh repo p with
      | .ok stats =>
        i ← saveImport { i with nextIndex := i.nextIndex + 1, stats := addStats i.stats stats
                                error := none }
      | .error (.rateLimited why) =>
        let _ ← importFailed i s!"GitHub's rate limit ({why}); it goes on by itself"
        return
      | .error (.retry why) =>
        i ← importFailed i s!"reading #{p.number}: {why}; it is read again on the next pass"
        break
    if i.nextIndex ≥ pulls.size then
      let _ ← saveImport { i with status := "done", error := none }
      log s!"calibration import {i.id} of {repo.slug} is done: {i.stat "imported"} new \
sample(s)"

/-! ## Runs -/

/-- The most samples one run reviews. -/
def maxRunSamples : Nat := 20

/-- A set of calibration jobs asked for together. -/
structure Run where
  id        : String
  owner     : String
  name      : String
  sampleIds : List String
  createdAt : String

private def Run.ofRow (r : Store.RunRow) : Run :=
  let ids := match Json.parse r.sample_ids >>= (·.getArr?) with
    | .ok xs => xs.toList.filterMap (·.getStr?.toOption)
    | .error _ => []
  { id := r.id, owner := r.owner, name := r.name, sampleIds := ids, createdAt := r.created_at }

/-- The runs of `owner/name`, newest first. -/
def runsOf (owner name : String) : IO (Array Run) := do
  let rows ← Store.run <| HasModel.fetch <| query% do
    let r ← from Store.RunRow
    guard r.owner = owner
    guard r.name = name
    select r
    order_by_desc r.created_at
    order_by_desc r.id
  return rows.map Run.ofRow

def findRun (owner name id : String) : IO (Option Run) := do
  return (← runsOf owner name).find? (·.id == id)

/-- The calibration jobs of `owner/name`. -/
def calibrationJobs (owner name : String) : IO (Array Job) := do
  return (← Platform.listJobs).filter fun j =>
    j.owner == owner && j.name == name && j.kind? == some .calibration

/-- `count` samples of `owner/name` for a run: those reviewed by the fewest calibration jobs so
    far, the most recently reviewed first among equals. -/
def pickSamples (owner name : String) (count : Nat) : IO (List String) := do
  let jobs ← calibrationJobs owner name
  let uses (s : Sample) : Nat := (jobs.filter (·.sampleId == some s.id)).size
  let samples ← listSamples owner name
  -- `listSamples` is newest first, and the sort is stable on the index it carries.
  let ranked := samples.zipIdx.qsort fun (a, i) (b, j) =>
    uses a < uses b || (uses a == uses b && i < j)
  return (ranked.toList.take count).map (·.1.id)

/-- Why a run was not made. -/
inductive RunError where
  | invalid (why : String)
  /-- The daily cap of calibration jobs would be passed. -/
  | capped (why : String)

/-- A run of `repo` over `sampleIds`: one `pending` calibration job for each, at the sample's
    commit and with its base. In one transaction with the checks that every sample is the
    repository's and not deleted, and that the jobs fit in what is left of `cap` — the calibration
    jobs of the repository made in the last 24 hours — so that two runs asked for at once cannot
    pass it together. -/
def createRun (repo : Repo) (sampleIds : List String) (cap : Nat) :
    IO (Except RunError (Run × Array Job)) := do
  let now ← nowIso
  let nowEpoch := (← Std.Time.Timestamp.now).toSecondsSinceUnixEpoch.val
  let since := isoOfEpoch (nowEpoch - 86400)
  let runId ← randomHex 8
  let ids ← sampleIds.mapM fun _ => randomHex 8
  Store.transact do
    let samples ← fetchSamples repo.owner repo.name
    let mut picked : Array Sample := #[]
    for sid in sampleIds do
      let some s := samples.find? fun s => s.id == sid && s.deletedAt.isNone
        | return .error (.invalid s!"'{sid}' is not a sample of {repo.slug}")
      picked := picked.push s
    let made ← Platform.jobsSinceIn repo.owner repo.name since .calibration
    if made + picked.size > cap then
      return .error (.capped s!"{repo.slug} has had {made} calibration job(s) in the last 24 \
hours; {picked.size} more would pass the most allowed, {cap} (--max-calibration-jobs-per-day)")
    let jobs : Array Job := Array.zipWith (fun (s : Sample) id =>
      ({ id := id, owner := repo.owner, name := repo.name, prNumber := s.prNumber
       , headSha := some s.commitId, baseSha := some s.baseSha, title := some s.title
       , prBody := some s.prBody, createdAt := now, updatedAt := now
       , kindRaw := some JobKind.calibration.toString, sampleId := some s.id
       , runId := some runId } : Job)) picked ids.toArray
    for j in jobs do HasModel.save j.toRow
    let run : Run :=
      { id := runId, owner := repo.owner, name := repo.name, sampleIds, createdAt := now }
    HasModel.save ({ id := runId, owner := repo.owner, name := repo.name
                   , sample_ids := (Json.arr (sampleIds.map Json.str).toArray).compress
                   , created_at := now } : Store.RunRow)
    return .ok (run, jobs)

/-! ## Scores -/

/-- The score of job `id` by the current matcher, as stored. -/
def scoreOf (id : String) : IO (Option Store.ScoreRow) := do
  let rows ← Store.run <| HasModel.fetch <| query% do
    let s ← from Store.ScoreRow
    guard s.job_id = id
    guard s.matcher_version = (Score.matcherVersion : Int)
    select s
  return rows[0]?

/-- The scores of `owner/name` by the current matcher. -/
def scoresOf (owner name : String) : IO (Array Store.ScoreRow) := do
  Store.run <| HasModel.fetch <| query% do
    let s ← from Store.ScoreRow
    guard s.owner = owner
    guard s.name = name
    guard s.matcher_version = (Score.matcherVersion : Int)
    select s

/-- Score calibration job `job` against its sample, by the current matcher, unless that is done:
    the agent's first draft — what it submitted, before anything a person did — against the
    trusted reviewer's review. Answers whether a score was written; nothing is written for a job
    that has no draft yet, or whose sample or draft cannot be read. -/
def scoreJob (job : Job) : IO Bool := do
  unless job.kind? == some .calibration do return false
  let some sid := job.sampleId | return false
  if (← scoreOf job.id).isSome then return false
  let some draft := (← Platform.revisions job.id).find? (·.author == Author.agent.toString)
    | return false
  let .ok review := Review.ofJsonString draft.reviewRaw | return false
  let some sample ← findSample sid | return false
  let s := Score.score review sample.state sample.comments
  Store.run <| HasModel.save
    ({ job_id := job.id, matcher_version := Score.matcherVersion, run_id := job.runId
     , sample_id := sid, owner := job.owner, name := job.name
     , rubric_version := job.rubricVersion.map Int.ofNat, score := s.toJson.compress
     , created_at := ← nowIso } : Store.ScoreRow)
  return true

/-- Score every calibration job that has a draft and no score by the current matcher: a job whose
    scoring on submission was missed, and every job again once the matcher changes. Answers how
    many were scored. -/
def scorePending : IO Nat := do
  let mut n := 0
  for j in ← Platform.listJobs do
    if j.kind? == some .calibration && (← scoreJob j) then n := n + 1
  return n

/-! ## What is read -/

private def aggregateOf (rows : Array Store.ScoreRow) : Score.Aggregate :=
  rows.foldl (init := {}) fun a r =>
    match Json.parse r.score with
    | .ok j => (a.add j).getD a
    | .error _ => a

/-- How many of `jobs` are in each status, as `{status: n}`. -/
private def statusCounts (jobs : Array Job) : Json :=
  let names := (jobs.map (·.statusRaw)).toList.eraseDups
  .mkObj (names.map fun s => (s, ((jobs.filter (·.statusRaw == s)).size : Json)))

/-- A run, with its aggregate; with `detail`, each of its jobs beside its sample and its score. -/
def runJson (run : Run) (detail : Bool) : IO Json := do
  let jobs := (← calibrationJobs run.owner run.name).filter (·.runId == some run.id)
  let scores := (← scoresOf run.owner run.name).filter (·.run_id == some run.id)
  let fields : List (String × Json) :=
    [("id", run.id), ("owner", run.owner), ("name", run.name), ("createdAt", run.createdAt),
     ("samples", run.sampleIds.length), ("jobs", statusCounts jobs),
     ("aggregate", (aggregateOf scores).toJson)]
  unless detail do return .mkObj fields
  let results ← jobs.mapM fun j => do
    let sample ← match j.sampleId with
      | some sid => findSample sid
      | none => pure none
    let score := (scores.find? (·.job_id == j.id)).bind fun r => (Json.parse r.score).toOption
    return Json.mkObj [
      ("jobId", j.id), ("status", j.statusRaw), ("error", optStr j.error),
      ("rubricVersion", (j.rubricVersion.map fun v => (v : Json)).getD .null),
      ("prType", optStr j.prType),
      ("sample", (sample.map fun s => Json.mkObj [("id", s.id), ("prNumber", s.prNumber),
        ("reviewer", s.reviewer), ("state", s.state), ("commitId", s.commitId),
        ("title", s.title), ("comments", s.comments.length),
        ("deleted", s.deletedAt.isSome)]).getD .null),
      ("score", score.getD .null)]
  return .mkObj (fields ++ [("results", .arr results)])

/-- The aggregate over every scored calibration job of `owner/name`, and the same for each rubric
    version the jobs were reviewed against (`null`: before rubrics), newest version first. -/
def summaryJson (owner name : String) : IO Json := do
  let scores ← scoresOf owner name
  let versions := ((scores.map (·.rubric_version)).toList.eraseDups.toArray.qsort fun a b =>
    a.getD (-1) > b.getD (-1)).toList
  return .mkObj [
    ("owner", owner), ("name", name), ("runs", (← runsOf owner name).size),
    ("samples", (← listSamples owner name).size),
    ("overall", (aggregateOf scores).toJson),
    ("byRubricVersion", .arr (versions.map fun v =>
      Json.mkObj [("rubricVersion", (v.map fun n => (n.toNat : Json)).getD .null),
        ("aggregate", (aggregateOf (scores.filter (·.rubric_version == v))).toJson)]).toArray)]

end DiffReviewer.Calibration