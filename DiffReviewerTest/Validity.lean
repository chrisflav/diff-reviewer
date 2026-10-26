import DiffReviewer
import DiffReviewerTest.Basic
import DiffReviewerTest.Server
import DiffReviewerTest.Workers
import DiffReviewerTest.Calibration
import DiffReviewerTest.Style

open Lean (Json)
open DiffReviewer
open DiffReviewer.Server
open DiffReviewerTest.Server
open DiffReviewerTest.Workers
open DiffReviewerTest.Calibration
open DiffReviewerTest.Style

/-!
# What keeps calibration a measurement

The held-out split, fixed once made; the platform's own posts kept out of the samples; a proposal
held to the rubric's own fields, cancelled when a person says so, and given its context bounded;
and the platform's credentials on orchestra kept apart from its others.
-/

namespace DiffReviewerTest.Validity

/-- A sample's split is a stable hash of its pull request against the share, stored once; a later
    sample of a pull request takes its split; a share changed later splits only the pull requests
    imported after it. -/
def splitsAreStableAndStored : Test := withTempDb do
  let evals := ((List.range 1000).filter fun n =>
    Calibration.splitOf "acme" "widgets" n 50 == "eval").length
  let f ← history
  let svc ← DiffReviewerTest.Calibration.services f
  let st ← State.new cfg svc
  let tooMuch ← putRepo st "{\"evalShare\": 101}"
  let _ ← imported st svc f (evalShare := 0)
  let before ← samples st
  let changed ← putRepo st "{\"evalShare\": 100}"
  -- A later round of #12, and a new pull request #14.
  f.reviews.modify (· ++ #[(12, review 205 "alice" "COMMENTED" "Also." headA),
                           (14, review 401 "alice" "COMMENTED" "New." headA)])
  f.closed.modify (·.push { number := 14, title := "Pull 14", body := "", headSha := headA
                          , baseSha := base, state := "closed" })
  let _ ← importId st
  Calibration.importStep f.client svc.log 100
  let after ← samples st
  let splitOf (xs : List Json) (rid : Nat) : Option String :=
    (xs.find? (nats · "reviewIds" |>.contains rid)).bind (str · ["split"])
  return checkEq (Calibration.splitOf "acme" "widgets" 7 37)
      (Calibration.splitOf "acme" "widgets" 7 37) "the same group, the same split"
    ++ checkEq (Calibration.splitOf "acme" "widgets" 7 0) "pool" "a share of 0"
    ++ checkEq (Calibration.splitOf "acme" "widgets" 7 100) "eval" "a share of 100"
    ++ check (400 ≤ evals && evals ≤ 600) s!"about half held out at 50: {evals} of 1000"
    ++ checkStatus tooMuch 400 "a share past 100"
    ++ check (before.all (str · ["split"] == some "pool")) "imported at 0: all of the pool"
    ++ checkEq (num (bodyJson changed) ["evalShare"]) (some 100) "the share, a setting"
    ++ checkEq (splitOf after 101) (some "pool") "a split once made does not change"
    ++ checkEq (splitOf after 205) (some "pool")
      "a later sample of a pull request with a split takes that split"
    ++ checkEq (splitOf after 401) (some "eval") "a new pull request takes the new share"

/-- The reviews the platform posted are not samples: by the id GitHub gave a job's post, or by the
    marker in their body; they are counted as `ownPosts`. -/
def ownPostsAreNotSamples : Test := withTempDb do
  let f ← history
  let svc ← DiffReviewerTest.Calibration.services f
  let st ← State.new cfg svc
  let _ ← putRepo st "{\"trustedReviewers\": [\"alice\"]}"
  let some repo ← Platform.findRepo "acme" "widgets" | return #["the repository is gone"]
  let job ← Platform.createJob repo 12 (some headB)
  let _ ← Platform.updateJob job.id fun j =>
    return { j with statusRaw := "posted"
                    postedReview := some "{\"id\": 207, \"url\": \"u\", \"body\": \"b\"}" }
  let marked := "Fine.\n\n<!-- diff-reviewer job x -->"
  f.reviews.modify (· ++ #[(12, review 206 "alice" "COMMENTED" marked headB),
                           (12, review 207 "alice" "APPROVED" "Fine, edited on GitHub." headB)])
  let id ← importId st
  Calibration.importStep f.client svc.log 100
  let done ← importNamed st id
  let all ← samples st
  let reviewIds := all.flatMap (nats · "reviewIds")
  return checkEq (num done ["stats", "ownPosts"]) (some 2) "two of the platform's posts"
    ++ check (!reviewIds.contains 206 && !reviewIds.contains 207) "in no sample"
    ++ check (reviewIds.contains 201) "while alice's own review of the commit is"

