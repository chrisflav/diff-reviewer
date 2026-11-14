import Lean.Data.Json
import DiffReviewer.Rubric
import Std.Data.HashSet

open Lean (Json)

/-!
# Rubrics as files

A repository's rubric lives in the rubrics repository (`DiffReviewer.Rubrics`) as a directory of
markdown files, `<owner>/<name>/`:

  * `rubric.md` — the default rubric, in its body; its front matter may set `fanout` and
    `types`, the order the pull request types are listed in (those it leaves out follow, by name).
  * `types/<type>.md` — one pull request type, named by its file: in its front matter its
    `description`, `fanout` and `categories`, a mapping of each category's name to its description
    in the order they are listed; in its body its rubric.
  * `style.md` — the style notes, the whole file.

Any other front-matter key is kept, as an unknown field of the document, the type or (when a
category is written as a mapping, `name: {description: …, …}`) the category: what a newer build
reads passes through this one. A directory that is not there is no rubric; a `rubric.md` that is
not there is an empty default rubric.

Front matter is the YAML between a first line `---` and the next line `---` (a byte order mark
before it is dropped), at most 64 KiB and 1000 keys and items. This build reads the part of YAML
front matter needs, and refuses the rest rather than guess: mappings and lists by
indentation, plain, single- and double-quoted scalars, `|` and `>` block scalars, and flow
collections written as JSON. Anchors, aliases, tags and tabs are refused. Every error names the
file and, where it has one, the line, so that the check (`diff-reviewer rubrics check`) can be
read against the file.

`render` writes a document back as such a directory: what the export of the old versions and a
rubric proposal's pull request commit.
-/

namespace DiffReviewer.RubricFiles

/-- What is wrong with one file of a rubric directory, and where. -/
structure FileError where
  /-- The file's path in the rubrics repository (or, before it is placed, in the directory). -/
  file    : String
  line    : Option Nat := none
  message : String
  deriving Repr, BEq, Inhabited

def FileError.toJson (e : FileError) : Json :=
  .mkObj [("file", e.file), ("line", (e.line.map fun n => (n : Json)).getD .null),
          ("message", e.message)]

def FileError.ofJson? (j : Json) : Option FileError := do
  let message ← (j.getObjValAs? String "message").toOption
  return { file := (j.getObjValAs? String "file").toOption.getD ""
         , line := (j.getObjValAs? Nat "line").toOption, message }

/-- `file:line: message`, as a compiler says it. -/
def FileError.render (e : FileError) : String :=
  let place := match e.line with
    | some n => s!"{e.file}:{n}"
    | none => e.file
  if place.isEmpty then e.message else s!"{place}: {e.message}"

/-- `e` placed under `dir`. -/
def FileError.under (dir : String) (e : FileError) : FileError :=
  { e with file := if e.file.isEmpty then dir else s!"{dir}/{e.file}" }

/-! ## YAML, the part front matter needs -/

/-- A YAML value, its mappings in the order they are written and with the line of each key. -/
inductive Yaml where
  | null
  | bool (b : Bool)
  | num (n : Lean.JsonNumber)
  | str (s : String)
  | seq (xs : Array (Nat × Yaml))
  | map (kvs : Array (String × Nat × Yaml))
  /-- A flow collection, read as the JSON it is. -/
  | json (j : Json)
  deriving Inhabited

partial def Yaml.toJson : Yaml → Json
  | .null => .null
  | .bool b => .bool b
  | .num n => .num n
  | .str s => .str s
  | .seq xs => .arr (xs.map (·.2.toJson))
  | .map kvs => .mkObj (kvs.toList.map fun (k, _, v) => (k, v.toJson))
  | .json j => j

/-- A line where something went wrong, and what. -/
abbrev YErr := Nat × String

private structure Ln where
  num    : Nat
  indent : Nat
  /-- After the indentation, without trailing whitespace. -/
  text   : String
  raw    : String
  deriving Inhabited

