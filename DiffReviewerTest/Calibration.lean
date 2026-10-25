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

A repository's past: three closed pull requests, reviewed by two trusted reviewers and by
somebody else, with reviews to merge, to keep for their decision only and to drop, and inline
comments of every kind the import keeps or drops. Imported, run, reviewed by the agent and
scored — and never posted, whatever is asked.
-/

namespace DiffReviewerTest.Calibration

/-- The closed pull requests, their reviews and their review comments; which pull requests'
    reviews are refused next for GitHub's rate limit, and which always fail; and what GitHub says
    of the rate limit. -/
structure FakeHistory where
  gh          : FakeGitHub
  closed      : IO.Ref (Array GitHub.Pull)
  reviews     : IO.Ref (Array (Nat × GitHub.PostedReview))
  comments    : IO.Ref (Array (Nat × GitHub.ReviewComment))
  rateLimited : IO.Ref (List Nat)
  failing     : IO.Ref (List Nat)
  limit       : IO.Ref (Option GitHub.RateLimit)
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

/-- #11 at `headA`: alice asks for changes, keeping two comments and dropping three, then
    comments once more on the same commit — one sample, `partial`; mallory, who is not trusted,
    comments; alice's pending review and her reply-only review are not samples. #12 at `headB`:
    alice approves with a word, bob approves with none — a sample for its decision only. #13 at
    `jobHead`: alice asks for changes with two comments, nothing dropped — a `full` sample. -/
def FakeHistory.new : IO FakeHistory := do
  let pull (n : Nat) (head : String) : GitHub.Pull :=
    { number := n, title := s!"Pull {n}", body := s!"About {n}.", headSha := head
    , baseSha := base, state := "closed" }
  return { gh := ← FakeGitHub.new
         , closed := ← IO.mkRef #[pull 11 headA, pull 12 headB, pull 13 jobHead]
         , reviews := ← IO.mkRef #[
             (11, review 101 "Alice" "CHANGES_REQUESTED" "Please fix the names." headA),
             (11, review 102 "mallory" "COMMENTED" "Ship it." headA),
             (11, review 103 "alice" "PENDING" "draft" headA),
             (11, review 104 "alice" "COMMENTED" "" headA),
             (11, review 105 "alice" "COMMENTED" "One more." headA),
             (12, review 201 "alice" "APPROVED" "LGTM" headB),
             (12, review 203 "bob" "APPROVED" "" headB),
             (13, review 301 "alice" "CHANGES_REQUESTED" "Please fix the names." jobHead)]
         , comments := ← IO.mkRef #[
             (11, comment 1 101 "RIGHT" 5 (start := some 3) (body := "rename that")),
             (11, comment 2 101 "LEFT" 2),
             (11, comment 3 101 "RIGHT" 5 (reply := some 1)),
             (11, comment 4 101 "RIGHT" 7 (commit := headB)),
             (11, comment 5 101 "RIGHT" 12),
             (11, comment 6 102 "RIGHT" 9),
             (11, comment 7 104 "RIGHT" 5 (reply := some 1)),
             (11, comment 8 105 "RIGHT" 15),
             (13, comment 9 301 "RIGHT" 5 (start := some 3) (commit := jobHead)
               (body := "rename this")),
             (13, comment 10 301 "RIGHT" 12 (commit := jobHead) (body := "and this"))]
         , rateLimited := ← IO.mkRef [], failing := ← IO.mkRef [], limit := ← IO.mkRef none
         , reviewCalls := ← IO.mkRef #[] }

def FakeHistory.client (f : FakeHistory) : GitHub.Client :=
  { f.gh.client with
    listClosedPulls := fun _ _ limit => return .ok ((← f.closed.get).extract 0 limit)
    listReviews := fun _ _ n => do
      f.reviewCalls.modify (·.push n)
      if (← f.rateLimited.get).contains n then
        f.rateLimited.modify (·.erase n)
        return .error (.rateLimited "GitHub answered 403: API rate limit exceeded")
      if (← f.failing.get).contains n then return .error (.indefinite "GitHub answered 502")
      return .ok (((← f.reviews.get).filter (·.1 == n)).map (·.2))
    listReviewComments := fun _ _ n =>
      return .ok (((← f.comments.get).filter (·.1 == n)).map (·.2))
    mergeBase := fun _ _ _ _ => return .ok mergeBase
    rateLimit := f.limit.get }

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

def nats (j : Json) (k : String) : List Nat :=
  ((j.getObjVal? k).toOption.bind (·.getArr?.toOption)).map
    (·.toList.filterMap (·.getNat?.toOption)) |>.getD []

