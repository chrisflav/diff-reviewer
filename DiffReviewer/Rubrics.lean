import Lean.Data.Json
import DiffReviewer.Platform
import DiffReviewer.GitHub
import DiffReviewer.RubricFiles
import Std.Data.HashMap
import Std.Data.HashSet

open Lean (Json)

/-!
# The rubrics repository

Every repository's rubric, and its style notes, live in one git repository on GitHub
(`DIFF_REVIEWER_RUBRICS_REPO`, branch `DIFF_REVIEWER_RUBRICS_BRANCH`, `main` by default), as the
directory `<owner>/<name>/` (`DiffReviewer.RubricFiles`). Git is the record: the platform only
reads it — people change a rubric by a commit or a pull request — and a rubric is named by the
commit it is read at.

  * **Following the branch** (`refresh`, on every pass of the workers). The branch's head is read,
    and for every registered repository what that commit holds (`snapshot`), once per commit. When
    it reads, it is the rubric in use (`HeadRow.good_sha`); when it does not, the last that did
    stays in use, and the errors, with their files and lines, are kept beside it for the API to
    show. A repository with no directory has no rubric; so has every repository while the rubrics
    repository has no such branch (an empty repository has none), which is said once and not
    retried as an error. But a rubrics repository that cannot be read — not found, or not to the
    token, which GitHub answers alike — is never no rubric: until it has been read once, the jobs
    of a repository wait (`pinOrWait`).
  * **Pinning.** A job is pinned to the commit in use when it is queued, and a calibration run's
    jobs all to one when the run is made (`Job.rubricSha`): its agent, its fan-out's sub-runs and
    the checks of its submission read the rubric at that commit (`ofJob`), whatever the branch has
    become since.
  * **What a commit holds** is read from the git data API — the commit, its trees down to the
    directory, and the directory's blobs — and kept per commit and repository
    (`Store.SnapshotRow`). A directory whose tree was read already, at another commit, is not
    read again.
  * **Provenance** (`provenanceOf`). A rubric proposal's pull request, merged, records what the
    proposal drew on on its merge commit and on its own commit (`DiffReviewer.Proposal`); so does
    each version the export of the old database made (`importMapping`). A commit carries the
    provenance of every commit before it on the branch that carries one — whoever changed the
    directory since, since a person's edit of a derived rubric keeps what it learned. Before it is
    known cheaply: each head is recorded as descending from the head before it, by the commits
    between (`recordLineage`), and a head that does not descend — a force-push — by the commits of
    the directory's history. A score of a job pinned to such a commit, of a sample of one of those
    pull requests, is `derived` (`Calibration.derivedOf`).
  * **The old versions.** Jobs and scores from before name an integer `rubricVersion`; the export
    (`diff-reviewer rubrics export`) wrote each version as a commit and a mapping of versions to
    commits, which `importMapping` loads (`Store.MappingRow`), so that they are shown at their
    commit.
-/

namespace DiffReviewer.Rubrics

open Db.Query.DSL
open RubricFiles (FileError Parsed)

/-- The rubrics repository, and the branch whose head is the rubrics in use. -/
structure Source where
  owner  : String
  name   : String
  branch : String := "main"
  deriving Repr, BEq, Inhabited

def Source.slug (s : Source) : String := s!"{s.owner}/{s.name}"

/-- The rubrics repository the environment names, `none` when it names none, and an error when
    `DIFF_REVIEWER_RUBRICS_REPO` is not `owner/name`. -/
def Source.ofEnv : IO (Except String (Option Source)) := do
  let some repo ← IO.getEnv "DIFF_REVIEWER_RUBRICS_REPO" | return .ok none
  let repo := repo.trimAscii.toString
  if repo.isEmpty then return .ok none
  let branch := ((← IO.getEnv "DIFF_REVIEWER_RUBRICS_BRANCH").map (·.trimAscii.toString)).getD ""
  let branch := if branch.isEmpty then "main" else branch
  match repo.splitOn "/" with
  | [o, n] =>
    unless validSlugPart o && validSlugPart n do
      return .error s!"DIFF_REVIEWER_RUBRICS_REPO is '{repo}', not a GitHub repository's owner/name"
    if branch.any (fun c => c == ' ' || c == '?' || c == '#' || c == '&') ||
        branch.startsWith "/" || branch.endsWith "/" then
      return .error s!"DIFF_REVIEWER_RUBRICS_BRANCH is '{branch}', not a branch name"
    return .ok (some { owner := o.toLower, name := n.toLower, branch })
  | _ => return .error s!"DIFF_REVIEWER_RUBRICS_REPO is '{repo}', not owner/name"

