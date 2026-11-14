import DiffReviewer
import DiffReviewerTest.Basic
import DiffReviewerTest.Server
import DiffReviewerTest.Workers
import DiffReviewerTest.Calibration
import DiffReviewerTest.FakeGit

open Lean (Json)
open DiffReviewer
open DiffReviewer.Server
open DiffReviewerTest.Server
open DiffReviewerTest.Workers
open DiffReviewerTest.Calibration
open DiffReviewerTest.FakeGit

/-!
# Learned review style and rubric proposals, against fakes

The examples `agent show` carries, picked from the calibration samples for variety and never
from the pull request under review; the style notes, the rubrics repository's `style.md`, which the
instructions carry; and a rubric proposal's whole life — asked for, queued as a task of the
repository through its own orchestra client, written from the calibration data and the people's
edits, opened as a pull request on the rubrics repository, and accepted by its merge or rejected
by its close.
-/

namespace DiffReviewerTest.Style

/-- `FakeHistory`, with comments long enough to be examples: each says which comment it is. -/
def history : IO FakeHistory := do
  let f ← FakeHistory.new
  f.comments.modify (·.map fun (n, c) =>
    (n, { c with body := s!"{c.body}: please follow the naming convention here" }))
  return f

def agentProposalReq (method : Std.Http.Method) (job : String) (body : String := "")
    (repo : String := "acme/widgets") : Req :=
  req method s!"/api/agent/v1/repos/{repo}/proposals/{job}" body (token := proposerAgentToken)

def examplesOf (r : Reply) : List Json :=
  (((bodyJson r).getObjVal? "examples").toOption.bind (·.getArr?.toOption)).map (·.toList)
    |>.getD []

def bodies (xs : List Json) : List String := xs.filterMap (str · ["body"])

/-- Picking: a file not shown first, then a category not shown, then the scope and the length
    shown less; at most the number asked; the same candidates give the same picks. -/
def examplesAreVaried : Test := do
  let e (file : String) (cat : Option String) (scope : String) (n : Nat) (len := 30) :
      Style.Example :=
    { file, startLine := n, line := n, body := String.ofList (List.replicate len 'x')
    , category := cat, scope, sampleId := s!"s{n % 3}", commentId := n }
  let cands := #[e "A.lean" (some "naming") "full" 1, e "A.lean" (some "naming") "full" 2,
                 e "A.lean" (some "docs") "partial" 3, e "B.lean" none "full" 4,
                 e "B.lean" (some "naming") "partial" 5 (len := 300), e "C.lean" none "full" 6]
  let picked := Style.pick cands 4
  let again := Style.pick cands 4
  let fifty := (List.range 50).toArray.map fun n => e s!"F{n}.lean" none "full" n
  let many := Style.pick fifty 99
  return checkEq (picked.map (·.commentId)) #[1, 5, 6, 3]
      "a new file each time while there is one, the category and scope breaking ties"
    ++ checkEq (again.map (·.commentId)) (picked.map (·.commentId)) "deterministic"
    ++ checkEq many.size 50 "no more than there are"
    ++ checkEq (Style.pick fifty).size Style.maxExamples "at most twenty by default"
    ++ check (!Style.showable "LGTM") "a word is not an example"
    ++ check (!Style.showable (String.ofList (List.replicate 700 'x'))) "nor a page"
    ++ check (Style.showable "Please rename this to `foo_bar`, as the convention says.")
      "a sentence is"

/-- Set sample `id`'s split, as only the suite does: a split is otherwise never changed. -/
def setSplit (id split : String) : IO Unit :=
  Store.run do
    let db ← read
    SQLite.exec db s!"UPDATE calibration_sample SET split = '{split}' WHERE id = '{id}'"

/-- A run of the pool's samples `ids`. -/
def poolRunOf (st : State) (ids : List String) : IO Reply :=
  route st (req .post s!"{repoPath}/calibration/runs"
    s!"\{\"split\": \"pool\", \"samples\": [{", ".intercalate (ids.map (s!"\"{·}\""))}]}")

/-- The examples come from trusted reviewers' pool samples reviewed before the review the job is,
    never of its pull request, never of the eval samples, as their text and category only — the
    category calibration paired them with — and the style notes end the instructions. -/