/-- A proposal's document may carry no field a rubric does not have, at any depth. -/
def proposalsHaveNoUnknownFields : Test := do
  let parse (doc : String) := Proposal.Submission.ofJson
    ((Json.parse (proposal 1 (rubric := doc))).toOption.getD .null)
  let top := parse "{\"defaultRubric\": \"x\", \"note\": 1}"
  let inType := parse "{\"prTypes\": [{\"name\": \"a\", \"weight\": 2}]}"
  let inCategory := parse "{\"prTypes\": [{\"name\": \"a\", \"categories\": \
[{\"name\": \"c\", \"colour\": \"red\"}]}]}"
  let says (r : Except String Proposal.Submission) (t : String) : Bool :=
    match r with
    | .error e => (e.splitOn t).length > 1
    | .ok _ => false
  return check (says top "note") "on the document"
    ++ check (says inType "weight") "on a type"
    ++ check (says inCategory "colour") "on a category"
    ++ check ((parse proposedRubric) matches .ok _) "a document of the rubric's fields"

/-- A person cancels a live proposal job: it fails, and its orchestra run is cancelled through the
    proposals' client; a new one may then be asked for. -/
def proposalsAreCancelled : Test := withTempDb do
  let f ← history
  let orch ← FakeOrchestra.new
  let prop ← FakeOrchestra.new
  let svc ← withProposer f orch prop
  let st ← State.new cfg svc
  let _ ← putRepo st "{}"
  let made ← route st (req .post proposalsPath "{}")
  let jobId := (field made "id").getD ""
  Workers.queuePending svc
  let cancel (id : String) := route st (req .post s!"{proposalsPath}/jobs/{id}/cancel" "{}")
  let cancelled ← cancel jobId
  let twice ← cancel jobId
  let review ← newJob st
  let notProposal ← cancel ((field review "id").getD "")
  let anew ← route st (req .post proposalsPath "{}")
  return checkStatus cancelled 200 "cancelling it"
    ++ checkEq (field cancelled "status") (some "failed") "it is failed"
    ++ checkEq (← prop.cancelled.get).size 1 "its run, cancelled through the proposals' client"
    ++ checkEq (← orch.cancelled.get).size 0 "and not the reviews'"
    ++ checkStatus twice 409 "cancelling it again"
    ++ checkStatus notProposal 404 "a review job is not a proposal's to cancel"
    ++ checkStatus anew 201 "a new one, asked for after"

/-- The context's texts are cut at 2 KiB, on a character boundary. -/
def contextTextsAreBounded : Test := do
  let long := String.ofList (List.replicate 3000 'x')
  let wide := String.ofList (List.replicate 1000 'ä')
  let (cut, was) := Proposal.truncate long
  let (cutWide, _) := Proposal.truncate wide
  let (short, wasShort) := Proposal.truncate "short"
  return checkEq cut.utf8ByteSize Proposal.maxContextBodyBytes "cut to 2 KiB"
    ++ check was "and marked"
    ++ check (cutWide.utf8ByteSize ≤ Proposal.maxContextBodyBytes && cutWide.all (· == 'ä'))
      "never inside a character"
    ++ check (short == "short" && !wasShort) "a short text as it is"

/-- The proposals' token on orchestra is none of the platform's other credentials. -/
def theProposerTokenIsChecked : Test := do
  let orchestraToken := "orch-0123456789abcdef0123456789abcdef"
  let ok : Config := { cfg with orchestraToken := some orchestraToken
                                proposerToken := some "prop-0123456789abcdef0123456789abcdef" }
  return check (ok.check matches .ok ()) "a token of its own"
    ++ check (({ ok with proposerToken := some orchestraToken } : Config).check matches .error _)
      "the reviews' orchestra token"
    ++ check (({ ok with proposerToken := some apiToken } : Config).check matches .error _)
      "the API token"
    ++ check (({ ok with proposerToken := some agentToken } : Config).check matches .error _)
      "the agent token"
    ++ check (({ ok with proposerToken := some "short" } : Config).check matches .error _)
      "a short one"

/-- Each token is one credential: the proposals' agent token reaches a proposal's agent routes
    and nothing else, the agent token everything but them. -/
