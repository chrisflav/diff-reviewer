import DiffReviewer.Platform
import DiffReviewer.GitHub
import DiffReviewer.Orchestra
import DiffReviewer.Diff

open Lean (Json)

/-!
# The platform's own moves

What `serve` does without being asked, on a loop every `--interval` seconds (`start`):

  * **discovery** — for each repository with `autoReview`, list its open pull requests and make a
    job for every head commit that has none, at most `maxJobsPerDay` a day per repository. A job of
    an older head of the same pull request is `stale` — its line numbers no longer name the code
    under review — and if it is queued or running, its orchestra run is cancelled: nothing is spent
    on a commit nobody will merge.
  * **queueing** — check each `pending` job's head is still its pull request's, fetch its diff
    (a diff past `maxDiffBytes` fails the job), and put it on orchestra, as the platform's API
    client, recording the queue entry. Orchestra's `external_id` is the job's id (with the attempt
    for a retry), so a request whose answer was lost is answered with the entry it made rather than
    queued twice.
  * **following** — read each queued or running job's entry (and whatever entry continues it) and
    move the job to `running` when the run starts, or to `failed` when it ends without the agent
    having submitted a review.
  * **settling** — every claim to post older than its window is settled as
    `POST /api/v1/jobs/{id}/reconcile` would settle it (`settleClaims`): a post whose outcome was
    unknown is not left holding its job until a person looks, which in a `direct` repository
    nobody may do.

And it drops the kept diffs no live job needs. On request: fetching a diff (`diffOf`, cached per
commit) and posting an approved review (`postJob`), which a person asks for, or the agent's
submission does for a `direct` repository.

## Posting once

A review posted twice under the operator's name cannot be taken back, and a request can time out
after GitHub has acted on it. So:

  * posting is claimed in the database (`post_started_at`) immediately before the one request
    made under the claim, the post. The claim is taken in a `BEGIN IMMEDIATE` transaction that
    requires the job still `approved`, at the version read and with the claim read, so of any
    number of processes on one database that read the same job, at most one claims it.
  * a claim younger than `postClaimSeconds` — three times the post's timeout — is never taken
    over, so a claim is taken over only once the request made under it has certainly ended.
  * the posted body carries the marker `<!-- diff-reviewer job <id> -->`, and an older claim is
    settled before anything is posted again: the pull request's reviews by the operator
    (`DIFF_REVIEWER_GITHUB_LOGIN`) are searched for the marker, and a review found is recorded
    as posted — GitHub's id, URL and body.
  * only a definite refusal (a `4xx`) clears the claim. No answer, or a `5xx`, keeps it, even when
    the review is not to be found yet.
  * while a claim stands, the job cannot leave `approved`, have its review edited or be made
    `stale` (`Job.claimBlocks`): what it says is what may have been posted. Posting it again
    settles the claim.

Only a person's `POST /api/v1/jobs/{id}/post` posts an approval or a request for changes. A
`direct` repository's review is always posted as a comment, and so is any review of a pull request
the operator (`DIFF_REVIEWER_GITHUB_LOGIN`) wrote, which GitHub would refuse; the job's `postNote`
says so.

The clients are passed in as `Services`, so that the suite runs all of it against fakes. Without
an orchestra client the platform still runs — jobs simply stay `pending` — and says so once.

None of these hold the store's lock across a call to GitHub or orchestra: each reads what it
needs, makes the call, and writes the outcome with `Platform.updateJob`, whose function re-checks
that the job is still in the state the call was made for.
-/

namespace DiffReviewer.Workers

/-- The bounds the workers keep to. -/
structure Limits where
  /-- New jobs discovery makes per repository in 24 hours. -/
  maxJobsPerDay : Nat := 50
  /-- The largest diff reviewed, in bytes. -/
  maxDiffBytes : Nat := GitHub.defaultMaxDiffBytes
  /-- The GitHub login reviews are posted as, when known. -/
  githubLogin : Option String := none
  /-- Days a fetched diff is kept at most. -/
  diffRetentionDays : Nat := 30
  /-- How long a claim to post is taken to be a post still in flight, perhaps from another
      process; past it, the claim is an attempt whose outcome must be checked. Three times the
      timeout of the one request made under the claim, the post itself: nothing else is done
      while it is held. -/
  postClaimSeconds : Nat := 3 * GitHub.requestTimeout