def samples (st : State) : IO (List Json) := do
  return items (← route st (req .get s!"{repoPath}/calibration/samples"))

/-- The sample review `reviewId` is part of. -/
def sampleOf (st : State) (reviewId : Nat) : IO Json := do
  return ((← samples st).find? (nats · "reviewIds" |>.contains reviewId)).getD .null

def sampleId (st : State) (reviewId : Nat) : IO String := do
  return (str (← sampleOf st reviewId) ["id"]).getD ""

def imports (st : State) : IO (List Json) := do
  return items (← route st (req .get s!"{repoPath}/calibration/import"))

/-- Import `id`, as listed now. -/
def importNamed (st : State) (id : String) : IO Json := do
  return ((← imports st).find? (str · ["id"] == some id)).getD .null

def import_ (st : State) (body : String := "{}") : IO Reply :=
  route st (req .post s!"{repoPath}/calibration/import" body)

/-- Ask for an import; answers its id. -/
def importId (st : State) (body : String := "{}") : IO String := do
  return (field (← import_ st body) "id").getD ""

/-- Register the repository with alice and bob trusted, and import its history in one pass;
    answers the import's id. -/
def imported (st : State) (svc : Workers.Services) (f : FakeHistory) (mode := "staged") :
    IO String := do
  let _ ← putRepo st s!"\{\"mode\": \"{mode}\", \"trustedReviewers\": [\"Alice\", \"bob\"]}"
  let id ← importId st
  Calibration.importStep f.client svc.log 100
  return id

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

/-- The matcher: one to one, on one file, overlapping or within three lines, closest first; what
    it reports; and a sample scored for its decision only. -/
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
  let partial_ := (Score.score agent "APPROVED" human (scope := "partial")).toJson
  let agg := [j, partial_].foldl (fun a x => (a.add x).getD a) ({} : Score.Aggregate)
  let aj := agg.toJson
  let unscorable := Json.mkObj [("matcherVersion", 1), ("unscorable", "the draft does not read")]
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
    ++ checkEq (ratioOf partial_ ["precision"]) none "a partial sample has no precision"
    ++ checkEq (num partial_ ["matched"]) (some 2) "though its pairs are made, to be read"
    ++ checkEq (num aj ["scored"]) (some 2) "both scores aggregated"
    ++ checkEq (num aj ["commentsScored"]) (some 1) "only the full one for its comments"
    ++ checkEq (num aj ["agentComments"]) (some 4) "the agent's comments of the full one"
    ++ checkEq (num aj ["decisions", "compared"]) (some 2) "both decisions compared"
    ++ checkEq (num aj ["decisions", "agreed"]) (some 1) "one agreed"
    ++ check (agg.add unscorable).isNone "an unscorable score is left out"

/-- The import merges what one reviewer said of one commit into one sample, keeps its comments on
    the new side of that commit and drops and counts the rest; keeps an approval that says nothing
    for its decision; is idempotent, counting nothing twice; adds a later review to its group; and
    adds nothing to, or back, a deleted sample. -/
