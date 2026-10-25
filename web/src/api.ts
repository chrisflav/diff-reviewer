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
  constructor(status: number, message: string) {
    super(message);
    this.name = "ApiError";
    this.status = status;
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

export interface Repo {
  owner: string;
  name: string;
  mode: PostingMode;
  /** Whether the platform finds the repository's open pull requests itself. */
  autoReview: boolean;
  createdAt: string;
}

export interface InlineComment {
  file: string;
  start_line: number;
  end_line: number;
  body: string;
  suggestion?: string;
}

export interface Review {
  decision: Decision;
  body: string;
  comments: InlineComment[];
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
    throw new ApiError(res.status, msg);
  }
  return json as T;
}

export const api = {
  session: () => request<{ authenticated: boolean }>("GET", "/api/session"),
  login: (password: string) => request<{ authenticated: boolean }>("POST", "/api/login", { password }),
  logout: () => request<{ authenticated: boolean }>("POST", "/api/logout"),

  repos: () => request<{ items: Repo[] }>("GET", "/api/v1/repos").then((r) => r.items),
  putRepo: (owner: string, name: string, mode: PostingMode) =>
    request<Repo>("PUT", `/api/v1/repos/${seg(owner)}/${seg(name)}`, { mode }),
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
};

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

/** Whether a person may edit the review now; mirrors `JobStatus.personCanEdit` in Lean. */
export function canEdit(s: string): boolean {
  return s === "pending" || s === "draft" || s === "approved" || s === "rejected";
}