import DiffReviewer.Platform
import DiffReviewer.GitHub
import DiffReviewer.Orchestra

open Lean (Json)

/-!
# The platform's own moves

What `serve` does without being asked, on a loop every `--interval` seconds (`start`):

  * **discovery** — for each repository with `autoReview`, list its open pull requests and make a
    job for every head commit that has none; a draft or approved review of an older head of the
    same pull request is `stale`, since its line numbers no longer name the code under review.
  * **queueing** — put each `pending` job on orchestra, as the platform's API client, and record
    the queue entry. Orchestra's `external_id` is the job's id (with the attempt for a retry), so a
    request whose answer was lost is answered with the entry it made rather than queued twice.
  * **following** — read each queued or running job's entry (and whatever entry continues it) and
    move the job to `running` when the run starts, or to `failed` when it ends without the agent
    having submitted a review.

And, on request: fetching a diff (`diffOf`, cached per commit) and posting an approved review
(`postJob`), which a person asks for, or the agent's submission does for a `direct` repository.

The clients are passed in as `Services`, so that the suite runs all of it against fakes. Without
an orchestra client the platform still runs — jobs simply stay `pending` — and says so once.

None of these hold the store's lock across a call to GitHub or orchestra: each reads what it
needs, makes the call, and writes the outcome with `Platform.updateJob`, whose function re-checks
that the job is still in the state the call was made for.
-/

namespace DiffReviewer.Workers

structure Services where
  github    : Option GitHub.Client
  orchestra : Option Orchestra.Client
  log       : String → IO Unit
  /-- The jobs being posted right now, so that two requests to post one review post it once. -/
  posting   : IO.Ref (List String)
  /-- The keys of the messages `logOnce` has already written. -/
  logged    : IO.Ref (List String)

def Services.new (github : Option GitHub.Client := none)
    (orchestra : Option Orchestra.Client := none)
    (log : String → IO Unit := fun m => IO.eprintln s!"diff-reviewer: {m}") : IO Services := do
  return { github, orchestra, log, posting := ← IO.mkRef [], logged := ← IO.mkRef [] }

/-- Log `msg` the first time `key` is logged, and never again: for a state that holds on every
    pass of the loop, such as orchestra not being configured. -/
def Services.logOnce (s : Services) (key msg : String) : IO Unit := do
  let first ← s.logged.modifyGet fun ks =>
    if ks.contains key then (false, ks) else (true, key :: ks)
  if first then s.log msg

/-! ## What the agent is told -/

/-- The prompt of the orchestra task that reviews `job`. It names no head commit: the agent asks the
    platform which one (`agent show`), so a prompt never disagrees with the job. -/
def prompt (job : Job) : String :=
  let slug := s!"{job.owner}/{job.name}"
  s!"Review pull request #{job.prNumber} of {slug} for the diff-reviewer platform (job {job.id}).

1. Run `diff-reviewer agent show {slug} {job.prNumber}`. It prints the pull request — its head \
and base commits, title and description — and the instructions for the review; follow them.
2. The repository is checked out read-only in your working directory. Check out the head commit it \
names (`git fetch origin pull/{job.prNumber}/head && git checkout <headSha>`) and read the change \
in context. `diff-reviewer agent diff {slug} {job.prNumber}` prints the diff under review.
3. Write the review as a JSON file `\{\"headSha\": …, \"prType\": null, \"review\": …}` and \
submit it with `diff-reviewer agent submit {slug} {job.prNumber} <file>`. Fix what it reports and \
submit again until it is accepted.

Do not comment on, review or otherwise write to the pull request on GitHub yourself: the review \
is posted, once accepted, by the platform."

/-- The checkable sentence the run is held to. -/
def goal (job : Job) : String :=
  s!"`diff-reviewer agent submit {job.owner}/{job.name} {job.prNumber}` accepted a review of the \
pull request."

/-- How to review, in markdown: the `instructions` of `GET /api/agent/v1/…/pulls/{pr}`. M2 adds
    the repository's rubrics. -/
def instructions : String :=
"# Reviewing a pull request

