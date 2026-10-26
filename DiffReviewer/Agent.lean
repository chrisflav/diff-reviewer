import DiffReviewer.Types
import DiffReviewer.Http
import Lean.Data.Json

open Lean (Json)

/-!
# The agent's side: `diff-reviewer agent show|diff|submit|proposal`

What a reviewing agent runs inside its orchestra sandbox. Each subcommand is one request to the
platform's agent API (`/api/agent/v1/repos/{owner}/{name}/pulls/{pr}…`), made with curl so that it
goes through the proxy and CA bundle the sandbox is set up with. `agent proposal show|submit` are
a rubric proposal's, of the repository and the job
(`/api/agent/v1/repos/{owner}/{name}/proposals/{jobId}`): the job is in the path, so `--job` is
required.

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
    `/review`. `job` is the job the agent's prompt named (`--job`), sent as `X-Diff-Reviewer-Job`
    so that the platform can tell this run from an older one of the same pull request. -/
def request (cfg : Config) (method slug pr suffix : String) (body : Option String := none)
    (job : Option String := none) : IO (Except String Http.Response) := do
  let some (owner, name) := splitSlug slug | return .error s!"'{slug}' is not owner/name"
  let some _ := pr.toNat? | return .error s!"'{pr}' is not a pull request number"
  let headers := [("Authorization", s!"Bearer {cfg.token}"), ("Accept", "application/json")] ++
    (if body.isSome then [("Content-Type", "application/json")] else []) ++
    (job.map (fun j => ("X-Diff-Reviewer-Job", j))).toList
  let url := s!"{cfg.url}/api/agent/v1/repos/{owner}/{name}/pulls/{pr}{suffix}"
  return (← Http.send { method, url, headers, body }).mapError (·.message)

/-- Make one request and print its answer; answers the exit code. -/
private def call (method slug pr suffix : String) (body : Option String) (pretty : Bool)
    (job : Option String) : IO UInt32 := do
  let cfg ← match ← loadConfig with
    | .ok c => pure c
    | .error e => return ← fail e
  match ← request cfg method slug pr suffix body job with
  | .error e => fail e
  | .ok r =>
    let shown := if pretty then ((Json.parse r.body).toOption.map (·.pretty)).getD r.body
      else r.body
    if 200 ≤ r.status && r.status < 300 then
      -- A diff ends in its own newline; JSON does not.
      if pretty then IO.println shown else IO.print shown
      return 0
    fail s!"the platform answered {r.status}: {shown}"

def showPull (slug pr : String) (job : Option String := none) : IO UInt32 :=
  call "GET" slug pr "" none true job

/-- Print the diff under review; with `since`, an incremental re-review's diff of the changes since
    its previous review, which the platform answers only for the head that review was of. -/
def printDiff (slug pr : String) (job : Option String := none) (since : Option String := none) :
    IO UInt32 := do
  match since with
  | none => call "GET" slug pr "/diff" none false job
  | some sha =>
    unless !sha.isEmpty && sha.all (fun c => c.isDigit || ('a' ≤ c.toLower && c.toLower ≤ 'f')) do
      return ← fail s!"'{sha}' is not a commit id"
    call "GET" slug pr s!"/diff?since={sha.toLower}" none false job

/-- Submit the review in `path` (`-` for standard input). -/
def submit (slug pr path : String) (job : Option String := none) : IO UInt32 := do
  let contents ← if path == "-" then (← IO.getStdin).readToEnd else IO.FS.readFile path
  match parseSubmission contents with
  | .error e => fail e
  | .ok j => call "POST" slug pr "/review" (some j.compress) true job

/-- One request to the agent API about rubric proposal job `job` of `slug`. -/
def proposalRequest (cfg : Config) (method slug job : String) (body : Option String := none) :
    IO (Except String Http.Response) := do
  let some (owner, name) := splitSlug slug | return .error s!"'{slug}' is not owner/name"
  unless !job.isEmpty && job.all (fun c => c.isAlphanum || c == '-' || c == '_' || c == '.') do
    return .error s!"'{job}' is not a job id"
  let headers := [("Authorization", s!"Bearer {cfg.token}"), ("Accept", "application/json")] ++
    (if body.isSome then [("Content-Type", "application/json")] else [])
  let url := s!"{cfg.url}/api/agent/v1/repos/{owner}/{name}/proposals/{job}"
  return (← Http.send { method, url, headers, body }).mapError (·.message)

private def callProposal (method slug job : String) (body : Option String) : IO UInt32 := do
  let cfg ← match ← loadConfig with
    | .ok c => pure c
    | .error e => return ← fail e
  match ← proposalRequest cfg method slug job body with
  | .error e => fail e
  | .ok r =>
    let shown := ((Json.parse r.body).toOption.map (·.pretty)).getD r.body
    if 200 ≤ r.status && r.status < 300 then
      IO.println shown
      return 0
    fail s!"the platform answered {r.status}: {shown}"

/-- What a rubric proposal is to be written from. -/
def showProposal (slug job : String) : IO UInt32 :=
  callProposal "GET" slug job none

/-- What `proposal submit` sends, read from the file the agent wrote: an object with a
    `baseVersion`, a `rubric` object and a `rationale`, checked before a request is made. The
    platform checks the rest. -/
def parseProposal (contents : String) : Except String Json := do
  let j ← (Json.parse contents).mapError (s!"the proposal is not JSON: " ++ ·)
  if (j.getObjValAs? Nat "baseVersion").toOption.isNone then
    throw "the proposal must name the \"baseVersion\" of the rubric it was written from"
  unless ((j.getObjVal? "rubric").toOption.bind (·.getObj?.toOption)).isSome do
    throw "the proposal must carry the whole \"rubric\" document, as an object"
  if (j.getObjValAs? String "rationale").toOption.isNone then
    throw "the proposal must carry a \"rationale\""
  return j

/-- Submit the proposal in `path` (`-` for standard input). -/
def submitProposal (slug path job : String) : IO UInt32 := do
  let contents ← if path == "-" then (← IO.getStdin).readToEnd else IO.FS.readFile path
  match parseProposal contents with
  | .error e => fail e
  | .ok j => callProposal "POST" slug job (some j.compress)

/-- `["--job", id]`: the trailing flag every subcommand requires, since the platform answers only
    a request that names its job. -/
def jobFlag : List String → Option (Option String)
  | ["--job", id] => some (some id)
  | _ => none

/-- `agent diff`'s flags: `--job <id>`, after `--since <sha>` for an incremental re-review's diff of
    the changes since its previous review. -/
def diffFlags : List String → Option (Option String × Option String)
  | ["--since", sha, "--job", id] => some (some sha, some id)
  | ["--job", id] => some (none, some id)
  | _ => none

end DiffReviewer.Agent