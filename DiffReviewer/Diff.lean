import DiffReviewer.Types

/-!
# Which lines a review may comment on

GitHub takes an inline comment only on a line the pull request's diff shows: on the right-hand
side, a line of a hunk of the file's new version (an added line or a context line). A comment
anywhere else makes GitHub refuse the whole review (`422`). So a review is checked against the diff
before it is accepted from the agent and again before it is posted, and the error says which
comment and which hunks there are, which is what the agent needs to fix it.

Only what this needs is parsed: each file's new path (`+++ b/…`, unquoted when git quoted it) and
its hunks (`@@ -a,b +c,d @@`), giving the right-hand lines `c .. c+d-1`. A hunk's lines are counted
off its header, so that inside a hunk a removed line reading `-- x` or an added one reading `++ x`
is content, never a file header.
-/

namespace DiffReviewer.Diff

/-- A path as git writes it in a header: as it is, or — holding a space, a quote, a control
    character or a byte past ASCII — in double quotes with C escapes, a non-ASCII byte as `\ooo`. -/
def unquote (s : String) : String := Id.run do
  unless s.length ≥ 2 && s.startsWith "\"" && s.endsWith "\"" do return s
  let cs := ((s.drop 1).dropEnd 1).toString.toList
  let mut out : ByteArray := .empty
  let mut i := 0
  while h : i < cs.length do
    let c := cs[i]
    if c == '\\' && i + 1 < cs.length then
      let n := cs[i + 1]!
      let octal (d : Char) : Bool := '0' ≤ d && d ≤ '7'
      if octal n && (cs[i + 2]?.any octal) && (cs[i + 3]?.any octal) then
        let v := (n.toNat - 48) * 64 + (cs[i + 2]!.toNat - 48) * 8 + (cs[i + 3]!.toNat - 48)
        out := out.push v.toUInt8
        i := i + 4
      else
        let e := match n with
          | 'n' => '\n' | 't' => '\t' | 'r' => '\r' | 'a' => '\x07' | 'b' => '\x08'
          | 'f' => '\x0c' | 'v' => '\x0b' | c => c
        out := out ++ (String.singleton e).toUTF8
        i := i + 2
    else
      out := out ++ (String.singleton c).toUTF8
      i := i + 1
  return (String.fromUTF8? out).getD s

/-- `a[,b]` of a hunk header: the start and the count, which is 1 when it is left out. -/
private def range? (s : String) : Option (Nat × Nat) :=
  match (s.splitOn ",").map String.toNat? with
  | [some a] => some (a, 1)
  | [some a, some b] => some (a, b)
  | _ => none

/-- Each file of a unified diff, with the right-hand line ranges of its hunks. A deleted file
    (`+++ /dev/null`) has none. -/
def rightHunks (diff : String) : List (String × List (Nat × Nat)) := Id.run do
  let mut files : Array (String × Array (Nat × Nat)) := #[]
  -- The lines of the current hunk still to come, on the old side and the new.
  let mut oldLeft := 0
  let mut newLeft := 0
  for line in diff.splitOn "\n" do
    if oldLeft > 0 || newLeft > 0 then
      if line.startsWith "\\" then continue
      if line.startsWith "-" then oldLeft := oldLeft - 1
      else if line.startsWith "+" then newLeft := newLeft - 1
      else
        oldLeft := oldLeft - 1
        newLeft := newLeft - 1
      continue
    if line.startsWith "+++ " then
      let path := unquote (line.drop 4).toString.trimAscii.toString
      let path := if path.startsWith "b/" then (path.drop 2).toString else path
      files := files.push (path, #[])
    else if line.startsWith "@@ " && !files.isEmpty then
      -- `@@ -a[,b] +c[,d] @@ …`
      let words := line.splitOn " "
      let side (sign : String) : Option (Nat × Nat) :=
        (words.find? (·.startsWith sign)).bind fun w => range? (w.drop 1).toString
      let some (_, oldCount) := side "-" | continue
      let some (start, count) := side "+" | continue
      oldLeft := oldCount
      newLeft := count
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