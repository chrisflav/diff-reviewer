import DiffReviewer
import DiffReviewerTest.Basic

open Lean (Json)
open DiffReviewer
open DiffReviewer.Server

namespace DiffReviewerTest.Server

def password : String := "correct-horse-battery"

def apiToken : String := "api-0123456789abcdef0123456789abcdef"

def agentToken : String := "agent-0123456789abcdef0123456789abcdef"

def cfg : Config := { password, apiToken := some apiToken, agentToken := some agentToken }

/-- A request with `token` as its bearer, the API token unless said otherwise. -/
def req (method : Std.Http.Method) (path : String) (body : String := "")
    (auth : Bool := true) (json : Bool := true) (token : String := apiToken) : Req :=
  { method, path, body
  , header := fun n =>
      if n == "authorization" && auth then some s!"Bearer {token}"
      else if n == "content-type" && json then some "application/json"
      else none }

def bodyJson (r : Reply) : Json :=
  (Json.parse (String.fromUTF8! r.body)).toOption.getD .null

def checkStatus (r : Reply) (code : Nat) (what : String) : Array String :=
  check (r.status.toCode.toNat == code)
    s!"{what}: expected {code}, got {r.status.toCode} {String.fromUTF8! r.body}"

private def loginBody (p : String) : String := s!"\{\"password\": \"{p}\"}"

/-- The session cookie a login reply sets. -/
private def cookieOf (r : Reply) : Option String :=
  (r.headers.lookup "Set-Cookie").bind fun c => ((c.splitOn ";").head?)

private def withCookie (r : Req) (cookie : String) : Req :=
  { r with header := fun n => if n == "cookie" then some cookie else r.header n }

/-- Three credentials, none standing in for another: the password only logs in, the API token
    reaches `/api/v1/` and nothing else, the agent token `/api/agent/v1/` and nothing else. -/
def theApiNeedsTheSecret : Test := do
  let st ← State.new cfg
  withTempDb do
    let anon ← route st (req .get "/api/v1/repos" (auth := false))
    let wrong ← route st (req .get "/api/v1/repos" (token := "nope"))
    let byToken ← route st (req .get "/api/v1/repos")
    let byPassword ← route st (req .get "/api/v1/repos" (token := password))
    let byAgent ← route st (req .get "/api/v1/repos" (token := agentToken))
    let agentPath := "/api/agent/v1/repos/acme/widgets/pulls/7"
    let agentByApi ← route st (req .get agentPath)
    let agentByPassword ← route st (req .get agentPath (token := password))
    let agentByAgent ← route st (req .get agentPath (token := agentToken))
    let login ← route st (req .post "/api/login" (loginBody password) (auth := false))
    let cookie := (cookieOf login).getD ""
    let bySession ← route st (withCookie (req .get "/api/v1/repos" (auth := false)) cookie)
    let agentBySession ← route st (withCookie (req .get agentPath (auth := false)) cookie)
    let session ← route st (req .get "/api/session" (auth := false))
    let spec ← route st (req .get "/api/openapi.json" (auth := false))
    let noAgent ← State.new { cfg with agentToken := none }
    let agentUnset ← route noAgent (req .get agentPath (token := agentToken))
    return checkStatus anon 401 "no credential"
      ++ checkStatus wrong 401 "a wrong secret"
      ++ checkStatus byToken 200 "the API token"
      ++ checkStatus byPassword 401 "the password as a bearer"
      ++ checkStatus byAgent 401 "the agent token on /api/v1"
      ++ checkStatus agentByApi 401 "the API token on the agent API"
      ++ checkStatus agentByPassword 401 "the password on the agent API"
      ++ checkStatus agentByAgent 404 "the agent token, for a pull request with no review running"
      ++ checkStatus login 200 "logging in"
      ++ checkStatus bySession 200 "the session"
      ++ checkStatus agentBySession 401 "the session on the agent API"
      ++ checkStatus session 200 "the session check is public"
      ++ checkStatus spec 200 "the spec is public"
      ++ checkStatus agentUnset 401 "the agent API, with no agent token configured"

