import { describe, expect, it } from "vitest";
import type { AgentComment, HumanComment } from "./api";
import { FEW, formatRatio, groupPairs, importState, isScore } from "./calibration";

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