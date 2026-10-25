import DiffReviewer.Types
import DiffReviewer.Http
import Lean.Data.Json

open Lean (Json)

/-!
# The agent's side: `diff-reviewer agent show|diff|submit`

What a reviewing agent runs inside its orchestra sandbox. Each subcommand is one request to the
platform's agent API (`/api/agent/v1/repos/{owner}/{name}/pulls/{pr}…`), made with curl so that it
goes through the proxy and CA bundle the sandbox is set up with.

The platform's address and token come from `~/.config/diff-reviewer/agent.json`
(`{"url": …, "token": …}`), which kleis's setup writes, and `DIFF_REVIEWER_URL` and
`DIFF_REVIEWER_TOKEN` override either. In a sandbox the token is the placeholder `kleis`: kleis
strips it and sends the real agent token on, so the agent never holds a credential of the platform.
-/

namespace DiffReviewer.Agent

structure Config where
  url   : String
  token : String

/-- The configuration, from the file's contents (when there is a file) and the environment, which
    wins. -/
def resolve (file : Option Json) (envUrl envToken : Option String) : Except String Config := do
  let fromFile (k : String) : Option String :=
    file.bind (·.getObjValAs? String k |>.toOption) |>.filter (!·.isEmpty)
  let some url := envUrl.filter (!·.isEmpty) <|> fromFile "url"
    | throw "no platform URL: set \"url\" in ~/.config/diff-reviewer/agent.json or \
DIFF_REVIEWER_URL"
  let some token := envToken.filter (!·.isEmpty) <|> fromFile "token"
    | throw "no token: set \"token\" in ~/.config/diff-reviewer/agent.json or DIFF_REVIEWER_TOKEN"
  return { url := (url.dropEndWhile (· == '/')).toString, token }

def configPath : IO (Option System.FilePath) := do
  return (← IO.getEnv "HOME").map (· / ".config" / "diff-reviewer" / "agent.json")

def loadConfig : IO (Except String Config) := do
  let file ← match ← configPath with
    | some p =>
      if ← p.pathExists then
        match Json.parse (← IO.FS.readFile p) with
        | .ok j => pure (some j)
        | .error e => return .error s!"{p} is not JSON: {e}"
      else pure none
    | none => pure none
  return resolve file (← IO.getEnv "DIFF_REVIEWER_URL") (← IO.getEnv "DIFF_REVIEWER_TOKEN")

/-- `owner/name` as its two halves. -/
def splitSlug (slug : String) : Option (String × String) :=
  match slug.splitOn "/" with
  | [o, n] => if o.isEmpty || n.isEmpty then none else some (o, n)
  | _ => none

/-- What `submit` sends, read from the file the agent wrote and checked as the platform will check
    it, so that a mistake is reported before a request is made. -/
def parseSubmission (contents : String) : Except String Json := do
  let j ← (Json.parse contents).mapError (s!"the submission is not JSON: " ++ ·)
  let some head := (j.getObjValAs? String "headSha").toOption
    | throw "the submission must name the \"headSha\" that was reviewed"
  if head.isEmpty then throw "\"headSha\" is empty"
  match j.getObjVal? "prType" with
  | .error _ | .ok .null | .ok (.str _) => pure ()
  | .ok _ => throw "\"prType\" must be a string or null"
  let review ← (j.getObjVal? "review" >>= Review.ofJson).mapError
    (s!"\"review\" is not a review: " ++ ·)
  review.validate.mapError (s!"\"review\": " ++ ·)
  return j

private def fail (msg : String) : IO UInt32 := do
  IO.eprintln s!"error: {msg}"
  return 1

/-- One request to the agent API about pull request `pr` of `slug`; `suffix` is `""`, `/diff` or
    `/review`. -/
def request (cfg : Config) (method slug pr suffix : String) (body : Option String := none) :
    IO (Except String Http.Response) := do
  let some (owner, name) := splitSlug slug | return .error s!"'{slug}' is not owner/name"
  let some _ := pr.toNat? | return .error s!"'{pr}' is not a pull request number"
  let headers := [("Authorization", s!"Bearer {cfg.token}"), ("Accept", "application/json")] ++
    (if body.isSome then [("Content-Type", "application/json")] else [])
  let url := s!"{cfg.url}/api/agent/v1/repos/{owner}/{name}/pulls/{pr}{suffix}"
  Http.send { method, url, headers, body }

/-- Make one request and print its answer; answers the exit code. -/
private def call (method slug pr suffix : String) (body : Option String) (pretty : Bool) :
    IO UInt32 := do
  let cfg ← match ← loadConfig with
    | .ok c => pure c
    | .error e => return ← fail e
  match ← request cfg method slug pr suffix body with
  | .error e => fail e
  | .ok r =>
    let shown := if pretty then ((Json.parse r.body).toOption.map (·.pretty)).getD r.body
      else r.body
    if 200 ≤ r.status && r.status < 300 then
      -- A diff ends in its own newline; JSON does not.
      if pretty then IO.println shown else IO.print shown
      return 0
    fail s!"the platform answered {r.status}: {shown}"

def showPull (slug pr : String) : IO UInt32 := call "GET" slug pr "" none true

def printDiff (slug pr : String) : IO UInt32 := call "GET" slug pr "/diff" none false

/-- Submit the review in `path` (`-` for standard input). -/
def submit (slug pr path : String) : IO UInt32 := do
  let contents ← if path == "-" then (← IO.getStdin).readToEnd else IO.FS.readFile path
  match parseSubmission contents with
  | .error e => fail e
  | .ok j => call "POST" slug pr "/review" (some j.compress) true

end DiffReviewer.Agent