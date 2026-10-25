# diff-reviewer

A platform for agentic reviews of GitHub pull requests (taxis #588), grown out of a small review
tool. Agents draft reviews; you read and edit them against the diff, approve them, and they are
posted to the pull request under your name.

It is built in milestones. This is the first, the skeleton:

- **A review format** (`DiffReviewer/Types.lean`): a decision (comment, approve, request changes),
  a summary, and inline comments on file line ranges with optional suggestions.
- **The platform server** (`diff-reviewer serve`): a REST API over a SQLite database, holding the
  repositories it reviews and one *job* per review of a pull request. A job moves
  `pending → queued → running → draft → approved → posted`; `rejected` is a discarded draft,
  `stale` a draft whose pull request has moved on. `docs/openapi.json` describes the API and is
  served at `/api/openapi.json`.
- **A web front-end** (`web/`): sign in, register repositories, request a review, read a review,
  edit it, approve or reject it. Every write names the version of the job it was made on, so a
  stale page is refused rather than overwriting; queueing, running and posting are the platform's
  own moves, which no request makes.
- **The command-line tools** it started as: `diff-reviewer github` posts a review JSON to a pull
  request with `gh`, and `diff-reviewer from-git` turns a commit range into one.

Next: queueing reviews on orchestra and showing them against the diff (M1), then rubrics,
calibration from past human reviews, and learned review style.

## Running it

```sh
lake build
cd web && npm ci && npm run build && cd ..
DIFF_REVIEWER_PASSWORD='…' .lake/build/bin/diff-reviewer serve --db reviews.db --site web/dist
```

It listens on `127.0.0.1:8090` (`--host`, `--port`). The password is the one you sign in with,
and what scripts send as `Authorization: Bearer <password>`. The server is plain HTTP: put TLS in
front of anything wider than loopback, and pass `--secure-cookie`.

Known limits of this milestone: `/api/login` is not rate-limited, and the password is also the
bearer token for scripts. Both change before the platform posts anything under your name.

During front-end work, `cd web && npm run dev` serves the app with hot reload and proxies `/api`
to the server on 8090 (`DIFF_REVIEWER_URL` to point it elsewhere).

## Tests

```sh
lake test
```

The suite covers the review format, the job transitions, that the migrations build the declared
schema, the API's authentication and a review's whole life over it, and that `docs/openapi.json`
documents exactly the routes the server answers. `docs/openapi.json` is embedded in the binary:
after editing it, touch `DiffReviewer/Server.lean` in a way that changes it, or delete that
module's build output, so that it is embedded again.

## License

Apache 2.0.