import DiffReviewer
import DiffReviewerTest.Basic
import DiffReviewerTest.Server
import DiffReviewerTest.Workers
import DiffReviewerTest.Calibration

open Lean (Json)
open DiffReviewer
open DiffReviewer.Server
open DiffReviewerTest.Server
open DiffReviewerTest.Workers

/-!
# Fan-out, against fakes

A repository whose `feature` type asks for fan-out, and fixes it as the type of its reviews: a
job is reviewed by three sub-runs — the default, `correctness` and `naming` — each queued on the
fake orchestra under `<job>.<key>`, each bound to itself on the agent API, merged into one draft
once all are in or failed. And the merge's rules on their own, the caps, and a calibration run
that fans out and is scored on the merged draft.
-/

namespace DiffReviewerTest.Fanout

/-- A rubric whose `feature` type fans out over two categories. -/
def fanoutRubric : String :=
  "{\"version\": 0, \"defaultRubric\": \"Be careful.\", \"prTypes\": [\
{\"name\": \"feature\", \"fanout\": true, \"description\": \"New things.\", \"categories\": [\
{\"name\": \"correctness\", \"description\": \"Wrong, or proves the wrong thing.\"}, \
{\"name\": \"naming\", \"description\": \"Against the naming convention.\"}]}, \
{\"name\": \"refactor\", \"categories\": [{\"name\": \"loss\"}]}]}"

def commentJson (start stop : Nat) (body category severity : String) : String :=
  s!"\{\"file\": \"A.lean\", \"start_line\": {start}, \"end_line\": {stop}, \"body\": \"{body}\", \
\"category\": \"{category}\", \"severity\": \"{severity}\"}"

def reviewJson (decision body : String) (comments : List String) : String :=
  s!"\{\"decision\": \"{decision}\", \"body\": \"{body}\", \"comments\": \
[{", ".intercalate comments}]}"

/-- `r`, naming `id` as its job, as `--job` does. -/
def asJob (r : Req) (id : String) : Req :=
  { r with header := fun k => if k == "x-diff-reviewer-job" then some id else r.header k }

/-- A staged repository, with the fan-out rubric and `feature` fixed as its type, and a job for
    pull request 7 at `jobHead`; answers the job's id. -/
def fannedRepo (st : State) (repo : String := "{\"mode\": \"staged\", \"prType\": \"feature\"}")
    (pr : Nat := 7) : IO String := do
  let _ ← route st (req .put "/api/v1/repos/acme/widgets" "{\"mode\": \"staged\"}")
  let _ ← route st (req .put "/api/v1/repos/acme/widgets/rubrics" fanoutRubric)
  let _ ← route st (req .put "/api/v1/repos/acme/widgets" repo)
  let job ← route st (req .post "/api/v1/jobs"
    s!"\{\"owner\": \"acme\", \"name\": \"widgets\", \"prNumber\": {pr}, \
\"headSha\": \"{jobHead}\"}")
  return (field job "id").getD ""

def subRunsOf (r : Reply) : List Json :=
  (((bodyJson r).getObjVal? "subRuns").toOption.bind (·.getArr?.toOption)).map (·.toList)
    |>.getD []

def strOf (j : Json) (k : String) : Option String := (j.getObjValAs? String k).toOption

def has (s t : String) : Bool := (s.splitOn t).length > 1

/-- The JSON at `path` of `j`, compressed. -/
def str? (j : Json) (path : List String) : Option String :=
  match path with
  | [] => some j.compress
  | k :: ks => (j.getObjVal? k).toOption.bind (str? · ks)

/-- Fan-out is planned from the fixed type, or the document, never from a type the agent would
    pick; keys are made of the categories' names, unique, and never a number. -/