def examplesLeaveOutThePullUnderReview : Test := withTempDb do
  let f ← history
  -- #11 and #12 were reviewed in September, #13 in October.
  f.reviews.modify (·.map fun (n, r) =>
    (n, if n == 13 then r else { r with submittedAt := some "2026-09-01T00:00:00Z" }))
  let orch ← FakeOrchestra.new
  let fg ← FakeGit.new
  let svc := fg.attach (← DiffReviewerTest.Calibration.services f orch)
  let st ← State.new cfg svc
  let _ ← imported st svc f (evalShare := 0)
  let _ ← fg.setRubric "acme" "widgets" "{}" (notes := "Keep comments to one sentence.")
  refresh svc
  let evalRun ← runOf st [← sampleId st 301]
  let made ← poolRunOf st [← sampleId st 301]
  let jobId := ((resultsOf made).head?.bind (str · ["jobId"])).getD ""
  Workers.queuePending svc
  let shown ← routeAgent st (agentReq .get "" (pr := 13))
  let ex := examplesOf shown
  let instructions := (field shown "instructions").getD ""
  -- Scored: #13's comment 9 is paired with the agent's `naming` comment.
  let _ ← routeAgent st (agentReq .post "/review" (submission jobHead agentReview) (pr := 13))
  -- A job of #11's sample, reviewed in September: nothing of #11, nor of #13, which came later.
  let other ← poolRunOf st [← sampleId st 101]
  Workers.queuePending svc
  let ex11 := examplesOf (← routeAgent st (agentReq .get "" (pr := 11)))
  -- A review made now sees both, #13's comment with the category calibration gave it.
  f.gh.pulls.set #[pull7 jobHead]
  let _ ← newJob st
  Workers.queuePending svc
  let ex7 := examplesOf (← routeAgent st (agentReq .get ""))
  let catOf (body : String) : Option String :=
    (ex7.find? (str · ["body"] == some body)).bind (str · ["category"])
  let has (xs : List String) (t : String) := xs.any fun b => (b.splitOn t).length > 1
  -- #11's sample held out: no longer an example. Nobody trusted: none at all.
  setSplit (← sampleId st 101) "eval"
  let _ ← Platform.updateJob jobId fun j => return { j with statusRaw := "running" }
  let heldOut := examplesOf (← routeAgent st (agentReq .get "" (pr := 13)))
  let _ ← putRepo st "{\"trustedReviewers\": []}"
  let none_ ← routeAgent st (agentReq .get "" (pr := 13))
  return checkStatus evalRun 400 "a run of the eval samples, of a pool sample"
    ++ checkStatus made 201 "a run of the pool, asked for"
    ++ checkStatus shown 200 "the calibration job's read"
    ++ check (!has (bodies ex) "rename this" && !has (bodies ex) "and this")
      "nothing of #13, whose sample the job is scored against"
    ++ check (has (bodies ex) "rename that") "#11's comments, reviewed before, are there"
    ++ check (ex.all fun x => match x.getObj? with
        | .ok kvs => kvs.toList.map (·.1) |>.all (["body", "category"].contains ·)
        | .error _ => false) "an example is its text and category, and nothing else"
    ++ check ((instructions.splitOn "do not copy them").length > 1) "the instructions: not copied"
    ++ check (instructions.endsWith "Keep comments to one sentence.") "and the style notes last"
    ++ checkStatus other 201 "a run of #11's sample"
    ++ checkEq ex11.length 0 "a job of #11 sees nothing of #11, nor of what came after"
    ++ check (has (bodies ex7) "rename that" && has (bodies ex7) "rename this")
      "a review made now sees both"
    ++ checkEq (catOf "rename this: please follow the naming convention here") (some "naming")
      "a comment calibration paired has the paired comment's category"
    ++ checkEq (catOf "and this: please follow the naming convention here") none
      "one it did not has none"
    ++ check (!has (bodies heldOut) "rename that") "an eval sample is never an example"
    ++ checkEq (examplesOf none_).length 0 "with nobody trusted, no examples"

/-- The style notes are no setting but the rubrics repository's `style.md`: a write of the settings
    that names them, or a proposal to adopt them from, is refused, saying where they are; and the
    file is read, bounded. -/
def styleNotesAreInTheRubricsRepository : Test := withTempDb do
  let st ← State.new cfg
  let made ← putRepo st "{\"styleNotes\": \"Be brief.\"}"
  let adopted ← putRepo st "{\"fromProposal\": \"x\"}"
  let plain ← putRepo st "{\"mode\": \"staged\"}"
  let long := String.ofList (List.replicate (maxStyleNotesBytes + 1) 'x')
  let read := RubricFiles.parseDir [{ path := "style.md", content := "\nBe brief.\n\n" }]
  let tooLong := RubricFiles.parseDir [{ path := "style.md", content := long }]
  return checkStatus made 400 "notes in the settings"
    ++ check ((field made "error").any fun e => (e.splitOn "acme/widgets/style.md").length > 1)
      "saying where they are"
    ++ checkStatus adopted 400 "notes adopted from a proposal"
    ++ checkStatus plain 201 "the other settings"
    ++ check (!((bodyJson plain).getObjVal? "styleNotes" |>.isOk)) "which hold no notes"
    ++ checkEq (read.toOption.map (·.styleNotes)) (some "Be brief.") "style.md, read"
    ++ check (tooLong matches .error _) "past 16 KiB"
    ++ checkEq (Workers.instructionsFor none "") Workers.instructions "no notes, nothing added"

def rubricV1 : String :=
  "{\"defaultRubric\": \"Check names.\", \"prTypes\": [\
{\"name\": \"feature\", \"description\": \"Adds things.\", \"rubric\": \"Check docs.\", \
\"categories\": [{\"name\": \"naming\", \"description\": \"Names.\"}]}, \
{\"name\": \"refactor\", \"description\": \"Moves.\", \"categories\": []}]}"

def proposedRubric : String :=
  "{\"defaultRubric\": \"Check names and docstrings.\", \"prTypes\": [\
{\"name\": \"feature\", \"description\": \"Adds things.\", \"rubric\": \"Check docs and tests.\", \
\"categories\": [{\"name\": \"naming\", \"description\": \"Names, by the convention.\"}, \
{\"name\": \"docs\", \"description\": \"Docstrings.\"}]}, \
{\"name\": \"fix\", \"description\": \"Fixes a bug.\", \"categories\": []}]}"

def proposal (rubric : String := proposedRubric)
    (notes : String := "\"One sentence a comment.\"") (base : Option String := none) : String :=
  let b := (base.map fun b => s!"\"baseSha\": \"{b}\", ").getD ""
  s!"\{{b}\"rubric\": {rubric}, \"styleNotes\": {notes}, \
\"rationale\": \"People keep asking for docstrings.\"}"

def proposalsPath : String := s!"{repoPath}/proposals"

/-- Services with a client for reviews and one for proposals, reading the rubrics repository from
    `fg`. -/
