import Lean.Data.Json

open Lean (Json)

/-!
# Rubrics

What a repository's maintainers want a review to look at. A rubric document is a default rubric —
markdown that applies to every pull request of the repository — and a list of **pull request
types**, each with a name, a description that says when it applies, a rubric of its own and the
**categories** its comments are filed under.

The agent is given all of it (`GET /api/agent/v1/…`): it picks the type that fits the pull
request, follows that type's rubric with the default one, and files each comment under one of the
type's categories with a severity. Its submission names the type, which must be one of the
document's (or `null` when there are none), and the job records the type and the version of the
document it was checked against.

A document is stored whole and versioned: every change is a new version, and the old ones are
kept. A job's review is only understood next to the rubric it was written to, and calibration
(M3, M4) compares reviews across rubric changes; a rubric edited in place would lose both.
-/

namespace DiffReviewer

structure Category where
  name        : String
  description : String := ""
  deriving Repr, BEq

structure PrType where
  name        : String
  /-- When the type applies, for the agent choosing one. -/
  description : String := ""
  /-- How to review a pull request of this type, in markdown; on top of the default rubric. -/
  rubric      : String := ""
  categories  : List Category := []
  deriving Repr, BEq

structure Rubric where
  /-- How to review any pull request of the repository, in markdown. -/
  defaultRubric : String := ""
  prTypes       : List PrType := []
  deriving Repr, BEq

def Category.toJson (c : Category) : Json :=
  .mkObj [("name", c.name), ("description", c.description)]

def PrType.toJson (t : PrType) : Json :=
  .mkObj [("name", t.name), ("description", t.description), ("rubric", t.rubric),
          ("categories", .arr (t.categories.map Category.toJson).toArray)]

def Rubric.toJson (r : Rubric) : Json :=
  .mkObj [("defaultRubric", r.defaultRubric),
          ("prTypes", .arr (r.prTypes.map PrType.toJson).toArray)]

/-- Field `k` of `j`, a string; absent or `null` is `""`. -/
private def strField (j : Json) (k : String) (what : String) : Except String String :=
  match j.getObjVal? k with
  | .error _ | .ok .null => .ok ""
  | .ok (.str s) => .ok s
  | .ok _ => .error s!"{what}: '{k}' must be a string"

/-- Field `k` of `j`, an array; absent or `null` is empty. -/
private def arrField (j : Json) (k : String) (what : String) : Except String (List Json) :=
  match j.getObjVal? k with
  | .error _ | .ok .null => .ok []
  | .ok (.arr xs) => .ok xs.toList
  | .ok _ => .error s!"{what}: '{k}' must be an array"

def Category.ofJson (j : Json) (what : String) : Except String Category := do
  let some name := (j.getObjValAs? String "name").toOption
    | throw s!"{what} must have a 'name'"
  return { name, description := ← strField j "description" what }

def PrType.ofJson (j : Json) (what : String) : Except String PrType := do
  let some name := (j.getObjValAs? String "name").toOption
    | throw s!"{what} must have a 'name'"
  let what := s!"{what} ('{name}')"
  let categories ← (← arrField j "categories" what).zipIdx.mapM fun (c, i) =>
    Category.ofJson c s!"{what}, category {i + 1}"
  return { name, description := ← strField j "description" what
         , rubric := ← strField j "rubric" what, categories }

def Rubric.ofJson (j : Json) : Except String Rubric := do
  unless j.getObj?.isOk do throw "the rubric document must be an object"
  let prTypes ← (← arrField j "prTypes" "the document").zipIdx.mapM fun (t, i) =>
    PrType.ofJson t s!"pull request type {i + 1}"
  return { defaultRubric := ← strField j "defaultRubric" "the document", prTypes }

/-- The most pull request types a document may name, and categories a type may. -/
def maxPrTypes : Nat := 50

def maxCategories : Nat := 50

/-- The longest name of a type or a category. -/
def maxRubricNameLength : Nat := 100

/-- The longest rubric, default or a type's, in bytes. -/
def maxRubricBytes : Nat := 65536

/-- Why `r` is not a document to store, if it is not: a type or category without a name, or with
    one another has, or past the bounds above. -/
def Rubric.validate (r : Rubric) : Except String Unit := do
  let name (what n : String) : Except String Unit := do
    if n.trimAscii.isEmpty then throw s!"{what} has an empty name"
    if n.length > maxRubricNameLength then
      throw s!"{what}'s name is longer than {maxRubricNameLength} characters"
  let size (what s : String) : Except String Unit := do
    if s.utf8ByteSize > maxRubricBytes then
      throw s!"{what} is longer than {maxRubricBytes} bytes"
  size "the default rubric" r.defaultRubric
  if r.prTypes.length > maxPrTypes then
    throw s!"the document names {r.prTypes.length} pull request types; at most {maxPrTypes}"
  for (t, i) in r.prTypes.zipIdx do
    let what := s!"pull request type {i + 1}"
    name what t.name
    if (r.prTypes.filter (·.name == t.name)).length > 1 then
      throw s!"two pull request types are called '{t.name}'"
    size s!"the rubric of '{t.name}'" t.rubric
    if t.categories.length > maxCategories then
      throw s!"'{t.name}' names {t.categories.length} categories; at most {maxCategories}"
    for (c, j) in t.categories.zipIdx do
      name s!"category {j + 1} of '{t.name}'" c.name
      if (t.categories.filter (·.name == c.name)).length > 1 then
        throw s!"'{t.name}' has two categories called '{c.name}'"

def Rubric.findType? (r : Rubric) (name : String) : Option PrType :=
  r.prTypes.find? (·.name == name)

/-- The categories a comment of a review of type `prType` may be filed under: the type's, when it
    names any, and otherwise every category of the document. Empty when the document names none,
    and then a category is free text. -/
def Rubric.categoriesFor (r : Rubric) (prType : Option String) : List String :=
  let own := ((prType.bind r.findType?).map (·.categories.map (·.name))).getD []
  if !own.isEmpty then own else
    (r.prTypes.flatMap (·.categories.map (·.name))).eraseDups

/-- Why `prType` is not a type a submission under `r` may name, if it is not: one of the
    document's types, or `null` when it names none. -/
def Rubric.checkPrType (r : Rubric) (prType : Option String) : Except String Unit :=
  match prType, r.prTypes with
  | none, [] => .ok ()
  | some t, [] =>
    .error s!"'prType' is '{t}', but the repository's rubric names no pull request types; send null"
  | none, ts =>
    .error s!"'prType' must name the type of the pull request, one of \
{", ".intercalate (ts.map (·.name))}"
  | some t, ts =>
    if ts.any (·.name == t) then .ok ()
    else .error s!"'{t}' is not a pull request type of the repository's rubric; it is one of \
{", ".intercalate (ts.map (·.name))}"

end DiffReviewer