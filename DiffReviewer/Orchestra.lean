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

As with `GitHub.Client`, a record of functions, so that the workers can be run against a fake.
-/

namespace DiffReviewer.Orchestra

/-- What the platform asks for. -/
structure QueueRequest where
  prompt      : String
  goal        : String
  /-- `owner/name`. -/
  upstream    : String
  issueNumber : Nat
  /-- The platform's id for the work. Orchestra answers an entry it already holds for it rather
      than queueing a second, so a request whose answer was lost can be repeated. -/
  externalId  : String
  deriving Repr

def QueueRequest.toJson (r : QueueRequest) : Json :=
  .mkObj [("prompt", r.prompt), ("goal", r.goal), ("upstream", r.upstream),
          ("issue_number", r.issueNumber), ("external_id", r.externalId)]

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
  queue : QueueRequest → IO (Except String Entry)
  entry : (id : String) → IO (Except String Entry)

private def errorOf (r : Http.Response) : String :=
  let msg := ((Json.parse r.body).toOption.bind (·.getObjValAs? String "error" |>.toOption))
  s!"orchestra answered {r.status}{(msg.map (": " ++ ·)).getD ""}"

/-- The client that talks to orchestra at `url` with `token`, through curl. -/
def Client.curl (url token : String) : Client :=
  let url := (url.dropEndWhile (· == '/')).toString
  let call (method path : String) (body : Option Json) : IO (Except String Entry) := do
    let headers := [("Authorization", s!"Bearer {token}"), ("Accept", "application/json")] ++
      (if body.isSome then [("Content-Type", "application/json")] else [])
    match ← Http.send { method, url := url ++ path, headers, body := body.map (·.compress) } with
    | .error e => return .error e
    | .ok r =>
      unless 200 ≤ r.status && r.status < 300 do return .error (errorOf r)
      return (Json.parse r.body).bind Entry.ofJson |>.mapError
        (s!"orchestra's answer is not a queue entry: " ++ ·)
  { queue := fun req => call "POST" "/api/v1/queue" (some req.toJson)
    entry := fun id => call "GET" s!"/api/v1/queue/{id}" none }

/-- The client configured by `DIFF_REVIEWER_ORCHESTRA_URL` and
    `DIFF_REVIEWER_ORCHESTRA_TOKEN_FILE`, or `none` unless both are set. -/
def Client.fromEnv : IO (Option Client) := do
  let some url ← IO.getEnv "DIFF_REVIEWER_ORCHESTRA_URL" | return none
  let some path ← IO.getEnv "DIFF_REVIEWER_ORCHESTRA_TOKEN_FILE" | return none
  return some (Client.curl url (← Http.readTokenFile path))

end DiffReviewer.Orchestra