def theImportGroupsTrustedReviews : Test := withTempDb do
  let f ← FakeHistory.new
  let svc ← services f
  let st ← State.new cfg svc
  let _ ← putRepo st "{}"
  let noTrusted ← import_ st
  let first ← importNamed st (← imported st svc f)
  let all ← samples st
  let s11 ← sampleOf st 101
  let s12a ← sampleOf st 201
  let s12b ← sampleOf st 203
  let s13 ← sampleOf st 301
  let lines (s : Json) (k : String) : List (Option Nat) :=
    (((s.getObjVal? "comments").toOption.bind (·.getArr?.toOption)).map
      (·.toList.map (num · [k]))).getD []
  -- Again: nothing new, nothing counted twice.
  let again ← import_ st "{\"limit\": 5}"
  let againId := (field again "id").getD ""
  let tooMany ← import_ st "{\"limit\": 500}"
  Calibration.importStep f.client svc.log 100
  let second ← importNamed st againId
  -- A later review of alice's on #11 at headA joins her sample; one of bob's on #12 at headB does
  -- not join his, deleted.
  let bobsPath := s!"{repoPath}/calibration/samples/{(str s12b ["id"]).getD ""}"
  let deleted ← route st (req .delete bobsPath)
  let deletedAgain ← route st (req .delete bobsPath)
  f.reviews.modify (· ++ #[(11, review 106 "alice" "COMMENTED" "And another." headA),
                           (12, review 204 "bob" "COMMENTED" "Also this." headB)])
  f.comments.modify (·.push (11, comment 11 106 "RIGHT" 18))
  let thirdId ← importId st
  Calibration.importStep f.client svc.log 100
  let third ← importNamed st thirdId
  let s11' ← sampleOf st 101
  let after ← samples st
  return checkStatus noTrusted 409 "an import with nobody trusted"
    ++ checkEq (str first ["status"]) (some "done") "the import, after one pass"
    ++ checkEq (num first ["stats", "pulls"]) (some 3) "pull requests listed"
    ++ checkEq (num first ["stats", "reviews"]) (some 6) "the trusted reviewers' submitted reviews"
    ++ checkEq (num first ["stats", "imported"]) (some 4) "samples made"
    ++ checkEq (num first ["stats", "merged"]) (some 1) "a review merged into its group's sample"
    ++ checkEq (num first ["stats", "empty"]) (some 1) "a comment that says nothing"
    ++ checkEq (num first ["stats", "droppedLeft"]) (some 1) "a comment on the old side"
    ++ checkEq (num first ["stats", "droppedOutdated"]) (some 1) "one placed on another commit"
    ++ checkEq (num first ["stats", "droppedReplies"]) (some 2) "replies"
    ++ checkEq all.length 4 "samples"
    ++ checkEq (all.map (str · ["id"])) [str s11 ["id"], str s12b ["id"], str s13 ["id"],
      str s12a ["id"]] "the most recently reviewed first"
    ++ checkEq (nats s11 "reviewIds") [101, 105] "alice's two reviews of headA, merged"
    ++ checkEq (str s11 ["reviewer"]) (some "alice") "the reviewer, in lower case"
    ++ checkEq (str s11 ["state"]) (some "CHANGES_REQUESTED") "the strongest state"
    ++ checkEq (str s11 ["body"]) (some "Please fix the names.\n\nOne more.") "the bodies"
    ++ checkEq (str s11 ["commitId"]) (some headA) "the commit reviewed"
    ++ checkEq (str s11 ["baseSha"]) (some mergeBase) "the base it had there"
    ++ checkEq (lines s11 "line") [some 5, some 12, some 15]
      "the comments kept, by their line on the review's commit"
    ++ checkEq (lines s11 "start_line") [some 3, some 12, some 15] "and where they start"
    ++ checkEq (num s11 ["dropped", "left"]) (some 1) "the sample says what it dropped"
    ++ checkEq (str s11 ["scope"]) (some "partial") "and that it is not the whole review"
    ++ checkEq (str s12a ["scope"]) (some "full") "an approval with a word and no comment"
    ++ checkEq (str s12b ["scope"]) (some "decision") "an approval that says nothing"
    ++ checkEq (str s13 ["scope"]) (some "full") "a review with nothing dropped"
    ++ checkStatus again 202 "importing again, once the first is done"
    ++ checkStatus tooMany 400 "more than 200 pull requests"
    ++ checkEq (num second ["stats", "known"]) (some 6) "importing again: every review known"
    ++ checkEq (num second ["stats", "imported"]) (some 0) "nothing new"
    ++ checkEq (num second ["stats", "empty"]) (some 0) "the empty review not counted again"
    ++ checkEq (num second ["stats", "droppedReplies"]) (some 0) "nor its replies"
    ++ checkStatus deleted 204 "deleting a sample"
    ++ checkStatus deletedAgain 404 "deleting it twice"
    ++ checkEq (nats s11' "reviewIds") [101, 105, 106] "a later review joins its group"
    ++ checkEq (lines s11' "line") [some 5, some 12, some 15, some 18] "with its comment"
    ++ checkEq (num third ["stats", "merged"]) (some 1) "counted as merged"
    ++ checkEq (num third ["stats", "known"]) (some 6) "every review seen before, known"
    ++ checkEq (num third ["stats", "deleted"]) (some 1) "and the deleted group's, counted apart"
    ++ checkEq after.length 3 "a deleted sample stays deleted"

/-- GitHub's rate limit stops the import where it is, and the next pass goes on from there; the
    requests left under the reserve pause it until the reset; a pass reads at most its budget of
    pull requests; and the limit is read off GitHub's headers. -/
def theImportKeepsToItsBudget : Test := withTempDb do
  let f ← FakeHistory.new
  let svc ← services f
  let st ← State.new cfg svc
  let _ ← putRepo st "{\"trustedReviewers\": [\"alice\"]}"
  let firstId ← importId st
  let busy ← import_ st
  f.rateLimited.set [12]
  Calibration.importStep f.client svc.log 100
  let stopped ← importNamed st firstId
  let callsThen := (← f.reviewCalls.get).size
  Calibration.importStep f.client svc.log 100
  let resumed ← importNamed st firstId
  -- Under the reserve until a reset an hour away: nothing is asked.
  let now := (← Std.Time.Timestamp.now).toSecondsSinceUnixEpoch.val
  f.limit.set (some { remaining := 499, resetAt := now + 3600 })
  let pausedId ← importId st
  f.reviewCalls.set #[]
  Calibration.importStep f.client svc.log 100
  let paused ← importNamed st pausedId
  let pausedCalls := (← f.reviewCalls.get).size
  -- Fewer left on the next pass, still under the reserve: nothing new is written.
  f.limit.set (some { remaining := 450, resetAt := now + 3600 })
  Calibration.importStep f.client svc.log 100
  let pausedAgain ← importNamed st pausedId
  -- Past the reset, it goes on; a budget of one pull request a pass.
  f.limit.set (some { remaining := 499, resetAt := now - 1 })
  Calibration.importStep f.client svc.log 1
  let budgeted ← importNamed st pausedId
  let budgetCalls ← f.reviewCalls.get
  let dump := "HTTP/1.1 200 Connection established\r\n\r\nHTTP/2 403\r\n\
x-ratelimit-remaining: 0\r\nX-RateLimit-Reset: 1792866501\r\ncontent-type: application/json\r\n\r\n"
  let headers := Http.parseHeaders dump
  let answer (status : Nat) (msg : String) : Http.Response :=
    { status, body := s!"\{\"message\": \"{msg}\"}" }
  return checkStatus busy 409 "a second import while one is under way"
    ++ checkEq (str stopped ["status"]) (some "running") "the import, stopped by the limit"
    ++ checkEq (num stopped ["pullsRead"]) (some 1) "the pull request read before it"
    ++ check ((str stopped ["error"]).any (·.startsWith "GitHub's rate limit")) "why it stopped"
    ++ checkEq callsThen 2 "nothing asked after the limit"
    ++ checkEq (str resumed ["status"]) (some "done") "the next pass finishes it"
    ++ checkEq (num resumed ["stats", "imported"]) (some 3) "with every sample of alice's"
    ++ checkEq (resumed.getObjVal? "error" |>.toOption) (some .null) "and no error"
    ++ checkEq pausedCalls 0 "under the reserve, nothing asked"
    ++ check ((str paused ["error"]).any (·.startsWith "paused until")) "and why"
    ++ checkEq (str pausedAgain ["error"]) (str paused ["error"])
      "the same words on the next pass"
    ++ checkEq (str pausedAgain ["updatedAt"]) (str paused ["updatedAt"]) "and nothing written"
    ++ check (!(str paused ["error"]).any (fun e => (e.splitOn "499").length > 1))
      "no count in what is stored"
    ++ checkEq budgetCalls #[11] "past the reset, one pull request in a pass of budget one"
    ++ checkEq (num budgeted ["pullsRead"]) (some 1) "and recorded"
    ++ checkEq headers.length 3 "the last answer's headers, past the proxy's"
    ++ checkEq ((GitHub.RateLimit.ofResponse? { status := 403, body := "", headers }).map
      fun l => (l.remaining, l.resetAt)) (some (0, 1792866501)) "the rate limit they give"
    ++ check (GitHub.rateLimited (answer 403 "API rate limit exceeded for user ID 1."))
      "GitHub's primary limit"
    ++ check (GitHub.rateLimited (answer 403 "You have exceeded a secondary rate limit."))
      "its secondary limit"
    ++ check (GitHub.rateLimited (answer 429 "Too Many Requests")) "a 429"
    ++ check (!GitHub.rateLimited (answer 403 "Resource not accessible by integration"))
      "a refusal that is not the limit"

/-- A pull request that keeps failing is skipped after three tries, and the import goes on; an
    import can be cancelled, and is then read no further. -/
def stuckImportsMoveOn : Test := withTempDb do
  let f ← FakeHistory.new
  let svc ← services f
  let st ← State.new cfg svc
  let _ ← putRepo st "{\"trustedReviewers\": [\"alice\"]}"
  let stuckId ← importId st
  f.failing.set [12]
  Calibration.importStep f.client svc.log 100
  let once ← importNamed st stuckId
  Calibration.importStep f.client svc.log 100
  Calibration.importStep f.client svc.log 100
  let skipped ← importNamed st stuckId
  -- Cancelled before it has read anything.
  f.failing.set []
  let started ← import_ st
  let id := (field started "id").getD ""
  let cancelled ← route st (req .post s!"{repoPath}/calibration/import/{id}/cancel" "{}")
  f.reviewCalls.set #[]
  Calibration.importStep f.client svc.log 100
  let twice ← route st (req .post s!"{repoPath}/calibration/import/{id}/cancel" "{}")
  let unknown ← route st (req .post s!"{repoPath}/calibration/import/nope/cancel" "{}")
  return checkEq (num once ["pullsRead"]) (some 1) "#12 failed once"
    ++ checkEq (num once ["failures"]) (some 1) "and that is counted"
    ++ checkEq (str skipped ["status"]) (some "done") "after the third failure it goes on"
    ++ checkEq (num skipped ["stats", "unreadable"]) (some 1) "#12, skipped as unreadable"
    ++ checkEq (num skipped ["stats", "imported"]) (some 2) "and the rest imported"
    ++ checkStatus cancelled 200 "cancelling an import"
    ++ checkEq (field cancelled "status") (some "cancelled") "it is cancelled"
    ++ checkEq (← f.reviewCalls.get).size 0 "and read no further"
    ++ checkStatus twice 409 "cancelling it again"
    ++ checkStatus unknown 404 "cancelling an import that is not one"

def runOf (st : State) (ids : List String) : IO Reply :=
  route st (req .post s!"{repoPath}/calibration/runs"
    s!"\{\"samples\": [{", ".intercalate (ids.map (s!"\"{·}\""))}]}")