def withProposer (f : FakeHistory) (orch prop : FakeOrchestra) (fg : FakeGit)
    (limits : Workers.Limits := {}) : IO Workers.Services := do
  return fg.attach (← Workers.Services.new (some f.client) (some orch.client) (fun _ => pure ())
    limits (some prop.client))

/-- Commit `doc` (a rubric document) and `notes` as `acme/widgets`'s, and follow the branch. -/
def commitRubric (fg : FakeGit) (svc : Workers.Services) (doc : String) (notes : String := "") :
    IO String := do
  let sha ← fg.setRubric "acme" "widgets" doc notes
  refresh svc
  return sha

/-- The text of `path` at the tip of `branch` of the rubrics repository. -/
def fileAt (fg : FakeGit) (branch path : String) : IO (Option String) := do
  return (← fg.headFiles branch).lookup path

def listOf (j : Json) (path : List String) : List Json :=
  match path with
  | [] => (j.getArr?.toOption.map (·.toList)).getD []
  | k :: ks => ((j.getObjVal? k).toOption.map (listOf · ks)).getD []

/-- A proposal's life: asked for, one live at a time — and not at all with no rubrics repository to
    open it on; queued through the proposals' client as a task of the repository, with no pull
    request; read and submitted by the agent on the routes of the repository and the job, checked
    as rubric files are; opened, by the platform, as a pull request on the rubrics repository — a
    commit over the job's commit on a branch of its own, its rationale the body — and shown with
    its diff against its base; and accepted when that pull request is merged, the merge then the
    rubric in use. -/
