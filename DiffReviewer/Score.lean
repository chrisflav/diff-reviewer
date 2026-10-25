import Lean.Data.Json
import DiffReviewer.Types

open Lean (Json)

/-!
# Scoring a review against a person's

Calibration asks how the agent's review of a commit compares with a trusted reviewer's review of
the same commit. This module is the comparison, and nothing else: no database, no GitHub.

**Matching.** Each of the agent's inline comments is paired with at most one of the person's, and
each of the person's with at most one of the agent's (`matchComments`). Two comments can be paired
when they are on the same file and their line ranges overlap or lie within `matchWindow` lines of
each other; of all such candidates the closest are paired first — the smallest gap, then the
smallest difference of their ends — and a comment once paired is out. Greedy rather than an optimal
assignment: on a few dozen comments the two rarely differ, and a greedy match is easy to explain.

The match is by place only. Two comments on the same lines may say different things, and two that
say the same thing may sit a screen apart, so the numbers are a lower bound on agreement in the
first case and an upper one in the second. A later matcher — a semantic judge reading the pairs —
is expected; so every score names the `matcherVersion` that made it, a better matcher writes scores
of its own version beside the old ones rather than over them, and every pair is named by its two
comment ids (`Pair.key`), which a judge's verdict can refer to from a record of its own.

**What is reported** (`Score`): the agent's comments that found a match (*precision*), the
person's that were found (*recall*), precision for each of the agent's categories and severities,
whether the agent's decision was the person's, the pairs, and what was left over on each side.
Counts are kept beside every ratio, and aggregates (`Aggregate`) add counts up before dividing, so
that a review with one comment weighs as one comment, not as a whole review.

**Scope.** A sample whose comments are not the whole of what the person said — some were dropped,
being on the old side or not on a line of the commit (`partial`) — or that is an approval or a
request for changes saying nothing else (`decision`) is scored for its decision only: its comments
are still paired, to be read, but it has no precision or recall of its own and adds nothing to an
aggregate's; its decision counts.
-/

namespace DiffReviewer.Score

/-- The version of the matcher below. Bumped whenever a change could pair comments differently:
    a score is only comparable with scores of its own version. -/
def matcherVersion : Nat := 1

/-- How many lines apart two ranges may be and still be paired. -/
def matchWindow : Nat := 3

/-- One of the person's inline comments, on the new side of the diff at the review's commit. -/
structure HumanComment where
  /-- GitHub's id of the comment. -/
  id        : Nat
  path      : String
  startLine : Nat
  line      : Nat
  body      : String
  deriving Repr, BEq

def HumanComment.toJson (c : HumanComment) : Json :=
  .mkObj [("id", c.id), ("path", c.path), ("start_line", c.startLine), ("line", c.line),
          ("body", c.body)]

def HumanComment.ofJson (j : Json) : Except String HumanComment := do
  let line ← j.getObjValAs? Nat "line"
  return { id := ← j.getObjValAs? Nat "id", path := ← j.getObjValAs? String "path"
         , startLine := (j.getObjValAs? Nat "start_line").toOption.getD line, line
         , body := (j.getObjValAs? String "body").toOption.getD "" }

/-- The lines between two ranges: 0 when they overlap. -/
def gap (a1 b1 a2 b2 : Nat) : Nat :=
  if b1 < a2 then a2 - b1 else if b2 < a1 then a1 - b2 else 0

/-- How far apart the ends of two ranges are: what breaks a tie between ranges at the same gap. -/
private def offset (a1 b1 a2 b2 : Nat) : Nat :=
  (if a1 ≤ a2 then a2 - a1 else a1 - a2) + (if b1 ≤ b2 then b2 - b1 else b1 - b2)

/-- A pairing of the agent's comment `agent` with the person's `human`, by their indices. -/
structure Pair where
  agent : Nat
  human : Nat
  gap   : Nat
  deriving Repr, BEq

/-- The one-to-one greedy match of `agent`'s comments with `human`'s, closest first; see the
    module's description. Answers the pairs in the order they were made. -/
def matchComments (agent : List InlineComment) (human : List HumanComment) : List Pair := Id.run do
  let mut cands : Array (Nat × Nat × Nat × Nat) := #[]
  for (a, i) in agent.zipIdx do
    for (h, j) in human.zipIdx do
      if a.file != h.path then continue
      let g := gap a.range.startLine a.range.endLine h.startLine h.line
      if g ≤ matchWindow then
        cands := cands.push (g, offset a.range.startLine a.range.endLine h.startLine h.line, i, j)
  let lt (x y : Nat × Nat × Nat × Nat) : Bool :=
    x.1 < y.1 || (x.1 == y.1 && (x.2.1 < y.2.1 || (x.2.1 == y.2.1 &&
      (x.2.2.1 < y.2.2.1 || (x.2.2.1 == y.2.2.1 && x.2.2.2 < y.2.2.2)))))
  let mut usedA : Array Nat := #[]
  let mut usedH : Array Nat := #[]
  let mut pairs : Array Pair := #[]
  for (g, _, i, j) in cands.qsort lt do
    if usedA.contains i || usedH.contains j then continue
    usedA := usedA.push i
    usedH := usedH.push j
    pairs := pairs.push { agent := i, human := j, gap := g }
  return pairs.toList

