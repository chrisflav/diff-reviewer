# diff-reviewer

A platform for agentic reviews of GitHub pull requests (taxis #588), grown out of a small review
tool. Agents draft reviews; you read and edit them against the diff, approve them, and they are
posted to the pull request under your name.

It is built in milestones. The first six are here:

- **A review format** (`DiffReviewer/Types.lean`): a decision (comment, approve, request changes),
  a summary, and at most 200 inline comments on file line ranges with optional suggestions. Each
  comment has a stable `id`, and may have a `category` and a `severity` (see
  [Rubrics](#rubrics)). Fields the platform does not know, on a review or a comment, are kept as
  they are.
- **The platform server** (`diff-reviewer serve`): a REST API over a SQLite database, holding the
  repositories it reviews and one *job* per review of a pull request at one head commit. A job
  moves `pending → queued → running → draft → approved → posted`; `rejected` is a discarded draft,
  `stale` a draft whose pull request has moved on, `failed` a run that ended without a review.
  `docs/openapi.json` describes the API and is served at `/api/openapi.json`.
- **Background workers** inside `serve` (`DiffReviewer/Workers.lean`), every `--interval` seconds:
  *discovery* makes a job for every new head of an open pull request of a repository with
  `autoReview` (GitHub draft pull requests wait until they are ready; at most
  `--max-jobs-per-day` a repository), and makes every job of an older head `stale`, cancelling its
  orchestra run if it has one; *queueing* checks a `pending` job's head is still the pull
  request's, fetches its diff (past `--max-diff-bytes` the job `failed`s) and puts it on
  [orchestra](https://github.com/chrisflav/orchestra) as an API client; *following* reads the
  queue entry and moves the job to `running`, or to `failed` when the run ends without a review;
  *settling* settles every claim to post that is past its window, as
  `POST /api/v1/jobs/{id}/reconcile` would, and logs what it found. Kept diffs no live job needs,
  and any older than 30 days, are dropped.
- **The agent API** (`/api/agent/v1/repos/{owner}/{name}/pulls/{pr}…`) and **the agent CLI**
  (`diff-reviewer agent show|diff|submit … --job <id>`, `agent diff … --since <sha>` for an
  [incremental re-review](#incremental-re-review)): what the reviewing agent reads and how
  it submits. A submission is checked as GitHub would check it — its comments must be on the
  diff's new side — and becomes a `draft`; in a `direct` repository it is posted at once, always
  as a comment.
- **Posting** (`POST /api/v1/jobs/{id}/post`): an approved review is posted to the pull request
  under the operator's GitHub account, pinned to the job's head commit, as its decision. Only this
  route, a person's, ever approves or requests changes. A review is posted once, even with several
  processes on one database: the attempt is claimed in the database just before the post (in a
  `BEGIN IMMEDIATE` transaction, so one process claims it), a claim is never taken over within
  three times the post's timeout, and the posted body carries a marker
  (`<!-- diff-reviewer job <id> -->`). When GitHub's answer is lost, is a `5xx`, or is its rate limit, the claim
  stands — the job cannot leave `approved`, be edited or go stale — until a later attempt has
  searched the pull request's reviews by the operator for the marker; a review found is recorded
  as GitHub holds it (`postedReview`) rather than posted again. `POST /api/v1/jobs/{id}/reconcile`
  does only that check, without posting: found, the job is `posted`; not found once the claim's
  window has passed, the claim is cleared and the job is free to be edited, rejected or go stale.
  The workers make the same check on every pass, so a claim is settled even when nobody asks — in
  a `direct` repository nobody may. There, a review the platform posted that is found not to have
  reached GitHub is posted again, as a comment — but only if the pull request is still open at the
  job's head (otherwise the job is `stale`), and at most 3 posts by the platform in all; after that
  it is left `approved`, with why in its `error`, for a person to post. A post a person starts is
  never posted again by the platform, and does not count.
- **Rubrics** (`/api/v1/repos/{owner}/{name}/rubrics`): per repository, a default rubric and the
  kinds of pull request its reviews tell apart, each with its own rubric and categories, which the
  agent reviews by. See [Rubrics](#rubrics).
- **A review's history** (`GET /api/v1/jobs/{id}/revisions`): every write of a job's review — the
  agent's submission, each edit, and what GitHub holds once it is posted — kept with who wrote it.
  The agent's draft beside what was posted is what calibration will learn from. It is bounded: the
  agent's first draft, every revision GitHub holds, and the last 100 are kept. It and the rubric
  history are paged (`?limit=…&offset=…`, 50 by default).
- **Calibration** (`/api/v1/repos/{owner}/{name}/calibration/…`): the agent's reviews of past
  commits, scored against the reviews the repository's trusted reviewers wrote of the same commits.
  See [Calibration](#calibration).
- **Learned review style**: the agent is shown inline comments the trusted reviewers wrote, to
  write in their style, and the operator's `styleNotes`. See [Review style](#review-style).
- **Rubric proposals** (`/api/v1/repos/{owner}/{name}/proposals`): an agent reads the calibration
  data and the people's edits of the agent's drafts and proposes a rubric, which a person accepts
  as the next rubric version or rejects. See [Rubric proposals](#rubric-proposals).
- **Fan-out**: a pull request type — or the rubric, for every review — may ask for its reviews to
  be run as one sub-run per category plus one by the default rubric, side by side, and merged into
  one draft. See [Fan-out](#fan-out).
- **Incremental re-review**: a new head of a pull request whose review was posted is reviewed for
  the changes since, with the posted review in the agent's context. See
  [Incremental re-review](#incremental-re-review).
- **A web front-end** (`web/`): sign in, register repositories, request a review, read a review,
  edit it, approve or reject it. Every write names the version of the job it was made on, so a
  stale page is refused rather than overwriting.
- **The command-line tools** it started as: `diff-reviewer github` posts a review JSON to a pull
  request, and `diff-reviewer from-git` turns a commit range into one.

Next: the front-end for style, proposals, fan-out and incremental re-review.

## Running it

```sh
lake build
cd web && npm ci && npm run build && cd ..
DIFF_REVIEWER_PASSWORD='…' \
DIFF_REVIEWER_API_TOKEN_FILE=/etc/diff-reviewer/api-token \
DIFF_REVIEWER_AGENT_TOKEN_FILE=/etc/diff-reviewer/agent-token \
DIFF_REVIEWER_GITHUB_TOKEN_FILE=/etc/diff-reviewer/github-token \
DIFF_REVIEWER_ORCHESTRA_URL=https://orchestra.example \
DIFF_REVIEWER_ORCHESTRA_TOKEN_FILE=/etc/diff-reviewer/orchestra-token \
  .lake/build/bin/diff-reviewer serve --db reviews.db --site web/dist
```

It listens on `127.0.0.1:8090` (`--host`, `--port`) and runs the workers every 60 seconds
(`--interval`). The server is plain HTTP: put TLS in front of anything wider than loopback, pass
`--secure-cookie`, and name the reverse proxy with `--trusted-proxy <ip>`: failed logins are
counted per client address — an IPv6 client per /64 — which is the socket's peer unless the
request comes from that proxy, when it is the last address of `X-Forwarded-For`. `--max-jobs-per-day` (default 50) bounds the
jobs discovery makes per repository — each sub-run of a [fan-out](#fan-out) counting as one, and
checked when a review fans out — `--max-calibration-jobs-per-day` (default 20) the calibration
jobs runs make (and their retries) per repository, apart from it, `--github-reserve` (default 500)
the GitHub requests calibration imports leave for discovery and posting, `--max-proposals-per-day`
(default 2) the rubric proposals a person may ask for per repository, and `--max-diff-bytes`
(default 5242880) the diff reviewed.

Releases (`v*` tags) attach a Linux x86_64 binary and its sha256 to the GitHub release; it runs on
Debian bookworm and newer. They also publish the image review tasks run in on orchestra,
`ghcr.io/chrisflav/diff-reviewer-agent` (see [The agent image](#the-agent-image)). The workflow
builds with read-only permissions and only its publishing jobs may write — the release's job
`contents`, the image's job `packages`; its actions are pinned by commit.

### Configuration

Everything but the flags comes from the environment. A token is always read from a file, so that
it never appears in a process listing or a shell history; the file's surrounding whitespace is
ignored.

| Variable | |
| --- | --- |
| `DIFF_REVIEWER_PASSWORD` | Required. What you sign in with, at least 12 characters. Accepted only by `POST /api/login`, which is rate-limited: after 5 failures from one address (an IPv6 /64) within 15 minutes every attempt from it is refused (`429`, at once, with `Retry-After`) for 15 seconds, doubling with each further failure; after 100 from all addresses together, every password attempt is refused for a while. Sign in with the API token then. |
| `DIFF_REVIEWER_API_TOKEN_FILE` | The bearer scripts send to `/api/v1/` (`Authorization: Bearer …`). `POST /api/login` also takes it (`{"token": …}`) and issues a session, with no rate limit: the way in while password attempts are refused. Unset, only a signed-in browser reaches the API. |
| `DIFF_REVIEWER_AGENT_TOKEN_FILE` | The bearer of `/api/agent/v1/` — every route but a rubric proposal's — and good for nothing else. Unset, those routes refuse everything. kleis holds it, never the agent. |
| `DIFF_REVIEWER_PROPOSER_AGENT_TOKEN_FILE` | The bearer of a rubric proposal's agent routes (`/api/agent/v1/repos/{owner}/{name}/proposals/…`), and of nothing else: the agent token does not reach them, nor this one a pull request's. Unset, they refuse everything. kleis holds it, under an account of its own (see [Behind kleis](#behind-kleis)). |
| `DIFF_REVIEWER_GITHUB_TOKEN_FILE` | The token for api.github.com: listing pull requests, reading one and its diff, posting reviews. Unset, there is no discovery, no diff and no posting. In production this is the placeholder `kleis` (see below). Also used by `diff-reviewer github`, which otherwise falls back to `gh auth token`. |
| `DIFF_REVIEWER_GITHUB_LOGIN` | The GitHub login reviews are posted as. **Set it in production.** When a post's outcome is unknown, only reviews by this login count as the platform's: without it, anyone who writes a job's marker into a review of their own could make the platform record that job as posted (it logs this once). And on a pull request this login wrote, GitHub refuses an approval or a request for changes, so such a review is posted as a comment and the job's `postNote` says so. |
| `DIFF_REVIEWER_GITHUB_API` | GitHub's API root, `https://api.github.com` by default. |
| `DIFF_REVIEWER_ORCHESTRA_PROPOSER_TOKEN_FILE` | The platform's second API client token on orchestra, which rubric proposals are queued with (see [On orchestra](#on-orchestra)). Unset, proposal jobs stay `pending`, with why in their `error`. |
| `DIFF_REVIEWER_ORCHESTRA_URL`, `DIFF_REVIEWER_ORCHESTRA_TOKEN_FILE` | Orchestra, and the platform's API client token on it. Without both, jobs stay `pending` (and the log says so once). Orchestra is always reached directly, never through `HTTPS_PROXY` (its host is curl's `noproxy`): the proxy is kleis, there for GitHub, and the orchestra token is not one kleis should see. Add the host to `NO_PROXY` too, for anything else in the environment. |
| `HTTPS_PROXY`, `NO_PROXY`, `CURL_CA_BUNDLE`, `SSL_CERT_FILE` | Every outgoing request is made with `curl`, which reads these as usual (and no `~/.curlrc`: it runs with `-q`). Only `https` is used, or `http` to loopback. |

The three secrets must differ, and each token must be at least 32 characters
(`openssl rand -hex 32`): `serve` refuses to start otherwise. So must the orchestra token for
proposals: at least 32 characters, and none of the password, the API token, the agent token or
the orchestra token for reviews.

The agent CLI reads `~/.config/diff-reviewer/agent.json`, `{"url": "https://reviews.example",
"token": "kleis"}`, and `DIFF_REVIEWER_URL` and `DIFF_REVIEWER_TOKEN` override either field.
(`DIFF_REVIEWER_URL` is also where `npm run dev` proxies `/api` to.) The prompt gives the agent
its job id, which it passes as `--job <id>` (`X-Diff-Reviewer-Job`), and must: a request about a
pull request that names no job is refused (`400`), however many reviews of it are running — an old
head's, not yet cancelled, beside the new one's must never be given the wrong one — and so is one
naming a job of another kind (a rubric proposal, `404`).

Head commits are always whole commit ids (40 or 64 hex digits); `POST /api/v1/jobs` refuses an
abbreviation.

### On orchestra

The platform queues reviews as an orchestra API client. Create
`<config>/clients/diff-reviewer.json` on orchestra:

```json
{
  "token": "{{diff_reviewer_token}}",
  "backend": "claude",
  "read_only": true,
  "kleis_spec": "reviewer",
  "execution_image": "ghcr.io/chrisflav/diff-reviewer-agent:0.1.0@sha256:…",
  "queue_policy": {
    "repos": ["acme/widgets"],
    "images": ["ghcr.io/chrisflav/diff-reviewer-agent:0.1.0@sha256:…"],
    "max_budget": 3.0
  },
  "max_active": 10
}
```

with `diff_reviewer_token` in orchestra's `secrets.json` and the same value in the platform's
`DIFF_REVIEWER_ORCHESTRA_TOKEN_FILE`. `queue_policy.repos` must list every repository registered
on the platform: orchestra refuses (`400`) a repository it does not list, and the job stays
`pending` with that reason in its `error`. Each request names the prompt, a goal, the upstream,
the pull request (`issue_number`) and the job id as `external_id` — `<id>.2`, `<id>.3`, … for a
retry, since orchestra answers an `external_id` it has seen with the entry it already made; a
[fan-out](#fan-out)'s sub-runs are `<id>.<key>` (`<id>.<key>.2` run again). When a
pull request moves on, the platform cancels the runs of its older heads
(`POST /api/v1/queue/{id}/cancel`). The
agent needs `curl` and the `diff-reviewer` binary from a release on its `PATH`: see the next
section.

**Rubric proposals need a second client.** A proposal task must run under a kleis spec of its
own, `rubric-proposer` (see [Behind kleis](#behind-kleis)), and orchestra gives every task an API
client queues the client file's `kleis_spec`: a request cannot name one (`kleis_narrow` can only
take away). So proposals are queued through a client of their own,
`<config>/clients/diff-reviewer-proposer.json`:

```json
{
  "token": "{{diff_reviewer_proposer_token}}",
  "backend": "claude",
  "read_only": true,
  "kleis_spec": "rubric-proposer",
  "execution_image": "ghcr.io/chrisflav/diff-reviewer-agent:0.2.0@sha256:…",
  "queue_policy": {
    "repos": ["acme/widgets"],
    "images": ["ghcr.io/chrisflav/diff-reviewer-agent:0.2.0@sha256:…"],
    "max_budget": 3.0
  },
  "max_active": 2
}
```

with an image of a release that has `agent proposal` (this one's or later), and its own token —
orchestra refuses a token two clients share — in `secrets.json` and in the
platform's `DIFF_REVIEWER_ORCHESTRA_PROPOSER_TOKEN_FILE`. A proposal's request names the prompt,
a goal, the upstream and the job id as `external_id`, and no `issue_number`: orchestra takes a
task of a repository with no issue (its `queue_policy` has no rule about one), and the task's
token then carries `task_upstream` and no `task_issue`. It carries the narrowing
`"github: only discover, fetch"`, as a calibration job's does. The platform follows and cancels a
proposal's entry through the same client. (If orchestra one day lets a client's `queue_policy`
list the specs a request may name — a `kleis_specs` list beside `repos`, and a `kleis_spec`
request field checked against it — one client would do.)

### The agent image

On orchestra's `kubernetes` backend a review runs in its own pod, and the image that pod runs must
carry the `diff-reviewer` CLI. Orchestra's default agent image does not, and should not: each
release publishes `ghcr.io/chrisflav/diff-reviewer-agent:<version>` (the release's tag without
its `v`, and `:latest` for the latest release), which is orchestra's agent image
(`ghcr.io/chrisflav/orchestra-agent`) with the release's binary in `/usr/local/bin` and nothing
else changed — the same non-root `agent` user, the same home, `curl` already there. It is built
by `docker/agent.Dockerfile`, from the binary attached to the release, on a base pinned by tag
and digest in that file; its labels name the commit it was built from
(`org.opencontainers.image.revision`) and the base it was built on
(`org.opencontainers.image.base.name`, `org.opencontainers.image.base.digest`).

It needs orchestra's per-task `execution_image` (orchestra PR #220, not yet merged at the time of
writing). A review task asks for it by name (orchestra's `execution_image`), which beats both the operator's
per-repository pin and a repository's own `execution.image`: a review needs this CLI whatever the
repository it reviews. In the client file above:

- **`execution_image`** is the image every task the platform queues runs in. The platform's
  requests do not name one, so this default is what applies.
- **`queue_policy.images`** lists the images a request may name instead. List this image there
  too (orchestra refuses, `400`, a request naming an image the list does not have), so that a
  request may name it; leave every other image out.

**Pin it by digest.** A tag can be pushed again — `:latest` moves with every release, and a
version's tag moves when its image is rebuilt on a newer base — so write
`ghcr.io/chrisflav/diff-reviewer-agent:<version>@<digest>`, in both places: the release
workflow's run prints the digest it pushed in its summary, and `docker buildx imagetools inspect
ghcr.io/chrisflav/diff-reviewer-agent:<version>` shows it later.
`images` is an exact list, so a new digest has to be written there as well as in
`execution_image`.

**A newer base.** To pick up a newer claude-code without a new release, run the release workflow
by hand (*Actions → Release → Run workflow*) with the release's tag (`v0.1.0`) and the
`orchestra-agent` tag to build on (`claude-<version>`): it rebuilds that release's image from its
binary and Dockerfile against that tag, pins the digest the tag has at that moment in the labels,
pushes `:<version>` again (and `:latest`, if it is the latest release), and prints the new digest.

**On landrun or local hosts** there is no image: orchestra notes the requested image in its log
and runs the task on the host. Install the release's binary somewhere on the agent's `PATH` there
(under landrun, a path the sandbox can execute, e.g. through `additional_sandbox_paths`).

To build it from a local binary:

```sh
lake build
DOCKER_BUILDKIT=1 docker build -f docker/agent.Dockerfile --build-arg BINARY=diff-reviewer \
  -t diff-reviewer-agent:dev .lake/build/bin
```

### Behind kleis

The platform holds no real credential of GitHub, and agents hold none of the platform's:

- **The agent's side.** kleis's `diff-reviewer` extension injects the agent token
  (`Authorization: Bearer`) into an agent's requests to `/api/agent/v1/` and nothing else, and
  its `reviewer` spec allows them only for the task's own repository and pull request
  (`task_upstream`, `task_issue`). GitHub is read-only to the agent, so an agent can never post
  anything itself. The extension's setup writes `~/.config/diff-reviewer/agent.json` with the
  platform's URL and the placeholder token `kleis`, which kleis strips and replaces.
- **A proposal agent's side.** A rubric proposal's routes are of the repository and the job, with
  no pull request, and the extension must add them — repository-bound, emitting
  `repository($o, $n)` and no `pull` fact:

  | Method | Path | Operation |
  | --- | --- | --- |
  | `GET` | `/api/agent/v1/repos/{o}/{n}/proposals/{jobId}` | `read_proposal` |
  | `POST` | `/api/agent/v1/repos/{o}/{n}/proposals/{jobId}` | `submit_proposal` |

  The `reviewer` spec must not allow `read_proposal` or `submit_proposal`: a review agent has no
  business reading the calibration data or writing a rubric. A separate `rubric-proposer` spec
  allows them, bound to the task's repository (`task_upstream`), and nothing of the review routes
  (`…/pulls/{pr}…`): a proposal task has no `task_issue` to bind them to. The platform binds the
  request to the job: `{jobId}` must be a proposal job of that repository — for a read, queued or
  running (a repository has at most one such job); a submission to one that is not running is a
  `409` — or the answer is `404`. A submission carries a whole rubric document, so allow request
  bodies up to the platform's own limit, 1 MiB.

  **A second account.** These routes take their own bearer,
  `DIFF_REVIEWER_PROPOSER_AGENT_TOKEN_FILE`, and the review routes refuse it, as these refuse the agent token: should a grant ever let a
  request of the one kind through on the other's routes, the platform still refuses it. So kleis
  needs a second account, `diff-reviewer/proposer`, carrying that token, and the `rubric-proposer`
  spec injects it (and the `reviewer` spec keeps injecting the agent token).
- **The platform's side.** Run `serve` with `HTTPS_PROXY` pointing at kleis (and kleis's CA in
  `CURL_CA_BUNDLE`), and `DIFF_REVIEWER_GITHUB_TOKEN_FILE` holding `kleis`. kleis's
  `diff-reviewer-poster` grant injects the operator's PAT for reading pull requests and posting
  reviews on the repositories it lists, so approved reviews appear under your own name.
  Calibration's imports read only under `/repos/{owner}/{name}/` too — the closed pull requests,
  their reviews and review comments, and a compare of two commits — which the same grant allows.

## Rubrics

A repository's rubric is one document, `GET`/`PUT /api/v1/repos/{owner}/{name}/rubrics`:

```json
{
  "version": 3,
  "defaultRubric": "Proofs must not use `sorry`. Prefer `simp only` in the middle of a proof.",
  "prTypes": [
    {
      "name": "feature",
      "description": "Adds new definitions or theorems.",
      "rubric": "Check the names against the naming convention, and that every new definition has a docstring and the API a user needs.",
      "categories": [
        {"name": "correctness", "description": "Wrong, or proves the wrong thing."},
        {"name": "naming", "description": "Against the naming convention."},
        {"name": "docs", "description": "Missing or misleading documentation."}
      ]
    },
    {"name": "refactor", "description": "Moves or renames without changing what is proved.",
     "rubric": "Check that nothing is lost and that deprecations are added.", "categories": []}
  ]
}
```

- **What to write.** The *default rubric* is what every review of the repository should look at:
  the conventions a maintainer checks first, what the repository cares about and what it does not.
  A *pull request type* is a kind of change that is reviewed differently: its `description` says
  how to recognise it — the agent picks the type by it — and its `rubric` says what to look at in
  such a change, on top of the default. Its *categories* are what its comments are filed under:
  short names (`correctness`, `naming`, `performance`), with a description of what belongs in each.
  Rubrics are markdown and go to the agent as they are, so write them as you would brief a careful
  new maintainer: concrete checks, not adjectives.
- **How agents use them.** `agent show` gives the agent the default rubric at the end of its
  `instructions`, and the types in `prTypes`, each with its rubric and categories. The agent picks
  the type that fits, reviews by its rubric, and gives every comment a `severity` — `nit`,
  `minor`, `major` or `blocker` — and a `category`. Its submission must name one of the types as
  `prType` (or `null` when there are none), and each category must be one of that type's — or
  is free text when that type lists none: the platform refuses anything else, saying what to fix,
  while the agent can still fix it. A person's edit is checked the same way, for the comments
  whose category it adds or changes; a job of no type (reviewed by hand) may use any category of
  the document, or free text if it names none. A job reviewed with no rubric at all records
  `rubricVersion` 0.
- **Versions.** Every `PUT` names the version it replaces (`0` for the first) and is refused
  (`409`) if that is no longer the current one; it becomes the next version, and every version is
  kept (`GET …/rubrics/history`). A job records the version and the type it was reviewed against
  (`rubricVersion`, `prType`), so a review is always read next to the rubric it was written to.
  Fields the platform does not know, on the document, a type or a category, are kept through every
  write, so a newer front-end's additions survive an older platform; and a `GET`'s answer may be
  sent back as the next `PUT` as it is, edited. A version this build cannot read is shown with its
  `documentError` and is not overwritten (`409`). Deleting a repository keeps its rubric versions,
  as it keeps its jobs, which name them: registering it again picks its rubric up where it was.
- **Not on GitHub.** Categories and severities are for the platform — reading, filtering,
  calibration, the categories of style examples — and are not part of what is posted: a posted
  review stays in the operator's plain style, which [Review style](#review-style) is how the
  agent learns.

Every inline comment has an `id`, short and random, unique within its review: the platform gives
one to each comment written without one, when the review is submitted or edited, and keeps the ones
comments have — so keep them when editing, and a comment can be followed from the agent's draft to
what was posted. A review stored before ids existed gets them on its next write, never on a read.

## Calibration

How close are the agent's reviews to the ones the people you trust write? Calibration measures it
on the repository's own past: the agent reviews commits that a trusted reviewer has already
reviewed, without being shown that review, and the two are compared.

### How to calibrate

1. **Say whose reviews count.** `PUT /api/v1/repos/{owner}/{name}` (and `GET` it to read the
   settings and their `version`) with
   `{"trustedReviewers": ["alice", "bob"]}` (alongside `mode` and `autoReview`, which the write
   replaces as always). Leaving `trustedReviewers` out of a later write keeps them. The settings
   are versioned: send the `version` you read, and a write over a newer one is a `409`. Versions
   never repeat for one repository: deleted and registered again (with `version` 0), it goes on
   from the version it had, so a page that read the old registration is refused by the new.
2. **Import.** `POST …/calibration/import` with `{"limit": 50}` (the default; at most 200) queues
   an import of that many of the most recently updated closed pull requests. The workers read it
   on, 25 pull requests a pass (`GET …/calibration/import` shows how far;
   `POST …/calibration/import/{id}/cancel` stops it, keeping what it stored). What one trusted
   reviewer said of one commit — every review they submitted of it, merged — becomes a **sample**
   (`GET …/calibration/samples`): the commit, the merge base of the pull request's base and that
   commit (the base its diff had there), the reviewer, the strongest state of the reviews
   (`CHANGES_REQUESTED`, then `APPROVED`, then `COMMENTED`), their bodies, and their inline
   comments on the new side of that commit. One sample is one job of a run. A sample's `scope`
   says what it is scored for:
   - `full` — everything;
   - `partial` — comments were dropped (on the old side, or not anchored to the commit; see
     below), so its comments are not the whole review: its decision only;
   - `decision` — an approval or a request for changes that says nothing else: its decision only.

   What is not kept is counted, on the sample (`dropped`) and on the import (`stats`). Every
   review is counted once, by the import that first looks at it:
   - `droppedLeft` — comments on the old side of the diff;
   - `droppedOutdated` — comments not anchored to a line of the review's own commit: written
     against another commit (`original_commit_id`), or on the whole file rather than a line.
     "Outdated" means exactly this here, and not what GitHub shows: a comment GitHub now marks
     outdated is outdated only against later commits, is kept at the line it was written on, and
     is usually one the author acted on — dropping it would bias the sample towards what was
     ignored;
   - `droppedReplies` — replies in a thread, which answer a comment rather than raise one; they
     do not make a sample `partial`;
   - `empty` — comments (and dismissed reviews) that leave nothing to compare, no body and no
     comment kept — a reply in a thread among them, which GitHub files as a review of its own; not
     stored. An empty approval or request for changes is kept, as a `decision` sample;
   - `merged` — reviews added to the sample of their commit and reviewer;
   - `known` — reviews an earlier import looked at, whatever became of them;
   - `deleted` — reviews of a group whose sample was deleted, added to nothing;
   - `unreachable` — reviews of a commit GitHub can no longer compare with the base, typically
     one a force-push left unreferenced; not stored, since its diff cannot be had;
   - `unreadable` — pull requests whose reviews or comments GitHub refused to list, or that
     failed three times running; the import skips them and goes on;
   - `ownPosts` — reviews the platform posted itself, under the operator's login, which may well
     be trusted: by GitHub's id of a job's `postedReview`, or by the marker in their body. Never a
     sample: the agent is neither scored against nor taught by itself.

   Importing again adds only reviews no import has seen, to the sample of their group when there
   is one; a sample you delete (`DELETE …/calibration/samples/{id}`) stays deleted and gets
   nothing more; `GET …/calibration/samples?deleted=include` lists the deleted ones too, marked
   (`deleted`, `deletedAt`). GitHub's budget is shared with discovery and posting: when GitHub
   says its rate limit is reached, or its `X-RateLimit-Remaining` falls under `--github-reserve` (500 by
   default), the import pauses where it is until `X-RateLimit-Reset`, and goes on by itself; while
   it waits, its `resetAt` says until when.
3. **Run.** `POST …/calibration/runs` with `{"samples": ["<id>", …]}`, or `{"count": 10}` for
   the samples run least so far (at most 20 either way); a sample that a live calibration job is
   reviewing already is refused (`409`), and `count` leaves those out. Each sample gets a
   `calibration` job at its commit, with its base for the diff, which is queued on orchestra and
   reviewed as a review job is, with the same prompt and the repository's current rubric — apart
   from how the code is read, and from being told it is not posted. The prompt and what the agent
   reads name no sample and quote nothing of the person's review, and the task cannot read it
   on GitHub either: its orchestra request carries the kleis narrowing
   `"github: only discover, fetch"` (`kleis_narrow`), so its token reaches GitHub only through
   git — no REST or GraphQL read, no download — while the agent API, which gives it the pull
   request and the diff, is not narrowed. A review job's request carries none. The task's
   checkout is the default branch, read-only, so the agent is told to review from
   `diff-reviewer agent diff`, to read a file at the commit with `git show <headSha>:<path>` where
   the clone has it, and to read no other ref. A calibration job is **never posted**: it cannot be
   approved, edited, claimed, posted or reconciled (`409`), in a `direct` repository too;
   discovery never makes it `stale`. Its repository's `--max-calibration-jobs-per-day` (20 by
   default, apart from `--max-jobs-per-day`) is charged once for each job a run makes and once
   for each time a person runs a failed one again (`failed → pending`); past it either is a
   `429`. Running a failed job again is refused (`409`) while a newer run's job reviews its
   sample: one sample is one live job. `GET /api/v1/jobs` lists review jobs unless asked
   `?kind=calibration`, `?kind=proposal` or `?kind=all`. Runs are of the `eval` samples (see
   [Held out](#held-out)); `{"split": "pool"}` asks for a run of the pool instead, whose scores give
   rubric proposals evidence and are never in an aggregate.
4. **Read.** When the agent submits, its draft is scored against the sample, and kept with the
   job; a draft that cannot be scored is marked `unscorable`, with why, once.
   `GET …/calibration/runs/{id}` shows each sample's result and the run's aggregate,
   `GET …/calibration/runs` every run's aggregate over time, and `GET …/calibration/summary` the
   aggregate over all runs, and by the rubric version the jobs were reviewed against — so that a
   rubric change can be judged by whether the numbers moved. A deleted sample's scores are left
   out of every aggregate, and still shown, marked, in its run.

### Held out

What the agent learns from must not be what it is measured by. So every sample is assigned, once,
to `eval` or to the `pool`: by a stable hash (FNV-1a) of its pull request (`owner/name#pr`)
against the repository's `evalShare` (`PUT /api/v1/repos/{owner}/{name}`, 0 to 100, 50 by
default, versioned with the other settings). By pull request, not by review: two reviewers of one
pull request, or two rounds of it, say much of the same, and one must not teach what the other
tests. A new sample of a pull request that has a split already takes it. The split is stored on
the sample (`split`) and never changes: a new share splits only the pull requests that come after
it. A sample imported before splits existed is given one the first time it is read — for a run,
an example or a proposal, and for a run, the list of runs or the summary (`GET …/calibration/runs`,
`…/runs/{id}`, `…/summary`); nothing is written when every sample has one.

- **Runs** are of `eval` samples, and every aggregate is of `eval` samples only. A run of the pool
  must be asked for (`"split": "pool"`).
- **What the agent learns from** is the pool and the review jobs, never `eval` — and of the pool,
  never a sample of a pull request that has an `eval` sample (which samples stored while the split
  was by review may have): the examples of style ([Review style](#review-style)), a rubric
  proposal's misses, unmatched comments and pool aggregates, and its people's edits, which are of
  posted review jobs of pull requests with no `eval` sample ([Rubric proposals](#rubric-proposals)).
- **Derived scores.** Every rubric version records what it was derived from (`derivedFrom`, the
  samples, and `derivedFromPulls`, their pull requests): the pull requests the context of the
  proposal it came from drew on — its misses, its unmatched comments, its people's edits — and
  every earlier version's, since a person's edit of a derived rubric may keep what it learned.
  Each version of the style notes records the same (kept by name, so a delete and a registration
  again keep it), and each job records the notes version its agent was given when it read the job
  (`notesVersion`), as it records its `rubricVersion`. A score whose sample's pull request is in
  the set of its job's rubric version or notes version is `derived` (`scoreDerived` in a run's
  results) — a sample of that pull request imported later too: left out of aggregates unless asked
  (`?derived=include`), and counted (`derivedScores`), like a stale one. What it guards: the split
  keeps eval out of what the agent learns from; this keeps what a rubric or the notes learned from
  out of what measures them, wherever it came from — the pool when an eval sample of its pull
  request arrives later, a pull request's posted reviews, samples split before the split was by
  pull request. It holds for every way a proposal reaches the rubric or the notes: accepting it,
  or saving a rebased version with `fromProposal` ([Rubric proposals](#rubric-proposals)). A
  rubric or notes a person writes from what they read of a proposal without naming it is beyond
  what the platform can know.

### What the numbers mean

The agent's and the person's inline comments are paired one to one, greedily, closest first: two
comments can pair when they are on the same file and their line ranges overlap or are at most 3
lines apart.

- **precision** — paired agent comments over all agent comments: how much of what the agent says
  is on something the person also commented on. Also given **per category** and **per severity**
  of the agent's comments, which shows whether, say, its `blocker`s land more often than its
  `nit`s.
- **recall** — paired person comments over all person comments: how much of what the person
  raised the agent found.
- **decision agreement** — whether the agent's decision is the person's (`APPROVED`,
  `CHANGES_REQUESTED`, `COMMENTED`), with the full agent-by-person matrix; a `DISMISSED` review is
  not compared.
- the **pairs**, and the comments left unpaired on each side, to read what was missed and what
  was extra.

Precision and recall, overall and by category and severity, are of `full` samples only
(`commentsScored` of the `scored` jobs); a `partial` or `decision` sample has none of its own, and
counts for its decision. Aggregates add counts first and divide last, so every comment weighs the
same, however many its review had. Ratios are to four decimals, and `null` when there is nothing
to divide by.

### Their limits

- **Pairing is by place only.** Two comments on the same lines may say different things, and two
  that say the same may be a screen apart; a comment the person put on the call site and the agent
  on the definition is a miss on both sides. Read precision and recall as how often the agent
  looks where a person looks, not as how often it is right. Every score records the
  `matcherVersion` that made it, and every pair is named by its two comments' ids (`key`), so a
  later judge of what the comments say can add a verdict per pair, and a new matcher scores of its
  own version, beside the old ones and never over them; only scores of the current version are
  aggregated, and the workers score every job again when it changes.
- **A person's review is not ground truth.** People skip what is fine, comment on what an agent
  is told not to, and spread one review over several. An agent comment with no pair may be right,
  and a person's that the agent missed may be a matter of taste. Few samples make for noisy
  numbers.
- **What git still shows.** The narrowing closes GitHub's API to the agent, not git. The task's
  checkout is the repository's default branch, which for a merged pull request already holds the
  change as it was merged — after the review, often with what the reviewer asked for — and the
  agent could fetch the pull request's later commits too. It is told to read only the diff and
  the reviewed commit; nothing enforces it until orchestra can check a task out at a given commit,
  which the platform will then ask for (`checkout`, a TODO in `Workers.queuePending`).
- **A job is bound by its pull request, not by itself.** kleis lets an agent's requests through
  for its task's repository and pull request, and the job is the one it names (`--job`). Of the
  active jobs at one commit only the one made last (to the second) is answered, and a run never
  gives a sample to two live jobs, so an older run of a commit cannot take over a newer one; but
  an agent could still name an active job of another commit of the same pull request. Closing
  that needs kleis to bind the job header to a fact of the task (its orchestra `external_id`).
- **Groups are merged as they come.** A review of a commit imported after a run scored its sample
  joins the sample; the earlier score stays as it was, against the sample as it was then, and is
  marked `stale` (`scoreStale` in the run's results). Aggregates leave stale scores out and say how
  many there were (`staleScores`); `?stale=include` on `…/runs`, `…/runs/{id}` and `…/summary`
  takes them in. A fresh score needs a fresh run of the sample.
- **The base is reconstructed.** It is the merge base of the base the closed pull request has now
  and the reviewed commit, which is the base GitHub's diff showed for any history but a rewritten
  base branch. A reviewed commit that a force-push left unreferenced may be gone from GitHub: it
  cannot be compared, and its reviews are counted as `unreachable` rather than stored, so a
  repository that force-pushes during review loses those samples.

## Review style

How a repository's reviews are written — how long a comment is, how direct, whether it suggests
or asks — is easier to show than to describe, so the agent is shown, and told the rest.

- **Examples.** `agent show` gives the agent `examples`: up to 20 inline comments the
  repository's trusted reviewers wrote, taken from its `pool` calibration samples (import some
  first; see [Calibration](#calibration)), each its text and the category calibration paired it
  with when it was paired with one of the agent's comments (otherwise `null`) — no file, no lines,
  nothing to go and look up. The prompt and the instructions tell the agent to write in their style — their length,
  their tone, how directly they say what to change — and not to copy them.
- **Which.** Of the `pool` samples not deleted whose reviewer is still trusted, and whose pull
  request has no `eval` sample, the `full` and
  `partial` ones submitted before the review the job is — for a calibration job, before its
  sample's review; for a review job, before the job was made — and of their comments those of 20
  to 600 characters. Picked greedily for variety: each
  pick prefers a file not shown yet, then a category not shown yet, then the scope and the length
  (under or over 160 characters) shown less, then a sample not used yet, ties going to the most
  recently reviewed. Deterministic: the same samples give the same examples.
- **Never the pull request under review.** Every sample of the job's pull request is left out. For
  a calibration job that is the sample it is scored against and any other review of the same pull
  request, so the human review it is scored against never reaches the agent.
- **Style notes.** `PUT /api/v1/repos/{owner}/{name}` takes `styleNotes`, markdown of at most 16
  KiB the operator writes — what the examples cannot show: "one sentence a comment", "no
  praise", "suggest, don't ask". It is versioned with the other settings (send the `version` you
  read), kept by a write that leaves it out, and cleared by `""`. The agent's `instructions` end
  with it, after the default rubric.

## Rubric proposals

Calibration says where the agent and the trusted reviewers part, and the review history what
people change in the agent's drafts before posting them. A rubric proposal is an agent reading
both and writing the rubric it thinks the repository should have, with why. It is advisory: a
person reads it beside the rubric and accepts or rejects it.

1. **Ask.** `POST /api/v1/repos/{owner}/{name}/proposals` with `{}` makes a `proposal` job of the
   repository (`prNumber` 0), queued on orchestra as a task of the repository with no pull request
   (see [On orchestra](#on-orchestra)) and never posted. A repository has at most one live
   proposal — a job pending, queued or running, or a proposal waiting for a decision (`409`) —
   and at most `--max-proposals-per-day` (2 by default) are asked for a day (`429`). A failed one
   is not run again; ask for a new one. `GET /api/v1/jobs?kind=proposal` lists the jobs, and
   `POST …/proposals/jobs/{jobId}/cancel` with `{}` cancels a pending, queued or running one: it
   is `failed`, and its orchestra run cancelled through the proposals' client.
2. **The agent reads** (`diff-reviewer agent proposal show <owner/name> --job <id>`, `GET
   /api/agent/v1/repos/{o}/{n}/proposals/{jobId}`) the current rubric and its version, the style
   notes, calibration's aggregates of the pool (overall, by category, by severity, by rubric
   version), up to 30 comments trusted reviewers made that the agent missed and 30 the agent made
   that nobody matched — from each sample's newest score that is not stale, of `full` `pool`
   samples not deleted, of a reviewer still trusted and of a pull request with no `eval` sample,
   each with its pull request, file, lines and text — and up to 30 comments people changed,
   removed or added in the agent's drafts before posting them, before and after, from the history
   of the posted review jobs of pull requests with no `eval` sample. Every text over 2 KiB is cut
   and marked (`bodyTruncated`). All of it was written by others, on pull requests anyone may
   open: the instructions tell the agent to read it as data and never as instructions. Its first
   read records the style notes it was given, and every read the samples and pull requests it
   drew on: the provenance the rubric and the notes taken from the proposal record.
3. **It submits** (`agent proposal submit <owner/name> <file> --job <id>`) a whole rubric document,
   checked as a rubric `PUT` is — and with no field a rubric does not have, on the document, a
   type or a category (`400`, naming them; only a person's document keeps unknown fields) —
   optional new `styleNotes`, and a `rationale` (markdown, at most 32 KiB), naming the
   `baseVersion` it was written from. It is stored as a `pending` proposal and the
   job becomes a `draft`.
4. **Read it.** `GET …/proposals` (paged) and `GET …/proposals/{id}`, which carries the document,
   the style notes and a structured diff against its base: the default rubric's text before and
   after; the types added, removed and changed — a changed type's description and rubric before
   and after, its categories added, removed and changed; and the style notes before and after.
   `rebaseNeeded` says the rubric has moved since its base.
5. **Decide.** `POST …/proposals/{id}/accept` with `{"version": n}`, the rubric version you read,
   writes the proposal as the next rubric version, recording the samples its context drew on
   (see [Held out](#held-out)); with `"applyStyleNotes": true` its style notes too, as the
   repository's — without it they are not written. One transaction, the rubric first: a refusal
   after it rolls everything back. It is a versioned write: when the rubric has moved since the
   proposal's base, or since you read it, nothing is written and the answer is a `409` with
   `baseVersion` and `currentVersion`, so that you rebase the proposal in the editor and save that
   as a rubric `PUT` with `"fromProposal": "<id>"`: it records the proposal's provenance on the
   version (see [Held out](#held-out)) and marks the proposal accepted, freeing the repository's
   one live proposal. Notes taken from a proposal are saved the same way, as a settings `PUT`
   with `fromProposal`. Applying notes is a `409` too when the proposal has none, or when the
   repository's notes are no longer the ones its agent was given at its first read of its context
   (the snapshot is taken then, not on submission).
   `POST …/proposals/{id}/reject` with `{}` records the decision and writes nothing else.

## Fan-out

A rubric with many categories asks one run to keep all of them in mind, and those it reaches last
get the least of it. A pull request type that sets `"fanout": true` — or the document, beside its
`defaultRubric`, for every review — is reviewed by **sub-runs** instead: one per category, each told
to look at its category only and to file every comment under it, and one by the default rubric for
what no category covers. Each is an orchestra task of its own.

```json
{"version": 3, "defaultRubric": "…", "prTypes": [
  {"name": "feature", "fanout": true, "categories": [{"name": "correctness"}, {"name": "naming"}]}]}
```

- **The type is fixed per repository.** The agent picks a pull request's type while it reviews it,
  which is too late: the sub-runs, one per category of the type, are queued before any agent has
  read the change. Of the ways out — a cheap classifying run first, then the fan-out; fanning out
  by the default rubric's categories, which it has none of; the operator fixing the type — the last
  is the simplest that is correct: nothing runs twice, nothing waits, and the type is known when
  the job is queued. `PUT /api/v1/repos/{owner}/{name}` takes `"prType": "feature"` (a type of the
  current rubric; `""` for none). The agent is then shown that type and must submit it, fanned out
  or not. Without a fixed type, a type's `fanout` does nothing — the agent picks and reviews in one
  run — while the document's fans every review out over every category of the document, as a
  review of no type may use. A fixed type the rubric has since dropped is not fixed.
- **Sub-runs.** Queueing makes them in one transaction with the check of the day's cap, and the
  job becomes `queued` with no queue entry of its own; `running` once a sub-run starts. Each is
  queued under `<job>.<key>`, its key made of its category's name (`default` for the default
  review), and its prompt names it so: `--job <job>.<key>`, sent as `X-Diff-Reviewer-Job`. The
  agent API binds every request to the job and the sub-run: the job alone is refused (`409`), and
  a sub-run must be queued or running. `agent show` gives it the rubric version the job fanned out
  under, its scope (`subRun`, and at the end of its `instructions`) and the type (`prType`). Its
  submission is a partial review, checked as a review is, with every comment of its category for a
  category's sub-run, and kept on the sub-run. A run that ends without a submission is run once
  more (`<job>.<key>.2`, which its agent is named by too), charged against the day's cap like the
  first — past it, the sub-run fails instead; then the sub-run has failed. A run given up on may
  still submit, and the run that replaced it is then cancelled. The sub-runs are those of the job's
  current attempt (`fanoutRound`): a job run again — fanned out anew, or as one run when the rubric
  no longer fans out — leaves the old round as history, shown nowhere and naming nothing. The job's answers show its sub-runs
  (`subRuns`): key, category, status, attempts, error, how many comments.
- **The merge.** When every sub-run has submitted or failed, their reviews are merged into the
  job's draft — the agent's one revision, which a calibration job is scored on — and it goes on as
  any draft: edited, approved, posted (at once, as a comment, in a `direct` repository). The
  comments are the union, the default's first and then each category's in the rubric's order. Two
  are one when they are on the same file, their lines overlap, and their bodies are near-identical
  — of all the words of the two (lower case, letters and digits), at least four fifths are in both
  — and the more severe is kept, in the first's place. Ids stay unique: a later comment repeating
  an id is given a fresh one. The summary is the default's, then each category's after its name;
  a sub-run that failed is named as not reviewed. The decision is the strictest — a request for
  changes, then a comment, then an approval — and never an approval when a sub-run failed. Past
  200 comments, the least severe are dropped first (no severity counting as the least), the last
  first, and the summary says how many of which. When every sub-run failed, the job fails.
- **Spend.** Every sub-run counts against the day's cap — `--max-jobs-per-day` for a review, in
  place of the one its job counted for; `--max-calibration-jobs-per-day` for a calibration job,
  whose run is charged for every sub-run it will make (`429` past it). Past the cap a fan-out
  waits, `pending`, saying why. A repository's `maxFanout` (8 by default, 1 to 51) bounds the
  sub-runs of one review, the default's among them: a review that would make more fails, saying
  so — raise it, or fix a type with fewer categories. Running a failed job again fans it out anew.
- **Rubric proposals** show a change of `fanout`, of the document or of a type, in their diff: a
  proposal that turns fan-out on multiplies what reviews cost, and one that turns it off drops
  what a person set.
- **Calibration** jobs fan out as review jobs do — each sub-run narrowed and told it is not
  posted — and are scored on the merged draft.

## Incremental re-review

A pull request that moves on after its review was posted does not need the whole review again: the
agent is asked for the changes since, told what was already said, and the review posted names the
one it follows.

- **When.** Queueing decides it, for a review job: if a review job of another head of the same pull
  request is `posted` (the newest such), and GitHub's compare of that head with the new one says
  `ahead` — the old head is an ancestor of the new — the job is incremental. It records the posted
  job (`previousJob`), the head that review was of (`incrementalSince`) and the commits since
  (`incrementalCommits`, the newest 100, each message at most 1000 characters), and the diff
  between the two heads is fetched and kept like any diff. The decision is made once for the
  job's head and kept on the job: a job waiting on anything else does not ask GitHub again on
  every pass. Calibration jobs are never incremental.
- **A force-push** — the old head not an ancestor of the new (`diverged`, `behind`) — falls back to a
  full review, and the job says why (`fullReviewReason`); so does an old head GitHub refuses to
  compare (it may be gone), and a diff since too large. GitHub not answering, or its rate limit,
  leaves the job `pending` with why, recorded once, as any other read queueing waits on.
- **What the agent gets.** `agent show` adds `incremental`: the head it follows, the earlier review
  as GitHub holds it (`postedReview`, without the platform's hidden marker) with the inline
  comments it was posted with, the commits
  since, and the command for their diff, `diff-reviewer agent diff <owner/name> <pr> --since <sha>
  --job <id>` (`GET /api/agent/v1/repos/{o}/{n}/pulls/{pr}/diff?since=<sha>`; `since` must be the
  job's own `incrementalSince`, or the answer is a `400` naming it). The prompt and the
  instructions ask it to review the changes since, not to repeat a point the earlier review made,
  and to say in the summary which of those points the new commits resolve. A [fan-out](#fan-out)'s
  sub-runs of an incremental review are told the same.
- **Only the new lines.** Every inline comment must lie in a hunk of the diff since — and, as
  always, of the pull request's diff, since GitHub takes comments only there: a submission off it
  is a `400` saying which hunks there are, and posting checks it again — strictly: when the diff
  since cannot be read, the post is refused rather than made unchecked.
- **The draft** ends with a line naming the earlier review and linking it on GitHub ("Follow-up
  to [the earlier review](…) of <sha>: this review covers the commits since."), unless the body
  links it already: added when the agent's review — or a fan-out's merge — is drafted, so that a
  person reads, edits and approves it with the rest. It is left out when it would take the body
  past what GitHub takes (65536 characters).
- **Off.** `PUT /api/v1/repos/{owner}/{name}` with `"incremental": false` reviews every head in
  full; it is on by default — repositories registered before it included — and kept by a write
  that leaves it out.

## Tests

```sh
lake test
```

The suite covers the review format, the job transitions, that the migrations build the declared
schema and bring an old database up to date, the credentials (each reaches only its own routes)
and the login rate limit per address, a review's whole life over the API, the workers —
discovery, its cap and cancellations, queueing, following, posting once whatever GitHub answers,
direct mode, settling claims on their own and posting a direct review again at most three times —
against a fake GitHub and a fake orchestra, rubrics and their versions, the agent's submission
checked against them, comment ids and unknown fields kept through every round trip (of reviews and
rubrics), the history of a review from draft to post, the checks of a review against its diff,
the agent CLI against the server on loopback, calibration — trusted reviewers as a versioned
setting, the import of past reviews (what it keeps and drops, idempotence, deleted samples, the rate
limit and the budget of a pass), the matcher, runs and their cap, calibration jobs left alone by
discovery and never posted by any path, and the aggregates — learned style — the examples
picked for variety and never of the pull request under review, the style notes as a versioned
setting — rubric proposals — one live a repository and a cap a day, queued with no pull request
through their own client, what the agent reads and submits, the diff, accepting as a versioned
write that asks for a rebase when the rubric has moved and rolls back whole, the style notes
applied only when asked and only over the notes the agent read, rejecting, cancelling, unknown
fields refused, `fromProposal` keeping provenance — the held-out split by pull request, fixed
once made, held-out pull requests teaching nothing, and derived scores, by rubric and notes
version and by pull request, left out; the two agent tokens kept apart; the platform's
own posts kept out of the samples; the job header required — fan-out: planned from the fixed type or the document, queued as sub-runs
under their own external ids and cancelled with their job, each bound to its job and itself on the
agent API, merged by the rules above, one failing and all failing, run again, `maxFanout` and the
day's cap, and calibration scored on the merged draft — incremental re-review: the context of the
posted review and the commits since, the diff since bound to the job, comments only on it, the
follow-up line in the draft, posting refused unchecked, the decision made once, a force-push and
a refused compare reviewed in full, GitHub not answering waited on once, and the setting — and
that `docs/openapi.json`
documents exactly the routes the server answers. Nothing in it reaches the network.

`docs/openapi.json` is embedded in the binary with `include_str`, and Lake rebuilds a module when
its own source changes, not when a file it includes does: after editing the spec, touch
`DiffReviewer/Server.lean` in a way that changes it, or delete its build output
(`rm .lake/build/lib/lean/DiffReviewer/Server.* .lake/build/ir/DiffReviewer/Server.*`), so that
it is embedded again.

## License

Apache 2.0.