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
  /**
   * The percent of new calibration samples held out as `eval` (what runs measure by); the rest
   * are the `pool` examples and proposals learn from. Absent before API 0.6.0.
   */
  evalShare?: number;
  /**
   * The pull request type every review of the repository is of, fixed by the operator (null: the
   * agent picks). A type with `fanout` fans out only when fixed. Absent before API 0.7.0.
   */
  prType?: string | null;
  /** The most sub-runs one fan-out review may make (1 to 51, 8 by default). API 0.7.0. */
  maxFanout?: number;
  /** Whether a new head after a posted review is reviewed incrementally (default true; 0.8.0). */
  incremental?: boolean;
  /** Incremented by every write of the settings; sent back to have a stale write refused (409). */
  version: number;
  createdAt: string;
  /** Settings a newer build knows: sent back as they were read. */
  [field: string]: unknown;
}

/**
 * A write of a repository's settings. `mode` and `autoReview` fall back to their defaults when
 * left out; `trustedReviewers` is kept. `version` (0 for a repository not registered) makes a
 * stale write a 409; left out, it is not checked. The style notes are not a setting (API 1.0.0):
 * they live in the rubrics repository, and a write naming `styleNotes` or `fromProposal` is a 400.
 */
export interface RepoSettings {
  mode?: PostingMode;
  autoReview?: boolean;
  trustedReviewers?: string[];
  /** 0 to 100; kept when left out. Changes only the pull requests split after it. */
  evalShare?: number;
  /** A type of the current rubric to fix, or "" for none; kept when left out. */
  prType?: string;
  /** 1 to 51; kept when left out. */
  maxFanout?: number;
  /** Incremental re-review on or off; kept when left out. */
  incremental?: boolean;
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
 * The rubric's parts keep the fields this client does not know (front matter a newer build
 * reads), as the server sends them.
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
  /**
   * Whether its reviews run as one sub-run per category plus the default, merged into one draft;
   * only when the repository fixes this type. Absent is false (API 0.7.0).
   */
  fanout?: boolean;
  [field: string]: unknown;
}

/** Where a rubric commit does not parse: the file and line, when known, and why. */
export interface RubricError {
  file: string | null;
  line: number | null;
  message: string;
}

/** One file of the rubric at its commit, with where to read it and where to edit it on GitHub. */
export interface RubricFile {
  path: string;
  /** The file at the commit (`…/blob/<sha>/<path>`). */
  url: string;
  /** GitHub's editor of the file on the branch (`…/edit/<branch>/<path>`). */
  editUrl: string;
}

/**
 * A repository's rubric as the rubrics repository holds it at one commit (API 1.0.0): read only,
 * changed by commits and pull requests on GitHub. The answer of `GET …/rubrics` (the commit in
 * use) and of `GET …/rubrics/commits/{sha}`. Front-matter keys of `rubric.md` this build does not
 * know are spread into it.
 */
export interface RubricView {
  owner: string;
  name: string;
  /** The rubrics repository, `owner/name`; null when none is configured. */
  repository: string | null;
  branch: string;
  /** The repository's directory in it, `owner/name`. */
  directory: string;
  /** The commit the rubric is read at; null when there is none to read (see `error`). */
  sha: string | null;
  /** `GET …/rubrics` only: the head of the branch last seen. Null at a commit asked for. */
  headSha: string | null;
  /** When the head was last read. */
  checkedAt: string | null;
  /**
   * Of `GET …/rubrics`: why the head is not the commit in use (it does not parse), or why there
   * is no rubric at all (an empty repository, a missing branch, none configured). Of a commit:
   * why it does not parse.
   */
  error: RubricError | null;
  /** Whether the directory exists at `sha`; false: no rubric there. */
  exists: boolean;
  defaultRubric: string;
  prTypes: PrType[];
  /** Whether every review fans out, over the fixed type's categories. */
  fanout: boolean;
  /** How the repository's reviews are written, in markdown (`style.md`); empty for none. */
  styleNotes: string;
  files: RubricFile[];
  /** The directory on the branch, on GitHub; null when there is none. */
  treeUrl: string | null;
  /** The integer version of the old platform this commit was exported from, if any. */
  legacyVersion: number | null;
  /** The calibration samples the rubric was derived from. */
  derivedFrom: string[];
  /** The pull requests (`owner/name#pr`) it was derived from. */
  derivedFromPulls: string[];
  [field: string]: unknown;
}

/** One commit of the rubrics repository touching a repository's directory. */
export interface RubricCommit {
  sha: string;
  message: string;
  author: string;
  authorLogin: string | null;
  date: string;
  /** The commit on GitHub. */
  url: string;
  legacyVersion: number | null;
}

