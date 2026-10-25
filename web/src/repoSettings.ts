/**
 * A repository's settings as the settings page edits them: the checks of a trusted reviewer's
 * login, which mirror `validLogin` and `maxTrustedReviewers` in Lean; the body of a versioned
 * write, which sends back every field read; and a three-way merge, for a save that met a newer
 * version (409).
 *
 * Pure functions only, so that what the page does can be checked without a browser.
 */

import type { PostingMode, Repo, RepoSettings } from "./api";
import { same } from "./review";

/** The most trusted reviewers a repository names (`maxTrustedReviewers`). */
export const MAX_TRUSTED_REVIEWERS = 50;
/** The longest GitHub login. */
export const MAX_LOGIN_LENGTH = 39;

/** What the page edits of a repository's settings. */
export interface RepoForm {
  mode: PostingMode;
  autoReview: boolean;
  /** In lower case, once each, as the server stores them. */
  trustedReviewers: string[];
}

/** The fields of a repository that are about the record, not settings a write sends. */
const metaFields = ["owner", "name", "createdAt", "version"];

export function formOf(r: Repo): RepoForm {
  return {
    mode: r.mode,
    autoReview: r.autoReview,
    trustedReviewers: normalLogins(r.trustedReviewers ?? []),
  };
}

/**
 * The body of a write of `form` over `read`, the settings at the version last read: every field
 * read that is not about the record, a newer build's settings among them, so that a write from
 * this page leaves them as they were; the form on top; and the version, so that a write over a
 * newer one is a 409.
 */
export function putBody(read: Repo, form: RepoForm): RepoSettings {
  const out: Record<string, unknown> = { ...read };
  for (const f of metaFields) delete out[f];
  return {
    ...out,
    mode: form.mode,
    autoReview: form.autoReview,
    trustedReviewers: form.trustedReviewers,
    version: read.version,
  };
}

/** The body that registers a repository not registered yet. */
export function registerBody(mode: PostingMode, autoReview: boolean): RepoSettings {
  return { mode, autoReview, version: 0 };
}

/**
 * Why `login` is not a GitHub login, as `validLogin` says it, or null: ASCII letters, digits and
 * single hyphens, not at either end, at most 39 characters.
 */
export function loginProblem(login: string): string | null {
  if (login === "") return "A login cannot be empty.";
  if (login.length > MAX_LOGIN_LENGTH)
    return `A GitHub login has at most ${MAX_LOGIN_LENGTH} characters.`;
  if (!/^[A-Za-z0-9-]*$/.test(login)) return "A GitHub login has only letters, digits and hyphens.";
  if (login.startsWith("-") || login.endsWith("-"))
    return "A GitHub login does not start or end with a hyphen.";
  if (login.includes("--")) return "A GitHub login has no two hyphens in a row.";
  return null;
}

/** Logins as the server stores them: lower case, once each, in the order first given. */
export function normalLogins(logins: string[]): string[] {
  const out: string[] = [];
  for (const l of logins) {
    const n = l.toLowerCase();
    if (!out.includes(n)) out.push(n);
  }
  return out;
}

/**
 * What adding `input` (one or more logins, separated by spaces or commas, an `@` before each
 * allowed) to `list` gives: the new list, or why it is refused.
 */
export function addLogins(list: string[], input: string): { list: string[] } | { problem: string } {
  const given = input
    .split(/[\s,]+/)
    .map((l) => l.replace(/^@/, ""))
    .filter((l) => l !== "");
  if (given.length === 0) return { problem: "Name a GitHub login." };
  for (const l of given) {
    const why = loginProblem(l);
    if (why !== null) return { problem: `'${l}': ${why}` };
  }
  const next = normalLogins([...list, ...given]);
  if (next.length > MAX_TRUSTED_REVIEWERS)
    return { problem: `A repository names at most ${MAX_TRUSTED_REVIEWERS} trusted reviewers.` };
  const fresh = next.length - list.length;
  if (fresh === 0)
    return { problem: given.length === 1 ? "Already listed." : "All of them are listed already." };
  return { list: next };
}

