import Lean.Data.Json
import DiffReviewer.Calibration

open Lean (Json)

/-!
# Review style, learned from examples

How a repository's reviews are written — how long a comment is, how direct, whether it suggests
or asks — is easier to show than to describe. So the agent is shown: `agent show` carries
`examples`, up to `maxExamples` inline comments the repository's trusted reviewers wrote, taken
from its calibration samples (`examplesFor`), and the prompt tells it to write in their style
without copying them. Beside them, the operator's `styleNotes` (`Repo.styleNotes`) say in words
what the examples cannot, and end the agent's instructions.

**Which comments.** Of the samples not deleted whose reviewer is still trusted, the `full` and
`partial` ones — a `decision` sample has no comments — and of their comments those of a short to
medium length (`minExampleChars` to `maxExampleChars`): a one-word comment shows no style, and a
page-long one crowds out the rest. Picked greedily, for variety rather than recency alone: each
pick prefers a file not shown yet, then a category not shown yet, then the scope and the length
(short or medium) shown less so far, then a sample not used yet; ties go to the most recently
reviewed. Deterministic: the same samples give the same examples, so a calibration run is not
scored against a draw.

**Categories.** A person's comment carries no category of its own. Where calibration paired it
with one of the agent's comments, that comment's category is the example's; otherwise it has
none, and is shown without.

**What is never shown.** Nothing of the pull request under review: every sample of the job's pull
request is left out, whatever the job's kind. For a review job that is the job's own sample, if
it has one; for a calibration job, it is the sample it is scored against and every other review
of the same pull request, so the human review the job is scored against never reaches the agent,
nor anything said beside it.
-/

namespace DiffReviewer.Style

open Score (HumanComment)

/-- The most examples `agent show` carries. -/
def maxExamples : Nat := 20

/-- The shortest and longest comment shown, in characters of its trimmed body. -/
def minExampleChars : Nat := 20

def maxExampleChars : Nat := 600

/-- Past this a comment is `medium`, and below it `short`. -/
def shortExampleChars : Nat := 160

/-- The most recent samples looked at: enough for variety, few enough to read on every
    `agent show`. -/
def maxSamplesRead : Nat := 200

/-- One example, as `agent show` gives it. -/
structure Example where
  file      : String
  startLine : Nat
  line      : Nat
  body      : String
  /-- The category of the agent's comment calibration paired it with, if there was one. -/
  category  : Option String
  /-- `full` or `partial`: the scope of the sample it is from. -/
  scope     : String
  /-- Which sample it is from: what the picking spreads over, never shown. -/
  sampleId  : String
  /-- Which comment it is: what keeps it from being picked twice, never shown. -/
  commentId : Nat
  deriving Repr, BEq, Inhabited

def Example.toJson (e : Example) : Json :=
  .mkObj [("file", e.file), ("start_line", e.startLine), ("end_line", e.line), ("body", e.body),
          ("category", (e.category.map Json.str).getD .null), ("scope", e.scope)]

private def short (e : Example) : Bool := e.body.trimAscii.toString.length < shortExampleChars

/-- How well `e` adds to `picked`: a file not shown counts most, then a category not shown, then
    the scope and the length shown less, then a sample not used; as a tuple compared in order. -/
private def gain (picked : Array Example) (e : Example) : Nat × Nat × Nat × Nat × Nat :=
  let count (p : Example → Bool) := (picked.filter p).size
  let newFile := if picked.any (·.file == e.file) then 0 else 1
  let newCategory := match e.category with
    | some c => if picked.any (·.category == some c) then 0 else 1
    | none => 0
  let scopeLess :=
    if count (·.scope == e.scope) ≤ count (·.scope != e.scope) then 1 else 0
  let lengthLess :=
    if count (short · == short e) ≤ count (short · != short e) then 1 else 0
  let newSample := if picked.any (·.sampleId == e.sampleId) then 0 else 1
  (newFile, newCategory, scopeLess, lengthLess, newSample)

private def better (a b : Nat × Nat × Nat × Nat × Nat) : Bool :=
  a.1 > b.1 || (a.1 == b.1 && (a.2.1 > b.2.1 || (a.2.1 == b.2.1 && (a.2.2.1 > b.2.2.1 ||
    (a.2.2.1 == b.2.2.1 && (a.2.2.2.1 > b.2.2.2.1 ||
      (a.2.2.2.1 == b.2.2.2.1 && a.2.2.2.2 > b.2.2.2.2)))))))

/-- Up to `n` of `candidates`, in the order they are picked; see the module's description. The
    candidates are in order of preference among equals (the most recent first). -/
def pick (candidates : Array Example) (n : Nat := maxExamples) : Array Example := Id.run do
  let mut picked : Array Example := #[]
  let mut left := candidates
  for _ in [0:n] do
    let some first := left[0]? | break
    let mut best := 0
    let mut bestGain := gain picked first
    for (e, i) in left.zipIdx do
      let g := gain picked e
      if better g bestGain then
        best := i
        bestGain := g
    picked := picked.push left[best]!
    left := left.eraseIdx! best
  return picked

/-- Whether a comment is of a length to show. -/
def showable (body : String) : Bool :=
  let n := body.trimAscii.toString.length
  minExampleChars ≤ n && n ≤ maxExampleChars

/-- The categories calibration's pairs give the person's comments of `owner/name`: GitHub's id of
    the comment, and the category of the agent's comment it was paired with. -/
private def pairedCategories (owner name : String) : IO (List (Nat × String)) := do
  let mut out : List (Nat × String) := []
  for row in ← Calibration.scoresOf owner name do
    let some score := (Json.parse row.score).toOption | continue
    let some pairs := (score.getObjVal? "pairs").toOption.bind (·.getArr?.toOption) | continue
    for p in pairs do
      let human := (p.getObjVal? "human").toOption.bind (·.getObjValAs? Nat "id" |>.toOption)
      let cat := (p.getObjVal? "agent").toOption.bind (·.getObjValAs? String "category" |>.toOption)
      if let (some h, some c) := (human, cat) then
        unless out.any (·.1 == h) do out := (h, c) :: out
  return out

/-- The examples for `job` of `repo`: see the module's description. -/
def examplesFor (repo : Repo) (job : Job) : IO (Array Example) := do
  if repo.trustedReviewers.isEmpty then return #[]
  let samples := (← Calibration.listSamples repo.owner repo.name).filter fun s =>
    s.prNumber != job.prNumber && repo.trustedReviewers.contains s.reviewer &&
      (s.scope == "full" || s.scope == "partial")
  let samples := samples.extract 0 maxSamplesRead
  let cats ← pairedCategories repo.owner repo.name
  let candidates := samples.flatMap fun s =>
    (s.comments.filter (showable ·.body)).toArray.map fun (c : HumanComment) =>
      { file := c.path, startLine := c.startLine, line := c.line, body := c.body.trimAscii.toString
      , category := cats.lookup c.id, scope := s.scope, sampleId := s.id, commentId := c.id }
  return pick candidates

end DiffReviewer.Style