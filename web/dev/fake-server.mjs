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
 *
 * Rubrics are versioned per repository as the real server keeps them (`chrisflav/diff-reviewer`
 * has two versions; `chrisflav/unreadable` has one this build "cannot read"), and every write of
 * a job's review is kept in its history. To try a 409 on the rubric page, save from another tab:
 *
 *     curl -X POST 127.0.0.1:8091/__fake/rubric-bump    # someone else saves a new version
 */

import { createServer } from "node:http";
import { randomBytes } from "node:crypto";

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
      id: "c0ffee01",
      category: "correctness",
      severity: "major",
      // A field a newer build writes, which this front-end must pass through untouched.
      confidence: 0.8,
    },
    {
      file: "DiffReviewer/Types.lean",
      start_line: 44,
      end_line: 46,
      body: "The trailing comma moved; keep the list aligned.",
      id: "c0ffee02",
      category: "style",
      severity: "nit",
      suggestion:
        '    ("start_line", c.range.startLine),\n    ("end_line",   c.range.endLine),\n    ("body",       c.body)',
    },
    {
      file: "DiffReviewer/Types.lean",
      start_line: 2,
      end_line: 43,
      body: "This range starts in the first hunk and ends in the second.",
      id: "c0ffee03",
      severity: "blocker",
      category: "<b>correctness</b>",
    },
    {
      file: "DiffReviewer/Platform.lean",
      start_line: 120,
      end_line: 121,
      body: "This file is not in the diff, so this comment is listed apart.",
      id: "c0ffee04",
      severity: "minor",
    },
  ],
};

const jobs = new Map();
const revisions = new Map();
for (const [id, status, prNumber, r] of [
  ["j-draft", "draft", 12, review],
  ["j-failed", "failed", 13, null],
  [
    "j-approved",
    "approved",
    14,
    { ...review, decision: "comment", comments: review.comments.slice(0, 2) },
  ],
  [
    "j-posted",
    "posted",
    15,
    {
      ...review,
      decision: "comment",
      body: "Two things before this goes in.\n\nThe new decision is not read yet.",
      comments: [
        { ...review.comments[0], severity: "blocker", body: "Not read by `Decision.ofJson`." },
        {
          file: "README.md",
          start_line: 2,
          end_line: 2,
          body: "A script tag in the README.",
          id: "c0ffee05",
          category: "docs",
          severity: "minor",
        },
      ],
    },
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
    rubricVersion: status === "failed" ? null : status === "posted" ? 1 : 2,
    directPosts: 0,
    postDirect: false,
    attempts: status === "failed" ? 2 : 1,
    postStartedAt: null,
    postedUrl: null,
    postNote: null,
    postedReview: null,
  });
  const job = jobs.get(id);
  // The agent's draft, and for the posted job the edits and what GitHub holds.
  const revs = [];
  if (r !== null) revs.push(revision(job, 1, "agent", status === "posted" ? review : r));
  if (status === "posted") {
    revs.push(
      revision(job, 2, "person", {
        ...r,
        comments: [r.comments[0], ...review.comments.slice(1, 3)],
      }),
    );
    revs.push(revision(job, 3, "person", r));
    revs.push(revision(job, 4, "github", { ...r, body: `${r.body}` }));
    Object.assign(job, {
      version: 4,
      postedUrl: `https://github.com/chrisflav/diff-reviewer/pull/${prNumber}#pullrequestreview-2`,
    });
  }
  revisions.set(id, revs);
}

function revision(job, version, author, r) {
  return {
    jobId: job.id,
    version,
    author,
    review: structuredClone(r),
    reviewError: null,
    createdAt: new Date(Date.now() - (10 - version) * 60000).toISOString(),
  };
}

// The rubric versions of each repository, oldest first.
const featureType = {
  name: "feature",
  description: "Adds new definitions or theorems.",
  rubric:
    "Check the names against the naming convention, and that every new definition has a docstring.\n\n<script>alert('a rubric is text')</script>",
  categories: [
    { name: "correctness", description: "Wrong, or proves the wrong thing." },
    { name: "naming", description: "Against the naming convention." },
    { name: "style", description: "Formatting and layout." },
  ],
  // A field a newer front-end wrote: kept through every save.
  colour: "green",
};
const rubrics = new Map([
  [
    "chrisflav/diff-reviewer",
    [
      {
        createdAt: now(),
        doc: { defaultRubric: "Proofs must not use `sorry`.", prTypes: [featureType] },
      },
      {
        createdAt: now(),
        doc: {
          defaultRubric:
            "Proofs must not use `sorry`.\nPrefer `simp only` in the middle of a proof.",
          prTypes: [
            {
              ...featureType,
              categories: [
                ...featureType.categories,
                { name: "docs", description: "Missing documentation." },
              ],
            },
            {
              name: "refactor",
              description: "Moves or renames without changing what is proved.",
              rubric: "Check that nothing is lost and that deprecations are added.",
              categories: [],
            },
          ],
          reviewers: ["kim"],
        },
      },
    ],
  ],
  [
    "chrisflav/unreadable",
    [{ createdAt: now(), doc: null, documentError: "unknown field type 'weights'" }],
  ],
]);

function rubricVersion(owner, name, i) {
  const vs = rubrics.get(`${owner}/${name}`) ?? [];
  const v = vs[i];
  if (v === undefined)
    return {
      owner,
      name,
      version: 0,
      createdAt: null,
      defaultRubric: "",
      prTypes: [],
      documentError: null,
    };
  if (v.doc === null)
    return {
      owner,
      name,
      version: i + 1,
      createdAt: v.createdAt,
      defaultRubric: null,
      prTypes: null,
      documentError: v.documentError,
    };
  return { ...v.doc, owner, name, version: i + 1, createdAt: v.createdAt, documentError: null };
}

