/**
 * Unsaved review edits, kept in this tab's session storage while they are made.
 *
 * A page that goes away (a 401 sends the person to the login screen, a reload, a navigation)
 * would otherwise take the edits with it. The job page writes them here on every change, drops
 * them once saved or discarded, and offers them back when it is opened again.
 */

import { freeze, thaw, type LocalReview } from "./review";
import { freezeRubric, thawRubric, type LocalRubric } from "./rubric";

/** Edits as the job page holds them: made to `base`, the review at `version` of job `jobId`. */
export interface Edits {
  jobId: string;
  version: number;
  base: LocalReview;
  review: LocalReview;
}

export interface Stashed extends Edits {
  savedAt: string;
}

const prefix = "diff-reviewer:edits:";

// Storage can be missing or refuse (a private window, a full quota): the page works without it.
export function stash(e: Edits) {
  try {
    sessionStorage.setItem(
      prefix + e.jobId,
      JSON.stringify({
        jobId: e.jobId,
        version: e.version,
        base: freeze(e.base),
        review: freeze(e.review),
        savedAt: new Date().toISOString(),
      }),
    );
  } catch {
    /* kept in memory only */
  }
}

export function unstash(jobId: string): Stashed | null {
  try {
    const text = sessionStorage.getItem(prefix + jobId);
    if (text === null) return null;
    const j = JSON.parse(text) as Record<string, unknown>;
    const base = thaw(j.base);
    const review = thaw(j.review);
    if (
      j.jobId !== jobId ||
      typeof j.version !== "number" ||
      typeof j.savedAt !== "string" ||
      base === null ||
      review === null
    )
      return null;
    return { jobId, version: j.version, base, review, savedAt: j.savedAt };
  } catch {
    return null;
  }
}

export function dropStash(jobId: string) {
  try {
    sessionStorage.removeItem(prefix + jobId);
  } catch {
    /* nothing to drop */
  }
}

/** Unsaved rubric edits of repository `repo` (`owner/name`): made to `base`, at `version`. */
export interface RubricEdits {
  repo: string;
  version: number;
  base: LocalRubric;
  doc: LocalRubric;
}

export interface StashedRubric extends RubricEdits {
  savedAt: string;
}

const rubricPrefix = "diff-reviewer:rubric:";

export function stashRubric(e: RubricEdits) {
  try {
    sessionStorage.setItem(
      rubricPrefix + e.repo,
      JSON.stringify({
        repo: e.repo,
        version: e.version,
        base: freezeRubric(e.base),
        doc: freezeRubric(e.doc),
        savedAt: new Date().toISOString(),
      }),
    );
  } catch {
    /* kept in memory only */
  }
}

export function unstashRubric(repo: string): StashedRubric | null {
  try {
    const text = sessionStorage.getItem(rubricPrefix + repo);
    if (text === null) return null;
    const j = JSON.parse(text) as Record<string, unknown>;
    const base = thawRubric(j.base);
    const doc = thawRubric(j.doc);
    if (
      j.repo !== repo ||
      typeof j.version !== "number" ||
      typeof j.savedAt !== "string" ||
      base === null ||
      doc === null
    )
      return null;
    return { repo, version: j.version, base, doc, savedAt: j.savedAt };
  } catch {
    return null;
  }
}

export function dropRubricStash(repo: string) {
  try {
    sessionStorage.removeItem(rubricPrefix + repo);
  } catch {
    /* nothing to drop */
  }
}