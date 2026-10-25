import DiffReviewer
import DiffReviewerTest.Basic
import DiffReviewerTest.Server
import DiffReviewerTest.Workers

open Lean (Json)
open DiffReviewer
open DiffReviewer.Server
open DiffReviewerTest.Server
open DiffReviewerTest.Workers

/-!
# Calibration, against fakes

A repository's past: two closed pull requests, reviewed by a trusted reviewer and by somebody
else, with inline comments of every kind the import keeps or drops. Imported, run, reviewed by the
agent and scored — and never posted, whatever is asked.
-/

namespace DiffReviewerTest.Calibration

/-- The closed pull requests, their reviews and their review comments, and whether the next
    request for the reviews of a pull request is refused for GitHub's rate limit. -/
structure FakeHistory where
  gh          : FakeGitHub
  closed      : IO.Ref (Array GitHub.Pull)
  reviews     : IO.Ref (Array (Nat × GitHub.PostedReview))
  comments    : IO.Ref (Array (Nat × GitHub.ReviewComment))
  rateLimited : IO.Ref (List Nat)
  /-- Every request for the reviews of a pull request, by its number. -/
  reviewCalls : IO.Ref (Array Nat)

def mergeBase : String := "dddddddd44444444dddddddd44444444dddddddd"

def review (id : Nat) (author state body commit : String) : GitHub.PostedReview :=
  { id, author, state, body, commitId := commit, url := s!"https://github.example/r/{id}"
  , submittedAt := some s!"2026-10-0{id % 9 + 1}T00:00:00Z" }

def comment (id review : Nat) (side : String) (line : Nat) (start : Option Nat := none)
    (commit : String := headA) (reply : Option Nat := none) (body : String := s!"comment {id}") :
    GitHub.ReviewComment :=
  { id, reviewId := some review, path := "A.lean", body, side := some side
  , startSide := start.map fun _ => side, originalLine := some line, originalStartLine := start
  , originalCommitId := commit, inReplyTo := reply }

/-- #11 at `headA`: alice asks for changes with two comments to keep and three to drop; mallory,
    who is not trusted, comments; alice's pending review and her reply-only review are not
    samples. #12 at `headB`: alice approves, without comments. -/
def FakeHistory.new : IO FakeHistory := do
  return { gh := ← FakeGitHub.new
         , closed := ← IO.mkRef #[
             { number := 11, title := "Fix widgets", body := "Fixes them.", headSha := headA
             , baseSha := base, state := "closed" },
             { number := 12, title := "More widgets", body := "", headSha := headB
             , baseSha := base, state := "closed" }]
         , reviews := ← IO.mkRef #[
             (11, review 101 "Alice" "CHANGES_REQUESTED" "Please fix the names." headA),
             (11, review 102 "mallory" "COMMENTED" "Ship it." headA),
             (11, review 103 "alice" "PENDING" "draft" headA),
             (11, review 104 "alice" "COMMENTED" "" headA),
             (12, review 201 "alice" "APPROVED" "LGTM" headB)]
         , comments := ← IO.mkRef #[
             (11, comment 1 101 "RIGHT" 5 (start := some 3) (body := "rename this")),
             (11, comment 2 101 "LEFT" 2),
             (11, comment 3 101 "RIGHT" 5 (reply := some 1)),
             (11, comment 4 101 "RIGHT" 7 (commit := headB)),
             (11, comment 5 101 "RIGHT" 12 (body := "and this")),
             (11, comment 6 102 "RIGHT" 9),
             (11, comment 7 104 "RIGHT" 5 (reply := some 1))]
         , rateLimited := ← IO.mkRef [], reviewCalls := ← IO.mkRef #[] }

def FakeHistory.client (f : FakeHistory) : GitHub.Client :=
  { f.gh.client with
    listClosedPulls := fun _ _ limit => return .ok ((← f.closed.get).extract 0 limit)
    listReviews := fun _ _ n => do
      f.reviewCalls.modify (·.push n)
      if (← f.rateLimited.get).contains n then
        f.rateLimited.modify (·.erase n)
        return .error (.rateLimited "GitHub answered 403: API rate limit exceeded")
      return .ok (((← f.reviews.get).filter (·.1 == n)).map (·.2))
    listReviewComments := fun _ _ n =>
      return .ok (((← f.comments.get).filter (·.1 == n)).map (·.2))
    mergeBase := fun _ _ _ _ => return .ok mergeBase }

