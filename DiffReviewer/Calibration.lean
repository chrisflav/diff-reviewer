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
    comments are read. What one reviewer said of one commit — every review they submitted of it,
    merged — is a **sample**: the commit, the base the pull request had there (the merge base of
    its base and that commit, which is what GitHub's diff of the pull request showed), the
    reviewer, the strongest state of the reviews (`CHANGES_REQUESTED`, then `APPROVED`, then
    `COMMENTED`), their bodies, and their comments on the new side of the diff at that commit.
  * **What is dropped.** A comment on the old side, one not anchored to a line of the review's own
    commit, and a reply in a thread are dropped — the agent writes none of those — and counted;
    a sample that lost comments so is `partial`, and scored for its decision only. A comment GitHub
    calls outdated *now* is kept: it is placed by its `original_line` on the commit it was written
    against, which is the sample's, and dropping it would drop exactly the comments the author
    acted on. A review that says nothing is dropped if it is a comment; an approval or a request
    for changes that says nothing is kept, as a `decision` sample.
  * **Idempotent.** Every review looked at is recorded with what became of it
    (`Store.ReviewSeenRow`) and never looked at again: importing again adds only reviews not seen
    — to the sample of their group when there is one — counts nothing twice, and adds nothing to
    a group whose sample a person deleted.
  * **Bounded.** An import reads a bounded number of pull requests a pass. It pauses, to go on
    later, when GitHub says its rate limit is reached, and when the requests left fall under a
    reserve kept for discovery and posting, until the limit resets. A pull request that fails three
    times is skipped as `unreadable`. A person may cancel an import.
  * **Runs** (`createRun`). A run asks for one `calibration` job per sample, at the sample's commit
    and with its base for the diff. The jobs go through the queue and the agent as any review does,
    with the same prompt and rubric — and a token narrowed to cloning and fetching from GitHub
    (`Workers.calibrationNarrowing`) — but the review is never posted (`Job.notPostable`), discovery
    never makes them `stale`, and they count toward a daily cap of their own per repository
    (`maxCalibrationJobsPerDay`): a charge when a run makes one and another when a person runs it
    again (`retryJob`), each checked in one transaction with the write it allows. What the agent is
    given names no sample and says nothing of the person's review.
  * **Held out, by pull request** (`splitOf`, `assignSplits`, `poolSamples`). Every sample is
    `eval` or `pool`, by a stable hash of its pull request against the repository's `evalShare`
    (50 by default), fixed once assigned and stored; a sample of a pull request that has a split
    already takes it. By pull request, not by review: two reviewers of one pull request, or two
    rounds of it, say much the same, and one must not teach what the other tests. Changing the
    share changes only the pull requests split later. Runs measure on `eval` samples; a run may be
    asked of the `pool`, to give rubric proposals evidence, and its scores are never in an
    aggregate. What the agent learns from — the examples of style, a rubric proposal's misses and
    pool aggregates — is of `pool` samples whose pull request has no `eval` sample (which samples
    stored before the split was by pull request may have).
  * **Derived** (`derivedOf`). A score is `derived`, and left out of aggregates unless asked like
    a stale one, when its sample's pull request is one the rubric version or the style notes
    version its job was reviewed under was derived from (`Platform.Provenance`): what a rubric
    learned from is no test of it.
  * **Not the platform's own.** An import skips the reviews the platform posted — by GitHub's id
    of a job's `postedReview`, or by the marker in their body — and counts them as `ownPosts`: the
    agent is not to be scored against, nor learn from, itself.
  * **Scores** (`scoreJob`, and `scorePending` on every pass). When a calibration job's review is a
    draft, the agent's first draft is scored against its sample (`DiffReviewer.Score`) and kept per
    job and matcher version; a draft that cannot be scored is marked so, once. A score whose sample
    a later review has since joined is marked `stale`, and kept as it was. Runs and the repository
    are aggregates of the scores of samples not deleted, stale ones left out unless asked
    (`runJson`, `summaryJson`).
-/

namespace DiffReviewer.Calibration

open Db.Query.DSL
open Score (HumanComment)

private def optStr : Option String → Json
  | some s => .str s
  | none   => .null

private def nowEpoch : IO Int :=
  return (← Std.Time.Timestamp.now).toSecondsSinceUnixEpoch.val

/-! ## Samples -/

/-- What one trusted reviewer said of one commit of a pull request. -/
structure Sample where
  id          : String
  owner       : String
  name        : String
  prNumber    : Nat
  /-- GitHub's ids of the reviews merged into it. -/
  reviewIds   : List Nat
  reviewer    : String
  /-- The strongest of its reviews' `state`s, as GitHub gave it. -/
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
  /-- `full`, `partial` or `decision`; see `Score`. -/
  scope       : String
  submittedAt : Option String
  importedAt  : String
  updatedAt   : String
  deletedAt   : Option String
  /-- `eval` or `pool`; `none` until assigned (`assignSplits`). -/
  split       : Option String := none

def Sample.comments (s : Sample) : List HumanComment :=
  match Json.parse s.commentsRaw >>= (·.getArr?) with
  | .ok xs => xs.toList.filterMap (HumanComment.ofJson · |>.toOption)
  | .error _ => []

def Sample.toJson (s : Sample) : Json :=
  .mkObj [("id", s.id), ("owner", s.owner), ("name", s.name), ("prNumber", s.prNumber),
          ("reviewIds", .arr (s.reviewIds.map fun (n : Nat) => (n : Json)).toArray),
          ("reviewer", s.reviewer), ("state", s.state),
          ("body", s.body), ("commitId", s.commitId), ("baseSha", s.baseSha),
          ("title", s.title), ("scope", s.scope),
          ("comments", .arr (s.comments.map HumanComment.toJson).toArray),
          ("dropped", .mkObj [("left", s.droppedLeft), ("outdated", s.droppedOutdated),
                              ("replies", s.droppedReplies)]),
          ("submittedAt", optStr s.submittedAt), ("importedAt", s.importedAt),
          ("updatedAt", s.updatedAt), ("deleted", s.deletedAt.isSome),
          ("deletedAt", optStr s.deletedAt), ("split", optStr s.split)]

private def natsOfRaw (raw : String) : List Nat :=
  match Json.parse raw >>= (·.getArr?) with
  | .ok xs => xs.toList.filterMap (·.getNat?.toOption)
  | .error _ => []

private def Sample.ofRow (r : Store.SampleRow) : Sample :=
  { id := r.id, owner := r.owner, name := r.name, prNumber := r.pr_number.toNat
  , reviewIds := natsOfRaw r.review_ids, reviewer := r.reviewer, state := r.state, body := r.body
  , commitId := r.commit_id, baseSha := r.base_sha, title := r.title, prBody := r.pr_body
  , commentsRaw := r.comments, droppedLeft := r.dropped_left.toNat
  , droppedOutdated := r.dropped_outdated.toNat, droppedReplies := r.dropped_replies.toNat
  , scope := r.scope, submittedAt := r.submitted_at, importedAt := r.imported_at
  , updatedAt := r.updated_at, deletedAt := r.deleted_at, split := r.split }

private def Sample.toRow (s : Sample) : Store.SampleRow :=
  { id := s.id, owner := s.owner, name := s.name, pr_number := s.prNumber
  , review_ids := (Json.arr (s.reviewIds.map fun (n : Nat) => (n : Json)).toArray).compress
  , reviewer := s.reviewer, state := s.state, body := s.body
  , commit_id := s.commitId, base_sha := s.baseSha, title := s.title, pr_body := s.prBody
  , comments := s.commentsRaw, dropped_left := s.droppedLeft
  , dropped_outdated := s.droppedOutdated, dropped_replies := s.droppedReplies
  , scope := s.scope, submitted_at := s.submittedAt, imported_at := s.importedAt
  , updated_at := s.updatedAt, deleted_at := s.deletedAt, split := s.split }

private def fetchSamples (owner name : String) : Sqlite.M (Array Sample) := do
  let rows ← HasModel.fetch <| query% do
    let s ← from Store.SampleRow
    guard s.owner = owner
    guard s.name = name
    select s
  return rows.map Sample.ofRow

/-- The samples of `owner/name` not deleted — or, with `deleted`, all of them, the deleted ones
    marked by their `deletedAt` — the most recently reviewed first. -/
def listSamples (owner name : String) (deleted := false) : IO (Array Sample) := do
  let all ← Store.run (fetchSamples owner name)
  -- The id breaks ties between reviews submitted in the same second, so the order is total.
  let key (s : Sample) : String := s.submittedAt.getD s.importedAt
  return (all.filter (deleted || ·.deletedAt.isNone)).qsort fun a b =>
    key a > key b || (key a == key b && a.id > b.id)

/-- FNV-1a, 64 bits, of the UTF-8 of `s`: a hash that is the same on every build and machine. -/
def stableHash (s : String) : UInt64 :=
  s.toUTF8.foldl (fun h b => (h ^^^ b.toUInt64) * 1099511628211) 14695981039346656037

/-- The split of the samples of pull request `pr` of `owner/name`, with `evalShare` percent held
    out: `eval` when the hash of `owner/name#pr` falls under the share. -/
def splitOf (owner name : String) (pr : Nat) (evalShare : Nat) : String :=
  let bucket := (stableHash (prKey owner name pr)).toNat % 100
  if bucket < evalShare then "eval" else "pool"

/-- The split a new sample of pull request `pr` takes, among `samples`: the one a sample of the
    pull request has already — the first stored, should an old database hold two — or `splitOf`'s
    with the share now. -/
def splitFor (samples : Array Sample) (owner name : String) (pr : Nat) (evalShare : Nat) :
    String :=
  match (samples.filter (·.prNumber == pr)).toList.filterMap (·.split) with
  | s :: _ => s
  | [] => splitOf owner name pr evalShare

/-- Give every sample of `repo` without a split one (`splitFor`), and store it: a split, once
    made, never changes. Nothing is written, and no write lock taken, when every sample has one;
    otherwise in one transaction that reads the repository's share again. -/
def assignSplits (repo : Repo) : IO Unit := do
  let all ← Store.run (fetchSamples repo.owner repo.name)
  unless all.any (·.split.isNone) do return
  let now ← nowIso
  Store.transact do
    let some repo ← Platform.fetchRepo repo.owner repo.name | return
    let mut all ← fetchSamples repo.owner repo.name
    for i in [0:all.size] do
      let some s := all[i]? | continue
      if s.split.isSome then continue
      let s : Sample := { s with split := some (splitFor all s.owner s.name s.prNumber
                                                  repo.evalShare), updatedAt := now }
      HasModel.save s.toRow
      all := all.set! i s

/-- The pull requests of `owner/name` that have an `eval` sample, deleted or not. -/
def evalPulls (owner name : String) : IO (List Nat) := do
  let all ← Store.run (fetchSamples owner name)
  return ((all.filter (·.split == some "eval")).toList.map (·.prNumber)).eraseDups

/-- The samples of `repo` an agent may learn from: of the `pool`, not deleted, and of a pull
    request no `eval` sample is of. The most recently reviewed first. -/
def poolSamples (repo : Repo) : IO (Array Sample) := do
  assignSplits repo
  let held ← evalPulls repo.owner repo.name
  return (← listSamples repo.owner repo.name).filter fun s =>
    s.split == some "pool" && !held.contains s.prNumber

/-- The ids of `owner/name`'s deleted samples. -/
def deletedSamples (owner name : String) : IO (List String) := do
  return ((← Store.run (fetchSamples owner name)).filter (·.deletedAt.isSome)).toList.map (·.id)

/-- Sample `id`, deleted or not. -/
def findSample (id : String) : IO (Option Sample) := do
  let rows ← Store.run <| HasModel.fetch <| query% do
    let s ← from Store.SampleRow
    guard s.id = id
    select s
  return rows[0]?.map Sample.ofRow

/-- Delete sample `id` of `owner/name`: it is no longer listed, picked for a run or counted in an
    aggregate, and importing again neither brings it back nor adds to it. Its scores are kept, and
    shown, marked, with the runs that used it. Answers whether there was such a sample. -/
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

/-- How strong a review's state is, for a sample of several: a request for changes over an
    approval over a comment. -/
def stateRank : String → Nat
  | "CHANGES_REQUESTED" => 3
  | "APPROVED"          => 2
  | "COMMENTED"         => 1
  | _                   => 0

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

/-- How many times reading one pull request may fail before it is skipped as `unreadable`. -/
def maxPullFailures : Nat := 3

/-- What an import counts, in this order. Every review is counted once, by the import that first
    looks at it. -/
def statKeys : List String :=
  ["pulls", "reviews", "imported", "merged", "known", "deleted", "empty", "unreachable",
   "unreadable", "ownPosts",
   "droppedLeft", "droppedOutdated", "droppedReplies"]

/-- A request to import, and how far it has got. -/
structure Import where
  id         : String
  owner      : String
  name       : String
  limit      : Nat
  /-- `queued`, `running`, `done`, `failed` or `cancelled`. -/
  status     : String
  pulls      : Option (Array PullRef)
  nextIndex  : Nat
  /-- How many times reading pull request `nextIndex` has failed. -/
  failures   : Nat
  stats      : List (String × Nat)
  error      : Option String
  requestedAt : String
  updatedAt  : String
  /-- When GitHub's rate limit resets, while the import waits for it: refused for the limit, or
      paused under the reserve. -/
  resetAt    : Option String := none

def Import.stat (i : Import) (k : String) : Nat := ((i.stats.lookup k).getD 0)

def Import.toJson (i : Import) : Json :=
  .mkObj [("id", i.id), ("owner", i.owner), ("name", i.name), ("limit", i.limit),
          ("status", i.status),
          ("pullsListed", (i.pulls.map fun ps => (ps.size : Json)).getD .null),
          ("pullsRead", i.nextIndex), ("failures", i.failures),
          ("stats", .mkObj (statKeys.map fun k => (k, (i.stat k : Json)))),
          ("error", optStr i.error), ("resetAt", optStr i.resetAt),
          ("requestedAt", i.requestedAt), ("updatedAt", i.updatedAt)]

private def Import.ofRow (r : Store.ImportRow) : Import :=
  let pulls := r.pulls.bind fun raw =>
    (Json.parse raw >>= (·.getArr?) >>= (·.mapM PullRef.ofJson)).toOption
  let stats := match Json.parse r.stats >>= (·.getObj?) with
    | .ok kvs => kvs.toList.filterMap fun (k, v) => (v.getNat?.toOption.map (k, ·))
    | .error _ => []
  { id := r.id, owner := r.owner, name := r.name, limit := r.pull_limit.toNat
  , status := r.status, pulls, nextIndex := r.next_index.toNat, failures := r.failures.toNat
  , stats, error := r.error, requestedAt := r.requested_at, updatedAt := r.updated_at
  , resetAt := r.reset_at }

private def Import.toRow (i : Import) : Store.ImportRow :=
  { id := i.id, owner := i.owner, name := i.name, pull_limit := i.limit, status := i.status
  , pulls := i.pulls.map fun ps => (Json.arr (ps.map PullRef.toJson)).compress
  , next_index := i.nextIndex, failures := i.failures
  , stats := (Json.mkObj (i.stats.map fun (k, v) => (k, (v : Json)))).compress
  , error := i.error, requested_at := i.requestedAt, updated_at := i.updatedAt
  , reset_at := i.resetAt }

private def fetchImports : Sqlite.M (Array Import) := do
  let rows ← HasModel.fetch <| query% do
    let i ← from Store.ImportRow
    select i
    order_by i.requested_at
    order_by i.id
  return rows.map Import.ofRow

/-- The imports of `owner/name`, newest first (ties broken by id). -/
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
    , pulls := none, nextIndex := 0, failures := 0, stats := [], error := none
    , requestedAt := now, updatedAt := now }
  Store.transact do
    if let some cur := (← fetchImports).find? fun j =>
        j.owner == repo.owner && j.name == repo.name && active j then
      return .error cur
    HasModel.save i.toRow
    return .ok i

