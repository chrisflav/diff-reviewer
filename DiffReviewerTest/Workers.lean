import DiffReviewer
import DiffReviewerTest.Basic
import DiffReviewerTest.Server

open Lean (Json)
open DiffReviewer
open DiffReviewer.Server
open DiffReviewerTest.Server

/-!
# The workers, the agent API and posting, against fakes

`FakeGitHub` and `FakeOrchestra` are `GitHub.Client` and `Orchestra.Client` over in-memory state,
recording what was asked of them, so that a review's whole life — discovered, queued, run,
submitted, approved, posted — is driven here without a request leaving the process.
-/

namespace DiffReviewerTest.Workers

/-- How the fake answers a post. -/
inductive PostOutcome where
  | ok
  /-- A `422`: nothing posted. -/
  | refused
  /-- Posted, and the answer lost on the way back. -/
  | lostAnswer
  /-- A `502`, and nothing posted. -/
  | failedUnposted
  /-- A `403` for the rate limit, and nothing posted. -/
  | rateLimited
  deriving BEq

structure FakeGitHub where
  pulls     : IO.Ref (Array GitHub.Pull)
  /-- Each posted review: the pull request, the review as posted, its commit and its event. -/
  posted    : IO.Ref (Array (Nat × Review × Option String × Option Decision))
  diffCalls : IO.Ref Nat
  outcome   : IO.Ref PostOutcome
  /-- Whether listing the reviews fails. -/
  listFails : IO.Ref Bool
  diffText  : IO.Ref String
  /-- The login the fake's own posts are by. -/
  reviewer  : IO.Ref String
  /-- Reviews by others on the pull requests, listed after the platform's. -/
  foreign   : IO.Ref (Array GitHub.PostedReview)

/-- A diff whose new side of `A.lean` is lines 1 to 20. -/
def sampleDiff : String :=
  "diff --git a/A.lean b/A.lean\n--- a/A.lean\n+++ b/A.lean\n@@ -1,3 +1,20 @@\n def x := 1\n"

