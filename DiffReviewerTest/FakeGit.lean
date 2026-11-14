import DiffReviewer
import DiffReviewerTest.Basic

open Lean (Json)
open DiffReviewer

/-!
# A fake rubrics repository

`FakeGit` is the rubrics repository as GitHub's git data API serves it — refs, commits, trees and
blobs at their shas, the commits that change a path, and a pull request opened from a branch —
over in-memory state, so that following the branch, pinning, a broken head and a proposal's pull
request, merged or closed, are driven without a request leaving the process. Trees and blobs are
named by their contents, as git names them: a directory nothing changed in keeps its tree's sha.
-/

namespace DiffReviewerTest.FakeGit

/-- The rubrics repository of the suite. -/
def source : Rubrics.Source := { owner := "chrisflav", name := "review-rubrics" }

private def hex16 (n : UInt64) : String :=
  let digits := (List.range 16).reverse.map fun i =>
    "0123456789abcdef".toList[((n >>> (4 * i).toUInt64) &&& 15).toNat]!
  String.ofList digits

/-- A sha of 40 hex digits made of `s`, as git's are of an object's contents. -/
def shaOf (s : String) : String :=
  (hex16 (hash s) ++ hex16 (hash (s ++ "\x00")) ++ hex16 (hash ("\x01" ++ s))).take 40 |>.toString

/-- One pull request of the fake: its branch, and what GitHub says of it. -/
structure FakePull where
  pull   : GitHub.Pull
  branch : String

structure FakeGit where
  /-- Every object: a blob's text, or a tree's entries (name, type, sha). -/
  blobs   : IO.Ref (List (String × String))
  trees   : IO.Ref (List (String × Array GitHub.TreeEntry))
  commits : IO.Ref (List (String × GitHub.GitCommit))
  /-- What each root tree holds, path by path. -/
  files   : IO.Ref (List (String × List (String × String)))
  refs    : IO.Ref (List (String × String))
  pulls   : IO.Ref (Array FakePull)
  counter : IO.Ref Nat
  /-- Every request, as `METHOD path`, in order. -/
  calls   : IO.Ref (Array String)
  /-- Whether the token cannot read the repository: GitHub answers every request `404`. -/
  hidden  : IO.Ref Bool

