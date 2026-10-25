import DiffReviewer
import DiffReviewerTest.Basic

open Lean (Json)
open DiffReviewer
open DiffReviewer.Server

namespace DiffReviewerTest.Server

private def password : String := "correct-horse-battery"

/-- A fresh database under `.lake/test/`, so a test never touches a real one. -/
private def withTempDb (act : IO α) : IO α := do
  let dir : System.FilePath := ".lake" / "test"
  IO.FS.createDirAll dir
  let path := dir / s!"server-{← IO.monoNanosNow}.db"
  Store.setPath path
  try act finally
    try IO.FS.removeFile path catch _ => pure ()

private def req (method : Std.Http.Method) (path : String) (body : String := "")
    (auth : Bool := true) (json : Bool := true) : Req :=
  { method, path, body
  , header := fun n =>
      if n == "authorization" && auth then some s!"Bearer {password}"
      else if n == "content-type" && json then some "application/json"
      else none }

private def bodyJson (r : Reply) : Json :=
  (Json.parse (String.fromUTF8! r.body)).toOption.getD .null

private def checkStatus (r : Reply) (code : Nat) (what : String) : Array String :=
  check (r.status.toCode.toNat == code)
    s!"{what}: expected {code}, got {r.status.toCode} {String.fromUTF8! r.body}"

def theApiNeedsTheSecret : Test := do
  let st ← State.new { password }
  withTempDb do
    let anon ← route st (req .get "/api/v1/repos" (auth := false))
    let wrong ← route st { req .get "/api/v1/repos" (auth := false) with
                           header := fun n => if n == "authorization" then some "Bearer nope"
                                              else none }
    let session ← route st (req .get "/api/session" (auth := false))
    let spec ← route st (req .get "/api/openapi.json" (auth := false))
    return checkStatus anon 401 "no credential"
      ++ checkStatus wrong 401 "a wrong secret"
      ++ checkStatus session 200 "the session check is public"
      ++ checkStatus spec 200 "the spec is public"

def pathsNameOnlyThemselves : Test := do
  return checkEq (apiSegments "/api/v1/repos/acme/widgets") (some ["repos", "acme", "widgets"])
      "a repository path"
    ++ checkEq (apiSegments "/api/v1/repos/../jobs") none "a parent segment"
    ++ checkEq (apiSegments "/api/v1/repos/%2e%2e/x") none "an encoded parent segment"
    ++ checkEq (staticCandidate "site" "/../etc/passwd") none "a static path escaping the site"
    ++ checkEq (staticCandidate "site" "/assets/a.js") (some ("site" / "assets" / "a.js"))
      "a static file"

private def field (r : Reply) (k : String) : Option String :=
  ((bodyJson r).getObjValAs? String k).toOption

private def versionOf (r : Reply) : Nat :=
  ((bodyJson r).getObjValAs? Nat "version").toOption.getD 0

private def reviewBody (version : Nat) (review : String) : String :=
  s!"\{\"version\": {version}, \"review\": {review}}"

private def fine : String := "{\"decision\": \"comment\", \"body\": \"Fine.\", \"comments\": []}"

private def statusBody (status : String) (version : Nat) : String :=
  s!"\{\"status\": \"{status}\", \"version\": {version}}"

/-- A registered repository and a new job on it; answers the job reply. -/
private def newJob (st : State) : IO Reply := do
  let _ ← route st (req .put "/api/v1/repos/Acme/Widgets" "{\"mode\": \"staged\"}")
  route st (req .post "/api/v1/jobs"
    "{\"owner\": \"acme\", \"name\": \"widgets\", \"prNumber\": 7, \"headSha\": \"ABCDEF1\"}")

def aReviewIsDraftedAndApproved : Test := do
  let st ← State.new { password }
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
  let st ← State.new { password }
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
  let st ← State.new { password }
  withTempDb do
    let job ← newJob st
    let id := (field job "id").getD ""
    let some j ← Platform.findJob id | return #["the job was not stored"]
    let odd := "{\"decision\":\"block\",\"body\":\"\",\"comments\":[]}"
    Store.run <| HasModel.save
      ({ id, owner := j.owner, name := j.name, pr_number := j.prNumber, head_sha := j.headSha
       , status := "escalated", queue_entry := none, review := some odd, version := 1
       , created_at := j.createdAt, updated_at := j.updatedAt } : Store.JobRow)
    let read ← route st (req .get s!"/api/v1/jobs/{id}")
    let write ← route st (req .post s!"/api/v1/jobs/{id}/status" (statusBody "rejected" 1))
    let some after ← Platform.findJob id | return #["the job disappeared"]
    return checkStatus read 200 "reading it"
      ++ checkEq (field read "status") (some "escalated") "the unknown status, as stored"
      ++ check (field read "reviewError" |>.isSome) "the review is reported as unreadable"
      ++ checkStatus write 409 "a write to it"
      ++ checkEq after.reviewRaw (some odd) "the stored review, untouched"
      ++ checkEq after.statusRaw "escalated" "the stored status, untouched"

def editsFollowTheState : Test := do
  let st ← State.new { password }
  withTempDb do
    let job ← newJob st
    let id := (field job "id").getD ""
    let drafted ← route st (req .put s!"/api/v1/jobs/{id}/review" (reviewBody 1 fine))
    let stale ← route st (req .post s!"/api/v1/jobs/{id}/status"
      (statusBody "stale" (versionOf drafted)))
    let edit ← route st (req .put s!"/api/v1/jobs/{id}/review" (reviewBody (versionOf stale) fine))
    return checkStatus stale 200 "marking the draft stale"
      ++ checkStatus edit 409 "editing a stale review"

/-- Every route `apiRoutes` names is in `docs/openapi.json` with exactly its methods, and the spec
    documents no route that is not served. -/
def theSpecDescribesTheRoutes : Test := do
  let some paths := (Json.parse openApiSpec).toOption.bind (·.getObjVal? "paths" |>.toOption)
    | return #["docs/openapi.json has no 'paths'"]
  let some documented := paths.getObj?.toOption | return #["'paths' is not an object"]
  let mut failures := #[]
  for (kind, methods) in apiRoutes do
    let key := s!"/api/v1/{kind}"
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
    if key.startsWith "/api/v1/" then
      unless apiRoutes.any (fun (k, _) => s!"/api/v1/{k}" == key) do
        failures := failures.push s!"the spec documents {key}, which is not served"
  return failures

def all : List (String × Test) :=
  [("theApiNeedsTheSecret", theApiNeedsTheSecret),
   ("pathsNameOnlyThemselves", pathsNameOnlyThemselves),
   ("aReviewIsDraftedAndApproved", aReviewIsDraftedAndApproved),
   ("inputsAreChecked", inputsAreChecked),
   ("whatThisBuildCannotReadIsKept", whatThisBuildCannotReadIsKept),
   ("editsFollowTheState", editsFollowTheState),
   ("theSpecDescribesTheRoutes", theSpecDescribesTheRoutes)]

end DiffReviewerTest.Server