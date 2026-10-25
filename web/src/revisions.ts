/**
 * What changed between two revisions of a job's review: the summary, the decision, and the
 * comments added, removed or changed, matched by their ids. The agent's draft beside what was
 * posted is what calibration learns from; this is how the page shows it.
 *
 * Pure functions only, so that what the page shows can be checked without a browser.
 */

import type { InlineComment, Revision, Review } from "./api";
import { parseReview, same } from "./review";

/** The review a revision holds, or why it cannot be shown. Read as stored, not checked. */
export function readRevision(r: Revision): Review | string {
  if (r.reviewError !== null) return r.reviewError;
  const out = parseReview(JSON.stringify(r.review ?? null), false);
  return typeof out === "string" ? `this revision is not a review this page can read: ${out}` : out;
}

export interface Change<T> {
  before: T;
  after: T;
}

export interface CommentChange extends Change<InlineComment> {
  /** What differs: `place` (file and lines), `body`, `suggestion`, `category`, `severity`, … */
  fields: string[];
}

export interface ReviewDiff {
  decision: Change<string> | null;
  body: Change<string> | null;
  /** Other fields of the review that differ, by name. */
  other: string[];
  added: InlineComment[];
  removed: InlineComment[];
  changed: CommentChange[];
  /** Comments the same on both sides. */
  unchanged: number;
  /** Comments paired without ids (a review stored before ids existed): by content or place. */
  guessed: number;
}

const hasId = (c: InlineComment) => typeof c.id === "string" && c.id !== "";

/** The fields in which two comments differ; the place (file and lines) counts as one. */
export function commentFields(a: InlineComment, b: InlineComment): string[] {
  const out: string[] = [];
  if (a.file !== b.file || a.start_line !== b.start_line || a.end_line !== b.end_line)
    out.push("place");
  const names = new Set([...Object.keys(a), ...Object.keys(b)]);
  for (const k of names) {
    if (k === "file" || k === "start_line" || k === "end_line") continue;
    // An id given on the next write is not a change the comment's writer made.
    if (k === "id" && (a.id === undefined || a.id === null)) continue;
    if (!same(a[k], b[k])) out.push(k);
  }
  return out;
}

/**
 * Pair the comments of `a` and `b`: by id where both carry one, which is how the platform follows
 * a comment from draft to post. A comment without an id (stored before ids existed; the next write
 * gives it one) pairs with a comment the very same but for the id, else with the one at the same
 * place, when only one is there. Two comments that both carry ids are never paired by a guess.
 * Anything else is an addition or a removal.
 */
export function pairComments(
  a: InlineComment[],
  b: InlineComment[],
): { pairs: [number, number][]; guessed: number } {
  const taken = new Set<number>();
  const pairs: [number, number][] = [];
  const of = new Map<number, number>();
  const byId = new Map<string, number>();
  b.forEach((c, j) => {
    if (hasId(c) && !byId.has(c.id as string)) byId.set(c.id as string, j);
  });
  a.forEach((c, i) => {
    if (!hasId(c)) return;
    const j = byId.get(c.id as string);
    if (j === undefined || taken.has(j)) return;
    taken.add(j);
    of.set(i, j);
  });
  let guessed = 0;
  const guessable = (x: InlineComment, y: InlineComment) => !(hasId(x) && hasId(y));
  const guess = (fits: (x: InlineComment, y: InlineComment) => boolean, unique: boolean) =>
    a.forEach((c, i) => {
      if (of.has(i)) return;
      const ok = (x: InlineComment, y: InlineComment) => guessable(x, y) && fits(x, y);
      const js = b.flatMap((d, j) => (!taken.has(j) && ok(c, d) ? [j] : []));
      const j = js[0];
      if (j === undefined || (unique && js.length !== 1)) return;
      if (unique && a.filter((x, k) => !of.has(k) && ok(x, b[j] as InlineComment)).length !== 1)
        return;
      taken.add(j);
      of.set(i, j);
      guessed++;
    });
  const withoutId = (x: InlineComment) => ({ ...x, id: undefined });
  guess((x, y) => same(withoutId(x), withoutId(y)), false);
  guess(
    (x, y) => x.file === y.file && x.start_line === y.start_line && x.end_line === y.end_line,
    true,
  );
  a.forEach((_, i) => {
    const j = of.get(i);
    if (j !== undefined) pairs.push([i, j]);
  });
  return { pairs, guessed };
}

