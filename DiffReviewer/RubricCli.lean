import Lean.Data.Json
import DiffReviewer.Rubrics

open Lean (Json)

/-!
# The rubrics commands

  * `diff-reviewer rubrics check <dir>` (`check`): whether a checkout of the rubrics repository is
    one the platform reads — every `<owner>/<name>/` directory in it parsed as the workers parse it
    (`RubricFiles.parseDir`), and every error printed as `file:line: message`. For the rubrics
    repository's CI: a pull request that would break a rubric is refused before it is merged,
    rather than kept out of use by the platform after.
  * `diff-reviewer rubrics export --db <db> --out <dir>` (`exportDb`): the rubrics, and the style
    notes, the database kept before rubrics lived in git, as a new git repository in the layout of
    the rubrics repository — one commit per version, in the order they were written, each dated
    when its version was written; a version that changes nothing is the commit before it, with
    what it was derived from folded into that commit's — and a mapping of each version to its
    commit, beside it (`<dir>.mapping.json`, or `--mapping <file>`), with what each commit was
    derived from.
  * `diff-reviewer rubrics import-mapping --db <db> <file>` (`importMapping`): that mapping loaded
    into a database (`Rubrics.importMapping`), so that the jobs and scores that name a version
    find its commit. `serve` loads it too, on start-up, when `DIFF_REVIEWER_RUBRICS_MAPPING` names
    the file.
-/

namespace DiffReviewer.RubricCli

open Db.Query.DSL
open RubricFiles (FileError)

/-! ## Check -/

/-- Every file under `dir`, by its path from `dir`, dotfiles among them: the platform reads a
    directory whole, and refuses a dotfile in `types/`. -/
partial def filesUnder (dir : System.FilePath) (prefix_ : String := "") :
    IO (Array (String × System.FilePath)) := do
  let mut out := #[]
  let entries := (← dir.readDir).qsort (·.fileName < ·.fileName)
  for e in entries do
    let rel := if prefix_.isEmpty then e.fileName else s!"{prefix_}/{e.fileName}"
    if ← e.path.isDir then out := out ++ (← filesUnder e.path rel)
    else out := out.push (rel, e.path)
  return out

/-- What is wrong with the rubric directories of the checkout at `root`, and how many there are:
    see the module's description. A directory's name must be a repository's, in lower case — the
    platform names every repository so. -/
def checkDir (root : System.FilePath) : IO (Nat × Array FileError) := do
  let mut errors : Array FileError := #[]
  let mut count := 0
  let owners := (← root.readDir).qsort (·.fileName < ·.fileName)
  for o in owners do
    if o.fileName.startsWith "." || !(← o.path.isDir) then continue
    for n in (← o.path.readDir).qsort (·.fileName < ·.fileName) do
      if n.fileName.startsWith "." || !(← n.path.isDir) then continue
      let dir := Rubrics.directory o.fileName n.fileName
      count := count + 1
      unless validSlugPart o.fileName && validSlugPart n.fileName do
        errors := errors.push { file := dir, message := "not a GitHub repository's owner/name" }
        continue
      if o.fileName.toLower != o.fileName || n.fileName.toLower != n.fileName then
        errors := errors.push { file := dir, message := s!"the platform names repositories in \
lower case: rename it {dir.toLower}" }
        continue
      let mut files := #[]
      for (rel, path) in ← filesUnder n.path do
        let wanted := rel == "rubric.md" || rel == "style.md" ||
          (rel.startsWith "types/" && rel.endsWith ".md")
        files := files.push ({ path := rel, content := ← if wanted then IO.FS.readFile path
                                                        else pure "" } : RubricFiles.File)
      match RubricFiles.parseDir files.toList with
      | .ok _ => pure ()
      | .error es => errors := errors ++ es.map (·.under dir)
  return (count, errors)

/-- `diff-reviewer rubrics check <dir>`: the errors, one a line, and the exit code. -/
def check (root : System.FilePath) : IO UInt32 := do
  unless ← root.isDir do
    IO.eprintln s!"error: {root} is not a directory"
    return 1
  let (count, errors) ← checkDir root
  for e in errors do IO.eprintln e.render
  if errors.isEmpty then
    IO.println s!"{count} rubric director{if count == 1 then "y" else "ies"}, all of them read"
    return 0
  IO.eprintln s!"{errors.size} error(s) in {count} rubric director{if count == 1 then "y" else
    "ies"}"
  return 1

/-! ## Export -/

/-- `git` in `dir` with `args`, as the export runs it: no hooks, no signing, its identity and date
    given. Its standard output, or an error with what it said. -/
