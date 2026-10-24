import DiffReviewer

open DiffReviewer

private def usage : String :=
"diff-reviewer — code review tool

USAGE:
  diff-reviewer github   <owner/repo> <pr-number> <review.json> [--submit]
      Submit the review to a GitHub pull request via the gh CLI.
      Requires gh to be authenticated (gh auth login).
      By default the review is saved as a pending (draft) review.
      Pass --submit to publish it immediately.

  diff-reviewer from-git <git-range>
      Parse commits in <git-range> (e.g. main..HEAD) and print a
      Review JSON to stdout.

  diff-reviewer serve [--db <path>] [--host <ip>] [--port <n>] [--site <dir>]
                      [--secure-cookie]
      Run the review platform: the HTTP API, and the front-end built into
      <dir> (web/dist). The password is $DIFF_REVIEWER_PASSWORD. Defaults:
      --db diff-reviewer.db, --host 127.0.0.1, --port 8090.
"

private def cmdGitHub (repo : String) (prStr : String) (jsonPath : String)
    (pending : Bool) : IO Unit := do
  let prNumber := prStr.toNat?.getD 0
  if prNumber == 0 then
    IO.eprintln s!"error: invalid PR number '{prStr}'"
    IO.Process.exit 1
  let contents ← IO.FS.readFile jsonPath
  match Review.ofJsonString contents with
  | .error e =>
    IO.eprintln s!"error: could not parse review from {jsonPath}: {e}"
    IO.Process.exit 1
  | .ok review =>
    match ← submitReview repo prNumber review pending with
    | .ok ()   =>
      IO.println (if pending then "Review saved as pending." else "Review submitted successfully.")
    | .error e =>
      IO.eprintln s!"error: {e}"
      IO.Process.exit 1

private def cmdFromGit (range : String) : IO Unit := do
  match ← reviewFromGit range with
  | .error e =>
    IO.eprintln s!"error: {e}"
    IO.Process.exit 1
  | .ok review =>
    IO.println review.toJsonString

private def serveFlags : List String → Except String (Server.Config → Server.Config)
  | [] => .ok id
  | "--db" :: v :: rest => do
    let f ← serveFlags rest
    return fun c => f { c with dbPath := v }
  | "--host" :: v :: rest => do
    let f ← serveFlags rest
    return fun c => f { c with host := v }
  | "--port" :: v :: rest => do
    let some n := v.toNat? | .error s!"--port: '{v}' is not a port"
    unless n < 65536 do .error s!"--port: '{v}' is not a port"
    let f ← serveFlags rest
    return fun c => f { c with port := n.toUInt16 }
  | "--site" :: v :: rest => do
    let f ← serveFlags rest
    return fun c => f { c with siteDir := some v }
  | "--secure-cookie" :: rest => do
    let f ← serveFlags rest
    return fun c => f { c with secureCookie := true }
  | flag :: _ => .error s!"unknown flag '{flag}'"

private def cmdServe (flags : List String) : IO Unit := do
  let some password ← IO.getEnv "DIFF_REVIEWER_PASSWORD"
    | IO.eprintln "error: set DIFF_REVIEWER_PASSWORD to the password the platform is to require"
      IO.Process.exit 1
  if password.length < 12 then
    IO.eprintln "error: DIFF_REVIEWER_PASSWORD is shorter than 12 characters"
    IO.Process.exit 1
  let cfg ← match serveFlags flags with
    | .ok f => pure (f { password })
    | .error e =>
      IO.eprintln s!"error: {e}"
      IO.Process.exit 1
  Store.setPath cfg.dbPath
  -- Open (and migrate) the database before listening, so a bad path fails at start-up.
  let _ ← Platform.listRepos
  let (port, _) ← Server.serve cfg
  IO.println s!"diff-reviewer: serving on http://{cfg.host}:{port} (database {cfg.dbPath})"
  -- The server runs on its own threads; this one only has to stay alive.
  repeat IO.sleep 3600000

def main (args : List String) : IO Unit := do
  match args with
  | ["github", repo, prNumber, jsonPath]             => cmdGitHub repo prNumber jsonPath true
  | ["github", repo, prNumber, jsonPath, "--submit"] => cmdGitHub repo prNumber jsonPath false
  | ["from-git", range]                  => cmdFromGit range
  | "serve" :: flags                     => cmdServe flags
  | _ =>
    IO.print usage
    IO.Process.exit 1
