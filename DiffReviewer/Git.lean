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

-- Parse a "@@ -old_start[,old_count] +new_start[,new_count] @@" hunk header.
-- Returns the line range in the new file.
private def parseHunkRange (line : String) : Option LineRange := do
  -- Find the "+N" or "+N,M" token; exclude "+++ b/..." file headers
  let token ← line.splitOn " " |>.find? (fun p =>
    p.startsWith "+" && !p.startsWith "+++")
  let inner := dropStr token 1  -- strip leading "+"
  if inner.contains ',' then do
    let parts := inner.splitOn ","
    let startLine ← parts.head?.bind (·.toNat?)
    let count := parts.drop 1 |>.head?.bind (·.toNat?) |>.getD 1
    let endLine := if count == 0 then startLine else startLine + count - 1
    some { startLine, endLine }
  else do
    let startLine ← inner.toNat?
    some { startLine, endLine := startLine }

-- Find the minimal range (new-file lines) and the suggestion content for the first hunk.
-- The suggestion contains exactly the new-file lines in [startLine, endLine].
private def firstHunkRangeAndSuggestion (diff : String) : Option (LineRange × String) := do
  let lines := diff.splitOn "\n"
  let hunkHeader ← lines.find? (·.startsWith "@@ ")
  let baseRange ← parseHunkRange hunkHeader
  let hunkLines := lines
    |>.dropWhile (fun l => !l.startsWith "@@ ")
    |>.drop 1
    |>.takeWhile (fun l => !l.startsWith "diff " && !l.startsWith "@@ ")
  -- First pass: find the minimal range of changed lines.
  let (_, firstChange, lastChange) := hunkLines.foldl
    (fun acc l =>
      let (lineNo, first, last) : Nat × Option Nat × Option Nat := acc
      if l.startsWith "+" && !l.startsWith "+++" then
        (lineNo + 1, some (first.getD lineNo), some lineNo)
      else if l.startsWith "-" && !l.startsWith "---" then
        (lineNo, some (first.getD lineNo), some lineNo)
      else if l.startsWith " " then
        (lineNo + 1, first, last)
      else
        (lineNo, first, last))
    ((baseRange.startLine, none, none) : Nat × Option Nat × Option Nat)
  let startLine ← firstChange
  let endLine ← lastChange
  -- Second pass: collect new-file lines (+ and context) within [startLine, endLine].
  let (_, suggLines) := hunkLines.foldl
    (fun acc l =>
      let (lineNo, content) : Nat × List String := acc
      if l.startsWith "+" && !l.startsWith "+++" then
        let c := if lineNo >= startLine && lineNo <= endLine then content ++ [dropStr l 1] else content
        (lineNo + 1, c)
      else if l.startsWith " " then
        let c := if lineNo >= startLine && lineNo <= endLine then content ++ [dropStr l 1] else content
        (lineNo + 1, c)
      else
        (lineNo, content))
    ((baseRange.startLine, []) : Nat × List String)
  some ({ startLine, endLine }, "\n".intercalate suggLines)

private def rawCommitToComment (rc : RawCommit) : InlineComment :=
  let file := firstFileFromDiff rc.diff |>.getD "unknown"
  let (range, suggestion) := firstHunkRangeAndSuggestion rc.diff
    |>.getD ({ startLine := 1, endLine := 1 }, "")
  let commentBody :=
    if rc.body.isEmpty then rc.subject
    else rc.subject ++ "\n\n" ++ rc.body
  { file
    range
    body       := commentBody
    suggestion := if suggestion.isEmpty then none else some suggestion }

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
