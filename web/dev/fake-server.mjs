/**
 * A stand-in for `diff-reviewer serve`, to work on the front-end without the backend:
 *
 *     npm run fake                                      # listens on 127.0.0.1:8091
 *     DIFF_REVIEWER_URL=http://127.0.0.1:8091 npm run dev
 *
 * It holds a few jobs in memory (a draft, a failed run, an approved review) and answers the
 * routes the pages call, with the versions, 409s and status moves the real server makes. Any
 * password signs in. Nothing is written to disk.
 *
 * Two switches, for trying what the page does when things go wrong:
 *
 *     curl -X POST 127.0.0.1:8091/__fake/expire          # the session ends: 401 until sign-in
 *     curl -X POST '127.0.0.1:8091/__fake/delay?ms=3000' # writes answer after a pause
 *     curl -X POST '127.0.0.1:8091/__fake/post?outcome=hang' # next post: ok, refuse or hang
 *
 * A claim (a post that may have reached GitHub) is settled by "Check GitHub" as found, posted.
 */

import { createServer } from "node:http";

const port = Number(process.env.PORT ?? 8091);
let signedIn = true;
let delay = 0;
const now = () => new Date().toISOString();

const big = Array.from({ length: 450 }, (_, i) => `+export const n${i} = ${i};`).join("\n");

const diff = `diff --git a/DiffReviewer/Types.lean b/DiffReviewer/Types.lean
index 1111111..2222222 100644
--- a/DiffReviewer/Types.lean
+++ b/DiffReviewer/Types.lean
@@ -1,9 +1,10 @@
 import Lean.Data.Json

 namespace DiffReviewer

 inductive Decision where
   | comment
   | approve
   | requestChanges
+  | dismiss
   deriving Repr, BEq
@@ -40,6 +41,7 @@ def LineRange.ofJson (j : Lean.Json) : Except String LineRange := do
 def InlineComment.toJson (c : InlineComment) : Lean.Json :=
   let fields : List (String × Lean.Json) := [
-    ("file",       c.file),
+    ("file",       c.file),  -- the path on the new side of the diff, which is the one GitHub wants for a RIGHT-side comment and which the agent must therefore never take from the old side
     ("start_line", c.range.startLine),
-    ("end_line",   c.range.endLine)
+    ("end_line",   c.range.endLine),
+    ("body",       c.body)
   ]
diff --git a/README.md b/README.md
index 3333333..4444444 100644
--- a/README.md
+++ b/README.md
@@ -1,3 +1,4 @@
 # diff-reviewer
-
+<script>alert("not run")</script>
+
 Review pull requests with an agent.
\\ No newline at end of file
diff --git a/docs/old name.md b/docs/new name.md
similarity index 100%
rename from docs/old name.md
rename to docs/new name.md
diff --git a/web/src/generated.ts b/web/src/generated.ts
new file mode 100644
index 0000000..5555555
--- /dev/null
+++ b/web/src/generated.ts
@@ -0,0 +1,450 @@
${big}
diff --git a/web/public/logo.png b/web/public/logo.png
index 6666666..7777777 100644
Binary files a/web/public/logo.png and b/web/public/logo.png differ
`;

const review = {
  rubric: { name: "default", version: 2 },
  decision: "request_changes",
  body: "Two things before this goes in.\n\nThe new decision is not handled by `Decision.ofJson`.\n<b>This is not bold.</b>",
  comments: [
    {
      file: "DiffReviewer/Types.lean",
      start_line: 9,
      end_line: 9,
      body: '`Decision.ofJson` does not read "dismiss" yet.',
      // Fields a newer build writes, which this front-end must pass through untouched.
      category: "correctness",
      severity: "major",
    },
    {
      file: "DiffReviewer/Types.lean",
      start_line: 44,
      end_line: 46,
      body: "The trailing comma moved; keep the list aligned.",
      suggestion:
        '    ("start_line", c.range.startLine),\n    ("end_line",   c.range.endLine),\n    ("body",       c.body)',
    },
    {
      file: "DiffReviewer/Types.lean",
      start_line: 2,
      end_line: 43,
      body: "This range starts in the first hunk and ends in the second.",
    },
    {
      file: "DiffReviewer/Platform.lean",
      start_line: 120,
      end_line: 121,
      body: "This file is not in the diff, so this comment is listed apart.",
    },
  ],
};