/-- Past five failures in the window every attempt is refused, the right password too, until the
    delay has passed; the delay doubles with each further failure. -/
def loginsAreRateLimited : Test := do
  let now ← IO.mkRef (1000000 : Int)
  let st ← State.new cfg (clock := now.get)
  withTempDb do
    let mut failures := #[]
    for i in [0:5] do
      let r ← route st (req .post "/api/login" (loginBody "wrong") (auth := false))
      failures := failures ++ checkStatus r 401 s!"wrong password {i + 1}"
    let locked ← route st (req .post "/api/login" (loginBody password) (auth := false))
    now.modify (· + loginBackoff 5 + 1)
    let wrongAgain ← route st (req .post "/api/login" (loginBody "wrong") (auth := false))
    let lockedLonger ← route st (req .post "/api/login" (loginBody password) (auth := false))
    now.modify (· + loginBackoff 6 + 1)
    let ok ← route st (req .post "/api/login" (loginBody password) (auth := false))
    let afterOk ← route st (req .post "/api/login" (loginBody "wrong") (auth := false))
    return failures
      ++ checkStatus locked 429 "the right password while refused"
      ++ check (locked.headers.lookup "Retry-After" |>.isSome) "a Retry-After"
      ++ checkStatus wrongAgain 401 "a sixth wrong password, after the delay"
      ++ checkStatus lockedLonger 429 "refused again, for longer"
      ++ check (loginBackoff 6 == 2 * loginBackoff 5) "the delay doubles"
      ++ checkStatus ok 200 "the right password after the delay"
      ++ checkStatus afterOk 401 "a success clears the count"

def credentialsAreChecked : Test := do
  return check (cfg.check matches .ok ()) "the suite's own configuration"
    ++ check (({ cfg with password := "short" } : Config).check matches .error _) "a short password"
    ++ check (({ cfg with apiToken := some "short" } : Config).check matches .error _)
      "a short token"
    ++ check (({ cfg with agentToken := some apiToken } : Config).check matches .error _)
      "one token for both"
    ++ check (({ cfg with password := apiToken } : Config).check matches .error _)
      "the password as a token"

def pathsNameOnlyThemselves : Test := do
  return checkEq (apiSegments "/api/v1/repos/acme/widgets") (some ["repos", "acme", "widgets"])
      "a repository path"
    ++ checkEq (apiSegments "/api/v1/repos/../jobs") none "a parent segment"
    ++ checkEq (apiSegments "/api/v1/repos/%2e%2e/x") none "an encoded parent segment"
    ++ checkEq (staticCandidate "site" "/../etc/passwd") none "a static path escaping the site"
    ++ checkEq (staticCandidate "site" "/assets/a.js") (some ("site" / "assets" / "a.js"))
      "a static file"

def field (r : Reply) (k : String) : Option String :=
  ((bodyJson r).getObjValAs? String k).toOption

def versionOf (r : Reply) : Nat :=
  ((bodyJson r).getObjValAs? Nat "version").toOption.getD 0

def reviewBody (version : Nat) (review : String) : String :=
  s!"\{\"version\": {version}, \"review\": {review}}"

def fine : String := "{\"decision\": \"comment\", \"body\": \"Fine.\", \"comments\": []}"

def statusBody (status : String) (version : Nat) : String :=
  s!"\{\"status\": \"{status}\", \"version\": {version}}"

/-- A registered repository and a new job on it; answers the job reply. -/
def newJob (st : State) : IO Reply := do
  let _ ← route st (req .put "/api/v1/repos/Acme/Widgets" "{\"mode\": \"staged\"}")
  route st (req .post "/api/v1/jobs"
    "{\"owner\": \"acme\", \"name\": \"widgets\", \"prNumber\": 7, \"headSha\": \"ABCDEF1\"}")

