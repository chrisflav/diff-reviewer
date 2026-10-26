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

/-- The commit a task's workspace is checked out at instead of the default branch (orchestra's
    `checkout`). Orchestra fetches it from the task's upstream before the sandbox exists — which a
    read-only task cannot do for itself — and fails the task if the commit cannot be had. -/
structure Checkout where
  /-- The full commit name, lower case. -/
  commit   : String
  /-- The upstream ref fetched for it, which must reach it: `refs/pull/<n>/head`. -/
  fetchRef : Option String := none
  /-- A repository holding only the commit and its history: no branches, no tags, no remotes, no
      reflog, nothing that came after it. -/
  isolate  : Bool := false
  deriving Repr, BEq

def Checkout.toJson (c : Checkout) : Json :=
  .mkObj ([("commit", (c.commit : Json))] ++
    (c.fetchRef.map fun r => [("fetch_ref", (r : Json))]).getD [] ++
    (if c.isolate then [("isolate", (true : Json))] else []))

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
      branch: a review's head; `none` for a rubric proposal, which reads the default branch. -/
  checkout    : Option Checkout := none
  deriving Repr

def QueueRequest.toJson (r : QueueRequest) : Json :=
  let fields : List (String × Json) :=
    [("prompt", (r.prompt : Json)), ("goal", r.goal), ("upstream", r.upstream)] ++
    (r.issueNumber.map fun n => [("issue_number", (n : Json))]).getD [] ++
    [("external_id", (r.externalId : Json))]
  let fields := if r.kleisNarrow.isEmpty then fields
    else fields ++ [("kleis_narrow", .arr (r.kleisNarrow.map Json.str).toArray)]
  .mkObj (match r.checkout with
    | some c => fields ++ [("checkout", c.toJson)]
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

/-- Why a request was not queued. -/
inductive QueueError where
  /-- Orchestra refused the request as it is (`400`): a checkout its backend does not make — any
      on `landrun` or `local` unless the operator allows hooks on the host, `isolate` on `local`
      at all, any on `merger` or `triage` (`refusesCheckout`) — or a field the client's policy
      does not allow. Asked again unchanged, it is refused again. -/
  | refused (why : String)
  /-- Anything else — orchestra unreachable, its daemon down (`409`), the client at its
      `max_active` (`429`) — which may pass. -/
  | failed (why : String)
  deriving Repr, BEq

/-- What orchestra says when its backend does not make a checkout
    (`ExecutionConfig.checkoutRefusal?` in orchestra's `Config.lean`): on `merger` or `triage`,
    `isolate` on `local`, and any checkout on a backend that runs hooks on the host. Phrases of
    its refusals, word for word. -/
def checkoutRefusals : List String :=
  ["runs no agent on a checkout; 'checkout' is for tasks that do",
   "'isolate' is refused on the 'local' execution backend",
   "a task checked out at a commit runs its repository's hooks in that commit's tree"]

/-- Whether refusal `why` is of the request's `checkout` (`checkoutRefusals`), rather than of a
    field the client file does not allow — a repository its `queue_policy` does not list, say,
    which the operator may yet add, and whose name may well have "checkout" in it. -/
def refusesCheckout (why : String) : Bool :=
  checkoutRefusals.any fun w => (why.splitOn w).length > 1

instance : ToString QueueError where
  toString
    | .refused why | .failed why => why

structure Client where
  /-- Queue a task; an `Entry` answers it, or the one an `externalId` seen before made. -/
  queue  : QueueRequest → IO (Except QueueError Entry)
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
  -- A refusal of the request itself (`400`) is told apart: asking again would be refused again.
  let send (method path : String) (body : Option Json) :
      IO (Except QueueError Http.Response) := do
    let headers := [("Authorization", s!"Bearer {token}"), ("Accept", "application/json")] ++
      (if body.isSome then [("Content-Type", "application/json")] else [])
    match ← Http.send { method, url := url ++ path, headers, body := body.map (·.compress)
                      , noproxy := some (Http.hostOf url) } with
    | .error e => return .error (.failed e.message)
    | .ok r =>
      if r.status == 400 then return .error (.refused (errorOf r))
      unless 200 ≤ r.status && r.status < 300 do return .error (.failed (errorOf r))
      return .ok r
  let call (method path : String) (body : Option Json) : IO (Except QueueError Entry) := do
    return (← send method path body).bind fun r =>
      (Json.parse r.body).bind Entry.ofJson |>.mapError
        (.failed <| s!"orchestra's answer is not a queue entry: " ++ ·)
  { queue := fun req => call "POST" "/api/v1/queue" (some req.toJson)
    entry := fun id => return (← call "GET" s!"/api/v1/queue/{id}" none).mapError toString
    cancel := fun id => do
      return (← send "POST" s!"/api/v1/queue/{id}/cancel" (some (.mkObj []))).map (fun _ => ())
        |>.mapError toString }

/-- The client configured by `DIFF_REVIEWER_ORCHESTRA_URL` and the token file `tokenVar` names
    (`DIFF_REVIEWER_ORCHESTRA_TOKEN_FILE` unless it says), or `none` unless both are set. -/
def Client.fromEnv (tokenVar := "DIFF_REVIEWER_ORCHESTRA_TOKEN_FILE") : IO (Option Client) := do
  let some url ← IO.getEnv "DIFF_REVIEWER_ORCHESTRA_URL" | return none
  let some path ← IO.getEnv tokenVar | return none
  return some (Client.curl url (← Http.readTokenFile path))

end DiffReviewer.Orchestra