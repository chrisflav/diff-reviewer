/**
 * Typed client for the `diff-reviewer serve` JSON API (`docs/openapi.json`).
 *
 * Authentication is the session cookie the browser holds and sends on its own; nothing here
 * attaches a credential.
 */

export class UnauthorizedError extends Error {
  constructor() {
    super("unauthorized");
    this.name = "UnauthorizedError";
  }
}

export class ApiError extends Error {
  readonly status: number;
  /** The answer's JSON, for errors that carry more than a message (a failed post's job). */
  readonly body: unknown;
  constructor(status: number, message: string, body: unknown = null) {
    super(message);
    this.name = "ApiError";
    this.status = status;
    this.body = body;
  }
}

export type PostingMode = "staged" | "direct";

export type JobStatus =
  | "pending"
  | "queued"
  | "running"
  | "draft"
  | "approved"
  | "posted"
  | "rejected"
  | "stale"
  | "failed";

export type Decision = "comment" | "approve" | "request_changes";

/** How much a comment matters, from least to most. */
export type Severity = "nit" | "minor" | "major" | "blocker";

export const severities: Severity[] = ["nit", "minor", "major", "blocker"];

export interface Repo {
  owner: string;
  name: string;
  mode: PostingMode;
  /** Whether the platform finds the repository's open pull requests itself. */
  autoReview: boolean;
  /** The GitHub logins, in lower case, whose past reviews calibration scores the agent against. */
  trustedReviewers: string[];
  /** Incremented by every write of the settings; sent back to have a stale write refused (409). */
  version: number;
  createdAt: string;
  /** Settings a newer build knows: sent back as they were read. */
  [field: string]: unknown;
}

/**
 * A write of a repository's settings. `mode` and `autoReview` fall back to their defaults when
 * left out; `trustedReviewers` is kept. `version` (0 for a repository not registered) makes a
 * stale write a 409; left out, it is not checked.
 */
export interface RepoSettings {
  mode?: PostingMode;
  autoReview?: boolean;
  trustedReviewers?: string[];
  version?: number;
  [field: string]: unknown;
}

/**
 * Fields this build does not know (a newer one's `category`, `severity`, …) are kept on every
 * round trip through the page, hence the index signatures: an edit changes what it edits and
 * passes the rest through.
 */
export interface InlineComment {
  file: string;
  start_line: number;
  end_line: number;
  body: string;
  suggestion?: string;
  /** Stable within the review; the server assigns one on write when absent. Keep it on edits. */
  id?: string;
  /** One of the rubric's categories for the job's pull request type, or free text without any. */
  category?: string;
  severity?: Severity;
  [field: string]: unknown;
}

export interface Review {
  decision: Decision;
  body: string;
  comments: InlineComment[];
  [field: string]: unknown;
}

/**
 * Rubric documents, like reviews, keep the fields this client does not know: edit what was read
 * (spread it) rather than rebuild it, and the server keeps the rest.
 */
export interface Category {
  name: string;
  description: string;
  [field: string]: unknown;
}

export interface PrType {
  name: string;
  /** When the type applies: what the agent picks it by. */
  description: string;
  /** How to review a pull request of this type, in markdown, on top of the default rubric. */
  rubric: string;
  categories: Category[];
  [field: string]: unknown;
}

/** One version of a repository's rubric document. */
export interface RubricDocument {
  owner: string;
  name: string;
  /** 0 for a repository with no rubric yet; sent back with the next write. */
  version: number;
  createdAt: string | null;
  /** Null only when `documentError` says why the stored document cannot be read. */
  defaultRubric: string | null;
  prTypes: PrType[] | null;
  documentError: string | null;
  [field: string]: unknown;
}

/** One write of a job's review. */
export interface Revision {
  jobId: string;
  /** The job's version the write made. */
  version: number;
  /** `agent`, `person` or `github` (what GitHub holds once posted). */
  author: "agent" | "person" | "github" | string;
  /** The review as stored, not reinterpreted. */
  review: unknown;
  reviewError: string | null;
  createdAt: string;
}