def aReviewIsDraftedAndApproved : Test := do
  let st ← State.new cfg
  withTempDb do
    let job ← newJob st
    let again ← route st (req .put "/api/v1/repos/acme/widgets" "{}")
    let missing ← route st (req .post "/api/v1/jobs"
      "{\"owner\": \"acme\", \"name\": \"other\", \"prNumber\": 1}")
    let id := (field job "id").getD ""
    let early ← route st (req .post s!"/api/v1/jobs/{id}/status" (statusBody "approved" 1))
    let review ← route st (req .put s!"/api/v1/jobs/{id}/review" (reviewBody 1 fine))
    let stale ← route st (req .put s!"/api/v1/jobs/{id}/review" (reviewBody 1 fine))
    let approved ← route st (req .post s!"/api/v1/jobs/{id}/status"
      (statusBody "approved" (versionOf review)))
    let posted ← route st (req .post s!"/api/v1/jobs/{id}/status"
      (statusBody "posted" (versionOf approved)))
    let form ← route st (req .post s!"/api/v1/jobs/{id}/status" "status=draft" (json := false))
    return checkStatus again 200 "the same repository, in other case"
      ++ checkStatus missing 404 "a job for a repository nobody registered"
      ++ checkStatus job 201 "a new job"
      ++ checkEq (field job "headSha") (some "abcdef1") "the commit, in lower case"
      ++ checkStatus early 409 "approving before there is a draft"
      ++ checkStatus review 200 "the draft"
      ++ checkEq (field review "status") (some "draft") "the job after its review"
      ++ checkStatus stale 409 "a write naming a version that is no longer current"
      ++ checkStatus approved 200 "the approval"
      ++ checkStatus posted 409 "posting is the platform's, not a request's"
      ++ checkStatus form 415 "a form post"

def inputsAreChecked : Test := do
  let st ← State.new cfg
  withTempDb do
    let job ← newJob st
    let id := (field job "id").getD ""
    let huge ← route st (req .post "/api/v1/jobs"
      "{\"owner\": \"acme\", \"name\": \"widgets\", \"prNumber\": 99999999999999999999}")
    let zero ← route st (req .post "/api/v1/jobs"
      "{\"owner\": \"acme\", \"name\": \"widgets\", \"prNumber\": 0}")
    let sha ← route st (req .post "/api/v1/jobs"
      "{\"owner\": \"acme\", \"name\": \"widgets\", \"prNumber\": 1, \"headSha\": \"main\"}")
    let line0 ← route st (req .put s!"/api/v1/jobs/{id}/review" (reviewBody 1
      "{\"decision\": \"comment\", \"body\": \"\", \"comments\": [{\"file\": \"A.lean\", \"start_line\": 0, \"end_line\": 0, \"body\": \"x\"}]}"))
    let backwards ← route st (req .put s!"/api/v1/jobs/{id}/review" (reviewBody 1
      "{\"decision\": \"comment\", \"body\": \"\", \"comments\": [{\"file\": \"A.lean\", \"start_line\": 5, \"end_line\": 2, \"body\": \"x\"}]}"))
    let listed ← route st (req .get "/api/v1/jobs")
    return checkStatus huge 400 "a pull request number past 2^31"
      ++ checkStatus zero 400 "pull request 0"
      ++ checkStatus sha 400 "a head that is not a commit id"
      ++ checkStatus line0 400 "a comment on line 0"
      ++ checkStatus backwards 400 "a comment ending before it starts"
      ++ checkStatus listed 200 "the job list after all that"

/-- A stored status or review this build does not understand is left exactly as it is: shown,
    refused for writes, never replaced by a default. -/