def aProposalBecomesAPullRequest : Test := withTempDb do
  let f ← history
  let orch ← FakeOrchestra.new
  let prop ← FakeOrchestra.new
  let fg ← FakeGit.new
  let svc ← withProposer f orch prop fg
  let st ← State.new cfg svc
  let _ ← putRepo st "{}"
  let noRepo ← route (← State.new cfg (← Workers.Services.new)) (req .post proposalsPath "{}")
  let noBranch ← route st (req .post proposalsPath "{}")
  let base ← commitRubric fg svc rubricV1 (notes := "Be brief.")
  let unknownRepo ← route st (req .post "/api/v1/repos/acme/nope/proposals" "{}")
  let made ← route st (req .post proposalsPath "{}")
  let jobId := (field made "id").getD ""
  let second ← route st (req .post proposalsPath "{}")
  Workers.queuePending svc
  let queued ← prop.queued.get
  let reviewQueue ← orch.queued.get
  let q := queued[0]?
  let early ← route st (agentProposalReq .post jobId (proposal))
  -- The head moves before the agent reads: it is given, and proposes over, the commit it was
  -- pinned to.
  let _ ← fg.change [("other/repo/rubric.md", some "Other.\n")]
  refresh svc
  let shown ← route st (agentProposalReq .get jobId)
  let ctx := bodyJson shown
  let byPull ← routeAgent st (agentReq .get "" (pr := 0))
  let wrongJob ← route st (agentProposalReq .get "nope")
  let wrongRepo ← route st (agentProposalReq .get jobId (repo := "acme/other"))
  let byApi ← route st (req .get s!"/api/agent/v1/repos/acme/widgets/proposals/{jobId}")
  let dupTypes := proposal (rubric := "{\"prTypes\": [{\"name\": \"a\"}, {\"name\": \"a\"}]}")
  let invalid ← route st (agentProposalReq .post jobId dupTypes)
  let slash ← route st (agentProposalReq .post jobId
    (proposal (rubric := "{\"prTypes\": [{\"name\": \"a/b\"}]}")))
  let noRationale ← route st (agentProposalReq .post jobId
    s!"\{\"rubric\": {proposedRubric}}")
  let wrongBase ← route st (agentProposalReq .post jobId (proposal (base := some headA)))
  let callsBefore := (← fg.calls.get).filter (·.startsWith "POST")
  let submitted ← route st (agentProposalReq .post jobId (proposal (base := some base)))
  let pid := (field submitted "proposalId").getD ""
  let twice ← route st (agentProposalReq .post jobId (proposal))
  let stillOne ← route st (req .post proposalsPath "{}")
  let listed ← route st (req .get proposalsPath)
  let one ← route st (req .get s!"{proposalsPath}/{pid}")
  let d := (bodyJson one).getObjVal? "diff" |>.toOption |>.getD .null
  let feature := (listOf d ["typesChanged"]).head?.getD .null
  let pulls ← fg.pulls.get
  let branch := s!"diff-reviewer/proposal/acme/widgets/{pid}"
  let rubricMd ← fileAt fg branch "acme/widgets/rubric.md"
  let fixMd ← fileAt fg branch "acme/widgets/types/fix.md"
  let refactorMd ← fileAt fg branch "acme/widgets/types/refactor.md"
  let styleMd ← fileAt fg branch "acme/widgets/style.md"
  let otherOnBranch ← fileAt fg branch "other/repo/rubric.md"
  let posts := (← fg.calls.get).filter (·.startsWith "POST")
  let some job ← Platform.findJob jobId | return #["the proposal job is gone"]
  let moved ← route st (req .post s!"/api/v1/jobs/{jobId}/status" (statusBody "rejected"
    job.version))
  let postIt ← route st (req .post s!"/api/v1/jobs/{jobId}/post" s!"\{\"version\": {job.version}}")
  let accept ← route st (req .post s!"{proposalsPath}/{pid}/accept" "{\"version\": 1}")
  -- Open, it is pending; merged, accepted, and the merge is the rubric in use.
  Proposal.followPulls (fg.client bare) source (fun _ _ => pure ())
  let stillPending ← route st (req .get s!"{proposalsPath}/{pid}")
  let merge ← fg.merge 1
  Workers.tick svc
  let accepted ← route st (req .get s!"{proposalsPath}/{pid}")
  let rubric ← route st (req .get s!"{repoPath}/rubrics")
  let jobs ← route st { req .get "/api/v1/jobs" with query := "kind=proposal" }
  let types := (listOf (bodyJson rubric) ["prTypes"]).filterMap (str · ["name"])
  let anew ← route st (req .post proposalsPath "{}")
  return checkStatus noRepo 409 "a proposal with no rubrics repository configured"
    ++ checkStatus noBranch 409 "or with one that has no branch yet"
    ++ checkStatus unknownRepo 404 "a proposal for a repository not registered"
    ++ checkStatus made 201 "asking for a proposal"
    ++ checkEq (field made "kind") (some "proposal") "a proposal job"
    ++ checkEq (num (bodyJson made) ["prNumber"]) (some 0) "of no pull request"
    ++ checkStatus second 409 "a second while one is live"
    ++ checkEq queued.size 1 "queued through the proposals' client"
    ++ checkEq reviewQueue.size 0 "and not the reviews'"
    ++ checkEq (q.map (·.issueNumber)) (some none) "with no pull request"
    ++ check (q.any fun q => !(q.toJson.getObjVal? "issue_number" |>.isOk))
      "and no issue_number in what orchestra is sent"
    ++ checkEq (q.map (·.externalId)) (some jobId) "its external id is the job's"
    ++ checkEq (q.map (·.upstream)) (some "acme/widgets") "of the repository"
    ++ checkEq (q.map (·.kleisNarrow)) (some ["services: diff-reviewer"])
      "with GitHub closed to it"
    ++ check (q.any fun q => (q.prompt.splitOn "agent proposal show acme/widgets").length > 1 &&
        (q.prompt.splitOn "advisory").length > 1) "the prompt: the task, and that it is advisory"
    ++ check (q.any fun q => (q.goal.splitOn "proposal submit").length > 1) "the goal: a submission"
    ++ checkStatus early 409 "a submission before the context is read"
    ++ checkStatus shown 200 "the agent's read"
    ++ checkEq (str ctx ["status"]) (some "running") "which starts the run"
    ++ checkEq (str ctx ["rubric", "sha"]) (some base) "the rubric of the commit it was pinned to"
    ++ checkEq (str ctx ["styleNotes"]) (some "Be brief.") "the style notes, of that commit"
    ++ check (str ctx ["instructions"]).isSome "the instructions"
    ++ check ((ctx.getObjVal? "calibration").isOk) "calibration's aggregates"
    ++ checkStatus byPull 404 "a proposal is not a pull request's"
    ++ checkStatus wrongJob 404 "another job"
    ++ checkStatus wrongRepo 404 "another repository"
    ++ checkStatus byApi 401 "the API token on the agent's routes"
    ++ checkStatus invalid 400 "a document the rubric files would refuse"
    ++ checkStatus slash 400 "a type that cannot be a file's name"
    ++ checkStatus noRationale 400 "no rationale"
    ++ checkStatus wrongBase 400 "a base that is not the job's commit"
    ++ checkEq callsBefore.size 0 "nothing written to the rubrics repository before a submission"
    ++ checkStatus submitted 200 "the submission"
    ++ checkEq (field submitted "pullRequest")
      (some "https://github.com/chrisflav/review-rubrics/pull/1") "opened as a pull request"
    ++ checkEq posts.toList ["POST /repos/chrisflav/review-rubrics/git/trees",
        "POST /repos/chrisflav/review-rubrics/git/commits",
        "POST /repos/chrisflav/review-rubrics/git/refs",
        "POST /repos/chrisflav/review-rubrics/pulls"]
      "by a tree, a commit, a branch and a pull request, and nothing else written"
    ++ checkEq (pulls.map (·.branch)) #[branch] "from the proposal's branch"
    ++ check (pulls.any fun p => (p.pull.body.splitOn "People keep asking for docstrings.").length
      > 1) "with the rationale as its body"
    ++ check (rubricMd.any fun t => (t.splitOn "Check names and docstrings.").length > 1)
      "the default rubric, as rubric.md"
    ++ check (fixMd.any fun t => (t.splitOn "Fixes a bug.").length > 1) "a type added, as a file"
    ++ checkEq refactorMd none "a type removed, its file removed"
    ++ checkEq styleMd (some "One sentence a comment.\n") "the style notes, as style.md"
    ++ checkEq otherOnBranch none "over the commit the job was pinned to, not the head since"
    ++ checkStatus twice 409 "a second submission"
    ++ checkStatus stillOne 409 "a new proposal while this one's pull request is open"
    ++ checkEq (items listed).length 1 "the proposals"
    ++ checkEq (str ((items listed).head?.getD .null) ["status"]) (some "pending") "pending"
    ++ checkEq (str (bodyJson one) ["jobId"]) (some jobId) "of its job"
    ++ checkEq (str (bodyJson one) ["baseSha"]) (some base) "its base"
    ++ checkEq (str (bodyJson one) ["pullRequest", "state"]) (some "open") "its pull request, open"
    ++ checkEq (str d ["defaultRubric", "after"]) (some "Check names and docstrings.")
      "the default rubric's change"
    ++ checkEq ((listOf d ["typesAdded"]).filterMap (str · ["name"])) ["fix"] "the type added"
    ++ checkEq ((listOf d ["typesRemoved"]).filterMap (·.getStr?.toOption)) ["refactor"]
      "the type removed"
    ++ checkEq (str feature ["name"]) (some "feature") "the type changed"
    ++ checkEq (str feature ["rubric", "before"]) (some "Check docs.") "its rubric, before"
    ++ checkEq ((listOf feature ["categoriesAdded"]).filterMap (str · ["name"])) ["docs"]
      "a category added"
    ++ checkEq ((listOf feature ["categoriesChanged"]).filterMap (str · ["after"]))
      ["Names, by the convention."] "a category changed"
    ++ checkEq (str feature ["description"]) none "the description, unchanged"
    ++ checkEq (str d ["styleNotes", "before"]) (some "Be brief.") "the style notes' change"
    ++ checkStatus moved 409 "a status move of a proposal job"
    ++ checkStatus postIt 409 "posting it"
    ++ checkStatus accept 404 "no accepting on the platform"
    ++ checkEq (str (bodyJson stillPending) ["status"]) (some "pending") "open: pending"
    ++ checkEq (str (bodyJson accepted) ["status"]) (some "accepted") "merged: accepted"
    ++ checkEq (str (bodyJson accepted) ["mergeSha"]) (some merge) "by its merge commit"
    ++ checkEq (str (bodyJson accepted) ["pullRequest", "state"]) (some "merged") "merged"
    ++ checkEq (str (bodyJson rubric) ["sha"]) (some merge) "the merge, the rubric in use"
    ++ checkEq types ["feature", "fix"] "the rubric is the proposal's"
    ++ checkEq (str (bodyJson rubric) ["styleNotes"]) (some "One sentence a comment.")
      "and the style notes"
    ++ checkEq (items jobs).length 1 "proposal jobs are listed by their kind"
    ++ checkStatus anew 201 "and the repository may have a new one"