const jobs = new Map();
for (const [id, status, prNumber, r] of [
  ["j-draft", "draft", 12, review],
  ["j-failed", "failed", 13, null],
  [
    "j-approved",
    "approved",
    14,
    { ...review, decision: "comment", comments: review.comments.slice(0, 2) },
  ],
]) {
  jobs.set(id, {
    id,
    owner: "chrisflav",
    name: "diff-reviewer",
    prNumber,
    headSha: "0123456789abcdef0123456789abcdef01234567",
    status,
    queueEntry: null,
    review: r,
    reviewError: null,
    version: 1,
    createdAt: now(),
    updatedAt: now(),
    baseSha: "89abcdef0123456789abcdef0123456789abcdef",
    title: `Add the dismiss decision (#${prNumber})`,
    prBody: "Adds `dismiss`.\n\n<script>alert('a PR body is text')</script>",
    error: status === "failed" ? "the run ended without a submission" : null,
    prType: status === "failed" ? null : "feature",
    attempts: status === "failed" ? 2 : 1,
    postStartedAt: null,
    postedUrl: null,
    postNote: null,
    postedReview: null,
  });
}

const repos = new Map([
  [
    "chrisflav/diff-reviewer",
    {
      owner: "chrisflav",
      name: "diff-reviewer",
      mode: "staged",
      autoReview: false,
      createdAt: now(),
    },
  ],
]);
// What the next post does: "ok", "refuse" (GitHub says no: 502 with the job) or "hang" (the post
// may have reached GitHub: the claim stays, and the answer is a 502).
let postOutcome = "ok";

const moves = {
  draft: ["approved", "rejected", "stale"],
  approved: ["draft"],
  rejected: ["draft"],
  failed: ["pending"],
};
const editable = ["pending", "draft", "approved", "rejected"];

function send(res, status, body) {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify(body));
}

function posted(job) {
  const url = `https://github.com/${job.owner}/${job.name}/pull/${job.prNumber}#pullrequestreview-1`;
  return bump(job, {
    status: "posted",
    postStartedAt: null,
    error: null,
    postedUrl: url,
    postNote:
      job.review?.decision === "request_changes"
        ? "posted as a comment: GitHub refuses a request for changes on one's own pull request"
        : null,
    postedReview: { id: 1, url, body: job.review?.body ?? "" },
  });
}

function bump(job, change) {
  Object.assign(job, change, { version: job.version + 1, updatedAt: now() });
  return job;
}

async function readJson(req) {
  let text = "";
  for await (const chunk of req) text += chunk;
  return text === "" ? {} : JSON.parse(text);
}