def whatThisBuildCannotReadIsKept : Test := do
  let st ← State.new cfg
  withTempDb do
    let job ← newJob st
    let id := (field job "id").getD ""
    let some j ← Platform.findJob id | return #["the job was not stored"]
    let odd := "{\"decision\":\"block\",\"body\":\"\",\"comments\":[]}"
    Store.run <| HasModel.save
      ({ id, owner := j.owner, name := j.name, pr_number := j.prNumber, head_sha := j.headSha
       , status := "escalated", queue_entry := none, review := some odd, version := 1
       , created_at := j.createdAt, updated_at := j.updatedAt, base_sha := none, title := none
       , pr_body := none, error := none, pr_type := none, attempts := none } : Store.JobRow)
    let read ← route st (req .get s!"/api/v1/jobs/{id}")
    let write ← route st (req .post s!"/api/v1/jobs/{id}/status" (statusBody "rejected" 1))
    let edit ← route st (req .put s!"/api/v1/jobs/{id}/review" (reviewBody 1 fine))
    let some after ← Platform.findJob id | return #["the job disappeared"]
    return checkStatus read 200 "reading it"
      ++ checkEq (field read "status") (some "escalated") "the unknown status, as stored"
      ++ check (field read "reviewError" |>.isSome) "the review is reported as unreadable"
      ++ checkStatus write 409 "a write to it"
      ++ checkStatus edit 409 "an edit of it"
      ++ checkEq after.reviewRaw (some odd) "the stored review, untouched"
      ++ checkEq after.statusRaw "escalated" "the stored status, untouched"

def editsFollowTheState : Test := do
  let st ← State.new cfg
  withTempDb do
    let job ← newJob st
    let id := (field job "id").getD ""
    let drafted ← route st (req .put s!"/api/v1/jobs/{id}/review" (reviewBody 1 fine))
    let stale ← route st (req .post s!"/api/v1/jobs/{id}/status"
      (statusBody "stale" (versionOf drafted)))
    let edit ← route st (req .put s!"/api/v1/jobs/{id}/review" (reviewBody (versionOf stale) fine))
    return checkStatus stale 200 "marking the draft stale"
      ++ checkStatus edit 409 "editing a stale review"

/-- Every route `apiRoutes` and `agentRoutes` name is in `docs/openapi.json` with exactly its
    methods, and the spec documents no route under either prefix that is not served. -/
def theSpecDescribesTheRoutes : Test := do
  let some paths := (Json.parse openApiSpec).toOption.bind (·.getObjVal? "paths" |>.toOption)
    | return #["docs/openapi.json has no 'paths'"]
  let some documented := paths.getObj?.toOption | return #["'paths' is not an object"]
  let mut failures := #[]
  let served := apiRoutes.map (fun (k, ms) => (s!"/api/v1/{k}", ms)) ++
    agentRoutes.map (fun (k, ms) => (s!"/api/agent/v1/{k}", ms))
  for (key, methods) in served do
    match paths.getObjVal? key with
    | .error _ => failures := failures.push s!"{key} is served but not documented"
    | .ok entry =>
      let specMethods := (entry.getObj?.toOption.map (·.toList.map (·.1))).getD []
      for m in methods do
        unless specMethods.contains m do
          failures := failures.push s!"{key} answers {m} but the spec does not say so"
      for m in specMethods do
        unless methods.contains m || m == "parameters" do
          failures := failures.push s!"the spec documents {m} {key}, which is not served"
  for (key, _) in documented.toList do
    if key.startsWith "/api/v1/" || key.startsWith "/api/agent/v1/" then
      unless served.any (·.1 == key) do
        failures := failures.push s!"the spec documents {key}, which is not served"
  return failures

def all : List (String × Test) :=
  [("theApiNeedsTheSecret", theApiNeedsTheSecret),
   ("loginsAreRateLimited", loginsAreRateLimited),
   ("credentialsAreChecked", credentialsAreChecked),
   ("pathsNameOnlyThemselves", pathsNameOnlyThemselves),
   ("aReviewIsDraftedAndApproved", aReviewIsDraftedAndApproved),
   ("inputsAreChecked", inputsAreChecked),
   ("whatThisBuildCannotReadIsKept", whatThisBuildCannotReadIsKept),
   ("editsFollowTheState", editsFollowTheState),
   ("theSpecDescribesTheRoutes", theSpecDescribesTheRoutes)]

end DiffReviewerTest.Server