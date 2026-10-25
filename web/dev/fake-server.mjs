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
 *
 * The repository settings are versioned too, and `chrisflav/diff-reviewer` has calibration data:
 * samples (one deleted, one whose score is stale), an import that went through, and runs over a
 * month, the last still going. A new import moves on as it is read, and pauses once, for half a
 * minute, as one under `--github-reserve` does.
 *
 *     curl -X POST 127.0.0.1:8091/__fake/repo-bump       # someone else changes the settings
 *     curl -X POST '127.0.0.1:8091/__fake/calibration-cap?charged=20' # the daily cap is reached
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
      trustedReviewers: ["alice", "bob"],
      version: 3,
      createdAt: now(),
    },
  ],
  [
    "chrisflav/unreadable",
    {
      owner: "chrisflav",
      name: "unreadable",
      mode: "staged",
      autoReview: false,
      trustedReviewers: [],
      version: 1,
      createdAt: now(),
    },
  ],
]);

/** `validLogin` in Lean. */
const validLogin = (s) =>
  s.length > 0 &&
  s.length <= 39 &&
  !s.startsWith("-") &&
  !s.endsWith("-") &&
  !s.includes("--") &&
  /^[A-Za-z0-9-]+$/.test(s);

/** `putRepo` in Lean: versioned, `trustedReviewers` kept when left out. */
function putRepo(owner, name, body) {
  const key = `${owner}/${name}`.toLowerCase();
  const old = repos.get(key);
  const current = old?.version ?? 0;
  if (body.mode !== undefined && body.mode !== null && !["staged", "direct"].includes(body.mode))
    return [400, { error: `'mode' must be 'staged' or 'direct', not '${body.mode}'` }];
  let trusted = old?.trustedReviewers ?? [];
  if (body.trustedReviewers !== undefined && body.trustedReviewers !== null) {
    const t = body.trustedReviewers;
    if (!Array.isArray(t) || !t.every((l) => typeof l === "string"))
      return [400, { error: "'trustedReviewers' must be an array of GitHub logins" }];
    const bad = t.find((l) => !validLogin(l));
    if (bad !== undefined) return [400, { error: `'${bad}' is not a GitHub login` }];
    if (t.length > 50)
      return [400, { error: `'trustedReviewers' names ${t.length} logins; at most 50` }];
    trusted = [...new Set(t.map((l) => l.toLowerCase()))];
  }
  if (body.version !== undefined && body.version !== null && body.version !== current)
    return [
      409,
      {
        error: `the settings of ${key} have changed since they were read (version ${body.version}, now ${current}); reload them`,
      },
    ];
  const repo = {
    owner: owner.toLowerCase(),
    name: name.toLowerCase(),
    mode: body.mode ?? "staged",
    autoReview: body.autoReview ?? false,
    trustedReviewers: trusted,
    version: current + 1,
    createdAt: old?.createdAt ?? now(),
  };
  repos.set(key, repo);
  return [old === undefined ? 201 : 200, repo];
}