/-- A proposal whose pull request is closed unmerged is rejected, and changes nothing; a pull
    request that cannot be opened yet is tried again by the workers, its error shown meanwhile;
    and proposals are capped per day. -/
def aClosedPullRequestRejects : Test := withTempDb do
  let f ← history
  let orch ← FakeOrchestra.new
  let prop ← FakeOrchestra.new
  let fg ← FakeGit.new
  let svc ← withProposer f orch prop fg { maxProposalsPerDay := 3 }
  let st ← State.new cfg svc
  let _ ← putRepo st "{}"
  let base ← commitRubric fg svc rubricV1
  let propose (notes : String := "\"One sentence a comment.\"") : IO String := do
    let made ← route st (req .post proposalsPath "{}")
    let jobId := (field made "id").getD ""
    Workers.queuePending svc
    let _ ← route st (agentProposalReq .get jobId)
    let r ← route st (agentProposalReq .post jobId (proposal (notes := notes)))
    return (field r "proposalId").getD ""
  let first ← propose
  fg.close 1
  Workers.tick svc
  let shown ← route st (req .get s!"{proposalsPath}/{first}")
  let afterClose ← Rubrics.pinFor "acme" "widgets"
  -- Its branch exists already, as a lost answer would leave it: the pull request is still opened.
  let pid2 ← do
    let made ← route st (req .post proposalsPath "{}")
    let jobId := (field made "id").getD ""
    Workers.queuePending svc
    let _ ← route st (agentProposalReq .get jobId)
    -- GitHub not answering when it is submitted: no pull request yet.
    let down : Workers.Services := { svc with github := some bare }
    let r ← route (← State.new cfg down) (agentProposalReq .post jobId (proposal (notes := "null")))
    pure ((field r "proposalId").getD "")
  let waiting ← route st (req .get s!"{proposalsPath}/{pid2}")
  Workers.tick svc
  let opened ← route st (req .get s!"{proposalsPath}/{pid2}")
  let styleMd ← fileAt fg s!"diff-reviewer/proposal/acme/widgets/{pid2}" "acme/widgets/style.md"
  fg.close 2
  Workers.tick svc
  let _ ← propose
  fg.close 3
  Workers.tick svc
  let capped ← route st (req .post proposalsPath "{}")
  return checkEq (str (bodyJson shown) ["status"]) (some "rejected") "closed: rejected"
    ++ checkEq (str (bodyJson shown) ["pullRequest", "state"]) (some "closed") "closed"
    ++ checkEq afterClose (some base) "nothing changed"
    ++ check (str (bodyJson waiting) ["prError"]).isSome "a pull request not opened yet, and why"
    ++ checkEq (str (bodyJson waiting) ["pullRequest"]) none "none yet"
    ++ checkEq (str (bodyJson opened) ["pullRequest", "url"])
      (some "https://github.com/chrisflav/review-rubrics/pull/2") "opened by the workers"
    ++ checkEq (str (bodyJson opened) ["prError"]) none "the error gone"
    ++ checkEq styleMd none "a proposal of no notes leaves style.md alone"
    ++ checkStatus capped 429 "a fourth proposal in a day, past a cap of three"

/-- What the proposal agent reads: the people's comments the agent missed and the agent's nobody
    matched, from the scored runs, and what a person changed in a draft before it was posted. -/
