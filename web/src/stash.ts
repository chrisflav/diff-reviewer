/**
 * Unsaved review edits, kept in this tab's session storage while they are made.
 *
 * A page that goes away (a 401 sends the person to the login screen, a reload, a navigation)
 * would otherwise take the edits with it. The job page writes them here on every change, drops
 * them once saved or discarded, and offers them back when it is opened again.
 */

import {
  freeze,
  rebase,
  same,
  thaw,
  toReview,
  type Conflict,
  type LocalReview,
  type Pick,
} from "./review";
import {
  DEFAULT_EVAL_SHARE,
  mergeRepoSettings,
  type RepoConflict,
  type RepoForm,
  type RepoPicks,
} from "./repoSettings";

/** Edits as the job page holds them: made to `base`, the review at `version` of job `jobId`. */
export interface Edits {
  jobId: string;
  version: number;
  base: LocalReview;
  review: LocalReview;
}

export interface Stashed extends Edits {
  savedAt: string;
  pending: Pending | null;
}

const prefix = "diff-reviewer:edits:";

/**
 * Write `value` under `key`; false when storage is missing or refuses (a private window, a full
 * quota). Then an older copy is removed rather than left to be offered back as if it were these
 * edits, and the page says that the edits are held in memory only.
 */
function put(key: string, value: () => unknown): boolean {
  try {
    sessionStorage.setItem(key, JSON.stringify(value()));
    return true;
  } catch {
    try {
      sessionStorage.removeItem(key);
    } catch {
      /* no storage at all */
    }
    return false;
  }
}

/**
 * The conflicts a move onto a newer version left open: the edits from before the move and the
 * sides picked so far. The conflicts themselves are worked out again from these, since moving the
 * same edits onto the same version always gives the same ones.
 */
export interface Pending {
  from: number;
  source: Edits;
  picks: Record<string, Pick>;
}

/** Keep the edits, and any conflicts still open; false when they are held in memory only. */
export function stash(e: Edits, pending: Pending | null = null): boolean {
  return put(prefix + e.jobId, () => ({
    jobId: e.jobId,
    version: e.version,
    base: freeze(e.base),
    review: freeze(e.review),
    savedAt: new Date().toISOString(),
    pending:
      pending === null
        ? null
        : {
            from: pending.from,
            version: pending.source.version,
            base: freeze(pending.source.base),
            review: freeze(pending.source.review),
            picks: pending.picks,
          },
  }));
}

const picksOk = (v: unknown) => v === "mine" || v === "theirs" || v === "both";

function thawReviewPending(jobId: string, j: unknown): Pending | null | undefined {
  if (j === null || j === undefined) return null;
  if (typeof j !== "object") return undefined;
  const p = j as Record<string, unknown>;
  const base = thaw(p.base);
  const review = thaw(p.review);
  const picks = p.picks;
  if (
    typeof p.from !== "number" ||
    typeof p.version !== "number" ||
    base === null ||
    review === null ||
    typeof picks !== "object" ||
    picks === null ||
    !Object.values(picks).every(picksOk)
  )
    return undefined;
  return {
    from: p.from,
    source: { jobId, version: p.version, base, review },
    picks: picks as Record<string, Pick>,
  };
}

export function unstash(jobId: string): Stashed | null {
  try {
    const text = sessionStorage.getItem(prefix + jobId);
    if (text === null) return null;
    const j = JSON.parse(text) as Record<string, unknown>;
    const base = thaw(j.base);
    const review = thaw(j.review);
    const pending = thawReviewPending(jobId, j.pending);
    if (
      j.jobId !== jobId ||
      typeof j.version !== "number" ||
      typeof j.savedAt !== "string" ||
      base === null ||
      review === null ||
      pending === undefined
    )
      return null;
    return { jobId, version: j.version, base, review, savedAt: j.savedAt, pending };
  } catch {
    return null;
  }
}

/**
 * The edits `s` kept, at the version they were made to, and the conflicts that were open: moving
 * the edits from before the move onto `s.base` again gives the same conflicts, and the picks and
 * the edits made since are in `s.review` already. `null` when that move no longer gives `s.base`
 * (stored by another build): then the edits from before the move are what is left to restore.
 */
export function reopen(s: Stashed): {
  edits: Edits;
  rebased: {
    from: number;
    to: number;
    conflicts: Conflict[];
    picks: Record<string, Pick>;
    source: Edits;
  } | null;
} | null {
  const edits: Edits = { jobId: s.jobId, version: s.version, base: s.base, review: s.review };
  const p = s.pending;
  if (p === null) return { edits, rebased: null };
  const r = rebase(p.source.base, p.source.review, toReview(s.base));
  if (!same(freeze(r.base), freeze(s.base))) return null;
  return {
    edits,
    rebased: {
      from: p.from,
      to: s.version,
      conflicts: r.conflicts,
      picks: p.picks,
      source: p.source,
    },
  };
}

export function dropStash(jobId: string) {
  try {
    sessionStorage.removeItem(prefix + jobId);
  } catch {
    /* nothing to drop */
  }
}

/** Owner and name as the server keys them: GitHub's names are not case-sensitive. */
export function repoKey(owner: string, name: string): string {
  return `${owner}/${name}`.toLowerCase();
}

