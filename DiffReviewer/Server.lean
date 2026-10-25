import Lean.Data.Json
import Std.Http
import Std.Net
import DiffReviewer.Platform
import DiffReviewer.Workers

open Lean (Json)
open Std.Net
open Std.Async
open Std.Http (Request Response Body Header Status Method)
open Std.Http.Server (Handler)

/-!
# The platform's HTTP server

`diff-reviewer serve` answers, on one port:

  * `GET /api/openapi.json` — the API's own description, uncredentialed.
  * `POST /api/login`, `POST /api/logout`, `GET /api/session` — the authentication surface.
  * `/api/v1/…` — the repositories and review jobs; see `docs/openapi.json`.
  * `/api/agent/v1/…` — what a reviewing agent reads and submits, through kleis.
  * everything else — the front-end built into `web/dist` (`--site`), with a single-page-app
    fallback.

Routing is a pure-ish function from a `Req` to a `Reply` (`route`), so that the suite can drive
it without a socket; `serve` adapts `Std.Http` to it and back.

## Authentication

One person runs the platform — the one whose name approved reviews are posted under — and three
credentials reach it, none of which stands in for another:

  * **the password**, only ever sent to `POST /api/login`, which exchanges it for an `HttpOnly`,
    `SameSite=Strict` session cookie. Failed attempts are rate-limited: past `loginFailureLimit`
    within `loginWindowSeconds`, every attempt — right or wrong — is a `429` for a delay that
    doubles with each further failure, so the password cannot be guessed at the speed of the
    network.
  * **the API token** (`apiToken`), what a script sends as `Authorization: Bearer` to `/api/v1/`.
    The session cookie reaches the same routes.
  * **the agent token** (`agentToken`), the only credential of `/api/agent/v1/`, and good for
    nothing else. Agents never hold it: an agent's request goes through kleis, which replaces the
    placeholder the agent sends with this token, and only for the routes, repository and pull
    request its grant allows.

Writes must be `application/json`, which with `SameSite=Strict` is what keeps a cross-site form
from making one.
-/

namespace DiffReviewer.Server

/-! ## Requests and replies -/

/-- What `route` needs of a request. -/
structure Req where
  method  : Method
  /-- The path, without the query string, still percent-encoded. -/
  path    : String
  /-- Look up a header, case-insensitively. -/
  header  : String → Option String := fun _ => none
  body    : String := ""
  /-- The address of the socket's other end, when known. -/
  peer    : Option String := none

/-- What `route` answers. -/
structure Reply where
  status      : Status
  body        : ByteArray := ByteArray.empty
  contentType : String := "application/json"
  headers     : List (String × String) := []

def Reply.json (j : Json) (status : Status := .ok) : Reply :=
  { status, body := j.compress.toUTF8, headers := [("Cache-Control", "no-store")] }

def Reply.error (msg : String) (status : Status) : Reply :=
  .json (.mkObj [("error", msg)]) status

def Reply.noContent : Reply := { status := .noContent, contentType := "" }

/-! ## Server state -/

structure Config where
  /-- What a person signs in with. -/
  password : String
  /-- The bearer for `/api/v1/` (`DIFF_REVIEWER_API_TOKEN_FILE`). Without one only a signed-in
      browser reaches the API. -/
  apiToken : Option String := none
  /-- The bearer for `/api/agent/v1/` (`DIFF_REVIEWER_AGENT_TOKEN_FILE`). Without one the agent API
      refuses everything. -/
  agentToken : Option String := none
  port : UInt16 := 8090
  /-- Loopback by default: the API is plain HTTP, so anything wider is a deliberate choice. -/
  host : String := "127.0.0.1"
  /-- The built front-end (`web/dist`), when it is served from here too. -/
  siteDir : Option System.FilePath := none
  sessionTtlSeconds : Nat := 43200
  /-- Add `Secure` to the session cookie; on whenever TLS terminates in front. -/
  secureCookie : Bool := false
  /-- The SQLite database file. -/
  dbPath : System.FilePath := "diff-reviewer.db"
  /-- Seconds between the passes of the background workers. -/
  interval : Nat := 60
  /-- The address of the reverse proxy in front, whose `X-Forwarded-For` names the client. A
      request from anywhere else is taken to come from its socket's peer. -/
  trustedProxy : Option String := none
  /-- The bounds the workers keep to. -/
  limits : Workers.Limits := {}

/-- Why `cfg`'s credentials are unsafe to serve with, if they are: a short secret, or one secret
    used for two credentials, which would make them interchangeable. -/
def Config.check (cfg : Config) : Except String Unit := do
  if cfg.password.length < 12 then throw "the password is shorter than 12 characters"
  for (what, tok?) in [("API", cfg.apiToken), ("agent", cfg.agentToken)] do
    if let some tok := tok? then
      if tok.length < 32 then throw s!"the {what} token is shorter than 32 characters"
      if tok == cfg.password then throw s!"the {what} token is the password"
  if let (some a, some b) := (cfg.apiToken, cfg.agentToken) then
    if a == b then throw "the API token and the agent token are the same"

