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
# What must not happen

A review posted twice or under the wrong event, the operator locked out by somebody else's
guesses, money spent on commits nobody will merge, a diff too large to read: each against the
fakes of `DiffReviewerTest.Workers`.
-/

namespace DiffReviewerTest.Safety

private def servicesWith (gh : Option FakeGitHub) (orch : Option FakeOrchestra)
    (logs : IO.Ref (Array String)) (limits : Workers.Limits := {}) : IO Workers.Services :=
  Workers.Services.new (gh.map (·.client)) (orch.map (·.client)) (fun m => logs.modify (·.push m))
    limits

private def putRepo (st : State) (body : String) : IO Unit := do
  let _ ← route st (req .put "/api/v1/repos/acme/widgets" body)

private def review (decision body : String) : String :=
  s!"\{\"decision\": \"{decision}\", \"body\": \"{body}\", \"comments\": []}"

/-- A new job of pull request 7, reviewed with `r` and approved; answers its id and version. -/
private def approvedJob (st : State) (r : String := fine) : IO (String × Nat) := do
  let job ← newJob st
  let id := (field job "id").getD ""
  let drafted ← route st (req .put s!"/api/v1/jobs/{id}/review" (reviewBody 1 r))
  let approved ← route st (req .post s!"/api/v1/jobs/{id}/status"
    (statusBody "approved" (versionOf drafted)))
  return (id, versionOf approved)

private def post (st : State) (id : String) (version : Nat) : IO Reply :=
  route st (req .post s!"/api/v1/jobs/{id}/post" s!"\{\"version\": {version}}")

private def job! (id : String) : IO Job := do
  let some j ← Platform.findJob id | throw (.userError s!"job {id} is gone")
  return j

/-- An unknown outcome is settled by the marker, never by posting again. -/
def aReviewIsPostedOnce : Test := withTempDb do
  let gh ← FakeGitHub.new #[pull7 jobHead]
  let logs ← IO.mkRef #[]
  let st ← State.new cfg (← servicesWith gh none logs)
  let count : IO Nat := return (← gh.posted.get).size
  -- Posted, and the answer lost: found by its marker.
  let (a, va) ← approvedJob st
  gh.outcome.set .lostAnswer
  let lost ← post st a va
  let afterLost ← count
  -- Not posted, a 5xx: the claim is kept even though nothing is found yet; once it is old, the
  -- next attempt looks again, finds nothing, and posts.
  let (b, vb) ← approvedJob st
  gh.outcome.set .failedUnposted
  let unposted ← post st b vb
  let jb ← job! b
  gh.outcome.set .ok
  let tooSoonB ← post st b jb.version
  let _ ← Platform.updateJob b fun j =>
    return { j with postStartedAt := some "2000-01-01T00:00:00Z" }
  let again ← post st b (← job! b).version
  let afterB ← count
  -- Posted, the answer lost, and the reviews unreadable: the claim stays, a second attempt soon
  -- after is refused, and a later one finds the review rather than posting it again.
  let (c, vc) ← approvedJob st
  gh.outcome.set .lostAnswer
  gh.listFails.set true
  let unknown ← post st c vc
  let jc ← job! c
  let tooSoon ← post st c jc.version
  gh.listFails.set false
  gh.outcome.set .ok
  let _ ← Platform.updateJob c fun j =>
    return { j with postStartedAt := some "2000-01-01T00:00:00Z" }
  let later ← post st c (← job! c).version
  let afterC ← count
  -- A definite refusal: no claim left, the reason recorded.
  let (d, vd) ← approvedJob st
  gh.outcome.set .refused
  let refused ← post st d vd
  let jd ← job! d
  let bodies := (← gh.posted.get).map (·.2.1.body)
  return checkStatus lost 200 "a post whose answer was lost"
    ++ checkEq (field lost "status") (some "posted") "found by its marker"
    ++ check (field lost "postedUrl" |>.isSome) "the posted review's URL"
    ++ checkEq afterLost 1 "reviews on GitHub after the lost answer"
    ++ checkStatus unposted 502 "a 5xx with nothing posted"
    ++ checkEq jb.statusRaw "approved" "the job after it"
    ++ check jb.postStartedAt.isSome "the claim kept after a 5xx, though nothing is found yet"
    ++ checkStatus tooSoonB 409 "another attempt within the claim's window"
    ++ checkStatus again 200 "posting it again once the claim is old"
    ++ checkEq afterB 2 "reviews on GitHub after the second job"
    ++ checkStatus unknown 502 "an outcome that could not be checked"
    ++ check jc.postStartedAt.isSome "the claim is kept"
    ++ checkStatus tooSoon 409 "another attempt while the claim is recent"
    ++ checkStatus later 200 "a later attempt"
    ++ checkEq afterC 3 "reviews on GitHub: the third job's, once"
    ++ check (((bodyJson later).getObjVal? "postedReview").toOption.bind
        (·.getObjValAs? String "body" |>.toOption) |>.any fun b => (b.splitOn c).length > 1)
      "GitHub's record of the review, kept"
    ++ checkStatus refused 502 "a 422"
    ++ checkEq jd.postStartedAt none "no claim after a definite refusal"
    ++ check (jd.error.any (·.startsWith "posting failed")) "the refusal, recorded"
    ++ check (bodies.all fun b => (b.splitOn "<!-- diff-reviewer job ").length == 2)
      "every posted body carries its marker"

