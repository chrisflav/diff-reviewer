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

/** Whether a comment carries the stable id a newer backend gives every comment. */
function hasId(c: InlineComment): boolean {
  return c.id !== undefined && c.id !== null;
}

/**
 * Whether `k` and `o` may be paired by a guess. Two comments that both carry ids are the same
 * comment exactly when their ids are equal, so no guess applies to them.
 */
function guessable(k: InlineComment, o: InlineComment): boolean {
  return !(hasId(k) && hasId(o));
}

/**
 * Give each of `other`'s comments without a key yet the key of the first comment of `known` that
 * `fits` it and is not taken; among several, the one `rank` puts lowest.
 */
function pair(
  known: LocalComment[],
  other: InlineComment[],
  keys: (number | undefined)[],
  used: Set<number>,
  fits: (k: LocalComment, o: InlineComment) => boolean,
  rank: (k: LocalComment) => number = () => 0,
) {
  other.forEach((o, i) => {
    if (keys[i] !== undefined) return;
    let best: LocalComment | undefined;
    for (const k of known)
      if (!used.has(k[KEY]) && fits(k, o) && (best === undefined || rank(k) < rank(best))) best = k;
    if (best === undefined) return;
    keys[i] = best[KEY];
    used.add(best[KEY]);
  });
}

const byId = (k: InlineComment, o: InlineComment) => hasId(k) && hasId(o) && same(k.id, o.id);
const samePlace = (k: InlineComment, o: InlineComment) =>
  k.file === o.file && k.start_line === o.start_line && k.end_line === o.end_line;

/**
 * Key `other`'s comments by the comments of `known` they are: by id where both carry one;
 * otherwise first those that are the same, then those at the same place (an edited comment keeps
 * its place). With `positional`, the comments left over then pair up in order, as an edit of the
 * same list does; without it, they are new. Without ids this is a guess, and what it gets wrong
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
  const go = (fits: (k: LocalComment, o: InlineComment) => boolean) =>
    pair(known, other, keys, used, fits);
  go(byId);
  go((k, o) => guessable(k, o) && same(withoutKey(k), o));
  go((k, o) => guessable(k, o) && samePlace(k, o));
  // The first comment not yet taken, in order.
  if (positional) go(guessable);
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

/**
 * Where this person and another writer changed the same thing differently. For a comment, `key`
 * is its key in the base; `theirs` may carry another key, when it is the comment that took its
 * place on their side (deleted there, and one added in the same file).
 */
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
 * Three-way merge of the fields of `base` (an object), `mine` and `theirs`: what only one side
 * changed takes that change. Answers the merge and the names both changed differently.
 */
function mergeFields<T extends Record<string, unknown>>(
  base: T,
  mine: T,
  theirs: T,
  skip: string[] = [],
): [Record<string, unknown>, string[]] {
  const out: Record<string, unknown> = { ...theirs };
  const clashes: string[] = [];
  const names = new Set([...Object.keys(base), ...Object.keys(mine), ...Object.keys(theirs)]);
  for (const name of names) {
    if (skip.includes(name)) continue;
    const [b, m, t] = [base[name], mine[name], theirs[name]];
    let v = t;
    if (same(t, b)) v = m;
    else if (!same(m, b) && !same(m, t)) clashes.push(name);
    if (v === undefined) delete out[name];
    else out[name] = v;
  }
  return [out, clashes];
}

/**
 * Key the other writer's comments by the comments they are: those of `base`, or this person's
 * new ones (`added`) where the other side has the very same (a save of these edits that landed
 * though its answer was lost, or a second tab with the same edits). By id where both carry one;
 * else, in turn: the same as in the base, the same as this person's version of it, the same as
 * one of this person's new ones, at the same place, and — a comment moved — in the same file with
 * the same body or suggestion. Among several equal candidates, one this person edited is taken
 * first and one they deleted last, so that the other side's edits and deletions of identical
 * comments land where they lose least.
 */