/-- The agent's review of #13: one comment on alice's first, one on nothing. -/
def agentReview : String :=
  "{\"decision\": \"request_changes\", \"body\": \"Two things.\", \"comments\": [\
{\"file\": \"A.lean\", \"start_line\": 4, \"end_line\": 5, \"body\": \"a name\", \
\"category\": \"naming\", \"severity\": \"minor\"}, \
{\"file\": \"A.lean\", \"start_line\": 18, \"end_line\": 18, \"body\": \"a doc\", \
\"category\": \"docs\", \"severity\": \"nit\"}]}"

def resultsOf (r : Reply) : List Json :=
  (((bodyJson r).getObjVal? "results").toOption.bind (·.getArr?.toOption)).map (·.toList)
    |>.getD []

/-- A calibration job goes through the queue and the agent like a review — at its sample's commit,
    though the pull request is closed — is scored when it is a draft, and is never approved,
    claimed or posted, even in a `direct` repository; nor is what the agent is given any of the
    person's review, nor does its prompt send it to any other commit. -/
def calibrationJobsAreNeverPosted : Test := withTempDb do
  let f ← FakeHistory.new
  let orch ← FakeOrchestra.new
  let svc ← services f orch
  let st ← State.new cfg svc
  let _ ← imported st svc f (mode := "direct")
  let made ← runOf st [← sampleId st 301]
  let runId := (field made "id").getD ""
  let jobId := ((resultsOf made).head?.bind (str · ["jobId"])).getD ""
  Workers.queuePending svc
  let queued ← orch.queued.get
  let prompt := (queued[0]?.map (·.prompt)).getD ""
  let has (t : String) := (prompt.splitOn t).length > 1
  let shown ← route st (agentReq .get "" (pr := 13))
  let shownText := String.fromUTF8! shown.body
  let human := ["Please fix the names.", "rename this", "and this"]
  let submitted ← route st (agentReq .post "/review" (submission jobHead agentReview) (pr := 13))
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
  let result := ((resultsOf run).head?).getD .null
  let listed ← route st (req .get "/api/v1/jobs")
  let listedCal ← route st { req .get "/api/v1/jobs" with query := "kind=calibration" }
  let reviewPrompt := Workers.prompt { job with kindRaw := none }
  let withCheckout : Orchestra.QueueRequest :=
    { prompt := "", goal := "", upstream := "acme/widgets", issueNumber := some 13
    , externalId := "x"
    , checkout := some jobHead }
  return checkStatus made 201 "the run"
    ++ checkEq (queued.map (·.issueNumber)) #[some 13] "queued, though the pull request is closed"
    ++ checkEq (queued.map (·.kleisNarrow)) #[["github: only discover, fetch"]]
      "with its token narrowed to cloning and fetching from GitHub"
    ++ check ((queued[0]?.map (·.toJson.getObjVal? "kleis_narrow" |>.isOk)).getD false)
      "the narrowing is in the request orchestra is sent"
    ++ checkEq (queued.map (·.checkout)) #[none] "no checkout, until orchestra takes one"
    ++ check (str withCheckout.toJson ["checkout"] == some jobHead)
      "a checkout, once set, is in the request"
    ++ checkEq job.headSha (some jobHead) "at the sample's commit"
    ++ checkEq job.baseSha (some mergeBase) "with its base"
    ++ checkEq job.kindRaw (some "calibration") "of the kind"
    ++ check (!has "pull/13/head" && !has "git fetch") "the prompt fetches nothing"
    ++ check (has "git show <headSha>:<path>") "it reads files at the commit"
    ++ check (has "never posted" && !has "posted, once accepted") "and is told it is not posted"
    ++ check ((reviewPrompt.splitOn "posted, once accepted").length > 1)
      "while a review's prompt says it is"
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
    ++ checkEq (str result ["score", "scope"]) (some "full") "a full sample"
    ++ checkEq (ratioOf result ["score", "precision"]) (some "0.5") "precision: one of two"
    ++ checkEq (ratioOf result ["score", "recall"]) (some "0.5") "recall: one of two"
    ++ checkEq (num result ["score", "matcherVersion"]) (some Score.matcherVersion)
      "the matcher's version"
    ++ checkEq ((result.getObjVal? "score").toOption.bind
      (·.getObjVal? "decision" |>.toOption) |>.bind (·.getObjValAs? Bool "agree" |>.toOption))
      (some true) "both asked for changes"
    ++ checkEq (items listed).length 0 "the job list is of reviews"
    ++ checkEq (items listedCal).length 1 "and lists calibration jobs when asked"