structure Services where
  github    : Option GitHub.Client
  orchestra : Option Orchestra.Client
  log       : String → IO Unit
  limits    : Limits
  /-- The jobs being posted right now, so that two requests to post one review post it once. -/
  posting   : IO.Ref (List String)
  /-- The keys of the messages `logOnce` has already written. -/
  logged    : IO.Ref (List String)

def Services.new (github : Option GitHub.Client := none)
    (orchestra : Option Orchestra.Client := none)
    (log : String → IO Unit := fun m => IO.eprintln s!"diff-reviewer: {m}")
    (limits : Limits := {}) : IO Services := do
  return { github, orchestra, log, limits, posting := ← IO.mkRef [], logged := ← IO.mkRef [] }

private def nowEpoch : IO Int :=
  return (← Std.Time.Timestamp.now).toSecondsSinceUnixEpoch.val

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

1. Run `diff-reviewer agent show {slug} {job.prNumber} --job {job.id}`. It prints the pull \
request — its head and base commits, title and description — and the instructions for the \
review; follow them.
2. The repository is checked out read-only in your working directory. Check out the head commit it \
names (`git fetch origin pull/{job.prNumber}/head && git checkout <headSha>`) and read the change \
in context. `diff-reviewer agent diff {slug} {job.prNumber} --job {job.id}` prints the diff under \
review.
3. Pick the pull request type, of the `prTypes` it printed, whose description fits the change, \
and review the change by that type's `rubric` together with the `instructions` (with no `prTypes`, \
by the `instructions` alone). Give every inline comment a `severity` (`nit`, `minor`, `major` or \
`blocker`) and a `category`, one of that type's `categories` when it lists any.
4. Write the review as a JSON file `\{\"headSha\": …, \"prType\": …, \"review\": …}`, with \
`prType` the name of the type you picked (or null when there are no `prTypes`), and submit it with \
`diff-reviewer agent submit {slug} {job.prNumber} <file> --job {job.id}`. Fix what it reports and \
submit again until it is accepted.

A review may carry at most {maxInlineComments} inline comments; merge or drop the least \
important rather than exceed it.

Do not comment on, review or otherwise write to the pull request on GitHub yourself: the review \
is posted, once accepted, by the platform."

/-- The checkable sentence the run is held to. -/
def goal (job : Job) : String :=
  s!"`diff-reviewer agent submit {job.owner}/{job.name} {job.prNumber}` accepted a review of the \
pull request."