Review the change at the head commit named here, as a careful maintainer of the repository would:
correctness first, then whether it fits the codebase's conventions, then clarity. Say what is
wrong and why, and where you can, what to do instead. Do not restate what the change does, and do
not comment on what is fine.

## The review

`diff-reviewer agent submit` takes a JSON file:

```json
{
  \"headSha\": \"<the headSha agent show printed>\",
  \"prType\": null,
  \"review\": {
    \"decision\": \"comment\",
    \"body\": \"The summary: what matters most, in a few sentences.\",
    \"comments\": [
      {\"file\": \"path/in/repo.lean\", \"start_line\": 10, \"end_line\": 12,
       \"body\": \"Why this is a problem.\", \"suggestion\": \"optional replacement lines\"}
    ]
  }
}
```

- `decision` is `comment`, `approve` or `request_changes`.
- A comment's lines are line numbers of the file at the head commit (the right-hand side of the
  diff), and must lie in a hunk of the diff. `suggestion`, when given, replaces lines
  `start_line`..`end_line` exactly.
- A review is posted only after the platform accepts it; a person may edit it first."

/-! ## Pull request metadata and diffs -/

private def setPull (job : Job) (p : GitHub.Pull) : Job :=
  { job with headSha := job.headSha <|> some p.headSha, baseSha := job.baseSha <|> some p.baseSha
             title := job.title <|> some p.title, prBody := job.prBody <|> some p.body }

/-- Whether `job` already knows its head, base and title. -/
private def hasPull (job : Job) : Bool :=
  job.headSha.isSome && job.baseSha.isSome && job.title.isSome

/-- Why a diff could not be had. -/
inductive DiffError where
  /-- The job names no head commit. -/
  | noHead
  /-- No GitHub client is configured, and the diff is not cached. -/
  | unavailable
  | github (why : String)

def DiffError.message : DiffError → String
  | .noHead => "the job names no head commit yet"
  | .unavailable => "GitHub is not configured (DIFF_REVIEWER_GITHUB_TOKEN_FILE)"
  | .github why => why

/-- The head commit and diff of `job`: from the cache, or from GitHub, then cached. A job that does
    not know its base yet takes the pull request's current one. -/
def diffOf (s : Services) (job : Job) : IO (Except DiffError (String × String)) := do
  let some head := job.headSha | return .error .noHead
  if let some base := job.baseSha then
    if let some d ← Platform.cachedDiff job.owner job.name base head then return .ok (head, d)
  let some gh := s.github | return .error .unavailable
  let base ← match job.baseSha with
    | some b => pure b
    | none => match ← gh.getPull job.owner job.name job.prNumber with
      | .ok p => pure p.baseSha
      | .error e => return .error (.github e)
  if let some d ← Platform.cachedDiff job.owner job.name base head then return .ok (head, d)
  match ← gh.diff job.owner job.name base head with
  | .error e => return .error (.github e)
  | .ok d =>
    Platform.cacheDiff job.owner job.name base head d
    return .ok (head, d)

/-! ## Posting -/

inductive PostError where
  | notFound
  | conflict (why : String)
  /-- No GitHub client is configured. -/
  | unavailable
  /-- GitHub refused or could not be reached; the job, with the error recorded, is still
      `approved`. -/
  | github (why : String) (job : Job)

/-- Post job `id`'s review to its pull request and mark it `posted`. The job must be `approved` and,
    when `version` is given, at that version; the review is pinned to the job's head commit.

    If GitHub refuses, the job stays `approved` with the reason in its `error`, so that it can be
    posted again. Once GitHub has the review the job is `posted` whatever happened to it meanwhile
    — that is now what happened — with the review that was posted. -/