function alignTheirs(
  base: LocalReview,
  mine: LocalReview,
  theirs: InlineComment[],
  fresh: () => number,
): LocalComment[] {
  const inBase = new Set(base.comments.map((c) => c[KEY]));
  const mineBy = new Map(mine.comments.map((c) => [c[KEY], c]));
  const added = mine.comments.filter((c) => !inBase.has(c[KEY]));
  const rank = (k: LocalComment) => {
    const m = mineBy.get(k[KEY]);
    return m === undefined ? 2 : same(m, k) ? 1 : 0;
  };
  const keys: (number | undefined)[] = theirs.map(() => undefined);
  const used = new Set<number>();
  const go = (
    known: LocalComment[],
    fits: (k: LocalComment, o: InlineComment) => boolean,
    r?: (k: LocalComment) => number,
  ) => pair(known, theirs, keys, used, fits, r);
  const all = [...base.comments, ...added];
  go(all, byId);
  go(base.comments, (k, o) => guessable(k, o) && same(withoutKey(k), o), rank);
  go(
    base.comments,
    (k, o) => {
      const m = mineBy.get(k[KEY]);
      return m !== undefined && guessable(m, o) && same(withoutKey(m), o);
    },
    rank,
  );
  go(added, (k, o) => guessable(k, o) && same(withoutKey(k), o));
  go(base.comments, (k, o) => guessable(k, o) && samePlace(k, o), rank);
  // A moved comment: the same words in the same file. Only where the pairing is the one
  // possible, both ways; two comments saying the same ("nit: naming") are not told apart by a
  // guess, and what is left unpaired goes to the conflict path instead.
  const moved = (k: LocalComment, o: InlineComment) =>
    guessable(k, o) &&
    k.file === o.file &&
    ((k.body.trim() !== "" && k.body === o.body) ||
      (k.suggestion !== undefined && k.suggestion === o.suggestion));
  const freeBase = base.comments.filter((k) => !used.has(k[KEY]));
  const freeTheirs = theirs.filter((_, i) => keys[i] === undefined);
  theirs.forEach((o, i) => {
    if (keys[i] !== undefined) return;
    const ks = freeBase.filter((k) => moved(k, o));
    const k = ks[0];
    if (ks.length !== 1 || k === undefined) return;
    if (freeTheirs.filter((x) => moved(k, x)).length !== 1) return;
    keys[i] = k[KEY];
    used.add(k[KEY]);
  });
  return theirs.map((o, i) => ({ ...o, [KEY]: keys[i] ?? fresh() }));
}

/** Where a comment is: its lines, and the suggestion, which is written for exactly those. */
const placeFields = ["file", "start_line", "end_line", "suggestion"];

function placeOf(c: InlineComment): unknown[] {
  return placeFields.map((f) => c[f]);
}

/**
 * A comment both sides changed, merged: its place (file, lines and suggestion, as one) and each
 * other field take the change of the side that made one. `null` where both changed the place,
 * or another field, differently: a line moved on one side and a file or a suggestion changed on
 * the other would mix two places.
 */
export function mergeComment3(
  bc: LocalComment,
  mc: LocalComment,
  tc: LocalComment,
): LocalComment | null {
  const [pb, pm, pt] = [placeOf(bc), placeOf(mc), placeOf(tc)];
  if (!same(pm, pb) && !same(pt, pb) && !same(pm, pt)) return null;
  const [merged, clash] = mergeFields(bc, mc, tc, placeFields);
  if (clash.length > 0) return null;
  const from = same(pt, pb) ? mc : tc;
  const out = { ...merged, [KEY]: bc[KEY] } as LocalComment;
  for (const f of placeFields) {
    if (from[f] === undefined) delete out[f];
    else out[f] = from[f];
  }
  return out;
}

/** Whether two comments' ranges overlap or lie within a few lines of each other. */
function near(a: InlineComment, b: InlineComment): boolean {
  return Math.max(a.start_line, b.start_line) - Math.min(a.end_line, b.end_line) <= 3;
}

/**
 * Move this person's edits (`mine`, made to `base`) onto a newer version (`theirs`): what only
 * one side changed takes that side's change, field by field, comments included; what both changed
 * alike is that; and what both changed differently is a conflict, left at their version until the
 * person picks one. Nothing the other writer did is undone without the person choosing so.
 */
