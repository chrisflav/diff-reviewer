import { describe, expect, it } from "vitest";
import type { AgentComment, HumanComment } from "./api";
import {
  decisionTable,
  FEW,
  formatRatio,
  groupPairs,
  importState,
  isScore,
  scoreScope,
} from "./calibration";
import { directLabel, runPoints } from "./components/RunChart";

describe("formatRatio", () => {
  it("shows the denominator beside the percentage", () => {
    const r = formatRatio(3, 4, 0.75);
    expect(r.text).toBe("75% (3/4)");
    expect(r.label).toBe("3 of 4, 75%");
    expect(r.defined).toBe(true);
  });

  it("marks a ratio of few", () => {
    expect(formatRatio(1, FEW - 1).few).toBe(true);
    expect(formatRatio(1, FEW).few).toBe(false);
  });

  it("has nothing to show when there is nothing to divide by", () => {
    const r = formatRatio(0, 0, null);
    expect(r.percent).toBe("—");
    expect(r.text).toBe("— (0/0)");
    expect(r.defined).toBe(false);
  });

  it("takes the server's null as undefined even with a denominator", () => {
    // A partial sample's precision is null although the agent commented.
    expect(formatRatio(1, 3, null).defined).toBe(false);
  });

  it("keeps one decimal and drops a trailing zero", () => {
    expect(formatRatio(2, 3, 0.6667).percent).toBe("66.7%");
    expect(formatRatio(1, 2, 0.5).percent).toBe("50%");
  });

  it("never rounds a ratio that is not 0 or 1 to them", () => {
    expect(formatRatio(1999, 2000, 0.9995).percent).toBe("99.9%");
    expect(formatRatio(1, 2001, 0.0005).percent).toBe("0.1%");
    expect(formatRatio(0, 5, 0).percent).toBe("0%");
    expect(formatRatio(5, 5, 1).percent).toBe("100%");
  });

  it("computes the ratio when the server gave none", () => {
    expect(formatRatio(1, 4).text).toBe("25% (1/4)");
  });
});

const agent = (id: string, file: string, start: number, end = start): AgentComment => ({
  id,
  file,
  start_line: start,
  end_line: end,
  body: `agent ${id}`,
  category: null,
  severity: null,
});

const human = (id: number, path: string, start: number, line = start): HumanComment => ({
  id,
  path,
  start_line: start,
  line,
  body: `human ${id}`,
});

describe("groupPairs", () => {
  it("files pairs and unpaired comments by file, in path order", () => {
    const g = groupPairs({
      pairs: [
        { key: "a1:1", gap: 0, agent: agent("a1", "b.lean", 10), human: human(1, "b.lean", 9) },
      ],
      unmatchedAgent: [agent("a2", "a.lean", 5)],
      unmatchedHuman: [human(2, "c.lean", 1), human(3, "b.lean", 40)],
    });
    expect(g.map((f) => f.file)).toEqual(["a.lean", "b.lean", "c.lean"]);
    const b = g[1];
    expect(b?.rows.map((r) => r.kind)).toEqual(["pair", "human"]);
    expect([b?.pairs, b?.agentOnly, b?.humanOnly]).toEqual([1, 0, 1]);
  });

  it("orders a file's rows by first line, a pair first at a tie", () => {
    const g = groupPairs({
      pairs: [{ key: "a1:1", gap: 2, agent: agent("a1", "f", 20), human: human(1, "f", 15, 17) }],
      unmatchedAgent: [agent("a2", "f", 15), agent("a3", "f", 3)],
      unmatchedHuman: [human(2, "f", 15)],
    });
    const rows = g[0]?.rows ?? [];
    expect(rows.map((r) => r.kind)).toEqual(["agent", "pair", "agent", "human"]);
    const first = rows[0];
    expect(first?.kind === "agent" && first.agent.id).toBe("a3");
  });

  it("keeps the server's order of rows at one line and of one kind", () => {
    const g = groupPairs({
      pairs: [],
      unmatchedAgent: [agent("x", "f", 7), agent("y", "f", 7)],
      unmatchedHuman: [],
    });
    expect(g[0]?.rows.map((r) => (r.kind === "agent" ? r.agent.id : ""))).toEqual(["x", "y"]);
  });

  it("files a pair under the agent's file and places it by the earlier side", () => {
    const g = groupPairs({
      pairs: [{ key: "a:1", gap: 1, agent: agent("a", "f", 30), human: human(1, "f", 27, 29) }],
      unmatchedAgent: [agent("b", "f", 28)],
      unmatchedHuman: [],
    });
    expect(g[0]?.rows.map((r) => r.kind)).toEqual(["pair", "agent"]);
  });

  it("is empty with no comments on either side", () => {
    expect(groupPairs({ pairs: [], unmatchedAgent: [], unmatchedHuman: [] })).toEqual([]);
  });
});