/-- Direct mode never approves or requests changes; a person's post does, unless the pull request
    is the operator's own. -/
def decisionsArePostedAsAPersonDecides : Test := withTempDb do
  let gh ← FakeGitHub.new #[pull7 headA]
  let orch ← FakeOrchestra.new
  let logs ← IO.mkRef #[]
  let st ← State.new cfg (← servicesWith gh orch logs)
  putRepo st "{\"mode\": \"direct\"}"
  let _ ← route st (req .post "/api/v1/jobs"
    s!"\{\"owner\": \"acme\", \"name\": \"widgets\", \"prNumber\": 7, \"headSha\": \"{headA}\"}")
  Workers.queuePending (← servicesWith gh orch logs)
  let _ ← route st (agentReq .get "")
  let submitted ← route st (agentReq .post "/review" (submission headA (review "approve" "")))
  let directId := (field submitted "jobId").getD ""
  let direct ← job! directId
  -- A person posts a staged approval as an approval.
  let gh2 ← FakeGitHub.new #[pull7 jobHead]
  let st2 ← State.new cfg (← servicesWith gh2 none logs)
  let (p, vp) ← approvedJob st2 (review "approve" "Good.")
  let personal ← post st2 p vp
  -- The operator's own pull request: GitHub would refuse, so a comment, and the job says so.
  let gh3 ← FakeGitHub.new #[{ pull7 jobHead with author := "chrisflav" }]
  let st3 ← State.new cfg (← servicesWith gh3 none logs { githubLogin := some "ChrisFlav" })
  let (o, vo) ← approvedJob st3 (review "request_changes" "Two things.")
  let own ← post st3 o vo
  let events (g : FakeGitHub) : IO (Array (Option Decision)) :=
    return (← g.posted.get).map (·.2.2.2)
  return checkEq direct.statusRaw "posted" "the direct review"
    ++ checkEq (← events gh) #[some .comment] "the direct review's event"
    ++ check direct.postNote.isSome "the direct job says it was posted as a comment"
    ++ check (direct.review?.any (·.toOption.any (·.decision == .approve)))
      "the agent's decision is kept on the job"
    ++ checkStatus personal 200 "a person's post"
    ++ checkEq (← events gh2) #[some .approve] "a person's approval"
    ++ checkStatus own 200 "a post on the operator's own pull request"
    ++ checkEq (← events gh3) #[some .comment] "posted as a comment"
    ++ check ((field own "postNote").any (·.startsWith "posted as a comment")) "and the job says so"

private def loginFrom (st : State) (peer : String) (p : String)
    (forwarded : Option String := none) : IO Reply :=
  route st { method := .post, path := "/api/login", peer := some peer
           , body := s!"\{\"password\": \"{p}\"}"
           , header := fun n =>
               if n == "content-type" then some "application/json"
               else if n == "x-forwarded-for" then forwarded
               else none }

/-- Failed logins count against the address they came from — the socket's, or the trusted
    proxy's `X-Forwarded-For` — so one client cannot lock out another; all of them together hit a
    much higher ceiling. -/
