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

def aReviewMovesFromDraftToPosted : Test := do
  let st ← State.new { password }
  withTempDb do
    let created ← route st (req .put "/api/v1/repos/acme/widgets" "{\"mode\": \"staged\"}")
    let again ← route st (req .put "/api/v1/repos/acme/widgets" "{}")
    let missing ← route st (req .post "/api/v1/jobs"
      "{\"owner\": \"acme\", \"name\": \"other\", \"prNumber\": 1}")
    let job ← route st (req .post "/api/v1/jobs"
      "{\"owner\": \"acme\", \"name\": \"widgets\", \"prNumber\": 7, \"headSha\": \"abc\"}")
    let id := ((bodyJson job).getObjValAs? String "id").toOption.getD ""
    let early ← route st (req .post s!"/api/v1/jobs/{id}/status" "{\"status\": \"approved\"}")
    let review ← route st (req .put s!"/api/v1/jobs/{id}/review"
      "{\"decision\": \"comment\", \"body\": \"Fine.\", \"comments\": []}")
    let notReview ← route st (req .put s!"/api/v1/jobs/{id}/review" "{\"decision\": \"maybe\"}")
    let approved ← route st (req .post s!"/api/v1/jobs/{id}/status" "{\"status\": \"approved\"}")
    let posted ← route st (req .post s!"/api/v1/jobs/{id}/status" "{\"status\": \"posted\"}")
    let edit ← route st (req .put s!"/api/v1/jobs/{id}/review"
      "{\"decision\": \"approve\", \"body\": \"\", \"comments\": []}")
    let form ← route st (req .post s!"/api/v1/jobs/{id}/status" "status=draft" (json := false))
    let listed ← route st (req .get "/api/v1/jobs")
    let count := ((bodyJson listed).getObjValAs? (Array Json) "items").toOption.map (·.size)
    return checkStatus created 201 "a new repository"
      ++ checkStatus again 200 "the same repository again"
      ++ checkStatus missing 404 "a job for a repository nobody registered"
      ++ checkStatus job 201 "a new job"
      ++ checkStatus early 409 "approving before there is a draft"
      ++ checkStatus review 200 "the draft"
      ++ checkEq ((bodyJson review).getObjValAs? String "status").toOption (some "draft")
        "the job after its review"
      ++ checkStatus notReview 400 "a body that is not a review"
      ++ checkStatus approved 200 "the approval"
      ++ checkStatus posted 200 "the posting"
      ++ checkStatus edit 409 "editing a posted review"
      ++ checkStatus form 415 "a form post"
      ++ checkEq count (some 1) "the job list"

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
   ("aReviewMovesFromDraftToPosted", aReviewMovesFromDraftToPosted),
   ("theSpecDescribesTheRoutes", theSpecDescribesTheRoutes)]

end DiffReviewerTest.Server