def services (f : FakeHistory) (orch : Option FakeOrchestra := none) (limits : Workers.Limits := {})
    : IO Workers.Services :=
  Workers.Services.new (some f.client) (orch.map (·.client)) (fun _ => pure ()) limits

def repoPath : String := "/api/v1/repos/acme/widgets"

def putRepo (st : State) (body : String) : IO Reply :=
  route st (req .put repoPath body)

def items (r : Reply) : List Json :=
  (((bodyJson r).getObjVal? "items").toOption.bind (·.getArr?.toOption)).map (·.toList) |>.getD []

def num (j : Json) (path : List String) : Option Nat :=
  match path with
  | [] => j.getNat?.toOption
  | k :: ks => (j.getObjVal? k).toOption.bind (num · ks)

def str (j : Json) (path : List String) : Option String :=
  match path with
  | [] => j.getStr?.toOption
  | k :: ks => (j.getObjVal? k).toOption.bind (str · ks)

/-- A ratio as the API writes it. -/
def ratioOf (j : Json) (path : List String) : Option String :=
  match path with
  | [] => if j matches .null then none else some j.compress
  | k :: ks => (j.getObjVal? k).toOption.bind (ratioOf · ks)

/-- Register the repository with alice trusted, and import its history in one pass. -/
def imported (st : State) (svc : Workers.Services) (f : FakeHistory) (mode := "staged") :
    IO Unit := do
  let _ ← putRepo st s!"\{\"mode\": \"{mode}\", \"trustedReviewers\": [\"Alice\"]}"
  let _ ← route st (req .post s!"{repoPath}/calibration/import" "{}")
  Calibration.importStep f.client svc.log 100

/-- The trusted reviewers are a setting like the others, and versioned: a write that leaves them
    out keeps them, a stale version is refused, and a login is checked. -/
def trustedReviewersAreASetting : Test := withTempDb do
  let f ← FakeHistory.new
  let st ← State.new cfg (← services f)
  let made ← putRepo st "{\"trustedReviewers\": [\"Alice\", \"bob\", \"alice\"]}"
  let kept ← putRepo st "{\"mode\": \"direct\"}"
  let stale ← putRepo st "{\"version\": 1, \"trustedReviewers\": []}"
  let current ← putRepo st s!"\{\"version\": {versionOf kept}, \"trustedReviewers\": [\"carol\"]}"
  let bad ← putRepo st "{\"trustedReviewers\": [\"-x\"]}"
  let notList ← putRepo st "{\"trustedReviewers\": \"alice\"}"
  let fresh ← route st (req .put "/api/v1/repos/acme/other" "{\"version\": 3}")
  let trusted (r : Reply) : List String :=
    (((bodyJson r).getObjVal? "trustedReviewers").toOption.bind (·.getArr?.toOption)).map
      (·.toList.filterMap (·.getStr?.toOption)) |>.getD []
  return checkStatus made 201 "registering"
    ++ checkEq (trusted made) ["alice", "bob"] "the logins, in lower case, once each"
    ++ checkEq (versionOf made) 1 "the first version"
    ++ checkEq (trusted kept) ["alice", "bob"] "a write that leaves them out keeps them"
    ++ checkEq (field kept "mode") (some "direct") "while it changes the mode"
    ++ checkEq (versionOf kept) 2 "the version after a second write"
    ++ checkStatus stale 409 "a write of a version that is no longer current"
    ++ checkStatus current 200 "a write of the current version"
    ++ checkEq (trusted current) ["carol"] "replaced"
    ++ checkStatus bad 400 "a login GitHub would not have"
    ++ checkStatus notList 400 "a login that is not in a list"
    ++ checkStatus fresh 409 "a version for a repository not registered yet"

/-- The matcher: one to one, on one file, overlapping or within three lines, closest first; and
    what it reports. -/