createServer(async (req, res) => {
  const url = new URL(req.url ?? "/", "http://x");
  let parts;
  try {
    parts = url.pathname
      .split("/")
      .filter((p) => p !== "")
      .map(decodeURIComponent);
  } catch {
    return send(res, 400, { error: "malformed path" });
  }
  const body = req.method === "GET" ? {} : await readJson(req).catch(() => null);
  if (body === null) return send(res, 400, { error: "not JSON" });

  if (url.pathname === "/__fake/expire") {
    signedIn = false;
    return send(res, 200, {});
  }
  if (url.pathname === "/__fake/delay") {
    delay = Number(url.searchParams.get("ms") ?? 0);
    return send(res, 200, {});
  }
  if (url.pathname === "/api/session") return send(res, 200, { authenticated: signedIn });
  if (url.pathname === "/__fake/post") {
    postOutcome = url.searchParams.get("outcome") ?? "ok";
    return send(res, 200, {});
  }
  if (url.pathname === "/api/login") {
    if (typeof body.token === "string" && body.token !== "token")
      return send(res, 401, { error: "unauthorized" });
    signedIn = true;
    return send(res, 200, { authenticated: true });
  }
  if (url.pathname === "/api/logout") {
    signedIn = false;
    return send(res, 200, { authenticated: false });
  }
  if (!signedIn) return send(res, 401, { error: "unauthorized" });
  if (req.method !== "GET" && delay > 0) await new Promise((r) => setTimeout(r, delay));
  if (url.pathname === "/api/v1/repos") return send(res, 200, { items: [...repos.values()] });
  if (parts[2] === "repos" && parts.length === 5 && req.method === "PUT") {
    const key = `${parts[3]}/${parts[4]}`.toLowerCase();
    const repo = {
      owner: parts[3].toLowerCase(),
      name: parts[4].toLowerCase(),
      mode: body.mode ?? "staged",
      autoReview: body.autoReview ?? false,
      createdAt: repos.get(key)?.createdAt ?? now(),
    };
    repos.set(key, repo);
    return send(res, 200, repo);
  }
  if (url.pathname === "/api/v1/jobs" && req.method === "GET")
    return send(res, 200, { items: [...jobs.values()] });

  if (parts[0] === "api" && parts[1] === "v1" && parts[2] === "jobs" && parts[3] !== undefined) {
    const job = jobs.get(parts[3]);
    if (job === undefined) return send(res, 404, { error: `no job ${parts[3]}` });
    const action = parts[4];
    if (action === undefined) return send(res, 200, job);
    if (action === "diff") return send(res, 200, { headSha: job.headSha, diff });
    if (body.version !== job.version)
      return send(res, 409, { error: `job ${job.id} is at version ${job.version}` });
    if (job.postStartedAt !== null && (action === "review" || action === "status"))
      return send(res, 409, {
        error: `a post of job ${job.id} (begun ${job.postStartedAt}) may have reached GitHub; it is being checked`,
      });
    if (action === "review" && req.method === "PUT") {
      if (!editable.includes(job.status))
        return send(res, 409, {
          error: `job ${job.id} is ${job.status}; its review is not edited now`,
        });
      return send(res, 200, bump(job, { review: body.review, status: "draft" }));
    }
    if (action === "status" && req.method === "POST") {
      if (!(moves[job.status] ?? []).includes(body.status))
        return send(res, 409, {
          error: `job ${job.id} is ${job.status} and cannot be made ${body.status}`,
        });
      return send(res, 200, bump(job, { status: body.status }));
    }
    if (action === "post" && req.method === "POST") {
      if (job.status !== "approved")
        return send(res, 409, { error: `job ${job.id} is ${job.status}, not approved` });
      if (job.postStartedAt !== null)
        return send(res, 409, {
          error: `posting job ${job.id} began at ${job.postStartedAt} and may still be under way`,
        });
      if (postOutcome === "refuse") {
        bump(job, { error: "posting failed: 422 Unprocessable Entity" });
        return send(res, 502, { error: "GitHub refused the review: 422", job });
      }
      if (postOutcome === "hang") {
        bump(job, { postStartedAt: now() });
        return send(res, 502, {
          error: "GitHub did not answer; the post may have reached it",
          job,
        });
      }
      return send(res, 200, posted(job));
    }
    if (action === "reconcile" && req.method === "POST") {
      if (job.postStartedAt === null)
        return send(res, 409, { error: `job ${job.id} has no post to settle` });
      return send(res, 200, posted(job));
    }
  }
  send(res, 404, { error: "no such route" });
}).listen(port, "127.0.0.1", () => console.log(`fake diff-reviewer on http://127.0.0.1:${port}`));