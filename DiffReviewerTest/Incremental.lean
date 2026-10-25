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
# Incremental re-review, against fakes

Pull request 7's review at `headA` is posted; the pull request moves on to `headB`. The fake
GitHub compares the two as the test says — `ahead`, `diverged`, or not at all — and answers the
pull request's diff (lines 1 to 20 of `A.lean`) or, from `headA`, the diff of the changes since
(lines 15 to 18).
-/

namespace DiffReviewerTest.Incremental

/-- The diff from `headA` to `headB`: lines 15 to 18 of `A.lean`. -/
def rangeDiff : String :=
  "diff --git a/A.lean b/A.lean\n--- a/A.lean\n+++ b/A.lean\n@@ -15,2 +15,4 @@\n x\n"

/-- How the fake compares two commits. -/
inductive Compare where
  | ahead
  | diverged
  | refused
  | unreachable

/-- How many times the fake was asked to compare, since the last `posted`. -/
initialize compareCalls : IO.Ref Nat ← IO.mkRef 0

/-- Whether the fake refuses the diff from `headA`. -/
initialize rangeFails : IO.Ref Bool ← IO.mkRef false

/-- 150 commits from `headA` to `headB`, oldest first, as GitHub lists them. -/
def commitsSince : Array (String × String) :=
  ((Array.range 149).map fun i => (s!"c{i}", s!"Commit {i}")).push (headB, "Fix the names")