/-- How many of some of the agent's comments there were, and how many of them were paired. -/
structure Tally where
  comments : Nat := 0
  matched  : Nat := 0
  deriving Repr, BEq, Inhabited

def Tally.add (a b : Tally) : Tally :=
  { comments := a.comments + b.comments, matched := a.matched + b.matched }

/-- `n / d` to four decimals, as a JSON number; `null` when there is nothing to divide by. -/
def ratio (n d : Nat) : Json :=
  if d == 0 then .null else .num ⟨((n * 20000 + d) / (2 * d) : Nat), 4⟩

/-- The tallies of a grouping, as `[{key, comments, matched, precision}]`, in key order. -/
private def talliesJson (key : String) (ts : List (Option String × Tally)) : Json :=
  let sorted := (ts.toArray.qsort fun x y => (x.1.getD "") < (y.1.getD "")).toList
  .arr (sorted.map fun (k, t) =>
    Json.mkObj [(key, (k.map Json.str).getD .null), ("comments", t.comments),
                ("matched", t.matched), ("precision", ratio t.matched t.comments)]).toArray

private def talliesOfJson (key : String) (j : Json) : List (Option String × Tally) :=
  match j.getArr? with
  | .ok xs => xs.toList.filterMap fun x =>
    let k := (x.getObjValAs? String key).toOption
    match x.getObjValAs? Nat "comments", x.getObjValAs? Nat "matched" with
    | .ok c, .ok m => some (k, { comments := c, matched := m })
    | _, _ => none
  | .error _ => []

/-- Add `t` to the tally of `k` in `ts`. -/
def bump (ts : List (Option String × Tally)) (k : Option String) (t : Tally) :
    List (Option String × Tally) :=
  if ts.any (·.1 == k) then ts.map fun (k', t') => if k' == k then (k', t'.add t) else (k', t')
  else ts ++ [(k, t)]

/-- The decision a person's review stands for, by GitHub's `state`: `none` for one that stands
    for none (`DISMISSED`, `PENDING`), which is not compared. -/
def decisionOfState : String → Option Decision
  | "APPROVED"          => some .approve
  | "CHANGES_REQUESTED" => some .requestChanges
  | "COMMENTED"         => some .comment
  | _                   => none

/-- What a sample is scored for: everything (`full`), or its decision only (`partial`,
    `decision`). -/
def commentsCount (scope : String) : Bool := scope == "full"

/-- What the matcher says of one calibration job: its review against its sample's. -/
structure Score where
  matcherVersion : Nat := Score.matcherVersion
  /-- The sample's scope: `full`, `partial` or `decision`. -/
  scope          : String := "full"
  agentComments  : Nat
  humanComments  : Nat
  matched        : Nat
  byCategory     : List (Option String × Tally)
  bySeverity     : List (Option String × Tally)
  agentDecision  : Decision
  /-- The person's review's `state`, as GitHub gave it. -/
  humanState     : String
  /-- Whether the two decisions are one; `none` when the person's state stands for none. -/
  agree          : Option Bool
  pairs          : List (InlineComment × HumanComment × Nat)
  unmatchedAgent : List InlineComment
  unmatchedHuman : List HumanComment

/-- Score `agent`, the agent's review, against a person's review in state `state` with inline
    comments `human`. -/
def score (agent : Review) (state : String) (human : List HumanComment) (scope := "full") :
    Score := Id.run do
  let pairs := matchComments agent.comments human
  let matchedA := pairs.map (·.agent)
  let matchedH := pairs.map (·.human)
  let mut byCategory := []
  let mut bySeverity := []
  for (c, i) in agent.comments.zipIdx do
    let t : Tally := { comments := 1, matched := if matchedA.contains i then 1 else 0 }
    byCategory := bump byCategory c.category t
    bySeverity := bump bySeverity (c.severity.map (·.toString)) t
  let human? := decisionOfState state
  return { scope, agentComments := agent.comments.length, humanComments := human.length
         , matched := pairs.length, byCategory, bySeverity, agentDecision := agent.decision
         , humanState := state, agree := human?.map (· == agent.decision)
         , pairs := pairs.filterMap fun p => do
             return (← agent.comments[p.agent]?, ← human[p.human]?, p.gap)
         , unmatchedAgent := (agent.comments.zipIdx.filter (!matchedA.contains ·.2)).map (·.1)
         , unmatchedHuman := (human.zipIdx.filter (!matchedH.contains ·.2)).map (·.1) }

/-- How a pair is named: the agent's comment id and GitHub's id of the person's, which neither a
    later edit nor a re-import changes. What a later judge's verdict on the pair refers to. -/
def Pair.key (a : InlineComment) (h : HumanComment) : String :=
  s!"{a.id.getD "?"}:{h.id}"