export interface Job {
  id: string;
  owner: string;
  name: string;
  prNumber: number;
  headSha: string | null;
  /** A `JobStatus`, or one a newer build wrote, which this one shows and does not change. */
  status: JobStatus | string;
  queueEntry: string | null;
  review: Review | null;
  /** Why the stored review could not be read, when it could not. */
  reviewError: string | null;
  /** Sent back with every write, so that a stale page gets a 409 instead of overwriting. */
  version: number;
  createdAt: string;
  updatedAt: string;
  /** The pull request's base commit, title and description, from GitHub, once known. */
  baseSha: string | null;
  title: string | null;
  prBody: string | null;
  /** What the platform's last step on the job failed with, until one succeeds. */
  error: string | null;
  /** The kind of pull request the agent said it reviewed. */
  prType: string | null;
  /** How many times the job has been queued on orchestra. */
  attempts: number;
  /** When posting last began, while its outcome is not known. */
  postStartedAt: string | null;
  /** The posted review on GitHub. */
  postedUrl: string | null;
  /** How the review was posted, when that differs from its decision. */
  postNote: string | null;
  /** The review as GitHub holds it, once posted. */
  postedReview: { id: number; url: string; body: string } | null;
  /** The rubric version the review was checked against: 0 for none, null from before rubrics. */
  rubricVersion: number | null;
  /** How many times the platform has posted the review on its own (`direct`), at most 3. */
  directPosts: number;
  /** Whether the last post was the platform's own, which it may post again. */
  postDirect: boolean;
  /**
   * `review`, or `calibration`: a review of a past commit, scored against a trusted reviewer's
   * review and never approved, edited or posted. A kind a newer build wrote is never posted.
   * Absent from a server older than API 0.5.0, whose jobs are all reviews.
   */
  kind?: JobKind | string;
  /** The calibration sample and run of a `calibration` job. */
  sampleId?: string | null;
  runId?: string | null;
}

export type JobKind = "review" | "calibration";

/** A trusted reviewer's inline comment, on the new side of the diff at the review's commit. */
export interface HumanComment {
  /** GitHub's id of the comment. */
  id: number;
  path: string;
  start_line: number;
  line: number;
  body: string;
}

/**
 * What one trusted reviewer said of one commit of a closed pull request: every review they
 * submitted of it, merged.
 */
export interface CalibrationSample {
  id: string;
  owner: string;
  name: string;
  prNumber: number;
  /** GitHub's ids of the reviews merged into it. */
  reviewIds: number[];
  reviewer: string;
  /** The strongest state of its reviews: `CHANGES_REQUESTED`, then `APPROVED`, then `COMMENTED`. */
  state: string;
  body: string;
  /** The commit reviewed, and the base the pull request's diff had there. */
  commitId: string;
  baseSha: string;
  title: string;
  /**
   * What it is scored for: everything, or (`partial`: comments were dropped; `decision`: it says
   * nothing but its state) its decision only.
   */
  scope: CalibrationScope | string;
  comments: HumanComment[];
  /** Comments not kept: on the old side, not anchored to a line of `commitId`, replies. */
  dropped: { left: number; outdated: number; replies: number };
  submittedAt: string | null;
  importedAt: string;
  /** When a review was last merged into it. */
  updatedAt: string;
}

export type CalibrationScope = "full" | "partial" | "decision";

export type CalibrationImportStatus = "queued" | "running" | "done" | "failed" | "cancelled";