/-- `gh`'s client, comparing as `cmp` says and answering the diff from `headA` as `rangeDiff`. -/
def client (gh : FakeGitHub) (cmp : IO.Ref Compare) : GitHub.Client :=
  { gh.client with
    diff := fun _ _ base _ => do
      gh.diffCalls.modify (· + 1)
      if base == headA then
        if ← rangeFails.get then return .error (.indefinite "GitHub answered 502")
        return .ok rangeDiff
      return .ok (← gh.diffText.get)
    compare := fun _ _ _ _ => do
      compareCalls.modify (· + 1)
      match ← cmp.get with
      | .ahead => return .ok { status := "ahead", commits := commitsSince }
      | .diverged => return .ok { status := "diverged", commits := #[] }
      | .refused => return .error (.definite "GitHub answered 404: No common ancestor")
      | .unreachable => return .error (.indefinite "GitHub answered 502") }

def commentJson (line : Nat) (body : String) : String :=
  s!"\{\"file\": \"A.lean\", \"start_line\": {line}, \"end_line\": {line}, \"body\": \"{body}\"}"

def reviewWith (comments : List String) : String :=
  s!"\{\"decision\": \"comment\", \"body\": \"Better.\", \"comments\": \
[{", ".intercalate comments}]}"

def has (s t : String) : Bool := (s.splitOn t).length > 1

/-- The fakes, a repository registered with `repo`, and pull request 7's review at `headA` posted
    — one comment, on line 3 — and a job for the pull request's new head, `headB`; answers the
    services, the server, the orchestra, the GitHub, and the two jobs' ids. -/
def posted (cmp : Compare) (repo : String := "{\"mode\": \"staged\"}") :
    IO (Workers.Services × State × FakeOrchestra × FakeGitHub × String × String) := do
  compareCalls.set 0
  rangeFails.set false
  let gh ← FakeGitHub.new #[pull7 headA]
  let orch ← FakeOrchestra.new
  let cmpRef ← IO.mkRef cmp
  let svc ← Workers.Services.new (some (client gh cmpRef)) (some orch.client) (fun _ => pure ())
  let st ← State.new cfg svc
  let _ ← route st (req .put "/api/v1/repos/acme/widgets" repo)
  let mk (head : String) := route st (req .post "/api/v1/jobs"
    s!"\{\"owner\": \"acme\", \"name\": \"widgets\", \"prNumber\": 7, \"headSha\": \"{head}\"}")
  let a := (field (← mk headA) "id").getD ""
  let drafted ← route st (req .put s!"/api/v1/jobs/{a}/review"
    (reviewBody 1 (reviewWith [commentJson 3 "Rename x."])))
  let approved ← route st (req .post s!"/api/v1/jobs/{a}/status"
    (statusBody "approved" (versionOf drafted)))
  let _ ← route st (req .post s!"/api/v1/jobs/{a}/post" s!"\{\"version\": {versionOf approved}}")
  gh.pulls.set #[pull7 headB]
  let b := (field (← mk headB) "id").getD ""
  return (svc, st, orch, gh, a, b)

/-- The new head descends from the reviewed one: the job is incremental, knows what it follows
    and the commits since, and its agent is shown the posted review and asked for the changes
    since; their diff is bound to the job, comments off it are refused, and the posted body links
    the earlier review. -/
def anIncrementalReReview : Test := withTempDb do
  let (svc, st, orch, gh, a, b) ← posted .ahead
  let some prev ← Platform.findJob a | return #["the posted job is gone"]
  Workers.queuePending svc
  let job ← route st (req .get s!"/api/v1/jobs/{b}")
  let prompt := ((← orch.queued.get)[0]?.map (·.prompt)).getD ""
  let shown ← routeAgent st (agentReq .get "")
  let shownJson := bodyJson shown
  let incremental := (shownJson.getObjVal? "incremental").toOption.getD .null
  let since (sha : String) : Req := { agentReq .get "/diff" with query := s!"since={sha}" }
  let range ← routeAgent st (since headA)
  let wrongSince ← routeAgent st (since headB)
  let fullDiff ← routeAgent st (agentReq .get "/diff")
  let offRange ← routeAgent st (agentReq .post "/review"
    (submission headB (reviewWith [commentJson 3 "Still."])))
  let kept ← do
    let _ ← Platform.pruneDiffs "2000-01-01T00:00:00Z"
    Platform.cachedDiff "acme" "widgets" headA headB
  let submitted ← routeAgent st (agentReq .post "/review"
    (submission headB (reviewWith [commentJson 16 "A new problem."])))
  let some drafted ← Platform.findJob b | return #["the job is gone"]
  let draftBody := ((drafted.review?.bind (·.toOption)).map (·.body)).getD ""
  let approved ← route st (req .post s!"/api/v1/jobs/{b}/status"
    (statusBody "approved" drafted.version))
  -- The diff since cannot be had: the post is refused, not made unchecked.
  Store.run do
    let db ← read
    SQLite.exec db s!"DELETE FROM pull_diff WHERE base_sha = '{headA}'"
  rangeFails.set true
  let unchecked ← route st (req .post s!"/api/v1/jobs/{b}/post"
    s!"\{\"version\": {versionOf approved}}")
  rangeFails.set false
  let postedB ← route st (req .post s!"/api/v1/jobs/{b}/post"
    s!"\{\"version\": {versionOf approved}}")
  let bodies := (← gh.posted.get).map (·.2.1.body)
  let url := prev.postedUrl.getD ""
  let str (j : Json) (k : String) := (j.getObjValAs? String k).toOption
  let commits := (((job |> bodyJson).getObjVal? "incrementalCommits").toOption.bind
    (·.getArr?.toOption) |>.map (·.toList.filterMap (str · "sha"))).getD []
  let postedBody := ((incremental.getObjVal? "postedReview").toOption.bind
    (str · "body")).getD "<none>"
  return checkEq (field job "previousJob") (some a) "the job it follows up"
    ++ checkEq (field job "incrementalSince") (some headA) "the head that review was of"
    ++ checkEq commits.length 100 "the commits since, at most 100"
    ++ checkEq (commits.head?, commits.getLast?) (some "c50", some headB) "the newest"
    ++ checkEq (← compareCalls.get) 1 "compared once"
    ++ checkEq (field job "fullReviewReason") none "no reason to review it in full"
    ++ check (has prompt s!"--since {headA} --job {b}") "the prompt asks for the changes since"
    ++ check (has prompt "Do not repeat a point the earlier review made") "and not to repeat"
    ++ check (has prompt "which of its points the new commits resolve") "and what is resolved"
    ++ checkStatus shown 200 "the agent's read"
    ++ checkEq (str incremental "sinceSha") (some headA) "the agent is told what it follows"
    ++ checkEq ((incremental.getObjVal? "postedReview").toOption.bind (str · "url"))
      prev.postedUrl "the posted review, as GitHub holds it"
    ++ check (has (incremental.compress) "Rename x.") "with its comments"
    ++ check (!has postedBody "diff-reviewer job" && has postedBody "Better.")
      "and its body without the hidden marker"
    ++ check (has (incremental.compress) "Fix the names") "and the commits since"
    ++ check ((str shownJson "instructions").any (has · "follows up an earlier one"))
      "its instructions say so"
    ++ checkStatus range 200 "the diff since"
    ++ checkEq (String.fromUTF8! range.body) rangeDiff "is the range's"
    ++ checkStatus wrongSince 400 "the diff since another commit"
    ++ check (String.fromUTF8! fullDiff.body != rangeDiff) "the pull request's diff, without"
    ++ checkStatus offRange 400 "a comment off the changes since"
    ++ check (has (String.fromUTF8! offRange.body) "since") "saying why"
    ++ check kept.isSome "the diff since is kept while the job is live"
    ++ checkStatus submitted 200 "a comment on them"
    ++ check (has draftBody s!"Follow-up to [the earlier review]({url})")
      "the draft links the earlier review, for a person to read and approve"
    ++ checkStatus unchecked 409 "posting when the diff since cannot be checked"
    ++ checkStatus postedB 200 "posting it"
    ++ checkEq ((bodies[1]?.map (·.splitOn "Follow-up to")).map (·.length)) (some 2)
      "the posted body links the earlier review, once"

/-- A force-push — the reviewed head no ancestor of the new — falls back to a full review, with
    why on the job; so does a head GitHub refuses to compare. GitHub not answering keeps the job
    waiting, recorded once. -/
def aForcePushIsReviewedInFull : Test := withTempDb do
  let failing : Orchestra.Client :=
    { queue := fun _ => return .error "orchestra answered 503", entry := fun _ => return .error ""
      cancel := fun _ => return .ok () }
  let (svc0, _, _, _, _, b0) ← posted .diverged
  let svcF := { svc0 with orchestra := some failing }
  Workers.queuePending svcF
  Workers.queuePending svcF
  let decidedOnce ← compareCalls.get
  let some held ← Platform.findJob b0 | return #["the job is gone"]
  let _ ← Platform.updateJob b0 fun j => return { j with statusRaw := "rejected" }
  let (svc, st, orch, _, _, b) ← posted .diverged
  Workers.queuePending svc
  let some job ← Platform.findJob b | return #["the job is gone"]
  let prompt := ((← orch.queued.get)[0]?.map (·.prompt)).getD ""
  let shown ← routeAgent st (agentReq .get "")
  let since ← routeAgent st { agentReq .get "/diff" with query := s!"since={headA}" }
  let submitted ← routeAgent st (agentReq .post "/review"
    (submission headB (reviewWith [commentJson 3 "Anywhere in the diff."])))
  let (svc2, _, _, _, _, b2) ← posted .refused
  Workers.queuePending svc2
  let some refused ← Platform.findJob b2 | return #["the second job is gone"]
  let (svc3, _, _, _, _, b3) ← posted .unreachable
  Workers.queuePending svc3
  let some waiting ← Platform.findJob b3 | return #["the third job is gone"]
  Workers.queuePending svc3
  let some still ← Platform.findJob b3 | return #["the third job is gone"]
  return checkEq decidedOnce 1 "decided once, though the job waits on orchestra"
    ++ checkEq held.statusRaw "pending" "the job that waits"
    ++ check (held.fullReviewReason.any (has · "force-push")) "keeps the decision"
    ++ checkEq job.incrementalSince none "a force-push is not incremental"
    ++ check (job.fullReviewReason.any (has · "force-push")) "and the job says why"
    ++ checkEq job.statusRaw "queued" "queued, to be reviewed in full"
    ++ check (!has prompt "--since") "the prompt asks for the whole diff"
    ++ checkEq (((bodyJson shown).getObjVal? "incremental").toOption) (some .null)
      "nothing to follow up"
    ++ checkStatus since 400 "a diff since, of a full review"
    ++ checkStatus submitted 200 "a comment anywhere in the diff"
    ++ check (refused.fullReviewReason.any (has · "could not be compared"))
      "a head GitHub refuses to compare"
    ++ checkEq refused.statusRaw "queued" "is reviewed in full"
    ++ checkEq waiting.statusRaw "pending" "GitHub not answering: the job waits"
    ++ check (waiting.error.any (has · "502")) "saying why"
    ++ checkEq still.version waiting.version "once"

/-- `incremental` is a setting, on by default; off, a new head is reviewed in full, as one is when
    nothing was posted. -/
def incrementalIsASetting : Test := withTempDb do
  let (svc, st, _, _, _, b) ← posted .ahead "{\"mode\": \"staged\", \"incremental\": false}"
  Workers.queuePending svc
  let some off ← Platform.findJob b | return #["the job is gone"]
  let repo ← route st (req .get "/api/v1/repos/acme/widgets")
  let bad ← route st (req .put "/api/v1/repos/acme/widgets" "{\"incremental\": \"yes\"}")
  let on ← route st (req .put "/api/v1/repos/acme/widgets" "{\"incremental\": true}")
  let kept ← route st (req .put "/api/v1/repos/acme/widgets" "{\"mode\": \"staged\"}")
  -- Nothing posted: the first review of a pull request is a full one.
  let gh ← FakeGitHub.new #[pull7 headA]
  let cmp ← IO.mkRef Compare.ahead
  let svc2 ← Workers.Services.new (some (client gh cmp)) (some (← FakeOrchestra.new).client)
    (fun _ => pure ())
  let st2 ← State.new cfg svc2
  let job ← route st2 (req .post "/api/v1/jobs"
    s!"\{\"owner\": \"acme\", \"name\": \"widgets\", \"prNumber\": 7, \"headSha\": \"{headA}\"}")
  Workers.queuePending svc2
  let some first ← Platform.findJob ((field job "id").getD "") | return #["the job is gone"]
  let flag (r : Reply) := ((bodyJson r).getObjValAs? Bool "incremental").toOption
  return checkEq off.incrementalSince none "off, a new head is reviewed in full"
    ++ checkEq off.fullReviewReason none "with nothing to say"
    ++ checkEq (flag repo) (some false) "the setting"
    ++ checkStatus bad 400 "a setting that is not a boolean"
    ++ checkEq (flag on) (some true) "turned on"
    ++ checkEq (flag kept) (some true) "kept by a write that leaves it out"
    ++ checkEq first.statusRaw "queued" "a first review"
    ++ checkEq first.incrementalSince none "is a full one"

/-- The agent CLI's `--since`, and the prompt of a fan-out's sub-run of an incremental re-review. -/
def theAgentAsksForTheChangesSince : Test := do
  let job : Job := { id := "j1", owner := "acme", name := "widgets", prNumber := 7
                   , createdAt := "", updatedAt := "", incrementalSince := some headA }
  let sub : Fanout.SubRun := { id := "s1", jobId := "j1", owner := "acme", name := "widgets"
                             , round := 0, position := 1, key := "naming"
                             , category := some "naming", externalBase := "j1", createdAt := ""
                             , updatedAt := "" }
  let scope : Workers.Scope :=
    { sub := sub, category := some { name := "naming" }, others := [], ref := "j1.naming" }
  let inScope := Workers.prompt job (some scope)
  return checkEq (Agent.diffFlags ["--since", headA, "--job", "j1"]) (some (some headA, some "j1"))
      "--since before --job"
    ++ checkEq (Agent.diffFlags ["--job", "j1"]) (some (none, some "j1")) "--job alone"
    ++ checkEq (Agent.diffFlags ["--since", headA]) none "no --job"
    ++ check (has inScope s!"--since {headA} --job j1.naming")
      "a sub-run of an incremental re-review asks for the changes since"
    ++ check (!has (Workers.prompt { job with incrementalSince := none }) "--since")
      "a full review does not"

def all : List (String × Test) :=
  [("anIncrementalReReview", anIncrementalReReview),
   ("aForcePushIsReviewedInFull", aForcePushIsReviewedInFull),
   ("incrementalIsASetting", incrementalIsASetting),
   ("theAgentAsksForTheChangesSince", theAgentAsksForTheChangesSince)]

end DiffReviewerTest.Incremental