/-- Cancel import `id` of `owner/name`, if it is queued or running: what it has stored stays, and
    the workers read no more of it. `none` when there is no such import; an error, with it, when
    it has ended already. -/
def cancelImport (owner name id : String) : IO (Option (Except Import Import)) := do
  let now ← nowIso
  Store.transact do
    let some i := (← fetchImports).find? fun j => j.id == id && j.owner == owner && j.name == name
      | return none
    unless active i do return some (.error i)
    let i := { i with status := "cancelled", updatedAt := now }
    HasModel.save i.toRow
    return some (.ok i)

/-- Write the workers' progress on `i`, unless it was cancelled meanwhile: then `none`, and the
    workers stop. The check and the write are one transaction, so a cancel is never overwritten. -/
private def saveImport (i : Import) : IO (Option Import) := do
  let i := { i with updatedAt := ← nowIso }
  Store.transact do
    let some cur := (← fetchImports).find? (·.id == i.id) | return none
    unless active cur do return none
    HasModel.save i.toRow
    return some i

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

private def fetchSeen (owner name : String) : Sqlite.M (Array Store.ReviewSeenRow) :=
  HasModel.fetch <| query% do
    let r ← from Store.ReviewSeenRow
    guard r.owner = owner
    guard r.name = name
    select r

