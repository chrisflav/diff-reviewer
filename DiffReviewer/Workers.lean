import DiffReviewer.Platform
import DiffReviewer.GitHub
import DiffReviewer.Orchestra
import DiffReviewer.Diff
import DiffReviewer.Calibration
import DiffReviewer.Proposal
import DiffReviewer.Fanout

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
  * **calibration** — the queued imports of past reviews read on (`Calibration.importStep`, a
    bounded number of pull requests a pass), and every calibration job with a draft and no score
    scored (`Calibration.scorePending`).
  * **settling** — every claim to post older than its window is settled as
    `POST /api/v1/jobs/{id}/reconcile` would settle it (`settleClaims`): a post whose outcome was
    unknown is not left holding its job until a person looks, which in a `direct` repository
    nobody may do. There, a review the platform posted that is found not to have reached GitHub
    is posted again — as a comment, as every direct post is — if its pull request is still open
    at the job's head (otherwise the job is `stale`), up to `maxDirectPostAttempts` posts by the
    platform; then it is left `approved`, with why, for a person.

A job whose rubric asks for fan-out (`DiffReviewer.Fanout`) is not queued itself: queueing makes
its sub-runs — one per category and one for the default — in one transaction with the check of
the day's cap, and queues each as a task of its own (`queueSubRuns`), with a prompt that narrows
it to its category; following follows each, runs one that ended without a submission once more,
and merges the partial reviews into the job's draft once every sub-run has submitted or failed
(`settleFanout`). Retiring the job cancels its sub-runs' runs.

A review job of a pull request whose review was posted, at a new head, is an **incremental
re-review** — unless its repository turns that off (`incremental`). Queueing decides it
(`incrementalOf`): it compares the head the posted review was of with the new one, and when the
old descends into the new, the job records the posted review's job, that head and the commits
since, and the agent is shown the posted review and asked for the changes since — their diff
(`rangeDiffOf`) is what every comment must be on (`checkDiffs`), and the posted body names the
earlier review (`followUp`). A force-push, where the old head is no ancestor of the new, falls back
to a full review, with why on the job (`fullReviewReason`).

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
  * only a definite refusal (a `4xx`) clears the claim. No answer, a `5xx`, or GitHub's rate limit
    keeps it, even when the review is not to be found yet: a rate-limited post is retried once
    the claim is settled, after the limit has had time to reset, not at once.
  * while a claim stands, the job cannot leave `approved`, have its review edited or be made
    `stale` (`Job.claimBlocks`): what it says is what may have been posted. Posting it again
    settles the claim.

A `proposal` job (`DiffReviewer.Proposal`) is of a repository, not of a pull request: it is
queued with no `issue_number`, through the client for proposals (`Services.proposer`) — its task
needs a kleis spec of its own, and orchestra gives every task of one client the client's spec — and
is followed and cancelled through it. Without that client, proposal jobs stay `pending`, with why.
Nothing of GitHub is read for it, and it is never posted.

A `calibration` job (`DiffReviewer.Calibration`) is queued and run as a review is, at its sample's
commit and with its sample's base — the pull request is closed, so neither its state nor its head
is checked — and is never claimed or posted: `postJob`, `reconcileJob` and `postDirect` refuse it
before anything else, and the claim refuses it again in its transaction. Discovery leaves it alone.

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
  /-- The most times the platform posts a `direct` repository's review on its own — the post on
      submission and the ones after a settled claim found it had not reached GitHub; a person's
      posts are not counted. Past it a person has to post. -/
  maxDirectPostAttempts : Nat := 3
  /-- New calibration jobs runs may make per repository in 24 hours: a cap of their own, apart from
      `maxJobsPerDay`. -/
  maxCalibrationJobsPerDay : Nat := 20
  /-- Pull requests the calibration imports read in one pass, together. -/
  importPullsPerPass : Nat := 25
  /-- GitHub requests kept for discovery and posting: imports pause, until the limit resets, when
      fewer are left. -/
  githubReserve : Nat := 500
  /-- New rubric proposal jobs a person may ask for per repository in 24 hours. -/
  maxProposalsPerDay : Nat := 2

structure Services where
  github    : Option GitHub.Client
  orchestra : Option Orchestra.Client
  /-- The orchestra client rubric proposals are queued through: a client file of its own, whose
      `kleis_spec` (`rubric-proposer`) allows the agent's proposal routes, which the review
      client's (`reviewer`) must not. -/
  proposer  : Option Orchestra.Client
  log       : String → IO Unit
  limits    : Limits
  /-- The jobs being posted right now, so that two requests to post one review post it once. -/
  posting   : IO.Ref (List String)
  /-- The keys of the messages `logOnce` has already written. -/
  logged    : IO.Ref (List String)

def Services.new (github : Option GitHub.Client := none)
    (orchestra : Option Orchestra.Client := none)
    (log : String → IO Unit := fun m => IO.eprintln s!"diff-reviewer: {m}")
    (limits : Limits := {}) (proposer : Option Orchestra.Client := none) : IO Services := do
  return { github, orchestra, proposer, log, limits, posting := ← IO.mkRef []
         , logged := ← IO.mkRef [] }

/-- The orchestra client `job` is queued, followed and cancelled through. -/
def Services.orchestraFor (s : Services) (job : Job) : Option Orchestra.Client :=
  if job.kind? == some .proposal then s.proposer else s.orchestra

private def nowEpoch : IO Int :=
  return (← Std.Time.Timestamp.now).toSecondsSinceUnixEpoch.val

/-- Log `msg` the first time `key` is logged, and never again: for a state that holds on every
    pass of the loop, such as orchestra not being configured. -/