private def nowEpoch : IO Int :=
  return (← Std.Time.Timestamp.now).toSecondsSinceUnixEpoch.val

/-- The failed logins of one client, or of all: their times within the window, and until when
    attempts are refused. -/
structure Lockout where
  failures    : Array Int := #[]
  lockedUntil : Int := 0
  deriving Inhabited

structure State where
  cfg : Config
  /-- Session ids with their expiry, in epoch seconds. In memory: a restart logs everyone out. -/
  sessions : IO.Ref (Array (String × Int))
  /-- GitHub, orchestra, and the posting guard. -/
  services : Workers.Services
  /-- Failed logins by client address. -/
  loginByAddress : IO.Ref (Array (String × Lockout))
  /-- Failed logins from everywhere. -/
  loginGlobal : IO.Ref Lockout
  /-- The current epoch second; replaced in the suite. -/
  clock : IO Int := nowEpoch
  /-- Sleep this many milliseconds; replaced in the suite. -/
  sleep : Nat → IO Unit := fun ms => IO.sleep ms.toUInt32

def State.new (cfg : Config) (services : Option Workers.Services := none)
    (clock : IO Int := nowEpoch) (sleep : Nat → IO Unit := fun ms => IO.sleep ms.toUInt32) :
    IO State := do
  let services ← match services with
    | some s => pure s
    | none => Workers.Services.new
  return { cfg, sessions := ← IO.mkRef #[], services, loginByAddress := ← IO.mkRef #[]
         , loginGlobal := ← IO.mkRef {}, clock, sleep }

def sessionCookieName : String := "diff_reviewer_session"

/-- Length-independent comparison, so a wrong secret takes as long to refuse as a right one takes
    to accept. -/
def constantTimeEq (a b : String) : Bool := Id.run do
  let x := a.toUTF8
  let y := b.toUTF8
  let byte (b : ByteArray) (i : Nat) : UInt8 := if h : i < b.size then b[i] else 0
  let mut diff : UInt8 := if x.size == y.size then 0 else 1
  for i in [0:max x.size y.size] do
    diff := diff ||| (byte x i ^^^ byte y i)
  return diff == 0

private def issueSession (st : State) : IO String := do
  let id ← randomHex 32
  let now ← st.clock
  st.sessions.modify fun ss =>
    (ss.filter (fun (_, exp) => exp > now)).push (id, now + st.cfg.sessionTtlSeconds)
  return id

private def sessionValid (st : State) (id : String) : IO Bool := do
  let now ← st.clock
  return (← st.sessions.get).any fun (sid, exp) => exp > now && constantTimeEq sid id

def cookieValue (raw : String) (name : String) : Option String :=
  (raw.splitOn ";").findSome? fun part =>
    match (part.trimAscii.toString.splitOn "=") with
    | k :: rest => if k == name then some ("=".intercalate rest) else none
    | [] => none

private def cookieHeader (st : State) (value : String) (maxAge : Nat) : String :=
  let attrs := s!"{sessionCookieName}={value}; HttpOnly; SameSite=Strict; Path=/; Max-Age={maxAge}"
  if st.cfg.secureCookie then attrs ++ "; Secure" else attrs

/-- The bearer token a request carries. -/
def bearer (r : Req) : Option String := do
  let auth ← r.header "authorization"
  guard (auth.startsWith "Bearer ")
  return (auth.drop "Bearer ".length).trimAscii.toString

/-- Whether a request carries the API token, or a session obtained with the password. -/
def authenticated (st : State) (r : Req) : IO Bool := do
  if let (some tok, some expected) := (bearer r, st.cfg.apiToken) then
    if constantTimeEq tok expected then return true
  if let some sid := (r.header "cookie").bind (cookieValue · sessionCookieName) then
    return ← sessionValid st sid
  return false

/-- Whether a request carries the agent token. Nothing else counts: not a session, not the API
    token. -/
def agentAuthenticated (st : State) (r : Req) : Bool :=
  match bearer r, st.cfg.agentToken with
  | some tok, some expected => constantTimeEq tok expected
  | _, _ => false

/-! ## Login rate limiting -/

/-- Failed logins allowed from one address within `loginWindowSeconds` before its attempts are
    refused. -/
def loginFailureLimit : Nat := 5

/-- Failed logins from all addresses together within the window past which every attempt is slowed
    by `loginGlobalDelayMs`: a guess spread over many addresses is slowed down, and the operator,
    from an address of their own, is slowed too but never refused. -/
def loginGlobalLimit : Nat := 100

/-- The delay every login attempt takes while past `loginGlobalLimit`, in milliseconds. -/
def loginGlobalDelayMs : Nat := 2000

def loginWindowSeconds : Int := 900

/-- The most addresses whose failures are remembered; past it the least recent is forgotten. -/
def loginMaxAddresses : Nat := 4096

/-- How long attempts are refused after the `n`th failure in the window (`n ≥ limit`): 15 seconds,
    doubling, at most the window. -/
def loginBackoff (n : Nat) (limit : Nat := loginFailureLimit) : Int :=
  min loginWindowSeconds (15 * 2 ^ (min 10 (n - limit)))