def git (dir : System.FilePath) (args : Array String) (date : Option String := none) :
    IO (Except String String) := do
  let who := [("GIT_AUTHOR_NAME", "diff-reviewer"), ("GIT_COMMITTER_NAME", "diff-reviewer"),
              ("GIT_AUTHOR_EMAIL", "diff-reviewer@localhost"),
              ("GIT_COMMITTER_EMAIL", "diff-reviewer@localhost")]
  let dates := match date with
    | some d => [("GIT_AUTHOR_DATE", d), ("GIT_COMMITTER_DATE", d)]
    | none => []
  let env := (who ++ dates).toArray.map fun (k, v) => (k, some v)
  let out ← IO.Process.output
    { cmd := "git"
    , args := #["-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] ++ args
    , cwd := some dir, env }
  if out.exitCode != 0 then
    return .error s!"git {" ".intercalate args.toList}: {out.stderr.trimAscii}"
  return .ok out.stdout.trimAscii.toString

/-- One version the database kept: of a repository's rubric or its style notes. -/
private structure Version where
  owner     : String
  name      : String
  /-- `rubric` or `notes`. -/
  kind      : String
  version   : Nat
  createdAt : String
  rubric    : Option (Except String Rubric) := none
  notes     : String := ""
  derived   : Provenance := {}

private def versionsOf : IO (Array Version) := do
  let rubrics ← Store.run <| HasModel.fetch <| query% do
    let r ← from Store.RubricRow
    select r
  let notes ← Store.run <| HasModel.fetch <| query% do
    let n ← from Store.NotesRow
    select n
  let rs := rubrics.map fun r =>
    ({ owner := r.owner, name := r.name, kind := "rubric", version := r.version.toNat
     , createdAt := r.created_at, rubric := some ((Json.parse r.document).bind Rubric.ofJson)
     , derived := { samples := stringsOfRaw r.derived_samples, prs := stringsOfRaw r.derived_prs } }
     : Version)
  let ns := notes.map fun n =>
    ({ owner := n.owner, name := n.name, kind := "notes", version := n.version.toNat
     , createdAt := n.created_at, notes := n.notes
     , derived := { samples := stringsOfRaw (some n.derived_samples)
                  , prs := stringsOfRaw (some n.derived_prs) } } : Version)
  -- In the order they were written; a repository's versions in their order.
  return (rs ++ ns).qsort fun a b =>
    a.createdAt < b.createdAt || (a.createdAt == b.createdAt &&
      (a.owner < b.owner || (a.owner == b.owner && (a.name < b.name || (a.name == b.name &&
        (a.kind > b.kind || (a.kind == b.kind && a.version < b.version)))))))

/-- What a repository's directory holds as the export goes: its rubric and notes so far, and
    what each was derived from. -/
private structure DirState where
  rubric       : Rubric := {}
  notes        : String := ""
  rubricProv   : Provenance := {}
  notesProv    : Provenance := {}
  /-- The last commit that changed the directory. -/
  lastCommit   : Option String := none

/-- Write `owner/name`'s directory under `out` as `st` says, replacing what was there. -/
private def writeDir (out : System.FilePath) (owner name : String) (st : DirState) : IO Unit := do
  let dir := out / owner / name
  if ← dir.isDir then IO.FS.removeDirAll dir
  for f in RubricFiles.render st.rubric st.notes do
    let path := dir / f.path
    if let some parent := path.parent then IO.FS.createDirAll parent
    IO.FS.writeFile path f.content

/-- `diff-reviewer rubrics export`: see the module's description. `out` must not exist, or be
    empty. Answers the exit code. -/