def commentsAreMatchedByPlace : Test := do
  let a (file : String) (s e : Nat) (cat : Option String := none)
      (sev : Option Severity := none) (id : String := s!"a{s}") : InlineComment :=
    { file, range := { startLine := s, endLine := e }, body := "x", suggestion := none
    , id := some id, category := cat, severity := sev }
  let h (id : Nat) (file : String) (s e : Nat) : Score.HumanComment :=
    { id, path := file, startLine := s, line := e, body := "y" }
  let agent : Review :=
    { decision := .requestChanges, body := "b"
    , comments := [a "A.lean" 10 12 (some "naming") (some .minor),
                   a "A.lean" 14 14 (some "naming") (some .major),
                   a "A.lean" 30 30 (some "docs") (some .nit),
                   a "B.lean" 10 10 none (some .nit)] }
  -- 11..11 overlaps the first and is 3 from the second; 17 is 3 from the second; 34 is 4 from
  -- the third; nothing is on B.lean.
  let human := [h 1 "A.lean" 11 11, h 2 "A.lean" 17 17, h 3 "A.lean" 34 34, h 4 "C.lean" 10 10]
  let pairs := Score.matchComments agent.comments human
  let s := Score.score agent "CHANGES_REQUESTED" human
  let j := s.toJson
  let cat (name : String) (k : String) : Option Nat :=
    (((j.getObjVal? "byCategory").toOption.bind (·.getArr?.toOption)).bind fun xs =>
      xs.find? (str · ["category"] == some name)).bind (num · [k])
  let none_ := Score.score { agent with comments := [] } "DISMISSED" []
  return checkEq (pairs.map fun p => (p.agent, p.human)) [(0, 0), (1, 1)]
      "the pairs: the overlap first, then the second within three lines"
    ++ checkEq (Score.gap 1 2 6 6) 4 "four lines apart"
    ++ checkEq (Score.gap 5 9 7 7) 0 "inside"
    ++ checkEq s.matched 2 "matched"
    ++ checkEq (ratioOf j ["precision"]) (some "0.5") "precision: 2 of the agent's 4"
    ++ checkEq (ratioOf j ["recall"]) (some "0.5") "recall: 2 of the person's 4"
    ++ checkEq (cat "naming" "matched") (some 2) "both naming comments matched"
    ++ checkEq (cat "docs" "matched") (some 0) "the docs comment did not"
    ++ checkEq s.agree (some true) "both asked for changes"
    ++ checkEq (s.pairs.map fun (x, y, _) => Score.Pair.key x y) ["a10:1", "a14:2"]
      "pairs are named by their comments' ids"
    ++ checkEq (s.unmatchedHuman.map (·.id)) [3, 4] "the person's comments not found"
    ++ checkEq (s.unmatchedAgent.map (·.id)) [some "a30", some "a10"]
      "the agent's comments not matched"
    ++ checkEq none_.agree none "a dismissed review's decision is not compared"
    ++ checkEq (ratioOf none_.toJson ["precision"]) none "no comments: no precision"
    ++ checkEq (Score.ratio 1 3).compress "0.3333" "a third"
    ++ checkEq (Score.ratio 2 3).compress "0.6667" "two thirds, rounded"

/-- The import keeps a trusted reviewer's reviews, each with its commit and the merge base, and
    its comments on the new side of that commit; it drops and counts the rest; importing again
    adds nothing, and a deleted sample stays deleted. -/
