import DiffReviewer.Types

namespace DiffReviewer

private structure RawCommit where
  hash    : String
  subject : String
  body    : String
  diff    : String

private def splitCommits (log : String) : List String :=
  let lines := log.splitOn "\n"
  let (blocks, current) := lines.foldl (fun (acc, cur) line =>
    if line.startsWith "commit " && !cur.isEmpty then
      (acc ++ ["\n".intercalate cur], [line])
    else
      (acc, cur ++ [line]))
    ([], [])
  if current.isEmpty then blocks
  else blocks ++ ["\n".intercalate current]

private def trimStr (s : String) : String := s.trimAscii.toString
private def dropStr (s : String) (n : Nat) : String := (s.drop n).toString

private def parseCommitBlock (block : String) : Option RawCommit := do
  let lines := block.splitOn "\n"
  let hashLine ← lines.head?
  guard (hashLine.startsWith "commit ")
  let hash := trimStr (dropStr hashLine 7)
  let rest := lines.drop 1
  let msgLines := rest.dropWhile (fun l =>
    l.startsWith "Author:" || l.startsWith "Date:" || l.startsWith "Merge:" || l == "")
  let (msgLines, diffLines) := msgLines.span (fun l => !l.startsWith "diff --git")
  let subject := trimStr (msgLines.head?.getD "")
  let bodyLines := msgLines.drop 1 |>.dropWhile (· == "")
  let body := trimStr ("\n".intercalate bodyLines)
  let diff := "\n".intercalate diffLines
  some { hash, subject, body, diff }

private def firstFileFromDiff (diff : String) : Option String :=
  diff.splitOn "\n"
    |>.find? (·.startsWith "diff --git ")
    |>.bind (fun line =>
      -- "diff --git a/foo/bar b/foo/bar"
      let parts := line.splitOn " "
      parts.drop 3 |>.head? |>.map (fun p =>
        if p.startsWith "b/" then dropStr p 2 else p))

private def rawCommitToComment (rc : RawCommit) : InlineComment :=
  let file := firstFileFromDiff rc.diff |>.getD "unknown"
  let commentBody :=
    if rc.body.isEmpty then rc.subject
    else rc.subject ++ "\n\n" ++ rc.body
  { file
    range      := { startLine := 1, endLine := 1 }
    body       := commentBody
    suggestion := if rc.diff.isEmpty then none else some rc.diff }

/-- Parse the output of `git log -p --reverse <range>` into a `Review`. -/
def parseGitLog (logOutput : String) : Review :=
  let commits := splitCommits logOutput
    |>.filterMap parseCommitBlock
    |>.filter (fun rc => !rc.hash.isEmpty)
  let comments := commits.map rawCommitToComment
  { decision := .comment
    body     := s!"Review generated from {commits.length} commit(s)."
    comments }

/-- Run `git log -p --reverse <range>` in the current directory and return a `Review`. -/
def reviewFromGit (range : String) : IO (Except String Review) := do
  let result ← IO.Process.output { cmd := "git", args := #["log", "-p", "--reverse", range] }
  if result.exitCode != 0 then
    return .error (if result.stderr.isEmpty then result.stdout else result.stderr)
  return .ok (parseGitLog result.stdout)

end DiffReviewer
