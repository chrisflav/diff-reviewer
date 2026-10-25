/**
 * What the calibration pages show of the numbers, worked out apart from the pages so that it can
 * be checked without a browser: ratios with their denominators, the pairs of a score grouped by
 * file, and the state of an import.
 */

import type {
  AgentComment,
  CalibrationImport,
  CalibrationScore,
  CalibrationUnscorable,
  HumanComment,
} from "./api";

/**
 * Below this many in the denominator a ratio is marked as resting on few comments or samples: one
 * comment more or less moves it by a tenth or more.
 */
export const FEW = 10;

/** A ratio as the pages show it: never a percentage alone. */
export interface ShownRatio {
  /** `"75%"`, or `"—"` when there is nothing to divide by. */
  percent: string;
  /** `"3/4"`. */
  fraction: string;
  /** `"75% (3/4)"`, or `"— (0/0)"`. */
  text: string;
  /** What a screen reader says: `"3 of 4, 75%"`, or `"none of 0: nothing to divide by"`. */
  label: string;
  /** Whether the denominator is under `FEW`. */
  few: boolean;
  /** Whether there was anything to divide by. */
  defined: boolean;
}

/**
 * `num` over `den`, the server's ratio `value` (to four decimals) taken when given, so that the
 * page shows what the server computed. Percentages to one decimal at most, without a trailing
 * `.0`; a ratio that is not 0 or 1 is never rounded to them.
 */
export function formatRatio(num: number, den: number, value?: number | null): ShownRatio {
  const fraction = `${num}/${den}`;
  if (den === 0 || value === null) {
    return {
      percent: "—",
      fraction,
      text: `— (${fraction})`,
      label: `${num} of ${den}: nothing to divide by`,
      few: true,
      defined: false,
    };
  }
  const v = value ?? num / den;
  const percent = `${percentOf(v, num, den)}%`;
  return {
    percent,
    fraction,
    text: `${percent} (${fraction})`,
    label: `${num} of ${den}, ${percent}`,
    few: den < FEW,
    defined: true,
  };
}

function percentOf(v: number, num: number, den: number): string {
  const p = Math.round(v * 1000) / 10;
  // 199 of 200 is not 100%, and 1 of 2000 is not 0%.
  if (p >= 100 && num < den) return "99.9";
  if (p <= 0 && num > 0) return "0.1";
  return p.toFixed(1).replace(/\.0$/, "");
}

/** A line range, `12` or `12–14`. */
export function lines(start: number, end: number): string {
  return start === end ? `${start}` : `${start}–${end}`;
}

/** One row of a score's comments, in the file it is on. */
export type PairRow =
  | { kind: "pair"; key: string; gap: number; agent: AgentComment; human: HumanComment }
  | { kind: "agent"; agent: AgentComment }
  | { kind: "human"; human: HumanComment };

export interface FileRows {
  file: string;
  rows: PairRow[];
  /** Counts of each kind of row: what the file's heading says. */
  pairs: number;
  agentOnly: number;
  humanOnly: number;
}

function startOf(r: PairRow): number {
  switch (r.kind) {
    case "pair":
      return Math.min(r.agent.start_line, r.human.start_line);
    case "agent":
      return r.agent.start_line;
    case "human":
      return r.human.start_line;
  }
}

const kindRank = { pair: 0, agent: 1, human: 2 } as const;

/**
 * The pairs and the comments left unpaired on each side, by file (in path order) and within a
 * file by first line, a pair before an unpaired comment at the same line. A comment's file is the
 * agent's `file` or the person's `path`; a pair is filed under the agent's, which matching makes
 * the person's too.
 */
export function groupPairs(
  s: Pick<CalibrationScore, "pairs" | "unmatchedAgent" | "unmatchedHuman">,
): FileRows[] {
  const byFile = new Map<string, PairRow[]>();
  const add = (file: string, r: PairRow) => {
    const rows = byFile.get(file);
    if (rows === undefined) byFile.set(file, [r]);
    else rows.push(r);
  };
  for (const p of s.pairs ?? [])
    add(p.agent.file, { kind: "pair", key: p.key, gap: p.gap, agent: p.agent, human: p.human });
  for (const a of s.unmatchedAgent ?? []) add(a.file, { kind: "agent", agent: a });
  for (const h of s.unmatchedHuman ?? []) add(h.path, { kind: "human", human: h });
  const files = [...byFile.keys()].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  return files.map((file) => {
    // A stable sort: rows at one line and of one kind keep the server's order.
    const rows = (byFile.get(file) ?? [])
      .map((r, i) => ({ r, i }))
      .sort(
        (x, y) =>
          startOf(x.r) - startOf(y.r) || kindRank[x.r.kind] - kindRank[y.r.kind] || x.i - y.i,
      )
      .map((x) => x.r);
    return {
      file,
      rows,
      pairs: rows.filter((r) => r.kind === "pair").length,
      agentOnly: rows.filter((r) => r.kind === "agent").length,
      humanOnly: rows.filter((r) => r.kind === "human").length,
    };
  });
}

