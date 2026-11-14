import { describe, expect, it } from "vitest";
import type { RubricProposal } from "./api";
import {
  diffCounts,
  parseInline,
  parseRationale,
  proposalPath,
  proposalsPath,
  pullState,
  rubricUnchanged,
} from "./proposals";

const proposal: RubricProposal = {
  id: "p1",
  owner: "o",
  name: "n",
  jobId: "j1",
  status: "pending",
  baseSha: "1111111111111111111111111111111111111111",
  currentSha: "2222222222222222222222222222222222222222",
  rationale: "Because.",
  proposesStyleNotes: true,
  createdAt: "t",
  decidedAt: null,
  branch: "proposals/o/n/p1",
  pullRequest: null,
  prError: null,
  mergeSha: null,
};

describe("a proposal that only flips fan-out", () => {
  const none = {
    defaultRubric: null,
    typesAdded: [],
    typesRemoved: [],
    typesChanged: [],
    styleNotes: null,
  };
  const docOnly = { ...none, fanout: { before: false, after: true } };
  const typeOnly = {
    ...none,
    typesChanged: [
      {
        name: "feature",
        description: null,
        rubric: null,
        fanout: { before: true, after: false },
        categoriesAdded: [],
        categoriesRemoved: [],
        categoriesChanged: [],
      },
    ],
  };

  it("changes the rubric", () => {
    expect(rubricUnchanged(none)).toBe(true);
    expect(rubricUnchanged(docOnly)).toBe(false);
    expect(rubricUnchanged(typeOnly)).toBe(false);
  });

  it("is counted", () => {
    expect(diffCounts(none)).toBe("no changes");
    expect(diffCounts(docOnly)).toBe("fan-out turned on");
    expect(diffCounts({ ...docOnly, fanout: { before: true, after: false } })).toBe(
      "fan-out turned off",
    );
    expect(diffCounts(typeOnly)).toBe("1 type changed");
  });
});

describe("where a proposal stands on GitHub", () => {
  const pr = (state: string) => ({
    number: 7,
    url: "https://github.com/chrisflav/review-rubrics/pull/7",
    state,
  });

  it("follows its pull request: merged is accepted, closed unmerged rejected", () => {
    expect(pullState({ ...proposal, pullRequest: pr("open") })).toMatch(/is open/);
    expect(pullState({ ...proposal, pullRequest: pr("merged"), status: "accepted" })).toMatch(
      /merged: the proposal is accepted/,
    );
    expect(pullState({ ...proposal, pullRequest: pr("closed"), status: "rejected" })).toMatch(
      /closed unmerged: the proposal is rejected/,
    );
  });

  it("says when its pull request is not opened yet, and when opening it failed", () => {
    expect(pullState(proposal)).toMatch(/not opened yet/);
    expect(pullState({ ...proposal, prError: "403 from GitHub" })).toMatch(/could not be opened/);
  });

  it("is linked to on this site by its id", () => {
    expect(proposalsPath("a b", "c")).toBe("/repos/a%20b/c/proposals");
    expect(proposalPath("a", "c", "p/1")).toBe("/repos/a/c/proposals/p%2F1");
  });
});

describe("parseRationale", () => {
  it("reads headings, paragraphs, lists, quotes and code", () => {
    const b = parseRationale(
      "# Why\n\nThe agent **missed** `simp`.\n\n- one\n- two\n\n1. first\n\n> quoted\n\n```\n<b>x</b>\n```",
    );
    expect(b.map((x) => x.kind)).toEqual(["heading", "paragraph", "list", "list", "quote", "code"]);
    expect(b[5]).toEqual({ kind: "code", text: "<b>x</b>" });
    expect(b[3]).toMatchObject({ kind: "list", ordered: true });
  });

  it("keeps a link as its text and its address", () => {
    expect(parseInline("see [this](javascript:alert(1))")).toEqual([
      { kind: "text", text: "see " },
      { kind: "link", children: [{ kind: "text", text: "this" }], target: "javascript:alert(1)" },
    ]);
  });

  it("leaves HTML as text", () => {
    expect(parseInline("<script>alert(1)</script>")).toEqual([
      { kind: "text", text: "<script>alert(1)</script>" },
    ]);
  });

  it("reads a heading without its closing #s", () => {
    expect(parseRationale("## Why ##  ")).toEqual([
      { kind: "heading", level: 2, children: [{ kind: "text", text: "Why" }] },
    ]);
    expect(parseRationale("#\tWhy #x")[0]).toMatchObject({
      children: [{ kind: "text", text: "Why #x" }],
    });
  });

  it("closes a code span only on a run of its own length", () => {
    expect(parseInline("``a`b`` c")).toEqual([
      { kind: "code", text: "a`b" },
      { kind: "text", text: " c" },
    ]);
    expect(parseInline("``a`")).toEqual([{ kind: "text", text: "``a`" }]);
  });
});

describe("parseInline after a link with no end", () => {
  it("is text, and a link after it is still one", () => {
    expect(parseInline("[[a](b [c](d)")).toEqual([
      { kind: "text", text: "[[a](b " },
      { kind: "link", children: [{ kind: "text", text: "c" }], target: "d" },
    ]);
  });
});

describe("parseRationale on hostile input", () => {
  // At the 32 KB limit of a rationale; each of these took from a third of a second to minutes.
  const limit = 32 * 1024;
  const ticks = () => {
    let s = "";
    for (let k = 1; s.length < limit; k++) s += `${"`".repeat(k)}a`;
    return s;
  };
  const inputs: Record<string, () => string> = {
    "a heading padded with spaces": () => `# a${" ".repeat(limit)}b`,
    "a heading of #s": () => `# ${"#".repeat(limit)}x`,
    "backtick runs of distinct lengths": ticks,
    "unclosed brackets": () => "[".repeat(limit),
    "brackets before a link with no end": () =>
      `${"[".repeat(limit / 2)}a](${"b".repeat(limit / 2)}`,
    "unclosed strong": () => "**a ".repeat(limit / 4),
    "unclosed underscores": () => "__a ".repeat(limit / 4),
    "a mix": () => "[`*_".repeat(limit / 4),
  };

  for (const [what, input] of Object.entries(inputs))
    it(`reads ${what} in well under a second`, () => {
      const s = input();
      const t = performance.now();
      parseRationale(s);
      expect(performance.now() - t).toBeLessThan(250);
    });
});