def theFanoutIsPlanned : Test := do
  let some doc := (Json.parse fanoutRubric).toOption.bind
      (fun j => (Rubric.ofJson j ["version"]).toOption)
    | return #["the rubric does not read"]
  let names (p : Option FanoutPlan) := p.map fun p => (p.prType, p.categories.map (·.name))
  let docWide := { doc with fanout := true }
  let back := (Rubric.ofJson (doc.toJson)).toOption
  return checkEq (names (doc.fanoutPlan (some "feature")))
      (some (some "feature", ["correctness", "naming"])) "the fixed type that fans out"
    ++ checkEq (names (doc.fanoutPlan none)) none "a type the agent would pick: one run"
    ++ checkEq (names (doc.fanoutPlan (some "refactor"))) none "a fixed type that does not fan out"
    ++ checkEq (names (docWide.fanoutPlan none))
      (some (none, ["correctness", "naming", "loss"])) "the document's fan-out, no type fixed"
    ++ checkEq (names (docWide.fanoutPlan (some "refactor"))) (some (some "refactor", ["loss"]))
      "the document's fan-out, a type fixed"
    ++ checkEq (names (docWide.fanoutPlan (some "gone")))
      (some (none, ["correctness", "naming", "loss"])) "a fixed type the document dropped"
    ++ checkEq ((doc.fanoutPlan (some "feature")).map (·.size)) (some 3) "three sub-runs"
    ++ check (back == some doc) "the fanout flag survives a round trip"
    ++ check (!has (doc.toJson.compress) "\"fanout\":false") "and is written only when on"
    ++ check ((Rubric.ofJson (.mkObj [("fanout", "yes")])) matches .error _) "a fanout not a bool"
    ++ checkEq (str? (Proposal.diffJson doc docWide) ["fanout", "after"]) (some "true")
      "a proposal's diff shows the document's fanout"
    ++ checkEq (str? (Proposal.diffJson docWide docWide) ["fanout"]) (some "null")
      "and nothing when it is the same"
    ++ checkEq (str? (Proposal.diffJson doc { doc with prTypes := doc.prTypes.map fun t =>
        { t with fanout := false } }) ["typesChanged"])
      (some "[{\"categoriesAdded\":[],\"categoriesChanged\":[],\"categoriesRemoved\":[],\
\"description\":null,\"fanout\":{\"after\":false,\"before\":true},\"name\":\"feature\",\
\"rubric\":null}]")
      "a type whose fanout alone changed is changed"
    ++ checkEq (Fanout.keysOf ["Correctness", "naming!", "default", "42", "naming?", ""])
      ["default", "correctness", "naming", "default-2", "c42", "naming-2", "c"] "the keys"

/-- The merge: duplicates are one, the more severe kept in the first's place; ids stay unique;
    summaries are by category; the decision is the strictest, and never an approval when a
    sub-run failed; and the cap drops the least severe first, saying so. -/
def theMergeRules : Test := do
  let c (start stop : Nat) (body : String) (sev : Option Severity) (id : Option String)
      (cat : String := "x") : InlineComment :=
    { file := "A.lean", range := { startLine := start, endLine := stop }, body, suggestion := none
    , id, category := some cat, severity := sev }
  let general : Review := { decision := .comment, body := "General.", comments :=
    [c 3 5 "Rename this variable to something clearer." (some .minor) (some "x1")] }
  let correctness : Review := { decision := .requestChanges, body := " Wrong. ", comments :=
    [c 4 4 "rename this variable, to something clearer" (some .major) (some "x1") "correctness",
     c 10 10 "Off by one." (some .blocker) (some "x1") "correctness",
     c 30 30 "Rename this variable to something clearer." (some .minor) (some "x2")
       "correctness"] }
  let naming : Review := { decision := .approve, body := "", comments := [] }
  let m := Fanout.merge [{ category := none, review := some general },
    { category := some "correctness", review := some correctness },
    { category := some "naming", review := some naming }]
  let assigned ← m.assignIds
  let ids := assigned.comments.filterMap (·.id)
  let failed := Fanout.merge [{ category := none, review := some naming },
    { category := some "naming", review := none }]
  let many : Review := { decision := .comment, body := "Many.", comments :=
    [c 1 1 "one" (some .blocker) none, c 2 2 "two" (some .nit) none, c 3 3 "three" none none,
     c 4 4 "four" (some .minor) none, c 5 5 "five" (some .nit) none] }
  let capped := Fanout.merge [{ category := none, review := some many }] (cap := 3)
  return checkEq m.decision .requestChanges "the strictest decision"
    ++ checkEq (m.comments.map (·.range.startLine)) [4, 10, 30]
      "the duplicate merged into the first's place, the more severe kept"
    ++ checkEq (m.comments.map (·.severity)) [some .major, some .blocker, some .minor]
      "their severities"
    ++ checkEq ((m.comments.head?).map fun c => (c.body, c.category))
      (some ("rename this variable, to something clearer", some "correctness"))
      "the kept comment's body and category are its own"
    ++ checkEq (m.comments.map (·.id)) [some "x1", none, some "x2"] "a repeated id cleared"
    ++ checkEq ids.length 3 "every comment has an id once assigned"
    ++ checkEq ids.eraseDups.length 3 "and they are unique"
    ++ checkEq m.body "General.\n\n**correctness.** Wrong." "the summaries, by category"
    ++ check (assigned.validate matches .ok ()) "the merge is a valid review"
    ++ checkEq failed.decision .comment "an approval with a sub-run missing is a comment"
    ++ check (has failed.body "_Not reviewed: the naming review did not finish._")
      "the summary names what was not reviewed"
    ++ checkEq (capped.comments.map (·.body)) ["one", "two", "four"]
      "the cap drops no severity, then the last nit"
    ++ check (has capped.body "2 comment(s) were dropped" &&
        has capped.body "no severity: 1, nit: 1") "and says so"
    ++ check (Fanout.nearIdentical "Rename this, please." "rename this please")
      "near-identical bodies"
    ++ check (!Fanout.nearIdentical "Rename this." "Delete this.") "different bodies"