def Services.logOnce (s : Services) (key msg : String) : IO Unit := do
  let first ← s.logged.modifyGet fun ks =>
    if ks.contains key then (false, ks) else (true, key :: ks)
  if first then s.log msg

/-! ## What the agent is told -/

/-- What one sub-run of a fan-out review is to look at (`DiffReviewer.Fanout`). -/
structure Scope where
  sub      : Fanout.SubRun
  /-- The category it reviews, with what belongs in it; `none` for the default review. -/
  category : Option Category
  /-- The categories the other sub-runs review. -/
  others   : List String
  /-- What its agent names it by: `<job>.<key>`, and `<job>.<key>.<n>` for its `n`th run. -/
  ref      : String

/-- The id the agent names its job by: the job's, or the sub-run's (`Scope.ref`). -/
def agentRef (job : Job) (scope : Option Scope) : String :=
  match scope with
  | some sc => sc.ref
  | none => job.id

/-- What the prompt of an incremental re-review adds to its second step: what it follows up, and
    that it reviews the changes since, without repeating what the earlier review said. -/
private def incrementalNote (job : Job) (ref : String) : String :=
  match job.incrementalSince with
  | none => ""
  | some since =>
    let slug := s!"{job.owner}/{job.name}"
    s!"

   This pull request was reviewed before, at `{since}`, and that review was posted: `agent show` \
prints it as GitHub holds it (`incremental.postedReview`, with its comments) and the commits since \
(`incremental.commits`). Review the new changes only: \
`diff-reviewer agent diff {slug} {job.prNumber} --since {since} --job {ref}` prints their diff, \
and every inline comment must be on a line of it. Do not repeat a point the earlier review made; \
say in the summary which of its points the new commits resolve."

/-- The step of `prompt` that has the agent check out the commit under review. A calibration
    job's commit is of a pull request that has since been closed. The task's checkout is the
    repository's default branch, mounted read-only — which may well hold the change as it was
    merged, after the review — so the agent reviews from the platform's diff, reads files at the
    commit with `git show` where the clone has it, and is told to read no other ref; what was said
    of the pull request on GitHub its token's narrowing (`calibrationNarrowing`) keeps from it. -/
private def checkoutStep (job : Job) (ref : String) : String :=
  let slug := s!"{job.owner}/{job.name}"
  let diff := s!"`diff-reviewer agent diff {slug} {job.prNumber} --job {ref}` prints the diff \
under review."
  if job.kind? == some .calibration then
    s!"2. Review the change as it stands at the head commit it names, as if the pull request were \
open for review now. {diff} Read that diff first. The working directory holds the repository \
read-only, at a later state than that commit: do not read its files as they are, and do not check \
out, fetch or read any other ref, branch or commit. For the context of a changed file, read it at \
the head commit, `git show <headSha>:<path>`, where that commit is in the clone; where it is not, \
review from the diff alone. Do not read the pull request's reviews or comments; this task reaches \
GitHub only through git, not through its API."
  else
    s!"2. The repository is checked out read-only in your working directory. Check out the head \
commit it names (`git fetch origin pull/{job.prNumber}/head && git checkout <headSha>`) and read \
the change in context. {diff}{incrementalNote job ref}"

/-- The prompt's last line: who posts the review, which for a calibration job is nobody. -/
private def postingLine (job : Job) : String :=
  if job.kind? == some .calibration then
    "Do not comment on, review or otherwise write to the pull request on GitHub: the review is \
kept by the platform, and never posted."
  else
    "Do not comment on, review or otherwise write to the pull request on GitHub yourself: the \
review is posted, once accepted, by the platform."

/-- The prompt of the orchestra task that writes rubric proposal `job`. -/
def proposalPrompt (job : Job) : String :=
  let slug := s!"{job.owner}/{job.name}"
  s!"Propose a change to the review rubric of {slug} for the diff-reviewer platform (job {job.id}).

1. Run `diff-reviewer agent proposal show {slug} --job {job.id}`. It prints the repository's \
current rubric and its version, its style notes, its calibration results — what trusted \
reviewers raised that the reviewing agent missed, what the agent said that nobody did — and what \
people changed in the agent's drafts before posting them, with the instructions for the proposal; \
follow them.
2. The repository is checked out read-only in your working directory, at its default branch: read \
its code and documentation where they help you judge the evidence. This task reaches GitHub only \
through git, not through its API; read nothing else.
3. Write the rubric document you propose — the whole of it — with a rationale, as the \
instructions describe, and submit it with \
`diff-reviewer agent proposal submit {slug} <file> --job {job.id}`. Fix what it reports and submit \
again until it is accepted.

The proposal is advisory: a person reads it beside the current rubric and accepts or rejects it. \
Do not change the repository, and do not comment on, review or otherwise write to anything on \
GitHub."

/-- The step of `prompt` that says what to review by: the type the agent picks, or for a sub-run
    of a fan-out review, its one category — or, for the default sub-run, what no category
    covers. -/