def loginsAreLimitedPerAddress : Test := do
  let now ← IO.mkRef (1000000 : Int)
  let st ← State.new { cfg with trustedProxy := some "10.0.0.1" } (clock := now.get)
  withTempDb do
    for _ in [0:5] do
      let _ ← loginFrom st "1.1.1.1" "wrong"
    let lockedOut ← loginFrom st "1.1.1.1" password
    let other ← loginFrom st "2.2.2.2" password
    -- An untrusted peer's header is ignored: each guess still counts against the peer.
    for i in [0:5] do
      let _ ← loginFrom st "3.3.3.3" "wrong" (forwarded := some s!"7.7.7.{i}")
    let spoofed ← loginFrom st "3.3.3.3" password (forwarded := some "7.7.7.99")
    -- Through the trusted proxy, the client it names.
    for _ in [0:5] do
      let _ ← loginFrom st "10.0.0.1" "wrong" (forwarded := some "5.5.5.5, 9.9.9.9")
    let proxiedLocked ← loginFrom st "10.0.0.1" password (forwarded := some "9.9.9.9")
    let proxiedOther ← loginFrom st "10.0.0.1" password (forwarded := some "8.8.8.8")
    -- IPv6: one /64 is one client.
    let st3 ← State.new cfg (clock := now.get)
    for i in [0:5] do
      let _ ← loginFrom st3 s!"2001:db8:1:2::{i + 1}" "wrong"
    let sameNet ← loginFrom st3 "2001:db8:1:2:ffff::9" password
    let otherNet ← loginFrom st3 "2001:db8:1:3::1" password
    return checkStatus lockedOut 429 "the address that failed"
      ++ checkStatus other 200 "another address"
      ++ checkStatus spoofed 429 "an untrusted peer claiming another address"
      ++ checkStatus proxiedLocked 429 "the client the proxy names"
      ++ checkStatus proxiedOther 200 "another client behind the proxy"
      ++ check (loginGlobalLimit ≥ 10 * loginFailureLimit) "the ceiling is much higher"
      ++ checkStatus sameNet 429 "another address of the same /64"
      ++ checkStatus otherNet 200 "another /64"
      ++ checkEq (addressKey "2001:0DB8:0:0::1") "2001:db8:0:0::/64" "an IPv6 key"
      ++ checkEq (addressKey "::ffff:192.0.2.7") "192.0.2.7" "an IPv4-mapped address"
      ++ checkEq (addressKey "192.0.2.7") "192.0.2.7" "an IPv4 address"

private def tokenLogin (st : State) (peer token : String) : IO Reply :=
  route st { method := .post, path := "/api/login", peer := some peer
           , body := s!"\{\"token\": \"{token}\"}"
           , header := fun n => if n == "content-type" then some "application/json" else none }

/-- Milliseconds `act` takes, and its answer. -/
private def timed (act : IO α) : IO (Nat × α) := do
  let t0 ← IO.monoMsNow
  let a ← act
  return ((← IO.monoMsNow) - t0, a)

/-- Past the ceiling over all addresses, a password attempt is an immediate `429` — nothing waits,
    so no request thread is held — while the API reaches its token at normal speed and the API
    token still signs in, so the operator is never locked out. -/
def theCeilingNeverLocksTheOperatorOut : Test := do
  let now ← IO.mkRef (1000000 : Int)
  let st ← State.new cfg (clock := now.get)
  withTempDb do
    for i in [0:loginGlobalLimit] do
      let _ ← loginFrom st s!"6.6.{i / 256}.{i % 256}" "wrong"
    let (apiMs, api) ← timed (route st (req .get "/api/v1/jobs"))
    let (pwMs, pw) ← timed (loginFrom st "4.4.4.4" password)
    let wrongToken ← tokenLogin st "4.4.4.4" "nope"
    let (tokMs, tok) ← timed (tokenLogin st "4.4.4.4" apiToken)
    let noApiToken ← State.new { cfg with apiToken := none } (clock := now.get)
    let unset ← tokenLogin noApiToken "4.4.4.4" apiToken
    return checkStatus api 200 "the API, with its token"
      ++ check (apiMs < 500) s!"answered at normal speed ({apiMs} ms)"
      ++ checkStatus pw 429 "a password attempt past the ceiling"
      ++ check (pw.headers.lookup "Retry-After" |>.isSome) "with Retry-After"
      ++ check (pwMs < 500) s!"answered without delay ({pwMs} ms)"
      ++ checkStatus wrongToken 401 "a wrong token: refused, not rate-limited"
      ++ checkStatus tok 200 "the API token signs in"
      ++ check (tok.headers.lookup "Set-Cookie" |>.isSome) "and gets a session"
      ++ check (tokMs < 500) s!"at normal speed ({tokMs} ms)"
      ++ checkStatus unset 401 "no token login without an API token"