// Calibration: samples, imports, runs and their calibration jobs, of chrisflav/diff-reviewer.
const calib = {
  samples: [],
  imports: [],
  runs: [],
  /** Calibration jobs charged today, against `--max-calibration-jobs-per-day`. */
  charged: 0,
  cap: 20,
};
const files = ["DiffReviewer/Types.lean", "DiffReviewer/Platform.lean", "README.md"];
const day = 86400000;
for (let i = 0; i < 32; i++) {
  const reviewer = i % 3 === 0 ? "bob" : "alice";
  const scope = i % 7 === 3 ? "partial" : i % 5 === 4 ? "decision" : "full";
  const n = scope === "decision" ? 0 : 1 + (i % 4);
  const comments = Array.from({ length: n }, (_, k) => ({
    id: 9000 + i * 10 + k,
    path: files[(i + k) % files.length],
    start_line: 10 + k * 20,
    line: 12 + k * 20,
    body:
      k === 0 && i === 0
        ? "Is this <b>right</b>? <script>alert('a person's comment is text')</script>"
        : `Comment ${k + 1} of the review of #${100 + i}: check the edge case.`,
  }));
  const at = new Date(Date.now() - (i + 1) * day).toISOString();
  calib.samples.push({
    id: `s-${String(i).padStart(2, "0")}`,
    owner: "chrisflav",
    name: "diff-reviewer",
    prNumber: 100 + i,
    reviewIds: [5000 + i],
    reviewer,
    state: scope === "decision" ? "APPROVED" : i % 2 === 0 ? "CHANGES_REQUESTED" : "COMMENTED",
    body:
      scope === "decision"
        ? ""
        : `Thanks. A few things.\n\n<img src=x onerror=alert(1)> is text here.`,
    commitId: (i.toString(16).padStart(2, "0") + "ab").repeat(10),
    baseSha: "89abcdef0123456789abcdef0123456789abcdef",
    title: `Pull request ${100 + i}`,
    scope,
    comments,
    dropped: { left: scope === "partial" ? 1 : 0, outdated: 0, replies: i % 4 === 0 ? 2 : 0 },
    submittedAt: at,
    importedAt: at,
    updatedAt: at,
    deletedAt: null,
    // A review joined it after its first score: that score is stale.
    joinedAt: i === 1 ? now() : null,
  });
}
calib.imports.push({
  id: "imp-1",
  owner: "chrisflav",
  name: "diff-reviewer",
  limit: 50,
  status: "done",
  pullsListed: 40,
  pullsRead: 40,
  failures: 0,
  stats: {
    pulls: 40,
    reviews: 41,
    imported: 32,
    merged: 3,
    known: 0,
    deleted: 0,
    empty: 4,
    unreachable: 1,
    unreadable: 1,
    droppedLeft: 3,
    droppedOutdated: 2,
    droppedReplies: 9,
  },
  error: null,
  requestedAt: new Date(Date.now() - 40 * day).toISOString(),
  updatedAt: new Date(Date.now() - 40 * day).toISOString(),
});

/** The agent's draft of a sample: one comment paired with each of the first `hit` of the person's. */
function agentDraft(s, hit, extra) {
  const comments = [];
  s.comments.slice(0, hit).forEach((c, k) =>
    comments.push({
      id: `a${k}`,
      file: c.path,
      start_line: c.start_line + (k % 2 === 0 ? 0 : 4),
      end_line: c.line + (k % 2 === 0 ? 0 : 4),
      body: `The agent on ${c.path}: <i>handle</i> the empty case.`,
      category: k % 2 === 0 ? "correctness" : "style",
      severity: k % 2 === 0 ? "major" : "nit",
    }),
  );
  for (let k = 0; k < extra; k++)
    comments.push({
      id: `x${k}`,
      file: files[(k + 1) % files.length],
      start_line: 300 + k,
      end_line: 301 + k,
      body: "An extra remark the person did not make.",
      category: "docs",
      severity: "minor",
    });
  return {
    decision: s.state === "APPROVED" ? "approve" : hit > 1 ? "request_changes" : "comment",
    body: "The agent's review.",
    comments,
  };
}

/** `Score.score` in Lean, near enough: pairs by place, within 3 lines. */
function scoreOf(s, draft) {
  const human = [...s.comments];
  const pairs = [];
  const unmatchedAgent = [];
  for (const a of draft.comments) {
    const j = human.findIndex(
      (h) => h.path === a.file && a.start_line <= h.line + 3 && h.start_line <= a.end_line + 3,
    );
    if (j < 0) {
      unmatchedAgent.push(a);
      continue;
    }
    const [h] = human.splice(j, 1);
    const gap = Math.max(0, a.start_line - h.line, h.start_line - a.end_line);
    pairs.push({ key: `${a.id}:${h.id}`, gap, agent: a, human: h });
  }
  const full = s.scope === "full";
  const ratio = (a, b) => (b === 0 ? null : Math.round((a / b) * 10000) / 10000);
  const tally = (field) => {
    const m = new Map();
    for (const a of draft.comments) {
      const k = a[field] ?? null;
      const t = m.get(k) ?? { [field]: k, comments: 0, matched: 0 };
      t.comments++;
      if (pairs.some((p) => p.agent === a)) t.matched++;
      m.set(k, t);
    }
    return [...m.values()].map((t) => ({ ...t, precision: ratio(t.matched, t.comments) }));
  };
  const toState = {
    approve: "APPROVED",
    request_changes: "CHANGES_REQUESTED",
    comment: "COMMENTED",
  };
  return {
    matcherVersion: 1,
    scope: s.scope,
    agentComments: draft.comments.length,
    humanComments: s.comments.length,
    matched: pairs.length,
    precision: full ? ratio(pairs.length, draft.comments.length) : null,
    recall: full ? ratio(pairs.length, s.comments.length) : null,
    byCategory: full ? tally("category") : [],
    bySeverity: full ? tally("severity") : [],
    decision: { agent: draft.decision, human: s.state, agree: toState[draft.decision] === s.state },
    pairs,
    unmatchedAgent,
    unmatchedHuman: human,
  };
}

