/-!
# HTTP requests, through curl

The platform talks to GitHub and to orchestra, and the agent CLI to the platform, over HTTPS. All
of it goes through `curl` rather than a TLS stack linked into the binary: curl honours
`HTTPS_PROXY` and the CA bundle (`CURL_CA_BUNDLE`, `SSL_CERT_FILE`) from the environment it
inherits, which is exactly how kleis sits in front of every request an orchestra sandbox — or the
platform itself — makes, and it is on every machine the binary runs on.

The request's options and headers are handed to curl as a config file on its standard input
(`--config -`), never on its command line: a bearer token on `argv` is readable by every process on
the machine. `-q` comes first, so that no `~/.curlrc` adds to it. A body goes through a temporary
file (`data-binary = @file`) rather than into the config. A header value holding a line break is
refused, and so is plain `http` to anything but loopback: nothing the platform sends may be read
on the way.
-/

namespace DiffReviewer.Http

/-- One request. -/
structure Request where
  method   : String := "GET"
  url      : String
  headers  : List (String × String) := []
  body     : Option String := none
  /-- Seconds before curl gives up. -/
  timeout  : Nat := 60
  /-- Refuse an answer larger than this many bytes (curl exits 63). -/
  maxBytes : Option Nat := none
  /-- A host reached directly, never through `HTTPS_PROXY`. -/
  noproxy  : Option String := none

/-- What the server answered. -/
structure Response where
  status : Nat
  body   : String

/-- Why a request has no `Response`. -/
inductive Failure where
  /-- Refused before anything was sent: the request was not one to make. -/
  | refused (why : String)
  /-- Sent, or perhaps sent, without an answer: no route, a refused handshake, a timeout. What the
      server did with it is unknown. -/
  | noAnswer (why : String) (exitCode : Nat)

def Failure.message : Failure → String
  | .refused why | .noAnswer why _ => why

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

/-- The host of an `http(s)://host[:port]/…` URL. -/
def hostOf (url : String) : String :=
  let rest := match url.splitOn "://" with
    | [_, r] => r
    | _ => url
  let authority := (rest.splitOn "/").headD ""
  if authority.startsWith "[" then ((authority.splitOn "]").headD "").drop 1 |>.toString
  else (authority.splitOn ":").headD ""

/-- Whether `url` may be requested: `https`, or `http` to loopback. -/
def allowedUrl (url : String) : Bool :=
  url.startsWith "https://" ||
    (url.startsWith "http://" && ["127.0.0.1", "localhost", "::1"].contains (hostOf url))

/-- The marker that separates the body from the status curl writes after it. -/
private def statusMarker : String := "\n--diff-reviewer-status:"

/-- The config file `request` is sent as, its body (if any) read from `bodyFile`. -/
def config (r : Request) (bodyFile : Option System.FilePath := none) : String :=
  let lines := [
    s!"url = {quote r.url}",
    s!"request = {quote r.method}",
    "silent", "show-error",
    s!"max-time = {r.timeout}",
    s!"write-out = {quote (statusMarker ++ "%{http_code}")}"] ++
    (r.maxBytes.map (s!"max-filesize = {·}")).toList ++
    (r.noproxy.map (s!"noproxy = {quote ·}")).toList ++
    r.headers.map (fun (k, v) => s!"header = {quote s!"{k}: {v}"}") ++
    (bodyFile.map (fun f => s!"data-binary = {quote ("@" ++ f.toString)}")).toList
  "\n".intercalate lines ++ "\n"

/-- Why `r` is not a request to make, if it is not. -/
def check (r : Request) : Option String :=
  if !allowedUrl r.url then some s!"{r.url}: only https (or http to loopback) is used"
  else if r.headers.any (fun (k, v) => (k ++ v).any (fun c => c == '\r' || c == '\n')) then
    some s!"{r.url}: a header holds a line break"
  else none

/-- Run `request`. Any answer, `4xx` and `5xx` included, is a `Response`. -/
def send (request : Request) : IO (Except Failure Response) := do
  if let some why := check request then return .error (.refused why)
  let run (bodyFile : Option System.FilePath) : IO (Except Failure IO.Process.Output) := do
    try
      return .ok (← IO.Process.output { cmd := "curl", args := #["-q", "--config", "-"] }
        (some (config request bodyFile)))
    catch e => return .error (.refused s!"curl could not be run: {e}")
  let out ← match request.body with
    | none => run none
    | some b =>
      let (h, path) ← IO.FS.createTempFile
      try
        h.putStr b
        h.flush
        run (some path)
      finally
        try IO.FS.removeFile path catch _ => pure ()
  let out ← match out with
    | .ok o => pure o
    | .error e => return .error e
  if out.exitCode != 0 then
    let why := out.stderr.trimAscii.toString
    let why := if why.isEmpty then s!"curl exited {out.exitCode}" else why
    return .error (.noAnswer s!"{request.method} {request.url}: {why}" out.exitCode.toNat)
  let parts := out.stdout.splitOn statusMarker
  let some code := parts.getLast?.bind (·.trimAscii.toString.toNat?)
    | return .error (.noAnswer s!"{request.method} {request.url}: curl did not report a status" 0)
  let body := statusMarker.intercalate (parts.dropLast)
  return .ok { status := code, body }

/-- A file's contents, trimmed: how every token the platform reads from disk is stored. -/
def readTokenFile (path : System.FilePath) : IO String := do
  return (← IO.FS.readFile path).trimAscii.toString

end DiffReviewer.Http