/** Why the form cannot be written, or null; what the server checks, so that it never says 400. */
export function formProblem(f: RepoForm): string | null {
  if (f.mode !== "staged" && f.mode !== "direct") return `'${String(f.mode)}' is not a mode.`;
  if (f.trustedReviewers.length > MAX_TRUSTED_REVIEWERS)
    return `A repository names at most ${MAX_TRUSTED_REVIEWERS} trusted reviewers.`;
  for (const l of f.trustedReviewers) {
    const why = loginProblem(l);
    if (why !== null) return `'${l}': ${why}`;
  }
  return null;
}

export function sameForm(a: RepoForm, b: RepoForm): boolean {
  return (
    a.mode === b.mode &&
    a.autoReview === b.autoReview &&
    a.trustedReviewers.length === b.trustedReviewers.length &&
    a.trustedReviewers.every((l, i) => b.trustedReviewers[i] === l)
  );
}

/** A setting both this page and another write changed, to different values. */
export type RepoConflict =
  | { field: "mode"; mine: PostingMode; theirs: PostingMode }
  | { field: "autoReview"; mine: boolean; theirs: boolean };

export interface RepoMerged {
  /** The merge, with the other write's value wherever there is a conflict. */
  form: RepoForm;
  conflicts: RepoConflict[];
}

/**
 * The edits from `base` to `mine`, moved onto `theirs`, a newer version. A setting only one side
 * changed takes that side's value. The trusted reviewers merge as a set: the logins this page
 * added are added, those it removed are removed, and every other change of the other write is
 * kept, so that neither side's additions or removals are lost. A mode or `autoReview` both
 * changed to different values is a conflict, left at theirs until a side is picked: nothing is
 * overwritten unasked. With today's two-valued settings no conflict arises (two sides that both
 * changed a setting from its base changed it to the same value); the page still asks, and keeps
 * the sides picked across a reload, so that a setting of more values cannot be overwritten.
 */
export function mergeRepoSettings(base: RepoForm, mine: RepoForm, theirs: RepoForm): RepoMerged {
  const conflicts: RepoConflict[] = [];
  const scalar = <K extends "mode" | "autoReview">(k: K): RepoForm[K] => {
    if (mine[k] === base[k] || mine[k] === theirs[k]) return theirs[k];
    if (theirs[k] === base[k]) return mine[k];
    conflicts.push({ field: k, mine: mine[k], theirs: theirs[k] } as RepoConflict);
    return theirs[k];
  };
  const mode = scalar("mode");
  const autoReview = scalar("autoReview");
  const b = new Set(normalLogins(base.trustedReviewers));
  const m = normalLogins(mine.trustedReviewers);
  const mSet = new Set(m);
  const added = m.filter((l) => !b.has(l));
  const removed = new Set([...b].filter((l) => !mSet.has(l)));
  const trustedReviewers = normalLogins([
    ...normalLogins(theirs.trustedReviewers).filter((l) => !removed.has(l)),
    ...added,
  ]);
  return { form: { mode, autoReview, trustedReviewers }, conflicts };
}

/** `form` with conflict `c` settled for `pick`. */
export function resolveRepoConflict(
  form: RepoForm,
  c: RepoConflict,
  pick: "mine" | "theirs",
): RepoForm {
  return { ...form, [c.field]: pick === "mine" ? c.mine : c.theirs };
}

/** Which side of each conflict was picked, by field. */
export type RepoPicks = Partial<Record<RepoConflict["field"], "mine" | "theirs">>;

/** The conflicts of a merge not yet given a side. */
export function openConflicts(conflicts: RepoConflict[], picks: RepoPicks): RepoConflict[] {
  return conflicts.filter((c) => picks[c.field] === undefined);
}

/**
 * Whether `now`, the settings read after a 409, differ from `read`, what the person saw, in
 * `autoReview` alone (or not at all): the mode, the trusted reviewers and every other setting, a
 * newer build's among them, as they were. Only then may a toggle of `autoReview` be written over
 * `now` without asking: turning automatic reviews on is a different decision for a repository
 * whose mode became `direct` meanwhile.
 */
export function onlyAutoReviewChanged(read: Repo, now: Repo): boolean {
  const settings = (r: Repo) => {
    const b: Record<string, unknown> = { ...putBody(r, formOf(r)) };
    delete b.autoReview;
    delete b.version;
    return b;
  };
  return same(settings(read), settings(now));
}