/**
 * The review as the job page edits it, and where its comments land in a diff.
 *
 * Pure functions only, so that what the page shows can be checked without a browser.
 */

import type { Decision, InlineComment, Review } from "./api";
import { displayPath, type DiffFile } from "./diff";

/**
 * The key a comment is known by while the page edits it. A symbol, so that it can never clash
 * with a field of the review, and `JSON.stringify` leaves it out on its own.
 */
export const KEY: unique symbol = Symbol("comment key");

/** A comment with a key that stays put while comments around it are added and deleted. */
export interface LocalComment extends InlineComment {
  [KEY]: number;
}

export interface LocalReview {
  decision: Decision;
  body: string;
  comments: LocalComment[];
  [field: string]: unknown;
}

/** Key `r`'s comments: by `keys` where given (a stored edit), else by position. */
export function toLocal(r: Review, keys?: number[]): LocalReview {
  return { ...r, comments: r.comments.map((c, i) => ({ ...c, [KEY]: keys?.[i] ?? i })) };
}

/** The review as the API takes it: every field it came with, the keys dropped. */
export function toReview(r: LocalReview): Review {
  return { ...r, comments: r.comments.map(withoutKey) };
}

function withoutKey(c: LocalComment): InlineComment {
  const out: Partial<LocalComment> & InlineComment = { ...c };
  delete out[KEY];
  return out;
}

export function nextKey(r: LocalReview): number {
  return r.comments.reduce((k, c) => Math.max(k, c[KEY] + 1), 0);
}

/**
 * `old` with the fields a form edits replaced by `edited`'s, and the rest kept. A suggestion
 * turned off is removed, not left behind.
 */
export function mergeComment(old: LocalComment, edited: InlineComment): LocalComment {
  const out: LocalComment = {
    ...old,
    file: edited.file,
    start_line: edited.start_line,
    end_line: edited.end_line,
    body: edited.body,
  };
  if (edited.suggestion === undefined) delete out.suggestion;
  else out.suggestion = edited.suggestion;
  return out;
}

/** Equality of JSON values; symbol keys (the comment keys) do not count. */
export function same(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (typeof a !== "object" || typeof b !== "object" || a === null || b === null) return false;
  if (Array.isArray(a) !== Array.isArray(b)) return false;
  if (Array.isArray(a) && Array.isArray(b))
    return a.length === b.length && a.every((x, i) => same(x, b[i]));
  const ra = a as Record<string, unknown>;
  const rb = b as Record<string, unknown>;
  const ka = Object.keys(ra).filter((k) => ra[k] !== undefined);
  const kb = Object.keys(rb).filter((k) => rb[k] !== undefined);
  return ka.length === kb.length && ka.every((k) => same(ra[k], rb[k]));
}

/** Whether two reviews say the same, keys aside. */
export function sameReview(a: LocalReview, b: LocalReview): boolean {
  return same(toReview(a), toReview(b));
}

/**
 * Key `other`'s comments by the comments of `known` they are: first those that are the same, then
 * those at the same place (an edited comment keeps its place). With `positional`, the comments
 * left over then pair up in order, as an edit of the same list does; without it, they are new.
 * The review has no comment ids, so this is the best a page can do, and what it gets wrong
 * shows up as a conflict, not as a lost edit.
 */
export function align(
  known: LocalComment[],
  other: InlineComment[],
  positional: boolean,
  fresh: () => number,
): LocalComment[] {
  const keys: (number | undefined)[] = other.map(() => undefined);
  const used = new Set<number>();
  const pass = (fits: (k: LocalComment, o: InlineComment) => boolean) => {
    other.forEach((o, i) => {
      if (keys[i] !== undefined) return;
      const k = known.find((c) => !used.has(c[KEY]) && fits(c, o));
      if (k === undefined) return;
      keys[i] = k[KEY];
      used.add(k[KEY]);
    });
  };
  pass((k, o) => same(withoutKey(k), o));
  pass((k, o) => k.file === o.file && k.start_line === o.start_line && k.end_line === o.end_line);
  // The first comment not yet taken, in order.
  if (positional) pass(() => true);
  return other.map((o, i) => ({ ...o, [KEY]: keys[i] ?? fresh() }));
}

/** A counter past every key in `rs`, for comments that are new to all of them. */
export function freshKeys(...rs: LocalReview[]): () => number {
  let next = Math.max(0, ...rs.map(nextKey));
  return () => next++;
}

/**
 * The review `text` (JSON someone edited) says, keyed against `current` so that edits stay edits
 * of the same comments; new comments get keys `base` has not used either.
 */
export function fromJson(
  text: string,
  current: LocalReview,
  base: LocalReview,
): LocalReview | string {
  const r = parseReview(text);
  if (typeof r === "string") return r;
  return { ...r, comments: align(current.comments, r.comments, true, freshKeys(current, base)) };
}

