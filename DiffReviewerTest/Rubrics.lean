import DiffReviewer
import DiffReviewerTest.Basic
import DiffReviewerTest.Server
import DiffReviewerTest.Workers
import DiffReviewerTest.FakeGit

open Lean (Json)
open DiffReviewer
open DiffReviewer.Server
open DiffReviewerTest.Server
open DiffReviewerTest.Workers
open DiffReviewerTest.FakeGit

/-!
# Rubrics, comment ids and a review's history

A repository's rubric, read from the rubrics repository at its branch's head and kept while a
head does not read; the agent reviewing by it at the commit its job is pinned to, and its
submission checked against it; comments that keep their ids and the fields this build does not
know; every write of a review in the job's history; and claims to post settled by the loop itself.
-/

namespace DiffReviewerTest.Rubrics

private def putRepo (st : State) (body : String) : IO Unit := do
  let _ ← route st (req .put "/api/v1/repos/acme/widgets" body)

/-- Commit `doc` (the fields of a rubric document) as `acme/widgets`'s rubric, and follow the
    branch once: the commit. -/
def setRubric (fg : FakeGit) (svc : Workers.Services) (doc : String) (notes : String := "") :
    IO String := do
  let sha ← fg.setRubric "acme" "widgets" s!"\{{doc}}" notes
  refresh svc
  return sha

/-- A document with two types: `feature`, with categories, and `docs`, without. -/
private def twoTypes : String :=
  "\"defaultRubric\": \"Check the proofs.\", \"prTypes\": [\
{\"name\": \"feature\", \"description\": \"New API\", \"rubric\": \"Look at the names.\", \
\"categories\": [{\"name\": \"correctness\", \"description\": \"Wrong\"}, {\"name\": \"style\"}]}, \
{\"name\": \"docs\", \"description\": \"Documentation only\"}]"

/-- One comment on `A.lean`, line 3, with the extra JSON fields `more`. -/
private def withComment (more : String := "") : String :=
  s!"\{\"decision\": \"comment\", \"body\": \"One thing.\", \"comments\": [\{\"file\": \"A.lean\", \
\"start_line\": 3, \"end_line\": 3, \"body\": \"x\"{more}}]}"

private def job! (id : String) : IO Job := do
  let some j ← Platform.findJob id | throw (.userError s!"job {id} is gone")
  return j

private def commentsOf (r : Reply) : List Json :=
  ((((bodyJson r).getObjVal? "review").bind (·.getObjVal? "comments")).bind (·.getArr?)).toOption
    |>.map (·.toList) |>.getD []

private def strOf (j : Json) (k : String) : Option String := (j.getObjValAs? String k).toOption

private def itemsOf (r : Reply) : List Json :=
  (((bodyJson r).getObjVal? "items").bind (·.getArr?)).toOption.map (·.toList) |>.getD []

/-- A comment keeps its id, gets one when it has none, and a review and its comments keep the
    fields this build does not know; a severity it does not know makes the review unreadable. -/