def Lockout.wait (l : Lockout) (now : Int) : Option Int :=
  if now < l.lockedUntil then some (l.lockedUntil - now) else none

def Lockout.fail (l : Lockout) (now : Int) (limit : Nat) : Lockout :=
  let failures := (l.failures.filter (· > now - loginWindowSeconds)).push now
  { failures
  , lockedUntil := if failures.size ≥ limit then now + loginBackoff failures.size limit
                   else l.lockedUntil }

/-- Whether `l` holds nothing a later attempt is judged by. -/
private def Lockout.expired (l : Lockout) (now : Int) : Bool :=
  l.lockedUntil ≤ now && l.failures.all (· ≤ now - loginWindowSeconds)

/-- The groups of an IPv6 address, all eight, or `none` if it is not one. -/
def ipv6Groups (a : String) : Option (List String) := do
  let parts := a.splitOn "::"
  let split (s : String) : List String := if s.isEmpty then [] else s.splitOn ":"
  let groups ← match parts with
    | [whole] => pure (split whole)
    | [h, t] =>
      let (h, t) := (split h, split t)
      guard (h.length + t.length < 8)
      pure (h ++ List.replicate (8 - h.length - t.length) "0" ++ t)
    | _ => none
  guard (groups.length == 8 && groups.all fun g =>
    !g.isEmpty && g.length ≤ 4 &&
      g.all (fun c => c.isDigit || ('a' ≤ c.toLower && c.toLower ≤ 'f')))
  return groups.map fun g =>
    let g := (g.toLower.dropWhile (· == '0')).toString
    if g.isEmpty then "0" else g

/-- The key failed logins are counted under for `addr`: an IPv4 address as it is (an IPv4-mapped
    IPv6 one as its IPv4 address), an IPv6 address as its /64 — what one subscriber holds, and can
    pick any address of for each guess. -/
def addressKey (addr : String) : String :=
  let last := (addr.splitOn ":").getLast!
  if addr.contains ':' && last.contains '.' then last
  else match ipv6Groups addr with
    | some gs => ":".intercalate (gs.take 4) ++ "::/64"
    | none => addr

/-- The client a request is from: the last address of `X-Forwarded-For` when the request comes
    from the trusted proxy — the one that proxy added — and otherwise the socket's peer. A header
    from anyone else is ignored, or any client could claim a fresh address for every guess. The
    answer is the address's `addressKey`. -/
def clientAddress (st : State) (r : Req) : String :=
  let peer := r.peer.getD "unknown"
  addressKey <| if st.cfg.trustedProxy == some peer then
    match (r.header "x-forwarded-for").bind fun h =>
        ((h.splitOn ",").map (·.trimAscii.toString)).filter (!·.isEmpty) |>.getLast? with
    | some a => a
    | none => peer
  else peer

/-- The seconds a login attempt from `addr` must still wait, or `none` if it may be made. -/
private def loginWait (st : State) (addr : String) : IO (Option Int) := do
  let now ← st.clock
  let mine := ((← st.loginByAddress.get).find? (·.1 == addr)).map (·.2)
  return mine.bind (·.wait now)

/-- Slow the attempt down while all addresses together are past `loginGlobalLimit`. -/
private def loginThrottle (st : State) : IO Unit := do
  let now ← st.clock
  let recent := (← st.loginGlobal.get).failures.filter (· > now - loginWindowSeconds)
  if recent.size ≥ loginGlobalLimit then st.sleep loginGlobalDelayMs

private def loginFailed (st : State) (addr : String) : IO Unit := do
  let now ← st.clock
  -- Only whether the window holds `loginGlobalLimit` failures matters, so no more are kept.
  st.loginGlobal.modify fun l =>
    let l := l.fail now loginGlobalLimit
    { l with failures := l.failures.extract (l.failures.size - loginGlobalLimit) l.failures.size }
  st.loginByAddress.modify fun t =>
    let mine := ((t.find? (·.1 == addr)).map (·.2)).getD {}
    let rest := (t.filter fun (a, l) => a != addr && !l.expired now)
    -- Bounded: forget the address whose last failure is oldest.
    let rest := if rest.size < loginMaxAddresses then rest else
      (rest.qsort fun x y => x.2.failures.back?.getD 0 > y.2.failures.back?.getD 0).pop
    rest.push (addr, mine.fail now loginFailureLimit)

private def loginSucceeded (st : State) (addr : String) : IO Unit :=
  st.loginByAddress.modify (·.filter (·.1 != addr))

/-! ## Paths -/

def isJsonContentType : Option String → Bool
  | none   => false
  | some raw =>
    let ty := ((raw.splitOn ";").headD "").trimAscii.toString.toLower
    ty == "application/json" || (ty.startsWith "application/" && ty.endsWith "+json")

/-- The segments of an `/api/v1/…` path, each of which may name only itself: letters, digits,
    `-`, `_` and `.`, not `.` or `..`. Percent-escapes are not decoded, so `%2e%2e` is refused as a
    segment rather than read as a second spelling of `..`. -/