/** Whether a stored score is a score, rather than a record of why there is none. */
export function isScore(s: CalibrationScore | CalibrationUnscorable | null): s is CalibrationScore {
  return s !== null && !("unscorable" in s) && Array.isArray((s as CalibrationScore).pairs);
}

/** What an import is doing, for its status line. */
export type ImportState =
  | { kind: "paused"; until: string | null; why: string }
  | { kind: "rateLimited"; why: string }
  | { kind: "retrying"; why: string }
  | { kind: "active" }
  | { kind: "ended"; status: string };

/**
 * An import's state: a queued or running one whose last pass stopped short says why in `error`,
 * which the workers word as `paused until <time>: …` under the reserve and `GitHub's rate limit
 * (…)` when GitHub refused. Either goes on by itself.
 */
export function importState(i: Pick<CalibrationImport, "status" | "error">): ImportState {
  if (i.status !== "queued" && i.status !== "running") return { kind: "ended", status: i.status };
  const why = i.error;
  if (why === null || why === "") return { kind: "active" };
  const paused = /^paused until (\S+):\s/.exec(why);
  if (paused !== null) return { kind: "paused", until: paused[1] ?? null, why };
  if (/rate limit/i.test(why)) return { kind: "rateLimited", why };
  return { kind: "retrying", why };
}

/** Whether an import is still going on (queued or running), and so can be cancelled. */
export function importLive(i: Pick<CalibrationImport, "status">): boolean {
  return i.status === "queued" || i.status === "running";
}

/** The counts an import keeps, in the order shown, with what each means (from the README). */
export const importStats: { key: string; label: string; means: string }[] = [
  { key: "pulls", label: "pull requests", means: "Closed pull requests listed to be read." },
  {
    key: "reviews",
    label: "reviews",
    means: "Submitted reviews by trusted reviewers that no earlier import had seen.",
  },
  {
    key: "imported",
    label: "samples made",
    means: "New samples: what one trusted reviewer said of one commit.",
  },
  {
    key: "merged",
    label: "merged",
    means: "Reviews added to the sample of their commit and reviewer, which already existed.",
  },
  {
    key: "known",
    label: "known",
    means: "Reviews an earlier import looked at, whatever became of them; never counted again.",
  },
  {
    key: "deleted",
    label: "to deleted samples",
    means: "Reviews of a commit and reviewer whose sample was deleted: added to nothing.",
  },
  {
    key: "empty",
    label: "empty",
    means:
      "Comments (and dismissed reviews) with no body and no comment kept: nothing to compare; not stored. An empty approval or request for changes is kept, as a decision sample.",
  },
  {
    key: "unreachable",
    label: "unreachable",
    means:
      "Reviews of a commit GitHub can no longer compare with the base, typically one a force-push left unreferenced; not stored.",
  },
  {
    key: "unreadable",
    label: "unreadable",
    means:
      "Pull requests whose reviews or comments GitHub refused to list, or that failed three times running; skipped.",
  },
  {
    key: "droppedLeft",
    label: "dropped: old side",
    means: "Comments on the old side of the diff, which cannot be compared; the sample is partial.",
  },
  {
    key: "droppedOutdated",
    label: "dropped: not anchored",
    means:
      "Comments not on a line of the review's own commit: written against another commit, or on a whole file. Not GitHub's \"outdated\". The sample is partial.",
  },
  {
    key: "droppedReplies",
    label: "dropped: replies",
    means:
      "Replies in a thread, which answer a comment rather than raise one; they do not make a sample partial.",
  },
];

/** What a sample's scope means for its scores. */
export const scopeMeans: Record<string, string> = {
  full: "Everything: its comments count towards precision and recall, and its decision towards agreement.",
  partial:
    "Comments were dropped (on the old side, or not anchored to the commit), so its comments are not the whole review: scored for its decision only.",
  decision:
    "An approval or request for changes that says nothing else: scored for its decision only.",
};

/** The most samples one run takes (`maxRunSamples`). */
export const MAX_RUN_SAMPLES = 20;