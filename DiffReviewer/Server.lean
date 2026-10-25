import Lean.Data.Json
import Std.Http
import Std.Net
import DiffReviewer.Platform
import DiffReviewer.Workers
import DiffReviewer.Proposal
import DiffReviewer.Style

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
  * `/api/v1/…` — the repositories and review jobs, calibration
    (`/api/v1/repos/{owner}/{name}/calibration/…`) and rubric proposals
    (`/api/v1/repos/{owner}/{name}/proposals/…`); see `docs/openapi.json`.
  * `/api/agent/v1/…` — what a reviewing agent reads and submits, through kleis: of a pull
    request (`…/pulls/{pr}…`) for a review, of the repository and the job
    (`…/proposals/{jobId}`) for a rubric proposal.
  * everything else — the front-end built into `web/dist` (`--site`), with a single-page-app
    fallback.

Routing is a pure-ish function from a `Req` to a `Reply` (`route`), so that the suite can drive
it without a socket; `serve` adapts `Std.Http` to it and back.

## Authentication

One person runs the platform — the one whose name approved reviews are posted under — and three
credentials reach it, none of which stands in for another:

  * **the password**, only ever sent to `POST /api/login`, which exchanges it for an `HttpOnly`,
    `SameSite=Strict` session cookie. Failed attempts are rate-limited per client address, and
    over all addresses together: past the limit, every attempt — right or wrong — is an
    immediate `429` for a delay that doubles with each further failure, so the password cannot be
    guessed at the speed of the network. Nothing waits in the handler: a slow refusal would hold
    a request thread.
  * **the API token** (`apiToken`), what a script sends as `Authorization: Bearer` to `/api/v1/`.
    The session cookie reaches the same routes, and `POST /api/login` takes the token too, never
    rate-limited — it cannot be guessed — so that the operator can sign in while password
    attempts are refused.
  * **the agent token** (`agentToken`), the only credential of `/api/agent/v1/`, and good for
    nothing else. Agents never hold it: an agent's request goes through kleis, which replaces the
    placeholder the agent sends with this token, and only for the routes, repository and pull
    request its grant allows.
  * **the proposals' agent token** (`proposerAgentToken`), the only credential of a rubric
    proposal's agent routes (`/api/agent/v1/repos/{owner}/{name}/proposals/…`), which the agent
    token does not reach, as it reaches no other: should kleis's grants ever let a review agent's
    request through to them, or a proposal agent's to a pull request, the platform still refuses
    it. kleis holds it, under an account of its own.

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
  /-- The query string, without the `?`, still percent-encoded. -/
  query   : String := ""

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
  /-- The bearer of a rubric proposal's agent routes (`DIFF_REVIEWER_PROPOSER_AGENT_TOKEN_FILE`),
      and of nothing else. Without one they refuse everything. -/
  proposerAgentToken : Option String := none
  /-- The platform's tokens on orchestra, for reviews and for rubric proposals: not served with,
      but checked with the others, so that no two credentials are one. -/
  orchestraToken : Option String := none
  proposerToken : Option String := none
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
  -- Every token stands for one credential only: the platform's own, and its two on orchestra —
  -- which refuses a token two clients share, and a token of one side that reached the other must
  -- not open it.
  let tokens : List (String × String) :=
    [("the API token", cfg.apiToken), ("the agent token", cfg.agentToken),
     ("the proposals' agent token", cfg.proposerAgentToken),
     ("the orchestra token", cfg.orchestraToken),
     ("the orchestra proposer token", cfg.proposerToken)].filterMap fun (w, t) => t.map (w, ·)
  for ((what, tok), i) in tokens.zipIdx do
    if tok.length < 32 then throw s!"{what} is shorter than 32 characters"
    if tok == cfg.password then throw s!"{what} is the password"
    for (other, tok') in tokens.drop (i + 1) do
      if tok == tok' then throw s!"{what} and {other} are the same"

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

def State.new (cfg : Config) (services : Option Workers.Services := none)
    (clock : IO Int := nowEpoch) : IO State := do
  let services ← match services with
    | some s => pure s
    | none => Workers.Services.new
  return { cfg, sessions := ← IO.mkRef #[], services, loginByAddress := ← IO.mkRef #[]
         , loginGlobal := ← IO.mkRef {}, clock }

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

/-- Whether a request carries the agent token — or, with `proposal`, the proposals' agent token.
    Nothing else counts: not a session, not the API token, not the other agent token. -/
def agentAuthenticated (st : State) (r : Req) (proposal := false) : Bool :=
  match bearer r, (if proposal then st.cfg.proposerAgentToken else st.cfg.agentToken) with
  | some tok, some expected => constantTimeEq tok expected
  | _, _ => false

/-! ## Login rate limiting -/

/-- Failed logins allowed from one address within `loginWindowSeconds` before its attempts are
    refused. -/
def loginFailureLimit : Nat := 5

/-- Failed logins from all addresses together within the window past which every password
    attempt is refused for a while: a guess spread over many addresses is stopped too. The
    operator is never locked out by it — `POST /api/login` also takes the API token, which no
    limit counts — and nothing waits: a refusal is an immediate `429`, so no request thread is
    held. -/
def loginGlobalLimit : Nat := 100

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

/-- The seconds a password attempt from `addr` must still wait, and why, or `none` if it may be
    made: its own address's lock first, then the one over all addresses. -/
private def loginWait (st : State) (addr : String) : IO (Option (Int × String)) := do
  let now ← st.clock
  let mine := ((← st.loginByAddress.get).find? (·.1 == addr)).map (·.2)
  if let some w := mine.bind (·.wait now) then
    return some (w, s!"too many failed logins; try again in {w} seconds")
  if let some w := (← st.loginGlobal.get).wait now then
    return some (w, s!"too many failed logins from everywhere; try again in {w} seconds, or sign \
in with the API token")
  return none

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

/-- The most items one page of a history holds, and what a page holds unless `limit` says. -/
def maxPageSize : Nat := 200

def defaultPageSize : Nat := 50

/-- Value `k` of a query string, undecoded. -/
def queryParam (query k : String) : Option String :=
  (query.splitOn "&").findSome? fun kv => match kv.splitOn "=" with
    | [a, b] => if a == k then some b else none
    | _ => none

/-- One page of `xs`, as `?limit=n&offset=m` names it (`defaultPageSize` and 0 unless they say):
    `{"items": [...], "nextOffset": …}`, `nextOffset` null on the last page. -/
private def page (query : String) (xs : Array Json) : IO Reply := do
  let num (k : String) (dflt : Nat) : Except String Nat :=
    match queryParam query k with
    | none => .ok dflt
    | some v => match v.toNat? with
      | some n => .ok n
      | none => .error s!"'{k}' must be a whole number"
  let (limit, offset) ← match num "limit" defaultPageSize, num "offset" 0 with
    | .ok l, .ok o => pure (l, o)
    | .error e, _ | _, .error e => return .error e .badRequest
  unless 1 ≤ limit && limit ≤ maxPageSize do
    return .error s!"'limit' must be between 1 and {maxPageSize}" .badRequest
  let next : Json := if offset + limit < xs.size then (offset + limit : Nat) else .null
  return .json (.mkObj [("items", .arr (xs.extract offset (offset + limit))),
                        ("nextOffset", next)])

private def parseBody (body : String) : Except String Json :=
  (Json.parse body).mapError (s!"the body is not valid JSON: " ++ ·)

/-- Register a repository or change its settings. Every field is optional. `prType` fixes the pull
    request type of the repository's reviews (a type of its current rubric; `""` for none, the
    agent's pick), which a fan-out needs (`DiffReviewer.Fanout`), and `maxFanout` bounds the
    sub-runs one review fans out to; both are kept when left out. `fromProposal` names
    the rubric proposal the style notes written come from: they record its provenance, and it is
    accepted with the write. `mode` and
    `autoReview` take their defaults when left out, as they always have; `trustedReviewers` and
    `styleNotes` keep what they were, so that a client that does not know them cannot wipe them.
    `version`, when given, is the version of the settings last read (0 for a repository not
    registered), and the write is a `409` if they have changed since. -/
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
  let trusted ← match j.getObjVal? "trustedReviewers" with
    | .error _ | .ok .null => pure none
    | .ok (.arr xs) =>
      let some logins := xs.toList.mapM (·.getStr?.toOption)
        | return .error "'trustedReviewers' must be an array of GitHub logins" .badRequest
      if let some bad := logins.find? (!validLogin ·) then
        return .error s!"'{bad}' is not a GitHub login" .badRequest
      if logins.length > maxTrustedReviewers then
        return .error s!"'trustedReviewers' names {logins.length} logins; at most \
{maxTrustedReviewers}" .badRequest
      pure (some logins)
    | .ok _ => return .error "'trustedReviewers' must be an array of GitHub logins" .badRequest
  let styleNotes ← match j.getObjVal? "styleNotes" with
    | .error _ | .ok .null => pure none
    | .ok (.str s) =>
      if s.utf8ByteSize > maxStyleNotesBytes then
        return .error s!"'styleNotes' is longer than {maxStyleNotesBytes} bytes" .badRequest
      pure (some s)
    | .ok _ => return .error "'styleNotes' must be a string" .badRequest
  let evalShare ← match j.getObjVal? "evalShare" with
    | .error _ | .ok .null => pure none
    | .ok v => match v.getNat? with
      | .ok n =>
        unless n ≤ 100 do return .error "'evalShare' must be between 0 and 100" .badRequest
        pure (some n)
      | .error _ => return .error "'evalShare' must be a whole number of percent" .badRequest
  let expected ← match j.getObjVal? "version" with
    | .error _ | .ok .null => pure none
    | .ok v => match v.getNat? with
      | .ok n => pure (some n)
      | .error _ => return .error "'version' must be a whole number" .badRequest
  -- The fixed type must be one the rubric names now; `""` clears it.
  let prType ← match j.getObjVal? "prType" with
    | .error _ | .ok .null => pure none
    | .ok (.str "") => pure (some none)
    | .ok (.str t) =>
      let doc := (← Platform.currentRubric owner.toLower name.toLower).bind (·.rubric?.toOption)
      unless (doc.bind (·.findType? t)).isSome do
        return .error s!"'prType' must name a pull request type of the repository's rubric, \
or be \"\" for none; '{t}' is not one" .badRequest
      pure (some (some t))
    | .ok _ => return .error "'prType' must be a pull request type's name, or \"\"" .badRequest
  let maxFanout ← match j.getObjVal? "maxFanout" with
    | .error _ | .ok .null => pure none
    | .ok v => match v.getNat? with
      | .ok n =>
        unless 1 ≤ n && n ≤ maxFanoutLimit do
          return .error s!"'maxFanout' must be between 1 and {maxFanoutLimit}" .badRequest
        pure (some n)
      | .error _ => return .error "'maxFanout' must be a whole number" .badRequest
  -- Style notes a person wrote from a rubric proposal — after rebasing it, say — record its
  -- provenance, and the proposal is accepted with the write.
  let provenance ← match j.getObjVal? "fromProposal" with
    | .error _ | .ok .null => pure (pure (.ok {}))
    | .ok (.str id) =>
      let now ← nowIso
      let repo : Repo := { owner := owner.toLower, name := name.toLower, createdAt := now }
      pure (Proposal.adoptIn repo id none now)
    | .ok _ => return .error "'fromProposal' must be a proposal's id" .badRequest
  match ← Platform.putRepo owner name
      { mode, autoReview, trustedReviewers := trusted, styleNotes, evalShare, prType, maxFanout
      , expected, provenance } with
  | .ok (existed, repo) => return .json repo.toJson (if existed then .ok else .created)
  | .error (.invalid why) => return .error why .badRequest
  | .error (.conflict why) => return .error why .conflict
  | .error .notFound => return .error "not found" .notFound

/-- A job as `GET` answers it: with the states of its sub-runs, when it is fanned out (empty when
    it is not). -/
private def jobJson (job : Job) (subs : Array Fanout.SubRun) : Json :=
  job.toJson.setObjVal! "subRuns" (.arr (subs.map (·.toJson)))

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

/-- The rubric a job's review is checked against: the version it was reviewed against — 0 is no
    rubric — and for a job that names none (made before rubrics, or not reviewed by the agent)
    the repository's current one; `none` when there is none. An error when that
    version cannot be read by this build. -/
private def rubricOfJob (job : Job) : IO (Except String (Option Rubric)) := do
  let version? ← match job.rubricVersion with
    | some 0 => pure none
    | some v => Platform.rubricAt job.owner job.name v
    | none => Platform.currentRubric job.owner job.name
  match version? with
  | none => return .ok none
  | some v => return (v.rubric?.map some).mapError fun e =>
    s!"the rubric of {job.owner}/{job.name} (version {v.version}) cannot be read by this build \
({e})"

/-- Replace a job's review. The body is `{"version": n, "review": {...}}`. Editing makes the job a
    draft again — an approval was of the review as it was. The categories are checked against the
    rubric the job was reviewed against, comments without an id are given one, and the review is
    appended to the job's history as a person's. -/
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
  let editable (job : Job) : Except Platform.UpdateError Unit := do
    let st ← current job version
    if let some why := job.claimBlocks then throw (.conflict why)
    -- A calibration job's review is what the agent submitted, scored as it was.
    unless job.isReview do
      throw (.conflict s!"job {id} is a {job.kindRaw.getD "review"} job; its review is not edited")
    unless st.personCanEdit do
      throw (.conflict s!"job {id} is {st.toString}; its review is not edited now")
    if let some (.error e) := job.review? then
      throw (.conflict s!"job {id}'s stored review cannot be read by this build ({e}); it is \
left as it is")
  let some job ← Platform.findJob id | return .error "not found" .notFound
  -- The checks of the job first: a stale page is told to reload before anything else.
  if let .error e := editable job then return updateReply (.error e)
  -- Only a category the edit adds or changes is checked: one the agent gave under the rubric it
  -- reviewed by is the agent's, and stays as it was.
  let stored := match job.review? with
    | some (.ok r) => r.comments
    | _ => []
  let changed (c : InlineComment) : Bool := match c.id with
    | none => true
    | some i => (stored.find? (·.id == some i)).map (·.category) != some c.category
  match ← rubricOfJob job with
  | .error e => return .error e .conflict
  | .ok doc =>
    let allowed := (doc.map (·.categoriesFor job.prType)).getD []
    if let .error e := review.checkCategories allowed changed then
      return .error s!"'review': {e}" .badRequest
  let review ← review.assignIds
  updateReply <$> Platform.updateJob id (revision := Job.revisionBy .person) fun job => do
    editable job
    -- A person's edit ends the platform's own attempts to post.
    return { job.setReview review with statusRaw := JobStatus.draft.toString, postDirect := false }

/-- Make a person's decision on a job. The body is `{"status": …, "version": n}`. Running a failed
    calibration job again charges its repository's daily cap of calibration jobs, as a new one
    does: `429` past it. -/
private def setStatus (st : State) (id body : String) : IO Reply := do
  let j ← match parseBody body with
    | .ok j => pure j
    | .error e => return .error e .badRequest
  let version ← match versionOf j with
    | .ok v => pure v
    | .error e => return .error e .badRequest
  let some to := (j.getObjValAs? String "status").toOption.bind JobStatus.ofString?
    | return .error "'status' must be approved, rejected, stale, draft or pending" .badRequest
  -- A proposal is decided as a proposal, and a failed one asked for again as a new one: its job's
  -- status is the platform's.
  if let some job ← Platform.findJob id then
    if job.kind? == some .proposal then
      return .error s!"job {id} is a rubric proposal: accept or reject the proposal it wrote, or \
ask for a new one" .conflict
  if to == .pending then
    if let some job ← Platform.findJob id then
      if job.kind? == some .calibration then
        return match ← Calibration.retryJob id version
            st.services.limits.maxCalibrationJobsPerDay with
          | .ok j => .json j.toJson
          | .error .notFound => .error "not found" .notFound
          | .error (.invalid why) => .error why .badRequest
          | .error (.conflict why) => .error why .conflict
          | .error (.capped why) => .error why .tooManyRequests
  updateReply <$> Platform.updateJob id fun job => do
    let st ← current job version
    if let some why := job.claimBlocks then throw (.conflict why)
    unless st.personCanMove to do
      throw (.conflict s!"job {id} is {st.toString} and cannot be made {to.toString} from here")
    if to == .approved then
      if let some why := job.notPostable then throw (.conflict why)
      match job.review? with
      | some (.ok _) => pure ()
      | some (.error e) => throw (.conflict s!"job {id}'s review does not parse ({e})")
      | none => throw (.conflict s!"job {id} has no review to approve")
    -- Another run: the entry of the last one is history, and so is why it failed.
    if to == .pending then
      return { job with statusRaw := to.toString, queueEntry := none, error := none
                        postDirect := false, fanoutRound := none }
    -- A person's move ends the platform's own attempts to post.
    return { job with statusRaw := to.toString, postDirect := false }

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

/-- Settle a claimed job without posting. The body is `{"version": n}`. -/
private def reconcileJob (st : State) (id body : String) : IO Reply := do
  let j ← match parseBody body with
    | .ok j => pure j
    | .error e => return .error e .badRequest
  let version ← match versionOf j with
    | .ok v => pure v
    | .error e => return .error e .badRequest
  match ← Workers.reconcileJob st.services id version with
  | .ok job => return .json job.toJson
  | .error .notFound => return .error "not found" .notFound
  | .error (.conflict why) => return .error why .conflict
  | .error .unavailable =>
    return .error "GitHub is not configured (DIFF_REVIEWER_GITHUB_TOKEN_FILE)" .serviceUnavailable
  | .error (.github why job) =>
    return .json (.mkObj [("error", why), ("job", job.toJson)]) .badGateway

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

/-- Replace a repository's rubric document. The body is the whole document, `{"version": n,
    "defaultRubric": …, "prTypes": [...]}`, with `version` the one last read (0 when there was
    none); it becomes version `n + 1`, and version `n` stays in the history. -/
private def putRubric (owner name body : String) : IO Reply := do
  if (← Platform.findRepo owner name).isNone then return .error "not found" .notFound
  let j ← match parseBody body with
    | .ok j => pure j
    | .error e => return .error e .badRequest
  let some version := (j.getObjValAs? Nat "version").toOption
    | return .error "the body must carry the rubric's 'version', as last read (0 for none)"
        .badRequest
  let doc ← match Rubric.ofJson j (ignore := RubricVersion.fields) with
    | .ok d => pure d
    | .error e => return .error e .badRequest
  if let .error e := doc.validate then return .error e .badRequest
  let fromProposal ← match j.getObjVal? "fromProposal" with
    | .error _ | .ok .null => pure none
    | .ok (.str id) => pure (some id)
    | .ok _ => return .error "'fromProposal' must be a proposal's id" .badRequest
  let some repo ← Platform.findRepo owner name | return .error "not found" .notFound
  let written ← match fromProposal with
    | some id => Proposal.saveRubricFrom repo id version doc
    | none => Platform.putRubric owner name version doc
  match written with
  | .ok v => return .json v.toJson
  | .error .notFound => return .error "not found" .notFound
  | .error (.conflict why) => return .error why .conflict
  | .error (.invalid why) => return .error why .badRequest

/-! ## Calibration -/

/-- Whether an aggregate's query asks for stale scores too (`?stale=include`). -/
private def staleIn (query : String) : Bool := queryParam query "stale" == some "include"

/-- Whether it asks for derived scores too (`?derived=include`). -/
private def derivedIn (query : String) : Bool := queryParam query "derived" == some "include"

/-- Answer `k` for registered repository `owner/name`, or `404`. -/
private def withRepo (owner name : String) (k : Repo → IO Reply) : IO Reply := do
  match ← Platform.findRepo owner.toLower name.toLower with
  | some repo => k repo
  | none => return .error "not found" .notFound

/-- Queue an import of past reviews. The body is `{"limit": n}`, every field optional: the `n`
    most recently updated closed pull requests (50 unless it says, at most 200). `202` with the
    import; `409` with the import under way while one is, or when the repository names no trusted
    reviewers. -/
private def calibrationImport (st : State) (owner name body : String) : IO Reply :=
  withRepo owner name fun repo => do
    let j ← match parseBody body with
      | .ok j => pure j
      | .error e => return .error e .badRequest
    let limit ← match j.getObjVal? "limit" with
      | .error _ | .ok .null => pure Calibration.defaultImportLimit
      | .ok v => match v.getNat? with
        | .ok n =>
          unless 1 ≤ n && n ≤ Calibration.maxImportLimit do
            return .error s!"'limit' must be between 1 and {Calibration.maxImportLimit}" .badRequest
          pure n
        | .error _ => return .error "'limit' must be a whole number" .badRequest
    if repo.trustedReviewers.isEmpty then
      return .error s!"{repo.slug} names no trusted reviewers; set 'trustedReviewers' first"
        .conflict
    if st.services.github.isNone then
      return .error "GitHub is not configured (DIFF_REVIEWER_GITHUB_TOKEN_FILE)" .serviceUnavailable
    match ← Calibration.requestImport repo limit with
    | .ok i => return .json i.toJson .accepted
    | .error cur =>
      return .json (.mkObj [("error", s!"import {cur.id} of {repo.slug} is under way"),
                            ("import", cur.toJson)]) .conflict

/-- Ask for a calibration run. The body is `{"samples": [id, …]}`, or `{"count": n}` for the `n`
    samples reviewed by the fewest runs so far; at most `Calibration.maxRunSamples` either way.
    `"split"` is `eval` (the default: what calibration measures by) or `pool` (evidence for
    rubric proposals, never aggregated); every sample must be of it. `201` with the run; `429`
    when its jobs would pass the daily cap of calibration jobs. -/
private def calibrationRun (st : State) (owner name body : String) : IO Reply :=
  withRepo owner name fun repo => do
    let j ← match parseBody body with
      | .ok j => pure j
      | .error e => return .error e .badRequest
    let most := Calibration.maxRunSamples
    let split ← match j.getObjVal? "split" with
      | .error _ | .ok .null => pure "eval"
      | .ok (.str "eval") => pure "eval"
      | .ok (.str "pool") => pure "pool"
      | .ok _ => return .error "'split' must be eval or pool" .badRequest
    let ids ← match j.getObjVal? "samples", j.getObjVal? "count" with
      | .ok (.arr xs), .error _ =>
        let some ids := xs.toList.mapM (·.getStr?.toOption)
          | return .error "'samples' must be an array of sample ids" .badRequest
        if ids.eraseDups.length != ids.length then
          return .error "'samples' names a sample twice" .badRequest
        pure ids
      | .error _, .ok v => match v.getNat? with
        | .ok n =>
          unless 1 ≤ n && n ≤ most do
            return .error s!"'count' must be between 1 and {most}" .badRequest
          Calibration.pickSamples repo n split
        | .error _ => return .error "'count' must be a whole number" .badRequest
      | .ok _, .error _ => return .error "'samples' must be an array of sample ids" .badRequest
      | _, _ => return .error "the body names either 'samples' or a 'count'" .badRequest
    if ids.isEmpty then
      return .error s!"{repo.slug} has no {split} samples to review; import some first"
        .badRequest
    if ids.length > most then
      return .error s!"a run reviews at most {most} samples" .badRequest
    match ← Calibration.createRun repo ids st.services.limits.maxCalibrationJobsPerDay split with
    | .ok (run, _) => return .json (← Calibration.runJson run (detail := true)) .created
    | .error .notFound => return .error "not found" .notFound
    | .error (.invalid why) => return .error why .badRequest
    | .error (.conflict why) => return .error why .conflict
    | .error (.capped why) => return .error why .tooManyRequests

/-! ## Rubric proposals -/

/-- The current rubric version of `owner/name`, 0 for none. -/
private def rubricVersionOf (owner name : String) : IO Nat := do
  return ((← Platform.currentRubric owner name).map (·.version)).getD 0

/-- Ask for a rubric proposal. The body is `{}`. `201` with the proposal job; `409` while the
    repository has a live one, `429` past `--max-proposals-per-day`. -/
private def createProposal (st : State) (owner name body : String) : IO Reply :=
  withRepo owner name fun repo => do
    if let .error e := parseBody body then return .error e .badRequest
    match ← Proposal.createJob repo st.services.limits.maxProposalsPerDay with
    | .ok job => return .json job.toJson .created
    | .error (.live why) => return .error why .conflict
    | .error (.capped why) => return .error why .tooManyRequests

private def decideReply (r : Except Proposal.DecideError Json) : Reply :=
  match r with
  | .ok j => .json j
  | .error .notFound => .error "not found" .notFound
  | .error (.conflict why) => .error why .conflict
  | .error (.moved base current why) =>
    .json (.mkObj [("error", why), ("baseVersion", base), ("currentVersion", current)]) .conflict

/-- Accept a proposal. The body is `{"version": n}`, the rubric version the person read. `409`
    with `baseVersion` and `currentVersion` when the rubric has moved since the proposal's base,
    or since it was read. -/
private def acceptProposal (owner name id body : String) : IO Reply :=
  withRepo owner name fun repo => do
    let j ← match parseBody body with
      | .ok j => pure j
      | .error e => return .error e .badRequest
    let some version := (j.getObjValAs? Nat "version").toOption
      | return .error "the body must carry the rubric's 'version', as last read" .badRequest
    let apply ← match j.getObjVal? "applyStyleNotes" with
      | .error _ | .ok .null => pure false
      | .ok (.bool b) => pure b
      | .ok _ => return .error "'applyStyleNotes' must be true or false" .badRequest
    match ← Proposal.accept repo id version apply with
    | .ok (p, v) =>
      return decideReply (.ok (.mkObj [("proposal", ← p.toJson v.version (detail := true)),
                                       ("rubric", v.toJson)]))
    | .error e => return decideReply (.error e)

/-- Cancel proposal job `jobId`: a pending, queued or running one is `failed`, its orchestra run
    cancelled through the proposals' client (`Workers.retire`). The body is `{}`. `409` for a job
    that is not live. -/
private def cancelProposalJob (st : State) (owner name jobId body : String) : IO Reply :=
  withRepo owner name fun repo => do
    if let .error e := parseBody body then return .error e .badRequest
    let some job ← Platform.findJob jobId | return .error "not found" .notFound
    unless job.kind? == some .proposal && job.owner == repo.owner && job.name == repo.name do
      return .error "not found" .notFound
    unless job.status?.any (Proposal.liveStatuses.contains ·) do
      return .error s!"job {jobId} is {job.statusRaw}; only a pending, queued or running proposal \
job is cancelled" .conflict
    Workers.retire st.services job .failed "cancelled by a person"
    let some after ← Platform.findJob jobId | return .error "not found" .notFound
    unless after.status? == some .failed do
      return .error s!"job {jobId} moved on while it was cancelled; it is {after.statusRaw}"
        .conflict
    return .json after.toJson

/-- Reject a proposal. The body is `{}`. -/
private def rejectProposal (owner name id body : String) : IO Reply :=
  withRepo owner name fun repo => do
    if let .error e := parseBody body then return .error e .badRequest
    match ← Proposal.reject repo id with
    | .ok p =>
      return .json (← p.toJson (← rubricVersionOf repo.owner repo.name) (detail := true))
    | .error e => return decideReply (.error e)

/-- Every route under `/api/v1/`, with the methods it answers. `DiffReviewerTest.Server` checks
    this against `docs/openapi.json`, so a route without a spec entry fails the suite. -/
def apiRoutes : Array (String × Array String) :=
  #[("repos",                    #["get"]),
    ("repos/{owner}/{name}",     #["get", "put", "delete"]),
    ("jobs",                     #["get", "post"]),
    ("jobs/{id}",                #["get"]),
    ("jobs/{id}/review",         #["put"]),
    ("jobs/{id}/status",         #["post"]),
    ("jobs/{id}/post",           #["post"]),
    ("jobs/{id}/reconcile",      #["post"]),
    ("jobs/{id}/diff",           #["get"]),
    ("jobs/{id}/revisions",      #["get"]),
    ("repos/{owner}/{name}/rubrics",         #["get", "put"]),
    ("repos/{owner}/{name}/rubrics/history", #["get"]),
    ("repos/{owner}/{name}/calibration/import",       #["get", "post"]),
    ("repos/{owner}/{name}/calibration/import/{id}/cancel", #["post"]),
    ("repos/{owner}/{name}/calibration/samples",      #["get"]),
    ("repos/{owner}/{name}/calibration/samples/{id}", #["get", "delete"]),
    ("repos/{owner}/{name}/calibration/runs",         #["get", "post"]),
    ("repos/{owner}/{name}/calibration/runs/{id}",    #["get"]),
    ("repos/{owner}/{name}/calibration/summary",      #["get"]),
    ("repos/{owner}/{name}/proposals",                #["get", "post"]),
    ("repos/{owner}/{name}/proposals/{id}",           #["get"]),
    ("repos/{owner}/{name}/proposals/{id}/accept",    #["post"]),
    ("repos/{owner}/{name}/proposals/{id}/reject",    #["post"]),
    ("repos/{owner}/{name}/proposals/jobs/{jobId}/cancel", #["post"])]

private def apiRoute (st : State) (r : Req) (segs : List String) : IO Reply := do
  match segs, r.method with
  | ["repos"], .get =>
    return .json (items ((← Platform.listRepos).map (·.toJson)))
  | ["repos", owner, name], .get => withRepo owner name fun repo => return .json repo.toJson
  | ["repos", owner, name], .put => putRepo owner name r.body
  | ["repos", owner, name], .delete =>
    if ← Platform.deleteRepo owner name then return .noContent
    else return .error "not found" .notFound
  | ["jobs"], .get =>
    -- Review jobs unless `kind` says otherwise: calibration jobs are never acted on, and are read
    -- with their runs. A fan-out job carries its sub-runs.
    let kind := queryParam r.query "kind"
    let keep ← match kind with
      | none | some "review" => pure fun (j : Job) => j.isReview
      | some "calibration" => pure fun (j : Job) => j.kind? == some .calibration
      | some "proposal" => pure fun (j : Job) => j.kind? == some .proposal
      | some "all" => pure fun (_ : Job) => true
      | some k =>
        return .error s!"'kind' must be review, calibration, proposal or all, not '{k}'" .badRequest
    let jobs := (← Platform.listJobs).filter keep
    let subs ← Fanout.currentByJob jobs
    return .json (items (jobs.map fun j => jobJson j ((subs.lookup j.id).getD #[])))
  | ["jobs"], .post => createJob r.body
  | ["jobs", id], .get =>
    match ← Platform.findJob id with
    | some j => return .json (jobJson j (← Fanout.current j.id))
    | none   => return .error "not found" .notFound
  | ["jobs", id, "review"], .put => putReview id r.body
  | ["jobs", id, "status"], .post => setStatus st id r.body
  | ["jobs", id, "post"], .post => postJob st id r.body
  | ["jobs", id, "reconcile"], .post => reconcileJob st id r.body
  | ["jobs", id, "diff"], .get =>
    match ← Platform.findJob id with
    | some j => diffReply st j (text := false)
    | none   => return .error "not found" .notFound
  | ["jobs", id, "revisions"], .get =>
    if (← Platform.findJob id).isNone then return .error "not found" .notFound
    page r.query ((← Platform.revisions id).map (·.toJson))
  | ["repos", owner, name, "rubrics"], .get =>
    let (owner, name) := (owner.toLower, name.toLower)
    if (← Platform.findRepo owner name).isNone then return .error "not found" .notFound
    match ← Platform.currentRubric owner name with
    | some v => return .json v.toJson
    | none => return .json (RubricVersion.none owner name)
  | ["repos", owner, name, "rubrics"], .put => putRubric owner.toLower name.toLower r.body
  | ["repos", owner, name, "rubrics", "history"], .get =>
    let (owner, name) := (owner.toLower, name.toLower)
    if (← Platform.findRepo owner name).isNone then return .error "not found" .notFound
    page r.query ((← Platform.rubricHistory owner name).map (·.toJson))
  | ["repos", owner, name, "calibration", "import"], .post =>
    calibrationImport st owner.toLower name.toLower r.body
  | ["repos", owner, name, "calibration", "import"], .get =>
    withRepo owner name fun repo => do
      page r.query ((← Calibration.importsOf repo.owner repo.name).map (·.toJson))
  | ["repos", owner, name, "calibration", "import", id, "cancel"], .post =>
    withRepo owner name fun repo => do
      match ← Calibration.cancelImport repo.owner repo.name id with
      | some (.ok i) => return .json i.toJson
      | some (.error i) =>
        return .json (.mkObj [("error", s!"import {id} is {i.status}; only a queued or running \
import is cancelled"), ("import", i.toJson)]) .conflict
      | none => return .error "not found" .notFound
  | ["repos", owner, name, "calibration", "samples"], .get =>
    withRepo owner name fun repo => do
      let deleted ← match queryParam r.query "deleted" with
        | none | some "exclude" => pure false
        | some "include" => pure true
        | some v => return .error s!"'deleted' must be include or exclude, not '{v}'" .badRequest
      page r.query ((← Calibration.listSamples repo.owner repo.name deleted).map (·.toJson))
  | ["repos", owner, name, "calibration", "samples", id], .get =>
    withRepo owner name fun repo => do
      match ← Calibration.findSample id with
      | some s =>
        if s.owner == repo.owner && s.name == repo.name && s.deletedAt.isNone then
          return .json s.toJson
        return .error "not found" .notFound
      | none => return .error "not found" .notFound
  | ["repos", owner, name, "calibration", "samples", id], .delete =>
    withRepo owner name fun repo => do
      if ← Calibration.deleteSample repo.owner repo.name id then return .noContent
      return .error "not found" .notFound
  | ["repos", owner, name, "calibration", "runs"], .post =>
    calibrationRun st owner.toLower name.toLower r.body
  | ["repos", owner, name, "calibration", "runs"], .get =>
    withRepo owner name fun repo => do
      let runs ← Calibration.runsOf repo.owner repo.name
      page r.query (← runs.mapM (Calibration.runJson · (detail := false) (staleIn r.query)
        (derivedIn r.query)))
  | ["repos", owner, name, "calibration", "runs", id], .get =>
    withRepo owner name fun repo => do
      match ← Calibration.findRun repo.owner repo.name id with
      | some run =>
        return .json (← Calibration.runJson run (detail := true) (staleIn r.query)
          (derivedIn r.query))
      | none => return .error "not found" .notFound
  | ["repos", owner, name, "calibration", "summary"], .get =>
    withRepo owner name fun repo => do
      return .json (← Calibration.summaryJson repo.owner repo.name (staleIn r.query)
        (derivedIn r.query))
  | ["repos", owner, name, "proposals"], .post =>
    createProposal st owner.toLower name.toLower r.body
  | ["repos", owner, name, "proposals"], .get =>
    withRepo owner name fun repo => do
      let current ← rubricVersionOf repo.owner repo.name
      let ps ← Proposal.proposalsOf repo.owner repo.name
      page r.query (← ps.mapM (·.toJson current (detail := false)))
  | ["repos", owner, name, "proposals", id], .get =>
    withRepo owner name fun repo => do
      match ← Proposal.findProposal repo.owner repo.name id with
      | some p =>
        return .json (← p.toJson (← rubricVersionOf repo.owner repo.name) (detail := true))
      | none => return .error "not found" .notFound
  | ["repos", owner, name, "proposals", id, "accept"], .post =>
    acceptProposal owner name id r.body
  | ["repos", owner, name, "proposals", id, "reject"], .post =>
    rejectProposal owner name id r.body
  | ["repos", owner, name, "proposals", "jobs", jobId, "cancel"], .post =>
    cancelProposalJob st owner name jobId r.body
  | ["repos", _, _, "proposals", "jobs", _, "cancel"], _ =>
    return .error "method not allowed" .methodNotAllowed
  | ["repos", _, _, "proposals"], _ | ["repos", _, _, "proposals", _], _
  | ["repos", _, _, "proposals", _, "accept"], _ | ["repos", _, _, "proposals", _, "reject"], _ =>
    return .error "method not allowed" .methodNotAllowed
  | ["repos", _, _, "calibration", "import"], _ | ["repos", _, _, "calibration", "samples"], _
  | ["repos", _, _, "calibration", "import", _, "cancel"], _
  | ["repos", _, _, "calibration", "samples", _], _ | ["repos", _, _, "calibration", "runs"], _
  | ["repos", _, _, "calibration", "runs", _], _ | ["repos", _, _, "calibration", "summary"], _ =>
    return .error "method not allowed" .methodNotAllowed
  | ["repos"], _ | ["repos", _, _], _ | ["jobs"], _ | ["jobs", _], _
  | ["jobs", _, "review"], _ | ["jobs", _, "status"], _ | ["jobs", _, "post"], _
  | ["jobs", _, "reconcile"], _ | ["jobs", _, "revisions"], _
  | ["repos", _, _, "rubrics"], _ | ["repos", _, _, "rubrics", "history"], _
  | ["jobs", _, "diff"], _ =>
    return .error "method not allowed" .methodNotAllowed
  | _, _ => return .error "not found" .notFound

/-! ## The agent API -/

/-- Every route under `/api/agent/v1/`, with the methods it answers; checked against
    `docs/openapi.json` like `apiRoutes`. A review's are under `repos/{owner}/{name}/pulls/{pr}`,
    so that a kleis grant can bind them to the task's repository and pull request; a rubric
    proposal's under `repos/{owner}/{name}/proposals/{jobId}`, of the repository and the job, with
    no pull request — a grant binds them to the task's repository, and only a spec for proposals
    (`rubric-proposer`, not `reviewer`) allows them. -/
def agentRoutes : Array (String × Array String) :=
  #[("repos/{owner}/{name}/pulls/{pr}",        #["get"]),
    ("repos/{owner}/{name}/pulls/{pr}/diff",   #["get"]),
    ("repos/{owner}/{name}/pulls/{pr}/review", #["post"]),
    ("repos/{owner}/{name}/proposals/{jobId}", #["get", "post"])]

/-- The segments of an `/api/agent/v1/…` path, checked as `apiSegments` checks them. -/
def agentSegments (path : String) : Option (List String) :=
  if path.startsWith "/api/agent/v1/" then
    apiSegments ("/api/v1/" ++ (path.drop "/api/agent/v1/".length).toString)
  else none

/-- The job an agent is running for a pull request: the one it names (`X-Diff-Reviewer-Job`, from
    `--job`), which must be a review or calibration job of that pull request, `queued` or
    `running`. A request that names none is refused (`400`), whatever the pull request has
    running: guessing would let the run of a superseded head take over the review of the new one.
    A job of another kind — a rubric proposal — is refused (`404`): it has routes of its own.

    A fan-out job is run by its sub-runs, each named `<job>.<key>` — `<job>.<key>.<n>` for its
    `n`th run (`DiffReviewer.Fanout`): a request naming the job alone is refused (`409`), and one
    naming a sub-run must name a run the platform made of one of its current round (the job's
    attempt's) that has not submitted, failed or been cancelled. The answer is the job, the sub-run
    and the run named.

    kleis binds an agent's requests to its task's pull request, not to its job, so an agent could
    name another active job of the same pull request. Of the active jobs at one commit, only the one
    made last (to the second, as creation times are kept) is answered: an older run of that commit —
    a job asked for again by hand — is refused rather than let take over the newer one, and a run
    never shares its sample with another (`Calibration.createRun`). A job of another commit of the
    same pull request can still be named; closing that needs kleis to bind the header to a fact of
    the task (its orchestra `external_id`), which it does not have. -/
private def activeJob (owner name : String) (pr : Nat) (jobId : Option String) :
    IO (Except Reply (Job × Option (Fanout.SubRun × Nat))) := do
  let some ref := jobId
    | return .error (Reply.error "name the job you run: X-Diff-Reviewer-Job (`--job <id>`, as \
the prompt gives it)" .badRequest)
  -- A sub-run of a fan-out is named `<job>.<key>`, and its `n`th run `<job>.<key>.<n>`.
  let (id, key, attempt) := match ref.splitOn "." with
    | [i, k] => (i, some k, 1)
    | [i, k, n] => (i, some k, n.toNat?.getD 0)
    | i :: k :: _ => (i, some k, 0)
    | _ => (ref, none, 1)
  let active := (← Platform.jobsOfPull owner.toLower name.toLower pr).filter fun j =>
    (j.status? == some .queued || j.status? == some .running) &&
      (j.isReview || j.kind? == some .calibration)
  let some j := active.find? (·.id == id)
    | return .error (Reply.error s!"job {id} is not a review of {owner}/{name}#{pr} being run"
        .notFound)
  -- Made later, to the second: two jobs made in one second are both answered.
  if let some newer := active.find? fun k => k.headSha == j.headSha && k.createdAt > j.createdAt
  then
    return .error (Reply.error s!"job {id} has been superseded by job {newer.id}, a newer review \
of the same commit; it is not run" .conflict)
  let subs ← Fanout.current j.id
  match key with
  | none =>
    if subs.isEmpty then return .ok (j, none)
    return .error (Reply.error s!"job {id} is reviewed in sub-runs, one per category: name yours, \
`--job {id}.<key>`, as your prompt gives it" .conflict)
  | some k =>
    match subs.find? (·.key == k) with
    | some sub =>
      -- A run given up on (`pending`, waiting to run again, or an older run's name) may still
      -- submit; a run the platform never made may not.
      unless 1 ≤ attempt && attempt ≤ sub.attempts do
        return .error (Reply.error s!"sub-run {ref} names no run of the platform's" .notFound)
      if ["pending", "queued", "running"].contains sub.status then
        return .ok (j, some (sub, attempt))
      return .error (Reply.error s!"sub-run {ref} is {sub.status}, not being run" .notFound)
    | none => return .error (Reply.error s!"job {id} has no sub-run '{k}' being run" .notFound)

/-- The repository's current rubric, as its version and document: `none` when it has none, and a
    `409` reply when this build cannot read it — the agent is not to review by a default the
    repository never wrote. -/
private def agentRubric (job : Job) : IO (Except Reply (Option (Nat × Rubric))) := do
  match ← Platform.currentRubric job.owner job.name with
  | none => return .ok none
  | some v => match v.rubric? with
    | .ok d => return .ok (some (v.version, d))
    | .error e => return .error (.error s!"the rubric of {job.owner}/{job.name} (version \
{v.version}) cannot be read by this build ({e}); the review waits for it to be fixed" .conflict)

private def agentJobJson (job : Job) (rubric : Option (Nat × Rubric)) (styleNotes : String)
    (examples : Array Style.Example) : Json :=
  let doc := rubric.map (·.2)
  .mkObj [("jobId", job.id), ("owner", job.owner), ("name", job.name), ("prNumber", job.prNumber),
          ("headSha", (job.headSha.map Json.str).getD .null),
          ("baseSha", (job.baseSha.map Json.str).getD .null),
          ("title", job.title.getD ""), ("body", job.prBody.getD ""),
          ("status", job.statusRaw), ("instructions", Workers.instructionsFor doc styleNotes),
          ("prTypes", .arr (((doc.map (·.prTypes)).getD []).map PrType.toJson).toArray),
          ("rubricVersion", (rubric.map (·.1)).getD 0),
          ("examples", .arr (examples.map (·.toJson)))]

/-- The type `repo` fixes for its reviews (`Repo.prType`), when `doc` still names it: a type the
    rubric has dropped since is no longer fixed, and the agent picks again. -/
private def fixedType (repo : Repo) (doc : Option Rubric) : Option String :=
  repo.prType.filter fun t => (doc.bind (·.findType? t)).isSome

/-- The rubric a fan-out job's sub-runs review by: the version it was fanned out under, which every
    sub-run is shown and checked against, whatever the rubric has become since. -/
private def fanoutRubric (job : Job) : IO (Except Reply (Option (Nat × Rubric))) := do
  let some v := job.rubricVersion | return .ok none
  if v == 0 then return .ok none
  let some rv ← Platform.rubricAt job.owner job.name v | return .ok none
  match rv.rubric? with
  | .ok d => return .ok (some (v, d))
  | .error e => return .error (.error s!"the rubric of {job.owner}/{job.name} (version {v}) \
cannot be read by this build ({e}); the review waits for it to be fixed" .conflict)

/-- What a sub-run is told beside the job: its scope, at the end of its instructions and as
    `subRun`, and the type its review is of (`prType`), which the platform fixed. -/
private def withScope (answer : Json) (job : Job) (scope : Workers.Scope) : Json :=
  let instructions := (answer.getObjValAs? String "instructions").toOption.getD ""
  answer.setObjVal! "instructions" (instructions ++ Workers.scopeInstructions scope)
    |>.setObjVal! "prType" ((job.prType.map Json.str).getD .null)
    |>.setObjVal! "subRun" (.mkObj [
      ("key", scope.sub.key), ("id", scope.ref),
      ("category", ((scope.category.map (·.name)).map Json.str).getD .null),
      ("description", ((scope.category.map (·.description)).map Json.str).getD .null),
      ("others", .arr (scope.others.map Json.str).toArray)])

/-- The first read of a queued job is the run starting: it moves to `running`; so does a sub-run,
    and its job with it. The examples of the repository's review style leave out every sample of
    the job's pull request (`Style.examplesFor`). A sub-run is shown the rubric its job fanned out
    under, and its scope. -/
private def agentShow (job : Job) (named : Option (Fanout.SubRun × Nat)) : IO Reply := do
  let sub := named.map (·.1)
  let rubric ← match ← (if sub.isSome then fanoutRubric job else agentRubric job) with
    | .ok r => pure r
    | .error reply => return reply
  let some repo ← Platform.findRepo job.owner job.name | return .error "not found" .notFound
  let examples ← Style.examplesFor repo job
  let scope ← match named with
    | some (s, n) => pure (((← Workers.scopesOf job (← Fanout.current job.id))
        |>.find? (·.sub.id == s.id)).map fun sc => { sc with ref := s.agentIdFor n })
    | none => pure none
  let fixed := fixedType repo (rubric.map (·.2))
  let answer (j : Job) :=
    let a := agentJobJson j rubric repo.styleNotes examples
    match scope, fixed with
    | some sc, _ => withScope a j sc
    | none, some t =>
      let instructions := (a.getObjValAs? String "instructions").toOption.getD ""
      a.setObjVal! "prType" t |>.setObjVal! "instructions" (instructions ++ s!"\n\n# The pull \
request type\n\nThe repository fixes the type of its reviews: `{t}`. Review by its rubric, and \
submit with `prType` `{t}`.")
    | none, none => a
  if let some (s, n) := named then
    if s.status == "queued" && n == s.attempts then
      let _ ← Fanout.update s.id fun _ cur => do
        unless cur.status == "queued" || cur.status == "running" do throw "moved on"
        return { cur with status := "running" }
  -- The notes version the agent is given, recorded as the rubric's is on submission: what its
  -- score is judged derived by. Written only when it changes, or the job starts.
  let notes := some repo.styleNotesVersion
  if job.status? != some .queued && job.notesVersion == notes then return .json (answer job)
  match ← Platform.updateJob job.id fun j => do
      unless j.status? == some .queued || j.status? == some .running do return j
      let st := if j.status? == some .queued then JobStatus.running.toString else j.statusRaw
      return { j with statusRaw := st, notesVersion := notes }
  with
  | .ok j => return .json (answer j)
  | .error _ => return .error "not found" .notFound

/-- The rubric proposal job `id` of `owner/name` an agent is running: a `proposal` job of that
    repository, `queued` or `running` — or, for a submission (`live` false), in any status, so
    that a second submission is told the job has its proposal (`409`) rather than that it is not
    one. kleis binds the agent's request to its task's repository; this binds it to the job, which
    is the repository's one live proposal job. -/
private def activeProposal (owner name id : String) (live := true) :
    IO (Except Reply (Repo × Job)) := do
  let (owner, name) := (owner.toLower, name.toLower)
  let notRun := Reply.error s!"job {id} is not a rubric proposal of {owner}/{name} being run"
    .notFound
  let some repo ← Platform.findRepo owner name | return .error notRun
  let some job ← Platform.findJob id | return .error notRun
  unless job.kind? == some .proposal && job.owner == owner && job.name == name &&
      (!live || job.status? == some .queued || job.status? == some .running) do
    return .error notRun
  return .ok (repo, job)

/-- What a proposal agent reads; the first read of a queued job moves it to `running`. -/
private def agentProposalShow (repo : Repo) (job : Job) : IO Reply := do
  let job ← if job.status? != some .queued then pure job else
    match ← Platform.updateJob job.id fun j => do
        unless j.status? == some .queued do return j
        return { j with statusRaw := JobStatus.running.toString }
    with
    | .ok j => pure j
    | .error _ => return .error "not found" .notFound
  return .json (← Proposal.contextJson repo job)

/-- A proposal agent's submission: `{"baseVersion", "rubric", "styleNotes", "rationale"}`,
    checked as a rubric `PUT` is, and stored as a pending proposal; the job is then a `draft`. -/
private def agentProposalSubmit (repo : Repo) (job : Job) (body : String) : IO Reply := do
  let j ← match parseBody body with
    | .ok j => pure j
    | .error e => return .error e .badRequest
  let sub ← match Proposal.Submission.ofJson j with
    | .ok s => pure s
    | .error e => return .error e .badRequest
  match ← Proposal.submit repo job.id sub with
  | .ok p =>
    return .json (.mkObj [("proposalId", p.id), ("jobId", job.id), ("status", p.status)])
  | .error .notFound => return .error "not found" .notFound
  | .error (.conflict why) => return .error why .conflict
  | .error (.invalid why) => return .error why .badRequest

/-- A sub-run's partial review, checked as the agent's review is — against the rubric version its
    job fanned out under, with `prType` the job's (or left out) — and, for a category's sub-run,
    with every comment of its category. It is kept on the sub-run, not the job: once every sub-run
    is in, the platform merges them into the job's draft (`Workers.settleFanout`), which may be at
    once. -/
private def subRunSubmit (st : State) (job : Job) (sub : Fanout.SubRun) (attempt : Nat)
    (body : String) : IO Reply := do
  let j ← match parseBody body with
    | .ok j => pure j
    | .error e => return .error e .badRequest
  let some headSha := (j.getObjValAs? String "headSha").toOption
    | return .error "the body must name the 'headSha' that was reviewed" .badRequest
  match j.getObjVal? "prType" with
  | .error _ | .ok .null => if job.prType.isSome then
      return .error s!"'prType' is '{job.prType.getD ""}', the type this review is of" .badRequest
  | .ok (.str t) => unless job.prType == some t do
      return .error s!"'prType' is {(job.prType.map (s!"'{·}'")).getD "null"}, the type this \
review is of, not '{t}'" .badRequest
  | .ok _ => return .error "'prType' must be a string or null" .badRequest
  let review ← match j.getObjVal? "review" >>= Review.ofJson with
    | .ok r => pure r
    | .error e => return .error s!"'review' is not a review: {e}" .badRequest
  if let .error e := review.validate then return .error s!"'review': {e}" .badRequest
  let rubric ← match ← fanoutRubric job with
    | .ok r => pure r
    | .error reply => return reply
  let doc := (rubric.map (·.2)).getD {}
  match sub.category with
  | some c =>
    for (cm, i) in review.comments.zipIdx do
      unless cm.category == some c do
        return .error s!"'review': comment {i + 1}: this review covers the category '{c}' only; \
give every comment the category '{c}'" .badRequest
  | none =>
    if let .error e := review.checkCategories (doc.categoriesFor job.prType) then
      return .error s!"'review': {e}" .badRequest
  if let .ok (_, d) ← Workers.diffOf st.services job then
    if let .error e := Diff.check review d then return .error s!"'review': {e}" .badRequest
  let review ← review.assignIds
  let headSha := headSha.toLower
  let submitted ← Fanout.update sub.id fun j cur => do
    -- Its latest run once it has started; a run given up on whenever it is still unsettled.
    let given := attempt < cur.attempts || cur.status == "pending"
    unless cur.status == "running" ||
        (given && ["pending", "queued", "running"].contains cur.status) do
      throw s!"sub-run {cur.agentIdFor attempt} is {cur.status}, not running; run \
`diff-reviewer agent show` first"
    unless j.status? == some .queued || j.status? == some .running do
      throw s!"job {j.id} is {j.statusRaw}, not being run"
    unless j.headSha == some headSha do
      throw s!"the review is of {headSha}, but job {j.id} is of {j.headSha.getD "no commit"}"
    return { cur with status := "submitted", reviewRaw := some review.toJson.compress
                      error := none }
  let done ← match submitted with
    | .ok d => pure d
    | .error why => return .error why .conflict
  -- A run given up on submitted after all: the run that replaced it is not wanted.
  if attempt < sub.attempts then
    if let (some entry, some orch) := (sub.queueEntry, st.services.orchestraFor job) then
      if let .error e ← orch.cancel entry then
        IO.eprintln s!"diff-reviewer: cancelling entry {entry} of sub-run {done.agentId}: {e}"
  Workers.settleFanout st.services job.id
  let after := (← Platform.findJob job.id).getD job
  return .json (.mkObj [("jobId", job.id), ("subRun", sub.key), ("subRunStatus", "submitted"),
                        ("status", after.statusRaw),
                        ("error", (after.error.map Json.str).getD .null)])

/-- The agent's review. The body is `{"headSha", "prType", "review"}`; the job must be running and
    at that head. `prType` must be a type of the repository's current rubric (or `null` when it
    names none) — the one the repository fixes (`Repo.prType`), when it fixes one — and every
    comment's category one of that type's; the job records the type and the
    rubric's version, comments without an id are given one, and the review is the first revision
    of the job's history. A `direct` repository's review is then posted at once; if that fails the
    job is left `approved` with the reason, for a person to post again, and the submission still
    stands. A calibration job's review is never posted, in any mode: it is scored against its
    sample instead. A sub-run of a fan-out submits its partial review instead
    (`subRunSubmit`). -/
private def agentSubmit (st : State) (job : Job) (sub : Option (Fanout.SubRun × Nat))
    (body : String) : IO Reply := do
  if let some (s, n) := sub then return ← subRunSubmit st job s n body
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
  let rubric ← match ← agentRubric job with
    | .ok r => pure r
    | .error reply => return reply
  let doc := (rubric.map (·.2)).getD {}
  if let .error e := doc.checkPrType prType then return .error e .badRequest
  if let some repo ← Platform.findRepo job.owner job.name then
    if let some t := fixedType repo (rubric.map (·.2)) then
      unless prType == some t do
        return .error s!"'prType' must be '{t}': the repository fixes the type of its reviews"
          .badRequest
  if let .error e := review.checkCategories (doc.categoriesFor prType) then
    return .error s!"'review': {e}" .badRequest
  -- GitHub refuses a comment off the diff; the agent is told now, while it can still fix it.
  if let .ok (_, d) ← Workers.diffOf st.services job then
    if let .error e := Diff.check review d then return .error s!"'review': {e}" .badRequest
  let review ← review.assignIds
  let headSha := headSha.toLower
  let drafted ← Platform.updateJob job.id (revision := Job.revisionBy .agent) fun j => do
    unless j.status? == some .running do
      throw (.conflict s!"job {j.id} is {j.statusRaw}, not running; run `diff-reviewer agent \