/** What changed of a repository's rubric between two commits. */
export interface RubricCompare {
  base: string;
  head: string;
  /** The comparison on GitHub. */
  url: string;
  /** Null with `diffError` when either commit does not parse. */
  diff: RubricProposalDiff | null;
  diffError: string | null;
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
  /**
   * The rubrics repository's commit the review was checked against (API 1.0.0); null for a job
   * from before, or one reviewed with no rubric.
   */
  rubricSha: string | null;
  /**
   * Legacy: the rubric version of the old platform the review was checked against: 0 for none,
   * null when not recorded. Shown when `rubricSha` is null.
   */
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
  /** Legacy: the style notes version the agent was given, before the rubrics repository. */
  notesVersion?: number | null;
  /**
   * The sub-runs of a fan-out review, default first; empty when not fanned out. Only in the
   * answers of `GET /api/v1/jobs` and `GET /api/v1/jobs/{id}` (API 0.7.0).
   */
  subRuns?: SubRun[];
  /** An incremental re-review: the job whose posted review it follows up (API 0.8.0). */
  previousJob?: string | null;
  /** The head that review was of, from which the diff it reviews starts. */
  incrementalSince?: string | null;
  /** The commits since, at most 100. */
  incrementalCommits?: { sha: string; message: string }[] | null;
  /** Why a review that would have been incremental is a full one (a force-push, …). */
  fullReviewReason?: string | null;
}

/** One sub-run of a fan-out review (API 0.7.0). */
export interface SubRun {
  /** `default`, or made of the category's name; the agent names it `<job>.<key>`. */
  key: string;
  /** The category it reviews; null for the default review. */
  category: string | null;
  status: "pending" | "queued" | "running" | "submitted" | "failed" | "cancelled" | string;
  queueEntry: string | null;
  attempts: number;
  error: string | null;
  /** How many comments its partial review has, once submitted. */
  comments: number | null;
  updatedAt: string;
}

/** `proposal`: a rubric proposal of the repository (`prNumber` 0), never posted (API 0.6.0). */
export type JobKind = "review" | "calibration" | "proposal";

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
  /** Deleted: listed only when asked (`includeDeleted`). Absent before API 0.6.0. */
  deleted?: boolean;
  deletedAt?: string | null;
  /**
   * `eval` (held out: what runs measure by) or `pool` (what examples and proposals learn from),
   * fixed once assigned; null until then. Absent before API 0.6.0.
   */
  split?: "eval" | "pool" | null;
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
  /**
   * When GitHub's rate limit resets, while the import waits for it (refused for the limit, or
   * paused under the reserve); null otherwise. Absent before API 0.6.0.
   */
  resetAt?: string | null;
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
  /**
   * Scores of samples the rubric (with its style notes) was derived from, and whether they are
   * counted (`?derived=include`). Absent before API 0.6.0.
   */
  derivedScores?: number;
  derivedIncluded?: boolean;
  /**
   * Scores of jobs not checked out isolated at their commit, and whether they are counted (they
   * are unless `?unisolated=exclude`). Absent before API 0.9.0.
   */
  unisolatedScores?: number;
  unisolatedIncluded?: boolean;
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
  /** The rubric commit its job was reviewed against (API 1.0.0). */
  rubricSha: string | null;
  /** Legacy: the old platform's rubric version. */
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
    /** `eval` or `pool`, null until assigned. Absent before API 0.6.0. */
    split?: "eval" | "pool" | null;
  } | null;
  /** Null until the job's draft is scored. */
  score: CalibrationScore | CalibrationUnscorable | null;
  /** A review joined the sample after the score was made; the score is kept as it was. */
  scoreStale: boolean;
  /** The score is of a sample its rubric learned from: left out of the aggregate. */
  scoreDerived?: boolean;
  /**
   * Whether the job was checked out isolated at its commit: false when a force-push left the
   * commit unreached by its pull request's head and it ran on the default branch, null before
   * checkouts or until decided. Absent before API 0.9.0.
   */
  isolated?: boolean | null;
  /** The score is of a job not checked out isolated; counted unless asked not to. */
  scoreUnisolated?: boolean;
}

export interface CalibrationRun {
  id: string;
  owner: string;
  name: string;
  createdAt: string;
  /** The split it was run of; `pool` runs are never counted. Absent before API 0.9.0. */
  split?: "eval" | "pool";
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
  /**
   * By the rubric the jobs were reviewed against, newest first: its commit, or for jobs from
   * before the rubrics repository, the legacy version (0: no rubric; both null: unrecorded).
   */
  byRubric: RubricAggregate[];
  /** Whose scores: `eval`. Absent before API 0.6.0. */
  split?: string;
}

export interface RubricAggregate {
  rubricSha: string | null;
  rubricVersion: number | null;
  aggregate: CalibrationAggregate;
}

export type RubricProposalStatus = "pending" | "accepted" | "rejected";