/-- Record reviews `ids` of `repo` as seen, with what became of them. -/
private def markSeen (repo : Repo) (ids : List Nat) (outcome : String)
    (sample : Option String := none) : Sqlite.M Unit := do
  let now ← nowIso
  for id in ids do
    HasModel.save ({ owner := repo.owner, name := repo.name, review_id := id, outcome
                   , sample_id := sample, seen_at := now } : Store.ReviewSeenRow)

/-- One review's part of a sample: the review, and its comments kept and dropped. -/
structure Part where
  review   : GitHub.PostedReview
  kept     : Array HumanComment
  left     : Nat
  outdated : Nat
  replies  : Nat

/-- The comments of review `r` among `comments`, kept or dropped. -/
def partOf (r : GitHub.PostedReview) (comments : Array GitHub.ReviewComment) : Part := Id.run do
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
        -- Not anchored to the review's own commit: written against another.
        if !c.originalCommitId.isEmpty && c.originalCommitId != r.commitId then
          outdated := outdated + 1
        else
          let start := c.originalStartLine.getD line
          kept := kept.push { id := c.id, path := c.path, startLine := min start line, line
                            , body := c.body }
      -- On the whole file, or on no line at all.
      | _, _ => outdated := outdated + 1
  return { review := r, kept, left, outdated, replies }