def commentsKeepTheirIdsAndUnknownFields : Test := do
  let raw := "{\"decision\": \"comment\", \"body\": \"b\", \"reviewer_note\": {\"k\": 1}, \
\"comments\": [{\"file\": \"A.lean\", \"start_line\": 1, \"end_line\": 2, \"body\": \"x\", \
\"id\": \"keep-me\", \"severity\": \"minor\", \"category\": \"style\", \"resolved\": true}, \
{\"file\": \"A.lean\", \"start_line\": 4, \"end_line\": 4, \"body\": \"y\"}]}"
  let .ok r := Review.ofJsonString raw | return #["the review did not parse"]
  let r' ← r.assignIds
  let back := (Json.parse r'.toJson.compress).toOption.getD .null
  let comments := ((back.getObjVal? "comments").bind (·.getArr?)).toOption.getD #[]
  let ids := r'.comments.map (·.id)
  let withId (id : String) : Review :=
    { r' with comments := r'.comments.map fun (c : InlineComment) => { c with id := some id } }
  let dup := withId "same"
  let badId := withId "a b"
  let unknownSeverity := Review.ofJsonString
    "{\"decision\": \"comment\", \"body\": \"b\", \"comments\": [{\"file\": \"A.lean\", \
\"start_line\": 1, \"end_line\": 1, \"body\": \"x\", \"severity\": \"critical\"}]}"
  let reread := Review.ofJsonString r'.toJsonString
  return checkEq (ids.headD none) (some "keep-me") "the id it had"
    ++ check (ids.getLast?.any (·.any validCommentId)) "an id for the comment without"
    ++ checkEq (r.comments.getLast?.bind (·.id)) none "no id on the review as read"
    ++ check ((back.getObjVal? "reviewer_note").isOk) "the review's unknown field"
    ++ checkEq ((comments[0]?.bind (·.getObjValAs? Bool "resolved" |>.toOption))) (some true)
      "the comment's unknown field"
    ++ checkEq ((comments[0]?.bind (strOf · "severity"))) (some "minor") "the severity"
    ++ checkEq ((comments[0]?.bind (strOf · "category"))) (some "style") "the category"
    ++ check (reread matches .ok _) "the review reads back"
    ++ check ((reread.toOption.map (· == r')).getD false) "and is the same review"
    ++ check (r'.validate matches .ok ()) "a review with ids"
    ++ check (dup.validate matches .error _) "two comments with one id"
    ++ check (badId.validate matches .error _) "an id with a space"
    ++ check (unknownSeverity matches .error _) "a severity this build does not know"
    ++ check (r'.checkCategories ["correctness"] matches .error _) "a category not allowed"
    ++ check (r'.checkCategories [] matches .ok ()) "free text when there are none"

/-- A repository's rubric is its directory in the rubrics repository, at the head of its branch:
    none before the repository has a branch (an empty one), said once; then each head as it moves,
    its history of the commits that changed the directory, any commit's rubric, and a compare of
    two. Nothing writes it: there is no `PUT`. -/
def rubricsAreReadFromGit : Test := withTempDb do
  let fg ← FakeGit.new
  let logs ← IO.mkRef #[]
  let svc := fg.attach (← Workers.Services.new (log := fun m => logs.modify (·.push m)))
  let st ← State.new cfg svc
  let unconfigured ← State.new cfg
  let unregistered ← route st (req .get "/api/v1/repos/acme/widgets/rubrics")
  putRepo st "{}"
  let none_ ← route unconfigured (req .get "/api/v1/repos/acme/widgets/rubrics")
  -- An empty repository: no branch, no rubric, said once.
  refresh svc
  refresh svc
  let empty ← route st (req .get "/api/v1/repos/acme/widgets/rubrics")
  let emptyHistory ← route st (req .get "/api/v1/repos/acme/widgets/rubrics/history")
  let saidEmpty := (← logs.get).filter fun m => (m.splitOn "has no branch main").length > 1
  let first ← setRubric fg svc twoTypes
  let atFirst ← route st (req .get "/api/v1/repos/Acme/Widgets/rubrics")
  -- Another repository's directory changing leaves this one's history alone.
  let _ ← fg.change [("other/repo/rubric.md", some "Other.\n")]
  let second ← setRubric fg svc "\"defaultRubric\": \"Be brief.\"" (notes := "One sentence.")
  let current ← route st (req .get "/api/v1/repos/acme/widgets/rubrics")
  let history ← route st (req .get "/api/v1/repos/acme/widgets/rubrics/history")
  let old ← route st (req .get s!"/api/v1/repos/acme/widgets/rubrics/commits/{first}")
  let cmp ← route st { req .get "/api/v1/repos/acme/widgets/rubrics/compare" with
                       query := s!"base={first}&head={second}" }
  let put ← route st (req .put "/api/v1/repos/acme/widgets/rubrics" "{\"version\": 0}")
  let badSha ← route st (req .get "/api/v1/repos/acme/widgets/rubrics/commits/abc")
  let shas := (itemsOf history).map (strOf · "sha")
  let types (r : Reply) := ((bodyJson r).getObjVal? "prTypes").toOption.bind (·.getArr?.toOption)
  let files := ((bodyJson current).getObjVal? "files").toOption.bind (·.getArr?.toOption)
  let d := ((bodyJson cmp).getObjVal? "diff").toOption.getD .null
  return checkStatus unregistered 404 "the rubric of a repository nobody registered"
    ++ checkStatus none_ 200 "with no rubrics repository configured"
    ++ check ((bodyJson none_).getObjVal? "repository" matches .ok .null) "said so"
    ++ checkStatus empty 200 "an empty rubrics repository"
    ++ checkEq (field empty "sha") none "no commit"
    ++ check (((bodyJson empty).getObjVal? "error").toOption.bind (strOf · "message") |>.any
      fun m => (m.splitOn "has no branch main").length > 1) "why, in the answer"
    ++ checkEq saidEmpty.size 1 "and in the log, once"
    ++ checkEq (itemsOf emptyHistory).length 0 "no history"
    ++ checkEq (field atFirst "sha") (some first) "the first commit, in use"
    ++ checkEq ((types atFirst).map (·.size)) (some 2) "its types"
    ++ checkEq (field current "sha") (some second) "the head, in use"
    ++ checkEq (field current "defaultRubric") (some "Be brief.") "the current document"
    ++ checkEq (field current "styleNotes") (some "One sentence.") "the style notes, from style.md"
    ++ checkEq ((files.map (·.size))) (some 2) "its files, rubric.md and style.md"
    ++ check (((files.bind (·[0]?)).bind (strOf · "editUrl")).any fun u =>
      u == "https://github.com/chrisflav/review-rubrics/edit/main/acme/widgets/rubric.md")
      "each with where to edit it"
    ++ checkEq shas [some second, some first] "the history, the commits of the directory only"
    ++ checkEq ((types old).map (·.size)) (some 2) "an older commit's rubric"
    ++ checkStatus cmp 200 "a compare"
    ++ checkEq ((d.getObjVal? "defaultRubric").toOption.bind (strOf · "after")) (some "Be brief.")
      "what changed"
    ++ checkEq (((d.getObjVal? "typesRemoved").toOption.bind (·.getArr?.toOption)).map (·.size))
      (some 2) "the types removed"
    ++ checkStatus put 405 "no write"
    ++ checkStatus badSha 400 "a commit that is not a whole id"

/-- A head that does not read is not used: the last that did stays in use, and the errors are
    shown with their files and lines; once fixed, the head is used again. A review waits while no
    head has ever read. -/
def aBrokenHeadKeepsTheLastGood : Test := withTempDb do
  let fg ← FakeGit.new
  let svc := fg.attach (← Workers.Services.new (log := fun _ => pure ()))
  let st ← State.new cfg svc
  putRepo st "{}"
  let good ← setRubric fg svc twoTypes
  let broken ← fg.change [("acme/widgets/types/bad.md",
    some "---\ndescription: fine\ncategories: [\n---\nBody.\n")]
  refresh svc
  let shown ← route st (req .get "/api/v1/repos/acme/widgets/rubrics")
  let err := ((bodyJson shown).getObjVal? "error").toOption.getD .null
  let pin ← Rubrics.pinFor "acme" "widgets"
  let fixed ← fg.change [("acme/widgets/types/bad.md",
    some "---\ndescription: fine\ncategories:\n  a: b\n---\nBody.\n")]
  refresh svc
  let after ← route st (req .get "/api/v1/repos/acme/widgets/rubrics")
  return checkEq (field shown "sha") (some good) "the last good commit, still in use"
    ++ checkEq (field shown "headSha") (some broken) "beside the head"
    ++ checkEq (strOf err "file") (some "acme/widgets/types/bad.md") "the file"
    ++ checkEq ((err.getObjValAs? Nat "line").toOption) (some 3) "the line"
    ++ checkEq pin (some good) "what a job is pinned to"
    ++ checkEq (field after "sha") (some fixed) "fixed, the head is used"
    ++ check ((bodyJson after).getObjVal? "error" matches .ok .null) "and nothing is wrong"

/-- The agent is given the rubric and reviews by it: its submission names one of the types, files
    its comments under that type's categories, and the job records both and the rubric's version;
    its comments are given ids, and its review is the first revision of the job. -/
def theAgentReviewsByTheRubric : Test := withTempDb do
  let gh ← FakeGitHub.new #[pull7]
  let orch ← FakeOrchestra.new
  let logs ← IO.mkRef #[]
  let fg ← FakeGit.new
  let svc := fg.attach (← services gh orch logs)
  let st ← State.new cfg svc
  putRepo st "{}"
  let pinned ← setRubric fg svc twoTypes
  let created ← route st (req .post "/api/v1/jobs"
    s!"\{\"owner\": \"acme\", \"name\": \"widgets\", \"prNumber\": 7, \"headSha\": \"{headA}\"}")
  let id := (field created "id").getD ""
  Workers.queuePending svc
  let prompt := ((← orch.queued.get)[0]?.map (·.prompt)).getD ""
  -- The head moves while the job runs: its agent still reads the commit it was pinned to.
  let moved ← setRubric fg svc "\"defaultRubric\": \"Something else.\""
  let shown ← routeAgent st (agentReq .get "")
  let types := (((bodyJson shown).getObjVal? "prTypes").bind (·.getArr?)).toOption.getD #[]
  let feature := types[0]?.getD .null
  let categories := ((feature.getObjVal? "categories").bind (·.getArr?)).toOption.getD #[]
  let tagged := withComment ", \"category\": \"correctness\", \"severity\": \"major\""
  let noType ← routeAgent st (agentReq .post "/review" (submission headA tagged))
  let otherType ← routeAgent st (agentReq .post "/review"
    (submission headA tagged (prType := "\"refactor\"")))
  let wrongCategory ← routeAgent st (agentReq .post "/review" (submission headA
    (withComment ", \"category\": \"naming\"") (prType := "\"feature\"")))
  let badSeverity ← routeAgent st (agentReq .post "/review" (submission headA
    (withComment ", \"severity\": \"critical\"") (prType := "\"feature\"")))
  let submitted ← routeAgent st (agentReq .post "/review"
    (submission headA tagged (prType := "\"feature\"")))
  let job ← route st (req .get s!"/api/v1/jobs/{id}")
  let comment := (commentsOf job).headD .null
  let revisions ← route st (req .get s!"/api/v1/jobs/{id}/revisions")
  let revs := itemsOf revisions
  let instructions := (field shown "instructions").getD ""
  let mentions (s t : String) := (s.splitOn t).length > 1
  return checkStatus shown 200 "the agent's read"
    ++ check (mentions instructions "Check the proofs.") "the default rubric in the instructions"
    ++ check (mentions instructions "severity") "the instructions ask for severities"
    ++ checkEq types.size 2 "the pull request types"
    ++ checkEq (strOf feature "rubric") (some "Look at the names.") "a type's rubric"
    ++ checkEq categories.size 2 "a type's categories"
    ++ checkEq (field shown "rubricSha") (some pinned) "the commit the job is pinned to"
    ++ check (moved != pinned && !mentions instructions "Something else.")
      "not the head the branch moved to"
    ++ check (mentions prompt "prTypes") "the prompt says to pick a type"
    ++ check (mentions prompt "severity") "the prompt says to give severities"
    ++ checkStatus noType 400 "no type, where the rubric names types"
    ++ checkStatus otherType 400 "a type the rubric does not name"
    ++ checkStatus wrongCategory 400 "a category the type does not name"
    ++ checkStatus badSeverity 400 "a severity that is not one"
    ++ checkStatus submitted 200 "the submission"
    ++ checkEq (field job "prType") (some "feature") "the job's type"
    ++ checkEq (field job "rubricSha") (some pinned) "the job's rubric commit"
    ++ check ((strOf comment "id").any validCommentId) "the comment's id"
    ++ checkEq (strOf comment "category") (some "correctness") "the comment's category"
    ++ checkEq (strOf comment "severity") (some "major") "the comment's severity"
    ++ checkEq (revs.map (strOf · "author")) [some "agent"] "the history: the agent's draft"
    ++ checkEq (revs.map (·.getObjValAs? Nat "version" |>.toOption)) [some (versionOf job)]
      "at the job's version"

/-- Every write of a review is in the job's history: the agent's draft, each person's edit — which
    keeps the ids of the comments it keeps — and what GitHub holds once posted. -/
def everyWriteIsARevision : Test := withTempDb do
  let gh ← FakeGitHub.new #[pull7]
  let orch ← FakeOrchestra.new
  let logs ← IO.mkRef #[]
  let svc ← services gh orch logs
  let st ← State.new cfg svc
  putRepo st "{}"
  let created ← route st (req .post "/api/v1/jobs"
    s!"\{\"owner\": \"acme\", \"name\": \"widgets\", \"prNumber\": 7, \"headSha\": \"{headA}\"}")
  let id := (field created "id").getD ""
  Workers.queuePending svc
  let _ ← routeAgent st (agentReq .get "")
  let _ ← routeAgent st (agentReq .post "/review"
    (submission headA (withComment ", \"category\": \"anything at all\"")))
  let drafted ← route st (req .get s!"/api/v1/jobs/{id}")
  let agentId := ((commentsOf drafted).headD .null |> (strOf · "id")).getD ""
  let edited ← route st (req .put s!"/api/v1/jobs/{id}/review" (reviewBody (versionOf drafted)
    s!"\{\"decision\": \"request_changes\", \"body\": \"Two things.\", \"comments\": [\
\{\"file\": \"A.lean\", \"start_line\": 3, \"end_line\": 3, \"body\": \"x, sharper\", \
\"id\": \"{agentId}\"}, \{\"file\": \"A.lean\", \"start_line\": 5, \"end_line\": 5, \
\"body\": \"and this\"}]}"))
  let editedIds := (commentsOf edited).map (strOf · "id")
  let approved ← route st (req .post s!"/api/v1/jobs/{id}/status"
    (statusBody "approved" (versionOf edited)))
  let posted ← route st (req .post s!"/api/v1/jobs/{id}/post"
    s!"\{\"version\": {versionOf approved}}")
  let revisions ← route st (req .get s!"/api/v1/jobs/{id}/revisions")
  let revs := itemsOf revisions
  let missing ← route st (req .get "/api/v1/jobs/nope/revisions")
  let githubRev := (revs.getLast?.bind (·.getObjVal? "review" |>.toOption)).getD .null
  return checkStatus edited 200 "a person's edit"
    ++ checkEq (editedIds.headD none) (some agentId) "the kept comment keeps its id"
    ++ check (editedIds.getLast?.join.any (· != agentId)) "the new comment has its own"
    ++ checkStatus posted 200 "posting"
    ++ checkEq (revs.map (strOf · "author")) [some "agent", some "person", some "github"]
      "the history"
    ++ checkEq (strOf githubRev "body") (some "Two things.") "GitHub's body, without the marker"
    ++ checkEq (strOf githubRev "decision") (some "request_changes") "the event it was posted as"
    ++ checkStatus missing 404 "the history of no job"

/-- A review stored before comments had ids is shown as stored, and gets ids on its next write. -/
def oldReviewsGetIdsWhenWritten : Test := withTempDb do
  let st ← State.new cfg
  let job ← newJob st
  let id := (field job "id").getD ""
  let old := "{\"decision\":\"comment\",\"body\":\"Old.\",\"comments\":[{\"file\":\"A.lean\",\
\"start_line\":1,\"end_line\":1,\"body\":\"x\"}]}"
  let _ ← Platform.updateJob id fun j => return { j with reviewRaw := some old
                                                         statusRaw := "draft" }
  let read ← route st (req .get s!"/api/v1/jobs/{id}")
  let afterRead ← job! id
  let written ← route st (req .put s!"/api/v1/jobs/{id}/review" (reviewBody (versionOf read)
    ((bodyJson read).getObjVal? "review" |>.toOption |>.getD .null).compress))
  return checkEq ((commentsOf read).map (strOf · "id")) [none] "no id when read"
    ++ checkEq afterRead.reviewRaw (some old) "the stored review, untouched by reading"
    ++ checkStatus written 200 "writing it back"
    ++ check ((commentsOf written).all fun c => (strOf c "id").isSome) "ids, once written"

/-- A person's edit is held to the rubric too: a category of the job's type, and free text where
    the rubric names none. -/
def editsAreCheckedAgainstTheRubric : Test := withTempDb do
  let fg ← FakeGit.new
  let svc := fg.attach (← Workers.Services.new (log := fun _ => pure ()))
  let st ← State.new cfg svc
  let job ← newJob st
  let id := (field job "id").getD ""
  let free ← route st (req .put s!"/api/v1/jobs/{id}/review"
    (reviewBody 1 (withComment ", \"category\": \"whatever\"")))
  let _ ← setRubric fg svc twoTypes
  let unknown ← route st (req .put s!"/api/v1/jobs/{id}/review"
    (reviewBody (versionOf free) (withComment ", \"category\": \"whatever\"")))
  let known ← route st (req .put s!"/api/v1/jobs/{id}/review"
    (reviewBody (versionOf free) (withComment ", \"category\": \"style\"")))
  return checkStatus free 200 "free text, with no rubric"
    ++ checkStatus unknown 400 "a category no type names"
    ++ checkStatus known 200 "one a type names"

/-- The loop settles a claim past its window by itself, as `reconcile` would, and says so: found,
    the job is posted; not found, it is free again. A failure to tell is written once. -/
def claimsSettleThemselves : Test := withTempDb do
  let gh ← FakeGitHub.new #[pull7 jobHead]
  let logs ← IO.mkRef #[]
  let svc ← services gh none logs
  let st ← State.new cfg svc
  let approvedJob : IO (String × Nat) := do
    let job ← newJob st
    let id := (field job "id").getD ""
    let drafted ← route st (req .put s!"/api/v1/jobs/{id}/review" (reviewBody 1 fine))
    let approved ← route st (req .post s!"/api/v1/jobs/{id}/status"
      (statusBody "approved" (versionOf drafted)))
    return (id, versionOf approved)
  let post (id : String) (v : Nat) : IO Unit := do
    let _ ← route st (req .post s!"/api/v1/jobs/{id}/post" s!"\{\"version\": {v}}")
  let age (id : String) : IO Unit := do
    let _ ← Platform.updateJob id fun j =>
      return { j with postStartedAt := some "2000-01-01T00:00:00Z" }
  -- Posted, the answer lost and the reviews unreadable: the claim stands.
  let (a, va) ← approvedJob
  gh.outcome.set .lostAnswer
  gh.listFails.set true
  post a va
  -- Not posted (a 5xx): the claim stands too.
  let (b, vb) ← approvedJob
  gh.outcome.set .failedUnposted
  post b vb
  -- A claim within its window is left alone.
  Workers.settleClaims svc
  let aWithin ← job! a
  age a
  age b
  Workers.settleClaims svc
  let aUnclear ← job! a
  Workers.settleClaims svc
  let aUnclear2 ← job! a
  gh.listFails.set false
  Workers.tick svc
  let aSettled ← job! a
  let bSettled ← job! b
  let said := (← logs.get).filter (·.startsWith "settled ")
  return check aWithin.postStartedAt.isSome "a claim within its window"
    ++ checkEq aUnclear.statusRaw "approved" "reviews that cannot be read"
    ++ check aUnclear.postStartedAt.isSome "the claim stands"
    ++ checkEq aUnclear2.version aUnclear.version "the failure, written once"
    ++ checkEq aSettled.statusRaw "posted" "found: posted"
    ++ checkEq bSettled.statusRaw "approved" "not found: still approved"
    ++ checkEq bSettled.postStartedAt none "and free"
    ++ checkEq said.size 2 "both logged"
    ++ checkEq (← gh.posted.get).size 1 "and nothing posted by settling"

/-- A rubric's files keep the front-matter keys this build does not know — of `rubric.md`, a
    type's file and a category written as a mapping — and show them; the agent is given them as
    the document's own fields. -/
def rubricsKeepUnknownFields : Test := withTempDb do
  let fg ← FakeGit.new
  let svc := fg.attach (← Workers.Services.new (log := fun _ => pure ()))
  let st ← State.new cfg svc
  putRepo st "{}"
  let _ ← fg.change [
    ("acme/widgets/rubric.md", some "---\ntone: terse\n---\nd\n"),
    ("acme/widgets/types/feature.md", some "---\nweight: 2\ncategories:\n  style:\n    \
description: Style\n    color: red\n---\nLook.\n")]
  refresh svc
  let read ← route st (req .get "/api/v1/repos/acme/widgets/rubrics")
  let ty := (((bodyJson read).getObjVal? "prTypes").toOption.bind (·.getArr?.toOption) |>.bind
    (·[0]?)).getD .null
  let cat := (((ty.getObjVal? "categories").bind (·.getArr?)).toOption.bind (·[0]?)).getD .null
  -- Written back as files, they read as they were.
  let doc := (Rubric.ofJson (bodyJson read) (ignore := Rubrics.viewFields)).toOption.getD {}
  let again := RubricFiles.parseDir (RubricFiles.render doc)
  return checkEq (field read "tone") (some "terse") "the document's unknown key"
    ++ checkEq ((ty.getObjValAs? Nat "weight").toOption) (some 2) "a type's"
    ++ checkEq (strOf cat "color") (some "red") "a category's"
    ++ checkEq (strOf cat "description") (some "Style") "beside its description"
    ++ check ((again.toOption.map (·.rubric == doc)).getD false) "rendered and read again, the same"
    ++ check ((doc.extra.lookup "owner").isNone && (doc.extra.lookup "sha").isNone)
      "the answer's own fields are not the document's"

/-- A `direct` repository with a running job of pull request 7; answers the job's id. -/
private def directJob (st : State) (svc : Workers.Services) : IO String := do
  putRepo st "{\"mode\": \"direct\"}"
  let created ← route st (req .post "/api/v1/jobs"
    s!"\{\"owner\": \"acme\", \"name\": \"widgets\", \"prNumber\": 7, \"headSha\": \"{headA}\"}")
  Workers.queuePending svc
  let _ ← routeAgent st (agentReq .get "")
  return (field created "id").getD ""

private def ageClaim (id : String) : IO Unit := do
  let _ ← Platform.updateJob id fun j =>
    if j.postStartedAt.isSome then return { j with postStartedAt := some "2000-01-01T00:00:00Z" }
    else return j

/-- In a `direct` repository, a review settling finds never reached GitHub is posted again, as a
    comment, by the loop: here the second post reaches it. -/
def aDirectPostIsRetried : Test := withTempDb do
  let gh ← FakeGitHub.new #[pull7]
  let orch ← FakeOrchestra.new
  let logs ← IO.mkRef #[]
  let svc ← services gh orch logs
  let st ← State.new cfg svc
  let id ← directJob st svc
  gh.outcome.set .failedUnposted
  let submitted ← routeAgent st (agentReq .post "/review" (submission headA
    (review := "{\"decision\": \"request_changes\", \"body\": \"No.\", \"comments\": []}")))
  let first ← job! id
  gh.outcome.set .ok
  ageClaim id
  Workers.settleClaims svc
  let after ← job! id
  let posted ← gh.posted.get
  return checkEq (field submitted "status") (some "approved") "the first post failed"
    ++ check first.postStartedAt.isSome "its claim stands"
    ++ checkEq first.directPosts 1 "one post by the platform"
    ++ checkEq after.statusRaw "posted" "posted again by the loop"
    ++ checkEq after.directPosts 2 "the second"
    ++ checkEq (posted.map (·.2.2.2)) #[some .comment] "as a comment"
    ++ check ((← logs.get).any (·.startsWith s!"posted job {id} again")) "and logged"

/-- At most `maxDirectPostAttempts` posts of a `direct` job in all; then it is left `approved`,
    free, with why, and that is logged once. -/
def aDirectPostIsRetriedAtMostThrice : Test := withTempDb do
  let gh ← FakeGitHub.new #[pull7]
  let orch ← FakeOrchestra.new
  let logs ← IO.mkRef #[]
  let svc ← services gh orch logs
  let st ← State.new cfg svc
  let id ← directJob st svc
  gh.outcome.set .failedUnposted
  let _ ← routeAgent st (agentReq .post "/review" (submission headA))
  for _ in [0:5] do
    ageClaim id
    Workers.settleClaims svc
  let after ← job! id
  let gaveUp := (← logs.get).filter fun m => (m.splitOn "the most the platform tries").length > 1
  return checkEq after.statusRaw "approved" "left approved"
    ++ checkEq after.postStartedAt none "without a claim"
    ++ checkEq after.directPosts 3 "after three posts"
    ++ check (after.error.any fun e => (e.splitOn "3 times").length > 1)
      s!"saying why: {after.error}"
    ++ checkEq gaveUp.size 1 "logged once"
    ++ checkEq (← gh.posted.get).size 0 "nothing reached GitHub"

/-- Before posting a `direct` review again the pull request is read: moved on from the job's
    head, or closed, the job is `stale` and nothing is posted. -/
def aDirectRepostChecksThePull : Test := withTempDb do
  let gh ← FakeGitHub.new #[pull7]
  let orch ← FakeOrchestra.new
  let logs ← IO.mkRef #[]
  let svc ← services gh orch logs
  let st ← State.new cfg svc
  let id ← directJob st svc
  gh.outcome.set .failedUnposted
  let _ ← routeAgent st (agentReq .post "/review" (submission headA))
  gh.outcome.set .ok
  gh.pulls.set #[pull7 headB]
  ageClaim id
  Workers.settleClaims svc
  let movedOn ← job! id
  -- A closed pull request, at the job's head.
  let some j ← Platform.findJob id | return #["gone"]
  let _ ← Platform.updateJob id fun _ =>
    return { j with statusRaw := "approved", postDirect := true, error := none }
  gh.pulls.set #[{ pull7 with state := "closed" }]
  Workers.settleClaims svc
  let closed ← job! id
  return checkEq movedOn.statusRaw "stale" "moved on: stale"
    ++ check (movedOn.error.any fun e => (e.splitOn "moved on").length > 1) "saying why"
    ++ checkEq closed.statusRaw "stale" "closed: stale"
    ++ checkEq (← gh.posted.get).size 0 "nothing posted"

/-- What a person starts is theirs: a person's post of a `direct` job is not retried by the
    platform, nor counted among its posts. -/
def aPersonsPostIsNotRetried : Test := withTempDb do
  let gh ← FakeGitHub.new #[pull7]
  let orch ← FakeOrchestra.new
  let logs ← IO.mkRef #[]
  let svc ← services gh orch logs
  let st ← State.new cfg svc
  let id ← directJob st svc
  gh.outcome.set .failedUnposted
  let _ ← routeAgent st (agentReq .post "/review" (submission headA))
  ageClaim id
  -- The person posts: the earlier claim is settled, and the person's own post fails too.
  let _ ← route st (req .post s!"/api/v1/jobs/{id}/post" s!"\{\"version\": {(← job! id).version}}")
  let afterPerson ← job! id
  gh.outcome.set .ok
  ageClaim id
  Workers.settleClaims svc
  Workers.settleClaims svc
  let after ← job! id
  return checkEq afterPerson.directPosts 1 "the person's post is not counted"
    ++ checkEq afterPerson.postDirect false "and is not the platform's"
    ++ checkEq after.statusRaw "approved" "settled, and not posted again"
    ++ checkEq after.postStartedAt none "free"
    ++ checkEq (← gh.posted.get).size 0 "nothing posted by the platform"

/-- A job reviewed against no rubric records version 0; categories are checked only where the
    edit adds or changes one; a picked type with no categories takes free text; the history
    keeps the first draft and the last `maxRevisions`; pages; and a rubric this build cannot read
    is not overwritten, nor a `null` stored. -/
def rubricEdgesAreHeld : Test := withTempDb do
  let gh ← FakeGitHub.new #[pull7]
  let orch ← FakeOrchestra.new
  let logs ← IO.mkRef #[]
  let fg ← FakeGit.new
  let svc := fg.attach (← services gh orch logs)
  let st ← State.new cfg svc
  putRepo st "{}"
  -- An empty rubrics repository, read: no rubric.
  refresh svc
  let created ← route st (req .post "/api/v1/jobs"
    s!"\{\"owner\": \"acme\", \"name\": \"widgets\", \"prNumber\": 7, \"headSha\": \"{headA}\"}")
  let id := (field created "id").getD ""
  Workers.queuePending svc
  let _ ← routeAgent st (agentReq .get "")
  let _ ← routeAgent st (agentReq .post "/review"
    (submission headA (withComment ", \"category\": \"legacy\"")))
  let noRubric ← job! id
  -- A rubric with categories now: the job was reviewed against none, so free text still holds.
  let _ ← setRubric fg svc twoTypes
  let freeStill ← route st (req .put s!"/api/v1/jobs/{id}/review"
    (reviewBody noRubric.version (withComment ", \"category\": \"invented\"")))
  -- A job from before rubrics, against the current one: an unchanged category stands.
  let some j ← Platform.findJob id | return #["gone"]
  let old := "{\"decision\":\"comment\",\"body\":\"Old.\",\"comments\":[{\"file\":\"A.lean\",\
\"start_line\":3,\"end_line\":3,\"body\":\"x\",\"id\":\"c1\",\"category\":\"legacy\"}]}"
  let _ ← Platform.updateJob id fun _ =>
    return { j with rubricVersion := none, reviewRaw := some old, statusRaw := "draft" }
  let v := (← job! id).version
  let kept ← route st (req .put s!"/api/v1/jobs/{id}/review" (reviewBody v
    (withComment ", \"id\": \"c1\", \"category\": \"legacy\"")))
  let changed ← route st (req .put s!"/api/v1/jobs/{id}/review" (reviewBody (versionOf kept)
    (withComment ", \"id\": \"c1\", \"category\": \"bogus\"")))
  let added ← route st (req .put s!"/api/v1/jobs/{id}/review" (reviewBody (versionOf kept)
    (withComment ", \"category\": \"legacy\"")))
  -- The history, bounded and paged.
  for _ in [0:Platform.maxRevisions + 5] do
    let _ ← Platform.updateJob id (revision := Job.revisionBy .person) fun j => return j
  let revs ← Platform.revisions id
  let page1 ← route st { req .get s!"/api/v1/jobs/{id}/revisions" with query := "limit=2" }
  let badLimit ← route st { req .get s!"/api/v1/jobs/{id}/revisions" with query := "limit=0" }
  let doc : Rubric := match Rubric.ofJson ((Json.parse s!"\{{twoTypes}}").toOption.getD .null) with
    | .ok d => d
    | .error _ => {}
  let r : GitHub.PostedReview := { id := 1, body := "b", url := "u", state := "COMMENTED" }
  let posted := (Json.parse (Workers.postedRevision noRubric r (some .approve))).toOption.getD .null
  return checkEq noRubric.rubricVersion (some 0) "reviewed against no rubric: version 0"
    ++ checkStatus freeStill 200 "free text for a job reviewed against no rubric"
    ++ checkStatus kept 200 "an unchanged category the rubric does not name"
    ++ checkStatus changed 400 "a changed one"
    ++ checkStatus added 400 "a new one"
    ++ checkEq (doc.categoriesFor (some "docs")) [] "a type without categories: free text"
    ++ checkEq (doc.categoriesFor (some "feature")) ["correctness", "style"] "a type's own"
    ++ checkEq (doc.categoriesFor none) ["correctness", "style"] "no type: the document's"
    ++ checkEq revs.size (Platform.maxRevisions + 1) "the history, bounded"
    ++ checkEq (revs[0]?.map (·.author)) (some "agent") "the first draft kept"
    ++ checkEq (revs.back?.map (·.version)) (some (← job! id).version) "and the latest"
    ++ checkEq (itemsOf page1).length 2 "a page"
    ++ checkEq ((bodyJson page1).getObjValAs? Nat "nextOffset").toOption (some 2) "the next one"
    ++ checkStatus badLimit 400 "a limit of 0"
    ++ checkEq (strOf posted "decision") (some "comment") "the decision GitHub's state says"

def all : List (String × Test) :=
  [("commentsKeepTheirIdsAndUnknownFields", commentsKeepTheirIdsAndUnknownFields),
   ("rubricsAreReadFromGit", rubricsAreReadFromGit),
   ("aBrokenHeadKeepsTheLastGood", aBrokenHeadKeepsTheLastGood),
   ("theAgentReviewsByTheRubric", theAgentReviewsByTheRubric),
   ("everyWriteIsARevision", everyWriteIsARevision),
   ("oldReviewsGetIdsWhenWritten", oldReviewsGetIdsWhenWritten),
   ("editsAreCheckedAgainstTheRubric", editsAreCheckedAgainstTheRubric),
   ("claimsSettleThemselves", claimsSettleThemselves),
   ("rubricsKeepUnknownFields", rubricsKeepUnknownFields),
   ("aDirectPostIsRetried", aDirectPostIsRetried),
   ("aDirectPostIsRetriedAtMostThrice", aDirectPostIsRetriedAtMostThrice),
   ("aDirectRepostChecksThePull", aDirectRepostChecksThePull),
   ("aPersonsPostIsNotRetried", aPersonsPostIsNotRetried),
   ("rubricEdgesAreHeld", rubricEdgesAreHeld)]

end DiffReviewerTest.Rubrics