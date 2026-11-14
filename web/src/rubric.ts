/**
 * A repository's rubric as the pages read it: the categories a review may use, which mirror
 * `categoriesFor` in Lean; which rubric a job was checked against; and what the rubric page shows
 * of a commit of the rubrics repository, where rubrics live and are changed (API 1.0.0). The
 * platform only reads them: the page links to the files on GitHub to edit them.
 *
 * Pure functions only, so that what the pages do can be checked without a browser.
 */

import type {
  InlineComment,
  PrType,
  Review,
  RubricCommit,
  RubricError,
  RubricView,
} from "./api";
import { MAX_CATEGORY_LENGTH } from "./review";
import { blankAscii, charLength } from "./text";

/** What `categoriesFor` reads of a rubric. */
export interface RubricDoc {
  defaultRubric: string;
  prTypes: PrType[];
  [field: string]: unknown;
}

/**
 * The categories a comment of a review of type `prType` may be filed under; mirrors
 * `Rubric.categoriesFor`. The type's, when the rubric names it — none, for a type that lists
 * none, and then a category is free text. A review of no type the rubric names (a job reviewed by
 * hand) may use any category of the rubric, or free text if it names none. Empty means free text.
 */
export function categoriesFor(d: Pick<RubricDoc, "prTypes">, prType: string | null): string[] {
  const t = prType === null ? undefined : d.prTypes.find((x) => x.name === prType);
  if (t !== undefined) return (t.categories ?? []).map((c) => c.name);
  const out: string[] = [];
  for (const x of d.prTypes)
    for (const c of x.categories ?? []) if (!out.includes(c.name)) out.push(c.name);
  return out;
}

/** Which rubric a job's comments are checked against. */
export type JobRubric = { kind: "sha"; sha: string } | { kind: "none" } | { kind: "current" };

/**
 * The rubric a job's comments are checked against: the commit it records (`rubricSha`); for a
 * job from before the rubrics repository, none when it was reviewed with none (legacy version 0),
 * and otherwise — no rubric recorded, or a legacy version, which is no commit — the rubric in use.
 */
export function rubricOfJob(j: {
  rubricSha?: string | null;
  rubricVersion: number | null;
}): JobRubric {
  if (typeof j.rubricSha === "string") return { kind: "sha", sha: j.rubricSha };
  if (j.rubricVersion === 0) return { kind: "none" };
  return { kind: "current" };
}

/** A commit as the pages name it: its first seven hex digits. */
export function shortSha(sha: string): string {
  return sha.slice(0, 7);
}

/**
 * How a job's rubric (or a calibration aggregate's) is named: its commit, short; else the legacy
 * version of the old platform (`v3`), `none` for none; null when nothing was recorded.
 */
export function rubricLabel(r: {
  rubricSha?: string | null;
  rubricVersion: number | null;
}): string | null {
  if (typeof r.rubricSha === "string") return shortSha(r.rubricSha);
  if (r.rubricVersion === null) return null;
  return r.rubricVersion === 0 ? "none" : `v${r.rubricVersion}`;
}

/** The rubric page of a repository, at commit `sha` when one is given. */
export function rubricPath(owner: string, name: string, sha?: string | null): string {
  const base = `/repos/${encodeURIComponent(owner)}/${encodeURIComponent(name)}/rubric`;
  return typeof sha === "string" ? `${base}?sha=${encodeURIComponent(sha)}` : base;
}

/** What the rubric page has to say of a view. */
export type RubricState =
  /** No rubrics repository is configured. */
  | { kind: "unconfigured" }
  /** No commit to read the rubric at: an empty repository, a missing branch; `error` says. */
  | { kind: "none"; error: RubricError | null }
  /**
   * A rubric at `sha`. `headBroken`: the branch's head does not parse, and this commit, the last
   * good one, is in use; `error` says where.
   */
  | { kind: "rubric"; headBroken: boolean };

export function rubricState(v: Pick<RubricView, "repository" | "sha" | "error">): RubricState {
  if (v.repository === null) return { kind: "unconfigured" };
  if (v.sha === null) return { kind: "none", error: v.error };
  return { kind: "rubric", headBroken: v.error !== null };
}

