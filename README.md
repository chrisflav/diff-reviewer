# diff-reviewer

A platform for agentic reviews of GitHub pull requests (taxis #588), grown out of a small review
tool. Agents draft reviews; you read and edit them against the diff, approve them, and they are
posted to the pull request under your name.

It is built in milestones. The first three are here:

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
  (`diff-reviewer agent show|diff|submit … --job <id>`): what the reviewing agent reads and how
  it submits. A submission is checked as GitHub would check it — its comments must be on the
  diff's new side — and becomes a `draft`; in a `direct` repository it is posted at once, always
  as a comment.
- **Posting** (`POST /api/v1/jobs/{id}/post`): an approved review is posted to the pull request
  under the operator's GitHub account, pinned to the job's head commit, as its decision. Only this
  route, a person's, ever approves or requests changes. A review is posted once, even with several
  processes on one database: the attempt is claimed in the database just before the post (in a
  `BEGIN IMMEDIATE` transaction, so one process claims it), a claim is never taken over within
  three times the post's timeout, and the posted body carries a marker
  (`<!-- diff-reviewer job <id> -->`). When GitHub's answer is lost or is a `5xx`, the claim
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
- **A web front-end** (`web/`): sign in, register repositories, request a review, read a review,
  edit it, approve or reject it. Every write names the version of the job it was made on, so a
  stale page is refused rather than overwriting.
- **The command-line tools** it started as: `diff-reviewer github` posts a review JSON to a pull
  request, and `diff-reviewer from-git` turns a commit range into one.

Next: calibration from past human reviews, and learned review style.

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
jobs discovery makes per repository, and `--max-diff-bytes` (default 5242880) the diff reviewed.

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
| `DIFF_REVIEWER_AGENT_TOKEN_FILE` | The bearer of `/api/agent/v1/`, and good for nothing else. Unset, the agent API refuses everything. kleis holds it, never the agent. |
| `DIFF_REVIEWER_GITHUB_TOKEN_FILE` | The token for api.github.com: listing pull requests, reading one and its diff, posting reviews. Unset, there is no discovery, no diff and no posting. In production this is the placeholder `kleis` (see below). Also used by `diff-reviewer github`, which otherwise falls back to `gh auth token`. |
| `DIFF_REVIEWER_GITHUB_LOGIN` | The GitHub login reviews are posted as. **Set it in production.** When a post's outcome is unknown, only reviews by this login count as the platform's: without it, anyone who writes a job's marker into a review of their own could make the platform record that job as posted (it logs this once). And on a pull request this login wrote, GitHub refuses an approval or a request for changes, so such a review is posted as a comment and the job's `postNote` says so. |
| `DIFF_REVIEWER_GITHUB_API` | GitHub's API root, `https://api.github.com` by default. |
| `DIFF_REVIEWER_ORCHESTRA_URL`, `DIFF_REVIEWER_ORCHESTRA_TOKEN_FILE` | Orchestra, and the platform's API client token on it. Without both, jobs stay `pending` (and the log says so once). Orchestra is always reached directly, never through `HTTPS_PROXY` (its host is curl's `noproxy`): the proxy is kleis, there for GitHub, and the orchestra token is not one kleis should see. Add the host to `NO_PROXY` too, for anything else in the environment. |
| `HTTPS_PROXY`, `NO_PROXY`, `CURL_CA_BUNDLE`, `SSL_CERT_FILE` | Every outgoing request is made with `curl`, which reads these as usual (and no `~/.curlrc`: it runs with `-q`). Only `https` is used, or `http` to loopback. |

The three secrets must differ, and each token must be at least 32 characters
(`openssl rand -hex 32`): `serve` refuses to start otherwise.

The agent CLI reads `~/.config/diff-reviewer/agent.json`, `{"url": "https://reviews.example",
"token": "kleis"}`, and `DIFF_REVIEWER_URL` and `DIFF_REVIEWER_TOKEN` override either field.
(`DIFF_REVIEWER_URL` is also where `npm run dev` proxies `/api` to.) The prompt gives the agent
its job id, which it passes as `--job <id>`: with two reviews of one pull request running — an
old head's, not yet cancelled, and the new one's — a request that names none is refused rather
than given the wrong one.

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
retry, since orchestra answers an `external_id` it has seen with the entry it already made. When a
pull request moves on, the platform cancels the runs of its older heads
(`POST /api/v1/queue/{id}/cancel`). The
agent needs `curl` and the `diff-reviewer` binary from a release on its `PATH`: see the next
section.

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
- **The platform's side.** Run `serve` with `HTTPS_PROXY` pointing at kleis (and kleis's CA in
  `CURL_CA_BUNDLE`), and `DIFF_REVIEWER_GITHUB_TOKEN_FILE` holding `kleis`. kleis's
  `diff-reviewer-poster` grant injects the operator's PAT for reading pull requests and posting
  reviews on the repositories it lists, so approved reviews appear under your own name.

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
- **Not on GitHub.** Categories and severities are for the platform — reading, filtering, and
  calibration later — and are not part of what is posted: a posted review stays in the operator's
  plain style. (To be revisited with learned review style, M4.)

Every inline comment has an `id`, short and random, unique within its review: the platform gives
one to each comment written without one, when the review is submitted or edited, and keeps the ones
comments have — so keep them when editing, and a comment can be followed from the agent's draft to
what was posted. A review stored before ids existed gets them on its next write, never on a read.

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
the agent CLI against the server on loopback, and that `docs/openapi.json` documents exactly the
routes the server answers. Nothing in it reaches the network.

`docs/openapi.json` is embedded in the binary with `include_str`, and Lake rebuilds a module when
its own source changes, not when a file it includes does: after editing the spec, touch
`DiffReviewer/Server.lean` in a way that changes it, or delete its build output
(`rm .lake/build/lib/lean/DiffReviewer/Server.* .lake/build/ir/DiffReviewer/Server.*`), so that
it is embedded again.

## License

Apache 2.0.