/-- Where `owner/name`'s rubric is, in the rubrics repository. -/
def directory (owner name : String) : String := s!"{owner}/{name}"

def Source.web (s : Source) : String := s!"https://github.com/{s.owner}/{s.name}"

def Source.blobUrl (s : Source) (sha path : String) : String := s!"{s.web}/blob/{sha}/{path}"

def Source.editUrl (s : Source) (path : String) : String := s!"{s.web}/edit/{s.branch}/{path}"

def Source.treeUrl (s : Source) (path : String) : String := s!"{s.web}/tree/{s.branch}/{path}"

def Source.commitUrl (s : Source) (sha : String) : String := s!"{s.web}/commit/{sha}"

def Source.compareUrl (s : Source) (base head : String) : String :=
  s!"{s.web}/compare/{base}...{head}"

/-! ## What a commit holds -/

/-- What commit `commit` of the rubrics repository holds for `owner/name`: the tree of its
    directory (`none`: there is none, and so no rubric), and what it reads as, or why not. -/
structure Snapshot where
  commit : String
  owner  : String
  name   : String
  tree   : Option String
  parsed : Except (Array FileError) Parsed

def Snapshot.rubric? (s : Snapshot) : Except (Array FileError) (Option Rubric) :=
  s.parsed.map fun p => if s.tree.isSome then some p.rubric else none

def Snapshot.styleNotes (s : Snapshot) : String :=
  match s.parsed with
  | .ok p => p.styleNotes
  | .error _ => ""

/-- Why `s` does not read, as one line: its first error, and how many more there are. -/
def errorsLine (es : Array FileError) : String :=
  let first := (es[0]?.map (·.render)).getD "it does not read"
  if es.size ≤ 1 then first else s!"{first} (and {es.size - 1} more)"

private def errorsJson (es : Array FileError) : String :=
  (Json.arr (es.map (·.toJson))).compress

private def errorsOfRaw (raw : String) : Array FileError :=
  match Json.parse raw with
  | .ok (.arr xs) => xs.filterMap FileError.ofJson?
  | _ => #[{ file := "", message := "the errors recorded do not read" }]

private def Snapshot.ofRow (r : Store.SnapshotRow) : Snapshot :=
  let parsed : Except (Array FileError) Parsed := match r.errors, r.document with
    | some es, _ => .error (errorsOfRaw es)
    | none, some doc => match (Json.parse doc).bind Rubric.ofJson with
      | .ok d => .ok { rubric := d, styleNotes := r.style_notes.getD "" }
      | .error e => .error #[{ file := "", message := s!"the document kept does not read: {e}" }]
    | none, none => .ok {}
  { commit := r.commit_sha, owner := r.owner, name := r.name, tree := r.tree_sha, parsed }

private def Snapshot.toRow (s : Snapshot) (now : String) : Store.SnapshotRow :=
  let (document, notes, errors) : Option String × Option String × Option String :=
    match s.parsed with
    | .ok p => (some p.rubric.toJson.compress, some p.styleNotes, none)
    | .error es => (none, none, some (errorsJson es))
  { commit_sha := s.commit, owner := s.owner, name := s.name, tree_sha := s.tree, document
  , style_notes := notes, errors, fetched_at := now }

def fetchSnapshot (commit owner name : String) : Sqlite.M (Option Snapshot) := do
  let rows ← HasModel.fetch <| query% do
    let r ← from Store.SnapshotRow
    guard r.commit_sha = commit
    guard r.owner = owner
    guard r.name = name
    select r
  return rows[0]?.map Snapshot.ofRow

/-- What commit `commit` holds for `owner/name`, if it has been read. -/
def cached (commit owner name : String) : IO (Option Snapshot) :=
  Store.run (fetchSnapshot commit owner name)

/-- The snapshots of `owner/name` read so far. -/
private def snapshotsOf (owner name : String) : IO (Array Snapshot) := do
  let rows ← Store.run <| HasModel.fetch <| query% do
    let r ← from Store.SnapshotRow
    guard r.owner = owner
    guard r.name = name
    select r
  return rows.map Snapshot.ofRow