private def agentJson (c : InlineComment) : Json :=
  .mkObj [("id", (c.id.map Json.str).getD .null), ("file", c.file),
          ("start_line", c.range.startLine), ("end_line", c.range.endLine), ("body", c.body),
          ("category", (c.category.map Json.str).getD .null),
          ("severity", (c.severity.map (Json.str ·.toString)).getD .null)]

def Score.toJson (s : Score) : Json :=
  let counts := commentsCount s.scope
  .mkObj [
    ("matcherVersion", s.matcherVersion), ("scope", s.scope),
    ("agentComments", s.agentComments), ("humanComments", s.humanComments),
    ("matched", s.matched),
    ("precision", if counts then ratio s.matched s.agentComments else .null),
    ("recall", if counts then ratio s.matched s.humanComments else .null),
    ("byCategory", talliesJson "category" s.byCategory),
    ("bySeverity", talliesJson "severity" s.bySeverity),
    ("decision", .mkObj [("agent", s.agentDecision.toJson), ("human", s.humanState),
      ("agree", (s.agree.map Json.bool).getD .null)]),
    ("pairs", .arr (s.pairs.map fun (a, h, g) =>
      Json.mkObj [("key", Pair.key a h), ("gap", g), ("agent", agentJson a),
                  ("human", h.toJson)]).toArray),
    ("unmatchedAgent", .arr (s.unmatchedAgent.map agentJson).toArray),
    ("unmatchedHuman", .arr (s.unmatchedHuman.map HumanComment.toJson).toArray)]

/-! ## Aggregates -/

/-- Scores added up: counts, from which every ratio is computed afresh. -/
structure Aggregate where
  scored        : Nat := 0
  /-- Of them, those whose comments count: of `full` samples. -/
  commentsScored : Nat := 0
  agentComments : Nat := 0
  humanComments : Nat := 0
  matched       : Nat := 0
  byCategory    : List (Option String × Tally) := []
  bySeverity    : List (Option String × Tally) := []
  /-- Reviews whose decisions could be compared, and those where they were one. -/
  decisions     : Nat := 0
  agreed        : Nat := 0
  /-- How often each pair of decisions occurred, agent's then person's state. -/
  confusion     : List ((String × String) × Nat) := []
  deriving Inhabited

/-- Add a stored score, `Score.toJson` as written, to `a`: its decision, and its comments when its
    scope says they count (a score written without a scope is `full`). A score that does not read
    — one marked `unscorable` among them — is left out, and so answers `none`. -/
def Aggregate.add (a : Aggregate) (j : Json) : Option Aggregate := do
  let counts := commentsCount ((j.getObjValAs? String "scope").toOption.getD "full")
  let n (k : String) : Option Nat := do
    let v ← (j.getObjValAs? Nat k).toOption
    return if counts then v else 0
  let d := (j.getObjVal? "decision").toOption.getD .null
  let agree := (d.getObjValAs? Bool "agree").toOption
  let pair := ((d.getObjValAs? String "agent").toOption.getD "?",
               (d.getObjValAs? String "human").toOption.getD "?")
  let confusion := if a.confusion.any (·.1 == pair) then
      a.confusion.map fun (p, c) => if p == pair then (p, c + 1) else (p, c)
    else a.confusion ++ [(pair, 1)]
  let tallies (k : String) := if counts then (j.getObjVal? k).toOption.getD .null else .null
  let byCategory := (talliesOfJson "category" (tallies "byCategory"))
    |>.foldl (fun ts (k, t) => bump ts k t) a.byCategory
  let bySeverity := (talliesOfJson "severity" (tallies "bySeverity"))
    |>.foldl (fun ts (k, t) => bump ts k t) a.bySeverity
  return { scored := a.scored + 1
         , commentsScored := a.commentsScored + (if counts then 1 else 0)
         , agentComments := a.agentComments + (← n "agentComments")
         , humanComments := a.humanComments + (← n "humanComments")
         , matched := a.matched + (← n "matched"), byCategory, bySeverity
         , decisions := a.decisions + (if agree.isSome then 1 else 0)
         , agreed := a.agreed + (if agree == some true then 1 else 0), confusion }

def Aggregate.toJson (a : Aggregate) : Json :=
  .mkObj [
    ("matcherVersion", matcherVersion), ("scored", a.scored),
    ("commentsScored", a.commentsScored),
    ("agentComments", a.agentComments), ("humanComments", a.humanComments),
    ("matched", a.matched),
    ("precision", ratio a.matched a.agentComments), ("recall", ratio a.matched a.humanComments),
    ("byCategory", talliesJson "category" a.byCategory),
    ("bySeverity", talliesJson "severity" a.bySeverity),
    ("decisions", .mkObj [("compared", a.decisions), ("agreed", a.agreed),
      ("agreement", ratio a.agreed a.decisions),
      ("matrix", .arr (a.confusion.map fun ((ag, h), c) =>
        Json.mkObj [("agent", ag), ("human", h), ("count", c)]).toArray)])]

end DiffReviewer.Score