/** Where a rubric error is, `file, line n`; empty when it names no file. */
export function errorWhere(e: RubricError): string {
  if (e.file === null) return "";
  return e.line === null ? e.file : `${e.file}, line ${e.line}`;
}

/** The fields of a view this build knows; the rest are front matter of a newer one. */
const viewFields = new Set([
  "owner",
  "name",
  "repository",
  "branch",
  "directory",
  "sha",
  "headSha",
  "checkedAt",
  "error",
  "exists",
  "defaultRubric",
  "prTypes",
  "fanout",
  "styleNotes",
  "files",
  "treeUrl",
  "legacyVersion",
  "derivedFrom",
  "derivedFromPulls",
]);

const typeFields = new Set(["name", "description", "rubric", "categories", "fanout"]);

/** The front-matter keys of `rubric.md` this build does not know, in the order the server sent. */
export function extraFields(v: RubricView): [string, unknown][] {
  return Object.entries(v).filter(([k]) => !viewFields.has(k));
}

/** A type's front-matter keys this build does not know. */
export function typeExtras(t: PrType): [string, unknown][] {
  return Object.entries(t).filter(([k]) => !typeFields.has(k));
}

/** A value of front matter as text: a string as it is, anything else as JSON. */
export function showValue(v: unknown): string {
  return typeof v === "string" ? v : JSON.stringify(v);
}

/** The first line of a commit message. */
export function commitTitle(message: string): string {
  const i = message.indexOf("\n");
  return (i < 0 ? message : message.slice(0, i)).trim();
}

/**
 * The commits picked to compare after `sha` is clicked: unpicked when it was picked; otherwise
 * picked, the earlier of two picks let go, so that at most two are ever picked.
 */
export function togglePick(picked: string[], sha: string): string[] {
  if (picked.includes(sha)) return picked.filter((s) => s !== sha);
  return [...picked, sha].slice(-2);
}

/**
 * Two commits of the history (newest first) as a comparison: the older the base, the newer the
 * head. Null unless both are in it, and two.
 */
export function comparePair(
  items: Pick<RubricCommit, "sha">[],
  a: string,
  b: string,
): { base: string; head: string } | null {
  const i = items.findIndex((c) => c.sha === a);
  const j = items.findIndex((c) => c.sha === b);
  if (i < 0 || j < 0 || i === j) return null;
  return i > j ? { base: a, head: b } : { base: b, head: a };
}

/**
 * Why the server would refuse category `cat` on a comment it checks, or `null`. `allowed` is
 * `categoriesFor`'s answer (empty: free text).
 */
export function categoryProblem(cat: string | undefined, allowed: string[]): string | null {
  if (cat === undefined) return null;
  if (blankAscii(cat) || charLength(cat) > MAX_CATEGORY_LENGTH)
    return `The category must be 1 to ${MAX_CATEGORY_LENGTH} characters.`;
  if (allowed.length > 0 && !allowed.includes(cat))
    return `"${cat}" is not a category of the rubric; it is one of ${allowed.join(", ")}.`;
  return null;
}

/**
 * The categories the stored review's comments have, by comment id: what the server takes a
 * comment's category to be unchanged from. A comment without an id is always checked.
 */
export function storedCategories(r: Review | null): Map<string, string | undefined> {
  const out = new Map<string, string | undefined>();
  for (const c of r?.comments ?? []) if (typeof c.id === "string") out.set(c.id, c.category);
  return out;
}

/** Why the server would refuse comment `c`'s category, checked as `putReview` checks it. */
export function commentCategoryProblem(
  c: InlineComment,
  allowed: string[],
  stored: Map<string, string | undefined>,
): string | null {
  const unchanged = typeof c.id === "string" && stored.has(c.id) && stored.get(c.id) === c.category;
  return unchanged ? null : categoryProblem(c.category, allowed);
}

/** The first comment of `r` whose category the server would refuse, said as it would say it. */
export function reviewCategoryProblem(
  r: Review,
  allowed: string[],
  stored: Map<string, string | undefined>,
): string | null {
  for (const [i, c] of r.comments.entries()) {
    const p = commentCategoryProblem(c, allowed, stored);
    if (p !== null) return `Comment ${i + 1}: ${p}`;
  }
  return null;
}