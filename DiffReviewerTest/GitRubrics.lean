import DiffReviewer
import DiffReviewerTest.Basic
import DiffReviewerTest.Server
import DiffReviewerTest.Workers
import DiffReviewerTest.Calibration
import DiffReviewerTest.Fanout
import DiffReviewerTest.Style
import DiffReviewerTest.FakeGit

open Lean (Json)
open DiffReviewer
open DiffReviewer.Server
open DiffReviewerTest.Server
open DiffReviewerTest.Workers
open DiffReviewerTest.FakeGit

/-!
# Rubrics in git

The files a rubric is written as — their front matter read, with every error placed at its file
and line, unknown keys kept, and written back as they read — the check of a checkout the rubrics
repository's CI runs, the export of the old database as a history with its mapping, read back so
that old jobs find their commits, and pinning: one commit for every job of a calibration run, and
for every sub-run of a fan-out, whatever the branch does meanwhile.
-/

namespace DiffReviewerTest.GitRubrics

open RubricFiles in
private def errorsOf (files : List (String × String)) : List String :=
  match parseDir (files.map fun (path, content) => { path, content }) with
  | .ok _ => []
  | .error es => es.toList.map FileError.render

open RubricFiles in
private def parsed (files : List (String × String)) : Option Parsed :=
  (parseDir (files.map fun (path, content) => { path, content })).toOption

/-- The front matter YAML takes: mappings, lists, quoted and plain scalars, block scalars, JSON
    flow; a category's description, or a mapping keeping its other keys; the order of the types
    and of the categories as written. And what it refuses, each at its line. -/
def filesAreParsed : Test := do
  let feature := "---\ndescription: 'Adds things: new ones'\nfanout: true\ncategories:\n  \
correctness: Wrong   # a comment\n  \"naming\": \"Names.\"\n  docs:\n    description: |\n      \
Two\n      lines.\n    weight: 2\nlabels: [a, b]\n---\n\nCheck docs.\n"
  let ok := parsed [("rubric.md", "---\ntypes:\n- feature\n- docs\n---\nDefault.\n"),
    ("types/feature.md", feature), ("types/docs.md", "\uFEFFDocs only.\n"),
    ("README.md", "not read")]
  let r := (ok.map (·.rubric)).getD {}
  let f := (r.findType? "feature").getD { name := "" }
  let fanoutYes := errorsOf [("types/x.md", "---\nfanout: yes\n---\n")]
  return check ok.isSome "a directory that reads"
    ++ checkEq (r.prTypes.map (·.name)) ["feature", "docs"] "the types, in the order given"
    ++ checkEq r.defaultRubric "Default." "the default rubric, the body"
    ++ checkEq f.description "Adds things: new ones" "a single-quoted string"
    ++ checkEq (f.categories.map (·.name)) ["correctness", "naming", "docs"]
      "the categories in their order"
    ++ checkEq (f.categories.map (·.description)) ["Wrong", "Names.", "Two\nlines.\n"]
      "plain, double-quoted, and a block"
    ++ checkEq ((f.categories.getLast?.map (·.extra)).getD []) [("weight", (2 : Json))]
      "a category's other keys, kept"
    ++ checkEq (f.extra.map (·.1)) ["labels"] "a type's unknown key, kept"
    ++ checkEq f.rubric "Check docs." "the body, without its blank lines"
    ++ checkEq fanoutYes ["types/x.md:2: 'fanout' must be true or false"]
      "yes is no boolean here"
    ++ checkEq (errorsOf [("types/x.md", "---\ncategories:\n  a: x\n  a: y\n---\n")])
      ["types/x.md:4: 'a' is given twice"] "a key twice, at its line"
    ++ checkEq (errorsOf [("types/x.md", "---\ndescription: a\n  b: c\n---\n")])
      ["types/x.md:3: this line is indented more than the key before it"] "an indentation"
    ++ checkEq (errorsOf [("rubric.md", "---\nfanout: true\n")])
      ["rubric.md:1: the front matter that starts here is not closed by a line `---`"]
      "front matter not closed"
    ++ checkEq (errorsOf [("rubric.md", "---\ntypes: [x]\n---\n")])
      ["rubric.md:2: 'types' lists 'x', but there is no types/x.md"] "a type that is not there"
    ++ checkEq (errorsOf [("types/x.md", "---\nname: y\n---\n")])
      ["types/x.md:2: a type's name is its file's; drop 'name'"] "a name beside the file's"
    ++ checkEq (errorsOf [("types/x.md", "---\n\tdescription: a\n---\n")])
      ["types/x.md:2: indentation must be spaces, not tabs"] "a tab"
    ++ checkEq (errorsOf [("types/x.md", "---\ndescription: &a b\n---\n")])
      ["types/x.md:2: anchors, aliases and tags are not supported; quote the value"] "an anchor"
    ++ checkEq (errorsOf [("types/x.txt", "")])
      ["types/x.txt: types/ holds one file per type, types/<type>.md"] "a file not a type's"
    ++ checkEq (errorsOf [("types/a.md", "---\ncategories: 3\n---\n"),
        ("types/b.md", "---\ndescription: [\n---\n")]).length 2
      "every file's error, not the first only"
    ++ checkEq ((r.findType? "docs").map (·.rubric)) (some "Docs only.")
      "a byte order mark, dropped"
    ++ checkEq (errorsOf [("types/.gitkeep", "")])
      ["types/.gitkeep: types/ holds one file per type, types/<type>.md, and nothing else: drop \
this one"] "a dotfile in types/"
    ++ checkEq (errorsOf [("types/Feature.md", "a"), ("types/feature.md", "b")])
      ["types/feature.md: another type's name differs from 'feature' only in case: names must \
differ in more, for every file system"] "two names one only in case"
    ++ checkEq (errorsOf [("types/x.md", "---\n" ++ String.join ((List.range 1001).map
        (s!"k{·}: v\n")) ++ "---\n")])
      ["types/x.md:2: the front matter holds more than 1000 keys and items"] "too many keys"
    ++ checkEq (errorsOf [("types/x.md", "---\nd: \"" ++ String.ofList (List.replicate 70000 'x')
        ++ "\"\n---\n")])
      ["types/x.md:2: the front matter is longer than 65536 bytes"] "too long a front matter"