def theImportKeepsTrustedReviews : Test := withTempDb do
  let f ← FakeHistory.new
  let svc ← services f
  let st ← State.new cfg svc
  let _ ← putRepo st "{}"
  let noTrusted ← route st (req .post s!"{repoPath}/calibration/import" "{}")
  imported st svc f
  let imports ← route st (req .get s!"{repoPath}/calibration/import")
  let samples ← route st (req .get s!"{repoPath}/calibration/samples")
  let all := items samples
  let s101 := all.find? (num · ["reviewId"] == some 101)
  let comments101 := (s101.bind (·.getObjVal? "comments" |>.toOption)).bind (·.getArr?.toOption)
  let again ← route st (req .post s!"{repoPath}/calibration/import" "{\"limit\": 5}")
  let tooMany ← route st (req .post s!"{repoPath}/calibration/import" "{\"limit\": 500}")
  Calibration.importStep f.client svc.log 100
  let afterAgain := (items (← route st (req .get s!"{repoPath}/calibration/samples"))).length
  let id101 := (s101.bind (str · ["id"])).getD ""
  let deleted ← route st (req .delete s!"{repoPath}/calibration/samples/{id101}")
  let deletedAgain ← route st (req .delete s!"{repoPath}/calibration/samples/{id101}")
  let _ ← route st (req .post s!"{repoPath}/calibration/import" "{}")
  Calibration.importStep f.client svc.log 100
  let afterDelete := items (← route st (req .get s!"{repoPath}/calibration/samples"))
  let first := (items imports).head?.getD .null
  return checkStatus noTrusted 409 "an import with nobody trusted"
    ++ checkEq (str first ["status"]) (some "done") "the import, after one pass"
    ++ checkEq (num first ["stats", "pulls"]) (some 2) "pull requests listed"
    ++ checkEq (num first ["stats", "reviews"]) (some 3) "alice's submitted reviews"
    ++ checkEq (num first ["stats", "imported"]) (some 2) "samples made"
    ++ checkEq (num first ["stats", "empty"]) (some 1) "a review with nothing to compare"
    ++ checkEq (num first ["stats", "droppedLeft"]) (some 1) "a comment on the old side"
    ++ checkEq (num first ["stats", "droppedOutdated"]) (some 1) "one placed on another commit"
    ++ checkEq (num first ["stats", "droppedReplies"]) (some 2) "replies"
    ++ checkEq all.length 2 "samples"
    ++ checkEq (all.map (num · ["reviewId"])) [some 201, some 101] "the most recent first"
    ++ checkEq (s101.bind (str · ["reviewer"])) (some "alice") "the reviewer, in lower case"
    ++ checkEq (s101.bind (str · ["state"])) (some "CHANGES_REQUESTED") "the state, as given"
    ++ checkEq (s101.bind (str · ["commitId"])) (some headA) "the commit reviewed"
    ++ checkEq (s101.bind (str · ["baseSha"])) (some mergeBase) "the base it had there"
    ++ checkEq (comments101.map (·.toList.map (num · ["line"]))) (some [some 5, some 12])
      "the comments kept, by their line on the review's commit"
    ++ checkEq (comments101.map (·.toList.map (num · ["start_line"]))) (some [some 3, some 12])
      "and where they start"
    ++ checkEq (s101.bind (num · ["dropped", "left"])) (some 1) "the sample says what it dropped"
    ++ checkStatus again 202 "importing again, once the first is done"
    ++ checkStatus tooMany 400 "more than 200 pull requests"
    ++ checkEq afterAgain 2 "importing again adds nothing"
    ++ checkStatus deleted 204 "deleting a sample"
    ++ checkStatus deletedAgain 404 "deleting it twice"
    ++ checkEq (afterDelete.map (num · ["reviewId"])) [some 201] "a deleted sample stays deleted"

/-- GitHub's rate limit stops the import where it is, and the next pass goes on from there; and a
    pass reads at most its budget of pull requests. -/