/-- Discovery neither makes a calibration job `stale` nor counts it as a review of its head;
    calibration jobs have a daily cap of their own per repository, which running one again
    charges; and one sample is reviewed by one live job at a time. -/
def calibrationJobsStandApart : Test := withTempDb do
  let f ← FakeHistory.new
  let svc ← services f (limits := { maxCalibrationJobsPerDay := 1, maxJobsPerDay := 1 })
  let st ← State.new cfg svc
  let _ ← imported st svc f
  let (s101, s201) := (← sampleId st 101, ← sampleId st 201)
  let both ← runOf st [s101, s201]
  let one ← runOf st [s201]
  let another ← runOf st [s101]
  let byCount ← route st (req .post s!"{repoPath}/calibration/runs" "{\"count\": 50}")
  let neither ← route st (req .post s!"{repoPath}/calibration/runs" "{}")
  let unknown ← runOf st ["nope"]
  -- #12, reopened at the head alice approved: discovery makes a review of it, and leaves the
  -- calibration job alone; then the pull request moves on, and still it is left alone.
  let _ ← putRepo st "{\"autoReview\": true}"
  f.gh.pulls.set #[{ number := 12, title := "More widgets", body := "", headSha := headB
                   , baseSha := base }]
  Workers.discover svc
  f.gh.pulls.set #[{ number := 12, title := "More widgets", body := "", headSha := jobHead
                   , baseSha := base }]
  Workers.discover svc
  let jobs ← Platform.jobsOfPull "acme" "widgets" 12
  let cal := jobs.filter (·.kind? == some .calibration)
  let reviews := jobs.filter (·.isReview)
  -- The job's run fails; running it again is a charge, past the cap of one, within one of three.
  let calId := (cal[0]?.map (·.id)).getD ""
  let _ ← Platform.updateJob calId fun j => return { j with statusRaw := "failed" }
  let some failed ← Platform.findJob calId | return #["the calibration job is gone"]
  let capped ← route st (req .post s!"/api/v1/jobs/{calId}/status"
    (statusBody "pending" failed.version))
  let roomy ← State.new cfg (← services f (limits := { maxCalibrationJobsPerDay := 3 }))
  let retried ← route roomy (req .post s!"/api/v1/jobs/{calId}/status"
    (statusBody "pending" failed.version))
  let busySample ← runOf roomy [s201]
  let thirdCharge ← runOf roomy [s101]
  -- It fails again, and a newer run picks its sample: running it again is refused.
  let _ ← Platform.updateJob calId fun j => return { j with statusRaw := "failed" }
  let some failedAgain ← Platform.findJob calId | return #["the calibration job is gone"]
  let roomier ← State.new cfg (← services f (limits := { maxCalibrationJobsPerDay := 10 }))
  let newerRun ← runOf roomier [s201]
  let sibling ← route roomier (req .post s!"/api/v1/jobs/{calId}/status"
    (statusBody "pending" failedAgain.version))
  let some stillFailed ← Platform.findJob calId | return #["the calibration job is gone"]
  return checkStatus both 429 "two jobs past a cap of one"
    ++ checkStatus one 201 "one job within it"
    ++ checkStatus another 429 "and none after"
    ++ checkStatus byCount 400 "more than 20 samples"
    ++ checkStatus neither 400 "a run of nothing"
    ++ checkStatus unknown 400 "a sample that is not one"
    ++ checkEq (cal.map (·.statusRaw)) #["pending"] "the calibration job, untouched"
    ++ checkEq (reviews.map (·.headSha)) #[some headB]
      "a review of the head, made though a calibration job is of it; the cap of reviews is its own"
    ++ checkStatus capped 429 "running a failed calibration job again, past the cap"
    ++ checkStatus retried 200 "and within it"
    ++ checkEq (field retried "status") (some "pending") "it is pending again"
    ++ checkStatus busySample 409 "a run of a sample a live job is reviewing"
    ++ checkStatus thirdCharge 201 "the third charge of three: the job and its retry count"
    ++ checkStatus newerRun 201 "a newer run of the failed job's sample"
    ++ checkStatus sibling 409 "running the old job again, beside the newer one"
    ++ checkEq stillFailed.statusRaw "failed" "which stays failed"
    ++ checkEq stillFailed.version failedAgain.version "untouched"