/-- The scope of a sample of `parts`: `decision` when they say nothing but their state,
    `partial` when comments that were findings were dropped, `full` otherwise. -/
private def scopeOf (comments : List HumanComment) (body : String) (dropped : Nat) : String :=
  if comments.isEmpty && body.trimAscii.isEmpty then "decision"
  else if dropped > 0 then "partial"
  else "full"

/-- Store `parts` — reviews of one reviewer of one commit, none seen yet — as the sample of their
    group: a new one, or added to the one there is. A group whose sample was deleted gets nothing.
    The check and the writes are one transaction, so that two processes importing at once store
    each review once. Answers what became of them: `imported`, `merged`, `deleted` or `known`. -/
private def storeGroup (repo : Repo) (p : PullRef) (base : String) (parts : List Part) :
    IO String := do
  let now ← nowIso
  let fresh ← randomHex 8
  Store.transact do
    let seen := (← fetchSeen repo.owner repo.name).map (·.review_id.toNat)
    let parts := parts.filter (!seen.contains ·.review.id)
    let some first := parts.head? | return "known"
    let commit := first.review.commitId
    let reviewer := first.review.author.toLower
    let existing := (← fetchSamples repo.owner repo.name).find? fun s =>
      s.prNumber == p.number && s.commitId == commit && s.reviewer == reviewer
    let ids := parts.map (·.review.id)
    if let some s := existing then
      if s.deletedAt.isSome then
        markSeen repo ids "deleted" (some s.id)
        return "deleted"
    let old : Sample := existing.getD
      { id := fresh, owner := repo.owner, name := repo.name, prNumber := p.number, reviewIds := []
      , reviewer, state := "", body := "", commitId := commit, baseSha := base, title := p.title
      , prBody := p.body, commentsRaw := "[]", droppedLeft := 0, droppedOutdated := 0
      , droppedReplies := 0, scope := "decision", submittedAt := none, importedAt := now
      , updatedAt := now, deletedAt := none
      , split := some (splitFor (← fetchSamples repo.owner repo.name) repo.owner repo.name
                         p.number repo.evalShare) }
    let comments := old.comments ++ parts.flatMap (·.kept.toList)
    let bodies := ([old.body] ++ parts.map (·.review.body)).filter (!·.trimAscii.isEmpty)
    let body := "\n\n".intercalate bodies
    let state := (parts.map (·.review.state)).foldl
      (fun a b => if stateRank b > stateRank a then b else a) old.state
    let left := old.droppedLeft + (parts.map (·.left)).sum
    let outdated := old.droppedOutdated + (parts.map (·.outdated)).sum
    let submittedAt := (parts.filterMap (·.review.submittedAt)).foldl
      (fun a b => if a.all (· < b) then some b else a) old.submittedAt
    let s : Sample :=
      { old with reviewIds := old.reviewIds ++ ids, state, body
                 commentsRaw := (Json.arr (comments.map HumanComment.toJson).toArray).compress
                 droppedLeft := left, droppedOutdated := outdated
                 droppedReplies := old.droppedReplies + (parts.map (·.replies)).sum
                 scope := scopeOf comments body (left + outdated), submittedAt, updatedAt := now }
    HasModel.save s.toRow
    markSeen repo ids "sample" (some s.id)
    -- A score of the sample as it was is no longer of the whole of it.
    if existing.isSome then
      let scores ← HasModel.fetch <| query% do
        let r ← from Store.ScoreRow
        guard r.sample_id = s.id
        select r
      for r in scores do
        unless r.stale == some true do HasModel.save { r with stale := some true }
    return if existing.isSome then "merged" else "imported"

