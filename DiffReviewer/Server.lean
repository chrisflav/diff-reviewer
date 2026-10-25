import Lean.Data.Json
import Std.Http
import Std.Net
import DiffReviewer.Platform

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
  * everything else — the front-end built into `web/dist` (`--site`), with a single-page-app
    fallback.

Routing is a pure-ish function from a `Req` to a `Reply` (`route`), so that the suite can drive
it without a socket; `serve` adapts `Std.Http` to it and back.

## Authentication

One person runs the platform — the one whose name approved reviews are posted under — so there
is one shared secret, presented two ways, as on orchestra's dashboard: a browser exchanges it at
`POST /api/login` for an `HttpOnly`, `SameSite=Strict` session cookie, and a script sends
`Authorization: Bearer <secret>`. Every route under `/api/v1/` needs one of them. Writes must be
`application/json`, which with `SameSite=Strict` is what keeps a cross-site form from making one.
Agents will reach the platform through kleis with credentials of their own; that is a later
milestone.
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
  /-- The shared secret. -/
  password : String
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

structure State where
  cfg : Config
  /-- Session ids with their expiry, in epoch seconds. In memory: a restart logs everyone out. -/
  sessions : IO.Ref (Array (String × Int))

def State.new (cfg : Config) : IO State := do
  return { cfg, sessions := ← IO.mkRef #[] }

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

private def nowEpoch : IO Int :=
  return (← Std.Time.Timestamp.now).toSecondsSinceUnixEpoch.val

private def issueSession (st : State) : IO String := do
  let id ← randomHex 32
  let now ← nowEpoch
  st.sessions.modify fun ss =>
    (ss.filter (fun (_, exp) => exp > now)).push (id, now + st.cfg.sessionTtlSeconds)
  return id

private def sessionValid (st : State) (id : String) : IO Bool := do
  let now ← nowEpoch
  return (← st.sessions.get).any fun (sid, exp) => exp > now && constantTimeEq sid id

def cookieValue (raw : String) (name : String) : Option String :=
  (raw.splitOn ";").findSome? fun part =>
    match (part.trimAscii.toString.splitOn "=") with
    | k :: rest => if k == name then some ("=".intercalate rest) else none
    | [] => none

private def cookieHeader (st : State) (value : String) (maxAge : Nat) : String :=
  let attrs := s!"{sessionCookieName}={value}; HttpOnly; SameSite=Strict; Path=/; Max-Age={maxAge}"
  if st.cfg.secureCookie then attrs ++ "; Secure" else attrs

/-- Whether a request carries the secret, or a session obtained with it. -/
def authenticated (st : State) (r : Req) : IO Bool := do
  if let some auth := r.header "authorization" then
    if auth.startsWith "Bearer " then
      if constantTimeEq (auth.drop "Bearer ".length).trimAscii.toString st.cfg.password then
        return true
  if let some sid := (r.header "cookie").bind (cookieValue · sessionCookieName) then
    return ← sessionValid st sid
  return false

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
  let existed ← Platform.putRepo owner name mode
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
        return .error s!"'headSha' must be a commit id (7 to 64 hex digits), not '{sha}'" .badRequest
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
    unless st.personCanEdit do
      throw (.conflict s!"job {id} is {st.toString}; its review is not edited now")
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
    | return .error "'status' must be approved, rejected, stale or draft" .badRequest
  updateReply <$> Platform.updateJob id fun job => do
    let st ← current job version
    unless st.personCanMove to do
      throw (.conflict s!"job {id} is {st.toString} and cannot be made {to.toString} from here")
    if to == .approved then
      match job.review? with
      | some (.ok _) => pure ()
      | some (.error e) => throw (.conflict s!"job {id}'s review does not parse ({e})")
      | none => throw (.conflict s!"job {id} has no review to approve")
    return { job with statusRaw := to.toString }

/-- Every route under `/api/v1/`, with the methods it answers. `DiffReviewerTest.Server` checks
    this against `docs/openapi.json`, so a route without a spec entry fails the suite. -/
def apiRoutes : Array (String × Array String) :=
  #[("repos",                    #["get"]),
    ("repos/{owner}/{name}",     #["put", "delete"]),
    ("jobs",                     #["get", "post"]),
    ("jobs/{id}",                #["get"]),
    ("jobs/{id}/review",         #["put"]),
    ("jobs/{id}/status",         #["post"])]

private def apiRoute (r : Req) (segs : List String) : IO Reply := do
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
  | ["repos"], _ | ["repos", _, _], _ | ["jobs"], _ | ["jobs", _], _
  | ["jobs", _, "review"], _ | ["jobs", _, "status"], _ =>
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
    unless constantTimeEq p st.cfg.password do return .error "invalid password" .unauthorized
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
  try apiRoute r segs
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
    let r : Req :=
      { method := req.line.method, path := toString req.line.uri.path, body
      , header := fun n => (req.line.headers.get? (Header.Name.ofString! n)).map toString }
    toResponse (← route s.st r)
  onFailure _ _ := pure ()

private def httpConfig : Std.Http.Config where
  maxRequests := 0
  maxBodySize := maxBodyBytes.toNat
  maxUriLength := 4096

/-- Start serving. Returns the bound port and a function that stops the server. -/
def serve (cfg : Config) : IO (UInt16 × IO Unit) := do
  let some hostAddr := IPv4Addr.ofString cfg.host
    | throw (.userError s!"'{cfg.host}' is not an IPv4 address")
  let st ← State.new cfg
  let server ← Async.block do
    Std.Http.Server.serve (SocketAddress.v4 { addr := hostAddr, port := cfg.port })
      (Server.mk st) httpConfig
  let boundPort := match server.localAddr with
    | some (.v4 a) => a.port
    | some (.v6 a) => a.port
    | none         => cfg.port
  return (boundPort, Async.block server.shutdownAndWait)

end DiffReviewer.Server