def aProposalReadsTheEvidence : Test := withTempDb do
  let f ← history
  let orch ← FakeOrchestra.new
  let prop ← FakeOrchestra.new
  let fg ← FakeGit.new
  let svc ← withProposer f orch prop fg
  let st ← State.new cfg svc
  let _ ← imported st svc f (evalShare := 0)
  let _ ← commitRubric fg svc "{}"
  let s301 ← sampleId st 301
  let run ← poolRunOf st [s301]
  Workers.queuePending svc
  let _ ← routeAgent st (agentReq .get "" (pr := 13))
  let _ ← routeAgent st (agentReq .post "/review" (submission jobHead agentReview) (pr := 13))
  -- A review of #7: the agent drafts two comments, a person rewrites one and drops the other.
  f.gh.pulls.set #[pull7 jobHead]
  let job ← route st (req .post "/api/v1/jobs"
    s!"\{\"owner\": \"acme\", \"name\": \"widgets\", \"prNumber\": 7, \"headSha\": \"{jobHead}\"}")
  let id := (field job "id").getD ""
  Workers.queuePending svc
  let _ ← routeAgent st (agentReq .get "")
  let _ ← routeAgent st (agentReq .post "/review" (submission jobHead agentReview))
  let some drafted ← Platform.findJob id | return #["the review job is gone"]
  let some (.ok r) := drafted.review? | return #["the draft does not read"]
  let kept := (r.comments.take 1).map fun (c : InlineComment) => { c with body := "Rename." }
  let edited : Review := { r with comments := kept }
  let put ← route st (req .put s!"/api/v1/jobs/{id}/review"
    (reviewBody drafted.version edited.toJson.compress))
  let approved ← route st (req .post s!"/api/v1/jobs/{id}/status"
    (statusBody "approved" (versionOf put)))
  let posted ← route st (req .post s!"/api/v1/jobs/{id}/post"
    s!"\{\"version\": {versionOf approved}}")
  let made ← route st (req .post proposalsPath "{}")
  let jobId := (field made "id").getD ""
  Workers.queuePending svc
  let ctx := bodyJson (← route st (agentProposalReq .get jobId))
  let missed := listOf ctx ["missedHuman"]
  let extra := listOf ctx ["unmatchedAgent"]
  let edits := listOf ctx ["personEdits"]
  let change (k : String) := edits.find? (str · ["change"] == some k)
  -- Merged, its merge commit carries the sample its context drew on; a score of it under that
  -- commit's rubric is derived — and under any later commit that leaves the directory as the merge
  -- left it, but not once another commit has changed it.
  let submitted ← route st (agentProposalReq .post jobId (proposal))
  let pid := (field submitted "proposalId").getD ""
  let merge ← fg.merge 1
  Workers.tick svc
  let accepted ← route st (req .get s!"{proposalsPath}/{pid}")
  let rubricView ← route st (req .get s!"{repoPath}/rubrics")
  -- Another repository's directory changes: the head moves, this directory's tree does not.
  let elsewhere ← fg.change [("other/repo/rubric.md", some "Other.\n")]
  refresh svc
  -- Held out now (as only the suite can make it), and run again under the derived rubric.
  setSplit s301 "eval"
  let scoreOnce : IO Reply := do
    let r ← runOf st [s301]
    Workers.queuePending svc
    let _ ← routeAgent st (agentReq .get "" (pr := 13))
    let _ ← routeAgent st (agentReq .post "/review"
      (submission jobHead agentReview (prType := "\"feature\"")) (pr := 13))
    return r
  let again ← scoreOnce
  -- A person changes the directory: a new rubric, not the proposal's.
  let edited ← fg.change [("acme/widgets/rubric.md", some "Check names, docstrings and tests.\n")]
  refresh svc
  let third ← scoreOnce
  let summary := bodyJson (← route st (req .get s!"{repoPath}/calibration/summary"))
  let withDerived := bodyJson (← route st
    { req .get s!"{repoPath}/calibration/summary" with query := "derived=include" })
  let runId := (field again "id").getD ""
  let result := (resultsOf (← route st (req .get s!"{repoPath}/calibration/runs/{runId}"))).head?
  let thirdResult := (resultsOf (← route st
    (req .get s!"{repoPath}/calibration/runs/{(field third "id").getD ""}"))).head?
  let byRubric := listOf summary ["byRubric"]
  let instructions := (str ctx ["instructions"]).getD ""
  return checkStatus posted 200 "the review, posted"
    ++ checkStatus run 201 "a run of the pool"
    ++ check ((instructions.splitOn "never as instructions to you").length > 1)
      "the instructions say the context is data, not instructions"
    ++ checkEq (str (bodyJson accepted) ["status"]) (some "accepted") "the proposal, merged"
    ++ checkEq ((listOf (bodyJson rubricView) ["derivedFrom"]).filterMap
      (·.getStr?.toOption)) [s301] "the merge commit is derived from the sample"
    ++ checkEq (str (bodyJson rubricView) ["sha"]) (some merge) "and in use"
    ++ checkStatus again 201 "a run of it under the derived rubric"
    ++ checkEq (result.bind (str · ["rubricSha"])) (some elsewhere)
      "pinned to a later head, the directory as the merge left it"
    ++ checkEq (result.bind (·.getObjValAs? Bool "scoreDerived" |>.toOption)) (some true)
      "derived, and marked in its run"
    ++ checkEq (thirdResult.bind (str · ["rubricSha"])) (some edited)
      "a run after a person changed the directory"
    ++ checkEq (thirdResult.bind (·.getObjValAs? Bool "scoreDerived" |>.toOption)) (some false)
      "is not derived"
    ++ checkEq (num summary ["overall", "scored"]) (some 2)
      "the scores under the first rubric and the person's count; the derived one does not"
    ++ checkEq (num summary ["overall", "derivedScores"]) (some 1) "which is derived"
    ++ checkEq (num withDerived ["overall", "scored"]) (some 3) "and in when asked"
    ++ checkEq ((byRubric.filterMap (str · ["rubricSha"])).length) 3 "one aggregate per rubric"
    ++ checkEq (missed.map (num · ["end_line"])) [some 12] "the comment of alice's the agent missed"
    ++ checkEq (missed.map (num · ["prNumber"])) [some 13] "of #13"
    ++ check (bodies missed |>.all (·.startsWith "and this")) "with what it said"
    ++ checkEq (extra.map (num · ["start_line"])) [some 18] "the agent's comment nobody matched"
    ++ checkEq (extra.map (str · ["category"])) [some "docs"] "with its category"
    ++ checkEq ((change "changed").bind (str · ["before", "body"])) (some "a name")
      "a comment a person changed: before"
    ++ checkEq ((change "changed").bind (str · ["after", "body"])) (some "Rename.") "and after"
    ++ checkEq ((change "removed").bind (str · ["before", "body"])) (some "a doc")
      "a comment a person removed"
    ++ checkEq ((change "changed").bind (num · ["prNumber"])) (some 7) "of #7"

