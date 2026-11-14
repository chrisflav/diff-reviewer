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
  *following the rubrics* reads the head of the [rubrics repository](#rubrics)'s branch;
  *discovery* makes a job for every new head of an open pull request of a repository with
  `autoReview` (GitHub draft pull requests wait until they are ready; at most
  `--max-jobs-per-day` a repository), and makes every job of an older head `stale`, cancelling its
  orchestra run if it has one; *queueing* checks a `pending` job's head is still the pull
  request's, fetches its diff (past `--max-diff-bytes` the job `failed`s) and puts it on
  [orchestra](https://github.com/chrisflav/orchestra) as an API client; *following* reads the
  queue entry and moves the job to `running`, or to `failed` when the run ends without a review;
  *rubric proposals* open their pull requests and follow them; *settling* settles every claim to post that is past its window, as
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
- **Rubrics**, in a git repository of their own (`DIFF_REVIEWER_RUBRICS_REPO`): per repository, a
  default rubric and the kinds of pull request its reviews tell apart, each with its own rubric and
  categories, and the style notes, which the agent reviews by at the commit its job is pinned to.
  The platform only reads them (`/api/v1/repos/{owner}/{name}/rubrics`). See [Rubrics](#rubrics).
- **A review's history** (`GET /api/v1/jobs/{id}/revisions`): every write of a job's review — the
  agent's submission, each edit, and what GitHub holds once it is posted — kept with who wrote it.
  The agent's draft beside what was posted is what calibration will learn from. It is bounded: the
  agent's first draft, every revision GitHub holds, and the last 100 are kept. It and the rubric's
  history are paged (`?limit=…&offset=…`, 50 by default).
- **Calibration** (`/api/v1/repos/{owner}/{name}/calibration/…`): the agent's reviews of past
  commits, scored against the reviews the repository's trusted reviewers wrote of the same commits.
  See [Calibration](#calibration).
- **Learned review style**: the agent is shown inline comments the trusted reviewers wrote, to
  write in their style, and the style notes, `style.md` beside the rubric. See
  [Review style](#review-style).
- **Rubric proposals** (`/api/v1/repos/{owner}/{name}/proposals`): an agent reads the calibration
  data and the people's edits of the agent's drafts and proposes a rubric, which the platform opens
  as a pull request on the rubrics repository, for a person to merge or close. See
  [Rubric proposals](#rubric-proposals).
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
DIFF_REVIEWER_RUBRICS_REPO=chrisflav/review-rubrics \
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
| `DIFF_REVIEWER_RUBRICS_REPO` | The rubrics repository, `owner/name` (`chrisflav/review-rubrics`), read through the GitHub token: see [Rubrics](#rubrics). Unset, reviews have no rubric and there are no rubric proposals (it logs this once). |
| `DIFF_REVIEWER_RUBRICS_BRANCH` | The branch whose head is the rubrics in use, and that rubric proposals' pull requests are opened into; `main` by default. |
| `DIFF_REVIEWER_RUBRICS_MAPPING` | An export's mapping of old rubric versions to commits, loaded on start-up (see [Moving the rubrics out of the database](#moving-the-rubrics-out-of-the-database)). |
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
(`POST /api/v1/queue/{id}/cancel`).

**Each review is checked out at its head.** A review's request (and each fan-out sub-run's)
carries `"checkout": {"commit": "<head>", "fetch_ref": "refs/pull/<n>/head"}`: orchestra fetches
the commit and checks the task out at it, on a detached `HEAD`, before the agent starts, so a
read-only agent never has to fetch it itself. A [calibration](#calibration) job's adds
`"isolate": true`; a rubric proposal's carries none, and reads the default branch. Orchestra
refuses (`400`) a checkout on its `landrun` and `local` execution backends, which run a
repository's hooks on the host, unless `execution.allow_checkout_hooks_on_host` is set, and
`isolate` on `local` at all: run reviews on `kubernetes`. Such a refusal fails the job with
orchestra's reason (any other `400` leaves it `pending`, as above), and it can be run again once
that is fixed. A run whose commit cannot be had — one a force-push left unreachable from the pull
request's head ref — fails on orchestra, and the job's `error` says the checkout may be why; a
calibration job is checked for that before it is queued, and runs without a checkout instead (see
[Their limits](#their-limits)).

**Upgrading.** `checkout` needs orchestra with per-task checkouts (orchestra PR #222): an older
orchestra refuses the field (`400`), and every review and calibration job then stays pending
with that reason recorded. On orchestra's `landrun` or `local` execution backends every checkout is refused unless
the operator sets `execution.allow_checkout_hooks_on_host` (which runs a pull request's hooks on
the host, so only for a deployment where everyone who can open a pull request is trusted), and
`isolate` is refused on `local` whatever it says: so on those backends every review and
calibration job fails. Run the platform's tasks on `kubernetes`.

The agent needs `curl` and the `diff-reviewer` binary from a release on its `PATH`: see the next
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
`"services: diff-reviewer"`, as a calibration job's does: nothing of GitHub, since orchestra
resets the default branch itself. The platform follows and cancels a
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
- **The rubrics repository.** The same token reads it, and opens rubric proposals' pull requests
  on it. A private one (`chrisflav/review-rubrics` is) needs the fine-grained PAT behind kleis to
  include it, with **Contents: read** — and, for proposals only, **Contents: write** and **Pull
  requests: write**. These are every request the platform makes of it (`{o}/{n}` the rubrics
  repository, `{branch}` its branch):

  | Method | Path | What for |
  | --- | --- | --- |
  | `GET` | `/repos/{o}/{n}/git/ref/heads/{branch}` | the branch's head, every pass (`404`, `409`: none) |
  | `GET` | `/repos/{o}/{n}/git/commits/{sha}` | a commit's tree |
  | `GET` | `/repos/{o}/{n}/git/trees/{sha}`, `…?recursive=1` | the trees down to a directory, and its files |
  | `GET` | `/repos/{o}/{n}/git/blobs/{sha}` | a file (`Accept: application/vnd.github.raw+json`) |
  | `GET` | `/repos/{o}/{n}/commits?sha={branch}&path={owner}/{name}&per_page=…&page=…` | a rubric's history |
  | `POST` | `/repos/{o}/{n}/git/trees` | a proposal's tree, over its base's (Contents: write) |
  | `POST` | `/repos/{o}/{n}/git/commits` | a proposal's commit (Contents: write) |
  | `POST` | `/repos/{o}/{n}/git/refs` | its branch, `refs/heads/diff-reviewer/proposal/<owner>/<name>/<id>` (Contents: write) |
  | `GET` | `/repos/{o}/{n}/pulls?head={o}:{branch}&state=all` | the pull request of a proposal's branch, after a lost answer |
  | `POST` | `/repos/{o}/{n}/pulls` | a proposal's pull request (Pull requests: write) |
  | `GET` | `/repos/{o}/{n}/pulls/{number}` | whether it was merged or closed |

  The writes are only ever to a branch under `diff-reviewer/proposal/`, and a pull request from
  it: the platform never writes to the rubrics branch itself. **Follow-ups, not in this
  repository:** kleis's `diff-reviewer-poster` spec should allow the rubrics repository with
  exactly these routes (the reads above for every repository it lists would be more than needed),
  and restrict `POST …/git/refs` to refs under `refs/heads/diff-reviewer/proposal/`; and the
  deployment (castor's nixos-config, PR #78) must add the rubrics repository to the grant's
  repositories list and set `DIFF_REVIEWER_RUBRICS_REPO` (and `DIFF_REVIEWER_RUBRICS_BRANCH`, if
  not `main`, and `DIFF_REVIEWER_RUBRICS_MAPPING` while the old versions are mapped). Neither the
  `reviewer` nor the `rubric-proposer` spec gets anything of the rubrics repository: agents read
  rubrics only through the platform, and never write them.

## Rubrics

A repository's rubric — the default rubric, the kinds of pull request its reviews tell apart, each
with its own rubric and categories, and its style notes — lives in **one git repository on
GitHub, the rubrics repository** (`DIFF_REVIEWER_RUBRICS_REPO`, say `chrisflav/review-rubrics`),
as a directory per reviewed repository. Git is the record: the platform only reads it, and people
change a rubric by a commit or a pull request there. Every review is pinned to the commit it was
reviewed against.

```
acme/widgets/
  rubric.md            the default rubric; front matter: fanout, types (their order)
  style.md             the style notes
  types/
    feature.md         a pull request type; front matter: description, fanout, categories
    refactor.md
```

`acme/widgets/rubric.md`:

```markdown
---
types:
  - feature
  - refactor
---

Proofs must not use `sorry`. Prefer `simp only` in the middle of a proof.
```

`acme/widgets/types/feature.md`:

```markdown
---
description: Adds new definitions or theorems.
fanout: false
categories:
  correctness: Wrong, or proves the wrong thing.
  naming: Against the naming convention.
  docs: Missing or misleading documentation.
---

Check the names against the naming convention, and that every new definition has a docstring and
the API a user needs.
```

- **The files.** A file is YAML front matter between a first line `---` and the next `---`, and a
  markdown body. `rubric.md`'s body is the default rubric; its front matter may set `fanout` (see
  [Fan-out](#fan-out)) and `types`, the order the types are listed in (those it leaves out follow,
  by name). A type is named by its file, `types/<name>.md`: its front matter has its
  `description`, `fanout` and `categories`, a mapping of each category's name to its description
  in the order they are listed; its body is its rubric. `style.md` is the style notes, the whole
  file (see [Review style](#review-style)). A directory that is not there is no rubric; a missing
  `rubric.md` is an empty default rubric. Front matter keys the platform does not know — of
  `rubric.md`, of a type, or of a category written as a mapping (`docs: {description: …,
  weight: 2}`) — are kept and passed on as fields of the document, the type or the category, so
  that what a newer platform reads passes through an older one. The YAML read is what front matter
  needs: mappings and lists by indentation, plain and quoted strings, `|` and `>` blocks, and flow
  collections written as JSON; anchors, aliases, tags and tabs are refused rather than guessed at.
  The bounds: at most 50 types and 50 categories a type, names of at most 100 characters, rubrics
  of at most 64 KiB, style notes of at most 16 KiB.
- **What to write.** The *default rubric* is what every review of the repository should look at:
  the conventions a maintainer checks first, what the repository cares about and what it does not.
  A *pull request type* is a kind of change that is reviewed differently: its `description` says
  how to recognise it — the agent picks the type by it — and its rubric says what to look at in
  such a change, on top of the default. Its *categories* are what its comments are filed under:
  short names (`correctness`, `naming`, `performance`), with a description of what belongs in each.
  Rubrics are markdown and go to the agent as they are, so write them as you would brief a careful
  new maintainer: concrete checks, not adjectives.
- **Following the branch.** On every pass the workers read the head of
  `DIFF_REVIEWER_RUBRICS_BRANCH` (`main` by default), through the platform's GitHub client — so
  through kleis — and what that commit holds for every registered repository: its commit, its trees
  down to the directory, and the directory's blobs, each commit once, kept in the database per
  commit and repository (a directory whose tree was read at another commit is not read again).
  When it reads, it is the rubric in use. **A head that does not read keeps the last one that did
  in use**, and the API and the front-end show why, by file and line
  (`acme/widgets/types/feature.md:4: 'naming' is given twice`); a review asked for while a
  repository's rubric has never read waits for it, saying so. An empty rubrics repository, or one
  without the branch, is no rubric for anyone: said once in the log and in the API, not retried as
  an error.
- **Pinning.** A job is pinned to the commit in use when it is queued (`rubricSha`; a job pinned
  to none — no rubric — records `rubricVersion` 0, as it always has): its agent reads the rubric,
  the types and the style notes at that commit, never a newer head, and its submission is checked
  against them. A [fan-out](#fan-out)'s sub-runs read their job's commit; a calibration run pins
  one commit for all its jobs when it is made. Running a failed review again pins it anew.
- **How agents use them.** `agent show` gives the agent the default rubric at the end of its
  `instructions`, then the style notes, the types in `prTypes`, each with its rubric and
  categories, and the commit they are of (`rubricSha`). The agent picks the type that fits,
  reviews by its rubric, and gives every comment a `severity` — `nit`, `minor`, `major` or
  `blocker` — and a `category`. Its submission must name one of the types as `prType` (or `null`
  when there are none), and each category must be one of that type's — or is free text when that
  type lists none: the platform refuses anything else, saying what to fix, while the agent can
  still fix it. A person's edit is checked the same way, for the comments whose category it adds
  or changes; a job of no type (reviewed by hand) may use any category of the document, or free
  text if it names none.
- **Reading them.** `GET /api/v1/repos/{owner}/{name}/rubrics` is the rubric in use: the commit
  (`sha`), the branch's head (`headSha`), why they differ (`error`, `errors`), the document, the
  style notes, and each file with where to edit it on GitHub (`files[].editUrl`).
  `GET …/rubrics/history` lists the commits of the branch that changed the directory, with their
  author, date and message; `GET …/rubrics/commits/{sha}` is the rubric at any commit, and
  `GET …/rubrics/compare?base=<sha>&head=<sha>` what changed between two, as a proposal's diff is
  shown. The front-end's rubric page is a viewer of the same, with links to edit the files on
  GitHub. There is no write.
- **Not on GitHub.** Categories and severities are for the platform — reading, filtering,
  calibration, the categories of style examples — and are not part of what is posted: a posted
  review stays in the operator's plain style, which [Review style](#review-style) is how the
  agent learns.

**Merge rights on the rubrics repository are control over reviews.** Everything in it goes into
the agents' prompts: whoever can merge to its branch decides what every review looks at, and what
a review agent is told to do. Protect the branch as you would the platform's own code — required
reviews, no force-pushes — and give write access only to people you would let edit the platform's
prompts. The agents never get write access to it: a review agent reads it only through the
platform, and a [rubric proposal](#rubric-proposals) is written to it by the platform, as a pull
request a person merges.

### Checking a rubrics repository

`diff-reviewer rubrics check <dir>` reads every `<owner>/<name>/` directory of a checkout as the
platform does, prints every error as `file:line: message`, and exits 1 if there is one; a
directory whose name is not a repository's in lower case is one (the platform names repositories
in lower case). Run it in the rubrics repository's CI, so that a pull request that breaks a rubric
is refused before it is merged rather than kept out of use after:

```yaml
# .github/workflows/check.yml in the rubrics repository
name: Check the rubrics
on:
  pull_request:
  push:
    branches: [main]
permissions:
  contents: read
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 # v5.1.0
      - name: Install diff-reviewer
        env:
          VERSION: v0.3.0
          GH_TOKEN: ${{ github.token }}
        run: |
          mkdir -p /tmp/dr
          gh release download "$VERSION" --repo chrisflav/diff-reviewer \
            --pattern "diff-reviewer-$VERSION-linux-x86_64*" --dir /tmp/dr
          (cd /tmp/dr && sha256sum --check "diff-reviewer-$VERSION-linux-x86_64.sha256")
          sudo install -m 755 "/tmp/dr/diff-reviewer-$VERSION-linux-x86_64" \
            /usr/local/bin/diff-reviewer
      - run: diff-reviewer rubrics check .
```

Pin the action by commit, and the release by a tag of one that has `rubrics check` (this one's or
later); the binary is checked against the sha256 the release attaches beside it.

### Moving the rubrics out of the database

Rubrics lived in the database before (`repo_rubric`, and the style notes in `repo_notes`); those
tables are kept, read-only. To move them:

1. `diff-reviewer rubrics export --db reviews.db --out review-rubrics` writes a new git repository
   in the layout above, on branch `main` (`--branch`), with one commit per version — rubric
   versions and style notes versions interleaved in the order they were written, each authored and
   dated when it was written — and the mapping of every version to its commit,
   `review-rubrics.mapping.json` (`--mapping <file>`), with what each commit was derived from. A
   version this build cannot read is left out, and said so. `--out` must not exist, or be empty.
2. Push it to the empty rubrics repository: `git -C review-rubrics remote add origin …` and
   `git push origin main`. Its commits keep their ids.
3. Load the mapping: `diff-reviewer rubrics import-mapping --db reviews.db
   review-rubrics.mapping.json`, or set `DIFF_REVIEWER_RUBRICS_MAPPING` to the file and `serve`
   loads it on start-up (loading it again changes nothing). Old jobs and calibration scores keep
   their integer `rubricVersion`; the API shows the commit it was exported as beside it
   (`rubricSha`), the summary groups their scores under it, and an exported commit carries what
   its version was derived from, so that scores made under it are judged as before.

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
   reviewed as a review job is, with the same prompt and the rubric in use when the run was made
   (one commit for every job of the run, however the branch moves meanwhile) — apart
   from how the code is read, and from being told it is not posted. The prompt and what the agent
   reads name no sample and quote nothing of the person's review, and the task cannot read it
   on GitHub either: its orchestra request carries the kleis narrowing
   `"services: diff-reviewer"` (`kleis_narrow`), so its token reaches nothing of GitHub — no
   REST or GraphQL read, no download, and no git, so it cannot clone the repository or fetch
   `refs/pull/<n>/head` — while the agent API, which gives it the pull request and the diff, is
   not narrowed. A review job's request carries none. The task is checked out at the sample's
   commit, isolated (`checkout` with `"isolate": true`): a repository of that commit and its
   history only, with no branch, no tag, no remote and nothing that came after it, so the agent
   sees neither the pull request's later commits nor the default branch that merged it. Orchestra
   fetches the commit itself, before the task starts, by the pull request's head ref, and checks
   it out only if that ref reaches it; so before a calibration job is first queued the platform
   compares the commit with the pull request's head (`isolated` on the job), and one a force-push
   left behind runs without a checkout (see [Their limits](#their-limits)). A calibration job is
   **never posted**: it cannot be
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
   aggregate over all runs, and by the rubric the jobs were reviewed against (`byRubric`: its
   commit, and for the jobs of before, the version the mapping finds a commit for) — so that a
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
- **Derived scores.** A merged [rubric proposal](#rubric-proposals) records, on its merge commit,
  what its context drew on (the samples, and their pull requests): its misses, its unmatched
  comments, its people's edits. **The rule:** a commit of the rubrics repository carries that
  provenance, for a repository, when its directory `<owner>/<name>/` is the same git tree the
  merge commit left — that is, the merge commit and every later commit of the branch until another
  commit changes the directory (and any commit that brings the directory back to that tree). It is
  decided by the tree's id, which the workers read for every commit a job is pinned to and every
  commit a provenance is recorded on, so it holds whatever way the pull request was merged — a
  merge commit, a squash, a rebase — and whatever else the branch did meanwhile. The rubric and
  the style notes are one directory, so a proposal of either is covered. A score whose sample's
  pull request (or which sample itself) is in the provenance of its job's commit
  (`derivedFrom`, `derivedFromPulls` on the rubric's answer) is `derived` (`scoreDerived` in a
  run's results) — a sample of that pull request imported later too: left out of aggregates unless
  asked (`?derived=include`), and counted (`derivedScores`), like a stale one. What it guards: the
  split keeps eval out of what the agent learns from; this keeps what a rubric or the notes
  learned from out of what measures them, wherever it came from — the pool when an eval sample of
  its pull request arrives later, a pull request's posted reviews, samples split before the split
  was by pull request.
  *What it does not:* a person's later commit to the directory is a new rubric, the person's, and
  carries nothing: if it keeps what the proposal learned, scores under it are not marked. (Before
  rubrics lived in git, every version carried every earlier version's provenance, whoever wrote
  it. That rule keeps every score of a rubric that ever took a proposal out of the aggregates for
  good; this one measures a person's revision as theirs, and needs no ancestry of commits — which
  the platform would have to ask GitHub for, commit by commit.) Nor can the platform know of a
  rubric or notes a person writes from what they read of a proposal without merging it. The jobs
  and scores of before keep the old rule, on the old tables: each rubric version and style notes
  version recorded what it was derived from, and a score is derived by its job's `rubricVersion`
  and `notesVersion`; the export's commits carry each version's provenance too.

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
- **What isolation is not.** The checkout holds within git, and the token reaches nothing of
  GitHub; the agent may still have the network, and where its sandbox lets it past kleis it could
  clone a public repository anonymously. It is told to fetch nothing.
- **A force-pushed sample is not isolated.** A sample whose pull request was rewritten after the
  review has a head that no longer reaches the reviewed commit (GitHub compares them as `behind`
  or `diverged`), and orchestra checks a commit out only if the head reaches it: it would fail
  the run, charged, every time. So such a job (`isolated: false`) is queued without a checkout,
  on the default branch, with the diff-only prompt: it reviews from `diff-reviewer agent diff`,
  reads files with `git show <headSha>:<path>` where the clone has the commit, and is told to
  read no other ref. The default branch may hold the change as it was merged, after the review,
  so its score may be better than a blind review would earn. It is marked in its run, and
  counted unless `?unisolated=exclude` on `…/runs`, `…/runs/{id}` and `…/summary` leaves out the
  scores of every job not isolated (each aggregate says how many, `unisolatedScores`) — those of
  jobs run before checkouts among them.
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
- **Style notes.** `<owner>/<name>/style.md` in the rubrics repository, markdown of at most 16 KiB
  — what the examples cannot show: "one sentence a comment", "no praise", "suggest, don't ask".
  The agent's `instructions` end with them, after the default rubric, as they are at the commit
  its job is pinned to. They live beside the rubric rather than in the settings so that everything
  that shapes a review has one history, and a rubric proposal's notes travel in its pull request
  with its rubric: the provenance of a merge commit covers both (see [Held out](#held-out)), and a
  person who wants the rubric and not the notes drops `style.md` from the pull request before
  merging it. A settings write naming `styleNotes` is refused, saying where they are. (Notes
  written in the settings before are what the export writes as `style.md`.)

## Rubric proposals

Calibration says where the agent and the trusted reviewers part, and the review history what
people change in the agent's drafts before posting them. A rubric proposal is an agent reading
both and writing the rubric it thinks the repository should have, with why. It is advisory: it is
a pull request on the rubrics repository, which a person merges or closes.

1. **Ask.** `POST /api/v1/repos/{owner}/{name}/proposals` with `{}` makes a `proposal` job of the
   repository (`prNumber` 0), queued on orchestra as a task of the repository with no pull request
   (see [On orchestra](#on-orchestra)) and never posted, pinned like a review to the commit of the
   rubrics repository in use. A repository has at most one live proposal — a job pending, queued
   or running, or a proposal whose pull request is open or still to be opened (`409`) — and at
   most `--max-proposals-per-day` (2 by default) are asked for a day (`429`). With no rubrics
   repository, or none read yet, there is nothing to open a pull request on: `409`. A failed one
   is not run again; ask for a new one. `GET /api/v1/jobs?kind=proposal` lists the jobs, and
   `POST …/proposals/jobs/{jobId}/cancel` with `{}` cancels a pending, queued or running one: it
   is `failed`, and its orchestra run cancelled through the proposals' client.
2. **The agent reads** (`diff-reviewer agent proposal show <owner/name> --job <id>`, `GET
   /api/agent/v1/repos/{o}/{n}/proposals/{jobId}`) the rubric and the style notes at the commit its
   job is pinned to (`rubric.sha`), calibration's aggregates of the pool (overall, by category, by
   severity, by rubric), up to 30 comments trusted reviewers made that the agent missed and 30 the
   agent made that nobody matched — from each sample's newest score that is not stale, of `full`
   `pool` samples not deleted, of a reviewer still trusted and of a pull request with no `eval`
   sample, each with its pull request, file, lines and text — and up to 30 comments people
   changed, removed or added in the agent's drafts before posting them, before and after, from the
   history of the posted review jobs of pull requests with no `eval` sample. Every text over 2 KiB
   is cut and marked (`bodyTruncated`). All of it was written by others, on pull requests anyone
   may open: the instructions tell the agent to read it as data and never as instructions. Every
   read records the samples and pull requests it drew on: the provenance the proposal's merge
   records.
3. **It submits** (`agent proposal submit <owner/name> <file> --job <id>`) a whole rubric
   document — `defaultRubric`, `prTypes`, `fanout` — checked as the rubric files are, and with no
   field a rubric does not have, on the document, a type or a category (`400`, naming them; only a
   person's files keep unknown keys), and no type whose name cannot be a file's; optional new
   `styleNotes` (`""` removes `style.md`); and a `rationale` (markdown, at most 32 KiB). A
   `baseSha`, if it names one, must be its job's commit. It is stored as a `pending` proposal and
   the job becomes a `draft`.
4. **It becomes a pull request.** The platform — never the agent — renders the document as files,
   writes them as a commit over the job's commit (a tree over that commit's, by the git data API),
   on the branch `diff-reviewer/proposal/<owner>/<name>/<id>` of the rubrics repository, and opens
   a pull request from it into the rubrics branch, whose body is the rationale. A type the
   proposal drops has its file removed. When GitHub refuses or does not answer, the proposal says
   why (`prError`) and the workers try again on every pass, from where it stopped; a branch or a
   pull request an earlier attempt made is found rather than made twice.
5. **Read it.** `GET …/proposals` (paged) and `GET …/proposals/{id}`, which carries the document,
   the style notes, its pull request (`pullRequest`: number, page, state) and a structured diff
   against its base: the default rubric's text before and after; the types added, removed and
   changed — a changed type's description and rubric before and after, its categories added,
   removed and changed; and the style notes before and after. The pull request itself shows the
   diff of the files.
6. **Decide on GitHub.** Review the pull request as any other: edit its branch, take part of it,
   rebase it on a branch that has moved. **Merged, the proposal is `accepted`; closed unmerged, it
   is `rejected`** — the workers read its state on every pass, and once decided it is followed no
   further. Merging is what changes the rubric: the merge is the branch's head, read on the next
   pass like any other commit. Nothing is accepted or rejected on the platform.

## Fan-out

A rubric with many categories asks one run to keep all of them in mind, and those it reaches last
get the least of it. A pull request type that sets `fanout: true` in its front matter — or
`rubric.md`, for every review — is reviewed by **sub-runs** instead: one per category, each told
to look at its category only and to file every comment under it, and one by the default rubric for
what no category covers. Each is an orchestra task of its own.

```markdown
---
description: Adds new definitions or theorems.
fanout: true
categories:
  correctness: Wrong, or proves the wrong thing.
  naming: Against the naming convention.
---
```

- **The type is fixed per repository.** The agent picks a pull request's type while it reviews it,
  which is too late: the sub-runs, one per category of the type, are queued before any agent has
  read the change. Of the ways out — a cheap classifying run first, then the fan-out; fanning out
  by the default rubric's categories, which it has none of; the operator fixing the type — the last
  is the simplest that is correct: nothing runs twice, nothing waits, and the type is known when
  the job is queued. `PUT /api/v1/repos/{owner}/{name}` takes `"prType": "feature"` (a type of the
  rubric in use; `""` for none). The agent is then shown that type and must submit it, fanned out
  or not. Without a fixed type, a type's `fanout` does nothing — the agent picks and reviews in one
  run — while the document's fans every review out over every category of the document, as a
  review of no type may use. A fixed type the rubric has since dropped is not fixed.
- **Sub-runs.** Queueing makes them in one transaction with the check of the day's cap, and the
  job becomes `queued` with no queue entry of its own; `running` once a sub-run starts. Each is
  queued under `<job>.<key>`, its key made of its category's name (`default` for the default
  review), and its prompt names it so: `--job <job>.<key>`, sent as `X-Diff-Reviewer-Job`. The
  agent API binds every request to the job and the sub-run: the job alone is refused (`409`), and
  a sub-run must be queued or running. `agent show` gives it the rubric at the commit the job
  fanned out under, its scope (`subRun`, and at the end of its `instructions`) and the type (`prType`). Its
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
discovery, its cap and cancellations, queueing with the checkout each task asks for (and a
checkout orchestra refuses, in its own words, failing the job) and the narrowing each kind of job
is queued with, following, posting once whatever GitHub answers,
direct mode, settling claims on their own and posting a direct review again at most three times —
against a fake GitHub and a fake orchestra, rubrics in git — read from a fake rubrics repository
that serves trees, blobs and commits at their shas and takes pull requests: an empty one, each
head as the branch moves, the history and a compare, a broken head keeping the last good rubric
with its errors' files and lines, a job reading the commit it was pinned to while the head moves,
a calibration run's jobs and a fan-out's sub-runs all reading one commit; the files parsed, every
error at its file and line, written back as they read, unknown keys kept; the check of a
checkout; the export of the old versions as a history, and its mapping loaded so that old jobs
find their commits — the agent's submission checked against them, comment ids and unknown fields
kept through every round trip (of reviews and rubrics), the history of a review from draft to post, the checks of a review against its diff,
the agent CLI against the server on loopback, calibration — trusted reviewers as a versioned
setting, the import of past reviews (what it keeps and drops, idempotence, deleted samples, the rate
limit and the budget of a pass), the matcher, runs and their cap, a force-pushed sample run without
isolation and scored apart, calibration jobs left alone by
discovery and never posted by any path, and the aggregates — learned style — the examples
picked for variety and never of the pull request under review, the style notes read from
`style.md` and refused as a setting — rubric proposals — one live a repository and a cap a day,
queued with no pull request through their own client, what the agent reads and submits, opened as
a pull request of a tree, a commit and a branch over the job's commit and nothing else written,
opened again by the workers when GitHub failed, accepted by its merge and rejected by its close,
cancelling, unknown fields refused — runs recording their split — the held-out split by pull
request, fixed once made, held-out pull requests teaching nothing, and derived scores — by the
merge commit's tree, a later head leaving the directory alone still derived and one after a
person's change not, by style notes alone, and by pull request — left out; the two agent tokens kept apart; the platform's
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