/** Where this person and another writer changed the same thing differently. */
export type Conflict =
  | { kind: "field"; name: string; mine: unknown; theirs: unknown }
  | { kind: "comment"; key: number; mine: LocalComment | null; theirs: LocalComment | null };

export function conflictId(c: Conflict): string {
  return c.kind === "field" ? `field:${c.name}` : `comment:${c.key}`;
}

export interface Rebased {
  /** `theirs` with this person's changes made to it; where both changed a thing, theirs. */
  review: LocalReview;
  /** `theirs`, keyed like the edits: what the edits are now changes to. */
  base: LocalReview;
  conflicts: Conflict[];
}

/**
 * Move this person's edits (`mine`, made to `base`) onto a newer version (`theirs`): what only
 * one side changed takes that side's change, what both changed alike is that, and what both
 * changed differently is a conflict, left at their version until the person picks one. Nothing
 * the other writer did is undone without the person choosing so.
 */
export function rebase(base: LocalReview, mine: LocalReview, theirsReview: Review): Rebased {
  const theirs: LocalReview = {
    ...theirsReview,
    comments: align(base.comments, theirsReview.comments, false, freshKeys(base, mine)),
  };
  const conflicts: Conflict[] = [];
  const review: LocalReview = { ...theirs, comments: [] };

  const names = new Set([...Object.keys(base), ...Object.keys(mine), ...Object.keys(theirs)]);
  names.delete("comments");
  for (const name of names) {
    const [b, m, t] = [base[name], mine[name], theirs[name]];
    let v = t;
    if (same(t, b)) v = m;
    else if (!same(m, b) && !same(m, t))
      conflicts.push({ kind: "field", name, mine: m, theirs: t });
    if (v === undefined) delete review[name];
    else review[name] = v;
  }

  const byKey = (cs: LocalComment[]) => new Map(cs.map((c) => [c[KEY], c]));
  const [b, m, t] = [byKey(base.comments), byKey(mine.comments), byKey(theirs.comments)];
  const comment = (
    key: number,
    bc: LocalComment,
    mc: LocalComment | null,
    tc: LocalComment | null,
  ) => {
    if (mc !== null && same(mc, bc)) return tc;
    if (tc !== null && same(tc, bc)) return mc;
    if (mc === null && tc === null) return null;
    if (mc !== null && tc !== null && same(mc, tc)) return tc;
    conflicts.push({ kind: "comment", key, mine: mc, theirs: tc });
    return tc;
  };
  for (const tc of theirs.comments) {
    const bc = b.get(tc[KEY]);
    const out = bc === undefined ? tc : comment(tc[KEY], bc, m.get(tc[KEY]) ?? null, tc);
    if (out !== null) review.comments.push(out);
  }
  for (const bc of base.comments) {
    if (t.has(bc[KEY])) continue;
    const out = comment(bc[KEY], bc, m.get(bc[KEY]) ?? null, null);
    if (out !== null) review.comments.push(out);
  }
  for (const mc of mine.comments) if (!b.has(mc[KEY])) review.comments.push(mc);
  return { review, base: theirs, conflicts };
}

/** `r` with a conflict settled one way. Picking again settles it the other way. */
export function resolve(r: LocalReview, c: Conflict, pick: "mine" | "theirs"): LocalReview {
  if (c.kind === "field") {
    const out: LocalReview = { ...r };
    const v = pick === "mine" ? c.mine : c.theirs;
    if (v === undefined) delete out[c.name];
    else out[c.name] = v;
    return out;
  }
  const v = pick === "mine" ? c.mine : c.theirs;
  const rest = r.comments.filter((x) => x[KEY] !== c.key);
  if (v === null) return { ...r, comments: rest };
  const at = r.comments.findIndex((x) => x[KEY] === c.key);
  const comments = [...rest];
  comments.splice(at < 0 ? comments.length : at, 0, v);
  return { ...r, comments };
}

/** A local review as JSON can hold it: the keys beside the review, not in it. */
export interface Frozen {
  review: Review;
  keys: number[];
}

export function freeze(r: LocalReview): Frozen {
  return { review: toReview(r), keys: r.comments.map((c) => c[KEY]) };
}

export function thaw(f: unknown): LocalReview | null {
  if (typeof f !== "object" || f === null) return null;
  const { review, keys } = f as { review?: unknown; keys?: unknown };
  const r = parseReview(JSON.stringify(review ?? null), false);
  if (typeof r === "string" || !Array.isArray(keys) || keys.length !== r.comments.length)
    return null;
  if (!keys.every((k) => Number.isInteger(k))) return null;
  return toLocal(r, keys as number[]);
}

/** Why the server would refuse `c`, or `null`; mirrors `Review.validate` in Lean. */
export function commentProblem(c: InlineComment): string | null {
  if (c.file.trim() === "") return "The comment names no file.";
  if (!Number.isInteger(c.start_line) || c.start_line < 1) return "Lines start at 1.";
  if (!Number.isInteger(c.end_line) || c.end_line < c.start_line)
    return "The last line is before the first.";
  if (c.body.trim() === "" && c.suggestion === undefined) return "The comment says nothing.";
  return null;
}