function currentRubric(owner, name) {
  const vs = rubrics.get(`${owner}/${name}`) ?? [];
  return rubricVersion(owner, name, vs.length - 1);
}

/** Why the document is refused, as `Rubric.validate` says it, or null. */
function rubricProblem(d) {
  if (typeof d.defaultRubric !== "string" || !Array.isArray(d.prTypes)) return "not a document";
  if (d.prTypes.length > 50)
    return `the document names ${d.prTypes.length} pull request types; at most 50`;
  for (const [i, t] of d.prTypes.entries()) {
    if (typeof t.name !== "string" || t.name.trim() === "")
      return `pull request type ${i + 1} has an empty name`;
    if (d.prTypes.filter((u) => u.name === t.name).length > 1)
      return `two pull request types are called '${t.name}'`;
    for (const [j, c] of (t.categories ?? []).entries()) {
      if (typeof c.name !== "string" || c.name.trim() === "")
        return `category ${j + 1} of '${t.name}' has an empty name`;
      if (t.categories.filter((x) => x.name === c.name).length > 1)
        return `'${t.name}' has two categories called '${c.name}'`;
    }
  }
  return null;
}

/** `categoriesFor` of the rubric the job was reviewed against: empty is free text. */
function allowedCategories(job) {
  if (job.rubricVersion === 0) return [];
  const vs = rubrics.get(`${job.owner}/${job.name}`) ?? [];
  const v = job.rubricVersion === null ? vs[vs.length - 1] : vs[job.rubricVersion - 1];
  const d = v?.doc;
  if (d === undefined || d === null) return [];
  const t = d.prTypes.find((x) => x.name === job.prType);
  if (t !== undefined) return (t.categories ?? []).map((c) => c.name);
  return [...new Set(d.prTypes.flatMap((x) => (x.categories ?? []).map((c) => c.name)))];
}

function page(items, url) {
  const limit = Number(url.searchParams.get("limit") ?? 50);
  const offset = Number(url.searchParams.get("offset") ?? 0);
  const slice = items.slice(offset, offset + limit);
  return { items: slice, nextOffset: offset + limit < items.length ? offset + limit : null };
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
  [
    "chrisflav/unreadable",
    { owner: "chrisflav", name: "unreadable", mode: "staged", autoReview: false, createdAt: now() },
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
  const out = bump(job, {
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
  revisions.get(job.id)?.push(revision(job, job.version, "github", job.review));
  return out;
}

function bump(job, change, author = null) {
  Object.assign(job, change, { version: job.version + 1, updatedAt: now() });
  if (author !== null) revisions.get(job.id)?.push(revision(job, job.version, author, job.review));
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
  if (url.pathname === "/__fake/rubric-bump") {
    const vs = rubrics.get("chrisflav/diff-reviewer");
    const last = structuredClone(vs[vs.length - 1].doc);
    last.defaultRubric += "\nSomeone else's line.";
    const feature = last.prTypes.find((t) => t.name === "feature");
    if (feature !== undefined) feature.description += " (Someone else's words.)";
    vs.push({ createdAt: now(), doc: last });
    return send(res, 200, {});
  }
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
  if (parts[2] === "repos" && parts[5] === "rubrics") {
    const [owner, name] = [parts[3].toLowerCase(), parts[4].toLowerCase()];
    if (!repos.has(`${owner}/${name}`))
      return send(res, 404, { error: `${owner}/${name} is not registered` });
    const vs = rubrics.get(`${owner}/${name}`) ?? [];
    if (parts[6] === "history" && req.method === "GET")
      return send(res, 200, page(vs.map((_, i) => rubricVersion(owner, name, i)).reverse(), url));
    if (parts.length === 6 && req.method === "GET")
      return send(res, 200, currentRubric(owner, name));
    if (parts.length === 6 && req.method === "PUT") {
      if (body.version !== vs.length)
        return send(res, 409, {
          error: `the rubric of ${owner}/${name} is at version ${vs.length}, not ${body.version}`,
        });
      if (vs.length > 0 && vs[vs.length - 1].doc === null)
        return send(res, 409, {
          error: "the current version cannot be read by this build; it is left as it is",
        });
      const doc = { ...body };
      for (const f of ["version", "owner", "name", "createdAt", "documentError"]) delete doc[f];
      doc.defaultRubric ??= "";
      doc.prTypes = (doc.prTypes ?? []).map((t) => ({
        description: "",
        rubric: "",
        categories: [],
        ...t,
      }));
      const why = rubricProblem(doc);
      if (why !== null) return send(res, 400, { error: why });
      vs.push({ createdAt: now(), doc });
      rubrics.set(`${owner}/${name}`, vs);
      return send(res, 200, currentRubric(owner, name));
    }
  }
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
    if (action === "revisions") return send(res, 200, page(revisions.get(job.id) ?? [], url));
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
      const stored = job.review?.comments ?? [];
      const allowed = allowedCategories(job);
      for (const [i, c] of (body.review?.comments ?? []).entries()) {
        const was = stored.find((x) => x.id !== undefined && x.id === c.id);
        if (c.category === undefined || (was !== undefined && was.category === c.category))
          continue;
        if (allowed.length > 0 && !allowed.includes(c.category))
          return send(res, 400, {
            error: `'review': comment ${i + 1}: '${c.category}' is not a category of the rubric; it is one of ${allowed.join(", ")}`,
          });
      }
      for (const c of body.review?.comments ?? []) c.id ??= randomBytes(4).toString("hex");
      return send(res, 200, bump(job, { review: body.review, status: "draft" }, "person"));
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