def apiSegments (path : String) : Option (List String) := do
  guard (path.startsWith "/api/v1/")
  let segs := ((path.drop "/api/v1/".length).toString.splitOn "/").filter (!·.isEmpty)
  guard (!segs.isEmpty)
  guard (segs.all fun s => s != "." && s != ".." &&
    s.all fun c => c.isAlphanum || c == '-' || c == '_' || c == '.')
  return segs

/-- The paths reachable without a credential. -/
def publicPaths : Array String := #["/api/login", "/api/logout", "/api/session", "/api/openapi.json"]

/-! ## The API -/

/-- `docs/openapi.json`, embedded so that the spec describes the binary answering. Lake keys this
    module's build on its own source, not on the file it includes: after editing the spec, change
    this module too (or delete its build output) so that it is embedded again. -/
def openApiSpec : String := include_str "../docs/openapi.json"

private def items (xs : Array Json) : Json := .mkObj [("items", .arr xs)]

private def parseBody (body : String) : Except String Json :=
  (Json.parse body).mapError (s!"the body is not valid JSON: " ++ ·)

private def putRepo (owner name body : String) : IO Reply := do
  unless validSlugPart owner && validSlugPart name do
    return .error s!"'{owner}/{name}' is not a GitHub repository name" .badRequest
  let j ← match parseBody body with
    | .ok j => pure j
    | .error e => return .error e .badRequest
  let mode ← match j.getObjVal? "mode" with
    | .error _ | .ok .null => pure PostingMode.staged
    | .ok (.str s) => match PostingMode.ofString? s with
      | some m => pure m
      | none => return .error s!"'mode' must be 'staged' or 'direct', not '{s}'" .badRequest
    | .ok _ => return .error "'mode' must be a string" .badRequest
  let autoReview ← match j.getObjVal? "autoReview" with
    | .error _ | .ok .null => pure false
    | .ok (.bool b) => pure b
    | .ok _ => return .error "'autoReview' must be true or false" .badRequest
  let existed ← Platform.putRepo owner name mode autoReview
  let some repo ← Platform.findRepo owner.toLower name.toLower
    | return .error "the repository was written and could not be read back" .internalServerError
  return .json repo.toJson (if existed then .ok else .created)

private def createJob (body : String) : IO Reply := do
  let j ← match parseBody body with
    | .ok j => pure j
    | .error e => return .error e .badRequest
  let some owner := (j.getObjValAs? String "owner").toOption
    | return .error "the body must name the repository's 'owner'" .badRequest
  let some name := (j.getObjValAs? String "name").toOption
    | return .error "the body must name the repository's 'name'" .badRequest
  let some prNumber := (j.getObjValAs? Nat "prNumber").toOption
    | return .error "the body must name the pull request as a whole number 'prNumber'" .badRequest
  unless 1 ≤ prNumber && prNumber ≤ maxPrNumber do
    return .error s!"'prNumber' must be between 1 and {maxPrNumber}" .badRequest
  let headSha ← match j.getObjVal? "headSha" with
    | .error _ | .ok .null => pure none
    | .ok (.str sha) =>
      let sha := sha.toLower
      unless validSha sha do
        return .error s!"'headSha' must be a whole commit id (40 or 64 hex digits), not '{sha}'"
          .badRequest
      pure (some sha)
    | .ok _ => return .error "'headSha' must be a string" .badRequest
  let some repo ← Platform.findRepo owner.toLower name.toLower
    | return .error s!"{owner}/{name} is not a registered repository" .notFound
  let job ← Platform.createJob repo prNumber headSha
  return .json job.toJson .created

/-- The `version` a write names: the version of the job the client last read. -/
private def versionOf (j : Json) : Except String Nat :=
  match j.getObjValAs? Nat "version" with
  | .ok v => .ok v
  | .error _ => .error "the body must carry the job's 'version', as last read"

private def updateReply : Except Platform.UpdateError Job → Reply
  | .ok job => .json job.toJson
  | .error .notFound => .error "not found" .notFound
  | .error (.conflict why) => .error why .conflict
  | .error (.invalid why) => .error why .badRequest

/-- The checks every person's write makes on the job it is about: this build understands its
    status, and it is the version the client read. -/
private def current (job : Job) (version : Nat) : Except Platform.UpdateError JobStatus := do
  let some st := job.status?
    | throw (.conflict s!"job {job.id} is '{job.statusRaw}', a status this build does not know; \
it is left as it is")
  unless job.version == version do
    throw (.conflict s!"job {job.id} has changed since it was read (version {version}, now \
{job.version}); reload it")
  return st

/-- Replace a job's review. The body is `{"version": n, "review": {...}}`. Editing makes the job a
    draft again — an approval was of the review as it was. -/