/-- A job of a type that fans out is not queued itself: its three sub-runs are, under
    `<job>.<key>`, each told its category; the job shows them, `queued` with no entry of its own.
    The pull request moving on cancels all three. -/
def aFanoutIsQueued : Test := withTempDb do
  let gh ← FakeGitHub.new #[pull7 jobHead]
  let orch ← FakeOrchestra.new
  let logs ← IO.mkRef #[]
  let svc ← services gh orch logs
  let st ← State.new cfg svc
  let id ← fannedRepo st "{\"mode\": \"staged\", \"prType\": \"feature\", \"autoReview\": true}"
  Workers.queuePending svc
  let queued ← orch.queued.get
  let job ← route st (req .get s!"/api/v1/jobs/{id}")
  let listed ← route st (req .get "/api/v1/jobs")
  let listedSubs := ((DiffReviewerTest.Calibration.items listed).head?.bind fun j =>
    (j.getObjVal? "subRuns").toOption.bind (·.getArr?.toOption)).map (·.size)
  let prompt (k : Nat) := (queued[k]?.map (·.prompt)).getD ""
  gh.pulls.set #[pull7 headB]
  Workers.discover svc
  let after ← route st (req .get s!"/api/v1/jobs/{id}")
  return checkEq (queued.map (·.externalId)) #[s!"{id}.default", s!"{id}.correctness",
      s!"{id}.naming"] "the sub-runs' external ids"
    ++ checkEq (queued.map (·.issueNumber)) #[some 7, some 7, some 7] "of the pull request"
    ++ check (has (prompt 1) s!"--job {id}.correctness") "a sub-run names itself"
    ++ check (has (prompt 1) "covers only the category `correctness`" &&
        has (prompt 1) "Wrong, or proves the wrong thing.") "and is told its category"
    ++ check (has (prompt 0) "general review" && has (prompt 0) "`naming`")
      "the default's prompt names the others' categories"
    ++ checkEq (field job "status") (some "queued") "the job, fanned out"
    ++ checkEq (field job "queueEntry") none "with no entry of its own"
    ++ checkEq (field job "prType") (some "feature") "of the fixed type"
    ++ checkEq (versionOf job) 2 "fanned out in one write"
    ++ checkEq ((subRunsOf job).map (strOf · "key")) [some "default", some "correctness",
      some "naming"] "its sub-runs"
    ++ checkEq ((subRunsOf job).map (strOf · "status")) [some "queued", some "queued",
      some "queued"] "queued"
    ++ checkEq listedSubs (some 3) "the list shows them too"
    ++ checkEq (field after "status") (some "stale") "the job, once its pull request moved on"
    ++ checkEq (← orch.cancelled.get) #["e0", "e1", "e2"] "every sub-run's run cancelled"
    ++ checkEq ((subRunsOf after).map (strOf · "status")) [some "cancelled", some "cancelled",
      some "cancelled"] "and every sub-run"