export interface CalibrationImport {
  id: string;
  owner: string;
  name: string;
  limit: number;
  status: CalibrationImportStatus | string;
  /** The closed pull requests found, once listed. */
  pullsListed: number | null;
  pullsRead: number;
  /** How many times reading the next pull request has failed; at 3 it is skipped. */
  failures: number;
  /**
   * `pulls`, `reviews`, `imported`, `merged`, `known`, `deleted`, `empty`, `unreachable`,
   * `unreadable`, `droppedLeft`, `droppedOutdated`, `droppedReplies`.
   */
  stats: Record<string, number>;
  /**
   * Why the last pass stopped short (GitHub's rate limit, a pause under the reserve until it
   * resets, an error to retry), or why it failed.
   */
  error: string | null;
  requestedAt: string;
  updatedAt: string;
}

/** The agent's comments of one category or severity, and how many were matched. */
export interface CalibrationTally {
  comments: number;
  matched: number;
  /** To four decimals; null with no comments. */
  precision: number | null;
}

/** One of the agent's comments, as drafted. */
export interface AgentComment {
  id: string | null;
  file: string;
  start_line: number;
  end_line: number;
  body: string;
  category: string | null;
  severity: Severity | null;
}

/** A calibration job's draft against its sample. Matching is by place only. */
export interface CalibrationScore {
  /** Scores of different matcher versions are not compared. */
  matcherVersion: number;
  /** Only a `full` sample has a precision and recall; the others count for their decision. */
  scope: CalibrationScope | string;
  agentComments: number;
  humanComments: number;
  matched: number;
  /** matched / agentComments; null when the agent wrote none, or the sample is not `full`. */
  precision: number | null;
  /** matched / humanComments; null when the person wrote none, or the sample is not `full`. */
  recall: number | null;
  byCategory: (CalibrationTally & { category: string | null })[];
  bySeverity: (CalibrationTally & { severity: Severity | null })[];
  /** `agree` is null when the person's state stands for no decision (`DISMISSED`). */
  decision: { agent: Decision; human: string; agree: boolean | null };
  /** `key` is `<agent comment id>:<GitHub comment id>`; `gap` the lines between the ranges. */
  pairs: { key: string; gap: number; agent: AgentComment; human: HumanComment }[];
  unmatchedAgent: AgentComment[];
  unmatchedHuman: HumanComment[];
}

/** A draft that could not be scored, and why; left out of aggregates. */
export interface CalibrationUnscorable {
  matcherVersion: number;
  unscorable: string;
}

/**
 * Scores of samples not deleted, added up as counts; every ratio is computed from the sums.
 * Comment counts and ratios are of `full` samples (`commentsScored`); decisions of all.
 */
export interface CalibrationAggregate {
  matcherVersion: number;
  scored: number;
  commentsScored: number;
  /** Stale scores in scope, and whether they are counted (`?stale=include`). */
  staleScores: number;
  staleIncluded: boolean;
  agentComments: number;
  humanComments: number;
  matched: number;
  precision: number | null;
  recall: number | null;
  byCategory: (CalibrationTally & { category: string | null })[];
  bySeverity: (CalibrationTally & { severity: Severity | null })[];
  decisions: {
    compared: number;
    agreed: number;
    agreement: number | null;
    matrix: { agent: string; human: string; count: number }[];
  };
}

export interface CalibrationRunResult {
  jobId: string;
  status: JobStatus | string;
  error: string | null;
  rubricVersion: number | null;
  prType: string | null;
  sample: {
    id: string;
    prNumber: number;
    reviewer: string;
    state: string;
    commitId: string;
    title: string;
    scope: CalibrationScope | string;
    comments: number;
    /** A deleted sample's score is shown here and left out of every aggregate. */
    deleted: boolean;
  } | null;
  /** Null until the job's draft is scored. */
  score: CalibrationScore | CalibrationUnscorable | null;
  /** A review joined the sample after the score was made; the score is kept as it was. */
  scoreStale: boolean;
}

export interface CalibrationRun {
  id: string;
  owner: string;
  name: string;
  createdAt: string;
  samples: number;
  /** Its jobs by status. */
  jobs: Record<string, number>;
  aggregate: CalibrationAggregate;
  /** Only in the answer for one run. */
  results?: CalibrationRunResult[];
}