/** `aggregateOf` in Lean: counts first, ratios last, deleted samples and (unless asked) stale left out. */
function aggregate(results, includeStale) {
  const ratio = (a, b) => (b === 0 ? null : Math.round((a / b) * 10000) / 10000);
  const live = results.filter(
    (r) =>
      r.score !== null && !("unscorable" in r.score) && sampleById(r.sampleId)?.deletedAt === null,
  );
  const staleScores = live.filter((r) => r.scoreStale).length;
  const rows = live.filter((r) => includeStale || !r.scoreStale);
  const full = rows.filter((r) => r.score.scope === "full");
  const sum = (f) => full.reduce((n, r) => n + r.score[f], 0);
  const merge = (field) => {
    const m = new Map();
    for (const r of full)
      for (const t of r.score[field === "category" ? "byCategory" : "bySeverity"]) {
        const k = t[field];
        const o = m.get(k) ?? { [field]: k, comments: 0, matched: 0 };
        o.comments += t.comments;
        o.matched += t.matched;
        m.set(k, o);
      }
    return [...m.values()].map((t) => ({ ...t, precision: ratio(t.matched, t.comments) }));
  };
  const compared = rows.filter((r) => r.score.decision.agree !== null);
  const agreed = compared.filter((r) => r.score.decision.agree).length;
  const matrix = new Map();
  for (const r of compared) {
    const k = `${r.score.decision.agent}|${r.score.decision.human}`;
    matrix.set(k, (matrix.get(k) ?? 0) + 1);
  }
  return {
    matcherVersion: 1,
    scored: rows.length,
    commentsScored: full.length,
    agentComments: sum("agentComments"),
    humanComments: sum("humanComments"),
    matched: sum("matched"),
    precision: ratio(sum("matched"), sum("agentComments")),
    recall: ratio(sum("matched"), sum("humanComments")),
    byCategory: merge("category"),
    bySeverity: merge("severity"),
    decisions: {
      compared: compared.length,
      agreed,
      agreement: ratio(agreed, compared.length),
      matrix: [...matrix.entries()].map(([k, count]) => {
        const [agent, human] = k.split("|");
        return { agent, human, count };
      }),
    },
    staleScores,
    staleIncluded: includeStale,
  };
}

const sampleById = (id) => calib.samples.find((s) => s.id === id);

function sampleJson(s) {
  const out = { ...s };
  delete out.deletedAt;
  delete out.joinedAt;
  return out;
}

/** A calibration job, as `GET /api/v1/jobs` lists it. */
function calibrationJob(run, s, status, createdAt) {
  const id = `cj-${run.id}-${s.id}`;
  const draft =
    status === "draft" ? agentDraft(s, s.comments.length > 1 ? 1 : s.comments.length, 1) : null;
  const job = {
    id,
    owner: "chrisflav",
    name: "diff-reviewer",
    prNumber: s.prNumber,
    headSha: s.commitId,
    status,
    queueEntry: null,
    review: draft,
    reviewError: null,
    version: 1,
    createdAt,
    updatedAt: createdAt,
    baseSha: s.baseSha,
    title: s.title,
    prBody: null,
    error: status === "failed" ? "the run ended without a submission" : null,
    prType: draft === null ? null : "feature",
    rubricVersion: draft === null ? null : run.rubricVersion,
    directPosts: 0,
    postDirect: false,
    attempts: 1,
    postStartedAt: null,
    postedUrl: null,
    postNote: null,
    postedReview: null,
    kind: "calibration",
    sampleId: s.id,
    runId: run.id,
  };
  jobs.set(id, job);
  revisions.set(id, draft === null ? [] : [revision(job, 1, "agent", draft)]);
  return job;
}