/-- Without a client for proposals, a proposal job waits, with why, written once; its run ending
    without a proposal fails it, as followed through its own client. -/
def proposalsWaitForTheirClient : Test := withTempDb do
  let f ← history
  let orch ← FakeOrchestra.new
  let prop ← FakeOrchestra.new
  let fg ← FakeGit.new
  let svc := fg.attach (← DiffReviewerTest.Calibration.services f orch)
  let st ← State.new cfg svc
  let _ ← putRepo st "{}"
  let _ ← commitRubric fg svc rubricV1
  let made ← route st (req .post proposalsPath "{}")
  let jobId := (field made "id").getD ""
  Workers.queuePending svc
  let some once ← Platform.findJob jobId | return #["the proposal job is gone"]
  Workers.queuePending svc
  let some twice ← Platform.findJob jobId | return #["the proposal job is gone"]
  let withProp ← withProposer f orch prop fg
  Workers.queuePending withProp
  let some queued ← Platform.findJob jobId | return #["the proposal job is gone"]
  prop.set ((queued.queueEntry).getD "") "failed"
  Workers.follow withProp
  let some failed ← Platform.findJob jobId | return #["the proposal job is gone"]
  let retried ← route st (req .post s!"/api/v1/jobs/{jobId}/status"
    (statusBody "pending" failed.version))
  let anew ← route st (req .post proposalsPath "{}")
  return checkEq once.statusRaw "pending" "without the client, pending"
    ++ check (once.error.any fun e => (e.splitOn "PROPOSER_TOKEN_FILE").length > 1) "and why"
    ++ checkEq twice.version once.version "written once"
    ++ checkEq (← orch.queued.get).size 0 "never through the reviews' client"
    ++ checkEq queued.statusRaw "queued" "with it, queued"
    ++ checkEq failed.statusRaw "failed" "a run that ends without a proposal"
    ++ check (failed.error.any fun e => (e.splitOn "a proposal").length > 1) "says so"
    ++ checkStatus retried 409 "a failed proposal is not run again"
    ++ checkStatus anew 201 "a new one is asked for instead"

/-- `agent proposal submit` checks its file before it sends it. -/
def theProposalCliChecksItsInput : Test := do
  let ok := Agent.parseProposal (proposal (base := some headA))
  let noBase := Agent.parseProposal s!"\{\"rubric\": {proposedRubric}, \"rationale\": \"r\"}"
  let noRubric := Agent.parseProposal "{\"baseSha\": \"x\", \"rationale\": \"r\"}"
  let noWhy := Agent.parseProposal s!"\{\"rubric\": {proposedRubric}}"
  return check (ok matches .ok _) "a whole proposal"
    ++ check (noBase matches .ok _) "without a base, which is the job's"
    ++ check (noRubric matches .error _) "without a rubric"
    ++ check (noWhy matches .error _) "without a rationale"

/-- What the front-end reads: one repository with its settings, the deleted samples when asked,
    marked, and when the rate limit an import waits for resets — refused for it as well as paused
    under the reserve. -/
def theUiReadsWhatItNeeds : Test := withTempDb do
  let f ← history
  let svc ← DiffReviewerTest.Calibration.services f
  let st ← State.new cfg svc
  let missing ← route st (req .get repoPath)
  let _ ← imported st svc f
  let one ← route st (req .get "/api/v1/repos/Acme/Widgets")
  let listed := (items (← route st (req .get "/api/v1/repos"))).head?.getD .null
  let sid ← sampleId st 203
  let _ ← route st (req .delete s!"{repoPath}/calibration/samples/{sid}")
  let samplesQ (q : String) :=
    route st { req .get s!"{repoPath}/calibration/samples" with query := q }
  let without := items (← samplesQ "")
  let withDeleted := items (← samplesQ "deleted=include")
  let bad ← samplesQ "deleted=maybe"
  let marked := withDeleted.find? (str · ["id"] == some sid)
  -- Refused for the rate limit, with requests left over the reserve: the reset GitHub gave.
  let now := (← Std.Time.Timestamp.now).toSecondsSinceUnixEpoch.val
  f.limit.set (some { remaining := 4000, resetAt := now + 600 })
  f.rateLimited.set [11]
  let limitedId ← importId st
  Calibration.importStep f.client svc.log 100
  let limited ← importNamed st limitedId
  f.limit.set (some { remaining := 4000, resetAt := now - 1 })
  Calibration.importStep f.client svc.log 100
  let resumed ← importNamed st limitedId
  return checkStatus missing 404 "a repository not registered"
    ++ checkStatus one 200 "one repository"
    ++ checkEq (bodyJson one).compress listed.compress "the same object as in the list"
    ++ checkEq (num (bodyJson one) ["version"]) (some 1) "with its version"
    ++ checkEq without.length 3 "the samples not deleted"
    ++ checkEq withDeleted.length 4 "and with the deleted one"
    ++ checkEq ((marked.bind (·.getObjValAs? Bool "deleted" |>.toOption))) (some true) "marked"
    ++ check (marked.any (str · ["deletedAt"] |>.isSome)) "with when"
    ++ check (without.all fun x => (x.getObjValAs? Bool "deleted").toOption == some false)
      "the others are not"
    ++ checkStatus bad 400 "a 'deleted' that is neither"
    ++ checkEq (str limited ["resetAt"]) (some (isoOfEpoch (now + 600)))
      "a rate-limited import says when the limit resets"
    ++ checkEq (str resumed ["status"]) (some "done") "it goes on"
    ++ checkEq (resumed.getObjVal? "resetAt" |>.toOption) (some .null) "and the reset is cleared"