private def ghError (what : String) (e : GitHub.Error) : String := s!"{what}: {e.message}"

/-- The entry `name`, a tree, of tree `sha`. -/
private def subtree (gh : GitHub.Client) (src : Source) (sha name : String) :
    IO (Except String (Option String)) := do
  match ← gh.getTree src.owner src.name sha false with
  | .error e => return .error (ghError s!"reading tree {sha}" e)
  | .ok es => return .ok ((es.find? fun e => e.path == name && e.type == "tree").map (·.sha))

/-- What commit `commit` of `src` holds for `owner/name`: kept, or read from GitHub and kept. An
    error is GitHub not answering as it should, which is not kept: it is tried again. -/
def snapshot (gh : GitHub.Client) (src : Source) (commit owner name : String) :
    IO (Except String Snapshot) := do
  if let some s ← cached commit owner name then return .ok s
  let save (s : Snapshot) : IO (Except String Snapshot) := do
    let now ← nowIso
    Store.run (HasModel.save (s.toRow now))
    return .ok s
  let c ← match ← gh.getCommit src.owner src.name commit with
    | .ok c => pure c
    | .error e => return .error (ghError s!"reading commit {commit} of {src.slug}" e)
  let none' : Snapshot := { commit, owner, name, tree := none, parsed := .ok {} }
  let ownerTree ← match ← subtree gh src c.tree owner with
    | .ok t => pure t
    | .error e => return .error e
  let some ownerTree := ownerTree | save none'
  let dirTree ← match ← subtree gh src ownerTree name with
    | .ok t => pure t
    | .error e => return .error e
  let some dirTree := dirTree | save none'
  -- The same directory read at another commit reads the same.
  if let some s := (← snapshotsOf owner name).find? (·.tree == some dirTree) then
    return ← save { s with commit }
  let entries ← match ← gh.getTree src.owner src.name dirTree true with
    | .ok es => pure es
    | .error e => return .error (ghError s!"reading {directory owner name} at {commit}" e)
  let wanted := entries.filter fun e =>
    e.type == "blob" &&
      (e.path == "rubric.md" || e.path == "style.md" || e.path.startsWith "types/")
  let mut files : Array RubricFiles.File := #[]
  for e in wanted do
    -- Only what is read is fetched: anything else under `types/` is an error by its name.
    let content ← if e.path.endsWith ".md" then
        match ← gh.getBlob src.owner src.name e.sha with
        | .ok t => pure t
        | .error err =>
          return .error (ghError s!"reading {directory owner name}/{e.path} at {commit}" err)
      else pure ""
    files := files.push { path := e.path, content }
  let parsed := (RubricFiles.parseDir files.toList).mapError
    (·.map (·.under (directory owner name)))
  save { commit, owner, name, tree := some dirTree, parsed }

/-! ## Following the branch -/

/-- Where `owner/name`'s rubric stands: the head last read, the commit in use, why the head is not
    it or why there is none — an error of no file is the rubrics repository's own: it could not be
    read — and when it was last read. -/
structure Head where
  headSha   : Option String := none
  goodSha   : Option String := none
  errors    : Array FileError := #[]
  checkedAt : Option String := none
  /-- When the rubrics repository was last read for it; none before it ever was. -/
  readAt    : Option String := none

def fetchHead (owner name : String) : Sqlite.M (Option Head) := do
  let rows ← HasModel.fetch <| query% do
    let r ← from Store.HeadRow
    guard r.owner = owner
    guard r.name = name
    select r
  return rows[0]?.map fun r =>
    { headSha := r.head_sha, goodSha := r.good_sha
    , errors := (r.error.map errorsOfRaw).getD #[], checkedAt := some r.checked_at
    , readAt := r.read_at }

def headOf (owner name : String) : IO (Option Head) := Store.run (fetchHead owner name)

/-- The commit `owner/name`'s reviews are pinned to now: the one whose rubric is in use, if any. -/
def pinFor (owner name : String) : IO (Option String) := do
  return (← headOf owner name).bind (·.goodSha)

/-- What a job of `owner/name` is pinned to when it is queued, the rubrics repository `src` being
    configured: the commit in use; none when the repository has been read and has no rubric for it
    — the branch missing, or empty — or why the job waits: the rubrics repository has never been
    read for it (not yet, or it cannot be: not found, or not readable with the token), which is
    never taken for no rubric. -/
