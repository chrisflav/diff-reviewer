import Lean.Data.Json
import DiffReviewer.Types
import DiffReviewer.Rubric
import DiffReviewer.Platform

open Lean (Json)

/-!
# Fan-out: one review, run as one sub-run per category

A long rubric with many categories asks one run to hold all of them in mind at once, and the
categories it reaches last get the least of it. A pull request type — or the document, for every
review — that sets `fanout: true` is reviewed instead by **sub-runs** side by side: one per
category of the type, each told to look only at its category and to file every comment under it,
and one by the default rubric for what no category covers. Each is an orchestra task of its own,
and submits a partial review through the agent API, bound to its job and to itself
(`X-Diff-Reviewer-Job: <job>.<key>`). The platform merges the partial reviews into the job's
draft (`merge`), which then goes on as any draft does: a person edits and approves it, a `direct`
repository posts it, a calibration job is scored on it.

## Which type

The agent picks a pull request's type while it reviews it, but the sub-runs are what reviews it,
and they must be queued — each told its category — before any agent has read the change. Three
ways out were weighed:

  * a classifying run first, which picks the type, after which the platform fans out: correct, but
    every review waits for a run before its real runs start, the platform follows two phases, and
    the type is picked by a run that has read the least of the change;
  * fanning out by the default rubric's categories only: there are none — categories are a
    type's — and a type's own `fanout` could never be honoured;
  * the operator fixes the type per repository (`Repo.prType`).

The last is the simplest that is correct: the type is known when the job is queued, nothing runs
twice, and nothing waits. A repository with one kind of change — or that wants its reviews fanned
out — names it; one that does not keeps the agent's pick and its reviews are single runs, unless
the document's own `fanout` asks for every review to fan out: then, with no type fixed, the
sub-runs are one per category of the whole document, as a review of no type may use
(`Rubric.fanoutPlan`).

## Merging

When every sub-run has submitted, or the rest have failed past their retry, the partial reviews
are merged (`merge`):

  * **the comments** are the union, the default's first and then each category's in the
    rubric's order. Two comments are one when they are on the same file, their line ranges
    overlap, and their bodies are near-identical: of the sets of their words — lower case,
    letters and digits — the common words are at least four fifths of all (`nearIdentical`). The
    one kept is the more severe, the earlier of two alike, in the earlier's place.
  * **the ids** stay unique: the first comment to carry an id keeps it, and a later one with the
    same id is given a fresh one.
  * **the summary** is the default's, then each category's under its name; a sub-run that failed
    is named as not reviewed.
  * **the decision** is the strictest: a request for changes over a comment over an approval —
    and never an approval when a sub-run failed, since part of the change went unread.
  * **the cap** of `maxInlineComments` is kept by dropping the least severe comments first (no
    severity counts as the least), the last of them first, and the summary says how many.

A job that fails every sub-run fails. Until it is merged the job is `running` (`queued` until a
sub-run starts), and its sub-runs' states are shown on it (`subRuns`).

## Spend

Every sub-run counts against its repository's daily cap of jobs — `--max-jobs-per-day` for a
review, `--max-calibration-jobs-per-day` for a calibration job — in place of the one its job
counted for, checked in the transaction that makes them: past it the job waits, `pending`, with
why. A fan-out that would make more sub-runs than the repository's `maxFanout` (8 by default) is
refused: the job fails, saying so.
-/

namespace DiffReviewer.Fanout

open Db.Query.DSL

/-! ## Sub-runs -/

/-- The states of a sub-run. `submitted`, `failed` and `cancelled` are final. -/
def finalStatuses : List String := ["submitted", "failed", "cancelled"]

/-- The states in which a sub-run is on orchestra, or about to be. -/
def liveStatuses : List String := ["pending", "queued", "running"]

/-- How many times a sub-run is queued at most: its first run, and one more when that ends
    without a submission. Past it the sub-run has failed, and the review is merged without it. -/
def maxAttempts : Nat := 2