/-- A document written as files reads back as itself: the order, fan-out, unknown fields and
    strings YAML would read otherwise among it. -/
def filesRoundTrip : Test := do
  let doc := "{\"defaultRubric\": \"---\\nNot front matter.\", \"fanout\": true, \"tone\": \
{\"k\": [1, true]}, \"prTypes\": [{\"name\": \"zeta\", \"description\": \"true\", \"rubric\": \
\"r\", \"categories\": [{\"name\": \"no\", \"description\": \"a: b # c\"}, {\"name\": \"2\", \
\"description\": \"multi\\nline\", \"color\": \"red\"}]}, {\"name\": \"alpha\", \"fanout\": true, \
\"categories\": []}]}"
  let some r := ((Json.parse doc).bind Rubric.ofJson).toOption | return #["the document"]
  let again := RubricFiles.parseDir (RubricFiles.render r "Notes.\n")
  return check ((again.toOption.map (·.rubric == r)).getD false) "the same document"
    ++ checkEq (again.toOption.map (·.styleNotes)) (some "Notes.") "and the notes"

/-- `rubrics check` reads every directory of a checkout, and names every error by its file and
    line; a directory not in lower case is one. -/
def theCheckReadsACheckout : Test := do
  let root : System.FilePath := ".lake" / "test" / s!"check-{← IO.monoNanosNow}"
  let write (path content : String) : IO Unit := do
    let p := root / path
    if let some d := p.parent then IO.FS.createDirAll d
    IO.FS.writeFile p content
  try
    write "acme/widgets/rubric.md" "Good.\n"
    write "acme/widgets/types/feature.md" "---\ncategories:\n  a: b\n---\n"
    write "acme/gadgets/types/feature.md" "---\ncategories: [\n---\n"
    write "Acme/Upper/rubric.md" "x\n"
    write ".github/workflows/check.yml" "on: push\n"
    write "README.md" "The rubrics.\n"
    let (count, errors) ← RubricCli.checkDir root
    IO.FS.removeDirAll (root / "Acme")
    IO.FS.removeDirAll (root / "acme" / "gadgets")
    let (_, clean) ← RubricCli.checkDir root
    return checkEq count 3 "three directories"
      ++ checkEq (errors.toList.map RubricFiles.FileError.render)
        ["Acme/Upper: the platform names repositories in lower case: rename it acme/upper",
         "acme/gadgets/types/feature.md:2: a flow collection must be JSON, or a list of plain \
values like [a, b]"] "each error, at its place"
      ++ checkEq clean.size 0 "a checkout that reads"
  finally
    try IO.FS.removeDirAll root catch _ => pure ()

