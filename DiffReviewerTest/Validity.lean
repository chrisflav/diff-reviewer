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

/-- A sample's split is a stable hash of its group against the share, stored once: a share changed
    later splits only the samples imported after it. -/
def splitsAreStableAndStored : Test := withTempDb do
  let keys := (List.range 1000).map fun n => (n, s!"{n}aa")
  let evals := (keys.filter fun (n, c) =>
    Calibration.splitOf "acme" "widgets" n c "alice" 50 == "eval").length
  let f ← history
  let svc ← DiffReviewerTest.Calibration.services f
  let st ← State.new cfg svc
  let tooMuch ← putRepo st "{\"evalShare\": 101}"
  let _ ← imported st svc f (evalShare := 0)
  let before ← samples st
  let changed ← putRepo st "{\"evalShare\": 100}"
  f.reviews.modify (·.push (12, review 205 "alice" "COMMENTED" "Also." headA))
  let _ ← importId st
  Calibration.importStep f.client svc.log 100
  let after ← samples st
  let splitOf (xs : List Json) (rid : Nat) : Option String :=
    (xs.find? (nats · "reviewIds" |>.contains rid)).bind (str · ["split"])
  return checkEq (Calibration.splitOf "acme" "widgets" 7 "aa" "alice" 37)
      (Calibration.splitOf "acme" "widgets" 7 "aa" "alice" 37) "the same group, the same split"
    ++ checkEq (Calibration.splitOf "acme" "widgets" 7 "aa" "alice" 0) "pool" "a share of 0"
    ++ checkEq (Calibration.splitOf "acme" "widgets" 7 "aa" "alice" 100) "eval" "a share of 100"
    ++ check (400 ≤ evals && evals ≤ 600) s!"about half held out at 50: {evals} of 1000"
    ++ checkStatus tooMuch 400 "a share past 100"
    ++ check (before.all (str · ["split"] == some "pool")) "imported at 0: all of the pool"
    ++ checkEq (num (bodyJson changed) ["evalShare"]) (some 100) "the share, a setting"
    ++ checkEq (splitOf after 101) (some "pool") "a split once made does not change"
    ++ checkEq (splitOf after 205) (some "eval") "a sample imported after takes the new share"

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

def all : List (String × Test) :=
  [("splitsAreStableAndStored", splitsAreStableAndStored),
   ("ownPostsAreNotSamples", ownPostsAreNotSamples),
   ("proposalsHaveNoUnknownFields", proposalsHaveNoUnknownFields),
   ("proposalsAreCancelled", proposalsAreCancelled),
   ("contextTextsAreBounded", contextTextsAreBounded),
   ("theProposerTokenIsChecked", theProposerTokenIsChecked)]

end DiffReviewerTest.Validity