export interface CalibrationSummary {
  owner: string;
  name: string;
  runs: number;
  samples: number;
  overall: CalibrationAggregate;
  /** Newest rubric version first; 0 is no rubric. */
  byRubricVersion: { rubricVersion: number | null; aggregate: CalibrationAggregate }[];
}

export interface JobDiff {
  headSha: string;
  /** Unified diff text, as `git diff` writes it. */
  diff: string;
}

/** Thrown when the server could not be reached at all. */
export class NetworkError extends Error {
  constructor() {
    super("the server could not be reached");
    this.name = "NetworkError";
  }
}

async function request<T>(method: string, path: string, body?: unknown): Promise<T> {
  const init: RequestInit = { method, credentials: "same-origin" };
  if (body !== undefined) {
    init.headers = { "Content-Type": "application/json" };
    init.body = JSON.stringify(body);
  }
  let res: Response;
  try {
    res = await fetch(path, init);
  } catch {
    throw new NetworkError();
  }
  if (res.status === 401) throw new UnauthorizedError();
  if (res.status === 204) return undefined as T;
  const text = await res.text();
  let json: unknown = null;
  try {
    json = text === "" ? null : JSON.parse(text);
  } catch {
    /* not JSON: reported below */
  }
  if (!res.ok) {
    const msg =
      json !== null && typeof json === "object" && "error" in json
        ? String((json as { error: unknown }).error)
        : `${res.status} ${res.statusText}`;
    throw new ApiError(res.status, msg, json);
  }
  return json as T;
}