export function reviewProblem(r: Review): string | null {
  for (const [i, c] of r.comments.entries()) {
    const p = commentProblem(c);
    if (p !== null) return `Comment ${i + 1}: ${p}`;
  }
  return null;
}

const decisions: readonly string[] = ["comment", "approve", "request_changes"];

/**
 * Read a review someone typed as JSON; answers why it is not one, as a string, if it is not.
 * Fields it does not know are kept. `validate` checks it as the server will.
 */
export function parseReview(text: string, validate = true): Review | string {
  let j: unknown;
  try {
    j = JSON.parse(text);
  } catch {
    return "The review is not valid JSON.";
  }
  if (!isObject(j)) return "The review must be a JSON object.";
  if (typeof j.decision !== "string" || !decisions.includes(j.decision))
    return `"decision" must be one of ${decisions.join(", ")}.`;
  if (typeof j.body !== "string") return '"body" must be a string.';
  if (!Array.isArray(j.comments)) return '"comments" must be an array.';
  const comments: InlineComment[] = [];
  for (const [i, c] of (j.comments as unknown[]).entries()) {
    const at = `Comment ${i + 1}`;
    if (!isObject(c)) return `${at} must be an object.`;
    if (typeof c.file !== "string") return `${at}: "file" must be a string.`;
    if (typeof c.start_line !== "number" || typeof c.end_line !== "number")
      return `${at}: "start_line" and "end_line" must be numbers.`;
    if (typeof c.body !== "string") return `${at}: "body" must be a string.`;
    if (c.suggestion !== undefined && c.suggestion !== null && typeof c.suggestion !== "string")
      return `${at}: "suggestion" must be a string.`;
    const out: InlineComment = {
      ...c,
      file: c.file,
      start_line: c.start_line,
      end_line: c.end_line,
      body: c.body,
    };
    // `null` is how some writers say "none"; the server reads it so too.
    if (typeof c.suggestion !== "string") delete out.suggestion;
    comments.push(out);
  }
  const review: Review = { ...j, decision: j.decision as Decision, body: j.body, comments };
  return (validate ? reviewProblem(review) : null) ?? review;
}

function isObject(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

/** For each new-side line a file's diff shows, the index of the hunk that shows it. */
export function newLineHunks(f: DiffFile): Map<number, number> {
  const m = new Map<number, number>();
  f.hunks.forEach((h, hi) => {
    for (const l of h.lines) if (l.newLine !== null) m.set(l.newLine, hi);
  });
  return m;
}

export interface Placement {
  /** Per file path, per new-side line: the comments that end on it, in review order. */
  anchored: Map<string, Map<number, LocalComment[]>>;
  /** Comments whose last line the diff does not show, or whose file it does not touch. */
  outside: LocalComment[];
  /** Keys of anchored comments whose first line is not in the hunk of the last: GitHub refuses those. */
  split: Set<number>;
  /** Per file path, the new-side lines some comment covers. */
  covered: Map<string, Set<number>>;
}

/**
 * Where each comment goes: under the line it ends on, which is where GitHub shows it too.
 * Every comment lands somewhere, so a review whose lines moved loses nothing.
 */
export function placeComments(files: DiffFile[], comments: LocalComment[]): Placement {
  const hunksOf = new Map<string, Map<number, number>>();
  for (const f of files) if (f.newPath !== null) hunksOf.set(f.newPath, newLineHunks(f));
  const p: Placement = { anchored: new Map(), outside: [], split: new Set(), covered: new Map() };
  for (const c of comments) {
    const lines = hunksOf.get(c.file);
    const endHunk = lines?.get(c.end_line);
    if (lines === undefined || endHunk === undefined) {
      p.outside.push(c);
      continue;
    }
    if (lines.get(c.start_line) !== endHunk) p.split.add(c[KEY]);
    let byLine = p.anchored.get(c.file);
    if (byLine === undefined) p.anchored.set(c.file, (byLine = new Map()));
    const at = byLine.get(c.end_line);
    if (at === undefined) byLine.set(c.end_line, [c]);
    else at.push(c);
    let cov = p.covered.get(c.file);
    if (cov === undefined) p.covered.set(c.file, (cov = new Set()));
    // Over the lines shown, not the range: an agent's range can be absurdly long.
    for (const n of lines.keys()) if (n >= c.start_line && n <= c.end_line) cov.add(n);
  }
  return p;
}

/** How many comments a file carries, for its header. */
export function commentsIn(p: Placement, f: DiffFile): number {
  const byLine = p.anchored.get(displayPath(f));
  if (byLine === undefined || f.newPath === null) return 0;
  let n = 0;
  for (const cs of byLine.values()) n += cs.length;
  return n;
}

export function rangeLabel(c: { start_line: number; end_line: number }): string {
  return c.start_line === c.end_line ? `line ${c.end_line}` : `lines ${c.start_line}–${c.end_line}`;
}