def postJob (s : Services) (id : String) (version : Option Nat := none) :
    IO (Except PostError Job) := do
  let claimed ← s.posting.modifyGet fun ids =>
    if ids.contains id then (false, ids) else (true, id :: ids)
  unless claimed do return .error (.conflict s!"job {id} is being posted already")
  try
    let some job ← Platform.findJob id | return .error .notFound
    unless job.status? == some .approved do
      return .error (.conflict s!"job {id} is {job.statusRaw}; only an approved review is posted")
    if let some v := version then
      unless job.version == v do
        return .error (.conflict s!"job {id} has changed since it was read (version {v}, now \
{job.version}); reload it")
    let some (.ok review) := job.review?
      | return .error (.conflict s!"job {id} has no review this build can read")
    let some head := job.headSha
      | return .error (.conflict s!"job {id} names no head commit to pin the review to")
    let some gh := s.github | return .error .unavailable
    match ← gh.postReview job.owner job.name job.prNumber review (some head) (pending := false) with
    | .error e =>
      let recorded ← Platform.updateJob id fun j => do
        unless j.status? == some .approved do throw (.conflict "moved on")
        return { j with error := some s!"posting failed: {e}" }
      return .error (.github e (match recorded with | .ok j => j | .error _ => job))
    | .ok url =>
      s.log s!"posted the review of {job.owner}/{job.name}#{job.prNumber} (job {id}): {url}"
      match ← Platform.updateJob id fun j =>
          return { j.setReview review with statusRaw := JobStatus.posted.toString, error := none }
      with
      | .ok j => return .ok j
      | .error _ => return .error .notFound
  finally
    s.posting.modify (·.erase id)

/-- After the agent's submission to a `direct` repository: approve the draft at `version` and post
    it. -/
def postDirect (s : Services) (id : String) (version : Nat) : IO (Except PostError Job) := do
  let approved ← Platform.updateJob id fun j => do
    unless j.status? == some .draft && j.version == version do
      throw (.conflict s!"job {id} changed before it could be posted")
    return { j with statusRaw := JobStatus.approved.toString }
  match approved with
  | .error .notFound => return .error .notFound
  | .error (.conflict why) | .error (.invalid why) => return .error (.conflict why)
  | .ok j => postJob s id (some j.version)

/-! ## The loop -/

/-- Record `why` as job `id`'s error while it is still `status`, unless it is the error already
    recorded: a failure repeated on every pass must not bump the version every pass, or a person's
    page would be stale before they could act on it. -/
private def recordError (id : String) (status : JobStatus) (why : String) : IO Unit := do
  let some job ← Platform.findJob id | return
  if job.error == some why || job.status? != some status then return
  let _ ← Platform.updateJob id fun j => do
    unless j.status? == some status do throw (.conflict "moved on")
    return { j with error := some why }

/-- Discovery: a job for every new head of an open pull request of an `autoReview` repository, and
    `stale` for the drafts and approvals of heads that are no longer the pull request's. GitHub
    draft pull requests are left until they are marked ready for review. -/
def discover (s : Services) : IO Unit := do
  let repos := (← Platform.listRepos).filter (·.autoReview)
  if repos.isEmpty then return
  let some gh := s.github
    | s.logOnce "discover-no-github" "GitHub is not configured (DIFF_REVIEWER_GITHUB_TOKEN_FILE); \
repositories with autoReview are not searched for pull requests"
  for repo in repos do
    match ← gh.listOpenPulls repo.owner repo.name with
    | .error e => s.log s!"discovery on {repo.slug}: {e}"
    | .ok pulls =>
      for p in pulls do
        if p.draft then continue
        if let some job ← Platform.createJobForHead repo p.number p.headSha
            (some p.baseSha) (some p.title) (some p.body) then
          s.log s!"new job {job.id} for {repo.slug}#{p.number} at {p.headSha}"
        for old in ← Platform.jobsOfPull repo.owner repo.name p.number do
          let some sha := old.headSha | continue
          if sha == p.headSha then continue
          unless old.status? == some .draft || old.status? == some .approved do continue
          let _ ← Platform.updateJob old.id fun j => do
            unless j.version == old.version do throw (.conflict "moved on")
            return { j with statusRaw := JobStatus.stale.toString
                            error := some s!"the pull request moved on to {p.headSha}" }

/-- Orchestra's id for attempt `attempts` at job `id`: the id itself for the first, so that it is
    the job id the contract names, and `id.n` for the `n`th, since orchestra answers an id it has
    seen with the entry it already made. -/
def externalId (id : String) (attempts : Nat) : String :=
  if attempts == 0 then id else s!"{id}.{attempts + 1}"