def theAgentTokensStandApart : Test := withTempDb do
  let st ← State.new cfg
  let _ ← putRepo st "{}"
  let proposalPath := "/api/agent/v1/repos/acme/widgets/proposals/nope"
  let byAgent ← route st (req .get proposalPath (token := agentToken))
  let byProposer ← route st (req .get proposalPath (token := proposerAgentToken))
  let pullByProposer ← route st (req .get "/api/agent/v1/repos/acme/widgets/pulls/7"
    (token := proposerAgentToken))
  let same : Config := { cfg with proposerAgentToken := some agentToken }
  let asApi : Config := { cfg with proposerAgentToken := some apiToken }
  return checkStatus byAgent 401 "the agent token on a proposal's route"
    ++ checkStatus byProposer 404 "the proposals' agent token there, for a job that is not one"
    ++ checkStatus pullByProposer 401 "the proposals' agent token on a pull request's route"
    ++ check (same.check matches .error _) "one token for both agents"
    ++ check (asApi.check matches .error _) "the API token as the proposals' agent token"

/-- A posted review job of pull request `pr`: the agent's draft of one comment, and what was
    posted, the comment rewritten. Answers the job. -/
def postedReviewOf (pr : Nat) : IO Job := do
  let some repo ← Platform.findRepo "acme" "widgets" | throw (IO.userError "no repository")
  let job ← Platform.createJob repo pr (some headA)
  let _ ← Platform.updateJob job.id fun j => return { j with statusRaw := "posted" }
  let r (body : String) := s!"\{\"decision\": \"comment\", \"body\": \"b\", \"comments\": \
[\{\"file\": \"A.lean\", \"start_line\": 3, \"end_line\": 3, \"body\": \"{body}\", \
\"id\": \"c1\"}]}"
  Store.run do
    HasModel.save ({ job_id := job.id, version := 2, author := "agent", review := r "draft"
                   , created_at := "2026-10-01T00:00:00Z" } : Store.RevisionRow)
    HasModel.save ({ job_id := job.id, version := 3, author := "github", review := r "posted"
                   , created_at := "2026-10-01T00:00:00Z" } : Store.RevisionRow)
  return job

/-- A pull request with an `eval` sample teaches nothing: its other samples are not the pool's,
    its posted reviews are not people's edits; and reading the splits again writes nothing. -/
def heldOutPullsTeachNothing : Test := withTempDb do
  let f ← history
  let svc ← DiffReviewerTest.Calibration.services f
  let st ← State.new cfg svc
  let _ ← imported st svc f (evalShare := 0)
  let some repo ← Platform.findRepo "acme" "widgets" | return #["the repository is gone"]
  let (s201, s203) := (← sampleId st 201, ← sampleId st 203)
  let before := (← Calibration.poolSamples repo).map (·.id)
  setSplit s201 "eval"
  let after := (← Calibration.poolSamples repo).map (·.id)
  let _ ← postedReviewOf 7
  let _ ← postedReviewOf 12
  let (edits, prs) ← Proposal.personEdits "acme" "widgets"
  let stamps := (← samples st).map (str · ["updatedAt"])
  let _ ← route st (req .get s!"{repoPath}/calibration/summary")
  let stampsAgain := (← samples st).map (str · ["updatedAt"])
  return check (before.contains s203) "bob's sample of #12, of the pool"
    ++ check (!after.contains s203 && !after.contains s201)
      "no longer, once another sample of #12 is held out"
    ++ checkEq prs [7] "people's edits of #7, and none of #12, held out"
    ++ checkEq edits.size 1 "one changed comment"
    ++ checkEq stampsAgain stamps "splits read again, nothing written"

/-- A proposal's agent context records the pull requests it drew on; a person who rebases the
    proposal and saves it with `fromProposal` keeps that provenance on the rubric version and the
    style notes, accepts the proposal and frees its slot; and the notes' provenance survives a
    delete and a registration again. -/
