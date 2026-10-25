/**
 * The review as the job page edits it, and where its comments land in a diff.
 *
 * Pure functions only, so that what the page shows can be checked without a browser.
 */

import type { Decision, InlineComment, Review } from "./api";
import { displayPath, type DiffFile } from "./diff";

/** A comment with a key that stays put while comments around it are added and deleted. */
export interface LocalComment extends InlineComment {
  key: number;
}

export interface LocalReview {
  decision: Decision;
  body: string;
  comments: LocalComment[];
}

export function toLocal(r: Review): LocalReview {
  return {
    decision: r.decision,
    body: r.body,
    comments: r.comments.map((c, i) => ({ ...c, key: i })),
  };
}

/** The review as the API takes it: the keys dropped, and no `suggestion` key when there is none. */
export function toReview(r: LocalReview): Review {
  return {
    decision: r.decision,
    body: r.body,
    comments: r.comments.map((c) => withoutKey(c)),
  };
}

function withoutKey(c: LocalComment): InlineComment {
  const out: InlineComment = {
    file: c.file,
    start_line: c.start_line,
    end_line: c.end_line,
    body: c.body,
  };
  if (c.suggestion !== undefined) out.suggestion = c.suggestion;
  return out;
}

export function nextKey(r: LocalReview): number {
  return r.comments.reduce((k, c) => Math.max(k, c.key + 1), 0);
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

/** Read a review someone typed as JSON; answers why it is not one, as a string, if it is not. */
export function parseReview(text: string): Review | string {
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
      file: c.file,
      start_line: c.start_line,
      end_line: c.end_line,
      body: c.body,
    };
    if (typeof c.suggestion === "string") out.suggestion = c.suggestion;
    comments.push(out);
  }
  const review: Review = { decision: j.decision as Decision, body: j.body, comments };
  return reviewProblem(review) ?? review;
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
    if (lines.get(c.start_line) !== endHunk) p.split.add(c.key);
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