structure SubRun where
  id           : String
  jobId        : String
  owner        : String
  name         : String
  round        : Nat
  position     : Nat
  key          : String
  /-- The category it reviews; `none` for the default review. -/
  category     : Option String
  status       : String := "pending"
  queueEntry   : Option String := none
  attempts     : Nat := 0
  externalBase : String
  reviewRaw    : Option String := none
  error        : Option String := none
  createdAt    : String
  updatedAt    : String
  deriving Repr, Inhabited

def SubRun.ofRow (r : Store.SubRunRow) : SubRun :=
  { id := r.id, jobId := r.job_id, owner := r.owner, name := r.name, round := r.round.toNat
  , position := r.position.toNat, key := r.key, category := r.category, status := r.status
  , queueEntry := r.queue_entry, attempts := r.attempts.toNat, externalBase := r.external_base
  , reviewRaw := r.review, error := r.error, createdAt := r.created_at
  , updatedAt := r.updated_at }

def SubRun.toRow (s : SubRun) : Store.SubRunRow :=
  { id := s.id, job_id := s.jobId, owner := s.owner, name := s.name, round := s.round
  , position := s.position, key := s.key, category := s.category, status := s.status
  , queue_entry := s.queueEntry, attempts := s.attempts, external_base := s.externalBase
  , review := s.reviewRaw, error := s.error, created_at := s.createdAt
  , updated_at := s.updatedAt }

def SubRun.isFinal (s : SubRun) : Bool := finalStatuses.contains s.status

/-- The id an agent names the sub-run by (`--job`), `<job>.<key>`. -/
def SubRun.agentId (s : SubRun) : String := s!"{s.jobId}.{s.key}"

/-- Orchestra's id for the sub-run's current attempt: `<base>.<key>` for the first, and
    `<base>.<key>.<n>` for the `n`th, since orchestra answers an id it has seen with the entry it
    made. `base` is the job's own external id for the attempt that fanned out. -/
def SubRun.externalId (s : SubRun) : String :=
  if s.attempts == 0 then s!"{s.externalBase}.{s.key}"
  else s!"{s.externalBase}.{s.key}.{s.attempts + 1}"

/-- The partial review it submitted: `none` when there is none. -/
def SubRun.review? (s : SubRun) : Option (Except String Review) :=
  s.reviewRaw.map Review.ofJsonString

private def optStr : Option String → Json
  | some s => .str s
  | none => .null

/-- What the job's answer shows of a sub-run. -/
def SubRun.toJson (s : SubRun) : Json :=
  let comments : Json := match s.review? with
    | some (.ok r) => (r.comments.length : Json)
    | _ => .null
  .mkObj [("key", s.key), ("category", optStr s.category), ("status", s.status),
          ("queueEntry", optStr s.queueEntry), ("attempts", s.attempts),
          ("error", optStr s.error), ("comments", comments), ("updatedAt", s.updatedAt)]

/-! ## Keys -/

/-- `name` as a key: lower case, letters and digits, other runs of characters one `-`, at most 40
    characters; one that is empty or all digits is prefixed with `c`, so that a key never reads as
    an attempt's number in an external id. -/
def slug (name : String) : String := Id.run do
  let mut out : List Char := []
  for c in name.toLower.toList do
    if c.isAlphanum && c.toNat < 128 then out := out ++ [c]
    else if !out.isEmpty && out.getLast? != some '-' then out := out ++ ['-']
  let s := String.ofList ((out.reverse.dropWhile (· == '-')).reverse.take 40)
  let s := (s.dropEndWhile (· == '-')).toString
  if s.isEmpty || s.all Char.isDigit then "c" ++ s else s

/-- The keys of a plan's sub-runs, in order: `default` for the default review, then each
    category's `slug`, with `-2`, `-3`, … after one already taken. -/