def fromProposalKeepsProvenance : Test := withTempDb do
  let f ← history
  let orch ← FakeOrchestra.new
  let prop ← FakeOrchestra.new
  let svc ← withProposer f orch prop
  let st ← State.new cfg svc
  let _ ← putRepo st "{}"
  let _ ← route st (req .put s!"{repoPath}/rubrics" rubricV1)
  let _ ← postedReviewOf 7
  let made ← route st (req .post proposalsPath "{}")
  let jobId := (field made "id").getD ""
  Workers.queuePending svc
  let _ ← route st (agentProposalReq .get jobId)
  let submitted ← route st (agentProposalReq .post jobId (proposal 1))
  let pid := (field submitted "proposalId").getD ""
  let _ ← route st (req .put s!"{repoPath}/rubrics" "{\"version\": 1, \"defaultRubric\": \"x\"}")
  let moved ← route st (req .post s!"{proposalsPath}/{pid}/accept" "{\"version\": 2}")
  let rebased ← route st (req .put s!"{repoPath}/rubrics"
    s!"\{\"version\": 2, \"fromProposal\": \"{pid}\", \"defaultRubric\": \"rebased\"}")
  let shown ← route st (req .get s!"{proposalsPath}/{pid}")
  let anew ← route st (req .post proposalsPath "{}")
  let notes ← putRepo st s!"\{\"styleNotes\": \"Brief.\", \"fromProposal\": \"{pid}\"}"
  let notesNow ← Platform.notesHistory "acme" "widgets"
  let unknown ← putRepo st "{\"styleNotes\": \"x\", \"fromProposal\": \"nope\"}"
  let _ ← route st (req .delete repoPath)
  let again ← putRepo st "{\"version\": 0}"
  let notesAfter ← Platform.notesHistory "acme" "widgets"
  let pulls (j : Json) := (listOf j ["derivedFromPulls"]).filterMap (·.getStr?.toOption)
  let movedWhy := (field moved "error").getD ""
  return check ((movedWhy.splitOn "fromProposal").length > 1)
      "a moved rubric's 409 says to save with fromProposal"
    ++ checkStatus rebased 200 "the rebased rubric, saved from the proposal"
    ++ checkEq (pulls (bodyJson rebased)) ["acme/widgets#7"]
      "records the pull request its context drew on"
    ++ checkEq (str (bodyJson shown) ["status"]) (some "accepted") "the proposal is accepted"
    ++ checkEq (num (bodyJson shown) ["acceptedVersion"]) (some 3) "as that version"
    ++ checkStatus anew 201 "and its slot is free"
    ++ checkStatus notes 200 "style notes, written from it"
    ++ checkEq ((notesNow[0]?.map (·.derived.prs)).getD []) ["acme/widgets#7"]
      "record its provenance"
    ++ checkEq (num (bodyJson notes) ["styleNotesVersion"]) (some 1) "as notes version 1"
    ++ checkStatus unknown 400 "from a proposal that is not one"
    ++ checkEq (num (bodyJson again) ["styleNotesVersion"]) (some 2)
      "registered again: the notes go on from the last version"
    ++ checkEq ((notesAfter[0]?.map (·.derived.prs)).getD []) ["acme/widgets#7"]
      "and keep what they were derived from"

/-- Style notes saved in the settings from a proposal record its provenance and decide nothing:
    the proposal stays pending, its slot taken, and its rubric can still be accepted, which the
    notes do not get in the way of. -/
def notesAloneDecideNothing : Test := withTempDb do
  let f ← history
  let orch ← FakeOrchestra.new
  let prop ← FakeOrchestra.new
  let svc ← withProposer f orch prop
  let st ← State.new cfg svc
  let _ ← putRepo st "{}"
  let _ ← route st (req .put s!"{repoPath}/rubrics" rubricV1)
  let _ ← postedReviewOf 7
  let made ← route st (req .post proposalsPath "{}")
  let jobId := (field made "id").getD ""
  Workers.queuePending svc
  let _ ← route st (agentProposalReq .get jobId)
  let submitted ← route st (agentProposalReq .post jobId (proposal 1))
  let pid := (field submitted "proposalId").getD ""
  let notes ← putRepo st s!"\{\"styleNotes\": \"Brief.\", \"fromProposal\": \"{pid}\"}"
  let notesNow ← Platform.notesHistory "acme" "widgets"
  let shown ← route st (req .get s!"{proposalsPath}/{pid}")
  let anew ← route st (req .post proposalsPath "{}")
  let accepted ← route st (req .post s!"{proposalsPath}/{pid}/accept" "{\"version\": 1}")
  let after ← route st (req .get s!"{proposalsPath}/{pid}")
  return checkStatus notes 200 "style notes, written from the proposal"
    ++ checkEq ((notesNow[0]?.map (·.derived.prs)).getD []) ["acme/widgets#7"]
      "record its provenance"
    ++ checkEq (str (bodyJson shown) ["status"]) (some "pending") "the proposal is still pending"
    ++ check ((bodyJson shown).getObjVal? "acceptedVersion" matches .ok .null)
      "with no rubric version"
    ++ checkStatus anew 409 "and still the repository's live proposal"
    ++ checkStatus accepted 200 "its rubric is accepted afterwards"
    ++ checkEq (str (bodyJson after) ["status"]) (some "accepted") "and then it is accepted"
    ++ checkEq (num (bodyJson after) ["acceptedVersion"]) (some 2) "as rubric version 2"

/-- The notes version an agent was given is recorded on its job; a score of any sample of a pull
    request those notes were derived from is derived, one imported after them too. -/