/** `{before, after}` of a text a proposal changes; null when unchanged. */
export type TextChange = { before: string; after: string } | null;

/** A flag before and after, or null when it is the same. */
export type FlagChange = { before: boolean; after: boolean } | null;

/** What a proposal changes of the rubric it was written from, or one commit of another. */
export interface RubricProposalDiff {
  defaultRubric: TextChange;
  /** The document's `fanout`, when it changes (API 0.7.0). */
  fanout?: FlagChange;
  typesAdded: PrType[];
  /** Their names. */
  typesRemoved: string[];
  typesChanged: {
    name: string;
    description: TextChange;
    rubric: TextChange;
    /** The type's `fanout`, when the proposal changes it (API 0.7.0). */
    fanout?: FlagChange;
    categoriesAdded: Category[];
    categoriesRemoved: string[];
    /** Categories whose description changed. */
    categoriesChanged: { name: string; before: string; after: string }[];
  }[];
  /** Null when the proposal proposes no style notes, or the same. */
  styleNotes: TextChange;
}

/** The pull request a proposal is, on the rubrics repository. */
export interface ProposalPull {
  number: number;
  url: string;
  state: "open" | "merged" | "closed" | string;
}

/**
 * A rubric an agent proposed from the calibration data: a pull request on the rubrics repository
 * (API 1.0.0). Merged, it is accepted; closed unmerged, rejected. Decided on GitHub.
 */
export interface RubricProposal {
  id: string;
  owner: string;
  name: string;
  /** The `proposal` job that wrote it. */
  jobId: string;
  status: RubricProposalStatus | string;
  /** The rubric commit it was written from; null when there was none. */
  baseSha: string | null;
  /** The rubric commit in use now. */
  currentSha: string | null;
  /** Why, in markdown. */
  rationale: string;
  proposesStyleNotes: boolean;
  createdAt: string;
  decidedAt: string | null;
  /** The branch of the rubrics repository it is written on. */
  branch: string;
  /** Null until it is opened. */
  pullRequest: ProposalPull | null;
  /** Why the pull request could not be opened yet. */
  prError: string | null;
  /** The commit merging it made, once merged. */
  mergeSha: string | null;
  /** Only in the answer for one proposal. */
  document?: { defaultRubric: string; prTypes: PrType[]; [field: string]: unknown } | null;
  documentError?: string | null;
  styleNotes?: string | null;
  /** The style notes at its base, when it proposes some. */
  baseStyleNotes?: string | null;
  diff?: RubricProposalDiff | null;
  diffError?: string | null;
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
  /** One repository, with its settings and their version (API 0.6.0). */
  repo: (owner: string, name: string) =>
    request<Repo>("GET", `/api/v1/repos/${seg(owner)}/${seg(name)}`),
  /**
   * Write the settings named; see `RepoSettings` for what an omitted one does. Callers send the
   * `version` they read (0 to register), so that a write over a newer one is a 409; `putBody` in
   * `repoSettings.ts` makes the body from what was read.
   */
  putRepoSettings: (owner: string, name: string, settings: RepoSettings) =>
    request<Repo>("PUT", `/api/v1/repos/${seg(owner)}/${seg(name)}`, settings),
  deleteRepo: (owner: string, name: string) =>
    request<void>("DELETE", `/api/v1/repos/${seg(owner)}/${seg(name)}`),

  /** Review jobs, unless `kind` asks for calibration or proposal jobs, or all. */
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