def keysOf (categories : List String) : List String := Id.run do
  let mut used : List String := ["default"]
  let mut out : List String := ["default"]
  for c in categories do
    let base := slug c
    let mut k := base
    let mut n := 2
    while used.contains k do
      k := s!"{base}-{n}"
      n := n + 1
    used := k :: used
    out := out ++ [k]
  return out

/-! ## Merging -/

/-- A sub-run's part in the merge: its category (`none`, the default) and its review, `none` when
    it failed. -/
structure Part where
  category : Option String
  review   : Option Review

/-- How severe a comment is, for keeping the more severe of two and dropping the least severe
    first: no severity is below `nit`. -/
def severityRank : Option Severity → Nat
  | none => 0
  | some .nit => 1
  | some .minor => 2
  | some .major => 3
  | some .blocker => 4

/-- How strict a decision is: an approval, a comment, a request for changes. -/
def decisionRank : Decision → Nat
  | .approve => 0
  | .comment => 1
  | .requestChanges => 2

/-- The words of a comment's body, for comparing two: lower case, letters and digits. -/
def words (s : String) : List String :=
  ((s.toLower.map fun c => if c.isAlphanum then c else ' ').splitOn " ").filter (!·.isEmpty)
    |>.eraseDups

/-- Whether two bodies say near enough the same: of all the words of the two, at least four
    fifths are in both. Two empty bodies are the same. -/
def nearIdentical (a b : String) : Bool :=
  let (wa, wb) := (words a, words b)
  let common := (wa.filter wb.contains).length
  let all := wa.length + wb.length - common
  all == 0 || 5 * common ≥ 4 * all

/-- Whether `a` and `b` are one comment: on the same file, overlapping lines, near-identical
    bodies. -/
def duplicate (a b : InlineComment) : Bool :=
  a.file == b.file && a.range.startLine ≤ b.range.endLine &&
    b.range.startLine ≤ a.range.endLine && nearIdentical a.body b.body

/-- `cs` with every duplicate merged into the first of its kind, which takes the more severe of
    the two in its place; answers how many were merged. -/
def dedupe (cs : List InlineComment) : List InlineComment × Nat := Id.run do
  let mut kept : Array InlineComment := #[]
  let mut merged := 0
  for c in cs do
    match kept.findIdx? (duplicate · c) with
    | some i =>
      merged := merged + 1
      if let some k := kept[i]? then
        if severityRank c.severity > severityRank k.severity then kept := kept.set! i c
    | none => kept := kept.push c
  return (kept.toList, merged)

/-- `cs` with the id of every comment after the first that carries it cleared, for
    `Review.assignIds` to give a fresh one. -/
def uniqueIds (cs : List InlineComment) : List InlineComment := Id.run do
  let mut seen : List String := []
  let mut out : Array InlineComment := #[]
  for c in cs do
    match c.id with
    | some i =>
      if seen.contains i then out := out.push { c with id := none }
      else
        seen := i :: seen
        out := out.push c
    | none => out := out.push c
  return out.toList

/-- `cs` cut to `cap`: the least severe dropped first, and of those the last first. Answers what
    was dropped, by severity. -/
def capComments (cs : List InlineComment) (cap : Nat) :
    List InlineComment × List (Option Severity × Nat) := Id.run do
  if cs.length ≤ cap then return (cs, [])
  let order := cs.zipIdx.toArray.qsort fun (a, i) (b, j) =>
    severityRank a.severity < severityRank b.severity ||
      (severityRank a.severity == severityRank b.severity && i > j)
  let dropped : List (InlineComment × Nat) := (order.extract 0 (cs.length - cap)).toList
  let gone := dropped.map (·.2)
  let kept := (cs.zipIdx.filter fun (p : InlineComment × Nat) => !gone.contains p.2).map (·.1)
  let bySeverity := ([none] ++ Severity.all.map some).filterMap fun (sev : Option Severity) =>
    let n := (dropped.filter fun (p : InlineComment × Nat) => p.1.severity == sev).length
    if n == 0 then none else some (sev, n)
  return (kept, bySeverity)