def theImportStopsAtTheRateLimit : Test := withTempDb do
  let f ← FakeHistory.new
  let svc ← services f
  let st ← State.new cfg svc
  let _ ← putRepo st "{\"trustedReviewers\": [\"alice\"]}"
  let _ ← route st (req .post s!"{repoPath}/calibration/import" "{}")
  let busy ← route st (req .post s!"{repoPath}/calibration/import" "{}")
  f.rateLimited.set [12]
  Calibration.importStep f.client svc.log 100
  let stopped := (items (← route st (req .get s!"{repoPath}/calibration/import"))).head?.getD .null
  let callsThen := (← f.reviewCalls.get).size
  Calibration.importStep f.client svc.log 100
  let resumed := (items (← route st (req .get s!"{repoPath}/calibration/import"))).head?.getD .null
  -- A budget of one pull request a pass.
  let _ ← route st (req .post s!"{repoPath}/calibration/import" "{}")
  f.reviewCalls.set #[]
  Calibration.importStep f.client svc.log 1
  let budgeted := ((items (← route st (req .get s!"{repoPath}/calibration/import"))).find?
    (str · ["status"] == some "running")).getD .null
  let answer (status : Nat) (msg : String) : Http.Response :=
    { status, body := s!"\{\"message\": \"{msg}\"}" }
  return checkStatus busy 409 "a second import while one is under way"
    ++ check (GitHub.rateLimited (answer 403 "API rate limit exceeded for user ID 1."))
      "GitHub's primary limit"
    ++ check (GitHub.rateLimited (answer 403 "You have exceeded a secondary rate limit."))
      "its secondary limit"
    ++ check (GitHub.rateLimited (answer 429 "Too Many Requests")) "a 429"
    ++ check (!GitHub.rateLimited (answer 403 "Resource not accessible by integration"))
      "a refusal that is not the limit"
    ++ checkEq (str stopped ["status"]) (some "running") "the import, stopped by the limit"
    ++ checkEq (num stopped ["pullsRead"]) (some 1) "the pull request read before it"
    ++ check ((str stopped ["error"]).any (·.startsWith "GitHub's rate limit")) "why it stopped"
    ++ checkEq callsThen 2 "nothing asked after the limit"
    ++ checkEq (str resumed ["status"]) (some "done") "the next pass finishes it"
    ++ checkEq (num resumed ["stats", "imported"]) (some 2) "with every sample"
    ++ checkEq (resumed.getObjVal? "error" |>.toOption) (some .null) "and no error"
    ++ checkEq (← f.reviewCalls.get) #[11] "one pull request read in a pass of budget one"
    ++ checkEq (num budgeted ["pullsRead"]) (some 1) "and recorded"

/-- The id of the sample of review `reviewId`. -/
def sampleId (st : State) (reviewId : Nat) : IO String := do
  let all := items (← route st (req .get s!"{repoPath}/calibration/samples"))
  return ((all.find? (num · ["reviewId"] == some reviewId)).bind (str · ["id"])).getD ""

def runOf (st : State) (ids : List String) : IO Reply :=
  route st (req .post s!"{repoPath}/calibration/runs"
    s!"\{\"samples\": [{", ".intercalate (ids.map (s!"\"{·}\""))}]}")

/-- The agent's review of #11: one comment on alice's first, one on nothing. -/
def agentReview : String :=
  "{\"decision\": \"request_changes\", \"body\": \"Two things.\", \"comments\": [\
{\"file\": \"A.lean\", \"start_line\": 4, \"end_line\": 5, \"body\": \"a name\", \
\"category\": \"naming\", \"severity\": \"minor\"}, \
{\"file\": \"A.lean\", \"start_line\": 18, \"end_line\": 18, \"body\": \"a doc\", \
\"category\": \"docs\", \"severity\": \"nit\"}]}"

/-- A calibration job goes through the queue and the agent like a review — at its sample's commit,
    though the pull request is closed — is scored when it is a draft, and is never approved,
    claimed or posted, even in a `direct` repository; nor is what the agent is given any of the
    person's review. -/