/-- `reconcile` settles a claim without posting: found, posted; not found once the window has
    passed, freed; within it, or with the reviews unreadable, left as it is. -/
def aClaimIsReconciled : Test := withTempDb do
  let gh ← FakeGitHub.new #[pull7 jobHead]
  let logs ← IO.mkRef #[]
  let st ← State.new cfg (← servicesWith gh none logs)
  let reconcile (id : String) : IO Reply := do
    route st (req .post s!"/api/v1/jobs/{id}/reconcile" s!"\{\"version\": {(← job! id).version}}")
  let age (id : String) : IO Unit := do
    let _ ← Platform.updateJob id fun j =>
      return { j with postStartedAt := some "2000-01-01T00:00:00Z" }
  -- Not posted (a 5xx): within the window a 409, past it freed, and then it moves.
  let (a, va) ← approvedJob st
  gh.outcome.set .failedUnposted
  let _ ← post st a va
  let tooSoon ← reconcile a
  age a
  let freed ← reconcile a
  let ja ← job! a
  let moved ← route st (req .post s!"/api/v1/jobs/{a}/status" (statusBody "draft" ja.version))
  -- Posted, the answer lost, the reviews unreadable: a 502 and the claim stands; then found.
  let (b, vb) ← approvedJob st
  gh.outcome.set .lostAnswer
  gh.listFails.set true
  let _ ← post st b vb
  age b
  let unclear ← reconcile b
  let jb ← job! b
  gh.listFails.set false
  let found ← reconcile b
  -- Nothing to settle.
  let (c, _) ← approvedJob st
  let nothing ← reconcile c
  return checkStatus tooSoon 409 "within the claim's window"
    ++ checkStatus freed 200 "past it, nothing found"
    ++ checkEq ja.statusRaw "approved" "the freed job"
    ++ checkEq ja.postStartedAt none "without its claim"
    ++ checkStatus moved 200 "and it can be moved back to draft"
    ++ checkStatus unclear 502 "reviews that cannot be read"
    ++ check jb.postStartedAt.isSome "the claim stands"
    ++ checkStatus found 200 "found"
    ++ checkEq (field found "status") (some "posted") "posted"
    ++ checkEq (← gh.posted.get).size 1 "and nothing posted by reconciling"
    ++ checkStatus nothing 409 "a job with no claim"

/-- Nothing is spent on a head the pull request has moved on from: pending jobs of it are stale,
    queued and running ones cancelled and stale, and queueing checks again. -/