private def reviewStep (scope : Option Scope) : String :=
  let style := "Write your comments in the style of the `examples` it printed — comments the \
repository's trusted reviewers wrote on other pull requests — but do not copy them."
  let severity := "a `severity` (`nit`, `minor`, `major` or `blocker`)"
  match scope with
  | none =>
    s!"3. Pick the pull request type, of the `prTypes` it printed, whose description fits the \
change, and review the change by that type's `rubric` together with the `instructions` (with no \
`prTypes`, by the `instructions` alone). Give every inline comment {severity} and a `category`: \
one of that type's `categories`, or, when it lists none, a word or two of your own. {style}"
  | some sc =>
    let n := sc.others.length + 1
    let side := if n == 1 then "This review is run on its own, as a fan-out review of no \
categories." else s!"This review is one of {n} run side by side, which the platform merges into \
one."
    let typeLine := "the `rubric` of the type `agent show` names as `prType` (none, when it names \
none)"
    match sc.category with
    | some c =>
      let what := if c.description.trimAscii.isEmpty then "" else s!" — {c.description}"
      s!"3. {side} Yours covers only the category `{c.name}`{what}. Review the change by the \
`instructions` and {typeLine} only as they bear on `{c.name}`, and leave everything else to the \
other reviews. Give every inline comment the `category` `{c.name}` and {severity}. {style}"
    | none =>
      let others := if sc.others.isEmpty then "" else
        s!" The others each cover one category: {", ".intercalate (sc.others.map (s!"`{·}`"))}; \
leave those to them."
      s!"3. {side} Yours is the general review, by the `instructions` and {typeLine}: what \
matters in the change that no category covers.{others} Give every inline comment {severity} and \
a `category`: one of the type's `categories`, or, when it lists none, a word or two of your own. \
{style}"

/-- The prompt of the orchestra task that reviews `job` — or, with `scope`, one sub-run of its
    fan-out. It names no head commit: the agent asks the platform which one (`agent show`), so a
    prompt never disagrees with the job. A calibration job's differs only in how the commit is
    read (`checkoutStep`) and in who posts the review (`postingLine`), and says nothing of the
    review it is scored against. A sub-run's names it by `<job>.<key>`, and narrows the review to
    its category (`reviewStep`). -/
def prompt (job : Job) (scope : Option Scope := none) : String :=
  if job.kind? == some .proposal then proposalPrompt job else
  let slug := s!"{job.owner}/{job.name}"
  let ref := agentRef job scope
  let prTypeLine := if scope.isSome then "`prType` the type `agent show` names (null when it \
names none)" else "`prType` the name of the type you picked (or null when there are no `prTypes`)"
  s!"Review pull request #{job.prNumber} of {slug} for the diff-reviewer platform (job {ref}).

1. Run `diff-reviewer agent show {slug} {job.prNumber} --job {ref}`. It prints the pull \
request — its head and base commits, title and description — and the instructions for the \
review; follow them.
{checkoutStep job ref}
{reviewStep scope}
4. Write the review as a JSON file `\{\"headSha\": …, \"prType\": …, \"review\": …}`, with \
{prTypeLine}, and submit it with \
`diff-reviewer agent submit {slug} {job.prNumber} <file> --job {ref}`. Fix what it reports and \
submit again until it is accepted.

A review may carry at most {maxInlineComments} inline comments; merge or drop the least \
important rather than exceed it.

{postingLine job}"

/-- The narrowing of a calibration job's kleis token: of GitHub, only the ref advertisement
    (`discover`) and `git-upload-pack` (`fetch`) — enough to clone and fetch the commit, and no
    REST or GraphQL read, so the agent cannot read the review it is scored against, nor anything
    said of the pull request since. kleis compiles it to a reject of every other operation of the
    `github` service; the agent API (`diff-reviewer`) is not narrowed, and gives it the diff. -/
def calibrationNarrowing : List String := ["github: only discover, fetch"]

/-- The narrowings a job's orchestra task is queued with: `calibrationNarrowing` for a
    calibration job and for a rubric proposal — which reads the repository's code through git and
    has no use for GitHub's API — and none for a review. -/
def narrowingFor (job : Job) : List String :=
  if job.kind? == some .calibration || job.kind? == some .proposal then calibrationNarrowing
  else []

/-- The checkable sentence the run is held to. -/
def goal (job : Job) : String :=
  if job.kind? == some .proposal then
    s!"`diff-reviewer agent proposal submit {job.owner}/{job.name}` accepted a rubric proposal."
  else
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
  type's `categories`; when that type lists none (or there are no `prTypes`), a word or two of
  your own for what the comment is about.
- `decision` is `comment`, `approve` or `request_changes`.
- A comment's lines are line numbers of the file at the head commit (the right-hand side of the
  diff), and must lie in a hunk of the diff. `suggestion`, when given, replaces lines
  `start_line`..`end_line` exactly.
- At most 200 inline comments: if you have more, merge related ones or drop the least important.
- A review is posted only after the platform accepts it; a person may edit it first.

## Style

The `examples` printed with these instructions are inline comments the repository's trusted
reviewers wrote on other pull requests. Write your comments in their style — their length, their
tone, how directly they say what to change — but do not copy them: every comment of yours is
about this change, in your own words. With no examples, write plainly and briefly."

/-- The `instructions` of `GET /api/agent/v1/…/pulls/{pr}`: how to review, then the repository's
    default rubric, when it has one, then its style notes, when it has them. The pull request
    types, each with its own rubric, are beside them in `prTypes`, and the examples of its style
    in `examples`. -/
def instructionsFor (doc : Option Rubric) (styleNotes : String := "") : String :=
  let withRubric := match doc with
    | some d =>
      if d.defaultRubric.trimAscii.isEmpty then instructions
      else instructions ++ "\n\n# The repository's rubric\n\n" ++ d.defaultRubric
    | none => instructions
  if styleNotes.trimAscii.isEmpty then withRubric
  else withRubric ++ "\n\n# How reviews of this repository are written\n\n" ++ styleNotes

/-- What the `instructions` of a sub-run of a fan-out review end with: its scope, as its prompt
    says it. -/
def scopeInstructions (scope : Scope) : String :=
  let others := if scope.others.isEmpty then "" else
    s!" The other reviews each cover one category: {", ".intercalate scope.others}."
  match scope.category with
  | some c =>
    let what := if c.description.trimAscii.isEmpty then "" else s!" ({c.description})"
    s!"\n\n# This review's scope\n\nThis review is one of several of the change, run side by \
side and merged by the platform. It covers only the category `{c.name}`{what}: review the change \
for that alone, and give every inline comment the `category` `{c.name}`; leave everything else to \
the other reviews.{others} Submit with `prType` as `prType` names it here."
  | none =>
    s!"\n\n# This review's scope\n\nThis review is one of several of the change, run side by \
side and merged by the platform. It is the general review: what matters that no category of the \
others covers.{others} Submit with `prType` as `prType` names it here."