export function rebase(base: LocalReview, mine: LocalReview, theirsReview: Review): Rebased {
  const theirs: LocalReview = {
    ...theirsReview,
    comments: alignTheirs(base, mine, theirsReview.comments, freshKeys(base, mine)),
  };
  const conflicts: Conflict[] = [];
  const [fields, clashes] = mergeFields(base, mine, theirs, ["comments"]);
  const review = { ...fields, comments: [] } as unknown as LocalReview;
  for (const name of clashes)
    conflicts.push({ kind: "field", name, mine: mine[name], theirs: theirs[name] });

  const byKey = (cs: LocalComment[]) => new Map(cs.map((c) => [c[KEY], c]));
  const [b, m, t] = [byKey(base.comments), byKey(mine.comments), byKey(theirs.comments)];
  const comment = (
    key: number,
    bc: LocalComment,
    mc: LocalComment | null,
    tc: LocalComment | null,
  ): LocalComment | null => {
    if (mc !== null && same(mc, bc)) return tc;
    if (tc !== null && same(tc, bc)) return mc;
    if (mc === null && tc === null) return null;
    if (mc !== null && tc !== null) {
      if (same(mc, tc)) return tc;
      const merged = mergeComment3(bc, mc, tc);
      if (merged !== null) return merged;
    }
    conflicts.push({ kind: "comment", key, mine: mc, theirs: tc });
    return tc;
  };
  for (const tc of theirs.comments) {
    const bc = b.get(tc[KEY]);
    const out = bc === undefined ? tc : comment(tc[KEY], bc, m.get(tc[KEY]) ?? null, tc);
    if (out !== null) review.comments.push(out);
  }
  // Their new comments, which may stand where a comment of the base was.
  const stand = theirs.comments.filter((c) => !b.has(c[KEY]) && !m.has(c[KEY]));
  for (const bc of base.comments) {
    if (t.has(bc[KEY])) continue;
    const mc = m.get(bc[KEY]) ?? null;
    const at =
      mc === null || same(mc, bc)
        ? -1
        : stand.findIndex((c) => c.file === bc.file && guessable(c, bc) && near(c, bc));
    const sub = stand[at];
    if (sub !== undefined) {
      // Deleted on their side, with a new comment at or just by its lines, and edited on this
      // one: perhaps the same comment, changed by both. Their new one stays until the person
      // picks, and "both" is a choice, since it may be another comment altogether.
      stand.splice(at, 1);
      conflicts.push({ kind: "comment", key: bc[KEY], mine: mc, theirs: sub });
      continue;
    }
    const out = comment(bc[KEY], bc, mc, null);
    if (out !== null) review.comments.push(out);
  }
  // This person's new comments; one the other side has too is there already.
  for (const mc of mine.comments) if (!b.has(mc[KEY]) && !t.has(mc[KEY])) review.comments.push(mc);
  return { review, base: theirs, conflicts };
}

/** `r` with a conflict settled one way. Picking again settles it the other way. */
export type Pick = "mine" | "theirs" | "both";

/** Whether keeping both sides is a choice: both are there, as two comments (not one changed). */
export function canKeepBoth(c: Conflict): boolean {
  return (
    c.kind === "comment" && c.mine !== null && c.theirs !== null && c.mine[KEY] !== c.theirs[KEY]
  );
}

export function resolve(r: LocalReview, c: Conflict, pick: Pick): LocalReview {
  if (c.kind === "field") {
    const out: LocalReview = { ...r };
    const v = pick === "mine" ? c.mine : c.theirs;
    if (v === undefined) delete out[c.name];
    else out[c.name] = v;
    return out;
  }
  // Either side's comment goes, whatever its key, and the one picked takes the first's place.
  const keys = new Set([c.key]);
  if (c.theirs !== null) keys.add(c.theirs[KEY]);
  if (c.mine !== null) keys.add(c.mine[KEY]);
  const keep =
    pick === "both" && canKeepBoth(c) ? [c.theirs, c.mine] : [pick === "mine" ? c.mine : c.theirs];
  const at = r.comments.findIndex((x) => keys.has(x[KEY]));
  const comments = r.comments.filter((x) => !keys.has(x[KEY]));
  comments.splice(at < 0 ? comments.length : at, 0, ...keep.filter((x) => x !== null));
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

/** The most inline comments a review may carry; mirrors `maxInlineComments` in Lean. */
export const MAX_COMMENTS = 200;

/** Why the server would refuse `r`, or `null`; mirrors `Review.validate` in Lean. */
export function reviewProblem(r: Review): string | null {
  if (r.comments.length > MAX_COMMENTS)
    return `The review carries ${r.comments.length} inline comments; a review may carry at most ${MAX_COMMENTS}.`;
  if (r.decision !== "approve" && r.body.trim() === "")
    return "The summary is empty; GitHub requires one unless the review approves.";
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