def calibrationJobsAreNeverPosted : Test := withTempDb do
  let f ← FakeHistory.new
  let orch ← FakeOrchestra.new
  let svc ← services f orch
  let st ← State.new cfg svc
  imported st svc f (mode := "direct")
  let sid ← sampleId st 101
  let made ← runOf st [sid]
  let runId := (field made "id").getD ""
  let jobId := (((bodyJson made).getObjVal? "results").toOption.bind (·.getArr?.toOption)
    |>.bind (·[0]?) |>.bind (str · ["jobId"])).getD ""
  Workers.queuePending svc
  let queued ← orch.queued.get
  let prompt := (queued[0]?.map (·.prompt)).getD ""
  let shown ← route st (agentReq .get "" (pr := 11))
  let shownText := String.fromUTF8! shown.body
  let human := ["Please fix the names.", "rename this", "and this"]
  let submitted ← route st (agentReq .post "/review" (submission headA agentReview) (pr := 11))
  let some job ← Platform.findJob jobId | return #["the calibration job is gone"]
  let approve ← route st (req .post s!"/api/v1/jobs/{jobId}/status"
    (statusBody "approved" job.version))
  let edit ← route st (req .put s!"/api/v1/jobs/{jobId}/review" (reviewBody job.version fine))
  -- Approved by other means, it is still neither claimed nor posted.
  let _ ← Platform.updateJob jobId fun j => return { j with statusRaw := "approved" }
  let some forced ← Platform.findJob jobId | return #["the calibration job is gone"]
  let post ← route st (req .post s!"/api/v1/jobs/{jobId}/post"
    s!"\{\"version\": {forced.version}}")
  let direct ← Workers.postJob svc jobId (some forced.version) (direct := true)
  let _ ← Platform.updateJob jobId fun j =>
    return { j with postStartedAt := some "2020-01-01T00:00:00Z", postDirect := true }
  let some claimed ← Platform.findJob jobId | return #["the calibration job is gone"]
  let reconcile ← route st (req .post s!"/api/v1/jobs/{jobId}/reconcile"
    s!"\{\"version\": {claimed.version}}")
  Workers.settleClaims svc
  let some after ← Platform.findJob jobId | return #["the calibration job is gone"]
  let run ← route st (req .get s!"{repoPath}/calibration/runs/{runId}")
  let result := (((bodyJson run).getObjVal? "results").toOption.bind (·.getArr?.toOption)
    |>.bind (·[0]?)).getD .null
  let listed ← route st (req .get "/api/v1/jobs")
  let listedCal ← route st { req .get "/api/v1/jobs" with query := "kind=calibration" }
  return checkStatus made 201 "the run"
    ++ checkEq (queued.map (·.issueNumber)) #[11] "queued, though the pull request is closed"
    ++ checkEq (queued.map (·.kleisNarrow)) #[["github: only discover, fetch"]]
      "with its token narrowed to cloning and fetching from GitHub"
    ++ check ((queued[0]?.map (·.toJson.getObjVal? "kleis_narrow" |>.isOk)).getD false)
      "the narrowing is in the request orchestra is sent"
    ++ checkEq job.headSha (some headA) "at the sample's commit"
    ++ checkEq job.baseSha (some mergeBase) "with its base"
    ++ checkEq job.kindRaw (some "calibration") "of the kind"
    ++ check ((prompt.splitOn "git fetch origin <headSha>").length > 1)
      "the prompt fetches the commit itself"
    ++ check (human.all fun t => (prompt.splitOn t).length == 1)
      "the prompt says nothing of alice's"
    ++ checkStatus shown 200 "the agent's read"
    ++ check (human.all fun t => (shownText.splitOn t).length == 1)
      "nor does what the agent reads"
    ++ checkStatus submitted 200 "the submission"
    ++ checkEq (field submitted "status") (some "draft") "a draft, in a direct repository too"
    ++ checkStatus approve 409 "approving it"
    ++ checkStatus edit 409 "editing it"
    ++ checkStatus post 409 "posting it, approved"
    ++ check (direct matches .error (.conflict _)) "the platform's own post of it"
    ++ checkStatus reconcile 409 "settling a claim of it"
    ++ checkEq after.postStartedAt claimed.postStartedAt "the workers settle nothing of it"
    ++ checkEq after.statusRaw "approved" "and post nothing"
    ++ checkEq (← f.gh.posted.get).size 0 "nothing reached GitHub"
    ++ checkEq (str result ["status"]) (some "approved") "the run's result"
    ++ checkEq (ratioOf result ["score", "precision"]) (some "0.5") "precision: one of two"
    ++ checkEq (ratioOf result ["score", "recall"]) (some "0.5") "recall: one of two"
    ++ checkEq (num result ["score", "matcherVersion"]) (some Score.matcherVersion)
      "the matcher's version"
    ++ checkEq ((result.getObjVal? "score").toOption.bind
      (·.getObjVal? "decision" |>.toOption) |>.bind (·.getObjValAs? Bool "agree" |>.toOption))
      (some true) "both asked for changes"
    ++ checkEq (items listed).length 0 "the job list is of reviews"
    ++ checkEq (items listedCal).length 1 "and lists calibration jobs when asked"

/-- Discovery neither makes a calibration job `stale` nor counts it as a review of its head; and
    calibration jobs have a daily cap of their own. -/