def exportDb (db out : System.FilePath) (mapping : Option System.FilePath) (branch : String) :
    IO UInt32 := do
  let fail (why : String) : IO UInt32 := do
    IO.eprintln s!"error: {why}"
    return 1
  unless ← db.pathExists do return ← fail s!"{db} does not exist"
  if ← out.pathExists then
    unless (← out.isDir) && (← out.readDir).isEmpty do
      return ← fail s!"{out} exists and is not an empty directory"
  IO.FS.createDirAll out
  let mappingPath := mapping.getD ⟨(out.toString.dropEndWhile (· == '/')).toString ++
    ".mapping.json"⟩
  Store.setPath db
  let versions ← versionsOf
  if let .error e ← git out #["init", "-q", "-b", branch] then return ← fail e
  let mut states : List ((String × String) × DirState) := []
  let mut entries : Array Json := #[]
  for v in versions do
    let key := (v.owner, v.name)
    let st := (states.lookup key).getD {}
    let st ← match v.kind, v.rubric with
      | "rubric", some (.ok r) =>
        -- A type whose name cannot be a file's is left out, and said so: the rest is kept.
        let bad := r.prTypes.filter fun t => (RubricFiles.typeNameProblem t.name).isSome
        for t in bad do
          IO.eprintln s!"warning: {v.owner}/{v.name}'s rubric version {v.version} has a type \
'{t.name}' that cannot be a file's name ({(RubricFiles.typeNameProblem t.name).getD ""}); it is \
left out"
        let r := { r with prTypes := r.prTypes.filter fun t =>
          (RubricFiles.typeNameProblem t.name).isNone }
        pure { st with rubric := r, rubricProv := v.derived }
      | "rubric", _ =>
        IO.eprintln s!"warning: {v.owner}/{v.name}'s rubric version {v.version} cannot be read \
by this build; it is left out, and has no commit"
        continue
      | _, _ => pure { st with notes := v.notes, notesProv := v.derived }
    states := (key, st) :: states.filter (·.1 != key)
    writeDir out v.owner v.name st
    -- What was written reads back, as the platform will read it.
    let mut files : Array RubricFiles.File := #[]
    for (rel, path) in ← filesUnder (out / v.owner / v.name) do
      files := files.push { path := rel, content := ← IO.FS.readFile path }
    if let .error es := RubricFiles.parseDir files.toList then
      return ← fail s!"{v.owner}/{v.name}'s {v.kind} version {v.version}, written, does not \
read: {Rubrics.errorsLine (es.map (·.under (Rubrics.directory v.owner v.name)))}"
    if let .error e ← git out #["add", "-A", "--", Rubrics.directory v.owner v.name] then
      return ← fail e
    let what := if v.kind == "rubric" then "rubric" else "style notes"
    let msg := s!"{v.owner}/{v.name}: {what} version {v.version}\n\nExported from the \
diff-reviewer database, where it was written at {v.createdAt}."
    let dir := Rubrics.directory v.owner v.name
    let changed ← match ← git out #["status", "--porcelain", "--", dir] with
      | .ok s => pure !s.isEmpty
      | .error e => return ← fail e
    -- The commit carries what both its rubric and its notes were derived from.
    let prov := st.rubricProv.union st.notesProv
    let provJson (p : Provenance) : List (String × Json) :=
      [("derivedFrom", .arr (p.samples.map Json.str).toArray),
       ("derivedFromPulls", .arr (p.prs.map Json.str).toArray)]
    let sha ← match changed, st.lastCommit with
      | false, some last =>
        -- A version that changes nothing is no commit — a history of the directory would skip
        -- an empty one, and what it was derived from with it — but the last commit that changed
        -- the directory: what it was derived from is folded into that commit's.
        entries := entries.map fun e =>
          let same := (e.getObjValAs? String "commit").toOption == some last &&
            (e.getObjValAs? String "owner").toOption == some v.owner &&
            (e.getObjValAs? String "name").toOption == some v.name
          if !same then e else
            let old : Provenance :=
              { samples := ((e.getObjVal? "derivedFrom" >>= (·.getArr?)).toOption.getD #[]).toList
                  |>.filterMap (·.getStr?.toOption)
                prs := ((e.getObjVal? "derivedFromPulls" >>= (·.getArr?)).toOption.getD #[]).toList
                  |>.filterMap (·.getStr?.toOption) }
            (provJson (old.union prov)).foldl (fun e (k, x) => e.setObjVal! k x) e
        IO.println s!"{last} {v.owner}/{v.name} {what} version {v.version} (no change: the \
commit before)"
        pure last
      | _, _ =>
        if let .error e ← git out #["commit", "-q", "--no-verify", "-m", msg]
            (date := some v.createdAt) then
          return ← fail e
        match ← git out #["rev-parse", "HEAD"] with
        | .ok s =>
          IO.println s!"{s} {v.owner}/{v.name} {what} version {v.version}"
          pure s
        | .error e => return ← fail e
    states := (key, { st with lastCommit := some sha }) :: states.filter (·.1 != key)
    let prov := if changed then prov else
      (((entries.find? fun e => (e.getObjValAs? String "commit").toOption == some sha &&
          (e.getObjValAs? String "owner").toOption == some v.owner &&
          (e.getObjValAs? String "name").toOption == some v.name).map fun e =>
        ({ samples := ((e.getObjVal? "derivedFrom" >>= (·.getArr?)).toOption.getD #[]).toList
              |>.filterMap (·.getStr?.toOption)
           prs := ((e.getObjVal? "derivedFromPulls" >>= (·.getArr?)).toOption.getD #[]).toList
              |>.filterMap (·.getStr?.toOption) } : Provenance)).getD prov)
    let fields : List (String × Json) := [("owner", v.owner), ("name", v.name), ("kind", v.kind),
      ("version", v.version), ("commit", sha), ("createdAt", v.createdAt)]
    entries := entries.push (.mkObj (fields ++ provJson prov))
  IO.FS.writeFile mappingPath (Json.mkObj [("branch", branch), ("entries", .arr entries)]).pretty
  IO.println s!"{entries.size} version(s) exported to {out}; the mapping is {mappingPath}"
  return 0

/-- `diff-reviewer rubrics import-mapping`: the mapping at `file` loaded into `db`. -/
def importMapping (db file : System.FilePath) : IO UInt32 := do
  let j ← match Json.parse (← IO.FS.readFile file) with
    | .ok j => pure j
    | .error e =>
      IO.eprintln s!"error: {file} is not JSON: {e}"
      return 1
  Store.setPath db
  match ← Rubrics.importMapping j with
  | .ok n =>
    IO.println s!"{n} version(s) mapped to their commits"
    return 0
  | .error e =>
    IO.eprintln s!"error: {file}: {e}"
    return 1

end DiffReviewer.RubricCli