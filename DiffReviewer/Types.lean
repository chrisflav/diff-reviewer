import Lean.Data.Json

/-!
# The review format

A review is a decision, a summary and inline comments on line ranges of the files the pull request
changes, each with an optional suggestion. It is what the agent submits, what a person edits and
what is posted to GitHub, and it is stored as the JSON `Review.toJson` writes.

Three things make a stored review a record that later milestones can learn from rather than a
snapshot:

  * **Every comment has an `id`**, short and random, unique within its review. The platform
    assigns one to a comment that has none when the review is written — submitted or edited
    (`Review.assignIds`) — and keeps the one a comment has, so that a comment can be followed
    from the agent's draft through each edit to what was posted. A review stored before ids
    existed gets them on its next write, never on a read: reading changes nothing.
  * **A comment may say what it is about**: a `category` (one of the repository's rubric
    categories, when its rubric names any) and a `severity` (`nit`, `minor`, `major`, `blocker`).
  * **Fields this build does not know survive.** A review or comment read with fields a newer
    build (or the front-end) wrote carries them in `extra` and writes them back as they were, so
    that a round trip through this build loses nothing. A known field of the wrong type, and a
    severity this build does not know, are errors instead: such a review is shown as unreadable
    and left as it is, as an unknown decision is.
-/

namespace DiffReviewer

/-- How unknown fields are shown by `repr`: as their JSON. -/
instance : Repr Lean.Json := ⟨fun j _ => .text j.compress⟩

inductive Decision where
  | comment
  | approve
  | requestChanges
  deriving Repr, BEq

/-- How much a comment matters: a `nit` may be ignored, a `blocker` must be fixed before merging. -/
inductive Severity where
  | nit
  | minor
  | major
  | blocker
  deriving Repr, BEq, DecidableEq

def Severity.all : List Severity := [.nit, .minor, .major, .blocker]

def Severity.toString : Severity → String
  | .nit     => "nit"
  | .minor   => "minor"
  | .major   => "major"
  | .blocker => "blocker"

def Severity.ofString? (s : String) : Option Severity :=
  Severity.all.find? (·.toString == s)

structure LineRange where
  startLine : Nat
  endLine : Nat
  deriving Repr, BEq

structure InlineComment where
  file : String
  range : LineRange
  body : String
  suggestion : Option String
  /-- Stable within the review; assigned when the review is written, if absent. -/
  id : Option String := none
  /-- What the comment is about: one of the repository's rubric categories, or free text when
      its rubric names none. -/
  category : Option String := none
  severity : Option Severity := none
  /-- The fields this build does not know, written back as they were read. -/
  extra : List (String × Lean.Json) := []
  deriving Repr, BEq

structure Review where
  decision : Decision
  body : String
  comments : List InlineComment
  /-- The fields this build does not know, written back as they were read. -/
  extra : List (String × Lean.Json) := []
  deriving Repr, BEq

-- JSON serialization

def Decision.toJson : Decision → Lean.Json
  | .comment        => "comment"
  | .approve        => "approve"
  | .requestChanges => "request_changes"

def Decision.ofJson (j : Lean.Json) : Except String Decision := do
  let s ← j.getStr?
  match s with
  | "comment"         => .ok .comment
  | "approve"         => .ok .approve
  | "request_changes" => .ok .requestChanges
  | v                 => .error s!"unknown decision '{v}'"

def LineRange.toJson (r : LineRange) : Lean.Json :=
  .mkObj [("start_line", r.startLine), ("end_line", r.endLine)]

def LineRange.ofJson (j : Lean.Json) : Except String LineRange := do
  let startLine ← (← j.getObjVal? "start_line").getNat?
  let endLine   ← (← j.getObjVal? "end_line").getNat?
  return { startLine, endLine }

/-- The fields of object `j` not named in `known`: what a record keeps in its `extra` and writes
    back, so that a field this build does not know survives it. -/
def unknownFields (j : Lean.Json) (known : List String) : List (String × Lean.Json) :=
  match j.getObj? with
  | .ok kvs => kvs.toList.filter (!known.contains ·.1)
  | .error _ => []

/-- Optional string field `k` of `j`: absent or `null` is `none`, anything but a string an error. -/
private def optStrField (j : Lean.Json) (k : String) : Except String (Option String) :=
  match j.getObjVal? k with
  | .error _ | .ok .null => .ok none
  | .ok (.str s) => .ok (some s)
  | .ok _ => .error s!"'{k}' must be a string"

private def commentFields : List String :=
  ["file", "start_line", "end_line", "body", "suggestion", "id", "category", "severity"]

def InlineComment.toJson (c : InlineComment) : Lean.Json :=
  let opt (k : String) : Option String → List (String × Lean.Json)
    | none   => []
    | some s => [(k, (s : Lean.Json))]
  -- The unknown fields first, so that a known field is never shadowed by one of them.
  let known : List (String × Lean.Json) := [
    ("file",       c.file),
    ("start_line", c.range.startLine),
    ("end_line",   c.range.endLine),
    ("body",       c.body)]
  .mkObj (c.extra ++ known ++
    opt "suggestion" c.suggestion ++ opt "id" c.id ++ opt "category" c.category ++
    opt "severity" (c.severity.map (·.toString)))

def InlineComment.ofJson (j : Lean.Json) : Except String InlineComment := do
  let file      ← (← j.getObjVal? "file").getStr?
  let startLine ← (← j.getObjVal? "start_line").getNat?
  let endLine   ← (← j.getObjVal? "end_line").getNat?
  let body      ← (← j.getObjVal? "body").getStr?
  let suggestion : Option String :=
    (j.getObjVal? "suggestion").toOption.bind (·.getStr?.toOption)
  let id ← optStrField j "id"
  let category ← optStrField j "category"
  let severity ← match ← optStrField j "severity" with
    | none => pure none
    | some s => match Severity.ofString? s with
      | some v => pure (some v)
      | none => throw s!"unknown severity '{s}': it is one of nit, minor, major, blocker"
  return { file, range := { startLine, endLine }, body, suggestion, id, category, severity
         , extra := unknownFields j commentFields }