def supersededHeadsCostNothing : Test := withTempDb do
  let gh ← FakeGitHub.new #[pull7 headA]
  let orch ← FakeOrchestra.new
  let logs ← IO.mkRef #[]
  let svc ← servicesWith gh orch logs
  let st ← State.new cfg svc
  putRepo st "{\"mode\": \"staged\", \"autoReview\": true}"
  Workers.discover svc
  Workers.queuePending svc
  let some queuedJob := (← Platform.jobsOfPull "acme" "widgets" 7)[0]? | return #["no job"]
  gh.pulls.set #[pull7 headB]
  Workers.discover svc
  let old ← job! queuedJob.id
  -- A pending job of a head that moves before it is queued.
  let jobs ← Platform.jobsOfPull "acme" "widgets" 7
  let some newer := jobs.find? (·.headSha == some headB) | return #["no job for the new head"]
  gh.pulls.set #[pull7 jobHead]
  Workers.discover svc
  let pendingOld ← job! newer.id
  -- A job asked for by hand, of a head that is not the pull request's: not queued.
  let manual ← route st (req .post "/api/v1/jobs"
    s!"\{\"owner\": \"acme\", \"name\": \"widgets\", \"prNumber\": 7, \"headSha\": \"{headA}\"}")
  let before := (← orch.queued.get).size
  Workers.queuePending svc
  let manualJob ← job! ((field manual "id").getD "")
  let queuedNow := (← orch.queued.get).map (·.externalId)
  -- A closed pull request is not queued either.
  gh.pulls.set #[{ pull7 jobHead with state := "closed" }]
  let closed ← route st (req .post "/api/v1/jobs"
    s!"\{\"owner\": \"acme\", \"name\": \"widgets\", \"prNumber\": 7, \"headSha\": \"{jobHead}\"}")
  Workers.queuePending svc
  let closedJob ← job! ((field closed "id").getD "")
  return checkEq old.statusRaw "stale" "the queued job of the old head"
    ++ checkEq (← orch.cancelled.get) #["e0"] "its orchestra run, cancelled"
    ++ checkEq pendingOld.statusRaw "stale" "a pending job of a superseded head"
    ++ checkEq manualJob.statusRaw "stale" "a hand-made job of a head that is not current"
    ++ check (!queuedNow.contains manualJob.id) "which is not queued"
    ++ checkEq queuedNow.size (before + 1) "only the current head's job is queued"
    ++ checkEq closedJob.statusRaw "stale" "a job of a closed pull request"

/-- At most `maxJobsPerDay` new jobs a repository a day, and saying so. -/
def discoveryIsCapped : Test := withTempDb do
  let gh ← FakeGitHub.new #[pull7, { pull7 with number := 8 }, { pull7 with number := 9 }]
  let logs ← IO.mkRef #[]
  let svc ← servicesWith gh none logs { maxJobsPerDay := 2 }
  let st ← State.new cfg svc
  putRepo st "{\"autoReview\": true}"
  Workers.discover svc
  Workers.discover svc
  let jobs ← Platform.listJobs
  let said := (← logs.get).filter fun m => (m.splitOn "the most allowed").length > 1
  return checkEq jobs.size 2 "jobs made"
    ++ checkEq said.size 1 "the cap, said once"

/-- Listings read every page, and stop at `maxPages`. -/
def listingsReadEveryPage : Test := do
  let calls ← IO.mkRef 0
  let sizes := #[100, 100, 30]
  let three ← GitHub.collectPages fun page => do
    calls.modify (· + 1)
    return .ok (Array.replicate (sizes[page - 1]?.getD 0) page)
  let threeCalls ← calls.get
  let endless ← GitHub.collectPages fun page => return .ok (Array.replicate 100 page)
  return checkEq (three.toOption.map (·.size)) (some 230) "three pages"
    ++ checkEq threeCalls 3 "requests for them"
    ++ checkEq (endless.toOption.map (·.size)) (some (100 * GitHub.maxPages)) "a bounded listing"

/-- With two reviews of one pull request running, the agent must say which is its own; naming it,
    only that one starts. -/
def anAgentRunsOnlyItsOwnJob : Test := withTempDb do
  let gh ← FakeGitHub.new #[pull7 jobHead]
  let orch ← FakeOrchestra.new
  let logs ← IO.mkRef #[]
  let svc ← servicesWith gh orch logs
  let st ← State.new cfg svc
  let first ← newJob st
  let second ← newJob st
  Workers.queuePending svc
  let a := (field first "id").getD ""
  let b := (field second "id").getD ""
  let unnamed ← route st (agentReq .get "")
  let named ← route st { agentReq .get "" with
    header := fun n => if n == "x-diff-reviewer-job" then some b else (agentReq .get "").header n }
  let ja ← job! a
  let jb ← job! b
  return checkStatus unnamed 409 "two reviews, and the agent does not say which"
    ++ checkStatus named 200 "the agent names its job"
    ++ checkEq jb.statusRaw "running" "that job"
    ++ checkEq ja.statusRaw "queued" "the other one, untouched"
    ++ check (((Workers.prompt ja).splitOn s!"--job {a}").length > 1) "the prompt names the job"

/-- A diff past the limit fails the job before anything is spent on it; kept diffs no live job
    needs are dropped. -/