/-- Read pull request `p` of `repo`, and store what each trusted reviewer said of each commit it
    reviewed, from the reviews not seen before. Answers what it counted. A pull request GitHub
    refuses to show (a `4xx`) counts as `unreadable`, and a commit it cannot compare as
    `unreachable` — a force-push may have left it unreferenced — so that neither holds the import
    up. -/
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
  let seen := (← Store.run (fetchSeen repo.owner repo.name)).map (·.review_id.toNat)
  let fresh := mine.filter (!seen.contains ·.id)
  if fresh.isEmpty then return .ok [("known", mine.size)]
  -- The platform's own posts — under the operator's login, who may well be trusted — are not a
  -- person's review: by the id GitHub gave a job's post, or by the marker every post carries.
  let posted := (← Platform.listJobs).toList.filterMap fun j =>
    if j.owner == repo.owner && j.name == repo.name then
      (j.postedReview.bind (Json.parse · |>.toOption)).bind (·.getObjValAs? Nat "id" |>.toOption)
    else none
  let own (r : GitHub.PostedReview) : Bool :=
    posted.contains r.id || (r.body.splitOn "<!-- diff-reviewer job ").length > 1
  let ownPosts := fresh.filter own
  unless ownPosts.isEmpty do
    Store.transact (markSeen repo (ownPosts.toList.map (·.id)) "own")
  let fresh := fresh.filter (!own ·)
  if fresh.isEmpty then
    return .ok ([("known", mine.size - ownPosts.size)] ++
      if ownPosts.isEmpty then [] else [("ownPosts", ownPosts.size)])
  let comments ← match ← gh.listReviewComments repo.owner repo.name p.number with
    | .ok cs => pure cs
    | .error (.definite _) => return .ok [("unreadable", 1)]
    | .error e => return .error (readError e)
  let mut stats : List (String × Nat) :=
    [("reviews", fresh.size), ("known", mine.size - fresh.size - ownPosts.size),
     ("ownPosts", ownPosts.size)]
  -- One group per commit and reviewer, in the order GitHub listed the reviews.
  let mut groups : Array ((String × String) × Array Part) := #[]
  for r in fresh do
    let part := partOf r comments
    stats := addStats stats [("droppedLeft", part.left), ("droppedOutdated", part.outdated),
                             ("droppedReplies", part.replies)]
    -- A comment that says nothing is nothing to compare; an approval or a request for changes
    -- that says nothing is still a decision.
    if part.kept.isEmpty && r.body.trimAscii.isEmpty &&
        !(r.state == "APPROVED" || r.state == "CHANGES_REQUESTED") then
      Store.transact (markSeen repo [r.id] "empty")
      stats := addStats stats [("empty", 1)]
      continue
    let key := (r.commitId, r.author.toLower)
    groups := match groups.findIdx? (·.1 == key) with
      | some i => groups.modify i fun (k, ps) => (k, ps.push part)
      | none => groups.push (key, #[part])
  let mut bases : List (String × Option String) := []
  for ((commit, _), parts) in groups do
    let base ← match bases.lookup commit with
      | some b => pure b
      | none =>
        let b ← match ← gh.mergeBase repo.owner repo.name p.baseSha commit with
          | .ok b => pure (some b)
          | .error (.definite _) => pure none
          | .error e => return .error (readError e)
        bases := (commit, b) :: bases
        pure b
    let some base := base
      | Store.transact (markSeen repo (parts.toList.map (·.review.id)) "unreachable")
        stats := addStats stats [("unreachable", parts.size)]
        continue
    let outcome ← storeGroup repo p base parts.toList
    stats := addStats stats <| match outcome with
      | "imported" => [("imported", 1), ("merged", parts.size - 1)]
      | "merged" => [("merged", parts.size)]
      | "deleted" => [("deleted", parts.size)]
      | _ => [("known", parts.size)]
  return .ok stats

/-- Record `why` as the import's error, with when the rate limit it waits for resets, unless they
    are the ones recorded: a failure repeated on every pass is written once. -/
private def importFailed (i : Import) (why : String) (status := i.status)
    (resetAt : Option String := none) : IO Unit := do
  if i.error == some why && i.status == status && i.resetAt == resetAt then return
  let _ ← saveImport { i with error := some why, status, resetAt }

/-- When GitHub's rate limit resets, as its last answer said. -/
private def resetOf (gh : GitHub.Client) : IO (Option String) := do
  return (← gh.rateLimit).map (isoOfEpoch ·.resetAt)

/-- Why GitHub is not to be asked anything more for imports now, if it is not: what it said last
    leaves fewer than `reserve` requests before its limit resets. The reserve is for discovery and
    posting, which matter more than an import that can wait. -/
def pausedFor (gh : GitHub.Client) (reserve : Nat) : IO (Option String) := do
  let some l ← gh.rateLimit | return none
  if l.remaining < reserve && (← nowEpoch) < l.resetAt then
    -- No count in the text: it is recorded once per window, not again on every pass.
    return some s!"paused until {isoOfEpoch l.resetAt}: GitHub's requests left before its limit \
resets are under the {reserve} kept for discovery and posting (--github-reserve)"
  return none

/-- How one import's pass ended. -/
private inductive Pass where
  /-- Out of budget, done, cancelled, or waiting to retry a pull request: the next import may go
      on. -/
  | next (budget : Nat)
  /-- GitHub is not to be asked anything more on this pass. -/
  | stop

/-- Read import `i` of `repo` on, at most `budget` pull requests. -/
private def runImport (gh : GitHub.Client) (log : String → IO Unit) (reserve : Nat)
    (repo : Repo) (i : Import) (budget : Nat) : IO Pass := do
  let mut i := i
  let mut budget := budget
  if let some why ← pausedFor gh reserve then
    importFailed i why (resetAt := ← resetOf gh)
    return .stop
  let pulls ← match i.pulls with
    | some ps => pure ps
    | none =>
      match ← gh.listClosedPulls repo.owner repo.name i.limit with
      | .ok ps =>
        let ps := ps.map fun p =>
          ({ number := p.number, title := p.title, body := p.body, baseSha := p.baseSha }
            : PullRef)
        let listed : Import := { i with pulls := some ps, status := "running", error := none,
                                        resetAt := none,
                                        stats := addStats i.stats [("pulls", ps.size)] }
        let some i' ← saveImport listed | return .next budget
        i := i'
        log s!"calibration import {i.id} of {repo.slug}: {ps.size} closed pull request(s)"
        pure ps
      | .error (.rateLimited why) =>
        importFailed i s!"GitHub's rate limit ({why}); it goes on by itself"
          (resetAt := ← resetOf gh)
        return .stop
      | .error (.definite why) =>
        importFailed i s!"listing the closed pull requests: {why}" "failed"
        return .next budget
      | .error e =>
        importFailed i s!"listing the closed pull requests: {e.message}"
        return .next budget
  while i.nextIndex < pulls.size && budget > 0 do
    let some p := pulls[i.nextIndex]? | break
    if let some why ← pausedFor gh reserve then
      importFailed i why (resetAt := ← resetOf gh)
      return .stop
    budget := budget - 1
    let next ← match ← importPull gh repo p with
      | .ok stats =>
        pure { i with nextIndex := i.nextIndex + 1, failures := 0,
                      stats := addStats i.stats stats, error := none, resetAt := none }
      | .error (.rateLimited why) =>
        importFailed i s!"GitHub's rate limit ({why}); it goes on by itself"
          (resetAt := ← resetOf gh)
        return .stop
      | .error (.retry why) =>
        if i.failures + 1 ≥ maxPullFailures then
          log s!"calibration import {i.id} of {repo.slug}: #{p.number} skipped after \
{maxPullFailures} failures: {why}"
          pure { i with nextIndex := i.nextIndex + 1, failures := 0,
                        stats := addStats i.stats [("unreadable", 1)],
                        error := some s!"#{p.number} was skipped after {maxPullFailures} \
failures: {why}" }
        else
          let failed : Import := { i with failures := i.failures + 1,
                                          error := some s!"reading #{p.number}: {why}; it is \
read again on the next pass" }
          let _ ← saveImport failed
          return .next budget
    let some i' ← saveImport next | return .next budget
    i := i'
  if i.nextIndex ≥ pulls.size then
    if let some _ ← saveImport { i with status := "done" } then
      log s!"calibration import {i.id} of {repo.slug} is done: {i.stat "imported"} new \
sample(s)"
  return .next budget

/-- One pass of importing: the queued and running imports, oldest first, reading at most
    `budget` pull requests in all. Each pull request's outcome is written as soon as it is read,
    so a pass cut short loses nothing. GitHub's rate limit, or its requests left falling under
    `reserve`, ends the pass: the import goes on where it stopped on a later one. -/
def importStep (gh : GitHub.Client) (log : String → IO Unit) (budget : Nat)
    (reserve : Nat := 500) : IO Unit := do
  let mut budget := budget
  for i in (← Store.run fetchImports).filter active do
    if budget == 0 then return
    let some repo ← Platform.findRepo i.owner i.name
      | importFailed i "the repository is no longer registered" "failed"
        continue
    if repo.trustedReviewers.isEmpty then
      importFailed i "the repository names no trusted reviewers" "failed"
      continue
    match ← runImport gh log reserve repo i budget with
    | .stop => return
    | .next b => budget := b

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

/-- The runs of `owner/name`, newest first (ties broken by id). -/
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

/-- Every job of a kind other than `review`, found by the index on the kind: reviews, which are
    most of the jobs, are stored without one. -/
private def fetchKindedJobs : Sqlite.M (Array Job) := do
  let rows ← HasModel.fetch <| query% do
    let j ← from Store.JobRow
    guard j.kind.isSome
    select j
    order_by_desc j.created_at
    order_by_desc j.id
  return rows.map Job.ofRow

/-- The calibration jobs of `owner/name`, newest first. -/
def calibrationJobs (owner name : String) : IO (Array Job) := do
  return (← Store.run fetchKindedJobs).filter fun j =>
    j.owner == owner && j.name == name && j.kind? == some .calibration

/-- The statuses in which a calibration job is still to be run. -/
private def liveStatuses : List JobStatus := [.pending, .queued, .running]

private def isLive (j : Job) : Bool := j.status?.any (liveStatuses.contains ·)

/-- `count` samples of `repo` of split `split` for a run: of those no live calibration job is
    reviewing, the ones reviewed by the fewest calibration jobs so far, the most recently reviewed
    first among equals. -/
def pickSamples (repo : Repo) (count : Nat) (split := "eval") : IO (List String) := do
  assignSplits repo
  let jobs ← calibrationJobs repo.owner repo.name
  let uses (s : Sample) : Nat := (jobs.filter (·.sampleId == some s.id)).size
  let live (s : Sample) : Bool := jobs.any fun j => j.sampleId == some s.id && isLive j
  let samples := (← listSamples repo.owner repo.name).filter fun s =>
    !live s && s.split == some split
  -- `listSamples` is newest first, and the sort is stable on the index it carries.
  let ranked := samples.zipIdx.qsort fun (a, i) (b, j) =>
    uses a < uses b || (uses a == uses b && i < j)
  return (ranked.toList.take count).map (·.1.id)

/-- Why a run, or a retry, was not made. -/
inductive RunError where
  | notFound
  | invalid (why : String)
  | conflict (why : String)
  /-- The daily cap of calibration jobs would be passed. -/
  | capped (why : String)

/-- The charges on `owner/name`'s daily cap since `since`. -/
private def chargesSince (owner name since : String) : Sqlite.M Nat := do
  let rows ← HasModel.fetch <| query% do
    let c ← from Store.ChargeRow
    guard c.owner = owner
    guard c.name = name
    select c
  return (rows.filter (·.charged_at ≥ since)).size

private def charge (owner name jobId now : String) : Sqlite.M Unit := do
  HasModel.save ({ id := ← randomHex 8, owner, name, job_id := jobId, charged_at := now }
    : Store.ChargeRow)

private def capError (slug : String) (made more cap : Nat) : RunError :=
  .capped s!"{slug} has run {made} calibration job(s) in the last 24 hours; {more} more would pass \
the most allowed, {cap} (--max-calibration-jobs-per-day)"

/-- A run of `repo` over `sampleIds`: one `pending` calibration job for each, at the sample's
    commit and with its base. In one transaction with the checks that every sample is the
    repository's, not deleted and not being reviewed by a live calibration job already — one
    sample is one job at a time — and that the jobs fit in what is left of `cap`, the charges on
    the repository's cap in the last 24 hours; each job is a charge. Every sample must be of
    `split`: `eval`, what calibration measures by, unless the run is asked of the `pool`, whose
    scores give rubric proposals evidence and are never in an aggregate. -/
def createRun (repo : Repo) (sampleIds : List String) (cap : Nat) (split := "eval") :
    IO (Except RunError (Run × Array Job)) := do
  assignSplits repo
  let now ← nowIso
  let since := isoOfEpoch ((← nowEpoch) - 86400)
  let runId ← randomHex 8
  let ids ← sampleIds.mapM fun _ => randomHex 8
  Store.transact do
    let samples ← fetchSamples repo.owner repo.name
    let jobs := (← fetchKindedJobs).filter fun j =>
      j.owner == repo.owner && j.name == repo.name && j.kind? == some .calibration
    let mut picked : Array Sample := #[]
    for sid in sampleIds do
      let some s := samples.find? fun s => s.id == sid && s.deletedAt.isNone
        | return .error (.invalid s!"'{sid}' is not a sample of {repo.slug}")
      unless s.split == some split do
        return .error (.invalid s!"sample {sid} is a {s.split.getD "?"} sample, and this run is \
of the {split} samples{if split == "eval" then "; examples and proposals learn from the pool, \
which calibration does not measure by" else ""}")
      if let some j := jobs.find? fun j => j.sampleId == some sid && isLive j then
        return .error (.conflict s!"sample {sid} is being reviewed already, by job {j.id}")
      picked := picked.push s
    let made ← chargesSince repo.owner repo.name since
    if made + picked.size > cap then return .error (capError repo.slug made picked.size cap)
    let jobs : Array Job := Array.zipWith (fun (s : Sample) id =>
      ({ id := id, owner := repo.owner, name := repo.name, prNumber := s.prNumber
       , headSha := some s.commitId, baseSha := some s.baseSha, title := some s.title
       , prBody := some s.prBody, createdAt := now, updatedAt := now
       , kindRaw := some JobKind.calibration.toString, sampleId := some s.id
       , runId := some runId } : Job)) picked ids.toArray
    for j in jobs do
      HasModel.save j.toRow
      charge repo.owner repo.name j.id now
    let run : Run :=
      { id := runId, owner := repo.owner, name := repo.name, sampleIds, createdAt := now }
    HasModel.save ({ id := runId, owner := repo.owner, name := repo.name
                   , sample_ids := (Json.arr (sampleIds.map Json.str).toArray).compress
                   , created_at := now } : Store.RunRow)
    return .ok (run, jobs)

/-- A person's `failed → pending` of calibration job `id`, read at `version`: run it again, which
    charges the repository's cap like a new job. Refused while another live job reviews the same
    sample, as `createRun` refuses it. Both checks are in the transaction of the write. -/
def retryJob (id : String) (version : Nat) (cap : Nat) : IO (Except RunError Job) := do
  let now ← nowIso
  let since := isoOfEpoch ((← nowEpoch) - 86400)
  Store.transact do
    let some job ← Platform.fetchJob id | return .error .notFound
    unless job.version == version do
      return .error (.conflict s!"job {id} has changed since it was read (version {version}, now \
{job.version}); reload it")
    unless job.status? == some .failed do
      return .error (.conflict s!"job {id} is {job.statusRaw} and cannot be made pending from \
here")
    -- One sample is one live job: a newer run may have picked it since this one failed.
    if let some other := (← fetchKindedJobs).find? fun j =>
        j.id != id && j.sampleId.isSome && j.sampleId == job.sampleId && isLive j then
      return .error (.conflict s!"sample {job.sampleId.getD ""} is being reviewed by job \
{other.id}; job {id} is not run again")
    let made ← chargesSince job.owner job.name since
    if made + 1 > cap then return .error (capError s!"{job.owner}/{job.name}" made 1 cap)
    let next := { job with statusRaw := JobStatus.pending.toString, queueEntry := none
                           error := none, postDirect := false, version := job.version + 1
                           updatedAt := now }
    HasModel.save next.toRow
    charge job.owner job.name id now
    return .ok next

/-! ## Scores -/

private def fetchScores : Sqlite.M (Array Store.ScoreRow) :=
  HasModel.fetch <| query% do
    let s ← from Store.ScoreRow
    guard s.matcher_version = (Score.matcherVersion : Int)
    select s

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
  return (← Store.run fetchScores).filter fun s => s.owner == owner && s.name == name

private def saveScore (job : Job) (sampleId : String) (score : Json) : IO Unit := do
  Store.run <| HasModel.save
    ({ job_id := job.id, matcher_version := Score.matcherVersion, run_id := job.runId
     , sample_id := sampleId, owner := job.owner, name := job.name
     , rubric_version := job.rubricVersion.map Int.ofNat, score := score.compress
     , created_at := ← nowIso, stale := some false } : Store.ScoreRow)

/-- Score calibration job `job` against its sample, by the current matcher, unless that is done:
    the agent's first draft — what it submitted, before anything a person did — against what the
    trusted reviewer said, for the sample's scope. Answers whether a score was written. Nothing is
    written for a job with no draft yet; a draft that does not read, or a sample that is gone, is
    written as `unscorable`, with why, so that it is not tried again on every pass. -/
def scoreJob (job : Job) : IO Bool := do
  unless job.kind? == some .calibration do return false
  let some sid := job.sampleId | return false
  if (← scoreOf job.id).isSome then return false
  let some draft := (← Platform.revisions job.id).find? (·.author == Author.agent.toString)
    | return false
  let unscorable (why : String) : IO Bool := do
    saveScore job sid (.mkObj [("matcherVersion", Score.matcherVersion), ("unscorable", why)])
    return true
  let review ← match Review.ofJsonString draft.reviewRaw with
    | .ok r => pure r
    | .error e => return ← unscorable s!"the agent's draft does not read: {e}"
  let some sample ← findSample sid | return ← unscorable s!"sample {sid} is gone"
  saveScore job sid (Score.score review sample.state sample.comments sample.scope).toJson
  return true

/-- Score every calibration job that has a draft and no score by the current matcher: a job whose
    scoring on submission was missed, and every job again once the matcher changes. The jobs are
    found by the index on the kind, and those scored already left out before anything else is
    read. Answers how many were scored. -/
def scorePending : IO Nat := do
  let scored := (← Store.run fetchScores).map (·.job_id)
  let mut n := 0
  for j in ← Store.run fetchKindedJobs do
    if scored.contains j.id || j.kind? != some .calibration then continue
    if ← scoreJob j then n := n + 1
  return n

/-! ## What is read -/

private def isStale (r : Store.ScoreRow) : Bool := r.stale == some true

/-- Which of the scores of `owner/name` are `derived`: of a sample whose pull request — or which
    itself — the rubric version the job was reviewed against, or the style notes version its agent
    was given (`Job.notesVersion`), was derived from. By pull request, so that a sample of such a
    pull request imported later is flagged too. Neither is a test of what learned from it. -/
def derivedOf (owner name : String) : IO (Store.ScoreRow → Bool) := do
  let rubrics ← Platform.rubricHistory owner name
  let notes ← Platform.notesHistory owner name
  let samples ← Store.run (fetchSamples owner name)
  let jobs ← calibrationJobs owner name
  return fun r =>
    let pr := (samples.find? (·.id == r.sample_id)).map fun s => prKey owner name s.prNumber
    let hit (p : Provenance) : Bool :=
      p.samples.contains r.sample_id || pr.any (p.prs.contains ·)
    let byRubric := rubrics.any fun v => r.rubric_version == some (v.version : Int) && hit v.derived
    let notesVersion := (jobs.find? (·.id == r.job_id)).bind (·.notesVersion)
    let byNotes := notes.any fun n => notesVersion == some n.version && hit n.derived
    byRubric || byNotes

/-- What an aggregate leaves out, and what it is asked to take in. -/
structure Filter where
  /-- The samples deleted, and those of the other split, whose scores are never aggregated. -/
  deleted  : List String := []
  others   : List String := []
  derived  : Store.ScoreRow → Bool := fun _ => false
  includeStale   : Bool := false
  includeDerived : Bool := false

/-- The aggregate of `rows` under `f`: never of the samples deleted or of the pool, and, unless
    asked, not of the stale or derived scores; with how many of those there were and whether they
    are in. -/
private def aggregateOf (rows : Array Store.ScoreRow) (f : Filter) : Json :=
  let rows := rows.filter fun r => !f.deleted.contains r.sample_id && !f.others.contains r.sample_id
  let agg := rows.foldl (init := ({} : Score.Aggregate)) fun a r =>
    if isStale r && !f.includeStale then a else
    if f.derived r && !f.includeDerived then a else
    match Json.parse r.score with
    | .ok j => (a.add j).getD a
    | .error _ => a
  agg.toJson.setObjVal! "staleScores" ((rows.filter isStale).size : Json)
    |>.setObjVal! "staleIncluded" f.includeStale
    |>.setObjVal! "derivedScores" ((rows.filter f.derived).size : Json)
    |>.setObjVal! "derivedIncluded" f.includeDerived

/-- The filter of `owner/name`'s aggregates of the samples of `split`: `eval` for what calibration
    measures, `pool` for the evidence a rubric proposal is given. -/
def filterOf (owner name : String) (includeStale includeDerived : Bool) (split := "eval") :
    IO Filter := do
  if let some repo ← Platform.findRepo owner name then assignSplits repo
  let all ← Store.run (fetchSamples owner name)
  -- The pool's aggregates, which a proposal reads, leave out every sample of a pull request that
  -- is held out, whatever its own split.
  let held ← evalPulls owner name
  let outside (s : Sample) : Bool :=
    s.split != some split || (split == "pool" && held.contains s.prNumber)
  return { deleted := ← deletedSamples owner name
         , others := (all.filter outside).toList.map (·.id)
         , derived := ← derivedOf owner name, includeStale, includeDerived }

/-- How many of `jobs` are in each status, as `{status: n}`. -/
private def statusCounts (jobs : Array Job) : Json :=
  let names := (jobs.map (·.statusRaw)).toList.eraseDups
  .mkObj (names.map fun s => (s, ((jobs.filter (·.statusRaw == s)).size : Json)))

/-- A run, with its aggregate — of the samples not deleted and not of the pool, and of the scores
    not stale and not derived unless asked; with `detail`, each of its jobs beside its sample,
    marked when deleted, and its score, marked when stale or derived. -/
def runJson (run : Run) (detail : Bool) (includeStale := false) (includeDerived := false) :
    IO Json := do
  let jobs := (← calibrationJobs run.owner run.name).filter (·.runId == some run.id)
  let scores := (← scoresOf run.owner run.name).filter (·.run_id == some run.id)
  let f ← filterOf run.owner run.name includeStale includeDerived
  let fields : List (String × Json) :=
    [("id", run.id), ("owner", run.owner), ("name", run.name), ("createdAt", run.createdAt),
     ("samples", run.sampleIds.length), ("jobs", statusCounts jobs),
     ("aggregate", aggregateOf scores f)]
  unless detail do return .mkObj fields
  let results ← jobs.mapM fun j => do
    let sample ← match j.sampleId with
      | some sid => findSample sid
      | none => pure none
    let row := scores.find? (·.job_id == j.id)
    let score := row.bind fun r => (Json.parse r.score).toOption
    return Json.mkObj [
      ("jobId", j.id), ("status", j.statusRaw), ("error", optStr j.error),
      ("rubricVersion", (j.rubricVersion.map fun v => (v : Json)).getD .null),
      ("prType", optStr j.prType),
      ("sample", (sample.map fun s => Json.mkObj [("id", s.id), ("prNumber", s.prNumber),
        ("reviewer", s.reviewer), ("state", s.state), ("commitId", s.commitId),
        ("title", s.title), ("scope", s.scope), ("comments", s.comments.length),
        ("deleted", s.deletedAt.isSome), ("split", optStr s.split)]).getD .null),
      ("score", score.getD .null), ("scoreStale", row.any isStale),
      ("scoreDerived", row.any f.derived)]
  return .mkObj (fields ++ [("results", .arr results)])

/-- The aggregate over every scored calibration job of `owner/name` whose sample is not deleted
    and not of the pool (and whose score is neither stale nor derived, unless asked), and the same
    for each rubric version the jobs were reviewed against (`null`: before rubrics), newest version
    first. -/
def summaryJson (owner name : String) (includeStale := false) (includeDerived := false)
    (split := "eval") : IO Json := do
  let f ← filterOf owner name includeStale includeDerived split
  let scores := (← scoresOf owner name).filter (!f.deleted.contains ·.sample_id)
  let versions := ((scores.map (·.rubric_version)).toList.eraseDups.toArray.qsort fun a b =>
    a.getD (-1) > b.getD (-1)).toList
  return .mkObj [
    ("owner", owner), ("name", name), ("split", split), ("runs", (← runsOf owner name).size),
    ("samples", (← listSamples owner name).size),
    ("overall", aggregateOf scores f),
    ("byRubricVersion", .arr (versions.map fun v =>
      Json.mkObj [("rubricVersion", (v.map fun n => (n.toNat : Json)).getD .null),
        ("aggregate", aggregateOf (scores.filter (·.rubric_version == v)) f)]
      ).toArray)]

end DiffReviewer.Calibration