def Review.toJson (r : Review) : Lean.Json :=
  let known : List (String × Lean.Json) := [
    ("decision", r.decision.toJson),
    ("body",     r.body),
    ("comments", .arr (r.comments.map InlineComment.toJson).toArray)]
  .mkObj (r.extra ++ known)

def Review.ofJson (j : Lean.Json) : Except String Review := do
  let decision ← Decision.ofJson (← j.getObjVal? "decision")
  let body     ← (← j.getObjVal? "body").getStr?
  let arr      ← (← j.getObjVal? "comments").getArr?
  let comments ← arr.toList.zipIdx.mapM fun (c, i) =>
    (InlineComment.ofJson c).mapError (s!"comment {i + 1}: " ++ ·)
  return { decision, body, comments, extra := unknownFields j ["decision", "body", "comments"] }

def Review.toJsonString (r : Review) : String :=
  r.toJson.pretty

def Review.ofJsonString (s : String) : Except String Review :=
  (Lean.Json.parse s).bind Review.ofJson

/-- The longest comment id accepted. The platform's own are 8 characters. -/
def maxCommentIdLength : Nat := 64

/-- The longest category accepted, a rubric's or free text. -/
def maxCategoryLength : Nat := 100

/-- Whether `s` can be a comment id: what fits in a URL or an HTML id unescaped. -/
def validCommentId (s : String) : Bool :=
  !s.isEmpty && s.length ≤ maxCommentIdLength &&
    s.all fun c => c.isAlphanum || c == '-' || c == '_'

/-- The most inline comments a review may carry. Past a few hundred GitHub's review endpoint and
    any reader give out, and kleis's request-body limits on the agent API are sized for this
    many. -/
def maxInlineComments : Nat := 200

/-- Why `r` could not be posted as a GitHub review, or `ok`: a comment or a request for changes
    says something in its summary (GitHub refuses either with an empty body), and every comment
    names a file and a line range starting at 1 with its end at or after its start, and says
    something; and there are at most `maxInlineComments` comments. A comment's `id`, when it has
    one, is `validCommentId` and unique within the review, and its `category` says something.
    Checked when a review is written — submitted, edited — and again before it is posted, so a
    review that GitHub would refuse is refused before it is stored. Whether the comments' lines
    are in the diff is `Diff.check`, and whether their categories are the rubric's
    `checkCategories`. -/
def Review.validate (r : Review) : Except String Unit := do
  if r.comments.length > maxInlineComments then
    throw s!"the review carries {r.comments.length} inline comments; a review may carry at most \
{maxInlineComments} inline comments, so merge or drop the least important"
  if r.decision != .approve && r.body.trimAscii.isEmpty then
    throw "the summary ('body') is empty; GitHub requires one unless the review approves"
  for (c, i) in r.comments.zipIdx do
    let at_ := s!"comment {i + 1}"
    if c.file.trimAscii.isEmpty then throw s!"{at_} names no file"
    if c.range.startLine == 0 then throw s!"{at_}: lines start at 1"
    if c.range.endLine < c.range.startLine then
      throw s!"{at_}: end_line {c.range.endLine} is before start_line {c.range.startLine}"
    if c.body.trimAscii.isEmpty && c.suggestion.isNone then throw s!"{at_} says nothing"
    if let some id := c.id then
      unless validCommentId id do
        throw s!"{at_}: 'id' must be 1 to {maxCommentIdLength} letters, digits, '-' or '_'"
      if (r.comments.filter (·.id == some id)).length > 1 then
        throw s!"{at_}: another comment has the id '{id}'; ids are unique within a review"
    if let some cat := c.category then
      if cat.trimAscii.isEmpty || cat.length > maxCategoryLength then
        throw s!"{at_}: 'category' must be 1 to {maxCategoryLength} characters"

/-- Why a comment of `r` names a category outside `allowed`, if one does. An empty `allowed` is a
    repository whose rubric names no categories, where any category is free text. -/
def Review.checkCategories (r : Review) (allowed : List String) : Except String Unit := do
  if allowed.isEmpty then return
  for (c, i) in r.comments.zipIdx do
    if let some cat := c.category then
      unless allowed.contains cat do
        throw s!"comment {i + 1}: '{cat}' is not a category of the rubric; it is one of \
{", ".intercalate allowed}"

/-- A fresh comment id: 4 random bytes, hex-encoded. Short, since a person reads them in the API
    and the history; 2^32 is plenty for at most `maxInlineComments` comments. -/
private def freshCommentId : IO String := do
  let bytes ← IO.getRandomBytes 4
  let hex (n : Nat) : Char := "0123456789abcdef".toList[n % 16]!
  return String.ofList (bytes.toList.flatMap fun b => [hex (b.toNat / 16), hex b.toNat])

/-- `r` with an id on every comment: the ones they carry, and a fresh one, unused in `r`, for
    each comment without. Done when a review is written, never when it is read. -/
def Review.assignIds (r : Review) : IO Review := do
  let mut used : List String := r.comments.filterMap (·.id)
  let mut out : Array InlineComment := #[]
  for c in r.comments do
    if c.id.isSome then
      out := out.push c
    else
      let mut id ← freshCommentId
      while used.contains id do id ← freshCommentId
      used := id :: used
      out := out.push { c with id := some id }
  return { r with comments := out.toList }

end DiffReviewer