def diffsAreBounded : Test := withTempDb do
  let gh ← FakeGitHub.new #[pull7 jobHead]
  let orch ← FakeOrchestra.new
  let logs ← IO.mkRef #[]
  let svc ← servicesWith gh orch logs { maxDiffBytes := 10 }
  let st ← State.new cfg svc
  let job ← newJob st
  Workers.queuePending svc
  let failed ← job! ((field job "id").getD "")
  -- Pruning: a live job's diff is kept, until it is too old.
  let live ← newJob st
  let liveId := (field live "id").getD ""
  let _ ← Platform.updateJob liveId fun j => return { j with baseSha := some base }
  Platform.cacheDiff "acme" "widgets" base jobHead "diff"
  Platform.cacheDiff "acme" "widgets" base headB "orphan"
  let _ ← Platform.pruneDiffs "2000-01-01T00:00:00Z"
  let kept ← Platform.cachedDiff "acme" "widgets" base jobHead
  let orphan ← Platform.cachedDiff "acme" "widgets" base headB
  let _ ← Platform.pruneDiffs "9999-01-01T00:00:00Z"
  let aged ← Platform.cachedDiff "acme" "widgets" base jobHead
  return checkEq failed.statusRaw "failed" "the job with a diff past the limit"
    ++ check (failed.error.any fun e => (e.splitOn "larger than").length > 1) "why"
    ++ checkEq (← orch.queued.get).size 0 "nothing queued"
    ++ checkEq kept (some "diff") "a live job's diff"
    ++ checkEq orphan none "a diff no live job is of"
    ++ checkEq aged none "a diff past the retention"

/-- Comments must be on the diff's new side, and a comment or a request for changes must say
    something: what GitHub would otherwise refuse with a `422`. -/
def reviewsAreCheckedAgainstTheDiff : Test := withTempDb do
  let added := "\n".intercalate (List.replicate 10 "+a")
  let diff := s!"diff --git a/A.lean b/A.lean\n--- a/A.lean\n+++ b/A.lean\n@@ -1,0 +5,10 @@\n\
{added}\n\
@@ -40 +50 @@\n y\ndiff --git a/Old.lean b/Old.lean\n--- a/Old.lean\n+++ /dev/null\n\
@@ -1,2 +0,0 @@\n"
  let at_ (file : String) (a b : Nat) : Review :=
    { decision := .comment, body := "x"
    , comments := [{ file, range := { startLine := a, endLine := b }, body := "y"
                   , suggestion := none }] }
  let oneComment : InlineComment :=
    { file := "A.lean", range := { startLine := 5, endLine := 5 }, body := "y", suggestion := none }
  -- Inside a hunk a line is content, whatever it starts with; and git quotes some paths.
  let tricky := "diff --git a/A.lean b/A.lean\n--- a/A.lean\n+++ b/A.lean\n@@ -1,2 +1,3 @@\n\
--- not a header\n+++ not a header either\n+++ b/C.lean\n x\n\\ No newline at end of file\n\
diff --git \"a/sp ace/\\303\\251t\\303\\251.lean\" \"b/sp ace/\\303\\251t\\303\\251.lean\"\n\
--- \"a/sp ace/\\303\\251t\\303\\251.lean\"\n+++ \"b/sp ace/\\303\\251t\\303\\251.lean\"\n\
@@ -0,0 +7 @@\n+y\n"
  let pure := checkEq (Diff.rightHunks diff) [("A.lean", [(5, 14), (50, 50)]), ("/dev/null", [])]
      "the hunks"
    ++ checkEq (Diff.rightHunks tricky) [("A.lean", [(1, 3)]), ("sp ace/été.lean", [(7, 7)])]
      "lines like headers inside a hunk, and a quoted path"
    ++ checkEq (Diff.unquote "\"a\\tb\\\"c\"") "a\tb\"c" "C escapes"
    ++ check (Diff.check (at_ "A.lean" 5 14) diff matches .ok ()) "a comment in a hunk"
    ++ check (Diff.check (at_ "A.lean" 50 50) diff matches .ok ()) "a one-line hunk"
    ++ check (Diff.check (at_ "A.lean" 14 15) diff matches .error _) "past the hunk"
    ++ check (Diff.check (at_ "A.lean" 10 50) diff matches .error _) "across two hunks"
    ++ check (Diff.check (at_ "B.lean" 1 1) diff matches .error _) "a file the diff leaves alone"
    ++ check (({ at_ "A.lean" 5 5 with body := "" } : Review).validate matches .error _)
      "a comment saying nothing"
    ++ check (({ at_ "A.lean" 5 5 with body := "", decision := .approve } : Review).validate
      matches .ok ()) "an approval may say nothing"
    ++ check (({ at_ "A.lean" 5 5 with
                 comments := List.replicate maxInlineComments oneComment }
               : Review).validate matches .ok ()) "200 inline comments"
    ++ check (match ({ at_ "A.lean" 5 5 with
                 comments := List.replicate (maxInlineComments + 1)
                   oneComment } : Review).validate with
              | .error e => (e.splitOn "at most 200 inline comments").length > 1
              | .ok () => false) "201, refused with the limit named"
  -- At submission: refused, with what the agent needs to fix it.
  let gh ← FakeGitHub.new #[pull7 jobHead]
  let orch ← FakeOrchestra.new
  let logs ← IO.mkRef #[]
  let svc ← servicesWith gh orch logs
  let st ← State.new cfg svc
  let _ ← newJob st
  Workers.queuePending svc
  let _ ← route st (agentReq .get "")
  let off ← route st (agentReq .post "/review" (submission jobHead
    "{\"decision\": \"comment\", \"body\": \"x\", \"comments\": [{\"file\": \"A.lean\", \"start_line\": 30, \"end_line\": 31, \"body\": \"y\"}]}"))
  let on ← route st (agentReq .post "/review" (submission jobHead
    "{\"decision\": \"comment\", \"body\": \"x\", \"comments\": [{\"file\": \"A.lean\", \"start_line\": 2, \"end_line\": 3, \"body\": \"y\"}]}"))
  let msg := ((bodyJson off).getObjValAs? String "error").toOption.getD ""
  return pure
    ++ checkStatus off 400 "a comment off the diff"
    ++ check ((msg.splitOn "hunk").length > 1) s!"the error names the hunks: {msg}"
    ++ checkStatus on 200 "a comment on it"