private def putReview (id body : String) : IO Reply := do
  let j ← match parseBody body with
    | .ok j => pure j
    | .error e => return .error e .badRequest
  let version ← match versionOf j with
    | .ok v => pure v
    | .error e => return .error e .badRequest
  let review ← match j.getObjVal? "review" >>= Review.ofJson with
    | .ok r => pure r
    | .error e => return .error s!"'review' is not a review: {e}" .badRequest
  if let .error e := review.validate then return .error s!"'review': {e}" .badRequest
  updateReply <$> Platform.updateJob id fun job => do
    let st ← current job version
    if let some why := job.claimBlocks then throw (.conflict why)
    unless st.personCanEdit do
      throw (.conflict s!"job {id} is {st.toString}; its review is not edited now")
    if let some (.error e) := job.review? then
      throw (.conflict s!"job {id}'s stored review cannot be read by this build ({e}); it is \
left as it is")
    return { job.setReview review with statusRaw := JobStatus.draft.toString }

/-- Make a person's decision on a job. The body is `{"status": …, "version": n}`. -/
private def setStatus (id body : String) : IO Reply := do
  let j ← match parseBody body with
    | .ok j => pure j
    | .error e => return .error e .badRequest
  let version ← match versionOf j with
    | .ok v => pure v
    | .error e => return .error e .badRequest
  let some to := (j.getObjValAs? String "status").toOption.bind JobStatus.ofString?
    | return .error "'status' must be approved, rejected, stale, draft or pending" .badRequest
  updateReply <$> Platform.updateJob id fun job => do
    let st ← current job version
    if let some why := job.claimBlocks then throw (.conflict why)
    unless st.personCanMove to do
      throw (.conflict s!"job {id} is {st.toString} and cannot be made {to.toString} from here")
    if to == .approved then
      match job.review? with
      | some (.ok _) => pure ()
      | some (.error e) => throw (.conflict s!"job {id}'s review does not parse ({e})")
      | none => throw (.conflict s!"job {id} has no review to approve")
    -- Another run: the entry of the last one is history, and so is why it failed.
    if to == .pending then
      return { job with statusRaw := to.toString, queueEntry := none, error := none }
    return { job with statusRaw := to.toString }

/-- Post an approved review to GitHub. The body is `{"version": n}`. `502` when GitHub refuses,
    with the job — still `approved`, the reason in its `error` — beside the message. -/
private def postJob (st : State) (id body : String) : IO Reply := do
  let j ← match parseBody body with
    | .ok j => pure j
    | .error e => return .error e .badRequest
  let version ← match versionOf j with
    | .ok v => pure v
    | .error e => return .error e .badRequest
  match ← Workers.postJob st.services id (some version) with
  | .ok job => return .json job.toJson
  | .error .notFound => return .error "not found" .notFound
  | .error (.conflict why) => return .error why .conflict
  | .error .unavailable =>
    return .error "GitHub is not configured (DIFF_REVIEWER_GITHUB_TOKEN_FILE)" .serviceUnavailable
  | .error (.github why job) =>
    return .json (.mkObj [("error", s!"GitHub refused the review: {why}"), ("job", job.toJson)])
      .badGateway

private def diffReply (st : State) (job : Job) (text : Bool) : IO Reply := do
  match ← Workers.diffOf st.services job with
  | .ok (head, diff) =>
    if text then
      return { status := .ok, body := diff.toUTF8, contentType := "text/plain; charset=utf-8"
             , headers := [("Cache-Control", "no-store")] }
    return .json (.mkObj [("headSha", head), ("diff", diff)])
  | .error .noHead => return .error Workers.DiffError.noHead.message .conflict
  | .error .unavailable => return .error Workers.DiffError.unavailable.message .serviceUnavailable
  | .error (.tooLarge why) => return .error why .payloadTooLarge
  | .error (.github why) => return .error s!"the diff could not be read: {why}" .badGateway

/-- Every route under `/api/v1/`, with the methods it answers. `DiffReviewerTest.Server` checks
    this against `docs/openapi.json`, so a route without a spec entry fails the suite. -/