def FakeGit.new : IO FakeGit := do
  return { blobs := ← IO.mkRef [], trees := ← IO.mkRef [], commits := ← IO.mkRef []
         , files := ← IO.mkRef [], refs := ← IO.mkRef [], pulls := ← IO.mkRef #[]
         , counter := ← IO.mkRef 0, calls := ← IO.mkRef #[], hidden := ← IO.mkRef false }

/-- The tree of `files` (paths from it), every tree below it stored: its sha. -/
partial def FakeGit.tree (fg : FakeGit) (files : List (String × String)) : IO String := do
  let here := files.filter fun (p, _) => !p.contains '/'
  let dirs := (files.filterMap fun (p, _) => if p.contains '/' then (p.splitOn "/").head?
    else none).eraseDups
  let mut entries : Array GitHub.TreeEntry := #[]
  for (p, c) in here do
    let sha := shaOf s!"blob {c}"
    fg.blobs.modify ((sha, c) :: ·)
    entries := entries.push { path := p, type := "blob", sha }
  for d in dirs do
    let below := files.filterMap fun (p, c) =>
      if p.startsWith (d ++ "/") then some ((p.drop (d.length + 1)).toString, c) else none
    entries := entries.push { path := d, type := "tree", sha := ← fg.tree below }
  let sorted := entries.qsort (·.path < ·.path)
  let sha := shaOf ("tree " ++ String.join (sorted.toList.map fun e =>
    s!"{e.type} {e.sha} {e.path};"))
  fg.trees.modify ((sha, sorted) :: ·)
  fg.files.modify ((sha, files) :: ·)
  return sha

def FakeGit.filesOf (fg : FakeGit) (tree : String) : IO (List (String × String)) := do
  return ((← fg.files.get).lookup tree).getD []

def FakeGit.head (fg : FakeGit) (branch : String := "main") : IO (Option String) := do
  return (← fg.refs.get).lookup branch

def FakeGit.commitOf (fg : FakeGit) (sha : String) : IO (Option GitHub.GitCommit) := do
  return (← fg.commits.get).lookup sha

/-- A commit of `files` on `parents`: its sha. -/
def FakeGit.commitFiles (fg : FakeGit) (files : List (String × String)) (parents : Array String)
    (message : String) : IO String := do
  let tree ← fg.tree files
  let n ← fg.counter.modifyGet fun n => (n + 1, n + 1)
  let sha := shaOf s!"commit {n} {tree} {parents}"
  let date := s!"2026-11-{if n < 10 then "0" else ""}{n % 28 + 1}T10:00:00Z"
  fg.commits.modify ((sha, { sha, tree, parents, message, authorName := "Christian"
                            , authorLogin := some "chrisflav", date }) :: ·)
  return sha

/-- The files of the head of `branch`, none before its first commit. -/
def FakeGit.headFiles (fg : FakeGit) (branch : String := "main") : IO (List (String × String)) := do
  let some h ← fg.head branch | return []
  let some c ← fg.commitOf h | return []
  fg.filesOf c.tree

/-- Commit `changes` (a path and its new text, or `none` to remove it) on `branch`: its sha. -/
def FakeGit.change (fg : FakeGit) (changes : List (String × Option String))
    (message := "change") (branch := "main") : IO String := do
  let files ← fg.headFiles branch
  let files := changes.foldl (init := files) fun acc (p, c) =>
    let rest := acc.filter (·.1 != p)
    match c with
    | some t => rest ++ [(p, t)]
    | none => rest
  let parents := ((← fg.head branch).map (#[·])).getD #[]
  let sha ← fg.commitFiles files parents message
  fg.refs.modify fun rs => (branch, sha) :: rs.filter (·.1 != branch)
  return sha

/-- Commit `owner/name`'s directory as the document `doc` (the JSON of a rubric document) and
    `notes` render it, in place of what it held: the commit's sha. -/
def FakeGit.setRubric (fg : FakeGit) (owner name doc : String) (notes : String := "")
    (message := "rubric") : IO String := do
  let some r := (Json.parse doc |>.bind Rubric.ofJson).toOption
    | throw (IO.userError s!"not a rubric document: {doc}")
  let dir := s!"{owner}/{name}/"
  let old := (← fg.headFiles).filter (·.1.startsWith dir)
  let new := (RubricFiles.render r notes).map fun f => (dir ++ f.path, some f.content)
  let gone := old.filterMap fun (p, _) =>
    if new.any (·.1 == p) then none else some (p, (none : Option String))
  fg.change (new ++ gone) message

/-- Merge pull request `n`: its branch's changes over its base, committed on the base with both as
    parents, and the pull request closed and merged by it. -/
def FakeGit.merge (fg : FakeGit) (n : Nat) : IO String := do
  let some fp := (← fg.pulls.get)[n - 1]? | throw (IO.userError s!"no pull request {n}")
  let some tip ← fg.head fp.branch | throw (IO.userError "no branch")
  let some c ← fg.commitOf tip | throw (IO.userError "no commit")
  let theirs ← fg.filesOf c.tree
  let base ← match c.parents[0]? with
    | some p => do
      let some pc ← fg.commitOf p | pure []
      fg.filesOf pc.tree
    | none => pure []
  -- What the branch changed over its base.
  let changed := theirs.filter fun (p, t) => base.lookup p != some t
  let removed := base.filter fun (p, _) => (theirs.lookup p).isNone
  let mine ← fg.headFiles
  let merged := (mine.filter fun (p, _) =>
      !changed.any (·.1 == p) && !removed.any (·.1 == p)) ++ changed
  let main := ((← fg.head).map (#[·, tip])).getD #[tip]
  let sha ← fg.commitFiles merged main s!"Merge pull request #{n}"
  fg.refs.modify fun rs => ("main", sha) :: rs.filter (·.1 != "main")
  fg.pulls.modify fun ps => ps.modify (n - 1) fun fp =>
    { fp with pull := { fp.pull with state := "closed", merged := true
                                     mergeCommitSha := some sha } }
  return sha

/-- Move `branch` to `sha`, whatever it was at: a force-push. -/
def FakeGit.forcePush (fg : FakeGit) (sha : String) (branch := "main") : IO Unit :=
  fg.refs.modify fun rs => (branch, sha) :: rs.filter (·.1 != branch)

/-- Every commit `sha` descends from, itself among them. -/
partial def FakeGit.ancestors (fg : FakeGit) (sha : String) : IO (List String) := do
  let rec go (todo : List String) (seen : List String) : IO (List String) := do
    match todo with
    | [] => return seen
    | c :: rest =>
      if seen.contains c then go rest seen else
      let ps := ((← fg.commitOf c).map (·.parents.toList)).getD []
      go (ps ++ rest) (seen ++ [c])
  go [sha] []

/-- Close pull request `n` unmerged. -/
def FakeGit.close (fg : FakeGit) (n : Nat) : IO Unit :=
  fg.pulls.modify fun ps => ps.modify (n - 1) fun fp =>
    { fp with pull := { fp.pull with state := "closed" } }

private def notFound {α : Type} : IO (Except GitHub.Error α) :=
  return .error (.definite "GitHub answered 404: Not Found")

/-- Whether `path` of `files` differs between two file lists. -/
private def differs (path : String) (a b : List (String × String)) : Bool :=
  let under (fs : List (String × String)) :=
    fs.filter fun (p, _) => p == path || p.startsWith (path ++ "/")
  under a != under b

/-- A client that is `base` on every repository but the rubrics repository, which is `fg`. -/
def FakeGit.client (fg : FakeGit) (base : GitHub.Client) : GitHub.Client :=
  let mine (o n : String) := o == source.owner && n == source.name
  let log (s : String) : IO Unit := fg.calls.modify (·.push s)
  { base with
    branchHead := fun o n b => do
      unless mine o n do return ← base.branchHead o n b
      log s!"GET /repos/{o}/{n}/git/ref/heads/{b}"
      if ← fg.hidden.get then
        return .error (.definite s!"{o}/{n} was not found, or the token cannot read it \
(GitHub answered 404: Not Found)")
      -- An empty repository has no head; one with commits and not this branch is an error, as
      -- the client makes it of GitHub's 404 and the repository's 200.
      match ← fg.head b with
      | some h => return .ok (some h)
      | none =>
        if (← fg.refs.get).isEmpty then return .ok none
        return .error (.definite s!"{o}/{n} has no branch {b}")
    compare := fun o n b h => do
      unless mine o n do return ← base.compare o n b h
      log s!"GET /repos/{o}/{n}/compare/{b}...{h}"
      let ofHead ← fg.ancestors h
      let ofBase ← fg.ancestors b
      let status := if b == h then "identical" else if ofHead.contains b then "ahead"
        else if ofBase.contains h then "behind" else "diverged"
      let between := (ofHead.filter (!ofBase.contains ·)).reverse
      return .ok { status, commits := (between.map (·, "")).toArray }
    getCommit := fun o n sha => do
      unless mine o n do return ← base.getCommit o n sha
      log s!"GET /repos/{o}/{n}/git/commits/{sha}"
      match ← fg.commitOf sha with
      | some c => return .ok c
      | none => notFound
    getTree := fun o n sha recursive => do
      unless mine o n do return ← base.getTree o n sha recursive
      log s!"GET /repos/{o}/{n}/git/trees/{sha}{if recursive then "?recursive=1" else ""}"
      let some es := (← fg.trees.get).lookup sha | notFound
      if !recursive then return .ok es
      let files ← fg.filesOf sha
      let blobs := files.map fun (p, c) => ({ path := p, type := "blob"
                                            , sha := shaOf s!"blob {c}" } : GitHub.TreeEntry)
      return .ok blobs.toArray
    getBlob := fun o n sha => do
      unless mine o n do return ← base.getBlob o n sha
      log s!"GET /repos/{o}/{n}/git/blobs/{sha}"
      match (← fg.blobs.get).lookup sha with
      | some c => return .ok c
      | none => notFound
    listCommits := fun o n b path limit => do
      unless mine o n do return ← base.listCommits o n b path limit
      log s!"GET /repos/{o}/{n}/commits?sha={b}&path={path}"
      let mut out := #[]
      -- `sha=` names a branch or a commit.
      let start ← match ← fg.head b with
        | some h => pure (some h)
        | none => pure (if (← fg.commitOf b).isSome then some b else none)
      let mut cur := start
      while out.size < limit do
        let some sha := cur | break
        let some c ← fg.commitOf sha | break
        let mineFiles ← fg.filesOf c.tree
        let parentFiles ← match c.parents[0]? with
          | some p => do
            let some pc ← fg.commitOf p | pure []
            fg.filesOf pc.tree
          | none => pure []
        if differs path mineFiles parentFiles then out := out.push c
        cur := c.parents[0]?
      return .ok out
    createTree := fun o n baseTree changes => do
      unless mine o n do return ← base.createTree o n baseTree changes
      log s!"POST /repos/{o}/{n}/git/trees"
      let files ← fg.filesOf baseTree
      let files := changes.foldl (init := files) fun acc c =>
        let rest := acc.filter (·.1 != c.path)
        match c.content with
        | some t => rest ++ [(c.path, t)]
        | none => rest
      return .ok (← fg.tree files)
    createCommit := fun o n message tree parents => do
      unless mine o n do return ← base.createCommit o n message tree parents
      log s!"POST /repos/{o}/{n}/git/commits"
      return .ok (← fg.commitFiles (← fg.filesOf tree) parents message)
    createBranch := fun o n branch sha => do
      unless mine o n do return ← base.createBranch o n branch sha
      log s!"POST /repos/{o}/{n}/git/refs"
      if (← fg.head branch).isSome then
        return .error (.definite "GitHub answered 422: Reference already exists")
      fg.refs.modify ((branch, sha) :: ·)
      return .ok ()
    createPull := fun o n title head b body => do
      unless mine o n do return ← base.createPull o n title head b body
      log s!"POST /repos/{o}/{n}/pulls"
      let some tip ← fg.head head | return .error (.definite "GitHub answered 422: no branch")
      let num := (← fg.pulls.get).size + 1
      let pull : GitHub.Pull :=
        { number := num, title, body, headSha := tip, baseSha := ((← fg.head b).getD "")
        , htmlUrl := s!"https://github.com/{o}/{n}/pull/{num}" }
      fg.pulls.modify (·.push { pull, branch := head })
      return .ok pull
    findPull := fun o n head => do
      unless mine o n do return ← base.findPull o n head
      log s!"GET /repos/{o}/{n}/pulls?head={o}:{head}&state=all"
      return .ok (((← fg.pulls.get).find? (·.branch == head)).map (·.pull))
    getPull := fun o n num => do
      unless mine o n do return ← base.getPull o n num
      log s!"GET /repos/{o}/{n}/pulls/{num}"
      match (← fg.pulls.get)[num - 1]? with
      | some fp => return .ok fp.pull
      | none => notFound }

/-- A GitHub that knows nothing but the rubrics repository. -/
def bare : GitHub.Client where
  listOpenPulls _ _ := return .ok #[]
  getPull _ _ _ := return .error (.definite "GitHub answered 404: Not Found")
  diff _ _ _ _ := return .error (.definite "GitHub answered 404: Not Found")
  listReviews _ _ _ := return .ok #[]
  postReview _ _ _ _ _ _ := return .error (.definite "GitHub answered 422")

/-- `s` reading the rubrics repository from `fg`, through its GitHub (or `bare`). -/
def FakeGit.attach (fg : FakeGit) (s : Workers.Services) : Workers.Services :=
  { s with github := some (fg.client (s.github.getD bare)), rubrics := some source }

/-- The fake the last `withGit` made: for a test whose helpers commit a rubric without being
    handed the fake. -/
initialize currentRef : IO.Ref (Option FakeGit) ← IO.mkRef none

/-- `s` reading the rubrics repository from a new fake, which `commitRubric` commits to. -/
def withGit (s : Workers.Services) : IO Workers.Services := do
  let fg ← FakeGit.new
  currentRef.set (some fg)
  return fg.attach s

/-- Commit `doc` (a rubric document) as `owner/name`'s to the fake the last `withGit` made, and
    follow the branch once: the commit. -/
def commitRubric (owner name doc : String) (notes : String := "") : IO String := do
  let some fg ← currentRef.get | throw (IO.userError "no fake rubrics repository; use withGit")
  let sha ← fg.setRubric owner name doc notes
  Rubrics.refresh (fg.client bare) source fun _ _ => pure ()
  return sha

/-- One pass of following the branch, as the workers make it. -/
def refresh (s : Workers.Services) : IO Unit := do
  if let some (gh, src) := s.rubricsAt then Rubrics.refresh gh src s.logOnce

end DiffReviewerTest.FakeGit