/** Unsaved settings of repository `repo` (`owner/name`): made to `base`, at `version`. */
export interface RepoEdits {
  repo: string;
  version: number;
  base: RepoForm;
  form: RepoForm;
}

/**
 * The conflicts a move onto a newer version left open: the edits from before the move and the
 * sides picked so far. The conflicts themselves are worked out again from these, since moving the
 * same edits onto the same version always gives the same ones.
 */
export interface PendingRepo {
  from: number;
  source: RepoEdits;
  picks: RepoPicks;
}

export interface StashedRepo extends RepoEdits {
  savedAt: string;
  pending: PendingRepo | null;
  /**
   * Kept by a build that did not know the share held out: it was filled in alike on both sides,
   * so that restoring moves the edits onto the settings as they are rather than writing it.
   */
  legacy?: boolean;
}

const repoPrefix = "diff-reviewer:repo:";

/** Keep the settings edits, and any conflicts still open; false when they are held in memory only. */
export function stashRepo(e: RepoEdits, pending: PendingRepo | null = null): boolean {
  return put(repoPrefix + e.repo, () => ({
    ...e,
    savedAt: new Date().toISOString(),
    pending:
      pending === null
        ? null
        : {
            from: pending.from,
            version: pending.source.version,
            base: pending.source.base,
            form: pending.source.form,
            picks: pending.picks,
          },
  }));
}

/**
 * A stored form; one from before the share held out has the default, and says so (`legacy`). A
 * share left empty is `NaN` in the form, which JSON stores as null: it is `NaN` again. Style
 * notes a build from before the rubrics repository kept are not a setting any more: dropped.
 */
function thawForm(j: unknown): (RepoForm & { legacy: boolean }) | null {
  if (typeof j !== "object" || j === null) return null;
  const f = j as Record<string, unknown>;
  if (f.mode !== "staged" && f.mode !== "direct") return null;
  if (typeof f.autoReview !== "boolean") return null;
  const t = f.trustedReviewers;
  if (!Array.isArray(t) || !t.every((l) => typeof l === "string")) return null;
  const legacy = f.evalShare === undefined;
  const share = f.evalShare === null ? Number.NaN : f.evalShare;
  if (!legacy && typeof share !== "number") return null;
  return {
    mode: f.mode,
    autoReview: f.autoReview,
    trustedReviewers: t as string[],
    evalShare: legacy ? DEFAULT_EVAL_SHARE : (share as number),
    legacy,
  };
}

function plain(f: RepoForm & { legacy: boolean }): RepoForm {
  const { legacy: _, ...rest } = f;
  return rest;
}

function thawRepoPending(repo: string, j: unknown): PendingRepo | null | undefined {
  if (j === null || j === undefined) return null;
  if (typeof j !== "object") return undefined;
  const p = j as Record<string, unknown>;
  const base = thawForm(p.base);
  const form = thawForm(p.form);
  const picks = p.picks;
  if (
    typeof p.from !== "number" ||
    typeof p.version !== "number" ||
    base === null ||
    form === null ||
    typeof picks !== "object" ||
    picks === null ||
    !Object.values(picks).every((v) => v === "mine" || v === "theirs")
  )
    return undefined;
  return {
    from: p.from,
    source: { repo, version: p.version, base: plain(base), form: plain(form) },
    picks: picks as RepoPicks,
  };
}

export function unstashRepo(repo: string): StashedRepo | null {
  try {
    const text = sessionStorage.getItem(repoPrefix + repo);
    if (text === null) return null;
    const j = JSON.parse(text) as Record<string, unknown>;
    const base = thawForm(j.base);
    const form = thawForm(j.form);
    const pending = thawRepoPending(repo, j.pending);
    if (
      j.repo !== repo ||
      typeof j.version !== "number" ||
      typeof j.savedAt !== "string" ||
      base === null ||
      form === null ||
      pending === undefined ||
      base.legacy !== form.legacy
    )
      return null;
    return {
      repo,
      version: j.version,
      base: plain(base),
      form: plain(form),
      savedAt: j.savedAt,
      pending,
      ...(base.legacy ? { legacy: true } : {}),
    };
  } catch {
    return null;
  }
}

/**
 * The edits `s` kept, and the conflicts that were open: moving the edits from before the move onto
 * `s.base` again gives the same conflicts, and the sides picked are in `s.form` already. `null`
 * when that move no longer gives them (stored by another build): then the edits from before the
 * move are what is left to restore.
 */
export function reopenRepo(
  s: StashedRepo,
): { edits: RepoEdits; pending: PendingRepo | null; conflicts: RepoConflict[] } | null {
  const edits: RepoEdits = { repo: s.repo, version: s.version, base: s.base, form: s.form };
  const p = s.pending;
  if (p === null) return { edits, pending: null, conflicts: [] };
  const m = mergeRepoSettings(p.source.base, p.source.form, s.base);
  if (m.conflicts.length === 0) return null;
  return { edits, pending: p, conflicts: m.conflicts };
}

export function dropRepoStash(repo: string) {
  try {
    sessionStorage.removeItem(repoPrefix + repo);
  } catch {
    /* nothing to drop */
  }
}