/-- The category named `name` of `doc`, for a review of type `prType`: the type's, or any of the
    document's for a review of none. -/
def categoryOf (doc : Rubric) (prType : Option String) (name : String) : Option Category :=
  match prType.bind doc.findType? with
  | some t => t.categories.find? (·.name == name)
  | none => (doc.prTypes.flatMap (·.categories)).find? (·.name == name)

/-- The scope of each of `subs`, the sub-runs of `job`, under the rubric version the job fanned
    out by; named for the run about to be queued (`next`), or for the latest. -/
def scopesOf (job : Job) (subs : Array Fanout.SubRun) (next := true) : IO (Array Scope) := do
  let doc ← match job.rubricVersion with
    | some v => pure ((← Platform.rubricAt job.owner job.name v).bind (·.rubric?.toOption))
    | none => pure none
  let cats := (subs.filterMap (·.category)).toList
  return subs.map fun sub =>
    let category := sub.category.map fun name =>
      ((doc.bind (categoryOf · job.prType name)).getD { name })
    { sub, category, others := match sub.category with
        | some c => cats.filter (· != c)
        | none => cats
      ref := if next then sub.agentIdFor (sub.attempts + 1) else sub.agentId }

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

/-- The diff of `base...head` of `owner/name`, from the cache or from GitHub, then cached; past
    `maxDiffBytes` it is refused. -/
private def fetchDiff (s : Services) (owner name base head : String) :
    IO (Except DiffError String) := do
  if let some d ← Platform.cachedDiff owner name base head then return .ok d
  let some gh := s.github | return .error .unavailable
  match ← gh.diff owner name base head with
  | .error (.tooLarge n) => return .error (.tooLarge (GitHub.Error.tooLarge n).message)
  | .error e => return .error (.github e.message)
  | .ok d =>
    if d.utf8ByteSize > s.limits.maxDiffBytes then
      return .error (.tooLarge (GitHub.Error.tooLarge s.limits.maxDiffBytes).message)
    Platform.cacheDiff owner name base head d
    return .ok d

/-- The diff an incremental re-review reviews: from the head its previous review was of to its
    own, cached as the pull request's diffs are. -/
def rangeDiffOf (s : Services) (job : Job) : IO (Except DiffError String) := do
  let some head := job.headSha | return .error .noHead
  let some since := job.incrementalSince
    | return .error (.github s!"job {job.id} is not an incremental review")
  fetchDiff s job.owner job.name since head

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
  return (← fetchDiff s job.owner job.name base head).map (head, ·)

/-- Why `r` has a comment GitHub would refuse against `job`'s diff, or — for an incremental
    re-review — one off the diff of the changes since its previous review, if it has one. A diff
    that cannot be had is not checked here: posting checks again. -/
def checkDiffs (s : Services) (job : Job) (r : Review) : IO (Except String Unit) := do
  if let .ok (_, d) ← diffOf s job then
    if let .error e := Diff.check r d then return .error e
  if let some since := job.incrementalSince then
    if let .ok d ← rangeDiffOf s job then
      if let .error e := Diff.check r d then
        return .error s!"{e} — this review follows up the one of {since}, and comments only on the \
changes since it (`diff-reviewer agent diff … --since {since}`)"
  return .ok ()

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

/-- An incremental re-review's review as it is posted: its body names the earlier review it follows
    up, with a link to it on GitHub, unless it links it already. Any other review as it is. -/
def followUp (job : Job) (r : Review) : IO Review := do
  let (some prevId, some since) := (job.previousJob, job.incrementalSince) | return r
  let url := (← Platform.findJob prevId).bind (·.postedUrl)
  if url.any fun u => (r.body.splitOn u).length > 1 then return r
  let short := (since.take 12).toString
  let line := match url with
    | some u => s!"Follow-up to [the earlier review]({u}) of {short}: this review covers the \
commits since."
    | none => s!"Follow-up to the earlier review of {short}: this review covers the commits since."
  return { r with body := if r.body.trimAscii.isEmpty then line else r.body ++ "\n\n" ++ line }

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
    review with GitHub's body, without the marker, and its decision as GitHub's `state` says or,
    failing that, the event it was posted as when that is known. The comments are the job's: the
    claim kept them from being edited meanwhile. -/