private def Ln.blank (l : Ln) : Bool := l.text.isEmpty || l.text.startsWith "#"

private def lineSplit (s : String) : List String :=
  (s.splitOn "\n").map fun l => (l.dropEndWhile (· == '\r')).toString

private def linesOf (s : String) (first : Nat) : Except YErr (Array Ln) := do
  let mut out := #[]
  for (l, i) in (lineSplit s).zipIdx do
    let cs := l.toList
    let ws := cs.takeWhile fun c => c == ' ' || c == '\t'
    let text := (String.ofList (cs.drop ws.length)).trimAsciiEnd.toString
    if ws.contains '\t' && !text.isEmpty then
      throw (first + i, "indentation must be spaces, not tabs")
    out := out.push { num := first + i, indent := ws.length, text, raw := l }
  return out

private def nextContent (ls : Array Ln) (i : Nat) : Nat := Id.run do
  let mut j := i
  while h : j < ls.size do
    if !ls[j].blank then return j
    j := j + 1
  return j

private def isSeqItem (t : String) : Bool := t == "-" || t.startsWith "- "

/-- What follows a quoted scalar on its line must be nothing, or a comment. -/
private def endsClean (rest : List Char) : Bool :=
  let r := rest.dropWhile (· == ' ')
  r.isEmpty || r.head? == some '#'

/-- The double-quoted scalar `s` starts with, and the characters after it. YAML's escapes in a
    double-quoted scalar are JSON's, and those are the ones taken. -/
private def doubleQuoted (s : String) (line : Nat) : Except YErr (String × List Char) := do
  let cs := s.toList
  let rec go (xs : List Char) (acc : List Char) (esc : Bool) : Option (List Char × List Char) :=
    match xs with
    | [] => none
    | c :: rest =>
      if esc then go rest (c :: acc) false
      else if c == '\\' then go rest (c :: acc) true
      else if c == '"' then some (acc.reverse, rest)
      else go rest (c :: acc) false
  let some (inner, rest) := go (cs.drop 1) [] false
    | throw (line, "a double-quoted string is not closed on its line")
  match Json.parse ("\"" ++ String.ofList inner ++ "\"") with
  | .ok (.str v) => return (v, rest)
  | _ => throw (line, "a double-quoted string has an escape this reader does not know")

/-- The single-quoted scalar `s` starts with (`''` is a quote), and the characters after it. -/
private def singleQuoted (s : String) (line : Nat) : Except YErr (String × List Char) := do
  let rec go (xs : List Char) (acc : List Char) : Option (List Char × List Char) :=
    match xs with
    | [] => none
    | '\'' :: '\'' :: rest => go rest ('\'' :: acc)
    | '\'' :: rest => some (acc.reverse, rest)
    | c :: rest => go rest (c :: acc)
  let some (inner, rest) := go (s.toList.drop 1) []
    | throw (line, "a single-quoted string is not closed on its line")
  return (String.ofList inner, rest)

/-- `s` without a trailing comment (` # …`): of a plain scalar, where `#` starts one only after a
    space. -/
private def stripComment (s : String) : String :=
  if s.startsWith "#" then "" else
  match s.splitOn " #" with
  | x :: _ => x.trimAsciiEnd.toString
  | [] => s

private def isNumberLike (s : String) : Bool :=
  let body := if s.startsWith "-" || s.startsWith "+" then (s.drop 1).toString else s
  !body.isEmpty && body.toList.all (fun c => c.isDigit || c == '.' || c == 'e' || c == 'E' ||
    c == '-' || c == '+') && body.toList.head?.any Char.isDigit