def FakeGitHub.new (pulls : Array GitHub.Pull := #[]) : IO FakeGitHub := do
  return { pulls := ← IO.mkRef pulls, posted := ← IO.mkRef #[], diffCalls := ← IO.mkRef 0
         , outcome := ← IO.mkRef .ok, listFails := ← IO.mkRef false
         , diffText := ← IO.mkRef sampleDiff, reviewer := ← IO.mkRef "chrisflav"
         , foreign := ← IO.mkRef #[] }

/-- The `state` GitHub gives a review submitted as `event`. -/
def stateOf : Option Decision → String
  | some .approve => "APPROVED"
  | some .requestChanges => "CHANGES_REQUESTED"
  | some .comment => "COMMENTED"
  | none => "PENDING"

def FakeGitHub.client (f : FakeGitHub) : GitHub.Client where
  listOpenPulls _ _ := return .ok (← f.pulls.get)
  getPull _ _ n := do
    match (← f.pulls.get).find? (·.number == n) with
    | some p => return .ok p
    | none => return .error (.definite "GitHub answered 404: Not Found")
  diff _ _ _ _ := do
    f.diffCalls.modify (· + 1)
    return .ok (← f.diffText.get)
  listReviews _ _ n := do
    if ← f.listFails.get then return .error (.indefinite "GitHub answered 503")
    let author ← f.reviewer.get
    let own := ((← f.posted.get).filter (·.1 == n)).mapIdx fun i (_, r, _, ev) =>
      { id := i, body := r.body, url := s!"https://github.example/review/{i}", author
      , state := stateOf ev }
    return .ok (own ++ (← f.foreign.get))
  postReview _ _ n review commit event := do
    let record := do
      f.posted.modify (·.push (n, review, commit, event))
      return ((← f.posted.get).size - 1)
    match ← f.outcome.get with
    | .refused => return .error (.definite "GitHub answered 422: Unprocessable Entity")
    | .failedUnposted => return .error (.indefinite "GitHub answered 502")
    | .rateLimited =>
      return .error (.rateLimited "GitHub answered 403: API rate limit exceeded for user ID 1.")
    | .lostAnswer =>
      let _ ← record
      return .error (.indefinite "curl: (28) Operation timed out")
    | .ok =>
      let i ← record
      return .ok { id := i, body := review.body, url := s!"https://github.example/review/{i}"
                 , state := stateOf event }

structure FakeOrchestra where
  queued    : IO.Ref (Array Orchestra.QueueRequest)
  entries   : IO.Ref (Array Orchestra.Entry)
  cancelled : IO.Ref (Array String)

def FakeOrchestra.new : IO FakeOrchestra := do
  return { queued := ← IO.mkRef #[], entries := ← IO.mkRef #[], cancelled := ← IO.mkRef #[] }

/-- Set entry `id`'s status and successor. -/
def FakeOrchestra.set (f : FakeOrchestra) (id status : String)
    (continuedBy : Option String := none) : IO Unit := do
  f.entries.modify fun es =>
    let es := es.filter (·.id != id)
    es.push { id, status, continuedBy }

/-- Like orchestra: an `external_id` seen before answers the entry it made. -/
def FakeOrchestra.client (f : FakeOrchestra) : Orchestra.Client where
  queue req := do
    let qs ← f.queued.get
    if let some i := qs.findIdx? (·.externalId == req.externalId) then
      return .ok { id := s!"e{i}", status := "pending" }
    f.queued.set (qs.push req)
    let e : Orchestra.Entry := { id := s!"e{qs.size}", status := "pending" }
    f.entries.modify (·.push e)
    return .ok e
  entry id := do
    match (← f.entries.get).find? (·.id == id) with
    | some e => return .ok e
    | none => return .error "orchestra answered 404"
  cancel id := do
    f.cancelled.modify (·.push id)
    f.set id "cancelled"
    return .ok ()

def headA : String := "aaaaaaaa11111111aaaaaaaa11111111aaaaaaaa"

def headB : String := "bbbbbbbb22222222bbbbbbbb22222222bbbbbbbb"

def base : String := "cccccccc33333333cccccccc33333333cccccccc"

def pull7 (head : String := headA) (draft := false) : GitHub.Pull :=
  { number := 7, title := "Add widgets", body := "Widgets.", headSha := head, baseSha := base
  , draft }

/-- Services over fresh fakes, logging into a list. -/
def services (gh : Option FakeGitHub) (orch : Option FakeOrchestra) (logs : IO.Ref (Array String)) :
    IO Workers.Services :=
  Workers.Services.new (gh.map (·.client)) (orch.map (·.client)) (fun m => logs.modify (·.push m))

def agentReq (method : Std.Http.Method) (suffix : String) (body : String := "")
    (pr : Nat := 7) : Req :=
  req method s!"/api/agent/v1/repos/acme/widgets/pulls/{pr}{suffix}" body (token := agentToken)

/-- A submission of `review` at `head`; `prType` is JSON, `null` for a repository without pull
    request types. -/
def submission (head : String) (review : String := fine) (prType : String := "null") : String :=
  s!"\{\"headSha\": \"{head}\", \"prType\": {prType}, \"review\": {review}}"

private def putRepo (st : State) (body : String) : IO Unit := do
  let _ ← route st (req .put "/api/v1/repos/acme/widgets" body)

private def onlyJob : IO (Option Job) := do
  return (← Platform.jobsOfPull "acme" "widgets" 7)[0]?

/-- Discovery makes one job per head commit, leaves GitHub drafts alone, and makes the review of a
    head the pull request has moved on from `stale`. -/
def discoveryFindsNewHeads : Test := withTempDb do
  let gh ← FakeGitHub.new #[pull7, { pull7 with number := 8, draft := true }]
  let logs ← IO.mkRef #[]
  let svc ← services gh none logs
  let st ← State.new cfg svc
  putRepo st "{\"mode\": \"staged\"}"
  Workers.discover svc
  if (← onlyJob).isSome then return #["a repository without autoReview was searched"]
  putRepo st "{\"mode\": \"staged\", \"autoReview\": true}"
  Workers.discover svc
  Workers.discover svc
  let jobs ← Platform.jobsOfPull "acme" "widgets" 7
  let drafts ← Platform.jobsOfPull "acme" "widgets" 8
  let some first := jobs[0]? | return #["no job was made for the open pull request"]
  let reviewed ← route st (req .put s!"/api/v1/jobs/{first.id}/review" (reviewBody 1 fine))
  gh.pulls.set #[pull7 headB]
  Workers.discover svc
  let jobs' ← Platform.jobsOfPull "acme" "widgets" 7
  let some old ← Platform.findJob first.id | return #["the first job is gone"]
  return checkEq jobs.size 1 "jobs for one head, after two passes"
    ++ checkEq first.headSha (some headA) "the job's head"
    ++ checkEq first.title (some "Add widgets") "the job's title"
    ++ checkEq first.baseSha (some base) "the job's base"
    ++ checkEq drafts.size 0 "jobs for a GitHub draft"
    ++ checkStatus reviewed 200 "a review of the first head"
    ++ checkEq jobs'.size 2 "jobs once the head moved"
    ++ checkEq old.statusRaw "stale" "the review of the old head"
    ++ check (jobs'.any (·.headSha == some headB)) "a job for the new head"

/-- Without orchestra, jobs stay pending and that is said once. -/
def withoutOrchestraJobsWait : Test := withTempDb do
  let logs ← IO.mkRef #[]
  let svc ← services none none logs
  let st ← State.new cfg svc
  let job ← newJob st
  Workers.tick svc
  Workers.tick svc
  let some j ← Platform.findJob ((field job "id").getD "") | return #["the job is gone"]
  let said := (← logs.get).filter (·.startsWith "orchestra is not configured")
  return checkEq j.statusRaw "pending" "the job"
    ++ checkEq said.size 1 "the message, after two passes"

/-- A review's life over the agent API: queued, read (now running), its diff, a submission of the
    wrong head refused, the right one a draft; then approved and posted, pinned to the head. -/
def anAgentReviewsAndItIsPosted : Test := withTempDb do
  let gh ← FakeGitHub.new #[pull7]
  let orch ← FakeOrchestra.new
  let logs ← IO.mkRef #[]
  let svc ← services gh orch logs
  let st ← State.new cfg svc
  putRepo st "{\"mode\": \"staged\"}"
  let _ ← route st (req .put "/api/v1/repos/acme/widgets/rubrics"
    "{\"version\": 0, \"prTypes\": [{\"name\": \"feature\"}]}")
  -- A job asked for without a head: queueing reads it from GitHub.
  let created ← route st (req .post "/api/v1/jobs"
    "{\"owner\": \"acme\", \"name\": \"widgets\", \"prNumber\": 7}")
  let id := (field created "id").getD ""
  let beforeQueue ← route st (agentReq .get "")
  Workers.queuePending svc
  let queued ← orch.queued.get
  let some q := queued[0]? | return #["nothing was queued"]
  let feature := "\"feature\""
  let early ← route st (agentReq .post "/review" (submission headA (prType := feature)))
  let shown ← route st (agentReq .get "")
  let diff ← route st (agentReq .get "/diff")
  let diff2 ← route st (agentReq .get "/diff")
  let other ← route st (agentReq .get "" (pr := 8))
  let wrongHead ← route st (agentReq .post "/review" (submission headB (prType := feature)))
  let invalid ← route st (agentReq .post "/review" (submission headA
    "{\"decision\": \"comment\", \"body\": \"\", \"comments\": [{\"file\": \"A.lean\", \"start_line\": 0, \"end_line\": 0, \"body\": \"x\"}]}"))
  let submitted ← route st (agentReq .post "/review" (submission headA (prType := feature)))
  let again ← route st (agentReq .post "/review" (submission headA (prType := feature)))
  let afterSubmit ← route st (agentReq .get "")
  let job ← route st (req .get s!"/api/v1/jobs/{id}")
  let approved ← route st (req .post s!"/api/v1/jobs/{id}/status"
    (statusBody "approved" (versionOf job)))
  let staleVersion ← route st (req .post s!"/api/v1/jobs/{id}/post" (statusBody "x" 1))
  let posted ← route st (req .post s!"/api/v1/jobs/{id}/post"
    s!"\{\"version\": {versionOf approved}}")
  let postedTwice ← route st (req .post s!"/api/v1/jobs/{id}/post"
    s!"\{\"version\": {versionOf posted}}")
  let jobDiff ← route st (req .get s!"/api/v1/jobs/{id}/diff")
  let postedReviews ← gh.posted.get
  return checkStatus beforeQueue 404 "the agent API before the job is queued"
    ++ checkEq q.externalId id "the external id is the job's"
    ++ checkEq q.upstream "acme/widgets" "the upstream"
    ++ checkEq q.issueNumber 7 "the pull request"
    ++ checkEq q.kleisNarrow [] "a review's token is not narrowed"
    ++ check (!(q.toJson.getObjVal? "kleis_narrow" |>.isOk)) "nor does its request say so"
    ++ check ((q.prompt.splitOn "diff-reviewer agent show acme/widgets 7").length > 1)
      "the prompt says to run agent show"
    ++ checkStatus early 409 "a submission before the first read"
    ++ checkStatus shown 200 "the agent's first read"
    ++ checkEq (field shown "status") (some "running") "the job after the first read"
    ++ checkEq (field shown "headSha") (some headA) "the head, read from GitHub at queueing"
    ++ checkEq (field shown "title") (some "Add widgets") "the title"
    ++ checkEq (field shown "jobId") (some id) "the job id"
    ++ check (field shown "instructions" |>.isSome) "the instructions"
    ++ checkStatus diff 200 "the diff"
    ++ checkEq diff.contentType "text/plain; charset=utf-8" "the diff is text"
    ++ checkEq (← gh.diffCalls.get) 1 "GitHub asked for the diff once, then the cache"
    ++ check (diff.body == diff2.body) "the cached diff is the diff"
    ++ checkStatus other 404 "another pull request"
    ++ checkStatus wrongHead 409 "a review of another head"
    ++ checkStatus invalid 400 "a review GitHub would refuse"
    ++ checkStatus submitted 200 "the submission"
    ++ checkEq (field submitted "status") (some "draft") "the job after the submission"
    ++ checkStatus again 404 "a second submission, with no review running"
    ++ checkStatus afterSubmit 404 "the agent API once the review is a draft"
    ++ checkEq (field job "prType") (some "feature") "the pull request type"
    ++ checkStatus approved 200 "the approval"
    ++ checkStatus staleVersion 409 "posting a version that is not current"
    ++ checkStatus posted 200 "posting"
    ++ checkEq (field posted "status") (some "posted") "the job after posting"
    ++ checkStatus postedTwice 409 "posting a posted review"
    ++ checkEq postedReviews.size 1 "reviews on GitHub"
    ++ checkEq (postedReviews.map (·.2.2.1)) #[some headA] "the commit the review is pinned to"
    ++ checkStatus jobDiff 200 "the job's diff for the front-end"
    ++ checkEq (field jobDiff "headSha") (some headA) "the diff's head"

/-- GitHub refusing leaves the job approved with the reason; without GitHub, a 503. -/
def aFailedPostStaysApproved : Test := withTempDb do
  let gh ← FakeGitHub.new #[pull7]
  let logs ← IO.mkRef #[]
  let svc ← services gh none logs
  let st ← State.new cfg svc
  let job ← newJob st
  let id := (field job "id").getD ""
  let drafted ← route st (req .put s!"/api/v1/jobs/{id}/review" (reviewBody 1 fine))
  let approved ← route st (req .post s!"/api/v1/jobs/{id}/status"
    (statusBody "approved" (versionOf drafted)))
  gh.outcome.set .refused
  let refused ← route st (req .post s!"/api/v1/jobs/{id}/post"
    s!"\{\"version\": {versionOf approved}}")
  let some after ← Platform.findJob id | return #["the job is gone"]
  let noGitHub ← State.new cfg (← services none none logs)
  let unavailable ← route noGitHub (req .post s!"/api/v1/jobs/{id}/post"
    s!"\{\"version\": {after.version}}")
  gh.outcome.set .ok
  let retried ← route st (req .post s!"/api/v1/jobs/{id}/post" s!"\{\"version\": {after.version}}")
  return checkStatus refused 502 "GitHub refusing"
    ++ checkEq after.statusRaw "approved" "the job after the refusal"
    ++ check (after.error.any (·.startsWith "posting failed")) "the reason is recorded"
    ++ check (((bodyJson refused).getObjVal? "job").isOk) "the job is in the answer"
    ++ checkStatus unavailable 503 "posting without GitHub"
    ++ checkStatus retried 200 "posting again"
    ++ checkEq (field retried "error") none "the error, once posted"

/-- A `direct` repository's review is posted on submission. -/
def aDirectReviewIsPostedOnSubmission : Test := withTempDb do
  let gh ← FakeGitHub.new #[pull7]
  let orch ← FakeOrchestra.new
  let logs ← IO.mkRef #[]
  let svc ← services gh orch logs
  let st ← State.new cfg svc
  putRepo st "{\"mode\": \"direct\"}"
  let _ ← route st (req .post "/api/v1/jobs"
    s!"\{\"owner\": \"acme\", \"name\": \"widgets\", \"prNumber\": 7, \"headSha\": \"{headA}\"}")
  Workers.queuePending svc
  let _ ← route st (agentReq .get "")
  let submitted ← route st (agentReq .post "/review" (submission headA))
  return checkEq (field submitted "status") (some "posted") "the job after the submission"
    ++ checkEq (← gh.posted.get).size 1 "reviews on GitHub"

/-- Following the queue entry: running when it runs, through `continuedBy`, and failed when the run
    ends without a submission; a person's retry queues a new attempt under a new external id. -/
def followingMovesTheJob : Test := withTempDb do
  let gh ← FakeGitHub.new #[pull7 jobHead]
  let orch ← FakeOrchestra.new
  let logs ← IO.mkRef #[]
  let svc ← services gh orch logs
  let st ← State.new cfg svc
  let job ← newJob st
  let id := (field job "id").getD ""
  Workers.tick svc
  let some queued ← Platform.findJob id | return #["the job is gone"]
  Workers.follow svc
  let some stillQueued ← Platform.findJob id | return #["the job is gone"]
  orch.set "e0" "unfinished" (continuedBy := some "e9")
  orch.set "e9" "running"
  Workers.follow svc
  let some running ← Platform.findJob id | return #["the job is gone"]
  Workers.follow svc
  let some unchanged ← Platform.findJob id | return #["the job is gone"]
  orch.set "e9" "done"
  Workers.follow svc
  let some failed ← Platform.findJob id | return #["the job is gone"]
  let retry ← route st (req .post s!"/api/v1/jobs/{id}/status"
    (statusBody "pending" failed.version))
  Workers.tick svc
  let some requeued ← Platform.findJob id | return #["the job is gone"]
  let ids := (← orch.queued.get).map (·.externalId)
  return checkEq queued.statusRaw "queued" "the job once queued"
    ++ checkEq queued.queueEntry (some "e0") "its entry"
    ++ checkEq stillQueued.version queued.version "a pending entry changes nothing"
    ++ checkEq running.statusRaw "running" "the job once its continuation runs"
    ++ checkEq running.queueEntry (some "e9") "the entry followed"
    ++ checkEq unchanged.version running.version "nothing new, nothing written"
    ++ checkEq failed.statusRaw "failed" "the job once the run ended without a review"
    ++ check failed.error.isSome "why it failed"
    ++ checkStatus retry 200 "the retry"
    ++ checkEq (field retry "queueEntry") none "the old entry, after a retry"
    ++ checkEq requeued.statusRaw "queued" "the job, queued again"
    ++ checkEq ids #[id, s!"{id}.2"] "the external ids of the two attempts"

/-- A repeated failure to queue is recorded once, not on every pass. -/
def aRepeatedFailureIsRecordedOnce : Test := withTempDb do
  let logs ← IO.mkRef #[]
  let failing : Orchestra.Client :=
    { queue := fun _ => return .error "orchestra answered 429", entry := fun _ => return .error ""
      cancel := fun _ => return .ok () }
  let gh ← FakeGitHub.new #[pull7 jobHead]
  let svc ← Workers.Services.new (some gh.client) (some failing) (fun m => logs.modify (·.push m))
  let st ← State.new cfg svc
  let job ← newJob st
  let id := (field job "id").getD ""
  Workers.queuePending svc
  let some once ← Platform.findJob id | return #["the job is gone"]
  Workers.queuePending svc
  let some twice ← Platform.findJob id | return #["the job is gone"]
  return checkEq once.statusRaw "pending" "the job"
    ++ check (once.error.any (·.endsWith "429")) "the reason"
    ++ checkEq twice.version once.version "the version, after the second failure"

/-- The agent CLI's configuration and its local check of a submission. -/
def theAgentCliChecksItsInput : Test := do
  let file := (Json.parse "{\"url\": \"https://reviews.example/\", \"token\": \"kleis\"}").toOption
  let fromFile := Agent.resolve file none none
  let overridden := Agent.resolve file (some "http://127.0.0.1:1") (some "t")
  let missing := Agent.resolve none none (some "t")
  return check (fromFile matches .ok { url := "https://reviews.example", token := "kleis" })
      "the file, its trailing slash dropped"
    ++ check (overridden matches .ok { url := "http://127.0.0.1:1", token := "t" })
      "the environment overrides"
    ++ check (missing matches .error _) "no URL"
    ++ check (Agent.parseSubmission (submission headA) matches .ok _) "a good submission"
    ++ check (Agent.parseSubmission "{\"review\": {}}" matches .error _) "no head"
    ++ check (Agent.parseSubmission (submission headA
      "{\"decision\": \"comment\", \"body\": \"\", \"comments\": [{\"file\": \"\", \"start_line\": 1, \"end_line\": 1, \"body\": \"x\"}]}")
      matches .error _) "a comment on no file"
    ++ checkEq (Agent.splitSlug "acme/widgets") (some ("acme", "widgets")) "a slug"
    ++ checkEq (Agent.splitSlug "acme") none "half a slug"

/-- What curl is handed: every value quoted, so that nothing can end the line it is on; the body
    by file, not inline; and the requests it must not make refused before it is run. -/
def curlConfigIsQuoted : Test := do
  let r : Http.Request := { method := "POST", url := "https://x.example/a"
                          , headers := [("Authorization", "Bearer t\"x")]
                          , body := some "{}", noproxy := some "orch.example" }
  let c := Http.config r (some "/tmp/body")
  let lines := c.splitOn "\n"
  return checkEq (Http.quote "a\"b\\c\nd") "\"a\\\"b\\\\c\\nd\"" "quoting"
    ++ check (lines.contains "data-binary = \"@/tmp/body\"") "the body, from its file"
    ++ check (!lines.any (·.startsWith "data-binary = \"{")) "no body inline"
    ++ check (lines.contains "noproxy = \"orch.example\"") "orchestra past the proxy"
    ++ check (Http.check r).isNone "a good request"
    ++ check (Http.check { r with headers := [("Authorization", "Bearer t\r\nX-Evil: 1")] }).isSome
      "a header with a line break"
    ++ check (Http.check { r with url := "http://x.example/a" }).isSome "plain http"
    ++ check (Http.check { r with url := "http://127.0.0.1:8090/a" }).isNone "http to loopback"
    ++ checkEq (Http.hostOf "https://orch.example:8443/api") "orch.example" "a host"
    ++ checkEq (Http.hostOf "http://[::1]:80/") "::1" "an IPv6 host"

/-- The agent CLI against a real server on loopback: curl, the config it is handed, and the agent
    API's answer. -/
def theAgentCliTalksToTheServer : Test := withTempDb do
  let gh ← FakeGitHub.new #[pull7 jobHead]
  let orch ← FakeOrchestra.new
  let logs ← IO.mkRef #[]
  let svc ← services gh orch logs
  let st ← State.new cfg svc
  putRepo st "{\"mode\": \"staged\"}"
  let _ ← newJob st
  Workers.queuePending svc
  let (port, stop) ← Server.serve { cfg with port := 0 } svc
  try
    let agent : Agent.Config := { url := s!"http://127.0.0.1:{port}", token := agentToken }
    let shown ← Agent.request agent "GET" "acme/widgets" "7" ""
    let diff ← Agent.request agent "GET" "acme/widgets" "7" "/diff"
    let wrong ← Agent.request { agent with token := "kleis" } "GET" "acme/widgets" "7" ""
    let submitted ← Agent.request agent "POST" "acme/widgets" "7" "/review"
      (some (submission jobHead))
    let status (r : Except String Http.Response) := match r with
      | .ok r => r.status
      | .error _ => 0
    return checkEq (status shown) 200 "show"
      ++ checkEq (status diff) 200 "diff"
      ++ check (match diff with | .ok r => r.body.startsWith "diff --git" | .error _ => false)
        "the diff's text"
      ++ checkEq (status wrong) 401 "the placeholder, unreplaced"
      ++ checkEq (status submitted) 200 "submit"
  finally stop

def all : List (String × Test) :=
  [("discoveryFindsNewHeads", discoveryFindsNewHeads),
   ("withoutOrchestraJobsWait", withoutOrchestraJobsWait),
   ("anAgentReviewsAndItIsPosted", anAgentReviewsAndItIsPosted),
   ("aFailedPostStaysApproved", aFailedPostStaysApproved),
   ("aDirectReviewIsPostedOnSubmission", aDirectReviewIsPostedOnSubmission),
   ("followingMovesTheJob", followingMovesTheJob),
   ("aRepeatedFailureIsRecordedOnce", aRepeatedFailureIsRecordedOnce),
   ("theAgentCliChecksItsInput", theAgentCliChecksItsInput),
   ("curlConfigIsQuoted", curlConfigIsQuoted),
   ("theAgentCliTalksToTheServer", theAgentCliTalksToTheServer)]

end DiffReviewerTest.Workers