def postedRevision (job : Job) (r : GitHub.PostedReview) (event : Option Decision) : String :=
  let m := marker job.id
  let body :=
    if r.body.endsWith ("\n\n" ++ m) then (r.body.dropEnd (m.length + 2)).toString
    else if r.body.endsWith m then (r.body.dropEnd m.length).toString
    else r.body
  let base := (job.reviewRaw.bind (Json.parse · |>.toOption)).getD (.mkObj [])
  let base := if base.getObj?.isOk then base else .mkObj []
  let base := base.setObjVal! "body" body
  (match r.decision? <|> event with
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
                      postedReview := some r.toJson.compress, postNote := note
                      postDirect := false }
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
    if let some why := job.notPostable then return .error (.conflict why)
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
    if let .error e ← checkDiffs s job review then
      return .error (.conflict s!"job {id}'s review would be refused: {e}")
    let markPosted (r : GitHub.PostedReview) (note : Option String)
        (event : Option Decision := none) : IO (Except PostError Job) :=
      recordPosted s job r note event
    -- Leave the job to be posted again, with why; `keepClaim` while whether it was posted is
    -- still unknown, so that the next attempt waits out the claim and looks before it posts.
    let failed (why : String) (keepClaim : Bool) : IO (Except PostError Job) := do
      -- A definite refusal ends the platform's own attempts: posting again is a person's call.
      let recorded ← Platform.updateJob id fun j =>
        return { j with error := some why
                        postStartedAt := if keepClaim then j.postStartedAt else none
                        postDirect := keepClaim && j.postDirect }
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
      if let some why := j.notPostable then throw (.conflict why)
      unless j.status? == some .approved do
        throw (.conflict s!"job {id} is {j.statusRaw}; only an approved review is posted")
      unless j.version == job.version && j.postStartedAt == job.postStartedAt do
        throw (.conflict s!"job {id} changed while it was being posted; reload it")
      return { j with postStartedAt := some (isoOfEpoch now), postDirect := direct
                      directPosts := if direct then j.directPosts + 1 else j.directPosts }
    if let .error e := claim then
      return .error (match e with
        | .notFound => .notFound
        | .conflict why | .invalid why => .conflict why)
    let body ← followUp job review
    match ← gh.postReview job.owner job.name job.prNumber (withMarker id body) (some head)
        (some event) with
    | .ok r => markPosted r note (some event)
    | .error (.definite why) => failed s!"posting failed: {why}" false
    | .error (.rateLimited why) =>
      -- Nothing was posted, but a post is not to be made again before the limit resets, nor by
      -- a person who reads "refused" as "try now": the claim stands, as for an unknown outcome,
      -- and is settled — the marker looked for, then cleared — once its window has passed.
      failed s!"GitHub's rate limit refused the post ({why}); it is checked and can be posted \
again once the limit resets" true
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
    if let some why := job.notPostable then return .error (.conflict why)
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
    if let some why := j.notPostable then throw (.conflict why)
    unless j.status? == some .draft && j.version == version do
      throw (.conflict s!"job {id} changed before it could be posted")
    return { j with statusRaw := JobStatus.approved.toString }
  match approved with
  | .error .notFound => return .error .notFound
  | .error (.conflict why) | .error (.invalid why) => return .error (.conflict why)
  | .ok j => postJob s id (some j.version) (direct := true)

/-- What follows a job's draft, the agent's or the merge of its sub-runs': a calibration job is
    scored, and a `direct` repository's review posted. Answers the job as it then is. -/
def afterDraft (s : Services) (job : Job) : IO Job := do
  if job.kind? == some .calibration then
    try
      let _ ← Calibration.scoreJob job
    catch e =>
      -- The workers score it on their next pass.
      s.log s!"scoring job {job.id}: {e}"
  let some repo ← Platform.findRepo job.owner job.name | return job
  if repo.mode != .direct || !job.isReview then return job
  match ← postDirect s job.id job.version with
  | .ok j => return j
  | .error _ => return (← Platform.findJob job.id).getD job

/-- Settle fan-out job `jobId` (`Fanout.settle`): merged into its draft once every sub-run is in,
    then on as any draft (`afterDraft`), or failed when every sub-run failed. -/
def settleFanout (s : Services) (jobId : String) : IO Unit := do
  match ← Fanout.settle jobId with
  | .drafted j =>
    s.log s!"merged the sub-runs of job {j.id} into its draft"
    let _ ← afterDraft s j
  | .failed j => s.log s!"job {j.id} is failed: {j.error.getD ""}"
  | .waiting => pure ()

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
    it; so are its sub-runs' runs, once it has moved. -/
def retire (s : Services) (job : Job) (to : JobStatus) (why : String) : IO Unit := do
  if job.status? == some .queued || job.status? == some .running then
    if let (some orch, some entry) := (s.orchestraFor job, job.queueEntry) then
      if let .error e ← orch.cancel entry then
        s.log s!"cancelling entry {entry} of job {job.id}: {e}"
  let retired ← Platform.updateJob job.id fun j => do
    unless j.statusRaw == job.statusRaw do throw (.conflict "moved on")
    if let some why := j.claimBlocks then throw (.conflict why)
    return { j with statusRaw := to.toString, error := some why }
  -- A fan-out's sub-runs go with it: nothing more is spent on any of them.
  if retired matches .ok _ then
    let entries ← Fanout.cancelLive job.id s!"job {job.id} is {to.toString}"
    if let some orch := s.orchestraFor job then
      for entry in entries do
        if let .error e ← orch.cancel entry then
          s.log s!"cancelling entry {entry} of a sub-run of job {job.id}: {e}"
  s.log s!"job {job.id} is {to.toString}: {why}"

/-- The statuses in which a job of a superseded head is made `stale`. -/
private def supersedable : List JobStatus := [.pending, .queued, .running, .draft, .approved]

/-- Discovery: a job for every new head of an open pull request of an `autoReview` repository, up
    to `maxJobsPerDay` a day, and `stale` for the jobs of heads that are no longer the pull
    request's. GitHub draft pull requests are left until they are marked ready for review. Only
    review jobs are looked at: a calibration job is of a past commit by design, and is neither a
    reason to make no job for a head nor ever made `stale` here. -/
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
      -- A fan-out's sub-runs count, each in place of the one job (`Fanout.reviewSpend`).
      let mut made ← Fanout.reviewSpend repo.owner repo.name (isoOfEpoch (now - 86400))
      for p in pulls do
        if p.draft then continue
        let jobs := (← Platform.jobsOfPull repo.owner repo.name p.number).filter (·.isReview)
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

/-- The most commits of an incremental re-review's range kept for the agent, and the longest
    message of one. -/
def maxIncrementalCommits : Nat := 100

def maxCommitMessageChars : Nat := 1000