/-- While a post may have reached GitHub, the job keeps what it says: it cannot leave
    `approved`, be edited or be made stale, and posting it again settles it. -/
def anUnsettledPostHoldsTheJob : Test := withTempDb do
  let gh ← FakeGitHub.new #[pull7 jobHead]
  let logs ← IO.mkRef #[]
  let svc ← servicesWith gh none logs
  let st ← State.new cfg svc
  putRepo st "{\"autoReview\": true}"
  let (id, v) ← approvedJob st
  gh.outcome.set .lostAnswer
  gh.listFails.set true
  let _ ← post st id v
  let held ← job! id
  let moved ← route st (req .post s!"/api/v1/jobs/{id}/status" (statusBody "draft" held.version))
  let edited ← route st (req .put s!"/api/v1/jobs/{id}/review" (reviewBody held.version fine))
  gh.pulls.set #[pull7 headB]
  Workers.discover svc
  let afterDiscovery ← job! id
  gh.listFails.set false
  let _ ← Platform.updateJob id fun j =>
    return { j with postStartedAt := some "2000-01-01T00:00:00Z" }
  let settled ← post st id (← job! id).version
  return checkStatus moved 409 "moving it off approved"
    ++ check (((bodyJson moved).getObjValAs? String "error").toOption.any fun e =>
        (e.splitOn "may have reached GitHub").length > 1) "saying why"
    ++ checkStatus edited 409 "editing its review"
    ++ checkEq afterDiscovery.statusRaw "approved" "discovery leaves it alone"
    ++ checkStatus settled 200 "posting it again"
    ++ checkEq (field settled "status") (some "posted") "settled: it was posted"
    ++ checkEq (← gh.posted.get).size 1 "and only once"

/-- With the operator's login known, a review by anyone else carrying a job's marker is not taken
    for the platform's; without it, that is said. -/