def derivedByPullAndNotes : Test := withTempDb do
  let f ← history
  let orch ← FakeOrchestra.new
  let prop ← FakeOrchestra.new
  let svc ← withProposer f orch prop
  let st ← State.new cfg svc
  let _ ← imported st svc f (evalShare := 0)
  let _ ← poolRunOf st [← sampleId st 301]
  Workers.queuePending svc
  let _ ← routeAgent st (agentReq .get "" (pr := 13))
  let _ ← routeAgent st (agentReq .post "/review" (submission jobHead agentReview) (pr := 13))
  let made ← route st (req .post proposalsPath "{}")
  let jobId := (field made "id").getD ""
  Workers.queuePending svc
  let _ ← route st (agentProposalReq .get jobId)
  let submitted ← route st (agentProposalReq .post jobId (proposal 0))
  let pid := (field submitted "proposalId").getD ""
  let _ ← putRepo st s!"\{\"styleNotes\": \"Brief.\", \"fromProposal\": \"{pid}\"}"
  -- Bob reviews #13 later; his sample takes #13's split, and the suite holds it out.
  f.reviews.modify (·.push (13, review 302 "bob" "COMMENTED" "Looks off." jobHead))
  let _ ← importId st
  Calibration.importStep f.client svc.log 100
  let bobs ← sampleId st 302
  setSplit bobs "eval"
  let run ← runOf st [bobs]
  Workers.queuePending svc
  let _ ← routeAgent st (agentReq .get "" (pr := 13))
  let _ ← routeAgent st (agentReq .post "/review" (submission jobHead agentReview) (pr := 13))
  let job := ((resultsOf run).head?.bind (str · ["jobId"])).getD ""
  let some j ← Platform.findJob job | return #["the calibration job is gone"]
  let summary := bodyJson (← route st (req .get s!"{repoPath}/calibration/summary"))
  return checkStatus run 201 "a run of bob's sample"
    ++ checkEq j.notesVersion (some 1) "the job records the notes version its agent was given"
    ++ checkEq j.rubricVersion (some 0) "under no rubric"
    ++ checkEq (num summary ["overall", "derivedScores"]) (some 1)
      "its score is derived: the notes learned from #13"
    ++ checkEq (num summary ["overall", "scored"]) (some 0) "and left out"

/-- A proposal's misses are of each sample's newest score: a later run that found what an earlier
    one missed leaves nothing missed. -/
def missesAreOfTheNewestScore : Test := withTempDb do
  let f ← history
  let orch ← FakeOrchestra.new
  let prop ← FakeOrchestra.new
  let svc ← withProposer f orch prop
  let st ← State.new cfg svc
  let _ ← imported st svc f (evalShare := 0)
  let s301 ← sampleId st 301
  let both := "{\"decision\": \"request_changes\", \"body\": \"Both.\", \"comments\": [\
{\"file\": \"A.lean\", \"start_line\": 4, \"end_line\": 5, \"body\": \"a name\"}, \
{\"file\": \"A.lean\", \"start_line\": 12, \"end_line\": 12, \"body\": \"this too\"}]}"
  for review in [agentReview, both] do
    let _ ← poolRunOf st [s301]
    Workers.queuePending svc
    let _ ← routeAgent st (agentReq .get "" (pr := 13))
    let _ ← routeAgent st (agentReq .post "/review" (submission jobHead review) (pr := 13))
    IO.sleep 1100
  let made ← route st (req .post proposalsPath "{}")
  let jobId := (field made "id").getD ""
  Workers.queuePending svc
  let ctx := bodyJson (← route st (agentProposalReq .get jobId))
  return checkEq (listOf ctx ["missedHuman"]).length 0 "nothing missed by the newest run"
    ++ checkEq (listOf ctx ["unmatchedAgent"]).length 0 "nor said beside it"

def all : List (String × Test) :=
  [("splitsAreStableAndStored", splitsAreStableAndStored),
   ("ownPostsAreNotSamples", ownPostsAreNotSamples),
   ("proposalsHaveNoUnknownFields", proposalsHaveNoUnknownFields),
   ("proposalsAreCancelled", proposalsAreCancelled),
   ("contextTextsAreBounded", contextTextsAreBounded),
   ("theProposerTokenIsChecked", theProposerTokenIsChecked),
   ("theAgentTokensStandApart", theAgentTokensStandApart),
   ("heldOutPullsTeachNothing", heldOutPullsTeachNothing),
   ("fromProposalKeepsProvenance", fromProposalKeepsProvenance),
   ("notesAloneDecideNothing", notesAloneDecideNothing),
   ("derivedByPullAndNotes", derivedByPullAndNotes),
   ("missesAreOfTheNewestScore", missesAreOfTheNewestScore)]

end DiffReviewerTest.Validity