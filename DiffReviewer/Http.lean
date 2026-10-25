/-!
# HTTP requests, through curl

The platform talks to GitHub and to orchestra, and the agent CLI to the platform, over HTTPS. All
of it goes through `curl` rather than a TLS stack linked into the binary: curl honours
`HTTPS_PROXY` and the CA bundle (`CURL_CA_BUNDLE`, `SSL_CERT_FILE`) from the environment it
inherits, which is exactly how kleis sits in front of every request an orchestra sandbox — or the
platform itself — makes, and it is on every machine the binary runs on.

The whole request, headers and body included, is handed to curl as a config file on its standard
input (`--config -`), never on its command line: a bearer token on `argv` is readable by every
process on the machine.
-/

namespace DiffReviewer.Http

/-- One request. -/
structure Request where
  method  : String := "GET"
  url     : String
  headers : List (String × String) := []
  body    : Option String := none
  /-- Seconds before curl gives up. -/
  timeout : Nat := 60

/-- What the server answered. -/
structure Response where
  status : Nat
  body   : String

/-- `s` as a double-quoted curl config value: curl knows the escapes `\\`, `\"`, `\t`, `\n`, `\r`
    and `\v` there. -/
def quote (s : String) : String :=
  let esc := s.foldl (init := "") fun acc c =>
    match c with
    | '\\' => acc ++ "\\\\"
    | '"'  => acc ++ "\\\""
    | '\n' => acc ++ "\\n"
    | '\r' => acc ++ "\\r"
    | '\t' => acc ++ "\\t"
    | c    => acc.push c
  "\"" ++ esc ++ "\""

/-- The marker that separates the body from the status curl writes after it. -/
private def statusMarker : String := "\n--diff-reviewer-status:"

/-- The config file `request` is sent as. -/
def config (r : Request) : String :=
  let lines := [
    s!"url = {quote r.url}",
    s!"request = {quote r.method}",
    "silent", "show-error",
    s!"max-time = {r.timeout}",
    s!"write-out = {quote (statusMarker ++ "%{http_code}")}"] ++
    r.headers.map (fun (k, v) => s!"header = {quote s!"{k}: {v}"}") ++
    (match r.body with
     | some b => [s!"data-binary = {quote b}"]
     | none   => [])
  "\n".intercalate lines ++ "\n"

/-- Run `request`. An error is a request that got no HTTP answer at all (no route, a refused TLS
    handshake, a timeout); any answer, `4xx` and `5xx` included, is a `Response`. -/
def send (request : Request) : IO (Except String Response) := do
  let out ← try
      IO.Process.output { cmd := "curl", args := #["--config", "-"] } (some (config request))
    catch e => return .error s!"curl could not be run: {e}"
  if out.exitCode != 0 then
    let why := out.stderr.trimAscii.toString
    let why := if why.isEmpty then s!"curl exited {out.exitCode}" else why
    return .error s!"{request.method} {request.url}: {why}"
  let parts := out.stdout.splitOn statusMarker
  let some code := parts.getLast?.bind (·.trimAscii.toString.toNat?)
    | return .error s!"{request.method} {request.url}: curl did not report a status"
  let body := statusMarker.intercalate (parts.dropLast)
  return .ok { status := code, body }

/-- A file's contents, trimmed: how every token the platform reads from disk is stored. -/
def readTokenFile (path : System.FilePath) : IO String := do
  return (← IO.FS.readFile path).trimAscii.toString

end DiffReviewer.Http