/** What changed from review `a` to review `b`. */
export function diffReviews(a: Review, b: Review): ReviewDiff {
  const { pairs, guessed } = pairComments(a.comments, b.comments);
  const inA = new Set(pairs.map(([i]) => i));
  const inB = new Set(pairs.map(([, j]) => j));
  const changed: CommentChange[] = [];
  let unchanged = 0;
  for (const [i, j] of pairs) {
    const before = a.comments[i] as InlineComment;
    const after = b.comments[j] as InlineComment;
    const fields = commentFields(before, after);
    if (fields.length === 0) unchanged++;
    else changed.push({ before, after, fields });
  }
  const other = [...new Set([...Object.keys(a), ...Object.keys(b)])].filter(
    (k) => k !== "decision" && k !== "body" && k !== "comments" && !same(a[k], b[k]),
  );
  return {
    decision: a.decision === b.decision ? null : { before: a.decision, after: b.decision },
    body: a.body === b.body ? null : { before: a.body, after: b.body },
    other,
    added: b.comments.filter((_, j) => !inB.has(j)),
    removed: a.comments.filter((_, i) => !inA.has(i)),
    changed,
    unchanged,
    guessed,
  };
}

export function isEmptyDiff(d: ReviewDiff): boolean {
  return (
    d.decision === null &&
    d.body === null &&
    d.other.length === 0 &&
    d.added.length === 0 &&
    d.removed.length === 0 &&
    d.changed.length === 0
  );
}

/**
 * The two revisions calibration compares: the agent's first draft and the last of what GitHub
 * holds. Before the review is posted, the latest revision stands in for what was posted, and
 * `posted` says so.
 */
export function draftAndPosted(
  revs: Revision[],
): { draft: Revision; final: Revision; posted: boolean } | null {
  const draft = revs.find((r) => r.author === "agent");
  if (draft === undefined) return null;
  const github = revs.filter((r) => r.author === "github");
  const final = github[github.length - 1] ?? revs[revs.length - 1];
  if (final === undefined) return null;
  return { draft, final, posted: github.length > 0 };
}

export type LinePart = { kind: "same" | "add" | "del"; text: string };

/** The lines of `a` and `b` as a diff; past a size, simply all of `a` removed and `b` added. */
export function lineDiff(a: string, b: string): LinePart[] {
  const x = a === "" ? [] : a.split("\n");
  const y = b === "" ? [] : b.split("\n");
  if (x.length * y.length > 250000)
    return [
      ...x.map((text) => ({ kind: "del" as const, text })),
      ...y.map((text) => ({ kind: "add" as const, text })),
    ];
  // Longest common subsequence, from the end, so that the walk below goes forward.
  const n = x.length;
  const m = y.length;
  const lcs: number[][] = Array.from({ length: n + 1 }, () => new Array<number>(m + 1).fill(0));
  for (let i = n - 1; i >= 0; i--)
    for (let j = m - 1; j >= 0; j--)
      (lcs[i] as number[])[j] =
        x[i] === y[j]
          ? ((lcs[i + 1] as number[])[j + 1] as number) + 1
          : Math.max((lcs[i + 1] as number[])[j] as number, (lcs[i] as number[])[j + 1] as number);
  const out: LinePart[] = [];
  let i = 0;
  let j = 0;
  while (i < n || j < m) {
    if (i < n && j < m && x[i] === y[j]) {
      out.push({ kind: "same", text: x[i] as string });
      i++;
      j++;
    } else if (
      i < n &&
      (j >= m || ((lcs[i + 1] as number[])[j] as number) >= ((lcs[i] as number[])[j + 1] as number))
    ) {
      // Removals before additions, as a unified diff shows them.
      out.push({ kind: "del", text: x[i] as string });
      i++;
    } else {
      out.push({ kind: "add", text: y[j] as string });
      j++;
    }
  }
  return out;
}