export const api = {
  session: () => request<{ authenticated: boolean }>("GET", "/api/session"),
  login: (password: string) =>
    request<{ authenticated: boolean }>("POST", "/api/login", { password }),
  /** Sign in with the API token: never rate-limited, the way in while password attempts are not. */
  loginWithToken: (token: string) =>
    request<{ authenticated: boolean }>("POST", "/api/login", { token }),
  logout: () => request<{ authenticated: boolean }>("POST", "/api/logout"),

  repos: () => request<{ items: Repo[] }>("GET", "/api/v1/repos").then((r) => r.items),
  /**
   * Write the settings named; see `RepoSettings` for what an omitted one does. Callers send the
   * `version` they read (0 to register), so that a write over a newer one is a 409; `putBody` in
   * `repoSettings.ts` makes the body from what was read.
   */
  putRepoSettings: (owner: string, name: string, settings: RepoSettings) =>
    request<Repo>("PUT", `/api/v1/repos/${seg(owner)}/${seg(name)}`, settings),
  deleteRepo: (owner: string, name: string) =>
    request<void>("DELETE", `/api/v1/repos/${seg(owner)}/${seg(name)}`),

  /** Review jobs, unless `kind` asks for calibration jobs or all. */
  jobs: (kind: JobKind | "all" = "review") =>
    request<{ items: Job[] }>("GET", `/api/v1/jobs?kind=${kind}`).then((r) => r.items),
  job: (id: string) => request<Job>("GET", `/api/v1/jobs/${seg(id)}`),
  createJob: (owner: string, name: string, prNumber: number, headSha: string | null) =>
    request<Job>(
      "POST",
      "/api/v1/jobs",
      headSha === null ? { owner, name, prNumber } : { owner, name, prNumber, headSha },
    ),
  putReview: (id: string, version: number, review: Review) =>
    request<Job>("PUT", `/api/v1/jobs/${seg(id)}/review`, { version, review }),
  setStatus: (id: string, version: number, status: JobStatus) =>
    request<Job>("POST", `/api/v1/jobs/${seg(id)}/status`, { status, version }),
  /** Settle a post whose outcome is unknown, without posting (`POST /api/v1/jobs/{id}/reconcile`). */
  reconcileJob: (id: string, version: number) =>
    request<Job>("POST", `/api/v1/jobs/${seg(id)}/reconcile`, { version }),
  /** The pull request's diff at the job's head. */
  diff: (id: string) => request<JobDiff>("GET", `/api/v1/jobs/${seg(id)}/diff`),
  /** Post an approved review to GitHub, under the operator's account; the job becomes `posted`. */
  post: (id: string, version: number) =>
    request<Job>("POST", `/api/v1/jobs/${seg(id)}/post`, { version }),
  /** One page of the writes of the job's review, oldest first. */
  revisions: (id: string, limit = 50, offset = 0) =>
    request<Page<Revision>>("GET", `/api/v1/jobs/${seg(id)}/revisions?${pageQuery(limit, offset)}`),

  rubrics: (owner: string, name: string) =>
    request<RubricDocument>("GET", `/api/v1/repos/${seg(owner)}/${seg(name)}/rubrics`),
  /** Replace the whole document; `version` is the one last read (0 for none). */
  putRubrics: (
    owner: string,
    name: string,
    version: number,
    doc: { defaultRubric: string; prTypes: PrType[]; [field: string]: unknown },
  ) =>
    request<RubricDocument>("PUT", `/api/v1/repos/${seg(owner)}/${seg(name)}/rubrics`, {
      version,
      ...doc,
    }),
  /** One page of the versions of the document, newest first. */
  rubricHistory: (owner: string, name: string, limit = 50, offset = 0) =>
    request<Page<RubricDocument>>(
      "GET",
      `/api/v1/repos/${seg(owner)}/${seg(name)}/rubrics/history?${pageQuery(limit, offset)}`,
    ),

  /**
   * Version `version` of the document: the current one, or found in the history, which is newest
   * first and numbered without gaps, so that `current - version` is where to look first.
   */
  rubricAt: async (owner: string, name: string, version: number): Promise<RubricDocument> => {
    const now = await api.rubrics(owner, name);
    if (now.version === version) return now;
    const guess = now.version - version;
    if (guess > 0) {
      const page = await api.rubricHistory(owner, name, 1, guess);
      const hit = page.items.find((v) => v.version === version);
      if (hit !== undefined) return hit;
    }
    for (let offset: number | null = 0; offset !== null;) {
      const page: Page<RubricDocument> = await api.rubricHistory(owner, name, 200, offset);
      const hit = page.items.find((v) => v.version === version);
      if (hit !== undefined) return hit;
      offset = page.nextOffset;
    }
    throw new ApiError(404, `${owner}/${name} has no rubric version ${version}`);
  },

  /** Queue an import of the `limit` (default 50, at most 200) most recent closed pull requests. */
  importCalibration: (owner: string, name: string, limit?: number) =>
    request<CalibrationImport>(
      "POST",
      `${calibration(owner, name)}/import`,
      limit === undefined ? {} : { limit },
    ),
  /** Stop a queued or running import; what it stored stays. */
  cancelCalibrationImport: (owner: string, name: string, id: string) =>
    request<CalibrationImport>("POST", `${calibration(owner, name)}/import/${seg(id)}/cancel`, {}),
  /** One page of the repository's imports, newest first. */
  calibrationImports: (owner: string, name: string, limit = 50, offset = 0) =>
    request<Page<CalibrationImport>>(
      "GET",
      `${calibration(owner, name)}/import?${pageQuery(limit, offset)}`,
    ),
  /** One page of the samples, most recently reviewed first. */
  calibrationSamples: (owner: string, name: string, limit = 50, offset = 0) =>
    request<Page<CalibrationSample>>(
      "GET",
      `${calibration(owner, name)}/samples?${pageQuery(limit, offset)}`,
    ),
  calibrationSample: (owner: string, name: string, id: string) =>
    request<CalibrationSample>("GET", `${calibration(owner, name)}/samples/${seg(id)}`),
  /** Delete a sample; importing again neither brings it back nor adds to it. */
  deleteCalibrationSample: (owner: string, name: string, id: string) =>
    request<void>("DELETE", `${calibration(owner, name)}/samples/${seg(id)}`),
  /**
   * Run the agent on the samples named, or on `count` of those run least; at most 20. A sample a
   * live job is reviewing is refused (409); past the daily cap, 429.
   */
  createCalibrationRun: (
    owner: string,
    name: string,
    which: { samples: string[] } | { count: number },
  ) => request<CalibrationRun>("POST", `${calibration(owner, name)}/runs`, which),
  /** One page of the runs, newest first, each with its aggregate. */
  calibrationRuns: (owner: string, name: string, limit = 50, offset = 0, stale = false) =>
    request<Page<CalibrationRun>>(
      "GET",
      `${calibration(owner, name)}/runs?${pageQuery(limit, offset)}${staleQuery(stale, "&")}`,
    ),
  /** One run, with each sample's result; `stale` counts stale scores in its aggregate. */
  calibrationRun: (owner: string, name: string, id: string, stale = false) =>
    request<CalibrationRun>(
      "GET",
      `${calibration(owner, name)}/runs/${seg(id)}${staleQuery(stale, "?")}`,
    ),
  /** The aggregate over every run, and by rubric version; `stale` counts stale scores too. */
  calibrationSummary: (owner: string, name: string, stale = false) =>
    request<CalibrationSummary>(
      "GET",
      `${calibration(owner, name)}/summary${staleQuery(stale, "?")}`,
    ),
};