private def plainScalar (s : String) (line : Nat) : Except YErr Yaml := do
  let s := stripComment s
  if ["", "~", "null", "Null", "NULL"].contains s then return .null
  if ["true", "True", "TRUE"].contains s then return .bool true
  if ["false", "False", "FALSE"].contains s then return .bool false
  if let some c := s.toList.head? then
    if "&*!".contains c then
      throw (line, "anchors, aliases and tags are not supported; quote the value")
    if "%@`|>".contains c then throw (line, s!"a value starting with '{c}' must be quoted")
  if (s.splitOn ": ").length > 1 then throw (line, "a value holding ': ' must be quoted")
  if isNumberLike s then
    if let .ok (.num n) := Json.parse s then return .num n
  return .str s

/-- A flow collection: JSON, or a list of plain values (`[a, b]`). -/
private def flowScalar (s : String) (line : Nat) : Except YErr Yaml := do
  if let .ok j := Json.parse s then return .json j
  -- A comment after the collection.
  if let .ok j := Json.parse (((s.splitOn " #").headD s).trimAsciiEnd.toString) then
    return .json j
  let inner := ((s.drop 1).dropEndWhile (· == ']')).toString
  if s.startsWith "[" && s.endsWith "]" && !inner.toList.any (fun c => "[]{}\"'".contains c) then
    let items := if inner.trimAscii.isEmpty then [] else inner.splitOn ","
    let vals ← items.mapM fun i => plainScalar i.trimAscii.toString line
    return .seq (vals.map (line, ·)).toArray
  throw (line, "a flow collection must be JSON, or a list of plain values like [a, b]")

private def scalar (s : String) (line : Nat) : Except YErr Yaml := do
  if s.startsWith "\"" then
    let (v, rest) ← doubleQuoted s line
    unless endsClean rest do throw (line, "something follows a quoted string on its line")
    return .str v
  if s.startsWith "'" then
    let (v, rest) ← singleQuoted s line
    unless endsClean rest do throw (line, "something follows a quoted string on its line")
    return .str v
  if s.startsWith "[" || s.startsWith "{" then return ← flowScalar s line
  plainScalar s line

/-- `key: rest` split into the key and the rest, or `none` when the line is not a mapping entry. -/
private def splitKey (text : String) (line : Nat) : Except YErr (Option (String × String)) := do
  let afterKey (k : String) (rest : List Char) : Option (String × String) :=
    match rest with
    | ':' :: more =>
      if more.isEmpty || more.head? == some ' ' then
        some (k, (String.ofList more).trimAscii.toString)
      else none
    | _ => none
  if text.startsWith "\"" then
    let (k, rest) ← doubleQuoted text line
    return afterKey k rest
  if text.startsWith "'" then
    let (k, rest) ← singleQuoted text line
    return afterKey k rest
  if text.startsWith "[" || text.startsWith "{" || isSeqItem text then return none
  match text.splitOn ": " with
  | k :: rest@(_ :: _) =>
    return some (k.trimAsciiEnd.toString, (": ".intercalate rest).trimAscii.toString)
  | _ =>
    if text.endsWith ":" then return some ((text.dropEnd 1).trimAsciiEnd.toString, "")
    return none

/-- A `|` or `>` block scalar, its header `header`, at the entry on line `j` indented `ind`:
    the lines after it indented further, or blank. Answers the value and the next line. -/
private def blockScalar (ls : Array Ln) (j ind : Nat) (header : String) :
    Except YErr (Yaml × Nat) := do
  let line := ls[j]!.num
  let h := stripComment header
  let folded := h.startsWith ">"
  let chomp := (h.drop 1).toString
  unless ["", "-", "+"].contains chomp do
    throw (line, "a block scalar's header must be |, |-, |+, >, >- or >+")
  let mut k := j + 1
  let mut body : Array (Option String) := #[]
  let mut contentIndent : Option Nat := none
  while h : k < ls.size do
    let l := ls[k]
    if l.text.isEmpty then
      body := body.push none
      k := k + 1
      continue
    if l.indent ≤ ind then break
    let ci := contentIndent.getD l.indent
    contentIndent := some ci
    if l.indent < ci then
      throw (l.num, "this line is indented less than the first line of its block")
    body := body.push (some (String.ofList (l.raw.toList.drop ci)))
    k := k + 1
  -- Trailing blank lines belong to the chomping, not the text.
  let trailing := (body.toList.reverse.takeWhile (·.isNone)).length
  let lines := body.extract 0 (body.size - trailing)
  let text := if folded then
      (lines.foldl (init := ("", false)) fun (acc, prevText) l => match l with
        | none => (acc ++ "\n", false)
        | some t => (if prevText then acc ++ " " ++ t else acc ++ t, true)).1
    else "\n".intercalate (lines.toList.map (·.getD ""))
  let text := if lines.isEmpty then "" else match chomp with
    | "-" => text
    | "+" => text ++ String.ofList (List.replicate (trailing + 1) '\n')
    | _ => text ++ "\n"
  return (.str text, k)