def pinOrWait (src : Source) (owner name : String) : IO (Except String (Option String)) := do
  let some h ← headOf owner name
    | return .error s!"the rubrics repository {src.slug} has not been read yet; the job waits \
for it"
  if h.readAt.isNone then
    let why := if h.errors.isEmpty then "it has not been read yet" else
      s!"it cannot be read: {errorsLine h.errors}"
    return .error s!"the rubrics repository {src.slug} has never been read for {owner}/{name} — \
{why}; the job waits for it"
  return .ok h.goodSha

private def saveHead (owner name : String) (h : Head) : IO Unit := do
  let now ← nowIso
  Store.run <| HasModel.save
    ({ owner, name, head_sha := h.headSha, good_sha := h.goodSha
     , error := if h.errors.isEmpty then none else some (errorsJson h.errors)
     , checked_at := now, read_at := h.readAt } : Store.HeadRow)

/-- The message of a rubrics repository without the branch. -/
def noBranchMessage (src : Source) : String :=
  s!"the rubrics repository {src.slug} has no branch {src.branch} — it may be empty: no rubric \
is read from it until it has"

/-- Every commit a provenance is recorded on, read, so that its directory's tree is known. -/
private def provenanceCommits : IO (Array (String × String × String)) := do
  let rows ← Store.run <| HasModel.fetch <| query% do
    let r ← from Store.ProvenanceRow
    select r
  return rows.map fun r => (r.commit_sha, r.owner, r.name)

private def fetchLineage (owner name commit : String) : IO (Option Store.LineageRow) := do
  let rows ← Store.run <| HasModel.fetch <| query% do
    let r ← from Store.LineageRow
    guard r.owner = owner
    guard r.name = name
    guard r.commit_sha = commit
    select r
  return rows[0]?

/-- The most commits of a directory's history read to know what a head descends from. -/
def maxHistory : Nat := 1000

