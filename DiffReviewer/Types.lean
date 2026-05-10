import Lean.Data.Json

namespace DiffReviewer

inductive Decision where
  | comment
  | approve
  | requestChanges
  deriving Repr, BEq

structure LineRange where
  startLine : Nat
  endLine : Nat
  deriving Repr, BEq

structure InlineComment where
  file : String
  range : LineRange
  body : String
  suggestion : Option String
  deriving Repr, BEq

structure Review where
  decision : Decision
  body : String
  comments : List InlineComment
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

def InlineComment.toJson (c : InlineComment) : Lean.Json :=
  let fields : List (String × Lean.Json) := [
    ("file",       c.file),
    ("start_line", c.range.startLine),
    ("end_line",   c.range.endLine),
    ("body",       c.body)
  ]
  let fields := match c.suggestion with
    | none   => fields
    | some s => fields ++ [("suggestion", (s : Lean.Json))]
  .mkObj fields

def InlineComment.ofJson (j : Lean.Json) : Except String InlineComment := do
  let file      ← (← j.getObjVal? "file").getStr?
  let startLine ← (← j.getObjVal? "start_line").getNat?
  let endLine   ← (← j.getObjVal? "end_line").getNat?
  let body      ← (← j.getObjVal? "body").getStr?
  let suggestion : Option String :=
    (j.getObjVal? "suggestion").toOption.bind (·.getStr?.toOption)
  return { file, range := { startLine, endLine }, body, suggestion }

def Review.toJson (r : Review) : Lean.Json :=
  .mkObj [
    ("decision", r.decision.toJson),
    ("body",     r.body),
    ("comments", .arr (r.comments.map InlineComment.toJson).toArray)
  ]

def Review.ofJson (j : Lean.Json) : Except String Review := do
  let decision ← Decision.ofJson (← j.getObjVal? "decision")
  let body     ← (← j.getObjVal? "body").getStr?
  let arr      ← (← j.getObjVal? "comments").getArr?
  let comments ← arr.toList.mapM InlineComment.ofJson
  return { decision, body, comments }

def Review.toJsonString (r : Review) : String :=
  r.toJson.pretty

def Review.ofJsonString (s : String) : Except String Review :=
  (Lean.Json.parse s).bind Review.ofJson

end DiffReviewer