mutual

/-- The block node starting at line `i` or after, if it is indented at least `ind`. -/
private partial def block (ls : Array Ln) (i ind : Nat) : Except YErr (Yaml × Nat) := do
  let j := nextContent ls i
  if h : j < ls.size then
    let l := ls[j]
    if l.indent < ind then return (.null, j)
    if isSeqItem l.text then seqAt ls j l.indent #[] else mapAt ls j l.indent #[] {} none
  else return (.null, j)

/-- What follows `key:` on line `j` of a mapping indented `ind`: `rest`, or the block after. -/
private partial def entryValue (ls : Array Ln) (j ind : Nat) (rest : String) :
    Except YErr (Yaml × Nat) := do
  let line := ls[j]!.num
  if rest.isEmpty || rest.startsWith "#" then
    let k := nextContent ls (j + 1)
    if h : k < ls.size then
      let l := ls[k]
      if l.indent > ind then return ← block ls (j + 1) (ind + 1)
      -- A list may sit at its key's indentation.
      if l.indent == ind && isSeqItem l.text then return ← seqAt ls k ind #[]
    return (.null, j + 1)
  if rest.startsWith "|" || rest.startsWith ">" then return ← blockScalar ls j ind rest
  return (← scalar rest line, j + 1)

/-- The mapping at line `i` or after, indented `ind`; `first`, when given, stands in for its first
    line — the rest of a `- key: value` line, its key lined up with the keys under it. `seen`, its
    keys so far, for the check that none is given twice. -/
private partial def mapAt (ls : Array Ln) (i ind : Nat) (acc : Array (String × Nat × Yaml))
    (seen : Std.HashSet String) (first : Option (Nat × Ln)) : Except YErr (Yaml × Nat) := do
  let j := nextContent ls i
  if h : j < ls.size then
    let l := match first with
      | some (f, fl) => if f == j then fl else ls[j]
      | none => ls[j]
    if l.indent < ind then return (.map acc, j)
    if l.indent > ind then throw (l.num, "this line is indented more than the key before it")
    if isSeqItem l.text then throw (l.num, "a list item where a key was expected")
    let some (k, rest) ← splitKey l.text l.num
      | throw (l.num, "expected `key: value`")
    if k.isEmpty then throw (l.num, "a key is empty")
    if seen.contains k then throw (l.num, s!"'{k}' is given twice")
    let (v, next) ← entryValue ls j ind rest
    mapAt ls next ind (acc.push (k, l.num, v)) (seen.insert k) none
  else return (.map acc, j)