show` first")
    unless j.headSha == some headSha do
      throw (.conflict s!"the review is of {headSha}, but job {j.id} is of \
{j.headSha.getD "no commit"}")
    return { j.setReview review with statusRaw := JobStatus.draft.toString, prType, error := none
                                     rubricVersion := some ((rubric.map (·.1)).getD 0) }
  let job ← match drafted with
    | .ok j => pure j
    | .error e => return updateReply (.error e)
  let job ← Workers.afterDraft st.services job
  return .json (.mkObj [("jobId", job.id), ("status", job.statusRaw),
                        ("error", (job.error.map Json.str).getD .null)])

private def agentRoute (st : State) (r : Req) : IO Reply := do
  -- A rubric proposal's routes take the proposals' agent token, and every other the agent token.
  let proposalRoute := match agentSegments r.path with
    | some ("repos" :: _ :: _ :: "proposals" :: _) => true
    | _ => false
  unless agentAuthenticated st r proposalRoute do return .error "unauthorized" .unauthorized
  let some segs := agentSegments r.path | return .error "not found" .notFound
  if r.method == .post && !isJsonContentType (r.header "content-type") then
    return .error "writes must be sent as application/json" .unsupportedMediaType
  let pull (owner name pr : String) (k : Job → Option (Fanout.SubRun × Nat) → IO Reply) :
      IO Reply := do
    let some n := pr.toNat? | return .error "not found" .notFound
    match ← activeJob owner name n (r.header "x-diff-reviewer-job") with
    | .ok (job, sub) => k job sub
    | .error reply => return reply
  let proposal (owner name id : String) (k : Repo → Job → IO Reply) : IO Reply := do
    match ← activeProposal owner name id (live := r.method != .post) with
    | .ok (repo, job) => k repo job
    | .error reply => return reply
  match segs, r.method with
  | ["repos", o, n, "pulls", pr], .get => pull o n pr agentShow
  | ["repos", o, n, "pulls", pr, "diff"], .get =>
    pull o n pr fun job _ => diffReply st job (text := true)
  | ["repos", o, n, "pulls", pr, "review"], .post => pull o n pr (agentSubmit st · · r.body)
  | ["repos", o, n, "proposals", id], .get => proposal o n id agentProposalShow
  | ["repos", o, n, "proposals", id], .post =>
    proposal o n id (agentProposalSubmit · · r.body)
  | ["repos", _, _, "pulls", _], _ | ["repos", _, _, "pulls", _, "diff"], _
  | ["repos", _, _, "pulls", _, "review"], _ | ["repos", _, _, "proposals", _], _ =>
    return .error "method not allowed" .methodNotAllowed
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
    let body := (Json.parse r.body).toOption
    let field (k : String) := body.bind (·.getObjValAs? String k |>.toOption)
    -- The API token signs in too, unlimited: it is 32 characters or more of randomness, which no
    -- rate of guessing reaches, and it is how the operator gets in while password attempts from
    -- everywhere are refused.
    if let some tok := field "token" then
      let ok := match st.cfg.apiToken with
        | some expected => constantTimeEq tok expected
        | none => false
      unless ok do return .error "invalid token" .unauthorized
    else
      let some p := field "password"
        | return .error "expected a JSON body of the form {\"password\": \"…\"} or \
{\"token\": \"…\"}" .badRequest
      let addr := clientAddress st r
      if let some (wait, why) ← loginWait st addr then
        return { Reply.error why .tooManyRequests with
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
      , query := req.line.uri.query.toRawString
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