/-- The old versions exported: one commit a version, rubric and notes interleaved as they were
    written, dated then, in a checkout the check reads; the mapping loaded makes an old job show
    its commit and an exported commit carry what its version was derived from; loading it again
    changes nothing. -/
def theExportRoundTrips : Test := withTempDb do
  let st ← State.new cfg
  let _ ← route st (req .put "/api/v1/repos/acme/widgets" "{}")
  let save (v : Nat) (doc when : String) (prs : List String := []) : IO Unit :=
    Store.run <| HasModel.save
      ({ owner := "acme", name := "widgets", version := v, document := doc, created_at := when
       , derived_samples := some "[]", derived_prs := some (rawOfStrings prs) }
       : Store.RubricRow)
  save 1 "{\"defaultRubric\": \"One.\", \"prTypes\": [{\"name\": \"feature\", \"categories\": \
[{\"name\": \"naming\"}]}]}" "2026-01-01T10:00:00Z"
  save 2 "{\"defaultRubric\": \"Two.\"}" "2026-03-01T10:00:00Z" ["acme/widgets#7"]
  save 3 "{\"prTypes\": 7}" "2026-04-01T10:00:00Z"
  Store.run <| HasModel.save
    ({ owner := "acme", name := "widgets", version := 1, notes := "Be brief."
     , derived_samples := "[]", derived_prs := "[\"acme/widgets#9\"]"
     , created_at := "2026-02-01T10:00:00Z" } : Store.NotesRow)
  let some repo ← Platform.findRepo "acme" "widgets" | return #["the repository"]
  let old ← Platform.createJob repo 7 (some headA)
  let _ ← Platform.updateJob old.id fun j => return { j with rubricVersion := some 2 }
  let db ← Store.pathRef.get
  let out : System.FilePath := ".lake" / "test" / s!"export-{← IO.monoNanosNow}"
  let mappingPath : System.FilePath := ⟨out.toString ++ ".mapping.json"⟩
  try
    let code ← RubricCli.exportDb db out none "main"
    let log ← RubricCli.git out #["log", "--reverse", "--format=%s|%aI"]
    let lines := (log.toOption.getD "").splitOn "\n"
    let (_, errors) ← RubricCli.checkDir out
    let notesAt2 ← RubricCli.git out #["show", "HEAD:acme/widgets/style.md"]
    let typesGone ← RubricCli.git out #["show", "HEAD:acme/widgets/types/feature.md"]
    let mapping := (Json.parse (← IO.FS.readFile mappingPath)).toOption.getD .null
    let entries := ((mapping.getObjVal? "entries").toOption.bind (·.getArr?.toOption)).getD #[]
    let commitOf (kind : String) (v : Nat) : Option String :=
      (entries.find? fun e => (e.getObjValAs? String "kind").toOption == some kind &&
        (e.getObjValAs? Nat "version").toOption == some v).bind
        (·.getObjValAs? String "commit" |>.toOption)
    let loaded ← Rubrics.importMapping mapping
    let again ← Rubrics.importMapping mapping
    let shown ← route st (req .get s!"/api/v1/jobs/{old.id}")
    let v2 := (commitOf "rubric" 2).getD ""
    let prov ← Rubrics.provenanceOf "acme" "widgets" [v2]
    let refusedOut ← RubricCli.exportDb db out none "main"
    return checkEq code 0 "the export"
      ++ checkEq lines ["acme/widgets: rubric version 1|2026-01-01T10:00:00Z",
          "acme/widgets: style notes version 1|2026-02-01T10:00:00Z",
          "acme/widgets: rubric version 2|2026-03-01T10:00:00Z"]
        "a commit a version, in order, dated when it was written; one that does not read, none"
      ++ checkEq errors.size 0 "a checkout the check reads"
      ++ checkEq notesAt2.toOption (some "Be brief.") "the notes, kept with the later rubric"
      ++ check (typesGone matches .error _) "a type the later version dropped, gone"
      ++ checkEq entries.size 3 "three versions mapped"
      ++ checkEq (commitOf "rubric" 3) none "and not the one that does not read"
      ++ checkEq loaded.toOption (some 3) "loaded"
      ++ checkEq again.toOption (some 3) "loaded again, the same"
      ++ checkEq (field shown "rubricSha") (some v2) "an old job shows its version's commit"
      ++ checkEq (← Rubrics.legacyVersion "acme" "widgets" v2) (some 2) "and the commit its version"
      ++ checkEq ((prov.head?.map (·.2.prs)).getD []) ["acme/widgets#7", "acme/widgets#9"]
        "the commit carries what its rubric and its notes were derived from"
      ++ checkEq refusedOut 1 "an export over a directory that is not empty"
  finally
    try IO.FS.removeDirAll out catch _ => pure ()
    try IO.FS.removeFile mappingPath catch _ => pure ()