/-- Whether review job `job`, read for queueing, is an incremental re-review, as a change of its
    fields: it is when `repo` reviews incrementally, a review of another head of its pull request
    was posted (the newest such), and GitHub says the head that review was of is an ancestor of
    this one — then it records that job, that head and the commits since, and the diff between is
    fetched. A head that is not an ancestor — a force-push — or that GitHub refuses to compare
    makes it a full review, with why (`fullReviewReason`). An error to wait on, and record, when
    GitHub could not be asked. -/
def incrementalOf (s : Services) (repo : Repo) (job : Job) : IO (Except String (Job → Job)) := do
  let full (reason : Option String) (j : Job) : Job :=
    { j with previousJob := none, incrementalSince := none, incrementalCommitsRaw := none
             fullReviewReason := reason }
  let some head := job.headSha | return .ok (full none)
  unless repo.incremental && job.isReview do return .ok (full none)
  let some gh := s.github | return .ok (full none)
  -- Newest first: the review posted last is the one the new head follows.
  let posted := (← Platform.jobsOfPull job.owner job.name job.prNumber).filter fun j =>
    j.isReview && j.status? == some .posted && j.id != job.id && j.headSha.isSome &&
      j.headSha != some head
  let some prev := posted[0]? | return .ok (full none)
  let some since := prev.headSha | return .ok (full none)
  match ← gh.compare job.owner job.name since head with
  | .error (.definite why) =>
    return .ok (full (some s!"the head the last posted review was of, {since}, could not be \
compared with {head} ({why}); reviewed in full"))
  | .error e => return .error s!"comparing the last reviewed head {since} with {head}: {e.message}"
  | .ok c =>
    unless c.status == "ahead" do
      return .ok (full (some s!"the head the last posted review was of, {since}, is not an \
ancestor of {head} — a force-push (GitHub compares them as {c.status}); reviewed in full"))
    let commits := (c.commits.extract 0 maxIncrementalCommits).map fun (sha, msg) =>
      Json.mkObj [("sha", sha), ("message", (msg.take maxCommitMessageChars).toString)]
    let inc (j : Job) : Job :=
      { j with previousJob := some prev.id, incrementalSince := some since
               incrementalCommitsRaw := some (Json.arr commits).compress, fullReviewReason := none }
    match ← rangeDiffOf s (inc job) with
    | .ok _ => return .ok inc
    | .error (.tooLarge why) =>
      return .ok (full (some s!"the diff since the last posted review is too large ({why}); \
reviewed in full"))
    | .error e => return .error s!"reading the diff since the last posted review: {e.message}"

/-- The fan-out plan of a review of `repo` under its current rubric, and that rubric's version;
    `none` when it is one run — or when the rubric cannot be read, which the agent is told when it
    reads the job. -/
private def fanoutPlanOf (repo : Repo) : IO (Option (FanoutPlan × Nat)) := do
  let some v ← Platform.currentRubric repo.owner repo.name | return none
  let .ok doc := v.rubric? | return none
  return (doc.fanoutPlan repo.prType).map (·, v.version)

/-- Queue every `pending` sub-run of fan-out job `job` on orchestra, each a task of its own under
    `<base>.<key>`, with a prompt narrowed to its category. A failure is recorded on the sub-run,
    once, and it is queued again on the next pass. -/
def queueSubRuns (s : Services) (job : Job) : IO Unit := do
  let some orch := s.orchestraFor job | return
  let subs ← Fanout.current job.id
  for scope in ← scopesOf job subs do
    let sub := scope.sub
    unless sub.status == "pending" do continue
    let req : Orchestra.QueueRequest :=
      { prompt := prompt job (some scope), goal := goal job, upstream := s!"{job.owner}/{job.name}"
      , issueNumber := some job.prNumber, externalId := sub.externalId
      , kleisNarrow := narrowingFor job, checkout := none }
    match ← orch.queue req with
    | .error e => Fanout.recordError sub "pending" s!"queueing on orchestra: {e}"
    | .ok entry =>
      let r ← Fanout.update sub.id fun j cur => do
        unless cur.status == "pending" do throw "moved on"
        unless j.status? == some .queued || j.status? == some .running do throw "moved on"
        return { cur with status := "queued", queueEntry := some entry.id
                          attempts := cur.attempts + 1, error := none }
      match r with
      | .ok _ => s.log s!"queued sub-run {scope.ref} as orchestra entry {entry.id}"
      | .error _ =>
        -- Retired, or submitted by a run given up on, meanwhile: the run is not wanted — unless
        -- another process recorded this very entry.
        let now := (← Fanout.current job.id).find? (·.id == sub.id)
        unless now.any (·.queueEntry == some entry.id) do
          if let .error e ← orch.cancel entry.id then
            s.log s!"cancelling entry {entry.id} of sub-run {scope.ref}: {e}"
        s.log s!"sub-run {scope.ref} changed while it was queued as entry {entry.id}"

/-- Queueing: every `pending` job of a registered repository whose head is still its pull
    request's, onto orchestra, once its diff has been fetched and found small enough. A calibration
    job is of a past commit of a closed pull request, which it knows with its base from its
    sample: neither the pull request's state nor its head is checked, only its diff. A rubric
    proposal is of the repository, and nothing of GitHub is read for it; it is queued through the
    client for proposals, with no `issue_number`. A job of a kind this build does not know is left
    alone. -/