/-- A sub-run is named `<job>.<key>`; the job alone, a key it has not, and a sub-run not being run
    are refused. Its submission is a partial review of its category only, under the type the
    repository fixed; once all three are in they are merged into the job's draft — the agent's
    one revision — and the job goes on as any draft. -/
def subRunsAreBound : Test := withTempDb do
  let gh ← FakeGitHub.new #[pull7 jobHead]
  let orch ← FakeOrchestra.new
  let logs ← IO.mkRef #[]
  let svc ← services gh orch logs
  let st ← State.new cfg svc
  let id ← fannedRepo st
  Workers.queuePending svc
  let a (sub : String) (r : Req) := route st (asJob r s!"{id}{sub}")
  let bare ← a "" (agentReq .get "")
  let unknown ← a ".nope" (agentReq .get "")
  let ok := reviewJson "comment" "Correct." [commentJson 4 5 "Off by one." "correctness" "major"]
  let early ← a ".correctness" (agentReq .post "/review" (submission jobHead ok "\"feature\""))
  let shown ← a ".correctness" (agentReq .get "")
  let some afterShow ← Platform.findJob id | return #["the job is gone"]
  let diff ← a ".correctness" (agentReq .get "/diff")
  let wrongCategory ← a ".correctness" (agentReq .post "/review" (submission jobHead
    (reviewJson "comment" "x" [commentJson 4 5 "A name." "naming" "minor"]) "\"feature\""))
  let wrongType ← a ".correctness" (agentReq .post "/review"
    (submission jobHead ok "\"refactor\""))
  let submitted ← a ".correctness" (agentReq .post "/review"
    (submission jobHead ok "\"feature\""))
  let again ← a ".correctness" (agentReq .get "")
  let _ ← a ".default" (agentReq .get "")
  let general ← a ".default" (agentReq .post "/review" (submission jobHead
    (reviewJson "approve" "Fine otherwise." [commentJson 5 5 "off by one" "naming" "minor"])
    "\"feature\""))
  let _ ← a ".naming" (agentReq .get "")
  let last ← a ".naming" (agentReq .post "/review" (submission jobHead
    (reviewJson "comment" "Names." [commentJson 8 8 "Call it `widget`." "naming" "nit"])
    "\"feature\""))
  let some job ← Platform.findJob id | return #["the job is gone"]
  let revisions ← Platform.revisions id
  let review := match job.review? with
    | some (.ok r) => some r
    | _ => none
  let shownText := String.fromUTF8! shown.body
  return checkStatus bare 409 "the job alone, which is run in sub-runs"
    ++ checkStatus unknown 404 "a sub-run it has not"
    ++ checkStatus early 409 "a submission before the sub-run's first read"
    ++ checkStatus shown 200 "the sub-run's read"
    ++ check (has shownText "This review's scope" && has shownText "\"category\":\"correctness\"")
      "it is told its scope"
    ++ check (has shownText "\"prType\":\"feature\"") "and the type"
    ++ check (has shownText "\"others\":[\"naming\"]") "and the others' categories"
    ++ checkEq afterShow.statusRaw "running" "the job, once a sub-run runs"
    ++ checkStatus diff 200 "the sub-run reads the diff"
    ++ checkStatus wrongCategory 400 "a comment of another category"
    ++ checkStatus wrongType 400 "another type"
    ++ checkStatus submitted 200 "the partial review"
    ++ checkEq (field submitted "subRunStatus") (some "submitted") "the sub-run, submitted"
    ++ checkEq (field submitted "status") (some "running") "the job, waiting for the others"
    ++ checkStatus again 404 "a sub-run that has submitted"
    ++ checkStatus general 200 "the default's review"
    ++ checkStatus last 200 "the last review"
    ++ checkEq (field last "status") (some "draft") "the job, merged"
    ++ checkEq job.prType (some "feature") "of its type"
    ++ checkEq job.rubricVersion (some 1) "under the rubric it fanned out by"
    ++ checkEq ((review.map (·.comments.map (·.range.startLine))).getD []) [4, 8]
      "the duplicate merged, the more severe kept"
    ++ checkEq (review.map (·.decision)) (some .comment) "the strictest decision"
    ++ check ((review.map (has ·.body "**naming.** Names.")).getD false) "the summaries"
    ++ checkEq (revisions.map (·.author)) #["agent"] "the merge is the agent's one revision"