/-- Queueing: every `pending` job of a registered repository, onto orchestra. -/
def queuePending (s : Services) : IO Unit := do
  let jobs ← Platform.jobsWithStatus [.pending]
  if jobs.isEmpty then return
  let some orch := s.orchestra
    | s.logOnce "queue-no-orchestra" "orchestra is not configured (DIFF_REVIEWER_ORCHESTRA_URL, \
DIFF_REVIEWER_ORCHESTRA_TOKEN_FILE); pending jobs stay pending"
  for job in jobs do
    if (← Platform.findRepo job.owner job.name).isNone then continue
    let mut job := job
    unless hasPull job do
      let some gh := s.github
        | recordError job.id .pending "the job does not know its pull request's head and base, \
and GitHub is not configured to read them"
          continue
      match ← gh.getPull job.owner job.name job.prNumber with
      | .ok p => job := setPull job p
      | .error e =>
        recordError job.id .pending s!"reading the pull request: {e}"
        continue
    let req : Orchestra.QueueRequest :=
      { prompt := prompt job, goal := goal job, upstream := s!"{job.owner}/{job.name}"
      , issueNumber := job.prNumber, externalId := externalId job.id job.attempts }
    match ← orch.queue req with
    | .error e => recordError job.id .pending s!"queueing on orchestra: {e}"
    | .ok entry =>
      let r ← Platform.updateJob job.id fun j => do
        unless j.status? == some .pending do throw (.conflict "moved on")
        return { j with headSha := job.headSha, baseSha := job.baseSha, title := job.title
                        prBody := job.prBody, statusRaw := JobStatus.queued.toString
                        queueEntry := some entry.id, attempts := j.attempts + 1, error := none }
      match r with
      | .ok _ => s.log s!"queued job {job.id} as orchestra entry {entry.id}"
      | .error _ => s.log s!"job {job.id} changed while it was queued as entry {entry.id}"

/-- The entry that `id` has become, following `continuedBy` (a bounded number of times, so that a
    cycle cannot hold the loop). -/
private def latestEntry (orch : Orchestra.Client) (id : String) :
    IO (Except String Orchestra.Entry) := do
  let first ← orch.entry id
  let .ok first := first | return first
  let mut e := first
  for _ in [0:16] do
    let some next := e.continuedBy | break
    match ← orch.entry next with
    | .ok n => e := n
    | .error err => return .error err
  return .ok e

/-- Following: move each queued or running job as its orchestra entry moves. -/
def follow (s : Services) : IO Unit := do
  let jobs ← Platform.jobsWithStatus [.queued, .running]
  let some orch := s.orchestra | return
  for job in jobs do
    let some entryId := job.queueEntry | continue
    match ← latestEntry orch entryId with
    | .error e => s.log s!"following job {job.id} (entry {entryId}): {e}"
    | .ok e =>
      let next : Option JobStatus :=
        if Orchestra.terminal e.status then some .failed
        else if e.status == "running" && job.status? == some .queued then some .running
        else none
      if next.isNone && e.id == entryId then continue
      let _ ← Platform.updateJob job.id fun j => do
        unless j.status? == some .queued || j.status? == some .running do
          throw (.conflict "moved on")
        let j := { j with queueEntry := some e.id }
        match next with
        | some .failed =>
          return { j with statusRaw := JobStatus.failed.toString
                          error := some s!"the run ended ({e.status}) without submitting a review" }
        | some st => return { j with statusRaw := st.toString }
        | none => return j

/-- One pass of the loop. A step that throws is logged, and the next step still runs. -/
def tick (s : Services) : IO Unit := do
  for (what, step) in [("discovery", discover s), ("queueing", queuePending s),
                       ("following", follow s)] do
    try step catch e => s.log s!"{what}: {e}"

/-- Run `tick` every `interval` seconds, on a thread of its own, for as long as the process. -/
def start (s : Services) (interval : Nat) : IO Unit := do
  let _ ← IO.asTask (prio := .dedicated) do
    repeat
      tick s
      IO.sleep (interval * 1000).toUInt32
  return

end DiffReviewer.Workers