private partial def seqAt (ls : Array Ln) (i ind : Nat) (acc : Array (Nat × Yaml)) :
    Except YErr (Yaml × Nat) := do
  let j := nextContent ls i
  if h : j < ls.size then
    let l := ls[j]
    if l.indent < ind || !isSeqItem l.text then return (.seq acc, j)
    if l.indent > ind then throw (l.num, "this line is indented more than the item before it")
    let rest := (l.text.drop 1).trimAscii.toString
    if rest.isEmpty || rest.startsWith "#" then
      let (v, next) ← block ls (j + 1) (ind + 1)
      return ← seqAt ls next ind (acc.push (l.num, v))
    if let some _ ← splitKey rest l.num then
      -- `- key: value`: a mapping whose keys line up with this one.
      let offset := l.text.length - rest.length
      let (v, next) ← mapAt ls j (ind + offset) #[] {}
        (some (j, { l with indent := ind + offset, text := rest }))
      return ← seqAt ls next ind (acc.push (l.num, v))
    seqAt ls (j + 1) ind (acc.push (l.num, ← scalar rest l.num))
  else return (.seq acc, j)

end

/-- The YAML document `src`, whose first line is line `first` of its file. -/
def parseYaml (src : String) (first : Nat := 1) : Except YErr Yaml := do
  let ls ← linesOf src first
  let (v, i) ← block ls 0 0
  let j := nextContent ls i
  if h : j < ls.size then throw (ls[j].num, "this line does not belong to what comes before it")
  return v

/-! ## Front matter -/

/-- A file split into its front matter — the keys of the YAML between a first line `---` and the
    next `---` (or `...`), each with its line — and its body, from the line after; a file that does
    not start with `---` is all body. -/
structure Split where
  keys     : Array (String × Nat × Yaml) := #[]
  body     : String
  bodyLine : Nat := 1

/-- `s` without its leading blank lines and trailing whitespace: a body as it is kept. -/
def normalizeBody (s : String) : String :=
  let lines := (lineSplit s).dropWhile fun l => l.trimAscii.isEmpty
  ("\n".intercalate lines).trimAsciiEnd.toString

/-- The longest front matter, in bytes, and the most keys and items it may hold. -/
def maxFrontMatterBytes : Nat := 65536

def maxFrontMatterEntries : Nat := 1000

/-- How many keys and items `y` holds, all the way down. -/
partial def Yaml.entries : Yaml → Nat
  | .seq xs => xs.foldl (fun n (_, x) => n + 1 + x.entries) 0
  | .map kvs => kvs.foldl (fun n (_, _, x) => n + 1 + x.entries) 0
  | _ => 0

/-- `s` without the byte order mark an editor may start a file with. -/
def stripBom (s : String) : String :=
  if s.startsWith "\uFEFF" then (s.drop 1).toString else s

def splitFile (content : String) : Except YErr Split := do
  let content := stripBom content
  let lines := lineSplit content
  unless lines.head?.any (·.trimAsciiEnd.toString == "---") do
    return { body := normalizeBody content }
  let rest := lines.drop 1
  let some k := rest.findIdx? fun l => ["---", "..."].contains l.trimAsciiEnd.toString
    | throw (1, "the front matter that starts here is not closed by a line `---`")
  let yaml := "\n".intercalate (rest.take k)
  if yaml.utf8ByteSize > maxFrontMatterBytes then
    throw (2, s!"the front matter is longer than {maxFrontMatterBytes} bytes")
  let parsed ← parseYaml yaml 2
  if parsed.entries > maxFrontMatterEntries then
    throw (2, s!"the front matter holds more than {maxFrontMatterEntries} keys and items")
  let keys ← match parsed with
    | .map kvs => pure kvs
    | .null => pure #[]
    | _ => throw (2, "the front matter must be a mapping of keys to values")
  return { keys, body := normalizeBody ("\n".intercalate (rest.drop (k + 1))), bodyLine := k + 3 }

/-! ## The directory -/

/-- One file of a rubric directory: its path in the directory, and what it holds. -/
structure File where
  path    : String
  content : String
  deriving Repr, BEq, Inhabited

/-- What a rubric directory holds: the document, and the style notes. -/
structure Parsed where
  rubric     : Rubric := {}
  styleNotes : String := ""
  deriving Repr

private def fail {α : Type} (file : String) (line : Nat) (msg : String) :
    Except FileError α :=
  .error { file, line := some line, message := msg }