def queuePending (s : Services) : IO Unit := do
  let jobs ← Platform.jobsWithStatus [.pending]
  if jobs.isEmpty then return
  for job in jobs do
    let some repo ← Platform.findRepo job.owner job.name | continue
    if job.kind?.isNone then continue
    let proposal := job.kind? == some .proposal
    let some orch := s.orchestraFor job
      | if proposal then
          recordError job.id .pending "no orchestra client for rubric proposals is configured \
(DIFF_REVIEWER_ORCHESTRA_URL, DIFF_REVIEWER_ORCHESTRA_PROPOSER_TOKEN_FILE); the proposal waits"
        else
          s.logOnce "queue-no-orchestra" "orchestra is not configured \
(DIFF_REVIEWER_ORCHESTRA_URL, DIFF_REVIEWER_ORCHESTRA_TOKEN_FILE); pending jobs stay pending"
        continue
    let mut job := job
    if !proposal then
      match s.github with
      | none =>
        unless hasPull job do
          recordError job.id .pending "the job does not know its pull request's head and base, \
and GitHub is not configured to read them"
          continue
      | some gh =>
        if job.kind? == some .calibration then
          unless hasPull job do
            retire s job .failed "the calibration job does not know its commit, base and title"
            continue
        else
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
    -- A new head of a pull request whose review was posted: the changes since, when they follow.
    if job.isReview then
      match ← incrementalOf s repo job with
      | .error why =>
        recordError job.id .pending why
        continue
      | .ok f => job := f job
    -- A rubric that asks for fan-out: the job's sub-runs are queued, not the job.
    if !proposal then
      if let some (plan, version) ← fanoutPlanOf repo then
        if plan.size > repo.maxFanout then
          retire s job .failed s!"the review would fan out to {plan.size} sub-runs (the \
default and {plan.categories.length} categories), more than {repo.slug}'s maxFanout, \
{repo.maxFanout}; raise it, or set a type with fewer categories"
          continue
        let since := isoOfEpoch ((← nowEpoch) - 86400)
        let charge := if job.kind? == some .calibration then
            Calibration.chargeFanoutIn job plan.size s.limits.maxCalibrationJobsPerDay
          else Fanout.reviewChargeIn job plan.size s.limits.maxJobsPerDay since
        let learnt (j : Job) : Job :=
          { j with headSha := job.headSha, baseSha := job.baseSha, title := job.title
                   prBody := job.prBody, previousJob := job.previousJob
                   incrementalSince := job.incrementalSince
                   incrementalCommitsRaw := job.incrementalCommitsRaw
                   fullReviewReason := job.fullReviewReason }
        match ← Fanout.begin job learnt plan version (externalId job.id job.attempts) charge with
        | .error .moved => s.log s!"job {job.id} changed while it was fanned out"
        | .error (.capped why) => recordError job.id .pending why
        | .ok (j, subs) =>
          s.log s!"fanned job {job.id} out to {subs.size} sub-runs"
          queueSubRuns s j
        continue
    let req : Orchestra.QueueRequest :=
      { prompt := prompt job, goal := goal job, upstream := s!"{job.owner}/{job.name}"
      , issueNumber := if proposal then none else some job.prNumber
      , externalId := externalId job.id job.attempts
      , kleisNarrow := narrowingFor job
      -- TODO(orchestra): send `checkout := job.headSha` for a calibration job once orchestra's
      -- `POST /api/v1/queue` takes `checkout` (its per-task "check out this commit"); until then
      -- it refuses the field, and the task is checked out at the default branch.
      , checkout := none }
    match ← orch.queue req with
    | .error e => recordError job.id .pending s!"queueing on orchestra: {e}"
    | .ok entry =>
      let r ← Platform.updateJob job.id fun j => do
        unless j.status? == some .pending do throw (.conflict "moved on")
        return { j with headSha := job.headSha, baseSha := job.baseSha, title := job.title
                        prBody := job.prBody, statusRaw := JobStatus.queued.toString
                        queueEntry := some entry.id, attempts := j.attempts + 1, error := none
                        fanoutRound := none
                        previousJob := job.previousJob, incrementalSince := job.incrementalSince
                        incrementalCommitsRaw := job.incrementalCommitsRaw
                        fullReviewReason := job.fullReviewReason }
      match r with
      | .ok _ => s.log s!"queued job {job.id} as orchestra entry {entry.id}"
      | .error _ =>
        -- Retired meanwhile: the run is not wanted — unless another process recorded this entry.
        let now ← Platform.findJob job.id
        unless now.any (·.queueEntry == some entry.id) do
          if let .error e ← orch.cancel entry.id then
            s.log s!"cancelling entry {entry.id} of job {job.id}: {e}"
        s.log s!"job {job.id} changed while it was queued as entry {entry.id}"

/-- The sub-runs still to queue of the fan-out jobs under way: one queueing failed, or a run ended
    without a submission and is run again. -/
def queueRetries (s : Services) : IO Unit := do
  for job in ← Platform.jobsWithStatus [.queued, .running] do
    if job.queueEntry.isSome then continue
    if (← Fanout.current job.id).any (·.status == "pending") then queueSubRuns s job

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
  for job in jobs do
    let some orch := s.orchestraFor job | continue
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
                          error := some s!"the run ended ({e.status}) without submitting \
{if j.kind? == some .proposal then "a proposal" else "a review"}" }
        | some st => return { j with statusRaw := st.toString }
        | none => return j

/-- Mark fan-out job `id` `running`, if it is still `queued`: one of its sub-runs has started. -/
private def markRunning (id : String) : IO Unit := do
  let some job ← Platform.findJob id | return
  unless job.status? == some .queued do return
  let _ ← Platform.updateJob id fun j => do
    unless j.status? == some .queued do throw (.conflict "moved on")
    return { j with statusRaw := JobStatus.running.toString }

/-- The charge for running a sub-run of `job` again, against its day's cap, inside the transaction
    that makes it `pending`: why not, past it. -/
private def chargeRetryIn (s : Services) (job : Job) (since : String) :
    Sqlite.M (Except String Unit) :=
  if job.kind? == some .calibration then
    Calibration.chargeRetryIn job s.limits.maxCalibrationJobsPerDay
  else Fanout.reviewRetryChargeIn job s.limits.maxJobsPerDay since