/-- How a category is named in the merged summary. -/
private def heading : Option String → String
  | none => "General"
  | some c => c

/-- The merged review of `parts` (see "Merging" above), its ids not yet all assigned: give it to
    `Review.assignIds`. At least one part must have a review. -/
def merge (parts : List Part) (cap : Nat := maxInlineComments) : Review :=
  let reviews := parts.filterMap (·.review)
  let failed := parts.filter (·.review.isNone)
  let (comments, _) := dedupe (reviews.flatMap (·.comments))
  let comments := uniqueIds comments
  let (comments, dropped) := capComments comments cap
  let strictest := reviews.foldl (fun d r => if decisionRank r.decision > decisionRank d then
    r.decision else d) Decision.approve
  let decision := if !failed.isEmpty && strictest == .approve then Decision.comment else strictest
  let sections := parts.filterMap fun p => p.review.bind fun r =>
    let b := r.body.trimAscii.toString
    if b.isEmpty then none
    else if p.category.isNone then some b
    else some s!"**{heading p.category}.** {b}"
  let notReviewed := failed.map fun p =>
    s!"_Not reviewed: the {(heading p.category).toLower} review did not finish._"
  let droppedNote := if dropped.isEmpty then [] else
    let total := dropped.foldl (fun n (_, k) => n + k) 0
    let parts := dropped.map fun (sev, k) => s!"{(sev.map (·.toString)).getD "no severity"}: {k}"
    [s!"_{total} comment(s) were dropped to stay within {cap} inline comments, the least severe \
first ({", ".intercalate parts})._"]
  let body := "\n\n".intercalate (sections ++ notReviewed ++ droppedNote)
  let body := if body.isEmpty && decision != .approve then
    "Reviewed category by category; see the inline comments." else body
  { decision, body, comments }

/-! ## The store -/

/-- Every sub-run of job `jobId`, of every round, in round and merge order. -/
def fetchAll (jobId : String) : Sqlite.M (Array SubRun) := do
  let rows ← HasModel.fetch <| query% do
    let s ← from Store.SubRunRow
    guard s.job_id = jobId
    select s
  let subs := rows.map SubRun.ofRow
  return subs.qsort fun a b => a.round < b.round || (a.round == b.round && a.position < b.position)

/-- The current sub-runs of job `jobId`: those of its latest round, in merge order; none for a
    job that is not fanned out. -/
def fetchCurrent (jobId : String) : Sqlite.M (Array SubRun) := do
  let all ← fetchAll jobId
  let some last := all.back? | return #[]
  return all.filter (·.round == last.round)

def current (jobId : String) : IO (Array SubRun) := Store.run (fetchCurrent jobId)

/-- The current sub-runs of every job of `owner/name` that has any, by job; or of every
    repository with `none`. -/
def currentByJob (repo : Option (String × String) := none) :
    IO (List (String × Array SubRun)) := do
  let rows ← Store.run <| HasModel.fetch <| query% do
    let s ← from Store.SubRunRow
    select s
  let subs := (rows.map SubRun.ofRow).filter fun s =>
    repo.all fun (o, n) => s.owner == o && s.name == n
  let jobs := (subs.map (·.jobId)).toList.eraseDups
  return jobs.map fun j =>
    let mine := subs.filter (·.jobId == j)
    let last := mine.foldl (fun r s => max r s.round) 0
    (j, (mine.filter (·.round == last)).qsort (·.position < ·.position))

/-- How many sub-runs of `owner/name` were made at or after `since`, and the jobs that ever had
    any: with the jobs that never did, what a repository has spent of a day's cap. -/
def madeSinceIn (owner name since : String) : Sqlite.M (Nat × List String) := do
  let rows ← HasModel.fetch <| query% do
    let s ← from Store.SubRunRow
    guard s.owner = owner
    guard s.name = name
    select s
  return ((rows.filter (·.created_at ≥ since)).size, (rows.map (·.job_id)).toList.eraseDups)

