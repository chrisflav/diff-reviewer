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
  createdAt: string;
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
  login: (password: string) => request<{ authenticated: boolean }>("POST", "/api/login", { password }),
  /** Sign in with the API token: never rate-limited, the way in while password attempts are not. */
  loginWithToken: (token: string) =>
    request<{ authenticated: boolean }>("POST", "/api/login", { token }),
  logout: () => request<{ authenticated: boolean }>("POST", "/api/logout"),

  repos: () => request<{ items: Repo[] }>("GET", "/api/v1/repos").then((r) => r.items),
  /** Replaces the settings: both are sent, since an omitted one would fall back to its default. */
  putRepo: (owner: string, name: string, mode: PostingMode, autoReview: boolean) =>
    request<Repo>("PUT", `/api/v1/repos/${seg(owner)}/${seg(name)}`, { mode, autoReview }),
  deleteRepo: (owner: string, name: string) =>
    request<void>("DELETE", `/api/v1/repos/${seg(owner)}/${seg(name)}`),

  jobs: () => request<{ items: Job[] }>("GET", "/api/v1/jobs").then((r) => r.items),
  job: (id: string) => request<Job>("GET", `/api/v1/jobs/${seg(id)}`),
  createJob: (owner: string, name: string, prNumber: number, headSha: string | null) =>
    request<Job>("POST", "/api/v1/jobs", headSha === null
      ? { owner, name, prNumber }
      : { owner, name, prNumber, headSha }),
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
};

/** One page of a history; `nextOffset` is null on the last. */
export interface Page<T> {
  items: T[];
  nextOffset: number | null;
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