/** A run of `ids`, its jobs `status` (scored when `draft`); `ago` days back. */
function makeRun(id, ids, ago, rubricVersion, status = "draft", hits = null) {
  const createdAt = new Date(Date.now() - ago * day).toISOString();
  const run = {
    id,
    owner: "chrisflav",
    name: "diff-reviewer",
    createdAt,
    rubricVersion,
    results: [],
  };
  ids.forEach((sid, k) => {
    const s = sampleById(sid);
    const st = typeof status === "function" ? status(k) : status;
    const job = calibrationJob(run, s, st, createdAt);
    let score = null;
    if (st === "draft") {
      const hit = hits === null ? Math.min(s.comments.length, 1 + (k % 3)) : hits;
      const draft = agentDraft(s, Math.min(hit, s.comments.length), k % 3);
      job.review = draft;
      score =
        k === ids.length - 1 && ids.length > 4
          ? { matcherVersion: 1, unscorable: "the draft names no decision" }
          : scoreOf(s, draft);
    }
    run.results.push({
      jobId: job.id,
      sampleId: sid,
      score,
      scoreStale: s.joinedAt !== null && st === "draft",
    });
  });
  calib.runs.unshift(run);
  return run;
}
const ids = (from, n) => calib.samples.slice(from, from + n).map((s) => s.id);
makeRun("run-1", ids(0, 6), 30, 1, "draft", 0);
makeRun("run-2", ids(0, 8), 20, 1);
makeRun("run-3", ids(2, 10), 10, 2, "draft", 3);
makeRun("run-4", ids(4, 4), 1, 2, (k) => (k === 0 ? "running" : k === 1 ? "failed" : "draft"));
// A deleted sample: still shown, marked, in its runs, and left out of the aggregates.
calib.samples[5].deletedAt = now();

function runJson(run, detail, includeStale) {
  const counts = {};
  for (const r of run.results) {
    const st = jobs.get(r.jobId)?.status ?? "pending";
    counts[st] = (counts[st] ?? 0) + 1;
  }
  const out = {
    id: run.id,
    owner: run.owner,
    name: run.name,
    createdAt: run.createdAt,
    samples: run.results.length,
    jobs: counts,
    aggregate: aggregate(run.results, includeStale),
  };
  if (detail)
    out.results = run.results.map((r) => {
      const job = jobs.get(r.jobId);
      const s = sampleById(r.sampleId);
      return {
        jobId: r.jobId,
        status: job?.status ?? "pending",
        error: job?.error ?? null,
        rubricVersion: job?.rubricVersion ?? null,
        prType: job?.prType ?? null,
        sample:
          s === undefined
            ? null
            : {
                id: s.id,
                prNumber: s.prNumber,
                reviewer: s.reviewer,
                state: s.state,
                commitId: s.commitId,
                title: s.title,
                comments: s.comments.length,
                deleted: s.deletedAt !== null,
                scope: s.scope,
              },
        score: r.score,
        scoreStale: r.scoreStale,
      };
    });
  return out;
}

/** The import a pass reads on: a live one moves a few pull requests on each time it is asked. */
function advanceImports() {
  for (const i of calib.imports) {
    if (i.status !== "queued" && i.status !== "running") continue;
    if (i.pausedUntil !== undefined && Date.now() < i.pausedUntil) continue;
    i.status = "running";
    i.error = null;
    delete i.pausedUntil;
    i.pullsListed ??= Math.min(i.limit, 12);
    i.stats.pulls = i.pullsListed;
    i.pullsRead = Math.min(i.pullsListed, i.pullsRead + 2);
    i.stats.reviews = (i.stats.reviews ?? 0) + 2;
    i.stats.known = (i.stats.known ?? 0) + 2;
    i.updatedAt = now();
    if (i.pullsRead === 6 && i.pausedOnce === undefined) {
      // Under the reserve: paused until GitHub's limit resets, half a minute on.
      i.pausedOnce = true;
      i.pausedUntil = Date.now() + 30000;
      const at = new Date(i.pausedUntil).toISOString().replace(/\.\d+Z$/, "Z");
      i.error = `paused until ${at}: GitHub's requests left before its limit resets are under the 500 kept for discovery and posting (--github-reserve)`;
    }
    if (i.pullsRead >= i.pullsListed) i.status = "done";
  }
}

