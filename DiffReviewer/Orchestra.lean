import DiffReviewer.Http
import Lean.Data.Json

open Lean (Json)

/-!
# Orchestra

The platform is one of orchestra's API clients: it queues a review with `POST /api/v1/queue` and
follows the entry with `GET /api/v1/queue/{id}`. The client file on orchestra's side
(`<config>/clients/diff-reviewer.json`) decides everything the platform does not ask for — the
backend, the budget, that the task is read-only and which kleis spec its credentials derive from —
so a request here names only the prompt, the pull request and the platform's own id for the work.

A rubric proposal is of a repository, not of a pull request: its request names no
`issue_number`, which orchestra takes (a task with an upstream and no issue), and its task's
token carries no `task_issue` fact. It is queued through a client of its own
(`DIFF_REVIEWER_ORCHESTRA_PROPOSER_TOKEN_FILE`): a request cannot name its kleis spec — the client
file's `kleis_spec` is every task's — and a proposal's spec (`rubric-proposer`) allows routes a
review's (`reviewer`) must not.

As with `GitHub.Client`, a record of functions, so that the workers can be run against a fake.
-/

namespace DiffReviewer.Orchestra

/-- What the platform asks for. -/
structure QueueRequest where
  prompt      : String
  goal        : String
  /-- `owner/name`. -/
  upstream    : String
  /-- The pull request; `none` for a task of the repository, a rubric proposal. -/
  issueNumber : Option Nat
  /-- The platform's id for the work. Orchestra answers an entry it already holds for it rather
      than queueing a second, so a request whose answer was lost can be repeated. -/
  externalId  : String
  /-- Narrowings of the task's kleis token (`kleis_narrow`), in kleis's `service: only op, op`
      syntax, added to what the client file gives every task: a task can be given less than the
      client's spec, never more. Empty for a review. -/
  kleisNarrow : List String := []
  /-- The commit to check the task's repository out at (`checkout`), rather than its default
      branch. Not yet sent: orchestra's queue API does not take it yet (see `queuePending`). -/
  checkout    : Option String := none
  deriving Repr

def QueueRequest.toJson (r : QueueRequest) : Json :=
  let fields : List (String × Json) :=
    [("prompt", (r.prompt : Json)), ("goal", r.goal), ("upstream", r.upstream)] ++
    (r.issueNumber.map fun n => [("issue_number", (n : Json))]).getD [] ++
    [("external_id", (r.externalId : Json))]
  let fields := if r.kleisNarrow.isEmpty then fields
    else fields ++ [("kleis_narrow", .arr (r.kleisNarrow.map Json.str).toArray)]
  .mkObj (match r.checkout with
    | some sha => fields ++ [("checkout", (sha : Json))]
    | none => fields)

/-- What the platform reads of a queue entry. -/
structure Entry where
  id          : String
  /-- `pending`, `running`, `done`, `failed`, `unfinished` or `cancelled`. -/
  status      : String
  /-- The entry that carries this one's run on, after a restart resume or a retry. -/
  continuedBy : Option String := none
  deriving Repr, BEq

def Entry.ofJson (j : Json) : Except String Entry := do
  let id ← j.getObjValAs? String "id"
  let status ← j.getObjValAs? String "status"
  let continuedBy := (j.getObjValAs? String "continuedBy").toOption
  return { id, status, continuedBy }

/-- Whether an entry in this status will do nothing more. -/
def terminal (status : String) : Bool :=
  ["done", "failed", "unfinished", "cancelled"].contains status

structure Client where
  queue  : QueueRequest → IO (Except String Entry)
  entry  : (id : String) → IO (Except String Entry)
  /-- Stop the run of entry `id`, or withdraw it if it has not started. -/
  cancel : (id : String) → IO (Except String Unit)

private def errorOf (r : Http.Response) : String :=
  let msg := ((Json.parse r.body).toOption.bind (·.getObjValAs? String "error" |>.toOption))
  s!"orchestra answered {r.status}{(msg.map (": " ++ ·)).getD ""}"

/-- The client that talks to orchestra at `url` with `token`, through curl. Orchestra is reached
    directly, never through `HTTPS_PROXY`: the proxy is kleis, there for GitHub, and the orchestra
    token is the platform's own, not one kleis should see. -/
def Client.curl (url token : String) : Client :=
  let url := (url.dropEndWhile (· == '/')).toString
  let send (method path : String) (body : Option Json) : IO (Except String Http.Response) := do
    let headers := [("Authorization", s!"Bearer {token}"), ("Accept", "application/json")] ++
      (if body.isSome then [("Content-Type", "application/json")] else [])
    match ← Http.send { method, url := url ++ path, headers, body := body.map (·.compress)
                      , noproxy := some (Http.hostOf url) } with
    | .error e => return .error e.message
    | .ok r =>
      unless 200 ≤ r.status && r.status < 300 do return .error (errorOf r)
      return .ok r
  let call (method path : String) (body : Option Json) : IO (Except String Entry) := do
    return (← send method path body).bind fun r =>
      (Json.parse r.body).bind Entry.ofJson |>.mapError
        (s!"orchestra's answer is not a queue entry: " ++ ·)
  { queue := fun req => call "POST" "/api/v1/queue" (some req.toJson)
    entry := fun id => call "GET" s!"/api/v1/queue/{id}" none
    cancel := fun id => do
      return (← send "POST" s!"/api/v1/queue/{id}/cancel" (some (.mkObj []))).map fun _ => () }

/-- The client configured by `DIFF_REVIEWER_ORCHESTRA_URL` and the token file `tokenVar` names
    (`DIFF_REVIEWER_ORCHESTRA_TOKEN_FILE` unless it says), or `none` unless both are set. -/
def Client.fromEnv (tokenVar := "DIFF_REVIEWER_ORCHESTRA_TOKEN_FILE") : IO (Option Client) := do
  let some url ← IO.getEnv "DIFF_REVIEWER_ORCHESTRA_URL" | return none
  let some path ← IO.getEnv tokenVar | return none
  return some (Client.curl url (← Http.readTokenFile path))

end DiffReviewer.Orchestra