/-- What `owner/name` has spent of its daily cap of review jobs since `since`: one for each review
    job made since that was never fanned out, and one for each sub-run of a review job made
    since. -/
def reviewSpendIn (owner name since : String) : Sqlite.M Nat := do
  let rows ← HasModel.fetch <| query% do
    let j ← from Store.JobRow
    guard j.owner = owner
    guard j.name = name
    select j
  let jobs := rows.map Job.ofRow
  let reviews := (jobs.filter (·.isReview)).map (·.id)
  let subs ← HasModel.fetch <| query% do
    let s ← from Store.SubRunRow
    guard s.owner = owner
    guard s.name = name
    select s
  let fanned := (subs.map (·.job_id)).toList.eraseDups
  let single := jobs.filter fun j => j.isReview && j.createdAt ≥ since && !fanned.contains j.id
  let subsSince := subs.filter fun s => s.created_at ≥ since && reviews.contains s.job_id
  return single.size + subsSince.size

def reviewSpend (owner name since : String) : IO Nat := Store.run (reviewSpendIn owner name since)

/-- The check of `owner/name`'s daily cap of review jobs for review job `job` fanned out to `size`
    sub-runs, inside the transaction that makes them: its sub-runs count in place of the job, which
    counted for one if it was made since `since` and never fanned out. Why not, when they would
    pass `cap`. -/
def reviewChargeIn (job : Job) (size cap : Nat) (since : String) :
    Sqlite.M (Except String Unit) := do
  let spent ← reviewSpendIn job.owner job.name since
  let (_, fanned) ← madeSinceIn job.owner job.name since
  let self := if job.createdAt ≥ since && !fanned.contains job.id then 1 else 0
  if spent - self + size > cap then
    return .error s!"{job.owner}/{job.name} has spent {spent} of its {cap} review jobs in the last \
24 hours (--max-jobs-per-day), each sub-run of a fan-out counting as one; this review's {size} \
sub-runs would pass it, and wait"
  return .ok ()

/-- Why a fan-out was not begun. -/
inductive BeginError where
  /-- The job moved on meanwhile. -/
  | moved
  /-- The day's cap would be passed: the job waits, with why. -/
  | capped (why : String)

/-- Fan job `job`, read `pending`, out by `plan` under rubric version `rubricVersion`: in one
    transaction with the check that it is still `pending` at the version read, and `charge` —
    the check of the day's cap for the sub-runs and its charge, answering why not — a new round
    of `pending` sub-runs, their external ids under `base`, and the job `queued`, of the plan's
    type and rubric version, with what queueing learnt of its pull request (`learnt`). -/
def begin (job : Job) (learnt : Job → Job) (plan : FanoutPlan) (rubricVersion : Nat)
    (base : String) (charge : Sqlite.M (Except String Unit)) :
    IO (Except BeginError (Job × Array SubRun)) := do
  let now ← nowIso
  let keys := keysOf (plan.categories.map (·.name))
  let ids ← keys.mapM fun _ => randomHex 8
  Store.transact do
    let some j ← Platform.fetchJob job.id | return .error .moved
    unless j.status? == some .pending && j.version == job.version do return .error .moved
    if let .error why ← charge then return .error (.capped why)
    let categories : List (Option String) := none :: plan.categories.map (some ·.name)
    let subs : Array SubRun := ((categories.zip keys).zip ids).toArray.zipIdx.map
      fun (((category, key), id), i) =>
        { id, jobId := j.id, owner := j.owner, name := j.name, round := j.attempts
        , position := i, key, category, externalBase := base, createdAt := now
        , updatedAt := now }
    for s in subs do HasModel.save s.toRow
    let next := { learnt j with
      statusRaw := JobStatus.queued.toString, queueEntry := none, attempts := j.attempts + 1
      error := none, prType := plan.prType, rubricVersion := some rubricVersion
      version := j.version + 1, updatedAt := now }
    HasModel.save next.toRow
    return .ok (next, subs)