function calibrationRoute(req, res, url, parts, body) {
  const [owner, name] = [parts[3].toLowerCase(), parts[4].toLowerCase()];
  const repo = repos.get(`${owner}/${name}`);
  if (repo === undefined) return send(res, 404, { error: `${owner}/${name} is not registered` });
  const mine = (x) => x.owner === owner && x.name === name;
  const includeStale = url.searchParams.get("stale") === "include";
  const what = parts[6];
  const id = parts[7];
  if (what === "import") {
    advanceImports();
    if (req.method === "GET" && id === undefined)
      return send(res, 200, page([...calib.imports.filter(mine)].reverse(), url));
    if (req.method === "POST" && id === undefined) {
      if (repo.trustedReviewers.length === 0)
        return send(res, 409, {
          error: `${owner}/${name} names no trusted reviewers; set 'trustedReviewers' first`,
        });
      const live = calib.imports.find((i) => mine(i) && ["queued", "running"].includes(i.status));
      if (live !== undefined)
        return send(res, 409, {
          error: `an import of ${owner}/${name} is under way`,
          import: live,
        });
      const limit = body.limit ?? 50;
      if (!Number.isInteger(limit) || limit < 1 || limit > 200)
        return send(res, 400, { error: "'limit' must be between 1 and 200" });
      const i = {
        id: `imp-${calib.imports.length + 1}`,
        owner,
        name,
        limit,
        status: "queued",
        pullsListed: null,
        pullsRead: 0,
        failures: 0,
        stats: {},
        error: null,
        requestedAt: now(),
        updatedAt: now(),
      };
      calib.imports.push(i);
      return send(res, 202, i);
    }
    if (req.method === "POST" && parts[8] === "cancel") {
      const i = calib.imports.find((x) => mine(x) && x.id === id);
      if (i === undefined) return send(res, 404, { error: "not found" });
      if (!["queued", "running"].includes(i.status))
        return send(res, 409, { error: `import ${id} is ${i.status}`, import: i });
      Object.assign(i, { status: "cancelled", updatedAt: now() });
      return send(res, 200, i);
    }
  }
  if (what === "samples") {
    const live = calib.samples.filter((s) => mine(s) && s.deletedAt === null);
    if (req.method === "GET" && id === undefined)
      return send(res, 200, page(live.map(sampleJson), url));
    const s = live.find((x) => x.id === id);
    if (s === undefined) return send(res, 404, { error: "not found" });
    if (req.method === "GET") return send(res, 200, sampleJson(s));
    if (req.method === "DELETE") {
      s.deletedAt = now();
      res.writeHead(204);
      return res.end();
    }
  }
  if (what === "runs") {
    const runs = calib.runs.filter(mine);
    if (req.method === "GET" && id === undefined)
      return send(
        res,
        200,
        page(
          runs.map((r) => runJson(r, false, includeStale)),
          url,
        ),
      );
    if (req.method === "GET") {
      const r = runs.find((x) => x.id === id);
      if (r === undefined) return send(res, 404, { error: "not found" });
      return send(res, 200, runJson(r, true, includeStale));
    }
    if (req.method === "POST") {
      const busy = (sid) =>
        [...jobs.values()].some(
          (j) => j.sampleId === sid && ["pending", "queued", "running"].includes(j.status),
        );
      const live = calib.samples.filter((s) => mine(s) && s.deletedAt === null);
      let chosen;
      if (Array.isArray(body.samples)) {
        if (body.samples.length < 1 || body.samples.length > 20)
          return send(res, 400, { error: "'samples' names 1 to 20 samples" });
        for (const sid of body.samples) {
          if (!live.some((s) => s.id === sid)) return send(res, 404, { error: `no sample ${sid}` });
          if (busy(sid))
            return send(res, 409, {
              error: `sample ${sid} is being reviewed by a live calibration job`,
            });
        }
        chosen = body.samples;
      } else if (Number.isInteger(body.count)) {
        if (body.count < 1 || body.count > 20)
          return send(res, 400, { error: "'count' must be between 1 and 20" });
        chosen = live
          .filter((s) => !busy(s.id))
          .slice(0, body.count)
          .map((s) => s.id);
      } else return send(res, 400, { error: "name 'samples' or a 'count'" });
      if (calib.charged + chosen.length > calib.cap)
        return send(res, 429, {
          error: `${owner}/${name} has had ${calib.charged} calibration jobs today; ${chosen.length} more would pass the cap of ${calib.cap} (--max-calibration-jobs-per-day)`,
        });
      calib.charged += chosen.length;
      const run = makeRun(`run-${calib.runs.length + 1}`, chosen, 0, 2, "pending");
      return send(res, 201, runJson(run, false, false));
    }
  }
  if (what === "summary" && req.method === "GET") {
    const all = calib.runs.filter(mine).flatMap((r) => r.results.map((x) => ({ ...x, run: r })));
    const versions = [...new Set(all.map((x) => x.run.rubricVersion))].sort((a, b) => b - a);
    return send(res, 200, {
      owner,
      name,
      runs: calib.runs.filter(mine).length,
      samples: calib.samples.filter((s) => mine(s) && s.deletedAt === null).length,
      overall: aggregate(all, includeStale),
      byRubricVersion: versions.map((v) => ({
        rubricVersion: v,
        aggregate: aggregate(
          all.filter((x) => x.run.rubricVersion === v),
          includeStale,
        ),
      })),
    });
  }
  return send(res, 404, { error: "no such route" });
}
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
  if (url.pathname === "/__fake/repo-bump") {
    // Someone else changes the settings: a trusted reviewer more, and the mode.
    const r = repos.get("chrisflav/diff-reviewer");
    Object.assign(r, {
      trustedReviewers: [...r.trustedReviewers.filter((l) => l !== "bob"), "carol"],
      mode: r.mode === "staged" ? "direct" : "staged",
      version: r.version + 1,
    });
    return send(res, 200, r);
  }
  if (url.pathname === "/__fake/calibration-cap") {
    calib.charged = Number(url.searchParams.get("charged") ?? calib.cap);
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
    const [status, out] = putRepo(parts[3], parts[4], body);
    return send(res, status, out);
  }
  if (parts[2] === "repos" && parts.length === 5 && req.method === "DELETE") {
    repos.delete(`${parts[3]}/${parts[4]}`.toLowerCase());
    res.writeHead(204);
    return res.end();
  }
  if (parts[2] === "repos" && parts[5] === "calibration")
    return calibrationRoute(req, res, url, parts, body);
  if (url.pathname === "/api/v1/jobs" && req.method === "GET") {
    const kind = url.searchParams.get("kind") ?? "review";
    if (!["review", "calibration", "all"].includes(kind))
      return send(res, 400, { error: "'kind' must be review, calibration or all" });
    const all = [...jobs.values()];
    return send(res, 200, {
      items: kind === "all" ? all : all.filter((j) => (j.kind ?? "review") === kind),
    });
  }

  if (parts[0] === "api" && parts[1] === "v1" && parts[2] === "jobs" && parts[3] !== undefined) {
    const job = jobs.get(parts[3]);
    if (job === undefined) return send(res, 404, { error: `no job ${parts[3]}` });
    const action = parts[4];
    if (action === undefined) return send(res, 200, job);
    if (action === "diff") return send(res, 200, { headSha: job.headSha, diff });
    if (action === "revisions") return send(res, 200, page(revisions.get(job.id) ?? [], url));
    if (body.version !== job.version)
      return send(res, 409, { error: `job ${job.id} is at version ${job.version}` });
    if ((job.kind ?? "review") !== "review") {
      if (action === "status" && body.status === "pending" && job.status === "failed") {
        if (calib.charged + 1 > calib.cap)
          return send(res, 429, {
            error: `${job.owner}/${job.name} has had ${calib.charged} calibration jobs today; the cap is ${calib.cap} (--max-calibration-jobs-per-day)`,
          });
        calib.charged++;
        return send(res, 200, bump(job, { status: "pending", error: null }));
      }
      return send(res, 409, {
        error: `job ${job.id} is a ${job.kind} job; it is never approved or posted`,
      });
    }
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