/-- With two active jobs of one commit, the agent may name only the one made last. -/
def aSupersededJobIsNotRun : Test := withTempDb do
  let gh ← FakeGitHub.new #[pull7 jobHead]
  let orch ← FakeOrchestra.new
  let svc ← Workers.Services.new (some gh.client) (some orch.client) (fun _ => pure ())
  let st ← State.new cfg svc
  let older ← newJob st
  -- Creation times are kept to the second.
  IO.sleep 1100
  let newer ← newJob st
  Workers.queuePending svc
  let naming (id : String) : Req :=
    let r := agentReq .get ""
    { r with header := fun n => if n == "x-diff-reviewer-job" then some id else r.header n }
  let byOlder ← route st (naming ((field older "id").getD ""))
  let byNewer ← route st (naming ((field newer "id").getD ""))
  return checkStatus byOlder 409 "the older job of the commit"
    ++ checkStatus byNewer 200 "the newer"

/-- Runs and the repository are aggregates of their jobs' scores, by run and by rubric version,
    of the samples not deleted; scoring again changes nothing; and a draft that cannot be scored is
    marked so, once. -/
def runsAreAggregated : Test := withTempDb do
  let f ← FakeHistory.new
  let orch ← FakeOrchestra.new
  let svc ← services f orch
  let st ← State.new cfg svc
  let _ ← imported st svc f
  let sid ← sampleId st 301
  let made ← runOf st [sid]
  let runId := (field made "id").getD ""
  Workers.queuePending svc
  let _ ← route st (agentReq .get "" (pr := 13))
  let _ ← route st (agentReq .post "/review" (submission jobHead agentReview) (pr := 13))
  let rescored ← Calibration.scorePending
  let runs ← route st (req .get s!"{repoPath}/calibration/runs")
  let summary ← route st (req .get s!"{repoPath}/calibration/summary")
  let missing ← route st (req .get s!"{repoPath}/calibration/runs/nope")
  let listed := (items runs).head?.getD .null
  let s := bodyJson summary
  let byVersion := ((s.getObjVal? "byRubricVersion").toOption.bind (·.getArr?.toOption)).getD #[]
  -- A draft that does not read.
  let bad ← runOf st [← sampleId st 201]
  let badJob := ((resultsOf bad).head?.bind (str · ["jobId"])).getD ""
  Store.run <| HasModel.save ({ job_id := badJob, version := 2, author := "agent"
                              , review := "{\"decision\": \"block\"", created_at := "x" }
                              : Store.RevisionRow)
  let unscorable ← Calibration.scorePending
  let unscorableAgain ← Calibration.scorePending
  let badRun ← route st (req .get s!"{repoPath}/calibration/runs/{(field bad "id").getD ""}")
  -- A later review of alice's of #13's commit joins the sample: its score is stale, as it was.
  f.reviews.modify (·.push (13, review 302 "alice" "COMMENTED" "And this." jobHead))
  f.comments.modify (·.push (13, comment 12 302 "RIGHT" 18 (commit := jobHead)))
  let _ ← importId st
  Calibration.importStep f.client svc.log 100
  let staleRun ← route st (req .get s!"{repoPath}/calibration/runs/{runId}")
  let staleResult := ((resultsOf staleRun).head?).getD .null
  let staleSummary := bodyJson (← route st (req .get s!"{repoPath}/calibration/summary"))
  let withStale := bodyJson (← route st
    { req .get s!"{repoPath}/calibration/summary" with query := "stale=include" })
  let badScore := ((resultsOf badRun).head?.bind (·.getObjVal? "score" |>.toOption)).getD .null
  -- Deleting the sample takes its score out of the aggregates, and marks it in the run.
  let _ ← route st (req .delete s!"{repoPath}/calibration/samples/{sid}")
  let summary' := bodyJson (← route st (req .get s!"{repoPath}/calibration/summary"))
  let run' ← route st (req .get s!"{repoPath}/calibration/runs/{runId}")
  let result' := ((resultsOf run').head?).getD .null
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
    ++ checkEq unscorable 1 "a draft that does not read, marked"
    ++ checkEq unscorableAgain 0 "once"
    ++ check (str badScore ["unscorable"]).isSome "the run says why"
    ++ checkEq ((staleResult.getObjValAs? Bool "scoreStale").toOption) (some true)
      "a score of a sample a later review joined is stale"
    ++ checkEq (ratioOf staleResult ["score", "precision"]) (some "0.5") "and left as it was"
    ++ checkEq (num staleSummary ["overall", "scored"]) (some 0) "left out of the summary"
    ++ checkEq (num staleSummary ["overall", "staleScores"]) (some 1) "which says so"
    ++ checkEq (num withStale ["overall", "scored"]) (some 1) "and in it when asked"
    ++ checkEq (num summary' ["overall", "scored"]) (some 0) "a deleted sample's score left out"
    ++ checkEq ((result'.getObjVal? "sample").toOption.bind
      (·.getObjValAs? Bool "deleted" |>.toOption)) (some true) "and marked in its run"
    ++ check (ratioOf result' ["score", "precision"]).isSome "which still shows its score"

/-- A post refused for GitHub's rate limit keeps its claim, as one whose outcome is unknown, and
    is free to be posted again once the claim is settled. -/
def aRateLimitedPostWaits : Test := withTempDb do
  let gh ← FakeGitHub.new #[pull7 jobHead]
  let svc ← Workers.Services.new (some gh.client) none (fun _ => pure ())
    { postClaimSeconds := 0 }
  let st ← State.new cfg svc
  let job ← newJob st
  let id := (field job "id").getD ""
  let drafted ← route st (req .put s!"/api/v1/jobs/{id}/review" (reviewBody 1 fine))
  let approved ← route st (req .post s!"/api/v1/jobs/{id}/status"
    (statusBody "approved" (versionOf drafted)))
  gh.outcome.set .rateLimited
  let refused ← route st (req .post s!"/api/v1/jobs/{id}/post"
    s!"\{\"version\": {versionOf approved}}")
  let some held ← Platform.findJob id | return #["the job is gone"]
  gh.outcome.set .ok
  Workers.settleClaims svc
  let some settled ← Platform.findJob id | return #["the job is gone"]
  let posted ← route st (req .post s!"/api/v1/jobs/{id}/post" s!"\{\"version\": {settled.version}}")
  return checkStatus refused 502 "a post refused for the rate limit"
    ++ checkEq held.statusRaw "approved" "the job"
    ++ check held.postStartedAt.isSome "keeps its claim"
    ++ check (held.error.any fun e => (e.splitOn "rate limit").length > 1) "and says why"
    ++ checkEq settled.postStartedAt none "settled, not found on GitHub: the claim is cleared"
    ++ checkStatus posted 200 "and it is posted"
    ++ checkEq (← gh.posted.get).size 1 "once"

def all : List (String × Test) :=
  [("trustedReviewersAreASetting", trustedReviewersAreASetting),
   ("commentsAreMatchedByPlace", commentsAreMatchedByPlace),
   ("theImportGroupsTrustedReviews", theImportGroupsTrustedReviews),
   ("theImportKeepsToItsBudget", theImportKeepsToItsBudget),
   ("stuckImportsMoveOn", stuckImportsMoveOn),
   ("calibrationJobsAreNeverPosted", calibrationJobsAreNeverPosted),
   ("calibrationJobsStandApart", calibrationJobsStandApart),
   ("aSupersededJobIsNotRun", aSupersededJobIsNotRun),
   ("runsAreAggregated", runsAreAggregated),
   ("aRateLimitedPostWaits", aRateLimitedPostWaits)]

end DiffReviewerTest.Calibration