/-- A sub-run whose run ends without a submission is run once more, under a new external id;
    ending again, it has failed, and the job is merged without it — never as an approval. A job
    all of whose sub-runs fail fails. -/
def aSubRunFails : Test := withTempDb do
  let gh ← FakeGitHub.new #[pull7 jobHead, { pull7 jobHead with number := 8 }]
  let orch ← FakeOrchestra.new
  let logs ← IO.mkRef #[]
  let svc ← services gh orch logs
  let st ← State.new cfg svc
  let id ← fannedRepo st
  Workers.queuePending svc
  let a (sub : String) (r : Req) := route st (asJob r s!"{id}{sub}")
  orch.set "e1" "failed"
  Workers.followSubRuns svc
  let retrying ← route st (req .get s!"/api/v1/jobs/{id}")
  Workers.queueRetries svc
  let ids := (← orch.queued.get).map (·.externalId)
  orch.set "e3" "done"
  Workers.followSubRuns svc
  for (sub, body) in [(".default", reviewJson "approve" "Fine." []),
                      (".naming", reviewJson "approve" "" [])] do
    let _ ← a sub (agentReq .get "")
    let _ ← a sub (agentReq .post "/review" (submission jobHead body "\"feature\""))
  let some job ← Platform.findJob id | return #["the job is gone"]
  let review := match job.review? with
    | some (.ok r) => some r
    | _ => none
  -- Pull request 8: every sub-run fails twice.
  let job8 ← route st (req .post "/api/v1/jobs"
    s!"\{\"owner\": \"acme\", \"name\": \"widgets\", \"prNumber\": 8, \"headSha\": \"{jobHead}\"}")
  let id8 := (field job8 "id").getD ""
  Workers.queuePending svc
  for e in ["e4", "e5", "e6"] do orch.set e "failed"
  Workers.followSubRuns svc
  Workers.queueRetries svc
  for e in ["e7", "e8", "e9"] do orch.set e "cancelled"
  Workers.followSubRuns svc
  let some failed ← Platform.findJob id8 | return #["the second job is gone"]
  -- Run again by a person: a new round, under the job's second attempt.
  let _ ← route st (req .post s!"/api/v1/jobs/{id8}/status" (statusBody "pending" failed.version))
  Workers.queuePending svc
  let round2 := ((← orch.queued.get).extract 10 13).map (·.externalId)
  let current ← Fanout.current id8
  return checkEq ((subRunsOf retrying).map (strOf · "status")) [some "queued", some "pending",
      some "queued"] "the sub-run whose run failed waits to run again"
    ++ check ((subRunsOf retrying).any fun s => (strOf s "error").any (has · "run again"))
      "saying so"
    ++ checkEq ids #[s!"{id}.default", s!"{id}.correctness", s!"{id}.naming",
      s!"{id}.correctness.2"] "run again under a new external id"
    ++ checkEq job.statusRaw "draft" "merged without the failed sub-run"
    ++ checkEq (review.map (·.decision)) (some .comment) "as a comment, not an approval"
    ++ check ((review.map (has ·.body "the correctness review did not finish")).getD false)
      "the summary says what was not reviewed"
    ++ checkEq failed.statusRaw "failed" "a job all of whose sub-runs failed"
    ++ check (failed.error.any (has · "every sub-run failed")) "and why"
    ++ checkEq round2 #[s!"{id8}.2.default", s!"{id8}.2.correctness", s!"{id8}.2.naming"]
      "a job run again fans out anew, under its second attempt's external id"
    ++ checkEq (current.map (·.round)) #[1, 1, 1] "the current round"
    ++ checkEq (current.map (·.status)) #["queued", "queued", "queued"] "queued afresh"

/-- A fan-out past `maxFanout` is refused, and the job fails; every sub-run counts against the
    day's cap of review jobs, so a fan-out past it waits, saying so once, and discovery counts the
    sub-runs. The settings are checked. -/