def calibrationJobsStandApart : Test := withTempDb do
  let f ← FakeHistory.new
  let svc ← services f (limits := { maxCalibrationJobsPerDay := 1, maxJobsPerDay := 1 })
  let st ← State.new cfg svc
  imported st svc f
  let (s101, s201) := (← sampleId st 101, ← sampleId st 201)
  let both ← runOf st [s101, s201]
  let one ← runOf st [s201]
  let another ← runOf st [s101]
  let byCount ← route st (req .post s!"{repoPath}/calibration/runs" "{\"count\": 50}")
  let neither ← route st (req .post s!"{repoPath}/calibration/runs" "{}")
  let unknown ← runOf st ["nope"]
  -- #12, reopened at the head alice approved: discovery makes a review of it, and leaves the
  -- calibration job alone; then the pull request moves on, and still it is left alone.
  let _ ← putRepo st "{\"autoReview\": true, \"trustedReviewers\": [\"alice\"]}"
  f.gh.pulls.set #[{ number := 12, title := "More widgets", body := "", headSha := headB
                   , baseSha := base }]
  Workers.discover svc
  f.gh.pulls.set #[{ number := 12, title := "More widgets", body := "", headSha := jobHead
                   , baseSha := base }]
  Workers.discover svc
  let jobs ← Platform.jobsOfPull "acme" "widgets" 12
  let cal := jobs.filter (·.kind? == some .calibration)
  let reviews := jobs.filter (·.isReview)
  return checkStatus both 429 "two jobs past a cap of one"
    ++ checkStatus one 201 "one job within it"
    ++ checkStatus another 429 "and none after"
    ++ checkStatus byCount 400 "more than 20 samples"
    ++ checkStatus neither 400 "a run of nothing"
    ++ checkStatus unknown 400 "a sample that is not one"
    ++ checkEq (cal.map (·.statusRaw)) #["pending"] "the calibration job, untouched"
    ++ checkEq (reviews.map (·.headSha)) #[some headB]
      "a review of the head, made though a calibration job is of it; the cap of reviews is its own"

/-- Runs and the repository are aggregates of their jobs' scores: by run, and by rubric version;
    and scoring again changes nothing. -/
def runsAreAggregated : Test := withTempDb do
  let f ← FakeHistory.new
  let orch ← FakeOrchestra.new
  let svc ← services f orch
  let st ← State.new cfg svc
  imported st svc f
  let made ← runOf st [← sampleId st 101]
  let runId := (field made "id").getD ""
  Workers.queuePending svc
  let _ ← route st (agentReq .get "" (pr := 11))
  let _ ← route st (agentReq .post "/review" (submission headA agentReview) (pr := 11))
  let rescored ← Calibration.scorePending
  let runs ← route st (req .get s!"{repoPath}/calibration/runs")
  let summary ← route st (req .get s!"{repoPath}/calibration/summary")
  let missing ← route st (req .get s!"{repoPath}/calibration/runs/nope")
  let listed := (items runs).head?.getD .null
  let s := bodyJson summary
  let byVersion := ((s.getObjVal? "byRubricVersion").toOption.bind (·.getArr?.toOption)).getD #[]
  return checkEq rescored 0 "nothing scored twice"
    ++ checkEq (str listed ["id"]) (some runId) "the run, listed"
    ++ checkEq (num listed ["aggregate", "matched"]) (some 1) "its pairs"
    ++ checkEq (num listed ["jobs", "draft"]) (some 1) "its jobs by status"
    ++ checkEq (num s ["overall", "scored"]) (some 1) "the repository's scored jobs"
    ++ checkEq (ratioOf s ["overall", "recall"]) (some "0.5") "its recall"
    ++ checkEq (num s ["overall", "decisions", "agreed"]) (some 1) "decisions agreed"
    ++ checkEq (byVersion.toList.map (num · ["rubricVersion"])) [some 0]
      "by rubric version: none, which is 0"
    ++ checkStatus missing 404 "a run that is not one"

def all : List (String × Test) :=
  [("trustedReviewersAreASetting", trustedReviewersAreASetting),
   ("commentsAreMatchedByPlace", commentsAreMatchedByPlace),
   ("theImportKeepsTrustedReviews", theImportKeepsTrustedReviews),
   ("theImportStopsAtTheRateLimit", theImportStopsAtTheRateLimit),
   ("calibrationJobsAreNeverPosted", calibrationJobsAreNeverPosted),
   ("calibrationJobsStandApart", calibrationJobsStandApart),
   ("runsAreAggregated", runsAreAggregated)]

end DiffReviewerTest.Calibration