/-- How to review and how to write the review, in markdown: what every repository's
    `instructions` start with (`instructionsFor`). -/
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
  \"prType\": \"<the name of the pull request type you picked, or null>\",
  \"review\": {
    \"decision\": \"comment\",
    \"body\": \"The summary: what matters most, in a few sentences.\",
    \"comments\": [
      {\"file\": \"path/in/repo.lean\", \"start_line\": 10, \"end_line\": 12,
       \"body\": \"Why this is a problem.\", \"suggestion\": \"optional replacement lines\",
       \"category\": \"correctness\", \"severity\": \"major\"}
    ]
  }
}
```

- `prType` is the name of one of the `prTypes` listed with these instructions: the one whose
  description fits the pull request. Review it by that type's `rubric` as well as by this text.
  With no `prTypes` listed, it is `null`.
- Every comment has a `severity`: `nit` (take it or leave it), `minor` (worth fixing), `major`
  (should be fixed before merging) or `blocker` (must be). And a `category`: one of the picked
  type's `categories` when it lists any, otherwise a word or two of your own for what the comment
  is about.
- `decision` is `comment`, `approve` or `request_changes`.
- A comment's lines are line numbers of the file at the head commit (the right-hand side of the
  diff), and must lie in a hunk of the diff. `suggestion`, when given, replaces lines
  `start_line`..`end_line` exactly.
- At most 200 inline comments: if you have more, merge related ones or drop the least important.
- A review is posted only after the platform accepts it; a person may edit it first."

/-- The `instructions` of `GET /api/agent/v1/…/pulls/{pr}`: how to review, then the repository's
    default rubric, when it has one. The pull request types, each with its own rubric, are beside
    them in `prTypes`. -/
def instructionsFor (doc : Option Rubric) : String :=
  match doc with
  | some d =>
    if d.defaultRubric.trimAscii.isEmpty then instructions
    else instructions ++ "\n\n# The repository's rubric\n\n" ++ d.defaultRubric
  | none => instructions

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
  /-- The diff is past `maxDiffBytes`. -/
  | tooLarge (why : String)
  | github (why : String)

def DiffError.message : DiffError → String
  | .noHead => "the job names no head commit yet"
  | .unavailable => "GitHub is not configured (DIFF_REVIEWER_GITHUB_TOKEN_FILE)"
  | .tooLarge why | .github why => why

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
      | .error e => return .error (.github e.message)
  if let some d ← Platform.cachedDiff job.owner job.name base head then return .ok (head, d)
  match ← gh.diff job.owner job.name base head with
  | .error (.tooLarge n) => return .error (.tooLarge (GitHub.Error.tooLarge n).message)
  | .error e => return .error (.github e.message)
  | .ok d =>
    if d.utf8ByteSize > s.limits.maxDiffBytes then
      return .error (.tooLarge (GitHub.Error.tooLarge s.limits.maxDiffBytes).message)
    Platform.cacheDiff job.owner job.name base head d
    return .ok (head, d)

/-! ## Posting -/

inductive PostError where
  | notFound
  | conflict (why : String)
  /-- No GitHub client is configured. -/
  | unavailable
  /-- GitHub refused, or could not be reached; the job, with the error recorded, is still
      `approved`. -/
  | github (why : String) (job : Job)

/-- The marker the posted body of job `id`'s review ends with, by which it is found again. -/
def marker (id : String) : String := s!"<!-- diff-reviewer job {id} -->"

/-- The review as it is posted: its body, then the marker. -/
def withMarker (id : String) (r : Review) : Review :=
  { r with body := if r.body.isEmpty then marker id else r.body ++ "\n\n" ++ marker id }

/-- The review of job `id` already on the pull request, if there is one: one carrying its marker,
    by the operator. Anyone may write the marker into a review of their own; with
    `DIFF_REVIEWER_GITHUB_LOGIN` unset there is no telling theirs from the platform's, which is
    said once. -/
private def findPosted (s : Services) (gh : GitHub.Client) (job : Job) :
    IO (Except GitHub.Error (Option GitHub.PostedReview)) := do
  if s.limits.githubLogin.isNone then
    s.logOnce "forged-markers" "DIFF_REVIEWER_GITHUB_LOGIN is not set: a review somebody else \
wrote with a job's marker in it cannot be told from the platform's own"
  let byOperator (r : GitHub.PostedReview) : Bool :=
    s.limits.githubLogin.all (·.toLower == r.author.toLower)
  return (← gh.listReviews job.owner job.name job.prNumber).map fun rs =>
    rs.find? fun r => byOperator r && (r.body.splitOn (marker job.id)).length > 1

/-- What a review is posted as, and why, when that is not its own decision. -/
def postedEvent (direct : Bool) (decision : Decision) (author login : Option String) :
    Decision × Option String :=
  if decision == .comment then (.comment, none)
  else if direct then
    (.comment, some "posted as a comment: in direct mode the platform never approves or requests \
changes")
  else if author.isSome && author.map (·.toLower) == login.map (·.toLower) then
    (.comment, some s!"posted as a comment: {author.getD ""} wrote the pull request, and GitHub \
does not let its author approve it or request changes")
  else (decision, none)

/-- What GitHub holds of job `job`'s review once posted as `r`, for the job's history: the job's
    review with GitHub's body, without the marker, and the event it was posted as when that is
    known. The comments are the job's: the claim kept them from being edited meanwhile. -/
def postedRevision (job : Job) (r : GitHub.PostedReview) (event : Option Decision) : String :=
  let m := marker job.id
  let body :=
    if r.body.endsWith ("\n\n" ++ m) then (r.body.dropEnd (m.length + 2)).toString
    else if r.body.endsWith m then (r.body.dropEnd m.length).toString
    else r.body
  let base := (job.reviewRaw.bind (Json.parse · |>.toOption)).getD (.mkObj [])
  let base := if base.getObj?.isOk then base else .mkObj []
  let base := base.setObjVal! "body" body
  (match event with
    | some e => base.setObjVal! "decision" e.toJson
    | none => base).compress

/-- Mark `job` posted as `r`, GitHub's record of it, posted as `event` when that is known. The
    job's own review is left as it is, which the claim kept from being edited meanwhile; what
    GitHub holds is appended to its history. -/
private def recordPosted (s : Services) (job : Job) (r : GitHub.PostedReview)
    (note : Option String) (event : Option Decision := none) : IO (Except PostError Job) := do
  s.log s!"posted the review of {job.owner}/{job.name}#{job.prNumber} (job {job.id}): {r.url}"
  let revision (j : Job) : Option (Author × String) := some (.github, postedRevision j r event)
  match ← Platform.updateJob job.id (revision := revision) fun j =>
      return { j with statusRaw := JobStatus.posted.toString, error := none
                      postStartedAt := none, postedUrl := some r.url
                      postedReview := some r.toJson.compress, postNote := note }
  with
  | .ok j => return .ok j
  | .error _ => return .error .notFound

/-- Post job `id`'s review to its pull request and mark it `posted`. The job must be `approved` and,
    when `version` is given, at that version; the review is pinned to the job's head commit, and
    its comments are checked against the diff first. `direct` posts it as a comment, whatever its
    decision.

    See "Posting once" above: an earlier claim is settled first, the claim is written just before
    GitHub is asked, the body carries the marker, and an unknown outcome is settled by looking for
    the marker. If GitHub refuses, the job stays `approved` with the reason in its `error`, so that
    it can be posted again. Once GitHub has the review the job is `posted`, with GitHub's record of
    what was posted. -/
def postJob (s : Services) (id : String) (version : Option Nat := none) (direct := false) :
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
    if let .error e := review.validate then
      return .error (.conflict s!"job {id}'s review would be refused by GitHub: {e}")
    let some head := job.headSha
      | return .error (.conflict s!"job {id} names no head commit to pin the review to")
    let some gh := s.github | return .error .unavailable
    if let .ok (_, d) ← diffOf s job then
      if let .error e := Diff.check review d then
        return .error (.conflict s!"job {id}'s review would be refused by GitHub: {e}")
    let markPosted (r : GitHub.PostedReview) (note : Option String)
        (event : Option Decision := none) : IO (Except PostError Job) :=
      recordPosted s job r note event
    -- Leave the job to be posted again, with why; `keepClaim` while whether it was posted is
    -- still unknown, so that the next attempt waits out the claim and looks before it posts.
    let failed (why : String) (keepClaim : Bool) : IO (Except PostError Job) := do
      let recorded ← Platform.updateJob id fun j =>
        return { j with error := some why
                        postStartedAt := if keepClaim then j.postStartedAt else none }
      return .error (.github why (match recorded with | .ok j => j | .error _ => job))
    -- A claim an earlier attempt left. Recent, it may be a post still under way; older, its
    -- outcome is settled before anything else is done.
    if let some t := job.postStartedAt then
      let recent := isoOfEpoch ((← nowEpoch) - s.limits.postClaimSeconds)
      if t > recent then
        return .error (.conflict s!"posting job {id} began at {t} and may still be under way; \
try again in a few minutes")
      match ← findPosted s gh job with
      | .ok (some r) =>
        return ← markPosted r (some "found on GitHub after an attempt whose outcome was unknown")
      | .ok none => pure ()
      | .error e =>
        return ← failed s!"an earlier attempt to post may have succeeded, and GitHub's reviews \
could not be read to tell ({e.message})" true
    let author ← if s.limits.githubLogin.isNone || direct then pure none else
      pure ((← gh.getPull job.owner job.name job.prNumber).toOption.map (·.author))
    let (event, note) := postedEvent direct review.decision author s.limits.githubLogin
    -- The claim, taken last, so that the post is the only thing done under it: in one
    -- transaction with the checks that the job is still approved, at the version read, and its
    -- claim the one read — so of two processes that read the same job, one claims it.
    let now ← nowEpoch
    let claim ← Platform.updateJob id fun j => do
      unless j.status? == some .approved do
        throw (.conflict s!"job {id} is {j.statusRaw}; only an approved review is posted")
      unless j.version == job.version && j.postStartedAt == job.postStartedAt do
        throw (.conflict s!"job {id} changed while it was being posted; reload it")
      return { j with postStartedAt := some (isoOfEpoch now) }
    if let .error e := claim then
      return .error (match e with
        | .notFound => .notFound
        | .conflict why | .invalid why => .conflict why)
    match ← gh.postReview job.owner job.name job.prNumber (withMarker id review) (some head)
        (some event) with
    | .ok r => markPosted r note (some event)
    | .error (.definite why) => failed s!"posting failed: {why}" false
    | .error e =>
      -- No answer, or a 5xx: the review may yet appear. The claim is kept either way, until it is
      -- found or a later attempt, past the claim's window, has looked and not found it.
      match ← findPosted s gh job with
      | .ok (some r) => markPosted r note (some event)
      | .ok none =>
        failed s!"posting may have failed ({e.message}); it is looked for again before the next \
attempt" true
      | .error e2 =>
        failed s!"posting may have failed ({e.message}); GitHub's reviews could not be read to \
tell ({e2.message}), and are looked at before the next attempt" true
  finally
    s.posting.modify (·.erase id)

/-- Settle job `id`'s claim without posting: a person's way to free a job whose post may have
    reached GitHub, so that it can be edited, rejected or left to go stale. The job must be
    `approved`, at `version`, and claimed. The marker found among the operator's reviews makes it
    `posted`; not found, the claim is cleared once its window has passed (within it, a post may
    still be under way: `conflict`); reviews that cannot be read leave the claim as it is. -/
def reconcileJob (s : Services) (id : String) (version : Nat) : IO (Except PostError Job) := do
  let claimed ← s.posting.modifyGet fun ids =>
    if ids.contains id then (false, ids) else (true, id :: ids)
  unless claimed do return .error (.conflict s!"job {id} is being posted right now")
  try
    let some job ← Platform.findJob id | return .error .notFound
    unless job.status? == some .approved && job.version == version do
      return .error (.conflict s!"job {id} is {job.statusRaw} at version {job.version}, not an \
approved job at version {version}; reload it")
    let some started := job.postStartedAt
      | return .error (.conflict s!"job {id} has no post to settle")
    let some gh := s.github | return .error .unavailable
    match ← findPosted s gh job with
    | .ok (some r) =>
      recordPosted s job r (some "found on GitHub after an attempt whose outcome was unknown")
    | .ok none =>
      let recent := isoOfEpoch ((← nowEpoch) - s.limits.postClaimSeconds)
      if started > recent then
        return .error (.conflict s!"posting job {id} began at {started} and may still be under \
way; try again in a few minutes")
      match ← Platform.updateJob id fun j => do
          unless j.version == job.version && j.postStartedAt == job.postStartedAt do
            throw (.conflict s!"job {id} changed while it was being checked; reload it")
          return { j with postStartedAt := none
                          error := some "the post did not reach GitHub; the job is free again" }
      with
      | .ok j => return .ok j
      | .error .notFound => return .error .notFound
      | .error (.conflict why) | .error (.invalid why) => return .error (.conflict why)
    | .error e =>
      let why := s!"GitHub's reviews could not be read to tell whether the post reached it \
({e.message}); the claim stands"
      -- Written once: settling runs on every pass, and must not bump the version every pass.
      if job.error == some why then return .error (.github why job)
      let recorded ← Platform.updateJob id fun j => return { j with error := some why }
      return .error (.github why (match recorded with | .ok j => j | .error _ => job))
  finally
    s.posting.modify (·.erase id)

/-- After the agent's submission to a `direct` repository: approve the draft at `version` and post
    it, as a comment. -/
def postDirect (s : Services) (id : String) (version : Nat) : IO (Except PostError Job) := do
  let approved ← Platform.updateJob id fun j => do
    unless j.status? == some .draft && j.version == version do
      throw (.conflict s!"job {id} changed before it could be posted")
    return { j with statusRaw := JobStatus.approved.toString }
  match approved with
  | .error .notFound => return .error .notFound
  | .error (.conflict why) | .error (.invalid why) => return .error (.conflict why)
  | .ok j => postJob s id (some j.version) (direct := true)

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

/-- Move `job` to `to` (`stale` or `failed`) with `why`, if it is still in the status it was read
    in. A queued or running job's orchestra run is cancelled first: nothing more is to be spent on
    it. -/
def retire (s : Services) (job : Job) (to : JobStatus) (why : String) : IO Unit := do
  if job.status? == some .queued || job.status? == some .running then
    if let (some orch, some entry) := (s.orchestra, job.queueEntry) then
      if let .error e ← orch.cancel entry then
        s.log s!"cancelling entry {entry} of job {job.id}: {e}"
  let _ ← Platform.updateJob job.id fun j => do
    unless j.statusRaw == job.statusRaw do throw (.conflict "moved on")
    if let some why := j.claimBlocks then throw (.conflict why)
    return { j with statusRaw := to.toString, error := some why }
  s.log s!"job {job.id} is {to.toString}: {why}"

/-- The statuses in which a job of a superseded head is made `stale`. -/
private def supersedable : List JobStatus := [.pending, .queued, .running, .draft, .approved]

/-- Discovery: a job for every new head of an open pull request of an `autoReview` repository, up
    to `maxJobsPerDay` a day, and `stale` for the jobs of heads that are no longer the pull
    request's. GitHub draft pull requests are left until they are marked ready for review. -/
def discover (s : Services) : IO Unit := do
  let repos := (← Platform.listRepos).filter (·.autoReview)
  if repos.isEmpty then return
  let some gh := s.github
    | s.logOnce "discover-no-github" "GitHub is not configured (DIFF_REVIEWER_GITHUB_TOKEN_FILE); \
repositories with autoReview are not searched for pull requests"
  for repo in repos do
    match ← gh.listOpenPulls repo.owner repo.name with
    | .error e => s.log s!"discovery on {repo.slug}: {e.message}"
    | .ok pulls =>
      let now ← nowEpoch
      let mut made ← Platform.jobsSince repo.owner repo.name (isoOfEpoch (now - 86400))
      for p in pulls do
        if p.draft then continue
        let jobs ← Platform.jobsOfPull repo.owner repo.name p.number
        unless jobs.any (·.headSha == some p.headSha) do
          if made ≥ s.limits.maxJobsPerDay then
            s.logOnce s!"cap-{repo.slug}-{now / 86400}" s!"{repo.slug} has had \
{s.limits.maxJobsPerDay} new jobs in 24 hours, the most allowed (--max-jobs-per-day); its new \
heads wait"
          else if let some job ← Platform.createJobForHead repo p.number p.headSha
              (some p.baseSha) (some p.title) (some p.body) then
            made := made + 1
            s.log s!"new job {job.id} for {repo.slug}#{p.number} at {p.headSha}"
        for old in jobs do
          let some sha := old.headSha | continue
          if sha == p.headSha then continue
          unless old.status?.any (supersedable.contains ·) do continue
          -- A post of it may have reached GitHub: left until that is settled.
          if old.claimBlocks.isSome then continue
          retire s old .stale s!"the pull request moved on to {p.headSha}"

/-- Orchestra's id for attempt `attempts` at job `id`: the id itself for the first, so that it is
    the job id the contract names, and `id.n` for the `n`th, since orchestra answers an id it has
    seen with the entry it already made. -/
def externalId (id : String) (attempts : Nat) : String :=
  if attempts == 0 then id else s!"{id}.{attempts + 1}"

/-- Queueing: every `pending` job of a registered repository whose head is still its pull
    request's, onto orchestra, once its diff has been fetched and found small enough. -/
def queuePending (s : Services) : IO Unit := do
  let jobs ← Platform.jobsWithStatus [.pending]
  if jobs.isEmpty then return
  let some orch := s.orchestra
    | s.logOnce "queue-no-orchestra" "orchestra is not configured (DIFF_REVIEWER_ORCHESTRA_URL, \
DIFF_REVIEWER_ORCHESTRA_TOKEN_FILE); pending jobs stay pending"
  for job in jobs do
    if (← Platform.findRepo job.owner job.name).isNone then continue
    let mut job := job
    match s.github with
    | none =>
      unless hasPull job do
        recordError job.id .pending "the job does not know its pull request's head and base, \
and GitHub is not configured to read them"
        continue
    | some gh =>
      match ← gh.getPull job.owner job.name job.prNumber with
      | .error e =>
        recordError job.id .pending s!"reading the pull request: {e.message}"
        continue
      | .ok p =>
        if p.state != "open" then
          retire s job .stale s!"the pull request is {p.state}"
          continue
        if job.headSha.any (· != p.headSha) then
          retire s job .stale s!"the pull request moved on to {p.headSha}"
          continue
        job := setPull job p
      match ← diffOf s job with
      | .ok _ => pure ()
      | .error (.tooLarge why) =>
        retire s job .failed why
        continue
      | .error e =>
        recordError job.id .pending s!"reading the diff: {e.message}"
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

/-- Settling: every claim to post older than its window, settled as a person's
    `POST /api/v1/jobs/{id}/reconcile` settles it — found on GitHub, the job is `posted`; not
    found, the claim is cleared — and logged. A claim within its window may be a post under way,
    and is left to it. -/
def settleClaims (s : Services) : IO Unit := do
  let some _ := s.github | return
  let recent := isoOfEpoch ((← nowEpoch) - s.limits.postClaimSeconds)
  for job in ← Platform.jobsWithStatus [.approved] do
    let some started := job.postStartedAt | continue
    if started > recent then continue
    let what := s!"the post of job {job.id} ({job.owner}/{job.name}#{job.prNumber}, begun \
{started})"
    match ← reconcileJob s job.id job.version with
    | .ok j =>
      if j.status? == some .posted then
        s.log s!"settled {what}: it reached GitHub, {j.postedUrl.getD "?"}; the job is posted"
      else
        s.log s!"settled {what}: it did not reach GitHub; the job is approved and free again"
    | .error (.github why _) => s.logOnce s!"settle-{job.id}-{why}" s!"settling {what}: {why}"
    -- Moved meanwhile, or being posted right now: nothing to settle on this pass.
    | .error _ => pure ()

/-- One pass of the loop. A step that throws is logged, and the next step still runs. -/
def tick (s : Services) : IO Unit := do
  let prune : IO Unit := do
    let before := isoOfEpoch ((← nowEpoch) - s.limits.diffRetentionDays * 86400)
    let n ← Platform.pruneDiffs before
    if n > 0 then s.log s!"dropped {n} kept diff(s)"
  for (what, step) in [("discovery", discover s), ("queueing", queuePending s),
                       ("following", follow s), ("settling claims", settleClaims s),
                       ("pruning diffs", prune)] do
    try step catch e => s.log s!"{what}: {e}"

/-- Run `tick` every `interval` seconds, on a thread of its own, for as long as the process. A pass
    that throws anyway is logged, and the loop goes on: a worker that died would stop every review
    without a word. -/
def start (s : Services) (interval : Nat) : IO Unit := do
  let _ ← IO.asTask (prio := .dedicated) do
    repeat
      try tick s catch e => s.log s!"worker pass: {e}"
      IO.sleep (interval * 1000).toUInt32
  return

end DiffReviewer.Workers