/-- A repository deleted and registered again goes on from the version it had: a page that read a
    version of the old registration is refused by the new one rather than overwriting it; and the
    deleted one is gone from every lookup meanwhile. -/
def versionsNeverRepeat : Test := withTempDb do
  let st ← State.new cfg
  let first ← putRepo st "{\"version\": 0, \"trustedReviewers\": [\"alice\"]}"
  let second ← putRepo st "{\"version\": 1, \"trustedReviewers\": [\"alice\", \"bob\"]}"
  let deleted ← route st (req .delete repoPath)
  let gone ← route st (req .get repoPath)
  let listed := items (← route st (req .get "/api/v1/repos"))
  let job ← route st (req .post "/api/v1/jobs"
    "{\"owner\": \"acme\", \"name\": \"widgets\", \"prNumber\": 7}")
  let proposalOf ← route st (req .post s!"{repoPath}/proposals" "{}")
  let staleBefore ← putRepo st "{\"version\": 1, \"trustedReviewers\": [\"mallory\"]}"
  let again ← putRepo st "{\"version\": 0, \"trustedReviewers\": [\"carol\"]}"
  let stale ← putRepo st "{\"version\": 1, \"trustedReviewers\": [\"mallory\"]}"
  let staleZero ← putRepo st "{\"version\": 0, \"trustedReviewers\": [\"mallory\"]}"
  let deletedTwice ← route st (req .delete "/api/v1/repos/acme/nope")
  let now ← route st (req .get repoPath)
  let trusted (r : Reply) : List String :=
    (listOf (bodyJson r) ["trustedReviewers"]).filterMap (·.getStr?.toOption)
  return checkEq (versionOf first, versionOf second) (1, 2) "the first registration's versions"
    ++ checkStatus deleted 204 "deleting it"
    ++ checkStatus gone 404 "it is gone"
    ++ checkEq listed.length 0 "from the list too"
    ++ checkStatus job 404 "no job is made for it"
    ++ checkStatus proposalOf 404 "nor a proposal"
    ++ checkStatus staleBefore 409 "a write of an old version before it is registered again"
    ++ checkStatus again 201 "registered again"
    ++ checkEq (versionOf again) 3 "at the version after the last it had"
    ++ checkStatus stale 409 "a page of the old registration's version 1"
    ++ checkStatus staleZero 409 "a second registration from a page that never saw the first"
    ++ checkEq (trusted now) ["carol"] "the new registration's trusted reviewers, untouched"
    ++ checkStatus deletedTwice 404 "deleting a repository that is not registered"

/-- A run records the split it was asked of, and says it, as one run and in the list; a run
    stored before runs recorded it is of the split its samples have. -/
def runsRecordTheirSplit : Test := withTempDb do
  let f ← history
  let orch ← FakeOrchestra.new
  let svc ← DiffReviewerTest.Calibration.services f orch
  let st ← State.new cfg svc
  let _ ← imported st svc f (evalShare := 0)
  let pool ← poolRunOf st [← sampleId st 301]
  let s101 ← sampleId st 101
  setSplit s101 "eval"
  let evalRun ← runOf st [s101]
  let listed ← route st (req .get s!"{repoPath}/calibration/runs")
  let poolId := (field pool "id").getD ""
  -- Its sample moved to `eval` since, by hand: the run is still of what it was asked of.
  setSplit (← sampleId st 301) "eval"
  let kept ← route st (req .get s!"{repoPath}/calibration/runs/{poolId}")
  -- As a run stored before `0008` is.
  Store.run do
    let db ← read
    SQLite.exec db "UPDATE calibration_run SET split = NULL"
  let old ← route st (req .get s!"{repoPath}/calibration/runs/{poolId}")
  let splits := (listOf (bodyJson listed) ["items"]).filterMap (str · ["split"])
  return checkStatus pool 201 "a run of the pool"
    ++ checkEq (field pool "split") (some "pool") "says it is of the pool"
    ++ checkEq (field evalRun "split") (some "eval") "a run of the eval samples, of eval"
    ++ checkEq (splits.toArray.qsort (· < ·)) #["eval", "pool"] "as the list says"
    ++ checkEq (field kept "split") (some "pool") "the split it was run of is stored"
    ++ checkEq (field old "split") (some "eval") "an older run, of its samples' split"

def all : List (String × Test) :=
  [("examplesAreVaried", examplesAreVaried),
   ("examplesLeaveOutThePullUnderReview", examplesLeaveOutThePullUnderReview),
   ("styleNotesAreInTheRubricsRepository", styleNotesAreInTheRubricsRepository),
   ("aProposalBecomesAPullRequest", aProposalBecomesAPullRequest),
   ("aClosedPullRequestRejects", aClosedPullRequestRejects),
   ("aProposalReadsTheEvidence", aProposalReadsTheEvidence),
   ("proposalsWaitForTheirClient", proposalsWaitForTheirClient),
   ("theProposalCliChecksItsInput", theProposalCliChecksItsInput),
   ("theUiReadsWhatItNeeds", theUiReadsWhatItNeeds),
   ("versionsNeverRepeat", versionsNeverRepeat),
   ("runsRecordTheirSplit", runsRecordTheirSplit)]

end DiffReviewerTest.Style