/-- Change sub-run `id` with `f`, given its job, in one transaction; `f` answers why not. -/
def update (id : String) (f : Job → SubRun → Except String SubRun) :
    IO (Except String SubRun) := do
  let now ← nowIso
  Store.transact do
    let rows ← HasModel.fetch <| query% do
      let s ← from Store.SubRunRow
      guard s.id = id
      select s
    let some row := rows[0]? | return .error s!"sub-run {id} is gone"
    let s := SubRun.ofRow row
    let some job ← Platform.fetchJob s.jobId | return .error s!"job {s.jobId} is gone"
    match f job s with
    | .error e => return .error e
    | .ok next =>
      let next := { next with updatedAt := now }
      HasModel.save next.toRow
      return .ok next

/-- Record `why` as sub-run `s`'s error while it is still `status`, unless it is recorded already:
    a failure repeated on every pass is written once. -/
def recordError (s : SubRun) (status : String) (why : String) : IO Unit := do
  if s.error == some why then return
  let _ ← update s.id fun _ cur => do
    unless cur.status == status do throw "moved on"
    return { cur with error := some why }

/-- Mark every live sub-run of job `jobId`'s current round `cancelled`, with why; answers their
    queue entries, for their runs to be cancelled. -/
def cancelLive (jobId why : String) : IO (List String) := do
  let now ← nowIso
  Store.transact do
    let subs ← fetchCurrent jobId
    let live := subs.filter (liveStatuses.contains ·.status)
    for s in live do
      HasModel.save { s with status := "cancelled", error := some why, updatedAt := now }.toRow
    return (live.filterMap (·.queueEntry)).toList

/-- What settling a fan-out job came to. -/
inductive Settled where
  /-- Sub-runs are still to submit or fail, or the job has moved on. -/
  | waiting
  /-- The merged review is the job's draft. -/
  | drafted (job : Job)
  /-- Every sub-run failed, or the merge could not be made: the job failed. -/
  | failed (job : Job)

/-- Settle fan-out job `jobId`: once every current sub-run is final, merge their partial reviews
    into its draft — written as the agent's, the first revision of its history, which is what a
    calibration job is scored on — or, when none submitted one, fail it. The job must still be
    `queued` or `running` at the version read, which keeps two settlements from both writing. -/
def settle (jobId : String) : IO Settled := do
  let some job ← Platform.findJob jobId | return .waiting
  unless job.status? == some .queued || job.status? == some .running do return .waiting
  let subs ← current jobId
  if subs.isEmpty || !subs.all (·.isFinal) then return .waiting
  let parts : List Part := subs.toList.map fun s =>
    { category := s.category
    , review := if s.status == "submitted" then
        match s.review? with
        | some (.ok r) => some r
        | _ => none
      else none }
  let write (f : Job → Job) (revision : Job → Option (Author × String) := fun _ => none) :
      IO (Option Job) := do
    match ← Platform.updateJob jobId (revision := revision) fun j => do
        unless j.version == job.version &&
            (j.status? == some .queued || j.status? == some .running) do
          throw (.conflict "moved on")
        return f j
    with
    | .ok j => return some j
    | .error _ => return none
  if parts.all (·.review.isNone) then
    let why := "; ".intercalate (subs.toList.map fun s =>
      s!"{s.key}: {s.error.getD s.status}")
    match ← write fun j => { j with statusRaw := JobStatus.failed.toString
                                    error := some s!"every sub-run failed ({why})" } with
    | some j => return .failed j
    | none => return .waiting
  let merged ← (merge parts).assignIds
  if let .error e := merged.validate then
    match ← write fun j => { j with statusRaw := JobStatus.failed.toString
                                    error := some s!"the sub-runs' reviews do not merge: {e}" } with
    | some j => return .failed j
    | none => return .waiting
  match ← write (revision := Job.revisionBy .agent) fun j =>
      { j.setReview merged with statusRaw := JobStatus.draft.toString, error := none } with
  | some j => return .drafted j
  | none => return .waiting

end DiffReviewer.Fanout