def fanoutsAreCapped : Test := withTempDb do
  let gh ← FakeGitHub.new #[pull7 jobHead, { pull7 jobHead with number := 8 }]
  let orch ← FakeOrchestra.new
  let logs ← IO.mkRef #[]
  let svc ← Workers.Services.new (some gh.client) (some orch.client)
    (fun m => logs.modify (·.push m)) { maxJobsPerDay := 3 }
  let st ← State.new cfg svc
  let id ← fannedRepo st "{\"mode\": \"staged\", \"prType\": \"feature\", \"maxFanout\": 2}"
  Workers.queuePending svc
  let some refused ← Platform.findJob id | return #["the job is gone"]
  let zero ← route st (req .put "/api/v1/repos/acme/widgets" "{\"maxFanout\": 0}")
  let huge ← route st (req .put "/api/v1/repos/acme/widgets" "{\"maxFanout\": 99}")
  let noType ← route st (req .put "/api/v1/repos/acme/widgets" "{\"prType\": \"nope\"}")
  let cleared ← route st (req .put "/api/v1/repos/acme/widgets" "{\"prType\": \"\"}")
  let raised ← route st (req .put "/api/v1/repos/acme/widgets"
    "{\"prType\": \"feature\", \"maxFanout\": 8}")
  -- The failed job is run again: three sub-runs, the whole day's cap.
  let some failed ← Platform.findJob id | return #["the job is gone"]
  let _ ← route st (req .post s!"/api/v1/jobs/{id}/status" (statusBody "pending" failed.version))
  Workers.queuePending svc
  let some fanned ← Platform.findJob id | return #["the job is gone"]
  let job8 ← route st (req .post "/api/v1/jobs"
    s!"\{\"owner\": \"acme\", \"name\": \"widgets\", \"prNumber\": 8, \"headSha\": \"{jobHead}\"}")
  let id8 := (field job8 "id").getD ""
  Workers.queuePending svc
  let some waiting ← Platform.findJob id8 | return #["the second job is gone"]
  Workers.queuePending svc
  let some still ← Platform.findJob id8 | return #["the second job is gone"]
  let spent ← Fanout.reviewSpend "acme" "widgets" "2000-01-01T00:00:00Z"
  return checkEq refused.statusRaw "failed" "a fan-out past maxFanout"
    ++ check (refused.error.any (has · "maxFanout")) "and why"
    ++ checkStatus zero 400 "a maxFanout of 0"
    ++ checkStatus huge 400 "a maxFanout past the limit"
    ++ checkStatus noType 400 "a fixed type the rubric does not name"
    ++ checkStatus cleared 200 "clearing the fixed type"
    ++ checkEq (((bodyJson cleared).getObjVal? "prType").toOption) (some .null) "cleared"
    ++ checkEq (((bodyJson raised).getObjValAs? Nat "maxFanout").toOption) (some 8) "raised"
    ++ checkEq fanned.statusRaw "queued" "the job, run again and fanned out"
    ++ checkEq ((← orch.queued.get).map (·.externalId)) #[s!"{id}.default",
      s!"{id}.correctness", s!"{id}.naming"] "its sub-runs, the job's first queued attempt"
    ++ checkEq waiting.statusRaw "pending" "a fan-out past the day's cap waits"
    ++ check (waiting.error.any (has · "--max-jobs-per-day")) "saying so"
    ++ checkEq still.version waiting.version "once"
    ++ checkEq spent 4 "three sub-runs and the job waiting"

/-- A calibration job under a rubric that fans out fans out too: its run is charged for every
    sub-run, each sub-run is narrowed and never posted, and the job is scored on the merged
    draft. -/