/-- A calibration run pins one commit for every job it makes, and a fan-out's sub-runs read their
    job's: the branch moving between the run and its queueing, or while the sub-runs run, changes
    nothing they read. -/
def pinsHoldAcrossAHeadMove : Test := withTempDb do
  -- A run of two samples, the head moving before they are queued.
  let f ← DiffReviewerTest.Calibration.FakeHistory.new
  let orch ← FakeOrchestra.new
  let svc ← withGit (← DiffReviewerTest.Calibration.services f orch)
  let st ← State.new cfg svc
  let _ ← DiffReviewerTest.Calibration.imported st svc f
  let pinned ← commitRubric "acme" "widgets" "{\"defaultRubric\": \"First.\"}"
  let made ← DiffReviewerTest.Calibration.runOf st
    [← DiffReviewerTest.Calibration.sampleId st 301, ← DiffReviewerTest.Calibration.sampleId st 201]
  let _ ← commitRubric "acme" "widgets" "{\"defaultRubric\": \"Second.\"}"
  Workers.queuePending svc
  let jobs := (DiffReviewerTest.Calibration.resultsOf made).filterMap
    (DiffReviewerTest.Calibration.str · ["jobId"])
  let shas ← jobs.mapM fun id => do return (← Platform.findJob id).bind (·.rubricSha)
  -- A fan-out, the head moving while its sub-runs run.
  let gh ← FakeGitHub.new #[pull7 jobHead]
  let logs ← IO.mkRef #[]
  let svc2 ← withGit (← services gh orch logs)
  let st2 ← State.new cfg svc2
  let id ← DiffReviewerTest.Fanout.fannedRepo st2
  Workers.queuePending svc2
  let fannedBy ← Rubrics.pinFor "acme" "widgets"
  let _ ← commitRubric "acme" "widgets" "{\"defaultRubric\": \"Moved.\", \"prTypes\": [{\"name\": \
\"feature\", \"fanout\": true, \"categories\": [{\"name\": \"other\"}]}]}"
  let sub ← route st2 (DiffReviewerTest.Fanout.asJob (agentReq .get "") s!"{id}.correctness")
  let instructions := (field sub "instructions").getD ""
  return checkStatus made 201 "the run"
    ++ checkEq (field made "rubricSha") (some pinned) "pinned to the commit in use"
    ++ checkEq shas [some pinned, some pinned] "every job of it, queued after the head moved"
    ++ checkStatus sub 200 "a sub-run's read"
    ++ checkEq (field sub "rubricSha") fannedBy "its job's commit, not the head since"
    ++ check ((instructions.splitOn "Be careful.").length > 1 &&
      (instructions.splitOn "Moved.").length == 1) "and that commit's rubric"

/-- What a commit was derived from is every provenance recorded on a commit before it: after a
    merge, a person's edit carries it on; two proposals merged one after the other, both; the
    export's commits, every one after them; and a force-push that drops a merge from the branch
    drops its provenance too. Each head's lineage is read once: by a compare with the head before
    it, or, when it does not descend from it, by the directory's history. -/
