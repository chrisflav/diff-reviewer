import DiffReviewer

open DiffReviewer

private def usage : String :=
"diff-reviewer — code review tool

USAGE:
  diff-reviewer github   <owner/repo> <pr-number> <review.json> [--submit]
      Post the review to a GitHub pull request. The token is read from
      $DIFF_REVIEWER_GITHUB_TOKEN_FILE, or else from `gh auth token`.
      By default the review is saved as a pending (draft) review.
      Pass --submit to publish it immediately.

  diff-reviewer from-git <git-range>
      Parse commits in <git-range> (e.g. main..HEAD) and print a
      Review JSON to stdout.

  diff-reviewer serve [--db <path>] [--host <ip>] [--port <n>] [--site <dir>]
                      [--secure-cookie] [--interval <seconds>]
                      [--trusted-proxy <ip>] [--max-jobs-per-day <n>]
                      [--max-diff-bytes <n>] [--max-calibration-jobs-per-day <n>]
                      [--github-reserve <n>] [--max-proposals-per-day <n>]
      Run the review platform: the HTTP API, the front-end built into <dir>
      (web/dist), and the workers that find pull requests, queue reviews on
      orchestra and follow them, every --interval seconds. Configured by the
      environment; see the README. Defaults: --db diff-reviewer.db,
      --host 127.0.0.1, --port 8090, --interval 60, --max-jobs-per-day 50,
      --max-diff-bytes 5242880, --max-calibration-jobs-per-day 20,
      --github-reserve 500 (GitHub requests calibration imports leave for
      discovery and posting), --max-proposals-per-day 2 (rubric proposals a
      person may ask for per repository). --trusted-proxy is the reverse proxy whose
      X-Forwarded-For names the client, for the login rate limit.

  diff-reviewer agent show   <owner/repo> <pr-number> --job <id>
  diff-reviewer agent diff   <owner/repo> <pr-number> --job <id>
  diff-reviewer agent submit <owner/repo> <pr-number> <submission.json | -> --job <id>
      What a reviewing agent runs: the review it is to write, the diff under
      review, and submitting the review. The platform's URL and token are in
      ~/.config/diff-reviewer/agent.json ({\"url\": …, \"token\": …}), and
      $DIFF_REVIEWER_URL and $DIFF_REVIEWER_TOKEN override them. --job names
      the job the agent's prompt gave it, and is required.

  diff-reviewer agent proposal show   <owner/repo> --job <id>
  diff-reviewer agent proposal submit <owner/repo> <proposal.json | -> --job <id>
      What a rubric proposal agent runs: what the proposal is written from (the
      rubric, the style notes, calibration's results, people's edits), and
      submitting the proposed rubric with its rationale.
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
    let some (owner, name) := Agent.splitSlug repo
      | IO.eprintln s!"error: '{repo}' is not owner/repo"
        IO.Process.exit 1
    let gh ← match ← GitHub.Client.fromEnv with
      | some c => pure c
      | none =>
        -- Without a token file, the token `gh` is signed in with, as before there was a client.
        let out ← try IO.Process.output { cmd := "gh", args := #["auth", "token"] }
          catch _ => pure { exitCode := 1, stdout := "", stderr := "" }
        if out.exitCode != 0 || out.stdout.trimAscii.isEmpty then
          IO.eprintln "error: set DIFF_REVIEWER_GITHUB_TOKEN_FILE, or sign in with `gh auth login`"
          IO.Process.exit 1
        pure (GitHub.Client.curl out.stdout.trimAscii.toString (← GitHub.defaultApi))
    let event := if pending then none else some review.decision
    match ← gh.postReview owner name prNumber review none event with
    | .ok r =>
      IO.println (if pending then "Review saved as pending." else "Review submitted successfully.")
      unless r.url.isEmpty do IO.println r.url
    | .error e =>
      IO.eprintln s!"error: {e.message}"
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
  | "--interval" :: v :: rest => do
    let some n := v.toNat? | .error s!"--interval: '{v}' is not a number of seconds"
    unless n ≥ 1 do .error "--interval must be at least 1 second"
    let f ← serveFlags rest
    return fun c => f { c with interval := n }
  | "--trusted-proxy" :: v :: rest => do
    let f ← serveFlags rest
    return fun c => f { c with trustedProxy := some v }
  | "--max-jobs-per-day" :: v :: rest => do
    let some n := v.toNat? | .error s!"--max-jobs-per-day: '{v}' is not a number"
    let f ← serveFlags rest
    return fun c => f { c with limits.maxJobsPerDay := n }
  | "--max-diff-bytes" :: v :: rest => do
    let some n := v.toNat? | .error s!"--max-diff-bytes: '{v}' is not a number of bytes"
    let f ← serveFlags rest
    return fun c => f { c with limits.maxDiffBytes := n }
  | "--max-calibration-jobs-per-day" :: v :: rest => do
    let some n := v.toNat? | .error s!"--max-calibration-jobs-per-day: '{v}' is not a number"
    let f ← serveFlags rest
    return fun c => f { c with limits.maxCalibrationJobsPerDay := n }
  | "--max-proposals-per-day" :: v :: rest => do
    let some n := v.toNat? | .error s!"--max-proposals-per-day: '{v}' is not a number"
    let f ← serveFlags rest
    return fun c => f { c with limits.maxProposalsPerDay := n }
  | "--github-reserve" :: v :: rest => do
    let some n := v.toNat? | .error s!"--github-reserve: '{v}' is not a number of requests"
    let f ← serveFlags rest
    return fun c => f { c with limits.githubReserve := n }
  | flag :: _ => .error s!"unknown flag '{flag}'"

/-- The token in the file `var` names, if it is set. -/
private def tokenFromEnv (var : String) : IO (Option String) := do
  let some path ← IO.getEnv var | return none
  let tok ← try Http.readTokenFile path
    catch e =>
      IO.eprintln s!"error: {var}: {e}"
      IO.Process.exit 1
  if tok.isEmpty then
    IO.eprintln s!"error: {var}: {path} is empty"
    IO.Process.exit 1
  return some tok

private def cmdServe (flags : List String) : IO Unit := do
  let some password ← IO.getEnv "DIFF_REVIEWER_PASSWORD"
    | IO.eprintln "error: set DIFF_REVIEWER_PASSWORD to the password the platform is to require"
      IO.Process.exit 1
  let apiToken ← tokenFromEnv "DIFF_REVIEWER_API_TOKEN_FILE"
  let agentToken ← tokenFromEnv "DIFF_REVIEWER_AGENT_TOKEN_FILE"
  let proposerAgentToken ← tokenFromEnv "DIFF_REVIEWER_PROPOSER_AGENT_TOKEN_FILE"
  let cfg ← match serveFlags flags with
    | .ok f => pure (f { password, apiToken, agentToken, proposerAgentToken })
    | .error e =>
      IO.eprintln s!"error: {e}"
      IO.Process.exit 1
  if let .error e := cfg.check then
    IO.eprintln s!"error: {e}"
    IO.Process.exit 1
  let log (m : String) : IO Unit := IO.eprintln s!"diff-reviewer: {m}"
  if apiToken.isNone then
    log "no DIFF_REVIEWER_API_TOKEN_FILE: only a signed-in browser reaches /api/v1"
  if agentToken.isNone then
    log "no DIFF_REVIEWER_AGENT_TOKEN_FILE: the agent API refuses every request"
  if proposerAgentToken.isNone then
    log "no DIFF_REVIEWER_PROPOSER_AGENT_TOKEN_FILE: a rubric proposal's agent routes refuse \
every request"
  let login := (← IO.getEnv "DIFF_REVIEWER_GITHUB_LOGIN").filter (!·.isEmpty)
  let cfg := { cfg with limits.githubLogin := login }
  let github ← GitHub.Client.fromEnv cfg.limits.maxDiffBytes
  if github.isNone then
    log "no DIFF_REVIEWER_GITHUB_TOKEN_FILE: no discovery, no diffs, no posting"
  let orchestraUrl ← IO.getEnv "DIFF_REVIEWER_ORCHESTRA_URL"
  let orchestraToken ← tokenFromEnv "DIFF_REVIEWER_ORCHESTRA_TOKEN_FILE"
  let proposerToken ← tokenFromEnv "DIFF_REVIEWER_ORCHESTRA_PROPOSER_TOKEN_FILE"
  let cfg := { cfg with orchestraToken, proposerToken }
  if let .error e := cfg.check then
    IO.eprintln s!"error: {e}"
    IO.Process.exit 1
  let client (tok? : Option String) : Option Orchestra.Client := do
    return Orchestra.Client.curl (← orchestraUrl) (← tok?)
  let orchestra := client orchestraToken
  let proposer := client proposerToken
  if orchestra.isSome && proposer.isNone then
    log "no DIFF_REVIEWER_ORCHESTRA_PROPOSER_TOKEN_FILE: rubric proposals stay pending"
  let services ← Workers.Services.new github orchestra log cfg.limits proposer
  Store.setPath cfg.dbPath
  -- Open (and migrate) the database before listening, so a bad path fails at start-up.
  let _ ← Platform.listRepos
  let (port, _) ← Server.serve cfg services
  IO.println s!"diff-reviewer: serving on http://{cfg.host}:{port} (database {cfg.dbPath})"
  (← IO.getStdout).flush
  Workers.start services cfg.interval
  -- The server runs on its own threads; this one only has to stay alive.
  repeat IO.sleep 3600000

def main (args : List String) : IO Unit := do
  match args with
  | ["github", repo, prNumber, jsonPath]             => cmdGitHub repo prNumber jsonPath true
  | ["github", repo, prNumber, jsonPath, "--submit"] => cmdGitHub repo prNumber jsonPath false
  | ["from-git", range]                  => cmdFromGit range
  | "serve" :: flags                     => cmdServe flags
  | "agent" :: "show" :: repo :: pr :: rest =>
    let some job := Agent.jobFlag rest | IO.print usage; IO.Process.exit 1
    IO.Process.exit (← Agent.showPull repo pr job).toUInt8
  | "agent" :: "diff" :: repo :: pr :: rest =>
    let some job := Agent.jobFlag rest | IO.print usage; IO.Process.exit 1
    IO.Process.exit (← Agent.printDiff repo pr job).toUInt8
  | ["agent", "proposal", "show", repo, "--job", job] =>
    IO.Process.exit (← Agent.showProposal repo job).toUInt8
  | ["agent", "proposal", "submit", repo, path, "--job", job] =>
    IO.Process.exit (← Agent.submitProposal repo path job).toUInt8
  | "agent" :: "submit" :: repo :: pr :: path :: rest =>
    let some job := Agent.jobFlag rest | IO.print usage; IO.Process.exit 1
    IO.Process.exit (← Agent.submit repo pr path job).toUInt8
  | _ =>
    IO.print usage
    IO.Process.exit 1