/-- Following the sub-runs of every fan-out job under way, as `follow` follows a job: `running`
    when its run starts; when it ends without a submission, `pending` to run again while it has
    had fewer than `Fanout.maxAttempts` runs, and `failed` after. Then each job is settled: merged
    once every sub-run is in (`settleFanout`). -/
def followSubRuns (s : Services) : IO Unit := do
  for job in ← Platform.jobsWithStatus [.queued, .running] do
    let subs ← Fanout.current job.id
    if subs.isEmpty then continue
    if let some orch := s.orchestraFor job then
      for sub in subs do
        unless sub.status == "queued" || sub.status == "running" do continue
        let some entryId := sub.queueEntry | continue
        match ← latestEntry orch entryId with
        | .error e => s.log s!"following sub-run {sub.agentId} (entry {entryId}): {e}"
        | .ok e =>
          let ended := Orchestra.terminal e.status
          let starts := e.status == "running" && sub.status == "queued"
          if !ended && !starts && e.id == entryId then continue
          -- Running it again costs a run more, charged like the first — checked and reserved in
          -- the transaction that makes it pending: past the cap it fails.
          let since := isoOfEpoch ((← nowEpoch) - 86400)
          let r ← Fanout.updateM sub.id fun j cur => do
            unless cur.status == "queued" || cur.status == "running" do return .error "moved on"
            let cur := { cur with queueEntry := some e.id }
            if ended then
              let why := s!"the run ended ({e.status}) without submitting a review"
              if cur.attempts < Fanout.maxAttempts then
                match ← chargeRetryIn s j since with
                | .ok () =>
                  return .ok { cur with status := "pending"
                                        error := some s!"{why}; it is run again" }
                | .error capped =>
                  return .ok { cur with status := "failed", error := some s!"{why}; {capped}" }
              return .ok { cur with status := "failed", error := some why }
            if starts then return .ok { cur with status := "running" }
            return .ok cur
          if r matches .ok { status := "running", .. } then markRunning job.id
    settleFanout s job.id

/-- Settling: every claim to post older than its window, settled as a person's
    `POST /api/v1/jobs/{id}/reconcile` settles it — found on GitHub, the job is `posted`; not
    found, the claim is cleared — and logged. A claim within its window may be a post under way,
    and is left to it.

    Then a `direct` repository's review whose own post (`postDirect`) was settled as not having
    reached GitHub is posted again, as a comment, while the platform has posted it fewer than
    `maxDirectPostAttempts` times; past that it is left `approved`, with why, for a person. Before
    posting again the pull request is read: closed, or moved on from the job's head, the job is
    `stale` instead — a review of a commit nobody will merge is not posted. A person's own post
    clears `postDirect`, so what a person started is never retried by the platform, nor counted. -/
def settleClaims (s : Services) : IO Unit := do
  let some gh := s.github | return
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
  let most := s.limits.maxDirectPostAttempts
  for j in ← Platform.jobsWithStatus [.approved] do
    unless j.postDirect && j.postStartedAt.isNone do continue
    unless (← Platform.findRepo j.owner j.name).any (·.mode == .direct) do continue
    if j.directPosts ≥ most then
      let why := s!"posted {j.directPosts} times without the review reaching GitHub, the most \
the platform tries on its own; post it (POST /api/v1/jobs/{j.id}/post) to try again"
      let r ← Platform.updateJob j.id fun j' => do
        unless j'.status? == some .approved && j'.postDirect && j'.postStartedAt.isNone do
          throw (.conflict "moved on")
        return { j' with postDirect := false, error := some why }
      if r matches .ok _ then s.log s!"job {j.id} of {j.owner}/{j.name}: {why}"
      continue
    match ← gh.getPull j.owner j.name j.prNumber with
    | .error e =>
      s.logOnce s!"repost-{j.id}-{e.message}" s!"reading {j.owner}/{j.name}#{j.prNumber} before \
posting job {j.id} again: {e.message}"
      continue
    | .ok p =>
      if p.state != "open" then
        retire s j .stale s!"the pull request is {p.state}; its review is not posted again"
        continue
      if j.headSha != some p.headSha then
        retire s j .stale s!"the pull request moved on to {p.headSha}; its review is not posted \
again"
        continue
    match ← postJob s j.id (some j.version) (direct := true) with
    | .ok p =>
      s.log s!"posted job {j.id} again ({p.directPosts} of {most}): it is {p.statusRaw}"
    | .error (.github why p) =>
      s.log s!"posting job {j.id} again ({p.directPosts} of {most}): {why}"
    | .error (.conflict why) => s.log s!"posting job {j.id} again: {why}"
    | .error .notFound | .error .unavailable => pure ()

/-- One pass of the loop. A step that throws is logged, and the next step still runs. -/
def tick (s : Services) : IO Unit := do
  let prune : IO Unit := do
    let before := isoOfEpoch ((← nowEpoch) - s.limits.diffRetentionDays * 86400)
    let n ← Platform.pruneDiffs before
    if n > 0 then s.log s!"dropped {n} kept diff(s)"
  let calibrate : IO Unit := do
    if let some gh := s.github then
      Calibration.importStep gh s.log s.limits.importPullsPerPass s.limits.githubReserve
    let n ← Calibration.scorePending
    if n > 0 then s.log s!"scored {n} calibration job(s)"
  for (what, step) in [("discovery", discover s), ("queueing", queuePending s),
                       ("queueing sub-runs", queueRetries s), ("following", follow s),
                       ("following sub-runs", followSubRuns s), ("settling claims", settleClaims s),
                       ("calibration", calibrate), ("pruning diffs", prune)] do
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