describe("isScore", () => {
  it("tells a score from an unscorable record", () => {
    expect(isScore({ matcherVersion: 1, unscorable: "no decision" })).toBe(false);
    expect(isScore(null)).toBe(false);
  });
});

describe("importState", () => {
  it("reads the reset time of a paused import", () => {
    const s = importState({
      status: "running",
      error:
        "paused until 2026-10-25T12:00:00Z: GitHub's requests left before its limit resets are under the 500 kept",
    });
    expect(s).toEqual({
      kind: "paused",
      until: "2026-10-25T12:00:00Z",
      why: expect.stringContaining("paused") as unknown as string,
    });
  });

  it("tells a rate limit from another error, and an ended import from both", () => {
    expect(
      importState({ status: "queued", error: "GitHub's rate limit (API rate limit exceeded)" })
        .kind,
    ).toBe("rateLimited");
    expect(importState({ status: "running", error: "reading #4: timeout" }).kind).toBe("retrying");
    expect(importState({ status: "running", error: null }).kind).toBe("active");
    expect(importState({ status: "failed", error: "rate limit" }).kind).toBe("ended");
  });
});

describe("scoreScope", () => {
  it("reads a score written without a scope as full, as Score.lean does", () => {
    expect(scoreScope({})).toBe("full");
    expect(scoreScope({ scope: null })).toBe("full");
    expect(scoreScope({ scope: "partial" })).toBe("partial");
  });
});

describe("decisionTable", () => {
  const t = decisionTable([
    { agent: "approve", human: "APPROVED", count: 3 },
    { agent: "request_changes", human: "DISMISSED", count: 2 },
    { agent: "approve", human: "CHANGES_REQUESTED", count: 1 },
    { agent: "request_changes", human: "APPROVED", count: 1 },
  ]);

  it("puts the compared states first and marks the rest", () => {
    expect(t.humans).toEqual([
      { state: "APPROVED", compared: true },
      { state: "CHANGES_REQUESTED", compared: true },
      { state: "DISMISSED", compared: false },
    ]);
    expect(t.agents).toEqual(["approve", "request_changes"]);
  });

  it("counts compared cells apart from the rest: they add up to decisions.compared", () => {
    expect(t.compared).toBe(5);
    expect(t.notCompared).toBe(2);
    expect(t.count("request_changes", "DISMISSED")).toBe(2);
    expect(t.count("approve", "DISMISSED")).toBe(0);
  });
});

describe("the chart's direct labels", () => {
  const run = (
    agg: Partial<{
      matched: number;
      agentComments: number;
      humanComments: number;
      precision: number | null;
      recall: number | null;
    }>,
  ) => ({
    id: "r",
    owner: "o",
    name: "n",
    createdAt: "2026-10-01T00:00:00Z",
    samples: 1,
    jobs: {},
    aggregate: {
      matcherVersion: 1,
      scored: 1,
      commentsScored: 1,
      staleScores: 0,
      staleIncluded: false,
      agentComments: 0,
      humanComments: 0,
      matched: 0,
      precision: null,
      recall: null,
      byCategory: [],
      bySeverity: [],
      decisions: { compared: 0, agreed: 0, agreement: null, matrix: [] },
      ...agg,
    },
  });

  it("say 100% of a run whose every comment paired, from its own counts", () => {
    const [p] = runPoints([
      run({ matched: 4, agentComments: 4, humanComments: 5, precision: 1, recall: 0.8 }),
    ]);
    if (p === undefined) throw new Error("no point");
    expect(directLabel(p, "precision")).toBe("precision 100%");
    expect(directLabel(p, "recall")).toBe("recall 80%");
  });

  it("never say 0% of a run where something paired", () => {
    const [p] = runPoints([
      run({ matched: 1, agentComments: 3000, humanComments: 1, precision: 0.0003, recall: 1 }),
    ]);
    if (p === undefined) throw new Error("no point");
    expect(directLabel(p, "precision")).toBe("precision 0.1%");
  });

  it("order the runs oldest first", () => {
    const a = { ...run({}), id: "new", createdAt: "2026-10-02T00:00:00Z" };
    const b = { ...run({}), id: "old", createdAt: "2026-09-01T00:00:00Z" };
    expect(runPoints([a, b]).map((p) => p.id)).toEqual(["old", "new"]);
  });
});