  /** The rubric in use, at its commit, and what is wrong with the branch's head, if anything. */
  rubrics: (owner: string, name: string) =>
    request<RubricView>("GET", rubrics(owner, name)),
  /** One page of the commits touching the repository's rubric directory, newest first. */
  rubricHistory: (owner: string, name: string, limit = 50, offset = 0) =>
    request<Page<RubricCommit>>(
      "GET",
      `${rubrics(owner, name)}/history?${pageQuery(limit, offset)}`,
    ),
  /** The rubric at commit `sha` of the rubrics repository. */
  rubricAt: (owner: string, name: string, sha: string) =>
    request<RubricView>("GET", `${rubrics(owner, name)}/commits/${seg(sha)}`),
  /** What changed of the rubric from commit `base` to commit `head`. */
  compareRubrics: (owner: string, name: string, base: string, head: string) =>
    request<RubricCompare>(
      "GET",
      `${rubrics(owner, name)}/compare?base=${seg(base)}&head=${seg(head)}`,
    ),

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
  /**
   * One page of the samples, most recently reviewed first; with `includeDeleted`, the deleted ones
   * too, marked (API 0.6.0).
   */
  calibrationSamples: (
    owner: string,
    name: string,
    limit = 50,
    offset = 0,
    includeDeleted = false,
  ) =>
    request<Page<CalibrationSample>>(
      "GET",
      `${calibration(owner, name)}/samples?${pageQuery(limit, offset)}${
        includeDeleted ? "&deleted=include" : ""
      }`,
    ),
  calibrationSample: (owner: string, name: string, id: string) =>
    request<CalibrationSample>("GET", `${calibration(owner, name)}/samples/${seg(id)}`),
  /** Delete a sample; importing again neither brings it back nor adds to it. */
  deleteCalibrationSample: (owner: string, name: string, id: string) =>
    request<void>("DELETE", `${calibration(owner, name)}/samples/${seg(id)}`),
  /**
   * Run the agent on the samples named, or on `count` of those run least; at most 20. A sample a
   * live job is reviewing is refused (409); past the daily cap, 429. Of the `eval` samples unless
   * `split` is `pool` (evidence for proposals, never aggregated; API 0.6.0).
   */
  createCalibrationRun: (
    owner: string,
    name: string,
    which: ({ samples: string[] } | { count: number }) & { split?: "eval" | "pool" },
  ) => request<CalibrationRun>("POST", `${calibration(owner, name)}/runs`, which),
  /** One page of the runs, newest first, each with its aggregate. */
  calibrationRuns: (
    owner: string,
    name: string,
    limit = 50,
    offset = 0,
    stale = false,
    derived = false,
    isolatedOnly = false,
  ) =>
    request<Page<CalibrationRun>>(
      "GET",
      `${calibration(owner, name)}/runs?${pageQuery(limit, offset)}${scoreQuery(stale, derived, "&", isolatedOnly)}`,
    ),
  /**
   * One run, with each sample's result; `stale` counts stale scores in its aggregate, `derived`
   * the scores of samples its rubric or style notes learned from (API 0.6.0); `isolatedOnly`
   * leaves out the scores of jobs not checked out isolated (API 0.9.0).
   */
  calibrationRun: (
    owner: string,
    name: string,
    id: string,
    stale = false,
    derived = false,
    isolatedOnly = false,
  ) =>
    request<CalibrationRun>(
      "GET",
      `${calibration(owner, name)}/runs/${seg(id)}${scoreQuery(stale, derived, "?", isolatedOnly)}`,
    ),
  /**
   * The aggregate over every run, and by rubric; `stale` counts stale scores too, and
   * `derived` derived ones; `isolatedOnly` leaves out those of jobs not checked out isolated.
   */
  calibrationSummary: (
    owner: string,
    name: string,
    stale = false,
    derived = false,
    isolatedOnly = false,
  ) =>
    request<CalibrationSummary>(
      "GET",
      `${calibration(owner, name)}/summary${scoreQuery(stale, derived, "?", isolatedOnly)}`,
    ),

  /**
   * Ask an agent for a rubric proposal: answers the `proposal` job. 409 while one is live (a job
   * running, or a proposal whose pull request is open); 429 past the daily cap.
   */
  createProposal: (owner: string, name: string) =>
    request<Job>("POST", proposals(owner, name), {}),
  /** One page of the proposals, newest first, without documents and diffs. */
  proposals: (owner: string, name: string, limit = 50, offset = 0) =>
    request<Page<RubricProposal>>(
      "GET",
      `${proposals(owner, name)}?${pageQuery(limit, offset)}`,
    ),
  /** One proposal, with its document, style notes and diff against its base. */
  proposal: (owner: string, name: string, id: string) =>
    request<RubricProposal>("GET", `${proposals(owner, name)}/${seg(id)}`),
  /** Cancel a pending, queued or running proposal job: it fails, and its run is cancelled. */
  cancelProposalJob: (owner: string, name: string, jobId: string) =>
    request<Job>("POST", `${proposals(owner, name)}/jobs/${seg(jobId)}/cancel`, {}),
};

function rubrics(owner: string, name: string): string {
  return `/api/v1/repos/${seg(owner)}/${seg(name)}/rubrics`;
}

function proposals(owner: string, name: string): string {
  return `/api/v1/repos/${seg(owner)}/${seg(name)}/proposals`;
}

function calibration(owner: string, name: string): string {
  return `/api/v1/repos/${seg(owner)}/${seg(name)}/calibration`;
}

/** One page of a history; `nextOffset` is null on the last. */
export interface Page<T> {
  items: T[];
  nextOffset: number | null;
}

/**
 * `?stale=include` (or `&…`) when stale scores are to be counted, `derived=include` when
 * derived ones are, and `unisolated=exclude` when only isolated jobs' scores are.
 */
export function scoreQuery(
  stale: boolean,
  derived: boolean,
  sep: "?" | "&",
  isolatedOnly = false,
): string {
  const q = [
    ...(stale ? ["stale=include"] : []),
    ...(derived ? ["derived=include"] : []),
    ...(isolatedOnly ? ["unisolated=exclude"] : []),
  ];
  return q.length === 0 ? "" : `${sep}${q.join("&")}`;
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