def calibrationFansOut : Test := withTempDb do
  let f ← DiffReviewerTest.Calibration.FakeHistory.new
  let orch ← FakeOrchestra.new
  let svc ← DiffReviewerTest.Calibration.services f orch { maxCalibrationJobsPerDay := 3 }
  let st ← State.new cfg svc
  let _ ← DiffReviewerTest.Calibration.imported st svc f
  let _ ← route st (req .put "/api/v1/repos/acme/widgets/rubrics"
    "{\"version\": 0, \"fanout\": true, \"prTypes\": [{\"name\": \"feature\", \"categories\": [\
{\"name\": \"naming\"}, {\"name\": \"docs\"}]}]}")
  let s301 ← DiffReviewerTest.Calibration.sampleId st 301
  let s201 ← DiffReviewerTest.Calibration.sampleId st 201
  let two ← DiffReviewerTest.Calibration.runOf st [s301, s201]
  let made ← DiffReviewerTest.Calibration.runOf st [s301]
  let runId := (field made "id").getD ""
  let jobId := (((DiffReviewerTest.Calibration.resultsOf made).head?).bind
    (DiffReviewerTest.Calibration.str · ["jobId"])).getD ""
  let more ← DiffReviewerTest.Calibration.runOf st [s201]
  Workers.queuePending svc
  let queued ← orch.queued.get
  let a (sub : String) (r : Req) := route st (asJob r s!"{jobId}{sub}")
  for (sub, body) in [
      (".default", reviewJson "request_changes" "Two things." []),
      (".naming", reviewJson "comment" "A name." [commentJson 4 5 "a name" "naming" "minor"]),
      (".docs", reviewJson "comment" "A doc." [commentJson 18 18 "a doc" "docs" "nit"])] do
    let _ ← a sub (agentReq .get "" (pr := 13))
    let _ ← a sub (agentReq .post "/review" (submission jobHead body) (pr := 13))
  let some job ← Platform.findJob jobId | return #["the calibration job is gone"]
  let run ← route st (req .get s!"{DiffReviewerTest.Calibration.repoPath}/calibration/runs/{runId}")
  let result := ((DiffReviewerTest.Calibration.resultsOf run).head?).getD .null
  let ratio := DiffReviewerTest.Calibration.ratioOf result
  return checkStatus two 429 "a run whose sub-runs would pass the day's cap"
    ++ checkStatus made 201 "a run of one, three sub-runs"
    ++ checkStatus more 429 "the cap, spent on the sub-runs"
    ++ checkEq (queued.map (·.externalId)) #[s!"{jobId}.default", s!"{jobId}.naming",
      s!"{jobId}.docs"] "its sub-runs, queued"
    ++ checkEq (queued.map (·.kleisNarrow)) (#[0, 1, 2].map fun _ => Workers.calibrationNarrowing)
      "each narrowed"
    ++ check (queued.all (has ·.prompt "never posted")) "each told it is never posted"
    ++ checkEq job.statusRaw "draft" "merged"
    ++ checkEq (← f.gh.posted.get).size 0 "nothing posted"
    ++ checkEq (ratio ["score", "precision"]) (some "0.5") "scored on the merged draft: precision"
    ++ checkEq (ratio ["score", "recall"]) (some "0.5") "and recall"

/-- A job fanned out, failed, and run again as one run — its rubric no longer fans out — is that
    one run: the old round is history, shown nowhere, naming nothing on the agent API, never
    settled over the new run's draft. -/
def aStaleRoundIsHistory : Test := withTempDb do
  let gh ← FakeGitHub.new #[pull7 jobHead]
  let orch ← FakeOrchestra.new
  let logs ← IO.mkRef #[]
  let svc ← services gh orch logs
  let st ← State.new cfg svc
  let id ← fannedRepo st
  Workers.queuePending svc
  for e in ["e0", "e1", "e2"] do orch.set e "failed"
  Workers.followSubRuns svc
  Workers.queueRetries svc
  for e in ["e3", "e4", "e5"] do orch.set e "failed"
  Workers.followSubRuns svc
  let some failed ← Platform.findJob id | return #["the job is gone"]
  let _ ← route st (req .put "/api/v1/repos/acme/widgets" "{\"prType\": \"\"}")
  let _ ← route st (req .post s!"/api/v1/jobs/{id}/status" (statusBody "pending" failed.version))
  Workers.queuePending svc
  let queued ← route st (req .get s!"/api/v1/jobs/{id}")
  let stale ← route st (asJob (agentReq .get "") s!"{id}.default")
  let shown ← route st (asJob (agentReq .get "") id)
  Workers.followSubRuns svc
  let some running ← Platform.findJob id | return #["the job is gone"]
  let submitted ← route st (asJob (agentReq .post "/review"
    (submission jobHead (prType := "\"feature\""))) id)
  Workers.followSubRuns svc
  let some after ← Platform.findJob id | return #["the job is gone"]
  return checkEq failed.statusRaw "failed" "every sub-run failed"
    ++ checkEq ((← orch.queued.get).back?.map (·.externalId)) (some s!"{id}.2")
      "run again as one run"
    ++ checkEq (subRunsOf queued) [] "the old round is not shown"
    ++ checkStatus stale 404 "nor named"
    ++ checkStatus shown 200 "the one run is answered"
    ++ checkEq running.statusRaw "running" "and not failed by the old round"
    ++ checkStatus submitted 200 "its review"
    ++ checkEq after.statusRaw "draft" "is the draft"
    ++ checkEq ((after.review?.bind (·.toOption)).map (·.body)) (some "Fine.")
      "and no merge of the old round is written over it"

/-- A run given up on may still submit: the run that replaced it, named `<job>.<key>.2`, is then
    cancelled. Running a sub-run again costs a run more. -/
def aGivenUpRunMaySubmit : Test := withTempDb do
  let gh ← FakeGitHub.new #[pull7 jobHead]
  let orch ← FakeOrchestra.new
  let logs ← IO.mkRef #[]
  let svc ← services gh orch logs
  let st ← State.new cfg svc
  let id ← fannedRepo st
  Workers.queuePending svc
  orch.set "e1" "unfinished"
  Workers.followSubRuns svc
  Workers.queueRetries svc
  let retryPrompt := ((← orch.queued.get)[3]?.map (·.prompt)).getD ""
  let spent ← Fanout.reviewSpend "acme" "widgets" "2000-01-01T00:00:00Z"
  let late ← route st (asJob (agentReq .post "/review" (submission jobHead
    (reviewJson "comment" "Late." [commentJson 4 4 "Off." "correctness" "minor"]) "\"feature\""))
    s!"{id}.correctness")
  let unknown ← route st (asJob (agentReq .get "") s!"{id}.naming.2")
  return check (has retryPrompt s!"--job {id}.correctness.2") "the second run is named so"
    ++ checkEq spent 4 "three sub-runs and a run again"
    ++ checkStatus late 200 "the run given up on submits"
    ++ checkEq (← orch.cancelled.get) #["e3"] "and the run that replaced it is cancelled"
    ++ checkStatus unknown 404 "a run the platform never made"

/-- A job retired between its queueing and the record of it has its run cancelled, as one run
    and as a sub-run. -/
def aRetiredJobsRunIsCancelled : Test := withTempDb do
  let gh ← FakeGitHub.new #[pull7 jobHead]
  let orch ← FakeOrchestra.new
  let retiring : Orchestra.Client := { orch.client with
    queue := fun r => do
      let e ← orch.client.queue r
      for j in ← Platform.jobsOfPull "acme" "widgets" 7 do
        let _ ← Platform.updateJob j.id fun j => return { j with statusRaw := "stale" }
      return e }
  let svc ← Workers.Services.new (some gh.client) (some retiring) (fun _ => pure ())
  let st ← State.new cfg svc
  let _ ← newJob st
  Workers.queuePending svc
  let single ← orch.cancelled.get
  let _ ← fannedRepo st
  Workers.queuePending svc
  let all ← orch.cancelled.get
  return checkEq single #["e0"] "one run's entry"
    ++ check (all.contains "e1") "a sub-run's entry"

def all : List (String × Test) :=
  [("theFanoutIsPlanned", theFanoutIsPlanned),
   ("theMergeRules", theMergeRules),
   ("aFanoutIsQueued", aFanoutIsQueued),
   ("subRunsAreBound", subRunsAreBound),
   ("aSubRunFails", aSubRunFails),
   ("fanoutsAreCapped", fanoutsAreCapped),
   ("calibrationFansOut", calibrationFansOut),
   ("aStaleRoundIsHistory", aStaleRoundIsHistory),
   ("aGivenUpRunMaySubmit", aGivenUpRunMaySubmit),
   ("aRetiredJobsRunIsCancelled", aRetiredJobsRunIsCancelled)]

end DiffReviewerTest.Fanout