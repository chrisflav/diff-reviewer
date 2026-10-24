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
  | "stale";

export type Decision = "comment" | "approve" | "request_changes";

export interface Repo {
  owner: string;
  name: string;
  mode: PostingMode;
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
  status: JobStatus;
  queueEntry: string | null;
  review: Review | null;
  createdAt: string;
  updatedAt: string;
}

async function request<T>(method: string, path: string, body?: unknown): Promise<T> {
  const init: RequestInit = { method, credentials: "same-origin" };
  if (body !== undefined) {
    init.headers = { "Content-Type": "application/json" };
    init.body = JSON.stringify(body);
  }
  const res = await fetch(path, init);
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
    request<Repo>("PUT", `/api/v1/repos/${owner}/${name}`, { mode }),
  deleteRepo: (owner: string, name: string) =>
    request<void>("DELETE", `/api/v1/repos/${owner}/${name}`),

  jobs: () => request<{ items: Job[] }>("GET", "/api/v1/jobs").then((r) => r.items),
  job: (id: string) => request<Job>("GET", `/api/v1/jobs/${id}`),
  createJob: (owner: string, name: string, prNumber: number, headSha: string | null) =>
    request<Job>("POST", "/api/v1/jobs", headSha === null
      ? { owner, name, prNumber }
      : { owner, name, prNumber, headSha }),
  putReview: (id: string, review: Review) => request<Job>("PUT", `/api/v1/jobs/${id}/review`, review),
  setStatus: (id: string, status: JobStatus) =>
    request<Job>("POST", `/api/v1/jobs/${id}/status`, { status }),
};

/** The moves a person makes from a job's page; mirrors `JobStatus.canMove` in Lean. */
export function nextStatuses(s: JobStatus): JobStatus[] {
  switch (s) {
    case "draft":
      return ["approved", "rejected", "stale"];
    case "approved":
      return ["posted", "draft"];
    case "rejected":
      return ["draft"];
    default:
      return [];
  }
}