/-- How head `h` of `owner/name` descends from the history before it, recorded once
    (`Store.LineageRow`): from the head read before, `prev`, by the commits between them when it
    descends from it (GitHub's compare says `ahead`, of at most 100 commits, or `identical`); and
    otherwise — no head before, a force-push, a longer way — by the commits of the directory's
    history at `h`. An error is GitHub not answering: nothing is recorded, and it is tried again. -/
def recordLineage (gh : GitHub.Client) (src : Source) (owner name h : String)
    (prev : Option String) : IO (Except String Unit) := do
  if (← fetchLineage owner name h).isSome then return .ok ()
  let now ← nowIso
  let save (parent : Option String) (commits : Array String) : IO (Except String Unit) := do
    Store.run <| HasModel.save
      ({ owner, name, commit_sha := h, parent_sha := parent
       , commits := rawOfStrings commits.toList, created_at := now } : Store.LineageRow)
    return .ok ()
  if let some p := prev then
    if p == h then return ← save none #[]
    match ← gh.compare src.owner src.name p h with
    | .error e => return .error (ghError s!"comparing {p} with {h}" e)
    | .ok c =>
      if c.status == "identical" then return ← save (some p) #[]
      if c.status == "ahead" && c.totalCommits ≤ c.commits.size then
        return ← save (some p) (c.commits.map (·.1))
  match ← gh.listCommits src.owner src.name h (directory owner name) maxHistory with
  | .error e => return .error (ghError s!"reading the history of {directory owner name} at {h}" e)
  | .ok cs => save none (cs.map (·.sha))

/-- One pass of following the branch of `src`: see the module's description. `note key msg` says
    `msg` once for `key`. -/
def refresh (gh : GitHub.Client) (src : Source) (note : String → String → IO Unit) :
    IO Unit := do
  let repos ← Platform.listRepos
  let now ← nowIso
  match ← gh.branchHead src.owner src.name src.branch with
  | .error e =>
    -- Not read: every repository keeps what it has in use, and says why — a review of one that
    -- was never read waits rather than going without a rubric.
    let why := s!"the rubrics repository {src.slug} cannot be read: {e.message}"
    note s!"rubrics-head-{e.message}" s!"{why}; the rubrics in use stay"
    for r in repos do
      let cur := (← headOf r.owner r.name).getD {}
      unless cur.errors.map (·.message) == #[why] do
        saveHead r.owner r.name { cur with errors := #[{ file := "", message := why }] }
  | .ok none =>
    let why := noBranchMessage src
    note "rubrics-no-branch" why
    for r in repos do
      let cur := (← headOf r.owner r.name).getD {}
      saveHead r.owner r.name
        { cur with headSha := none, errors := #[{ file := "", message := why }], readAt := now }
  | .ok (some h) =>
    for r in repos do
      let cur := (← headOf r.owner r.name).getD {}
      if cur.headSha == some h && cur.readAt.isSome && cur.errors.all (!·.file.isEmpty) then
        continue
      let snap ← match ← snapshot gh src h r.owner r.name with
        | .ok s => pure s
        | .error why =>
          note s!"rubrics-{r.slug}-{h}-{why}" s!"reading the rubric of {r.slug} at {h}: {why}"
          continue
      let prev := if cur.readAt.isSome then cur.headSha else none
      if let .error why ← recordLineage gh src r.owner r.name h prev then
        note s!"rubrics-lineage-{r.slug}-{h}-{why}" s!"reading what {h} descends from: {why}"
        continue
      match snap.parsed with
      | .ok _ => saveHead r.owner r.name { headSha := some h, goodSha := some h, readAt := now }
      | .error es =>
        saveHead r.owner r.name
          { headSha := some h, goodSha := cur.goodSha, errors := es, readAt := now }
        let kept := match cur.goodSha with
          | some g => s!"the last that did, {g}, stays in use"
          | none => "there is no rubric in use until it reads"
        note s!"rubrics-{r.slug}-{h}" s!"the rubric of {r.slug} at {h} does not read: \
{errorsLine es}; {kept}"
  -- The commits provenance is recorded on are read too, so that their trees are known.
  for (c, o, n) in ← provenanceCommits do
    if (← cached c o n).isNone then
      if let .error why ← snapshot gh src c o n then
        note s!"rubrics-prov-{c}-{why}" s!"reading {o}/{n} at {c}, which a provenance is \
recorded on: {why}"

/-! ## The rubric of a job -/

/-- What a job is reviewed by: its rubric (`none`: none) and the style notes. -/
structure JobRubric where
  rubric     : Option Rubric := none
  styleNotes : String := ""
  /-- The commit it is read at, when it is read from the rubrics repository. -/
  sha        : Option String := none

/-- The rubric job `job` is reviewed by: at its pinned commit, read from GitHub (through `gh`) if
    it is not kept; for a job of before rubrics lived in git, its version as the database kept it,
    with the notes the repository had; and none for a job pinned to nothing. An error when the
    commit cannot be read, or does not read. -/
def ofJob (gh : Option (GitHub.Client × Source)) (job : Job) : IO (Except String JobRubric) := do
  match job.rubricSha with
  | some sha =>
    let snap ← match ← cached sha job.owner job.name, gh with
      | some s, _ => pure (Except.ok s)
      | none, some (c, src) => snapshot c src sha job.owner job.name
      | none, none => pure (.error s!"commit {sha} of the rubrics repository has not been read, \
and GitHub is not configured to read it")
    match snap with
    | .error e => return .error e
    | .ok s => match s.rubric? with
      | .ok r => return .ok { rubric := r, styleNotes := s.styleNotes, sha := some sha }
      | .error es => return .error s!"the rubric of {job.owner}/{job.name} at {sha} does not \
read: {errorsLine es}"
  | none =>
    match job.rubricVersion with
    | some 0 | none => return .ok {}
    | some v =>
      let notes := ((← Platform.findRepo job.owner job.name).map (·.styleNotes)).getD ""
      match ← Platform.rubricAt job.owner job.name v with
      | none => return .ok { styleNotes := notes }
      | some rv => match rv.rubric? with
        | .ok d => return .ok { rubric := some d, styleNotes := notes }
        | .error e => return .error s!"the rubric of {job.owner}/{job.name} (version {v}) cannot \
be read by this build ({e})"

/-- The rubric in use for `owner/name` now, kept: for a check made before a job is pinned (a
    repository's fixed type, a calibration run's charge). -/
def current (owner name : String) : IO (Option Rubric) := do
  let some sha ← pinFor owner name | return none
  let some s ← cached sha owner name | return none
  return (s.rubric?.toOption).bind id

/-! ## The old versions -/

def mappingRows (owner name : String) : IO (Array Store.MappingRow) :=
  Store.run <| HasModel.fetch <| query% do
    let r ← from Store.MappingRow
    guard r.owner = owner
    guard r.name = name
    select r

/-- The commit version `version` of `owner/name`'s rubric was exported as, if the mapping has it. -/
def legacyCommit (owner name : String) (version : Nat) : IO (Option String) := do
  return ((← mappingRows owner name).find? fun r =>
    r.kind == "rubric" && r.version == (version : Int)).map (·.commit_sha)

/-- The rubric version commit `sha` was exported from, if it was. -/
def legacyVersion (owner name sha : String) : IO (Option Nat) := do
  return ((← mappingRows owner name).find? fun r =>
    r.kind == "rubric" && r.commit_sha == sha).map (·.version.toNat)

/-- The commit job `job` was reviewed by: the one it is pinned to, or the one its old rubric
    version was exported as. -/
def shaOfJob (job : Job) : IO (Option String) := do
  if job.rubricSha.isSome then return job.rubricSha
  match job.rubricVersion with
  | some v => if v == 0 then return none else legacyCommit job.owner job.name v
  | none => return none

/-- `j`, a job's JSON, with the commit its old rubric version was exported as, when it is pinned to
    none itself. -/
def withLegacySha (job : Job) (j : Json) : IO Json := do
  if job.rubricSha.isSome then return j
  match ← shaOfJob job with
  | some sha => return j.setObjVal! "rubricSha" sha
  | none => return j

/-- Load an export's mapping (`diff-reviewer rubrics export`): every version to its commit, and on
    every commit what the version was derived from. Loading it again changes nothing. Answers how
    many versions it maps. -/
def importMapping (j : Json) : IO (Except String Nat) := do
  let some entries := (j.getObjVal? "entries" >>= (·.getArr?)).toOption
    | return .error "the mapping has no 'entries'"
  let now ← nowIso
  let mut rows : Array Store.MappingRow := #[]
  let mut provs : Array Store.ProvenanceRow := #[]
  for e in entries do
    let str (k : String) : Option String := (e.getObjValAs? String k).toOption
    let some owner := str "owner" | return .error "an entry has no 'owner'"
    let some name := str "name" | return .error "an entry has no 'name'"
    let some kind := str "kind" | return .error "an entry has no 'kind'"
    unless kind == "rubric" || kind == "notes" do
      return .error s!"an entry's kind is '{kind}', not rubric or notes"
    let some version := (e.getObjValAs? Nat "version").toOption
      | return .error "an entry has no 'version'"
    let some commit := str "commit" | return .error "an entry has no 'commit'"
    unless validSha commit do return .error s!"'{commit}' is not a whole commit id"
    rows := rows.push { owner, name, kind, version, commit_sha := commit, imported_at := now }
    let strs (k : String) : List String :=
      ((e.getObjVal? k >>= (·.getArr?)).toOption.getD #[]).toList.filterMap (·.getStr?.toOption)
    let derived := strs "derivedFrom"
    let pulls := strs "derivedFromPulls"
    unless derived.isEmpty && pulls.isEmpty do
      provs := provs.push { owner, name, commit_sha := commit, source := "export"
                          , samples := rawOfStrings derived, prs := rawOfStrings pulls
                          , created_at := now }
  Store.transact do
    for r in rows do HasModel.save r
    for p in provs do HasModel.save p
  return .ok rows.size

/-! ## Provenance -/

/-- Record that commit `commit` of the rubrics repository, for `owner/name`, was derived from
    `p`, by `source`. -/
def recordProvenanceIn (owner name commit source : String) (p : Provenance) : Sqlite.M Unit := do
  HasModel.save ({ owner, name, commit_sha := commit, source, samples := rawOfStrings p.samples
                 , prs := rawOfStrings p.prs, created_at := ← nowIso } : Store.ProvenanceRow)

/-- For `owner/name`, what each commit in `shas` was derived from: every provenance recorded on it
    or on a commit before it — a merged proposal's, an exported version's — whoever changed the
    directory since. Before it is what its lineage says (`recordLineage`): the commits between it
    and the head read before it, and before those, that head's; or the commits of the directory's
    history. A commit no lineage was recorded for, never a head, carries only its own. -/
def provenanceOf (owner name : String) (shas : List String) :
    IO (List (String × Provenance)) := do
  let rows ← Store.run <| HasModel.fetch <| query% do
    let r ← from Store.ProvenanceRow
    guard r.owner = owner
    guard r.name = name
    select r
  if rows.isEmpty then return shas.map (·, {})
  let lineage ← Store.run <| HasModel.fetch <| query% do
    let r ← from Store.LineageRow
    guard r.owner = owner
    guard r.name = name
    select r
  let byCommit : Std.HashMap String Store.LineageRow :=
    lineage.foldl (init := {}) fun m r => m.insert r.commit_sha r
  let before (sha : String) : Std.HashSet String := Id.run do
    let mut seen : Std.HashSet String := {}
    let mut cur := some sha
    -- Bounded, so that a cycle a force-push and its undoing could record cannot hold it.
    for _ in [0:byCommit.size + 1] do
      let some c := cur | break
      if seen.contains c then break
      seen := seen.insert c
      let some row := byCommit[c]? | break
      for x in stringsOfRaw (some row.commits) do seen := seen.insert x
      cur := row.parent_sha
    return seen
  return shas.map fun sha =>
    let set := before sha
    (sha, rows.foldl (init := {}) fun (acc : Provenance) r =>
      if set.contains r.commit_sha then
        acc.union { samples := stringsOfRaw (some r.samples), prs := stringsOfRaw (some r.prs) }
      else acc)

/-! ## What the API shows -/

/-- The files of `owner/name`'s directory in `p`, as the rubrics repository has them. -/
private def filesOf (owner name : String) (p : Parsed) : List String :=
  let dir := directory owner name
  [s!"{dir}/rubric.md"] ++ p.rubric.prTypes.map (fun t => s!"{dir}/types/{t.name}.md") ++
    (if p.styleNotes.isEmpty then [] else [s!"{dir}/style.md"])

/-- The fields of a rubric as the API shows it that are not the document's: a client — a proposal
    agent starting from what it read — that sends it back sends them too, and they are not kept as
    the document's. -/
def viewFields : List String :=
  ["owner", "name", "repository", "branch", "directory", "sha", "headSha", "checkedAt", "error",
   "errors", "exists", "files", "treeUrl", "legacyVersion", "derivedFrom", "derivedFromPulls",
   "styleNotes", "version", "createdAt", "documentError", "fromProposal"]

/-- A repository's rubric as the API shows it, at `snap` (none: none read): the document's fields
    — those this build does not know among them — beside where it is, the files to edit it by, and
    why the head is not it (`errors`, the first as `error`). -/
def viewJson (src : Option Source) (owner name : String) (snap : Option Snapshot)
    (errors : Array FileError) (headSha checkedAt : Option String) (legacy : Option Nat)
    (prov : Provenance) : Json :=
  let dir := directory owner name
  let parsed := snap.bind (·.parsed.toOption)
  let exists' := snap.any (·.tree.isSome)
  let doc : Rubric := if exists' then (parsed.map (·.rubric)).getD {} else {}
  let files : List Json := match src, snap, parsed with
    | some s, some sn, some p =>
      if !exists' then [] else (filesOf owner name p).map fun (path : String) =>
        Json.mkObj [("path", path), ("url", s.blobUrl sn.commit path), ("editUrl", s.editUrl path)]
    | _, _, _ => []
  let optStr (o : Option String) : Json := (o.map Json.str).getD .null
  let fields : List (String × Json) := [
    ("owner", owner), ("name", name), ("repository", optStr (src.map (·.slug))),
    ("branch", optStr (src.map (·.branch))), ("directory", dir),
    ("sha", optStr (snap.map (·.commit))), ("headSha", optStr headSha),
    ("checkedAt", optStr checkedAt),
    ("error", (errors[0]?.map (·.toJson)).getD .null), ("errors", .arr (errors.map (·.toJson))),
    ("exists", exists'), ("files", .arr files.toArray),
    ("treeUrl", optStr (src.map (·.treeUrl dir))),
    ("legacyVersion", (legacy.map fun v => (v : Json)).getD .null),
    ("derivedFrom", .arr (prov.samples.map Json.str).toArray),
    ("derivedFromPulls", .arr (prov.prs.map Json.str).toArray)]
  let known : List (String × Json) := [
    ("defaultRubric", doc.defaultRubric), ("prTypes", .arr (doc.prTypes.map PrType.toJson).toArray),
    ("fanout", doc.fanout), ("styleNotes", (parsed.map (·.styleNotes)).getD "")]
  .mkObj (doc.extra ++ fields ++ known)

/-- `owner/name`'s rubric in use, as the API shows it: see `viewJson`. -/
def currentJson (src : Option Source) (owner name : String) : IO Json := do
  let some s := src
    | return viewJson none owner name none #[{ file := "", message := "no rubrics repository is \
configured (DIFF_REVIEWER_RUBRICS_REPO): reviews have no rubric" }] none none none {}
  let head := (← headOf owner name).getD {}
  let snap ← match head.goodSha with
    | some g => cached g owner name
    | none => pure none
  let errors := if head.readAt.isNone && head.errors.isEmpty then
      #[{ file := "", message := s!"{s.slug} has not been read for {owner}/{name} yet; the \
workers read it on their next pass" }]
    else head.errors
  let legacy ← match head.goodSha with
    | some g => legacyVersion owner name g
    | none => pure none
  let prov ← match head.goodSha with
    | some g => pure (((← provenanceOf owner name [g]).head?.map (·.2)).getD {})
    | none => pure {}
  return viewJson src owner name snap errors head.headSha head.checkedAt legacy prov

/-- `owner/name`'s rubric at commit `sha`, as the API shows it, read if it has not been. -/
def atJson (gh : GitHub.Client) (src : Source) (owner name sha : String) :
    IO (Except String Json) := do
  match ← snapshot gh src sha owner name with
  | .error e => return .error e
  | .ok snap =>
    let errors := match snap.parsed with
      | .ok _ => #[]
      | .error es => es
    let prov := ((← provenanceOf owner name [sha]).head?.map (·.2)).getD {}
    return .ok (viewJson (some src) owner name (some snap) errors none none
      (← legacyVersion owner name sha) prov)

/-- The commits of `src`'s branch that change `owner/name`'s directory, newest first, at most
    `limit`, as the API shows them. -/
def historyJson (gh : GitHub.Client) (src : Source) (owner name : String) (limit : Nat := 200) :
    IO (Except String (Array Json)) := do
  match ← gh.branchHead src.owner src.name src.branch with
  | .ok none => return .ok #[]
  | .error e => return .error (ghError s!"reading the head of {src.slug}" e)
  | .ok (some _) =>
  match ← gh.listCommits src.owner src.name src.branch (directory owner name) limit with
  | .error e => return .error (ghError s!"listing the commits of {directory owner name}" e)
  | .ok cs =>
    let mapping ← mappingRows owner name
    return .ok (cs.map fun c =>
      let legacy := (mapping.find? fun r => r.kind == "rubric" && r.commit_sha == c.sha).map
        (·.version.toNat)
      Json.mkObj [("sha", c.sha), ("message", c.message), ("author", c.authorName),
        ("authorLogin", (c.authorLogin.map Json.str).getD .null), ("date", c.date),
        ("url", src.commitUrl c.sha),
        ("legacyVersion", (legacy.map fun v => (v : Json)).getD .null)])

/-- What changed in `owner/name`'s rubric from commit `base` to commit `head`. -/
def compareJson (gh : GitHub.Client) (src : Source) (owner name base head : String) :
    IO (Except String Json) := do
  let b ← match ← snapshot gh src base owner name with
    | .ok s => pure s
    | .error e => return .error e
  let h ← match ← snapshot gh src head owner name with
    | .ok s => pure s
    | .error e => return .error e
  let (diff, diffError) : Json × Json := match b.parsed, h.parsed with
    | .ok bp, .ok hp =>
      let br := if b.tree.isSome then bp.rubric else {}
      let hr := if h.tree.isSome then hp.rubric else {}
      (diffJson br hr (some (bp.styleNotes, hp.styleNotes)), .null)
    | .error es, _ => (.null, .str s!"{base} does not read: {errorsLine es}")
    | _, .error es => (.null, .str s!"{head} does not read: {errorsLine es}")
  return .ok (.mkObj [("base", base), ("head", head), ("url", src.compareUrl base head),
                      ("diff", diff), ("diffError", diffError)])

end DiffReviewer.Rubrics