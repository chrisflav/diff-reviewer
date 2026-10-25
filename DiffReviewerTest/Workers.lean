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

structure FakeGitHub where
  pulls     : IO.Ref (Array GitHub.Pull)
  /-- Each posted review: the pull request, the review and the commit it was pinned to. -/
  posted    : IO.Ref (Array (Nat × Review × Option String))
  diffCalls : IO.Ref Nat
  /-- What posting fails with, while it is set. -/
  failPost  : IO.Ref (Option String)

def FakeGitHub.new (pulls : Array GitHub.Pull := #[]) : IO FakeGitHub := do
  return { pulls := ← IO.mkRef pulls, posted := ← IO.mkRef #[], diffCalls := ← IO.mkRef 0
         , failPost := ← IO.mkRef none }

def FakeGitHub.client (f : FakeGitHub) : GitHub.Client where
  listOpenPulls _ _ := return .ok (← f.pulls.get)
  getPull _ _ n := do
    match (← f.pulls.get).find? (·.number == n) with
    | some p => return .ok p
    | none => return .error "GitHub answered 404: Not Found"
  diff _ _ base head := do
    f.diffCalls.modify (· + 1)
    return .ok s!"diff --git a/A.lean b/A.lean\n--- {base}\n+++ {head}\n"
  postReview _ _ n review commit pending := do
    if let some e ← f.failPost.get then return .error e
    unless !pending do return .error "the platform posted a pending review"
    f.posted.modify (·.push (n, review, commit))
    return .ok s!"https://github.example/pull/{n}#review"

structure FakeOrchestra where
  queued  : IO.Ref (Array Orchestra.QueueRequest)
  entries : IO.Ref (Array Orchestra.Entry)

def FakeOrchestra.new : IO FakeOrchestra := do
  return { queued := ← IO.mkRef #[], entries := ← IO.mkRef #[] }

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

def headA : String := "aaaaaaaa11111111"

def headB : String := "bbbbbbbb22222222"

def base : String := "cccccccc33333333"

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

def submission (head : String) (review : String := fine) : String :=
  s!"\{\"headSha\": \"{head}\", \"prType\": \"feature\", \"review\": {review}}"

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
  -- A job asked for without a head: queueing reads it from GitHub.
  let created ← route st (req .post "/api/v1/jobs"
    "{\"owner\": \"acme\", \"name\": \"widgets\", \"prNumber\": 7}")
  let id := (field created "id").getD ""
  let beforeQueue ← route st (agentReq .get "")
  Workers.queuePending svc
  let queued ← orch.queued.get
  let some q := queued[0]? | return #["nothing was queued"]
  let early ← route st (agentReq .post "/review" (submission headA))
  let shown ← route st (agentReq .get "")
  let diff ← route st (agentReq .get "/diff")
  let diff2 ← route st (agentReq .get "/diff")
  let other ← route st (agentReq .get "" (pr := 8))
  let wrongHead ← route st (agentReq .post "/review" (submission headB))
  let invalid ← route st (agentReq .post "/review" (submission headA
    "{\"decision\": \"comment\", \"body\": \"\", \"comments\": [{\"file\": \"A.lean\", \"start_line\": 0, \"end_line\": 0, \"body\": \"x\"}]}"))
  let submitted ← route st (agentReq .post "/review" (submission headA))
  let again ← route st (agentReq .post "/review" (submission headA))
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
    ++ checkEq (postedReviews.map (·.2.2)) #[some headA] "the commit the review is pinned to"
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
  gh.failPost.set (some "GitHub answered 422: Unprocessable Entity")
  let refused ← route st (req .post s!"/api/v1/jobs/{id}/post"
    s!"\{\"version\": {versionOf approved}}")
  let some after ← Platform.findJob id | return #["the job is gone"]
  let noGitHub ← State.new cfg (← services none none logs)
  let unavailable ← route noGitHub (req .post s!"/api/v1/jobs/{id}/post"
    s!"\{\"version\": {after.version}}")
  gh.failPost.set none
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
  let gh ← FakeGitHub.new #[pull7]
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
    { queue := fun _ => return .error "orchestra answered 429", entry := fun _ => return .error "" }
  let gh ← FakeGitHub.new #[pull7]
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

/-- What curl is handed: every value quoted, so a header or body cannot end the line it is on. -/
def curlConfigIsQuoted : Test := do
  let c := Http.config { method := "POST", url := "https://x.example/a"
                       , headers := [("Authorization", "Bearer t\"\nurl = https://evil")]
                       , body := some "{\"a\": \"b\\\\c\"}" }
  let lines := c.splitOn "\n"
  return checkEq (Http.quote "a\"b\\c\nd") "\"a\\\"b\\\\c\\nd\"" "quoting"
    ++ check (!lines.any (·.startsWith "url = https://evil")) "a header cannot add a line"
    ++ check (lines.contains "data-binary = \"{\\\"a\\\": \\\"b\\\\\\\\c\\\"}\"") "the body"

/-- The agent CLI against a real server on loopback: curl, the config it is handed, and the agent
    API's answer. -/
def theAgentCliTalksToTheServer : Test := withTempDb do
  let gh ← FakeGitHub.new #[pull7]
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
      (some (submission "abcdef1"))
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