def apiRoutes : Array (String × Array String) :=
  #[("repos",                    #["get"]),
    ("repos/{owner}/{name}",     #["put", "delete"]),
    ("jobs",                     #["get", "post"]),
    ("jobs/{id}",                #["get"]),
    ("jobs/{id}/review",         #["put"]),
    ("jobs/{id}/status",         #["post"]),
    ("jobs/{id}/post",           #["post"]),
    ("jobs/{id}/diff",           #["get"])]

private def apiRoute (st : State) (r : Req) (segs : List String) : IO Reply := do
  match segs, r.method with
  | ["repos"], .get =>
    return .json (items ((← Platform.listRepos).map (·.toJson)))
  | ["repos", owner, name], .put => putRepo owner name r.body
  | ["repos", owner, name], .delete =>
    if ← Platform.deleteRepo owner name then return .noContent
    else return .error "not found" .notFound
  | ["jobs"], .get =>
    return .json (items ((← Platform.listJobs).map (·.toJson)))
  | ["jobs"], .post => createJob r.body
  | ["jobs", id], .get =>
    match ← Platform.findJob id with
    | some j => return .json j.toJson
    | none   => return .error "not found" .notFound
  | ["jobs", id, "review"], .put => putReview id r.body
  | ["jobs", id, "status"], .post => setStatus id r.body
  | ["jobs", id, "post"], .post => postJob st id r.body
  | ["jobs", id, "diff"], .get =>
    match ← Platform.findJob id with
    | some j => diffReply st j (text := false)
    | none   => return .error "not found" .notFound
  | ["repos"], _ | ["repos", _, _], _ | ["jobs"], _ | ["jobs", _], _
  | ["jobs", _, "review"], _ | ["jobs", _, "status"], _ | ["jobs", _, "post"], _
  | ["jobs", _, "diff"], _ =>
    return .error "method not allowed" .methodNotAllowed
  | _, _ => return .error "not found" .notFound

/-! ## The agent API -/

/-- Every route under `/api/agent/v1/`, with the methods it answers; checked against
    `docs/openapi.json` like `apiRoutes`. Each is under `repos/{owner}/{name}/pulls/{pr}`, so that a
    kleis grant can bind it to the task's repository and pull request. -/
def agentRoutes : Array (String × Array String) :=
  #[("repos/{owner}/{name}/pulls/{pr}",        #["get"]),
    ("repos/{owner}/{name}/pulls/{pr}/diff",   #["get"]),
    ("repos/{owner}/{name}/pulls/{pr}/review", #["post"])]

/-- The segments of an `/api/agent/v1/…` path, checked as `apiSegments` checks them. -/
def agentSegments (path : String) : Option (List String) :=
  if path.startsWith "/api/agent/v1/" then
    apiSegments ("/api/v1/" ++ (path.drop "/api/agent/v1/".length).toString)
  else none

/-- The job an agent is running for a pull request: one that is `queued` or `running` — the one the
    agent names (`X-Diff-Reviewer-Job`, from `--job`), or else the only one. With two, an agent
    that does not say which it runs is told so rather than given one: the run of a superseded head
    must not take over the review of the new one. -/
private def activeJob (owner name : String) (pr : Nat) (jobId : Option String) :
    IO (Except Reply Job) := do
  let active := (← Platform.jobsOfPull owner.toLower name.toLower pr).filter fun j =>
    j.status? == some .queued || j.status? == some .running
  let notRun := Reply.error s!"no review of {owner}/{name}#{pr} is being run" .notFound
  match jobId with
  | some id => return match active.find? (·.id == id) with
    | some j => .ok j
    | none => .error (Reply.error s!"job {id} is not a review of {owner}/{name}#{pr} being run"
        .notFound)
  | none =>
    match active.toList with
    | [] => return .error notRun
    | [j] => return .ok j
    | _ => return .error (Reply.error s!"{active.size} reviews of {owner}/{name}#{pr} are being \
run; name yours with --job" .conflict)

private def agentJobJson (job : Job) : Json :=
  .mkObj [("jobId", job.id), ("owner", job.owner), ("name", job.name), ("prNumber", job.prNumber),
          ("headSha", (job.headSha.map Json.str).getD .null),
          ("baseSha", (job.baseSha.map Json.str).getD .null),
          ("title", job.title.getD ""), ("body", job.prBody.getD ""),
          ("status", job.statusRaw), ("instructions", Workers.instructions),
          ("prTypes", .arr #[]), ("examples", .arr #[])]

/-- The first read of a queued job is the run starting: it moves to `running`. -/
private def agentShow (job : Job) : IO Reply := do
  if job.status? != some .queued then return .json (agentJobJson job)
  match ← Platform.updateJob job.id fun j => do
      unless j.status? == some .queued do return j
      return { j with statusRaw := JobStatus.running.toString }
  with
  | .ok j => return .json (agentJobJson j)
  | .error _ => return .error "not found" .notFound

/-- The agent's review. The body is `{"headSha", "prType", "review"}`; the job must be running and
    at that head. A `direct` repository's review is then posted at once; if that fails the job is
    left `approved` with the reason, for a person to post again, and the submission still stands. -/
private def agentSubmit (st : State) (job : Job) (body : String) : IO Reply := do
  let j ← match parseBody body with
    | .ok j => pure j
    | .error e => return .error e .badRequest
  let some headSha := (j.getObjValAs? String "headSha").toOption
    | return .error "the body must name the 'headSha' that was reviewed" .badRequest
  let prType ← match j.getObjVal? "prType" with
    | .error _ | .ok .null => pure none
    | .ok (.str t) => pure (some t)
    | .ok _ => return .error "'prType' must be a string or null" .badRequest
  let review ← match j.getObjVal? "review" >>= Review.ofJson with
    | .ok r => pure r
    | .error e => return .error s!"'review' is not a review: {e}" .badRequest
  if let .error e := review.validate then return .error s!"'review': {e}" .badRequest
  -- GitHub refuses a comment off the diff; the agent is told now, while it can still fix it.
  if let .ok (_, d) ← Workers.diffOf st.services job then
    if let .error e := Diff.check review d then return .error s!"'review': {e}" .badRequest
  let headSha := headSha.toLower
  let drafted ← Platform.updateJob job.id fun j => do
    unless j.status? == some .running do
      throw (.conflict s!"job {j.id} is {j.statusRaw}, not running; run `diff-reviewer agent \
show` first")
    unless j.headSha == some headSha do
      throw (.conflict s!"the review is of {headSha}, but job {j.id} is of \
{j.headSha.getD "no commit"}")
    return { j.setReview review with statusRaw := JobStatus.draft.toString, prType, error := none }
  let job ← match drafted with
    | .ok j => pure j
    | .error e => return updateReply (.error e)
  let job ← match ← Platform.findRepo job.owner job.name with
    | some repo =>
      if repo.mode != .direct then pure job else
      match ← Workers.postDirect st.services job.id job.version with
      | .ok j => pure j
      | .error _ => pure ((← Platform.findJob job.id).getD job)
    | none => pure job
  return .json (.mkObj [("jobId", job.id), ("status", job.statusRaw),
                        ("error", (job.error.map Json.str).getD .null)])

private def agentRoute (st : State) (r : Req) : IO Reply := do
  unless agentAuthenticated st r do return .error "unauthorized" .unauthorized
  let some segs := agentSegments r.path | return .error "not found" .notFound
  if r.method == .post && !isJsonContentType (r.header "content-type") then
    return .error "writes must be sent as application/json" .unsupportedMediaType
  let pull (owner name pr : String) (k : Job → IO Reply) : IO Reply := do
    let some n := pr.toNat? | return .error "not found" .notFound
    match ← activeJob owner name n (r.header "x-diff-reviewer-job") with
    | .ok job => k job
    | .error reply => return reply
  match segs, r.method with
  | ["repos", o, n, "pulls", pr], .get => pull o n pr agentShow
  | ["repos", o, n, "pulls", pr, "diff"], .get => pull o n pr (diffReply st · (text := true))
  | ["repos", o, n, "pulls", pr, "review"], .post => pull o n pr (agentSubmit st · r.body)
  | ["repos", _, _, "pulls", _], _ | ["repos", _, _, "pulls", _, "diff"], _
  | ["repos", _, _, "pulls", _, "review"], _ => return .error "method not allowed" .methodNotAllowed
  | _, _ => return .error "not found" .notFound

/-! ## Static files -/

private def contentTypeOf (name : String) : String :=
  if      name.endsWith ".html" then "text/html; charset=utf-8"
  else if name.endsWith ".css"  then "text/css; charset=utf-8"
  else if name.endsWith ".js"   then "text/javascript; charset=utf-8"
  else if name.endsWith ".json" then "application/json; charset=utf-8"
  else if name.endsWith ".svg"  then "image/svg+xml"
  else if name.endsWith ".png"  then "image/png"
  else if name.endsWith ".ico"  then "image/x-icon"
  else if name.endsWith ".woff2" then "font/woff2"
  else "application/octet-stream"

/-- The file a path names under `root`, or `none` if it would leave it. `.` and `..` are refused
    rather than normalised, and nothing is percent-decoded. -/
def staticCandidate (root : System.FilePath) (path : String) : Option System.FilePath :=
  let segs := (path.splitOn "/").filter (!·.isEmpty)
  if segs.any (fun s => s == "." || s == ".." || s.contains '\\') then none
  else some (segs.foldl (fun (p : System.FilePath) (s : String) => p / s) root)

/-- Serve a file of the site, falling back to `index.html` for a path without an extension — a
    client-side route — so that reloading `/jobs/abc` answers the app. -/
private def serveStatic (root : System.FilePath) (path : String) : IO Reply := do
  let shell := root / "index.html"
  let lastHasDot := ((path.splitOn "/").filter (!·.isEmpty)).getLast?.any (·.contains '.')
  let file? ← match staticCandidate root path with
    | none => pure none
    | some f =>
      if ← f.isDir then
        pure (if ← (f / "index.html").pathExists then some (f / "index.html") else none)
      else if ← f.pathExists then pure (some f)
      else pure none
  let file? ← match file? with
    | some f => pure (some f)
    | none => pure (if !lastHasDot && (← shell.pathExists) then some shell else none)
  let some file := file? | return { status := .notFound, body := "not found\n".toUTF8,
                                    contentType := "text/plain; charset=utf-8" }
  let cache := if path.startsWith "/assets/" then "public, max-age=31536000, immutable"
    else "no-cache"
  return { status := .ok, body := ← IO.FS.readBinFile file
         , contentType := contentTypeOf file.toString, headers := [("Cache-Control", cache)] }

/-! ## Routing -/

/-- Answer one request. The credential is required first, before any route runs, except for the
    public paths and the site — checking once is what keeps a route from being open by omission.

    Two things keep a write from being forged by another site: the cookie is `SameSite=Strict`,
    and a write has to be JSON (or a `DELETE`), which from another origin needs a CORS preflight
    this server never grants. So: no CORS headers, and no `GET` that changes anything. -/
def route (st : State) (r : Req) : IO Reply := do
  if r.path.startsWith "/api/agent/" then
    try return ← agentRoute st r
    catch e =>
      IO.eprintln s!"diff-reviewer: {r.path}: {e}"
      return .error "internal error; see the server log" .internalServerError
  let isSite := r.method == .get && !r.path.startsWith "/api/"
  unless publicPaths.contains r.path || isSite || (← authenticated st r) do
    return .error "unauthorized" .unauthorized
  if r.path == "/api/openapi.json" then
    return { status := .ok, body := openApiSpec.toUTF8, headers := [("Cache-Control", "no-cache")] }
  if r.path == "/api/login" then
    unless r.method == .post do return .error "method not allowed" .methodNotAllowed
    let supplied := (Json.parse r.body).toOption.bind (·.getObjValAs? String "password" |>.toOption)
    let some p := supplied
      | return .error "expected a JSON body of the form {\"password\": \"…\"}" .badRequest
    let addr := clientAddress st r
    loginThrottle st
    if let some wait ← loginWait st addr then
      return { Reply.error s!"too many failed logins; try again in {wait} seconds"
                 .tooManyRequests with
               headers := [("Cache-Control", "no-store"), ("Retry-After", toString wait)] }
    unless constantTimeEq p st.cfg.password do
      loginFailed st addr
      return .error "invalid password" .unauthorized
    loginSucceeded st addr
    let sid ← issueSession st
    return { Reply.json (.mkObj [("authenticated", true)]) with
             headers := [("Cache-Control", "no-store"),
                         ("Set-Cookie", cookieHeader st sid st.cfg.sessionTtlSeconds)] }
  if r.path == "/api/logout" then
    unless r.method == .post do return .error "method not allowed" .methodNotAllowed
    if let some sid := (r.header "cookie").bind (cookieValue · sessionCookieName) then
      st.sessions.modify (·.filter fun (s, _) => !constantTimeEq s sid)
    return { Reply.json (.mkObj [("authenticated", false)]) with
             headers := [("Cache-Control", "no-store"), ("Set-Cookie", cookieHeader st "" 0)] }
  if r.path == "/api/session" then
    return .json (.mkObj [("authenticated", Json.bool (← authenticated st r))])
  if isSite then
    match st.cfg.siteDir with
    | some root => return ← serveStatic root r.path
    | none => return { status := .notFound, body := "not found\n".toUTF8,
                       contentType := "text/plain; charset=utf-8" }
  let some segs := apiSegments r.path | return .error "not found" .notFound
  if r.method == .post || r.method == .put then
    unless isJsonContentType (r.header "content-type") do
      return .error "writes must be sent as application/json" .unsupportedMediaType
  -- The reason goes to the log, not the response: it can quote SQL and stored values.
  try apiRoute st r segs
  catch e =>
    IO.eprintln s!"diff-reviewer: {r.path}: {e}"
    return .error "internal error; see the server log" .internalServerError

/-! ## Serving -/

/-- Cap on a request body: a review with many comments is the largest thing written. -/
private def maxBodyBytes : UInt64 := 1048576

private structure Server where
  st : State

private def toResponse (rep : Reply) : Async (Response Body.Any) := do
  let b := Response.withStatus rep.status
    |>.header! "X-Content-Type-Options" "nosniff"
    |>.header! "X-Frame-Options" "DENY"
    |>.header! "Referrer-Policy" "no-referrer"
    -- Review text is written by agents reading pull requests, so it is untrusted: the app renders
    -- it as text, and this keeps anything that slipped through from loading or running.
    |>.header! "Content-Security-Policy"
      "default-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'"
  let b := if rep.contentType.isEmpty then b else b.header! "Content-Type" rep.contentType
  let b := rep.headers.foldl (fun b (k, v) => b.header! k v) b
  b.fromBytes rep.body

private instance : Handler Server where
  onRequest s req := do
    let body : String ← if req.line.method == .post || req.line.method == .put then
        req.body.readAll (maximumSize := some maxBodyBytes)
      else pure ""
    let peer := (req.extensions.get Std.Http.Server.RemoteAddr).map fun a =>
      match a.addr with
      | .v4 v => toString v.addr
      | .v6 v => toString v.addr
    let r : Req :=
      { method := req.line.method, path := toString req.line.uri.path, body, peer
      , header := fun n => (req.line.headers.get? (Header.Name.ofString! n)).map toString }
    toResponse (← route s.st r)
  onFailure _ _ := pure ()

private def httpConfig : Std.Http.Config where
  maxRequests := 0
  maxBodySize := maxBodyBytes.toNat
  maxUriLength := 4096

/-- Start serving. Returns the bound port and a function that stops the server. -/
def serve (cfg : Config) (services : Workers.Services) : IO (UInt16 × IO Unit) := do
  let some hostAddr := IPv4Addr.ofString cfg.host
    | throw (.userError s!"'{cfg.host}' is not an IPv4 address")
  let st ← State.new cfg services
  let server ← Async.block do
    Std.Http.Server.serve (SocketAddress.v4 { addr := hostAddr, port := cfg.port })
      (Server.mk st) httpConfig
  let boundPort := match server.localAddr with
    | some (.v4 a) => a.port
    | some (.v6 a) => a.port
    | none         => cfg.port
  return (boundPort, Async.block server.shutdownAndWait)

end DiffReviewer.Server