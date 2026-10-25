import DiffReviewer.Types

/-!
# Which lines a review may comment on

GitHub takes an inline comment only on a line the pull request's diff shows: on the right-hand
side, a line of a hunk of the file's new version (an added line or a context line). A comment
anywhere else makes GitHub refuse the whole review (`422`). So a review is checked against the diff
before it is accepted from the agent and again before it is posted, and the error says which
comment and which hunks there are, which is what the agent needs to fix it.

Only what this needs is parsed: each file's new path (`+++ b/…`) and its hunk headers
(`@@ -a,b +c,d @@`), giving the right-hand lines `c .. c+d-1`.
-/

namespace DiffReviewer.Diff

/-- Each file of a unified diff, with the right-hand line ranges of its hunks. A deleted file
    (`+++ /dev/null`) has none. -/
def rightHunks (diff : String) : List (String × List (Nat × Nat)) := Id.run do
  let mut files : Array (String × Array (Nat × Nat)) := #[]
  for line in diff.splitOn "\n" do
    if line.startsWith "+++ " then
      let path := (line.drop 4).toString.trimAscii.toString
      let path := if path.startsWith "b/" then (path.drop 2).toString else path
      files := files.push (path, #[])
    else if line.startsWith "@@ " && !files.isEmpty then
      -- `@@ -a[,b] +c[,d] @@ …`
      let some plus := (line.splitOn " ").find? (·.startsWith "+") | continue
      let nums := ((plus.drop 1).toString.splitOn ",").map String.toNat?
      let (start, count) := match nums with
        | [some c] => (c, 1)
        | [some c, some d] => (c, d)
        | _ => (0, 0)
      if count == 0 then continue
      let (p, hs) := files.back!
      files := files.pop.push (p, hs.push (start, start + count - 1))
  return files.toList.map fun (p, hs) => (p, hs.toList)

private def showHunks : List (Nat × Nat) → String
  | [] => "none"
  | hs => ", ".intercalate (hs.map fun (a, b) => s!"{a}-{b}")

/-- Why `r` has a comment GitHub would refuse against `diff`, if it has one: on a file the diff
    does not touch, or on lines no single hunk of it shows on the right-hand side. -/
def check (r : Review) (diff : String) : Except String Unit := do
  let files := rightHunks diff
  for (c, i) in r.comments.zipIdx do
    let at_ := s!"comment {i + 1} ({c.file}:{c.range.startLine}-{c.range.endLine})"
    let some (_, hunks) := files.find? (·.1 == c.file)
      | throw s!"{at_}: the diff does not change {c.file}"
    unless hunks.any (fun (a, b) => a ≤ c.range.startLine && c.range.endLine ≤ b) do
      throw s!"{at_}: the lines are not all in one hunk of the diff's new side; its hunks there \
are lines {showHunks hunks}"

end DiffReviewer.Diff