def aForgedMarkerIsIgnored : Test := withTempDb do
  let gh ← FakeGitHub.new #[pull7 jobHead]
  let logs ← IO.mkRef #[]
  let st ← State.new cfg (← servicesWith gh none logs { githubLogin := some "ChrisFlav" })
  let (id, v) ← approvedJob st
  gh.foreign.set
    #[{ id := 99, body := s!"lgtm {Workers.marker id}", url := "x", author := "mallory" }]
  gh.outcome.set .failedUnposted
  let _ ← post st id v
  let _ ← Platform.updateJob id fun j =>
    return { j with postStartedAt := some "2000-01-01T00:00:00Z" }
  gh.outcome.set .ok
  let posted ← post st id (← job! id).version
  let postedCount := (← gh.posted.get).size
  -- Without the login, looking for a marker says, once, that a forgery cannot be ruled out.
  let logs2 ← IO.mkRef #[]
  let st2 ← State.new cfg (← servicesWith gh none logs2)
  gh.outcome.set .lostAnswer
  for _ in [0:2] do
    let (i, v) ← approvedJob st2
    let _ ← post st2 i v
  let warned := (← logs2.get).filter fun m => (m.splitOn "DIFF_REVIEWER_GITHUB_LOGIN").length > 1
  return checkStatus posted 200 "posted despite the forged marker"
    ++ checkEq postedCount 1 "the platform's own review was posted"
    ++ check ((field posted "postedUrl").any (· != "x")) "not the forged one"
    ++ checkEq warned.size 1 "the warning, once"

/-- A step that throws does not stop the others, nor the loop. -/
def aThrowingStepStopsNothing : Test := withTempDb do
  let gh ← FakeGitHub.new #[pull7 jobHead]
  let orch ← FakeOrchestra.new
  let logs ← IO.mkRef #[]
  let throwing : GitHub.Client :=
    { gh.client with listOpenPulls := fun _ _ => throw (.userError "boom") }
  let svc ← Workers.Services.new (some throwing) (some orch.client)
    (fun m => logs.modify (·.push m))
  let st ← State.new cfg svc
  let _ ← newJob st
  putRepo st "{\"autoReview\": true}"
  Workers.tick svc
  return checkEq (← orch.queued.get).size 1 "queueing ran after discovery threw"
    ++ check ((← logs.get).any (·.startsWith "discovery: ")) "the throw is logged"

/-- Two transactions on one database from two connections: the second waits for the first
    instead of failing. -/
def transactionsTakeTheWriteLock : Test := withTempDb do
  let gh ← FakeGitHub.new #[pull7 jobHead]
  let st ← State.new cfg (← servicesWith gh none (← IO.mkRef #[]))
  let job ← newJob st
  let id := (field job "id").getD ""
  let tasks ← (List.range 8).mapM fun _ => IO.asTask do
    Platform.updateJob id fun j => return { j with error := some "x" }
  for t in tasks do
    let _ ← IO.wait t
  return checkEq (← job! id).version 9 "every write landed, one after another"

def all : List (String × Test) :=
  [("aReviewIsPostedOnce", aReviewIsPostedOnce),
   ("decisionsArePostedAsAPersonDecides", decisionsArePostedAsAPersonDecides),
   ("loginsAreLimitedPerAddress", loginsAreLimitedPerAddress),
   ("theCeilingNeverLocksTheOperatorOut", theCeilingNeverLocksTheOperatorOut),
   ("aClaimIsReconciled", aClaimIsReconciled),
   ("supersededHeadsCostNothing", supersededHeadsCostNothing),
   ("discoveryIsCapped", discoveryIsCapped),
   ("listingsReadEveryPage", listingsReadEveryPage),
   ("anAgentRunsOnlyItsOwnJob", anAgentRunsOnlyItsOwnJob),
   ("diffsAreBounded", diffsAreBounded),
   ("reviewsAreCheckedAgainstTheDiff", reviewsAreCheckedAgainstTheDiff),
   ("aThrowingStepStopsNothing", aThrowingStepStopsNothing),
   ("anUnsettledPostHoldsTheJob", anUnsettledPostHoldsTheJob),
   ("aForgedMarkerIsIgnored", aForgedMarkerIsIgnored),
   ("transactionsTakeTheWriteLock", transactionsTakeTheWriteLock)]

end DiffReviewerTest.Safety