function calibration(owner: string, name: string): string {
  return `/api/v1/repos/${seg(owner)}/${seg(name)}/calibration`;
}

/** One page of a history; `nextOffset` is null on the last. */
export interface Page<T> {
  items: T[];
  nextOffset: number | null;
}

/** `?stale=include` (or `&…`) when stale scores are to be counted. */
function staleQuery(stale: boolean, sep: "?" | "&"): string {
  return stale ? `${sep}stale=include` : "";
}

function pageQuery(limit: number, offset: number): string {
  return `limit=${Math.trunc(limit)}&offset=${Math.trunc(offset)}`;
}

/** One path segment, encoded, so that a `/`, `?` or `#` in it cannot change the path. */
function seg(s: string): string {
  return encodeURIComponent(s);
}

/** The moves a person makes from a job's page; mirrors `JobStatus.personCanMove` in Lean. */
export function nextStatuses(s: string): JobStatus[] {
  switch (s) {
    case "draft":
      return ["approved", "rejected", "stale"];
    case "approved":
    case "rejected":
      return ["draft"];
    case "failed":
      return ["pending"];
    default:
      return [];
  }
}

/**
 * Whether the job is a review to post: of the kind `review` (or from a server older than kinds).
 * A calibration job, or one of a kind a newer build wrote, is never approved, edited or posted.
 */
export function isReviewJob(j: Pick<Job, "kind">): boolean {
  return j.kind === undefined || j.kind === "review";
}

/**
 * The moves a person makes from the job's page: a review's as `nextStatuses`; a calibration job
 * only runs again once failed; a kind this build does not know, none.
 */
export function jobMoves(j: Pick<Job, "kind" | "status">): JobStatus[] {
  if (isReviewJob(j)) return nextStatuses(j.status);
  return j.kind === "calibration" && j.status === "failed" ? ["pending"] : [];
}

/** Whether a GitHub URL the server recorded may be shown as a link: GitHub's own pages only. */
export function githubLink(url: string | null): string | null {
  return url !== null && url.startsWith("https://github.com/") ? url : null;
}

/** Whether a job may be posted now; posting is its own action, not a status move. */
export function canPost(s: string): boolean {
  return s === "approved";
}

/** Whether a person may edit the review now; mirrors `JobStatus.personCanEdit` in Lean. */
export function canEdit(s: string): boolean {
  return s === "pending" || s === "draft" || s === "approved" || s === "rejected";
}