def provenanceIsCumulative : Test := withTempDb do
  let fg ← FakeGit.new
  let svc := fg.attach (← Workers.Services.new (log := fun _ => pure ()))
  let st ← State.new cfg svc
  let _ ← route st (req .put "/api/v1/repos/acme/widgets" "{}")
  let prov (sha : String) (prs : List String) : IO Unit :=
    Store.run (Rubrics.recordProvenanceIn "acme" "widgets" sha s!"proposal:{sha}" { prs })
  let pullsOf (sha : String) : IO (List String) := do
    return (((← Rubrics.provenanceOf "acme" "widgets" [sha]).head?.map (·.2.prs)).getD [])
  -- Exported: two commits, the mapping carrying what each was derived from.
  let e1 ← fg.change [("acme/widgets/rubric.md", some "One.\n")]
  let e2 ← fg.change [("acme/widgets/rubric.md", some "Two.\n")]
  let mapping := Json.mkObj [("entries", .arr #[
    .mkObj [("owner", "acme"), ("name", "widgets"), ("kind", "rubric"), ("version", (1 : Nat)),
            ("commit", e1), ("derivedFrom", .arr #[]),
            ("derivedFromPulls", .arr #["acme/widgets#1"])],
    .mkObj [("owner", "acme"), ("name", "widgets"), ("kind", "rubric"), ("version", (2 : Nat)),
            ("commit", e2), ("derivedFrom", .arr #[]),
            ("derivedFromPulls", .arr #["acme/widgets#1"])]])]
  let _ ← Rubrics.importMapping mapping
  refresh svc
  let firstRead := (← fg.calls.get).filter fun c => (c.splitOn "/commits?sha=").length > 1
  -- A person's edit after the export.
  let edit ← fg.change [("acme/widgets/rubric.md", some "Two, edited.\n")]
  refresh svc
  let afterExport ← pullsOf edit
  -- Two proposals merged, one after the other, each followed by an edit.
  let m1 ← fg.change [("acme/widgets/rubric.md", some "Three.\n")]
  prov m1 ["acme/widgets#7"]
  refresh svc
  let m2 ← fg.change [("acme/widgets/rubric.md", some "Four.\n")]
  prov m2 ["acme/widgets#8"]
  refresh svc
  let after ← fg.change [("acme/widgets/style.md", some "Brief.\n")]
  refresh svc
  let both := (← pullsOf after).toArray.qsort (· < ·) |>.toList
  let compares := (← fg.calls.get).filter fun c => (c.splitOn "/compare/").length > 1
  -- A force-push to before the second merge: its provenance is gone with it.
  let some c1 ← fg.commitOf m1 | return #["the first merge"]
  let back ← fg.commitFiles (← fg.filesOf c1.tree) #[m1] "the second merge, undone by a rewrite"
  fg.forcePush back
  refresh svc
  let rewritten := (← pullsOf back).toArray.qsort (· < ·) |>.toList
  return check (firstRead.size ≥ 1) "the first head read by the directory's history"
    ++ checkEq afterExport ["acme/widgets#1"] "an edit after the export keeps its provenance"
    ++ checkEq both ["acme/widgets#1", "acme/widgets#7", "acme/widgets#8"]
      "after two merges and an edit: all of it"
    ++ checkEq compares.size 4 "each later head by a compare with the one before"
    ++ checkEq rewritten ["acme/widgets#1", "acme/widgets#7"]
      "a force-push that drops a merge drops its provenance"

/-- Until the rubrics repository has been read, reviews, calibration runs and proposals wait,
    saying why — one not found, or that the token cannot read, above all, which is never taken for
    no rubric; once it is read and has no branch, they go on with no rubric. A run made meanwhile
    pins every job to the one commit its first job is queued under. -/
def anUnreadRepositoryWaits : Test := withTempDb do
  let f ← DiffReviewerTest.Calibration.FakeHistory.new
  let orch ← FakeOrchestra.new
  let fg ← FakeGit.new
  let prop ← FakeOrchestra.new
  let svc := fg.attach (← Workers.Services.new (some f.client) (some orch.client) (fun _ => pure ())
    {} (some prop.client))
  let st ← State.new cfg svc
  let _ ← DiffReviewerTest.Calibration.imported st svc f
  fg.hidden.set true
  refresh svc
  f.gh.pulls.set #[pull7 jobHead]
  let review ← newJob st
  let run ← DiffReviewerTest.Calibration.runOf st
    [← DiffReviewerTest.Calibration.sampleId st 301, ← DiffReviewerTest.Calibration.sampleId st 201]
  let proposal ← route st (req .post "/api/v1/repos/acme/widgets/proposals" "{}")
  Workers.queuePending svc
  let reviewId := (field review "id").getD ""
  let some waiting ← Platform.findJob reviewId | return #["the review"]
  let shown ← route st (req .get "/api/v1/repos/acme/widgets/rubrics")
  let queuedWhileHidden := (← orch.queued.get).size + (← prop.queued.get).size
  -- Readable, and with a rubric: every job goes on, the run's all at one commit.
  fg.hidden.set false
  let pinned ← fg.setRubric "acme" "widgets" "{\"defaultRubric\": \"Now.\"}"
  refresh svc
  Workers.queuePending svc
  let runJobs := (DiffReviewerTest.Calibration.resultsOf run).filterMap
    (DiffReviewerTest.Calibration.str · ["jobId"])
  let shas ← runJobs.mapM fun id => do return (← Platform.findJob id).bind (·.rubricSha)
  let some reviewed ← Platform.findJob reviewId | return #["the review"]
  let proposalJob ← Platform.findJob ((field proposal "id").getD "")
  -- An empty repository, read, where nothing was ever in use: no rubric, and a review goes on
  -- without one.
  Store.run do
    let db ← read
    SQLite.exec db "DELETE FROM rubric_head"
  let fg2 ← FakeGit.new
  let svc2 := fg2.attach svc
  refresh svc2
  let _ ← Platform.updateJob reviewId fun j =>
    return { j with statusRaw := "pending", rubricSha := none, rubricVersion := none }
  Workers.queuePending svc2
  let some noRubric ← Platform.findJob reviewId | return #["the review"]
  return checkEq waiting.statusRaw "pending" "a review, while the repository cannot be read"
    ++ check (waiting.error.any fun e => (e.splitOn "not found, or the token cannot read").length
      > 1) "saying why"
    ++ checkEq queuedWhileHidden 0 "nothing queued: no review, no run, no proposal"
    ++ check (((bodyJson shown).getObjVal? "error").toOption.bind
      (DiffReviewerTest.Calibration.str · ["message"]) |>.any fun m =>
        (m.splitOn "cannot be read").length > 1) "the API says it cannot be read"
    ++ checkStatus run 201 "a run, made meanwhile"
    ++ checkEq (field run "rubricSha") none "pinned to nothing yet"
    ++ checkEq shas [some pinned, some pinned] "its jobs, pinned once read, to one commit"
    ++ checkEq reviewed.rubricSha (some pinned) "the review, too"
    ++ checkEq (proposalJob.map (·.statusRaw)) (some "queued") "and the proposal"
    ++ checkEq noRubric.rubricVersion (some 0) "a repository read with no branch: no rubric"
    ++ checkEq noRubric.statusRaw "queued" "and the review goes on"

/-- A proposal's branch or pull request that is someone else's is never taken for its own: a
    branch of its name at another commit, or a pull request of it whose head is not its commit,
    fails it with why. -/
def aProposalsBranchIsItsOwn : Test := withTempDb do
  let f ← DiffReviewerTest.Calibration.FakeHistory.new
  let orch ← FakeOrchestra.new
  let prop ← FakeOrchestra.new
  let fg ← FakeGit.new
  let svc := fg.attach (← Workers.Services.new (some f.client) (some orch.client) (fun _ => pure ())
    {} (some prop.client))
  let st ← State.new cfg svc
  let _ ← route st (req .put "/api/v1/repos/acme/widgets" "{}")
  let base ← fg.setRubric "acme" "widgets" "{}"
  refresh svc
  let made ← route st (req .post "/api/v1/repos/acme/widgets/proposals" "{}")
  let jobId := (field made "id").getD ""
  Workers.queuePending svc
  let _ ← route st (DiffReviewerTest.Style.agentProposalReq .get jobId)
  -- Submitted while GitHub is away: the branch is to be made later.
  let down : Workers.Services := { svc with github := some bare }
  let sub ← route (← State.new cfg down) (DiffReviewerTest.Style.agentProposalReq .post jobId
    (DiffReviewerTest.Style.proposal (rubric := "{\"defaultRubric\": \"x\"}")))
  let pid := (field sub "proposalId").getD ""
  -- Someone makes a branch of its name first, at another commit.
  let other ← fg.change [("other/repo/rubric.md", some "Mine.\n")]
  fg.refs.modify (((s!"diff-reviewer/proposal/acme/widgets/{pid}"), other) :: ·)
  Workers.tick svc
  let p ← route st (req .get s!"/api/v1/repos/acme/widgets/proposals/{pid}")
  return checkStatus sub 200 "the submission"
    ++ check ((DiffReviewerTest.Calibration.str (bodyJson p) ["prError"]).any fun e =>
      (e.splitOn "is not the proposal's").length > 1) "the branch, not taken"
    ++ checkEq (← fg.pulls.get).size 0 "and no pull request opened from it"
    ++ check (base != other) "of another commit"

def all : List (String × Test) :=
  [("filesAreParsed", filesAreParsed),
   ("filesRoundTrip", filesRoundTrip),
   ("theCheckReadsACheckout", theCheckReadsACheckout),
   ("theExportRoundTrips", theExportRoundTrips),
   ("pinsHoldAcrossAHeadMove", pinsHoldAcrossAHeadMove),
   ("provenanceIsCumulative", provenanceIsCumulative),
   ("anUnreadRepositoryWaits", anUnreadRepositoryWaits),
   ("aProposalsBranchIsItsOwn", aProposalsBranchIsItsOwn)]

end DiffReviewerTest.GitRubrics