private def asBool (file : String) (k : String) (line : Nat) : Yaml → Except FileError Bool
  | .null => .ok false
  | .bool b => .ok b
  | .json (.bool b) => .ok b
  | _ => fail file line s!"'{k}' must be true or false"

private def asString (file : String) (k : String) (line : Nat) : Yaml → Except FileError String
  | .null => .ok ""
  | .str s => .ok s
  | .json (.str s) => .ok s
  | _ => fail file line s!"'{k}' must be a string"

/-- Why `n`, a type's or a category's name, is not one, if it is not. -/
private def nameProblem (n : String) : Option String :=
  if n.trimAscii.isEmpty then some "the name is empty"
  else if n.length > maxRubricNameLength then
    some s!"the name is longer than {maxRubricNameLength} characters"
  else none

/-- Why `n` cannot be a pull request type's name, which is its file's: also no `/` or `\`, and
    not starting with a dot. -/
def typeNameProblem (n : String) : Option String :=
  (nameProblem n) <|>
    (if n.toList.any (fun c => c == '/' || c == '\\') then
       some "a type's name cannot hold '/' or '\\'"
     else if n.startsWith "." then some "a type's name cannot start with '.'"
     else none)

private def bodySize (file : String) (sp : Split) (what : String) : Except FileError Unit := do
  if sp.body.utf8ByteSize > maxRubricBytes then
    fail file sp.bodyLine s!"{what} is longer than {maxRubricBytes} bytes"

private def splitOf (file content : String) : Except FileError Split :=
  (splitFile content).mapError fun (line, message) => { file, line := some line, message }

/-- `rubric.md`: the default rubric, `fanout`, the order of the types (each with its line), and
    the keys this build does not know. -/
private def readRubricMd (file content : String) :
    Except FileError (String × Bool × Option (List (String × Nat)) × List (String × Json)) := do
  let sp ← splitOf file content
  bodySize file sp "the default rubric"
  let mut fanout := false
  let mut order := none
  let mut extra := #[]
  for (k, line, v) in sp.keys do
    match k with
    | "fanout" => fanout ← asBool file k line v
    | "types" =>
      let items ← match v with
        | .null => pure #[]
        | .seq xs => xs.mapM fun (l, x) => do return (← asString file "types" l x, l)
        | .json (.arr xs) => xs.mapM fun x => match x with
          | .str s => pure (s, line)
          | _ => fail file line "'types' must list the types' names"
        | _ => fail file line "'types' must be a list of the types' names, in order"
      order := some items.toList
    | _ => extra := extra.push (k, v.toJson)
  return (sp.body, fanout, order, extra.toList)

/-- A category, `name: description` — or `name: {description: …, …}`, which keeps the rest. -/
private def readCategory (file : String) (name : String) (line : Nat) (v : Yaml) :
    Except FileError Category := do
  if let some why := nameProblem name then fail file line s!"category '{name}': {why}"
  match v with
  | .null => return { name }
  | .str s | .json (.str s) => return { name, description := s }
  | .map kvs =>
    let mut c : Category := { name }
    let mut extra := #[]
    for (k, l, x) in kvs do
      match k with
      | "description" => c := { c with description := ← asString file k l x }
      | "name" => fail file l "a category's name is its key; drop 'name'"
      | _ => extra := extra.push (k, x.toJson)
    return { c with extra := extra.toList }
  | .json (.obj _) =>
    let j := v.toJson
    if (j.getObjVal? "name").isOk then fail file line "a category's name is its key; drop 'name'"
    let description ← match j.getObjVal? "description" with
      | .error _ | .ok .null => pure ""
      | .ok (.str s) => pure s
      | .ok _ => fail file line "'description' must be a string"
    return { name, description, extra := unknownFields j ["description"] }
  | _ => fail file line s!"category '{name}' must be its description, or a mapping"

/-- `types/<name>.md`. -/
private def readType (file name content : String) : Except FileError PrType := do
  let sp ← splitOf file content
  bodySize file sp s!"the rubric of '{name}'"
  let mut t : PrType := { name, rubric := sp.body }
  let mut extra := #[]
  for (k, line, v) in sp.keys do
    match k with
    | "description" => t := { t with description := ← asString file k line v }
    | "fanout" => t := { t with fanout := ← asBool file k line v }
    | "categories" =>
      let cats ← match v with
        | .null => pure #[]
        | .map kvs => kvs.mapM fun (n, l, x) => readCategory file n l x
        | _ => fail file line "'categories' must map each category's name to its description"
      if cats.size > maxCategories then
        fail file line s!"'{name}' names {cats.size} categories; at most {maxCategories}"
      t := { t with categories := cats.toList }
    | "name" => fail file line "a type's name is its file's; drop 'name'"
    | _ => extra := extra.push (k, v.toJson)
  return { t with extra := extra.toList }

/-- The rubric directory of `files` (paths within the directory), or everything wrong with it,
    each placed in the file it is in. Files other than `rubric.md`, `style.md` and `types/*.md`
    are left alone, but `types/` holds nothing else (a dotfile apart). -/
def parseDir (files : List File) (maxNotesBytes : Nat := maxStyleNotesBytes) :
    Except (Array FileError) Parsed := do
  let mut errors : Array FileError := #[]
  let mut defaultRubric := ""
  let mut fanout := false
  let mut order : Option (List (String × Nat)) := none
  let mut extra := []
  if let some f := files.find? (·.path == "rubric.md") then
    match readRubricMd f.path f.content with
    | .ok (b, fo, o, x) => defaultRubric := b; fanout := fo; order := o; extra := x
    | .error e => errors := errors.push e
  let mut types : Array PrType := #[]
  for f in files do
    unless f.path.startsWith "types/" do continue
    let base := (f.path.drop 6).toString
    if base.startsWith "." then
      errors := errors.push { file := f.path, message := "types/ holds one file per type, \
types/<type>.md, and nothing else: drop this one" }
      continue
    if base.contains '/' then
      errors := errors.push { file := f.path, message := "types/ holds one file per type, \
types/<type>.md, and no directories" }
      continue
    unless base.endsWith ".md" do
      errors := errors.push { file := f.path, message := "types/ holds one file per type, \
types/<type>.md" }
      continue
    let name := (base.dropEnd 3).toString
    if let some why := typeNameProblem name then
      errors := errors.push { file := f.path, message := why }
      continue
    match readType f.path name f.content with
    | .ok t => types := types.push t
    | .error e => errors := errors.push e
  -- Two names one case-insensitive file system would take for one file.
  let mut lower : Std.HashSet String := {}
  for t in types do
    if lower.contains t.name.toLower then
      errors := errors.push { file := s!"types/{t.name}.md", message := s!"another type's name \
differs from '{t.name}' only in case: names must differ in more, for every file system" }
    lower := lower.insert t.name.toLower
  if types.size > maxPrTypes then
    errors := errors.push { file := "types", message := s!"the rubric names {types.size} pull \
request types; at most {maxPrTypes}" }
  -- The order `rubric.md` gives, then the rest by name.
  let mut ordered : Array PrType := #[]
  for (n, line) in order.getD [] do
    if ordered.any (·.name == n) then
      errors := errors.push { file := "rubric.md", line := some line
                            , message := s!"'types' lists '{n}' twice" }
    else match types.find? (·.name == n) with
      | some t => ordered := ordered.push t
      | none => errors := errors.push { file := "rubric.md", line := some line
                                      , message := s!"'types' lists '{n}', but there is no \
types/{n}.md" }
  let rest := (types.filter fun t => !ordered.any (·.name == t.name)).qsort (·.name < ·.name)
  let rubric : Rubric := { defaultRubric, prTypes := (ordered ++ rest).toList, fanout, extra }
  let mut notes := ""
  if let some f := files.find? (·.path == "style.md") then
    match splitOf f.path f.content with
    | .ok sp =>
      let text := if sp.keys.isEmpty then normalizeBody (stripBom f.content) else sp.body
      if text.utf8ByteSize > maxNotesBytes then
        errors := errors.push { file := f.path, message := s!"the style notes are longer than \
{maxNotesBytes} bytes" }
      notes := text
    | .error e => errors := errors.push e
  unless errors.isEmpty do throw errors
  if let .error e := rubric.validate then throw #[{ file := "", message := e }]
  return { rubric, styleNotes := notes }

/-! ## Writing -/

/-- Whether `s` reads back as itself, unquoted. -/
private def plainSafe (s : String) : Bool :=
  match s.toList.head? with
  | none => false
  | some c =>
    (c.isAlpha || c.isDigit) && !s.toList.any (fun c => c == '\n' || c == '\t' || c == '\r') &&
      s.trimAscii.toString == s && !s.endsWith ":" && (s.splitOn ": ").length == 1 &&
      (s.splitOn " #").length == 1 && !isNumberLike s &&
      !["true", "false", "null", "yes", "no", "on", "off", "y", "n"].contains s.toLower

/-- `s` as a YAML scalar: plain when that reads back as `s`, and otherwise double-quoted, whose
    escapes JSON's are. -/
def yamlString (s : String) : String :=
  if plainSafe s then s else (Json.str s).compress

/-- `j` as a YAML value on one line: a string as `yamlString`, anything else as its JSON. -/
def yamlValue : Json → String
  | .str s => yamlString s
  | j => j.compress

/-- A file of `keys` (each written on its line, after `key: `) and `body`. With no keys, the body
    alone, unless it starts with what would be read as front matter. -/
def renderFile (keys : List String) (body : String) : String :=
  let body := normalizeBody body
  let tail := if body.isEmpty then "" else body ++ "\n"
  if keys.isEmpty && !body.startsWith "---" then tail
  else
    let fm := "---\n" ++ String.join (keys.map (· ++ "\n")) ++ "---\n"
    if body.isEmpty then fm else fm ++ "\n" ++ tail

private def extraLines (extra : List (String × Json)) : List String :=
  extra.map fun (k, v) => s!"{yamlString k}: {yamlValue v}"

/-- `types/<t>.md` of type `t`. -/
def renderType (t : PrType) : String :=
  let cats := t.categories.map fun c =>
    if c.extra.isEmpty then s!"  {yamlString c.name}: {yamlString c.description}"
    else s!"  {yamlString c.name}: \
{(Json.mkObj ([("description", (c.description : Json))] ++ c.extra)).compress}"
  let keys := (if t.description.isEmpty then [] else [s!"description: {yamlString t.description}"])
    ++ (if t.fanout then ["fanout: true"] else [])
    ++ (if cats.isEmpty then [] else "categories:" :: cats)
    ++ extraLines t.extra
  renderFile keys t.rubric

/-- `rubric.md` of `r`: its `types` list every type, so that the order is the document's. -/
def renderRubricMd (r : Rubric) : String :=
  let keys := (if r.fanout then ["fanout: true"] else [])
    ++ (if r.prTypes.isEmpty then [] else "types:" :: r.prTypes.map (s!"  - {yamlString ·.name}"))
    ++ extraLines r.extra
  renderFile keys r.defaultRubric

/-- The directory of `r` and `styleNotes`: `rubric.md`, a file per type, and `style.md` when there
    are notes. -/
def render (r : Rubric) (styleNotes : String := "") : List File :=
  [{ path := "rubric.md", content := renderRubricMd r }] ++
    r.prTypes.map (fun t => { path := s!"types/{t.name}.md", content := renderType t }) ++
    (if (normalizeBody styleNotes).isEmpty then []
     else [{ path := "style.md", content := normalizeBody styleNotes ++ "\n" }])

end DiffReviewer.RubricFiles